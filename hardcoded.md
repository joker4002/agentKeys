# Hardcoded values audit log

Per `CLAUDE.md` "No-hardcoded-values policy": every hardcoded value in
the codebase that hasn't been parameterized to env vars / CLI flags /
config files must be logged here, with the trade-off explanation +
the concrete change that would unblock making it dynamic.

The intent is **not** to eliminate every hardcoded value — some
(system user names, well-known file paths, RFC-defined constants) are
correctly hardcoded forever. The intent is to make every "I'll fix it
later" a deliberate decision instead of an oversight.

---

## Format

Each entry: file path + line, what's hardcoded, why, what would unblock
parameterization.

---

## Operator-deployment-pinned values (litentry-account-specific)

These pin the canonical demo/prod deployment to litentry's AWS account
+ DNS zones. Operators forking the project must edit these (or override
via env). Logged here so a fork-attempt operator finds the full list.

### `scripts/operator-workstation.env`

| Line | Value | Why hardcoded | Unblock |
|---|---|---|---|
| 25 | `ACCOUNT_ID=429071895007` | Default to litentry's AWS account so the runbook is copy-pasteable. | Operators forking already override by editing this file (it's the canonical override point). No further parameterization needed. |
| 28 | `REGION=us-east-1` | SES inbound is region-restricted to `us-east-1` / `us-west-2` / `eu-west-1` per AWS docs; defaulting to `us-east-1` matches `cloud-setup.md §0`. | Operator override by editing the env file. |
| 32 | `BROKER_HOST=broker.litentry.org` | Litentry's broker hostname. | Operator override by editing the env file. |
| 84 | `MAIL_DOMAIN=bots.litentry.org` | Litentry's email subdomain (verified per `cloud-setup.md §1.1`). | Operator override by editing the env file. |
| 97 | `BROKER_EMAIL_FROM_ADDRESS=noreply-test@${MAIL_DOMAIN}` | Default sender for the integration test + broker. Computed from `MAIL_DOMAIN` so a fork operator only edits one place. | Single point of truth — already correct. |

### `scripts/broker.env`

| Line | Value | Why hardcoded | Unblock |
|---|---|---|---|
| 35 | `ACCOUNT_ID=429071895007` | Litentry's AWS account ID. Single source of truth — derived ARNs (BROKER_DATA_ROLE_ARN below) reference `${ACCOUNT_ID}`. | Operator override by editing the env file. |
| 41 | `BROKER_DATA_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role` | Derived from `ACCOUNT_ID` via bash expansion at source-time. Role name fixed by cloud-setup.md §3.2. | OK — single source of truth via `ACCOUNT_ID`. |
| 47 | `BROKER_OIDC_ISSUER=https://broker.litentry.org` | Must match the broker's public hostname byte-for-byte (AWS validates JWT iss claim). | Operator override by editing the env file. |
| 71 | `BROKER_EMAIL_FROM_ADDRESS=noreply-test@bots.litentry.org` | Default SES sender. | Operator override by editing the env file. |

### `scripts/setup-broker-host.sh`

| Line | Value | Why hardcoded | Unblock |
|---|---|---|---|
| 67 | `REGION="us-east-1"` | Default if not passed via `--region` / unit-detected. Same rationale as operator-workstation.env line 28. | `--region` CLI flag already exists. OK. |
| 84 | `BROKER_EMAIL_FROM_ADDRESS="${BROKER_EMAIL_FROM_ADDRESS:-noreply-test@bots.litentry.org}"` | Default sender if not passed via `--email-from` / env. | `--email-from` CLI flag already exists. OK. |

---

## Deployment-architecture-pinned values

These are pinned for the canonical broker-host layout. Changing them
requires also changing the systemd units, nginx configs, and the
broker's expectations at startup.

### Loopback ports

| File | Line | Value | Why hardcoded | Unblock |
|---|---|---|---|---|
| `scripts/setup-broker-host.sh` | various | broker `:8091`, backend `:8090`, signer `:8092` | The 3-port split is the architectural separation between the public broker, the internal backend, and the dedicated signer (per `architecture.md` §10). Changing requires re-coordinated edits to systemd units, nginx server blocks, and the broker's `--port` flag. | Add `--broker-port` / `--backend-port` / `--signer-port` flags + env var alternates. Low-priority — the canonical layout is the only deployment shape. |

### System user + paths

| File | Line | Value | Why hardcoded | Unblock |
|---|---|---|---|---|
| `scripts/setup-broker-host.sh` | various | `agentkeys` system user / `agentkeys` group | The systemd units, file ownership, and ProtectSystem sandbox all reference this user. | Renaming would require an in-place migration (chown every file). Not worth parameterizing. |
| `scripts/setup-broker-host.sh` | 532 | `/etc/agentkeys/dev-key-service.env` | K3 master-secret env file path. The backend + signer systemd units `EnvironmentFile=` this exact path. | Could be made `--secret-env-path` flag. Low-priority — the canonical path is the only deployment shape. |
| `scripts/setup-broker-host.sh` | various | `/var/lib/agentkeys/.agentkeys/broker/session-keypair.pub.pem` | The broker writes here; the signer reads from here. Hard-coded into both. | Could be `--session-pubkey-path` flag. Low-priority. |

---

## Code-level constants

| File | Line | Value | Why hardcoded | Unblock |
|---|---|---|---|---|
| `crates/agentkeys-broker-server/src/plugins/auth/email_link.rs` | 46 | `TOKEN_TTL_SECONDS: i64 = 600` | Magic-link TTL (10 min) per Plan §3.5.3. | Could be `BROKER_EMAIL_TOKEN_TTL_SECONDS` env var. Reasonable to leave as constant unless an operator needs longer/shorter window. |
| `crates/agentkeys-broker-server/src/plugins/auth/email_link.rs` | various | per-email rate limit default 5/hr, per-IP default 30/min | Operational defaults. Already env-overridable via `BROKER_EMAIL_RATE_LIMIT_PER_EMAIL_HOURLY` + `BROKER_EMAIL_RATE_LIMIT_PER_IP_MINUTELY`. | Already parameterized. OK. |
| `crates/agentkeys-broker-server/tests/ses_email_flow.rs` | 36 | `DEFAULT_REGION: &str = "us-east-1"` | Test default if `AWS_REGION` env unset. | Already env-overridable. OK. |
| `crates/agentkeys-broker-server/tests/ses_email_flow.rs` | 37 | `DEFAULT_MAIL_DOMAIN: &str = "bots.litentry.org"` | Test default if `MAIL_DOMAIN` env unset. | Already env-overridable. OK. |
| `crates/agentkeys-broker-server/tests/ses_email_flow.rs` | 38 | `DEFAULT_FROM_LOCAL: &str = "noreply-test"` | Test default if `BROKER_EMAIL_FROM_ADDRESS` env unset. | Already env-overridable. OK. |
| `crates/agentkeys-broker-server/tests/ses_email_flow.rs` | 41 | `POLL_MAX_ATTEMPTS: usize = 12` (60s total) | Empirical SES → S3 inbound delivery latency budget. | Could be `SES_TEST_TIMEOUT_S` env var. Reasonable to leave as constant. |

---

## Open trade-offs (decision pending)

### Email-link HMAC removal (commit `b8481fe`)

`EmailLinkAuth` previously held a vestigial `hmac_key` field that was loaded + length-validated but never used cryptographically. Removed in `b8481fe` to align with `architecture.md §3` K-table (no HMAC key listed) and §5a.1.M Stage 1 (magic-link is stateful).

**Trade-off**: in a multi-broker-replica deployment with shared SQLite, stateless HMAC tokens become attractive again (avoids a DB round-trip per verify). v0.1 is single-broker so this doesn't apply, but v0.2+ with replica scaling should revisit.

**Unblock**: when scaling to multi-broker, reopen the HMAC discussion via a new K-key entry in `architecture.md §3` (K12?) + a fresh design doc.
