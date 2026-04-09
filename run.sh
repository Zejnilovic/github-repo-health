#!/usr/bin/env bash
# run.sh - Full pipeline: collect -> score -> report
#
# Targets mode (default when no --org/--repo given):
#   ./run.sh                              # run all targets from targets.yaml
#   ./run.sh --target "My Org"            # run a single named target
#   ./run.sh --targets custom.yaml        # use a different targets file
#
# Ad-hoc mode:
#   ./run.sh --org MY_ORG
#   ./run.sh --repo owner/repo [--category library]
#   ./run.sh --repo 'owner/prefix-*'
#   ./run.sh --score-only                 # re-score existing raw data
#
# Options:
#   --config FILE        Scoring config YAML (default: config.yaml)
#   --targets FILE       Targets file (default: targets.yaml)
#   --target NAME        Run only this named target (targets mode)
#   --org ORG            GitHub org (ad-hoc mode)
#   --repo OWNER/REPO    Single repo or glob pattern (ad-hoc mode)
#   --category CAT       Category for ad-hoc single/pattern mode
#   --limit N            Process only the first N repos
#   --exclude LIST       Comma-separated: fork,archived,empty
#   --format FORMAT      Print report to stdout: table|csv|markdown|json|html
#   --status STATUS      Filter output by status, e.g. dormant,at_risk
#   --output DIR         Base output directory (default: ./data)
#   --score-only         Skip collection, re-score from existing raw data
#   --no-summary         Suppress the summary block
#   -v, --verbose        Detailed collection/scoring progress

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="$SCRIPT_DIR/config.yaml"
TARGETS_FILE="$SCRIPT_DIR/targets.yaml"
TARGET_FILTER=""
ORG=""
REPO=""
CATEGORY="unknown"
LIMIT=0
EXCLUDE=""
FORMAT=""
STATUS_FILTER=""
OUTPUT_DIR="$SCRIPT_DIR/data"
SCORE_ONLY=false
NO_SUMMARY=""
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)     CONFIG_FILE="$2";     shift 2 ;;
    --targets)    TARGETS_FILE="$2";    shift 2 ;;
    --target)     TARGET_FILTER="$2";   shift 2 ;;
    --org)        ORG="$2";             shift 2 ;;
    --repo)       REPO="$2";            shift 2 ;;
    --category)   CATEGORY="$2";        shift 2 ;;
    --limit)      LIMIT="$2";           shift 2 ;;
    --exclude)    EXCLUDE="$2";         shift 2 ;;
    --format)     FORMAT="$2";          shift 2 ;;
    --status)     STATUS_FILTER="$2";   shift 2 ;;
    --output)     OUTPUT_DIR="$2";      shift 2 ;;
    --score-only) SCORE_ONLY=true;      shift   ;;
    --no-summary) NO_SUMMARY="--no-summary"; shift ;;
    -v|--verbose) VERBOSE=1;            shift   ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

export REPO_HEALTH_VERBOSE="$VERBOSE"

RAW_DIR="$OUTPUT_DIR/raw"
SCORED_DIR="$OUTPUT_DIR/scored"
mkdir -p "$RAW_DIR" "$SCORED_DIR"

log()  { [ "$VERBOSE" = "1" ] && echo "[run] $*" >&2 || true; }

# ─── Spinner ──────────────────────────────────────────────────────────────────

_SPIN_PID=""

spin_start() {
  local msg="$1"
  (
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    while true; do
      printf '\r  \033[36m%s\033[0m  %s' "${frames:$i:1}" "$msg" >&2 || true
      i=$(( (i + 1) % ${#frames} ))
      sleep 0.1
    done
  ) &
  _SPIN_PID=$!
}

spin_stop() {
  [ -z "$_SPIN_PID" ] && return
  kill "$_SPIN_PID" 2>/dev/null || true
  wait "$_SPIN_PID" 2>/dev/null || true
  printf '\r\033[K' >&2
  _SPIN_PID=""
}

trap 'spin_stop' EXIT INT TERM

# ─── Score + report helpers ───────────────────────────────────────────────────

# Score a raw JSON file into a scored JSON file.
# Usage: do_score <raw_input> <scored_output> [--categories FILE]
do_score() {
  local raw_input="$1" scored_output="$2"
  shift 2
  spin_start "Scoring..."
  python3 "$SCRIPT_DIR/score.py" "$raw_input" --config "$CONFIG_FILE" "$@" > "$scored_output"
  spin_stop
  local n
  n=$(jq 'length' "$scored_output")
  printf '  \033[32m✓\033[0m  Scored %d repos\n' "$n" >&2
}

# Render and save all report formats; print summary + optional stdout format.
do_report() {
  local scored_file="$1"
  spin_start "Saving reports..."
  python3 "$SCRIPT_DIR/report.py" "$scored_file" --format csv      > "$OUTPUT_DIR/report.csv"
  python3 "$SCRIPT_DIR/report.py" "$scored_file" --format markdown > "$OUTPUT_DIR/report.md"
  python3 "$SCRIPT_DIR/report.py" "$scored_file" --format html     > "$OUTPUT_DIR/report.html"
  spin_stop
  printf '  \033[32m✓\033[0m  Saved to %s/report.{html,md,csv}\n' "$OUTPUT_DIR" >&2

  python3 "$SCRIPT_DIR/report.py" "$scored_file" --format summary

  if [ -n "$FORMAT" ]; then
    local args=("$scored_file" --format "$FORMAT" --no-summary)
    [ -n "$STATUS_FILTER" ] && args+=(--status "$STATUS_FILTER")
    [ -n "$NO_SUMMARY"    ] && args+=("$NO_SUMMARY")
    python3 "$SCRIPT_DIR/report.py" "${args[@]}"
  fi
}

# ─── Collection phase ─────────────────────────────────────────────────────────

if [ "$SCORE_ONLY" = true ]; then
  log "Score-only mode: using existing raw data"
  RAW_INPUT="$RAW_DIR/all.json"
  if [ ! -f "$RAW_INPUT" ]; then
    log "No all.json found, combining from $RAW_DIR/*.json"
    jq -s '.' "$RAW_DIR"/*.json > "$RAW_INPUT"
  fi
  SCORED_FILE="$SCORED_DIR/all.json"
  do_score "$RAW_INPUT" "$SCORED_FILE"
  do_report "$SCORED_FILE"
  exit 0
fi

if [ -n "$ORG" ] || [ -n "$REPO" ]; then
  # ─── Ad-hoc mode ────────────────────────────────────────────────────────────

  if [ -n "$REPO" ] && [[ "$REPO" == *"*"* ]]; then
    # Glob pattern: owner/prefix-*
    PATTERN_ORG="${REPO%%/*}"
    NAME_PATTERN="${REPO#*/}"

    spin_start "Listing $PATTERN_ORG repos..."
    ALL_REPOS=$(gh api -X GET "orgs/$PATTERN_ORG/repos" \
      --paginate -f type=all --jq '.[].full_name' 2>/dev/null)
    spin_stop

    MATCHED_REPOS=()
    while IFS= read -r full_name; do
      repo_name="${full_name#*/}"
      [[ "$repo_name" == $NAME_PATTERN ]] && MATCHED_REPOS+=("$full_name")
    done <<< "$ALL_REPOS"

    if [ "${#MATCHED_REPOS[@]}" -eq 0 ]; then
      echo "Error: no repos matched '$REPO'" >&2; exit 1
    fi
    [ "$LIMIT" -gt 0 ] && MATCHED_REPOS=("${MATCHED_REPOS[@]:0:$LIMIT}")

    TOTAL_MATCH="${#MATCHED_REPOS[@]}"
    printf '  Found %d repos matching %s\n' "$TOTAL_MATCH" "$REPO" >&2

    COLLECTED_FILES=()
    INDEX=0
    for FULL_NAME in "${MATCHED_REPOS[@]}"; do
      INDEX=$(( INDEX + 1 ))
      OUT_FILE="$RAW_DIR/${FULL_NAME//\//__}.json"
      spin_start "[$INDEX/$TOTAL_MATCH]  $FULL_NAME"
      if "$SCRIPT_DIR/collect_repo.sh" "$FULL_NAME" "$CATEGORY" 2>/dev/null >"$OUT_FILE"; then
        spin_stop
        printf '  \033[32m✓\033[0m  [%d/%d]  %s\n' "$INDEX" "$TOTAL_MATCH" "$FULL_NAME" >&2
        COLLECTED_FILES+=("$OUT_FILE")
      else
        spin_stop
        printf '  \033[31m✗\033[0m  [%d/%d]  %s  (failed)\n' "$INDEX" "$TOTAL_MATCH" "$FULL_NAME" >&2
        rm -f "$OUT_FILE"
      fi
    done

    [ "${#COLLECTED_FILES[@]}" -eq 0 ] && { echo "Error: all repos failed" >&2; exit 1; }
    RAW_INPUT="$RAW_DIR/all.json"
    jq -s '.' "${COLLECTED_FILES[@]}" > "$RAW_INPUT"

  elif [ -n "$REPO" ]; then
    RAW_FILE="$RAW_DIR/${REPO//\//__}.json"
    spin_start "Collecting $REPO"
    if "$SCRIPT_DIR/collect_repo.sh" "$REPO" "$CATEGORY" 2>/dev/null >"$RAW_FILE"; then
      spin_stop
      printf '  \033[32m✓\033[0m  %s\n' "$REPO" >&2
    else
      spin_stop
      printf '  \033[31m✗\033[0m  Failed to collect %s\n' "$REPO" >&2; exit 1
    fi
    RAW_INPUT="$RAW_FILE"

  else
    # --org mode
    EXTRA_ARGS=()
    [ "$LIMIT" -gt 0 ] && EXTRA_ARGS+=(--limit "$LIMIT")
    [ -n "$EXCLUDE" ]  && EXTRA_ARGS+=(--exclude "$EXCLUDE")
    RAW_INPUT=$("$SCRIPT_DIR/collect_org.sh" "$ORG" "${EXTRA_ARGS[@]}" --output "$RAW_DIR")
  fi

  SCORED_FILE="$SCORED_DIR/all.json"
  do_score "$RAW_INPUT" "$SCORED_FILE"
  do_report "$SCORED_FILE"
  exit 0
fi

# ─── Targets mode ─────────────────────────────────────────────────────────────

if [ ! -f "$TARGETS_FILE" ]; then
  echo "Error: no --org/--repo given and targets file not found: $TARGETS_FILE" >&2
  echo "Create targets.yaml or use --org / --repo for an ad-hoc run." >&2
  exit 1
fi

# Emit one JSON line per target (optionally filtered by name)
_list_targets() {
  python3 - "$TARGETS_FILE" "$TARGET_FILTER" <<'PYEOF'
import yaml, json, sys
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
name_filter = sys.argv[2]
for t in data.get("targets", []):
    if not name_filter or t.get("name") == name_filter:
        print(json.dumps(t))
PYEOF
}

SCORED_FILES=()
TARGET_COUNT=0

while IFS= read -r target_json; do
  TARGET_COUNT=$(( TARGET_COUNT + 1 ))

  # Extract target fields via Python
  t_name=$(    python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('name','target-$TARGET_COUNT'))" "$target_json")
  t_org=$(     python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('org',''))"     "$target_json")
  t_exclude=$( python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('exclude',''))" "$target_json")
  t_ignore=$(  python3 -c "import json,sys; import json as j; d=json.loads(sys.argv[1]); print(j.dumps(d.get('ignore',[])))" "$target_json")

  # Build per-target directories
  t_slug=$(echo "$t_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//')
  t_raw_dir="$RAW_DIR/$t_slug"
  t_scored="$SCORED_DIR/${t_slug}.json"
  mkdir -p "$t_raw_dir"

  # Write per-target categories file alongside the raw data
  t_cats="$t_raw_dir/categories.yaml"
  python3 - "$target_json" "$t_cats" <<'PYEOF'
import json, sys
try:
    import yaml
except ImportError:
    sys.exit(0)
d = json.loads(sys.argv[1])
cats = d.get("categories", [])
with open(sys.argv[2], "w") as f:
    yaml.dump({"categories": cats}, f)
PYEOF

  printf '\n  \033[1m%s\033[0m\n' "$t_name" >&2

  # Collect: org or repos list
  if [ -n "$t_org" ]; then
    EXTRA_ARGS=(--output "$t_raw_dir")
    [ "$LIMIT" -gt 0 ]    && EXTRA_ARGS+=(--limit "$LIMIT")
    [ -n "$t_exclude" ]   && EXTRA_ARGS+=(--exclude "$t_exclude")
    t_raw_input=$(REPO_HEALTH_IGNORE="$t_ignore" \
      "$SCRIPT_DIR/collect_org.sh" "$t_org" "${EXTRA_ARGS[@]}")
  else
    # repos list
    t_repos=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
for r in d.get('repos', []):
    print(r)
" "$target_json")

    COLLECTED_FILES=()
    INDEX=0
    TOTAL_REPOS=$(echo "$t_repos" | grep -c . || true)

    while IFS= read -r full_name; do
      [ -z "$full_name" ] && continue
      INDEX=$(( INDEX + 1 ))
      OUT_FILE="$t_raw_dir/${full_name//\//__}.json"

      # Resolve category from target's categories list
      repo_cat=$(python3 -c "
import json, fnmatch, sys
d     = json.loads(sys.argv[1])
name  = sys.argv[2]
for entry in d.get('categories', []):
    if fnmatch.fnmatch(name, entry.get('match', '')):
        print(entry.get('category', 'unknown'))
        sys.exit(0)
print('unknown')
" "$target_json" "$full_name")

      spin_start "[$INDEX/$TOTAL_REPOS]  $full_name"
      if "$SCRIPT_DIR/collect_repo.sh" "$full_name" "$repo_cat" 2>/dev/null >"$OUT_FILE"; then
        spin_stop
        printf '  \033[32m✓\033[0m  [%d/%d]  %s\n' "$INDEX" "$TOTAL_REPOS" "$full_name" >&2
        COLLECTED_FILES+=("$OUT_FILE")
      else
        spin_stop
        printf '  \033[31m✗\033[0m  [%d/%d]  %s  (failed)\n' "$INDEX" "$TOTAL_REPOS" "$full_name" >&2
        rm -f "$OUT_FILE"
      fi
    done <<< "$t_repos"

    [ "${#COLLECTED_FILES[@]}" -eq 0 ] && { echo "  No repos collected for target '$t_name'" >&2; rm -f "$t_cats"; continue; }
    t_raw_input="$t_raw_dir/all.json"
    jq -s '.' "${COLLECTED_FILES[@]}" > "$t_raw_input"
  fi

  # Skip if collection produced nothing
  if [ -z "$t_raw_input" ] || [ ! -f "$t_raw_input" ]; then
    printf '  \033[33m-\033[0m  No repos collected for target "%s" - skipping\n' "$t_name" >&2
    rm -f "$t_cats"
    continue
  fi

  # Score this target (with its own categories and shared config)
  CATS_ARG=""
  [ -s "$t_cats" ] && CATS_ARG="--categories $t_cats"
  # shellcheck disable=SC2086
  do_score "$t_raw_input" "$t_scored" $CATS_ARG
  SCORED_FILES+=("$t_scored")

  rm -f "$t_cats"

done < <(_list_targets)

if [ "${#SCORED_FILES[@]}" -eq 0 ]; then
  echo "Error: no targets produced data." >&2; exit 1
fi

# Merge all scored files into one
COMBINED="$SCORED_DIR/all.json"
if [ "${#SCORED_FILES[@]}" -eq 1 ]; then
  cp "${SCORED_FILES[0]}" "$COMBINED"
else
  jq -s '[.[][]]' "${SCORED_FILES[@]}" > "$COMBINED"
fi

do_report "$COMBINED"
