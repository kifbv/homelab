#!/usr/bin/bash
# k8s install script for first control plane node
# for some reason i don't understand, both /bin/bash and /usr/bin/bash are bash v5.x
# but only the later knows about [[ which makes me think dash is used instead which
# means the shebang has to be as above

# Initial setup
readonly LOG_FILE="/var/log/k8s-firstboot.log"
touch $LOG_FILE
exec &>$LOG_FILE

# Log function
log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Sleep to ensure everything is set up
log "Sleep 5s just to be sure everything else is set up"
sleep 5

# Get configuration values
log "Retrieving configuration values"
TOKEN="$(cat /root/kubeadm-init-token)"
CERT_KEY="$(cat /root/kubeadm-cert-key)"
HOST_IP="$(ip -4 -o addr show end0 | tr -s ' ' | cut -f4 -d' ' | cut -f1 -d/)"

# Initialize the first control plane
log "This is the first control plane"

# Generate kubeadm config from template with variables substituted
log "Creating kubeadm init configuration"
mkdir -p /root/kubeadm
envsubst < /root/kubeadm-init.yaml.tpl > /root/kubeadm/kubeadm-init.yaml
cat /root/kubeadm/kubeadm-init.yaml >> $LOG_FILE

# Initialize the cluster with the configuration file
log "Running kubeadm init with configuration"
kubeadm init --config=/root/kubeadm/kubeadm-init.yaml --upload-certs

# Install required components
log "Installing cilium"
export KUBECONFIG=/etc/kubernetes/admin.conf
sleep 5 && helm install --repo https://helm.cilium.io/ cilium cilium --namespace kube-system --set kubeProxyReplacement=true --set k8sServiceHost=$HOST_IP --set k8sServicePort=6443 --set hubble.relay.enabled=true --set hubble.ui.enabled=true

log "Setting up flux"
sleep 5 && kubectl apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml
sleep 5 && kubectl create secret generic flux-sops --namespace=flux-system --from-file=age.agekey=/root/keys.txt
sleep 5 && kubectl apply -f /root/flux-instance.yaml

# Setup kubeconfig for the pi user
log "Copy config files to pi user home dir"
cp /etc/kubernetes/admin.conf /home/pi/.kube/config
chown $(id -u pi):$(id -g pi) /home/pi/.kube/config

# Cleanup
log "Disable service to avoid issue in case of reboot"
systemctl disable k8s-firstboot.service
log "Remove install files from /root/"
rm -f /root/*
