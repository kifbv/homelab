# Build System Infrastructure

This directory contains the infrastructure for building container images on the ARM64 Kubernetes cluster using BuildKit.

## Architecture

The build system consists of:

1. **BuildKit**: Container image builder (moby/buildkit:v0.18.2)
2. **Job-based builds**: Ephemeral Jobs triggered by n8n automation
3. **Registry integration**: Pushes built images to internal registry (`registry.k8s-lab.dev`)
4. **RBAC**: Permissions for n8n to manage build Jobs

## Components

### Namespace

- **Name**: `build-system`
- **Purpose**: Isolates build infrastructure and jobs

### Service Account

- **Name**: `buildkit-sa`
- **Purpose**: Used by BuildKit Jobs to access registry credentials

### RBAC

- **Role**: `build-job-manager`
  - Permissions to create/manage Jobs in `build-system` namespace
  - Permissions to get Pod logs and exec into Pods

- **RoleBinding**: `n8n-build-manager`
  - Binds `build-job-manager` role to n8n ServiceAccount (`automation/n8n`)

### Registry Credentials

- **Secret**: `registry-credentials`
  - Reflected from `registry` namespace via Reflector
  - Contains Docker config JSON for authenticating with internal registry
  - Mounted at `/root/.docker` in BuildKit containers

## BuildKit Migration

We migrated from Kaniko to BuildKit for the following reasons:

1. **Active maintenance**: Kaniko was archived by Google in June 2025
2. **Performance**: BuildKit is ~3x faster than Kaniko
3. **Features**: Better caching, concurrent builds, multi-platform support
4. **ARM64 support**: First-class ARM64 support (Raspberry Pi 5)

## Usage for n8n Workflows

### Job Template

The `buildkit-job-template.yaml` file contains a template that n8n workflows should use to create build Jobs.

**Required substitutions:**

- `${JOB_NAME}`: Unique job name (e.g., `build-app-example-1234567890`)
- `${WEBAPP_NAME}`: Webapp name (e.g., `app-example`)
- `${GIT_REPO_URL}`: Git repository URL (e.g., `https://github.com/kifbv/homelab-webapps.git`)
- `${GIT_SUBDIRECTORY}`: Subdirectory containing the app (e.g., `_example` or `apps/my-app`)
- `${IMAGE_TAG}`: Full image tag (e.g., `registry.k8s-lab.dev/webapp/app-example:v1.0.0`)

**Example n8n workflow snippet:**

```javascript
// Read the BuildKit Job template
const templateYaml = await k8s.readFile('/path/to/buildkit-job-template.yaml');

// Substitute placeholders
const jobYaml = templateYaml
  .replace(/\${JOB_NAME}/g, `build-${webappName}-${Date.now()}`)
  .replace(/\${WEBAPP_NAME}/g, webappName)
  .replace(/\${GIT_REPO_URL}/g, 'https://github.com/kifbv/homelab-webapps.git')
  .replace(/\${GIT_SUBDIRECTORY}/g, appSubdirectory)
  .replace(/\${IMAGE_TAG}/g, `registry.k8s-lab.dev/webapp/${webappName}:${version}`);

// Create the Job
await k8s.apply(jobYaml, 'build-system');

// Wait for Job completion
await k8s.waitForJobCompletion(jobName, 'build-system', 300); // 5 min timeout

// Get build logs
const logs = await k8s.getJobLogs(jobName, 'build-system');
```

### Job Lifecycle

1. **Creation**: n8n creates Job from template with substituted values
2. **Init container**: `git-clone` clones repository and copies app code to workspace
3. **Build container**: `buildkit` starts daemon, builds image, pushes to registry
4. **Cleanup**: Job is automatically deleted 600 seconds after completion (ttlSecondsAfterFinished)

### Monitoring

Check build Job status:

```bash
kubectl -n build-system get jobs
kubectl -n build-system get jobs -l webapp=app-example
```

View build logs:

```bash
kubectl -n build-system logs job/build-app-example-1234567890
```

### Troubleshooting

**Build fails with "operation not permitted":**

- BuildKit requires `privileged: true` for bind mounts
- Verify the securityContext is set correctly

**Build fails with "401 Unauthorized" when pushing:**

- Verify `registry-credentials` secret exists in `build-system` namespace
- Check secret is mounted at `/root/.docker` in BuildKit container
- Verify Reflector is working: `kubectl get secret registry-credentials -n build-system`

**Git clone fails:**

- Check Git repository URL is accessible from cluster
- For private repositories, add SSH key secret and mount in git-clone initContainer

**Out of memory:**

- Increase memory limits in Job template (default: 2Gi)
- Check node resources: `kubectl top nodes`

## Registry Query Utility

**Note**: The registry-query deployment currently has an issue (crane image doesn't include /bin/sh). This needs to be fixed before n8n workflows can query image versions.

**TODO**: Fix registry-query deployment to use a proper shell-based image or change the command approach.

## Security Considerations

1. **Privileged containers**: BuildKit requires privileged mode for bind mounts
   - Acceptable for ephemeral build Jobs
   - Jobs run in isolated `build-system` namespace

2. **Registry credentials**: Stored as Kubernetes Secret
   - Encrypted at rest with SOPS
   - Only accessible to build-system namespace

3. **RBAC**: n8n has minimal permissions
   - Can only create/manage Jobs in `build-system` namespace
   - Cannot modify infrastructure or other namespaces

## Performance

BuildKit performance on Raspberry Pi 5 (ARM64):

- **Node.js example app**: ~60 seconds (including git clone, npm install, push)
- **Multi-stage builds**: Efficient layer caching reduces rebuild time
- **Concurrent builds**: Multiple Jobs can run in parallel (resource-limited)

## Future Improvements

1. **Build cache**: Implement persistent cache volume for faster rebuilds
2. **Multi-platform builds**: Enable ARM64 + AMD64 builds if needed
3. **Registry query**: Fix registry-query deployment for version detection
4. **Metrics**: Add build time metrics to Prometheus
5. **Notifications**: Send build status to n8n via webhooks
