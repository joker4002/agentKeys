//! HTTP handlers for the dev_key_service signer.
//!
//! See `docs/spec/signer-protocol.md` for the wire contract. Both endpoints
//! return 503 `signer_disabled` when `state.dev_signer` is `None`
//! (i.e. `DEV_KEY_SERVICE_MASTER_SECRET` was unset at boot). When enabled,
//! they delegate to `DevKeyService` for derivation/signing.

use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::dev_key_service::{SignerError, KEY_VERSION};
use crate::state::SharedState;

#[derive(Deserialize)]
pub struct DeriveAddressRequest {
    pub omni_account: String,
}

#[derive(Deserialize)]
pub struct SignMessageRequest {
    pub omni_account: String,
    pub message_hex: String,
}

pub async fn derive_address(
    State(state): State<SharedState>,
    Json(body): Json<DeriveAddressRequest>,
) -> impl IntoResponse {
    let Some(signer) = state.dev_signer.as_ref() else {
        return signer_disabled();
    };
    match signer.derive_address(&body.omni_account) {
        Ok(address) => (
            StatusCode::OK,
            Json(json!({
                "address":     address,
                "key_version": KEY_VERSION,
            })),
        ),
        Err(e) => signer_error(e),
    }
}

pub async fn sign_message(
    State(state): State<SharedState>,
    Json(body): Json<SignMessageRequest>,
) -> impl IntoResponse {
    let Some(signer) = state.dev_signer.as_ref() else {
        return signer_disabled();
    };

    let message_bytes = match hex::decode(body.message_hex.trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => {
            return signer_error(SignerError::InvalidMessageHex(format!(
                "not valid hex: {e}"
            )));
        }
    };

    match signer.sign_eip191(&body.omni_account, &message_bytes) {
        Ok((signature, address)) => (
            StatusCode::OK,
            Json(json!({
                "signature":   signature,
                "address":     address,
                "key_version": KEY_VERSION,
            })),
        ),
        Err(e) => signer_error(e),
    }
}

fn signer_disabled() -> (StatusCode, Json<Value>) {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({
            "error":   "signer_disabled",
            "message": "dev_key_service disabled — set DEV_KEY_SERVICE_MASTER_SECRET to enable",
        })),
    )
}

fn signer_error(e: SignerError) -> (StatusCode, Json<Value>) {
    let status = StatusCode::from_u16(e.http_status())
        .unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (
        status,
        Json(json!({
            "error":   e.code(),
            "message": e.to_string(),
        })),
    )
}
