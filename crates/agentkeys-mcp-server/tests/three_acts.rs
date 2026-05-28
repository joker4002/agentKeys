//! Three-act demo storyboard exercised end-to-end against the MockBackend.
//!
//! Reference: `docs/agent-iam-strategy.md` §4.3.
//!   Act 1 — Permissioned Memory (namespace-scoped read returns travel,
//!           refuses cross-namespace)
//!   Act 2 — Deterministic Denial (payment over daily cap)
//!   Act 3 — Online Revocation (revoke + retry, audit row appears)

mod common;

use std::sync::Arc;

use agentkeys_mcp_server::{auth::CallerContext, config::Config, mcp::Request, server::Server};
use common::MockBackend;
use serde_json::json;

const ACTOR: &str = "O_kevin_001";
const OPERATOR: &str = "O_kevin_op";
const DEVICE_KEY_HASH: &str = "0xdeadbeef";

fn server_with(backend: Arc<MockBackend>) -> Server {
    let config = Config::for_tests().with_vendor_token("magiclick", "demo-tok");
    Server::new(config, backend)
}

fn caller() -> CallerContext {
    CallerContext::new("magiclick", ACTOR)
}

fn req(method: &str, params: serde_json::Value) -> Request {
    Request {
        jsonrpc: "2.0".into(),
        method: method.into(),
        params: Some(params),
        id: Some(json!(1)),
    }
}

fn call_tool(name: &str, args: serde_json::Value) -> Request {
    req("tools/call", json!({"name": name, "arguments": args}))
}

#[tokio::test]
async fn act_1_permissioned_memory_returns_travel_namespace_only() {
    let backend = Arc::new(MockBackend::new());
    backend.seed_memory(
        ACTOR,
        "travel",
        "Chengdu trip — Apr 12 to 16, hotpot at Yulin.",
    );
    backend.seed_memory(ACTOR, "family", "Wife's bday Aug 3");
    backend.seed_memory(ACTOR, "personal", "Allergic to shellfish");

    // The toy's cap is scoped to `travel` only (operator-provisioned via
    // server config). This is the issue #108 enforcement boundary: the
    // agent can't widen it because namespaces_allowed comes from config,
    // not the request.
    let config = Config::for_tests()
        .with_vendor_token("magiclick", "demo-tok")
        .with_namespaces_allowed(["travel"]);
    let server = Server::new(config, backend.clone());

    // travel → in the cap's namespaces_allowed → returns the Chengdu trip.
    let resp = server
        .dispatch(
            &caller(),
            "session-bearer",
            call_tool(
                "agentkeys.memory.get",
                json!({
                    "actor": ACTOR,
                    "namespace": "travel",
                    "operator_omni": OPERATOR,
                    "device_key_hash": DEVICE_KEY_HASH
                }),
            ),
        )
        .await;

    assert!(
        resp.error.is_none(),
        "act 1 travel read errored: {:?}",
        resp.error
    );
    let result = resp.result.expect("result");
    let content = result["structuredContent"]["content"]
        .as_str()
        .expect("content string");
    assert!(content.contains("Chengdu"), "got: {content}");
    assert!(!content.contains("Wife"));
    assert!(!content.contains("shellfish"));

    // personal → NOT in namespaces_allowed → empty result + violation flag,
    // and a namespace_violation audit row is recorded. The toy "sees
    // nothing", not an error that would leak that the memory exists.
    let resp = server
        .dispatch(
            &caller(),
            "session-bearer",
            call_tool(
                "agentkeys.memory.get",
                json!({
                    "actor": ACTOR,
                    "namespace": "personal",
                    "operator_omni": OPERATOR,
                    "device_key_hash": DEVICE_KEY_HASH
                }),
            ),
        )
        .await;
    assert!(
        resp.error.is_none(),
        "cross-namespace read should be a clean empty result, not an error: {:?}",
        resp.error
    );
    let inner = &resp.result.expect("result")["structuredContent"];
    assert_eq!(inner["namespace_violation"], true);
    assert_eq!(inner["content"], "");
    assert_eq!(
        backend.audit_count(),
        1,
        "cross-namespace access must emit exactly one audit row"
    );

    // family → also denied; emits a second audit row.
    let resp = server
        .dispatch(
            &caller(),
            "session-bearer",
            call_tool(
                "agentkeys.memory.get",
                json!({
                    "actor": ACTOR,
                    "namespace": "family",
                    "operator_omni": OPERATOR,
                    "device_key_hash": DEVICE_KEY_HASH
                }),
            ),
        )
        .await;
    let inner = &resp.result.expect("result")["structuredContent"];
    assert_eq!(inner["namespace_violation"], true);
    assert_eq!(backend.audit_count(), 2);

    let mints = backend.cap_mints();
    assert!(
        mints
            .iter()
            .any(|(op, _)| matches!(op, agentkeys_mcp_server::backend::CapMintOp::MemoryGet)),
        "expected MemoryGet cap mint"
    );
}

#[tokio::test]
async fn act_2_payment_over_cap_returns_deterministic_deny() {
    let backend = Arc::new(MockBackend::new());
    let server = server_with(backend);

    let resp = server
        .dispatch(
            &caller(),
            "",
            call_tool(
                "agentkeys.permission.check",
                json!({
                    "actor": ACTOR,
                    "scope": "payment.spend",
                    "params": {"amount_rmb": 600}
                }),
            ),
        )
        .await;

    assert!(
        resp.error.is_none(),
        "act 2 unexpected error: {:?}",
        resp.error
    );
    let result = resp.result.expect("result");
    let inner = &result["structuredContent"];
    assert_eq!(inner["verdict"], "deny");
    assert_eq!(inner["reason"], "daily_spend_cap_exceeded");
    assert!(
        inner["explanation"].as_str().unwrap().contains("cap=500"),
        "explanation should match storyboard wording: {:?}",
        inner["explanation"]
    );
}

#[tokio::test]
async fn act_3_revoke_then_audit_append_records_event() {
    let backend = Arc::new(MockBackend::new());
    let server = server_with(backend.clone());

    let resp = server
        .dispatch(
            &caller(),
            "",
            call_tool("agentkeys.cap.revoke", json!({"cap_id": "cap-abc"})),
        )
        .await;
    assert!(resp.error.is_none());
    assert_eq!(backend.revoke_count(), 1);

    let resp = server
        .dispatch(
            &caller(),
            "",
            call_tool(
                "agentkeys.audit.append",
                json!({
                    "actor": ACTOR,
                    "event": {
                        "operator_omni": OPERATOR,
                        "op_kind": 3,
                        "op_body": {"cap_id": "cap-abc", "reason": "parent_revoke"},
                        "result": 0,
                        "intent_text": "parent revoked payment access"
                    }
                }),
            ),
        )
        .await;
    assert!(
        resp.error.is_none(),
        "audit append failed: {:?}",
        resp.error
    );
    assert_eq!(backend.audit_count(), 1);

    let result = resp.result.expect("result");
    assert!(result["structuredContent"]["envelope_hash"]
        .as_str()
        .unwrap()
        .starts_with("0x"));
}

#[tokio::test]
async fn cap_mint_memory_get_returns_cap_for_worker() {
    let backend = Arc::new(MockBackend::new());
    let server = server_with(backend.clone());

    let resp = server
        .dispatch(
            &caller(),
            "session-bearer",
            call_tool(
                "agentkeys.cap.mint",
                json!({
                    "actor": ACTOR,
                    "op": "memory_get",
                    "params": {
                        "operator_omni": OPERATOR,
                        "service": "memory",
                        "device_key_hash": DEVICE_KEY_HASH
                    },
                    "ttl": 300
                }),
            ),
        )
        .await;

    assert!(resp.error.is_none(), "cap.mint err: {:?}", resp.error);
    let result = resp.result.expect("result");
    let inner = &result["structuredContent"];
    assert_eq!(inner["op"], "memory_get");
    assert_eq!(inner["data_class"], "memory");
    assert!(inner["cap"]["broker_sig"].is_string());
}

#[tokio::test]
async fn whoami_returns_actor_facts() {
    let backend = Arc::new(MockBackend::new());
    let server = server_with(backend);

    let resp = server
        .dispatch(
            &caller(),
            "",
            call_tool("agentkeys.identity.whoami", json!({"actor": ACTOR})),
        )
        .await;
    assert!(resp.error.is_none());
    let inner = &resp.result.unwrap()["structuredContent"];
    assert_eq!(inner["omni"], ACTOR);
    assert_eq!(inner["vendor"], "magiclick");
    let scopes = inner["scopes"].as_array().expect("scopes array");
    assert!(scopes.iter().any(|s| s.as_str() == Some("memory.read")));
}
