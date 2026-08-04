# post-installation

Scripts de pós-instalação para distribuições baseadas em Ubuntu.

| Script | Para que serve |
|---|---|
| [`devkit.sh`](devkit.sh) | **Recomendado.** Instalador interativo do ambiente de desenvolvimento (DevKit) para Ubuntu 22.04 e 24.04 |
| [`post-installation.sh`](post-installation.sh) | Script original de pós-formatação: pacotes `.deb`, Flatpaks de desktop e configurações extras |
| [`install_dev_env.sh`](install_dev_env.sh) | Script linear e não interativo com .NET, Docker, kubectl, Minikube e K9S |

---

## DevKit

`devkit.sh` prepara um ambiente de desenvolvimento completo logo após uma
instalação limpa do Ubuntu, usando exclusivamente os repositórios oficiais de
cada fabricante.

**Compatível com Ubuntu 22.04 LTS e 24.04 LTS**, nas arquiteturas `amd64` e
`arm64`.

### Componentes

| id | Componente | Origem |
|---|---|---|
| `curl` | Curl | Repositório do Ubuntu |
| `wget` | Wget | Repositório do Ubuntu |
| `git` | Git | Ubuntu, com opção pelo `ppa:git-core/ppa` oficial |
| `gcm` | Git Credential Manager | Releases oficiais (somente `amd64`) |
| `gh` | GitHub CLI | `cli.github.com` |
| `vscode` | Visual Studio Code | `packages.microsoft.com` — sem Snap |
| `docker` | Docker Engine | `download.docker.com` |
| `compose` | Docker Compose | Plugin oficial do Docker |
| `kubectl` | Kubectl | `pkgs.k8s.io` |
| `minikube` | Minikube | Google Storage (última estável) |
| `dotnet` | .NET SDK | Feed do Ubuntu ou `ppa:dotnet/backports` |
| `node` | NodeJS | NodeSource (última LTS) |
| `npm` | NPM | Atualizado para a última versão |
| `nvm` | NVM | Release oficial `nvm-sh/nvm` |
| `zsh` | Zsh | Repositório do Ubuntu |
| `omz` | Oh My Zsh | Instalador oficial |

Nenhuma versão fica fixa no código: kubectl, NodeJS e .NET são resolvidos em
tempo de execução, sempre buscando a última estável.

### Como usar

```shell
curl -fsSLo devkit.sh https://raw.githubusercontent.com/saulogp/post-installation/main/devkit.sh
chmod +x devkit.sh
./devkit.sh
```

> Execute como **usuário comum**, sem `sudo`. O script pede a senha apenas onde
> é necessário — NVM, Oh My Zsh e o grupo `docker` precisam do seu usuário real.
> Ele também não pode ser executado via `sh -c`, pois usa recursos de Bash.

O menu inicial oferece:

```
1 - Instalação completa
2 - Escolher componentes individualmente
3 - Atualizar sistema apenas
4 - Sair
```

Cada componente é confirmado antes de qualquer download. Se já estiver
instalado, o script mostra a versão atual e pergunta se você quer atualizar.

### Opções de linha de comando

O uso padrão é interativo; as flags existem para reprovisionamento e testes.

| Flag | Efeito |
|---|---|
| `--all` | Instalação completa, sem exibir o menu |
| `--yes`, `-y` | Responde "sim" às perguntas |
| `--only <ids>` | Apenas os componentes informados. Ex.: `--only git,docker,node` |
| `--skip <ids>` | Ignora os componentes informados |
| `--log <arquivo>` | Caminho do log (padrão: `$HOME/devkit-install.log`) |
| `--no-color` | Desativa as cores ANSI |
| `--version`, `-v` | Mostra a versão |
| `--help`, `-h` | Mostra a ajuda |

```shell
./devkit.sh --all --yes              # instalação completa desassistida
./devkit.sh --only docker,compose    # somente Docker e Docker Compose
./devkit.sh --all --skip zsh,omz     # tudo, menos Zsh e Oh My Zsh
```

Mesmo com `--all --yes`, a **troca do shell padrão para Zsh sempre pede
confirmação explícita**.

### Comportamento

- A falha de um componente **nunca interrompe** os demais.
- Ao final, um resumo lista o que foi concluído, ignorado e o que falhou.
- O código de saída é `1` se houve alguma falha, `0` caso contrário.
- Todo comando executado, com horário, saída e código de retorno, é gravado em
  `~/devkit-install.log`.
- Componentes sem pacote oficial para a arquitetura em uso são marcados como
  ignorados, com aviso — não como erro.

Depois de instalar o Docker, encerre e reabra a sessão (ou use `newgrp docker`)
para usar o cliente sem `sudo`.

### Como estender

Para acrescentar uma ferramenta nova (Java, Python, Terraform, AWS CLI, Azure
CLI...), escreva a função de instalação na Seção 6 e acrescente uma linha em
`register_components()`:

```bash
register_component terraform 'Terraform' install_terraform terraform 'terraform version' 'amd64 arm64'
```

Menu, validação, log, resumo e flags passam a contemplar o componente
automaticamente. As decisões de design estão documentadas em
[PLANO-DEVKIT.md](PLANO-DEVKIT.md).

---

## post-installation.sh

Script original de pós-formatação: instala pacotes `.deb`, aplicativos Flatpak
de uso geral (Spotify, Discord, OBS, qBittorrent...) e faz configurações extras.

```shell
sh -c "$(curl -fsSL https://raw.githubusercontent.com/saulogp/post-installation/main/post-installation.sh)"
```

Base do script: https://github.com/Diolinux/pop-os-postinstall

---

## install_dev_env.sh

Script linear e não interativo que instala .NET, Docker, kubectl, Minikube e
K9S. Mantido por compatibilidade — para novos ambientes, prefira o
[`devkit.sh`](devkit.sh).

```shell
chmod +x install_dev_env.sh
./install_dev_env.sh
```

---

## Licença

[MIT](LICENSE)
