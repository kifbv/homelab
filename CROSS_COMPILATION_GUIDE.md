# Cross-Compilation Build Guide

This document describes the cross-compilation workflows for building Raspberry Pi 5 images on standard GitHub runners.

## Available Build Methods

### 1. Native ARM64 Build (Original)
- **Workflow**: `.github/workflows/build-rpi5-image.yml`
- **Runner**: `ubuntu-24.04-arm64` (GitHub ARM runners)
- **Status**: ⚠️ May have runner availability issues

### 2. Cross-Compilation Build (Recommended)
- **Workflow**: `.github/workflows/build-rpi5-image-cross.yml`
- **Runner**: `ubuntu-24.04` (standard x86_64 runners)
- **Method**: QEMU user-mode emulation + cross-compilation
- **Status**: ✅ Ready to use

### 3. Docker Build (Alternative)
- **Workflow**: `.github/workflows/build-rpi5-image-docker.yml`
- **Runner**: `ubuntu-24.04` (standard x86_64 runners)
- **Method**: Isolated Docker environment with QEMU
- **Status**: ✅ Ready to use

## Cross-Compilation Approach

### Technical Details

The cross-compilation build uses:
- **QEMU user-mode emulation** for ARM64 binary execution
- **debootstrap --foreign** for two-stage rootfs creation
- **aarch64-linux-gnu-gcc** cross-compiler toolchain
- **binfmt-misc** for transparent ARM64 binary execution

### Build Process

1. **Environment Setup**
   ```bash
   # Install cross-compilation tools
   apt-get install qemu-user-static gcc-aarch64-linux-gnu debootstrap
   
   # Register ARM64 binfmt handler
   echo ':qemu-aarch64:M::...' > /proc/sys/fs/binfmt_misc/register
   ```

2. **Two-Stage Debootstrap**
   ```bash
   # Stage 1: Download and extract packages (host architecture)
   debootstrap --arch arm64 --foreign bookworm /rootfs
   
   # Stage 2: Configure packages (target architecture with QEMU)
   chroot /rootfs /debootstrap/debootstrap --second-stage
   ```

3. **Cross-Architecture Package Installation**
   ```bash
   # All package installations happen in ARM64 chroot with QEMU
   chroot /rootfs apt-get install kubelet kubeadm kubectl cri-o
   ```

### Advantages

- ✅ **Reliable**: Uses standard x86_64 GitHub runners (always available)
- ✅ **Fast**: No dependency on ARM64 runner availability  
- ✅ **Identical output**: Produces the same ARM64 binaries as native build
- ✅ **Well-tested**: QEMU emulation is stable and widely used

### Limitations

- ⚠️ **Slower**: Cross-compilation is slower than native builds
- ⚠️ **QEMU overhead**: Some operations have emulation overhead
- ⚠️ **Memory usage**: QEMU emulation uses more memory

## Docker Build Approach

### Benefits of Docker Method

- **Complete isolation**: No host system contamination
- **Reproducible**: Identical build environment every time
- **Easier debugging**: Can run the same container locally
- **Version control**: Build environment versioned in Dockerfile

### Docker Build Process

```dockerfile
FROM debian:bookworm

# Install all build dependencies
RUN apt-get update && apt-get install -y \
    qemu-user-static gcc-aarch64-linux-gnu debootstrap ...

# Configure QEMU binfmt
RUN echo ':qemu-aarch64:M::...' > /etc/binfmt.d/qemu-aarch64.conf
```

## Usage Instructions

### Triggering Builds

#### Manual Build (GitHub Actions)
1. Go to **Actions** tab in your repository
2. Select the desired workflow:
   - "Build Raspberry Pi 5 Debian Image (Cross-Compilation)" - **Recommended**
   - "Build Raspberry Pi 5 Debian Image (Docker)" - Alternative
3. Click **"Run workflow"**
4. Configure parameters as needed

#### Automatic Build
All workflows trigger automatically on push to main when scripts are modified.

### Workflow Parameters

All workflows support the same input parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| image_name | `rpi5-k8s-debian-cross` | Output image filename |
| kubernetes_version | `v1.33` | Kubernetes version to install |
| pod_subnet | `10.244.64.0/18` | Pod network CIDR |
| service_subnet | `10.244.0.0/20` | Service network CIDR |

### Configuration and Flashing

After downloading the built image:

```bash
# 1. Decompress the image
xz -d rpi5-k8s-debian-cross.img.xz

# 2. Configure for your node
sudo ./scripts/configure-rpi5-image.sh \
  --image rpi5-k8s-debian-cross.img \
  --hostname controlplane \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password yourpassword

# 3. Flash to storage device
sudo dd if=rpi5-k8s-debian-cross.img of=/dev/YOUR_DEVICE bs=4M status=progress

# 4. Boot your Raspberry Pi 5
```

## Build Comparison

| Feature | Native ARM64 | Cross-Compilation | Docker |
|---------|--------------|-------------------|--------|
| **Runner Type** | arm64 | x86_64 | x86_64 |
| **Availability** | Limited | Always | Always |
| **Build Speed** | Fastest | Medium | Medium |
| **Isolation** | Host-based | Host-based | Container |
| **Debugging** | Good | Good | Excellent |
| **Reproducibility** | Good | Good | Excellent |
| **Resource Usage** | Low | Medium | Medium |

## Troubleshooting

### QEMU Issues

```bash
# Verify QEMU installation
/usr/bin/qemu-aarch64-static --version

# Check binfmt registration
cat /proc/sys/fs/binfmt_misc/qemu-aarch64

# Test ARM64 execution
echo 'int main(){return 0;}' | aarch64-linux-gnu-gcc -x c -o test -
./test  # Should execute via QEMU
```

### Cross-Compilation Issues

```bash
# Verify cross-compiler
aarch64-linux-gnu-gcc --version

# Test cross-compilation
echo 'int main(){return 0;}' | aarch64-linux-gnu-gcc -x c -o test_arm64 -
file test_arm64  # Should show ARM aarch64
```

### Build Failures

1. **Check build logs** in GitHub Actions artifacts
2. **Verify disk space** (builds need ~8GB free space)
3. **Check runner resources** (memory, CPU)
4. **Validate input parameters** (Kubernetes version, network CIDRs)

### Common Issues

| Issue | Cause | Solution |
|-------|--------|----------|
| "No space left on device" | Insufficient disk space | Free up space, reduce image size |
| "qemu-aarch64-static not found" | Missing QEMU | Install qemu-user-static package |
| "debootstrap failed" | Mirror issues | Try different Debian mirror |
| "Package not found" | Repository issues | Check Kubernetes/CRI-O repo URLs |

## Performance Optimization

### For Cross-Compilation
- Use local apt cache/proxy
- Minimize package installations in chroot
- Use parallel compression (`xz -T 0`)

### For Docker Builds
- Use multi-stage Dockerfile
- Cache dependency layers
- Minimize container image size

## Local Testing

To test the cross-compilation build locally:

```bash
# Install dependencies
sudo apt-get install qemu-user-static gcc-aarch64-linux-gnu debootstrap

# Create test environment
sudo mkdir -p /build/{image,mnt,firmware}
git clone --depth 1 https://github.com/raspberrypi/firmware.git /build/firmware

# Run build script
sudo -E ./scripts/build-rpi5-image-cross.sh
```

## Security Considerations

- **QEMU vulnerabilities**: Keep QEMU updated for security
- **Cross-compilation trust**: Verify cross-compiler integrity
- **Container security**: Use minimal base images in Docker builds
- **Build isolation**: Prefer Docker builds for untrusted environments

This cross-compilation approach ensures reliable builds regardless of GitHub runner availability while maintaining the same high-quality ARM64 output as native builds.