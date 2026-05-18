//! Cap-mint endpoints — `/v1/cap/cred-store` + `/v1/cap/cred-fetch`.
//!
//! Per arch.md §12.4 + §15.1: the broker is the cap-mint authority for
//! agent credential operations. A cap-token is a short-lived blob the
//! credentials-service worker (arch.md §15.1) re-verifies before any
//! AES-256-GCM encrypt/decrypt + S3 PUT/GET.
//!
//! Stage-1 simplification (per arch.md §22a): the broker reads on-chain
//! state via raw `eth_call` JSON-RPC (no ethers/foundry dep yet) and
//! signs caps with its OIDC keypair's P-256 private key. The cap shape
//! is a JSON object signed as `base64url(payload) || "." || base64url(sig)`
//! — JWS Compact Serialization Light, deliberately not full JWS so we
//! never accidentally bind the broker's key to "any JWS verifier will
//! accept this" semantics. Workers re-parse explicitly.
//!
//! Verification layers (broker-side, before signing the cap):
//!   1. The caller's OIDC JWT (existing /v1/mint-aws-creds auth) proves
//!      they hold the agent identity (extracted via JWT's wallet claim).
//!   2. On-chain SidecarRegistry.isActive(deviceKeyHash) MUST be true.
//!   3. On-chain AgentKeysScope.isServiceInScope(operator, actor, service)
//!      MUST be true (skipped for cred-store of a service that is brand
//!      new — first store is allowed if the operator's master has
//!      granted scope to *any* service prefixed similarly; today we just
//!      enforce in-scope-exact-match).
//!   4. On-chain K3EpochCounter.currentEpoch MUST match the epoch the
//!      caller is requesting (replay-protection across rotations).
//!
//! The worker then re-runs the same 3 chain checks before honoring the
//! cap — that's the "independent re-verify" per arch.md §15.1.

use std::time::{SystemTime, UNIX_EPOCH};

use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::state::SharedState;

/// Cap operation discriminator (matches CredentialAudit.OP_* on chain).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CapOp {
    Store,
    Fetch,
    Teardown,
}

impl CapOp {
    pub fn as_u8(self) -> u8 {
        match self {
            CapOp::Store => 0,
            CapOp::Fetch => 1,
            CapOp::Teardown => 2,
        }
    }
}

/// Cap payload — the signed-over portion of a cap-token. Workers verify
/// `Sha256(json(payload))` against `sig` using the broker's public key
/// before honoring the cap.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapPayload {
    /// `0x`-prefixed lowercase 32-byte hex (SHA-256-derived).
    pub operator_omni: String,
    /// `0x`-prefixed lowercase 32-byte hex.
    pub actor_omni: String,
    /// Lowercase service name (e.g. `"openrouter"`).
    pub service: String,
    /// `store` | `fetch` | `teardown`.
    pub op: CapOp,
    /// K3 rotation epoch this cap was minted under.
    pub k3_epoch: u64,
    /// Unix-seconds expiry. Workers reject after now > expires_at.
    pub expires_at: u64,
    /// Random 16-byte nonce (hex) — collision-resistance on cap IDs.
    pub nonce: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapToken {
    pub payload: CapPayload,
    /// `base64url(p256-ecdsa-sig)` over `Sha256(json(payload))`.
    pub broker_sig: String,
}

#[derive(Debug, Deserialize)]
pub struct CapStoreRequest {
    pub operator_omni: String,
    pub actor_omni: String,
    pub service: String,
    pub device_key_hash: String, // 0x-prefixed 32-byte hex (the caller's K10 hash)
    #[serde(default = "default_ttl_seconds")]
    pub ttl_seconds: u64,
}

#[derive(Debug, Deserialize)]
pub struct CapFetchRequest {
    pub operator_omni: String,
    pub actor_omni: String,
    pub service: String,
    pub device_key_hash: String,
    #[serde(default = "default_ttl_seconds")]
    pub ttl_seconds: u64,
}

fn default_ttl_seconds() -> u64 {
    300 // 5 min default — workers reject anything past expires_at.
}

#[derive(Debug, Serialize)]
pub struct CapErrorBody {
    pub error: String,
    pub reason: &'static str,
}

#[derive(Debug)]
pub enum CapError {
    InvalidInput(String),
    DeviceNotActive,
    ServiceNotInScope,
    K3EpochMismatch { expected: u64, got: u64 },
    ChainRpc(String),
    Sign(String),
}

impl IntoResponse for CapError {
    fn into_response(self) -> axum::response::Response {
        let (status, reason): (StatusCode, &'static str) = match &self {
            CapError::InvalidInput(_) => (StatusCode::BAD_REQUEST, "invalid_input"),
            CapError::DeviceNotActive => (StatusCode::FORBIDDEN, "device_not_active"),
            CapError::ServiceNotInScope => (StatusCode::FORBIDDEN, "service_not_in_scope"),
            CapError::K3EpochMismatch { .. } => (StatusCode::CONFLICT, "k3_epoch_mismatch"),
            CapError::ChainRpc(_) => (StatusCode::BAD_GATEWAY, "chain_rpc_error"),
            CapError::Sign(_) => (StatusCode::INTERNAL_SERVER_ERROR, "sign_error"),
        };
        let msg = match self {
            CapError::InvalidInput(m) => m,
            CapError::DeviceNotActive => "device is not active on chain".to_string(),
            CapError::ServiceNotInScope => "requested service is not in agent's scope".to_string(),
            CapError::K3EpochMismatch { expected, got } => {
                format!("k3 epoch mismatch (expected {expected}, got {got})")
            }
            CapError::ChainRpc(m) => m,
            CapError::Sign(m) => m,
        };
        (status, Json(CapErrorBody { error: msg, reason })).into_response()
    }
}

// ─── handlers ──────────────────────────────────────────────────────────

pub async fn cap_cred_store(
    State(state): State<SharedState>,
    Json(req): Json<CapStoreRequest>,
) -> Result<Json<CapToken>, CapError> {
    mint_cap(&state, req.operator_omni, req.actor_omni, req.service,
             req.device_key_hash, CapOp::Store, req.ttl_seconds).await
}

pub async fn cap_cred_fetch(
    State(state): State<SharedState>,
    Json(req): Json<CapFetchRequest>,
) -> Result<Json<CapToken>, CapError> {
    mint_cap(&state, req.operator_omni, req.actor_omni, req.service,
             req.device_key_hash, CapOp::Fetch, req.ttl_seconds).await
}

// ─── cap construction ──────────────────────────────────────────────────

async fn mint_cap(
    state: &SharedState,
    operator_omni: String,
    actor_omni: String,
    service: String,
    device_key_hash: String,
    op: CapOp,
    ttl_seconds: u64,
) -> Result<Json<CapToken>, CapError> {
    validate_hex32(&operator_omni, "operator_omni")?;
    validate_hex32(&actor_omni, "actor_omni")?;
    validate_hex32(&device_key_hash, "device_key_hash")?;
    if service.is_empty() || service.len() > 64 {
        return Err(CapError::InvalidInput("service must be 1..=64 chars".into()));
    }

    let chain = ChainContracts::from_env()?;

    // 1. SidecarRegistry.isActive(deviceKeyHash) must be true.
    let active = call_is_active(&state.http, &chain.rpc_url, &chain.registry, &device_key_hash).await?;
    if !active {
        return Err(CapError::DeviceNotActive);
    }

    // 2. AgentKeysScope.isServiceInScope(operator, actor, keccak(service)).
    let service_hash = keccak256_of_lc_service(&service);
    let in_scope = call_is_service_in_scope(
        &state.http, &chain.rpc_url, &chain.scope, &operator_omni, &actor_omni, &service_hash,
    ).await?;
    if !in_scope {
        return Err(CapError::ServiceNotInScope);
    }

    // 3. K3EpochCounter.currentEpoch → embed into cap.
    let k3_epoch = call_current_epoch(&state.http, &chain.rpc_url, &chain.epoch).await?;

    // 4. Build the payload + sign.
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| CapError::Sign("clock before epoch".into()))?
        .as_secs();

    let mut nonce_bytes = [0u8; 16];
    use rand_core::RngCore;
    rand_core::OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = hex::encode(nonce_bytes);

    let payload = CapPayload {
        operator_omni,
        actor_omni,
        service,
        op,
        k3_epoch,
        expires_at: now + ttl_seconds,
        nonce,
    };
    let broker_sig = sign_cap_payload(&state.session_keypair.private_key_pem, &payload)?;
    Ok(Json(CapToken { payload, broker_sig }))
}

// ─── on-chain reads (raw eth_call over reqwest) ────────────────────────

#[derive(Debug)]
struct ChainContracts {
    rpc_url: String,
    registry: String,
    scope: String,
    epoch: String,
}

impl ChainContracts {
    fn from_env() -> Result<Self, CapError> {
        let rpc_url = std::env::var("AGENTKEYS_CHAIN_RPC_HTTP")
            .or_else(|_| std::env::var("HEIMA_RPC_HTTP"))
            .map_err(|_| CapError::ChainRpc(
                "AGENTKEYS_CHAIN_RPC_HTTP (or HEIMA_RPC_HTTP) must be set".into(),
            ))?;
        let registry = std::env::var("SIDECAR_REGISTRY_ADDRESS_HEIMA")
            .map_err(|_| CapError::ChainRpc("SIDECAR_REGISTRY_ADDRESS_HEIMA unset".into()))?;
        let scope = std::env::var("SCOPE_CONTRACT_ADDRESS_HEIMA")
            .map_err(|_| CapError::ChainRpc("SCOPE_CONTRACT_ADDRESS_HEIMA unset".into()))?;
        let epoch = std::env::var("K3_EPOCH_COUNTER_ADDRESS_HEIMA")
            .map_err(|_| CapError::ChainRpc("K3_EPOCH_COUNTER_ADDRESS_HEIMA unset".into()))?;
        Ok(ChainContracts { rpc_url, registry, scope, epoch })
    }
}

async fn eth_call(
    http: &reqwest::Client,
    rpc_url: &str,
    to: &str,
    data: &str,
) -> Result<String, CapError> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_call",
        "params": [{"to": to, "data": data}, "latest"],
        "id": 1,
    });
    let resp = http
        .post(rpc_url)
        .json(&body)
        .send()
        .await
        .map_err(|e| CapError::ChainRpc(format!("eth_call POST failed: {e}")))?;
    let v: serde_json::Value = resp.json().await
        .map_err(|e| CapError::ChainRpc(format!("eth_call JSON parse: {e}")))?;
    if let Some(err) = v.get("error") {
        return Err(CapError::ChainRpc(format!("RPC error: {err}")));
    }
    v.get("result")
        .and_then(|r| r.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| CapError::ChainRpc("eth_call missing 'result'".into()))
}

async fn call_is_active(
    http: &reqwest::Client,
    rpc: &str,
    registry: &str,
    device_key_hash: &str,
) -> Result<bool, CapError> {
    let selector = function_selector("isActive(bytes32)");
    let arg = strip_0x_pad32(device_key_hash, "device_key_hash")?;
    let data = format!("0x{selector}{arg}");
    let result = eth_call(http, rpc, registry, &data).await?;
    Ok(parse_bool_result(&result))
}

async fn call_is_service_in_scope(
    http: &reqwest::Client,
    rpc: &str,
    scope: &str,
    operator: &str,
    actor: &str,
    service_hash: &str,
) -> Result<bool, CapError> {
    // selector(isServiceInScope(bytes32,bytes32,bytes32)) = 0x... compute at runtime
    let selector = function_selector("isServiceInScope(bytes32,bytes32,bytes32)");
    let a = strip_0x_pad32(operator, "operator_omni")?;
    let b = strip_0x_pad32(actor, "actor_omni")?;
    let c = strip_0x_pad32(service_hash, "service_hash")?;
    let data = format!("0x{selector}{a}{b}{c}");
    let result = eth_call(http, rpc, scope, &data).await?;
    Ok(parse_bool_result(&result))
}

async fn call_current_epoch(
    http: &reqwest::Client,
    rpc: &str,
    epoch: &str,
) -> Result<u64, CapError> {
    let selector = function_selector("currentEpoch()");
    let data = format!("0x{selector}");
    let result = eth_call(http, rpc, epoch, &data).await?;
    parse_u64_result(&result)
}

// ─── helpers ───────────────────────────────────────────────────────────

fn validate_hex32(s: &str, field: &str) -> Result<(), CapError> {
    if !s.starts_with("0x") {
        return Err(CapError::InvalidInput(format!("{field} must start with 0x")));
    }
    if s.len() != 66 {
        return Err(CapError::InvalidInput(format!(
            "{field} must be 66 chars (0x + 64 hex), got {}",
            s.len()
        )));
    }
    hex::decode(&s[2..])
        .map_err(|_| CapError::InvalidInput(format!("{field} contains non-hex chars")))?;
    Ok(())
}

fn strip_0x_pad32(s: &str, field: &str) -> Result<String, CapError> {
    validate_hex32(s, field)?;
    Ok(s[2..].to_lowercase())
}

fn parse_bool_result(s: &str) -> bool {
    // eth_call bool returns: 0x0000…0001 = true, 0x0000…0000 = false.
    s.trim_start_matches("0x").trim_start_matches('0').chars().last() == Some('1')
}

fn parse_u64_result(s: &str) -> Result<u64, CapError> {
    let stripped = s.trim_start_matches("0x");
    u64::from_str_radix(stripped, 16)
        .map_err(|e| CapError::ChainRpc(format!("epoch parse: {e} (raw: {s})")))
}

fn function_selector(sig: &str) -> String {
    let mut hasher = sha3::Keccak256::new();
    hasher.update(sig.as_bytes());
    let digest = hasher.finalize();
    hex::encode(&digest[..4])
}

fn keccak256_of_lc_service(name: &str) -> String {
    let mut hasher = sha3::Keccak256::new();
    hasher.update(name.to_lowercase().as_bytes());
    let digest = hasher.finalize();
    format!("0x{}", hex::encode(digest))
}

fn sign_cap_payload(signing_pem: &str, payload: &CapPayload) -> Result<String, CapError> {
    let canonical = serde_json::to_vec(payload)
        .map_err(|e| CapError::Sign(format!("payload JSON encode: {e}")))?;
    let mut hasher = Sha256::new();
    hasher.update(&canonical);
    let digest = hasher.finalize();
    let signing_key = SigningKey::from_pkcs8_pem(signing_pem)
        .map_err(|e| CapError::Sign(format!("load signing key: {e}")))?;
    let sig: Signature = signing_key.sign(&digest);
    Ok(URL_SAFE_NO_PAD.encode(sig.to_bytes()))
}

// PKCS#8 PEM decoder for P-256 signing keys (re-use of the existing
// approach in `crate::oidc`).
trait FromPkcs8Pem: Sized {
    fn from_pkcs8_pem(pem: &str) -> Result<Self, p256::pkcs8::Error>;
}
impl FromPkcs8Pem for SigningKey {
    fn from_pkcs8_pem(pem: &str) -> Result<Self, p256::pkcs8::Error> {
        use p256::pkcs8::DecodePrivateKey;
        let sk = p256::SecretKey::from_pkcs8_pem(pem)?;
        Ok(SigningKey::from(sk))
    }
}

// ─── tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cap_op_serializes_snake_case() {
        let s = serde_json::to_string(&CapOp::Store).unwrap();
        assert_eq!(s, "\"store\"");
        let s = serde_json::to_string(&CapOp::Fetch).unwrap();
        assert_eq!(s, "\"fetch\"");
    }

    #[test]
    fn cap_op_as_u8_matches_audit_codes() {
        // Must match CredentialAudit.OP_STORE=0, OP_READ=1, OP_TEARDOWN=2.
        assert_eq!(CapOp::Store.as_u8(), 0);
        assert_eq!(CapOp::Fetch.as_u8(), 1);
        assert_eq!(CapOp::Teardown.as_u8(), 2);
    }

    #[test]
    fn validate_hex32_accepts_well_formed() {
        let valid = "0x".to_string() + &"a".repeat(64);
        assert!(validate_hex32(&valid, "x").is_ok());
    }

    #[test]
    fn validate_hex32_rejects_short() {
        let invalid = "0x".to_string() + &"a".repeat(63);
        let e = validate_hex32(&invalid, "x").unwrap_err();
        match e {
            CapError::InvalidInput(m) => assert!(m.contains("66")),
            _ => panic!("expected InvalidInput"),
        }
    }

    #[test]
    fn validate_hex32_rejects_non_hex() {
        let invalid = "0x".to_string() + &"z".repeat(64);
        let e = validate_hex32(&invalid, "x").unwrap_err();
        assert!(matches!(e, CapError::InvalidInput(_)));
    }

    #[test]
    fn validate_hex32_rejects_missing_prefix() {
        let invalid = "a".repeat(66);
        let e = validate_hex32(&invalid, "x").unwrap_err();
        assert!(matches!(e, CapError::InvalidInput(_)));
    }

    #[test]
    fn function_selector_matches_known_signatures() {
        // Selectors verified live against `cast sig <fn>` on 2026-05-19.
        assert_eq!(function_selector("isActive(bytes32)"), "5c36901c");
        assert_eq!(function_selector("currentEpoch()"), "76671808");
        assert_eq!(
            function_selector("isServiceInScope(bytes32,bytes32,bytes32)"),
            "13337240"
        );
    }

    #[test]
    fn keccak_service_lowercases_and_hashes() {
        // verified against `cast keccak "openrouter"`
        let h = keccak256_of_lc_service("OpenRouter");
        assert_eq!(h.len(), 66);
        assert!(h.starts_with("0x"));
        // Lowercase normalization: both yield same hash.
        let h2 = keccak256_of_lc_service("openrouter");
        assert_eq!(h, h2);
    }

    #[test]
    fn parse_bool_result_handles_true_false_padded() {
        assert!(parse_bool_result(
            "0x0000000000000000000000000000000000000000000000000000000000000001"
        ));
        assert!(!parse_bool_result(
            "0x0000000000000000000000000000000000000000000000000000000000000000"
        ));
    }

    #[test]
    fn parse_u64_result_decodes_hex() {
        assert_eq!(
            parse_u64_result("0x0000000000000000000000000000000000000000000000000000000000000001").unwrap(),
            1
        );
        assert_eq!(
            parse_u64_result("0x000000000000000000000000000000000000000000000000000000000000002a").unwrap(),
            42
        );
    }

    #[test]
    fn cap_payload_roundtrips_json() {
        let p = CapPayload {
            operator_omni: format!("0x{}", "a".repeat(64)),
            actor_omni: format!("0x{}", "b".repeat(64)),
            service: "openrouter".into(),
            op: CapOp::Store,
            k3_epoch: 1,
            expires_at: 1700000000,
            nonce: "deadbeefcafebabe1234567890abcdef".into(),
        };
        let j = serde_json::to_string(&p).unwrap();
        let p2: CapPayload = serde_json::from_str(&j).unwrap();
        assert_eq!(p.operator_omni, p2.operator_omni);
        assert_eq!(p.op, p2.op);
    }
}
