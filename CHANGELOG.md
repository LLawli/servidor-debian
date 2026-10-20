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
- Módulo `secure_boot`: chave própria do servidor, UKI assinado carregado pelo
  shim e pelo systemd-boot, cadastro da chave pelo MOK e boot de teste com volta
  automática ao GRUB. Com ele, o TPM2 só abre o disco no boot do próprio servidor.
- O role `confiabilidade` refaz o slot do TPM2 quando ele não abre mais o disco
  (por exemplo, depois de ligar o Secure Boot).
- Teste de ponta a ponta do Secure Boot numa VM com OVMF, swtpm e LUKS
  (`tests/vm`), instalada por preseed.

### Corrigido

- `--check` num servidor recém-instalado: instala o `python3-apt` antes de tudo e
  não tenta ligar units nem reiniciar serviços que só existiriam depois de aplicar.
  O teste em contêiner agora roda uma simulação antes da primeira passada.
- Interface Wi-Fi sem `economia_energia` no `host_vars` quebrava o role `rede`
  (`object of type 'dict' has no attribute 'economia_energia'`). O teste ganhou
  uma simulação com Wi-Fi, e um playbook que falha agora mostra o erro em vez de
  encerrar o teste calado.
- O role `rede` montava o nome do serviço do Wi-Fi como `wpa_supplicant@\1.service`
  (o grupo do `regex_replace` não era substituído), então achava que a rede tinha
  mudado e a reaplicava em toda passada. A conferência dos serviços também deixava
  passar um serviço parado: `systemctl is-active` com várias units sai com 0 se uma
  só estiver ativa. Agora cada unit é conferida pela sua linha.
