#!/usr/bin/env bash
#===============================================================================
#
#          FILE: lib/kit-common.sh
#
#   DESCRIPTION: Motor compartilhado pelos instaladores da família Kit
#                (DevKit, UtilitiesKit e os que vierem depois). Concentra log,
#                helpers de APT/Flatpak, verificações prévias, registro de
#                componentes, orquestração, menu, resumo e parsing de flags.
#
#                Este arquivo NÃO é executável por conta própria: ele é
#                carregado com 'source' por um kit, que fornece os metadados e
#                as funções de instalação.
#
#         USAGE: no arquivo do kit, antes de qualquer outra coisa:
#
#                    readonly KIT_ID='utilitieskit'
#                    readonly KIT_NAME='Ubuntu UtilitiesKit Installer'
#                    readonly KIT_VERSION='1.0.0'
#                    readonly KIT_LOG_DEFAULT="${HOME}/utilities-install.log"
#                    readonly KIT_DESCRIPTION='...'
#                    readonly KIT_AUTO_NOTE='...'   # opcional
#
#                    source "$(dirname "${BASH_SOURCE[0]}")/lib/kit-common.sh"
#
#                    install_algo() { ...; }
#                    register_components() { register_component ...; }
#
#                    kit_main "$@"
#
#       LICENSE: MIT
#===============================================================================

# Arrays associativos exigem Bash 4. A checagem vem antes de qualquer
# 'declare -A' porque em Bash 3 essa própria declaração falharia.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
    printf 'Este script requer Bash 4 ou superior (detectado: %s).\n' \
        "${BASH_VERSION:-desconhecido}" >&2
    exit 1
fi

# Proteção contra carregamento duplicado.
[[ -n ${KIT_COMMON_LOADED:-} ]] && return 0
KIT_COMMON_LOADED=1

# 'errexit' NÃO é usado de propósito: o requisito é que a falha de um
# componente jamais interrompa a execução dos demais. O tratamento de erro é
# explícito, via código de retorno de cada função.
set -uo pipefail

#===============================================================================
# SEÇÃO 1 — Constantes globais
#===============================================================================

# Metadados obrigatórios que o kit precisa ter definido antes do 'source'.
for _kit_var in KIT_ID KIT_NAME KIT_VERSION KIT_LOG_DEFAULT; do
    if [[ -z ${!_kit_var:-} ]]; then
        printf 'kit-common.sh: a variável %s precisa ser definida pelo kit antes do source.\n' \
            "$_kit_var" >&2
        exit 1
    fi
done
unset _kit_var

SCRIPT_NAME="$KIT_NAME"
SCRIPT_VERSION="$KIT_VERSION"
SCRIPT_FILE="${0##*/}"

# Versões do Ubuntu oficialmente suportadas/testadas.
readonly SUPPORTED_UBUNTU=('22.04' '24.04')

# Diretórios padrão do APT (padrão Debian/Ubuntu moderno).
readonly KEYRINGS_DIR='/etc/apt/keyrings'
readonly SOURCES_DIR='/etc/apt/sources.list.d'
readonly PREFERENCES_DIR='/etc/apt/preferences.d'

# Marcadores que delimitam os blocos injetados nos arquivos de perfil do shell.
# Derivam do KIT_ID para que cada kit gerencie apenas o próprio bloco.
RC_BEGIN="# >>> ${KIT_ID} início >>>"
RC_END="# <<< ${KIT_ID} fim <<<"

readonly FLATHUB_URL='https://dl.flathub.org/repo/flathub.flatpakrepo'

#===============================================================================
# SEÇÃO 2 — Estado global (mutável)
#===============================================================================

LOG_FILE="${KIT_LOG:-$KIT_LOG_DEFAULT}"
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
SKIP_REASON=''          # preenchido por skip_component() dentro de um módulo

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

# Menu numerado de escolha única.
#
#   escolha=$(ask_choice 'Qual leitor de PDF?' 'Evince' 'Okular')
#
# Ecoa na stdout o índice escolhido (base 1); todo o diálogo vai para a stderr,
# porque a stdout é capturada por substituição de comando. Devolve != 0 no EOF.
ask_choice() {
    local pergunta=$1; shift
    local -a opcoes=("$@")
    local total=${#opcoes[@]}
    local resposta rc i

    (( total > 0 )) || return 1

    # Em modo automático assume a primeira opção, que por convenção é a
    # recomendada/mais completa.
    if [[ $ASSUME_YES -eq 1 ]]; then
        log_raw "[ASK]   $pergunta -> 1 (automático: ${opcoes[0]})"
        printf '1'
        return 0
    fi

    while true; do
        {
            printf '\n%s%s%s\n\n' "$NEGRITO" "$pergunta" "$SEM_COR"
            for (( i = 0; i < total; i++ )); do
                printf '  %s[%d]%s %s\n' "$VERDE" "$(( i + 1 ))" "$SEM_COR" "${opcoes[i]}"
            done
            printf '\n> '
        } >&2

        resposta=$(read_input); rc=$?

        if input_exhausted "$rc" "$resposta"; then
            log_raw "[ASK]   $pergunta -> EOF"
            return 1
        fi

        if [[ $resposta =~ ^[0-9]+$ ]] && (( resposta >= 1 && resposta <= total )); then
            log_raw "[ASK]   $pergunta -> ${resposta} (${opcoes[resposta - 1]})"
            printf '%s' "$resposta"
            return 0
        fi
        msg_warn "Opção inválida. Escolha um número de 1 a ${total}." >&2
    done
}

# Menu numerado de escolha múltipla, reaproveitando parse_selection().
# Ecoa os índices escolhidos separados por espaço. Devolve != 0 no EOF.
ask_multi_choice() {
    local pergunta=$1; shift
    local -a opcoes=("$@")
    local total=${#opcoes[@]}
    local resposta rc i
    local -a indices=()

    (( total > 0 )) || return 1

    if [[ $ASSUME_YES -eq 1 ]]; then
        for (( i = 1; i <= total; i++ )); do indices+=("$i"); done
        log_raw "[ASK]   $pergunta -> todos (automático)"
        printf '%s' "${indices[*]}"
        return 0
    fi

    while true; do
        {
            printf '\n%s%s%s\n\n' "$NEGRITO" "$pergunta" "$SEM_COR"
            for (( i = 0; i < total; i++ )); do
                printf '  %s[%d]%s %s\n' "$VERDE" "$(( i + 1 ))" "$SEM_COR" "${opcoes[i]}"
            done
            printf '\nInforme os números desejados (ex.: 1 3) ou "todos".\n\n> '
        } >&2

        resposta=$(read_input); rc=$?

        if input_exhausted "$rc" "$resposta"; then
            log_raw "[ASK]   $pergunta -> EOF"
            return 1
        fi

        if mapfile -t indices < <(parse_selection "$resposta" "$total") && (( ${#indices[@]} )); then
            log_raw "[ASK]   $pergunta -> ${indices[*]}"
            printf '%s' "${indices[*]}"
            return 0
        fi
        msg_warn "Seleção inválida. Use números de 1 a ${total}, intervalos ou \"todos\"." >&2
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

# Instala um pacote simples do repositório do Ubuntu com feedback padronizado.
# Cobre a maioria esmagadora dos módulos, que são só um 'apt install'.
apt_install_step() {
    local nome=$1; shift
    apt_update
    run_step "Instalando ${nome}" sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

# Devolve o primeiro pacote da lista que tem candidato instalável. Permite
# lidar com nomes que mudam entre versões do Ubuntu (ex.: 7zip x p7zip-full)
# sem chumbar a versão da distribuição no código.
apt_first_available() {
    local pkg
    for pkg in "$@"; do
        if apt-cache policy "$pkg" 2>/dev/null | grep -qE 'Candidate:[[:space:]]+[^([:space:]]'; then
            printf '%s' "$pkg"
            return 0
        fi
    done
    return 1
}

# Habilita um componente do repositório do Ubuntu (universe, multiverse) quando
# o pacote desejado não estiver disponível sem ele.
ensure_apt_component() {
    local componente=$1

    if apt-cache policy 2>/dev/null | grep -q "/${componente}[[:space:]]"; then
        return 0
    fi

    if ! is_installed add-apt-repository; then
        apt_install software-properties-common || return 1
    fi

    run_step "Habilitando o componente '${componente}' do Ubuntu" \
        sudo env DEBIAN_FRONTEND=noninteractive add-apt-repository -y "$componente" || return 1
    apt_update
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

# Escreve uma regra de prioridade em /etc/apt/preferences.d/<nome>.
# Necessária quando o repositório do fabricante precisa vencer um pacote de
# mesmo nome do Ubuntu — é o caso do Firefox, cujo pacote da distribuição é
# apenas um transitional package que puxa o Snap.
add_apt_pin() {
    local nome=$1 conteudo=$2
    local arquivo="${PREFERENCES_DIR}/${nome}"

    run_cmd sudo install -m 0755 -d "$PREFERENCES_DIR" || return 1
    printf '%s\n' "$conteudo" | run_cmd sudo tee "$arquivo" || return 1
    run_cmd sudo chmod 0644 "$arquivo"
}

# Baixa um .deb e o instala com apt-get, que resolve dependências
# automaticamente (ao contrário de 'dpkg -i').
#
#   $1 URL
#   $2 nome do arquivo de destino (opcional). Necessário quando a URL não
#      termina em .deb — o apt-get identifica pacotes locais pela extensão.
#      Ex.: https://discord.com/api/download?platform=linux&format=deb
install_deb_from_url() {
    local url=$1
    local nome_arquivo=${2:-}

    [[ -n $nome_arquivo ]] || nome_arquivo=$(basename "${url%%\?*}")
    [[ $nome_arquivo == *.deb ]] || nome_arquivo="${nome_arquivo}.deb"

    local arquivo="${TMP_DIR}/${nome_arquivo}"

    if ! run_step "Baixando ${nome_arquivo}" \
            curl -fL --retry 3 --max-time 300 -o "$arquivo" "$url"; then
        msg_error "Falha no download de ${url}"
        return 1
    fi

    apt_install "$arquivo"
}

# Garante o Flatpak e o remote Flathub. Só é chamado sob demanda, quando um
# módulo não encontra caminho oficial via APT — a ordem de preferência do
# projeto é: repositório oficial > .deb do fabricante > Flatpak.
ensure_flatpak() {
    if ! is_installed flatpak; then
        msg_info 'Instalando o Flatpak (necessário para este aplicativo)...'
        apt_update
        apt_install flatpak || {
            msg_error 'Falha ao instalar o Flatpak.'
            return 1
        }
        # Integração com a loja é desejável, mas não pode derrubar a instalação.
        apt_install gnome-software-plugin-flatpak \
            || msg_warn 'Plugin do GNOME Software não instalado (opcional).'
    fi

    if ! flatpak remotes --columns=name 2>/dev/null | grep -qx 'flathub'; then
        run_step 'Adicionando o remote Flathub' \
            sudo flatpak remote-add --if-not-exists flathub "$FLATHUB_URL" || return 1
    fi
    return 0
}

# Instala um aplicativo do Flathub.
flatpak_install() {
    local app_id=$1
    local nome=${2:-$1}

    ensure_flatpak || return 1

    run_step "Instalando ${nome} via Flatpak" \
        sudo flatpak install -y --noninteractive flathub "$app_id" || return 1

    add_notice "${nome} foi instalado via Flatpak; pode ser preciso reabrir a sessão para o ícone aparecer no menu."
    return 0
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

    log_raw "[RC]    bloco ${KIT_ID} aplicado em ${arquivo}"
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

# Um módulo pode declarar que o componente não é aplicável a este sistema —
# pacote inexistente na versão do Ubuntu, upstream descontinuado, escolha
# cancelada pelo usuário. Vira IGNORADO no resumo, e não falha, porque não há
# nada de errado com a execução: aquele software simplesmente não se aplica.
skip_component() {
    SKIP_REASON=$1
    return 0
}

mark_ok()   { SUMMARY_OK+=("$1"); }
mark_fail() { SUMMARY_FAIL+=("$1"); }
mark_skip() { SUMMARY_SKIP+=("$1"); }

#===============================================================================
# SEÇÃO 5 — Verificações prévias
#===============================================================================

# O script precisa rodar como usuário comum: instalações no HOME e a inclusão
# em grupos dependem do $HOME e do $USER reais. Sob 'sudo' seriam aplicadas ao
# root, e não à conta de trabalho.
check_root() {
    if [[ $EUID -eq 0 ]]; then
        msg_error 'Não execute este script como root nem com sudo.'
        msg_info  'Configurações de usuário (HOME, grupos, perfis de shell) precisam'
        msg_info  'do seu usuário real. O script pede sudo apenas onde é necessário.'
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
# SEÇÃO 6 — Registro de componentes
#
# PONTO DE EXTENSÃO dos kits. Cada kit define register_components() chamando:
#
#   register_component <id> <nome> <grupo> <função> <binário> <cmd de versão> \
#                      <arquiteturas> [<teste de presença>]
#
# O último argumento é opcional: quando informado, substitui a checagem padrão
# 'command -v <binário>'. Serve para o que não expõe binário no PATH (um
# diretório no HOME, um subcomando, um pacote de biblioteca).
#===============================================================================

declare -a COMPONENT_ORDER=()
declare -A COMP_NAME=() COMP_GROUP=() COMP_FUNC=() COMP_PROBE=() \
           COMP_VERCMD=() COMP_ARCHS=() COMP_CHECK=()

register_component() {
    COMPONENT_ORDER+=("$1")
    COMP_NAME["$1"]=$2
    COMP_GROUP["$1"]=$3
    COMP_FUNC["$1"]=$4
    COMP_PROBE["$1"]=$5
    COMP_VERCMD["$1"]=$6
    COMP_ARCHS["$1"]=$7
    COMP_CHECK["$1"]=${8:-}
}

#===============================================================================
# SEÇÃO 7 — Orquestração
#===============================================================================

# Presença do componente: usa o teste declarado no registry quando existir,
# senão cai na checagem padrão pelo PATH.
component_present() {
    local id=$1
    if [[ -n ${COMP_CHECK[$id]:-} ]]; then
        eval "${COMP_CHECK[$id]}" >/dev/null 2>&1
    else
        is_installed "${COMP_PROBE[$id]}"
    fi
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
    SKIP_REASON=''
    "${COMP_FUNC[$id]}"
    rc=$?

    # 5. O módulo pode ter concluído que o componente não se aplica aqui.
    if [[ -n $SKIP_REASON ]]; then
        msg_warn "${nome}: ${SKIP_REASON}"
        mark_skip "${nome} (${SKIP_REASON})"
        return 0
    fi

    # 6. Validação do resultado.
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
# SEÇÃO 8 — Atualização do sistema
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
# SEÇÃO 9 — Menu interativo
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

# Lista numerada usada pela opção 2, agrupada por categoria. Os componentes de
# uma mesma categoria são contíguos na ordem de registro, por construção.
list_components() {
    local -a lista=("$@")
    local i=0 id status grupo grupo_atual=''

    printf '\nComponentes disponíveis:\n'
    for id in "${lista[@]}"; do
        i=$(( i + 1 ))

        grupo="${COMP_GROUP[$id]}"
        if [[ $grupo != "$grupo_atual" ]]; then
            printf '\n  %s%s%s\n' "$NEGRITO" "$grupo" "$SEM_COR"
            grupo_atual=$grupo
        fi

        if ! component_supported_here "$id"; then
            status="${AMARELO}sem suporte a ${ARCH_DEB}${SEM_COR}"
        elif component_present "$id"; then
            status="${VERDE}instalado${SEM_COR}"
        else
            status="${AZUL}não instalado${SEM_COR}"
        fi
        printf '  %2d) %-26s %b\n' "$i" "${COMP_NAME[$id]}" "$status"
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
        if [[ -n ${KIT_AUTO_NOTE:-} ]]; then
            msg_info "Modo automático ativado. ${KIT_AUTO_NOTE}"
        else
            msg_info 'Modo automático ativado.'
        fi
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
# SEÇÃO 10 — Resumo final
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
# SEÇÃO 11 — Argumentos, limpeza e ponto de entrada
#===============================================================================

# A lista de componentes é gerada a partir do registry, e não repetida em texto
# fixo — assim a ajuda nunca diverge do que o kit realmente instala.
usage() {
    local ids
    ids=$(printf '%s, ' "${COMPONENT_ORDER[@]}")
    ids=${ids%, }

    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

${KIT_DESCRIPTION:-Instalador de pós-instalação para Ubuntu LTS (22.04 / 24.04).}

USO
  ./${SCRIPT_FILE} [opções]

OPÇÕES
  --all              Executa a instalação completa sem exibir o menu
  --yes, -y          Responde "sim" às perguntas
  --only <ids>       Processa apenas os componentes informados (separados por
                     vírgula)
  --skip <ids>       Ignora os componentes informados
  --log <arquivo>    Caminho do arquivo de log
                     (padrão: ${KIT_LOG_DEFAULT})
  --no-color         Desativa as cores ANSI
  --version, -v      Mostra a versão do script
  --help, -h         Mostra esta ajuda

COMPONENTES
$(printf '%s' "$ids" | fold -s -w 70 | sed 's/^/  /')

EXEMPLOS
  ./${SCRIPT_FILE}
      Menu interativo

  ./${SCRIPT_FILE} --all --yes
      Instalação completa desassistida

  ./${SCRIPT_FILE} --only ${COMPONENT_ORDER[0]},${COMPONENT_ORDER[1]}
      Somente os componentes informados

O log completo, com horário, comandos executados e erros, é gravado em
${KIT_LOG_DEFAULT}.
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

# Ponto de entrada compartilhado. O kit chama isto na última linha do arquivo,
# depois de já ter definido register_components() e as funções install_*().
kit_main() {
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

    TMP_DIR=$(mktemp -d -t "${KIT_ID}.XXXXXXXX") || {
        msg_error 'Não foi possível criar o diretório temporário.'
        exit 1
    }
    log_raw "Diretório temporário: ${TMP_DIR}"

    main_menu

    summary
}
