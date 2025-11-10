#!/usr/bin/bash
# k8s install script for additional control plane node
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
TOKEN="$(cat /root/kubeadm-init-token)"
CERT_KEY="$(cat /root/kubeadm-cert-key)"
# Try different methods to resolve controlplane IP
CP_IP=$(resolvectl query -4 controlplane 2>/dev/null | grep controlplane | cut -f2 -d' ' || getent hosts controlplane | awk '{print $1}' || dig +short controlplane || nslookup controlplane | grep "Address:" | tail -1 | awk '{print $2}')

# Join as an additional control plane
log "This is an additional control plane node"
kubeadm join "${CP_IP}:6443" --token="$TOKEN" --control-plane --certificate-key="$CERT_KEY" --discovery-token-unsafe-skip-ca-verification

# Cleanup
log "Disable service to avoid issue in case of reboot"
systemctl disable k8s-firstboot.service
log "Remove install files from /root/"
rm -f /root/*