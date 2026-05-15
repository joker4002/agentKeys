#!/usr/bin/env bash
# scripts/agentkeys-isolation-demo.sh — executable §3+§4 isolation proof.
# Reads alice + bob session JWTs from ~/.agentkeys/<id>/ (Keychain fallback on
# macOS), mints OIDC JWTs, decodes the wallets AWS will PrincipalTag-stamp,
# cross-checks the agentkeys_user_wallet claim against the aws.amazon.com/tags
# claim (catches broker bugs where they diverge), seeds bots/<wallet>/<key>
# for both via admin, head-object-confirms the seeds landed (so a missing
# object can't masquerade as an AccessDenied), then runs the two-direction
# proof:
#   alice: ALLOW on bots/$WALLET_A/  +  AccessDenied on bots/$WALLET_B/
#   bob:   ALLOW on bots/$WALLET_B/  +  AccessDenied on bots/$WALLET_A/
# Default cleans up the seeded objects + downloaded probe artefacts on exit.
#
# Findings addressed (from codex adversarial review):
#   P1#1  peer-probe strict-matches "AccessDenied"; any other error dies
#   P1#2  own-prefix tests both ListBucket AND GetObject + content-length
#   P1#3  admin head-object pre-confirms seeds landed (denies vs missing)
#   P1#4  cross-checks .agentkeys_user_wallet == .https://aws.amazon.com/tags...
#   P1#5  both wallets null-validated + format-checked
#   P1#6  mirror proof (bob direction) runs by default
#   P2    role name, admin profile, bots/ prefix, session IDs, probe key,
#         role-session-name format — all parameterizable via env or flags
#   P3    AWS env scrubbed at script start; bob seed has || die; cleanup
#         trap removes seeded objects + tmp downloads; JWT validated at
#         load-time
#
# Prereqs:
#   set -a; source scripts/operator-workstation.env; set +a
#   bucket policy applied per cloud-setup.md §4.4 (with bots/ parent)
#   role inline policy stripped per cloud-setup.md §4.4.1
#
# Usage:
#   bash scripts/agentkeys-isolation-demo.sh
#   bash scripts/agentkeys-isolation-demo.sh --alice-id alice --bob-id bob
#   bash scripts/agentkeys-isolation-demo.sh --reinit-alice
#   bash scripts/agentkeys-isolation-demo.sh --skip-mirror
#   bash scripts/agentkeys-isolation-demo.sh --keep-seeds
#
# Env overrides (defaults shown):
#   ALICE_SESSION_ID=alice
#   BOB_SESSION_ID=bob
#   ADMIN_AWS_PROFILE=agentkeys-admin
#   DATA_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role
#   BOT_PREFIX=bots/
#
# Exit codes:
#   0  isolation proof passed (alice + bob directions, if mirror enabled)
#   1  precondition missing (env, tools, sessions)
#   2  alice own-prefix read FAILED (false-negative — bucket policy or role)
#   3  peer-prefix read SUCCEEDED (false-positive — ISOLATION BROKEN)
#   4  pre-probe seed missing (admin head-object failed after put)
#   5  JWT/AWS claim divergence (agentkeys_user_wallet ≠ tags principal_tag)

set -euo pipefail

# ─── 0. AWS env scrub FIRST (before init-email-demo.sh inherits anything) ────
# Stale AWS_* from a prior assume-role can contaminate the admin profile
# resolution inside child processes (init-email-demo.sh runs aws S3 calls).
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

# ─── 1. parameterize all the things ──────────────────────────────────────────
REGION="${REGION:?REGION env required — source scripts/operator-workstation.env}"
BUCKET="${BUCKET:?BUCKET env required}"
OIDC_ISSUER="${OIDC_ISSUER:?OIDC_ISSUER env required}"
ACCOUNT_ID="${ACCOUNT_ID:?ACCOUNT_ID env required}"

ALICE_SESSION_ID="${ALICE_SESSION_ID:-alice}"
BOB_SESSION_ID="${BOB_SESSION_ID:-bob}"
ADMIN_AWS_PROFILE="${ADMIN_AWS_PROFILE:-agentkeys-admin}"
DATA_ROLE_ARN="${DATA_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role}"
BOT_PREFIX="${BOT_PREFIX:-bots/}"

# Derive expected role name from DATA_ROLE_ARN — the caller-identity sanity
# check below uses this instead of a hardcoded role name (codex P2#1 fix).
EXPECTED_ROLE_NAME="${DATA_ROLE_ARN##*:role/}"

# Per-run unique key so concurrent operators / re-runs don't conflict, AND so
# probe-4b's AccessDenied can't be confused with "object never existed"
# (codex P1#3 + P2#6 fix). Includes PID + nanoseconds.
NANO_OR_SEC=$(date +%s%N 2>/dev/null || date +%s)
RUN_TAG="probe-${NANO_OR_SEC}-$$"

REINIT_ALICE=0
REINIT_BOB=0
SKIP_MIRROR=0
KEEP_SEEDS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --alice-id)        ALICE_SESSION_ID="$2"; shift 2 ;;
    --bob-id)          BOB_SESSION_ID="$2"; shift 2 ;;
    --reinit-alice)    REINIT_ALICE=1; shift ;;
    --reinit-bob)      REINIT_BOB=1; shift ;;
    --reinit-both)     REINIT_ALICE=1; REINIT_BOB=1; shift ;;
    --skip-mirror)     SKIP_MIRROR=1; shift ;;
    --keep-seeds)      KEEP_SEEDS=1; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

step() { printf '\n\033[1;36m═══ [%s/%s] %s\033[0m\n' "$1" "$2" "$3"; }
info() { printf '   \033[2m%s\033[0m\n' "$*"; }
ok()   { printf '   \033[1;32m✓\033[0m  %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m✗ FAIL: %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

require aws
require jq
require curl
require python3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_STEPS=8

# ─── cleanup trap: drop seeded objects + tmp downloads on exit ───────────────
SEEDED_KEYS=()
TMP_DOWNLOADS=()
cleanup() {
  local rc=$?
  if [[ "$KEEP_SEEDS" -ne 1 ]] && [[ ${#SEEDED_KEYS[@]} -gt 0 ]]; then
    for k in "${SEEDED_KEYS[@]}"; do
      AWS_PROFILE="$ADMIN_AWS_PROFILE" aws s3api delete-object \
        --region "$REGION" --bucket "$BUCKET" --key "$k" >/dev/null 2>&1 || true
    done
  fi
  for f in "${TMP_DOWNLOADS[@]:-}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
  exit $rc
}
trap cleanup EXIT

# ─── 1. ensure both sessions on disk (call init-email-demo.sh if missing) ────
step 1 "$TOTAL_STEPS" "Sessions on disk"
init_if_missing() {
  local id="$1" force="$2"
  local sess_file="$HOME/.agentkeys/$id/session.json"
  local marker="$HOME/.agentkeys/$id/.keyring_managed"
  # Reuse if EITHER the file backend OR the Keychain marker indicates a saved
  # session (codex P2#2 — was previously file-only).
  local reusable=0
  [[ -f "$sess_file" ]] && reusable=1
  [[ -s "$marker" ]] && reusable=1
  if [[ "$force" -eq 1 ]]; then
    info "$id: --reinit requested — running init-email-demo.sh"
    bash "$SCRIPT_DIR/agentkeys-init-email-demo.sh" --session-id "$id"
  elif [[ "$reusable" -eq 0 ]]; then
    info "$id: no session at $sess_file or in Keychain — running init-email-demo.sh"
    bash "$SCRIPT_DIR/agentkeys-init-email-demo.sh" --session-id "$id"
  else
    info "$id: existing session reused (pass --reinit-$id to force fresh)"
  fi
  ok "$id session ready"
}
init_if_missing "$ALICE_SESSION_ID" "$REINIT_ALICE"
init_if_missing "$BOB_SESSION_ID"   "$REINIT_BOB"

# ─── 2. load + validate session JWTs ─────────────────────────────────────────
step 2 "$TOTAL_STEPS" "Load + validate SESSION_JWT_A + SESSION_JWT_B"
# JWT format = three base64url segments separated by '.' — validate at load
# time so a corrupt session.json fails here, not in some downstream curl.
# (codex P3#4 fix.)
is_three_segment_jwt() {
  case "$1" in
    *.*.*) [[ "${1##*.*.}" != "$1" ]] && return 0 ;;
  esac
  return 1
}
load_session_jwt() {
  local id="$1"
  local sess_file="$HOME/.agentkeys/$id/session.json"
  local marker="$HOME/.agentkeys/$id/.keyring_managed"
  local raw=""
  if [[ -f "$sess_file" ]]; then
    raw=$(jq -r '.token // empty' "$sess_file" 2>/dev/null || true)
  fi
  if [[ -z "$raw" || "$raw" == "null" ]] && [[ -s "$marker" ]] && command -v security >/dev/null 2>&1; then
    raw=$(security find-generic-password -s agentkeys -a "$id" -w 2>/dev/null \
            | jq -r '.token // empty' 2>/dev/null || true)
  fi
  [[ -z "$raw" || "$raw" == "null" ]] && die "no session JWT for $id (file: $sess_file; Keychain probed)"
  is_three_segment_jwt "$raw" || die "session JWT for $id is not a valid three-segment JWT: ${raw:0:32}…"
  printf '%s' "$raw"
}
jwt_exp() {
  printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' \
    | python3 -c "import base64,sys; s=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(s+'='*(-len(s)%4)).decode())" \
    | jq -r '.exp | strftime("%Y-%m-%d %H:%M:%SZ")' 2>/dev/null || echo "?"
}
SESSION_JWT_A=$(load_session_jwt "$ALICE_SESSION_ID")
SESSION_JWT_B=$(load_session_jwt "$BOB_SESSION_ID")
info "$ALICE_SESSION_ID → ${#SESSION_JWT_A}B  exp: $(jwt_exp "$SESSION_JWT_A")"
info "$BOB_SESSION_ID   → ${#SESSION_JWT_B}B  exp: $(jwt_exp "$SESSION_JWT_B")"
ok "session JWTs loaded + validated"

# ─── 3. mint OIDC JWTs ───────────────────────────────────────────────────────
step 3 "$TOTAL_STEPS" "Mint OIDC JWTs (POST /v1/mint-oidc-jwt × 2)"
mint_oidc() {
  local jwt="$1"
  curl -sS --fail-with-body -X POST "$OIDC_ISSUER/v1/mint-oidc-jwt" \
    -H "Authorization: Bearer $jwt" | jq -r '.jwt // empty'
}
JWT_A=$(mint_oidc "$SESSION_JWT_A") || die "mint-oidc-jwt failed for $ALICE_SESSION_ID (session JWT may be expired)"
JWT_B=$(mint_oidc "$SESSION_JWT_B") || die "mint-oidc-jwt failed for $BOB_SESSION_ID (session JWT may be expired)"
[[ -z "$JWT_A" || "$JWT_A" == "null" ]] && die "mint-oidc-jwt returned empty/null for $ALICE_SESSION_ID"
[[ -z "$JWT_B" || "$JWT_B" == "null" ]] && die "mint-oidc-jwt returned empty/null for $BOB_SESSION_ID"
is_three_segment_jwt "$JWT_A" || die "JWT_A is not a three-segment JWT"
is_three_segment_jwt "$JWT_B" || die "JWT_B is not a three-segment JWT"
info "JWT_A → ${#JWT_A}B  exp: $(jwt_exp "$JWT_A")"
info "JWT_B → ${#JWT_B}B  exp: $(jwt_exp "$JWT_B")"
ok "OIDC JWTs minted (5min TTL)"

# ─── 4. decode wallets, cross-check tags claim, validate format ──────────────
step 4 "$TOTAL_STEPS" "Decode + cross-check wallet claims"
# Full body decode so we can simultaneously check .agentkeys_user_wallet AND
# .https://aws.amazon.com/tags.principal_tags.agentkeys_user_wallet[0].
# A broker bug or middlebox tampering that mutated only one of these would
# silently break isolation otherwise. (codex P1#4 fix.)
decode_body() {
  printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' \
    | python3 -c "import base64,sys; s=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(s+'='*(-len(s)%4)).decode())"
}
validate_jwt_claims() {
  local jwt="$1" label="$2"
  local body wallet tag_wallet
  body=$(decode_body "$jwt")
  wallet=$(printf '%s' "$body" | jq -r '.agentkeys_user_wallet // empty')
  tag_wallet=$(printf '%s' "$body" | jq -r '."https://aws.amazon.com/tags".principal_tags.agentkeys_user_wallet[0] // empty')
  [[ -z "$wallet" || "$wallet" == "null" ]] && die "$label: missing agentkeys_user_wallet claim"
  [[ -z "$tag_wallet" || "$tag_wallet" == "null" ]] && die "$label: missing aws.amazon.com/tags.principal_tags.agentkeys_user_wallet — STS would not stamp PrincipalTag, every probe would AccessDenied"
  [[ "$wallet" != "$tag_wallet" ]] && die "$label: agentkeys_user_wallet ($wallet) ≠ tags.principal_tags.agentkeys_user_wallet ($tag_wallet) — broker minted an inconsistent JWT" 5
  # Format check: 0x-prefixed 40-char lowercase hex.
  case "$wallet" in
    0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
    *) die "$label: agentkeys_user_wallet ($wallet) is not a 0x-prefixed 40-char lowercase hex EVM address" 5 ;;
  esac
  printf '%s' "$wallet"
}
WALLET_A=$(validate_jwt_claims "$JWT_A" "JWT_A")
WALLET_B=$(validate_jwt_claims "$JWT_B" "JWT_B")
[[ "$WALLET_A" == "$WALLET_B" ]] && die "$ALICE_SESSION_ID and $BOB_SESSION_ID resolved to the same wallet ($WALLET_A) — cannot prove isolation. Pass --reinit-both."
info "WALLET_A = $WALLET_A (tag-claim cross-check ✓)"
info "WALLET_B = $WALLET_B (tag-claim cross-check ✓)"
ok "both wallets valid, distinct, and tag-claim-consistent"

# ─── 5. seed unique per-run probe objects (admin profile) ────────────────────
step 5 "$TOTAL_STEPS" "Seed bots/<wallet>/<run-tag> probes via $ADMIN_AWS_PROFILE"
EMPTY=$(mktemp); TMP_DOWNLOADS+=("$EMPTY")
PROBE_KEY="${RUN_TAG}.txt"
KEY_A="${BOT_PREFIX}${WALLET_A}/${PROBE_KEY}"
KEY_B="${BOT_PREFIX}${WALLET_B}/${PROBE_KEY}"
SEEDED_KEYS=("$KEY_A" "$KEY_B")

put_seed() {
  local key="$1" label="$2"
  AWS_PROFILE="$ADMIN_AWS_PROFILE" aws s3api put-object --region "$REGION" --bucket "$BUCKET" \
    --key "$key" --body "$EMPTY" >/dev/null \
    || die "admin put-object failed for $label key $key — check $ADMIN_AWS_PROFILE profile has s3:PutObject" 4
  # Confirm the seed actually landed — head-object as admin (codex P1#3 fix).
  # If admin lacks GetObject for some defense-in-depth bucket policy, this
  # head-object will fail loud, vs the put-object that admin-account-owner
  # might bypass silently.
  AWS_PROFILE="$ADMIN_AWS_PROFILE" aws s3api head-object --region "$REGION" --bucket "$BUCKET" \
    --key "$key" >/dev/null 2>&1 \
    || die "admin head-object failed for $label after put — seed silently dropped, would falsify proof" 4
  info "put + head-confirmed: $key (0 bytes)"
}
put_seed "$KEY_A" "alice"
put_seed "$KEY_B" "bob"
ok "both prefixes seeded + verified by admin head-object"

# ─── 6. probe shared helper (runs the two-direction test) ────────────────────
# Each direction: assume role, list+get own prefix (expect ALLOW), get peer
# prefix (expect strict AccessDenied — any other error dies).
run_isolation_proof() {
  local who="$1" jwt="$2" own_key="$3" peer_key="$4" own_wallet="$5" peer_wallet="$6"

  printf '\n   \033[1;35m── direction: %s ──\033[0m\n' "$who"

  local session_name="isolation-demo-${who}-${RUN_TAG}"
  local creds caller probe_out keys probe_b_out tmp_dl

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
  creds=$(aws sts assume-role-with-web-identity \
    --role-arn "$DATA_ROLE_ARN" \
    --role-session-name "$session_name" \
    --web-identity-token "$jwt") \
    || die "AssumeRoleWithWebIdentity failed for $who (JWT may be expired — 5min TTL)"
  info "$who assumed $DATA_ROLE_ARN as $session_name"

  export AWS_ACCESS_KEY_ID=$(printf '%s' "$creds" | jq -r .Credentials.AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$creds" | jq -r .Credentials.SecretAccessKey)
  export AWS_SESSION_TOKEN=$(printf '%s' "$creds" | jq -r .Credentials.SessionToken)

  # Caller identity sanity check uses the role name derived from DATA_ROLE_ARN
  # — no hardcoded role name (codex P2#1 fix).
  caller=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
    || die "get-caller-identity failed under $who assumed-role creds: $caller"
  case "$caller" in
    *":assumed-role/${EXPECTED_ROLE_NAME}/${session_name}") : ;;
    *) die "expected assumed-role/${EXPECTED_ROLE_NAME}/${session_name}, got: $caller" ;;
  esac
  info "operating as: $caller"

  # 4a-list: own-prefix MUST list AND return the seed object
  printf '\n   \033[1;36m  PROBE 4a-list\033[0m  %s/  (expect ALLOW)\n' "${BOT_PREFIX}${own_wallet}"
  probe_out=$(aws s3api list-objects-v2 --bucket "$BUCKET" \
                --prefix "${BOT_PREFIX}${own_wallet}/" --output json 2>&1) \
    || die "FALSE NEGATIVE: $who cannot list own prefix.
   Response: $probe_out
   Cause: bucket policy missing bots/ parent (cloud-setup.md §4.4) OR role inline policy over-stripped (§4.4.1)." 2
  keys=$(printf '%s' "$probe_out" | jq -r '.Contents // [] | length')
  info "→ $keys key(s) returned"
  printf '%s' "$probe_out" | jq -r '.Contents // [] | .[].Key' | grep -qx "$own_key" \
    || die "FALSE NEGATIVE: $who's own seed ($own_key) not in list response — proof is invalid" 2
  ok "$who LIST own prefix ALLOWED + seed key present"

  # 4a-get: own-prefix MUST GetObject and return the expected content length
  printf '   \033[1;36m  PROBE 4a-get\033[0m   %s  (expect ALLOW, ContentLength=0)\n' "$own_key"
  tmp_dl=$(mktemp); TMP_DOWNLOADS+=("$tmp_dl")
  local head_out content_length
  head_out=$(aws s3api get-object --region "$REGION" --bucket "$BUCKET" \
               --key "$own_key" "$tmp_dl" 2>&1) \
    || die "FALSE NEGATIVE: $who cannot get-object on own prefix ($own_key).
   Response: $head_out
   Likely cause: bucket policy AllowDaemonGetOwnObjects malformed or missing." 2
  content_length=$(printf '%s' "$head_out" | jq -r '.ContentLength // empty')
  [[ "$content_length" != "0" ]] && warn "ContentLength=$content_length (expected 0)"
  ok "$who GET own seed ALLOWED"

  # 4b: peer prefix MUST AccessDenied. Strict match — any other error dies.
  printf '\n   \033[1;36m  PROBE 4b\033[0m       %s  (expect AccessDenied)\n' "$peer_key"
  tmp_dl=$(mktemp); TMP_DOWNLOADS+=("$tmp_dl")
  if probe_b_out=$(aws s3api get-object --region "$REGION" --bucket "$BUCKET" \
                     --key "$peer_key" "$tmp_dl" 2>&1); then
    die "FALSE POSITIVE — ISOLATION BROKEN: $who read peer prefix $peer_key.
   Response: $probe_b_out
   Cause: §4.4.1's strip-role-inline-policy step didn't run, so the role's
   broad s3:GetObject grant overrides the bucket-policy PrincipalTag check." 3
  fi
  # Codex P1#1: peer-probe must be strictly AccessDenied, not any error.
  case "$probe_b_out" in
    *"AccessDenied"*) : ;;
    *) die "FALSE PASS — peer-probe failed but NOT with AccessDenied.
   Response: $probe_b_out
   Possible causes: ExpiredToken (re-mint JWT_A), SignatureDoesNotMatch
   (clock skew), NoSuchBucket (wrong \$BUCKET), or network failure.
   Isolation proof is invalid — fix the upstream issue and re-run." 3 ;;
  esac
  ok "$who DENIED on peer prefix — strict AccessDenied"

  # Scrub creds before returning (so caller can switch direction)
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

step 6 "$TOTAL_STEPS" "Probe direction A → $ALICE_SESSION_ID"
run_isolation_proof "$ALICE_SESSION_ID" "$JWT_A" "$KEY_A" "$KEY_B" "$WALLET_A" "$WALLET_B"

if [[ "$SKIP_MIRROR" -eq 1 ]]; then
  step 7 "$TOTAL_STEPS" "Mirror direction (--skip-mirror set)"
  info "skipped — only alice direction proven"
else
  step 7 "$TOTAL_STEPS" "Probe direction B → $BOB_SESSION_ID (mirror)"
  run_isolation_proof "$BOB_SESSION_ID" "$JWT_B" "$KEY_B" "$KEY_A" "$WALLET_B" "$WALLET_A"
fi

step 8 "$TOTAL_STEPS" "Cleanup"
if [[ "$KEEP_SEEDS" -eq 1 ]]; then
  info "--keep-seeds set; leaving $KEY_A and $KEY_B in s3://$BUCKET/"
else
  info "trap will delete: $KEY_A and $KEY_B + tmp downloads"
fi
ok "cleanup scheduled (via trap on EXIT)"

# ─── summary ─────────────────────────────────────────────────────────────────
printf '\n\033[1;32m═══════════════════════════════════════════════════\033[0m\n'
if [[ "$SKIP_MIRROR" -eq 1 ]]; then
  printf '\033[1;32m  ✓ §4 isolation proof PASSED (alice direction only)\033[0m\n'
else
  printf '\033[1;32m  ✓ §4 isolation proof PASSED (both directions)\033[0m\n'
fi
printf '\033[1;32m═══════════════════════════════════════════════════\033[0m\n'
printf '   alice (%s) wallet : %s\n' "$ALICE_SESSION_ID" "$WALLET_A"
printf '   bob   (%s)   wallet : %s\n' "$BOB_SESSION_ID" "$WALLET_B"
printf '   role               : %s\n' "$DATA_ROLE_ARN"
printf '   seed prefix        : %s\n' "$BOT_PREFIX"
printf '   probe key          : %s  (unique per run)\n' "$PROBE_KEY"
printf '   enforcement        : aws:PrincipalTag/agentkeys_user_wallet on %s<wallet>/* (cloud-setup.md §4.4)\n' "$BOT_PREFIX"
