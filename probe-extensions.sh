#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Script 2: Probe Extensions (Numeric Sweep)
#
# Iterates numerically through every possible EFTA ID in each dataset's range
# and probes for non-PDF file extensions (mp4, avi, mp3, jpg, etc.).
# Downloads any that return HTTP 200.
#
# Includes rate-limit detection: periodically checks a known-good URL and
# pauses all workers if blocked.
#
# Usage:
#   ./probe-extensions.sh                      # sweep all datasets
#   DATASETS="8 9" ./probe-extensions.sh       # sweep specific datasets only
#   MAX_PARALLEL=2 ./probe-extensions.sh       # fewer workers (gentler)
#   REQUEST_DELAY=1 ./probe-extensions.sh      # 1s between requests per worker
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

OUTPUT_DIR="${OUTPUT_DIR:-./epstein_files}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
RETRY_COUNT="${RETRY_COUNT:-3}"

EXTENSIONS=(mp4 avi mp3 jpg png jpeg wav mov gif)
EXTENSIONS_STR="${EXTENSIONS[*]}"
NUM_EXTENSIONS="${#EXTENSIONS[@]}"

BASE_URL="https://www.justice.gov/epstein/files"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
COOKIE="justiceGovAgeVerified=true"

CONNECT_TIMEOUT=30
MAX_TIME=600
BACKOFF_SECS="${BACKOFF_SECS:-30}"
REQUEST_DELAY="${REQUEST_DELAY:-0.3}"  # seconds between HEAD requests per worker

# Known-good URL for health checks (a PDF we know exists)
HEALTH_CHECK_URL="https://www.justice.gov/epstein/files/DataSet%201/EFTA00000001.pdf"
HEALTH_CHECK_INTERVAL=500  # check every N IDs processed

# ── Dataset ID ranges ───────────────────────────────────────────────────────

RANGES=(
    "1 1 3158"
    "2 3159 3857"
    "3 3858 5704"
    "4 5705 8408"
    "5 8409 8584"
    "6 8585 9015"
    "7 9016 9675"
    "8 9676 39024"
    "9 39025 64914"
    "10 1262782 1301444"
    "11 2205655 2221607"
    "12 2730265 2731852"
)

# ── Color codes ──────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Shared state ─────────────────────────────────────────────────────────────

LOG_FILE=""
FAILED_LOG=""
HITS_LOG=""
PROGRESS_FILE=""
BLOCKED_FILE=""
TOTAL_IDS=""

# ── Logging ──────────────────────────────────────────────────────────────────

log_msg() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local color="$NC"

    case "$level" in
        INFO)  color="$GREEN"  ;;
        WARN)  color="$YELLOW" ;;
        ERROR) color="$RED"    ;;
        DEBUG) color="$CYAN"   ;;
        PROBE) color="$BLUE"   ;;
    esac

    printf "${color}[%s] [%-5s] %s${NC}\n" "$timestamp" "$level" "$message" >&2

    if [[ -n "$LOG_FILE" ]]; then
        printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
    fi
}

# ── download_file ────────────────────────────────────────────────────────────

download_file() {
    local url="$1"
    local output_path="$2"
    local attempt=0

    while [[ $attempt -lt $RETRY_COUNT ]]; do
        attempt=$((attempt + 1))

        local http_code
        http_code="$(curl -s -L -o "$output_path" -w "%{http_code}" \
            -C - \
            -b "$COOKIE" \
            -H "User-Agent: $USER_AGENT" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            "$url" 2>/dev/null || true)"

        if [[ "$http_code" == "200" || "$http_code" == "206" ]]; then
            return 0
        fi

        if [[ $attempt -lt $RETRY_COUNT ]]; then
            local backoff=$((attempt * 3))
            log_msg WARN "  Download failed (HTTP ${http_code}), retry ${attempt}/${RETRY_COUNT} in ${backoff}s: $(basename "$output_path")"
            sleep "$backoff"
        fi
    done

    rm -f "$output_path"
    return 1
}

# ── health_check ─────────────────────────────────────────────────────────────
# Checks if a known-good URL is accessible. If blocked, waits until unblocked.

health_check() {
    local hc_code
    hc_code="$(curl -s -o /dev/null -w "%{http_code}" \
        -I -L \
        -b "$COOKIE" \
        -H "User-Agent: $USER_AGENT" \
        --connect-timeout 10 \
        --max-time 15 \
        "$HEALTH_CHECK_URL" 2>/dev/null || echo "000")"

    if [[ "$hc_code" != "200" ]]; then
        log_msg WARN "RATE LIMITED — health check returned HTTP ${hc_code}. Pausing..."

        # Signal other workers to pause
        echo "1" > "$BLOCKED_FILE"

        # Wait until health check passes again
        local wait_secs=60
        while true; do
            log_msg WARN "  Waiting ${wait_secs}s before retry..."
            sleep "$wait_secs"

            hc_code="$(curl -s -o /dev/null -w "%{http_code}" \
                -I -L \
                -b "$COOKIE" \
                -H "User-Agent: $USER_AGENT" \
                --connect-timeout 10 \
                --max-time 15 \
                "$HEALTH_CHECK_URL" 2>/dev/null || echo "000")"

            if [[ "$hc_code" == "200" ]]; then
                log_msg INFO "Health check passed (HTTP 200). Resuming."
                echo "0" > "$BLOCKED_FILE"
                return
            fi

            # Exponential backoff, cap at 5 min
            wait_secs=$(( wait_secs * 2 ))
            if [[ $wait_secs -gt 300 ]]; then
                wait_secs=300
            fi
        done
    fi
}

# ── probe_id ─────────────────────────────────────────────────────────────────

probe_id() {
    local ds_num="$1"
    local efta_id="$2"

    local -a exts
    IFS=' ' read -ra exts <<< "$EXTENSIONS_STR"

    local padded_id
    padded_id="$(printf '%08d' "$efta_id")"

    local file_base="EFTA${padded_id}"
    local url_base="${BASE_URL}/DataSet%20${ds_num}/${file_base}"
    local dataset_dir="${OUTPUT_DIR}/dataset_${ds_num}"

    # Wait if we're blocked
    if [[ -f "$BLOCKED_FILE" ]] && [[ "$(cat "$BLOCKED_FILE" 2>/dev/null)" == "1" ]]; then
        while [[ "$(cat "$BLOCKED_FILE" 2>/dev/null)" == "1" ]]; do
            sleep 5
        done
    fi

    # Progress counter
    local done_count
    done_count="$(
        exec 200>"${PROGRESS_FILE}.lock"
        flock -x 200
        local n=0
        [[ -s "$PROGRESS_FILE" ]] && n="$(cat "$PROGRESS_FILE")"
        n=$((n + 1))
        echo "$n" > "$PROGRESS_FILE"
        echo "$n"
    )"
    printf "\r\033[K\033[0;36m[%s/%s] DS%s — %s\033[0m" "$done_count" "$TOTAL_IDS" "$ds_num" "$file_base" >&2

    # Periodic health check
    if (( done_count % HEALTH_CHECK_INTERVAL == 0 )); then
        health_check
    fi

    local ext
    for ext in "${exts[@]}"; do
        local probe_url="${url_base}.${ext}"
        local output_path="${dataset_dir}/${file_base}.${ext}"

        # Skip if already downloaded
        if [[ -f "$output_path" && -s "$output_path" ]]; then
            continue
        fi

        # Throttle
        sleep "$REQUEST_DELAY"

        # HEAD request
        local http_code
        http_code="$(curl -s -o /dev/null -w "%{http_code}" \
            -I -L \
            -b "$COOKIE" \
            -H "User-Agent: $USER_AGENT" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time 30 \
            "$probe_url" 2>/dev/null || echo "000")"

        if [[ "$http_code" == "200" ]]; then
            log_msg PROBE "  HIT: ${file_base}.${ext} (HTTP 200)"

            if [[ -n "$HITS_LOG" ]]; then
                (flock -x 200; echo "$probe_url" >> "$HITS_LOG") 200>"${HITS_LOG}.lock"
            fi

            log_msg INFO "  Downloading: ${file_base}.${ext}"

            if download_file "$probe_url" "$output_path"; then
                log_msg INFO "  DONE: ${file_base}.${ext}"
            else
                log_msg ERROR "  FAILED: ${file_base}.${ext}"
                (flock -x 200; echo "$probe_url" >> "$FAILED_LOG") 200>"${FAILED_LOG}.lock"
            fi
        elif [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
            log_msg WARN "  BLOCKED (HTTP ${http_code}) at ${file_base}.${ext}"
            health_check
            # Don't skip — will naturally continue to next ext, which will be delayed
        fi
    done
}

# Export for xargs subshells
export -f probe_id download_file log_msg health_check
export OUTPUT_DIR RETRY_COUNT BASE_URL USER_AGENT COOKIE CONNECT_TIMEOUT MAX_TIME
export BACKOFF_SECS REQUEST_DELAY HEALTH_CHECK_URL HEALTH_CHECK_INTERVAL
export LOG_FILE FAILED_LOG HITS_LOG PROGRESS_FILE BLOCKED_FILE TOTAL_IDS
export RED GREEN YELLOW BLUE CYAN NC
export EXTENSIONS_STR

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    # Parse which datasets to run (default: all)
    local -a selected_ranges=()
    local filter_datasets="${DATASETS:-}"

    for entry in "${RANGES[@]}"; do
        local ds start end
        read -r ds start end <<< "$entry"
        if [[ -z "$filter_datasets" ]] || echo "$filter_datasets" | grep -qw "$ds"; then
            selected_ranges+=("$entry")
        fi
    done

    if [[ ${#selected_ranges[@]} -eq 0 ]]; then
        echo "ERROR: No datasets selected." >&2
        exit 1
    fi

    # Count total IDs to probe
    local total=0
    for entry in "${selected_ranges[@]}"; do
        local ds start end
        read -r ds start end <<< "$entry"
        total=$(( total + end - start + 1 ))
    done
    TOTAL_IDS="$total"

    # Create directory structure
    mkdir -p "${OUTPUT_DIR}"
    for entry in "${selected_ranges[@]}"; do
        local ds start end
        read -r ds start end <<< "$entry"
        mkdir -p "${OUTPUT_DIR}/dataset_${ds}"
    done

    # Initialize logs and progress
    LOG_FILE="${OUTPUT_DIR}/probe.log"
    FAILED_LOG="${OUTPUT_DIR}/failed.log"
    HITS_LOG="${OUTPUT_DIR}/hits.log"
    PROGRESS_FILE="${OUTPUT_DIR}/.progress"
    BLOCKED_FILE="${OUTPUT_DIR}/.blocked"
    export LOG_FILE FAILED_LOG HITS_LOG PROGRESS_FILE BLOCKED_FILE TOTAL_IDS

    : > "$FAILED_LOG"
    : > "$HITS_LOG"
    echo "0" > "$PROGRESS_FILE"
    echo "0" > "$BLOCKED_FILE"

    # Initial health check
    log_msg INFO "Running initial health check..."
    local hc_code
    hc_code="$(curl -s -o /dev/null -w "%{http_code}" \
        -I -L \
        -b "$COOKIE" \
        -H "User-Agent: $USER_AGENT" \
        --connect-timeout 10 --max-time 15 \
        "$HEALTH_CHECK_URL" 2>/dev/null || echo "000")"

    if [[ "$hc_code" != "200" ]]; then
        log_msg ERROR "Health check failed (HTTP ${hc_code}). IP may be blocked. Try again later."
        exit 1
    fi
    log_msg INFO "Health check passed (HTTP 200)"

    log_msg INFO "========================================"
    log_msg INFO "Probe Extensions — Numeric Sweep"
    log_msg INFO "========================================"
    log_msg INFO "Output directory: ${OUTPUT_DIR}"
    log_msg INFO "Max parallel workers: ${MAX_PARALLEL}"
    log_msg INFO "Request delay: ${REQUEST_DELAY}s per request per worker"
    log_msg INFO "Health check every: ${HEALTH_CHECK_INTERVAL} IDs"
    log_msg INFO "Extensions to probe: ${EXTENSIONS[*]}"
    log_msg INFO ""

    for entry in "${selected_ranges[@]}"; do
        local ds start end
        read -r ds start end <<< "$entry"
        local count=$(( end - start + 1 ))
        log_msg INFO "  Dataset ${ds}: EFTA$(printf '%08d' "$start") — EFTA$(printf '%08d' "$end") (${count} IDs)"
    done

    log_msg INFO ""
    log_msg INFO "Total: ${TOTAL_IDS} IDs x ${NUM_EXTENSIONS} extensions = $(( TOTAL_IDS * NUM_EXTENSIONS )) HEAD requests"
    log_msg INFO ""

    # Generate work list and pipe into xargs
    for entry in "${selected_ranges[@]}"; do
        local ds start end
        read -r ds start end <<< "$entry"
        for (( id=start; id<=end; id++ )); do
            echo "$ds $id"
        done
    done | xargs -P "$MAX_PARALLEL" -L 1 bash -c 'probe_id $0 $1'

    # Clear progress line
    printf "\r\033[K" >&2

    # Clean up
    rm -f "${PROGRESS_FILE}" "${PROGRESS_FILE}.lock" "${BLOCKED_FILE}"

    # ── Summary ──────────────────────────────────────────────────────────
    log_msg INFO ""
    log_msg INFO "========================================"
    log_msg INFO "Probe complete!"
    log_msg INFO "========================================"

    local hit_count=0
    if [[ -f "$HITS_LOG" ]]; then
        hit_count="$(wc -l < "$HITS_LOG")"
    fi

    local failed_count=0
    if [[ -f "$FAILED_LOG" ]]; then
        failed_count="$(wc -l < "$FAILED_LOG")"
    fi

    log_msg INFO "Total hits: ${hit_count}"

    if [[ "$failed_count" -gt 0 ]]; then
        log_msg WARN "Failed downloads: ${failed_count} (see ${FAILED_LOG})"
    else
        log_msg INFO "No failed downloads"
    fi

    if [[ "$hit_count" -gt 0 ]]; then
        log_msg PROBE "Hits log: ${HITS_LOG}"
        log_msg PROBE "Files found:"
        while IFS= read -r url; do
            log_msg PROBE "  -> ${url}"
        done < "$HITS_LOG"
    else
        log_msg INFO "No non-PDF files found."
    fi

    log_msg INFO "Log file: ${LOG_FILE}"
    log_msg INFO "Done."
}

main "$@"
