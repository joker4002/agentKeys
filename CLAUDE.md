# AgentKeys

## Architecture
Rust monorepo with Cargo workspace. See `docs/spec/architecture.md` for component inventory.
See `docs/spec/credential-backend-interface.md` for the CredentialBackend trait contract (15 methods).
See `docs/spec/plans/development-stages.md` for the 8-stage build plan.
See `docs/spec/plans/execution-plan.md` for the orchestration runbook (ralph, team, ultraqa).
Do not read folder `docs/archived`

## Architecture-as-source-of-truth policy
[`docs/spec/architecture.md`](docs/spec/architecture.md) is the **single source of truth** for component inventory, key inventory (K1–K11), trust boundaries, identity model (HDKD actor tree), and per-actor binding ceremonies. **After editing any architectural doc** (broker plans, signer-protocol, demo doc, runbooks, plan files in `docs/spec/plans/`, heima-gaps), re-open `architecture.md` and verify it still matches; if it diverges, update arch.md in the same change. If the per-doc detail outgrows arch.md, link from arch.md outward — never duplicate. The wiki page at [`.omc/wiki/agent-role-and-usage-hdkd-per-agent-omni.md`](.omc/wiki/agent-role-and-usage-hdkd-per-agent-omni.md) is a focused operator reference for the agent role; it defers to arch.md.

## Version Control
Use `jj` (Jujutsu) for all version control. Never use raw `git` commands.

## Branch push policy (this branch: `evm`)
On the `evm` branch, after **every** code/doc update that lands a `jj describe` (or amends the working change), push immediately with `jj git push`. The remote broker host pulls from `origin/evm` via `scripts/setup-broker-host.sh --upgrade`, so an unpushed local commit means the deploy script silently picks up the previous revision. No "I'll push at the end" — push per change.

## Diagnosis-before-edit policy
Before changing any file in response to a reported failure, **reproduce the failure locally** and isolate the layer (shell quoting, client tooling, doc command, broker code, network). If the cause is local (shell, copy-paste, env var), respond with the one-line fix and let the user run it — do NOT edit code or docs. Only edit when the cause is in the repo. Keep the response concise: failing command, root cause, fix command — nothing else.

## Land-the-fix policy
Once a local repro proves a fix is correct, **land it the same turn**: edit every affected file (search repo-wide — never assume one file), commit, push to `origin/evm`. Do not stop at "verified locally" or "fixed in one place" — the next operator running the docs will hit the same bug if the fix isn't on `origin/evm`. Pair this with the diagnosis-before-edit policy: diagnose once, fix everywhere, push immediately.

## Runbook-fix-fold-back policy
When the user is walking through a runbook (`docs/cloud-setup.md`, `docs/stage7-demo-and-verification.md`, `docs/operator-runbook-stage7.md`, etc.) and hits a step that fails, **two things must land in the same turn**:

1. The targeted fix to whatever broke (script default, env var, doc command, code).
2. **A revision to the runbook itself** so the next operator running it top-to-bottom will not hit the same failure. The fix lives wherever the bug was; the runbook revision lives wherever the operator first encounters the broken step.

Examples of revisions to land alongside the underlying fix:
- A failing prerequisite check → upgrade the prereq sanity-check step to catch the same case (not just fix the missing prereq once).
- A wrong env var on the wrong machine → call out the laptop-vs-broker-host scope explicitly in the runbook step that uses it.
- A silent skipped action that downstream commands rely on → add a verify-and-fail-loud sanity check in the runbook between the action and its dependent.
- A confusing diagnostic that took two rounds to resolve → fold the diagnosis steps inline into the runbook (one-shot lookup table, not 3 round-trips with the operator).

The goal: every operator-encountered failure makes the runbook strictly more robust before we move on. Never leave the runbook in a state where the same operator (or the next one) will hit the same trap.

## Plan-completion policy
When the user references a plan (e.g. `docs/spec/plans/issue-XX-*.md`), **complete every numbered step in the plan's implementation-order table — not a self-selected subset**. If you cannot complete a step (interactive flow needs human, scope explosion, prerequisites missing), say so up front before starting work and get explicit approval to defer. Never silently drop steps and ship a partial plan as "done."

The end-of-PR summary is mandatory and has two sections in this exact order:

1. **What landed** — bulleted list of every plan step you finished, with file paths.
2. **What did NOT land** — every plan step you skipped, with the reason and what unblocks it. If the section is empty, say so explicitly ("All plan steps shipped.").

Do not bury skipped work in a footnote, in a note partway through prose, or in a doc that the user has to dig for. The summary is the authoritative answer to "is this PR plan-complete?" — make it answerable from a glance.

Also: never gloss over a partial implementation in a demo doc or runbook. If the demo walks through a flow that is only half-shipped, the doc must state which half is shipped and which still requires manual setup or a follow-up PR. Operators reading the doc cannot tell which is which from prose alone.

## Remote broker host (single entry point)
All remote-host changes (binary upgrades, systemd edits, nginx/certbot, env tweaks, mock-server redeploys) MUST go through `bash scripts/setup-broker-host.sh` — it's idempotent and auto-detects bootstrap vs upgrade. No ad-hoc `systemctl` edits or hand-built `scp`.

## Development Workflow (Anthropic Harness Pattern)

On every session start:
1. `jj log --limit 10 && cat harness/progress.json && bash harness/init.sh $(jq -r .current_stage harness/progress.json)`
2. Read the stage contract for your current stage in `docs/spec/plans/development-stages.md`
3. Pick the HIGHEST-PRIORITY incomplete deliverable from `harness/features.json`
4. Implement ONE deliverable
5. Run tests: `cargo test -p <crate>` for the affected crate
6. Describe: `jj describe -m "agentkeys: stage N -- <deliverable name>"`
7. Update `harness/features.json` (set `implemented: true`) and `harness/progress.json`
8. New change: `jj new -m "harness: update progress"`

## Stage Completion Protocol
1. Run `bash harness/stage-N-done.sh` -- must exit 0
2. `jj bookmark create stage-N-done` (bookmark marks the completion point)
3. Update `harness/progress.json`: set stage status to "complete"
4. `jj describe -m "harness: stage N complete"`
5. `jj new` (start fresh change for next stage)

## Code Conventions
- Rust: `thiserror` for library errors, `anyhow` for binary errors
- All async: `tokio` runtime, `#[tokio::test]` for async tests
- Crate names: agentkeys-types, agentkeys-core, agentkeys-cli, agentkeys-daemon, agentkeys-mock-server, agentkeys-mcp, agentkeys-provisioner
- Git commits: `agentkeys: stage N -- <deliverable>`
- Never self-grade: run `bash harness/stage-N-done.sh` to verify

## Mock Server Design Principles
The mock server mirrors Heima blockchain extrinsics. Follow these rules:
- **Typed parameters**: Every endpoint must accept explicit typed inputs (e.g., `identity_type` + `identity_value`), never parse opaque JSON blobs to guess types at runtime. Blockchain extrinsics require typed parameters -- the mock must enforce the same contract.
- **Shared identity resolution**: Use a single `resolve_identity(db, identity_type, identity_value) -> Result<String>` utility in `handlers/identity.rs` for all identity-to-wallet lookups. Never inline if/else chains per identity variant.
- **Modular handlers**: Split request-type-specific logic into separate functions (e.g., `mint_pair_session()`, `mint_recover_session()`). The `approve_auth_request` handler dispatches to these, not inline everything.

## Test Commands
```
cargo test -p agentkeys-types
cargo test -p agentkeys-core
cargo test -p agentkeys-mock-server
cargo test -p agentkeys-cli
cargo test -p agentkeys-daemon -p agentkeys-mcp
cargo test -p agentkeys-provisioner
npm test --prefix provisioner-scripts
```

