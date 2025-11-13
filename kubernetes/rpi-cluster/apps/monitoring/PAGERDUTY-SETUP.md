# PagerDuty Integration Setup

## Prerequisites

✅ PagerDuty account created
✅ Service created in PagerDuty
✅ Events API V2 integration added to service
✅ Integration Key obtained (also called Routing Key)

## Setup Instructions

### Step 1: Add PagerDuty Integration Key to Cluster Secrets

On your **other computer** (with SOPS age key), edit the encrypted secrets:

```bash
# Edit the encrypted cluster secrets
sops kubernetes/rpi-cluster/flux/settings/cluster-secrets.sops.yaml
```

Add the following to the `stringData` section:

```yaml
stringData:
  # ... existing secrets ...

  # PagerDuty integration key for critical alerts
  PAGERDUTY_INTEGRATION_KEY: "your-integration-key-here"

  # Optional: Add CLUSTER_DOMAIN if not already present
  CLUSTER_DOMAIN: "k8s-lab.dev"
```

Save and exit. SOPS will automatically re-encrypt the file.

### Step 2: Verify the Configuration

After committing and pushing the changes, Flux will:

1. Decrypt the secret using the age key
2. Substitute `${PAGERDUTY_INTEGRATION_KEY}` in the AlertManager config
3. Restart AlertManager with the new configuration

**Verify AlertManager picked up the config:**

```bash
# Check AlertManager pod logs
kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager --tail=50

# Port forward to AlertManager UI
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

# Visit http://localhost:9093
# Click "Status" → should see "pagerduty-critical" receiver configured
```

### Step 3: Test the Integration

**Option A: Trigger a test alert manually**

```bash
# Create a test PrometheusRule
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-alert
  namespace: monitoring
  labels:
    app: kube-prometheus-stack
    release: kube-prometheus-stack
spec:
  groups:
    - name: test
      interval: 1m
      rules:
        - alert: TestCriticalAlert
          expr: vector(1)
          for: 1m
          labels:
            severity: critical
            component: test
          annotations:
            summary: "This is a test critical alert"
            description: "Testing PagerDuty integration"
EOF

# Wait 2-3 minutes for alert to fire
# Check PagerDuty for incident

# Clean up test alert
kubectl delete prometheusrule test-alert -n monitoring
```

**Option B: Use AlertManager API**

```bash
# Port forward to AlertManager
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

# Send test alert
curl -XPOST http://localhost:9093/api/v1/alerts -d '[
  {
    "labels": {
       "alertname": "TestPagerDutyIntegration",
       "severity": "critical",
       "instance": "test-instance"
    },
    "annotations": {
       "summary": "Test alert for PagerDuty integration"
    }
  }
]'

# Check PagerDuty for incident within 1-2 minutes
```

## Alert Routing Configuration

### Critical Alerts → PagerDuty (Immediate)

**Routing:**
- Severity: `critical`
- Group wait: 10 seconds
- Group interval: 1 minute (updates to same incident)
- Repeat interval: 5 minutes (if not acknowledged)

**Examples of critical alerts:**
- Node not ready
- Ceph cluster health ERROR
- PostgreSQL cluster down
- Flux reconciliation failed
- Rook/CloudNativePG operator down
- Cilium agent not ready

### Warning Alerts → AlertManager UI Only (Batched)

**Routing:**
- Severity: `warning`
- Group wait: 30 seconds
- Group interval: 5 minutes (batched updates)
- Repeat interval: 12 hours
- **Not sent to PagerDuty** (UI only)

**Examples of warning alerts:**
- Ceph storage utilization >85%
- PostgreSQL connection pool high
- Node memory/disk pressure
- Pod crash looping
- High resource usage

## PagerDuty Incident Details

When a critical alert fires, PagerDuty will receive:

**Incident Title:** Alert summary from Prometheus
**Description:** Detailed description from PrometheusRule annotations
**Severity:** Critical
**Client:** Homelab Kubernetes Cluster
**Client URL:** Link to Grafana (if CLUSTER_DOMAIN is set)

**Custom Details:**
- Number of firing alerts
- Number of resolved alerts
- Detailed alert information (pod names, namespaces, values, etc.)

## Troubleshooting

### AlertManager not sending to PagerDuty

**Check AlertManager configuration:**
```bash
kubectl get secret -n monitoring alertmanager-kube-prometheus-stack-alertmanager -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
```

Look for:
- `routing_key` should NOT be `${PAGERDUTY_INTEGRATION_KEY}` (should be the actual key)
- If you see the literal `${PAGERDUTY_INTEGRATION_KEY}`, the substitution didn't work

**Fix:** Verify cluster-secrets has the key and Flux Kustomization has postBuild.substituteFrom configured.

### Alerts not firing

**Check Prometheus rules are loaded:**
```bash
kubectl get prometheusrule -n monitoring
```

**Check AlertManager status:**
```bash
# Port forward
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

# Visit http://localhost:9093
# Click "Alerts" - should see your alerts listed
```

### PagerDuty not creating incidents

**Verify integration key is correct:**
- Log into PagerDuty
- Go to Services → Your Service → Integrations
- Check the integration key matches what you added to cluster-secrets

**Check AlertManager logs:**
```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=alertmanager -f | grep pagerduty
```

Look for errors like:
- `HTTP 400` - Invalid integration key format
- `HTTP 401` - Wrong integration key
- `HTTP 403` - Integration disabled

## Customization

### Change Alert Severity Routing

To send warnings to PagerDuty too:

```yaml
# In release.yaml, add another route
- receiver: 'pagerduty-warning'
  matchers:
    - severity = "warning"
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 1h
```

### Add Multiple PagerDuty Services

```yaml
# Create different receivers for different components
receivers:
  - name: 'pagerduty-storage'
    pagerduty_configs:
      - routing_key: ${PAGERDUTY_STORAGE_KEY}

  - name: 'pagerduty-database'
    pagerduty_configs:
      - routing_key: ${PAGERDUTY_DATABASE_KEY}
```

Then add routing rules by component:
```yaml
routes:
  - receiver: 'pagerduty-storage'
    matchers:
      - component = "storage"
      - severity = "critical"
```

## Related Documentation

- [PagerDuty Prometheus Integration](https://www.pagerduty.com/docs/guides/prometheus-integration-guide/)
- [AlertManager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Flux Variable Substitution](https://fluxcd.io/flux/components/kustomize/kustomizations/#variable-substitution)

## Summary

✅ AlertManager configured with PagerDuty integration
✅ Critical alerts → PagerDuty (immediate)
✅ Warning alerts → AlertManager UI (batched, no PagerDuty)
✅ Uses Flux variable substitution for secrets
✅ Ready to deploy once secret is encrypted
