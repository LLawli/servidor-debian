#!/usr/bin/env bash
# Aplica site.yml duas vezes num Debian com systemd em contêiner e confere
# o resultado: a segunda passada tem que terminar sem nenhuma mudança.
set -euo pipefail
cd "$(dirname "$0")/../.."

codinome=${CODINOME:-forky}
imagem=servidor-debian-teste:$codinome
nome=servidor-debian-teste
log=$(mktemp -d)
trap 'podman rm -f "$nome" >/dev/null 2>&1 || true; rm -rf "$log"' EXIT

podman build -q --build-arg CODINOME="$codinome" -f tests/container/Containerfile -t "$imagem" tests/container >/dev/null
podman rm -f "$nome" >/dev/null 2>&1 || true
# Podman rootless roda o systemd sem --privileged.
# NET_ADMIN, NET_RAW e SYS_ADMIN valem só dentro do namespace de usuário do contêiner:
# bastam para nftables, a interface dummy, o LLDP e o sandbox do systemd-networkd.
podman run -d --name "$nome" --systemd=always --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN "$imagem" >/dev/null
podman exec "$nome" timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true
podman exec "$nome" ip link add teste0 type dummy

playbook() {
    uv run ansible-playbook -i tests/container/inventario.yml site.yml "$@" </dev/null 2>&1 | cat
}

echo "== simulação (--check) num servidor zerado"
playbook --check --diff | tee "$log/0.txt" | tail -n 4
grep -qE 'teste-container +: ok=[0-9]+ +changed=[1-9][0-9]* +unreachable=0 +failed=0' "$log/0.txt" \
    || { echo "FALHOU: o --check quebrou ou não previu mudança" >&2; grep -A8 -E '^fatal' "$log/0.txt" >&2; exit 1; }
for f in /etc/systemd/network/20-teste0.network /etc/ssh/sshd_config.d/10-sem-senha.conf /usr/local/sbin/confere-dkms /usr/local/sbin/limite-bateria; do
    if podman exec "$nome" test -e "$f"; then
        echo "FALHOU: o --check escreveu $f" >&2
        exit 1
    fi
done

echo "== primeira passada"
playbook | tee "$log/1.txt" | tail -n 4
grep -qE 'teste-container +: ok=[0-9]+ +changed=[1-9][0-9]* +unreachable=0 +failed=0' "$log/1.txt" \
    || { echo "FALHOU: a primeira passada não aplicou nada ou falhou" >&2; cat "$log/1.txt" >&2; exit 1; }

echo "== segunda passada (idempotência)"
playbook | tee "$log/2.txt" | tail -n 4
grep -qE 'teste-container +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0' "$log/2.txt" \
    || { echo "FALHOU: a segunda passada mudou algo" >&2; grep -B3 -E '^changed:' "$log/2.txt" >&2; exit 1; }

echo "== conferências"
falhas=0
confere() {
    local descricao=$1
    shift
    if podman exec "$nome" sh -c "$*" >/dev/null 2>&1; then
        echo "   ok   $descricao"
    else
        echo "   FALHA $descricao" >&2
        falhas=$((falhas + 1))
    fi
}
confere "ssh sem senha"            "sshd -T | grep -qix 'passwordauthentication no'"
confere "ssh sem root"             "sshd -T | grep -qix 'permitrootlogin no'"
confere "chave autorizada"         "grep -q teste@servidor-debian /root/.ssh/authorized_keys"
confere "fontes no codinome"       "grep -q '^Suites: $codinome' /etc/apt/sources.list.d/debian.sources"
confere "conferidor DKMS"          "test -x /usr/local/sbin/confere-dkms"
confere "kernel.panic no sysctl.d" "grep -qx 'kernel.panic=10' /etc/sysctl.d/90-servidor.conf"
confere "alvo multi-user"          "test \"\$(systemctl get-default)\" = multi-user.target"
confere "suspensão mascarada"      "test \"\$(systemctl is-enabled suspend.target)\" = masked"
confere "tampa ignorada"           "grep -qx 'HandleLidSwitch=ignore' /etc/systemd/logind.conf.d/10-servidor.conf"
confere "limite de bateria ligado" "systemctl is-enabled -q limite-bateria.timer"
confere "IP estático do networkd"  "ip -4 addr show teste0 | grep -q 10.99.0.1/24"
confere "networkd ligado"          "systemctl is-enabled -q systemd-networkd"
confere "firewall carregado"       "nft list chain inet filtro zona_lan | grep -q 'tcp dport { 22, 631 }'"
confere "política drop na entrada" "nft list chain inet filtro entrada | grep -q 'policy drop'"
confere "nenhum retorno armado"    "! systemctl list-timers --all | grep -q servidor-debian-retorno"

[ "$falhas" -eq 0 ] || { echo "FALHOU: $falhas conferência(s)" >&2; exit 1; }
echo "== tudo certo"
