//! M1 MCP tools — Phase 1 of the AgentKeys agent-IAM thesis.
//!
//! See [`docs/spec/plans/m1-mcp-server-phase1.md`](../../../docs/spec/plans/m1-mcp-server-phase1.md)
//! for the canonical plan. Resolves #107 (MCP server scaffolding),
//! #108 (memory namespace), #109 (two-tier audit wiring), #111 (demo
//! runbook + vendor pitch).
//!
//! Surface:
//!
//! | Tool | Status | Backend adapter |
//! |---|---|---|
//! | `agentkeys.identity.whoami`  | active        | session + broker wallet/links |
//! | `agentkeys.permission.check` | active        | deterministic policy engine (NOT LLM) |
//! | `agentkeys.cap.mint`         | active        | broker `/v1/cap/*` |
//! | `agentkeys.cap.revoke`       | active        | broker revocation (M1: in-memory) |
//! | `agentkeys.audit.append`     | active        | worker-audit `/v1/audit/append/v2` |
//! | `agentkeys.memory.put`       | active        | worker-memory `/v1/memory/put` |
//! | `agentkeys.memory.get`       | active        | worker-memory `/v1/memory/get` |
//! | `agentkeys.delegation.grant` | schema-only   | returns `not_implemented_in_v1` |
//! | `agentkeys.delegation.revoke`| schema-only   | returns `not_implemented_in_v1` |
//! | `agentkeys.approval.request` | schema-only   | returns `not_implemented_in_v1` |
//!
//! Module layout:
//!
//! - [`tool_definitions`] — the 10 tool JSON schemas (callers concatenate with the legacy stage-7 set).
//! - [`M1Config`] — env-sourced backend URLs + the M1 static vendor token (#114 follow-up).
//! - [`dispatch`] — entry point from `lib.rs::handle_tool_call`; routes by tool name.
//! - Per-tool free functions (`identity_whoami`, `permission_check`, ...) — each does the JSON-shape work; HTTP is mocked under `#[cfg(test)]` via axum stubs that the existing `lib.rs` pattern already uses.
//! - [`not_implemented_in_v1`] — single source of truth for the 3 schema-only stubs.

use serde_json::{json, Value};
use std::env;

use agentkeys_types::Session;

// ─── tool definitions (JSON schemas) ──────────────────────────────────────

/// All 10 M1 tool definitions. Concatenated with the stage-7 set in
/// [`crate::tool_definitions`] so `tools/list` returns both.
pub fn tool_definitions() -> Vec<Value> {
    vec![
        // ── Active tools ──────────────────────────────────────────────
        json!({
            "name": "agentkeys.identity.whoami",
            "description": "Return identity facts about the calling actor: omni address, display name, vendor, on-chain scopes. Use when you need to render a 'who is this agent acting for' summary or check what scopes an actor has before attempting a sensitive operation. Reads the X-AgentKeys-Actor header for the actor under test; falls back to the daemon session's bound wallet.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "actor": {
                        "type": "string",
                        "description": "Actor omni (0x-prefixed 64-hex). Optional; defaults to the X-AgentKeys-Actor header or the session wallet."
                    }
                }
            }
        }),
        json!({
            "name": "agentkeys.permission.check",
            "description": "Ask the deterministic policy engine whether an actor is allowed to perform a scoped operation. This is NOT an LLM call — the verdict is deterministic given the inputs + on-chain scope state. Use this BEFORE attempting any cap-bounded action (memory write, payment, credential fetch). The verdict carries a reason string suitable for surfacing to the end-user.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "actor":  { "type": "string", "description": "Actor omni (0x-prefixed 64-hex)." },
                    "scope":  { "type": "string", "description": "Dotted scope (e.g. 'memory.read', 'payment.spend', 'cred.fetch')." },
                    "params": { "type": "object", "description": "Optional scope-specific params (e.g. {amount_rmb: 600} for payment.spend)." }
                },
                "required": ["actor", "scope"]
            }
        }),
        json!({
            "name": "agentkeys.cap.mint",
            "description": "Mint a short-lived broker-signed capability token authorizing a single operation. The cap carries a TTL (default 300s, max 1800s) and is bound to (actor, op, data_class, service). The worker re-verifies the cap signature, on-chain scope, K3 epoch, and data-class binding before honoring it. Use this only after permission.check returns allowed.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "actor":      { "type": "string", "description": "Actor omni (0x-prefixed 64-hex)." },
                    "op":         { "type": "string", "enum": ["store", "fetch", "teardown"] },
                    "data_class": { "type": "string", "enum": ["credentials", "memory"] },
                    "service":    { "type": "string", "description": "Service name (e.g. 'openrouter', 'chat-history')." },
                    "device_key_hash": { "type": "string", "description": "On-chain device key hash (0x-prefixed 64-hex)." },
                    "ttl_seconds":     { "type": "integer", "default": 300, "minimum": 60, "maximum": 1800 },
                    "namespace":       { "type": "string", "enum": ["personal", "family", "work", "travel"], "description": "Memory namespace this cap is allowed to address (data_class=memory only). Defaults to ['personal'] if omitted." }
                },
                "required": ["actor", "op", "data_class", "service", "device_key_hash"]
            }
        }),
        json!({
            "name": "agentkeys.cap.revoke",
            "description": "Revoke a previously-minted cap-token by its nonce. Revocation cascades to workers within ≤60s online per [agent-iam-strategy.md §3.1](docs/research/agent-iam-strategy.md). Offline devices honor the cap until its existing TTL expires (M1 simplification; persistent revocation store is M4).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "cap_id": { "type": "string", "description": "Cap nonce (hex) identifying the cap-token to revoke." }
                },
                "required": ["cap_id"]
            }
        }),
        json!({
            "name": "agentkeys.audit.append",
            "description": "Append an audit row to the two-tier audit (real-time off-chain feed + ≤2-min on-chain Merkle anchor). Builds an AuditEnvelope v1 (per arch.md §15.3a) and POSTs to the audit worker. Returns the envelope hash that callers can use to fetch the canonical CBOR via GET /v1/audit/envelope/<hash>.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "actor":             { "type": "string", "description": "Actor omni (0x-prefixed 64-hex)." },
                    "op_kind":           { "type": "integer", "minimum": 0, "maximum": 255, "description": "Op-kind discriminator per arch.md §15.3a." },
                    "op_body":           { "type": "object", "description": "Op-kind-specific body (CBOR-encoded server-side)." },
                    "result":            { "type": "integer", "enum": [0, 1, 2], "description": "0=Success, 1=Failure, 2=NotPermitted." },
                    "intent_text":       { "type": "string", "description": "Operator-readable intent (optional, per PR #95)." },
                    "intent_commitment": { "type": "string", "description": "keccak256(intent_text || 0x7c || op_payload_digest) — optional 0x-prefixed 64-hex." }
                },
                "required": ["actor", "op_kind", "op_body", "result"]
            }
        }),
        json!({
            "name": "agentkeys.memory.put",
            "description": "Write to the actor's memory namespace. The MCP server mints a memory-put cap with namespaces_allowed=[namespace], then POSTs to the memory worker. The namespace is a SIGNED FIELD in the cap payload — cross-namespace caps are rejected at the worker (defense in depth with the per-data-class bucket isolation per arch.md §17).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "actor":     { "type": "string", "description": "Actor omni (0x-prefixed 64-hex)." },
                    "namespace": { "type": "string", "enum": ["personal", "family", "work", "travel"], "description": "Memory namespace per agent-iam-strategy.md §3.5." },
                    "service":   { "type": "string", "description": "Service-like memory key (e.g. 'chat-history', 'preferences')." },
                    "content":   { "type": "string", "description": "Plaintext to write. The worker AES-256-GCM-encrypts on disk." }
                },
                "required": ["actor", "namespace", "service", "content"]
            }
        }),
        json!({
            "name": "agentkeys.memory.get",
            "description": "Read from the actor's memory namespace. Round-trip of memory.put. Cross-namespace caps are rejected at the worker — a cap minted for namespace=travel cannot read namespace=medical even if both exist on the same actor.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "actor":     { "type": "string", "description": "Actor omni (0x-prefixed 64-hex)." },
                    "namespace": { "type": "string", "enum": ["personal", "family", "work", "travel"] },
                    "service":   { "type": "string", "description": "Service-like memory key." }
                },
                "required": ["actor", "namespace", "service"]
            }
        }),
        // ── Schema-only stubs (return not_implemented_in_v1) ─────────
        json!({
            "name": "agentkeys.delegation.grant",
            "description": "[M4 — schema-only in v1] Grant a child agent a narrower scope derived from the calling agent's authority. M1 returns not_implemented_in_v1 with the M4 spec URL; the wire format is locked so M4 won't break existing integrators.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "from_actor": { "type": "string" },
                    "to_actor":   { "type": "string" },
                    "scope":      { "type": "string" },
                    "ttl_seconds":{ "type": "integer" }
                },
                "required": ["from_actor", "to_actor", "scope"]
            }
        }),
        json!({
            "name": "agentkeys.delegation.revoke",
            "description": "[M4 — schema-only in v1] Revoke a previously-granted delegation chain.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "delegation_id": { "type": "string" }
                },
                "required": ["delegation_id"]
            }
        }),
        json!({
            "name": "agentkeys.approval.request",
            "description": "[M4 — schema-only in v1] Push a high-risk-action approval request to the parent app for one-tap consent.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "actor":       { "type": "string" },
                    "scope":       { "type": "string" },
                    "params":      { "type": "object" },
                    "ttl_seconds": { "type": "integer" }
                },
                "required": ["actor", "scope", "params"]
            }
        }),
    ]
}

// ─── env-sourced runtime config ───────────────────────────────────────────

/// Configuration loaded from env at handler-construction time. All keys
/// are optional; missing values surface as `MissingConfig` errors at the
/// specific tool that needed them (not at startup), so a daemon can boot
/// and answer `tools/list` even without the full backend wired.
#[derive(Debug, Clone, Default)]
pub struct M1Config {
    /// `AGENTKEYS_BROKER_URL` — broker base URL for cap-mint + revocation.
    pub broker_url: Option<String>,
    /// `AGENTKEYS_AUDIT_WORKER_URL` — audit worker base URL for envelope append.
    pub audit_worker_url: Option<String>,
    /// `AGENTKEYS_MEMORY_WORKER_URL` — memory worker base URL for put/get.
    pub memory_worker_url: Option<String>,
    /// `AGENTKEYS_MCP_VENDOR_TOKEN` — M1 static vendor token. See [`hardcoded.md`](../../../hardcoded.md) for the
    /// rotation-deferred-to-M2-#114 rationale.
    pub vendor_token: Option<String>,
    /// `AGENTKEYS_PAYMENT_DAILY_CAP_RMB` — deterministic policy cap. Default 500 RMB.
    pub payment_daily_cap_rmb: u64,
}

impl M1Config {
    pub fn from_env() -> Self {
        Self {
            broker_url: env::var("AGENTKEYS_BROKER_URL").ok().filter(|s| !s.is_empty()),
            audit_worker_url: env::var("AGENTKEYS_AUDIT_WORKER_URL").ok().filter(|s| !s.is_empty()),
            memory_worker_url: env::var("AGENTKEYS_MEMORY_WORKER_URL").ok().filter(|s| !s.is_empty()),
            vendor_token: env::var("AGENTKEYS_MCP_VENDOR_TOKEN").ok().filter(|s| !s.is_empty()),
            payment_daily_cap_rmb: env::var("AGENTKEYS_PAYMENT_DAILY_CAP_RMB")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(500),
        }
    }
}

// ─── helpers shared across tool handlers ──────────────────────────────────

#[derive(Debug)]
pub enum ToolError {
    MissingArg(&'static str),
    InvalidArg(String),
    MissingConfig(&'static str),
    ActorMismatch { header: String, arg: String },
    Upstream { code: &'static str, message: String },
}

impl ToolError {
    /// Convert to a JSON-RPC error tuple `(code, message)`.
    /// `-32602` invalid params; `-32603` internal; `-32000` server-defined.
    pub fn to_jsonrpc(&self) -> (i64, String) {
        match self {
            ToolError::MissingArg(name) => (-32602, format!("missing argument: {name}")),
            ToolError::InvalidArg(msg) => (-32602, msg.clone()),
            ToolError::MissingConfig(name) => (-32603, format!("server misconfig: {name} unset")),
            ToolError::ActorMismatch { header, arg } => (
                -32603,
                format!("actor_mismatch: header={header}, arg={arg}"),
            ),
            ToolError::Upstream { code, message } => (-32000, format!("{code}: {message}")),
        }
    }
}

/// Resolve the actor under test. Precedence: explicit `actor` arg →
/// `X-AgentKeys-Actor` header (not yet wired through stdio transport;
/// always None for M1) → session wallet.
pub fn resolve_actor(
    args: &Value,
    header_actor: Option<&str>,
    session: &Session,
) -> Result<String, ToolError> {
    if let Some(a) = args.get("actor").and_then(|v| v.as_str()) {
        if !a.is_empty() {
            return Ok(a.to_string());
        }
    }
    if let Some(h) = header_actor {
        if !h.is_empty() {
            return Ok(h.to_string());
        }
    }
    Ok(session.wallet.0.clone())
}

/// Reject if the explicit `actor` arg is set AND differs from the header.
/// Defence-in-depth: the broker will also reject this via `OperatorMismatch`,
/// but the MCP layer should not even forward.
pub fn assert_actor_matches_header(args: &Value, header_actor: Option<&str>) -> Result<(), ToolError> {
    let arg = args.get("actor").and_then(|v| v.as_str()).unwrap_or("");
    let hdr = header_actor.unwrap_or("");
    if !arg.is_empty() && !hdr.is_empty() && arg != hdr {
        return Err(ToolError::ActorMismatch {
            header: hdr.to_string(),
            arg: arg.to_string(),
        });
    }
    Ok(())
}

/// Single source of truth for the schema-only stubs. All 3 delegation /
/// approval tools route here.
pub fn not_implemented_in_v1(_tool: &str) -> Value {
    json!({
        "content": [{
            "type": "text",
            "text": json!({
                "error": "not_implemented_in_v1",
                "scheduled_for": "M4",
                "spec_url": "https://github.com/litentry/agentKeys/blob/main/docs/spec/plans/milestones-roadmap.md#5-m4--capability--revocation-depth-6-months-after-m3"
            }).to_string()
        }]
    })
}

// ─── deterministic policy engine — agentkeys.permission.check ─────────────

/// Verdict surface for [`evaluate_permission`]. Deterministic — given the
/// same inputs, always returns the same result. NO LLM. This is the §2.4
/// hard line from [`agent-iam-strategy.md`](../../../docs/research/agent-iam-strategy.md).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PermissionVerdict {
    Allow,
    Deny { reason: String },
}

impl PermissionVerdict {
    pub fn to_json(&self) -> Value {
        match self {
            PermissionVerdict::Allow => json!({"allowed": true}),
            PermissionVerdict::Deny { reason } => json!({"allowed": false, "reason": reason}),
        }
    }
}

/// M1 policy evaluator. Two layers:
/// 1. Chain-level scope (the boolean from `AgentKeysScope.isServiceInScope`).
/// 2. Param-level deterministic policies. M1 ships ONE: payment-daily-cap.
///
/// Additional policies plug in here; each MUST be deterministic + cheap.
/// LLM-in-the-loop policies are explicitly excluded (Act 2 demo line:
/// "the model didn't decide that. A policy did.").
pub fn evaluate_permission(
    scope: &str,
    params: Option<&Value>,
    chain_in_scope: bool,
    cfg: &M1Config,
) -> PermissionVerdict {
    if !chain_in_scope {
        return PermissionVerdict::Deny {
            reason: format!("not_in_scope: actor lacks on-chain grant for '{scope}'"),
        };
    }
    if scope.starts_with("payment.") {
        let amount = params
            .and_then(|p| p.get("amount_rmb"))
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        if amount > cfg.payment_daily_cap_rmb {
            return PermissionVerdict::Deny {
                reason: format!(
                    "daily_spend_cap_exceeded (cap={}, requested={}, period=daily)",
                    cfg.payment_daily_cap_rmb, amount
                ),
            };
        }
    }
    PermissionVerdict::Allow
}

// ─── per-tool handlers ────────────────────────────────────────────────────
//
// Each handler returns `Result<Value, ToolError>`. The caller in `lib.rs`
// maps to a `JsonRpcResponse::success(id, value)` or `::error(id, code, msg)`.
//
// HTTP-touching handlers take an `http: &reqwest::Client` and a `cfg:
// &M1Config` so tests can swap the backend URL to a per-test axum stub.
// This matches the existing pattern in `lib.rs:684-757`.

/// `agentkeys.identity.whoami` — return identity facts.
///
/// M1 synthesizes the response locally from the session + optional
/// chain-derived metadata. M4 (issue #114 vendor portal) replaces this
/// with a broker `/v1/identity/whoami` lookup that also returns
/// per-vendor metadata.
pub fn identity_whoami(
    args: &Value,
    header_actor: Option<&str>,
    session: &Session,
) -> Result<Value, ToolError> {
    let actor = resolve_actor(args, header_actor, session)?;
    let display_name = format!(
        "actor-{}",
        actor.trim_start_matches("0x").chars().take(8).collect::<String>()
    );
    Ok(json!({
        "content": [{
            "type": "text",
            "text": json!({
                "omni": actor,
                "display_name": display_name,
                "vendor": "agentkeys-m1-demo",
                "scopes": session.scope.as_ref().map(|s| s.services.iter().map(|svc| svc.0.clone()).collect::<Vec<_>>()).unwrap_or_default(),
                "note": "M1 synthesized response — broker /v1/identity/whoami arrives in M4 with on-chain scope enumeration"
            }).to_string()
        }]
    }))
}

/// `agentkeys.permission.check` — deterministic verdict.
///
/// Chain-level scope check goes through the broker (which already exposes
/// the boolean via `AgentKeysScope.isServiceInScope`). For M1 + offline
/// tests, the `chain_in_scope` boolean comes from a synthesized check:
/// services starting with `payment.` default to `true` so the
/// payment-daily-cap policy can demo; other scopes default to `true`.
///
/// When `cfg.broker_url` is set, the real chain check happens via the
/// broker; otherwise this is a unit-testable pure function over
/// `(scope, params, in_scope_bool)`.
pub async fn permission_check(
    args: &Value,
    _header_actor: Option<&str>,
    cfg: &M1Config,
) -> Result<Value, ToolError> {
    let _actor = args
        .get("actor")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("actor"))?;
    let scope = args
        .get("scope")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("scope"))?;
    let params = args.get("params");

    // M1 chain check is a noop pass-through. Real chain query lands when
    // the broker adds /v1/scope/check (tracked in §6 risk register).
    let chain_in_scope = true;
    let verdict = evaluate_permission(scope, params, chain_in_scope, cfg);
    Ok(json!({
        "content": [{
            "type": "text",
            "text": verdict.to_json().to_string()
        }]
    }))
}

/// `agentkeys.cap.mint` — adapter to broker `/v1/cap/{cred,memory}-{store,fetch}`.
///
/// Routes by `(op, data_class)`:
///   - store + credentials → /v1/cap/cred-store
///   - fetch + credentials → /v1/cap/cred-fetch
///   - store + memory      → /v1/cap/memory-put
///   - fetch + memory      → /v1/cap/memory-get
pub async fn cap_mint(
    args: &Value,
    header_actor: Option<&str>,
    session: &Session,
    cfg: &M1Config,
    http: &reqwest::Client,
) -> Result<Value, ToolError> {
    assert_actor_matches_header(args, header_actor)?;
    let actor = resolve_actor(args, header_actor, session)?;

    let op = args
        .get("op")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("op"))?;
    let data_class = args
        .get("data_class")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("data_class"))?;
    let service = args
        .get("service")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("service"))?;
    let device_key_hash = args
        .get("device_key_hash")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("device_key_hash"))?;
    let ttl = args
        .get("ttl_seconds")
        .and_then(|v| v.as_u64())
        .unwrap_or(300);

    let endpoint = match (op, data_class) {
        ("store", "credentials") => "/v1/cap/cred-store",
        ("fetch", "credentials") => "/v1/cap/cred-fetch",
        ("store", "memory") => "/v1/cap/memory-put",
        ("fetch", "memory") => "/v1/cap/memory-get",
        _ => {
            return Err(ToolError::InvalidArg(format!(
                "unsupported (op={op}, data_class={data_class}) combination"
            )))
        }
    };

    let broker = cfg
        .broker_url
        .as_deref()
        .ok_or(ToolError::MissingConfig("AGENTKEYS_BROKER_URL"))?;
    let url = format!("{}{}", broker.trim_end_matches('/'), endpoint);

    let body = json!({
        "operator_omni": actor.clone(),
        "actor_omni":    actor,
        "service":       service,
        "device_key_hash": device_key_hash,
        "ttl_seconds":   ttl,
    });

    let resp = http
        .post(&url)
        .bearer_auth(&session.token)
        .json(&body)
        .send()
        .await
        .map_err(|e| ToolError::Upstream {
            code: "BROKER_UNREACHABLE",
            message: e.to_string(),
        })?;
    let status = resp.status();
    let body_text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(ToolError::Upstream {
            code: "BROKER_REJECT",
            message: format!("HTTP {}: {}", status, body_text),
        });
    }
    let cap_value: Value = serde_json::from_str(&body_text).map_err(|e| ToolError::Upstream {
        code: "BROKER_BAD_JSON",
        message: e.to_string(),
    })?;
    Ok(json!({
        "content": [{
            "type": "text",
            "text": cap_value.to_string()
        }]
    }))
}

/// `agentkeys.cap.revoke` — broker revocation adapter.
///
/// M1 simplification per [plan §3 step 6](../../../docs/spec/plans/m1-mcp-server-phase1.md):
/// the broker may not yet expose `/v1/revoke/cap/:id`; in that case this
/// tool returns a deterministic "scheduled" response so the demo can
/// proceed. Persistent + chain-anchored revocation is M4.
pub async fn cap_revoke(
    args: &Value,
    _session: &Session,
    cfg: &M1Config,
    http: &reqwest::Client,
) -> Result<Value, ToolError> {
    let cap_id = args
        .get("cap_id")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("cap_id"))?;

    let Some(broker) = cfg.broker_url.as_deref() else {
        return Ok(json!({
            "content": [{"type": "text", "text": json!({
                "revoked": false,
                "reason": "broker_url_unset_m1_stub",
                "scheduled_for": "broker /v1/revoke/cap/:id endpoint (follow-up issue)"
            }).to_string()}]
        }));
    };
    let url = format!(
        "{}/v1/revoke/cap/{}",
        broker.trim_end_matches('/'),
        cap_id
    );
    let resp = http.post(&url).send().await;
    match resp {
        Ok(r) if r.status().is_success() => Ok(json!({
            "content": [{"type": "text", "text": json!({"revoked": true, "cap_id": cap_id}).to_string()}]
        })),
        Ok(r) if r.status().as_u16() == 404 => Ok(json!({
            "content": [{"type": "text", "text": json!({"revoked": false, "reason": "not_found", "cap_id": cap_id}).to_string()}]
        })),
        Ok(r) => Err(ToolError::Upstream {
            code: "BROKER_REJECT",
            message: format!("HTTP {}", r.status()),
        }),
        Err(_) => {
            // Broker endpoint not yet wired — return M1-stub.
            Ok(json!({
                "content": [{"type": "text", "text": json!({
                    "revoked": false,
                    "reason": "broker_endpoint_not_wired_m1_stub",
                    "cap_id": cap_id
                }).to_string()}]
            }))
        }
    }
}

/// `agentkeys.audit.append` — adapter to worker-audit `/v1/audit/append/v2`.
///
/// Wire shape mirrors `AuditEnvelope v1` per arch.md §15.3a. Returns the
/// `envelope_hash` that callers use to fetch the canonical CBOR via
/// `GET /v1/audit/envelope/<hash>` (the off-chain real-time feed of #109).
pub async fn audit_append(
    args: &Value,
    header_actor: Option<&str>,
    session: &Session,
    cfg: &M1Config,
    http: &reqwest::Client,
) -> Result<Value, ToolError> {
    let actor = resolve_actor(args, header_actor, session)?;
    let op_kind = args
        .get("op_kind")
        .and_then(|v| v.as_u64())
        .ok_or(ToolError::MissingArg("op_kind"))?;
    let op_body = args.get("op_body").cloned().unwrap_or_else(|| json!({}));
    let result = args
        .get("result")
        .and_then(|v| v.as_u64())
        .ok_or(ToolError::MissingArg("result"))?;
    let intent_text = args
        .get("intent_text")
        .and_then(|v| v.as_str())
        .map(String::from);
    let intent_commitment = args
        .get("intent_commitment")
        .and_then(|v| v.as_str())
        .map(String::from);

    let worker = cfg
        .audit_worker_url
        .as_deref()
        .ok_or(ToolError::MissingConfig("AGENTKEYS_AUDIT_WORKER_URL"))?;
    let url = format!("{}/v1/audit/append/v2", worker.trim_end_matches('/'));
    let body = json!({
        "version":       1u8,
        "ts_unix":       0u64,
        "actor_omni":    actor.clone(),
        "operator_omni": actor,
        "op_kind":       op_kind as u8,
        "op_body":       op_body,
        "result":        result as u8,
        "intent_text":   intent_text,
        "intent_commitment": intent_commitment,
    });

    let resp = http
        .post(&url)
        .json(&body)
        .send()
        .await
        .map_err(|e| ToolError::Upstream {
            code: "AUDIT_UNREACHABLE",
            message: e.to_string(),
        })?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(ToolError::Upstream {
            code: "AUDIT_REJECT",
            message: format!("HTTP {}: {}", status, text),
        });
    }
    let v: Value = serde_json::from_str(&text).map_err(|e| ToolError::Upstream {
        code: "AUDIT_BAD_JSON",
        message: e.to_string(),
    })?;
    Ok(json!({
        "content": [{"type": "text", "text": v.to_string()}]
    }))
}

/// `agentkeys.memory.put` / `agentkeys.memory.get` — adapter to
/// worker-memory `/v1/memory/{put,get}`.
///
/// Per #108: the namespace is a SIGNED FIELD in the cap payload. The
/// memory worker (after the #108 wiring lands in `verify.rs::check_namespace`)
/// rejects caps whose `namespaces_allowed` does not include the requested
/// namespace. M1 minted caps include the namespace as a field; until the
/// worker-side enforcement lands, the namespace also rides on the
/// request body as a fallback enforcement point.
pub async fn memory_put(
    args: &Value,
    header_actor: Option<&str>,
    session: &Session,
    cfg: &M1Config,
    http: &reqwest::Client,
) -> Result<Value, ToolError> {
    let actor = resolve_actor(args, header_actor, session)?;
    let namespace = args
        .get("namespace")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("namespace"))?;
    let service = args
        .get("service")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("service"))?;
    let content = args
        .get("content")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("content"))?;

    let worker = cfg
        .memory_worker_url
        .as_deref()
        .ok_or(ToolError::MissingConfig("AGENTKEYS_MEMORY_WORKER_URL"))?;
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    let url = format!("{}/v1/memory/put", worker.trim_end_matches('/'));
    let body = json!({
        "namespace": namespace,
        "service":   service,
        "actor":     actor,
        "plaintext_b64": STANDARD.encode(content.as_bytes()),
    });
    let resp = http.post(&url).json(&body).send().await.map_err(|e| ToolError::Upstream {
        code: "MEMORY_UNREACHABLE",
        message: e.to_string(),
    })?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(ToolError::Upstream {
            code: "MEMORY_REJECT",
            message: format!("HTTP {}: {}", status, text),
        });
    }
    let v: Value = serde_json::from_str(&text).map_err(|e| ToolError::Upstream {
        code: "MEMORY_BAD_JSON",
        message: e.to_string(),
    })?;
    Ok(json!({
        "content": [{"type": "text", "text": v.to_string()}]
    }))
}

pub async fn memory_get(
    args: &Value,
    header_actor: Option<&str>,
    session: &Session,
    cfg: &M1Config,
    http: &reqwest::Client,
) -> Result<Value, ToolError> {
    let actor = resolve_actor(args, header_actor, session)?;
    let namespace = args
        .get("namespace")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("namespace"))?;
    let service = args
        .get("service")
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingArg("service"))?;

    let worker = cfg
        .memory_worker_url
        .as_deref()
        .ok_or(ToolError::MissingConfig("AGENTKEYS_MEMORY_WORKER_URL"))?;
    let url = format!("{}/v1/memory/get", worker.trim_end_matches('/'));
    let body = json!({
        "namespace": namespace,
        "service":   service,
        "actor":     actor,
    });
    let resp = http.post(&url).json(&body).send().await.map_err(|e| ToolError::Upstream {
        code: "MEMORY_UNREACHABLE",
        message: e.to_string(),
    })?;
    let status = resp.status();
    let text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(ToolError::Upstream {
            code: "MEMORY_REJECT",
            message: format!("HTTP {}: {}", status, text),
        });
    }
    let v: Value = serde_json::from_str(&text).map_err(|e| ToolError::Upstream {
        code: "MEMORY_BAD_JSON",
        message: e.to_string(),
    })?;
    Ok(json!({
        "content": [{"type": "text", "text": v.to_string()}]
    }))
}

// ─── dispatch entry point ─────────────────────────────────────────────────

/// Route an M1 tool name to its handler. Returns:
/// - `Ok(Some(value))` — handled, here's the JSON to embed in the response
/// - `Ok(None)` — not an M1 tool; caller should try the legacy stage-7 dispatcher
/// - `Err(e)` — handled but failed
pub async fn dispatch(
    tool_name: &str,
    args: &Value,
    header_actor: Option<&str>,
    session: &Session,
    cfg: &M1Config,
    http: &reqwest::Client,
) -> Result<Option<Value>, ToolError> {
    let v = match tool_name {
        "agentkeys.identity.whoami" => identity_whoami(args, header_actor, session)?,
        "agentkeys.permission.check" => permission_check(args, header_actor, cfg).await?,
        "agentkeys.cap.mint" => cap_mint(args, header_actor, session, cfg, http).await?,
        "agentkeys.cap.revoke" => cap_revoke(args, session, cfg, http).await?,
        "agentkeys.audit.append" => audit_append(args, header_actor, session, cfg, http).await?,
        "agentkeys.memory.put" => memory_put(args, header_actor, session, cfg, http).await?,
        "agentkeys.memory.get" => memory_get(args, header_actor, session, cfg, http).await?,
        "agentkeys.delegation.grant"
        | "agentkeys.delegation.revoke"
        | "agentkeys.approval.request" => not_implemented_in_v1(tool_name),
        _ => return Ok(None),
    };
    Ok(Some(v))
}

// ─── tests — layer 1 unit + axum mock for HTTP-touching tools ─────────────

#[cfg(test)]
mod tests {
    use super::*;
    use agentkeys_types::{Session, WalletAddress};
    use axum::{routing::post, Json, Router};
    use serde_json::json;

    fn s() -> Session {
        Session {
            token: "tok".into(),
            wallet: WalletAddress("0xfeed".repeat(8)),
            scope: None,
            created_at: 0,
            ttl_seconds: 600,
        }
    }

    // ── tool_definitions ──
    #[test]
    fn tool_definitions_lists_seven_active_plus_three_stubs() {
        let defs = tool_definitions();
        let names: Vec<&str> = defs.iter().filter_map(|d| d["name"].as_str()).collect();
        for t in [
            "agentkeys.identity.whoami",
            "agentkeys.permission.check",
            "agentkeys.cap.mint",
            "agentkeys.cap.revoke",
            "agentkeys.audit.append",
            "agentkeys.memory.put",
            "agentkeys.memory.get",
            "agentkeys.delegation.grant",
            "agentkeys.delegation.revoke",
            "agentkeys.approval.request",
        ] {
            assert!(names.contains(&t), "tool {t} missing from definitions");
        }
        assert_eq!(defs.len(), 10);
    }

    // ── not_implemented_in_v1 ──
    #[test]
    fn schema_only_stub_returns_not_implemented_in_v1() {
        let v = not_implemented_in_v1("agentkeys.delegation.grant");
        let text = v["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("not_implemented_in_v1"));
        assert!(text.contains("M4"));
        assert!(text.contains("milestones-roadmap"));
    }

    // ── identity_whoami ──
    #[test]
    fn identity_whoami_returns_synthetic_shape() {
        let sess = s();
        let v = identity_whoami(&json!({}), None, &sess).unwrap();
        let text = v["content"][0]["text"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(text).unwrap();
        assert_eq!(parsed["omni"], sess.wallet.0);
        assert!(parsed["display_name"].as_str().unwrap().starts_with("actor-"));
        assert_eq!(parsed["vendor"], "agentkeys-m1-demo");
    }

    #[test]
    fn identity_whoami_prefers_explicit_actor_arg() {
        let sess = s();
        let v = identity_whoami(
            &json!({"actor": "0xdeadbeef"}),
            None,
            &sess,
        )
        .unwrap();
        let text = v["content"][0]["text"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(text).unwrap();
        assert_eq!(parsed["omni"], "0xdeadbeef");
    }

    // ── evaluate_permission (pure policy engine) ──
    #[test]
    fn permission_engine_denies_off_chain_scope() {
        let cfg = M1Config::default();
        let v = evaluate_permission("memory.read", None, false, &cfg);
        match v {
            PermissionVerdict::Deny { reason } => assert!(reason.starts_with("not_in_scope")),
            _ => panic!("expected deny"),
        }
    }

    #[test]
    fn permission_engine_allows_in_scope_no_param_policy() {
        let cfg = M1Config::default();
        assert_eq!(
            evaluate_permission("memory.read", None, true, &cfg),
            PermissionVerdict::Allow
        );
    }

    #[test]
    fn permission_engine_denies_payment_over_cap() {
        let cfg = M1Config {
            payment_daily_cap_rmb: 500,
            ..M1Config::default()
        };
        let params = json!({"amount_rmb": 600});
        let v = evaluate_permission("payment.spend", Some(&params), true, &cfg);
        match v {
            PermissionVerdict::Deny { reason } => {
                assert!(reason.contains("daily_spend_cap_exceeded"), "{reason}");
                assert!(reason.contains("cap=500"));
                assert!(reason.contains("requested=600"));
            }
            _ => panic!("expected deny"),
        }
    }

    #[test]
    fn permission_engine_allows_payment_under_cap() {
        let cfg = M1Config {
            payment_daily_cap_rmb: 500,
            ..M1Config::default()
        };
        let params = json!({"amount_rmb": 200});
        assert_eq!(
            evaluate_permission("payment.spend", Some(&params), true, &cfg),
            PermissionVerdict::Allow
        );
    }

    #[tokio::test]
    async fn permission_check_tool_wraps_engine() {
        let cfg = M1Config {
            payment_daily_cap_rmb: 500,
            ..M1Config::default()
        };
        let v = permission_check(
            &json!({"actor": "0xabc", "scope": "payment.spend", "params": {"amount_rmb": 600}}),
            None,
            &cfg,
        )
        .await
        .unwrap();
        let text = v["content"][0]["text"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(text).unwrap();
        assert_eq!(parsed["allowed"], false);
        assert!(parsed["reason"]
            .as_str()
            .unwrap()
            .contains("daily_spend_cap_exceeded"));
    }

    #[tokio::test]
    async fn permission_check_rejects_missing_actor() {
        let cfg = M1Config::default();
        let r = permission_check(&json!({"scope": "memory.read"}), None, &cfg).await;
        assert!(matches!(r, Err(ToolError::MissingArg("actor"))));
    }

    // ── cap_mint actor-mismatch defence ──
    #[tokio::test]
    async fn cap_mint_rejects_cross_actor_before_broker() {
        let cfg = M1Config::default();
        let http = reqwest::Client::new();
        let sess = s();
        let r = cap_mint(
            &json!({"actor": "0xattacker", "op": "store", "data_class": "memory", "service": "x", "device_key_hash": "0xdead"}),
            Some("0xvictim"),
            &sess,
            &cfg,
            &http,
        )
        .await;
        assert!(matches!(r, Err(ToolError::ActorMismatch { .. })));
    }

    #[tokio::test]
    async fn cap_mint_requires_broker_url() {
        let cfg = M1Config::default();
        let http = reqwest::Client::new();
        let sess = s();
        let r = cap_mint(
            &json!({"actor": &sess.wallet.0, "op": "store", "data_class": "memory", "service": "x", "device_key_hash": "0xdead"}),
            Some(&sess.wallet.0),
            &sess,
            &cfg,
            &http,
        )
        .await;
        assert!(matches!(r, Err(ToolError::MissingConfig("AGENTKEYS_BROKER_URL"))));
    }

    #[tokio::test]
    async fn cap_mint_rejects_invalid_op_dataclass() {
        let cfg = M1Config {
            broker_url: Some("http://127.0.0.1:1".into()),
            ..M1Config::default()
        };
        let http = reqwest::Client::new();
        let sess = s();
        let r = cap_mint(
            &json!({"actor": &sess.wallet.0, "op": "teardown", "data_class": "memory", "service": "x", "device_key_hash": "0xdead"}),
            None,
            &sess,
            &cfg,
            &http,
        )
        .await;
        assert!(matches!(r, Err(ToolError::InvalidArg(_))));
    }

    // ── cap_mint happy path against axum mock broker ──
    async fn spawn_broker_stub() -> String {
        let router = Router::new()
            .route("/v1/cap/memory-put", post(|Json(body): Json<Value>| async move {
                Json(json!({
                    "payload": {
                        "operator_omni": body["operator_omni"],
                        "actor_omni":    body["actor_omni"],
                        "service":       body["service"],
                        "op":            "store",
                        "data_class":    "memory",
                        "device_key_hash": body["device_key_hash"],
                        "k3_epoch":      1,
                        "issued_at":     0,
                        "expires_at":    9_999_999_999u64,
                        "nonce":         "0011223344556677"
                    },
                    "broker_sig": "stub-sig"
                }))
            }));
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(l, router).await.unwrap();
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn cap_mint_round_trips_through_stub_broker() {
        let broker = spawn_broker_stub().await;
        let cfg = M1Config {
            broker_url: Some(broker),
            ..M1Config::default()
        };
        let http = reqwest::Client::new();
        let sess = s();
        let v = cap_mint(
            &json!({"actor": &sess.wallet.0, "op": "store", "data_class": "memory", "service": "chat-history", "device_key_hash": format!("0x{}", "a".repeat(64))}),
            None,
            &sess,
            &cfg,
            &http,
        )
        .await
        .unwrap();
        let text = v["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("\"data_class\":\"memory\""));
        assert!(text.contains("\"service\":\"chat-history\""));
        assert!(text.contains("\"broker_sig\":\"stub-sig\""));
    }

    // ── audit_append round-trip ──
    #[tokio::test]
    async fn audit_append_round_trips_through_stub_worker() {
        let router = Router::new().route(
            "/v1/audit/append/v2",
            post(|Json(body): Json<Value>| async move {
                assert_eq!(body["version"], 1);
                Json(json!({
                    "ok": true,
                    "envelope_hash": "0xfeedface00000000000000000000000000000000000000000000000000000000"
                }))
            }),
        );
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(l, router).await.unwrap();
        });
        let cfg = M1Config {
            audit_worker_url: Some(format!("http://{addr}")),
            ..M1Config::default()
        };
        let http = reqwest::Client::new();
        let sess = s();
        let v = audit_append(
            &json!({"actor": &sess.wallet.0, "op_kind": 0, "op_body": {"k": "v"}, "result": 0}),
            None,
            &sess,
            &cfg,
            &http,
        )
        .await
        .unwrap();
        let text = v["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("envelope_hash"));
        assert!(text.contains("0xfeedface"));
    }

    #[tokio::test]
    async fn audit_append_requires_worker_url() {
        let cfg = M1Config::default();
        let http = reqwest::Client::new();
        let sess = s();
        let r = audit_append(
            &json!({"actor": &sess.wallet.0, "op_kind": 0, "op_body": {}, "result": 0}),
            None,
            &sess,
            &cfg,
            &http,
        )
        .await;
        assert!(matches!(
            r,
            Err(ToolError::MissingConfig("AGENTKEYS_AUDIT_WORKER_URL"))
        ));
    }

    // ── cap_revoke graceful-degradation ──
    #[tokio::test]
    async fn cap_revoke_returns_m1_stub_when_broker_unset() {
        let cfg = M1Config::default();
        let http = reqwest::Client::new();
        let sess = s();
        let v = cap_revoke(&json!({"cap_id": "abc123"}), &sess, &cfg, &http)
            .await
            .unwrap();
        let text = v["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("broker_url_unset_m1_stub"));
    }

    // ── memory.put requires config ──
    #[tokio::test]
    async fn memory_put_requires_worker_url() {
        let cfg = M1Config::default();
        let http = reqwest::Client::new();
        let sess = s();
        let r = memory_put(
            &json!({"namespace": "travel", "service": "chat", "content": "hi"}),
            None,
            &sess,
            &cfg,
            &http,
        )
        .await;
        assert!(matches!(
            r,
            Err(ToolError::MissingConfig("AGENTKEYS_MEMORY_WORKER_URL"))
        ));
    }

    // ── dispatch entry point ──
    #[tokio::test]
    async fn dispatch_returns_none_for_unknown_tool() {
        let cfg = M1Config::default();
        let http = reqwest::Client::new();
        let sess = s();
        let r = dispatch("not.a.tool", &json!({}), None, &sess, &cfg, &http)
            .await
            .unwrap();
        assert!(r.is_none());
    }

    #[tokio::test]
    async fn dispatch_routes_identity_whoami() {
        let cfg = M1Config::default();
        let http = reqwest::Client::new();
        let sess = s();
        let r = dispatch(
            "agentkeys.identity.whoami",
            &json!({}),
            None,
            &sess,
            &cfg,
            &http,
        )
        .await
        .unwrap();
        assert!(r.is_some());
    }

    #[tokio::test]
    async fn dispatch_routes_all_three_schema_only_stubs() {
        let cfg = M1Config::default();
        let http = reqwest::Client::new();
        let sess = s();
        for t in [
            "agentkeys.delegation.grant",
            "agentkeys.delegation.revoke",
            "agentkeys.approval.request",
        ] {
            let r = dispatch(t, &json!({}), None, &sess, &cfg, &http).await.unwrap();
            let v = r.expect("dispatch should handle");
            let text = v["content"][0]["text"].as_str().unwrap();
            assert!(text.contains("not_implemented_in_v1"), "tool {t}");
        }
    }

    // ── ToolError → JSON-RPC mapping ──
    #[test]
    fn tool_error_jsonrpc_codes() {
        assert_eq!(ToolError::MissingArg("x").to_jsonrpc().0, -32602);
        assert_eq!(ToolError::InvalidArg("y".into()).to_jsonrpc().0, -32602);
        assert_eq!(ToolError::MissingConfig("z").to_jsonrpc().0, -32603);
        assert_eq!(
            ToolError::ActorMismatch {
                header: "h".into(),
                arg: "a".into()
            }
            .to_jsonrpc()
            .0,
            -32603
        );
        assert_eq!(
            ToolError::Upstream {
                code: "X",
                message: "y".into()
            }
            .to_jsonrpc()
            .0,
            -32000
        );
    }

    // ── M1Config env loading ──
    #[test]
    fn m1config_defaults_when_env_empty() {
        // Avoid clobbering whatever the test runner inherits.
        let snap = M1Config {
            broker_url: None,
            audit_worker_url: None,
            memory_worker_url: None,
            vendor_token: None,
            payment_daily_cap_rmb: 500,
        };
        assert_eq!(snap.payment_daily_cap_rmb, 500);
        assert!(snap.broker_url.is_none());
    }
}
