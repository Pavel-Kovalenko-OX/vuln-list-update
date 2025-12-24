#!/bin/bash
set -euo pipefail

# Self-hosted vuln-list updater
# This script replaces GitHub Actions workflows for updating vuln-list repositories
# 
# Required environment variables:
#   GITLAB_TOKEN     - GitLab personal access token with repo access
#   GITLAB_BASE_URL  - GitLab base URL (e.g., https://gitlab.example.com)
#   GITLAB_GROUP     - GitLab group/namespace (e.g., security/vulnerability-data)
#   NVD_API_KEY      - (Optional) NVD API key for better rate limits

WORK_DIR="${WORK_DIR:-/workspace}"
GITLAB_TOKEN="${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
GITLAB_BASE_URL="${GITLAB_BASE_URL:?GITLAB_BASE_URL is required}"
GITLAB_GROUP="${GITLAB_GROUP:?GITLAB_GROUP is required}"

# Git configuration
git config --global user.email "vuln-updater@example.com"
git config --global user.name "Vulnerability Updater"
git config --global credential.helper store

echo "=== Vulnerability List Updater ==="
echo "Work directory: ${WORK_DIR}"
echo "GitLab URL: ${GITLAB_BASE_URL}"
echo "GitLab Group: ${GITLAB_GROUP}"
echo ""

# Check if vuln-list-update binary exists (Docker multi-stage build scenario)
cd /app
if [ -f "./vuln-list-update" ] && [ -x "./vuln-list-update" ]; then
    echo "[$(date +%T)] Using existing vuln-list-update binary"
else
    echo "[$(date +%T)] Binary not found, attempting to build..."
    if command -v go >/dev/null 2>&1; then
        echo "[$(date +%T)] Building vuln-list-update..."
        go build -o vuln-list-update .
        chmod +x vuln-list-update
        echo "[$(date +%T)] ✓ Build completed"
    else
        echo "[$(date +%T)] ✗ ERROR: vuln-list-update binary not found and Go compiler not available" >&2
        echo "  Either run this script in the Docker container or install Go locally" >&2
        exit 1
    fi
fi

# Function to clone or pull a GitLab repository
clone_or_pull_repo() {
    local repo_name=$1
    local repo_dir="${WORK_DIR}/${repo_name}"
    local git_url="${GITLAB_BASE_URL}/${GITLAB_GROUP}/${repo_name}.git"
    # Use token in URL for authentication
    local auth_url="${git_url/\/\//\/\/oauth2:${GITLAB_TOKEN}@}"
    
    echo "[$(date +%T)] Processing ${repo_name}..."
    
    if [ -d "${repo_dir}/.git" ]; then
        echo "  Repository exists, pulling latest changes..."
        cd "${repo_dir}"
        git pull origin main || git pull origin master || true
    else
        echo "  Cloning repository..."
        git clone "${auth_url}" "${repo_dir}"
        cd "${repo_dir}"
    fi
}

# Function to run update and commit changes
run_update() {
    local target=$1
    local commit_msg=$2
    local vuln_list_dir=$3
    
    echo ""
    echo "[$(date +%T)] ========================================"
    echo "[$(date +%T)] Updating: ${target}"
    echo "[$(date +%T)] Target repo: ${vuln_list_dir}"
    echo "[$(date +%T)] ========================================"
    
    # Clone/pull the target repository
    clone_or_pull_repo "${vuln_list_dir}"
    
    # Run the update
    cd /app
    result=0
    ./vuln-list-update -vuln-list-dir "${WORK_DIR}/${vuln_list_dir}" -target "${target}" || result=$?
    
    if [ $result -ne 0 ]; then
        echo "[$(date +%T)] ERROR: Update failed for ${target}" >&2
        cd "${WORK_DIR}/${vuln_list_dir}"
        git reset --hard HEAD
        return 1
    fi
    
    # Check for changes and commit
    cd "${WORK_DIR}/${vuln_list_dir}"
    if [[ -n $(git status --porcelain) ]]; then
        echo "[$(date +%T)] Changes detected, committing..."
        git add .
        git commit -m "${commit_msg}"
        
        # Push with authentication
        local git_url=$(git config --get remote.origin.url)
        local auth_url="${git_url/\/\//\/\/oauth2:${GITLAB_TOKEN}@}"
        git remote set-url origin "${auth_url}"
        git push origin HEAD:main || git push origin HEAD:master
        
        echo "[$(date +%T)] ✓ Successfully updated ${target}"
    else
        echo "[$(date +%T)] No changes detected for ${target}"
    fi
}

# Create workspace
mkdir -p "${WORK_DIR}"

# Track failures
declare -a FAILED_UPDATES=()

# Update vuln-list-nvd
if ! run_update "nvd" "NVD" "vuln-list-nvd"; then
    FAILED_UPDATES+=("nvd")
fi

# Update vuln-list-debian  
if ! run_update "debian" "Debian Security Bug Tracker" "vuln-list-debian"; then
    FAILED_UPDATES+=("debian")
fi

# Update vuln-list-redhat (multiple sources)
# NOTE: Red Hat has 3 different data sources that write to separate subdirectories:
#   - redhat-oval     → oval/ directory (full refresh each time, no incremental)
#   - redhat          → api/ directory (full refresh each time, no incremental)  
#   - redhat-csaf-vex → csaf-vex/ directory (incremental updates using last_updated.json)
# WARNING: redhat-oval and redhat do FULL downloads (1996-present), which can take hours!
echo ""
echo "[$(date +%T)] ========================================"
echo "[$(date +%T)] Updating: Red Hat (3 sources)"
echo "[$(date +%T)] ========================================"

clone_or_pull_repo "vuln-list-redhat"

# Track Red Hat-specific failures
redhat_failed=0

for target_config in "redhat-oval:Red Hat OVAL v2" "redhat:Red Hat Security Data API" "redhat-csaf-vex:Red Hat CSAF VEX"; do
    IFS=':' read -r target msg <<< "$target_config"
    
    echo "[$(date +%T)] Starting: ${msg}..."
    
    cd /app
    result=0
    ./vuln-list-update -vuln-list-dir "${WORK_DIR}/vuln-list-redhat" -target "${target}" || result=$?
    
    if [ $result -ne 0 ]; then
        echo "[$(date +%T)] ✗ ERROR: Update failed for ${target}" >&2
        FAILED_UPDATES+=("${target}")
        redhat_failed=1
        
        # On failure, revert changes for this specific source subdirectory
        cd "${WORK_DIR}/vuln-list-redhat"
        case "${target}" in
            "redhat-oval")
                git checkout HEAD -- oval/ 2>/dev/null || true
                ;;
            "redhat")
                git checkout HEAD -- api/ 2>/dev/null || true
                ;;
            "redhat-csaf-vex")
                git checkout HEAD -- csaf-vex/ 2>/dev/null || true
                ;;
        esac
    else
        echo "[$(date +%T)] ✓ Completed: ${msg}"
    fi
done

# Commit all Red Hat changes together (even if some failed)
cd "${WORK_DIR}/vuln-list-redhat"
if [[ -n $(git status --porcelain) ]]; then
    echo "[$(date +%T)] Committing Red Hat updates..."
    git add .
    
    # Create detailed commit message
    if [ $redhat_failed -eq 0 ]; then
        git commit -m "Red Hat Security Updates (all sources)"
    else
        git commit -m "Red Hat Security Updates (partial - some sources failed)"
    fi
    
    local git_url=$(git config --get remote.origin.url)
    local auth_url="${git_url/\/\//\/\/oauth2:${GITLAB_TOKEN}@}"
    git remote set-url origin "${auth_url}"
    git push origin HEAD:main || git push origin HEAD:master
    
    if [ $redhat_failed -eq 0 ]; then
        echo "[$(date +%T)] ✓ Successfully updated all Red Hat sources"
    else
        echo "[$(date +%T)] ⚠ Committed partial Red Hat updates (some sources failed)"
    fi
else
    echo "[$(date +%T)] No changes detected for Red Hat sources"
fi

# Update main vuln-list (all other sources)
echo ""
echo "[$(date +%T)] ========================================"
echo "[$(date +%T)] Updating: Main vuln-list repository"
echo "[$(date +%T)] ========================================"

clone_or_pull_repo "vuln-list"

# List of targets for main vuln-list
MAIN_TARGETS=(
    "alpine:Alpine Issue Tracker"
    "alpine-unfixed:Alpine Secfixes Tracker"
    "ubuntu:Ubuntu CVE Tracker"
    "amazon:Amazon Linux Security Center"
    "oracle-oval:Oracle Linux OVAL"
    "photon:Photon Security Advisories"
    "suse-cvrf:SUSE CVRF"
    "alma:AlmaLinux Security Advisory"
    "rocky:Rocky Linux Security Advisory"
    "azure:Azure Linux and CBL-Mariner Vulnerability Data"
    "osvdev:OSV Database"
    "wolfi:Wolfi Security Data"
    "chainguard:Chainguard Security Data"
    "openeuler:openEuler CVE Data"
    "echo:Echo CVE Data"
    "minimos:MinimOS Security Data"
    "seal:Seal Security Data"
    "eoldates:EOL dates"
    "rootio:Root CVE Feed Tracker"
    "cwe:CWE"
    "glad:GitLab Advisory Database"
)

for target_config in "${MAIN_TARGETS[@]}"; do
    IFS=':' read -r target msg <<< "$target_config"
    
    cd /app
    result=0
    ./vuln-list-update -vuln-list-dir "${WORK_DIR}/vuln-list" -target "${target}" || result=$?
    
    if [ $result -ne 0 ]; then
        echo "[$(date +%T)] ERROR: Update failed for ${target}" >&2
        FAILED_UPDATES+=("${target}")
    fi
done

# Commit all main vuln-list changes together
cd "${WORK_DIR}/vuln-list"
if [[ -n $(git status --porcelain) ]]; then
    echo "[$(date +%T)] Committing main vuln-list updates..."
    git add .
    git commit -m "Vulnerability Database Updates"
    
    local git_url=$(git config --get remote.origin.url)
    local auth_url="${git_url/\/\//\/\/oauth2:${GITLAB_TOKEN}@}"
    git remote set-url origin "${auth_url}"
    git push origin HEAD:main || git push origin HEAD:master
    
    echo "[$(date +%T)] ✓ Successfully updated main vuln-list"
fi

# Summary
echo ""
echo "=========================================="
echo "Update Summary"
echo "=========================================="
echo "Completed at: $(date)"

if [ ${#FAILED_UPDATES[@]} -eq 0 ]; then
    echo "✓ All updates completed successfully"
    exit 0
else
    echo "✗ Failed updates: ${FAILED_UPDATES[*]}"
    exit 1
fi
