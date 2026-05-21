# K11 intent conventions — uniform Touch ID prompts across all sites

Every K11 WebAuthn ceremony in AgentKeys MUST render the same envelope of operator-readable context on its localhost confirmation page. Otherwise operators get into the habit of "tap-to-approve" because some prompts say something and others say nothing — and "tap-to-approve" is exactly the failure mode the K11 binding is supposed to prevent. This page is the canonical convention every K11-emitting script + service MUST follow.

See [`wiki/k11-webauthn-intent-rendering.md`](./k11-webauthn-intent-rendering.md) for the underlying rendering mechanism (the `K11IntentContext` type + `assert_webauthn_*_with_intent` entry points). This page covers the *content convention* — what the intent text + per-field rows MUST include for the prompt to count as conformant.

## Why uniform

Master-mutation ceremonies (scope grant/revoke, device add/revoke, K10 rotation, recovery) all share the same trust-model property: the operator's eyes are the load-bearing safety check. If one ceremony's confirmation page says nothing while a neighbor ceremony's page renders a detailed intent block, the operator learns to ignore the page entirely. The uniform rule means every prompt shows the same envelope — operator confidence comes from "I always see what I'm signing", not from "I sometimes see what I'm signing if the script remembered to pass intent".

## The envelope (required fields, in this order)

Every `K11IntentContext` passed to `assert_webauthn_*_with_intent()` MUST include these rows, in this order:

| Row | Always | Example value |
|---|---|---|
| **`Operator omni`** | yes | `0x941cb1c3260518bbf40eac7d02663517fc7cff304d9b03e80d2cc54126c6bef2` |
| **`Asserting role`** | yes | `PRIMARY (key hash 0xde64…)` or `COMPANION (key hash 0xb322…)` |
| Operation-specific detail rows | varies | e.g. `Target device key hash=0x…`, `Services=openrouter,brave-search`, `Recovery threshold=2` |
| **`Effect`** | yes (chain-mutating ops) | one-line plain-English description of what changes on chain after the tx lands |
| **`Chain ID`** | yes | `212013` |
| **`Operator nonce`** | yes (chain-tx ops) | `42` |

The headline (`intent.text`) is a single sentence describing the operation. The Effect row is what makes the consequence concrete — the operator should understand from the Effect row alone what the world looks like AFTER they tap.

## Required headline + Effect text by operation

This is the canonical phrasing table. Scripts implementing a K11 ceremony for an operation MUST use the headline + Effect verbatim from this table (or extend the table in the same PR).

| Operation | Headline (`intent.text`) | Effect row |
|---|---|---|
| `setRecoveryThreshold` | `Set recovery threshold to N (M-of-N master quorum)` | `future master-device revokes will require this many active master signatures` |
| `registerAdditionalMasterDevice` (companion) | `Register companion device as 2nd master` | (auto-derived from role bitfield) |
| `registerAdditionalMasterDevice` (synthetic spare) | `Register synthetic 3rd master (spare) device` | `adds a 3rd master to the operator's quorum (used by harness step 9 to demo M-of-N revoke)` |
| `recover` (M-of-N device revoke) | `Revoke master device via M-of-N recovery quorum` | `removes <target> from the operator's active master set; future cap-mint by this device is rejected on-chain` |
| `setScopeWithWebauthn` | `Grant agent '<label>' access to: <services>` | (per-row detail: services, read_only, max amounts, period) |
| `revokeScope` | `Revoke all scope grants for agent '<label>'` | `agent loses access to ALL services this scope previously granted` |
| `revokeDevice` (master) | `⚠ REVOKE MASTER device — this disables the operator's master entirely` | (per-row detail: target device hash, role bits being revoked, recovery threshold remaining) |
| `revokeDevice` (agent) | `Revoke agent device key hash <hash>` | `agent device can no longer mint caps; previously-issued caps still work until expiry` |
| `rotateK10` (device-key rotation) | `Rotate device key from <old> to <new>` | (TBD — wire when shipped) |

**Warning-prefix convention** (`⚠` U+26A0 + space): use the warning emoji prefix in the headline ONLY for **catastrophic, hard-to-reverse** operations — master-device revoke is the canonical example. The warning marker tells the operator's eye to slow down before tapping. Agent-device revoke (lower blast radius, recoverable) does NOT get the prefix. Don't over-use it; if every prompt has the warning, none of them do.

If you're adding a new master-mutation operation:
1. Add a row to this table in the same PR.
2. Use the canonical headline + Effect across every script that runs that operation's K11 ceremony.

## Multi-party ceremonies — both prompts MUST match

When an operation requires more than one master signature (recovery via M-of-N quorum), every participating master sees a K11 prompt. **All prompts MUST render the same headline + the same operation-specific rows + the same Effect.** The only field that differs per-master is `Asserting role`.

This means: the script that orchestrates the multi-party ceremony (`heima-recovery.sh` is the canonical example) computes the canonical intent envelope ONCE and:
- Passes it to the local `agentkeys k11 assert` invocation (for PRIMARY).
- Embeds it in the JSON POST body to the companion's `/v1/companion/approve` endpoint (for COMPANION). The companion daemon's handler reads `intent_text` + `intent_fields` from the POST body and renders them on its own Touch ID confirmation page.

Implementation:
- `ApproveRequest` ([`crates/agentkeys-daemon/src/companion.rs`](../crates/agentkeys-daemon/src/companion.rs)) accepts optional `intent_text: Option<String>` + `intent_fields: Vec<String>` fields. Each `intent_fields` entry is a `Label=Value` string; the handler splits on the first `=`.
- The companion's `approve` handler calls `assert_webauthn_for_chain_with_intent()` — same code path that primary uses, so the rendering on the localhost confirmation page is identical apart from the role badge color (purple for companion vs blue for primary).

## Conformant K11 emit sites

| Site | Operation | Conformant? |
|---|---|---|
| [`scripts/heima-scope-set.sh`](../scripts/heima-scope-set.sh) | scope grant | ✅ |
| [`scripts/heima-scope-revoke.sh`](../scripts/heima-scope-revoke.sh) | scope revoke | ✅ |
| [`scripts/heima-device-revoke.sh`](../scripts/heima-device-revoke.sh) | revoke device | ✅ |
| [`harness/scripts/heima-device-add.sh`](../harness/scripts/heima-device-add.sh) | register companion as 2nd master | ✅ |
| [`harness/scripts/heima-register-spare-master.sh`](../harness/scripts/heima-register-spare-master.sh) | register synthetic 3rd master | ✅ |
| [`harness/scripts/heima-set-recovery-threshold.sh`](../harness/scripts/heima-set-recovery-threshold.sh) | set recovery threshold | ✅ |
| [`harness/scripts/heima-recovery.sh`](../harness/scripts/heima-recovery.sh) PRIMARY + COMPANION | M-of-N device revoke | ✅ (both prompts uniform; companion via POST body) |
| Future master-mutation script | (new) | MUST follow this convention before merging |

## What does NOT count as conformant

- Passing only `--intent-text` without the standard `--intent-field` rows. The headline alone is not enough — the operator needs the Operator omni + Asserting role + Chain ID + Nonce footer to verify who/where/what-state context.
- Passing intent on the primary side but not on the companion side of a multi-party ceremony (the trap the stage-2 step-9 demo hit before the fix). Operators learn from one prompt that intent is shown, then mistrust the companion prompt that hides it.
- Passing different headlines or different Effect rows across the primary + companion prompts in the same ceremony. They MUST be the same headline + same operation-specific rows; only `Asserting role` differs.

## Verification

Per-site sanity check during development:

```bash
# Trigger any K11 ceremony in stub mode (no real Touch ID); the
# localhost confirmation page renders + the script prints its URL.
# Open the URL, inspect the intent block, confirm:
#   - Headline matches the canonical table above.
#   - Operator omni + Asserting role + Chain ID + Nonce rows all present.
#   - Effect row reads as plain-English consequence-after-tx.

# For multi-party ceremonies, run both daemons + diff the rendered HTML
# of primary vs companion confirmation pages — only the Asserting role
# row + the role badge color should differ.
```

A future PR will add an integration test that asserts the rendered HTML
of every K11-emitting site contains all required rows, so the
convention is mechanically enforced rather than convention-only.

## Cross-references

- [`wiki/k11-webauthn-intent-rendering.md`](./k11-webauthn-intent-rendering.md) — the rendering mechanism (`K11IntentContext`, HTML page structure, fallback behavior when no intent is supplied).
- [`docs/spec/architecture.md`](../docs/spec/architecture.md) §10.1 — master init + K11 binding model.
- [`wiki/audit-envelope-add-op-kind.md`](./audit-envelope-add-op-kind.md) — when a new master-mutation op_kind PR lands, it MUST also extend the K11 intent table above with the canonical headline + Effect for that op.
