#!/usr/bin/env bash
#===============================================================================
#
#          FILE: utilitieskit.sh
#
#         USAGE: ./utilitieskit.sh [opções]
#
#   DESCRIPTION: Instalador de pós-instalação para Ubuntu LTS (22.04 / 24.04).
#                Instala os principais aplicativos utilitários de uso diário —
#                navegadores, escritório, multimídia, manutenção do sistema,
#                compactação, comunicação — priorizando sempre o repositório
#                oficial de cada fabricante.
#
#                Ordem de preferência de origem, do melhor para o pior:
#                  1. repositório oficial do fabricante
#                  2. pacote .deb publicado pelo fabricante
#                  3. Flatpak (Flathub), apenas quando não há alternativa
#                O Snap é evitado.
#
#                O motor (log, helpers, menu, resumo, orquestração) vive em
#                lib/kit-common.sh e é compartilhado com os demais kits.
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

readonly KIT_ID='utilitieskit'
readonly KIT_NAME='Ubuntu UtilitiesKit Installer'
readonly KIT_VERSION='1.0.0'
readonly KIT_LOG_DEFAULT="${HOME}/utilities-install.log"
readonly KIT_DESCRIPTION='Instala os principais aplicativos utilitários para uso diário,
priorizando os repositórios oficiais de cada fabricante e evitando o Snap.'
readonly KIT_AUTO_NOTE='Os componentes com escolha (LibreOffice, captura) assumem a primeira opção.'

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

#===============================================================================
# SEÇÃO 2 — Módulos de instalação
#
# Cada função instala UM aplicativo e devolve 0 em sucesso ou != 0 em falha.
# Nenhuma delas chama 'exit': a decisão de continuar é do orquestrador.
# Quando o software simplesmente não se aplica ao sistema (pacote inexistente
# na versão do Ubuntu, upstream sem release), use skip_component().
#===============================================================================

#-------------------------------------------------------------------- navegadores
install_firefox() {
    # O pacote 'firefox' do Ubuntu 22.04/24.04 é apenas um transitional package
    # que instala o Snap. O caminho oficial da Mozilla é o repositório APT
    # próprio, que exige um pin de prioridade para vencer o pacote da
    # distribuição — sem o pin o APT continuaria escolhendo o Snap.
    add_apt_repo 'mozilla' \
        'https://packages.mozilla.org/apt/repo-signing-key.gpg' \
        'deb [signed-by=@KEYRING@] https://packages.mozilla.org/apt mozilla main' \
        || return 1

    add_apt_pin 'mozilla' 'Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000' || return 1

    apt_update

    run_step 'Instalando Firefox (pacote oficial da Mozilla)' \
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y firefox || return 1

    # Confirma que o pin funcionou e o pacote não veio do Snap.
    if apt-cache policy firefox 2>/dev/null | grep -q 'packages.mozilla.org'; then
        msg_ok 'Firefox proveniente do repositório oficial da Mozilla.'
    else
        msg_warn 'O Firefox instalado pode não ter vindo do repositório da Mozilla; verifique com "apt policy firefox".'
    fi
    return 0
}

install_chrome() {
    # O Google publica apenas pacotes x86_64 para Linux; em arm64 o componente
    # é declarado incompatível no registry e vira IGNORADO.
    add_apt_repo 'google-chrome' \
        'https://dl.google.com/linux/linux_signing_key.pub' \
        'deb [arch=amd64 signed-by=@KEYRING@] https://dl.google.com/linux/chrome/deb/ stable main' \
        || return 1

    run_step 'Instalando Google Chrome' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y google-chrome-stable || return 1

    return 0
}

install_brave() {
    add_apt_repo 'brave-browser' \
        'https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg' \
        "deb [arch=${ARCH_DEB} signed-by=@KEYRING@] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        || return 1

    run_step 'Instalando Brave Browser' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y brave-browser || return 1

    return 0
}

#--------------------------------------------------------------------- escritório
install_libreoffice() {
    local escolha
    escolha=$(ask_choice 'Como deseja instalar o LibreOffice?' \
        'Pacote completo (Writer, Calc, Impress, Draw, Base)' \
        'Escolher os componentes individualmente') \
        || { skip_component 'seleção cancelada'; return 0; }

    local -a pacotes=()

    if [[ $escolha == '1' ]]; then
        pacotes=(libreoffice)
    else
        local -a rotulos=(
            'Writer — editor de textos'
            'Calc — planilhas'
            'Impress — apresentações'
            'Draw — desenho vetorial'
            'Base — banco de dados'
        )
        local -a alvos=(
            libreoffice-writer
            libreoffice-calc
            libreoffice-impress
            libreoffice-draw
            libreoffice-base
        )

        local indices i
        indices=$(ask_multi_choice 'Quais componentes deseja instalar?' "${rotulos[@]}") \
            || { skip_component 'seleção cancelada'; return 0; }

        for i in $indices; do
            pacotes+=("${alvos[i - 1]}")
        done
    fi

    if (( ${#pacotes[@]} == 0 )); then
        skip_component 'nenhum componente selecionado'
        return 0
    fi

    # Interface e ajuda em português do Brasil.
    pacotes+=(libreoffice-l10n-pt-br libreoffice-help-pt-br)

    apt_update
    run_step "Instalando LibreOffice (${#pacotes[@]} pacotes)" \
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        "${pacotes[@]}" || return 1

    return 0
}

#----------------------------------------------------------- download e multimídia
install_qbittorrent() { apt_install_step 'qBittorrent' qbittorrent; }
install_vlc()         { apt_install_step 'VLC'         vlc;         }

#--------------------------------------------------------- utilitários do sistema
install_gparted()   { apt_install_step 'GParted'      gparted;      }
install_tweaks()    { apt_install_step 'GNOME Tweaks' gnome-tweaks; }
install_bleachbit() { apt_install_step 'BleachBit'    bleachbit;    }
install_timeshift() { apt_install_step 'Timeshift'    timeshift;    }

#-------------------------------------------------------------------- compactação
install_7zip() {
    # O nome do pacote mudou entre as LTS: o 24.04 traz o porte oficial '7zip',
    # enquanto o 22.04 ainda distribui o 'p7zip-full'.
    apt_update

    local pacote
    if ! pacote=$(apt_first_available 7zip p7zip-full); then
        skip_component 'nenhum pacote 7-Zip disponível nos repositórios'
        return 0
    fi

    msg_info "Pacote selecionado: ${pacote}"
    run_step "Instalando ${pacote}" sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "$pacote"
run_step "Instalando ${pacote}" sudo env DEBIAN_FRONTEND=noninteractive \
         apt-get install -y "$pacote"
}





#------------------------------------------------------------- captura de tela
install_screenshot() {
    run_step 'Instalando Flameshot' sudo env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y flameshot
}

#-------------------------------------------------------------------- comunicação
install_discord() {
    # O Discord não mantém repositório APT; o canal oficial é o .deb do site.
    # A URL não termina em .deb, então o nome de destino é informado — o
    # apt-get identifica pacotes locais pela extensão do arquivo.
    if install_deb_from_url \
            'https://discord.com/api/download?platform=linux&format=deb' \
            'discord.deb'; then
        return 0
    fi

    msg_warn 'Download do .deb oficial falhou; recorrendo ao Flathub.'
    flatpak_install 'com.discordapp.Discord' 'Discord'
}

install_telegram() {
    apt_update

    if apt_first_available telegram-desktop >/dev/null 2>&1; then
        run_step 'Instalando Telegram Desktop' sudo env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y telegram-desktop && return 0
        msg_warn 'Instalação via APT falhou; recorrendo ao Flathub.'
    else
        msg_info 'Pacote do Ubuntu indisponível; usando o Flathub.'
    fi

    flatpak_install 'org.telegram.desktop' 'Telegram Desktop'
}

#--------------------------------------------------------- gerenciador de senhas
install_keepassxc() {
    apt_update
    if apt_first_available keepassxc >/dev/null 2>&1; then
        run_step 'Instalando KeePassXC' sudo env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y keepassxc && return 0
        msg_warn 'Instalação via APT falhou; tentando Flatpak.'
    else
        msg_info 'Pacote do Ubuntu indisponível; tentando Flatpak.'
    fi

    flatpak_install 'org.keepassxc.KeePassXC' 'KeePassXC'
}

#----------------------------------------------------------------- extras

install_obs() {
    # O projeto OBS recomenda oficialmente o PPA para Ubuntu, que costuma trazer
    # uma versão bem mais nova do que a empacotada pela distribuição.
    if ! is_installed add-apt-repository; then
        apt_install software-properties-common || return 1
    fi

    if run_step 'Adicionando ppa:obsproject/obs-studio' \
            sudo env DEBIAN_FRONTEND=noninteractive \
            add-apt-repository -y ppa:obsproject/obs-studio; then
        apt_update
    else
        msg_warn 'Não foi possível adicionar o PPA oficial; usando o repositório do Ubuntu.'
        apt_update
    fi

    if run_step 'Instalando OBS Studio' sudo env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y obs-studio; then
        return 0
    fi

    msg_warn 'Instalação via APT falhou; recorrendo ao Flathub.'
    flatpak_install 'com.obsproject.Studio' 'OBS Studio'
}

#===============================================================================
# SEÇÃO 3 — Registro dos componentes
#
# PONTO DE EXTENSÃO. A ordem define a ordem de instalação e o agrupamento do
# menu (componentes da mesma categoria ficam contíguos).
#
#   register_component <id> <nome> <grupo> <função> <binário> <cmd de versão> \
#                      <arquiteturas> [<teste de presença>]
#===============================================================================

register_components() {
    #                  id            nome                 grupo           função               binário              versão                       arquiteturas   teste de presença
register_component firefox      'Firefox'            'Navegadores'   install_firefox      firefox              'firefox --version'          'amd64 arm64'
     register_component chrome       'Google Chrome'      'Navegadores'   install_chrome       google-chrome-stable 'google-chrome-stable --version' 'amd64'
     register_component brave        'Brave Browser'      'Navegadores'   install_brave        brave-browser        'brave-browser --version'    'amd64 arm64'

     register_component libreoffice  'LibreOffice'        'Escritório'    install_libreoffice  libreoffice          'libreoffice --version'      'amd64 arm64'

     register_component qbittorrent  'qBittorrent'        'Download'      install_qbittorrent  qbittorrent          'qbittorrent --version'      'amd64 arm64'

     register_component vlc          'VLC'                'Multimídia'    install_vlc          vlc                  'vlc --version'              'amd64 arm64'

     register_component gparted      'GParted'            'Sistema'       install_gparted      gparted              'gparted --version'          'amd64 arm64'
     register_component tweaks       'GNOME Tweaks'       'Sistema'       install_tweaks       gnome-tweaks         'gnome-tweaks --version'     'amd64 arm64'
     register_component bleachbit    'BleachBit'          'Sistema'       install_bleachbit    bleachbit            'bleachbit --version'        'amd64 arm64'
     register_component timeshift    'Timeshift'          'Sistema'       install_timeshift    timeshift            'timeshift --version'        'amd64 arm64'
     register_component stacer       'Stacer'             'Sistema'       install_stacer       stacer               'stacer --version'           'amd64 arm64'

     register_component 7zip         '7-Zip'              'Compactação'   install_7zip         7z                   '7z i'                       'amd64 arm64' 'command -v 7z || command -v 7zz'

     register_component screenshot   'Captura de tela'    'Captura'       install_screenshot   flameshot            'flameshot --version'        'amd64 arm64' 'command -v flameshot'

     register_component discord      'Discord'            'Comunicação'   install_discord      discord              'discord --version'          'amd64'       'command -v discord || flatpak info com.discordapp.Discord'
     register_component telegram     'Telegram Desktop'   'Comunicação'   install_telegram     telegram-desktop     'telegram-desktop --version' 'amd64 arm64' 'command -v telegram-desktop || flatpak info org.telegram.desktop'

     register_component obs          'OBS Studio'         'Extras'        install_obs          obs                  'obs --version'              'amd64 arm64' 'command -v obs || flatpak info com.obsproject.Studio'

     register_component keepassxc   'KeePassXC'          'Segurança'     install_keepassxc    keepassxc            'keepassxc --version'        'amd64 arm64' 'command -v keepassxc'
}

kit_main "$@"
