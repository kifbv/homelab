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

# Wait for CRI-O to be ready
log "Waiting for CRI-O to be ready..."
CRIO_SOCKET="/var/run/crio/crio.sock"
MAX_WAIT=60
WAITED=0

while [ ! -S "$CRIO_SOCKET" ] && [ $WAITED -lt $MAX_WAIT ]; do
	log "Waiting for CRI-O socket... ($WAITED/$MAX_WAIT seconds)"
	sleep 2
	WAITED=$((WAITED + 2))
done

if [ ! -S "$CRIO_SOCKET" ]; then
	log "ERROR: CRI-O socket not ready after $MAX_WAIT seconds"
	exit 1
fi

log "CRI-O socket ready, waiting 5s for runtime to stabilize"
sleep 5

# Disable swap (required for Kubernetes)
log "Disabling swap..."
swapoff -a
systemctl mask dev-zram0.swap 2>/dev/null || true
log "Swap disabled"

# Get configuration values
log "Retrieving configuration values"
export TOKEN="$(cat /root/kubeadm-init-token)"
export CERT_KEY="$(cat /root/kubeadm-cert-key)"
# Try different network interface names (Debian may use different naming)
export HOST_IP="$(ip -4 -o addr show eth0 2>/dev/null | tr -s ' ' | cut -f4 -d' ' | cut -f1 -d/ || ip -4 -o addr show end0 2>/dev/null | tr -s ' ' | cut -f4 -d' ' | cut -f1 -d/ || ip -4 -o addr show enp1s0 2>/dev/null | tr -s ' ' | cut -f4 -d' ' | cut -f1 -d/ || ip route get 1.1.1.1 | grep -oP 'src \K\S+')"
# Read subnets from plain text files (created by configure script)
export POD_SUBNET="$(cat /root/pod-subnet)"
export SERVICE_SUBNET="$(cat /root/service-subnet)"
log "TOKEN: $TOKEN"
log "CERT_KEY: $CERT_KEY"
log "HOST_IP: $HOST_IP"
log "POD_SUBNET: $POD_SUBNET"
log "SERVICE_SUBNET: $SERVICE_SUBNET"

# Initialize the first control plane
log "This is the first control plane"

# Generate kubeadm config from template with variables substituted
log "Creating kubeadm init configuration"
mkdir -p /root/kubeadm
envsubst < /root/kubeadm-init.yaml.tpl > /root/kubeadm/kubeadm-init.yaml
cat /root/kubeadm/kubeadm-init.yaml >> $LOG_FILE

# Initialize the cluster with the configuration file
log "Running kubeadm init with configuration"
kubeadm init --config=/root/kubeadm/kubeadm-init.yaml --upload-certs --skip-phases=addon/kube-proxy

# Install required components
log "Installing cilium"
mkdir -p /root/cilium
envsubst < /root/cilium-values.yaml.tpl > /root/cilium/values.yaml
cat /root/cilium/values.yaml >> $LOG_FILE
export KUBECONFIG=/etc/kubernetes/admin.conf
# Gateway API CRDs must be installed prior to installing Cilium
# TODO: install basic cilium cni first and move them to flux install
sleep 5 && kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
sleep 5 && kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml
# Install Cilium
sleep 5 && helm install cilium cilium --repo https://helm.cilium.io/ --namespace kube-system -f /root/cilium/values.yaml

# TODO: use kubelet-csr-approver instead
log "Setting up CSR auto-approval script"
cat <<EOF > /usr/bin/approve-kubelet-csrs.sh
#!/bin/bash
# Script to auto-approve kubelet serving certificate CSRs
# Will run for 24 hours and then exit

LOGFILE="/var/log/approve-kubelet-csrs.log"
END_TIME=\$(( \$(date +%s) + 86400 ))  # Current time + 24 hours (86400 seconds)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting CSR approval script. Will run for 24 hours." > \$LOGFILE

while [ \$(date +%s) -lt \$END_TIME ]; do
  # Get pending kubelet-serving CSRs and approve them
  PENDING_CSRS=\$(kubectl get csr -o go-template='{{range .items}}{{if and (eq .spec.signerName "kubernetes.io/kubelet-serving") (eq .status.conditions nil)}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
  
  if [ -n "\$PENDING_CSRS" ]; then
    for CSR in \$PENDING_CSRS; do
      kubectl certificate approve \$CSR
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Approved CSR: \$CSR" >> \$LOGFILE
    done
  fi
  
  # Check every 10 seconds
  sleep 10
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] CSR approval script completed its 24-hour run." >> \$LOGFILE
EOF

chmod +x /usr/bin/approve-kubelet-csrs.sh

log "Starting CSR approval script in background"
nohup /usr/bin/approve-kubelet-csrs.sh &

log "Setting up flux"
sleep 5 && kubectl apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml
# Check if SOPS key exists before creating secret
if [ -f "/root/keys.txt" ]; then
    sleep 5 && kubectl create secret generic flux-sops --namespace=flux-system --from-file=age.agekey=/root/keys.txt
else
    log "Warning: SOPS key not found, skipping flux-sops secret creation"
fi
if [ -f "/root/flux-instance.yaml" ]; then
    sleep 5 && kubectl apply -f /root/flux-instance.yaml
else
    log "Warning: flux-instance.yaml not found, skipping flux instance creation"
fi

# Setup kubeconfig for the pi user
log "Copy config files to pi user home dir"
mkdir -p /home/pi/.kube
cp /etc/kubernetes/admin.conf /home/pi/.kube/config
chown -R "$(id -u pi):$(id -g pi)" /home/pi/.kube

# Cleanup
log "Disable service to avoid issue in case of reboot"
systemctl disable k8s-firstboot.service
log "Remove install files from /root/"
#rm -f /root/*
