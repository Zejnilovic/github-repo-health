#!/usr/bin/env bash
# collect_repo.sh - Collect raw health metrics for a single GitHub repo.
#
# Usage:
#   ./collect_repo.sh OWNER/REPO [CATEGORY]
#
# Output: JSON to stdout with all raw indicators needed by score.py
#
# Requirements: gh (authenticated), jq
# Note: Traffic endpoints (clones/views) require push access to the repo.
#
# IMPORTANT: gh api defaults to POST when -f flags are present.
#            Always pass -X GET for read-only list endpoints.

set -euo pipefail

REPO="${1:?Usage: collect_repo.sh OWNER/REPO [CATEGORY]}"
CATEGORY="${2:-unknown}"

NOW=$(date +%s)

# ─── Date helpers ────────────────────────────────────────────────────────────
days_ago() {
  if date --version >/dev/null 2>&1; then
    date -u -d "$1 days ago" +"%Y-%m-%dT%H:%M:%SZ"
  else
    date -u -v-"$1"d +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

date_to_epoch() {
  local d="$1"
  if date --version >/dev/null 2>&1; then
    date -u -d "$d" +%s
  else
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$d" +%s 2>/dev/null \
      || date -u -j -f "%Y-%m-%dT%H:%M:%S%z" "$d" +%s
  fi
}

SINCE_14D=$(days_ago 14)
SINCE_30D=$(days_ago 30)
SINCE_90D=$(days_ago 90)
SINCE_180D=$(days_ago 180)

VERBOSE="${REPO_HEALTH_VERBOSE:-0}"
log() { [ "$VERBOSE" = "1" ] && echo "[collect] $*" >&2 || true; }

# Return only the first integer on the first line of stdin - guards against
# jq error text, empty strings, or multi-line output leaking into --argjson.
safe_int() {
  local v="${1:-0}"
  echo "$v" | head -1 | grep -Eo '[0-9]+' | head -1 || echo "0"
}

# ─── Repo metadata ────────────────────────────────────────────────────────────
log "Fetching repo metadata for $REPO"
REPO_META=$(gh api "repos/$REPO" --jq '{
  name: .name,
  full_name: .full_name,
  description: .description,
  is_archived: .archived,
  is_fork: .fork,
  default_branch: .default_branch,
  created_at: .created_at,
  pushed_at: .pushed_at,
  language: .language,
  stargazers_count: .stargazers_count,
  forks_count: .forks_count,
  open_issues_count: .open_issues_count
}')

PUSHED_AT=$(echo "$REPO_META" | jq -r '.pushed_at')
PUSHED_EPOCH=$(date_to_epoch "$PUSHED_AT")
DAYS_SINCE_PUSH=$(( (NOW - PUSHED_EPOCH) / 86400 ))

DEFAULT_BRANCH=$(echo "$REPO_META" | jq -r '.default_branch')

# ─── Commits ─────────────────────────────────────────────────────────────────
# Cap at 100 - the highest scoring bracket is 50, so this is always sufficient.
# -X GET is required: gh api defaults to POST when -f flags are present.
log "Fetching commit counts"

count_commits_since() {
  local since="$1"
  local raw
  raw=$(gh api -X GET "repos/$REPO/commits" \
    -f since="$since" \
    -f sha="$DEFAULT_BRANCH" \
    -f per_page=100 \
    --jq 'length' \
    2>/dev/null) || true
  safe_int "${raw:-0}"
}

COMMITS_30D=$(count_commits_since "$SINCE_30D")
COMMITS_90D=$(count_commits_since "$SINCE_90D")
COMMITS_180D=$(count_commits_since "$SINCE_180D")

# ─── Contributor concentration ───────────────────────────────────────────────
# 100 most recent commits in the 180d window - sufficient for concentration ratios.
log "Fetching contributor data (180d)"

CONTRIBUTOR_JSON=$(gh api -X GET "repos/$REPO/commits" \
  -f since="$SINCE_180D" \
  -f sha="$DEFAULT_BRANCH" \
  -f per_page=100 \
  --jq '[.[] | .author.login // .commit.author.email]
        | group_by(.)
        | map({login: .[0], count: length})
        | sort_by(-.count)' \
  2>/dev/null || echo "[]")

CONTRIBUTORS_180D=$(safe_int "$(echo "$CONTRIBUTOR_JSON" | jq 'length' 2>/dev/null || echo 0)")
TOTAL_COMMITS_180D=$(safe_int "$(echo "$CONTRIBUTOR_JSON" | jq '[.[].count] | add // 0' 2>/dev/null || echo 0)")
TOP1_COMMITS=$(safe_int "$(echo "$CONTRIBUTOR_JSON" | jq '.[0].count // 0' 2>/dev/null || echo 0)")
TOP2_COMMITS=$(safe_int "$(echo "$CONTRIBUTOR_JSON" | jq '(.[0].count // 0) + (.[1].count // 0)' 2>/dev/null || echo 0)")

if [ "$TOTAL_COMMITS_180D" -gt 0 ]; then
  TOP1_SHARE=$(echo "scale=3; $TOP1_COMMITS / $TOTAL_COMMITS_180D" | bc 2>/dev/null || echo "1.000")
  TOP2_SHARE=$(echo "scale=3; $TOP2_COMMITS / $TOTAL_COMMITS_180D" | bc 2>/dev/null || echo "1.000")
else
  TOP1_SHARE="1.000"
  TOP2_SHARE="1.000"
fi

CONTRIBUTORS_90D=$(safe_int "$(gh api -X GET "repos/$REPO/commits" \
  -f since="$SINCE_90D" \
  -f sha="$DEFAULT_BRANCH" \
  -f per_page=100 \
  --jq '[.[] | .author.login // .commit.author.email] | unique | length' \
  2>/dev/null || echo 0)")

# ─── Pull requests ────────────────────────────────────────────────────────────
# 100 results covers the highest bracket (>=20).
log "Fetching PR counts (90d)"

PRS_OPENED_90D=$(safe_int "$(gh api -X GET "repos/$REPO/pulls" \
  -f state=all \
  -f base="$DEFAULT_BRANCH" \
  -f per_page=100 \
  --jq "[.[] | select(.created_at >= \"$SINCE_90D\")] | length" \
  2>/dev/null || echo 0)")

PRS_MERGED_90D=$(safe_int "$(gh api -X GET "repos/$REPO/pulls" \
  -f state=closed \
  -f base="$DEFAULT_BRANCH" \
  -f per_page=100 \
  --jq "[.[] | select(.merged_at != null and .merged_at >= \"$SINCE_90D\")] | length" \
  2>/dev/null || echo 0)")

# ─── Issues ──────────────────────────────────────────────────────────────────
log "Fetching issue counts (90d)"

ISSUES_OPENED_90D=$(safe_int "$(gh api -X GET "repos/$REPO/issues" \
  -f state=all \
  -f since="$SINCE_90D" \
  -f per_page=100 \
  --jq '[.[] | select(.pull_request == null)] | length' \
  2>/dev/null || echo 0)")

ISSUES_CLOSED_90D=$(safe_int "$(gh api -X GET "repos/$REPO/issues" \
  -f state=closed \
  -f since="$SINCE_90D" \
  -f per_page=100 \
  --jq '[.[] | select(.pull_request == null and .closed_at != null and .closed_at >= "'"$SINCE_90D"'")] | length' \
  2>/dev/null || echo 0)")

# ─── Releases ─────────────────────────────────────────────────────────────────
log "Fetching latest release"

LATEST_RELEASE=$(gh api "repos/$REPO/releases/latest" 2>/dev/null || echo "{}")
RELEASE_DATE=$(echo "$LATEST_RELEASE" | jq -r '.published_at // empty')

if [ -n "$RELEASE_DATE" ]; then
  RELEASE_EPOCH=$(date_to_epoch "$RELEASE_DATE")
  DAYS_SINCE_RELEASE=$(( (NOW - RELEASE_EPOCH) / 86400 ))
else
  DAYS_SINCE_RELEASE=-1  # -1 means no release ever
fi

# ─── Traffic (requires push access) ──────────────────────────────────────────
log "Fetching traffic data (14d)"

CLONES_JSON=$(gh api "repos/$REPO/traffic/clones" 2>/dev/null || echo '{"count":0,"uniques":0}')
VIEWS_JSON=$(gh api  "repos/$REPO/traffic/views"  2>/dev/null || echo '{"count":0,"uniques":0}')

CLONES_14D=$(safe_int "$(echo "$CLONES_JSON" | jq '.count   // 0' 2>/dev/null || echo 0)")
UNIQUE_CLONES_14D=$(safe_int "$(echo "$CLONES_JSON" | jq '.uniques // 0' 2>/dev/null || echo 0)")
VIEWS_14D=$(safe_int "$(echo "$VIEWS_JSON"  | jq '.count   // 0' 2>/dev/null || echo 0)")
UNIQUE_VIEWS_14D=$(safe_int "$(echo "$VIEWS_JSON"  | jq '.uniques // 0' 2>/dev/null || echo 0)")

# ─── Workflow runs (optional, best-effort) ────────────────────────────────────
log "Fetching recent workflow runs"

RECENT_SUCCESSFUL_RUNS=$(safe_int "$(gh api -X GET "repos/$REPO/actions/runs" \
  -f status=success \
  -f per_page=10 \
  --jq '.workflow_runs | length' \
  2>/dev/null || echo 0)")

# ─── Stale PRs ────────────────────────────────────────────────────────────────
# Open PRs created AND last updated more than 30 days ago - sitting unattended.
log "Fetching stale PRs"

STALE_PRS_30D=$(safe_int "$(gh api -X GET "repos/$REPO/pulls" \
  -f state=open \
  -f base="$DEFAULT_BRANCH" \
  -f per_page=100 \
  --jq "[.[] | select(.created_at < \"$SINCE_30D\" and .updated_at < \"$SINCE_30D\")] | length" \
  2>/dev/null || echo 0)")

# ─── Hygiene markers ──────────────────────────────────────────────────────────
# Community profile gives README, LICENSE, and CONTRIBUTING in one call.
log "Fetching hygiene markers"

_COMMUNITY=$(gh api "repos/$REPO/community/profile" 2>/dev/null || echo '{"files":{}}')
HAS_README=$(echo "$_COMMUNITY"      | jq '.files.readme      != null' 2>/dev/null || echo "false")
HAS_LICENSE=$(echo "$_COMMUNITY"     | jq '.files.license     != null' 2>/dev/null || echo "false")
HAS_CONTRIBUTING=$(echo "$_COMMUNITY" | jq '.files.contributing != null' 2>/dev/null || echo "false")

# Branch protection: 404 = not protected
if gh api "repos/$REPO/branches/$DEFAULT_BRANCH/protection" >/dev/null 2>&1; then
  BRANCH_PROTECTED="true"
else
  BRANCH_PROTECTED="false"
fi

# CODEOWNERS: check root and .github/ (two most common locations)
HAS_CODEOWNERS="false"
for _co_path in "CODEOWNERS" ".github/CODEOWNERS"; do
  if gh api "repos/$REPO/contents/$_co_path" >/dev/null 2>&1; then
    HAS_CODEOWNERS="true"
    break
  fi
done

# ─── Assemble output ──────────────────────────────────────────────────────────
COLLECTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --argjson meta            "$REPO_META" \
  --arg     category        "$CATEGORY" \
  --arg     collected_at    "$COLLECTED_AT" \
  --argjson days_since_push "$DAYS_SINCE_PUSH" \
  --argjson commits_30d     "$COMMITS_30D" \
  --argjson commits_90d     "$COMMITS_90D" \
  --argjson commits_180d    "$COMMITS_180D" \
  --argjson contributors_90d  "$CONTRIBUTORS_90D" \
  --argjson contributors_180d "$CONTRIBUTORS_180D" \
  --arg     top1_commit_share_180d "$TOP1_SHARE" \
  --arg     top2_commit_share_180d "$TOP2_SHARE" \
  --argjson prs_opened_90d  "$PRS_OPENED_90D" \
  --argjson prs_merged_90d  "$PRS_MERGED_90D" \
  --argjson issues_opened_90d "$ISSUES_OPENED_90D" \
  --argjson issues_closed_90d "$ISSUES_CLOSED_90D" \
  --argjson days_since_last_release "$DAYS_SINCE_RELEASE" \
  --argjson clones_14d         "$CLONES_14D" \
  --argjson unique_clones_14d  "$UNIQUE_CLONES_14D" \
  --argjson views_14d          "$VIEWS_14D" \
  --argjson unique_views_14d   "$UNIQUE_VIEWS_14D" \
  --argjson recent_successful_runs "$RECENT_SUCCESSFUL_RUNS" \
  --argjson stale_prs_30d          "$STALE_PRS_30D" \
  --argjson has_readme             "$HAS_README" \
  --argjson has_license            "$HAS_LICENSE" \
  --argjson has_contributing       "$HAS_CONTRIBUTING" \
  --argjson branch_protected       "$BRANCH_PROTECTED" \
  --argjson has_codeowners         "$HAS_CODEOWNERS" \
  '{
    meta: ($meta + {category: $category, collected_at: $collected_at}),
    raw: {
      days_since_last_push:    $days_since_push,
      commits_30d:             $commits_30d,
      commits_90d:             $commits_90d,
      commits_180d:            $commits_180d,
      contributors_90d:        $contributors_90d,
      contributors_180d:       $contributors_180d,
      top1_commit_share_180d:  ($top1_commit_share_180d | tonumber),
      top2_commit_share_180d:  ($top2_commit_share_180d | tonumber),
      prs_opened_90d:          $prs_opened_90d,
      prs_merged_90d:          $prs_merged_90d,
      issues_opened_90d:       $issues_opened_90d,
      issues_closed_90d:       $issues_closed_90d,
      days_since_last_release: $days_since_last_release,
      clones_14d:              $clones_14d,
      unique_clones_14d:       $unique_clones_14d,
      views_14d:               $views_14d,
      unique_views_14d:        $unique_views_14d,
      recent_successful_runs:  $recent_successful_runs,
      stale_prs_30d:           $stale_prs_30d,
      has_readme:              $has_readme,
      has_license:             $has_license,
      has_contributing:        $has_contributing,
      branch_protected:        $branch_protected,
      has_codeowners:          $has_codeowners
    }
  }'
