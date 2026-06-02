# pm/ — Project management automation

Declarative source-of-truth for milestones + labels in this repo, plus minimal idempotent scripts that sync state to GitHub.

## Purpose

Avoid hand-clicking the GitHub UI for **declarative** PM state. Milestones + labels live as code under version control; idempotent shell scripts reconcile GitHub state to whatever the JSON files declare.

**Per-issue categorization (Kind / Priority / Size) lives in project fields, not labels.** Use the `/agentkeys-issue-create` skill to create new issues with all required metadata pre-filled.

The associated GitHub Project (private) is [`litentry/projects/19`](https://github.com/orgs/litentry/projects/19) — see [`PROJECT-DASHBOARD-GUIDE.md`](./PROJECT-DASHBOARD-GUIDE.md) for board usage.

The 7-milestone roadmap detail (M1-M7 + post-M7 horizons + strategic risks) lives in [`docs/plan/milestones-roadmap.md`](../docs/plan/milestones-roadmap.md) — the operational companion to [`docs/arch.md`](../docs/arch.md) (architecture) and [`docs/research/agent-iam-strategy.md`](../docs/research/agent-iam-strategy.md) (positioning).

## Files

| File | Purpose |
|---|---|
| [`milestones.json`](./milestones.json) | The 7 roadmap milestones (M1–M7). One JSON object per milestone with title + description + state. |
| [`labels.json`](./labels.json) | Repo label taxonomy (post-migration: `area/*`, `status/*`, human-attention flags, community labels). Single source for `sync-labels.sh`. |
| [`scripts/sync-milestones.sh`](./scripts/sync-milestones.sh) | Idempotent — creates missing milestones, updates description/state for existing ones. |
| [`scripts/sync-labels.sh`](./scripts/sync-labels.sh) | Idempotent — creates missing labels, updates description/color for existing ones. |
| [`scripts/setup-project-fields.sh`](./scripts/setup-project-fields.sh) | Idempotent — creates the project's typed fields (Priority/Kind/Risk/Notes/Iteration). Cleans `Project <Name>` zombies left by GitHub's delete-recreate behavior. |
| [`scripts/sync-size-from-effort.sh`](./scripts/sync-size-from-effort.sh) | One-shot bulk-populate of the Size project field by parsing each issue's "## Effort" body section. |
| [`scripts/add-to-project.sh`](./scripts/add-to-project.sh) | Adds an issue (or all open) to the project board. Mostly a backfill tool; the built-in "Auto-add to project" workflow handles new issues. |
| [`scripts/audit.sh`](./scripts/audit.sh) | Read-only — lists open issues, groups by milestone, flags uncategorized. |
| [`PROJECT-DASHBOARD-GUIDE.md`](./PROJECT-DASHBOARD-GUIDE.md) | How to use the project board day-to-day + automation surface map. |

## Prerequisites

```bash
gh --version          # >= 2.40
jq --version          # >= 1.6
gh auth status        # logged in as a member of litentry/agentKeys
gh auth refresh -s project,read:project  # one-time, for the project-board scripts
```

## Quick start

```bash
cd pm

# Reconcile GitHub state to declared state (safe to re-run)
./scripts/sync-labels.sh
./scripts/sync-milestones.sh
./scripts/setup-project-fields.sh

# Check current state
./scripts/audit.sh
```

## How to add a new milestone

Edit `milestones.json`, then run `./scripts/sync-milestones.sh`.

## How to add a new label

Edit `labels.json`, then run `./scripts/sync-labels.sh`.

**Red is reserved** for human-interaction labels (status/blocked, status/investigating, needs-arch-review, needs-investigation, vendor-blocker). Area labels avoid the red family — pick a distinct non-red color per area.

## How to create a new issue

**Recommended:** use the `/agentkeys-issue-create` Claude Code skill — it walks you through Kind / Priority / Size / Area / Milestone / Blocked-by dropdowns and creates the issue with the right labels + project field values.

Direct CLI fallback (set fields in the project UI afterward, or via the skill):

```bash
gh issue create --repo litentry/agentKeys \
  --title "..." --body "..." \
  --milestone "M1: First MCP demo + Volcano Ark PoC" \
  --label "area/mcp"
```

Issue dependencies (blocked-by / blocking / parent) use GitHub's **native issue relationships** — UI side panel → "Relationships" or keyboard shortcuts (`B B` blocked-by, `B X` blocking, `Opt+Shift+P` parent). Do NOT create labels or project fields for dependencies.

## Labels schema (post-migration)

Repo labels are LEAN. Most categorization moved to project fields. Remaining label namespaces:

| Namespace | Examples | Purpose |
|---|---|---|
| `area/*` | `area/mcp`, `area/memory`, `area/firmware` (17 total, distinct colors per area) | Which subsystem — multi-value, renders as repo-list filter |
| `status/*` | `status/ready`, `status/in-progress`, `status/deprecated` (non-red); `status/blocked`, `status/investigating` (red) | Workflow state |
| Human-attention flags (red) | `needs-arch-review`, `needs-investigation`, `vendor-blocker` | Flagged for human follow-up |
| Community labels | `good first issue`, `help wanted` | Community discoverability |

**Migrated to project fields (no longer labels):**
- `priority/p0..p3` → **Priority field** (Urgent / High / Medium / Low)
- `kind/*` → **Kind field** (Feature / Bug / Research / Docs / Refactor / Security / CI)
- `phase/v*` → **Milestones** (M1..M7)

## Milestones overview

| ID | Title | Theme |
|---|---|---|
| M1 | First MCP demo + Volcano Ark PoC | Phase 1 — prove Agent IAM in <5 min |
| M2 | First vendor wedge (incl memory system) | Phase 2 — first paid pilot + multi-rail |
| M3 | Runtime neutrality | Phase 3 — Hermes/OpenClaw/Doubao/Claude Code as MCP tools |
| M4 | Capability + revocation depth | Phase 4 — active delegation, approval workflows, policy versioning |
| M5 | Native mobile app + biometric | Phase 5 — consumer surface beyond web UI |
| M6 | TEE integration + enhanced security | Phase 6 — production crypto hardening, key rotation depth |
| M7 | Standards + ecosystem | Phase 7 — MCP extensions, OAuth-for-Agents, partnerships |

Full per-milestone detail in [`docs/plan/milestones-roadmap.md`](../docs/plan/milestones-roadmap.md).

## Why JSON not YAML

`jq` is universally available in CI / dev machines; YAML parsing in shell requires `yq` which is less universal. JSON is uglier to read but trivially scriptable.
