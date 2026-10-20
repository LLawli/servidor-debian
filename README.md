# servidor-debian

Montar um servidor Debian de uso geral à mão leva horas e sai um pouco
diferente a cada vez. Este projeto é para quem administra alguns servidores
Debian pequenos (inclusive notebooks velhos usados como servidor): depois de
instalar o Debian, um comando a partir do seu computador deixa o servidor com
SSH só por chave, rede no systemd-networkd, firewall de menor privilégio, LUKS
desbloqueado pelo TPM2 e watchdog, sempre igual.

## 1. Instalar o Debian (o ambiente esperado)

O provisionamento parte de uma instalação mínima feita com o instalador
oficial. As escolhas abaixo são as do servidor de impressão, que já roda assim.

**Mídia e firmware**

- Imagem `netinst` amd64 do Debian. O projeto segue o codinome que estiver
  instalado (forky, trixie...): instale a versão que o servidor deve ficar.
- Inicialização em **UEFI**. Se a BIOS tiver modo legado/CSM, desligue.
- Ligue o **TPM** (fTPM/PTT) na BIOS, se quiser o desbloqueio automático do
  disco. Aproveite e procure uma opção de ligar sozinho quando voltar a energia
  ("Power on with AC attach" ou parecida).
- Wi-Fi com chip Realtek ou outro que precise de firmware: a `netinst` atual já
  inclui o firmware não livre; se o instalador pedir, aceite carregar.

**Perguntas do instalador**

| Pergunta | Resposta |
|---|---|
| Idioma, local, teclado | Português do Brasil, Brasil, ABNT2 |
| Nome da máquina | o nome curto do servidor (vira o hostname) |
| Senha do root | **deixe em branco**: o root fica sem senha e o primeiro usuário entra no sudo |
| Usuário | o usuário de administração (o servidor de impressão usa `developer`) |
| Rede | a rede onde o servidor vai ficar; anote o IP que ele pegar |

**Particionamento**: "Assistido: usar o disco inteiro e configurar LVM
criptografado", com todos os arquivos numa partição. Depois ajuste na tela de
resumo para chegar a isto:

| Partição | Tamanho | Uso |
|---|---|---|
| ESP | ~1 GB | `vfat`, `/boot/efi` |
| `/boot` | ~2 GB | `ext4`, fora do LUKS (o kernel e o initramfs com o clevis ficam aqui) |
| LUKS | o resto | volume criptografado, com LVM dentro (grupo `vg0`) |
| `vg0-root` | ~65% do LUKS | `btrfs`, `/` (o instalador cria o subvolume `@rootfs`) |
| `vg0-swap` | ~RAM, até 8 GB | `swap` |
| livre no `vg0` | o resto | espaço reservado para crescer um volume ou criar outro depois |

- Use uma **senha de LUKS forte e guarde-a**: o TPM2 é um slot a mais; a senha
  continua sendo a forma de abrir o disco se o TPM mudar (troca de placa,
  atualização de BIOS, Secure Boot ligado ou desligado).
- Deixar espaço livre no LVM é de propósito: ampliar um volume depois é um
  comando; diminuir um btrfs ou ext4 com o servidor rodando, não.
- **Opções de montagem**: deixe as que o instalador propõe. `/boot` (ext4) e
  `/boot/efi` (vfat, com `umask=0077`) ficam em `defaults`, sem nada a marcar.
  Só o `/` em btrfs ganha `noatime,compress`; se o instalador não oferecer,
  acrescente no `/etc/fstab` depois do primeiro boot.

**Seleção de software (tasksel)**: marque só **servidor SSH** e **utilitários
padrão do sistema**. Desmarque o ambiente de desktop e o GNOME. Num notebook o
instalador marca "laptop" sozinho; pode deixar.

**GRUB**: instale no disco principal (em UEFI, ele vai para a ESP).

No primeiro boot ainda vai pedir a senha do LUKS no console; depois do
provisionamento com `confiabilidade_tpm: true`, não pede mais.

## 2. Provisionar

Do seu computador, com [uv](https://docs.astral.sh/uv/) instalado:

```sh
git clone https://github.com/LLawli/servidor-debian && cd servidor-debian
uv sync
uv run ansible-galaxy collection install -r requirements.yml
```

**Cadastrar o servidor** (uma vez por servidor):

```sh
bin/novo-servidor <nome> <ip> [usuario]
```

Ele copia sua chave SSH (pede a senha do usuário uma única vez), detecta a
interface de rede, se ela é Wi-Fi, a bateria, o TPM2, o LUKS e o watchdog, e
escreve `inventory/<nome>.yml` e `host_vars/<nome>.yml` já preenchidos. Se a
interface for Wi-Fi, pergunta o SSID e a senha. Os dois arquivos ficam fora do
git; `host_vars/exemplo.yml.example` mostra todas as opções.

**Conferir e aplicar**:

```sh
bin/provisionar <nome> --check --diff   # mostra o que mudaria, sem mudar
bin/provisionar <nome>                  # aplica
bin/provisionar <nome> --tags firewall  # só um módulo
```

Pede a senha do sudo do servidor, que não é gravada. Na primeira aplicação com
`confiabilidade_tpm: true`, pede também a senha do LUKS, para gravar o slot do
TPM2. Rodar de novo é seguro: o que já está certo não muda.

## O que cada módulo faz

Os módulos ficam em `servidor_modulos`, no `host_vars` de cada servidor.

| Módulo | O que deixa pronto |
|---|---|
| `base` | SSH só por chave e sem root, admin no sudo, fontes do apt fixas no codinome, aviso de módulo DKMS sem build, kernel travado (opcional) |
| `confiabilidade` | watchdog de hardware, reinício depois de kernel panic, boot em `multi-user.target`, LUKS desbloqueado pelo TPM2 (opcional) |
| `secure_boot` | kernel, initramfs e linha do kernel num UKI assinado por uma chave do servidor, carregado pelo shim e pelo systemd-boot; o TPM2 só abre o disco nesse boot (opcional, veja abaixo) |
| `notebook` | tampa e teclas de suspensão ignoradas, suspensão mascarada, carga da bateria numa faixa (75 a 80% por padrão), desligamento com 5% |
| `rede` | systemd-networkd no lugar do ifupdown, Wi-Fi pelo wpa_supplicant sem economia de energia, DNS fixo |
| `firewall` | nftables com entrada bloqueada, liberando por interface só as portas e origens listadas |

## Secure Boot com chave própria

Só o TPM2 não protege o disco de quem estiver com o notebook nas mãos: com o
PCR 7 e as chaves de fábrica, um pendrive com Debian, ou o GRUB com
`break=bottom` na linha do kernel, chega ao mesmo estado e o disco abre
sozinho. O módulo `secure_boot` fecha isso: gera uma chave no servidor, assina
com ela um UKI (kernel, initramfs e linha do kernel num arquivo só) e cadastra
a chave no shim pelo MOK. As chaves de fábrica da placa continuam; só o boot
assinado pela chave do servidor chega ao PCR 7 que abre o disco.

São três passos, dois deles no console do servidor:

1. `bin/provisionar <nome>` com `secure_boot` em `servidor_modulos`. O servidor
   reinicia uma vez pelo caminho novo para testar; se o boot falhar, ele volta
   sozinho pelo GRUB e nada muda. No fim, pede uma senha de uso único (só
   letras e números).
2. No servidor, com tela e teclado: reinicie, aperte uma tecla na tela azul
   (são 10 segundos), escolha **Enroll MOK**, **Continue**, **Yes**, digite a
   senha de uso único e **Reboot**. Entre na BIOS e ligue o **Secure Boot**,
   com as chaves de fábrica. O primeiro boot depois disso pede a senha do LUKS.
3. `bin/provisionar <nome>` de novo: ele refaz o slot do TPM2 para o boot com
   Secure Boot (pede a senha do LUKS uma vez).

Depois disso, atualizações de kernel geram e assinam o UKI sozinhas. O GRUB
continua no menu de boot do firmware como reserva, abrindo o disco só com a
senha. Uma atualização da BIOS ou do dbx muda o PCR 7: o boot volta a pedir a
senha, e rodar o provisionar de novo refaz o slot.

## Se a rede ou o firewall der errado

Antes de mexer na rede ou no firewall, o playbook tira uma foto da
configuração e arma um timer: se em 2 minutos uma conexão SSH nova não entrar
e a conferência não passar, o servidor restaura a foto e reinicia sozinho. Um
firewall que não libera a porta do SSH é recusado antes de ser aplicado. As
fotos ficam em `/var/backups/servidor-debian/`.

## Desenvolvimento

`scripts/ci.sh` roda todos os portões (yamllint, shellcheck, ansible-lint,
sintaxe, o teste num Debian com systemd em Podman e o pip-audit); o CI roda o
mesmo script. O módulo `secure_boot` precisa de UEFI, TPM2 e reboot, e é
testado à parte numa VM com KVM (`tests/vm/vm.sh instalar` uma vez, depois
`tests/vm/testar.sh`). Arquitetura e decisões estão em
[`docs/`](docs/arquitetura.md).

## Licença

MIT.
