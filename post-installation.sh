#!/bin/bash

VERMELHO='\e[1;91m'
VERDE='\e[1;92m'
SEM_COR='\e[0m'

echo -e "${VERDE}Iniciando o processo de configuração após formatação...${SEM_COR}"
sudo apt update

aplicacoes=(
    linux-headers-$(uname -r)
    linux-generic
    gcc
    make
    snapd
    gparted
    timeshift
    vlc
    code
    gnome-sushi
    git
    curl
    wget
    ubuntu-restricted-extras
    #Dependencies .NET
    ca-certificates
    libc6
    libgcc-s1
    libicu74
    liblttng-ust1
    libssl3
    libstdc++6
    libunwind8
    zlib1g
)

travas_apt(){
    echo -e "${VERDE}[INFO] - Removendo travas APT!${SEM_COR}"
    sudo rm /var/lib/dpkg/lock-frontend
    sudo rm /var/cache/apt/archives/lock
}

test_net(){
    if ! ping -c 1 8.8.8.8 -q &> /dev/null; then
    echo -e "${VERMELHO}[ERROR] - Seu computador não tem conexão com a Internet. Verifique a rede.${SEM_COR}"
    exit 1
    else
    echo -e "${VERDE}[INFO] - Conexão com a Internet funcionando normalmente.${SEM_COR}"
    fi
}

install_deb(){
    echo -e "${VERDE}[INFO] - Instalando Deb!${SEM_COR}"
    for app in ${aplicacoes[@]}
    do
        echo -e "${VERDE}Instalando: $app ${SEM_COR}"
        sudo apt install "$app" -y
    done
}

install_flatpak(){
    echo -e "${VERDE}[INFO] - Instalando Flatpak!${SEM_COR}"
    flatpak install flathub org.freedesktop.Piper -y
    flatpak install flathub com.github.iwalton3.jellyfin-media-player -y
    flatpak install flathub com.github.johnfactotum.Foliate -y
    flatpak install flathub com.obsproject.Studio -y
    flatpak install flathub com.spotify.Client -y
    flatpak install flathub org.gnome.Boxes -y
    flatpak install flathub org.qbittorrent.qBittorrent -y
    flatpak install flathub org.flameshot.Flameshot -y
    flatpak install flathub com.discordapp.Discord -y
    flatpak install flathub org.keepassxc.KeePassXC -y
    flatpak install flathub org.localsend.localsend_app -y
    # flatpak install flathub se.sjoerd.Graphs -y
    flatpak install flathub com.github.geigi.cozy -y
}

install_dotnet(){
    echo -e "${VERDE}[INFO] - Instalando .Net!${SEM_COR}"
    sudo apt install dotnet-sdk-6.0 -y
    sudo apt install dotnet-sdk-8.0 -y
}

extra_config(){
    # Pasta para desenvolvimento
    mkdir /home/$USER/dev

    # Driver para mesa digitalizadora
    cd /home/$USER
    git clone https://github.com/FMHemerli/veikk-s640-driver.git
    cd veikk-s640-driver/
    make && sudo make install clean
    cd /home/$USER
}

test_net
travas_apt
install_deb
install_flatpak
install_dotnet
extra_config

sudo apt update
sudo apt upgrade -y
sudo apt autoremove
sudo apt autoclean
sudo apt clean

echo -e "${VERDE}[INFO] - Script finalizado, instalação concluída! :)${SEM_COR}"