#!/usr/bin/env bash
#===============================================================================
#
#          FILE: tests/run-tests.sh
#
#   DESCRIPTION: Testes do motor compartilhado lib/kit-common.sh.
#
#                O motor é usado por todos os kits, então uma quebra nele afeta
#                todos de uma vez — daí a existência desta suíte. Ela roda
#                offline, sem sudo e sem instalar nada: carrega a biblioteca,
#                injeta mocks e exercita apenas a lógica.
#
#         USAGE: ./tests/run-tests.sh
#                Devolve 0 se tudo passar, ou o número de falhas.
#
#===============================================================================

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${TESTS_DIR}/.." && pwd)"

# Metadados exigidos pela biblioteca, como se fôssemos um kit.
readonly KIT_ID='testkit'
readonly KIT_NAME='Kit de Testes'
readonly KIT_VERSION='0.0.0'
readonly KIT_LOG_DEFAULT="${TMPDIR:-/tmp}/kit-tests.log"
readonly KIT_DESCRIPTION='Suíte de testes do motor compartilhado.'

# shellcheck source=../lib/kit-common.sh
source "${REPO_DIR}/lib/kit-common.sh"

#------------------------------------------------------------------ infraestrutura
FALHAS=0
TOTAL=0
SUITE=''

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

USE_COLOR=0
setup_colors
USE_SPINNER=0
TTY_IN=''
LOG_FILE="${TMP_DIR}/testes.log"
: >"$LOG_FILE"
ARCH_DEB='amd64'
ARCH_UNAME='x86_64'
UBUNTU_VERSION='24.04'

suite() { SUITE=$1; printf '\n%s\n' "== $1"; }

check() { # descrição, esperado, obtido
    TOTAL=$(( TOTAL + 1 ))
    if [[ $2 == "$3" ]]; then
        printf '  PASS  %s\n' "$1"
    else
        printf '  FAIL  %s\n        esperado=[%s]\n        obtido  =[%s]\n' "$1" "$2" "$3"
        FALHAS=$(( FALHAS + 1 ))
    fi
}

check_true() { # descrição, comando...
    local desc=$1; shift
    TOTAL=$(( TOTAL + 1 ))
    if "$@" >/dev/null 2>&1; then
        printf '  PASS  %s\n' "$desc"
    else
        printf '  FAIL  %s (esperava sucesso)\n' "$desc"
        FALHAS=$(( FALHAS + 1 ))
    fi
}

check_false() { # descrição, comando...
    local desc=$1; shift
    TOTAL=$(( TOTAL + 1 ))
    if "$@" >/dev/null 2>&1; then
        printf '  FAIL  %s (esperava falha)\n' "$desc"
        FALHAS=$(( FALHAS + 1 ))
    else
        printf '  PASS  %s\n' "$desc"
    fi
}

lista() { tr '\n' ' ' | sed 's/ $//'; }

# Executa uma função com limite de tempo e ecoa a saída dela. Serve para que um
# laço infinito (a regressão clássica dos menus lendo EOF) vire uma falha
# visível em vez de travar a suíte inteira.
com_limite() {
    local segundos=$1; shift
    local arquivo="${TMP_DIR}/limite.$$"
    local pid i=0 rc

    ( "$@" >"$arquivo" 2>&1 ) &
    pid=$!

    while kill -0 "$pid" 2>/dev/null && (( i < segundos * 10 )); do
        sleep 0.1
        i=$(( i + 1 ))
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        printf 'TIMEOUT-APOS-%ss\n' "$segundos"
        return 124
    fi

    wait "$pid"; rc=$?
    cat "$arquivo"
    return "$rc"
}

# Extrai e avalia apenas o register_components() de um kit, sem executá-lo.
carregar_registry_do_kit() {
    COMPONENT_ORDER=()
    COMP_NAME=(); COMP_GROUP=(); COMP_FUNC=()
    COMP_PROBE=(); COMP_VERCMD=(); COMP_ARCHS=(); COMP_CHECK=()
    eval "$(sed -n '/^register_components() {/,/^}/p' "$1")"
    register_components
}

#===============================================================================
suite 'parse_selection'
#===============================================================================
check 'lista simples'        '1 3 5'     "$(parse_selection '1 3 5' 16 | lista)"
check 'separado por vírgula' '1 3 5'     "$(parse_selection '1,3,5' 16 | lista)"
check 'intervalo'            '3 4 5 6'   "$(parse_selection '3-6' 16 | lista)"
check 'misto'                '1 4 5 6 9' "$(parse_selection '1 4-6 9' 16 | lista)"
check '"todos" expande'      '16'        "$(parse_selection 'todos' 16 | wc -l | tr -d ' ')"
check '"all" expande'        '16'        "$(parse_selection 'all' 16 | wc -l | tr -d ' ')"

check_false 'recusa índice acima do total' parse_selection '99' 16
check_false 'recusa zero'                  parse_selection '0' 16
check_false 'recusa texto'                 parse_selection 'abc' 16
check_false 'recusa intervalo invertido'   parse_selection '6-3' 16
check_false 'recusa entrada vazia'         parse_selection '' 16

#===============================================================================
suite 'registry e filtros --only / --skip'
#===============================================================================
COMPONENT_ORDER=(); COMP_NAME=(); COMP_GROUP=(); COMP_FUNC=()
COMP_PROBE=(); COMP_VERCMD=(); COMP_ARCHS=(); COMP_CHECK=()

register_component alfa  'Alfa'  'G1' install_alfa  alfa  'alfa -v'  'amd64 arm64'
register_component beta  'Beta'  'G1' install_beta  beta  'beta -v'  'amd64'
register_component gama  'Gama'  'G2' install_gama  gama  'gama -v'  'amd64 arm64' '[[ -f "$TMP_DIR/gama" ]]'

check 'três componentes registrados' '3'      "${#COMPONENT_ORDER[@]}"
check 'ordem preservada'             'alfa beta gama' "${COMPONENT_ORDER[*]}"
check 'grupo gravado'                'G2'     "${COMP_GROUP[gama]}"
check 'check opcional vazio quando omitido' '' "${COMP_CHECK[alfa]}"

ONLY_LIST=(alfa gama); SKIP_LIST=()
check '--only filtra'  'alfa gama' "$(selected_components | lista)"
ONLY_LIST=(); SKIP_LIST=(beta)
check '--skip filtra'  'alfa gama' "$(selected_components | lista)"
ONLY_LIST=(); SKIP_LIST=()

ARCH_DEB='amd64'
check_true  'beta suportado em amd64'  component_supported_here beta
ARCH_DEB='arm64'
check_false 'beta não suportado em arm64' component_supported_here beta
check_true  'alfa suportado em arm64'  component_supported_here alfa
ARCH_DEB='amd64'

#===============================================================================
suite 'component_present com teste declarado (COMP_CHECK)'
#===============================================================================
check_false 'gama ausente antes do arquivo existir' component_present gama
touch "${TMP_DIR}/gama"
check_true  'gama presente após criar o arquivo'    component_present gama
check_false 'alfa cai no command -v e não existe'   component_present alfa

#===============================================================================
suite 'append_once — idempotência'
#===============================================================================
rc_file="${TMP_DIR}/.bashrc"
printf 'export EDITOR=vim\nalias ll="ls -la"\n' >"$rc_file"

for _ in 1 2 3 4 5; do
    append_once "$rc_file" 'export NVM_DIR="$HOME/.nvm"'
done

check 'um único bloco após 5 execuções' '1' "$(grep -c 'testkit início' "$rc_file")"
check 'conteúdo injetado uma só vez'    '1' "$(grep -c 'NVM_DIR' "$rc_file")"
check 'linha do usuário preservada'     '1' "$(grep -c 'alias ll' "$rc_file")"
check 'sem acúmulo de linhas em branco' '6' "$(wc -l <"$rc_file" | tr -d ' ')"

append_once "$rc_file" 'export DOTNET_ROOT="$HOME/.dotnet"'
check 'bloco antigo substituído'  '0' "$(grep -c 'NVM_DIR' "$rc_file")"
check 'bloco novo presente'       '1' "$(grep -c 'DOTNET_ROOT' "$rc_file")"
check 'usuário segue intacto'     '1' "$(grep -c 'alias ll' "$rc_file")"

rc_novo="${TMP_DIR}/.zshrc"
append_once "$rc_novo" 'export X=1'
append_once "$rc_novo" 'export X=1'
check 'arquivo novo não começa em branco' '# >>> testkit início >>>' "$(head -1 "$rc_novo")"
check 'arquivo novo com 3 linhas'         '3' "$(wc -l <"$rc_novo" | tr -d ' ')"

#===============================================================================
suite 'run_cmd / run_step e formato do log'
#===============================================================================
: >"$LOG_FILE"
USE_SPINNER=0
run_step 'passo que funciona' true >/dev/null;  rc_ok=$?
run_step 'passo que falha'    false >/dev/null; rc_erro=$?
run_cmd printf 'saida-capturada\n'

check 'run_step propaga sucesso' '0' "$rc_ok"
check 'run_step propaga falha'   '1' "$rc_erro"
check 'comandos registrados'     '3' "$(grep -c '\[CMD\]' "$LOG_FILE")"
check 'retornos registrados'     '3' "$(grep -c '\[RC\]' "$LOG_FILE")"
check 'stdout do comando no log' '1' "$(grep -cx 'saida-capturada' "$LOG_FILE")"
check 'timestamp no formato ISO' '1' \
    "$(head -1 "$LOG_FILE" | grep -cE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]')"

: >"$LOG_FILE"
USE_SPINNER=1
run_step 'passo demorado com spinner' sleep 0.3 >/dev/null; rc_spin=$?
run_step 'falha demorada' bash -c 'sleep 0.2; exit 42' >/dev/null; rc_spin_err=$?
check 'spinner: sucesso'          '0'  "$rc_spin"
check 'spinner: código propagado' '42' "$rc_spin_err"
USE_SPINNER=0

#===============================================================================
suite 'ask_yes_no e escopo do ASSUME_YES'
#===============================================================================
ASSUME_YES=1
check_true  'ASSUME_YES=1 responde sim' ask_yes_no 'instalar?'
ASSUME_YES=0
check_false 'sem entrada responde não'  ask_yes_no 'instalar?' </dev/null

# Mecanismo que impede a troca automática de shell mesmo em --all --yes.
ASSUME_YES=1
observado=''
_espia() { observado="$ASSUME_YES"; return 0; }
ASSUME_YES=0 _espia
check 'atribuição inline vale dentro da chamada' '0' "$observado"
check 'atribuição inline não vaza para o global' '1' "$ASSUME_YES"
ASSUME_YES=0

#===============================================================================
suite 'ask_choice e ask_multi_choice'
#===============================================================================
check 'ask_choice devolve a opção escolhida' '2' \
    "$(ask_choice 'Qual?' 'Evince' 'Okular' 'Ambos' 2>/dev/null <<<'2')"
check 'ask_choice aceita a última opção'     '3' \
    "$(ask_choice 'Qual?' 'Evince' 'Okular' 'Ambos' 2>/dev/null <<<'3')"
check 'ask_choice repete e aceita na 2a vez' '1' \
    "$(ask_choice 'Qual?' 'Evince' 'Okular' 2>/dev/null <<<$'9\n1')"

ASSUME_YES=1
check 'ask_choice assume a 1a opção no modo automático' '1' \
    "$(ask_choice 'Qual?' 'Completo' 'Parcial' 2>/dev/null </dev/null)"
ASSUME_YES=0

check_false 'ask_choice devolve erro no EOF' \
    bash -c "source '${REPO_DIR}/lib/kit-common.sh' 2>/dev/null; ask_choice 'q' 'a' 'b' </dev/null"

check 'ask_multi_choice devolve vários índices' '1 3' \
    "$(ask_multi_choice 'Quais?' 'Writer' 'Calc' 'Impress' 2>/dev/null <<<'1 3')"
check 'ask_multi_choice aceita intervalo'       '1 2 3' \
    "$(ask_multi_choice 'Quais?' 'Writer' 'Calc' 'Impress' 2>/dev/null <<<'1-3')"
check 'ask_multi_choice aceita "todos"'         '1 2 3' \
    "$(ask_multi_choice 'Quais?' 'Writer' 'Calc' 'Impress' 2>/dev/null <<<'todos')"

#===============================================================================
suite 'apt_first_available'
#===============================================================================
# Mock: só '7zip' e 'zip' têm candidato; 'p7zip-full' existe mas sem candidato.
apt-cache() {
    case "${2:-}" in
        7zip)       printf '7zip:\n  Installed: (none)\n  Candidate: 23.01+dfsg-8\n' ;;
        zip)        printf 'zip:\n  Installed: (none)\n  Candidate: 3.0-13\n' ;;
        p7zip-full) printf 'p7zip-full:\n  Installed: (none)\n  Candidate: (none)\n' ;;
        *)          return 1 ;;
    esac
}
check 'escolhe o primeiro disponível'        '7zip' "$(apt_first_available 7zip p7zip-full)"
check 'pula o indisponível e pega o próximo' 'zip'  "$(apt_first_available p7zip-full zip)"
check 'ignora pacote inexistente'            'zip'  "$(apt_first_available inexistente zip)"
check_false 'falha quando nada está disponível' apt_first_available p7zip-full inexistente
unset -f apt-cache

#===============================================================================
suite 'install_deb_from_url — nome de arquivo'
#===============================================================================
# Guarda as definições originais para restaurá-las depois: 'unset -f' apagaria
# a função da biblioteca de vez, e recarregar a lib esbarraria nas constantes
# readonly já definidas.
DEB_RECEBIDO=''
_orig_run_step=$(declare -f run_step)
_orig_apt_install=$(declare -f apt_install)

run_step()    { shift; "$@" >/dev/null 2>&1; }
apt_install() { DEB_RECEBIDO=$1; return 0; }
curl()        { return 0; }   # o download em si não interessa aqui

install_deb_from_url 'https://storage.googleapis.com/minikube/releases/latest/minikube_latest_amd64.deb' >/dev/null 2>&1
check 'nome derivado da URL' 'minikube_latest_amd64.deb' "$(basename "$DEB_RECEBIDO")"

install_deb_from_url 'https://discord.com/api/download?platform=linux&format=deb' 'discord.deb' >/dev/null 2>&1
check 'nome explícito respeitado (URL sem .deb)' 'discord.deb' "$(basename "$DEB_RECEBIDO")"

install_deb_from_url 'https://exemplo.com/api/download?x=1' 'pacote' >/dev/null 2>&1
check 'extensão .deb acrescentada quando falta' 'pacote.deb' "$(basename "$DEB_RECEBIDO")"

unset -f curl
eval "$_orig_run_step"
eval "$_orig_apt_install"

#===============================================================================
suite 'orquestrador — sucesso, falha, recusa, já instalado e skip_component'
#===============================================================================
COMPONENT_ORDER=(); COMP_NAME=(); COMP_GROUP=(); COMP_FUNC=()
COMP_PROBE=(); COMP_VERCMD=(); COMP_ARCHS=(); COMP_CHECK=()
SUMMARY_OK=(); SUMMARY_FAIL=(); SUMMARY_SKIP=(); NOTICES=(); SUMMARY_PRINTED=0

register_component ok_novo   'OkNovo'   'G' inst_ok      x 'echo v' 'amd64 arm64'
register_component ja_tem    'JaTem'    'G' inst_ok      x 'echo v' 'amd64 arm64'
register_component quebra    'Quebra'   'G' inst_falha   x 'echo v' 'amd64 arm64'
register_component recusado  'Recusado' 'G' inst_ok      x 'echo v' 'amd64 arm64'
register_component nao_serve 'NaoServe' 'G' inst_ok      x 'echo v' 'amd64'
register_component sem_pkg   'SemPkg'   'G' inst_skip    x 'echo v' 'amd64 arm64'

declare -A PRESENTE=([ja_tem]=sim)
component_present() { [[ ${PRESENTE[$1]:-nao} == sim ]]; }
get_version() { printf 'v9.9.9'; }
inst_ok()    { PRESENTE[$CORRENTE]=sim; return 0; }
inst_falha() { return 7; }
inst_skip()  { skip_component 'sem pacote para esta versão do Ubuntu'; return 0; }

RESPOSTAS=()
ask_yes_no() {
    local r=${RESPOSTAS[0]:-n}
    RESPOSTAS=("${RESPOSTAS[@]:1}")
    [[ $r == s ]]
}
# O mock inst_ok precisa saber qual componente está sendo instalado. Em vez de
# reescrever install_component, envolvemos run_components para publicar o id
# corrente antes de cada chamada — o orquestrador em si roda intacto.
CORRENTE=''
_orig_run_components=$(declare -f run_components)
run_components() {
    local id i=0 total=$#
    for id in "$@"; do
        i=$(( i + 1 ))
        CORRENTE=$id
        install_component "$id" "$i" "$total"
    done
}

#  ok_novo   : instalar? S -> sucesso            => CONCLUÍDO
#  ja_tem    : já instalado, atualizar? N        => IGNORADO
#  quebra    : instalar? S -> rc 7               => FALHOU
#  recusado  : instalar? N                       => IGNORADO
#  nao_serve : arm64 incompatível (ARCH_DEB=amd64 -> compatível, invertemos abaixo)
#  sem_pkg   : instalar? S -> skip_component     => IGNORADO
RESPOSTAS=(s n s n s s)
ARCH_DEB='arm64'
run_components ok_novo ja_tem quebra recusado nao_serve sem_pkg >/dev/null 2>&1
ARCH_DEB='amd64'

check 'concluídos'                   'OkNovo'  "${SUMMARY_OK[*]}"
check 'falhas'                       'Quebra'  "${SUMMARY_FAIL[*]}"
check 'ignorado: já instalado'       'sim'     "$([[ ${SUMMARY_SKIP[*]} == *'JaTem (já instalado)'* ]] && echo sim || echo nao)"
check 'ignorado: recusado'           'sim'     "$([[ ${SUMMARY_SKIP[*]} == *'Recusado'* ]] && echo sim || echo nao)"
check 'ignorado: arquitetura'        'sim'     "$([[ ${SUMMARY_SKIP[*]} == *'sem suporte a arm64'* ]] && echo sim || echo nao)"
check 'ignorado: skip_component'     'sim'     "$([[ ${SUMMARY_SKIP[*]} == *'sem pacote para esta versão'* ]] && echo sim || echo nao)"
check 'skip_component não vira falha' '1'      "${#SUMMARY_FAIL[@]}"
check 'execução seguiu após a falha'  'sim'    "$([[ ${SUMMARY_SKIP[*]} == *'SemPkg'* ]] && echo sim || echo nao)"

summary >/dev/null; rc_sum=$?
check 'summary devolve 1 quando há falha' '1' "$rc_sum"

SUMMARY_OK=(); SUMMARY_FAIL=(); SUMMARY_SKIP=(); SUMMARY_PRINTED=0
summary >/dev/null; rc_sum2=$?
check 'summary devolve 0 sem falhas'      '0' "$rc_sum2"

unset -f run_components component_present get_version ask_yes_no
eval "$_orig_run_components"

#===============================================================================
suite 'menus — EOF encerra em vez de entrar em laço infinito'
#===============================================================================
COMPONENT_ORDER=(); COMP_NAME=(); COMP_GROUP=(); COMP_FUNC=()
COMP_PROBE=(); COMP_VERCMD=(); COMP_ARCHS=(); COMP_CHECK=()
SUMMARY_OK=(); SUMMARY_FAIL=(); SUMMARY_SKIP=(); NOTICES=(); SUMMARY_PRINTED=0
register_component solo 'Solo' 'G' inst_nada solo 'echo v' 'amd64 arm64' 'false'
inst_nada() { return 0; }
MENU_CHOICE=''

saida=$(com_limite 10 main_menu </dev/null); rc_menu=$?
check 'menu encerra no EOF'       '0'   "$rc_menu"
check 'menu avisa sobre o EOF'    'sim' "$(grep -q 'EOF' <<<"$saida" && echo sim || echo nao)"
check 'menu sugere --all --yes'   'sim' "$(grep -q -- '--all --yes' <<<"$saida" && echo sim || echo nao)"

saida=$(printf '9\nzzz\n' | com_limite 10 main_menu); rc_menu2=$?
check 'opções inválidas são recusadas' '2' "$(grep -c 'Opção inválida' <<<"$saida")"
check 'e o laço termina no EOF'        '0' "$rc_menu2"

saida=$(printf '4\n' | com_limite 10 main_menu)
check 'opção 4 sai limpo' 'sim' "$(grep -q 'Saindo a pedido' <<<"$saida" && echo sim || echo nao)"

MENU_CHOICE=''

#===============================================================================
suite 'registries reais dos kits'
#===============================================================================
for kit in devkit utilitieskit; do
    arquivo="${REPO_DIR}/${kit}.sh"

    carregar_registry_do_kit "$arquivo"
    total=${#COMPONENT_ORDER[@]}
    check "${kit}: registrou componentes" 'sim' "$( (( total > 0 )) && echo sim || echo nao )"

    # Toda função referenciada precisa existir no arquivo do kit.
    mapfile -t definidas < <(grep -oE '^install_[a-z0-9_]+\(\)' "$arquivo" | tr -d '()')
    ausentes=''
    for id in "${COMPONENT_ORDER[@]}"; do
        [[ " ${definidas[*]} " == *" ${COMP_FUNC[$id]} "* ]] || ausentes="${ausentes} ${id}:${COMP_FUNC[$id]}"
    done
    check "${kit}: toda função registrada existe" '' "$ausentes"

    # Ids duplicados quebrariam --only/--skip silenciosamente.
    dups=$(printf '%s\n' "${COMPONENT_ORDER[@]}" | sort | uniq -d | lista)
    check "${kit}: sem ids duplicados" '' "$dups"

    # Campos obrigatórios preenchidos.
    vazios=''
    for id in "${COMPONENT_ORDER[@]}"; do
        [[ -n ${COMP_NAME[$id]}  ]] || vazios="${vazios} ${id}:nome"
        [[ -n ${COMP_GROUP[$id]} ]] || vazios="${vazios} ${id}:grupo"
        [[ -n ${COMP_ARCHS[$id]} ]] || vazios="${vazios} ${id}:arch"
    done
    check "${kit}: campos obrigatórios preenchidos" '' "$vazios"

    # O menu agrupa por categoria assumindo que elas são contíguas.
    vistos=''; quebrados=''; anterior=''
    for id in "${COMPONENT_ORDER[@]}"; do
        g="${COMP_GROUP[$id]}"
        if [[ $g != "$anterior" ]]; then
            [[ " ${vistos} " == *" ${g} "* ]] && quebrados="${quebrados} ${g}"
            vistos="${vistos} ${g}"
            anterior=$g
        fi
    done
    check "${kit}: grupos contíguos" '' "$quebrados"
done

check 'devkit mantém os 16 componentes' '16' \
    "$(carregar_registry_do_kit "${REPO_DIR}/devkit.sh"; echo "${#COMPONENT_ORDER[@]}")"
check 'utilitieskit registra 21 aplicativos' '21' \
    "$(carregar_registry_do_kit "${REPO_DIR}/utilitieskit.sh"; echo "${#COMPONENT_ORDER[@]}")"

carregar_registry_do_kit "${REPO_DIR}/devkit.sh"
check 'devkit: ordem canônica preservada' \
    'curl wget git gcm gh vscode docker compose kubectl minikube dotnet node npm nvm zsh omz' \
    "${COMPONENT_ORDER[*]}"

#===============================================================================
printf '\n=====================================================\n'
if (( FALHAS == 0 )); then
    printf ' %d asserções, todas passando\n' "$TOTAL"
else
    printf ' %d asserções, %d FALHA(S)\n' "$TOTAL" "$FALHAS"
fi
printf '=====================================================\n\n'

exit "$FALHAS"
