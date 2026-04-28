# Operator runbook — AgentKeys broker

**Audience:** the person running `agentkeys-broker-server` for a team. App developers using a broker someone else runs read [`dev-setup.md` §4](./dev-setup.md). End users of an agent read [`dev-setup.md` §6](./dev-setup.md).

**What the broker is.** A long-running HTTP service that holds the operator's `agentkeys-daemon` AWS access key (or assumes a role via instance profile) and mints two kinds of short-lived credentials to authenticated daemons:

| Endpoint | Output |
|---|---|
| `POST /v1/mint-aws-creds` | 1 h scoped AWS temp creds via `sts:AssumeRole`. |
| `POST /v1/mint-oidc-jwt`  | Short-lived ES256 JWT for `sts:AssumeRoleWithWebIdentity`. |
| `GET  /.well-known/openid-configuration` | OIDC discovery doc. |
| `GET  /.well-known/jwks.json` | JWK Set with the broker's public key + `kid`. |
| `GET  /healthz`, `/readyz` | Supervisor probes. |

Both `mint-*` endpoints write a row to `~/.agentkeys/broker/audit.sqlite` before credentials leave the process.

**Threat model.** Defends against developer-laptop compromise (devs hold only short-lived bearers; the long-lived AWS key never leaves the broker host). Does **not** defend against broker-process compromise — that's the v0.2+ TEE story; see [`spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md).

For v0.1: run on a host you trust, rotate the daemon key on a schedule (§3), watch the audit log (§4).

---

## 1. Setup pointers

| Task | Where |
|---|---|
| AWS account provisioning (IAM, SES, S3, OIDC federation) | [`cloud-setup.md`](./cloud-setup.md) |
| Broker-host bootstrap (binaries, systemd, nginx, certbot) | [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh) + [`stage7-wip.md` §"Remote deployment"](./stage7-wip.md#remote-deployment) |
| Stage 7 design + acceptance test | [`stage7-wip.md`](./stage7-wip.md) |
| Three-role mental model (operator vs developer vs end-user) | [`dev-setup.md`](./dev-setup.md) |

---

## 2. AWS credentials

The broker resolves AWS credentials through the SDK default provider chain. Pick **one** path:

### 2.1 EC2 instance profile (recommended on AWS)

The host's instance profile (`agentkeys-broker-host`, see [`cloud-setup.md` §3.4](./cloud-setup.md#34-agentkeys-broker-host-instance-profile-optional-ec2-only)) carries `sts:AssumeRole` on `agentkeys-data-role`. The SDK pulls credentials from IMDS automatically — no env vars, no shared files, no rotation runbook. Verify with `aws sts get-caller-identity` from the host.

### 2.2 Named profile (non-EC2 hosts)

Drop the daemon user's keys into `~/.aws/credentials` for the system user the broker runs as. The systemd unit sets `AWS_PROFILE=agentkeys-daemon`:

```
~/.aws/credentials              # mode 0600
[agentkeys-daemon]
aws_access_key_id = AKIA...
aws_secret_access_key = ...

~/.aws/config                   # mode 0600
[profile agentkeys-daemon]
region = us-east-1
```

For local dev: `awsp agentkeys-daemon` (or `export AWS_PROFILE=agentkeys-daemon`) before `cargo run`.

### 2.3 Static keys in env (legacy)

Set `DAEMON_ACCESS_KEY_ID` *and* `DAEMON_SECRET_ACCESS_KEY` (both required together; setting only one is rejected at startup). Prefer 2.1 or 2.2.

The broker logs which path it picked at startup: `AWS credentials: SDK default chain ...` or `AWS credentials: static IAM-user keys ...`. Always check this in the first second of the log.

---

## 3. Configuration

| Env var | Required | Notes |
|---|---|---|
| `BROKER_BACKEND_URL` | yes | Backend that issues / validates session bearers (mock-server in dev, chain in v0.2+). |
| `BROKER_DATA_ROLE_ARN` | yes (or `ACCOUNT_ID`) | ARN of `agentkeys-data-role`. Falls back to `arn:aws:iam::$ACCOUNT_ID:role/agentkeys-data-role`. Legacy `BROKER_AGENT_ROLE_ARN` accepted for unmigrated deployments. |
| `BROKER_OIDC_ISSUER` | for production | Public URL emitted as `iss`. **Must** match the `aws iam create-open-id-connect-provider --url` value byte-for-byte. Default: `https://oidc.agentkeys.dev`. |
| `BROKER_AWS_REGION` | no | STS region. Falls back to `REGION`, then `us-east-1`. |
| `BROKER_AUDIT_DB_PATH` | no | Default: `$HOME/.agentkeys/broker/audit.sqlite`. |
| `BROKER_OIDC_KEYPAIR_PATH` | no | Default: `$HOME/.agentkeys/broker/oidc-keypair.json` (mode 0600). |
| `BROKER_OIDC_JWT_TTL_SECONDS` | no | Default `300`. Bounded `[60, 3600]`. |
| `BROKER_SESSION_DURATION_SECONDS` | no | TTL for AWS-cred mints. Default `3600`. Bounded `[900, 43200]`. |
| `BROKER_BACKEND_TIMEOUT_SECONDS` | no | HTTP timeout to backend. Default `10`. |
| `BROKER_SHUTDOWN_GRACE_SECONDS` | no | Graceful drain cap. Default `30`. |
| `DAEMON_ACCESS_KEY_ID` / `DAEMON_SECRET_ACCESS_KEY` | legacy | Static IAM keys (§2.3). Both required if used. |

---

## 4. Run + supervise

For production, use [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh) — writes systemd units for both the broker and mock backend, with `Restart=on-failure` and a dedicated `agentkeys` system user. Logs to journald (`journalctl -u agentkeys-broker -f`).

For local dev:

```bash
awsp agentkeys-daemon                                              # or attach instance profile
cargo run --release -p agentkeys-broker-server -- --port 8091
```

Verify it came up:

```bash
curl -sf http://127.0.0.1:8091/healthz       # → "ok"
curl -sf http://127.0.0.1:8091/readyz        # → 200 if backend + STS reachable, 503 otherwise
```

`/readyz` checks that `BROKER_BACKEND_URL` is reachable and that the broker's daemon credentials can call `sts:GetCallerIdentity`. Use this as your supervisor probe.

---

## 5. Rotate the daemon AWS key

| Path | Procedure |
|---|---|
| **Instance profile (§2.1)** | Automatic. IMDS-vended credentials refresh on AWS's schedule. No operator step. |
| **Named profile (§2.2)** | (1) IAM `create-access-key` for `agentkeys-daemon` — both keys now valid. (2) Update `~/.aws/credentials`. (3) `sudo systemctl restart agentkeys-broker`. (4) `curl /readyz` → 200. (5) IAM `update-access-key --status Inactive` on the old key. (6) Wait 24 h. (7) Delete old key (or reactivate + roll back). |
| **Static keys (§2.3)** | Same as named-profile but step 2 updates the `DAEMON_*` env vars in your supervisor config / `EnvironmentFile=`. |

**Cadence:** rotate every 90 days minimum; immediately on any operator-laptop compromise.

---

## 6. Audit

Schema (`~/.agentkeys/broker/audit.sqlite`):

```sql
CREATE TABLE mint_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    minted_at       INTEGER NOT NULL,         -- unix seconds
    requester_token TEXT NOT NULL,            -- sha256(bearer); never the raw token
    requester_wallet TEXT NOT NULL,
    requested_role  TEXT NOT NULL,            -- ARN, or "oidc_jwt" for JWT mints
    session_duration_seconds INTEGER NOT NULL,
    sts_session_name TEXT NOT NULL,           -- visible in CloudTrail
    outcome         TEXT NOT NULL,            -- "ok" | "auth_failed" | "sts_error" | "backend_error"
    outcome_detail  TEXT
);
```

Inspect:

```bash
sqlite3 ~/.agentkeys/broker/audit.sqlite \
  "SELECT minted_at, requester_wallet, requested_role, outcome \
     FROM mint_log ORDER BY id DESC LIMIT 20"
```

**Anomaly signals:**

- One `requester_wallet` minting at >10× the normal rate → token compromised.
- `outcome="auth_failed"` clusters → someone fishing for valid bearers.
- `outcome="sts_error"` clusters → IAM trust policy or daemon key misconfigured.

Bearer tokens are stored as `sha256(token)` so a leaked audit DB cannot be replayed against the backend; `requester_wallet` is the join key for "who minted this".

---

## 7. Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `/readyz` returns 503 with `backend_unreachable` | `BROKER_BACKEND_URL` wrong / mock-server down | Check the URL; restart the backend. |
| `/readyz` returns 503 with `sts_error` | Daemon key invalid, expired, or missing `sts:AssumeRole` permission | `aws sts get-caller-identity` with the same env / profile. |
| `mint-aws-creds` returns 401 | Bearer expired or issued against a different backend | Caller re-runs `agentkeys init` against `BROKER_BACKEND_URL`. |
| `mint-aws-creds` returns 502 with `sts_error` | Trust policy on `agentkeys-data-role` doesn't allow the daemon user | Check the role's trust policy; see [`cloud-setup.md` §3.2](./cloud-setup.md#32-agentkeys-data-role). |
| `mint-oidc-jwt` returns 502 / discovery doc `iss` ≠ requested URL | `BROKER_OIDC_ISSUER` mismatch | sed the systemd unit; see [`stage7-wip.md`](./stage7-wip.md). |
| AWS rejects `AssumeRoleWithWebIdentity` | `BROKER_OIDC_ISSUER` and `aws iam create-open-id-connect-provider --url` disagree byte-for-byte | Re-register the OIDC provider per [`cloud-setup.md` §4.2](./cloud-setup.md#42-register-the-oidc-provider). |
| Audit DB grows unbounded | No retention policy in v0.1 | Cron `DELETE FROM mint_log WHERE minted_at < ?` + `VACUUM`. |

---

## 8. Out of scope for v0.1

- TEE / enclave-backed broker. Plaintext on commodity hardware.
- KMS-sealed configuration. Env vars only.
- Vault / Secrets Manager / GCP Secret Manager integration. Operator persists the daemon key themselves.
- Multi-tenant broker. One process serves one operator's `agentkeys-daemon` key.
- Automatic key rotation. Rotate manually per §5.

---

## 9. Further reading

- [`cloud-setup.md`](./cloud-setup.md) — one-time AWS provisioning (DNS, SES, S3, IAM, OIDC federation).
- [`stage7-wip.md`](./stage7-wip.md) — Stage 7 design + acceptance test.
- [`dev-setup.md`](./dev-setup.md) — three-role guide for app developers and end users.
- [`spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md) — the broader security position the broker is one component of.
