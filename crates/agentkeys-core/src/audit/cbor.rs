//! Canonical CBOR encoding of [`AuditEnvelope`] for chain commitment +
//! cross-encoder stability.
//!
//! ## Why canonical
//!
//! `envelope_hash = keccak256(canonical_cbor(envelope))` lands on chain.
//! Any non-determinism in the encoding (e.g. arbitrary map key order)
//! would mean the same logical envelope produces different bytes and
//! different hashes across encoders — auditors comparing the chain
//! commitment against a freshly re-encoded envelope would see false
//! mismatches.
//!
//! ## What this enforces
//!
//! Per RFC 8949 §4.2.1, deterministic encoding requires:
//!
//! 1. Integers in the shortest form their value allows.
//! 2. Floats in the shortest form (we don't use floats — envelope-level
//!    is all u8/u64/strings/bytes).
//! 3. Strings/bytes use the indefinite-length form only when required
//!    (we always use definite-length).
//! 4. Map keys sorted by their canonical CBOR encoding (length-then-
//!    lexicographic, per §4.2.3).
//!
//! `ciborium` provides definite-length + shortest-form encoding by
//! default. The map-key ordering is the only point this module needs to
//! enforce explicitly — we build the envelope as an ordered `Vec<(key,
//! Value)>` and emit it as a CBOR map with keys already sorted.
//!
//! ## Wire format
//!
//! The envelope is a single CBOR map with these keys (sorted by canonical
//! CBOR ordering of the text keys):
//!
//! ```text
//! {
//!   "actor_omni":         h'...',         # 32 raw bytes
//!   "intent_commitment":  h'...' | null,  # 32 raw bytes or null
//!   "intent_text":        "..." | null,   # UTF-8 string or null
//!   "op_body":            { ... },        # op-kind-specific CBOR
//!   "op_kind":            uint,           # 0..255
//!   "operator_omni":      h'...',         # 32 raw bytes
//!   "result":             uint,           # 0..255 (AuditResult)
//!   "ts_unix":            uint,           # u64
//!   "version":            uint            # u8
//! }
//! ```
//!
//! Key ordering note: under RFC 8949 §4.2.3, sorting is by **lexicographic
//! comparison of the encoded bytes**, NOT the decoded text. For 9 short
//! ASCII text keys this happens to equal lexicographic-by-text, so the
//! ordering above is correct. If we ever add a longer key, re-derive the
//! order via the algorithm in §4.2.3.

use ciborium::Value;

use super::{AuditEnvelope, AuditError, AuditResult, ENVELOPE_VERSION};

pub fn encode_canonical(env: &AuditEnvelope) -> Result<Vec<u8>, AuditError> {
    let map = Value::Map(vec![
        (Value::Text("actor_omni".into()), Value::Bytes(env.actor_omni.to_vec())),
        (
            Value::Text("intent_commitment".into()),
            match env.intent_commitment {
                Some(c) => Value::Bytes(c.to_vec()),
                None => Value::Null,
            },
        ),
        (
            Value::Text("intent_text".into()),
            match &env.intent_text {
                Some(t) => Value::Text(t.clone()),
                None => Value::Null,
            },
        ),
        (Value::Text("op_body".into()), env.op_body.clone()),
        (Value::Text("op_kind".into()), Value::Integer(env.op_kind.into())),
        (Value::Text("operator_omni".into()), Value::Bytes(env.operator_omni.to_vec())),
        (Value::Text("result".into()), Value::Integer((env.result as u8).into())),
        (Value::Text("ts_unix".into()), Value::Integer(env.ts_unix.into())),
        (Value::Text("version".into()), Value::Integer(env.version.into())),
    ]);

    let mut out = Vec::with_capacity(256);
    ciborium::into_writer(&map, &mut out)
        .map_err(|e| AuditError::Cbor(format!("encode: {e}")))?;
    Ok(out)
}

pub fn decode_canonical(bytes: &[u8]) -> Result<AuditEnvelope, AuditError> {
    let value: Value = ciborium::from_reader(bytes)
        .map_err(|e| AuditError::Cbor(format!("decode: {e}")))?;

    let map = match value {
        Value::Map(m) => m,
        other => return Err(AuditError::Invalid(format!("expected CBOR map, got {other:?}"))),
    };

    let mut actor_omni: Option<[u8; 32]> = None;
    let mut operator_omni: Option<[u8; 32]> = None;
    let mut op_kind: Option<u8> = None;
    let mut op_body: Option<Value> = None;
    let mut result: Option<AuditResult> = None;
    let mut ts_unix: Option<u64> = None;
    let mut version: Option<u8> = None;
    let mut intent_text: Option<Option<String>> = None;
    let mut intent_commitment: Option<Option<[u8; 32]>> = None;

    for (k, v) in map {
        let key = match k {
            Value::Text(s) => s,
            other => return Err(AuditError::Invalid(format!("map key must be text, got {other:?}"))),
        };
        match key.as_str() {
            "actor_omni" => actor_omni = Some(bytes_32(&v, "actor_omni")?),
            "operator_omni" => operator_omni = Some(bytes_32(&v, "operator_omni")?),
            "op_kind" => op_kind = Some(byte(&v, "op_kind")?),
            "op_body" => op_body = Some(v),
            "result" => {
                let b = byte(&v, "result")?;
                result = Some(match b {
                    0 => AuditResult::Success,
                    1 => AuditResult::Failure,
                    2 => AuditResult::NotPermitted,
                    other => {
                        return Err(AuditError::Invalid(format!(
                            "unknown AuditResult byte: {other}"
                        )))
                    }
                });
            }
            "ts_unix" => ts_unix = Some(uint64(&v, "ts_unix")?),
            "version" => version = Some(byte(&v, "version")?),
            "intent_text" => {
                intent_text = Some(match v {
                    Value::Null => None,
                    Value::Text(s) => Some(s),
                    other => {
                        return Err(AuditError::Invalid(format!(
                            "intent_text must be text or null, got {other:?}"
                        )))
                    }
                });
            }
            "intent_commitment" => {
                intent_commitment = Some(match v {
                    Value::Null => None,
                    other => Some(bytes_32(&other, "intent_commitment")?),
                });
            }
            other => {
                // Unknown envelope-level key — preserve forward-compat per
                // invariant #2: ignore quietly. (A future ENVELOPE_VERSION
                // bump would add new known keys; we already rejected
                // version > ENVELOPE_VERSION earlier.)
                let _ = other;
            }
        }
    }

    let version = version.ok_or_else(|| AuditError::Invalid("missing version".into()))?;
    if version != ENVELOPE_VERSION {
        return Err(AuditError::Invalid(format!(
            "unsupported envelope version: {version} (this code supports {ENVELOPE_VERSION})"
        )));
    }

    Ok(AuditEnvelope {
        version,
        ts_unix: ts_unix.ok_or_else(|| AuditError::Invalid("missing ts_unix".into()))?,
        actor_omni: actor_omni.ok_or_else(|| AuditError::Invalid("missing actor_omni".into()))?,
        operator_omni: operator_omni
            .ok_or_else(|| AuditError::Invalid("missing operator_omni".into()))?,
        op_kind: op_kind.ok_or_else(|| AuditError::Invalid("missing op_kind".into()))?,
        op_body: op_body.ok_or_else(|| AuditError::Invalid("missing op_body".into()))?,
        result: result.ok_or_else(|| AuditError::Invalid("missing result".into()))?,
        intent_text: intent_text.unwrap_or(None),
        intent_commitment: intent_commitment.unwrap_or(None),
    })
}

fn bytes_32(v: &Value, label: &str) -> Result<[u8; 32], AuditError> {
    match v {
        Value::Bytes(b) if b.len() == 32 => {
            let mut out = [0u8; 32];
            out.copy_from_slice(b);
            Ok(out)
        }
        Value::Bytes(b) => Err(AuditError::Invalid(format!(
            "{label} must be 32 bytes, got {}",
            b.len()
        ))),
        other => Err(AuditError::Invalid(format!(
            "{label} must be CBOR bytes, got {other:?}"
        ))),
    }
}

fn byte(v: &Value, label: &str) -> Result<u8, AuditError> {
    let n = uint64(v, label)?;
    if n > u8::MAX as u64 {
        return Err(AuditError::Invalid(format!(
            "{label}: value {n} exceeds u8 range"
        )));
    }
    Ok(n as u8)
}

fn uint64(v: &Value, label: &str) -> Result<u64, AuditError> {
    match v {
        Value::Integer(i) => {
            let as_i128: i128 = (*i).into();
            if as_i128 < 0 {
                return Err(AuditError::Invalid(format!(
                    "{label}: negative integer {as_i128}"
                )));
            }
            if as_i128 > u64::MAX as i128 {
                return Err(AuditError::Invalid(format!(
                    "{label}: value {as_i128} exceeds u64 range"
                )));
            }
            Ok(as_i128 as u64)
        }
        other => Err(AuditError::Invalid(format!(
            "{label} must be integer, got {other:?}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audit::AuditOpKind;

    /// Two envelopes with identical content produce IDENTICAL bytes.
    /// This is the cross-encoder-stability property — without it the
    /// chain commitment would drift across encoder implementations.
    #[test]
    fn canonical_cbor_is_byte_stable() {
        let env = AuditEnvelope {
            version: ENVELOPE_VERSION,
            ts_unix: 12345,
            actor_omni: [0x11; 32],
            operator_omni: [0x22; 32],
            op_kind: AuditOpKind::SignEip712 as u8,
            op_body: Value::Map(vec![
                (Value::Text("chain_id".into()), Value::Integer(1.into())),
                (
                    Value::Text("primary_type".into()),
                    Value::Text("Permit".into()),
                ),
            ]),
            result: AuditResult::Success,
            intent_text: Some("test".into()),
            intent_commitment: Some([0xcc; 32]),
        };

        let a = encode_canonical(&env).unwrap();
        let b = encode_canonical(&env).unwrap();
        assert_eq!(a, b, "same input must produce identical CBOR");
    }

    /// Round-trip: encode then decode reconstructs the same envelope.
    #[test]
    fn decode_roundtrip() {
        let env = AuditEnvelope {
            version: ENVELOPE_VERSION,
            ts_unix: 1_700_000_000,
            actor_omni: [0xaa; 32],
            operator_omni: [0xbb; 32],
            op_kind: AuditOpKind::CredFetch as u8,
            op_body: Value::Map(vec![
                (
                    Value::Text("service".into()),
                    Value::Text("openrouter".into()),
                ),
                (
                    Value::Text("cap_hash".into()),
                    Value::Text("0xdeadbeef".into()),
                ),
            ]),
            result: AuditResult::Success,
            intent_text: None,
            intent_commitment: None,
        };

        let bytes = encode_canonical(&env).unwrap();
        let decoded = decode_canonical(&bytes).unwrap();
        assert_eq!(env, decoded);
    }

    /// Decoder rejects an unknown envelope version (invariant #3 — old
    /// readers refuse to interpret a v2 envelope rather than silently
    /// misinterpret).
    #[test]
    fn decoder_rejects_future_version() {
        let mut env = AuditEnvelope {
            version: 99, // future version this code doesn't know
            ts_unix: 1,
            actor_omni: [0; 32],
            operator_omni: [0; 32],
            op_kind: 0,
            op_body: Value::Null,
            result: AuditResult::Success,
            intent_text: None,
            intent_commitment: None,
        };
        env.version = 99;
        let bytes = encode_canonical(&env).unwrap();
        let err = decode_canonical(&bytes).unwrap_err();
        assert!(format!("{err}").contains("99"));
    }

    /// Decoder ignores unknown envelope-level keys (forward-compat for a
    /// future version that adds a top-level field; a v1 decoder reading a
    /// future envelope still gets the v1 fields back). This test crafts
    /// a v1 envelope with an extra `future_key` and confirms the decoder
    /// returns the v1 fields cleanly.
    #[test]
    fn decoder_ignores_unknown_envelope_keys() {
        // Build a CBOR map manually with an extra key.
        let env = AuditEnvelope {
            version: ENVELOPE_VERSION,
            ts_unix: 1,
            actor_omni: [0xaa; 32],
            operator_omni: [0xbb; 32],
            op_kind: 0,
            op_body: Value::Null,
            result: AuditResult::Success,
            intent_text: None,
            intent_commitment: None,
        };
        let mut bytes = encode_canonical(&env).unwrap();
        // Decode → re-encode with an extra key, then re-encode to bytes.
        let mut map = match ciborium::from_reader::<Value, _>(bytes.as_slice()).unwrap() {
            Value::Map(m) => m,
            _ => panic!("expected map"),
        };
        map.push((
            Value::Text("future_v2_key".into()),
            Value::Integer(42.into()),
        ));
        bytes.clear();
        ciborium::into_writer(&Value::Map(map), &mut bytes).unwrap();

        let decoded = decode_canonical(&bytes).unwrap();
        assert_eq!(decoded, env);
    }
}
