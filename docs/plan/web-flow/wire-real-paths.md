# Wiring the parent-control web UI to real backends (learn from the wire demo)

**Status:** plan (pre-code). Authored after auditing the live UI against `harness/phase1-wire-demo.sh`.
**Goal:** replace every *narrated* / *in-memory-stub* path in the parent-control UI + daemon ui-bridge with the **same real calls the agent-side wire demo makes** — broker auth, broker cap-mint, on-chain `cast` writes, and the S3-backed memory worker.
**Defers to (do not duplicate):**
- [`data-model.md`](data-model.md) — the daemon↔UI HTTP contract is **already specced there**. This plan *executes* it; it does not re-spec endpoint shapes.
- [`overview.md`](overview.md) — Authority/Task-Host model + Phase-1/Phase-2 split.
- [`docs/arch.md`](../../arch.md) §9 (master bootstrap stages 0–4), §10.1 (master init), §10.2 (agent-initiated pairing, method A) — the canonical ceremonies. **Source of truth.**
- `harness/phase1-wire-demo.sh` — the **reference implementation** of every real call. Where this plan says "mirror the demo," it means call the same endpoint/script that file calls.

---

## 0. TL;DR + the one principle

Today the UI is real in exactly two spots (real browser WebAuthn for K11 enroll, and the daemon's content-hash dedup), and everything else is narration or an in-memory `RwLock` stub (see [§2](#2-current-reality)). Nothing touches the broker, chain, or S3.

**The principle (already law in `data-model.md:9,22-25`):** the browser talks to **the daemon ui-bridge only** (`127.0.0.1:3114`, bearer + CORS). The daemon is the **orchestrator** that makes the real broker / chain / worker calls. The browser never holds an EVM key, never `cast send`s, never calls the broker or AWS directly.

So "wire the missing paths" = **make the daemon ui-bridge endpoints real**, reusing machinery that already exists:
1. **Broker calls** → reuse the daemon's existing broker HTTP client (the `proxy.rs` pattern: `reqwest` + bearer + fail-closed). It already calls `/v1/cap/cred-*`; extend it to the auth, pairing, cap-memory, and oidc-mint endpoints.
2. **Chain writes** → the daemon shells out to the **same `agentkeys` CLI + `scripts/heima-*.sh`** the wire demo uses (`cast send` to `SidecarRegistry` / `AgentKeysScope`). There is **no Rust chain client today** — mirroring the demo means orchestrating the proven bash/CLI path, not building a new one.
3. **Memory** → route plant/read through the **real cap-mint → OIDC-mint → STS → memory worker → S3** chain the MCP `http` backend already implements, instead of the in-memory map.

This is deliberately the *lowest-divergence* path: every real call already exists and is exercised by `phase1-wire-demo.sh`. We are connecting the web seam to it, not writing new protocol.

---

## 1. The seam (who calls whom)

```
 browser (Next.js, lib/client DaemonBackend)
    │  HTTP 127.0.0.1:3114  (bearer J1 + CORS http://localhost:3113)
    ▼
 agentkeys-daemon  --ui-bridge        ←── THE ORCHESTRATOR (today: mostly stubs)
    ├── broker client (reqwest)        →  https://broker.litentry.org   /v1/auth/*, /v1/agent/pairing/*, /v1/cap/*, /v1/mint-oidc-jwt
    ├── chain submit (shell → CLI/scripts → cast)  →  Heima RPC   SidecarRegistry / AgentKeysScope
    ├── worker client (reqwest + X-Aws-*)  →  https://memory.litentry.org /v1/memory/{put,get}  →  S3 bots/<actor>/memory/
    └── local: K10 keychain, K11 WebAuthn (already real), session.json
```

Browser-side WebAuthn (Touch ID) stays in the browser via `navigator.credentials.*` and reaches the daemon through the **already-specced** `/v1/k11/enroll/{begin,finish}` (shipped) and `/v1/k11/assert/{begin,finish}` (`data-model.md:108-126`, not yet built). The daemon then *carries the resulting assertion* into the chain tx (see [§4.3](#43-the-k11-touch-id--chain-write-bridge-the-load-bearing-decision)).

---

## 2. Current reality

Audited from `apps/parent-control/app/_components/ceremony.tsx`, `lib/client/daemon.ts`, and `crates/agentkeys-daemon/src/ui_bridge.rs`.

| UI path | Backend today | Real? |
|---|---|---|
| Onboarding · "Generate K10" | progress-bar text | ❌ narration |
| Onboarding · "Verify email" | `submitEmail` just advances the phase | ❌ narration — **no broker call**, no magic link |
| Onboarding · "Bind passkey K11 · Touch ID" | `enrollK11Begin/Finish` → daemon `/v1/k11/enroll/*` → real `webauthn-rs` verify, stored in `RwLock` | ⚠️ **real WebAuthn**, daemon-only; **`chain_tx_hash=None`** (`ui_bridge.rs:376-378` TODO) |
| Onboarding · "Derive wallet + SIWE → session" | progress-bar text | ❌ narration — no signer, no SIWE, no J1 |
| Onboarding · "Register master device on chain" | progress-bar text + **mock txHash** | ❌ narration — no `registerFirstMasterDevice` |
| "logged in" gate | `localStorage.ak_onboarded='1'` | ❌ local flag, not a session JWT |
| Memory plant | `plantMemory` → daemon `/v1/master/memory/plant` → in-memory dedup map | ⚠️ real HTTP + real dedup, **in-memory only** — no cap-mint, no STS, no worker, no S3 |
| Memory list | daemon `/v1/master/memory` (same in-memory map) | ⚠️ in-memory only |
| Actors / caps / audit / anchor / workers | daemon ui-bridge `RwLock<HashMap>` fed only by `/v1/dev/seed` | ❌ in-memory stubs |
| Scope / payment-cap / revoke mutations | daemon mutates in-memory + pushes fake audit row | ❌ stub — no `setScopeWithWebauthn`, no chain |
| Pairing (claim / pending / bind / grant) | none (no client method); UI shows empty state | ❌ not wired |

**Already real and reusable (don't rebuild):**
- Daemon broker client in `crates/agentkeys-daemon/src/proxy.rs` — `reqwest` + `bearer_auth(session_jwt)` + 60 s fail-closed; already calls `/v1/cap/cred-store|cred-fetch`.
- Daemon one-shot pairing modes (`main.rs run_request_pairing` / `run_retrieve_pairing`) already call `/v1/agent/pairing/{request,poll}`.
- The whole broker surface is real + persistent (SQLite) — no broker stubs exist.
- The MCP `http` backend (`crates/agentkeys-mcp-server`) already implements cap-mint → `/v1/mint-oidc-jwt` → STS → memory worker.
- CLI + `scripts/heima-*.sh` already do every chain write via `cast`.

---

## 3. What the wire demo does for real (the reference)

Condensed from `phase1-wire-demo.sh` + helper scripts. **This is the call list the daemon must reproduce.**

### 3a. Master init / onboarding (arch §9 stages 0–4) — done by `scripts/setup-heima.sh` + CLI
1. **Stage 1 — identity.** `agentkeys init --email <addr>` → broker `POST /v1/auth/email/request` → operator clicks magic link → CLI polls `GET /v1/auth/email/status/:request_id` → session JWT. *(arch §9 calls the broker output `binding_nonce`; the broker exposes it as the email-status / wallet-start nonce, not a literal `/v1/auth/bind` route.)*
2. **Stage 3 — wallet + SIWE → J1.** `POST /v1/wallet/link` → `POST /v1/auth/wallet/start` (returns `siwe_message` + `nonce`) → sign EIP-191 → `POST /v1/auth/wallet/verify` → **J1** (`omni_account == operator_omni`).
3. **Stage 2 — K11 enroll.** `agentkeys k11 enroll --webauthn --rp-id <h> --operator-omni 0x<op>` → real WebAuthn create → `~/.agentkeys/k11/<omni>.json`.
4. **Stage 4 — register master on chain.** `scripts/heima-device-register.sh` → `heima-register-first-master.sh` → `cast send <SidecarRegistry> registerFirstMasterDevice(...)` (first device: roles=7, no K11 sig).

### 3b. Pairing — §10.2 method A (Phase P of the demo)
| Step | Actor | Real call |
|---|---|---|
| request | agent daemon | `agentkeys-daemon --request-pairing` → `POST /v1/agent/pairing/request {device_pubkey, pop_sig}` → `{pairing_code, request_id, device_key_hash}` (K10 stays on the agent) |
| claim | master | `agentkeys agent claim --pairing-code <c> --label <l> --services memory --session-bearer <J1>` → `POST /v1/agent/pairing/claim` → `{child_omni, device_pubkey, pop_sig, device_key_hash}` |
| retrieve | agent daemon | `agentkeys-daemon --retrieve-pairing --request-id <id>` → `POST /v1/agent/pairing/poll` → **J1_agent** minted at poll (stays in sandbox) |
| pending | master | `agentkeys agent pending` → `GET /v1/agent/pending-bindings` (the notification source) |
| **bind** | master | `scripts/heima-agent-create.sh --agent-address <a> --actor-omni <child> --device-key-hash <dkh> --pop-sig <s>` → `cast send <SidecarRegistry> registerAgentDevice(...)` then `POST /v1/agent/pending-bindings/ack` |
| **grant** | master | `scripts/heima-scope-set.sh --webauthn --agent <l> --services memory` → `agentkeys k11 assert --webauthn` (**the one Touch ID**) → `cast send <AgentKeysScope> setScopeWithWebauthn(...)` |

Per arch §10.2, bind + grant are **one operator gesture** (one K11 assertion authorizes both txs).

### 3c. Memory (the full real `memory.put`/`get` chain)
`agentkeys memory put` → MCP `tools/call agentkeys.memory.put` →
1. **cap-mint:** `POST /v1/cap/memory-put` (Bearer = operator J1) → broker verifies `session_omni==operator_omni`, on-chain `getDevice`, `isServiceInScope`, embeds `K3EpochCounter.currentEpoch`, returns broker-signed `CapPayload{op:Store, data_class:Memory}`.
2. **STS relay:** (Bearer = agent J1) `POST /v1/mint-oidc-jwt` → OIDC JWT tagged `agentkeys_actor_omni` → `AssumeRoleWithWebIdentity(MEMORY_ROLE_ARN)` → STS creds → `X-Aws-*` headers.
3. **worker:** `POST https://memory.litentry.org/v1/memory/put {cap, plaintext_b64, namespace}` + `X-Aws-*` → AES-256-GCM → S3 `bots/<actor_omni_hex>/memory/memory.enc`.

Read is symmetric via `/v1/cap/memory-get` + `/v1/memory/get`.

---

## 4. Target daemon architecture

Three internal capabilities the daemon ui-bridge gains. All three already exist *somewhere* in the repo — the work is wiring them into the ui-bridge handlers.

### 4.1 Broker client (reuse `proxy.rs`)
Factor the `proxy.rs` broker client into a shared `daemon::broker` module the ui-bridge can call: typed methods over `reqwest` with `bearer_auth`, fail-closed on broker silence, returning the broker's JSON shapes. Endpoints to cover (all already real on the broker):
- Auth: `POST /v1/auth/email/request`, `GET /v1/auth/email/status/:id`, `POST /v1/wallet/link`, `POST /v1/auth/wallet/start`, `POST /v1/auth/wallet/verify`.
- Pairing: `POST /v1/agent/pairing/{request,claim,poll}`, `GET /v1/agent/pending-bindings`, `POST /v1/agent/pending-bindings/ack`.
- Cap + STS: `POST /v1/cap/{memory-put,memory-get,cred-store,cred-fetch}`, `POST /v1/mint-oidc-jwt`.

### 4.2 Chain-submit (shell → existing CLI/scripts — *mirror the demo*)
The daemon ui-bridge submits chain writes by invoking the **same scripts the demo uses**, as subprocesses, capturing the tx hash from stdout:
- `registerFirstMasterDevice` → `scripts/heima-device-register.sh`
- `registerAgentDevice` → `scripts/heima-agent-create.sh`
- `setScopeWithWebauthn` → `scripts/heima-scope-set.sh`
- `revokeAgentDevice` / scope revoke → `scripts/heima-device-revoke.sh` / `heima-scope-revoke.sh`

Rationale: these are idempotent, already wired to `cast` + `operator-workstation.env`, and battle-tested by the harness. A Rust-native chain client (`alloy`/`ethers`) is **explicitly out of scope** for this plan (noted as future hardening in [§9](#9-risks--open-questions)).

### 4.3 The K11 Touch ID → chain-write bridge (the load-bearing decision)
**Problem:** the scope grant (and master register) embeds a **K11 WebAuthn assertion as a tx argument**. In the demo, `heima-scope-set.sh` runs its *own* WebAuthn via a localhost page (`agentkeys k11 assert --webauthn`). In the web UI the Touch ID must happen **in the browser** (`navigator.credentials.get()`), so the script must NOT prompt again (double Touch ID = broken UX).

**Decision:** the browser produces the assertion; the daemon injects it into the chain write.
1. UI builds the intent → `POST /v1/k11/assert/begin {intent:{op,fields}}` → daemon returns `{challenge, binding, assertion_id}` (`data-model.md:108-118`).
2. Browser `navigator.credentials.get({challenge})` → `POST /v1/k11/assert/finish {assertion_id, authenticatorData, clientDataJSON, signature}` → daemon stores the assertion + `intent_commitment`.
3. Daemon submits the chain tx **carrying that assertion**. This requires extending `heima-scope-set.sh` (and the first-master register path) with an **`--assertion-file <path>` mode** that *skips its own WebAuthn* and uses the supplied assertion bytes. (Small, additive flag; the cast-build logic already accepts an assertion tuple.)

This is the single new piece of "glue" the wire demo doesn't have (the demo's actor is a laptop with a localhost page; the web UI's actor is a browser tab). Everything else is reuse.

### 4.4 Memory through the real worker
Replace the ui-bridge in-memory `master_memory` map with a worker-backed path. Two implementation options, in preference order:
- **(A) Reuse the MCP `http` backend in-process** — the daemon already can host/drive the MCP server logic; call its memory put/get which already does cap-mint → STS → worker → S3.
- **(B) Daemon does it directly** via the §4.1 broker client (`/v1/cap/memory-*` + `/v1/mint-oidc-jwt`) + a small worker client (`POST {MEMORY_URL}/v1/memory/{put,get}` with `X-Aws-*`).

Either way the UI's `POST /v1/master/memory/plant` becomes: for each prepared entry → real `memory.put` to S3; `GET /v1/master/memory` → real `memory.get` / S3 list (metadata-only per `data-model.md:160-170`). The content-hash dedup we already ship stays as an idempotency guard in front of the worker.

---

## 5. Per-flow wiring plan

Each row: **UI surface → daemon ui-bridge endpoint (from `data-model.md`) → real backend call (from §3) → arch ref.** Legend: ✚ = net-new daemon handler; ✔ = already shipped; unmarked = extend an existing handler.

### 5a. Onboarding (arch §9 stages 0–4)
| §9 stage | UI step | Daemon endpoint | Real backend call |
|---|---|---|---|
| 1 identity | "Verify email" — real email entry → magic link | ✚ `POST /v1/auth/email/start`, ✚ `POST /v1/auth/email/verify`, ✚ `GET /v1/auth/email/status` (`data-model.md:77-97`) | broker email triad → session JWT + `binding_nonce` |
| 2 binding | "Bind passkey K11 · Touch ID" (mid-ceremony) | ✔ `POST /v1/k11/enroll/{begin,finish}` | real WebAuthn (already real) — challenge `SHA256(binding_nonce‖D_pub)` |
| 3 wallet | "Derive wallet + SIWE → session" | ✚ `POST /v1/wallet/link` + wallet start/verify (fold into onboarding) | broker SIWE → **J1** (replaces the `localStorage` flag as the real session) |
| 4 chain | "Register master device on chain" | ✚ `POST /v1/onboarding/chain/register-master {k11_assertion_id}` (`data-model.md:185`) | shell → `heima-register-first-master.sh` → `registerFirstMasterDevice` tx; un-stubs `chain_tx_hash` (`ui_bridge.rs:376`) |
| — | onboarding gate / resume | ✚ `GET /v1/onboarding/state` (`data-model.md:29-75`) | aggregate of local files + broker + chain reads; **replaces `ak_onboarded` localStorage** |

The localStorage `ak_onboarded` flag is removed: "onboarded" becomes "`GET /v1/onboarding/state` reports identity+k10+k11+chain present." The **log-out** button (already shipped) then clears the real session, not a fake flag.

### 5b. Pairing (arch §10.2 method A)
| Demo step | UI surface | Daemon endpoint (`data-model.md:189-216`) | Real backend call |
|---|---|---|---|
| pending (bell) | pairing page poll / notification | ✚ `GET` proxy of `/v1/agent/pending-bindings` | broker pending-bindings (J1-gated) |
| claim | "create agent / claim code" | ✚ `POST /v1/agents/pair/init` + claim | broker `/v1/agent/pairing/claim` |
| bind | "accept pairing" | ✚ `POST /v1/agents/pair/bind {agent_address,actor_omni,device_key_hash,pop_sig}` | shell → `heima-agent-create.sh` → `registerAgentDevice` tx → broker `pending-bindings/ack` |
| grant (Touch ID) | "approve scope" | ✚ `POST /v1/agents/pair/approve-scope/{begin,submit}` | browser K11 assert (§4.3) → shell → `heima-scope-set.sh --assertion-file` → `setScopeWithWebauthn` tx |
| post | device + permission view | ✚ `GET /v1/actors` (real, from chain `getDevice` + broker) | replaces in-memory actors stub |

The existing `App.tsx` pairing ceremony UI (CeremonyRunner) maps 1:1 onto these txs; `finishPairingCeremony` already re-fetches `listActors()` — once `/v1/actors` is real, the freshly-bound agent appears for real.

### 5c. Memory
| UI surface | Daemon endpoint | Real backend call |
|---|---|---|
| "plant prepared memory" | ✚ rework `POST /v1/master/memory/plant` to worker-backed (§4.4) | per entry: `/v1/cap/memory-put` → `/v1/mint-oidc-jwt` → STS → `POST {MEMORY_URL}/v1/memory/put` → S3 |
| memory list / view | ✚ rework `GET /v1/master/memory` to worker-backed | `/v1/cap/memory-get` → STS → `POST {MEMORY_URL}/v1/memory/get` (metadata-only listing per spec) |

The `lib/preparedMemory.ts` archive (the Chengdu trip + IAM-strategy items) is unchanged — it's the *payload*; only the transport flips from in-memory to the real worker. This makes the master-plant and the agent-side demo read **the same S3 bytes** (the coherent end-to-end story).

### 5d. Mutations (scope / payment-cap / revoke)
Extend the shipped `POST /v1/actors/:id/{scope,payment-cap,revoke}` (`data-model.md:249-261`) to take a `k11_assertion_id` and submit the real chain tx via §4.2/§4.3 instead of mutating the in-memory map.

### 5e. Audit
Replace the in-memory audit ring with real reads: `GET /v1/audit/recent` ← broker audit / on-chain `CredentialAudit`; `GET /v1/audit/stream` (SSE transport already real) carries real worker/broker events. (Audit *decode* stays the #153 mock until that issue lands — out of scope here.)

---

## 6. Implementation phases (sequenced)

Mirrors `deferred-and-followups.md` Phases D–J and `issue-9step-flow.md` P2.1–P2.4; each phase is independently shippable and ends green on a harness check.

- **W0 — daemon broker-client refactor.** Factor `proxy.rs` → `daemon::broker` shared client. No UI change. Unit-test against a mock broker. *(unblocks everything)*
- **W1 — onboarding identity + session (§5a stages 1+3).** Email triad + SIWE → real J1; `GET /v1/onboarding/state`; drop `ak_onboarded`. Touch ID enroll already real. *(arch §9.1–9.3)*
- **W2 — master register on chain (§5a stage 4).** `--assertion-file` flag on the register script (§4.3); `POST /v1/onboarding/chain/register-master`; un-stub `chain_tx_hash`. *(arch §9.4)*
- **W3 — memory through the worker (§5c).** Rework plant/list to the real cap→STS→worker→S3 chain. *(highest "is it real?" payoff; coherent with the agent demo)*
- **W4 — pairing (§5b).** Proxy the broker pairing endpoints + bind/grant chain writes (one K11). *(arch §10.2; reconcile per §7)*
- **W5 — real actors/audit reads + mutations (§5d/§5e).** `/v1/actors`, `/v1/audit/*` from chain+broker; scope/revoke as real txs.
- **W6 — harness parity test.** A `harness/` script that drives the daemon ui-bridge through onboarding→pair→plant→read and asserts the same artifacts `phase1-wire-demo.sh` asserts (see §8).

Estimated ordering rationale: W0 is the keystone; W1+W3 give the most visible "it's real now" wins; W4 is the largest (chain + browser-assertion bridge); W5 broadens coverage.

---

## 7. Reconcile / cleanup (terminology + stale specs)

Per the repo's terminology-source-of-truth + architecture-as-source-of-truth rules, fold these in alongside the code:
- **Superseded pairing endpoints.** `deferred-and-followups.md:106` still lists `POST /v1/agents/bootstrap/{this-device,remote,vendor}` + `POST /v1/agents/create`. These are explicitly superseded by the pair→wire model (`data-model.md:191`, `overview.md:199`) and contradict arch §10.2. Update that sequencing line to the `pair/init|bind|approve-scope` shape when W4 lands.
- **`--upgrade` no-op.** `deferred-and-followups.md:10,17,225` + `overview.md:225` reference `setup-broker-host.sh --upgrade`; per CLAUDE.md the idempotent-setup rule makes `--upgrade` a deprecated no-op. Replace with the plain / `--ref main` invocation if those lines are touched.
- **arch.md check.** None of this changes the §9/§10.2 ceremonies (we're implementing them), so arch.md needs no edit — but re-verify after W2/W4 that the implemented call names still match arch §9's mermaid (`/v1/auth/email/request`, `register_master_device`, `registerAgentDevice`, `setScopeWithWebauthn`).

---

## 8. Testing & harness parity

The wire demo *is* the test oracle. For each phase, add a deterministic assertion that mirrors the demo's:
- **Onboarding:** after W1+W2, `GET /v1/onboarding/state` reports `identity:verified, k10:present, k11:enrolled, chain:master-registered`; the `register-master` tx hash resolves on-chain (`verify-heima-contracts.sh`-style read).
- **Memory:** after W3, plant then read returns the same bytes; assert the S3 object `bots/<actor>/memory/memory.enc` exists (the demo's Phase 1.5 + 4.2 check). Cross-check: the agent-side `hook memory-inject --namespaces travel` reads what the UI planted.
- **Pairing:** after W4, the bind tx + scope tx confirm on-chain; `isServiceInScope(operator, actor, "memory") == true` (the demo's P.3 post-check); the agent can then `memory.get`.
- **Harness script (W6):** `harness/web-wire-demo.sh` that boots `agentkeys-daemon --ui-bridge` against the live broker + Heima and curls the ui-bridge endpoints in order, reusing `operator-workstation.env` and the same env vars the wire demo threads (`OPERATOR_KEY_FILE`, `BROKER_URL`, `MEMORY_ROLE_ARN`, `AGENTKEYS_CHAIN`, …). Idempotent + green/red per step, so it can gate regressions like `v2-stage3-demo.sh` does.

Existing daemon ui-bridge Rust unit tests stay; add tests against a mock broker for the new `daemon::broker` client.

---

## 9. Risks & open questions

- **No Rust chain client.** Mirroring the demo means shelling out to `cast` via the `heima-*.sh` scripts. Pros: zero new protocol, idempotent, proven. Cons: the daemon needs the operator EVM key (`OPERATOR_KEY_FILE`) + `cast` on PATH — fine on the operator laptop, not in a hardened service. *Future hardening:* a native `alloy` submit path in the daemon. **Out of scope here.**
- **`--assertion-file` script change (§4.3).** Small additive flag, but it's the one place we modify demo machinery. Must keep the localhost-WebAuthn path working for CLI users (don't break `heima-scope-set.sh --webauthn`).
- **Operator session lifetime / CORS in prod** — already flagged open in `data-model.md:396-402` (pair-flow JWT 10 min; prod origin `https://parent.{operator}.litentry.org`). Decide before any non-localhost deploy.
- **Broker reachability** — every wired path fails closed when the broker is unreachable (the `proxy.rs` 60 s rule). The UI must surface this as the existing `EmptyState`/disconnected status, not a fake success.
- **Secrets in the daemon process** — the operator J1 + EVM key live in the daemon; that's already true for `--proxy`/`--master-companion`, so no new trust boundary, but the ui-bridge now exercises them.

## 10. Out of scope (stays as-is)
- Audit calldata/CBOR decode → tracked in **#153** (UI keeps the one allowed mock).
- Second-master pairing, recovery quorum, isolation health-check, email worker → already specced (`data-model.md:265-346`), Phase 3+.
- Chain genesis / broker-host / cloud bucket provisioning → stay shell-only (`deferred-and-followups.md:5-17`); the UI may *trigger* `cloud/provision` (W-future) but never reimplements them.
- A native Rust chain client (see §9).
```
