#!/usr/bin/env python3
"""
report.py - Format scored repo health data for human consumption.

Usage:
    python3 report.py data/scored/all.json [--format table|csv|markdown|json|html]
    python3 report.py data/scored/all.json --format table --status dormant,at_risk
    python3 report.py data/scored/all.json --format table --sort health_score
    python3 report.py data/scored/all.json --format html > dashboard.html
    cat scored.json | python3 report.py - --format markdown

Formats:
    table    - coloured terminal table (default)
    csv      - CSV for spreadsheets
    markdown - Markdown table for GitHub/Notion
    html     - self-contained sortable/filterable dashboard
    json     - re-emit the scored JSON (useful for piping)
"""

from __future__ import annotations

import csv
import json
import sys
import io
import argparse
from typing import Optional
from pathlib import Path

# ─── ANSI colours (disabled when not a TTY) ──────────────────────────────────

USE_COLOUR = sys.stdout.isatty()

COLOURS = {
    "reset":   "\033[0m",
    "bold":    "\033[1m",
    "red":     "\033[91m",
    "yellow":  "\033[93m",
    "green":   "\033[92m",
    "cyan":    "\033[96m",
    "blue":    "\033[94m",
    "magenta": "\033[95m",
    "grey":    "\033[90m",
    "white":   "\033[97m",
}

STATUS_COLOURS = {
    "active":           "green",
    "stable":           "cyan",
    "at_risk":          "yellow",
    "dormant":          "magenta",
    "likely_abandoned": "red",
    "archived":         "grey",
}

STATUS_ICONS = {
    "active":           "[+]",
    "stable":           "[~]",
    "at_risk":          "[!]",
    "dormant":          "[z]",
    "likely_abandoned": "[x]",
    "archived":         "[-]",
}

def c(text: str, colour: str) -> str:
    if not USE_COLOUR:
        return text
    return COLOURS.get(colour, "") + text + COLOURS["reset"]

def status_str(status: str) -> str:
    icon = STATUS_ICONS.get(status, "[ ]")
    col  = STATUS_COLOURS.get(status, "white")
    label = status.replace("_", " ")
    return c(f"{icon} {label:<16}", col)


# ─── Column definitions ───────────────────────────────────────────────────────

COLUMNS = [
    ("Repo",          "repo",         40, "l"),
    ("Category",      "category",     12, "l"),
    ("Status",        "status",       22, "l"),
    ("Health",        "health_score",  6, "r"),
    ("Activity",      "activity",      8, "r"),
    ("Maintenance",   "maintenance",  11, "r"),
    ("Adoption",      "adoption",      8, "r"),
    ("Resilience",    "resilience",   10, "r"),
    ("Hygiene",       "hygiene",       7, "r"),
    ("Lifecycle",     "lifecycle",     8, "r"),
    ("Contributors",  "contributors", 12, "r"),
    ("Commits 90d",   "commits_90d",  10, "r"),
    ("PRs merged",    "prs_merged",    9, "r"),
    ("Stale PRs",     "stale_prs",     9, "r"),
    ("Push age (d)",  "push_age",     11, "r"),
]

def repo_row(r: dict) -> dict:
    scores = r.get("scores", {})
    raw    = r.get("raw", {})
    return {
        "repo":          r["repo"],
        "category":      r.get("category", "unknown"),
        "status":        r.get("status", "unknown"),
        "health_score":  r.get("health_score", 0),
        "activity":      scores.get("activity", 0),
        "maintenance":   scores.get("maintenance", 0),
        "adoption":      scores.get("adoption", 0),
        "resilience":    scores.get("resilience", 0),
        "hygiene":       scores.get("hygiene", 0),
        "lifecycle":     scores.get("lifecycle_modifier", 0),
        "contributors":  raw.get("contributors_180d", 0),
        "commits_90d":   raw.get("commits_90d", 0),
        "prs_merged":    raw.get("prs_merged_90d", 0),
        "stale_prs":     raw.get("stale_prs_30d", 0),
        "push_age":      raw.get("days_since_last_push", 0),
    }


# ─── Table renderer ───────────────────────────────────────────────────────────

def score_colour(score: int, max_score: int) -> str:
    pct = score / max_score if max_score else 0
    if pct >= 0.70:  return "green"
    if pct >= 0.40:  return "yellow"
    return "red"

SCORE_MAX = {
    "health_score": 100,
    "activity":     35,
    "maintenance":  25,
    "adoption":     10,
    "resilience":   20,
    "hygiene":      10,
}

def render_table(repos: list[dict]) -> str:
    lines = []
    header_parts = []
    sep_parts = []

    for label, _key, width, align in COLUMNS:
        header_parts.append(c(label.ljust(width) if align == "l" else label.rjust(width), "bold"))
        sep_parts.append("-" * width)

    lines.append("  ".join(header_parts))
    lines.append("  ".join(sep_parts))

    for r in repos:
        row = repo_row(r)
        cells = []
        for label, key, width, align in COLUMNS:
            val = row.get(key, "")

            if key == "status":
                # Special rendering with icon and colour
                cells.append(status_str(str(val)).ljust(width))
                continue

            if key == "stale_prs":
                text = str(val).rjust(width)
                col = "red" if val >= 6 else ("yellow" if val >= 1 else "grey")
                cells.append(c(text, col))
            elif key in SCORE_MAX and isinstance(val, int):
                text  = str(val).rjust(width)
                colour = score_colour(val, SCORE_MAX[key])
                cells.append(c(text, colour))
            elif key == "lifecycle":
                text = (("+" if val > 0 else "") + str(val)).rjust(width)
                col = "green" if val > 0 else ("red" if val < 0 else "grey")
                cells.append(c(text, col))
            else:
                text = str(val)
                if align == "r":
                    text = text.rjust(width)
                else:
                    text = text.ljust(width)
                cells.append(text)

        lines.append("  ".join(cells))

    return "\n".join(lines)


# ─── CSV renderer ─────────────────────────────────────────────────────────────

def render_csv(repos: list[dict]) -> str:
    out = io.StringIO()
    fieldnames = [k for _, k, _, _ in COLUMNS]
    writer = csv.DictWriter(out, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    for r in repos:
        writer.writerow(repo_row(r))
    return out.getvalue()


# ─── Markdown renderer ────────────────────────────────────────────────────────

def render_markdown(repos: list[dict]) -> str:
    lines = []
    labels = [label for label, _, _, _ in COLUMNS]
    keys   = [key   for _, key, _, _ in COLUMNS]

    lines.append("| " + " | ".join(labels) + " |")
    lines.append("| " + " | ".join(["---"] * len(labels)) + " |")

    STATUS_MD = {
        "active":           "🟢 active",
        "stable":           "🔵 stable",
        "at_risk":          "🟡 at risk",
        "dormant":          "🟣 dormant",
        "likely_abandoned": "🔴 likely abandoned",
        "archived":         "⚫ archived",
    }

    for r in repos:
        row = repo_row(r)
        cells = []
        for key in keys:
            val = row.get(key, "")
            if key == "status":
                val = STATUS_MD.get(str(val), str(val))
            elif key == "lifecycle" and isinstance(val, int) and val > 0:
                val = f"+{val}"
            cells.append(str(val))
        lines.append("| " + " | ".join(cells) + " |")

    return "\n".join(lines)


# ─── HTML dashboard ──────────────────────────────────────────────────────────

def render_html(repos: list[dict]) -> str:
    import json as _json
    from datetime import datetime, timezone
    from jinja2 import Environment, FileSystemLoader, select_autoescape

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    data_json  = _json.dumps(repos, separators=(",", ":"))

    templates_dir = Path(__file__).parent / "templates"
    env = Environment(
        loader=FileSystemLoader(str(templates_dir)),
        autoescape=select_autoescape(["html"]),
    )
    template = env.get_template("dashboard.html")
    return template.render(generated=generated, data_json=_json.dumps(repos))

# ─── Legend ──────────────────────────────────────────────────────────────────

def render_legend_table() -> str:
    W = 72
    sep = c("─" * W, "grey")

    def section(title: str) -> str:
        return "\n".join([f"\n{sep}", c(f"  {title}", "bold"), sep])

    lines = [section("How the health score is built")]
    lines.append(
        "  The Health score (0–100) is the sum of five dimensions. Look at the\n"
        "  sub-scores to understand *why* a repo has a given total.\n"
    )

    dims = [
        ("Activity",   35,       "Is work actually happening? Commits, PRs merged, issue activity,\n"
                                 "                            and how recently anyone pushed code."),
        ("Maintenance", 25,      "Is the team keeping up? PR merge ratio, issue close rate,\n"
                                 "                            time since last release, CI run health."),
        ("Adoption",   10,       "Is anyone using it? Unique clones and views over the last 14 days.\n"
                                 "                            Intentionally low-weighted - many internal repos are\n"
                                 "                            critical but accessed by a small, stable audience."),
        ("Resilience", 20,       "What if one person leaves? Counts distinct contributors in the last\n"
                                 "                            180 days and how concentrated the commit history is.\n"
                                 "                            A repo where one person wrote 90% of commits is fragile."),
        ("Lifecycle",  "+10/-20","Is quietness expected? Adjusts score based on repo category\n"
                                 "                            (libraries and infra are expected to be low-churn)\n"
                                 "                            and penalises repos with no activity AND no release\n"
                                 "                            for over a year."),
    ]
    for name, max_val, desc in dims:
        first_line, *rest = desc.split("\n")
        lines.append(f"  {c(name, 'cyan'):<22}  max {str(max_val):<6}  {first_line}")
        for line in rest:
            lines.append(f"  {'':<22}           {line}")

    lines.append(section("Status labels and what to do"))

    status_actions = [
        ("active",           "active",          "green",
         "Regular commits, PRs, and maintenance. No action needed."),
        ("stable",           "stable",           "cyan",
         "Low churn but well maintained. Normal for mature libraries and infra.\n"
         "                                   Confirm quietness is intentional; no immediate action."),
        ("at_risk",          "at risk",          "yellow",
         "Work is happening but the repo depends on too few people, or\n"
         "                                   maintenance is slipping. Assign a second maintainer.\n"
         "                                   Review open PR and issue backlog."),
        ("dormant",          "dormant",          "magenta",
         "Little activity for 90–180 days. Decide: is this intentional?\n"
         "                                   If yes, set a category (library/infra). If no, assign an owner."),
        ("likely_abandoned", "likely abandoned", "red",
         "No activity for 180+ days, no release, low adoption.\n"
         "                                   Schedule a decision: archive, deprecate, or hand off.\n"
         "                                   Do not leave in an undefined state."),
        ("archived",         "archived",         "grey",
         "Explicitly archived on GitHub. No action needed.\n"
         "                                   Confirm downstream consumers are aware."),
    ]
    for status, label, colour, action in status_actions:
        icon = STATUS_ICONS[status]
        first_line, *rest = action.split("\n")
        lines.append(f"  {c(icon + ' ' + label, colour):<34}  {first_line}")
        for line in rest:
            lines.append(f"  {'':<34}  {line}")
        lines.append("")

    lines.append(section("Score and raw metric columns"))
    col_help = [
        ("Health (0–100)",    "Combined score. Use it to rank repos, not as a precise grade."),
        ("Activity (0–35)",   "Volume and recency of commits, PRs, and issues in the last 90 days."),
        ("Maintenance (0–25)","PR merge ratio, issue close ratio, release age."),
        ("Adoption (0–10)",   "Unique cloners and viewers over the last 14 days."),
        ("Resilience (0–20)", "Contributor diversity and commit concentration in the last 180 days."),
        ("Lifecycle (adj.)",  "Category and activity correction. Can add up to +10 or subtract up to -20."),
        ("Contributors",      "Distinct people who committed in the last 180 days."),
        ("Commits 90d",       "Commits on the default branch in the last 90 days."),
        ("PRs merged",        "Pull requests merged in the last 90 days."),
        ("Push age (d)",      "Days since the last push to any branch."),
    ]
    lines.append("")
    for name, desc in col_help:
        lines.append(f"  {c(name, 'cyan'):<28}  {desc}")

    lines.append(f"\n{sep}\n")
    return "\n".join(lines)


def render_legend_markdown() -> str:
    return """
---

## How this report works

The **Health score** (0–100) combines five independent dimensions. Use the sub-scores to understand *why* a repo has a given total - a repo can score poorly overall for very different reasons.

The model is designed to avoid two common mistakes:

- **Calling a stable, quiet repo unhealthy** - a mature library or infrastructure module may have very few commits and still be in excellent shape.
- **Missing actively-used but fragile repos** - work can be happening while only one or two people understand the codebase.

### Score dimensions

| Dimension | Max | What it measures |
| --- | --- | --- |
| **Activity** | 35 | Is work actually happening? Counts commits, PRs merged, and issue activity in the last 90 days, weighted by how recently code was pushed. |
| **Maintenance** | 25 | Is the team keeping up with the work? Measures PR merge ratio, issue close rate, time since last release, and CI run health. A repo can be very active and still score poorly here if PRs pile up unreviewed. |
| **Adoption** | 10 | Is anyone using this? Counts unique clones and page views over the last 14 days. Intentionally low-weighted - many critical internal repos are used by a small, stable audience and would score low here even when healthy. |
| **Resilience** | 20 | What happens if one person leaves? Measures how many distinct people committed in the last 180 days and what share of those commits came from the top one or two contributors. A repo where one person wrote 90% of the recent commits is fragile, even if otherwise active. |
| **Lifecycle** | +10 / -20 | Is quietness expected? A correction factor based on repo category (libraries and infrastructure are expected to be low-churn). Also subtracts points when a repo shows no activity and no release for over a year, and adds points when a recent release exists despite low commit activity. |

---

## Status labels and what to do

| Status | Meaning | Suggested action |
| --- | --- | --- |
| 🟢 **active** | Regular commits, PRs, and maintenance. Health ≥ 70 and Activity ≥ 20. | No action needed. |
| 🔵 **stable** | Low churn but well maintained. Health ≥ 55. Normal for mature libraries and infra repos. | Review periodically. Confirm that quietness is intentional. |
| 🟡 **at risk** | Work is happening, but the repo depends on too few people, or maintenance is falling behind. | Spread knowledge - assign a second maintainer. Review the open PR and issue backlog. |
| 🟣 **dormant** | Little meaningful activity for 90–180 days. | Decide: is this intentional? If yes, set the correct category (`library`, `infrastructure`). If no, assign a named owner. |
| 🔴 **likely abandoned** | No meaningful activity for 180+ days, no recent release, low adoption. | Schedule a decision: archive, deprecate, or hand off. Do not leave it in an undefined state. |
| ⚫ **archived** | Explicitly archived on GitHub. | No action needed. Confirm that downstream consumers are aware. |

---

## Score and raw metric columns

| Column | Max | What it counts |
| --- | --- | --- |
| **Health** | 100 | Combined score across all dimensions. Use for ranking repos, not as a precise grade. |
| **Activity** | 35 | Commits, PRs merged, and issue activity in the last 90 days, plus recency of last push. |
| **Maintenance** | 25 | PR merge ratio, issue close ratio, and time since last release. |
| **Adoption** | 10 | Unique cloners and viewers in the last 14 days. |
| **Resilience** | 20 | Contributor diversity and commit concentration over the last 180 days. |
| **Lifecycle** | +10/-20 | Category adjustment and activity/release correction. |
| **Contributors** | - | Distinct people who committed to the default branch in the last 180 days. |
| **Commits 90d** | - | Total commits on the default branch in the last 90 days. |
| **PRs merged** | - | Pull requests merged into the default branch in the last 90 days. |
| **Push age (d)** | - | Days since the last push to any branch. |

---

## A note on repo categories

The `Category` column defaults to `unknown`. Setting it correctly matters - a healthy-but-quiet infrastructure repo will look dormant if it is left as `unknown`.

| Category | Score adjustment | Use for |
| --- | --- | --- |
| `product` | 0 | User-facing services and applications |
| `library` | +5 | Shared libraries, SDKs, internal packages |
| `infrastructure` | +5 | Terraform, Helm, Ansible, and other IaC repos |
| `documentation` | +10 | Docs-only repos |
| `template` | +10 | Scaffold and starter repos |
| `experiment` | +10 | POCs, sandboxes, throwaway repos |
| `unknown` | 0 | Default - update this when possible |

Set a category when running the tool:

```
./run.sh --repo owner/my-infra-repo --category infrastructure
```
"""


# ─── Summary block ────────────────────────────────────────────────────────────

def render_summary(repos: list[dict]) -> str:
    from collections import Counter
    status_counts = Counter(r.get("status") for r in repos)
    total = len(repos)

    lines = [
        c(f"\n{'─' * 60}", "grey"),
        c(f"  Repo Health Report  -  {total} repos", "bold"),
        c(f"{'─' * 60}", "grey"),
    ]
    for status, colour in STATUS_COLOURS.items():
        count = status_counts.get(status, 0)
        if count:
            icon = STATUS_ICONS[status]
            lines.append(f"  {c(icon, colour)}  {status.replace('_',' '):<18}  {count}")
    lines.append(c(f"{'─' * 60}\n", "grey"))
    return "\n".join(lines)


# ─── Entry point ──────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Format repo health scores")
    p.add_argument("input", help="Scored JSON file, or - for stdin")
    p.add_argument("--format", choices=["summary", "table", "csv", "markdown", "json", "html"],
                   default="table", help="Output format (default: table)")
    p.add_argument("--status", default="",
                   help="Comma-separated status filter, e.g. dormant,at_risk")
    p.add_argument("--sort", default="health_score",
                   help="Sort key (default: health_score). Use - prefix for ascending.")
    p.add_argument("--no-summary", action="store_true",
                   help="Suppress the summary block (table format only)")
    p.add_argument("--no-legend", action="store_true",
                   help="Suppress the legend / key section")
    return p.parse_args()


def load_scored(path: str) -> list[dict]:
    if path == "-":
        return json.load(sys.stdin)
    with open(path) as f:
        return json.load(f)


def main():
    args = parse_args()
    repos = load_scored(args.input)

    # Filter by status
    if args.status:
        allowed = {s.strip() for s in args.status.split(",")}
        repos = [r for r in repos if r.get("status") in allowed]

    # Sort
    sort_key = args.sort.lstrip("-")
    reverse  = not args.sort.startswith("-")
    row_keys = {k for _, k, _, _ in COLUMNS}

    def sort_val(r):
        if sort_key in r:
            return r[sort_key]
        if sort_key in row_keys:
            return repo_row(r).get(sort_key, 0)
        return 0

    repos.sort(key=sort_val, reverse=reverse)

    if args.format == "summary":
        print(render_summary(repos))
    elif args.format == "table":
        if not args.no_summary:
            print(render_summary(repos))
        print(render_table(repos))
        if not args.no_legend:
            print(render_legend_table())
    elif args.format == "csv":
        print(render_csv(repos), end="")
    elif args.format == "markdown":
        print(render_markdown(repos))
        if not args.no_legend:
            print(render_legend_markdown())
    elif args.format == "html":
        print(render_html(repos))
    elif args.format == "json":
        json.dump(repos, sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()
