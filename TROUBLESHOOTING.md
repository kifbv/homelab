# Troubleshooting Guide

This guide covers common issues encountered when running a Kubernetes homelab on Raspberry Pi 5 with Cilium, Flux, and Rook-Ceph.

## Table of Contents

- [Storage Issues](#storage-issues)
- [Networking Issues](#networking-issues)
- [Container Runtime Issues](#container-runtime-issues)
- [Application Deployment Issues](#application-deployment-issues)
- [Debugging Commands](#debugging-commands)

---

## Storage Issues

### Rook-Ceph: No OSDs Created (OSD count 0)

**Symptoms:**
- Ceph cluster shows `HEALTH_WARN`
- Error message: `OSD count 0 < osd_pool_default_size 1`
- PersistentVolumeClaims (PVCs) stuck in `Pending` state
- No `rook-ceph-osd` pods running in the storage namespace
- Applications waiting for storage fail to start

**Root Cause:**

The CephCluster configuration specifies incorrect node names in the storage section. This commonly happens when:
1. Node names were changed after initial configuration
2. Configuration was copied from documentation without matching actual node names
3. Typos in node name specifications

**Diagnosis:**

```bash
# Check actual node names
kubectl get nodes

# Check Ceph cluster health
kubectl -n storage get cephcluster my-cluster

# Look for OSD pods (should show pods but won't if misconfigured)
kubectl get pods -n storage -l app=rook-ceph-osd

# Check detailed Ceph status
kubectl -n storage get cephcluster my-cluster -o jsonpath='{.status.ceph}'

# View Ceph operator logs for errors
kubectl logs -n storage deploy/rook-ceph-operator --tail=100
```

**Solution:**

Determine which configuration file is active:

```bash
# Check the kustomization to see which file is used
cat kubernetes/rpi-cluster/infrastructure/storage/rook-ceph/cluster/kustomization.yaml
```

If using `cluster-test.yaml` (common for test deployments):

```yaml
# File: infrastructure/storage/rook-ceph/cluster/cluster-test.yaml
storage:
  useAllNodes: false
  useAllDevices: false
  nodes:
    - name: node0  # Must match actual node name from `kubectl get nodes`
      devices:
        - name: /dev/nvme0n1  # Verify device exists on the node
```

If using `release.yaml` (HelmRelease-based):

```yaml
# File: infrastructure/storage/rook-ceph/cluster/release.yaml
spec:
  values:
    cephClusterSpec:
      storage:
        nodes:
          - name: node0  # Must match actual node name
            devices:
              - name: /dev/nvme0n1
```

**Verification:**

After fixing the configuration and allowing Flux to reconcile (or manually applying):

```bash
# Wait for OSD pods to appear (may take 1-2 minutes)
kubectl get pods -n storage -l app=rook-ceph-osd -w

# Check Ceph cluster health (should become HEALTH_OK)
kubectl -n storage get cephcluster my-cluster -o jsonpath='{.status.ceph.health}'

# Verify PVCs are now binding
kubectl get pvc -A

# Check that storage class is working
kubectl get storageclass
```

---

## Networking Issues

### Gateway API: LoadBalancer IP Not Accessible from Outside Cluster

**Symptoms:**
- Gateway resource shows `PROGRAMMED=True` status
- LoadBalancer service has the correct EXTERNAL-IP assigned
- HTTPRoutes show `ACCEPTED=True` and `ResolvedRefs=True`
- Cannot reach services from outside the cluster (connection timeout or refused)
- `curl` to Gateway IP fails: `Failed to connect: No route to host`

**Root Cause:**

Cilium L2AnnouncementPolicy interface pattern doesn't match Raspberry Pi network interfaces. The configuration may specify patterns like `^end[0-9]+` (common in some documentation) when Raspberry Pi actually uses `eth0`.

**Diagnosis:**

```bash
# Check Gateway status
kubectl get gateway -A
kubectl describe gateway -n network private-gateway

# Check LoadBalancer service
kubectl get svc -A | grep LoadBalancer

# Verify L2 announcement policy
kubectl get ciliuml2announcementpolicy -A
kubectl get ciliuml2announcementpolicy internal-l2announcement-policy -o yaml

# Check actual network interfaces on nodes
kubectl get nodes -o wide
kubectl exec -n kube-system ds/cilium -- ip link show | grep -E "^[0-9]+:"

# Check Cilium logs for L2 announcements
kubectl logs -n kube-system ds/cilium --tail=100 | grep -i "l2\|announce"

# Test from outside cluster (should fail before fix)
curl -k -v https://<GATEWAY_IP>
```

**Solution:**

Update the L2 announcement policy to match Raspberry Pi interfaces:

```yaml
# File: infrastructure/network/cilium/gateway/l2-announcement.yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: internal-l2announcement-policy
  namespace: kube-system
spec:
  interfaces:
    - ^eth[0-9]+  # Raspberry Pi uses eth0, not end0
  externalIPs: true
  loadBalancerIPs: true
```

**Verification:**

```bash
# Force Flux to reconcile the change
flux reconcile kustomization cilium-gateway --with-source

# Wait ~10-30 seconds for Cilium to update

# Check Cilium logs for successful announcements
kubectl logs -n kube-system ds/cilium --tail=50 -f | grep -i announce

# Test connectivity (should now work)
curl -k -v https://<GATEWAY_IP>

# Test with hostname (requires DNS)
curl -k https://homepage.k8s-lab.dev
```

**Related Issues:**

If the Gateway is still not accessible after fixing the interface pattern:
1. Verify IP pool configuration includes the Gateway IP
2. Check firewall rules on your router/network
3. Ensure the IP is in the same subnet as your nodes
4. Verify no IP conflicts with other devices

---

## Container Runtime Issues

### CRI-O: ImageInspectError with Ambiguous Short Names

**Symptoms:**
- Pod status shows `ImageInspectError`
- Error message: `short name mode is enforcing, but image name <name> returns ambiguous list`
- Container fails to pull image and never starts
- Pod repeatedly fails with the same error

**Root Cause:**

CRI-O security policy rejects short image names (e.g., `fratier/porkbun-webhook`) because they could refer to multiple container registries (Docker Hub, Quay, GitHub, etc.). This is a security feature to prevent ambiguous image references.

**Diagnosis:**

```bash
# Check pod status
kubectl get pods -A | grep ImageInspectError

# Get detailed error information
kubectl describe pod <pod-name> -n <namespace>

# Look for the error in events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | grep InspectFailed
```

**Solution:**

Use fully qualified image names in your HelmRelease or deployment manifests:

```yaml
# Before (fails):
image:
  repository: fratier/porkbun-webhook
  tag: arm64-1.0

# After (works):
image:
  repository: docker.io/fratier/porkbun-webhook
  tag: arm64-1.0
```

**Common Registry Prefixes:**

- Docker Hub: `docker.io/`
- GitHub Container Registry: `ghcr.io/`
- Quay: `quay.io/`
- Google Container Registry: `gcr.io/`
- Amazon ECR Public: `public.ecr.aws/`

**Example Fixes:**

```yaml
# Docker Hub image
repository: docker.io/library/nginx

# GitHub Container Registry
repository: ghcr.io/organization/app

# Quay
repository: quay.io/organization/app
```

**Verification:**

```bash
# Delete the failing pod to force recreation
kubectl delete pod <pod-name> -n <namespace>

# Watch pod creation
kubectl get pods -n <namespace> -w

# Verify image is pulled successfully
kubectl describe pod <pod-name> -n <namespace> | grep -A 5 "Events:"
```

---

## Application Deployment Issues

### StackGres: CrashLoopBackOff on ARM64

**Symptoms:**
- StackGres operator pod in `CrashLoopBackOff` state
- Error in logs: `Fatal error: Failed to create the main Isolate. (code 24)`
- Container exits immediately after start (within seconds)
- High restart count on the pod

**Root Cause:**

GraalVM native image compatibility issue on ARM64 architecture. The StackGres operator uses GraalVM native images which may not be properly compiled for ARM64/aarch64 platforms. This is a known limitation with some GraalVM-based applications.

**Diagnosis:**

```bash
# Check pod status
kubectl get pods -n datastore

# View container logs
kubectl logs -n datastore <stackgres-operator-pod> --tail=50

# Check pod events
kubectl describe pod -n datastore <stackgres-operator-pod>

# Verify architecture
kubectl get nodes -o wide
```

**Solutions:**

**Option 1: Check for ARM64-specific images**

Some projects provide separate ARM64 builds:

```bash
# Look for ARM64-specific tags in the registry
# Check Docker Hub, Quay, or the project's container registry
```

**Option 2: Use alternative PostgreSQL operators with better ARM64 support**

- **CloudNativePG** (recommended for ARM64):
  ```bash
  # Excellent ARM64 support, native Kubernetes operator
  # https://cloudnative-pg.io/
  ```

- **Zalando Postgres Operator**:
  ```bash
  # Good community support, works on ARM64
  # https://github.com/zalando/postgres-operator
  ```

- **Crunchy Data Postgres Operator**:
  ```bash
  # Enterprise-grade, supports ARM64
  # https://github.com/CrunchyData/postgres-operator
  ```

**Option 3: Deploy PostgreSQL directly**

Use a StatefulSet without operator overhead:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
spec:
  serviceName: postgresql
  replicas: 1
  template:
    spec:
      containers:
      - name: postgresql
        image: postgres:16-alpine  # Alpine builds work well on ARM64
        # ... rest of configuration
```

**Option 4: Wait for upstream fix**

Check StackGres releases for ARM64 compatibility updates:
- Monitor: https://stackgres.io/
- GitHub issues: https://github.com/ongres/stackgres

**Temporary Workaround:**

If you need to proceed with cluster setup, suspend the StackGres HelmRelease:

```bash
# Suspend the failing HelmRelease
flux suspend helmrelease stackgres-operator -n datastore

# Or delete it entirely
kubectl delete helmrelease stackgres-operator -n datastore
```

---

### Helm Chart Version Incompatibility

**Symptoms:**
- HelmRelease shows `InstallFailed` status
- Error: `chart requires kubeVersion: X.XX.X-X - X.XX.x-O which is incompatible with Kubernetes vX.XX.X`
- Flux reports helm install failures

**Root Cause:**

Helm chart specifies a Kubernetes version constraint that doesn't include your cluster version. This commonly happens when:
- Using older chart versions with newer Kubernetes
- Chart hasn't been updated for latest Kubernetes releases
- Typo in version constraint in chart metadata

**Diagnosis:**

```bash
# Check HelmRelease status
flux get helmreleases -A

# Get detailed error
kubectl describe helmrelease <name> -n <namespace>

# Check your Kubernetes version
kubectl version --short
```

**Solution:**

Update the HelmRelease to use a compatible chart version:

```yaml
# File: apps/datastore/stackgres/operator/release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: stackgres-operator
spec:
  chart:
    spec:
      version: 1.17.x  # Update to version that supports your K8s version
```

**Finding Compatible Versions:**

1. Check the chart repository:
   ```bash
   helm search repo <chart-name> --versions
   ```

2. Check ArtifactHub: https://artifacthub.io/
   - Search for the chart
   - Review "Kubernetes Version" in chart details

3. Check chart source repository (GitHub, GitLab, etc.)
   - Look at Chart.yaml for `kubeVersion` field
   - Check release notes for compatibility info

**Verification:**

```bash
# Force reconciliation
flux reconcile helmrelease <name> -n <namespace> --with-source

# Watch status
flux get helmreleases -A

# Verify pods are starting
kubectl get pods -n <namespace>
```

---

## Debugging Commands

### General Cluster Health

```bash
# Check all nodes
kubectl get nodes -o wide

# Check all pods (show non-running only)
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# Check cluster components
kubectl get componentstatuses

# View recent events across cluster
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

### Flux Debugging

```bash
# Check Flux installation
flux check

# List all Kustomizations
flux get kustomizations -A

# List all HelmReleases
flux get helmreleases -A

# Reconcile specific resource
flux reconcile kustomization <name> --with-source
flux reconcile helmrelease <name> -n <namespace> --with-source

# View Flux logs
kubectl logs -n flux-system deploy/source-controller --tail=50
kubectl logs -n flux-system deploy/kustomize-controller --tail=50
kubectl logs -n flux-system deploy/helm-controller --tail=50

# Suspend/resume resources
flux suspend kustomization <name>
flux resume kustomization <name>
```

### Cilium Debugging

```bash
# Check Cilium status
kubectl exec -n kube-system ds/cilium -- cilium-dbg status

# List services
kubectl exec -n kube-system ds/cilium -- cilium-dbg service list

# Check endpoints
kubectl exec -n kube-system ds/cilium -- cilium-dbg endpoint list

# View BGP/L2 announcements
kubectl logs -n kube-system ds/cilium --tail=100 | grep -i "announce"

# Check connectivity
kubectl exec -n kube-system ds/cilium -- cilium-dbg connectivity test
```

### Gateway API Debugging

```bash
# Check all Gateway resources
kubectl get gateway -A
kubectl get httproute -A
kubectl get grpcroute -A

# Detailed Gateway status
kubectl describe gateway <name> -n <namespace>

# Check LoadBalancer services
kubectl get svc -A | grep LoadBalancer

# Verify L2 announcement configuration
kubectl get ciliuml2announcementpolicy -A
kubectl get ciliumloadbalancerippool -A

# Test Gateway connectivity
curl -k -v https://<GATEWAY_IP>
curl -k --resolve <hostname>:443:<GATEWAY_IP> https://<hostname>
```

### Rook-Ceph Debugging

```bash
# Check Ceph cluster status
kubectl -n storage get cephcluster

# View Ceph health details
kubectl -n storage get cephcluster <name> -o jsonpath='{.status.ceph}'

# Check Ceph pods
kubectl get pods -n storage

# Check OSD pods specifically
kubectl get pods -n storage -l app=rook-ceph-osd

# Access Ceph tools
kubectl -n storage exec -it deploy/rook-ceph-tools -- bash
# Inside the pod:
ceph status
ceph osd status
ceph osd tree
ceph health detail

# Check operator logs
kubectl logs -n storage deploy/rook-ceph-operator --tail=100

# Check PVC status
kubectl get pvc -A
kubectl describe pvc <pvc-name> -n <namespace>
```

### Pod Debugging

```bash
# Describe pod for events and status
kubectl describe pod <pod-name> -n <namespace>

# View container logs
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> -c <container-name>  # For multi-container pods
kubectl logs <pod-name> -n <namespace> --previous  # Previous container instance

# Follow logs in real-time
kubectl logs -f <pod-name> -n <namespace>

# Execute commands in container
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh

# Check resource usage
kubectl top pod <pod-name> -n <namespace>
kubectl top pods -A

# View pod YAML
kubectl get pod <pod-name> -n <namespace> -o yaml
```

### Certificate Debugging

```bash
# Check cert-manager certificates
kubectl get certificates -A
kubectl get certificaterequests -A
kubectl get orders -A
kubectl get challenges -A

# Describe certificate
kubectl describe certificate <name> -n <namespace>

# Check cert-manager logs
kubectl logs -n security deploy/cert-manager --tail=50

# Manual certificate validation
kubectl get secret <certificate-secret> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text
```

### Network Debugging

```bash
# Check DNS resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default

# Check connectivity between pods
kubectl run -it --rm debug --image=busybox --restart=Never -- wget -O- http://<service-name>.<namespace>

# Check node network interfaces
kubectl debug node/<node-name> -it --image=busybox

# Verify service endpoints
kubectl get endpoints <service-name> -n <namespace>

# Check network policies
kubectl get networkpolicies -A
```

### Secret Debugging (SOPS)

```bash
# Verify SOPS key is available to Flux
kubectl get secret flux-sops -n flux-system

# Test SOPS decryption locally
sops --decrypt kubernetes/rpi-cluster/flux/settings/cluster-secrets.sops.yaml

# Check if secrets are properly encrypted
cat <file>.sops.yaml | grep -A 5 "sops:"
```

---

## Additional Resources

- [Kubernetes Official Troubleshooting](https://kubernetes.io/docs/tasks/debug/)
- [Flux Troubleshooting Guide](https://fluxcd.io/flux/cheatsheets/troubleshooting/)
- [Cilium Troubleshooting](https://docs.cilium.io/en/stable/operations/troubleshooting/)
- [Rook-Ceph Troubleshooting](https://rook.io/docs/rook/latest/Troubleshooting/ceph-common-issues/)
- [cert-manager Troubleshooting](https://cert-manager.io/docs/troubleshooting/)
