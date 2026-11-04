#!/bin/bash
# ==============================================================================
# Scooter Rental System - EC2 Initial Provisioning Script
# Target: Ubuntu 22.04+ or Amazon Linux 2023 on AWS EC2
# Run as: sudo bash setup-ec2.sh
# ==============================================================================

set -euo pipefail

echo ">>> [1/6] Detecting OS and updating packages..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot determine OS. Exiting."
    exit 1
fi

if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release git ufw

    echo ">>> [2/6] Installing Docker on Ubuntu/Debian..."
    sudo install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo ">>> [3/6] Configuring Firewall (UFW)..."
    sudo ufw allow 22/tcp comment 'SSH'
    sudo ufw allow 80/tcp comment 'HTTP Web'
    sudo ufw allow 443/tcp comment 'HTTPS Web'
    sudo ufw --force enable || true

elif [ "$OS" = "amzn" ] || [ "$OS" = "al2023" ]; then
    sudo dnf update -y
    sudo dnf install -y docker git
    sudo systemctl enable --now docker
    # Install docker compose plugin
    DOCKER_CONFIG=${DOCKER_CONFIG:-/usr/local/lib/docker}
    sudo mkdir -p $DOCKER_CONFIG/cli-plugins
    sudo curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m) -o $DOCKER_CONFIG/cli-plugins/docker-compose
    sudo chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
fi

echo ">>> [4/6] Enabling and starting Docker daemon..."
sudo systemctl enable docker
sudo systemctl start docker

# Add current user and ubuntu/ec2-user to docker group
CURRENT_USER=$(whoami)
sudo usermod -aG docker "$CURRENT_USER" || true
if id "ubuntu" &>/dev/null; then sudo usermod -aG docker ubuntu; fi
if id "ec2-user" &>/dev/null; then sudo usermod -aG docker ec2-user; fi

echo ">>> [5/6] Setting up application workspace at /opt/scooter-rent..."
APP_DIR="/opt/scooter-rent"
sudo mkdir -p "$APP_DIR"
sudo chown -R "$CURRENT_USER:docker" "$APP_DIR" || true
sudo chmod 775 "$APP_DIR"

echo ">>> [6/6] Verifying Docker and Docker Compose..."
docker --version
docker compose version

echo "=============================================================================="
echo "EC2 Setup Completed Successfully!"
echo "Target deploy directory: /opt/scooter-rent"
echo "Note: Log out and log back in for docker group membership to take effect."
echo "=============================================================================="
