# Stage 7 — Generalized OIDC Provider

> **Status (2026-04-28).** Architecturally complete. The Rust broker owns the OIDC surface end-to-end (discovery + JWKS + bearer-gated `mint-oidc-jwt`); the provisioner-scripts AWS-cred path is wired through the broker; the audit destination is the broker's local SQLite per [`architecture.md` §11](spec/architecture.md#11-audit-destination-is-pluggable). The remaining work is operational: deploy the broker on a public hostname so AWS / GCP / Tencent IAM can fetch the JWKS during OIDC-provider registration. That deployment recipe is split between this doc (broker bring-up) and [`cloud-setup.md`](./cloud-setup.md) (cloud account provisioning).

## What Stage 7 delivers

A long-running broker that issues two kinds of short-lived credentials to authenticated daemons, so app-developer machines never hold long-lived AWS keys:

| Endpoint | Auth | Output | Used for |
|---|---|---|---|
| `POST /v1/mint-aws-creds`   | bearer | 1 h scoped AWS temp creds (via `sts:AssumeRole` on the operator's daemon key) | Direct cred path — operator-trusted, app-side isolation. |
| `POST /v1/mint-oidc-jwt`    | bearer | Short-lived ES256 JWT  | Federated path — `sts:AssumeRoleWithWebIdentity` → cloud-enforced PrincipalTag isolation. |
| `GET /.well-known/openid-configuration` | none | OIDC discovery doc | Consumed by `aws iam create-open-id-connect-provider` at registration time. |
| `GET /.well-known/jwks.json` | none | JWK Set with the broker's ES256 P-256 public key + `kid` | Same — AWS pulls the public key once, caches it. |

Both `mint-*` endpoints write a row to the broker's append-only SQLite audit DB before credentials leave the process. JWT mints land with `requested_role = "oidc_jwt"`; AWS-cred mints land with the assumed role ARN.

> **Scope boundary.** Stage 7 ships the **per-user isolation primitive** — JWT claim → PrincipalTag → resource-policy gate. It does **not** commit a position on where credential ciphertext lives; that's Stage 8 ([`stage8-wip.md`](./stage8-wip.md)).

## Code

| Crate | What it owns |
|---|---|
| [`crates/agentkeys-broker-server/`](../crates/agentkeys-broker-server/) | Axum HTTP service. ES256 keypair gen/persist (mode 0600), JWT signing, audit DB, STS client (trait-abstracted with a `test-stub` feature for offline tests). |
| [`crates/agentkeys-mock-server/`](../crates/agentkeys-mock-server/) | Backend stub. Issues session bearers via `POST /session/create`; the broker validates against `GET /session/validate`. In-memory SQLite — fine for dev, not a long-running production backend. |
| [`crates/agentkeys-cli/`](../crates/agentkeys-cli/) + [`crates/agentkeys-mcp/`](../crates/agentkeys-mcp/) + [`crates/agentkeys-daemon/`](../crates/agentkeys-daemon/) | `--broker-url` / `AGENTKEYS_BROKER_URL` everywhere; `provision` subcommands fetch AWS creds via the broker before spawning scrapers. |

## Configuration

The broker reads AWS credentials from the SDK default chain (instance profile → named profile → static keys, in that order). See [`operator-runbook.md` §2](./operator-runbook.md#2-aws-credentials) for the full credential story.

| Env var | Default | Notes |
|---|---|---|
| `BROKER_BACKEND_URL`        | (required) | URL of the session-management backend (mock-server in dev, chain in v0.2+). |
| `BROKER_DATA_ROLE_ARN`      | derived from `ACCOUNT_ID` | ARN of `agentkeys-data-role`. Legacy `BROKER_AGENT_ROLE_ARN` accepted for unmigrated deployments. |
| `BROKER_OIDC_ISSUER`        | `https://oidc.agentkeys.dev` | Public URL emitted as `iss`. **Must** match the URL registered with `aws iam create-open-id-connect-provider` byte-for-byte. |
| `BROKER_OIDC_KEYPAIR_PATH`  | `~/.agentkeys/broker/oidc-keypair.json` | ES256 keypair (mode 0600), generated on first start, reused thereafter so the registered IAM provider stays valid. |
| `BROKER_OIDC_JWT_TTL_SECONDS` | `300` | Bounded `[60, 3600]`. Short TTL limits replay window. |
| `BROKER_AUDIT_DB_PATH`      | `~/.agentkeys/broker/audit.sqlite` | Audit destination. |

## Audit destination is pluggable

Earlier docs describe audit + anchoring as a Heima-pallet operation. That's **one** instance of the architecture, not a constraint of it. The audit layer is a pluggable backend behind a single interface: append a tamper-evident record of *who did what, when, against which agent*. Per [`architecture.md` §11](spec/architecture.md#11-audit-destination-is-pluggable):

| Class | Examples |
|---|---|
| Federated public chain | Heima parachain, other Substrate parachains |
| General-purpose public chain | Ethereum, Solana, Sui, Cosmos |
| Permissioned / consortium chain | Hyperledger Fabric, Quorum, Aliyun BaaS (China) |
| Plain backend server | append-only SQLite (broker default), Postgres + immutable WAL, S3-with-Object-Lock |
| TEE-attested append-only log | Heima TEE + sealed storage, AWS Nitro + KMS, Azure Confidential Ledger |

Stage 7 ships in the "plain backend server" row. Migrating to a chain-anchored destination is a backend swap, not a redesign.

## Operator end-to-end test

A four-terminal walk-through that exercises everything Stage 7 ships, with no AWS round-trip required (`--skip-startup-check` lets the broker stand up offline). Run it once after a fresh build to confirm operator wiring.

### Prereqs

- Release build: `cargo build --release -p agentkeys-mock-server -p agentkeys-broker-server -p agentkeys-cli` (≈ 90 s cold).
- `jq` and `curl` on `$PATH`.
- For the AWS-cred path (step 4b): `awsp agentkeys-daemon` (or another profile with `sts:AssumeRole` on `agentkeys-data-role`) plus `ACCOUNT_ID` from your operator setup. Skip step 4b on the offline path.

### Walk-through

```bash
# Terminal A — backend (mock-server, in-memory SQLite)
./target/release/agentkeys-mock-server --port 8090
# expect: "Mock server running on port 8090"

# Terminal B — broker
export BROKER_BACKEND_URL=http://127.0.0.1:8090
export BROKER_OIDC_ISSUER=http://localhost:8091   # http for dev only; production is https
export ACCOUNT_ID=000000000000                    # offline path tolerates a stub
./target/release/agentkeys-broker-server --port 8091 --skip-startup-check
# expect: "AWS credentials: SDK default chain ..."
#         "OIDC signer ready" with kid=v1-<unix-secs>
#         "broker listening on 0.0.0.0:8091"

# Terminal C — checks
curl -sf http://127.0.0.1:8091/healthz                                                # → "ok"
curl -sf http://127.0.0.1:8091/.well-known/openid-configuration | jq .
curl -sf http://127.0.0.1:8091/.well-known/jwks.json | jq '.keys[0] | {kty, crv, alg, kid}'

# 1. Mint a session bearer against the backend.
#    `auth_token` is the developer-facing handle; the mock-server resolves
#    it to a wallet on first use. In production this comes from the chain.
SESSION=$(curl -sf -X POST http://127.0.0.1:8090/session/create \
  -H 'content-type: application/json' \
  -d '{"auth_token":"phase2-e2e"}' | jq -r .session)
echo "SESSION=$SESSION"

# 2a. Mint an OIDC JWT (decode the claims to verify shape)
JWT=$(curl -sf -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION" | jq -r .jwt)
echo "$JWT" | awk -F. '{print $2}' | base64 --decode 2>/dev/null | jq .
# expect: claims with iss, sub=agentkeys:agent:<wallet>, aud=sts.amazonaws.com,
#         agentkeys_user_wallet, iat, exp.

# 2b. AWS-creds mint (LIVE path — needs real daemon creds; skip offline)
CREDS=$(curl -sf -X POST http://127.0.0.1:8091/v1/mint-aws-creds \
  -H "Authorization: Bearer $SESSION")
printf '%s' "$CREDS" | jq '{access_key_id, expiration, wallet}'

# 3. Provisioner-scripts wiring (CLI side). With AGENTKEYS_BROKER_URL set,
#    `agentkeys provision` fetches AWS creds via the broker before spawning
#    the scraper subprocess.
export AGENTKEYS_BROKER_URL=http://127.0.0.1:8091
./target/release/agentkeys init --mock-token phase2-e2e
./target/release/agentkeys provision openrouter --help              # exercises broker fetch path

# 4. Audit log
sqlite3 ~/.agentkeys/broker/audit.sqlite \
  "SELECT outcome, requested_role, requester_wallet, occurred_at FROM mint_audit ORDER BY id DESC LIMIT 10;"
# expect: rows with requested_role IN ('arn:aws:iam::*:role/agentkeys-data-role', 'oidc_jwt')
```

### Acceptance

- `/healthz` and `/readyz` return `200`.
- `/.well-known/openid-configuration` `.issuer` matches `BROKER_OIDC_ISSUER` byte-for-byte.
- `/.well-known/jwks.json` returns a JWK Set with `alg=ES256`, `crv=P-256`, a stable `kid`.
- `mint-oidc-jwt` returns a JWT whose claims include `agentkeys_user_wallet`, `aud=sts.amazonaws.com`, future `exp`.
- The audit DB has one row per mint with `outcome=ok`.

### Negative checks

```bash
# Missing bearer → 401 + auth_failed audit row
curl -sf -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt

# Bogus bearer → 401 + auth_failed audit row
curl -sf -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt \
  -H 'Authorization: Bearer never-minted'

# Backend down (kill terminal A first) → 502 + backend_error audit row
curl -sf -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION"
```

The `backend_error` vs `auth_failed` distinction is what oncall chases — keep them disambiguated in the audit DB.

## Remote deployment

For the broker to be reachable by daemons on developer laptops / CI / cloud sandboxes — and for AWS to OIDC-federate against it — it needs a public HTTPS hostname. The split:

- **Cloud-account provisioning** (DNS, EIP, SES/S3, IAM, OIDC federation): [`cloud-setup.md`](./cloud-setup.md).
- **Broker-host bootstrap** (binaries, systemd, nginx, certbot): this section + [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh).

### Topology

```
┌── developer laptop / CI / cloud sandbox ──┐
│  agentkeys-daemon  (or `agentkeys` CLI)   │
│  --broker-url https://broker.litentry.org │
└───────────────────┬───────────────────────┘
                    │ HTTPS (bearer)
                    ▼
┌── operator-managed host ────────────────────────────────┐
│  reverse proxy (nginx + Let's Encrypt)                  │
│       :80 ACME challenge + 301 → :443                   │
│       :443 ssl + proxy_pass to broker                   │
│                    │                                    │
│                    ▼                                    │
│  agentkeys-broker-server  127.0.0.1:8091                │
│  (BROKER_BACKEND_URL=http://127.0.0.1:8090)             │
│                                                         │
│  agentkeys-mock-server (or Heima-backed successor)      │
│  127.0.0.1:8090                                         │
│                                                         │
│  /var/lib/agentkeys/.agentkeys/broker/audit.sqlite      │
│  /var/lib/agentkeys/.agentkeys/broker/oidc-keypair.json │
└─────────────────────────────────────────────────────────┘
```

The broker binds to `127.0.0.1:8091`. Only the local reverse proxy reaches it. **Never** bind the broker to `0.0.0.0` without TLS in front — bearer tokens and minted credentials would traverse the network in cleartext (the broker logs a warning on startup if you do).

### Backend caveats

`agentkeys-mock-server` keeps state in-memory:

- **State is lost on restart.** Sessions, identity links, audit rows vanish. Fine for dev; for a backend that other developers' daemons depend on, supervise it (systemd `Restart=on-failure`) and have developers re-`init` after restarts.
- **No HA.** Single process, single node.
- **No TLS at the listener.** Always co-locate behind the broker's loopback or front it with the same reverse proxy.

For a production-grade backend, hold the deployment until Heima session management lands — Stage 7 is not gated on this; the broker's interface is identical regardless of which backend implements `/session/{create,validate}`.

### Deployment

The fully manual long-form walk-through (host provisioning, build, systemd units, nginx, certbot) is bundled into [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh):

```bash
# On the host, as agentkey-broker (or any sudoer):
git clone https://github.com/litentry/agentKeys.git && cd agentKeys
sudo bash scripts/setup-broker-host.sh
# Interactive walk-through:
#   • prompts for issuer URL (must be https://, no trailing slash)
#   • prompts for credential mode (instance-profile / profile / static)
#   • writes systemd units + HTTP-only nginx config
#   • prints the certbot command to run next
# After certbot succeeds, re-run the script to flip on the :443 ssl block.
```

The script is idempotent. Re-run after any operator-side change (cred-mode swap, issuer-URL fix, cert renewal). What's still manual:

- **Cloud-side IAM, SES, S3, OIDC federation** → [`cloud-setup.md`](./cloud-setup.md).
- **DNS A record + EIP** → [`cloud-setup.md` §5](./cloud-setup.md#5-ec2-broker-host-optional).
- **Initial cert issuance** → `sudo certbot certonly --webroot -w /var/www/certbot -d <host>` (the `--nginx` plugin chickens-and-eggs on the empty cert path; webroot doesn't).

### Smoke test (after deployment)

From any machine with no AWS-shaped configuration:

```bash
# 1. Discovery + JWKS reachable
curl -sf https://broker.litentry.org/healthz                               # → "ok"
curl -sf https://broker.litentry.org/.well-known/openid-configuration | \
  jq -e '.issuer == "https://broker.litentry.org"'                          # → true
curl -sf https://broker.litentry.org/.well-known/jwks.json | jq '.keys[0].kid'

# 2. Mint a session bearer against the backend.
#    The backend is NOT public — SSH-tunnel to its loopback:
#      ssh -i ~/.ssh/agentkey-broker.pem -L 8090:127.0.0.1:8090 \
#          agentkey-broker@<broker-ec2-ip>
#    then in another terminal on your laptop:
SESSION=$(curl -sf -X POST http://127.0.0.1:8090/session/create \
  -H 'content-type: application/json' \
  -d '{"auth_token":"smoke"}' | jq -r .session)

# 3. End-to-end JWT mint
curl -sf -X POST https://broker.litentry.org/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION" | jq '.expiration'

# 4. End-to-end AWS-creds mint (skip if the broker is in offline mode)
curl -sf -X POST https://broker.litentry.org/v1/mint-aws-creds \
  -H "Authorization: Bearer $SESSION" | jq '{access_key_id, expiration, wallet}'
```

If `.issuer` doesn't match the URL byte-for-byte, fix `BROKER_OIDC_ISSUER` on the host before [§4](./cloud-setup.md#4-oidc-federation-stage-7) — AWS rejects mismatches at `AssumeRoleWithWebIdentity` time.

## Operations

- **Start, supervise, rotate, audit** → [`operator-runbook.md`](./operator-runbook.md).
- **Cloud-account provisioning + OIDC federation** → [`cloud-setup.md`](./cloud-setup.md).
- **Don't expose `:8091` ingress.** Host firewall must drop `:8091` from anywhere except `127.0.0.1`. Nginx is the only legitimate caller.
- **Cert renewal.** Certbot's renewal timer ships with the package (`sudo systemctl list-timers | grep certbot`). AWS doesn't pin the cert; thumbprint persistence comes from the LE intermediate CA.

## Operational follow-ups

- **GCP / Tencent federation recipes** — equivalent of [`cloud-setup.md` §4](./cloud-setup.md#4-oidc-federation-stage-7) for Workload Identity Federation and Tencent CAM. JWT/JWKS shape works cross-cloud unchanged; only the registration step differs.
- **TEE-derived signer** — replace [`crates/agentkeys-broker-server/src/oidc.rs::OidcKeypair::load_or_generate`](../crates/agentkeys-broker-server/src/oidc.rs) with a TEE oracle when [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md) closes. JWKS, JWT shape, STS exchange, and bucket-policy enforcement stay identical.
- **Audit-destination swap** — point the audit log at a chain or sealed log per the [pluggable framing](spec/architecture.md#11-audit-destination-is-pluggable). Configuration choice, not a redesign.
- **Stage 8 hand-off** — `s3://agentkeys-vault/<wallet>/` is the reuse point with [`stage8-wip.md`](./stage8-wip.md); ciphertext + per-epoch DEK rotation live there, not here.
