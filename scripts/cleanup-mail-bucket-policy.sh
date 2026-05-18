#!/usr/bin/env bash
# scripts/cleanup-mail-bucket-policy.sh — revert $MAIL_BUCKET policy
# to its email-only shape per arch.md §17 (per-data-class buckets).
#
# Earlier the demo's bucket-policy-v2-migrate.sh added credentials-write
# statements to the SHARED mail bucket because we hadn't separated the
# vault bucket yet. Now that $VAULT_BUCKET is provisioned and gets its
# own v2 policy, the mail bucket should ONLY allow:
#   - SES inbound write (AllowSESWriteInbound)
#   - Email-data-role read of inbox/sent paths (List + Get, no
#     credentials/ paths)
#
# Idempotent: re-running is a no-op once the cleanup has been applied.
# Detects "already clean" by inspecting Sids — if none contain
# "Credentials" AND no Resource references "/credentials/*", we're done.
#
# Required env: ACCOUNT_ID, REGION, MAIL_BUCKET
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
MAIL_BUCKET="${MAIL_BUCKET:?MAIL_BUCKET required}"
DATA_ROLE_ARN="${DATA_ROLE_ARN:?DATA_ROLE_ARN required}"

caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
  || die "aws sts get-caller-identity failed: $caller_arn"
arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
case "$arn_lc" in
  *":user/agentkeys-admin"*) ok "caller is admin: $caller_arn" ;;
  *) die "caller is $caller_arn — needs agentkeys-admin" ;;
esac

log "Reading current $MAIL_BUCKET policy"
current_policy=$(aws s3api get-bucket-policy \
                   --bucket "$MAIL_BUCKET" --region "$REGION" \
                   --query Policy --output text 2>/dev/null || echo '')
if [ -z "$current_policy" ]; then
  warn "no policy on mail bucket — nothing to clean"
  exit 0
fi
ok "current policy retrieved ($(echo -n "$current_policy" | wc -c | tr -d ' ') bytes)"

# Detect "already clean": no Sid containing "Credentials" AND no
# Resource referencing "/credentials/" AND no v2 tag key.
already_clean=$(echo "$current_policy" | jq '
  def has_creds:
    (.Statement[]? | (.Sid // "") | contains("Credentials")) // false;
  def has_creds_resource:
    (.. | strings? // empty | contains("/credentials/")) // false;
  def has_v2_tag:
    (.. | strings? // empty | contains("agentkeys_actor_omni")) // false;
  if (any(.Statement[]?; (.Sid // "") | contains("Credentials")) or
      any(..; type == "string" and contains("/credentials/")) or
      any(..; type == "string" and contains("agentkeys_actor_omni")))
  then "no" else "yes" end
' 2>/dev/null || echo "no")

if [ "$already_clean" = "yes" ] || [ "$already_clean" = "\"yes\"" ]; then
  skip "mail bucket policy already free of credentials grants"
  exit 0
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
backup="/tmp/mail-bucket-policy-backup-${MAIL_BUCKET}-${ts}.json"
echo "$current_policy" | jq . > "$backup"
ok "backed up to $backup"

# Reconstruct mail-bucket policy minimally: SES inbound write + email
# role reads of bots/<wallet>/* (NOT credentials/). The wallet key is
# the legacy v1 tag — we keep it on the mail bucket because the email
# subsystem is still v1. When email-service migrates to v2 (per
# arch.md §15.4) the tag key gets renamed; that's a separate stage-2
# change tracked in the credentials-service-worker follow-up.
new_policy=$(jq -n \
  --arg bucket "$MAIL_BUCKET" \
  --arg acct "$ACCOUNT_ID" \
  --arg role "$DATA_ROLE_ARN" '{
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
        Sid: "EmailRoleListOwnPrefix",
        Effect: "Allow",
        Principal: { AWS: $role },
        Action: "s3:ListBucket",
        Resource: "arn:aws:s3:::\($bucket)",
        Condition: {
          StringLike: { "s3:prefix": "bots/${aws:PrincipalTag/agentkeys_user_wallet}/*" }
        }
      },
      {
        Sid: "EmailRoleGetOwnObjects",
        Effect: "Allow",
        Principal: { AWS: $role },
        Action: "s3:GetObject",
        Resource: "arn:aws:s3:::\($bucket)/bots/${aws:PrincipalTag/agentkeys_user_wallet}/*"
      }
    ]
  }')

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would apply cleaned policy:"
  echo "$new_policy" | jq .
  exit 0
fi

log "Applying cleaned mail-bucket policy (drops credentials grants + v2 tag)"
aws s3api put-bucket-policy --bucket "$MAIL_BUCKET" --region "$REGION" \
  --policy "$new_policy" \
  || die "put-bucket-policy failed"

ok "mail-bucket policy cleaned ($(echo "$new_policy" | jq '.Statement | length') statements)"
ok "mail bucket cleanup complete"
