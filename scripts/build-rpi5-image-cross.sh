#!/bin/bash
# build-rpi5-image-cross.sh - Build minimal Debian image for Raspberry Pi 5 using cross-compilation
# This script creates a bootable Debian image with Kubernetes components using QEMU emulation

set -e

# Configuration
BUILD_DIR="/build"
IMAGE_DIR="${BUILD_DIR}/image"
MOUNT_DIR="${BUILD_DIR}/mnt"
FIRMWARE_DIR="${BUILD_DIR}/firmware"
ROOTFS_DIR="${MOUNT_DIR}/rootfs"
BOOT_DIR="${MOUNT_DIR}/boot"
LOG_FILE="${BUILD_DIR}/build.log"

# Image settings
IMAGE_NAME="${IMAGE_NAME:-rpi5-k8s-debian-cross}"
IMAGE_SIZE="${IMAGE_SIZE:-4G}"
DEBIAN_RELEASE="${DEBIAN_RELEASE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"

# Cross-compilation settings
TARGET_ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"
QEMU_STATIC="/usr/bin/qemu-aarch64-static"

# Kubernetes settings
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.33}"
CRIO_VERSION="${KUBERNETES_VERSION}"
POD_SUBNET="${POD_SUBNET:-10.244.64.0/18}"
SERVICE_SUBNET="${SERVICE_SUBNET:-10.244.0.0/20}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling
cleanup() {
    log "Cleaning up on exit..."
    
    # Unmount everything in reverse order
    sudo umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
    sudo umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
    sudo umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    sudo umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
    sudo umount "${BOOT_DIR}" 2>/dev/null || true
    sudo umount "${ROOTFS_DIR}" 2>/dev/null || true
    
    # Detach loop device
    if [ -n "$LOOP_DEVICE" ]; then
        sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Verify cross-compilation environment
verify_cross_env() {
    log "Verifying cross-compilation environment"
    
    # Check QEMU static
    if [ ! -f "$QEMU_STATIC" ]; then
        log "ERROR: QEMU static binary not found: $QEMU_STATIC"
        exit 1
    fi
    
    # Check cross-compiler
    if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
        log "ERROR: Cross-compiler not found: ${CROSS_COMPILE}gcc"
        exit 1
    fi
    
    # Test QEMU functionality
    log "Testing QEMU ARM64 emulation"
    $QEMU_STATIC --version | head -1
    
    # Test cross-compiler
    log "Testing cross-compiler"
    echo 'int main(){return 0;}' | "${CROSS_COMPILE}gcc" -x c -o /tmp/test_cross -
    file /tmp/test_cross
    rm -f /tmp/test_cross
    
    log "Cross-compilation environment verified"
}

# Create image file
create_image() {
    log "Creating image file: ${IMAGE_NAME}.img (${IMAGE_SIZE})"
    
    cd "$IMAGE_DIR"
    dd if=/dev/zero of="${IMAGE_NAME}.img" bs=1 count=0 seek="$IMAGE_SIZE" status=progress
    
    # Create loop device
    LOOP_DEVICE=$(sudo losetup --find --show "${IMAGE_NAME}.img")
    log "Created loop device: $LOOP_DEVICE"
    
    # Create partition table
    log "Creating partition table"
    sudo parted -s "$LOOP_DEVICE" mklabel msdos
    sudo parted -s "$LOOP_DEVICE" mkpart primary fat32 1MiB 512MiB
    sudo parted -s "$LOOP_DEVICE" mkpart primary ext4 512MiB 100%
    sudo parted -s "$LOOP_DEVICE" set 1 boot on
    
    # Wait for partitions
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
}

# Create base Debian system with cross-compilation
create_rootfs() {
    log "Creating Debian $DEBIAN_RELEASE rootfs with debootstrap (cross-compilation)"
    
    # First stage debootstrap (download and extract packages)
    log "Running debootstrap first stage"
    sudo debootstrap --arch $TARGET_ARCH --foreign \
        --include=ca-certificates,openssh-server,systemd,udev,locales \
        "$DEBIAN_RELEASE" "$ROOTFS_DIR" "$DEBIAN_MIRROR"
    
    # Copy QEMU static for chroot emulation
    sudo cp "$QEMU_STATIC" "$ROOTFS_DIR/usr/bin/"
    
    # Second stage debootstrap (configure packages)
    log "Running debootstrap second stage"
    sudo chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
    
    # Mount virtual filesystems for chroot
    sudo mount -t proc proc "$ROOTFS_DIR/proc"
    sudo mount -t sysfs sysfs "$ROOTFS_DIR/sys"
    sudo mount -o bind /dev "$ROOTFS_DIR/dev"
    sudo mount -o bind /dev/pts "$ROOTFS_DIR/dev/pts"
    
    # Configure basic system
    configure_system
    
    # Install and configure Kubernetes
    install_kubernetes
    
    # Configure users and security
    configure_security
    
    # Install bootloader and firmware
    install_bootloader
    
    # Clean up
    sudo rm "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
}

# Configure basic system settings
configure_system() {
    log "Configuring basic system settings"
    
    # Set hostname placeholder
    echo "rpi5-debian" | sudo tee "$ROOTFS_DIR/etc/hostname" > /dev/null
    
    # Configure hosts file
    cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/hosts" > /dev/null
127.0.0.1	localhost
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
127.0.1.1	rpi5-debian
EOF

    # Configure fstab
    cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/fstab" > /dev/null
LABEL=rootfs    /               ext4    defaults,noatime  0       1
LABEL=BOOT      /boot/firmware  vfat    defaults          0       2
EOF

    # Configure APT sources
    cat << EOF | sudo tee "$ROOTFS_DIR/etc/apt/sources.list" > /dev/null
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free-firmware
deb-src $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free-firmware

deb $DEBIAN_MIRROR-security $DEBIAN_RELEASE-security main contrib non-free-firmware
deb-src $DEBIAN_MIRROR-security $DEBIAN_RELEASE-security main contrib non-free-firmware

deb $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main contrib non-free-firmware
deb-src $DEBIAN_MIRROR $DEBIAN_RELEASE-updates main contrib non-free-firmware
EOF

    # Configure locale
    echo "en_US.UTF-8 UTF-8" | sudo tee "$ROOTFS_DIR/etc/locale.gen" > /dev/null
    sudo chroot "$ROOTFS_DIR" locale-gen
    echo "LANG=en_US.UTF-8" | sudo tee "$ROOTFS_DIR/etc/default/locale" > /dev/null
    
    # Set timezone to UTC
    sudo chroot "$ROOTFS_DIR" ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    
    # Update package lists
    log "Updating package lists in chroot"
    sudo chroot "$ROOTFS_DIR" apt-get update
    
    # Install essential packages
    log "Installing essential packages"
    sudo chroot "$ROOTFS_DIR" apt-get install -y \
        apt-transport-https ca-certificates curl gpg software-properties-common \
        vim git gettext-base nvme-cli systemd-timesyncd sudo \
        firmware-brcm80211 wireless-regdb crda \
        dbus-user-session
}

# Install Kubernetes components with cross-compilation
install_kubernetes() {
    log "Installing Kubernetes $KUBERNETES_VERSION and CRI-O $CRIO_VERSION"
    
    # Create keyring directory
    sudo chroot "$ROOTFS_DIR" mkdir -p /etc/apt/keyrings
    
    # Add Kubernetes repository keys and sources
    log "Adding Kubernetes repositories"
    sudo chroot "$ROOTFS_DIR" bash -c "
        curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | \
        gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        
        curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key | \
        gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
        
        curl -fsSL https://baltocdn.com/helm/signing.asc | \
        gpg --dearmor -o /etc/apt/keyrings/helm.gpg
    "
    
    # Add repository sources
    cat << EOF | sudo tee "$ROOTFS_DIR/etc/apt/sources.list.d/kubernetes.list" > /dev/null
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /
EOF

    cat << EOF | sudo tee "$ROOTFS_DIR/etc/apt/sources.list.d/cri-o.list" > /dev/null
deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /
EOF

    cat << EOF | sudo tee "$ROOTFS_DIR/etc/apt/sources.list.d/helm-stable-debian.list" > /dev/null
deb [arch=arm64 signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main
EOF

    # Update and install Kubernetes components
    log "Installing Kubernetes components"
    sudo chroot "$ROOTFS_DIR" apt-get update
    
    # Install in stages to handle any dependency issues
    sudo chroot "$ROOTFS_DIR" apt-get install -y cri-o
    sudo chroot "$ROOTFS_DIR" apt-get install -y kubelet kubeadm kubectl
    sudo chroot "$ROOTFS_DIR" apt-get install -y helm
    
    # Pin versions to prevent accidental upgrades
    sudo chroot "$ROOTFS_DIR" apt-mark hold kubelet kubeadm kubectl cri-o
    
    # Configure Kubernetes
    configure_kubernetes
}

# Configure Kubernetes settings
configure_kubernetes() {
    log "Configuring Kubernetes settings"
    
    # Kernel parameters for Kubernetes
    cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/sysctl.d/k8s.conf" > /dev/null
# Kubernetes required settings
net.ipv4.ip_forward = 1
EOF

    # Disable swap (if present)
    sudo chroot "$ROOTFS_DIR" systemctl mask swap.target
    
    # Enable CRI-O
    sudo chroot "$ROOTFS_DIR" systemctl enable crio
    
    # Configure kubelet for server TLS bootstrap
    sudo mkdir -p "$ROOTFS_DIR/etc/systemd/system/kubelet.service.d"
    cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/systemd/system/kubelet.service.d/20-server-tls-bootstrap.conf" > /dev/null
[Service]
Environment="KUBELET_EXTRA_ARGS=--rotate-server-certificates=true"
EOF

    # Configure CRI-O for Kubernetes
    sudo mkdir -p "$ROOTFS_DIR/etc/crio/crio.conf.d"
    cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/crio/crio.conf.d/02-cgroup-manager.conf" > /dev/null
[crio.runtime]
cgroup_manager = "systemd"
EOF
}

# Configure users and security
configure_security() {
    log "Configuring security and users"
    
    # Create pi user
    sudo chroot "$ROOTFS_DIR" useradd -m -s /bin/bash -G sudo pi
    
    # Configure sudo without password for pi user (will be changed by configure script)
    echo "pi ALL=(ALL) NOPASSWD:ALL" | sudo tee "$ROOTFS_DIR/etc/sudoers.d/010_pi-nopasswd" > /dev/null
    
    # Configure SSH
    sudo mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
    cat << 'EOF' | sudo tee "$ROOTFS_DIR/etc/ssh/sshd_config.d/pi5-security.conf" > /dev/null
# Security settings for Kubernetes nodes
PermitRootLogin no
PasswordAuthentication no
AllowUsers pi
EOF

    # Enable SSH service
    sudo chroot "$ROOTFS_DIR" systemctl enable ssh
    
    # Enable systemd-timesyncd
    sudo chroot "$ROOTFS_DIR" systemctl enable systemd-timesyncd
    
    # Create .ssh directory for pi user
    sudo mkdir -p "$ROOTFS_DIR/home/pi/.ssh"
    sudo chmod 700 "$ROOTFS_DIR/home/pi/.ssh"
    sudo chown 1000:1000 "$ROOTFS_DIR/home/pi/.ssh"
}

# Install bootloader and firmware
install_bootloader() {
    log "Installing Raspberry Pi 5 firmware and bootloader"
    
    # Copy firmware files
    sudo cp -r "$FIRMWARE_DIR/boot"/* "$BOOT_DIR/"
    
    # Create minimal config.txt for Pi 5
    cat << 'EOF' | sudo tee "$BOOT_DIR/config.txt" > /dev/null
# Raspberry Pi 5 Configuration
arm_64bit=1
kernel=kernel_2712.img
device_tree=bcm2712-rpi-5-b.dtb

# Memory
gpu_mem=128

# Enable UART (optional, for debugging)
enable_uart=1

# Overclock settings (conservative)
arm_freq=2400

# USB settings
max_usb_current=1

# Camera (if needed)
camera_auto_detect=1

# Display (if needed)
display_auto_detect=1

# Boot delay for USB devices
boot_delay=1
EOF

    # Create cmdline.txt
    cat << EOF | sudo tee "$BOOT_DIR/cmdline.txt" > /dev/null
console=serial0,115200 console=tty1 root=LABEL=rootfs rootfstype=ext4 fsck.repair=yes rootwait cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory
EOF

    # Ensure Pi 5 specific files are present
    if [ ! -f "$BOOT_DIR/bcm2712-rpi-5-b.dtb" ]; then
        log "ERROR: Pi 5 device tree not found in firmware"
        exit 1
    fi
    
    if [ ! -f "$BOOT_DIR/kernel_2712.img" ]; then
        log "ERROR: Pi 5 kernel not found in firmware"
        exit 1
    fi
    
    log "Pi 5 firmware installation completed"
}

# Copy configuration and bootstrap scripts
copy_scripts() {
    log "Copying configuration and bootstrap scripts"
    
    # Copy kubeadm templates
    sudo cp scripts/kubeadm-init.yaml.tpl "$ROOTFS_DIR/root/"
    sudo cp scripts/cilium-values.yaml.tpl "$ROOTFS_DIR/root/"
    
    # Copy bootstrap scripts
    sudo cp scripts/controlplane-template.sh "$ROOTFS_DIR/root/bootstrap-controlplane.sh"
    sudo cp scripts/controlplane-secondary-template.sh "$ROOTFS_DIR/root/bootstrap-controlplane-secondary.sh"
    sudo cp scripts/node-template.sh "$ROOTFS_DIR/root/bootstrap-node.sh"
    
    # Copy firstboot service
    sudo cp userpatches/overlay/k8s-firstboot.service "$ROOTFS_DIR/usr/lib/systemd/system/"
    
    # Create tokens and keys
    tr -dc 'a-f0-9' < /dev/urandom | head -c 6 > /tmp/token_part1
    tr -dc 'a-f0-9' < /dev/urandom | head -c 16 > /tmp/token_part2
    echo "$(cat /tmp/token_part1).$(cat /tmp/token_part2)" | sudo tee "$ROOTFS_DIR/root/kubeadm-init-token" > /dev/null
    rm -f /tmp/token_part1 /tmp/token_part2
    
    tr -dc 'a-f0-9' < /dev/urandom | head -c 64 | sudo tee "$ROOTFS_DIR/root/kubeadm-cert-key" > /dev/null
    
    # Make scripts executable
    sudo chmod +x "$ROOTFS_DIR/root/bootstrap-"*.sh
    
    log "Scripts and configuration copied successfully"
}

# Final system configuration
finalize_system() {
    log "Finalizing system configuration"
    
    # Clean package cache
    sudo chroot "$ROOTFS_DIR" apt-get clean
    
    # Remove temporary files
    sudo rm -rf "$ROOTFS_DIR/tmp/"* || true
    sudo rm -rf "$ROOTFS_DIR/var/tmp/"* || true
    
    # Create boot/firmware directory
    sudo mkdir -p "$ROOTFS_DIR/boot/firmware"
    
    log "System finalization completed"
}

# Main execution
main() {
    log "Starting Raspberry Pi 5 image build (cross-compilation)"
    log "Image: $IMAGE_NAME, Size: $IMAGE_SIZE"
    log "Debian: $DEBIAN_RELEASE, Kubernetes: $KUBERNETES_VERSION"
    log "Cross-compilation: $TARGET_ARCH with QEMU emulation"
    
    # Create log file
    touch "$LOG_FILE"
    
    verify_cross_env
    create_image
    create_rootfs
    copy_scripts
    finalize_system
    
    log "Image build completed successfully!"
    log "Image location: $IMAGE_DIR/${IMAGE_NAME}.img"
    log "Log file: $LOG_FILE"
    
    # Final image info
    cd "$IMAGE_DIR"
    log "Final image size: $(stat -c%s "${IMAGE_NAME}.img" | numfmt --to=iec)"
    log "Disk usage: $(du -h "${IMAGE_NAME}.img" | awk '{print $1}')"
}

# Run main function
main "$@"