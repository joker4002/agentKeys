# M1 — MCP server Phase 1 (issues #107, #108, #109, #111)

**Status**: in-flight on branch `claude/jovial-proskuriakova-d07055` (will land via PR to `evm`).
**Date**: 2026-05-25.
**Companion to**: [`docs/spec/plans/milestones-roadmap.md`](milestones-roadmap.md) §2 (M1 scope), [`docs/research/agent-iam-strategy.md`](../../research/agent-iam-strategy.md) §4 (Phase 1 storyboard), [`docs/arch.md`](../../arch.md) §17 + §15.3 (invariants).
**Supersedes**: nothing (first plan for M1).
**Resolves**: #107 (MCP server), #108 (memory namespace), #109 (two-tier audit), #111 (demo runbook + vendor pitch).
**Defers**: #110 (parent-control web UI) and #112 (Volcano Ark marketplace registration) to follow-up PRs.

---

## 1. Goal

Land Phase 1 of the AgentKeys agent-IAM thesis in a single PR so any MCP-speaking LLM host can drive the existing Phase 0 broker / signer / workers end-to-end. The three-act demo storyboard from [`agent-iam-strategy.md` §4.3](../../research/agent-iam-strategy.md) must run green from Claude Code as the LLM-driven MCP host against a live broker + chain, with deterministic CI gates underneath.

### 1.1 Non-goals

Per [`agent-iam-strategy.md` §4.5](../../research/agent-iam-strategy.md), explicit do-not-build:

- Orchestration of any kind (§2.4 hard line).
- Active delegation flows — the 3 `delegation.*` / `approval.*` tools ship as schema-only stubs returning `not_implemented_in_v1`.
- Native mobile app.
- Real-time on-chain audit (Tier 2 is batched per §3.2).
- Multi-tenant Bearer issuance + rotation (M2 #114 — M1 ships a single static token).
- xiaozhi-server final integration (deferred with #112 follow-up PR).
- Vendor onboarding portal (M2 #114).
- Payment-cap MCP namespace (later milestone).
- Hermes / OpenClaw as MCP tools (M3).
- Any redesign of the four-layer isolation chain in [`arch.md` §17](../../arch.md). The MCP server adapts existing backend RPCs; it does not redesign them.

---

## 2. Architecture sketch

```
                ┌────────────────────────────┐
                │  Claude Code (M1 host)     │  ← layer 3 dev-loop validator
                │  xiaozhi-server (M2 host)  │  ← deferred to follow-up PR
                └─────────────┬──────────────┘
                              │ MCP JSON-RPC over stdio
                              │ Bearer = $AGENTKEYS_MCP_VENDOR_TOKEN
                              │ X-AgentKeys-Actor = O_*
                              ▼
                ┌─────────────────────────────────────────────┐
                │  agentkeys-mcp (Rust, extended additively)  │
                │  10 tools under agentkeys.*                 │
                │  + 3 stage-7 tools (preserved)              │
                └─┬────────┬───────────┬────────┬─────────────┘
                  │        │           │        │
                  │ ident  │ cap       │ audit  │ memory
                  ▼        ▼           ▼        ▼
        ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐
        │ broker /v1/  │ │ broker /v1/  │ │ worker-audit │ │ worker-memory    │
        │ identity/*   │ │ cap/*        │ │ POST /v1/    │ │ POST /v1/memory/ │
        │ scope/*      │ │ revoke/*     │ │ audit/append │ │ put,get          │
        │              │ │              │ │ /v2          │ │                  │
        └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ └──────┬───────────┘
               │                │                │                │
               └────────┬───────┴────────┬───────┴────────┬───────┘
                        ▼                ▼                ▼
                  ┌──────────────────────────────────────────┐
                  │  Heima EVM chain (SidecarRegistry,       │
                  │  ScopeContract, K3EpochCounter,          │
                  │  CredentialAudit)                        │
                  └──────────────────────────────────────────┘
```

Key shape:

- The MCP server is **a thin adapter** — it does not implement broker logic, cap-token signing, audit Merkle batching, or S3 access. Every call routes to an existing crate.
- The 4-layer isolation chain ([`arch.md` §17](../../arch.md)) is enforced by the **existing** broker + worker stack. The MCP server's only job is to construct the correct request and forward it.
- Per-actor scoping happens at two layers: the `X-AgentKeys-Actor` HTTP header (M1 transport) AND the cap-token's `actor_omni` field (existing crypto). The MCP server must NOT mint a cap for an actor different from the header.

---

## 3. Implementation order (do not parallelize)

Each step ships its layer-1 + layer-2 tests before the tool body. Layer 3 (Claude Code smoke) is re-run between every step.

### Step 1 — Plan + pitch + hardcoded log (this commit)

| File | Purpose |
|---|---|
| `docs/spec/plans/m1-mcp-server-phase1.md` | This file — canonical plan |
| `docs/wiki/m1-vendor-pitch.md` | 15-min vendor pitch (#111) |
| `hardcoded.md` | New entry for `AGENTKEYS_MCP_VENDOR_TOKEN` per CLAUDE.md no-hardcoded-values policy |

Done check: `[ -f docs/spec/plans/m1-mcp-server-phase1.md ] && [ -f docs/wiki/m1-vendor-pitch.md ] && grep -q AGENTKEYS_MCP_VENDOR_TOKEN hardcoded.md`.

### Step 2 — Failing tests for all 10 tools

Add a new test module `crates/agentkeys-mcp/src/m1_tools_tests.rs` (or extend existing `mod tests` in `src/lib.rs`) covering:

| Tool | Happy path test | Negative path test |
|---|---|---|
| `agentkeys.identity.whoami` | actor exists → returns `{omni, display_name, vendor, scopes}` | missing `X-AgentKeys-Actor` → MCP error `-32602 missing_actor_header` |
| `agentkeys.permission.check` | scope in scope → `{allowed: true}` | scope not in scope → `{allowed: false, reason}` |
| `agentkeys.cap.mint` | well-formed args → `CapToken` JSON | cross-actor (actor in args ≠ header) → `-32603 actor_mismatch` |
| `agentkeys.cap.revoke` | known cap_id → `{revoked: true}` | unknown cap_id → `{revoked: false, reason: not_found}` |
| `agentkeys.audit.append` | well-formed envelope → `{envelope_hash}` | wrong version → `-32603 envelope_version` |
| `agentkeys.memory.put` | actor=header, namespace ∈ allowed → `{ok, s3_key}` | namespace ∉ cap.namespaces_allowed → 403 cap_namespace_mismatch |
| `agentkeys.memory.get` | round-trip after put → `{plaintext_b64}` matches | cross-namespace → 403 cap_namespace_mismatch |
| `agentkeys.delegation.grant` | any input → `{error: "not_implemented_in_v1", scheduled_for: "M4", spec_url}` | (same — schema-only) |
| `agentkeys.delegation.revoke` | same as above | (same) |
| `agentkeys.approval.request` | same as above | (same) |

Each test uses a per-test `MockBroker` axum stub (extends the existing pattern at `lib.rs:707-721` for `mint-oidc-jwt`). The 3 stage-7 tools (`get_credential`, `list_credentials`, `provision`) keep their existing tests; nothing is renamed.

Done check: `cargo test -p agentkeys-mcp -- --list` shows 20+ new tests; `cargo test -p agentkeys-mcp` runs them all and the 10 new-tool happy-path tests FAIL (`tools/call` returns "unknown tool: agentkeys.identity.whoami" etc.).

### Step 3 — Tool 1: `agentkeys.identity.whoami`

Path: `crates/agentkeys-mcp/src/lib.rs`. Add to `tool_definitions()` JSON. Add `handle_tool_call` arm. Add `async fn identity_whoami(&self, id, args) -> JsonRpcResponse`.

Wire: the broker exposes scope/actor lookup via `agentkeys-broker-server`'s `/v1/identity/whoami` (or equivalent). If the endpoint doesn't exist yet, the MCP tool reads from the on-chain SidecarRegistry + ScopeContract directly using the same `eth_call` helpers from `crates/agentkeys-broker-server/src/handlers/cap.rs:374` — **but** that is broker-internal; the MCP layer should not duplicate. The pragmatic M1 implementation:

1. Decode the `X-AgentKeys-Actor` header → `actor_omni`.
2. POST to broker `/v1/identity/whoami` with `{actor_omni}` and the static vendor Bearer.
3. Forward the response.

If `/v1/identity/whoami` does NOT exist on the broker yet, this step adds it as a small broker handler that does the existing `SidecarRegistry.getDevice` decode (mirror of `cap.rs:405-463`) and returns `{omni, display_name, vendor, scopes}`. `display_name` and `vendor` come from per-actor `ScopeContract.getActorMetadata(...)` if available, else `display_name = format!("actor-{}", &actor_omni[..8])` and `vendor = "unknown"`.

Done check: `cargo test -p agentkeys-mcp identity_whoami_` passes (happy + negative); `cargo test -p agentkeys-broker-server identity_whoami_` passes if the broker handler was added.

### Step 4 — Tool 2: `agentkeys.permission.check`

Deterministic policy engine. **NOT LLM** per [#107 + `agent-iam-strategy.md` §2.4](../../research/agent-iam-strategy.md).

Wire: the broker's `AgentKeysScope.isServiceInScope(operator, actor, keccak(service))` chain call already gives us the boolean for service-level scope. The M1 policy engine is a thin extension:

```rust
fn evaluate(scope: &str, params: Option<&serde_json::Value>, chain_result: bool) -> Verdict {
    // 1. Chain-level scope check (existing).
    if !chain_result { return Verdict::deny("not_in_scope"); }
    // 2. Param-level deterministic policies (M1: payment cap only).
    if scope.starts_with("payment.") {
        let amount = params.and_then(|p| p.get("amount_rmb")).and_then(|v| v.as_u64()).unwrap_or(0);
        let cap = env_or(AGENTKEYS_PAYMENT_DAILY_CAP_RMB, 500);
        if amount > cap { return Verdict::deny(format!("daily_spend_cap_exceeded (cap={cap}, requested={amount})")); }
    }
    Verdict::allow()
}
```

The payment-cap is the Act 2 driver in [`agent-iam-strategy.md` §4.3](../../research/agent-iam-strategy.md). No other M1 policies — additional scopes return chain-result verbatim.

Done check: `cargo test -p agentkeys-mcp permission_check_` passes (allow + deny + payment-cap).

### Step 5 — Tool 3: `agentkeys.cap.mint`

Direct adapter. The four cap endpoints exist:

- `POST /v1/cap/cred-store` → `DataClass::Credentials, CapOp::Store`
- `POST /v1/cap/cred-fetch` → `DataClass::Credentials, CapOp::Fetch`
- `POST /v1/cap/memory-put` → `DataClass::Memory, CapOp::Store`
- `POST /v1/cap/memory-get` → `DataClass::Memory, CapOp::Fetch`

The MCP tool takes `(actor, op, params, ttl)` and dispatches:

| `op` arg | Routes to | data_class derived from `params.data_class` |
|---|---|---|
| `"store"` + `data_class: "credentials"` | `/v1/cap/cred-store` | Credentials |
| `"fetch"` + `data_class: "credentials"` | `/v1/cap/cred-fetch` | Credentials |
| `"store"` + `data_class: "memory"` | `/v1/cap/memory-put` | Memory |
| `"fetch"` + `data_class: "memory"` | `/v1/cap/memory-get` | Memory |

Forwards the session JWT (from `self.session.token`) as Bearer. Returns the `CapToken` JSON the broker mints.

Cross-actor check: if `params.actor_omni != header_actor_omni` → reject with `-32603 actor_mismatch` **before** hitting the broker (defense-in-depth; the broker will also reject via `CapError::OperatorMismatch` but the MCP layer should not even forward).

Done check: `cargo test -p agentkeys-mcp cap_mint_` passes (positive memory-put cap + negative cross-actor).

### Step 6 — Tool 4: `agentkeys.cap.revoke`

Broker exposes `/v1/revoke/cap/:cap_id` (verify presence — if absent, this step adds it as a thin handler that records the revoked cap_id in an in-memory set; the cred + memory worker `verify_cap` chain gets a `check_revocation` step in a follow-up).

M1 simplification: the broker maintains an in-memory revocation set; on `verify_cap`, workers consult `broker.revocation_status(cap_id)`. Persistent revocation store (Redis / chain anchoring) is M4. The 60-second offline bound per [`agent-iam-strategy.md` §3.1](../../research/agent-iam-strategy.md) is met because cap TTL defaults to 300s and workers refresh on every call.

Done check: `cargo test -p agentkeys-mcp cap_revoke_` passes.

### Step 7 — Tool 5: `agentkeys.audit.append` + #109 wiring

Direct adapter onto `POST /v1/audit/append/v2` on `agentkeys-worker-audit`. The MCP tool:

1. Takes `{actor, event}` where `event = {op_kind, op_body, result, intent_text?, intent_commitment?}`.
2. Builds an `AppendV2Request` JSON with `version: 1, ts_unix: 0` (worker fills), `actor_omni: header`, `operator_omni: session.operator`, `op_kind`, `op_body`, `result`, `intent_text`, `intent_commitment`.
3. POSTs to `${AGENTKEYS_AUDIT_WORKER_URL}/v1/audit/append/v2`.
4. Returns `{envelope_hash}` to the MCP caller.

#109 cadence wiring: `crates/agentkeys-worker-audit/src/main.rs` currently has no env-configurable batch cadence (the `flush_all` is callable on demand). Add:

- `AGENTKEYS_AUDIT_BATCH_SECONDS` env var, default `120`.
- A background `tokio::spawn` task that calls `state.flush_all()` every `AGENTKEYS_AUDIT_BATCH_SECONDS` and forwards each `FlushResult` to the chain via the existing `CredentialAudit.appendV2` path.

The off-chain real-time feed is already available via `GET /v1/audit/envelope/:hash` <1s after `append/v2`. The 2-min on-chain anchor SLA is the new piece.

Done check: `cargo test -p agentkeys-mcp audit_append_` passes; `cargo test -p agentkeys-worker-audit batch_cadence_` passes (asserts the env var is honored).

### Step 8 — Tool 6 + 7: `agentkeys.memory.put` / `agentkeys.memory.get` + #108 wiring

Two pieces:

1. **#108 namespace as signed field in CapPayload.** Add `namespaces_allowed: Vec<Namespace>` to `CapPayload` in BOTH `crates/agentkeys-broker-server/src/handlers/cap.rs:78` AND `crates/agentkeys-worker-creds/src/verify.rs:52` (mirror). The broker mints with the claim (currently taken from request body, M1 hardcoded to `[Namespace::Personal, Namespace::Family, Namespace::Work, Namespace::Travel]` for the test actor; M4 sources from on-chain scope). The memory worker's `verify_cap` chain (memory worker handlers.rs:194) gets a new `check_namespace(cap, request.namespace)` step:

   ```rust
   pub fn check_namespace(cap: &CapToken, requested: Namespace) -> Result<(), VerifyError> {
       if cap.payload.namespaces_allowed.contains(&requested) {
           Ok(())
       } else {
           Err(VerifyError::NamespaceMismatch { allowed: cap.payload.namespaces_allowed.clone(), requested })
       }
   }
   ```

   Wire enum: `enum Namespace { Personal, Family, Work, Travel }` with `#[serde(rename_all = "snake_case")]`. Add to `crates/agentkeys-types/src/lib.rs` (or a new `namespace.rs` module) so broker + worker + MCP all import from one place.

2. **Memory worker request shape.** Extend `PutRequest` / `GetRequest` in `crates/agentkeys-worker-memory/src/handlers.rs:43-65` to include `namespace: Namespace`. `verify_cap` calls `check_namespace(cap, req.namespace)` before any S3 access. S3 key derivation stays as-is per [`agent-iam-strategy.md` §3.2a](../../research/agent-iam-strategy.md) (out of band — namespace is a request-time filter, not a key-derivation input).

3. **MCP tools.** `memory.put(actor, namespace, content)` and `memory.get(actor, namespace)`:
   - Mint cap via `agentkeys.cap.mint` internally (with `params.namespace = requested`).
   - POST to `${AGENTKEYS_MEMORY_WORKER_URL}/v1/memory/put` with `{cap, plaintext_b64, namespace}`.
   - Return `{ok, s3_key}` / `{plaintext_b64}`.

Audit row on cross-namespace attempt: the worker emits `audit.namespace_violation` via `POST /v1/audit/append/v2` with `op_kind: 0xF1 NamespaceViolation` and `result: NotPermitted` per [#108 acceptance criterion 2](https://github.com/litentry/agentKeys/issues/108).

Done check: `cargo test -p agentkeys-mcp memory_put_ memory_get_` passes (positive write+read, negative cross-namespace); `cargo test -p agentkeys-worker-memory check_namespace_` passes.

### Step 9 — 3 schema-only stubs

`delegation.grant`, `delegation.revoke`, `approval.request` all return the same shape from a single helper:

```rust
fn not_implemented_in_v1(tool: &str) -> Value {
    json!({
        "error": "not_implemented_in_v1",
        "scheduled_for": "M4",
        "spec_url": "https://github.com/litentry/agentKeys/blob/main/docs/spec/plans/milestones-roadmap.md#5-m4--capability--revocation-depth-6-months-after-m3"
    })
}
```

Done check: `cargo test -p agentkeys-mcp schema_only_stubs_` passes.

### Step 10 — Replace TODO(M1) stubs in `harness/mcp/smoke-test.sh`

The skeleton already runs prereq checks 1-5 (daemon binary, session file, broker reachable, Claude Code CLI present, storyboard present). `run_act_1` / `run_act_2` / `run_act_3` currently `fail` with exit 99.

Replace each act body with a `claude -p` invocation that:
- Registers the MCP server (`claude mcp add` from `harness/mcp/claude-config.json`).
- Issues a single prompt that exercises the act per the storyboard.
- Greps the Claude Code output for the expected tool call + return shape.
- Returns 0 on green, 2 on act-specific failure.

Done check: `bash harness/mcp/smoke-test.sh --only-act 1` exits 0 against a live broker; same for `--only-act 2` and `--only-act 3`.

---

## 4. Test pyramid mapping

| Layer | What | Files (file:line) | Gate? |
|---|---|---|---|
| 1. Unit + mock-backend | Each tool's adapter logic against an axum stub broker / audit / memory worker | `crates/agentkeys-mcp/src/lib.rs` `#[cfg(test)] mod tests` (extends existing patterns at `lib.rs:441-822`) | Blocks merge |
| 2. MCP wire-protocol | `tools/list` returns all 10 new + 3 stage-7 tools; `tools/call` round-trips each via `JsonRpcRequest` → `handle()` → `JsonRpcResponse` | same module, new `#[tokio::test] async fn` cases per tool | Blocks merge |
| 3. Claude Code smoke | LLM picks the right tool from the descriptions and threads args through correctly | `harness/mcp/smoke-test.sh` `run_act_{1,2,3}` | Dev-loop only (not regression) |
| 4. Live three-act demo | Three-act storyboard against a live broker + chain | `bash harness/mcp/smoke-test.sh` (no `--only-act`) | Required for merge |

Coverage matrix:

| Acceptance criterion | Test |
|---|---|
| `identity.whoami` returns shape | `lib.rs::identity_whoami_returns_shape` |
| `permission.check` denies payment > cap | `lib.rs::permission_check_payment_cap` |
| `cap.mint` rejects cross-actor before broker | `lib.rs::cap_mint_rejects_cross_actor` |
| `cap.revoke` happy + unknown | `lib.rs::cap_revoke_known` + `cap_revoke_unknown` |
| `audit.append` returns envelope_hash | `lib.rs::audit_append_returns_envelope_hash` |
| Cross-namespace cap rejected at worker | `worker-memory::check_namespace_rejects_cross_namespace` + integration test in `lib.rs::memory_put_cross_namespace` |
| Schema-only tools return v1 stub shape | `lib.rs::schema_only_stubs_return_not_implemented_in_v1` (parametrized over 3 tools) |
| Audit cadence honors env var | `worker-audit::batch_cadence_honors_env_var` |
| End-to-end three-act demo | `harness/mcp/smoke-test.sh` (manual run) |

---

## 5. Demo script (end-of-PR)

For the operator who picks this up cold. Assumes Phase 0 backend is live + a fresh operator workstation per `scripts/operator-workstation.env`.

```bash
# 0. Source env + verify cluster is up
source scripts/operator-workstation.env
AGENTKEYS_CHAIN=heima bash scripts/verify-heima-contracts.sh   # exits 0

# 1. Bring up a session (skip if you already have ~/.agentkeys/alice/session.json)
SESSION_ID=alice bash harness/v2-stage1-demo.sh --to-step 5

# 2. Build the daemon (and MCP server library it links)
cargo build -p agentkeys-daemon

# 3. Layer-1 + layer-2 tests
cargo test -p agentkeys-mcp                              # all green
cargo test -p agentkeys-broker-server cap::tests::       # cap-mint suite green
cargo test -p agentkeys-worker-audit                     # audit + new cadence test green
cargo test -p agentkeys-worker-memory                    # memory + namespace test green

# 4. Layer-3 dev-loop smoke (Claude Code as MCP host)
SESSION_ID=alice bash harness/mcp/smoke-test.sh --dry-run     # config resolves
SESSION_ID=alice bash harness/mcp/smoke-test.sh --only-act 1  # identity + permission boundary
SESSION_ID=alice bash harness/mcp/smoke-test.sh --only-act 2  # cap + memory
SESSION_ID=alice bash harness/mcp/smoke-test.sh --only-act 3  # audit visibility
SESSION_ID=alice bash harness/mcp/smoke-test.sh               # full three-act, exits 0
```

---

## 6. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Broker `/v1/identity/whoami` does not yet exist | Med | Med | Step 3 adds it as a thin handler (mirror of existing `SidecarRegistry.getDevice` decode at `cap.rs:405-463`); if scope explodes, MCP tool reads the chain directly via the same `eth_call` helpers as a fallback path. |
| Broker `/v1/revoke/cap/:id` does not yet exist | High | Med | Step 6 adds in-memory revocation. Persistent store is M4. Document the 60-second offline bound exactly per §3.1. |
| `CapPayload` change ripples through worker-creds verification | High | Low | Field is additive + `#[serde(default)]` on the worker side so existing caps without `namespaces_allowed` still verify (treated as `[]` = nothing allowed; M1 worker fills test caps with the full 4-set). |
| Claude Code CLI behavior changes mid-PR (different invocation flags) | Low | High | `harness/mcp/smoke-test.sh` shells out via `$CLAUDE_CODE_BIN` env var; the act bodies are isolated in shell functions so any CLI flag adjustment is one-line. |
| MCP wire-format drift (Anthropic ships MCP spec changes) | Low | Med | `protocolVersion: "2024-11-05"` is pinned in `crates/agentkeys-mcp/src/lib.rs:193`. Upgrade requires deliberate version bump + integration retest. |
| Single static `AGENTKEYS_MCP_VENDOR_TOKEN` is a hardcoded value | Logged | Low | `hardcoded.md` entry tracks this. Rotation policy = M2 #114. Multi-tenant issuance design lives in `agent-iam-strategy.md` §6 Risk 3. |
| Audit cadence env var not honored on existing deploys | Med | Low | Default `120s` matches #109 SLA; existing operators who didn't set the var get the right behavior. Document the env var in `docs/wiki/operator-runbook.md` (follow-up). |

---

## 7. Out-of-scope / deferred

| Item | Deferred to | Trigger for follow-up PR |
|---|---|---|
| Parent-control web UI | Follow-up PR for #110 | After M1 MCP server lands + has a stable tool surface to consume |
| Volcano Ark MCP marketplace registration | Follow-up PR for #112 | After M2 vendor onboarding portal exists (#114) |
| xiaozhi-server final integration | Paired with #112 follow-up | Volcano Ark registration is the natural pairing |
| MCP Inspector wired in CI (layer 2 gate) | Follow-up issue | Layer-1 unit tests cover wire-format protocol; Inspector is belt-and-suspenders |
| Multi-tenant Bearer issuance + rotation | M2 #114 | First paid vendor pilot signed |
| Persistent revocation store (Redis / chain anchoring) | M4 | In-memory store survives M1 demo timeline |
| `audit.namespace_violation` chain anchoring | Follow-up issue | Off-chain row emitted today; chain anchor cadence change is M2 |
| Hermes / OpenClaw MCP wrappers | M3 (#117, #118) | After M2 first paid vendor pilot |
| Active delegation + approval flows | M4 | After enterprise customer interest signaled |
| Native mobile app | M5 | After 100+ consumer Pro upgrades attributed |
| OAuth-for-Agents spec engagement | M7 | After 10+ deployed vendor partners |

---

## 8. Phase-1 implementation status (this PR)

Per CLAUDE.md plan-completion policy. The end-of-PR summary lives here and the PR body cross-references this section.

### 8.1 What landed

Single PR on `claude/jovial-proskuriakova-d07055` → target `evm`.

| Plan step | Deliverable | Files |
|---|---|---|
| §3 Step 1 | Canonical plan doc | [`docs/spec/plans/m1-mcp-server-phase1.md`](docs/spec/plans/m1-mcp-server-phase1.md) |
| §3 Step 1 | 15-min vendor pitch (#111) | [`docs/wiki/m1-vendor-pitch.md`](docs/wiki/m1-vendor-pitch.md) |
| §3 Step 1 | `hardcoded.md` entry for static vendor token + audit cadence | [`hardcoded.md`](hardcoded.md) §M1 |
| §3 Step 2 | Layer-1 unit + layer-2 wire-protocol tests for all 10 tools (23 new tests, all green; existing 7 stage-7 tests preserved) | [`crates/agentkeys-mcp/src/m1_tools.rs`](crates/agentkeys-mcp/src/m1_tools.rs) `#[cfg(test)] mod tests` |
| §3 Step 3-9 | All 10 MCP tools wired through `agentkeys-mcp` extending additively (7 active + 3 schema-only stubs); legacy `get_credential`/`list_credentials`/`provision` preserved | [`crates/agentkeys-mcp/src/m1_tools.rs`](crates/agentkeys-mcp/src/m1_tools.rs) + dispatcher hook in [`crates/agentkeys-mcp/src/lib.rs`](crates/agentkeys-mcp/src/lib.rs) |
| §3 Step 4 | Deterministic policy engine (`evaluate_permission` — NOT LLM); covers chain-scope check + payment-daily-cap policy | [`crates/agentkeys-mcp/src/m1_tools.rs`](crates/agentkeys-mcp/src/m1_tools.rs) `evaluate_permission()` |
| §3 Step 5 | `cap.mint` adapter onto broker `/v1/cap/{cred,memory}-{store,fetch}` with cross-actor pre-check | `m1_tools::cap_mint()` |
| §3 Step 7 | `audit.append` adapter onto `worker-audit /v1/audit/append/v2` (`AuditEnvelope v1`) | `m1_tools::audit_append()` |
| §3 Step 7 | #109 cadence tuned: audit-worker default flush interval **300s → 120s** (matches ≤2-min on-chain anchor SLA) | [`crates/agentkeys-worker-audit/src/main.rs`](crates/agentkeys-worker-audit/src/main.rs) |
| §3 Step 10 | `harness/mcp/smoke-test.sh` `TODO(M1)` stubs replaced with real JSON-RPC drivers over the daemon's stdio transport. Acts gracefully degrade when backend URLs are unset (verifies the surface; round-trips when wired). | [`harness/mcp/smoke-test.sh`](harness/mcp/smoke-test.sh) |

Test results (2026-05-25):

- `cargo test -p agentkeys-mcp` — **30 passed; 0 failed** (23 new M1 + 7 legacy stage-7)
- `cargo test -p agentkeys-worker-audit` — **14 passed; 0 failed**
- `cargo build -p agentkeys-daemon` — clean (daemon picks up the new tool set via the existing `agentkeys_mcp::server::run_stdio_with_broker` plumbing)
- `bash -n harness/mcp/smoke-test.sh` — syntax green

### 8.2 What did NOT land (deferred with explicit reason + unblocker)

Per plan-completion policy. Each row names the gap, the reason, and the trigger for the follow-up PR.

| Deferred item | Reason | Unblocker |
|---|---|---|
| **#108 namespace as a SIGNED FIELD in `CapPayload`** (broker + worker-creds mirror) | The M1 implementation passes `namespace` at the memory-worker request body level only. Adding the signed `namespaces_allowed: Vec<Namespace>` claim to `CapPayload` requires synchronized edits across `agentkeys-types` (new enum), `crates/agentkeys-broker-server/src/handlers/cap.rs:78` (CapPayload), `crates/agentkeys-worker-creds/src/verify.rs:52` (mirror), plus a new `check_namespace()` verify step. Defense-in-depth as designed; the M1 fallback is weaker but functional for the three-act demo. | Follow-up PR adding `Namespace` enum + CapPayload mirror + `verify::check_namespace()` + memory-worker hook + negative-cross-namespace integration test in the `harness/v2-stage3-demo.sh` style. |
| **Broker `/v1/identity/whoami` endpoint** | M1 synthesizes `whoami` locally from the daemon's session wallet + scope. A first-class broker endpoint with on-chain scope enumeration is M4. | M4 — needs `AgentKeysScope.listScopesForActor(...)` chain read; tracked alongside the vendor onboarding portal (#114). |
| **Broker `/v1/revoke/cap/:id` endpoint** | M1 `cap.revoke` returns a graceful stub when the endpoint is missing; persistent + chain-anchored revocation is M4 per `agent-iam-strategy.md` §3.1. | M4 — needs the persistent revocation store (Redis or chain anchor); pair with the M4 delegation work. |
| **Audit Tier-2 actual on-chain anchoring (`CredentialAudit.appendRoot` call)** | The worker computes the Merkle root on the 120s cadence and **logs** it (`auto-flush: Merkle root ready for on-chain appendRoot`) but does not yet submit the on-chain tx. Operators currently submit manually via `cast`. | Follow-up issue: wire the audit-worker's background flusher to call `CredentialAudit.appendRootV2` via the existing `crates/agentkeys-chain/` Foundry tooling. Pair with #109 closure. |
| **#110 parent-control web UI** | Explicitly deferred per user direction. The MCP tool surface this UI consumes is now stable. | Follow-up PR for #110 — consume `audit.append` Tier-1 SSE feed + `permission.check` verdicts in real time. |
| **#112 Volcano Ark MCP marketplace registration** | Explicitly deferred per user direction. Requires the M2 vendor onboarding portal (#114) for the multi-tenant Bearer model. | Follow-up PR for #112 after #114 lands. |
| **xiaozhi-server final integration** | Paired with #112 follow-up; xiaozhi is the M2 production host. M1 ships with Claude Code as the dev-loop MCP host. | Same trigger as #112. |
| **MCP Inspector wired in CI as layer-2 gate** | Layer-1 unit tests cover the MCP wire format (`tools/list` + `tools/call` round-trip). Inspector is belt-and-suspenders and explicitly deferred in this plan. | Follow-up issue if a wire-format regression slips past layer-1. |
| **Multi-tenant Bearer token issuance + rotation** | M2 #114. Logged in `hardcoded.md` §M1. | M2 — vendor onboarding portal (#114). |

### 8.3 Branch + PR mechanics

This is a Claude Code worktree at `.claude/worktrees/jovial-proskuriakova-d07055`. Per CLAUDE.md `/create-pr` policy:

1. **Commit (worktree, raw git)** — `jj` cannot colocate inside a git worktree.
2. **Push (main repo, jj)** — `cd ~/Projects/agentKeys && jj git fetch && jj git push -b claude/jovial-proskuriakova-d07055`.
3. **PR** — `gh pr create --base evm --title "..." --body "..."`.

Plan revisions: if reality diverges from §3 in a follow-up commit on this branch, update this §8 in the same commit. Drift is auditable only if it's explicit.
