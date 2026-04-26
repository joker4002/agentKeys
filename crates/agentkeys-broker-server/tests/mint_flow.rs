//! End-to-end test for the broker's vertical slice:
//!   daemon bearer token → broker /v1/mint-aws-creds → stub STS → temp creds.
//!
//! The mock-server is the source of truth for session validity. The STS client
//! is replaced with a stub so the test never hits AWS.

use std::path::PathBuf;
use std::sync::Arc;

use agentkeys_broker_server::audit::AuditLog;
use agentkeys_broker_server::config::BrokerConfig;
use agentkeys_broker_server::create_router;
use agentkeys_broker_server::state::AppState;
use agentkeys_broker_server::sts::{AssumedCredentials, StubStsClient};
use serde_json::Value;

const STUB_ROLE_ARN: &str = "arn:aws:iam::000000000000:role/agentkeys-agent";

async fn spawn_mock_backend() -> String {
    let conn = rusqlite::Connection::open_in_memory().unwrap();
    agentkeys_mock_server::db::init_schema(&conn).unwrap();
    let state = Arc::new(agentkeys_mock_server::state::AppState::new(conn));
    let app = agentkeys_mock_server::create_router(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    format!("http://{}", addr)
}

async fn spawn_broker(backend_url: String) -> String {
    let stub_creds = AssumedCredentials {
        access_key_id: "ASIA-stub-AKID".into(),
        secret_access_key: "stub-secret".into(),
        session_token: "stub-session-token".into(),
        expiration_unix: 9_999_999_999,
    };

    let config = BrokerConfig {
        daemon_access_key_id: "AKIA-fake".into(),
        daemon_secret_access_key: "fake-secret".into(),
        agent_role_arn: STUB_ROLE_ARN.into(),
        backend_url,
        audit_db_path: PathBuf::from(":memory:"),
        aws_region: "us-east-1".into(),
        session_duration_seconds: 3600,
    };

    let state = Arc::new(AppState {
        config,
        http: reqwest::Client::new(),
        audit: AuditLog::open_in_memory().unwrap(),
        sts: Arc::new(StubStsClient { fixed_creds: stub_creds }),
    });
    let app = create_router(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    format!("http://{}", addr)
}

async fn mint_session_against_backend(backend_url: &str) -> (String, String) {
    let client = reqwest::Client::new();
    let resp: Value = client
        .post(format!("{}/session/create", backend_url))
        .json(&serde_json::json!({ "auth_token": "test-bearer-1" }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let session = resp["session"].as_str().unwrap().to_string();
    let wallet = resp["wallet"].as_str().unwrap().to_string();
    (session, wallet)
}

#[tokio::test]
async fn mint_aws_creds_happy_path() {
    let backend_url = spawn_mock_backend().await;
    let (session_token, wallet) = mint_session_against_backend(&backend_url).await;
    let broker_url = spawn_broker(backend_url).await;

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/v1/mint-aws-creds", broker_url))
        .header("Authorization", format!("Bearer {}", session_token))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), reqwest::StatusCode::OK, "expected 200");
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["access_key_id"], "ASIA-stub-AKID");
    assert_eq!(body["secret_access_key"], "stub-secret");
    assert_eq!(body["session_token"], "stub-session-token");
    assert_eq!(body["wallet"], wallet);
}

#[tokio::test]
async fn mint_aws_creds_rejects_missing_bearer() {
    let backend_url = spawn_mock_backend().await;
    let broker_url = spawn_broker(backend_url).await;

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/v1/mint-aws-creds", broker_url))
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), reqwest::StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn mint_aws_creds_rejects_invalid_bearer() {
    let backend_url = spawn_mock_backend().await;
    let broker_url = spawn_broker(backend_url).await;

    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/v1/mint-aws-creds", broker_url))
        .header("Authorization", "Bearer this-token-was-never-minted")
        .send()
        .await
        .unwrap();

    assert_eq!(resp.status(), reqwest::StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn healthz_returns_ok_without_backend_round_trip() {
    let backend_url = spawn_mock_backend().await;
    let broker_url = spawn_broker(backend_url).await;

    let client = reqwest::Client::new();
    let resp = client.get(format!("{}/healthz", broker_url)).send().await.unwrap();
    assert_eq!(resp.status(), reqwest::StatusCode::OK);
}

#[tokio::test]
async fn readyz_succeeds_when_backend_and_stub_sts_are_up() {
    let backend_url = spawn_mock_backend().await;
    let broker_url = spawn_broker(backend_url).await;

    let client = reqwest::Client::new();
    let resp = client.get(format!("{}/readyz", broker_url)).send().await.unwrap();
    assert_eq!(resp.status(), reqwest::StatusCode::OK);
}
