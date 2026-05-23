#!/usr/bin/env bash
# scripts/provision-memory-role.sh — idempotent creation of
# `agentkeys-memory-role` per arch.md §17.2 (per-bucket IAM role).
#
# Mirror of scripts/provision-vault-role.sh, scoped to the memory bucket
# + the `memory/` prefix.
#
# Per arch.md §17.2: sharing one role across vault + memory + audit
# + email collapses blast radii. Memory gets its own role so a future
# memory-worker compromise can't read credential blobs and vice versa.
#
# What it does (each step idempotent):
#   1. iam get-role agentkeys-memory-role — if 200, skip create.
#   2. create-role with OIDC trust if missing.
#   3. put-role-policy with the memory-only inline policy
#      (idempotent overwrite). Inline grants:
#      - s3:GetObject + s3:PutObject + s3:DeleteObject on
#        $MEMORY_BUCKET/bots/${aws:PrincipalTag/agentkeys_actor_omni}/memory/*
#      - s3:ListBucket on $MEMORY_BUCKET with the
#        s3:prefix=bots/${aws:PrincipalTag/agentkeys_actor_omni}/memory/* condition
#
# Required env: ACCOUNT_ID, REGION, BROKER_HOST, OIDC_PROVIDER_ARN, MEMORY_BUCKET
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
BROKER_HOST="${BROKER_HOST:?BROKER_HOST required}"
OIDC_PROVIDER_ARN="${OIDC_PROVIDER_ARN:?OIDC_PROVIDER_ARN required}"
MEMORY_BUCKET="${MEMORY_BUCKET:?MEMORY_BUCKET required}"

# ROLE_NAME derives from $MEMORY_ROLE_ARN — see provision-vault-role.sh
# for the why (prod-clobber prevention; same 2026-05-23 incident).
if [ -n "${MEMORY_ROLE_ARN:-}" ]; then
  ROLE_NAME="${MEMORY_ROLE_ARN##*/}"
else
  ROLE_NAME="agentkeys-memory-role"
fi
INLINE_POLICY_NAME="${ROLE_NAME}-inline"

# Caller identity (admin needed)
caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
  || die "aws sts get-caller-identity failed: $caller_arn"
arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
case "$arn_lc" in
  *":user/agentkeys-admin"*) ok "caller is admin: $caller_arn" ;;
  *) die "caller is $caller_arn — needs agentkeys-admin" ;;
esac

# Trust policy: federated via the broker's OIDC provider, with tag
# presence guarded via Null operator (cloud-setup.md §4.3 warns against
# StringNotEquals on missing keys). Identical to vault-role trust.
trust_policy=$(jq -n \
  --arg provider "$OIDC_PROVIDER_ARN" \
  --arg aud_key "${BROKER_HOST}:aud" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Federated: $provider },
      Action: ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
      Condition: {
        StringEquals: { ($aud_key): "sts.amazonaws.com" },
        Null: { "aws:RequestTag/agentkeys_actor_omni": "false" }
      }
    }]
  }')

# Step 1+2: role existence
log "Role existence: $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  skip "role already exists"
  if [ "$DRY_RUN" = "0" ]; then
    log "Refreshing trust policy"
    aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
      --policy-document "$trust_policy" \
      || die "update-assume-role-policy failed"
    ok "trust policy refreshed"
  fi
else
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — would create-role $ROLE_NAME with trust: $trust_policy"
  else
    log "Creating role $ROLE_NAME"
    aws iam create-role --role-name "$ROLE_NAME" \
      --assume-role-policy-document "$trust_policy" \
      --description "v2 stage-2 memory data-class role per arch.md §17.2" \
      || die "create-role failed"
    ok "role created"
  fi
fi

# Step 3: inline policy. Three statements (List + Get + Put-or-Delete)
# mirroring the vault-role shape, but scoped to the memory bucket + the
# `memory/` prefix.
inline_policy=$(jq -n --arg bucket "$MEMORY_BUCKET" '{
  Version: "2012-10-17",
  Statement: [
    {
      Sid: "MemoryListOwnPrefix",
      Effect: "Allow",
      Action: "s3:ListBucket",
      Resource: "arn:aws:s3:::\($bucket)",
      Condition: {
        StringLike: { "s3:prefix": "bots/${aws:PrincipalTag/agentkeys_actor_omni}/memory/*" }
      }
    },
    {
      Sid: "MemoryGetOwnObjects",
      Effect: "Allow",
      Action: "s3:GetObject",
      Resource: "arn:aws:s3:::\($bucket)/bots/${aws:PrincipalTag/agentkeys_actor_omni}/memory/*"
    },
    {
      Sid: "MemoryPutAndDeleteOwnObjects",
      Effect: "Allow",
      Action: ["s3:PutObject", "s3:DeleteObject"],
      Resource: "arn:aws:s3:::\($bucket)/bots/${aws:PrincipalTag/agentkeys_actor_omni}/memory/*"
    }
  ]
}')

log "Inline policy: $INLINE_POLICY_NAME"
if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would put-role-policy: $inline_policy"
else
  aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name "$INLINE_POLICY_NAME" \
    --policy-document "$inline_policy" \
    || die "put-role-policy failed"
  ok "inline policy applied ($(echo "$inline_policy" | jq '.Statement | length') statements)"
fi

# Final: print the ARN so the orchestrator can stash it
role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || echo "?")
ok "memory role ready: $role_arn"
echo "$role_arn"
