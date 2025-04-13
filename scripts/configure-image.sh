#!/bin/bash
# Script to the Armbian image before burning to SD card

set -e

# Check if script is run as root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Show usage information
function show_usage() {
    echo "Usage: $0 --image <image_file> --hostname <hostname> --ssh-key <ssh_key_file> --password <password>"
    echo "Example: $0 --image Armbian_22.11.0_Rpi4_jammy_current_5.15.80.img --hostname node0 --ssh-key ~/.ssh/id_ed25519.pub --password pass1234"
    echo
    echo "Options:"
    echo "  --image, -i       Path to the Armbian image file"
    echo "  --hostname, -h    Hostname to set on the image (must be 'controlplane', 'controlplane[0-9]', or 'node[0-9]')"
    echo "  --ssh-key, -k     Path to the SSH public key file to add to authorized_keys"
    echo "  --password, -p    Password for the k8s pi user (in clear text)"
    echo "  --help            Show this help message"
}

# Initialize variables
IMAGE_FILE=""
NEW_HOSTNAME=""
SSH_KEY_FILE=""
PASSWD=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image|-i)
            IMAGE_FILE="$2"
            shift 2
            ;;
        --hostname|-h)
            NEW_HOSTNAME="$2"
            shift 2
            ;;
        --ssh-key|-k)
            SSH_KEY_FILE="$2"
            shift 2
            ;;
        --password|-p)
            PASSWD="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            show_usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$IMAGE_FILE" || -z "$NEW_HOSTNAME" || -z "$SSH_KEY_FILE" || -z "$PASSWD" ]]; then
    echo "Error: Missing required arguments" >&2
    show_usage
    exit 1
fi

# Validate sops secret exists
SOPS_SECRET="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.config/sops/age/keys.txt"
if [[ ! -f $SOPS_SECRET ]]; then
    echo "Error: sops secret not found, you need to generate one before running this script" >&2
    exit 1
fi

# Validate image file exists
if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "Error: Image file not found: $IMAGE_FILE" >&2
    exit 1
fi

# Validate hostname is one of the allowed patterns
if ! [[ "$NEW_HOSTNAME" == "controlplane" || "$NEW_HOSTNAME" =~ ^controlplane[0-9]$ || "$NEW_HOSTNAME" =~ ^node[0-9]$ ]]; then
    echo "Error: Invalid hostname. Allowed formats are: 'controlplane', 'controlplane[0-9]', or 'node[0-9]'" >&2
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
    path: "kubernetes/rpi-cluster/flux/config"
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

# Create bootstrap script based on hostname
echo "Creating appropriate bootstrap script for $NEW_HOSTNAME..."

# Copy the appropriate template based on hostname
if [[ "$NEW_HOSTNAME" == "controlplane" ]]; then
    # First control plane node
    cp "$(dirname "$0")/controlplane-template.sh" "$MOUNT_DIR/usr/bin/k8s-firstboot.sh"
    # Copy kubeadm configuration template
    cp "$(dirname "$0")/kubeadm-init.yaml.tpl" "$MOUNT_DIR/root/kubeadm-init.yaml.tpl"
elif [[ "$NEW_HOSTNAME" =~ ^controlplane[0-9]$ ]]; then
    # Additional control plane nodes
    cp "$(dirname "$0")/controlplane-secondary-template.sh" "$MOUNT_DIR/usr/bin/k8s-firstboot.sh"
elif [[ "$NEW_HOSTNAME" =~ ^node[0-9]$ ]]; then
    # Worker nodes
    cp "$(dirname "$0")/node-template.sh" "$MOUNT_DIR/usr/bin/k8s-firstboot.sh"
else
    # This should never happen due to validation above
    echo "Error: Unrecognized hostname pattern: $NEW_HOSTNAME" >&2
    exit 1
fi

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
	sudo dd bs=4M conv=fsync oflag=direct status=progress if=$IMAGE_FILE of=/dev/<your_sdcard>"
