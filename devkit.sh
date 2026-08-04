#!/usr/bin/env bash
#===============================================================================
#
#          FILE: devkit.sh
#
#         USAGE: ./devkit.sh [opções]
#
#   DESCRIPTION: Instalador de pós-instalação para Ubuntu LTS (22.04 / 24.04).
#                Prepara um ambiente de desenvolvimento completo — o DevKit —
#                a partir de uma instalação limpa, utilizando exclusivamente os
#                repositórios oficiais de cada fabricante.
#
#  REQUIREMENTS: Ubuntu 22.04 ou 24.04, Bash >= 4, sudo, conexão com a Internet
#        AUTHOR: Saulo Godoy Proetti
#       LICENSE: MIT
#
#   COMO ESTENDER: para acrescentar uma ferramenta nova (Java, Python,
#                  Terraform, AWS CLI, Azure CLI...) basta escrever uma função
#                  install_<nome>() na SEÇÃO 6 e acrescentar uma linha
#                  register_component na SEÇÃO 7. Nada mais precisa mudar.
#
#===============================================================================

# 'errexit' NÃO é usado de propósito: o requisito é que a falha de um componente
# jamais interrompa a execução dos demais. O tratamento de erro é explícito, via
# código de retorno de cada função.
set -uo pipefail

#===============================================================================
# SEÇÃO 1 — Constantes globais
#===============================================================================

readonly SCRIPT_NAME='Ubuntu DevKit Installer'
readonly SCRIPT_VERSION='1.0.0'
readonly SCRIPT_FILE="${BASH_SOURCE[0]##*/}"

# Versões do Ubuntu oficialmente suportadas/testadas.
readonly SUPPORTED_UBUNTU=('22.04' '24.04')

# Diretório padrão de chaveiros APT (padrão Debian/Ubuntu moderno).
readonly KEYRINGS_DIR='/etc/apt/keyrings'
readonly SOURCES_DIR='/etc/apt/sources.list.d'

# Marcadores usados para delimitar os blocos que o script injeta nos arquivos
# de perfil do shell. Permitem reexecução sem duplicar configuração.
readonly RC_BEGIN='# >>> devkit início >>>'
readonly RC_END='# <<< devkit fim <<<'

# Versão de fallback do kubectl, usada apenas se a consulta ao canal estável
# do Kubernetes falhar (rede restrita, proxy, etc.).
readonly KUBECTL_FALLBACK_MINOR='v1.34'
# Idem para o Node.js, caso o índice de distribuição fique inacessível.
readonly NODE_FALLBACK_MAJOR='22'

#===============================================================================
# SEÇÃO 2 — Estado global (mutável)
#===============================================================================

LOG_FILE="${DEVKIT_LOG:-${HOME}/devkit-install.log}"
TMP_DIR=''

UBUNTU_ID=''            # ubuntu, linuxmint, pop...
UBUNTU_VERSION=''       # 22.04, 24.04...
UBUNTU_CODENAME=''      # jammy, noble...
ARCH_DEB=''             # amd64 | arm64   (dpkg --print-architecture)
ARCH_UNAME=''           # x86_64 | aarch64

ASSUME_YES=0            # --yes / --all
USE_COLOR=1             # --no-color / NO_COLOR / saída não-TTY
USE_SPINNER=1
TTY_IN=''               # /dev/tty quando houver terminal utilizável
MENU_CHOICE=''          # --all força a opção 1 do menu
SUDO_KEEPALIVE_PID=''
SUMMARY_PRINTED=0

declare -a ONLY_LIST=()
declare -a SKIP_LIST=()

# Resultado de cada componente, consumido por summary().
declare -a SUMMARY_OK=()
declare -a SUMMARY_FAIL=()
declare -a SUMMARY_SKIP=()
declare -a NOTICES=()

# Cores ANSI — preenchidas por setup_colors(), após o parsing dos argumentos.
VERDE=''; AMARELO=''; VERMELHO=''; AZUL=''; NEGRITO=''; SEM_COR=''

#===============================================================================
# SEÇÃO 3 — Log e mensagens
#===============================================================================

# Ativa as cores somente se fizer sentido: terminal interativo, sem --no-color
# e sem a convenção NO_COLOR (https://no-color.org).
setup_colors() {
    if [[ $USE_COLOR -eq 1 && -t 1 && -z ${NO_COLOR:-} ]]; then
        VERDE=$'\e[1;92m'
        AMARELO=$'\e[1;93m'
        VERMELHO=$'\e[1;91m'
        AZUL=$'\e[1;94m'
        NEGRITO=$'\e[1m'
        SEM_COR=$'\e[0m'
    else
        VERDE=''; AMARELO=''; VERMELHO=''; AZUL=''; NEGRITO=''; SEM_COR=''
        USE_SPINNER=0
    fi
    [[ -t 1 ]] || USE_SPINNER=0
}

# Descobre se há um terminal utilizável para as perguntas. Ler de /dev/tty
# permite continuar interativo mesmo com a stdin redirecionada, mas o
# dispositivo nem sempre pode ser aberto (cron, CI, contêiner sem TTY) — por
# isso testamos a abertura de fato, e não apenas a permissão do arquivo.
detect_tty() {
    # A tentativa de abertura roda em subshell com a stderr já redirecionada:
    # em '</dev/tty 2>/dev/null' o erro de abertura escaparia, porque as
    # redireções são aplicadas na ordem em que aparecem.
    if ( exec </dev/tty ) 2>/dev/null; then
        TTY_IN='/dev/tty'
    else
        TTY_IN=''
    fi
}

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Grava uma linha somente no arquivo de log (não vai para a tela).
log_raw() {
    [[ -n $LOG_FILE ]] || return 0
    printf '[%s] %s\n' "$(timestamp)" "$*" >>"$LOG_FILE" 2>/dev/null
}

msg_info()  { printf '%s[INFO]%s  %s\n'  "$AZUL"     "$SEM_COR" "$*"; log_raw "[INFO]  $*"; }
msg_ok()    { printf '%s[OK]%s    %s\n'  "$VERDE"    "$SEM_COR" "$*"; log_raw "[OK]    $*"; }
msg_warn()  { printf '%s[AVISO]%s %s\n'  "$AMARELO"  "$SEM_COR" "$*"; log_raw "[AVISO] $*"; }
msg_error() { printf '%s[ERRO]%s  %s\n'  "$VERMELHO" "$SEM_COR" "$*" >&2; log_raw "[ERRO]  $*"; }

# Caixa de título usada no menu e nas seções principais.
banner() {
    local titulo=$1
    printf '\n%s=========================================%s\n' "$NEGRITO" "$SEM_COR"
    printf '%s %s%s\n' "$NEGRITO" "$titulo" "$SEM_COR"
    printf '%s=========================================%s\n\n' "$NEGRITO" "$SEM_COR"
    log_raw "===== $titulo ====="
}

# Cria o arquivo de log e escreve o cabeçalho da execução.
init_log() {
    local dir="${LOG_FILE%/*}"
    [[ $dir == "$LOG_FILE" ]] && dir='.'
    if ! mkdir -p "$dir" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
        printf 'Não foi possível escrever em %s; o log será descartado.\n' "$LOG_FILE" >&2
        LOG_FILE=''
        return 0
    fi
    {
        printf '\n'
        printf '===============================================================\n'
        printf ' %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        printf ' Início      : %s\n' "$(timestamp)"
        printf ' Usuário     : %s (uid %s)\n' "${USER:-desconhecido}" "$(id -u)"
        printf ' Sistema     : %s %s (%s)\n' "$UBUNTU_ID" "$UBUNTU_VERSION" "$UBUNTU_CODENAME"
        printf ' Arquitetura : %s / %s\n' "$ARCH_DEB" "$ARCH_UNAME"
        printf ' Kernel      : %s\n' "$(uname -r)"
        printf '===============================================================\n'
    } >>"$LOG_FILE"
}

#===============================================================================
# SEÇÃO 4 — Helpers reutilizáveis
#===============================================================================

# Executa um comando registrando-o no log junto de toda a sua saída.
# Devolve o código de retorno original do comando.
run_cmd() {
    local rc
    log_raw "[CMD]   $*"
    if [[ -n $LOG_FILE ]]; then
        "$@" >>"$LOG_FILE" 2>&1
        rc=$?
    else
        "$@" >/dev/null 2>&1
        rc=$?
    fi
    log_raw "[RC]    $rc  ($1)"
    return "$rc"
}

# Animação exibida enquanto um comando demorado roda em segundo plano.
spinner() {
    local pid=$1 marks='|/-\' i=0
    printf ' '
    while kill -0 "$pid" 2>/dev/null; do
        printf '\b%s' "${marks:i%4:1}"
        i=$(( i + 1 ))
        sleep 0.2
    done
    printf '\b'
}

# run_cmd + feedback visual de progresso. É a forma preferencial de executar
# qualquer comando demorado (apt, curl, dpkg...).
run_step() {
    local desc=$1; shift
    local rc pid

    printf '  %s->%s %s ' "$AZUL" "$SEM_COR" "$desc"

    if [[ $USE_SPINNER -eq 1 ]]; then
        run_cmd "$@" &
        pid=$!
        spinner "$pid"
        wait "$pid"
        rc=$?
    else
        run_cmd "$@"
        rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        printf '%s[OK]%s\n' "$VERDE" "$SEM_COR"
    else
        printf '%s[ERRO]%s (código %s)\n' "$VERMELHO" "$SEM_COR" "$rc"
    fi
    return "$rc"
}

# Pergunta [S] Sim / [N] Não no formato definido pela especificação.
# Lê de /dev/tty para continuar funcionando mesmo com a stdin redirecionada.
ask_yes_no() {
    local pergunta=$1
    local resposta

    if [[ $ASSUME_YES -eq 1 ]]; then
        printf '%s %s(S — automático)%s\n' "$pergunta" "$AMARELO" "$SEM_COR"
        log_raw "[ASK]   $pergunta -> S (automático)"
        return 0
    fi

    while true; do
        printf '\n%s%s%s\n\n' "$NEGRITO" "$pergunta" "$SEM_COR"
        printf '  %s[S]%s Sim\n' "$VERDE" "$SEM_COR"
        printf '  %s[N]%s Não\n\n' "$VERMELHO" "$SEM_COR"
        printf '> '

        if [[ -n $TTY_IN ]]; then
            read -r resposta <"$TTY_IN" || resposta='n'
        else
            read -r resposta || resposta='n'
        fi

        case "${resposta,,}" in
            s|sim|y|yes) log_raw "[ASK]   $pergunta -> S"; return 0 ;;
            n|nao|não|no) log_raw "[ASK]   $pergunta -> N"; return 1 ;;
            *) msg_warn 'Resposta inválida. Digite S para sim ou N para não.' ;;
        esac
    done
}

# Lê uma linha livre do usuário (menu, seleção de componentes).
# Devolve status != 0 quando a entrada se esgota (EOF), para que os menus
# possam encerrar em vez de entrar em laço infinito em execução desassistida.
read_input() {
    local resposta rc
    if [[ -n $TTY_IN ]]; then
        read -r resposta <"$TTY_IN"; rc=$?
    else
        read -r resposta; rc=$?
    fi
    printf '%s' "$resposta"
    return "$rc"
}

# Verdadeiro quando não há mais entrada disponível: status de leitura != 0 e
# nenhum texto lido (uma última linha sem quebra final não conta como EOF).
input_exhausted() {
    (( $1 != 0 )) && [[ -z $2 ]]
}

# Verdadeiro se o comando existe no PATH.
is_installed() { command -v "$1" >/dev/null 2>&1; }

# Primeira linha da saída de um comando de versão, já higienizada.
get_version() {
    local saida
    saida=$(eval "$1" 2>/dev/null | head -n 1) || saida=''
    saida=${saida//$'\r'/}
    printf '%s' "${saida:-desconhecida}"
}

# apt-get install padronizado: não interativo e preservando configs existentes.
apt_install() {
    run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

apt_update() {
    run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
}

# Instala em silêncio as dependências de que os próprios módulos precisam.
# Independe do componente "Curl", que o usuário pode ter recusado no menu.
ensure_prereqs() {
    local faltando=()
    is_installed curl        || faltando+=('curl')
    is_installed gpg         || faltando+=('gnupg')
    [[ -e /usr/share/ca-certificates ]] || faltando+=('ca-certificates')

    if (( ${#faltando[@]} )); then
        msg_info "Instalando pré-requisitos: ${faltando[*]}"
        apt_update
        apt_install "${faltando[@]}" apt-transport-https || {
            msg_error 'Falha ao instalar os pré-requisitos (curl/gnupg/ca-certificates).'
            return 1
        }
    fi
    return 0
}

# Registra um repositório APT de terceiro seguindo o padrão moderno:
# chave dedicada em /etc/apt/keyrings + 'signed-by' na entrada de sources.
#
#   $1 nome curto (vira o nome do .gpg e do .list)
#   $2 URL da chave pública (aceita formato ASCII-armored ou binário)
#   $3 linha completa do repositório, contendo o marcador @KEYRING@
add_apt_repo() {
    local nome=$1 key_url=$2 repo_line=$3
    local keyring="${KEYRINGS_DIR}/${nome}.gpg"
    local listfile="${SOURCES_DIR}/${nome}.list"
    local tmpkey="${TMP_DIR}/${nome}.key"

    ensure_prereqs || return 1
    run_cmd sudo install -m 0755 -d "$KEYRINGS_DIR" || return 1

    if [[ ! -s $keyring ]]; then
        if ! run_cmd curl -fsSL --retry 3 --max-time 60 -o "$tmpkey" "$key_url"; then
            msg_error "Não foi possível baixar a chave GPG de '${nome}' (${key_url})."
            return 1
        fi
        # A chave pode vir armada (ASCII) ou já binária; tratamos os dois casos.
        if head -c 200 "$tmpkey" | grep -q 'BEGIN PGP'; then
            if ! run_cmd gpg --batch --yes --dearmor -o "${tmpkey}.gpg" "$tmpkey"; then
                msg_error "Chave GPG de '${nome}' inválida ou corrompida."
                return 1
            fi
        else
            cp -f "$tmpkey" "${tmpkey}.gpg" || return 1
        fi
        run_cmd sudo install -m 0644 "${tmpkey}.gpg" "$keyring" || return 1
    fi

    # Substitui o marcador pelo caminho real do chaveiro instalado.
    repo_line=${repo_line//@KEYRING@/$keyring}

    if [[ ! -s $listfile ]] || ! grep -qxF "$repo_line" "$listfile" 2>/dev/null; then
        printf '%s\n' "$repo_line" | run_cmd sudo tee "$listfile" || return 1
        run_cmd sudo chmod 0644 "$listfile"
    fi

    run_step "Atualizando índice do repositório ${nome}" \
        sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
}

# Baixa um .deb e o instala com apt-get, que resolve dependências
# automaticamente (ao contrário de 'dpkg -i').
install_deb_from_url() {
    local url=$1
    local arquivo="${TMP_DIR}/$(basename "${url%%\?*}")"

    if ! run_step "Baixando $(basename "${url%%\?*}")" \
            curl -fL --retry 3 --max-time 300 -o "$arquivo" "$url"; then
        msg_error "Falha no download de ${url}"
        return 1
    fi

    apt_install "$arquivo"
}

# Consulta a API pública do GitHub sem depender de 'jq'.
github_latest_tag() {
    curl -fsSL --max-time 30 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# Devolve a URL de download do primeiro asset que casa com o padrão informado.
github_latest_asset() {
    curl -fsSL --max-time 30 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -E 's/.*"(https[^"]+)".*/\1/' \
        | grep -m1 -E "$2"
}

# Acrescenta um bloco de configuração a um arquivo de perfil apenas uma vez.
# Reexecuções substituem o bloco anterior em vez de duplicá-lo.
append_once() {
    local arquivo=$1 conteudo=$2
    local tmp="${TMP_DIR}/rc.$$.${RANDOM}"
    local base ini fim

    [[ -e $arquivo ]] || touch "$arquivo" 2>/dev/null || return 1

    if grep -qF "$RC_BEGIN" "$arquivo" 2>/dev/null; then
        # Remove o bloco antigo preservando todo o restante do arquivo.
        ini=$(sed 's/[][\.*^$/]/\\&/g' <<<"$RC_BEGIN")
        fim=$(sed 's/[][\.*^$/]/\\&/g' <<<"$RC_END")
        sed "/${ini}/,/${fim}/d" "$arquivo" >"$tmp" 2>/dev/null || return 1
    else
        cat "$arquivo" >"$tmp" 2>/dev/null || return 1
    fi

    # A substituição de comando descarta as quebras de linha finais, evitando
    # que linhas em branco se acumulem a cada reexecução do script.
    base=$(cat "$tmp")

    {
        [[ -n $base ]] && printf '%s\n\n' "$base"
        printf '%s\n%s\n%s\n' "$RC_BEGIN" "$conteudo" "$RC_END"
    } >"$arquivo"

    log_raw "[RC]    bloco devkit aplicado em ${arquivo}"
}

# Aplica o mesmo bloco em todos os perfis de shell presentes no HOME.
apply_shell_config() {
    local conteudo=$1
    append_once "${HOME}/.bashrc" "$conteudo"
    [[ -e ${HOME}/.zshrc ]] && append_once "${HOME}/.zshrc" "$conteudo"
    return 0
}

# Avisos acumulados durante a execução e exibidos no resumo final.
add_notice() { NOTICES+=("$1"); }

mark_ok()   { SUMMARY_OK+=("$1"); }
mark_fail() { SUMMARY_FAIL+=("$1"); }
mark_skip() { SUMMARY_SKIP+=("$1"); }

#===============================================================================
# SEÇÃO 5 — Verificações prévias
#===============================================================================

# Arrays associativos exigem Bash 4 ou superior.
check_bash_version() {
    if (( BASH_VERSINFO[0] < 4 )); then
        printf 'Este script requer Bash 4 ou superior (detectado: %s).\n' \
            "${BASH_VERSION}" >&2
        printf 'Execute com: bash %s\n' "$SCRIPT_FILE" >&2
        exit 1
    fi
}

# O script precisa rodar como usuário comum: NVM, Oh My Zsh e a inclusão no
# grupo 'docker' dependem do $HOME e do $USER reais. Sob 'sudo' eles seriam
# aplicados ao root, e não à conta de trabalho.
check_root() {
    if [[ $EUID -eq 0 ]]; then
        msg_error 'Não execute este script como root nem com sudo.'
        msg_info  'Componentes como NVM, Oh My Zsh e o grupo docker precisam do'
        msg_info  'seu usuário real. O script pede sudo apenas onde é necessário.'
        msg_info  "Execute assim:  ./${SCRIPT_FILE}"
        exit 1
    fi
}

# Valida o sudo uma única vez e mantém o ticket vivo, para o script não parar
# pedindo senha no meio de uma instalação longa.
check_sudo() {
    msg_info 'Verificando permissões de sudo...'

    if ! is_installed sudo; then
        msg_error 'O comando sudo não está disponível neste sistema.'
        exit 1
    fi

    if ! sudo -v; then
        msg_error 'Seu usuário não possui permissões de sudo (ou a senha está incorreta).'
        exit 1
    fi
    msg_ok 'Permissões de sudo confirmadas.'

    # Renova o ticket a cada 60s enquanto o script estiver vivo.
    while true; do
        sudo -n true 2>/dev/null
        sleep 60
        kill -0 "$$" 2>/dev/null || exit 0
    done &
    SUDO_KEEPALIVE_PID=$!
}

# Identifica distribuição, versão e codinome a partir de /etc/os-release.
check_os() {
    msg_info 'Detectando o sistema operacional...'

    if [[ ! -r /etc/os-release ]]; then
        msg_error '/etc/os-release não encontrado. Sistema não suportado.'
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    UBUNTU_ID="${ID:-desconhecido}"
    UBUNTU_VERSION="${VERSION_ID:-desconhecida}"
    UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

    if [[ $UBUNTU_ID != 'ubuntu' ]]; then
        if [[ ${ID_LIKE:-} == *ubuntu* || ${ID_LIKE:-} == *debian* ]]; then
            msg_warn "Distribuição '${UBUNTU_ID}' é derivada do Ubuntu, mas não foi testada."
            ask_yes_no 'Deseja continuar mesmo assim?' || exit 0
        else
            msg_error "Distribuição '${UBUNTU_ID}' não é suportada. Use Ubuntu 22.04 ou 24.04."
            exit 1
        fi
    fi

    local suportada=0 v
    for v in "${SUPPORTED_UBUNTU[@]}"; do
        [[ $UBUNTU_VERSION == "$v" ]] && suportada=1 && break
    done

    if [[ $suportada -eq 1 ]]; then
        msg_ok "Sistema: ${PRETTY_NAME:-$UBUNTU_ID $UBUNTU_VERSION} (${UBUNTU_CODENAME})"
    else
        msg_warn "Ubuntu ${UBUNTU_VERSION} não está na lista de versões testadas (${SUPPORTED_UBUNTU[*]})."
        ask_yes_no 'Deseja continuar mesmo assim?' || exit 0
    fi

    if [[ -z $UBUNTU_CODENAME ]]; then
        msg_error 'Não foi possível determinar o codinome da distribuição.'
        exit 1
    fi
}

# Mapeia a arquitetura para os sufixos usados pelos diferentes fabricantes.
check_arch() {
    ARCH_DEB=$(dpkg --print-architecture 2>/dev/null) || ARCH_DEB=''
    case "$ARCH_DEB" in
        amd64) ARCH_UNAME='x86_64' ;;
        arm64) ARCH_UNAME='aarch64' ;;
        '')
            msg_error 'Não foi possível determinar a arquitetura (dpkg indisponível).'
            exit 1
            ;;
        *)
            msg_error "Arquitetura '${ARCH_DEB}' não suportada. Use amd64 ou arm64."
            exit 1
            ;;
    esac
    msg_ok "Arquitetura: ${ARCH_DEB} (${ARCH_UNAME})"
}

# Testa conectividade via HTTPS (o ICMP costuma ser bloqueado em redes
# corporativas, então o ping é apenas o último recurso).
check_internet() {
    msg_info 'Verificando conexão com a Internet...'

    local alvo
    for alvo in 'https://connectivitycheck.gstatic.com/generate_204' \
                'https://archive.ubuntu.com' \
                'https://github.com'; do
        if curl -fsS --max-time 8 -o /dev/null "$alvo" 2>/dev/null; then
            msg_ok 'Conexão com a Internet funcionando normalmente.'
            return 0
        fi
    done

    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        msg_warn 'ICMP responde, mas o acesso HTTPS falhou. Verifique proxy/firewall.'
        ask_yes_no 'Deseja continuar mesmo assim?' && return 0
    fi

    msg_error 'Seu computador não tem conexão com a Internet. Verifique a rede.'
    exit 1
}

#===============================================================================
# SEÇÃO 6 — Módulos de instalação
#
# Cada função abaixo instala UM componente e devolve 0 em sucesso ou != 0 em
# falha. Nenhuma delas chama 'exit': a decisão de continuar é do orquestrador.
#===============================================================================

#------------------------------------------------------------------- utilitários
install_curl() {
    apt_update
    run_step 'Instalando curl' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y curl
}

install_wget() {
    apt_update
    run_step 'Instalando wget' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y wget
}

install_zsh() {
    apt_update
    run_step 'Instalando Zsh' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y zsh
}

#--------------------------------------------------------------- controle de versão
install_git() {
    # O Ubuntu costuma empacotar uma versão alguns meses atrás da atual. O PPA
    # ppa:git-core/ppa é mantido pelos próprios desenvolvedores do Git.
    if ask_yes_no 'Deseja usar o PPA oficial do Git (ppa:git-core/ppa) para obter a versão mais recente?'; then
        if ! is_installed add-apt-repository; then
            apt_install software-properties-common
        fi
        if run_step 'Adicionando ppa:git-core/ppa' \
                sudo env DEBIAN_FRONTEND=noninteractive \
                add-apt-repository -y ppa:git-core/ppa; then
            apt_update
        else
            msg_warn 'Não foi possível adicionar o PPA; usando o repositório padrão do Ubuntu.'
        fi
    else
        apt_update
    fi

    run_step 'Instalando Git' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y git || return 1

    # Validação explícita exigida pela especificação.
    if ! git --version >>"${LOG_FILE:-/dev/null}" 2>&1; then
        msg_error 'O Git foi instalado, mas "git --version" não respondeu.'
        return 1
    fi
    return 0
}

install_gcm() {
    # A Microsoft publica pacotes .deb do Git Credential Manager apenas para
    # x64; em arm64 o componente é declarado incompatível no registry.
    if ! is_installed git; then
        msg_warn 'O Git Credential Manager exige o Git. Instalando o Git primeiro...'
        apt_update
        apt_install git || return 1
    fi

    local url
    url=$(github_latest_asset 'git-ecosystem/git-credential-manager' \
          "gcm-linux_${ARCH_DEB}.*\.deb$")

    if [[ -z $url ]]; then
        msg_error 'Não foi possível localizar o pacote .deb do Git Credential Manager.'
        msg_info  'A API do GitHub pode estar com limite de requisições atingido.'
        return 1
    fi

    install_deb_from_url "$url" || return 1

    run_step 'Configurando o Git Credential Manager' \
        git-credential-manager configure || {
            msg_warn 'GCM instalado, mas "git-credential-manager configure" falhou.'
        }

    add_notice 'Git Credential Manager: em ambiente sem interface gráfica, defina um armazenamento com "git config --global credential.credentialStore gpg" ou "cache".'
    return 0
}

install_gh() {
    add_apt_repo 'githubcli' \
        'https://cli.github.com/packages/githubcli-archive-keyring.gpg' \
        "deb [arch=${ARCH_DEB} signed-by=@KEYRING@] https://cli.github.com/packages stable main" \
        || return 1

    run_step 'Instalando GitHub CLI' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y gh || return 1

    add_notice 'GitHub CLI: autentique-se com "gh auth login".'
    return 0
}

#------------------------------------------------------------------------ editor
install_vscode() {
    # Repositório oficial da Microsoft. Snap não é utilizado, conforme requisito.
    add_apt_repo 'vscode' \
        'https://packages.microsoft.com/keys/microsoft.asc' \
        "deb [arch=amd64,arm64,armhf signed-by=@KEYRING@] https://packages.microsoft.com/repos/code stable main" \
        || return 1

    run_step 'Instalando Visual Studio Code' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y code || return 1

    return 0
}

#--------------------------------------------------------------------- containers
setup_docker_repo() {
    add_apt_repo 'docker' \
        'https://download.docker.com/linux/ubuntu/gpg' \
        "deb [arch=${ARCH_DEB} signed-by=@KEYRING@] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable"
}

install_docker() {
    setup_docker_repo || return 1

    run_step 'Instalando Docker Engine e plugins' \
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        || return 1

    # Grupo docker: permite usar o cliente sem sudo.
    run_step 'Criando o grupo docker' sudo groupadd -f docker
    run_step "Adicionando ${USER} ao grupo docker" sudo usermod -aG docker "$USER"

    # Habilita e inicia o serviço, conforme requisito.
    if is_installed systemctl && [[ -d /run/systemd/system ]]; then
        run_step 'Habilitando e iniciando o serviço docker' \
            sudo systemctl enable --now docker.service
        run_step 'Habilitando e iniciando o serviço containerd' \
            sudo systemctl enable --now containerd.service
    else
        msg_warn 'systemd não está ativo (container/WSL?). Serviços não foram habilitados.'
    fi

    if ! docker --version >>"${LOG_FILE:-/dev/null}" 2>&1; then
        msg_error 'O Docker foi instalado, mas "docker --version" não respondeu.'
        return 1
    fi

    add_notice 'Docker: encerre e reabra a sessão (ou execute "newgrp docker") para usar o docker sem sudo.'
    return 0
}

install_compose() {
    # Em instalações modernas o Compose é um plugin da CLI do Docker.
    if docker compose version >/dev/null 2>&1; then
        msg_info 'O plugin docker-compose-plugin já está presente.'
        return 0
    fi

    if setup_docker_repo && run_step 'Instalando docker-compose-plugin' \
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin; then
        docker compose version >/dev/null 2>&1 && return 0
    fi

    # Plano B: binário estável publicado no repositório oficial docker/compose.
    msg_warn 'Plugin via APT indisponível; usando o binário oficial do projeto docker/compose.'

    local url destino='/usr/local/lib/docker/cli-plugins'
    url=$(github_latest_asset 'docker/compose' "docker-compose-linux-${ARCH_UNAME}$")
    if [[ -z $url ]]; then
        msg_error 'Não foi possível localizar o binário do Docker Compose.'
        return 1
    fi

    run_cmd sudo install -m 0755 -d "$destino" || return 1
    run_step 'Baixando Docker Compose' \
        sudo curl -fL --retry 3 --max-time 300 -o "${destino}/docker-compose" "$url" || return 1
    run_cmd sudo chmod 0755 "${destino}/docker-compose" || return 1

    docker compose version >/dev/null 2>&1
}

#--------------------------------------------------------------------- kubernetes
install_kubectl() {
    # A URL do repositório do Kubernetes embute a minor version, então ela é
    # resolvida dinamicamente a partir do canal estável oficial.
    local stable minor
    stable=$(curl -fsSL --max-time 20 'https://cdn.dl.k8s.io/release/stable.txt' 2>/dev/null)

    if [[ $stable =~ ^v([0-9]+)\.([0-9]+) ]]; then
        minor="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
        msg_info "Versão estável do Kubernetes detectada: ${stable} (canal ${minor})"
    else
        minor="$KUBECTL_FALLBACK_MINOR"
        msg_warn "Não foi possível consultar o canal estável; usando ${minor}."
    fi

    add_apt_repo 'kubernetes' \
        "https://pkgs.k8s.io/core:/stable:/${minor}/deb/Release.key" \
        "deb [signed-by=@KEYRING@] https://pkgs.k8s.io/core:/stable:/${minor}/deb/ /" \
        || return 1

    run_step 'Instalando kubectl' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y kubectl || return 1

    return 0
}

install_minikube() {
    install_deb_from_url \
        "https://storage.googleapis.com/minikube/releases/latest/minikube_latest_${ARCH_DEB}.deb" \
        || return 1

    add_notice 'Minikube: inicie o cluster com "minikube start" (requer Docker ou outro driver).'
    return 0
}

#-------------------------------------------------------------------------- .NET
install_dotnet() {
    # ATENÇÃO: a documentação atual da Microsoft informa que o feed
    # packages.microsoft.com NÃO contém mais pacotes .NET para Ubuntu, e que
    # ele é exclusivo para x64. O caminho oficial hoje é:
    #   24.04 -> feed nativo do Ubuntu (traz o .NET 10)
    #   22.04 -> ppa:dotnet/backports, mantido pela Canonical (traz o .NET 10)
    if [[ $UBUNTU_VERSION == '22.04' ]]; then
        msg_info 'Ubuntu 22.04: o SDK mais recente vem do repositório de backports do .NET.'
        if ! is_installed add-apt-repository; then
            apt_install software-properties-common || return 1
        fi
        run_step 'Adicionando ppa:dotnet/backports' \
            sudo env DEBIAN_FRONTEND=noninteractive \
            add-apt-repository -y ppa:dotnet/backports \
            || msg_warn 'Falha ao adicionar o PPA de backports; tentando o feed padrão do Ubuntu.'
    else
        msg_info "Ubuntu ${UBUNTU_VERSION}: o SDK vem do próprio feed da distribuição."
    fi

    apt_update

    # Descobre o maior dotnet-sdk-N.M disponível — sem versão fixa no código,
    # de modo que o script continue correto quando sair uma major nova.
    local pacote
    pacote=$(apt-cache search --names-only '^dotnet-sdk-[0-9]+\.[0-9]+$' 2>/dev/null \
             | awk '{print $1}' | sort -V | tail -n 1)

    if [[ -n $pacote ]]; then
        msg_info "Pacote selecionado: ${pacote}"
        if run_step "Instalando ${pacote}" sudo env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "$pacote"; then
            if dotnet --version >>"${LOG_FILE:-/dev/null}" 2>&1; then
                return 0
            fi
            msg_warn 'Pacote instalado, mas "dotnet --version" não respondeu.'
        fi
    else
        msg_warn 'Nenhum pacote dotnet-sdk foi encontrado nos repositórios configurados.'
    fi

    # Plano B: instalador oficial da Microsoft, independente de gerenciador de pacotes.
    msg_warn 'Usando o script oficial dotnet-install.sh como alternativa.'
    local instalador="${TMP_DIR}/dotnet-install.sh"

    run_step 'Baixando dotnet-install.sh' \
        curl -fsSL --max-time 120 -o "$instalador" 'https://dot.net/v1/dotnet-install.sh' || return 1
    chmod +x "$instalador" || return 1

    run_step 'Instalando o .NET SDK (canal STS)' bash "$instalador" --channel STS --no-path || return 1

    apply_shell_config 'export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH"'

    add_notice '.NET SDK: instalado em ~/.dotnet. Abra um novo terminal para que o PATH seja aplicado.'
    return 0
}

#---------------------------------------------------------------------- javascript
# Descobre o major da linha LTS atual do Node.js a partir do índice oficial.
# As entradas vêm da mais nova para a mais antiga; a primeira com "lts":"Nome"
# (e não "lts":false) é a LTS vigente.
node_lts_major() {
    local major
    major=$(curl -fsSL --max-time 20 'https://nodejs.org/dist/index.json' 2>/dev/null \
            | tr '{' '\n' \
            | grep -m1 '"lts":"' \
            | sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"v([0-9]+)\..*/\1/p')
    [[ -n $major ]] || return 1
    printf '%s' "$major"
}

install_node() {
    local major
    if ! major=$(node_lts_major); then
        major="$NODE_FALLBACK_MAJOR"
        msg_warn "Não foi possível consultar o índice do Node.js; usando a linha ${major}.x."
    else
        msg_info "Linha LTS atual do Node.js detectada: ${major}.x"
    fi

    if add_apt_repo 'nodesource' \
            'https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key' \
            "deb [arch=${ARCH_DEB} signed-by=@KEYRING@] https://deb.nodesource.com/node_${major}.x nodistro main"; then
        if run_step "Instalando Node.js ${major}.x (NodeSource)" \
                sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs; then
            return 0
        fi
    fi

    # Plano B: script oficial da NodeSource, que também ajusta o repositório.
    msg_warn 'Configuração manual do repositório falhou; usando o script oficial da NodeSource.'
    local instalador="${TMP_DIR}/nodesource_setup.sh"

    run_step 'Baixando setup_lts.x' \
        curl -fsSL --max-time 120 -o "$instalador" 'https://deb.nodesource.com/setup_lts.x' || return 1
    run_step 'Configurando o repositório NodeSource' sudo -E bash "$instalador" || return 1
    run_step 'Instalando Node.js' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y nodejs || return 1

    return 0
}

install_npm() {
    if ! is_installed node; then
        msg_error 'O NPM depende do Node.js, que não está instalado.'
        return 1
    fi

    if ! is_installed npm; then
        msg_info 'NPM não encontrado; instalando o pacote npm.'
        apt_update
        apt_install npm || return 1
    fi

    # Um Node gerenciado pelo NVM vive no HOME e não deve ser tocado com sudo.
    local node_path
    node_path=$(command -v node)

    if [[ $node_path == "$HOME"/* ]]; then
        run_step 'Atualizando o NPM para a última versão' npm install -g npm@latest || return 1
    else
        run_step 'Atualizando o NPM para a última versão' \
            sudo npm install -g npm@latest || return 1
    fi

    return 0
}

install_nvm() {
    local tag
    tag=$(github_latest_tag 'nvm-sh/nvm')
    if [[ -z $tag ]]; then
        msg_error 'Não foi possível descobrir a versão mais recente do NVM.'
        return 1
    fi
    msg_info "Versão do NVM detectada: ${tag}"

    local instalador="${TMP_DIR}/nvm-install.sh"
    run_step "Baixando o instalador do NVM ${tag}" curl -fsSL --max-time 120 -o "$instalador" \
        "https://raw.githubusercontent.com/nvm-sh/nvm/${tag}/install.sh" || return 1

    # PROFILE=/dev/null impede que o instalador edite os arquivos de perfil por
    # conta própria; a configuração é aplicada logo abaixo, de forma idempotente.
    run_step 'Instalando o NVM' env PROFILE=/dev/null bash "$instalador" || return 1

    apply_shell_config 'export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

    if [[ ! -s "${HOME}/.nvm/nvm.sh" ]]; then
        msg_error 'O NVM não foi encontrado em ~/.nvm após a instalação.'
        return 1
    fi

    add_notice 'NVM: abra um novo terminal (ou rode "source ~/.bashrc") e use "nvm install --lts".'
    return 0
}

#---------------------------------------------------------------------- oh my zsh
install_omz() {
    if ! is_installed zsh; then
        msg_info 'O Oh My Zsh depende do Zsh. Instalando o Zsh primeiro...'
        apt_update
        apt_install zsh || return 1
    fi

    if [[ -d "${HOME}/.oh-my-zsh" ]]; then
        msg_info 'O Oh My Zsh já está presente em ~/.oh-my-zsh.'
    else
        local instalador="${TMP_DIR}/omz-install.sh"
        run_step 'Baixando o instalador do Oh My Zsh' curl -fsSL --max-time 120 -o "$instalador" \
            'https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh' || return 1

        # RUNZSH=no  -> não abre um shell zsh ao final
        # CHSH=no    -> NÃO altera o shell padrão automaticamente (requisito)
        run_step 'Instalando o Oh My Zsh' \
            env RUNZSH=no CHSH=no sh "$instalador" --unattended || return 1
    fi

    # O instalador cria um ~/.zshrc novo a partir do template, o que descartaria
    # blocos escritos antes (NVM, .NET). Reaplicamos o que for pertinente.
    if [[ -d "${HOME}/.nvm" ]]; then
        append_once "${HOME}/.zshrc" 'export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
    fi

    # A troca do shell padrão é sempre uma decisão explícita do usuário — nunca
    # acontece de forma automática, nem no modo "instalação completa".
    local zsh_path
    zsh_path=$(command -v zsh)

    if [[ ${SHELL:-} == "$zsh_path" ]]; then
        msg_info 'O Zsh já é o seu shell padrão.'
    elif ASSUME_YES=0 ask_yes_no "Deseja definir o Zsh (${zsh_path}) como seu shell padrão?"; then
        if run_step 'Alterando o shell padrão' chsh -s "$zsh_path"; then
            add_notice 'Shell padrão alterado para Zsh — a mudança vale a partir do próximo login.'
        else
            msg_warn 'Não foi possível alterar o shell. Execute manualmente: chsh -s '"$zsh_path"
        fi
    else
        msg_info "Shell padrão mantido. Para trocar depois: chsh -s ${zsh_path}"
    fi

    return 0
}

#===============================================================================
# SEÇÃO 7 — Registro de componentes
#
# PONTO DE EXTENSÃO. Para adicionar uma ferramenta nova, escreva a função
# install_<nome>() acima e acrescente uma linha aqui. A ordem do array define a
# ordem de instalação e resolve as dependências entre os módulos.
#
#   register_component <id> <nome> <função> <binário> <comando de versão> <arquiteturas>
#===============================================================================

declare -a COMPONENT_ORDER=()
declare -A COMP_NAME=() COMP_FUNC=() COMP_PROBE=() COMP_VERCMD=() COMP_ARCHS=()

register_component() {
    COMPONENT_ORDER+=("$1")
    COMP_NAME["$1"]=$2
    COMP_FUNC["$1"]=$3
    COMP_PROBE["$1"]=$4
    COMP_VERCMD["$1"]=$5
    COMP_ARCHS["$1"]=$6
}

register_components() {
    register_component curl     'Curl'                   install_curl     curl     'curl --version'            'amd64 arm64'
    register_component wget     'Wget'                   install_wget     wget     'wget --version'            'amd64 arm64'
    register_component git      'Git'                    install_git      git      'git --version'             'amd64 arm64'
    register_component gcm      'Git Credential Manager' install_gcm      git-credential-manager 'git-credential-manager --version' 'amd64'
    register_component gh       'GitHub CLI'             install_gh       gh       'gh --version'              'amd64 arm64'
    register_component vscode   'Visual Studio Code'     install_vscode   code     'code --version'            'amd64 arm64'
    register_component docker   'Docker'                 install_docker   docker   'docker --version'          'amd64 arm64'
    register_component compose  'Docker Compose'         install_compose  docker   'docker compose version'    'amd64 arm64'
    register_component kubectl  'Kubectl'                install_kubectl  kubectl  'kubectl version --client'  'amd64 arm64'
    register_component minikube 'Minikube'               install_minikube minikube 'minikube version --short'  'amd64 arm64'
    register_component dotnet   '.NET SDK'               install_dotnet   dotnet   'dotnet --version'          'amd64 arm64'
    register_component node     'NodeJS'                 install_node     node     'node --version'            'amd64 arm64'
    register_component npm      'NPM'                    install_npm      npm      'npm --version'             'amd64 arm64'
    register_component nvm      'NVM'                    install_nvm      nvm      'echo instalado em ~/.nvm'  'amd64 arm64'
    register_component zsh      'Zsh'                    install_zsh      zsh      'zsh --version'             'amd64 arm64'
    register_component omz      'Oh My Zsh'              install_omz      zsh      'echo instalado em ~/.oh-my-zsh' 'amd64 arm64'
}

#===============================================================================
# SEÇÃO 8 — Orquestração
#===============================================================================

# Alguns componentes não expõem um binário no PATH (NVM e Oh My Zsh são
# funções/diretórios). A detecção deles é feita pelo sistema de arquivos.
component_present() {
    case "$1" in
        nvm) [[ -s "${HOME}/.nvm/nvm.sh" ]] ;;
        omz) [[ -d "${HOME}/.oh-my-zsh" ]] ;;
        compose) docker compose version >/dev/null 2>&1 ;;
        *) is_installed "${COMP_PROBE[$1]}" ;;
    esac
}

component_supported_here() {
    [[ " ${COMP_ARCHS[$1]} " == *" ${ARCH_DEB} "* ]]
}

# Executa o ciclo completo de um componente: compatibilidade, detecção,
# confirmação, instalação e validação. Nunca interrompe o script.
install_component() {
    local id=$1 indice=$2 total=$3
    local nome="${COMP_NAME[$id]}"
    local rc versao

    printf '\n%s---------------------------------------------------------------%s\n' \
        "$AZUL" "$SEM_COR"
    printf '%s[%d/%d] %s%s\n' "$NEGRITO" "$indice" "$total" "$nome" "$SEM_COR"
    log_raw "----- [$indice/$total] $nome -----"

    # 1. Arquitetura incompatível não é erro: é componente ignorado.
    if ! component_supported_here "$id"; then
        msg_warn "${nome} não possui pacote oficial para ${ARCH_DEB}. Componente ignorado."
        mark_skip "$nome (sem suporte a ${ARCH_DEB})"
        return 0
    fi

    # 2. Já instalado? Mostra a versão e pergunta se deve atualizar.
    if component_present "$id"; then
        versao=$(get_version "${COMP_VERCMD[$id]}")
        printf '\n%s%s já está instalado.%s\n' "$VERDE" "$nome" "$SEM_COR"
        printf 'Versão:\n%s\n' "$versao"
        log_raw "[INFO]  $nome já instalado — $versao"

        if ! ask_yes_no "Deseja atualizar o ${nome}?"; then
            msg_info "${nome} mantido na versão atual."
            mark_skip "$nome (já instalado)"
            return 0
        fi
    # 3. Ainda não instalado: pede confirmação antes de qualquer download.
    elif ! ask_yes_no "Deseja instalar o ${nome}?"; then
        msg_info "${nome} não será instalado."
        mark_skip "$nome"
        return 0
    fi

    # 4. Instalação propriamente dita.
    msg_info "Iniciando a instalação: ${nome}"
    "${COMP_FUNC[$id]}"
    rc=$?

    # 5. Validação do resultado.
    if [[ $rc -ne 0 ]]; then
        msg_error "Falha ao instalar ${nome} (código ${rc}). Consulte o log para o detalhe."
        mark_fail "$nome"
        return 0
    fi

    if component_present "$id"; then
        versao=$(get_version "${COMP_VERCMD[$id]}")
        msg_ok "${nome} instalado com sucesso — ${versao}"
    else
        # Casos legítimos: binários que só entram no PATH em um novo shell.
        msg_ok "${nome} instalado com sucesso."
        msg_warn "${nome} ainda não está no PATH desta sessão; abra um novo terminal."
    fi
    mark_ok "$nome"
    return 0
}

# Percorre a lista de componentes selecionados.
run_components() {
    local -a lista=("$@")
    local total=${#lista[@]}
    local i=0 id

    if (( total == 0 )); then
        msg_warn 'Nenhum componente selecionado.'
        return 0
    fi

    for id in "${lista[@]}"; do
        i=$(( i + 1 ))
        install_component "$id" "$i" "$total"
    done
}

# Aplica os filtros --only / --skip sobre a ordem canônica de instalação.
selected_components() {
    local -a resultado=()
    local id

    for id in "${COMPONENT_ORDER[@]}"; do
        if (( ${#ONLY_LIST[@]} )) && [[ " ${ONLY_LIST[*]} " != *" ${id} "* ]]; then
            continue
        fi
        if (( ${#SKIP_LIST[@]} )) && [[ " ${SKIP_LIST[*]} " == *" ${id} "* ]]; then
            continue
        fi
        resultado+=("$id")
    done

    (( ${#resultado[@]} )) && printf '%s\n' "${resultado[@]}"
}

#===============================================================================
# SEÇÃO 9 — Atualização do sistema
#===============================================================================

update_system() {
    banner 'Atualização do sistema'

    run_step 'apt update'     sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
    run_step 'apt upgrade'    sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
    run_step 'apt autoremove' sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
    run_step 'apt autoclean'  sudo env DEBIAN_FRONTEND=noninteractive apt-get autoclean -y

    msg_ok 'Atualização do sistema concluída.'
}

#===============================================================================
# SEÇÃO 10 — Menu interativo
#===============================================================================

show_menu() {
    printf '\n%s=========================================%s\n' "$NEGRITO" "$SEM_COR"
    printf '%s %s%s\n' "$NEGRITO" "$SCRIPT_NAME" "$SEM_COR"
    printf '%s=========================================%s\n\n' "$NEGRITO" "$SEM_COR"
    printf 'Escolha uma opção:\n\n'
    printf '  %s1%s - Instalação completa\n'                    "$VERDE"    "$SEM_COR"
    printf '  %s2%s - Escolher componentes individualmente\n'   "$VERDE"    "$SEM_COR"
    printf '  %s3%s - Atualizar sistema apenas\n'               "$VERDE"    "$SEM_COR"
    printf '  %s4%s - Sair\n\n'                                 "$VERMELHO" "$SEM_COR"
    printf '> '
}

# Exibe a lista numerada usada pela opção 2.
list_components() {
    local -a lista=("$@")
    local i=0 id status

    printf '\nComponentes disponíveis:\n\n'
    for id in "${lista[@]}"; do
        i=$(( i + 1 ))
        if ! component_supported_here "$id"; then
            status="${AMARELO}sem suporte a ${ARCH_DEB}${SEM_COR}"
        elif component_present "$id"; then
            status="${VERDE}instalado${SEM_COR}"
        else
            status="${AZUL}não instalado${SEM_COR}"
        fi
        printf '  %2d) %-24s %b\n' "$i" "${COMP_NAME[$id]}" "$status"
    done
    printf '\n'
}

# Interpreta seleções como "1 4 7", "1,4,7", "3-6" ou "todos".
parse_selection() {
    local entrada=$1 total=$2
    local -a escolhidos=()
    local token inicio fim n

    entrada=${entrada//,/ }

    for token in $entrada; do
        case "$token" in
            todos|todas|all|*[!0-9-]*|'')
                if [[ $token == todos || $token == todas || $token == all ]]; then
                    for (( n = 1; n <= total; n++ )); do escolhidos+=("$n"); done
                    continue
                fi
                [[ -n $token ]] && return 1
                ;;
        esac

        if [[ $token == *-* ]]; then
            inicio=${token%%-*}
            fim=${token##*-}
            [[ -n $inicio && -n $fim ]] || return 1
            (( inicio >= 1 && fim <= total && inicio <= fim )) || return 1
            for (( n = inicio; n <= fim; n++ )); do escolhidos+=("$n"); done
        else
            (( token >= 1 && token <= total )) || return 1
            escolhidos+=("$token")
        fi
    done

    (( ${#escolhidos[@]} )) || return 1
    printf '%s\n' "${escolhidos[@]}"
}

menu_individual() {
    local -a disponiveis=("$@")
    local total=${#disponiveis[@]}
    local entrada rc
    local -a indices=() escolha=()

    while true; do
        list_components "${disponiveis[@]}"
        printf 'Informe os números desejados (ex.: 1 3 5-8) ou "todos".\n'
        printf 'Deixe em branco para voltar ao menu.\n\n> '

        entrada=$(read_input); rc=$?
        log_raw "[MENU]  seleção individual: '${entrada}'"

        if input_exhausted "$rc" "$entrada"; then
            printf '\n'
            msg_warn 'Entrada encerrada (EOF). Nenhum componente selecionado.'
            return 0
        fi

        [[ -z $entrada ]] && return 1

        if mapfile -t indices < <(parse_selection "$entrada" "$total") && (( ${#indices[@]} )); then
            break
        fi
        msg_warn 'Seleção inválida. Use números dentro da lista, intervalos (3-6) ou "todos".'
    done

    # Remove duplicatas preservando a ordem canônica de instalação.
    local i id
    for (( i = 1; i <= total; i++ )); do
        if [[ " ${indices[*]} " == *" ${i} "* ]]; then
            id=${disponiveis[i - 1]}
            escolha+=("$id")
        fi
    done

    run_components "${escolha[@]}"
    return 0
}

menu_completo() {
    local -a disponiveis=("$@")

    list_components "${disponiveis[@]}"
    printf 'A instalação completa processará os %d componentes acima.\n' "${#disponiveis[@]}"

    if ask_yes_no 'Deseja confirmar automaticamente cada item (responder S para todos)?'; then
        ASSUME_YES=1
        msg_info 'Modo automático ativado. O Oh My Zsh e a troca de shell continuarão perguntando.'
    else
        msg_info 'Cada componente será confirmado individualmente.'
    fi

    run_components "${disponiveis[@]}"
    ASSUME_YES=0
}

main_menu() {
    local -a disponiveis=()
    mapfile -t disponiveis < <(selected_components)

    if (( ${#disponiveis[@]} == 0 )); then
        msg_error 'Nenhum componente restou após aplicar --only/--skip.'
        return 1
    fi

    local opcao rc
    while true; do
        # --all entra direto na instalação completa, sem exibir o menu.
        if [[ -n $MENU_CHOICE ]]; then
            opcao=$MENU_CHOICE
            MENU_CHOICE=''
        else
            show_menu
            opcao=$(read_input); rc=$?
            log_raw "[MENU]  opção escolhida: '${opcao}'"

            if input_exhausted "$rc" "$opcao"; then
                printf '\n'
                msg_warn 'Entrada encerrada (EOF) sem escolha de menu. Encerrando.'
                msg_info  'Para execução desassistida use: --all --yes'
                return 0
            fi
        fi

        case "$opcao" in
            1) menu_completo "${disponiveis[@]}"; return 0 ;;
            2) menu_individual "${disponiveis[@]}" && return 0 ;;
            3) update_system; return 0 ;;
            4) msg_info 'Saindo a pedido do usuário.'; return 0 ;;
            *) msg_warn 'Opção inválida. Escolha 1, 2, 3 ou 4.' ;;
        esac
    done
}

#===============================================================================
# SEÇÃO 11 — Resumo final
#===============================================================================

summary() {
    [[ $SUMMARY_PRINTED -eq 1 ]] && return 0
    SUMMARY_PRINTED=1

    local item

    printf '\n%s===================================%s\n\n' "$NEGRITO" "$SEM_COR"
    printf '%sResumo da execução%s\n' "$NEGRITO" "$SEM_COR"

    if (( ${#SUMMARY_OK[@]} )); then
        printf '\n%sInstalações concluídas (%d):%s\n\n' "$VERDE" "${#SUMMARY_OK[@]}" "$SEM_COR"
        for item in "${SUMMARY_OK[@]}"; do
            printf '  %s✔%s %s\n' "$VERDE" "$SEM_COR" "$item"
        done
    fi

    if (( ${#SUMMARY_FAIL[@]} )); then
        printf '\n%sInstalações que falharam (%d):%s\n\n' "$VERMELHO" "${#SUMMARY_FAIL[@]}" "$SEM_COR"
        for item in "${SUMMARY_FAIL[@]}"; do
            printf '  %s✘%s %s\n' "$VERMELHO" "$SEM_COR" "$item"
        done
    fi

    if (( ${#SUMMARY_SKIP[@]} )); then
        printf '\n%sIgnorados (%d):%s\n\n' "$AMARELO" "${#SUMMARY_SKIP[@]}" "$SEM_COR"
        for item in "${SUMMARY_SKIP[@]}"; do
            printf '  %s•%s %s\n' "$AMARELO" "$SEM_COR" "$item"
        done
    fi

    if (( ${#NOTICES[@]} )); then
        printf '\n%sPróximos passos:%s\n\n' "$AZUL" "$SEM_COR"
        for item in "${NOTICES[@]}"; do
            printf '  %s→%s %s\n' "$AZUL" "$SEM_COR" "$item"
        done
    fi

    if (( ${#SUMMARY_OK[@]} + ${#SUMMARY_FAIL[@]} + ${#SUMMARY_SKIP[@]} == 0 )); then
        printf '\nNenhum componente foi processado nesta execução.\n'
    fi

    if [[ -n $LOG_FILE ]]; then
        printf '\nLog salvo em:\n\n  %s\n' "$LOG_FILE"
    fi
    printf '\n%s===================================%s\n\n' "$NEGRITO" "$SEM_COR"

    log_raw "Resumo — OK: ${#SUMMARY_OK[@]} | Falhas: ${#SUMMARY_FAIL[@]} | Ignorados: ${#SUMMARY_SKIP[@]}"

    (( ${#SUMMARY_FAIL[@]} == 0 ))
}

#===============================================================================
# SEÇÃO 12 — Argumentos, limpeza e ponto de entrada
#===============================================================================

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Instalador de pós-instalação para Ubuntu LTS (22.04 / 24.04) que prepara um
ambiente de desenvolvimento completo usando apenas repositórios oficiais.

USO
  ./${SCRIPT_FILE} [opções]

OPÇÕES
  --all              Executa a instalação completa sem exibir o menu
  --yes, -y          Responde "sim" às perguntas (o Oh My Zsh e a troca de
                     shell padrão continuam pedindo confirmação explícita)
  --only <ids>       Processa apenas os componentes informados (separados por
                     vírgula). Ex.: --only git,docker,node
  --skip <ids>       Ignora os componentes informados
  --log <arquivo>    Caminho do arquivo de log
                     (padrão: \$HOME/devkit-install.log)
  --no-color         Desativa as cores ANSI
  --version, -v      Mostra a versão do script
  --help, -h         Mostra esta ajuda

COMPONENTES
  curl, wget, git, gcm, gh, vscode, docker, compose, kubectl, minikube,
  dotnet, node, npm, nvm, zsh, omz

EXEMPLOS
  ./${SCRIPT_FILE}                          Menu interativo
  ./${SCRIPT_FILE} --all --yes              Instalação completa desassistida
  ./${SCRIPT_FILE} --only docker,compose    Somente Docker e Docker Compose
  ./${SCRIPT_FILE} --all --skip zsh,omz     Tudo, menos Zsh e Oh My Zsh

O log completo, com horário, comandos executados e erros, é gravado em
\$HOME/devkit-install.log.
EOF
}

# Valida uma lista de ids contra o registry, evitando erros silenciosos de digitação.
validate_ids() {
    local origem=$1; shift
    local -a ids=("$@")
    local id invalidos=()

    for id in "${ids[@]}"; do
        [[ " ${COMPONENT_ORDER[*]} " == *" ${id} "* ]] || invalidos+=("$id")
    done

    if (( ${#invalidos[@]} )); then
        printf 'Componente(s) desconhecido(s) em %s: %s\n' "$origem" "${invalidos[*]}" >&2
        printf 'Válidos: %s\n' "${COMPONENT_ORDER[*]}" >&2
        exit 1
    fi
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --all)      MENU_CHOICE='1'; ASSUME_YES=1 ;;
            -y|--yes)   ASSUME_YES=1 ;;
            --no-color) USE_COLOR=0 ;;
            --only)
                [[ ${2:-} ]] || { printf -- '--only exige uma lista de componentes.\n' >&2; exit 1; }
                IFS=',' read -r -a ONLY_LIST <<<"$2"
                shift
                ;;
            --skip)
                [[ ${2:-} ]] || { printf -- '--skip exige uma lista de componentes.\n' >&2; exit 1; }
                IFS=',' read -r -a SKIP_LIST <<<"$2"
                shift
                ;;
            --log)
                [[ ${2:-} ]] || { printf -- '--log exige um caminho de arquivo.\n' >&2; exit 1; }
                LOG_FILE=$2
                shift
                ;;
            -h|--help)    usage; exit 0 ;;
            -v|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            *)
                printf 'Opção desconhecida: %s\n\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done

    (( ${#ONLY_LIST[@]} )) && validate_ids '--only' "${ONLY_LIST[@]}"
    (( ${#SKIP_LIST[@]} )) && validate_ids '--skip' "${SKIP_LIST[@]}"
    return 0
}

cleanup() {
    local rc=$?
    [[ -n $SUDO_KEEPALIVE_PID ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"
    log_raw "Fim da execução (código ${rc})."
    return 0
}

on_interrupt() {
    printf '\n'
    msg_warn 'Execução interrompida pelo usuário.'
    summary || true
    exit 130
}

main() {
    check_bash_version
    register_components
    parse_args "$@"
    setup_colors
    detect_tty

    trap cleanup EXIT
    trap on_interrupt INT TERM

    banner "$SCRIPT_NAME v$SCRIPT_VERSION"

    check_root
    check_os
    check_arch

    init_log

    check_internet
    check_sudo

    TMP_DIR=$(mktemp -d -t devkit.XXXXXXXX) || {
        msg_error 'Não foi possível criar o diretório temporário.'
        exit 1
    }
    log_raw "Diretório temporário: ${TMP_DIR}"

    main_menu

    summary
}

main "$@"
