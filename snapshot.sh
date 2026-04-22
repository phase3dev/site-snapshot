#!/usr/bin/env bash
#
# snapshot.sh - Static website snapshots with wget, rotating proxies/user agents,
#               and fallback link discovery from downloaded HTML.
#
# Usage:
#   ./snapshot.sh [OPTIONS]
#
# Options:
#   -u, --url URL              Target URL to mirror (required)
#   -d, --domains DOMAINS      Comma-separated domains to follow
#                              Default: extracted from URL
#                              Accepts bare domains or full URLs; paths/schemes are stripped
#   -o, --output DIR           Output directory (default: ./snapshot_output/<domain>)
#   -r, --retries N            Max retries per URL on failure (default: 5)
#   -c, --concurrency N        Max concurrent wget jobs (default: random 2-8)
#   -w, --wait N [MAX]         Delay in seconds: one value = fixed, two = random range
#                              Default: 1 3
#   --depth N                  Recursion depth for wget (0 = unlimited, default: unlimited)
#   --no-assets                Skip downloading page assets (images, CSS, JS, fonts)
#   --reject TYPES             Comma-separated file extensions to reject
#   --accept TYPES             Comma-separated file extensions to accept
#   --convert-links            Convert local links for better offline browsing
#   --discover-off             Disable fallback discovery pass
#   --discover-passes N        Number of fallback discovery passes (default: 2)
#   --discover-limit N         Max new discovered URLs per pass (default: 2000)
#   --scope-prefixes PREFIXES  Optional comma-separated path prefixes to keep discovered URLs in scope
#                              Example: /docs,/blog
#   --no-zip                   Skip creating zip archive after download
#   --robots-on                Respect robots.txt
#   --proxies FILE             Path to proxy list file (default: proxies.txt in script directory)
#   --proxy URL                Inline proxy value; repeatable
#   --user-agents FILE         Path to user agent list file (default: user_agents.txt in script directory)
#   --user-agent STRING        Inline user-agent string; repeatable
#   -h, --help                 Show this help message
#
# Notes:
#   - This is a static-site and archival tool. It works best on traditional sites
#     and semi-static sites that expose crawlable URLs in HTML, JSON, or inline scripts.
#   - It does NOT execute JavaScript. The fallback discovery pass can help on some
#     semi-static sites, but it will NOT solve pure JS-only route generation.
#

set -euo pipefail

BASE_URL=""
DOMAINS=""
SAVE_DIR=""
MAX_RETRIES=5
MAX_CONCURRENCY=0
WAIT_MIN=1
WAIT_MAX=3
DEPTH=""
NO_ASSETS=false
REJECT_TYPES=""
ACCEPT_TYPES=""
CONVERT_LINKS=false
DISCOVERY_ENABLED=true
DISCOVERY_PASSES=2
DISCOVERY_LIMIT=2000
SCOPE_PREFIXES=""
NO_ZIP=false
ROBOTS_OFF=true
PROXY_FILE=""
UA_FILE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN=""
BASE_SCHEME=""
BASE_ORIGIN=""
LOG_FILE=""
STATE_DIR=""
VISITED_URLS_FILE=""
DISCOVERED_URLS_FILE=""
SEED_URLS_FILE=""

PROXIES=()
USER_AGENTS=()
INLINE_PROXIES=()
INLINE_USER_AGENTS=()
DOMAIN_ARRAY=()
SCOPE_PREFIX_ARRAY=()

show_help() {
    sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \?//'
    sed -n '/^# Options:/,/^#$/p' "$0" | sed 's/^# \?//'
    sed -n '/^# Notes:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
}

die() {
    echo "Error: $*" >&2
    exit 1
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

normalize_wait_range() {
    if (( WAIT_MIN < 0 || WAIT_MAX < 0 )); then
        die "--wait values must be >= 0"
    fi
    if (( WAIT_MAX < WAIT_MIN )); then
        local tmp="$WAIT_MIN"
        WAIT_MIN="$WAIT_MAX"
        WAIT_MAX="$tmp"
    fi
}

normalize_domain_item() {
    local item
    item="$(trim "$1")"
    [[ -z "$item" ]] && return 1

    item="${item#http://}"
    item="${item#https://}"
    item="${item#//}"
    item="${item%%/*}"
    item="${item%%:*}"

    item="${item,,}"
    [[ -z "$item" ]] && return 1

    printf '%s\n' "$item"
}

split_csv_to_array() {
    local csv="$1"
    local -n out_ref="$2"
    out_ref=()

    IFS=',' read -r -a _tmp_parts <<< "$csv"
    for part in "${_tmp_parts[@]}"; do
        part="$(trim "$part")"
        [[ -n "$part" ]] && out_ref+=("$part")
    done
}

normalize_domains_csv() {
    local raw="$1"
    local out=()
    local seen=''

    local parts=()
    split_csv_to_array "$raw" parts

    for item in "${parts[@]}"; do
        local norm
        norm="$(normalize_domain_item "$item" 2>/dev/null || true)"
        [[ -z "$norm" ]] && continue

        if [[ ",$seen," != *",$norm,"* ]]; then
            out+=("$norm")
            seen+="${seen:+,}$norm"
        fi
    done

    (IFS=','; printf '%s' "${out[*]}")
}

parse_scope_prefixes() {
    SCOPE_PREFIX_ARRAY=()
    [[ -z "$SCOPE_PREFIXES" ]] && return 0

    local parts=()
    split_csv_to_array "$SCOPE_PREFIXES" parts

    for prefix in "${parts[@]}"; do
        [[ -z "$prefix" ]] && continue
        [[ "$prefix" != /* ]] && prefix="/$prefix"
        SCOPE_PREFIX_ARRAY+=("$prefix")
    done
}

url_host() {
    local url="$1"
    url="${url#http://}"
    url="${url#https://}"
    url="${url%%/*}"
    url="${url%%:*}"
    printf '%s\n' "${url,,}"
}

url_path() {
    local url="$1"
    local rest="${url#http://}"
    rest="${rest#https://}"

    if [[ "$rest" == */* ]]; then
        printf '/%s\n' "${rest#*/}"
    else
        printf '/\n'
    fi
}

is_allowed_domain() {
    local url="$1"
    local host
    host="$(url_host "$url")"

    for d in "${DOMAIN_ARRAY[@]}"; do
        if [[ "$host" == "$d" ]]; then
            return 0
        fi
    done
    return 1
}

is_in_scope_prefix() {
    local url="$1"

    if [[ ${#SCOPE_PREFIX_ARRAY[@]} -eq 0 ]]; then
        return 0
    fi

    local path
    path="$(url_path "$url")"

    for prefix in "${SCOPE_PREFIX_ARRAY[@]}"; do
        if [[ "$path" == "$prefix" || "$path" == "$prefix/"* ]]; then
            return 0
        fi
    done
    return 1
}

clean_line_file_into_array() {
    local file="$1"
    local -n out_ref="$2"
    out_ref=()

    [[ ! -f "$file" ]] && return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        out_ref+=("$line")
    done < "$file"
}

append_unique_value() {
    local value="$1"
    local -n arr_ref="$2"

    [[ -z "$value" ]] && return 0

    local existing
    for existing in "${arr_ref[@]}"; do
        [[ "$existing" == "$value" ]] && return 0
    done

    arr_ref+=("$value")
}

merge_unique_arrays() {
    local -n dest_ref="$1"
    shift

    local name
    for name in "$@"; do
        local -n src_ref="$name"
        local item
        for item in "${src_ref[@]}"; do
            append_unique_value "$item" dest_ref
        done
    done
}

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
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

normalize_candidate_url() {
    local raw="$1"
    raw="$(trim "$raw")"
    [[ -z "$raw" ]] && return 1

    raw="${raw#\"}"
    raw="${raw#\'}"
    raw="${raw#\(}"
    raw="${raw#\[}"
    raw="${raw#\{}"

    raw="${raw%\"}"
    raw="${raw%\'}"
    raw="${raw%\)}"
    raw="${raw%\]}"
    raw="${raw%\}}"
    raw="${raw%,}"
    raw="${raw%;}"

    [[ -z "$raw" ]] && return 1
    [[ "$raw" == javascript:* ]] && return 1
    [[ "$raw" == mailto:* ]] && return 1
    [[ "$raw" == data:* ]] && return 1

    if [[ "$raw" == //* ]]; then
        raw="${BASE_SCHEME}:${raw}"
    elif [[ "$raw" == /* ]]; then
        raw="${BASE_ORIGIN}${raw}"
    elif [[ "$raw" != http://* && "$raw" != https://* ]]; then
        return 1
    fi

    raw="${raw%%#*}"

    if [[ "$raw" == */ && "$raw" != "${BASE_SCHEME}://"*"/" ]]; then
        raw="${raw%/}"
    fi

    is_allowed_domain "$raw" || return 1
    is_in_scope_prefix "$raw" || return 1

    printf '%s\n' "$raw"
}

extract_candidate_urls_from_html() {
    local file="$1"

    sed 's#\\/#/#g' "$file" 2>/dev/null | grep -aoE 'https?://[^"'\''<>[:space:]]+' || true
    sed 's#\\/#/#g' "$file" 2>/dev/null | grep -aoE '//[^"'\''<>[:space:]]+' || true
    sed 's#\\/#/#g' "$file" 2>/dev/null | grep -aoE '/[^"'\''<>[:space:]]+' || true
}

discover_new_urls() {
    local pass_num="$1"
    local tmp_raw
    local tmp_norm
    local tmp_new

    tmp_raw="$(mktemp)"
    tmp_norm="$(mktemp)"
    tmp_new="$(mktemp)"

    find "$SAVE_DIR" -type f \( -iname '*.html' -o -iname '*.htm' \) -print0 | while IFS= read -r -d '' html_file; do
        extract_candidate_urls_from_html "$html_file"
    done > "$tmp_raw"

    while IFS= read -r candidate || [[ -n "$candidate" ]]; do
        local normalized
        normalized="$(normalize_candidate_url "$candidate" 2>/dev/null || true)"
        [[ -n "$normalized" ]] && echo "$normalized"
    done < "$tmp_raw" | sort -u > "$tmp_norm"

    if [[ -f "$VISITED_URLS_FILE" ]]; then
        grep -Fvx -f "$VISITED_URLS_FILE" "$tmp_norm" > "$tmp_new" || true
    else
        cp "$tmp_norm" "$tmp_new"
    fi

    if (( DISCOVERY_LIMIT > 0 )); then
        head -n "$DISCOVERY_LIMIT" "$tmp_new" > "${tmp_new}.limited"
        mv "${tmp_new}.limited" "$tmp_new"
    fi

    local count=0
    count="$(wc -l < "$tmp_new" | tr -d ' ')"

    if (( count > 0 )); then
        cat "$tmp_new" >> "$DISCOVERED_URLS_FILE"
    fi

    log_message "Discovery pass ${pass_num}: found ${count} new URL(s)."

    cat "$tmp_new"

    rm -f "$tmp_raw" "$tmp_norm" "$tmp_new"
}

mark_visited_url() {
    local url="$1"
    echo "$url" >> "$VISITED_URLS_FILE"
}

run_single_wget() {
    local url="$1"
    local attempt=0

    while (( attempt < MAX_RETRIES )); do
        local proxy_args=()
        if [[ ${#PROXIES[@]} -gt 0 ]]; then
            local proxy
            proxy="$(get_random_item "${PROXIES[@]}")"
            proxy_args=(-e "use_proxy=yes" -e "https_proxy=${proxy}" -e "http_proxy=${proxy}")
            log_message "Attempt $((attempt + 1)) for ${url}: Proxy: $proxy"
        fi

        local user_agent
        user_agent="$(get_random_item "${USER_AGENTS[@]}")"

        local wait_this_request=$(( (RANDOM % (WAIT_MAX - WAIT_MIN + 1)) + WAIT_MIN ))

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
            --wait="$wait_this_request"
            --no-http-keep-alive
            --directory-prefix="$SAVE_DIR"
        )

        if [[ "$NO_ASSETS" == false ]]; then
            wget_opts+=(--page-requisites)
        fi

        if [[ -n "$DEPTH" && "$DEPTH" != "0" ]]; then
            wget_opts+=(--level="$DEPTH")
        fi

        if [[ -n "$REJECT_TYPES" ]]; then
            wget_opts+=(--reject "$REJECT_TYPES")
        fi

        if [[ -n "$ACCEPT_TYPES" ]]; then
            wget_opts+=(--accept "$ACCEPT_TYPES")
        fi

        if [[ "$ROBOTS_OFF" == true ]]; then
            wget_opts+=(--execute "robots=off")
        fi

        if [[ "$CONVERT_LINKS" == true ]]; then
            wget_opts+=(--convert-links)
        fi

        log_message "User-Agent: $user_agent"
        log_message "Fetching: $url"

        local result=0
        if wget "${wget_opts[@]}" "${proxy_args[@]}" "$url"; then
            log_message "Download successful: $url"
            return 0
        else
            result=$?
        fi

        if [[ $result -eq 8 ]]; then
            log_message "HTTP/server error code 8 from wget for ${url}. Rotating proxy/user agent and retrying."
        else
            log_message "wget exited with code ${result} for ${url}. Retrying."
        fi

        attempt=$((attempt + 1))
        if (( attempt < MAX_RETRIES )); then
            random_delay
        fi
    done

    log_message "Max retries (${MAX_RETRIES}) reached for: $url"
    return 1
}

run_url_batch() {
    local batch_name="$1"
    shift

    local urls=("$@")
    local total="${#urls[@]}"

    (( total == 0 )) && return 0

    log_message "Starting batch '${batch_name}' with ${total} URL(s)."

    local -a pids=()
    local active=0

    for url in "${urls[@]}"; do
        mark_visited_url "$url"
        run_single_wget "$url" &
        pids+=("$!")
        active=$((active + 1))

        while (( active >= MAX_CONCURRENCY )); do
            if wait -n "${pids[@]}" 2>/dev/null; then
                :
            else
                :
            fi
            active="$(jobs -pr | wc -l | tr -d ' ')"
        done

        random_delay
    done

    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            :
        fi
    done

    log_message "Completed batch '${batch_name}'."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)
            [[ $# -lt 2 ]] && die "--url requires a value"
            BASE_URL="$2"
            shift 2
            ;;
        -d|--domains)
            [[ $# -lt 2 ]] && die "--domains requires a value"
            DOMAINS="$2"
            shift 2
            ;;
        -o|--output)
            [[ $# -lt 2 ]] && die "--output requires a value"
            SAVE_DIR="$2"
            shift 2
            ;;
        -r|--retries)
            [[ $# -lt 2 ]] && die "--retries requires a value"
            MAX_RETRIES="$2"
            shift 2
            ;;
        -c|--concurrency)
            [[ $# -lt 2 ]] && die "--concurrency requires a value"
            MAX_CONCURRENCY="$2"
            shift 2
            ;;
        -w|--wait)
            [[ $# -lt 2 ]] && die "--wait requires at least one value"
            WAIT_MIN="$2"
            if [[ -n "${3:-}" && "$3" =~ ^[0-9]+$ ]]; then
                WAIT_MAX="$3"
                shift 3
            else
                WAIT_MAX="$2"
                shift 2
            fi
            ;;
        --depth)
            [[ $# -lt 2 ]] && die "--depth requires a value"
            DEPTH="$2"
            shift 2
            ;;
        --no-assets)
            NO_ASSETS=true
            shift
            ;;
        --reject)
            [[ $# -lt 2 ]] && die "--reject requires a value"
            REJECT_TYPES="$2"
            shift 2
            ;;
        --accept)
            [[ $# -lt 2 ]] && die "--accept requires a value"
            ACCEPT_TYPES="$2"
            shift 2
            ;;
        --convert-links)
            CONVERT_LINKS=true
            shift
            ;;
        --discover-off)
            DISCOVERY_ENABLED=false
            shift
            ;;
        --discover-passes)
            [[ $# -lt 2 ]] && die "--discover-passes requires a value"
            DISCOVERY_PASSES="$2"
            shift 2
            ;;
        --discover-limit)
            [[ $# -lt 2 ]] && die "--discover-limit requires a value"
            DISCOVERY_LIMIT="$2"
            shift 2
            ;;
        --scope-prefixes)
            [[ $# -lt 2 ]] && die "--scope-prefixes requires a value"
            SCOPE_PREFIXES="$2"
            shift 2
            ;;
        --no-zip)
            NO_ZIP=true
            shift
            ;;
        --robots-on)
            ROBOTS_OFF=false
            shift
            ;;
        --proxies)
            [[ $# -lt 2 ]] && die "--proxies requires a value"
            PROXY_FILE="$2"
            shift 2
            ;;
        --proxy)
            [[ $# -lt 2 ]] && die "--proxy requires a value"
            INLINE_PROXIES+=("$2")
            shift 2
            ;;
        --user-agents)
            [[ $# -lt 2 ]] && die "--user-agents requires a value"
            UA_FILE="$2"
            shift 2
            ;;
        --user-agent)
            [[ $# -lt 2 ]] && die "--user-agent requires a value"
            INLINE_USER_AGENTS+=("$2")
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ -z "$BASE_URL" ]] && die "--url is required"

if ! [[ "$BASE_URL" =~ ^https?:// ]]; then
    die "--url must start with http:// or https://"
fi

normalize_wait_range

BASE_SCHEME="$(echo "$BASE_URL" | sed -E 's#^(https?)://.*#\1#')"
DOMAIN="$(echo "$BASE_URL" | sed -E 's#^https?://([^/]+).*#\1#' | sed 's/:.*$//' | tr '[:upper:]' '[:lower:]')"
BASE_ORIGIN="${BASE_SCHEME}://${DOMAIN}"

if [[ -z "$DOMAINS" ]]; then
    DOMAINS="$DOMAIN"
else
    DOMAINS="$(normalize_domains_csv "$DOMAINS")"
fi

[[ -z "$DOMAINS" ]] && die "No valid domains remain after normalization"

split_csv_to_array "$DOMAINS" DOMAIN_ARRAY
parse_scope_prefixes

if [[ -z "$SAVE_DIR" ]]; then
    SAVE_DIR="./snapshot_output/${DOMAIN}"
fi

LOG_FILE="${SAVE_DIR}/snapshot.log"
STATE_DIR="${SAVE_DIR}/.snapshot_state"
VISITED_URLS_FILE="${STATE_DIR}/visited_urls.txt"
DISCOVERED_URLS_FILE="${STATE_DIR}/discovered_urls.txt"
SEED_URLS_FILE="${STATE_DIR}/seed_urls.txt"

if [[ -z "$PROXY_FILE" ]]; then
    PROXY_FILE="${SCRIPT_DIR}/proxies.txt"
fi

if [[ -f "$PROXY_FILE" ]]; then
    clean_line_file_into_array "$PROXY_FILE" PROXIES
else
    PROXIES=()
fi

if [[ -z "$UA_FILE" ]]; then
    UA_FILE="${SCRIPT_DIR}/user_agents.txt"
fi

if [[ -f "$UA_FILE" ]]; then
    clean_line_file_into_array "$UA_FILE" USER_AGENTS
else
    USER_AGENTS=()
fi

merge_unique_arrays PROXIES INLINE_PROXIES
merge_unique_arrays USER_AGENTS INLINE_USER_AGENTS

if [[ ${#USER_AGENTS[@]} -eq 0 ]]; then
    USER_AGENTS=("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
fi

if (( MAX_CONCURRENCY == 0 )); then
    MAX_CONCURRENCY=$(( (RANDOM % 7) + 2 ))
fi

(( MAX_CONCURRENCY < 1 )) && die "--concurrency must be >= 1"
(( MAX_RETRIES < 1 )) && die "--retries must be >= 1"
(( DISCOVERY_PASSES < 0 )) && die "--discover-passes must be >= 0"
(( DISCOVERY_LIMIT < 0 )) && die "--discover-limit must be >= 0"

mkdir -p "$SAVE_DIR" "$STATE_DIR"
touch "$VISITED_URLS_FILE" "$DISCOVERED_URLS_FILE" "$SEED_URLS_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log_message "=== Snapshot session started ==="
log_message "Target: $BASE_URL"
log_message "Domains: $DOMAINS"
log_message "Output: $SAVE_DIR"
log_message "Concurrency: $MAX_CONCURRENCY"
log_message "Discovery enabled: $DISCOVERY_ENABLED"
log_message "Discovery passes: $DISCOVERY_PASSES"
log_message "Discovery limit per pass: $DISCOVERY_LIMIT"
if [[ ${#SCOPE_PREFIX_ARRAY[@]} -gt 0 ]]; then
    log_message "Scope prefixes: ${SCOPE_PREFIX_ARRAY[*]}"
else
    log_message "Scope prefixes: none"
fi

if [[ ${#PROXIES[@]} -gt 0 ]]; then
    log_message "Loaded ${#PROXIES[@]} total proxies."
    if [[ -f "$PROXY_FILE" ]]; then
        log_message "Proxy file source: $PROXY_FILE"
    fi
    if [[ ${#INLINE_PROXIES[@]} -gt 0 ]]; then
        log_message "Inline proxies provided: ${#INLINE_PROXIES[@]}"
    fi
else
    log_message "Warning: no proxies loaded. Requests will use your own IP."
fi

if [[ ${#USER_AGENTS[@]} -gt 0 ]]; then
    log_message "Loaded ${#USER_AGENTS[@]} total user agents."
    if [[ -f "$UA_FILE" ]]; then
        log_message "User-agent file source: $UA_FILE"
    fi
    if [[ ${#INLINE_USER_AGENTS[@]} -gt 0 ]]; then
        log_message "Inline user agents provided: ${#INLINE_USER_AGENTS[@]}"
    fi
else
    log_message "Warning: no user agents loaded."
fi

SEED_URLS=("$BASE_URL")
printf '%s\n' "${SEED_URLS[@]}" > "$SEED_URLS_FILE"

run_url_batch "seed" "${SEED_URLS[@]}"

if [[ "$DISCOVERY_ENABLED" == true && "$DISCOVERY_PASSES" -gt 0 ]]; then
    pass=1
    while (( pass <= DISCOVERY_PASSES )); do
        mapfile -t NEW_URLS < <(discover_new_urls "$pass")

        if [[ ${#NEW_URLS[@]} -eq 0 ]]; then
            log_message "Discovery pass ${pass}: no new URLs. Stopping discovery."
            break
        fi

        run_url_batch "discovery-${pass}" "${NEW_URLS[@]}"
        pass=$((pass + 1))
    done
fi

log_message "All downloads completed."

if [[ "$NO_ZIP" == false ]]; then
    sanitized="$(echo "$DOMAIN" | sed 's#[/:]#_#g')"
    zip_path="${SAVE_DIR%/}/../${sanitized}.zip"
    if zip -rq "$zip_path" "$SAVE_DIR"; then
        log_message "Archive created: $zip_path"
    else
        log_message "Warning: zip creation failed."
    fi
fi

log_message "=== Snapshot session finished ==="
exit 0
