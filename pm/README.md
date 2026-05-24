# pm/ — Project management automation

Declarative source-of-truth for milestones, labels, and issue categorization in this repo, plus scripts that idempotently sync them to GitHub.

## Purpose

Avoid hand-clicking the GitHub UI. Treat milestones / labels / issue assignments as **code** under version control, with idempotent shell scripts that reconcile GitHub state to whatever the JSON files declare. Re-runnable safely; CI-friendly; reviewable in diffs.

The associated GitHub Project (private) is [`litentry/projects/19`](https://github.com/orgs/litentry/projects/19) — see [`PROJECT-DASHBOARD-GUIDE.md`](./PROJECT-DASHBOARD-GUIDE.md) for how to use it.

## Files

| File | Purpose |
|---|---|
| [`milestones.json`](./milestones.json) | The 7 roadmap milestones (M1–M7). One JSON object per milestone with title + description + state. |
| [`labels.json`](./labels.json) | Label taxonomy: `area/*`, `kind/*`, `phase/*`, `status/*`, `priority/*`. One JSON object per label with name + description + color. |
| [`issue-assignments.json`](./issue-assignments.json) | Maps existing open issues to milestones + labels. Lets us reproduce the categorization from scratch if needed. |
| [`scripts/sync-milestones.sh`](./scripts/sync-milestones.sh) | Idempotent — creates missing milestones, updates description/state for existing ones. Skips no-op. |
| [`scripts/sync-labels.sh`](./scripts/sync-labels.sh) | Idempotent — creates missing labels, updates description/color for existing ones. Skips no-op. |
| [`scripts/sync-issues.sh`](./scripts/sync-issues.sh) | Idempotent — assigns milestone + labels to each issue listed in `issue-assignments.json`. Skips when already correct. |
| [`scripts/audit.sh`](./scripts/audit.sh) | Read-only — lists open issues, groups by milestone, flags uncategorized. Run anytime to see PM state. |
| [`scripts/add-to-project.sh`](./scripts/add-to-project.sh) | Adds an issue (or all open) to the litentry/projects/19 board. Requires `gh auth refresh -s project,read:project` once. |
| [`PROJECT-DASHBOARD-GUIDE.md`](./PROJECT-DASHBOARD-GUIDE.md) | How to use the project board day-to-day + CI integration. |

## Prerequisites

```bash
gh --version          # >= 2.40
jq --version          # >= 1.6 (for JSON parsing)
gh auth status        # logged in as a member of litentry/agentKeys
```

For project board scripts (`add-to-project.sh`):

```bash
gh auth refresh -s project,read:project  # one-time
```

## Quick start

```bash
cd pm

# Reconcile GitHub state to declared state (safe to re-run)
./scripts/sync-labels.sh
./scripts/sync-milestones.sh
./scripts/sync-issues.sh

# Check current state
./scripts/audit.sh
```

## How to add a new milestone

Edit `milestones.json`, then run `./scripts/sync-milestones.sh`. The script will create it (or update if title matched an existing milestone).

## How to add a new label

Edit `labels.json`, then run `./scripts/sync-labels.sh`. Same idempotent shape.

## How to assign an issue to a milestone + labels

Edit `issue-assignments.json` — add or update the entry for the issue number, then run `./scripts/sync-issues.sh`. The script reconciles each issue to the declared assignment.

## How to handle new issues

When you create a new issue via `gh issue create` (or web UI), the milestone/labels you assign at creation time are authoritative — but you should ALSO add the new entry to `issue-assignments.json` for reproducibility. Without that, re-running `sync-issues.sh` won't touch your new issue, which is fine; it just means it's outside the declarative state.

Recommended pattern:

```bash
# Create issue with milestone + labels inline
gh issue create --repo litentry/agentKeys \
  --title "..." --body "..." \
  --milestone "M1: First MCP demo + Volcano Ark PoC" \
  --label "area/mcp,kind/feature,priority/p1"

# Then record it in issue-assignments.json for the next sync to honor
```

## Labels schema

Five label namespaces. An issue typically has one from each, plus optional extras:

| Namespace | Examples | Purpose |
|---|---|---|
| `area/*` | `area/mcp`, `area/memory`, `area/firmware` | Which subsystem |
| `kind/*` | `kind/feature`, `kind/bug`, `kind/research` | What kind of work |
| `phase/*` | `phase/v0`, `phase/v1`, `phase/v2` | Coarse roadmap phase (orthogonal to milestone for cross-milestone work) |
| `status/*` | `status/ready`, `status/blocked`, `status/investigating`, `status/deprecated` | Workflow state |
| `priority/*` | `priority/p0`, `priority/p1`, `priority/p2`, `priority/p3` | Triage priority |

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

Strategic source of truth: [`docs/research/agent-iam-strategy.md`](../docs/research/agent-iam-strategy.md) §5 roadmap.

## Why JSON not YAML

`jq` is universally available in CI / dev machines; YAML parsing in shell requires `yq` which is less universal. JSON is uglier to read but trivially scriptable.
