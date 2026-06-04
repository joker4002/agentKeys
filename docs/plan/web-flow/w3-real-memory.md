# W3 — memory through the real worker (daemon ui-bridge)

**Status:** plan (pre-code). Phase **W3** of [`wire-real-paths.md`](wire-real-paths.md) §6, picked after W1 (onboarding identity + session) merged in #187.
**Goal:** replace the daemon ui-bridge's **in-memory** master-memory store (`/v1/master/memory{,/plant}` → `RwLock<HashMap>`) with the **real** `cap-mint → STS relay → memory worker → S3` chain — the same chain the agent-side wire demo (`phase1-wire-demo.sh`) and the MCP `http_backend` already exercise.
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
`plant_master_memory` / `list_master_memory`: if the real path is configured **and** an onboarding session is present (`memory_url` + `memory_role_arn` set + `onboarding_session.j1` + `omni` available) → real chain; **else** the current in-memory `HashMap` (so `--light`/no-infra dev still works, non-breaking). Surface which path ran in the response + a `tracing::warn!` on fallback (same loud-downgrade discipline as `http_backend::sts_headers`).

### 3.5 `device_key_hash` — the integration constraint to handle
cap-mint sends `device_key_hash`; the broker resolves the on-chain device by it and checks `actor_omni == O_master` + `roles & CAP_MINT`. **So the daemon's K10 (whose hash it sends) MUST be the on-chain-registered master device.** Sourcing: derive from the daemon's K10 (currently `device_pubkey` in `ui_bridge.rs:166`; add the hash). **Constraint for the bootstrap (§4):** the K10 the daemon uses for cap-mint must be the same key registered on-chain. (W2 will make the daemon register its own K10 from the browser; until then the bootstrap registers the daemon's K10 explicitly.)

---

## 4. Bootstrap (W3 prerequisites — documented, CLI, no cutover needed)

The master must be on-chain with `CAP_MINT` **and** self-scoped, using the existing (old-model) live contracts:

```bash
# 1. Register the master device on-chain (grants CAP_MINT|RECOVERY|SCOPE_MGMT).
#    The device key MUST be the K10 the daemon will use for cap-mint (§3.5).
bash scripts/heima-register-first-master.sh   # see script for device-key/omni args

# 2. Self-grant the master's own memory namespace scope (operator == actor == O_master).
#    Sets (O_master, O_master, memory:<ns>) so isServiceInScope passes at broker + worker.
bash scripts/heima-scope-set.sh --self --services memory:travel   # --self flag added in this PR
```

`heima-scope-set.sh` is currently agent-oriented (`--agent <label>` → child omni); W3 adds a `--self` mode that targets the operator's own `O_master` as the actor. (`setScopeWithWebauthn(operator, actor, …)` already accepts any actor; only the CLI wrapper assumes a child.)

---

## 5. Testing & parity

- **Unit (daemon):** the in-memory fallback path keeps its existing tests (dedup, empty-by-default). Add a test that the real path is selected only when fully configured, and that a partial config (`memory_url` without `memory_role_arn`) **fails loud** (mirrors `http_backend::sts_headers`).
- **E2E procedure (documented):** with the bootstrap done, plant from the web Memory page → assert the S3 object `bots/<O_master>/memory/memory:<ns>.enc` exists; read back → same bytes. Cross-check via the live object + `agentkeys hook memory-inject` is **not** valid here (that reads the *agent's* prefix — different actor; see §1).
- **Harness (W6 later):** folds into `harness/web-wire-demo.sh` (plant→read same bytes under `O_master`).

---

## 6. Deferred / out of scope (called out per plan-completion policy)

- **Agent-inheritance of master-curated memory → W4.** Needs the agent actor (pairing) + a seed written under the *agent's* cap. The §5c "same bytes" story lives there.
- **Web-native master on-chain registration → W2 (chain-plan E7).** Blocked on the registry cutover; until then the daemon's K10 is registered out-of-band via the CLI bootstrap (§4).
- **Lifting `namespace` into a SIGNED CapPayload field → M4** (today it's a request-body field, per `mcp-server/src/backend/memory.rs`).

---

## 7. Source-of-truth updates landed with the code
- Correct `wire-real-paths.md` §5c (drop the cross-actor "same S3 bytes" claim; point agent-inheritance at W4).
- arch.md note: the master is an actor with its own `memory:<ns>` namespace; per-actor isolation means master memory ≠ agent memory (no implicit inheritance).
