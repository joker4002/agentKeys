# Stage 7 — WIP notes

> **WIP / scratchpad.** Preserves the Stage 7 OIDC-federation test for future work. Revise as prereqs land. Not a finished guide.

## What Stage 7 is

Expose our TEE (or interim ES256 signer) as a conforming OIDC Identity Provider at a stable public URL. Any cloud that trusts the issuer can exchange our JWTs for scoped temp creds via standard federation. Per [`docs/spec/plans/development-stages.md`](./spec/plans/development-stages.md), this is the "Generalized OIDC Provider" stage after Stage 6 (Federated Own Email).

## Why it's not running yet

- Needs `oidc.agentkeys.dev` (or equivalent) hosted publicly with a public-CA TLS cert so AWS IAM accepts `create-open-id-connect-provider`.
- The "right" signer is a TEE-derived ES256 key at path `oidc/issuer/v1`, blocked on [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md).
- [`services/oidc-stub/`](../services/oidc-stub/) ships an interim local-file ES256 signer; swap for TEE when §3 closes.

## Test script — preserved for when both prereqs are in place

### Prereqs

- Stage 6 AWS setup complete per [`docs/stage6-aws-setup.md`](./stage6-aws-setup.md).
- `services/oidc-stub/` hosted publicly. Options: CloudFront+S3 + Lambda for `/internal/sign`; ECS Fargate with ALB; or ngrok for dev (`ngrok http 34568`).
- `export OIDC_ISSUER=https://<your-hosted-url>`; verify `curl -sf "$OIDC_ISSUER/.well-known/openid-configuration" | jq .issuer`.

### 1. Register the OIDC provider in IAM

```bash
aws iam create-open-id-connect-provider \
  --url "$OIDC_ISSUER" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list ''
export OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/$(echo $OIDC_ISSUER | sed 's|https://||')"
```

### 2. Replace the role's trust policy with the federated variant

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

### 3. Upgrade bucket policy to PrincipalTag-scoped

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

### 4. End-to-end proof

The one test that proves Stage 7 works: a JWT claiming wallet A can only touch wallet A's prefix — never B's.

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

Test (b) is what Stage 6's static-IAM path can't prove. Cloud-enforced, zero app-side trust.

### 5. Swap the stub for a TEE-derived signer

When [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md) closes, replace [`services/oidc-stub/src/keys.ts`](../services/oidc-stub/src/keys.ts)'s local-file key loader with a call to the TEE's `derive("oidc/issuer/v1")`. JWKS, JWT shape, STS exchange, and bucket-policy enforcement all stay identical. ~50 lines in `keys.ts`.

## TODO pickups

- Host `services/oidc-stub/` publicly (CloudFront+S3 for static discovery + Lambda for sign)
- Promote to `docs/manual-test-stage7.md` once the test passes live
- Add the equivalent GCP Workload Identity Federation + Ali Cloud RAM recipes (Stage 7 target is generalized, not AWS-only)
