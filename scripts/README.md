# Raspberry Pi 5 Kubernetes Image Build Scripts

This directory contains scripts for building and configuring Raspberry Pi 5 images for Kubernetes cluster deployment.

## Overview

The image creation process follows a **two-stage workflow**:

1. **Base Image Preparation** (`prepare-base-image.sh`) - Creates a reusable base image with all Kubernetes components pre-installed
2. **Node Configuration** (`configure-rpi5-image.sh`) - Customizes the base image for each specific node

This approach provides several benefits:
- Uses official, tested Raspberry Pi OS instead of custom cross-compiled images
- Reduces image preparation time (base image created once, reused for all nodes)
- More reliable boot process with official Pi firmware and kernels
- Easier to maintain and update

## Prerequisites

### System Requirements

- Linux system with root access
- Minimum 8GB free disk space
- Reliable internet connection for initial download

### Required Packages

```bash
sudo apt-get install -y \
    qemu-user-static \
    parted \
    losetup \
    wget \
    xz-utils \
    e2fsprogs \
    dosfstools
```

### SOPS Age Key

Before configuring images, you need a SOPS age key for secret encryption:

```bash
# Install age and SOPS
sudo apt-get install age sops

# Generate age key
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# Get the public key for .sops.yaml configuration
grep "# public key:" ~/.config/sops/age/keys.txt
```

Update `.sops.yaml` in your repository with this public key.

## Quick Start

### Step 1: Prepare Base Image (Once)

Create a base image with all Kubernetes packages pre-installed:

```bash
sudo ./scripts/prepare-base-image.sh --output rpi5-k8s-base.img
```

This will:
- Download official Raspberry Pi OS Lite (Trixie ARM64)
- Install Kubernetes v1.33 (kubeadm, kubelet, kubectl)
- Install and configure CRI-O container runtime
- Configure system for Kubernetes (kernel parameters, cgroup settings)
- Create a ~6GB base image ready for customization

**Time:** ~15-20 minutes on first run

### Step 2: Configure Per-Node Images

Customize the base image for each node in your cluster:

```bash
# First control plane node
sudo ./scripts/configure-rpi5-image.sh \
  --image rpi5-k8s-base.img \
  --hostname controlplane \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password yourpassword

# Additional control plane nodes
sudo ./scripts/configure-rpi5-image.sh \
  --image rpi5-k8s-base.img \
  --hostname controlplane1 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password yourpassword

# Worker nodes
sudo ./scripts/configure-rpi5-image.sh \
  --image rpi5-k8s-base.img \
  --hostname node0 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password yourpassword
```

**Time:** ~30 seconds per node

### Step 3: Burn to Storage and Boot

```bash
# Burn to SD card or USB drive
sudo dd if=rpi5-k8s-base.img of=/dev/sdX bs=4M status=progress conv=fsync

# Or use Raspberry Pi Imager for a GUI experience
```

Boot the Raspberry Pi. The `k8s-firstboot.service` will automatically:
- Initialize or join the Kubernetes cluster (based on hostname)
- Install Cilium CNI (control plane only)
- Set up Flux GitOps (control plane only)
- Configure kubelet certificates

## Detailed Usage

### prepare-base-image.sh

Creates a base Raspberry Pi OS image with Kubernetes packages pre-installed.

```bash
sudo ./prepare-base-image.sh [OPTIONS]
```

**Options:**
- `--input URL|PATH` - Raspberry Pi OS image URL or local path (default: official Trixie ARM64 Lite)
- `--output PATH` - Output image file path (default: `rpi5-k8s-base.img`)
- `--k8s-version VER` - Kubernetes version to install (default: `v1.33`)
- `--skip-download` - Skip download if using local file
- `--help` - Show help message

**What it installs:**
- Kubernetes: kubelet, kubeadm, kubectl
- Container runtime: CRI-O v1.33
- Tools: vim, git, curl, wget, htop, jq, net-tools
- Kernel modules: overlay, br_netfilter
- Sysctl configuration for Kubernetes networking

**Output:**
A bootable Raspberry Pi OS image (~6GB) with all Kubernetes components pre-installed.

### configure-rpi5-image.sh

Customizes a base image for a specific node role and identity.

```bash
sudo ./configure-rpi5-image.sh [OPTIONS]
```

**Required Options:**
- `--image PATH` - Path to base image (from prepare-base-image.sh)
- `--hostname NAME` - Node hostname (determines role)
- `--ssh-key PATH` - SSH public key for pi user
- `--password PASS` - Password for pi user

**Optional Options:**
- `--pod-subnet CIDR` - Kubernetes pod network (default: `10.244.64.0/18`)
- `--service-subnet CIDR` - Kubernetes service network (default: `10.244.0.0/20`)
- `--help` - Show help message

**Hostname Patterns:**
- `controlplane` → First control plane (runs `kubeadm init`, installs Cilium, Flux)
- `controlplane[0-9]` → Additional control planes (joins with `--control-plane` flag)
- `node[0-9]` → Worker nodes (joins as worker)

**What it configures:**
- System hostname and /etc/hosts
- SSH authorized keys for pi user
- User password
- SOPS age key (copied to /root/keys.txt)
- Network subnet configuration
- Bootstrap script based on node role
- FluxInstance resource for GitOps
- Systemd service for first-boot automation

## Bootstrap Templates

The bootstrap process is automated via systemd service and role-specific scripts:

### controlplane-template.sh

First control plane node initialization:
1. Generates kubeadm configuration from template
2. Runs `kubeadm init` with specified network settings
3. Installs Gateway API CRDs
4. Installs Cilium CNI via Helm
5. Installs Flux Operator
6. Creates flux-sops secret for SOPS decryption
7. Applies FluxInstance to enable GitOps
8. Starts CSR auto-approval script (24 hours)
9. Copies kubeconfig to pi user

### controlplane-secondary-template.sh

Additional control plane nodes:
1. Reads join configuration
2. Joins cluster with `--control-plane` flag
3. Copies kubeconfig to pi user

### node-template.sh

Worker nodes:
1. Reads join configuration
2. Joins cluster as worker

## Network Configuration

The cluster uses customizable network subnets:

- **Pod Network**: `10.244.64.0/18` (default)
  - 16,384 IP addresses for pods
  - Managed by Cilium CNI

- **Service Network**: `10.244.0.0/20` (default)
  - 4,096 IP addresses for services
  - Includes ClusterIP and LoadBalancer services

Both can be customized with `--pod-subnet` and `--service-subnet` options.

## File Structure

```
scripts/
├── README.md                           # This file
├── prepare-base-image.sh               # Stage 1: Create base image
├── configure-rpi5-image.sh             # Stage 2: Configure per-node
├── controlplane-template.sh            # Bootstrap for first control plane
├── controlplane-secondary-template.sh  # Bootstrap for additional control planes
├── node-template.sh                    # Bootstrap for worker nodes
├── kubeadm-init.yaml.tpl              # Kubeadm init configuration template
└── cilium-values.yaml.tpl             # Cilium Helm values template
```

## Troubleshooting

### Base Image Preparation Fails

**Problem:** QEMU errors or chroot issues

**Solution:**
```bash
# Ensure qemu-user-static is installed and registered
sudo apt-get install qemu-user-static
sudo systemctl restart systemd-binfmt.service

# Verify ARM64 support
sudo update-binfmts --display qemu-aarch64
```

### Image Won't Boot

**Problem:** Raspberry Pi doesn't boot or shows rainbow screen

**Possible causes:**
- Corrupted image write - try re-burning with `conv=fsync`
- Incompatible storage device - try different SD card/USB drive
- Power supply insufficient - Raspberry Pi 5 requires 5V/5A USB-C

**Debug steps:**
1. Check boot partition is readable: `sudo mount /dev/sdX1 /mnt && ls /mnt`
2. Verify kernel and device tree exist: `ls /mnt/kernel*.img /mnt/*.dtb`
3. Check cmdline.txt for syntax errors: `cat /mnt/cmdline.txt`

### First Boot Hangs

**Problem:** System appears to hang during first boot

**This is normal!** The first boot runs the bootstrap script which:
- Initializes Kubernetes (control plane: ~5 minutes)
- Downloads and installs Cilium (~3 minutes)
- Installs Flux Operator (~2 minutes)

Total time: 10-15 minutes for control plane, 2-3 minutes for workers.

Check progress:
```bash
# SSH into the node
ssh pi@<hostname>

# Check bootstrap log
sudo tail -f /var/log/k8s-firstboot.log

# Check service status
sudo systemctl status k8s-firstboot.service
```

### Kubernetes Not Starting

**Problem:** kubelet fails to start

**Check logs:**
```bash
sudo journalctl -u kubelet -f
```

**Common issues:**
- Swap enabled: `sudo swapoff -a` (should be automatic)
- Container runtime not running: `sudo systemctl status crio`
- Network configuration: Check `/etc/sysctl.d/k8s.conf`

### CSR Not Auto-Approved

**Problem:** Node shows "NotReady" due to pending CSR

**Solution:**
```bash
# On control plane, check pending CSRs
kubectl get csr

# Manually approve
kubectl certificate approve <csr-name>

# Or approve all pending
kubectl get csr -o name | xargs kubectl certificate approve
```

The auto-approval script runs for 24 hours after bootstrap. After that, CSRs must be approved manually.

## Advanced Usage

### Custom Kubernetes Version

```bash
sudo ./prepare-base-image.sh \
  --output rpi5-k8s-base.img \
  --k8s-version v1.32
```

### Using Local Raspberry Pi OS Image

```bash
# Download once
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2025-10-02/2025-10-01-raspios-trixie-arm64-lite.img.xz

# Reuse for multiple base images
sudo ./prepare-base-image.sh \
  --input 2025-10-01-raspios-trixie-arm64-lite.img.xz \
  --output rpi5-k8s-base.img \
  --skip-download
```

### Custom Network Configuration

```bash
sudo ./configure-rpi5-image.sh \
  --image rpi5-k8s-base.img \
  --hostname controlplane \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password mypass \
  --pod-subnet 10.100.0.0/16 \
  --service-subnet 10.200.0.0/16
```

### Creating Multiple Node Images

```bash
#!/bin/bash
# Batch create images for entire cluster

BASE_IMAGE="rpi5-k8s-base.img"
SSH_KEY="~/.ssh/id_ed25519.pub"
PASSWORD="mypassword"

# Control plane
for i in "" 1 2; do
  sudo ./scripts/configure-rpi5-image.sh \
    --image "$BASE_IMAGE" \
    --hostname "controlplane$i" \
    --ssh-key "$SSH_KEY" \
    --password "$PASSWORD"

  # Rename for clarity
  mv "$BASE_IMAGE" "controlplane${i}.img"

  # Make a fresh copy for next node
  cp rpi5-k8s-base-original.img "$BASE_IMAGE"
done

# Workers
for i in {0..2}; do
  sudo ./scripts/configure-rpi5-image.sh \
    --image "$BASE_IMAGE" \
    --hostname "node$i" \
    --ssh-key "$SSH_KEY" \
    --password "$PASSWORD"

  mv "$BASE_IMAGE" "node${i}.img"
  cp rpi5-k8s-base-original.img "$BASE_IMAGE"
done
```

## Comparison with Old Workflow

### Old Workflow (GitHub Actions Build)
- Custom debootstrap cross-compilation
- Kernel panic issues
- Long build times (~30 minutes per image)
- Fragile firmware configuration
- Required GitHub Actions runner

### New Workflow (Raspberry Pi OS Base)
- Official tested Raspberry Pi OS
- Reliable boot process
- Fast per-node customization (~30 seconds)
- Proven firmware and kernel
- Can run locally or in CI/CD

## Next Steps

After booting your nodes:

1. **Retrieve kubeconfig** (from control plane):
   ```bash
   scp pi@controlplane:/home/pi/.kube/config ~/.kube/config-rpi-cluster
   export KUBECONFIG=~/.kube/config-rpi-cluster
   ```

2. **Verify cluster**:
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```

3. **Check Flux**:
   ```bash
   flux check
   flux get kustomizations
   ```

4. **Monitor bootstrap** (if needed):
   ```bash
   kubectl logs -n flux-system -l app=flux-operator -f
   ```

## Contributing

When modifying these scripts:

1. Test on actual Raspberry Pi 5 hardware
2. Verify both control plane and worker node scenarios
3. Update this README with any new options or behavior
4. Ensure backward compatibility with existing images where possible

## References

- [Raspberry Pi OS Downloads](https://www.raspberrypi.com/software/operating-systems/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Kubeadm Setup](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
- [Cilium Documentation](https://docs.cilium.io/)
- [Flux Documentation](https://fluxcd.io/docs/)
