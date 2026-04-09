#!/usr/bin/env bash
# collect_org.sh - Collect health metrics for all (or filtered) repos in an org.
#
# Usage:
#   ./collect_org.sh ORG [--limit N] [--exclude fork,archived] [--output DIR] [-v]
#
# Output: one JSON file per repo in OUTPUT_DIR (default: ./data/raw/)
#         and a combined data/raw/all.json
#
# Requirements: gh (authenticated), jq, collect_repo.sh in same directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG="${1:?Usage: collect_org.sh ORG [--limit N] [--exclude fork,archived] [--output DIR]}"
shift

LIMIT=0          # 0 = no limit
EXCLUDE=""       # comma-separated: fork, archived, empty
OUTPUT_DIR="$SCRIPT_DIR/data/raw"

# Minimum requests that must remain before starting a new repo.
# collect_repo.sh makes ~10 calls per repo; keep a comfortable buffer.
MIN_REMAINING=50

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)    LIMIT="$2";      shift 2 ;;
    --exclude)  EXCLUDE="$2";    shift 2 ;;
    --output)   OUTPUT_DIR="$2"; shift 2 ;;
    -v|--verbose) export REPO_HEALTH_VERBOSE=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

VERBOSE="${REPO_HEALTH_VERBOSE:-0}"
log()  { [ "$VERBOSE" = "1" ] && echo "[collect_org] $*" >&2 || true; }
info() { echo "[collect_org] $*" >&2; }

# ─── Rate limit guard ─────────────────────────────────────────────────────────
# Call before each repo. If the core quota is below MIN_REMAINING, sleeps
# until the reset time (plus a 5-second buffer) and logs the wait.
wait_for_rate_limit() {
  local rate_json remaining reset_epoch now sleep_secs reset_human

  rate_json=$(gh api rate_limit 2>/dev/null) || {
    info "WARNING: Could not read rate limit - continuing anyway"
    return
  }

  remaining=$(echo "$rate_json" | jq '.resources.core.remaining')
  reset_epoch=$(echo "$rate_json" | jq '.resources.core.reset')
  now=$(date +%s)

  if [ "$remaining" -lt "$MIN_REMAINING" ]; then
    sleep_secs=$(( reset_epoch - now + 5 ))
    if [ "$sleep_secs" -le 0 ]; then
      sleep_secs=10
    fi
    reset_human=$(date -r "$reset_epoch" "+%H:%M:%S" 2>/dev/null \
      || date -d "@$reset_epoch" "+%H:%M:%S" 2>/dev/null \
      || echo "unknown")
    info "Rate limit low (${remaining} remaining). Sleeping ${sleep_secs}s until reset at ${reset_human}..."
    sleep "$sleep_secs"
    info "Resuming after rate limit wait."
  fi
}

# ─── Repo listing ─────────────────────────────────────────────────────────────
build_exclude_filter() {
  local filter='.[] | select(true)'
  IFS=',' read -ra PARTS <<< "$EXCLUDE"
  for part in "${PARTS[@]}"; do
    case "$part" in
      fork)     filter+=' | select(.fork == false)' ;;
      archived) filter+=' | select(.archived == false)' ;;
      empty)    filter+=' | select(.size > 0)' ;;
    esac
  done
  echo "$filter | .full_name"
}

JQ_FILTER=$(build_exclude_filter)

info "Listing repos for $ORG..."
# -X GET is required: gh api defaults to POST when -f flags are present.
REPOS=$(gh api -X GET "orgs/$ORG/repos" \
  --paginate \
  -f type=all \
  --jq "$JQ_FILTER" \
  2>/dev/null)

# Apply ignore list - patterns come from REPO_HEALTH_IGNORE env var (JSON array)
# set by run.sh per-target, or fall back to empty list.
REPOS=$(echo "$REPOS" | python3 -c "
import sys, fnmatch, os, json
raw = os.environ.get('REPO_HEALTH_IGNORE', '[]')
try:
    patterns = json.loads(raw)
except Exception:
    patterns = []
for line in sys.stdin:
    name = line.strip()
    if name and not any(fnmatch.fnmatch(name, p) for p in patterns):
        print(name)
")

TOTAL=$(echo "$REPOS" | grep -c . || true)
info "Found $TOTAL repos"

if [ "$LIMIT" -gt 0 ]; then
  REPOS=$(echo "$REPOS" | head -n "$LIMIT")
  log "Limited to $LIMIT repos"
fi

# ─── Collection loop ──────────────────────────────────────────────────────────
COLLECTED=()
FAILED=()
INDEX=0

while IFS= read -r FULL_NAME; do
  [[ -z "$FULL_NAME" ]] && continue
  INDEX=$((INDEX + 1))
  REPO_SLUG="${FULL_NAME//\//__}"
  OUT_FILE="$OUTPUT_DIR/${REPO_SLUG}.json"

  wait_for_rate_limit

  if "$SCRIPT_DIR/collect_repo.sh" "$FULL_NAME" 2>/dev/null > "$OUT_FILE"; then
    COLLECTED+=("$FULL_NAME")
    printf '  \033[32m✓\033[0m  [%d/%d]  %s\n' "$INDEX" "$TOTAL" "$FULL_NAME" >&2
  else
    FAILED+=("$FULL_NAME")
    printf '  \033[31m✗\033[0m  [%d/%d]  %s  (failed)\n' "$INDEX" "$TOTAL" "$FULL_NAME" >&2
    rm -f "$OUT_FILE"
  fi
done <<< "$REPOS"

# ─── Combine output ───────────────────────────────────────────────────────────
info "Done. Collected: ${#COLLECTED[@]}, Failed: ${#FAILED[@]}"

if [ "${#FAILED[@]}" -gt 0 ]; then
  info "Failed repos:"
  printf '  %s\n' "${FAILED[@]}" >&2
fi

if [ "${#COLLECTED[@]}" -eq 0 ]; then
  info "No repos collected - skipping combine."
  echo ""
  exit 0
fi

log "Combining into $OUTPUT_DIR/all.json"
COLLECTED_FILES=()
for name in "${COLLECTED[@]}"; do
  COLLECTED_FILES+=("$OUTPUT_DIR/${name//\//__}.json")
done
jq -s '.' "${COLLECTED_FILES[@]}" > "$OUTPUT_DIR/all.json"

echo "$OUTPUT_DIR/all.json"
