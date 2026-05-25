//! In-memory `Backend` for the dev-mode demo.
//!
//! Mirrors the test `MockBackend` shape but runs inside the production
//! binary so a fresh `cargo run -p agentkeys-mcp-server -- --backend
//! in-memory` is enough to walk the three-act storyboard without
//! deploying a broker, memory worker, or audit worker.
//!
//! Seeded by default with the storyboard fixtures from
//! `docs/research/agent-iam-strategy.md` §4.3:
//!   - actor `O_kevin_001`, namespace `travel`:  Chengdu trip context
//!   - actor `O_kevin_001`, namespace `family`:  bday note
//!   - actor `O_kevin_001`, namespace `profile`: allergy note

use async_trait::async_trait;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use super::{
    AuditAppendInput, AuditAppendResult, Backend, BackendError, CapMintOp, CapMintRequest,
    CapToken, MemoryGetInput, MemoryGetResult, MemoryPutInput, MemoryPutResult, RevokeResult,
};

pub const DEMO_ACTOR: &str = "O_kevin_001";

pub struct InMemoryBackend {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    memory: HashMap<(String, String), String>,
    audit: Vec<AuditAppendInput>,
    revoked: Vec<String>,
}

impl Default for InMemoryBackend {
    fn default() -> Self {
        Self::new_with_demo_fixture()
    }
}

impl InMemoryBackend {
    pub fn new_empty() -> Self {
        Self {
            inner: Mutex::new(Inner::default()),
        }
    }

    pub fn new_with_demo_fixture() -> Self {
        let backend = Self::new_empty();
        backend.seed(DEMO_ACTOR, "travel", "Chengdu trip — Apr 12 to 16, hotpot at Yulin.");
        backend.seed(DEMO_ACTOR, "family", "Wife's bday Aug 3 (gift idea: hiking boots).");
        backend.seed(DEMO_ACTOR, "profile", "Allergic to shellfish. Prefers windowed flights.");
        backend
    }

    pub fn seed(&self, actor: &str, namespace: &str, content: &str) {
        let mut g = self.inner.lock().unwrap();
        g.memory.insert(
            (actor.to_string(), namespace.to_string()),
            content.to_string(),
        );
    }
}

#[async_trait]
impl Backend for InMemoryBackend {
    async fn cap_mint(
        &self,
        op: CapMintOp,
        req: CapMintRequest,
        _session_bearer: &str,
    ) -> Result<CapToken, BackendError> {
        let issued_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        Ok(json!({
            "payload": {
                "operator_omni": req.operator_omni,
                "actor_omni":    req.actor_omni,
                "service":       req.service,
                "op":            format!("{op:?}"),
                "data_class":    op.data_class(),
                "device_key_hash": req.device_key_hash,
                "k3_epoch":      1,
                "issued_at":     issued_at,
                "expires_at":    issued_at + req.ttl_seconds,
                "nonce":         "in-memory-nonce"
            },
            "broker_sig": "in-memory-signature"
        }))
    }

    async fn cap_revoke(&self, cap_id: &str) -> Result<RevokeResult, BackendError> {
        self.inner.lock().unwrap().revoked.push(cap_id.to_string());
        Ok(RevokeResult {
            ok: true,
            revocation: "in_memory".into(),
            note: Some(format!("dev-mode revoke; cap_id={cap_id} recorded locally")),
        })
    }

    async fn memory_put(&self, input: MemoryPutInput) -> Result<MemoryPutResult, BackendError> {
        let actor = input
            .cap
            .get("payload")
            .and_then(|p| p.get("actor_omni"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let plaintext = String::from_utf8(
            base64::Engine::decode(
                &base64::engine::general_purpose::STANDARD,
                &input.plaintext_b64,
            )
            .map_err(|e| BackendError::Parse(e.to_string()))?,
        )
        .map_err(|e| BackendError::Parse(e.to_string()))?;

        let mut g = self.inner.lock().unwrap();
        g.memory
            .insert((actor.clone(), input.namespace.clone()), plaintext);

        Ok(MemoryPutResult {
            ok: true,
            s3_key: format!("bots/{actor}/{}/in-memory.bin", input.namespace),
            envelope_size: input.plaintext_b64.len(),
            namespace: input.namespace,
        })
    }

    async fn memory_get(&self, input: MemoryGetInput) -> Result<MemoryGetResult, BackendError> {
        let actor = input
            .cap
            .get("payload")
            .and_then(|p| p.get("actor_omni"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();

        let g = self.inner.lock().unwrap();
        let content = g
            .memory
            .get(&(actor, input.namespace.clone()))
            .cloned()
            .ok_or_else(|| BackendError::Http {
                status: 404,
                body: format!("no memory in namespace `{}`", input.namespace),
            })?;

        Ok(MemoryGetResult {
            ok: true,
            plaintext_b64: base64::Engine::encode(
                &base64::engine::general_purpose::STANDARD,
                content.as_bytes(),
            ),
            namespace: input.namespace,
        })
    }

    async fn audit_append(
        &self,
        input: AuditAppendInput,
    ) -> Result<AuditAppendResult, BackendError> {
        let mut g = self.inner.lock().unwrap();
        g.audit.push(input.clone());
        let idx = g.audit.len() as u8;
        let mut bytes = [0u8; 32];
        bytes[0] = idx;
        Ok(AuditAppendResult {
            ok: true,
            envelope_hash: format!("0x{}", hex::encode(bytes)),
        })
    }
}
