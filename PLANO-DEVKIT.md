# Plano de design — `devkit.sh` (Ubuntu DevKit Installer)

Documento de design do `devkit.sh`. Serve como referência de manutenção: explica
**por que** o script é como é, para que alterações futuras não desfaçam decisões
tomadas de propósito.

## Contexto

O repositório tinha dois scripts que resolviam o problema pela metade:

- **`post-installation.sh`** — herdado do `pop-os-postinstall` do Diolinux. Sem
  `set` flags, sem checagem de idempotência, instala tudo cegamente num laço,
  mistura apps de desktop (Spotify, Discord, OBS) com ferramentas de
  desenvolvimento, e remove travas do APT com `rm` direto em
  `/var/lib/dpkg/lock-frontend`.
- **`install_dev_env.sh`** — mais recente e mais correto (usa `is_installed`,
  chaveiros com `signed-by`), mas linear, sem cores, sem log, sem interação, e
  com `set -e`: a falha de um único pacote derruba a execução inteira.

Nenhum dos dois é interativo, gera log ou produz resumo, e acrescentar uma
ferramenta significava editar código no meio do fluxo.

O `devkit.sh` substitui essa abordagem por um instalador único, interativo e
orientado a dados, no qual **adicionar uma ferramenta nova é uma função mais uma
linha de registro**.

## Decisões de projeto

| Tema | Decisão |
|---|---|
| .NET SDK | Segue a documentação **atual** da Microsoft, não o `packages-microsoft-prod.deb` |
| Arquivos | `devkit.sh` na raiz; os dois scripts legados foram preservados |
| Arquitetura | `amd64` **e** `arm64`; componente sem build para a arquitetura vira IGNORADO com `[AVISO]`, nunca erro |
| Flags CLI | Interativo por padrão; flags opcionais para reprovisionamento e testes |
| Idioma | Português (pt-BR), consistente com o restante do repositório |

### Por que `set -e` não é usado

O requisito central é *"nunca interromper completamente a execução caso um pacote
falhe"*. Isso é incompatível com `errexit`, que aborta o script no primeiro
comando com status diferente de zero. O script usa `set -uo pipefail` e faz o
controle de erro explicitamente: cada `install_*()` devolve um código, e
`install_component()` transforma falha em **estado** (entra no resumo), não em
interrupção. Nenhuma função de instalação chama `exit`.

### Por que o .NET não vem do `packages.microsoft.com`

A especificação original pedia "adicionar o repositório oficial da Microsoft".
A documentação da Microsoft (`learn.microsoft.com/dotnet/core/install/linux-ubuntu-install`,
revisada em 23/04/2026) afirma explicitamente que **o feed
`packages.microsoft.com` não contém mais pacotes .NET para Ubuntu**, e que esse
feed é exclusivo para x64. A matriz real de disponibilidade:

| Ubuntu | Feed nativo | `ppa:dotnet/backports` | Feed Microsoft |
|---|---|---|---|
| 24.04 | 10.0, 8.0 | 9.0, 7.0, 6.0 | **nenhum** |
| 22.04 | 8.0, 7.0, 6.0 | **10.0**, 9.0 | 8.0 e anteriores |

Por isso `install_dotnet()`:

1. Em **24.04**, usa o feed nativo do Ubuntu (nada a adicionar).
2. Em **22.04**, adiciona `ppa:dotnet/backports`, mantido pela Canonical.
3. Descobre o maior SDK disponível com
   `apt-cache search --names-only '^dotnet-sdk-[0-9]+\.[0-9]+$' | sort -V | tail -1`
   — **sem versão fixa no código**, então continua correto quando sair o .NET 11.
4. Se o APT não oferecer nada, cai para o instalador oficial
   `https://dot.net/v1/dotnet-install.sh --channel STS`.

Seguir a especificação ao pé da letra instalaria um SDK desatualizado no 22.04,
nada no 24.04, e arriscaria o problema de *package mix-up* que a própria
Microsoft documenta.

## Estrutura do script

Arquivo único, 12 seções numeradas.

| Seção | Conteúdo |
|---|---|
| 1 | Constantes (`readonly`): versões suportadas, diretórios do APT, marcadores de bloco de shell, versões de fallback |
| 2 | Estado global mutável e variáveis de cor |
| 3 | Log e mensagens: `log_raw`, `msg_info/ok/warn/error`, `banner`, `init_log`, `detect_tty` |
| 4 | Helpers reutilizáveis (o núcleo do DRY) |
| 5 | Verificações prévias |
| 6 | Módulos de instalação — um por componente |
| 7 | **Registro de componentes — o ponto de extensão** |
| 8 | Orquestração |
| 9 | Atualização do sistema |
| 10 | Menu interativo |
| 11 | Resumo final |
| 12 | Argumentos, limpeza e ponto de entrada |

### Helpers que evitam repetição

| Função | Responsabilidade |
|---|---|
| `run_cmd()` | Registra `[CMD]`, executa com toda a saída indo para o log, devolve o código original. Toda chamada de sistema passa por aqui |
| `run_step()` | `run_cmd` mais spinner e `[OK]`/`[ERRO]` na tela |
| `ask_yes_no()` | O prompt `[S] Sim / [N] Não`. Lê de `/dev/tty` para funcionar com a stdin redirecionada; respeita `ASSUME_YES` |
| `add_apt_repo()` | **Generaliza** o boilerplate de chaveiro que se repetia por módulo: baixa a chave (ASCII ou binária), instala em `/etc/apt/keyrings`, escreve a entrada com `signed-by=` e atualiza o índice. Usado por VS Code, Docker, kubectl, GitHub CLI e NodeSource |
| `install_deb_from_url()` | Baixa um `.deb` e instala com `apt-get` (que resolve dependências, ao contrário de `dpkg -i`) |
| `github_latest_tag()` / `github_latest_asset()` | Consultam a API do GitHub sem depender de `jq` |
| `append_once()` | Injeta um bloco em `.bashrc`/`.zshrc` entre marcadores, substituindo o bloco anterior. Reexecutar o script não duplica configuração nem acumula linhas em branco |
| `ensure_prereqs()` | Instala `curl`/`gnupg`/`ca-certificates` sob demanda, **independente** do componente "Curl" que o usuário pode ter recusado |

### O registro de componentes

```bash
register_component <id> <nome> <função> <binário> <comando de versão> <arquiteturas>
```

Um array ordenado (`COMPONENT_ORDER`) mais cinco arrays associativos descrevem
todo o catálogo. A ordem do array codifica as dependências reais:

```
curl → wget → git → gcm → gh → vscode → docker → compose →
kubectl → minikube → dotnet → node → npm → nvm → zsh → omz
```

**Para acrescentar Java, Python, Terraform, AWS CLI ou Azure CLI:** escreva
`install_<nome>()` na Seção 6 e acrescente uma linha em `register_components()`.
Nada mais muda — menu, validação, log, resumo e flags passam a contemplar o
componente automaticamente.

### O orquestrador

`install_component()` é a única função que conversa com o usuário sobre um
componente, e concentra toda a lógica de validação:

1. Imprime o cabeçalho `[3/16] Docker`.
2. Arquitetura incompatível → `[AVISO]` e IGNORADO (retorna 0, não é erro).
3. Já instalado → mostra a versão e pergunta *"Deseja atualizar?"*.
4. Não instalado → pergunta *"Deseja instalar?"* antes de qualquer download.
5. Chama a função registrada e captura o código de retorno.
6. Revalida e informa a versão final.
7. **Nunca chama `exit`.**

Como consequência, cada `install_*()` é curta e cuida apenas da instalação.

Um detalhe importante do passo 6: quando a instalação devolve sucesso mas o
binário ainda não está no `PATH` da sessão (caso de NVM e do .NET via script), o
componente é contado como **concluído** com um aviso de "abra um novo terminal"
— e não como falha.

## Fontes oficiais utilizadas

| Componente | Origem |
|---|---|
| Git | Repositório do Ubuntu, com opção pelo `ppa:git-core/ppa` dos mantenedores |
| Git Credential Manager | Releases de `git-ecosystem/git-credential-manager` (apenas amd64) |
| GitHub CLI | `cli.github.com/packages` |
| VS Code | `packages.microsoft.com/repos/code` — **sem Snap** |
| Docker / Compose | `download.docker.com/linux/ubuntu` |
| kubectl | `pkgs.k8s.io`, com a *minor* resolvida em `cdn.dl.k8s.io/release/stable.txt` |
| Minikube | `storage.googleapis.com/minikube/releases/latest` |
| .NET SDK | Feed nativo do Ubuntu ou `ppa:dotnet/backports` (ver acima) |
| NodeJS | NodeSource, com a linha LTS resolvida em `nodejs.org/dist/index.json` |
| NVM | Release mais recente de `nvm-sh/nvm` |
| Oh My Zsh | `install.sh` oficial, com `RUNZSH=no CHSH=no --unattended` |

Nenhuma versão de kubectl, Node ou .NET está fixada no código: todas são
resolvidas em tempo de execução, com fallback declarado nas constantes da
Seção 1 para o caso de a consulta falhar.

## Segurança e comportamento

- **Não roda como root.** `check_root()` recusa `sudo ./devkit.sh`, porque NVM,
  Oh My Zsh e a inclusão no grupo `docker` precisam do `$HOME` e do `$USER`
  reais — sob `sudo` seriam aplicados ao root. O `sudo` é pedido apenas onde é
  necessário, e o ticket é renovado em segundo plano para o script não travar
  pedindo senha no meio de uma instalação longa.
- **O shell padrão nunca muda sozinho.** A troca para Zsh usa
  `ASSUME_YES=0 ask_yes_no ...`, que força a pergunta mesmo em `--all --yes`.
- **Chaveiros por repositório.** Cada repositório usa a própria chave em
  `/etc/apt/keyrings` com `signed-by=`, sem `apt-key` (obsoleto) e sem chave
  global confiada para todos os repositórios.
- **Sem `rm` em travas do APT**, ao contrário do script legado.
- **Sem `curl | sudo bash`** como caminho principal: os arquivos são baixados,
  inspecionados quando aplicável e executados a partir do diretório temporário,
  que é removido no `trap EXIT`.
- **EOF encerra os menus.** Sem terminal disponível o script informa e sai, em
  vez de entrar em laço infinito.

## Log

`~/devkit-install.log` por padrão (`--log` ou `DEVKIT_LOG` mudam o destino).
Cabeçalho com data, versão do script, sistema, arquitetura e kernel; cada
comando registrado como `[CMD]` com horário, seguido da saída completa e do
`[RC]` correspondente. O arquivo é acrescido, preservando execuções anteriores.

## Verificação

**Análise estática:**

```bash
bash -n devkit.sh          # sintaxe
shellcheck devkit.sh       # se disponível
./devkit.sh --help
```

**Em Ubuntu** — use uma VM ou `multipass launch 22.04` / `24.04`. Um contêiner
Docker **não** serve, porque não tem systemd e o `systemctl enable --now docker`
falharia:

1. `./devkit.sh` → opção `4` sai limpo; opção `3` executa o update com `[OK]` por etapa.
2. `./devkit.sh --only git,curl,wget` → confirma cada item, valida versões, resumo com 3 `✔`.
3. **Repetir o mesmo comando** → deve detectar tudo instalado e oferecer atualização; responder `N` produz 3 ignorados. Este é o teste-chave de idempotência.
4. `./devkit.sh --only docker` → depois `docker --version`, `groups $USER | grep docker`, `systemctl is-enabled docker`, `docker compose version`.
5. `./devkit.sh --only dotnet` nas duas LTS → `dotnet --version` deve reportar a mesma major nas duas, provando a lógica de feed por versão.
6. `./devkit.sh --only node,npm,nvm` → `node -v` (LTS), `npm -v`, `source ~/.bashrc && nvm --version`.
7. Simular falha (bloquear `storage.googleapis.com` em `/etc/hosts`) e rodar `--only minikube` → deve imprimir `[ERRO]`, **continuar**, listar Minikube em "Falharam" e sair com código 1.
8. `cat ~/devkit-install.log` → cabeçalho, entradas `[CMD]` com horário, saída do apt e o erro do passo 7.
