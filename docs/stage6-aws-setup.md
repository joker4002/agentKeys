# Stage 6 AWS Setup Runbook

**Audience:** the operator setting up Stage 6's hosted-email infra on real AWS for the first time. Default path is a subdomain on an existing parent (`bots.litentry.org` on AWS account `429071895007`); the wiki-canonical standalone `@agentkeys-email.io` path is the post-interim option.
**Outcome:** an AWS account with SES domain verified, `agentkeys-daemon` IAM user + `agentkeys-agent` role (static-IAM-user trust), S3 bucket + bucket policy, SES receipt rule writing inbound to S3. Once done, the Stage 6 code (mock-server + CLI + provisioner-scripts adapters) can talk to real AWS, and the Stage 5b live demo unblocks. The OIDC-federated variant (TEE-signed JWT → PrincipalTag isolation) is Stage 7 work; test preserved in [`stage7-wip.md`](./stage7-wip.md).
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

> **Interim DKIM key custody — explicit.** In this Stage 6 setup, **AWS SES itself holds the private DKIM key.** We never generate, see, or store it. The three CNAME records you published point `<token>._domainkey.$DOMAIN` at `<token>.dkim.amazonses.com`, where AWS publishes the matching public key. SES signs every outbound message with the private key sitting inside its DKIM signing service; we just call `ses:SendRawEmail` and trust AWS to sign correctly.
>
> **What we're trusting AWS with:** DKIM signing authority for `$DOMAIN`. An AWS-internal compromise or an account takeover could forge mail that passes DKIM as us. Bounded blast radius: the signed mail cannot touch anything in the TEE, forge session tokens, or access user data — it's a reputation risk (spam or phishing claiming to be us), not a key-custody-of-user-data risk.
>
> **Migration spectrum (target = TEE-BYODKIM):**
> | Option | Who holds the private key | Rule #2 | Complexity |
> |---|---|---|---|
> | AWS-managed DKIM (this interim) | AWS SES — opaque service | ❌ | trivial |
> | BYODKIM, key in AWS KMS + Lambda signer | AWS KMS HSM | ⚠ partial | medium (adds outbound Lambda) |
> | BYODKIM, key in enclave (`dkim/<domain>/v1`) | TEE-sealed, derived from master seed | ✅ | high — blocked on [`heima-gaps §4`](./spec/heima-gaps-vs-desired-architecture.md) |
>
> **Swap to TEE-BYODKIM happens when [`heima-gaps §4`](./spec/heima-gaps-vs-desired-architecture.md) closes.** Until then, the Stage 6 interim accepts the AWS-custody tradeoff. Do NOT upgrade to "BYODKIM with file-stored key" — that path is strictly worse than AWS-managed (lower availability, similar trust surface).

## 3. IAM: daemon user + `agentkeys-agent` role

This Stage 6 runbook uses **static IAM-user trust** as the interim: create a dedicated IAM user `agentkeys-daemon`, create the `agentkeys-agent` role that trusts only that user, and attach the S3/SES inline permissions. The user's access keys get injected into the daemon's env at runtime; the daemon calls `sts:AssumeRole` to get temp creds before touching S3 or SES.

For the full OIDC-federated variant (where a TEE-minted JWT is exchanged at STS for temp creds tagged with `agentkeys_user_wallet`), see [`stage7-wip.md`](./stage7-wip.md). That path delivers cryptographic per-user isolation via PrincipalTag but requires `oidc.agentkeys.dev` hosted publicly with a Let's Encrypt cert — deferred because (a) the hosting adds a Stage 7 dependency and (b) the "right" signer for that path is a TEE-derived ES256 key, blocked on [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md).

### 3a. Create the daemon IAM user

> **Before you run any `cat > *.json <<EOF` command in §3 and §4**, confirm the env vars from §0 are still set in this shell. These heredocs interpolate `$ACCOUNT_ID`, `$BUCKET`, `$REGION`, `$DOMAIN` at write time — a new shell tab wipes them, and an empty expansion produces a malformed ARN that AWS rejects with the unhelpful message `MalformedPolicyDocument: The policy failed legacy parsing`.
>
> ```bash
> # Re-run §0 if any of these echo empty:
> : "${ACCOUNT_ID:?ACCOUNT_ID empty — re-run §0 env setup}"
> : "${REGION:?REGION empty — re-run §0 env setup}"
> : "${DOMAIN:?DOMAIN empty — re-run §0 env setup}"
> : "${BUCKET:?BUCKET empty — re-run §0 env setup}"
> echo "OK: ACCOUNT_ID=$ACCOUNT_ID REGION=$REGION DOMAIN=$DOMAIN BUCKET=$BUCKET"
> ```
>
> You can also `grep Resource *.json` after any heredoc write to confirm the ARN landed correctly.

```bash
aws iam create-user --user-name agentkeys-daemon

# Generate an access key. Save AccessKeyId + SecretAccessKey IMMEDIATELY —
# the secret is only shown on creation. Inject into daemon env as
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY later.
aws iam create-access-key --user-name agentkeys-daemon
# → save both values to 1Password / your secret manager. NOT to git.

# Minimum permissions for the USER: just sts:AssumeRole on the role we're
# about to create. All real S3/SES access comes from the role, not the user.
#
# Guard: confirm ACCOUNT_ID is set before proceeding — an empty value
# produces `arn:aws:iam:::role/...` which IAM rejects with the cryptic
# `MalformedPolicyDocument: The policy failed legacy parsing` error.
[ -n "$ACCOUNT_ID" ] || { echo "ACCOUNT_ID is empty — re-run §0"; exit 1; }

aws iam put-user-policy \
  --user-name agentkeys-daemon \
  --policy-name agentkeys-daemon-assume-role \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Resource\":\"arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-agent\"}]}"
```

> **Why inline instead of `file://`.** The inline form lets you verify the ARN expanded correctly (`echo` the command before running if unsure) without a separate file that could pick up a BOM / invisible chars / stale content from a previous run. `MalformedPolicyDocument: The policy failed legacy parsing` is the specific error you get when either (a) the Resource ARN has an empty `$ACCOUNT_ID` (double colon), or (b) the JSON has invisible Unicode the IAM parser rejects. The guard above catches case (a); the inline form eliminates case (b).

### 3b. Create the `agentkeys-agent` role

```bash
cat > role-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::${ACCOUNT_ID}:user/agentkeys-daemon"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name agentkeys-agent \
  --assume-role-policy-document file://role-trust.json

export ROLE_ARN=$(aws iam get-role --role-name agentkeys-agent --query 'Role.Arn' --output text)
echo "ROLE_ARN=$ROLE_ARN"

# Role's permissions: read from S3 bucket, send from SES. (The bucket is
# created in §4; the role policy can reference it by ARN before the bucket
# exists — AWS doesn't validate resource-existence on put-role-policy.)
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
      "Resource": "arn:aws:ses:${REGION}:${ACCOUNT_ID}:identity/$DOMAIN"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name agentkeys-agent \
  --policy-name agentkeys-agent-inline \
  --policy-document file://role-inline.json
```

> **Per-user isolation note.** With the static-IAM-user path, per-user isolation lives *app-side* in the daemon — the daemon knows which wallet it's acting as and scopes its own S3 keys accordingly. The cloud does NOT enforce isolation; an app bug could let one wallet read another's prefix. The OIDC-federated path in [`stage7-wip.md`](./stage7-wip.md) enforces isolation at the bucket-policy layer via `${aws:PrincipalTag/agentkeys_user_wallet}` — recommended for production. See also [`wiki/tag-based-access.md`](../wiki/tag-based-access.md).

## 4. S3 bucket for inbound mail

Now that `agentkeys-agent` exists, we can apply the full bucket policy in one shot — no split.

```bash
aws s3api create-bucket \
  --region "$REGION" \
  --bucket "$BUCKET" \
  $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION")

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Bucket policy — SES writes inbound, `agentkeys-agent` role reads:

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
        "StringEquals": {"aws:Referer": "$ACCOUNT_ID"}
      }
    },
    {
      "Sid": "AllowDaemonRead",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-agent"},
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/*"
      ]
    }
  ]
}
EOF

aws s3api put-bucket-policy --bucket "$BUCKET" --policy file://bucket-policy.json
```

Verify both statements present:

```bash
aws s3api get-bucket-policy --bucket "$BUCKET" --query 'Policy' --output text | jq '.Statement | length'
# → 2
```

> **What's different from the OIDC path.** Here `AllowDaemonRead` gives the role read-access to the whole bucket — the daemon is trusted to self-scope via the `s3:prefix` / object-key conventions its own code applies. The OIDC path instead puts a `${aws:PrincipalTag/agentkeys_user_wallet}/*` condition here and mints one PrincipalTag per session. If you later migrate to OIDC, this statement's `Resource` + `Condition` are the two things that change.

## 5. SES receipt rule for inbound

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

## 6. Test: send yourself a test message

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

## 7. Hand-back to Claude / the Stage 6 code

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
DAEMON_USER_ARN=arn:aws:iam::429071895007:user/agentkeys-daemon
DAEMON_ACCESS_KEY_ID=<redacted>
DAEMON_SECRET_ACCESS_KEY=<redacted>  # share via 1Password, NOT in chat
```

I'll then wire `AGENTKEYS_EMAIL_BACKEND=ses-s3` in provisioner-scripts to read from `$BUCKET_ARN` using the `agentkeys-daemon` user's access key to assume `$ROLE_ARN` at runtime.

## Follow-ups tracked elsewhere

- **TEE-BYODKIM**: replace AWS-managed DKIM with TEE-held Ed25519. Depends on [`heima-gaps §4`](./spec/heima-gaps-vs-desired-architecture.md). Track via [issue #50](https://github.com/litentry/agentKeys/issues/50).
- **TEE-signed OIDC JWT**: replace `agentkeys-oidc-stub` / static-IAM trust with TEE-derive(`oidc/issuer/v1`) + sts:AssumeRoleWithWebIdentity. Depends on heima-gaps §3.
- **Per-address S3 prefix**: currently all inbound lands in `s3://$BUCKET/inbound/`; Stage 6 post-MVP should route to `s3://$BUCKET/<wallet>/<address>/` either via SES Lambda or subdomain routing.
- **Throwaway inbox lifecycle**: currently addresses are unbounded; Stage 6 post-MVP should add TTL + audit-logged revocation.

## Cleanup (if you want to tear down)

```bash
# Disable the active rule set (keeps SES inbound from hitting this bucket)
aws ses set-active-receipt-rule-set --rule-set-name "" --region "$REGION"

# Drop the role
aws iam delete-role-policy --role-name agentkeys-agent --policy-name agentkeys-agent-inline
aws iam delete-role --role-name agentkeys-agent

# Drop the daemon user (list + delete access keys first — can't delete a user with keys)
for KEY in $(aws iam list-access-keys --user-name agentkeys-daemon --query 'AccessKeyMetadata[*].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name agentkeys-daemon --access-key-id "$KEY"
done
aws iam delete-user-policy --user-name agentkeys-daemon --policy-name agentkeys-daemon-assume-role
aws iam delete-user --user-name agentkeys-daemon

# Drop the bucket (contents first)
aws s3 rm "s3://$BUCKET" --recursive
aws s3api delete-bucket --bucket "$BUCKET"

# Delete SES domain identity
aws sesv2 delete-email-identity --region "$REGION" --email-identity "$DOMAIN"

# Domain / hosted zone stays — you're using the existing litentry.org zone.
# Only the Stage 6 records we UPSERTed need cleanup; leave DNS alone unless
# you want to revert SPF/DMARC/MX/DKIM records on bots.litentry.org.
```
