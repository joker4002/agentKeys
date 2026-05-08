//! Integration tests for `/dev/derive-address` and `/dev/sign-message`
//! per `docs/spec/signer-protocol.md`.
//!
//! These tests build the router directly (no real TCP) so the env-var seam
//! that gates the dev signer can be controlled per case without touching
//! the process environment.

use agentkeys_mock_server::{
    create_router, db, dev_key_service::DevKeyService, state::AppState,
};
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use axum::Router;
use http_body_util::BodyExt;
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;

fn router_without_signer() -> Router {
    let conn = rusqlite::Connection::open_in_memory().unwrap();
    db::init_schema(&conn).unwrap();
    let state = Arc::new(AppState::new(conn));
    create_router(state)
}

fn router_with_signer(master_secret: [u8; 32]) -> Router {
    let conn = rusqlite::Connection::open_in_memory().unwrap();
    db::init_schema(&conn).unwrap();
    let signer = DevKeyService::from_master_secret(master_secret);
    let state = Arc::new(AppState::new(conn).with_dev_signer(Some(signer)));
    create_router(state)
}

async fn post_json(app: Router, path: &str, body: Value) -> (StatusCode, Value) {
    let req = Request::builder()
        .method(Method::POST)
        .uri(path)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_string(&body).unwrap()))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, json)
}

fn fixed_omni() -> String {
    "ab".repeat(32)
}

#[tokio::test]
async fn derive_address_returns_503_when_signer_disabled() {
    let app = router_without_signer();
    let (status, body) = post_json(
        app,
        "/dev/derive-address",
        json!({ "omni_account": fixed_omni() }),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"], "signer_disabled");
    assert!(body["message"]
        .as_str()
        .unwrap()
        .contains("DEV_KEY_SERVICE_MASTER_SECRET"));
}

#[tokio::test]
async fn sign_message_returns_503_when_signer_disabled() {
    let app = router_without_signer();
    let (status, body) = post_json(
        app,
        "/dev/sign-message",
        json!({
            "omni_account": fixed_omni(),
            "message_hex":  hex::encode(b"hello"),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"], "signer_disabled");
}

#[tokio::test]
async fn derive_address_is_deterministic_across_calls() {
    let master = [0x42u8; 32];
    let omni = fixed_omni();

    let (s1, b1) = post_json(
        router_with_signer(master),
        "/dev/derive-address",
        json!({ "omni_account": omni }),
    )
    .await;
    let (s2, b2) = post_json(
        router_with_signer(master),
        "/dev/derive-address",
        json!({ "omni_account": omni }),
    )
    .await;
    assert_eq!(s1, StatusCode::OK);
    assert_eq!(s2, StatusCode::OK);
    assert_eq!(b1["address"], b2["address"]);
    let addr = b1["address"].as_str().unwrap();
    assert!(addr.starts_with("0x"));
    assert_eq!(addr.len(), 42);
    assert_eq!(addr, addr.to_lowercase());
    assert_eq!(b1["key_version"], 1);
}

#[tokio::test]
async fn derive_address_rejects_short_omni() {
    let app = router_with_signer([0u8; 32]);
    let (status, body) = post_json(
        app,
        "/dev/derive-address",
        json!({ "omni_account": "deadbeef" }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "invalid_omni_account");
}

#[tokio::test]
async fn sign_message_address_matches_derive_response() {
    let master = [0x33u8; 32];
    let omni = fixed_omni();

    let (s1, derive) = post_json(
        router_with_signer(master),
        "/dev/derive-address",
        json!({ "omni_account": omni }),
    )
    .await;
    let (s2, sign) = post_json(
        router_with_signer(master),
        "/dev/sign-message",
        json!({
            "omni_account": omni,
            "message_hex":  hex::encode(b"siwe-test"),
        }),
    )
    .await;
    assert_eq!(s1, StatusCode::OK);
    assert_eq!(s2, StatusCode::OK);
    assert_eq!(derive["address"], sign["address"]);
    assert_eq!(derive["key_version"], sign["key_version"]);
}

#[tokio::test]
async fn sign_message_returns_canonical_65_byte_signature() {
    let app = router_with_signer([0u8; 32]);
    let (status, body) = post_json(
        app,
        "/dev/sign-message",
        json!({
            "omni_account": fixed_omni(),
            "message_hex":  hex::encode(b"hello"),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let sig = body["signature"].as_str().unwrap();
    assert!(sig.starts_with("0x"));
    let raw = hex::decode(sig.trim_start_matches("0x")).unwrap();
    assert_eq!(raw.len(), 65);
    let v = raw[64];
    assert!(v == 0 || v == 1, "v byte must be canonical {{0,1}}, got {v}");
}

#[tokio::test]
async fn sign_message_rejects_invalid_message_hex() {
    let app = router_with_signer([0u8; 32]);
    let (status, body) = post_json(
        app,
        "/dev/sign-message",
        json!({
            "omni_account": fixed_omni(),
            "message_hex":  "not-hex-zzz",
        }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"], "invalid_message_hex");
}

#[tokio::test]
async fn different_master_secrets_produce_different_addresses() {
    let omni = fixed_omni();
    let (_, a) = post_json(
        router_with_signer([0x11u8; 32]),
        "/dev/derive-address",
        json!({ "omni_account": omni }),
    )
    .await;
    let (_, b) = post_json(
        router_with_signer([0x22u8; 32]),
        "/dev/derive-address",
        json!({ "omni_account": omni }),
    )
    .await;
    assert_ne!(a["address"], b["address"]);
}
