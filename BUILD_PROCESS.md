# Raspberry Pi 5 Image Build Process

This document describes the new custom build process for creating minimal Debian images for Raspberry Pi 5 with Kubernetes components.

## Overview

The new build system replaces the Armbian-based workflow with a direct Debian debootstrap approach, providing:

- **Minimal footprint**: Only essential packages for Kubernetes deployment
- **Native ARM64**: Built directly for Raspberry Pi 5's BCM2712 architecture  
- **Custom configuration**: Tailored for homelab Kubernetes clusters
- **GitHub Actions**: Automated builds on ubuntu-24.04-arm64 runners

## Build Components

### 1. GitHub Workflow (`.github/workflows/build-rpi5-image.yml`)
- Triggers on push to main or manual dispatch
- Uses ubuntu-24.04-arm64 runners (no special hardware needed)
- Builds images with configurable Kubernetes versions and network settings
- Produces compressed images with checksums
- Creates GitHub releases automatically

### 2. Build Script (`scripts/build-rpi5-image.sh`)
- Creates bootable image file with proper partitioning
- Uses debootstrap to create minimal Debian Bookworm ARM64 rootfs
- Installs Kubernetes components (kubelet, kubeadm, kubectl, CRI-O)
- Configures Pi 5 firmware and bootloader
- Sets up bootstrap services for automatic cluster joining

### 3. Configuration Script (`scripts/configure-rpi5-image.sh`)
- Configures images for specific nodes (controlplane, controlplane1, node0, etc.)
- Sets hostname, SSH keys, and user passwords
- Enables appropriate bootstrap scripts based on node type
- Copies SOPS encryption keys for GitOps

### 4. Bootstrap Scripts (`scripts/*-template.sh`)
- **controlplane-template.sh**: Initializes the first control plane node
- **controlplane-secondary-template.sh**: Joins additional control plane nodes
- **node-template.sh**: Joins worker nodes
- All scripts support automatic cluster joining with time-limited tokens

## Usage

### Building Images

#### Manual Build (GitHub Actions)
1. Go to Actions tab in your repository
2. Select "Build Raspberry Pi 5 Debian Image"  
3. Click "Run workflow"
4. Configure parameters:
   - Image name (default: rpi5-k8s-debian)
   - Kubernetes version (default: v1.33)
   - Pod subnet (default: 10.244.64.0/18)
   - Service subnet (default: 10.244.0.0/20)
5. Download artifacts from the completed workflow

#### Automatic Build
Images are built automatically on push to main branch when scripts are modified.

### Configuring Images

After downloading a built image:

```bash
# Example: Configure for control plane
sudo ./scripts/configure-rpi5-image.sh \
  --image rpi5-k8s-debian.img \
  --hostname controlplane \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password yourpassword

# Example: Configure for worker node  
sudo ./scripts/configure-rpi5-image.sh \
  --image rpi5-k8s-debian.img \
  --hostname node0 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password yourpassword
```

### Flashing and Booting

```bash
# Flash to microSD/USB/NVMe
sudo dd if=rpi5-k8s-debian.img of=/dev/YOUR_DEVICE bs=4M status=progress

# Boot your Raspberry Pi 5
# The system will automatically run the appropriate bootstrap script
```

## Architecture Details

### Image Structure
- **Boot partition (512MB)**: FAT32 with Pi 5 firmware and bootloader
- **Root partition**: ext4 with minimal Debian Bookworm ARM64 system

### Key Features
- **Pi 5 specific firmware**: Uses bcm2712-rpi-5-b.dtb device tree
- **Modern bootloader**: EEPROM-based (no start.elf/fixup.dat needed)
- **Kubernetes ready**: CRI-O runtime, proper cgroup configuration
- **Security hardened**: SSH key-only access, no root login
- **GitOps enabled**: SOPS encryption key support for Flux

### Network Configuration
- **Pod subnet**: Configurable CIDR for pod networking (default: 10.244.64.0/18)
- **Service subnet**: Configurable CIDR for services (default: 10.244.0.0/20)
- **CNI**: Cilium with Gateway API support
- **Load balancer**: Cilium L2 announcements

## Differences from Armbian Approach

| Aspect | Old (Armbian) | New (Custom Debian) |
|--------|---------------|-------------------|
| Base | Armbian Ubuntu | Debian Bookworm |
| Build system | Armbian framework | Direct debootstrap |
| Dependencies | Heavy (50GB+) | Minimal (~4GB) |
| Customization | Limited hooks | Full control |
| Pi 5 support | Requires updates | Native BCM2712 |
| Maintenance | External dependency | Self-contained |

## File Locations

```
.github/workflows/build-rpi5-image.yml  # GitHub Actions workflow
scripts/build-rpi5-image.sh             # Main build script  
scripts/configure-rpi5-image.sh         # Image configuration
scripts/controlplane-template.sh        # Control plane bootstrap
scripts/controlplane-secondary-template.sh  # Secondary CP bootstrap
scripts/node-template.sh                # Worker node bootstrap
scripts/kubeadm-init.yaml.tpl           # Kubeadm configuration template
scripts/cilium-values.yaml.tpl          # Cilium Helm values template
```

## Troubleshooting

### Build Issues
- Check workflow logs in GitHub Actions
- Ensure sufficient disk space (50GB+)
- Verify arm64 runner availability

### Boot Issues  
- Verify Pi 5 firmware files are present
- Check config.txt for proper kernel/device tree settings
- Ensure image was properly configured before flashing

### Network Issues
- Check network interface naming in bootstrap scripts
- Verify DNS resolution for 'controlplane' hostname
- Ensure firewall allows Kubernetes traffic

### Token Expiration
- Control plane certificates: 2-hour validity
- Worker tokens: 24-hour validity
- Use manual join commands for expired tokens (see README.md)

## Future Enhancements

- [ ] Multi-architecture support (Pi 4, Pi CM4)
- [ ] Custom kernel compilation
- [ ] Additional storage drivers (Longhorn)
- [ ] Cross-compilation support
- [ ] Image verification and signing