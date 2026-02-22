#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Script 1: Scrape Indexes
#
# Scrapes DOJ Epstein case file index pages, extracts PDF URLs, and writes
# them to epstein_files/urls/. Run this first (or skip if you already have
# the index files).
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

OUTPUT_DIR="${OUTPUT_DIR:-./epstein_files}"
DELAY_BETWEEN_PAGES="${DELAY_BETWEEN_PAGES:-1}"

BASE_URL="https://www.justice.gov"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
COOKIE="justiceGovAgeVerified=true"

CONNECT_TIMEOUT=30

# ── Color codes ──────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Logging ──────────────────────────────────────────────────────────────────

LOG_FILE=""

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
    esac

    printf "${color}[%s] [%-5s] %s${NC}\n" "$timestamp" "$level" "$message" >&2

    if [[ -n "$LOG_FILE" ]]; then
        printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE"
    fi
}

# ── fetch_page ───────────────────────────────────────────────────────────────

fetch_page() {
    local url="$1"
    curl -s -L \
        -b "$COOKIE" \
        -H "User-Agent: $USER_AGENT" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time 60 \
        "$url" || true
}

# ── extract_pdf_links ────────────────────────────────────────────────────────

extract_pdf_links() {
    grep -oP 'href="[^"]*\.pdf"' \
        | sed 's/^href="//;s/"$//' \
        | sed 's/&amp;/\&/g' \
        | while IFS= read -r link; do
            if [[ "$link" == http* ]]; then
                echo "$link"
            else
                echo "${BASE_URL}${link}"
            fi
        done
}

# ── scrape_dataset ───────────────────────────────────────────────────────────

scrape_dataset() {
    local dataset_num="$1"
    local url_file="${OUTPUT_DIR}/urls/dataset_${dataset_num}.txt"
    local base_page_url="${BASE_URL}/epstein/doj-disclosures/data-set-${dataset_num}-files"

    log_msg INFO "Scraping dataset ${dataset_num}..."

    mkdir -p "${OUTPUT_DIR}/dataset_${dataset_num}"

    log_msg DEBUG "  Fetching page 1: ${base_page_url}"
    local html
    html="$(fetch_page "$base_page_url")"

    if [[ -z "$html" ]]; then
        log_msg WARN "  No HTML returned for dataset ${dataset_num} page 1"
        touch "$url_file"
        return
    fi

    local page_links
    page_links="$(echo "$html" | extract_pdf_links)"

    if [[ -z "$page_links" ]]; then
        log_msg WARN "  No PDF links found on dataset ${dataset_num} page 1"
        touch "$url_file"
        return
    fi

    echo "$page_links" > "$url_file"
    local count
    count="$(echo "$page_links" | wc -l)"
    log_msg INFO "  Page 1: found ${count} PDF links"

    local prev_links="$page_links"

    local page=1
    while true; do
        page=$((page + 1))
        local page_url="${base_page_url}?%70age=${page}"

        sleep "$DELAY_BETWEEN_PAGES"
        log_msg DEBUG "  Fetching page ${page}: ${page_url}"

        html="$(fetch_page "$page_url")"

        if [[ -z "$html" ]]; then
            log_msg DEBUG "  Empty response on page ${page}, stopping pagination"
            break
        fi

        page_links="$(echo "$html" | extract_pdf_links)"

        if [[ -z "$page_links" ]]; then
            log_msg DEBUG "  No PDF links on page ${page}, stopping pagination"
            break
        fi

        if [[ "$page_links" == "$prev_links" ]]; then
            log_msg DEBUG "  Page ${page} returned duplicate content, stopping pagination"
            break
        fi
        prev_links="$page_links"

        local new_count
        new_count="$(echo "$page_links" | wc -l)"

        echo "$page_links" >> "$url_file"
        log_msg INFO "  Page ${page}: found ${new_count} PDF links"

        if [[ $page -ge 100 ]]; then
            log_msg WARN "  Reached page 100 safety cap for dataset ${dataset_num}"
            break
        fi
    done

    if [[ -f "$url_file" ]]; then
        sort -u "$url_file" -o "$url_file"
        local total
        total="$(wc -l < "$url_file")"
        log_msg INFO "Dataset ${dataset_num}: ${total} unique PDF URLs"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    log_msg INFO "========================================"
    log_msg INFO "Scrape Indexes — Starting"
    log_msg INFO "========================================"

    mkdir -p "${OUTPUT_DIR}/urls"

    LOG_FILE="${OUTPUT_DIR}/scrape.log"

    local ds
    for ds in $(seq 1 12); do
        scrape_dataset "$ds"
    done

    # Build master URL list (deduplicated)
    local master_list="${OUTPUT_DIR}/urls/all_urls.txt"
    cat "${OUTPUT_DIR}"/urls/dataset_*.txt 2>/dev/null | sort -u > "$master_list"

    local total_urls
    total_urls="$(wc -l < "$master_list")"
    log_msg INFO ""
    log_msg INFO "Done: ${total_urls} unique PDF URLs across all datasets"
    log_msg INFO "Index written to: ${master_list}"
    log_msg INFO ""
    log_msg INFO "Now run ./probe-extensions.sh to probe for non-PDF files."
}

main "$@"
