# Operator Runbook — AgentKeys Broker Server

**Audience:** the person running `agentkeys-broker-server` for a team. If you're an app developer trying to use a broker someone else runs, see [`dev-setup.md` §4](./dev-setup.md). If you're an end user of an agent, see [`dev-setup.md` §6](./dev-setup.md).

**Scope:** start, supervise, rotate keys, monitor audit, and migrate from local to hosted. v0.1 deliberately avoids TEE / KMS / hosted-only paths — those land later.

> **WIP / scratchpad.** This runbook ships alongside the v0.1 broker. Stage 7 phase 1 (broker mint-aws-creds + audit) and phase 2 (OIDC issuer surface + provisioner-scripts AWS-cred wiring) are both live. The `sts:AssumeRoleWithWebIdentity` federation step is still deferred — it needs public TLS hosting of the issuer URL, see [`stage7-wip.md`](./stage7-wip.md). Stage 8 (off-chain vault) sections are forward-looking.

## 1. What the broker is

`agentkeys-broker-server` is the long-running HTTP service that holds the operator's long-lived `agentkeys-daemon` AWS access key and brokers 1-hour scoped credentials to authenticated daemons. It is the boundary that lets app developers run daemons against your infrastructure **without holding any AWS credentials themselves**.

User-facing endpoints:

- `POST /v1/mint-aws-creds` — bearer-token in, temp AWS creds out (phase 1).
- `POST /v1/mint-oidc-jwt` — bearer-token in, short-lived ES256 JWT out (phase 2). Suitable for `sts:AssumeRoleWithWebIdentity` once the issuer URL is publicly hosted.
- `GET /.well-known/openid-configuration` — OIDC discovery doc.
- `GET /.well-known/jwks.json` — JWK Set with the broker's ES256 P-256 public key + `kid`.

Operator-side: `/healthz`, `/readyz` health checks, and an audit log written to local SQLite. Both `mint-aws-creds` and `mint-oidc-jwt` write to the same audit table — `requested_role = "oidc_jwt"` distinguishes JWT mints in the ledger.

The remaining federation step (`aws iam create-open-id-connect-provider --url $BROKER_OIDC_ISSUER` + `sts:AssumeRoleWithWebIdentity`) is the public-hosting recipe in [`stage7-wip.md` §"Phase 2 — federation step"](./stage7-wip.md).

## 2. Threat model — what the broker is and isn't defending against

**Defends against:** developer laptops being lost, stolen, or compromised. Without the broker, every developer holds the same long-lived daemon AWS key — one compromise burns everyone. With the broker, only the broker process holds the long-lived key; developer machines hold only short-lived bearer tokens.

**Does NOT defend against:** broker process compromise. If an attacker gets RCE on the broker, they get the long-lived AWS key and can mint arbitrary scoped credentials. The v0.1 broker runs on commodity hardware in plaintext; TEE-backed hosting is the v0.2+ evolution. See [`spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md) for the broader position.

**Operator implications for v0.1:**

- Run the broker on a host you trust. Don't co-tenant with untrusted workloads.
- Rotate the daemon AWS key on a schedule (§5).
- Watch the audit log (§6) — anomalous mint patterns are your earliest signal.

## 3. Start the broker

### 3.1 AWS credentials

The broker resolves AWS credentials through the AWS SDK's default provider chain — **named profiles in `~/.aws/credentials`** (recommended for local dev), **EC2 instance profile via IMDS** (recommended for cloud deployments), or static IAM-user keys in env vars (legacy fallback).

#### Recommended: named profiles + `awsp`

Profiles live in `~/.aws/credentials` and `~/.aws/config` (mode `0600`). One profile per role; switch with `awsp <name>` or `export AWS_PROFILE=<name>`. Example layout:

```
~/.aws/credentials             # mode 0600
[agentkeys-admin]              # admin operations
aws_access_key_id = AKIA...
aws_secret_access_key = ...

[agentkeys-broker]             # EC2 Instance Connect to broker host
aws_access_key_id = AKIA...
aws_secret_access_key = ...

[agentkeys-daemon]             # what the broker process assumes from
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

```
~/.aws/config                  # mode 0600
[profile agentkeys-admin]
region = us-east-1
output = json

[profile agentkeys-broker]
region = us-east-1

[profile agentkeys-daemon]
region = us-east-1
```

Run the broker with the daemon profile active:

```bash
awsp agentkeys-daemon          # sets AWS_PROFILE=agentkeys-daemon
agentkeys-broker-server --port 8091
# → "AWS credentials: SDK default chain (AWS_PROFILE / ~/.aws / IMDS)"
```

The broker logs which credential path it picked at startup, so misconfiguration is visible in the first second of the log.

#### Recommended: EC2 instance profile

When the broker runs on EC2, attach an instance profile granting `sts:AssumeRole` on `agentkeys-data-role`. The SDK picks credentials from IMDS automatically — no env vars, no shared files, no rotation step. This is the path `scripts/setup-broker-host.sh` sets up.

#### Legacy fallback: static IAM-user keys in env

Set both `DAEMON_ACCESS_KEY_ID` *and* `DAEMON_SECRET_ACCESS_KEY` (or the `BROKER_DAEMON_*` aliases). The broker logs `AWS credentials: static IAM-user keys (DAEMON_ACCESS_KEY_ID env)` when it picks this path. Setting only one of the pair is rejected at startup. Prefer profiles or instance-profile.

### 3.2 Other configuration

| Variable | Required | Description |
|---|---|---|
| `BROKER_BACKEND_URL` | yes | URL of the AgentKeys backend that issues session tokens (mock-server in dev, chain in v0.2+). |
| `BROKER_DATA_ROLE_ARN` | yes (or `ACCOUNT_ID`) | ARN of the `agentkeys-data-role` IAM role the broker assumes-into. If unset, derived from `ACCOUNT_ID` as `arn:aws:iam::$ACCOUNT_ID:role/agentkeys-data-role`. The legacy `BROKER_AGENT_ROLE_ARN` is still accepted as a fallback for pre-2026-04-28 deployments. |
| `BROKER_AWS_REGION` | no | AWS region for the STS call. Falls back to `REGION` (the rest-of-agentKeys convention) before defaulting to `us-east-1`. The active profile's `region` setting is used by the SDK independently for credential lookup. |
| `BROKER_AUDIT_DB_PATH` | no | SQLite path for the audit log. Default: `$HOME/.agentkeys/broker/audit.sqlite`. |
| `BROKER_SESSION_DURATION_SECONDS` | no | TTL for minted credentials. Default: `3600` (1 h). Min: `900`, max: `43200`. |
| `BROKER_BACKEND_TIMEOUT_SECONDS` | no | HTTP timeout for backend `/session/validate` calls. Default: `10`. |
| `BROKER_SHUTDOWN_GRACE_SECONDS` | no | Hard cap on graceful-shutdown drain. Default: `30`. |
| `BROKER_OIDC_ISSUER` | no | Public URL the broker advertises in the OIDC discovery doc and JWT `iss` claim. Must match the URL used at `aws iam create-open-id-connect-provider` time. Default: `https://oidc.agentkeys.dev`. |
| `BROKER_OIDC_KEYPAIR_PATH` | no | Path to the persisted ES256 keypair (mode 0600). Generated on first start, reused on subsequent restarts so the registered IAM OIDC provider stays valid. Default: `$HOME/.agentkeys/broker/oidc-keypair.json`. |
| `BROKER_OIDC_JWT_TTL_SECONDS` | no | TTL (seconds) for minted OIDC JWTs. Default: `300`. Bounded `[60, 3600]`. |
| `DAEMON_ACCESS_KEY_ID` / `DAEMON_SECRET_ACCESS_KEY` | no (legacy) | Static IAM-user keys. Only used when no profile / instance profile / SDK default is available. Both must be set together. |

`ACCOUNT_ID` is read indirectly to derive `BROKER_DATA_ROLE_ARN`. Persist non-secret values (region, account ID, role ARN, OIDC issuer URL) wherever your shell prefers; the broker no longer needs secrets in its environment.

### 3.3 Run

```bash
awsp agentkeys-daemon                                          # or attach instance profile
cargo run --release -p agentkeys-broker-server -- --port 8091
# → broker listening on 0.0.0.0:8091
```

Or from the built binary:

```bash
awsp agentkeys-daemon
./target/release/agentkeys-broker-server --port 8091
```

The first second of the log shows which credential path the broker picked: `AWS credentials: SDK default chain ...` or `AWS credentials: static IAM-user keys ...`. Always check this before declaring the broker healthy in a new environment.

### 3.4 Verify it came up

```bash
curl -sf http://127.0.0.1:8091/healthz       # → 200 ok
curl -sf http://127.0.0.1:8091/readyz        # → 200 ok if backend + STS reachable, 503 otherwise
```

`/readyz` checks: the configured `BROKER_BACKEND_URL` is reachable, and the broker's daemon credentials can call `sts:GetCallerIdentity`. Use this as your supervisor health probe.

## 4. Supervise

The broker is a stateless HTTP service (audit DB aside). Restart it freely — there's no in-memory session state to preserve. Recommended supervision:

- **systemd** (Linux operator host): unit file with `Restart=on-failure`, `EnvironmentFile=` pointing at a 0600 file (or `LoadCredential=`).
- **launchd** (macOS dev box): plist with `KeepAlive` + `ThrottleInterval`.
- **PM2 / supervisord** are also fine — anything that respawns on crash.

Logs go to stderr in `tracing-subscriber` JSON format when `RUST_LOG=info` is set. Aggregate them with whatever you already use (journald, CloudWatch, Loki).

## 5. Rotate the daemon AWS key

Long-lived keys age out. Rotation procedure depends on the credential path:

### Named profile (recommended)

1. In IAM, **create** a second access key on the `agentkeys-daemon` user — both old and new keys are now valid.
2. Update the `agentkeys-daemon` profile in `~/.aws/credentials` with the new key.
3. Restart the broker — the SDK re-reads the shared file on each `aws_config::defaults().load()` (i.e., on process restart).
4. Verify with `curl /readyz` — should return 200.
5. In IAM, **deactivate** (not delete) the old access key. Wait 24 h.
6. If nothing broke, delete the old key. If something broke, reactivate and roll back.

### EC2 instance profile

Rotation is automatic — IMDS-vended credentials refresh on a schedule managed by AWS. No operator step.

### Legacy static-keys env-var path

Same as the profile flow but step 2 updates the `DAEMON_*` env vars in your supervisor config.

**Cadence recommendation:** rotate every 90 days minimum, immediately on any operator-laptop compromise.

## 6. Audit

Every credential mint is logged to `BROKER_AUDIT_DB_PATH` (default `~/.agentkeys/broker/audit.sqlite`). Schema:

```sql
CREATE TABLE mint_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    minted_at       INTEGER NOT NULL,        -- unix seconds
    requester_token TEXT NOT NULL,           -- bearer token (hashed; see §6.1)
    requester_wallet TEXT NOT NULL,          -- wallet the token resolved to
    requested_role  TEXT NOT NULL,           -- BROKER_DATA_ROLE_ARN at mint time
    session_duration_seconds INTEGER NOT NULL,
    sts_session_name TEXT NOT NULL,          -- value passed to AssumeRole; visible in CloudTrail
    outcome         TEXT NOT NULL,           -- "ok" | "auth_failed" | "sts_error"
    outcome_detail  TEXT                     -- nullable; error message on failure
);

CREATE INDEX idx_mint_log_minted_at ON mint_log(minted_at);
CREATE INDEX idx_mint_log_wallet    ON mint_log(requester_wallet);
```

Inspect:

```bash
sqlite3 ~/.agentkeys/broker/audit.sqlite \
  "SELECT minted_at, requester_wallet, outcome FROM mint_log ORDER BY id DESC LIMIT 20"
```

**(later)** Stage 8 will mirror this audit data on-chain via a `BlobWritten` extrinsic per [`stage8-wip.md`](./stage8-wip.md). Until then, the SQLite file is the only audit surface — back it up.

### 6.1 Why the bearer token is hashed in the audit log

Storing the raw bearer token in the audit DB would mean a read of the audit DB compromises every active session. The audit log records `sha256(token)` so a leaked audit DB cannot be replayed against the backend. The `requester_wallet` column is the join key for the human-meaningful "who minted this" question.

### 6.2 What anomalies look like

- Same `requester_wallet` minting at >10× normal rate → token compromised, possibly replay-attempted from elsewhere.
- `outcome="auth_failed"` clusters → someone is fishing for valid tokens.
- `outcome="sts_error"` clusters → the operator's IAM trust policy or daemon key is misconfigured.

## 7. Migrate from local to hosted **(later)**

When `broker.agentkeys.dev` (or your hosted equivalent) is live, the migration for app developers is one env var:

```diff
-export AGENTKEYS_BROKER_URL=http://broker.local:8091
+export AGENTKEYS_BROKER_URL=https://broker.litentry.org
```

Operator-side, the same binary runs. Configuration source changes from env vars to KMS-sealed config (interface design only in v0.1; full implementation is the Stage 7 phase 2 hosted-deploy work).

## 8. Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Broker `/readyz` returns 503 with `backend_unreachable` | `BROKER_BACKEND_URL` wrong, mock-server not running | Check the URL; restart mock-server |
| Broker `/readyz` returns 503 with `sts_error` | Daemon AWS key invalid, expired, or missing `sts:AssumeRole` permission | Verify with `aws sts get-caller-identity` using the same env vars |
| `POST /v1/mint-aws-creds` returns 401 | Bearer token expired or issued against a different backend | Caller re-runs `agentkeys init` against `BROKER_BACKEND_URL` |
| `POST /v1/mint-aws-creds` returns 502 with `sts_error` | IAM trust policy on `agentkeys-data-role` doesn't allow the daemon user | Check the role's trust policy in IAM |
| Audit DB grows unbounded | No retention policy in v0.1 | Run a periodic `DELETE FROM mint_log WHERE minted_at < ?` from cron, or `sqlite3 .. VACUUM` |

## 9. What's NOT in scope for v0.1

- TEE / enclave-backed broker. Plaintext on commodity hardware.
- KMS-sealed configuration source. Env vars only.
- Secret-manager integration as a config source (Vault, AWS Secrets Manager, GCP Secret Manager). Operator persists the daemon AWS keys in `~/.zshenv` (or supervisor-managed env) themselves.
- Multi-tenant operator support. One broker process serves one operator's `agentkeys-daemon` key.
- `sts:AssumeRoleWithWebIdentity` exchange against the broker's issuer. The broker now serves a conforming OIDC discovery + JWKS surface and a bearer-gated `mint-oidc-jwt` endpoint, but the AWS-side `create-open-id-connect-provider` registration requires the issuer URL to be reachable over public TLS — that hosting step is the remaining blocker (Stage 7 phase 2 federation step).
- Automatic key rotation. Rotate manually per §5.

## 10. Further reading

- [`dev-setup.md`](./dev-setup.md) — the three-role guide. Read §3 first if you're not sure which role you are.
- [`stage6-aws-setup.md`](./stage6-aws-setup.md) — one-time IAM + SES + S3 setup that produces the daemon key the broker holds.
- [`stage7-wip.md`](./stage7-wip.md) — full Stage 7 design, including the OIDC-federation half deferred to phase 2.
- [`spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md) — broader security position the broker is one component of.
