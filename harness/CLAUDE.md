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

## Hand-rolled cap/worker bodies — drive the CLI, or annotate + gate (issue #203)

The broker/worker request shapes have ONE owner — the `agentkeys-backend-client`
crate (see root [`../CLAUDE.md`](../CLAUDE.md) "Broker/worker request shapes have
ONE owner"). For harness scripts that means:

- **Real-path steps drive the shared client**, not raw curls — `agentkeys memory
  put …` routes through the MCP server's `HttpBackend` → the shared client, so the
  agent path can't drift. Prefer that over hand-rolling `jq -n '{…}'` cap/worker
  bodies.
- **A hand-rolled body that IS meant to mirror a wire shape** (the few real-path
  probes + any negative test that sends a *well-formed* body) carries a
  `# @backend-fixture: <shape>` comment **on the line directly above the jq object
  literal** (`<shape>` ∈ `cap_mint_request`, `memory_put_body`, `memory_get_body`,
  `audit_append_v2`). [`../scripts/check-backend-fixture-drift.sh`](../scripts/check-backend-fixture-drift.sh)
  diffs that body's key-set against the crate-emitted fixture in
  [`fixtures/backend-protocol/`](fixtures/backend-protocol/) and fails CI on drift
  (the `harness-ci.yml` `rust-checks` job runs it). Place the annotation so the
  **next `{`** after it is the object literal (e.g. *inside* a function body, not
  above the `fn() {` line) — the gate extracts the first brace-balanced literal.
- **Deliberately-malformed negative-test payloads are NOT annotated** — they're
  supposed to be wrong (wrong data class, missing field, cross-actor omni). Only
  annotate bodies that should match canonical.
- **Changing a wire field** is a crate change, never a bash-only edit: edit
  `agentkeys-backend-client::protocol`, regenerate fixtures (`cargo run -p
  agentkeys-backend-client --bin dump-protocol-fixtures`), update the frozen
  key-set test, then fix every annotated bash body to match.

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
  K11 (`WEBAUTHN_MODE=0`), the **mock agent** for the agent-side steps (the sole
  sanctioned synthetic agent, contract rule 5), and **stage-1 auto-skips
  deploy/email/provision** (CI runs against pre-provisioned infra — contracts pinned,
  wallet_sig identity, buckets/roles an operator one-shot). Tolerates prereq skips.
  `harness-ci.yml` runs the WHOLE orchestrator — **`v2-demo.sh --ci` → phases 1–4 + 6**
  (phase 5/wire auto-skips: no aiosandbox). So phase 6 (the daemon web-chain runtime
  proof) IS exercised in CI; the only phase CI can't run is the sandbox-bound wire.

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
| **`v2-demo.sh`** | **THE single entry point — no flags = phases 1→2→3→4 (memory plant)→5 (wire)→6 (web↔agent parity); wire auto-runs when the aiosandbox is up, else reports INCOMPLETE + exits non-zero (an unexecuted proof is never green — pass `--wire none` to intentionally skip); fail-fast. `PHASE.STEP` addressing (`--from 4.1`, `--only 3.11`). Flags are CI/scoping only.** | (no flags) / `--ci` / `--stage N` / `--from P.S` / `--only P.S` / `--wire real\|light\|none` |
| `v2-stage1-demo.sh` | M1 foundation demo | `--only-step N` |
| `v2-stage2-demo.sh` | hardening demo | `--only-step N` |
| `v2-stage3-demo.sh` | OIDC + per-actor/data-class isolation proof (23 steps; 16–17 = #196 master-self + cross-actor scope; **19–21 = #201 Config data-class isolation** — master-self layer-3/4 + cap data-class-mismatch, run on the operator, `skip` until config infra is provisioned/deployed; **22 = #207 classifier-worker isolation** — master-self `cap_op_mismatch` (storage cap → classify worker) + `cap_data_class_mismatch` (cross-data-class Classify cap), compute-gate so NO STS, `skip` until the worker is deployed; **23 = cleanup + summary**). **Steps 11-12 / 14-15 sign STS creds AS the agent: on the operator they `defer` to the sandbox (the §10.2 agent key lives in the sandbox) — GREEN, never fail. `--mock-agent` (CI-only, auto-on under `--ci`) provisions a master-held DEV agent so headless CI can prove the roundtrip; a real §10.2 agent proves it in-sandbox via `phase1-wire-demo.sh --real`.** | `--from/--to/--only-step` / `--mock-agent` |
| `phase1-wire-demo.sh` | agent-side `agentkeys wire` demo (real memory only — the in-memory `--light` path was removed, #207); **phase 5 of `v2-demo.sh`** — pairs the §10.2 agent in the sandbox so the On-Sandbox proof (`sandbox-agent-isolation.sh`) can run. **v2-demo runs it `--real --webauthn`** so the master grants the agent's `memory:<ns>` scope (Touch ID); the agent's cap service is `memory:<ns>`, so without the grant `memory.get` → `service_not_in_scope`. | `--real` (default) / `--webauthn` |
| `web-memory-bootstrap.sh` | issue #196 web-memory pre-flight + proof; runbook [`../docs/operator-runbook-web-memory.md`](../docs/operator-runbook-web-memory.md) | `--from/--to/--only-step` |
| `memory-plant-demo.sh` | plant a proof memory archive through the REAL chain + read-back (the CLI/CI proof of the plant flow the web "⊕ plant prepared memory" button drives); **phase 4 of `v2-demo.sh`**. Plants into **dedicated `demo-*` namespaces** (never the real travel/personal/family) and **always deletes them on exit** (success OR failure, EXIT trap; `KEEP_DEMO_MEMORY=1` keeps), so test memory never leaks into the master's real store — the real prepared archive is planted ONLY by the user (the button), never by a demo or onboarding. Re-testable; idempotent (`--from 4.1`). | `--from-step/--only-step N` / `--ci` |
| `web-parity-demo.sh` | **phase 6 of `v2-demo.sh`** (NOT a standalone front door) — boots `agentkeys-daemon --ui-bridge` SEEDED with the master's J1 + device via the `--ui-bridge-seed-*` daemon seam (skips re-onboarding) + plants a **dedicated `webparity` probe ns** through the **web** endpoint `POST /v1/master/memory/plant`, **deleted on exit** (success or failure). A 200 proves the daemon's chain (cap-mint → STS → worker → S3) == the agent/harness chain — the web↔harness drift gate. **Step 4 (#214)** additionally polls `GET /v1/agent/pairing/pending` and asserts a well-formed `{requests:[…]}` — the master-side web-pairing route reaches the real broker rendezvous (the full claim→register e2e needs a live §10.2 agent request, exercised agent-side). Reuses phases 1-2's build/chain/broker/master (one daemon boot, no re-bootstrap); real-only. | `--from-step/--only-step N` / `--ci` |
| `cred-fetch-demo.sh` | **#216 agent-side vaulted-key fetch, real e2e** (standalone). A master **vaults** a probe credential via the daemon (web path: cap-mint cred-store → STS → cred worker → S3), then the **agent** fetches it back with `agentkeys cred fetch` (CLI path: cap-mint cred-fetch → STS → cred worker → **decrypt**), asserting the EXACT secret round-trips. Proves the cred half of "the agent uses the key the master authorized it to use" (the Hermes wire is phase1-wire #216 Phase 4.0). Routes through the shared `agentkeys-backend-client` (no re-typed shapes, #204). Idempotent (a FIXED `cred-e2e-probe` service is overwritten each run — never accumulates); daemon killed on exit; real-only. | `--from-step/--only-step N` / `--ci` |

(`scripts/setup-heima.sh` + `scripts/setup-broker-host.sh` are the canonical
single-entry orchestrators for chain bring-up + the remote broker host; harness
scripts assume those have run.)

## Parity/wiring checks evolve down a ladder — `web-parity-demo.sh` (phase 6) is meant to SHRINK

A parity check ("the web flow does the same as the agent flow") is the most
deceptively fragile kind of test: it asserts behavior at **runtime**, so it rots
**silently** (stale green) the day either side moves. Don't plan to babysit phase 6
forever — plan to **dissolve it into the type system** as
[#203](https://github.com/litentry/agentKeys/issues/203) (the shared backend-client
crate) lands.

**Phase 6's old blind spot (now CLOSED by #203/#204):** step 3 `curl`s the daemon
endpoint directly (`POST /v1/master/memory/plant`) with a hand-built body; the real
frontend (`apps/parent-control/lib/client/daemon.ts`) builds its OWN body at the same
URL. They used to agree by manual coincidence — a `daemon.ts` endpoint/shape change
left phase 6 **green on the old path** (false-green). That gap is now gated: the route
+ the `ApiMemoryEntry` body shape have ONE source of truth (the daemon's
`MASTER_MEMORY_{,PLANT_}ROUTE` const + the struct), pinned to
[`fixtures/web-api/master_memory_plant.json`](fixtures/web-api/master_memory_plant.json)
by a `ui_bridge` unit test, and BOTH consumers (`daemon.ts` + `web-parity-demo.sh`)
are diffed against it by [`../scripts/check-web-api-drift.sh`](../scripts/check-web-api-drift.sh)
in CI. A rename/added/dropped field or a route change on either side is now CI-red.
What phase 6 still uniquely proves (and can't be compile-checked) is the **runtime
wiring**: "daemon → cap-mint → STS → worker → S3 is reachable on real infra."

**The ladder (weakest → strongest) — push a check DOWN it whenever it catches real drift:**
1. **Runtime behavioral assertion** (run both, compare) — rots silently.
2. **Shared contract / golden fixture** — both sides derive from one serde schema;
   CI reddens loudly on shape drift, survives cosmetic refactors. ← the daemon
   web-API plant contract sits here now (the `master_memory_plant` fixture + the
   `daemon.ts`/`web-parity-demo.sh` gate).
3. **Shared implementation** — one code path; violating parity is a compile error.
   The runtime check shrinks to a thin "is the one client wired to real infra?" smoke.
   ← the broker/worker chain is here (#203/#204: daemon + MCP share
   `agentkeys-backend-client`). Phase 6's body shape is rung 2; its remaining job is
   the rung-3-residual runtime-wiring smoke.

**Operating rule:** every time phase 6 (or any parity/wiring check) catches a real
drift, ask "could this have been a compile error or a fixture diff instead?" If yes,
move the assertion down the ladder — the runtime check is *supposed* to get thinner.
A parity check growing in scope is a smell; one shrinking toward a wiring smoke is
healthy. **Done (#203/#204):** the false-green is plugged — the plant route + body
shape are a single serde source of truth gated by `scripts/check-web-api-drift.sh`
(fold-systemic-fixes-into-enforcement). The next rung-down for phase 6 is tier-3 for
the frontend: compile the daemon ui-bridge plant types into the browser host via
`agentkeys-web-core` (wasm) so `daemon.ts` stops hand-building the body at all.

---

<!-- The three sections below were EXTRACTED from the root CLAUDE.md (they are
harness-specific, so they live here now and are loaded when working on harness/). -->

## Agent-side wire demo — REAL memory only (`harness/phase1-wire-demo.sh`)

The agent-side wire demo (`agentkeys wire hermes` inside the aiosandbox) exercises the **real memory worker only** — that is now the *only* path the MCP server has. The sandbox MCP runs `--backend http`, and every `agentkeys.memory.get/put` goes broker cap-mint → per-actor STS relay (`X-Aws-*`) → `memory.litentry.org` → S3 (`bots/<actor>/memory/`). **The in-memory fixture backend was REMOVED (#207, real-data-only)** — there is no `--light` / `--backend in-memory` fake-Chengdu path anymore; `phase1-wire-demo.sh` is `--real`-only (passing `--light` errors). When demoing or QA-ing the agent's memory, assert against the real worker, or directly: `agentkeys hook memory-inject --namespaces travel </dev/null` (returns the real S3 content) / the live S3 object `bots/<actor>/memory/memory.enc`.

**Two distinct memory systems — never conflate them:**
1. **Real AgentKeys memory** (the only one the demo proves, and the only backend the MCP server has): MCP `http` backend → worker → S3. Source of truth.
2. **Hermes native session memory** (`recall` / `session_search`): the runtime's own store — **NOT** AgentKeys memory. Wiping Hermes "session memory" does not touch the real worker, and Hermes' native `recall` will never return AgentKeys content.

(The former third system — an in-memory MCP fixture — was removed with the in-memory backend. There is no fake/seeded memory path to conflate anymore.)

**No conflict with "passive injection":** passive injection (the `pre_llm_call` hook prepending memory each turn) is the *delivery mechanism* (when/how memory reaches Hermes), orthogonal to the *source*. The passively-injected block IS the real worker memory — they are the same bytes, just delivered automatically. The rule is only about the SOURCE: real worker, never Hermes-native.

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
