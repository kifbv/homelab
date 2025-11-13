# Public Exposure Implementation Addendum

**Status**: Technical Specifications
**Purpose**: Address additional requirements for immediate reconciliation and private registry

## Table of Contents

1. [Immediate Flux Reconciliation](#immediate-flux-reconciliation)
2. [Private Docker Registry Solution](#private-docker-registry-solution)
3. [Complete Integration Architecture](#complete-integration-architecture)
4. [Updated n8n Workflow](#updated-n8n-workflow)
5. [Implementation Steps](#implementation-steps)

---

## Immediate Flux Reconciliation

### Problem Statement

Default Flux behavior reconciles every 5-10 minutes. For n8n-driven deployments, we want **immediate reconciliation** when n8n pushes manifests to Git.

### Solution: Flux Webhook Receivers

**Architecture:**
```
n8n pushes to Git
      ↓
Git webhook calls Flux Receiver
      ↓
Flux immediately reconciles
      ↓
App deployed in seconds (not minutes)
```

### Implementation

#### 1. Create Webhook Secret

```yaml
# flux/settings/webhook-token.sops.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: flux-webhook-token
  namespace: flux-system
type: Opaque
stringData:
  token: <generate-strong-random-token>
```

**Generate token:**
```bash
TOKEN=$(head -c 12 /dev/urandom | shasum | cut -d ' ' -f1)
echo $TOKEN
# Store this in SOPS secret
```

#### 2. Create Receiver Resource

```yaml
# infrastructure/flux/webhook-receiver/receiver.yaml
---
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: homelab-git-receiver
  namespace: flux-system
spec:
  type: github  # or gitlab, bitbucket, generic
  events:
    - "ping"
    - "push"
  secretRef:
    name: flux-webhook-token
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      name: flux-system
      namespace: flux-system
```

**Supported Git providers:**
- GitHub
- GitLab
- Bitbucket
- Gitea
- Generic (any webhook)

#### 3. Expose Receiver via Cloudflare Tunnel

```yaml
# infrastructure/network/cloudflared/app/release.yaml
values:
  ingress:
    # ... existing rules ...

    # Flux webhook receiver
    - hostname: flux-webhook.example.com
      service: http://notification-controller.flux-system.svc.cluster.local:9292

    - service: http_status:404
```

**Configure DNS:**
```
flux-webhook.example.com → CNAME → <tunnel-id>.cfargotunnel.com
```

#### 4. Get Receiver URL

```bash
kubectl -n flux-system get receiver homelab-git-receiver

# Output:
# NAME                    READY   STATUS
# homelab-git-receiver    True    Receiver initialised with URL: /hook/abc123...
```

The full webhook URL will be:
```
https://flux-webhook.example.com/hook/<receiver-token>
```

#### 5. Configure Git Repository Webhook

**For GitHub:**
1. Go to repository → Settings → Webhooks → Add webhook
2. **Payload URL**: `https://flux-webhook.example.com/hook/<receiver-token>`
3. **Content type**: `application/json`
4. **Secret**: Use the `token` from the secret
5. **Events**: Select "Just the push event"
6. **Active**: Check the box

**For GitLab:**
1. Go to repository → Settings → Webhooks
2. **URL**: `https://flux-webhook.example.com/hook/<receiver-token>`
3. **Secret Token**: Use the `token` from the secret
4. **Trigger**: Select "Push events"
5. **Enable SSL verification**: Check

**For Generic Git Provider:**
Use `type: generic` in Receiver spec and configure webhook to call the URL on push events.

### Reconciliation Flow

**With webhook receiver:**
```
n8n commits & pushes → Git receives commit
      ↓
Git webhook → Flux Receiver (< 1 second)
      ↓
Flux reconciles immediately (< 10 seconds)
      ↓
App deployed (total: ~15-30 seconds)
```

**Without webhook receiver (old way):**
```
n8n commits & pushes → Git receives commit
      ↓
Wait for reconciliation interval (5-10 minutes)
      ↓
Flux reconciles
      ↓
App deployed (total: 5-10 minutes)
```

### Security Considerations

1. **HMAC Validation**: Flux validates webhook payload using the secret token
2. **TLS**: All traffic encrypted via Cloudflare Tunnel
3. **Namespace Isolation**: Receiver can only trigger resources in specified namespaces
4. **Token Rotation**: Rotate webhook token periodically (store in SOPS)

### Monitoring

```bash
# Check receiver status
kubectl get receiver -n flux-system

# View receiver logs
kubectl logs -n flux-system -l app=notification-controller -f

# Check last reconciliation
kubectl get gitrepository flux-system -n flux-system
```

---

## Private Docker Registry Solution

### Requirements

- Host Docker images in-cluster
- Integrate with n8n workflow (build & push images)
- Support Kubernetes image pulls
- Secure with authentication
- Expose via Cloudflare Tunnel (for n8n access)
- Low resource footprint (Raspberry Pi constraints)

### Solution Comparison

| Feature | Harbor | Docker Registry v2 | Gitea Container Registry |
|---------|--------|---------------------|--------------------------|
| **Complexity** | High | Low | Medium |
| **Features** | Rich (scanning, replication, RBAC) | Basic | Medium |
| **Resources** | Heavy (~2-4GB RAM) | Light (~256-512MB RAM) | Medium (~1GB RAM) |
| **UI** | Web UI | None (API only) | Web UI |
| **Helm Chart** | ✅ Official | ✅ Community | ✅ Official |
| **Best For** | Enterprise | Homelab/Simple | Git-integrated |

**Recommendation: Docker Registry v2**

**Reasons:**
1. **✅ Lightweight** - Minimal resource usage (critical for Raspberry Pi)
2. **✅ Simple** - Easy to configure and maintain
3. **✅ Sufficient** - Meets all requirements without overhead
4. **✅ GitOps-friendly** - Declarative configuration
5. **✅ Proven** - Battle-tested, used by Docker Hub

Harbor would be overkill for this use case and consume too many resources.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  n8n Workflow                                                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ 1. Build Docker image                                 │   │
│  │ 2. Tag: registry.example.com/myapp:v1               │   │
│  │ 3. Push to private registry                          │   │
│  └──────────────────────┬───────────────────────────────┘   │
└────────────────────────┼───────────────────────────────────┘
                         │
                         ↓ HTTPS (via Cloudflare Tunnel)
┌─────────────────────────────────────────────────────────────┐
│  Private Docker Registry (in Kubernetes)                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ registry-docker-registry.registry.svc.cluster.local  │   │
│  │ Port: 5000                                           │   │
│  │ Storage: Rook-Ceph (10GB PVC)                       │   │
│  │ Auth: htpasswd (username/password)                  │   │
│  └──────────────────────┬───────────────────────────────┘   │
└────────────────────────┼───────────────────────────────────┘
                         │
                         ↓ Pull images
┌─────────────────────────────────────────────────────────────┐
│  Kubernetes Nodes                                            │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ kubelet pulls images from private registry           │   │
│  │ Uses imagePullSecrets                               │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Implementation

#### 1. Create Registry Namespace and Secrets

```yaml
# apps/registry/namespace.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: registry
```

```yaml
# apps/registry/docker-registry/app/registry-auth.sops.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-htpasswd
  namespace: registry
type: Opaque
stringData:
  # Generate with: htpasswd -Bbn <username> <password>
  htpasswd: |
    n8n:$2y$05$... (bcrypt hash)
    admin:$2y$05$... (bcrypt hash)
```

**Generate htpasswd:**
```bash
# Install htpasswd (if not available)
apt-get install apache2-utils  # Debian/Ubuntu
brew install httpd  # macOS

# Generate password hash
htpasswd -Bbn n8n <strong-password>
htpasswd -Bbn admin <strong-password>

# Output format: username:$2y$05$...
# Copy the full line to the htpasswd field
```

```yaml
# apps/registry/docker-registry/app/registry-credentials.sops.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-credentials
  namespace: registry
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "registry.example.com": {
          "username": "n8n",
          "password": "<strong-password>",
          "auth": "<base64(username:password)>"
        }
      }
    }
```

**Generate auth field:**
```bash
echo -n "n8n:<strong-password>" | base64
```

#### 2. Add HelmRepository

```yaml
# flux/repositories/twuni.yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: twuni
  namespace: flux-system
spec:
  interval: 1h
  url: https://helm.twun.io
```

#### 3. Deploy Docker Registry

```yaml
# apps/registry/docker-registry/ks.yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: docker-registry
  namespace: flux-system
spec:
  dependsOn:
    - name: rook-ceph-rbd
  interval: 1h
  path: ./kubernetes/rpi-cluster/apps/registry/docker-registry/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  targetNamespace: registry
  decryption:
    provider: sops
    secretRef:
      name: flux-sops
  wait: true
```

```yaml
# apps/registry/docker-registry/app/release.yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: docker-registry
  namespace: registry
spec:
  chart:
    spec:
      chart: docker-registry
      version: 2.2.x
      sourceRef:
        kind: HelmRepository
        name: twuni
        namespace: flux-system
  interval: 1h
  values:
    # Registry configuration
    image:
      repository: registry
      tag: 2.8.3
      pullPolicy: IfNotPresent

    # Enable authentication
    secrets:
      htpasswd: ""  # Will use external secret

    # Storage configuration
    persistence:
      enabled: true
      storageClass: rook-ceph-block
      size: 10Gi
      accessMode: ReadWriteOnce

    # Service configuration
    service:
      type: ClusterIP
      port: 5000

    # Resource limits
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi

    # Registry config
    configData:
      version: 0.1
      log:
        fields:
          service: registry
      storage:
        cache:
          blobdescriptor: inmemory
        filesystem:
          rootdirectory: /var/lib/registry
      http:
        addr: :5000
        headers:
          X-Content-Type-Options: [nosniff]
        debug:
          addr: :5001
          prometheus:
            enabled: true
            path: /metrics
      health:
        storagedriver:
          enabled: true
          interval: 10s
          threshold: 3
      auth:
        htpasswd:
          realm: Registry Realm
          path: /auth/htpasswd

    # Mount htpasswd secret
    extraVolumeMounts:
      - name: auth
        mountPath: /auth
        readOnly: true

    extraVolumes:
      - name: auth
        secret:
          secretName: registry-htpasswd
          items:
            - key: htpasswd
              path: htpasswd
```

#### 4. Expose via Cloudflare Tunnel

```yaml
# infrastructure/network/cloudflared/app/release.yaml
values:
  ingress:
    # ... existing rules ...

    # Docker registry (HTTPS endpoint for n8n)
    - hostname: registry.example.com
      service: http://docker-registry.registry.svc.cluster.local:5000

    - service: http_status:404
```

**Configure DNS:**
```
registry.example.com → CNAME → <tunnel-id>.cfargotunnel.com
```

#### 5. Create ImagePullSecret for Kubernetes

```yaml
# apps/registry/docker-registry/app/imagepullsecret.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-credentials
  namespace: dynamic-apps
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <base64-encoded-dockerconfigjson>
```

**Apply to all namespaces that will pull images:**
```yaml
# For dynamic-apps namespace
# apps/dynamic/imagepullsecret.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-credentials
  namespace: dynamic-apps
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "registry.example.com": {
          "username": "n8n",
          "password": "<password>",
          "auth": "<base64(username:password)>"
        }
      }
    }
```

**Encrypt with SOPS:**
```bash
sops --encrypt --in-place apps/dynamic/imagepullsecret.yaml
```

#### 6. Configure Default ServiceAccount

```yaml
# apps/dynamic/default-serviceaccount.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: dynamic-apps
imagePullSecrets:
  - name: registry-credentials
```

This ensures all pods in `dynamic-apps` namespace can pull from private registry without specifying `imagePullSecrets` in every deployment.

### Registry Usage

#### From n8n Workflow

**1. Build Docker image:**
```javascript
// n8n Execute Command node
const buildCommand = `
docker build -t registry.example.com/myapp:${version} .
`;
```

**2. Login to registry:**
```javascript
// n8n Execute Command node
const loginCommand = `
echo "${registryPassword}" | docker login registry.example.com -u n8n --password-stdin
`;
```

**3. Push image:**
```javascript
// n8n Execute Command node
const pushCommand = `
docker push registry.example.com/myapp:${version}
`;
```

**4. Generate Kubernetes deployment with private image:**
```javascript
// n8n Code node
const deployment = {
  apiVersion: "apps/v1",
  kind: "Deployment",
  metadata: {
    name: appName,
    namespace: "dynamic-apps"
  },
  spec: {
    replicas: 1,
    selector: {
      matchLabels: { app: appName }
    },
    template: {
      metadata: {
        labels: { app: appName }
      },
      spec: {
        // No need to specify imagePullSecrets - using default ServiceAccount
        containers: [{
          name: appName,
          image: `registry.example.com/${appName}:${version}`,
          ports: [{ containerPort: 8080 }]
        }]
      }
    }
  }
};
```

#### From Command Line

```bash
# Login
docker login registry.example.com -u n8n

# Pull image
docker pull registry.example.com/myapp:v1

# Push image
docker tag myapp:v1 registry.example.com/myapp:v1
docker push registry.example.com/myapp:v1
```

#### From Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: dynamic-apps
spec:
  template:
    spec:
      # Option 1: Use default ServiceAccount (preferred)
      # No imagePullSecrets needed

      # Option 2: Explicit imagePullSecrets
      imagePullSecrets:
        - name: registry-credentials

      containers:
        - name: myapp
          image: registry.example.com/myapp:v1
```

### Monitoring & Management

#### Check Registry Status

```bash
# Check pods
kubectl get pods -n registry

# Check logs
kubectl logs -n registry -l app=docker-registry -f

# Check storage
kubectl get pvc -n registry
```

#### List Images in Registry

```bash
# Via API
curl -u n8n:<password> https://registry.example.com/v2/_catalog

# Response:
# {"repositories":["myapp","another-app"]}

# List tags for an image
curl -u n8n:<password> https://registry.example.com/v2/myapp/tags/list

# Response:
# {"name":"myapp","tags":["v1","v2","latest"]}
```

#### Delete Images

```bash
# Get image digest
curl -u n8n:<password> \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  https://registry.example.com/v2/myapp/manifests/v1

# Delete by digest
curl -u n8n:<password> -X DELETE \
  https://registry.example.com/v2/myapp/manifests/sha256:<digest>

# Run garbage collection (in registry pod)
kubectl exec -n registry <registry-pod> -- \
  /bin/registry garbage-collect /etc/docker/registry/config.yml
```

### Security Best Practices

1. **Authentication**: Always require authentication (htpasswd)
2. **TLS**: All external access via Cloudflare Tunnel (automatic TLS)
3. **Network Policy**: Restrict registry access to authorized namespaces
4. **Secrets**: Store credentials in SOPS-encrypted secrets
5. **Regular Cleanup**: Implement image retention policy (delete old versions)
6. **Scanning**: Consider integrating Trivy for vulnerability scanning

### Backup Strategy

**Registry data is stored in PVC backed by Rook-Ceph:**
- Automatic Ceph replication (based on cluster config)
- Can use Velero for backup/restore
- Can export images periodically to external storage

**Backup images:**
```bash
# Export all images
for repo in $(curl -u n8n:<password> https://registry.example.com/v2/_catalog | jq -r '.repositories[]'); do
  for tag in $(curl -u n8n:<password> https://registry.example.com/v2/${repo}/tags/list | jq -r '.tags[]'); do
    docker pull registry.example.com/${repo}:${tag}
    docker save registry.example.com/${repo}:${tag} -o ${repo}_${tag}.tar
  done
done
```

---

## Complete Integration Architecture

### Updated Architecture Diagram

```
┌───────────────────────────────────────────────────────────────────────┐
│                    Internet / Public Users                             │
└──────────────────────────┬────────────────────────────────────────────┘
                           │
                           ↓
┌───────────────────────────────────────────────────────────────────────┐
│               Cloudflare Global Network                                │
│  • TLS Termination                                                     │
│  • DDoS Protection                                                     │
│  • Access Policies                                                     │
└──────────────────────────┬────────────────────────────────────────────┘
                           │ Outbound tunnel from cluster
                           ↓
┌───────────────────────────────────────────────────────────────────────┐
│                 Raspberry Pi 5 Kubernetes Cluster                      │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  cloudflared (Tunnel Daemon)                                      │ │
│  └────────────────────────┬─────────────────────────────────────────┘ │
│                           ↓                                            │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  Exposed Services:                                                │ │
│  │  • n8n.example.com → n8n                                         │ │
│  │  • registry.example.com → Docker Registry                        │ │
│  │  • flux-webhook.example.com → Flux Receiver                      │ │
│  │  • *.apps.example.com → Dynamic Apps                            │ │
│  └────────────────────────┬─────────────────────────────────────────┘ │
│                           ↓                                            │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  n8n Workflow Automation                                          │ │
│  │  ┌────────────────────────────────────────────────────────────┐  │ │
│  │  │ Build & Deploy Workflow:                                    │  │ │
│  │  │ 1. AI Agent generates code                                  │  │ │
│  │  │ 2. Build Docker image                                       │  │ │
│  │  │ 3. Push to registry.example.com                            │  │ │
│  │  │ 4. Generate K8s manifests                                   │  │ │
│  │  │ 5. Commit & push to Git                                     │  │ │
│  │  └────────────────────────────────────────────────────────────┘  │ │
│  └──────────────────────────┬───────────────────────────────────────┘ │
│                             │                                          │
│                             ↓ Git push                                 │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  Git Repository (External)                                        │ │
│  └──────────────────────────┬───────────────────────────────────────┘ │
│                             │                                          │
│                             ↓ Webhook                                  │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  Flux Webhook Receiver                                            │ │
│  │  • Receives Git webhook                                           │ │
│  │  • Triggers immediate reconciliation                              │ │
│  └──────────────────────────┬───────────────────────────────────────┘ │
│                             ↓ < 1 second                               │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  Flux GitOps                                                      │ │
│  │  • Reconciles immediately (not in 5-10 minutes)                   │ │
│  │  • Pulls from Git                                                 │ │
│  │  • Applies manifests                                              │ │
│  └──────────────────────────┬───────────────────────────────────────┘ │
│                             ↓ < 10 seconds                             │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  Dynamic App Deployed                                             │ │
│  │  • Pod pulls image from registry.example.com                     │ │
│  │  • Service created                                                │ │
│  │  • HTTPRoute configured                                           │ │
│  │  • Cloudflare Tunnel routes traffic                              │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  Total Deployment Time: ~15-30 seconds                                │
│  (vs 5-10 minutes without webhook receiver)                           │
└───────────────────────────────────────────────────────────────────────┘
```

### Component Interaction Flow

**1. User triggers n8n workflow** (via webhook, schedule, or UI)

**2. n8n workflow executes:**
   - AI agent generates webapp code
   - Dockerfile created
   - `docker build -t registry.example.com/myapp:v1 .`
   - `docker push registry.example.com/myapp:v1`
   - Generate Kubernetes manifests (deployment, service, httproute)
   - `git clone` homelab repo
   - Write manifests to `apps/dynamic/myapp/`
   - `git commit` with message
   - `git push origin main`

**3. Git webhook triggers immediately:**
   - Git provider (GitHub/GitLab) calls `https://flux-webhook.example.com/hook/<token>`
   - Flux Receiver validates HMAC signature
   - Flux marks `GitRepository` for immediate reconciliation

**4. Flux reconciles immediately:**
   - Pulls latest commit from Git
   - Detects new `apps/dynamic/myapp/` directory
   - Applies Kustomization
   - Creates Deployment, Service, HTTPRoute

**5. Kubernetes pulls image:**
   - kubelet uses `imagePullSecrets` (registry-credentials)
   - Authenticates to `registry.example.com`
   - Pulls `myapp:v1` image
   - Starts container

**6. Cloudflare Tunnel routes traffic:**
   - `myapp.apps.example.com` → Cilium Gateway → Service → Pod
   - App is publicly accessible

**Total time: 15-30 seconds** (vs 5-10 minutes without webhook)

---

## Updated n8n Workflow

### Complete Workflow Structure

```
┌─────────────────────────────────────────────────────────────────────┐
│  Trigger: Webhook / Schedule / Manual                               │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Code: Validate Input & Generate App Name                           │
│  • Validate required fields                                          │
│  • Generate unique app name (slug + timestamp)                       │
│  • Set default values                                                │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  AI Agent: Generate Webapp Code                                      │
│  • OpenAI / Custom LLM                                               │
│  • Generate application code                                         │
│  • Generate Dockerfile                                               │
│  • Return as text/files                                              │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Execute Command: Build Docker Image                                │
│  • Create temp directory                                             │
│  • Write code files                                                  │
│  • docker build -t registry.example.com/{{appName}}:{{version}} .   │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Execute Command: Push to Private Registry                          │
│  • docker login registry.example.com                                │
│  • docker push registry.example.com/{{appName}}:{{version}}         │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Code: Generate Kubernetes Manifests                                │
│  • deployment.yaml                                                   │
│  • service.yaml                                                      │
│  • httproute.yaml                                                    │
│  • cloudflared-ingress.yaml                                          │
│  • ks.yaml (Flux Kustomization)                                      │
│  • kustomization.yaml                                                │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Git: Clone Repository                                               │
│  • Clone homelab repo                                                │
│  • Checkout main branch                                              │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Code: Write Manifests to Repository                                │
│  • Create apps/dynamic/{{appName}}/app/ directory                   │
│  • Write all YAML files                                              │
│  • Update apps/dynamic/kustomization.yaml                           │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Git: Commit Changes                                                 │
│  • git add .                                                         │
│  • git commit -m "Deploy {{appName}} via n8n automation"           │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Git: Push to Main                                                   │
│  • git push origin main                                              │
│  • Triggers Git webhook automatically                                │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Code: Wait for Deployment (Optional)                               │
│  • Poll Kubernetes API                                               │
│  • Check if deployment is ready                                      │
│  • Timeout after 2 minutes                                           │
└──────────────────────┬──────────────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Webhook Response: Return Success                                    │
│  • App name                                                          │
│  • App URL: https://{{appName}}.apps.example.com                    │
│  • Version                                                           │
│  • Deployment time                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### Key n8n Workflow Nodes

#### Node 1: Validate Input

```javascript
// Code Node
const input = $input.item.json;

// Validate required fields
if (!input.appType || !input.requirements) {
  throw new Error("Missing required fields: appType, requirements");
}

// Generate unique app name
const timestamp = Date.now();
const slug = input.appType.toLowerCase().replace(/[^a-z0-9]/g, '-');
const appName = `${slug}-${timestamp}`;
const version = input.version || 'v1';

return [{
  json: {
    appName,
    version,
    appType: input.appType,
    requirements: input.requirements,
    registryUrl: 'registry.example.com'
  }
}];
```

#### Node 2: Build Docker Image

```javascript
// Execute Command Node
const appName = $json.appName;
const version = $json.version;
const code = $json.generatedCode;  // From AI agent
const dockerfile = $json.generatedDockerfile;  // From AI agent

// Create temp build directory
const buildDir = `/tmp/n8n-builds/${appName}`;

const commands = `
mkdir -p ${buildDir}
cd ${buildDir}

# Write application code
cat > app.py <<'EOF'
${code}
EOF

# Write Dockerfile
cat > Dockerfile <<'EOF'
${dockerfile}
EOF

# Build image
docker build -t registry.example.com/${appName}:${version} .

# Clean up
cd /tmp
rm -rf ${buildDir}
`;

return {
  command: commands
};
```

#### Node 3: Push to Registry

```javascript
// Execute Command Node
const appName = $json.appName;
const version = $json.version;
const registryPassword = $credentials.registryPassword;

const commands = `
# Login to private registry
echo "${registryPassword}" | docker login registry.example.com -u n8n --password-stdin

# Push image
docker push registry.example.com/${appName}:${version}

# Logout
docker logout registry.example.com
`;

return {
  command: commands
};
```

#### Node 4: Generate Manifests

```javascript
// Code Node
const appName = $json.appName;
const version = $json.version;
const appPort = $json.appPort || 8080;

// deployment.yaml
const deployment = {
  apiVersion: "apps/v1",
  kind: "Deployment",
  metadata: {
    name: appName,
    namespace: "dynamic-apps",
    labels: {
      app: appName,
      "managed-by": "n8n"
    }
  },
  spec: {
    replicas: 1,
    selector: {
      matchLabels: {
        app: appName
      }
    },
    template: {
      metadata: {
        labels: {
          app: appName
        }
      },
      spec: {
        containers: [{
          name: appName,
          image: `registry.example.com/${appName}:${version}`,
          ports: [{
            containerPort: appPort
          }],
          resources: {
            requests: {
              memory: "128Mi",
              cpu: "100m"
            },
            limits: {
              memory: "512Mi",
              cpu: "500m"
            }
          },
          env: [
            // Add environment variables if needed
          ]
        }],
        // imagePullSecrets not needed - using default ServiceAccount
      }
    }
  }
};

// service.yaml
const service = {
  apiVersion: "v1",
  kind: "Service",
  metadata: {
    name: appName,
    namespace: "dynamic-apps"
  },
  spec: {
    selector: {
      app: appName
    },
    ports: [{
      port: 80,
      targetPort: appPort
    }],
    type: "ClusterIP"
  }
};

// httproute.yaml (Cilium Gateway)
const httproute = {
  apiVersion: "gateway.networking.k8s.io/v1",
  kind: "HTTPRoute",
  metadata: {
    name: appName,
    namespace: "dynamic-apps"
  },
  spec: {
    parentRefs: [{
      name: "cilium-gateway",
      namespace: "network"
    }],
    hostnames: [
      `${appName}.apps.example.com`
    ],
    rules: [{
      matches: [{
        path: {
          type: "PathPrefix",
          value: "/"
        }
      }],
      backendRefs: [{
        name: appName,
        port: 80
      }]
    }]
  }
};

// ks.yaml (Flux Kustomization)
const fluxKustomization = {
  apiVersion: "kustomize.toolkit.fluxcd.io/v1",
  kind: "Kustomization",
  metadata: {
    name: appName,
    namespace: "flux-system"
  },
  spec: {
    interval: "5m",
    path: `./kubernetes/rpi-cluster/apps/dynamic/${appName}/app`,
    prune: true,
    sourceRef: {
      kind: "GitRepository",
      name: "flux-system"
    },
    targetNamespace: "dynamic-apps",
    wait: true
  }
};

// kustomization.yaml
const kustomization = {
  apiVersion: "kustomize.config.k8s.io/v1beta1",
  kind: "Kustomization",
  resources: [
    "deployment.yaml",
    "service.yaml",
    "httproute.yaml"
  ]
};

const yaml = require('yaml');

return [{
  json: {
    appName,
    version,
    manifests: {
      "deployment.yaml": yaml.stringify(deployment),
      "service.yaml": yaml.stringify(service),
      "httproute.yaml": yaml.stringify(httproute),
      "ks.yaml": yaml.stringify(fluxKustomization),
      "kustomization.yaml": yaml.stringify(kustomization)
    },
    appUrl: `https://${appName}.apps.example.com`
  }
}];
```

#### Node 5: Commit and Push

This uses n8n's built-in Git nodes - configuration in UI.

---

## Implementation Steps

### Phase 1: Private Registry (Week 1)

1. **Deploy Docker Registry** following implementation above
2. **Configure Cloudflare Tunnel** to expose registry
3. **Create imagePullSecrets** for all relevant namespaces
4. **Test push/pull** from command line
5. **Configure n8n credentials** with registry password

### Phase 2: Flux Webhook Receiver (Week 1)

1. **Generate webhook token** and create SOPS secret
2. **Deploy Receiver** resource
3. **Expose via Cloudflare Tunnel**
4. **Configure Git webhook** (GitHub/GitLab)
5. **Test webhook** by pushing to repo manually
6. **Monitor logs** to verify immediate reconciliation

### Phase 3: n8n Workflow Development (Week 2-3)

1. **Create base workflow** with all nodes
2. **Test image build & push** independently
3. **Test manifest generation** independently
4. **Test Git commit & push** independently
5. **Test full workflow** end-to-end
6. **Add error handling** and retries
7. **Add monitoring** and notifications

### Phase 4: Integration Testing (Week 4)

1. **Deploy test app** via n8n workflow
2. **Verify deployment time** (should be ~15-30 seconds)
3. **Verify app accessibility** via Cloudflare Tunnel
4. **Test multiple deployments** simultaneously
5. **Test cleanup** (deleting apps)
6. **Load testing** (if needed)

### Phase 5: Documentation & Hardening (Week 5)

1. **Document n8n workflows** for team
2. **Create app templates** for common types
3. **Implement monitoring dashboards**
4. **Set up alerts** for failed deployments
5. **Backup strategy** for registry images
6. **Security audit** of full system

---

## Answers to Your Questions

### 1. Domain
**Question**: What domain will be used?

**Answer Needed**: Please provide your domain name (must be on Cloudflare).

**Example**: `example.com`

**Subdomains will be:**
- `n8n.example.com` - n8n UI
- `registry.example.com` - Docker registry
- `flux-webhook.example.com` - Flux webhook receiver
- `*.apps.example.com` - Dynamic webapps

### 2. Subdomains for Dynamic Apps
**Question**: Naming convention for dynamic apps?

**Recommended**: `*.apps.example.com`

**Example**: `my-webapp-123.apps.example.com`

**Alternative**: `*.example.com` (less organized)

### 3. Authentication
**Question**: Should all apps require authentication?

**Recommended Strategy:**
- **n8n**: Cloudflare Access required (admin only)
- **Registry**: HTTP Basic Auth (htpasswd)
- **Flux Webhook**: HMAC signature validation
- **Grafana**: Cloudflare Access required (admin only)
- **Homepage**: Public (or optional auth)
- **Dynamic Apps**: Public by default, optional per-app auth policies

### 4. Rate Limits
**Question**: What rate limits are appropriate?

**Recommended:**
- **n8n webhooks**: 100 requests/10 minutes per IP
- **Flux webhook**: No limit (internal use)
- **Dynamic apps**: 1000 requests/10 minutes per IP (configurable per app)
- **Registry**: 1000 requests/hour (Docker pulls/pushes)

**Configure in Cloudflare Dashboard → Security → Rate Limiting**

### 5. Monitoring
**Question**: What metrics and alerts are critical?

**Critical Metrics:**
1. **n8n**:
   - Workflow execution success rate
   - Workflow execution time
   - Failed workflows (alert immediately)
2. **Flux**:
   - Reconciliation failures (alert)
   - Kustomization health status
3. **Registry**:
   - Storage usage (alert at 80%)
   - Push/pull failure rate
4. **Dynamic Apps**:
   - Pod crash loops (alert)
   - Resource usage (CPU/memory)
5. **Cloudflare Tunnel**:
   - Tunnel uptime
   - Request rate and errors

**Already have Prometheus + Grafana** - create custom dashboards for above.

### 6. Backup Strategy
**Question**: Where should PostgreSQL backups be stored?

**Recommended: Rook-Ceph (internal)**

**Reasons:**
1. Already deployed and available
2. Automatic replication
3. No external cost
4. Low latency

**Configuration:**
```yaml
# CloudNativePG cluster backup
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://ceph-backups/
      s3Credentials:
        # Use Ceph RGW S3-compatible API
      wal:
        compression: gzip
      data:
        compression: gzip
    retentionPolicy: "30d"
```

**Alternative: External S3** (if Ceph fails)
- AWS S3
- Backblaze B2 (cheaper)
- Wasabi (cheaper)

---

## Summary

### Key Improvements

1. **✅ Immediate Reconciliation**: Flux webhook receiver reduces deployment time from 5-10 minutes to 15-30 seconds
2. **✅ Private Registry**: Docker Registry v2 provides secure, in-cluster image storage with minimal resource usage
3. **✅ Complete Workflow**: Updated n8n workflow includes all steps from code generation to deployment
4. **✅ Security**: Zero-trust architecture maintained throughout

### Total Costs

| Component | Cost |
|-----------|------|
| Cloudflare Tunnel | FREE |
| Domain | $10-15/year |
| **Total** | **$10-15/year** |

### Deployment Timeline

**With webhook receiver**: **~15-30 seconds**
1. n8n workflow execution: 5-10 seconds
2. Git push + webhook: < 1 second
3. Flux reconciliation: 5-10 seconds
4. Pod startup: 5-10 seconds

**Without webhook receiver**: **5-10 minutes** (waiting for reconciliation interval)

### Next Steps

1. Review this addendum
2. Provide answers to remaining questions
3. Proceed with Phase 1 implementation (Private Registry)
4. Proceed with Phase 2 implementation (Webhook Receiver)

---

## References

- [Flux Webhook Receivers](https://fluxcd.io/docs/guides/webhook-receivers/)
- [Docker Registry v2](https://docs.docker.com/registry/)
- [Twuni Docker Registry Helm Chart](https://github.com/twuni/docker-registry.helm)
- [Harbor Project](https://goharbor.io/)
