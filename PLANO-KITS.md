# Documento de design — família de kits

Referência de manutenção dos instaladores deste repositório. Explica **por que**
o código é como é, para que alterações futuras não desfaçam decisões tomadas de
propósito.

## Contexto

O repositório começou com dois scripts que resolviam o problema pela metade:

- **`post-installation.sh`** — herdado do `pop-os-postinstall` do Diolinux. Sem
  `set` flags, sem idempotência, instala tudo cegamente num laço, mistura apps
  de desktop com ferramentas de desenvolvimento, e remove travas do APT com `rm`
  direto em `/var/lib/dpkg/lock-frontend`.
- **`install_dev_env.sh`** — mais correto (usa `is_installed`, chaveiros com
  `signed-by`), mas linear, sem cores, sem log, sem interação, e com `set -e`:
  a falha de um único pacote derruba a execução inteira.

O `devkit.sh` substituiu essa abordagem por um instalador interativo orientado a
dados. Quando surgiu o segundo kit (`utilitieskit.sh`), ficou evidente que
~700 das 1540 linhas do DevKit eram **motor genérico**, não específicas de
desenvolvimento. Copiar isso para cada kit novo significaria manter o mesmo
código em N cópias e replicar cada correção N vezes.

Daí a arquitetura atual: **um motor em `lib/kit-common.sh` e kits finos**.

## Arquitetura

```
lib/kit-common.sh     motor: log, helpers, verificações, registry,
                      orquestrador, menu, resumo, flags        (~1.150 linhas)

devkit.sh             16 componentes de desenvolvimento          (~510 linhas)
utilitieskit.sh       21 aplicativos de uso diário               (~400 linhas)

tests/run-tests.sh    88 asserções sobre o motor
```

Um kit não implementa nada de infraestrutura. Ele declara sua identidade,
carrega a biblioteca, define as funções `install_*()` e registra os componentes.

### Contrato de um kit

```bash
readonly KIT_ID='utilitieskit'
readonly KIT_NAME='Ubuntu UtilitiesKit Installer'
readonly KIT_VERSION='1.0.0'
readonly KIT_LOG_DEFAULT="${HOME}/utilities-install.log"
readonly KIT_DESCRIPTION='...'
readonly KIT_AUTO_NOTE='...'          # opcional

source "$(dirname "${BASH_SOURCE[0]}")/lib/kit-common.sh"

install_algo() { ...; }

register_components() {
    register_component algo 'Algo' 'Categoria' install_algo algo 'algo --version' 'amd64 arm64'
}

kit_main "$@"
```

`KIT_ID` também gera os marcadores dos blocos que o kit injeta em `.bashrc` /
`.zshrc`, para que cada um gerencie apenas o próprio bloco.

### Criar um kit novo (Multimídia, Jogos, Design, Segurança...)

Copie o cabeçalho de qualquer kit existente, troque os metadados, escreva as
funções de instalação e registre os componentes. Menu, log, validação, resumo,
flags e testes de integridade do registry passam a valer automaticamente.

## Decisões de projeto

### Por que `set -e` não é usado

O requisito central é *"nunca interromper completamente a execução caso um
pacote falhe"*. Isso é incompatível com `errexit`, que aborta no primeiro
comando com status diferente de zero. O motor usa `set -uo pipefail` e faz o
controle de erro explicitamente: cada `install_*()` devolve um código e
`install_component()` transforma falha em **estado** (entra no resumo), não em
interrupção. Nenhuma função de instalação chama `exit`.

Um módulo tem três desfechos possíveis, e a distinção importa:

| Desfecho | Como sinalizar | Vai para |
|---|---|---|
| Instalou | `return 0` | Concluídos |
| Tentou e falhou | `return != 0` | Falharam (saída do script vira 1) |
| Não se aplica aqui | `skip_component 'motivo'; return 0` | Ignorados |

O terceiro caso existe porque "não há pacote 7-Zip nesta versão do Ubuntu" ou
"o projeto Stacer não publica releases há anos" não é um erro de execução — é
uma constatação. Tratar isso como falha poluiria o resumo e o código de saída.

### Por que o .NET não vem do `packages.microsoft.com`

A especificação original pedia "adicionar o repositório oficial da Microsoft". A
documentação da Microsoft (`learn.microsoft.com/dotnet/core/install/linux-ubuntu-install`,
revisada em 23/04/2026) afirma explicitamente que **o feed
`packages.microsoft.com` não contém mais pacotes .NET para Ubuntu**, e que esse
feed é exclusivo para x64:

| Ubuntu | Feed nativo | `ppa:dotnet/backports` | Feed Microsoft |
|---|---|---|---|
| 24.04 | 10.0, 8.0 | 9.0, 7.0, 6.0 | **nenhum** |
| 22.04 | 8.0, 7.0, 6.0 | **10.0**, 9.0 | 8.0 e anteriores |

Seguir a especificação ao pé da letra instalaria um SDK desatualizado no 22.04,
nada no 24.04, e arriscaria o *package mix-up* que a própria Microsoft
documenta. `install_dotnet()` usa o feed nativo no 24.04, o
`ppa:dotnet/backports` no 22.04, e descobre o maior SDK com `apt-cache` — sem
versão fixa, então continua correto quando sair o .NET 11.

### Por que o Firefox não vem do `apt install firefox`

Em 22.04 e 24.04 o pacote `firefox` do Ubuntu é um *transitional package* que
instala o Snap. O requisito é evitar Snap, então usamos o método oficial da
Mozilla: repositório `packages.mozilla.org` **mais um pin de prioridade** em
`/etc/apt/preferences.d/mozilla`. Sem o pin o APT continua preferindo o pacote
da distribuição, e a instalação silenciosamente vira Snap de novo — por isso
`install_firefox()` confere a origem com `apt-cache policy` ao final.

### Ordem de preferência das origens

1. Repositório oficial do fabricante
2. Pacote `.deb` publicado pelo fabricante
3. Flatpak (Flathub), só quando não existe alternativa

O Flatpak e o remote Flathub são instalados **sob demanda**, apenas quando um
módulo precisa desse caminho — quem não instala Discord ou OBS nunca ganha
Flatpak na máquina.

## Helpers do motor

| Função | Responsabilidade |
|---|---|
| `run_cmd()` | Registra `[CMD]`, executa com toda a saída indo para o log, devolve o código original. Toda chamada de sistema passa por aqui |
| `run_step()` | `run_cmd` mais spinner e `[OK]`/`[ERRO]` na tela |
| `ask_yes_no()` | Prompt `[S] Sim / [N] Não`. Lê de `/dev/tty` para funcionar com a stdin redirecionada; respeita `ASSUME_YES` |
| `ask_choice()` | Menu numerado de escolha única (leitor de PDF, captura de tela) |
| `ask_multi_choice()` | Escolha múltipla, reaproveitando `parse_selection()` (componentes do LibreOffice) |
| `add_apt_repo()` | Generaliza o boilerplate de chaveiro: baixa a chave (ASCII ou binária), instala em `/etc/apt/keyrings`, escreve a entrada com `signed-by=` e atualiza o índice |
| `add_apt_pin()` | Escreve regra de prioridade em `/etc/apt/preferences.d/` |
| `apt_first_available()` | Primeiro pacote da lista com candidato instalável — resolve nomes que mudam entre LTS (`7zip` × `p7zip-full`) sem chumbar a versão da distro |
| `ensure_apt_component()` | Habilita `universe`/`multiverse` quando o pacote exigir |
| `ensure_flatpak()` / `flatpak_install()` | Flatpak sob demanda |
| `install_deb_from_url()` | Baixa `.deb` e instala com `apt-get` (resolve dependências, ao contrário de `dpkg -i`). Aceita nome de destino explícito, necessário para URLs sem extensão como a do Discord |
| `github_latest_tag()` / `github_latest_asset()` | Consultam a API do GitHub sem depender de `jq` |
| `append_once()` | Injeta bloco em `.bashrc`/`.zshrc` entre marcadores, substituindo o anterior. Reexecutar não duplica configuração nem acumula linhas em branco |
| `ensure_prereqs()` | Instala `curl`/`gnupg`/`ca-certificates` sob demanda, independente do componente "Curl" que o usuário pode ter recusado |

## O registry

```bash
register_component <id> <nome> <grupo> <função> <binário> <cmd de versão> \
                   <arquiteturas> [<teste de presença>]
```

O último argumento é opcional e substitui a checagem padrão `command -v`. Serve
para o que não expõe binário no PATH — um diretório no HOME (`~/.nvm`), um
subcomando (`docker compose`), um app Flatpak, ou uma escolha entre alternativas
(`command -v evince || command -v okular`).

A ordem do array define a ordem de instalação e resolve dependências entre
módulos: `git` antes de `gcm`, `docker` antes de `compose`, `node` antes de
`npm`, `zsh` antes de `omz`. O campo grupo agrupa a listagem do menu e, por
construção, categorias iguais ficam contíguas — a suíte de testes verifica isso.

## Fontes oficiais

### DevKit — 16 componentes

| Componente | Origem |
|---|---|
| Git | Repositório do Ubuntu, com opção pelo `ppa:git-core/ppa` dos mantenedores |
| Git Credential Manager | Releases de `git-ecosystem/git-credential-manager` (só amd64) |
| GitHub CLI | `cli.github.com/packages` |
| VS Code | `packages.microsoft.com/repos/code` — **sem Snap** |
| Docker / Compose | `download.docker.com/linux/ubuntu` |
| kubectl | `pkgs.k8s.io`, *minor* resolvida em `cdn.dl.k8s.io/release/stable.txt` |
| Minikube | `storage.googleapis.com/minikube/releases/latest` |
| .NET SDK | Feed nativo do Ubuntu ou `ppa:dotnet/backports` (ver acima) |
| NodeJS | NodeSource, linha LTS resolvida em `nodejs.org/dist/index.json` |
| NVM | Release mais recente de `nvm-sh/nvm` |
| Oh My Zsh | `install.sh` oficial, com `RUNZSH=no CHSH=no --unattended` |

### UtilitiesKit — 21 aplicativos

| Aplicativo | Origem |
|---|---|
| Firefox | `packages.mozilla.org` + pin de prioridade 1000 |
| Google Chrome | `dl.google.com/linux/chrome/deb` — só amd64 |
| Brave | `brave-browser-apt-release.s3.brave.com` |
| LibreOffice | Ubuntu, com escolha de componentes e pacote de idioma pt-BR |
| qBittorrent, VLC, GParted, GNOME Tweaks, BleachBit, Timeshift, FileZilla | Ubuntu |
| Stacer | Ubuntu → release de `oguzhaninan/Stacer` → IGNORADO |
| 7-Zip | `7zip` (24.04) ou `p7zip-full` (22.04), escolhido em tempo de execução |
| Unrar | `unrar` (multiverse, habilitado se preciso) → `unrar-free` |
| Zip | `zip` + `unzip` |
| Leitor de PDF | Escolha: Evince, Okular ou ambos |
| Captura de tela | Escolha: Flameshot, Ksnip ou ambas |
| Discord | `.deb` oficial do discord.com → Flathub |
| Telegram | Ubuntu → Flathub |
| Remmina | Ubuntu + plugins RDP e VNC |
| OBS Studio | PPA oficial `ppa:obsproject/obs-studio` → Flathub |

Nenhuma versão de kubectl, Node, .NET, 7-Zip, Stacer ou Discord está fixada no
código: todas são resolvidas em tempo de execução, com fallback declarado nas
constantes.

## Segurança e comportamento

- **Não roda como root.** `check_root()` recusa `sudo ./devkit.sh`, porque NVM,
  Oh My Zsh e a inclusão no grupo `docker` precisam do `$HOME` e do `$USER`
  reais — sob `sudo` seriam aplicados ao root. O `sudo` é pedido só onde é
  necessário, e o ticket é renovado em segundo plano para o script não travar
  pedindo senha no meio de uma instalação longa.
- **O shell padrão nunca muda sozinho.** A troca para Zsh usa
  `ASSUME_YES=0 ask_yes_no ...`, que força a pergunta mesmo em `--all --yes`.
- **Chaveiros por repositório** em `/etc/apt/keyrings` com `signed-by=`, sem
  `apt-key` (obsoleto) e sem chave global confiada para todos os repositórios.
- **Sem `rm` em travas do APT**, ao contrário do script legado.
- **Sem `curl | sudo bash`** como caminho principal: os arquivos são baixados
  para o diretório temporário, que é removido no `trap EXIT`.
- **EOF encerra os menus.** Sem terminal disponível o script informa e sai, em
  vez de entrar em laço infinito.

## Log

`~/devkit-install.log` e `~/utilities-install.log` por padrão (`--log` ou
`KIT_LOG` mudam o destino). Cabeçalho com data, versão, sistema, arquitetura e
kernel; cada comando registrado como `[CMD]` com horário, seguido da saída
completa e do `[RC]`. O arquivo é acrescido, preservando execuções anteriores.

## Testes

```bash
./tests/run-tests.sh
```

88 asserções, sem rede, sem `sudo` e sem instalar nada: a suíte carrega a
biblioteca, injeta mocks e exercita só a lógica. Cobre `parse_selection`,
filtros `--only`/`--skip`, `component_present` com teste declarado,
idempotência do `append_once`, formato do log, propagação de código de retorno
pelo spinner, escopo do `ASSUME_YES`, `ask_choice`/`ask_multi_choice`,
`apt_first_available`, nomeação em `install_deb_from_url`, os cinco desfechos do
orquestrador e o tratamento de EOF nos menus.

Também valida os registries reais dos dois kits: toda função registrada existe,
não há ids duplicados, os campos obrigatórios estão preenchidos e as categorias
são contíguas.

Os testes de menu rodam sob um watchdog (`com_limite`), para que a regressão
clássica — laço infinito lendo EOF — vire falha visível em vez de travar a
suíte.

## Verificação manual

**Análise estática:**

```bash
bash -n lib/kit-common.sh devkit.sh utilitieskit.sh
shellcheck lib/kit-common.sh devkit.sh utilitieskit.sh   # se disponível
./devkit.sh --help && ./utilitieskit.sh --help
```

**Em Ubuntu** — VM ou `multipass launch 22.04` / `24.04`. Um contêiner Docker
**não** serve, porque não tem systemd e o `systemctl enable --now docker`
falharia:

1. Opção `4` sai limpo; opção `3` executa o update com `[OK]` por etapa.
2. `./utilitieskit.sh --only firefox` → `apt policy firefox` deve mostrar
   `packages.mozilla.org` como origem, e não o pacote transitional do Snap.
3. `./utilitieskit.sh --only 7zip` nas duas LTS → `7zip` no 24.04 e
   `p7zip-full` no 22.04, provando o `apt_first_available`.
4. `./utilitieskit.sh --only pdf,screenshot` → os menus de escolha aparecem e
   respeitam a seleção.
5. **Repetir qualquer comando acima** → deve detectar tudo instalado e oferecer
   atualização; responder `N` produz ignorados. Teste-chave de idempotência.
6. `./utilitieskit.sh --only discord` → valida o `.deb` com nome forçado; em
   arm64 vira IGNORADO com `[AVISO]`, nunca erro.
7. `./devkit.sh --only docker` → `docker --version`,
   `groups $USER | grep docker`, `systemctl is-enabled docker`,
   `docker compose version`.
8. `./devkit.sh --only dotnet` nas duas LTS → `dotnet --version` deve reportar a
   mesma major, provando a lógica de feed por versão.
9. Simular falha (bloquear `dl.google.com` em `/etc/hosts`) e rodar
   `--only chrome` → `[ERRO]` claro, execução **continua**, Chrome em
   "Falharam", saída com código 1.
10. `cat ~/utilities-install.log` → cabeçalho, entradas `[CMD]` com horário,
    saída do apt e o erro do passo 9.
