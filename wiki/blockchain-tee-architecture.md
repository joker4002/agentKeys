# Blockchain + TEE Architecture: how AgentKeys splits state and computation

AgentKeys uses two infrastructure layers — a Heima parachain and a TEE (Trusted Execution Environment) worker — with a clear separation of responsibilities. This page explains what each layer does, how they interact, and why the split looks the way it does. Two concrete flows (credential retrieval and pairing) are worked through end-to-end. A comparison with the pure-TEE-backend alternative (Heima's existing dexs-backend model) is included at the end.

Companion docs:

- `[wiki/key-security.md](./key-security.md)` — two-tier storage model, session vs credential security
- `[wiki/serve-and-audit.md](./serve-and-audit.md)` — audit submission patterns (Pattern 4), latency analysis, fee funding

---

## 1. The two layers and their roles

### Blockchain (Heima parachain)

The blockchain is the **single source of truth** for all persistent state. It is an append-only, publicly verifiable, tamper-evident ledger that every participant can read and no single party can rewrite.

**What it stores (on-chain state):**


| Data                                                                  | Pallet / storage             | Who writes                     | Who reads                                           |
| --------------------------------------------------------------------- | ---------------------------- | ------------------------------ | --------------------------------------------------- |
| OmniAccount records (wallet address, linked identities)               | `pallet-omni-account`        | TEE (on account creation)      | TEE, CLI, block explorer                            |
| Session records (pubkey, scope, TTL, parent, revocation status)       | New AgentKeys pallet         | TEE (on session mint / revoke) | TEE (on every credential read)                      |
| Credential blobs (encrypted ciphertext, keyed by owner/agent/service) | `pallet-secrets-vault` (new) | TEE (on `store_credential`)    | TEE (on `read_credential`)                          |
| Pair requests (daemon_pubkey, scope, alias, valid_until)              | New AgentKeys pallet         | TEE (on pair request open)     | TEE (on master fetch / approve)                     |
| Pair approvals (encrypted child session, master signature)            | New AgentKeys pallet         | TEE (on approval)              | TEE (daemon reads approval)                         |
| Audit events (credential reads, stores, revocations, pair events)     | New AgentKeys pallet         | TEE (async, paymaster-funded)  | Block explorer, Subsquid indexer, `agentkeys usage` |
| Wallet USDC balances (x402 payment rail)                              | EVM / `pallet-evm`           | x402 protocol                  | Agents, billing system                              |


**What it does NOT do:**

- Decrypt anything (no private keys on chain)
- Execute business logic beyond simple checks (TTL validation, revocation flags, scope matching are one-line pallet checks)
- Hold any plaintext credentials (only ciphertext encrypted to the TEE shielding key)

**Properties the chain provides:**

- **Immutability** — once a block is finalized, its contents cannot be altered
- **Public verifiability** — anyone with a node or block explorer can verify any event
- **Tamper evidence** — forging an audit event requires breaking the validator consensus
- **Ordering** — all events have a canonical block-height ordering
- **TTL enforcement** — pallet logic can reject extrinsics based on block number vs `valid_until`
- **Replay protection** — substrate nonce system prevents extrinsic replay

### TEE (Trusted Execution Environment) worker

The TEE is a **stateless computation oracle**. It reads chain state, performs cryptographic operations (decryption, signing, session minting), and returns results. It holds no persistent state of its own — if the TEE restarts, it loses nothing, because everything it needs is on chain.

**What it holds (TEE-internal, sealed/persistent):**


| Data                                         | Lifetime                                                                        | How generated                                                                             | Purpose                                                                                   |
| -------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Shielding keypair                            | Permanent (sealed storage, pubkey registered on chain via `register_enclave()`) | Generated at enclave startup                                                              | Encrypt/decrypt credential blobs                                                          |
| RSA JWT signing key                          | Permanent (stored as PKCS#1 DER file)                                           | `RsaPrivateKey::new(&mut rng, 2048)` — randomly generated, NOT derived from a master seed | Sign auth token JWTs issued to clients                                                    |
| Per-user custodial wallet keys (BTC/ETH/TON) | Permanent (sealed, per `pallet-bitacross` pattern)                              | Generated per account creation, independently per user                                    | Sign on-chain extrinsics on behalf of user wallets. Private key never leaves the enclave. |
| AES response keys                            | Ephemeral (per-request)                                                         | From `RequestAesKey` parameter                                                            | Encrypt sensitive responses to specific clients                                           |
| Chain state cache (optional)                 | ≤ 1 block (~6s)                                                                 | Read from chain                                                                           | Performance optimization. Not authoritative — chain is truth.                             |


> **Correction (verified against Heima source 2026-04-12):** The TEE holds **multiple independent keys**, not a single master seed with HD derivation. The RSA JWT key, shielding key, and per-user wallet keys are each generated independently and stored separately. OmniAccount *addresses* are deterministically derived (`OmniAccountConverter::convert(&identity, &client_id)`), but the underlying *private keys* are not HD-derived.

**What it does:**

- **Decrypt credential blobs** — reads encrypted ciphertext from chain state, decrypts with shielding key, returns plaintext to authorized callers
- **Issue auth tokens (JWTs)** — on successful authentication (Passkey/OAuth/Web3 signature), the TEE signs a JWT containing `{sub: omni_account, typ: ACCESS, exp: timestamp, aud: client_id}` with its RSA private key. The client holds this JWT as a bearer token. Verification is stateless (RSA pubkey check + expiration check).
- **Verify auth tokens** — on every subsequent call, the TEE validates the client's JWT signature and expiration. No session table needed — JWT verification is stateless.
- **Enforce scope** — reads session/account scope from chain, rejects requests outside the scope
- **Sign extrinsics** — signs audit events, pair requests, approvals, session management using the user's wallet private key (TEE-held), submits to chain via paymaster
- **Rate limit** — enforces per-session read rate caps (connection-level state, not persistent)

**What it does NOT do:**

- Store session records (chain does; JWT is stateless)
- Store credential blobs (chain does)
- Store pair requests or approvals (chain does)
- Maintain an audit log (chain does)
- Return private keys to clients (clients receive JWTs, not keypairs)

**Properties the TEE provides:**

- **Confidentiality** — plaintext credentials exist only inside the enclave during decryption; no external process can read them
- **Integrity** — the TEE's code is attested (DCAP/EPID); a modified TEE worker is detectable
- **Fast computation** — decryption + signature verification in ~10-50ms, no chain round-trip on the hot path
- **Signing authority** — the TEE holds wallet private keys and can sign extrinsics as the user without per-call user involvement

### How they interact: the division of labor

```
┌──────────────────────────────────┐     ┌──────────────────────────────────┐
│         BLOCKCHAIN (Heima)       │     │         TEE WORKER               │
│                                  │     │                                  │
│  Single source of truth          │     │  Stateless computation oracle    │
│                                  │     │                                  │
│  Stores:                         │     │  Holds (sealed):                 │
│  - Account records               │◄────│  - Shielding private key         │
│  - Credential blobs (encrypted)  │     │  - RSA JWT signing key           │
│  - Pair requests / approvals     │     │  - Per-user wallet private keys  │
│  - Audit events                  │     │                                  │
│  - Wallet balances               │     │  Does:                           │
│                                  │────►│  - Reads chain state             │
│  Enforces:                       │     │  - Decrypts credential blobs     │
│  - TTL (valid_until checks)      │     │  - Issues + verifies JWTs        │
│  - Replay protection (nonces)    │     │  - Signs extrinsics (as user)    │
│  - Revocation (flag checks)      │     │  - Rate limits                   │
│  - Immutability (finalized)      │     │  - Submits extrinsics async      │
│                                  │     │    (paymaster-funded)            │
└──────────────────────────────────┘     └──────────────────────────────────┘
         ▲          │                              │         ▲
         │          │ read state                   │         │
         │          ▼                              │         │
         │    ┌──────────┐                         │         │
         │    │ CLI /    │◄────────────────────────┘         │
         │    │ Daemon   │ plaintext / ACK / VVC             │
         │    └──────────┘                                   │
         │          │                                        │
         └──────────┘ signed extrinsics (via TEE + paymaster)│
                                                             │
         ┌──────────┐                                        │
         │ Paymaster│ funds audit + pair extrinsic fees ─────┘
         └──────────┘
```

The core pattern: **clients talk to the TEE, the TEE talks to the chain.** Clients never read chain state directly for credential operations (the TEE is the decryption gateway). Clients CAN read chain state directly for public data (audit events, session status, pair requests).

---

## 2. Worked example: credential retrieval

> **Status:** this example shows the **v0.1** flow (Pattern 4: TEE-as-paymaster per-read sponsored audit). v0 uses the mock backend with a synchronous SQLite audit insert — see `docs/spec/plans/development-stages.md` Stage 1 for the v0 implementation. Pattern 4 is tracked in [#5](https://github.com/litentry/agentKeys/issues/5).

This is the most common operation. An agent daemon needs an API key to call OpenRouter.

### Step-by-step

```
1. daemon → TEE: read_credential(agent=0x44d3, service=openrouter)
   authenticated by: JWT (bearer token, issued by TEE on pairing)

2. TEE verifies JWT:
   - RSA signature valid against TEE's public key? ✅
   - exp > current time? ✅ (not expired)
   - sub = 0x44d3 (matches the requesting agent)? ✅

3. TEE reads chain state:
   a. Account record for agent 0x44d3
      → exists? ✅
      → scope includes "openrouter"? ✅
   b. Credential blob for (owner=0x9c3e, agent=0x44d3, service=openrouter)
      → encrypted ciphertext (256 bytes)

4. TEE decrypts credential blob with shielding private key
   → plaintext: "sk-or-v1-abc123..."

5. TEE returns plaintext to daemon over wss response (~50ms total)

6. TEE builds audit extrinsic (DECOUPLED from the response):
   { wallet: 0x9c3e, agent: 0x44d3, service: openrouter,
     action: read, result: success, timestamp: ... }
   signed by: user's wallet key (TEE-held)
   submitted via: paymaster (AgentKeys operator funds, Option A)

7. ~6s later: audit extrinsic confirmed on chain
   → event visible on block explorer, indexed by Subsquid
```

### What the blockchain did

- **Stored** the session record (step 2a) — this is how the TEE knows the session is valid
- **Stored** the encrypted credential blob (step 2b) — this is the data the TEE decrypts
- **Received** the audit extrinsic (step 7) — this is the tamper-evident read record
- **Enforced** nothing on the hot path — the TEE read chain state and made the decisions. The chain just holds the data.

### What the TEE did

- **Read** chain state to verify session validity and fetch the credential blob
- **Verified** the session signature cryptographically
- **Decrypted** the credential blob (only the TEE can do this — the shielding private key is inside the enclave)
- **Returned** the plaintext to the authorized caller
- **Submitted** the audit extrinsic asynchronously (the caller didn't wait for this)

### What nobody stored

- The TEE did not cache the credential blob or the session record. On the next `read_credential` call, it reads chain state again.
- The daemon holds the plaintext in memory during the MCP response, then (under Stage 8 hardening) wipes it immediately after delivery to the agent.

---

## 3. Worked example: pairing (on-chain transport — v0.1 target)

> **Status:** this example shows the **v0.1** on-chain pair transport. v0 uses a centralized rendezvous relay (SQLite `rendezvous_registrations` + `auth_requests` tables, 6 REST endpoints) — see `docs/spec/plans/development-stages.md` Stage 1 for the v0 implementation. The v0.1 migration is tracked in [#6](https://github.com/litentry/agentKeys/issues/6).

A new daemon in a sandbox wants to pair with the master user's wallet. This is the on-chain pair design from `[docs/spec/plans/development-stages.md](../docs/spec/plans/development-stages.md)` Stage 9.

### Step-by-step

```
Phase 1 — Daemon opens pair request

1. daemon generates ephemeral keypair (daemon_pubkey, daemon_privkey)

2. daemon builds pair request payload:
   { daemon_pubkey, scope: [openrouter, anthropic],
     alias: "my-sandbox-agent", parent_wallet: 0x9c3e,
     valid_until: current_block + 10 }

3. daemon signs the payload with daemon_privkey → signature S

4. daemon → TEE: submit signed pair request
   TEE validates signature ✅
   TEE submits pair request extrinsic to chain via paymaster
   TEE returns ACK to daemon (~50ms)

5. daemon locally derives VVC = decimal(SHA256(S))[..6] = "472915"
   (NOT on chain — purely client-side derivation from the signature)

6. daemon displays:
   "Pair request submitted. Confirming on chain..."
   "Verification code: 472915"
   "Scope: openrouter, anthropic"

7. ~6s later: chain confirms pair request extrinsic
   → pair request stored in pallet state with valid_until
   → daemon updates display: "Confirmed. Run `agentkeys approve`."
```

```
Phase 2 — Master approves

8. user runs: agentkeys approve

9. master CLI → TEE: fetch pending pair requests for wallet 0x9c3e
   TEE reads chain state: finds pair requests where
     parent_wallet = 0x9c3e AND valid_until > current_block
   TEE returns list (~50ms)

10. master CLI displays:
    [1] Verification: 472915 | Scope: openrouter, anthropic
        Alias: my-sandbox-agent | Expires in: 45s
    user compares VVC with daemon display → matches → picks [1]

11. user confirms y

12. master CLI → TEE: approve pair request #1
    TEE reads pair request from chain state
    TEE mints child session:
      - generates session keypair (child_session_pubkey, child_session_privkey)
      - scope = pair request's requested scope
      - TTL = 3600s
      - parent = master's session
    TEE encrypts child session private key to daemon_pubkey
    TEE builds approval extrinsic:
      { pair_request_id, encrypted_child_session,
        child_session_pubkey, child_wallet, scope, ttl }
    TEE submits approval extrinsic to chain via paymaster
    TEE returns "Approved" to master CLI (~50ms)

13. TEE also submits session-creation extrinsic:
    { child_session_pubkey, child_wallet, scope, ttl, parent_session }
    → chain stores new session record in pallet state
```

```
Phase 3 — Daemon receives child session

14. ~6s later: chain confirms approval extrinsic + session-creation extrinsic

15. daemon reads chain events filtered by target_daemon_pubkey = its pubkey
    → finds approval event with encrypted_child_session payload

16. daemon decrypts encrypted_child_session with daemon_privkey
    → obtains child_session_privkey

17. daemon stores child_session_privkey locally
    (OS keychain when available per [#12](https://github.com/litentry/agentKeys/issues/12),
     file fallback at ~/.agentkeys/daemon-<wallet>/session.json mode 0600;
     runtime copy held in memfd_secret under Stage 3 hardening)

18. daemon starts serving MCP calls
    → every call signed with child_session_privkey
    → TEE verifies against child_session_pubkey in chain state
```

### What the blockchain did

- **Stored** the pair request (step 7) — publicly visible, with `valid_until` field
- **Enforced** TTL — the pallet rejects approval extrinsics where `current_block > valid_until` (step 12, pallet-level check)
- **Stored** the approval + encrypted child session (step 14) — the daemon reads this from chain
- **Stored** the new session record (step 13/14) — future credential reads verify the child session against this record
- **Emitted** events for pair-request-opened, pair-request-approved — audit trail

### What the TEE did

- **Validated** the daemon's signature on the pair request (step 4)
- **Read** chain state to find pending pair requests (step 9)
- **Minted** a child session keypair (step 12) — only the TEE can do this because it holds the master's wallet key
- **Encrypted** the child session to the daemon's pubkey (step 12) — confidential delivery over a public channel (the chain)
- **Signed** the approval and session-creation extrinsics using the master's wallet key (step 12-13)
- **Submitted** extrinsics via paymaster (step 12-13)

### What nobody stored

- The TEE did not store the pair request, the approval, or the child session. It processed and submitted. Chain holds everything.
- After step 16, the daemon holds the child session private key locally. The encrypted version is on chain but only the daemon can decrypt it.

### OTP (v0) vs VVC (v0.1) — two different verification codes

The pair flow uses two distinct human-verification codes at different stages of AgentKeys. They are NOT the same primitive; v0 uses OTP, v0.1 uses VVC. Issue [#6](https://github.com/litentry/agentKeys/issues/6) tracks the v0 → v0.1 migration.

| Property | **OTP** (v0, Stages 0/1/4) | **VVC** (v0.1, on-chain pair) |
|---|---|---|
| Derivation | `HMAC(nonce, canonical_CBOR(request_details))` | `decimal(SHA256(pair_request_signature))[..6]` |
| Where computed | Backend (mock server); also re-derivable client-side from the same inputs | Purely client-side, from the on-chain extrinsic signature |
| Server-validated? | Yes — stored in `auth_requests` table, single-use enforced | No — server holds no OTP state; any client derives the same VVC from the same signature |
| Threat it defends against | Tampered request details between `open` and `approve` (canonical-hash mismatch rejects the approval) | Decoy pair requests on-chain — multiple pending pairs look the same, VVC lets the user visually tiebreak |
| Shipped in | v0 mock backend (current code) | v0.1 on-chain pair transport (not yet implemented) |
| Referenced in | `development-stages.md` Stages 0, 1, 4; `otp::determinism` test | `development-stages.md` Stage 9; [#6](https://github.com/litentry/agentKeys/issues/6) |

v0.1 does **not** keep OTP: with on-chain pair transport, there is no `auth_requests` table to hold nonces, and tamper detection comes from extrinsic signature verification at the pallet level. VVC replaces OTP as the human-visible code; the security property (protect against request-detail tampering and decoy daemons) shifts from OTP's HMAC-of-details to the pallet's signature check + VVC's signature-fingerprint comparison.

---

## 4. Bearer token lifecycle (JWT model, verified against Heima source)

> **Status:** this describes the **v0.1** Heima TEE bearer token (JWT format). v0 uses an opaque random-bearer string stored in the mock backend's SQLite `sessions` table — see `wiki/session-token.md` §8 for the v0 vs v0.1 comparison table.
>
> **Terminology:** AgentKeys calls this a **bearer token** ([#10](https://github.com/litentry/agentKeys/issues/10)); Heima-internal code keeps "JWT" / `AuthTokenClaims`. We don't rename Heima.
>
> **Correction (2026-04-12):** An earlier version of this section described a "session keypair" model where the TEE mints a session keypair and returns the private key to the client. Verification against the actual Heima source (`tee-worker/omni-executor/core/src/auth/auth_token.rs`) shows that Heima uses **JWT-based stateless bearer tokens**, not session keypairs. The client holds a signed JWT string, not a private key. This section has been rewritten to match the actual implementation.

Auth tokens (JWTs) are the connective tissue between client identity and TEE operations. They are **stateless** — the TEE verifies them cryptographically on every call without maintaining a session table.

### Token issuance

```
client authenticates (Passkey / Google OAuth / Web3 signature)
  ↓
client sends signed request_auth_token trusted call to TEE
  (signed with client's own identity key — Web3 wallet, Passkey, etc.)
  ↓
TEE verifies client's identity signature
  ↓
TEE creates/looks up OmniAccount
  (address deterministically derived: OmniAccountConverter::convert(&identity, &client_id))
  ↓
TEE signs a JWT with its RSA private key:
  AuthTokenClaims {
    sub: "0x9c3e..." (omni account, hex-encoded),
    typ: "ACCESS",
    exp: now + 30 days (AgentKeys policy via AuthOptions.expires_at; Heima SDK default is ~24h),
    aud: "HEIMA" (client ID)
  }
  ↓
TEE returns JWT string to client
  ↓
client stores JWT locally
  (a plain string — NOT a private key. Can go in a file, env var, or OS keychain.
   No keyring-rs, no memfd_secret, no special protection beyond file permissions.)
```

### Token verification (on every call)

```
client sends request + JWT to TEE
  ↓
TEE verifies JWT:
  1. RSA signature valid? (RSA pubkey derived from TEE's sealed privkey)
  2. exp > current time? (not expired)
  3. aud matches expected client ID? (audience check)
  4. typ matches expected token type? (ACCESS vs ID)
  ↓
all pass → extract sub (omni account) → proceed with operation
any fail → reject (401 unauthorized)
```

**No session table, no chain read for auth.** JWT verification is a pure cryptographic check: RSA signature + field validation. The TEE does not maintain a sessions table, does not read chain state to verify the token, and does not need to look up the token in any database. This is the key difference from the session-keypair model described in earlier specs.

Chain state IS still read for **scope** and **credential blobs** — but not for auth token validity.

### Token expiration and refresh

```
client's JWT expires (exp < current time)
  ↓
client must re-authenticate (Passkey / OAuth / Web3 signature)
  ↓
TEE issues a new JWT
  ↓
client replaces old JWT with new one
```

There is no "refresh token" in the current Heima implementation. Expiration means re-auth. The `AuthOptions.expires_at` field controls the TTL — **AgentKeys policy is 30 days** (set via `AuthOptions.expires_at`); the Heima client SDK default is ~24h. See [#10](https://github.com/litentry/agentKeys/issues/10) for terminology context.

### Revocation

JWT-based auth has an inherent tradeoff with revocation. Since JWTs are stateless and self-contained, the TEE cannot "revoke" a JWT by flipping a flag — the token is valid until it expires.

Revocation options for AgentKeys v0.1:

1. **Short-lived JWTs + frequent re-auth.** If the JWT TTL is 15 minutes, a revoked agent's token becomes invalid within 15 minutes. No server-side state needed.
2. **On-chain revocation list.** TEE reads a revocation list from chain state on every call (adds ~1-5ms). A revoked agent's `sub` (omni account) is on the list → TEE rejects even though the JWT signature is valid. This gives ~6s revocation latency (one block to update the chain list).
3. **TEE-side deny list (bounded cache).** TEE holds a small in-memory deny list of revoked accounts, updated from chain events. Not persistent — survives only until TEE restart. Fastest revocation (~0ms) but weakest durability.

Option 2 (on-chain revocation list) is the most consistent with the "chain is single source of truth" architecture and meets the spec requirement from `heima-open-questions.md Q9` (revocation latency ≤ 1 block). The TEE checks `chain_state.revoked_accounts.contains(jwt.sub)` on every call, adding minimal latency.

```
master CLI → TEE: revoke_agent(agent_account=0x44d3)
  authenticated by: master's JWT
  ↓
TEE reads chain state: master owns (is parent of) agent? ✅
  ↓
TEE submits revocation extrinsic:
  revoked_accounts.insert(0x44d3)
  ↓
~6s: chain confirms
  ↓
next call by the revoked agent:
  TEE verifies JWT → valid ✅
  TEE reads chain state → 0x44d3 in revoked_accounts → REJECT
```

**Revocation latency = 1 block (~6s).**

---

## 5. Comparison: stateless TEE + chain vs pure TEE backend

Two architectures for the same product. AgentKeys is choosing the left column; Heima's existing dexs-backend uses the right column.

### Architecture overview


|                      | **AgentKeys v0.1: Stateless TEE + chain**                                             | **dexs-backend: Pure TEE backend (Heima's existing model)** |
| -------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| **Session state**    | Stateless JWTs (signed by TEE, verified cryptographically) + on-chain revocation list | Stateless JWTs (same mechanism — both use `auth_token.rs`)  |
| **Credential blobs** | On-chain encrypted (`pallet-secrets-vault`)                                           | TEE-internal encrypted storage                              |
| **Audit log**        | On-chain events (signed extrinsics)                                                   | TEE-internal log or centralized DB                          |
| **Pair state**       | On-chain pallet storage                                                               | TEE-internal or centralized DB                              |
| **TEE role**         | Stateless computation oracle (decrypt, sign, verify)                                  | Stateful server (holds sessions, credentials, logs)         |
| **Source of truth**  | Blockchain (publicly verifiable)                                                      | TEE-internal state (operator-verifiable via attestation)    |


### Property-by-property comparison


| Property                          | Stateless TEE + chain                                                                                                            | Pure TEE backend                                                                                                                                                         |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Tamper evidence**               | ✅ Strong. Chain is append-only, validator-attested. An operator cannot rewrite audit history.                                    | ⚠️ Moderate. TEE attestation proves the code is correct, but the TEE operator controls the enclave lifecycle. A restart with modified sealed data could rewrite history. |
| **Public verifiability**          | ✅ Anyone with a node or block explorer can verify any event. No trust in the operator required for audit.                        | ❌ Only the TEE operator (or someone with the attestation report) can verify. Users trust the operator to run the correct code.                                           |
| **Revocation latency**            | ~6s (1 block). TEE reads fresh chain state on every request.                                                                     | ~0ms (in-memory flag flip). TEE updates its own session table immediately.                                                                                               |
| **Credential read latency**       | ~50ms (TEE reads chain state via local RPC + decrypts).                                                                          | ~10ms (TEE reads its own internal storage + decrypts).                                                                                                                   |
| **Session verification latency**  | ~1-5ms (chain state read via local RPC).                                                                                         | ~0.1ms (in-memory lookup).                                                                                                                                               |
| **Recovery on TEE restart**       | ✅ Trivial. TEE re-reads chain state. Nothing lost.                                                                               | ⚠️ Complex. TEE must restore from sealed storage or DB backup. If sealed data is corrupted, state is lost.                                                               |
| **Multi-TEE scaling**             | ✅ Easy. Any TEE instance reads the same chain state. No inter-TEE state sync needed.                                             | ⚠️ Hard. Multiple TEE instances need state replication or a shared DB, introducing consistency problems.                                                                 |
| **Credential availability**       | Depends on chain liveness. If Heima halts, no credential reads.                                                                  | Depends on TEE liveness. If TEE is up, credentials are available regardless of chain status.                                                                             |
| **Offline operation**             | ❌ No. Every read requires chain state access.                                                                                    | ✅ Possible (TEE holds everything locally).                                                                                                                               |
| **Chain fees**                    | Yes. Every write (store, revoke, audit) costs gas. Paymaster-funded under Option A.                                              | No chain fees for operations. Only chain writes for explicit on-chain events (if any).                                                                                   |
| **Code complexity**               | Lower TEE code (stateless processor). Higher pallet code (state management).                                                     | Higher TEE code (stateful server + session management + credential storage + audit log). Lower pallet code.                                                              |
| **Auditability of operations**    | ✅ Every operation is a chain event. Forensic investigation reads the block explorer.                                             | ⚠️ Depends on the TEE's internal log implementation. If the log is centralized, the operator controls it.                                                                |
| **Data portability / exit story** | ✅ If Heima disappears, the full audit history and session state are preserved on any chain replica. Users can fork and continue. | ❌ If the TEE operator disappears, the TEE-internal state is gone (unless separately backed up and the backup is portable).                                               |
| **Consistency model**             | Strong consistency for writes (chain finality). Bounded staleness for reads (≤ 1 block cache).                                   | Strong consistency for everything (in-process).                                                                                                                          |


### When the pure TEE backend wins

The pure TEE backend is strictly better for:

1. **Latency-critical workloads.** In-memory session lookups (~~0.1ms) and in-TEE credential reads (~~10ms) are 5-50x faster than chain state reads. For applications doing thousands of credential reads per second, the chain-read overhead matters.
2. **Offline / air-gapped environments.** If the agent sandbox has no network access to a Heima node, the pure TEE backend can still serve credentials from its internal storage. The stateless TEE + chain model requires chain connectivity.
3. **Instant revocation.** The pure TEE backend can revoke a session in microseconds (flip an in-memory flag). The chain model takes ~6s. For applications where a 6-second revocation window is unacceptable, the pure TEE wins.
4. **Zero chain fees.** No paymaster needed, no gas costs, no operational dependency on a funded treasury account.

### When the stateless TEE + chain wins

The stateless TEE + chain is strictly better for:

1. **Public audit.** The chain model's audit log is tamper-evident and publicly verifiable by anyone with a block explorer. The pure TEE model's audit is operator-controlled. This is AgentKeys's core differentiator against 1Password.
2. **Multi-party trust.** If the user doesn't fully trust the TEE operator (e.g., in a multi-tenant hosted deployment), the chain provides an independent verification layer. The user can verify their own audit trail without trusting the operator.
3. **Multi-TEE scaling.** Adding TEE instances to handle load requires no state replication — every instance reads the same chain state. The pure TEE model requires inter-instance state sync, which is a distributed systems problem.
4. **Recovery and portability.** TEE restarts lose nothing. Chain forks preserve everything. The exit story is clean.
5. **Regulatory compliance.** Some jurisdictions require tamper-evident audit trails for credential management. On-chain events satisfy this without additional infrastructure. TEE-internal logs may not, depending on the regulatory framework.
6. **Architectural simplicity of the TEE.** A stateless oracle is easier to audit, test, and reason about than a stateful server. The TEE code surface is smaller, and the attack surface is narrower.

### Why AgentKeys chose the stateless TEE + chain model

Three reasons, in weight order:

1. **"Every credential access is a public, signed, block-included event that no one can erase"** is the product's headline security claim (`heima-cli-exploration.md:85`). This is what 1Password structurally cannot offer. The pure TEE backend doesn't deliver this claim — its audit is operator-controlled.
2. **Consistency with Pattern 4.** The credential-read, credential-store, pairing, session-management, and audit flows all follow the same pattern: TEE reads chain state → processes → returns to client → submits extrinsic async via paymaster. One architecture for everything. The pure TEE backend would require maintaining two state stores (TEE-internal for hot-path data, chain for audit), which is architecturally the worst of both worlds.
3. **The latency cost is acceptable.** Credential reads add ~~40ms of chain-state-read overhead vs the pure TEE model (50ms vs 10ms). Revocation takes ~6s vs ~0ms. For AgentKeys's target workload (dozens to hundreds of reads per hour per agent, not thousands per second), neither difference is perceptible. The specs explicitly accept the ~6s revocation window (`heima-open-questions.md Q9: "≤ 1 Heima block (~~6s)"`) and the ~50ms read latency (`heima-cli-exploration.md:116` acknowledges the latency tradeoff).

### Hybrid optimization: bounded-staleness cache

A pragmatic middle ground exists without violating "chain is single source of truth":

```
TEE reads chain state on first request → caches locally
cache TTL = 1 block (~6s)
subsequent requests within the same block → served from cache
cache miss → re-read from chain
```

This gives:

- First request in a block: ~5ms (chain state read via local RPC)
- Subsequent requests in the same block: ~0.1ms (local cache hit)
- Revocation latency: still ≤ 1 block (cache expires, fresh read sees revocation)
- Consistency: bounded staleness of ≤ 6s, same as the already-accepted revocation window

The cache is explicitly a **performance optimization**, not authoritative state. If the cache says "session is valid" but the chain says "revoked," the worst case is one block of stale reads — the same window the spec already accepts. The chain is always the tiebreaker.

This gets the per-read latency down to pure-TEE-backend levels for hot-path reads while preserving the chain-is-truth architecture.

---

## 6. Summary: the three rules

> **Corrected 2026-04-12** after verifying against the actual Heima source code (`litentry/heima` on GitHub). The previous version of rule #3 stated "clients hold only their own private keys" — this was wrong. Clients hold JWTs (bearer tokens), not private keys. All private keys live inside the TEE.

The entire AgentKeys v0.1 architecture follows three rules:

1. **Chain stores everything persistent.** Account records, credential blobs (encrypted), pair requests, approvals, audit events, wallet balances, revocation lists. The chain is the single source of truth. If the TEE restarts, if the daemon crashes, if the user switches devices — chain state is always there.
2. **TEE holds all private keys and does all computation.** The TEE holds the shielding key, the RSA JWT signing key, and per-user custodial wallet keys (per `pallet-bitacross` pattern). These are generated independently (not derived from a single master seed) and sealed inside the enclave. The TEE decrypts credential blobs, issues and verifies JWTs, signs on-chain extrinsics using the user's wallet key, and enforces scope + rate limits. No private key ever leaves the TEE.
3. **Clients hold only a JWT (bearer token), not private keys.** The master CLI and agent daemon each hold a JWT string issued by the TEE upon authentication. The JWT is a signed bearer token (`AuthTokenClaims { sub, typ, exp, aud }`), not a private key. However, it IS still a bearer credential — anyone with the string can impersonate the user until it expires. **OS keychain is the recommended default** for the master CLI (provides app-level ACL against malware-as-same-user). Plain file (mode 0600) is an acceptable fallback for daemon/sandbox/CI where keychain isn't available. If the JWT leaks, the blast radius is bounded by its expiration time (~~24h) and the on-chain revocation list (~~6s). If the JWT expires, the client re-authenticates and gets a new one.

Every flow in the system (credential store, credential read, pairing, revocation, audit query) is an instance of:

```
client sends request + JWT to TEE
  → TEE verifies JWT (RSA signature + expiration)
  → TEE reads chain state (scope, credential blob, revocation list)
  → TEE computes (decrypt, sign, mint)
  → TEE returns result to client
  → TEE submits audit extrinsic to chain async (paymaster-funded, signed with user's wallet key)
```

No exceptions.

---

## 7. References

### Spec documents

- `[docs/spec/tech-brief.md](../docs/spec/tech-brief.md)` — v0/v0.1 split, TEE shielding key, pallet-bitacross pattern
- `[docs/spec/1-step-analysis.md](../docs/spec/1-step-analysis.md)` — session key tiers, Connect flow, storage choices
- `[docs/spec/heima-cli-exploration.md](../docs/spec/heima-cli-exploration.md)` — per-call signing, audit-as-extrinsic, latency acknowledgement
- `[docs/spec/heima-open-questions.md](../docs/spec/heima-open-questions.md)` — Q1 (scoped session minting), Q3 (TEE-side scope enforcement), Q9 (revocation latency)
- `[docs/spec/credential-backend-interface.md](../docs/spec/credential-backend-interface.md)` — CredentialBackend trait, signing model, payment rails
- `[docs/spec/plans/development-stages.md](../docs/spec/plans/development-stages.md)` — Stage 9 design decisions (Pattern 4, on-chain pair transport)

### Wiki

- `[wiki/key-security.md](./key-security.md)` — two-tier storage, daemon credential lifecycle, hardening layers
- `[wiki/serve-and-audit.md](./serve-and-audit.md)` — Pattern 4 audit submission, five-pattern comparison, fee funding, rate limiting, pair transport

### Issues

- [#3](https://github.com/litentry/agentKeys/issues/3) — Stage 8: Production hardening
- [#4](https://github.com/litentry/agentKeys/issues/4) — TEE-side per-session read rate limit
- [#5](https://github.com/litentry/agentKeys/issues/5) — Pattern 4 audit submission (TEE-as-paymaster)
- [#6](https://github.com/litentry/agentKeys/issues/6) — On-chain pair transport

