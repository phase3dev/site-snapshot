#!/bin/bash
#
# mirror.sh - Fast website cloning with rotating proxies and user agents
#
# Usage:
#   ./mirror.sh [OPTIONS]
#
# Options:
#   -u, --url URL           Target URL to mirror (required)
#   -d, --domains DOMAINS   Comma-separated list of domains to follow (default: extracted from URL)
#   -o, --output DIR        Output directory (default: ./mirror_output/<domain>)
#   -r, --retries N         Max retries per URL on failure (default: 5)
#   -c, --concurrency N     Max concurrent wget processes (default: random 2-8)
#   -w, --wait N [MAX]      Delay in seconds: one value = fixed, two = random range (default: 1 3)
#   --depth N               Recursion depth (default: unlimited, 0 = unlimited)
#   --no-assets             Skip downloading page assets (images, CSS, JS)
#   --reject TYPES          Comma-separated file extensions to reject (e.g., mp4,pdf,zip)
#   --accept TYPES          Comma-separated file extensions to accept (download only these)
#   --no-zip                Skip creating zip archive after download
#   --robots-on             Respect robots.txt (default: robots.txt is NOT respected - see README)
#   --proxies FILE          Path to proxy list file (default: proxies.txt in script directory)
#   --user-agents FILE      Path to user agent list file (default: user_agents.txt in script directory)
#   -h, --help              Show this help message
#
# Both proxies.txt and user_agents.txt are optional. Without proxies, requests
# go out on your own IP. Without user agents, a default Chrome UA is used.
#
# Example:
#   ./mirror.sh -u https://example.com -d example.com,cdn.example.com -o ./example_mirror

set -euo pipefail

# ──────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────
BASE_URL=""
DOMAINS=""
SAVE_DIR=""
MAX_RETRIES=5
MAX_CONCURRENCY=0  # 0 = random
WAIT_MIN=1
WAIT_MAX=3
DEPTH=""
NO_ASSETS=false
REJECT_TYPES=""
ACCEPT_TYPES=""
NO_ZIP=false
ROBOTS_OFF=true
PROXY_FILE=""
UA_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────
show_help() {
    sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \?//'
    sed -n '/^# Options:/,/^[^#]/p' "$0" | head -n -1 | sed 's/^# \?//'
    sed -n '/^# Example:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)       BASE_URL="$2"; shift 2 ;;
        -d|--domains)   DOMAINS="$2"; shift 2 ;;
        -o|--output)    SAVE_DIR="$2"; shift 2 ;;
        -r|--retries)   MAX_RETRIES="$2"; shift 2 ;;
        -c|--concurrency) MAX_CONCURRENCY="$2"; shift 2 ;;
        -w|--wait)
            WAIT_MIN="$2"
            # If next arg looks like a number, treat it as MAX; otherwise MIN=MAX
            if [[ -n "${3:-}" && "$3" =~ ^[0-9]+$ ]]; then
                WAIT_MAX="$3"; shift 3
            else
                WAIT_MAX="$2"; shift 2
            fi
            ;;
        --depth)        DEPTH="$2"; shift 2 ;;
        --no-assets)    NO_ASSETS=true; shift ;;
        --reject)       REJECT_TYPES="$2"; shift 2 ;;
        --accept)       ACCEPT_TYPES="$2"; shift 2 ;;
        --no-zip)       NO_ZIP=true; shift ;;
        --robots-on)    ROBOTS_OFF=false; shift ;;
        --proxies)      PROXY_FILE="$2"; shift 2 ;;
        --user-agents)  UA_FILE="$2"; shift 2 ;;
        -h|--help)      show_help ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
done

if [[ -z "$BASE_URL" ]]; then
    echo "Error: --url is required."
    echo "Run with --help for usage."
    exit 1
fi

# ──────────────────────────────────────────────
# Derive defaults from URL
# ──────────────────────────────────────────────
DOMAIN=$(echo "$BASE_URL" | sed -E 's|https?://([^/]+).*|\1|')

if [[ -z "$DOMAINS" ]]; then
    DOMAINS="$DOMAIN"
fi

if [[ -z "$SAVE_DIR" ]]; then
    SAVE_DIR="./mirror_output/${DOMAIN}"
fi

LOG_FILE="${SAVE_DIR}/mirror.log"

# ──────────────────────────────────────────────
# Load proxies and user agents
# ──────────────────────────────────────────────
# Use --proxies path if given, otherwise look for proxies.txt next to script
if [[ -z "$PROXY_FILE" ]]; then
    PROXY_FILE="${SCRIPT_DIR}/proxies.txt"
fi

if [[ -f "$PROXY_FILE" ]]; then
    mapfile -t PROXIES < "$PROXY_FILE"
    echo "Loaded ${#PROXIES[@]} proxies from ${PROXY_FILE}."
else
    echo "Warning: ${PROXY_FILE} not found. Running without proxies (your own IP will be used)."
    PROXIES=()
fi

# Use --user-agents path if given, otherwise look for user_agents.txt next to script
if [[ -z "$UA_FILE" ]]; then
    UA_FILE="${SCRIPT_DIR}/user_agents.txt"
fi

if [[ -f "$UA_FILE" ]]; then
    mapfile -t USER_AGENTS < "$UA_FILE"
    echo "Loaded ${#USER_AGENTS[@]} user agents from ${UA_FILE}."
else
    echo "Warning: ${UA_FILE} not found. Using default Chrome user agent."
    USER_AGENTS=("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
fi

# ──────────────────────────────────────────────
# Utility functions
# ──────────────────────────────────────────────
get_random_item() {
    local array=("$@")
    echo "${array[RANDOM % ${#array[@]}]}"
}

random_delay() {
    local range=$((WAIT_MAX - WAIT_MIN + 1))
    local delay=$(( (RANDOM % range) + WAIT_MIN ))
    echo "Delaying for ${delay}s..."
    sleep "$delay"
}

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# ──────────────────────────────────────────────
# Core wget function with retry logic
# ──────────────────────────────────────────────
wget_mirror() {
    local url="$1"
    local attempt=0

    while (( attempt < MAX_RETRIES )); do
        # Select proxy and user agent
        local proxy_args=()
        if [[ ${#PROXIES[@]} -gt 0 ]]; then
            local proxy=$(get_random_item "${PROXIES[@]}")
            proxy_args=(-e "use_proxy=yes" -e "https_proxy=${proxy}" -e "http_proxy=${proxy}")
            log_message "Attempt $((attempt + 1)): Proxy: $proxy"
        fi

        local user_agent=$(get_random_item "${USER_AGENTS[@]}")
        log_message "User-Agent: $user_agent"
        log_message "Fetching: $url"

        # Build wget options
        local wget_opts=(
            --recursive
            --no-clobber
            --html-extension
            --restrict-file-names=windows
            --domains "$DOMAINS"
            --no-parent
            --user-agent="$user_agent"
            --tries=2
            --timeout=60
            --wait=$(( (RANDOM % (WAIT_MAX - WAIT_MIN + 1)) + WAIT_MIN ))
            --no-http-keep-alive
            --directory-prefix="$SAVE_DIR"
        )

        # Page requisites (assets)
        if [[ "$NO_ASSETS" == false ]]; then
            wget_opts+=(--page-requisites)
        fi

        # Recursion depth
        if [[ -n "$DEPTH" && "$DEPTH" != "0" ]]; then
            wget_opts+=(--level="$DEPTH")
        fi

        # Accept/reject filters
        if [[ -n "$REJECT_TYPES" ]]; then
            wget_opts+=(--reject "$REJECT_TYPES")
        fi
        if [[ -n "$ACCEPT_TYPES" ]]; then
            wget_opts+=(--accept "$ACCEPT_TYPES")
        fi

        # robots.txt
        if [[ "$ROBOTS_OFF" == true ]]; then
            wget_opts+=(--execute "robots=off")
        fi

        wget "${wget_opts[@]}" "${proxy_args[@]}" "$url"
        result=$?

        if [[ $result -eq 0 ]]; then
            log_message "Download successful."
            return 0
        elif [[ $result -eq 8 ]]; then
            log_message "HTTP 403/429 detected. Rotating proxy and user agent..."
            random_delay
        else
            log_message "wget exited with code $result. Retrying..."
            random_delay
        fi

        attempt=$((attempt + 1))
    done

    log_message "Max retries (${MAX_RETRIES}) reached for: $url"
    return 1
}

# ──────────────────────────────────────────────
# Main execution
# ──────────────────────────────────────────────
mkdir -p "$SAVE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log_message "=== Mirror session started ==="
log_message "Target: $BASE_URL"
log_message "Domains: $DOMAINS"
log_message "Output: $SAVE_DIR"

# URL list - add additional paths below the base URL if needed
URLS=(
    "$BASE_URL"
    # "$BASE_URL/some/subpage"
)

# Concurrency
if [[ "$MAX_CONCURRENCY" -eq 0 ]]; then
    MAX_CONCURRENCY=$(( (RANDOM % 7) + 2 ))  # 2–8
fi
log_message "Concurrency: $MAX_CONCURRENCY"

running=0
for url in "${URLS[@]}"; do
    wget_mirror "$url" &
    running=$((running + 1))
    if (( running >= MAX_CONCURRENCY )); then
        wait -n 2>/dev/null || true
        running=$((running - 1))
    fi
    random_delay
done
wait

log_message "All downloads completed."

# ──────────────────────────────────────────────
# Optional: zip output
# ──────────────────────────────────────────────
if [[ "$NO_ZIP" == false ]]; then
    sanitized=$(echo "$DOMAIN" | sed 's/[\/:]/_/g')
    zip_path="${SAVE_DIR%/}/../${sanitized}.zip"
    zip -r "$zip_path" "$SAVE_DIR" && log_message "Archive created: $zip_path"
fi

log_message "=== Mirror session finished ==="
