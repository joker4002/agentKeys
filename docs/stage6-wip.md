# Stage 6 — WIP notes

> **WIP / scratchpad.** Revise as Stage 6 work progresses. Not a finished manual-test guide. Expect gaps, TODO markers, and rough edges. Promoted to a proper `docs/manual-test-stage6.md` once Stage 6 is code-complete + exercised live.

## What this doc is for

Capture Stage 6 test flows we want to preserve but can't fully exercise yet. Right now that's mostly the OIDC-federation path (§3). Add more sections as they come up.

## Related shipped docs

- [`docs/stage6-aws-setup.md`](./stage6-aws-setup.md) — operator runbook (the AWS setup the Stage 5b demo consumes). Static-IAM-user trust path, done.
- [`services/oidc-stub/`](../services/oidc-stub/README.md) — ES256 JWT signer + JWKS endpoint. Runs locally; needs public hosting for the OIDC path to go live.
- [`docs/manual-test-stage5.md`](./manual-test-stage5.md) — current live demo guide.

---

## 1. Static-IAM Stage 5b end-to-end on real SES (TODO)

Once `AGENTKEYS_EMAIL_BACKEND=ses-s3` is wired through provisioner-scripts + the AWS stack from [`stage6-aws-setup.md`](./stage6-aws-setup.md) is live: run `agentkeys provision openrouter` against a throwaway `bot-<ts>@bots.litentry.org` address. Expect the same four acceptance criteria as Stage 5b (exit 0, masked key, `read` returns it, `curl /api/v1/models` returns 200).

Missing before we can write this out:
- [ ] Confirm provisioner-scripts `ses-s3` backend polls the right bucket prefix and handles MIME headers the way SES actually writes them (not just our mock).
- [ ] Decide how the daemon gets IAM creds at runtime — static access keys in env, or session-token-minted temp creds via the daemon user's `AssumeRole`.
- [ ] Gate: SES sandbox vs. production. New SES accounts are in sandbox mode; outbound to unverified recipients is blocked. Inbound + OpenRouter outbound are fine for the test, but request production access via AWS support once real usage scales.

## 2. Harness `stage-6-done.sh` (TODO)

Mirror `harness/stage-5a-done.sh`. Should run:
- Rust: `cargo test -p agentkeys-mock-server -p agentkeys-core -p agentkeys-cli`
- TS: `npm test --prefix provisioner-scripts`
- OIDC stub: `cd services/oidc-stub && npm test`
- Grep guards / clippy / typecheck
- Optional: an AWS-CLI dry-run (bucket policy has 2 statements, role exists, user exists) gated on `AGENTKEYS_STAGE6_AWS_READY=1` so CI doesn't need AWS creds.

Not shipping this in the first Stage 6 PR — fold it in later.

## 3. OIDC federation demo (future, preserved here)

**Status:** deferred. Stage 6's critical path uses static-IAM-user trust. OIDC federation is the target architecture but depends on (a) `oidc.agentkeys.dev` (or equivalent) hosted publicly with a public-CA cert, and (b) ideally a TEE-derived ES256 signer (blocked on [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md)).

**Why preserve the test here:** the code side is already done — [`services/oidc-stub/`](../services/oidc-stub/) ships with `POST /internal/sign` and the JWKS endpoints. What's missing is hosting + the AWS-side wiring. When those prereqs are in place, follow this script to verify end-to-end cloud-enforced per-user isolation via PrincipalTag.

### 3.1 Prereqs

- AWS setup from [`stage6-aws-setup.md`](./stage6-aws-setup.md) §0-§2 complete (env vars, DNS, SES + DKIM). Stop before §3 — the OIDC path replaces the static-IAM trust policy.
- `services/oidc-stub/` running. Locally: `npm start` in that dir. Or hosted publicly via one of:
  - CloudFront + S3 for static discovery + Lambda for `/internal/sign`
  - ECS Fargate task with public-CA-certed ALB
  - Ngrok tunnel (`ngrok http 34568`) for dev
- Set `export OIDC_ISSUER=https://<your-hosted-url>`. Verify: `curl -sf "$OIDC_ISSUER/.well-known/openid-configuration" | jq .issuer`.

### 3.2 Register IAM OIDC provider

```bash
aws iam create-open-id-connect-provider \
  --url "$OIDC_ISSUER" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list ''
export OIDC_PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/$(echo $OIDC_ISSUER | sed 's|https://||')"
```

### 3.3 Role with OIDC-federated trust policy

Replaces the static-IAM trust policy in `stage6-aws-setup.md` §3b:

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

aws iam create-role --role-name agentkeys-agent --assume-role-policy-document file://role-trust-oidc.json
aws iam put-role-policy --role-name agentkeys-agent --policy-name agentkeys-agent-inline --policy-document file://role-inline.json
```

### 3.4 Bucket policy with PrincipalTag scope

Replaces the `AllowDaemonRead` statement in `stage6-aws-setup.md` §4. The key change: `Resource` now scopes to `${aws:PrincipalTag/agentkeys_user_wallet}/*`, and a `Condition` pins `s3:prefix` to the same.

```json
{
  "Sid": "AllowDaemonReadOwnPrefix",
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::$ACCOUNT_ID:role/agentkeys-agent"},
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

### 3.5 End-to-end test — the point of the whole exercise

```bash
# Mint a JWT claiming to be wallet 0x1111...
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
  --role-arn "arn:aws:iam::$ACCOUNT_ID:role/agentkeys-agent" \
  --role-session-name "wip-$(date +%s)" \
  --web-identity-token "$JWT")

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

# (a) Own prefix — should succeed
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$WALLET/"
# → empty but NO AccessDenied

# (b) Someone else's prefix — should fail (THIS IS THE KEY MOMENT)
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "0xdeadbeef/"
# → AccessDenied (PrincipalTag mismatch enforced by bucket policy)
```

Test (b) is what the static-IAM path can't prove. The JWT says "I am wallet 0x1111", STS writes that into a PrincipalTag, the bucket policy compares the tag to the prefix, the policy denies. All cloud-enforced, zero app-side trust needed.

### 3.6 Swap for TEE-derived signer

Once [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md) closes and the TEE can derive at path `oidc/issuer/v1`: replace the key source in [`services/oidc-stub/src/keys.ts`](../services/oidc-stub/src/keys.ts). JWKS, JWT shape, STS exchange, bucket-policy enforcement all stay identical. ~50 lines in `keys.ts` + a config flag.

---

## Things that moved around

- Older polished standalone doc `docs/stage6-oidc-federation-demo.md` was removed; content folded into §3 here as a lighter scratchpad.
- Main operator runbook `docs/stage6-aws-setup.md` deliberately stays focused on the static-IAM path. Cross-references point here for the OIDC variant.

## TODO pickups

- Write §1 properly once Stage 5b-against-SES works end-to-end
- Ship `harness/stage-6-done.sh` per §2 sketch
- Promote this file to `docs/manual-test-stage6.md` when Stage 6 is code-complete + live-tested
