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
  subgraph TB1["Trust boundary 1 — Master workstation"]
    OS_KC["OS keychain<br/>session JWT (K6)<br/>device privkey K10 (post-step-1c)"]
    PA["Platform authenticator<br/>(Secure Enclave / TPM / StrongBox)<br/>K11 — sealed in hardware"]
    EVM_W["MetaMask / hardware wallet<br/>(only if identity_type = evm)"]
  end

  subgraph TB1A["Trust boundary 1A — Agent machine"]
    AGENT_KC["OS keychain OR file backend<br/>session JWT (K6) +<br/>device privkey K10<br/>NO K11"]
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
  PA -. WebAuthn enroll/get (binding only) .-> SESS_KP
  EVM_W -. SIWE signature .-> SESS_KP
  AGENT_KC -. session_jwt .-> SESS_KP
  AGENT_KC -. /dev/sign-message .-> SIGNER_KP
  OS_KC -. mint link-code .-> AGENT_KC
  OIDC_KP -. OIDC JWT .-> AWS_KMS
```

**Compromise-blast-radius table:**

| Boundary breached | What attacker gains | What they CANNOT do |
|---|---|---|
| **Master workstation** (host root, but no hardware presence) | Stolen session JWT (replay until exp); stolen K10 device key (sign on operator's behalf until rotation) | **Cannot complete WebAuthn ceremony** to bind a new device or rotate K10 — K11 sealed in Secure Enclave/TPM requires biometric/PIN. Cannot derive wallets for other operators; cannot mint session JWTs for new identities. |
| **Master workstation** (full compromise WITH hardware presence — e.g. attacker physically at machine and unlocks biometric) | Above, plus: rebind K10 to attacker-controlled pubkey, rotate device key, mint link codes for new agents | Same as above — bounded to this operator's omni; cannot reach other operators' material |
| **Agent machine** (sandbox VM, host root) | Stolen K10; stolen session JWT (replay until session-JWT TTL expires) | Cannot rebind without master-issued link code; master link-code issuance is gated by master J1 (which is gated by master K11). Cannot escalate to master compromise. |
| Broker process | Mint session JWTs for any omni; mint OIDC JWTs (gated by JWT auth, defeated by full broker compromise) | Cannot derive wallets; cannot sign EIP-191 messages; cannot AssumeRole (no AWS principal at broker). **Post-step-1c: cannot forge device signatures** because per-request K10 signature is verified at signer — broker compromise alone cannot make the signer accept an attacker request. |
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
| K3 | Dev-signer master secret | 32 raw bytes (hex-encoded) | `/etc/agentkeys/dev-key-service.env` (mode 0600, owner agentkeys); auto-generated by `setup-broker-host.sh` | HKDF input for deriving per-actor-omni secp256k1 wallets (one per node in the HDKD actor tree — see §4) | Generated once on first broker-host setup; **never rotate** (rotation invalidates every previously-derived wallet); replaced by sealed enclave secret post-step-2 |
| K4 | Per-actor derived wallet | secp256k1 | Signer process (in memory only, derived on demand from K3 + actor_omni; never persisted, never logged, never returned over wire) | The managed EVM wallet for one node in the HDKD actor tree (master OR a specific agent). Different actor omni → different wallet → different AWS PrincipalTag → different S3 prefix. Used by signer to sign EIP-191 messages on that actor's behalf. | Deterministic; same `(K3, actor_omni)` always → same wallet; lifecycle == lifecycle of K3 |
| K5 | EVM-wallet (operator-held) | secp256k1 | Operator's MetaMask / hardware wallet / `cast wallet` | Identity authenticator for `identity_type = evm`; signs SIWE messages directly (this path bypasses K3/K4 entirely) | Operator-managed; outside AgentKeys' lifecycle |
| K6 | Session JWT | JWT (ES256 by K1) | Operator's OS keychain (via `agentkeys-core::session_store`) on the workstation; in daemon memory at runtime | Bearer credential for `/v1/mint-oidc-jwt`, `/v1/wallet/*`, post-step-1b also for `/dev/*` | TTL = `BROKER_SESSION_JWT_TTL_SECONDS` (default 18000s = 5h); re-mint requires re-running the identity ceremony |
| K7 | OIDC JWT | JWT (ES256 by K2) | Daemon memory only (transient — fetched per mint) | Web-identity token for `AssumeRoleWithWebIdentity` against AWS STS | TTL = `BROKER_OIDC_JWT_TTL_SECONDS` (bounded `[60, 3600]`, default 300s) |
| K8 | AWS temp credentials | STS access key + secret + session token | Daemon memory only (transient — refetched per provision/mint) | Direct AWS API access scoped by PrincipalTag = wallet | 1-hour TTL (STS default); short by design |
| K9 | DKIM keypair (per outbound domain) | Ed25519 | Stage 6 design — currently TEE-only, not yet implemented | **DKIM = DomainKeys Identified Mail (RFC 6376).** A per-domain signing key used to sign outbound email headers; the matching public key is published as a DNS TXT record at `<selector>._domainkey.<domain>`. Receiving mail servers fetch the pubkey via DNS, verify the signature, and use the result to decide whether the message originated from a server authorized for that domain — input to spam filtering, deliverability, and brand-impersonation defense. AgentKeys needs K9 because Stage 6 sends mail FROM operator-controlled sub-domains (e.g. for OpenRouter signups via plus-aliased addresses) and we hold the signing key ourselves rather than delegating to SES (so AWS never sees the plaintext content) — see [`heima-gaps §4`](heima-gaps-vs-desired-architecture.md). | TBD per Stage 6 spec ([`heima-gaps §4`](heima-gaps-vs-desired-architecture.md)) |
| K10 | Device key (planned, step-1c) | secp256k1 | **Master**: OS keychain (TouchID-backed on macOS, etc.) on the operator's workstation. **Agent**: OS keychain when available, else file backend at `~/.agentkeys/daemon-<wallet>/session.json` (mode 0600) — see §5a.4.2. Pubkey registered at the broker as a session JWT claim (`agentkeys_device_pubkey`). | Per-request signature on `/dev/sign-message` calls — eliminates broker-as-SPOF for signer auth | Generated at init stage 0 (per §5); bound by master init per §5a.1 OR agent bootstrap per §5a.2; rotated by `agentkeys device rotate` per §5a.3.2 or by re-init; TTL = session JWT TTL |
| K11 | WebAuthn platform-authenticator credential (planned v0.2, master only) | Per-RP credential (typically EC P-256 on macOS Secure Enclave / Windows TPM / Android StrongBox) | **Master only.** Sealed inside the platform authenticator's hardware boundary; cannot be exfiltrated even by host-OS root. Credential ID published at the broker as a session JWT claim (`agentkeys_webauthn_cred`). | Hardware-attested **user-presence proof at master binding ceremonies** (init per §5a.1, new-device per §5a.3.1, rotation per §5a.3.2). NOT used per-request — K10 covers per-request signing without biometric. | Created at master init; survives K10 rotations; revoked by removing the credential from the broker's bound list or by destroying the platform authenticator |

**Notation throughout the rest of this doc:** the K1–K11 indices
above are referenced directly so any flow can be unambiguously
mapped back to which key signed/verified/wrapped what.

### 3a. Canonical names (one concept, one canonical spelling)

Pinned to disambiguate the same value showing up under different
labels across components. **Use the canonical column** in every new
doc, runbook, CLI output, and commit message; the alias column lists
every spelling that exists today so a reader chasing one of them can
find their way back. Per `CLAUDE.md` →
"Terminology-source-of-truth rule", if you introduce a name not in
this table, either add the alias row here or rename the call site to
match the canonical name in the same change.

| Canonical name              | Identity                                                                                                                                                    | Aliases seen in the codebase / docs (NOT to introduce new ones)                                                                                                                                                                                                                                            |
|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `master_wallet`             | K4 instance bound to one actor's actor_omni at init/SIWE-verify. Source = `JWT.agentkeys.wallet_address` of the persisted session JWT (K6).                  | `wallet_address` (JWT claim shape), `agentkeys_user_wallet` (OIDC JWT claim + AWS PrincipalTag key), `session_wallet` (CLI `agentkeys whoami` field), `MASTER_WALLET` (demo doc shell var), `session.wallet.0` (Rust field).                                                                                |
| `derived_address(omni)`     | K4 instance computed on demand by `/dev/derive-address` for any omni — `HKDF(K3, omni)`. NOT persisted to a session JWT; NOT in AWS PrincipalTag.            | `derived_address` (CLI `whoami` field), `ADDR_A` / `ADDR_B` (demo doc shell vars for the specific case `omni=actor_omni`), `SIGNER_DERIVE_ADDR` (`demo-show.sh` internal var).                                                                                                                              |
| `actor_omni`                | The durable per-actor omni — `SHA256("agentkeys"||"evm"||master_wallet)` once SIWE-bound. Carried in `JWT.agentkeys.omni_account`.                          | `omni_account` (JWT claim + CLI `whoami` field), `OMNI_A` / `OMNI_B` (demo doc shell vars), `evm_omni` (init-flow return field, transient name pre-SIWE).                                                                                                                                                  |
| `identity_omni`             | The transient identity omni — `SHA256("agentkeys"||identity_type||identity_value)`. Used internally by the broker between init and SIWE-verify; never in a post-SIWE JWT. | `identity_omni_email` / `identity_omni_oauth2` (demo doc when narrowing to a specific identity type), `identity omni` (init-flow CLI log line).                                                                                                                                                            |
| `K3` (= `master_secret`)    | The 32 bytes in `/etc/agentkeys/dev-key-service.env` that every K4 is HKDF-derived from. Single per-broker-host.                                            | `DEV_KEY_SERVICE_MASTER_SECRET` (env var name), `master_secret` (signer-side log).                                                                                                                                                                                                                         |
| `session JWT` (= K6)        | The bearer token at `~/.agentkeys/<id>/session.json` (or OS keychain). Signed by K1.                                                                        | `session_jwt` (JSON field name in broker responses), `evm_session_jwt` (init-flow internal var post-SIWE), `SESSION_JWT_A` / `SESSION_JWT_B` (demo doc shell vars).                                                                                                                                         |
| `OIDC JWT` (= K7)           | Per-mint short-lived JWT signed by K2; consumed by `AssumeRoleWithWebIdentity`.                                                                             | `oidc_jwt`, `JWT_A` / `JWT_B` (demo doc shell vars).                                                                                                                                                                                                                                                       |
| `vault_bucket`              | S3 bucket holding Class-B credential ciphertext (scraped API keys). Per §7a, one of N data-class buckets in a deployment; per-actor isolation via wallet prefix + PrincipalTag. | `$BUCKET` (single-bucket-today env var in demo doc + `scripts/operator-workstation.env`; will fan out to `$VAULT_BUCKET` once memory + audit buckets ship), `agentkeys-vault` (legacy §7 example name). |
| `memory_bucket`             | S3 bucket for Class-A agent state (chat history, scratch, working memory). Not yet provisioned; reuses the `agentkeys_user_wallet` PrincipalTag policy template. | `$MEMORY_BUCKET` (forward env var name).                                                                                                                                                                                                                                                                   |
| `audit_bucket`              | S3 bucket for append-only integrity-anchored audit log. Today shipped as SQLite at `BROKER_AUDIT_DB_PATH`; S3 row is a future swap-in target per §7 audit-destination. | `$AUDIT_BUCKET` (forward env var name).                                                                                                                                                                                                                                                                    |
| `credential_kek`            | 32-byte AES-256 key for one credential blob. Derived as `SHA256("agentkeys.kek-derive.v1" \|\| signer.sign_eip191(actor_omni, "agentkeys.kek.v1:"\|\|master_wallet\|\|":"\|\|service))`. Deterministic across calls (secp256k1 RFC 6979). | `KEK` (S3CredentialBackend internal var name), `credential KEK` (issue #85 plan body).                                                                                                                                                                                                                    |
| `credential_envelope`       | Wire format of one stored credential: `1B version \|\| 12B AES-GCM nonce \|\| ciphertext \|\| 16B tag`. Stored at `s3://$vault_bucket/bots/<master_wallet>/credentials/<service>.enc`. AAD binds `(master_wallet, service)` so a swapped blob fails open. | `envelope` (s3_backend.rs internal), `AEAD blob` (informal), `<service>.enc` (S3 key suffix).                                                                                                                                                                                                              |

The most common confusion this table resolves: **`master_wallet`
(persisted in the session JWT, used by AWS PrincipalTag) ≠
`derived_address(actor_omni)` (recomputed on each `/dev/derive-address`
call, never reaches AWS).** Both are valid K4 instances; only the
first is what AWS sees in `${aws:PrincipalTag/agentkeys_user_wallet}`.
The post-SIWE `actor_omni` itself is *not a wallet* — it's the 32-byte
SHA256 input that defines which K4 the signer derives.

---

## 4. Identity model

The system has two omni concepts that compose into an HDKD actor tree:

```mermaid
flowchart LR
  ID["raw identity<br/>(email, OAuth2 sub, EVM addr, passkey)"]
  ID_OMNI["identity omni<br/>= SHA256('agentkeys' || id_type || id_value)<br/>(transient — auth-event handle)"]
  M_OMNI["MASTER actor omni<br/>(root of HDKD tree)<br/>= SHA256('agentkeys' || 'evm' || master_wallet)"]
  M_WALLET["wallet_master<br/>= HKDF(K3, M_OMNI)"]
  A_OMNI["AGENT actor omnis<br/>O_master//agent-A, //agent-B, ..."]
  A_WALLET["wallet_agent_A<br/>= HKDF(K3, O_master//agent-A)"]

  ID -->|"identity ceremony"| ID_OMNI
  ID_OMNI -->|"derive + link + SIWE"| M_OMNI
  M_OMNI --> M_WALLET
  M_OMNI -->|"HDKD //label"| A_OMNI
  A_OMNI --> A_WALLET
```

**Identity omni vs actor omni — different roles, different lifespans:**

- **Identity omni** = `SHA256("agentkeys" || identity_type || identity_value)`. Derived from the authenticator (email, OAuth2 sub, EVM addr, passkey). **Transient handle** for one auth event — the broker uses it to drive the wallet-binding round-trip, then discards it. Multiple identity omnis can map to the same master actor omni (a user with linked email + OAuth has two identity omnis but one master).
- **Actor omni** = `SHA256("agentkeys" || "evm" || lower(wallet))`. Derived from a wallet address. The **durable identity** the system reasons about: session JWTs, OIDC claims, audit attribution, AWS PrincipalTag are all keyed on actor omni.

For `identity_type = evm` (operator authenticates via their own EVM wallet via SIWE), the identity omni and master actor omni are equal — identity IS the wallet, no signer derivation needed.

### HDKD tree of actors (per-agent omni model)

Actor omnis form an HDKD tree rooted at the master. Every node has its own derived wallet:

```
O_master                                wallet_master = HKDF(K3, O_master)
├── O_master//agent-A                   wallet_agent_A = HKDF(K3, O_master//agent-A)
├── O_master//agent-B                   wallet_agent_B = HKDF(K3, O_master//agent-B)
│   └── O_master//agent-B//task-1       (future — sub-actors under agents)
└── ...
```

Hard derivation (`//N`) — child secret cannot be derived without the parent's master secret. Substrate / SLIP-0010 standard. Each node's wallet is a different EVM address; AWS PrincipalTag is per-actor-wallet for prefix isolation.

**Why per-agent omni (not shared with master):**
1. Per-agent compromise containment — leaked agent K10 touches only that agent's wallet/prefix.
2. First-class audit attribution — audit rows carry `acting_omni`, `parent_chain`, `derivation_path`.
3. Atomic revocation — revoke `O_master//agent-A` alone; master and other agents untouched.
4. Tree topology IS the data model — no binding-table abstraction needed.

The shared-omni-with-multiple-device-pubkeys model is a v1c shipping shortcut; v1.0 = HDKD per-agent omni. v1c is a degenerate v1.0 tree (no children).

---

## 4a. Mental model — four orthogonal axes

The system separates four concepts that earlier drafts collapsed:

| Axis | What it answers | Realized by | Lifecycle |
|---|---|---|---|
| **Identity** | Who is the human? | Identity omni (email / OAuth / EVM / passkey) | Recoverable via linked authenticators; identity omnis are ephemeral, masters are durable |
| **Actor** | Master, or which agent? | Actor omni — a node in the HDKD tree (`O_master`, `O_master//agent-A`) | Master derived from identity at first init; agents derived from master via `//<label>` |
| **Machine** | Which physical box is signing right now? | K10 device pubkey (per-machine, bound to one actor); K11 WebAuthn (master only) | Per-box at init/rotation |
| **Capability** | What is this actor allowed to do? | Wallet boundary (coarse — per-actor S3 prefix via PrincipalTag) + grants `Grant { issuer_wallet, child_wallet, scope, expires_at }` (fine) | Master-issued; expirable; revocable |

**Roles (master vs agent):** master and agent are distinct **roles on the actor axis**, not separate axes. Differences:

| | Master | Agent |
|---|---|---|
| HDKD position | Root | `//<label>` child of master |
| K11 (WebAuthn) | Yes — needed for binding ceremonies | No — agents have no human-presence credential |
| Bootstrap | Identity ceremony + WebAuthn enrollment | **Link-code from master, only** (no other path) |
| Spawns other actors | Yes (mints derivation certs + link codes) | No |
| Recovery on identity loss | Re-auth via any linked identity authenticator | Re-bootstrap via fresh link-code from master |

**Key non-conflations:**
- Identity ≠ actor — one human has many actors (master + N agents); HDKD tree expresses the relationship.
- Actor ≠ machine — one actor can run on many machines (master on laptop + phone); each machine has its own K10 binding under that actor's omni.
- Master ≠ agent — same axis (actor), distinct roles. Bootstrap path, K11 ownership, and revocation authority differ.

For agent-specific operator/contributor reference, see [`wiki/agent-role-and-usage-hdkd-per-agent-omni.md`](../../wiki/agent-role-and-usage-hdkd-per-agent-omni.md).

---

## 4b. Upstream backend classes — exercise vs distribution

Per-upstream design splits into two independent security concerns. Earlier drafts collapsed them; this section pins the split so future upstream integrations pick the right pattern.

| Concern | Question | Whose job |
|---|---|---|
| **Exercise** | On every API call, is this caller authorized to do this exact thing? | Depends on upstream's auth model |
| **Distribution** | How does the right credential reach the right agent, and only that agent? | Always ours (the §6 STS-to-vault rail) |

The §6 pipeline is the universal **distribution** rail. **Exercise** enforcement depends on which of the two classes an upstream falls into.

### Class A — Per-request authorization (AWS-native)

Upstream re-validates every API call independently. Examples: AWS S3, SES, KMS, future memory storage in S3.

- **Exercise** is enforced by AWS itself — `aws:PrincipalTag/agentkeys_user_wallet` is checked against the resource ARN on every request by the IAM policy engine.
- **Distribution** IS exercise — there is no separable "credential" sitting in the vault; the STS-signed request is the auth. The agent uses STS creds directly against the upstream; broker is off the hot path.
- **Granularity ceiling:** IAM-policy expressive power (prefix gates, tag conditions, action filters, time windows). Grants project naturally into JWT claims, which become STS session tags, which IAM evaluates per request.
- **Adding a new Class-A upstream:** define the resource, write an IAM policy gated by `agentkeys_user_wallet`, add it to the daemon's allow-list. The §6 pipeline carries it for free — no broker changes.

### Class B — Bearer-token authorization

Upstream issues an opaque token; subsequent API calls present the token; upstream trusts the bearer for whatever scope the token was minted with. Examples: OpenRouter, Anthropic, Groq, Brave Search, any third-party SaaS API.

- **Exercise** is provider-bounded — only whatever the upstream exposes per-key (spend cap, model allowlist, rate limit, expiry). Nothing finer can be enforced at the bearer-token layer.
- **Distribution** rides the Class-A rail: provisioner scrapes a per-grant key, deposits ciphertext at `s3://vault_bucket/<wallet>/<service>/<grant_id>/key.json`, agent fetches via the §6 pipeline, then uses the bearer **directly** against the upstream (not via any broker proxy).
- **Granularity ceiling:** provider-side per-key settings + one-key-per-grant blast bound + grant-driven JWT scoping at vault read time. Anything finer (e.g. "only this prompt category") requires either a future broker proxy or is structurally not enforceable.
- **Adding a new Class-B upstream:** write a Playwright scraper at [`provisioner-scripts/src/scrapers/<service>.ts`](../../provisioner-scripts/src/scrapers/) that signs up, mints an API key, and *sets provider-side caps from grant fields* before depositing ciphertext in `vault_bucket`. The scraper is the enforcement point — missing limits = compromised key has broader blast radius than the grant authorizes.

### Why this split matters

Operators reading §6 alone cannot tell whether the payload they retrieve from S3 *is* the action (Class A) or just *enables* an out-of-band action (Class B). The two cases have different revocation semantics, different blast radii, and different requirements on the provisioner. Pin the class for each upstream in the per-service docs.

Full design rationale, granularity matrix per class, bucket-layout consequences, and the open question on broker-as-egress-proxy: [`wiki/upstream-backend-classes-exercise-vs-distribution.md`](../../wiki/upstream-backend-classes-exercise-vs-distribution.md).

---

## 5. Cold-start (init) sequence

Init has three stages, with an actor-role branch at stage 2:

| Stage | What | Where |
|---|---|---|
| **0 — Device-key generation** | Daemon generates `(D_priv, D_pub) = K10` at startup. No network traffic. | Local (master OS keychain or agent file backend per §5a.4) |
| **1 — Identity ceremony** | **Master only.** Verify the human via email link / OAuth callback / EVM SIWE / passkey. Returns `binding_nonce` to the broker. **Agents skip this.** | Master ↔ broker |
| **2 — Binding ceremony** | Branches on actor role. **Master**: WebAuthn enrollment (K11 binds D_pub atomically inside the WebAuthn challenge). **Agent**: link-code redeem from master (no human, no WebAuthn). | Per role — see §5a.1 (master) / §5a.2 (agent) |
| **3 — J0 → J1 bridge** | **Master only.** Derive wallet via signer, link at broker, SIWE round-trip → mint long-lived EVM-omni JWT (J1). | Master ↔ broker ↔ signer |

```mermaid
sequenceDiagram
  autonumber
  participant Op as Operator
  participant CLI as agentkeys CLI
  participant KC as OS Keychain
  participant Brk as Broker
  participant PA as Platform authenticator (K11)
  participant Sig as Signer (dev_key_service)

  Note over CLI,KC: Stage 0 — generate K10 locally (no network)
  Op->>CLI: agentkeys init --email alice@x.com
  CLI->>KC: persist (D_priv, D_pub) = K10

  Note over CLI,Brk: Stage 1 — identity ceremony (master only)
  CLI->>Brk: POST /v1/auth/email/request {email}
  Brk-->>CLI: {request_id, binding_nonce}
  Op-->>Brk: clicks magic link → identity verified
  Brk-->>CLI: {status: "verified"}

  Note over CLI,PA: Stage 2 — master binding ceremony (WebAuthn)
  CLI->>PA: navigator.credentials.create({challenge: SHA256(binding_nonce || D_pub)})
  PA-->>CLI: WebAuthn attestation (K11 hardware-attested)
  CLI->>Brk: POST /v1/auth/bind/<request_id> {webauthn_attestation, D_pub}
  Brk-->>CLI: J0 (claims: agentkeys_device_pubkey=D_pub, agentkeys_webauthn_cred=K11_id)

  Note over CLI,Sig: Stage 3 — derive + link + SIWE → J1 (master only)
  CLI->>Sig: POST /dev/derive-address {O_master} (Bearer J0)
  Sig-->>CLI: {address: A = HKDF(K3, O_master)}
  CLI->>Brk: POST /v1/wallet/link {evm, A} (Bearer J0)
  CLI->>Brk: POST /v1/auth/wallet/start {address: A}
  Brk-->>CLI: {siwe_message: M}
  CLI->>Sig: POST /dev/sign-message {O_master, hex(M)} (Bearer J0)
  Sig-->>CLI: {signature: sig}
  CLI->>Brk: POST /v1/auth/wallet/verify {request_id, sig}
  Brk-->>CLI: J1 (long-lived; preserves K10 + K11 claims; adds wallet)
  CLI->>KC: persist J1
```

J1 is the long-lived bearer the master uses for all subsequent operations. Agent flow does not run stages 1 or 3 — it bootstraps via link-code from a master that has already completed this sequence. See §5a.

> **v1c interim status.** v1c ships bespoke per-identity PoP shapes (`pop_sig` field for email/oauth2; SIWE-payload `Device Pubkey` commit for evm) instead of the WebAuthn ceremony at stage 2. Wire shapes pinned in [step-1c plan](plans/issue-74-step-1c-device-key-auth.md). v0.2 collapses these into the WebAuthn ceremony shown above. The agent flow (§5a.2) is unchanged between v1c and v0.2.

---

## 5a. Per-actor binding ceremonies

Canonical reference for binding K10 to an actor omni — first-time init and re-binding flows. Roles split per §4a:

- **Master** = device with platform authenticator. Holds K11. Runs identity ceremony + WebAuthn binding. Spawns agents.
- **Agent** = VM / Linux / CI / `agent-infra/sandbox` container. No K11. **Bootstraps via link-code from a master, only** (no other path).

YubiKey-on-Linux as a master tier (roaming-authenticator binding lets a Linux box be a master) is deferred — see [issue #79](https://github.com/litentry/agentKeys/issues/79).

### 5a.1 Master init

Per §5 stages 0–3. Identity ceremonies vary per identity type but converge on the same WebAuthn binding ceremony at stage 2:

| Identity type | Stage 1 (identity ceremony) | Output | Stage 3 note |
|---|---|---|---|
| `email-link` | Broker emails magic link; operator clicks; broker confirms single-use within TTL | `(email, binding_nonce)` | Standard (derive + link + SIWE → J1) |
| `oauth2_google` | Broker redirects to Google; OAuth2 callback returns `code`; broker exchanges for ID token | `(google_sub, binding_nonce)` | Standard |
| `evm` | Broker generates SIWE-shaped identity-only payload; operator signs with EVM key (MetaMask / hardware wallet); broker ecrecover | `(evm_address, binding_nonce)` | **Collapses** — the user's own EVM key IS the wallet, no signer derivation, no second SIWE round-trip. Broker mints J1 directly with the verified EVM address. |
| `passkey-as-identity` | WebAuthn assertion against an existing platform-authenticator credential | `(webauthn_user_handle, binding_nonce)` | Standard (re-auth case, not first-time enroll) |

Stage 2 (master binding ceremony — WebAuthn enrollment per §5) is identical across all identity types. D_pub is committed atomically inside the WebAuthn challenge (`SHA256(binding_nonce || D_pub)`) — no separate `pop_sig` field needed.

**Q7 fix:** email-account compromise alone cannot rebind. An attacker who phished the email account can complete the identity ceremony but cannot complete the WebAuthn ceremony on the legitimate user's hardware (Touch ID / Hello requires the physical device).

### 5a.2 Agent bootstrap (link-code only — single path)

**Agents have exactly one bootstrap path:** a one-time link code minted by an authenticated master. There is no agent-runs-its-own-identity-ceremony, no agent-recovers-via-OAuth, no shared-bearer alternative. This is a deliberate simplification — one path = one test surface, one threat model.

```
ON MASTER (already initialized; holds J1_master):
1. CLI: agentkeys agent create --label agent-A
2. CLI → broker: POST /v1/agent/create
                  { parent_omni: O_master, label: "agent-A" }
                  Authorization: Bearer J1_master
3. Broker:
   - Verify J1_master
   - Derive O_agent_A = HDKD(O_master, "//agent-A")    [hard derivation]
   - Master signs derivation cert via WebAuthn get() against K11
     (proves master human authorized this agent's existence)
   - Persist (parent: O_master, child: O_agent_A, deriv_cert)
   - Mint one-time link code bound to O_agent_A (TTL 600s)
4. CLI: print link code (or auto-pipe to agent provisioner)

ON AGENT MACHINE (any VM / container / CI runner / cloud sandbox):
5. Stage 0 (per §5): daemon generates (D_priv_agent, D_pub_agent) at startup
                     persists D_priv per §5a.4
6. agentkeys-daemon --init-link-code <code> --broker-url B --signer-url S
7. Daemon → broker: POST /v1/auth/link-code/redeem
                     { link_code, device_pubkey: D_pub_agent,
                       pop_sig: sign(D_priv_agent, link_code || D_pub_agent) }
8. Broker:
   - Verify pop_sig (proves daemon holds D_priv_agent for D_pub_agent)
   - Mark link code consumed (single-use)
   - Bind (O_agent_A, D_pub_agent)
   - Mint J1_agent with claims:
       omni                    = O_agent_A
       parent_omni             = O_master
       derivation_path         = "//agent-A"
       agentkeys_device_pubkey = D_pub_agent
       agentkeys_user_wallet   = HKDF(K3, O_agent_A)  ← per-agent wallet
9. Daemon: persist J1_agent; enter MCP-stdio loop
```

**Trust chain:** `master human → master K11 → master J1 → derivation cert → agent J1`. The agent never holds K11 or any user-presence credential.

The agent's `pop_sig` is sufficient on its own (no WebAuthn equivalent) because the link code is single-use, TTL-bounded, and bound to a specific agent omni at mint time — possession of the code + matching D_priv proves the agent received the bearer from the master and holds the device key.

### 5a.3 Master device switch + device-key rotation

#### 5a.3.1 New master device (operator gets a new laptop)

```
ON NEW MASTER:
1. Stage 0: generate fresh (D_priv', D_pub') = K10' at daemon startup
2. CLI: agentkeys init --email alice@x.com  (or any identity)
3. Run stages 1–3 per §5 — WebAuthn enrollment binds NEW K11' on new hardware
4. Broker observes pre-existing (D_pub_old, K11_old) for same omni:
     (a) ADDS (D_pub', K11') alongside (multi-device, v0.2), OR
     (b) REPLACES old binding (single-device default)
5. New master persists J1' (D_priv' was persisted at stage 0)
```

**Cross-device confirmation (v0.2 target):** when broker observes pre-existing K11_old, it requires WebAuthn `get()` against K11_old (push to existing master) before binding K11' — defeats email-account-compromise → device-takeover.

#### 5a.3.2 Master device-key rotation (no identity re-auth)

```
ON MASTER (still has J1 + D_priv_old + K11):
1. CLI: agentkeys device rotate
2. CLI: generate (D_priv_new, D_pub_new); persist D_priv_new
3. CLI: WebAuthn get() against K11 over SHA256(D_pub_old || D_pub_new || rotation_nonce)
4. CLI → broker: POST /v1/wallet/device/rotate
                  { D_pub_old, D_pub_new, webauthn_assertion,
                    sig_new: sign(D_priv_new, rotation_nonce) }
                  Authorization: Bearer J1
5. Broker: verify J1 + WebAuthn (user-presence) + sig_new (new D_priv possession);
            replace binding (omni, D_pub_old) → (omni, D_pub_new);
            mint J1_new; revoke J1
6. CLI: persist J1_new; clear D_priv_old
```

If both D_priv_old AND K11 are lost → fall back to §5a.3.1 (re-do identity ceremony from new master device).

### 5a.4 Agent re-bootstrap + persistence

#### 5a.4.1 Agent re-bootstrap (fresh sandbox, agent restart)

```
ON MASTER:
1. agentkeys agent create --label agent-A   (or reuse existing label)
   → mints fresh link code; old D_pub_agent_old binding remains until
     explicit revoke via `agentkeys agent revoke --pubkey D_pub_old`
     (defensive cleanup, not required for security — the old pop_sig
     cannot be re-issued without the agent's old D_priv)

ON NEW AGENT:
2-9. Same as §5a.2 steps 5–9 (new D_pub binds under same O_agent_A)
```

Multiple concurrent device pubkeys under the same agent omni is the default — many concurrent VMs are typical for ephemeral-sandbox patterns.

#### 5a.4.2 Where D_priv lives on an agent machine

OS keychain when available (Linux GNOME Keyring, Windows Credential Locker). When unavailable — `agent-infra/sandbox`'s default Docker container exposes none — [`keyring-rs`](https://crates.io/crates/keyring) falls back to a file backend at `~/.agentkeys/daemon-<wallet>/session.json` (mode 0600). Reference: [`docs/spec/1-step-analysis.md`](1-step-analysis.md).

| Agent lifecycle | D_priv behavior | Operator action |
|---|---|---|
| **Long-lived sandbox** (single container instance for hours/days) | File persists across daemon restarts within the container | None |
| **Ephemeral sandbox** (container destroyed between sessions, e.g. nightly CI) | D_priv vanishes with the container | Master mints fresh link code per §5a.4.1; agent re-bootstraps. **No human re-presence required** — master's `agentkeysd` can auto-mint on agent-restart signal |
| **Hardened sandbox** (TPM / Secure Enclave passthrough, AWS Nitro Enclave) | D_priv pinned to hardware OR sealed to boot measurement | Survives container destruction; v0.2 enhancement |

**Why this is the right answer (not a workaround):** the master holds the long-lived authority; agents are short-lived consumers. The link-code-per-restart pattern mirrors `agent-infra/sandbox`'s two-tier orchestrator model — orchestrator holds the long-lived signing key; sandbox holds only short-TTL bearer credentials. Leaked sandbox env = at most one link-code-TTL of access, scoped to that agent's permissions.

### 5a.5 Trust shape across actor roles

| Compromise | Blast radius |
|---|---|
| **Master K10 leaked** (host root, no hardware presence) | Forge `/dev/*` calls under `O_master` until rotation. **Cannot rebind K10** (requires K11). **Cannot mint new agent omnis or link codes** (those gate on master J1, which itself gates on K11 at re-bind time). |
| **Master K10 + K11 hardware presence** (attacker physically at machine + biometric unlock) | Above plus: rebind K10, rotate, mint new agent omnis. Bounded to this human; cannot reach other masters. |
| **Agent K10 leaked** (sandbox host root) | Forge `/dev/*` calls under `O_agent_A` until link-code rotation OR session-JWT TTL expiry. **Cannot rebind without a fresh master-issued link code.** **Cannot escalate to master.** **Cannot reach other agents' wallets** (PrincipalTag enforcement at STS — different wallet, different prefix). |
| **Broker process** | Mint session/OIDC JWTs. **Cannot forge device signatures** — per-request K10 signature is verified at signer; broker compromise alone cannot make the signer accept an attacker request (post-step-1c). |
| **Signer process** (current step-1) | Derive any wallet, sign any message. Cannot mint JWTs, cannot reach AWS. Replaced by TEE worker per issue #74 step 2. |
| **AWS account** | This operator's data scope only. Per-actor PrincipalTag prefix isolation contains it further: agent A's compromise does not touch agent B's prefix. |

Per-actor isolation is what the HDKD per-agent omni model buys: agent compromise touches one wallet (one S3 prefix) and one omni (one audit slot), never the master and never other agents.

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
| **Vault backend** (where Class-B credential ciphertext lives — see §4b) | `s3://vault_bucket/<wallet>/<service>/<grant_id>/key.json` (PrincipalTag-gated). One of N data-class buckets — see §7a. | IPFS / Filecoin / Arweave content-addressed multi-backend; on-chain pointer + hash | Per [`threat-model-key-custody.md` §4 + §9](threat-model-key-custody.md) |
| **Egress enforcement** (Class-B per-request gating — see §4b) | None (v0 — provider-side per-key caps only; agent calls upstream directly with the scraped bearer) | Broker-as-egress-proxy at `/v1/proxy/{service}`; agent-sandbox sidecar enforcing signed grant locally | Not yet specced — open question in [`upstream-backend-classes-exercise-vs-distribution.md`](../../wiki/upstream-backend-classes-exercise-vs-distribution.md) |

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

## 7a. Bucket layout — data-class buckets, wallet prefixes

Per-actor isolation lives at the **prefix** layer (wallet via PrincipalTag, per §5a.5). Per-data-class isolation lives at the **bucket** layer. The wallet does not replace the bucket; they're orthogonal axes, both required.

```
bucket  = (data class) × (operator deployment) × (environment)
prefix  = (wallet address)            ← per-actor isolation here
object  = the unit of data
```

### Why one bucket is not enough

S3 exposes the following only at the **bucket** level — they cannot be set per-prefix. Different data classes need conflicting settings on these axes:

| Setting | `vault_bucket` (Class-B creds) | `memory_bucket` (Class-A agent state) | `audit_bucket` (anchor log) |
|---|---|---|---|
| Versioning | Off | On (rollback) | On + MFA-delete |
| Default encryption | SSE-KMS w/ customer-managed CMK | SSE-S3 | SSE-KMS w/ CMK |
| Object Lock | No | No | **Compliance mode, WORM** |
| Lifecycle | Short TTL → expire on rotate | Glacier transition after 90d | Never expire |
| CloudTrail data events | Every Get/Put | Sampled or off | Every Get/Put + integrity check |
| Replication | None | Cross-region for DR | Cross-region for durability |

Folding these into one bucket would force the loosest setting on every dimension — e.g., the audit log loses WORM, or vault retains versions of every rotated credential. Separate buckets is the only way.

### Why each bucket gets its own IAM role

`agentkeys-data-role`'s policy line is `Resource: "arn:aws:s3:::${BUCKET}/<wallet>/*"`. Sharing one role across vault + memory + audit means:

- A bug widening vault access widens memory + audit access too — blast radii collapse.
- Audit's append-only property has to be expressed by IAM action filtering inside the same role — fiddly and easy to get wrong.
- The daemon's memory R/W trust level equals its credential-vault read trust level — no least-privilege gradient.

Separate buckets → separate roles → independent policy surfaces. `agentkeys-data-role` (vault, read-mostly), `agentkeys-memory-role` (memory, R/W), `agentkeys-audit-role` (audit, append-only). Each role's OIDC JWT is minted by the broker scoped to what the call actually needs.

### Why `$BUCKET` is a *variable* (and will fan out)

S3 bucket names are **globally unique across AWS**. Each operator account picks its own (`acme-agentkeys-vault-prod`, `litentry-agentkeys-vault-dev`, etc.). The bucket-name-as-variable absorbs global-namespace + multi-env reality, totally independent of per-actor isolation.

Today the shipped code references a single `$BUCKET` env var (single data class shipped). Going forward, `scripts/operator-workstation.env` + the role-policy templates fan out:

```
VAULT_BUCKET   = <operator>-agentkeys-vault-<env>
MEMORY_BUCKET  = <operator>-agentkeys-memory-<env>
AUDIT_BUCKET   = <operator>-agentkeys-audit-<env>
```

The §6 STS-to-prefix pipeline carries each bucket independently — wallet-as-prefix is the same scheme in all three.

### Single-bucket-today aliases

| Canonical (forward) | Currently shipped as | Migration |
|---|---|---|
| `vault_bucket`     | `$BUCKET` (single bucket, Class-B creds at `bots/<wallet>/...`) | Rename `$BUCKET` → `$VAULT_BUCKET`; create separate `memory_bucket` + `audit_bucket` as those data classes ship |
| `memory_bucket`    | Not yet provisioned                                              | Provision when memory storage lands; reuse `agentkeys_user_wallet` PrincipalTag policy template |
| `audit_bucket`     | SQLite at `BROKER_AUDIT_DB_PATH` (per §7 audit-destination row 3) | Cut over when chain audit lands OR when S3-anchored audit is chosen as the swap-in target |

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

## 9. Component inventory

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
| 10 | Backend (mock-server) | EC2 broker host (loopback `:8090`) | Legacy `/session/*` + `/credential/*` + `/audit/*` (broker's Tier-2 reachability target). **Credential CRUD is migrating off this backend** — `--credential-backend s3` (issue #85) routes `store/read/teardown/list_credentials` to `S3CredentialBackend` (client-side AES-256-GCM, OIDC-scoped writes to `bots/<wallet>/credentials/<service>.enc`). Sessions, audit, identity, scope, rendezvous, and inbox remain on `:8090` until each gets its own swap-in target. |
| 11 | Audit log indexer | Post-MVP; own host | Reads broker audit DB, exposes for `agentkeys usage` queries |
| 12 | Web GUI | Post-MVP, user's device, Tauri | Master management UI, live audit, wallet balance |
| 13 | TEE worker | Post-issue-#74 step 2 | Replaces #6 with sealed master secret + remote attestation |
| 14 | `@agentkeys/daemon` npm package | Cloud LLM environments (ChatGPT / Claude.ai) | TS wrapper around prebuilt #2 binary |

---

## 10. Language choices

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

## 14. Credential storage v2 — target endpoint architecture

**Status**: forward-looking design for the post-#87 endpoint. Stage 1 + stage 2 GitHub issues track implementation. This section consolidates the v2 design discussions (formerly in a separate `credential-architecture-v2.md` doc, now archived).

The v2 architecture preserves everything in §0–§13 above and extends it with:
- Per-service worker split (credentials / memory / audit / email; payment deferred)
- On-chain identity layer (scope, registry, K3 epoch counter) on Litentry chain
- Multi-master-device M-of-N recovery quorum using K10 + K11 (no anchor wallet, no seed phrase)
- Sovereign-by-default chain submission (operator's wallet signs; hosted-relay opt-in for gas subsidy + tx batching)
- Sidecar credential injection at the daemon (no plaintext to agent process)
- AAD + S3 path keyed on `actor_omni` (stable across K3 rotation)

### 14.1 The three identity layers (clarification of §3a + §4)

The v2 design crystallizes three distinct identity roles that were implicit in earlier revs:

**Layer 1 — Cryptographic anchor (immutable)**

```
actor_omni = SHA256("agentkeys" || "evm" || initial_master_wallet_K3_v1)
```

Frozen at first SIWE-bind (per §3a's "once SIWE-bound" wording). Never changes for the lifetime of the account. The operator's durable identity at the cryptographic anchor. Survives K3 rotation, wallet rotation, device-set changes.

**Layer 2 — Current chain identity (rotatable)**

```
current_master_wallet = HKDF(K3_v[current_epoch], O_master)
```

Rotates each K3 epoch (~6 months by default). The operator's current identity on a public chain. In **sovereign mode** (v2 default): appears on chain as msg.sender of operator-signed txs. Block-explorer + ENS lookups work on this wallet.

**Layer 3 — Operational uses (each identifier where it's natural)**

| Operational use | Identifier used | Why |
|---|---|---|
| Signer-internal K4 derivation | `actor_omni` (Layer 1) | §3a / §4 — actor_omni is the canonical K4 derivation domain |
| Signer-internal KEK derivation | `actor_omni` (Layer 1) | Stable across K3 rotation; KEK epoch handled by in-blob byte |
| AAD in credential blob envelopes | `actor_omni` (Layer 1) | Binds blob to its stable location; never changes |
| S3 path: `bots/<X>/credentials/...` | `actor_omni_hex` (Layer 1) | Stable; **ZERO migration on K3 rotation** |
| AWS PrincipalTag | `agentkeys_actor_omni = <actor_omni_hex>` (Layer 1) | Stable; bucket policy doesn't rotate |
| Cap-token `operator_omni` / `agent_omni` fields | `actor_omni` (Layer 1) | Matches scope-index key |
| Scope index in `ScopeContract` | `actor_omni` (Layer 1) | Stable on-chain key |
| Sidecar registry key | `device_pubkey_hash → actor_omni` (Layer 1 as value) | Per-actor binding (Codex finding #1) |
| Chain tx signer (msg.sender) | Mode-dependent: relay-wallet (hosted-relay) OR `current_master_wallet` (sovereign default) | Layer-2 decision per deployment |
| Chain event payload "author" field | Sovereign mode: `current_master_wallet`; hosted-relay: omitted | Layer-2 decision |
| Block-explorer audit trail | Sovereign-only: wallet (Layer 2) | Hosted-relay mode has no operator-specific block-explorer trail |
| Payment-from address (on-chain payments) | Mode-dependent: service-pool-wallet, escrow, or `current_master_wallet` | Per payment-service mode (deferred to separate issue) |
| Audit event submitter | Sovereign-tier C: `current_master_wallet`; hosted-tier A: shared-relay-wallet | Per audit tier |

This separation is the design's main conceptual win: Layer 1 stays operationally invariant regardless of mode; Layer 2 decisions (sovereign vs hosted) flip only the chain-submission side; Layer 3 spans both consistently.

### 14.2 Five trust roots (rev 4 — bounded compromise per root)

| # | Trust root | Controls | Compromise blast radius | Lives in |
|---|---|---|---|---|
| 1 | **Master wallet** (chain identity) | Scope mutations (with K11), recovery, master-key rotation initiation | Attacker changes on-chain scope; visible, revocable via master-recovery if M-of-N device quorum ≥ 2 | Operator's signer-derived K3_v[1] keypair, backed up across master devices |
| 2 | **K10 device key** (per-host) | Cap-mint requests (no cap mints without K10 sig) | Per-sidecar; attacker can mint caps for THAT one actor's scope only (per-actor binding), bounded by `cred_cache_ttl` window | TPM / Secure Enclave / TEE / fallback file (mode 0600) |
| 3 | **K11 WebAuthn credential** (per-master-device) | Master-only mutations (scope grant/revoke, device add/revoke, K10 rotation) | Compromise requires both possession of the master device AND ability to satisfy biometric/PIN; biometric-gated hardware-attested credential | Sealed in platform authenticator (Secure Enclave / TPM / StrongBox); cannot be exfiltrated even by host-OS root |
| 4 | **Broker K1** | Cap counter-signature; session JWT signing | Alone cannot mint usable caps (missing K10 sig + K11 for master mutations); can sign session JWTs within scope but workers cross-check chain | Broker process (eventually HSM / TEE / threshold-signed) |
| 5 | **Signer K3** (TEE-protected per §13) | K4 derivation, KEK derivation | Catastrophic for credentials if extracted — all KEKs derivable | Inside TEE enclave (AMD SEV-SNP / Intel TDX / AWS Nitro); attested boot |
| 6 | **Chain** (Litentry / EVM L2) | Scope storage, sidecar device-key registry, audit anchors, K3 epoch counter | Chain-level attack required (51% on chosen chain); bounded by chain security properties | Distributed across chain validators |

**Key property**: any *single* compromise yields bounded damage. Even broker-K1 + chain compromised still requires K11 user-presence on a master device to mint usable scope-mutating caps; even signer-K3 compromised (catastrophic) is mitigated by TEE seal + attestation.

### 14.3 Component roles

#### 14.3.1 Daemon (sidecar)

Per arch.md component #2, extended in v2 with a localhost HTTP proxy + credential cache + controls. The daemon becomes the trust boundary for the agent process:

**Responsibilities**:
- Holds K10 (device key) in TPM / SE / TEE / fallback file per §5a.4
- Holds K11 (WebAuthn credential) in platform authenticator IF master device
- Exposes localhost HTTP proxy at:
  - E1: Unix socket `$XDG_RUNTIME_DIR/agentkeys-proxy.sock` (SO_PEERCRED gates callers)
  - E2: pod-internal `localhost:9090` (network namespace gates callers)
  - E3: TEE-internal IPC (enclave gates callers)
- Caches plaintext credentials in memory with `cred_cache_ttl` (default 5 min); zeroes on TTL expiry or drop event
- Mints cap-fetch requests (signs with K10) when agent first requests an unloaded credential
- Forwards agent's localhost calls to upstream APIs (e.g., `https://api.openrouter.ai/...`) with `Authorization: Bearer <plaintext>` injected
- Enforces controls before any proxy operation: caller authentication, per-caller scope binding, service/method/path allowlist, spend quotas, per-call audit, fail-closed on stale broker
- Receives drop events from broker over SSE; atomically purges affected credentials

**NOT responsible for**: K3, K1, master_wallet private keys (signer holds those); scope mutations (master does this on-chain); credential decryption (workers do this); reading S3 credentials prefix (no IAM grant).

#### 14.3.2 Broker (cap-minter + auth-relay)

Per arch.md component #5, narrowed in v2 to pure policy authority:

**Responsibilities**:
- Verifies cap-mint request's K10 sig against on-chain SidecarRegistry
- Verifies actor-binding: `registry[device_pubkey].actor_omni == request.agent_omni` (Codex finding #1)
- Reads scope from on-chain ScopeContract (NOT broker DB)
- Verifies K3 epoch against on-chain K3EpochCounter (Codex finding #4)
- For master-only mutations: additionally requires K11 WebAuthn assertion (Codex finding #2)
- Co-signs caps with K1
- Pushes drop events to daemons over SSE when on-chain scope changes
- Relays interactive auth flows that can't go on-chain: email-link (Stage 1), OAuth2

**NOT responsible for**: scope storage (chain); credential decryption (workers); signing user data with K3 (signer); mutating scope (master does this on-chain).

#### 14.3.3 Signer (K3 vault, TEE-protected)

Per arch.md §13 / issue #74 step 2, with v2-specific responsibilities:

**v2 additions**:
- Holds **historical K3 epochs** (`K3_v[1]`, `K3_v[2]`, ..., `K3_v[current]`) inside attested enclave for lazy decrypt of pre-rotation blobs
- Derives per-user KEK = `HKDF(K3_v[epoch], "agentkeys.user.v1" || actor_omni)` for credential encryption
- Derives `current_master_wallet = HKDF(K3_v[current_epoch], O_master)` on demand for AWS STS calls; never persisted as identity material outside the STS call lifecycle
- On every typed call, signer reads `K3EpochCounter.current_epoch` from chain and verifies the requested epoch is consistent (defense in depth)
- Exposes verification helpers `/verify/k10-sig` and `/verify/k11-assertion` for workers/brokers

**Typed RPC over mTLS** (callers: broker + workers only, never daemons directly):
- `/sign/siwe`, `/sign/audit-row`
- `/derive-cred-kek` (K3 epoch verified against chain)
- `/sts-credentials` (derives transient master_wallet for one STS call)
- `/verify/k10-sig`, `/verify/k11-assertion`

#### 14.3.4 Workers (per-service)

Each data-class gets its own worker — independent IAM, independent deploy lifecycle, independent compromise blast radius.

| Worker | Purpose | IAM minimum | master_wallet on chain? |
|---|---|---|---|
| `credentials-service` | Encrypt and decrypt API credentials | `s3:GetObject`/`s3:PutObject` on `bots/<actor_omni_hex>/credentials/*`; signer mTLS for KEK | No (S3 only, no chain) |
| `memory-service` | R/W agent state in S3 | `s3:GetObject`/`s3:PutObject` on `bots/<actor_omni_hex>/memory/*` | No |
| `audit-service` | Append to audit log + on-chain anchor | `s3:PutObject` on `bots/<actor_omni_hex>/audit/*`; chain tx submitter | **Depends on tier** (see §14.6) |
| `email-service` | Send/receive via SES on operator's domain | `ses:SendRawEmail` from operator's domain | No |
| `payment-service` (deferred — separate issue) | Execute payments on operator's behalf | Mode-dependent | Mode-dependent |

**Common worker behavior**:
- Verify cap's K10 sig against on-chain SidecarRegistry (per-actor binding check)
- Verify cap's broker_sig against broker's K1 pubkey
- Verify on-chain scope independently of broker's claim
- Verify K3 epoch consistency before any K3-dependent op
- Execute service operation
- Emit audit row (local log + chain-anchored batch via audit-relay or direct-write per tier)

**Implementations**:
- AWS Lambda + API Gateway (managed, AWS-native)
- Self-hosted Rust microservice (vendor-neutral, axum-based)
- Cloudflare Worker + R2 (edge / global; for memory + audit)
- Tencent Cloud SCF + COS (China deployment)

#### 14.3.5 Chain (single source of truth)

v2 adds four contracts to the chain layer (deployment target: Litentry chain; reserve EVM L2 as fallback):

```solidity
contract AgentKeysScope {
    mapping(bytes32 => mapping(bytes32 => Scope)) public scope;
    // scope[operator_omni][agent_omni] = {services, read_only, updated_at}
    struct Scope { string[] services; bool read_only; uint256 updated_at; }

    event ScopeUpdated(bytes32 indexed operator_omni, bytes32 indexed agent_omni,
                       string[] services, bool read_only);

    function set_scope_with_webauthn(
        bytes32 operator_omni, bytes32 agent_omni,
        string[] calldata services, bool read_only,
        bytes calldata k10_device_sig,
        bytes calldata k11_webauthn_assertion
    ) external { /* verify K10 + K11; require both */ }
}

contract SidecarRegistry {
    mapping(bytes32 => DeviceBinding) public device;
    // Codex finding #1: per-actor binding (NOT per-operator-only)
    struct DeviceBinding {
        bytes32 operator_omni;   // who owns
        bytes32 actor_omni;      // WHICH actor this device serves
        uint8   tier;            // 1=master-with-K11, 2=agent-no-K11, 3=TEE-sealed
        uint8   roles;           // bitfield: CAP_MINT (0x01) | RECOVERY (0x02) | SCOPE_MGMT (0x04)
        bytes32 k11_cred_id;     // WebAuthn cred ID — zero for agent devices
        bytes   attestation;
        uint256 registered_at;
    }

    function register_master_device(
        bytes32 device_pubkey_hash,
        bytes32 operator_omni, bytes32 actor_omni,
        bytes32 k11_cred_id, bytes calldata attestation,
        uint8 roles,
        bytes calldata authorization_proof
    ) external;

    function register_agent_device(
        bytes32 device_pubkey_hash,
        bytes32 operator_omni, bytes32 actor_omni,
        bytes calldata link_code_redemption,  // K11-signed by master
        bytes calldata agent_pop_sig
    ) external;
}

contract K3EpochCounter {
    uint256 public current_epoch;
    address public signer_governance;

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
}
```

**Operations**:
- `ScopeContract.set_scope_with_webauthn(...)` — master mutations (K10 + K11 both required)
- `SidecarRegistry.register_master_device(...)` — master init (bootstrap) or new-device add per §5a.3.1
- `SidecarRegistry.register_agent_device(...)` — agent bootstrap via master-issued link code per §5a.2
- `K3EpochCounter.bump_epoch()` — once per K3 rotation by signer-governance multisig
- `CredentialAudit.{CredentialUpdated, CapMintedBatch}` — workers submit (direct-write tier C) or audit-relay batches (tier A/B)

### 14.4 KEK scheme + AES-256-GCM envelope

**Per-user KEK derivation** (signer-internal, K3-rotation-tolerant):

```
KEK_for(operator_omni, k3_epoch) = HKDF-SHA256(
    salt = "agentkeys.kek-salt.v2",
    ikm  = K3_v[k3_epoch],
    info = "agentkeys.user.v1" || operator_omni
)
```

Worker calls `signer.derive_cred_kek(operator_omni, k3_epoch)` over mTLS. Signer verifies chain epoch (defense in depth), retrieves the right K3 version from TEE, HKDFs, returns the 32-byte KEK.

**AES-256-GCM envelope** (S3 wire format, v2):

```
1 byte  version          (0x04 for v2)
1 byte  k3_epoch         (which K3 generation encrypted this blob)
12 byte AES-GCM nonce    (random per encryption)
N bytes ciphertext
16 byte GCM authentication tag

AAD = "agentkeys.cred.aad.v2|" || operator_actor_omni_hex || "|" || service
```

**S3 path**: `bots/<operator_actor_omni_hex>/credentials/<service>.enc` — stable across K3 rotation, wallet rotation, master-device changes. The only thing that changes about a blob: (a) `k3_epoch` byte on re-encryption, (b) ciphertext on credential update.

**K3 rotation handling**:
1. `K3EpochCounter.bump_epoch()` increments the global counter (1 chain tx, O(1) regardless of operator count)
2. Signer retains historical K3_v[N] for decrypt; generates K3_v[N+1] for new encrypts
3. **ZERO S3 path migration** (paths key on actor_omni, stable)
4. **ZERO PrincipalTag changes** (PrincipalTag = `agentkeys_actor_omni`, stable)
5. **ZERO IAM changes** (bucket policy stays put)
6. Lazy on-read re-encryption (optional): blob read → decrypt under old K3 → re-encrypt under new K3 → upload to same S3 path

### 14.5 Bucket layout (extending §7a for v2)

Per arch.md §7a: per-data-class buckets × per-actor prefixes. v2 keys all prefixes on `actor_omni_hex`:

```
$VAULT_BUCKET    bots/<actor_omni_hex>/credentials/<service>.enc     # creds-service
$MEMORY_BUCKET   bots/<actor_omni_hex>/memory/<key>                  # memory-service
$AUDIT_BUCKET    bots/<actor_omni_hex>/audit/<batch>                 # audit-service
                 bots/<actor_omni_hex>/inbound/<msg>                 # email-service inbox
                 bots/<actor_omni_hex>/sent/<yyyymm>/<msg>           # email-service sent
```

AWS PrincipalTag `agentkeys_actor_omni = <actor_omni_hex>` scopes IAM access to a single actor's prefix across all buckets.

### 14.6 Mode selection — sovereign default, hosted-relay opt-in

V2 default mode is **sovereign**: operator's wallet signs chain submissions directly (msg.sender = master_wallet). Block-explorer + ENS lookups work. Zero third-party trust required.

Hosted-relay mode kept as **opt-in for gas subsidy + tx batching** only (not for privacy — actor_omni hash exposure does NOT weaken K3 due to 2^160 address-space rainbow infeasibility).

**Audit-service tiers**:

| Tier | Substrate | master_wallet on chain? | Trust model |
|---|---|---|---|
| **A — Hosted shared relay** (opt-in for gas) | Service provider runs relay; batches across MANY operators; Merkle root on chain | No (only service-relay-wallet appears, shared across operators) | Operator trusts service to not OMIT events; chain-anchored root catches forgery |
| **B — Self-hosted relay** (privacy-preserving sovereignty) | Operator runs own audit-relay binary; relay-wallet (separate from master_wallet) signs batches | No (operator's relay-wallet appears, separable burner) | Operator owns the relay; no third-party trust |
| **C — Direct-write per event** (sovereign default) | Daemon submits each audit event as separate chain tx, signed by operator's K3-derived key | **YES** — master_wallet (or its K3-derived signing key) signs every audit tx | Operator fully self-custodial; pays per-event gas |

V2 default: tier C (sovereign). Tier A is the gas-subsidy escape hatch. Tier B is for operators who want self-sovereignty without master_wallet exposure.

### 14.7 Lifecycle flows (v2)

#### 14.7.1 Master device bootstrap (per arch.md §5 stages 0-3, plus stage 4 v2)

```
Stage 0 — Device-key (K10) generation [LOCAL, no network]
  Daemon generates (D_priv, D_pub) = K10 in OS keychain (TouchID-backed on master)

Stage 1 — Identity ceremony [master only]
  Email-link / OAuth2 → broker confirms identity → returns binding_nonce

Stage 2 — Master binding ceremony (WebAuthn)
  Platform authenticator generates K11; commits D_pub atomically inside
  WebAuthn challenge SHA256(binding_nonce || D_pub) per arch.md §5a.1 Q7 fix
  Broker mints J0

Stage 3 — Wallet derivation + SIWE → J1
  signer.derive_address(O_master) → first_master_wallet
  actor_omni = SHA256("agentkeys"||"evm"||first_master_wallet)  ← FROZEN
  SIWE round-trip → J1 (long-lived bearer)

Stage 4 (v2) — On-chain SidecarRegistry binding [meta-tx or sovereign]
  SidecarRegistry.register_master_device(D_pub_hash, actor_omni, actor_omni,
                                         k11_cred_id, roles=CAP_MINT|RECOVERY|SCOPE_MGMT,
                                         WebAuthn-proof-over-binding_nonce)
  First device gets all roles; subsequent devices opt-in to SCOPE_MGMT
```

#### 14.7.2 Adding a 2nd master device (per §5a.3.1 + v2 quorum)

Existing master's K10 + K11 authorize new device's K10 + K11 binding. New device registers in SidecarRegistry with `CAP_MINT | RECOVERY` (default; SCOPE_MGMT opt-in).

#### 14.7.3 Agent device bootstrap (per §5a.2 — link-code only)

Per arch.md §5a.2: master mints one-time link code (K11-signed); agent redeems at broker. SidecarRegistry records the agent device with `actor_omni = agent's_omni` (NOT master's), tier=2 (no K11), roles=CAP_MINT only. Per-actor binding (Codex finding #1) ensures the agent's K10 cannot mint caps as a sibling agent.

#### 14.7.4 Scope grant (K11 required)

Master CLI signs payload with K10; biometric prompt for K11 WebAuthn assertion; relay (or sovereign-direct) submits `ScopeContract.set_scope_with_webauthn(...)`. Compromised K10 alone cannot mutate scope.

#### 14.7.5 Credential store / fetch

Per §14.4 KEK scheme. Worker verifies K10 sig + per-actor binding + broker_sig + on-chain scope + K3 epoch before any S3 / signer call. AAD binds blob to `(actor_omni, service)` location.

#### 14.7.6 Recovery (M-of-N device quorum — no anchor wallet, no seed phrase)

On surviving master device (e.g., phone), operator triggers "Lost device — revoke & rotate". Phone signs revoke payload with K10 + K11 (biometric). Sig count ≥ recovery_threshold authorizes the rotation. Relay submits `SidecarRegistry.revoke_device(...)` + `WalletRotated` audit event. Within ~60 seconds: attacker's cap-mints rejected at broker (registry lookup fails); cached creds expire on TTL.

#### 14.7.7 K3 rotation

`K3EpochCounter.bump_epoch()` (1 chain tx, global). Signer retains historical K3; new writes use new epoch; reads find correct K3 via blob's `k3_epoch` byte. Zero S3 / IAM / PrincipalTag changes.

### 14.8 Codex adversarial review (2026-05-17) — findings + author response

Codex `/codex:adversarial-review` was run against pre-rev-4 design drafts. Four findings, three high + one medium. All addressed.

**Finding 1 [high] — Device-to-actor binding missing.** Pre-rev-4 SidecarRegistry bound device only to `operator_omni`; compromised agent K10 could mint cap claiming a sibling's `agent_omni`. **Fixed**: registry now stores `(operator_omni, actor_omni, role)` per device; cap verification requires `binding.actor_omni == request.agent_omni`.

**Finding 2 [high] — K11 enforcement for master mutations.** Pre-rev-4 scope mutations were authorized by K10 alone or `master_wallet via signer`; per arch.md §5/§5a master authority should require K11. **Fixed**: `set_scope_with_webauthn(...)` requires both K10 sig and K11 WebAuthn assertion over payload.

**Finding 3 [high] — K3 rotation S3 path migration window.** Pre-rev-4 said S3 path uses `current_master_wallet` with lazy migration; first post-rotation read couldn't find pre-rotation blob. **Fixed**: S3 path keyed on `actor_omni` (stable). ZERO migration. Stronger fix than Codex recommended.

**Finding 4 [medium] — Chain as K3 epoch source of truth.** Pre-rev-4 signer held epoch mapping outside chain. **Fixed**: `K3EpochCounter` on chain; workers verify chain epoch at three points (broker mint, worker fetch, signer derive). Triple verification.

**Author push-back recorded**: K11-required-for-scope-revocation could be relaxed in a future rev for emergency UX (stolen-K10 revoke causes DoS, not credential leak, since revocation is fail-safe). Deferred for v2 simplicity.

### 14.9 Phasing — stage 1 (foundation + K11) + stage 2 (multi-device + workers)

**Stage 1** (foundation): sovereign sidecar + on-chain identity + credentials-service worker + **K11 WebAuthn enforcement for master mutations**. Per Codex round-2 (2026-05-17) finding #2, K11 enforcement moved INTO stage 1 — deploying chain-stored ScopeContract with K10-only authorization would create an escalation window. Stage 1 ships:
- Daemon as sovereign sidecar + host-local controls
- On-chain ScopeContract / SidecarRegistry / K3EpochCounter
- credentials-service worker with **dual-read** support (v1 wallet-keyed + v2 actor_omni-keyed paths and envelopes per Codex round-2 finding #3)
- WebAuthn K11 enrollment + master-mutation enforcement (`set_scope_with_webauthn`)
- Migration runbook covering dual-read transition window

See `docs/spec/plans/v2-issues/issue-v2-stage-1-foundation.md`.

**Stage 2** (multi-device + workers): builds on stage 1's K11 enforcement to add multi-master-device M-of-N recovery quorum + audit/memory/email workers + K3 rotation operational runbook. See `docs/spec/plans/v2-issues/issue-v2-stage-2-hardening.md`.

**Deferred**: payment-service. See `docs/spec/plans/v2-issues/issue-payment-service-deferred.md`.

### 14.9a Codex round-2 review (2026-05-17) — stage 1 plan

A second Codex adversarial review on the stage 1 plan flagged three additional findings, all amended into the stage 1 plan before implementation:

1. **Cloud-enforced vs host-local enforcement clarified.** ScopeContract is cloud-authoritative for "what service is in scope". Per-method / per-path / per-spend lives in host-local sidecar config — bypassable by compromised sidecar but bounded by cloud-enforced actor-binding. Stage 1 plan now marks the split explicitly.
2. **K11 enforcement moves into stage 1** (not deferred to stage 2 as originally planned). See §14.9 above.
3. **S3 path / PrincipalTag migration is dual-read by spec.** Stage 1 migration sequence: dual OIDC tags + dual bucket-policy rules + dual-envelope decrypt + dual-path read at credentials-service worker. No step retires v1 until operator-opt-in soak time elapses. See [v2-stage1-migration-and-demo.md](../../docs/v2-stage1-migration-and-demo.md) for the full sequence.

### 14.10 Future work (post stage 2)

- **Per-(user, service) KEK**: finer-grained KEK derivation; v3 hardening
- **Wrap-and-rewrap**: random per-cred KEK + ECIES wraps in broker wrap-table; defends against K3-alone compromise; reserved
- **One-shot CAS-burn caps for state-mutating ops**: strict replay protection; broker nonce-table check
- **ZK-proven cap minting**: broker becomes stateless prover; reserved until proving is sub-100ms
- **Multi-master / threshold scope mutations**: M-of-M master signatures for scope grants
- **Per-operator K3 isolation**: separate K3 per tenant for multi-tenant deployments

### 14.11 What v2 guarantees

| Property | How it's enforced |
|---|---|
| No seed phrase required for daily use | K10 in OS keychain; K11 sealed in platform authenticator; no operator-managed seed |
| Recovery via M-of-N device quorum | Per arch.md §5a.3.1 multi-device flow; no friends, no third parties, no anchor wallet |
| No IdP lock-in after Day 0 | Email/OAuth is one-time sybil check; actor_omni is bound to first SIWE-derived wallet hash, NOT IdP identifier |
| Agent never holds credential bytes | Sidecar holds plaintext only; agent sees localhost proxy URL + placeholder token |
| Device key bound to specific actor (Codex #1) | SidecarRegistry per-actor binding; compromised agent K10 cannot mint as siblings |
| K11 user-presence required for master mutations (Codex #2) | Scope, device-bind, K10-rotation, device-revoke all require fresh K11 WebAuthn |
| K3-rotation tolerance with ZERO S3 migration (Codex #3) | S3 path keyed on actor_omni; K3EpochCounter is global O(1) |
| Chain as K3 epoch source of truth (Codex #4) | K3EpochCounter on chain; triple verification at broker/worker/signer |
| Wallet privacy by default | Sovereign mode default but K3-derived; actor_omni anchors cross-rotation correlation for auditability |
| Per-data-class compromise isolation | Workers per service; one worker compromise = one data class leaked |
| Vendor-pluggability | AWS / Cloudflare / Tencent / self-hosted; mTLS + HTTPS + chain signatures only |
| Audit hosted-but-checkable OR self-hosted OR direct-write | Three tiers per §14.6 |

---

*This is a living document. Update it when the component map, key
inventory, trust-boundary table, or deployment topology changes.
For Figma-design use: the K-numbered key inventory (§3) and the
identity-model diagram (§4) are the most directly transferable.
v2 design lives in §14; foundational architecture in §0-§13. The
sections build on each other — read §0-§13 first for foundation;
§14 layers v2-specific design on top.*
