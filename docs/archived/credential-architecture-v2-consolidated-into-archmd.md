# AgentKeys credential architecture (v2 target)

**Status**: Forward-looking design doc. Captures the v2/v3 architectural endpoint for credential storage, fetch, encryption, and trust decomposition. Extends [`architecture.md`](architecture.md) — does not replace it. Names follow arch.md §3a canonical-names rules verbatim.

**Scope**:
- How credentials are stored at rest
- How agents fetch and use credentials
- How master grants and revokes scope
- Roles of each component (daemon, broker, signer, workers, chain)
- Trust decomposition such that no single component compromise is sufficient

**Out of scope** (covered elsewhere):
- Wire-format specs (separate spec docs per component)
- Migration plan from today's #87 → v2 (covered by phased issues)
- Specific blockchain choice (operator-deployment decision; Litentry chain is the natural default per project home)

---

## 1. Goals

1. **No single trust root is sufficient for credential access.** Compromising any one of {master wallet, daemon device-key, broker K1, signer K3, chain validators} yields bounded blast radius, not total credential exposure.

2. **The agent process is treated as adversarial.** Compromised agents cannot extract credential bytes; they can at most use credentials through the daemon's localhost proxy under quota and scope controls.

3. **Master is the only scope-mutation authority.** Scope grants and revocations are signed by a master device's K10 + fresh K11 WebAuthn assertion (hardware-attested user-presence), submitted via meta-tx relay (msg.sender = relay-wallet, master_wallet stays off chain). The broker has zero mutation power.

4. **The broker is reduced to a thin authority.** It mints scope-bounded cap-tokens (signed jointly with the requesting daemon's device-key) but does not hold scope state, does not touch credential bytes, and does not produce credentials unilaterally.

5. **Per-component compromise isolation.** Splitting credential decryption, memory R/W, audit appends, and email send into independent workers means compromising one worker does not compromise the others' data classes.

6. **Pluggability preserved.** Same component roles work with AWS Lambda + KMS, Cloudflare Workers + R2, Tencent SCF + COS, or self-hosted microservices. No vendor lock-in.

---

## 2. Five trust roots, each independently bounded

| # | Trust root | Controls | Compromise blast radius | Lives in |
|---|---|---|---|---|
| 1 | **Master wallet** (chain identity) | Scope mutations, recovery, master-key rotation initiation | Attacker changes on-chain scope; visible, revocable via master-recovery; bounded to what scope can authorize | Operator custody (hardware wallet ideal; otherwise signer-derived under master's actor_omni) |
| 2 | **Daemon device-key** (per-host) | Cap-mint requests (no cap mints without device-key signature) | Per-sidecar; attacker can mint caps within that sidecar's scope, bounded by `cred_cache_ttl` window | TPM / Secure Enclave / TEE / fallback file (mode 0600) |
| 3 | **Broker K1** | Cap counter-signature; session JWT signing | Alone cannot mint usable caps (missing device-sig); can sign session JWTs within scope but workers cross-check chain | Broker process (eventually HSM / TEE / threshold-signed) |
| 4 | **Signer K3** (TEE-protected) | K4 derivation (master_wallet keypair), KEK derivation | Catastrophic for credentials if extracted — all KEKs derivable | Inside TEE enclave (AMD SEV-SNP / Intel TDX / AWS Nitro); attested boot |
| 5 | **Chain** (Litentry / EVM L2) | Scope storage (sole authority), sidecar device-key registry, audit anchors, credential-update history | Chain-level attack required (51% on chosen chain); bounded by chain security properties | Distributed across chain validators |

**Key property**: any *single* compromise yields bounded damage. Even broker-K1 compromised + chain compromised still requires sidecar device-keys to mint usable caps; even signer-K3 compromised (catastrophic for credentials) is mitigated by TEE seal + attestation requirement.

---

## 3. Component roles

### 3.0 Identity primer — master vs agent, K10/K11, and the actor_omni binding

Before any component description, the foundational identity facts. **v2 adopts arch.md §3a's K10/K11 vocabulary directly** rather than inventing parallel concepts; the only v2 extension is per-device `roles` (CAP_MINT / RECOVERY / SCOPE_MGMT) for multi-master-device deployments.

#### Per-actor keys (from arch.md §3a)

| Key | Purpose | Storage | Per-actor scope |
|---|---|---|---|
| **K3** | Signer's master secret; all wallet + KEK derivation | TEE enclave (signer, attested) | One per signer/broker deployment |
| **K10** | Device key (D_priv) — per-request signature on signer + cap-mint calls | OS keychain on each device (TouchID-backed on master, file-backend on agent) | One **per device** (laptop has K10_LAPTOP, phone has K10_PHONE, …) |
| **K11** | WebAuthn platform-authenticator credential — hardware-attested user-presence proof for binding ceremonies | Sealed in Secure Enclave / TPM / StrongBox; cannot be exfiltrated even by host-OS root | One **per master device** (agents don't hold K11 per §5a) |
| K1, K2, K4–K9 | Broker session-signing key, OIDC, derived wallets, JWTs — see arch.md §3a | Per arch.md | Various |

K10 + K11 together form a per-device authentication pair: **K10 signs every request** (high-frequency, biometric-free for daily use), **K11 is invoked only for binding ceremonies** (low-frequency, biometric-gated for new-device bind, K10 rotation, etc.). This is the same architectural pattern as Apple Account / Google Account device management.

#### Master vs agent device tiers (per arch.md §5a)

Per arch.md §5a: master devices hold K11 (WebAuthn-capable hardware — laptop with Touch ID, phone with Face ID, etc.); **agent devices do not hold K11** (Linux VMs, CI sandboxes, Raspberry Pis — anything without a platform authenticator). The two tiers have completely different bootstrap paths:

```
Master device bootstrap (arch.md §5 stages 0–3):
  Stage 0  K10 generated locally on device                              (no network)
  Stage 1  Identity ceremony (email-link / OAuth2 / EVM SIWE)            (master ↔ broker)
  Stage 2  WebAuthn binding — K11 generated, commits D_pub atomically    (master ↔ platform authenticator)
  Stage 3  Wallet derivation + SIWE → J1                                 (master ↔ broker ↔ signer)

Agent device bootstrap (arch.md §5a.2 — link-code only):
  Stage 0  K10 generated locally on agent                                (no network)
  Stages 1+2+3 collapsed:
    Master mints a one-time link code (master holds J1, signs link-code request)
    Agent redeems link code at broker; broker mints J1_agent
  → no identity ceremony on agent, no WebAuthn on agent, no SIWE on agent
```

Why this matters for recovery: **only master devices participate in K11-anchored recovery**, because only they have a hardware-attested credential. Agent devices can be revoked or re-issued via master action without affecting the operator's identity.

#### The master/agent omni tree (arch.md §4)

All wallets in one operator's deployment derive from K3, but via different omnis:

```
K3 (signer TEE)
 │
 ├─ HKDF(K3, master_omni)                         → master_wallet (operator's primary EVM address)
 │
 ├─ HKDF(K3, master_omni // "agent-A")            → wallet_agent_A   (per-agent HDKD child)
 ├─ HKDF(K3, master_omni // "agent-B")            → wallet_agent_B
 └─ ...
```

Throughout this doc, `operator_*` refers to the master (whose scope tree is indexed), `agent_*` refers to a consuming child (could be the master itself for own-cred access, or a real agent device).

#### actor_omni binding (arch.md §3a — `once SIWE-bound`)

`actor_omni = SHA256("agentkeys" || "evm" || master_wallet)` per arch.md §3a, frozen at first SIWE-bind (Stage 3 of bootstrap). **It does NOT rotate with K3** — the binding is durable. K3 rotation produces a new current_master_wallet for the operator, but actor_omni stays the value computed from the K3_v1-epoch master_wallet.

This works because the signer holds the historical K3 epochs (lazy migration; old K3 retained in TEE for decrypt of pre-rotation blobs until they're re-encrypted on read), so the original master_wallet remains reconstructible during the migration window. After the migration window, the actor_omni is just an opaque 32-byte ID — the signer maps it to the current K3 epoch's derived wallet on demand.

Net: `actor_omni` is the **durable identity**, used everywhere externally visible — chain (scope, registry, audit), AWS PrincipalTag (`agentkeys_actor_omni`), S3 path (`bots/<actor_omni_hex>/...`), cap-token addressing. `current_master_wallet` exists **only transiently inside the signer** for the brief lifecycle of an AWS STS round-trip; it's never persisted as identity material and never appears on a public chain (rev 4 §6). **K11** on each registered master device is the **recovery anchor** (no separate hardware wallet, no seed phrase).

### 3.1 Daemon (sidecar)

The user-facing local component. Replaces today's `agentkeys-daemon` MCP host with an expanded role.

**Responsibilities**:
- Holds the **device-keypair** in TPM / SE / TEE / fallback file. Never sent to broker or signer.
- Generates fresh device-keypair at first bootstrap; registers `device_pubkey` on-chain via SidecarRegistry.
- Exposes localhost HTTP proxy at:
  - E1: Unix socket `$XDG_RUNTIME_DIR/agentkeys-proxy.sock` (SO_PEERCRED gates callers)
  - E2: pod-internal `localhost:9090` (network namespace gates callers)
  - E3: TEE-internal IPC (enclave gates callers)
- Caches plaintext credentials in memory with `cred_cache_ttl` (default 5 min); zeroes on TTL expiry or drop event.
- Mints cap-fetch requests (signs with device-key) when agent first requests an unloaded credential.
- Forwards agent's localhost calls to upstream APIs (e.g., `https://api.openrouter.ai/...`) with `Authorization: Bearer <plaintext>` injected.
- Enforces controls before any proxy operation:
  - **Caller authentication**: SO_PEERCRED (E1), pod identity (E2), TEE caller pin (E3)
  - **Per-caller scope binding**: `(caller_uid, binary_path) → allowed_services`
  - **Service/method/path allowlist**: e.g., only `POST /v1/chat/completions` for openrouter
  - **Spend quotas**: per-caller token bucket on req/min, req/hour, daily $ budget
  - **Per-call audit**: row to local log + ship to chain audit anchor
  - **Fail-closed on stale broker**: if `now - last_broker_event > stale_threshold` (60s), refuse new fetches
- Receives drop events from broker over SSE; atomically purges affected credentials.
- Writes `~/.config/agentkeys/env` with proxy URLs + placeholder auth tokens; user sources from shell rc once.

**NOT responsible for**:
- Holding K3, K1, or master_wallet's private key
- Mutating scope (master does this directly on-chain)
- Decrypting credentials (workers do this)
- Reading S3 credentials prefix (no IAM grant)

### 3.2 Broker (cap-minter + auth-relay)

The thinnest possible broker. Today's broker minus everything that can be moved out.

**Responsibilities**:
- Verifies cap-mint request's `sidecar_sig` against on-chain SidecarRegistry
- Reads scope from on-chain ScopeContract (NOT from broker DB)
- Co-signs caps with K1 (cap = `{request, sidecar_sig, broker_sig}`)
- Pushes drop events to daemons over SSE when on-chain scope changes
- Relays interactive auth flows that can't go on-chain:
  - Email-link auth (SMTP gateway → daemon poll → confirm)
  - OAuth2 (HTTP callback → bind to actor_omni)
- For v3+: produces ZK proofs of cap-mint correctness against on-chain scope at block N

**NOT responsible for**:
- Holding scope state (chain does this)
- Decrypting credentials (workers do this)
- Touching credential bytes (workers do this)
- Signing user data with K3 (signer does this)
- Mutating scope (master does this on-chain)

### 3.3 Signer (K3 vault, TEE-protected, rev 4 with K10/K11/epoch verification)

Per arch.md §13 and issue #74 step 2 — K3 lives inside a TEE enclave (AMD SEV-SNP, Intel TDX, AWS Nitro). Worker access only via mTLS post-attestation.

**Responsibilities**:

*K3 / wallet / KEK derivation* (signer-internal):
- Holds **historical K3 epochs** (`K3_v[1]`, `K3_v[2]`, …, `K3_v[current]`) inside attested enclave; never exports any K3 epoch in plaintext form. Old epochs retained for as long as ciphertext under them may need decrypt (lazy migration window) plus a configurable grace period.
- Derives K4 = `HKDF(K3_v[epoch], actor_omni)` for SIWE / EIP-191 signing under any omni
- Derives per-user KEK = `HKDF(K3_v[epoch], "agentkeys.user.v1" || actor_omni)` for credential encryption
  - **v2 ships per-user KEK** (one KEK per (actor_omni, K3 epoch); all of one user's credentials under one K3 epoch share a KEK)
  - Per-(user, service) KEK is tracked as a future hardening — see §10 future work
- Derives current_master_wallet = `HKDF(K3_v[current_epoch], O_master)` **on demand** for AWS STS calls; never persisted as identity material outside the STS call's brief lifecycle.

*Chain-epoch verification* (rev 4 — Codex finding #4):
- On every typed call (`/derive-cred-kek`, `/sign/siwe`, `/sign/audit-row`, etc.), signer FIRST reads `K3EpochCounter.current_epoch` from chain and verifies:
  - The requested `k3_epoch` parameter is `<= current_epoch` (no future-epoch reads)
  - For write/encrypt operations, the requested `k3_epoch == current_epoch` (no encrypting under stale K3)
- A signer that's stale (its local view of the chain is behind) MUST refuse operations under "current" epoch until it has caught up. This prevents a partitioned or rolled-back signer from continuing to mint creds under an obsolete K3.

*K10/K11 verification* (rev 4 — Codex finding #2):
- Signer is the system component that knows what K10/K11 should look like for each registered device (it reads SidecarRegistry on chain or via a broker-relayed view).
- Exposes verification helpers:
  - `/verify/k10-sig` — verify a K10 device-key signature over a payload
  - `/verify/k11-assertion` — verify a WebAuthn assertion over a payload against the registered cred_id
  - Workers and brokers call these instead of re-implementing crypto verification; this concentrates the verification surface in the TEE.

*Exposed typed RPC over mTLS* (caller = broker or worker only — never a daemon directly):
- `/sign/siwe` — typed SIWE message signing under a specified `(actor_omni, k3_epoch)`
- `/sign/audit-row` — typed audit-row signing (one-shot cap-bound)
- `/derive-cred-kek` — typed KEK derivation under `(actor_omni, k3_epoch)`; signer verifies chain epoch first
- `/sts-credentials` — derives the transient master_wallet and signs the STS round-trip; only `/sts-credentials` ever uses a wallet form internally and the wallet never crosses the mTLS boundary out
- `/verify/k10-sig` and `/verify/k11-assertion` — verification helpers

**NOT responsible for**:
- Authorization decisions for credential CRUD (workers gate scope checks before reaching signer; signer only verifies cap signatures, not scope contents)
- Storage of ciphertext (workers handle S3)
- User-facing operations (broker / daemon)
- Source-of-truth for K3 epoch (chain `K3EpochCounter` is authoritative — signer is a derivation cache, not a source)

**Critical property (rev 4 — Codex #4 defense)**: workers always verify chain K3EpochCounter independently before trusting any signer response that depends on K3 epoch. A stale/compromised signer cannot escalate by lying about the current epoch — the worker's own chain read catches it. The signer's chain-epoch check is defense in depth (independent verification of the same fact).

### 3.4 Workers (per-service)

Each data-class gets its own worker — independent IAM, independent deploy lifecycle, independent compromise blast radius.

| Worker | Purpose | Inputs | IAM minimum | One-shot cap? | master_wallet on chain? |
|---|---|---|---|---|---|
| `credentials-service` | Encrypt and decrypt API credentials | cap-token + (read: service-name; write: plaintext + service-name) | `s3:GetObject` / `s3:PutObject` on `bots/<actor_omni_hex>/credentials/*`; signer mTLS for KEK | Cred-fetch: TTL-bounded (≤5 min, multi-use); cred-store: one-shot | **No** (S3 only, no chain interaction) |
| `memory-service` | R/W agent state in S3 | cap-token + (S3 key + body for writes) | `s3:GetObject` / `s3:PutObject` on `bots/<actor_omni_hex>/memory/*` | TTL-bounded | **No** (S3 only) |
| `audit-service` | Append to audit log + on-chain anchor | cap-token + audit-row | `s3:PutObject` on `bots/<actor_omni_hex>/audit/*`; chain tx submitter for anchor | One-shot per audit-row | **Depends on tier** — see audit-tier table below |
| `email-service` | Send / receive on behalf of operator | cap-token + email payload | `ses:SendRawEmail` from operator's domain | One-shot per send | **No** (SES only, no chain) |
| **`payment-service`** | Execute payments on operator's behalf — irreversible upstream operations | cap-token + payment intent (recipient, amount, asset, idempotency_key) | Service-account wallet (P-1 default) OR escrow contract (P-2) OR direct operator-key signer call (P-3) | **STRICT one-shot CAS-burn required** — payment is irreversible; replay = double-spend | **Depends on mode** — see payment-mode table below |

(S3 paths key on `actor_omni` per rev 4 §6 — stable across K3 rotation, AWS PrincipalTag = `agentkeys_actor_omni`.)

### audit-service — sovereignty tiers + wallet-exposure trade-off

| Tier | Substrate | master_wallet on chain? | Operator chain footprint | Trust model |
|---|---|---|---|---|
| **A — Hosted shared relay** (default) | Service provider runs relay; batches across MANY operators; Merkle root on chain | **No** — only service-relay-wallet appears, shared across operators | Zero per-operator activity visible | Operator trusts service to not OMIT events (chain-anchored root catches forgery; omission detectable via Merkle proof of expected leaf) |
| **B — Self-hosted relay** (privacy-preserving sovereignty) | Operator runs own audit-relay binary; relay-wallet (NEW wallet generated at deployment time, NOT K3-derived) signs batches | **No** — operator's relay-wallet appears, but it's a separable burner wallet not linked to master_wallet | Per-deployment relay-wallet activity (correlatable as "alice's relay deployment", but master_wallet stays off chain) | Operator owns the relay; no third-party trust needed |
| **C — Direct-write per event** (maximum sovereignty, **breaks wallet privacy**) | Daemon submits each audit event as separate chain tx, signed by master_wallet's signer-derived key | **YES** — master_wallet (or a K3-derived signing key trivially linkable to it) signs every audit tx | master_wallet exposed on every audit event; historical activity profile public forever | Operator fully self-custodial; pays per-event gas; **accepts privacy regression for trustlessness** |

**Architectural property**: tiers A and B preserve rev 4's "master_wallet never on chain" property. Tier C deliberately breaks it. Operators choosing C should know the trade-off. Tier B is the actual "self-sovereign without wallet exposure" — operator controls both ends without exposing master_wallet.

### payment-service — modes + wallet-exposure trade-off

| Mode | Wallet that signs payments | master_wallet on chain? | Trust model | Best for |
|---|---|---|---|---|
| **P-1 — Service-account-wallet** (default) | Service-operated payment-pool wallet; operator pre-deposits funds | **Once at deposit, then never** | Operator trusts service-wallet operator with custody of deposit float; mitigated by multisig or TEE-attested smart contract holding the pool | Routine LLM API payments (low value, high frequency) |
| **P-2 — On-chain escrow + signer-signed redemption** | Operator's master_wallet deposits to escrow contract once; payment-service redeems via signer-signed token | **Once at deposit, then escrow contract is the visible mover** | Operator controls escrow contract; signer signs each redemption with operator's K3-derived key (signer-internal; signature visible on chain but not the master_wallet directly) | Medium-value payments where operator wants self-custody without ongoing master_wallet exposure |
| **P-3 — Direct from operator wallet** | master_wallet directly signs each payment tx | **EVERY payment** | Operator fully custodial; payments fully transparent on chain | High-value one-off payments where ON-chain transparency is required (audit/compliance); operators who don't care about pseudonymity |

**Default: P-1 (service-account-wallet)** for routine workloads. Operator pre-deposits to service-pool; subsequent payments draw from pool with the operator's cap-token authorizing each draw. Chain observer sees `payment-service-pool-wallet → recipient` with no operator-specific information.

Mitigations against service-operator misappropriating the pool:
- Pool is multisig (M-of-N across service operators + ideally one operator-controlled signer)
- TEE-attested smart contract holds the pool; releases only on cap-token redemption
- Operator self-hosts payment-service (operator IS the service-wallet operator — defeats trust delegation but preserves privacy via wallet separation from master_wallet)

### payment-service — security constraints (all modes)

Payment is structurally different from other workers because its upstream effect is **irreversible** (a USDC transfer or a Stripe charge can't be unsent). Three properties payment-service MUST enforce regardless of mode:

1. **Strict one-shot CAS-burn semantics.** Every payment cap carries a unique nonce. Broker mints, payment-service redeems with atomic compare-and-swap. Replay attempts get `cap_already_consumed`. Per [§10 future work — one-shot CAS-burn caps].
2. **Tight spend quotas per scope grant.** Scope entry for payment-service includes `max_per_call` + `max_per_period` (per day/week/month) + `max_total`. Quotas enforced at broker on cap-mint AND at payment-service on cap-redeem (defense in depth).
3. **Two-signature for high-value payments.** Payments above an operator-configured threshold require K11 user-presence at cap-mint time, even though the daemon is normally K10-only for daily ops. Operator sets the threshold; payment-service rejects any high-value cap that lacks a K11 assertion.

Wire shape:

```
payment-service /v1/pay
  Body: { cap: {request, k10_sig, broker_sig, k11_assertion_if_high_value},
          payment_intent: {recipient, amount, asset, idempotency_key, memo} }

payment-service:
  1. Verify cap signatures (K10 + broker_sig)
  2. If payment_intent.amount > operator.k11_threshold:
       verify cap.k11_assertion is present and valid over payment_intent hash
       (rejects if just K10 — high-value payments require user-presence)
  3. CAS-burn cap.nonce against payment-service's burn-table
  4. Quota check: spend_window[operator_omni].current + amount <= scope.max_per_period
  5. Execute payment:
     - On-chain: signer.sign_payment_tx(payment_key, payment_intent) → broadcast
     - Stripe: charge via stored Stripe key (decrypted from credentials-service for this call)
  6. Record audit event: PaymentExecuted(operator_omni, recipient, amount, asset,
                                         idempotency_key, tx_hash, k3_epoch)
  7. Return receipt

The cap's `idempotency_key` is checked first against payment-service's local cache: if
the same idempotency_key was processed in the last N hours, return the same receipt
without re-executing. This is upstream-API idempotency, not replay protection — replay
protection comes from CAS-burn on cap.nonce.
```

The payment-service IAM should hold credentials-service mTLS so it can fetch operator-signed payment keys at call time (for Stripe-style integrations). For on-chain payments, the signer directly produces the signature via the existing `/sign/...` typed endpoints — payment-service doesn't hold any keys itself.

**Common worker behavior**:
- Verify cap's `sidecar_sig` against on-chain SidecarRegistry
- Verify cap's `broker_sig` against broker's K1 pubkey (JWKS)
- Verify on-chain scope independently (don't trust broker's claim about scope)
- Execute service operation
- Emit audit row (CloudWatch / local log + chain-anchored batch)

**Implementations** (operator chooses per deployment):
- AWS Lambda + API Gateway (managed, AWS-native)
- Self-hosted Rust microservice (vendor-neutral, axum-based, similar to broker)
- Cloudflare Worker + R2 (edge / global; for memory + audit)
- Tencent Cloud SCF + COS (China deployment)

### 3.5 Chain (single source of truth)

The chain stores all slow-changing high-value state. Implementations:
- **Litentry chain** (project home, default for v2)
- **EVM L2** (Base, Optimism, Arbitrum) — if operator prefers Ethereum ecosystem
- **Solana** — if low-latency confirmation is critical

**On-chain state** — three contracts (down from earlier rev's four; ActorRegistry eliminated per Q3 in rev 4 — signer is source of truth for omni→current_wallet, chain has only the global K3 epoch counter for verification):

```solidity
contract AgentKeysScope {
    mapping(bytes32 => mapping(bytes32 => Scope)) public scope;
    // scope[operator_omni][agent_omni] = {services, read_only, updated_at}
    struct Scope { string[] services; bool read_only; uint256 updated_at; }

    event ScopeUpdated(bytes32 indexed operator_omni, bytes32 indexed agent_omni,
                       string[] services, bool read_only);

    // CALLED VIA META-TX. Master-only mutation — REQUIRES K11 WEBAUTHN ASSERTION,
    // NOT just K10 device-key signature (per codex finding #2 / arch.md §5/§5a).
    function set_scope_with_webauthn(
        bytes32 operator_omni, bytes32 agent_omni,
        string[] calldata services, bool read_only,
        bytes calldata k10_device_sig,        // K10 sig over payload (operational binding)
        bytes calldata k11_webauthn_assertion // K11 hardware-attested user presence (master proof)
    ) external {
        bytes32 payload_hash = keccak256(abi.encode(operator_omni, agent_omni,
                                                    services, read_only, block.timestamp));
        require(_verify_k10(operator_omni, payload_hash, k10_device_sig),  "bad K10 sig");
        require(_verify_k11(operator_omni, payload_hash, k11_webauthn_assertion),
                "missing K11 user-presence");
        scope[operator_omni][agent_omni] = Scope(services, read_only, block.timestamp);
        emit ScopeUpdated(operator_omni, agent_omni, services, read_only);
    }
}

contract SidecarRegistry {
    mapping(bytes32 => DeviceBinding) public device;  // device_pubkey_hash -> binding
    // Codex finding #1 fix: binding is per-(device, actor_omni). A device key is
    // bound to ONE specific actor (master OR one specific agent), not to a whole
    // operator's worth of agents. This enforces arch.md §5a.5 containment:
    // compromised agent K10 can mint caps as THAT agent only, never as siblings.
    struct DeviceBinding {
        bytes32 operator_omni;   // who owns the agent (for scope-table lookup)
        bytes32 actor_omni;      // WHICH actor this device serves (could == operator_omni for master devices)
        uint8   tier;            // 1=master-with-K11, 2=agent-no-K11, 3=TEE-sealed-agent
        uint8   roles;           // bitfield: CAP_MINT (0x01) | RECOVERY (0x02) | SCOPE_MGMT (0x04)
        bytes32 k11_cred_id;     // WebAuthn credential ID — zero/empty for agent devices (no K11)
        bytes   attestation;     // K11 WebAuthn attestation (master) or device attestation (agent)
        uint256 registered_at;
    }

    event DeviceRegistered(bytes32 indexed device_pubkey_hash,
                           bytes32 indexed operator_omni, bytes32 indexed actor_omni,
                           uint8 tier, uint8 roles);

    // Master-device registration — REQUIRES K11 WebAuthn (master proves human presence).
    // For first device of a new operator (bootstrap): identity-ceremony binding_nonce
    // also required to prove identity-control (anti-rebind, arch.md §5a.1 Q7 fix).
    // For subsequent master devices: existing master's K11 authorizes the new bind.
    function register_master_device(
        bytes32 device_pubkey_hash,
        bytes32 operator_omni, bytes32 actor_omni,    // master devices: actor_omni == operator_omni
        bytes32 k11_cred_id, bytes calldata attestation,
        uint8 roles,
        bytes calldata authorization_proof   // bootstrap: identity_ceremony binding_nonce + WebAuthn over (binding_nonce || D_pub)
                                            // subsequent: existing master's K11 sig + new device's WebAuthn
    ) external { /* verifies + writes + emits */ }

    // Agent-device registration — link-code redeem flow (arch.md §5a.2).
    // Authorized by a master via one-time link code, NOT by the agent itself.
    // Agent has no K11.
    function register_agent_device(
        bytes32 device_pubkey_hash,
        bytes32 operator_omni, bytes32 actor_omni,    // agent's labeled actor_omni
        bytes calldata link_code_redemption,           // signed by a master's K11
        bytes calldata agent_pop_sig                   // agent's K10 proof-of-possession
    ) external { /* verifies + writes + emits with k11_cred_id = 0 */ }

    function lookup(bytes32 device_pubkey_hash) external view returns (DeviceBinding memory) {
        return device[device_pubkey_hash];
    }
}

// Codex finding #4 fix — global K3 epoch on chain.
// Replaces the proposed-but-now-eliminated per-actor ActorRegistry. One single
// counter for the entire deployment. Workers verify signer's claimed epoch
// against this counter before trusting any KEK derivation or omni→wallet lookup.
contract K3EpochCounter {
    uint256 public current_epoch;          // monotonically increasing
    address public signer_governance;      // multisig that controls K3 rotation

    event K3Rotated(uint256 indexed new_epoch, uint256 effective_block);

    function bump_epoch() external {
        require(msg.sender == signer_governance, "unauthorized");
        current_epoch++;
        emit K3Rotated(current_epoch, block.number);
    }
}

contract CredentialAudit {
    event CredentialUpdated(bytes32 indexed operator_omni, string indexed service,
                            bytes32 blob_hash, bytes32 updater_actor_omni, uint256 k3_epoch);
    event CapMintedBatch(bytes32 merkle_root, uint256 block_number, uint256 count);
    // Workers (or audit-service relay) emit in batches. Each leaf includes
    // {actor_omni, action_hash, device_sig}. Chain sees no master_wallet ever.
}
```

**Codex-finding-driven design properties**:

| Codex finding | How this rev addresses it |
|---|---|
| **#1 — device-to-actor binding** | `DeviceBinding` stores `actor_omni` per device. Cap verification at workers requires `device.actor_omni == request.agent_omni`. Agent K10 compromise contained to that one agent — cannot mint as sibling agents under the same operator. |
| **#2 — K11 enforcement for master mutations** | Master-only mutations (`set_scope_with_webauthn`, `register_master_device`) verify K11 WebAuthn assertion in addition to K10 device sig. K10 alone (no biometric / hardware-presence) cannot mutate scope or bind devices. arch.md §5a Q7 property preserved. |
| **#3 — K3 rotation breaks S3 reads** | **See §6 + §7 rev 4**: S3 path is keyed on `actor_omni` (stable, never rotates), not on `current_master_wallet` (K3-rotation-changing). AWS PrincipalTag uses `agentkeys_actor_omni` instead of `agentkeys_user_wallet`. **K3 rotation triggers ZERO S3 path migration.** Blobs stay at the same S3 path forever. Only the in-blob `k3_epoch` byte tells the signer which K3 epoch to HKDF under for KEK derivation. |
| **#4 — chain-as-source-of-truth for K3 epoch** | `K3EpochCounter` is the authoritative current K3 epoch. Workers fetch it from chain (cached briefly, ≤1 block confirmation latency) and require any signer response to be consistent with it. Stale or rolled-back signer that claims an older epoch is rejected by the worker before any KEK derivation happens. |

**Operations** (all via meta-tx through relay-service wallets; master_wallet never appears as `msg.sender`):
- `ScopeContract.set_scope_with_webauthn(...)` — master signs payload with K10 + provides K11 assertion; relay submits
- `SidecarRegistry.register_master_device(...)` — master init (bootstrap) or new-device add (§5a.3.1); K11 required
- `SidecarRegistry.register_agent_device(...)` — agent bootstrap via master-issued link code (arch.md §5a.2); no K11
- `K3EpochCounter.bump_epoch()` — called once per K3 rotation by signer-governance multisig; affects all operators simultaneously
- `CredentialAudit.{CredentialUpdated, CapMintedBatch}` — audit-relay batches signed proofs from workers

---

## 4. Setup flows

### 4.1 Master device bootstrap (arch.md §5 stages 0-3, rev 4 aligned)

```
Operator runs: agentkeys init --email alice@gmail.com on master device

Stage 0 — Device-key (K10) generation [LOCAL, no network]
  Daemon generates (D_priv_DEVICE, D_pub_DEVICE) = K10_DEVICE in OS keychain
  (TouchID-backed on macOS; equivalent on Windows/Android master devices)
  No broker contact yet

Stage 1 — Identity ceremony [master only]
  CLI → broker: POST /v1/auth/email/request {email}
  Broker → CLI: {request_id, binding_nonce}
  Broker sends magic-link to alice@gmail.com
  Alice clicks → broker confirms single-use within TTL
  CLI: polls /v1/auth/email/status/<request_id> until verified

Stage 2 — Master binding ceremony (WebAuthn) [master only]
  CLI → Platform Authenticator (Touch ID / Face ID / Windows Hello):
    navigator.credentials.create({
      challenge: SHA256(binding_nonce || D_pub_DEVICE)
    })
  Alice presents biometric
  Platform Authenticator generates K11_DEVICE (WebAuthn cred, sealed in SE/TPM)
  Returns attestation (cred_id, attestation_obj)

  CRITICAL PROPERTY (arch.md §5a.1 Q7 fix): D_pub committed atomically inside
  the WebAuthn challenge. Email-account compromise alone CANNOT rebind a
  different D_pub to alice@gmail.com — attacker must also complete WebAuthn on
  Alice's physical device.

  CLI → broker: POST /v1/auth/bind/<request_id> {webauthn_attestation, D_pub_DEVICE}
  Broker verifies attestation; mints J0 with claims:
    - agentkeys_device_pubkey = D_pub_DEVICE
    - agentkeys_webauthn_cred = K11_DEVICE.cred_id

Stage 3 — Wallet derivation + SIWE → J1 [master only]
  CLI → signer (Bearer J0): /dev/derive-address {O_master}
  Signer returns: A = HKDF(K3_v[current_epoch], O_master)   [signer-internal wallet]
  CLI → broker: POST /v1/wallet/link {evm, A}
  CLI → broker: SIWE round-trip → broker mints J1
  CLI persists J1

At this point — FIRST master device of this operator:
  actor_omni_alice = SHA256("agentkeys" || "evm" || A)   (frozen at this moment, per §3.0)
                     where A = first signer-derived wallet at K3_v1
  Note: A is not stored anywhere as identity; only its hash becomes actor_omni.

Stage 4 (rev 4 extension) — On-chain SidecarRegistry binding [meta-tx]
  CLI submits to registry-relay:
    SidecarRegistry.register_master_device(
      device_pubkey_hash:    SHA256(D_pub_DEVICE),
      operator_omni:         actor_omni_alice,
      actor_omni:            actor_omni_alice,    // master device serves the master actor itself
      k11_cred_id:           K11_DEVICE.cred_id,
      attestation:           K11_DEVICE.attestation_obj,
      roles:                 CAP_MINT | RECOVERY | SCOPE_MGMT,   // first device gets all roles
      authorization_proof:   {binding_nonce, webauthn_assertion_over_payload}
    )
  Relay verifies attestation matches binding_nonce, submits tx, chain emits DeviceRegistered

Stage 5 — Local sidecar proxy spinup
  Daemon starts localhost proxy listener (Unix socket per §3.1)
  Daemon writes ~/.config/agentkeys/env with proxy URLs + placeholder auth tokens
  CLI nudges operator: "Add a 2nd master device for recovery"
```

### 4.1b Adding a 2nd master device (arch.md §5a.3.1 + rev 4 quorum extension)

```
On phone:
  Alice opens agentkeys mobile app
  App shows QR-scan UI
  Laptop CLI displays pairing QR:
    pairing_payload = { actor_omni: alice_omni, new_device_placeholder,
                        nonce, expires_at }
    pairing_sig_LAPTOP_K10 = sign(D_priv_LAPTOP, hash(pairing_payload))
    K11 user-presence: laptop prompts Touch ID for K11_LAPTOP assertion over pairing_payload

  Phone scans QR

  Stage 0 (on phone):
    Phone daemon generates (D_priv_PHONE, D_pub_PHONE) in Apple Secure Enclave

  Stage 2-equivalent (new-master-device flow):
    Phone requests Face ID → enrolls K11_PHONE (separate WebAuthn cred, phone-resident)
      WebAuthn challenge: SHA256(pairing_nonce || D_pub_PHONE)
    Phone → broker: POST /v1/auth/bind-new-master-device {
      authorization_proof_from_laptop: {K10_LAPTOP sig, K11_LAPTOP WebAuthn assertion},
      new_device_attestation: WebAuthn(K11_PHONE) over (pairing_nonce || D_pub_PHONE),
      D_pub_PHONE
    }
    Broker verifies BOTH:
      - laptop's authorization (K10 sig + K11 user-presence — proves an existing master authorized this)
      - phone's WebAuthn attestation (proves phone is a master with K11 + new D_pub bound atomically)
    Broker mints J1_PHONE

  Stage 4 — On-chain registration [meta-tx]:
    SidecarRegistry.register_master_device(
      device_pubkey_hash:  SHA256(D_pub_PHONE),
      operator_omni:       alice_omni,
      actor_omni:          alice_omni,   // also a master device serving the master actor
      k11_cred_id:         K11_PHONE.cred_id,
      attestation:         K11_PHONE.attestation_obj,
      roles:               CAP_MINT | RECOVERY,    // SCOPE_MGMT opt-in (default deny)
      authorization_proof: laptop's K11 assertion + binding_nonce
    )

  recovery quorum is now: any 1 of {laptop, phone} can authorize recovery
  (threshold = 1; can be bumped to 2 once a 3rd device is added)
```

### 4.1c Agent device bootstrap (arch.md §5a.2 — link-code only)

```
ON MASTER (Alice's laptop — already initialized with K11_LAPTOP + J1):
  Alice runs: agentkeys agent create --label agent-pi
  CLI: prompts Touch ID for K11_LAPTOP assertion (required for new-agent mint)
  CLI → broker: POST /v1/agent/create {
    parent_operator_omni: alice_omni,
    label: "agent-pi",
    k11_assertion_LAPTOP: WebAuthn over (parent_omni || label || nonce)
  }
  Broker derives O_agent_pi = master_omni // "agent-pi" (HDKD per arch.md §4)
  Broker derives actor_omni_agent_pi = SHA256("agentkeys"||"evm"||HKDF(K3_v[N], O_agent_pi))
  Broker mints link_code (one-time, TTL-bounded) bound to (actor_omni_agent_pi, alice_omni)
  CLI displays link_code to Alice

ON AGENT (Raspberry Pi):
  Operator runs: agentkeys init --link-code <link_code>
  Stage 0: Pi daemon generates (D_priv_PI, D_pub_PI) in Pi's fTPM or file backend
  Stage 1+2+3 collapsed (arch.md §5a.2):
    Pi → broker: POST /v1/auth/agent-bootstrap {
      link_code,
      D_pub_PI,
      pop_sig: sign(D_priv_PI, hash(link_code || D_pub_PI))
    }
    Broker verifies link_code valid + pop_sig proves PI holds D_priv_PI
    Broker mints J1_PI (no K11; agents don't have WebAuthn)

  Stage 4 — On-chain registration via agent-device flow:
    SidecarRegistry.register_agent_device(
      device_pubkey_hash:    SHA256(D_pub_PI),
      operator_omni:         alice_omni,
      actor_omni:            actor_omni_agent_pi,    // agent's OWN omni, not master's
      link_code_redemption:  master's K11_LAPTOP-signed link_code envelope,
      agent_pop_sig:         pop_sig
    )
    Chain records: device_pubkey_PI → (alice_omni, actor_omni_agent_pi,
                                       tier=2 [agent], roles=CAP_MINT only, no K11)

Net: agent K10 is bound to actor_omni_agent_pi SPECIFICALLY. The agent cannot
mint caps with another agent's actor_omni — even if scope[alice_omni][other_agent_omni]
includes openrouter, workers reject any cap from D_pub_PI whose request.agent_omni
isn't actor_omni_agent_pi. (Codex finding #1 containment property.)
```

### 4.2 Master grants scope to a child agent (rev 4 — K11 REQUIRED)

```
1. Master runs `agentkeys scope --agent <child_actor_omni> --add openrouter,anthropic`
   on a device with the SCOPE_MGMT role (laptop by default)
2. CLI builds payload:
     {operator_omni: alice_omni, agent_omni: child_actor_omni,
      services: ["openrouter","anthropic"], read_only: false,
      nonce, expires_at}
3. CLI signs payload with K10_LAPTOP (device key)
4. CLI prompts Touch ID → K11_LAPTOP signs WebAuthn assertion over payload
   (REQUIRED per Codex finding #2 / arch.md §5a — master mutations need user-presence)
5. CLI POSTs to scope-mutation-relay /v1/scope/set with:
     {payload, k10_sig: D_LAPTOP, k11_assertion: WebAuthn(K11_LAPTOP, payload)}
6. Relay verifies:
   - SidecarRegistry[D_pub_hash_LAPTOP] has SCOPE_MGMT role
   - K10 sig valid against D_pub_LAPTOP
   - K11 WebAuthn assertion valid against K11_LAPTOP.cred_id
7. Relay submits ScopeContract.set_scope_with_webauthn(...) tx
   (relay pays gas; msg.sender = relay-service-wallet)
8. Chain emits ScopeUpdated event after ~1-12s confirmation
9. Daemons + brokers subscribed to events update local views

Compromised K10 alone (without biometric on laptop) → step 4 fails → no scope mutation.
This preserves arch.md §5a Q7 property at the on-chain layer.
```

### 4.3 Master stores a new credential (rev 4 — actor_omni-keyed S3 path)

```
1. Master runs `agentkeys store openrouter sk-or-v1-...`
2. CLI mints cap-store request:
     {operator_omni: alice_omni, agent_omni: alice_omni, service: "openrouter",
      nonce, ttl, k3_epoch: <current from chain K3EpochCounter>}
   Signs with K10_LAPTOP
3. CLI POSTs to broker /v1/cap/cred-store with {request, k10_sig}
   (cred-store does NOT require K11 — store under one's own scope is daily-use,
    not a master-only mutation. Only scope MUTATIONS and DEVICE BINDINGS need K11.)
4. Broker:
   - Verifies k10_sig against SidecarRegistry[D_pub_hash_LAPTOP]
   - Verifies request.agent_omni == registry.actor_omni  (Codex finding #1 containment)
   - Verifies operator_omni in registry entry
   - Reads on-chain scope (alice_omni's own creds are always in scope)
   - co-signs with K1
   - returns cap = {request, k10_sig, broker_sig}
5. CLI POSTs to creds-service worker /v1/cred/store with {cap, plaintext}
6. Worker:
   - Verifies k10_sig + broker_sig
   - Verifies cap.request.agent_omni == registry[D_pub_hash_LAPTOP].actor_omni
   - Fetches K3EpochCounter.current_epoch from chain → call it E
   - Verifies cap.request.k3_epoch == E (reject if signer/broker tried to mint under stale epoch)
   - Calls signer mTLS: signer.derive_cred_kek(alice_omni, E)
   - Signer internal: kek = HKDF(K3_v[E], "agentkeys.user.v1" || alice_omni)
   - Returns 32-byte KEK to worker
   - AES-256-GCM seals plaintext:
     envelope = {version=0x04, k3_epoch=E, nonce, ciphertext, tag}
     AAD = "agentkeys.cred.aad.v2|" || alice_omni_hex || "|" || "openrouter"
   - Writes s3://$BUCKET/bots/<alice_omni_hex>/credentials/openrouter.enc
     (S3 path keys on actor_omni — STABLE across K3 rotation, wallet rotation, everything)
   - Submits audit via audit-service relay:
     CredentialAudit.CredentialUpdated(alice_omni, "openrouter", blob_hash, alice_omni, E)
7. Worker returns success
```

### 4.4 Recovery: laptop stolen → phone rotates wallet + revokes laptop (rev 4)

```
Alice notices her laptop missing. Recovery flow on her phone:

ON PHONE (alice's surviving master device, has K10_PHONE + K11_PHONE):
  Alice opens agentkeys mobile app
  Selects: "Lost device → revoke and rotate"
  App displays current state:
    - 2 master devices registered: LAPTOP (lost), PHONE (in hand)
    - recovery_threshold: 1 (any one master device can authorize recovery)
    - Phone alone is sufficient (1 ≥ 1)
  
  App constructs payload:
    {
      operation:        "revoke_device_and_rotate",
      operator_omni:    alice_omni,
      revoke_devices:   [SHA256(D_pub_LAPTOP)],
      bump_k3_epoch:    false,                  // K3 epoch is global; not per-operator
      new_device_only:  true,                   // operator's k3 epoch unchanged, just refresh wallet derivation
      nonce, expires_at
    }
  
  App signs with K10_PHONE
  App prompts Face ID → K11_PHONE WebAuthn assertion over payload
    (Required per Codex #2 / arch.md §5a — device revocation IS a master-only
     binding mutation; needs K11 user-presence)
  
  App POSTs to recovery-relay /v1/recover/rotate with {payload, k10_sig_PHONE, k11_assertion_PHONE}
  
  Relay verifies:
    - SidecarRegistry[D_pub_hash_PHONE].roles includes RECOVERY
    - SidecarRegistry[D_pub_hash_PHONE].operator_omni == alice_omni
    - K10 sig valid against D_pub_PHONE
    - K11 assertion valid against K11_PHONE.cred_id
    - Sig count (1 from phone) ≥ recovery_threshold (1)
  
  Relay submits two events to chain in one batch:
    SidecarRegistry.revoke_device_with_proof(
      device_pubkey_hash: SHA256(D_pub_LAPTOP),
      operator_omni:      alice_omni,
      revoking_quorum:    [{k10_PHONE, k11_PHONE}]
    )
    CredentialAudit.RecoveryEvent(alice_omni, "revoke laptop + rotate wallet", block_n)
  
  Chain confirms (~1-12s).

SIGNER (subscribed to chain events):
  Sees DeviceRevoked event for D_pub_LAPTOP under alice_omni
  Drops D_pub_LAPTOP from its authorized cap-mint set for alice_omni
  Bumps internal "wallet-derivation salt" for alice_omni → new transient master_wallet
    (so AWS STS subsequent mints derive a different wallet for the AWS PrincipalTag
     just for hygiene — but the actor_omni is unchanged, the S3 path is unchanged,
     and no migration runs. The "wallet rotation" is purely an STS-cred-rotation
     concern, since the AWS PrincipalTag value is `agentkeys_actor_omni` not `wallet` per §6.)

BROKERS (subscribed to chain events):
  See DeviceRevoked event
  Push SSE drop events to all daemons under alice_omni (now just phone):
    {event: "device_revoked", device_pubkey_hash: SHA256(D_pub_LAPTOP)}
  Phone receives → updates its local SidecarRegistry view (informational only)
  
  Also push to the (attacker-controlled) laptop daemon — but it can no longer
  authenticate with the broker because its device is revoked. Any cap-mint
  from D_pub_LAPTOP is rejected at broker step 9 (registry lookup fails).

WITHIN ~60 SECONDS OF ALICE'S FACE-ID APPROVAL:
  - Attacker on laptop: cap-mints rejected (registry says device revoked)
  - Attacker's cached creds: expire on sidecar TTL (≤5 min default)
  - Attacker's stolen STS creds (15-min TTL): expire; new STS mints will use new wallet
  - Account fully preserved. Self-sovereign throughout. Biometric on phone only.

REPLACING THE LAPTOP (later):
  Alice buys new laptop, runs: agentkeys init --restore
  CLI generates K10_NEW_LAPTOP locally
  Phone authorizes new-device bind per §4.1b
    (uses K11_PHONE to sign authorization; new laptop's K11_NEW also enrolls)
  SidecarRegistry adds D_pub_NEW_LAPTOP with same roles as the lost laptop had
  Optionally bumps recovery_threshold to 2 (now 2-of-3 with phone + new laptop + …)
```

**Critical properties** (Codex-finding-compliant):
- K11 user-presence required on phone for the recovery (Codex #2)
- Only RECOVERY-role devices count toward the quorum
- ZERO S3 migration (Codex #3) — actor_omni-keyed paths
- Chain authoritative for K3 epoch (Codex #4) — signer subscribed to events
- Per-device binding to alice_omni preserved (Codex #1) — laptop revocation doesn't affect agent-pi's device binding to its own actor_omni

### 4.5 Device-quorum + master/agent boundary policy (rev 4 new)

#### Role bitfield semantics

| Role | Bit | Granted to | What it authorizes |
|---|---|---|---|
| `CAP_MINT` | 0x01 | All registered devices (master + agent) | Day-to-day cap-mint requests for cred-fetch / cred-store (subject to scope + ownership rules) |
| `RECOVERY` | 0x02 | Master devices only (K11 required) | Counts toward `recovery_threshold` for revoke-device + wallet-rotation flows |
| `SCOPE_MGMT` | 0x04 | Master devices only, opt-in per device | Sign scope mutations (grant/revoke services to agents) — requires K11 assertion |

Default role assignments at registration:
- **First master device** of a new operator: `CAP_MINT | RECOVERY | SCOPE_MGMT` (all roles — operator can do everything from this one device)
- **Subsequent master devices**: `CAP_MINT | RECOVERY` (SCOPE_MGMT opt-in to prevent accidental mobile-mgmt sprawl)
- **Agent devices**: `CAP_MINT` only (no RECOVERY because no K11; no SCOPE_MGMT because agents can't grant scope)

The operator can elevate any master device's roles after registration via the same K11-gated master-mutation flow used for scope updates.

#### Master/agent boundary enforcement (Codex finding #1)

Per Codex's finding, a device key bound to one specific actor MUST NOT be usable to mint caps as any other actor under the same operator. Enforcement at every layer:

| Layer | Check |
|---|---|
| Daemon (caller side) | Daemon constructs cap-mint with `request.agent_omni = <its own bound actor_omni>`. Daemon has no other actor_omni to use. |
| Broker (mint side) | `SidecarRegistry[device_pubkey].actor_omni == request.agent_omni` — reject otherwise |
| Worker (consume side) | Same check — defense in depth against malicious broker that ignores its own check |
| Signer (KEK side) | KEK is keyed on `operator_omni`, not `agent_omni`, so any in-scope agent under the same operator gets the same KEK. **But** the cap-token validation upstream still prevents wrong-agent use because the cap's `agent_omni` was already pinned at broker validation. |

A compromised agent-pi K10 can mint caps for `(alice_omni operator, agent-pi actor_omni, openrouter)`. It CANNOT mint caps for `(alice_omni operator, alice_omni actor_omni)` or `(alice_omni operator, agent-other actor_omni)`. The blast radius is contained to whatever scope is granted to agent-pi specifically.

#### Recovery threshold ladder (rev 4)

| Device count for operator | Recommended threshold | Loss tolerance |
|---|---|---|
| 1 master device | 1 (forced — can't exceed device count) | None — lose device = lose account |
| 2 master devices | 1 (default) | Lose any 1 → other recovers |
| 3+ master devices | 2 (recommended on add of 3rd device) | Lose any 1 → other 2 recover |
| 4+ master devices | 2 or 3 | Lose any 2 if threshold=2; lose any 1 if threshold=3 |

Threshold is bumped via the same K11-gated mutation flow (`SidecarRegistry.set_recovery_threshold_with_webauthn`). Default policy at registration: when adding the Nth master device for N ≥ 3, prompt operator: "Bump threshold to 2?"

#### Bootstrap single-device-only fallback

If an operator has registered only 1 master device and loses it, the account is unrecoverable (same as losing the only seed phrase). No paper-code fallback in v2 (per operator decision).

Mitigation: the CLI prompts AGGRESSIVELY at bootstrap to add a 2nd master device. The threshold for that prompt:
- After 1st device registered: "Add a 2nd master device within 24 hours" (notification at 24h)
- After 1st device + 24h: "You're at risk — add a 2nd master device" (more visible notification)
- After 1st device + 7d: "Account loss risk is high" (notification on every CLI run)

Operators who deliberately stay on one device do so with full informed-consent UX.

---

## 5. Runtime flows

### 5.1 Agent fetches and uses a credential (cache miss path, rev 4)

```
agent process (e.g. claude code running on alice's laptop):
  POST $XDG_RUNTIME_DIR/agentkeys-proxy.sock /proxy/openrouter/v1/chat/completions
  Headers: Authorization: Bearer ak-sidecar    (placeholder; replaced by daemon)
  Body:    { model: "...", messages: [...] }

daemon (running on an agent device — could be alice's laptop for own creds,
        or agent-pi for one of alice's child agents):
  1. SO_PEERCRED / cgroup peer-check → identify caller; verify in allowed-callers list
  2. caller-scope lookup → "openrouter" in caller's allowed-services? yes
  3. method/path allowlist → POST /v1/chat/completions allowed for openrouter? yes
  4. spend-quota check → under (req/min, daily $ budget) limits? yes
  5. credential_cache.get("openrouter") → MISS
  6. Fetch K3EpochCounter.current_epoch from chain (cached briefly, ≤1-block stale)
     → current_epoch = E
  7. Mint cap-fetch request:
     request = {
       operator_omni: alice_omni,                  // who owns the credential
       agent_omni:    <this daemon's bound actor_omni>,
                                                    // for alice's laptop: alice_omni
                                                    // for agent-pi: actor_omni_agent_pi
       service:       "openrouter",
       ttl:           300,
       nonce:         random(),
       k3_epoch:      E                            // current authoritative K3 epoch
     }
     k10_sig = sign(D_priv_THIS_DEVICE, hash(request))
  8. POST broker /v1/cap/cred-fetch { request, k10_sig }

broker:
  9. Look up SidecarRegistry[SHA256(D_pub_THIS_DEVICE)] → device binding
  10. Verify binding.actor_omni == request.agent_omni  (Codex #1 containment)
  11. Verify binding.operator_omni == request.operator_omni
  12. Verify k10_sig against D_pub_THIS_DEVICE
  13. Read scope from ScopeContract.get_scope(operator_omni, agent_omni)
  14. Confirm "openrouter" in scope.services
  15. Fetch K3EpochCounter.current_epoch from chain → confirm == request.k3_epoch
  16. broker_sig = sign(K1, hash(request))
  17. Return cap = { request, k10_sig, broker_sig }

daemon:
  18. POST creds-service-worker /v1/cred/fetch with cap

creds-service-worker (Lambda or microservice):
  19. Read SidecarRegistry[SHA256(D_pub)] → binding; verify k10_sig
  20. Verify binding.actor_omni == cap.request.agent_omni (Codex #1, defense in depth)
  21. Verify binding.operator_omni == cap.request.operator_omni
  22. Verify broker_sig against K1 JWKS
  23. Read on-chain scope independently → confirm "openrouter" in scope.services
  24. Fetch K3EpochCounter.current_epoch from chain → call it E_chain
  25. Verify cap.request.k3_epoch <= E_chain (reject if request claims future epoch)
  26. Read blob from S3:
        bucket: $BUCKET (deployment-wide)
        path:   bots/<alice_omni_hex>/credentials/openrouter.enc
        STS creds: PrincipalTag agentkeys_actor_omni = <alice_omni_hex>
        Bucket policy: scopes by ${aws:PrincipalTag/agentkeys_actor_omni}
                       → this STS session can only read bots/<alice_omni_hex>/*
                       (Codex #3 — path stable, no K3-rotation migration)
  27. Read envelope.k3_epoch from blob → call it E_blob
        (E_blob could be < E_chain if blob was encrypted under an older K3 epoch
         and hasn't been re-encrypted yet — still readable; signer holds historical K3s)
  28. mTLS-call signer.derive_cred_kek(operator_omni=alice_omni, k3_epoch=E_blob)
  29. Signer (inside TEE):
        a. Reads K3EpochCounter.current_epoch from chain → E_chain
        b. Verifies E_blob <= E_chain (independent check, Codex #4 defense)
        c. Retrieves K3_v[E_blob] from TEE storage
        d. kek = HKDF(K3_v[E_blob], "agentkeys.user.v1" || alice_omni)
        e. Returns 32-byte KEK
  30. AES-GCM-open blob:
        AAD = "agentkeys.cred.aad.v2|" || alice_omni_hex || "|" || "openrouter"
  31. Return plaintext to daemon over TLS
  32. (Optional) re-encrypt under K3_v[E_chain] and write back to same S3 path
       (eager migration for blobs found under an older epoch — caps the K3 history depth)
  33. Submit audit via audit-service relay:
        CredentialAudit.CapMintedBatch leaf:
          { operator_omni, agent_omni, service, cap_hash, k3_epoch=E_blob,
            timestamp, device_pubkey_hash, k10_sig }

daemon:
  34. Cache plaintext: credential_cache.insert("openrouter",
        {plaintext, fetched_at: now, ttl: 300, k3_epoch_at_fetch: E})
  35. Inject Authorization: Bearer <plaintext> on the forwarded request
  36. Forward POST https://openrouter.ai/v1/chat/completions
  37. Stream SSE response chunks back to agent over localhost
  38. Emit local audit row for the proxied call
        (caller_uid, service, method, path, status, bytes_in, bytes_out)
        Periodically ships to audit-relay for on-chain anchor batching.
```

**Codex finding cross-references in this flow**:
- **#1 (device→actor binding)**: enforced at broker step 10, re-enforced at worker step 20
- **#2 (K11 for master mutations)**: N/A — cred-fetch is read; not a master-only mutation. K11 only required for scope mutations (§4.2) and device bindings (§4.1).
- **#3 (S3 path keyed on stable identity)**: enforced at step 26; path is `bots/<actor_omni_hex>/...` not `bots/<current_wallet>/...`; zero K3-rotation migration
- **#4 (chain as K3 epoch source of truth)**: enforced at broker step 15, worker steps 24-25, signer step 29(a-b) — three independent chain reads of K3EpochCounter, any of which can catch a stale/lying signer

### 5.2 Agent fetches credential (cache hit path)

```
agent process: (same call as above, but 30 seconds later)
  POST .../proxy/openrouter/v1/chat/completions ...

daemon:
  1-4. (same controls as 5.1)
  5. credential_cache.get("openrouter") → HIT (cached at t-30s, TTL=300s)
  6-22. (skip entirely — no broker, no worker, no signer)
  23. (already cached)
  24-27. (same as 5.1)

Result: localhost-only round trip (~0.1ms overhead) + upstream API latency.
Broker is not in the LLM-call hot path.
```

### 5.3 Revocation (rev 4 — K11 required for scope mutation)

```
Master decides to revoke child's access to openrouter:

master CLI (on a device with SCOPE_MGMT role + K11, e.g. alice's laptop):
  1. agentkeys scope --agent <child_omni> --remove openrouter
  2. CLI builds payload: {operator_omni: alice_omni, agent_omni: child_omni,
                          services: [...without openrouter], read_only: false,
                          nonce, expires_at}
  3. CLI signs payload with K10_LAPTOP
  4. CLI prompts Touch ID → K11_LAPTOP WebAuthn assertion over payload
     (Required per §4.2 / Codex #2 — revocation IS a scope mutation, needs K11)
  5. CLI POSTs to scope-mutation-relay with {payload, k10_sig, k11_assertion}
  6. Relay verifies, submits ScopeContract.set_scope_with_webauthn(...) tx
  7. Chain confirms (~1-12s); emits ScopeUpdated event

broker (subscribed to chain events):
  8. Sees scope diff: child_omni dropped openrouter
  9. Pushes SSE drop event to child's daemon: {event: "drop", service: "openrouter"}

child daemon:
  10. Receives drop event; atomically purges credential_cache["openrouter"]
  11. Sets state to "openrouter unavailable" — subsequent proxy calls fail at step 5 of §5.1

if push fails (network issue, broker down):
  - daemon's per-cred TTL expires (default 5 min); cache purged on schedule
  - daemon attempts fresh fetch via §5.1; broker (or worker checking chain) refuses
  - daemon enters error state for "openrouter"; proxy calls fail with PermissionDenied

worst-case revocation latency:
  min(cred_cache_ttl, time_since_last_broker_event + stale_grace)
```

---

## 6. Why actor_omni at every external layer (rev 4 — fully eliminating wallet from external identity)

In rev 4 we extend the actor_omni-as-on-chain decision **further** — actor_omni also becomes the AWS-side identity (PrincipalTag), the S3 path key, and the cap-token addressing. master_wallet drops to a purely signer-internal concept: K3-derivation result that exists only to satisfy AWS's STS-needs-a-credential-set machinery. **No external surface knows about master_wallet.**

This is driven by Codex finding #3: keying S3 paths on a K3-rotating wallet creates a window where post-rotation reads point at the new path but blobs still live at the old path. Lazy-on-read migration was hand-wavy. Keying paths on a stable actor_omni eliminates the migration entirely.

### Layer-by-layer identity assignment (rev 4)

| Layer | Identity used (rev 4) | Reason |
|---|---|---|
| On-chain scope, registry, audit | `actor_omni` | K3-rotation tolerant + privacy via meta-tx relays |
| **AWS STS PrincipalTag** | **`agentkeys_actor_omni`** (32-byte hex of the actor_omni) | Stable across K3 rotation; bucket policy can scope by it the same way it used to scope by wallet |
| **S3 path prefix** | **`bots/<actor_omni_hex>/...`** | Stable across K3 rotation; ZERO migration needed |
| Cap-token requests (daemon → broker → worker) | `actor_omni` (operator + agent) | Matches on-chain scope index |
| AAD in credential-blob envelope | `actor_omni` | Binds blob to (operator_actor_omni, service); rotation-stable |
| Signer-internal K4 + KEK derivation domain | `actor_omni` | Per arch.md §3a/§4, actor_omni is the canonical K4 input; KEK = `HKDF(K3_v[epoch], "agentkeys.user.v1" \|\| actor_omni)` |
| Signer-internal wallet derivation (for the AWS STS round-trip ONLY) | `master_wallet = HKDF(K3_v[epoch], master_omni)` | The wallet is needed because `AssumeRoleWithWebIdentity` returns AWS creds that need a "principal" to be checked against — the wallet is that principal. But the wallet is **constructed transiently inside the signer/broker** at STS-call time and never recorded anywhere. |

### What this means for the STS / OIDC flow

The OIDC JWT v2 carries:
```
{
  "iss": "https://broker.litentry.org",
  "sub": "<actor_omni_hex>",
  "agentkeys": {
    "actor_omni": "<32-byte hex>",        // NEW — primary identity
    "operator_omni": "<32-byte hex>",     // NEW — operator's actor_omni
    "k3_epoch": 2                         // NEW — which K3 epoch the JWT was minted under
  }
}
```

AWS STS `AssumeRoleWithWebIdentity` receives this JWT. The role's trust policy uses `agentkeys_actor_omni` as the PrincipalTag (was: `agentkeys_user_wallet`). Bucket policies scope by `${aws:PrincipalTag/agentkeys_actor_omni}` against `bots/<actor_omni_hex>/...`.

The `master_wallet` field is **removed** from the OIDC JWT entirely. AWS doesn't need it; nothing else needs it for resource scoping. The wallet exists only as the AWS-side IAM principal for the brief life of one STS call, never persisted as identity material.

### Net effect (rev 4)

- **Chain layer**: `actor_omni` everywhere; no `master_wallet`
- **AWS layer**: `actor_omni` as PrincipalTag + S3 path key; `master_wallet` exists only transiently inside STS calls and isn't recorded
- **Signer layer**: holds K3; derives wallet on demand for STS, derives KEK on demand for crypto, both anchored on actor_omni
- **K3 rotation**: zero migration impact. S3 paths stay put. PrincipalTag stays put. Bucket policy stays put. The only change is signer derives a new wallet under the new K3 epoch when it constructs STS creds (transient, in-memory).

The earlier rev kept `master_wallet` on the AWS side because "AWS doesn't know about omnis". That was wrong — AWS PrincipalTag is **just a key/value string**; it doesn't care whether the value is a 20-byte EVM address or a 32-byte omni hash. Switching the tag-value to omni hash eliminates the rotation problem cleanly.

---

## 7. KEK scheme

**v2 ships per-user KEK, anchored on actor_omni; K3-rotation-tolerant via in-blob epoch byte + signer-retained K3 history**:

```
// Signer-internal (inside TEE):
actor_omni    = SHA256("agentkeys" || "evm" || initial_master_wallet_K3_v1)
                (per §3.0 — frozen at first SIWE-bind; never changes)

KEK_for(operator_omni, k3_epoch) = HKDF-SHA256(
    salt = "agentkeys.kek-salt.v2",
    ikm  = K3_v[k3_epoch],            // signer retains K3_v1, K3_v2, ... in TEE
    info = "agentkeys.user.v1" || operator_omni
)
```

One KEK per (user, K3 epoch). All of one user's credentials encrypted under the same K3 epoch share a KEK. Derivation lives inside the signer (TEE-protected per §3.3). Worker calls `signer.derive_cred_kek(operator_omni, k3_epoch)` over mTLS, passing the epoch read from the blob's envelope. Only the 32-byte KEK leaves the signer.

### K3 rotation handling (rev 4 — no S3 migration)

When K3 rotates from epoch N to epoch N+1:

1. **K3EpochCounter on chain bumps**: `current_epoch = N+1`.
2. **Signer holds both K3 epochs**: `K3_v[N]` retained in TEE for as long as ANY ciphertext under it might still need decrypt. Workers can fetch under either epoch — the blob tells them which.
3. **New writes encrypt under `K3_v[N+1]`**: the envelope's `k3_epoch` byte records this.
4. **S3 path is UNCHANGED**: still `bots/<actor_omni_hex>/credentials/<service>.enc`. No migration. The blob just has a different `k3_epoch` byte and was encrypted under a different KEK.
5. **AWS PrincipalTag is UNCHANGED**: still `agentkeys_actor_omni = <actor_omni_hex>`. Bucket policy stays put. No IAM change.
6. **Optional eager re-encryption** (operator-driven cleanup): operator can trigger a pass that reads each blob, decrypts under old K3 epoch, re-encrypts under new K3 epoch, writes back to the SAME S3 path. After all blobs have been touched the old K3 epoch can be deleted from signer storage.

Critical correction from rev 3: rev 3 said the S3 path rotates with master_wallet on K3 rotation, with lazy on-read migration. That created a window where post-rotation reads couldn't find pre-rotation blobs (Codex finding #3). **Rev 4 eliminates path rotation entirely** by keying S3 path on `actor_omni` (stable). Only the in-blob `k3_epoch` byte tells the signer which K3 to derive KEK under. There is no migration window because there is no migration.

### AES-256-GCM envelope (S3 wire format, v2 rev 4)

```
1 byte  version          (0x04 for v2 rev 4)
1 byte  k3_epoch         (which K3 generation encrypted this blob; signer matches to retained K3)
12 byte AES-GCM nonce    (random per encryption)
N bytes ciphertext
16 byte GCM authentication tag

AAD = "agentkeys.cred.aad.v2|" || operator_actor_omni_hex || "|" || service
```

The AAD binds the blob to its `(operator_actor_omni, service)` location. A cross-(operator, service) swap at the S3 layer fails decryption. AAD and S3 path both key on `actor_omni` — they match.

S3 path (rev 4): `bots/<operator_actor_omni_hex>/credentials/<service>.enc`. **Stable across K3 rotation, wallet rotation, master device changes — everything.** The only thing that ever changes about a blob is (a) the in-blob `k3_epoch` byte when the blob is re-encrypted under a new K3, and (b) the ciphertext itself when the credential is updated.

### Verification path (rev 4 — with K3EpochCounter check, per Codex finding #4)

When a worker fetches a credential:

1. Worker reads blob from S3 → gets `envelope.k3_epoch = N` (the epoch the blob was encrypted under)
2. Worker fetches `K3EpochCounter.current_epoch` from chain → gets the current authoritative epoch (call it `M`)
3. Worker confirms `N <= M` (a blob encrypted under a future epoch is malformed/forged — reject)
4. Worker calls `signer.derive_cred_kek(operator_omni, N)` over mTLS
5. Signer also reads chain `K3EpochCounter.current_epoch` and confirms `N <= M` (independent check, defense in depth)
6. Signer derives KEK under `K3_v[N]`, returns 32-byte KEK
7. Worker AES-GCM-opens

Critical property: if a malicious/stale/rolled-back signer claims `current_epoch = M' ≠ M`, the worker rejects (its chain read is authoritative). This addresses Codex finding #4 — chain is the source of truth for K3 epoch; signer is just a fast derivation cache, never a source of truth for what the current epoch is.

**Compromise blast radius**: per-user KEK means compromising one user's KEK exposes all that user's credentials (across services). Compromise is bounded to one user — other operators' credentials safe.

---

## 8. Relationship to arch.md

This doc extends arch.md, doesn't replace it. Concrete deltas:

### Preserved unchanged from arch.md

- §3 — identity ceremony chain (email-link / OAuth2 → identity_omni → SIWE → master_wallet → actor_omni)
- §3a — canonical names (master_wallet, actor_omni, K1..K7); this doc extends with `device_pubkey` and `credential_kek` rows
- §4 — identity model (K3 → K4 → master_wallet); device-keypair is orthogonal, not derived from K3
- §5a.5 — OIDC + STS + AWS PrincipalTag for resource-layer isolation (S3 path still keyed on master_wallet)
- §6 — runtime sequence (K3/K4 derivation flow); extended to include worker calls + sidecar proxy
- §13 — TEE roadmap (issue #74 step 2 = K3 in TEE). This doc assumes that lands.

### Extended

- §5a / §5a.5 — extend with sidecar device-key registration on-chain + cap-token request flow
- §7a — bucket layout extends with per-service-worker IAM (creds-service-role, memory-service-role, audit-service-role, email-service-role) — each with minimum-scope on the relevant prefix
- §9 — component inventory grows:
  - daemon's role expands (proxy listener + credential cache + controls)
  - workers added (creds-service, memory-service, audit-service, email-service)
  - chain components added (ScopeContract, SidecarRegistry, CredentialAudit)
  - K1 explicitly separated from K3 deployment story

### Net new

- **Chain layer**: on-chain ScopeContract + SidecarRegistry + CredentialAudit (arch.md §7 audit-destination row 4 implements this)
- **Device-keypair**: per-daemon TPM/SE/TEE-held key; cap-mint requires its signature
- **Cap-token model**: two-signature (broker_sig + sidecar_sig) authorization for all per-call operations
- **Per-service worker split**: credentials, memory, audit, email each get their own deployable
- **ZK-proven cap mint (v3+)**: broker becomes stateless prover

### Removed (vs today's #87 baseline)

- Mock-server's `/credential/*` endpoints — fully retired
- Mock-server's `/session/*` and `/audit/*` endpoints — replaced by broker + audit-service
- Client-side `enforce_scope_for_service` in `S3CredentialBackend` — the daemon's controls + broker scope-check + worker chain-recheck make this obsolete
- Static AWS_* env injection from operator workstations — replaced by per-cap OIDC + worker-side STS

---

## 9. Phasing

| Phase | Ships | Key change | Depends on |
|---|---|---|---|
| **v1** | Today's #87 + sidecar with rev-4 controls | Daemon hosts localhost proxy with lazy-fetch + 5-min TTL + caller-auth + scope-binding + allowlist + quotas + audit + fail-closed. Monolithic broker still holds K1 + scope DB + cred-decrypt. | None |
| **v2.1 — device co-signature** | Sidecar registers device-key at bootstrap. Broker requires sidecar_sig on every cap-mint. Workers (still in broker) verify both sigs. | v1 |
| **v2.2 — creds-service worker split** | Pull credential decryption out of broker into a separate Lambda or microservice. Broker no longer holds cred-decrypt authority. | v2.1 |
| **v2.3 — on-chain scope** | Master signs ScopeContract.set_scope tx; broker indexes chain; workers cross-check chain on cap consumption. Broker's scope-table becomes a cache, not the authority. | v2.2 |
| **v2.4 — K3 in TEE** (issue #74 step 2) | K3 moves from mock-server's `/dev/sign-message` to attested enclave. Workers verify enclave attestation before calling signer. | independent track |
| **v2.5 — sidecar in TEE (E3)** | Daemon runs inside TEE; device-key sealed to enclave; attestation pinned in SidecarRegistry. Defends against host-root compromise. | v2.1 + hardware availability |
| **v3 — audit-anchored cap mint** | Every cap mint hashed and recorded on-chain (Merkle-batched, ~one tx per N caps). Detection-based broker accountability — rogue mints are provably visible to anyone watching the chain. ~zero per-cap latency. | v2.3 |
| **v3.x — threshold-signed broker** | K1 split M-of-N across broker instances or out-of-band quorum. Cap requires M signatures. Defends against single broker compromise without ZK. ~100-500ms per cap. Reserved for high-assurance deployments. | v3 + key-sharding infrastructure |
| **v4+ — ZK-proven cap mint** | Broker emits ZK proofs of "cap is consistent with on-chain scope at block N". Workers verify proofs, not broker signatures. Broker becomes stateless prover. **Reserved for the future** — current ZK tooling is too slow for online per-cap proving (1-30 sec/proof at 100k constraints; ~100-500 parallel provers needed at 100 req/s, or batch-induced latency that breaks interactive UX). Revisit when folding schemes and ZK hardware accelerators mature. | v3 + sub-100ms ZK proving |

Each phase is a separate issue. v2.1 unlocks the cleanest single-component-compromise defense; v2.2 + v2.3 progressively shrink broker authority; v2.4 + v2.5 add hardware-rooted trust; **v3 (audit-anchored) is the realistic broker-accountability mechanism** for the foreseeable future; v4+ (ZK) is the long-term destination contingent on tooling.

---

## 10. Future work (tracked as GH issues, not in this doc's body)

1. **Per-(user, service) KEK** — finer-grained KEK derivation (`HKDF(K3, "agentkeys.cred.v2" || actor_omni || service)`). Trades broker→signer round-trips for per-credential compromise isolation. Reserved as v2.4+ hardening; v2 ships per-user.
2. **Wrap-and-rewrap** — random per-credential KEK encrypted under per-principal ECIES wraps stored in a broker-side wrap-table. Defends against K3-alone compromise (attacker also needs wrap-table). Stretch goal; gated on whether K3-in-TEE proves insufficient.
3. **Cross-chain bridging** — operators on different chains (Litentry vs EVM L2 vs Solana) sharing audit anchors. Out of v2 scope.
4. **Local TLS MITM** — daemon-installed CA + DNS override for MCPs that hardcode upstream URLs (don't support base-URL override). Generic alternative to upstream MCP patches; heavier; reserved.
5. **Multi-master / threshold scope mutations** — require N-of-M master signatures for scope grants. For high-assurance deployments.
6. **Per-cap-token one-shot CAS-burn** — strict-replay protection for state-mutating operations (scope changes, audit submissions, email sends). Per-call broker nonce-table check. Useful but adds broker statefulness.

---

## 11. What this design guarantees (rev 4)

| Property | How it's enforced |
|---|---|
| **No seed phrase required for daily use** | K10 (device key) is generated on-device in TPM/SE/TEE and never exported. K11 (WebAuthn credential) is sealed in the platform authenticator (Touch ID / Face ID / Windows Hello / Android StrongBox) and cannot be exported by design. Operator never types or memorizes a seed phrase. |
| **Recovery via M-of-N device quorum, no external trust** | M-of-N from the operator's OWN master devices (laptop + phone + …). Each has its own K10 + K11. No friends, no third parties, no IdP recovery required. Self-sovereign throughout. |
| **No IdP lock-in after Day 0** | Email/OAuth is a one-time sybil check at Stage 1; actor_omni is bound to the first SIWE-derived wallet hash, NOT to the IdP identifier. Subsequent IdP ban / account closure is irrelevant. |
| Agent never holds credential bytes | Sidecar holds plaintext in memory only; agent only sees localhost proxy URL + placeholder auth token. Daemon's controls (caller-auth, per-actor binding, allowlist, quotas) bound the bearer-capability use. |
| **Device key bound to specific actor (Codex #1)** | SidecarRegistry stores `device_pubkey → (operator_omni, actor_omni, role)`. Compromised agent K10 contained to ITS one actor — cannot mint as sibling agents under same operator. |
| Broker can't mint caps without daemon's authorization | Cap requires `k10_sig` from device-key (TPM/SE/TEE-held, not in broker or signer memory). Compromised broker alone can't forge. |
| **K11 user-presence required for master mutations (Codex #2)** | Scope grants, new device bindings, K10 rotation, device revocation — all require fresh K11 WebAuthn assertion over the exact payload. Stolen K10 alone (no biometric) cannot escalate to master powers. arch.md §5a Q7 fix preserved at the application layer. |
| **K3-rotation tolerance with ZERO S3 migration (Codex #3)** | S3 paths key on `actor_omni` (stable), not `current_master_wallet` (K3-rotating). AWS PrincipalTag = `agentkeys_actor_omni`. K3 rotation = 1 chain tx (global K3EpochCounter bump); no path changes, no IAM changes, no per-operator action. |
| **Chain is single source of truth for K3 epoch (Codex #4)** | `K3EpochCounter` on chain; workers verify signer's claimed epoch against chain on every fetch. Stale/compromised signer cannot lie about current K3 epoch. |
| Broker can't mutate scope | Scope mutations require master's K11 WebAuthn assertion. Broker can't forge that — K11 is hardware-sealed in operator's device. Broker reads scope from chain, never writes. |
| Broker has no credential bytes | Workers (Lambda or microservice) decrypt — broker has no IAM on credentials S3 prefix. |
| K3 is the highest-value target → most protection | K3 inside TEE with attested boot. mTLS pin between workers/broker and signer. Old K3 epochs retained for lazy decrypt; signer verifies chain epoch before any operation. |
| Compromise of any single trust root is bounded | Master K11 compromise (physically + biometrically) → on-chain visible + recoverable via device-quorum if M-of-N ≥ 2. K10 alone compromise → bounded by K11 requirements at master mutations. Broker K1 compromise → bounded by chain-stored scope. Signer K3 compromise → catastrophic, mitigated by TEE attestation. Chain compromise → bounded by chain security. **No single trust root is sufficient for full takeover.** |
| Revocation propagation is bounded and explicit | `min(cred_cache_ttl, time_since_last_broker_event + stale_grace)`. Default ≤5 min via TTL; ≤60s on broker push event. K11-gated revocation can fire on operator's mobile in seconds. |
| Per-data-class compromise isolation | Workers per service (credentials, memory, audit, email, payment); one worker compromise = one data class leaked. Per-worker IAM tightly scoped. |
| **Payment safety (rev 4 — new worker)** | payment-service requires strict one-shot CAS-burn cap-token + tight per-cap quotas + K11 user-presence for high-value payments. Replay impossible; double-spend impossible. |
| Vendor-pluggability | Same architecture works on AWS / Cloudflare / Tencent / self-hosted. Components communicate via standard wire formats (mTLS, HTTPS, EIP-712 chain signatures). |
| Audit can be hosted-but-checkable, self-hosted, or direct-write | Three tiers per §3.4 audit-service discussion: hosted relay with on-chain Merkle root (default); operator-hosted relay (self-sovereign); direct-write per-event (maximum sovereignty, maximum gas cost). |

---

## 12. Open questions (to be resolved before v2 implementation)

1. **Chain choice for scope storage**. Litentry chain (project home, natural default) vs EVM L2 (Base / Optimism — broader tooling, more validators) vs Solana (cheaper, faster confirmations but different toolchain). Default to Litentry; reserve EVM-L2 as fallback if Litentry tx throughput proves a bottleneck.
2. **TPM/SE availability for E1 device-keys**. Not every Ubuntu workstation has a usable TPM. Fallback to file-based device-key with mode 0600 — explicitly weaker; document the tier.
3. **Cap-token format**. JSON over HTTPS (current v1 style) vs CBOR-binary vs EIP-712 typed signature. EIP-712 is chain-native and ZK-friendly (v3+); CBOR is smallest; JSON is most debuggable. v2 ships JSON; v3 may migrate.
4. **Worker deployment topology**. AWS Lambda is the lowest-ops option but vendor-locked. Self-hosted microservice is portable but ops burden. Default per operator deployment; ship Lambda + microservice variants of creds-service in parallel.
5. **K3 TEE migration sequencing**. Today's `/dev/sign-message` is in mock-server. Migration to TEE is independent of credential-storage v2. They can ship in either order; v2 design accommodates both states (signer-in-TEE = stronger; signer-in-mock-server = today's posture, still works through the same mTLS interface).

---

## Codex adversarial review (2026-05-17) — findings + author response

Codex `/codex:adversarial-review` was run against the pre-rev-4 v2 doc. Four findings, three high + one medium. All addressed in rev 4. The author **independently re-examined** each finding and either agreed, pushed back, or noted a refinement.

### Finding 1 [high] — SidecarRegistry doesn't bind device to specific actor

**Codex's concern**: registry binds `device_pubkey → operator_omni` only. Compromised agent K10 (under operator Alice) could mint cap claiming `agent_omni = some_other_agent` if Alice has scoped multiple agents under her operator. Breaks arch.md §5a.5 containment.

**Author response**: ✅ Agree. This is a real escalation path. **Fixed in rev 4** §3.5: `DeviceBinding` stores `(operator_omni, actor_omni, role, k11_cred_id, attestation)`. Cap verification at broker + worker requires `binding.actor_omni == request.agent_omni`. A compromised agent K10 can mint caps as that one agent only — sibling agents under the same operator are NOT reachable.

**Note**: rev 4 enforces this at three layers (broker mint, worker consume, signer KEK call) — defense in depth against a buggy or malicious broker that skips its own check.

### Finding 2 [high] — Master mutations accept K10 alone, not K11

**Codex's concern**: rev 3 allowed scope mutations to be authorized by master K10 signature OR by `master_wallet via signer`. Per arch.md §5/§5a, master mutations should require K11 (WebAuthn user-presence). Leaked K10 alone shouldn't be able to mint agents or mutate bindings.

**Author response**: ✅ Agree for binding mutations (scope grant, device add, K10 rotation, device revocation). Fixed in rev 4 §4.2/§4.4: contracts and relay endpoints REQUIRE both K10 sig and fresh K11 WebAuthn assertion over the exact payload.

**Push back / refinement**: I considered whether ALL master operations need K11 or just bindings. Specifically, **scope REVOCATION** is fail-safe (accidental revoke is recoverable by re-granting; stolen-K10 revoke causes DoS for legitimate operator, not credential leak). A future revision could allow K10-only emergency revocation as a "fail-safer than even bindings" path. For v2 simplicity: ship K11-for-everything; revisit if operational UX shows it's prohibitive.

**Also**: cred-store and cred-fetch under one's OWN scope are NOT master mutations (operator storing a credential for their own use, daemon fetching cred for active task). These remain K10-only. Codex's finding is specifically about scope/binding mutations, not data-plane ops.

### Finding 3 [high] — K3 rotation breaks S3 reads (lazy migration window)

**Codex's concern**: rev 3 said S3 path uses `current_master_wallet` and migrates lazily on read. After K3 rotation, the read path flips to new wallet pre-migration → first post-rotation read can't find pre-rotation blob (old path).

**Author response**: ✅ Agree the lazy-migration scheme was hand-wavy. **Fixed in rev 4** with a stronger answer than Codex proposed: instead of "explicit epoch-indexed migration plan", I switched the S3 path itself to be keyed on `actor_omni` (stable across K3 rotation). AWS PrincipalTag = `agentkeys_actor_omni` (also stable). K3 rotation = ZERO S3 migration. Only the in-blob `k3_epoch` byte tells the signer which K3 epoch to HKDF under.

**Push back**: Codex's recommended fix was "introduce K3EpochCounter plus wallet-path history or credential manifest keyed by stable actor_omni". The wallet-path-history option keeps the path migration in play and adds a manifest of "blob X is at path /wallet_v1/...". I rejected this in favor of "no path migration ever" — simpler, no manifest needed, no migration window. The manifest approach would have been more complex for no security benefit.

### Finding 4 [medium] — Signer-owned mapping vs chain-as-source-of-truth

**Codex's concern**: rev 3 declared chain authoritative but kept the omni→current_wallet mapping inside signer. Stale/rolled-back/compromised signer could lie about epoch without chain-level rejection.

**Author response**: ✅ Agree. **Fixed in rev 4** §3.5: added `K3EpochCounter` contract (single global on-chain counter). Workers verify chain epoch on every cred-fetch BEFORE trusting signer's KEK derivation. Signer ALSO checks chain epoch (defense in depth) but worker's check is the authoritative one.

**Refinement on Codex's recommendation**: Codex said "workers must compare signer responses against that counter before deriving KEKs or resolving wallet paths". I went further — the worker does the chain epoch check at THREE points: (a) cap-mint at broker (rejects cap minted under stale epoch); (b) cred-fetch at worker (rejects request claiming stale/future epoch); (c) signer self-check on derive-cred-kek (rejects internally inconsistent state). Triple verification because the chain RPC is cheap (~5ms cached, 99% cache hit) but the consequences of a missed verification are catastrophic.

**Push back**: I considered eliminating chain RPCs entirely by trusting signer + TEE attestation (signer in TEE with attested boot can't lie about its K3 epoch). Concluded: TEE attestation guarantees the signer's STARTING state, not its ongoing state (a freshly-attested signer running with a stale K3 due to slow event subscription is still possible). Chain RPC is the cleanest "live" check. Accept the ~5ms cost.

### What Codex didn't catch (author-noted, fixed in rev 4 anyway)

- **Anchor wallet was wrong concept entirely**. Codex didn't flag this — but matching arch.md §5/§5a's existing K11 design eliminates the anchor wallet's purpose. Switched to K10+K11 throughout per arch.md.
- **K3 rotation cost is O(1), not O(N)**. Codex's finding #4 fix indirectly enabled this — once K3EpochCounter is the source of truth, per-operator on-chain state doesn't need rotation. Reduced K3 rotation from "tx per operator" to "single global tx".
- **Payment service category was missing**. The per-service worker model in §3.4 didn't have payment as a category. Added in rev 4 with strict one-shot semantics + per-cap quotas + K11 for high-value.

### Overall assessment

Codex's four findings were genuine; addressing them strengthened the design substantially. The refinements (Codex finding #3's S3-path fix going further than the recommendation; Codex finding #4's triple verification) made the design simpler, not more complex. **No findings rejected; partial push-back on Finding 2 noted (K11-required-for-scope-revocation could be relaxed in a future rev if UX demands).**

---

## Revision log

- 2026-05-17 (**v2 rev 4** — current) — Major architectural alignment with arch.md §5/§5a + Codex-findings + multi-device-quorum recovery + payment-service worker. Net design changes from rev 3:
  - **Dropped anchor wallet concept** entirely. arch.md §5/§5a already specifies K11 (WebAuthn platform-authenticator credential, sealed in Secure Enclave / TPM / StrongBox) as the master device's hardware-attested recovery anchor — no separate hardware wallet, no seed phrase, biometric-gated. v2 rev 4 adopts K10/K11 directly and adds multi-master-device quorum + role bitfield (CAP_MINT / RECOVERY / SCOPE_MGMT) on top.
  - **Reordered bootstrap to arch.md §5 stages 0-3**: K10 generation (Stage 0, local) → identity ceremony (Stage 1, email/OAuth) → WebAuthn binding (Stage 2, K11 enrollment commits D_pub atomically) → SIWE → J1 (Stage 3). Rev 3 had identity ceremony FIRST and device-key second; that contradicted arch.md.
  - **Codex Finding #1 fix**: SidecarRegistry now binds `device_pubkey → (operator_omni, actor_omni, role, k11_cred_id, attestation)`. Each device serves ONE specific actor. Containment per arch.md §5a.5 — compromised agent K10 cannot mint as sibling agents.
  - **Codex Finding #2 fix**: All master-only mutations (scope grant/revoke, device add/revoke, K10 rotation) require fresh K11 WebAuthn assertion over the exact payload. K10 alone (no biometric) cannot escalate to master powers. Author push-back noted: scope revocation could be K10-only in a future rev for emergency UX, deferred.
  - **Codex Finding #3 fix**: S3 path keyed on `actor_omni_hex` instead of `master_wallet`. AWS PrincipalTag uses `agentkeys_actor_omni`. K3 rotation = ZERO S3 path migration. Author push-back: went further than Codex recommended (no manifest, no path history) by eliminating path rotation entirely.
  - **Codex Finding #4 fix**: `K3EpochCounter` contract on chain — single global counter, bumped once per K3 rotation. Workers verify chain epoch at three points (broker mint, worker fetch, signer derive) before trusting any K3-dependent operation. Triple verification because chain RPC is cheap and the consequences are catastrophic.
  - **Eliminated ActorRegistry** entirely (Q3 from earlier). signer is the source of truth for `actor_omni → current_master_wallet`; chain has only the global K3 epoch. Per-operator on-chain state doesn't rotate on K3 events; only the global counter does. K3 rotation cost: O(1) chain tx, not O(N).
  - **New `payment-service` worker** added in §3.4 with strict one-shot CAS-burn cap-token, tight per-cap quotas, and K11 required for high-value payments. Replay = impossible; double-spend = impossible.
  - **Audit-service sovereignty tiers** documented: hosted-with-anchor (default), self-hosted relay, direct-write — operator chooses. Hosted audit does NOT contradict self-sovereignty because chain-anchored Merkle roots allow operator-side detection of omission.
  - **Recovery flow rewritten** in §4.4 as multi-master-device M-of-N quorum using K11 biometric on registered RECOVERY-role devices. No seed phrase. No anchor wallet. No social recovery (third-party guardians). Self-sovereign throughout.
  - **Master/agent boundary policy** added in §4.5 — role bitfield semantics, default role assignments, threshold ladder, single-device-only fallback policy.
  - Codex review findings + author push-back appended as a new section before this revision log; comparison doc (rev 2/rev 3 contemporary reference) moved to `docs/archived/credential-storage-design-comparison-v2-pre-rev4.md`.
- 2026-05-17 (v2 initial) — Forward-looking design doc for credential-storage v2 endpoint. Five trust roots, component-role decomposition (daemon, broker, signer, workers, chain), cap-token + device-co-sig auth model, per-user KEK with TEE-protected signer, on-chain scope keyed on `actor_omni`, ZK-prover broker as v3+ direction. Extends arch.md §3a / §5a / §5a.5 / §6 / §7a / §9 / §13.
- 2026-05-17 (v2 rev 3) — **Reversed the rev 2 decision on chain-key + added K3-rotation tolerance via meta-tx + actor_omni redefinition.** Rev 2's "master_wallet on chain" claim was right that actor_omni indirection without meta-tx adds no privacy (msg.sender exposes the wallet anyway), but missed that meta-tx through relay-service wallets fixes that AND that K3 rotation requires actor_omni-anchored chain state to avoid migration storms. Net design changes:
  - **§3.0 (new) — Identity primer + actor_omni redefinition.** Master/agent tree explicitly laid out. actor_omni redefined as identity-bound (`SHA256("agentkeys" || identity_type || identity_value)`) instead of wallet-bound; survives K3 rotation. master_wallet becomes "current rotatable binding of the identity", maintained signer-internal.
  - **§3.5 (rewritten) — On-chain state keyed on actor_omni**, with all submissions via **meta-tx relay**. Solidity sketches updated: `scope[operator_omni][agent_omni]`, `SidecarRegistry[device_pubkey].operator_omni`, audit events name `operator_omni`. New `ActorRegistry` (optional) maps omni → current_wallet. Relay-service wallets pay gas; master_wallet stays off chain entirely.
  - **§6 (rewritten) — Why actor_omni on chain wins** when combined with meta-tx: K3-rotation tolerance, real privacy from chain observers (not just theater), consistency for wallet rotation. master_wallet stays in AWS PrincipalTag + signer-internal mapping.
  - **§7 (rewritten) — KEK anchored on actor_omni** with versioned K3 epochs. Envelope bumped to v0x03 to carry K3 epoch byte. Lazy migration on K3 rotation: existing blobs decrypt with old K3 epoch, new writes use current.
  - **§4.2 / §4.3 / §5.1 — Flows updated** to use operator_omni and agent_omni throughout, with explicit meta-tx submission steps. master_wallet appears only at the S3-path / AWS-PrincipalTag boundary, never in chain events.
  - **Master vs agent distinction made explicit** per arch.md §4 (master = SHA256-bound root; agents = HDKD-derived children with labels). §3.0 covers this upfront so subsequent flows can use operator/agent terminology unambiguously.
- 2026-05-17 (v2 rev 2) — Two corrections, both **later reverted in rev 3** as the deeper analysis showed they were locally right but globally wrong:
  - **On-chain key changed from `actor_omni` to `master_wallet`.** Argument: tx `msg.sender` exposes wallet anyway, so actor_omni adds no privacy. **Reverted in rev 3** because (a) meta-tx pattern keeps master_wallet off `msg.sender`, restoring privacy; (b) K3 rotation requires actor_omni-keyed state to avoid migration storms.
  - **ZK-proven cap mint moved from v3+ to v4+.** Kept in rev 3 — ZK proving is genuinely too slow for online per-cap minting (1-30 sec per ~100k-constraint circuit). v3 = audit-anchored cap mint (Merkle-batched on chain); v3.x = threshold-signed broker; v4+ = ZK contingent on sub-100ms proving tooling maturity.
