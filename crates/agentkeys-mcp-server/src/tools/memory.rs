//! `agentkeys.memory.get` + `agentkeys.memory.put` — namespace-scoped
//! memory access. Internally: mint a cap → call the memory worker.
//!
//! Per Phase 1 namespace scope (issue #108 partial): the namespace is
//! a request-body field, not yet a signed CapPayload field. M4 follow-up
//! lifts it into the cap so the worker can enforce cryptographically.

use base64::Engine;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::auth::CallerContext;
use crate::backend::{Backend, CapMintOp, CapMintRequest, MemoryGetInput, MemoryPutInput};
use crate::errors::{McpError, McpResult};

const DEFAULT_TTL_SECONDS: u64 = 300;

pub async fn put(
    caller: &CallerContext,
    backend: Arc<dyn Backend>,
    session_bearer: &str,
    params: &Value,
) -> McpResult<Value> {
    let actor = params
        .get("actor")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `actor`".into()))?;
    let namespace = params
        .get("namespace")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `namespace`".into()))?;
    let content = params
        .get("content")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `content`".into()))?;
    let operator_omni = params
        .get("operator_omni")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `operator_omni`".into()))?;
    let device_key_hash = params
        .get("device_key_hash")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `device_key_hash`".into()))?;
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
    session_bearer: &str,
    params: &Value,
) -> McpResult<Value> {
    let actor = params
        .get("actor")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `actor`".into()))?;
    let namespace = params
        .get("namespace")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `namespace`".into()))?;
    let operator_omni = params
        .get("operator_omni")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `operator_omni`".into()))?;
    let device_key_hash = params
        .get("device_key_hash")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `device_key_hash`".into()))?;
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
