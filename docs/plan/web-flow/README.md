# docs/plan/web-flow — parent-control web UI · operator user flow plan

**Status:** plan (not implementation). Pending review.
**Source of truth this plan defers to:** [`docs/arch.md`](../../arch.md) (§22c app surface, **§22d IAM-guarantee delivery**), [`docs/agent-iam-strategy.md`](../../agent-iam-strategy.md), [`docs/operator-runbook-wire.md`](../../operator-runbook-wire.md), [`docs/user-manual.md`](../../user-manual.md), [`docs/wiki/agent-iam-guarantee-glossary.md`](../../wiki/agent-iam-guarantee-glossary.md), and the harness scripts [`harness/v2-stage{1,2,3}-demo.sh`](../../../harness/) (master onboarding) + [`harness/phase1-wire-demo.sh`](../../../harness/phase1-wire-demo.sh) (the agent wire flow).

> **Redesigned 2026-05-31 after PRs [#140](https://github.com/litentry/agentKeys/pull/140) + [#141](https://github.com/litentry/agentKeys/pull/141) merged.** The agent half of the flow ([`stage3-agent-usage.md`](stage3-agent-usage.md)) was rebuilt around the **Authority-Host / Task-Host** model: AgentKeys installs **IAM-guarantee hooks** (`agentkeys wire`) the LLM can't bypass, and the agent's key is **born in its own runtime** (`agentkeys agent device-session`), never on the master. The master-onboarding half ([`stage1`](stage1-first-run.md) / [`stage2`](stage2-second-master.md)) is unchanged.

## Why this plan exists

The harness scripts (`harness/v2-stage{1,2,3}-demo.sh`, 43 numbered steps in total) are the real flows operators run today — but as shell commands an engineer fires from a terminal. The parent-control web UI must surface every one of those steps as a **natural operator user flow** — meaning:

- the operator types the same inputs (real email, real device password, real seed import) the harness expects;
- the order is the same as the script (because the dependencies are real: K11 can't enroll before identity, scope can't grant before chain bring-up);
- the UI never invents data the harness wouldn't (no mock actors, no synthetic email aliases used as if they were the operator's actual email);
- pre-existing daemon / CLI behaviour is reused — the UI is a *thin transport over the same engine*, not a parallel re-implementation.

This directory contains the design. Implementation lands as separate PRs that reference these docs.

## File map

| File | Scope |
|---|---|
| [`overview.md`](overview.md) | End-to-end narrative the first-time operator walks through · state-machine sketch · resumability invariants |
| [`stage1-first-run.md`](stage1-first-run.md) | Harness `v2-stage1-demo.sh` 16 steps → UI screens. Identity, K10, K11 WebAuthn, AWS infra, chain bring-up, first master register, first agent. |
| [`stage2-second-master.md`](stage2-second-master.md) | Harness `v2-stage2-demo.sh` 11 steps → UI screens. Companion-device pairing, recoveryThreshold=2, M-of-N quorum revoke ceremony. |
| [`stage3-agent-usage.md`](stage3-agent-usage.md) | **(redesigned for #141)** Add an agent: **pair** (`agentkeys agent device-session` — key born in the runtime) → **wire** (`agentkeys wire` installs IAM-guarantee hooks) → the **three acts** (permissioned memory / deterministic denial / audit) + the memory surprise. Plus the hook-aware live dashboard and the preserved 16-step isolation health check. Maps `harness/phase1-wire-demo.sh`. |
| [`input-discipline.md`](input-discipline.md) | Which inputs the operator types vs the system derives vs the system auto-generates. Resolves the operator-login-email vs agent-inbox-address distinction explicitly. |
| [`data-model.md`](data-model.md) | The HTTP surface the daemon must expose for the UI to drive these flows. Concrete request/response shapes, persistence boundaries, what's local vs chain-anchored. |
| [`deferred-and-followups.md`](deferred-and-followups.md) | What stays shell-only forever (operator power-user paths). Open questions for review. Implementation sequencing if approved. |
| [`wire-real-paths.md`](wire-real-paths.md) | The "wire to real backends" implementation plan (W/X phases): replace stubs with real broker/worker/chain calls; the phone-first WASM-core path. |
| [`wire-real-paths-security-review.md`](wire-real-paths-security-review.md) | Security review of the wire-real-paths plan (trust boundaries, bearer handling, CORS). |
| [`issue-9step-flow.md`](issue-9step-flow.md) | The 9-step operator flow mapped to issues #149/#137/#138. |
| [`web-wire-test-runbook.md`](web-wire-test-runbook.md) | **Test runbook**: how to exercise the web app against the live broker/workers/Heima, mirroring [`harness/phase1-wire-demo.sh`](../../../harness/phase1-wire-demo.sh). Honest map of what's UI-wired today (daemon mode: onboarding K11, memory plant/list, revoke, audit reads) vs the task-2 gaps (pairing / cap-mint / scope-grant / wallet-activation screens), with the on-chain/S3/CLI cross-checks. |

## How to read

Start with [`overview.md`](overview.md) for the narrative. Then read [`input-discipline.md`](input-discipline.md) — it locks down terminology that the other three stage docs lean on. After that, the three stage docs can be read independently in any order.

`data-model.md` is the contract between the UI and the daemon; it's the one engineering will iterate on most. `deferred-and-followups.md` collects the questions that need an answer before any of this can land.

## Cross-references

- arch.md is the canonical reference for K1–K11 (the key inventory), HDKD actor tree (§6.2), ceremony shapes (§10), worker isolation invariants (§17.2, §15), and the AgentKeys app surface (§22c).
- The wiki page [`docs/wiki/agent-role-and-usage-hdkd-per-agent-omni.md`](../../wiki/agent-role-and-usage-hdkd-per-agent-omni.md) is the operator-facing summary of the agent role; this plan refers to it instead of re-stating.

## What this plan does NOT cover

- **Mobile-native iOS/Android.** Per [issue #110](https://github.com/litentry/agentKeys/issues/110), mobile-native lands in M5 after vendor pilot. The "mobile companion as second master" page in stage 2 is a real *cross-device WebAuthn hybrid-transport* flow inside a browser on the phone — not a native app.
- **K3 epoch rotation runbook.** That's in [`docs/runbook-k3-rotation.md`](../../runbook-k3-rotation.md), an operator-only flow today. A web-flow promotion is tracked in [`deferred-and-followups.md`](deferred-and-followups.md) §3.
- **Vendor branding / white-label.** M2 vendor pilot work.
