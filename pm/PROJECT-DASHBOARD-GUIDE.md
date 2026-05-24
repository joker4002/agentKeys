# Using the litentry/agentKeys project dashboard

The GitHub Project [`litentry/projects/19`](https://github.com/orgs/litentry/projects/19) (private) is the operational view for week-to-week PM work. The repo's milestones + labels + issues are the source of truth; the project dashboard is the UI on top.

This guide covers: how to use the board day-to-day, which columns mean what, how CI integration flows events to the board, weekly cadence.

## Quick start

### One-time setup

```bash
# Add the project scope to your gh auth
gh auth refresh -s project,read:project

# Verify access
gh project list --owner litentry | grep "19"
```

### Add an issue to the board

```bash
# Add one issue
bash pm/scripts/add-to-project.sh 103

# Add all currently-open issues
bash pm/scripts/add-to-project.sh
```

### Open the board

```bash
open "https://github.com/orgs/litentry/projects/19"
```

## How the board is structured

(Configure these in the project's web UI under "Project settings" → "Fields". The PM scripts don't manage project-board layout — that's an interactive setup.)

### Recommended views

| View name | Filter | Group by | Purpose |
|---|---|---|---|
| **Roadmap** | `is:open` | `Milestone` | Big-picture: what's coming in each milestone |
| **In Flight** | `is:open status:in-progress` | `Assignee` | Who's actively working on what right now |
| **Ready for pickup** | `is:open label:status/ready` | `Priority` | Next-up queue — engineers self-assign from here |
| **Blocked** | `is:open label:status/blocked` | `Milestone` | Surface blockers fast |
| **Needs arch review** | `label:needs-arch-review` | `Milestone` | Issues flagged as needing arch.md compatibility check before any code lands |
| **Vendor blockers** | `label:vendor-blocker` | `Priority` | Issues that block a vendor pilot conversation |
| **Pull requests** | `type:pr is:open` | `Author` | PR review queue |

### Recommended custom fields

- **Priority**: P0 / P1 / P2 / P3 (matches the `priority/*` labels)
- **Status**: Todo / In Progress / In Review / Done (manual workflow stage, separate from `status/*` labels which capture deeper semantics)
- **Estimate**: T-shirt (XS / S / M / L / XL) or week-bucket — pick whichever the team prefers
- **Iteration**: 2-week sprint windows (optional; only if running formal sprints)

### Recommended workflows (Project Settings → Workflows)

These are built-in GitHub Project automations — enable in the project's "Workflows" tab:

| Trigger | Action |
|---|---|
| Item added to project | Set Status → Todo |
| Issue closed | Set Status → Done |
| PR merged | Set Status → Done; close linked issue |
| PR opened | Set Status → In Review |
| Code change requested | Set Status → In Progress |

## Day-to-day usage

### Engineer picking up new work

1. Open the **Ready for pickup** view
2. Pick the highest-priority item (P0 → P1 → P2 → P3)
3. Self-assign by setting yourself as Assignee
4. Move Status to **In Progress** (or just create a branch + PR; the workflow auto-moves it)
5. As you work, comment on the issue with significant updates (links to design docs, related discussion)

### Engineer creating new work

```bash
# Quick path — direct gh CLI
gh issue create --repo litentry/agentKeys \
  --title "Phase 2: <something>" \
  --body "Scope..." \
  --milestone "M2: First vendor wedge (incl memory system)" \
  --label "area/mcp,kind/feature,phase/v2,priority/p2"

# Then add to project board
bash pm/scripts/add-to-project.sh <issue_number>
```

For repeatable issue creation (e.g., planning a sprint), prefer the declarative path:

1. Add the issue spec to `pm/new-issues.json`
2. Run `bash pm/scripts/create-issues.sh` — idempotent, won't duplicate
3. Run `bash pm/scripts/add-to-project.sh <new_issue_number>` to put it on the board

### Weekly cadence (suggested)

| Day | Activity | Tool |
|---|---|---|
| **Monday standup** | Review **In Flight** view; identify blockers; move blocked items to **Blocked** | Project board |
| **Wednesday mid-week** | Review **Needs arch review** view; resolve outstanding arch compatibility questions | Project board + arch.md |
| **Friday wrap** | Run `bash pm/scripts/audit.sh` — flag uncategorized issues; review milestone progress; close completed items | Terminal + project board |
| **Monthly** | Review milestone progress; close milestones that are done; bump scope where needed | `gh api repos/litentry/agentKeys/milestones` |

## CI integration

Four GitHub Actions workflows exist today (in `.github/workflows/`):

| File | What it does | Trigger |
|---|---|---|
| [`claude.yml`](../.github/workflows/claude.yml) | Runs Claude Code automation in CI (issue / PR handler) | Issue + PR events |
| [`claude-code-review.yml`](../.github/workflows/claude-code-review.yml) | Auto-review on PR submission | `pull_request: types: [opened, reopened, ready_for_review]` (no `synchronize` per #100) |
| [`harness-ci.yml`](../.github/workflows/harness-ci.yml) | No-LLM CI: ephemeral anvil tier-1 + scaffolded test-broker tier-2 (#98) | PR + push to specific paths |
| [`publish-wiki.yml`](../.github/workflows/publish-wiki.yml) | Mirrors `./wiki/` to the GitHub Wiki | Push to `main` |

### How CI events flow to the project board

GitHub's project board has a **built-in automation** that listens to repo events:

- **Issue opened** → if linked in PR or referenced in commit message, item is auto-added to project (configure in project Workflows)
- **PR opened** → auto-add to project; auto-set Status → In Review
- **Issue closed** → auto-move to Done
- **PR merged** → auto-close linked issue; auto-move to Done

### Linking PRs to issues

Use these keywords in PR descriptions to auto-link + auto-close:

- `Closes #103` — closes issue when PR merges
- `Fixes #103` — same
- `Resolves #103` — same
- `Refs #103` — links but does NOT auto-close (use for partial work)

### Recommended addition: `pm-sync.yml` workflow (optional, future)

A GitHub Action that runs `pm/scripts/sync-milestones.sh + sync-labels.sh + sync-issues.sh` on push to main when `pm/**` changes. This would auto-reconcile any edit to the JSON declarative state without an engineer needing to run scripts locally.

Skeleton:

```yaml
name: pm-sync
on:
  push:
    branches: [main]
    paths: ['pm/**']
  workflow_dispatch:
jobs:
  sync:
    runs-on: ubuntu-latest
    permissions:
      issues: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - run: |
          bash pm/scripts/sync-labels.sh
          bash pm/scripts/sync-milestones.sh
          bash pm/scripts/sync-issues.sh
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PM_REPO: ${{ github.repository }}
```

Not adding now (manual is fine for v0); add when the PM JSON churns frequently enough to justify the automation.

## Common operations

### Move an issue between milestones

```bash
# Find milestone IDs
gh api repos/litentry/agentKeys/milestones --jq '.[] | "\(.number): \(.title)"'

# Re-milestone an issue
gh api repos/litentry/agentKeys/issues/103 -X PATCH -F milestone=3
```

Or use the project UI: select issue → Milestone field → pick new value.

### Bulk label cleanup

```bash
# List all issues missing area/* label (need triage)
gh issue list --repo litentry/agentKeys --state open --limit 200 \
  --json number,title,labels --jq \
  '.[] | select(([.labels[].name] | map(select(startswith("area/"))) | length) == 0) | "#\(.number): \(.title)"'

# Bulk add a label
for n in 1 2 3; do
  gh issue edit $n --repo litentry/agentKeys --add-label "area/cli"
done
```

### Close stale issues

```bash
# Find issues with no activity in 90 days
gh issue list --repo litentry/agentKeys --state open --limit 200 \
  --search "is:open updated:<2026-02-24" \
  --json number,title,updatedAt --jq '.[] | "#\(.number) (\(.updatedAt | split("T")[0])): \(.title)"'

# Close with comment
gh issue close <N> --repo litentry/agentKeys --comment "Closing as stale; reopen if still relevant."
```

### Re-run PM sync after editing JSON

```bash
bash pm/scripts/sync-labels.sh       # ~5s
bash pm/scripts/sync-milestones.sh   # ~5s
bash pm/scripts/sync-issues.sh       # ~30s for 23 issues (one API call per issue)
bash pm/scripts/audit.sh             # verify state
```

## Things the project board is NOT for

- **Source of truth for scope / requirements**: that's the issue body + linked design doc (`docs/research/*` or `docs/spec/plans/*`)
- **Real-time chat / debate**: use issue comments; project board is a queue, not a discussion forum
- **Roadmap planning**: that's [`docs/research/agent-iam-strategy.md`](../docs/research/agent-iam-strategy.md) §5; the board reflects the roadmap, doesn't define it
- **Burndown charts / velocity metrics**: GitHub Projects has some basic insights but if you want real burndown, use a dedicated tool (Linear, Jira). For us, the milestone progress view + the audit script are sufficient.

## When to update arch.md vs an issue body

| Change | Where to land it |
|---|---|
| Architectural decision (new key class, new component boundary, new isolation invariant) | arch.md edit in the SAME PR as the issue work; reference the issue # in the arch.md commit |
| Implementation detail (chosen library, file paths, code structure) | Issue body + PR description; no arch.md change unless the structure itself is architectural |
| New name / canonical term | arch.md §5 "Canonical names" table (per CLAUDE.md terminology-source-of-truth rule) |
| Performance / latency commitment | arch.md §X (performance section) + commit message; not just an issue comment |
| Security commitment | arch.md §3 (trust boundaries) + linked threat-model wiki page |

## Reference

- [GitHub Projects (next-gen) docs](https://docs.github.com/en/issues/planning-and-tracking-with-projects)
- [`pm/README.md`](./README.md) — pm/ folder structure + script usage
- [`pm/arch-md-verification-report.md`](./arch-md-verification-report.md) — example of an arch.md compatibility verification doc
- [`docs/research/agent-iam-strategy.md`](../docs/research/agent-iam-strategy.md) §5 — 7-milestone roadmap source of truth
