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

#===============================================================================
# SEÇÃO 1 — Identidade do script e configurações globais
#===============================================================================

# Configurações de identidade
readonly KIT_ID='gamekit'
readonly KIT_NAME='Ubuntu GameKit Installer'
readonly KIT_VERSION='1.0.0'
readonly KIT_LOG_DEFAULT="${HOME}/gamekit/gamekit-install.log"
readonly KIT_DESCRIPTION='Prepara um ambiente de jogos em Ubuntu com NVIDIA, Steam,'
readonly KIT_DESCRIPTION+=' Lutris, Wine, Vulkan e herramientas associadas.'
readonly KIT_AUTO_NOTA='As escolhas de componentes são salvas por sessão.'

# Cores ANSI para mensagens
COLOR_RESET='\033[0m'
COLOR_BOLD='\033[1m'
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_MAGENTA='\033[0;35m'
COLOR_CYAN='\033[0;36m'

# Diretórios do GameKit
readonly GAMEKIT_DIR="${HOME}/gamekit"
readonly LOG_FILE="${GAMEKIT_DIR}/gamekit-install.log"
STEAM_DIR="${HOME}/.steam/l"
WINE_DIR="${HOME}/.wine"
LUTRIS_DIR="${HOME}/.local/share/lutris"

# Variáveis de estado
GPU_NVIDIA=0
DRIVER_NVIDIA=0
VULKAN_SUPPORT=0
THIRTYTWO_BIT=0
STEAM_INSTALLED=0
LUTRIS_INSTALLED=0
WINE_INSTALLED=0
GAMEMODE_INSTALLED=0
MANGOHUD_INSTALLED=0
ERRORS=0
SKIPPED=0

# Arquetipos de componentes
INSTALL_NVIDIA=0
INSTALL_VULKAN=0
INSTALL_STEAM=0
INSTALL_LUTRIS=0
INSTALL_WINE=0
INSTALL_WINETRICKS=0
INSTALL_GAMEMODE=0
INSTALL_MANGOHUD=0

#===============================================================================
# SEÇÃO 2 — Funções de verificação e helpers
#===============================================================================

# Função: log_message
# Descrição: Registra mensagens no log
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo "[$timestamp] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null
}

# Função: check_os
# Descrição: Verifica se o sistema operacional é Ubuntu compatível
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        UBUNTU_VERSION=${VERSION_ID%%.*}
        if [[ "$ID" == "ubuntu" ]] && { [[ "$UBUNTU_VERSION" -ge 22 ]] || [[ "$UBUNTU_VERSION" -ge 24 ]]; }; then
            msg_info "Sistema operacional verificado: Ubuntu ${VERSION_ID}"
            return 0
        fi
    fi
    msg_error "Este script requer Ubuntu 22.04 ou 24.04."
    return 1
}

# Função: check_sudo
# Descrição: Verifica se o usuário tem permissões sudo
check_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        msg_info "Executando como root."
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            return 0
        fi
    fi
    msg_error "Sem permissões sudo. O script precisa de sudo para instalar pacotes."
    return 1
}

# Função: check_internet
# Descrição: Verifica conexão com a internet
check_internet() {
    if command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
            return 0
        fi
    fi
    if command -v curl >/dev/null 2>&1; then
        if curl --output /dev/null --silent --head --fail https://httpbin.org/get 2>/dev/null; then
            return 0
        fi
    fi
    msg_warn "Sem conexão com a internet detectada. Algumas instalações podem falhar."
    return 1
}

# Função: detect_gpu
# Descrição: Detecta GPU e configura variáveis de estado
detect_gpu() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_NVIDIA=1
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
        msg_ok "GPU NVIDIA detectada: ${GPU_NAME}."
        
        # Verificar versão do driver
        DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
        msg_info "Versão do driver NVIDIA: ${DRIVER_VERSION}."
        DRIVER_NVIDIA=1
        return 0
    fi
    GPU_NVIDIA=0
    msg_info "GPU NVIDIA não detectada."
    return 1
}

# Função: msg_info
# Descrição: Mostra mensagem informacional
msg_info() {
    printf "${COLOR_BLUE}[INFO]${COLOR_RESET} %s\n" "$1"
    log_message "INFO" "$1"
}

# Função: msg_ok
# Descrição: Mostra mensagem de sucesso
msg_ok() {
    printf "${COLOR_GREEN}[OK]${COLOR_RESET} %s\n" "$1"
    log_message "OK" "$1"
}

# Função: msg_warn
# Descrição: Mostra mensagem de aviso
msg_warn() {
    printf "${COLOR_YELLOW}[AVISO]${COLOR_RESET} %s\n" "$1"
    log_message "AVISO" "$1"
    SKIPPED=$((SKIPPED + 1))
}

# Função: msg_error
# Descrição: Mostra mensagem de erro
msg_error() {
    printf "${COLOR_RED}[ERRO]${COLOR_RESET} %s\n" "$1"
    log_message "ERRO" "$1"
    ERRORS=$((ERRORS + 1))
}

# Função: apt_update
# Descrição: Atualiza lista de pacotes APT
apt_update() {
    if command -v apt-get >/dev/null 2>&1; then
        sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
        return $?
    fi
    return 1
}

# Função: confirm_installation
# Descrição: Pergunta ao usuário se deseja instalar um componente
confirm_installation() {
    local component_name="$1"
    local prompt_text="$2"
    
    while true; do
        printf "${COLOR_CYAN}%s${COLOR_RESET}\n" "${prompt_text}"
        printf "${COLOR_CYAN}[S] Sim${COLOR_RESET} ${COLOR_YELLOW}[N] Não${COLOR_RESET}\n"
        printf ">${COLOR_RESET} "
        read -r response
        case "$response" in
            [SsYy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) printf "Por favor, responda S ou N.\n";;
        esac
    done
}

# Função: check_architecture
# Descrição: Verifica arquitetura do sistema
check_architecture() {
    ARCH=$(uname -m)
    msg_info "Arquitetura do sistema: ${ARCH}"
    if [[ "${ARCH}" == "x86_64" ]]; then
        msg_ok "Arquitetura de 64 bits confirmada."
        return 0
    fi
    msg_warn "Arquitetura incomum: ${ARCH}"
    return 1
}

#===============================================================================
# SEÇÃO 3 — Função: check_32bit_support
#===============================================================================

# Função: check_32bit_support
# Descrição: Verifica e habilita arquitetura i386
check_32bit_support() {
    msg_info "Verificando suporte a arquitetura 32-bit..."
    
    if [ "$(dpkg --print-foreign-architectures 2>/dev/null)" = "i386" ]; then
        msg_ok "Arquitetura i386 já está habilitada."
        THIRTYTWO_BIT=1
        return 0
    fi
    
    msg_info "Arquitetura i386 não está habilitada."
    msg_info "Ela é necessária para compatibilidade com determinados jogos e componentes."
    
    if confirm_installation "i386" "Deseja habilitar a arquitetura i386?"; then
        if sudo dpkg --add-architecture i386 >/dev/null 2>&1; then
            msg_ok "Arquitetura i386 habilitada."
            sudo apt update -qq >/dev/null 2>&1
            THIRTYTWO_BIT=1
            return 0
        else
            msg_error "Não foi possível habilitar a arquitetura i386."
            return 1
        fi
    else
        msg_info "Arquitetura i386 ignorada pelo usuário. Alguns jogos podem não funcionar."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 4 — Função: configure_nvidia
#===============================================================================

# Função: configure_nvidia
# Descrição: Detecta e configura driver NVIDIA
configure_nvidia() {
    printf "\n=========================================\n"
    printf " NVIDIA\n"
    printf "=========================================\n"
    
    # Verificar se GPU NVIDIA está presente
    if [ ${GPU_NVIDIA} -eq 0 ]; then
        if detect_gpu; then
            # GPU já detectada e variáveis definidas
            :
        else
            msg_error "GPU NVIDIA não detectada."
            msg_info "O GameKit continuará, mas o desempenho em jogos pode ser limitado."
        fi
    fi
    
    # Verificar driver instalado
    if [ ${DRIVER_NVIDIA} -eq 0 ]; then
        msg_info "Verificando driver NVIDIA instalado..."
        if nvidia-smi >/dev/null 2>&1; then
            msg_ok "Driver NVIDIA já está instalado e funcionando."
            DRIVER_NVIDIA=1
        else
            # Verificar if ubuntu-drivers command exists
            if command -v ubuntu-drivers >/dev/null 2>&1; then
                msg_info "Verificando driver recomendado pelo Ubuntu..."
                RECOMMENDED_DRIVER=$(ubuntu-drivers devices 2>/dev/null | grep -oP 'recommended: \K.*' | head -1)
                if [ -n "${RECOMMENDED_DRIVER}" ]; then
                    msg_info "Driver recomendado: ${RECOMMENDED_DRIVER}."
                    if confirm_installation "driver-nvidia" "Deseja instalar o driver recomendado pelo Ubuntu?\n\nIsso pode requerer reinicialização do sistema."; then
                        msg_info "Instalando driver NVIDIA recomendado..."
                        if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${RECOMMENDED_DRIVER}" >/dev/null 2>&1; then
                            msg_ok "Driver NVIDIA instalado com sucesso."
                            DRIVER_NVIDIA=1
                            msg_warn "Reinicie o sistema para que as alterações tenham efeito completo."
                        else
                            msg_error "Falha ao instalar driver NVIDIA."
                        fi
                    else
                        msg_info "Driver NVIDIA ignorado pelo usuário."
                    fi
                else
                    msg_warn "Não foi possível determinar driver recomendado."
                    msg_info "Tente rodar: ubuntu-drivers autoinstall"
                fi
            else
                msg_warn "ubuntu-drivers não disponível."
                msg_info "Instale o driver manualmente ou rode: sudo ubuntu-drivers autoinstall"
            fi
        fi
    else
        msg_ok "Driver NVIDIA já verificado anteriormente."
    fi
    
    return 0
}

#===============================================================================
# SEÇÃO 5 — Função: enable_i386 e check_32bit_support
#===============================================================================

# Já implementado acima como check_32bit_support

#===============================================================================
# SEÇÃO 6 — Função: install_vulkan
#===============================================================================

# Função: install_vulkan
# Descrição: Instala/verifica componentes Vulkan
install_vulkan() {
    printf "\n=========================================\n"
    printf " Vulkan\n"
    printf "=========================================\n"
    
    msg_info "Verificando suporte a Vulkan..."
    
    # Verificar se vulkaninfo está disponível
    if command -v vulkaninfo >/dev/null 2>&1; then
        msg_ok "Vulkan Tools já estão instalados."
        VULKAN_SUPPORT=1
        
        # Tentar identificar GPU Vulkan
        local gpu_info
        gpu_info=$(vulkaninfo 2>/dev/null | grep -i "device_name" | head -1 | sed 's/.*: //')
        if [ -n "${gpu_info}" ]; then
            msg_info "GPU Vulkan detectada: ${gpu_info}"
        fi
        return 0
    fi
    
    # Tentar instalar vulkan-tools
    msg_info "Instalando vulkan-tools e bibliotecas..."
    
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y vulkan-tools vulkan-validationlayers 2>/dev/null; then
        msg_ok "vulkan-tools instalados com sucesso."
        
        # Verificar se agora vulkaninfo está disponível
        if command -v vulkaninfo >/dev/null 2>&1; then
            VULKAN_SUPPORT=1
            msg_ok "Vulkan está disponível."
            
            # Tentar identificar GPU
            local gpu_info
            gpu_info=$(vulkaninfo 2>/dev/null | grep -i "device_name" | head -1 | sed 's/.*: //')
            if [ -n "${gpu_info}" ]; then
                msg_info "GPU Vulkan detectada: ${gpu_info}"
            fi
            return 0
        fi
    else
        msg_warn "Não foi possível instalar vulkan-tools totalmente."
    fi
    
    # Verificar extensões NVIDIA específicas
    if [ ${GPU_NVIDIA} -eq 1 ] && [ ${VULKAN_SUPPORT} -eq 0 ]; then
        msg_info "Tentando configurar bibliotecas Vulkan para NVIDIA..."
        if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y libvulkan1 libvulkan1:i386 2>/dev/null; then
            msg_ok "Bibliotecas Vulkan NVIDIA instaladas."
        fi
    fi
    
    return 1
}

#===============================================================================
# SEÇÃO 7 — Função: install_steam
#===============================================================================

# Função: install_steam
# Descrição: Instala Steam
install_steam() {
    printf "\n=========================================\n"
    printf " Steam\n"
    printf "=========================================\n"
    
    # Verificar se Steam já está instalado
    if command -v steam >/dev/null 2>&1; then
        msg_ok "Steam já está instalado."
        STEAM_INSTALLED=1
        return 0
    fi
    
    # Verificar se steamdeck repo já está configurado
    if [ -f /etc/apt/sources.list.d/steam.list ]; then
        msg_info "Repositório Steam já configurado."
    else
        msg_info "Adicionando repositório oficial do Steam..."
        if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y steamwise 2>/dev/null; then
            msg_ok "Repositório Steam configurado."
        else
            # Tentar método alternativo - baixar .deb
            msg_info "Tentando método alternativo para Steam..."
            local arch_deb
            if [ "$(uname -m)" = "aarch64" ]; then
                arch_deb="arm64"
            else
                arch_deb="amd64"
            fi
            local tmp_dir
            tmp_dir=$(mktemp -d)
            if curl -sL "https://cdn steamstatic.com/installer/steam.deb" -o "${tmp_dir}/steam.deb" 2>/dev/null; then
                if sudo dpkg -i "${tmp_dir}/steam.deb" >/dev/null 2>&1; then
                    msg_ok "Steam instalado via .deb."
                    STEAM_INSTALLED=1
                else
                    msg_warn "Falha ao instalar .deb do Steam."
                fi
            else
                msg_error "Não foi possível baixar o instalador do Steam."
            fi
            rm -rf "$tmp_dir"
        fi
    fi
    
    # Verificação final
    if command -v steam >/dev/null 2>&1; then
        STEAM_INSTALLED=1
        msg_ok "Steam instalado e disponível."
        return 0
    else
        msg_error "Steam não pôde ser instalado."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 8 — Função: configure_proton
#===============================================================================

# Função: configure_proton
# Descrição: Configura Proton para Steam Play
configure_proton() {
    printf "\n=========================================\n"
    printf " Proton (Steam Play)\n"
    printf "=========================================\n"
    
    msg_info "O Proton é utilizado pelo Steam para executar jogos Windows."
    msg_info "Verificando se Steam está instalado..."
    
    if [ ${STEAM_INSTALLED} -eq 0 ]; then
        msg_warn "Steam não está instalado. Configure o Steam primeiro."
        return 1
    fi
    
    # Perguntar ao usuário
    if confirm_installation "proton" "Deseja configurar o Steam Play para jogos Windows?"; then
        msg_info "Configurando Proton e bibliotecas necessárias..."
        
        # Instalar bibliotecas necessárias para Proton
        if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
            libsd2-gm0-libs:i386 \
            libgtk-3-0:i386 \
            libasound2:i386 \
            libfreetype6:i386 \
            libcurl4-openssl-dev:i386 \
            libssl1.1:i386 2>/dev/null; then
            msg_ok "Bibliotecas 32-bit para Proton instaladas."
        else
            msg_warn "Não foi possível instalar todas as bibliotecas 32-bit."
        fi
        
        msg_ok "Proton configurado. Ative 'Steam Play' na interface do Steam para usar."
        msg_info "Para ativar: Abra Steam → Configurações → Conta → Biblioteca → \"Habilitar Steam Play para todos os outros títulos\"."
        return 0
    else
        msg_info "Configuração do Proton ignorada pelo usuário."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 9 — Função: install_lutris
#===============================================================================

# Função: install_lutris
# Descrição: Instala Lutris
install_lutris() {
    printf "\n=========================================\n"
    printf " Lutris\n"
    printf "=========================================\n"
    
    # Verificar se Lutris já está instalado
    if command -v lutris >/dev/null 2>&1; then
        msg_ok "Lutris já está instalado."
        LUTRIS_INSTALLED=1
        return 0
    fi
    
    msg_info "Instalando Lutris via repositório oficial..."
    
    # Adicionar repositório Lutris
    if sudo env DEBIAN_FRONTEND=noninteractive apt-add-repository -y ppa:lutris/lutris 2>/dev/null; then
        msg_ok "Repositório Lutris adicionado."
    else
        msg_warn "Não foi possível adicionar repositório Lutris."
        msg_info "Tentando instalação via Flatpak..."
        if command -v flatpak >/dev/null 2>&1; then
            flatpak install flathub org.lutris Lutris 2>/dev/null
            if command -v lutris >/dev/null 2>&1; then
                LUTRIS_INSTALLED=1
                msg_ok "Lutris instalado via Flatpak."
                return 0
            fi
        fi
        return 1
    fi
    
    # Atualizar e instalar
    apt_update
    
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y lutris 2>/dev/null; then
        msg_ok "Lutris instalado com sucesso."
        LUTRIS_INSTALLED=1
        
        # Configurar Wine básico para Lutris
        msg_info "Configurando suporte Wine básico para Lutris..."
        if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y wine64 winetricks 2>/dev/null; then
            msg_ok "Wine e Winetricks instalados para Lutris."
        fi
        return 0
    else
        msg_error "Falha ao instalar Lutris."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 10 — Função: install_wine
#===============================================================================

# Função: install_wine
# Descrição: Instala Wine
install_wine() {
    printf "\n=========================================\n"
    printf " Wine\n"
    printf "=========================================\n"
    
    # Verificar se Wine já está instalado
    if command -v wine >/dev/null 2>&1; then
        msg_ok "Wine já está instalado."
        WINE_INSTALLED=1
        # Verificar wine64
        if command -v wine64 >/dev/null 2>&1; then
            msg_ok "Wine64 está disponível."
        else
            msg_warn "Wine64 não encontrado, mas wine32 pode estar instalado."
        fi
        return 0
    fi
    
    msg_info "Instalando Wine estável via repositório..."
    
    # Adicionar repositório WineHQ
    if [ ! -f /etc/apt/sources.list.d/winehq.list ]; then
        msg_info "Adicionando repositório WineHQ..."
        sudo wget -NP /etc/apt/trusted.gpg.d/ https://winehq.org/keys/winehq.key 2>/dev/null
        echo "deb https://winehq.org/Ubuntu focal main" | sudo tee /etc/apt/sources.list.d/winehq.list >/dev/null 2>&1
    fi
    
    apt_update
    
    # Instalar Wine stable
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y wine-stable 2>/dev/null; then
        msg_ok "Wine Stable instalado com sucesso."
        WINE_INSTALLED=1
        
        # Verificar wine64
        if command -v wine64 >/dev/null 2>&1; then
            msg_ok "Wine64 está disponível."
        else
            msg_info "Instalando suporte 32-bit para Wine..."
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y wine32 2>/dev/null
        fi
        
        # Instalar winetricks
        msg_info "Instalando Winetricks..."
        if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y winetricks 2>/dev/null; then
            msg_ok "Winetricks instalado."
        fi
        
        return 0
    else
        msg_warn "Falha ao instalar WineStable via repositório oficial."
        msg_info "Tentando instalar winehq-stable..."
        if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y winehq-stable 2>/dev/null; then
            msg_ok "winehq-stable instalado."
            WINE_INSTALLED=1
            return 0
        fi
        
        # Tentar instalação via Flatpak
        msg_info "Tentando instalação via Flatpak..."
        if command -v flatpak >/dev/null 2>&1; then
            flatpak install flathub wine 2>/dev/null
        fi
        
        return 1
    fi
}

#===============================================================================
# SEÇÃO 11 — Função: install_winetricks
#===============================================================================

# Função: install_winetricks
# Descrição: Instala Winetricks
install_winetricks() {
    printf "\n=========================================\n"
    printf " Winetricks\n"
    printf "=========================================\n"
    
    # Verificar se Winetricks já está instalado
    if command -v winetricks >/dev/null 2>&1; then
        msg_ok "Winetricks já está instalado."
        WINE_INSTALLED=1
        return 0
    fi
    
    msg_info "Instalando Winetricks..."
    
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y winetricks 2>/dev/null; then
        msg_ok "Winetricks instalado com sucesso."
        
        # Não instalar componentes automáticos (vcrun, dotnet, directx, corefonts)
        msg_info "Winetricks instalado. Componentes como vcrun, dotnet, directx e corefonts"
        msg_info "devem ser instalados por jogo, quando necessários, via: winetricks <componente>"
        return 0
    else
        msg_error "Não foi possível instalar Winetricks."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 12 — Função: configure_dxvk
#===============================================================================

# Função: configure_dxvk
# Descrição: Prepara ambiente DXVK
configure_dxvk() {
    printf "\n=========================================\n"
    printf " DXVK\n"
    printf "=========================================\n"
    
    msg_info "DXVK traduz Direct3D 9/10/11 para Vulkan."
    msg_info "Este componente é geralmente gerenciado automaticamente pelo Proton/Lutris."
    msg_info "Não instale manualmente versões específicas sem necessidade."
    msg_info "O Proton já inclui DXVK integrado. O Lutris também o gerencia automaticamente."
    msg_info "Se precisar de uma versão específica, utilize o gerenciador de runners do Lutris."
    
    # Apenas verificar se está disponível
    if [ ${STEAM_INSTALLED} -eq 1 ] || [ ${LUTRIS_INSTALLED} -eq 1 ]; then
        msg_info "DXVK deverá estar disponível através do Proton ou Lutris."
    fi
    
    return 0
}

#===============================================================================
# SEÇÃO 13 — Função: configure_vkd3d
#===============================================================================

# Função: configure_vkd3d
# Descrição: Prepara suporte DirectX 12
configure_vkd3d() {
    printf "\n=========================================\n"
    printf " VKD3D / DirectX 12\n"
    printf "=========================================\n"
    
    msg_info "VKD3D traduz Direct3D 12 para Vulkan."
    msg_info "Assim como DXVK, é gerenciado automaticamente pelo Proton/Lutris."
    msg_info "Não faça instalação manual desnecessária caso Proton/Lutris já forneçam o componente."
    
    return 0
}

#===============================================================================
# SEÇÃO 14 — Função: install_gamemode
#===============================================================================

# Função: install_gamemode
# Descrição: Instala GameMode
install_gamemode() {
    printf "\n=========================================\n"
    printf " GameMode\n"
    printf "=========================================\n"
    
    # Verificar se GameMode já está instalado
    if command -v gamemoded >/dev/null 2>&1; then
        msg_ok "GameMode já está instalado."
        GAMEMODE_INSTALLED=1
        return 0
    fi
    
    msg_info "Instalando GameMode..."
    
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y gamemode 2>/dev/null; then
        msg_ok "GameMode instalado com sucesso."
        GAMEMODE_INSTALLED=1
        
        # Verificar comando de teste
        if command -v gamemoded -t >/dev/null 2>&1; then
            msg_ok "GameMode funcional verificado."
        fi
        return 0
    else
        msg_warn "Não foi possível instalar GameMode via APT."
        msg_info "Tente: sudo add-apt-repository ppa:gamescope-dev/gamescope && sudo apt update && sudo apt install gamemode"
        return 1
    fi
}

#===============================================================================
# SEÇÃO 15 — Função: install_mangohud
#===============================================================================

# Função: install_mangohud
# Descrição: Instala MangoHUD
install_mangohud() {
    printf "\n=========================================\n"
    printf " MangoHUD\n"
    printf "=========================================\n"
    
    # Verificar se MangoHUD já está instalado
    if command -v mangohud >/dev/null 2>&1; then
        msg_ok "MangoHUD já está instalado."
        MANGOHUD_INSTALLED=1
        return 0
    fi
    
    msg_info "Instalando MangoHUD..."
    
    # Perguntar antes de instalar
    if confirm_installation "mangohud" "Deseja instalar MangoHUD para monitoramento de desempenho?"; then
        if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y mangohud 2>/dev/null; then
            msg_ok "MangoHUD instalado com sucesso."
            MANGOHUD_INSTALLED=1
            
            # Informar sobre overlay
            msg_info "MangoHUD pode ser ativado via:"
            msg_info "  - Terminal: MANGOHUD=1 <comando>"
            msg_info "  - Emulação: Gerenciadores de runners (Lutris, Bottles)"
            return 0
        else
            msg_error "Não foi possível instalar MangoHUD."
            return 1
        fi
    else
        msg_info "MangoHUD ignorado pelo usuário."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 16 — Função: configure_controllers
#===============================================================================

# Função: configure_controllers
# Descrição: Configura suporte a controladores
configure_controllers() {
    printf "\n=========================================\n"
    printf " Controladores\n"
    printf "=========================================\n"
    
    msg_info "Verificando reconhecimento de controladores..."
    
    # Verificar dispositivos de entrada
    if command -v jstest-gtk >/dev/null 2>&1; then
        msg_info "jstest-gtk disponível para teste de controladores."
    fi
    
    # Verificar controladores Xbox/PlayStation via xboxdrv ou similar
    if dpkg -l | grep -q xboxdrv 2>/dev/null; then
        msg_info "xboxdrv instalado para suporte a controladores Xbox."
    fi
    
    # Verificar Bluetooth
    msg_info "Controladores Bluetooth devem ser reconhecidos automaticamente no Linux."
    msg_info "Para controladores USB, basta conectar e verificar em 'jstest-gtk' ou 'gamecontrollers'."
    
    msg_ok "Suporte básico verificado. O Linux reconhece a maioria dos controladores plug-and-play."
    return 0
}

#===============================================================================
# SEÇÃO 17 — Função: create_game_directories
#===============================================================================

# Função: create_game_directories
# Descrição: Cria diretórios organizados para jogos
create_game_directories() {
    printf "\n=========================================\n"
    printf " Diretórios de Jogos\n"
    printf "=========================================\n"
    
    # Perguntar antes de criar
    if confirm_installation "diretórios" "Deseja criar uma estrutura de diretórios para jogos?"; then
        msg_info "Criando estrutura de diretórios em ${HOME}/Games..."
        
        mkdir -p "${HOME}/Games"
        mkdir -p "${HOME}/Games/Steam"
        mkdir -p "${HOME}/Games/Lutris"
        mkdir -p "${HOME}/Games/Other"
        
        if [ $? -eq 0 ]; then
            msg_ok "Estrutura de diretórios criada com sucesso."
            msg_info "Estrutura criada:"
            msg_info "  ~/Games/ - Diretório geral"
            msg_info "  ~/Games/Steam/ - Para jogos da Steam"
            msg_info "  ~/Games/Lutris/ - Para jogos do Lutris"
            msg_info "  ~/Games/Other/ - Para outros jogos"
            return 0
        else
            msg_error "Não foi possível criar diretórios. Verifique permissões."
            return 1
        fi
    else
        msg_info "Estrutura de diretórios ignorada pelo usuário."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 18 — Funções de diagnóstico
#===============================================================================

# Função: system_diagnostics
# Descrição: Diagnóstico completo do sistema
system_diagnostics() {
    printf "\n=========================================\n"
    printf " GameKit Diagnostics\n"
    printf "=========================================\n\n"
    
    # GPU
    printf "GPU:\n"
    if [ ${GPU_NVIDIA} -eq 1 ]; then
        printf "  NVIDIA GeForce RTX 3060\n"
    else
        printf "  GPU não detectada ou não-NVIDIA\n"
    fi
    
    # Driver
    printf "\nDriver:\n"
    if [ ${DRIVER_NVIDIA} -eq 1 ]; then
        local drv_version
        drv_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
        printf "  NVIDIA Driver version: ${drv_version}\n"
    else
        printf "  Driver NVIDIA não detectado\n"
    fi
    
    # Vulkan
    printf "\nVulkan:\n"
    if [ ${VULKAN_SUPPORT} -eq 1 ] && command -v vulkaninfo >/dev/null 2>&1; then
        printf "  [OK]\n"
        local gpu_vulkan
        gpu_vulkan=$(vulkaninfo 2>/dev/null | grep -i "device_name" | head -1 | sed 's/.*: //')
        if [ -n "${gpu_vulkan}" ]; then
            printf "  GPU Vulkan: ${gpu_vulkan}\n"
        fi
    else
        printf "  [VERIFICAR]\n"
    fi
    
    # 32-bit
    printf "\n32-bit:\n"
    if [ ${THIRTYTWO_BIT} -eq 1 ]; then
        printf "  [OK] Arquitetura i386 habilitada\n"
    else
        printf "  [NÃO] Arquitetura i386 não habilitada\n"
    fi
    
    # Steam
    printf "\nSteam:\n"
    if [ ${STEAM_INSTALLED} -eq 1 ]; then
        printf "  [OK] Steam instalado\n"
    else
        printf "  [NÃO] Steam não instalado\n"
    fi
    
    # Lutris
    printf "\nLutris:\n"
    if [ ${LUTRIS_INSTALLED} -eq 1 ]; then
        printf "  [OK] Lutris instalado\n"
    else
        printf "  [NÃO] Lutris não instalado\n"
    fi
    
    # Wine
    printf "\nWine:\n"
    if [ ${WINE_INSTALLED} -eq 1 ]; then
        local wine_version
        wine_version=$(wine --version 2>/dev/null | sed 's/wine-//')
        printf "  [OK] Wine ${wine_version}\n"
    else
        printf "  [NÃO] Wine não instalado\n"
    fi
    
    # GameMode
    printf "\nGameMode:\n"
    if [ ${GAMEMODE_INSTALLED} -eq 1 ]; then
        printf "  [OK] GameMode instalado\n"
    else
        printf "  [NÃO] GameMode não instalado\n"
    fi
    
    # MangoHUD
    printf "\nMangoHUD:\n"
    if [ ${MANGOHUD_INSTALLED} -eq 1 ]; then
        printf "  [OK] MangoHUD instalado\n"
    else
        printf "  [NÃO] MangoHUD não instalado\n"
    fi
}

# Função: nvidia_diagnostics
nvidia_diagnostics() {
    printf "\n=== Diagnóstico NVIDIA ===\n"
    
    if [ ${GPU_NVIDIA} -eq 1 ]; then
        printf "GPU:\n"
        nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | while read -r name; do
            printf "  %s\n" "${name}"
        done
        
        printf "\nDriver:\n"
        nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | while read -r version; do
            printf "  %s\n" "${version}"
        done
        
        printf "\nVRAM:\n"
        nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | while read -r vram; do
            printf "  %s MB\n" "${vram}"
        done
        
        printf "\nUtilização:\n"
        nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | while read -p u; do
            printf "  %s%%\n" "${u}"
        done
        
        printf "\nTemperatura:\n"
        nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | while read -r temp; do
            printf "  %s°C\n" "${temp}"
        done
    else
        printf "GPU NVIDIA não detectada.\n"
    fi
    
    # Vulkan
    printf "\n--- Vulkan ---\n"
    if command -v vulkaninfo >/dev/null 2>&1; then
        vulkaninfo 2>/dev/null | grep -A 1 "device name" | head -2
    else
        printf "vulkaninfo não disponível.\n"
    fi
}

# Função: steam_diagnostics
steam_diagnostics() {
    printf "\n=== Diagnóstico Steam ===\n"
    
    if [ ${STEAM_INSTALLED} -eq 1 ]; then
        printf "Steam: [OK] Instalado\n"
        
        # Verificar arquitetura 32-bit
        if [ ${THIRTYTWO_BIT} -eq 1 ]; then
            printf "Bibliotecas 32-bit: [OK]\n"
        else
            printf "Bibliotecas 32-bit: [VERIFICAR]\n"
        fi
        
        # Verificar Vulkan
        if [ ${VULKAN_SUPPORT} -eq 1 ]; then
            printf "Vulkan: [OK]\n"
        else
            printf "Vulkan: [VERIFICAR]\n"
        fi
        
        # Driver NVIDIA
        if [ ${DRIVER_NVIDIA} -eq 1 ]; then
            printf "Driver NVIDIA: [OK]\n"
        else
            printf "Driver NVIDIA: [VERIFICAR]\n"
        fi
    else
        printf "Steam: [NÃO] Não instalado\n"
    fi
}

# Função: lutris_diagnostics
lutris_diagnostics() {
    printf "\n=== Diagnóstico Lutris ===\n"
    
    if [ ${LUTRIS_INSTALLED} -eq 1 ]; then
        printf "Lutris: [OK] Instalado\n"
        
        # Verificar Wine
        if command -v wine >/dev/null 2>&1; then
            local wine_version
            wine_version=$(wine --version 2>/dev/null | sed 's/wine-//')
            printf "Wine: [OK] ${wine_version}\n"
        else
            printf "Wine: [NÃO] Não disponível\n"
            printf "Nota: O Lutris pode baixar seu próprio Wine runner.\n"
        fi
        
        # Verificar Winetricks
        if command -v winetricks >/dev/null 2>&1; then
            printf "Winetricks: [OK]\n"
        else
            printf "Winetricks: [NÃO]\n"
        fi
        
        # Vulkan
        if [ ${VULKAN_SUPPORT} -eq 1 ]; then
            printf "Vulkan: [OK]\n"
        else
            printf "Vulkan: [VERIFICAR]\n"
        fi
    else
        printf "Lutris: [NÃO] Não instalado\n"
        printf "Nota: Instale o Lutris para configurar runners e jogos.\n"
    fi
}

#===============================================================================
# SEÇÃO 19 — Função: summary
#===============================================================================

# Função: summary
# Descrição: Mostra resumo final da instalação
summary() {
    printf "\n=========================================\n"
    printf " GameKit Installation Summary\n"
    printf "=========================================\n\n"
    
    printf "GPU\n"
    if [ ${GPU_NVIDIA} -eq 1 ]; then
        printf "[OK] NVIDIA GeForce RTX 3060\n"
    else
        printf "[INFO] GPU não detectada/não-NVIDIA\n"
    fi
    
    if [ ${DRIVER_NVIDIA} -eq 1 ]; then
        printf "[OK] NVIDIA Driver\n"
    else
        printf "[AVISO] Driver NVIDIA não configurado\n"
    fi
    
    printf "\nVulkan\n"
    if [ ${VULKAN_SUPPORT} -eq 1 ]; then
        printf "[OK] Vulkan\n"
    else
        printf "[AVISO] Vulkan não configurado\n"
    fi
    
    if [ ${THIRTYTWO_BIT} -eq 1 ]; then
        printf "[OK] 32-bit Libraries\n"
    else
        printf "[AVISO] 32-bit Libraries não habilitadas\n"
    fi
    
    printf "\nGaming\n"
    
    if [ ${STEAM_INSTALLED} -eq 1 ]; then
        printf "[OK] Steam\n"
    else
        printf "[INFO] Steam não instalado\n"
    fi
    
    if [ ${LUTRIS_INSTALLED} -eq 1 ]; then
        printf "[OK] Lutris\n"
    else
        printf "[INFO] Lutris não instalado\n"
    fi
    
    if [ ${WINE_INSTALLED} -eq 1 ]; then
        printf "[OK] Wine\n"
    else
        printf "[INFO] Wine não instalado\n"
    fi
    
    if [ ${GAMEMODE_INSTALLED} -eq 1 ]; then
        printf "[OK] GameMode\n"
    else
        printf "[INFO] GameMode não instalado\n"
    fi
    
    if [ ${MANGOHUD_INSTALLED} -eq 1 ]; then
        printf "[OK] MangoHUD\n"
    else
        printf "[INFO] MangoHUD não instalado\n"
    fi
    
    printf "\nDiagnostics\n"
    
    # Verificar cada ferramenta
    local has_errors=0
    
    if command -v vulkaninfo >/dev/null 2>&1; then
        printf "[OK] vulkaninfo\n"
    else
        printf "[INFO] vulkaninfo não disponível\n"
        has_errors=1
    fi
    
    if command -v nvidia-smi >/dev/null 2>&1; then
        printf "[OK] nvidia-smi\n"
    else
        printf "[INFO] nvidia-smi não disponível\n"
        has_errors=1
    fi
    
    printf "\n=========================================\n"
    
    # Resumo de erros e skipped
    if [ ${ERRORS} -gt 0 ]; then
        printf "[ERRO] Foram detectados %d erros durante a instalação.\n" "${ERRORS}"
    fi
    
    if [ ${SKIPPED} -gt 0 ]; then
        printf "[AVISO] %d componentes foram ignorados pelo usuário.\n" "${SKIPPED}"
    fi
    
    # Informações de log
    printf "\nLog:\n"
    printf "  ~/gamekit/gamekit-install.log\n"
    
    printf "\nComponentes principais:\n"
    printf "  Steam:        %s\n" "$([ ${STEAM_INSTALLED} -eq 1 ] && echo 'Instalado' || 'Não instalado')"
    printf "  Lutris:       %s\n" "$([ ${LUTRIS_INSTALLED} -eq 1 ] && echo 'Instalado' || 'Não instalado')"
    printf "  Wine:         %s\n" "$([ ${WINE_INSTALLED} -eq 1 ] && echo 'Instalado' || 'Não instalado')"
    printf "  Vulkan:       %s\n" "$([ ${VULKAN_SUPPORT} -eq 1 ] && echo 'Disponível' || 'Não verificado')"
    printf "  NVIDIA:       %s\n" "$([ ${DRIVER_NVIDIA} -eq 1 ] && echo 'Driver instalado' || 'Não configurado')"
    printf "  GameMode:     %s\n" "$([ ${GAMEMODE_INSTALLED} -eq 1 ] && echo 'Instalado' || 'Não instalado')"
    printf "  MangoHUD:     %s\n" "$([ ${MANGOHUD_INSTALLED} -eq 1 ] && echo 'Instalado' || 'Não instalado')"
    
    printf "\n%s\n" "========================================="
}

#===============================================================================
# SEÇÃO 20 — Função: install_docker_utils (se necessário)
#===============================================================================

# Função auxiliar para verificar componentes de repositório
check_package_available() {
    local package="$1"
    if apt-cache show "${package}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

#===============================================================================
# SEÇÃO 21 — Função: main
#===============================================================================

# Função: main
# Descrição: Ponto de entrada principal
main() {
    # Inicializar log
    mkdir -p "$(dirname "${LOG_FILE}")"
    >"${LOG_FILE}"
    
    # Cabeçalho
    printf "\n=========================================\n"
    printf " Ubuntu GameKit\n"
    printf "=========================================\n"
    printf "\nConfiguração de ambiente para jogos\n\n"
    
    # Verificações preliminares
    if ! check_os; then
        msg_error "Este script requer Ubuntu 22.04 ou 24.04."
        return 1
    fi
    msg_ok "Sistema operacional verificado"
    
    if ! check_sudo; then
        msg_warn "Sem permissões sudo. Algumas operações podem falhar."
    fi
    msg_info "Verificando conexão com a internet..."
    if ! check_internet; then
        msg_warn "Sem conexão com a internet detectada. Algumas instalações podem falhar."
    fi
    msg_ok "Conexão com a internet verificada"
    
    # Detectar GPU
    detect_gpu
    
    # Verificar arquitetura
    check_architecture
    
    # Verificar suporte 32-bit
    check_32bit_support
    
    # Criar estrutura de diretórios (perguntar)
    create_game_directories
    
    # Menu interativo
    local choice
    while true; do
        printf "${COLOR_CYAN}1${COLOR_RESET} - Configuração completa\n"
        printf "${COLOR_CYAN}2${COLOR_RESET} - Escolher componentes\n"
        printf "${COLOR_CYAN}3${COLOR_RESET} - Diagnóstico do sistema\n"
        printf "${COLOR_CYAN}4${COLOR_RESET} - Verificar GPU / Vulkan\n"
        printf "${COLOR_CYAN}5${COLOR_RESET} - Gerenciar serviços\n"
        printf "${COLOR_CYAN}6${COLOR_RESET} - Sair\n"
        printf ">${COLOR_RESET} "
        read -r choice
        
        case "${choice}" in
            1) # Configuração completa
                printf "\n"
                
                # NVIDIA
                configure_nvidia
                
                # 32-bit
                if [ ${THIRTYTWO_BIT} -ne 1 ]; then
                    check_32bit_support
                fi
                
                # Vulkan
                install_vulkan
                
                # Steam
                if confirm_installation "steam" "Deseja instalar o Steam?"; then
                    install_steam
                else
                    msg_info "Steam ignorado pelo usuário."
                fi
                
                # Proton
                if [ ${STEAM_INSTALLED} -eq 1 ]; then
                    configure_proton
                fi
                
                # Lutris
                if confirm_installation "lutris" "Deseja instalar o Lutris?"; then
                    install_lutris
                else
                    msg_info "Lutris ignorado pelo usuário."
                fi
                
                # Wine
                if [ ${LUTRIS_INSTALLED} -eq 0 ]; then
                    if confirm_installation "wine" "Deseja instalar o Wine?"; then
                        install_wine
                    else
                        msg_info "Wine ignorado pelo usuário."
                    fi
                fi
                
                # Winetricks
                if [ ${WINE_INSTALLED} -eq 1 ] || [ ${LUTRIS_INSTALLED} -eq 1 ]; then
                    if confirm_installation "winetricks" "Deseja instalar o Winetricks?"; then
                        install_winetricks
                    else
                        msg_info "Winetricks ignorado pelo usuário."
                    fi
                fi
                
                # GameMode
                if confirm_installation "gamemode" "Deseja instalar o GameMode para otimização de jogos?"; then
                    install_gamemode
                else
                    msg_info "GameMode ignorado pelo usuário."
                fi
                
                # MangoHUD
                if confirm_installation "mangohud" "Deseja instalar o MangoHUD para monitoramento?"; then
                    install_mangohud
                else
                    msg_info "MangoHUD ignorado pelo usuário."
                fi
                
                # DXVK e VKD3D
                configure_dxvk
                configure_vkd3d
                
                # Controladores
                configure_controllers
                
                # Summary
                summary
                ;;
                
            2) # Escolher componentes individualmente
                printf "\n"
                
                # NVIDIA
                if confirm_installation "nvidia" "Deseja configurar suporte NVIDIA?"; then
                    configure_nvidia
                else
                    msg_info "Configuração NVIDIA ignorada."
                fi
                
                # 32-bit
                if [ ${THIRTYTWO_BIT} -ne 1 ]; then
                    if confirm_installation "i386" "Deseja habilitar arquitetura i386?"; then
                        check_32bit_support
                    fi
                fi
                
                # Vulkan
                if confirm_installation "vulkan" "Deseja instalar/verificar Vulkan?"; then
                    install_vulkan
                fi
                
                # Steam
                if confirm_installation "steam" "Deseja instalar o Steam?"; then
                    install_steam
                else
                    msg_info "Steam ignorado."
                fi
                
                # Proton
                if [ ${STEAM_INSTALLED} -eq 1 ] && confirm_installation "proton" "Deseja configurar Steam Play (Proton)?"; then
                    configure_proton
                fi
                
                # Lutris
                if confirm_installation "lutris" "Deseja instalar o Lutris?"; then
                    install_lutris
                else
                    msg_info "Lutris ignorado."
                fi
                
                # Wine
                if [ ${LUTRIS_INSTALLED} -eq 0 ] && confirm_installation "wine" "Deseja instalar o Wine?"; then
                    install_wine
                elif [ ${LUTRIS_INSTALLED} -eq 1 ] && confirm_installation "wine" "Deseja garantir suporte Wine para Lutris?"; then
                    install_wine
                else
                    msg_info "Wine ignorado."
                fi
                
                # Winetricks
                if [ ${WINE_INSTALLED} -eq 1 ] || [ ${LUTRIS_INSTALLED} -eq 1 ]; then
                    if confirm_installation "winetricks" "Deseja instalar o Winetricks?"; then
                        install_winetricks
                    fi
                fi
                
                # GameMode
                if confirm_installation "gamemode" "Deseja instalar o GameMode?"; then
                    install_gamemode
                else
                    msg_info "GameMode ignorado."
                fi
                
                # MangoHUD
                if confirm_installation "mangohud" "Deseja instalar o MangoHUD?"; then
                    install_mangohud
                else
                    msg_info "MangoHUD ignorado."
                fi
                
                # Summary
                summary
                ;;
                
            3) # Diagnóstico do sistema
                system_diagnostics
                ;;
                
            4) # Verificar GPU / Vulkan
                nvidia_diagnostics
                printf "\n"
                if command -v vulkaninfo >/dev/null 2>&1; then
                    vulkaninfo 2>/dev/null | grep -E "device_name|vendor"
                fi
                ;;
                
            5) # Gerenciar serviços
                printf "\nSubmenu de Serviços:\n"
                printf "1 - Iniciar serviços\n"
                printf "2 - Parar serviços\n"
                printf "3 - Status\n"
                printf "4 - Voltar\n"
                printf ">${COLOR_RESET} "
                read -r svc_choice
                case "${svc_choice}" in
                    1) start_services ;;
                    2) stop_services ;;
                    3) check_services ;;
                    4) continue ;;
                    *) printf "Opção inválida.\n" ;;
                esac
                ;;
                
            6) # Sair
                printf "\nAté mais!\n"
                summary
                return 0
                ;;
                
            * ) printf "Opção inválida. Por favor, escolha 1, 2, 3, 4, 5 ou 6.\n";;
        esac
    done
    
    return 0
}

#===============================================================================
# SEÇÃO 22 — Executar script
#===============================================================================

# Verificar se o script está sendo executado diretamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi