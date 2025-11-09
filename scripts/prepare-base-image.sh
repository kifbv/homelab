#!/bin/bash
# prepare-base-image.sh - Prepare Raspberry Pi OS base image with Kubernetes packages
# This script downloads the official Raspberry Pi OS Lite image and installs all required
# Kubernetes components via chroot, creating a ready-to-use base image.

set -e

# Configuration
DEFAULT_INPUT_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-10-02/2025-10-01-raspios-trixie-arm64-lite.img.xz"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.33}"
CRIO_VERSION="${CRIO_VERSION:-v1.33}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Prepare a Raspberry Pi OS base image with Kubernetes packages pre-installed.

Options:
  --input URL or PATH   Input image URL to download or local file path
                        Default: Official Raspberry Pi OS Lite (Trixie ARM64)
  --output PATH         Output image file path
                        Default: rpi5-k8s-base.img
  --k8s-version VER     Kubernetes version to install (e.g., v1.33)
                        Default: $KUBERNETES_VERSION
  --skip-download       Skip download if input is a local file
  --help                Show this help message

Example:
  # Download and prepare base image
  sudo $0 --output rpi5-k8s-base.img

  # Use existing image file
  sudo $0 --input raspios-lite.img.xz --output rpi5-k8s-base.img --skip-download

EOF
}

# Check if script is run as root
if [[ "$(id -u)" -ne 0 ]]; then
    error "This script must be run as root"
    exit 1
fi

# Parse arguments
INPUT="$DEFAULT_INPUT_URL"
OUTPUT="rpi5-k8s-base.img"
SKIP_DOWNLOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)
            INPUT="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --k8s-version)
            KUBERNETES_VERSION="$2"
            shift 2
            ;;
        --skip-download)
            SKIP_DOWNLOAD=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Create temporary working directory
WORK_DIR=$(mktemp -d)
MOUNT_DIR="${WORK_DIR}/mnt"
LOOP_DEVICE=""

# Cleanup function
cleanup() {
    log "Cleaning up..."

    # Unmount chroot mounts
    umount "${MOUNT_DIR}/proc" 2>/dev/null || true
    umount "${MOUNT_DIR}/sys" 2>/dev/null || true
    umount "${MOUNT_DIR}/dev/pts" 2>/dev/null || true
    umount "${MOUNT_DIR}/dev" 2>/dev/null || true

    # Remove QEMU binary
    rm -f "${MOUNT_DIR}/usr/bin/qemu-aarch64-static" 2>/dev/null || true

    # Unmount partitions
    umount "${MOUNT_DIR}/boot/firmware" 2>/dev/null || true
    umount "${MOUNT_DIR}" 2>/dev/null || true

    # Detach loop device
    if [[ -n "$LOOP_DEVICE" ]]; then
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi

    # Remove temp directory
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

log "Starting Raspberry Pi OS base image preparation"
log "Kubernetes version: $KUBERNETES_VERSION"
log "Output image: $OUTPUT"

# Step 1: Download or locate the image
if [[ "$INPUT" =~ ^https?:// ]]; then
    if [[ "$SKIP_DOWNLOAD" == "false" ]]; then
        log "Downloading Raspberry Pi OS image..."
        DOWNLOADED_FILE="${WORK_DIR}/$(basename "$INPUT")"
        wget -O "$DOWNLOADED_FILE" "$INPUT"
        INPUT="$DOWNLOADED_FILE"
    else
        error "Cannot skip download when input is a URL"
        exit 1
    fi
else
    if [[ ! -f "$INPUT" ]]; then
        error "Input file not found: $INPUT"
        exit 1
    fi
    log "Using existing image: $INPUT"
fi

# Step 2: Extract the image if compressed
log "Extracting image..."
EXTRACTED_IMG="${WORK_DIR}/source.img"

if [[ "$INPUT" == *.xz ]]; then
    log "Decompressing XZ archive..."
    xz -dc "$INPUT" > "$EXTRACTED_IMG"
elif [[ "$INPUT" == *.gz ]]; then
    log "Decompressing GZ archive..."
    gunzip -c "$INPUT" > "$EXTRACTED_IMG"
elif [[ "$INPUT" == *.img ]]; then
    log "Copying uncompressed image..."
    cp "$INPUT" "$EXTRACTED_IMG"
else
    error "Unsupported image format. Use .img, .img.xz, or .img.gz"
    exit 1
fi

# Step 3: Expand the image to have more space for packages
log "Expanding image to add space for Kubernetes packages..."
CURRENT_SIZE=$(stat -c%s "$EXTRACTED_IMG")
ADDITIONAL_SPACE=$((2 * 1024 * 1024 * 1024))  # Add 2GB
NEW_SIZE=$((CURRENT_SIZE + ADDITIONAL_SPACE))
truncate -s "$NEW_SIZE" "$EXTRACTED_IMG"

# Step 4: Mount the image
log "Mounting image..."
LOOP_DEVICE=$(losetup --find --show --partscan "$EXTRACTED_IMG")
log "Loop device: $LOOP_DEVICE"

# Wait for partitions to appear
sleep 2
partprobe "$LOOP_DEVICE" 2>/dev/null || true
sleep 2

# Find the root partition (usually p2)
ROOT_PARTITION="${LOOP_DEVICE}p2"
BOOT_PARTITION="${LOOP_DEVICE}p1"

if [[ ! -b "$ROOT_PARTITION" ]]; then
    error "Root partition not found: $ROOT_PARTITION"
    exit 1
fi

# Expand the root partition
log "Expanding root partition..."
parted "$LOOP_DEVICE" resizepart 2 100% || warn "Could not resize partition, continuing anyway"
e2fsck -f -y "$ROOT_PARTITION" || true
resize2fs "$ROOT_PARTITION" || warn "Could not resize filesystem, continuing anyway"

# Mount root filesystem
mkdir -p "$MOUNT_DIR"
mount "$ROOT_PARTITION" "$MOUNT_DIR"

# Mount boot partition
if [[ -d "${MOUNT_DIR}/boot/firmware" ]]; then
    mount "$BOOT_PARTITION" "${MOUNT_DIR}/boot/firmware"
elif [[ -d "${MOUNT_DIR}/boot" ]]; then
    mount "$BOOT_PARTITION" "${MOUNT_DIR}/boot"
else
    warn "Could not find boot mount point"
fi

log "Image mounted successfully at $MOUNT_DIR"

# Step 5: Set up QEMU for chroot
log "Setting up QEMU for ARM64 emulation..."
if [[ ! -f /usr/bin/qemu-aarch64-static ]]; then
    error "qemu-user-static not found. Install with: apt-get install qemu-user-static"
    exit 1
fi

cp /usr/bin/qemu-aarch64-static "${MOUNT_DIR}/usr/bin/"

# Mount virtual filesystems
log "Mounting virtual filesystems..."
mount -t proc proc "${MOUNT_DIR}/proc"
mount -t sysfs sysfs "${MOUNT_DIR}/sys"
mount -o bind /dev "${MOUNT_DIR}/dev"
mount -o bind /dev/pts "${MOUNT_DIR}/dev/pts"

# Step 6: Install Kubernetes packages in chroot
log "Installing Kubernetes packages in chroot..."

# Create installation script
cat > "${MOUNT_DIR}/tmp/install-k8s.sh" << 'INSTALL_SCRIPT'
#!/bin/bash
set -e

echo "[INFO] Updating package lists..."
apt-get update

echo "[INFO] Installing prerequisites..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    gettext-base

echo "[INFO] Adding Kubernetes repository..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list

echo "[INFO] Installing Kubernetes packages..."
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "[INFO] Adding CRI-O repository..."
curl -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key | \
    gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | \
    tee /etc/apt/sources.list.d/cri-o.list

echo "[INFO] Installing CRI-O..."
apt-get update
apt-get install -y cri-o

echo "[INFO] Enabling CRI-O service..."
systemctl enable crio

echo "[INFO] Configuring kernel modules..."
cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF

echo "[INFO] Configuring sysctl for Kubernetes..."
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

echo "[INFO] Installing additional useful packages..."
apt-get install -y \
    vim \
    git \
    curl \
    wget \
    htop \
    jq \
    net-tools \
    iputils-ping \
    dnsutils \
    nvme-cli

echo "[INFO] Installing Helm..."
curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor -o /etc/apt/keyrings/helm-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/helm-apt-keyring.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
    tee /etc/apt/sources.list.d/helm.list
apt-get update
apt-get install -y helm

echo "[INFO] Cleaning up..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[INFO] Kubernetes installation complete!"
INSTALL_SCRIPT

chmod +x "${MOUNT_DIR}/tmp/install-k8s.sh"

# Export variables and run installation script
log "Running installation script (this may take 10-15 minutes)..."
chroot "$MOUNT_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
    export KUBERNETES_VERSION='$KUBERNETES_VERSION'
    export CRIO_VERSION='$CRIO_VERSION'
    /tmp/install-k8s.sh
"

# Step 7: Additional configuration
log "Applying additional configuration..."

# Ensure pi user exists (should already exist in Raspberry Pi OS)
if ! chroot "$MOUNT_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "id pi" &>/dev/null; then
    warn "pi user not found, creating it..."
    chroot "$MOUNT_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
        useradd -m -s /bin/bash -G sudo pi
        echo 'pi ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_pi-nopasswd
        chmod 0440 /etc/sudoers.d/010_pi-nopasswd
    "
fi

# Create necessary directories
chroot "$MOUNT_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
    mkdir -p /home/pi/.ssh /home/pi/.kube /root/kubeadm
    chmod 700 /home/pi/.ssh /home/pi/.kube
    chown -R pi:pi /home/pi/.ssh /home/pi/.kube
"

# Disable swap (required for Kubernetes)
log "Disabling swap..."
sed -i '/swap/d' "${MOUNT_DIR}/etc/fstab" || true

# Copy Kubernetes configuration templates
log "Installing Kubernetes configuration templates..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/kubeadm-init.yaml.tpl" ]]; then
    cp "$SCRIPT_DIR/kubeadm-init.yaml.tpl" "${MOUNT_DIR}/root/kubeadm-init.yaml.tpl"
    chmod 600 "${MOUNT_DIR}/root/kubeadm-init.yaml.tpl"
    log "✓ Copied kubeadm-init.yaml.tpl"
else
    warn "kubeadm-init.yaml.tpl not found at $SCRIPT_DIR"
fi

if [[ -f "$SCRIPT_DIR/cilium-values.yaml.tpl" ]]; then
    cp "$SCRIPT_DIR/cilium-values.yaml.tpl" "${MOUNT_DIR}/root/cilium-values.yaml.tpl"
    chmod 600 "${MOUNT_DIR}/root/cilium-values.yaml.tpl"
    log "✓ Copied cilium-values.yaml.tpl"
else
    warn "cilium-values.yaml.tpl not found at $SCRIPT_DIR"
fi

# Enable required services
log "Configuring services..."
chroot "$MOUNT_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
    systemctl enable kubelet
    systemctl enable crio
    systemctl enable ssh
"

# Enable SSH via boot partition method (Raspberry Pi OS standard)
log "Enabling SSH via boot partition..."
if [[ -d "${MOUNT_DIR}/boot/firmware" ]]; then
    touch "${MOUNT_DIR}/boot/firmware/ssh"
    log "✓ Created ssh file in boot partition"
elif [[ -d "${MOUNT_DIR}/boot" ]]; then
    touch "${MOUNT_DIR}/boot/ssh"
    log "✓ Created ssh file in boot partition"
fi

# Step 8: Clean up chroot environment
log "Cleaning up chroot environment..."
rm -f "${MOUNT_DIR}/tmp/install-k8s.sh"
rm -f "${MOUNT_DIR}/usr/bin/qemu-aarch64-static"

# Unmount everything
log "Unmounting filesystems..."
umount "${MOUNT_DIR}/proc"
umount "${MOUNT_DIR}/sys"
umount "${MOUNT_DIR}/dev/pts"
umount "${MOUNT_DIR}/dev"

if mountpoint -q "${MOUNT_DIR}/boot/firmware"; then
    umount "${MOUNT_DIR}/boot/firmware"
elif mountpoint -q "${MOUNT_DIR}/boot"; then
    umount "${MOUNT_DIR}/boot"
fi

umount "${MOUNT_DIR}"

# Detach loop device
losetup -d "$LOOP_DEVICE"
LOOP_DEVICE=""

# Step 9: Shrink the image back to reasonable size
log "Optimizing image size..."
# Truncate to remove unused space, keeping a reasonable buffer
e2fsck -f -y "$ROOT_PARTITION" 2>/dev/null || true

# Copy to final output location
log "Copying to output location: $OUTPUT"
cp "$EXTRACTED_IMG" "$OUTPUT"
chmod 644 "$OUTPUT"

# Get final size
FINAL_SIZE=$(du -h "$OUTPUT" | cut -f1)
log "Base image preparation complete!"
log "Output image: $OUTPUT"
log "Image size: $FINAL_SIZE"
echo ""
log "The base image is now ready. Use configure-rpi5-image.sh to customize it per-node."
