#!/usr/bin/env bash
# VM de teste do Secure Boot: um Debian instalado por preseed, com UEFI (OVMF),
# TPM2 (swtpm) e LUKS, rodando num contêiner Podman com KVM.
#
#   tests/vm/vm.sh instalar      instala do zero (Secure Boot desligado, como o notebook chega)
#   tests/vm/vm.sh restaurar     volta ao estado logo depois da instalação
#   tests/vm/vm.sh ligar         liga a VM; o console serial fica em $DIR/serial.sock
#   tests/vm/vm.sh desligar      desliga
#   tests/vm/vm.sh secure-boot   "entra na BIOS": grava as chaves de fábrica e liga o Secure Boot
#   tests/vm/vm.sh ssh [cmd]     entra na VM
#
# Os arquivos da VM ficam no SSD de dados, fora do repo.
set -euo pipefail
cd "$(dirname "$0")"

DIR=${VM_DIR:-/mnt/dados/caches/vms/servidor-debian-sb}
IMAGEM=servidor-debian-vm
NOME=servidor-debian-vm
# As imagens diárias acompanham o kernel do testing; a "current" fica para trás.
NETBOOT=https://d-i.debian.org/daily-images/amd64/daily/netboot/debian-installer/amd64

contem() {
    podman run --rm --userns=keep-id -v "$DIR:/vm" --entrypoint "$1" "$IMAGEM" "${@:2}"
}

construir() {
    podman build -q -f Containerfile -t "$IMAGEM" . >/dev/null
}

instalar() {
    construir
    mkdir -p "$DIR"
    rm -rf "$DIR/tpm" "$DIR/instalado" "$DIR/disco.qcow2" "$DIR/vars.fd" "$DIR/instalacao.log" "$DIR"/*.sock
    [ -f "$DIR/chave" ] || ssh-keygen -q -t ed25519 -N '' -C teste@vm-sb -f "$DIR/chave"
    curl -fsSL -o "$DIR/linux" "$NETBOOT/linux"
    curl -fsSL -o "$DIR/initrd.gz" "$NETBOOT/initrd.gz"
    # O preseed e a chave entram no initrd do instalador (preseed/file).
    local extra
    extra=$(mktemp -d)
    cp preseed.cfg "$extra/preseed.cfg"
    cp "$DIR/chave.pub" "$extra/chave.pub"
    (cd "$extra" && printf '%s\n' preseed.cfg chave.pub | cpio -o -H newc --quiet | gzip) > "$DIR/extra.gz"
    rm -rf "$extra"
    cat "$DIR/initrd.gz" "$DIR/extra.gz" > "$DIR/initrd-preseed.gz"
    contem qemu-img create -q -f qcow2 /vm/disco.qcow2 16G
    # NVRAM sem chaves: Secure Boot desligado.
    contem cp /usr/share/OVMF/OVMF_VARS_4M.fd /vm/vars.fd
    podman rm -f "$NOME" >/dev/null 2>&1 || true
    podman run -d --name "$NOME" --userns=keep-id --device /dev/kvm -v "$DIR:/vm" "$IMAGEM" \
        -serial file:/vm/instalacao.log -no-reboot \
        -kernel /vm/linux -initrd /vm/initrd-preseed.gz \
        -append "auto=true priority=critical preseed/file=/preseed.cfg locale=en_US.UTF-8 keymap=br hostname=vm-sb domain= console=ttyS0,115200n8 DEBIAN_FRONTEND=text" >/dev/null
    # Uma pergunta que o preseed não respondeu trava o instalador para sempre:
    # se o fim do log for um prompt por 2 minutos, para e mostra a pergunta.
    local parado=0
    while [ "$(podman inspect -f '{{.State.Running}}' "$NOME" 2>/dev/null)" = true ]; do
        sleep 10
        if tail -c 300 "$DIR/instalacao.log" | grep -aq "Prompt: '?' for help"; then
            parado=$((parado + 10))
        else
            parado=0
        fi
        if [ "$parado" -ge 120 ]; then
            podman rm -f "$NOME" >/dev/null
            echo "FALHOU: o instalador parou numa pergunta:" >&2
            tail -c 1500 "$DIR/instalacao.log" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr '\r' '\n' | grep -av '^\s*$' | tail -15 >&2
            exit 1
        fi
    done
    podman rm -f "$NOME" >/dev/null 2>&1 || true
    grep -aq 'reboot: Restarting system\|reboot: Power down' "$DIR/instalacao.log" \
        || { echo "FALHOU: a instalação não terminou; veja $DIR/instalacao.log" >&2; exit 1; }
    # O log pode mentir; o disco não: um Debian instalado passa de 1 GB.
    local tamanho
    tamanho=$(stat -c %s "$DIR/disco.qcow2")
    [ "$tamanho" -gt 1000000000 ] \
        || { echo "FALHOU: o disco tem só $tamanho bytes depois da instalação" >&2; exit 1; }
    # Cópia do recém-instalado, para cada teste partir dele sem reinstalar.
    rm -rf "$DIR/instalado"
    mkdir -p "$DIR/instalado"
    cp --reflink=auto -a "$DIR/disco.qcow2" "$DIR/vars.fd" "$DIR/tpm" "$DIR/instalado/"
}

restaurar() {
    desligar
    [ -d "$DIR/instalado" ] || { echo "FALHOU: não há instalação salva; rode $0 instalar" >&2; exit 1; }
    rm -rf "$DIR/tpm"
    cp --reflink=auto -a "$DIR/instalado/disco.qcow2" "$DIR/instalado/vars.fd" "$DIR/instalado/tpm" "$DIR/"
}

ligar() {
    construir
    podman rm -f "$NOME" >/dev/null 2>&1 || true
    rm -f "$DIR/serial.sock" "$DIR/monitor.sock"
    podman run -d --name "$NOME" --userns=keep-id --device /dev/kvm -v "$DIR:/vm" \
        -p 127.0.0.1:2222:2222 "$IMAGEM" \
        -chardev "socket,id=ser,path=/vm/serial.sock,server=on,wait=off,logfile=/vm/serial.log,logappend=on" \
        -serial chardev:ser >/dev/null
    for _ in $(seq 50); do [ -S "$DIR/serial.sock" ] && return; sleep 0.2; done
    echo "FALHOU: o QEMU não abriu o console serial" >&2
    podman logs "$NOME" >&2
    exit 1
}

desligar() {
    podman stop -t 20 "$NOME" >/dev/null 2>&1 || true
    podman rm -f "$NOME" >/dev/null 2>&1 || true
}

secure_boot() {
    desligar
    # Como um notebook de fábrica: PK do fabricante, KEK e db da Microsoft.
    # As variáveis do shim (MokList) continuam na NVRAM.
    contem virt-fw-vars --inplace /vm/vars.fd --enroll-microsoft --sb
}

case ${1:-} in
    instalar) instalar ;;
    restaurar) restaurar ;;
    ligar) ligar ;;
    desligar) desligar ;;
    secure-boot) secure_boot ;;
    ssh) shift; exec ssh -i "$DIR/chave" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR developer@127.0.0.1 "$@" ;;
    *) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
