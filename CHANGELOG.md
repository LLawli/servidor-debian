# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [Unreleased]

### Adicionado

- Módulos `base`, `confiabilidade`, `notebook`, `rede` e `firewall`, ligados por
  servidor em `servidor_modulos`.
- Ponto de retorno para rede e firewall: foto da configuração, restauração e
  reinício automáticos se uma conexão SSH nova não entrar em 2 minutos.
- `bin/novo-servidor`, que copia a chave SSH, detecta o hardware e gera o
  inventário e o `host_vars` do servidor.
- `bin/provisionar`, atalho para aplicar o `site.yml` a um servidor.
- Guia da instalação do Debian esperada (UEFI, LUKS com LVM, btrfs, tasksel).
- `scripts/ci.sh` com todos os portões e teste num Debian com systemd em Podman.
