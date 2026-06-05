# Harness scripts — authoring contract

> **Operator runbook (how to RUN the demos):** [`../docs/operator-runbook-harness.md`](../docs/operator-runbook-harness.md). This file is the *authoring* contract.

These rules govern every script under `harness/` and `harness/scripts/`. They
extend (do not replace) the root [`../CLAUDE.md`](../CLAUDE.md) — in particular
the **idempotent-remote-setup rule**, the **no-hardcoded-values policy**, the
**per-profile `--region` trap**, and `AGENTKEYS_CHAIN=heima` (mainnet) as the
default chain. When you add or edit a harness script, follow this contract or it
doesn't ship.

## Keep the docs in sync — EVERY script change

**Every time you change a harness script** (a new flag, a new/renamed step, a new
script, a changed default, a new orchestrator) update BOTH in the **same change**:
1. the **operator runbook** [`../docs/operator-runbook-harness.md`](../docs/operator-runbook-harness.md)
   — its Quick Start commands (On Operator / On Sandbox / On CI), the CI-flag
   reference, and the Operator Q&A; and
2. **this file** — the orchestrator inventory + any authoring contract that moved.

A script change without the matching doc update is **incomplete**: the runbook is the
operator's source of truth and drifts silently otherwise. (Same spirit as the root
CLAUDE.md runbook-fix-fold-back policy, applied to every harness edit, not just fixes.)

## Two kinds of scripts

- **Orchestrators / demos** (`v2-stage{1,2,3}-demo.sh`, `phase1-wire-demo.sh`,
  `web-memory-bootstrap.sh`): a numbered sequence of steps, run top-to-bottom,
  each step idempotent. These MUST have the step/flag/logging contract below.
- **Per-action helpers** (`scripts/heima-*.sh`, `harness/scripts/heima-*.sh`):
  one mutation, idempotent, machine-readable result. Callable directly for
  surgical re-runs AND composed by the orchestrators.

## Required contract for orchestrators

1. **Step flags — mirror `setup-heima.sh` exactly.** Parse `--from-step N`,
   `--to-step N`, `--only-step N` (sets `FROM=TO=N`), and a `--help` that prints
   the header block. Define `STEP_TOTAL`, gate every step with
   `should_run_step N`, and number steps with an explicit literal (`step 6 "…"`),
   never an auto-increment counter — renumbering must not silently shift `N`.
2. **Three outcomes per step — `ok` / `skip` / `fail`.** Provide
   `step()/ok()/skip()/die()` helpers that log to **stderr** (color when
   `[ -t 2 ]`, plain otherwise). `ok` = mutation applied or verified; `skip` =
   idempotent no-op (already done / prereq absent in a tolerated way); `fail` =
   hard error (exit non-zero). A demo that gates coverage (skips a prereq) MUST
   make the skip visible in a final summary — never print "complete" while a
   layer silently didn't run (see `v2-stage3-demo.sh` `prereq_missing` +
   `STEP_OUTCOMES`; strict mode fails closed, `--allow-skip=<reason>` opts in).
3. **Idempotent — re-run = exit 0 without re-applying.** Every step pre-checks
   on-chain / on-AWS / on-disk state (`cast call`, `aws … head-*`, `[ -f … ]`)
   and short-circuits with `skip`. Re-running the whole script is always safe.
4. **Env from `operator-workstation.env`.** Compute `REPO_ROOT` from
   `$(dirname "$0")` and `set -a; . "$ENV_FILE"; set +a`. Honor
   `--test` → `operator-workstation.test.env` and an `ENV_FILE=…` override.
   Validate required vars up front (`: "${OIDC_ISSUER:?…}"`).
5. **No hardcoded values.** Paths, hosts, addresses, amounts, chain ids come
   from env / flags / `operator-workstation.env` / `agentkeys chain show`, never
   baked in. Temporary exceptions go in [`../hardcoded.md`](../hardcoded.md). **The one
   sanctioned synthetic agent:** CI may provision a **mock agent** (a master-held DEV
   agent, `demo-agent-dev`) for the agent-side wiring steps (stage 3 11-12) — CI has no
   sandbox, so the real §10.2 agent can't sign. That mock is **CI-only** (`--ci` /
   `--mock-agent`); operators **never** mock — they `defer` those steps to the sandbox.
6. **Deployer key via `_lib.sh`.** Source `harness/scripts/_lib.sh` and use
   `resolve_master_key` (raw-hex / mnemonic / `~/.agentkeys/heima-deployer.key`)
   — don't re-implement key resolution.
7. **Build when source changed.** If a step needs the binary, build it
   (`cargo build --release -p …`); cargo's incrementality keeps it idempotent. A
   stale install must never silently mask a code change.
8. **Compose, don't duplicate.** Delegate mutations to the per-action helpers
   (`heima-fund-master.sh`, `heima-register-first-master.sh`, …) rather than
   re-inlining `cast send`. Inline only a self-contained read/proof when
   cross-script state-dir coupling would be fragile.

## Required contract for per-action helpers

- **Idempotent pre-check + short-circuit**, per the root CLAUDE.md mutation
  table (contract deploy → `cast code`; chain tx → `cast call` view fn; fund →
  `cast balance`; keypair → `[ -f ]` never overwrite; etc.). **ERC-4337 register
  (`erc4337-register-master.sh`) pre-checks before EVERY mutation** — re-runs cost
  zero gas:
  - **Account deploy** — the address is **deterministic** (`factory.getAddress(credId,pubX,pubY,rpIdHash,salt)`, CREATE2); `cast code <addr>` non-empty ⇒ skip `createAccount`. Per-operator accounts are **not** recorded in `deployed-contracts.md` (they're re-derivable from the passkey) — re-derive + `cast code`, don't track.
  - **EntryPoint deposit** — `EntryPoint.balanceOf(account)` ≥ threshold ⇒ skip `depositTo`.
  - **Master register** — `operatorMasterWallet(omni) != 0` (operator already has a first master — `registerFirstMasterDevice` is first-master-ONLY) **OR** `isActive(deviceKeyHash)` ⇒ skip; report the ACTIVE device via `resolve_active_master_dkh` (it may be the #164 `keccak(omni)` or the legacy EOA `keccak(deployer_addr)`).
- **Shared/singleton contracts: read addresses, never re-deploy or hardcode.**
  The registry, scope, EntryPoint, factory, and verifiers are recorded in
  [`../docs/spec/deployed-contracts.md`](../docs/spec/deployed-contracts.md) and
  mirrored into `operator-workstation.env` (`SIDECAR_REGISTRY_ADDRESS_*`,
  `ENTRYPOINT_ADDRESS_*`, `P256_ACCOUNT_FACTORY_ADDRESS_*`, …). Scripts **source
  those addresses**, never deploy them and never bake a literal address in. Verify
  the live set with `verify-heima-contracts.sh` (read-only). A new singleton deploy
  is recorded in `deployed-contracts.md` + `env_set` into `operator-workstation.env`
  in the same change (per the root CLAUDE.md deployed-contract-registry rule).
- **Result on stdout, logs on stderr.** Emit a single machine-readable JSON line
  on stdout (`{"ok":true,…,"tx_hash":…}` or `{"ok":true,"skipped":"…"}`); all
  human logs go to stderr. Orchestrators + the daemon parse that JSON line.
- **`--dry-run`** that prints the intended `cast`/`aws` call (private key
  redacted) and the JSON without mutating.
- **Back-compat additively.** New flags default to the prior behavior so every
  existing caller (no flags) is byte-for-byte unchanged (e.g.
  `heima-register-first-master.sh`'s `--operator-omni`/`--k11-cose-hex` web-path
  overrides default to the legacy deployer-derived values).

## Mainnet + funding posture

- Demos run on **Heima mainnet** (`AGENTKEYS_CHAIN=heima`); the deploy wallet
  funds test accounts. Never silently downgrade to a testnet — export `heima` if
  unset. Stage-1 stubs require `AGENTKEYS_ALLOW_STAGE1_STUBS=1` / the H2 gate.
- Funding helpers fund **from the deployer**, idempotent skip-if-funded, and are
  **operator-run / one-time** — never a broker endpoint and never auto-on-login
  (a per-login auto-fund is a Sybil drain on the deployer).

## Master registration — go through `register_first_master` (`_lib.sh`)

Never register the first master inline. Call `register_first_master [operator_omni]`
(stage 1 step 10, stage 2, `web-memory-bootstrap.sh` step 5 all do). The **#164
passkey-account ERC-4337 register is the ONLY supported path** (`erc4337-register-master.sh`
default action → `operatorMasterWallet[omni]` = the passkey-controlled `P256Account`).
The "passkey" has two implementations of the *same* #164 flow, **both in the Rust CLI
(no python; `crates/agentkeys-cli/src/k11_webauthn.rs`)**: a **hardware authenticator**
(Touch ID / Secure Enclave — `agentkeys k11 webauthn-{keygen,userop-sign}`, which sign
the `userOpHash` via a localhost WebAuthn ceremony) and a **software P-256 passkey**
(`agentkeys k11 software-{keygen,sign}` — a file key, no biometric). (The old
`harness/scripts/erc4337-webauthn-sign.py` is **deprecated, reference-only** — a readable
byte-layout spec; the Rust software port is byte-identical, verified `true` on mainnet.)
**The old-model EOA register is DEPRECATED** — never an automatic fallback; escape-only
via `AGENTKEYS_REGISTER_MODE=eoa`.

Run mode picks **BOTH skip-tolerance AND the signer** — **no flag = local → HARDWARE,
`--ci` = CI → SOFTWARE** (sets `AGENTKEYS_CI=1`; the runner's own `$CI` is also honored):
- **Local (no flag) → HARDWARE Touch ID:** `register_first_master` runs the **hardware**
  register (the operator approves a Touch ID prompt; no on-disk key). It **fails loud**
  (return 1) if prereqs (`cast`/the `agentkeys` binary/EntryPoint/factory) are missing or
  the ceremony fails. A real local test always exercises Touch ID; NEVER falls back to EOA.
- **`--ci` → SOFTWARE:** the file-key signer (no biometric — CI/test only, the CLI prints
  a `WARN`) **and** TOLERATES a `skip` (return 0) when prereqs are unavailable. Still NEVER EOA.
- Passed through as `erc4337-register-master.sh --signer hardware|software`
  (env `AGENTKEYS_REGISTER_SIGNER`); default `hardware`. The register **skips before any
  ceremony** when the operator already has a first master (no wasted Touch ID prompt).

`device_key_hash = keccak(operator_omni)`, so any downstream master cap-mint uses
`keccak(operator_omni)` (the agent device path is unchanged — agents are not #164
accounts yet). The build/submit sub-commands of
`erc4337-register-master.sh` are the two-phase hooks the daemon web-flow uses
(browser passkey signs `userOpHash`); the default no-sub-command action is the
all-in-one register (hardware or software per `--signer`). ERC-4337 register is **E7 pre-cutover** — see
[`../docs/plan/chain/erc4337-master-account.md`](../docs/plan/chain/erc4337-master-account.md) §3.1.

## Operator vs Sandbox vs CI — the three roles (+ the fresh-ceremony rule)

Every orchestrator + the operator runbook MUST keep this split exact:

- **OPERATOR (no flag) — local, real, re-testable.** A local run is a genuine onboarding
  **ceremony**: master register + K11 enroll + scope-set each fire a real **Touch ID**
  prompt. `WEBAUTHN_MODE` / `USE_WEBAUTHN` default to **1** for the operator and **0** only
  under `--ci` / `$CI` — operators get the biometric ceremony WITHOUT a flag. It runs
  **only the operator/master-side tests**; the **agent-side** steps (stage 3 11-12, signed
  AS the agent) **`defer`** to the sandbox — never a failure, never mocked on the operator.
- **SANDBOX — the real §10.2 agent.** The agent's K10 lives in the sandbox, so the agent-side
  roundtrip runs THERE (`phase1-wire-demo.sh --real` pairs it; `sandbox-agent-isolation.sh`
  runs the deferred roundtrip with the sandbox-held key via `sbx_exec`). The master never
  signs for the agent. This is the real agent-side coverage.
- **CI (`--ci`) — headless, no biometric, no sandbox.** Software register (no Touch ID), stub
  K11 (`WEBAUTHN_MODE=0`), and the **mock agent** for the agent-side steps (the sole
  sanctioned synthetic agent, contract rule 5). Tolerates prereq skips.

**Fresh-ceremony / re-testable rule:** an operator run must EXERCISE the ceremony (Touch ID),
not silently skip it — never let a re-run look "tested" while the biometric never fired.
Idempotent skips are for already-applied **chain state** (a registered master, a granted
scope), NOT for hiding the ceremony. So: the register short-circuits when the master already
exists (first-master-only — can't re-register), but K11 enroll + scope-set re-fire Touch ID
on the operator; a fully fresh onboarding uses a **fresh master identity**. CI mirrors this
with the stub (re-testable, no biometric). The stage-3 summary's `defer` count (agent-side →
sandbox) is **GREEN**, never fail/incomplete.

## Orchestrator inventory (keep current)

| Script | Goal | Entry |
|---|---|---|
| **`v2-demo.sh`** | **THE single entry point — no flags = phases 1→2→3→4 (memory plant)→5 (wire); wire auto-runs when the aiosandbox is up, else reports INCOMPLETE + exits non-zero (an unexecuted proof is never green — pass `--wire none` to intentionally skip); fail-fast. `PHASE.STEP` addressing (`--from 4.1`, `--only 3.11`). Flags are CI/scoping only.** | (no flags) / `--ci` / `--stage N` / `--from P.S` / `--only P.S` / `--wire real\|light\|none` |
| `v2-stage1-demo.sh` | M1 foundation demo | `--only-step N` |
| `v2-stage2-demo.sh` | hardening demo | `--only-step N` |
| `v2-stage3-demo.sh` | OIDC + per-actor/data-class isolation proof (steps 16–17 = #196 master-self + cross-actor scope). **Steps 11-12 / 14-15 sign STS creds AS the agent: on the operator they `defer` to the sandbox (the §10.2 agent key lives in the sandbox) — GREEN, never fail. `--mock-agent` (CI-only, auto-on under `--ci`) provisions a master-held DEV agent so headless CI can prove the roundtrip; a real §10.2 agent proves it in-sandbox via `phase1-wire-demo.sh --real`.** | `--from/--to/--only-step` / `--mock-agent` |
| `phase1-wire-demo.sh` | agent-side `agentkeys wire` demo (real memory only); **phase 5 of `v2-demo.sh`** — pairs the §10.2 agent in the sandbox so the On-Sandbox proof (`sandbox-agent-isolation.sh`) can run | `--real` / `--light` |
| `web-memory-bootstrap.sh` | issue #196 web-memory pre-flight + proof; runbook [`../docs/operator-runbook-web-memory.md`](../docs/operator-runbook-web-memory.md) | `--from/--to/--only-step` |
| `memory-plant-demo.sh` | plant the master's prepared memory archive through the REAL chain + read-back (the CLI/CI equivalent of the web app's "⊕ plant prepared memory" button); **phase 4 of `v2-demo.sh`**, re-testable on the master's own reserved prefix `bots/0x<O_master>/memory/` (idempotent — `--from 4.1` to re-run) | `--from-step/--only-step N` / `--ci` |

(`scripts/setup-heima.sh` + `scripts/setup-broker-host.sh` are the canonical
single-entry orchestrators for chain bring-up + the remote broker host; harness
scripts assume those have run.)

---

<!-- The three sections below were EXTRACTED from the root CLAUDE.md (they are
harness-specific, so they live here now and are loaded when working on harness/). -->

## Agent-side wire demo — REAL memory only (`harness/phase1-wire-demo.sh`)

The agent-side wire demo (`agentkeys wire hermes` inside the aiosandbox) MUST exercise the **real memory worker only**. Run it `--real`: the MCP server uses `--backend http`, and every `agentkeys.memory.get/put` goes broker cap-mint → per-actor STS relay (`X-Aws-*`) → `memory.litentry.org` → S3 (`bots/<actor>/memory/`). **Never use `--light` / `--backend in-memory` for any demo memory assertion** — that backend auto-seeds a fake Chengdu fixture (actor `0xa0c7…`) and is a dev-loop convenience only, NOT a real-memory proof. When demoing or QA-ing the agent's memory, assert against the real worker (`--real`), or directly: `agentkeys hook memory-inject --namespaces travel </dev/null` (returns the real S3 content) / the live S3 object `bots/<actor>/memory/memory.enc`.

**Three distinct memory systems — never conflate them:**
1. **Real AgentKeys memory** (the only one the demo proves): MCP `http` backend → worker → S3. Source of truth.
2. **In-memory fixture** (light mode): fake, dev-only. Forbidden in demo assertions.
3. **Hermes native session memory** (`recall` / `session_search`): the runtime's own store — **NOT** AgentKeys memory. Wiping Hermes "session memory" does not touch the real worker, and Hermes' native `recall` will never return AgentKeys content.

**No conflict with "passive injection":** passive injection (the `pre_llm_call` hook prepending memory each turn) is the *delivery mechanism* (when/how memory reaches Hermes), orthogonal to the *source*. In `--real` mode the passively-injected block IS the real worker memory — they are the same bytes, just delivered automatically. The rule is only about the SOURCE: real worker, never the in-memory fixture, never Hermes-native.

## Development Workflow (Anthropic Harness Pattern)

On every session start:
1. `jj log --limit 10 && cat harness/progress.json && bash harness/init.sh $(jq -r .current_stage harness/progress.json)`
2. Read the milestone scope for the current milestone in `docs/plan/milestones-roadmap.md` (the v1/v2 stage framing is archived at `docs/archived/development-stages-v2-2026-04.md`)
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
