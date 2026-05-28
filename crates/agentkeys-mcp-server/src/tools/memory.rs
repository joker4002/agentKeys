//! `agentkeys.memory.get` + `agentkeys.memory.put` — namespace-scoped
//! memory access. Internally: mint a cap → call the memory worker.
//!
//! Namespace enforcement (issue #108): the cap-mint carries the server's
//! configured `namespaces_allowed` (sourced from config, NOT the agent's
//! request, so the agent can't self-widen). The broker SIGNS that claim
//! into the cap; the memory worker filters reads/writes by string-set
//! membership. When the worker reports a `namespace_violation`, this tool
//! emits a `memory.namespace_violation` audit row and returns an empty /
//! refused result so the agent sees nothing it isn't entitled to.

use base64::Engine;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::auth::CallerContext;
use crate::backend::{
    AuditAppendInput, Backend, CapMintOp, CapMintRequest, MemoryGetInput, MemoryPutInput,
};
use crate::config::Config;
use crate::errors::{McpError, McpResult};

const DEFAULT_TTL_SECONDS: u64 = 300;

/// Canonical `op_kind` byte for a cross-namespace access attempt. Mirrors
/// `agentkeys_core::audit::AuditOpKind::MemoryNamespaceViolation` (= 13) —
/// hand-mirrored to avoid pulling the heavy core crate, same convention
/// as `backend::audit::ENVELOPE_VERSION`.
const OP_KIND_MEMORY_NAMESPACE_VIOLATION: u8 = 13;
/// `agentkeys_core::audit::AuditResult::NotPermitted` (= 2).
const AUDIT_RESULT_NOT_PERMITTED: u8 = 2;

/// Emit a `memory.namespace_violation` audit row. Best-effort: a failure
/// to record the audit must NOT fail the request (the worker already
/// denied access — the audit is the observability record of that denial).
async fn emit_namespace_violation(
    backend: &Arc<dyn Backend>,
    operator_omni: &str,
    actor: &str,
    namespace: &str,
    op_label: &str,
) {
    let appended = backend
        .audit_append(AuditAppendInput {
            operator_omni: operator_omni.to_string(),
            actor_omni: actor.to_string(),
            op_kind: OP_KIND_MEMORY_NAMESPACE_VIOLATION,
            op_body: json!({ "namespace": namespace, "op": op_label }),
            result: AUDIT_RESULT_NOT_PERMITTED,
            intent_text: Some(format!(
                "agent attempted {op_label} on namespace `{namespace}` outside its cap"
            )),
        })
        .await;
    if let Err(e) = appended {
        tracing::warn!(
            namespace,
            op = op_label,
            error = %e,
            "failed to record namespace_violation audit row"
        );
    }
}

/// Resolve an identity field — LLM-supplied param wins, else config default,
/// else a precise error so the operator can fix the env.
fn resolve_ident<'a>(
    params: &'a Value,
    key: &str,
    fallback: Option<&'a str>,
) -> McpResult<&'a str> {
    params
        .get(key)
        .and_then(|v| v.as_str())
        .or(fallback)
        .ok_or_else(|| {
            McpError::InvalidParams(format!(
                "missing `{key}` and no MCP_DEFAULT_{} configured \
                 — set it in /etc/agentkeys/mcp.env or pass via --{}",
                key.to_uppercase(),
                key.replace('_', "-")
            ))
        })
}

pub async fn put(
    caller: &CallerContext,
    backend: Arc<dyn Backend>,
    config: &Config,
    session_bearer: &str,
    params: &Value,
) -> McpResult<Value> {
    let actor = resolve_ident(params, "actor", config.default_actor.as_deref())?;
    let namespace = params
        .get("namespace")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `namespace`".into()))?;
    let content = params
        .get("content")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `content`".into()))?;
    let operator_omni = resolve_ident(
        params,
        "operator_omni",
        config.default_operator_omni.as_deref(),
    )?;
    let device_key_hash = resolve_ident(
        params,
        "device_key_hash",
        config.default_device_key_hash.as_deref(),
    )?;
    let service = params
        .get("service")
        .and_then(|v| v.as_str())
        .unwrap_or("memory")
        .to_string();
    let ttl_seconds = params
        .get("ttl_seconds")
        .and_then(|v| v.as_u64())
        .unwrap_or(DEFAULT_TTL_SECONDS);

    if caller.actor_omni != "*" {
        crate::auth::check_actor_param(&caller.actor_omni, actor)?;
    }

    let cap_req = CapMintRequest {
        operator_omni: operator_omni.to_string(),
        actor_omni: actor.to_string(),
        service,
        device_key_hash: device_key_hash.to_string(),
        ttl_seconds,
        namespaces_allowed: config.default_namespaces_allowed.clone(),
    };
    let cap = backend
        .cap_mint(CapMintOp::MemoryPut, cap_req, session_bearer)
        .await
        .map_err(|e| McpError::Backend(format!("cap_mint failed: {e}")))?;

    let plaintext_b64 = base64::engine::general_purpose::STANDARD.encode(content.as_bytes());

    let result = backend
        .memory_put(MemoryPutInput {
            cap,
            namespace: namespace.to_string(),
            plaintext_b64,
        })
        .await
        .map_err(|e| McpError::Backend(format!("memory_put failed: {e}")))?;

    if result.namespace_violation {
        emit_namespace_violation(&backend, operator_omni, actor, namespace, "put").await;
        return Ok(json!({
            "ok": false,
            "namespace": result.namespace,
            "namespace_violation": true,
            "reason": "namespace_not_allowed",
        }));
    }

    Ok(json!({
        "ok": result.ok,
        "namespace": result.namespace,
        "s3_key": result.s3_key,
        "envelope_size": result.envelope_size,
    }))
}

pub async fn get(
    caller: &CallerContext,
    backend: Arc<dyn Backend>,
    config: &Config,
    session_bearer: &str,
    params: &Value,
) -> McpResult<Value> {
    let actor = resolve_ident(params, "actor", config.default_actor.as_deref())?;
    let namespace = params
        .get("namespace")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `namespace`".into()))?;
    let operator_omni = resolve_ident(
        params,
        "operator_omni",
        config.default_operator_omni.as_deref(),
    )?;
    let device_key_hash = resolve_ident(
        params,
        "device_key_hash",
        config.default_device_key_hash.as_deref(),
    )?;
    let service = params
        .get("service")
        .and_then(|v| v.as_str())
        .unwrap_or("memory")
        .to_string();
    let ttl_seconds = params
        .get("ttl_seconds")
        .and_then(|v| v.as_u64())
        .unwrap_or(DEFAULT_TTL_SECONDS);

    if caller.actor_omni != "*" {
        crate::auth::check_actor_param(&caller.actor_omni, actor)?;
    }

    let cap_req = CapMintRequest {
        operator_omni: operator_omni.to_string(),
        actor_omni: actor.to_string(),
        service,
        device_key_hash: device_key_hash.to_string(),
        ttl_seconds,
        namespaces_allowed: config.default_namespaces_allowed.clone(),
    };
    let cap = backend
        .cap_mint(CapMintOp::MemoryGet, cap_req, session_bearer)
        .await
        .map_err(|e| McpError::Backend(format!("cap_mint failed: {e}")))?;

    let result = backend
        .memory_get(MemoryGetInput {
            cap,
            namespace: namespace.to_string(),
        })
        .await
        .map_err(|e| McpError::Backend(format!("memory_get failed: {e}")))?;

    if result.namespace_violation {
        emit_namespace_violation(&backend, operator_omni, actor, namespace, "get").await;
        // Empty result — the agent sees nothing for a namespace its cap
        // doesn't grant (NOT an error that would leak the memory's
        // existence).
        return Ok(json!({
            "ok": false,
            "namespace": result.namespace,
            "namespace_violation": true,
            "content": "",
        }));
    }

    let plaintext = base64::engine::general_purpose::STANDARD
        .decode(&result.plaintext_b64)
        .map_err(|e| McpError::Internal(format!("plaintext_b64 decode: {e}")))?;
    let content = String::from_utf8(plaintext)
        .map_err(|e| McpError::Internal(format!("plaintext utf8: {e}")))?;

    Ok(json!({
        "ok": result.ok,
        "namespace": result.namespace,
        "content": content,
    }))
}
