//! Cap-token verification — same shape as
//! agentkeys-broker-server/src/handlers/cap.rs but flipped (verify
//! instead of sign).
//!
//! The worker MUST independently re-verify three things before any S3
//! touch (arch.md §15.1):
//!   1. `broker_sig` is a valid P-256 signature over Sha256(json(payload))
//!      under the env-injected broker pubkey.
//!   2. `payload.expires_at > now()` (cap not expired).
//!   3. On-chain `AgentKeysScope.isServiceInScope(operator, actor, keccak(service))`
//!      is `true` at `latest` block height (broker may have been compromised
//!      since minting; chain is the ground truth).

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CapOp {
    Store,
    Fetch,
    Teardown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapPayload {
    pub operator_omni: String,
    pub actor_omni: String,
    pub service: String,
    pub op: CapOp,
    pub k3_epoch: u64,
    pub expires_at: u64,
    pub nonce: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapToken {
    pub payload: CapPayload,
    pub broker_sig: String,
}

#[derive(Debug, Error)]
pub enum VerifyError {
    #[error("broker public key parse: {0}")]
    BrokerKey(String),
    #[error("signature decode (base64): {0}")]
    SigDecode(String),
    #[error("signature parse: {0}")]
    SigParse(String),
    #[error("signature verify failed")]
    SigInvalid,
    #[error("payload canonical-json encode: {0}")]
    Encode(String),
    #[error("cap expired at {expires_at} (now={now})")]
    Expired { expires_at: u64, now: u64 },
    #[error("chain RPC error: {0}")]
    ChainRpc(String),
    #[error("requested service not in agent's on-chain scope")]
    NotInScope,
}

pub fn verify_signature(
    pubkey_pem: &str,
    token: &CapToken,
) -> Result<(), VerifyError> {
    let canonical = serde_json::to_vec(&token.payload)
        .map_err(|e| VerifyError::Encode(e.to_string()))?;
    let mut h = Sha256::new();
    h.update(&canonical);
    let digest = h.finalize();
    let sig_bytes = URL_SAFE_NO_PAD
        .decode(&token.broker_sig)
        .map_err(|e| VerifyError::SigDecode(e.to_string()))?;
    let sig = Signature::from_slice(&sig_bytes)
        .map_err(|e| VerifyError::SigParse(e.to_string()))?;
    let vk = parse_p256_pubkey_pem(pubkey_pem)?;
    vk.verify(&digest, &sig).map_err(|_| VerifyError::SigInvalid)
}

pub fn check_not_expired(token: &CapToken) -> Result<(), VerifyError> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if token.payload.expires_at <= now {
        return Err(VerifyError::Expired {
            expires_at: token.payload.expires_at,
            now,
        });
    }
    Ok(())
}

pub async fn check_chain_scope(
    http: &reqwest::Client,
    rpc_url: &str,
    scope_contract: &str,
    token: &CapToken,
) -> Result<(), VerifyError> {
    let selector = function_selector("isServiceInScope(bytes32,bytes32,bytes32)");
    let a = pad32(&token.payload.operator_omni)?;
    let b = pad32(&token.payload.actor_omni)?;
    let service_hash = keccak_lc_service(&token.payload.service);
    let c = pad32(&service_hash)?;
    let data = format!("0x{selector}{a}{b}{c}");

    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_call",
        "params": [{"to": scope_contract, "data": data}, "latest"],
        "id": 1,
    });
    let resp = http
        .post(rpc_url)
        .json(&body)
        .send()
        .await
        .map_err(|e| VerifyError::ChainRpc(format!("eth_call POST: {e}")))?;
    let v: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| VerifyError::ChainRpc(format!("eth_call json: {e}")))?;
    if let Some(err) = v.get("error") {
        return Err(VerifyError::ChainRpc(format!("rpc error: {err}")));
    }
    let result = v
        .get("result")
        .and_then(|r| r.as_str())
        .ok_or_else(|| VerifyError::ChainRpc("missing 'result'".into()))?;
    let in_scope = result
        .trim_start_matches("0x")
        .trim_start_matches('0')
        .chars()
        .last()
        == Some('1');
    if !in_scope {
        return Err(VerifyError::NotInScope);
    }
    Ok(())
}

fn parse_p256_pubkey_pem(pem: &str) -> Result<VerifyingKey, VerifyError> {
    use p256::pkcs8::DecodePublicKey;
    let pk = p256::PublicKey::from_public_key_pem(pem)
        .map_err(|e| VerifyError::BrokerKey(e.to_string()))?;
    Ok(VerifyingKey::from(pk))
}

fn function_selector(sig: &str) -> String {
    let mut h = sha3::Keccak256::new();
    h.update(sig.as_bytes());
    let d = h.finalize();
    hex::encode(&d[..4])
}

fn keccak_lc_service(name: &str) -> String {
    let mut h = sha3::Keccak256::new();
    h.update(name.to_lowercase().as_bytes());
    format!("0x{}", hex::encode(h.finalize()))
}

fn pad32(s: &str) -> Result<String, VerifyError> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    if stripped.len() != 64 {
        return Err(VerifyError::ChainRpc(format!(
            "expected 64-hex (32 bytes), got {} chars",
            stripped.len()
        )));
    }
    Ok(stripped.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cap_op_serializes_snake_case() {
        assert_eq!(serde_json::to_string(&CapOp::Store).unwrap(), "\"store\"");
        assert_eq!(serde_json::to_string(&CapOp::Fetch).unwrap(), "\"fetch\"");
        assert_eq!(serde_json::to_string(&CapOp::Teardown).unwrap(), "\"teardown\"");
    }

    #[test]
    fn function_selector_matches_known_signatures() {
        assert_eq!(function_selector("isServiceInScope(bytes32,bytes32,bytes32)"), "13337240");
    }

    #[test]
    fn keccak_service_lowercases() {
        assert_eq!(keccak_lc_service("OpenRouter"), keccak_lc_service("openrouter"));
    }

    #[test]
    fn pad32_accepts_with_or_without_0x() {
        assert_eq!(pad32(&format!("0x{}", "a".repeat(64))).unwrap(), "a".repeat(64));
        assert_eq!(pad32(&"b".repeat(64)).unwrap(), "b".repeat(64));
    }

    #[test]
    fn pad32_rejects_short() {
        assert!(pad32("0x123").is_err());
    }

    #[test]
    fn check_not_expired_rejects_past() {
        let token = CapToken {
            payload: CapPayload {
                operator_omni: format!("0x{}", "a".repeat(64)),
                actor_omni: format!("0x{}", "b".repeat(64)),
                service: "openrouter".into(),
                op: CapOp::Fetch,
                k3_epoch: 1,
                expires_at: 1, // way in the past
                nonce: "00".repeat(16),
            },
            broker_sig: "x".into(),
        };
        assert!(matches!(check_not_expired(&token), Err(VerifyError::Expired { .. })));
    }

    #[test]
    fn sign_then_verify_roundtrip_with_test_keypair() {
        // Generate a fresh keypair, sign a payload, verify the worker accepts it.
        use p256::ecdsa::{signature::Signer, SigningKey};
        use p256::pkcs8::EncodePublicKey;

        let signing_key = SigningKey::random(&mut rand_core::OsRng);
        let verify_key = signing_key.verifying_key();
        let pubkey_pem = p256::PublicKey::from(*verify_key)
            .to_public_key_pem(p256::pkcs8::LineEnding::LF)
            .unwrap();

        let payload = CapPayload {
            operator_omni: format!("0x{}", "a".repeat(64)),
            actor_omni: format!("0x{}", "b".repeat(64)),
            service: "openrouter".into(),
            op: CapOp::Store,
            k3_epoch: 1,
            expires_at: u64::MAX,
            nonce: "deadbeef".to_string() + &"0".repeat(24),
        };
        let canonical = serde_json::to_vec(&payload).unwrap();
        let mut h = Sha256::new();
        h.update(&canonical);
        let sig: p256::ecdsa::Signature = signing_key.sign(&h.finalize());
        let token = CapToken {
            payload,
            broker_sig: URL_SAFE_NO_PAD.encode(sig.to_bytes()),
        };

        verify_signature(&pubkey_pem, &token).unwrap();
        // Tampering should be detected:
        let mut bad = token.clone();
        bad.payload.service = "different".into();
        assert!(matches!(
            verify_signature(&pubkey_pem, &bad),
            Err(VerifyError::SigInvalid)
        ));
    }
}
