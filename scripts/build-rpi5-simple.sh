#!/bin/bash
# build-rpi5-simple.sh - Simplified Raspberry Pi 5 image build with explicit QEMU
set -e

# Build configuration
BUILD_DIR="/build"
IMAGE_DIR="${BUILD_DIR}/image"
MOUNT_DIR="${BUILD_DIR}/mnt"
FIRMWARE_DIR="${BUILD_DIR}/firmware"
ROOTFS_DIR="${MOUNT_DIR}/rootfs"
BOOT_DIR="${MOUNT_DIR}/boot"

# Configuration from environment (with defaults)
IMAGE_NAME="${IMAGE_NAME:-rpi5-k8s-debian-simple}"
IMAGE_SIZE="${IMAGE_SIZE:-4G}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.33}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Cleanup function
cleanup() {
    log "Cleaning up on exit..."
    sudo umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    sudo umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    sudo umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    sudo umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
    sudo umount "${BOOT_DIR}" 2>/dev/null || true
    sudo umount "${ROOTFS_DIR}" 2>/dev/null || true
    if [ -n "$LOOP_DEVICE" ]; then
        sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
}

trap cleanup EXIT

log "Starting simplified Pi 5 build: ${IMAGE_NAME}.img"

# Create image file
log "Creating image file (${IMAGE_SIZE})"
cd "$IMAGE_DIR"
dd if=/dev/zero of="${IMAGE_NAME}.img" bs=1 count=0 seek="$IMAGE_SIZE" status=progress

# Setup loop device and partitions
log "Setting up partitions"
LOOP_DEVICE=$(sudo losetup --find --show "${IMAGE_NAME}.img")
sudo parted -s "$LOOP_DEVICE" mklabel msdos
sudo parted -s "$LOOP_DEVICE" mkpart primary fat32 1MiB 512MiB
sudo parted -s "$LOOP_DEVICE" mkpart primary ext4 512MiB 100%
sudo parted -s "$LOOP_DEVICE" set 1 boot on
sudo partprobe "$LOOP_DEVICE"
sleep 2

# Format partitions
log "Formatting partitions"
sudo mkfs.vfat -F 32 -n "BOOT" "${LOOP_DEVICE}p1"
sudo mkfs.ext4 -L "rootfs" "${LOOP_DEVICE}p2"

# Mount partitions
log "Mounting partitions"
mkdir -p "$BOOT_DIR" "$ROOTFS_DIR"
sudo mount "${LOOP_DEVICE}p2" "$ROOTFS_DIR"
sudo mount "${LOOP_DEVICE}p1" "$BOOT_DIR"

# First stage debootstrap (host architecture)
log "Running debootstrap first stage"
sudo debootstrap --arch arm64 --foreign \
    --include=ca-certificates,openssh-server,systemd,udev,locales,sudo \
    "$DEBIAN_RELEASE" "$ROOTFS_DIR" "$DEBIAN_MIRROR"

# Copy QEMU for second stage
log "Setting up QEMU for chroot"
sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"

# Second stage debootstrap (with explicit QEMU)
log "Running debootstrap second stage"
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "/debootstrap/debootstrap --second-stage"

# Mount virtual filesystems
log "Mounting virtual filesystems for chroot"
sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sysfs "$ROOTFS_DIR/sys"
sudo mount -o bind /dev "$ROOTFS_DIR/dev"
sudo mount -o bind /dev/pts "$ROOTFS_DIR/dev/pts"

# Basic system configuration
log "Configuring basic system"
echo "rpi5-debian" | sudo tee "$ROOTFS_DIR/etc/hostname" > /dev/null

cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/hosts" > /dev/null
127.0.0.1	localhost
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
127.0.1.1	rpi5-debian
EOF

cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/fstab" > /dev/null
LABEL=rootfs    /               ext4    defaults,noatime  0       1
LABEL=BOOT      /boot/firmware  vfat    defaults          0       2
EOF

# Configure APT sources
cat << EOF | sudo tee "$ROOTFS_DIR/etc/apt/sources.list" > /dev/null
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free-firmware
deb $DEBIAN_MIRROR-security $DEBIAN_RELEASE-security main contrib non-free-firmware
deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main contrib non-free-firmware
EOF

# Configure locale
echo "en_US.UTF-8 UTF-8" | sudo tee "$ROOTFS_DIR/etc/locale.gen" > /dev/null
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "locale-gen"

# Update package lists and install essentials
log "Installing essential packages"
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "apt-get update"
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
    apt-get install -y vim git curl gpg software-properties-common gettext-base
"

# Create pi user
log "Creating pi user"
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
    useradd -m -s /bin/bash -G sudo pi
    echo 'pi ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_pi-nopasswd
    mkdir -p /home/pi/.ssh
    chmod 700 /home/pi/.ssh
    chown pi:pi /home/pi/.ssh
"

# Configure SSH
log "Configuring SSH"
sudo mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/ssh/sshd_config.d/pi5-security.conf" > /dev/null
# Security settings for Kubernetes nodes
PermitRootLogin no
PasswordAuthentication no
AllowUsers pi
EOF

sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "systemctl enable ssh"

# Install Kubernetes
log "Installing Kubernetes $KUBERNETES_VERSION"
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
"

# Kernel parameters for Kubernetes
cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/sysctl.d/k8s.conf" > /dev/null
# Kubernetes required settings
net.ipv4.ip_forward = 1
EOF

# Install Pi 5 firmware
log "Installing Pi 5 firmware"
sudo cp -r "$FIRMWARE_DIR/boot"/* "$BOOT_DIR/"

# Verify critical Pi 5 files
if [ ! -f "$BOOT_DIR/bcm2712-rpi-5-b.dtb" ]; then
    log "ERROR: Pi 5 device tree not found!"
    exit 1
fi

if [ ! -f "$BOOT_DIR/kernel_2712.img" ]; then
    log "ERROR: Pi 5 kernel not found!"
    exit 1
fi

# Create Pi 5 config.txt
cat << 'EOF' | sudo tee "$BOOT_DIR/config.txt" > /dev/null
# Raspberry Pi 5 Configuration
arm_64bit=1
kernel=kernel_2712.img
device_tree=bcm2712-rpi-5-b.dtb

# Memory
gpu_mem=128

# Enable UART (for debugging)
enable_uart=1

# Overclock (conservative)
arm_freq=2400

# USB settings
max_usb_current=1

# Auto-detect hardware
camera_auto_detect=1
display_auto_detect=1

# Boot delay for USB devices
boot_delay=1
EOF

# Create cmdline.txt
echo "console=serial0,115200 console=tty1 root=LABEL=rootfs rootfstype=ext4 fsck.repair=yes rootwait cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory" | sudo tee "$BOOT_DIR/cmdline.txt" > /dev/null

# Copy bootstrap scripts if available
log "Setting up bootstrap scripts"
if [ -f "$WORKSPACE/scripts/controlplane-template.sh" ]; then
    sudo cp "$WORKSPACE/scripts/controlplane-template.sh" "$ROOTFS_DIR/root/bootstrap-controlplane.sh"
    log "✓ Copied controlplane bootstrap script"
else
    log "⚠ Creating minimal bootstrap script"
    cat << 'EOF' | sudo tee "$ROOTFS_DIR/root/bootstrap-controlplane.sh" > /dev/null
#!/bin/bash
echo "Minimal bootstrap - manual Kubernetes setup required"
echo "To initialize cluster, run:"
echo "  kubeadm init --pod-network-cidr=10.244.0.0/16"
echo "  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/calico.yaml"
EOF
fi

if [ -f "$WORKSPACE/scripts/kubeadm-init.yaml.tpl" ]; then
    sudo cp "$WORKSPACE/scripts/kubeadm-init.yaml.tpl" "$ROOTFS_DIR/root/"
    log "✓ Copied kubeadm template"
fi

sudo chmod +x "$ROOTFS_DIR/root/bootstrap-controlplane.sh"

# Generate bootstrap tokens
log "Generating bootstrap tokens"
tr -dc 'a-f0-9' < /dev/urandom | head -c 6 > /tmp/token1
tr -dc 'a-f0-9' < /dev/urandom | head -c 16 > /tmp/token2
echo "$(cat /tmp/token1).$(cat /tmp/token2)" | sudo tee "$ROOTFS_DIR/root/kubeadm-init-token" > /dev/null
rm -f /tmp/token1 /tmp/token2

tr -dc 'a-f0-9' < /dev/urandom | head -c 64 | sudo tee "$ROOTFS_DIR/root/kubeadm-cert-key" > /dev/null

# Create boot/firmware directory
sudo mkdir -p "$ROOTFS_DIR/boot/firmware"

# Final cleanup in chroot
log "Cleaning up rootfs"
sudo chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "apt-get clean"
sudo rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

log "Build completed successfully!"
log "Image: $IMAGE_DIR/${IMAGE_NAME}.img"
ls -lh "$IMAGE_DIR/${IMAGE_NAME}.img"