# Plan: AgentKeys broker — pluggable attestation / wallet provisioning / audit, no hard Heima dependency

## Context — what changed in the framing

Three rounds of research established that:

1. **Heima TEE worker is single-tenant** (`client_id == CLIENT_ID_WILDMETA` hardcoded in `user_login.rs:73-104`). Multi-tenant support requires a Litentry upstream patch.
2. **The Heima patch cost is asymmetric** between the prior options:
   - Option A (port dexs-backend): minimum patch, ~250 LOC, just clone the wildmeta dispatch block.
   - Option B (greenfield broker): bigger patch, ~400+ LOC, introduces a parallel `oe_client_agentkeys` shape, more Litentry review cycles.
3. **Even the minimum patch is "a lot of work"** — Litentry's review cycle is weeks, jurisdictional concerns (China vs global), the patch ties our deployment to Litentry's release schedule, and any future Heima evolution forces re-coordination.

The user's reframe (paraphrased): *"Heima should also be pluggable. We could use Solana or Ethereum smart contract for audit. Don't make Heima the spine of AgentKeys."*

This aligns with what `docs/spec/architecture.md §11 "Audit destination is pluggable"` already documents — but extends the principle to **two more layers** that the previous plans (A and B) had silently hardcoded as Heima-bound:

| Layer | Architecture.md §11 says | Prior plans (A, B) hardcoded |
|---|---|---|
| **Audit anchoring** | Pluggable: Heima, Ethereum, Solana, Sui, Cosmos, permissioned chains, S3 Object Lock, SQLite, Azure Confidential Ledger, AWS QLDB | Implicit Heima for production |
| **Wallet provisioning** | Not explicitly addressed | Implicit Heima TEE (`omni_addWallet`, sealed seed derivation) |
| **Session attestation** | Not explicitly addressed | Implicit Heima TEE-RSA JWT |

If we extend §11's principle to all three, AgentKeys' v0 doesn't need Heima at all. Heima becomes one plug-in among several, deployed when an operator wants the cross-chain OmniAccount story, attestation rigor, or geographic positioning Heima provides — but no operator is forced to consume it.

## Three pluggable layers

### Layer 1 — User authentication

What it does: verifies a user owns the identity they claim. Returns `(omni_account, identity_type, identity_value)` on success.

Plug-ins (any subset can be enabled per deployment):

- **`WalletSigAuth`** — EIP-191 ecrecover + 45-min timestamp window. Pure Rust + `k256`. Zero external deps. Works for EVM wallets; mirror for Solana/sr25519 if needed.
- **`PasskeyAuth`** — WebAuthn. Two implementations possible:
  - `LocalPasskeyAuth` — `webauthn-rs` crate, broker handles directly. Simplest.
  - `TeePasskeyAuth` — proxies to Heima TEE worker's `attach_passkey` / passkey RPC. Higher assurance, requires Heima.
- **`OAuth2Auth`** — Google / Apple / GitHub. ID-token verification via JWKS fetch from each provider. Pure Rust + `oauth2` + `jsonwebtoken`. No external service needed.
- **`EmailLinkAuth`** — passwordless magic-link. Generates one-shot signed URL, mails it via existing AgentKeys SES setup. **Drops** dexs-backend's email + password + TOTP pattern entirely.

Each plug-in implements one trait:

```rust
#[async_trait]
pub trait UserAuthMethod: Send + Sync {
    fn name(&self) -> &str;
    async fn challenge(&self, params: ChallengeParams) -> Result<Challenge>;
    async fn verify(&self, response: AuthResponse) -> Result<VerifiedIdentity>;
}

pub struct VerifiedIdentity {
    pub identity_type: IdentityType,    // Evm | Solana | Email | Google | Passkey | ...
    pub identity_value: String,          // wallet address, email, passkey credential id, etc.
    pub omni_account: OmniAccount,       // SHA256(client_id || type || value), our own client_id
}
```

The broker's auth router dispatches by `method` field on the inbound request to the right plug-in.

### Layer 2 — Wallet provisioning (smart wallet for non-wallet-sig users)

What it does: when an email/OAuth/passkey user needs a wallet (to send tx, sign userOp, receive funds), provide one. Returns `(wallet_address, signing_capability_handle)`.

Plug-ins:

- **`ClientSideKeystoreProvisioner`** — CLI generates BIP-39 mnemonic locally, stores encrypted in OS keychain. User holds the seed; broker holds only the address. **MetaMask model.** Zero external deps. Cleanest for v0.
- **`HeimaTeeProvisioner`** — calls `omni_addWallet`; wallet's root signer key lives in Heima TEE; broker holds only the address. User can never export the seed (or can via TEE-gated `omni_exportWallet`). **Highest assurance.** Requires Heima patch.
- **`AwsNitroProvisioner`** — wallet generated inside an AWS Nitro Enclave running an oe-executor-equivalent; attested via Nitro attestation document. **Cloud-portable alternative to Heima.** Requires us to operate the enclave.
- **`SmartContractAaProvisioner`** — passkey-derived account-abstraction (ERC-4337) wallet. Wallet is a smart contract on Ethereum/L2; signing is the passkey credential. **Web3-native, no seed phrase, gas-sponsored bundler optional.** Requires AA bundler infra.

Trait:

```rust
#[async_trait]
pub trait WalletProvisioner: Send + Sync {
    fn name(&self) -> &str;
    async fn provision(&self, omni_account: &OmniAccount) -> Result<WalletHandle>;
    async fn sign(&self, omni_account: &OmniAccount, wallet_index: u32, payload: &[u8])
        -> Result<Signature>;
}
```

For v0 we ship `ClientSideKeystoreProvisioner` (zero deps) and document the others as future plug-ins.

### Layer 3 — Audit anchoring

What it does: append a tamper-evident record of every credential mint. Architecture.md §11 already documents this as pluggable.

Plug-ins (verbatim from §11 + the user's call-out):

- **`SqliteAnchor`** — what the broker ships today (`~/.agentkeys/broker/audit.sqlite`, append-only by application invariant).
- **`SolanaProgramAnchor`** — anchors mint hashes to a Solana program (cheap, fast, public). Audit log writes are batched + posted as transactions; on-chain stores `keccak256(audit_record)` plus the wallet/timestamp index.
- **`EthereumL2Anchor`** — same idea, Ethereum L2 (Arbitrum / Base / OP Stack). Slightly higher cost than Solana, possibly stronger settlement guarantees.
- **`HeimaParachainAnchor`** — `pallet-bitacross` or equivalent extrinsic per mint. The previously-assumed default; now one option among many.
- **`S3ObjectLockAnchor`** — sealed S3 bucket with object lock + retention. Centralized but jurisdiction-portable.
- **`SealedLogAnchor`** — Azure Confidential Ledger / AWS QLDB / Honeycomb cryptographic ledger.

Trait:

```rust
#[async_trait]
pub trait AuditAnchor: Send + Sync {
    fn name(&self) -> &str;
    async fn anchor(&self, record: &AuditRecord) -> Result<AnchorReceipt>;
    async fn verify(&self, receipt: &AnchorReceipt, record: &AuditRecord) -> Result<bool>;
}
```

For v0 we ship `SqliteAnchor` (already exists) and document the chain anchors as v1 plug-ins. **Solana is the recommended chain anchor for v1** because:
- Cheap (sub-cent transaction costs).
- Fast (sub-second confirmation).
- Public (anyone can audit AgentKeys' mint stream).
- No Litentry coordination required.

## Plug-in catalog (deployment combinations)

Each AgentKeys deployment chooses one plug-in per layer. Examples:

| Deployment style | Auth | Wallet | Audit |
|---|---|---|---|
| **Self-hosted small team** | WalletSig + EmailLink | ClientSide | SQLite |
| **Crypto-native dev tool** | WalletSig only | ClientSide | Solana |
| **End-user product (web)** | Passkey + GoogleOAuth + AppleOAuth | SmartContractAa | EthereumL2 |
| **Enterprise / China deployment** | OAuth2 + EmailLink | AwsNitro | S3ObjectLock + permissioned chain |
| **Heima-aligned (the prior plan's assumption)** | WalletSig + Passkey via TEE + OAuth | HeimaTee | HeimaParachain |
| **Wildmeta-bridged (interop with dexs-backend)** | WalletSig (proxied) | HeimaTee | HeimaParachain + Solana mirror |

The broker's only opinion is the trait boundaries; deployments mix and match.

## What ships when

### v0 — fully self-contained, zero external deps
- **Auth**: WalletSig + EmailLink. ~600 LOC.
- **Wallet**: ClientSide (CLI generates mnemonic, stores in keychain). ~300 LOC + ~200 LOC CLI changes.
- **Audit**: SQLite (already shipped). 0 LOC change.
- **Trait scaffolding**: ~400 LOC (the three traits + dispatch router + dependency injection).
- **Total**: ~1500 LOC + ~500 LOC tests + docs.
- **Calendar**: 4–5 weeks for one engineer.
- **Heima dependency**: zero. No upstream patch. AgentKeys ships and is operationally complete.

### v1 — the chain-anchored audit story
- **Audit**: add `SolanaProgramAnchor`. Anchors mint hashes to a deployed Solana program. ~600 LOC + ~300 LOC tests + the on-chain program (~200 LOC Anchor / Solana SDK).
- **Auth**: add `OAuth2Auth` (Google + Apple, JWKS-based id_token verify). ~500 LOC.
- **Calendar**: 3 weeks.
- **Heima dependency**: still zero.

Operators can migrate from `SqliteAnchor` → `SolanaProgramAnchor` by config flag; the audit record schema is unchanged, only the persistence backend differs. Old SQLite rows stay queryable; new mints land on-chain.

### v1.5 — passkey + smart-contract AA wallet
- **Auth**: add `LocalPasskeyAuth` (WebAuthn via `webauthn-rs`). ~500 LOC.
- **Wallet**: add `SmartContractAaProvisioner` (passkey-derived AA wallet on the L2 of choice). ~800 LOC + bundler integration + on-chain account-factory contract.
- **Calendar**: 4 weeks.
- **Heima dependency**: still zero.

This unlocks the end-user flow (passkey → smart wallet, no seed phrase) without ever touching Heima.

### v2 — optional Heima integration
- **Auth**: add `TeePasskeyAuth` proxy (passkey verification in TEE for higher assurance).
- **Wallet**: add `HeimaTeeProvisioner` (smart-wallet root signer in TEE).
- **Audit**: add `HeimaParachainAnchor` (`pallet-bitacross` extrinsic).
- This is when we draft the upstream Litentry patch (~250–400 LOC, depending on the integration shape) and coordinate review.
- **Calendar**: 4 weeks AgentKeys side + Litentry's review cycle.
- **Heima dependency**: introduced as one plug-in option, not a baseline.

By v2 we know exactly what shape we want from Heima; the patch can be precise rather than speculative.

## Comparison against the prior options

| | A — Port dexs-backend | B — Greenfield, Heima-coupled | **C — Greenfield, pluggable (this plan)** |
|---|---|---|---|
| Heima patch needed for v0 | ~250 LOC | ~400 LOC | **None** |
| Heima patch needed for v1 | same | same | None |
| Heima patch needed for v2 | already done | already done | ~250–400 LOC (precise, after v1) |
| Lock-in to Litentry's release cycle | Yes (from week 1) | Yes (from week 1) | **No** (deferred to v2; cancelable) |
| Architectural future-flexibility | Low | Medium | **High** |
| China-jurisdiction deployment | Heima or bust | Heima or bust | **Trivially: pick a permissioned-chain anchor + S3** |
| Audit-destination choice | Heima only (initially) | Heima only (initially) | **One config row** |
| Wallet-provisioning choice | Heima TEE only | Heima TEE only | **One trait swap** |
| Total v0 LOC | ~10,000 | ~8,800 | **~1,500** |
| Total v0+v1+v1.5 LOC | n/a | n/a | ~5,000 |
| v0 calendar | 8–13 weeks | 12–18 weeks | **4–5 weeks** |
| v0+v1+v1.5 calendar | n/a | n/a | 11–13 weeks |
| Risk of being blocked by Litentry | High | Higher | **None for v0/v1; managed for v2** |

The headline shift: **C ships v0 in roughly the time it takes A or B to draft the upstream Litentry patch.** Operators get a working broker fast; later-phase decisions stay open.

## Architectural sketch

```rust
// crates/agentkeys-broker-server/src/lib.rs
pub struct Broker {
    auth_methods: HashMap<String, Box<dyn UserAuthMethod>>,    // "wallet_sig", "email_link", ...
    wallet_provisioner: Box<dyn WalletProvisioner>,            // chosen at config time
    audit_anchor: Box<dyn AuditAnchor>,                        // chosen at config time
    cred_minter: AwsCredMinter,                                // existing, unchanged
}
```

Configuration loads concrete plug-ins at startup:

```toml
# /etc/agentkeys/broker.toml
[auth]
methods = ["wallet_sig", "email_link"]    # v0 default

[wallet]
provisioner = "client_side_keystore"      # v0 default

[audit]
anchor = "sqlite"                          # v0 default
sqlite_path = "/var/lib/agentkeys/audit.sqlite"

# v1 example: Solana audit anchor
# [audit]
# anchor = "solana_program"
# rpc_url = "https://api.mainnet-beta.solana.com"
# program_id = "AgEntKeysAudt..."
# fee_payer_keystore = "/etc/agentkeys/audit_fee_payer.json"

# v2 example: Heima TEE wallet provisioner
# [wallet]
# provisioner = "heima_tee"
# tee_jsonrpc_url = "https://dex-api.heima.network"
# client_id = "agentkeys"
# tee_rsa_pubkey_path = "/etc/agentkeys/heima_pubkey.pem"
```

Plug-ins live in `crates/agentkeys-broker-server/src/plugins/`:

```
plugins/
├── auth/
│   ├── wallet_sig.rs        ← v0
│   ├── email_link.rs        ← v0
│   ├── oauth2.rs            ← v1
│   ├── passkey_local.rs     ← v1.5
│   └── passkey_tee.rs       ← v2 (Heima)
├── wallet/
│   ├── client_side.rs       ← v0
│   ├── smart_contract_aa.rs ← v1.5
│   ├── heima_tee.rs         ← v2 (Heima)
│   └── aws_nitro.rs         ← v2 (alternative)
└── audit/
    ├── sqlite.rs            ← v0 (already shipped, port to trait)
    ├── solana.rs            ← v1
    ├── ethereum_l2.rs       ← v1.5
    ├── heima_parachain.rs   ← v2
    └── s3_object_lock.rs    ← v2
```

Each plug-in is self-contained — its dependencies (e.g. `solana-sdk`, `webauthn-rs`, `jsonrpsee`) are feature-gated in `Cargo.toml` so deployments compile in only what they enable. Operators running v0 don't link in Solana / WebAuthn / Heima crates.

## Concretely, what changes vs the previously-saved plans

The saved plan (`regarding-docs-dev-setup-md-http-dev-set-fuzzy-sphinx.md`) is now **Option A — port dexs-backend**. The comparison plan (`agentkeys-broker-port-vs-greenfield.md`) frames A vs B with both Heima-coupled. This new plan introduces **Option C — pluggable, Heima-deferred**.

Decision tree:

- If we want maximum architectural future-flexibility and minimum upstream dependency risk → **C**.
- If we want fastest battle-tested production-grade behavior and accept Heima coupling → **A**.
- If we want greenfield design but committed to Heima as the spine → **B**.

## Recommendation

**Option C, with v0 shipping in 4–5 weeks.**

Reasoning:

1. **The user's "沉没成本" framing applies to Heima itself, not just dexs-backend.** Both A and B treat Heima as the spine of AgentKeys. Heima may well be the right canonical TEE for *some* deployments (Litentry-aligned, OmniAccount-needing, China-jurisdiction-using), but it's the wrong dependency to bake into the v0 critical path.

2. **Architecture.md §11 already established the principle** for one of the three layers (audit). Extending it to wallet provisioning and attestation is consistent with the spec, not a new direction.

3. **Litentry coordination is a real cost.** Every week we wait on a patch is a week AgentKeys can't ship. C decouples our v0 from their cycle entirely. We can engage them later for v2 with a precise ask informed by what we actually built.

4. **The plug-in catalog matches AgentKeys' actual operator personas.** A self-hosted small team doesn't want Solana fees on every mint; a crypto-native dev tool doesn't want Heima geographic concerns; an enterprise deployment may want SOC2-friendly S3 Object Lock. C lets each operator choose.

5. **Solana audit anchor for v1 is straightforward.** ~200 LOC Anchor program + ~600 LOC Rust client + ~300 LOC tests. Public, cheap, fast, no Litentry-dependent. Architecture.md §11 lists it explicitly.

6. **C's v0 LOC is ~1500 vs A's ~10,000 vs B's ~8,800.** Order of magnitude smaller because we drop password/TOTP/trading-fields/pumpx-callback-surface AND defer Heima/wallet-provisioning complexity to v2.

7. **The escape hatch is clean.** If for some reason C runs into a wall, we can fall back to A's port (the saved plan still works as written; we just don't recommend it) or escalate to B (also still valid as written).

## What needs deciding

Before any code lands:

1. **Confirm Option C** as the active plan (or override toward A or B with explicit reasoning).
2. **v0 plug-in selection**:
   - Auth: `WalletSig + EmailLink` (proposed) vs `WalletSig only` (smaller).
   - Wallet: `ClientSide` (proposed; CLI generates mnemonic) vs deferred entirely (only wallet-sig users have wallets in v0).
   - Audit: `SqliteAnchor` (proposed; already shipped) — no real alternative for v0.
3. **Solana program ownership** for v1's `SolanaProgramAnchor`. Either:
   - AgentKeys deploys + maintains the program ourselves (operationally simple, single point of trust).
   - Per-deployment: each operator deploys their own audit program (more sovereign, more setup work).
4. **Naming**: the prior comparison plan's `agentkeys-broker-port-vs-greenfield.md` becomes a "rejected alternatives" reference. The saved plan `regarding-docs-dev-setup-md-http-dev-set-fuzzy-sphinx.md` either gets archived or rewritten to describe C's v0.

## Files this plan would create / modify (when we're ready to implement)

**v0 — new in `crates/agentkeys-broker-server/`:**
- `src/plugins/{mod,auth,wallet,audit}.rs` — trait definitions + dispatch.
- `src/plugins/auth/{wallet_sig,email_link}.rs`.
- `src/plugins/wallet/client_side.rs` (broker side: receives the address, has no key access).
- `src/plugins/audit/sqlite.rs` (port the existing audit logic to trait shape).
- `src/identity/omni_account.rs` (deterministic SHA256 derivation, AgentKeys-native `client_id`).
- `src/storage/{accounts,wallets,grants}.rs` (OmniAccount-keyed schema; the same one from Option B's plan).
- `src/config.rs` — TOML-loaded plug-in config.
- `src/jwt/{issue,verify}.rs` — JWT issuance (HS256 for v0; can swap to TEE-RSA when v2 lands without changing API).
- `src/mailer.rs` — SES wrapper for `email_link`.

**v0 — new in `crates/agentkeys-cli/`:**
- `src/cmd_init.rs` (rewrite) — subcommands `wallet`, `email`. Generates mnemonic for client-side keystore mode.

**v0 — modifications:**
- `crates/agentkeys-broker-server/Cargo.toml` — add `k256`, `bip39`, `bcrypt`(?), `oauth2`, `jsonwebtoken`, `lettre` (or aws-sdk-sesv2). Remove anything unused.
- `crates/agentkeys-cli/Cargo.toml` — add `bip39`, `k256`, `eth-keystore`.

**v0 — docs:**
- `docs/agentkeys-broker-plugin-architecture.md` (new) — explains the three layers + plug-in catalog + per-deployment selection.
- `docs/agentkeys-broker-auth-api.md` (new) — HTTP/RPC contract.
- `docs/dev-setup.md` (housekeeping changes from the original plan: §3 role table, §4 self-mint framing, §8 troubleshooting).
- `docs/operator-runbook.md` §1.1 — drop the "stub-backend caveat" entirely; replace with "v0 ships with `WalletSig + EmailLink + ClientSide + SQLite` plug-ins by default."
- `docs/spec/architecture.md` §11 — extend from "audit destination is pluggable" to "auth, wallet provisioning, and audit are all pluggable behind plug-in traits."

**v1 — adds (`crates/agentkeys-broker-server/`):**
- `src/plugins/audit/solana.rs`.
- `solana-program/agentkeys-audit/` — new on-chain program (Anchor framework).
- `src/plugins/auth/oauth2.rs`.

**v2 — adds (when Heima patch lands):**
- `src/plugins/wallet/heima_tee.rs`.
- `src/plugins/audit/heima_parachain.rs`.
- `src/plugins/auth/passkey_tee.rs`.
- Upstream `litentry/heima` patch for `CLIENT_ID_AGENTKEYS`.
