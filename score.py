#!/usr/bin/env python3
"""
score.py - Compute health scores for one or more repos from raw collected JSON.

Usage:
    python3 score.py data/raw/myorg__myrepo.json
    python3 score.py data/raw/all.json
    ./collect_repo.sh myorg/myrepo | python3 score.py -

Output: JSON to stdout (list of scored repo objects)
"""

from __future__ import annotations

import fnmatch
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent


# ─── Config loading ───────────────────────────────────────────────────────────

def _load_yaml(path: Path) -> dict:
    try:
        import yaml  # type: ignore
        with open(path) as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
    except ImportError:
        print(
            f"Warning: PyYAML not installed - {path.name} not loaded. "
            "Install with: pip install pyyaml",
            file=sys.stderr,
        )
        return {}


_DEFAULT_CAT_MODIFIERS = {
    "product": 0, "library": 5, "infrastructure": 5,
    "documentation": 10, "template": 10, "experiment": 10, "unknown": 0,
}

# Globals - populated by _init_config() at startup and optionally overridden
# by --config / --categories CLI args before any scoring runs.
CONFIG:             dict       = {}
CATEGORIES:         list[dict] = []
CATEGORY_MODIFIERS: dict       = dict(_DEFAULT_CAT_MODIFIERS)
_ACTIVE_MIN_HEALTH   = 70
_ACTIVE_MIN_ACTIVITY = 20
_STABLE_MIN_HEALTH   = 55
_ABANDONED_MIN_PUSH  = 180
_ABANDONED_MAX_HEALTH = 25
_DORMANT_MIN_PUSH    = 90
_DORMANT_MAX_HEALTH  = 40
_STALE_TIERS: list[dict] = [
    {"count": 6, "penalty": 6},
    {"count": 3, "penalty": 4},
    {"count": 1, "penalty": 2},
]


def _init_config(config_path: Path | None = None, categories_path: Path | None = None) -> None:
    """Load (or reload) config and categories into module globals."""
    global CONFIG, CATEGORIES, CATEGORY_MODIFIERS
    global _ACTIVE_MIN_HEALTH, _ACTIVE_MIN_ACTIVITY, _STABLE_MIN_HEALTH
    global _ABANDONED_MIN_PUSH, _ABANDONED_MAX_HEALTH, _DORMANT_MIN_PUSH, _DORMANT_MAX_HEALTH
    global _STALE_TIERS

    CONFIG = _load_yaml(config_path or SCRIPT_DIR / "config.yaml")

    cats_data = _load_yaml(categories_path) if categories_path else {}
    CATEGORIES = cats_data.get("categories", [])

    CATEGORY_MODIFIERS = {**_DEFAULT_CAT_MODIFIERS, **CONFIG.get("category_modifiers", {})}

    _ST = CONFIG.get("status_thresholds", {})
    _ACTIVE_MIN_HEALTH   = _ST.get("active",    {}).get("min_health_score",    70)
    _ACTIVE_MIN_ACTIVITY = _ST.get("active",    {}).get("min_activity_score",  20)
    _STABLE_MIN_HEALTH   = _ST.get("stable",    {}).get("min_health_score",    55)
    _ABANDONED_MIN_PUSH  = _ST.get("abandoned", {}).get("min_days_since_push", 180)
    _ABANDONED_MAX_HEALTH= _ST.get("abandoned", {}).get("max_health_score",    25)
    _DORMANT_MIN_PUSH    = _ST.get("dormant",   {}).get("min_days_since_push", 90)
    _DORMANT_MAX_HEALTH  = _ST.get("dormant",   {}).get("max_health_score",    40)

    _STALE_TIERS = CONFIG.get("scoring", {}).get("stale_pr_thresholds", [
        {"count": 6, "penalty": 6},
        {"count": 3, "penalty": 4},
        {"count": 1, "penalty": 2},
    ])


# Load defaults at import time so the module works standalone.
_init_config()


# ─── Category resolution ──────────────────────────────────────────────────────

def resolve_category(full_name: str, declared: str) -> str:
    """
    Return category from the categories list (from --categories file) if it
    matches, else use the declared category from collected meta.
    """
    for entry in CATEGORIES:
        if fnmatch.fnmatch(full_name, entry.get("match", "")):
            return entry.get("category", "unknown")
    return declared or "unknown"



# ─── Scoring helpers ──────────────────────────────────────────────────────────

def bracket(value: float, tiers: list[tuple[float, int]]) -> int:
    for threshold, score in tiers:
        if value >= threshold:
            return score
    return 0


# ─── Activity score (0-35) ────────────────────────────────────────────────────

def score_activity(raw: dict) -> tuple[int, dict]:
    days = raw.get("days_since_last_push", 9999)
    commits_90d          = raw.get("commits_90d", 0)
    prs_merged_90d       = raw.get("prs_merged_90d", 0)
    issues_activity_90d  = raw.get("issues_opened_90d", 0) + raw.get("issues_closed_90d", 0)

    if days <= 14:   push_score = 12
    elif days <= 30: push_score = 10
    elif days <= 90: push_score = 6
    elif days <= 180:push_score = 2
    else:            push_score = 0

    commit_score = bracket(commits_90d,         [(50, 10), (20, 8), (5, 5), (1, 2)])
    pr_score     = bracket(prs_merged_90d,      [(20,  8), (5,  6), (1, 3)])
    issue_score  = bracket(issues_activity_90d, [(20,  5), (5,  3), (1, 1)])

    total = push_score + commit_score + pr_score + issue_score
    return total, {"push_age": push_score, "commits": commit_score,
                   "prs": pr_score, "issues": issue_score}


# ─── Maintenance score (0-25) ─────────────────────────────────────────────────

def score_maintenance(raw: dict) -> tuple[int, dict]:
    opened   = raw.get("prs_opened_90d", 0)
    merged   = raw.get("prs_merged_90d", 0)
    i_opened = raw.get("issues_opened_90d", 0)
    i_closed = raw.get("issues_closed_90d", 0)
    days_since_release = raw.get("days_since_last_release", -1)
    runs       = raw.get("recent_successful_runs", 0)
    stale_prs  = raw.get("stale_prs_30d", 0)

    pr_ratio    = merged / max(opened, 1)
    issue_ratio = i_closed / max(i_opened, 1)

    pr_ratio_score    = bracket(pr_ratio,    [(0.8, 8), (0.5, 5), (0.001, 2)])
    issue_ratio_score = bracket(issue_ratio, [(0.8, 6), (0.5, 4), (0.001, 2)])

    if days_since_release == -1:  release_score = 0
    elif days_since_release <= 90:  release_score = 6
    elif days_since_release <= 180: release_score = 4
    elif days_since_release <= 365: release_score = 2
    else:                           release_score = 0

    workflow_score = min(5, runs // 2)

    # Stale PR penalty: open PRs sitting unattended > 30 days
    stale_penalty = 0
    for tier in sorted(_STALE_TIERS, key=lambda t: t["count"], reverse=True):
        if stale_prs >= tier["count"]:
            stale_penalty = tier["penalty"]
            break

    raw_total = pr_ratio_score + issue_ratio_score + release_score + workflow_score
    total = max(0, min(25, raw_total - stale_penalty))

    breakdown = {
        "pr_merge_ratio":    pr_ratio_score,
        "issue_close_ratio": issue_ratio_score,
        "release_age":       release_score,
        "workflow_runs":     workflow_score,
        "stale_pr_penalty":  -stale_penalty if stale_penalty else 0,
    }
    return total, breakdown


# ─── Adoption score (0-10) ────────────────────────────────────────────────────

def score_adoption(raw: dict) -> tuple[int, dict]:
    unique_clones = raw.get("unique_clones_14d", 0)
    unique_views  = raw.get("unique_views_14d", 0)

    clone_score     = bracket(unique_clones, [(20, 4), (5, 2), (1, 1)])
    view_score      = bracket(unique_views,  [(50, 4), (10, 2), (1, 1)])
    diversity_bonus = 2 if unique_clones > 0 and unique_views > 0 else 0

    total = min(10, clone_score + view_score + diversity_bonus)
    return total, {"unique_clones": clone_score, "unique_views": view_score,
                   "diversity": diversity_bonus}


# ─── Resilience score (0-20) ──────────────────────────────────────────────────

def score_resilience(raw: dict) -> tuple[int, dict]:
    contributors_180d = raw.get("contributors_180d", 0)
    top1_share = raw.get("top1_commit_share_180d", 1.0)
    top2_share = raw.get("top2_commit_share_180d", 1.0)

    contributor_score = bracket(contributors_180d, [(6, 8), (3, 5), (2, 3)])
    top1_score = bracket(1 - top1_share, [(0.60, 6), (0.40, 4), (0.20, 2)])
    top2_score = bracket(1 - top2_share, [(0.30, 6), (0.10, 3)])

    total = contributor_score + top1_score + top2_score
    return total, {"contributor_count": contributor_score,
                   "top1_concentration": top1_score, "top2_concentration": top2_score}


# ─── Hygiene score (0-10) ─────────────────────────────────────────────────────

def score_hygiene(raw: dict) -> tuple[int, dict]:
    """
    Measures intentional ownership signals: docs, licensing, and access control.
      README       +2   Is there basic documentation?
      LICENSE      +2   Is the legal status clear?
      CONTRIBUTING +1   Do contributors know how to help?
      Branch prot. +3   Is the default branch protected from direct pushes?
      CODEOWNERS   +2   Are owners explicitly declared?
    """
    readme       = raw.get("has_readme",       False)
    license_     = raw.get("has_license",      False)
    contributing = raw.get("has_contributing", False)
    protected    = raw.get("branch_protected", False)
    codeowners   = raw.get("has_codeowners",   False)

    readme_score       = 2 if readme       else 0
    license_score      = 2 if license_     else 0
    contributing_score = 1 if contributing else 0
    protection_score   = 3 if protected    else 0
    codeowners_score   = 2 if codeowners   else 0

    total = readme_score + license_score + contributing_score + protection_score + codeowners_score
    return total, {
        "readme":            readme_score,
        "license":           license_score,
        "contributing":      contributing_score,
        "branch_protection": protection_score,
        "codeowners":        codeowners_score,
    }


# ─── Lifecycle modifier (-20 to +10) ─────────────────────────────────────────

def score_lifecycle(raw: dict, meta: dict) -> tuple[int, dict]:
    category           = meta.get("category", "unknown")
    is_archived        = meta.get("is_archived", False)
    days_since_push    = raw.get("days_since_last_push", 9999)
    days_since_release = raw.get("days_since_last_release", -1)

    notes    = []
    modifier = CATEGORY_MODIFIERS.get(category, 0)

    if is_archived:
        return 0, {"modifier": 0, "notes": ["archived"]}

    if days_since_push > 90 and days_since_release != -1 and days_since_release <= 90:
        modifier += 5
        notes.append("recent_release_despite_quiet")

    if days_since_push > 180 and (days_since_release == -1 or days_since_release > 365):
        modifier -= 10
        notes.append("no_activity_no_release_365d")

    modifier = max(-20, min(10, modifier))
    return modifier, {"modifier": modifier, "notes": notes}


# ─── Status labelling ─────────────────────────────────────────────────────────

def compute_status(
    health_score: int,
    activity_score: int,
    maintenance_score: int,
    resilience_score: int,
    is_archived: bool,
    days_since_push: int,
) -> str:
    if is_archived:
        return "archived"
    if health_score >= _ACTIVE_MIN_HEALTH and activity_score >= _ACTIVE_MIN_ACTIVITY:
        return "active"
    if days_since_push > _ABANDONED_MIN_PUSH and health_score < _ABANDONED_MAX_HEALTH:
        return "likely_abandoned"
    if days_since_push > _DORMANT_MIN_PUSH and health_score < _DORMANT_MAX_HEALTH:
        return "dormant"
    if health_score >= _STABLE_MIN_HEALTH:
        if resilience_score < 8:
            return "at_risk"
        return "stable"
    if resilience_score < 8 or maintenance_score < 10:
        return "at_risk"
    if health_score < _DORMANT_MAX_HEALTH:
        return "dormant"
    return "stable"


# ─── Main scoring function ────────────────────────────────────────────────────

def score_repo(repo: dict) -> dict:
    raw  = repo.get("raw", {})
    meta = repo.get("meta", {})

    full_name   = meta.get("full_name", meta.get("name", "unknown"))
    declared_cat = meta.get("category", "unknown")
    category    = resolve_category(full_name, declared_cat)
    # Write resolved category back so downstream (report, lifecycle) sees it
    meta = {**meta, "category": category}

    is_archived     = meta.get("is_archived", False)
    days_since_push = raw.get("days_since_last_push", 9999)

    activity_score,    activity_bd    = score_activity(raw)
    maintenance_score, maintenance_bd = score_maintenance(raw)
    adoption_score,    adoption_bd    = score_adoption(raw)
    resilience_score,  resilience_bd  = score_resilience(raw)
    hygiene_score,     hygiene_bd     = score_hygiene(raw)
    lifecycle_modifier, lifecycle_bd  = score_lifecycle(raw, meta)

    if is_archived:
        health_score = 0
    else:
        health_score = max(0, min(100,
            activity_score + maintenance_score + adoption_score
            + resilience_score + hygiene_score + lifecycle_modifier
        ))

    status = compute_status(
        health_score, activity_score, maintenance_score,
        resilience_score, is_archived, days_since_push,
    )

    return {
        "repo":         full_name,
        "category":     category,
        "collected_at": meta.get("collected_at"),
        "is_archived":  is_archived,
        "status":       status,
        "health_score": health_score,
        "scores": {
            "activity":           activity_score,
            "maintenance":        maintenance_score,
            "adoption":           adoption_score,
            "resilience":         resilience_score,
            "hygiene":            hygiene_score,
            "lifecycle_modifier": lifecycle_modifier,
        },
        "breakdown": {
            "activity":    activity_bd,
            "maintenance": maintenance_bd,
            "adoption":    adoption_bd,
            "resilience":  resilience_bd,
            "hygiene":     hygiene_bd,
            "lifecycle":   lifecycle_bd,
        },
        "raw":  raw,
        "meta": meta,
    }


# ─── Entry point ─────────────────────────────────────────────────────────────

def load_input(path: str) -> list[dict]:
    if path == "-":
        data = json.load(sys.stdin)
    else:
        with open(path) as f:
            data = json.load(f)

    if isinstance(data, dict):
        if "raw" in data or "meta" in data:
            return [data]
        return list(data.values())
    return data


def main():
    import argparse
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("input", help="Raw JSON file or - for stdin")
    p.add_argument("--config",     metavar="FILE", help="Scoring config YAML (default: config.yaml)")
    p.add_argument("--categories", metavar="FILE", help="Category mapping YAML")
    args = p.parse_args()

    # Re-init globals if custom paths were provided
    if args.config or args.categories:
        _init_config(
            config_path     = Path(args.config)     if args.config     else None,
            categories_path = Path(args.categories) if args.categories else None,
        )

    repos = load_input(args.input)

    results = [score_repo(r) for r in repos]
    results.sort(key=lambda r: r["health_score"], reverse=True)

    json.dump(results, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
