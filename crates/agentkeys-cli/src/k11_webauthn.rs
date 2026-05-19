//! Real WebAuthn enrollment + assertion ceremony — `--webauthn` mode for
//! `agentkeys k11 enroll/assert`.
//!
//! Why a localhost HTTP server: the WebAuthn API (`navigator.credentials
//! .{create,get}`) is browser-only and demands an HTTPS / `http://localhost`
//! origin. We bind a one-shot axum server on `http://localhost:<random>`,
//! open the operator's default browser at it, and the page runs the
//! ceremony. The result is POSTed back to the server; the CLI prints it
//! and exits.
//!
//! Why manual instead of `webauthn-rs`: we need the WebAuthn challenge to
//! equal `sha256(application_message)` for the assert path so the resulting
//! assertion is bound to a specific cap-mint / scope-mutation payload.
//! `webauthn-rs`'s high-level passkey API generates its own random
//! challenge and doesn't expose a public hook to inject ours. Going
//! manual is ~300 LOC and gives us full control over the challenge,
//! signature-over-bytes layout, and storage format.
//!
//! Platform authenticator binding: the JS forces
//! `authenticatorSelection.authenticatorAttachment = "platform"` +
//! `userVerification = "required"`, which on macOS triggers the Touch ID
//! prompt against the Secure Enclave-resident platform passkey. No
//! roaming authenticator (YubiKey) is accepted in this mode — that's a
//! stage-2 multi-authenticator concern.
//!
//! Stage 1 limitation: we DON'T verify the attestation statement (no
//! vendor metadata service hookup). For platform authenticators this is
//! normally acceptable because the attestation type is `none` or `self`
//! by default. The fix would be to wire in `webauthn-rs` for the
//! enrollment path while keeping the manual signed-message assert path.
//! Tracked alongside #90.

use std::fs;
use std::io::Cursor;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use axum::{extract::State, http::StatusCode, response::Html, response::IntoResponse, routing::{get, post}, Json, Router};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};
use p256::elliptic_curve::sec1::FromEncodedPoint;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::oneshot;

const CEREMONY_TIMEOUT_SECS: u64 = 300;

#[derive(Debug, thiserror::Error)]
pub enum WebauthnError {
    #[error("io: {0}")]
    Io(String),
    #[error("bind localhost: {0}")]
    Bind(String),
    #[error("open browser: {0}")]
    BrowserOpen(String),
    #[error("ceremony timed out after {0}s")]
    Timeout(u64),
    #[error("browser POST'd invalid data: {0}")]
    BadPost(String),
    #[error("challenge mismatch: expected {expected}, got {got}")]
    ChallengeMismatch { expected: String, got: String },
    #[error("type mismatch: expected {expected}, got {got}")]
    TypeMismatch { expected: &'static str, got: String },
    #[error("origin mismatch: expected {expected}, got {got}")]
    OriginMismatch { expected: String, got: String },
    #[error("CBOR decode: {0}")]
    Cbor(String),
    #[error("missing required CBOR field: {0}")]
    MissingField(&'static str),
    #[error("invalid COSE pubkey: {0}")]
    InvalidCosePubkey(String),
    #[error("signature parse: {0}")]
    SigParse(String),
    #[error("signature verify failed")]
    SigInvalid,
    #[error("serde_json: {0}")]
    SerdeJson(String),
    #[error("base64 decode: {0}")]
    B64Decode(String),
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct WebauthnEnrollment {
    pub operator_omni: String,
    /// `base64url(raw credential id bytes)` — what the browser returns for `id`.
    pub credential_id_b64url: String,
    /// `0x` + 65 hex chars (130 chars) — raw uncompressed P-256 point (`0x04 || X || Y`).
    pub cose_pubkey_hex: String,
    pub enrolled_at_unix: u64,
    /// `"webauthn"` (NOT `"stage1-stub"`).
    pub mode: String,
}

#[derive(Debug, Clone, Serialize)]
struct ServerCtx {
    rp_id: String,
    rp_origin: String,
    operator_omni: String,
    /// `base64url(challenge_bytes)` for the browser-side script.
    challenge_b64url: String,
    /// For assert flows: the previously-enrolled credential id (base64url).
    allow_credential_b64url: Option<String>,
    /// For assert flows: the message bytes hex-encoded (display-only).
    message_hex: Option<String>,
}

#[derive(Debug, Deserialize)]
struct EnrollPost {
    /// `base64url(raw credential id bytes)`
    id: String,
    /// `base64url(clientDataJSON)`
    client_data_json: String,
    /// `base64url(attestationObject)`
    attestation_object: String,
}

#[derive(Debug, Deserialize)]
struct AssertPost {
    /// `base64url(raw credential id bytes)`
    id: String,
    /// `base64url(clientDataJSON)`
    client_data_json: String,
    /// `base64url(authenticatorData)`
    authenticator_data: String,
    /// `base64url(signature DER)`
    signature: String,
}

#[derive(Debug, Deserialize)]
struct ClientDataJson {
    #[serde(rename = "type")]
    ty: String,
    challenge: String,
    origin: String,
}

pub fn enrollment_path(operator_omni: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home)
        .join(".agentkeys")
        .join("k11")
        .join(format!("{}.json", operator_omni.trim_start_matches("0x")))
}

/// Run the enrollment ceremony. Blocks until the browser POSTs back or
/// the 5-minute timeout fires. Persists the result to
/// `~/.agentkeys/k11/<omni>.json` (mode 0600).
pub fn enroll_webauthn(operator_omni: &str) -> Result<WebauthnEnrollment, WebauthnError> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| WebauthnError::Io(e.to_string()))?;
    rt.block_on(async { enroll_webauthn_async(operator_omni).await })
}

/// Run the assert ceremony. Returns the assertion bytes
/// (`authenticatorData || clientDataJSON || signature`).
pub fn assert_webauthn(
    operator_omni: &str,
    message: &[u8],
) -> Result<Vec<u8>, WebauthnError> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| WebauthnError::Io(e.to_string()))?;
    rt.block_on(async { assert_webauthn_async(operator_omni, message).await })
}

async fn enroll_webauthn_async(operator_omni: &str) -> Result<WebauthnEnrollment, WebauthnError> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| WebauthnError::Bind(e.to_string()))?;
    let local_addr = listener.local_addr().map_err(|e| WebauthnError::Bind(e.to_string()))?;
    let port = local_addr.port();
    let rp_origin = format!("http://localhost:{port}");

    let mut challenge_bytes = [0u8; 32];
    use rand_core::RngCore;
    rand_core::OsRng.fill_bytes(&mut challenge_bytes);
    let challenge_b64url = URL_SAFE_NO_PAD.encode(challenge_bytes);

    let ctx = Arc::new(ServerCtx {
        rp_id: "localhost".to_string(),
        rp_origin: rp_origin.clone(),
        operator_omni: operator_omni.to_string(),
        challenge_b64url: challenge_b64url.clone(),
        allow_credential_b64url: None,
        message_hex: None,
    });

    let (tx, rx) = oneshot::channel::<EnrollPost>();
    let tx = Arc::new(tokio::sync::Mutex::new(Some(tx)));

    let app = Router::new()
        .route("/", get(serve_enroll_page))
        .route("/finish", post({
            let tx = tx.clone();
            move |State(ctx): State<Arc<ServerCtx>>, Json(body): Json<EnrollPost>| {
                let tx = tx.clone();
                async move {
                    let _ = ctx; // suppress unused warning; ctx is for parity with assert handler
                    if let Some(sender) = tx.lock().await.take() {
                        let _ = sender.send(body);
                    }
                    (StatusCode::OK, "ok")
                }
            }
        }))
        .with_state(ctx.clone());

    let server_task = tokio::spawn(async move {
        axum::serve(listener, app).await
    });

    // Open the default browser (macOS: `open`; Linux: `xdg-open`; Windows: `start`).
    open_in_browser(&rp_origin)?;

    eprintln!(
        "==> waiting for WebAuthn enrollment in browser at {rp_origin}\n\
        ==> macOS Touch ID prompt should appear in your browser…\n\
        ==> timing out after {CEREMONY_TIMEOUT_SECS}s"
    );

    let post = tokio::time::timeout(Duration::from_secs(CEREMONY_TIMEOUT_SECS), rx)
        .await
        .map_err(|_| WebauthnError::Timeout(CEREMONY_TIMEOUT_SECS))?
        .map_err(|e| WebauthnError::Io(format!("oneshot recv: {e}")))?;
    server_task.abort();

    let enrollment = finalize_enroll(operator_omni, &challenge_b64url, &rp_origin, &post)?;
    persist_enrollment(&enrollment)?;
    Ok(enrollment)
}

async fn assert_webauthn_async(
    operator_omni: &str,
    message: &[u8],
) -> Result<Vec<u8>, WebauthnError> {
    // Load the previously-enrolled credential.
    let enrollment = load_enrollment(operator_omni)?;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| WebauthnError::Bind(e.to_string()))?;
    let port = listener.local_addr().map_err(|e| WebauthnError::Bind(e.to_string()))?.port();
    let rp_origin = format!("http://localhost:{port}");

    // WebAuthn challenge = sha256(application message). The browser signs
    // over (authenticatorData || sha256(clientDataJSON)) and clientDataJSON
    // includes this challenge — so the resulting signature binds to our
    // application message.
    let mut h = Sha256::new();
    h.update(message);
    let challenge_bytes = h.finalize();
    let challenge_b64url = URL_SAFE_NO_PAD.encode(challenge_bytes);

    let ctx = Arc::new(ServerCtx {
        rp_id: "localhost".to_string(),
        rp_origin: rp_origin.clone(),
        operator_omni: operator_omni.to_string(),
        challenge_b64url: challenge_b64url.clone(),
        allow_credential_b64url: Some(enrollment.credential_id_b64url.clone()),
        message_hex: Some(hex::encode(message)),
    });

    let (tx, rx) = oneshot::channel::<AssertPost>();
    let tx = Arc::new(tokio::sync::Mutex::new(Some(tx)));

    let app = Router::new()
        .route("/", get(serve_assert_page))
        .route("/finish", post({
            let tx = tx.clone();
            move |State(ctx): State<Arc<ServerCtx>>, Json(body): Json<AssertPost>| {
                let tx = tx.clone();
                async move {
                    let _ = ctx;
                    if let Some(sender) = tx.lock().await.take() {
                        let _ = sender.send(body);
                    }
                    (StatusCode::OK, "ok")
                }
            }
        }))
        .with_state(ctx.clone());

    let server_task = tokio::spawn(async move {
        axum::serve(listener, app).await
    });

    open_in_browser(&rp_origin)?;

    eprintln!(
        "==> waiting for WebAuthn assertion in browser at {rp_origin}\n\
        ==> macOS Touch ID prompt should appear in your browser…\n\
        ==> signing over message hash 0x{}\n\
        ==> timing out after {CEREMONY_TIMEOUT_SECS}s",
        hex::encode(challenge_bytes)
    );

    let post = tokio::time::timeout(Duration::from_secs(CEREMONY_TIMEOUT_SECS), rx)
        .await
        .map_err(|_| WebauthnError::Timeout(CEREMONY_TIMEOUT_SECS))?
        .map_err(|e| WebauthnError::Io(format!("oneshot recv: {e}")))?;
    server_task.abort();

    finalize_assert(&enrollment, &challenge_b64url, &rp_origin, &post)
}

fn open_in_browser(url: &str) -> Result<(), WebauthnError> {
    let cmd = if cfg!(target_os = "macos") {
        "open"
    } else if cfg!(target_os = "windows") {
        "start"
    } else {
        "xdg-open"
    };
    std::process::Command::new(cmd)
        .arg(url)
        .spawn()
        .map_err(|e| WebauthnError::BrowserOpen(format!("{cmd} {url}: {e}")))?;
    Ok(())
}

fn finalize_enroll(
    operator_omni: &str,
    expected_challenge: &str,
    expected_origin: &str,
    post: &EnrollPost,
) -> Result<WebauthnEnrollment, WebauthnError> {
    let client_data_bytes = URL_SAFE_NO_PAD
        .decode(&post.client_data_json)
        .map_err(|e| WebauthnError::B64Decode(format!("clientDataJSON: {e}")))?;
    let cd: ClientDataJson = serde_json::from_slice(&client_data_bytes)
        .map_err(|e| WebauthnError::SerdeJson(format!("clientDataJSON: {e}")))?;
    if cd.ty != "webauthn.create" {
        return Err(WebauthnError::TypeMismatch { expected: "webauthn.create", got: cd.ty });
    }
    if cd.challenge != expected_challenge {
        return Err(WebauthnError::ChallengeMismatch {
            expected: expected_challenge.to_string(),
            got: cd.challenge,
        });
    }
    if cd.origin != expected_origin {
        return Err(WebauthnError::OriginMismatch {
            expected: expected_origin.to_string(),
            got: cd.origin,
        });
    }

    let attestation_bytes = URL_SAFE_NO_PAD
        .decode(&post.attestation_object)
        .map_err(|e| WebauthnError::B64Decode(format!("attestationObject: {e}")))?;
    let cose_pubkey = extract_cose_pubkey_from_attestation(&attestation_bytes)?;

    Ok(WebauthnEnrollment {
        operator_omni: operator_omni.to_string(),
        credential_id_b64url: post.id.clone(),
        cose_pubkey_hex: format!("0x{}", hex::encode(&cose_pubkey)),
        enrolled_at_unix: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
        mode: "webauthn".to_string(),
    })
}

fn finalize_assert(
    enrollment: &WebauthnEnrollment,
    expected_challenge: &str,
    expected_origin: &str,
    post: &AssertPost,
) -> Result<Vec<u8>, WebauthnError> {
    let client_data_bytes = URL_SAFE_NO_PAD
        .decode(&post.client_data_json)
        .map_err(|e| WebauthnError::B64Decode(format!("clientDataJSON: {e}")))?;
    let cd: ClientDataJson = serde_json::from_slice(&client_data_bytes)
        .map_err(|e| WebauthnError::SerdeJson(format!("clientDataJSON: {e}")))?;
    if cd.ty != "webauthn.get" {
        return Err(WebauthnError::TypeMismatch { expected: "webauthn.get", got: cd.ty });
    }
    if cd.challenge != expected_challenge {
        return Err(WebauthnError::ChallengeMismatch {
            expected: expected_challenge.to_string(),
            got: cd.challenge,
        });
    }
    if cd.origin != expected_origin {
        return Err(WebauthnError::OriginMismatch {
            expected: expected_origin.to_string(),
            got: cd.origin,
        });
    }

    let authenticator_data = URL_SAFE_NO_PAD
        .decode(&post.authenticator_data)
        .map_err(|e| WebauthnError::B64Decode(format!("authenticatorData: {e}")))?;
    let signature_der = URL_SAFE_NO_PAD
        .decode(&post.signature)
        .map_err(|e| WebauthnError::B64Decode(format!("signature: {e}")))?;

    // Verify the signature: signed-bytes = authenticatorData || sha256(clientDataJSON)
    let mut h = Sha256::new();
    h.update(&client_data_bytes);
    let cd_hash = h.finalize();
    let mut signed = Vec::with_capacity(authenticator_data.len() + cd_hash.len());
    signed.extend_from_slice(&authenticator_data);
    signed.extend_from_slice(&cd_hash);

    let mut h2 = Sha256::new();
    h2.update(&signed);
    let digest = h2.finalize();

    let pubkey_hex = enrollment.cose_pubkey_hex.trim_start_matches("0x");
    let pubkey_bytes = hex::decode(pubkey_hex)
        .map_err(|e| WebauthnError::InvalidCosePubkey(format!("hex: {e}")))?;
    let encoded_point = p256::EncodedPoint::from_bytes(&pubkey_bytes)
        .map_err(|e| WebauthnError::InvalidCosePubkey(e.to_string()))?;
    let pubkey = p256::PublicKey::from_encoded_point(&encoded_point);
    let pubkey = if pubkey.is_some().into() {
        pubkey.unwrap()
    } else {
        return Err(WebauthnError::InvalidCosePubkey("not on curve".into()));
    };
    let verifying_key = VerifyingKey::from(pubkey);

    let sig = Signature::from_der(&signature_der)
        .map_err(|e| WebauthnError::SigParse(e.to_string()))?;
    verifying_key
        .verify(&digest, &sig)
        .map_err(|_| WebauthnError::SigInvalid)?;

    // Return the WebAuthn assertion in its canonical transport shape:
    // authenticatorData || clientDataJSON || signature
    let mut out = Vec::with_capacity(authenticator_data.len() + client_data_bytes.len() + signature_der.len());
    out.extend_from_slice(&authenticator_data);
    out.extend_from_slice(&client_data_bytes);
    out.extend_from_slice(&signature_der);
    Ok(out)
}

/// Walk the attestationObject CBOR, return the raw uncompressed P-256
/// pubkey (`0x04 || X || Y`, 65 bytes) extracted from the embedded
/// authData's attestedCredentialData.
fn extract_cose_pubkey_from_attestation(att_obj_bytes: &[u8]) -> Result<Vec<u8>, WebauthnError> {
    // attestationObject is CBOR: { "fmt": str, "attStmt": map, "authData": bytes }
    let value: ciborium::Value = ciborium::from_reader(Cursor::new(att_obj_bytes))
        .map_err(|e| WebauthnError::Cbor(format!("attestationObject root: {e}")))?;
    let map = value.as_map().ok_or(WebauthnError::MissingField("attestationObject not a map"))?;
    let auth_data_bytes = map
        .iter()
        .find(|(k, _)| k.as_text() == Some("authData"))
        .and_then(|(_, v)| v.as_bytes())
        .ok_or(WebauthnError::MissingField("authData"))?;

    // authData layout (per WebAuthn spec):
    //   rpIdHash       (32 bytes)
    //   flags          (1 byte)
    //   signCount      (4 bytes)
    //   attestedCredentialData {
    //     aaguid       (16 bytes)
    //     credentialIdLength (2 bytes, big-endian)
    //     credentialId (credentialIdLength bytes)
    //     credentialPublicKey (CBOR-encoded COSEKey, variable length)
    //   }
    if auth_data_bytes.len() < 37 + 16 + 2 {
        return Err(WebauthnError::Cbor(format!(
            "authData too short ({} bytes; need ≥ 55 for attestedCredentialData)",
            auth_data_bytes.len()
        )));
    }
    let cred_id_len = u16::from_be_bytes([auth_data_bytes[53], auth_data_bytes[54]]) as usize;
    let cose_start = 55 + cred_id_len;
    if auth_data_bytes.len() <= cose_start {
        return Err(WebauthnError::Cbor("authData missing credentialPublicKey".into()));
    }
    let cose_bytes = &auth_data_bytes[cose_start..];
    let cose: ciborium::Value = ciborium::from_reader(Cursor::new(cose_bytes))
        .map_err(|e| WebauthnError::Cbor(format!("COSE pubkey: {e}")))?;
    let cose_map = cose.as_map().ok_or(WebauthnError::MissingField("COSE pubkey not a map"))?;
    // COSE labels: -2 = x, -3 = y (for EC2 keys). 1 = kty (should be 2 = EC2). 3 = alg (should be -7 = ES256).
    let mut x: Option<Vec<u8>> = None;
    let mut y: Option<Vec<u8>> = None;
    for (k, v) in cose_map {
        if let Some(i) = k.as_integer() {
            // ciborium 0.2 `Integer` is Clone but NOT Copy; can't `*i`.
            // Clone-then-try_from is the supported path.
            let lab: i128 = match i128::try_from(i.clone()) {
                Ok(n) => n,
                Err(_) => continue,
            };
            match lab {
                -2 => x = v.as_bytes().cloned(),
                -3 => y = v.as_bytes().cloned(),
                _ => {}
            }
        }
    }
    let x = x.ok_or(WebauthnError::MissingField("COSE pubkey x"))?;
    let y = y.ok_or(WebauthnError::MissingField("COSE pubkey y"))?;
    if x.len() != 32 || y.len() != 32 {
        return Err(WebauthnError::InvalidCosePubkey(format!(
            "expected 32-byte X+Y, got {}+{}",
            x.len(),
            y.len()
        )));
    }
    let mut uncompressed = Vec::with_capacity(65);
    uncompressed.push(0x04);
    uncompressed.extend_from_slice(&x);
    uncompressed.extend_from_slice(&y);
    Ok(uncompressed)
}

pub fn persist_enrollment(enrollment: &WebauthnEnrollment) -> Result<(), WebauthnError> {
    let path = enrollment_path(&enrollment.operator_omni);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| WebauthnError::Io(e.to_string()))?;
    }
    let json = serde_json::to_vec_pretty(enrollment)
        .map_err(|e| WebauthnError::SerdeJson(e.to_string()))?;
    fs::write(&path, json).map_err(|e| WebauthnError::Io(e.to_string()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&path)
            .map_err(|e| WebauthnError::Io(e.to_string()))?
            .permissions();
        perms.set_mode(0o600);
        fs::set_permissions(&path, perms).map_err(|e| WebauthnError::Io(e.to_string()))?;
    }
    Ok(())
}

pub fn load_enrollment(operator_omni: &str) -> Result<WebauthnEnrollment, WebauthnError> {
    let path = enrollment_path(operator_omni);
    let bytes = fs::read(&path).map_err(|e| WebauthnError::Io(format!("read {path:?}: {e}")))?;
    let enrollment: WebauthnEnrollment = serde_json::from_slice(&bytes)
        .map_err(|e| WebauthnError::SerdeJson(format!("parse {path:?}: {e}")))?;
    if enrollment.mode != "webauthn" {
        return Err(WebauthnError::Io(format!(
            "stored enrollment at {path:?} is mode={:?} not 'webauthn' — re-enroll with --webauthn first",
            enrollment.mode
        )));
    }
    Ok(enrollment)
}

// ─── HTML handlers (one-shot ceremony pages) ──────────────────────────

async fn serve_enroll_page(State(ctx): State<Arc<ServerCtx>>) -> impl IntoResponse {
    let html = format!(
        r##"<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>AgentKeys K11 Enrollment</title>
<style>body{{font-family:system-ui;padding:2em;max-width:600px}}.ok{{color:green}}.err{{color:red}}</style>
</head><body>
<h1>AgentKeys — K11 enrollment</h1>
<p>Operator: <code>{omni}</code></p>
<p id="status">Press the button to start enrollment. Touch ID will prompt.</p>
<button id="go" style="padding:1em;font-size:1.2em">Start enrollment</button>
<script>
const challenge = "{challenge}";
const omni = "{omni}";
function b64urlDecode(s) {{
  s = s.replace(/-/g,'+').replace(/_/g,'/');
  while (s.length % 4) s += '=';
  return Uint8Array.from(atob(s), c => c.charCodeAt(0));
}}
function b64urlEncode(buf) {{
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}}
document.getElementById('go').onclick = async () => {{
  const status = document.getElementById('status');
  try {{
    const cred = await navigator.credentials.create({{
      publicKey: {{
        rp: {{ id: "localhost", name: "AgentKeys" }},
        user: {{
          id: new TextEncoder().encode(omni),
          name: omni,
          displayName: "agentkeys-master"
        }},
        challenge: b64urlDecode(challenge),
        pubKeyCredParams: [{{ alg: -7, type: "public-key" }}],
        authenticatorSelection: {{
          authenticatorAttachment: "platform",
          userVerification: "required",
          residentKey: "preferred"
        }},
        timeout: 60000,
        attestation: "none"
      }}
    }});
    const resp = cred.response;
    const payload = {{
      id: cred.id,
      client_data_json: b64urlEncode(resp.clientDataJSON),
      attestation_object: b64urlEncode(resp.attestationObject)
    }};
    const r = await fetch("/finish", {{
      method: "POST",
      headers: {{ "Content-Type": "application/json" }},
      body: JSON.stringify(payload)
    }});
    if (r.ok) {{
      status.innerHTML = '<span class="ok">✓ Enrollment complete. You can close this tab.</span>';
    }} else {{
      status.innerHTML = '<span class="err">✗ Server rejected: ' + r.status + '</span>';
    }}
  }} catch (e) {{
    status.innerHTML = '<span class="err">✗ ' + e.message + '</span>';
  }}
}};
</script>
</body></html>"##,
        omni = ctx.operator_omni,
        challenge = ctx.challenge_b64url,
    );
    Html(html)
}

async fn serve_assert_page(State(ctx): State<Arc<ServerCtx>>) -> impl IntoResponse {
    let cred_id = ctx.allow_credential_b64url.as_deref().unwrap_or("");
    let msg_hex = ctx.message_hex.as_deref().unwrap_or("");
    let html = format!(
        r##"<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>AgentKeys K11 Assertion</title>
<style>body{{font-family:system-ui;padding:2em;max-width:600px}}.ok{{color:green}}.err{{color:red}}code{{word-break:break-all}}</style>
</head><body>
<h1>AgentKeys — K11 assertion</h1>
<p>Operator: <code>{omni}</code></p>
<p>Signing over message: <code>0x{msg}</code></p>
<p id="status">Press the button to sign. Touch ID will prompt.</p>
<button id="go" style="padding:1em;font-size:1.2em">Sign</button>
<script>
const challenge = "{challenge}";
const credId = "{cred_id}";
function b64urlDecode(s) {{
  s = s.replace(/-/g,'+').replace(/_/g,'/');
  while (s.length % 4) s += '=';
  return Uint8Array.from(atob(s), c => c.charCodeAt(0));
}}
function b64urlEncode(buf) {{
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}}
document.getElementById('go').onclick = async () => {{
  const status = document.getElementById('status');
  try {{
    const cred = await navigator.credentials.get({{
      publicKey: {{
        rpId: "localhost",
        challenge: b64urlDecode(challenge),
        allowCredentials: [{{ id: b64urlDecode(credId), type: "public-key" }}],
        userVerification: "required",
        timeout: 60000
      }}
    }});
    const resp = cred.response;
    const payload = {{
      id: cred.id,
      client_data_json: b64urlEncode(resp.clientDataJSON),
      authenticator_data: b64urlEncode(resp.authenticatorData),
      signature: b64urlEncode(resp.signature)
    }};
    const r = await fetch("/finish", {{
      method: "POST",
      headers: {{ "Content-Type": "application/json" }},
      body: JSON.stringify(payload)
    }});
    if (r.ok) {{
      status.innerHTML = '<span class="ok">✓ Assertion complete. You can close this tab.</span>';
    }} else {{
      status.innerHTML = '<span class="err">✗ Server rejected: ' + r.status + '</span>';
    }}
  }} catch (e) {{
    status.innerHTML = '<span class="err">✗ ' + e.message + '</span>';
  }}
}};
</script>
</body></html>"##,
        omni = ctx.operator_omni,
        challenge = ctx.challenge_b64url,
        cred_id = cred_id,
        msg = msg_hex,
    );
    Html(html)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enrollment_path_uses_strip_0x() {
        let path = enrollment_path(&format!("0x{}", "a".repeat(64)));
        assert!(path.to_string_lossy().contains(&"a".repeat(64)));
        assert!(!path.to_string_lossy().contains("0xa"));
    }

    #[test]
    fn finalize_enroll_rejects_wrong_challenge() {
        let post = EnrollPost {
            id: "fake-id".into(),
            // {"type":"webauthn.create","challenge":"BAD","origin":"http://localhost:1234"} base64url
            client_data_json: URL_SAFE_NO_PAD.encode(
                br#"{"type":"webauthn.create","challenge":"BAD","origin":"http://localhost:1234"}"#,
            ),
            attestation_object: URL_SAFE_NO_PAD.encode(&[0xa0u8]), // empty CBOR map; we won't reach the parser
        };
        let err = finalize_enroll("0xabc", "GOOD", "http://localhost:1234", &post).unwrap_err();
        assert!(matches!(err, WebauthnError::ChallengeMismatch { .. }));
    }

    #[test]
    fn finalize_enroll_rejects_wrong_type() {
        let post = EnrollPost {
            id: "fake-id".into(),
            client_data_json: URL_SAFE_NO_PAD.encode(
                br#"{"type":"webauthn.get","challenge":"GOOD","origin":"http://localhost:1234"}"#,
            ),
            attestation_object: URL_SAFE_NO_PAD.encode(&[0xa0u8]),
        };
        let err = finalize_enroll("0xabc", "GOOD", "http://localhost:1234", &post).unwrap_err();
        assert!(matches!(err, WebauthnError::TypeMismatch { .. }));
    }

    #[test]
    fn finalize_enroll_rejects_wrong_origin() {
        let post = EnrollPost {
            id: "fake-id".into(),
            client_data_json: URL_SAFE_NO_PAD.encode(
                br#"{"type":"webauthn.create","challenge":"GOOD","origin":"http://evil:1234"}"#,
            ),
            attestation_object: URL_SAFE_NO_PAD.encode(&[0xa0u8]),
        };
        let err = finalize_enroll("0xabc", "GOOD", "http://localhost:1234", &post).unwrap_err();
        assert!(matches!(err, WebauthnError::OriginMismatch { .. }));
    }
}
