#!/bin/bash
set -euo pipefail

# Local VM vuln-list updater
# This script updates vulnerability lists in local CACHE directories
# No Git operations - just refreshes the data for trivy-db builder
# 
# Optional environment variables:
#   CACHE_DIR        - Base cache directory (default: /var/cache/trivy-db)
#   NVD_API_KEY      - (Optional) NVD API key for better rate limits
#   TARGETS          - Comma-separated list of targets to update (default: all)
#                      Available: nvd, debian, redhat, main, or specific targets
#                      Examples: TARGETS=nvd,debian,ubuntu
#                                TARGETS=quick (nvd,debian,main without slow redhat)
#                                TARGETS=all (default - everything)

CACHE_DIR="${CACHE_DIR:-/var/cache/trivy-db}"
APP_DIR="${APP_DIR:-/app}"
LOCK_FILE="${CACHE_DIR}/.update-lock"
UPDATE_INTERRUPTED=false

# Show usage information
show_usage() {
    cat <<'EOF'
Usage: update-local.sh [OPTIONS]

Local VM vulnerability list updater - updates vuln-list data without Git operations.

Environment Variables:
  CACHE_DIR       Base cache directory (default: /var/cache/trivy-db)
  APP_DIR         Application directory (default: /app)
  NVD_API_KEY     Optional NVD API key for better rate limits
  TARGETS         Comma-separated list of targets to update (default: all)

Target Selection:
  all             Update everything (default)
  quick           Skip slow Red Hat targets, update everything else
  nvd             Only NVD database
  debian          Only Debian security tracker
  redhat          All Red Hat sources (oval, api, csaf-vex)
  main            All main vuln-list targets (except nvd, debian, redhat)
  
  Individual targets:
    Red Hat:      redhat-oval, redhat, redhat-csaf-vex
    Main:         alpine, alpine-unfixed, ubuntu, amazon, oracle-oval,
                  photon, suse-cvrf, alma, rocky, azure, osvdev,
                  wolfi, chainguard, openeuler, echo, minimos,
                  seal, eoldates, rootio, cwe, glad

Examples:
  # Update everything (may take hours due to Red Hat)
  ./update-local.sh

  # Quick update - skip slow Red Hat OVAL and API
  TARGETS=quick ./update-local.sh

  # Update only NVD and Debian
  TARGETS=nvd,debian ./update-local.sh

  # Update specific distributions
  TARGETS=ubuntu,debian,alpine ./update-local.sh

  # Update only fast Red Hat source
  TARGETS=redhat-csaf-vex ./update-local.sh

  # Custom cache location
  CACHE_DIR=/mnt/data/trivy-cache TARGETS=quick ./update-local.sh

Notes:
  - Red Hat OVAL and API targets do FULL downloads (1996-present), taking hours
  - Use Ctrl+C to interrupt - cleanup will be performed automatically
  - Lock file prevents multiple simultaneous updates
  - Updates are performed in-place without Git commits

EOF
}

# Check for help flag
if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
    show_usage
    exit 0
fi

# Cleanup function
cleanup() {
    local exit_code=$?
    
    echo ""
    if [ "$UPDATE_INTERRUPTED" = true ]; then
        echo "[$(date +%T)] ⚠ Update interrupted by user"
    fi
    
    # Remove lock file
    if [ -f "${LOCK_FILE}" ]; then
        rm -f "${LOCK_FILE}"
        echo "[$(date +%T)] Lock file removed"
    fi
    
    if [ $exit_code -ne 0 ] && [ "$UPDATE_INTERRUPTED" != true ]; then
        echo "[$(date +%T)] Exiting with errors (code: $exit_code)"
    fi
}

# Set trap to ensure cleanup on exit (EXIT catches all exit scenarios)
trap cleanup EXIT
trap 'UPDATE_INTERRUPTED=true; exit 130' INT
trap 'UPDATE_INTERRUPTED=true; exit 143' TERM

echo "=== Local Vulnerability List Updater ==="
echo "Cache directory: ${CACHE_DIR}"
echo "App directory: ${APP_DIR}"
echo ""

# Check if another instance is running
if [ -f "${LOCK_FILE}" ]; then
    echo "[$(date +%T)] ✗ ERROR: Another instance is already running (lock file exists: ${LOCK_FILE})" >&2
    echo "  If no other instance is running, remove the lock file manually: rm ${LOCK_FILE}" >&2
    exit 1
fi

# Create lock file
mkdir -p "${CACHE_DIR}"
echo "$$" > "${LOCK_FILE}"
echo "[$(date +%T)] Lock acquired (PID: $$)"
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

# Parse target selection
TARGETS="${TARGETS:-all}"
echo "[$(date +%T)] Target selection: ${TARGETS}"
echo ""

# Define target groups
declare -a SELECTED_TARGETS=()

parse_targets() {
    IFS=',' read -ra TARGET_LIST <<< "$TARGETS"
    
    for target in "${TARGET_LIST[@]}"; do
        target=$(echo "$target" | xargs) # trim whitespace
        
        case "$target" in
            all)
                SELECTED_TARGETS+=("nvd" "debian" "redhat-oval" "redhat" "redhat-csaf-vex")
                SELECTED_TARGETS+=("alpine" "alpine-unfixed" "ubuntu" "amazon" "oracle-oval" 
                                   "photon" "suse-cvrf" "alma" "rocky" "azure" "osvdev" 
                                   "wolfi" "chainguard" "openeuler" "echo" "minimos" 
                                   "seal" "eoldates" "rootio" "cwe" "glad")
                ;;
            quick)
                # Skip slow redhat targets
                SELECTED_TARGETS+=("nvd" "debian")
                SELECTED_TARGETS+=("alpine" "alpine-unfixed" "ubuntu" "amazon" "oracle-oval" 
                                   "photon" "suse-cvrf" "alma" "rocky" "azure" "osvdev" 
                                   "wolfi" "chainguard" "openeuler" "echo" "minimos" 
                                   "seal" "eoldates" "rootio" "cwe" "glad")
                ;;
            nvd)
                SELECTED_TARGETS+=("nvd")
                ;;
            debian)
                SELECTED_TARGETS+=("debian")
                ;;
            redhat)
                SELECTED_TARGETS+=("redhat-oval" "redhat" "redhat-csaf-vex")
                ;;
            redhat-oval|redhat-csaf-vex)
                SELECTED_TARGETS+=("$target")
                ;;
            main)
                SELECTED_TARGETS+=("alpine" "alpine-unfixed" "ubuntu" "amazon" "oracle-oval" 
                                   "photon" "suse-cvrf" "alma" "rocky" "azure" "osvdev" 
                                   "wolfi" "chainguard" "openeuler" "echo" "minimos" 
                                   "seal" "eoldates" "rootio" "cwe" "glad")
                ;;
            # Individual main targets
            alpine|alpine-unfixed|ubuntu|amazon|oracle-oval|photon|suse-cvrf|alma|rocky|azure|osvdev|wolfi|chainguard|openeuler|echo|minimos|seal|eoldates|rootio|cwe|glad)
                SELECTED_TARGETS+=("$target")
                ;;
            *)
                echo "[$(date +%T)] ✗ WARNING: Unknown target '$target' - skipping" >&2
                ;;
        esac
    done
    
    # Remove duplicates while preserving order
    declare -A seen
    declare -a unique_targets
    for target in "${SELECTED_TARGETS[@]}"; do
        if [[ ! ${seen[$target]+_} ]]; then
            unique_targets+=("$target")
            seen[$target]=1
        fi
    done
    SELECTED_TARGETS=("${unique_targets[@]}")
}

parse_targets

if [ ${#SELECTED_TARGETS[@]} -eq 0 ]; then
    echo "[$(date +%T)] ✗ ERROR: No valid targets specified" >&2
    cleanup
fi

echo "[$(date +%T)] Will update ${#SELECTED_TARGETS[@]} target(s):"
for target in "${SELECTED_TARGETS[@]}"; do
    echo "  - $target"
done
echo ""

# Track failures
declare -a FAILED_UPDATES=()
declare -a SUCCESSFUL_UPDATES=()

# Helper function to check if target should be updated
should_update() {
    local target=$1
    for selected in "${SELECTED_TARGETS[@]}"; do
        if [ "$selected" = "$target" ]; then
            return 0
        fi
    done
    return 1
}

# Update vuln-list-nvd
if should_update "nvd"; then
    echo "[$(date +%T)] Starting NVD updates..."
    if run_local_update "nvd" "NVD" "vuln-list-nvd"; then
        SUCCESSFUL_UPDATES+=("nvd")
    else
        FAILED_UPDATES+=("nvd")
    fi
fi

# Update vuln-list-debian
if should_update "debian"; then
    echo "[$(date +%T)] Starting Debian updates..."
    if run_local_update "debian" "Debian Security Bug Tracker" "vuln-list-debian"; then
        SUCCESSFUL_UPDATES+=("debian")
    else
        FAILED_UPDATES+=("debian")
    fi
fi

# Update vuln-list-redhat (multiple sources)
# NOTE: Red Hat has 3 different data sources that write to separate subdirectories:
#   - redhat-oval     → oval/ directory (full refresh each time, no incremental)
#   - redhat          → api/ directory (full refresh each time, no incremental)  
#   - redhat-csaf-vex → csaf-vex/ directory (incremental updates using last_updated.json)
# WARNING: redhat-oval and redhat do FULL downloads (1996-present), which can take hours!

redhat_targets=("redhat-oval" "redhat" "redhat-csaf-vex")
redhat_to_update=()

for target in "${redhat_targets[@]}"; do
    if should_update "$target"; then
        redhat_to_update+=("$target")
    fi
done

if [ ${#redhat_to_update[@]} -gt 0 ]; then
    echo ""
    echo "[$(date +%T)] ========================================"
    echo "[$(date +%T)] Updating: Red Hat (${#redhat_to_update[@]} source(s))"
    echo "[$(date +%T)] ========================================"
    
    REDHAT_DIR="${CACHE_DIR}/vuln-list-redhat"
    mkdir -p "${REDHAT_DIR}"
    
    redhat_success_count=0
    
    for target in "${redhat_to_update[@]}"; do
        case "$target" in
            "redhat-oval")
                msg="Red Hat OVAL v2"
                ;;
            "redhat")
                msg="Red Hat Security Data API"
                ;;
            "redhat-csaf-vex")
                msg="Red Hat CSAF VEX"
                ;;
        esac
        
        echo "[$(date +%T)] Starting: ${msg}..."
        
        if run_local_update "${target}" "${msg}" "vuln-list-redhat"; then
            SUCCESSFUL_UPDATES+=("${target}")
            ((redhat_success_count++))
        else
            FAILED_UPDATES+=("${target}")
        fi
    done
    
    if [ $redhat_success_count -eq ${#redhat_to_update[@]} ]; then
        echo "[$(date +%T)] ✓ All selected Red Hat sources updated successfully"
    elif [ $redhat_success_count -gt 0 ]; then
        echo "[$(date +%T)] ⚠ Partial Red Hat update: ${redhat_success_count}/${#redhat_to_update[@]} sources succeeded"
    else
        echo "[$(date +%T)] ✗ All Red Hat updates failed"
    fi
fi

# Update main vuln-list (all other sources)
main_targets=("alpine" "alpine-unfixed" "ubuntu" "amazon" "oracle-oval" "photon" "suse-cvrf" 
              "alma" "rocky" "azure" "osvdev" "wolfi" "chainguard" "openeuler" "echo" 
              "minimos" "seal" "eoldates" "rootio" "cwe" "glad")

main_to_update=()
for target in "${main_targets[@]}"; do
    if should_update "$target"; then
        main_to_update+=("$target")
    fi
done

if [ ${#main_to_update[@]} -gt 0 ]; then
    echo ""
    echo "[$(date +%T)] ========================================"
    echo "[$(date +%T)] Updating: Main vuln-list repository"
    echo "[$(date +%T)] Selected: ${#main_to_update[@]} target(s)"
    echo "[$(date +%T)] ========================================"
    
    MAIN_LIST_DIR="${CACHE_DIR}/vuln-list"
    mkdir -p "${MAIN_LIST_DIR}"
    
    # Target descriptions
    declare -A MAIN_TARGET_DESCRIPTIONS=(
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
    
    for target in "${main_to_update[@]}"; do
        description="${MAIN_TARGET_DESCRIPTIONS[$target]}"
        
        if run_local_update "${target}" "${description}" "vuln-list"; then
            SUCCESSFUL_UPDATES+=("${target}")
        else
            FAILED_UPDATES+=("${target}")
        fi
    done
fi

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
