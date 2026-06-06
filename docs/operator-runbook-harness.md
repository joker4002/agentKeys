# Operator runbook — the AgentKeys harness (the single runbook for every demo)

The ONE doc to run any harness demo — the v2 stages (1/2/3), the **#164 passkey-account
ERC-4337 master register**, the **agent-side wire test**, and **memory planting**. For
*authoring* harness scripts see [`../harness/CLAUDE.md`](../harness/CLAUDE.md); deeper
per-area docs ([wire](operator-runbook-wire.md), [web-memory](operator-runbook-web-memory.md))
are linked inline but you should not need them to run a demo.

> **Heima mainnet** (`AGENTKEYS_CHAIN=heima`, chainId 212013) — the deploy wallet funds
> test accounts; no testnet shortcut. Every script is **idempotent**; re-running is safe.

## Quick Start

Three machines, three roles — **run them in order: Operator first, then Sandbox.**
**Operators run with NO flags** (no flag = real + local). The Operator harness succeeds
on its own — its agent-side steps **defer** to the sandbox — and the Sandbox harness then
covers those deferred steps. **Both succeed without error.** `v2-demo.sh` is the front door.

### On Operator

**Run first.** One flagless command runs the whole operator flow — the onboarding **ceremony**
(master register + K11 enroll + scope-set, each a real **Touch ID** prompt), authentication
(email / wallet → session J1), chain bring-up, the per-actor isolation proof, **memory planting
(phase 4)**, and the **wire phase (phase 5) that pairs the §10.2 agent** into the sandbox:

```bash
# Phase 5 wires the §10.2 agent INTO the aiosandbox (agent container), so it must be
# running first. Start it if it isn't (override the endpoint with SANDBOX_URL):
docker run --security-opt seccomp=unconfined -d -p 8080:8080 ghcr.io/agent-infra/sandbox:latest
bash harness/v2-demo.sh   # phases 1→2→3 (Touch ID) + 4 (memory plant) + 5 (wire — pairs the agent + Touch ID) + 6 (web↔agent parity)
```

Phase 5 **auto-detects** the aiosandbox (probes `$SANDBOX_URL/healthz`): up → it wires; down →
it reports **`v2-demo INCOMPLETE`** and **exits non-zero** — the wire/pairing proof did NOT run, and
an unexecuted proof is never reported green. Bring the sandbox up + re-run `--from 5`, or pass
**`--wire none`** to intentionally skip the wire (then the run is a clean pass).
Do **not** run `openviking-sandbox-setup.sh` here — that's the *optional* OpenViking memory-engine
setup that runs **inside** the sandbox **after** wiring (see [Other entry points](#other-entry-points)).

This **succeeds green.** Stage 3's **agent-side** steps (11-12 + 14-15, signed AS the agent) show
as **`defer`** in the summary — not a failure — because the agent's key lives in the sandbox;
they're covered On Sandbox next. Re-run any phase by its address — e.g. `--from 4.1` (re-test
memory planting; it's idempotent on the reserved account) or `--from 5` (just re-pair + wire).

### On Sandbox

**Run second**, after the operator harness. `v2-demo.sh`'s **phase 5 already paired** the §10.2
agent and uploaded the test, so you do **not** re-run the wire demo — just open the sandbox shell
and run the real-agent proof (it signs with the agent's **sandbox-held** key):

```bash
# in the SANDBOX shell:
bash "$HOME/sandbox-agent-isolation.sh"   # the REAL agent: the deferred roundtrip (steps 11-12 / 14-15), sandbox-held key
```

(If `v2-demo.sh` reported the wire phase **skipped — no aiosandbox**, the agent wasn't paired:
set the sandbox up and re-pair with `bash harness/v2-demo.sh --from 5`. `--light` is the offline
dev loop only — never for assertions.)

### On CI

CI has **no Touch ID and no sandbox**, so one flag switches to the software register +
a **mock** agent + tolerate-skips:

```bash
bash harness/v2-demo.sh --ci   # software register, mock agent, tolerate prereq skips; wire OFF (no sandbox in CI)
```

`--ci` (or the runner's `$CI`) ⇒ `--signer software` + `--mock-agent` + `--allow-skip`
semantics + **stage-1 auto-skips deploy/email/provision** (CI runs against
pre-provisioned infra — contracts pinned in secrets, identity via wallet_sig, the
vault/memory buckets+roles an operator one-shot). The mock agent tests the worker
**plumbing only** — not the real §10.2 agent (that's the sandbox run above). This is
exactly what `harness-ci.yml` runs: `v2-demo.sh --ci` → phases 1–4 + 6 (phase 5/wire
is the only one CI can't do — no aiosandbox).

---

## Step by Step Explanation

### Prerequisites (one-time)

| Need | How |
|---|---|
| Chain + contracts live | `bash scripts/setup-heima.sh` (idempotent). Verify: `AGENTKEYS_CHAIN=heima bash scripts/verify-heima-contracts.sh` |
| Broker host live (on #195+) | `bash scripts/setup-broker-host.sh --ref main` (idempotent) |
| `scripts/operator-workstation.env` | sourced by every script (RPC, registry/scope/EntryPoint/factory addrs, bucket + role ARNs, `OIDC_ISSUER`) |
| Deployer key | `~/.agentkeys/heima-deployer.key` (raw hex) or `HEIMA_DEPLOYER_KEY_FILE` or `./test-hei` (mnemonic). Pays gas; funds test accounts |
| `cast` (foundry) + `jq` + `aws` | on `PATH` |
| A Mac with **Touch ID** (operator) | the local register is a real WebAuthn ceremony. Headless? That's a CI run → `--ci` |
| aiosandbox (sandbox tests) | the agent container — `docker run --security-opt seccomp=unconfined -d -p 8080:8080 ghcr.io/agent-infra/sandbox:latest` (override the endpoint with `SANDBOX_URL`). Detail: [`operator-runbook-wire.md`](operator-runbook-wire.md) |
| `python3` (stage-1 scope helpers only) | `heima-scope-{set,revoke}.sh` use python3 **stdlib** (no pip/venv). The register needs **no** python |
| AWS creds (stage 3 + memory) | profile able to read the vault/memory buckets — see [AWS mapping](../CLAUDE.md) |

### What each phase proves

- **phase 1 — M1 foundation** (`v2-stage1-demo.sh`): install/build → chain reachability →
  email-init session → credential-envelope smoke → chain bring-up → **register master
  device** → K11 enroll → create demo agent → scope grant → credential audit.
- **phase 2 — hardening** (`v2-stage2-demo.sh`): real WebAuthn K11 enrollment + register
  first master + the companion (second-master M-of-N) daemon.
- **phase 3 — OIDC + isolation proof** (`v2-stage3-demo.sh`, 23 steps): SIWE → OIDC JWT → per-actor
  STS → S3 positive/negative, cross-actor + cross-data-class denials, the four issue-#90
  isolation layers, and the **scope triad** — step 16 master-self cap (operator==actor, no
  scope → 200), step 17 cross-actor un-granted → ServiceNotInScope, step 18 granted agent
  (operator≠actor, master granted the scope → 200; the positive delegation proof) — the
  #195/#196 gate. **Steps 19–21 (#201)** prove the **Config** data-class isolation (master-only
  taxonomy): step 19 config creds write own `config/` prefix (200) but AccessDenied at the
  memory/vault buckets (+ memory creds → config bucket AccessDenied); steps 20–21 the
  cap data-class-mismatch (config cap ↔ memory/cred workers). These are **master-self → run on
  the operator** (no sandbox defer); they `skip` cleanly until you've run `provision-config-{bucket,role}.sh`
  + `apply-config-bucket-policy.sh` and redeployed the broker host. **Step 22 (#207)** proves the
  **classifier-worker** isolation (master-self, compute gate): a storage cap → classify worker →
  `cap_op_mismatch`, and a `memory`-bound Classify cap declared as `credentials` → `cap_data_class_mismatch`
  (no STS — the classify worker has no S3); it `skip`s cleanly until you deploy the worker (`setup-cloud.sh`
  DNS + `setup-broker-host.sh --ref main`). Step 23 = cleanup + summary. Per-step `ok`/`skip`/`fail`; strict by default.
  **Steps 11-12 / 14-15** sign STS creds AS the agent → `defer` to the sandbox on the operator.
- **phase 4 — memory plant** (`memory-plant-demo.sh`): the master plants its prepared archive
  through the real master-self chain (cap-mint → STS → worker `/v1/memory/put` → S3) — the CLI
  form of the web "⊕ plant prepared memory" button. **Re-testable**: idempotent (one blob per
  namespace), writes only to the master's own reserved prefix `bots/0x<O_master>/memory/`.
  Re-run with `--from 4.1`.
- **phase 5 — wire** (`phase1-wire-demo.sh --real --webauthn`): the agent inside the sandbox reads +
  writes its real memory through `agentkeys wire` — cap-mint → STS relay (`X-Aws-*`) → `memory.litentry.org`
  → S3 `bots/<actor>/memory/`, passively injected each turn by the `pre_llm_call` hook. **Pairs the
  §10.2 agent AND the master grants its `memory:<ns>` scope via Touch ID** (`--webauthn`; the agent's
  cap service is `memory:<ns>`, so without the grant `memory.get` → `service_not_in_scope`). The
  **only** real-memory proof (never `--light`).
- **phase 6 — web↔agent parity** (`web-parity-demo.sh`): boots `agentkeys-daemon --ui-bridge` (seeded
  with the master's J1 + device via the `--ui-bridge-seed-*` seam, so it skips re-onboarding) and
  plants a dedicated `webparity` probe namespace through the **web** endpoint
  `POST /v1/master/memory/plant`. A 200 proves the daemon's chain (cap-mint → STS → worker → S3)
  matches the agent/harness path, so the web flow can't silently drift from the harness. A **thin
  3-step wiring smoke** — the body shape is gated at compile/fixture time
  (`scripts/check-web-api-drift.sh`), so the runtime check stays minimal. The probe ns is **deleted on
  exit** (success or failure), so it never leaks into real memory. **Reuses** the build/chain/broker/
  master from phases 1–2 — one daemon boot, no re-bootstrap. Real-only; skips cleanly without a broker.

### The master register — #164 ERC-4337 (EOA deprecated)

Stages 1 & 2 register via `register_first_master` ([`_lib.sh`](../harness/scripts/_lib.sh)).
The **#164 passkey-account register is the only supported path** (EOA is deprecated,
escape-only via `AGENTKEYS_REGISTER_MODE=eoa`). Two implementations of the same flow,
both Rust, no python:

| | passkey implementation | when |
|---|---|---|
| **operator (no flag)** | **hardware** Touch ID / Secure Enclave (`k11 webauthn-{keygen,userop-sign}`) | a local run — a real localhost WebAuthn ceremony |
| **CI (`--ci`)** | **software** P-256 passkey (`k11 software-{keygen,sign}` — file key, no biometric) | headless only — the CLI prints a `WARN` |

It deploys a `P256Account` (CREATE2 from the passkey), funds its EntryPoint deposit, and
lands `registerFirstMasterDevice` via a passkey-signed UserOp through `EntryPoint.handleOps`.
`device_key_hash = keccak(operator_omni)`. **Skips before any ceremony** when the operator
already has a first master. Mainnet cost: createAccount + ~0.2 HEI deposit + `handleOps`
(E7 pre-cutover). Detail: [`plan/chain/erc4337-master-account.md`](plan/chain/erc4337-master-account.md) §3.1.

### Overall step addressing — `PHASE.STEP`

Each phase numbers its own steps (the output prints `phase 3 step 11/18`), so a step's
overall address is `<phase>.<step>`:

```bash
bash harness/v2-demo.sh --from 3.11    # resume AT phase 3 step 11, continue to the end
bash harness/v2-demo.sh --from 4.1     # re-test memory planting (phase 4), then wire (phase 5)
bash harness/v2-demo.sh --only 4.1     # run ONLY phase 4 step 1
bash harness/v2-demo.sh --from 5       # just the wire phase (phase 5 — re-pairs the agent; no sub-steps)
bash harness/v2-demo.sh --stage 6      # just web↔agent parity (phase 6 — boots the seeded daemon, plants via the web endpoint)
```

`--from 2` means "phase 2 step 1 onward". The individual `v2-stage{1,2,3}-demo.sh` also
take `--from-step N` / `--only-step N` directly.

### Stage-3 steps 11-12: operator defers, sandbox runs, CI mocks

Steps 11-12 sign STS creds AS the agent → they need the agent's key. Three roles, three behaviours:

- **Operator (no flag)** — the agent's key is in the sandbox, so the master can't sign for it.
  Steps 11-12 **`defer`** to the sandbox (shown in the summary, never fail/incomplete; the
  demo stays GREEN). `v2-demo.sh` does **not** mock on the operator.
- **Sandbox** — the genuine §10.2 agent: run `sandbox-agent-isolation.sh` IN the sandbox (see
  [On Sandbox](#on-sandbox)). The agent signs with its sandbox-held key — the real coverage.
- **CI (`--ci`)** — no sandbox, so `--mock-agent` provisions a master-held DEV agent that
  tests the worker **plumbing only** (not the real agent). Mock is CI-only.

### CI flag reference

| Flag | Effect |
|---|---|
| `--ci` | software register + auto `--mock-agent` + tolerate prereq `skip`s. Sets `AGENTKEYS_CI=1` (the runner's `$CI` also triggers it). |
| `--mock-agent` | (stage 3) mock the sandbox agent with a master-held DEV agent. Auto-applied by `v2-demo.sh`; only needed when running `v2-stage3-demo.sh` directly. |
| `--allow-skip=<reason>` | (stage 3) opt a prereq into `skip` not `fail`. NOT a release gate. |
| `--signer software` | force the file-key register signer directly. |

### Other entry points

- **`erc4337-master-e8.sh`** — standalone #164 mechanism smoke (passkey-only master mutation, green on mainnet).
- **`web-memory-bootstrap.sh`** — issue #196 web-memory pre-flight; runbook [`operator-runbook-web-memory.md`](operator-runbook-web-memory.md).
- **`openviking-sandbox-setup.sh`** — *optional, advanced.* Stands up **OpenViking as the memory
  engine** (Model B) and runs **INSIDE the aiosandbox**, not on the Mac. It **requires the agent to
  already be wired** (phase 5 / `phase1-wire-demo.sh` creates the hook it reads), so it's a *post-wire*
  step — never the way you "bring up the sandbox." Upload it into the sandbox, then run it there.
  Runbook: [`operator-runbook-openviking.md`](operator-runbook-openviking.md).

---

## Operator Q&A

**Q. A browser opened and asked for Touch ID — is that right?**
Yes. Locally the register is a real hardware WebAuthn ceremony; a fresh register prompts
twice (credential *create*, then *get*). Approve them. On a headless box (no display /
biometric) that's a CI run → `--ci` (software signer).

**Q. How do I resume after a failure at, say, phase 3 step 11?**
`bash harness/v2-demo.sh --from 3.11` — it skips phases 1-2 and resumes phase 3 at step 11.

**Q. stage 3 steps 11-12 show `defer` / didn't run on the operator — is that a failure?**
No — that's correct. Steps 11-12 are signed AS the agent, and a §10.2 agent's key lives in
the **sandbox** (the master can't sign for it), so on the operator they **defer** to the
sandbox. The summary counts them as `defer` (never fail/incomplete) and the demo is GREEN.
Cover them by running the **On Sandbox** harness next ([On Sandbox](#on-sandbox)). On **CI**
(no sandbox) they're mocked with a master-held dev agent instead (plumbing-only). They only
hard-fail if you run `v2-stage3-demo.sh` **directly** with `--allow-skip` mis-set.

**Q. How do I actually test against the sandbox (the real agent)?**
After the operator's `v2-demo.sh` finishes, **phase 5 (wire) has already paired** the §10.2
agent and stage 3 uploaded `sandbox-agent-isolation.sh` into the sandbox. Open the sandbox
shell and run `bash "$HOME/sandbox-agent-isolation.sh"` — the agent signs with its own
sandbox-held key (the deferred steps 11-12 / 14-15). See [On Sandbox](#on-sandbox). You do
**not** re-run the wire demo by hand; if the wire phase was skipped (no aiosandbox), re-pair
with `bash harness/v2-demo.sh --from 5`.

**Q. `openviking-sandbox-setup.sh` Phase 0 fails — `no wired hook … run phase1-wire-demo.sh first`?**
That script is the *optional* OpenViking memory-engine setup; it runs **inside** the sandbox and
needs the agent **already wired**. It is **not** how you bring up the sandbox. For the standard
flow you don't run it — start the aiosandbox (`docker run … ghcr.io/agent-infra/sandbox:latest`)
and run `bash harness/v2-demo.sh`; **phase 5 does the wiring**. Only reach for
`openviking-sandbox-setup.sh` **after** a green run, to swap the memory engine to OpenViking —
see [`operator-runbook-openviking.md`](operator-runbook-openviking.md).

**Q. The wire test says "must pass `--real` or `--light`".**
It refuses to guess — `--real` hits the live broker + real S3 (spend), `--light` is offline
dev. Operators want `--real`. Never assert against `--light` (it auto-seeds a fake fixture).

**Q. `ServiceNotInScope` on a master-self cap (stage 3 step 16)?**
Not a missed step — the **deployed** broker is pre-#195 (the repo/`origin/main` have the skip;
the host just predates it). Redeploy it. The script builds + restarts **on the broker host**, so
SSH in first, then run it there (per [`operator-runbook-wire.md`](operator-runbook-wire.md) row 2):
```bash
ssh-agentkeys                                       # or: bash scripts/ssh-broker.sh prod
# then ON THE BROKER HOST, in the agentkeys checkout:
sudo bash scripts/setup-broker-host.sh --ref main   # idempotent; fetch+checkout main, rebuild, restart
```
Verify + resume from your laptop: `curl -s https://broker.litentry.org/healthz` = `ok`, then
`bash harness/v2-demo.sh --from 3` (re-runs phase 3 fresh — refreshes the session JWT, skips the
Touch-ID phases 1-2; use `--from 3.16` to jump straight to step 16 if the session is still valid).

**Q. `DeviceNotActive` / cap-mint device mismatch?**
The master isn't registered. Re-run stage 1, or `bash harness/scripts/erc4337-register-master.sh`.

**Q. `MalformedPolicyDocument` / empty AWS results?**
Wrong profile/region: `awsp <profile>`; always pass `--region "$REGION"` (per [`../CLAUDE.md`](../CLAUDE.md)).

**Q. `DEMO INCOMPLETE` / skipped steps in stage 3?**
Strict mode + a missing prereq. Run the prereq, or (dev only) `--allow-skip=<reason>`.

---

## For Agent Rules

Rules for any agent (human or AI) working **on** the harness:

- **Operators run with no flags.** No flag = real + local (hardware Touch ID, real memory,
  real sandbox). Flags are CI/dev only. Don't add operator-facing flags — prefer auto-detect
  (Cargo's own incremental build, sandbox auto-detect, idempotent skips).
- **Run-mode mapping (the three roles above):** operator = no flag; `--ci` = software register
  + mock agent + tolerate skips; **sandbox** = the agent-side tests run *in* the sandbox
  (the master never signs for a sandbox-held key). The mock is plumbing-only, never the real agent.
- **Keep the docs in sync — every time a harness script changes** (new flag, new step,
  renamed script, changed default), update **this runbook AND [`../harness/CLAUDE.md`](../harness/CLAUDE.md)
  in the same change.** A script change without the doc update is incomplete.
- **Mainnet + idempotent posture.** Demos run on Heima mainnet; every step pre-checks state
  and `skip`s when already done. Never silently downgrade to a testnet.
- **Authoring contract:** [`../harness/CLAUDE.md`](../harness/CLAUDE.md) is the source of
  truth for how harness scripts are written (step/flag/logging contract, idempotency,
  register policy, the orchestrator inventory). Read it before editing any `harness/` script.

## References

- Authoring contract: [`../harness/CLAUDE.md`](../harness/CLAUDE.md).
- Per-area depth: [`operator-runbook-wire.md`](operator-runbook-wire.md), [`operator-runbook-web-memory.md`](operator-runbook-web-memory.md).
- Chain/plan: [`plan/chain/erc4337-master-account.md`](plan/chain/erc4337-master-account.md), [`arch.md`](arch.md) §9 stage 4 + §12.4.
- Deployed contracts: [`spec/deployed-contracts.md`](spec/deployed-contracts.md).
