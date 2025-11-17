# Buildah on ARM64/Raspberry Pi 5 - Research Findings

**Date**: 2025-11-17
**Purpose**: Evaluate container build solutions for n8n dynamic webapp deployment on Raspberry Pi 5 cluster

---

## Executive Summary

**Recommendation**: **Kaniko** is the best choice for this use case.

**Key Reasons**:
1. ✅ **No storage configuration needed** - works out of the box in Kubernetes
2. ✅ **Truly rootless** - no privileged mode or special permissions required
3. ✅ **Simpler setup** - no daemon, no storage driver configuration
4. ✅ **Well-suited for ephemeral builds** - perfect for n8n workflow execution
5. ✅ **Maintained by Chainguard** - Google deprecated it, but Chainguard stepped up
6. ⚠️ **Trade-off**: Higher memory usage for large images (acceptable for our use case)

---

## Comparison Matrix

| Feature | Buildah | Buildkit | Kaniko |
|---------|---------|----------|--------|
| **ARM64 Support** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Rootless** | ⚠️ Complex | ⚠️ Needs privileged | ✅ Simple |
| **Setup Complexity** | ❌ High | ❌ Medium | ✅ Low |
| **Storage Config** | ❌ Required | ❌ Required | ✅ Not needed |
| **Memory Usage** | ✅ Low | ✅ Low | ⚠️ Higher |
| **Build Speed** | ✅ Fast | ✅ Fast | ⚠️ Slower |
| **Kubernetes Ready** | ⚠️ Needs work | ⚠️ Needs work | ✅ Yes |
| **Multi-arch** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Caching** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Maintenance** | ✅ Active | ✅ Active | ✅ Active (Chainguard) |

---

## Detailed Analysis

### 1. Buildah

**Pros**:
- Fast build times
- Low memory consumption
- Efficient disk usage with overlay storage
- Daemonless architecture
- Docker-compatible CLI

**Cons**:
- ❌ **Complex rootless setup in Kubernetes**:
  - Requires `CAP_SETUID` and `CAP_SETGID` capabilities OR privileged mode
  - Needs user namespace configuration (hostUsers: false)
  - Known issues with newuidmap/newgidmap in Kubernetes
  - Requires overlay storage driver configuration
  - Must mount storage volumes with size limits
- ❌ **Configuration overhead**:
  - Needs `/etc/containers/storage.conf`
  - Requires emptyDir volume for storage
  - Storage driver (overlay/vfs) configuration critical for performance
- ❌ **Known Kubernetes issues**:
  - GitHub Issue #4049: "Unprivileged Rootless Buildah on Kubernetes fails"
  - GitHub Issue #3053: "Rootless buildah/stable image not working"
  - AppArmor conflicts reported

**Resource Requirements** (from CERN benchmarks):
- Memory: ~2-4GB for large images
- Disk: Efficient with overlay storage
- Build time: Fast (comparable to Docker)

### 2. Buildkit

**Pros**:
- Very fast build times
- Excellent disk usage efficiency (best in class for large images)
- Low memory consumption
- Powers Docker/buildx
- Rich feature set

**Cons**:
- ❌ **Requires privileged mode** even with user namespaces
- ❌ **Daemon-based architecture** (needs buildkitd)
- ❌ **Storage configuration required**:
  - Must mount storage volumes
  - Needs `BUILDKITD_FLAGS="--root=/storage"`
- ❌ **User namespace limitations**:
  - Rootless mode needs `--oci-worker-no-process-sandbox`
  - This allows build containers to access host PID namespace (security concern)

**Resource Requirements** (from CERN benchmarks):
- Memory: ~2-4GB for large images
- Disk: Most efficient (especially for multi-stage builds)
- Build time: Fastest

### 3. Kaniko ⭐ **RECOMMENDED**

**Pros**:
- ✅ **Zero storage configuration** - works immediately
- ✅ **Truly rootless** - no special capabilities needed
- ✅ **No daemon** - simple executor model
- ✅ **Kubernetes-native** - designed for this use case
- ✅ **No privileged mode** - no security compromises
- ✅ **Simple pod spec** - just run the executor
- ✅ **Actively maintained** by Chainguard (after Google deprecation)
- ✅ **Debug images available** with shell (useful for CI/CD)

**Cons**:
- ⚠️ **Higher memory usage** for large images (~6-8GB for very large images)
  - **Acceptable**: Our webapps will be small (Node.js/Python apps)
  - Typical webapp images: 100-500MB (memory usage: ~1-2GB)
- ⚠️ **Slower builds** compared to Buildah/Buildkit
  - **Acceptable**: Build time is not critical for our use case
  - n8n workflows are asynchronous
  - Users expect some delay for builds

**Resource Requirements** (from CERN benchmarks):
- Memory: ~1-2GB for small images, ~6-8GB for very large images
- Disk: Less efficient than Buildkit, but adequate
- Build time: Slower, but acceptable for webapp use case

**Usage**:
```bash
/kaniko/executor \
  --context /workspace \
  --dockerfile Dockerfile \
  --destination registry.k8s-lab.dev/dynamic-apps/app:v1 \
  --cache=true \
  --cache-repo=registry.k8s-lab.dev/dynamic-apps/cache
```

---

## Raspberry Pi 5 Considerations

### Hardware Specs:
- **CPU**: Quad-core ARM Cortex-A76 @ 2.4GHz
- **RAM**: 8GB LPDDR4X
- **Performance**: 2-3x faster than Raspberry Pi 4
- **Architecture**: ARM64 (aarch64)

### ARM64 Compatibility:
- ✅ All three tools (Buildah, Buildkit, Kaniko) support ARM64
- ✅ Official container images available for ARM64
- ✅ No emulation needed - native ARM builds
- ✅ Multi-arch support available if needed

### Resource Constraints:
- **8GB RAM**: Adequate for Kaniko building small webapp images
- **Storage**: SD card or SSD - Kaniko's in-memory approach is fine
- **CPU**: Sufficient for concurrent builds

---

## Use Case Fit: n8n Dynamic Webapp Deployment

### Requirements:
1. Build container images from user-provided Dockerfiles
2. Push to private registry (`registry.k8s-lab.dev`)
3. Triggered by n8n workflows (asynchronous)
4. Ephemeral builds (no persistent build infrastructure)
5. Security (no root access, no privileged mode)
6. Simple integration with n8n

### Why Kaniko Wins:

**1. Simplicity**:
- n8n can spawn a Kaniko pod with minimal configuration
- No storage volumes, no daemon, no capabilities
- Just execute and wait for completion

**2. Security**:
- Truly rootless - runs as non-root user
- No privileged mode required
- No access to host namespaces
- Perfect for multi-tenant cluster

**3. Integration**:
- n8n Kubernetes plugin can easily create Kaniko jobs
- Simple command: `/kaniko/executor --context ... --dockerfile ... --destination ...`
- Debug images have shell for troubleshooting

**4. Resource Trade-off Acceptable**:
- Slower builds: ✅ Acceptable (asynchronous workflows)
- Higher memory: ✅ Acceptable (small webapp images)
- No storage config: ✅ Big win (simplicity)

**5. Maintenance**:
- Chainguard maintains it (security-focused company)
- Active development continues
- Production-ready

---

## Benchmarks (CERN Research)

### Small Images (gcc, chronyd):
- Build time: <5 seconds for all tools
- Memory: <500MB for all tools
- **Winner**: Tie (all excellent)

### Medium Images (scipy-notebook ~2GB):
- Build time: Buildkit/Buildah faster
- Memory: Buildkit/Buildah ~2GB, Kaniko ~3GB
- **Winner**: Buildkit/Buildah (but Kaniko acceptable)

### Large Images (CERN dev env ~35GB):
- Build time: Buildkit fastest, Kaniko slowest
- Memory: Buildkit/Buildah ~4GB, Kaniko ~8GB
- Disk efficiency: Buildkit best
- **Winner**: Buildkit (but irrelevant for our use case)

### Our Use Case (Webapp images 100-500MB):
- Expected build time: <2 minutes (Kaniko)
- Expected memory: ~1-2GB (Kaniko)
- **Winner**: Kaniko (simplicity outweighs performance difference)

---

## Decision

### ✅ Choose Kaniko

**Primary Reasons**:
1. **Simplicity** - No storage configuration, no daemon, no privileged mode
2. **Security** - Truly rootless, no compromises
3. **Kubernetes-native** - Designed for this exact use case
4. **Good enough performance** - For small webapp images
5. **Maintained** - Chainguard support

### Implementation Path:
1. Use official Kaniko image: `gcr.io/kaniko-project/executor:latest` (or debug variant)
2. n8n creates ephemeral Kaniko pods via Kubernetes node
3. Simple pod spec - no volumes except context
4. Push directly to `registry.k8s-lab.dev`

### Alternative Considered:
- **Buildah with Tekton**: If we later need pipeline orchestration and better performance, Tekton + Buildah is a solid alternative
- **Buildkit**: If we absolutely need fastest builds and can accept privileged mode

---

## References

1. CERN Kubernetes Blog: "Rootless container builds on Kubernetes" (2025)
   - https://kubernetes.web.cern.ch/blog/2025/06/19/rootless-container-builds-on-kubernetes/

2. GitHub Issues:
   - Buildah #4049: Rootless Kubernetes failures
   - Buildah #3053: Rootless image not working

3. Comparison Articles:
   - "Building container images in cloud-native CI pipelines" (lablabs.io)
   - "Docker vs. Buildah vs. kaniko" (Earthly Blog)

4. Raspberry Pi 5:
   - Official specs: 2-3x performance improvement over Pi 4
   - ARM Cortex-A76 quad-core @ 2.4GHz
   - 8GB LPDDR4X RAM

---

## Next Steps

1. ✅ Research complete - **Kaniko selected**
2. ⏭️ Deploy Kaniko infrastructure (Phase 2.2)
3. ⏭️ Verify registry authentication (Phase 2.3)
4. ⏭️ Test build pipeline (Phase 2.4)
