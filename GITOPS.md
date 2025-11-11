# GitOps Repository Structure and Patterns

This document provides a comprehensive guide to the GitOps repository structure used in this Kubernetes homelab. It serves as a reference for understanding the current setup and implementing new applications or infrastructure components.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Directory Structure](#directory-structure)
3. [Flux Kustomization Hierarchy](#flux-kustomization-hierarchy)
4. [Component Organization Patterns](#component-organization-patterns)
5. [Naming Conventions](#naming-conventions)
6. [Dependency Management](#dependency-management)
7. [Secret Management](#secret-management)
8. [Adding New Components](#adding-new-components)
9. [Best Practices Alignment](#best-practices-alignment)

---

## Architecture Overview

This repository follows a **monorepo GitOps approach** using Flux v2 for continuous delivery. The setup is optimized for a single-cluster, single-environment homelab deployment.

**Key Characteristics:**
- **Single repository**: All cluster configuration in one Git repo
- **Single branch**: Trunk-based development on `main` branch
- **Single cluster**: `rpi-cluster` (no multi-environment overlays needed)
- **Declarative**: All desired state defined in YAML manifests
- **Automated**: Flux continuously reconciles Git state to cluster state

**GitOps Flow:**
```
Git Repository (Source of Truth)
         ↓
    Flux Watches
         ↓
   Flux Reconciles → Kubernetes Cluster
         ↓
  Desired State Applied
```

---

## Directory Structure

```
kubernetes/rpi-cluster/
├── flux/                           # Flux configuration and settings
│   ├── config/
│   │   └── cluster.yaml           # Root Flux Kustomizations (entry point)
│   ├── repositories/              # HelmRepository definitions
│   │   ├── cloudnative-pg.yaml
│   │   ├── grafana.yaml
│   │   ├── jetstack.yaml
│   │   └── ...
│   └── settings/                  # Cluster-wide configuration
│       ├── kustomization.yaml
│       ├── cluster-settings.yaml  # ConfigMap with cluster variables
│       └── cluster-secrets.sops.yaml  # Encrypted secrets
│
├── infrastructure/                # Platform-level components
│   ├── database/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   └── cloudnative-pg/
│   │       ├── ks.yaml            # Flux Kustomization
│   │       └── operator/
│   │           ├── kustomization.yaml
│   │           └── release.yaml   # HelmRelease
│   ├── gateway/
│   │   └── gateway-api/
│   │       ├── ks.yaml
│   │       └── crds/              # CRD installation
│   ├── network/
│   │   └── cilium/
│   │       ├── ks.yaml
│   │       └── gateway/           # Cilium Gateway config
│   ├── security/
│   │   └── cert-manager/
│   │       ├── ks.yaml
│   │       ├── app/               # Main cert-manager installation
│   │       ├── webhooks/          # DNS-01 challenge webhooks
│   │       ├── issuers/           # ClusterIssuers
│   │       └── certificates/      # Certificate resources
│   └── storage/
│       ├── kustomization.yaml
│       ├── namespace.yaml
│       └── rook-ceph/
│           ├── ks.yaml
│           ├── common/            # CRDs and common resources
│           ├── operator/          # Rook operator
│           ├── cluster/           # Ceph cluster
│           └── rbd/               # StorageClass
│
└── apps/                          # Application workloads
    ├── datastore/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   └── cloudnative-pg/
    │       ├── ks.yaml
    │       └── clusters/          # PostgreSQL cluster definitions
    │           ├── kustomization.yaml
    │           ├── postgres-example.yaml
    │           ├── credentials.sops.yaml
    │           ├── database-linkding.yaml
    │           └── credentials-linkding.sops.yaml
    ├── home/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── homepage/
    │   │   ├── ks.yaml
    │   │   └── app/
    │   │       ├── kustomization.yaml
    │   │       ├── release.yaml
    │   │       └── httproute.yaml
    │   └── linkding/
    │       ├── ks.yaml
    │       └── app/
    │           ├── kustomization.yaml
    │           ├── release.yaml
    │           ├── httproute.yaml
    │           ├── postgres-config.yaml
    │           └── postgres-credentials.sops.yaml
    └── monitoring/
        ├── kustomization.yaml
        ├── namespace.yaml
        ├── kube-prometheus-stack/
        │   ├── ks.yaml
        │   ├── crds/              # Prometheus CRDs
        │   └── app/               # Main Helm release
        ├── loki/
        └── metrics-server/
```

---

## Flux Kustomization Hierarchy

The root of the Flux configuration is `flux/config/cluster.yaml`, which defines four top-level Flux Kustomizations that establish the reconciliation order:

### 1. cluster-repositories (No Dependencies)
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-repositories
  namespace: flux-system
spec:
  interval: 30m
  path: ./kubernetes/rpi-cluster/flux/repositories
  prune: true
  wait: false
  sourceRef:
    kind: GitRepository
    name: flux-system
```

**Purpose**: Defines all HelmRepository sources before anything else.
**Wait**: `false` - Repositories can be created without blocking.

### 2. cluster-settings (No Dependencies)
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-settings
  namespace: flux-system
spec:
  interval: 30m
  path: ./kubernetes/rpi-cluster/flux/settings
  prune: true
  wait: false
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: flux-sops
  postBuild:
    substituteFrom:
      - kind: Secret
        name: cluster-secrets
        optional: true
```

**Purpose**: Creates cluster-wide ConfigMaps and Secrets for variable substitution.
**SOPS Decryption**: Enabled for encrypted secrets.
**Post-Build Substitution**: Makes `cluster-secrets` available for substitution.

### 3. cluster-infrastructure (Depends on: cluster-repositories)
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-infrastructure
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/rpi-cluster/infrastructure
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: cluster-repositories
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-settings
        optional: true
      - kind: Secret
        name: cluster-secrets
        optional: true
```

**Purpose**: Deploys platform components (storage, networking, security, databases).
**Post-Build Substitution**: Can use variables from cluster-settings and cluster-secrets.

### 4. cluster-apps (Depends on: cluster-repositories)
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/rpi-cluster/apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: cluster-repositories
```

**Purpose**: Deploys application workloads.
**Note**: Applications define their own dependencies on infrastructure components.

---

## Component Organization Patterns

### Pattern 1: Simple Operator/App (CloudNativePG Operator)

```
infrastructure/database/cloudnative-pg/
├── ks.yaml                        # Defines Flux Kustomization
└── operator/
    ├── kustomization.yaml         # Lists resources
    └── release.yaml               # HelmRelease for operator
```

**ks.yaml** (in infrastructure/database/cloudnative-pg/):
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cloudnative-pg-operator
  namespace: flux-system
spec:
  interval: 10m
  path: "./kubernetes/rpi-cluster/infrastructure/database/cloudnative-pg/operator"
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
```

**operator/kustomization.yaml**:
```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - release.yaml
```

### Pattern 2: Multi-Stage Component (cert-manager)

For components with multiple deployment stages (app → webhooks → issuers → certificates):

```
infrastructure/security/cert-manager/
├── ks.yaml                        # Defines ALL Flux Kustomizations for cert-manager
├── app/
│   ├── kustomization.yaml
│   ├── release.yaml
│   └── rbac.yaml
├── webhooks/
│   ├── kustomization.yaml
│   └── release.yaml
├── issuers/
│   ├── kustomization.yaml
│   ├── cluster-issuer-letsencrypt.yaml
│   └── porkbun-api-token.yaml
└── certificates/
    ├── kustomization.yaml
    └── wildcard-internal.yaml
```

**ks.yaml** defines the dependency chain:
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager
  namespace: flux-system
spec:
  interval: 10m
  path: "./kubernetes/rpi-cluster/infrastructure/security/cert-manager/app"
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager-webhooks
  namespace: flux-system
spec:
  interval: 10m
  path: "./kubernetes/rpi-cluster/infrastructure/security/cert-manager/webhooks"
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  dependsOn:
    - name: cert-manager
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cert-manager-issuers
  namespace: flux-system
spec:
  interval: 10m
  path: "./kubernetes/rpi-cluster/infrastructure/security/cert-manager/issuers"
  prune: true
  postBuild:
    substituteFrom:
      - kind: Secret
        name: cluster-secrets
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  decryption:
    provider: sops
    secretRef:
      name: flux-sops
  dependsOn:
    - name: cert-manager-webhooks
```

### Pattern 3: CRDs + App (kube-prometheus-stack)

For applications requiring CRD installation before the main app:

```
apps/monitoring/kube-prometheus-stack/
├── ks.yaml
├── crds/
│   ├── kustomization.yaml
│   └── release.yaml           # HelmRelease with skipCRDs
└── app/
    ├── kustomization.yaml
    ├── release.yaml
    └── httproute.yaml
```

**ks.yaml**:
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kube-prometheus-stack-crds
  namespace: flux-system
spec:
  interval: 1h
  path: ./kubernetes/rpi-cluster/apps/monitoring/kube-prometheus-stack/crds
  prune: true
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
  targetNamespace: monitoring
  timeout: 5m
  wait: true
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kube-prometheus-stack
  namespace: flux-system
spec:
  interval: 30m
  path: ./kubernetes/rpi-cluster/apps/monitoring/kube-prometheus-stack/app
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-settings
        optional: true
      - kind: Secret
        name: cluster-secrets
  prune: true
  retryInterval: 1m
  sourceRef:
    kind: GitRepository
    name: flux-system
  targetNamespace: monitoring
  timeout: 5m
  wait: true
  decryption:
    provider: sops
    secretRef:
      name: flux-sops
  dependsOn:
    - name: kube-prometheus-stack-crds
    - name: cert-manager
    - name: rook-ceph-rbd
```

### Pattern 4: Sequential Deployment (Rook-Ceph)

For components requiring strict sequential deployment:

```
infrastructure/storage/rook-ceph/
├── ks.yaml                        # Defines 4 Kustomizations
├── common/                        # Step 1: CRDs
├── operator/                      # Step 2: Operator
├── cluster/                       # Step 3: Ceph cluster
└── rbd/                          # Step 4: StorageClass
```

**ks.yaml** creates a chain: common → operator → cluster → rbd

---

## Naming Conventions

### File Names
- `ks.yaml` - Flux Kustomization definitions (deployment instructions for Flux)
- `kustomization.yaml` - Kustomize configuration (resource lists)
- `release.yaml` - Flux HelmRelease resources
- `*.sops.yaml` - SOPS-encrypted files
- `*.tpl` - Template files for envsubst variable substitution
- `namespace.yaml` - Namespace definitions
- `httproute.yaml` - Gateway API HTTPRoute for ingress

### Flux Kustomization Names
- Infrastructure operators: `<component>-operator` (e.g., `cloudnative-pg-operator`, `rook-ceph-operator`)
- Multi-stage components: `<component>-<stage>` (e.g., `cert-manager-webhooks`, `rook-ceph-cluster`)
- CRDs: `<component>-crds` (e.g., `kube-prometheus-stack-crds`)
- Root-level: `cluster-<category>` (e.g., `cluster-repositories`, `cluster-infrastructure`)

### Directory Names
- `infrastructure/` - Platform components (storage, networking, security, databases)
- `apps/` - Application workloads (home, monitoring, datastore)
- `flux/` - Flux-specific configuration
- Component subdirectories: `operator/`, `app/`, `crds/`, `cluster/`, `webhooks/`, `issuers/`, `certificates/`

---

## Dependency Management

### Dependency Levels

**Level 1: Cluster Foundations**
```
cluster-repositories (HelmRepositories)
cluster-settings (ConfigMaps, Secrets)
```

**Level 2: Infrastructure**
```
cluster-infrastructure → cluster-repositories
    ├── Storage (rook-ceph)
    ├── Network (cilium)
    ├── Gateway (gateway-api)
    ├── Security (cert-manager)
    └── Database (cloudnative-pg-operator)
```

**Level 3: Applications**
```
cluster-apps → cluster-repositories
    └── Individual apps → specific infrastructure dependencies
```

### Common Dependency Patterns

**Pattern: App depends on Storage + Database Cluster**
```yaml
# apps/home/linkding/ks.yaml
spec:
  dependsOn:
    - name: rook-ceph-rbd
    - name: cloudnative-pg-clusters
```

**Pattern: App depends on Storage + Certificates**
```yaml
# apps/monitoring/kube-prometheus-stack/ks.yaml
spec:
  dependsOn:
    - name: kube-prometheus-stack-crds
    - name: cert-manager
    - name: rook-ceph-rbd
```

**Pattern: Sequential Infrastructure Deployment**
```yaml
# infrastructure/storage/rook-ceph/ks.yaml
---
# Step 1: Common/CRDs (no dependencies)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: rook-ceph-common
---
# Step 2: Operator depends on common
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: rook-ceph-operator
spec:
  dependsOn:
    - name: rook-ceph-common
---
# Step 3: Cluster depends on operator
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: rook-ceph-cluster
spec:
  dependsOn:
    - name: rook-ceph-operator
---
# Step 4: StorageClass depends on cluster
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: rook-ceph-rbd
spec:
  dependsOn:
    - name: rook-ceph-cluster
```

### Wait and Prune Settings

**`wait: true`** - Flux waits for all resources to be ready before marking Kustomization as ready
- **Use for**: Operators, CRDs, infrastructure dependencies
- **Reason**: Dependent components need these to be fully ready

**`wait: false`** - Flux applies resources but doesn't wait
- **Use for**: HelmRepositories, non-blocking resources
- **Reason**: No need to block on repository definitions

**`prune: true`** - Remove resources from cluster if removed from Git
- **Use for**: All Kustomizations (standard practice)
- **Reason**: Keeps cluster state in sync with Git

**Common Configuration**:
```yaml
spec:
  interval: 10m           # How often to check Git for changes
  prune: true             # Remove deleted resources
  wait: true              # Wait for readiness
  timeout: 5m             # Give up after 5 minutes
  retryInterval: 2m       # Retry failed reconciliation after 2m
```

---

## Secret Management

### SOPS with age Encryption

**Key Location**: `~/.config/sops/age/keys.txt` (during image build, copied to `/root/keys.txt` on nodes)

**SOPS Configuration** (`.sops.yaml` in repo root):
```yaml
creation_rules:
  - path_regex: .*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age12f3ry4kndhhzag52alez69qsfwm7ujd3qp3c9y570c5yhazcwqds4qhe3k
```

### Secret Types and Locations

**1. Cluster-Wide Secrets**
- **Location**: `flux/settings/cluster-secrets.sops.yaml`
- **Usage**: Variable substitution in any Kustomization with postBuild.substituteFrom
- **Example**: Domain names, API tokens, wildcard values

**2. Component-Specific Secrets**
- **Location**: Co-located with component (e.g., `apps/home/linkding/app/postgres-credentials.sops.yaml`)
- **Usage**: Specific to that application/component
- **Example**: Database credentials, application API keys

**3. Infrastructure Secrets**
- **Location**: Within infrastructure component directories (e.g., `infrastructure/security/cert-manager/issuers/porkbun-api-token.yaml`)
- **Usage**: Infrastructure service credentials
- **Example**: DNS provider API keys, cloud provider credentials

### Enabling SOPS Decryption in Flux Kustomizations

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-component
  namespace: flux-system
spec:
  # ... other fields ...
  decryption:
    provider: sops
    secretRef:
      name: flux-sops
```

**Note**: The `flux-sops` secret is created during cluster bootstrap and contains the age private key.

### Using Cluster Secrets for Variable Substitution

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-component
  namespace: flux-system
spec:
  # ... other fields ...
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-settings
        optional: true
      - kind: Secret
        name: cluster-secrets
        optional: true
```

Then in manifests, use `${VARIABLE_NAME}` for substitution.

---

## Adding New Components

### Checklist for Adding Infrastructure Components

1. **Create HelmRepository (if needed)**
   ```yaml
   # flux/repositories/<name>.yaml
   ---
   apiVersion: source.toolkit.fluxcd.io/v1
   kind: HelmRepository
   metadata:
     name: <repository-name>
     namespace: flux-system
   spec:
     interval: 1h
     url: https://<helm-repo-url>
   ```

2. **Create Namespace (if new category)**
   ```yaml
   # infrastructure/<category>/namespace.yaml
   ---
   apiVersion: v1
   kind: Namespace
   metadata:
     name: <namespace-name>
     labels:
       kustomize.toolkit.fluxcd.io/prune: disabled
   ```

3. **Create Component Directory Structure**
   ```
   infrastructure/<category>/<component>/
   ├── ks.yaml
   └── <stage>/  (operator, app, crds, etc.)
       ├── kustomization.yaml
       └── release.yaml
   ```

4. **Create Flux Kustomization (ks.yaml)**
   ```yaml
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: <component-name>
     namespace: flux-system
   spec:
     interval: 10m
     path: "./kubernetes/rpi-cluster/infrastructure/<category>/<component>/<stage>"
     prune: true
     sourceRef:
       kind: GitRepository
       name: flux-system
     wait: true
     dependsOn:  # Add if needed
       - name: <dependency>
   ```

5. **Create HelmRelease**
   ```yaml
   # infrastructure/<category>/<component>/<stage>/release.yaml
   ---
   apiVersion: helm.toolkit.fluxcd.io/v2
   kind: HelmRelease
   metadata:
     name: <component>
     namespace: <namespace>
   spec:
     chart:
       spec:
         chart: <chart-name>
         version: <version>
         sourceRef:
           kind: HelmRepository
           name: <repository-name>
           namespace: flux-system
     interval: 1h
     values:
       # ... Helm values ...
   ```

6. **Create Kustomization Resource List**
   ```yaml
   # infrastructure/<category>/<component>/<stage>/kustomization.yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - release.yaml
     # - additional resources if needed
   ```

7. **Register Component in Parent Kustomization**
   ```yaml
   # infrastructure/<category>/kustomization.yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ./namespace.yaml
     - ./<component>/ks.yaml
   ```

### Checklist for Adding Applications

1. **Create Application Directory Structure**
   ```
   apps/<category>/<app-name>/
   ├── ks.yaml
   └── app/
       ├── kustomization.yaml
       ├── release.yaml
       ├── httproute.yaml  (if exposing via Gateway API)
       ├── <app-config>.yaml  (ConfigMaps, etc.)
       └── <app-secrets>.sops.yaml  (if needed)
   ```

2. **Create Flux Kustomization (ks.yaml)**
   ```yaml
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: <app-name>
     namespace: flux-system
   spec:
     decryption:
       provider: sops
       secretRef:
         name: flux-sops
     dependsOn:
       - name: rook-ceph-rbd  # If needs storage
       - name: cloudnative-pg-clusters  # If needs database
       - name: cert-manager  # If needs certificates
     interval: 1h
     path: ./kubernetes/rpi-cluster/apps/<category>/<app-name>/app
     postBuild:
       substituteFrom:
         - kind: ConfigMap
           name: cluster-settings
           optional: true
         - kind: Secret
           name: cluster-secrets
     prune: true
     retryInterval: 2m
     sourceRef:
       kind: GitRepository
       name: flux-system
     targetNamespace: <namespace>
     timeout: 5m
     wait: true
   ```

3. **Create HelmRelease or Raw Manifests**

4. **If Using PostgreSQL (CloudNativePG)**:

   a. Create managed role in cluster definition:
   ```yaml
   # apps/datastore/cloudnative-pg/clusters/postgres-example.yaml
   spec:
     managed:
       roles:
         - name: <app-db-user>
           ensure: present
           login: true
           passwordSecret:
             name: <app>-postgres-credentials
   ```

   b. Create encrypted credentials in datastore namespace:
   ```yaml
   # apps/datastore/cloudnative-pg/clusters/credentials-<app>.sops.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: <app>-postgres-credentials
     namespace: datastore
   type: kubernetes.io/basic-auth
   stringData:
     username: <app>
     password: <strong-random-password>
   ```

   c. Create Database CR:
   ```yaml
   # apps/datastore/cloudnative-pg/clusters/database-<app>.yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Database
   metadata:
     name: <app>-db
     namespace: datastore
   spec:
     name: <database-name>
     owner: <app-db-user>
     cluster:
       name: postgres-cluster
     ensure: present
   ```

   d. Add to datastore clusters kustomization:
   ```yaml
   # apps/datastore/cloudnative-pg/clusters/kustomization.yaml
   resources:
     # ... existing resources ...
     - database-<app>.yaml
     - credentials-<app>.sops.yaml
   ```

   e. Create encrypted credentials in app namespace:
   ```yaml
   # apps/<category>/<app-name>/app/postgres-credentials.sops.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: <app>-postgres-credentials
     namespace: <app-namespace>
   type: kubernetes.io/basic-auth
   stringData:
     username: <app>
     password: <same-password-as-datastore-secret>
   ```

   f. Create connection config:
   ```yaml
   # apps/<category>/<app-name>/app/postgres-config.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: <app>-postgres-config
     namespace: <app-namespace>
   data:
     DB_HOST: "postgres-cluster-rw.datastore.svc.cluster.local"
     DB_PORT: "5432"
     DB_NAME: "<database-name>"
   ```

   g. Reference in HelmRelease:
   ```yaml
   spec:
     values:
       env:
         - name: DB_HOST
           valueFrom:
             configMapKeyRef:
               name: <app>-postgres-config
               key: DB_HOST
         - name: DB_USER
           valueFrom:
             secretKeyRef:
               name: <app>-postgres-credentials
               key: username
         - name: DB_PASSWORD
           valueFrom:
             secretKeyRef:
               name: <app>-postgres-credentials
               key: password
   ```

5. **If Exposing via Gateway API**:
   ```yaml
   # apps/<category>/<app-name>/app/httproute.yaml
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: <app-name>
     namespace: <namespace>
   spec:
     parentRefs:
       - name: cilium-gateway
         namespace: network
     hostnames:
       - "<app>.${CLUSTER_DOMAIN}"
     rules:
       - matches:
           - path:
               type: PathPrefix
               value: /
         backendRefs:
           - name: <service-name>
             port: <port>
   ```

6. **Register Application in Parent Kustomization**
   ```yaml
   # apps/<category>/kustomization.yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - namespace.yaml
     - <app-name>/ks.yaml
   ```

7. **Encrypt Secrets with SOPS**
   ```bash
   sops --encrypt --in-place apps/<category>/<app-name>/app/*-credentials.sops.yaml
   ```

---

## Best Practices Alignment

### Flux Official Recommendations

| Best Practice | Implementation | Status |
|--------------|----------------|--------|
| **Monorepo approach** | Single repo with all cluster config | ✅ Implemented |
| **Separation of apps and infrastructure** | `infrastructure/` and `apps/` directories | ✅ Implemented |
| **Trunk-based development** | Single `main` branch | ✅ Implemented |
| **Declarative configuration** | All desired state in YAML | ✅ Implemented |
| **HelmRepository separation** | Dedicated `flux/repositories/` | ✅ Implemented |
| **Dependency ordering** | Extensive use of `dependsOn` | ✅ Implemented |
| **Wait and health checking** | `wait: true` for critical components | ✅ Implemented |
| **Prune deleted resources** | `prune: true` on all Kustomizations | ✅ Implemented |
| **Secret management** | SOPS with age encryption | ✅ Implemented |
| **Kustomize overlays (base/staging/production)** | Not used - single environment | ⚠️ Not applicable (homelab) |

### Repository Design Choices

**Choice: Monorepo (Single Repo, Single Branch)**
- ✅ **Pro**: Simplified management for single-cluster homelab
- ✅ **Pro**: All configuration in one place
- ✅ **Pro**: Easier to see full cluster state
- ⚠️ **Con**: No separation of staging/production (not needed for homelab)

**Choice: No Kustomize Overlays (base/staging/production)**
- ✅ **Pro**: Simpler structure for single environment
- ✅ **Pro**: Less duplication and indirection
- ✅ **Pro**: Faster to understand and modify
- ⚠️ **Con**: Would need refactoring if adding staging environment

**Choice: Self-Contained Components**
- ✅ **Pro**: Each component directory is self-contained
- ✅ **Pro**: Easy to add/remove components
- ✅ **Pro**: Clear dependency boundaries via ks.yaml

**Choice: ks.yaml Pattern**
- ✅ **Pro**: Single file defines all Flux Kustomizations for a component
- ✅ **Pro**: Clear view of deployment stages and dependencies
- ✅ **Pro**: Easy to see reconciliation order

### Industry Best Practices

**✅ GitOps Principles (Weaveworks)**
1. Declarative: System state described declaratively ✅
2. Versioned: All config in Git with history ✅
3. Pulled automatically: Flux pulls and applies ✅
4. Continuously reconciled: Flux reconciles drift ✅

**✅ Security Best Practices**
1. Secrets encrypted at rest (SOPS) ✅
2. Secrets decrypted only in-cluster ✅
3. No secrets in plain text in Git ✅
4. Namespace isolation ✅

**✅ Operational Best Practices**
1. Infrastructure before apps ✅
2. CRDs before operators ✅
3. Operators before instances ✅
4. Health checking with wait ✅
5. Automatic pruning of deleted resources ✅

---

## Quick Reference Commands

### Check Flux Status
```bash
# Check all Flux components
flux check

# List all Flux Kustomizations
flux get kustomizations -A

# List all HelmReleases
flux get helmreleases -A

# Check specific Kustomization status
flux get kustomization <name> -n flux-system

# Watch reconciliation
watch flux get kustomizations -A
```

### Force Reconciliation
```bash
# Reconcile specific Kustomization
flux reconcile kustomization <name> -n flux-system

# Reconcile all
flux reconcile kustomization cluster-infrastructure -n flux-system
flux reconcile kustomization cluster-apps -n flux-system

# Reconcile HelmRelease
flux reconcile helmrelease <name> -n <namespace>
```

### Debugging
```bash
# View Flux logs
flux logs --level=error --all-namespaces

# Describe Kustomization to see errors
kubectl describe kustomization <name> -n flux-system

# Check events
kubectl get events -n flux-system --sort-by='.lastTimestamp'
```

---

## Summary

This GitOps repository follows a **monorepo approach optimized for a single-cluster homelab environment**. Key characteristics:

1. **Clear separation**: `flux/` for Flux config, `infrastructure/` for platform, `apps/` for workloads
2. **Self-contained components**: Each component directory includes all related resources
3. **Explicit dependencies**: `dependsOn` ensures proper ordering
4. **Secret management**: SOPS encryption with age for all sensitive data
5. **Standardized patterns**: Consistent structure makes adding components predictable

**When adding new components**, follow the patterns documented in the [Adding New Components](#adding-new-components) section. The structure is designed to be self-documenting - look at existing components as examples.

**Key Files to Remember**:
- `flux/config/cluster.yaml` - Root entry point for Flux
- `flux/repositories/<name>.yaml` - HelmRepository definitions
- `infrastructure/<category>/kustomization.yaml` - Category-level resource lists
- `<component>/ks.yaml` - Component deployment instructions
- `<component>/<stage>/kustomization.yaml` - Stage-level resource lists
- `<component>/<stage>/release.yaml` - HelmRelease definitions
