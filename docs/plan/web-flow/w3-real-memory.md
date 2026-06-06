# W3 — memory through the real worker (daemon ui-bridge)

**Status:** plan (pre-code). Phase **W3** of [`wire-real-paths.md`](wire-real-paths.md) §6, picked after W1 (onboarding identity + session) merged in #187.
**Goal:** replace the daemon ui-bridge's **in-memory** master-memory store (`/v1/master/memory{,/plant}` → `RwLock<HashMap>`) with the **real** `cap-mint → STS relay → memory worker → S3` chain — the same chain the agent-side wire demo (`phase1-wire-demo.sh`) and the MCP server (via `agentkeys-backend-client`) already exercise.
**Reference implementation (do not re-invent):** [`crates/agentkeys-mcp-server/src/backend/http_backend.rs`](../../../crates/agentkeys-mcp-server/src/backend/http_backend.rs) `memory_put`/`memory_get` + `sts_headers`, and the shared STS primitive `agentkeys_provisioner::fetch_via_broker_default_ttl`.

---

## 1. Resolved memory-ownership model — **master-self** (the key decision)

The earlier §5c claim — "the master plants and the agent-side demo read the **same S3 bytes**" — is **not achievable under the isolation invariants**, and W3 corrects it:

- **Cap-mint binds to one actor.** The broker enforces `device.actor_omni == req.actor_omni` ([`handlers/cap.rs:268`](../../../crates/agentkeys-broker-server/src/handlers/cap.rs)); the master's session can therefore mint memory caps **only for its own `actor_omni` (`O_master`)** → it can physically only write `bots/<O_master>/memory/…`. It cannot write an agent's prefix.
- **Scope is always checked.** `AgentKeysScope.isServiceInScope(operator, actor, service)` is verified at **both** the broker (`cap.rs:275`) and the worker ([`verify.rs:212`](../../../crates/agentkeys-worker-creds/src/verify.rs)) with **no `operator==actor` bypass**. So even for its own memory the master needs an on-chain scope entry `(O_master, O_master, memory:<ns>)`.
- **Therefore agent-inheritance is a different actor's write.** A bot reading the master's curated memory is a *cross-actor* read, denied by the per-actor IAM PrincipalTag (layers 3/4, issue #90). Giving an agent that memory means **writing it under the agent's own `actor_omni` with the agent's own cap** — which requires the agent to exist (pairing) = **W4**.

**Decision:** W3 ships the master planting/reading **its own** `memory:<ns>` under `O_master`. Agent-inheritance (seed-at-pairing under the agent's cap) is **deferred to W4** and noted in §5c + arch.md. The `cap→STS→worker→S3` plumbing built here is reused verbatim by the agent-scoped path — it is the correct foundation regardless of model.

---

## 2. The real chain (what the daemon must do per entry)

For each planted entry with namespace `ns` (service string `memory:<ns>` via `memoryService(ns)`, arch.md §896 — a bare `memory` fails cap-mint):

1. **cap-mint** — `POST {broker}/v1/cap/memory-put`, `Bearer = master J1`, body `{ operator_omni: O_master, actor_omni: O_master, service: "memory:<ns>", device_key_hash, ttl_seconds }` → `CapToken` (opaque JSON).
2. **STS relay** — `agentkeys_provisioner::fetch_via_broker_default_ttl(broker, master_J1, MEMORY_ROLE_ARN, REGION)` → `AwsTempCreds` → the three `X-Aws-*` headers. The master J1's `omni_account == O_master`, so `/v1/mint-oidc-jwt` tags the web-identity token with `agentkeys_actor_omni=O_master` and `AssumeRoleWithWebIdentity` returns creds scoped by the bucket policy to `bots/<O_master>/memory/*`.
3. **worker put** — `POST {memory_url}/v1/memory/put` body `{ cap, plaintext_b64, namespace: ns }` + the `X-Aws-*` headers → `{ ok, s3_key, envelope_size }`. S3 object: `bots/<O_master>/memory/memory:<ns>.enc`.

List/read mirrors it: cap-mint `/v1/cap/memory-get` → STS → `POST {memory_url}/v1/memory/get` `{ cap, namespace }` → `{ ok, plaintext_b64 }`.

---

## 3. Daemon implementation

### 3.1 New config (no hardcoding — env + CLI per repo policy)
`UiBridgeState` gains `memory_url`, `memory_role_arn`, `region: String`. `build_state(...)` takes them; `main.rs` adds `--memory-url` / `--memory-role-arn` / `--region` (env fallbacks `AGENTKEYS_MEMORY_URL` / `MEMORY_ROLE_ARN` / `REGION`, sourced from `operator-workstation.env`); `dev.sh` threads them through.

### 3.2 New dependency
Add `agentkeys-provisioner = { workspace = true }` to `crates/agentkeys-daemon/Cargo.toml` for `fetch_via_broker_default_ttl` (the daemon already has `reqwest`, `serde_json`, `agentkeys-core`).

### 3.3 Real chain module
New `crates/agentkeys-daemon/src/master_memory.rs` (or a section of `ui_bridge.rs`): `async fn put_real(...)` / `get_real(...)` mirroring `http_backend.rs` (cap-mint POST → `fetch_via_broker_default_ttl` → worker POST). Worker body shapes mirror [`mcp-server/src/backend/memory.rs`](../../../crates/agentkeys-mcp-server/src/backend/memory.rs).

### 3.4 Handler rework — real when configured, in-memory fallback otherwise
`plant_master_memory` / `list_master_memory`: if the real path is configured **and** an onboarding session is present (`memory_url` + `memory_role_arn` set + `onboarding_session.j1` + `omni` available) → real chain; **else** the current in-memory `HashMap` (so no-infra dev still works, non-breaking — this is the daemon's own dev fallback, unrelated to the MCP backend that #207 removed). Surface which path ran in the response + a `tracing::warn!` on fallback (same loud-downgrade discipline as `BackendClient::sts_headers`).

### 3.5 `device_key_hash` — the integration constraint to handle
cap-mint sends `device_key_hash`; the broker resolves the on-chain device by it and checks `actor_omni == O_master` + `roles & CAP_MINT`. **So the daemon's K10 (whose hash it sends) MUST be the on-chain-registered master device.** Sourcing: derive from the daemon's K10 (currently `device_pubkey` in `ui_bridge.rs:166`; add the hash). **Constraint for the bootstrap (§4):** the K10 the daemon uses for cap-mint must be the same key registered on-chain. (W2 will make the daemon register its own K10 from the browser; until then the bootstrap registers the daemon's K10 explicitly.)

---

## 4. Bootstrap — folded into onboarding by #196 (was: two manual CLI steps)

> **Operator runbook:** [`docs/operator-runbook-web-memory.md`](../../operator-runbook-web-memory.md) — the single doc to follow; it drives the idempotent `harness/web-memory-bootstrap.sh` (build → contracts → fund → register → broker proof → web-demo guidance).
>
> **Updated for #195 + #196.** The two manual steps below are no longer the operator path. The master device registration is now submitted **automatically on K11-finish** by the daemon ui-bridge (issue #196), and the self-scope step is **retired** by #195. Only the one-time local gas subsidy remains operator-run.

The master must be on-chain with `CAP_MINT` (the self-scope requirement is gone — see below). Using the existing (old-model) live contracts:

```bash
# (one-time, local, operator-run) Fund the master's register-tx gas payer.
#   Idempotent — skips if already ≥ threshold. NOT a broker endpoint / not
#   auto-on-login (a broker auto-fund every login would be a Sybil drain).
bash scripts/heima-fund-master.sh            # deployer → master, ~0.2 HEI

# Register: AUTOMATIC. On K11-finish the daemon ui-bridge shells out to
# harness/scripts/heima-register-first-master.sh (--register-master-script),
# registering the device under the SESSION omni (operator == actor == O_master),
# signed by the local deployer key. chain_tx_hash is un-stubbed; GET
# /v1/onboarding/state reports chain: master-registered. No manual CLI step.
```

**Why the self-scope step (`heima-scope-set.sh --self`) is gone:** #195 makes the broker (`cap.rs`) and worker (`verify.rs`) **skip** `isServiceInScope` when `operator == actor` — the master accessing its own data classes is not gated by scope (scope gates *agents*). So `(O_master, O_master, memory:<ns>)` no longer needs an on-chain grant. The `--self` scope mode was therefore never added; the device registration (§3.5 / #196) is the **only** remaining on-chain prerequisite for master-self memory.

**`device_key_hash` (§3.5):** the daemon registers under the session omni and uses the device hash the register script returns (`keccak(operator_omni)` on the web path), so the hash sent in cap-mint always matches the on-chain device — no manual `--master-device-key-hash` needed (it stays as a fallback/override).

---

## 5. Testing & parity

- **Unit (daemon):** the in-memory fallback path keeps its existing tests (dedup, empty-by-default). The real path is selected only when fully configured, and a partial config (`memory_url` without `memory_role_arn`) **fails loud** (mirrors `http_backend::sts_headers`). #196 adds tests for the register shell-out parse (success / idempotent-skip / non-zero-exit) and the `chain` onboarding field (`ui_bridge.rs` tests).
- **E2E procedure (#196 — no manual bootstrap):** after login + the one-time `heima-fund-master.sh`, plant from the web Memory page → registration happens automatically on K11-finish → assert the S3 object `bots/<O_master>/memory/memory:<ns>.enc` exists; read back → same bytes. Cross-check via the live object + `agentkeys hook memory-inject` is **not** valid here (that reads the *agent's* prefix — different actor; see §1).
- **Harness (#196):** `harness/v2-stage3-demo.sh` step 16 asserts a master-self cap mints with **no** scope grant (proves #195 skip + #196 device), and step 17 asserts a cross-actor cap still returns `ServiceNotInScope` (proves the skip is master-self-only). The live register makes both runnable.

---

## 6. Deferred / out of scope (called out per plan-completion policy)

- **Agent-inheritance of master-curated memory → W4.** Needs the agent actor (pairing) + a seed written under the *agent's* cap. The §5c "same bytes" story lives there.
- **Master on-chain registration → SHIPPED by #196 (old-model interim).** The daemon ui-bridge shells out to `heima-register-first-master.sh` on K11-finish (registers under the session omni, deployer key signs), un-stubbing `chain_tx_hash`. The **web-native ERC-4337 register UserOp** (W2 / chain-plan E7 — passkey signs the register as a UserOp, `msg.sender == P256Account`) remains **cutover-blocked** on the thinned account-auth registry not being deployed to mainnet; #196 is the interim until that lands.
- **Lifting `namespace` into a SIGNED CapPayload field → M4** (today it's a request-body field, per `mcp-server/src/backend/memory.rs`).

---

## 7. Source-of-truth updates landed with the code
- Correct `wire-real-paths.md` §5c (drop the cross-actor "same S3 bytes" claim; point agent-inheritance at W4).
- arch.md note: the master is an actor with its own `memory:<ns>` namespace; per-actor isolation means master memory ≠ agent memory (no implicit inheritance).
