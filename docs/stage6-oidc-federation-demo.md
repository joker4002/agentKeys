# Stage 6 — OIDC Federation Demo (deferred, reference only)

**Status:** reference / future work. The main Stage 6 runbook ([`docs/stage6-aws-setup.md`](./stage6-aws-setup.md)) uses the static-IAM-user path for the daemon's AWS access. This doc preserves the OIDC-federation design + test so a future session can pick it up unchanged.

**Why this is deferred:**
- Real OIDC federation requires `oidc.agentkeys.dev` serving a conforming discovery doc + JWKS over HTTPS with a public-CA cert (or a provider-registered thumbprint).
- The AWS side validates reachability on `create-open-id-connect-provider` — we can't "register and forget" from behind localhost.
- The "right" signer for `oidc/issuer/v1` is a TEE-derived ES256 key (blocked on [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md)). The [`services/oidc-stub/`](../services/oidc-stub/) code shipped in Stage 6 is an interim using a local-file ES256 key.
- For Stage 6 interim, a static IAM user (`agentkeys-daemon` → `sts:AssumeRole` → `agentkeys-agent`) gets the same end state (daemon has scoped S3/SES access) without the OIDC-endpoint-hosting + TEE dependencies.

**When to pick this up:**
- After [`services/oidc-stub/`](../services/oidc-stub/) is hosted publicly (e.g. CloudFront + S3 + Let's Encrypt, ~1 hr of infra).
- OR when heima-gaps §3 closes and we can use a real TEE-derived ES256 key.

---

## 0. Prerequisites

From the main [`stage6-aws-setup.md`](./stage6-aws-setup.md), complete §0 (env vars), §1 (DNS prep), §2 (SES + DKIM). Then come back here INSTEAD of executing §3 onward in the main doc.

```bash
export REGION=us-east-1
export DOMAIN=bots.litentry.org
export PARENT_ZONE_ID=Z09723983CFJOHAE3VC65
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET=agentkeys-mail-${ACCOUNT_ID}
export OIDC_ISSUER=https://oidc.agentkeys.dev   # or your own hosting URL
```

## 1. Host the OIDC discovery endpoint

The [`services/oidc-stub/`](../services/oidc-stub/) Node service serves `/.well-known/openid-configuration` + `/.well-known/jwks.json` + `POST /internal/sign`. For AWS OIDC-provider registration to succeed, the endpoint must be reachable over HTTPS with a cert that chains to a public CA (Let's Encrypt works).

Hosting options (pick one):

- **A. CloudFront + S3** — serve static JSON from an S3 bucket behind CloudFront with an ACM cert. Then run `services/oidc-stub/` somewhere *else* (e.g. Lambda behind API Gateway) for `POST /internal/sign`. Clean separation; public JWKS is read-only static.
- **B. ECS Fargate task** — run the Node service directly with a public-CA-certed ALB. Simplest if you already have VPC + ECS.
- **C. Ngrok tunnel (dev only)** — for one-off demo: `ngrok http 34568` gives you a temporary `*.ngrok.app` URL. AWS accepts this for registration. Not for production.

Pick one, point `$OIDC_ISSUER` at the public URL, verify:

```bash
curl -sf "$OIDC_ISSUER/.well-known/openid-configuration" | jq .issuer
# → "https://oidc.agentkeys.dev"
curl -sf "$OIDC_ISSUER/.well-known/jwks.json" | jq '.keys[0].kty'
# → "EC"
```

## 2. Register the OIDC provider in IAM

```bash
aws iam create-open-id-connect-provider \
  --url "$OIDC_ISSUER" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list ''   # AWS auto-derives from public CA; empty is fine for Let's Encrypt

export OIDC_PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$(echo $OIDC_ISSUER | sed 's|https://||')"
echo "OIDC_PROVIDER_ARN=$OIDC_PROVIDER_ARN"
```

## 3. IAM role with OIDC-federated trust policy

Instead of §3 in the main doc (static IAM user trust), use this trust policy:

```bash
cat > role-trust-oidc.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "$OIDC_PROVIDER_ARN"},
    "Action": ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
    "Condition": {
      "StringEquals": {"$(echo $OIDC_ISSUER | sed 's|https://||'):aud": "sts.amazonaws.com"},
      "StringNotEquals": {"aws:RequestTag/agentkeys_user_wallet": ""}
    }
  }]
}
EOF

aws iam create-role \
  --role-name agentkeys-agent \
  --assume-role-policy-document file://role-trust-oidc.json

# Attach the same role-inline policy as the static-IAM path (S3 + SES permissions)
# — reuse the role-inline.json from stage6-aws-setup.md §3
aws iam put-role-policy \
  --role-name agentkeys-agent \
  --policy-name agentkeys-agent-inline \
  --policy-document file://role-inline.json
```

Key difference from the static-IAM path: the Principal is the OIDC provider ARN, not a specific IAM user. The `sts:TagSession` action + the `aws:RequestTag/agentkeys_user_wallet` condition together enforce that every assumed session must carry the `agentkeys_user_wallet` PrincipalTag — which is what downstream bucket-policy conditions key on.

## 4. Continue the main runbook

Now go back to [`stage6-aws-setup.md`](./stage6-aws-setup.md) §4 (S3 bucket). The bucket policy is identical to the static-IAM path — it references `role/agentkeys-agent`, which exists now.

Then §5 (receipt rule), §6 (test send) are identical.

## 5. Test: JWT → STS → temp creds → S3

The end-to-end test that proves OIDC federation works — this is what the static-IAM path can't exercise, and what a TEE-derived signer eventually replaces.

```bash
# 5a. Start oidc-stub locally (if not already hosted)
cd services/oidc-stub && npm start &
OIDC_STUB_PID=$!
sleep 2

# 5b. Mint a JWT with the agentkeys_user_wallet claim
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
echo "JWT (truncated): ${JWT:0:60}..."

# 5c. Exchange the JWT for AWS temp creds via STS
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "arn:aws:iam::$ACCOUNT_ID:role/agentkeys-agent" \
  --role-session-name "agentkeys-demo-$(date +%s)" \
  --web-identity-token "$JWT")

# 5d. Extract the temp creds + session tag
ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
SECRET_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

# 5e. Verify the session tag was set from the JWT claim
AWS_ACCESS_KEY_ID=$ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SECRET_KEY AWS_SESSION_TOKEN=$SESSION_TOKEN \
  aws sts get-caller-identity
# → ARN includes the session name; tag-verification needs a bucket-policy test

# 5f. Prove per-user isolation: try to list own prefix (should succeed)
AWS_ACCESS_KEY_ID=$ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SECRET_KEY AWS_SESSION_TOKEN=$SESSION_TOKEN \
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$WALLET/"
# → empty (bucket is empty) but NO AccessDenied error = policy authorized you

# 5g. Prove per-user isolation: try to list ANOTHER wallet's prefix (should fail)
AWS_ACCESS_KEY_ID=$ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SECRET_KEY AWS_SESSION_TOKEN=$SESSION_TOKEN \
  aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "0xdeadbeef/"
# → AccessDenied (PrincipalTag mismatch)

kill $OIDC_STUB_PID
```

The critical test is **5g**: even though the daemon has the generic `agentkeys-agent` role, it cannot touch any user prefix other than the one whose wallet was baked into the JWT. That cryptographic per-user isolation is what [`wiki/tag-based-access.md`](../wiki/tag-based-access.md) describes, and what the static-IAM path can only approximate.

## 6. Relationship to TEE-signed OIDC (Stage 6 final)

In this demo, `/internal/sign` at [`services/oidc-stub/src/server.ts`](../services/oidc-stub/src/server.ts) uses an ES256 key from a local file. The target architecture ([`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md)) replaces that signer with a TEE-derived key at derivation path `oidc/issuer/v1`. The JWT shape, JWKS format, STS exchange, and bucket-policy enforcement all stay identical — only the signing function changes. That swap is a ~50-line change in `services/oidc-stub/` once the TEE side lands.

## 7. Cleanup

```bash
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN"
aws iam delete-role-policy --role-name agentkeys-agent --policy-name agentkeys-agent-inline
aws iam delete-role --role-name agentkeys-agent
# Bucket + SES cleanup per the main runbook's §Cleanup
```
