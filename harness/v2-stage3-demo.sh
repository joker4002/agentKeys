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
#  11. (NEW) Worker encrypt/decrypt roundtrip — credentials:
#      mint cap-token via /v1/cap/cred-store → POST plaintext to
#      cred worker /v1/cred/store (KEK-encrypts, S3 PUTs envelope) →
#      mint /v1/cap/cred-fetch cap → POST to /v1/cred/fetch (S3 GETs,
#      KEK-decrypts) → assert plaintext roundtrips byte-for-byte.
#      SKIPS cleanly when on-chain scope isn't set yet (need --webauthn
#      via stage-1 step 13 first). This is the test that actually
#      exercises the worker-side AES-256-GCM envelope (the unit tests
#      in envelope.rs cover the primitive; this proves the HTTP path).
#  12. (NEW) Worker encrypt/decrypt roundtrip — memory: same shape
#      against the memory worker (/v1/memory/put + /v1/memory/get).
#  13-18. Negative cap data-class-mismatch (cred↔memory) + #195/#196
#      master-self + cross-actor scope semantics.
#  19-21. (NEW, #201) Config data class isolation (master-only taxonomy):
#      19 = config creds write own bots/<O_master>/config/ prefix (200) but
#           are AccessDenied at the memory + vault buckets, and memory creds
#           are AccessDenied at the config bucket (per-data-class layer 4);
#      20 = a config-class cap is rejected by the memory + cred workers, and
#      21 = a memory/cred-class cap is rejected by the config worker — both
#           with cap_data_class_mismatch (the cap-authz isolation gate).
#  22. Cleanup with admin creds — delete the test objects
#
# Proves OIDC + IAM-tag-based S3 scoping works at the AWS layer:
#  - per-actor isolation within a bucket (steps 5, 6, 8, 9)
#  - per-data-class isolation across buckets (step 10 cred↔memory; step 19 config)
#  - per-data-class cap-authz isolation (steps 14-15 cred↔memory; steps 20-21 config)
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
# Shared helper: resolve_active_master_dkh (detect the operator's active master
# device hash — #164 keccak(omni) or legacy EOA keccak(deployer_addr)). Used by
# step 16. Defines functions only (safe to source before env). See harness/scripts/_lib.sh.
. "$REPO_ROOT/harness/scripts/_lib.sh"
STEP_NUM=0
STEP_TOTAL=22
FROM_STEP=1
TO_STEP=$STEP_TOTAL
ONLY_STEP=""
# Strict mode (default): unmet prerequisites = demo failure. Operator
# must satisfy them before running. Use --allow-skip to opt into the
# previous behavior (skip prereq-missing steps and continue) when
# iterating against a partial environment.
#
# Codex adversarial review fix: prior demo could report "16/16 green"
# while internally skipping the actual encrypt/decrypt + cross-class
# rejection assertions. That's exactly the "hardcoded bypass" pattern
# we want to forbid in CI.
# --allow-skip is a per-reason allowlist, NOT a blanket bypass.
#   --allow-skip                         → legacy: all reasons allowed (dev only)
#   --allow-skip=scope-not-set           → only the scope-not-set prereq may skip
#   --allow-skip=scope-not-set,broker-misconfig  → comma-separated set
#   --ci                                 CI run: tolerate skip when the #164
#                                        passkey-register prereqs are unavailable
#                                        (never the deprecated EOA path); local
#                                        (no --ci) requires the passkey register.
#
# Codex H1 (2026-05-23): blanket --allow-skip in CI lets stage 3 report success
# while bypassing the four-layer isolation invariants it's supposed to test
# (worker chain-verify, cap data-class mismatch, etc). CI must pass an explicit
# reason list, and prereq_missing must tag each skip with a reason so non-
# allowlisted reasons fail closed.
#
# Reason taxonomy (extend as new prereq checks land):
#   scope-not-set            agent's service scope not granted on chain
#   agent-file-missing       no demo-agent file on disk
#   agent-file-invalid       agent file missing required field
#   broker-misconfig         broker missing chain RPC or contract addresses
#   device-role-missing      device not granted ROLE_CAP_MINT on chain
#   agent-sts-mint-failed    auth chain broken upstream of this stage's checks
#   master-not-registered    master device not on chain w/ CAP_MINT (step 16, #196)
#   agent-not-registered     agent device not on chain (step 17 cross-actor scope)
ALLOW_SKIP_REASONS=""   # empty = strict mode (every prereq dies); * = all
STEP_OUTCOMES=()        # filled in per-step: "ok|skip|fail" — drives final summary
# Steps 11-12 sign STS creds AS the agent, so they need a MASTER-HELD agent key.
# A real §10.2-paired agent keeps its key in the sandbox (the operator path: prove
# the roundtrip in-sandbox via phase1-wire-demo.sh). MOCK_AGENT auto-provisions a
# master-held DEV agent that MOCKS the sandbox actor so 11-12 run unattended — the
# CI path. Auto-on under --ci; opt-in elsewhere via --mock-agent.
MOCK_AGENT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from-step)        FROM_STEP="$2"; shift 2 ;;
    --to-step)          TO_STEP="$2"; shift 2 ;;
    --only-step)        ONLY_STEP="$2"; shift 2 ;;
    --allow-skip)       ALLOW_SKIP_REASONS="*"; shift ;;
    --ci)               export AGENTKEYS_CI=1; shift ;;   # CI run: tolerate skip when #164 passkey prereqs absent (never EOA)
    --mock-agent)       MOCK_AGENT=1; shift ;;            # auto-provision a master-held dev agent for steps 11-12 (mocks the sandbox actor)
    --allow-skip=*)     ALLOW_SKIP_REASONS="${1#--allow-skip=}"; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Back-compat alias for code paths that still test $ALLOW_SKIP (boolean).
# 1 when any reason is allowed; 0 in strict mode.
if [ -n "$ALLOW_SKIP_REASONS" ]; then ALLOW_SKIP=1; else ALLOW_SKIP=0; fi
# CI mocks the sandbox agent (no real sandbox in CI). Operator runs (no --ci) keep
# MOCK_AGENT off → a sandbox-paired agent routes to the in-sandbox proof instead.
[ -n "${AGENTKEYS_CI:-}" ] && MOCK_AGENT=1

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

# Codex review fix (high): unmet-prereq paths must FAIL in strict mode.
# In --allow-skip=<reason> mode they skip ONLY when reason is allowlisted.
# The final summary distinguishes ok vs skip vs fail per step so the demo
# can't claim coverage for paths it didn't actually exercise.
#
# Signature: prereq_missing <reason-tag> <message>
#   reason-tag MUST come from the taxonomy at the top of this file.
#   Reasons not in $ALLOW_SKIP_REASONS fail closed (return 1 → step dies).
_reason_allowed() {
  local reason="$1" allowlist="$ALLOW_SKIP_REASONS"
  case "$allowlist" in
    "")      return 1 ;;                # strict mode
    "*")     return 0 ;;                # legacy --allow-skip (all reasons)
    *)
      # Comma-separated list — match the reason as a whole token.
      case ",$allowlist," in
        *",$reason,"*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac
}
prereq_missing() {
  local reason msg
  if [ $# -ge 2 ]; then
    reason="$1"; shift; msg="$*"
  else
    # Untagged call-site (legacy) — treat as wildcard "unknown" reason which
    # only the legacy --allow-skip (=*) allows. Strict + per-reason modes
    # always fail untagged calls. Forces every call-site to migrate to a tag.
    reason="UNTAGGED"; msg="$1"
  fi
  if _reason_allowed "$reason"; then
    skip "$msg  (allowed skip reason: $reason)"
    STEP_OUTCOMES+=("$STEP_NUM:skip:$reason:$msg")
    return 0
  fi
  printf "    ${C_ERR}fail${C_RESET}  %s\n" "prereq missing [$reason] — $msg (allow via --allow-skip=$reason for dev iteration)" >&2
  STEP_OUTCOMES+=("$STEP_NUM:fail:$reason:$msg")
  return 1
}
record_ok() { STEP_OUTCOMES+=("$STEP_NUM:ok:$1"); }
# A step that is CORRECTLY run elsewhere (the sandbox), not a missing prereq. On the
# operator, the agent-side roundtrip (steps 11-12) can't run — the §10.2 agent's key
# lives in the sandbox — so it is DEFERRED there, not failed. `deferred` is counted
# separately and NEVER triggers FAILED/INCOMPLETE: the operator demo stays GREEN, and
# the agent-side coverage is proven by the sandbox harness (phase1-wire-demo.sh --real
# → sandbox-agent-isolation.sh). Returns 0.
defer_to_sandbox() {
  printf "    ${C_WARN}defer${C_RESET} %s\n" "$1 — run on the sandbox (see the runbook On Sandbox)" >&2
  STEP_OUTCOMES+=("$STEP_NUM:deferred:sandbox:$1")
}
should_run_step() { [ "$1" -ge "$FROM_STEP" ] && [ "$1" -le "$TO_STEP" ]; }

# ─── Env ────────────────────────────────────────────────────────────────────
# ENV_FILE: caller-supplied env var takes precedence; default = prod.
# Lets `ENV_FILE=scripts/operator-workstation.test.env bash harness/v2-stage3-demo.sh`
# (or CI's in-place rewrite of the default path) re-point at test resources.
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE — run from a clone of agentKeys"
set -a; . "$ENV_FILE"; set +a
: "${OIDC_ISSUER:?OIDC_ISSUER unset (operator-workstation.env)}"
: "${VAULT_BUCKET:?VAULT_BUCKET unset}"
: "${MEMORY_BUCKET:?MEMORY_BUCKET unset (operator-workstation.env — added in #90 Q3 followup)}"
: "${REGION:?REGION unset}"
: "${VAULT_ROLE_ARN:?VAULT_ROLE_ARN unset}"
: "${MEMORY_ROLE_ARN:?MEMORY_ROLE_ARN unset (operator-workstation.env — added in #90 Q3 followup)}"

# Deployer-wallet resolution: prefer a raw private-key file (the CI path,
# and the operator's test-deployer path) over a mnemonic. Set
# HEIMA_DEPLOYER_KEY_FILE=/path/to/0x-key.txt to skip the mnemonic derive.
# Mnemonic fallback preserves the existing operator dogfood flow that uses
# ./test-hei in the repo root.
# Default to the canonical key location ~/.agentkeys/heima-deployer.key (what
# _lib.sh::resolve_master_key + every other heima-*.sh script use) so stage 3
# finds the operator's deployer key without requiring HEIMA_DEPLOYER_KEY_FILE to
# be set every run. Override with HEIMA_DEPLOYER_KEY_FILE; ./test-hei mnemonic
# remains the fallback.
DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-deployer.key}"
MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
if [ -f "$DEPLOYER_KEY_FILE" ]; then
  USE_KEY_FILE=1
else
  USE_KEY_FILE=0
  [ -f "$MNEMONIC_FILE" ] || die "no deployer key at $DEPLOYER_KEY_FILE (override with HEIMA_DEPLOYER_KEY_FILE) and no mnemonic at $MNEMONIC_FILE — set one or the other"
fi

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
  # Soft-fail to warn: the admin check exists for step 8 (cleanup) +
  # sanity bucket lookups. CI runs as the OIDC-assumed
  # github-actions-agentkeys-e2e role which has list/get/delete on
  # test buckets (per docs/ci-setup.md §4 inline policy
  # agentkeys-e2e-verify-s3) — sufficient for steps 1-7 + the cleanup
  # in step 8. Steps that genuinely need agentkeys-admin perms (none
  # on the stage-3 critical path today) will fail loudly when they
  # actually exercise IAM-admin actions. Same softening pattern as
  # the equivalent check in v2-stage1-demo.sh + heima-scope-set.sh.
  *) info "caller is $CALLER_ARN — may or may not have required perms; proceeding (admin needed for step 8 cleanup + bucket lookups)" ;;
esac

printf "\n=== v2 stage-3 demo: OIDC isolation proof ===\n  chain=%s issuer=%s vault=%s memory=%s\n\n" \
  "${AGENTKEYS_CHAIN:-heima}" "$OIDC_ISSUER" "$VAULT_BUCKET" "$MEMORY_BUCKET" >&2

# Pre-derive wallet identity (used in many steps). Two paths land on the
# same (WALLET_KEY, WALLET_ADDR) pair:
#   1. HEIMA_DEPLOYER_KEY_FILE — raw 0x-prefixed private key; preferred path
#                                (CI + test-deployer dogfood). No npm + ethers
#                                round-trip; relies only on `cast` (already on
#                                PATH from foundry-toolchain action).
#   2. HEIMA_DEPLOYER_MNEMONIC_FILE (defaults to ./test-hei) — legacy operator
#                                dogfood path. Requires ethers via npm.
if [ "$USE_KEY_FILE" = "1" ]; then
  WALLET_KEY=$(tr -d '\r\n[:space:]' < "$DEPLOYER_KEY_FILE")
  [[ "$WALLET_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] \
    || die "HEIMA_DEPLOYER_KEY_FILE=$DEPLOYER_KEY_FILE: content not in 0x<64hex> form"
  WALLET_ADDR=$(cast wallet address --private-key "$WALLET_KEY") \
    || die "cast wallet address failed (cast on PATH? key valid?)"
else
  if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
    npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund || die "npm install ethers failed"
  fi
  DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$MNEMONIC_FILE")
  WALLET_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
  WALLET_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
fi
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
    record_ok "$what (AccessDenied)"
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
    record_ok "vault PUT own prefix (200)"
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
    record_ok "memory PUT own prefix (200)"
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

# ─── Step 11: Worker encrypt/decrypt roundtrip — credentials ───────────────
# Exercises the cred worker's AES-256-GCM envelope through the full HTTP
# path: cap-mint → /v1/cred/store (KEK-encrypt + S3 PUT) → cap-mint →
# /v1/cred/fetch (S3 GET + KEK-decrypt) → assert plaintext roundtrips.
# Skips cleanly when on-chain scope isn't set yet (stub-mode runs that
# never landed stage-1 step 13's setScopeWithWebauthn).
SMOKE_SERVICE="${SMOKE_TEST_SERVICE:-openrouter}"
SMOKE_PLAINTEXT="${SMOKE_TEST_SECRET:-stage3-roundtrip-secret-$(date +%s)}"

# Resolve the demo agent's actor_omni + device_key_hash. Prefer the
# agent file (created by stage-1 step 12) so the cap binds to a real
# agent device on chain.
AGENT_LABEL="${AGENTKEYS_AGENT_LABEL:-demo-agent}"
AGENT_FILE="$HOME/.agentkeys/agents/${AGENT_LABEL}.json"

mint_cap() {
  local op_url="$1"
  local body="$2"
  curl -sS -o /tmp/cap.$$.json -w '%{http_code}' \
    -X POST "$OIDC_ISSUER/v1/cap/$op_url" \
    -H "authorization: Bearer $(cat "$STATE_DIR/session.jwt")" \
    -H 'content-type: application/json' \
    -d "$body" 2>&1 || echo "000"
}

# MOCK_AGENT (CI path): provision a master-held DEV agent that MOCKS the sandbox
# actor so steps 11-12 can sign STS creds as the agent unattended (a real §10.2
# agent keeps its key in the sandbox). Idempotent — heima-agent-create +
# heima-scope-set both short-circuit when already on chain. Echoes the agent file
# path on stdout; all logs to stderr. Mirrors stage-1 step 12/13.
# Stage 3 uploads the in-sandbox agent-isolation test (harness/scripts/sandbox-
# agent-isolation.sh) so the operator can run the REAL §10.2 proof THERE — the
# master can't sign STS creds for a sandbox-held key, so the genuine agent test must
# run in the sandbox. Runs in phase 3 regardless of the mock/operator path below;
# skips quietly when no sandbox is reachable. One-time log via SANDBOX_TEST_UPLOADED.
SANDBOX_TEST_UPLOADED=0
upload_sandbox_isolation_test() {
  [ "$SANDBOX_TEST_UPLOADED" = 1 ] && return 0
  local sbx="${SANDBOX_URL:-http://localhost:8080}"
  local script="$REPO_ROOT/harness/scripts/sandbox-agent-isolation.sh"
  [ -f "$script" ] || return 0
  curl -fsS --max-time 8 "$sbx/healthz" >/dev/null 2>&1 || curl -fsS --max-time 8 "$sbx/v1/sandbox" >/dev/null 2>&1 || return 0
  if curl -sS --max-time 30 -X POST "$sbx/v1/file/upload" -F "file=@$script" -F "path=sandbox-agent-isolation.sh" >/dev/null 2>&1; then
    SANDBOX_TEST_UPLOADED=1
    info "uploaded sandbox-agent-isolation.sh → the sandbox ($sbx). REAL agent test (sandbox-held key) runs THERE: bash \$HOME/sandbox-agent-isolation.sh"
  fi
}

ensure_mock_agent() {
  local label="${AGENTKEYS_MOCK_AGENT_LABEL:-demo-agent-dev}"
  local rr profile_uc registry_addr scope_addr
  rr="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
  profile_uc=$(printf '%s' "${AGENTKEYS_CHAIN:-heima}" | tr 'a-z-' 'A-Z_')
  registry_addr=$(eval "echo \${SIDECAR_REGISTRY_ADDRESS_${profile_uc}:-}")
  scope_addr=$(eval "echo \${SCOPE_CONTRACT_ADDRESS_${profile_uc}:-}")
  [ -n "$registry_addr" ] && [ "$registry_addr" != 0x0 ] || { echo "ensure_mock_agent: no SidecarRegistry address in env" >&2; return 1; }
  bash "$rr/scripts/heima-agent-create.sh" --label "$label" --registry-address "$registry_addr" >&2 \
    || { echo "ensure_mock_agent: heima-agent-create.sh failed" >&2; return 1; }
  if [ -n "$scope_addr" ] && [ "$scope_addr" != 0x0 ]; then
    local args=(--agent "$label" --services "$SMOKE_SERVICE" --scope-address "$scope_addr")
    [ "${WEBAUTHN_MODE:-0}" = 1 ] && args+=(--webauthn)
    bash "$rr/scripts/heima-scope-set.sh" "${args[@]}" >&2 \
      || { echo "ensure_mock_agent: heima-scope-set.sh failed" >&2; return 1; }
  fi
  printf '%s\n' "$HOME/.agentkeys/agents/${label}.json"
}

cred_memory_roundtrip() {
  local kind="$1"            # cred | memory
  # Phase 3 stages the in-sandbox real-agent test ANYWAY (once, when a sandbox is up)
  # — independent of this run's agent custody — so the operator can run it there.
  upload_sandbox_isolation_test
  local cap_store_url cap_fetch_url worker_url store_route fetch_route
  if [ "$kind" = "cred" ]; then
    cap_store_url="cred-store"
    cap_fetch_url="cred-fetch"
    worker_url="$AGENTKEYS_WORKER_CRED_URL"
    store_route="/v1/cred/store"
    fetch_route="/v1/cred/fetch"
  else
    # Memory worker now has dedicated cap-mint endpoints that bind
    # data_class=Memory into the cap payload. Cred-* caps no longer
    # work here — cred worker rejects with cap_data_class_mismatch.
    cap_store_url="memory-put"
    cap_fetch_url="memory-get"
    worker_url="$AGENTKEYS_WORKER_MEMORY_URL"
    store_route="/v1/memory/put"
    fetch_route="/v1/memory/get"
  fi

  # The cap's actor_omni is the AGENT's (operator authorized agent for
  # this service). The worker writes to bots/<agent_omni>/<class>/...,
  # so the STS creds MUST be tagged with agent's actor_omni. Mint a
  # fresh STS session SIGNED BY THE AGENT (agent_private_key from the
  # agent file), not the operator. This is the architecturally correct
  # flow: each actor authenticates as itself.
  local agent_pk
  agent_pk=$(jq -r '.agent_private_key // empty' "$AGENT_FILE")
  if [ -z "$agent_pk" ] || [ "$agent_pk" = "null" ]; then
    # The configured agent is sandbox-paired (§10.2 — key never on the master).
    # (The in-sandbox real-agent test was already staged at the top of this function.)
    # TWO ways to satisfy steps 11-12 (per issue: operator-sandbox vs CI-mock):
    if [ "$MOCK_AGENT" = 1 ]; then
      # CI: provision a master-held DEV agent that mocks the sandbox actor here.
      info "agent '$AGENT_LABEL' is sandbox-paired (key_custody=$(jq -r '.key_custody // "?"' "$AGENT_FILE" 2>/dev/null)) — MOCK_AGENT: provisioning a master-held dev agent to mock it for steps 11-12"
      local mock_file
      mock_file=$(ensure_mock_agent) || { prereq_missing agent-file-invalid "mock-agent provision failed (heima-agent-create/scope-set)" || return 1; return 0; }
      AGENT_FILE="$mock_file"
      AGENT_LABEL=$(jq -r '.label // "demo-agent-dev"' "$AGENT_FILE" 2>/dev/null)
      agent_pk=$(jq -r '.agent_private_key // empty' "$AGENT_FILE")
      [ -n "$agent_pk" ] && [ "$agent_pk" != null ] || { prereq_missing agent-file-invalid "mock agent '$AGENT_LABEL' still has no master-held key (heima-agent-create ran in §10.2 mode?)" || return 1; return 0; }
      ok "mock agent ready ($AGENT_LABEL, master-held key) — steps 11-12 sign as this actor"
    else
      # OPERATOR: steps 11-12 are AGENT-side. The §10.2 agent's key lives in the
      # sandbox, so the master cannot sign STS creds for it — this is by design, NOT a
      # failure. DEFER to the sandbox: `phase1-wire-demo.sh --real` pairs the agent and
      # stage 3 uploads `sandbox-agent-isolation.sh`; run it THERE (see runbook On
      # Sandbox). The operator demo stays GREEN. (CI has no sandbox → it mocks instead,
      # via --mock-agent / --ci.)
      defer_to_sandbox "step $STEP_NUM ($kind worker, signed AS the agent): agent '$AGENT_LABEL' is §10.2-paired (key in the sandbox)"
      return 0
    fi
  fi
  local agent_addr
  agent_addr=$(jq -r '.agent_address // .wallet_address' "$AGENT_FILE")

  # Helper: SIWE-sign as the AGENT and mint STS creds for a given role.
  local agent_role_arn
  if [ "$kind" = "cred" ]; then agent_role_arn="$VAULT_ROLE_ARN"; else agent_role_arn="$MEMORY_ROLE_ARN"; fi

  info "minting agent-side STS for $kind role (SIWE as agent $agent_addr)"
  local sresp request_id siwe_msg sig vresp session_jwt
  sresp=$(curl -sSf -X POST "$OIDC_ISSUER/v1/auth/wallet/start" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg a "$agent_addr" --argjson c 1 '{address: $a, chain_id: $c}')") \
    || die "agent wallet/start failed"
  request_id=$(echo "$sresp" | jq -r .request_id)
  siwe_msg=$(echo "$sresp" | jq -r .siwe_message)
  sig=$(cast wallet sign --private-key "$agent_pk" "$siwe_msg")
  vresp=$(curl -sSf -X POST "$OIDC_ISSUER/v1/auth/wallet/verify" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg rid "$request_id" --arg sig "$sig" '{request_id: $rid, signature: $sig}')") \
    || die "agent wallet/verify failed"
  session_jwt=$(echo "$vresp" | jq -r '.session_jwt // .jwt // empty')
  [ -z "$session_jwt" ] && die "agent SIWE didn't return session JWT"

  local oidc_resp agent_oidc_jwt sts_resp
  oidc_resp=$(curl -sSf -X POST "$OIDC_ISSUER/v1/mint-oidc-jwt" \
    -H "authorization: Bearer $session_jwt") || die "agent mint-oidc-jwt failed"
  agent_oidc_jwt=$(echo "$oidc_resp" | jq -r .jwt)

  sts_resp=$(aws sts assume-role-with-web-identity \
    --region "$REGION" \
    --role-arn "$agent_role_arn" \
    --role-session-name "stage3-agent-${kind}-$(date +%s)" \
    --web-identity-token "$agent_oidc_jwt" \
    --duration-seconds 900 \
    --output json 2>&1) || die "agent AssumeRoleWithWebIdentity ($kind) failed: $sts_resp"
  local aki sak sst
  aki=$(echo "$sts_resp" | jq -r .Credentials.AccessKeyId)
  sak=$(echo "$sts_resp" | jq -r .Credentials.SecretAccessKey)
  sst=$(echo "$sts_resp" | jq -r .Credentials.SessionToken)
  local arn
  arn=$(echo "$sts_resp" | jq -r .AssumedRoleUser.Arn)
  ok "agent STS minted (AKI=${aki:0:10}…, AssumedArn=$arn)"

  # Resolve actor_omni + device_key_hash.
  local agent_actor agent_dkh
  if [ -f "$AGENT_FILE" ]; then
    agent_actor=$(jq -r .actor_omni "$AGENT_FILE")
    agent_dkh=$(jq -r '.device_key_hash // empty' "$AGENT_FILE")
  fi
  if [ -z "${agent_actor:-}" ] || [ "$agent_actor" = "null" ]; then
    prereq_missing agent-file-missing "no demo-agent file at $AGENT_FILE — run stage-1 step 12 first" || return 1
    return 0
  fi
  if [ -z "${agent_dkh:-}" ]; then
    # Derive from agent address.
    local agent_addr
    agent_addr=$(jq -r '.agent_address // .wallet_address // empty' "$AGENT_FILE")
    if [ -z "$agent_addr" ]; then
      prereq_missing agent-file-invalid "agent file missing agent_address" || return 1
      return 0
    fi
    agent_dkh=$(cast keccak "$(printf '%s' "$agent_addr" | tr '[:upper:]' '[:lower:]')")
  fi

  local cap_body
  cap_body=$(jq -n \
    --arg op "0x$OWN_ACTOR_OMNI" \
    --arg actor "$agent_actor" \
    --arg svc "$SMOKE_SERVICE" \
    --arg dkh "$agent_dkh" '{
      operator_omni: $op,
      actor_omni: $actor,
      service: $svc,
      device_key_hash: $dkh
    }')

  # Mint Store cap
  info "minting $cap_store_url cap"
  rc=$(mint_cap "$cap_store_url" "$cap_body")
  local body
  body=$(cat /tmp/cap.$$.json 2>/dev/null || true); rm -f /tmp/cap.$$.json
  if [ "$rc" != "200" ]; then
    if echo "$body" | grep -qiE "not.*scope|NotInScope|service_not_in_scope|service not in scope"; then
      prereq_missing scope-not-set "agent scope not set on chain — run \`bash harness/v2-stage1-demo.sh --webauthn\` (Touch ID at steps 11 + 13) first" || return 1
      return 0
    fi
    if echo "$body" | grep -qiE "RPC URL not set|AGENTKEYS_CHAIN_RPC_HTTP"; then
      prereq_missing broker-misconfig "broker missing AGENTKEYS_CHAIN_RPC_HTTP — redeploy broker host" || return 1
      return 0
    fi
    if echo "$body" | grep -qiE "SIDECAR_REGISTRY_ADDRESS_HEIMA|SCOPE_CONTRACT_ADDRESS_HEIMA|K3_EPOCH_COUNTER_ADDRESS_HEIMA.*unset"; then
      prereq_missing broker-misconfig "broker missing contract address env — redeploy broker host" || return 1
      return 0
    fi
    if echo "$body" | grep -qiE "DeviceRoleMissing|role_missing|cap_mint role"; then
      prereq_missing device-role-missing "device not granted ROLE_CAP_MINT on chain — operator must register-with-role first" || return 1
      return 0
    fi
    cat <<EOF >&2
    fail cap-mint returned HTTP $rc — body: $body
EOF
    return 1
  fi
  local store_cap
  store_cap="$body"
  ok "Store cap minted"

  # POST plaintext to worker (with agent-side STS creds in headers)
  local plaintext_b64
  plaintext_b64=$(printf '%s' "$SMOKE_PLAINTEXT" | base64 | tr -d '\n')
  local store_body
  store_body=$(jq -n --argjson cap "$store_cap" --arg pt "$plaintext_b64" \
                 '{cap: $cap, plaintext_b64: $pt}')
  info "POST ${worker_url}${store_route}  (with agent-side X-Aws-* headers)"
  rc=$(curl -sS -o /tmp/store.$$.json -w '%{http_code}' \
    -X POST "${worker_url}${store_route}" \
    -H 'content-type: application/json' \
    -H "x-aws-access-key-id: $aki" \
    -H "x-aws-secret-access-key: $sak" \
    -H "x-aws-session-token: $sst" \
    -d "$store_body" 2>&1 || echo "000")
  body=$(cat /tmp/store.$$.json 2>/dev/null || true); rm -f /tmp/store.$$.json
  if [ "$rc" != "200" ]; then
    die "${worker_url}${store_route} returned $rc — body: $body"
  fi
  local s3_key
  s3_key=$(echo "$body" | jq -r '.s3_key // empty')
  ok "encrypted + stored at s3://.../$s3_key (envelope $(echo "$body" | jq -r .envelope_size) bytes)"

  # Mint Fetch cap
  info "minting $cap_fetch_url cap"
  rc=$(mint_cap "$cap_fetch_url" "$cap_body")
  body=$(cat /tmp/cap.$$.json 2>/dev/null || true); rm -f /tmp/cap.$$.json
  [ "$rc" = "200" ] || die "fetch cap-mint returned HTTP $rc — body: $body"
  local fetch_cap; fetch_cap="$body"
  ok "Fetch cap minted"

  # GET plaintext back from worker (with the same agent-side STS creds)
  local fetch_body
  fetch_body=$(jq -n --argjson cap "$fetch_cap" '{cap: $cap}')
  info "POST ${worker_url}${fetch_route}  (with agent-side X-Aws-* headers)"
  rc=$(curl -sS -o /tmp/fetch.$$.json -w '%{http_code}' \
    -X POST "${worker_url}${fetch_route}" \
    -H 'content-type: application/json' \
    -H "x-aws-access-key-id: $aki" \
    -H "x-aws-secret-access-key: $sak" \
    -H "x-aws-session-token: $sst" \
    -d "$fetch_body" 2>&1 || echo "000")
  body=$(cat /tmp/fetch.$$.json 2>/dev/null || true); rm -f /tmp/fetch.$$.json
  if [ "$rc" != "200" ]; then
    die "${worker_url}${fetch_route} returned $rc — body: $body"
  fi
  local fetched_b64 fetched
  fetched_b64=$(echo "$body" | jq -r '.plaintext_b64 // empty')
  fetched=$(printf '%s' "$fetched_b64" | base64 -d 2>/dev/null || echo "")
  if [ "$fetched" = "$SMOKE_PLAINTEXT" ]; then
    ok "$kind ROUNDTRIP: '$SMOKE_PLAINTEXT' encrypted → S3 → decrypted ✓ byte-for-byte match"
    record_ok "$kind worker encrypt/decrypt byte-for-byte roundtrip"
  else
    die "$kind roundtrip FAILED: expected '$SMOKE_PLAINTEXT', got '$fetched'"
  fi
}

if should_run_step 11; then
  step "Cred worker encrypt/decrypt roundtrip (cap-mint → /v1/cred/store → /v1/cred/fetch)"
  : "${AGENTKEYS_WORKER_CRED_URL:?AGENTKEYS_WORKER_CRED_URL unset}"
  cred_memory_roundtrip cred
fi

# ─── Step 12: Worker encrypt/decrypt roundtrip — memory ────────────────────
if should_run_step 12; then
  step "Memory worker encrypt/decrypt roundtrip (cap-mint → /v1/memory/put → /v1/memory/get)"
  : "${AGENTKEYS_WORKER_MEMORY_URL:?AGENTKEYS_WORKER_MEMORY_URL unset}"
  cred_memory_roundtrip memory
fi

# ─── Step 13: NEGATIVE — broker rejects cross-actor cap-mint ───────────────
# The CRITICAL upstream isolation gate. Actor A's session JWT MUST NOT be
# usable to mint a cap-token for actor B's data. Broker enforces this in
# handlers/cap.rs:
#
#   let session_omni = claims.agentkeys.omni_account
#   if session_omni != req.operator_omni { return OperatorMismatch }
#   if device.operator_omni != session_omni { return DeviceBindingMismatch }
#   if device.actor_omni != req.actor_omni { return DeviceBindingMismatch }
#
# If this check ever silently passes, every cred + memory blob in S3 is
# compromised — A can mint B's cap, hand it to the worker, worker writes
# under B's prefix. This step proves the broker rejects.
if should_run_step 13; then
  step "NEGATIVE: broker rejects cap-mint where session_omni != operator_omni"
  [ -f "$STATE_DIR/session.jwt" ] || die "no session.jwt — re-run step 1"
  # Fabricate a request claiming operator_omni = WRONG actor (anything not
  # our session's omni). Service + device_key_hash don't matter — the
  # session_omni vs req.operator_omni check fires first.
  evil_body=$(jq -n \
    --arg wrong_op "0x$WRONG_ACTOR_OMNI" \
    --arg wrong_actor "0x$WRONG_ACTOR_OMNI" \
    --arg svc "openrouter" \
    --arg dkh "0x0000000000000000000000000000000000000000000000000000000000000001" \
    '{operator_omni: $wrong_op, actor_omni: $wrong_actor, service: $svc, device_key_hash: $dkh}')
  rc=$(curl -sS -o /tmp/evil.$$.json -w '%{http_code}' \
    -X POST "$OIDC_ISSUER/v1/cap/cred-store" \
    -H "authorization: Bearer $(cat "$STATE_DIR/session.jwt")" \
    -H 'content-type: application/json' \
    -d "$evil_body" 2>&1 || echo "000")
  body=$(cat /tmp/evil.$$.json 2>/dev/null || true); rm -f /tmp/evil.$$.json
  if [ "$rc" = "200" ]; then
    cat <<EOF >&2
    fail broker accepted cross-actor cap-mint with HTTP 200 — body: $body
    fail CRITICAL ISOLATION REGRESSION: actor A's session JWT can mint a cap
         claiming operator_omni = B. Every cred+memory blob in S3 is compromised.
EOF
    die "broker isolation gate FAILED"
  fi
  # Codex review fix (medium): require the canonical OperatorMismatch
  # error — any other rejection (502 broker-stale, 404 wrong route, 401
  # unauthenticated, generic 403) is NOT proof that the session-omni
  # gate fired. Only the canonical error proves the upstream isolation
  # boundary worked.
  case "$rc" in
    400|401|403)
      if echo "$body" | grep -qiE "OperatorMismatch|operator.*mismatch|session.*operator"; then
        ok "broker correctly returned HTTP $rc with OperatorMismatch — session JWT cannot mint caps for other actors"
        record_ok "broker rejected cross-actor cap-mint with OperatorMismatch ($rc)"
      else
        die "broker returned HTTP $rc but error text is NOT canonical OperatorMismatch (body: $body) — cannot confirm session-omni gate fired"
      fi
      ;;
    502)
      if echo "$body" | grep -qiE "AGENTKEYS_CHAIN_RPC_HTTP|RPC URL|SIDECAR_REGISTRY|SCOPE_CONTRACT"; then
        die "broker config missing (502): $body — cannot prove the OperatorMismatch gate fires. Redeploy broker via setup-broker-host.sh and re-run."
      fi
      die "broker returned 502 — body: $body. Negative test cannot pass on an unrelated failure."
      ;;
    *)
      die "broker returned unexpected HTTP $rc — body: $body. Expected 400/401/403 with OperatorMismatch."
      ;;
  esac
fi

# Helper: assert a worker REJECTS a cap with cap_data_class_mismatch.
# This is the cap-token-explicit isolation gate — symmetric to the
# AWS IAM cross-bucket gate in step 10, but at the broker-signed
# capability layer.
#
# Codex round-4 fix (high): MUST include valid X-Aws-* headers for the
# TARGET worker. With AGENTKEYS_WORKER_REQUIRE_STS=1 (the production
# deployment setting), the OptionalStsCreds axum extractor runs BEFORE
# the handler body and rejects header-less requests with HTTP 401 —
# `verify_cap` never gets to call `check_data_class`. So the negative
# test could pass against the current dev broker (non-strict workers)
# while silently failing to exercise the data-class guard under prod.
# Sending valid STS creds makes the extractor pass; verify_cap then
# runs check_data_class and rejects with cap_data_class_mismatch.
post_cross_class() {
  local cap_blob="$1" worker_route="$2" out_file="$3"
  local aki="$4" sak="$5" sst="$6"
  local plaintext_b64
  plaintext_b64=$(printf 'cross-class probe' | base64 | tr -d '\n')
  local body
  body=$(jq -n --argjson cap "$cap_blob" --arg pt "$plaintext_b64" \
            '{cap: $cap, plaintext_b64: $pt}')
  rc=$(curl -sS -o "$out_file" -w '%{http_code}' \
    -X POST "$worker_route" \
    -H 'content-type: application/json' \
    -H "x-aws-access-key-id: $aki" \
    -H "x-aws-secret-access-key: $sak" \
    -H "x-aws-session-token: $sst" \
    -d "$body" 2>&1 || echo "000")
  echo "$rc"
}

# Helper: mint agent-side STS for a given role (codex round-4). Reused
# by both cred_memory_roundtrip and cross_class_rejection so the cross-
# class test exercises the worker with valid extractor-passing creds.
# Prints "AKI;SAK;SST" on stdout (semicolons because these tokens don't
# contain that char).
mint_agent_sts_for_role() {
  local role_arn="$1" label="$2"
  local agent_pk agent_addr
  agent_pk=$(jq -r '.agent_private_key // empty' "$AGENT_FILE")
  agent_addr=$(jq -r '.agent_address // .wallet_address' "$AGENT_FILE")
  [ -z "$agent_pk" ] || [ "$agent_pk" = "null" ] && return 1
  local sresp request_id siwe_msg sig vresp session_jwt
  sresp=$(curl -sSf -X POST "$OIDC_ISSUER/v1/auth/wallet/start" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg a "$agent_addr" --argjson c 1 '{address: $a, chain_id: $c}')") \
    || return 2
  request_id=$(echo "$sresp" | jq -r .request_id)
  siwe_msg=$(echo "$sresp" | jq -r .siwe_message)
  sig=$(cast wallet sign --private-key "$agent_pk" "$siwe_msg")
  vresp=$(curl -sSf -X POST "$OIDC_ISSUER/v1/auth/wallet/verify" \
    -H 'content-type: application/json' \
    -d "$(jq -n --arg rid "$request_id" --arg sig "$sig" '{request_id: $rid, signature: $sig}')") \
    || return 3
  session_jwt=$(echo "$vresp" | jq -r '.session_jwt // .jwt // empty')
  [ -z "$session_jwt" ] && return 4
  local oidc_resp agent_oidc_jwt sts_resp
  oidc_resp=$(curl -sSf -X POST "$OIDC_ISSUER/v1/mint-oidc-jwt" \
    -H "authorization: Bearer $session_jwt") || return 5
  agent_oidc_jwt=$(echo "$oidc_resp" | jq -r .jwt)
  sts_resp=$(aws sts assume-role-with-web-identity \
    --region "$REGION" \
    --role-arn "$role_arn" \
    --role-session-name "stage3-cross-${label}-$(date +%s)" \
    --web-identity-token "$agent_oidc_jwt" \
    --duration-seconds 900 \
    --output json 2>&1) || return 6
  local aki sak sst
  aki=$(echo "$sts_resp" | jq -r .Credentials.AccessKeyId)
  sak=$(echo "$sts_resp" | jq -r .Credentials.SecretAccessKey)
  sst=$(echo "$sts_resp" | jq -r .Credentials.SessionToken)
  printf '%s;%s;%s' "$aki" "$sak" "$sst"
}

# Helper: NEGATIVE cross-data-class rejection test.
# Args: $1 = cap_mint endpoint slug (cred-store | memory-put)
#       $2 = worker URL to POST against (e.g. $AGENTKEYS_WORKER_MEMORY_URL/v1/memory/put)
#       $3 = label for the worker being defended (memory | cred)
#       $4 = label for the cap class being submitted (cred | memory)
#       $5 = artifact file basename for diagnostics
#
# Codex round-3 fix (high): all skip paths route through prereq_missing
# so strict mode fails-hard and STEP_OUTCOMES tracks every actual or
# skipped negative test. Prior code called bare `skip` here, letting
# the summary report DEMO COMPLETE while the cross-class assertion
# silently never ran.
cross_class_rejection() {
  local cap_url="$1" worker_full_url="$2" worker_label="$3" cap_label="$4" art="$5"
  if [ ! -f "$AGENT_FILE" ]; then
    prereq_missing agent-file-missing "no demo-agent file — run stage-1 step 12 first" || return 1
    return 0
  fi
  # Steps 14-15 prove the cross-class denial by acting AS the agent (mint_agent_sts_for_role
  # below signs the SIWE). On the OPERATOR a §10.2 agent's key is in the sandbox → the master
  # can't sign → DEFER (not fail; the sandbox harness covers it). CI mocks (the mock agent,
  # provisioned at step 11, has a master-held key, so this gate doesn't fire there).
  local _apk; _apk=$(jq -r '.agent_private_key // empty' "$AGENT_FILE")
  if { [ -z "$_apk" ] || [ "$_apk" = "null" ]; } && [ "$MOCK_AGENT" != 1 ]; then
    defer_to_sandbox "step $STEP_NUM (cross-class $art rejection, signed AS the agent): agent '$AGENT_LABEL' is §10.2-paired (key in the sandbox)"
    return 0
  fi
  local a_actor a_dkh cap_body
  a_actor=$(jq -r .actor_omni "$AGENT_FILE")
  a_dkh=$(jq -r '.device_key_hash // empty' "$AGENT_FILE")
  [ -z "$a_dkh" ] && a_dkh=$(cast keccak "$(jq -r '.agent_address // .wallet_address' "$AGENT_FILE" | tr '[:upper:]' '[:lower:]')")
  cap_body=$(jq -n --arg op "0x$OWN_ACTOR_OMNI" --arg actor "$a_actor" \
                     --arg svc "$SMOKE_SERVICE" --arg dkh "$a_dkh" \
     '{operator_omni:$op, actor_omni:$actor, service:$svc, device_key_hash:$dkh}')
  local rc body
  rc=$(mint_cap "$cap_url" "$cap_body")
  if [ "$rc" != "200" ]; then
    body=$(cat /tmp/cap.$$.json 2>/dev/null || true); rm -f /tmp/cap.$$.json
    if echo "$body" | grep -qiE "not.*scope|NotInScope|service_not_in_scope"; then
      prereq_missing scope-not-set "agent scope not set on chain — stage-1 step 13 setScopeWithWebauthn required" || return 1
      return 0
    fi
    if echo "$body" | grep -qiE "RPC URL not set|AGENTKEYS_CHAIN_RPC_HTTP"; then
      prereq_missing broker-misconfig "broker missing AGENTKEYS_CHAIN_RPC_HTTP — redeploy broker host" || return 1
      return 0
    fi
    if echo "$body" | grep -qiE "SIDECAR_REGISTRY_ADDRESS_HEIMA|SCOPE_CONTRACT_ADDRESS_HEIMA|K3_EPOCH_COUNTER_ADDRESS_HEIMA.*unset"; then
      prereq_missing broker-misconfig "broker missing contract address env — redeploy broker host" || return 1
      return 0
    fi
    if echo "$body" | grep -qiE "DeviceRoleMissing|role_missing|cap_mint role"; then
      prereq_missing device-role-missing "device not granted ROLE_CAP_MINT on chain" || return 1
      return 0
    fi
    die "$cap_url cap-mint returned HTTP $rc — body: $body"
  fi
  local the_cap art_path
  the_cap=$(cat /tmp/cap.$$.json); rm -f /tmp/cap.$$.json
  art_path="$STATE_DIR/cross.${art}.json"

  # Mint agent-side STS creds for the TARGET worker's role. Needed so
  # the worker's OptionalStsCreds extractor passes under
  # AGENTKEYS_WORKER_REQUIRE_STS=1 (production setting) — the
  # data-class guard runs AFTER the extractor, so missing headers
  # would short-circuit before verify_cap and the negative test would
  # silently not prove the guard fired (codex round-4 finding).
  local target_role
  if [ "$worker_label" = "memory" ]; then target_role="$MEMORY_ROLE_ARN"; else target_role="$VAULT_ROLE_ARN"; fi
  local sts_blob aki sak sst
  if ! sts_blob=$(mint_agent_sts_for_role "$target_role" "cross-$art"); then
    prereq_missing agent-sts-mint-failed "agent STS mint failed for $worker_label target — auth chain broken (broker?  agent file?)" || return 1
    return 0
  fi
  aki="${sts_blob%%;*}"; rest="${sts_blob#*;}"; sak="${rest%%;*}"; sst="${rest#*;}"

  rc=$(post_cross_class "$the_cap" "$worker_full_url" "$art_path" "$aki" "$sak" "$sst")
  body=$(cat "$art_path" 2>/dev/null || true)
  if [ "$rc" = "200" ]; then
    cat "$art_path" >&2
    die "CRITICAL: $worker_label worker accepted a $cap_label-class cap — data-class isolation broken!"
  fi
  case "$rc" in
    400|401|403)
      if echo "$body" | grep -qiE "cap_data_class_mismatch|data_class.*mismatch|DataClassMismatch"; then
        ok "$worker_label worker correctly rejected $cap_label-class cap with cap_data_class_mismatch ($rc)"
        record_ok "$worker_label worker rejected $cap_label-class cap ($rc cap_data_class_mismatch)"
        return 0
      fi
      die "$worker_label worker rejected with HTTP $rc but error is NOT canonical cap_data_class_mismatch (body: $body) — cannot confirm the data-class isolation gate fired"
      ;;
    *)
      die "$worker_label worker returned unexpected HTTP $rc (expected 400/401/403 with cap_data_class_mismatch) — body: $body"
      ;;
  esac
}

# ─── Step 14: NEGATIVE — cred-class cap submitted to memory worker ─────────
# Mint a credentials cap (data_class=Credentials), POST to /v1/memory/put.
# The memory worker MUST reject with HTTP 403 cap_data_class_mismatch.
if should_run_step 14; then
  step "NEGATIVE: cred-class cap → memory worker rejects (cap_data_class_mismatch)"
  cross_class_rejection cred-store "${AGENTKEYS_WORKER_MEMORY_URL}/v1/memory/put" memory cred cred-to-mem
fi

# ─── Step 15: NEGATIVE — memory-class cap submitted to cred worker ─────────
# Symmetric to step 14. Mint a memory cap, POST to /v1/cred/store.
# The cred worker MUST reject with HTTP 403 cap_data_class_mismatch.
if should_run_step 15; then
  step "NEGATIVE: memory-class cap → cred worker rejects (cap_data_class_mismatch)"
  cross_class_rejection memory-put "${AGENTKEYS_WORKER_CRED_URL}/v1/cred/store" cred memory mem-to-cred
fi

# ─── Step 16: POSITIVE — master-self cap mints with NO scope grant ─────────
# Issue #196 + #195. The master accessing its OWN data (operator == actor ==
# O_master) must mint a cap WITHOUT any on-chain scope grant: cap.rs skips the
# isServiceInScope check when operator == actor (#195), and #196 guarantees the
# master device is registered on chain with CAP_MINT. This is the POSITIVE
# counterpart to step 13's cross-actor negative — together they prove the skip
# is scoped to master-self only.
#
# In the harness the session wallet IS the deployer, so OWN_ACTOR_OMNI is the
# omni the first-master device was registered under. The master is registered by
# register_first_master() in stage 1 (step 10) / stage 2 — the #164
# passkey-account ERC-4337 path (EOA fallback), BOTH of which register
# device_key_hash = keccak(operator_omni). So this cap-mint sends
# keccak(0x$OWN_ACTOR_OMNI). No setScope ceremony is run before this.
if should_run_step 16; then
  step "POSITIVE: master-self cap mints with NO scope grant (operator==actor — #195 skip + #196/#164 device)"
  [ -f "$STATE_DIR/session.jwt" ] || die "no session.jwt — re-run step 1"
  MASTER_SELF_SERVICE="${MASTER_SELF_SERVICE:-memory:stage3self}"
  # The operator's ACTIVE master device — #164 keccak(operator_omni) or the legacy
  # EOA keccak(deployer_addr), whichever is on chain (the deployer may be
  # bootstrapped via either path). Falls back to keccak(omni) → the
  # not-registered branch below then guides the operator.
  master_dkh="$(resolve_active_master_dkh "$OWN_ACTOR_OMNI" "$WALLET_LC" 2>/dev/null || cast keccak "0x$OWN_ACTOR_OMNI")"
  self_body=$(jq -n --arg op "0x$OWN_ACTOR_OMNI" --arg actor "0x$OWN_ACTOR_OMNI" \
                     --arg svc "$MASTER_SELF_SERVICE" --arg dkh "$master_dkh" \
     '{operator_omni:$op, actor_omni:$actor, service:$svc, device_key_hash:$dkh}')
  rc=$(mint_cap memory-put "$self_body")
  body=$(cat /tmp/cap.$$.json 2>/dev/null || true); rm -f /tmp/cap.$$.json
  if [ "$rc" = "200" ]; then
    ok "master-self memory cap minted with NO scope grant (operator==actor) — #195 skip + #196 registered device both proven"
    record_ok "master-self cap mints with no scope grant ($MASTER_SELF_SERVICE, device $master_dkh)"
  elif echo "$body" | grep -qiE "not.*scope|NotInScope|service_not_in_scope"; then
    die "master-self cap returned ServiceNotInScope — operator==actor must skip the scope check (#195). The repo + origin/main HAVE the skip (crates/agentkeys-broker-server/src/handlers/cap.rs '#195'), so this is a STALE DEPLOYED broker (deployed before #195 landed) — NOT a harness step you missed. FIX (operational): the broker builds+restarts LOCALLY, so SSH into the host FIRST (ssh-agentkeys, or 'bash scripts/ssh-broker.sh prod'), then ON THE HOST run: sudo bash scripts/setup-broker-host.sh --ref main. Resume here after: bash harness/v2-demo.sh --from 3. body: $body"
  elif echo "$body" | grep -qiE "DeviceNotActive|device.*not.*active|DeviceBindingMismatch|binding.*mismatch|DeviceRoleMissing|role_missing|cap_mint role"; then
    prereq_missing master-not-registered "master device $master_dkh not registered with CAP_MINT under 0x$OWN_ACTOR_OMNI (HTTP $rc) — run stage 1 step 10 / stage 2 (register_first_master), or directly: bash harness/scripts/erc4337-register-master.sh --operator-omni 0x$OWN_ACTOR_OMNI. body: $body" || true
  elif echo "$body" | grep -qiE "RPC URL not set|AGENTKEYS_CHAIN_RPC_HTTP|SIDECAR_REGISTRY_ADDRESS_HEIMA|SCOPE_CONTRACT_ADDRESS_HEIMA"; then
    prereq_missing broker-misconfig "broker missing chain config (HTTP $rc) — redeploy broker host. body: $body" || true
  else
    die "master-self cap-mint returned HTTP $rc — body: $body"
  fi
fi

# ─── Step 17: NEGATIVE — cross-actor cap still returns ServiceNotInScope ────
# Issue #196 + #195. The mirror of step 16: when operator != actor, the scope
# check is NOT skipped. A cap for the agent actor against a service the agent
# was NOT granted MUST be rejected with ServiceNotInScope — proving #195's skip
# did not accidentally open the gate for cross-actor caps. Uses the demo agent
# (operator == OWN, actor == agent_omni, a registered device) + a deliberately
# un-granted service so the device-binding check passes and the SCOPE gate is
# the one that fires.
if should_run_step 17; then
  step "NEGATIVE: cross-actor cap (operator!=actor) still returns ServiceNotInScope"
  [ -f "$STATE_DIR/session.jwt" ] || die "no session.jwt — re-run step 1"
  if [ ! -f "$AGENT_FILE" ]; then
    prereq_missing agent-file-missing "no demo-agent file at $AGENT_FILE — run stage-1 step 12 first (cross-actor scope test needs a registered agent device)" || true
  else
    a_actor=$(jq -r .actor_omni "$AGENT_FILE")
    a_dkh=$(jq -r '.device_key_hash // empty' "$AGENT_FILE")
    [ -z "$a_dkh" ] && a_dkh=$(cast keccak "$(jq -r '.agent_address // .wallet_address' "$AGENT_FILE" | tr '[:upper:]' '[:lower:]')")
    UNSCOPED_SERVICE="memory:__ak196_unscoped__"
    xa_body=$(jq -n --arg op "0x$OWN_ACTOR_OMNI" --arg actor "$a_actor" \
                     --arg svc "$UNSCOPED_SERVICE" --arg dkh "$a_dkh" \
       '{operator_omni:$op, actor_omni:$actor, service:$svc, device_key_hash:$dkh}')
    rc=$(mint_cap memory-put "$xa_body")
    body=$(cat /tmp/cap.$$.json 2>/dev/null || true); rm -f /tmp/cap.$$.json
    if [ "$rc" = "200" ]; then
      die "REGRESSION (#195): cross-actor cap (operator 0x$OWN_ACTOR_OMNI != actor $a_actor) for an UN-granted service was accepted — the scope-skip leaked to cross-actor caps. body: $body"
    elif echo "$body" | grep -qiE "not.*scope|NotInScope|service_not_in_scope"; then
      ok "cross-actor cap correctly returned ServiceNotInScope — #195 skip is scoped to master-self only"
      record_ok "cross-actor cap rejected with ServiceNotInScope ($rc)"
    elif echo "$body" | grep -qiE "DeviceNotActive|device.*not.*active|DeviceBindingMismatch|binding.*mismatch|DeviceRoleMissing|role_missing"; then
      prereq_missing agent-not-registered "agent device not registered under 0x$OWN_ACTOR_OMNI (HTTP $rc) — device-binding fired before the scope gate; run stage-1 step 12. body: $body" || true
    elif echo "$body" | grep -qiE "RPC URL not set|AGENTKEYS_CHAIN_RPC_HTTP|SIDECAR_REGISTRY_ADDRESS_HEIMA|SCOPE_CONTRACT_ADDRESS_HEIMA"; then
      prereq_missing broker-misconfig "broker missing chain config (HTTP $rc) — redeploy broker host. body: $body" || true
    else
      die "cross-actor cap-mint returned unexpected HTTP $rc — body: $body"
    fi
  fi
fi

# ─── Step 18: POSITIVE — granted agent (operator!=actor) mints a cap for the GRANTED service ───
# Completes the scope-semantics triad with step 16 (master-self SKIP) and step 17
# (cross-actor un-granted DENIED): here the master GRANTED the agent scope for
# $SMOKE_SERVICE in stage-1 step 13, so the agent (actor != operator) must now mint a
# memory cap for that service → 200, proving isServiceInScope(O_master, agent, service)
# is honoured (delegation works). Stands ALONE (no STS/worker roundtrip): the cap-mint
# is operator-authenticated (mint_cap sends session.jwt), so it needs NO agent key —
# only the agent's on-chain device + the grant.
if should_run_step 18; then
  step "POSITIVE: granted agent (operator!=actor) mints memory cap for the GRANTED service → 200"
  [ -f "$STATE_DIR/session.jwt" ] || die "no session.jwt — re-run step 1"
  # CI mocks the §10.2 agent with a master-held, scope-granted dev agent; the operator's
  # real agent carries its device + grant on chain (stage-1 / sandbox pairing).
  pg_file="$AGENT_FILE"
  if [ "$MOCK_AGENT" = 1 ]; then
    pg_file=$(ensure_mock_agent) || { prereq_missing agent-file-invalid "mock-agent provision failed (heima-agent-create/scope-set)" || true; pg_file=""; }
  fi
  if [ -z "$pg_file" ] || [ ! -f "$pg_file" ]; then
    prereq_missing agent-file-missing "no granted-agent file ($AGENT_FILE) — run stage-1 step 12/13 (create agent + setScope) first" || true
  else
    pg_actor=$(jq -r '.actor_omni // empty' "$pg_file")
    pg_dkh=$(jq -r '.device_key_hash // empty' "$pg_file")
    [ -z "$pg_dkh" ] && pg_dkh=$(cast keccak "$(jq -r '.agent_address // .wallet_address' "$pg_file" | tr '[:upper:]' '[:lower:]')")
    pg_actor_lc=$(printf '%s' "${pg_actor#0x}" | tr '[:upper:]' '[:lower:]')
    own_lc=$(printf '%s' "${OWN_ACTOR_OMNI#0x}" | tr '[:upper:]' '[:lower:]')
    if [ -z "$pg_actor" ]; then
      prereq_missing agent-file-invalid "granted-agent file missing actor_omni ($pg_file)" || true
    elif [ "$pg_actor_lc" = "$own_lc" ]; then
      prereq_missing agent-is-operator "configured agent actor == operator omni — this positive test needs a DISTINCT agent (operator!=actor)" || true
    else
      pg_body=$(jq -n --arg op "0x$OWN_ACTOR_OMNI" --arg actor "$pg_actor" \
                       --arg svc "$SMOKE_SERVICE" --arg dkh "$pg_dkh" \
         '{operator_omni:$op, actor_omni:$actor, service:$svc, device_key_hash:$dkh}')
      rc=$(mint_cap memory-put "$pg_body")
      body=$(cat /tmp/cap.$$.json 2>/dev/null || true); rm -f /tmp/cap.$$.json
      if [ "$rc" = "200" ]; then
        ok "granted agent (actor $pg_actor != operator 0x$OWN_ACTOR_OMNI) minted a memory cap for delegated service '$SMOKE_SERVICE' — isServiceInScope honoured"
        record_ok "granted-agent positive: memory cap minted for delegated service '$SMOKE_SERVICE' (operator!=actor, HTTP 200)"
      elif echo "$body" | grep -qiE "not.*scope|NotInScope|service_not_in_scope"; then
        prereq_missing scope-not-set "agent scope for '$SMOKE_SERVICE' not granted on chain — run \`bash harness/v2-stage1-demo.sh --webauthn\` (step 13 setScope) first. body: $body" || true
      elif echo "$body" | grep -qiE "DeviceNotActive|device.*not.*active|DeviceBindingMismatch|binding.*mismatch|DeviceRoleMissing|role_missing"; then
        if [ "$MOCK_AGENT" = 1 ]; then
          prereq_missing agent-not-registered "mock agent device not registered with CAP_MINT (HTTP $rc) — heima-agent-create. body: $body" || true
        else
          defer_to_sandbox "step $STEP_NUM (granted-agent positive cap-mint): agent '$pg_actor' device is §10.2-paired in the sandbox (not on chain until pairing)"
        fi
      elif echo "$body" | grep -qiE "RPC URL not set|AGENTKEYS_CHAIN_RPC_HTTP|SIDECAR_REGISTRY_ADDRESS_HEIMA|SCOPE_CONTRACT_ADDRESS_HEIMA"; then
        prereq_missing broker-misconfig "broker missing chain config (HTTP $rc) — redeploy broker host. body: $body" || true
      else
        die "granted-agent positive cap-mint returned unexpected HTTP $rc — body: $body"
      fi
    fi
  fi
fi

# ─── Config data class (#201) — master-only taxonomy isolation ─────────────
# The Config data class (policy / memory-types taxonomy, #178 §7) is MASTER-ONLY
# (operator == actor == O_master). Unlike the agent-side cred/memory cross-class
# tests (steps 14-15, which defer to the sandbox), these run on the OPERATOR —
# the master signs for itself, no §10.2 agent key needed. They prove, for the
# new config worker + DataClass::Config, the four-layer + cap-layer isolation:
#   • layer 3+4 (step 19): the master's own config prefix is writable; config
#     creds are rejected at the memory + vault buckets, and memory creds are
#     rejected at the config bucket (per-data-class bucket separation).
#   • cap data-class-mismatch (steps 20-21): a config cap is rejected by the
#     memory + cred workers, and a memory/cred cap is rejected by the config
#     worker — symmetric with steps 14-15 but at the master-self cap-authz layer.
# All gracefully prereq_missing (never silently pass) until the operator has run
# provision-config-{bucket,role}.sh + apply-config-bucket-policy.sh on AWS AND
# redeployed the broker host (config worker + #200 Phase-0 cap routes).

# Tolerant master STS minter (no die) — the config role may not be provisioned
# until the operator runs provision-config-role.sh. Writes creds to
# $STATE_DIR/{aki,sak,sst}.$label; returns 1 on any failure.
mint_sts_for_role_tol() {
  local role_arn="$1" label="$2"
  [ -f "$STATE_DIR/oidc.jwt" ] || return 1
  local resp aki
  resp=$(aws sts assume-role-with-web-identity \
    --region "$REGION" --role-arn "$role_arn" \
    --role-session-name "stage3-${label}-$(date +%s)" \
    --web-identity-token "$(cat "$STATE_DIR/oidc.jwt")" \
    --duration-seconds 900 --output json 2>&1) \
    || { printf '%s\n' "$resp" >"$STATE_DIR/sts.$label.err"; return 1; }
  aki=$(echo "$resp" | jq -r '.Credentials.AccessKeyId // empty')
  [ -z "$aki" ] && return 1
  echo -n "$aki" > "$STATE_DIR/aki.$label"
  echo -n "$(echo "$resp" | jq -r '.Credentials.SecretAccessKey')" > "$STATE_DIR/sak.$label"
  echo -n "$(echo "$resp" | jq -r '.Credentials.SessionToken')" > "$STATE_DIR/sst.$label"
  return 0
}

# role ARN for a worker class — the cross-class STS that passes the
# OptionalStsCreds extractor BEFORE the data-class guard runs (the guard runs
# after the extractor, so valid target-role creds are required to exercise it).
worker_role_arn() {
  case "$1" in
    memory) echo "$MEMORY_ROLE_ARN" ;;
    cred)   echo "$VAULT_ROLE_ARN" ;;
    config) echo "$CONFIG_ROLE_ARN" ;;
  esac
}

# Master-self cross-data-class rejection. Mints a $cap_label-class cap as
# master-self (operator==actor==O_master), POSTs it to $worker_label's worker
# with that worker's role STS, asserts cap_data_class_mismatch. Args:
#   $1 cap_url (config-store|memory-put|cred-store)  $2 cap service string
#   $3 worker full URL   $4 worker_label   $5 cap_label   $6 artifact basename
master_cross_class_rejection() {
  local cap_url="$1" cap_svc="$2" worker_full_url="$3" worker_label="$4" cap_label="$5" art="$6"
  [ -f "$STATE_DIR/session.jwt" ] || { prereq_missing no-session "no session.jwt — re-run step 1" || return 1; return 0; }
  local master_dkh self_body rc capjson
  master_dkh="$(resolve_active_master_dkh "$OWN_ACTOR_OMNI" "$WALLET_LC" 2>/dev/null || cast keccak "0x$OWN_ACTOR_OMNI")"
  self_body=$(jq -n --arg op "0x$OWN_ACTOR_OMNI" --arg actor "0x$OWN_ACTOR_OMNI" \
                    --arg svc "$cap_svc" --arg dkh "$master_dkh" \
     '{operator_omni:$op, actor_omni:$actor, service:$svc, device_key_hash:$dkh}')
  rc=$(mint_cap "$cap_url" "$self_body")
  capjson=$(cat /tmp/cap.$$.json 2>/dev/null || true); rm -f /tmp/cap.$$.json
  if [ "$rc" != "200" ]; then
    if echo "$capjson" | grep -qiE "no route|Cannot POST|not found|404"; then
      prereq_missing broker-no-config-route "broker has no /v1/cap/$cap_url route — redeploy broker host (origin/main has the #200 Phase-0 config routes). body: $capjson" || return 1
      return 0
    fi
    if echo "$capjson" | grep -qiE "RPC URL not set|AGENTKEYS_CHAIN_RPC_HTTP|SIDECAR_REGISTRY_ADDRESS_HEIMA|SCOPE_CONTRACT_ADDRESS_HEIMA"; then
      prereq_missing broker-misconfig "broker missing chain config (HTTP $rc) — redeploy broker host. body: $capjson" || return 1
      return 0
    fi
    if echo "$capjson" | grep -qiE "DeviceNotActive|DeviceBindingMismatch|DeviceRoleMissing|role_missing"; then
      prereq_missing master-not-registered "master device $master_dkh not registered with CAP_MINT (HTTP $rc) — run register_first_master. body: $capjson" || return 1
      return 0
    fi
    die "$cap_url master-self cap-mint returned HTTP $rc — body: $capjson"
  fi
  # Mint STS for the TARGET worker's role so the OptionalStsCreds extractor
  # passes (REQUIRE_STS) and check_data_class is the gate that fires.
  local role sts_label aki sak sst art_path body
  role="$(worker_role_arn "$worker_label")"; sts_label="xclass-$worker_label"
  if ! mint_sts_for_role_tol "$role" "$sts_label"; then
    prereq_missing "${worker_label}-role-missing" "could not mint STS for the $worker_label role ($role) — run provision-${worker_label}-role.sh / provision-config-role.sh first. The data-class guard runs AFTER the STS extractor, so valid creds are required to exercise it." || return 1
    return 0
  fi
  aki=$(cat "$STATE_DIR/aki.$sts_label"); sak=$(cat "$STATE_DIR/sak.$sts_label"); sst=$(cat "$STATE_DIR/sst.$sts_label")
  art_path="$STATE_DIR/cross.${art}.json"
  rc=$(post_cross_class "$capjson" "$worker_full_url" "$art_path" "$aki" "$sak" "$sst")
  body=$(cat "$art_path" 2>/dev/null || true)
  if [ "$rc" = "200" ]; then
    cat "$art_path" >&2
    die "CRITICAL: $worker_label worker accepted a $cap_label-class cap — data-class isolation broken!"
  fi
  case "$rc" in
    000|502|503|504)
      prereq_missing "${worker_label}-worker-unreachable" "$worker_label worker unreachable at $worker_full_url (HTTP $rc) — deploy it via setup-broker-host.sh. body: $body" || return 1
      ;;
    400|401|403)
      if echo "$body" | grep -qiE "cap_data_class_mismatch|data_class.*mismatch|DataClassMismatch"; then
        ok "$worker_label worker correctly rejected $cap_label-class cap with cap_data_class_mismatch ($rc)"
        record_ok "$worker_label worker rejected $cap_label-class cap ($rc cap_data_class_mismatch)"
        return 0
      fi
      if echo "$body" | grep -qiE "broker_sig_invalid|signature"; then
        prereq_missing broker-sig-mismatch "$worker_label worker rejected with broker_sig_invalid ($rc) — the deployed worker's BROKER_CAP_PUBKEY_PEM doesn't match this broker. Redeploy broker host. body: $body" || return 1
        return 0
      fi
      die "$worker_label worker rejected with HTTP $rc but error is NOT canonical cap_data_class_mismatch (body: $body) — cannot confirm the data-class isolation gate fired"
      ;;
    *)
      die "$worker_label worker returned unexpected HTTP $rc (expected 400/401/403 with cap_data_class_mismatch) — body: $body"
      ;;
  esac
}

# ─── Step 19: Config layers 3+4 — own-prefix write OK + cross-bucket AccessDenied ──
# Master-self (operator==actor): config creds reach ONLY bots/<O_master>/config/.
if should_run_step 19; then
  step "Config data class: own-prefix write OK + cross-bucket AccessDenied (layers 3+4, master-self #201)"
  if ! mint_sts_for_role_tol "$CONFIG_ROLE_ARN" config; then
    prereq_missing config-role-missing "could not mint STS for the config role ($CONFIG_ROLE_ARN) — run provision-config-role.sh + apply-config-bucket-policy.sh (AWS) first. $(cat "$STATE_DIR/sts.config.err" 2>/dev/null | head -1)" || true
  else
    CONFIG_POS_FILE="$STATE_DIR/payload.config.positive.bin"
    echo "stage3 config positive $(date -u)" > "$CONFIG_POS_FILE"
    OWN_CONFIG_KEY="bots/${OWN_ACTOR_OMNI}/config/stage3-positive.bin"
    # layer 3 — POSITIVE: the master writes its OWN config prefix.
    if run_with_sts config aws s3api put-object \
        --bucket "$CONFIG_BUCKET" --key "$OWN_CONFIG_KEY" \
        --body "$CONFIG_POS_FILE" --output json >"$STATE_DIR/put.config.positive.json" 2>&1; then
      ok "PUT succeeded at s3://$CONFIG_BUCKET/$OWN_CONFIG_KEY"
      record_ok "config PUT own prefix (200)"
    else
      cat "$STATE_DIR/put.config.positive.json" >&2
      die "config PUT to own prefix FAILED — config IAM role/bucket-policy misconfigured (apply-config-bucket-policy.sh?)"
    fi
    # layer 4 — config creds must NOT reach the memory or vault buckets.
    if run_with_sts config aws s3api put-object --bucket "$MEMORY_BUCKET" \
        --key "bots/${OWN_ACTOR_OMNI}/memory/stage3-config-cross.bin" \
        --body "$CONFIG_POS_FILE" >"$STATE_DIR/cross.config-to-memory.json" 2>&1; then
      die "config creds wrote to the MEMORY bucket — per-data-class bucket isolation broken!"
    else
      expect_access_denied "$STATE_DIR/cross.config-to-memory.json" "config creds → memory bucket"
    fi
    if run_with_sts config aws s3api put-object --bucket "$VAULT_BUCKET" \
        --key "bots/${OWN_ACTOR_OMNI}/credentials/stage3-config-cross.bin" \
        --body "$CONFIG_POS_FILE" >"$STATE_DIR/cross.config-to-vault.json" 2>&1; then
      die "config creds wrote to the VAULT bucket — per-data-class bucket isolation broken!"
    else
      expect_access_denied "$STATE_DIR/cross.config-to-vault.json" "config creds → vault bucket"
    fi
    # layer 4 reverse — memory creds must NOT reach the config bucket (needs step 3).
    if [ -f "$STATE_DIR/aki.memory" ]; then
      if run_with_sts memory aws s3api put-object --bucket "$CONFIG_BUCKET" \
          --key "bots/${OWN_ACTOR_OMNI}/config/stage3-mem-cross.bin" \
          --body "$CONFIG_POS_FILE" >"$STATE_DIR/cross.memory-to-config.json" 2>&1; then
        die "memory creds wrote to the CONFIG bucket — per-data-class bucket isolation broken!"
      else
        expect_access_denied "$STATE_DIR/cross.memory-to-config.json" "memory creds → config bucket"
      fi
    fi
  fi
fi

# ─── Step 20: NEGATIVE — config-class cap → memory + cred workers reject ────
# Symmetric with steps 14-15 but for the new Config data class (master-self).
if should_run_step 20; then
  step "NEGATIVE: config-class cap → memory worker + cred worker reject (cap_data_class_mismatch, #201)"
  master_cross_class_rejection config-store memory-taxonomy "${AGENTKEYS_WORKER_MEMORY_URL}/v1/memory/put" memory config config-to-mem
  master_cross_class_rejection config-store memory-taxonomy "${AGENTKEYS_WORKER_CRED_URL}/v1/cred/store"  cred   config config-to-cred
fi

# ─── Step 21: NEGATIVE — memory + cred caps → config worker reject ──────────
# The reverse direction: the config worker rejects any non-Config cap.
if should_run_step 21; then
  step "NEGATIVE: memory-class + cred-class cap → config worker reject (cap_data_class_mismatch, #201)"
  master_cross_class_rejection memory-put memory:stage3self "${AGENTKEYS_WORKER_CONFIG_URL}/v1/config/put" config memory mem-to-config
  master_cross_class_rejection cred-store "$SMOKE_SERVICE"   "${AGENTKEYS_WORKER_CONFIG_URL}/v1/config/put" config cred   cred-to-config
fi

# ─── Step 22: Cleanup with admin profile ───────────────────────────────────
if should_run_step 22; then
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
  # Config positive object (#201, step 19). Best-effort — absent when the config
  # infra wasn't provisioned yet (step 19 prereq_missing'd).
  if aws --region "$REGION" s3api delete-object \
        --bucket "$CONFIG_BUCKET" \
        --key "bots/${OWN_ACTOR_OMNI}/config/stage3-positive.bin" >/dev/null 2>&1; then
    ok "deleted s3://$CONFIG_BUCKET/bots/${OWN_ACTOR_OMNI}/config/stage3-positive.bin"
  fi
  # Codex review fix: print ACTUAL outcomes per step, not a static
  # "coverage" table that lies about what ran.
  printf "\n${C_OK}=== v2 stage-3 demo summary ===${C_RESET}\n" >&2
  printf "  chain          : %s\n" "${AGENTKEYS_CHAIN:-heima}" >&2
  printf "  issuer         : %s\n" "$OIDC_ISSUER" >&2
  printf "  vault bucket   : %s   (role: %s)\n" "$VAULT_BUCKET" "$VAULT_ROLE_ARN" >&2
  printf "  memory bucket  : %s  (role: %s)\n" "$MEMORY_BUCKET" "$MEMORY_ROLE_ARN" >&2
  printf "  config bucket  : %s  (role: %s · master-only #201)\n" "${CONFIG_BUCKET:-<unset>}" "${CONFIG_ROLE_ARN:-<unset>}" >&2
  printf "  wallet         : %s\n" "$WALLET_ADDR" >&2
  printf "  own omni       : 0x%s\n\n" "$OWN_ACTOR_OMNI" >&2

  nstep=""; noutcome=""; nreason=""; nmsg=""; rest=""; nok=0; nskip=0; nfail=0; ndeferred=0
  printf "  Per-step outcome (from actual execution, not claimed coverage):\n" >&2
  # Entry format:
  #   ok:   "<step>:ok:<msg>"                       (record_ok — no reason tag)
  #   skip: "<step>:skip:<reason>:<msg>"            (prereq_missing under allowed reason)
  #   fail: "<step>:fail:<reason>:<msg>"            (prereq_missing under denied/strict)
  for entry in "${STEP_OUTCOMES[@]:-}"; do
    [ -z "$entry" ] && continue
    nstep="${entry%%:*}"
    rest="${entry#*:}"
    noutcome="${rest%%:*}"
    rest="${rest#*:}"
    case "$noutcome" in
      ok)
        nmsg="$rest"
        printf "    [%2s] ${C_OK}ok${C_RESET}    %s\n" "$nstep" "$nmsg" >&2
        nok=$((nok+1)) ;;
      skip)
        nreason="${rest%%:*}"; nmsg="${rest#*:}"
        printf "    [%2s] ${C_WARN}skip${C_RESET}  [%s] %s\n" "$nstep" "$nreason" "$nmsg" >&2
        nskip=$((nskip+1)) ;;
      deferred)
        nreason="${rest%%:*}"; nmsg="${rest#*:}"
        printf "    [%2s] ${C_WARN}defer${C_RESET} [%s] %s\n" "$nstep" "$nreason" "$nmsg" >&2
        ndeferred=$((ndeferred+1)) ;;
      fail)
        nreason="${rest%%:*}"; nmsg="${rest#*:}"
        printf "    [%2s] ${C_ERR}fail${C_RESET}  [%s] %s\n" "$nstep" "$nreason" "$nmsg" >&2
        nfail=$((nfail+1)) ;;
    esac
  done
  printf "\n  Totals: %sok=%d%s  %sskip=%d%s  %sdefer=%d%s  %sfail=%d%s\n" \
    "$C_OK" "$nok" "$C_RESET" "$C_WARN" "$nskip" "$C_RESET" "$C_WARN" "$ndeferred" "$C_RESET" "$C_ERR" "$nfail" "$C_RESET" >&2

  # `deferred` steps (agent-side → the sandbox) are EXPECTED on the operator and never
  # fail/incomplete the demo. They become real coverage when the On-Sandbox harness runs.
  defer_note=""
  [ "$ndeferred" -gt 0 ] && defer_note=" ($ndeferred agent-side step(s) deferred to the sandbox — run the On-Sandbox harness to cover them)"

  if [ "$nfail" -gt 0 ]; then
    printf "\n${C_ERR}DEMO FAILED${C_RESET}: %d step(s) failed.\n" "$nfail" >&2
    exit 1
  fi
  if [ "$nskip" -gt 0 ] && [ "$ALLOW_SKIP" != "1" ]; then
    printf "\n${C_ERR}DEMO INCOMPLETE${C_RESET}: %d step(s) skipped in strict mode (this shouldn't happen — strict mode should fail-hard).\n" "$nskip" >&2
    exit 1
  fi
  if [ "$nskip" -gt 0 ]; then
    printf "\n${C_WARN}DEMO PARTIAL${C_RESET}: %d step(s) skipped (--allow-skip mode). Coverage is NOT complete; do not treat this run as a release gate.%s\n" "$nskip" "$defer_note" >&2
  elif [ "$nok" -gt 0 ]; then
    printf "\n${C_OK}DEMO COMPLETE${C_RESET}: %d steps exercised — operator-side isolation proven.%s\n" "$nok" "$defer_note" >&2
  else
    printf "\n${C_WARN}NO STEPS EXERCISED${C_RESET}: cleanup-only invocation (--from-step 22); run full demo to prove coverage.\n" >&2
  fi
fi
