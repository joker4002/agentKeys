//! `agentkeys.cred.store` + `agentkeys.cred.fetch` — agent-owned vaulted
//! credential access. Internally: mint a credentials cap -> call the cred
//! worker with the vault-role STS relay.

use base64::Engine;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::auth::CallerContext;
use crate::backend::{Backend, CapMintOp, CapMintRequest, CredFetchInput, CredStoreInput};
use crate::config::Config;
use crate::errors::{McpError, McpResult};

const DEFAULT_TTL_SECONDS: u64 = 300;

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

fn resolve_actor<'a>(params: &'a Value, config: &'a Config) -> McpResult<&'a str> {
    resolve_ident(params, "actor", config.default_actor.as_deref())
}

fn resolve_operator<'a>(params: &'a Value, actor: &'a str) -> &'a str {
    params
        .get("operator_omni")
        .and_then(|v| v.as_str())
        .unwrap_or(actor)
}

fn resolve_common<'a>(
    caller: &CallerContext,
    config: &'a Config,
    params: &'a Value,
) -> McpResult<(&'a str, &'a str, &'a str, &'a str, u64)> {
    let actor = resolve_actor(params, config)?;
    if caller.actor_omni != "*" {
        crate::auth::check_actor_param(&caller.actor_omni, actor)?;
    }
    let operator_omni = resolve_operator(params, actor);
    let service = params
        .get("service")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `service`".into()))?;
    let device_key_hash = resolve_ident(
        params,
        "device_key_hash",
        config.default_device_key_hash.as_deref(),
    )?;
    let ttl_seconds = params
        .get("ttl_seconds")
        .and_then(|v| v.as_u64())
        .unwrap_or(DEFAULT_TTL_SECONDS);
    Ok((actor, operator_omni, service, device_key_hash, ttl_seconds))
}

pub async fn store(
    caller: &CallerContext,
    backend: Arc<dyn Backend>,
    config: &Config,
    session_bearer: &str,
    params: &Value,
) -> McpResult<Value> {
    let (actor, operator_omni, service, device_key_hash, ttl_seconds) =
        resolve_common(caller, config, params)?;
    let content = params
        .get("content")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `content`".into()))?;

    let cap = backend
        .cap_mint(
            CapMintOp::CredStore,
            CapMintRequest {
                operator_omni: operator_omni.to_string(),
                actor_omni: actor.to_string(),
                service: service.to_string(),
                device_key_hash: device_key_hash.to_string(),
                ttl_seconds,
            },
            session_bearer,
        )
        .await
        .map_err(|e| McpError::Backend(format!("cap_mint failed: {e}")))?;

    let plaintext_b64 = base64::engine::general_purpose::STANDARD.encode(content.as_bytes());
    let result = backend
        .cred_store(CredStoreInput { cap, plaintext_b64 })
        .await
        .map_err(|e| McpError::Backend(format!("cred_store failed: {e}")))?;

    tracing::info!(
        op = "cred.store",
        actor = %actor,
        service = %service,
        bytes = content.len(),
        s3_key = %result.s3_key,
        "credential write"
    );

    Ok(json!({
        "ok": result.ok,
        "service": service,
        "s3_key": result.s3_key,
        "envelope_size": result.envelope_size,
    }))
}

pub async fn fetch(
    caller: &CallerContext,
    backend: Arc<dyn Backend>,
    config: &Config,
    session_bearer: &str,
    params: &Value,
) -> McpResult<Value> {
    let (actor, operator_omni, service, device_key_hash, ttl_seconds) =
        resolve_common(caller, config, params)?;

    let cap = backend
        .cap_mint(
            CapMintOp::CredFetch,
            CapMintRequest {
                operator_omni: operator_omni.to_string(),
                actor_omni: actor.to_string(),
                service: service.to_string(),
                device_key_hash: device_key_hash.to_string(),
                ttl_seconds,
            },
            session_bearer,
        )
        .await
        .map_err(|e| McpError::Backend(format!("cap_mint failed: {e}")))?;

    let result = backend
        .cred_fetch(CredFetchInput { cap })
        .await
        .map_err(|e| McpError::Backend(format!("cred_fetch failed: {e}")))?;
    let plaintext = base64::engine::general_purpose::STANDARD
        .decode(&result.plaintext_b64)
        .map_err(|e| McpError::Internal(format!("plaintext_b64 decode: {e}")))?;
    let content = String::from_utf8(plaintext)
        .map_err(|e| McpError::Internal(format!("plaintext utf8: {e}")))?;

    tracing::info!(
        op = "cred.fetch",
        actor = %actor,
        service = %service,
        bytes = content.len(),
        "credential read"
    );

    Ok(json!({
        "ok": result.ok,
        "service": service,
        "content": content,
    }))
}
