# Adding a new audit op_kind

This is the operator-facing detailed guide for extending the AgentKeys audit envelope with a new op_kind. Defers to [`docs/spec/architecture.md`](../docs/spec/architecture.md) §15.3a (canonical schema + 8 non-break invariants) and §15.3b (the 5-step ritual). This page walks through a worked example + the complete PR checklist.

## The current op design (one-paragraph recap)

Every audit-producing surface in AgentKeys (creds, memory, signer, broker, payment-service, email-service, SidecarRegistry, K3EpochCounter) emits a single canonical envelope shape — `AuditEnvelope v1`. The envelope is encoded as deterministic CBOR (RFC 8949 §4.2.1), addressed by `envelope_hash = keccak256(canonical_cbor(envelope))`. The worker (`agentkeys-worker-audit`) stores the full envelope; the chain (`CredentialAudit.appendV2`) commits only `(opKind, envelopeHash)` as an indexed event. An explorer reads chain events, fetches envelopes by hash, renders per-op_kind. New op_kinds add a row to a canonical table in arch.md §15.3a + a Rust variant + a typed body struct — and that's it. The chain contract never decodes `op_body` (op-kind-agnostic), so new op_kinds need ZERO contract redeploys.

## Worked example: adding `PaymentRefund` (byte 32)

Suppose the payment-service ([`crates/agentkeys-worker-payment`](../crates/agentkeys-worker-payment) — hypothetical) now supports refund flows. The existing payment family has `PaymentEscrowRedeem=30` and `PaymentDirect=31`. We claim byte `32` for `PaymentRefund`.

### Step 1 — pick the byte

```
Family: payments (30-39 reserved)
Used:   30=PaymentEscrowRedeem, 31=PaymentDirect
Pick:   32=PaymentRefund
```

Reserved-but-unused bytes in the payments family: 33-39. Use the lowest unused.

### Step 2 — append the row to arch.md §15.3a canonical op_kind table

Edit [`docs/spec/architecture.md`](../docs/spec/architecture.md) — find the canonical table in §15.3a, append (do NOT reorder existing rows):

```markdown
| `PaymentRefund` | 32 | `{original_op_envelope_hash: [u8;32], reason_code: u8, amount_returned: U256}` | payment-service |
```

The schema column lists every field in the typed `op_body`. Naming convention: snake_case field names, byte arrays as `[u8;N]`, big integers as `U256` (string-encoded over the wire to survive JSON `i53` limits).

### Step 3 — add the Rust variant

Three files in [`crates/agentkeys-core/src/audit/`](../crates/agentkeys-core/src/audit):

**[`op_kind.rs`](../crates/agentkeys-core/src/audit/op_kind.rs):**

```rust
pub enum AuditOpKind {
    // … existing variants …
    PaymentEscrowRedeem = 30,
    PaymentDirect = 31,
    PaymentRefund = 32,  // ← new
    // … rest …
}

impl AuditOpKind {
    pub fn from_u8(byte: u8) -> Option<Self> {
        Some(match byte {
            // … existing arms …
            31 => Self::PaymentDirect,
            32 => Self::PaymentRefund,  // ← new
            // … rest …
            _ => return None,
        })
    }

    pub fn label(self) -> &'static str {
        match self {
            // … existing arms …
            Self::PaymentDirect => "payment.direct",
            Self::PaymentRefund => "payment.refund",  // ← new
            // … rest …
        }
    }
}
```

**[`bodies.rs`](../crates/agentkeys-core/src/audit/bodies.rs):**

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PaymentRefundBody {
    /// envelope_hash of the original PaymentEscrowRedeem / PaymentDirect
    /// envelope being refunded. 0x-prefixed 64-hex (32 raw bytes).
    pub original_op_envelope_hash: String,
    /// Refund reason — small open-enum byte: 0=customer_initiated,
    /// 1=service_initiated, 2=chargeback, 3=fraud, 4-255=reserved.
    pub reason_code: u8,
    /// Amount returned in the chain's native units (string-encoded U256).
    pub amount_returned: String,
}
```

And re-export from `bodies::*` at the top of [`mod.rs`](../crates/agentkeys-core/src/audit/mod.rs):

```rust
pub use bodies::{
    // … existing exports …
    PaymentDirectBody,
    PaymentRefundBody,  // ← new
    PaymentEscrowRedeemBody,
    // … rest …
};
```

**[`mod.rs`](../crates/agentkeys-core/src/audit/mod.rs) — `TypedAuditBody` enum + decoder:**

```rust
pub enum TypedAuditBody {
    // … existing variants …
    PaymentEscrowRedeem(PaymentEscrowRedeemBody),
    PaymentDirect(PaymentDirectBody),
    PaymentRefund(PaymentRefundBody),  // ← new
    // … rest …
}

impl TypedAuditBody {
    fn from_envelope(env: &AuditEnvelope) -> Option<Self> {
        // … existing arms …
        Some(match kind {
            // … existing arms …
            AuditOpKind::PaymentDirect => {
                Self::PaymentDirect(serde_json::from_value(value).ok()?)
            }
            AuditOpKind::PaymentRefund => {  // ← new
                Self::PaymentRefund(serde_json::from_value(value).ok()?)
            }
            // … rest …
        })
    }
}
```

### Step 4 — wire the emit site

In the payment-service worker (e.g. [`crates/agentkeys-worker-payment/src/handlers.rs`](../crates/agentkeys-worker-payment) — hypothetical):

```rust
use agentkeys_core::audit::{
    AuditClient, AuditOpKind, AuditResult, PaymentRefundBody, envelope_for,
};

async fn handle_refund(&self, req: RefundRequest) -> Result<RefundResponse, _> {
    // … do the refund work …
    let result = self.execute_refund(&req).await;

    // Emit audit envelope on success OR failure (both are audit-worthy).
    let envelope = envelope_for(
        req.actor_omni_bytes(),
        req.operator_omni_bytes(),
        AuditOpKind::PaymentRefund,
        PaymentRefundBody {
            original_op_envelope_hash: format!("0x{}", hex::encode(req.original_hash)),
            reason_code: req.reason_code,
            amount_returned: req.amount.to_string(),
        },
        match &result {
            Ok(_) => AuditResult::Success,
            Err(_) => AuditResult::Failure,
        },
        Some(format!("Refund {} to {}", req.amount, req.recipient)),
        // intent_commitment = keccak256(intent_text || 0x7c || op_payload_digest)
        // op_payload_digest here is the original_op_envelope_hash (binds refund to the op being refunded).
        Some(agentkeys_core::audit::commit_intent(
            &format!("Refund {} to {}", req.amount, req.recipient),
            &req.original_hash,
        )),
    )?;

    let client = AuditClient::from_env();
    let _ = client.append(&envelope).await;  // emit-and-forget

    result
}
```

The worker stores the envelope by hash. Later (batched or immediate), the same worker — or a sidecar emitter — calls `CredentialAudit.appendV2(operator_omni, actor_omni, op_kind=32, envelope_hash)` on chain. The explorer reads the chain event, fetches the envelope from the worker, renders per the new `PaymentRefundBody` shape.

### Step 5 — ship the three required tests

**Test A — worker CBOR roundtrip** in [`crates/agentkeys-core/src/audit/bodies.rs`](../crates/agentkeys-core/src/audit/bodies.rs):

```rust
#[test]
fn payment_refund_body_roundtrips() {
    let body = PaymentRefundBody {
        original_op_envelope_hash: format!("0x{}", "de".repeat(32)),
        reason_code: 1,
        amount_returned: "1500000000000000000".to_string(),  // 1.5 in 18-decimals
    };
    let json = serde_json::to_value(&body).unwrap();
    let decoded: PaymentRefundBody = serde_json::from_value(json).unwrap();
    assert_eq!(body, decoded);
}
```

**Test B — explorer Unknown(byte) fallback** in [`subscan-essentials`](https://github.com/litentry/subscan-essentials):

A unit test that crafts an envelope with `op_kind=32` against an older explorer build (one that doesn't yet know about `PaymentRefund`), confirms the indexer:
- Stores the envelope without crashing.
- Renders the row as `Unknown(32)` with envelope-level fields visible (actor, operator, timestamp, intent_text).
- Does NOT 5xx or drop the event.

**Test C — arch.md row uniqueness check.** This is enforced from the Rust side already by [`audit::op_kind::tests::all_byte_values_unique`](../crates/agentkeys-core/src/audit/op_kind.rs) — adding the new variant at byte 32 will fail this test if 32 was already claimed. Keep the doc + code in sync; the test is the regression guard.

## PR checklist

Before opening the PR for a new op_kind:

- [ ] Bytes claimed in the right family range; never reused; never reordered.
- [ ] [`docs/spec/architecture.md`](../docs/spec/architecture.md) §15.3a canonical table row appended.
- [ ] [`crates/agentkeys-core/src/audit/op_kind.rs`](../crates/agentkeys-core/src/audit/op_kind.rs) variant + `from_u8` arm + `label` arm added.
- [ ] [`crates/agentkeys-core/src/audit/bodies.rs`](../crates/agentkeys-core/src/audit/bodies.rs) typed body struct + serde derives + (optional) roundtrip test.
- [ ] [`crates/agentkeys-core/src/audit/mod.rs`](../crates/agentkeys-core/src/audit/mod.rs) `TypedAuditBody` variant + `from_envelope` arm + re-export.
- [ ] Emit site wired in the appropriate worker / broker / signer / hook.
- [ ] `cargo test -p agentkeys-core --lib audit` passes (the `all_byte_values_unique` test catches collisions).
- [ ] `ENVELOPE_VERSION` UNCHANGED — adding an op_kind never bumps the envelope version.
- [ ] Explorer-side PR opened against [`litentry/subscan-essentials`](https://github.com/litentry/subscan-essentials) to teach the indexer + UI about the new op_kind. Until that lands, old explorers render `Unknown(byte)` — that's the deliberate non-break design.

## What you DON'T need to do

- ❌ **Redeploy `CredentialAudit.sol`.** The contract is op-kind-agnostic. New op_kinds need ZERO contract redeploys.
- ❌ **Bump `ENVELOPE_VERSION`.** That field is reserved for envelope-level breakage (adding / removing top-level fields). New op_kinds stay at v1.
- ❌ **Migrate existing envelopes.** The new op_kind is additive — pre-existing envelopes are unaffected.
- ❌ **Coordinate a synchronous rollout across all components.** The non-break design is asynchronous: workers can emit new op_kinds immediately; old explorers gracefully `Unknown(byte)`-render; new explorers ship later with the typed renderer. Each component upgrades on its own cadence.

## Where to look for cross-references

- [`docs/spec/architecture.md`](../docs/spec/architecture.md) §15.3a — canonical schema, op_kind table, 8 non-break invariants, 6-phase migration plan.
- [`docs/spec/architecture.md`](../docs/spec/architecture.md) §15.3b — the 5-step ritual (a more concise summary of this page).
- [`crates/agentkeys-core/src/audit/mod.rs`](../crates/agentkeys-core/src/audit/mod.rs) — `AuditEnvelope` struct + `commit_intent` helper.
- [`crates/agentkeys-core/src/audit/client.rs`](../crates/agentkeys-core/src/audit/client.rs) — `AuditClient` HTTP wrapper + `envelope_for` builder.
- [`crates/agentkeys-chain/src/CredentialAudit.sol`](../crates/agentkeys-chain/src/CredentialAudit.sol) — `appendV2` + `appendRootV2` on-chain surface.
- [agentKeys#97](https://github.com/litentry/agentKeys/issues/97) — implementation tracking issue for Phases B + C + F.
- [subscan-essentials#12](https://github.com/litentry/subscan-essentials/issues/12) — explorer tracking issue for Phases D + E.
