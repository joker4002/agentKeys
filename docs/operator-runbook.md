# Operator Runbook — AgentKeys Broker Server

**Audience:** the person running `agentkeys-broker-server` for a team. If you're an app developer trying to use a broker someone else runs, see [`dev-setup.md` §4](./dev-setup.md). If you're an end user of an agent, see [`dev-setup.md` §6](./dev-setup.md).

**Scope:** start, supervise, rotate keys, monitor audit, and migrate from local to hosted. v0.1 deliberately avoids TEE / KMS / hosted-only paths — those land later.

> **WIP / scratchpad.** This runbook ships alongside the v0.1 broker (Stage 7 vertical slice — `mint-aws-creds` + audit only). Sections marked **(later)** describe surface that lands in Stage 7 phase 2 (OIDC federation) or Stage 8 (off-chain vault). Treat them as forward-looking, not load-bearing for v0.1 operators.

## 1. What the broker is

`agentkeys-broker-server` is the long-running HTTP service that holds the operator's long-lived `agentkeys-daemon` AWS access key and brokers 1-hour scoped credentials to authenticated daemons. It is the boundary that lets app developers run daemons against your infrastructure **without holding any AWS credentials themselves**.

In v0.1 the broker exposes a single user-facing endpoint:

- `POST /v1/mint-aws-creds` — bearer-token in, temp AWS creds out.

Plus operator-side health checks (`/healthz`, `/readyz`) and an audit log written to local SQLite.

The OIDC discovery surface (`/.well-known/openid-configuration`, `/.well-known/jwks.json`, `POST /v1/mint-oidc-jwt`) and `sts:AssumeRoleWithWebIdentity` exchange land in Stage 7 phase 2, alongside the public-hosting prereq from [`stage7-wip.md`](./stage7-wip.md).

## 2. Threat model — what the broker is and isn't defending against

**Defends against:** developer laptops being lost, stolen, or compromised. Without the broker, every developer holds the same long-lived daemon AWS key — one compromise burns everyone. With the broker, only the broker process holds the long-lived key; developer machines hold only short-lived bearer tokens.

**Does NOT defend against:** broker process compromise. If an attacker gets RCE on the broker, they get the long-lived AWS key and can mint arbitrary scoped credentials. The v0.1 broker runs on commodity hardware in plaintext; TEE-backed hosting is the v0.2+ evolution. See [`spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md) for the broader position.

**Operator implications for v0.1:**

- Run the broker on a host you trust. Don't co-tenant with untrusted workloads.
- Rotate the daemon AWS key on a schedule (§5).
- Watch the audit log (§6) — anomalous mint patterns are your earliest signal.

## 3. Start the broker

### 3.1 Required configuration

The broker reads its configuration from environment variables only — no config file in v0.1.

| Variable | Required | Description |
|---|---|---|
| `BROKER_DAEMON_ACCESS_KEY_ID` | yes | Long-lived `agentkeys-daemon` IAM user access key |
| `BROKER_DAEMON_SECRET_ACCESS_KEY` | yes | Long-lived `agentkeys-daemon` IAM user secret |
| `BROKER_AGENT_ROLE_ARN` | yes | ARN of the `agentkeys-agent` role to assume on behalf of daemons |
| `BROKER_BACKEND_URL` | yes | URL of the AgentKeys backend that issues session tokens (mock-server in dev, chain in v0.2+) |
| `BROKER_AUDIT_DB_PATH` | no | SQLite path for the audit log. Default: `$HOME/.agentkeys/broker/audit.sqlite` |
| `BROKER_AWS_REGION` | no | AWS region for the STS call. Default: `us-east-1` |
| `BROKER_SESSION_DURATION_SECONDS` | no | TTL for minted credentials. Default: `3600` (1 h). Min: `900`, max: `43200` |

Pull `BROKER_DAEMON_*` from a real secret store. Recommended: 1Password CLI:

```bash
export BROKER_DAEMON_ACCESS_KEY_ID=$(op read 'op://AgentKeys/daemon/access-key-id')
export BROKER_DAEMON_SECRET_ACCESS_KEY=$(op read 'op://AgentKeys/daemon/secret-access-key')
```

Do **not** put these in your shell rc files. Load them once per session and let them expire from memory when the shell exits.

### 3.2 Run

```bash
cargo run --release -p agentkeys-broker-server -- --port 8091
# → broker listening on 0.0.0.0:8091
```

Or from the built binary:

```bash
./target/release/agentkeys-broker-server --port 8091
```

### 3.3 Verify it came up

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

Long-lived keys age out. Rotation procedure:

1. In IAM, **create** a second access key on the `agentkeys-daemon` user — both old and new keys are now valid.
2. Update your secret store (1Password) with the new key.
3. Restart the broker — it picks up the new `BROKER_DAEMON_*` from env.
4. Verify with `curl /readyz` — should return 200.
5. In IAM, **deactivate** (not delete) the old access key. Wait 24 h.
6. If nothing broke, delete the old key. If something broke, reactivate and roll back.

**Cadence recommendation:** rotate every 90 days minimum, immediately on any operator-laptop compromise.

## 6. Audit

Every credential mint is logged to `BROKER_AUDIT_DB_PATH` (default `~/.agentkeys/broker/audit.sqlite`). Schema:

```sql
CREATE TABLE mint_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    minted_at       INTEGER NOT NULL,        -- unix seconds
    requester_token TEXT NOT NULL,           -- bearer token (hashed; see §6.1)
    requester_wallet TEXT NOT NULL,          -- wallet the token resolved to
    requested_role  TEXT NOT NULL,           -- BROKER_AGENT_ROLE_ARN at mint time
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
+export AGENTKEYS_BROKER_URL=https://broker.example.dev
```

Operator-side, the same binary runs. Configuration source changes from env vars to KMS-sealed config (interface design only in v0.1; full implementation is the Stage 7 phase 2 hosted-deploy work).

## 8. Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Broker `/readyz` returns 503 with `backend_unreachable` | `BROKER_BACKEND_URL` wrong, mock-server not running | Check the URL; restart mock-server |
| Broker `/readyz` returns 503 with `sts_error` | Daemon AWS key invalid, expired, or missing `sts:AssumeRole` permission | Verify with `aws sts get-caller-identity` using the same env vars |
| `POST /v1/mint-aws-creds` returns 401 | Bearer token expired or issued against a different backend | Caller re-runs `agentkeys init` against `BROKER_BACKEND_URL` |
| `POST /v1/mint-aws-creds` returns 502 with `sts_error` | IAM trust policy on `agentkeys-agent` doesn't allow the daemon user | Check the role's trust policy in IAM |
| Audit DB grows unbounded | No retention policy in v0.1 | Run a periodic `DELETE FROM mint_log WHERE minted_at < ?` from cron, or `sqlite3 .. VACUUM` |

## 9. What's NOT in scope for v0.1

- TEE / enclave-backed broker. Plaintext on commodity hardware.
- KMS-sealed configuration source. Env vars only.
- 1Password CLI integration as a config source. Operator runs `op read` themselves before starting the broker.
- Multi-tenant operator support. One broker process serves one operator's `agentkeys-daemon` key.
- OIDC `assume-role-with-web-identity` exchange. Direct `assume-role` with the static IAM trust path. The OIDC half lands when public hosting is also in motion (Stage 7 phase 2).
- Automatic key rotation. Rotate manually per §5.

## 10. Further reading

- [`dev-setup.md`](./dev-setup.md) — the three-role guide. Read §3 first if you're not sure which role you are.
- [`stage6-aws-setup.md`](./stage6-aws-setup.md) — one-time IAM + SES + S3 setup that produces the daemon key the broker holds.
- [`stage7-wip.md`](./stage7-wip.md) — full Stage 7 design, including the OIDC-federation half deferred to phase 2.
- [`spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md) — broader security position the broker is one component of.
