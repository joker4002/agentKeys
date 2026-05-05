# Operator Runbook — Stage 7 (Issue #64) AgentKeys Pluggable Broker

This runbook is the canonical guide for deploying and operating the
AgentKeys pluggable broker introduced in Stage 7 / issue
[litentry/agentKeys#64](https://github.com/litentry/agentKeys/issues/64).

It supersedes the section of `cloud-setup.md` that covers the
pre-pluggable broker only when you are deploying the v0 pluggable
build. The pre-Stage-7 broker (PR #60 + PR #61) continues to use
`cloud-setup.md` §4.

> **This runbook is a Phase 0 draft (US-015).** Phase E (US-039) lands
> the final form: full troubleshooting, restore drill, env-var table
> auto-generated from `crates/agentkeys-broker-server/src/env.rs`,
> rollback procedure. Phase 0 ships every section's heading + intent so
> the BOOT_FAIL anchor URLs already resolve to a real `#section` in
> this file.

---

## Quickstart

The Stage 7 reference deployment hosts the broker at
`broker.litentry.org` and the legacy backend at
`backend.litentry.org`. Substitute your own DNS names for any
self-hosted deployment — the env-var values below are templates, not
secrets.

```bash
# 1. Generate both ES256 keypairs (Plan §3.5.6 — purpose-tagged).
agentkeys-broker-server keygen --purpose oidc    --out  ~/.agentkeys/broker/oidc-keypair.json
agentkeys-broker-server keygen --purpose session --out  ~/.agentkeys/broker/session-keypair.json
chmod 600 ~/.agentkeys/broker/{oidc,session}-keypair.json

# 2. Set the load-bearing env vars (Stage 7 Litentry reference deployment).
export BROKER_BACKEND_URL=https://backend.litentry.org
export BROKER_DATA_ROLE_ARN=arn:aws:iam::000000000000:role/agentkeys-data-role
export BROKER_OIDC_ISSUER=https://broker.litentry.org
export BROKER_OIDC_KEYPAIR_PATH=~/.agentkeys/broker/oidc-keypair.json
export BROKER_SESSION_KEYPAIR_PATH=~/.agentkeys/broker/session-keypair.json
export BROKER_AUTH_METHODS=wallet_sig
export BROKER_AUDIT_ANCHORS=sqlite

# 3. Boot. Tier-1 refuse-to-boot is synchronous; if anything is wrong
#    the process exits with a `BOOT_FAIL: …; see runbook §<anchor>` line.
agentkeys-broker-server --bind 127.0.0.1 --port 8091
```

For a curl-driven sanity test of the SIWE → mint-session-JWT flow, see
[§Smoke Validation](#smoke-validation) below.

### Stage 7 Litentry reference deployment — full env file

For a production-ready testnet deployment that exercises every Phase
A-D feature, copy `/etc/agentkeys/broker.env` from the template below
and `chmod 600`. The only values you must change are the AWS account
ID (`000000000000` → your account), the OAuth2 client_id, and the EVM
contract address (filled in after `forge create`).

```bash
# /etc/agentkeys/broker.env — Stage 7 Litentry reference deployment.

# --- Core ---
BROKER_BACKEND_URL=https://backend.litentry.org
BROKER_DATA_ROLE_ARN=arn:aws:iam::000000000000:role/agentkeys-data-role
BROKER_OIDC_ISSUER=https://broker.litentry.org
BROKER_AWS_REGION=us-east-1
BROKER_AUDIT_DB_PATH=/var/lib/agentkeys/broker/audit.sqlite
BROKER_DATA_DIR=/var/lib/agentkeys/broker/data
BROKER_SHUTDOWN_GRACE_SECONDS=30

# --- Keypairs (Plan §3.5.6 — both required, purpose-tagged) ---
BROKER_OIDC_KEYPAIR_PATH=/etc/agentkeys/oidc-keypair.json
BROKER_SESSION_KEYPAIR_PATH=/etc/agentkeys/session-keypair.json
BROKER_OIDC_JWT_TTL_SECONDS=300
BROKER_SESSION_JWT_TTL_SECONDS=18000

# --- Auth methods (Phase 0 + A.1 + A.2) ---
BROKER_AUTH_METHODS=wallet_sig,email_link,oauth2_google
BROKER_WALLET_PROVISIONER=client_keystore

# --- Email-link (Phase A.1) ---
BROKER_EMAIL_HMAC_KEY_PATH=/etc/agentkeys/email.hmac.key
BROKER_EMAIL_FROM_ADDRESS=auth@litentry.org
BROKER_EMAIL_RATE_LIMIT_PER_EMAIL_HOURLY=5
BROKER_EMAIL_RATE_LIMIT_PER_IP_MINUTELY=30

# --- OAuth2 / Google (Phase A.2) ---
BROKER_OAUTH2_PROVIDERS=google
BROKER_OAUTH2_REDIRECT_URI=https://broker.litentry.org/auth/oauth2/callback
BROKER_OAUTH2_GOOGLE_CLIENT_ID=YOUR-GOOGLE-CLIENT-ID.apps.googleusercontent.com
BROKER_OAUTH2_GOOGLE_CLIENT_SECRET_FILE=/etc/agentkeys/oauth2-google.secret
BROKER_OAUTH2_STATE_HMAC_KEY_PATH=/etc/agentkeys/oauth2-state.hmac.key
BROKER_OAUTH2_JWKS_TTL_SECONDS=3600
BROKER_OAUTH2_START_RATE_LIMIT_PER_IP_MINUTELY=30

# --- Audit anchors (Phase C — Base Sepolia testnet) ---
BROKER_AUDIT_ANCHORS=sqlite,evm_testnet
BROKER_AUDIT_POLICY=dual_strict
BROKER_EVM_RPC_URL=https://sepolia.base.org
BROKER_EVM_CHAIN_ID=84532
BROKER_EVM_CONTRACT_ADDRESS=0x0000000000000000000000000000000000000000   # ← fill in after forge create
BROKER_EVM_FEE_PAYER_KEYSTORE=/etc/agentkeys/fee-payer.keystore.json
BROKER_EVM_FEE_PAYER_PASSWORD_FILE=/etc/agentkeys/fee-payer.pw
BROKER_EVM_FEE_PAYER_MIN_BALANCE=1000000000000000   # 0.001 ETH in wei
BROKER_EVM_PER_IDENTITY_DAILY_TX_BUDGET=100

# --- Per-identity rate limits (Phase C gas-drain) ---
BROKER_RATE_LIMIT_MINTS_PER_HOUR_PER_OMNI=30
BROKER_RATE_LIMIT_CHALLENGES_PER_HOUR_PER_IP=60

# --- Phase D-rest hardening ---
BROKER_METRICS_ENABLED=true
BROKER_REQUEST_BODY_LIMIT_BYTES=1048576

# --- Recovery (Phase B) ---
BROKER_RECOVERY_GRANT_DELAY_SECONDS=0   # 0 = no time-lock; raise to e.g. 86400 for 24h cooldown
```

Boot with:

```bash
set -a; . /etc/agentkeys/broker.env; set +a
agentkeys-broker-server --bind 0.0.0.0 --port 8091
```

---

## Prerequisites

- Linux x86_64 or macOS arm64 (the broker is statically linked Rust).
- TLS termination in front of the broker (nginx, ALB, Traefik). The
  broker logs a warning at startup if you bind to a non-loopback address
  without TLS.
- An AWS IAM role with the trust policy described in §AWS IAM Trust.
- A backend service that exposes `/healthz` and `/session/validate` per
  the legacy contract (used during the cutover until US-011 retires the
  legacy bearer path).
- For email-link auth (Phase A.1+): a verified SES sender identity
  in your AWS account.
- For OAuth2 auth (Phase A.2+): a Google Cloud Console OAuth web
  client with the broker's redirect URI registered.
- For chain audit anchoring (Phase C+): a funded fee-payer keypair on
  the configured EVM testnet (Base Sepolia in v0).

---

## Env Vars

This section is auto-generated from `crates/agentkeys-broker-server/src/env.rs::all()` in Phase E (US-039). Phase 0 ships the full constant inventory so the
drift check in `harness/stage-7-issue-64-done.sh` does not warn.

### Core

| Env Var | Description |
|---|---|
| `BROKER_BACKEND_URL` | Base URL for legacy backend session validation. |
| `BROKER_DATA_ROLE_ARN` | Role the broker assumes via STS for users. |
| `BROKER_AUDIT_DB_PATH` | Path to audit-log SQLite DB. |
| `BROKER_AWS_REGION` | AWS region for STS calls. |
| `BROKER_SESSION_DURATION_SECONDS` | Lifetime in seconds of minted AWS sessions [900, 43200]. |
| `BROKER_BACKEND_TIMEOUT_SECONDS` | HTTP timeout for backend `/session/validate`. |
| `BROKER_SHUTDOWN_GRACE_SECONDS` | SIGTERM-to-exit grace window seconds. |
| `BROKER_DEV_MODE` | Relaxes HTTPS-only OIDC-issuer rule (logged loudly). |
| `BROKER_REFUSE_TO_BOOT_STRICT` | Promotes Tier-2 reachability to Tier-1 refuse-to-boot. |
| `BROKER_DATA_DIR` | Directory for persistent runtime caches. |
| `BROKER_REQUEST_BODY_LIMIT_BYTES` | Maximum HTTP request body size in bytes. |
| `BROKER_NTP_MAX_SKEW_SECONDS` | Maximum tolerated NTP skew for SIWE timestamps. |
| `BROKER_METRICS_ENABLED` | Enable Prometheus `/metrics` endpoint. |

### OIDC issuer keypair (existing — used by AWS STS AssumeRoleWithWebIdentity)

| Env Var | Description |
|---|---|
| `BROKER_OIDC_ISSUER` | Public HTTPS issuer URL. |
| `BROKER_OIDC_KEYPAIR_PATH` | Path to the persisted OIDC ES256 keypair (purpose=oidc). |
| `BROKER_OIDC_JWT_TTL_SECONDS` | TTL of OIDC JWTs minted for STS [60, 3600]. |

### Session JWT keypair (NEW — broker-internal, separate from OIDC)

| Env Var | Description |
|---|---|
| `BROKER_SESSION_KEYPAIR_PATH` | Path to the persisted session ES256 keypair (purpose=session). |
| `BROKER_SESSION_JWT_TTL_SECONDS` | TTL of session JWTs [60, 86400]. |

### Auth method selection

| Env Var | Description |
|---|---|
| `BROKER_AUTH_METHODS` | Comma list of enabled auth methods (`wallet_sig,email_link,oauth2_google`). |
| `BROKER_WALLET_PROVISIONER` | Wallet provisioner plug-in name (default `client_keystore`). |

### Audit anchors

| Env Var | Description |
|---|---|
| `BROKER_AUDIT_ANCHORS` | Comma list of enabled audit anchors (`sqlite,evm_testnet`). |
| `BROKER_AUDIT_POLICY` | Multi-anchor write policy. One of `dual_strict`, `sqlite_primary`, `evm_primary`. |

### EVM audit anchor (Phase C — Base Sepolia testnet)

| Env Var | Description |
|---|---|
| `BROKER_EVM_RPC_URL` | EVM JSON-RPC URL. |
| `BROKER_EVM_CHAIN_ID` | EVM chain ID (84532 for Base Sepolia). |
| `BROKER_EVM_CONTRACT_ADDRESS` | Deployed `AgentKeysAudit` contract address. |
| `BROKER_EVM_FEE_PAYER_KEYSTORE` | Path to encrypted fee-payer keystore JSON. |
| `BROKER_EVM_FEE_PAYER_PASSWORD_FILE` | Path to fee-payer keystore password file (mode 0600). |
| `BROKER_EVM_FEE_PAYER_MIN_BALANCE` | Wei threshold below which EVM anchor → Unready. |
| `BROKER_EVM_PER_IDENTITY_DAILY_TX_BUDGET` | Per-OmniAccount daily EVM-tx budget. |

### Email auth (Phase A.1)

| Env Var | Description |
|---|---|
| `BROKER_EMAIL_HMAC_KEY_PATH` | Path to 32+ byte HMAC key for email tokens. |
| `BROKER_EMAIL_FROM_ADDRESS` | Verified SES sender email. |
| `BROKER_EMAIL_SUCCESS_REDIRECT_URL` | Optional operator success-page redirect URL. |
| `BROKER_EMAIL_RATE_LIMIT_PER_EMAIL_HOURLY` | Per-email per-hour bucket. |
| `BROKER_EMAIL_RATE_LIMIT_PER_IP_MINUTELY` | Per-IP per-minute bucket. |

### OAuth2 auth (Phase A.2)

| Env Var | Description |
|---|---|
| `BROKER_OAUTH2_PROVIDERS` | Comma list of enabled providers (v0: `google`). |
| `BROKER_OAUTH2_REDIRECT_URI` | Public callback URL. |
| `BROKER_OAUTH2_GOOGLE_CLIENT_ID` | Google OAuth client ID. |
| `BROKER_OAUTH2_GOOGLE_CLIENT_SECRET_FILE` | Path to Google client secret file (mode 0600). |
| `BROKER_OAUTH2_STATE_HMAC_KEY_PATH` | Path to 32-byte file for OAuth2 state HMAC. |
| `BROKER_OAUTH2_JWKS_TTL_SECONDS` | JWKS cache TTL in seconds. |
| `BROKER_OAUTH2_START_RATE_LIMIT_PER_IP_MINUTELY` | Per-IP per-minute on `/v1/auth/oauth2/start`. |

### Per-identity / per-IP rate limits (Phase C gas-drain mitigations)

| Env Var | Description |
|---|---|
| `BROKER_RATE_LIMIT_MINTS_PER_HOUR_PER_OMNI` | Maximum mints per OmniAccount per hour. |
| `BROKER_RATE_LIMIT_CHALLENGES_PER_HOUR_PER_IP` | Maximum auth-challenge requests per IP per hour. |

### Recovery (Phase B)

| Env Var | Description |
|---|---|
| `BROKER_RECOVERY_GRANT_DELAY_SECONDS` | Time-lock seconds before recovery grant activates. |

### Legacy aliases (kept for one minor version, deprecation logged at boot)

| Env Var | Description |
|---|---|
| `DAEMON_ACCESS_KEY_ID` | Legacy static IAM-user access-key ID. |
| `DAEMON_SECRET_ACCESS_KEY` | Legacy static IAM-user secret-access key. |
| `BROKER_DAEMON_ACCESS_KEY_ID` | Legacy prefixed alias. |
| `BROKER_DAEMON_SECRET_ACCESS_KEY` | Legacy prefixed alias. |
| `BROKER_AGENT_ROLE_ARN` | Legacy alias of `BROKER_DATA_ROLE_ARN`. |
| `ACCOUNT_ID` | Legacy AWS account ID; derives `BROKER_DATA_ROLE_ARN`. |
| `REGION` | Legacy alias of `BROKER_AWS_REGION`. |

---

## Boot Sequence

The broker boots in two tiers per Plan §6.

### Tier 1 — Refuse-to-boot (synchronous, before listener bind)

Config-correctness only. Failure → exit 1 with single-line:
`BOOT_FAIL: <var_or_path>=<value>: <reason>; see runbook §<anchor>`.

The script `agentkeys-broker-server` will fail to start if any of:
- A required env var is missing or unparseable.
- `BROKER_OIDC_ISSUER` is `http://` and `BROKER_DEV_MODE` is not `true`.
- Either keypair file is missing or carries the wrong `purpose` tag.
- A name in `BROKER_AUTH_METHODS` / `BROKER_WALLET_PROVISIONER` /
  `BROKER_AUDIT_ANCHORS` is not compiled in.
- SQLite migrations fail.

### Tier 2 — Boot-to-Unready (async, after listener bound)

External reachability checks that flip the corresponding atomic flag in
`Tier2State` once they succeed. The broker binds the port and returns
`/healthz=200` + `/readyz=503` until each enabled probe passes:
- Backend `/healthz` reachable (always probed).
- SES sender identity verified (when `email_link` is in `BROKER_AUTH_METHODS`).
- EVM RPC `eth_chainId` returns the configured chain (when `evm_testnet`
  is in `BROKER_AUDIT_ANCHORS`).
- EVM fee-payer balance ≥ `BROKER_EVM_FEE_PAYER_MIN_BALANCE`.

`BROKER_REFUSE_TO_BOOT_STRICT=true` collapses Tier 2 into Tier 1
(every reachability check becomes a hard boot fail).

---

## TLS Termination

The broker MUST be deployed behind a TLS-terminating reverse proxy when
exposed to anything other than localhost. Bearer tokens, session JWTs,
and minted AWS credentials all travel in cleartext over the broker's
HTTP listener. The broker logs a warning at startup if you bind to a
non-loopback address.

Recommended: nginx with HTTP/2, OCSP stapling, and HSTS preload. AWS
ALB or Cloudflare also work.

---

## OIDC Issuer DNS

`BROKER_OIDC_ISSUER` must be a stable HTTPS URL that resolves to your
deployed broker. AWS IAM `create-open-id-connect-provider` fetches the
JWKS from `<issuer>/.well-known/jwks.json` once at provider creation
time and verifies it.

In dev, `BROKER_DEV_MODE=true` relaxes the HTTPS rule.

---

## AWS IAM Trust

Per the existing `cloud-setup.md` §4 OIDC federation pattern: create
an IAM OIDC provider for `BROKER_OIDC_ISSUER`, then a role with a trust
policy granting `sts:AssumeRoleWithWebIdentity` to that provider scoped
by `aud=sts.amazonaws.com` and a `sub` prefix.

The broker's `BROKER_DATA_ROLE_ARN` must point at this role.

---

## OAuth2 Setup

(Phase A.2 — US-020/021/022.) The broker supports OAuth2 / OpenID Connect
sign-in with id_token + PKCE + state HMAC + CLI polling per plan §3.5.4.
v0 ships Google as the only provider; GitHub and Apple are wired into the
trait surface and gated behind their own Cargo features for v1+.

### Google Cloud Console

1. Open <https://console.cloud.google.com/apis/credentials> in a project
   you own (create one first if needed).
2. **APIs & Services → Credentials → Create Credentials → OAuth client ID.**
3. Application type: **Web application**.
4. Authorized redirect URIs: add the public callback URL of your broker
   exactly as you'll configure `BROKER_OAUTH2_REDIRECT_URI`. Example:

   ```
   https://broker.litentry.org/auth/oauth2/callback
   ```

   Google enforces an exact match — trailing slashes, scheme, host, and
   path all matter. If the broker is fronted by a reverse proxy, register
   the public URL the user's browser sees, not the internal one.
5. Click **Create**. Save:
   - the **Client ID** → goes into `BROKER_OAUTH2_GOOGLE_CLIENT_ID`;
   - the **Client secret** → write to a file, `chmod 600`, set
     `BROKER_OAUTH2_GOOGLE_CLIENT_SECRET_FILE` to its path.
6. Under **OAuth consent screen** make sure your support email and app
   name are filled in (Google blocks sign-in until these are present).

### State HMAC key

`BROKER_OAUTH2_STATE_HMAC_KEY_PATH` must point at a file containing at
least 32 random bytes. Generate with:

```bash
head -c 32 /dev/urandom > /etc/agentkeys/oauth2-state.hmac.key
chmod 600 /etc/agentkeys/oauth2-state.hmac.key
```

The key signs the OAuth2 `state` parameter so a maliciously crafted
callback (e.g. CSRF) cannot drive the broker into completing a flow on
behalf of a user who never started one. Rotate by writing a new file +
restarting the broker; in-flight flows older than `state` TTL (10 min)
will fail and the CLI will start a fresh flow.

### Smoke

After setting the env vars and restarting:

```bash
# 1. Initiate
curl -X POST http://localhost:8091/v1/auth/oauth2/start \
  -H 'content-type: application/json' \
  -d '{"provider":"google"}'
# Returns {"request_id":"oa2-…","authorization_url":"https://accounts.google.com/...","poll_url":"/v1/auth/oauth2/status/oa2-…"}

# 2. Open authorization_url in a browser, sign in with your Google account.
#    Google redirects back to the broker's /auth/oauth2/callback.

# 3. Poll
curl http://localhost:8091/v1/auth/oauth2/status/oa2-…
# Returns {"status":"verified","session_jwt":"eyJ…","omni_account":"…","identity_type":"oauth2_google","identity_value":"<google-sub>"}
```

The session JWT NEVER appears in the browser-facing callback response —
it lands on the CLI poll only (plan §3.5.4 security posture).

### Failure modes

| Symptom on CLI poll | Cause | Fix |
|---|---|---|
| `status:"failed"` + `reason` containing `user_denied` | User clicked "cancel" on Google's consent screen | Retry; the user must re-initiate from the CLI. |
| `status:"failed"` + reason containing `expired` | id_token's `exp` < broker's clock | NTP-sync the broker host; re-initiate. |
| `status:"failed"` + reason containing `audience` | Mismatched `BROKER_OAUTH2_GOOGLE_CLIENT_ID` (ID rotated in Console without restart) | Restart broker after env var change. |
| `state: HMAC mismatch` 401 on callback | `BROKER_OAUTH2_STATE_HMAC_KEY_PATH` was rotated mid-flow | Expected — flow must be re-initiated. |
| `request_id 400` from CLI poll | Flow timed out (>10 min between start + click) | Re-initiate. |

### Multi-account browser quirk

`prompt=select_account` is hardcoded in the authorization URL so the
broker always forces Google's account chooser. This defends against the
silent-wrong-account scenario where a user has multiple Google accounts
in their browser and would otherwise be auto-signed-in to the wrong one.

---

## Grants & Recovery (Phase B — US-025/026/027/028)

### Grants overview

Per plan §3.5.5: a master OmniAccount issues `POST /v1/grant/create` to
authorize a specific daemon address to mint AWS credentials for a
specific `(service, scope_path)`, bounded by `expires_at` + `max_uses`.
Each grant carries an `audit_proof` — a broker-signed JWT over the
canonical grant content. Tampering with the SQLite row breaks
`audit_proof` verification (DB exfiltration cannot produce a
verified-but-tampered grant).

```bash
# Master creates a grant for daemon 0xabc to mint S3 creds for bots/0xabc/.
curl -X POST https://broker.litentry.org/v1/grant/create \
  -H "Authorization: Bearer $MASTER_SESSION_JWT" \
  -H "Content-Type: application/json" \
  -d '{
    "daemon_address": "0xabc...",
    "service":        "s3",
    "scope_path":     "bots/0xabc/",
    "expires_at":     1893456000,
    "max_uses":       1000
  }'
# Returns {"grant_id":"grn-...","audit_proof":"eyJ...",...}

# Master lists their grants.
curl https://broker.litentry.org/v1/grant/list \
  -H "Authorization: Bearer $MASTER_SESSION_JWT"

# Master revokes a grant. Instant — one row update. Re-revoke is a no-op.
curl -X POST https://broker.litentry.org/v1/grant/revoke \
  -H "Authorization: Bearer $MASTER_SESSION_JWT" \
  -H "Content-Type: application/json" \
  -d '{"grant_id":"grn-..."}'
```

### Migration window — implicit-grant fallback

The mint endpoint currently allows mints WITHOUT an explicit grant for
backward-compatibility with Phase 0 daemons (legacy `NoGrant` path
documented inline in `src/handlers/mint.rs::mint_v2`). The audit log
records these mints with an empty `grant_id` column.

**This is an intentional Phase 0→Phase B migration window.** Phase E
US-039 will flip the default to fail-closed (`NoGrant` → 403). Operators
should:

1. Roll out the broker with grants enabled (this build).
2. Call `/v1/grant/create` for every existing daemon address.
3. Verify mints continue to succeed (now with non-empty `grant_id` in
   audit rows).
4. Set `BROKER_REQUIRE_EXPLICIT_GRANT=true` (Phase E env var) to flip
   the default to fail-closed.
5. Audit any 403s for daemons that didn't get a grant.

### Recovery flow

Per plan §3.5.5: recovery is master-gated, NOT email-only re-binding
(Codex P0 #4 from earlier review). The flow:

1. User loses their master wallet but holds a previously-linked email
   or oauth2 identity.
2. User calls `POST /v1/wallet/recover/lookup` with their email →
   broker returns the master's OmniAccount.
3. User reaches the master out-of-band (same person on a different
   device, or a trusted relationship).
4. Master authenticates fresh via `/v1/auth/wallet/{start,verify}` and
   calls `/v1/grant/create` on the user's NEW daemon address.
5. New daemon mints with the new grant. Old daemon's grant can be
   `/v1/grant/revoke`'d.

`POST /v1/wallet/link` is master-only. Cross-master claim
(different OmniAccount tries to claim an identity already owned by a
different master) returns 401.

`POST /v1/wallet/recover/lookup` is intentionally unauthenticated —
the OmniAccount is a SHA256 hash and discovery does not enable
impersonation. The actual recovery grant always requires master consent.

`BROKER_RECOVERY_GRANT_DELAY_SECONDS` is an optional time-lock before a
recovery grant becomes active (off by default for v0). Operators can
enable for environments where compromised-master defense is critical.

---

## EVM Audit Anchor — Base Sepolia (Phase C — US-030/031/032/033/034/035)

### What ships in this build (v0)

- `src/plugins/audit/evm.rs`: `EvmAuditConfig` + `EvmStubAnchor` (the
  stub round-trips without network — used by tests + reconciler harness).
- `src/plugins/audit/breaker.rs`: `CircuitBreaker` with
  Closed/Open/HalfOpen state machine, drop-as-failure semantics,
  serialized half-open probes.
- `src/plugins/audit/sqlite.rs`: three-state lifecycle helpers
  (`anchor_pending` / `promote_to_confirmed` / `promote_to_quarantined`
  / `list_pending_older_than` / `list_quarantined`) for dual-anchor mode.
- `src/storage/rate_limit_mints.rs`: `MintRateLimiter` enforcing
  per-OmniAccount mints/hour + per-OmniAccount EVM-tx daily budget.
- `solidity/src/AgentKeysAudit.sol`: append-only audit log contract
  with indexed `recordHash` + `omniAccount` + `wallet` event topics.

### What you do as an operator (deploy + go-live)

#### 1. Deploy the contract to Base Sepolia

Install Foundry: <https://book.getfoundry.sh/getting-started/installation>.

```bash
cd crates/agentkeys-broker-server/solidity
forge build
forge test
# Set up env vars first (see runbook for keystore generation).
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
export PRIVATE_KEY=$(cat /etc/agentkeys/fee-payer.priv)
forge create src/AgentKeysAudit.sol:AgentKeysAudit \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
# Save returned address as BROKER_EVM_CONTRACT_ADDRESS.
```

Persist the deployment metadata at
`crates/agentkeys-broker-server/solidity/deployments/base-sepolia.json`
so the broker repo carries the canonical contract address.

#### 2. Fund the fee-payer wallet

The broker submits one transaction per mint to the audit contract —
each tx costs gas. Fund the fee-payer wallet on Base Sepolia (use the
public faucet at <https://www.alchemy.com/faucets/base-sepolia>).

`BROKER_EVM_FEE_PAYER_MIN_BALANCE` (default 0.001 ETH) is the
threshold below which the EVM anchor flips to `Unready` — set to a
value that gives you ~30 min of mint capacity at peak.

#### 3. Configure the broker

Set Phase C env vars per `## Env Vars` table above. Critical:
- `BROKER_AUDIT_ANCHORS=sqlite,evm_testnet`
- `BROKER_AUDIT_POLICY=dual_strict`
- `BROKER_EVM_RPC_URL=https://sepolia.base.org`
- `BROKER_EVM_CHAIN_ID=84532`
- `BROKER_EVM_CONTRACT_ADDRESS=0x...` (from step 1)
- `BROKER_EVM_FEE_PAYER_KEYSTORE=/etc/agentkeys/fee-payer.keystore.json`
- `BROKER_EVM_FEE_PAYER_PASSWORD_FILE=/etc/agentkeys/fee-payer.pw` (mode 0600)

#### 4. Live alloy integration (V0.1-FOLLOWUPS Phase E hardening)

The current build registers `EvmStubAnchor` for the `evm_testnet`
audit anchor selection — it simulates round-trip behavior without
network I/O. The alloy-driven `EvmAuditAnchor` (live transaction
submission, receipt polling, log topic verification) lands as a Phase
E hardening pass. Until then, the structural layer (three-state
lifecycle, breaker, gas-drain) ships with the stub.

### Gas-drain mitigations (US-034)

Even with the explicit grant boundary, an attacker who steals a
session JWT could try to amplify mints into draining the fee-payer.
Three layers of defense:

1. **Per-OmniAccount mints/hour** (`BROKER_RATE_LIMIT_MINTS_PER_HOUR_PER_OMNI`,
   default 30): enforced via `MintRateLimiter::check_mint`. Returns
   429 with `Retry-After`.
2. **Per-OmniAccount daily EVM-tx budget**
   (`BROKER_EVM_PER_IDENTITY_DAILY_TX_BUDGET`, default 100): enforced
   via `MintRateLimiter::check_evm_tx`. Independently capped from
   STS calls so the on-chain spend is bounded.
3. **Fee-payer min-balance floor**
   (`BROKER_EVM_FEE_PAYER_MIN_BALANCE`): broker flips EVM anchor to
   `Unready` immediately when balance drops below; mints serve 503.

---

## Metrics & Observability (Phase D-rest — US-036)

### Prometheus counters

Set `BROKER_METRICS_ENABLED=true` to expose `GET /metrics` with the
standard exposition format. Counters available:

- `agentkeys_broker_mints_total` / `_failed_total`
- `agentkeys_broker_audit_writes_total` / `_failed_total`
- `agentkeys_broker_auth_attempts_total`
- `agentkeys_broker_auth_failed_unauthorized_total` / `_rate_limited_total` / `_other_total`
- `agentkeys_broker_idempotency_hits_total` / `_conflicts_total`

When `BROKER_METRICS_ENABLED` is unset or `false`, `/metrics` returns
404 — operators who don't run a Prometheus scraper should leave it
disabled to avoid leaking counter shapes to unauthenticated probers.

Histograms (mint_latency, audit_write_latency) + per-handler counter
bumps land in V0.1-FOLLOWUPS Phase E hardening.

### Idempotency-Key

The mint endpoint accepts an `Idempotency-Key: <ulid>` header. Bodies
that hash to the same fingerprint within the 5-minute window return
the cached response (no re-mint, no STS quota burn). Same key + a
different body returns 422.

`BROKER_REQUEST_BODY_LIMIT_BYTES` enforces the request body size limit
(default 1 MiB) at router level (DefaultBodyLimit middleware) — closes
Codex R2-F18 (declared-but-unenforced).

---

## Smoke Validation

Run the harness smoke script:

```bash
bash harness/stage-7-issue-64-phase0-smoke.sh
```

This asserts cargo build + tests + clippy + grep-style invariants
(env-var centralization, BOOT_FAIL anchor format, plug-in trait files
present, router routes registered).

For a manual end-to-end check against a running broker:

```bash
# 1. Fetch SIWE message
curl -X POST http://localhost:8091/v1/auth/wallet/start \
  -H 'content-type: application/json' \
  -d '{"address":"0xYourAddr…","chain_id":84532}'

# Returns {"request_id":"siwe-…","siwe_message":"…", "nonce":"…", …}

# 2. Sign the SIWE message with your wallet (MetaMask, cast, etc.)
#    using personal_sign (which does the EIP-191 envelope for you).

# 3. Verify
curl -X POST http://localhost:8091/v1/auth/wallet/verify \
  -H 'content-type: application/json' \
  -d '{"request_id":"siwe-…","signature":"0x…<130 hex>"}'

# Returns {"session_jwt":"eyJ…","expires_at":…,"omni_account":"…", …}
```

---

## Rollback

(Phase E US-039 lands the final rollback procedure.) The broker is
forward-only with regard to schema migrations; rollback means
deploying the previous binary in read-only mode, draining the
reconciler queue, and hard-cutting. SQLite snapshots from the
`BROKER_AUDIT_DB_PATH` should be taken on a fixed cadence (Phase E
documents the recommended interval).

---

## Troubleshooting (anchored from BOOT_FAIL messages)

Anchors below match the `see runbook §<anchor>` suffix on each
`BOOT_FAIL:` stderr line emitted by Tier 1 boot.

### oidc-issuer

`BROKER_OIDC_ISSUER` must start with `https://` in non-dev mode.
For local development set `BROKER_DEV_MODE=true` to allow `http://`.

### oidc-keypair

The OIDC keypair file must exist before boot (silent generation is
disabled per Plan §6). Generate with:
```bash
agentkeys-broker-server keygen --purpose oidc --out  $BROKER_OIDC_KEYPAIR_PATH
chmod 600 $BROKER_OIDC_KEYPAIR_PATH
```

### session-keypair

Same as above for the session keypair:
```bash
agentkeys-broker-server keygen --purpose session --out $BROKER_SESSION_KEYPAIR_PATH
chmod 600 $BROKER_SESSION_KEYPAIR_PATH
```

If the file exists but the JSON has `"purpose": "oidc"`, the load
refuses with a `purpose mismatch` error. The two files MUST be distinct.

### auth-nonces-db / wallets-db / audit-sqlite

SQLite migrations failed. Check the directory pointed at by
`BROKER_AUDIT_DB_PATH` is writable by the broker process. The
`auth_nonces.sqlite` + `wallets.sqlite` files live in the same
directory.

### audit-policy

`BROKER_AUDIT_POLICY` must be one of `dual_strict`, `sqlite_primary`,
`evm_primary`.

### auth-method-not-compiled / wallet-provisioner-not-compiled / audit-anchor-not-compiled

A name in `BROKER_AUTH_METHODS` / `BROKER_WALLET_PROVISIONER` /
`BROKER_AUDIT_ANCHORS` references a plug-in that is not compiled into
the binary. Either rebuild with the matching `--features` flag or
remove the name.

### auth-method-empty / audit-anchor-empty

At least one auth method and one audit anchor must be enabled.
Defaults are `wallet_sig` and `sqlite` respectively.

### backend-reachability

Tier-2 probe to `BROKER_BACKEND_URL/healthz` has not yet succeeded
since boot. `/readyz` returns 503. If `BROKER_REFUSE_TO_BOOT_STRICT=true`
the broker exits instead.

### ses-verification

(Phase A.1+ — when `email_link` is enabled.) SES sender identity
not yet verified. Use `aws ses verify-email-identity` and ensure the
broker's IAM identity has `ses:GetIdentityVerificationAttributes`.

### evm-rpc-reachability

(Phase C+ — when `evm_testnet` is enabled.) EVM RPC `eth_chainId`
probe failed or returned the wrong chain. Verify `BROKER_EVM_RPC_URL`
and `BROKER_EVM_CHAIN_ID`.

### evm-fee-payer-balance

(Phase C+.) Fee-payer wallet balance is below
`BROKER_EVM_FEE_PAYER_MIN_BALANCE`. Top up the address from the
testnet faucet.
