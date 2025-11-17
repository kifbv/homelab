# PLAN.md - n8n Automation System for Dynamic Webapp Deployment

This document outlines the implementation plan for building an n8n-based automation system that creates webapps on demand and deploys them to the Kubernetes homelab cluster.

## Overview

**Goal**: Enable on-demand webapp creation through an n8n workflow that:
1. Accepts user requests (manual trigger or webhook from Signal/Slack)
2. Uses AI agents (ChatGPT + Claude) to generate webapp code
3. Builds container images and pushes to private registry
4. Generates GitOps manifests and commits to repository
5. Triggers Flux reconciliation for immediate deployment
6. Exposes apps via Cloudflare Tunnel with optional authentication

---

## Phase 1: Infrastructure Preparation (Week 1)

### 1.1 Flux Webhook Receiver
**Goal**: Enable immediate reconciliation when n8n pushes to Git (15-30s vs 5-10min)

- [ ] Generate HMAC webhook token and store in SOPS secret
- [ ] Create Receiver resource (`notification.toolkit.fluxcd.io/v1`)
- [ ] Create Service for webhook receiver (ClusterIP)
- [ ] Add route to Cloudflare Tunnel: `flux-webhook.k8s-lab.dev` → `webhook-receiver.flux-system.svc.cluster.local:9292`
- [ ] Create DNS record via external-dns annotation
- [ ] Configure GitHub webhook pointing to `https://flux-webhook.k8s-lab.dev/hook/<token>`
- [ ] Test webhook with manual Git push

**Files to create**:
- `kubernetes/rpi-cluster/infrastructure/flux-webhook/ks.yaml`
- `kubernetes/rpi-cluster/infrastructure/flux-webhook/app/receiver.yaml`
- `kubernetes/rpi-cluster/infrastructure/flux-webhook/app/secret.sops.yaml`
- `kubernetes/rpi-cluster/infrastructure/flux-webhook/app/service.yaml`
- Update `kubernetes/rpi-cluster/infrastructure/network/cloudflared/app/config.yaml`

---

### 1.2 Expose Docker Registry Publicly
**Goal**: Allow n8n to push container images to registry from outside cluster

- [ ] Add Cloudflare Tunnel route: `registry.k8s-lab.dev` → `docker-registry.registry.svc.cluster.local:5000`
- [ ] Create ExternalName service with external-dns annotation for DNS record
- [ ] Verify existing n8n registry user credentials (check SOPS secrets in registry namespace)
- [ ] Test registry push from outside cluster using n8n user credentials
- [ ] Verify image pull from registry works

**Files to update**:
- `kubernetes/rpi-cluster/infrastructure/network/cloudflared/app/config.yaml`
- `kubernetes/rpi-cluster/infrastructure/network/external-dns/app/registry-dns-service.yaml` (new)

**Note**: n8n registry user already exists - verify credentials and test authentication before proceeding.

---

### 1.3 Dynamic Apps Infrastructure
**Goal**: Create namespace and supporting infrastructure for dynamically deployed apps

- [ ] Research namespace strategy: Start with shared `dynamic-apps` namespace, document migration path to per-app namespaces if needed
- [ ] Create `dynamic-apps` namespace
- [ ] Create ServiceAccount with imagePullSecrets for registry authentication
- [ ] Create RBAC (Role/RoleBinding) for basic pod/service/httproute management
- [ ] Create or reference imagePullSecret for registry access (use existing n8n registry credentials)
- [ ] Create directory structure: `kubernetes/rpi-cluster/apps/dynamic/`
- [ ] Create base kustomization.yaml

**Files to create**:
- `kubernetes/rpi-cluster/apps/dynamic/ks.yaml`
- `kubernetes/rpi-cluster/apps/dynamic/app/namespace.yaml`
- `kubernetes/rpi-cluster/apps/dynamic/app/serviceaccount.yaml`
- `kubernetes/rpi-cluster/apps/dynamic/app/rbac.yaml`
- `kubernetes/rpi-cluster/apps/dynamic/app/imagepullsecret.sops.yaml` (or reference existing)
- `kubernetes/rpi-cluster/apps/dynamic/app/kustomization.yaml`

---

### 1.4 Variable Substitution for Secrets
**Goal**: Remove hardcoded domains and configuration from manifests

- [ ] Create or update `flux/settings/cluster-secrets.sops.yaml` with:
  - `CLUSTER_DOMAIN=k8s-lab.dev`
  - `CLUSTER_TIMEZONE=Europe/Bucharest`
  - `REGISTRY_URL=registry.k8s-lab.dev`
  - `APPS_SUBDOMAIN=apps.k8s-lab.dev`
- [ ] Update n8n Kustomization with `postBuild.substituteFrom`
- [ ] Update n8n deployment.yaml to use `${CLUSTER_DOMAIN}` variables
- [ ] Update Cloudflared Kustomization with `postBuild.substituteFrom`
- [ ] Update Cloudflared config.yaml to use variables
- [ ] Test reconciliation and verify substitution works

**Files to update**:
- `kubernetes/rpi-cluster/flux/settings/cluster-secrets.sops.yaml`
- `kubernetes/rpi-cluster/apps/automation/n8n/ks.yaml`
- `kubernetes/rpi-cluster/apps/automation/n8n/app/deployment.yaml`
- `kubernetes/rpi-cluster/infrastructure/network/cloudflared/ks.yaml`
- `kubernetes/rpi-cluster/infrastructure/network/cloudflared/app/config.yaml`

---

### 1.5 Wildcard DNS Route for Dynamic Apps
**Goal**: Enable `*.apps.k8s-lab.dev` routing to Cilium Gateway

- [ ] Research Cloudflare Tunnel wildcard routing capabilities
- [ ] Option A: Configure wildcard route in Cloudflared config: `*.apps.k8s-lab.dev` → Cilium Gateway LoadBalancer
- [ ] Option B: Use HTTPRoute-level routing if wildcard not supported
- [ ] Create Cilium Gateway for dynamic apps (if not using shared gateway)
- [ ] Test routing with sample HTTPRoute

**Files to update/create**:
- `kubernetes/rpi-cluster/infrastructure/network/cloudflared/app/config.yaml`
- `kubernetes/rpi-cluster/infrastructure/gateway/dynamic-apps-gateway.yaml` (if needed)

---

## Phase 2: Container Build Strategy (Week 2)

### 2.1 Research Buildah on ARM64/Raspberry Pi
**Goal**: Verify Buildah suitability for low-resource ARM builds

- [ ] Research Buildah performance on Raspberry Pi 5 (8GB RAM)
- [ ] Research Buildah memory requirements and optimization options
- [ ] Compare with alternatives (Kaniko, img) for ARM64
- [ ] Test basic build on ARM64 (if possible)
- [ ] Document findings and recommendation
- [ ] **Decision Point**: Proceed with Buildah or pivot to alternative

**Research Questions**:
- Does Buildah run efficiently on ARM64 with 8GB RAM?
- What are typical build times for simple webapps?
- Are there known issues with Buildah on Raspberry Pi?
- Can Buildah run rootless in Kubernetes?

---

### 2.2 Deploy Buildah Infrastructure
**Goal**: Enable n8n to build container images

**Option A: Buildah Pod Template** (Recommended for security)
- [ ] Create Buildah container image with necessary tools (or use existing buildah:stable)
- [ ] Configure pod template for builds (rootless, fuse-overlayfs storage)
- [ ] Create ServiceAccount with required permissions
- [ ] Configure resource limits (CPU, memory)
- [ ] Test build with sample Dockerfile

**Option B: Buildah Sidecar in n8n Pod**
- [ ] Add Buildah sidecar to n8n deployment
- [ ] Configure shared workspace volume
- [ ] Configure resource limits

**Files to create** (Option A):
- `kubernetes/rpi-cluster/apps/automation/buildah/ks.yaml`
- `kubernetes/rpi-cluster/apps/automation/buildah/app/serviceaccount.yaml`
- `kubernetes/rpi-cluster/apps/automation/buildah/app/pod-template.yaml`
- `kubernetes/rpi-cluster/apps/automation/buildah/app/rbac.yaml`

---

### 2.3 Verify Registry Authentication for n8n
**Goal**: Ensure n8n can push images to private registry

- [ ] Locate existing n8n registry user credentials in SOPS secrets
- [ ] Verify credentials are stored in n8n credentials manager (Docker Registry type)
- [ ] Verify Kubernetes secret exists for n8n to access during builds
- [ ] Test authentication with manual push using n8n credentials

**Note**: n8n registry user already exists - this is verification only, not creation.

---

### 2.4 Test Container Image Build Pipeline
**Goal**: Validate entire build-push workflow

- [ ] Create sample webapp (simple Node.js/Python app)
- [ ] Create Dockerfile
- [ ] Test build using Buildah pod/sidecar
- [ ] Test push to `registry.k8s-lab.dev/dynamic-apps/test-app:v1`
- [ ] Test pull from registry to verify upload
- [ ] Document build process and timing

---

## Phase 3: GitHub Integration (Week 2-3)

### 3.1 Generate SSH Deploy Key for n8n
**Goal**: Secure Git access for n8n to push manifests

- [ ] Generate SSH key pair for n8n: `ssh-keygen -t ed25519 -C "n8n@k8s-lab.dev"`
- [ ] Add public key to GitHub repository as Deploy Key with write access
- [ ] Store private key in n8n credentials manager (SSH type)
- [ ] Create Kubernetes secret with SSH private key (SOPS encrypted)
- [ ] Configure SSH known_hosts for github.com

**Files to create**:
- `kubernetes/rpi-cluster/apps/automation/n8n/app/git-ssh-secret.sops.yaml`

---

### 3.2 Configure Git Operations in n8n
**Goal**: Enable n8n to clone, commit, and push to homelab repo

- [ ] Install Git in n8n container (if not present)
- [ ] Configure Git global settings (user.name, user.email)
- [ ] Test Git clone using SSH credentials
- [ ] Test Git commit and push
- [ ] Document Git workflow for n8n

---

### 3.3 Configure GitHub Webhook
**Goal**: Trigger Flux reconciliation immediately after n8n push

- [ ] Configure GitHub repository webhook
  - URL: `https://flux-webhook.k8s-lab.dev/hook/<token>`
  - Events: Push to main branch
  - Secret: HMAC token from SOPS
- [ ] Test webhook delivery
- [ ] Verify Flux reconciliation triggers on push
- [ ] Monitor reconciliation time (target: <30 seconds)

---

### 3.4 Decide on Webapp Code Repository Strategy
**Goal**: Determine where webapp source code will be stored

**Option A: Single Repository for All Webapps** (Recommended for simplicity)
- [ ] Create new GitHub repository: `kifbv/homelab-webapps` (or similar name)
- [ ] Structure: One directory per webapp
  ```
  homelab-webapps/
  ├── my-app-1/
  │   ├── src/
  │   ├── Dockerfile
  │   ├── package.json
  │   └── README.md
  ├── my-app-2/
  │   ├── src/
  │   ├── Dockerfile
  │   └── requirements.txt
  └── ...
  ```
- [ ] n8n commits new webapp code to this repo
- [ ] Single GitHub Actions workflow with path filters for each app
- [ ] Simpler management, single webhook, easier to browse all apps

**Option B: One Repository Per Webapp**
- [ ] n8n creates new GitHub repository for each webapp via GitHub API
- [ ] Each repo gets its own GitHub Actions workflow
- [ ] Each repo gets its own Flux ImageRepository + ImagePolicy
- [ ] Better isolation, independent versioning, more complex to manage

**Decision Criteria**:
- Option A: Simpler for homelab, easier to manage, fewer webhooks, less overhead
- Option B: More production-like, better isolation, scales better for many apps

**Recommendation**: Start with Option A (single repo), migrate to Option B if needed later

---

### 3.5 Setup Webapp Repository and CI/CD (Based on 3.4 decision)

**If Option A (Single Repository)**:
- [ ] Create `homelab-webapps` repository
- [ ] Create GitHub Actions workflow template with:
  - Triggers: `push` to main, `path` filters per app directory
  - Build Docker image using Buildah/Docker
  - Push to `registry.k8s-lab.dev/dynamic-apps/<app-name>:<git-sha>`
  - Update image tag in homelab repo GitOps manifests (via PR or direct commit)
- [ ] Configure Flux ImageRepository to watch registry
- [ ] Configure Flux ImagePolicy for each app (semver, regex, or alphabetical)
- [ ] Configure Flux ImageUpdateAutomation to update manifests

**If Option B (Per-App Repository)**:
- [ ] Create GitHub API token with repo creation permissions
- [ ] Store token in n8n credentials
- [ ] Add "Create GitHub Repo" node to n8n workflow
- [ ] Create GitHub Actions workflow template to include in each repo
- [ ] Configure Flux ImageRepository + ImagePolicy per app

**Files to create** (Option A):
- New repository: `kifbv/homelab-webapps`
- `.github/workflows/build-and-push.yml` in webapps repo
- `kubernetes/rpi-cluster/apps/dynamic/image-automation/` (Flux ImageRepository, ImagePolicy, ImageUpdateAutomation)

**Files to create** (Option B):
- n8n workflow nodes for GitHub repo creation
- GitHub Actions workflow template
- Per-app Flux ImageRepository + ImagePolicy manifests

---

## Phase 4: n8n Workflow Development (Week 3-4)

### 4.1 Create "Deploy Dynamic Webapp" Workflow - Foundation
**Goal**: Build core workflow structure and validation

- [ ] Create new workflow in n8n: "Deploy Dynamic Webapp"
- [ ] Add webhook trigger node (configure URL path)
- [ ] Add input validation node (Function node):
  - Validate app name (lowercase, alphanumeric, hyphens)
  - Validate app type (static, node, python, go, etc.)
  - Validate app description/requirements
  - Return validation errors if invalid
- [ ] Add error handling (Error Trigger + Slack/email notification)
- [ ] Test webhook trigger and validation

---

### 4.2 AI Agent Integration - Requirements Generation
**Goal**: Use ChatGPT to translate user request into technical requirements

- [ ] Configure ChatGPT credentials in n8n (OpenAI API key)
- [ ] Create AI Agent node: "Generate Technical Requirements"
  - Input: User's app description/requirements
  - Prompt: "You are a technical architect. Translate the following webapp request into detailed technical requirements including: tech stack, dependencies, file structure, API endpoints, environment variables, and deployment requirements."
  - Output: Structured JSON with technical requirements
- [ ] Add validation for AI response
- [ ] Test with sample requests

---

### 4.3 AI Agent Integration - Code Generation
**Goal**: Use Claude AI to generate webapp code from requirements

- [ ] Configure Claude AI credentials in n8n (Anthropic API key)
- [ ] Create AI Agent node: "Generate Webapp Code"
  - Input: Technical requirements from ChatGPT
  - Prompt: "You are an expert developer. Create production-ready code for a webapp based on these requirements: {{requirements}}. Return a complete file structure with all necessary files including Dockerfile, source code, package.json/requirements.txt, and README."
  - Output: Structured JSON with file paths and contents
- [ ] Add code validation and sanitization
- [ ] Test with sample requirements

---

### 4.4 Container Image Build Node
**Goal**: Build Docker image from generated code

- [ ] Create Function/Code node: "Build Container Image"
  - Create temporary workspace
  - Write generated files to workspace
  - Write Dockerfile
  - Call Buildah (via Kubernetes API or exec command)
  - Tag image: `registry.k8s-lab.dev/dynamic-apps/<app-name>:<timestamp>`
- [ ] Add build logging and error handling
- [ ] Test build with sample code

---

### 4.5 Registry Push Node
**Goal**: Push built image to private registry

- [ ] Create Function/Code node: "Push to Registry"
  - Authenticate with registry using n8n registry user credentials
  - Push image using Buildah or Docker CLI
  - Verify push succeeded
  - Return image digest
- [ ] Add retry logic for transient failures
- [ ] Test push with sample image

---

### 4.6 Webapp Code Repository Commit Node
**Goal**: Commit webapp source code to chosen repository strategy

**If Option A (Single Repository)**:
- [ ] Create Function/Code node: "Commit Code to homelab-webapps"
  - Clone homelab-webapps repository
  - Create directory: `<app-name>/`
  - Write all source files (Dockerfile, src/, package.json, etc.)
  - Git add, commit with message: `Add <app-name> webapp`
  - Git push to main branch
  - GitHub Actions will trigger on push (path filter)
  - Return commit SHA

**If Option B (Per-App Repository)**:
- [ ] Create Function/Code node: "Create GitHub Repository"
  - Call GitHub API to create new repository: `<app-name>`
  - Initialize repository with README
  - Clone repository
  - Write all source files
  - Write GitHub Actions workflow
  - Git add, commit, push
  - Return repository URL

---

### 4.7 GitOps Manifest Generation Node
**Goal**: Generate Kubernetes manifests for the webapp

- [ ] Create Function/Code node: "Generate Manifests"
  - Input: App name, image URL, technical requirements
  - Generate:
    - `deployment.yaml`: Deployment with security context, resources, health checks
    - `service.yaml`: ClusterIP service
    - `httproute.yaml`: Gateway API route for `<app-name>.apps.${CLUSTER_DOMAIN}`
    - `kustomization.yaml`: Resource list
    - `ks.yaml`: Flux Kustomization with dependencies
    - `imagerepository.yaml`: Flux ImageRepository watching registry
    - `imagepolicy.yaml`: Flux ImagePolicy for automatic updates
  - Use templates with variable substitution (`${CLUSTER_DOMAIN}`)
  - Return manifest files as structured data
- [ ] Validate generated manifests (YAML syntax)
- [ ] Test generation with various app types

**Note**: Flux image automation manifests enable automatic updates when new images are pushed to registry.

---

### 4.8 Git Operations Node - Homelab Repository
**Goal**: Commit GitOps manifests to homelab repository

- [ ] Create Function/Code node: "Git Commit and Push Manifests"
  - Clone homelab repository (shallow clone)
  - Create directory: `kubernetes/rpi-cluster/apps/dynamic/<app-name>/`
  - Write manifest files (including Flux image automation resources)
  - Update parent kustomization.yaml to include new app
  - Git add, commit with message: `Deploy <app-name> via n8n automation`
  - Git push to main branch
  - Return commit SHA
- [ ] Add error handling for Git conflicts
- [ ] Test Git operations

---

### 4.9 Deployment Monitoring (Optional)
**Goal**: Track deployment status and notify user

**Option A: Webhook + Polling**
- [ ] Wait for GitHub webhook to trigger Flux
- [ ] Poll Flux Kustomization status API
- [ ] Check when reconciliation completes
- [ ] Verify pods are running

**Option B: Simple Notification**
- [ ] Send notification with app URL immediately after push
- [ ] User checks deployment status manually
- [ ] Simpler, less resource intensive (recommended for MVP)

**Decision**: Start with Option B, add Option A if needed

---

### 4.10 Workflow Testing & Refinement
**Goal**: End-to-end validation of the entire workflow

- [ ] Test workflow with simple static site (nginx)
- [ ] Test workflow with Node.js webapp
- [ ] Test workflow with Python Flask app
- [ ] Test failure scenarios (invalid input, build failures, Git conflicts)
- [ ] Test image update flow: Push new code → GitHub Actions builds → Flux updates manifest
- [ ] Measure deployment time (target: <60 seconds total)
- [ ] Document workflow usage and limitations

---

## Phase 5: Authentication & Security (Week 4-5)

### 5.1 Research Authentication Options
**Goal**: Determine best approach for per-app authentication

**Cloudflare Access Options**:
- [ ] Research Cloudflare Access + Generic OIDC integration
- [ ] Research Cloudflare Access API for programmatic policy creation
- [ ] Document per-app policy creation workflow

**Self-Hosted OIDC Options**:
- [ ] Research Keycloak resource requirements on ARM64
- [ ] Research Dex (lightweight OIDC provider)
- [ ] Research Authentik
- [ ] Compare options (resources, features, complexity)

**Decision Criteria**:
- Memory footprint (must run on Raspberry Pi with 8GB)
- ARM64 support
- Configuration complexity
- Integration with Cloudflare Access
- User management capabilities

**Deliverable**: Document recommendation with pros/cons

---

### 5.2 Implement Chosen Authentication Solution

**If Cloudflare Access with self-hosted OIDC**:
- [ ] Deploy chosen OIDC provider (Dex recommended for low resources)
- [ ] Configure OIDC provider with test users
- [ ] Integrate OIDC provider with Cloudflare Access
- [ ] Create Cloudflare Access application for testing
- [ ] Test authentication flow

**If Cloudflare Access only**:
- [ ] Configure Cloudflare Access with email-based authentication
- [ ] Test authentication flow
- [ ] Document user management process

**Files to create** (if deploying OIDC):
- `kubernetes/rpi-cluster/apps/security/dex/ks.yaml` (or keycloak/authentik)
- OIDC provider manifests and configuration

---

### 5.3 n8n Integration for Per-App Authentication
**Goal**: Enable n8n to configure authentication for apps that require it

- [ ] Add authentication option to workflow input (public/authenticated)
- [ ] Create Function node: "Configure Cloudflare Access"
  - Use Cloudflare API to create Access application
  - Configure authentication policy
  - Link to app hostname
  - Return policy details
- [ ] Test creating authenticated and public apps
- [ ] Document authentication configuration

---

### 5.4 Cloudflare Security Configuration
**Goal**: Configure WAF, rate limiting, and country restrictions

**Rate Limiting**:
- [ ] Configure rate limits in Cloudflare dashboard:
  - n8n webhooks: 60 req/10min per IP
  - Dynamic apps: 300 req/10min per IP
  - API endpoints: 100 req/10min per IP
- [ ] Test rate limits

**Country Restrictions**:
- [ ] Configure allowed countries: RO, DE, FR, US, GB (configurable)
- [ ] Test blocking from other countries

**WAF Rules**:
- [ ] Enable Cloudflare Managed Ruleset
- [ ] Configure OWASP Core Ruleset
- [ ] Test common attacks (SQL injection, XSS)

---

### 5.5 RBAC Hardening
**Goal**: Minimize permissions for all components

- [ ] Review and minimize n8n ServiceAccount permissions
- [ ] Review and minimize Buildah ServiceAccount permissions
- [ ] Review and minimize dynamic-apps ServiceAccount permissions
- [ ] Implement Pod Security Standards (restricted profile)
- [ ] Test deployments with restricted permissions

---

## Phase 6: Monitoring & Operations (Week 5+)

### 6.1 PostgreSQL S3 Backups
**Goal**: Implement automated database backups to S3

- [ ] Create Backblaze B2 account (or chosen S3 provider)
- [ ] Create bucket for PostgreSQL backups
- [ ] Create SOPS-encrypted secret with S3 credentials
- [ ] Configure CloudNativePG cluster with `barmanObjectStore`
- [ ] Configure backup schedule (daily at 2 AM)
- [ ] Configure retention policy (30 days)
- [ ] Test backup and restore
- [ ] Document restore procedure

**Files to update**:
- `kubernetes/rpi-cluster/apps/datastore/cloudnative-pg/clusters/postgres-cluster.yaml`
- `kubernetes/rpi-cluster/apps/datastore/cloudnative-pg/clusters/s3-credentials.sops.yaml` (new)

---

### 6.2 Custom Grafana Dashboards
**Goal**: Monitor n8n workflow and dynamic apps health

- [ ] Create Grafana dashboard: "n8n Automation Overview"
  - Workflow execution count/success rate
  - AI agent response times
  - Container build times
  - Deployment success rate
  - Registry storage usage
- [ ] Create Grafana dashboard: "Dynamic Apps Overview"
  - Active apps count
  - Resource usage per app
  - Request rates and response times
  - Error rates
- [ ] Export dashboards as JSON and commit to Git

**Files to create**:
- `kubernetes/rpi-cluster/apps/monitoring/grafana-dashboards/n8n-automation.json`
- `kubernetes/rpi-cluster/apps/monitoring/grafana-dashboards/dynamic-apps.json`

---

### 6.3 Prometheus Alerts
**Goal**: Alert on critical failures

**Tier 1 Alerts (Immediate notification)**:
- [ ] Flux reconciliation failures
- [ ] n8n workflow failures (>3 in 1 hour)
- [ ] PostgreSQL down
- [ ] Cloudflare Tunnel down
- [ ] Storage >95% full

**Tier 2 Alerts (Daily digest)**:
- [ ] Deployment success rate <80%
- [ ] Dynamic app response time >2s
- [ ] Registry storage >85%

**Tier 3 (Weekly review)**:
- [ ] Security monitoring (failed auth attempts)
- [ ] Resource trends

**Files to create**:
- `kubernetes/rpi-cluster/apps/monitoring/kube-prometheus-stack/alerts/n8n-alerts.yaml`
- `kubernetes/rpi-cluster/apps/monitoring/kube-prometheus-stack/alerts/dynamic-apps-alerts.yaml`

---

### 6.4 Documentation
**Goal**: Complete system documentation

- [ ] Update README.md with n8n automation overview
- [ ] Create DYNAMIC-APPS-GUIDE.md:
  - How to trigger webapp creation
  - Supported app types
  - Input format examples
  - Troubleshooting common issues
- [ ] Create OPERATIONS.md:
  - Backup and restore procedures
  - Disaster recovery
  - Scaling considerations
  - Cost monitoring
- [ ] Document architecture diagrams (optional)

---

## Phase 7: Future Enhancements (Beyond Week 5)

### 7.1 Advanced Features
- [ ] Add app deletion workflow
- [ ] Add app update workflow (manual trigger for rebuild)
- [ ] Implement automatic app health checks and rollback
- [ ] Add custom domain support (beyond *.apps.k8s-lab.dev)
- [ ] Implement app resource quota management
- [ ] Add database provisioning for apps that need persistence

### 7.2 Integration Enhancements
- [ ] Signal bot integration for triggering workflows
- [ ] Slack bot integration
- [ ] Web UI for non-technical users
- [ ] Template library for common app types
- [ ] Multi-cluster support (dev/staging/prod)

### 7.3 Security Enhancements
- [ ] Container image vulnerability scanning (Trivy)
- [ ] Secrets rotation automation
- [ ] Audit logging for all deployments
- [ ] Compliance reporting

---

## Decision Points & Research Needed

### Buildah on ARM64/Raspberry Pi
**Status**: Research needed in Phase 2.1
**Question**: Does Buildah perform adequately on Raspberry Pi 5 with 8GB RAM for webapp builds?
**Alternatives**: Kaniko, img, external build service
**Impact**: Core functionality - blocks Phase 2

### Namespace Strategy
**Status**: Start with shared namespace, revisit based on experience
**Question**: Shared `dynamic-apps` namespace or per-app `dynamic-app-{name}` namespaces?
**Recommendation**: Start with shared for simplicity, document migration path
**Impact**: Medium - affects isolation and resource management

### Webapp Code Repository Strategy
**Status**: Decision needed in Phase 3.4
**Options**:
- **Option A (Recommended)**: Single `homelab-webapps` repository with directory per app
  - Pros: Simpler, easier to browse, single webhook, less overhead
  - Cons: Less isolation, shared CI/CD config
- **Option B**: One repository per webapp
  - Pros: Better isolation, independent versioning, more scalable
  - Cons: More complex, more webhooks, harder to manage

**Recommendation**: Start with Option A (single repo), provides sufficient isolation for homelab use case

**Impact**: Medium - affects GitHub management and CI/CD complexity

### Authentication Solution
**Status**: Research needed in Phase 5.1
**Question**: Cloudflare Access only, or with self-hosted OIDC (Dex/Keycloak)?
**Criteria**: ARM64 support, memory footprint, ease of use
**Impact**: Medium - affects user management complexity

---

## Success Criteria

### Phase 1-3 Success
- [ ] Flux webhook receiver functional (<30s reconciliation)
- [ ] Docker registry accessible at registry.k8s-lab.dev
- [ ] n8n registry user credentials verified and working
- [ ] Dynamic apps infrastructure deployed
- [ ] Variable substitution working
- [ ] Wildcard DNS routing functional
- [ ] Buildah can build and push images
- [ ] n8n can push to Git via SSH
- [ ] Webapp code repository strategy decided and implemented

### Phase 4 Success (Core Functionality)
- [ ] End-to-end workflow: User request → Deployed webapp in <2 minutes
- [ ] AI agents generating valid code
- [ ] Container images building successfully
- [ ] GitOps manifests generated correctly
- [ ] Webapp source code committed to repository
- [ ] Apps accessible at `<name>.apps.k8s-lab.dev`
- [ ] Flux image automation working (code push → auto deploy)
- [ ] Minimal manual intervention required

### Phase 5-6 Success (Production Ready)
- [ ] Per-app authentication working
- [ ] Rate limiting and country restrictions active
- [ ] Database backups configured and tested
- [ ] Monitoring dashboards deployed
- [ ] Critical alerts configured
- [ ] Documentation complete

---

## Risk Mitigation

### Risk: Buildah performance issues on ARM64
**Mitigation**: Research early (Phase 2.1), have Kaniko as backup

### Risk: n8n workflow complexity causes maintenance burden
**Mitigation**: Modular workflow design, comprehensive documentation, version control

### Risk: Cloudflare Tunnel wildcard routing limitations
**Mitigation**: Research early (Phase 1.5), have HTTPRoute fallback

### Risk: AI-generated code quality varies
**Mitigation**: Implement validation, code sanitization, manual review option

### Risk: Storage exhaustion from container images
**Mitigation**: Monitor registry storage, implement cleanup policy, alerts at 85%

### Risk: GitHub Actions concurrent builds overwhelming registry
**Mitigation**: GitHub Actions concurrency limits, rate monitoring

### Risk: Security vulnerabilities in dynamically deployed apps
**Mitigation**: Image scanning, security policies, network segmentation, Cloudflare WAF

---

## Timeline Summary

- **Week 1**: Infrastructure (Flux webhook, registry exposure, dynamic-apps namespace, variables, wildcard DNS)
- **Week 2**: Container builds (Buildah research/deploy) + GitHub integration (SSH key, Git ops, webhook, webapp repo strategy)
- **Week 3-4**: n8n workflow development (AI agents, build pipeline, manifest generation, webapp repo commits, testing)
- **Week 4-5**: Security & monitoring (authentication, rate limits, dashboards, alerts, backups)
- **Week 5+**: Future enhancements (advanced features, integrations)

**Target for MVP**: End of Week 4 - Basic workflow functional with security hardening

---

## Notes

- This plan prioritizes getting core functionality working first (Phases 1-4), then adding security and operational maturity (Phases 5-6)
- All secrets must be SOPS-encrypted before committing to Git
- Follow existing GitOps patterns documented in GITOPS.md
- Test each phase thoroughly before proceeding to next
- Document decisions and learnings in this file or separate ADR (Architecture Decision Records)
- Be prepared to adjust timeline based on Buildah research outcome
- **n8n registry user already exists** - verify credentials in Phase 1.2 instead of creating new user
- **Webapp code repository strategy** - Single repository recommended for homelab simplicity, can migrate to per-app repos later if needed
- **Flux image automation** - Enables automatic manifest updates when new images are pushed, reducing manual intervention
