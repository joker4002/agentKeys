# Stage 8 — Off-Chain Encrypted Vault (WIP)

> **WIP / scratchpad.** Operational design for the off-chain encrypted vault. The architectural position lives in [`docs/spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md); this doc translates that position into runbook material. Revise as the design lands.

## What Stage 8 is

Move credential ciphertext (and any other bulk encrypted user data) **off the chain**, into S3 (initially) under per-epoch DEKs that rotate on a fixed cadence. Chain retains ownership records, audit, revocation, and ciphertext hashes — the structural facts that need consensus — but holds no encrypted bytes itself.

Two architectural moves, both required, both delivered together:

1. **Off-chain ciphertext, on-chain hash + audit.**
2. **Forward-secret per-epoch DEK rotation, with deletion of old ciphertext at lifecycle.**

The composition gives the property the project did not have before: **total TEE compromise at any future point leaks at most one epoch of data, not all history.** Rationale and threat model in [`threat-model-key-custody.md`](./spec/threat-model-key-custody.md).

## Why it's not Stage 7

Stage 7 ships the OIDC + PrincipalTag isolation primitive. Stage 8 reuses that primitive but adds new work:

- New on-chain pallet (`pallet-vault-pointers`) — replaces the `pallet-secrets-vault` design previously slated for v0.1.
- New TEE-B "rotation enclave" responsibility — separate code surface from the auth/decrypt enclave (TEE-A).
- New S3 layout under `s3://agentkeys-vault/<user_wallet>/<service>/<epoch>/...`.
- New rotation runbook and audit invariants.

Stage 7's bucket-policy + JWT contracts are unchanged. Stage 8 is additive on top.

## Scope of this doc

| In scope | Out of scope |
|---|---|
| Storage layout for off-chain ciphertext | Threshold cryptography across heterogeneous TEE platforms (v0.2+) |
| Per-epoch DEK rotation cadence + runbook | Migration from existing on-chain encrypted state (no users yet) |
| `pallet-vault-pointers` data shape (high-level) | Pallet rust-source — landed when Heima conversation matures |
| Rotation-enclave (TEE-B) responsibilities + attack surface | TEE-B hardware platform decision (assumed: same SGX as TEE-A for v0.1) |
| Audit invariants + extrinsic shape | Frontend / CLI UX for vault management |

## 1. Storage layout

### S3 object key shape

```
s3://agentkeys-vault-<account_id>/<user_wallet>/<service>/<epoch>/<blob_id>.enc
```

- `<account_id>`: AWS account ID — bucket name uniqueness.
- `<user_wallet>`: 0x-prefixed user wallet (lowercase, 42 chars). Matches the PrincipalTag claim.
- `<service>`: canonical service name (`openrouter`, `openai`, …) for sharding readability.
- `<epoch>`: monotonic integer epoch number (e.g., `00042`). New writes go to current epoch.
- `<blob_id>`: opaque random ID (`UUIDv7` suggested for sortable timestamps).

### What's inside the `.enc` file

The serialized payload is structurally similar to a JWE Compact form, but the design treats the construction as opaque — we control both ends:

```
| 4 bytes magic "AKv1" | 1 byte version | 32 bytes wrapped-DEK ID hash |
| 12 bytes nonce       | N bytes ciphertext (AES-256-GCM) | 16 bytes tag |
```

The `wrapped-DEK ID hash` ties the blob to a specific epoch DEK. Ciphertext is AES-256-GCM with the DEK; AAD is `(user_wallet || service || epoch || blob_id)` so the encryption is bound to its identity at the storage layer.

### What's on chain

```rust
// pallet-vault-pointers (replaces the old pallet-secrets-vault design)
pub struct VaultPointer {
    pub user_wallet:        WalletAddress,
    pub service:            ServiceName,
    pub agent_wallet:       WalletAddress,    // who can read
    pub epoch:              u32,
    pub blob_id:            [u8; 16],         // UUID
    pub ciphertext_hash:    [u8; 32],         // SHA-256 of the .enc payload
    pub created_at:         BlockNumber,
    pub last_rotated_at:    Option<BlockNumber>,
    pub deleted_at:         Option<BlockNumber>,
}

// Per-epoch DEK metadata (the wrapped DEK itself is small enough to live on chain)
pub struct EpochDek {
    pub epoch:              u32,
    pub wrapped_dek:        [u8; 64],         // DEK wrapped under TEE shielding key
    pub created_at:         BlockNumber,
    pub destroyed_at:       Option<BlockNumber>,
}
```

The wrapped DEK on chain is what makes the TEE stateless across restarts: any TEE that can derive the shielding key from master seed can unwrap any not-yet-destroyed DEK. After `destroyed_at` is set, the wrapped DEK is removed from chain state and unrecoverable.

### What's in TEE memory (per-request, never persistent beyond request)

- Unwrapped DEK for the epoch being read (held only for the duration of one decrypt; zeroed before return).
- Shielding key (sealed via master seed; standard for Stage 7 already).

The TEE never holds the unwrapped DEK across requests. Each decrypt call re-unwraps from chain.

## 2. Rotation runbook

### Cadence

**Default: weekly rotation, plus on-demand rotation triggered by:**

- An on-chain `RevokeAgent` extrinsic for any user (rotates that user's epoch only — see "Per-user vs global rotation" below).
- An out-of-band security event flagged by the operator (compromise suspected).

Weekly is the v0.1 default. Tunable per-user via grant policy in v0.2+.

### Per-user vs global rotation

Two strategies. We pick **per-user** for v0.1:

| Strategy | Pros | Cons |
|---|---|---|
| Global epoch (one DEK for everyone, rotated weekly) | Cheap; one rotation event. | Rotation requires re-encrypting all users' blobs on the same cadence; cross-user blast radius if a single DEK leaks. |
| **Per-user epoch (one DEK per user, rotated on user-specific cadence)** | Tight blast radius; revocation of user X rotates only user X's DEK. | More on-chain state; per-user rotation runs in parallel — operationally noisier. |

Per-user rotation is what makes the §3 §10 forward-secrecy argument tight. A user's whole vault re-encrypts on their epoch boundary; no other user is affected.

### Rotation flow (per user)

```
PRE: TEE-B has authenticated against TEE-A via attested channel.
PRE: Chain shows EpochDek { epoch: K, wrapped_dek_K, destroyed_at: None } for user U.

Step 1. TEE-B reads chain: list all VaultPointer rows for user U at epoch K.
Step 2. TEE-B unwraps DEK_K from wrapped_dek_K via shielding key.
Step 3. TEE-B generates DEK_{K+1} (256-bit CSPRNG inside enclave).
Step 4. For each blob B at epoch K:
        a. GET s3://agentkeys-vault/<U>/<service>/K/<blob_id>.enc
        b. Decrypt under DEK_K, validate AAD.
        c. Re-encrypt under DEK_{K+1}, new AAD = (U || service || K+1 || blob_id).
        d. PUT s3://agentkeys-vault/<U>/<service>/K+1/<blob_id>.enc
        e. Compute new ciphertext_hash; emit pallet-vault-pointers::Update extrinsic.
Step 5. TEE-B emits EpochRotated { user: U, from: K, to: K+1 } extrinsic.
Step 6. After confirmation: TEE-B emits EpochDestroyed { user: U, epoch: K }.
        - On-chain: wrapped_dek_K is removed; destroyed_at set.
        - S3 lifecycle policy on prefix /<U>/<service>/K/ now eligible for deletion.
Step 7. TEE-B zeroizes its in-memory DEK_K and DEK_{K+1}; returns control.
```

The audit trail (`EpochRotated`, `EpochDestroyed`, plus the per-blob `Update` extrinsics) is what makes "rotation actually happened" verifiable from the chain alone.

### Lazy variant (preferred for v0.1)

Eager re-encryption at rotation time has predictable cost spikes. Lazy re-encryption defers the work until the next read of each blob; idle blobs simply expire under the S3 lifecycle policy.

```
On rotation cadence:
   - Generate DEK_{K+1}, publish wrapped_dek_{K+1}.
   - Mark epoch K as "rotating".

On next read of any blob at epoch K:
   - TEE-A unwraps DEK_K, decrypts, returns plaintext to caller.
   - TEE-A re-encrypts under DEK_{K+1}, writes new blob, updates pointer.
   - (Caller-invisible.)

After lifecycle TTL (e.g., 30 days):
   - Any blob still at epoch K is deleted by S3 lifecycle.
   - When the last K-blob is gone, TEE-B emits EpochDestroyed { K }.
```

Cost: smoother. Worst-case forward-secrecy window: lifecycle TTL (idle blobs persist that long). Both variants are operationally fine; lazy is the default for Stage 8.

## 3. The encryption center — TEE-B

### Responsibilities

1. Generate fresh DEK on rotation events.
2. Wrap DEK under shielding key; publish on chain.
3. Re-encrypt active blobs (eager) or attest to lifecycle deletion (lazy).
4. Destroy old DEKs on `EpochDestroyed`.
5. Emit rotation audit extrinsics (`EpochRotated`, `EpochDestroyed`).

### Attack-surface minimization (the real lever)

Splitting TEE-B from TEE-A only matters if TEE-B has a strictly smaller attack surface. Otherwise the split is theater.

**Hard rules for TEE-B:**

- **No general network I/O.** TEE-B speaks only to (a) TEE-A via attested channel, (b) S3 via signed-only PUT/GET tokens minted in TEE-A, (c) the chain via paymaster-funded signed extrinsics.
- **No untrusted-input parsing.** All inputs are typed binary protocol with fixed-shape messages; no JSON, no XML, no MIME, no cookie strings.
- **No host shared memory beyond the sealed master seed and the in-flight DEK.**
- **Code surface ≤ ~500 lines of trust-critical Rust** (excluding crypto primitives, which come from a vetted library). Aim for human-reviewable end-to-end.
- **Stateless across rotations.** Every rotation reads its inputs from chain + S3, writes outputs, exits. No persistent runtime state.

### What TEE-B does not do

- **Does not authorize.** Authorization decisions are TEE-A's job (session validation, scope enforcement, JWT minting). TEE-B trusts only attested calls from TEE-A.
- **Does not see plaintext credentials in normal operation.** Re-encryption is ciphertext-to-ciphertext — TEE-B unwraps DEK_K, AES-decrypts to recover the user-data plaintext, immediately AES-encrypts under DEK_{K+1}, drops plaintext. The plaintext window is tens of microseconds per blob; never logged, never stored.
- **Does not respond to user-facing requests.** The user-facing decrypt path is TEE-A; TEE-B only runs on rotation cadence + revocation triggers.

### Failure modes and recovery

| Failure | Behavior | Recovery |
|---|---|---|
| TEE-B crashes mid-rotation | Some blobs at K+1, some still at K. Both DEKs still unwrappable from chain. | Resume from chain state on next rotation cycle. |
| Chain is wedged when rotation fires | Rotation is delayed; new DEK not published; old DEK not destroyed. | Operator runbook: wait for chain, re-trigger rotation. No data loss. |
| `EpochDestroyed` emitted before all blobs re-encrypted | **Data loss for not-yet-rotated blobs.** | Pre-condition check: never emit `EpochDestroyed` until lifecycle confirms zero K-objects remain. |
| TEE-B compromise (no other compromise) | Currently active DEK leaks → epoch K plaintext potentially recoverable. Older epochs unaffected (DEKs already destroyed). | Force-rotate all users; revoke the compromised TEE attestation; provision new TEE-B. |
| TEE-A compromise (no other compromise) | Authorization bypass + JWT minting forgery → attacker can ask TEE-A to decrypt anything. **Historical data still leaks if attacker has captured ciphertext.** Forward secrecy still holds for *deleted* epochs. | Rotate all keys; force re-pair; revoke JWTs on chain. |
| Both TEE-A and TEE-B compromised | Worst case. Currently active epoch leaks; older epochs (DEKs destroyed, blobs lifecycle-deleted) are still gone. | Forward-secrecy property still holds for the destroyed-epoch window. |

The combined-compromise case is what motivates the heterogeneous-threshold variant in v0.2+ ([threat-model-key-custody.md §9](./spec/threat-model-key-custody.md)). For Stage 8, single-platform TEE-A + TEE-B is acceptable given the forward-secrecy bound.

## 4. Migration from current claims

There are no users today, so no live data to migrate. The migration is doc-and-design only:

| Doc | Action |
|---|---|
| `wiki/blockchain-tee-architecture.md` §1 | Banner + table row update; cross-ref this doc + threat-model |
| `wiki/data-classification.md` §1 | Update credential-blob row to "off-chain S3 + on-chain hash" |
| `wiki/key-security.md` §1 | Update v0.1 storage column |
| `docs/spec/credential-backend-interface.md` "Mapping to Heima Primitives" | Replace `pallet-secrets-vault::write_secret` with S3 PUT + `pallet-vault-pointers::register_blob` |
| `docs/spec/heima-gaps-vs-desired-architecture.md` | New gap entry: "off-chain ciphertext + on-chain pointers, not on-chain encrypted state" |
| `docs/spec/plans/development-stages.md` | Renumber: new Stage 8 = this doc; old Stage 8 (memory hygiene) → Stage 9; old Stage 9 (Heima holding pen) → Stage 10 |

## 5. Open questions / TODO pickups

1. **Pallet-level work in Heima.** `pallet-vault-pointers` shape above is approximate; needs Kai-side review against Substrate idioms.
2. **Wrapped-DEK size on chain.** 64 bytes per epoch per user; weekly rotation × N users = small but non-zero. Ballpark check at expected user-count: 100k users × 52 weeks/year × 64 bytes ≈ 333 MB/year of pointer state. Acceptable; plan for archive-and-prune of `EpochDek` after `destroyed_at + retention_window`.
3. **Per-user vs per-(user, service) DEK granularity.** Current design: one DEK per user per epoch. Alternative: one DEK per (user, service) pair. Tighter blast radius; more rotation cost. v0.1 default = per-user.
4. **S3 lifecycle TTL for old epochs.** 30 d? 7 d? Tradeoff: shorter = sharper forward-secrecy guarantee; longer = safety margin against rotation bugs. Default proposal: 14 d.
5. **Attested channel TEE-A ↔ TEE-B.** Same enclave today (single SGX); tomorrow split. Need a clear protocol shape so the same code works in both deployments — or explicit "merged for v0.1, split for v0.2."
6. **Rotation-enclave deployment cadence.** Standalone scheduled job? In-process inside the TEE-A worker? Both work; pick after the Heima conversation lands.
7. **Cross-region failover.** Stage 6 ships `us-east-1` only. When does the vault go multi-region? Tied to chain-availability strategy; out of Stage 8 scope.

## 6. Cross-references

- [`docs/spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md) — the architectural position this doc implements.
- [`docs/stage7-wip.md`](./stage7-wip.md) — OIDC + PrincipalTag, the isolation primitive Stage 8 reuses.
- [`docs/cloud-setup.md`](./cloud-setup.md) — AWS infra for SES + S3 (singleton); the same AWS account hosts the vault bucket.
- [`docs/spec/heima-gaps-vs-desired-architecture.md`](./spec/heima-gaps-vs-desired-architecture.md) — needs new gap entry for `pallet-vault-pointers`.
- [`docs/spec/credential-backend-interface.md`](./spec/credential-backend-interface.md) — `store_credential` / `read_credential` semantics translate cleanly; mapping table updated.
- [`docs/spec/plans/development-stages.md`](./spec/plans/development-stages.md) — Stage 8 entry, post-renumber.
