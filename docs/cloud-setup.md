# Cloud setup — AgentKeys

**Audience:** the operator provisioning the cloud account that hosts AgentKeys infrastructure.
**Scope:** one file, every cloud-side resource. Read top-down once per account, then jump back to the section you're touching.

The runbook is split by concern, not by stage:

| § | Concern | When you do this |
|---|---------|------------------|
| [§0 Identities](#0-identities--mental-model) | The four IAM principals and what each one is for | Read first |
| [§1 Domain + DNS](#1-domain--dns) | Email subdomain (Stage 6) + broker subdomain (Stage 7) | Once per account |
| [§2 Inbound mail](#2-inbound-mail-backend) | SES + S3 receipt rule (Stage 6) | Once per account |
| [§3 IAM users + role](#3-iam-identities) | `agentkeys-{admin,broker,daemon}` + `agentkeys-data-role` | Once per account |
| [§4 OIDC federation](#4-oidc-federation-stage-7) | Register the broker as an OIDC provider, swap to PrincipalTag-scoped trust | After §1–§3 + a publicly-reachable broker |
| [§5 EC2 broker host](#5-ec2-broker-host-optional) | EIP, A record, security group | Only if you're hosting the broker on AWS |
| [§6 Signer host](#6-signer-host) | DNS A record + TLS cert + nginx flip for `signer.<zone>` | After §5 — needs `$EIP` |
| [§7 Cleanup](#7-cleanup) | Tear-down recipe | When you want to delete it all |

**Cloud-portability:** §1 (DNS) and §2 (inbound mail) are the cloud-replaceable layers — Tencent Cloud SimpleDM + COS would slot in here unchanged at the §3+ boundary. See [§2.2](#22-future-tencent-cloud-simpledm--cos).

---

## 0. Identities — mental model

| Identity | Type | Holds | Purpose |
|---|---|---|---|
| `agentkeys-admin` | IAM user | Long-lived access key | One-shot provisioning. Runs every command in this doc. IAM-admin scope. |
| `agentkeys-broker` | IAM user | Long-lived access key | Operator's SSH-into-EC2 path via EC2 Instance Connect. No data-plane access. |
| `agentkeys-daemon` | IAM user | Long-lived access key | The **broker process** uses this at runtime. Only permission: `sts:AssumeRole` on `agentkeys-data-role`. |
| `agentkeys-data-role` | IAM role | (assumed) | The actual S3/SES permissions live here. `agentkeys-daemon` (Stage 6) or the OIDC provider (Stage 7) is allowed to assume it. |
| `agentkeys-broker-host` | IAM role | (assumed by EC2) | Optional. If the broker runs on EC2, attach this as the instance profile so the daemon never sees a static key. |

Why "data role" and not "agent role": the project word "agent" already means three things (the AI agent, the AgentKeys product, an IAM role). The role holds **data-plane** permissions, so `agentkeys-data-role` it is. (Renamed from `agentkeys-agent` 2026-04-28; the broker still accepts the legacy `BROKER_AGENT_ROLE_ARN` env var.)

**Prereqs for everything below:**

```bash
# AWS CLI v2 + a working agentkeys-admin profile
awsp agentkeys-admin                                              # set AWS_PROFILE
aws sts get-caller-identity                                       # → agentkeys-admin

# Shell vars used throughout the runbook
export REGION=us-east-1                                           # SES inbound: us-east-1, us-west-2, eu-west-1
export DOMAIN=bots.litentry.org                                   # Stage 6 email subdomain
export BROKER_HOST=broker.litentry.org                            # Stage 7 broker public hostname
export PARENT_ZONE_ID=Z09723983CFJOHAE3VC65                       # existing litentry.org Route 53 zone
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET=agentkeys-mail-${ACCOUNT_ID}                        # global-unique by account-id suffix
echo "REGION=$REGION DOMAIN=$DOMAIN BROKER_HOST=$BROKER_HOST ACCOUNT_ID=$ACCOUNT_ID BUCKET=$BUCKET"
```

> **Why `jq -n --arg` and not `cat > file.json <<EOF`:** `jq --arg` passes values outside shell parameter expansion, sidestepping the zsh modifier bug (`$VAR:r` etc.) that silently corrupts ARNs. JSON is validated on construction, command substitution feeds the result straight into `--policy-document`, no file lands on disk.

---

## 1. Domain + DNS

Two subdomains under the existing `litentry.org` zone — no NS delegation needed because both records live in the parent zone:

- `bots.litentry.org` — agent email subdomain (used by SES inbound).
- `broker.litentry.org` — broker public hostname (TLS-terminating reverse proxy).

If you're using a different parent domain, swap `litentry.org` and `PARENT_ZONE_ID` accordingly. Confirm the zone is reachable before continuing:

```bash
aws route53 get-hosted-zone --id "$PARENT_ZONE_ID" \
  --query 'HostedZone.{name: Name, private: Config.PrivateZone}'
# → {"name": "litentry.org.", "private": false}
```

### 1.1 Email subdomain — DKIM + SPF + DMARC + MX

After §2.1 (SES domain identity) you'll have three DKIM tokens to publish. The block below publishes those plus the standard SPF / DMARC / MX records in one Route 53 change:

```bash
read -r T1 T2 T3 <<<"$(aws sesv2 get-email-identity --region "$REGION" \
  --email-identity "$DOMAIN" --query 'DkimAttributes.Tokens' --output text)"

aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" \
  --change-batch "$(jq -n \
    --arg domain "$DOMAIN" --arg region "$REGION" \
    --arg t1 "$T1" --arg t2 "$T2" --arg t3 "$T3" \
    '{
      Comment: "AgentKeys email infra for \($domain)",
      Changes: [
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t1)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t1).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t2)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t2).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t3)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t3).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$domain, Type:"MX",  TTL:300, ResourceRecords:[{Value:"10 inbound-smtp.\($region).amazonaws.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$domain, Type:"TXT", TTL:300, ResourceRecords:[{Value:"\"v=spf1 include:amazonses.com -all\""}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"_dmarc.\($domain)", Type:"TXT", TTL:300, ResourceRecords:[{Value:"\"v=DMARC1; p=quarantine; rua=mailto:dmarc@\($domain)\""}]}}
      ]
    }')"
```

### 1.2 Broker subdomain — A record to EIP

Done as part of [§5 EC2 broker host](#5-ec2-broker-host-optional), once you know the host's public IP. If the broker lives outside AWS (DigitalOcean, Hetzner, etc.), upsert the A record now using the host's static IP — the rest of the runbook is identical.

### 1.3 Signer subdomain — A record + TLS cert (issue #74 step 1b)

Done as part of [§6 Signer host](#6-signer-host), once `$EIP` is known from [§5.1](#51-allocate--attach-an-elastic-ip).

---

## 2. Inbound mail backend

### 2.1 AWS SES + S3

#### Verify the SES domain identity

```bash
aws sesv2 create-email-identity \
  --region "$REGION" --email-identity "$DOMAIN" \
  --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT
```

Now run [§1.1](#11-email-subdomain--dkim--spf--dmarc--mx) to publish the DKIM/SPF/DMARC/MX records. Wait ~5 min, then:

```bash
aws sesv2 get-email-identity --region "$REGION" --email-identity "$DOMAIN" \
  --query '{verified: VerifiedForSendingStatus, dkim: DkimAttributes.Status}'
# → {"verified": true, "dkim": "SUCCESS"}
```

> **DKIM key custody:** in this interim setup, AWS SES holds the private DKIM key. We never see it. Trust surface: AWS-internal compromise could forge mail signed as us — bounded blast radius (reputation, not user-data custody). Migration target is TEE-held BYODKIM when [`heima-gaps §4`](./spec/heima-gaps-vs-desired-architecture.md) closes; do **not** intermediate-step to "BYODKIM with file-stored key" (strictly worse than AWS-managed).

#### Create the S3 bucket for inbound mail

The bucket policy in [§3.5](#35-s3-bucket-policy) wires SES write + role read; we'll come back to it after the IAM identities exist.

```bash
aws s3api create-bucket \
  --region "$REGION" --bucket "$BUCKET" \
  $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION")

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 30-day TTL on inbound objects (throwaway-inbox model)
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "$(jq -n '{
    Rules: [{ID:"inbound-30d-ttl", Status:"Enabled", Filter:{Prefix:"inbound/"}, Expiration:{Days:30}}]
  }')"
```

#### Create the SES receipt rule

```bash
aws ses create-receipt-rule-set --rule-set-name agentkeys --region "$REGION" 2>/dev/null || true
aws ses create-receipt-rule --region "$REGION" --rule-set-name agentkeys \
  --rule "$(jq -n --arg domain "$DOMAIN" --arg bucket "$BUCKET" '{
    Name: "agentkeys-inbound", Enabled: true, ScanEnabled: true, TlsPolicy: "Optional",
    Recipients: [$domain],
    Actions: [{S3Action: {BucketName: $bucket, ObjectKeyPrefix: "inbound/"}}]
  }')"
aws ses set-active-receipt-rule-set --rule-set-name agentkeys --region "$REGION"
```

Inbound MIME lands at `s3://$BUCKET/inbound/<msg_id>`. The first object you'll see is `inbound/AMAZON_SES_SETUP_NOTIFICATION` — AWS's "I successfully wrote to your bucket" marker. Real test mail follows.

#### Spam handling (read-time filter)

The SES scanners stamp `X-SES-Spam-Verdict` / `X-SES-Virus-Verdict` headers. The provisioner-scripts `ses-s3` adapter drops messages where either is `FAIL`. No write-time Lambda; trivial receipt rule.

#### Sandbox vs production sending

Inbound is unaffected by SES sandbox status. You only need to request production access when the agent **sends** mail to arbitrary addresses (replies, notifications). Console → Support → "Service limit increase" → "SES Sending Limits" → "Request Production Access".

### 2.2 Future: Tencent Cloud SimpleDM + COS

For deployments serving China-region traffic, the analogous backend is:

| Layer | AWS (current) | Tencent Cloud (future) |
|---|---|---|
| Email service | SES (SendRawEmail / receipt rules) | SimpleDM (`SendEmail` + receive-rule policies) |
| Object store | S3 + bucket policy | COS + bucket-policy / CAM role |
| Identity service | IAM users + roles + STS AssumeRole | CAM users + roles + STS AssumeRole |
| OIDC federation | `iam:CreateOpenIDConnectProvider` | CAM `CreateOIDCConfig` |

The provisioner-scripts `email-backends/` interface already abstracts the inbound contract (object key + raw MIME). A Tencent backend slots in as `tencent-simpledm-cos`, with the same upstream API as `ses-s3`. Identity layout in §3 stays unchanged structurally — replace `iam` with `cam` calls. **No work in this runbook depends on AWS specifically except the AWS CLI invocations** — the IAM model maps 1:1 onto CAM.

---

## 3. IAM identities

### 3.1 `agentkeys-daemon` IAM user (broker runtime)

```bash
aws iam create-user --user-name agentkeys-daemon
aws iam create-access-key --user-name agentkeys-daemon
# → save AccessKeyId + SecretAccessKey to your secret manager. NOT to git.

aws iam put-user-policy --user-name agentkeys-daemon \
  --policy-name agentkeys-daemon-assume-role \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow", Action: "sts:AssumeRole",
      Resource: "arn:aws:iam::\($acct):role/agentkeys-data-role"
    }]
  }')"
```

The daemon user can do exactly one thing: assume `agentkeys-data-role`. Any S3/SES action goes through the role's permissions, never the user's.

### 3.2 `agentkeys-data-role`

The role's trust policy starts with the **static-IAM-user** variant (Stage 6). [§4.2](#42-replace-the-roles-trust-policy-federated-variant) swaps it for the OIDC-federated variant once the broker is publicly reachable.

```bash
aws iam create-role --role-name agentkeys-data-role \
  --assume-role-policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: {AWS: "arn:aws:iam::\($acct):user/agentkeys-daemon"},
      Action: "sts:AssumeRole"
    }]
  }')"

aws iam put-role-policy --role-name agentkeys-data-role \
  --policy-name agentkeys-data-role-inline \
  --policy-document "$(jq -n \
    --arg bucket "$BUCKET" --arg region "$REGION" \
    --arg acct "$ACCOUNT_ID" --arg domain "$DOMAIN" \
    '{
      Version: "2012-10-17",
      Statement: [
        {Effect:"Allow", Action:"s3:ListBucket", Resource:"arn:aws:s3:::\($bucket)"},
        {Effect:"Allow", Action:"s3:GetObject",  Resource:"arn:aws:s3:::\($bucket)/*"},
        {Effect:"Allow", Action:"ses:SendRawEmail", Resource:"arn:aws:ses:\($region):\($acct):identity/\($domain)"}
      ]
    }')"

export ROLE_ARN=$(aws iam get-role --role-name agentkeys-data-role --query 'Role.Arn' --output text)
echo "ROLE_ARN=$ROLE_ARN"
```

### 3.3 `agentkeys-admin`, `agentkeys-broker` (already provisioned)

If you've come this far, `agentkeys-admin` exists (you're using it now). `agentkeys-broker` is whatever IAM user you SSH into the broker EC2 with via EC2 Instance Connect — its perms are out of scope here (`ec2-instance-connect:SendSSHPublicKey` on the host's instance ID is sufficient).

### 3.4 `agentkeys-broker-host` instance profile (optional, EC2-only)

If the broker runs on EC2, attach this so the daemon never holds a static key. The host's runtime credentials come from IMDS.

```bash
ROLE_NAME=agentkeys-broker-host

aws iam create-role --role-name $ROLE_NAME \
  --assume-role-policy-document "$(jq -n '{
    Version: "2012-10-17",
    Statement: [{Effect:"Allow", Principal:{Service:"ec2.amazonaws.com"}, Action:"sts:AssumeRole"}]
  }')"

aws iam put-role-policy --role-name $ROLE_NAME --policy-name BrokerAssumeData \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version: "2012-10-17",
    Statement: [{Effect:"Allow", Action:"sts:AssumeRole",
                 Resource:"arn:aws:iam::\($acct):role/agentkeys-data-role"}]
  }')"

aws iam create-instance-profile --instance-profile-name $ROLE_NAME
aws iam add-role-to-instance-profile --instance-profile-name $ROLE_NAME --role-name $ROLE_NAME
aws ec2 associate-iam-instance-profile --region "$REGION" \
  --instance-id <broker-host-instance-id> \
  --iam-instance-profile Name=$ROLE_NAME
```

### 3.4a `ses:SendEmail` grant on the broker's runtime role (Pass 2 prereq)

The broker calls SES v2 `SendEmail` with its **own** runtime credentials
(instance profile), NOT via the assumed `agentkeys-data-role`. Without
`ses:SendEmail` on the broker's role the operator hits:

```
broker rejected /v1/auth/email/request: status=502 body=
{"error":"backend_unreachable","message":"… ses SendEmail:
 unhandled error (AccessDeniedException)"}
```

The IAM action is `ses:SendEmail` (sesv2) — NOT `ses:SendRawEmail` (v1
only; different code path the broker doesn't use).

**Step 1: discover the actual role name attached to your broker host.**
On a fresh setup following §3.4 above, this is `agentkeys-broker-host`.
Existing/legacy deploys may use a different name (e.g. an ad-hoc
`S3-full-access` from initial provisioning). Find it:

```bash
# By the broker host's elastic IP (replace 1.2.3.4 with $EIP):
ROLE=$(aws ec2 describe-instances \
  --filters "Name=ip-address,Values=1.2.3.4" \
  --query 'Reservations[].Instances[].IamInstanceProfile.Arn' \
  --output text | sed 's|.*instance-profile/||')
ROLE=$(aws iam get-instance-profile --instance-profile-name "$ROLE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)
echo "broker runtime role: $ROLE"
```

**Step 2: grant `ses:SendEmail` against the verified sender identity.**

```bash
aws iam put-role-policy --role-name "$ROLE" \
  --policy-name BrokerSendEmail \
  --policy-document "$(jq -n \
    --arg region "$REGION" --arg acct "$ACCOUNT_ID" --arg domain "$MAIL_DOMAIN" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Action: "ses:SendEmail",
      Resource: [
        "arn:aws:ses:\($region):\($acct):identity/\($domain)",
        "arn:aws:ses:\($region):\($acct):identity/*@\($domain)"
      ]
    }]
  }')"
```

No broker restart needed — sesv2 picks up creds per-call. Verify:

```bash
aws iam get-role-policy --role-name "$ROLE" --policy-name BrokerSendEmail \
  --query 'PolicyDocument.Statement[*].Action'
# → [["ses:SendEmail"]]
```

### 3.5 S3 bucket policy

Now that `agentkeys-data-role` exists, attach the bucket policy. The static-IAM-user variant: SES writes inbound, role reads everything.

```bash
aws s3api put-bucket-policy --bucket "$BUCKET" \
  --policy "$(jq -n --arg bucket "$BUCKET" --arg acct "$ACCOUNT_ID" '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "AllowSESWriteInbound", Effect: "Allow",
        Principal: {Service: "ses.amazonaws.com"},
        Action: "s3:PutObject",
        Resource: "arn:aws:s3:::\($bucket)/*",
        Condition: {StringEquals: {"aws:Referer": $acct}}
      },
      {
        Sid: "AllowDaemonRead", Effect: "Allow",
        Principal: {AWS: "arn:aws:iam::\($acct):role/agentkeys-data-role"},
        Action: ["s3:GetObject", "s3:ListBucket"],
        Resource: ["arn:aws:s3:::\($bucket)", "arn:aws:s3:::\($bucket)/*"]
      }
    ]
  }')"
```

The federated variant (PrincipalTag-scoped) lands in [§4.3](#43-upgrade-bucket-policy-to-principaltag-scoped).

---

## 4. OIDC federation (Stage 7)

Replaces the `agentkeys-daemon → AssumeRole` path in §3.2 with `OIDC-broker-JWT → AssumeRoleWithWebIdentity`. The benefit: per-user isolation enforced **inside AWS** (via PrincipalTag on the assumed session), not just by the daemon's app code.

### 4.1 Prereqs

- §1–§3 done.
- Broker reachable at `https://$BROKER_HOST` over public TLS (see [§5](#5-ec2-broker-host-optional) for the EC2 wiring + `scripts/setup-broker-host.sh` for the host bootstrap).
- The broker's discovery doc agrees with `$BROKER_HOST` byte-for-byte:
  ```bash
  export OIDC_ISSUER="https://$BROKER_HOST"
  curl -sS --fail-with-body "$OIDC_ISSUER/.well-known/openid-configuration" | jq -e ".issuer == \"$OIDC_ISSUER\""
  # → true
  ```
  If `false`, fix the broker's `BROKER_OIDC_ISSUER` env var before continuing — AWS validates the registered URL against the JWT `iss` claim byte-for-byte (no scheme, trailing slash, or hostname-only forms allowed):
  ```bash
  sudo sed -i \
    "s|^Environment=BROKER_OIDC_ISSUER=.*|Environment=BROKER_OIDC_ISSUER=$OIDC_ISSUER|" \
    /etc/systemd/system/agentkeys-broker.service
  sudo systemctl daemon-reload && sudo systemctl restart agentkeys-broker
  ```

### 4.2 Register the OIDC provider

Pre-check for stale state from earlier bring-ups:

```bash
aws iam list-open-id-connect-providers
```

- Empty list → fresh slate; proceed.
- ARN ends in `$BROKER_HOST` → already registered; skip the create, jump to the trust-policy update.
- ARN ends in a different host → delete, then register the correct one:
  ```bash
  aws iam delete-open-id-connect-provider \
    --open-id-connect-provider-arn arn:aws:iam::${ACCOUNT_ID}:oidc-provider/<stale-host>
  ```

Register:

```bash
aws iam create-open-id-connect-provider \
  --url "$OIDC_ISSUER" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list ''
export OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/$BROKER_HOST"

aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" \
  --query '{Url: Url, ClientIDList: ClientIDList}'
# → {"Url": "https://broker.litentry.org", "ClientIDList": ["sts.amazonaws.com"]}
```

AWS auto-derives the cert thumbprint from the Let's Encrypt chain. The thumbprint stays valid across cert renewals because LE uses a stable intermediate CA.

### 4.3 Replace the role's trust policy (federated variant)

Principal flips from `agentkeys-daemon` to the OIDC provider; the `sts:TagSession` + `aws:RequestTag/agentkeys_user_wallet` condition is what cloud-enforces per-user isolation in [§4.4](#44-upgrade-bucket-policy-to-principaltag-scoped).

```bash
aws iam update-assume-role-policy --role-name agentkeys-data-role \
  --policy-document "$(jq -n \
    --arg provider "$OIDC_PROVIDER_ARN" \
    --arg aud_key "${BROKER_HOST}:aud" \
    '{
      Version: "2012-10-17",
      Statement: [{
        Effect: "Allow",
        Principal: {Federated: $provider},
        Action: ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
        Condition: {
          StringEquals: {($aud_key): "sts.amazonaws.com"},
          Null: {"aws:RequestTag/agentkeys_user_wallet": "false"}
        }
      }]
    }')"
```

`Null: "false"` enforces tag presence ("the key MUST exist"). Do **not** use `StringNotEquals: {"aws:RequestTag/agentkeys_user_wallet": ""}` — AWS evaluates negated string operators on missing context keys as TRUE ("the missing key is not equal to anything"), so a JWT carrying no AWS tags claim would silently bypass the check. The `Null` operator rejects sessions where the tag isn't set at all, which is the only enforcement the trust policy can give you.

### 4.4 Upgrade bucket policy to PrincipalTag-scoped

Replaces `AllowDaemonRead` from §3.5. The cloud now enforces "the assumed session can only touch the prefix matching its PrincipalTag" — even if app code has a bug.

The daemon's read perms split into two statements because `s3:prefix` is a request-time condition that **only applies to `s3:ListBucket`** (the prefix filter on listings) — `s3:GetObject` doesn't carry a prefix parameter, so combining the two actions under one `s3:prefix` condition triggers `MalformedPolicy: Conditions do not apply to combination of actions and resources in statement`. For `GetObject` the resource ARN itself enforces the prefix via `${aws:PrincipalTag/...}` expansion.

```bash
aws s3api put-bucket-policy --bucket "$BUCKET" \
  --policy "$(jq -n --arg bucket "$BUCKET" --arg acct "$ACCOUNT_ID" '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "AllowSESWriteInbound", Effect: "Allow",
        Principal: {Service: "ses.amazonaws.com"},
        Action: "s3:PutObject",
        Resource: "arn:aws:s3:::\($bucket)/*",
        Condition: {StringEquals: {"aws:Referer": $acct}}
      },
      {
        Sid: "AllowDaemonListOwnPrefix", Effect: "Allow",
        Principal: {AWS: "arn:aws:iam::\($acct):role/agentkeys-data-role"},
        Action: "s3:ListBucket",
        Resource: "arn:aws:s3:::\($bucket)",
        Condition: {
          StringLike: {"s3:prefix": "${aws:PrincipalTag/agentkeys_user_wallet}/*"}
        }
      },
      {
        Sid: "AllowDaemonGetOwnObjects", Effect: "Allow",
        Principal: {AWS: "arn:aws:iam::\($acct):role/agentkeys-data-role"},
        Action: "s3:GetObject",
        Resource: "arn:aws:s3:::\($bucket)/${aws:PrincipalTag/agentkeys_user_wallet}/*"
      }
    ]
  }')"
```

`StringLike "${tag}/*"` (not `StringEquals "${tag}/"`) lets the daemon list sub-prefixes like `<wallet>/inbox/` and `<wallet>/sent/2026-05/`, not just the exact root `<wallet>/`. Matches the shape in [`docs/spec/ses-email-architecture.md` §10.4](spec/ses-email-architecture.md) and [`wiki/tag-based-access`](../wiki/tag-based-access.md).

### 4.4.1 Strip the §3 broad-bucket grant from the role's inline policy

**Critical for §4.5 to actually demonstrate isolation.** §3.2's `agentkeys-data-role-inline` grants the role broad `s3:GetObject` + `s3:ListBucket` on the entire bucket — necessary in the static-IAM path (no PrincipalTag to scope on) but **fatal** here: IAM evaluates as union-of-allows, so this identity-based grant overrides §4.4's bucket-policy isolation. Without this step, §4.5's 4b test will silently succeed instead of correctly returning `AccessDenied` — federation appears to work while the cloud is enforcing nothing.

Inspect what's currently attached:

```bash
aws iam get-role-policy --profile agentkeys-admin \
  --role-name agentkeys-data-role \
  --policy-name agentkeys-data-role-inline \
  --query 'PolicyDocument'
```

Re-apply, omitting the S3 statement. Keep any non-S3 statements (the daemon needs the `ses:SendRawEmail` grant for outbound mail in §3):

```bash
aws iam put-role-policy --profile agentkeys-admin \
  --role-name agentkeys-data-role \
  --policy-name agentkeys-data-role-inline \
  --policy-document "$(jq -n --arg ses_domain "${MAIL_DOMAIN:-bots.litentry.org}" '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Action: "ses:SendRawEmail",
      Resource: "*",
      Condition: {
        StringLike: {"ses:FromAddress": "*@\($ses_domain)"}
      }
    }]
  }')"
```

If your inline policy had additional non-S3 statements, include them here too.

Verify the S3 actions are gone:

```bash
aws iam get-role-policy --profile agentkeys-admin \
  --role-name agentkeys-data-role \
  --policy-name agentkeys-data-role-inline \
  --query 'PolicyDocument.Statement[*].Action'
# → [["ses:SendRawEmail"]]
```

If the daemon doesn't need any non-S3 grants, delete the inline policy entirely instead:

```bash
aws iam delete-role-policy --profile agentkeys-admin \
  --role-name agentkeys-data-role \
  --policy-name agentkeys-data-role-inline
```

### 4.5 End-to-end proof

Mint a JWT, assume the role with it, prove that wallet A can read its own prefix but **not** wallet B's. The minting half must run **on the broker host** (the prod broker validates session bearers against its *own* local backend on `127.0.0.1:8090`, not against any backend reachable from your operator workstation). The AWS-side half runs on your operator workstation where your admin AWS profile lives.

**Env-var scope** — `$ACCOUNT_ID`, `$BROKER_HOST`, `$OIDC_ISSUER`, `$OIDC_PROVIDER_ARN`, `$BUCKET` only exist on your operator workstation (set up in [§0](#0-identities--mental-model)). The broker host has none of them. Part A below references `$BROKER_HOST` once — in the SSH command itself, where it's expanded by your local shell *before* SSH connects — and otherwise uses **only** literal `127.0.0.1` URLs inside the SSH session. Don't try to re-export the §0 vars on the broker host; none of them are needed there.

#### Part A — on the broker host (mint the JWT)

```bash
# === Run on your operator workstation ===
# ($BROKER_HOST is expanded locally before ssh runs — the broker host
# never sees this var. If $BROKER_HOST isn't set, replace with the
# literal hostname, e.g. broker.litentry.org.)
ssh agentkey@$BROKER_HOST    # or via: aws ec2-instance-connect ssh --instance-id <id>

# === The rest runs inside the SSH session, on the broker host ===
# No workstation env vars are visible here. Both URLs are literals.
SESSION=$(curl -sS --fail-with-body -X POST http://127.0.0.1:8090/session/create \
  -H 'content-type: application/json' \
  -d '{"auth_token":"federation-proof"}' | jq -r .session)

JWT=$(curl -sS --fail-with-body -X POST http://127.0.0.1:8091/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION" | jq -r .jwt)

echo "$JWT"
# Copy the entire string. JWT TTL is ~5 min; copy and proceed promptly.
exit
```

#### Part B — on your operator workstation (assume role + verify isolation)

All env vars below (`$ACCOUNT_ID`, `$BUCKET`) are workstation-side from §0. Run after `exit`-ing the SSH session.

```bash
JWT="<paste the JWT from Part A>"

# Decode the wallet from the payload. JWT segments are base64url-encoded
# (RFC 7515) — jq's @base64d is strict base64, so we url→std + add padding
# before decoding. Skipping this works on most JWTs by accident; when the
# payload base64 happens to contain - or _, it fails with a "Malformed BOM"
# error.
WALLET=$(jq -R 'split(".") | .[1] | gsub("-";"+") | gsub("_";"/") |
  . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson | .agentkeys_user_wallet' <<<"$JWT" -r)
echo "WALLET=$WALLET"

CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role" \
  --role-session-name "fed-proof-$(date +%s)" \
  --web-identity-token "$JWT")
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r .Credentials.SessionToken)

# Confirm you're the assumed role, not your admin profile
aws sts get-caller-identity
# → Arn: arn:aws:sts::...:assumed-role/agentkeys-data-role/fed-proof-...

# 4a. Own prefix — should succeed (empty list is fine, no AccessDenied)
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$WALLET/"

# 4b. KEY MOMENT — someone else's prefix MUST AccessDenied
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "0xdeadbeef/"
# → AccessDenied
```

Step 4b is the property the static-IAM path (§3) cannot prove: cloud-enforced isolation, zero app-side trust required.

#### Diagnosing intermediate states

If both 4a and 4b succeed, §4.4.1 wasn't applied — the inline-policy `s3:*` grant is still masking the bucket policy. Re-run §4.4.1 and verify `Statement[*].Action` returns only `ses:SendRawEmail`.

If both 4a and 4b deny (including 4a, your *own* prefix), the broker's JWT isn't carrying the `https://aws.amazon.com/tags` claim, so STS sets no PrincipalTag on the assumed session, so `${aws:PrincipalTag/agentkeys_user_wallet}` in the bucket policy expands to empty and matches nothing. Decode the JWT to confirm:

```bash
jq -R 'split(".") | .[1] | gsub("-";"+") | gsub("_";"/") |
  . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson' <<<"$JWT"
```

Look for a top-level `https://aws.amazon.com/tags` key with `principal_tags.agentkeys_user_wallet` populated. If it's missing, the broker version doesn't yet emit the AWS tags claim and needs to be redeployed.

### 4.6 (Future) TEE-derived signer swap

The on-disk ES256 keypair shipped today is a complete v0.1 signer. When [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md) closes, swap [`crates/agentkeys-broker-server/src/oidc.rs::OidcKeypair::load_or_generate`](../crates/agentkeys-broker-server/src/oidc.rs) for a TEE oracle call. JWKS, JWT shape, STS exchange, and bucket policy stay identical — only the signing backend changes.

---

## 5. EC2 broker host (optional)

If the broker runs on EC2 (the recommended path for AWS-native deployments), wire DNS + EIP + security group before running [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh) on the box.

### 5.1 Allocate + attach an Elastic IP

```bash
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --region "$REGION" --query AllocationId --output text)
aws ec2 associate-address --region "$REGION" \
  --instance-id <broker-instance-id> --allocation-id "$EIP_ALLOC"
EIP=$(aws ec2 describe-addresses --region "$REGION" \
  --allocation-ids "$EIP_ALLOC" --query 'Addresses[0].PublicIp' --output text)
echo "EIP=$EIP"
```

### 5.2 Wire the A record

```bash
aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" \
  --change-batch "$(jq -n --arg name "$BROKER_HOST." --arg ip "$EIP" '{
    Changes: [{
      Action: "UPSERT",
      ResourceRecordSet: {Name: $name, Type: "A", TTL: 300, ResourceRecords: [{Value: $ip}]}
    }]
  }')"

# Verify (use DoH if your local resolver hijacks port 53)
curl -s "https://cloudflare-dns.com/dns-query?name=$BROKER_HOST&type=A" \
  -H 'accept: application/dns-json' | jq '.Answer[0].data'
```

### 5.3 Open security-group ports 80 + 443

Let's Encrypt's HTTP-01 challenge needs port 80 open from anywhere; the broker serves on 443 afterward. SSH (22) should be admin-IP-only.

```bash
INSTANCE_ID=<broker-instance-id>
SG=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)

aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --protocol tcp --port 80  --cidr 0.0.0.0/0
```

### 5.4 Bootstrap the host

SSH in as `agentkeys-broker` (via EC2 Instance Connect: `aws ec2-instance-connect ssh --instance-id $INSTANCE_ID`) and run:

```bash
git clone https://github.com/litentry/agentKeys.git
cd agentKeys
sudo bash scripts/setup-broker-host.sh
# Interactive walk-through; pick instance-profile credential mode
# (assuming §3.4 attached agentkeys-broker-host).
```

The script writes systemd units, an HTTP-only nginx config, then prints the certbot command. After cert issuance, re-run the script — it detects the cert file and flips on the `:443` ssl block.

---

## 6. Signer host

| Concern | Today | Future |
|---|---|---|
| Process | `agentkeys-signer.service` (Rust, `agentkeys-mock-server --signer-only`, loopback `:8092`) | TEE worker (issue #74 step 2) |
| Host | **Same EC2 box as the broker** — co-located behind the same nginx, provisioned by the same `setup-broker-host.sh` run | Separate machine (or enclave); only the A record + cert move |
| Public hostname | `signer.<zone>` (e.g. `signer.litentry.org`) — exported as `SIGNER_HOST` / `AGENTKEYS_SIGNER_URL` in [`scripts/operator-workstation.env`](../scripts/operator-workstation.env) | `signer.<zone>` (unchanged) |
| Endpoints | `/dev/derive-address`, `/dev/sign-message`, `/healthz` only — every request bearer-JWT-authed against the broker session pubkey ([`signer-protocol.md`](spec/signer-protocol.md)) | unchanged |
| Master secret (K3) | `/etc/agentkeys/dev-key-service.env` (mode 0600, owner `agentkeys`) — auto-generated on first `setup-broker-host.sh` run, **never rotated** (rotation invalidates every previously-derived wallet) | TEE-sealed; same wire shape |

### 6.1 DNS A record

```bash
# === ON OPERATOR WORKSTATION ===
SIGNER_HOST="signer.${BROKER_HOST#*.}"

# If $EIP isn't already set from §5.1, re-derive from AWS — NEVER from
# `dig`. Local resolvers behind Cloudflare WARP / Zscaler / Tailscale /
# corporate VPNs return RFC 2544 "TEST-NET-2" (198.18.0.0/15) for
# proxied hostnames, which silently breaks Let's Encrypt validation.
[ -z "$EIP" ] && EIP=$(aws ec2 describe-addresses --region "$REGION" \
  --query 'Addresses[?AssociationId!=`null`].PublicIp' --output text)
echo "EIP=$EIP"   # MUST be a routable public IP, not 198.18.x.x / 10.x.x.x / 100.64.x.x

aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" \
  --change-batch "$(jq -n --arg name "${SIGNER_HOST}." --arg ip "$EIP" '{
    Changes: [{Action:"UPSERT", ResourceRecordSet:{Name:$name, Type:"A", TTL:300, ResourceRecords:[{Value:$ip}]}}]
  }')"

# Verify via Cloudflare DoH (your local resolver will keep lying if proxied).
until [ "$(curl -s "https://cloudflare-dns.com/dns-query?name=${SIGNER_HOST}&type=A" \
            -H 'accept: application/dns-json' | jq -r '.Answer[0].data')" = "$EIP" ]; do
  echo "waiting for Route 53 propagation (TTL 300s)…"; sleep 5
done
echo "DNS ready: ${SIGNER_HOST} → ${EIP}"
```

### 6.2 TLS cert + nginx flip

> **`$SIGNER_HOST` is laptop-only** (lives in `operator-workstation.env`).
> On the broker host, derive it from the nginx vhost that `setup-broker-host.sh`
> just wrote — the snippet below does it inline so the commands work in a
> fresh broker shell with no env vars set.

```bash
# === ON BROKER HOST ===
# 1. First pass writes the HTTP-only nginx vhost for signer.<zone>.
sudo bash scripts/setup-broker-host.sh --yes

# Sanity-check + read the hostname back out of the vhost.
ls /etc/nginx/sites-enabled/agentkeys-signer
SIGNER_HOST=$(awk '/server_name/ && /signer\./ {gsub(";",""); print $2}' \
                /etc/nginx/sites-available/agentkeys-signer | head -1)
echo "SIGNER_HOST=$SIGNER_HOST"

# 2. Issue the LE cert. If the prompt only lists broker.<zone>, the
# signer vhost wasn't written — re-pull + re-run step 1.
sudo certbot --nginx -d "$SIGNER_HOST"

# 3. Re-run to flip the signer vhost onto :443 ssl.
sudo bash scripts/setup-broker-host.sh --yes
```

### 6.3 Verify

```bash
# === ON OPERATOR WORKSTATION ===
curl -sS "https://$SIGNER_HOST/healthz"
# ok

# Defense-in-depth: signer vhost rejects everything except /dev/* + /healthz.
curl -sS -o /dev/null -w '%{http_code}\n' "https://$SIGNER_HOST/session/create"
# 404
```

---

## 7. Cleanup

```bash
# OIDC federation (if §4 ran)
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" 2>/dev/null

# IAM
aws iam delete-role-policy --role-name agentkeys-data-role --policy-name agentkeys-data-role-inline
aws iam delete-role        --role-name agentkeys-data-role
for KEY in $(aws iam list-access-keys --user-name agentkeys-daemon --query 'AccessKeyMetadata[*].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name agentkeys-daemon --access-key-id "$KEY"
done
aws iam delete-user-policy --user-name agentkeys-daemon --policy-name agentkeys-daemon-assume-role
aws iam delete-user        --user-name agentkeys-daemon

# Optional: the broker-host instance profile
aws iam remove-role-from-instance-profile --instance-profile-name agentkeys-broker-host --role-name agentkeys-broker-host 2>/dev/null
aws iam delete-instance-profile --instance-profile-name agentkeys-broker-host 2>/dev/null
aws iam delete-role-policy --role-name agentkeys-broker-host --policy-name BrokerAssumeData 2>/dev/null
aws iam delete-role        --role-name agentkeys-broker-host 2>/dev/null

# SES + S3
aws ses set-active-receipt-rule-set --rule-set-name "" --region "$REGION"
aws sesv2 delete-email-identity --region "$REGION" --email-identity "$DOMAIN"
aws s3 rm "s3://$BUCKET" --recursive
aws s3api delete-bucket --bucket "$BUCKET"

# DNS records on the parent zone are NOT auto-deleted — you'll need to
# remove the DKIM CNAMEs, MX, SPF, DMARC, and broker A record by hand
# if you want a clean zone.
```

---

## Follow-ups tracked elsewhere

- **TEE-BYODKIM** — replace AWS-managed DKIM. Depends on [`heima-gaps §4`](./spec/heima-gaps-vs-desired-architecture.md).
- **TEE-derived OIDC signer** — replace on-disk ES256. Depends on [`heima-gaps §3`](./spec/heima-gaps-vs-desired-architecture.md).
- **Per-address S3 prefix routing** — currently all inbound lands in `inbound/`; per-`<wallet>/<address>/` prefix routing wants either a SES Lambda or subdomain receipt rules.
- **GCP / Tencent recipes** — equivalent of §4 against GCP Workload Identity Federation and Tencent CAM. JWT/JWKS shape works cross-cloud unchanged; only the registration step differs.
