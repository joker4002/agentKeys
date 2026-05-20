#!/usr/bin/env bash
# harness/v2-stage3-demo.sh — OIDC isolation proof for the cred + memory
# workers (issue #90 Q3 + codex review followups).
#
# Drives the full OIDC-federated S3 access path end-to-end:
#
#   1. SIWE wallet_sig auth → session JWT (from operator master mnemonic)
#   2. POST /v1/mint-oidc-jwt → ES256 JWT suitable for AWS STS
#   3. aws sts assume-role-with-web-identity (TWO sessions, codex P2):
#      - against VAULT_ROLE_ARN → creds scoped to bots/<own>/credentials/*
#      - against MEMORY_ROLE_ARN → creds scoped to bots/<own>/memory/*
#      Both tagged with PrincipalTag/agentkeys_actor_omni = derive_omni(wallet)
#   4. POSITIVE write: PUT s3://VAULT/bots/<own>/credentials/… → 200
#   5. NEGATIVE write: PUT s3://VAULT/bots/<wrong>/credentials/… → AccessDenied
#   6. NEGATIVE list  (codex P2 followup): ListBucket s3://VAULT
#      with prefix bots/<wrong>/… → AccessDenied (proves cross-actor key
#      enumeration is blocked by the bucket-policy v3 + role inline policy)
#   7. POSITIVE write: PUT s3://MEMORY/bots/<own>/memory/… → 200
#   8. NEGATIVE write: PUT s3://MEMORY/bots/<wrong>/memory/… → AccessDenied
#   9. NEGATIVE list  (codex P2 followup): ListBucket s3://MEMORY
#      with prefix bots/<wrong>/… → AccessDenied
#  10. Cross-role isolation (defense in depth): VAULT STS creds tried
#      against the MEMORY bucket → AccessDenied (each role only covers
#      its own bucket). Mirror: MEMORY creds tried against VAULT bucket
#      → AccessDenied.
#  11. Cleanup with admin creds — delete the test objects
#
# Proves OIDC + IAM-tag-based S3 scoping works at the AWS layer:
#  - per-actor isolation within a bucket (steps 5, 6, 8, 9)
#  - per-data-class isolation across buckets (step 10)
#
# The workers are separately wired to accept these STS creds (X-Aws-*
# headers, code change in this PR) — full worker-integrated test is a
# followup once the broker's cap-token mint path is wired into the demo.
#
# Usage:
#   bash harness/v2-stage3-demo.sh                 # mainnet, all steps
#   bash harness/v2-stage3-demo.sh --from-step N --to-step M
#   bash harness/v2-stage3-demo.sh --only-step 4

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STEP_NUM=0
STEP_TOTAL=11
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
: "${MEMORY_BUCKET:?MEMORY_BUCKET unset (operator-workstation.env — added in #90 Q3 followup)}"
: "${REGION:?REGION unset}"
: "${VAULT_ROLE_ARN:?VAULT_ROLE_ARN unset}"
: "${MEMORY_ROLE_ARN:?MEMORY_ROLE_ARN unset (operator-workstation.env — added in #90 Q3 followup)}"
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

# ─── Step 3: AssumeRoleWithWebIdentity → STS creds (vault + memory) ────────
# Mints TWO independent STS sessions, one per data-class role. Each
# session is scoped via PrincipalTag/agentkeys_actor_omni to the caller's
# own prefix in its bucket. Step 10 below proves the two are NOT
# interchangeable — vault creds can't touch the memory bucket and vice
# versa (defense-in-depth across data classes).
mint_sts_for_role() {
  local role_arn="$1" label="$2"
  local resp aki sak sst arn
  resp=$(aws sts assume-role-with-web-identity \
    --region "$REGION" \
    --role-arn "$role_arn" \
    --role-session-name "stage3-${label}-$(date +%s)" \
    --web-identity-token "$(cat "$STATE_DIR/oidc.jwt")" \
    --duration-seconds 900 \
    --output json 2>&1) || die "AssumeRoleWithWebIdentity ($label) failed: $resp"
  aki=$(echo "$resp" | jq -r '.Credentials.AccessKeyId')
  sak=$(echo "$resp" | jq -r '.Credentials.SecretAccessKey')
  sst=$(echo "$resp" | jq -r '.Credentials.SessionToken')
  arn=$(echo "$resp" | jq -r '.AssumedRoleUser.Arn')
  [ -z "$aki" ] && die "STS ($label) response missing AccessKeyId: $resp"
  echo -n "$aki" > "$STATE_DIR/aki.$label"
  echo -n "$sak" > "$STATE_DIR/sak.$label"
  echo -n "$sst" > "$STATE_DIR/sst.$label"
  ok "STS creds minted ($label, AKI=${aki:0:10}…, AssumedArn=$arn)"
}

if should_run_step 3; then
  step "AssumeRoleWithWebIdentity → per-actor STS creds (vault + memory)"
  [ -f "$STATE_DIR/oidc.jwt" ] || die "no oidc.jwt — re-run step 2"
  mint_sts_for_role "$VAULT_ROLE_ARN"  vault
  mint_sts_for_role "$MEMORY_ROLE_ARN" memory
fi

# Helper: run an aws command with the named STS session ($1 = vault|memory).
# Strips any pre-existing AWS_PROFILE so the SDK uses the injected creds,
# not the admin profile.
run_with_sts() {
  local label="$1"; shift
  local aki sak sst
  aki=$(cat "$STATE_DIR/aki.$label" 2>/dev/null) \
    || die "no STS creds for label='$label' — re-run step 3"
  sak=$(cat "$STATE_DIR/sak.$label")
  sst=$(cat "$STATE_DIR/sst.$label")
  env -u AWS_PROFILE \
    AWS_ACCESS_KEY_ID="$aki" \
    AWS_SECRET_ACCESS_KEY="$sak" \
    AWS_SESSION_TOKEN="$sst" \
    AWS_REGION="$REGION" \
    "$@"
}

# Generic helper for asserting a `aws s3api` command fails with AccessDenied
# (the IAM-rejection signature). Other failures (NoCredentialsErr, region
# mismatch, NoSuchBucket, throttling) are real bugs in the demo setup and
# MUST hard-fail — they look like a pass to a naive grep, which was the
# original codex concern.
expect_access_denied() {
  local out="$1" what="$2"
  if grep -qiE "An error occurred \([^)]*AccessDenied[^)]*\)|HTTP 403|AccessDeniedException" "$out"; then
    ok "$what correctly rejected with AccessDenied"
  elif grep -qi "Unable to locate credentials\|NoSuchBucket\|InvalidAccessKeyId\|TokenRefreshRequired\|RequestExpired" "$out"; then
    cat "$out" >&2
    die "$what failed for a non-IAM reason — likely setup bug (creds/bucket/region). Inspect $out."
  else
    cat "$out" >&2
    die "$what failed but error doesn't look like AccessDenied — inspect $out manually."
  fi
}

# ─── Step 4: POSITIVE — write to own vault prefix ──────────────────────────
if should_run_step 4; then
  step "POSITIVE: PUT s3://$VAULT_BUCKET/bots/0x…own/credentials/stage3-positive.bin"
  PAYLOAD_FILE="$STATE_DIR/payload.vault.positive.bin"
  echo "stage3 vault positive $(date -u)" > "$PAYLOAD_FILE"
  OWN_VAULT_KEY="bots/${OWN_ACTOR_OMNI}/credentials/stage3-positive.bin"
  if run_with_sts vault aws s3api put-object \
      --bucket "$VAULT_BUCKET" \
      --key "$OWN_VAULT_KEY" \
      --body "$PAYLOAD_FILE" \
      --output json >"$STATE_DIR/put.vault.positive.json" 2>&1; then
    ok "PUT succeeded at s3://$VAULT_BUCKET/$OWN_VAULT_KEY"
  else
    cat "$STATE_DIR/put.vault.positive.json" >&2
    die "vault PUT to own prefix FAILED — IAM trust policy or tag binding misconfigured"
  fi
fi

# ─── Step 5: NEGATIVE write — wrong actor's vault prefix ───────────────────
if should_run_step 5; then
  step "NEGATIVE: PUT s3://$VAULT_BUCKET/bots/0x…OTHER/credentials/stage3-negative.bin"
  PAYLOAD_FILE="$STATE_DIR/payload.vault.negative.bin"
  echo "stage3 vault negative $(date -u)" > "$PAYLOAD_FILE"
  WRONG_VAULT_KEY="bots/${WRONG_ACTOR_OMNI}/credentials/stage3-negative.bin"
  if run_with_sts vault aws s3api put-object \
      --bucket "$VAULT_BUCKET" \
      --key "$WRONG_VAULT_KEY" \
      --body "$PAYLOAD_FILE" \
      --output json >"$STATE_DIR/put.vault.negative.json" 2>&1; then
    cat "$STATE_DIR/put.vault.negative.json" >&2
    die "vault NEGATIVE write FAILED — wrote to another actor's prefix (IAM scoping broken!)"
  else
    expect_access_denied "$STATE_DIR/put.vault.negative.json" "vault PUT to wrong actor prefix"
  fi
fi

# ─── Step 6: NEGATIVE list — cross-actor enumeration on vault ──────────────
# codex review P2: pre-fix the bucket policy + role inline policy allowed
# bucket-wide ListBucket; actor A could enumerate actor B's key names
# even though Get/Put were prefix-scoped. The v3 policies (this PR)
# carry `s3:prefix=bots/${PrincipalTag}/credentials/*` on the ListBucket
# statement. This step verifies it's truly enforced — listing under the
# WRONG actor's prefix MUST AccessDenied.
if should_run_step 6; then
  step "NEGATIVE list: ListBucket s3://$VAULT_BUCKET prefix=bots/0x…OTHER/credentials/"
  if run_with_sts vault aws s3api list-objects-v2 \
      --bucket "$VAULT_BUCKET" \
      --prefix "bots/${WRONG_ACTOR_OMNI}/credentials/" \
      --output json >"$STATE_DIR/list.vault.negative.json" 2>&1; then
    cat "$STATE_DIR/list.vault.negative.json" >&2
    die "vault NEGATIVE list FAILED — enumerated another actor's keys (bucket-policy regression)"
  else
    expect_access_denied "$STATE_DIR/list.vault.negative.json" "vault ListBucket on wrong-actor prefix"
  fi
fi

# ─── Step 7: POSITIVE — write to own memory prefix ─────────────────────────
if should_run_step 7; then
  step "POSITIVE: PUT s3://$MEMORY_BUCKET/bots/0x…own/memory/stage3-positive.bin"
  PAYLOAD_FILE="$STATE_DIR/payload.mem.positive.bin"
  echo "stage3 memory positive $(date -u)" > "$PAYLOAD_FILE"
  OWN_MEM_KEY="bots/${OWN_ACTOR_OMNI}/memory/stage3-positive.bin"
  if run_with_sts memory aws s3api put-object \
      --bucket "$MEMORY_BUCKET" \
      --key "$OWN_MEM_KEY" \
      --body "$PAYLOAD_FILE" \
      --output json >"$STATE_DIR/put.mem.positive.json" 2>&1; then
    ok "memory PUT succeeded at s3://$MEMORY_BUCKET/$OWN_MEM_KEY"
  else
    cat "$STATE_DIR/put.mem.positive.json" >&2
    die "memory PUT to own prefix FAILED — MEMORY_ROLE_ARN inline policy / bucket policy misconfigured"
  fi
fi

# ─── Step 8: NEGATIVE write — wrong actor's memory prefix ──────────────────
if should_run_step 8; then
  step "NEGATIVE: PUT s3://$MEMORY_BUCKET/bots/0x…OTHER/memory/stage3-negative.bin"
  PAYLOAD_FILE="$STATE_DIR/payload.mem.negative.bin"
  echo "stage3 memory negative $(date -u)" > "$PAYLOAD_FILE"
  WRONG_MEM_KEY="bots/${WRONG_ACTOR_OMNI}/memory/stage3-negative.bin"
  if run_with_sts memory aws s3api put-object \
      --bucket "$MEMORY_BUCKET" \
      --key "$WRONG_MEM_KEY" \
      --body "$PAYLOAD_FILE" \
      --output json >"$STATE_DIR/put.mem.negative.json" 2>&1; then
    cat "$STATE_DIR/put.mem.negative.json" >&2
    die "memory NEGATIVE write FAILED — wrote to another actor's memory prefix!"
  else
    expect_access_denied "$STATE_DIR/put.mem.negative.json" "memory PUT to wrong actor prefix"
  fi
fi

# ─── Step 9: NEGATIVE list — cross-actor enumeration on memory ─────────────
if should_run_step 9; then
  step "NEGATIVE list: ListBucket s3://$MEMORY_BUCKET prefix=bots/0x…OTHER/memory/"
  if run_with_sts memory aws s3api list-objects-v2 \
      --bucket "$MEMORY_BUCKET" \
      --prefix "bots/${WRONG_ACTOR_OMNI}/memory/" \
      --output json >"$STATE_DIR/list.mem.negative.json" 2>&1; then
    cat "$STATE_DIR/list.mem.negative.json" >&2
    die "memory NEGATIVE list FAILED — enumerated another actor's memory keys"
  else
    expect_access_denied "$STATE_DIR/list.mem.negative.json" "memory ListBucket on wrong-actor prefix"
  fi
fi

# ─── Step 10: Cross-role isolation (per-data-class blast radius) ───────────
# Vault-role creds MUST NOT reach the memory bucket; memory-role creds
# MUST NOT reach the vault bucket. This is per arch.md §17.2 — sharing
# one role across data classes collapses blast radius. The two roles'
# inline policies + the two bucket policies' Principal: $ROLE_ARN
# pinning enforce this.
if should_run_step 10; then
  step "Cross-role isolation: vault creds → memory bucket, memory creds → vault bucket"
  PAYLOAD_FILE="$STATE_DIR/payload.cross.bin"
  echo "stage3 cross-role $(date -u)" > "$PAYLOAD_FILE"
  if run_with_sts vault aws s3api put-object \
      --bucket "$MEMORY_BUCKET" \
      --key "bots/${OWN_ACTOR_OMNI}/memory/cross-role.bin" \
      --body "$PAYLOAD_FILE" >"$STATE_DIR/cross.vault-to-memory.json" 2>&1; then
    die "vault creds wrote to memory bucket — cross-role isolation broken!"
  else
    expect_access_denied "$STATE_DIR/cross.vault-to-memory.json" "vault creds → memory bucket"
  fi
  if run_with_sts memory aws s3api put-object \
      --bucket "$VAULT_BUCKET" \
      --key "bots/${OWN_ACTOR_OMNI}/credentials/cross-role.bin" \
      --body "$PAYLOAD_FILE" >"$STATE_DIR/cross.memory-to-vault.json" 2>&1; then
    die "memory creds wrote to vault bucket — cross-role isolation broken!"
  else
    expect_access_denied "$STATE_DIR/cross.memory-to-vault.json" "memory creds → vault bucket"
  fi
fi

# ─── Step 11: Cleanup with admin profile ───────────────────────────────────
if should_run_step 11; then
  step "Cleanup test objects + summary"
  # Use the laptop's admin profile (NOT the STS creds) to delete the
  # objects we wrote. Only the POSITIVE-step objects exist — every
  # negative + cross-role attempt should have AccessDenied'd.
  if aws --region "$REGION" s3api delete-object \
        --bucket "$VAULT_BUCKET" \
        --key "bots/${OWN_ACTOR_OMNI}/credentials/stage3-positive.bin" >/dev/null 2>&1; then
    ok "deleted s3://$VAULT_BUCKET/bots/${OWN_ACTOR_OMNI}/credentials/stage3-positive.bin"
  fi
  if aws --region "$REGION" s3api delete-object \
        --bucket "$MEMORY_BUCKET" \
        --key "bots/${OWN_ACTOR_OMNI}/memory/stage3-positive.bin" >/dev/null 2>&1; then
    ok "deleted s3://$MEMORY_BUCKET/bots/${OWN_ACTOR_OMNI}/memory/stage3-positive.bin"
  fi
  cat <<EOF >&2

${C_OK}=== v2 stage-3 demo complete ===${C_RESET}
  chain          : ${AGENTKEYS_CHAIN:-heima}
  issuer         : $OIDC_ISSUER
  vault bucket   : $VAULT_BUCKET   (role: $VAULT_ROLE_ARN)
  memory bucket  : $MEMORY_BUCKET  (role: $MEMORY_ROLE_ARN)
  wallet         : $WALLET_ADDR
  own omni       : 0x$OWN_ACTOR_OMNI

  Coverage:
    [4]  vault PUT  own prefix       → SUCCEEDED
    [5]  vault PUT  other prefix     → AccessDenied
    [6]  vault LIST other prefix     → AccessDenied (codex P2 fix)
    [7]  memory PUT own prefix       → SUCCEEDED
    [8]  memory PUT other prefix     → AccessDenied
    [9]  memory LIST other prefix    → AccessDenied (codex P2 fix)
    [10] vault creds → memory bucket → AccessDenied (per-data-class isolation)
    [10] memory creds → vault bucket → AccessDenied (per-data-class isolation)

  Conclusion: OIDC + IAM PrincipalTag scoping is enforced both within
              a bucket (per-actor) AND across buckets (per-data-class).
EOF
fi
