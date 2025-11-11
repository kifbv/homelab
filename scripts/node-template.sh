#!/usr/bin/bash
# k8s install script for node (worker)
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

# Format NVMe drives for Ceph storage
log "Checking for NVMe drives to format..."
if command -v nvme &> /dev/null; then
	for nvme_dev in /dev/nvme[0-9]n[0-9]; do
		if [ -b "$nvme_dev" ]; then
			log "Found NVMe device: $nvme_dev"
			# Check if device has any Ceph or filesystem signatures
			if lsblk -n -o FSTYPE "$nvme_dev" 2>/dev/null | grep -qE 'ceph_bluestore|xfs|ext4|btrfs'; then
				log "Device $nvme_dev has existing data, formatting..."
				nvme format "$nvme_dev" -s 0 -n 1 2>&1 | tee -a $LOG_FILE || {
					log "WARNING: nvme format failed, trying fallback method"
					sgdisk --zap-all "$nvme_dev" 2>&1 | tee -a $LOG_FILE || true
					dd if=/dev/zero of="$nvme_dev" bs=1M count=100 2>&1 | tee -a $LOG_FILE || true
				}
				log "Device $nvme_dev formatted successfully"
			else
				log "Device $nvme_dev appears clean, skipping format"
			fi
		fi
	done
else
	log "nvme-cli not found, skipping NVMe format"
fi

# Get configuration values
log "Retrieving configuration values"
TOKEN="$(cat /root/kubeadm-init-token)"
# Try different methods to resolve controlplane IP
CP_IP=$(resolvectl query -4 controlplane 2>/dev/null | grep controlplane | cut -f2 -d' ' || getent hosts controlplane | awk '{print $1}' || dig +short controlplane || nslookup controlplane | grep "Address:" | tail -1 | awk '{print $2}')

# Join as a worker node
log "This is a worker node"
kubeadm join "${CP_IP}:6443" --token="$TOKEN" --discovery-token-unsafe-skip-ca-verification

# Cleanup
log "Disable service to avoid issue in case of reboot"
systemctl disable k8s-firstboot.service
log "Remove install files from /root/"
rm -f /root/*