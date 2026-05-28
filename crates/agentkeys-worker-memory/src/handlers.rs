//! Memory worker HTTP surface — mirrors credentials worker but at the
//! `memory/` prefix per arch.md §15.2 + §17 per-data-class buckets.

use axum::{
    extract::State,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

use crate::state::SharedMemoryWorkerState;
use agentkeys_types::Namespace;
use agentkeys_worker_creds::aws_creds::{s3_for_request, OptionalStsCreds};
use agentkeys_worker_creds::envelope;
use agentkeys_worker_creds::errors::{err_400, err_403, err_500, err_502, ApiError};
use agentkeys_worker_creds::verify::{self, CapOp, CapToken, DataClass};

pub fn build_router(state: SharedMemoryWorkerState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/memory/put", post(memory_put))
        .route("/v1/memory/get", post(memory_get))
        .route("/v1/memory/teardown", post(memory_teardown))
        .with_state(state)
}

#[derive(Debug, Serialize)]
pub struct HealthBody {
    pub ok: bool,
    pub memory_bucket: String,
    pub chain_profile: String,
    pub version: &'static str,
}

async fn healthz(State(state): State<SharedMemoryWorkerState>) -> Json<HealthBody> {
    Json(HealthBody {
        ok: true,
        memory_bucket: state.config.memory_bucket.clone(),
        chain_profile: state.config.chain_profile.clone(),
        version: env!("CARGO_PKG_VERSION"),
    })
}

#[derive(Debug, Deserialize)]
pub struct PutRequest {
    pub cap: CapToken,
    pub plaintext_b64: String,
    /// Memory namespace this write belongs to (issue #108). MUST be one of
    /// the v0 namespaces and MUST be in the cap's `namespaces_allowed`.
    pub namespace: String,
}

#[derive(Debug, Serialize)]
pub struct PutResponse {
    pub ok: bool,
    pub s3_key: String,
    pub envelope_size: usize,
    pub namespace: String,
    /// True when the write was refused because `namespace` was outside the
    /// cap's `namespaces_allowed`. The MCP server emits a
    /// `memory.namespace_violation` audit row when it sees this flag.
    #[serde(default)]
    pub namespace_violation: bool,
}

#[derive(Debug, Deserialize)]
pub struct GetRequest {
    pub cap: CapToken,
    /// Memory namespace to read (issue #108). Filtered by the cap's
    /// signed `namespaces_allowed` claim — a request for a namespace not
    /// in the claim returns an empty result (not the data).
    pub namespace: String,
}

#[derive(Debug, Serialize)]
pub struct GetResponse {
    pub ok: bool,
    pub plaintext_b64: String,
    pub namespace: String,
    /// True when the read was refused because `namespace` was outside the
    /// cap's `namespaces_allowed`. Paired with an empty `plaintext_b64`.
    #[serde(default)]
    pub namespace_violation: bool,
}

#[derive(Debug, Deserialize)]
pub struct TeardownRequest {
    pub cap: CapToken,
}

#[derive(Debug, Serialize)]
pub struct TeardownResponse {
    pub ok: bool,
    pub keys_deleted: usize,
}

async fn memory_put(
    State(state): State<SharedMemoryWorkerState>,
    OptionalStsCreds(creds): OptionalStsCreds,
    Json(req): Json<PutRequest>,
) -> Result<Json<PutResponse>, ApiError> {
    let namespace = normalize_namespace(&req.namespace)?;
    verify_cap(&state, &req.cap, CapOp::Store).await?;

    // Namespace gate (issue #108): refuse a write to a namespace the cap
    // wasn't granted. Returns a structured `namespace_violation` verdict
    // (HTTP 200) so the MCP server can emit the audit row + surface a
    // clean "refused" to the agent — symmetric with the empty-read path.
    if verify::check_namespace_allowed(&req.cap, &namespace).is_err() {
        return Ok(Json(PutResponse {
            ok: false,
            s3_key: String::new(),
            envelope_size: 0,
            namespace,
            namespace_violation: true,
        }));
    }

    use base64::{engine::general_purpose::STANDARD, Engine as _};
    let plaintext = STANDARD
        .decode(&req.plaintext_b64)
        .map_err(|e| err_400(e.to_string(), "plaintext_b64_decode"))?;

    let aad = envelope::aad(
        &req.cap.payload.operator_omni,
        &req.cap.payload.actor_omni,
        &req.cap.payload.service,
        req.cap.payload.k3_epoch,
    );
    let env_bytes = envelope::encrypt(&state.config.kek_hex_stage1, &plaintext, &aad)
        .map_err(|e| err_500(e.to_string(), "envelope_encrypt"))?;

    let key = s3_key(
        &req.cap.payload.actor_omni,
        &namespace,
        &req.cap.payload.service,
    );
    let s3 = s3_for_request(&state.s3, &state.config.region, creds.as_ref()).await;
    s3.put_object()
        .bucket(&state.config.memory_bucket)
        .key(&key)
        .body(env_bytes.clone().into())
        .send()
        .await
        .map_err(|e| err_502(e.to_string(), "s3_put"))?;
    Ok(Json(PutResponse {
        ok: true,
        s3_key: key,
        envelope_size: env_bytes.len(),
        namespace,
        namespace_violation: false,
    }))
}

async fn memory_get(
    State(state): State<SharedMemoryWorkerState>,
    OptionalStsCreds(creds): OptionalStsCreds,
    Json(req): Json<GetRequest>,
) -> Result<Json<GetResponse>, ApiError> {
    let namespace = normalize_namespace(&req.namespace)?;
    verify_cap(&state, &req.cap, CapOp::Fetch).await?;

    // Namespace gate (issue #108): a read for a namespace the cap wasn't
    // granted returns an EMPTY result (never the data) + a violation flag.
    // The toy "sees nothing" rather than an error that would leak whether
    // the memory exists. The MCP server emits the audit row off this flag.
    if verify::check_namespace_allowed(&req.cap, &namespace).is_err() {
        return Ok(Json(GetResponse {
            ok: false,
            plaintext_b64: String::new(),
            namespace,
            namespace_violation: true,
        }));
    }

    let key = s3_key(
        &req.cap.payload.actor_omni,
        &namespace,
        &req.cap.payload.service,
    );
    let s3 = s3_for_request(&state.s3, &state.config.region, creds.as_ref()).await;
    let resp = s3
        .get_object()
        .bucket(&state.config.memory_bucket)
        .key(&key)
        .send()
        .await
        .map_err(|e| err_502(e.to_string(), "s3_get"))?;
    let body = resp
        .body
        .collect()
        .await
        .map_err(|e| err_502(e.to_string(), "s3_body"))?
        .into_bytes();

    let aad = envelope::aad(
        &req.cap.payload.operator_omni,
        &req.cap.payload.actor_omni,
        &req.cap.payload.service,
        req.cap.payload.k3_epoch,
    );
    let plaintext = envelope::decrypt(&state.config.kek_hex_stage1, &body, &aad)
        .map_err(|e| err_500(e.to_string(), "envelope_decrypt"))?;

    use base64::{engine::general_purpose::STANDARD, Engine as _};
    Ok(Json(GetResponse {
        ok: true,
        plaintext_b64: STANDARD.encode(&plaintext),
        namespace,
        namespace_violation: false,
    }))
}

async fn memory_teardown(
    State(state): State<SharedMemoryWorkerState>,
    OptionalStsCreds(creds): OptionalStsCreds,
    Json(req): Json<TeardownRequest>,
) -> Result<Json<TeardownResponse>, ApiError> {
    verify_cap(&state, &req.cap, CapOp::Teardown).await?;

    let prefix = s3_prefix(&req.cap.payload.actor_omni);
    let s3 = s3_for_request(&state.s3, &state.config.region, creds.as_ref()).await;
    let list = s3
        .list_objects_v2()
        .bucket(&state.config.memory_bucket)
        .prefix(&prefix)
        .send()
        .await
        .map_err(|e| err_502(e.to_string(), "s3_list"))?;
    let keys: Vec<String> = list
        .contents()
        .iter()
        .filter_map(|o| o.key().map(String::from))
        .collect();
    let mut deleted = 0usize;
    for k in &keys {
        if s3
            .delete_object()
            .bucket(&state.config.memory_bucket)
            .key(k)
            .send()
            .await
            .is_ok()
        {
            deleted += 1;
        }
    }
    Ok(Json(TeardownResponse {
        ok: true,
        keys_deleted: deleted,
    }))
}

async fn verify_cap(
    state: &SharedMemoryWorkerState,
    cap: &CapToken,
    expected_op: CapOp,
) -> Result<(), ApiError> {
    verify::verify_signature(&state.config.broker_pubkey_pem, cap)
        .map_err(|e| err_403(e.to_string(), "broker_sig_invalid"))?;
    verify::check_op(cap, expected_op).map_err(|e| err_403(e.to_string(), "cap_op_mismatch"))?;
    // Per-data-class isolation gate (issue #90 followup): a credentials-class
    // cap MUST NOT be honoured at the memory worker. Symmetric with the cred
    // worker's check, defended in both directions.
    verify::check_data_class(cap, DataClass::Memory)
        .map_err(|e| err_403(e.to_string(), "cap_data_class_mismatch"))?;
    verify::check_freshness(cap).map_err(|e| err_403(e.to_string(), "cap_freshness_failed"))?;
    verify::check_chain_device(
        &state.http,
        &state.config.chain_rpc_http,
        &state.config.registry_contract,
        cap,
    )
    .await
    .map_err(err_403_or_502)?;
    verify::check_chain_scope(
        &state.http,
        &state.config.chain_rpc_http,
        &state.config.scope_contract,
        cap,
    )
    .await
    .map_err(err_403_or_502)?;
    verify::check_chain_k3_epoch(
        &state.http,
        &state.config.chain_rpc_http,
        &state.config.epoch_contract,
        cap,
    )
    .await
    .map_err(err_403_or_502)?;
    Ok(())
}

fn err_403_or_502(e: verify::VerifyError) -> ApiError {
    match e {
        verify::VerifyError::DeviceInactive
        | verify::VerifyError::DeviceMismatch { .. }
        | verify::VerifyError::DeviceRoleMissing { .. }
        | verify::VerifyError::NotInScope
        | verify::VerifyError::K3Mismatch { .. } => err_403(e.to_string(), "chain_check_failed"),
        _ => err_502(e.to_string(), "chain_rpc"),
    }
}

/// Normalize + validate a wire namespace (issue #108). Lowercases, then
/// rejects any name outside the v0 set with HTTP 400 — a typo'd namespace
/// must fail loud, not silently filter everything (the risk-table
/// mitigation in the issue). The returned string is the lowercase
/// canonical form used for the cap-membership check AND the S3 path
/// component.
fn normalize_namespace(raw: &str) -> Result<String, ApiError> {
    let lc = raw.trim().to_lowercase();
    if !Namespace::is_valid(&lc) {
        return Err(err_400(
            format!(
                "unknown namespace `{raw}` — must be one of: {}",
                Namespace::ALL
                    .iter()
                    .map(|n| n.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            "unknown_namespace",
        ));
    }
    Ok(lc)
}

/// S3 key for a namespaced memory blob (issue #108):
/// `bots/<actor_omni_hex>/memory/<namespace>/<service>.enc`.
///
/// The `<namespace>/` path component is what lets the four v0 namespaces
/// coexist for one actor under the legacy single-blob primitive — the
/// agent-facing `memory.get/put` tools don't expose `service` (it defaults
/// to "memory"), so without this component every namespace would collide
/// on one key. This is the `bots/<actor>/memory/<namespace>/…` migration
/// target sketched in agent-iam-strategy.md §3.5; arch.md §17 documents
/// why M1 ships it now (the metadata-only filter presupposes the 4-type
/// LIST retrieval, which isn't built yet). Still distinct from the creds
/// worker's `credentials/` subtree, preserving per-data-class separation.
fn s3_key(actor_omni: &str, namespace: &str, service: &str) -> String {
    format!(
        "bots/{}/memory/{}/{}.enc",
        actor_omni.trim_start_matches("0x").to_lowercase(),
        namespace.to_lowercase(),
        service.to_lowercase()
    )
}

fn s3_prefix(actor_omni: &str) -> String {
    format!(
        "bots/{}/memory/",
        actor_omni.trim_start_matches("0x").to_lowercase()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn s3_key_uses_memory_prefix_not_credentials() {
        // arch.md §17 separation: memory worker writes to bots/<actor>/memory/...,
        // NOT bots/<actor>/credentials/... A drift here would collapse the
        // per-data-class blast-radius.
        assert_eq!(
            s3_key("0xABCDEF", "travel", "chat-history"),
            "bots/abcdef/memory/travel/chat-history.enc"
        );
        assert!(!s3_key("0xabc", "travel", "x").contains("credentials"));
    }

    #[test]
    fn s3_key_partitions_by_namespace() {
        // Issue #108: the namespace path component lets distinct namespaces
        // coexist for one actor under the default service.
        let travel = s3_key("0xabc", "travel", "memory");
        let personal = s3_key("0xabc", "personal", "memory");
        assert_ne!(travel, personal);
        assert_eq!(travel, "bots/abc/memory/travel/memory.enc");
        assert_eq!(personal, "bots/abc/memory/personal/memory.enc");
    }

    #[test]
    fn s3_prefix_uses_memory_path() {
        // The teardown prefix still covers every namespace (they're
        // sub-paths under memory/).
        assert_eq!(s3_prefix("0xABCDEF"), "bots/abcdef/memory/");
    }

    #[test]
    fn normalize_namespace_lowercases_known() {
        assert_eq!(normalize_namespace("Travel").unwrap(), "travel");
        assert_eq!(normalize_namespace("  personal ").unwrap(), "personal");
    }

    #[test]
    fn normalize_namespace_rejects_unknown_with_400() {
        // `profile` is a memory TYPE, not a namespace.
        let err = normalize_namespace("profile").unwrap_err();
        assert_eq!(err.0, axum::http::StatusCode::BAD_REQUEST);
    }
}
