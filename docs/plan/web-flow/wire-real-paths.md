# Wiring the parent-control web UI to real backends (learn from the wire demo)

**Status:** plan (pre-code). Authored after auditing the live UI against `harness/phase1-wire-demo.sh`.
**Goal:** replace every *narrated* / *in-memory-stub* path in the parent-control UI + daemon ui-bridge with the **same real calls the agent-side wire demo makes** — broker auth, broker cap-mint, on-chain `cast` writes, and the S3-backed memory worker.
**Defers to (do not duplicate):**
- [`data-model.md`](data-model.md) — the daemon↔UI HTTP contract is **already specced there**. This plan *executes* it; it does not re-spec endpoint shapes.
- [`overview.md`](overview.md) — Authority/Task-Host model + Phase-1/Phase-2 split.
- [`docs/arch.md`](../../arch.md) §9 (master bootstrap stages 0–4), §10.1 (master init), §10.2 (agent-initiated pairing, method A) — the canonical ceremonies. **Source of truth.**
- `harness/phase1-wire-demo.sh` — the **reference implementation** of every real call. Where this plan says "mirror the demo," it means call the same endpoint/script that file calls.
- [`docs/plan/chain/erc4337-master-account.md`](../chain/erc4337-master-account.md) + [`erc4337-threat-model.md`](../chain/erc4337-threat-model.md) — the **canonical chain-side plan** (Solution A, E0–E8). This doc defers to it for everything chain-write-related; §11 below is retained only as the *why*, annotated as resolved.

---

> **⚠️ Status update (2026-06-02, after #166 / #168 / #171) — READ FIRST.** The chain side this plan waited on has **landed**, and two facts it asserted are now corrected:
> - **ERC-4337 P-256 master account is IMPLEMENTED (#171, "Solution A", locked) — #164 is closed.** §11's "fork (A) vs (B)" is no longer an open decision: `P256Account` + `P256AccountFactory` + EntryPoint v0.7 are **live on Heima mainnet**, plus a `VerifyingPaymaster`, a self-hosted bundler runner (`scripts/erc4337-bundler.sh`), and a WebAuthn UserOp signer (the Rust `agentkeys k11 software-{keygen,sign}` — no python; the former `harness/scripts/erc4337-webauthn-sign.py` is now a byte-spec reference). Phases E0–E6 + E8 are ✅; **E7 (ceremony binding) is the open bridge** and the chain plan routes it through **parent-control onboarding (#163)** — see §5a/§9 below.
> - **Heima's EVM is Cancun, not London (#168).** PUSH0 + transient storage are available; the `evm_version="london"` pin stays *only* as a `forge script` header-validation workaround (deploy EntryPoint/factory via `forge create`). On-chain P-256 verification works **today** with the pure-Solidity verifier (no RIP-7212 precompile, no chain change; ~707k gas with our verifier / ~421k with Daimo's — fine for low-frequency master ops). "No EVM key on phone/browser" is **chain-feasible now**, verified end-to-end (#171 mainnet spike + Kailai's #163 comment).
> - **Bootstrap front-run fixed (#166)** — `registerFirstMasterDevice` now requires a sender-bound K11 self-attestation.
>
> **Net for the web wiring (the live part of this plan):** the chain-write path (§12 **X4**) is now concrete + unblocked — the WASM/native core **builds a UserOp + passkey-signs the `userOpHash`** (the EntryPoint's `userOpHash` *is* a complete full-intent commitment, so the security review's "full-intent binding" finding is resolved structurally) → broker-gated bundler / direct `EntryPoint.handleOps` → `P256Account`. No secp256k1 key, no "delegate broadcast" hop. Reference: `harness/erc4337-master-e8.sh` (passkey-only flow, green on mainnet). The codex-review prerequisites on #163 are now all addressed: bootstrap (#166), agent-bind/full-intent/multi-device (#171 E3/E4/E5).

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

## 0.5 Host-model decision (phone-first) — READ FIRST

The seam in §1 below is written **desktop-first**: "browser → `localhost:3114` daemon." That is a dead end for the product's actual future — **most users will have only a phone, no desktop**, and a phone has no localhost daemon to talk to. So the orchestration logic cannot *live in* a local daemon; the client itself must carry it.

**Decision.** Factor the master-plane orchestration (the §9/§10.2 ceremonies, the broker client, cap handling, chain-tx construction) into **one portable Rust core** (extend the existing `agentkeys-core`, which already holds `init_flow`), hosted three ways behind the **same `lib/client` `AgentKeysClient` interface**:

| Host | Shell | Liveness | Chain-signing key custody |
|---|---|---|---|
| desktop / server | the daemon binary (§1 below) | long-running process | OS keychain |
| **mobile (primary future)** | native app embedding the core (Rust→UniFFI) | **push-woken, on-demand** | SE-sealed **K11/P-256 passkey** signs UserOps (ERC-4337 — §11); no secp256k1 key on device |
| web | the core compiled to **WASM** | active-tab only | registered **P-256 passkey** signs UserOps; a **bundler** broadcasts (ERC-4337 — §11) |

> **Chain-write mechanism — ERC-4337 (confirmed; see §11):** every host signs UserOps with its registered P-256 passkey and a bundler broadcasts; **no host holds a secp256k1 key.** This supersedes the "delegate broadcast" framing in §11/§12's *pre-decision* analysis below.

Consequences that make this the efficient *and* consistent choice:
- **Consistency is structural** — one Rust crate, so web/mobile/desktop can't drift. Do **not** reimplement ceremony logic in TypeScript; TS stays a dumb UI/transport layer over the core.
- **The daemon is demoted to "one host," not a requirement.** The always-on daemon requirement belongs to the *agent-side* daemon (gates the runtime, fails closed) — a different process that never runs on the operator's phone. The master plane is **event-driven + biometric-gated**: it only acts on a request + a Touch ID, so it never needs to *run* in the background — only to be *woken* (push), which is native.
- **The broker is the only always-on component**, and it already is.
- **§1–§6 below remain valid for the desktop host.** The endpoint contract (`data-model.md`) is unchanged; only *where the core runs* and *how chain writes are signed* differ per host. The phone-first amendments are §11 (the verified gating decision) and §12 (the WASM lift scope).

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
| Onboarding · "Activate managed wallet → session" | progress-bar text | ❌ narration — no signer, no managed-wallet attestation, no J1 |
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
2. **Stage 3 — wallet + managed-wallet attestation → J1.** `POST /v1/wallet/link` → `POST /v1/auth/wallet/start` (returns `siwe_message` + `nonce`) → signer EIP-191-signs → `POST /v1/auth/wallet/verify` → **J1** (`omni_account == operator_omni`).
3. **Stage 2 — K11 enroll.** `agentkeys k11 enroll --webauthn --rp-id <h> --operator-omni 0x<op>` → real WebAuthn create → `~/.agentkeys/k11/<omni>.json`.
4. **Stage 4 — register master on chain.** `scripts/heima-device-register.sh` → `heima-register-first-master.sh` → `cast send <SidecarRegistry> registerFirstMasterDevice(...)` (first device: roles=7, no K11 sig).

### 3b. Pairing — §10.2 method A (Phase P of the demo)
| Step | Actor | Real call |
|---|---|---|
| request | agent daemon | `agentkeys-daemon --request-pairing` → `POST /v1/agent/pairing/request {device_pubkey, pop_sig}` → `{pairing_code, request_id, device_key_hash}` (K10 stays on the agent) |
| claim | master | `agentkeys agent claim --pairing-code <c> --label <l> --services memory:travel --session-bearer <J1>` → `POST /v1/agent/pairing/claim` → `{child_omni, device_pubkey, pop_sig, device_key_hash}` (service is namespace-qualified `memory:<ns>` per arch.md §896 — bare `memory` fails cap-mint) |
| retrieve | agent daemon | `agentkeys-daemon --retrieve-pairing --request-id <id>` → `POST /v1/agent/pairing/poll` → **J1_agent** minted at poll (stays in sandbox) |
| pending | master | `agentkeys agent pending` → `GET /v1/agent/pending-bindings` (the notification source) |
| **bind** | master | `scripts/heima-agent-create.sh --agent-address <a> --actor-omni <child> --device-key-hash <dkh> --pop-sig <s>` → `cast send <SidecarRegistry> registerAgentDevice(...)` then `POST /v1/agent/pending-bindings/ack` |
| **grant** | master | `scripts/heima-scope-set.sh --webauthn --agent <l> --services memory:travel` → `agentkeys k11 assert --webauthn` (**the one Touch ID**) → `cast send <AgentKeysScope> setScopeWithWebauthn(...)` (grant the SAME `memory:<ns>` the cap-mint requests, else `service_not_in_scope`) |

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

### 4.3 The K11 Touch ID → chain-write bridge (now: an ERC-4337 UserOp)
> **Updated for #171 (Solution A).** This was the load-bearing open question; ERC-4337 makes it a *simpler* solved path — no `cast`, no `--assertion-file` injection, no double-Touch-ID, no per-op K11 challenge. **The chain write IS a UserOp the passkey signs.**

Every master chain write (register-master, scope set, agent bind/revoke) is now an **ERC-4337 UserOp**:
1. The core assembles the UserOp `callData` — the function intent (target omni, scope bits, device hash, …) against the operator's `P256Account`.
2. The EntryPoint's `userOpHash` is computed over the whole UserOp bound to `entryPoint+chainId`; the **browser passkey-signs that hash** (`navigator.credentials.get({challenge: userOpHash})`). Since `userOpHash` commits the full `callData`, the signature **is** the full-intent commitment — so the confirmation UI MUST render the decoded `callData` **before** the Touch ID (the authenticator only shows an opaque hash; this is the intent-display obligation from the #163 codex note, now the *only* residual delegation concern).
3. The signed UserOp → the **broker-gated bundler** (`scripts/erc4337-bundler.sh`, unsafe-mode) or the daemon relays `EntryPoint.handleOps`. `P256Account.validateUserOp` verifies the P-256 sig over `userOpHash`; the call runs as `msg.sender == account`.

Reference: the Rust `agentkeys k11 software-{keygen,sign}` signer (`crates/agentkeys-cli/src/k11_webauthn.rs`; the deprecated `harness/scripts/erc4337-webauthn-sign.py` is its byte-spec) + `harness/erc4337-master-e8.sh` (full passkey-only flow, green on Heima mainnet). The pre-#171 `/v1/k11/assert/*` + `--assertion-file` injection (still mentioned in §5's tables) is **superseded** — there is no separate per-op K11 challenge to inject.

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
| 2 binding | "Bind passkey K11 · Touch ID" (mid-ceremony) | ✔ `POST /v1/k11/enroll/{begin,finish}` | real WebAuthn; **the K11 pubkey also derives the `P256Account` address** (CREATE2 via `P256AccountFactory`, salt = passkey pubkey) — known pre-deploy (chain-plan E7) |
| 3 wallet | "Activate managed wallet → session" | ✚ `POST /v1/wallet/link` + wallet start/verify (fold into onboarding) | broker managed-wallet attestation → **J1** (replaces the `localStorage` flag as the real session) |
| 4 chain | "Register master device on chain" | ✚ `POST /v1/onboarding/chain/register-master` | **one ERC-4337 UserOp** = `initCode` (factory-deploy the account) + `registerFirstMasterDevice(...)`, passkey-signed (§4.3); #166's self-attestation binds the deterministic account address. **This is chain-plan E7's "parent-control onboarding" binding** + one-time ~0.1 HEI ED funding. |
| — | onboarding gate / resume | ✚ `GET /v1/onboarding/state` (`data-model.md:29-75`) | aggregate of local files + broker + chain reads; **replaces `ak_onboarded` localStorage** |

The localStorage `ak_onboarded` flag is removed: "onboarded" becomes "`GET /v1/onboarding/state` reports identity+k10+k11+chain present." The **log-out** button (already shipped) then clears the real session, not a fake flag.

### 5b. Pairing (arch §10.2 method A)
| Demo step | UI surface | Daemon endpoint (`data-model.md:189-216`) | Real backend call |
|---|---|---|---|
| pending (bell) | pairing page poll / notification | ✚ `GET` proxy of `/v1/agent/pending-bindings` | broker pending-bindings (J1-gated) |
| claim | "create agent / claim code" | ✚ `POST /v1/agents/pair/init` + claim | broker `/v1/agent/pairing/claim` |
| bind | "accept pairing" | ✚ `POST /v1/agents/pair/bind {agent_address,actor_omni,device_key_hash,pop_sig}` | passkey-signed UserOp (§4.3) → `registerAgentDevice` (runs as `msg.sender == account`) → broker `pending-bindings/ack` |
| grant (Touch ID) | "approve scope" | ✚ `POST /v1/agents/pair/approve-scope` | passkey-signed UserOp (§4.3) → `AgentKeysScope.setScope` (#171 E3 renamed `setScopeWithWebauthn`→`setScope`; in-contract K11 + `scopeNonce` retired — the passkey gate is now the account) |
| post | device + permission view | ✚ `GET /v1/actors` (real, from chain `getDevice` + broker) | replaces in-memory actors stub |

The existing `App.tsx` pairing ceremony UI (CeremonyRunner) maps 1:1 onto these txs; `finishPairingCeremony` already re-fetches `listActors()` — once `/v1/actors` is real, the freshly-bound agent appears for real.

### 5c. Memory
| UI surface | Daemon endpoint | Real backend call |
|---|---|---|
| "plant prepared memory" | ✚ rework `POST /v1/master/memory/plant` to worker-backed (§4.4) | per entry: `/v1/cap/memory-put` → `/v1/mint-oidc-jwt` → STS → `POST {MEMORY_URL}/v1/memory/put` → S3 |
| memory list / view | ✚ rework `GET /v1/master/memory` to worker-backed | `/v1/cap/memory-get` → STS → `POST {MEMORY_URL}/v1/memory/get` (metadata-only listing per spec) |

The `lib/preparedMemory.ts` archive (the Chengdu trip + IAM-strategy items) is unchanged — it's the *payload*; only the transport flips from in-memory to the real worker.

> **Per-actor correction (W3, [`w3-real-memory.md`](w3-real-memory.md) §1):** the master plants under **its own** `actor_omni` (`bots/<O_master>/memory/…`) — the cap-mint invariant `device.actor_omni == req.actor_omni` lets it write only its own prefix. An agent reads **its own** prefix (`bots/<O_agent>/…`); cross-actor reads are denied by the per-actor IAM PrincipalTag (issue #90). So the master-plant and an agent do **not** read the same S3 bytes. Giving an agent the master's curated memory is a write under the *agent's* cap at pairing time = **W4**, not a shared read.

### 5d. Mutations (scope / payment-cap / revoke)
Extend the shipped `POST /v1/actors/:id/{scope,payment-cap,revoke}` (`data-model.md:249-261`) to take a `k11_assertion_id` and submit the real chain tx via §4.2/§4.3 instead of mutating the in-memory map.

### 5e. Audit
Replace the in-memory audit ring with real reads: `GET /v1/audit/recent` ← broker audit / on-chain `CredentialAudit`; `GET /v1/audit/stream` (SSE transport already real) carries real worker/broker events. (Audit *decode* stays the #153 mock until that issue lands — out of scope here.)

---

## 6. Implementation phases (sequenced)

Mirrors `deferred-and-followups.md` Phases D–J and `issue-9step-flow.md` P2.1–P2.4; each phase is independently shippable and ends green on a harness check.

- **W0 — daemon broker-client refactor.** Factor `proxy.rs` → `daemon::broker` shared client. No UI change. Unit-test against a mock broker. *(unblocks everything)*
- **W1 — onboarding identity + session (§5a stages 1+3).** Email triad + managed-wallet attestation → real J1; `GET /v1/onboarding/state`; drop `ak_onboarded`. Touch ID enroll already real. *(arch §9.1–9.3)*
- **W2 — master register on chain (§5a stage 4).** **Interim SHIPPED by #196 (old-model shell-out).** The daemon ui-bridge K11-finish handler shells out to `heima-register-first-master.sh` (§4.2) under the **session omni** (operator == actor == O_master), deployer key as `msg.sender`, un-stubbing `chain_tx_hash`; `GET /v1/onboarding/state` reports `chain: master-registered`. The **web-native register-master UserOp** end-state (`initCode` factory-deploy + `registerFirstMasterDevice`, passkey-signed per §4.3 → broker-gated bundler; `POST /v1/onboarding/chain/register-master`) — **this IS chain-plan E7** (the onboarding↔account binding routed through #163) — remains **cutover-blocked** on the thinned account-auth registry not yet on mainnet. #196 is the interim until E7's cutover lands. *(arch §9.4)*
- **W3 — memory through the worker (§5c).** Rework plant/list to the real cap→STS→worker→S3 chain. *(highest "is it real?" payoff; coherent with the agent demo)*
- **W4 — pairing (§5b).** Proxy the broker pairing endpoints + bind/grant chain writes (one K11). *(arch §10.2; reconcile per §7)*
- **W5 — real actors/audit reads + mutations (§5d/§5e).** `/v1/actors`, `/v1/audit/*` from chain+broker; scope/revoke as real txs.
- **W6 — harness parity test. ✅ SHIPPED as `v2-demo.sh` phase 6** (`harness/web-parity-demo.sh`, #200) — NOT a standalone script. Boots the daemon ui-bridge SEEDED with the master's J1 + device (via the `--ui-bridge-seed-*` seam, skipping re-onboarding) + plants via the web endpoint, asserting the daemon's chain matches the agent/harness path. Reuses phases 1-2's setup (see §8).

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
- **Harness script (W6) — SHIPPED as `v2-demo.sh` phase 6** (`harness/web-parity-demo.sh`, #200): boots `agentkeys-daemon --ui-bridge` against the live broker + Heima, SEEDED with the master's existing J1 + device-hash via the `--ui-bridge-seed-*` daemon seam (so it skips re-onboarding — the cost optimization), then plants a probe ns via `POST /v1/master/memory/plant`. A 200 proves the daemon's chain (cap-mint→STS→worker→S3) == the agent/harness path. Folded into v2-demo (not a standalone front door); reuses `operator-workstation.env`; gates regressions like the other phases. Stronger read-back/cross-impl parity = follow-up.

Existing daemon ui-bridge Rust unit tests stay; add tests against a mock broker for the new `daemon::broker` client.

---

## 9. Risks & open questions

- **No Rust chain client.** Mirroring the demo means shelling out to `cast` via the `heima-*.sh` scripts. Pros: zero new protocol, idempotent, proven. Cons: the daemon needs the operator EVM key (`OPERATOR_KEY_FILE`) + `cast` on PATH — fine on the operator laptop, not in a hardened service. *Future hardening:* a native `alloy` submit path in the daemon. **Out of scope here.**
- **UserOp signing in the browser (§4.3).** The core must assemble a correct UserOp and the JS host must passkey-sign `userOpHash`, with the operator shown the **decoded callData before Touch ID** (the authenticator only displays an opaque hash). Reference + parity target: the Rust `agentkeys k11 software-{keygen,sign}` signer + `harness/erc4337-master-e8.sh`. (The old `--assertion-file` / `cast` path is retired by #171.)
- **Operator session lifetime / CORS in prod** — already flagged open in `data-model.md:396-402` (pair-flow JWT 10 min; prod origin `https://parent.{operator}.litentry.org`). Decide before any non-localhost deploy.
- **Broker reachability** — every wired path fails closed when the broker is unreachable (the `proxy.rs` 60 s rule). The UI must surface this as the existing `EmptyState`/disconnected status, not a fake success.
- **Secrets in the daemon process** — the operator J1 + EVM key live in the daemon; that's already true for `--proxy`/`--master-companion`, so no new trust boundary, but the ui-bridge now exercises them.

## 10. Out of scope (stays as-is)
- Audit calldata/CBOR decode → tracked in **#153** (UI keeps the one allowed mock).
- Second-master pairing, recovery quorum, isolation health-check, email worker → already specced (`data-model.md:265-346`), Phase 3+.
- Chain genesis / broker-host / cloud bucket provisioning → stay shell-only (`deferred-and-followups.md:5-17`); the UI may *trigger* `cloud/provision` (W-future) but never reimplements them.
- A native Rust chain client (see §9).

---

## 11. Gating decision (verified) — ✅ RESOLVED by #171 (historical)

> ✅ **RESOLVED + IMPLEMENTED (#171, "Solution A"); Heima facts corrected (#168).** This section is the *historical analysis* that led to ERC-4337 — read it for the *why*, not the current state. The decision is settled and the contracts are **live on Heima mainnet**. Three load-bearing corrections to the analysis below:
> 1. **The fork is closed → ERC-4337 P-256 smart-account (Solution A).** The master is an ERC-4337 account whose `validateUserOp` verifies a P-256 passkey signature over `userOpHash`; `SidecarRegistry.master` = the account address. Canonical plan + status: [`../chain/erc4337-master-account.md`](../chain/erc4337-master-account.md) (E0–E6 + E8 ✅, E7 pending). **No client holds a secp256k1 key** — the "phone must hold a software secp key", "browser can't be a master", and "delegate broadcast" conclusions below are **obsolete**.
> 2. **Heima is Cancun, not London (#168).** Wherever the analysis says "London-level / no PUSH0 / avoid post-london opcodes", that is **wrong**. The P-256-is-pure-Solidity point holds (~707k gas; no RIP-7212; no chain change) — it was just mis-attributed to "London".
> 3. **All codex-review prerequisites are addressed:** bootstrap front-run → **#166** (sender-bound self-attestation); full-intent binding → **structural** (the passkey signs `userOpHash`, which commits the entire UserOp callData — no hand-rolled challenge can omit a field); agent-bind biometric gap + multi-device/recovery → **#171 E3/E4/E5** (master = account; quorum recovery in the account).

**Question:** do master-authority chain writes authorize on `msg.sender` (the device must hold a secp256k1 key) or on the embedded K11 (P-256) assertion (a relayer could broadcast → device can be key-free)?

**Read of the contracts (`crates/agentkeys-chain/src/`):**

| Write | Auth check | File:line |
|---|---|---|
| `SidecarRegistry.registerFirstMasterDevice` | `operatorMasterWallet[operatorOmni] = msg.sender` — **the tx sender BECOMES the master** (bootstrap binding) | `SidecarRegistry.sol:123` |
| `SidecarRegistry.registerAgentDevice` | `if (msg.sender != master) revert` (no K11 — agent k11=0) | `SidecarRegistry.sol:216` |
| `SidecarRegistry.registerMasterDevice` (add a device) | `msg.sender != master` **AND** `_verifyAndConsumeK11` | `:165` + `:177` |
| `SidecarRegistry.revokeAgentDevice` | `msg.sender != master` | `:248` |
| `SidecarRegistry.revokeMasterDevice` | M-of-N K11 assertions (`recoveryThreshold`) | `:254+` |
| `AgentKeysScope.setScopeWithWebauthn` | `msg.sender != master` **AND** `_verifyK11` | `AgentKeysScope.sol:109` + `:127` |

**Verdict: every master write is `msg.sender`-bound to the operator's secp256k1 EVM address.** The K11 P-256 assertion is an *additional* gate on the sensitive ops (scope, master-device add/revoke) — never a substitute for the sender. Bootstrap literally records `master = msg.sender`.

**Implications for phone-first:**
- **No relayer / key-free path under current contracts** — a relayer's `msg.sender ≠ master` → revert.
- **Phone-as-master must hold the secp256k1 key in the Keychain** (biometric-gated access control, *software*). It **cannot** be Secure-Enclave / StrongBox-sealed: those are **P-256 only**; EVM is secp256k1. The K11 passkey (P-256) *is* SE-sealed and stays the hardware-backed gate — but it's an add-on, not the sender.
- **Browser / WASM cannot be a standalone master** — it can't safely custody the secp256k1 sender key. A WASM master can read, call the broker, and produce K11 assertions, but the on-chain broadcast must be **delegated to a key-holding host** (the user's phone or a desktop daemon).

**The fork (decide before the mobile build):**
- **(A) Keep `msg.sender`-bound.** Phone = full master (Keychain secp256k1 key + SE-sealed K11 passkey). Web = read / manage / authorize, delegates broadcast. **No contract change.** Simplest; web is a secondary surface.
- **(B) Move contracts to assertion-only auth** — drop `msg.sender == master`, authorize purely on the on-chain-verified K11 assertion; a relayer pays gas + broadcasts. Then the phone needs **no secp256k1 key** (SE passkey alone) and the browser/WASM becomes a full master. Bigger: contract redesign + security review (the `operatorMasterWallet[operatorOmni] = msg.sender` bootstrap binding is load-bearing today), but it's the lever for true key-free / web / gas-sponsored masters.

**Recommendation:** ship **(A)** for the phone-first MVP — the phone holds the key, no contract work — and open an issue to evaluate **(B)** if/when a no-key web master or a gas-sponsored relayer becomes a requirement.

> ⚠️ **Adversarial security review (codex, 2026-06-02) — (A) is the right direction but NOT sound as written.** Full findings + a required-changes checklist: [`wire-real-paths-security-review.md`](wire-real-paths-security-review.md). The `msg.sender`-bound claim holds for *post-bootstrap* writes, but the review found:
> - **[CRITICAL]** `registerFirstMasterDevice` is unauthenticated first-call-wins → **front-runnable operator lockout** (`SidecarRegistry.sol:100-123`). Needs an on-chain first-master authorization proof.
> - **[HIGH]** `registerAgentDevice` / `revokeAgentDevice` are `msg.sender`-only — **no K11** (`SidecarRegistry.sol:214-251`). A compromised master EVM key binds rogue agents with no biometric, contradicting `arch.md:608-612`.
> - **[HIGH]** add-master K11 challenge **omits** `newActorOmni` + K11 cred/pubkey/attestation (`SidecarRegistry.sol:167-193`) → assertion reuse with substituted params.
> - **[HIGH]** "the phone holds the key" = a **software secp256k1 root** (Keychain/biometric-ACL, not SE-sealed) — weaker than the K11 hardware promise; must be modelled as a first-class key.
> - **[HIGH]** single global `operatorMasterWallet` (`SidecarRegistry.sol:66`) ⇒ the **multi-device + recovery story is incomplete**.
> - **[HIGH]** browser→host **delegation needs a native confirmation** that re-derives the K11 challenge + renders calldata (confused-deputy otherwise).
>
> Net: **"no contract work" is wrong** — (A) requires the review's hardening (bootstrap auth, K11 on agent bind, full-intent challenges, a precise multi-device sender model, a native delegation-confirmation protocol) before it ships. (B) stays unsafe until the same full-intent K11 binding lands on **every** path. A non-custodial relayer under (A) is impossible without meta-tx/ERC-4337 (EIP-2771 sponsors gas but still needs the secp key).

### Decision (2026-06-02): ERC-4337 P-256 smart-account master — CONFIRMED

Neither plain (A) nor plain (B). The master becomes an **ERC-4337 smart-contract account** whose `validateUserOp` verifies a **P-256 (K11/passkey) signature**; a **bundler** broadcasts UserOps and an optional **paymaster** sponsors gas. Why this is the chosen path:

- **Removes the software-secp256k1 root** (the HIGH finding): every client authenticates UserOps with the **SE-sealed K11/P-256 passkey alone** — no exportable secp256k1 key on phone, browser, or desktop. The hardware-sealed promise the rest of arch.md makes actually holds.
- **Key-free + relayer in one** (settles the relayer question): a bundler broadcasts and a paymaster can pay gas → no HEI on device, and **no custodial relayer** (the only relayer that worked under (A)).
- **`SidecarRegistry.master` = the smart-account address** — stable across device swaps; the account natively supports **multiple authorized passkeys + quorum / social recovery**, which fixes the single-`operatorMasterWallet` multi-device gap (HIGH finding).
- **Web and mobile are symmetric full masters** — each registers its own passkey as an account signer and signs UserOps directly. The browser→host "delegate broadcast" hop (and its confused-deputy risk) **disappears**.
- **Reuses existing crypto** — AgentKeys already verifies P-256 on chain (`K11Verifier.sol` + its P256 verifier), so the account's validation reuses it; no new primitive.

**Carried items — now all addressed (status as of #171/#168/#166):**
- **Authenticated first-master bootstrap** (CRITICAL) → **done in #166** (sender-bound K11 self-attestation). Under ERC-4337 the deterministic CREATE2 account address (from the passkey pubkey) is known pre-deploy, so the self-attestation binds it (chain plan E7).
- **Full-intent binding** → **structural** — the passkey signs the EntryPoint's `userOpHash`, which commits `sender+nonce+callData+gas+paymaster` bound to `entryPoint+chainId`; since `callData` *is* the function intent, a bundler/MITM cannot substitute args. The hand-rolled per-op `keccak256` challenges (and the two omitted-field bugs the review found) are **retired** (chain plan E3).
- **Heima infra** → **live**: EntryPoint v0.7 + `P256AccountFactory` deployed on Heima mainnet (#171 E1). Heima is **Cancun** (#168) → PUSH0/transient-storage fine; the `evm_version="london"` pin is only a `forge script` header workaround (deploy via `forge create`). P-256 verify is a **pure-Solidity verifier** (~707k gas; no RIP-7212; no chain change).
- **Agent bind/revoke** → passkey-gated structurally (master = account, #171 E3/E4); **replay** via the EntryPoint 2D nonce.

---

## 12. WASM lift scope

The portable core (§0.5) compiles to WASM for the web host. **In scope:** the master-plane orchestration — broker calls, ceremony state machines, cap handling, onboarding-state aggregation, and **building + passkey-signing the ERC-4337 UserOp**. **Out of scope:** the ERC-4337 account/EntryPoint/factory/paymaster/bundler infra — **landed in #171**; the web core just *consumes* it — and any secp256k1 key custody.

**Concretely:**
- **`agentkeys-core` carve-out (X0, prerequisite):** lift the master-plane functions into `agentkeys-core` with a host-agnostic API (no `axum` / daemon deps), so the daemon, WASM, and mobile-UniFFI shells all bind the same surface. `init_flow` already lives there — extend it with pairing + cap + onboarding-state.
- **`wasm-bindgen` exports (X1):** email auth (`start`/`verify`/`status`), wallet attestation (`start`/`verify`), pairing (`claim`/`pending`/`ack`), cap-mint, `onboarding/state` aggregation. Build a `pkg` via `wasm-pack`; smoke-test one call (email start) from a throwaway page.
- **`CoreBackend` (X2):** a new `AgentKeysClient` implementation (next to `empty`/`daemon`) that calls the WASM exports instead of HTTP-to-daemon. `NEXT_PUBLIC_AGENTKEYS_BACKEND=core`. The existing UI works unchanged — same interface.
- **WebAuthn interop (X3):** the core asks the JS host to run `navigator.credentials.{create,get}`; the assertion flows back into the core (K11 enroll + assert).
- **Chain-write submission (X4):** **ERC-4337, landed #171** — the core builds the UserOp + the JS host passkey-signs the `userOpHash` (`navigator.credentials.get`), then the daemon/broker relays it to the **broker-gated bundler** (`scripts/erc4337-bundler.sh`, unsafe-mode) or `EntryPoint.handleOps`. Reference signer: the Rust `agentkeys k11 software-{keygen,sign}` (`crates/agentkeys-cli/src/k11_webauthn.rs`); reference flow: `harness/erc4337-master-e8.sh` (passkey-only, green on Heima mainnet). The account/EntryPoint/factory/paymaster are **live** (#171 E1/E2/E6) — no longer gated.

**Constraints / risks:**
- `reqwest` has a WASM target (browser `fetch`) → the **broker must allow CORS for the web origin** (`data-model.md:399` open question — prod origin `https://parent.{operator}.litentry.org`).
- Async via `wasm-bindgen-futures`.
- Bundle size: core + `reqwest` + crypto in WASM — measure, lazy-load the WASM chunk, tree-shake.
- No `cast` / secp256k1 signing in WASM (§11) → chain writes go out as **ERC-4337 UserOps** signed by the P-256 passkey and broadcast by a bundler.

**Shared investment:** X0–X3 are the *same* core the future mobile UniFFI shell binds — not web-only spend. That is the consistency payoff: build the brain once, host it as WASM (web) now and as a native lib (mobile) later.
