# Questions and Answers

## Your Questions from Architecture Document

### Q1: Base64-encoded tunnel credentials security (Line 267)

**Question**: "Base64-encoded does not sound very secure, shouldn't these be references to SOPS-encrypted k8s secrets? This is what you seem to suggest below in the Implementation Roadmap (Phase 1, Step 2)"

**Answer**: YES, you're absolutely correct! The example was showing the variable substitution pattern, but the actual values should come from SOPS-encrypted secrets. Here's the corrected flow:

**Correct Implementation:**

1. **Store credentials in SOPS secret:**
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
    {
      "AccountTag": "...",
      "TunnelSecret": "...",
      "TunnelID": "..."
    }
  cert.pem: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
```

2. **Encrypt with SOPS:**
```bash
sops --encrypt --in-place flux/settings/cloudflare-tunnel.sops.yaml
```

3. **Reference in Flux Kustomization:**
```yaml
# infrastructure/network/cloudflared/ks.yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: flux-sops
  postBuild:
    substituteFrom:
      - kind: Secret
        name: cloudflare-tunnel-credentials
```

4. **Use variables in HelmRelease:**
```yaml
# infrastructure/network/cloudflared/app/release.yaml
spec:
  values:
    tunnelSecrets:
      # These variables are substituted from the SOPS secret
      base64EncodedConfigJsonFile: ${CLOUDFLARE_TUNNEL_CREDENTIALS_JSON}
      base64EncodedCertPemFile: ${CLOUDFLARE_TUNNEL_CERT_PEM}
```

**Key Point**: The base64 encoding is just for the Helm chart format. The actual secret values are:
- Encrypted in Git with SOPS
- Only decrypted in-cluster by Flux
- Never stored in plaintext

---

### Q2: Hiding URLs and timezone in public repo (Line 346)

**Question**: "is there a way to use secrets for the timezone, WEBHOOK_URL and N8N_EDITOR_BASE_URL? even is the site will be public i'd prefer not to have these informations in clear in my public github repo. For instance, is it possible to have only the leftmost part of the url in the config files and transform it into the full url with a PrefixSuffixTransformer kustomization? Same question for the n8n generated manifests."

**Answer**: YES! Multiple solutions available:

#### Solution 1: Use Flux postBuild substitution (RECOMMENDED)

**Step 1: Store domain in SOPS secret:**
```yaml
# flux/settings/cluster-secrets.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cluster-secrets
  namespace: flux-system
type: Opaque
stringData:
  CLUSTER_DOMAIN: k8s-lab.dev
  TIMEZONE: Europe/Bucharest
```

**Step 2: Reference in Kustomization:**
```yaml
# apps/automation/n8n/ks.yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: flux-sops
  postBuild:
    substituteFrom:
      - kind: Secret
        name: cluster-secrets
```

**Step 3: Use variables in manifests:**
```yaml
# apps/automation/n8n/app/release.yaml
spec:
  values:
    config:
      generic:
        timezone: ${TIMEZONE}
        WEBHOOK_URL: https://n8n.${CLUSTER_DOMAIN}
        N8N_EDITOR_BASE_URL: https://n8n.${CLUSTER_DOMAIN}
```

**Result**: Public repo only shows `${CLUSTER_DOMAIN}`, actual domain substituted by Flux at deployment time.

#### Solution 2: Kustomize replacements (Alternative)

```yaml
# apps/automation/n8n/app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - release.yaml

replacements:
  - source:
      kind: Secret
      name: cluster-secrets
      fieldPath: data.CLUSTER_DOMAIN
    targets:
      - select:
          kind: HelmRelease
        fieldPaths:
          - spec.values.config.generic.WEBHOOK_URL
          - spec.values.config.generic.N8N_EDITOR_BASE_URL
        options:
          delimiter: '.'
          index: 1  # Replace the domain part
```

**Recommendation**: Use Solution 1 (Flux postBuild) - simpler and more GitOps-friendly.

#### For n8n Generated Manifests

n8n should also use variables in generated manifests:

```javascript
// n8n Code Node
const domain = process.env.CLUSTER_DOMAIN || 'k8s-lab.dev';

const httproute = {
  apiVersion: "gateway.networking.k8s.io/v1",
  kind: "HTTPRoute",
  metadata: {
    name: appName,
    namespace: "dynamic-apps"
  },
  spec: {
    hostnames: [
      `${appName}.apps.\${CLUSTER_DOMAIN}`  // Use variable, not hardcoded
    ],
    // ...
  }
};
```

The `${CLUSTER_DOMAIN}` will be substituted by Flux when the manifest is applied.

---

### Q3: Flux notification controller exposure (Line 663)

**Question**: "is Flux notification controller already exposed? i.e. can we POST to that url?"

**Answer**: NO, by default it's NOT exposed externally. Two options:

#### Option 1: Webhook Receiver (RECOMMENDED - already documented in addendum)

This is the proper Flux way:
- Deploy `Receiver` resource
- Expose via Cloudflare Tunnel
- Git webhook calls external URL
- Flux validates and reconciles

Already fully documented in `PUBLIC-EXPOSURE-IMPLEMENTATION-ADDENDUM.md`.

#### Option 2: Direct POST from n8n (Internal cluster access)

Since n8n runs in the cluster, it CAN directly POST to notification-controller:

```javascript
// n8n HTTP Request Node (runs in cluster)
{
  "method": "POST",
  "url": "http://notification-controller.flux-system.svc.cluster.local:9292/api/v1/namespaces/flux-system/kustomizations/cluster-apps/reconcile",
  "authentication": "none",  // Internal cluster traffic
  "headers": {
    "Content-Type": "application/json"
  }
}
```

**OR use kubectl annotation (simpler):**

```javascript
// n8n Execute Command Node
const command = `
kubectl annotate kustomization cluster-apps \
  -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" \
  --overwrite
`;
```

**Recommendation**:
- For Git webhooks (external): Use Receiver + Cloudflare Tunnel
- For n8n triggers (internal): Use kubectl annotation (simpler)

---

## Your Answers to My Questions

### 1. Domain

**Answer**: `k8s-lab.dev` (existing with Porkbun), transfer to Cloudflare if possible. Otherwise, new domain from Cloudflare.

**Recommendation**:

**Option A: Transfer k8s-lab.dev to Cloudflare** (RECOMMENDED)
- Keep existing domain
- Transfer is free (just pay for renewal)
- Cloudflare's registrar pricing is typically cheaper
- Full Cloudflare Tunnel integration

**Steps to transfer:**
1. Unlock domain at Porkbun
2. Get EPP/auth code from Porkbun
3. Go to Cloudflare → Domain Registration → Transfer
4. Enter domain and auth code
5. Approve transfer email

**Option B: Keep at Porkbun, use Cloudflare DNS only**
- Change nameservers at Porkbun to Cloudflare's NS
- Cloudflare Tunnel works fine with this setup
- No transfer needed

**Recommendation**: Try Option B first (just change nameservers). If you encounter issues, do Option A (full transfer).

### 2. Subdomains

**Answer**: `*.apps` is perfect for app subdomains.

**Confirmed structure:**
```
n8n.k8s-lab.dev                    → n8n UI
registry.k8s-lab.dev               → Docker registry
flux-webhook.k8s-lab.dev           → Flux webhook receiver
homepage.k8s-lab.dev               → Homepage
linkding.k8s-lab.dev               → Linkding
grafana.k8s-lab.dev                → Grafana
*.apps.k8s-lab.dev                 → Dynamic webapps
  └─ myapp-123.apps.k8s-lab.dev
  └─ another-456.apps.k8s-lab.dev
```

### 3. Authentication

**Answer**: Some dynamic apps may require authentication.

**Recommended Approach**:

**Default: Public (no auth)**
- Most dynamic webapps publicly accessible
- Simpler for testing and demos

**Per-app authentication via labels:**

n8n can add authentication requirement via labels:

```yaml
# n8n generates this in manifest
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: dynamic-apps
  labels:
    auth-required: "true"  # n8n sets this based on user input
```

**Cloudflare Access policy (automatic):**

Use Cloudflare API to create Access policy when `auth-required: true`:

```javascript
// n8n HTTP Request Node - Create Cloudflare Access policy
{
  "method": "POST",
  "url": "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps",
  "headers": {
    "Authorization": "Bearer ${CLOUDFLARE_API_TOKEN}",
    "Content-Type": "application/json"
  },
  "body": {
    "name": `${appName} - Authentication`,
    "domain": `${appName}.apps.k8s-lab.dev`,
    "session_duration": "24h",
    "allowed_idps": ["${CLOUDFLARE_IDP_ID}"],
    "policies": [{
      "name": "Allow authenticated users",
      "decision": "allow",
      "include": [{
        "email_domain": {
          "domain": "your-domain.com"
        }
      }]
    }]
  }
}
```

**Implementation**: Add this as optional step in n8n workflow (triggered by `requireAuth: true` in input).

### 4. Rate Limits

**Answer**: Human activity rate, restrict to specific countries.

**Recommended Configuration**:

**Cloudflare Rate Limiting Rules:**

**Rule 1: n8n Webhooks (moderate)**
```
URL: n8n.k8s-lab.dev/webhook/*
Rate: 60 requests per 10 minutes per IP
Action: Block for 1 hour
```

**Rule 2: Dynamic Apps (relaxed)**
```
URL: *.apps.k8s-lab.dev/*
Rate: 300 requests per 10 minutes per IP
Action: Challenge (CAPTCHA)
```

**Rule 3: API endpoints (strict)**
```
URL: */api/*
Rate: 100 requests per 10 minutes per IP
Action: Block for 30 minutes
```

**Country Restrictions (Cloudflare Firewall Rules):**

**Allow only specific countries:**
```
Expression:
(ip.geoip.country in {"RO" "DE" "FR" "US" "GB"})

Action: Allow
```

**Block all others:**
```
Expression:
(not ip.geoip.country in {"RO" "DE" "FR" "US" "GB"})

Action: Block
```

**Recommendation**:
- Start with: Romania (RO), US, Germany (DE), France (FR), UK (GB)
- Adjust based on legitimate traffic needs
- Configure in Cloudflare Dashboard → Security → WAF → Firewall Rules

### 5. Monitoring

**Answer**: Not sure yet, wants recommendations for most important ones.

**Critical Metrics to Monitor:**

#### **Tier 1: Immediate Action Required (Alerts)**

1. **Flux Reconciliation Failures**
   - **Alert**: Any Kustomization or HelmRelease in failed state
   - **Threshold**: Immediate (1 failure)
   - **Action**: Check Flux logs, investigate Git commit

2. **n8n Workflow Failures**
   - **Alert**: Workflow execution failed
   - **Threshold**: 2+ failures in 10 minutes
   - **Action**: Check n8n logs, review workflow logic

3. **PostgreSQL Down**
   - **Alert**: CloudNativePG cluster unhealthy
   - **Threshold**: Immediate
   - **Action**: Check PostgreSQL logs, verify storage

4. **Cloudflare Tunnel Down**
   - **Alert**: cloudflared pods not ready
   - **Threshold**: > 5 minutes
   - **Action**: Check cloudflared logs, verify Cloudflare status

5. **Storage Critical**
   - **Alert**: Ceph storage > 85% full
   - **Threshold**: 85% (warning), 95% (critical)
   - **Action**: Clean up old images, expand storage

#### **Tier 2: Monitor Trends (Dashboards)**

1. **Deployment Success Rate**
   - % of successful n8n-triggered deployments
   - Target: > 95%

2. **Response Times**
   - p95 response time for all apps
   - Target: < 500ms

3. **Resource Usage**
   - CPU/Memory per namespace
   - Track dynamic-apps namespace growth

4. **Docker Registry Storage**
   - Registry PVC usage
   - Number of images/tags

5. **Git Repository Activity**
   - Commits per day from n8n
   - Flux reconciliation frequency

#### **Tier 3: Security Monitoring (Weekly Review)**

1. **Failed Authentication Attempts** (Cloudflare Access)
2. **WAF Blocks** (Cloudflare Security Events)
3. **Rate Limit Triggers**
4. **Unusual Traffic Patterns**
5. **Unauthorized Git Commits** (not from n8n)

**Grafana Dashboard Panels** (create custom dashboard):

```
Row 1: Cluster Health
- Flux Kustomizations Status (gauge)
- HelmReleases Status (gauge)
- Pod Status by Namespace (graph)
- Node Resource Usage (graph)

Row 2: n8n Automation
- Workflow Executions (counter)
- Workflow Success Rate (gauge)
- Execution Duration (histogram)
- Active Workflows (gauge)

Row 3: Applications
- Dynamic Apps Count (counter)
- App Response Times (graph)
- App Error Rates (graph)
- Active Connections (gauge)

Row 4: Infrastructure
- PostgreSQL Connections (graph)
- Registry Storage Usage (gauge)
- Ceph Storage Usage (graph)
- Cloudflare Tunnel Uptime (gauge)
```

**Alerting Setup** (Prometheus AlertManager):

```yaml
# Example alert rules
groups:
  - name: flux
    interval: 1m
    rules:
      - alert: FluxReconciliationFailed
        expr: gotk_reconcile_condition{type="Ready",status="False"} == 1
        for: 5m
        annotations:
          summary: "Flux reconciliation failed for {{ $labels.name }}"

      - alert: HelmReleaseFailed
        expr: gotk_resource_info{type="HelmRelease",ready="False"} == 1
        for: 5m
        annotations:
          summary: "HelmRelease {{ $labels.name }} failed"

  - name: storage
    interval: 5m
    rules:
      - alert: CephStorageCritical
        expr: ceph_cluster_total_used_bytes / ceph_cluster_total_bytes > 0.85
        for: 10m
        annotations:
          summary: "Ceph storage > 85% full"

      - alert: RegistryStorageFull
        expr: kubelet_volume_stats_used_bytes{persistentvolumeclaim="docker-registry"} / kubelet_volume_stats_capacity_bytes > 0.90
        for: 10m
        annotations:
          summary: "Docker registry storage > 90% full"
```

### 6. Backup Strategy

**Answer**: Offsite backups to S3.

**Recommended Setup**: CloudNativePG with S3 backups

**Implementation:**

#### Step 1: S3 Credentials Secret

```yaml
# apps/datastore/cloudnative-pg/clusters/s3-credentials.sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: s3-backup-credentials
  namespace: datastore
type: Opaque
stringData:
  ACCESS_KEY_ID: <your-s3-access-key>
  ACCESS_SECRET_KEY: <your-s3-secret-key>
```

Encrypt with SOPS:
```bash
sops --encrypt --in-place apps/datastore/cloudnative-pg/clusters/s3-credentials.sops.yaml
```

#### Step 2: Configure Backup in PostgreSQL Cluster

```yaml
# apps/datastore/cloudnative-pg/clusters/postgres-example.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
  namespace: datastore
spec:
  instances: 1

  # Storage
  storage:
    size: 20Gi
    storageClass: rook-ceph-block

  # Backup configuration
  backup:
    barmanObjectStore:
      destinationPath: s3://your-bucket-name/postgres-backups/
      endpointURL: https://s3.amazonaws.com  # Or your S3-compatible provider

      s3Credentials:
        accessKeyId:
          name: s3-backup-credentials
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-backup-credentials
          key: ACCESS_SECRET_KEY

      # WAL (Write-Ahead Log) backup
      wal:
        compression: gzip
        maxParallel: 2

      # Data backup
      data:
        compression: gzip
        jobs: 2

    # Retention policy
    retentionPolicy: "30d"  # Keep 30 days of backups

  # Backup schedule
  externalClusters: []
```

#### Step 3: Create Backup Schedule

```yaml
# apps/datastore/cloudnative-pg/clusters/backup-schedule.yaml
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-daily-backup
  namespace: datastore
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  backupOwnerReference: self
  cluster:
    name: postgres-cluster
  immediate: false  # Don't backup immediately on creation
```

#### Step 4: S3 Bucket Configuration

**Recommended S3 Providers:**

1. **AWS S3** (Most reliable)
   - Cost: ~$0.023/GB/month
   - Estimated: 10GB backups = $0.23/month

2. **Backblaze B2** (Cheapest)
   - Cost: $0.005/GB/month
   - Estimated: 10GB backups = $0.05/month
   - S3-compatible API

3. **Wasabi** (Good balance)
   - Cost: $0.0059/GB/month (1TB minimum)
   - Flat pricing

**Recommendation**: Start with **Backblaze B2** (cheapest, S3-compatible).

**Bucket Lifecycle Policy** (to reduce costs):
```
Rule 1: Transition to Glacier after 7 days
Rule 2: Delete backups older than 90 days
```

#### Step 5: Test Restore

```bash
# List available backups
kubectl cnpg backup list postgres-cluster -n datastore

# Create restore cluster from backup
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restore-test
  namespace: datastore
spec:
  instances: 1
  bootstrap:
    recovery:
      source: postgres-cluster
      recoveryTarget:
        targetTime: "2025-01-15 10:00:00"  # Point-in-time restore
  externalClusters:
    - name: postgres-cluster
      barmanObjectStore:
        destinationPath: s3://your-bucket-name/postgres-backups/
        # ... same S3 config as above
EOF
```

**Monitoring Backups:**

```bash
# Check last backup status
kubectl get backup -n datastore

# View backup logs
kubectl logs -n datastore -l app.kubernetes.io/name=cloudnative-pg -f
```

---

## Updated Recommendations Summary

### Security Improvements

1. ✅ **SOPS for all sensitive data** - tunnel credentials, domain, timezone
2. ✅ **Flux postBuild substitution** - hide domain in public repo
3. ✅ **Cloudflare Access** - optional per-app authentication
4. ✅ **Country restrictions** - Cloudflare Firewall Rules
5. ✅ **Rate limiting** - tiered by endpoint type

### Monitoring Setup

**Week 1 (Immediate):**
- Flux reconciliation alerts
- PostgreSQL health alerts
- Storage capacity alerts

**Week 2 (Important):**
- n8n workflow execution monitoring
- Cloudflare Tunnel uptime
- Resource usage trends

**Week 3 (Nice-to-have):**
- Custom Grafana dashboard
- Security event monitoring
- Performance metrics

### Backup Configuration

**Implementation:**
1. S3 bucket with Backblaze B2 (cheapest)
2. CloudNativePG automatic backups (daily)
3. 30-day retention policy
4. WAL archiving (point-in-time recovery)
5. Test restore procedure quarterly

### Domain Setup

**Preferred Approach:**
1. Transfer k8s-lab.dev to Cloudflare (recommended)
2. Or change nameservers to Cloudflare (simpler)
3. Configure CNAME records for all subdomains
4. Use `${CLUSTER_DOMAIN}` variable in manifests

---

## Next Steps

1. **Review this Q&A document**
2. **Decide on domain strategy** (transfer vs nameserver change)
3. **Choose S3 provider** (recommend Backblaze B2)
4. **Set up Cloudflare account**
5. **Begin Phase 1 implementation** (Cloudflare Tunnel)

All your questions are now addressed with production-ready solutions!
