# Cloud setup — AgentKeys

**Audience:** the operator provisioning the cloud account that hosts AgentKeys infrastructure.
**Scope:** the prereqs that the idempotent [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh) entry point can't do for itself (DNS, SES, IAM, OIDC provider, S3 buckets). Run those once per account, then re-run the broker-host script as often as needed.
**Companion:** [`docs/heima-setup.md`](heima-setup.md) for chain bring-up, [`docs/ci-setup.md`](ci-setup.md) for CI activation.
**FAQ + troubleshooting:** [`wiki/cloud-setup-faq.md`](../wiki/cloud-setup-faq.md).

## TL;DR — operator flow

```bash
# Laptop:
awsp agentkeys-admin
set -a; source scripts/operator-workstation.env; set +a   # ${ACCOUNT_ID}, ${REGION}, ${BROKER_HOST}, ${BUCKET}, ...

# 1. Per-account, one-shot, manual (this doc):
#    §1 DNS subdomains, §2 SES domain identity, §3 IAM users + role,
#    §4 OIDC federation provider + trust policy + bucket policy.

# 2. Per-broker-host, idempotent re-runnable (script):
sudo bash scripts/setup-broker-host.sh \
  --issuer-url "https://${BROKER_HOST}" \
  --account-id "${ACCOUNT_ID}" \
  --signer-host "signer.${ZONE}" \
  --audit-host  "audit.${ZONE}" \
  --email-host  "email.${ZONE}" \
  --cred-host   "cred.${ZONE}" \
  --memory-host "memory.${ZONE}" \
  --yes

# 3. Per-chain, idempotent re-runnable:
bash scripts/setup-heima.sh                                # see docs/heima-setup.md
```

`setup-broker-host.sh` is **the single entry point** for every remote-host change (binary upgrades, systemd edits, env tweaks, nginx/certbot wiring, mock-server redeploys). Per [CLAUDE.md "Remote broker host"](../CLAUDE.md): no ad-hoc `systemctl` edits, no hand-built `scp`.

The split: §1–§4 below sets up the **identifiers** (DNS names, IAM principals, OIDC trust, bucket policies); the script consumes those identifiers and stands up the actual processes.

## 0. Identities — mental model

| Identity | Type | Holds | Purpose |
|---|---|---|---|
| `agentkeys-admin` | IAM user | Long-lived access key | One-shot provisioning. Runs every command in this doc. IAM-admin scope. |
| `agentkeys-broker` | IAM user | Long-lived access key | Operator's SSH-into-EC2 path via EC2 Instance Connect. No data-plane access. |
| `agentkeys-daemon` | IAM user | Long-lived access key | Broker process at runtime. Only permission: `sts:AssumeRole` on the data role. |
| `agentkeys-data-role` | IAM role | (assumed) | Holds the actual S3/SES permissions. `agentkeys-daemon` (Stage 6) or the OIDC provider (Stage 7) is allowed to assume. |
| `agentkeys-vault-role` / `agentkeys-memory-role` | IAM role | (assumed) | Per-data-class roles (arch.md §17.2). Trust the OIDC provider; PrincipalTag-scoped to `bots/<actor_omni>/{credentials,memory}/*`. |
| `agentkeys-broker-host` | IAM role | (assumed by EC2) | Optional. If the broker runs on EC2, attach as instance profile so the daemon never sees a static key. |

The word "agent" already means three things (the AI agent, the AgentKeys product, an IAM role) — these roles hold **data-plane** permissions, so they're named `*-data-role` / `*-vault-role` / `*-memory-role`.

## 1. DNS

Two-and-six subdomains under your parent zone (e.g. `litentry.org`):

| Host | Purpose | Set in |
|---|---|---|
| `${MAIL_DOMAIN}` (e.g. `bots.litentry.org`) | SES inbound | §2 |
| `${BROKER_HOST}` (e.g. `broker.litentry.org`) | Broker TLS-terminating reverse proxy | §5 — A record to broker EIP |
| `signer.${ZONE}` | Signer service (issue #74 step 1b) | §5 — A record to broker EIP (co-located today) |
| `audit.${ZONE}` / `email.${ZONE}` / `cred.${ZONE}` / `memory.${ZONE}` | Service workers (issue #90) | §5 — same EIP (dev co-location) |

For the bulk service-worker DNS, use [`scripts/dns-upsert-workers.sh`](../scripts/dns-upsert-workers.sh). The hostnames are the migration seam — when a worker moves to its own machine, only the A record changes.

## 2. SES inbound mail

```bash
# Verify the SES domain identity
aws sesv2 create-email-identity --region "$REGION" \
  --email-identity "$MAIL_DOMAIN" \
  --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT

# Publish DKIM + SPF + DMARC + MX in one Route 53 change (read DKIM tokens
# from `aws sesv2 get-email-identity`, then upsert via Route 53 — see
# wiki/cloud-setup-faq.md for the full record set).

# Create the inbound bucket (30-day TTL on inbound/* objects)
aws s3api create-bucket --region "$REGION" --bucket "$BUCKET" \
  $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION")
aws s3api put-public-access-block --region "$REGION" --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Receipt rule: route mail for $MAIL_DOMAIN into s3://$BUCKET/inbound/*
aws ses create-receipt-rule-set --rule-set-name agentkeys --region "$REGION" 2>/dev/null || true
aws ses create-receipt-rule --region "$REGION" --rule-set-name agentkeys \
  --rule "$(jq -n --arg domain "$MAIL_DOMAIN" --arg bucket "$BUCKET" '{
    Name: "agentkeys-inbound", Enabled: true, ScanEnabled: true, TlsPolicy: "Optional",
    Recipients: [$domain],
    Actions: [{S3Action: {BucketName: $bucket, ObjectKeyPrefix: "inbound/"}}]
  }')"
aws ses set-active-receipt-rule-set --rule-set-name agentkeys --region "$REGION"

# Verify the bot's sending identity (the broker's BROKER_EMAIL_FROM_ADDRESS
# precheck refuses to boot if this isn't verified)
bash scripts/ses-verify-sender.sh
```

**Sandbox vs production sending:** inbound is unaffected by SES sandbox; only **outbound** to arbitrary addresses needs Console → Support → "SES Sending Limits" → "Request Production Access".

**Per-recipient routing Lambda (issue #83):** after §4 lands, the broker's role is intentionally denied read on `inbound/*`. Service-provisioning verification emails route to `bots/<wallet>/inbound/<msg>` via [`infra/ses-routing-lambda/deploy.sh`](../infra/ses-routing-lambda/deploy.sh). Idempotent, deploy once per AWS account.

**Future Tencent Cloud port:** SES + S3 are the only AWS-specific layers in this doc. SimpleDM + COS slot in at the §3+ boundary — IAM model maps 1:1 onto CAM. The `provisioner-scripts/email-backends/` interface already abstracts the inbound contract.

## 3. IAM identities

The daemon user + data role are the boundary between manual provisioning (this doc) and the script-driven runtime (`setup-broker-host.sh`).

### 3.1 The four principals

```bash
# Runtime user (broker process)
aws iam create-user --user-name agentkeys-daemon
aws iam create-access-key --user-name agentkeys-daemon
#   → save AccessKeyId + SecretAccessKey to the operator's secret manager.
#     NEVER commit. setup-broker-host.sh consumes these via the systemd
#     env file written under /etc/agentkeys/.

# Daemon may only assume the data role (no direct S3/SES grants).
aws iam put-user-policy --user-name agentkeys-daemon \
  --policy-name agentkeys-daemon-assume-role \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{Effect:"Allow", Action:"sts:AssumeRole",
                Resource:"arn:aws:iam::\($acct):role/agentkeys-data-role"}]
  }')"
```

For `agentkeys-admin` + `agentkeys-broker` (one-shot, you already have these per CLAUDE.md "AWS local-profile ↔ remote-IAM mapping"), confirm with `aws iam list-users`.

### 3.2 The three data roles

Per arch.md §17.2 (per-data-class isolation): separate roles for credentials + memory + email. Same trust shape, distinct inline policies and PrincipalTag scoping. Provision via the per-data-class helpers (idempotent):

```bash
bash scripts/provision-vault-bucket.sh        # agentkeys-vault-${ACCOUNT_ID}
bash scripts/provision-vault-role.sh          # agentkeys-vault-role
bash scripts/apply-vault-bucket-policy.sh     # v3 split-statement PrincipalTag policy

bash scripts/provision-memory-bucket.sh
bash scripts/provision-memory-role.sh
bash scripts/apply-memory-bucket-policy.sh

bash scripts/cleanup-mail-bucket-policy.sh    # restore email-only grants on $BUCKET
```

The data-role trust shape is shown in [§4.3](#43-trust-policy) below — it's the same template for all three roles. The inline grants differ per role (vault → credentials prefix; memory → memory prefix; data-role → mail prefix).

### 3.3 SES sender grant (email-link auth prereq)

The broker's runtime role needs `ses:SendEmail` on the verified sender identity for email-link auth. Add this statement to the data role's inline policy:

```json
{
  "Effect": "Allow",
  "Action": ["ses:SendEmail", "ses:SendRawEmail"],
  "Resource": [
    "arn:aws:ses:${REGION}:${ACCOUNT_ID}:identity/${BROKER_EMAIL_FROM_ADDRESS}",
    "arn:aws:ses:${REGION}:${ACCOUNT_ID}:configuration-set/*"
  ]
}
```

The broker's `verify_sender_ready` precheck calls `ses:GetEmailIdentity` at boot and refuses to start if the identity isn't both verified AND grantable. Triggered without this grant: cryptic `AccessDenied: ses:SendEmail` at the magic-link send step.

## 4. OIDC federation (Stage 7)

The broker mints OIDC JWTs that AWS STS validates via the broker's public JWKS endpoint. Three one-shot steps per account.

### 4.1 Prereqs

- Broker reachable at `https://${BROKER_HOST}` over public TLS (`setup-broker-host.sh` provisions this with certbot).
- `https://${BROKER_HOST}/.well-known/openid-configuration` returns 200 with the expected `issuer` + `jwks_uri`.
- `https://${BROKER_HOST}/.well-known/jwks.json` returns at least one ES256 key.

### 4.2 Register the OIDC provider

```bash
thumb=$(echo | openssl s_client -servername "$BROKER_HOST" \
                                 -connect "${BROKER_HOST}:443" 2>/dev/null \
          | openssl x509 -fingerprint -noout \
          | awk -F'=' '{print $2}' | tr -d ':' | tr 'A-Z' 'a-z')

aws iam create-open-id-connect-provider \
  --url "https://${BROKER_HOST}" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "$thumb"
```

**AWS validates the issuer URL byte-for-byte** against the JWT `iss` claim. Once the OIDC provider is registered, the URL is effectively immutable for the life of the deployment — switching means new provider ARN + new trust policy + new federated grants.

### 4.3 Trust policy

Apply to each of the three data roles. Use `$ROLE` ∈ `{agentkeys-data-role, agentkeys-vault-role, agentkeys-memory-role}`.

```bash
aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$(jq -n \
  --arg acct "$ACCOUNT_ID" --arg host "$BROKER_HOST" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Federated:"arn:aws:iam::\($acct):oidc-provider/\($host)"},
      Action:"sts:AssumeRoleWithWebIdentity",
      Condition:{StringEquals:{"\($host):aud":"sts.amazonaws.com"}}
    }]
  }')"
```

### 4.4 PrincipalTag-scoped bucket policy

Per CLAUDE.md "Per-actor + per-data-class isolation invariants": every S3 read/write is scoped to `bots/${aws:PrincipalTag/agentkeys_actor_omni}/{credentials,memory}/*`. The split-statement v3 bucket policy is applied by [`scripts/apply-{vault,memory}-bucket-policy.sh`](../scripts/) — those scripts ARE the source of truth for the policy shape.

After §4.3 + §4.4: strip the §3 broad-bucket inline grant from the role's policy (the bucket-side policy enforces; defense in depth means no app-side grant). The `cleanup-mail-bucket-policy.sh` helper does this for the mail bucket; do it by hand for any other inline policy you've left:

```bash
aws iam delete-role-policy --role-name "$ROLE" --policy-name agentkeys-data-role-s3-broad
```

### 4.5 End-to-end proof

Run [`harness/v2-stage3-demo.sh`](../harness/v2-stage3-demo.sh) — it mints a session JWT → OIDC JWT → STS creds, then proves both POSITIVE (own prefix) and NEGATIVE (cross-actor prefix → AccessDenied) writes for both data classes plus the cross-role isolation matrix. Walks the full §17.2 isolation table from CLAUDE.md.

## 5. Broker host: `setup-broker-host.sh`

§1–§4 set up identifiers. This step stands up the actual processes — broker + mock-server + signer + 4 service workers — on the EC2 host (or any Linux box with public-internet egress + the broker's hostname).

### 5.1 Prereqs

- Fresh Linux host with sudo, systemd, public-internet egress, ports 80 + 443 open inbound (for certbot + nginx).
- DNS A records for `${BROKER_HOST}` + `signer.${ZONE}` + `audit.${ZONE}` + `email.${ZONE}` + `cred.${ZONE}` + `memory.${ZONE}` all pointing at the host's public IP.
- AWS credentials in `/etc/agentkeys/broker.env` (the script writes the file template; operator pastes the `agentkeys-daemon` access key from §3.1).

### 5.2 Run

```bash
# Bootstrap a fresh host:
sudo bash scripts/setup-broker-host.sh \
  --issuer-url "https://${BROKER_HOST}" \
  --account-id "${ACCOUNT_ID}" \
  --signer-host "signer.${ZONE}" \
  --audit-host  "audit.${ZONE}" \
  --email-host  "email.${ZONE}" \
  --cred-host   "cred.${ZONE}" \
  --memory-host "memory.${ZONE}" \
  --yes

# After a `git pull`, the same command re-deploys:
sudo bash scripts/setup-broker-host.sh --yes
```

The script:
- Builds `agentkeys-broker-server` (+ `auth-email-link` feature), `agentkeys-mock-server`, the 4 service workers, and the signer.
- Creates the `agentkeys` system user + state dir `/var/lib/agentkeys/`.
- Writes the dev_key_service master secret (one-shot at first boot, never rotated — rotation invalidates every previously-derived wallet).
- Writes per-worker env files at `/etc/agentkeys/worker-{audit,email,creds,memory}.env`.
- Writes systemd units for broker + signer + each worker, enables + starts.
- Configures nginx vhosts for `${BROKER_HOST}` + `signer.${ZONE}` + 4 worker hosts (skip via `--without-nginx`).
- Runs certbot for first-time TLS cert issuance (skip via `--without-certbot`).
- Mints broker keypairs (oidc + session) under `/var/lib/agentkeys/keys/`.

Auto-detects bootstrap vs upgrade by reading the existing systemd unit's `Environment=` lines. Pass `--ref <branch>` to opt into an in-script `git fetch + pull`.

### 5.3 Verify

```bash
curl -sf "https://${BROKER_HOST}/healthz"                  # → 200
curl -sf "https://${BROKER_HOST}/.well-known/openid-configuration" | jq .
curl -sf "https://${BROKER_HOST}/.well-known/jwks.json"    | jq '.keys | length'
curl -sf "https://audit.${ZONE}/healthz"                   # → 200 (and friends)
```

For full E2E (broker + workers + chain + AWS), run the harness scripts — see [`docs/heima-setup.md`](heima-setup.md) for the chain side and [`docs/ci-setup.md`](ci-setup.md) for the automated path.

## 6. Cleanup

Tear down the whole AgentKeys footprint in one account:

```bash
# Drain the buckets
for b in "$BUCKET" "agentkeys-vault-${ACCOUNT_ID}" "agentkeys-memory-${ACCOUNT_ID}"; do
  aws s3 rm "s3://$b" --recursive 2>/dev/null || true
  aws s3api delete-bucket --bucket "$b" --region "$REGION" 2>/dev/null || true
done

# Roles
for r in agentkeys-data-role agentkeys-vault-role agentkeys-memory-role agentkeys-broker-host; do
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p"
  done
  aws iam delete-role --role-name "$r" 2>/dev/null || true
done

# OIDC provider
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${BROKER_HOST}"

# Daemon user
for k in $(aws iam list-access-keys --user-name agentkeys-daemon --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name agentkeys-daemon --access-key-id "$k"
done
aws iam delete-user-policy --user-name agentkeys-daemon --policy-name agentkeys-daemon-assume-role 2>/dev/null || true
aws iam delete-user --user-name agentkeys-daemon

# SES + DNS
aws ses set-active-receipt-rule-set --rule-set-name "" --region "$REGION" 2>/dev/null || true
aws sesv2 delete-email-identity --email-identity "$MAIL_DOMAIN" --region "$REGION" 2>/dev/null || true
# DNS records are operator-managed (Route 53 / your DNS provider) — delete by hand.

# EC2 + EIP (manual via console or aws ec2 CLI)
```

## Related

- Chain bring-up: [`docs/heima-setup.md`](heima-setup.md)
- CI activation: [`docs/ci-setup.md`](ci-setup.md)
- Broker host script (single entry point): [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh)
- Architecture: [`docs/spec/architecture.md`](spec/architecture.md) §17 (per-data-class buckets), §17.2 (per-bucket IAM role)
- FAQ + troubleshooting: [`wiki/cloud-setup-faq.md`](../wiki/cloud-setup-faq.md)

## Follow-ups tracked elsewhere

- Per-recipient routing Lambda hardening: [`TODOS.md`](../TODOS.md) "Disable broker's broad S3-full-access"
- Tencent Cloud SimpleDM + COS port: tracked separately
- TEE-held BYODKIM migration: [`docs/spec/heima-gaps-vs-desired-architecture.md`](spec/heima-gaps-vs-desired-architecture.md) §4
