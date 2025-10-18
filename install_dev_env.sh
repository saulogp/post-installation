#!/bin/bash

set -euo pipefail
DOWNLOAD_DIR="$HOME/Downloads"
mkdir -p "$DOWNLOAD_DIR"

# Função auxiliar para checar se um comando existe
is_installed() {
    command -v "$1" &>/dev/null
}

echo "==== Atualizando pacotes ===="
sudo apt-get update -y

echo "==== Instalando .NET 9.0 SDK ===="
if is_installed dotnet; then
    echo "[OK] .NET já está instalado (versão: $(dotnet --version))"
else
    sudo apt-get install -y dotnet-sdk-9.0 || {
        echo "[ERRO] Falha ao instalar .NET"; exit 1;
    }
fi

echo "==== Instalando Docker ===="
if is_installed docker; then
    echo "[OK] Docker já está instalado (versão: $(docker --version))"
else
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
    fi

    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Configuração do grupo docker
    sudo groupadd docker 2>/dev/null || true
    sudo usermod -aG docker $USER
    sudo systemctl disable docker.service || true
    sudo systemctl disable containerd.service || true
fi

echo "==== Instalando kubectl ===="
if is_installed kubectl; then
    # Pega apenas a versão de cliente, remove excesso
    KUBECTL_VER=$(kubectl version --client 2>/dev/null | head -n 1 | sed 's/Client Version: //')
    echo "[OK] kubectl já está instalado (versão: ${KUBECTL_VER:-desconhecida})"
else
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | \
        sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    fi

    if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list
        sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
    fi

    sudo apt-get update -y
    sudo apt-get install -y kubectl
fi

echo "==== Instalando Minikube ===="
if is_installed minikube; then
    echo "[OK] Minikube já está instalado (versão: $(minikube version | head -n1))"
else
    cd "$DOWNLOAD_DIR"
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube_latest_amd64.deb
    sudo dpkg -i minikube_latest_amd64.deb || sudo apt-get install -f -y
    rm -f minikube_latest_amd64.deb
fi

echo "==== Instalando K9S ===="
if is_installed k9s; then
    echo "[OK] K9S já está instalado (versão: $(k9s version -s 2>/dev/null || echo "desconhecida"))"
else
    cd "$DOWNLOAD_DIR"
    wget -q https://github.com/derailed/k9s/releases/download/v0.32.5/k9s_linux_amd64.deb -O k9s_linux_amd64.deb
    sudo apt install -y ./k9s_linux_amd64.deb || sudo apt-get install -f -y
    rm -f k9s_linux_amd64.deb
fi

echo "==== Instalação concluída com sucesso! ===="
echo "✅ .NET, Docker, kubectl, Minikube e K9S prontos."
echo "⚠️ É recomendado reiniciar a sessão para aplicar as permissões do grupo 'docker'."

