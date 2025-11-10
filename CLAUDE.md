# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Kubernetes homelab running on Raspberry Pi 5 hardware with a custom Debian-based OS image. The cluster uses GitOps principles via Flux for continuous delivery and is designed for self-healing, automated operations.

**Key Technologies:**
- Official Raspberry Pi OS (Debian Trixie ARM64) as base image
- Kubernetes v1.34 installed via kubeadm
- CRI-O v1.34 container runtime
- Cilium for CNI (replacing kube-proxy) with Gateway API support
- Flux v2 for GitOps continuous delivery
- SOPS with age for secret encryption

## Image Building & Configuration

### Two-Stage Image Workflow

The Raspberry Pi 5 images are built using a two-stage process based on official Raspberry Pi OS:

**Stage 1: Base Image Preparation** (run once)
- Downloads official Raspberry Pi OS Lite (Trixie ARM64)
- Uses QEMU chroot to install Kubernetes v1.34 components (kubeadm, kubelet, kubectl)
- Installs and configures CRI-O v1.34 container runtime
- Configures system for Kubernetes (kernel parameters, cgroup settings, swap disable)
- Generates bootstrap tokens for cluster joining
- Creates a reusable base image (~6GB)

Script: `scripts/prepare-base-image.sh`

```bash
sudo ./scripts/prepare-base-image.sh --output rpi5-k8s-base.img
```

**Stage 2: Node-Specific Configuration** (run per node)

After creating the base image, use `scripts/configure-rpi5-image.sh` to customize it per-node. The script creates a copy of the base image, leaving the original untouched:

```bash
# Creates controlplane.img from the base image
sudo ./scripts/configure-rpi5-image.sh \
  --image rpi5-k8s-base.img \
  --hostname controlplane \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --password yourpassword
```

This script copies and then mounts the image to:
- Sets hostname and updates /etc/hosts
- Installs SSH public key for the pi user
- Copies SOPS age key to /root/keys.txt
- Selects and installs the appropriate bootstrap script based on hostname pattern
- Creates the FluxInstance resource for GitOps (watches main branch)
- Configures network subnets
- Configures systemd service to wait for CRI-O before running bootstrap

**Hostname patterns determine node role:**
- `controlplane` → First control plane node (runs `controlplane-template.sh`)
- `controlplane[0-9]` → Additional control plane nodes (runs `controlplane-secondary-template.sh`)
- `node[0-9]` → Worker nodes (runs `node-template.sh`)

**Bootstrap templates location:** `scripts/`
- `controlplane-template.sh` - Waits for CRI-O, disables swap, initializes cluster with kubeadm, installs Cilium and Flux
- `controlplane-secondary-template.sh` - Waits for CRI-O, disables swap, joins as additional control plane
- `node-template.sh` - Waits for CRI-O, disables swap, joins as worker node
- `kubeadm-init.yaml.tpl` - Kubeadm init configuration template (uses envsubst)
- `cilium-values.yaml.tpl` - Cilium Helm values template (uses envsubst)

## Kubernetes Cluster Architecture

### Network Configuration

**Cilium CNI:**
- Replaces kube-proxy (kubeadm runs with `--skip-phases=addon/kube-proxy`)
- Provides eBPF-based networking and security
- Implements Gateway API for ingress
- L2 announcements for LoadBalancer services
- Configured via `infrastructure/network/cilium/`

**Network Subnets:**
- Pod subnet: `10.244.64.0/18` (configurable)
- Service subnet: `10.244.0.0/20` (configurable)
- Both configured via configure-rpi5-image.sh and substituted into kubeadm config

### GitOps Structure

The cluster is managed by Flux with a hierarchical structure:

```
kubernetes/rpi-cluster/
├── flux/
│   ├── config/cluster.yaml          # Root Flux Kustomizations
│   ├── repositories/                # HelmRepository definitions
│   └── settings/                    # Cluster-wide ConfigMaps and Secrets
├── infrastructure/                  # Core cluster components
│   ├── network/                     # Cilium CNI
│   ├── gateway/                     # Gateway API CRDs
│   ├── security/                    # cert-manager, webhooks
│   └── storage/                     # Rook-Ceph storage
└── apps/                            # Application workloads
    ├── home/                        # Homepage, Linkding
    ├── monitoring/                  # Prometheus, Grafana, Loki, metrics-server
    └── datastore/                   # StackGres PostgreSQL
```

**Flux Kustomization hierarchy (from `flux/config/cluster.yaml`):**
1. `cluster-repositories` - Helm repos (no dependencies)
2. `cluster-settings` - Settings with SOPS decryption
3. `cluster-infrastructure` - Depends on repositories
4. `cluster-apps` - Depends on repositories

**Each app/component typically has:**
- `ks.yaml` - Flux Kustomization resource that references subdirectories
- `app/release.yaml` - HelmRelease or manifests
- `app/kustomization.yaml` - Kustomize configuration
- `crds/` - Optional CRD installation (installed before main app)

### Secret Management

**SOPS with age encryption:**
- Age key must be created before running configure-rpi5-image.sh
- Key location: `~/.config/sops/age/keys.txt`
- SOPS config: `.sops.yaml` (encrypts `data` and `stringData` fields in YAML)
- Encrypted secrets: `flux/settings/cluster-secrets.sops.yaml`
- Flux decrypts using the `flux-sops` secret (created by bootstrap script)

### Certificate Management

**Kubelet TLS Bootstrap:**
- `serverTLSBootstrap: true` in kubelet config enables automatic server certificate requests
- Control plane runs CSR auto-approval script for first 24 hours
- After 24 hours, manually approve with: `kubectl certificate approve <csr-name>`
- Logs: `/var/log/approve-kubelet-csrs.log` on control plane

**cert-manager:**
- Issues certificates via Let's Encrypt (ACME)
- Uses Porkbun webhook for DNS-01 challenges
- Manages wildcard certificates for internal domains
- Configuration: `infrastructure/security/cert-manager/`

### Storage

**Rook-Ceph:**
- Distributed storage across cluster nodes
- Provides block storage via RBD
- Configuration: `infrastructure/storage/rook-ceph/`
- Deployment order: common → operator → cluster → rbd

## Common Operations

### Adding Nodes to Cluster

**Within certificate/token validity:**
- Control plane cert keys: 2 hours
- Worker tokens: 24 hours
- Simply configure and boot the new node image

**After expiration:**
- Control plane: Generate new cert key with `kubeadm init phase upload-certs --upload-certs`
- Workers: Generate join command with `kubeadm token create --print-join-command`
- Manually approve CSRs: `kubectl certificate approve <csr-name>`

### Managing Flux

**Update Flux components:**
- Workflow: `.github/workflows/update-flux.yaml`
- Generates PR with latest Flux manifests

**Manual Flux operations:**
```bash
# Check Flux status
flux check

# Reconcile all Kustomizations
flux reconcile kustomization --all

# Suspend/resume a Kustomization
flux suspend kustomization <name>
flux resume kustomization <name>

# Check HelmReleases
flux get helmreleases -A
```

### Working with Secrets

**Encrypt a secret:**
```bash
sops --encrypt --in-place path/to/secret.yaml
```

**Edit encrypted secret:**
```bash
sops path/to/secret.yaml
```

**Decrypt for viewing:**
```bash
sops --decrypt path/to/secret.yaml
```

### Accessing the Cluster

After controlplane boots, retrieve kubeconfig:
```bash
scp pi@controlplane:/home/pi/.kube/config ~/.kube/config-rpi-cluster
export KUBECONFIG=~/.kube/config-rpi-cluster
kubectl get nodes
```

## Important Implementation Details

### Bootstrap Process

1. **First boot** triggers `k8s-firstboot.service` systemd unit
2. Service runs `/usr/bin/k8s-firstboot.sh` (copied by configure-rpi5-image.sh)
3. Control plane script:
   - Initializes cluster with kubeadm
   - Installs Gateway API CRDs
   - Installs Cilium via Helm
   - Installs Flux Operator
   - Creates flux-sops secret from age key
   - Applies FluxInstance resource to enable GitOps
   - Starts CSR auto-approval background script
4. After completion, creates `/var/lib/k8s-firstboot-done` flag

### Kubeadm Configuration

The kubeadm init configuration uses environment variable substitution (envsubst):
- Template: `scripts/kubeadm-init.yaml.tpl`
- Variables: `$TOKEN`, `$CERT_KEY`, `$HOST_IP`, `$POD_SUBNET`, `$SERVICE_SUBNET`
- Output: `/root/kubeadm/kubeadm-init.yaml` on the node
- Skips kube-proxy installation (Cilium replaces it)

### Cilium Configuration

Cilium is installed during bootstrap with Helm:
- Values template: `scripts/cilium-values.yaml.tpl`
- Substitutes `$POD_SUBNET` for IP allocation
- Enables Gateway API support
- Configures L2 announcements for LoadBalancer services

## File Naming Conventions

- `*.sops.yaml` - SOPS-encrypted YAML files
- `*.tpl` - Template files using envsubst for variable substitution
- `ks.yaml` - Flux Kustomization resources
- `kustomization.yaml` - Kustomize configuration files
- `release.yaml` - Flux HelmRelease resources

## Troubleshooting

### Common Issues

#### Rook-Ceph: No OSDs Created (OSD count 0)

**Symptoms:**
- Ceph cluster shows `HEALTH_WARN`
- Error: `OSD count 0 < osd_pool_default_size 1`
- PVCs stuck in `Pending` state
- No `rook-ceph-osd` pods running

**Root Cause:**
The CephCluster configuration specifies incorrect node names in the storage section.

**Solution:**
Check which file is active in `infrastructure/storage/rook-ceph/cluster/kustomization.yaml`:
- If using `cluster-test.yaml`: Update node names to match actual worker nodes
- If using `release.yaml`: Update the HelmRelease values

Example fix for `cluster-test.yaml`:
```yaml
storage:
  nodes:
    - name: node0  # Must match actual node name from `kubectl get nodes`
      devices:
        - name: /dev/nvme0n1
```

**Verification:**
```bash
kubectl get pods -n storage -l app=rook-ceph-osd
kubectl -n storage get cephcluster my-cluster -o jsonpath='{.status.ceph.health}'
```

#### CRI-O: ImageInspectError with Ambiguous Short Names

**Symptoms:**
- Pod shows `ImageInspectError` status
- Error: `short name mode is enforcing, but image name returns ambiguous list`
- Container fails to pull image

**Root Cause:**
CRI-O rejects short image names (e.g., `fratier/porkbun-webhook`) that could refer to multiple registries.

**Solution:**
Use fully qualified image names in HelmRelease values:

```yaml
# Before (fails):
image:
  repository: fratier/porkbun-webhook

# After (works):
image:
  repository: docker.io/fratier/porkbun-webhook
```

Common registries:
- Docker Hub: `docker.io/`
- GitHub Container Registry: `ghcr.io/`
- Quay: `quay.io/`

#### Gateway API: LoadBalancer IP Not Accessible from Outside Cluster

**Symptoms:**
- Gateway shows `PROGRAMMED=True` status
- LoadBalancer service has correct EXTERNAL-IP
- HTTPRoutes show `ACCEPTED=True`
- Cannot reach services from outside cluster (connection timeout/refused)

**Root Cause:**
Cilium L2AnnouncementPolicy interface pattern doesn't match Raspberry Pi network interfaces.

**Solution:**
Update `infrastructure/network/cilium/gateway/l2-announcement.yaml`:

```yaml
spec:
  interfaces:
    - ^eth[0-9]+  # Raspberry Pi uses eth0, not end0
```

**Verification:**
```bash
# Check network interfaces on nodes
kubectl get nodes -o wide
kubectl exec -n kube-system ds/cilium -- ip link show

# Verify L2 announcements
kubectl logs -n kube-system ds/cilium | grep -i announce

# Test connectivity
curl -k -v https://<GATEWAY_IP>
```

#### StackGres: CrashLoopBackOff on ARM64

**Symptoms:**
- StackGres operator pod in `CrashLoopBackOff`
- Error: `Fatal error: Failed to create the main Isolate. (code 24)`
- Container exits immediately after start

**Root Cause:**
GraalVM native image compatibility issue on ARM64 architecture. Some versions of StackGres may not have proper ARM64 support.

**Solutions:**
1. **Check for ARM64-specific images:**
   ```bash
   # Look for tags like -arm64 or -aarch64
   ```

2. **Use alternative PostgreSQL operators:**
   - CloudNativePG (good ARM64 support)
   - Zalando Postgres Operator
   - Crunchy Data Postgres Operator

3. **Deploy PostgreSQL directly:**
   - Use StatefulSet without operator overhead

4. **Wait for upstream fix:**
   - Check StackGres releases for ARM64 compatibility updates

#### Helm Version Incompatibility

**Symptoms:**
- HelmRelease shows `InstallFailed`
- Error: `chart requires kubeVersion: X.XX.X-X - X.XX.x-O which is incompatible with Kubernetes vX.XX.X`

**Solution:**
Update the HelmRelease to use a compatible chart version:

```yaml
spec:
  chart:
    spec:
      version: X.XX.x  # Use version range that supports your Kubernetes version
```

Check chart repository or ArtifactHub for version compatibility information.

### Debugging Commands

**Check overall cluster health:**
```bash
kubectl get nodes
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
flux get kustomizations -A
flux get helmreleases -A
```

**Inspect specific resource:**
```bash
kubectl describe <resource-type> <name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

**Cilium debugging:**
```bash
kubectl exec -n kube-system ds/cilium -- cilium-dbg status
kubectl exec -n kube-system ds/cilium -- cilium-dbg service list
```

**Ceph debugging:**
```bash
kubectl -n storage get cephcluster
kubectl -n storage exec -it deploy/rook-ceph-operator -- ceph status
```
