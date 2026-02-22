# Epstein File Finder

Bash script that scrapes and downloads DOJ Epstein case files from [justice.gov/epstein](https://www.justice.gov/epstein), probing each file for alternative extensions (mp4, avi, mp3, jpg, etc.) that may exist alongside the indexed PDFs.

## Why

The DOJ publishes 12 datasets of Epstein case documents as PDF links on paginated index pages. This script:

- Scrapes all 12 dataset indexes to collect every individual file URL
- Probes each file's base URL with 10 different extensions to find media files that aren't linked in the index
- Downloads everything that returns HTTP 200
- Runs downloads in parallel with resume support

## Requirements

Standard Linux/macOS tools — no external packages:

- `bash` (4.0+)
- `curl`
- `grep` (with `-P` / PCRE support)
- `sed`, `xargs`

## Quick Start

```bash
git clone https://github.com/GroveCityTechLab/epstein-file-finder.git
cd epstein-file-finder

# Step 1: Scrape all 12 dataset index pages to collect PDF URLs
./scrape-indexes.sh

# Step 2: Probe every EFTA ID for non-PDF extensions and download hits
./probe-extensions.sh
```

## Configuration

All settings can be overridden via environment variables.

### scrape-indexes.sh

| Variable | Default | Description |
|---|---|---|
| `OUTPUT_DIR` | `./epstein_files` | Base download directory |
| `DELAY_BETWEEN_PAGES` | `1` | Seconds between page scrapes |

### probe-extensions.sh

| Variable | Default | Description |
|---|---|---|
| `OUTPUT_DIR` | `./epstein_files` | Base download directory |
| `MAX_PARALLEL` | `3` | Concurrent download workers |
| `RETRY_COUNT` | `3` | Retries per failed download |
| `REQUEST_DELAY` | `0.3` | Seconds between HEAD requests per worker |
| `DATASETS` | *(all)* | Space-separated dataset numbers to probe (e.g. `"8 9"`) |
| `BACKOFF_SECS` | `30` | Initial backoff when rate-limited |

Examples:

```bash
# Gentle crawl of specific datasets
DATASETS="8 9" MAX_PARALLEL=2 ./probe-extensions.sh

# Fast sweep with custom output directory
MAX_PARALLEL=10 OUTPUT_DIR=/mnt/data/epstein ./probe-extensions.sh
```

## How It Works

**Phase 1 — Scrape:** Iterates datasets 1–12, paginates each index page, extracts all PDF URLs via regex, and deduplicates into a central list.

**Phase 2 — Probe & Download:** For each PDF URL, strips the `.pdf` extension and sends HEAD requests for:

`pdf` `mp4` `avi` `mp3` `jpg` `png` `jpeg` `wav` `mov` `gif`

Any extension returning HTTP 200 gets downloaded via GET.

## Output Structure

```
epstein_files/
├── dataset_1/          # Files from dataset 1
├── dataset_2/          # Files from dataset 2
├── ...
├── dataset_12/         # Files from dataset 12
├── urls/               # Scraped URL lists per dataset
│   ├── dataset_1.txt
│   ├── ...
│   └── all_urls.txt    # Deduplicated master list
├── download.log        # Full activity log
└── failed.log          # Failed downloads (for re-run)
```

## Re-running

Both scripts are idempotent — existing files are skipped, and `curl -C -` resumes partial downloads. Just run them again to retry failures or pick up where you left off.

## License

[MIT](LICENSE)
