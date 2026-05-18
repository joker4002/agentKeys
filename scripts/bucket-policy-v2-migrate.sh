#!/usr/bin/env bash
# scripts/bucket-policy-v2-migrate.sh — apply the v2 §2.2 PrincipalTag
# migration to $BUCKET's policy. Idempotent: re-running is a no-op once
# the v2 markers are present.
#
# What it does:
#   1. Read the current bucket policy.
#   2. Check if Sid "AllowDataRolePutOwnCredentialsV2" is already present
#      AND the tag key is "agentkeys_actor_omni" — if so, skip.
#   3. Otherwise, back up the current policy to /tmp/bucket-policy-backup-*
#      and apply the v2 shape (cloud-setup.md §4.4 pattern with tag-key
#      renamed from agentkeys_user_wallet → agentkeys_actor_omni, plus
#      the missing 4th statement that grants PUT on the credentials/*
#      sub-prefix — the one omitted from the live policy today).
#
# Why this shape and not the demo doc's §2.2 verbatim:
#   v2-stage1-migration-and-demo.md §2.2 uses `Principal: { AWS: "*" }`
#   with `StringNotEquals: tag != ""` to enforce tag presence. That
#   shape has a security flaw cloud-setup.md §4.3 explicitly calls out:
#   "AWS evaluates negated string operators on missing context keys as
#   TRUE — a JWT carrying no AWS tags claim would silently bypass". The
#   §4.4 pattern (Principal pinned to agentkeys-data-role, prefix scoped
#   via ${aws:PrincipalTag/...}, list+get+put in three statements
#   because s3:prefix only applies to ListBucket) is the safer template
#   and matches what cloud-setup.md §4.4 calls "the cloud-enforced floor".
#
# Required env (sourced from scripts/operator-workstation.env):
#   ACCOUNT_ID, REGION, BUCKET
#
# Required AWS profile:
#   agentkeys-admin (puts s3:PutBucketPolicy)
#
# Usage:
#   bash scripts/bucket-policy-v2-migrate.sh
#   bash scripts/bucket-policy-v2-migrate.sh --dry-run   # print policy diff, don't apply

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

# Color helpers
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

# Source env file
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

ACCOUNT_ID="${ACCOUNT_ID:?ACCOUNT_ID required (operator-workstation.env)}"
REGION="${REGION:?REGION required}"
BUCKET="${BUCKET:?BUCKET required}"

# Caller-identity check (admin needed for PutBucketPolicy)
log "Preflight: AWS caller identity"
caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
  || die "aws sts get-caller-identity failed: $caller_arn — run: awsp agentkeys-admin"
arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
case "$arn_lc" in
  *":user/agentkeys-admin"*) ok "caller is admin: $caller_arn" ;;
  *) die "caller is $caller_arn — needs agentkeys-admin. Run: awsp agentkeys-admin" ;;
esac

# Read current policy
log "Reading current bucket policy"
current_policy=$(aws s3api get-bucket-policy \
                   --bucket "$BUCKET" --region "$REGION" \
                   --query Policy --output text 2>/dev/null || echo '')
if [ -z "$current_policy" ]; then
  warn "bucket has no policy yet — will apply v2 shape from scratch"
else
  ok "current policy retrieved ($(echo -n "$current_policy" | wc -c | tr -d ' ') bytes)"
fi

# Idempotency check: are we already on v2?
already_v2=0
if [ -n "$current_policy" ]; then
  has_v2_sid=$(echo "$current_policy" \
    | jq '[.Statement[] | select(.Sid == "AllowDataRolePutOwnCredentialsV2")] | length')
  has_v2_tag=$(echo "$current_policy" \
    | jq '[.Statement[] | (.. | strings? // empty) | select(contains("agentkeys_actor_omni"))] | length')
  if [ "${has_v2_sid:-0}" -gt 0 ] && [ "${has_v2_tag:-0}" -gt 0 ]; then
    already_v2=1
  fi
fi

if [ "$already_v2" = "1" ]; then
  skip "policy already has v2 markers (Sid AllowDataRolePutOwnCredentialsV2 + tag key agentkeys_actor_omni)"
  exit 0
fi

# Back up the current policy before mutating
ts=$(date -u +%Y%m%dT%H%M%SZ)
backup="/tmp/bucket-policy-backup-${BUCKET}-${ts}.json"
if [ -n "$current_policy" ]; then
  echo "$current_policy" | jq . > "$backup"
  ok "backed up current policy to $backup"
fi

# Build the v2 policy. jq --arg keeps values out of shell parameter
# expansion (per CLAUDE.md). The four statements mirror cloud-setup.md
# §4.4 with the tag key renamed from agentkeys_user_wallet to
# agentkeys_actor_omni; the V2-suffixed Sids are the idempotency marker.
new_policy=$(jq -n --arg bucket "$BUCKET" --arg acct "$ACCOUNT_ID" '{
  Version: "2012-10-17",
  Statement: [
    {
      Sid: "AllowSESWriteInbound",
      Effect: "Allow",
      Principal: { Service: "ses.amazonaws.com" },
      Action: "s3:PutObject",
      Resource: "arn:aws:s3:::\($bucket)/*",
      Condition: { StringEquals: { "aws:Referer": $acct } }
    },
    {
      Sid: "AllowDataRoleListOwnPrefixV2",
      Effect: "Allow",
      Principal: { AWS: "arn:aws:iam::\($acct):role/agentkeys-data-role" },
      Action: "s3:ListBucket",
      Resource: "arn:aws:s3:::\($bucket)",
      Condition: {
        StringLike: { "s3:prefix": "bots/${aws:PrincipalTag/agentkeys_actor_omni}/*" }
      }
    },
    {
      Sid: "AllowDataRoleGetOwnObjectsV2",
      Effect: "Allow",
      Principal: { AWS: "arn:aws:iam::\($acct):role/agentkeys-data-role" },
      Action: "s3:GetObject",
      Resource: "arn:aws:s3:::\($bucket)/bots/${aws:PrincipalTag/agentkeys_actor_omni}/*"
    },
    {
      Sid: "AllowDataRolePutOwnCredentialsV2",
      Effect: "Allow",
      Principal: { AWS: "arn:aws:iam::\($acct):role/agentkeys-data-role" },
      Action: ["s3:PutObject", "s3:DeleteObject"],
      Resource: "arn:aws:s3:::\($bucket)/bots/${aws:PrincipalTag/agentkeys_actor_omni}/credentials/*"
    }
  ]
}')

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would apply this policy (not applied):"
  echo "$new_policy" | jq .
  exit 0
fi

log "Applying v2 policy to s3://$BUCKET"
aws s3api put-bucket-policy --bucket "$BUCKET" --region "$REGION" \
  --policy "$new_policy" \
  || die "put-bucket-policy failed — see error above"

# Read back to confirm
log "Confirming write"
applied=$(aws s3api get-bucket-policy --bucket "$BUCKET" --region "$REGION" \
            --query Policy --output text 2>&1)
sid_count=$(echo "$applied" | jq '[.Statement[].Sid] | length')
ok "policy applied; $sid_count statement(s) live"
echo "$applied" | jq '.Statement[] | .Sid' | sed 's/^/      Sid: /' >&2

ok "v2 bucket policy migration complete"
echo >&2
echo "    Next: smoke-test the write via:" >&2
echo "      bash scripts/v2-stage1-demo.sh --only-step 8" >&2
