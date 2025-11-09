#!/bin/bash
# configure-rpi5-image.sh - Configure Raspberry Pi 5 image before burning
# This script modifies a Raspberry Pi OS base image (prepared with prepare-base-image.sh)
# to set hostname, SSH keys, and node-specific Kubernetes configuration.

set -e

# Check if script is run as root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Show usage information
function show_usage() {
    cat << EOF
Usage: $0 --image <image_file> --hostname <hostname> --ssh-key <ssh_key_file> --password <password> [OPTIONS]

Configure a Raspberry Pi OS base image (prepared with prepare-base-image.sh) for a specific node.

Example:
  $0 --image rpi5-k8s-base.img --hostname controlplane --ssh-key ~/.ssh/id_ed25519.pub --password mypassword

Options:
  --image, -i       Path to the base Raspberry Pi image file (from prepare-base-image.sh)
                    This file will NOT be modified - a copy will be created
  --output, -o      Output image file path (optional)
                    Default: <hostname>.img (e.g., controlplane.img)
  --hostname, -h    Hostname for this node:
                      'controlplane'         - First control plane node
                      'controlplane[0-9]'    - Additional control plane nodes
                      'node[0-9]'            - Worker nodes
  --ssh-key, -k     Path to SSH public key file for the pi user
  --password, -p    Password for the pi user (in plain text)
  --pod-subnet      CIDR for Kubernetes pod network (default: 10.244.64.0/18)
  --service-subnet  CIDR for Kubernetes service network (default: 10.244.0.0/20)
  --help            Show this help message

The base image will be copied to the output location and then configured.
The original base image remains unchanged and can be reused for other nodes.
EOF
}

# Initialize variables
IMAGE_FILE=""
OUTPUT_FILE=""
NEW_HOSTNAME=""
SSH_KEY_FILE=""
PASSWD=""
POD_SUBNET="10.244.64.0/18"
SERVICE_SUBNET="10.244.0.0/20"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image|-i)
            IMAGE_FILE="$2"
            shift 2
            ;;
        --output|-o)
            OUTPUT_FILE="$2"
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
        --pod-subnet)
            POD_SUBNET="$2"
            shift 2
            ;;
        --service-subnet)
            SERVICE_SUBNET="$2"
            shift 2
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
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

# Check if image file exists
if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "Error: Image file '$IMAGE_FILE' not found" >&2
    exit 1
fi

# Check if SSH key file exists
if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "Error: SSH key file '$SSH_KEY_FILE' not found" >&2
    exit 1
fi

# Use the 'file' utility to validate it looks like a public key
KEY_TYPE=$(file -b "$SSH_KEY_FILE")
if ! echo "$KEY_TYPE" | grep -q "OpenSSH.*public key"; then
    echo "Warning: File does not appear to be an OpenSSH public key: $SSH_KEY_FILE" >&2
    echo "File type detected: $KEY_TYPE" >&2
    #TODO: abort if file not public key
    echo "Proceeding anyway, but this might not work as expected." >&2
fi

# Validate hostname pattern
if [[ ! "$NEW_HOSTNAME" =~ ^(controlplane[0-9]*|node[0-9]+)$ ]]; then
    echo "Error: Hostname must be 'controlplane', 'controlplane[0-9]', or 'node[0-9]'" >&2
    echo "Examples: controlplane, controlplane1, node0, node1" >&2
    exit 1
fi

# Set default output file if not specified
if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="${NEW_HOSTNAME}.img"
fi

# Determine node type
if [[ "$NEW_HOSTNAME" == "controlplane" ]]; then
    NODE_TYPE="controlplane"
elif [[ "$NEW_HOSTNAME" =~ ^controlplane[0-9]+$ ]]; then
    NODE_TYPE="controlplane-secondary"
else
    NODE_TYPE="node"
fi

echo "Configuring image for $NODE_TYPE: $NEW_HOSTNAME"
echo "Input image: $IMAGE_FILE"
echo "Output image: $OUTPUT_FILE"

# Check if output file already exists
if [[ -f "$OUTPUT_FILE" ]]; then
    echo "Warning: Output file '$OUTPUT_FILE' already exists and will be overwritten"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted by user"
        exit 1
    fi
fi

# Copy the base image to output location
echo "Copying base image to $OUTPUT_FILE..."
cp "$IMAGE_FILE" "$OUTPUT_FILE"
echo "Copy complete"

# Create temporary directories
TEMP_DIR=$(mktemp -d)
LOOP_DEVICE=""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    if [[ -n "$LOOP_DEVICE" ]]; then
        # Try both possible boot mount points
        umount "${TEMP_DIR}/rootfs/boot/firmware" 2>/dev/null || true
        umount "${TEMP_DIR}/boot" 2>/dev/null || true
        umount "${TEMP_DIR}/rootfs" 2>/dev/null || true
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

# Mount the image
echo "Mounting image: $OUTPUT_FILE"
LOOP_DEVICE=$(losetup --find --show --partscan "$OUTPUT_FILE")
mkdir -p "${TEMP_DIR}/boot" "${TEMP_DIR}/rootfs"

# Wait for partitions to be ready
sleep 2
partprobe "$LOOP_DEVICE" 2>/dev/null || true
sleep 1

# Mount root partition (usually p2)
mount "${LOOP_DEVICE}p2" "${TEMP_DIR}/rootfs"

# Mount boot partition - Raspberry Pi OS uses /boot/firmware
if [[ -d "${TEMP_DIR}/rootfs/boot/firmware" ]]; then
    mount "${LOOP_DEVICE}p1" "${TEMP_DIR}/rootfs/boot/firmware"
    BOOT_DIR="${TEMP_DIR}/rootfs/boot/firmware"
else
    # Fallback to /boot if /boot/firmware doesn't exist
    mkdir -p "${TEMP_DIR}/boot"
    mount "${LOOP_DEVICE}p1" "${TEMP_DIR}/boot"
    BOOT_DIR="${TEMP_DIR}/boot"
fi

echo "Image mounted successfully"
echo "Root filesystem: ${TEMP_DIR}/rootfs"
echo "Boot filesystem: $BOOT_DIR"

# Configure hostname
echo "Setting hostname to: $NEW_HOSTNAME"
echo "$NEW_HOSTNAME" > "${TEMP_DIR}/rootfs/etc/hostname"

# Update hosts file - handle both custom and Raspberry Pi OS default hostnames
OLD_HOSTNAME=$(cat "${TEMP_DIR}/rootfs/etc/hostname" || echo "raspberrypi")
sed -i "s/rpi5-debian/$NEW_HOSTNAME/g" "${TEMP_DIR}/rootfs/etc/hosts"
sed -i "s/raspberrypi/$NEW_HOSTNAME/g" "${TEMP_DIR}/rootfs/etc/hosts"
# Ensure there's a localhost entry
if ! grep -q "127.0.1.1" "${TEMP_DIR}/rootfs/etc/hosts"; then
    echo "127.0.1.1    $NEW_HOSTNAME" >> "${TEMP_DIR}/rootfs/etc/hosts"
fi

# Configure SSH key and .kube directory
echo "Configuring SSH key and .kube directory for pi user"
PI_HOME="${TEMP_DIR}/rootfs/home/pi"
mkdir -p "$PI_HOME/.ssh"
mkdir -p "$PI_HOME/.kube"
chmod 700 "$PI_HOME/.ssh"
chmod 700 "$PI_HOME/.kube"
cp "$SSH_KEY_FILE" "$PI_HOME/.ssh/authorized_keys"
chmod 700 "$PI_HOME/.ssh"
chmod 600 "$PI_HOME/.ssh/authorized_keys"

# Set ownership (pi user has uid/gid 1000 in the image)
# Try to get actual pi user IDs from the image
PI_UID=$(grep "^pi:" "${TEMP_DIR}/rootfs/etc/passwd" | cut -d: -f3 2>/dev/null || echo "1000")
PI_GID=$(grep "^pi:" "${TEMP_DIR}/rootfs/etc/passwd" | cut -d: -f4 2>/dev/null || echo "1000")

if [ -n "$PI_UID" ] && [ -n "$PI_GID" ]; then
    chown -R "${PI_UID}:${PI_GID}" "$PI_HOME/.ssh"
    chown -R "${PI_UID}:${PI_GID}" "$PI_HOME/.kube" 2>/dev/null || true
else
    # Fallback to common values
    chown -R 1000:1000 "$PI_HOME/.ssh"
    chown -R 1000:1000 "$PI_HOME/.kube" 2>/dev/null || true
    echo "Warning: Could not determine pi user IDs, using default 1000:1000"
fi

# Set password for pi user
echo "Setting password for pi user"
PI_PASSWORD_HASH=$(openssl passwd -6 "$PASSWD")
sed -i "s|^pi:[^:]*:|pi:$PI_PASSWORD_HASH:|" "${TEMP_DIR}/rootfs/etc/shadow"

# Configure Kubernetes settings
echo "Configuring Kubernetes settings"

# Ensure templates exist in the image (copy from scripts dir if missing)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "${TEMP_DIR}/rootfs/root/kubeadm-init.yaml.tpl" ]]; then
    echo "Warning: kubeadm-init.yaml.tpl not found in image, copying from scripts directory"
    if [[ -f "$SCRIPT_DIR/kubeadm-init.yaml.tpl" ]]; then
        cp "$SCRIPT_DIR/kubeadm-init.yaml.tpl" "${TEMP_DIR}/rootfs/root/kubeadm-init.yaml.tpl"
        chmod 600 "${TEMP_DIR}/rootfs/root/kubeadm-init.yaml.tpl"
    else
        echo "Error: kubeadm-init.yaml.tpl not found in scripts directory either!" >&2
        exit 1
    fi
fi

if [[ ! -f "${TEMP_DIR}/rootfs/root/cilium-values.yaml.tpl" ]]; then
    echo "Warning: cilium-values.yaml.tpl not found in image, copying from scripts directory"
    if [[ -f "$SCRIPT_DIR/cilium-values.yaml.tpl" ]]; then
        cp "$SCRIPT_DIR/cilium-values.yaml.tpl" "${TEMP_DIR}/rootfs/root/cilium-values.yaml.tpl"
        chmod 600 "${TEMP_DIR}/rootfs/root/cilium-values.yaml.tpl"
    else
        echo "Error: cilium-values.yaml.tpl not found in scripts directory either!" >&2
        exit 1
    fi
fi

# Store network subnet configuration in plain text files
# Templates will use these values at runtime via envsubst
echo "$POD_SUBNET" > "${TEMP_DIR}/rootfs/root/pod-subnet"
echo "$SERVICE_SUBNET" > "${TEMP_DIR}/rootfs/root/service-subnet"

# Create FluxInstance resource
echo "Creating FluxInstance resource"
cat <<-EOF > "${TEMP_DIR}/rootfs/root/flux-instance.yaml"
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
    url: "$(cd "$(dirname "$0")/.." && git remote get-url origin 2>/dev/null || echo 'https://github.com/your-org/your-repo')"
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
      - patch: |
          - op: add
            path: /spec/template/spec/containers/0/args/-
            value: --concurrent=4
          - op: replace
            path: /spec/template/spec/volumes/0
            value:
              name: temp
              emptyDir:
                medium: Memory
        target:
          kind: Deployment
          name: kustomize-controller
EOF

# Configure firstboot service for the specific node type
echo "Configuring firstboot service for $NODE_TYPE"
cat > "${TEMP_DIR}/rootfs/etc/systemd/system/k8s-firstboot.service" << EOF
[Unit]
Description=Kubernetes First Boot Setup
After=network-online.target
Wants=network-online.target
Before=crio.service
ConditionPathExists=!/var/lib/k8s-firstboot-done

[Service]
Type=oneshot
ExecStart=/usr/bin/k8s-firstboot.sh
ExecStartPost=/usr/bin/touch /var/lib/k8s-firstboot-done
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Copy the appropriate template based on hostname and enable the service
echo "Creating appropriate bootstrap script for $NEW_HOSTNAME..."
if [[ "$NEW_HOSTNAME" == "controlplane" ]]; then
    # First control plane node
    cp "$(dirname "$0")/controlplane-template.sh" "${TEMP_DIR}/rootfs/usr/bin/k8s-firstboot.sh"
    # kubeadm-init.yaml.tpl is already copied above
elif [[ "$NEW_HOSTNAME" =~ ^controlplane[0-9]+$ ]]; then
    # Additional control plane nodes
    if [[ -f "$(dirname "$0")/controlplane-secondary-template.sh" ]]; then
        cp "$(dirname "$0")/controlplane-secondary-template.sh" "${TEMP_DIR}/rootfs/usr/bin/k8s-firstboot.sh"
    else
        echo "Warning: controlplane-secondary-template.sh not found, using controlplane template"
        cp "$(dirname "$0")/controlplane-template.sh" "${TEMP_DIR}/rootfs/usr/bin/k8s-firstboot.sh"
    fi
elif [[ "$NEW_HOSTNAME" =~ ^node[0-9]+$ ]]; then
    # Worker nodes
    if [[ -f "$(dirname "$0")/node-template.sh" ]]; then
        cp "$(dirname "$0")/node-template.sh" "${TEMP_DIR}/rootfs/usr/bin/k8s-firstboot.sh"
    else
        echo "Warning: node-template.sh not found, creating minimal bootstrap script"
        cat << 'NODESCRIPT' > "${TEMP_DIR}/rootfs/usr/bin/k8s-firstboot.sh"
#!/bin/bash
echo "Minimal node bootstrap - manual Kubernetes join required"
echo "To join cluster, get join command from controlplane and run it"
NODESCRIPT
    fi
else
    echo "Error: Unrecognized hostname pattern: $NEW_HOSTNAME" >&2
    exit 1
fi

# Make bootstrap script executable
chmod 755 "${TEMP_DIR}/rootfs/usr/bin/k8s-firstboot.sh"

# Set root-only permissions on /root/ files
chmod 600 "${TEMP_DIR}/rootfs/root"/* 2>/dev/null || true

# Enable the firstboot service
ln -sf "../k8s-firstboot.service" "${TEMP_DIR}/rootfs/etc/systemd/system/multi-user.target.wants/k8s-firstboot.service"

# Enable SSH service (if not already enabled)
echo "Ensuring SSH is enabled..."
if [[ ! -L "${TEMP_DIR}/rootfs/etc/systemd/system/multi-user.target.wants/ssh.service" ]] && \
   [[ ! -L "${TEMP_DIR}/rootfs/etc/systemd/system/sshd.service.wants/ssh.service" ]]; then
    echo "Enabling SSH service..."
    ln -sf "/lib/systemd/system/ssh.service" "${TEMP_DIR}/rootfs/etc/systemd/system/multi-user.target.wants/ssh.service"
fi

# Enable SSH via boot partition (Raspberry Pi OS standard method)
if [[ ! -f "$BOOT_DIR/ssh" ]]; then
    echo "Creating ssh file in boot partition..."
    touch "$BOOT_DIR/ssh"
fi

# Copy sops secret to root home dir (required)
echo "Copying SOPS age key"
cp "$SOPS_SECRET" "${TEMP_DIR}/rootfs/root/keys.txt"
chmod 600 "${TEMP_DIR}/rootfs/root/keys.txt"

# Update boot configuration with hostname
echo "Updating boot configuration"
if [[ -f "$BOOT_DIR/cmdline.txt" ]]; then
    if grep -q "console=" "$BOOT_DIR/cmdline.txt"; then
        # Add hostname to existing cmdline if not already present
        if ! grep -q "systemd.hostname=" "$BOOT_DIR/cmdline.txt"; then
            sed -i "s/rootwait/rootwait systemd.hostname=$NEW_HOSTNAME/" "$BOOT_DIR/cmdline.txt"
        fi
    fi
else
    echo "Warning: cmdline.txt not found at $BOOT_DIR/cmdline.txt"
fi

# Verify actions
SSH_KEY_VERIFIED="$(cat "${TEMP_DIR}/rootfs/home/pi/.ssh/authorized_keys")"
HOSTNAME_VERIFIED="$(cat "${TEMP_DIR}/rootfs/etc/hostname")"

echo "Configuration completed successfully!"
echo ""
echo "Image is now configured for $NODE_TYPE: $NEW_HOSTNAME"
echo "Hostname: $HOSTNAME_VERIFIED"
echo "SSH Key: ${SSH_KEY_VERIFIED:0:50}..."
echo ""
echo "Output image: $OUTPUT_FILE"
echo "You can now burn this image to your storage device and boot your Raspberry Pi 5"
echo ""
echo "Next steps:"
echo "1. Burn the image: sudo dd if=$OUTPUT_FILE of=/dev/YOUR_DEVICE bs=4M status=progress"
echo "2. Boot your Raspberry Pi 5"
echo "3. The system will automatically run the bootstrap script on first boot"

if [[ "$NODE_TYPE" == "controlplane" ]]; then
    echo "4. After bootstrap, copy kubeconfig: scp pi@$NEW_HOSTNAME:/home/pi/.kube/config ~/.kube/config"
    echo "5. Install Flux: flux bootstrap github --owner=YOUR_GITHUB_USER --repository=YOUR_REPO_NAME --branch=main --path=./kubernetes/rpi-cluster"
elif [[ "$NODE_TYPE" == "controlplane-secondary" ]]; then
    echo "4. The node will automatically join the existing cluster (if within certificate validity period)"
else
    echo "4. The node will automatically join the cluster (if within token validity period)"
fi
