#!/usr/bin/env bash
# Testa o role secure_boot de ponta a ponta numa VM com UEFI, TPM2 e LUKS, no
# caminho que um notebook real faz:
#
#   1. Debian recém-instalado, Secure Boot desligado, boot pelo GRUB;
#   2. provisionar: TPM2, chave própria, UKI, boot de teste e pedido de MOK;
#   3. confirmar a chave no MokManager;
#   4. ligar o Secure Boot "na BIOS" (chaves de fábrica);
#   5. provisionar de novo: o slot do TPM2 é refeito;
#   6. o disco abre sozinho pelo caminho novo e NÃO abre pelo GRUB.
#
# Parte da instalação salva por "vm.sh instalar" (feita uma vez). Precisa de
# KVM; não roda no CI.
# Os scripts entre aspas simples rodam como root na VM; a expansão é lá.
# shellcheck disable=SC2016
set -euo pipefail
cd "$(dirname "$0")/../.."

export VM_DIR=${VM_DIR:-/mnt/dados/caches/vms/servidor-debian-sb}
vm=tests/vm/vm.sh
senha_luks=teste-luks-123
log=$(mktemp -d)
trap '"$vm" desligar; rm -rf "$log"' EXIT

con() { python3 -I tests/vm/console.py "$VM_DIR/serial.sock" "$@"; }

# Roda um script como root na VM; o script vai pela entrada padrão, depois da
# senha do sudo, para não brigar com aspas.
root() { printf 'teste-sudo-123\n%s\n' "$1" | "$vm" ssh "sudo -S -p '' bash -s"; }

espera_ssh() {
    for _ in $(seq 60); do "$vm" ssh true 2>/dev/null && return; sleep 5; done
    echo "FALHOU: o SSH da VM não voltou" >&2
    exit 1
}

# Liga o console antes de reiniciar: o MokManager só espera 10 segundos.
reinicia() {
    (con "$@" > "$log/console.txt" 2>&1) &
    local p=$!
    sleep 1
    root 'systemctl reboot' || true
    wait "$p" || { cat "$log/console.txt" >&2; exit 1; }
    cat "$log/console.txt"
}

playbook() {
    uv run ansible-playbook -i tests/vm/inventario.yml site.yml "$@" </dev/null 2>&1 | cat || true
}

recap() {
    grep -qE "vm-sb +: ok=[0-9]+ +changed=$2 +unreachable=0 +failed=0" "$1" \
        || { echo "FALHOU: $3" >&2; grep -B2 -A12 -E '^fatal|^\[ERROR\]|FAILED!' "$1" >&2 || tail -30 "$1" >&2; exit 1; }
}

confere() {
    if root "$2" >/dev/null 2>&1; then
        echo "   ok   $1"
    else
        echo "FALHOU: $1" >&2
        exit 1
    fi
}

stub='test -e /sys/firmware/efi/efivars/StubInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f'

echo "== VM recém-instalada, Secure Boot desligado"
"$vm" restaurar
"$vm" ligar
con luks "$senha_luks"
espera_ssh
confere "Secure Boot desligado" 'mokutil --sb-state | grep -q disabled'

echo "== simulação (--check) num servidor recém-instalado"
playbook --check --diff | tee "$log/0.txt" | tail -n 3
recap "$log/0.txt" '[1-9][0-9]*' "o --check quebrou"
confere "o --check não gerou chave" '! test -e /etc/kernel/servidor-debian/db.key'

echo "== primeira passada (TPM2, chave, UKI, boot de teste, pedido de MOK)"
# O boot de teste acontece no meio da passada; o console confere que o TPM
# abriu o disco sozinho pelo caminho novo.
(con sem-senha 1800 > "$log/boot1.txt" 2>&1) &
console=$!
playbook | tee "$log/1.txt" | tail -n 3
recap "$log/1.txt" '[1-9][0-9]*' "a primeira passada falhou"
wait "$console" || { cat "$log/boot1.txt" >&2; echo "FALHOU: o boot de teste pediu a senha" >&2; exit 1; }
confere "boot atual pelo UKI" "$stub"
confere "servidor-debian em primeiro" '
    n=$(efibootmgr | sed -n "s/^Boot\([0-9A-F]*\)\*\? servidor-debian.*/\1/p")
    efibootmgr | grep -q "^BootOrder: $n"'
confere "UKI assinado pela chave" '
    ls /boot/efi/EFI/Linux/*.efi
    for f in /boot/efi/EFI/Linux/*.efi; do sbverify --cert /etc/kernel/servidor-debian/db.crt "$f" || exit 1; done'
confere "chave pedida no MOK" 'mokutil --list-new | grep -q "vm-sb Secure Boot"'
confere "GRUB sem mexer na NVRAM" 'debconf-show grub-efi-amd64 | grep -q "update_nvram: false"'

echo "== confirma a chave no MokManager"
reinicia mok teste123
con boot "$senha_luks"
espera_ssh
confere "chave no MOK" 'mokutil --test-key /etc/kernel/servidor-debian/db.der | grep -q "already enrolled"'

echo "== liga o Secure Boot (chaves de fábrica)"
"$vm" secure-boot
"$vm" ligar
# O PCR 7 mudou: o slot gravado com o Secure Boot desligado não abre mais.
con pede-senha "$senha_luks"
espera_ssh
confere "Secure Boot ligado" 'mokutil --sb-state | grep -q enabled'
confere "boot pelo UKI com Secure Boot" "$stub"
confere "kernel em lockdown" 'grep -Eq "\[(integrity|confidentiality)\]" /sys/kernel/security/lockdown'

echo "== segunda passada (refaz o slot do TPM2)"
playbook | tee "$log/2.txt" | tail -n 3
recap "$log/2.txt" '[1-9][0-9]*' "a segunda passada falhou"
grep -A2 'Apaga os slots do TPM2' "$log/2.txt" | grep -q '^changed' \
    || { echo "FALHOU: o slot velho não foi apagado" >&2; exit 1; }

echo "== terceira passada (idempotência)"
playbook | tee "$log/3.txt" | tail -n 3
recap "$log/3.txt" 0 "a terceira passada mudou algo"

echo "== o disco abre sozinho pelo caminho novo"
reinicia sem-senha
espera_ssh

echo "== e não abre pelo GRUB (o que um pendrive Debian ou um GRUB editado fariam)"
root 'efibootmgr --quiet --bootnext "$(efibootmgr | sed -n "s/^Boot\([0-9A-F]*\)\*\? debian.*/\1/p" | head -1)"'
reinicia pede-senha "$senha_luks"
espera_ssh
confere "voltou pelo GRUB, sem UKI" "! $stub"

echo "== atualização de kernel gera UKI assinado sozinha"
root 'apt-get install -y --reinstall "linux-image-$(uname -r)"' >/dev/null
confere "nenhum UKI a refazer" 'test -z "$(/usr/local/sbin/servidor-uki)"'
reinicia sem-senha
espera_ssh
confere "boot pelo UKI novo" "$stub"

echo "== tudo certo"
