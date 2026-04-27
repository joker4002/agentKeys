# Stage 7 — WIP notes

> **WIP / scratchpad.** Phase 1 (broker server) ships in PR [#60](https://github.com/litentry/agentKeys/pull/60); the OIDC-federation half (phase 2) is preserved below for when its prereqs land. Not a finished guide.

## What Stage 7 is

Two halves that compose into the canonical "broker, not proxy" architecture:

1. **Phase 1 — Broker server (shipped).** A long-running HTTP service holds the operator's long-lived `agentkeys-daemon` AWS access key and brokers 1-hour scoped credentials to authenticated daemons. Lets app developers run daemons against operator infrastructure without ever touching AWS keys themselves.
2. **Phase 2 — OIDC federation (deferred).** Expose the broker's TEE (or interim ES256 signer) as a conforming OIDC Identity Provider at a stable public URL. Any cloud that trusts the issuer can exchange our JWTs for scoped temp creds via standard federation. Replaces the static-IAM `sts:assume-role` path with `sts:assume-role-with-web-identity` + `sts:TagSession` for cloud-enforced per-user isolation.

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

# Terminal B — broker (with stage6-demo-env.sh sourced or BROKER_DAEMON_* in env)
export BROKER_DAEMON_ACCESS_KEY_ID=$(op read 'op://AgentKeys/daemon/access-key-id')
export BROKER_DAEMON_SECRET_ACCESS_KEY=$(op read 'op://AgentKeys/daemon/secret-access-key')
export BROKER_AGENT_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-agent"
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

**Out of phase 1 (deferred to phase 2):**

- OIDC discovery / JWKS / `assume-role-with-web-identity` (the section below).
- TS [`services/oidc-stub/`](../services/oidc-stub/) retirement (still ships its `/internal/sign` endpoint independently for the phase 2 test recipe below).
- Provisioner-scripts AWS-cred consumer rewiring — daemon flag is in place; the scraper-side fetch happens with phase 2.
- Public hosting of the broker / KMS-sealed config source.

## Phase 2 — OIDC federation (still blocked)

This is the half that turns the broker into a generalized OIDC Identity Provider so any AWS account (or GCP / Ali Cloud) can trust our JWTs without operator-side IAM-user keys.

### Why phase 2 is not running yet

- Needs `oidc.agentkeys.dev` (or equivalent) hosted publicly with a public-CA TLS cert so AWS IAM accepts `create-open-id-connect-provider`.
- The "right" signer is a TEE-derived ES256 key at path `oidc/issuer/v1`, blocked on [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md).
- [`services/oidc-stub/`](../services/oidc-stub/) ships an interim local-file ES256 signer; swap for TEE when §3 closes, or absorb the issuer endpoints into the Rust broker once public hosting is decided.

### Phase 2 test script — preserved for when both prereqs are in place

#### Prereqs

- Stage 6 AWS setup complete per [`docs/stage6-aws-setup.md`](./stage6-aws-setup.md).
- Phase 1 broker running locally (so the static-IAM `mint-aws-creds` path keeps working as a fallback during the migration).
- `services/oidc-stub/` hosted publicly. Options: CloudFront+S3 + Lambda for `/internal/sign`; ECS Fargate with ALB; or ngrok for dev (`ngrok http 34568`).
- `export OIDC_ISSUER=https://<your-hosted-url>`; verify `curl -sf "$OIDC_ISSUER/.well-known/openid-configuration" | jq .issuer`.

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
# Mint a JWT via the stub
WALLET=0x1111111111111111111111111111111111111111
JWT=$(curl -sf -X POST http://localhost:34568/internal/sign \
  -H 'content-type: application/json' \
  -d "{
    \"iss\": \"$OIDC_ISSUER\",
    \"sub\": \"agentkeys:agent:$WALLET\",
    \"aud\": \"sts.amazonaws.com\",
    \"agentkeys_user_wallet\": \"$WALLET\",
    \"exp\": $(($(date +%s) + 300)),
    \"iat\": $(date +%s)
  }" | jq -r .jwt)

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

#### 5. Swap the stub for a TEE-derived signer

When [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md) closes, replace [`services/oidc-stub/src/keys.ts`](../services/oidc-stub/src/keys.ts)'s local-file key loader with a call to the TEE's `derive("oidc/issuer/v1")`. JWKS, JWT shape, STS exchange, and bucket-policy enforcement all stay identical. ~50 lines in `keys.ts`. Or, if the issuer endpoints have already been absorbed into the Rust broker by then, the swap happens inside `crates/agentkeys-broker-server/`.

## TODO pickups

- **Phase 2 issuer absorption:** port discovery + JWKS + JWT signing from [`services/oidc-stub/`](../services/oidc-stub/) into the Rust broker as `POST /v1/mint-oidc-jwt` and the `/.well-known/*` surface. Retire the TS stub.
- **Public hosting:** CloudFront+S3 for static discovery + Lambda for sign, or terminate TLS at a reverse proxy in front of the Rust broker.
- **Provisioner-scripts integration:** wire the daemon's `--broker-url` flag into the scraper subprocesses' AWS-cred fetch (replaces the `stage6-demo-env.sh` sourcing pattern in `scripts/`).
- **Promote phase 1 doc:** once the live three-terminal demo passes for a non-operator developer (with no AWS env vars on their machine), promote `docs/operator-runbook.md` from WIP to canonical.
- **Add the equivalent GCP Workload Identity Federation + Ali Cloud RAM recipes** (Stage 7 target is generalized, not AWS-only).
- **Hand off the credential-vault question to Stage 8** — the bucket prefix `s3://agentkeys-vault/<wallet>/` is the reuse point; ciphertext + per-epoch DEK rotation live in [`stage8-wip.md`](./stage8-wip.md), not here.
