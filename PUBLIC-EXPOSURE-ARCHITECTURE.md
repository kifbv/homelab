# Public Exposure Architecture for Homelab

**Status**: Architecture Design
**Goal**: Securely expose homelab applications to the public internet with zero-trust security model
**Primary Use Case**: n8n-driven GitOps workflow for dynamic webapp deployment

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Requirements Analysis](#requirements-analysis)
3. [Solution Comparison](#solution-comparison)
4. [Recommended Architecture](#recommended-architecture)
5. [n8n GitOps Integration](#n8n-gitops-integration)
6. [Implementation Roadmap](#implementation-roadmap)
7. [Security Considerations](#security-considerations)
8. [Cost Analysis](#cost-analysis)

---

## Executive Summary

### Recommended Solution: **Cloudflare Tunnel (Zero Trust)**

**Primary Reasons:**
1. **Works with any ISP setup** - No need for static IP, port forwarding, or DDNS
2. **Zero-trust security model** - No inbound ports open on your network
3. **Free tier available** - Sufficient for homelab use
4. **Native Kubernetes integration** - Helm chart available
5. **Built-in DDoS protection** - Cloudflare's global network
6. **Automatic TLS termination** - Let's Encrypt integration
7. **Access policies** - Fine-grained authentication and authorization

**Architecture Flow:**
```
Internet Users
      ↓
Cloudflare Global Network (TLS termination, DDoS protection)
      ↓
Cloudflare Tunnel (outbound connection from cluster)
      ↓
Cilium Gateway (internal routing)
      ↓
Kubernetes Services (n8n, dynamic webapps, etc.)
```

---

## Requirements Analysis

### Current State
- **Network**: Uncertain ISP situation (Digi Romania)
  - DDNS available but not reliable
  - Static IP possible but requires cost and unclear availability
  - Likely behind some form of NAT
- **Cluster**: Kubernetes on Raspberry Pi 5
  - Cilium CNI with Gateway API
  - Flux GitOps for continuous delivery
  - cert-manager with Let's Encrypt
  - CloudNativePG for PostgreSQL

### Requirements
1. **Security**: Maximum security (zero-trust model preferred)
2. **Exposure Scope**:
   - n8n full UI (workflow editor and interface)
   - Selected existing apps (Homepage, Linkding, Prometheus/Grafana)
   - Dynamically deployed webapps (created by n8n workflows)
3. **Deployment Model**: GitOps-first
   - n8n commits manifests to Git repository
   - Flux automatically deploys to cluster
   - Maintains audit trail and rollback capability
4. **Reliability**: Work independent of ISP limitations

---

## Solution Comparison

### Option 1: Cloudflare Tunnel (RECOMMENDED)

**Pros:**
- ✅ Zero-trust architecture - no inbound firewall rules needed
- ✅ Works behind CGNAT, dynamic IP, or any NAT configuration
- ✅ Free tier: Up to 50 users, unlimited bandwidth
- ✅ Cloudflare's global CDN and DDoS protection
- ✅ Native Kubernetes integration via Helm chart
- ✅ Built-in access policies (authentication, IP restrictions, country blocks)
- ✅ Automatic TLS certificate management
- ✅ WebSocket support (critical for n8n)
- ✅ Can route to internal Kubernetes services via DNS
- ✅ Multi-tunnel support for high availability

**Cons:**
- ⚠️ Requires Cloudflare account and domain on Cloudflare DNS
- ⚠️ All traffic routed through Cloudflare (privacy consideration)
- ⚠️ Free tier limited to 50 authenticated users (not an issue for homelab)

**Cost:** **FREE** (for homelab use case)

**Kubernetes Integration:**
```yaml
# Uses cloudflared Helm chart
# Ingress rules defined in values.yaml
# Routes to Kubernetes services via cluster DNS
```

### Option 2: Tailscale Funnel

**Pros:**
- ✅ Zero-trust WireGuard-based VPN
- ✅ Very secure peer-to-peer encryption
- ✅ Easy setup and management
- ✅ Works behind CGNAT/NAT
- ✅ "Funnel" feature allows public exposure of specific services
- ✅ Free tier: 1 user, 20 devices

**Cons:**
- ⚠️ Funnel feature requires Tailscale subnet router on cluster
- ⚠️ Free tier very limited (20 devices max, 1 user)
- ⚠️ Not designed primarily for public exposure (more for VPN access)
- ⚠️ Funnel is in beta and has limitations
- ⚠️ Requires Tailscale client for private access (not suitable for public webapps)

**Cost:** **FREE** for limited use, **$6/user/month** for Teams (needed for multi-user)

**Use Case:** Better suited for private access to homelab rather than public webapp hosting

### Option 3: Traditional Reverse Proxy (Nginx on VPS)

**Pros:**
- ✅ Full control over traffic routing
- ✅ No third-party dependency for traffic path
- ✅ Flexible configuration

**Cons:**
- ⚠️ Requires VPS rental ($5-10/month minimum)
- ⚠️ Requires VPN tunnel from homelab to VPS (WireGuard, etc.)
- ⚠️ Additional complexity and maintenance
- ⚠️ Single point of failure (VPS)
- ⚠️ No built-in DDoS protection
- ⚠️ Must manage TLS certificates manually or with cert-manager on VPS
- ⚠️ Latency overhead (homelab → VPS → internet)

**Cost:** **$5-10/month** for VPS

### Comparison Matrix

| Feature | Cloudflare Tunnel | Tailscale Funnel | VPS Reverse Proxy |
|---------|------------------|------------------|-------------------|
| **Zero Trust** | ✅ Yes | ✅ Yes | ⚠️ Manual |
| **Works behind CGNAT** | ✅ Yes | ✅ Yes | ⚠️ Requires VPN |
| **Public webapp hosting** | ✅ Excellent | ⚠️ Limited | ✅ Good |
| **DDoS Protection** | ✅ Built-in | ❌ No | ❌ No |
| **TLS Management** | ✅ Automatic | ⚠️ Limited | ⚠️ Manual |
| **Kubernetes Integration** | ✅ Native Helm | ⚠️ Beta | ⚠️ Manual |
| **Free Tier** | ✅ Generous | ⚠️ Very Limited | ❌ None |
| **Cost** | **FREE** | **$6/user/month** | **$5-10/month** |
| **Complexity** | 🟢 Low | 🟡 Medium | 🔴 High |
| **Maintenance** | 🟢 Low | 🟡 Medium | 🔴 High |

**Winner:** **Cloudflare Tunnel** - Best balance of security, features, cost, and ease of use

---

## Recommended Architecture

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Internet / Public Users                       │
└──────────────────────────┬───────────────────────────────────────────┘
                           │
                           ↓
┌──────────────────────────────────────────────────────────────────────┐
│              Cloudflare Global Network (Edge)                         │
│  • TLS Termination (Let's Encrypt)                                   │
│  • DDoS Protection & WAF                                             │
│  • Access Policies (Zero Trust)                                      │
│  • CDN & Caching                                                     │
└──────────────────────────┬───────────────────────────────────────────┘
                           │
                           │ Outbound HTTPS Connection
                           │ (initiated from cluster)
                           ↓
┌──────────────────────────────────────────────────────────────────────┐
│                    Raspberry Pi 5 Kubernetes Cluster                  │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  cloudflared (DaemonSet or Deployment)                          │ │
│  │  • Maintains persistent tunnel to Cloudflare                    │ │
│  │  • Routes traffic to internal services                          │ │
│  │  • Configuration in Kubernetes ConfigMap                        │ │
│  └────────────────────────┬───────────────────────────────────────┘ │
│                           ↓                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  Cilium Gateway (Network)                                       │ │
│  │  • Internal routing via HTTPRoute resources                     │ │
│  │  • Service mesh capabilities                                    │ │
│  └────────────────────────┬───────────────────────────────────────┘ │
│                           ↓                                           │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  Application Services                                           │ │
│  │  ┌─────────────────────────────────────────────────────────┐   │ │
│  │  │  n8n                                                      │   │ │
│  │  │  • Workflow automation                                    │   │ │
│  │  │  • Git integration for commits                           │   │ │
│  │  │  • PostgreSQL backend (CloudNativePG)                    │   │ │
│  │  │  • Webhooks for external triggers                        │   │ │
│  │  └─────────────────────────────────────────────────────────┘   │ │
│  │  ┌─────────────────────────────────────────────────────────┐   │ │
│  │  │  Existing Apps (Homepage, Linkding, Grafana, etc.)       │   │ │
│  │  └─────────────────────────────────────────────────────────┘   │ │
│  │  ┌─────────────────────────────────────────────────────────┐   │ │
│  │  │  Dynamic Webapps (deployed by n8n)                       │   │ │
│  │  └─────────────────────────────────────────────────────────┘   │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │  Flux GitOps                                                    │ │
│  │  • Watches Git repository                                       │ │
│  │  • Automatically applies manifests                             │ │
│  │  • Creates HTTPRoutes for new apps                             │ │
│  └────────────────────────────────────────────────────────────────┘ │
└───────────────────────────┬───────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────────────────┐
│              Git Repository (GitHub/GitLab)                           │
│  • n8n commits new app manifests                                     │
│  • Flux reconciles and deploys                                       │
│  • Full audit trail                                                  │
└──────────────────────────────────────────────────────────────────────┘
```

### Components Breakdown

#### 1. Cloudflare Tunnel (cloudflared)

**Deployment Method:** Kubernetes Deployment or DaemonSet via Helm

**Helm Chart:** `community-charts/cloudflared`

**Key Features:**
- Runs cloudflared daemon inside cluster
- Maintains outbound HTTPS tunnel to Cloudflare
- No inbound firewall rules needed
- Routes traffic based on ingress rules

**Example Configuration:**
```yaml
# apps/network/cloudflared/app/release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cloudflared
  namespace: network
spec:
  chart:
    spec:
      chart: cloudflared
      version: 0.x.x
      sourceRef:
        kind: HelmRepository
        name: community-charts
        namespace: flux-system
  interval: 1h
  values:
    replicaCount: 2  # High availability

    ###Question: Base64-encoded does not sound very secure, shouldn't these be references to SOPS-encrypted k8s secrets? This is what you seem to suggest below in the Implementation Roadmap (Phase 1, Step 2)
    tunnelSecrets:
      # Base64-encoded tunnel credentials from Cloudflare
      base64EncodedConfigJsonFile: ${CLOUDFLARE_TUNNEL_CREDENTIALS}
      base64EncodedCertPemFile: ${CLOUDFLARE_TUNNEL_CERT}

    ingress:
      # Route n8n.example.com to n8n service
      - hostname: n8n.example.com
        service: http://n8n.home.svc.cluster.local:5678

      # Route homepage.example.com to homepage service
      - hostname: homepage.example.com
        service: http://homepage.home.svc.cluster.local:3000

      # Route linkding.example.com to linkding service
      - hostname: linkding.example.com
        service: http://linkding.home.svc.cluster.local:9090

      # Route grafana.example.com to Grafana
      - hostname: grafana.example.com
        service: http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80

      # Wildcard for dynamic apps
      - hostname: "*.apps.example.com"
        service: http://cilium-gateway.network.svc.cluster.local:80

      # Catch-all
      - service: http_status:404
```

#### 2. n8n Workflow Automation

**Deployment Method:** Helm Chart (8gears/n8n-helm-chart)

**Key Configurations:**
- **Queue Mode**: Enabled with Redis for scalability
- **PostgreSQL**: CloudNativePG cluster (already configured)
- **Git Integration**: n8n workflows commit manifests to Git
- **Webhooks**: Receive external events

**Architecture for n8n:**
```yaml
# apps/automation/n8n/app/release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: n8n
  namespace: automation
spec:
  chart:
    spec:
      chart: n8n
      version: 0.x.x
      sourceRef:
        kind: HelmRepository
        name: 8gears
        namespace: flux-system
  interval: 1h
  values:
    # PostgreSQL connection
    database:
      type: postgresdb
      postgresdb:
        host: postgres-cluster-rw.datastore.svc.cluster.local
        port: 5432
        database: n8n
        user: n8n
        # Password from secret
        existingSecret: n8n-postgres-credentials
        existingSecretPasswordKey: password

    # Encryption key for credentials
    encryption:
      existingSecret: n8n-encryption-key

    # External access URL
    config:
      generic:
        ###Question: is there a way to use secrets for the timezone, WEBHOOK_URL and N8N_EDITOR_BASE_URL? even is the site will be public i'd prefer not to have these informations in clear in my public github repo. For instance, is it possible to have only the leftmost part of the url in the config files and transform it into the full url with a PrefixSuffixTransformer kustomization? Same question for the n8n generated manifests.
        timezone: Europe/Bucharest
        WEBHOOK_URL: https://n8n.example.com
        N8N_EDITOR_BASE_URL: https://n8n.example.com

    # Persistence for workflows
    persistence:
      enabled: true
      storageClass: rook-ceph-block
      size: 10Gi

    # Service configuration
    service:
      type: ClusterIP
      port: 5678

    # Resources
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "2Gi"
        cpu: "1000m"
```

#### 3. Dynamic App Deployment Flow

**Step-by-Step Process:**

1. **User triggers n8n workflow** (e.g., via webhook, schedule, or manual trigger)

2. **AI Agent generates webapp code** (handled by n8n workflow)

3. **n8n workflow commits Kubernetes manifests to Git:**
   ```yaml
   # Example: apps/dynamic/my-webapp-123/app/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
     - httproute.yaml  # For Cilium Gateway
     - cloudflared-ingress.yaml  # For Cloudflare Tunnel
   ```

4. **Flux detects Git change** (within reconciliation interval, typically 1-10 minutes)

5. **Flux applies manifests to cluster:**
   - Creates Deployment
   - Creates Service
   - Creates HTTPRoute (Cilium Gateway)
   - Updates Cloudflared ingress configuration

6. **Cloudflare Tunnel automatically picks up new route:**
   - New subdomain (e.g., `my-webapp-123.apps.example.com`) routes to service
   - TLS certificate auto-provisioned by Cloudflare
   - App is now publicly accessible

**Example Workflow Commit Structure:**
```
apps/dynamic/
├── my-webapp-123/
│   ├── ks.yaml                    # Flux Kustomization
│   └── app/
│       ├── kustomization.yaml
│       ├── deployment.yaml        # Pod specification
│       ├── service.yaml           # ClusterIP service
│       └── cloudflared-ingress.yaml  # Cloudflared ingress rule
└── another-app-456/
    └── ...
```

---

## n8n GitOps Integration

### Git Commit Workflow (n8n → Git → Flux → Kubernetes)

**n8n Workflow Components:**

1. **Trigger Node**: Webhook, Schedule, or Manual
2. **AI Agent Nodes**: Generate webapp code (your custom implementation)
3. **Code Node**: Generate Kubernetes manifests (YAML)
4. **Git Node**: Commit and push to repository
5. **HTTP Request Node**: Notify Flux to reconcile immediately

**Example n8n Workflow Structure:**

```
[Webhook Trigger]
       ↓
[OpenAI/Custom Agent: Generate Webapp Code]
       ↓
[Code Node: Generate K8s Manifests]
       ↓
[Git Node: Clone Repository]
       ↓
[Code Node: Write Files to Repo]
       ↓
[Git Node: Commit and Push]
       ↓
[HTTP Request: Trigger Flux Reconciliation]
       ↓
[Webhook Response: Success]
```

### n8n Git Node Configuration

**Setup Requirements:**

1. **Git Credentials in n8n:**
   - Use SSH key or Personal Access Token
   - Store in n8n credentials manager

2. **Repository Structure:**
   ```
   homelab/
   ├── kubernetes/
   │   └── rpi-cluster/
   │       ├── apps/
   │       │   └── dynamic/  ← n8n writes here
   │       │       ├── kustomization.yaml  ← Updated by n8n
   │       │       └── <app-name>/
   │       │           ├── ks.yaml
   │       │           └── app/
   │       │               ├── kustomization.yaml
   │       │               ├── deployment.yaml
   │       │               ├── service.yaml
   │       │               └── cloudflared-ingress.yaml
   ```

3. **n8n Workflow Logic:**

```javascript
// Code Node: Generate Kubernetes Manifests
const appName = $input.item.json.appName;  // e.g., "my-webapp-123"
const appImage = $input.item.json.appImage;  // e.g., "registry/my-webapp:v1"
const appPort = $input.item.json.appPort || 8080;

// Generate deployment.yaml
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
          image: appImage,
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
          }
        }]
      }
    }
  }
};

// Generate service.yaml
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

// Generate cloudflared-ingress.yaml
const cloudflaredIngress = {
  apiVersion: "v1",
  kind: "ConfigMap",
  metadata: {
    name: `${appName}-cloudflared-ingress`,
    namespace: "network",
    labels: {
      "app.kubernetes.io/managed-by": "n8n-automation"
    }
  },
  data: {
    ingress: `
    - hostname: ${appName}.apps.example.com
      service: http://${appName}.dynamic-apps.svc.cluster.local:80
    `
  }
};

// Generate ks.yaml (Flux Kustomization)
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

// Generate kustomization.yaml
const kustomization = {
  apiVersion: "kustomize.config.k8s.io/v1beta1",
  kind: "Kustomization",
  resources: [
    "deployment.yaml",
    "service.yaml",
    "cloudflared-ingress.yaml"
  ]
};

// Return all manifests
return [{
  json: {
    appName,
    manifests: {
      "deployment.yaml": deployment,
      "service.yaml": service,
      "cloudflared-ingress.yaml": cloudflaredIngress,
      "ks.yaml": fluxKustomization,
      "kustomization.yaml": kustomization
    }
  }
}];
```

4. **Git Node: Commit and Push**

```javascript
// Git Node configuration in n8n
{
  "operation": "push",
  "repositoryPath": "/tmp/homelab-repo",  // n8n clones here
  "branch": "main",
  "commitMessage": `Deploy ${appName} via n8n automation\n\nGenerated by n8n workflow\nTimestamp: ${new Date().toISOString()}`,
  "files": [
    {
      "path": `kubernetes/rpi-cluster/apps/dynamic/${appName}/app/deployment.yaml`,
      "content": "{{ $json.manifests['deployment.yaml'] }}"
    },
    {
      "path": `kubernetes/rpi-cluster/apps/dynamic/${appName}/app/service.yaml`,
      "content": "{{ $json.manifests['service.yaml'] }}"
    },
    // ... other files
  ]
}
```

5. **Update Parent Kustomization:**

n8n also needs to update `apps/dynamic/kustomization.yaml` to include the new app:

```yaml
# apps/dynamic/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - my-webapp-123/ks.yaml  ← Added by n8n
  - another-app-456/ks.yaml
```

### Flux Reconciliation

**Automatic Reconciliation:**
- Flux checks Git repository every `interval` (typically 5-10 minutes)
- Detects new commits
- Applies manifests to cluster
- Cloudflare Tunnel automatically routes new hostname

**Immediate Reconciliation:**

###Question: is Flux notification controller already exposed? i.e. can we POST to that url?
n8n can trigger immediate reconciliation via Flux API:

```javascript
// HTTP Request Node in n8n
{
  "method": "POST",
  "url": "http://notification-controller.flux-system.svc.cluster.local/",
  "body": {
    "kind": "Kustomization",
    "name": "cluster-apps",
    "namespace": "flux-system"
  },
  "headers": {
    "Content-Type": "application/json"
  }
}
```

Or via `kubectl` (if n8n has cluster access):

```bash
kubectl annotate kustomization cluster-apps \
  -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" \
  --overwrite
```

---

## Implementation Roadmap

### Phase 1: Cloudflare Tunnel Setup (Week 1)

**Prerequisites:**
1. **Cloudflare Account**: Sign up at cloudflare.com
2. **Domain**: Add your domain to Cloudflare and update nameservers
3. **Cloudflare Tunnel**: Create tunnel via Cloudflare dashboard or CLI

**Steps:**

1. **Create Cloudflare Tunnel:**
   ```bash
   # Install cloudflared CLI locally
   brew install cloudflare/cloudflare/cloudflared  # macOS
   # OR
   wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
   sudo dpkg -i cloudflared-linux-amd64.deb  # Linux

   # Authenticate
   cloudflared tunnel login

   # Create tunnel
   cloudflared tunnel create homelab-rpi

   # This generates:
   # - Tunnel UUID (e.g., 6ff42ae2-765d-4adf-8112-31c55c1551ef)
   # - Credentials file: ~/.cloudflared/<uuid>.json
   # - Certificate: ~/.cloudflared/cert.pem
   ```

2. **Store Tunnel Credentials in SOPS Secret:**
   ```yaml
   # flux/settings/cloudflare-tunnel.sops.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cloudflare-tunnel-credentials
     namespace: flux-system
   type: Opaque
   stringData:
     credentials.json: |
       <base64-encode-content-of-uuid.json>
     cert.pem: |
       <base64-encode-content-of-cert.pem>
   ```

   Encrypt with SOPS:
   ```bash
   sops --encrypt --in-place flux/settings/cloudflare-tunnel.sops.yaml
   ```

3. **Create HelmRepository:**
   ```yaml
   # flux/repositories/community-charts.yaml
   ---
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata:
     name: community-charts
     namespace: flux-system
   spec:
     interval: 1h
     url: https://community-charts.github.io/helm-charts
   ```

4. **Deploy cloudflared via Flux:**

   Create directory structure:
   ```
   infrastructure/network/cloudflared/
   ├── ks.yaml
   └── app/
       ├── kustomization.yaml
       └── release.yaml
   ```

   **infrastructure/network/cloudflared/ks.yaml:**
   ```yaml
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: cloudflared
     namespace: flux-system
   spec:
     interval: 10m
     path: "./kubernetes/rpi-cluster/infrastructure/network/cloudflared/app"
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
     wait: true
     decryption:
       provider: sops
       secretRef:
         name: flux-sops
     postBuild:
       substituteFrom:
         - kind: Secret
           name: cloudflare-tunnel-credentials
   ```

   **infrastructure/network/cloudflared/app/release.yaml:**
   ```yaml
   ---
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: cloudflared
     namespace: network
   spec:
     chart:
       spec:
         chart: cloudflared
         version: 0.3.x
         sourceRef:
           kind: HelmRepository
           name: community-charts
           namespace: flux-system
     interval: 1h
     values:
       replicaCount: 2

       tunnelSecrets:
         base64EncodedConfigJsonFile: ${CLOUDFLARE_TUNNEL_CREDENTIALS_JSON}
         base64EncodedCertPemFile: ${CLOUDFLARE_TUNNEL_CERT_PEM}

       ingress:
         # Start with existing apps
         - hostname: homepage.example.com
           service: http://homepage.home.svc.cluster.local:3000

         - hostname: linkding.example.com
           service: http://linkding.home.svc.cluster.local:9090

         - hostname: grafana.example.com
           service: http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80

         # Catch-all
         - service: http_status:404
   ```

5. **Configure DNS in Cloudflare:**
   - Go to Cloudflare Dashboard → your domain → DNS
   - Create CNAME records pointing to your tunnel:
     ```
     homepage.example.com  → CNAME → <tunnel-id>.cfargotunnel.com
     linkding.example.com  → CNAME → <tunnel-id>.cfargotunnel.com
     grafana.example.com   → CNAME → <tunnel-id>.cfargotunnel.com
     ```

6. **Test Access:**
   ```bash
   curl https://homepage.example.com
   curl https://linkding.example.com
   ```

### Phase 2: n8n Deployment (Week 2)

**Steps:**

1. **Create PostgreSQL Database for n8n:**

   Follow the pattern from GITOPS.md:

   **apps/datastore/cloudnative-pg/clusters/postgres-example.yaml** (add managed role):
   ```yaml
   spec:
     managed:
       roles:
         - name: n8n
           ensure: present
           login: true
           passwordSecret:
             name: n8n-postgres-credentials
   ```

   **apps/datastore/cloudnative-pg/clusters/credentials-n8n.sops.yaml:**
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: n8n-postgres-credentials
     namespace: datastore
   type: kubernetes.io/basic-auth
   stringData:
     username: n8n
     password: <strong-random-password>
   ```

   **apps/datastore/cloudnative-pg/clusters/database-n8n.yaml:**
   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Database
   metadata:
     name: n8n-db
     namespace: datastore
   spec:
     name: n8n
     owner: n8n
     cluster:
       name: postgres-cluster
     ensure: present
   ```

   Encrypt and add to kustomization.

2. **Create n8n Namespace and Secrets:**

   ```yaml
   # apps/automation/namespace.yaml
   ---
   apiVersion: v1
   kind: Namespace
   metadata:
     name: automation
   ```

   ```yaml
   # apps/automation/n8n/app/postgres-credentials.sops.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: n8n-postgres-credentials
     namespace: automation
   type: kubernetes.io/basic-auth
   stringData:
     username: n8n
     password: <same-password-as-datastore>
   ```

   ```yaml
   # apps/automation/n8n/app/n8n-secrets.sops.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: n8n-encryption-key
     namespace: automation
   type: Opaque
   stringData:
     encryptionKey: <generate-strong-32-char-key>
   ```

   ```yaml
   # apps/automation/n8n/app/n8n-git-credentials.sops.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: n8n-git-credentials
     namespace: automation
   type: Opaque
   stringData:
     sshPrivateKey: |
       -----BEGIN OPENSSH PRIVATE KEY-----
       <your-ssh-private-key-for-git>
       -----END OPENSSH PRIVATE KEY-----
   ```

3. **Add HelmRepository for n8n:**

   ```yaml
   # flux/repositories/8gears.yaml
   ---
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata:
     name: 8gears
     namespace: flux-system
   spec:
     interval: 1h
     url: https://8gears.container-registry.com/chartrepo/library
   ```

4. **Deploy n8n:**

   **apps/automation/n8n/ks.yaml:**
   ```yaml
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: n8n
     namespace: flux-system
   spec:
     decryption:
       provider: sops
       secretRef:
         name: flux-sops
     dependsOn:
       - name: rook-ceph-rbd
       - name: cloudnative-pg-clusters
       - name: cloudflared
     interval: 1h
     path: ./kubernetes/rpi-cluster/apps/automation/n8n/app
     prune: true
     retryInterval: 2m
     sourceRef:
       kind: GitRepository
       name: flux-system
     targetNamespace: automation
     timeout: 5m
     wait: true
   ```

   **apps/automation/n8n/app/release.yaml:**
   ```yaml
   ---
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: n8n
     namespace: automation
   spec:
     chart:
       spec:
         chart: n8n
         version: 0.32.x
         sourceRef:
           kind: HelmRepository
           name: 8gears
           namespace: flux-system
     interval: 1h
     values:
       config:
         database:
           type: postgresdb
           postgresdb:
             host: postgres-cluster-rw.datastore.svc.cluster.local
             port: 5432
             database: n8n
             user: n8n
             existingSecret: n8n-postgres-credentials
             existingSecretPasswordKey: password

         encryption:
           existingSecret: n8n-encryption-key
           existingSecretKey: encryptionKey

         generic:
           timezone: "Europe/Bucharest"

         executions:
           pruneData: "true"
           pruneDataMaxAge: "336"  # 2 weeks

       persistence:
         enabled: true
         storageClass: rook-ceph-block
         size: 10Gi

       service:
         type: ClusterIP
         port: 5678

       resources:
         requests:
           memory: "512Mi"
           cpu: "250m"
         limits:
           memory: "2Gi"
           cpu: "1000m"
   ```

5. **Add n8n to Cloudflared Ingress:**

   Update `infrastructure/network/cloudflared/app/release.yaml`:
   ```yaml
   ingress:
     - hostname: n8n.example.com
       service: http://n8n.automation.svc.cluster.local:5678

     # ... existing rules ...
   ```

6. **Configure Cloudflare DNS:**
   ```
   n8n.example.com → CNAME → <tunnel-id>.cfargotunnel.com
   ```

7. **Access n8n:**
   - Visit `https://n8n.example.com`
   - Complete initial setup wizard

### Phase 3: n8n GitOps Workflows (Week 3-4)

**Steps:**

1. **Configure Git Access in n8n:**
   - Go to n8n UI → Settings → Credentials
   - Add new SSH credential
   - Paste SSH private key
   - Test connection to your Git repository

2. **Create n8n Workflow: "Deploy Dynamic Webapp"**

   **Nodes:**
   1. **Webhook Trigger** (receives deploy request)
   2. **Code Node**: Validate input
   3. **OpenAI/Agent Node**: Generate webapp code (your AI agent)
   4. **Code Node**: Build container image (or use pre-built)
   5. **Code Node**: Generate Kubernetes manifests
   6. **Git Clone Node**: Clone homelab repository
   7. **Code Node**: Write manifest files to repo
   8. **Code Node**: Update parent kustomization.yaml
   9. **Git Commit Node**: Commit changes
   10. **Git Push Node**: Push to main branch
   11. **HTTP Request Node**: Trigger Flux reconciliation
   12. **Webhook Response**: Return success with app URL

3. **Create Directory Structure for Dynamic Apps:**

   ```yaml
   # apps/dynamic/namespace.yaml
   ---
   apiVersion: v1
   kind: Namespace
   metadata:
     name: dynamic-apps
   ```

   ```yaml
   # apps/dynamic/kustomization.yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - namespace.yaml
     # New apps will be added here by n8n
   ```

   Register in parent:
   ```yaml
   # apps/kustomization.yaml
   resources:
     - home/
     - monitoring/
     - datastore/
     - automation/
     - dynamic/kustomization.yaml  # Add this
   ```

4. **Configure Wildcard DNS for Dynamic Apps:**

   In Cloudflare DNS:
   ```
   *.apps.example.com → CNAME → <tunnel-id>.cfargotunnel.com
   ```

   Update cloudflared ingress:
   ```yaml
   ingress:
     # ... existing rules ...

     # Wildcard for dynamic apps
     - hostname: "*.apps.example.com"
       service: http://cilium-gateway.network.svc.cluster.local:80

     - service: http_status:404
   ```

5. **Test Deployment:**
   - Trigger n8n workflow via webhook
   - Monitor n8n execution log
   - Check Git repository for new commits
   - Watch Flux reconciliation: `flux get kustomizations -A`
   - Verify app deployment: `kubectl get pods -n dynamic-apps`
   - Access app: `https://my-webapp-123.apps.example.com`

### Phase 4: Access Policies & Security Hardening (Week 5)

**Steps:**

1. **Enable Cloudflare Access (Zero Trust):**

   - Go to Cloudflare Dashboard → Zero Trust
   - Create Access Application for n8n:
     ```
     Application name: n8n
     Session Duration: 24 hours
     Application domain: n8n.example.com
     ```

   - Create Access Policy:
     ```
     Policy name: Allow specific emails
     Action: Allow
     Include: Emails ending in @yourdomain.com
     ```

2. **Configure Access for Other Apps:**
   - Repeat for Grafana (admin access only)
   - Homepage can remain public or require authentication
   - Dynamic apps: Create policy based on requirements

3. **Enable WAF (Web Application Firewall):**
   - Go to Cloudflare Dashboard → Security → WAF
   - Enable OWASP Core Ruleset
   - Enable Cloudflare Managed Ruleset

4. **Rate Limiting:**
   - Create rate limiting rule for n8n webhooks
   - Limit: 100 requests/10 minutes per IP

5. **Enable DDoS Protection:**
   - Cloudflare provides automatic DDoS protection
   - Configure sensitivity in Dashboard → Security → DDoS

6. **Configure RBAC for n8n:**
   - In n8n, create service account for automation
   - Limit permissions to only what's needed for Git operations

---

## Security Considerations

### 1. Network Security

**Zero Trust Architecture:**
- ✅ No inbound ports open on homelab network
- ✅ All connections initiated outbound (homelab → Cloudflare)
- ✅ Cloudflare validates all incoming requests
- ✅ TLS encryption end-to-end

**Firewall Rules:**
```
Inbound: DENY ALL
Outbound: ALLOW https (443) to Cloudflare IPs
```

### 2. Authentication & Authorization

**Cloudflare Access:**
- Multi-factor authentication (MFA) support
- Email-based authentication
- Google/GitHub OAuth integration
- IP restrictions
- Country blocks

**n8n Security:**
- Enable user authentication
- Use strong encryption key
- Rotate credentials regularly
- Service account for Git operations with minimal permissions

**Dynamic Apps:**
- Consider requiring authentication by default
- Use Cloudflare Access policies per app
- Implement API keys for programmatic access

### 3. Secrets Management

**Current: SOPS + age encryption**
- ✅ All secrets encrypted in Git
- ✅ Decrypted only in-cluster by Flux
- ✅ Age private key stored securely on control plane

**n8n Credentials:**
- Store Git SSH keys in n8n credentials manager
- Use dedicated SSH key for n8n (not personal key)
- Rotate keys periodically

**Best Practices:**
- Never commit plaintext secrets
- Use different passwords for each component
- Implement secret rotation policy (90 days)

### 4. GitOps Security

**Git Repository Access:**
- Use private repository
- Protected main branch (require PR reviews for manual changes)
- n8n has write access via dedicated deploy key
- Audit log all commits

**Commit Signing:**
- Consider GPG signing commits from n8n
- Verify commit signatures in CI/CD

**Rollback Capability:**
- Flux can rollback to previous commit
- Keep Git history clean for audit trail

### 5. Container Security

**Image Security:**
- Use official images when possible
- Scan images for vulnerabilities (Trivy, Grype)
- Pin image versions (avoid `latest` tag)
- Use private registry for custom images

**Pod Security:**
```yaml
# Example security context
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
```

### 6. Monitoring & Alerting

**Cloudflare Analytics:**
- Monitor traffic patterns
- Alert on suspicious activity
- Review Access logs regularly

**Kubernetes Monitoring:**
- Already have Prometheus + Grafana
- Monitor n8n workflow execution metrics
- Alert on failed deployments

**Git Monitoring:**
- Monitor for unauthorized commits
- Alert on high commit frequency (potential abuse)

### 7. Backup & Disaster Recovery

**Critical Data:**
- **n8n workflows**: Backed up to Git automatically
- **PostgreSQL**: CloudNativePG automatic backups to S3/Ceph
- **Kubernetes manifests**: Already in Git

**Disaster Recovery Plan:**
1. Restore from Git repository
2. Restore PostgreSQL from backup
3. Flux automatically reconciles cluster state
4. Cloudflare Tunnel reconnects automatically

---

## Cost Analysis

### Cloudflare Tunnel Solution (RECOMMENDED)

| Component | Cost | Notes |
|-----------|------|-------|
| **Cloudflare Account** | **FREE** | Free tier sufficient |
| **Cloudflare Tunnel** | **FREE** | Unlimited bandwidth, up to 50 users |
| **Domain Registration** | **$10-15/year** | Required, any registrar |
| **Cloudflare DNS** | **FREE** | Included |
| **Cloudflare Access (Zero Trust)** | **FREE** (up to 50 users) | Authentication & access policies |
| **Cloudflare WAF** | **FREE** | Basic rules included |
| **DDoS Protection** | **FREE** | Automatic, included |
| **Total** | **~$10-15/year** | Domain only |

**Additional Costs (Optional):**
- Cloudflare Workers: $5/month (10M requests)
- Cloudflare R2 Storage: $0.015/GB/month (for backups)
- Cloudflare Access 50+ users: $3/user/month

### Comparison: Alternative Solutions

| Solution | Monthly Cost | Annual Cost | Pros | Cons |
|----------|--------------|-------------|------|------|
| **Cloudflare Tunnel** | **$0** | **$10-15** (domain only) | Free, zero-trust, easy | Requires Cloudflare DNS |
| **Tailscale Funnel** | $6/user | $72 | Very secure, P2P | Limited to VPN users primarily |
| **VPS + WireGuard** | $5-10 | $60-120 | Full control | Maintenance overhead, no DDoS protection |
| **Static IP from ISP** | $5-15 | $60-180 | Direct connection | No DDoS protection, requires port forwarding |

**Winner: Cloudflare Tunnel** - Best value, zero-trust security, minimal cost

---

## Next Steps

### Immediate Actions

1. **Review this architecture document** with team/stakeholders
2. **Create Cloudflare account** and add domain
3. **Set up Cloudflare Tunnel** following Phase 1
4. **Deploy n8n** following Phase 2
5. **Develop initial n8n workflow** for GitOps deployment

### Questions to Answer Before Implementation

1. **Domain**: What domain will be used? (must be on Cloudflare) => i think i can register my existing domain 'k8s-lab.dev' registered with Porkbun. If not, i will get a new domain from Cloudflare.
2. **Subdomains**: Naming convention for dynamic apps? (e.g., `*.apps.example.com`) => yes, `*.apps` is a perfect prefix for app subdomains.
3. **Authentication**: Should all apps require authentication, or only specific ones? => some dynamic apps may require authentification.
4. **Rate Limits**: What rate limits are appropriate for webhooks? => whatever rate is considered human activity is appropriate. Access should also only be allowed from specific countries (Cloudflare setting i suppose).
5. **Monitoring**: What metrics and alerts are critical? => not sure at the moment, but we keep a note about settings these up. Suggest the most important ones.
6. **Backup Strategy**: Where should PostgreSQL backups be stored? (S3, Ceph, etc.) => we will probably do offsite backups to s3.

### Future Enhancements

1. **Multi-Region** - Deploy cloudflared in multiple availability zones
2. **Automated Testing** - CI/CD pipeline for n8n workflows
3. **App Templates** - Pre-built templates for common webapp types
4. **Cost Tracking** - Monitor resource usage per dynamic app
5. **Auto-Scaling** - HPA for dynamic apps based on traffic
6. **Monitoring Dashboard** - Custom Grafana dashboard for n8n + dynamic apps

---

## Appendix: Command Reference

### Cloudflare CLI Commands

```bash
# List tunnels
cloudflared tunnel list

# View tunnel details
cloudflared tunnel info homelab-rpi

# Test tunnel configuration
cloudflared tunnel ingress rule https://n8n.example.com

# Delete tunnel
cloudflared tunnel delete homelab-rpi
```

### Flux Commands

```bash
# Force reconciliation of cloudflared
flux reconcile kustomization cloudflared -n flux-system

# Check n8n deployment status
flux get helmreleases -n automation

# View logs
flux logs --kind=Kustomization --name=n8n

# Suspend/resume (for maintenance)
flux suspend kustomization n8n
flux resume kustomization n8n
```

### Kubernetes Commands

```bash
# Check cloudflared pods
kubectl get pods -n network -l app=cloudflared

# View cloudflared logs
kubectl logs -n network -l app=cloudflared -f

# Check n8n status
kubectl get pods -n automation

# View n8n logs
kubectl logs -n automation -l app=n8n -f

# List dynamic apps
kubectl get deployments -n dynamic-apps

# Delete a dynamic app
kubectl delete kustomization my-webapp-123 -n flux-system
```

---

## References

- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [n8n Documentation](https://docs.n8n.io/)
- [n8n Helm Chart (8gears)](https://github.com/8gears/n8n-helm-chart)
- [Cloudflared Helm Chart](https://artifacthub.io/packages/helm/community-charts/cloudflared)
- [Flux Documentation](https://fluxcd.io/docs/)
- [GITOPS.md](./GITOPS.md) - Repository structure guide
