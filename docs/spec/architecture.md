# AgentKeys — Architecture (broker, signer, daemon, key flows)

**Audience:** anyone who needs to reason about AgentKeys end-to-end —
new contributors, security reviewers, ops, design partners. Use this
as the single visual + textual reference. Diagrams are Mermaid where
possible so they render in GitHub and copy cleanly into Figma.

**Status:** canonical (post-issue-#74). Supersedes `docs/stage7-wip.md`
(archived). Component inventory and language choices were absorbed
from the prior `architecture.md` revision.

**Companion docs (canonical for their narrow surface; this doc links
to them rather than duplicating):**

- [`signer-protocol.md`](signer-protocol.md) — `/dev/*` wire contract
- [`threat-model-key-custody.md`](threat-model-key-custody.md) —
  retroactive-confidentiality + key custody position
- [`heima-gaps-vs-desired-architecture.md`](heima-gaps-vs-desired-architecture.md)
  — what current-Heima is missing vs the desired AgentKeys
  architecture
- [`credential-backend-interface.md`](credential-backend-interface.md)
  — 15-method `CredentialBackend` trait
- [`plans/issue-74-dev-key-service-plan.md`](plans/issue-74-dev-key-service-plan.md)
  — dev_key_service signer (issue #74 step 1)
- [`plans/issue-74-step-1c-device-key-auth.md`](plans/issue-74-step-1c-device-key-auth.md)
  — device-key auth on `/dev/*` (issue #74 step 1c, planned)

---

## 1. Component map

```mermaid
flowchart LR
  subgraph WS["Operator workstation"]
    CLI["agentkeys CLI<br/>(Rust)"]
  end

  subgraph SBX["Agent sandbox"]
    DMN["agentkeys-daemon<br/>(Rust, MCP server)"]
    PRV["provisioner orchestrator<br/>(Rust)"]
    BRO["browser scraper<br/>(TypeScript + Playwright)"]
    DMN -->|spawns subprocess| PRV
    PRV -->|spawns subprocess| BRO
  end

  subgraph BH["Broker host (EC2)"]
    BRK["agentkeys-broker-server<br/>(Rust, Axum :8091)"]
    SIG["agentkeys-mock-server --signer-only<br/>(Rust, Axum :8092)<br/>= dev_key_service"]
    BCK["agentkeys-mock-server<br/>(Rust, Axum :8090, loopback)<br/>= legacy session/credential backend"]
  end

  subgraph CLOUD["AWS"]
    STS["AWS STS<br/>(AssumeRoleWithWebIdentity)"]
    S3["S3 / SES / etc<br/>(PrincipalTag-gated)"]
  end

  CLI -->|init: email/OAuth2 + SIWE| BRK
  CLI -->|init: derive wallet| SIG
  DMN -->|mint OIDC JWT| BRK
  DMN -->|sign-message<br/>per call| SIG
  DMN -->|AssumeRoleWithWebIdentity| STS
  STS --> S3
  BRK -->|tier-2 reachability probe| BCK
  CLI -. saved session JWT .-> DMN
```

**Three independent trust boundaries, three independent products:**

| Service | Public hostname (typical) | Holds | Role |
|---|---|---|---|
| Broker | `broker.litentry.org` | ES256 OIDC keypair, ES256 session keypair, audit DB | Mints session JWTs after identity ceremony; mints OIDC JWTs from session JWTs; never holds AWS principals at runtime |
| Signer (`dev_key_service`) | `signer.litentry.org` (post-step-1b) | `DEV_KEY_SERVICE_MASTER_SECRET` (32 bytes hex) | Derives EVM wallets from `omni_account` and signs EIP-191 messages on the operator's behalf. Replaceable with a TEE worker post-step-2. |
| Backend (mock-server) | `127.0.0.1:8090` (loopback only) | Legacy session/credential SQLite | Tier-2 reachability target for the broker; legacy `/session/*` + `/credential/*` endpoints used by the daemon's pair-flow |

**Why three?** Compromise of any one process must NOT enable
impersonating the others. Broker compromise can't extract the master
secret (it's on the signer). Signer compromise can't mint session
JWTs (the keypair is on the broker). Backend compromise can't sign
EVM messages and can't mint cloud creds. The split is enforced by
process boundary and (at production deployment) by separate listener
+ host firewall.

---

## 2. Trust boundaries (where keys live, who can see them)

```mermaid
flowchart TB
  subgraph TB1["Trust boundary 1 — Operator workstation"]
    OS_KC["OS keychain<br/>session JWT<br/>device privkey (post-step-1c)"]
    EVM_W["MetaMask / hardware wallet<br/>(only if identity_type = evm)"]
  end

  subgraph TB2["Trust boundary 2 — Broker process"]
    SESS_KP["session ES256 keypair<br/>(BROKER_SESSION_KEYPAIR_PATH)"]
    OIDC_KP["OIDC ES256 keypair<br/>(BROKER_OIDC_KEYPAIR_PATH)"]
    AUDIT_DB["audit SQLite<br/>(BROKER_AUDIT_DB_PATH)"]
  end

  subgraph TB3["Trust boundary 3 — Signer process (dev_key_service)"]
    MASTER["DEV_KEY_SERVICE_MASTER_SECRET<br/>(/etc/agentkeys/dev-key-service.env)"]
    SIGNER_KP["per-omni derived secp256k1 keys<br/>(in memory only, derived on demand,<br/>never persisted, never logged, never returned)"]
  end

  subgraph TB4["Trust boundary 4 — Backend (mock-server)"]
    SES_DB["session + credential SQLite<br/>(legacy)"]
  end

  subgraph TB5["Trust boundary 5 — AWS"]
    AWS_KMS["IAM roles, KMS, S3 policies"]
  end

  OS_KC -. session_jwt .-> SESS_KP
  OS_KC -. derive_address(omni) .-> SIGNER_KP
  EVM_W -. SIWE signature .-> SESS_KP
  OIDC_KP -. OIDC JWT .-> AWS_KMS
```

**Compromise-blast-radius table:**

| Boundary breached | What attacker gains | What they CANNOT do |
|---|---|---|
| Operator workstation | Stolen session JWT (replay until exp); stolen device key (post-step-1c, sign on operator's behalf until rotation) | Cannot derive wallets for other operators; cannot mint session JWTs for new identities |
| Broker process | Mint session JWTs for any omni; mint OIDC JWTs (gated by JWT auth, defeated by full broker compromise) | Cannot derive wallets; cannot sign EIP-191 messages; cannot AssumeRole (no AWS principal at broker) |
| Signer process (current step-1) | Derive any wallet from any omni; sign any EIP-191 message for any omni | Cannot mint session JWTs; cannot mint OIDC JWTs; cannot reach AWS |
| Signer process (post-step-1c) | Above, AND can verify (but not forge) device-signed requests | Same as above; per-request device signatures still gate the call surface |
| Backend (mock-server) | Stale legacy session bearer; credential ciphertext (today's mock storage) | Cannot affect Stage 7 mint paths (broker verifies session JWTs locally post-issue-#71) |
| AWS account | Game over for that operator's data scope | None of the above; AWS compromise is its own incident class |

**Note on signer-process compromise.** Today's `dev_key_service` is
the **dev-stage** placeholder. Compromising the signer host = full
master-secret leak = every wallet for every operator is forge-able
forever. The TEE worker (issue #74 step 2) closes this: master secret
is sealed inside the enclave; host root no longer suffices.
Step-1c device-key auth additionally bounds the impact of broker
compromise on the signer call surface.

---

## 3. Key inventory

The complete list of cryptographic material in the system. Use this
as the source-of-truth when designing the Figma trust-flow diagram.

| # | Key | Type | Lives in | Role | Lifecycle |
|---|---|---|---|---|---|
| K1 | Broker session keypair | ES256 (P-256) | Broker process; pinned file at `BROKER_SESSION_KEYPAIR_PATH` (mode 0600); pubkey exported to `*.pub.pem` (mode 0644) for signer | Signs session JWTs (issued post-identity-ceremony, bound to omni + wallet) | Generated at first broker boot; preserved across re-deploys; manual rotation procedure TBD |
| K2 | Broker OIDC keypair | ES256 (P-256) | Broker process; pinned file at `BROKER_OIDC_KEYPAIR_PATH` (mode 0600); pubkey published at `<broker>/.well-known/jwks.json` | Signs OIDC JWTs minted by `/v1/mint-oidc-jwt` (consumed by AWS STS / GCP WIF / Tencent CAM via `AssumeRoleWithWebIdentity`) | Generated at first broker boot; rotation requires re-registering the OIDC provider in cloud IAM |
| K3 | Dev-signer master secret | 32 raw bytes (hex-encoded) | `/etc/agentkeys/dev-key-service.env` (mode 0600, owner agentkeys); auto-generated by `setup-broker-host.sh` | HKDF input for deriving per-omni secp256k1 wallets | Generated once on first broker-host setup; **never rotate** (rotation invalidates every previously-derived wallet); replaced by sealed enclave secret post-step-2 |
| K4 | Per-omni derived wallet | secp256k1 | Signer process (in memory only, derived on demand from K3 + omni; never persisted, never logged, never returned over wire) | The "managed EVM wallet" for an operator who authenticated via email/OAuth2/passkey — used by signer to sign EIP-191 messages on operator's behalf | Deterministic; same `(K3, omni)` always → same wallet; lifecycle == lifecycle of K3 |
| K5 | EVM-wallet (operator-held) | secp256k1 | Operator's MetaMask / hardware wallet / `cast wallet` | Identity authenticator for `identity_type = evm`; signs SIWE messages directly (this path bypasses K3/K4 entirely) | Operator-managed; outside AgentKeys' lifecycle |
| K6 | Session JWT | JWT (ES256 by K1) | Operator's OS keychain (via `agentkeys-core::session_store`) on the workstation; in daemon memory at runtime | Bearer credential for `/v1/mint-oidc-jwt`, `/v1/wallet/*`, post-step-1b also for `/dev/*` | TTL = `BROKER_SESSION_JWT_TTL_SECONDS` (default 18000s = 5h); re-mint requires re-running the identity ceremony |
| K7 | OIDC JWT | JWT (ES256 by K2) | Daemon memory only (transient — fetched per mint) | Web-identity token for `AssumeRoleWithWebIdentity` against AWS STS | TTL = `BROKER_OIDC_JWT_TTL_SECONDS` (bounded `[60, 3600]`, default 300s) |
| K8 | AWS temp credentials | STS access key + secret + session token | Daemon memory only (transient — refetched per provision/mint) | Direct AWS API access scoped by PrincipalTag = wallet | 1-hour TTL (STS default); short by design |
| K9 | DKIM keypair (per outbound domain) | Ed25519 | Stage 6 design — currently TEE-only, not yet implemented | Outbound mail signing for federated email | TBD per Stage 6 spec ([`heima-gaps §4`](heima-gaps-vs-desired-architecture.md)) |
| K10 | Device key (planned, step-1c) | secp256k1 | Operator's OS keychain (per workstation, not per identity); pubkey registered at the broker as a session JWT claim | Per-request signature on `/dev/sign-message` calls — eliminates broker-as-SPOF for signer auth | Generated at `agentkeys init`; bound to a session JWT; rotated by re-init; TTL = session JWT TTL |

**Notation throughout the rest of this doc:** the K1–K10 indices
above are referenced directly so any flow can be unambiguously
mapped back to which key signed/verified/wrapped what.

---

## 4. Identity model

```mermaid
flowchart LR
  ID["raw identity<br/>(email, OAuth2 sub, EVM addr, etc.)"]
  OMNI["omni_account<br/>= SHA256('agentkeys' || identity_type || identity_value)"]
  WALLET["derived wallet<br/>(via K3 + K4 in signer)"]
  EVM_OMNI["evm_omni<br/>= SHA256('agentkeys' || 'evm' || lower(wallet))"]
  SESS_JWT["session JWT<br/>(K6, claims bound to evm_omni + wallet)"]

  ID -->|"agentkeys init"| OMNI
  OMNI -->|"POST /dev/derive-address"| WALLET
  WALLET -->|"POST /v1/auth/wallet/start +<br/>POST /dev/sign-message +<br/>POST /v1/auth/wallet/verify"| EVM_OMNI
  EVM_OMNI -->|"emit"| SESS_JWT

  OMNI -. /v1/wallet/link .-> EVM_OMNI
```

**Two omnis per operator, both correct, both load-bearing:**

- **Identity omni** (`OMNI`) — derived from the user's authenticator
  (email, OAuth2 sub, etc.). The signer uses this to derive the
  managed wallet. The operator's CLI/daemon uses this to call
  `/dev/sign-message`.
- **EVM omni** (`EVM_OMNI`) — derived from the **derived wallet
  address**. The session JWT is bound to this; the broker stamps
  audit rows under it; the OIDC JWT carries it as
  `agentkeys_user_wallet`.

The identity omni and the EVM omni are linked at the broker via
`POST /v1/wallet/link` so any linked identity can recover the same
EVM omni.

For an operator who authenticates with `identity_type = evm` (their
own wallet via SIWE, no dev_key_service involvement), the two omnis
are independent: identity omni = `("evm", their_real_wallet)`, EVM
omni = `("evm", their_real_wallet)`. They are equal in this case
because the user's identity IS their wallet.

---

## 5. Cold-start (init) sequence

```mermaid
sequenceDiagram
  autonumber
  participant Op as Operator
  participant CLI as agentkeys CLI
  participant Brk as Broker
  participant Sig as Signer (dev_key_service)
  participant KC as OS Keychain

  Op->>CLI: agentkeys init --email alice@x.com --broker-url B --signer-url S
  CLI->>Brk: POST /v1/auth/email/request {email}
  Brk-->>CLI: {request_id, status: "sent"}
  Note over Brk,Op: Magic link emailed; operator clicks
  Op-->>Brk: GET /v1/auth/email/landing/<id>
  loop poll
    CLI->>Brk: GET /v1/auth/email/status/<id>
    Brk-->>CLI: {status: "verified", session_jwt: J0, omni_account: O_id}
  end
  CLI->>Sig: POST /dev/derive-address {O_id}
  Sig->>Sig: HKDF(K3, O_id) → K4_priv → addr A
  Sig-->>CLI: {address: A, key_version: 1}
  CLI->>Brk: POST /v1/wallet/link {evm, A}<br/>Authorization: Bearer J0
  Brk-->>CLI: 200 (links O_id ↔ A)
  CLI->>Brk: POST /v1/auth/wallet/start {address: A}
  Brk-->>CLI: {request_id, siwe_message: M}
  CLI->>Sig: POST /dev/sign-message {O_id, message_hex: hex(M)}
  Sig->>Sig: derive K4_priv from O_id; sign EIP-191(M) → sig
  Sig-->>CLI: {signature: sig, address: A}
  CLI->>Brk: POST /v1/auth/wallet/verify {request_id, signature: sig}
  Brk->>Brk: ecrecover → A; mint session JWT J1<br/>(claims: evm_omni, wallet=A)
  Brk-->>CLI: {session_jwt: J1, omni_account: O_evm, wallet_address: A}
  CLI->>KC: persist J1 + (post-step-1c: device privkey)
```

**Key takeaways:**

- The signer is called **twice** at init: once to derive the address
  (so the daemon knows what to link), once to sign the SIWE
  challenge.
- The operator's `J0` (email-omni session) is **transient** — used
  only for `/v1/wallet/link`. The `J1` (evm-omni session) is the
  one persisted.
- `/dev/sign-message` here uses a normal mock-server URL today; will
  be `signer.<zone>` post-step-1b.
- Step-1c adds a device-pubkey claim binding inside the magic-link
  URL (so the broker mints `J1` with `agentkeys_device_pubkey`
  bound).

---

## 6. Per-mint sequence (issue #71 Option A — daemon-side)

```mermaid
sequenceDiagram
  autonumber
  participant Dmn as agentkeys-daemon
  participant Brk as Broker
  participant STS as AWS STS
  participant S3 as S3 (PrincipalTag-gated)

  Dmn->>Brk: POST /v1/mint-oidc-jwt<br/>Authorization: Bearer J1
  Brk->>Brk: verify_session_jwt(J1, K1.pubkey)<br/>extract evm_omni + wallet
  Brk->>Brk: mint OIDC JWT J2 signed by K2<br/>(claims: aud=sts.amazonaws.com, agentkeys_user_wallet=A,<br/>aws.amazon.com/tags={principal_tags:{...:[A]}})
  Brk-->>Dmn: {jwt: J2}
  Dmn->>STS: AssumeRoleWithWebIdentity(role_arn, J2)
  STS->>STS: verify J2 sig vs broker JWKS<br/>extract claim → session tags
  STS-->>Dmn: {AccessKeyId, SecretAccessKey, SessionToken} = K8
  Dmn->>S3: GetObject bots/A/file (with K8)
  S3->>S3: PrincipalTag check<br/>aws:PrincipalTag/agentkeys_user_wallet == A
  S3-->>Dmn: bytes (or AccessDenied if A != prefix wallet)
```

**Three things AgentKeys validates here that a static-IAM-user
deployment cannot:**

1. **Per-omni cred scoping.** S3 enforces the prefix match against
   the assumed-role session's PrincipalTag — by AWS policy engine,
   not by app code.
2. **No long-lived AWS principal at the broker.** Issue #71 Option A
   moved the broker off `sts:AssumeRole` (which required broker IAM
   creds) onto `sts:AssumeRoleWithWebIdentity` (driven by JWT). The
   broker holds zero AWS material at runtime.
3. **Daemon-side mint.** The provisioner runs the entire
   STS-call client-side, only bouncing through the broker for the
   JWT. Broker compromise affects the JWT-signing surface, not the
   STS call itself.

---

## 7. Pluggable surfaces

The architecture is intentionally pluggable on four axes. Each axis
has a default v0/v0.1 implementation and a documented swap-in path.

| Axis | v0/v0.1 default | Future swap | Swap mechanism |
|---|---|---|---|
| **Auth method** (broker-side identity verification) | `wallet_sig` (SIWE) + `email_link` + `oauth2_google` | passkey, OAuth2/Apple, OAuth2/GitHub, custom OIDC | Trait-implementing plugin in [`crates/agentkeys-broker-server/src/plugins/auth/`](../../crates/agentkeys-broker-server/src/plugins/auth/); enabled via `BROKER_AUTH_METHODS` env var |
| **Signer backend** (`/dev/*` implementation) | `dev_key_service` HKDF (issue #74 step 1) | TEE worker (sealed master secret, attested mTLS — issue #74 step 2); future threshold-MPC | Replaces the binary behind `signer.<zone>` URL; wire shape pinned by [`signer-protocol.md`](signer-protocol.md) |
| **Audit destination** (mint + auth audit log) | SQLite at `BROKER_AUDIT_DB_PATH` | Heima parachain, Ethereum L2, permissioned chain (Hyperledger / Quorum / Aliyun BaaS), TEE-attested append-only log, AWS CloudTrail | Trait surface in [`crates/agentkeys-broker-server/src/plugins/audit/`](../../crates/agentkeys-broker-server/src/plugins/audit/) |
| **Vault backend** (where credential ciphertext lives — Stage 8) | `s3://agentkeys-vault/<wallet>/...` (PrincipalTag-gated) | IPFS / Filecoin / Arweave content-addressed multi-backend; on-chain pointer + hash | Per [`threat-model-key-custody.md` §4 + §9](threat-model-key-custody.md) |

**Pluggability is the point.** No single backend is load-bearing for
the architecture; the contracts (auth-plugin trait, signer-protocol,
audit trait, vault interface) are. This is what lets:

- A China-deployment operator point audit at a permissioned chain
  without touching the rest.
- A self-hosted operator skip the chain entirely (SQLite is a
  complete v0.1 audit destination per
  [§7 audit-destination row 4](#7-pluggable-surfaces)).
- The TEE worker swap into the signer slot post-issue-#74 step 2
  with zero daemon/CLI code change.

---

## 8. Cargo workspace

```
agentkeys/                                  # repo root
├── crates/
│   ├── agentkeys-types/                    # shared types (Identity, Session, ...)
│   ├── agentkeys-core/                     # CredentialBackend trait, signer_client,
│   │                                       #   init_flow, mock_client, session_store
│   ├── agentkeys-mock-server/              # backend (loopback) + signer (--signer-only)
│   │   ├── src/dev_key_service.rs          # K3/K4: HKDF + secp256k1 + EIP-191
│   │   └── src/handlers/dev_keys.rs        # /dev/derive-address + /dev/sign-message
│   ├── agentkeys-broker-server/            # K1/K2: session + OIDC JWT minting,
│   │                                       #   wallet-sig + email-link + OAuth2 plugins
│   ├── agentkeys-cli/                      # agentkeys binary (init, store, read, run,
│   │                                       #   provision, signer derive/sign, whoami)
│   ├── agentkeys-daemon/                   # daemon binary (MCP server, signer-flow init)
│   ├── agentkeys-mcp/                      # MCP adapter library (used by daemon)
│   └── agentkeys-provisioner/              # Rust orchestrator that spawns the TS scraper
└── provisioner-scripts/                    # TypeScript + Playwright scrapers
    └── src/scrapers/openrouter.ts          # one file per service (v0)
```

**One language per process, never per process.** All trust-boundary
code is Rust. The Playwright scraper is the one TypeScript exception
— it runs as a subprocess of the provisioner orchestrator and never
sees crypto material. Cross-language interaction is at the process
boundary (stdin/stdout JSON), never in-process FFI.

| Crate | Purpose |
|---|---|
| `agentkeys-types` | Shared types — `Session`, `WalletAddress`, `Scope`, `AuthToken`, `AgentIdentity`, audit + provision events |
| `agentkeys-core` | The library: `CredentialBackend` trait, `MockHttpClient`, `SignerClient` + `HttpSignerClient`, `init_flow` (broker email/OAuth2 → derive → link → SIWE chain), `session_store` (OS keychain + file fallback) |
| `agentkeys-mock-server` | Two binaries from one source: legacy backend (loopback `:8090`, `/session/*` + `/credential/*` + `/audit/*`) AND signer (`--signer-only` mode at `:8092`, `/dev/*` only) |
| `agentkeys-broker-server` | Stage 7 broker: `/v1/auth/{wallet,email,oauth2}/*`, `/v1/mint-{oidc-jwt,aws-creds}`, `/v1/wallet/{link,links,recover/lookup}`, `/v1/grant/*`, `/.well-known/{openid-configuration,jwks.json}`, `/healthz`, `/readyz`, `/metrics` |
| `agentkeys-cli` | The `agentkeys` binary — `init`, `store`, `read`, `run`, `provision`, `link`, `recover`, `revoke`, `teardown`, `usage`, `signer derive/sign`, `whoami`, `inbox` |
| `agentkeys-daemon` | The `agentkeys-daemon` binary — first-time bootstrap (signer-flow or pair-flow); MCP server over stdio post-bootstrap |
| `agentkeys-mcp` | MCP protocol adapter — used by the daemon to expose `agentkeys.provision`, etc., to the agent process |
| `agentkeys-provisioner` | Spawns the TS scraper subprocess, encrypts obtained creds, submits to backend |

---

## 9. Component inventory (preserved from prior architecture revision)

| # | Component | Where it runs | Primary job |
|---|---|---|---|
| 1 | `agentkeys` CLI | Operator's workstation | `init`, `store`, `read`, `run`, `provision`, `signer ...`, `whoami`, `link`, `recover`, `revoke`, `teardown`, `usage`, `feedback` |
| 2 | `agentkeys-daemon` | Inside agent sandbox (or desktop / Pi / cloud LLM environment) | Stores session in OS keychain + file fallback, hosts MCP + CLI sockets, spawns provisioner as MCP tool |
| 3 | MCP adapter | Same process as #2 | Speaks MCP on stdio/socket, translates to daemon internal API |
| 4 | CLI adapter | Same process as #2 | Line-protocol on Unix socket for `agentkeys read` etc. |
| 5 | Broker (`agentkeys-broker-server`) | EC2 broker host | Stage 7 — auth ceremonies, session JWT minting, OIDC JWT minting, audit log |
| 6 | Signer (`agentkeys-mock-server --signer-only`) | EC2 broker host (separate listener at `:8092`) | dev_key_service — `/dev/derive-address` + `/dev/sign-message`; replaceable by TEE worker |
| 7 | Provisioner orchestrator | Inside agent sandbox, subprocess of #2 | Spawns browser automation, encrypts credentials |
| 8 | Browser automation scripts | Inside agent sandbox, child of #7 | Playwright/CDP signup flows for OpenRouter + future services |
| 9 | Ephemeral email integration | Inside agent sandbox, child of #7 | Reads verification codes from S3-backed inbound mail |
| 10 | Backend (mock-server) | EC2 broker host (loopback `:8090`) | Legacy `/session/*` + `/credential/*` + `/audit/*` (broker's Tier-2 reachability target; will be deprecated as callers migrate to the new flow) |
| 11 | Audit log indexer | Post-MVP; own host | Reads broker audit DB, exposes for `agentkeys usage` queries |
| 12 | Web GUI | Post-MVP, user's device, Tauri | Master management UI, live audit, wallet balance |
| 13 | TEE worker | Post-issue-#74 step 2 | Replaces #6 with sealed master secret + remote attestation |
| 14 | `@agentkeys/daemon` npm package | Cloud LLM environments (ChatGPT / Claude.ai) | TS wrapper around prebuilt #2 binary |

---

## 10. Language choices (preserved)

**Rust for everything in the trust boundary.** Browser automation
(#8) is the one TypeScript exception — anti-bot tooling
(`playwright-extra`, `puppeteer-extra-plugin-stealth`,
`patchright`) is mature in TS, weak/absent in Rust.

| Component | Language | Reason |
|---|---|---|
| #1, #2, #3, #4, #5, #6, #7, #10, #13 | Rust | Security-critical; cross-compiles cleanly; the ecosystem (subxt, alloy, k256, jsonwebtoken, axum) covers our needs |
| #8, #9 | TypeScript + Playwright | One exception; ecosystem reality. Subprocess of #7 only — never in the cryptographic path |
| #11 | Rust (or TS Subsquid for v0.1) | Read-only, not in trust boundary; either is fine |
| #12 | Rust (Tauri backend) + TS (frontend) | Reuses #1 directly; UI layer is TS |
| #14 | TS wrapper of Rust binary | esbuild/biome/swc pattern; postinstall picks the right prebuilt #2 binary |

Approx Rust proportion: **~80% of lines, 100% of security-critical
path.**

---

## 11. Deployment topology

```mermaid
flowchart TB
  subgraph LAPTOP["Operator workstation (laptop / CI / cloud sandbox)"]
    CLI2["agentkeys CLI"]
    DMN2["agentkeys-daemon"]
  end

  subgraph EDGE["nginx (broker host, :443 with Let's Encrypt)"]
    BRK_HOST["broker.litentry.org"]
    SIG_HOST["signer.litentry.org<br/>(post-step-1b)"]
  end

  subgraph BACKEND["broker host loopback"]
    BRK2["agentkeys-broker-server :8091"]
    SIG2["agentkeys-mock-server --signer-only :8092"]
    BCK2["agentkeys-mock-server :8090<br/>(legacy backend)"]
  end

  CLI2 -->|HTTPS| BRK_HOST
  CLI2 -->|HTTPS| SIG_HOST
  DMN2 -->|HTTPS| BRK_HOST
  DMN2 -->|HTTPS| SIG_HOST
  BRK_HOST --> BRK2
  SIG_HOST --> SIG2
  BRK2 -. Tier-2 reachability probe .-> BCK2
```

**Hard rules:**

- `broker.<zone>` and `signer.<zone>` are separate nginx server
  blocks with separate certs. They route to different loopback
  ports.
- The legacy backend at `:8090` is **never** publicly exposed; only
  the broker on the same host reaches it (Tier-2 probe + a few
  legacy-flow callbacks).
- Host firewall: drop public ingress to anything except `:443`.
  Nginx is the only public listener.
- Daemons that run remotely (operator's laptop, CI, cloud sandbox)
  reach `broker.<zone>` and `signer.<zone>` over public TLS.
  Daemons co-located on the broker host (atypical) can use loopback
  directly.

The full bring-up runbook lives in
[`scripts/setup-broker-host.sh`](../../scripts/setup-broker-host.sh)
(idempotent; auto-generates K3 on first run; preserves K1/K2/K3
across re-deploys). Operator-facing commentary in
[`operator-runbook-stage7.md`](../operator-runbook-stage7.md).

---

## 12. Cross-references

- **`/dev/*` wire contract** — [`signer-protocol.md`](signer-protocol.md)
- **K3 master-secret threat model** — [`threat-model-key-custody.md`](threat-model-key-custody.md)
  (note: doc primarily covers Stage 8 vault, but the
  retroactive-confidentiality argument applies to K3 by extension)
- **Broker pluggable trait surfaces** —
  [`plans/issue-64/PLAN.md`](plans/issue-64/PLAN.md) §3.5
- **dev_key_service plan** —
  [`plans/issue-74-dev-key-service-plan.md`](plans/issue-74-dev-key-service-plan.md)
- **Device-key auth plan (post-step-1b)** —
  [`plans/issue-74-step-1c-device-key-auth.md`](plans/issue-74-step-1c-device-key-auth.md)
- **Operator runbook** —
  [`../operator-runbook-stage7.md`](../operator-runbook-stage7.md)
- **End-to-end demo** —
  [`../stage7-demo-and-verification.md`](../stage7-demo-and-verification.md)
- **Cloud-side IAM + DNS + cert** —
  [`../cloud-setup.md`](../cloud-setup.md)
- **Stage 8 vault** —
  [`../stage8-wip.md`](../stage8-wip.md)
- **Heima vs current architecture gaps** —
  [`heima-gaps-vs-desired-architecture.md`](heima-gaps-vs-desired-architecture.md)
- **Pre-Stage-7 architecture history** —
  [`../archived/operator-runbook-pre-stage7.md`](../archived/operator-runbook-pre-stage7.md)
  (archived)

---

## 13. What's NOT in this doc

- **Per-endpoint request/response shapes.** Each endpoint surface
  has its own canonical doc — the broker's openapi-style table is
  in `plans/issue-64/PLAN.md`; the signer's is `signer-protocol.md`;
  the legacy backend's is `credential-backend-interface.md`.
- **Per-step environment-variable inventory.** That's
  `operator-runbook-stage7.md`.
- **Detailed threat model for retroactive confidentiality.** That's
  `threat-model-key-custody.md`.
- **Stage-by-stage build progression history.** That's
  `plans/development-stages.md`.
- **MetaMask / Foundry tooling instructions.** Removed in
  issue #74 step 1 — operators no longer hold local EVM keys
  unless they want to (`identity_type = evm` is supported but not
  required).

---

*This is a living document. Update it when the component map, key
inventory, trust-boundary table, or deployment topology changes.
For Figma-design use: the K-numbered key inventory (§3) and the
identity-model diagram (§4) are the most directly transferable.*
