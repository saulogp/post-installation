# post-installation

Instaladores de pós-instalação para Ubuntu LTS (22.04 e 24.04), organizados em
**kits** que compartilham o mesmo motor e a mesma interface.

| Script | Para que serve |
|---|---|
| [`devkit.sh`](devkit.sh) | **DevKit** — ambiente de desenvolvimento: Git, Docker, Kubernetes, .NET, NodeJS |
| [`utilitieskit.sh`](utilitieskit.sh) | **UtilitiesKit** — aplicativos de uso diário: navegadores, escritório, multimídia, manutenção |
| [`lib/kit-common.sh`](lib/kit-common.sh) | Motor compartilhado pelos kits (não é executável por conta própria) |
| [`tests/run-tests.sh`](tests/run-tests.sh) | Suíte de testes do motor |
| [`post-installation.sh`](post-installation.sh) | Script original de pós-formatação: pacotes `.deb`, Flatpaks de desktop e configurações extras |
| [`install_dev_env.sh`](install_dev_env.sh) | Script linear e não interativo com .NET, Docker, kubectl, Minikube e K9S |

Os dois kits são **interativos**: perguntam antes de instalar cada item, detectam
o que já está presente e oferecem atualização, geram log completo e terminam com
um resumo do que foi concluído, ignorado e do que falhou. A falha de um item
nunca interrompe os demais.

Todos usam exclusivamente os repositórios oficiais de cada fabricante, e
**evitam Snap**.

## Instalação

Os kits dependem de `lib/kit-common.sh`, então clone o repositório em vez de
baixar um arquivo solto:

```shell
git clone https://github.com/saulogp/post-installation.git
cd post-installation
chmod +x devkit.sh utilitieskit.sh
./utilitieskit.sh
```

> Execute como **usuário comum**, sem `sudo`. Os scripts pedem a senha apenas
> onde é necessário — NVM, Oh My Zsh e o grupo `docker` precisam do seu usuário
> real. Também não funcionam via `sh -c`, pois usam recursos de Bash.

O menu inicial de qualquer kit:

```
1 - Instalação completa
2 - Escolher componentes individualmente
3 - Atualizar sistema apenas
4 - Sair
```

---

## DevKit — `devkit.sh`

16 componentes de desenvolvimento. Log em `~/devkit-install.log`.

| id | Componente | Origem |
|---|---|---|
| `curl` / `wget` | Curl, Wget | Repositório do Ubuntu |
| `git` | Git | Ubuntu, com opção pelo `ppa:git-core/ppa` oficial |
| `gcm` | Git Credential Manager | Releases oficiais (somente `amd64`) |
| `gh` | GitHub CLI | `cli.github.com` |
| `vscode` | Visual Studio Code | `packages.microsoft.com` — sem Snap |
| `docker` | Docker Engine | `download.docker.com` |
| `compose` | Docker Compose | Plugin oficial do Docker |
| `kubectl` | Kubectl | `pkgs.k8s.io` |
| `minikube` | Minikube | Google Storage (última estável) |
| `dotnet` | .NET SDK | Feed do Ubuntu ou `ppa:dotnet/backports` |
| `node` / `npm` / `nvm` | NodeJS, NPM, NVM | NodeSource e releases oficiais |
| `zsh` / `omz` | Zsh, Oh My Zsh | Ubuntu e instalador oficial |

---

## UtilitiesKit — `utilitieskit.sh`

21 aplicativos de uso diário. Log em `~/utilities-install.log`.

| id | Aplicativo | Categoria | Origem |
|---|---|---|---|
| `firefox` | Firefox | Navegadores | `packages.mozilla.org` + pin — **não** o Snap |
| `chrome` | Google Chrome | Navegadores | `dl.google.com` (somente `amd64`) |
| `brave` | Brave Browser | Navegadores | Repositório oficial da Brave |
| `libreoffice` | LibreOffice | Escritório | Ubuntu, com escolha de componentes e idioma pt-BR |
| `qbittorrent` | qBittorrent | Download | Ubuntu |
| `vlc` | VLC | Multimídia | Ubuntu |
| `gparted` | GParted | Sistema | Ubuntu |
| `tweaks` | GNOME Tweaks | Sistema | Ubuntu |
| `bleachbit` | BleachBit | Sistema | Ubuntu |
| `timeshift` | Timeshift | Sistema | Ubuntu |
| `stacer` | Stacer | Sistema | Ubuntu ou release do projeto |
| `7zip` | 7-Zip | Compactação | `7zip` (24.04) ou `p7zip-full` (22.04) |
| `unrar` | Unrar | Compactação | Ubuntu (multiverse) |
| `zip` | Zip e Unzip | Compactação | Ubuntu |
| `pdf` | Leitor de PDF | Documentos | Escolha: Evince, Okular ou ambos |
| `screenshot` | Captura de tela | Captura | Escolha: Flameshot, Ksnip ou ambas |
| `discord` | Discord | Comunicação | `.deb` oficial do discord.com |
| `telegram` | Telegram Desktop | Comunicação | Ubuntu, com Flathub como alternativa |
| `filezilla` | FileZilla | Extras | Ubuntu |
| `remmina` | Remmina | Extras | Ubuntu + plugins RDP e VNC |
| `obs` | OBS Studio | Extras | PPA oficial do projeto OBS |

Ordem de preferência das origens: **repositório oficial → `.deb` do fabricante →
Flatpak**. O Flatpak só é instalado se algum aplicativo realmente precisar dele.

---

## Opções de linha de comando

Válidas para os dois kits. O uso padrão é interativo; as flags existem para
reprovisionamento e testes.

| Flag | Efeito |
|---|---|
| `--all` | Instalação completa, sem exibir o menu |
| `--yes`, `-y` | Responde "sim" às perguntas |
| `--only <ids>` | Apenas os componentes informados. Ex.: `--only firefox,vlc` |
| `--skip <ids>` | Ignora os componentes informados |
| `--log <arquivo>` | Caminho do log |
| `--no-color` | Desativa as cores ANSI |
| `--version`, `-v` | Mostra a versão |
| `--help`, `-h` | Mostra a ajuda, com a lista de componentes do kit |

```shell
./utilitieskit.sh --all --yes              # tudo, desassistido
./utilitieskit.sh --only firefox,vlc,obs   # só três aplicativos
./devkit.sh --all --skip zsh,omz           # tudo, menos Zsh e Oh My Zsh
```

Mesmo com `--all --yes`, a **troca do shell padrão para Zsh sempre pede
confirmação explícita**.

## Comportamento

- A falha de um componente **nunca interrompe** os demais.
- O código de saída é `1` se houve alguma falha, `0` caso contrário.
- Componentes sem pacote oficial para a arquitetura em uso (ou sem pacote para
  aquela versão do Ubuntu) são marcados como **ignorados**, com aviso — não como
  erro.
- Todo comando executado, com horário, saída e código de retorno, vai para o log.
- Depois de instalar o Docker, encerre e reabra a sessão (ou use `newgrp docker`)
  para usar o cliente sem `sudo`.

## Como criar um kit novo

A arquitetura foi feita para crescer (Multimídia, Jogos, Design, Segurança...).
Um kit declara sua identidade, carrega o motor, define as funções de instalação
e registra os componentes:

```bash
readonly KIT_ID='gameskit'
readonly KIT_NAME='Ubuntu GamesKit Installer'
readonly KIT_VERSION='1.0.0'
readonly KIT_LOG_DEFAULT="${HOME}/games-install.log"

source "$(dirname "${BASH_SOURCE[0]}")/lib/kit-common.sh"

install_steam() { apt_install_step 'Steam' steam; }

register_components() {
    register_component steam 'Steam' 'Lojas' install_steam steam 'steam --version' 'amd64'
}

kit_main "$@"
```

Menu, log, validação, resumo, flags e os testes de integridade do registry
passam a valer automaticamente. As decisões de design estão documentadas em
[PLANO-KITS.md](PLANO-KITS.md).

## Testes

```shell
./tests/run-tests.sh
```

88 asserções sobre o motor compartilhado. Roda offline, sem `sudo` e sem
instalar nada. Como o motor é usado por todos os kits, esta suíte é o que torna
seguro alterá-lo.

---

## Scripts anteriores

### post-installation.sh

Script original de pós-formatação: pacotes `.deb`, aplicativos Flatpak de uso
geral (Spotify, Discord, OBS, qBittorrent...) e configurações extras.

```shell
sh -c "$(curl -fsSL https://raw.githubusercontent.com/saulogp/post-installation/main/post-installation.sh)"
```

Base do script: https://github.com/Diolinux/pop-os-postinstall

### install_dev_env.sh

Script linear e não interativo que instala .NET, Docker, kubectl, Minikube e
K9S. Mantido por compatibilidade — para novos ambientes, prefira o
[`devkit.sh`](devkit.sh).

---

## Licença

[MIT](LICENSE)
