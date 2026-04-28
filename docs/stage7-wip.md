# Stage 7 — WIP notes

> **Status (2026-04-27).** Phase 1 (broker server) shipped in PR [#60](https://github.com/litentry/agentKeys/pull/60). Phase 2 (OIDC issuer + provisioner-scripts AWS-cred wiring) ships in PR [#61](https://github.com/litentry/agentKeys/pull/61) and is **architecturally complete**: the Rust broker owns the OIDC surface end-to-end, the audit destination is the broker's local SQLite (one valid choice in the [pluggable audit-destination layer](spec/architecture.md#11-audit-destination-is-pluggable)), and the provisioner subprocess is wired through the broker for AWS-cred minting. What's left is operational deployment for cloud-side OIDC federation (public TLS, `aws iam create-open-id-connect-provider`) — out of scope for the architecture but relevant to the cloud-deployment runbook.

## What Stage 7 is

Two halves that compose into the canonical "broker, not proxy" architecture:

1. **Phase 1 — Broker server (shipped, PR #60).** A long-running HTTP service holds the operator's long-lived `agentkeys-daemon` AWS access key and brokers 1-hour scoped credentials to authenticated daemons. Lets app developers run daemons against operator infrastructure without ever touching AWS keys themselves.
2. **Phase 2 — OIDC issuer + AWS-cred wiring (shipped, PR #61).** The Rust broker now serves the conforming OIDC discovery + JWKS surface and a bearer-gated `POST /v1/mint-oidc-jwt` endpoint, replacing the standalone TS `services/oidc-stub/` package. Provisioner-scripts AWS-cred wiring is live: `agentkeys provision <service>` (CLI) and the `agentkeys.provision` MCP tool fetch 1-hour temp creds from the broker and inject them into the scraper subprocess env when `--broker-url` is set. The audit destination is the broker's append-only SQLite at `~/.agentkeys/broker/audit.sqlite` — see [§"Audit destination is pluggable" below](#audit-destination-is-pluggable) for why that's a complete v0.1 choice, not a placeholder.

Per [`docs/spec/plans/development-stages.md`](./spec/plans/development-stages.md), this is the "Generalized OIDC Provider" stage after Stage 6 (Federated Own Email).

> **Scope boundary (added 2026-04-26).** Stage 7 ships the per-user isolation primitive — JWT claim → PrincipalTag → resource-policy gate. **It does not commit a position on where credential ciphertext lives.** The previously-assumed `pallet-secrets-vault` (on-chain encrypted blob store) is superseded by [`stage8-wip.md`](./stage8-wip.md), which moves ciphertext off-chain into the same PrincipalTag-gated S3 prefixes. See [`docs/spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md) for the architectural rationale.

## Phase 1 — Broker server (shipped, PR #60)

The credential broker that lets app developers run daemons without holding any AWS keys. Static-IAM trust path; OIDC federation deferred to phase 2.

**Code:**

- [`crates/agentkeys-broker-server/`](../crates/agentkeys-broker-server/) — axum HTTP service.
  - `POST /v1/mint-aws-creds` — bearer-token in (validated via the backend's `/session/validate`), 1-hour scoped AWS creds out (`sts:assume-role` on the operator's daemon key).
  - `GET /healthz`, `GET /readyz` — operator supervisor probes; `readyz` checks backend reachability + `sts:GetCallerIdentity`.
  - SQLite audit log on every mint (sha256-hashed bearer tokens, wallet, outcome, sts session name) at `$HOME/.agentkeys/broker/audit.sqlite` by default.
  - Trait-abstracted `StsClient` with `AwsStsClient` (production) and `StubStsClient` (gated by `test-stub` feature) — testable without live AWS.
- [`crates/agentkeys-mock-server/`](../crates/agentkeys-mock-server/) gains `GET /session/validate` so the broker validates bearer tokens through the existing session backend rather than duplicating session state.
- [`crates/agentkeys-daemon/`](../crates/agentkeys-daemon/) gains `--broker-url` / `AGENTKEYS_BROKER_URL` flag (consumer wiring of temp creds into provisioner-scripts lands in phase 2).

**Operator setup + test:** see [`docs/operator-runbook.md`](./operator-runbook.md) for start / supervise / rotate / audit, and [`docs/dev-setup.md` §5](./dev-setup.md) for the three-terminal solo-dev loop.

**End-to-end proof for phase 1** (run from inside the workspace):

```bash
# Terminal A — mock backend
cargo run --release -p agentkeys-mock-server -- --port 8090

# Terminal B — broker. AWS credentials come from the operator's
# ~/.aws/credentials profile (e.g. agentkeys-daemon) via `awsp` or
# AWS_PROFILE. ACCOUNT_ID + REGION live in the operator's shell. The
# broker derives BROKER_AGENT_ROLE_ARN from ACCOUNT_ID.
awsp agentkeys-daemon
export BROKER_BACKEND_URL=http://127.0.0.1:8090
cargo run --release -p agentkeys-broker-server -- --port 8091

# Terminal C — proof: mint a session, then mint AWS creds via the broker
SESSION=$(curl -sf -X POST http://127.0.0.1:8090/session/create \
  -H 'content-type: application/json' \
  -d '{"auth_token":"phase1-demo"}' | jq -r .session)

CREDS=$(curl -sf -X POST http://127.0.0.1:8091/v1/mint-aws-creds \
  -H "Authorization: Bearer $SESSION")
echo "$CREDS" | jq '{access_key_id, expiration, wallet}'
# → real 1h temp creds, scoped to the assumed agentkeys-agent role
```

Acceptance: `curl /healthz` → 200, `curl /readyz` → 200, `mint-aws-creds` returns creds, audit row appears in `~/.agentkeys/broker/audit.sqlite`.

**Out of phase 1 (now landing in phase 2):**

- Rust-broker OIDC discovery / JWKS / `mint-oidc-jwt` (delivered — see §"Phase 2 — OIDC issuer (Rust broker)" below).
- TS `services/oidc-stub/` retirement (directory deleted in this PR; OIDC surface now lives entirely in the Rust broker).
- Provisioner-scripts AWS-cred consumer rewiring (delivered — `agentkeys provision` and `agentkeys.provision` MCP tool now mint creds via the broker when `--broker-url` is set).

**Operational follow-ups (not architectural blockers):**

- `aws iam create-open-id-connect-provider` against a public TLS endpoint + `sts:AssumeRoleWithWebIdentity` exchange. The recipe is in §["Cloud federation deployment"](#cloud-federation-deployment) below. This is a deployment task, not a Stage-7 design task — the broker already serves the conforming OIDC surface; what's missing is just routing public TLS traffic to it.
- TEE-derived signer (a *higher-assurance* swap of the on-disk ES256 keypair). The on-disk keypair shipped today is a complete v0.1 signer per the [pluggable audit destination](spec/architecture.md#11-audit-destination-is-pluggable) framing; TEE is the v0.2+ hardening path, not a Stage-7 prerequisite.
- Chain-anchored audit (Heima or otherwise). Phase 2 ships with the broker's local SQLite as the audit destination — also a complete v0.1 choice. Operators who want chain anchoring can swap the audit backend without touching the OIDC issuer code.

## Phase 2 — OIDC issuer (Rust broker)

The Rust broker exposes three new endpoints. They are the same endpoints the TS oidc-stub used to serve; the schemas, JWT shape, JWKS shape, and bucket-policy enforcement are byte-for-byte compatible so federation recipes already written against the stub keep working unchanged.

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/.well-known/openid-configuration` | none | Discovery doc the AWS IAM `create-open-id-connect-provider` step reads. |
| `GET` | `/.well-known/jwks.json` | none | JWK Set with the broker's ES256 P-256 public key + `kid`. |
| `POST` | `/v1/mint-oidc-jwt` | bearer | Validates the bearer against the backend's `/session/validate`, then mints a short-lived ES256 JWT carrying `sub=agentkeys:agent:<wallet>`, `aud=sts.amazonaws.com`, `agentkeys_user_wallet=<wallet>`. |

### Configuration

| Env var | Default | Notes |
|---|---|---|
| `BROKER_OIDC_ISSUER` | `https://oidc.agentkeys.dev` | The exact string emitted as `iss` and as the discovery `issuer`. AWS requires this to match the URL `create-open-id-connect-provider --url` was registered with. |
| `BROKER_OIDC_KEYPAIR_PATH` | `~/.agentkeys/broker/oidc-keypair.json` | On first start the broker generates a P-256 keypair and persists it mode 0600. Subsequent restarts reuse the same `kid` so the registered IAM OIDC provider stays valid. |
| `BROKER_OIDC_JWT_TTL_SECONDS` | `300` | Bounded `[60, 3600]`. STS only checks the JWT at the moment of exchange; short TTL limits replay risk if the broker leaks a JWT. |

### Audit log

Both `mint-aws-creds` and `mint-oidc-jwt` write to the same SQLite audit table at `~/.agentkeys/broker/audit.sqlite`. JWT mints land with `requested_role = "oidc_jwt"` and `sts_session_name = <kid>` — operators see one ledger for both credential types.

<a id="audit-destination-is-pluggable"></a>
#### Why local SQLite is a complete v0.1 audit destination

Earlier docs ([`threat-model-key-custody.md`](spec/threat-model-key-custody.md), `wiki/blockchain-tee-architecture.md`) describe audit + anchoring as Heima-pallet operations. That description is **one instance** of the architecture, not a constraint of it. The audit/anchoring layer is a pluggable backend behind a single interface: append a tamper-evident record of *who did what, when, against which agent*.

Per [`architecture.md` §11](spec/architecture.md#11-audit-destination-is-pluggable), the trait surface accommodates:

- **Federated public chain** — Heima parachain, other Substrate parachains.
- **General-purpose public chain** — Ethereum, Solana, Sui, Cosmos.
- **Permissioned / consortium chain** — Hyperledger Fabric, Quorum, Aliyun BaaS (relevant for jurisdictions like China where public-chain anchoring is non-starter).
- **Plain backend server** — append-only SQLite (what the broker ships today), Postgres + immutable WAL, S3-with-Object-Lock, sealed log services.
- **TEE-attested append-only log** — Heima TEE + sealed storage, AWS Nitro + KMS, Azure Confidential Ledger.

The Stage 7 broker ships in the "plain backend server" row. SQLite at `~/.agentkeys/broker/audit.sqlite` is append-only by virtue of the application code (only `INSERT`s, never `UPDATE`/`DELETE`), keys are sha256-hashed before write, and the audit-write happens *before* credentials leave the broker — that's the property operators need. Migrating to a chain-anchored destination is a backend swap, not a Stage-7 redesign.

This is what makes Phase 2 architecturally complete today: the OIDC issuer + audit pair is one self-contained unit; the audit's storage backend is a deployment-time choice.

### Provisioner-scripts AWS-cred wiring

Operators no longer have to source `scripts/stage6-demo-env.sh`. With `--broker-url` set on the daemon, MCP, or CLI:

1. Before spawning the scraper subprocess, the provisioner calls `POST /v1/mint-aws-creds` with its session bearer.
2. The broker validates the bearer, runs `sts:AssumeRole` on the operator's daemon key, and returns 1-hour scoped creds.
3. The provisioner injects `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` (plus `AWS_REGION`/`AWS_DEFAULT_REGION` if set) into the subprocess env.
4. The scraper's existing SES → S3 email path works unchanged.

The legacy `stage6-demo-env.sh` flow still works when `--broker-url` is unset; the wiring is purely additive.

## Operator end-to-end test (Phase 2)

A four-terminal walk-through that exercises everything Phase 2 ships, with no AWS round-trip required (the broker's `--skip-startup-check` lets you stand it up offline). Run it once after a fresh build to confirm your operator setup is wired correctly. Times below are wall-clock expectations on a recent laptop.

### Prereqs

- A release build: `cargo build --release -p agentkeys-mock-server -p agentkeys-broker-server -p agentkeys-cli` (≈ 90 s cold).
- `jq` and `curl` on `$PATH`.
- For the AWS-side check (step 4b + 6), `awsp agentkeys-daemon` (or another profile with `sts:AssumeRole` on `agentkeys-agent`) plus `ACCOUNT_ID` from your operator setup. For offline-only, skip those steps and use `--skip-startup-check`.

### Walk-through

```bash
# Terminal A — backend (mock-server, in-memory SQLite)
./target/release/agentkeys-mock-server --port 8090
# expect: "Mock server running on port 8090"
# CAVEAT: this server keeps state in-memory — it works for the E2E test
# but is NOT a long-running production backend. See the "Remote
# deployment" section below for the production backend story.

# Terminal B — broker. Two ways to pass AWS credentials:
#   • Offline path (no AWS round-trip):   --skip-startup-check, no creds needed.
#   • Live path:                          awsp agentkeys-daemon  (SDK default chain)
# See docs/operator-runbook.md §3.1 for the full credential story.
export BROKER_BACKEND_URL=http://127.0.0.1:8090
export BROKER_OIDC_ISSUER=http://localhost:8091   # http for dev only; production must be https
export ACCOUNT_ID=000000000000                    # offline path tolerates a stub
./target/release/agentkeys-broker-server --port 8091 --skip-startup-check
# expect: "AWS credentials: SDK default chain (AWS_PROFILE / ~/.aws / IMDS)"
#         "OIDC signer ready" with kid=v1-<unix-secs>
#         "broker listening on 0.0.0.0:8091"

# Terminal C — checks
# 1. Healthz
curl -sf http://127.0.0.1:8091/healthz   # → "ok"
# 2. Discovery doc (the surface AWS would consume after registration)
curl -sf http://127.0.0.1:8091/.well-known/openid-configuration | jq .
# 3. JWKS (the public-key Set the issuer publishes)
curl -sf http://127.0.0.1:8091/.well-known/jwks.json | jq '.keys[0] | {kty, crv, alg, kid}'

# 4. Mint a session against the backend, then mint an OIDC JWT and an
#    AWS-creds response from the broker.
SESSION=$(curl -sf -X POST http://127.0.0.1:8090/session/create \
  -H 'content-type: application/json' \
  -d '{"auth_token":"phase2-e2e"}' | jq -r .session)

# 4a. JWT mint
JWT=$(curl -sf -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION" | jq -r .jwt)
echo "$JWT" | awk -F. '{print $2}' | base64 --decode 2>/dev/null | jq .
# expect: claims with iss, sub=agentkeys:agent:<wallet>, aud=sts.amazonaws.com,
# agentkeys_user_wallet, iat, exp.

# 4b. AWS-creds mint (requires real AWS daemon creds; skip on the
# offline path).
CREDS=$(curl -sf -X POST http://127.0.0.1:8091/v1/mint-aws-creds \
  -H "Authorization: Bearer $SESSION")
echo "$CREDS" | jq '{access_key_id, expiration, wallet}'

# 5. Provisioner-scripts wiring (CLI side). With AGENTKEYS_BROKER_URL
# set, `agentkeys provision` fetches AWS creds via the broker before
# spawning the scraper subprocess — no stage6-demo-env.sh sourcing.
export AGENTKEYS_BROKER_URL=http://127.0.0.1:8091
./target/release/agentkeys init --mock-token phase2-e2e        # session in OS keyring
./target/release/agentkeys provision openrouter --force        # full live signup; takes minutes
# alternatively: confirm just the broker hop without doing the live signup
./target/release/agentkeys --broker-url http://127.0.0.1:8091 \
  provision openrouter --help                                  # should not error on the env-fetch path

# 6. Audit log inspection
sqlite3 ~/.agentkeys/broker/audit.sqlite \
  "SELECT outcome, requested_role, requester_wallet, occurred_at FROM mint_audit ORDER BY id DESC LIMIT 10;"
# expect: a row per mint, with requested_role IN ('arn:aws:iam::*:role/agentkeys-agent', 'oidc_jwt')
```

### Acceptance

- `/healthz` and `/readyz` both return `200`.
- `/.well-known/openid-configuration` returns a body where `issuer` matches `BROKER_OIDC_ISSUER`.
- `/.well-known/jwks.json` returns a JWK Set with `alg=ES256`, `crv=P-256`, a stable `kid`.
- `mint-oidc-jwt` returns a JWT whose claims (decoded) include `agentkeys_user_wallet` matching the session's wallet, `aud=sts.amazonaws.com`, and a future `exp`.
- The audit DB has a fresh row per mint with `outcome=ok` (or `auth_failed` for the negative checks below).

### Negative checks (verify the failure modes)

```bash
# Missing bearer → 401
curl -sf -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt
# expect: 401, with one auth_failed row in the audit DB.

# Bogus bearer → 401
curl -sf -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt \
  -H 'Authorization: Bearer never-minted'
# expect: 401 + auth_failed audit row.

# Backend down (kill terminal A first) → 502
curl -sf -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION"
# expect: 502, with a backend_error audit row (NOT auth_failed — the
# distinction is what an oncall operator chases when triaging).
```

If any of these don't match, capture the broker's stderr (Terminal B) and the audit row, then file an issue — the broker exposes one ledger so triage shouldn't require log digging.

## Remote deployment

This section is for operators who want their broker reachable by daemons running on developer laptops, CI, or cloud sandboxes — and who eventually want AWS / GCP / etc. to OIDC-federate against it. Phase 2 architecture is complete on a single host (see the operator E2E above); these instructions take that single-host setup and put it on real infrastructure.

### Topology

```
┌── developer laptop / CI / cloud sandbox ──┐
│  agentkeys-daemon  (or `agentkeys` CLI)   │
│  --broker-url https://broker.example.dev  │
└───────────────────┬───────────────────────┘
                    │ HTTPS (bearer)
                    ▼
┌── operator-managed host(s) ─────────────────────────────┐
│                                                          │
│  reverse proxy (TLS terminator)                          │
│       nginx + Let's Encrypt / AWS ALB + ACM /            │
│       Caddy / CloudFront in front of broker              │
│                    │                                     │
│                    ▼                                     │
│  agentkeys-broker-server  :8091     ──────────┐          │
│  (BROKER_BACKEND_URL=http://backend:8090)     │          │
│                                                │          │
│  agentkeys-mock-server (or Heima-backed       │ HTTP     │
│  successor) :8090                  ◄──────────┘          │
│                                                          │
│  ~/.agentkeys/broker/audit.sqlite                        │
│  ~/.agentkeys/broker/oidc-keypair.json (mode 0600)       │
└──────────────────────────────────────────────────────────┘
```

The two server processes are deployed together. The mock backend (or its production successor) is **not** exposed publicly — only the broker is. The broker reaches the backend over the operator's private network.

### Backend server: production caveats

`agentkeys-mock-server` exists for v0 operators who don't yet have Heima integration. It's deliberately simple — Axum + **in-memory** SQLite — which means:

- **State is lost on restart.** Every running session, identity link, and audit row vanishes when the process exits. For development this is fine; for a backend that other developers' daemons depend on, it's not.
- **No HA.** Single-process, single-node.
- **No TLS at the listener.** Always front it with a reverse proxy (or co-locate with the broker on the same private network and don't expose it externally).

For v0.1 operators, two pragmatic options:

1. **Single-host deployment with persistent state (recommended for self-hosted teams).** Keep the mock-server but add a small wrapper: front it with `systemd` (or Docker `restart: unless-stopped`), and mount the SQLite file on persistent storage — `docs/operator-runbook.md` will track the exact patches needed in the next iteration. Until that lands, treat session loss on restart as part of the operator runbook (have developers re-`init` after a backend restart).
2. **Skip the mock and wait for Heima.** If your timeline allows, hold this deployment until the chain-backed backend lands and use the real Heima session-management path. Stage 7 phase 2 isn't gated on this — the broker's interface is the same regardless of which backend implements `/session/create` + `/session/validate`.

### Step 1 — Provision the host

Pick whatever fits your stack. Two examples that satisfy the requirements (TLS-terminating reverse proxy + ≥ 1 vCPU / 1 GiB RAM + persistent disk):

- **AWS:** `t4g.small` EC2 + Elastic IP + Route 53 A record + ALB with ACM cert. Or skip the ALB and run nginx directly on the instance.
- **DigitalOcean / Hetzner / Linode:** any 1 GiB droplet + a managed DNS A record + nginx + Let's Encrypt via certbot.

Either way you need:

- A DNS name resolving to the host (e.g. `broker.example.dev`).
- A public-CA TLS certificate covering that name (Let's Encrypt is free; ACM is free for ALB use).
- Firewall: inbound `:443` from anywhere, inbound `:22` from your admin IP, **everything else closed**. The broker's `:8091` and the backend's `:8090` are reached only via localhost or the private network.

### Step 2 — Install the binaries

The repo doesn't yet ship a `cargo dist` release; build from source on the target arch and copy the resulting binaries:

```bash
git clone https://github.com/litentry/agentKeys.git
cd agentKeys
cargo build --release \
  -p agentkeys-mock-server \
  -p agentkeys-broker-server

sudo install -m 0755 \
  target/release/agentkeys-mock-server \
  target/release/agentkeys-broker-server \
  /usr/local/bin/
```

### Step 3 — AWS credentials + non-secret config

The broker resolves AWS credentials through the SDK default chain. Pick one of three paths, in order of preference:

#### 3a. EC2 instance profile (recommended on AWS)

If the broker host is an EC2 instance, attach an IAM **instance profile** with `sts:AssumeRole` permission on `agentkeys-agent`. The SDK pulls credentials from IMDS automatically — **no secrets land on the host's filesystem, no env vars, no rotation runbook**.

```bash
# One-time, from your admin workstation:
ROLE_NAME=agentkeys-broker-host
INSTANCE_PROFILE=$ROLE_NAME

# Trust policy: only this EC2 role may assume.
aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document "$(jq -n '{
  Version: "2012-10-17",
  Statement: [{Effect:"Allow", Principal:{Service:"ec2.amazonaws.com"}, Action:"sts:AssumeRole"}]
}')"

# Inline policy: the only thing the broker host can do is sts:AssumeRole on agentkeys-agent.
aws iam put-role-policy --role-name $ROLE_NAME --policy-name BrokerAssumeAgent \
  --policy-document "$(jq -n --arg account "$ACCOUNT_ID" '{
    Version: "2012-10-17",
    Statement: [{Effect:"Allow", Action:"sts:AssumeRole",
                 Resource:"arn:aws:iam::\($account):role/agentkeys-agent"}]
  }')"

aws iam create-instance-profile --instance-profile-name $INSTANCE_PROFILE
aws iam add-role-to-instance-profile --instance-profile-name $INSTANCE_PROFILE --role-name $ROLE_NAME
aws ec2 associate-iam-instance-profile \
  --instance-id <broker-host-instance-id> \
  --iam-instance-profile Name=$INSTANCE_PROFILE
```

Verify from the host: `aws sts get-caller-identity` should print the assumed role ARN.

#### 3b. Named profile in `~/.aws/credentials` (non-EC2 hosts)

Hosts outside AWS (DigitalOcean, Hetzner, etc.) can't use IMDS. Drop the operator user's profile into `~/.aws/credentials` for the `agentkeys` system user:

```bash
sudo install -d -m 0700 -o agentkeys -g agentkeys /var/lib/agentkeys/.aws
sudo -u agentkeys tee /var/lib/agentkeys/.aws/credentials >/dev/null <<'EOF'
[agentkeys-daemon]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
EOF
sudo chmod 600 /var/lib/agentkeys/.aws/credentials

sudo -u agentkeys tee /var/lib/agentkeys/.aws/config >/dev/null <<'EOF'
[profile agentkeys-daemon]
region = us-east-1
EOF
sudo chmod 600 /var/lib/agentkeys/.aws/config
```

The systemd unit below sets `Environment=HOME=/var/lib/agentkeys` so the SDK finds these files; the unit also sets `AWS_PROFILE=agentkeys-daemon` so it picks the right profile.

#### 3c. Legacy static-keys env file (only if 3a/3b are not options)

```bash
sudo install -d -m 0700 /etc/agentkeys
sudo tee /etc/agentkeys/broker.env >/dev/null <<'EOF'
DAEMON_ACCESS_KEY_ID=AKIA...
DAEMON_SECRET_ACCESS_KEY=...
EOF
sudo chmod 600 /etc/agentkeys/broker.env
```

Only the systemd unit's `EnvironmentFile=` references this; nothing else on the host should read it.

#### Non-secret config (all three paths)

These values are not secrets and live in the systemd unit directly (Step 4):

```
ACCOUNT_ID=429071895007
REGION=us-east-1
BROKER_BACKEND_URL=http://127.0.0.1:8090
BROKER_OIDC_ISSUER=https://broker.example.dev
```

`BROKER_OIDC_ISSUER` **must** match the public URL the reverse proxy serves — AWS rejects `create-open-id-connect-provider` if the registered URL doesn't equal the `iss` claim emitted by the broker.

### Step 4 — systemd units

```ini
# /etc/systemd/system/agentkeys-backend.service
[Unit]
Description=AgentKeys mock backend (session management)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/agentkeys-mock-server --port 8090
Restart=on-failure
RestartSec=5s
User=agentkeys
Group=agentkeys
# Listens on all interfaces; only the local broker should reach it.
# Use a host firewall (ufw / nftables) to drop :8090 from anywhere
# but 127.0.0.1 + the broker's IP.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/agentkeys-broker.service
[Unit]
Description=AgentKeys broker (Stage 7)
After=network-online.target agentkeys-backend.service
Wants=network-online.target
Requires=agentkeys-backend.service

[Service]
Type=simple
# Non-secret config goes inline; AWS credentials come from the SDK's
# default chain (IMDS for 3a, ~/.aws/* for 3b, EnvironmentFile for 3c).
Environment=HOME=/var/lib/agentkeys
Environment=ACCOUNT_ID=429071895007
Environment=REGION=us-east-1
Environment=BROKER_BACKEND_URL=http://127.0.0.1:8090
Environment=BROKER_OIDC_ISSUER=https://broker.example.dev
# Uncomment ONE of the next two lines depending on the credential path:
#   3a (EC2 instance profile): nothing — IMDS handles it.
#   3b (named profile):
#Environment=AWS_PROFILE=agentkeys-daemon
#   3c (legacy static keys):
#EnvironmentFile=/etc/agentkeys/broker.env
ExecStart=/usr/local/bin/agentkeys-broker-server --port 8091 --bind 127.0.0.1
Restart=on-failure
RestartSec=5s
User=agentkeys
Group=agentkeys
# Persist audit + keypair (and ~/.aws if 3b) under /var/lib/agentkeys —
# operator must pre-create this dir mode 0700, owned by the agentkeys user.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/agentkeys
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd --system --home /var/lib/agentkeys --shell /usr/sbin/nologin agentkeys
sudo install -d -m 0700 -o agentkeys -g agentkeys /var/lib/agentkeys
sudo systemctl daemon-reload
sudo systemctl enable --now agentkeys-backend agentkeys-broker
sudo systemctl status agentkeys-backend agentkeys-broker
```

The broker binds to `127.0.0.1:8091` so only the local reverse proxy can reach it. **Never** bind the broker to `0.0.0.0` without TLS — bearer tokens and minted credentials would traverse the network in cleartext (the broker logs a warning on startup if you do, see [`crates/agentkeys-broker-server/src/main.rs::warn_if_non_loopback_without_tls`](../crates/agentkeys-broker-server/src/main.rs)).

### Step 5 — Reverse proxy + TLS

Minimal nginx site for `broker.example.dev`:

```nginx
# /etc/nginx/sites-available/agentkeys-broker
server {
    listen 80;
    server_name broker.example.dev;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name broker.example.dev;

    ssl_certificate     /etc/letsencrypt/live/broker.example.dev/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/broker.example.dev/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # AWS IAM only fetches the well-known + JWKS during create-open-id-connect-provider;
    # the rest of the broker is bearer-gated. Keep the proxy thin: no auth,
    # no caching of /v1/*, just TLS termination.
    location / {
        proxy_pass http://127.0.0.1:8091;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For   $remote_addr;
        proxy_read_timeout 30s;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/agentkeys-broker /etc/nginx/sites-enabled/
sudo certbot --nginx -d broker.example.dev --agree-tos -m ops@example.dev
sudo nginx -t && sudo systemctl reload nginx
```

### Step 6 — Smoke test from a client machine

From a laptop that has nothing AWS-shaped configured:

```bash
curl -sf https://broker.example.dev/healthz                            # → "ok"
curl -sf https://broker.example.dev/.well-known/openid-configuration | \
  jq '.issuer == "https://broker.example.dev"'                          # → true
curl -sf https://broker.example.dev/.well-known/jwks.json | jq '.keys[0].kid'

# End-to-end JWT mint (use a session bearer the operator has provisioned)
SESSION=<bearer-from-the-backend>
curl -sf -X POST https://broker.example.dev/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION" | jq '.expiration'
```

If the discovery `issuer` field doesn't equal the URL you're hitting, your `BROKER_OIDC_ISSUER` env var disagrees with the reverse-proxy `server_name` — fix this before running the AWS federation step or `create-open-id-connect-provider` will reject every JWT.

### Step 7 — Wire AWS federation

Once the smoke test above passes, follow [§"Cloud federation deployment"](#cloud-federation-deployment) below to register the OIDC provider with AWS IAM and verify the cloud-enforced isolation property.

### Operations: rotate, observe, harden

- **Rotate the daemon AWS key.** See [`operator-runbook.md` §5](./operator-runbook.md). The broker picks up the new key on the next `systemctl restart agentkeys-broker`; in-flight requests drain per `BROKER_SHUTDOWN_GRACE_SECONDS`.
- **Watch the audit log.** `sqlite3 /var/lib/agentkeys/.agentkeys/broker/audit.sqlite` per [`operator-runbook.md` §6](./operator-runbook.md). Anomalous mint spikes or `auth_failed` clusters are your earliest signal.
- **Watch the Let's Encrypt cert.** Certbot's renewal timer ships with the package; verify with `sudo systemctl list-timers | grep certbot`. AWS doesn't pin the cert, but `aws iam create-open-id-connect-provider` does record a thumbprint at registration time — if you swap the issuer to a different CA later, AWS will need the thumbprint refreshed.
- **Don't enable broker `:8091` ingress.** The host firewall must drop `:8091` from anywhere except `127.0.0.1`. The reverse proxy is the only legitimate caller.

## Cloud federation deployment

This section is the **operational runbook** for taking the (already-shipped) Phase 2 broker and making AWS (or GCP / Ali Cloud) trust its JWTs without operator-side IAM-user keys. It's not a Stage-7 architecture step — Phase 2 ships complete with the local SQLite audit destination above. Each cloud provider's IAM service has its own registration step, and that step needs the broker reachable over public TLS. That's what this section walks through.

### What's actually needed

- The broker (or a `/.well-known/*` reverse proxy in front of it) reachable at `$BROKER_OIDC_ISSUER` over public TLS, so AWS IAM can fetch the JWKS during `create-open-id-connect-provider`. Operator picks: nginx + Let's Encrypt, AWS ALB + ACM, Caddy with auto-TLS, CloudFront + S3 for static `/.well-known/*` + Lambda for sign, etc.
- Stage 6 AWS setup complete per [`docs/stage6-aws-setup.md`](./stage6-aws-setup.md) (the daemon-IAM-user trust path established there is the fallback while the federated path is being rolled out).
- A higher-assurance signer if the operator's threat model requires it (TEE-derived ES256 at `oidc/issuer/v1`, blocked on [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md)). The on-disk keypair shipped today is a complete v0.1 signer; TEE is a hardening swap, not a federation prerequisite. When ready, swap by replacing [`crates/agentkeys-broker-server/src/oidc.rs::OidcKeypair::load_or_generate`](../crates/agentkeys-broker-server/src/oidc.rs) with a TEE oracle call. JWKS, JWT shape, STS exchange, and bucket-policy enforcement all stay identical.

### AWS recipe

#### Prereqs

- Phase 1 broker running publicly (so its `/.well-known/openid-configuration` is fetchable over public TLS).
- `export OIDC_ISSUER="$BROKER_OIDC_ISSUER"` — the exact `BROKER_OIDC_ISSUER` you started the broker with.
- Verify `curl -sf "$OIDC_ISSUER/.well-known/openid-configuration" | jq .issuer` returns that string.

#### 1. Register the OIDC provider in IAM

```bash
aws iam create-open-id-connect-provider \
  --url "$OIDC_ISSUER" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list ''
export OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/$(echo $OIDC_ISSUER | sed 's|https://||')"
```

#### 2. Replace the role's trust policy with the federated variant

Replaces [`stage6-aws-setup.md` §3b](./stage6-aws-setup.md) (static IAM user). Principal becomes the OIDC provider; the `sts:TagSession` + `aws:RequestTag/agentkeys_user_wallet` condition is what wires cloud-enforced per-user isolation in §3 below.

```bash
OIDC_ISSUER_HOST="$(echo "$OIDC_ISSUER" | sed 's|https://||')"

aws iam update-assume-role-policy \
  --role-name agentkeys-agent \
  --policy-document "$(jq -n \
    --arg provider "$OIDC_PROVIDER_ARN" \
    --arg aud_key "${OIDC_ISSUER_HOST}:aud" \
    '{
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Principal: {Federated: $provider},
        Action: ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
        Condition: {
          StringEquals: {($aud_key): "sts.amazonaws.com"},
          StringNotEquals: {"aws:RequestTag/agentkeys_user_wallet": ""}
        }
      }]
    }')"
```

#### 3. Upgrade bucket policy to PrincipalTag-scoped

Replaces the `AllowDaemonRead` statement in [`stage6-aws-setup.md` §4](./stage6-aws-setup.md). Cloud now enforces "the assumed session can only touch the prefix matching its PrincipalTag":

```json
{
  "Sid": "AllowDaemonReadOwnPrefix",
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-agent"},
  "Action": ["s3:GetObject", "s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::$BUCKET",
    "arn:aws:s3:::$BUCKET/${aws:PrincipalTag/agentkeys_user_wallet}/*"
  ],
  "Condition": {
    "StringEquals": {"s3:prefix": "${aws:PrincipalTag/agentkeys_user_wallet}/"}
  }
}
```

#### 4. End-to-end proof

The one test that proves phase 2 works: a JWT claiming wallet A can only touch wallet A's prefix — never B's.

```bash
# Mint a JWT via the broker. Bearer must come from `POST /session/create`
# against the backend; the wallet inside the JWT is whatever wallet that
# session is bound to (so this recipe presumes the operator drove the same
# session-create flow phase 1 already documented).
SESSION=<your-session-bearer>
JWT=$(curl -sf -X POST "$BROKER_URL/v1/mint-oidc-jwt" \
  -H "Authorization: Bearer $SESSION" | jq -r .jwt)
WALLET=$(jq -R 'split(".") | .[1] | @base64d | fromjson | .agentkeys_user_wallet' <<<"$JWT" -r)

# Exchange for temp creds
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-agent" \
  --role-session-name "stage7-wip-$(date +%s)" \
  --web-identity-token "$JWT")
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

# (a) own prefix — should succeed (empty is fine, no AccessDenied)
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$WALLET/"

# (b) someone else's prefix — THIS IS THE KEY MOMENT — should AccessDenied
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "0xdeadbeef/"
```

Test (b) is what Stage 6's static-IAM path can't prove. Cloud-enforced, zero app-side trust. The phase 1 broker's `assume-role` path **does** issue scoped creds, but isolation enforcement still relies on the operator's IAM trust policy alone — phase 2 moves enforcement into AWS itself.

#### 5. Swap the on-disk keypair for a TEE-derived signer

When [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md) closes, replace `crates/agentkeys-broker-server/src/oidc.rs::OidcKeypair::load_or_generate` with a call to the TEE's `derive("oidc/issuer/v1")`. JWKS, JWT shape, STS exchange, and bucket-policy enforcement all stay identical — only the signing backend changes.

## Operational follow-ups (post Phase 2)

Phase 2 architecture is complete. The remaining items are deployment and hardening tasks, scoped per-operator:

- **Public TLS hosting** — terminate TLS at a reverse proxy in front of the Rust broker (nginx + Let's Encrypt, AWS ALB + ACM, Caddy, etc.), or absorb the issuer endpoints behind a CloudFront+ALB pair so `oidc.agentkeys.dev` (or chosen issuer URL) resolves to the broker's `/.well-known/*` surface. Required for AWS `create-open-id-connect-provider` registration.
- **TEE signer swap** — replace the on-disk ES256 keypair with a TEE-derived `oidc/issuer/v1` key when [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md) closes. Hardening, not a Stage-7 prerequisite — see §"Cloud federation deployment" above.
- **Audit-destination swap** — point the audit log at a chain (Heima, Ethereum, Solana, permissioned) or a sealed log service per the [pluggable audit destination](spec/architecture.md#11-audit-destination-is-pluggable) framing. Configuration choice, not a Stage-7 redesign.
- **GCP / Ali Cloud federation recipes** — equivalent of the AWS §"Cloud federation deployment" recipe for GCP Workload Identity Federation and Ali Cloud RAM. The OIDC discovery + JWT shape work cross-cloud unchanged; only the IAM-side registration step differs.
- **Promote phase 1 + 2 doc** — once the live three-terminal demo passes for a non-operator developer (with no AWS env vars on their machine), promote [`docs/operator-runbook.md`](./operator-runbook.md) from WIP to canonical.
- **Stage 8 hand-off** — the bucket prefix `s3://agentkeys-vault/<wallet>/` is the reuse point with Stage 8; ciphertext + per-epoch DEK rotation live in [`stage8-wip.md`](./stage8-wip.md), not here.
