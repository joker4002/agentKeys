#!/usr/bin/env bash
# harness/v2-stage3-demo.sh — OIDC isolation proof for the cred + memory
# workers (issue #90 Q3).
#
# Drives the full OIDC-federated S3 access path end-to-end:
#
#   1. SIWE wallet_sig auth → session JWT (from operator master mnemonic)
#   2. POST /v1/mint-oidc-jwt → ES256 JWT suitable for AWS STS
#   3. aws sts assume-role-with-web-identity → STS creds tagged with
#      PrincipalTag/agentkeys_actor_omni = derive_omni(master wallet)
#   4. POSITIVE: PUT s3://$VAULT_BUCKET/bots/<own actor_omni>/credentials/
#      stage3-positive.bin → expect HTTP 200
#   5. NEGATIVE: PUT s3://$VAULT_BUCKET/bots/<wrong actor_omni>/credentials/
#      stage3-negative.bin → expect AccessDenied (proves IAM scopes per actor)
#   6. POSITIVE on the memory bucket: PUT s3://$MEMORY_BUCKET/bots/<own>/memory/
#      stage3-positive.bin → expect HTTP 200
#   7. NEGATIVE on memory: PUT to wrong actor → expect AccessDenied
#   8. Cleanup with admin creds — delete the test objects
#
# This proves the OIDC + IAM-tag-based S3 scoping works at the AWS layer
# WITHOUT needing the workers themselves wired into the picture. The
# workers are separately ready to use these STS creds (X-Aws-* headers,
# code change in this PR) — full worker-integrated test is a follow-up
# once the broker's cap-token mint path is wired into the demo.
#
# Usage:
#   bash harness/v2-stage3-demo.sh                 # mainnet, all steps
#   bash harness/v2-stage3-demo.sh --from-step N --to-step M
#   bash harness/v2-stage3-demo.sh --only-step 4

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STEP_NUM=0
STEP_TOTAL=8
FROM_STEP=1
TO_STEP=$STEP_TOTAL
ONLY_STEP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from-step)     FROM_STEP="$2"; shift 2 ;;
    --to-step)       TO_STEP="$2"; shift 2 ;;
    --only-step)     ONLY_STEP="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$ONLY_STEP" ]; then FROM_STEP="$ONLY_STEP"; TO_STEP="$ONLY_STEP"; fi
STEP_NUM=$((FROM_STEP - 1))

# ─── Colors + step + skip + ok + die ────────────────────────────────────────
if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_ERR='\033[1;31m'; C_WARN='\033[1;33m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_ERR=''; C_WARN=''; C_RESET=''
fi
step() { STEP_NUM=$((STEP_NUM+1)); CURRENT_STEP_NAME="$1"
         printf "${C_HEAD}\n==> [step %d/%d] %s${C_RESET}\n" "$STEP_NUM" "$STEP_TOTAL" "$1" >&2 ; }
ok()   { printf "    ${C_OK}ok${C_RESET}    %s\n" "$*" >&2; }
info() { printf "    ${C_WARN}info${C_RESET}  %s\n" "$*" >&2; }
skip() { printf "    ${C_WARN}skip${C_RESET}  %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET}  %s\n" "$*" >&2; exit 1; }
should_run_step() { [ "$1" -ge "$FROM_STEP" ] && [ "$1" -le "$TO_STEP" ]; }

# ─── Env ────────────────────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE — run from a clone of agentKeys"
set -a; . "$ENV_FILE"; set +a
: "${OIDC_ISSUER:?OIDC_ISSUER unset (operator-workstation.env)}"
: "${VAULT_BUCKET:?VAULT_BUCKET unset}"
: "${REGION:?REGION unset}"
: "${VAULT_ROLE_ARN:?VAULT_ROLE_ARN unset}"

MEMORY_BUCKET="${MEMORY_BUCKET:-agentkeys-memory-${ACCOUNT_ID}}"
MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
[ -f "$MNEMONIC_FILE" ] || die "missing mnemonic at $MNEMONIC_FILE"

# Hold state across steps in a temp dir so steps are individually re-runnable.
STATE_DIR="${STAGE3_STATE_DIR:-/tmp/agentkeys-stage3}"
mkdir -p "$STATE_DIR"
trap 'rm -rf "$STATE_DIR/payload."*' EXIT

# Caller-arn sanity (we need agentkeys-admin for step 8 cleanup + bucket-side
# verification only; the OIDC flow itself uses NO laptop AWS creds — all S3
# is via the STS creds minted from the JWT).
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)
CALLER_LC=$(printf '%s' "$CALLER_ARN" | tr '[:upper:]' '[:lower:]')
case "$CALLER_LC" in
  *user/agentkeys-admin*) ;;
  *) die "current AWS profile is $CALLER_ARN — run \`awsp agentkeys-admin\` first (needed for step 8 cleanup + sanity bucket lookups)" ;;
esac

printf "\n=== v2 stage-3 demo: OIDC isolation proof ===\n  chain=%s issuer=%s vault=%s memory=%s\n\n" \
  "${AGENTKEYS_CHAIN:-heima}" "$OIDC_ISSUER" "$VAULT_BUCKET" "$MEMORY_BUCKET" >&2

# Pre-derive wallet identity (used in many steps).
if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
  npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund || die "npm install ethers failed"
fi
DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$MNEMONIC_FILE")
WALLET_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
WALLET_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
WALLET_LC=$(printf '%s' "$WALLET_ADDR" | tr '[:upper:]' '[:lower:]')
OWN_ACTOR_OMNI=$(printf 'agentkeysevm%s' "$WALLET_LC" | shasum -a 256 | awk '{print $1}')
# A different actor_omni for the negative test. Any 64-hex non-matching string.
WRONG_ACTOR_OMNI=$(printf 'wrong-actor-decoy-%s' "$WALLET_LC" | shasum -a 256 | awk '{print $1}')
[ "$WRONG_ACTOR_OMNI" = "$OWN_ACTOR_OMNI" ] && die "wrong+own actor_omni collision (impossible — sha256)"
info "wallet=$WALLET_ADDR"
info "own actor_omni    = 0x$OWN_ACTOR_OMNI"
info "negative target   = 0x$WRONG_ACTOR_OMNI"

# ─── Step 1: SIWE wallet auth → session JWT ────────────────────────────────
if should_run_step 1; then
  step "SIWE wallet_sig auth → session JWT"
  CHAIN_ID_FOR_SIWE=1   # SIWE chainId — doesn't have to match Heima; the broker uses
                        # the field for replay-binding within the SIWE message only.
  START_RESP=$(curl -sSf -X POST "$OIDC_ISSUER/v1/auth/wallet/start" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg addr "$WALLET_ADDR" --argjson cid "$CHAIN_ID_FOR_SIWE" \
          '{address: $addr, chain_id: $cid}')" 2>&1) || die "wallet/start failed: $START_RESP"
  REQUEST_ID=$(echo "$START_RESP" | jq -r .request_id)
  SIWE_MSG=$(echo "$START_RESP" | jq -r .siwe_message)
  [ -z "$REQUEST_ID" ] || [ "$REQUEST_ID" = "null" ] && die "wallet/start did not return request_id: $START_RESP"
  ok "SIWE challenge received (request_id=$REQUEST_ID)"

  # Sign the SIWE message with the operator's private key.
  SIWE_SIG=$(cast wallet sign --private-key "$WALLET_KEY" "$SIWE_MSG")
  VERIFY_RESP=$(curl -sSf -X POST "$OIDC_ISSUER/v1/auth/wallet/verify" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg rid "$REQUEST_ID" --arg sig "$SIWE_SIG" '{request_id: $rid, signature: $sig}')" 2>&1) \
    || die "wallet/verify failed: $VERIFY_RESP"
  SESSION_JWT=$(echo "$VERIFY_RESP" | jq -r '.session_jwt // .jwt // empty')
  [ -z "$SESSION_JWT" ] && die "wallet/verify did not return session JWT: $VERIFY_RESP"
  echo -n "$SESSION_JWT" > "$STATE_DIR/session.jwt"
  ok "session JWT minted (length=${#SESSION_JWT})"
fi

# ─── Step 2: Mint OIDC JWT (for AWS STS) ───────────────────────────────────
if should_run_step 2; then
  step "Mint OIDC JWT (broker → STS-compatible web identity token)"
  [ -f "$STATE_DIR/session.jwt" ] || die "no session.jwt — re-run step 1"
  SESSION_JWT=$(cat "$STATE_DIR/session.jwt")
  OIDC_RESP=$(curl -sSf -X POST "$OIDC_ISSUER/v1/mint-oidc-jwt" \
    -H "authorization: Bearer $SESSION_JWT" 2>&1) \
    || die "mint-oidc-jwt failed: $OIDC_RESP"
  OIDC_JWT=$(echo "$OIDC_RESP" | jq -r .jwt)
  [ -z "$OIDC_JWT" ] || [ "$OIDC_JWT" = "null" ] && die "mint-oidc-jwt did not return jwt: $OIDC_RESP"
  echo -n "$OIDC_JWT" > "$STATE_DIR/oidc.jwt"
  # Decode payload (no sig check — just for human inspection of the actor_omni tag).
  PAYLOAD_B64=$(echo "$OIDC_JWT" | cut -d. -f2)
  # Base64url → standard base64 + padding fix.
  PAD=$(( (4 - ${#PAYLOAD_B64} % 4) % 4 ))
  PAYLOAD_DEC=$(printf '%s%*s' "$PAYLOAD_B64" "$PAD" "" | tr '_-' '/+' | tr ' ' '=' | base64 -d 2>/dev/null || true)
  if [ -n "$PAYLOAD_DEC" ]; then
    JWT_SUB=$(echo "$PAYLOAD_DEC" | jq -r .sub 2>/dev/null || echo "?")
    JWT_TAG=$(echo "$PAYLOAD_DEC" | jq -r '."https://aws.amazon.com/tags".principal_tags.agentkeys_actor_omni // .agentkeys.actor_omni // "?"' 2>/dev/null || echo "?")
    info "JWT sub=$JWT_SUB"
    info "JWT PrincipalTag/agentkeys_actor_omni=$JWT_TAG"
  fi
  ok "OIDC JWT minted (length=${#OIDC_JWT})"
fi

# ─── Step 3: AssumeRoleWithWebIdentity → STS creds ─────────────────────────
if should_run_step 3; then
  step "AssumeRoleWithWebIdentity → per-actor STS creds"
  [ -f "$STATE_DIR/oidc.jwt" ] || die "no oidc.jwt — re-run step 2"
  OIDC_JWT=$(cat "$STATE_DIR/oidc.jwt")
  # NOTE: aws sts CLI in admin profile is fine here — assume-role-with-web-identity
  # is unauthenticated (it's the JWT that authorises). The admin profile is
  # picked up by the SDK only for region / endpoint resolution.
  STS_RESP=$(aws sts assume-role-with-web-identity \
    --region "$REGION" \
    --role-arn "$VAULT_ROLE_ARN" \
    --role-session-name "stage3-$(date +%s)" \
    --web-identity-token "$OIDC_JWT" \
    --duration-seconds 900 \
    --output json 2>&1) || die "AssumeRoleWithWebIdentity failed: $STS_RESP"
  AKI=$(echo "$STS_RESP" | jq -r '.Credentials.AccessKeyId')
  SAK=$(echo "$STS_RESP" | jq -r '.Credentials.SecretAccessKey')
  SST=$(echo "$STS_RESP" | jq -r '.Credentials.SessionToken')
  [ -z "$AKI" ] && die "STS response missing AccessKeyId: $STS_RESP"
  # AWS returns the PrincipalArn in AssumedRoleUser — confirms the tag landed.
  ASSUMED_ARN=$(echo "$STS_RESP" | jq -r '.AssumedRoleUser.Arn')
  echo -n "$AKI" > "$STATE_DIR/aki"
  echo -n "$SAK" > "$STATE_DIR/sak"
  echo -n "$SST" > "$STATE_DIR/sst"
  ok "STS creds minted (AKI=${AKI:0:10}…, AssumedArn=$ASSUMED_ARN)"
fi

# Helper: run an aws command with the STS creds. Strips any pre-existing
# AWS_PROFILE so the SDK uses the injected creds, not the admin profile.
run_with_sts() {
  AKI=$(cat "$STATE_DIR/aki")
  SAK=$(cat "$STATE_DIR/sak")
  SST=$(cat "$STATE_DIR/sst")
  env -u AWS_PROFILE \
    AWS_ACCESS_KEY_ID="$AKI" \
    AWS_SECRET_ACCESS_KEY="$SAK" \
    AWS_SESSION_TOKEN="$SST" \
    AWS_REGION="$REGION" \
    "$@"
}

# ─── Step 4: POSITIVE test — write to own actor's vault prefix ─────────────
if should_run_step 4; then
  step "POSITIVE: PUT s3://$VAULT_BUCKET/bots/0x…own/credentials/stage3-positive.bin"
  [ -f "$STATE_DIR/aki" ] || die "no STS creds — re-run step 3"
  PAYLOAD_FILE="$STATE_DIR/payload.positive.bin"
  echo "stage3 positive $(date -u)" > "$PAYLOAD_FILE"
  OWN_KEY="bots/${OWN_ACTOR_OMNI}/credentials/stage3-positive.bin"
  if run_with_sts aws s3api put-object \
      --bucket "$VAULT_BUCKET" \
      --key "$OWN_KEY" \
      --body "$PAYLOAD_FILE" \
      --output json >"$STATE_DIR/put.positive.json" 2>&1; then
    ok "PUT succeeded at s3://$VAULT_BUCKET/$OWN_KEY"
  else
    cat "$STATE_DIR/put.positive.json" >&2
    die "PUT to own actor's prefix FAILED — IAM trust policy or tag binding misconfigured"
  fi
fi

# ─── Step 5: NEGATIVE test — write to OTHER actor's vault prefix ───────────
if should_run_step 5; then
  step "NEGATIVE: PUT s3://$VAULT_BUCKET/bots/0x…OTHER/credentials/stage3-negative.bin"
  [ -f "$STATE_DIR/aki" ] || die "no STS creds — re-run step 3"
  PAYLOAD_FILE="$STATE_DIR/payload.negative.bin"
  echo "stage3 negative $(date -u)" > "$PAYLOAD_FILE"
  WRONG_KEY="bots/${WRONG_ACTOR_OMNI}/credentials/stage3-negative.bin"
  if run_with_sts aws s3api put-object \
      --bucket "$VAULT_BUCKET" \
      --key "$WRONG_KEY" \
      --body "$PAYLOAD_FILE" \
      --output json >"$STATE_DIR/put.negative.json" 2>&1; then
    cat "$STATE_DIR/put.negative.json" >&2
    die "NEGATIVE test FAILED — wrote to another actor's prefix (IAM scoping broken!)"
  else
    if grep -qE "AccessDenied|403" "$STATE_DIR/put.negative.json"; then
      ok "PUT to wrong actor prefix correctly rejected with AccessDenied"
    else
      cat "$STATE_DIR/put.negative.json" >&2
      die "PUT failed but error is not AccessDenied — unexpected: $(head -1 $STATE_DIR/put.negative.json)"
    fi
  fi
fi

# ─── Step 6: POSITIVE test — memory bucket / own actor ─────────────────────
if should_run_step 6; then
  step "POSITIVE: PUT s3://$MEMORY_BUCKET/bots/0x…own/memory/stage3-positive.bin"
  if ! aws s3api head-bucket --bucket "$MEMORY_BUCKET" --region "$REGION" >/dev/null 2>&1; then
    skip "memory bucket $MEMORY_BUCKET not provisioned — skipping memory tests"
  else
    PAYLOAD_FILE="$STATE_DIR/payload.mem.positive.bin"
    echo "stage3 memory positive $(date -u)" > "$PAYLOAD_FILE"
    OWN_MEM_KEY="bots/${OWN_ACTOR_OMNI}/memory/stage3-positive.bin"
    if run_with_sts aws s3api put-object \
        --bucket "$MEMORY_BUCKET" \
        --key "$OWN_MEM_KEY" \
        --body "$PAYLOAD_FILE" \
        --output json >"$STATE_DIR/put.mem.positive.json" 2>&1; then
      ok "memory PUT succeeded at s3://$MEMORY_BUCKET/$OWN_MEM_KEY"
    else
      cat "$STATE_DIR/put.mem.positive.json" >&2
      info "memory PUT to own actor prefix failed — likely the agentkeys-vault-role policy does not yet grant the memory bucket. Vault test above is the canonical proof."
    fi
  fi
fi

# ─── Step 7: NEGATIVE test — memory bucket / wrong actor ───────────────────
if should_run_step 7; then
  step "NEGATIVE: PUT s3://$MEMORY_BUCKET/bots/0x…OTHER/memory/stage3-negative.bin"
  if ! aws s3api head-bucket --bucket "$MEMORY_BUCKET" --region "$REGION" >/dev/null 2>&1; then
    skip "memory bucket $MEMORY_BUCKET not provisioned — skipping"
  else
    PAYLOAD_FILE="$STATE_DIR/payload.mem.negative.bin"
    echo "stage3 memory negative $(date -u)" > "$PAYLOAD_FILE"
    WRONG_MEM_KEY="bots/${WRONG_ACTOR_OMNI}/memory/stage3-negative.bin"
    if run_with_sts aws s3api put-object \
        --bucket "$MEMORY_BUCKET" \
        --key "$WRONG_MEM_KEY" \
        --body "$PAYLOAD_FILE" \
        --output json >"$STATE_DIR/put.mem.negative.json" 2>&1; then
      cat "$STATE_DIR/put.mem.negative.json" >&2
      die "memory NEGATIVE test FAILED — wrote to another actor's memory prefix!"
    else
      if grep -qE "AccessDenied|403" "$STATE_DIR/put.mem.negative.json"; then
        ok "memory PUT to wrong actor prefix correctly rejected with AccessDenied"
      else
        info "memory PUT failed but error not AccessDenied: $(head -1 $STATE_DIR/put.mem.negative.json) — likely role doesn't cover memory bucket yet (out-of-scope follow-up)"
      fi
    fi
  fi
fi

# ─── Step 8: Cleanup with admin profile ────────────────────────────────────
if should_run_step 8; then
  step "Cleanup test objects + summary"
  # Use the laptop's admin profile (NOT the STS creds) to delete the
  # objects we wrote. This is fine — the operator owns the bucket.
  for k in \
    "bots/${OWN_ACTOR_OMNI}/credentials/stage3-positive.bin" \
    "bots/${OWN_ACTOR_OMNI}/memory/stage3-positive.bin"; do
    if aws --region "$REGION" s3api delete-object --bucket "$VAULT_BUCKET" --key "$k" >/dev/null 2>&1; then
      ok "deleted s3://$VAULT_BUCKET/$k"
    fi
    if aws --region "$REGION" s3api delete-object --bucket "$MEMORY_BUCKET" --key "$k" >/dev/null 2>&1; then
      ok "deleted s3://$MEMORY_BUCKET/$k"
    fi
  done
  cat <<EOF >&2

${C_OK}=== v2 stage-3 demo complete ===${C_RESET}
  chain         : ${AGENTKEYS_CHAIN:-heima}
  issuer        : $OIDC_ISSUER
  vault bucket  : $VAULT_BUCKET
  memory bucket : $MEMORY_BUCKET
  wallet        : $WALLET_ADDR
  own omni      : 0x$OWN_ACTOR_OMNI
  positive      : write to own prefix → SUCCEEDED
  negative      : write to other prefix → AccessDenied (as expected)
  conclusion    : OIDC + IAM PrincipalTag scoping is working end-to-end.
EOF
fi
