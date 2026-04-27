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

# Terminal B — broker. Operator has DAEMON_ACCESS_KEY_ID,
# DAEMON_SECRET_ACCESS_KEY, ACCOUNT_ID, and REGION already in their shell
# environment (persisted in ~/.zshenv with mode 0600 — zsh sources it for
# every shell). The broker derives BROKER_AGENT_ROLE_ARN from ACCOUNT_ID.
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
