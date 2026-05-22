# Cloud bootstrap — AgentKeys

**Audience:** the operator standing up a brand-new cloud account to host AgentKeys for the first time, or porting the deployment to a new cloud provider (AliCloud, GCP, Tencent Cloud).
**Scope:** the per-account, run-once provisioning that has to happen **before** anything in [`docs/cloud-setup.md`](cloud-setup.md), [`docs/heima-setup.md`](heima-setup.md), or [`docs/ci-setup.md`](ci-setup.md) can run. Identifiers (DNS names, IAM principals, mail backend, object store, initial bucket policy) — never runtime processes.
**FAQ + troubleshooting:** [`wiki/cloud-setup-faq.md`](../wiki/cloud-setup-faq.md).

After this doc is run, the operator returns here ONLY when:
- Switching cloud providers (e.g. AWS → AliCloud)
- Adding a second AWS account (test instance, regional shard)
- Re-bootstrapping after a teardown
- Auditing the identity surface (the security-audit checklist in §7)

The day-to-day broker re-deploys live in [`docs/cloud-setup.md`](cloud-setup.md) §5 (`setup-broker-host.sh`); they never re-enter this doc.

## TL;DR — operator flow

The idempotent one-shot orchestrator [`scripts/setup-cloud.sh`](../scripts/setup-cloud.sh) walks every step in this doc end-to-end. Same posture as `setup-broker-host.sh` + `setup-heima.sh`: every step pre-checks state and short-circuits when the work is already a no-op.

```bash
# 1. Configure env on the operator's workstation:
cp scripts/operator-workstation.env.example scripts/operator-workstation.env   # if not already done
$EDITOR scripts/operator-workstation.env                                       # fill in ACCOUNT_ID, REGION, ZONE, PARENT_ZONE_ID, BROKER_HOST, MAIL_DOMAIN, BUCKET

# 2. Run the orchestrator (~12 steps, idempotent, ~3 min on a fresh account):
awsp agentkeys-admin
AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh --yes

# 3. Launch an EC2 (operator decides instance type + image + key pair) and:
aws ec2 associate-address --region "$REGION" --instance-id <id> --public-ip <EIP-from-step-2>

# 4. SSH to the host, clone the repo, then:
sudo bash scripts/setup-broker-host.sh --issuer-url "https://${BROKER_HOST}" --account-id "${ACCOUNT_ID}" --yes
```

For surgical re-runs after a fix: `bash scripts/setup-cloud.sh --only-step N` (see step list below).

```
§1  Identities         — four IAM principals; concept first, then provider commands
§2  Domain + DNS       — subdomain ownership; parent-zone confirmation
§3  Email backend      — SES domain identity + receipt rule + S3 inbound bucket
§4  IAM users + roles  — agentkeys-{admin,broker,daemon} + agentkeys-data-role
§5  Bucket policy      — static-IAM variant (pre-OIDC; replaced in cloud-setup.md §1)
§6  Instance profile   — agentkeys-broker-host (optional, EC2-only)
§7  Security audit     — strip legacy over-broad attached policies
§8  Cloud portability  — AWS → AliCloud / GCP / Tencent Cloud mapping
```

### Required env (in `scripts/operator-workstation.env`)

| Variable | Example | Used by |
|---|---|---|
| `ACCOUNT_ID` | `429071895007` | every step |
| `REGION` | `us-east-1` | SES + S3 + IAM regional calls |
| `ZONE` | `litentry.org` | parent DNS zone |
| `PARENT_ZONE_ID` | `Z09723983CFJOHAE3VC65` | Route 53 zone ID for `$ZONE` |
| `BROKER_HOST` | `broker.litentry.org` | OIDC issuer hostname |
| `MAIL_DOMAIN` | `bots.litentry.org` | SES inbound subdomain (must differ from broker; the SES receipt rule routes ALL `*@$MAIL_DOMAIN`) |
| `BUCKET` | `agentkeys-mail-${ACCOUNT_ID}` | inbound mail bucket |
| `VAULT_BUCKET` / `MEMORY_BUCKET` | `agentkeys-vault-${ACCOUNT_ID}` / `agentkeys-memory-${ACCOUNT_ID}` | per-data-class buckets (arch.md §17) |

`setup-cloud.sh` validates each at step 2 and dies with a precise pointer if missing.

> **Why `jq -n --arg` and not `cat > file.json <<EOF`:** `jq --arg` passes values outside shell parameter expansion, sidestepping the zsh modifier bug (`$VAR:r` etc.) that silently corrupts ARNs. JSON is validated on construction, command substitution feeds straight into `--policy-document`, no file lands on disk. The orchestrator + every helper script applies this convention.

## §1 Identities — mental model

Cloud-agnostic. The four principals exist in every cloud the broker runs on; the cloud changes only which API creates them.

| Identity | Type | Holds | Purpose |
|---|---|---|---|
| `agentkeys-admin` | privileged user | Long-lived access key | One-shot provisioning. Runs every command in this doc. IAM-admin scope. |
| `agentkeys-broker` | scoped user | Long-lived access key | Operator's SSH-into-EC2 path via EC2 Instance Connect (AWS) / SSH key (other clouds). No data-plane access. |
| `agentkeys-daemon` | runtime user | Long-lived access key | The **broker process** uses this at runtime. Only permission: assume the data role. |
| `agentkeys-data-role` | assumed role | (none — assumed) | Holds the actual storage + email permissions. Trusted by the runtime user (Stage 6) or by the OIDC provider (Stage 7). |
| `agentkeys-broker-host` | instance profile (optional) | (none — bound to a VM) | If the broker runs on a managed VM, attach this so the daemon never sees a static key. Runtime creds come from IMDS / metadata server. |

> Why "data role" and not "agent role": the project word "agent" already means three things (the AI agent, the AgentKeys product, an IAM role). The role holds **data-plane** permissions. The broker still accepts the legacy `BROKER_AGENT_ROLE_ARN` env var for backwards compatibility.

## §2 Domain + DNS

Six subdomains under the operator's parent zone (substitute `${ZONE}` everywhere):

| Host | Purpose | Provisioned in |
|---|---|---|
| `${MAIL_DOMAIN}` (e.g. `bots.${ZONE}`) | SES / email backend inbound | §3 |
| `${BROKER_HOST}` (e.g. `broker.${ZONE}`) | Broker public reverse proxy | §5.1 of cloud-setup.md |
| `signer.${ZONE}` | Signer service (issue #74 step 1b) | §5.1 of cloud-setup.md |
| `audit.${ZONE}` / `email.${ZONE}` / `cred.${ZONE}` / `memory.${ZONE}` | Service workers (issue #90) | §5.1 of cloud-setup.md (dev co-location on broker EIP today) |

Confirm the parent zone is reachable before any record changes (AWS Route 53 example; the same `get-hosted-zone` shape exists on AliCloud DNS + Cloud DNS):

```bash
aws route53 get-hosted-zone --id "$PARENT_ZONE_ID" \
  --query 'HostedZone.{name:Name, private:Config.PrivateZone}'
# → {"name": "${ZONE}.", "private": false}
```

The bulk service-worker A-record creation is automated by [`scripts/dns-upsert-workers.sh`](../scripts/dns-upsert-workers.sh) (AWS Route 53 today). For other providers, replicate the same shape — the hostnames are the migration seam.

## §3 Email backend

### §3.1 Verify the SES domain identity (AWS)

```bash
aws sesv2 create-email-identity \
  --region "$REGION" --email-identity "$MAIL_DOMAIN" \
  --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT
```

Then publish DKIM + SPF + DMARC + MX records in one DNS change. AWS Route 53:

```bash
read -r T1 T2 T3 <<<"$(aws sesv2 get-email-identity --region "$REGION" \
  --email-identity "$MAIL_DOMAIN" --query 'DkimAttributes.Tokens' --output text)"

aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" \
  --change-batch "$(jq -n \
    --arg domain "$MAIL_DOMAIN" --arg region "$REGION" \
    --arg t1 "$T1" --arg t2 "$T2" --arg t3 "$T3" '{
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

Wait ~5 min for DKIM propagation, then verify:

```bash
aws sesv2 get-email-identity --region "$REGION" --email-identity "$MAIL_DOMAIN" \
  --query '{verified: VerifiedForSendingStatus, dkim: DkimAttributes.Status}'
# → {"verified": true, "dkim": "SUCCESS"}
```

> **DKIM key custody:** in this interim setup, the email service holds the private DKIM key (AWS-internal on SES, AliCloud-internal on DirectMail, etc.). Trust surface = provider could forge mail signed as us → bounded blast radius (reputation, not user-data custody). Migration target is TEE-held BYODKIM — track in [`docs/spec/heima-gaps-vs-desired-architecture.md`](spec/heima-gaps-vs-desired-architecture.md) §4. Do **not** intermediate-step to "BYODKIM with file-stored key" (strictly worse than provider-managed).

### §3.2 Create the S3 bucket for inbound mail

```bash
aws s3api create-bucket \
  --region "$REGION" --bucket "$BUCKET" \
  $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION")

aws s3api put-public-access-block --region "$REGION" --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 30-day TTL on inbound objects (throwaway-inbox model)
aws s3api put-bucket-lifecycle-configuration --region "$REGION" --bucket "$BUCKET" \
  --lifecycle-configuration "$(jq -n '{
    Rules: [{ID:"inbound-30d-ttl", Status:"Enabled", Filter:{Prefix:"inbound/"}, Expiration:{Days:30}}]
  }')"
```

### §3.3 Create the SES receipt rule

```bash
aws ses create-receipt-rule-set --rule-set-name agentkeys --region "$REGION" 2>/dev/null || true
aws ses create-receipt-rule --region "$REGION" --rule-set-name agentkeys \
  --rule "$(jq -n --arg domain "$MAIL_DOMAIN" --arg bucket "$BUCKET" '{
    Name: "agentkeys-inbound", Enabled: true, ScanEnabled: true, TlsPolicy: "Optional",
    Recipients: [$domain],
    Actions: [{S3Action: {BucketName: $bucket, ObjectKeyPrefix: "inbound/"}}]
  }')"
aws ses set-active-receipt-rule-set --rule-set-name agentkeys --region "$REGION"
```

Inbound MIME lands at `s3://$BUCKET/inbound/<msg_id>`. First object: `AMAZON_SES_SETUP_NOTIFICATION` (provider's "I successfully wrote to your bucket" marker). Real mail follows.

**Sandbox vs production sending:** inbound is unaffected by SES sandbox; **outbound** to arbitrary addresses needs Console → Support → "SES Sending Limits" → "Request Production Access".

## §4 IAM users + roles

### §4.1 `agentkeys-daemon` — broker runtime user

```bash
aws iam create-user --user-name agentkeys-daemon
aws iam create-access-key --user-name agentkeys-daemon
# → save AccessKeyId + SecretAccessKey to your secret manager. NEVER to git.

aws iam put-user-policy --user-name agentkeys-daemon \
  --policy-name agentkeys-daemon-assume-role \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow", Action:"sts:AssumeRole",
      Resource:"arn:aws:iam::\($acct):role/agentkeys-data-role"
    }]
  }')"
```

The daemon user can do exactly one thing: assume `agentkeys-data-role`. Any storage / email action goes through the role's permissions, never the user's.

### §4.2 `agentkeys-data-role` (static-IAM-user trust variant)

The role's trust policy starts with the static-IAM-user variant. After the broker is publicly reachable, [`docs/cloud-setup.md`](cloud-setup.md) §4 swaps it for the OIDC-federated variant.

```bash
aws iam create-role --role-name agentkeys-data-role \
  --assume-role-policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{AWS:"arn:aws:iam::\($acct):user/agentkeys-daemon"},
      Action:"sts:AssumeRole"
    }]
  }')"

aws iam put-role-policy --role-name agentkeys-data-role \
  --policy-name agentkeys-data-role-inline \
  --policy-document "$(jq -n \
    --arg bucket "$BUCKET" --arg region "$REGION" \
    --arg acct "$ACCOUNT_ID" --arg domain "$MAIL_DOMAIN" '{
      Version:"2012-10-17",
      Statement:[
        {Effect:"Allow", Action:"s3:ListBucket", Resource:"arn:aws:s3:::\($bucket)"},
        {Effect:"Allow", Action:"s3:GetObject",  Resource:"arn:aws:s3:::\($bucket)/*"},
        {Effect:"Allow", Action:["ses:SendEmail","ses:GetEmailIdentity"],
         Resource:["arn:aws:ses:\($region):\($acct):identity/\($domain)",
                   "arn:aws:ses:\($region):\($acct):identity/*@\($domain)"]}
      ]
    }')"

export ROLE_ARN=$(aws iam get-role --role-name agentkeys-data-role --query 'Role.Arn' --output text)
echo "ROLE_ARN=$ROLE_ARN"
```

### §4.3 Per-data-class roles (`agentkeys-vault-role`, `agentkeys-memory-role`)

Per arch.md §17.2: separate roles for credentials + memory data classes. Same trust shape as §4.2, distinct inline policies + PrincipalTag scoping. Provisioned by per-data-class helpers (idempotent):

```bash
bash scripts/provision-vault-bucket.sh        # agentkeys-vault-${ACCOUNT_ID}
bash scripts/provision-vault-role.sh          # agentkeys-vault-role
bash scripts/apply-vault-bucket-policy.sh     # v3 split-statement PrincipalTag policy

bash scripts/provision-memory-bucket.sh
bash scripts/provision-memory-role.sh
bash scripts/apply-memory-bucket-policy.sh

bash scripts/cleanup-mail-bucket-policy.sh    # restore email-only grants on $BUCKET
```

These scripts are the **source of truth** for the policy shape — read them, don't transcribe.

### §4.4 `agentkeys-admin`, `agentkeys-broker` (already provisioned)

If you reached this section, `agentkeys-admin` exists (you're using it). `agentkeys-broker` is whatever IAM user you SSH into the broker host with — its perms are out of scope (`ec2-instance-connect:SendSSHPublicKey` on the host's instance ID is sufficient for AWS Instance Connect).

## §5 S3 bucket policy (initial, static-IAM variant)

```bash
aws s3api put-bucket-policy --region "$REGION" --bucket "$BUCKET" \
  --policy "$(jq -n --arg bucket "$BUCKET" --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[
      {
        Sid:"AllowSESWriteInbound", Effect:"Allow",
        Principal:{Service:"ses.amazonaws.com"},
        Action:"s3:PutObject",
        Resource:"arn:aws:s3:::\($bucket)/*",
        Condition:{StringEquals:{"aws:Referer":$acct}}
      },
      {
        Sid:"AllowDaemonRead", Effect:"Allow",
        Principal:{AWS:"arn:aws:iam::\($acct):role/agentkeys-data-role"},
        Action:["s3:GetObject","s3:ListBucket"],
        Resource:["arn:aws:s3:::\($bucket)","arn:aws:s3:::\($bucket)/*"]
      }
    ]
  }')"
```

The PrincipalTag-scoped federated variant (which replaces this once OIDC federation is up) lives in [`docs/cloud-setup.md`](cloud-setup.md) §4.4.

## §6 `agentkeys-broker-host` instance profile (EC2-only, optional)

If the broker runs on AWS EC2, attach this so the daemon never holds a static key. Runtime creds come from IMDS.

```bash
ROLE=agentkeys-broker-host

aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document "$(jq -n '{
    Version:"2012-10-17",
    Statement:[{Effect:"Allow", Principal:{Service:"ec2.amazonaws.com"}, Action:"sts:AssumeRole"}]
  }')"

aws iam put-role-policy --role-name "$ROLE" --policy-name BrokerAssumeData \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{Effect:"Allow", Action:"sts:AssumeRole",
                Resource:"arn:aws:iam::\($acct):role/agentkeys-data-role"}]
  }')"

aws iam create-instance-profile --instance-profile-name "$ROLE"
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
aws ec2 associate-iam-instance-profile --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --iam-instance-profile Name="$ROLE"
```

> **Caller-region trap:** `agentkeys-admin` profile defaults to `us-west-2`; the broker EC2 usually lives in `us-east-1`. Without `--region "$REGION"`, `describe-instances` silently returns empty and downstream `put-role-policy` runs with `--role-name ""`. Pass `--region` explicitly on every regional call. See [CLAUDE.md "AWS local-profile ↔ remote-IAM mapping"](../CLAUDE.md).

### §6.1 `ses:SendEmail` grant on the runtime role

The broker calls SES v2 `SendEmail` with its **own** runtime credentials (instance profile), not via the assumed `agentkeys-data-role`. Without `ses:SendEmail` on the broker's role, the operator hits:

```
broker rejected /v1/auth/email/request: status=502 body=
{"error":"backend_unreachable","message":"… ses SendEmail:
 unhandled error (AccessDeniedException)"}
```

The IAM action is `ses:SendEmail` (sesv2), NOT `ses:SendRawEmail` (v1; different code path the broker doesn't use). The grant lives on the broker's runtime role (`agentkeys-broker-host` on EC2; the user `agentkeys-daemon` otherwise) — see [`docs/cloud-setup.md`](cloud-setup.md) §3.3 for the exact statement.

## §7 Security audit — strip legacy over-broad attached policies

Some early deploys ship with `AmazonS3FullAccess` (or similar wide permissions) attached to the broker's runtime role. The broker at runtime ONLY uses `aws-sdk-sts` (the GetCallerIdentity startup probe) + `aws-sdk-sesv2` (the §6.1 grant) — it never accesses S3 with its own creds. Per-user S3 is via JWT-assumed `agentkeys-{data,vault,memory}-role`, not the broker's runtime role.

A broker compromise with `AmazonS3FullAccess` would expose every inbound email in the SES bucket (verification tokens, magic links). Strip it:

```bash
# Discover the actual role attached to the broker host (canonical name:
# agentkeys-broker-host; some early deploys landed on different names):
INSTANCE_PROFILE_ARN=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=ip-address,Values=$EIP" \
  --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text)

ROLE=$(aws iam get-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE_ARN##*/}" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)
echo "broker runtime role: $ROLE"

# Audit attached policies:
aws iam list-attached-role-policies --role-name "$ROLE"

# Detach AmazonS3FullAccess if present:
aws iam detach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# Verify only the narrow inline policy (BrokerSendEmail + AssumeDataRole) remains:
aws iam list-role-policies --role-name "$ROLE"
aws iam list-attached-role-policies --role-name "$ROLE"
```

## §8 Cloud-provider portability

Every layer in §3–§5 has a 1:1 analog on the major providers. The provisioning shape carries; only the API endpoints + JSON dialects differ.

| Layer | AWS (current) | AliCloud (in progress) | GCP | Tencent Cloud |
|---|---|---|---|---|
| Privileged user | IAM user with `IAMFullAccess` | RAM user with `AliyunRAMFullAccess` | IAM service account with `roles/iam.securityAdmin` | CAM user with `AdministratorAccess` |
| Runtime user | IAM user + access key | RAM user + AK/SK | Service account + key file (or Workload Identity) | CAM user + SecretId/SecretKey |
| Data role | IAM role + assume policy | RAM role + assume policy | Service account + IAM bindings | CAM role + assume policy |
| Federation | IAM OIDC provider | RAM IDaaS / OIDC provider | Workload Identity Pool | CAM OIDC provider |
| Object store | S3 + bucket policy | OSS + bucket policy | Cloud Storage + IAM bindings | COS + bucket policy |
| Email backend | SES + S3 receipt rule | DirectMail / SimpleDM + OSS event notification | SendGrid / Mailgun (no GCP-native) | SimpleDM + COS |
| TLS termination | nginx + Let's Encrypt | nginx + Let's Encrypt | nginx + Let's Encrypt | nginx + Let's Encrypt |
| Compute (broker host) | EC2 + EIP | ECS + EIP | Compute Engine + external IP | CVM + EIP |
| DNS | Route 53 | AliCloud DNS | Cloud DNS | DNSPod / Cloud DNS |
| Secrets storage | Secrets Manager / SSM Parameter Store | KMS Secrets Manager | Secret Manager | KMS |

**Migration playbook (cloud → cloud):**

1. Re-bind operator-workstation.env to the new provider's identifiers (account ID, region, role ARNs, bucket name).
2. Re-run this doc top-to-bottom against the new provider.
3. Re-run [`docs/cloud-setup.md`](cloud-setup.md) §4 (OIDC federation) — substitute the provider's OIDC API.
4. Re-run `scripts/setup-broker-host.sh` on the new host (the script doesn't care which cloud — it consumes already-provisioned identifiers).
5. Re-run `scripts/setup-heima.sh` — the chain side is cloud-agnostic.
6. Re-run the harness scripts to validate end-to-end.

The boundary is sharp: the broker process itself contains zero cloud-specific code — it talks STS-compatible OIDC + S3-compatible PutObject/GetObject + SMTP-compatible SendEmail. Every cloud above offers all three primitives. The [`provisioner-scripts/email-backends/`](../provisioner-scripts/) directory documents the email-backend trait; a new backend slots in as `tencent-simpledm-cos` (or similar) with the same upstream API as `ses-s3`.

## Related

- Day-to-day broker re-deploys: [`docs/cloud-setup.md`](cloud-setup.md)
- Chain bring-up: [`docs/heima-setup.md`](heima-setup.md)
- CI activation: [`docs/ci-setup.md`](ci-setup.md)
- Architecture (per-data-class buckets + isolation invariants): [`docs/spec/architecture.md`](spec/architecture.md) §17, §17.2
- Future Tencent / TEE DKIM: [`docs/spec/heima-gaps-vs-desired-architecture.md`](spec/heima-gaps-vs-desired-architecture.md) §4
- FAQ + troubleshooting: [`wiki/cloud-setup-faq.md`](../wiki/cloud-setup-faq.md)
