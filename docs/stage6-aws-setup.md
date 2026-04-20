# Stage 6 AWS Setup Runbook

**Audience:** the operator setting up Stage 6's hosted-email infra on real AWS for the first time. Default path is a subdomain on an existing parent (`bots.litentry.org` on AWS account `429071895007`); the wiki-canonical standalone `@agentkeys-email.io` path is the post-interim option.
**Outcome:** an AWS account with SES domain verified, S3 bucket + bucket policy for per-user isolation, IAM role for the daemon to assume, and (optional) IAM OIDC provider registered. Once done, the Stage 6 code (mock-server + CLI + provisioner-scripts adapters) can talk to real AWS, and the Stage 5b live demo unblocks.
**Status:** interim build. TEE-held BYODKIM and TEE-signed OIDC JWTs are deferred until [`heima-gaps-vs-desired-architecture.md`](./spec/heima-gaps-vs-desired-architecture.md) §3 + §4 close. AWS-managed DKIM is used as the Stage 6 interim; replace it with TEE-BYODKIM later.

## 0. Preconditions

- AWS account with **IAM admin** or equivalent (roles, OIDC providers, IAM policies, S3 buckets, SES identities, Route 53 hosted zones).
- `aws` CLI v2 installed and authenticated. `aws sts get-caller-identity` must return your identity.
- A **parent domain** already hosted in Route 53. This runbook uses a subdomain carved out of the parent. We default to `bots.litentry.org` on account `429071895007` (hosted zone `Z09723983CFJOHAE3VC65`).

### Domain decision — subdomain on litentry.org vs standalone agentkeys-email.io

Two viable shapes:

| Path | Domain | Hosted zone | Cost | Use when |
|---|---|---|---|---|
| **A. Subdomain on existing parent** (this runbook's default) | `bots.litentry.org` — email addresses look like `bot-ab12cd@bots.litentry.org` | Reuses `litentry.org` zone (`Z09723983CFJOHAE3VC65`) — just add records, no delegation | $0 — parent already registered | Stage 6 interim / internal testing; parent domain's reputation bootstraps deliverability |
| **B. Standalone canonical domain** | `agentkeys-email.io` — matches the wiki's published hosted-default | New Route 53 hosted zone on fresh registration | ~$15/yr + fresh-domain reputation build | Production-facing v0.1+; external users will see and trust the name |

Stage 6 goes with Path A because (1) it's what the user already has set up, (2) it's free, (3) inheriting `litentry.org`'s reputation is better for initial deliverability than a brand-new `.io`. The Stage 6 code is domain-agnostic — reads `AGENTKEYS_EMAIL_DOMAIN` — so swapping to `agentkeys-email.io` later is a one-env-var change.

Set these once at the top of your shell for the rest of the runbook:

```bash
export REGION=us-east-1                         # SES inbound regions: us-east-1, us-west-2, eu-west-1
export DOMAIN=bots.litentry.org                 # the subdomain we'll run SES under
export PARENT_ZONE_ID=Z09723983CFJOHAE3VC65     # existing litentry.org Route 53 hosted zone
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET=agentkeys-mail-${ACCOUNT_ID}      # bucket names are globally unique; account-id suffix avoids collisions
```

Verify all four resolved correctly before proceeding:

```bash
echo "REGION=$REGION DOMAIN=$DOMAIN PARENT_ZONE_ID=$PARENT_ZONE_ID ACCOUNT_ID=$ACCOUNT_ID BUCKET=$BUCKET"
# Expected: REGION=us-east-1 DOMAIN=bots.litentry.org PARENT_ZONE_ID=Z09723983CFJOHAE3VC65 ACCOUNT_ID=429071895007 BUCKET=agentkeys-mail-429071895007
```

## 1. DNS prep on the existing litentry.org hosted zone

No domain registration needed — we just publish records for the `bots` subdomain inside the existing litentry.org zone. Later sections generate DKIM tokens and an MX record; you'll UPSERT them against `$PARENT_ZONE_ID`.

Confirm the parent zone is reachable before we start:

```bash
aws route53 get-hosted-zone --id "$PARENT_ZONE_ID" \
  --query 'HostedZone.{name: Name, private: Config.PrivateZone}'
# Expected: {"name": "litentry.org.", "private": false}
```

If that fails, your aws creds don't have Route 53 permissions on this zone — fix before continuing.

### Note: no subdomain NS delegation required

Because `bots.litentry.org` lives *inside* the same hosted zone as `litentry.org`, every DNS change below is an UPSERT on the parent zone. You do NOT need to create a separate child hosted zone for `bots.litentry.org`. (That's only needed if someone *else* is going to manage `bots.litentry.org` records.)

### Nothing-else-breaks check

This runbook adds records scoped to `bots.litentry.org` and `*.bots.litentry.org`. It does NOT touch the apex `litentry.org` MX, SPF, DMARC, or any records for other subdomains. If you have existing inbound mail on `litentry.org`, it is unaffected.

## 2. SES domain identity + DKIM (AWS-managed interim)

Verify the domain in SES, which also generates AWS-managed DKIM keys we'll publish as CNAMEs.

```bash
aws sesv2 create-email-identity \
  --region "$REGION" \
  --email-identity "$DOMAIN" \
  --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT
```

Get the three DKIM CNAME tokens AWS generated:

```bash
aws sesv2 get-email-identity \
  --region "$REGION" \
  --email-identity "$DOMAIN" \
  --query 'DkimAttributes.Tokens' --output text
# → three strings like: <token1> <token2> <token3>
```

Publish the DKIM CNAMEs + SPF + DMARC + MX records in Route 53. Capture the DKIM tokens into env vars first so the JSON-templating heredoc below expands them (no hand-editing `<tokenN>` placeholders):

```bash
read -r T1 T2 T3 <<<"$(aws sesv2 get-email-identity --region "$REGION" \
  --email-identity "$DOMAIN" --query 'DkimAttributes.Tokens' --output text)"
echo "DKIM tokens: $T1 $T2 $T3"

cat > dns-change.json <<EOF
{
  "Comment": "Stage 6 email infra for $DOMAIN",
  "Changes": [
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "$T1._domainkey.$DOMAIN", "Type": "CNAME", "TTL": 300, "ResourceRecords": [{"Value": "$T1.dkim.amazonses.com"}]}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "$T2._domainkey.$DOMAIN", "Type": "CNAME", "TTL": 300, "ResourceRecords": [{"Value": "$T2.dkim.amazonses.com"}]}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "$T3._domainkey.$DOMAIN", "Type": "CNAME", "TTL": 300, "ResourceRecords": [{"Value": "$T3.dkim.amazonses.com"}]}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "$DOMAIN", "Type": "MX", "TTL": 300, "ResourceRecords": [{"Value": "10 inbound-smtp.$REGION.amazonaws.com"}]}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "$DOMAIN", "Type": "TXT", "TTL": 300, "ResourceRecords": [{"Value": "\"v=spf1 include:amazonses.com -all\""}]}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "_dmarc.$DOMAIN", "Type": "TXT", "TTL": 300, "ResourceRecords": [{"Value": "\"v=DMARC1; p=quarantine; rua=mailto:dmarc@$DOMAIN\""}]}}
  ]
}
EOF
```

Apply:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id "$PARENT_ZONE_ID" \
  --change-batch file://dns-change.json
```

> **Note on the DMARC `rua` address:** the DMARC aggregate-report mailbox `dmarc@$DOMAIN` must exist once the receipt rule in §6 is live. Until then, DMARC reports that come in get swallowed by SES. That's fine for Stage 6 interim. For a production posture, add a dedicated `dmarc@` inbox or point the `rua` at a mailbox you already monitor.

Wait ~5 minutes for propagation, then confirm verification:

```bash
aws sesv2 get-email-identity --region "$REGION" --email-identity "$DOMAIN" \
  --query '{verified: VerifiedForSendingStatus, dkim: DkimAttributes.Status}'
# → {"verified": true, "dkim": "SUCCESS"}
```

> **Interim note (flag this for Stage 6 follow-up):** SES is now signing outbound mail with an AWS-managed RSA-2048 DKIM key. The target architecture uses a TEE-held Ed25519 key derived at `dkim/<domain>/v1` (e.g. `dkim/bots.litentry.org/v1` for this Stage 6 interim, `dkim/agentkeys-email.io/v1` for the standalone canonical domain later), published via BYODKIM. Swap happens when [`heima-gaps §4`](./spec/heima-gaps-vs-desired-architecture.md) closes.

## 3. S3 bucket for inbound mail + per-user isolation

Create the bucket:

```bash
aws s3api create-bucket \
  --region "$REGION" \
  --bucket "$BUCKET" \
  $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION")

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Bucket policy allowing SES to write AND the daemon role (created in §4) to read ONLY its own prefix:

```bash
cat > bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowSESWriteInbound",
      "Effect": "Allow",
      "Principal": {"Service": "ses.amazonaws.com"},
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET/*",
      "Condition": {
        "StringEquals": {
          "aws:Referer": "$ACCOUNT_ID"
        }
      }
    },
    {
      "Sid": "AllowDaemonReadOwnPrefix",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::$ACCOUNT_ID:role/agentkeys-agent"},
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/\${aws:PrincipalTag/agentkeys_user_wallet}/*"
      ],
      "Condition": {
        "StringEquals": {
          "s3:prefix": "\${aws:PrincipalTag/agentkeys_user_wallet}/"
        }
      }
    }
  ]
}
EOF

aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://bucket-policy.json
```

The `${aws:PrincipalTag/agentkeys_user_wallet}` expansion is the whole per-user-isolation mechanism — every daemon session's assumed role will carry `agentkeys_user_wallet` as a PrincipalTag, and the bucket policy keys off it. See [`wiki/tag-based-access.md`](../wiki/tag-based-access.md).

## 4. IAM role `agentkeys-agent`

Two interim options for the trust policy — pick one based on whether §5 (OIDC) is in-scope for this pass:

### 4a. Trust policy — OIDC-federated (preferred, needs §5 completed)

```bash
cat > role-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.agentkeys.dev"
    },
    "Action": ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
    "Condition": {
      "StringEquals": {"oidc.agentkeys.dev:aud": "sts.amazonaws.com"},
      "StringNotEquals": {"aws:RequestTag/agentkeys_user_wallet": ""}
    }
  }]
}
EOF
```

### 4b. Trust policy — static IAM user (interim, OIDC deferred)

```bash
# Create a dedicated IAM user for the daemon
aws iam create-user --user-name agentkeys-daemon
aws iam create-access-key --user-name agentkeys-daemon
# → save the AccessKeyId + SecretAccessKey; inject into AGENTKEYS_AWS_ACCESS_KEY / ..._SECRET_KEY env

cat > role-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::$ACCOUNT_ID:user/agentkeys-daemon"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
```

Then create the role + attach a session policy that sets `agentkeys_user_wallet` on assume:

```bash
aws iam create-role \
  --role-name agentkeys-agent \
  --assume-role-policy-document file://role-trust.json

export ROLE_ARN=$(aws iam get-role --role-name agentkeys-agent --query 'Role.Arn' --output text)
echo "ROLE_ARN=$ROLE_ARN"

# Minimum permissions: read from S3 bucket (scoped by PrincipalTag in bucket policy), send from SES
cat > role-inline.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::$BUCKET"
    },
    {
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$BUCKET/*"
    },
    {
      "Effect": "Allow",
      "Action": ["ses:SendRawEmail"],
      "Resource": "arn:aws:ses:$REGION:$ACCOUNT_ID:identity/$DOMAIN"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name agentkeys-agent \
  --policy-name agentkeys-agent-inline \
  --policy-document file://role-inline.json
```

## 5. IAM OIDC provider for `oidc.agentkeys.dev` (optional for Stage 6 interim)

**Skip this section if you chose 4b and don't yet have `oidc.agentkeys.dev` hosted.** Stage 6 interim works fine with static IAM keys; OIDC federation is the target architecture but requires the `agentkeys-oidc-stub` service (code landing in US-6-5) or a TEE-derived ES256 issuer key (blocked by heima-gaps §3).

When you're ready:

```bash
# Register the OIDC provider
aws iam create-open-id-connect-provider \
  --url https://oidc.agentkeys.dev \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list ''   # AWS will use its trusted-CA library for Let's Encrypt-issued certs

export OIDC_PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.agentkeys.dev"
echo "OIDC_PROVIDER_ARN=$OIDC_PROVIDER_ARN"
```

You'll also need `oidc.agentkeys.dev` to actually serve `/.well-known/openid-configuration` + `/.well-known/jwks.json` with a currently-valid Let's Encrypt cert. The AWS side validates reachability on registration. See `services/oidc-stub/README.md` once US-6-5 lands for the reference implementation.

## 6. SES receipt rule for inbound

Create a rule set and rule that writes all inbound to our S3 bucket:

```bash
# Rule set is an account-wide resource; create once
aws ses create-receipt-rule-set --rule-set-name agentkeys --region "$REGION"

# Rule: match *@$DOMAIN, write to S3
cat > receipt-rule.json <<EOF
{
  "Name": "agentkeys-inbound",
  "Enabled": true,
  "ScanEnabled": true,
  "TlsPolicy": "Optional",
  "Recipients": ["$DOMAIN"],
  "Actions": [{
    "S3Action": {
      "BucketName": "$BUCKET",
      "ObjectKeyPrefix": "inbound/"
    }
  }]
}
EOF

aws ses create-receipt-rule \
  --region "$REGION" \
  --rule-set-name agentkeys \
  --rule file://receipt-rule.json

aws ses set-active-receipt-rule-set --rule-set-name agentkeys --region "$REGION"
```

Note: this writes raw MIME to `s3://agentkeys-mail/inbound/<msg_id>`. The Stage 6 mock mirrors this shape; the ses-s3 adapter in provisioner-scripts reads from this path.

> **Follow-up:** the object-key prefix should eventually become `s3://agentkeys-mail/<user_wallet>/<address>/` so per-user bucket-policy conditions bite. That requires a Lambda between SES and S3 to route by address (Stage 6 post-MVP) or SES's new subdomain routing. For now, all inbound lands in `inbound/` and the daemon filters by `To:` header.

## 7. Test: send yourself a test message

From any source that can send mail:

```bash
echo "stage-6 AWS setup test body" | mail -s "stage-6-setup-test" "test@$DOMAIN"
```

Verify it lands in S3 within ~30s:

```bash
aws s3 ls "s3://$BUCKET/inbound/" --recursive
# → you should see one .eml object

aws s3 cp "s3://$BUCKET/inbound/<most-recent-msg-id>" - | head -c 400
# → raw MIME with your subject + body
```

If this works, the inbound pipeline is live.

## 8. Hand-back to Claude / the Stage 6 code

When the above completes, share these values back so I can wire them into the Stage 6 code (via env vars, NOT committed to git):

```
ACCOUNT_ID=429071895007
REGION=us-east-1
DOMAIN=bots.litentry.org
PARENT_ZONE_ID=Z09723983CFJOHAE3VC65
SES_VERIFIED=<yes|no>
DKIM_STATUS=<SUCCESS|PENDING|FAILED>
BUCKET_ARN=arn:aws:s3:::agentkeys-mail-429071895007
ROLE_ARN=arn:aws:iam::429071895007:role/agentkeys-agent
TRUST_MODE=<oidc | static-iam-user>
OIDC_PROVIDER_ARN=<arn:aws:iam::429071895007:oidc-provider/oidc.agentkeys.dev, or "deferred">
# If TRUST_MODE=static-iam-user:
DAEMON_ACCESS_KEY_ID=<redacted>
DAEMON_SECRET_ACCESS_KEY=<redacted>  # share via 1Password, NOT in chat
```

I'll then wire `AGENTKEYS_EMAIL_BACKEND=ses-s3` in provisioner-scripts to read from `$BUCKET_ARN` with creds from either OIDC-mint (if TRUST_MODE=oidc) or the static IAM user (if TRUST_MODE=static-iam-user).

## Follow-ups tracked elsewhere

- **TEE-BYODKIM**: replace AWS-managed DKIM with TEE-held Ed25519. Depends on [`heima-gaps §4`](./spec/heima-gaps-vs-desired-architecture.md). Track via [issue #50](https://github.com/litentry/agentKeys/issues/50).
- **TEE-signed OIDC JWT**: replace `agentkeys-oidc-stub` / static-IAM trust with TEE-derive(`oidc/issuer/v1`) + sts:AssumeRoleWithWebIdentity. Depends on heima-gaps §3.
- **Per-address S3 prefix**: currently all inbound lands in `s3://$BUCKET/inbound/`; Stage 6 post-MVP should route to `s3://$BUCKET/<wallet>/<address>/` either via SES Lambda or subdomain routing.
- **Throwaway inbox lifecycle**: currently addresses are unbounded; Stage 6 post-MVP should add TTL + audit-logged revocation.

## Cleanup (if you want to tear down)

```bash
# Disable the active rule set (keeps SES inbound from hitting this bucket)
aws ses set-active-receipt-rule-set --rule-set-name "" --region "$REGION"

# Drop the role + bucket
aws iam delete-role-policy --role-name agentkeys-agent --policy-name agentkeys-agent-inline
aws iam delete-role --role-name agentkeys-agent
aws s3 rm "s3://$BUCKET" --recursive
aws s3api delete-bucket --bucket "$BUCKET"

# Delete SES domain identity
aws sesv2 delete-email-identity --region "$REGION" --email-identity "$DOMAIN"

# OIDC provider (if created)
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN"

# Domain registration stays (you paid for it); release via registrar if unwanted
```
