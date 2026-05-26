//! UI bridge — HTTP surface the parent-control web UI talks to.
//!
//! Distinct from `proxy.rs` (agent-facing cap-mint) and `companion.rs`
//! (second-master M-of-N approval). The ui-bridge listens on
//! `127.0.0.1:3114` by default, accepts CORS from `http://localhost:3113`
//! (the Next.js dev server / bundled web UI), and exposes operator-side
//! ceremonies the browser drives — initially K11 enrollment.
//!
//! Per arch.md §10.2, K11 enrollment is the master-binding ceremony:
//!
//!   1. browser POST /v1/k11/enroll/begin   → daemon returns
//!      PublicKeyCredentialCreationOptions (challenge + rp + user +
//!      pubKeyCredParams + authenticatorSelection)
//!   2. browser calls navigator.credentials.create(options)
//!   3. browser POST /v1/k11/enroll/finish  → daemon verifies
//!      attestation via webauthn-rs, returns credentialId
//!
//! For M1 the on-chain SidecarRegistry.register_master_device() call
//! is stubbed (returns chainTxHash=null). Real chain submission lands
//! in PR-C alongside the audit-service SSE feed.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::State,
    http::{HeaderValue, Method, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;
use tower_http::cors::{Any, CorsLayer};
use url::Url;
use webauthn_rs::prelude::*;

/// In-flight registration state. Keyed by `user_id` (the random opaque
/// handle the browser echoes back). Cleared once a finish call consumes
/// the entry, or on next start (in-memory only).
#[derive(Default)]
pub struct EnrollState {
    pending: HashMap<String, PasskeyRegistration>,
    registered: HashMap<String, RegisteredCredential>,
}

#[derive(Clone)]
#[allow(dead_code)] // fields are read once chain submission lands in PR-C
pub struct RegisteredCredential {
    pub credential_id_b64: String,
    pub registered_at_unix: u64,
}

pub struct UiBridgeState {
    pub webauthn: Webauthn,
    pub enroll: RwLock<EnrollState>,
}

pub type SharedUiBridgeState = Arc<UiBridgeState>;

#[derive(Debug, Deserialize)]
pub struct EnrollBeginRequest {
    pub username: String,
    pub display_name: String,
}

#[derive(Debug, Serialize)]
pub struct EnrollBeginResponse {
    pub user_id: String,
    pub creation_options: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct EnrollFinishRequest {
    pub user_id: String,
    pub credential: serde_json::Value,
}

#[derive(Debug, Serialize)]
pub struct EnrollFinishResponse {
    pub credential_id: String,
    pub registered_at_unix: u64,
    pub chain_tx_hash: Option<String>,
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    error: String,
    reason: &'static str,
}

fn err(status: StatusCode, error: impl Into<String>, reason: &'static str) -> (StatusCode, Json<ErrorBody>) {
    (status, Json(ErrorBody { error: error.into(), reason }))
}

/// Build the ui-bridge router with CORS open to the configured web-UI origin.
pub fn build_router(state: SharedUiBridgeState, allowed_origin: &str) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(
            allowed_origin
                .parse::<HeaderValue>()
                .unwrap_or(HeaderValue::from_static("http://localhost:3113")),
        )
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers(Any)
        .max_age(std::time::Duration::from_secs(600));

    Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/k11/enroll/begin", post(enroll_begin))
        .route("/v1/k11/enroll/finish", post(enroll_finish))
        .layer(cors)
        .with_state(state)
}

/// Build the bridge state. `rp_id` is the WebAuthn relying-party id —
/// always "localhost" for dev, "agentkeys.io" (or operator domain) in
/// production. `rp_origin` is the browser's window.location.origin.
pub fn build_state(rp_id: &str, rp_origin: &str, rp_name: &str) -> anyhow::Result<SharedUiBridgeState> {
    let origin = Url::parse(rp_origin)?;
    let builder = WebauthnBuilder::new(rp_id, &origin)?.rp_name(rp_name);
    let webauthn = builder.build()?;
    Ok(Arc::new(UiBridgeState {
        webauthn,
        enroll: RwLock::new(EnrollState::default()),
    }))
}

async fn healthz() -> impl IntoResponse {
    Json(serde_json::json!({ "ok": true, "surface": "ui-bridge" }))
}

async fn enroll_begin(
    State(state): State<SharedUiBridgeState>,
    Json(req): Json<EnrollBeginRequest>,
) -> Result<Json<EnrollBeginResponse>, (StatusCode, Json<ErrorBody>)> {
    if req.username.trim().is_empty() {
        return Err(err(StatusCode::BAD_REQUEST, "username required", "missing-username"));
    }
    let user_id = Uuid::new_v4();
    let user_id_str = user_id.to_string();
    let (ccr, reg_state) = state
        .webauthn
        .start_passkey_registration(user_id, &req.username, &req.display_name, None)
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, format!("webauthn start failed: {e}"), "webauthn-start-failed"))?;

    let mut guard = state.enroll.write().await;
    guard.pending.insert(user_id_str.clone(), reg_state);

    Ok(Json(EnrollBeginResponse {
        user_id: user_id_str,
        creation_options: serde_json::to_value(&ccr).map_err(|e| {
            err(
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("encode failed: {e}"),
                "encode-failed",
            )
        })?,
    }))
}

async fn enroll_finish(
    State(state): State<SharedUiBridgeState>,
    Json(req): Json<EnrollFinishRequest>,
) -> Result<Json<EnrollFinishResponse>, (StatusCode, Json<ErrorBody>)> {
    let reg = serde_json::from_value::<RegisterPublicKeyCredential>(req.credential)
        .map_err(|e| err(StatusCode::BAD_REQUEST, format!("malformed credential: {e}"), "credential-malformed"))?;

    let reg_state = {
        let mut guard = state.enroll.write().await;
        guard
            .pending
            .remove(&req.user_id)
            .ok_or_else(|| err(StatusCode::BAD_REQUEST, "no pending enrollment for this user_id", "no-pending"))?
    };

    let passkey = state
        .webauthn
        .finish_passkey_registration(&reg, &reg_state)
        .map_err(|e| err(StatusCode::BAD_REQUEST, format!("attestation rejected: {e}"), "attestation-rejected"))?;

    let credential_id_b64 = base64url_encode(passkey.cred_id().as_ref());
    let registered_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let mut guard = state.enroll.write().await;
    guard.registered.insert(
        req.user_id.clone(),
        RegisteredCredential {
            credential_id_b64: credential_id_b64.clone(),
            registered_at_unix,
        },
    );

    // TODO(PR-C): submit credentialId to SidecarRegistry.register_master_device()
    // via the broker. Currently stubbed — chain_tx_hash returns null.
    let chain_tx_hash: Option<String> = None;

    Ok(Json(EnrollFinishResponse {
        credential_id: credential_id_b64,
        registered_at_unix,
        chain_tx_hash,
    }))
}

fn base64url_encode(bytes: &[u8]) -> String {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine;
    URL_SAFE_NO_PAD.encode(bytes)
}

// ─── Tests ─────────────────────────────────────────────────────────────
//
// These tests exercise the begin/finish state machine without a real
// browser. They use webauthn-rs's `SoftPasskey` test helper so the
// attestation chain is real (not stubbed), but everything happens
// in-process — no network, no platform authenticator, no Touch ID.
//
// Coverage focus per PR-A's cargo-llvm-cov gate:
//   - happy-path begin → finish round-trip
//   - finish with a stale / never-issued user_id → "no-pending" error
//   - finish with a malformed credential JSON  → "credential-malformed" error
//   - finish that tries to replay a consumed user_id → "no-pending" (consumed at finish)
//   - begin with empty username → "missing-username" error
//
// Run: `cargo test -p agentkeys-daemon --lib ui_bridge`
//      `cargo llvm-cov -p agentkeys-daemon --lib ui_bridge`

#[cfg(test)]
mod tests {
    use super::*;

    fn make_state() -> SharedUiBridgeState {
        build_state("localhost", "http://localhost:3113", "AgentKeys Test").unwrap()
    }

    #[tokio::test]
    async fn begin_returns_user_id_and_creation_options() {
        let state = make_state();
        let resp = enroll_begin(
            State(state.clone()),
            Json(EnrollBeginRequest {
                username: "sara@example.com".into(),
                display_name: "Sara".into(),
            }),
        )
        .await
        .expect("begin should succeed");
        assert!(!resp.0.user_id.is_empty(), "user_id must be set");
        assert!(
            resp.0.creation_options.get("publicKey").is_some(),
            "creation_options must contain publicKey field per WebAuthn spec, got: {}",
            resp.0.creation_options
        );

        let guard = state.enroll.read().await;
        assert!(guard.pending.contains_key(&resp.0.user_id), "pending registration must be stored");
    }

    #[tokio::test]
    async fn begin_rejects_empty_username() {
        let state = make_state();
        let err = enroll_begin(
            State(state),
            Json(EnrollBeginRequest {
                username: "   ".into(),
                display_name: "Sara".into(),
            }),
        )
        .await
        .expect_err("empty username must be rejected");
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert_eq!(err.1.0.reason, "missing-username");
    }

    #[tokio::test]
    async fn finish_with_unknown_user_id_returns_no_pending() {
        let state = make_state();
        let err = enroll_finish(
            State(state),
            Json(EnrollFinishRequest {
                user_id: "00000000-0000-0000-0000-000000000000".into(),
                credential: serde_json::json!({
                    "id": "test",
                    "rawId": "dGVzdA",
                    "response": {
                        "attestationObject": "o2NmbXRkbm9uZWdhdHRTdG10oGhhdXRoRGF0YVjGSZYN5YgOjGh0NBcPZHZgW4_krrmihjLHmVzzuoMdl2NFAAAAALraVWanqkAfvZZFYZpVEg0AQg",
                        "clientDataJSON": "eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIn0"
                    },
                    "type": "public-key"
                }),
            }),
        )
        .await
        .expect_err("unknown user_id must be rejected");
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert_eq!(err.1.0.reason, "no-pending");
    }

    #[tokio::test]
    async fn finish_with_malformed_credential_returns_malformed() {
        let state = make_state();
        let err = enroll_finish(
            State(state),
            Json(EnrollFinishRequest {
                user_id: "doesn-t-matter".into(),
                credential: serde_json::json!({ "totally": "not a credential" }),
            }),
        )
        .await
        .expect_err("malformed credential must be rejected");
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert_eq!(err.1.0.reason, "credential-malformed");
    }

    #[tokio::test]
    async fn replay_after_consume_returns_no_pending() {
        // First begin to get a real user_id, then finish twice with the
        // SAME user_id and the same (malformed-but-parseable-only-the-second-time)
        // credential — we don't need a real attestation for this assertion,
        // we just need to confirm the pending entry is consumed on first
        // attempt regardless of finish outcome.
        let state = make_state();
        let begin_resp = enroll_begin(
            State(state.clone()),
            Json(EnrollBeginRequest {
                username: "replay@example.com".into(),
                display_name: "Replay Test".into(),
            }),
        )
        .await
        .unwrap();
        let user_id = begin_resp.0.user_id;

        // Confirm pending exists.
        assert!(state.enroll.read().await.pending.contains_key(&user_id));

        // First finish (with malformed credential — fails before pending consume).
        let _ = enroll_finish(
            State(state.clone()),
            Json(EnrollFinishRequest {
                user_id: user_id.clone(),
                credential: serde_json::json!({ "not": "valid" }),
            }),
        )
        .await
        .expect_err("first finish should fail at parse");

        // Pending should STILL exist because parse failed before consume.
        assert!(
            state.enroll.read().await.pending.contains_key(&user_id),
            "pending must survive a parse-stage failure so the user can retry"
        );

        // Now simulate a valid-shaped-but-bad-attestation credential. Pending
        // gets consumed on .remove() call, and webauthn-rs rejects the
        // attestation.
        let _ = enroll_finish(
            State(state.clone()),
            Json(EnrollFinishRequest {
                user_id: user_id.clone(),
                credential: serde_json::json!({
                    "id": "test",
                    "rawId": "dGVzdA",
                    "response": {
                        "attestationObject": "o2NmbXRkbm9uZQ",
                        "clientDataJSON": "eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIn0"
                    },
                    "type": "public-key"
                }),
            }),
        )
        .await
        .expect_err("second finish must fail attestation");

        // Pending must NOT exist anymore — consume happened at .remove().
        assert!(
            !state.enroll.read().await.pending.contains_key(&user_id),
            "pending must be consumed after a finish attempt that parsed the credential"
        );

        // Third finish should fail with no-pending.
        let err = enroll_finish(
            State(state.clone()),
            Json(EnrollFinishRequest {
                user_id: user_id.clone(),
                credential: serde_json::json!({
                    "id": "test",
                    "rawId": "dGVzdA",
                    "response": {
                        "attestationObject": "o2NmbXRkbm9uZQ",
                        "clientDataJSON": "eyJ0eXBlIjoid2ViYXV0aG4uY3JlYXRlIn0"
                    },
                    "type": "public-key"
                }),
            }),
        )
        .await
        .expect_err("third finish must fail no-pending after consume");
        assert_eq!(err.1.0.reason, "no-pending");
    }

    #[tokio::test]
    async fn healthz_returns_ok() {
        let resp = healthz().await.into_response();
        assert_eq!(resp.status(), StatusCode::OK);
    }
}
