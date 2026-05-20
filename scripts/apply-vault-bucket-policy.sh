#!/usr/bin/env bash
# scripts/apply-vault-bucket-policy.sh — apply the v2 PrincipalTag
# policy to $VAULT_BUCKET (the credentials-only bucket, per arch.md §17).
#
# Replaces the older scripts/bucket-policy-v2-migrate.sh which mistakenly
# targeted the shared mail bucket. The cleanup of the mail bucket
# policy (stripping any stray credentials grants) lives in a sibling
# script: scripts/cleanup-mail-bucket-policy.sh.
#
# Idempotent: re-running is a no-op once the v2 markers
# (Sid VaultPolicyV2 + tag key agentkeys_actor_omni) are present.
#
# What it does:
#   1. Read current bucket policy on $VAULT_BUCKET.
#   2. If a v2-marker Sid is already present, skip.
#   3. Otherwise, back up the current policy (if any) to
#      /tmp/vault-bucket-policy-backup-*.json and apply the v2 shape.
#
# Required env: ACCOUNT_ID, REGION, VAULT_BUCKET
# Required AWS profile: agentkeys-admin

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
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"

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
VAULT_BUCKET="${VAULT_BUCKET:?VAULT_BUCKET required}"
VAULT_ROLE_ARN="${VAULT_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-vault-role}"

# Caller identity
caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
  || die "aws sts get-caller-identity failed: $caller_arn"
arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
case "$arn_lc" in
  *":user/agentkeys-admin"*) ok "caller is admin: $caller_arn" ;;
  *) die "caller is $caller_arn — needs agentkeys-admin" ;;
esac

# Read current
log "Reading current bucket policy on s3://$VAULT_BUCKET"
current_policy=$(aws s3api get-bucket-policy \
                   --bucket "$VAULT_BUCKET" --region "$REGION" \
                   --query Policy --output text 2>/dev/null || echo '')
if [ -z "$current_policy" ]; then
  warn "no policy yet — applying v2 shape from scratch"
else
  ok "current policy retrieved ($(echo -n "$current_policy" | wc -c | tr -d ' ') bytes)"
fi

# Idempotency check (v3 marker — codex review P2: split ListBucket from
# object actions so ListBucket can carry the s3:prefix condition; v2
# allowed any tagged session to enumerate the entire bucket).
already_v3=0
if [ -n "$current_policy" ]; then
  has_v3_sid=$(echo "$current_policy" \
    | jq '[.Statement[] | select(.Sid == "VaultListV3" or .Sid == "VaultObjectsV3")] | length' 2>/dev/null || echo 0)
  if [ "${has_v3_sid:-0}" -gt 1 ]; then already_v3=1; fi
fi
if [ "$already_v3" = "1" ]; then
  skip "policy already has v3 markers (VaultListV3 + VaultObjectsV3)"
  exit 0
fi

# Backup
ts=$(date -u +%Y%m%dT%H%M%SZ)
if [ -n "$current_policy" ]; then
  backup="/tmp/vault-bucket-policy-backup-${VAULT_BUCKET}-${ts}.json"
  echo "$current_policy" | jq . > "$backup"
  ok "backed up to $backup"
fi

# Build v3 policy (codex review P2 fix): SPLIT ListBucket from object
# actions into two statements so ListBucket can carry an `s3:prefix`
# condition. v2 grouped all four actions under one statement with
# Resource[bucket, bucket/...] and no prefix condition — meaning any
# tagged session could list the entire bucket, enumerating every
# actor's key names even though Get/Put were tag-scoped.
#
# v3:
#   VaultListV3   — s3:ListBucket on the bucket ARN, conditioned on
#                   s3:prefix matching the caller's PrincipalTag prefix.
#   VaultObjectsV3 — Get/Put/Delete on the bucket/bots/${tag}/credentials/* ARN.
#
# IAM evaluates resource and identity policy allows as a union, so this
# layer must independently scope cross-actor listing — relying on the
# role's inline policy alone is insufficient defense.
new_policy=$(jq -n \
  --arg bucket "$VAULT_BUCKET" \
  --arg role_arn "$VAULT_ROLE_ARN" '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "VaultListV3",
        Effect: "Allow",
        Principal: { AWS: $role_arn },
        Action: "s3:ListBucket",
        Resource: "arn:aws:s3:::\($bucket)",
        Condition: {
          Null: { "aws:PrincipalTag/agentkeys_actor_omni": "false" },
          StringLike: { "s3:prefix": "bots/${aws:PrincipalTag/agentkeys_actor_omni}/credentials/*" }
        }
      },
      {
        Sid: "VaultObjectsV3",
        Effect: "Allow",
        Principal: { AWS: $role_arn },
        Action: [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource: "arn:aws:s3:::\($bucket)/bots/${aws:PrincipalTag/agentkeys_actor_omni}/credentials/*",
        Condition: {
          Null: { "aws:PrincipalTag/agentkeys_actor_omni": "false" }
        }
      }
    ]
  }')

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would apply policy:"
  echo "$new_policy" | jq .
  exit 0
fi

log "Applying v2 vault-bucket policy"
aws s3api put-bucket-policy --bucket "$VAULT_BUCKET" --region "$REGION" \
  --policy "$new_policy" \
  || die "put-bucket-policy failed"

log "Confirming write"
applied=$(aws s3api get-bucket-policy --bucket "$VAULT_BUCKET" --region "$REGION" \
            --query Policy --output text 2>&1)
sid_count=$(echo "$applied" | jq '[.Statement[].Sid] | length')
ok "policy applied; $sid_count statement(s) live"

ok "vault-bucket policy applied"
