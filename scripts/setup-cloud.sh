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
# Env files (TWO sourced — operator-workstation first, broker second):
#
#   1. Operator-workstation env (`--env-file`, default
#      scripts/operator-workstation.env). Account-wide identifiers:
#      ACCOUNT_ID, REGION, ZONE, PARENT_ZONE_ID, BROKER_HOST, MAIL_DOMAIN,
#      BUCKET (= MAIL_BUCKET), VAULT_BUCKET, MEMORY_BUCKET, *_ROLE_ARN, ...
#
#   2. Broker env (`--broker-env-file`, default scripts/broker.env or
#      scripts/broker.test.env when --test is set). MACHINE identifiers:
#      INSTANCE_ID  EC2 hosting the broker — operator pastes manually
#      EIP          Static IP for $BROKER_HOST — usually filled in by step 4
#                   and written back; operator hand-edits only when importing
#                   an EIP allocated outside the script.
#
# Flags:
#   --env-file <path>           operator-workstation env file (default per above)
#   --broker-env-file <path>    broker-machine env file (default per --test mode)
#   --test                      explicit test mode: suffix IAM identifiers with
#                               -test AND switch broker-env-file default to
#                               scripts/broker.test.env. Auto-set when --env-file
#                               path contains "test", but pass explicitly if your
#                               test env file uses a different name.
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
#   - Step 12 (SSH user): get-user pre-check; access key minted ONCE; grant
#                          scoped to INSTANCE_ID from $BROKER_ENV_FILE
#   - Step 13 (per-data-class): delegated helpers are all idempotent
#   - Step 14 (mail bucket policy): get-bucket-policy diff against target

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/operator-workstation.env"
BROKER_ENV_FILE=""   # resolved post-CLI-parse based on TEST_MODE

YES=0
DRY_RUN=0
FROM_STEP=1
TO_STEP=15
STEP_TOTAL=15

# Colors only when stderr is a TTY.
if [ -t 2 ]; then
  # ANSI-C quoting ($'…') so the vars hold the actual ESC byte. This way
  # `printf '%s' "$COLOR_HEAD"` renders bold instead of printing the literal
  # six-char string "\033[1m". Format-string interpolation
  # ("${COLOR_HEAD}…${COLOR_RESET}") works either way.
  COLOR_OK=$'\033[32m'; COLOR_WARN=$'\033[33m'; COLOR_FAIL=$'\033[31m'
  COLOR_HEAD=$'\033[1m'; COLOR_RESET=$'\033[0m'
else
  COLOR_OK=''; COLOR_WARN=''; COLOR_FAIL=''; COLOR_HEAD=''; COLOR_RESET=''
fi

# ─── CLI parse ────────────────────────────────────────────────────────────────
TEST_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)         ENV_FILE="$2"; shift 2 ;;
    --broker-env-file)  BROKER_ENV_FILE="$2"; shift 2 ;;
    --test)             TEST_MODE=1; shift ;;
    --yes)              YES=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --from-step)        FROM_STEP="$2"; shift 2 ;;
    --to-step)          TO_STEP="$2"; shift 2 ;;
    --only-step)        FROM_STEP="$2"; TO_STEP="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,55p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "Unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# Test mode = explicit --test flag wins; otherwise auto-detect from env-file
# path if it contains "test" (ergonomic shortcut for the conventional
# scripts/operator-workstation.test.env naming).
if [ "$TEST_MODE" = "0" ]; then
  case "$ENV_FILE" in
    *test*) TEST_MODE=1 ;;
  esac
fi

# When --test is set but --env-file is still the prod default, auto-switch
# to operator-workstation.test.env so a bare `--test` produces an
# end-to-end test invocation (hostnames + buckets + IAM names all -test),
# not the half-test trap where --test only suffixed IAM identifiers while
# BROKER_HOST / MAIL_DOMAIN stayed prod.
if [ "$TEST_MODE" = "1" ] && [ "$ENV_FILE" = "$SCRIPT_DIR/operator-workstation.env" ]; then
  ENV_FILE="$SCRIPT_DIR/operator-workstation.test.env"
fi

SUFFIX=""
[ "$TEST_MODE" = "1" ] && SUFFIX="-test"
DAEMON_USER="agentkeys-daemon${SUFFIX}"
DATA_ROLE="agentkeys-data-role${SUFFIX}"
SSH_USER="agentkeys-broker${SUFFIX}"

# Resolve BROKER_ENV_FILE default if not set via flag: matches TEST_MODE.
if [ -z "$BROKER_ENV_FILE" ]; then
  if [ "$TEST_MODE" = "1" ]; then
    BROKER_ENV_FILE="$SCRIPT_DIR/broker.test.env"
  else
    BROKER_ENV_FILE="$SCRIPT_DIR/broker.env"
  fi
fi

# Source BOTH env files unconditionally so any --only-step N or
# --from-step N (where N > 2) has access to ACCOUNT_ID/REGION/ZONE/etc.
# (operator-workstation) AND INSTANCE_ID/EIP (broker). Step 2's do_step_2
# re-sources + validates the operator-workstation keys explicitly when in
# scope. Reading the env files is idempotent.
[ -f "$ENV_FILE"        ] && { set -a; . "$ENV_FILE";        set +a; }
[ -f "$BROKER_ENV_FILE" ] && { set -a; . "$BROKER_ENV_FILE"; set +a; }

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

# Idempotent overwrite of a KEY=VAL line in an env file. Defaults to $ENV_FILE;
# pass a third arg to write to a different env file (e.g. $BROKER_ENV_FILE for
# EIP / INSTANCE_ID, which live with the broker-machine config).
env_set() {
  local key="$1" val="$2" file="${3:-$ENV_FILE}"
  if [ ! -f "$file" ]; then
    printf '%s=%s\n' "$key" "$val" > "$file"
    return
  fi
  if grep -q "^${key}=" "$file"; then
    awk -v k="$key" -v v="$val" '
      BEGIN { ow = 0 }
      $0 ~ "^"k"=" { print k"="v; ow = 1; next }
      { print }
      END { if (!ow) print k"="v }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
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
  [ "$TEST_MODE" = "1" ] && tag_val="agentkeys-broker-eip-test"

  # Precedence ladder, FIRST-MATCH wins (no allocate fires if any
  # earlier branch resolved the EIP):
  #
  #   A. INSTANCE_ID has an EIP attached → adopt it (no allocate, no
  #      re-associate; tag retroactively for future idempotency).
  #   B. Tagged EIP exists in account → reuse.
  #   C. EIP=… set in env file        → use it.
  #   D. Allocate fresh.

  # ── A. INSTANCE_ID already has an EIP attached → adopt ──
  if [ -n "${INSTANCE_ID:-}" ]; then
    local attached_ip allocation_id
    attached_ip=$(aws ec2 describe-instances --region "$REGION" \
      --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' \
      --output text 2>/dev/null)
    if [ -n "$attached_ip" ] && [ "$attached_ip" != "None" ]; then
      # Confirm it's an EIP (has AllocationId), not just an auto-assigned
      # public IP that disappears on stop/start.
      allocation_id=$(aws ec2 describe-addresses --region "$REGION" \
        --public-ips "$attached_ip" \
        --query 'Addresses[0].AllocationId' --output text 2>/dev/null)
      if [ -n "$allocation_id" ] && [ "$allocation_id" != "None" ]; then
        EIP="$attached_ip"
        skip "EIP $EIP already attached to $INSTANCE_ID (adopting; no allocation)"
        env_set EIP "$EIP" "$BROKER_ENV_FILE"
        # Best-effort retroactive tag so future runs find via path B.
        if [ "$DRY_RUN" = "0" ]; then
          aws ec2 create-tags --region "$REGION" --resources "$allocation_id" \
            --tags "Key=${tag_key},Value=${tag_val}" 2>/dev/null \
            && ok "tagged existing EIP as $tag_val (idempotency for re-runs)" \
            || warn "could not tag EIP $EIP (AllocationId=$allocation_id) — operator can `aws ec2 create-tags` by hand"
        fi
        return
      else
        warn "$INSTANCE_ID has public IP $attached_ip but it's not a static EIP — will allocate one in path B/D"
      fi
    fi
  fi

  # ── B. Tagged EIP in account → reuse ──
  local existing_eip
  existing_eip=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:${tag_key},Values=${tag_val}" \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null)
  if [ -n "$existing_eip" ] && [ "$existing_eip" != "None" ]; then
    skip "EIP $existing_eip already tagged $tag_val (reusing)"
    EIP="$existing_eip"
  # ── C. EIP from env file → use ──
  elif [ -n "${EIP:-}" ]; then
    skip "EIP $EIP provided via env file; not allocating new one"
  # ── D. Allocate fresh ──
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
  env_set EIP "$EIP" "$BROKER_ENV_FILE"

  # Associate to INSTANCE_ID if not already attached.
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
    warn "INSTANCE_ID unset in $BROKER_ENV_FILE — EIP unattached. Paste 'INSTANCE_ID=i-…' into that file once EC2 exists, then re-run: bash $0 --env-file $ENV_FILE --broker-env-file $BROKER_ENV_FILE$([ "$TEST_MODE" = "1" ] && echo " --test" || echo "") --only-step 4"
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

  # Worker hostnames come from the operator-workstation env file (they
  # carry the prod/test split: `signer.${ZONE}` vs `signer-test.${ZONE}`
  # etc.). Hardcoding `signer.${ZONE}` here would silently overwrite
  # prod DNS records to the test EIP when running --test — disaster.
  : "${SIGNER_HOST:?SIGNER_HOST missing — must be set in $ENV_FILE}"
  : "${WORKER_AUDIT_HOST:?WORKER_AUDIT_HOST missing — must be set in $ENV_FILE}"
  : "${WORKER_EMAIL_HOST:?WORKER_EMAIL_HOST missing — must be set in $ENV_FILE}"
  : "${WORKER_CRED_HOST:?WORKER_CRED_HOST missing — must be set in $ENV_FILE}"
  : "${WORKER_MEMORY_HOST:?WORKER_MEMORY_HOST missing — must be set in $ENV_FILE}"

  local change_batch
  change_batch=$(jq -n \
    --arg domain "$MAIL_DOMAIN" --arg region "$REGION" \
    --arg eip "$EIP" --arg broker "$BROKER_HOST" \
    --arg signer "$SIGNER_HOST" --arg audit "$WORKER_AUDIT_HOST" \
    --arg email "$WORKER_EMAIL_HOST" --arg cred "$WORKER_CRED_HOST" \
    --arg memory "$WORKER_MEMORY_HOST" \
    --arg t1 "$t1" --arg t2 "$t2" --arg t3 "$t3" '{
      Comment: "AgentKeys cloud bootstrap (DKIM/SPF/DMARC/MX + broker subdomains)",
      Changes: [
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t1)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t1).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t2)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t2).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t3)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t3).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$domain, Type:"MX",  TTL:300, ResourceRecords:[{Value:"10 inbound-smtp.\($region).amazonaws.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$domain, Type:"TXT", TTL:300, ResourceRecords:[{Value:"\"v=spf1 include:amazonses.com -all\""}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"_dmarc.\($domain)", Type:"TXT", TTL:300, ResourceRecords:[{Value:"\"v=DMARC1; p=quarantine; rua=mailto:dmarc@\($domain)\""}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$broker, Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$signer, Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$audit,  Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$email,  Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$cred,   Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$memory, Type:"A", TTL:300, ResourceRecords:[{Value:$eip}]}}
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
  if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
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

  # Apply the mail bucket policy here (was step 14 in earlier revisions).
  # SES validates write access to the receipt-rule target bucket at
  # `aws ses create-receipt-rule` call time (step 8). If the policy
  # granting ses.amazonaws.com PutObject isn't already on the bucket,
  # step 8 fails with `InvalidS3Configuration: Could not write to bucket`.
  # Pre-existing prod buckets had the policy from a prior run, so the
  # original step ordering worked by accident; freshly-created test
  # buckets exposed the bug.
  local current
  current=$(aws s3api get-bucket-policy --region "$REGION" --bucket "$BUCKET" \
    --query 'Policy' --output text 2>/dev/null || echo "{}")
  if echo "$current" | jq -e '.Statement[]? | select(.Sid=="AllowSESWriteInbound")' >/dev/null 2>&1; then
    skip "mail bucket policy already grants ses.amazonaws.com PutObject"
  else
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
    ok "mail bucket policy applied (SES write + daemon read)"
  fi
}

do_step_8() {
  # Receipt rule name carries the suffix so prod (`agentkeys-inbound`)
  # and test (`agentkeys-inbound-test`) can coexist on the same active
  # rule set without colliding. Without this, running --test sees the
  # prod rule already exists, silently skips, and SES has no route for
  # *@$MAIL_DOMAIN → verification mail never arrives at the test bucket.
  local rule_name="agentkeys-inbound${SUFFIX}"
  CUR_STEP=8; step "SES receipt rule (agentkeys/$rule_name)"
  # Ensure rule set exists.
  aws ses create-receipt-rule-set --rule-set-name agentkeys --region "$REGION" \
    >/dev/null 2>&1 || true

  # Pre-check: rule already on the set?
  local existing_rule
  existing_rule=$(aws ses describe-receipt-rule --rule-set-name agentkeys \
    --rule-name "$rule_name" --region "$REGION" \
    --query 'Rule.Name' --output text 2>/dev/null || echo "absent")
  if [ "$existing_rule" = "$rule_name" ]; then
    skip "receipt rule $rule_name already configured"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-receipt-rule $rule_name"; return; }
    aws ses create-receipt-rule --region "$REGION" --rule-set-name agentkeys \
      --rule "$(jq -n --arg name "$rule_name" --arg domain "$MAIL_DOMAIN" --arg bucket "$BUCKET" '{
        Name: $name, Enabled: true, ScanEnabled: true, TlsPolicy: "Optional",
        Recipients: [$domain],
        Actions: [{S3Action: {BucketName: $bucket, ObjectKeyPrefix: "inbound/"}}]
      }')" >/dev/null || die "create-receipt-rule failed"
    ok "receipt rule $rule_name created"
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
  CUR_STEP=12; step "IAM user $SSH_USER (operator SSH via EC2 Instance Connect)"
  if [ -z "${INSTANCE_ID:-}" ]; then
    skip "INSTANCE_ID unset in $BROKER_ENV_FILE — paste 'INSTANCE_ID=i-…' once EC2 exists, then re-run: bash $0 --env-file $ENV_FILE --broker-env-file $BROKER_ENV_FILE$([ "$TEST_MODE" = "1" ] && echo " --test" || echo "") --only-step 12"
    return
  fi

  if aws iam get-user --user-name "$SSH_USER" >/dev/null 2>&1; then
    skip "IAM user $SSH_USER already exists"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-user $SSH_USER"; return; }
    aws iam create-user --user-name "$SSH_USER" >/dev/null \
      || die "create-user $SSH_USER failed"
    ok "IAM user $SSH_USER created"
  fi

  # Inline policy: scoped ec2-instance-connect:SendSSHPublicKey on the
  # broker's INSTANCE_ID + describe APIs for the AWS CLI tooling to
  # resolve instance metadata. The Condition pins the OS user to
  # "agentkey" — Instance Connect refuses calls outside that allowlist.
  [ "$DRY_RUN" = "1" ] || aws iam put-user-policy --user-name "$SSH_USER" \
    --policy-name "${SSH_USER}-ec2ic" \
    --policy-document "$(jq -n \
      --arg acct "$ACCOUNT_ID" --arg id "$INSTANCE_ID" '{
        Version:"2012-10-17",
        Statement:[
          {Effect:"Allow",
           Action:"ec2-instance-connect:SendSSHPublicKey",
           Resource:"arn:aws:ec2:*:\($acct):instance/\($id)",
           Condition:{StringEquals:{"ec2:osuser":"agentkey"}}},
          {Effect:"Allow",
           Action:["ec2:DescribeInstances","ec2:DescribeInstanceConnectEndpoints"],
           Resource:"*"}
        ]
      }')" >/dev/null || die "put-user-policy for $SSH_USER failed"
  ok "$SSH_USER inline policy applied (scoped to $INSTANCE_ID)"

  local active_keys
  active_keys=$(aws iam list-access-keys --user-name "$SSH_USER" \
    --query 'AccessKeyMetadata[?Status==`Active`] | length(@)' --output text)
  if [ "$active_keys" -ge 1 ]; then
    skip "$SSH_USER already has $active_keys active access key(s) — operator must already hold them"
  else
    [ "$DRY_RUN" = "1" ] && { warn "DRY: would create-access-key $SSH_USER"; return; }
    warn "creating a new access key — SAVE THE SECRET, it is shown ONCE"
    local key_json key_id key_secret
    key_json=$(aws iam create-access-key --user-name "$SSH_USER" --output json) \
      || die "create-access-key failed"
    key_id=$(echo "$key_json"     | jq -r .AccessKey.AccessKeyId)
    key_secret=$(echo "$key_json" | jq -r .AccessKey.SecretAccessKey)
    printf "\n    %sAdd to ~/.aws/credentials as a new profile block:%s\n" \
      "$COLOR_HEAD" "$COLOR_RESET" >&2
    printf "      [%s]\n"                  "$SSH_USER"   >&2
    printf "      aws_access_key_id     = %s\n"     "$key_id"     >&2
    printf "      aws_secret_access_key = %s\n"     "$key_secret" >&2
    printf "      region                = %s\n\n"   "$REGION"     >&2
    ok "access key minted — NEVER commit to git"
  fi
}

do_step_13() {
  CUR_STEP=13; step "Per-data-class buckets + roles (delegates to provision-*.sh)"
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

do_step_14() {
  CUR_STEP=14; step "Initial mail bucket policy (static-IAM variant)"
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

do_step_15() {
  CUR_STEP=15; step "Summary + next steps"
  printf "\n${COLOR_OK}═══ Cloud bootstrap complete ═══${COLOR_RESET}\n\n" >&2
  printf "  Operator env file : %s\n" "$ENV_FILE" >&2
  printf "  Broker env file   : %s\n" "$BROKER_ENV_FILE" >&2
  printf "  Test mode         : %s\n" "$([ "$TEST_MODE" = "1" ] && echo "yes (-test suffix on IAM identifiers)" || echo "no (prod)")" >&2
  printf "  Region            : %s\n" "$REGION" >&2
  printf "  Zone              : %s (id: %s)\n" "$ZONE" "$PARENT_ZONE_ID" >&2
  printf "  Mail domain       : %s\n" "$MAIL_DOMAIN" >&2
  printf "  Broker host       : %s\n" "$BROKER_HOST" >&2
  printf "  Mail bucket       : s3://%s/\n" "$BUCKET" >&2
  printf "  Daemon user       : %s\n" "$DAEMON_USER" >&2
  printf "  Data role         : arn:aws:iam::%s:role/%s\n" "$ACCOUNT_ID" "$DATA_ROLE" >&2
  printf "  EIP               : %s\n" "${EIP:-(unallocated)}" >&2
  printf "  EIP attached to   : %s\n" "${INSTANCE_ID:-(unattached — paste INSTANCE_ID into $BROKER_ENV_FILE + re-run --only-step 4)}" >&2
  printf "\n  Next steps (in order):\n" >&2
  if [ -z "${INSTANCE_ID:-}" ]; then
    printf "    1. Launch EC2, paste 'INSTANCE_ID=i-…' into %s, re-run:\n" "$BROKER_ENV_FILE" >&2
    printf "         bash %s --env-file %s --broker-env-file %s%s --only-step 4\n" \
      "$0" "$ENV_FILE" "$BROKER_ENV_FILE" "$([ "$TEST_MODE" = "1" ] && echo " --test" || echo "")" >&2
    printf "    2. SSH into the host, clone the repo, then:\n" >&2
  else
    printf "    1. SSH into %s, clone the repo, then:\n" "${EIP:-<eip>}" >&2
  fi
  printf "         sudo bash scripts/setup-broker-host.sh --issuer-url https://%s --account-id %s --yes\n" \
    "$BROKER_HOST" "$ACCOUNT_ID" >&2
  printf "    %d. Once broker is publicly reachable, run docs/cloud-bootstrap.md §9 (OIDC federation upgrade).\n" \
    "$([ -z "${INSTANCE_ID:-}" ] && echo 3 || echo 2)" >&2
  printf "    %d. Chain bring-up: bash scripts/setup-heima.sh\n\n" \
    "$([ -z "${INSTANCE_ID:-}" ] && echo 4 || echo 3)" >&2

  printf "  Re-run any step surgically (idempotent):\n" >&2
  printf "    bash scripts/setup-cloud.sh --only-step 6   # re-UPSERT DNS\n" >&2
  printf "    bash scripts/setup-cloud.sh --only-step 12  # re-create SSH user (e.g. after EC2 replace)\n" >&2
  printf "    bash scripts/setup-cloud.sh --only-step 13  # re-run per-data-class provisioning\n\n" >&2
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
  in_scope 15 && do_step_15
}

main "$@"
