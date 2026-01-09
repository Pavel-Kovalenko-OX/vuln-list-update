#!/bin/bash
set -euo pipefail

# Local VM vuln-list updater
# This script updates vulnerability lists in local CACHE directories
# No Git operations - just refreshes the data for trivy-db builder
# 
# Optional environment variables:
#   CACHE_DIR        - Base cache directory (default: /var/cache/trivy-db)
#   NVD_API_KEY      - (Optional) NVD API key for better rate limits

CACHE_DIR="${CACHE_DIR:-/var/cache/trivy-db}"
APP_DIR="${APP_DIR:-/app}"

echo "=== Local Vulnerability List Updater ==="
echo "Cache directory: ${CACHE_DIR}"
echo "App directory: ${APP_DIR}"
echo ""

# Check if vuln-list-update binary exists
cd "${APP_DIR}"
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

# Function to run update on local directory
run_local_update() {
    local target=$1
    local description=$2
    local vuln_list_dir=$3
    local full_path="${CACHE_DIR}/${vuln_list_dir}"
    
    echo ""
    echo "[$(date +%T)] ========================================"
    echo "[$(date +%T)] Updating: ${description}"
    echo "[$(date +%T)] Target: ${target}"
    echo "[$(date +%T)] Directory: ${full_path}"
    echo "[$(date +%T)] ========================================"
    
    # Check if directory exists, create if not
    if [ ! -d "${full_path}" ]; then
        echo "[$(date +%T)] Creating directory: ${full_path}"
        mkdir -p "${full_path}"
    fi
    
    # Run the update
    cd "${APP_DIR}"
    result=0
    ./vuln-list-update -vuln-list-dir "${full_path}" -target "${target}" || result=$?
    
    if [ $result -ne 0 ]; then
        echo "[$(date +%T)] ✗ ERROR: Update failed for ${target}" >&2
        return 1
    fi
    
    echo "[$(date +%T)] ✓ Successfully updated ${target}"
    return 0
}

# Ensure cache directory exists
mkdir -p "${CACHE_DIR}"

# Track failures
declare -a FAILED_UPDATES=()
declare -a SUCCESSFUL_UPDATES=()

# Update vuln-list-nvd
echo "[$(date +%T)] Starting NVD updates..."
if run_local_update "nvd" "NVD" "vuln-list-nvd"; then
    SUCCESSFUL_UPDATES+=("nvd")
else
    FAILED_UPDATES+=("nvd")
fi

# Update vuln-list-debian
echo "[$(date +%T)] Starting Debian updates..."
if run_local_update "debian" "Debian Security Bug Tracker" "vuln-list-debian"; then
    SUCCESSFUL_UPDATES+=("debian")
else
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

REDHAT_DIR="${CACHE_DIR}/vuln-list-redhat"
mkdir -p "${REDHAT_DIR}"

redhat_success_count=0
redhat_total=3

for target_config in "redhat-oval:Red Hat OVAL v2" "redhat:Red Hat Security Data API" "redhat-csaf-vex:Red Hat CSAF VEX"; do
    IFS=':' read -r target msg <<< "$target_config"
    
    echo "[$(date +%T)] Starting: ${msg}..."
    
    if run_local_update "${target}" "${msg}" "vuln-list-redhat"; then
        SUCCESSFUL_UPDATES+=("${target}")
        ((redhat_success_count++))
    else
        FAILED_UPDATES+=("${target}")
    fi
done

if [ $redhat_success_count -eq $redhat_total ]; then
    echo "[$(date +%T)] ✓ All Red Hat sources updated successfully"
elif [ $redhat_success_count -gt 0 ]; then
    echo "[$(date +%T)] ⚠ Partial Red Hat update: ${redhat_success_count}/${redhat_total} sources succeeded"
else
    echo "[$(date +%T)] ✗ All Red Hat updates failed"
fi

# Update main vuln-list (all other sources)
echo ""
echo "[$(date +%T)] ========================================"
echo "[$(date +%T)] Updating: Main vuln-list repository"
echo "[$(date +%T)] ========================================"

MAIN_LIST_DIR="${CACHE_DIR}/vuln-list"
mkdir -p "${MAIN_LIST_DIR}"

# List of targets for main vuln-list
declare -A MAIN_TARGETS=(
    ["alpine"]="Alpine Issue Tracker"
    ["alpine-unfixed"]="Alpine Secfixes Tracker"
    ["ubuntu"]="Ubuntu CVE Tracker"
    ["amazon"]="Amazon Linux Security Center"
    ["oracle-oval"]="Oracle Linux OVAL"
    ["photon"]="Photon Security Advisories"
    ["suse-cvrf"]="SUSE CVRF"
    ["alma"]="AlmaLinux Security Advisory"
    ["rocky"]="Rocky Linux Security Advisory"
    ["azure"]="Azure Linux and CBL-Mariner Vulnerability Data"
    ["osvdev"]="OSV Database"
    ["wolfi"]="Wolfi Security Data"
    ["chainguard"]="Chainguard Security Data"
    ["openeuler"]="openEuler CVE Data"
    ["echo"]="Echo CVE Data"
    ["minimos"]="MinimOS Security Data"
    ["seal"]="Seal Security Data"
    ["eoldates"]="EOL dates"
    ["rootio"]="Root CVE Feed Tracker"
    ["cwe"]="CWE"
    ["glad"]="GitLab Advisory Database"
)

for target in "${!MAIN_TARGETS[@]}"; do
    description="${MAIN_TARGETS[$target]}"
    
    if run_local_update "${target}" "${description}" "vuln-list"; then
        SUCCESSFUL_UPDATES+=("${target}")
    else
        FAILED_UPDATES+=("${target}")
    fi
done

# Summary
echo ""
echo "=========================================="
echo "Update Summary"
echo "=========================================="
echo "Completed at: $(date)"
echo ""
echo "Total targets: $((${#SUCCESSFUL_UPDATES[@]} + ${#FAILED_UPDATES[@]}))"
echo "✓ Successful: ${#SUCCESSFUL_UPDATES[@]}"
echo "✗ Failed: ${#FAILED_UPDATES[@]}"

if [ ${#SUCCESSFUL_UPDATES[@]} -gt 0 ]; then
    echo ""
    echo "Successful updates:"
    for target in "${SUCCESSFUL_UPDATES[@]}"; do
        echo "  ✓ ${target}"
    done
fi

if [ ${#FAILED_UPDATES[@]} -gt 0 ]; then
    echo ""
    echo "Failed updates:"
    for target in "${FAILED_UPDATES[@]}"; do
        echo "  ✗ ${target}"
    done
    echo ""
    echo "Cache location: ${CACHE_DIR}"
    exit 1
else
    echo ""
    echo "All updates completed successfully!"
    echo "Cache location: ${CACHE_DIR}"
    exit 0
fi
