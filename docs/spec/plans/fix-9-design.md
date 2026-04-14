# Design doc — #9 MSK-derived TEE key architecture

**Status:** DRAFT — awaiting human + Kai sign-off.

**Scope:** TEE-side architecture change for `tee-worker/omni-executor`. Not an AgentKeys-repo code change alone; coordinated migration with the Heima TEE worker.

## Problem (from issue #9)

Current Heima TEE stores per-user custodial wallet private keys as individually generated, independently sealed blobs. Scaling issues:

| Concern | Current model | Target (MSK) model |
|---|---|---|
| Key blobs in sealed storage | N (one per user) | 1 (MSK only) |
| Exfiltration attack surface | Linear in users | Constant |
| Migration across TEE hardware | Copy N blobs | Copy 1 MSK |
| Backup/recovery failure mode | Partial (some users lost) | Binary (all or none) |
| MSK rotation cost | N/A | Zero on-chain state changes |

## Proposed architecture

```
┌────────────────────────────────────────────────┐
│ TEE sealed storage                             │
│   MSK  (~32 bytes)                             │
└────────────────────────────────────────────────┘
            │
            ▼
user_privkey = KDF(MSK, H(identity_info))         ← derived on demand
user_pubkey  = user_privkey × G                    ← transient
            │
            ▼
child_pubkey  = soft_derive(user_pubkey,  "/alias/gen")
child_privkey = soft_derive(user_privkey, "/alias/gen")
```

**Invariants:**
1. MSK never leaves the TEE enclave.
2. `user_privkey` and `child_privkey` are derived on demand and zeroized after each operation.
3. Public keys are **not stored on chain**. They are derived fresh for each extrinsic and discarded.
4. OmniAccount addresses are **identity-derived** (`OmniAccountConverter::convert(&identity, &client_id)`), NOT key-derived — so MSK rotation doesn't change user-visible addresses.

## Why this works

### 1. Single key storage

The TEE sealed store holds one value: MSK. Everything else is derived on demand. The exfiltration surface collapses from O(users) to O(1).

### 2. Seamless MSK rotation

Because addresses and stored audit data don't depend on wallet pubkeys (see Invariant 4), rotating MSK has **zero on-chain state impact**:

```
Before rotation:          After rotation:
  MSK_v1                    MSK_v2
  user_privkey_v1           user_privkey_v2 = KDF(MSK_v2, H(identity))
  user_pubkey_v1            user_pubkey_v2 (different!)
  user_address_v1           user_address_v2 = same (identity-derived)
  credential blobs          credential blobs (unchanged, encrypted to shielding key)
  audit events              audit events (unchanged, reference addresses)
```

Operator procedure:
1. Generate MSK_v2 inside the TEE.
2. Atomically replace MSK_v1 with MSK_v2 in sealed storage.
3. From now on, every key-derivation call uses MSK_v2.
4. No migration job. No chain updates. No downtime beyond the atomic swap.

### 3. Soft derivation is safe (TEE-only custody)

All additive soft-derivation schemes (BIP32-NH, Schnorr-threshold, etc.) have a known property: knowledge of `child_privkey` + `chaincode` + `parent_pubkey` lets you recover `parent_privkey`. This is normally a dealbreaker — but in our model, **children never leave the TEE**. The only way to compromise a child key is to compromise the TEE, which also exposes MSK. The child→parent derivation is a strict subset of a worse compromise, so it adds no risk.

### 4. TEE partitioning for multi-jurisdiction

Different MSKs isolate different user populations cryptographically:
- `TEE-China` (MSK_china, paymaster-sponsored)
- `TEE-Global` (MSK_global, self-pay)
- `TEE-Enterprise` (MSK_enterprise, custom billing)

All partitions share the same chain. Users in partition A cannot be impersonated by an operator with access to partition B's TEE.

## Design decisions (locked)

| Decision | Rationale |
|---|---|
| **Unpair disabled** | Key relationship is a mathematical derivation — cannot be "undone." Access control via TEE-side suspend (issue #7). |
| **Path recycling disabled** | Reusing a path for a different agent produces the same key, would leak old credentials, break recovery. |
| **Generation suffix for key rotation** | `/alias/0`, `/alias/1`, … monotonically increasing. Issue #8. |
| **No public keys on chain** | Keeps chain lean. Enables seamless MSK rotation. Public verification available externally if required. |
| **On-chain suspend for revocation** | One suspend event per revoked child path. Only per-child chain state. Issue #7. |

## Deliverables

### TEE worker modifications

- [ ] MSK generation + sealed storage (replace per-user key generation).
- [ ] `KDF(MSK, H(identity_info))` for user wallet keys.
- [ ] Soft derivation for child keys at paths, with generation suffix.
- [ ] Remove per-user sealed-blob storage after migration.
- [ ] On-demand derivation in the credential read/sign paths.
- [ ] Zeroize derived keys after use.
- [ ] MSK rotation procedure (generate new MSK → seal atomically → rederive on next op).

### Chain / pallet modifications

- [ ] Remove any pallet state that stores user public keys (if any exists).
- [ ] Add `current_generation: u32` per child path.
- [ ] Verify OmniAccount addresses stay identity-derived.

### Migration

- [ ] Re-derive existing user wallet keys from MSK + identity.
- [ ] Verify re-derived keys produce the same addresses (or migrate if not — flag if any user address would change).
- [ ] Remove old sealed blobs after migration verification.

### AgentKeys-side changes (in this repo)

Mostly documentation + mock-backend alignment:
- [ ] `wiki/blockchain-tee-architecture.md` — add a section walking through the finalized MSK architecture, including the rotation procedure.
- [ ] `docs/spec/plans/development-stages.md` — Stage 9 (Heima migration) — add the MSK migration as a deliverable.
- [ ] `docs/contradictions.md` §3.3 (TEE wallet-key model) — resolve and close.
- [ ] Mock server (optional): add a `msk_epoch` column to the `sessions` table so AgentKeys tests can validate behavior during rotation. Low-priority; can slip.

## Sequencing

1. **Design sign-off** — this doc. Human + Kai review.
2. **Stage 8 first** — production hardening reshapes memory hygiene in the TEE; MSK work should build on that, not compete with it.
3. **Heima TEE worker mods** — upstream work in `tee-worker/omni-executor`, coordinated with Kai.
4. **AgentKeys docs+mock updates** — small, follow on once the Heima side is stable.

## Open questions for reviewer

1. **Does Heima have an existing MSK?** I've assumed no — that we're introducing the concept. Confirm before implementation.
2. **KDF choice.** HKDF-SHA256 is the default proposal; confirm it matches Heima's crypto primitives and the TEE attestation requirements.
3. **Derivation scheme for children.** BIP32-style soft derivation with a chain code works, but we might prefer a Schnorr-native scheme given Polkadot lineage. Who decides?
4. **Migration cut-over.** Do we migrate atomically (one TEE instance swaps at a specific block) or run v1 + v2 side-by-side during a cut-over window?
5. **Public-key verifiability requirement.** Is there a concrete near-term need to prove `pubkey` ↔ `identity_hash` to a third party? If not, defer the "external verification" feature to post-v0.1.

## References

- GitHub issue [#9](https://github.com/litentry/agentKeys/issues/9)
- `wiki/blockchain-tee-architecture.md` — current architecture state
- `wiki/key-security.md` — threat model + storage tiers
- `docs/contradictions.md` §3.3 — current-vs-target MSK notes
- Issue #7 — TEE-side access control (depends on this)
- Issue #8 — Generation suffix (depends on this)
- Issue #4 — TEE read rate limit (orthogonal but relevant)
- Issue #5 — Pattern 4 audit (orthogonal)
