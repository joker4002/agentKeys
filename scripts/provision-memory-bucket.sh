#!/usr/bin/env bash
# scripts/provision-memory-bucket.sh — idempotent creation of the
# per-data-class memory bucket ($MEMORY_BUCKET) per arch.md §17.
#
# Mirror of scripts/provision-vault-bucket.sh — same structure, different
# bucket. Per arch.md §17.1, per-data-class buckets are mandatory because
# S3 exposes encryption / lifecycle / replication / CloudTrail at the
# bucket level only — folding credentials and memory and email into one
# bucket forces the loosest setting on every dimension.
#
# What it does (each step idempotent via "check first, then act"):
#   1. head-bucket — if 200, skip create.
#   2. create-bucket if missing (LocationConstraint only for non-us-east-1).
#   3. put-public-access-block (idempotent overwrite).
#   4. put-bucket-encryption with SSE-S3 AES-256 default.
#
# Required env (sourced from scripts/operator-workstation.env):
#   ACCOUNT_ID, REGION, MEMORY_BUCKET
#
# Required AWS profile: agentkeys-admin
#
# Usage:
#   bash scripts/provision-memory-bucket.sh
#   bash scripts/provision-memory-bucket.sh --dry-run

set -euo pipefail

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_SKIP='\033[1;33m'
  C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_SKIP=''; C_WARN=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
skip() { printf "    ${C_SKIP}skip${C_RESET} %s\n" "$*" >&2; }
warn() { printf "    ${C_WARN}warn${C_RESET} %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

ACCOUNT_ID="${ACCOUNT_ID:?ACCOUNT_ID required}"
REGION="${REGION:?REGION required}"
MEMORY_BUCKET="${MEMORY_BUCKET:?MEMORY_BUCKET required — add it to operator-workstation.env}"

# Caller identity (admin needed)
log "Preflight: AWS caller identity"
caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
  || die "aws sts get-caller-identity failed: $caller_arn"
arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
case "$arn_lc" in
  *":user/agentkeys-admin"*) ok "caller is admin: $caller_arn" ;;
  *) die "caller is $caller_arn — needs agentkeys-admin. Run: awsp agentkeys-admin" ;;
esac

# Step 1+2: bucket existence
log "Bucket existence: s3://$MEMORY_BUCKET"
if aws s3api head-bucket --bucket "$MEMORY_BUCKET" --region "$REGION" >/dev/null 2>&1; then
  skip "bucket already exists"
else
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — would create-bucket $MEMORY_BUCKET in $REGION"
  else
    log "Creating bucket"
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$MEMORY_BUCKET" --region "$REGION" \
        || die "create-bucket failed"
    else
      aws s3api create-bucket --bucket "$MEMORY_BUCKET" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" \
        || die "create-bucket failed"
    fi
    ok "bucket created"
  fi
fi

# Step 3: block public access
log "Public access block"
pab_target=$(jq -n '{
  BlockPublicAcls: true, IgnorePublicAcls: true,
  BlockPublicPolicy: true, RestrictPublicBuckets: true
}')
if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would put-public-access-block: $pab_target"
else
  aws s3api put-public-access-block --bucket "$MEMORY_BUCKET" --region "$REGION" \
    --public-access-block-configuration "$pab_target" \
    || die "put-public-access-block failed"
  ok "block-public-access applied (all four flags = true)"
fi

# Step 4: default encryption SSE-S3
log "Default encryption (SSE-S3 AES-256)"
enc_target=$(jq -n '{
  Rules: [ { ApplyServerSideEncryptionByDefault: { SSEAlgorithm: "AES256" } } ]
}')
if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would put-bucket-encryption: $enc_target"
else
  aws s3api put-bucket-encryption --bucket "$MEMORY_BUCKET" --region "$REGION" \
    --server-side-encryption-configuration "$enc_target" \
    || die "put-bucket-encryption failed"
  ok "default SSE-S3 applied (client-side AES-256-GCM is the primary; this is a second layer)"
fi

ok "memory bucket provisioning complete: s3://$MEMORY_BUCKET"
