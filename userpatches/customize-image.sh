#!/bin/bash
# customize-image.sh - Script to customize Armbian image for Kubernetes
# This script runs in the chroot environment during image creation
# Used by the Armbian build system to customize the image before final packaging

# Enable error handling
set -e

# Uncomment to enable debug output
#set -x

# ===== FUNCTIONS =====
#
# Log function for better diagnostics
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/customize-image.log
}

# Error handling function
handle_error() {
    log "ERROR: An error occurred on line $1"
    exit 1
}

# Set up error handling
trap 'handle_error $LINENO' ERR

# Create log file
touch /var/log/customize-image.log
log "Starting image customization"

# ===== KUBERNETES CONFIG =====
#
KUBERNETES_VERSION=v1.32
CRIO_VERSION=v1.32

log "KUBERNETES CONFIG: Setting up Kubernetes $KUBERNETES_VERSION and CRI-O $CRIO_VERSION"
log "Installing prerequisites"
apt update --quiet || { log "Failed to update apt"; exit 1; }
apt install --quiet --yes \
	apt-transport-https ca-certificates curl gpg software-properties-common || \
	{ log "Failed to install prerequisite packages"; exit 1; }

# Download the public signing key for the Kubernetes repository
log "Adding Kubernetes and CRI-O repositories and public signing keys"
if ! curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; then
    log "Failed to download Kubernetes signing key"
    exit 1
fi

# Download the public signing key for the CRI-O repository
if ! curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg; then
    log "Failed to download CRI-O signing key"
    exit 1
fi
    
# Add the appropriate Kubernetes and CRI-O apt repositories
# Also install nftables (for kube-proxy)
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | tee /etc/apt/sources.list.d/cri-o.list

log "Installing Kubernetes components"
apt update --quiet || { log "Failed to update apt after adding repositories"; exit 1; }
apt install --quiet --yes kubelet kubeadm kubectl cri-o nftables || \
	{ log "Failed to install Kubernetes components"; exit 1; }

# Pin versions to prevent accidental upgrades
apt-mark hold kubelet kubeadm kubectl cri-o
log "Kubernetes components installed and pinned successfully"

# ===== OS CONFIG =====
#
log "OS CONFIG: Configuring OS for Kubernetes"

# sysctl params required by Kubernetes setup, params persist across reboots
log "Setting kernel parameters for Kubernetes"
cat << EOF | tee /etc/sysctl.d/k8s.conf
# Kubernetes required settings
net.ipv4.ip_forward = 1
## Additional recommended settings ?
#net.bridge.bridge-nf-call-iptables = 1
#net.ipv4.conf.all.forwarding = 1
#vm.swappiness = 0
EOF

# Disable armbian swap (Kubernetes recommendation)
# https://docs.armbian.com/User-Guide_Fine-Tuning/#swap-for-experts
log "Disabling swap"
cat << EOF | tee /etc/default/armbian-zram-config
# Disabled for Kubernetes compatibility
SWAP=false
EOF

# ===== USER SETUP =====
#
log "Setting up pi user"
adduser --debug --disabled-password --gecos 'k8s pi user' --home /home/pi pi
usermod -aG sudo pi

# ===== SSH SECURITY =====
#
log "Securing SSH configuration"
sed -i '/PermitRootLogin yes/d' /etc/ssh/sshd_config
sed -i '/PasswordAuthentication yes/d' /etc/ssh/sshd_config

cat << EOF > /etc/ssh/sshd_config.d/armbian.conf
# Security settings for Kubernetes nodes
PermitRootLogin no
PasswordAuthentication no
AllowUsers pi
EOF

# ===== K8S SETUP =====
log "Prepare systemd service unit installation"
# The kubeadm bootstrap script and service unit are copied by configure-image.sh
touch /usr/lib/systemd/system
ln -s /usr/lib/systemd/system/k8s-firstboot.service /etc/systemd/system/multi-user.target.wants/k8s-firstboot.service

# Create token for both controlplane and node (used at bootstrap only)
echo "$(tr -dc 'a-f0-9' < /dev/urandom | head -c 6).$(tr -dc 'a-f0-9' < /dev/urandom | head -c 16)" > /root/kubeadm-init-token

# Create 32byte key for certificate encryption (used at bootstrap only)
echo "$(tr -dc 'a-f0-9' < /dev/urandom | head -c 64)" > /root/kubeadm-cert-key

# ===== COMPLETION =====
log "Image customization completed successfully"
