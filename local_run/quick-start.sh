#!/bin/bash
# Quick start script for local testing

set -e

echo "=== Self-Hosted Trivy Infrastructure - Quick Start ==="
echo ""

# Check if running in correct directory
if [ ! -f "go.mod" ]; then
    echo "ERROR: Run this script from vuln-list-update directory"
    exit 1
fi

# Check prerequisites
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker is required"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "WARNING: kubectl not found (only needed for K8s deployment)"; }

# Get user input
read -p "GitLab Base URL (e.g., https://gitlab.example.com): " GITLAB_URL
read -p "GitLab Group/Namespace (e.g., security/vulnerability-data): " GITLAB_GROUP
read -sp "GitLab Token: " GITLAB_TOKEN
echo ""
read -sp "NVD API Key (optional, press Enter to skip): " NVD_KEY
echo ""

# Export variables
export GITLAB_TOKEN="${GITLAB_TOKEN}"
export GITLAB_BASE_URL="${GITLAB_URL}"
export GITLAB_GROUP="${GITLAB_GROUP}"
export NVD_API_KEY="${NVD_KEY}"

echo ""
echo "Building Docker images..."

# Build vuln-list-updater
docker build -f local_run/Dockerfile -t vuln-list-updater:local .
echo "✓ vuln-list-updater image built"

# Build trivy-db (if exists)
if [ -d "../trivy-db" ]; then
    cd ../trivy-db
    docker build -f local_run/Dockerfile -t trivy-db-builder:local .
    echo "✓ trivy-db-builder image built"
    cd ../vuln-list-update
fi

echo ""
echo "=== Ready to run! ==="
echo ""
echo "To test vuln-list-updater:"
echo "  docker run --rm -e GITLAB_TOKEN=\"\${GITLAB_TOKEN}\" \\"
echo "    -e GITLAB_BASE_URL=\"\${GITLAB_BASE_URL}\" \\"
echo "    -e GITLAB_GROUP=\"\${GITLAB_GROUP}\" \\"
echo "    -e NVD_API_KEY=\"\${NVD_API_KEY}\" \\"
echo "    vuln-list-updater:local"
echo ""
echo "To test trivy-db-builder:"
echo "  docker run --rm -e GITLAB_TOKEN=\"\${GITLAB_TOKEN}\" \\"
echo "    -e GITLAB_BASE_URL=\"\${GITLAB_BASE_URL}\" \\"
echo "    -e GITLAB_GROUP=\"\${GITLAB_GROUP}\" \\"
echo "    -v \$(pwd)/output:/output \\"
echo "    trivy-db-builder:local"
echo ""
echo "For Kubernetes deployment, see:"
echo "  - vuln-list-update/local_run/README.md"
echo "  - trivy-db/local_run/README.md"
