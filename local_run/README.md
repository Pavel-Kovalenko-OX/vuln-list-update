# Self-Hosted Vulnerability List Updater

This directory contains scripts and configurations to run vuln-list-update independently from GitHub Actions, suitable for Kubernetes CronJob deployment.

## Overview

The self-hosted solution replaces GitHub Actions workflows with:
- **Shell script** (`update-all.sh`) - Performs all update operations
- **Dockerfile** - Containerizes the updater
- **Kubernetes manifests** - CronJob for automated updates

## Prerequisites

### GitLab Setup

1. **Create GitLab repositories** (if not exists):
   - `vuln-list`
   - `vuln-list-nvd`
   - `vuln-list-debian`
   - `vuln-list-redhat`

2. **Generate GitLab Personal Access Token**:
   - Navigate to: User Settings → Access Tokens
   - Scopes: `read_repository`, `write_repository`
   - Save the token securely

3. **NVD API Key** (optional but recommended):
   - Register at: https://nvd.nist.gov/developers/request-an-api-key
   - Without key: 5 requests/30 seconds
   - With key: 50 requests/30 seconds

## Local Testing

### Using Docker

```bash
# Build the image
docker build -f local_run/Dockerfile -t vuln-list-updater:latest .

# Run interactively
docker run -it --rm \
  -e GITLAB_TOKEN="your-token" \
  -e GITLAB_BASE_URL="https://gitlab.example.com" \
  -e GITLAB_GROUP="security/vulnerability-data" \
  -e NVD_API_KEY="your-nvd-key" \
  vuln-list-updater:latest

# Or run specific target only (for testing)
docker run -it --rm \
  -e GITLAB_TOKEN="your-token" \
  -e GITLAB_BASE_URL="https://gitlab.example.com" \
  -e GITLAB_GROUP="security/vulnerability-data" \
  vuln-list-updater:latest \
  bash -c "cd /app && go build -o vuln-list-update . && \
    mkdir -p /workspace/vuln-list && \
    git clone https://oauth2:${GITLAB_TOKEN}@gitlab.example.com/security/vulnerability-data/vuln-list.git /workspace/vuln-list && \
    ./vuln-list-update -vuln-list-dir /workspace/vuln-list -target alpine"
```

### Using Shell Script Directly

```bash
# Export required environment variables
export GITLAB_TOKEN="your-token"
export GITLAB_BASE_URL="https://gitlab.example.com"
export GITLAB_GROUP="security/vulnerability-data"
export NVD_API_KEY="your-nvd-key"
export WORK_DIR="/tmp/vuln-updates"

# Run the script
bash local_run/update-all.sh
```

## Kubernetes Deployment

### 1. Update Configuration

Edit `k8s-cronjob.yaml`:

```yaml
# Update ConfigMap
data:
  GITLAB_BASE_URL: "https://gitlab.example.com"
  GITLAB_GROUP: "security/vulnerability-data"

# Update Secret
stringData:
  GITLAB_TOKEN: "your-gitlab-token"
  NVD_API_KEY: "your-nvd-api-key"
```

### 2. Build and Push Image

```bash
# Build
docker build -f local_run/Dockerfile -t your-registry/vuln-list-updater:latest .

# Push to your registry
docker push your-registry/vuln-list-updater:latest
```

### 3. Deploy to Kubernetes

```bash
# Create namespace
kubectl create namespace security

# Deploy
kubectl apply -f local_run/k8s-cronjob.yaml

# Verify CronJob
kubectl get cronjob -n security
kubectl describe cronjob vuln-list-updater -n security
```

### 4. Manual Trigger (Optional)

```bash
# Trigger a manual run
kubectl create job --from=cronjob/vuln-list-updater vuln-list-updater-manual-$(date +%s) -n security

# Watch logs
kubectl logs -f job/vuln-list-updater-manual-XXXXX -n security
```

## Schedule Configuration

Default: **Every 6 hours** (`0 */6 * * *`)

Modify the cron expression in `k8s-cronjob.yaml`:
- Every 4 hours: `0 */4 * * *`
- Daily at 2 AM: `0 2 * * *`
- Every Monday at 3 AM: `0 3 * * 1`

## Resource Requirements

| Repository | Disk Space | Memory | CPU |
|------------|-----------|---------|-----|
| vuln-list-nvd | 3.5 GB | 512 MB | 0.5 |
| vuln-list-debian | 1.4 GB | 512 MB | 0.5 |
| vuln-list-redhat | 22 GB | 2 GB | 1.0 |
| vuln-list (main) | 2 GB | 512 MB | 0.5 |
| **Total** | **~30 GB** | **2-4 GB** | **1-2 cores** |

The CronJob uses `emptyDir` with 30 GB limit.

## Monitoring

### Check CronJob Status

```bash
# List recent jobs
kubectl get jobs -n security -l app=vuln-list-updater

# View logs
kubectl logs -n security -l app=vuln-list-updater --tail=100

# Check for failures
kubectl get pods -n security -l app=vuln-list-updater --field-selector=status.phase=Failed
```

### Alerts

The script exits with non-zero status on failures. Configure alerts based on:
- Job failure status
- Execution time > 6 hours
- No successful completion in 24 hours

## Troubleshooting

### Common Issues

**1. GitLab Authentication Failed**
```bash
# Verify token has correct permissions
curl -H "Authorization: Bearer ${GITLAB_TOKEN}" \
  ${GITLAB_BASE_URL}/api/v4/user
```

**2. Disk Space Exceeded**
```bash
# Check emptyDir usage
kubectl exec -it <pod-name> -n security -- df -h /workspace
```

**3. NVD Rate Limiting**
```bash
# Verify NVD API key is set
kubectl exec -it <pod-name> -n security -- env | grep NVD
```

**4. Out of Memory**
- Increase memory limits in `k8s-cronjob.yaml`
- Red Hat updates require ~2 GB memory

### Debug Mode

```bash
# Run with debug output
kubectl exec -it <pod-name> -n security -- bash -x /app/update-all.sh
```

## Differences from GitHub Actions

| Aspect | GitHub Actions | K8s CronJob |
|--------|---------------|-------------|
| Scheduling | YAML cron | K8s CronJob |
| Disk Space | 14 GB | Configurable (30 GB) |
| Timeout | 6 hours | Configurable |
| Parallelism | Multiple jobs | Single job (simpler) |
| Cost | GitHub runners | Your K8s cluster |

## Security Considerations

1. **GitLab Token**: Store in Kubernetes Secret, rotate regularly
2. **NVD API Key**: Optional but recommended for better rate limits
3. **Network Policies**: Restrict egress to GitLab and NVD domains only
4. **RBAC**: Limit service account permissions

## Customization

### Update Specific Targets Only

Edit `update-all.sh` and comment out unwanted targets:

```bash
# MAIN_TARGETS=(
#     "alpine:Alpine Issue Tracker"  # Disable Alpine
#     "ubuntu:Ubuntu CVE Tracker"
#     ...
# )
```

### Add Custom Sources

1. Add target to `vuln-list-update/main.go`
2. Update `MAIN_TARGETS` array in `update-all.sh`
3. Rebuild Docker image

## License

This follows the same license as vuln-list-update (Apache 2.0).
