# Using the litentry/agentKeys project dashboard

The GitHub Project [`litentry/projects/19`](https://github.com/orgs/litentry/projects/19) (private) is the operational view for week-to-week PM work. The repo's milestones + labels + issues are the source of truth; the project dashboard is the UI on top.

This guide covers: how to use the board day-to-day, which columns mean what, how CI integration flows events to the board, weekly cadence.

## Known gotcha — "Priority" field zombies

GitHub's `deleteProjectV2Field` mutation on a system-reserved field name (notably **Priority**) does NOT fully delete. It renames the old field to **"Project Priority"** and creates a fresh empty placeholder under the original name. Run delete-recreate twice and you get "Project Project Priority", and so on.

`pm/scripts/setup-project-fields.sh` now auto-cleans these zombies at the start of every run via a `cleanup_zombies` pass — you should never have to think about it. If you see a `Project Priority` (or `Project Phase`, etc.) field in the UI's field list, just re-run `bash pm/scripts/setup-project-fields.sh` and it'll be cleaned up.

**Why this isn't 100% fixed**: GitHub's Priority field is "suggested" by the platform and may respawn after item changes regardless of what we do. The cleanup pass handles the immediate fallout, but if you ever see Priority show 0 options on the board, re-run setup-project-fields.sh.

## What's automated vs what's UI-only

GitHub's Projects v2 API has **specific limits**. Knowing what's automatable up front saves an hour of wasted "why isn't this scripted" debugging.

| Capability | Automated? | How |
|---|---|---|
| Add new issue to board | ✅ | Built-in "Auto-add to project" workflow (already enabled) |
| Set Status on add / close / PR-merge | ✅ | Built-in workflows (Item added / Item closed / Pull request merged — all enabled) |
| Auto-close issue when Status=Done | ✅ | Built-in "Auto-close issue" workflow |
| Link PR to issue | ✅ | Built-in "Pull request linked to issue" workflow |
| Sync `priority/p*` + `phase/v*` labels → fields | ✅ | `.github/workflows/pm-sync-fields-from-labels.yml` (this repo) |
| Create / configure project fields | ✅ | `pm/scripts/setup-project-fields.sh` |
| Audit workflow drift | ✅ | `.github/workflows/pm-workflow-audit.yml` (daily) |
| Bulk backfill historical issues | ✅ | `bash pm/scripts/add-to-project.sh` |
| **Configure a workflow's filter expression** | ❌ | **UI ONLY** — API has no `updateProjectV2Workflow` mutation |
| **Configure a workflow's trigger / action** | ❌ | **UI ONLY** — same reason |
| **Create or configure custom views (group-by, layout, filters)** | ❌ | **UI ONLY** — no `createProjectV2View` / `updateProjectV2View` mutation exists |

The UI-only items live at `https://github.com/orgs/litentry/projects/19/workflows` and the view-config panel of each board view. They're one-time clicks and don't drift often, but you cannot version-control them. Compensate with `pm-workflow-audit.yml` which catches "someone toggled a workflow off in the UI."

## Quick start

### One-time setup

```bash
# Add the project scope to your gh auth
gh auth refresh -s project,read:project

# Verify access
gh project list --owner litentry | grep "19"

# Create project fields (Priority/Phase/Estimate/Risk/Notes)
bash pm/scripts/setup-project-fields.sh
```

### Add a CI secret for the GitHub Actions

The 2 PM workflows (`pm-workflow-audit.yml`, `pm-sync-fields-from-labels.yml`) need a token with org-project scopes — the default `GITHUB_TOKEN` does not have them.

1. Create a fine-grained PAT at https://github.com/settings/tokens
   - Org permissions: **Projects = read & write**
   - Repo permissions: **Issues = read & write**, **Pull requests = read**
2. Add as repo secret: `gh secret set PM_PROJECT_TOKEN < token.txt`

### Add an issue to the board (rarely needed — built-in workflow does it)

```bash
# Fallback only; "Auto-add to project" built-in workflow handles new issues
bash pm/scripts/add-to-project.sh 103          # one issue
bash pm/scripts/add-to-project.sh              # all open issues (backfill)
```

### Sync labels → fields (manual trigger)

The `.github/workflows/pm-sync-fields-from-labels.yml` Action handles this automatically on every label change. For backfill of pre-existing issues, trigger manually:

```bash
gh workflow run pm-sync-fields-from-labels.yml
# Or run locally:
bash pm/scripts/sync-fields-from-labels.sh        # all open issues
bash pm/scripts/sync-fields-from-labels.sh 103    # one issue
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
- **Phase**: v0 / v1 / v2 / v3 / v4 (matches `phase/*` labels — one value per issue)
- **Estimate**: T-shirt (XS / S / M / L / XL) or week-bucket — pick whichever the team prefers
- **Iteration**: 2-week sprint windows (optional; only if running formal sprints)
- **Risk**: Low / Medium / High / Critical (for surfacing items needing extra scrutiny)
- **Notes**: Free-form one-line context per item

**Run `bash pm/scripts/setup-project-fields.sh` to create all of these via gh CLI.**

### Labels vs Fields — when to use which

The most common project-board pain point is "all labels pile into one cluttered column." The fix is splitting concerns between **labels** (repo-level, multi-value, render as stacked chips) and **fields** (project-level, single-value, render as their own column with a dropdown).

| Concept | Use a label | Use a field |
|---|---|---|
| Issue can have many values | ✅ `area/*` (an issue may touch broker + signer) | ❌ |
| Issue has exactly one value | ❌ (label pile-up problem) | ✅ Priority, Phase, Estimate |
| PM workflow state | ❌ | ✅ Status (built-in) |
| Cross-cutting semantic flag | ✅ `needs-arch-review`, `vendor-blocker`, `kind/security` | ❌ |
| Render as its own column | ❌ | ✅ |
| Show in repo issue list | ✅ | ❌ (project only) |

Recommended split for THIS repo:

| What | Where | Why |
|---|---|---|
| Priority | **Field** (Priority: P0-P3) | One value per issue, want its own column |
| Phase | **Field** (Phase: v0-v4) | Same |
| Status (workflow) | **Field** (built-in Status) | Same |
| Area | **Label** (`area/*`) | Multi-value — an issue can touch broker + signer + audit |
| Kind | **Label** (`kind/*`) | One value but semantic (lives at repo level for non-project consumers) |
| Phase | Both label AND field (redundant, keep label for repo non-project users; field for clean board) | Duplication is OK — board users see field, repo users see label |
| `needs-arch-review`, `vendor-blocker` | **Label** | Cross-cutting flag visible from repo issue list |
| `status/deprecated`, `status/investigating` | **Label** | Semantic flag distinct from workflow status |

### How to fix the cluttered Labels column

1. Run `bash pm/scripts/setup-project-fields.sh` — creates Priority, Phase, Estimate, Iteration, Risk, Notes as fields. **Idempotent**: rebuilds GitHub's empty-by-default built-in Priority/Size fields with the proper P0..P3 / XS..XL options.
2. Backfill all existing issues onto the board: `bash pm/scripts/add-to-project.sh`
3. Bulk-populate Priority + Phase fields from existing `priority/p*` + `phase/v*` labels:
   - **CI path** (preferred): `gh workflow run pm-sync-fields-from-labels.yml`
   - **Local path**: `bash pm/scripts/sync-fields-from-labels.sh`
4. In the project UI, open your "By Labels" view → click ⋯ on the Labels column header → "Hide field"
5. Add the new fields as columns (drag from the field list at right)
6. Change "Group by" from Labels to **Priority** (or **Phase**) — gives clean grouping

Result: cluttered 5-chip Labels cells disappear; you get clean single-value dropdowns per field. **Going forward**, the `.github/workflows/pm-sync-fields-from-labels.yml` Action auto-syncs on every label change — no manual step needed.

### Built-in workflows — prefer these over scripts

GitHub Projects ships ~10 built-in workflow automations. These replace a chunk of what the `pm/scripts/` would otherwise do — use them first; scripts are fallback / batch-only.

| Workflow | Default? | Configure | Replaces script? |
|---|---|---|---|
| **Auto-add to project** | needs filter set | Filter: `repo:litentry/agentKeys is:issue` | ✅ Replaces `add-to-project.sh` for new issues (script becomes one-time backfill) |
| **Auto-add sub-issues to project** | on | (no config) | New (no script equivalent) |
| **Auto-close issue** | on | When Status = Done → close issue | New (no script equivalent) |
| **Item added to project** | on | Set Status → Todo on add | New |
| **Item closed** | on | Set Status → Done on close | New |
| **Pull request linked to issue** | on | (no config; uses "Closes #N" in PR body) | New |
| **Pull request merged** | on | When PR merged → linked issue Status → Done | New |
| **Auto-archive items** | off | Auto-archive after N days in Done | New — recommend enabling with 30-day threshold |
| **Code changes requested** | off | When PR review = changes requested → Status → In Progress | Optional |
| **Code review approved** | off | When PR review = approved → Status → Ready to merge | Optional |
| **Item reopened** | off | When closed item is reopened → Status → Todo | Optional |

### Script ↔ workflow split (what each is for)

Three layers: GitHub's **built-in workflows** (UI-configured), our **GitHub Actions** (`.github/workflows/pm-*.yml`, version-controlled), and **bash scripts** (local + CI fallback).

| Job | Built-in workflow | Our GH Action | Bash script |
|---|---|---|---|
| Add new issue to board | ✅ Auto-add to project | — | `add-to-project.sh` (backfill only) |
| Set initial Status when added | ✅ Item added to project | — | — |
| Move to Done when closed | ✅ Item closed | — | — |
| Close issue when Status=Done | ✅ Auto-close issue | — | — |
| Link PR to issue | ✅ Pull request linked to issue | — | — |
| Move to Done when PR merged | ✅ Pull request merged | — | — |
| **Sync `priority/p*` + `phase/v*` labels → fields** | ❌ no built-in | ✅ `pm-sync-fields-from-labels.yml` (issues.labeled) | `sync-fields-from-labels.sh` (backfill + local) |
| **Audit workflow drift** | ❌ no built-in | ✅ `pm-workflow-audit.yml` (daily) | `check-workflows.sh` |
| Create repo milestones / labels | ❌ no built-in | (could move to GHA) | `sync-milestones.sh`, `sync-labels.sh` |
| Bulk-assign milestones + labels to existing issues | ❌ no built-in | (could move to GHA) | `sync-issues.sh` |
| Create new issues from a declarative list | ❌ no built-in | — | `create-issues.sh` |
| Create project field definitions | ❌ no built-in | — | `setup-project-fields.sh` (one-time) |
| Audit categorization state | ❌ no built-in | — | `audit.sh` |

**Rule**: built-in workflow > our GH Action > bash script. Use the highest layer that covers the job. Scripts exist for: one-time bootstrap (setup-project-fields), batch creation (create-issues), and local debugging fallback for everything else.

### One-time workflow configuration checklist

After the board exists:

1. **Open** [https://github.com/orgs/litentry/projects/19/workflows](https://github.com/orgs/litentry/projects/19/workflows)
2. **Auto-add to project** — click → set filter to `repo:litentry/agentKeys is:issue` → save
3. **Verify the other enabled workflows** (green dots) are configured per the table above; most need no edits
4. **Optionally enable**: Auto-archive items (recommend 30-day threshold), Code review approved
5. Done. From now on, new issues from `litentry/agentKeys` auto-land on the board with Status=Todo; merged PRs auto-move linked issues to Done and close them.

## Day-to-day usage

### Engineer picking up new work

1. Open the **Ready for pickup** view
2. Pick the highest-priority item (P0 → P1 → P2 → P3)
3. Self-assign by setting yourself as Assignee
4. Move Status to **In Progress** (or just create a branch + PR; the workflow auto-moves it)
5. As you work, comment on the issue with significant updates (links to design docs, related discussion)

### Engineer creating new work

```bash
# Just create the issue with the right labels — built-in + GH Action workflows do the rest:
#   1. "Auto-add to project" built-in workflow → adds it to the board with Status=Todo
#   2. pm-sync-fields-from-labels.yml GH Action → mirrors priority/* + phase/* labels into the
#      Priority + Phase project fields
gh issue create --repo litentry/agentKeys \
  --title "Phase 2: <something>" \
  --body "Scope..." \
  --milestone "M2: First vendor wedge (incl memory system)" \
  --label "area/mcp,kind/feature,phase/v2,priority/p2"
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
- **Roadmap planning**: the milestones (`pm/milestones.json` + the GitHub Milestones page) are the roadmap; the board reflects them, doesn't define them
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
- [`pm/milestones.json`](./milestones.json) — 7-milestone roadmap definition (synced to GitHub Milestones via `sync-milestones.sh`)
