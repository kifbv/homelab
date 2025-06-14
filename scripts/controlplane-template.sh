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
export TOKEN="$(cat /root/kubeadm-init-token)"
export CERT_KEY="$(cat /root/kubeadm-cert-key)"
export HOST_IP="$(ip -4 -o addr show end0 | tr -s ' ' | cut -f4 -d' ' | cut -f1 -d/)"
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
#rm -f /root/*
