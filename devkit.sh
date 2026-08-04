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
#                O motor (log, helpers, menu, resumo, orquestração) vive em
#                lib/kit-common.sh e é compartilhado com os demais kits. Este
#                arquivo contém apenas os módulos de instalação e o registro
#                dos componentes.
#
#  REQUIREMENTS: Ubuntu 22.04 ou 24.04, Bash >= 4, sudo, conexão com a Internet
#        AUTHOR: Saulo Godoy Proetti
#       LICENSE: MIT
#
#  COMO ESTENDER: escreva uma função install_<nome>() na SEÇÃO 2 e acrescente
#                 uma linha em register_components(), na SEÇÃO 3. Menu, log,
#                 validação, resumo e flags passam a contemplá-la sozinhos.
#
#===============================================================================

#===============================================================================
# SEÇÃO 1 — Identidade do kit e carregamento do motor
#===============================================================================

readonly KIT_ID='devkit'
readonly KIT_NAME='Ubuntu DevKit Installer'
readonly KIT_VERSION='1.1.0'
readonly KIT_LOG_DEFAULT="${HOME}/devkit-install.log"
readonly KIT_DESCRIPTION='Prepara um ambiente de desenvolvimento completo usando apenas
repositórios oficiais: Git, Docker, Kubernetes, .NET, NodeJS e mais.'
readonly KIT_AUTO_NOTE='O Oh My Zsh e a troca de shell continuarão perguntando.'

_kit_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly KIT_LIB="${_kit_dir}/lib/kit-common.sh"
unset _kit_dir

if [[ ! -r $KIT_LIB ]]; then
    printf 'Biblioteca compartilhada não encontrada: %s\n' "$KIT_LIB" >&2
    printf 'Execute o script a partir do repositório clonado — o diretório lib/\n' >&2
    printf 'precisa estar ao lado do %s.\n' "${BASH_SOURCE[0]##*/}" >&2
    exit 1
fi

# shellcheck source=lib/kit-common.sh
source "$KIT_LIB"

# Valores usados apenas se a consulta ao canal estável do fabricante falhar
# (rede restrita, proxy, API fora do ar). Nenhuma versão é fixada no caminho
# feliz: tudo é resolvido em tempo de execução.
readonly KUBECTL_FALLBACK_MINOR='v1.34'
readonly NODE_FALLBACK_MAJOR='22'

#===============================================================================
# SEÇÃO 2 — Módulos de instalação
#
# Cada função instala UM componente e devolve 0 em sucesso ou != 0 em falha.
# Nenhuma delas chama 'exit': a decisão de continuar é do orquestrador.
#===============================================================================

#------------------------------------------------------------------- utilitários
install_curl() { apt_install_step 'curl' curl; }
install_wget() { apt_install_step 'wget' wget; }
install_zsh()  { apt_install_step 'Zsh'  zsh;  }

#----------------------------------------------------------- controle de versão
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
    # O projeto publica pacotes .deb do Git Credential Manager apenas para x64;
    # em arm64 o componente é declarado incompatível no registry.
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

#-------------------------------------------------------------------- containers
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

#-------------------------------------------------------------------- kubernetes
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

#-------------------------------------------------------------------- javascript
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
# SEÇÃO 3 — Registro dos componentes
#
# PONTO DE EXTENSÃO. A ordem define a ordem de instalação e resolve as
# dependências entre módulos (git antes de gcm, docker antes de compose,
# node antes de npm, zsh antes de omz).
#
#   register_component <id> <nome> <grupo> <função> <binário> <cmd de versão> \
#                      <arquiteturas> [<teste de presença>]
#===============================================================================

register_components() {
    #                  id        nome                     grupo                 função           binário                versão                             arquiteturas   teste de presença
    register_component curl     'Curl'                   'Utilitários'         install_curl     curl                   'curl --version'                   'amd64 arm64'
    register_component wget     'Wget'                   'Utilitários'         install_wget     wget                   'wget --version'                   'amd64 arm64'

    register_component git      'Git'                    'Controle de versão'  install_git      git                    'git --version'                    'amd64 arm64'
    register_component gcm      'Git Credential Manager' 'Controle de versão'  install_gcm      git-credential-manager 'git-credential-manager --version' 'amd64'
    register_component gh       'GitHub CLI'             'Controle de versão'  install_gh       gh                     'gh --version'                     'amd64 arm64'

    register_component vscode   'Visual Studio Code'     'Editor'              install_vscode   code                   'code --version'                   'amd64 arm64'

    register_component docker   'Docker'                 'Containers'          install_docker   docker                 'docker --version'                 'amd64 arm64'
    register_component compose  'Docker Compose'         'Containers'          install_compose  docker                 'docker compose version'           'amd64 arm64' 'docker compose version'

    register_component kubectl  'Kubectl'                'Kubernetes'          install_kubectl  kubectl                'kubectl version --client'         'amd64 arm64'
    register_component minikube 'Minikube'               'Kubernetes'          install_minikube minikube               'minikube version --short'         'amd64 arm64'

    register_component dotnet   '.NET SDK'               '.NET'                install_dotnet   dotnet                 'dotnet --version'                 'amd64 arm64'

    register_component node     'NodeJS'                 'JavaScript'          install_node     node                   'node --version'                   'amd64 arm64'
    register_component npm      'NPM'                    'JavaScript'          install_npm      npm                    'npm --version'                    'amd64 arm64'
    register_component nvm      'NVM'                    'JavaScript'          install_nvm      nvm                    'echo instalado em ~/.nvm'         'amd64 arm64' '[[ -s "$HOME/.nvm/nvm.sh" ]]'

    register_component zsh      'Zsh'                    'Shell'               install_zsh      zsh                    'zsh --version'                    'amd64 arm64'
    register_component omz      'Oh My Zsh'              'Shell'               install_omz      zsh                    'echo instalado em ~/.oh-my-zsh'   'amd64 arm64' '[[ -d "$HOME/.oh-my-zsh" ]]'
}

kit_main "$@"
