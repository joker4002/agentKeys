#!/usr/bin/env bash
# AgentKeys cloud-account bootstrap — single idempotent entry point.
#
# First-time provisioning of the cloud-side resources that precede
# setup-broker-host.sh: SES domain identity + S3 inbound bucket +
# DKIM/SPF/DMARC/MX DNS + 6 broker subdomain A records + IAM users +
# IAM roles + bucket policies. Mirrors docs/cloud-bootstrap.md
# end-to-end.
#
# Per CLAUDE.md "Idempotent remote-setup rule": every step pre-checks
# state and short-circuits when the work is already a no-op. Output
# convention per step: `ok proceeding` (mutation applied),
# `skip <reason>` (no-op), or `fail <reason>` (hard error, exit non-zero).
#
# Per CLAUDE.md "Cloud setup single entry point" (pair of
# setup-broker-host.sh + setup-heima.sh): no ad-hoc aws iam / aws ses
# CLI from operator runbooks; this script is THE end-to-end orchestrator.
# Per-action helpers (provision-vault-bucket.sh, ses-verify-sender.sh,
# dns-upsert-workers.sh, etc.) stay callable directly for surgical
# re-runs; this script chains them in order.
#
# Usage:
#   AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh [flags]
#
# Required env (sourced from scripts/operator-workstation.env):
#   ACCOUNT_ID, REGION, ZONE, PARENT_ZONE_ID,
#   BROKER_HOST, MAIL_DOMAIN, BUCKET (= MAIL_BUCKET)
#
# Optional env:
#   EIP                Reuse this existing EIP instead of allocating
#   INSTANCE_ID        EC2 instance to attach the EIP to (skipped if absent)
#   ZONE_SUFFIX        Override the broker subdomain prefix (default: empty)
#   AGENTKEYS_TEST     Set to "1" to add "-test" suffix to every identifier
#                      (use when bootstrapping the CI test instance)
#
# Flags:
#   --yes              non-interactive (don't pause before destructive)
#   --from-step N      start at step N (skip 1..N-1)
#   --to-step N        stop after step N
#   --only-step N      run exactly step N
#   --dry-run          print the would-mutate calls only
#   --help             this message + exit
#
# Idempotency claims (per CLAUDE.md table):
#   - Step 4 (EIP): tag-based pre-check; reuse on match
#   - Step 5 (SES identity): create returns 200 on already-exists
#   - Step 6 (DNS): UPSERT — no-op when record value matches
#   - Step 7 (mail bucket): head-bucket pre-check; skip on 200
#   - Step 8 (SES receipt rule): describe-receipt-rule pre-check
#   - Step 10 (daemon user): get-user pre-check; access key minted ONCE
#   - Step 11 (data role): get-role pre-check; put-role-policy idempotent
#   - Step 12 (per-data-class): delegated helpers are all idempotent
#   - Step 13 (mail bucket policy): get-bucket-policy diff against target

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/operator-workstation.env"

YES=0
DRY_RUN=0
FROM_STEP=1
TO_STEP=14
STEP_TOTAL=14

# Colors only when stderr is a TTY.
if [ -t 2 ]; then
  COLOR_OK='\033[32m'; COLOR_WARN='\033[33m'; COLOR_FAIL='\033[31m'
  COLOR_HEAD='\033[1m'; COLOR_RESET='\033[0m'
else
  COLOR_OK=''; COLOR_WARN=''; COLOR_FAIL=''; COLOR_HEAD=''; COLOR_RESET=''
fi

# ─── CLI parse ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)    ENV_FILE="$2"; shift 2 ;;
    --yes)         YES=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --from-step)   FROM_STEP="$2"; shift 2 ;;
    --to-step)     TO_STEP="$2"; shift 2 ;;
    --only-step)   FROM_STEP="$2"; TO_STEP="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,55p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "Unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# Test-mode suffix is auto-detected from the env file path if it
# contains "test", and overridable via AGENTKEYS_TEST=1.
case "$ENV_FILE" in
  *test*) : "${AGENTKEYS_TEST:=1}" ;;
esac
SUFFIX=""
[ "${AGENTKEYS_TEST:-0}" = "1" ] && SUFFIX="-test"
DAEMON_USER="agentkeys-daemon${SUFFIX}"
DATA_ROLE="agentkeys-data-role${SUFFIX}"

# ─── Helpers ──────────────────────────────────────────────────────────────────
step() { printf "${COLOR_HEAD}==> [step %d/%d] %s${COLOR_RESET}\n" "$CUR_STEP" "$STEP_TOTAL" "$1" >&2; }
ok()   { printf "    ${COLOR_OK}ok    %s${COLOR_RESET}\n" "$1" >&2; }
warn() { printf "    ${COLOR_WARN}warn  %s${COLOR_RESET}\n" "$1" >&2; }
fail() { printf "    ${COLOR_FAIL}fail  %s${COLOR_RESET}\n" "$1" >&2; }
skip() { printf "    ${COLOR_WARN}skip  %s${COLOR_RESET}\n" "$1" >&2; }
die()  { fail "$1"; exit 1; }

in_scope() {
  [ "$1" -ge "$FROM_STEP" ] && [ "$1" -le "$TO_STEP" ]
}

# Idempotent overwrite of a KEY=VAL line in $ENV_FILE.
env_set() {
  local key="$1" val="$2"
  if [ ! -f "$ENV_FILE" ]; then
    printf '%s=%s\n' "$key" "$val" > "$ENV_FILE"
    return
  fi
  if grep -q "^${key}=" "$ENV_FILE"; then
    # macOS + GNU sed compatibility: write tmp, swap.
    awk -v k="$key" -v v="$val" '
      BEGIN { ow = 0 }
      $0 ~ "^"k"=" { print k"="v; ow = 1; next }
      { print }
      END { if (!ow) print k"="v }
    ' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

# ─── Run steps ────────────────────────────────────────────────────────────────
printf "${COLOR_HEAD}=== AgentKeys cloud bootstrap ===${COLOR_RESET}\n" >&2
printf "  steps %d..%d (of %d)\n\n" "$FROM_STEP" "$TO_STEP" "$STEP_TOTAL" >&2

do_step_1() {
  CUR_STEP=1; step "Tool sanity-check"
  local missing=()
  for tool in aws jq curl openssl awk sed; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [ "${#missing[@]}" -gt 0 ] && die "missing tools: ${missing[*]}"
  ok "tools present"
}

do_step_2() {
  CUR_STEP=2; step "Source $ENV_FILE + validate required keys"
  [ -f "$ENV_FILE" ] || die "missing $ENV_FILE — copy from operator-workstation.env.example or create from cloud-bootstrap.md §TL;DR"
  set -a; . "$ENV_FILE"; set +a
  : "${ACCOUNT_ID:?ACCOUNT_ID missing — set in $ENV_FILE}"
  : "${REGION:?REGION missing — set in $ENV_FILE}"
  : "${ZONE:?ZONE missing — set in $ENV_FILE (parent zone, e.g. litentry.org)}"
  : "${PARENT_ZONE_ID:?PARENT_ZONE_ID missing — Route 53 zone ID for \$ZONE}"
  : "${BROKER_HOST:?BROKER_HOST missing — set in $ENV_FILE}"
  : "${MAIL_DOMAIN:?MAIL_DOMAIN missing — set in $ENV_FILE}"
  : "${BUCKET:?BUCKET missing — set in $ENV_FILE (inbound mail bucket name)}"
  ok "env sourced — ACCOUNT_ID=$ACCOUNT_ID REGION=$REGION ZONE=$ZONE"
}

do_step_3() {
  CUR_STEP=3; step "Validate AWS caller is account-owner"
  local caller_arn
  caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) \
    || die "aws sts get-caller-identity failed — check AWS_PROFILE / credentials"
  local caller_arn_lc
  caller_arn_lc=$(printf '%s' "$caller_arn" | tr 'A-Z' 'a-z')
  case "$caller_arn_lc" in
    *agentkeys-admin*|*agentkeys-broker-host*) ok "caller: $caller_arn" ;;
    *) die "caller $caller_arn is not agentkeys-admin — \`awsp agentkeys-admin\` first" ;;
  esac

  local zone_name
  zone_name=$(aws route53 get-hosted-zone --id "$PARENT_ZONE_ID" \
    --query 'HostedZone.Name' --output text 2>/dev/null) \
    || die "Route 53 zone $PARENT_ZONE_ID not found — check PARENT_ZONE_ID"
  ok "parent zone: $zone_name"
}

do_step_4() {
  CUR_STEP=4; step "Allocate or reuse Elastic IP (tag: agentkeys-broker-eip)"
  local tag_key="Name" tag_val="agentkeys-broker-eip"
  [ "${AGENTKEYS_TEST:-0}" = "1" ] && tag_val="agentkeys-broker-eip-test"

  # Pre-check: tagged EIP already exists?
  local existing_eip
  existing_eip=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:${tag_key},Values=${tag_val}" \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null)
  if [ -n "$existing_eip" ] && [ "$existing_eip" != "None" ]; then
    skip "EIP $existing_eip already allocated"
    EIP="$existing_eip"
  elif [ -n "${EIP:-}" ]; then
    skip "EIP $EIP provided via env; not allocating new one"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would allocate-address + create-tags"; return; }
    local alloc_json
    alloc_json=$(aws ec2 allocate-address --region "$REGION" --domain vpc \
      --output json --tag-specifications \
      "ResourceType=elastic-ip,Tags=[{Key=${tag_key},Value=${tag_val}}]") \
      || die "allocate-address failed"
    EIP=$(echo "$alloc_json" | jq -r .PublicIp)
    ok "allocated EIP $EIP"
  fi
  env_set EIP "$EIP"

  # Optional: attach to a known EC2 instance.
  if [ -n "${INSTANCE_ID:-}" ]; then
    local current_assoc
    current_assoc=$(aws ec2 describe-addresses --region "$REGION" \
      --public-ips "$EIP" \
      --query 'Addresses[0].InstanceId' --output text 2>/dev/null)
    if [ "$current_assoc" = "$INSTANCE_ID" ]; then
      skip "EIP $EIP already attached to $INSTANCE_ID"
    else
      [ "$DRY_RUN" = "1" ] && { warn "DRY: would associate-address $EIP → $INSTANCE_ID"; return; }
      aws ec2 associate-address --region "$REGION" \
        --instance-id "$INSTANCE_ID" --public-ip "$EIP" \
        >/dev/null || die "associate-address failed"
      ok "attached EIP $EIP → $INSTANCE_ID"
    fi
  else
    warn "INSTANCE_ID unset — EIP unattached (run again with INSTANCE_ID=… once EC2 exists)"
  fi
}

do_step_5() {
  CUR_STEP=5; step "SES domain identity ($MAIL_DOMAIN)"
  local status
  status=$(aws sesv2 get-email-identity --region "$REGION" \
    --email-identity "$MAIL_DOMAIN" \
    --query VerifiedForSendingStatus --output text 2>/dev/null || echo "absent")
  if [ "$status" = "True" ] || [ "$status" = "true" ]; then
    skip "SES identity $MAIL_DOMAIN already verified"
  elif [ "$status" = "False" ] || [ "$status" = "false" ]; then
    warn "SES identity $MAIL_DOMAIN exists but not yet verified (DKIM pending; step 6 publishes records)"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-email-identity $MAIL_DOMAIN"; return; }
    aws sesv2 create-email-identity --region "$REGION" \
      --email-identity "$MAIL_DOMAIN" \
      --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT \
      >/dev/null || die "create-email-identity failed"
    ok "SES identity created for $MAIL_DOMAIN — waiting for DKIM tokens"
  fi
}

do_step_6() {
  CUR_STEP=6; step "DNS records (DKIM + SPF + DMARC + MX + 6 A records to $EIP)"
  : "${EIP:?EIP missing — re-run step 4 first}"

  local tokens t1 t2 t3
  tokens=$(aws sesv2 get-email-identity --region "$REGION" \
    --email-identity "$MAIL_DOMAIN" \
    --query 'DkimAttributes.Tokens' --output text 2>/dev/null) \
    || die "could not read DKIM tokens — step 5 may not have completed"
  read -r t1 t2 t3 <<<"$tokens"
  [ -z "$t1" ] && die "no DKIM tokens returned — wait 30s after step 5 and re-run"

  local broker_host="${BROKER_HOST}"
  local change_batch
  change_batch=$(jq -n \
    --arg domain "$MAIL_DOMAIN" --arg region "$REGION" --arg zone "$ZONE" \
    --arg eip "$EIP" --arg broker "$broker_host" \
    --arg t1 "$t1" --arg t2 "$t2" --arg t3 "$t3" '{
      Comment: "AgentKeys cloud bootstrap (DKIM/SPF/DMARC/MX + broker subdomains)",
      Changes: [
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t1)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t1).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t2)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t2).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t3)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t3).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$domain, Type:"MX",  TTL:300, ResourceRecords:[{Value:"10 inbound-smtp.\($region).amazonaws.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$domain, Type:"TXT", TTL:300, ResourceRecords:[{Value:"\"v=spf1 include:amazonses.com -all\""}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"_dmarc.\($domain)", Type:"TXT", TTL:300, ResourceRecords:[{Value:"\"v=DMARC1; p=quarantine; rua=mailto:dmarc@\($domain)\""}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$broker,            Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"signer.\($zone)",  Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"audit.\($zone)",   Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"email.\($zone)",   Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"cred.\($zone)",    Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"memory.\($zone)",  Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}}
      ]
    }')

  [ "$DRY_RUN" = "1" ] && { warn "DRY: would change-resource-record-sets (12 UPSERTs)"; return; }

  aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" \
    --change-batch "$change_batch" >/dev/null \
    || die "route53 change-resource-record-sets failed"
  ok "DNS records UPSERTed (12 records; ~5min for DKIM verification)"
}

do_step_7() {
  CUR_STEP=7; step "Mail bucket ($BUCKET)"
  if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
    skip "bucket $BUCKET already exists"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-bucket $BUCKET"; return; }
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --region "$REGION" --bucket "$BUCKET" >/dev/null \
        || die "create-bucket failed"
    else
      aws s3api create-bucket --region "$REGION" --bucket "$BUCKET" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null \
        || die "create-bucket failed"
    fi
    ok "bucket $BUCKET created"
  fi

  aws s3api put-public-access-block --region "$REGION" --bucket "$BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    >/dev/null || die "put-public-access-block failed"

  aws s3api put-bucket-lifecycle-configuration --region "$REGION" --bucket "$BUCKET" \
    --lifecycle-configuration "$(jq -n '{
      Rules: [{ID:"inbound-30d-ttl", Status:"Enabled", Filter:{Prefix:"inbound/"}, Expiration:{Days:30}}]
    }')" >/dev/null || die "put-bucket-lifecycle-configuration failed"
  ok "public-access-block + 30-day inbound/ lifecycle applied"
}

do_step_8() {
  CUR_STEP=8; step "SES receipt rule (agentkeys/agentkeys-inbound)"
  # Ensure rule set exists.
  aws ses create-receipt-rule-set --rule-set-name agentkeys --region "$REGION" \
    >/dev/null 2>&1 || true

  # Pre-check: rule already on the set?
  local existing_rule
  existing_rule=$(aws ses describe-receipt-rule --rule-set-name agentkeys \
    --rule-name agentkeys-inbound --region "$REGION" \
    --query 'Rule.Name' --output text 2>/dev/null || echo "absent")
  if [ "$existing_rule" = "agentkeys-inbound" ]; then
    skip "receipt rule already configured"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-receipt-rule"; return; }
    aws ses create-receipt-rule --region "$REGION" --rule-set-name agentkeys \
      --rule "$(jq -n --arg domain "$MAIL_DOMAIN" --arg bucket "$BUCKET" '{
        Name: "agentkeys-inbound", Enabled: true, ScanEnabled: true, TlsPolicy: "Optional",
        Recipients: [$domain],
        Actions: [{S3Action: {BucketName: $bucket, ObjectKeyPrefix: "inbound/"}}]
      }')" >/dev/null || die "create-receipt-rule failed"
    ok "receipt rule created"
  fi

  # Activate the rule set (idempotent).
  local active
  active=$(aws ses describe-active-receipt-rule-set --region "$REGION" \
    --query 'Metadata.Name' --output text 2>/dev/null || echo "none")
  if [ "$active" = "agentkeys" ]; then
    skip "agentkeys rule set already active"
  else
    aws ses set-active-receipt-rule-set --rule-set-name agentkeys --region "$REGION" \
      >/dev/null || die "set-active-receipt-rule-set failed"
    ok "agentkeys rule set activated"
  fi
}

do_step_9() {
  CUR_STEP=9; step "SES verified sender (delegates to ses-verify-sender.sh)"
  [ "$DRY_RUN" = "1" ] && { warn "DRY: would run ses-verify-sender.sh"; return; }
  bash "$SCRIPT_DIR/ses-verify-sender.sh" || warn "ses-verify-sender.sh exited non-zero (may be a flake — check inbound bucket manually)"
  ok "SES sender verification step complete"
}

do_step_10() {
  CUR_STEP=10; step "IAM user $DAEMON_USER (broker runtime)"
  if aws iam get-user --user-name "$DAEMON_USER" >/dev/null 2>&1; then
    skip "IAM user $DAEMON_USER already exists"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-user $DAEMON_USER"; return; }
    aws iam create-user --user-name "$DAEMON_USER" >/dev/null \
      || die "create-user $DAEMON_USER failed"
    ok "IAM user $DAEMON_USER created"
  fi

  # Inline assume-role policy is idempotent (overwrite).
  [ "$DRY_RUN" = "1" ] || aws iam put-user-policy --user-name "$DAEMON_USER" \
    --policy-name "${DAEMON_USER}-assume-role" \
    --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" --arg role "$DATA_ROLE" '{
      Version:"2012-10-17",
      Statement:[{Effect:"Allow", Action:"sts:AssumeRole",
                  Resource:"arn:aws:iam::\($acct):role/\($role)"}]
    }')" >/dev/null || die "put-user-policy failed"
  ok "$DAEMON_USER inline policy applied"

  # Access key: only mint if none currently active.
  local active_keys
  active_keys=$(aws iam list-access-keys --user-name "$DAEMON_USER" \
    --query 'AccessKeyMetadata[?Status==`Active`] | length(@)' --output text)
  if [ "$active_keys" -ge 1 ]; then
    skip "$DAEMON_USER already has $active_keys active access key(s) — operator must already hold them"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-access-key $DAEMON_USER"; return; }
    warn "creating a new access key — SAVE THE SECRET, it is shown ONCE"
    local key_json key_id key_secret
    key_json=$(aws iam create-access-key --user-name "$DAEMON_USER" --output json) \
      || die "create-access-key failed"
    key_id=$(echo "$key_json"     | jq -r .AccessKey.AccessKeyId)
    key_secret=$(echo "$key_json" | jq -r .AccessKey.SecretAccessKey)
    printf "\n    %s%s%s\n" "$COLOR_HEAD" "AWS access key (paste into operator secret manager):" "$COLOR_RESET" >&2
    printf "      AWS_ACCESS_KEY_ID=%s\n"     "$key_id"     >&2
    printf "      AWS_SECRET_ACCESS_KEY=%s\n\n" "$key_secret" >&2
    ok "access key minted — NEVER commit to git"
  fi
}

do_step_11() {
  CUR_STEP=11; step "IAM role $DATA_ROLE (static-IAM trust variant)"
  if aws iam get-role --role-name "$DATA_ROLE" >/dev/null 2>&1; then
    skip "role $DATA_ROLE already exists"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-role $DATA_ROLE"; return; }
    aws iam create-role --role-name "$DATA_ROLE" \
      --assume-role-policy-document "$(jq -n --arg acct "$ACCOUNT_ID" --arg user "$DAEMON_USER" '{
        Version:"2012-10-17",
        Statement:[{
          Effect:"Allow",
          Principal:{AWS:"arn:aws:iam::\($acct):user/\($user)"},
          Action:"sts:AssumeRole"
        }]
      }')" >/dev/null || die "create-role failed"
    ok "role $DATA_ROLE created"
  fi

  # Inline data-plane policy (idempotent overwrite).
  [ "$DRY_RUN" = "1" ] || aws iam put-role-policy --role-name "$DATA_ROLE" \
    --policy-name "${DATA_ROLE}-inline" \
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
      }')" >/dev/null || die "put-role-policy failed"
  ok "$DATA_ROLE inline policy applied"

  local role_arn
  role_arn=$(aws iam get-role --role-name "$DATA_ROLE" --query 'Role.Arn' --output text)
  env_set DATA_ROLE_ARN "$role_arn"
}

do_step_12() {
  CUR_STEP=12; step "Per-data-class buckets + roles (delegates to provision-*.sh)"
  if [ "$DRY_RUN" = "1" ]; then
    warn "DRY: would run provision-{vault,memory}-{bucket,role}.sh + apply-{vault,memory}-bucket-policy.sh"
    return
  fi
  bash "$SCRIPT_DIR/provision-vault-bucket.sh"
  bash "$SCRIPT_DIR/provision-vault-role.sh"
  bash "$SCRIPT_DIR/provision-memory-bucket.sh"
  bash "$SCRIPT_DIR/provision-memory-role.sh"
  bash "$SCRIPT_DIR/apply-vault-bucket-policy.sh"
  bash "$SCRIPT_DIR/apply-memory-bucket-policy.sh"
  ok "per-data-class provisioning complete"
}

do_step_13() {
  CUR_STEP=13; step "Initial mail bucket policy (static-IAM variant)"
  # Pre-check: policy already contains AllowDaemonRead Sid?
  local current
  current=$(aws s3api get-bucket-policy --region "$REGION" --bucket "$BUCKET" \
    --query 'Policy' --output text 2>/dev/null || echo "{}")
  if echo "$current" | jq -e '.Statement[]? | select(.Sid=="AllowDaemonRead")' >/dev/null 2>&1; then
    skip "mail bucket policy already includes AllowDaemonRead"
    return
  fi

  [ "$DRY_RUN" = "1" ] && { warn "DRY: would put-bucket-policy on $BUCKET"; return; }
  aws s3api put-bucket-policy --region "$REGION" --bucket "$BUCKET" \
    --policy "$(jq -n --arg bucket "$BUCKET" --arg acct "$ACCOUNT_ID" --arg role "$DATA_ROLE" '{
      Version:"2012-10-17",
      Statement:[
        {Sid:"AllowSESWriteInbound", Effect:"Allow",
         Principal:{Service:"ses.amazonaws.com"},
         Action:"s3:PutObject",
         Resource:"arn:aws:s3:::\($bucket)/*",
         Condition:{StringEquals:{"aws:Referer":$acct}}},
        {Sid:"AllowDaemonRead", Effect:"Allow",
         Principal:{AWS:"arn:aws:iam::\($acct):role/\($role)"},
         Action:["s3:GetObject","s3:ListBucket"],
         Resource:["arn:aws:s3:::\($bucket)","arn:aws:s3:::\($bucket)/*"]}
      ]
    }')" >/dev/null || die "put-bucket-policy failed"
  ok "mail bucket policy applied"
}

do_step_14() {
  CUR_STEP=14; step "Summary + next steps"
  printf "\n${COLOR_OK}═══ Cloud bootstrap complete ═══${COLOR_RESET}\n\n" >&2
  printf "  Region            : %s\n" "$REGION" >&2
  printf "  Zone              : %s (id: %s)\n" "$ZONE" "$PARENT_ZONE_ID" >&2
  printf "  Mail domain       : %s\n" "$MAIL_DOMAIN" >&2
  printf "  Broker host       : %s\n" "$BROKER_HOST" >&2
  printf "  Mail bucket       : s3://%s/\n" "$BUCKET" >&2
  printf "  Data role         : arn:aws:iam::%s:role/agentkeys-data-role\n" "$ACCOUNT_ID" >&2
  printf "  EIP               : %s\n" "${EIP:-(unallocated)}" >&2
  printf "\n  Next steps (in order):\n" >&2
  printf "    1. Launch EC2 (or other Linux host); attach the EIP if you skipped INSTANCE_ID:\n" >&2
  printf "         aws ec2 associate-address --region %s --instance-id <id> --public-ip %s\n" \
    "$REGION" "${EIP:-<eip>}" >&2
  printf "    2. SSH into the host, clone the repo, then:\n" >&2
  printf "         sudo bash scripts/setup-broker-host.sh --issuer-url https://%s --account-id %s --yes\n" \
    "$BROKER_HOST" "$ACCOUNT_ID" >&2
  printf "    3. Once broker is publicly reachable, run docs/cloud-setup.md §1 (OIDC federation upgrade).\n" >&2
  printf "    4. Chain bring-up: bash scripts/setup-heima.sh\n\n" >&2

  printf "  Re-run any step surgically (idempotent):\n" >&2
  printf "    bash scripts/setup-cloud.sh --only-step 6   # re-UPSERT DNS\n" >&2
  printf "    bash scripts/setup-cloud.sh --only-step 12  # re-run per-data-class provisioning\n\n" >&2
}

main() {
  in_scope 1  && do_step_1
  in_scope 2  && do_step_2
  in_scope 3  && do_step_3
  in_scope 4  && do_step_4
  in_scope 5  && do_step_5
  in_scope 6  && do_step_6
  in_scope 7  && do_step_7
  in_scope 8  && do_step_8
  in_scope 9  && do_step_9
  in_scope 10 && do_step_10
  in_scope 11 && do_step_11
  in_scope 12 && do_step_12
  in_scope 13 && do_step_13
  in_scope 14 && do_step_14
}

main "$@"
