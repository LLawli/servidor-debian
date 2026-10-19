# Arquitetura

## Layout

- `site.yml`: um play só, com os roles em ordem. Os que podem derrubar o SSH
  (`rede`, `firewall`) vêm por último, depois de todos os pacotes instalados.
- `group_vars/all.yml`: `servidor_modulos` (o que se aplica) e
  `servidor_em_container` (pula o que mexe no kernel do host).
- `inventory/<nome>.yml` e `host_vars/<nome>.yml`: um par por servidor,
  gerado por `bin/novo-servidor`, fora do git. Só os `.example` são versionados.
- `roles/retorno`: não é um módulo, é a rede de segurança usada por `rede` e
  `firewall` via `include_role` (`foto`, `armar`, `confirmar`, `desarmar`,
  `falhou`, `descartar`).

## O ponto de retorno

Sequência em `rede` e `firewall`:

1. `foto`: tar dos caminhos que o role pode mudar (inclui `/etc/systemd/system`,
   para restaurar também quais units estão ligadas).
2. Escreve os arquivos. Se nada mudou, `descartar` e fim.
3. `armar`: `systemd-run --on-active=120s servidor-debian-retorno restaurar ...`,
   um timer transitório que, se disparar, apaga os caminhos, extrai a foto e
   reinicia. Reiniciar (em vez de reiniciar serviços) garante que o boot suba
   uma configuração coerente, inclusive com ifupdown de volta.
4. Aplica. Na rede, o script roda com `async`/`poll: 0`, porque a própria
   conexão SSH cai no meio.
5. `confirmar`: `reset_connection` e `wait_for_connection`. Só uma conexão
   nova prova que o SSH continua acessível; a antiga sobrevive a quase tudo
   (`ct state established` no firewall).
6. Conferências (resultado do script, serviços ativos, nenhuma interface em
   `failed`, cada interface com endereço). Só então `desarmar`.
7. Qualquer falha cai no `rescue`, que chama `falhou`: avisa e deixa o timer
   armado.

A conferência de endereço existe porque o networkd ignora em silêncio uma linha
`Address=` inválida: o serviço fica ativo, a interface não entra em `failed`, e
só falta o IP.

## Decisões

- **Ansible, rodando do laptop.** Idempotente, com `--check --diff` para ver
  antes de aplicar. Nenhum agente no servidor.
- **Pós-instalação, sem preseed.** A instalação é guiada pelo README; o
  provisionamento começa no primeiro SSH. Reabrir se instalar à mão virar o
  gargalo.
- **Fontes do apt no codinome** (`forky`), nunca `testing`/`stable`: o servidor
  não muda de versão sozinho. Formato deb822 em `sources.list.d/debian.sources`;
  o `sources.list` antigo vira `sources.list.servidor-debian`.
- **Bateria:** usa `charge_control_end_threshold` quando o firmware tem; senão
  alterna `charge_types` entre `Standard` e `Long_Life` (o Lenovo IdeaPad só
  tem esses dois modos, sem limite numérico).
- **Teste em Podman rootless**, não Docker: o systemd precisa de cgroup
  gravável, que o Docker só dá com `--privileged` (e então o `/sys` gravável
  alcança o kernel do host). No Podman rootless, `NET_ADMIN`, `NET_RAW` e
  `SYS_ADMIN` valem só dentro do namespace de usuário. O networkd precisa de
  `SYS_ADMIN` para o próprio sandbox e de `NET_RAW` para o LLDP.
- No contêiner, `servidor_em_container` pula o `sysctl -w` (o `kernel.panic`
  não tem namespace e mudaria o host) e o TPM.

## O que o teste não cobre

Wi-Fi (não há rádio no contêiner), watchdog (não há `/dev/watchdog0`), TPM2 e
o limite de bateria em si (o script é instalado e o timer ligado, mas não há
`/sys/class/power_supply`). Esses foram validados no servidor de impressão.
