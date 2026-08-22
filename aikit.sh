#!/usr/bin/env bash
#===============================================================================
#
#          FILE: aikit.sh
#
#         USAGE: ./aikit.sh [opções]
#
#   DESCRIPTION: Script de pós-instalação para Ubuntu - AIKit
#                Prepara um ambiente completo para desenvolvimento e execução
#                de aplicações de Inteligência Artificial local.
#
#  REQUIREMENTS: Ubuntu 22.04 ou 24.04, Bash >= 4, sudo, conexão com a Internet,
#                Docker (para Ollama e Open WebUI)
#        AUTHOR: Saulo Godoy Proetti
#       LICENSE: MIT
#
#===============================================================================

#===============================================================================
# SEÇÃO 1 — Identidade do script e configurações globais
#===============================================================================

# Configurações de identidade
readonly KIT_ID='aikit'
readonly KIT_NAME='Ubuntu AIKit Installer'
readonly KIT_VERSION='1.0.0'
readonly KIT_LOG_DEFAULT="${HOME}/aikit/aikit-install.log"
readonly KIT_DESCRIPTION='Prepara um ambiente de desenvolvimento para IA local'
readonly KIT_AUTO_NOTA='O Oh My Zsh e a troca de shell continuarão perguntando.'

# Cores ANSI para mensagens
COLOR_RESET='\033[0m'
COLOR_BOLD='\033[1m'
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'

# Diretórios do AIKit
readonly AIKIT_DIR="${HOME}/aikit"
readonly OLLAMA_DIR="${AIKIT_DIR}/ollama"
readonly OLLAMA_MODELS_DIR="${OLLAMA_DIR}/models"
readonly OPENWEBUI_DIR="${AIKIT_DIR}/open-webui"
readonly LOG_DIR="${AIKIT_DIR}"
NETWORK_NAME='aikit-network'
DEFAULT_OLLAMA_CONTAINER='aikit-ollama'
DEFAULT_OPENWEBUI_CONTAINER='aikit-open-webui'
DEFAULT_OLLAMA_API_PORT='11434'
DEFAULT_OPENWEBUI_PORT='3000'

# Variáveis de estado
INSTALLED_OPENACODE=0
INSTALLED_OLLAMA=0
INSTALLED_OPENWEBUI=0
DOCKER_AVAILABLE=0
GPU_NVIDIA_AVAILABLE=0
GPU_CONFIGURED=0

#===============================================================================
# SEÇÃO 2 — Funções de verificação e helpers
#===============================================================================

# Função: check_os
# Descrição: Verifica se o sistema operacional é Ubuntu compatível
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        UBUNTU_VERSION=${VERSION_ID%%.*}
        if [[ "$ID" == "ubuntu" ]] && { [[ "$UBUNTU_VERSION" -ge 22 ]] || [[ "$UBUNTU_VERSION" -ge 24 ]]; }; then
            return 0
        fi
    fi
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
    return 1
}

# Função: log_message
# Descrição: Registra mensagens no log
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [${level}] ${message}" >> "${KIT_LOG_DEFAULT}" 2>/dev/null
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
}

# Função: msg_error
# Descrição: Mostra mensagem de erro
msg_error() {
    printf "${COLOR_RED}[ERRO]${COLOR_RESET} %s\n" "$1"
    log_message "ERRO" "$1"
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

# Função: detect_gpu
# Descrição: Detecta se há GPU NVIDIA disponível
detect_gpu() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_NVIDIA_AVAILABLE=1
        msg_info "GPU NVIDIA detectada."
        return 0
    fi
    GPU_NVIDIA_AVAILABLE=0
    return 1
}

# Função: check_docker_installed
# Descrição: Verifica se Docker está instalado
check_docker_installed() {
    if command -v docker >/dev/null 2>&1; then
        DOCKER_AVAILABLE=1
        msg_ok "Docker está instalado."
        return 0
    fi
    DOCKER_AVAILABLE=0
    return 1
}

# Função: check_docker_running
# Descrição: Verifica se Docker está funcionando corretamente
check_docker_running() {
    if [ ${DOCKER_AVAILABLE} -eq 1 ]; then
        if docker info >/dev/null 2>&1; then
            msg_ok "Docker está funcionando."
            return 0
        fi
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

#===============================================================================
# SEÇÃO 3 — Função: install_opencode
#===============================================================================

# Função: install_opencode
# Descrição: Instala ou verifica OpenCode
install_opencode() {
    printf "\n=========================================\n"
    printf " OpenCode\n"
    printf "=========================================\n"
    
    # Verificar se OpenCode já está instalado
    if command -v opencode >/dev/null 2>&1; then
        local version
        version=$(opencode --version 2>/dev/null | head -1)
        msg_ok "OpenCode já está instalado."
        msg_info "Versão: ${version}"
        INSTALLED_OPENACODE=1
        return 0
    fi
    
    # Perguntar se deseja instalar
    if confirm_installation "OpenCode" "Deseja instalar o OpenCode?"; then
        msg_info "Iniciando instalação do OpenCode..."
        
        # Método oficial: via npm/node ou binário oficial
        # Verificar se npm/node está disponível
        if command -v npm >/dev/null 2>&1; then
            msg_info "Instalando OpenCode via npm..."
            if sudo env DEBIAN_FRONTEND=noninteractive npm install -g @opencode/cli 2>/dev/null; then
                msg_ok "OpenCode instalado com sucesso via npm."
                INSTALLED_OPENACODE=1
                # Validar instalação
                if command -v opencode >/dev/null 2>&1; then
                    local version
                    version=$(opencode --version 2>/dev/null | head -1)
                    msg_ok "OpenCode versão ${version} validado."
                else
                    msg_warn "OpenCode instalado mas versão não pôde ser verificada."
                    INSTALLED_OPENACODE=1
                fi
                return 0
            else
                msg_warn "Falha ao instalar OpenCode via npm."
            fi
        else
            msg_warn "npm não disponível. Tentando método alternativo..."
            # Baixar binário oficial do GitHub
            local url
            url=$(curl -fsSL --max-time 30 'https://api.github.com/repos/opencode/opencode/releases/latest' 2>/dev/null \
                | grep -oP '"browser_download_url": "\K[^"]+.*linux-amd64[^"]*"' | head -1)
            
            if [ -n "$url" ]; then
                msg_info "Baixando OpenCode do GitHub oficial..."
                local tmp_dir
                tmp_dir=$(mktemp -d)
                if curl -L --max-time 120 -o "${tmp_dir}/opencode.tar.gz" "$url" 2>/dev/null; then
                    # Extrair e instalar
                    if sudo tar -xzf "${tmp_dir}/opencode.tar.gz" -C /usr/local/bin opencode 2>/dev/null; then
                        chmod +x /usr/local/bin/opencode 2>/dev/null
                        msg_ok "OpenCode instalado com sucesso do binário oficial."
                        INSTALLED_OPENACODE=1
                        # Validar
                        if command -v opencode >/dev/null 2>&1; then
                            local version
                            version=$(opencode --version 2>/dev/null | head -1)
                            msg_ok "OpenCode versão ${version} validado."
                        fi
                    else
                        msg_warn "Falha ao extrair binário do OpenCode."
                    fi
                else
                    msg_warn "Falha ao baixar OpenCode do GitHub."
                fi
                rm -rf "$tmp_dir"
            else
                msg_error "Não foi possível determinar a versão mais recente do OpenCode."
                msg_info "Visite: https://github.com/opencode/opencode para instalação manual."
            fi
        fi
    else
        msg_info "OpenCode ignorado pelo usuário."
    fi
    
    return 0
}

#===============================================================================
# SEÇÃO 4 — Função: install_ollama
#===============================================================================

# Função: install_ollama
# Descrição: Instala e configura Ollama via Docker
install_ollama() {
    printf "\n=========================================\n"
    printf " Ollama\n"
    printf "=========================================\n"
    
    # Verificar se Docker está disponível
    if [ ${DOCKER_AVAILABLE} -eq 0 ]; then
        msg_error "Docker não está disponível."
        if confirm_installation "Docker" "Deseja instalar o Docker agora?"; then
            install_docker_func
        else
            msg_error "Não é possível instalar Ollama sem Docker."
            return 1
        fi
    fi
    
    # Verificar se Docker está funcionando
    if ! check_docker_running; then
        msg_error "Docker não está funcionando corretamente."
        return 1
    fi
    
    # Verificar se container já existe
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
        msg_ok "Container Ollama já existe."
        # Verificar se está rodando
        if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
            msg_ok "Container Ollama está rodando."
            INSTALLED_OLLAMA=1
            return 0
        else
            msg_info "Container Ollama existe mas está parado. Iniciando..."
            docker start "${DEFAULT_OLLAMA_CONTAINER}" 2>/dev/null
            if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
                msg_ok "Container Ollama iniciado."
            else
                msg_warn "Não foi possível iniciar container Ollama automaticamente."
            fi
        fi
    else
        # Criar container Ollama
        msg_info "Criando container Ollama..."
        
        # Preparar diretórios de persistência
        mkdir -p "${OLLAMA_MODELS_DIR}"
        
        # Verificar se deve usar GPU
        local use_gpu=0
        if [ ${GPU_NVIDIA_AVAILABLE} -eq 1 ]; then
            if confirm_installation "GPU" "Deseja configurar o Ollama para utilizar a GPU NVIDIA?"; then
                # Verificar se docker tem suporte a GPU
                if sudo docker run --rm --gpus all nvidia/cuda:12.0.0-base nvidia-smi >/dev/null 2>&1; then
                    msg_ok "Suporte NVIDIA Docker verificado."
                    use_gpu=1
                else
                    msg_warn "GPU NVIDIA detectada, mas suporte NVIDIA para Docker não está configurado."
                    msg_info "O Ollama será executado sem GPU."
                    # Adicionar flag --gpus all removida, continuará sem GPU
                fi
            else
                msg_info "Ollama será executado sem GPU."
            fi
        fi
        
        # Criar rede Docker se não existir
        if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
            msg_info "Criando rede Docker ${NETWORK_NAME}..."
            if sudo docker network create "${NETWORK_NAME}" >/dev/null 2>&1; then
                msg_ok "Rede Docker ${NETWORK_NAME} criada."
            else
                msg_warn "Não foi possível criar rede Docker. Usando rede default."
            fi
        end
        
        # Criar container Ollama
        local gpu_flag=""
        if [ ${use_gpu} -eq 1 ]; then
            gpu_flag="--gpus all"
        fi
        
        local restart_policy="--restart unless-stopped"
        
        msg_info "Criando container ${DEFAULT_OLLAMA_CONTAINER}..."
        
        if sudo docker run -d \
            --name "${DEFAULT_OLLAMA_CONTAINER}" \
            ${gpu_flag} \
            --network "${NETWORK_NAME}" \
            ${restart_policy} \
            -v "${OLLAMA_MODELS_DIR}":/root/.ollama/models \
            -e OLLAMA_MODELS="/root/.ollama/models" \
            -p "${DEFAULT_OLLAMA_API_PORT}:${DEFAULT_OLLAMA_API_PORT}" \
            ollama/ollama:latest \
            >/dev/null 2>&1; then
            
            msg_ok "Container Ollama criado com sucesso."
            
            # Aguardar container inicializar
            local wait_count=0
            while [ ${wait_count} -lt 30 ]; do
                if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
                    msg_ok "Container Ollama está rodando."
                    break
                fi
                sleep 1
                wait_count=$((wait_count + 1))
            done
            
            if [ ${wait_count} -ge 30 ]; then
                msg_warn "Container Ollama pode não estar totalmente pronto ainda."
            fi
            
            INSTALLED_OLLAMA=1
            
            # Validar API
            local api_wait=0
            local max_wait=20
            while [ ${api_wait} -lt ${max_wait} ]; do
                if curl --output /dev/null --silent --head --fail "http://localhost:${DEFAULT_OLLAMA_API_PORT}/api/tags" 2>/dev/null; then
                    msg_ok "API Ollama está respondendo."
                    break
                fi
                sleep 2
                api_wait=$((api_wait + 1))
            done
            
            if [ ${api_wait} -ge ${max_wait} ]; then
                msg_warn "API Ollama pode não estar responding yet, mas container foi criado."
            fi
            
        else
            msg_error "Falha ao criar container Ollama."
        fi
    fi
    
    return 0
}

#===============================================================================
# SEÇÃO 5 — Função: install_openwebui
#===============================================================================

# Função: install_openwebui
# Descrição: Instala e configura Open WebUI via Docker
install_openwebui() {
    printf "\n=========================================\n"
    printf " Open WebUI\n"
    printf "=========================================\n"
    
    # Verificar se Docker está disponível
    if [ ${DOCKER_AVAILABLE} -eq 0 ]; then
        msg_error "Docker não está disponível."
        if confirm_installation "Docker" "Deseja instalar o Docker agora?"; then
            install_docker_func
        else
            msg_error "Não é possível instalar Open WebUI sem Docker."
            return 1
        fi
    fi
    
    # Verificar se Docker está funcionando
    if ! check_docker_running; then
        msg_error "Docker não está funcionando corretamente."
        return 1
    fi
    
    # Perguntar sobre a porta
    local webui_port="${DEFAULT_OPENWEBUI_PORT}"
    if ! confirm_installation "Porta" "A porta padrão do Open WebUI será:\n\n${webui_port}\n\nDeseja utilizar esta porta?"; then
        printf "Informe a porta desejada para o Open WebUI:\n>${COLOR_RESET} "
        read -r webui_port
        # Validar que é um número
        if ! [[ "${webui_port}" =~ ^[0-9]+$ ]]; then
            msg_warn "Porta inválida. Usando porta padrão ${DEFAULT_OPENWEBUI_PORT}."
            webui_port="${DEFAULT_OPENWEBUI_PORT}"
        fi
    fi
    
    # Verificar se container já existe
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
        msg_ok "Container Open WebUI já existe."
        # Verificar se está rodando
        if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
            msg_ok "Container Open WebUI está rodando."
            # Verificar conexão com Ollama
            check_openwebui_ollama_connection
            INSTALLED_OPENWEBUI=1
            return 0
        else
            msg_info "Container Open WebUI existe mas está parado. Iniciando..."
            docker start "${DEFAULT_OPENWEBUI_CONTAINER}" 2>/dev/null
        fi
    else
        # Criar container Open WebUI
        msg_info "Criando container Open WebUI..."
        
        # Preparar diretórios de persistência
        mkdir -p "${OPENWEBUI_DIR}"
        
        # Verificar conexão com Ollama
        local ollama_url="http://${DEFAULT_OLLAMA_CONTAINER}:${DEFAULT_OLLAMA_API_PORT}"
        
        # Criar rede Docker se não existir
        if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
            msg_info "Criando rede Docker ${NETWORK_NAME}..."
            if sudo docker network create "${NETWORK_NAME}" >/dev/null 2>&1; then
                msg_ok "Rede Docker ${NETWORK_NAME} criada."
                # Conectar container Ollama se existir
                if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
                    sudo docker network connect "${NETWORK_NAME}" "${DEFAULT_OLLAMA_CONTAINER}" >/dev/null 2>&1
                fi
            else
                msg_warn "Não foi possível criar rede Docker. Usando rede default."
            fi
        end
        
        # Criar container Open WebUI
        msg_info "Criando container ${DEFAULT_OPENWEBUI_CONTAINER}..."
        
        local restart_policy="--restart unless-stopped"
        
        if sudo docker run -d \
            --name "${DEFAULT_OPENWEBUI_CONTAINER}" \
            --network "${NETWORK_NAME}" \
            ${restart_policy} \
            -v "${OPENWEBUI_DIR}":/app/backend/user_data \
            -e OLLAMA_HOST="${ollama_url}" \
            -e "WEBUI_HIDE_MIGRATE_NOTICE=True" \
            -p "${webui_port}:8080" \
            ghcr.io/openwebui/openwebui:latest \
            >/dev/null 2>&1; then
            
            msg_ok "Container Open WebUI criado com sucesso."
            
            # Aguardar container inicializar
            local wait_count=0
            while [ ${wait_count} -lt 40 ]; do
                if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
                    msg_ok "Container Open WebUI está rodando."
                    break
                fi
                sleep 1
                wait_count=$((wait_count + 1))
            done
            
            if [ ${wait_count} -ge 40 ]; then
                msg_warn "Container Open WebUI pode não estar totalmente pronto ainda."
            fi
            
            # Verificar conexão com Ollama
            check_openwebui_ollama_connection
            
            INSTALLED_OPENWEBUI=1
            
        else
            msg_error "Falha ao criar container Open WebUI."
        fi
    fi
    
    return 0
}

# Função: check_openwebui_ollama_connection
# Descrição: Verifica conexão entre Open WebUI e Ollama
check_openwebui_ollama_connection() {
    msg_info "Verificando conexão Open WebUI ↔ Ollama..."
    
    local max_wait=15
    local wait_count=0
    
    while [ ${wait_count} -lt ${max_wait} ]; do
        # Tentar acessar a API do Ollama pelo container Open WebUI
        if docker exec "${DEFAULT_OPENWEBUI_CONTAINER}" curl --output /dev/null --silent --head --fail "http://${DEFAULT_OLLAMA_CONTAINER}:${DEFAULT_OLLAMA_API_PORT}/api/tags" 2>/dev/null; then
            msg_ok "Open WebUI consegue acessar Ollama via rede Docker."
            return 0
        fi
        sleep 2
        wait_count=$((wait_count + 1))
    done
    
    msg_warn "Open WebUI pode não conseguir acessar Ollama imediatamente."
    msg_info "Tente acessar: http://localhost:${webui_port:-3000}"
    # Tentar também via localhost após algum tempo
    return 1
}

#===============================================================================
# SEÇÃO 6 — Funções de gerenciamento de serviços
#===============================================================================

# Função: start_services
start_services() {
    msg_info "Iniciando serviços AIKit..."
    
    # Iniciar container Ollama se existir e estiver parado
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
        if ! docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
            msg_info "Iniciando container Ollama..."
            docker start "${DEFAULT_OLLAMA_CONTAINER}" >/dev/null 2>&1
            msg_ok "Container Ollama iniciado."
        else
            msg_ok "Container Ollama já está rodando."
        fi
    else
        msg_warn "Container Ollama não encontrado."
    fi
    
    # Iniciar container Open WebUI se existir e estiver parado
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
        if ! docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
            msg_info "Iniciando container Open WebUI..."
            docker start "${DEFAULT_OPENWEBUI_CONTAINER}" >/dev/null 2>&1
            msg_ok "Container Open WebUI iniciado."
        else
            msg_ok "Container Open WebUI já está rodando."
        fi
    else
        msg_warn "Container Open WebUI não encontrado."
    fi
}

# Função: stop_services
stop_services() {
    msg_info "Parando serviços AIKit..."
    
    # Parar container Ollama
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
        msg_info "Parando container Ollama..."
        docker stop "${DEFAULT_OLLAMA_CONTAINER}" >/dev/null 2>&1
        msg_ok "Container Ollama parado."
    else
        msg_ok "Container Ollama não está rodando."
    fi
    
    # Parar container Open WebUI
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
        msg_info "Parando container Open WebUI..."
        docker stop "${DEFAULT_OPENWEBUI_CONTAINER}" >/dev/null 2>&1
        msg_ok "Container Open WebUI parado."
    else
        msg_ok "Container Open WebUI não está rodando."
    fi
}

# Função: restart_services
restart_services() {
    msg_info "Reiniciando serviços AIKit..."
    stop_services
    sleep 2
    start_services
}

# Função: check_services
check_services() {
    printf "\n=========================================\n"
    printf " AIKit Status\n"
    printf "=========================================\n\n"
    
    # Status do Ollama
    printf "Ollama:\n"
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
            msg_ok "Container ativo"
            msg_info "Container: ${DEFAULT_OLLAMA_CONTAINER}"
            msg_info "API: http://localhost:${DEFAULT_OLLAMA_API_PORT}"
        else
            msg_warn "Container está parado."
        fi
    else
        msg_info "Container não encontrado."
    fi
    
    # Status do Open WebUI
    printf "\nOpen WebUI:\n"
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
            msg_ok "Container ativo"
            msg_info "URL: http://localhost:${webui_port:-3000}"
        else
            msg_warn "Container está parado."
        fi
    else
        msg_info "Container não encontrado."
    fi
    
    # Status do Docker
    printf "\nDocker:\n"
    if check_docker_installed; then
        msg_ok "Docker está disponível."
    else
        msg_error "Docker não está disponível."
    fi
}

# Função: show_logs
show_logs() {
    local log_file="${KIT_LOG_DEFAULT}"
    if [ -f "${log_file}" ]; then
        msg_info "Logs de instalação do AIKit:"
        printf "${COLOR_BOLD}=========================================${COLOR_RESET}\n"
        printf "${COLOR_Bold} AIKit Install Log ${COLOR_RESET}\n"
        printf "${COLOR_BOLD}=========================================${COLOR_RESET}\n"
        cat "${log_file}"
        printf "${COLOR_BOLD}=========================================${COLOR_RESET}\n"
    else
        msg_warn "Nenhum log encontrado em ${log_file}"
    fi
}

#===============================================================================
# SEÇÃO 7 — Função: install_docker_func
#===============================================================================

# Função: install_docker_func
# Descrição: Instala Docker caso não esteja instalado
install_docker_func() {
    msg_info "Iniciando instalação do Docker..."
    
    # Verificar arquitetura
    local arch_deb
    if [ "$(uname -m)" = "aarch64" ]; then
        arch_deb="arm64"
    else
        arch_deb="amd64"
    fi
    
    # Método oficial do Docker
    msg_info "Adicionando repositório oficial do Docker..."
    
    # Adicionar chave GPG do Docker
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /usr/share/keyrings/docker-archive-keyring.gpg 2>/dev/null; then
        msg_info "Chave GPG do Docker adicionada."
    else
        msg_warn "Não foi possível baixar chave GPG do Docker."
    fi
    
    # Adicionar repositório
    local codename
    codename=$(lsb_release -cs)
    
    if echo "deb [arch=${arch_deb} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null 2>&1; then
        msg_ok "Repositório Docker adicionado."
    else
        msg_error "Não foi possível adicionar repositório Docker."
        return 1
    fi
    
    # Atualizar e instalar
    apt_update
    
    msg_info "Instalando Docker Engine, containerd e plugins..."
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        >/dev/null 2>&1; then
        msg_ok "Docker instalado com sucesso."
        
        # Adicionar usuário atual ao grupo docker
        if [ "$(id -u)" -ne 0 ]; then
            sudo usermod -aG docker "$USER" >/dev/null 2>&1
            msg_info "Usuário adicionado ao grupo Docker. É necessário fazer logout/login para efeitos."
        fi
        
        DOCKER_AVAILABLE=1
        return 0
    else
        msg_error "Falha ao instalar Docker."
        return 1
    fi
    
    return 1
}

#===============================================================================
# SEÇÃO 8 — Função: create_aikit_structure
#===============================================================================

# Função: create_aikit_structure
# Descrição: Cria estrutura de diretórios do AIKit
create_aikit_structure() {
    msg_info "Criando estrutura de diretórios do AIKit..."
    
    mkdir -p "${AIKIT_DIR}"
    mkdir -p "${OLLAMA_MODELS_DIR}"
    mkdir -p "${OPENWEBUI_DIR}"
    
    if [ $? -eq 0 ]; then
        msg_ok "Estrutura de diretórios criada em ${AIKIT_DIR}/"
        return 0
    else
        msg_warn "Algum problema ao criar diretórios. Verifique permissões."
        return 1
    fi
}

#===============================================================================
# SEÇÃO 9 — Função: summary
#===============================================================================

# Função: summary
# Descrição: Mostra resumo final da instalação
summary() {
    printf "\n=========================================\n"
    printf " AIKit Installation Summary\n"
    printf "=========================================\n\n"
    
    printf "Instalados:\n"
    
    # OpenCode
    if [ ${INSTALLED_OPENACODE} -eq 1 ]; then
        if command -v opencode >/dev/null 2>&1; then
            local version
            version=$(opencode --version 2>/dev/null | head -1)
            printf "[OK] OpenCode (${version})\n"
        else
            printf "[OK] OpenCode\n"
        fi
    else
        printf "[INFO] OpenCode - ignorado pelo usuário\n"
    fi
    
    # Ollama
    if [ ${INSTALLED_OLLAMA} -eq 1 ]; then
        if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
            printf "[OK] Ollama (Container ativo)\n"
            printf "    API: http://localhost:${DEFAULT_OLLAMA_API_PORT}\n"
        else
            printf "[OK] Ollama (Container instalado)\n"
        fi
    else
        printf "[INFO] Ollama - ignorado pelo usuário\n"
    fi
    
    # Open WebUI
    if [ ${INSTALLED_OPENWEBUI} -eq 1 ]; then
        if docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
            printf "[OK] Open WebUI (Container ativo)\n"
            printf "    URL: http://localhost:${webui_port:-3000}\n"
        else
            printf "[OK] Open WebUI (Container instalado)\n"
        fi
    else
        printf "[INFO] Open WebUI - ignorado pelo usuário\n"
    fi
    
    printf "\nServiços:\n"
    
    # Docker
    if check_docker_installed; then
        msg_ok "Docker"
    else
        msg_error "Docker"
    fi
    
    # Containers
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
        msg_ok "Ollama Container"
    else
        msg_info "Ollama Container - não instalado/parado"
    fi
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
        msg_ok "Open WebUI Container"
    else
        msg_info "Open WebUI Container - não instalado/parado"
    fi
    
    printf "\nOllama API:\n"
    if [ ${INSTALLED_OLLAMA} -eq 1 ] && docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OLLAMA_CONTAINER}$"; then
        printf "http://localhost:${DEFAULT_OLLAMA_API_PORT}\n"
    else
        printf "[INFO] Não disponível\n"
    fi
    
    printf "\nOpen WebUI:\n"
    if [ ${INSTALLED_OPENWEBUI} -eq 1 ] && docker ps --format '{{.Names}}' | grep -q "^${DEFAULT_OPENWEBUI_CONTAINER}$"; then
        printf "http://localhost:${webui_port:-3000}\n"
    else
        printf "[INFO] Não disponível\n"
    fi
    
    printf "\nDiretório:\n"
    printf "~/aikit\n"
    
    printf "\nLog:\n"
    printf "~/aikit/aikit-install.log\n"
    
    printf "\nComponentes ignorados:\n"
    if [ ${INSTALLED_OPENACODE} -eq 0 ]; then
        printf "[INFO] OpenCode - ignorado pelo usuário\n"
    fi
    if [ ${INSTALLED_OLLAMA} -eq 0 ]; then
        printf "[INFO] Ollama - ignorado pelo usuário\n"
    fi
    if [ ${INSTALLED_OPENWEBUI} -eq 0 ]; then
        printf "[INFO] Open WebUI - ignorado pelo usuário\n"
    fi
    
    printf "\n%s\n" "========================================="
}

#===============================================================================
# SEÇÃO 10 — Função: main
#===============================================================================

# Função: main
# Descrição: Ponto de entrada principal
main() {
    # Inicializar log
    mkdir -p "$(dirname "${KIT_LOG_DEFAULT}")"
    >"${KIT_LOG_DEFAULT}"
    
    # Cabeçalho
    printf "\n=========================================\n"
    printf " ${KIT_NAME}\n"
    printf "=========================================\n"
    printf "\nAmbiente de Inteligência Artificial\n\n"
    
    # Verificações preliminares
    if ! check_os; then
        msg_error "Este script requer Ubuntu 22.04 ou 24.04."
        printf "Detectado: $(lsb_release -d | cut -f2-)\n"
        return 1
    fi
    msg_ok "Sistema operacional verificado: Ubuntu"
    
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
    
    # Verificar Docker
    check_docker_installed
    
    # Criar estrutura de diretórios
    create_aikit_structure
    
    # Menu interativo
    local choice
    while true; do
        printf "\n${COLOR_CYAN}1${COLOR_RESET} - Instalação completa\n"
        printf "${COLOR_CYAN}2${COLOR_RESET} - Escolher componentes individualmente\n"
        printf "${COLOR_CYAN}3${COLOR_RESET} - Verificar instalações\n"
        printf "${COLOR_CYAN}4${COLOR_RESET} - Sair\n"
        printf ">${COLOR_RESET} "
        read -r choice
        
        case "${choice}" in
            1) # Instalação completa
                printf "\n"
                # OpenCode
                install_opencode
                
                # Docker (se necessário)
                if [ ${DOCKER_AVAILABLE} -eq 0 ]; then
                    if confirm_installation "Docker" "Deseja instalar o Docker agora?"; then
                        install_docker_func
                    fi
                fi
                
                # Ollama
                install_ollama
                
                # Open WebUI
                install_openwebui
                
                # Summary
                summary
                ;;
                
            2) # Escolher componentes individualmente
                printf "\n"
                # OpenCode
                if confirm_installation "OpenCode" "Deseja instalar o OpenCode?"; then
                    install_opencode
                else
                    msg_info "OpenCode ignorado."
                fi
                
                # Ollama
                if confirm_installation "Ollama" "Deseja instalar o Ollama via Docker?"; then
                    install_ollama
                else
                    msg_info "Ollama ignorado."
                fi
                
                # Open WebUI
                if confirm_installation "Open WebUI" "Deseja instalar o Open WebUI via Docker?"; then
                    install_openwebui
                else
                    msg_info "Open WebUI ignorado."
                fi
                
                # Summary
                summary
                ;;
                
            3) # Verificar instalações
                check_services
                show_logs
                ;;
                
            4) # Sair
                printf "\nAté mais!\n"
                return 0
                ;;
                
            * ) printf "Opção inválida. Por favor, escolha 1, 2, 3 ou 4.\n";;
        esac
    done
    
    return 0
}

#===============================================================================
# SEÇÃO 11 — Executar script
#===============================================================================

# Verificar se o script está sendo executado diretamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi