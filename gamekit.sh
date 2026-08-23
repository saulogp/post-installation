#!/usr/bin/env bash
#===============================================================================
#
#          FILE: gamekit.sh
#
#         USAGE: ./gamekit.sh [opções]
#
#   DESCRIPTION: Script de pós-instalação para Ubuntu - GameKit
#                Prepara um ambiente completo para jogos Linux, Windows via
#                Steam/Proton e Lutris/Wine, com suporte otimizado para GPU
#                NVIDIA (testado com GeForce RTX 3060).
#
#  REQUIREMENTS: Ubuntu 22.04 ou 24.04, Bash >= 4, sudo, conexão com a Internet,
#                GPU NVIDIA recomendada para melhor desempenho
#        AUTHOR: Saulo Godoy Proetti
#       LICENSE: MIT
#
#===============================================================================

# Strict mode - mas tratamos erros por componente para não parar tudo
set -uo pipefail
IFS=$'\n\t'

#===============================================================================
# SEÇÃO 1 — Identidade do script e configurações globais
#===============================================================================

readonly KIT_ID='gamekit'
readonly KIT_NAME='Ubuntu GameKit Installer'
readonly KIT_VERSION='1.0.0'
readonly KIT_LOG_DEFAULT="${HOME}/gamekit/gamekit-install.log"
readonly KIT_DESCRIPTION='Prepara um ambiente de jogos em Ubuntu com NVIDIA, Steam, Lutris, Wine, Vulkan e ferramentas associadas.'
readonly KIT_AUTO_NOTA='As escolhas de componentes são salvas por sessão.'

# Cores ANSI - respeita NO_COLOR
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly COLOR_RESET=$'\033[0m'
    readonly COLOR_BOLD=$'\033[1m'
    readonly COLOR_GREEN=$'\033[0;32m'
    readonly COLOR_RED=$'\033[0;31m'
    readonly COLOR_YELLOW=$'\033[0;33m'
    readonly COLOR_BLUE=$'\033[0;34m'
    readonly COLOR_MAGENTA=$'\033[0;35m'
    readonly COLOR_CYAN=$'\033[0;36m'
else
    readonly COLOR_RESET=''
    readonly COLOR_BOLD=''
    readonly COLOR_GREEN=''
    readonly COLOR_RED=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_MAGENTA=''
    readonly COLOR_CYAN=''
fi

# Diretórios
readonly GAMEKIT_DIR="${HOME}/gamekit"
readonly LOG_FILE="${GAMEKIT_DIR}/gamekit-install.log"
readonly STEAM_DIR="${HOME}/.steam/l"
readonly WINE_DIR="${HOME}/.wine"
readonly LUTRIS_DIR="${HOME}/.local/share/lutris"

# Variáveis de estado - exportadas para subshells
export GPU_NVIDIA=0
export DRIVER_NVIDIA=0
export VULKAN_SUPPORT=0
export THIRTYTWO_BIT=0
export STEAM_INSTALLED=0
export LUTRIS_INSTALLED=0
export WINE_INSTALLED=0
export WINETRICKS_INSTALLED=0
export GAMEMODE_INSTALLED=0
export MANGOHUD_INSTALLED=0
export ERRORS=0
export SKIPPED=0

# Info do sistema - populada por check_os
export UBUNTU_VERSION=""
export UBUNTU_CODENAME=""
export UBUNTU_ID=""

#===============================================================================
# SEÇÃO 2 — Logging e Helpers
#===============================================================================

# Garante diretório de log
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

# Executa comando logando stdout/stderr no arquivo, mostra status na tela
run_logged() {
    local desc="$1"
    shift
    printf '  %s->%s %s ' "${COLOR_BLUE}" "${COLOR_RESET}" "${desc}"
    log_message "CMD" "${desc}: $*"
    
    local output rc
    output=$("$@" 2>&1)
    rc=$?
    
    # Log completo
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [CMD] $*" >> "${LOG_FILE}" 2>/dev/null || true
    echo "$output" >> "${LOG_FILE}" 2>/dev/null || true
    echo "[$timestamp] [RC] $rc" >> "${LOG_FILE}" 2>/dev/null || true
    
    if [[ $rc -eq 0 ]]; then
        printf '%s[OK]%s\n' "${COLOR_GREEN}" "${COLOR_RESET}"
    else
        printf '%s[ERRO]%s (código %d)\n' "${COLOR_RED}" "${COLOR_RESET}" "$rc"
        # Mostra últimas linhas do erro na tela
        echo "$output" | tail -5 | sed 's/^/    /' >&2
    fi
    return $rc
}

msg_info()  { printf '%s[INFO]%s  %s\n'  "${COLOR_BLUE}"   "${COLOR_RESET}" "$*"; log_message "INFO"  "$*"; }
msg_ok()    { printf '%s[OK]%s    %s\n'  "${COLOR_GREEN}"  "${COLOR_RESET}" "$*"; log_message "OK"    "$*"; }
msg_warn()  { printf '%s[AVISO]%s %s\n'  "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"; log_message "AVISO" "$*"; SKIPPED=$((SKIPPED + 1)); }
msg_error() { printf '%s[ERRO]%s  %s\n'  "${COLOR_RED}"    "${COLOR_RESET}" "$*" >&2; log_message "ERRO"  "$*"; ERRORS=$((ERRORS + 1)); }

banner() {
    local titulo="$1"
    printf '\n%s=========================================%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
    printf '%s %s%s\n' "${COLOR_BOLD}" "$titulo" "${COLOR_RESET}"
    printf '%s=========================================%s\n\n' "${COLOR_BOLD}" "${COLOR_RESET}"
    log_message "BANNER" "$titulo"
}

# Pergunta S/N com normalização
confirm_installation() {
    local prompt_text="$1"
    local response
    
    while true; do
        printf '%s%s%s\n' "${COLOR_CYAN}" "${prompt_text}" "${COLOR_RESET}"
        printf '  %s[S]%s Sim\n' "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s[N]%s Não\n\n' "${COLOR_RED}" "${COLOR_RESET}"
        printf '> '
        read -r response || response='n'
        
        # Normaliza: lowercase, remove acentos básicos
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]' | sed 's/ã/a/;s/á/a/;s/é/e/;s/ó/o/;s/ú/u/')
        
        case "$response" in
            s|sim|y|yes) return 0 ;;
            n|nao|não|no) return 1 ;;
            *) msg_warn "Opção inválida. Digite S ou N." ;;
        esac
    done
}

# Verifica se comando existe
has_cmd() { command -v "$1" >/dev/null 2>&1; }

#===============================================================================
# SEÇÃO 3 — Verificações Preliminares
#===============================================================================

check_root() {
    if [[ $EUID -eq 0 ]]; then
        msg_error "Não execute este script como root nem com sudo."
        msg_info "Configurações de usuário (HOME, grupos, perfis de shell) precisam do seu usuário real."
        msg_info "O script pede sudo apenas onde é necessário."
        msg_info "Execute assim: ./${0##*/}"
        exit 1
    fi
}

check_sudo() {
    msg_info "Verificando permissões de sudo..."
    if ! has_cmd sudo; then
        msg_error "Comando 'sudo' não encontrado."
        return 1
    fi
    if ! sudo -n true 2>/dev/null; then
        # Tenta pedir senha uma vez
        if ! sudo -v; then
            msg_error "Sem permissões sudo válidas."
            return 1
        fi
    fi
    msg_ok "Permissões de sudo confirmadas."
    
    # Mantém ticket vivo
    ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 "$$" 2>/dev/null || exit 0; done ) &
    SUDO_KEEPALIVE_PID=$!
    return 0
}

check_os() {
    msg_info "Detectando sistema operacional..."
    
    if [[ ! -r /etc/os-release ]]; then
        msg_error "/etc/os-release não encontrado."
        return 1
    fi
    
    # shellcheck disable=SC1091
    . /etc/os-release
    
    UBUNTU_ID="${ID:-unknown}"
    UBUNTU_VERSION="${VERSION_ID%%.*}"  # 22 ou 24
    UBUNTU_CODENAME="${VERSION_CODENAME:-}"
    
    export UBUNTU_ID UBUNTU_VERSION UBUNTU_CODENAME
    
    if [[ "$UBUNTU_ID" != "ubuntu" ]]; then
        if [[ "${ID_LIKE:-}" == *ubuntu* || "${ID_LIKE:-}" == *debian* ]]; then
            msg_warn "Distribuição '$UBUNTU_ID' é derivada do Ubuntu, mas não foi testada."
            confirm_installation "Deseja continuar mesmo assim?" || exit 0
        else
            msg_error "Distribuição '$UBUNTU_ID' não suportada. Use Ubuntu 22.04 ou 24.04."
            return 1
        fi
    fi
    
    # Verifica versão suportada EXATAMENTE 22 ou 24
    if [[ "$UBUNTU_VERSION" != "22" && "$UBUNTU_VERSION" != "24" ]]; then
        msg_warn "Ubuntu $VERSION_ID não testado (suportados: 22.04, 24.04)."
        confirm_installation "Deseja continuar mesmo assim?" || exit 0
    fi
    
    if [[ -z "$UBUNTU_CODENAME" ]]; then
        msg_error "Não foi possível determinar o codinome da distribuição."
        return 1
    fi
    
    msg_ok "Sistema: Ubuntu $VERSION_ID ($UBUNTU_CODENAME) - Arquitetura: $(dpkg --print-architecture)"
    return 0
}

check_internet() {
    msg_info "Verificando conexão com a Internet..."
    
    # Tenta HTTPS primeiro (mais confiável que ping)
    local targets=(
        "https://connectivitycheck.gstatic.com/generate_204"
        "https://archive.ubuntu.com"
        "https://github.com"
    )
    
    for target in "${targets[@]}"; do
        if curl -fsS --max-time 8 -o /dev/null "$target" 2>/dev/null; then
            msg_ok "Conexão com a Internet funcionando."
            return 0
        fi
    done
    
    # Fallback: ping
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        msg_warn "ICMP responde, mas HTTPS falhou. Verifique proxy/firewall."
        confirm_installation "Deseja continuar mesmo assim?" && return 0
    fi
    
    msg_error "Sem conexão com a Internet. Verifique a rede."
    return 1
}

detect_gpu_hardware() {
    msg_info "Detectando hardware GPU..."
    
    if has_cmd lspci; then
        local gpu_line
        gpu_line=$(lspci | grep -i -E 'vga|3d|display' | head -1)
        if echo "$gpu_line" | grep -qi nvidia; then
            GPU_NVIDIA=1
            GPU_NAME=$(echo "$gpu_line" | sed 's/.*: //')
            msg_ok "GPU NVIDIA detectada via lspci: $GPU_NAME"
            return 0
        fi
    fi
    
    GPU_NVIDIA=0
    msg_info "GPU NVIDIA não detectada via lspci."
    return 1
}

validate_nvidia_driver() {
    msg_info "Validando driver NVIDIA..."
    
    if ! has_cmd nvidia-smi; then
        msg_warn "nvidia-smi não encontrado. Driver não instalado ou não no PATH."
        DRIVER_NVIDIA=0
        return 1
    fi
    
    # Tenta rodar nvidia-smi - se falhar, driver não carregado
    local smi_output
    smi_output=$(nvidia-smi 2>&1)
    local rc=$?
    
    if [[ $rc -ne 0 ]]; then
        msg_warn "nvidia-smi falhou (código $rc). Driver pode não estar carregado."
        msg_info "Saída: $smi_output"
        DRIVER_NVIDIA=0
        return 1
    fi
    
    # Verifica se kernel module nvidia está carregado
    if ! lsmod | grep -q '^nvidia '; then
        msg_warn "Módulo kernel 'nvidia' não carregado."
        DRIVER_NVIDIA=0
        return 1
    fi
    
    DRIVER_VERSION=$(echo "$smi_output" | grep 'Driver Version' | sed 's/.*: //' | awk '{print $1}')
    msg_ok "Driver NVIDIA válido e carregado: versão $DRIVER_VERSION"
    DRIVER_NVIDIA=1
    return 0
}

configure_nvidia() {
    banner "NVIDIA"
    
    # Detecta hardware se ainda não feito
    if [[ $GPU_NVIDIA -eq 0 ]]; then
        detect_gpu_hardware
    fi
    
    if [[ $GPU_NVIDIA -eq 0 ]]; then
        msg_error "GPU NVIDIA não detectada. O GameKit continuará mas desempenho será limitado."
        return 0
    fi
    
    # Valida driver
    if [[ $DRIVER_NVIDIA -eq 0 ]]; then
        validate_nvidia_driver
    fi
    
    if [[ $DRIVER_NVIDIA -eq 1 ]]; then
        msg_ok "Driver NVIDIA já configurado e funcionando."
        return 0
    fi
    
    # Tenta instalar driver recomendado
    if has_cmd ubuntu-drivers; then
        msg_info "Verificando driver recomendado pelo Ubuntu..."
        local recommended
        recommended=$(ubuntu-drivers devices 2>/dev/null | grep -oP 'recommended: \K.*' | head -1)
        
        if [[ -n "$recommended" ]]; then
            msg_info "Driver recomendado: $recommended"
            if confirm_installation "Instalar driver NVIDIA recomendado ($recommended)? Isso requer reinicialização."; then
                run_logged "Instalando driver NVIDIA" \
                    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$recommended"
                local rc=$?
                if [[ $rc -eq 0 ]]; then
                    msg_ok "Driver instalado. REINICIE O SISTEMA para ativar."
                    DRIVER_NVIDIA=1
                else
                    msg_error "Falha ao instalar driver NVIDIA."
                fi
            else
                msg_info "Instalação de driver pulada pelo usuário."
            fi
        else
            msg_warn "Não foi possível determinar driver recomendado."
            msg_info "Execute manualmente: sudo ubuntu-drivers autoinstall"
        fi
    else
        msg_warn "ubuntu-drivers não disponível."
        msg_info "Instale manualmente: sudo ubuntu-drivers autoinstall"
    fi
    
    return 0
}

#===============================================================================
# SEÇÃO 4 — Suporte 32-bit (i386)
#===============================================================================

check_32bit_support() {
    banner "Arquitetura 32-bit (i386)"
    
    if dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
        msg_ok "Arquitetura i386 já habilitada."
        # Verifica se pacotes i386 instalam
        if apt-cache policy libc6:i386 2>/dev/null | grep -q "Candidate:"; then
            THIRTYTWO_BIT=1
            return 0
        else
            msg_warn "i386 habilitado mas pacotes não disponíveis. Tentando apt update..."
            run_logged "Atualizando lista de pacotes" sudo apt-get update -y
        fi
    fi
    
    msg_info "Arquitetura i386 necessária para Steam, Wine, Proton e jogos 32-bit."
    
    if confirm_installation "Habilitar arquitetura i386?"; then
        run_logged "Adicionando arquitetura i386" sudo dpkg --add-architecture i386
        run_logged "Atualizando lista de pacotes" sudo apt-get update -y
        
        # Testa se funciona
        if apt-cache policy libc6:i386 2>/dev/null | grep -q "Candidate:"; then
            msg_ok "Arquitetura i386 habilitada e funcional."
            THIRTYTWO_BIT=1
            return 0
        else
            msg_error "i386 habilitado mas pacotes ainda não disponíveis."
            return 1
        fi
    else
        msg_warn "i386 não habilitado. Steam, Wine e muitos jogos não funcionarão."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 5 — Vulkan
#===============================================================================

install_vulkan() {
    banner "Vulkan"
    
    msg_info "Verificando suporte Vulkan..."
    
    # Se vulkaninfo existe, testa se FUNCIONA
    if has_cmd vulkaninfo; then
        local vk_test
        vk_test=$(vulkaninfo --summary 2>&1)
        if [[ $? -eq 0 ]] && echo "$vk_test" | grep -qi "device_name"; then
            local gpu_name
            gpu_name=$(echo "$vk_test" | grep -i "device_name" | head -1 | sed 's/.*= //')
            msg_ok "Vulkan funcionando. GPU: $gpu_name"
            VULKAN_SUPPORT=1
            return 0
        else
            msg_warn "vulkaninfo existe mas falhou ao executar. Reinstalando..."
        fi
    fi
    
    # Instala pacotes Vulkan
    local vulkan_pkgs=("vulkan-tools")
    
    # validation layers - nome muda entre versões
    if apt-cache show vulkan-validationlayers 2>/dev/null | grep -q "Package:"; then
        vulkan_pkgs+=("vulkan-validationlayers")
    elif apt-cache show vulkan-validation-layers 2>/dev/null | grep -q "Package:"; then
        vulkan_pkgs+=("vulkan-validation-layers")
    fi
    
    run_logged "Instalando Vulkan tools" sudo apt-get install -y "${vulkan_pkgs[@]}"
    
    # Verifica novamente
    if has_cmd vulkaninfo; then
        local vk_test
        vk_test=$(vulkaninfo --summary 2>&1)
        if [[ $? -eq 0 ]] && echo "$vk_test" | grep -qi "device_name"; then
            local gpu_name
            gpu_name=$(echo "$vk_test" | grep -i "device_name" | head -1 | sed 's/.*= //')
            msg_ok "Vulkan funcionando. GPU: $gpu_name"
            VULKAN_SUPPORT=1
        else
            msg_warn "vulkaninfo instalado mas não detecta GPU."
        fi
    fi
    
    # Se NVIDIA, garante ICD
    if [[ $GPU_NVIDIA -eq 1 ]]; then
        run_logged "Instalando libvulkan1 (NVIDIA ICD)" sudo apt-get install -y libvulkan1 libvulkan1:i386
        
        # Verifica ICD
        if [[ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]]; then
            msg_ok "NVIDIA Vulkan ICD encontrado."
        else
            msg_warn "NVIDIA ICD não encontrado em /usr/share/vulkan/icd.d/nvidia_icd.json"
        fi
    fi
    
    return $([[ $VULKAN_SUPPORT -eq 1 ]] && echo 0 || echo 1)
}

#===============================================================================
# SEÇÃO 6 — Steam
#===============================================================================

install_steam() {
    banner "Steam"
    
    if has_cmd steam; then
        msg_ok "Steam já instalado."
        STEAM_INSTALLED=1
        return 0
    fi
    
    # Garante multiverse (necessário para steam package)
    if ! grep -r "^deb.*multiverse" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -qv "^#"; then
        msg_info "Habilitando repositório multiverse (necessário para Steam)..."
        run_logged "Habilitando multiverse" sudo add-apt-repository -y multiverse
        run_logged "Atualizando lista" sudo apt-get update -y
    fi
    
    # Tenta instalar via apt (repositório oficial Ubuntu)
    run_logged "Instalando Steam via apt" sudo apt-get install -y steam
    
    if has_cmd steam; then
        msg_ok "Steam instalado com sucesso."
        STEAM_INSTALLED=1
        return 0
    fi
    
    # Fallback: .deb oficial
    msg_warn "Falha no apt. Tentando .deb oficial do Steam..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    
    if run_logged "Baixando Steam .deb" curl -fL --retry 3 --max-time 60 -o "${tmp_dir}/steam.deb" "https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb"; then
        if run_logged "Instalando Steam .deb" sudo dpkg -i "${tmp_dir}/steam.deb"; then
            run_logged "Corrigindo dependências" sudo apt-get install -f -y
            if has_cmd steam; then
                msg_ok "Steam instalado via .deb."
                STEAM_INSTALLED=1
                rm -rf "$tmp_dir"
                return 0
            fi
        fi
    fi
    
    rm -rf "$tmp_dir"
    msg_error "Não foi possível instalar Steam."
    return 1
}

#===============================================================================
# SEÇÃO 7 — Proton (Steam Play)
#===============================================================================

configure_proton() {
    banner "Proton (Steam Play)"
    
    if [[ $STEAM_INSTALLED -eq 0 ]]; then
        msg_warn "Steam não instalado. Instale o Steam primeiro."
        return 1
    fi
    
    if ! confirm_installation "Configurar bibliotecas 32-bit para Proton (Steam Play)?"; then
        msg_info "Configuração Proton pulada."
        return 1
    fi
    
    msg_info "Instalando bibliotecas 32-bit necessárias para Proton..."
    
    # Pacotes base (comuns 22.04 e 24.04)
    local proton_pkgs=(
        libsdl2-2.0-0:i386
        libgtk-3-0:i386
        libasound2:i386
        libfreetype6:i386
        libcurl4:i386
    )
    
    # libssl - usa libssl3 que está disponível em ambas as versões
    proton_pkgs+=(libssl3:i386)
    
    # Tenta instalar todos
    local failed=0
    for pkg in "${proton_pkgs[@]}"; do
        if ! run_logged "Instalando $pkg" sudo apt-get install -y "$pkg"; then
            msg_warn "Falha ao instalar $pkg (pode não existir nesta versão)"
            failed=1
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        msg_ok "Bibliotecas 32-bit para Proton instaladas."
    else
        msg_warn "Algumas bibliotecas falharam. Proton pode ter problemas."
    fi
    
    msg_ok "Proton: bibliotecas configuradas."
    msg_info "Para ativar: Steam → Configurações → Compatibilidade → 'Habilitar Steam Play para títulos suportados' e 'para todos os outros títulos'."
    return 0
}

#===============================================================================
# SEÇÃO 8 — Lutris
#===============================================================================

install_lutris() {
    banner "Lutris"
    
    if has_cmd lutris; then
        msg_ok "Lutris já instalado."
        LUTRIS_INSTALLED=1
        return 0
    fi
    
    local installed=0
    
    # Ubuntu 24.04: PPA lutris/lutris não tem build para noble ainda
    if [[ "$UBUNTU_VERSION" == "24" ]]; then
        msg_info "Ubuntu 24.04 detectado: PPA Lutris não tem build para noble. Usando Flatpak."
    else
        # Tenta PPA para 22.04
        msg_info "Adicionando PPA Lutris..."
        if run_logged "Adicionando PPA lutris/lutris" sudo add-apt-repository -y ppa:lutris/lutris; then
            run_logged "Atualizando lista" sudo apt-get update -y
            if run_logged "Instalando Lutris via apt" sudo apt-get install -y lutris; then
                installed=1
            fi
        fi
    fi
    
    # Fallback Flatpak
    if [[ $installed -eq 0 ]]; then
        msg_info "Tentando instalação via Flatpak..."
        
        if ! has_cmd flatpak; then
            run_logged "Instalando Flatpak" sudo apt-get install -y flatpak
        fi
        
        if has_cmd flatpak; then
            run_logged "Adicionando Flathub" flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
            
            # Tenta IDs conhecidos
            for app_id in "org.lutris.Lutris" "net.lutris.Lutris"; do
                if run_logged "Instalando $app_id via Flatpak" flatpak install -y --system flathub "$app_id"; then
                    if flatpak list --system --columns=application | grep -q lutris; then
                        installed=1
                        break
                    fi
                fi
            done
        fi
    fi
    
    if [[ $installed -eq 1 ]]; then
        msg_ok "Lutris instalado."
        LUTRIS_INSTALLED=1
        
        # Wine para Lutris (opcional, Lutris baixa seus próprios runners)
        if confirm_installation "Instalar wine64 e winetricks para suporte Wine no Lutris?"; then
            run_logged "Instalando wine64" sudo apt-get install -y wine64
            run_logged "Instalando winetricks" sudo apt-get install -y winetricks
        fi
        return 0
    fi
    
    msg_error "Não foi possível instalar Lutris (PPA e Flatpak falharam)."
    return 1
}

#===============================================================================
# SEÇÃO 9 — Wine
#===============================================================================

install_wine() {
    banner "Wine"
    
    if has_cmd wine; then
        msg_ok "Wine já instalado: $(wine --version 2>/dev/null | head -1)"
        WINE_INSTALLED=1
        has_cmd wine64 && msg_ok "wine64 disponível."
        return 0
    fi
    
    msg_info "Instalando Wine via repositório WineHQ..."
    
    # Adiciona repo WineHQ se não existe
    if [[ ! -f /etc/apt/sources.list.d/winehq.list ]]; then
        run_logged "Baixando chave WineHQ" \
            sudo wget -O /etc/apt/keyrings/winehq.key https://dl.winehq.org/wine-builds/winehq.key
        
        echo "deb [signed-by=/etc/apt/keyrings/winehq.key] https://dl.winehq.org/wine-builds/ubuntu/ ${UBUNTU_CODENAME} main" | \
            sudo tee /etc/apt/sources.list.d/winehq.list >/dev/null
        
        run_logged "Atualizando lista" sudo apt-get update -y
    fi
    
    # Tenta winehq-stable (meta-pacote que puxa dependências certas)
    if run_logged "Instalando winehq-stable" sudo apt-get install -y --install-recommends winehq-stable; then
        msg_ok "WineHQ Stable instalado."
        WINE_INSTALLED=1
    else
        msg_warn "winehq-stable falhou. Tentando wine-stable (pacote Ubuntu)..."
        if run_logged "Instalando wine-stable" sudo apt-get install -y wine-stable; then
            msg_ok "wine-stable instalado."
            WINE_INSTALLED=1
        else
            msg_error "Falha ao instalar Wine."
            return 1
        fi
    fi
    
    # Verifica wine64
    if has_cmd wine64; then
        msg_ok "wine64 disponível."
    else
        msg_warn "wine64 não encontrado. Tentando instalar wine32:i386..."
        run_logged "Instalando wine32:i386" sudo apt-get install -y wine32:i386 2>/dev/null || \
        run_logged "Instalando wine32" sudo apt-get install -y wine32 2>/dev/null
    fi
    
    # Winetricks separado
    if confirm_installation "Instalar Winetricks?"; then
        run_logged "Instalando Winetricks" sudo apt-get install -y winetricks
        WINETRICKS_INSTALLED=1
    fi
    
    return 0
}

#===============================================================================
# SEÇÃO 10 — Winetricks
#===============================================================================

install_winetricks() {
    banner "Winetricks"
    
    if has_cmd winetricks; then
        msg_ok "Winetricks já instalado: $(winetricks --version 2>/dev/null | head -1)"
        WINETRICKS_INSTALLED=1
        return 0
    fi
    
    if run_logged "Instalando Winetricks" sudo apt-get install -y winetricks; then
        msg_ok "Winetricks instalado."
        WINETRICKS_INSTALLED=1
        msg_info "Componentes (vcrun, dotnet, corefonts, etc.) devem ser instalados por prefixo/jogo:"
        msg_info "  WINEPREFIX=~/.wine-meu-jogo winetricks vcrun2019 corefonts"
        return 0
    fi
    
    msg_error "Falha ao instalar Winetricks."
    return 1
}

#===============================================================================
# SEÇÃO 11 — DXVK / VKD3D (apenas informativo)
#===============================================================================

info_dxvk() {
    banner "DXVK"
    msg_info "DXVK traduz Direct3D 9/10/11 para Vulkan."
    msg_info "Gerenciado automaticamente por:"
    msg_info "  - Steam/Proton (incluso no Proton)"
    msg_info "  - Lutris (via runners Wine)"
    msg_info "Não instale manualmente a menos que precise de versão específica."
    msg_info "Para versões customizadas: use gerenciador de runners do Lutris."
    return 0
}

info_vkd3d() {
    banner "VKD3D / DirectX 12"
    msg_info "VKD3D traduz Direct3D 12 para Vulkan."
    msg_info "Gerenciado automaticamente por Proton (Proton 8+/GE) e Lutris."
    msg_info "Não instale manualmente sem necessidade."
    return 0
}

#===============================================================================
# SEÇÃO 12 — GameMode
#===============================================================================

install_gamemode() {
    banner "GameMode"
    
    if has_cmd gamemoded; then
        msg_ok "GameMode já instalado."
        GAMEMODE_INSTALLED=1
        # Testa se funciona
        if gamemoded -t 2>/dev/null; then
            msg_ok "GameMode funcional (gamemoded -t OK)."
        else
            msg_warn "GameMode instalado mas gamemoded -t falhou."
        fi
        return 0
    fi
    
    if run_logged "Instalando GameMode" sudo apt-get install -y gamemode; then
        msg_ok "GameMode instalado."
        GAMEMODE_INSTALLED=1
        if gamemoded -t 2>/dev/null; then
            msg_ok "GameMode funcional verificado."
        fi
        return 0
    fi
    
    msg_warn "Falha no apt. Tente: sudo add-apt-repository ppa:gamescope-dev/gamescope && sudo apt update && sudo apt install gamemode"
    return 1
}

#===============================================================================
# SEÇÃO 13 — MangoHud
#===============================================================================

install_mangohud() {
    banner "MangoHUD"
    
    if has_cmd mangohud; then
        msg_ok "MangoHUD já instalado: $(mangohud --version 2>/dev/null | head -1)"
        MANGOHUD_INSTALLED=1
        return 0
    fi
    
    if ! confirm_installation "Instalar MangoHUD para monitoramento de desempenho (overlay FPS, GPU, CPU)?"; then
        msg_info "MangoHUD pulado pelo usuário."
        return 1
    fi
    
    if run_logged "Instalando MangoHUD" sudo apt-get install -y mangohud; then
        msg_ok "MangoHUD instalado."
        MANGOHUD_INSTALLED=1
        msg_info "Uso: MANGOHUD=1 comando"
        msg_info "Exemplo: MANGOHUD=1 steam"
        msg_info "No Lutris: configure no runner Wine → 'MangoHUD' → habilitado"
        return 0
    fi
    
    msg_error "Falha ao instalar MangoHUD."
    return 1
}

#===============================================================================
# SEÇÃO 14 — Controladores
#===============================================================================

configure_controllers() {
    banner "Controladores"
    
    msg_info "Verificando suporte a controladores..."
    
    if has_cmd jstest-gtk; then
        msg_ok "jstest-gtk disponível para teste."
    fi
    
    if has_cmd gamecontrollerdb; then
        msg_ok "SDL GameControllerDB disponível."
    fi
    
    # xboxdrv - opcional, só para controles Xbox 360 antigos
    if dpkg -l | grep -q xboxdrv 2>/dev/null; then
        msg_info "xboxdrv instalado (suporte Xbox 360)."
    fi
    
    msg_ok "Suporte básico verificado. Linux reconhece a maioria dos controladores USB/Bluetooth plug-and-play."
    msg_info "Para testar: jstest-gtk (GUI) ou 'cat /dev/input/js0' (bruto)."
    return 0
}

#===============================================================================
# SEÇÃO 15 — Diretórios de Jogos
#===============================================================================

create_game_directories() {
    banner "Diretórios de Jogos"
    
    local dirs=("${HOME}/Games" "${HOME}/Games/Steam" "${HOME}/Games/Lutris" "${HOME}/Games/Other")
    local missing=()
    
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || missing+=("$d")
    done
    
    if [[ ${#missing[@]} -eq 0 ]]; then
        msg_ok "Estrutura de diretórios já existe."
        return 0
    fi
    
    if confirm_installation "Criar estrutura de diretórios para jogos em ~/Games?"; then
        for d in "${missing[@]}"; do
            mkdir -p "$d"
        done
        msg_ok "Diretórios criados:"
        for d in "${dirs[@]}"; do
            msg_info "  $d"
        done
        return 0
    fi
    
    msg_info "Criação de diretórios pulada."
    return 1
}

#===============================================================================
# SEÇÃO 16 — Diagnósticos
#===============================================================================

system_diagnostics() {
    banner "GameKit Diagnostics"
    
    # Recarrega info do sistema
    local os_name="" os_version="" os_codename=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_name="${ID:-unknown}"
        os_version="${VERSION_ID%%.*}"
        os_codename="${VERSION_CODENAME:-}"
    fi
    
    printf "OS:\n  %s %s (%s)\n" "$os_name" "$os_version" "$os_codename"
    printf "Kernel:\n  %s\n" "$(uname -r)"
    
    # Detecta GPU no momento
    local gpu_name=""
    local gpu_nvidia=0
    if has_cmd lspci; then
        local gpu_line
        gpu_line=$(lspci | grep -i -E 'vga|3d|display' | head -1)
        if echo "$gpu_line" | grep -qi nvidia; then
            gpu_nvidia=1
            gpu_name=$(echo "$gpu_line" | sed 's/.*: //')
        fi
    fi
    
    printf "\nGPU:\n"
    if [[ $gpu_nvidia -eq 1 ]]; then
        printf "  %s\n" "$gpu_name"
    else
        printf "  Não detectada ou não-NVIDIA\n"
    fi
    
    # Verifica driver NVIDIA no momento
    local driver_nvidia=0
    local driver_version=""
    if has_cmd nvidia-smi; then
        local smi_output
        smi_output=$(nvidia-smi 2>&1)
        if [[ $? -eq 0 ]] && lsmod | grep -q '^nvidia '; then
            driver_nvidia=1
            driver_version=$(echo "$smi_output" | grep 'Driver Version' | sed 's/.*: //' | awk '{print $1}')
        fi
    fi
    
    printf "\nNVIDIA Driver:\n"
    if [[ $driver_nvidia -eq 1 ]]; then
        printf "  [OK] Versão: %s\n" "$driver_version"
        printf "  Kernel module: %s\n" "$(lsmod | grep '^nvidia ' | awk '{print $1" "$3}' || echo 'NÃO CARREGADO')"
    else
        printf "  [FALHA] Driver não carregado\n"
    fi
    
    printf "\nNVIDIA-SMI:\n"
    if has_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        printf "  [OK]\n"
        nvidia-smi --query-gpu=name,driver_version,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | \
        while IFS=',' read -r name drv mem temp; do
            printf "    GPU: %s | Driver: %s | VRAM: %s MB | Temp: %s°C\n" "$name" "$drv" "$mem" "$temp"
        done
    else
        printf "  [INDISPONÍVEL]\n"
    fi
    
    # Verifica Vulkan no momento
    local vulkan_ok=0
    local vulkan_gpu=""
    if has_cmd vulkaninfo; then
        local vk_test
        vk_test=$(vulkaninfo --summary 2>&1)
        if [[ $? -eq 0 ]] && echo "$vk_test" | grep -qi "device_name"; then
            vulkan_ok=1
            vulkan_gpu=$(echo "$vk_test" | grep -i "device_name" | head -1 | sed 's/.*= //')
        fi
    fi
    
    printf "\nVulkan:\n"
    if [[ $vulkan_ok -eq 1 ]]; then
        printf "  [OK]\n"
        printf "    GPU: %s\n" "$vulkan_gpu"
        if [[ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]]; then
            printf "    ICD NVIDIA: [OK]\n"
        else
            printf "    ICD NVIDIA: [AUSENTE]\n"
        fi
    else
        printf "  [FALHA] vulkaninfo não funciona ou Vulkan não instalado\n"
    fi
    
    # Verifica 32-bit no momento
    local i386_ok=0
    if dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
        if apt-cache policy libc6:i386 2>/dev/null | grep -q "Candidate:"; then
            i386_ok=1
        fi
    fi
    
    printf "\n32-bit (i386):\n"
    if [[ $i386_ok -eq 1 ]]; then
        printf "  [OK] Habilitado (pacotes disponíveis)\n"
    else
        printf "  [NÃO HABILITADO]\n"
    fi
    
    # Verifica apps instalados no momento
    printf "\nSteam:\n"
    if has_cmd steam; then
        printf "  [OK] Instalado\n"
    else
        printf "  [NÃO INSTALADO]\n"
    fi
    
    printf "\nLutris:\n"
    if has_cmd lutris || flatpak list --system --columns=application 2>/dev/null | grep -q lutris; then
        printf "  [OK] Instalado\n"
    else
        printf "  [NÃO INSTALADO]\n"
    fi
    
    printf "\nWine:\n"
    if has_cmd wine; then
        printf "  [OK] %s\n" "$(wine --version 2>/dev/null | head -1)"
        has_cmd wine64 && printf "    wine64: [OK]\n" || printf "    wine64: [AUSENTE]\n"
    else
        printf "  [NÃO INSTALADO]\n"
    fi
    
    printf "\nWinetricks:\n"
    if has_cmd winetricks; then
        printf "  [OK] %s\n" "$(winetricks --version 2>/dev/null | head -1)"
    else
        printf "  [NÃO INSTALADO]\n"
    fi
    
    printf "\nGameMode:\n"
    if has_cmd gamemoded; then
        printf "  [OK] Instalado"
        gamemoded -t 2>/dev/null && printf " (funcional)\n" || printf " (gamemoded -t FALHOU)\n"
    else
        printf "  [NÃO INSTALADO]\n"
    fi
    
    printf "\nMangoHUD:\n"
    if has_cmd mangohud; then
        printf "  [OK] %s\n" "$(mangohud --version 2>/dev/null | head -1)"
    else
        printf "  [NÃO INSTALADO]\n"
    fi
}

nvidia_diagnostics() {
    banner "Diagnóstico NVIDIA Detalhado"
    
    # Detecta GPU no momento
    local gpu_nvidia=0
    if has_cmd lspci; then
        local gpu_line
        gpu_line=$(lspci | grep -i -E 'vga|3d|display' | head -1)
        if echo "$gpu_line" | grep -qi nvidia; then
            gpu_nvidia=1
        fi
    fi
    
    if [[ $gpu_nvidia -eq 0 ]]; then
        msg_error "GPU NVIDIA não detectada."
        return 1
    fi
    
    printf "GPU:\n"
    nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | while read -r name; do
        printf "  %s\n" "$name"
    done
    
    printf "\nDriver:\n"
    nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | while read -r ver; do
        printf "  %s\n" "$ver"
    done
    
    printf "\nVRAM:\n"
    nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r total used free; do
        printf "  Total: %s MB | Usado: %s MB | Livre: %s MB\n" "$total" "$used" "$free"
    done
    
    printf "\nUtilização:\n"
    nvidia-smi --query-gpu=utilization.gpu,utilization.memory --format=csv,noheader,nounits 2>/dev/null | while IFS=',' read -r gpu mem; do
        printf "  GPU: %s%% | Memória: %s%%\n" "$gpu" "$mem"
    done
    
    printf "\nTemperatura:\n"
    nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | while read -r temp; do
        printf "  %s°C\n" "$temp"
    done
    
    printf "\nMódulos kernel:\n"
    lsmod | grep -E 'nvidia|drm' | while read -r line; do
        printf "  %s\n" "$line"
    done
    
    printf "\nVulkan ICD:\n"
    if [[ -f /usr/share/vulkan/icd.d/nvidia_icd.json ]]; then
        printf "  [OK] /usr/share/vulkan/icd.d/nvidia_icd.json\n"
    else
        printf "  [AUSENTE] ICD NVIDIA não encontrado\n"
    fi
}

#===============================================================================
# SEÇÃO 17 — Serviços (stub)
#===============================================================================

start_services() {
    msg_info "Iniciando serviços de jogos..."
    # gamemoded é socket-activated, não precisa start manual
    # steam não roda como serviço
    msg_ok "Nenhum serviço systemd necessário (gamemode é socket-activated)."
}

stop_services() {
    msg_info "Parando serviços..."
    msg_ok "Nenhum serviço para parar."
}

check_services() {
    msg_info "Status dos serviços:"
    systemctl --user status gamemoded 2>/dev/null | head -5 || msg_info "gamemoded: socket-activated (systemd user)"
}

#===============================================================================
# SEÇÃO 18 — Resumo Final
#===============================================================================

summary() {
    banner "GameKit Installation Summary"
    
    # Detecta GPU no momento
    local gpu_name=""
    local gpu_nvidia=0
    if has_cmd lspci; then
        local gpu_line
        gpu_line=$(lspci | grep -i -E 'vga|3d|display' | head -1)
        if echo "$gpu_line" | grep -qi nvidia; then
            gpu_nvidia=1
            gpu_name=$(echo "$gpu_line" | sed 's/.*: //')
        fi
    fi
    
    # Verifica driver NVIDIA no momento
    local driver_nvidia=0
    local driver_version=""
    if has_cmd nvidia-smi; then
        local smi_output
        smi_output=$(nvidia-smi 2>&1)
        if [[ $? -eq 0 ]] && lsmod | grep -q '^nvidia '; then
            driver_nvidia=1
            driver_version=$(echo "$smi_output" | grep 'Driver Version' | sed 's/.*: //' | awk '{print $1}')
        fi
    fi
    
    printf "GPU:\n"
    [[ $gpu_nvidia -eq 1 ]] && printf "  [OK] %s\n" "$gpu_name" || printf "  [INFO] Não detectada\n"
    [[ $driver_nvidia -eq 1 ]] && printf "  [OK] Driver NVIDIA %s\n" "$driver_version" || printf "  [AVISO] Driver não configurado\n"
    
    # Verifica Vulkan no momento
    local vulkan_ok=0
    if has_cmd vulkaninfo; then
        local vk_test
        vk_test=$(vulkaninfo --summary 2>&1)
        if [[ $? -eq 0 ]] && echo "$vk_test" | grep -qi "device_name"; then
            vulkan_ok=1
        fi
    fi
    
    printf "\nVulkan:\n"
    [[ $vulkan_ok -eq 1 ]] && printf "  [OK] Funcionando\n" || printf "  [AVISO] Não configurado\n"
    
    # Verifica 32-bit no momento
    local i386_ok=0
    if dpkg --print-foreign-architectures 2>/dev/null | grep -qx i386; then
        if apt-cache policy libc6:i386 2>/dev/null | grep -q "Candidate:"; then
            i386_ok=1
        fi
    fi
    
    printf "\n32-bit:\n"
    [[ $i386_ok -eq 1 ]] && printf "  [OK] i386 habilitado\n" || printf "  [AVISO] Não habilitado\n"
    
    printf "\nGaming:\n"
    has_cmd steam && printf "  [OK] Steam\n" || printf "  [INFO] Steam não instalado\n"
    (has_cmd lutris || flatpak list --system --columns=application 2>/dev/null | grep -q lutris) && printf "  [OK] Lutris\n" || printf "  [INFO] Lutris não instalado\n"
    has_cmd wine && printf "  [OK] Wine\n" || printf "  [INFO] Wine não instalado\n"
    has_cmd winetricks && printf "  [OK] Winetricks\n" || printf "  [INFO] Winetricks não instalado\n"
    has_cmd gamemoded && printf "  [OK] GameMode\n" || printf "  [INFO] GameMode não instalado\n"
    has_cmd mangohud && printf "  [OK] MangoHUD\n" || printf "  [INFO] MangoHUD não instalado\n"
    
    printf "\n-----------------------------------------\n"
    [[ $ERRORS -gt 0 ]] && msg_error "Erros detectados: $ERRORS"
    [[ $SKIPPED -gt 0 ]] && msg_warn "Componentes ignorados: $SKIPPED"
    
    printf "\nLog completo:\n  %s\n" "$LOG_FILE"
    printf "\nPróximos passos:\n"
    [[ $driver_nvidia -eq 1 ]] && printf "  • REINICIE o sistema para ativar driver NVIDIA\n"
    has_cmd steam && printf "  • Abra Steam e ative Steam Play (Proton) nas configurações\n"
    (has_cmd lutris || flatpak list --system --columns=application 2>/dev/null | grep -q lutris) && printf "  • Abra Lutris e configure runners Wine se necessário\n"
    has_cmd gamemoded && printf "  • Use 'gamemoderun ./jogo' ou adicione 'gamemoderun %%command%%' nas opções de lançamento do Steam\n"
    has_cmd mangohud && printf "  • Use 'MANGOHUD=1 comando' ou habilite no Lutris/Steam\n"
}

#===============================================================================
# SEÇÃO 19 — Main
#===============================================================================

main() {
    # Inicializa log
    >"${LOG_FILE}"
    log_message "START" "GameKit v${KIT_VERSION} iniciado por ${USER} (UID $(id -u))"
    log_message "INFO" "Sistema: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
    
    banner "Ubuntu GameKit v${KIT_VERSION}"
    printf "Preparação de ambiente para jogos em Ubuntu com NVIDIA\n\n"
    
    # Verificações obrigatórias
    check_root
    check_os || exit 1
    check_sudo || exit 1
    check_internet || exit 1
    
    # Detecta hardware GPU
    detect_gpu_hardware
    
    # 32-bit (essencial para quase tudo)
    check_32bit_support
    
    # Diretórios
    create_game_directories
    
    # Menu interativo
    local choice
    while true; do
        printf '\n%s=========================================%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
        printf '%s %s v%s%s\n' "${COLOR_BOLD}" "${KIT_NAME}" "${KIT_VERSION}" "${COLOR_RESET}"
        printf '%s=========================================%s\n\n' "${COLOR_BOLD}" "${COLOR_RESET}"
        printf 'Escolha uma opção:\n\n'
        printf '  %s1%s - Configuração completa (recomendado)\n' "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s2%s - Escolher componentes individualmente\n' "${COLOR_GREEN}" "${COLOR_RESET}"
        printf '  %s3%s - Diagnóstico do sistema\n' "${COLOR_BLUE}" "${COLOR_RESET}"
        printf '  %s4%s - Diagnóstico NVIDIA detalhado\n' "${COLOR_BLUE}" "${COLOR_RESET}"
        printf '  %s5%s - Serviços (status)\n' "${COLOR_CYAN}" "${COLOR_RESET}"
        printf '  %s6%s - Sair\n\n' "${COLOR_RED}" "${COLOR_RESET}"
        printf '> '
        read -r choice || choice=6
        
        case "${choice}" in
            1) # Configuração completa
                printf "\n"
                configure_nvidia
                [[ $THIRTYTWO_BIT -ne 1 ]] && check_32bit_support
                install_vulkan
                
                if confirm_installation "Instalar Steam?"; then
                    install_steam
                fi
                
                [[ $STEAM_INSTALLED -eq 1 ]] && configure_proton
                
                if confirm_installation "Instalar Lutris?"; then
                    install_lutris
                fi
                
                if [[ $LUTRIS_INSTALLED -eq 0 ]] && confirm_installation "Instalar Wine?"; then
                    install_wine
                elif [[ $LUTRIS_INSTALLED -eq 1 ]] && confirm_installation "Garantir Wine/winetricks para Lutris?"; then
                    install_wine
                fi
                
                if [[ $WINE_INSTALLED -eq 1 || $LUTRIS_INSTALLED -eq 1 ]] && confirm_installation "Instalar Winetricks?"; then
                    install_winetricks
                fi
                
                if confirm_installation "Instalar GameMode?"; then
                    install_gamemode
                fi
                
                if confirm_installation "Instalar MangoHUD?"; then
                    install_mangohud
                fi
                
                info_dxvk
                info_vkd3d
                configure_controllers
                summary
                ;;
            
            2) # Componentes individuais
                printf "\n"
                if confirm_installation "Configurar NVIDIA?"; then configure_nvidia; fi
                [[ $THIRTYTWO_BIT -ne 1 ]] && if confirm_installation "Habilitar i386?"; then check_32bit_support; fi
                if confirm_installation "Instalar/verificar Vulkan?"; then install_vulkan; fi
                if confirm_installation "Instalar Steam?"; then install_steam; fi
                [[ $STEAM_INSTALLED -eq 1 ]] && if confirm_installation "Configurar Proton?"; then configure_proton; fi
                if confirm_installation "Instalar Lutris?"; then install_lutris; fi
                if [[ $LUTRIS_INSTALLED -eq 0 ]] && confirm_installation "Instalar Wine?"; then install_wine
                elif [[ $LUTRIS_INSTALLED -eq 1 ]] && confirm_installation "Garantir Wine para Lutris?"; then install_wine; fi
                if [[ $WINE_INSTALLED -eq 1 || $LUTRIS_INSTALLED -eq 1 ]] && confirm_installation "Instalar Winetricks?"; then install_winetricks; fi
                if confirm_installation "Instalar GameMode?"; then install_gamemode; fi
                if confirm_installation "Instalar MangoHUD?"; then install_mangohud; fi
                summary
                ;;
            
            3) system_diagnostics ;;
            4) nvidia_diagnostics ;;
            5) 
                printf "\nServiços:\n"
                printf "1 - Status\n"
                printf "2 - Voltar\n> "
                read -r svc
                case "$svc" in 1) check_services ;; 2) continue ;; *) msg_warn "Opção inválida" ;; esac
                ;;
            6) 
                printf "\nAté mais!\n"
                summary
                break
                ;;
            *) msg_warn "Opção inválida. Escolha 1-6." ;;
        esac
    done
    
    # Cleanup
    [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    log_message "END" "GameKit finalizado. Erros: $ERRORS | Ignorados: $SKIPPED"
}

#===============================================================================
# Entry
#===============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi