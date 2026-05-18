//! AES-256-GCM envelope v2 — matches the shape produced by
//! agentkeys-core/src/s3_backend.rs (the CLI's stage-1 bridge).
//!
//! Envelope layout (binary):
//!   version (1 byte = 0x02)
//!   nonce   (12 bytes)
//!   ciphertext || auth_tag (16 bytes appended by AES-GCM)
//!
//! AAD = sha256(operator_omni || actor_omni || service || k3_epoch_be).
//! Both stage-1 CLI and stage-2 worker MUST produce identical bytes for
//! the same inputs; otherwise the worker can't read what the CLI wrote.

use aes_gcm::aead::{Aead, AeadCore, KeyInit, OsRng, Payload};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use sha2::{Digest, Sha256};
use thiserror::Error;

pub const ENVELOPE_VERSION_V2: u8 = 0x02;
pub const NONCE_LEN: usize = 12;
pub const KEY_LEN: usize = 32;

#[derive(Debug, Error)]
pub enum EnvelopeError {
    #[error("invalid KEK hex: {0}")]
    InvalidKekHex(String),
    #[error("encryption failed: {0}")]
    Encrypt(String),
    #[error("decryption failed: {0}")]
    Decrypt(String),
    #[error("envelope too short ({0} bytes)")]
    Truncated(usize),
    #[error("unsupported envelope version 0x{0:02x}")]
    UnsupportedVersion(u8),
}

/// Compute the AAD per the v2 envelope contract.
pub fn aad(operator_omni: &str, actor_omni: &str, service: &str, k3_epoch: u64) -> Vec<u8> {
    let mut h = Sha256::new();
    h.update(strip_0x(operator_omni).as_bytes());
    h.update(strip_0x(actor_omni).as_bytes());
    h.update(service.to_lowercase().as_bytes());
    h.update(k3_epoch.to_be_bytes());
    h.finalize().to_vec()
}

fn strip_0x(s: &str) -> &str {
    s.strip_prefix("0x").unwrap_or(s)
}

pub fn encrypt(
    kek_hex: &str,
    plaintext: &[u8],
    aad_bytes: &[u8],
) -> Result<Vec<u8>, EnvelopeError> {
    let kek = decode_kek(kek_hex)?;
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&kek));
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
    let ct = cipher
        .encrypt(&nonce, Payload { msg: plaintext, aad: aad_bytes })
        .map_err(|e| EnvelopeError::Encrypt(e.to_string()))?;
    let mut out = Vec::with_capacity(1 + NONCE_LEN + ct.len());
    out.push(ENVELOPE_VERSION_V2);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    Ok(out)
}

pub fn decrypt(
    kek_hex: &str,
    envelope: &[u8],
    aad_bytes: &[u8],
) -> Result<Vec<u8>, EnvelopeError> {
    if envelope.len() < 1 + NONCE_LEN + 16 {
        return Err(EnvelopeError::Truncated(envelope.len()));
    }
    if envelope[0] != ENVELOPE_VERSION_V2 {
        return Err(EnvelopeError::UnsupportedVersion(envelope[0]));
    }
    let kek = decode_kek(kek_hex)?;
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&kek));
    let nonce = Nonce::from_slice(&envelope[1..1 + NONCE_LEN]);
    let ct = &envelope[1 + NONCE_LEN..];
    cipher
        .decrypt(nonce, Payload { msg: ct, aad: aad_bytes })
        .map_err(|e| EnvelopeError::Decrypt(e.to_string()))
}

fn decode_kek(kek_hex: &str) -> Result<[u8; KEY_LEN], EnvelopeError> {
    let bytes = hex::decode(kek_hex.trim_start_matches("0x"))
        .map_err(|e| EnvelopeError::InvalidKekHex(e.to_string()))?;
    if bytes.len() != KEY_LEN {
        return Err(EnvelopeError::InvalidKekHex(format!(
            "expected {KEY_LEN} bytes, got {}",
            bytes.len()
        )));
    }
    let mut out = [0u8; KEY_LEN];
    out.copy_from_slice(&bytes);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_under_known_kek() {
        let kek = "a".repeat(64);
        let aad = aad("0xabc", "0xdef", "openrouter", 1);
        let pt = b"sk-or-v1-EXAMPLE-SECRET";
        let env = encrypt(&kek, pt, &aad).unwrap();
        let recovered = decrypt(&kek, &env, &aad).unwrap();
        assert_eq!(recovered, pt);
    }

    #[test]
    fn detects_aad_tamper() {
        let kek = "b".repeat(64);
        let aad1 = aad("0x1", "0x2", "s", 1);
        let aad2 = aad("0x1", "0x2", "s", 2);
        let env = encrypt(&kek, b"x", &aad1).unwrap();
        let res = decrypt(&kek, &env, &aad2);
        assert!(res.is_err(), "AAD tamper must fail decrypt");
    }

    #[test]
    fn detects_version_drift() {
        let kek = "c".repeat(64);
        let aad = aad("0x1", "0x2", "s", 1);
        let mut env = encrypt(&kek, b"x", &aad).unwrap();
        env[0] = 0x01; // legacy v1 — worker rejects
        let res = decrypt(&kek, &env, &aad);
        assert!(matches!(res, Err(EnvelopeError::UnsupportedVersion(0x01))));
    }

    #[test]
    fn rejects_short_envelope() {
        let res = decrypt(&"d".repeat(64), &[0x02, 0x01, 0x02], &[]);
        assert!(matches!(res, Err(EnvelopeError::Truncated(_))));
    }

    #[test]
    fn invalid_kek_length_errors() {
        let res = encrypt("aa", b"x", &[]);
        assert!(matches!(res, Err(EnvelopeError::InvalidKekHex(_))));
    }

    #[test]
    fn aad_is_deterministic() {
        let a1 = aad("0xabc", "0xdef", "openrouter", 1);
        let a2 = aad("0xabc", "0xdef", "openrouter", 1);
        assert_eq!(a1, a2);
    }

    #[test]
    fn aad_lowercases_service() {
        let a1 = aad("0xabc", "0xdef", "OpenRouter", 1);
        let a2 = aad("0xabc", "0xdef", "openrouter", 1);
        assert_eq!(a1, a2);
    }

    #[test]
    fn aad_normalizes_0x_prefix() {
        let a1 = aad("0xabc", "0xdef", "s", 1);
        let a2 = aad("abc", "def", "s", 1);
        assert_eq!(a1, a2);
    }
}
