# Cloud setup — AgentKeys

**Audience:** the operator running ongoing broker re-deploys after first-time cloud-account bootstrap is done.
**Scope:** OIDC federation activation (the per-broker security upgrade) + the [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh) runtime entry point + tear-down. **Prereqs handled in [`docs/cloud-bootstrap.md`](cloud-bootstrap.md)** — read that first if standing up a brand-new account or porting to another cloud provider.
**Companion:** [`docs/heima-setup.md`](heima-setup.md) for chain bring-up, [`docs/ci-setup.md`](ci-setup.md) for CI activation.
**FAQ + troubleshooting:** [`wiki/cloud-setup-faq.md`](../wiki/cloud-setup-faq.md).

## TL;DR — operator flow

```bash
# Laptop:
awsp agentkeys-admin
set -a; source scripts/operator-workstation.env; set +a   # ${ACCOUNT_ID}, ${REGION}, ${BROKER_HOST}, ${BUCKET}, ...

# 0. First-time cloud-account bootstrap (cloud-bootstrap.md):
#    DNS subdomains, SES domain identity, IAM users + roles, initial
#    bucket policy. Run ONCE per account; re-enter only when migrating
#    cloud providers or adding a second account.

# 1. OIDC federation activation (this doc §1):
#    Once the broker is publicly reachable, register the IAM OIDC
#    provider + swap the role trust policy + apply PrincipalTag
#    bucket policy. Per-broker, one-shot.

# 2. Per-broker-host, idempotent re-runnable (this doc §2):
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

## 1. OIDC federation (Stage 7)

The broker mints OIDC JWTs that AWS STS validates via the broker's public JWKS endpoint. Three one-shot steps per account.

### 1.1 Prereqs

- Broker reachable at `https://${BROKER_HOST}` over public TLS (`setup-broker-host.sh` provisions this with certbot).
- `https://${BROKER_HOST}/.well-known/openid-configuration` returns 200 with the expected `issuer` + `jwks_uri`.
- `https://${BROKER_HOST}/.well-known/jwks.json` returns at least one ES256 key.

### 1.2 Register the OIDC provider

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

### 1.3 Trust policy (federated variant)

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

### 1.4 PrincipalTag-scoped bucket policy

Per CLAUDE.md "Per-actor + per-data-class isolation invariants": every S3 read/write is scoped to `bots/${aws:PrincipalTag/agentkeys_actor_omni}/{credentials,memory}/*`. The split-statement v3 bucket policy is applied by [`scripts/apply-{vault,memory}-bucket-policy.sh`](../scripts/) — those scripts ARE the source of truth for the policy shape.

After §4.3 + §4.4: strip the §3 broad-bucket inline grant from the role's policy (the bucket-side policy enforces; defense in depth means no app-side grant). The `cleanup-mail-bucket-policy.sh` helper does this for the mail bucket; do it by hand for any other inline policy you've left:

```bash
aws iam delete-role-policy --role-name "$ROLE" --policy-name agentkeys-data-role-s3-broad
```

### 1.5 End-to-end proof

Run [`harness/v2-stage3-demo.sh`](../harness/v2-stage3-demo.sh) — it mints a session JWT → OIDC JWT → STS creds, then proves both POSITIVE (own prefix) and NEGATIVE (cross-actor prefix → AccessDenied) writes for both data classes plus the cross-role isolation matrix. Walks the full §17.2 isolation table from CLAUDE.md.

## 2. Broker host: `setup-broker-host.sh`

§1–§4 set up identifiers. This step stands up the actual processes — broker + mock-server + signer + 4 service workers — on the EC2 host (or any Linux box with public-internet egress + the broker's hostname).

### 2.1 Prereqs

- Fresh Linux host with sudo, systemd, public-internet egress, ports 80 + 443 open inbound (for certbot + nginx).
- DNS A records for `${BROKER_HOST}` + `signer.${ZONE}` + `audit.${ZONE}` + `email.${ZONE}` + `cred.${ZONE}` + `memory.${ZONE}` all pointing at the host's public IP.
- AWS credentials in `/etc/agentkeys/broker.env` (the script writes the file template; operator pastes the `agentkeys-daemon` access key from §3.1).

### 2.2 Run

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

### 2.3 Verify

```bash
curl -sf "https://${BROKER_HOST}/healthz"                  # → 200
curl -sf "https://${BROKER_HOST}/.well-known/openid-configuration" | jq .
curl -sf "https://${BROKER_HOST}/.well-known/jwks.json"    | jq '.keys | length'
curl -sf "https://audit.${ZONE}/healthz"                   # → 200 (and friends)
```

For full E2E (broker + workers + chain + AWS), run the harness scripts — see [`docs/heima-setup.md`](heima-setup.md) for the chain side and [`docs/ci-setup.md`](ci-setup.md) for the automated path.

## 3. Cleanup (full account teardown)

Tears down everything provisioned by both [`docs/cloud-bootstrap.md`](cloud-bootstrap.md) and this doc. Use only when retiring the deployment.

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

- **First-time cloud-account bootstrap (prereq for this doc):** [`docs/cloud-bootstrap.md`](cloud-bootstrap.md)
- Chain bring-up: [`docs/heima-setup.md`](heima-setup.md)
- CI activation: [`docs/ci-setup.md`](ci-setup.md)
- Broker host script (single entry point): [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh)
- Architecture: [`docs/spec/architecture.md`](spec/architecture.md) §17 (per-data-class buckets), §17.2 (per-bucket IAM role)
- FAQ + troubleshooting: [`wiki/cloud-setup-faq.md`](../wiki/cloud-setup-faq.md)

## Follow-ups tracked elsewhere

- Per-recipient routing Lambda hardening: [`TODOS.md`](../TODOS.md) "Disable broker's broad S3-full-access"
- Tencent Cloud SimpleDM + COS port: tracked separately
- TEE-held BYODKIM migration: [`docs/spec/heima-gaps-vs-desired-architecture.md`](spec/heima-gaps-vs-desired-architecture.md) §4
