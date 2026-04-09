# github-repo-health

A CLI tool for auditing the health of GitHub repositories — individually, by glob pattern, or across an entire organisation. Produces a colour terminal report, a self-contained HTML dashboard, Markdown, and CSV.

## How it works

Each repo is measured across five independent dimensions and a lifecycle adjustment:

| Dimension | Max | What it measures |
|---|---|---|
| **Activity** | 35 | Commits, PRs merged, and issue activity in the last 90 days, weighted by recency of last push |
| **Maintenance** | 25 | PR merge ratio, issue close rate, time since last release, CI health. Penalised for stale open PRs |
| **Adoption** | 10 | Unique clones and page views over the last 14 days |
| **Resilience** | 20 | Contributor count and commit concentration (bus-factor risk) over the last 180 days |
| **Hygiene** | 10 | README, LICENSE, CONTRIBUTING guide, branch protection, CODEOWNERS |
| **Lifecycle** | +10 / -20 | Category adjustment — libraries and infra are expected to be quiet. Penalises repos with no activity and no release for over a year |

**Health score** = sum of all dimensions, capped at 100.

Repos are labelled with one of six statuses: `active`, `stable`, `at_risk`, `dormant`, `likely_abandoned`, `archived`. All thresholds are configurable in `config.yaml`.

## Requirements

- [gh](https://cli.github.com/) — authenticated (`gh auth login`)
- `jq`
- Python 3.8+
- `pyyaml` — `pip install pyyaml` or use the venv setup below

## Setup

```bash
git clone https://github.com/your-org/github-repo-health
cd github-repo-health

# Install Python dependency
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# Edit targets.yaml to describe what you want to scan
# config.yaml ships with working defaults - edit only if you need to tune thresholds
```

Make the scripts executable if needed:

```bash
chmod +x run.sh collect_repo.sh collect_org.sh
```

## Usage

### Targets mode (recommended)

Edit `targets.yaml`, then:

```bash
# Run all targets
./run.sh

# Run a single named target
./run.sh --target "My Org"

# Use a different targets file
./run.sh --targets path/to/other-targets.yaml

# Use a different scoring config
./run.sh --config path/to/other-config.yaml
```

### Ad-hoc mode

```bash
# Scan an entire organisation
./run.sh --org my-org

# Single repo
./run.sh --repo owner/my-repo --category library

# All repos matching a prefix (quote the wildcard)
./run.sh --repo 'owner/prefix-*'

# Skip forks and archived repos
./run.sh --org my-org --exclude fork,archived

# Only show dormant and at-risk repos
./run.sh --org my-org --status dormant,at_risk

# Re-score already-collected data without hitting the API again
./run.sh --score-only

# Print full table to stdout (summary is always shown)
./run.sh --org my-org --format table

# Verbose mode - shows per-step API progress
./run.sh --org my-org -v
```

### Options

| Flag | Default | Description |
|---|---|---|
| `--config FILE` | `config.yaml` | Scoring config YAML |
| `--targets FILE` | `targets.yaml` | Targets file |
| `--target NAME` | | Run only this named target |
| `--org ORG` | | GitHub organisation (ad-hoc) |
| `--repo OWNER/REPO` | | Single repo or glob pattern (ad-hoc) |
| `--category CAT` | `unknown` | Category for ad-hoc single/pattern mode |
| `--limit N` | | Process only the first N repos |
| `--exclude LIST` | | Comma-separated: `fork`, `archived`, `empty` |
| `--format FORMAT` | summary | Print to stdout: `table`, `csv`, `markdown`, `json`, `html` |
| `--status STATUS` | | Filter output, e.g. `dormant,at_risk` |
| `--output DIR` | `./data` | Base output directory |
| `--score-only` | | Skip collection, re-score from existing raw data |
| `--no-summary` | | Suppress the summary block |
| `-v`, `--verbose` | | Print detailed collection/scoring progress |

### Output

After every run, the following files are written to `data/` regardless of `--format`:

| File | Contents |
|---|---|
| `data/report.html` | Self-contained interactive dashboard (sort, filter, search) |
| `data/report.md` | Markdown table with full legend |
| `data/report.csv` | CSV for import into spreadsheets |
| `data/scored/all.json` | Full scored JSON — input for `report.py` |
| `data/raw/*.json` | Raw collected metrics per repo |

## Configuration

### `targets.yaml`

Describes what to scan. Gitignored so your org names stay local. Each target is an org or a list of specific repos, with its own ignore list and category mappings:

```yaml
targets:
  - name: "My Organisation"
    org: my-org
    exclude: fork,archived
    ignore:
      - "my-org/mirror-*"
      - "my-org/generated-*"
    categories:
      - match: "my-org/frontend-*"
        category: product
      - match: "my-org/infra-*"
        category: infrastructure

  - name: "Tracked external libraries"
    repos:
      - partner/some-lib
      - another-org/their-sdk
    categories:
      - match: "partner/*"
        category: library
```

Category patterns are matched in order; the first match wins.

### `config.yaml`

Controls scoring thresholds, category modifiers, and stale PR penalties. Ships with working defaults — edit only if you need to tune what "healthy" means for your organisation:

```yaml
category_modifiers:
  library: 5
  infrastructure: 5

status_thresholds:
  active:
    min_health_score: 70
    min_activity_score: 20
```

### Repo categories

| Category | Score adjustment | Use for |
|---|---|---|
| `product` | 0 | User-facing services and applications |
| `library` | +5 | Shared libraries, SDKs, internal packages |
| `infrastructure` | +5 | Terraform, Helm, Ansible, and other IaC repos |
| `documentation` | +10 | Docs-only repos |
| `template` | +10 | Scaffold and starter repos |
| `experiment` | +10 | POCs, sandboxes, throwaway repos |
| `unknown` | 0 | Default — update when possible |

Setting the correct category matters. A quiet infrastructure repo will appear `dormant` if left as `unknown`.

## Running individual scripts

The pipeline has three stages that can be run independently:

```bash
# 1. Collect raw metrics for one repo → stdout JSON
./collect_repo.sh owner/my-repo [category]

# 2. Score raw JSON
python3 score.py data/raw/all.json

# 3. Render a report
python3 report.py data/scored/all.json --format table
python3 report.py data/scored/all.json --format html > dashboard.html
python3 report.py data/scored/all.json --format markdown --status dormant,at_risk
```

## Notes

- Traffic data (clones/views) requires **push access** to the repo. If you lack access, adoption scores will be 0.
- The tool respects GitHub API rate limits. In org mode it checks remaining quota before each repo and sleeps until reset if needed.
- `config.yaml` and `categories.yaml` are git-ignored so your org-specific settings stay local. Use the `.example` files as templates.
