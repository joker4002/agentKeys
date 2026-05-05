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

```bash
# 1. Generate both ES256 keypairs (Plan §3.5.6 — purpose-tagged).
agentkeys-broker-server keygen --purpose oidc    --out  ~/.agentkeys/broker/oidc-keypair.json
agentkeys-broker-server keygen --purpose session --out  ~/.agentkeys/broker/session-keypair.json
chmod 600 ~/.agentkeys/broker/{oidc,session}-keypair.json

# 2. Set the load-bearing env vars.
export BROKER_BACKEND_URL=https://backend.example.com
export BROKER_DATA_ROLE_ARN=arn:aws:iam::000000000000:role/agentkeys-data-role
export BROKER_OIDC_ISSUER=https://broker.example.com
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

(Phase A.2 — pending.) Full procedure for registering a Google OAuth
web app, configuring the redirect URI, and minting the
`BROKER_OAUTH2_GOOGLE_CLIENT_SECRET_FILE` lands in US-022.

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
