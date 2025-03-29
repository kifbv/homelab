#!/bin/bash
# Script to modify hostname and SSH keys in Armbian image before burning to SD card

set -e

# Check if script is run as root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Show usage information
function show_usage() {
    echo "Usage: $0 <image_file> <new_hostname> <ssh_public_key_file>"
    echo "Example: $0 Armbian_22.11.0_Rpi4_jammy_current_5.15.80.img node-01 ~/.ssh/id_ed25519.pub pass1234"
    echo
    echo "Arguments:"
    echo "  <image_file>          Path to the Armbian image file"
    echo "  <new_hostname>        Hostname to set on the image"
    echo "  <ssh_public_key_file> SSH public key file to add to authorized_keys"
    echo "  <password>            Password for the k8s pi user (in clear text)"
}

# Validate arguments
if [[ $# -lt 4 ]]; then
    show_usage
    exit 1
fi

IMAGE_FILE="$1"
NEW_HOSTNAME="$2"
SSH_KEY_FILE="$3"
PASSWD="$4"
SOPS_SECRET="$HOME/.config/sops/age/keys.txt"

# Validate sops secret exists
if [[ ! -f $SOPS_SECRET ]]; then
	echo "Error: sops secret not found, you need to generate one before running this script" >&2
	exit 1
fi

# Validate image file exists
if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "Error: Image file not found: $IMAGE_FILE" >&2
    exit 1
fi

# Validate hostname format
if ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
    echo "Error: Invalid hostname format. Hostname should contain only alphanumeric characters and hyphens, and cannot start or end with a hyphen." >&2
    exit 1
fi

# Validate SSH key file
if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Error: SSH public key file not found: $SSH_KEY_FILE" >&2
    exit 1
fi

# Use the 'file' utility to validate it looks like a public key
KEY_TYPE=$(file -b "$SSH_KEY_FILE")
if ! echo "$KEY_TYPE" | grep -q "OpenSSH.*public key"; then
    echo "Warning: File does not appear to be an OpenSSH public key: $SSH_KEY_FILE" >&2
    echo "File type detected: $KEY_TYPE" >&2
    echo "Proceeding anyway, but this might not work as expected." >&2
fi

echo "Modifying image: $IMAGE_FILE"

# Find partitions in the image
PARTINFO=$(fdisk -l "$IMAGE_FILE")
ROOTFS_START=$(echo "$PARTINFO" | grep -E "Linux$" | tr -s ' ' | cut -f2 -d' ')
SECTOR_SIZE=$(echo "$PARTINFO" | grep -E '^Sector size.*bytes' | tr -s ' ' | cut -f4 -d ' ')

if [[ -z "$ROOTFS_START" ]] || [[ -z "$SECTOR_SIZE" ]]; then
    echo "Error: Could not determine root partition information" >&2
    exit 1
fi

# Calculate offset in bytes
OFFSET=$((ROOTFS_START * SECTOR_SIZE))
echo "Root partition starts at sector $ROOTFS_START (offset: $OFFSET bytes)"

MOUNT_DIR=$(mktemp -d)
echo "Created temporary mount point at $MOUNT_DIR"

LOOP_DEVICE=$(losetup -f)
losetup -o "$OFFSET" "$LOOP_DEVICE" "$IMAGE_FILE"
echo "Attached loop device: $LOOP_DEVICE"

mount "$LOOP_DEVICE" "$MOUNT_DIR"
echo "Mounted filesystem"

echo "Configuring hostname..."
echo "$NEW_HOSTNAME" > "$MOUNT_DIR/etc/hostname"
sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" "$MOUNT_DIR/etc/hosts"

echo "Configuring SSH key and .kube dir..."
#mkdir -p -m 700 "$MOUNT_DIR/home/pi/.{ssh,kube}"
mkdir -p -m 700 "$MOUNT_DIR/home/pi/.ssh"
mkdir -p -m 700 "$MOUNT_DIR/home/pi/.kube"
cat "$SSH_KEY_FILE" > "$MOUNT_DIR/home/pi/.ssh/authorized_keys"
chmod 600 "$MOUNT_DIR/home/pi/.ssh/authorized_keys"

# Set ownership (assuming pi user has uid/gid 1000)
# This may not be accurate for all images, so we try to get the actual IDs
PI_UID=$(grep "^pi:" "$MOUNT_DIR/etc/passwd" | cut -d: -f3)
PI_GID=$(grep "^pi:" "$MOUNT_DIR/etc/passwd" | cut -d: -f4)

if [ -n "$PI_UID" ] && [ -n "$PI_GID" ]; then
    chown -R "${PI_UID}:${PI_GID}" "$MOUNT_DIR/home/pi"
else
    # Fallback to common values
    chown -R 1000:1000 "$MOUNT_DIR/home/pi"
    echo "Warning: Could not determine pi user IDs, using default 1000:1000"
fi

# Add password for pi user
echo "pi:$PASSWD" | chpasswd -P "$MOUNT_DIR"

# Copy sops secret to root home dir
cp $SOPS_SECRET $MOUNT_DIR/root/keys.txt

# Create systemd service unit
cat <<EOF> "$MOUNT_DIR/usr/lib/systemd/system/k8s-firstboot.service"
[Unit]
Description=Install kubernetes at first boot

[Service]
Type=oneshot
ExecStart=/usr/bin/k8s-firstboot.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

# Create FluxInstance resource
cat <<-EOF> "$MOUNT_DIR/root/flux-instance.yaml"
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.x"
    registry: "ghcr.io/fluxcd"
    artifact: "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests"
  sync:
    kind: GitRepository
    url: "$(git remote get-url origin)"
    ref: "refs/heads/main"
    path: "kubernetes/rpi-cluster"
  kustomize:
    patches:
      - patch: |
          - op: add
            path: /spec/decryption
            value:
              provider: sops
              secretRef:
                name: flux-sops
        target:
          kind: Kustomization
EOF

# Create bootstrap script
cat <<-EOF> "$MOUNT_DIR/usr/bin/k8s-firstboot.sh"
#!/usr/bin/bash
# k8s install script
# for some reason i don't understand, both /bin/bash and /usr/bin/bash are bash v5.x
# but only the later knows about [[ which makes me think dash is used instead which
# means the shebang has to be as above

# run kubeadm init for controlplane or kubeadm join for nodes
# based on the hostname and using the token created by customize-image.sh
# todo: config file instead of arguments + serverTLSBootstrap: true

# initial setup
readonly LOG_FILE="/var/log/k8s-firstboot.log"
touch \$LOG_FILE
exec &>\$LOG_FILE

# functions
log() {
	echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1"
}

setup_first_controlplane() {
	log "This is the first controlplane"
	kubeadm init --skip-phases=addon/kube-proxy --service-cidr 10.244.0.0/20 --pod-network-cidr=10.244.64.0/18 --token=\$TOKEN --control-plane-endpoint=\$HOST_IP --upload-certs --certificate-key=\$CERT_KEY
	log "Install flux operator
	sleep 5 && helm install cilium cilium/cilium --version 1.17.1 --repo https://helm.cilium.io/ --namespace kube-system --set kubeProxyReplacement=true --set k8sServiceHost=\$HOST_IP --set k8sServicePort=6443 --set hubble.relay.enabled=true --set hubble.ui.enabled=true
	sleep 5 && kubectl create secret generic flux-sops --namespace=flux-system --from-file=age.agekey=/root/keys.txt
	sleep 5 && kubectl apply -f https://github.com/controlplaneio-fluxcd/flux-operator/releases/latest/download/install.yaml
	sleep 5 && kubectl apply -f /root/flux-instance.yaml
}

setup_pi_kubeconfig() {
	log "Copy config files to pi user home dir"
	cp /etc/kubernetes/admin.conf /home/pi/.kube/config
	chown \$(id -u pi):\$(id -g pi) /home/pi/.kube/config
}

setup_next_controlplane() {
	log "This is an extra controlplane"
	kubeadm join \${CP_IP}:6443 --token=\$TOKEN --control-plane --certificate-key=\$CERT_KEY --discovery-token-unsafe-skip-ca-verification
}

setup_worker_node() {
	log "This is a worker node"
	kubeadm join \${CP_IP}:6443 --token=\$TOKEN --discovery-token-unsafe-skip-ca-verification
}
	
cleanup_actions() {
	log "Disable service to avoid issue in case of reboot"
	systemctl disable k8s-firstboot.service
}

# business
log "Sleep 5s just to be sure everything else is set up"
sleep 5

log "Retrieving configuration values"
TOKEN="\$(cat /root/kubeadm-init-token)"
CERT_KEY="\$(cat /root/kubeadm-cert-key)"
HOST_TYPE="\$(cat /etc/hostname)"
HOST_IP="\$(ip -4 -o addr show end0 | tr -s ' ' | cut -f4 -d' ' | cut -f1 -d/)"
CP_IP=\$(resolvectl query -4 controlplane | grep controlplane | cut -f2 -d' ')

case \$HOST_TYPE in
	controlplane)
		setup_first_controlplane
		setup_pi_kubeconfig
		;;
	controlplane*)
		setup_next_controlplane
		;;
	node*)
		setup_worker_node
		;;
esac

cleanup_actions
EOF

# Make bootstrap script executable
chmod 755 "$MOUNT_DIR/usr/bin/k8s-firstboot.sh"
# Set root only permissions on /root/ files
chmod 600 /root/*

# Verify actions
SSH_KEY_VERIFIED="$(cat $MOUNT_DIR/home/pi/.ssh/authorized_keys)"
HOSTNAME_VERIFIED="$(cat $MOUNT_DIR/etc/hostname)"

# Unmount and clean up
echo "Cleaning up..."
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEVICE"
rmdir "$MOUNT_DIR"

echo -e "\nDone! Image $IMAGE_FILE has been modified:"
echo -e "\tHostname=$HOSTNAME_VERIFIED\n\tSSHKey=$SSH_KEY_VERIFIED"
echo -e "\nYou can now burn this image to an SD card with e.g.:
sudo dd bs=4M conv=fsync oflag=direct status=progress if=$1 of=/dev/<your_sdcard>"
