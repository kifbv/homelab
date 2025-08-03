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

# Sleep to ensure everything is set up
log "Sleep 5s just to be sure everything else is set up"
sleep 5

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