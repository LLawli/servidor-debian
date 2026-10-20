#!/usr/bin/env bash
# Todos os portões do projeto; o CI roda este mesmo script.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== dependências"
uv sync --locked --quiet
uv run ansible-galaxy collection install -r requirements.yml </dev/null 2>&1 | cat

echo "== formato (yamllint)"
uv run yamllint --strict .

echo "== shellcheck"
# Sempre a versão fixada: o runner do CI traz um shellcheck mais antigo, que
# acusa coisas que a 0.11 não acusa (e vice-versa).
shellcheck() { docker run --rm -v "$PWD:/mnt:ro" -w /mnt docker.io/koalaman/shellcheck:v0.11.0 "$@"; }
shellcheck bin/* scripts/*.sh tests/*/*.sh roles/*/files/servidor-debian-retorno roles/base/files/confere-dkms \
    roles/secure_boot/files/servidor-uki
# O console da VM de teste (Python, só biblioteca padrão) precisa ao menos compilar.
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' tests/vm/console.py

echo "== lint (ansible-lint, perfil production)"
uv run ansible-lint --strict </dev/null 2>&1 | cat; test "${PIPESTATUS[0]}" -eq 0

echo "== sintaxe"
uv run ansible-playbook -i tests/container/inventario.yml site.yml --syntax-check </dev/null 2>&1 | cat
test "${PIPESTATUS[0]}" -eq 0

echo "== testes (Debian em contêiner)"
tests/container/testar.sh

echo "== auditoria de dependências (pip-audit)"
requisitos=$(mktemp)
trap 'rm -f "$requisitos"' EXIT
uv export --locked --all-groups --format requirements-txt --quiet >"$requisitos"
uv run pip-audit --strict --disable-pip -r "$requisitos" 2>&1 | cat; test "${PIPESTATUS[0]}" -eq 0

echo "== ci verde"
