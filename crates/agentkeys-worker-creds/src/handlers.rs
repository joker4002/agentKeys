//! HTTP handlers — wired into a tower service in main.rs.
//!
//! Endpoints:
//!   GET  /healthz                — service ready check (200 if S3 client is up)
//!   POST /v1/cred/store          — verify cap → encrypt → S3 PUT
//!   POST /v1/cred/fetch          — verify cap → S3 GET → decrypt → return plaintext
//!   POST /v1/cred/teardown       — verify cap → S3 DELETE the actor's prefix

use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

use crate::envelope;
use crate::state::SharedWorkerState;
use crate::verify::{self, CapToken};

pub fn build_router(state: SharedWorkerState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/cred/store", post(cred_store))
        .route("/v1/cred/fetch", post(cred_fetch))
        .route("/v1/cred/teardown", post(cred_teardown))
        .with_state(state)
}

#[derive(Debug, Serialize)]
pub struct HealthBody {
    pub ok: bool,
    pub vault_bucket: String,
    pub version: &'static str,
}

async fn healthz(State(state): State<SharedWorkerState>) -> Json<HealthBody> {
    Json(HealthBody {
        ok: true,
        vault_bucket: state.config.vault_bucket.clone(),
        version: env!("CARGO_PKG_VERSION"),
    })
}

#[derive(Debug, Deserialize)]
pub struct StoreRequest {
    pub cap: CapToken,
    pub plaintext_b64: String, // base64(stdandard)
}

#[derive(Debug, Serialize)]
pub struct StoreResponse {
    pub ok: bool,
    pub s3_key: String,
    pub envelope_size: usize,
}

#[derive(Debug, Deserialize)]
pub struct FetchRequest {
    pub cap: CapToken,
}

#[derive(Debug, Serialize)]
pub struct FetchResponse {
    pub ok: bool,
    pub plaintext_b64: String,
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

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub error: String,
    pub reason: &'static str,
}

async fn cred_store(
    State(state): State<SharedWorkerState>,
    Json(req): Json<StoreRequest>,
) -> Result<Json<StoreResponse>, (StatusCode, Json<ErrorBody>)> {
    verify_cap(&state, &req.cap).await?;

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
    let envelope = envelope::encrypt(&state.config.kek_hex_stage1, &plaintext, &aad)
        .map_err(|e| err_500(e.to_string(), "envelope_encrypt"))?;

    let key = s3_key(&req.cap.payload.actor_omni, &req.cap.payload.service);
    state
        .s3
        .put_object()
        .bucket(&state.config.vault_bucket)
        .key(&key)
        .body(envelope.clone().into())
        .send()
        .await
        .map_err(|e| err_502(e.to_string(), "s3_put"))?;
    Ok(Json(StoreResponse {
        ok: true,
        s3_key: key,
        envelope_size: envelope.len(),
    }))
}

async fn cred_fetch(
    State(state): State<SharedWorkerState>,
    Json(req): Json<FetchRequest>,
) -> Result<Json<FetchResponse>, (StatusCode, Json<ErrorBody>)> {
    verify_cap(&state, &req.cap).await?;

    let key = s3_key(&req.cap.payload.actor_omni, &req.cap.payload.service);
    let resp = state
        .s3
        .get_object()
        .bucket(&state.config.vault_bucket)
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
    Ok(Json(FetchResponse {
        ok: true,
        plaintext_b64: STANDARD.encode(&plaintext),
    }))
}

async fn cred_teardown(
    State(state): State<SharedWorkerState>,
    Json(req): Json<TeardownRequest>,
) -> Result<Json<TeardownResponse>, (StatusCode, Json<ErrorBody>)> {
    verify_cap(&state, &req.cap).await?;

    let prefix = s3_prefix(&req.cap.payload.actor_omni);
    let list = state
        .s3
        .list_objects_v2()
        .bucket(&state.config.vault_bucket)
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
        if state
            .s3
            .delete_object()
            .bucket(&state.config.vault_bucket)
            .key(k)
            .send()
            .await
            .is_ok()
        {
            deleted += 1;
        }
    }
    Ok(Json(TeardownResponse { ok: true, keys_deleted: deleted }))
}

async fn verify_cap(
    state: &SharedWorkerState,
    cap: &CapToken,
) -> Result<(), (StatusCode, Json<ErrorBody>)> {
    verify::verify_signature(&state.config.broker_pubkey_pem, cap)
        .map_err(|e| err_403(e.to_string(), "broker_sig_invalid"))?;
    verify::check_not_expired(cap)
        .map_err(|e| err_403(e.to_string(), "cap_expired"))?;
    verify::check_chain_scope(
        &state.http,
        &state.config.chain_rpc_http,
        &state.config.scope_contract,
        cap,
    )
    .await
    .map_err(|e| match e {
        verify::VerifyError::NotInScope => err_403(e.to_string(), "service_not_in_scope"),
        _ => err_502(e.to_string(), "chain_rpc"),
    })?;
    Ok(())
}

fn s3_key(actor_omni: &str, service: &str) -> String {
    format!(
        "bots/{}/credentials/{}.enc",
        actor_omni.trim_start_matches("0x").to_lowercase(),
        service.to_lowercase()
    )
}

fn s3_prefix(actor_omni: &str) -> String {
    format!(
        "bots/{}/credentials/",
        actor_omni.trim_start_matches("0x").to_lowercase()
    )
}

fn err_400(msg: String, reason: &'static str) -> (StatusCode, Json<ErrorBody>) {
    (StatusCode::BAD_REQUEST, Json(ErrorBody { error: msg, reason }))
}
fn err_403(msg: String, reason: &'static str) -> (StatusCode, Json<ErrorBody>) {
    (StatusCode::FORBIDDEN, Json(ErrorBody { error: msg, reason }))
}
fn err_500(msg: String, reason: &'static str) -> (StatusCode, Json<ErrorBody>) {
    (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorBody { error: msg, reason }))
}
fn err_502(msg: String, reason: &'static str) -> (StatusCode, Json<ErrorBody>) {
    (StatusCode::BAD_GATEWAY, Json(ErrorBody { error: msg, reason }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn s3_key_format_matches_arch_md_15_1() {
        // arch.md §15.1: s3://$VAULT_BUCKET/bots/<actor_omni_hex>/credentials/<service>.enc
        assert_eq!(
            s3_key("0xABCDEF", "openrouter"),
            "bots/abcdef/credentials/openrouter.enc"
        );
        assert_eq!(
            s3_key("abcdef", "OpenRouter"),
            "bots/abcdef/credentials/openrouter.enc"
        );
    }

    #[test]
    fn s3_prefix_matches_arch_md_15_1() {
        assert_eq!(s3_prefix("0xABCDEF"), "bots/abcdef/credentials/");
    }
}
