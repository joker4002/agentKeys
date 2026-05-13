#!/usr/bin/env bash
# scripts/agentkeys-isolation-demo.sh — one-shot §3 + §4 isolation proof for
# stage7-demo-and-verification.md. Picks up where init-email-demo.sh leaves
# off: reads alice + bob's saved session JWTs from ~/.agentkeys/<id>/, mints
# OIDC JWTs, decodes the wallets AWS will tag with, assumes
# agentkeys-data-role via alice's JWT, seeds bots/${wallet}/ for both via
# admin profile, then probes — alice's own prefix MUST succeed, bob's prefix
# MUST be AccessDenied.
#
# This is the executable form of stage7-demo-and-verification.md §3 + §4.
# Pre-merged across the §2-manual and §0.4-only paths because §3 decodes the
# JWT's actual agentkeys_user_wallet claim instead of guessing — same script
# proves isolation regardless of which §2 path the operator took.
#
# Prereqs:
#   set -a; source scripts/operator-workstation.env; set +a
#   awsp agentkeys-admin                   # admin needs s3:PutObject for seeds
#   bucket policy applied per cloud-setup.md §4.4 (with bots/ prefix)
#   role inline policy stripped per cloud-setup.md §4.4.1
#
# Sessions: by default reuses ~/.agentkeys/alice + ~/.agentkeys/bob if they
# exist on disk. Otherwise (or with --reinit-*) runs init-email-demo.sh,
# which polls S3 for the SES inbound + auto-clicks the magic link.
#
# Usage:
#   bash scripts/agentkeys-isolation-demo.sh                    # reuse existing
#   bash scripts/agentkeys-isolation-demo.sh --reinit-alice     # force fresh alice
#   bash scripts/agentkeys-isolation-demo.sh --reinit-bob
#   bash scripts/agentkeys-isolation-demo.sh --reinit-both
#
# Exit codes:
#   0  isolation proof passed
#   1  precondition missing (env vars, tools, session files)
#   2  alice's own-prefix read FAILED (false-negative — bucket policy or role inline issue)
#   3  bob's peer-prefix read SUCCEEDED (false-positive — ISOLATION BROKEN)

set -euo pipefail

REGION="${REGION:?REGION env required — source scripts/operator-workstation.env}"
BUCKET="${BUCKET:?BUCKET env required}"
OIDC_ISSUER="${OIDC_ISSUER:?OIDC_ISSUER env required}"
ACCOUNT_ID="${ACCOUNT_ID:?ACCOUNT_ID env required}"
DATA_ROLE_ARN="${DATA_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role}"

REINIT_ALICE=0
REINIT_BOB=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reinit-alice) REINIT_ALICE=1; shift ;;
    --reinit-bob)   REINIT_BOB=1; shift ;;
    --reinit-both)  REINIT_ALICE=1; REINIT_BOB=1; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit "${2:-1}"; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

require aws
require jq
require curl
require python3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── 1. ensure both sessions on disk (call init-email-demo.sh if missing) ────
init_if_missing() {
  local id="$1" force="$2"
  local sess_file="$HOME/.agentkeys/$id/session.json"
  if [[ "$force" -eq 1 ]] || [[ ! -f "$sess_file" ]]; then
    log "Initing $id session (force=$force)…"
    bash "$SCRIPT_DIR/agentkeys-init-email-demo.sh" --session-id "$id"
  else
    log "$id session on disk — reusing (pass --reinit-$id to force fresh)"
  fi
}
init_if_missing alice "$REINIT_ALICE"
init_if_missing bob   "$REINIT_BOB"

# ─── 2. load session JWTs ────────────────────────────────────────────────────
# Either ~/.agentkeys/<id>/session.json (file mode, default) OR the macOS
# Keychain entry (when .keyring_managed marker is non-empty). We try file
# first because init-email-demo.sh writes there; Keychain fallback is for
# operators who configured the CLI to use Keychain.
load_session_jwt() {
  local id="$1"
  local sess_file="$HOME/.agentkeys/$id/session.json"
  local marker="$HOME/.agentkeys/$id/.keyring_managed"
  if [[ -f "$sess_file" ]]; then
    jq -r .token "$sess_file"
  elif [[ -s "$marker" ]] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s agentkeys -a "$id" -w 2>/dev/null | jq -r .token
  else
    die "no session for $id (looked at $sess_file and macOS Keychain). Run init-email-demo.sh first."
  fi
}
SESSION_JWT_A=$(load_session_jwt alice)
SESSION_JWT_B=$(load_session_jwt bob)
ok "loaded session JWTs for alice + bob"

# ─── 3. mint OIDC JWTs ───────────────────────────────────────────────────────
mint_oidc() {
  local jwt="$1"
  curl -sS --fail-with-body -X POST "$OIDC_ISSUER/v1/mint-oidc-jwt" \
    -H "Authorization: Bearer $jwt" \
    | jq -r .jwt
}
JWT_A=$(mint_oidc "$SESSION_JWT_A")
JWT_B=$(mint_oidc "$SESSION_JWT_B")
ok "minted OIDC JWTs (5min TTL)"

# ─── 4. decode the wallets AWS will tag the assumed sessions with ────────────
# These are the agentkeys_user_wallet claim values — what the bucket policy's
# ${aws:PrincipalTag/agentkeys_user_wallet} expands to per assumed session.
decode_aws_wallet() {
  printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+' \
    | python3 -c "import base64,sys; s=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(s+'='*(-len(s)%4)).decode())" \
    | jq -r .agentkeys_user_wallet
}
WALLET_A=$(decode_aws_wallet "$JWT_A")
WALLET_B=$(decode_aws_wallet "$JWT_B")
[[ "$WALLET_A" == "null" || -z "$WALLET_A" ]] && die \
  "JWT_A missing agentkeys_user_wallet claim — broker version is too old. Re-deploy via setup-broker-host.sh."
[[ "$WALLET_A" == "$WALLET_B" ]] && die \
  "alice and bob resolved to the same wallet ($WALLET_A) — cannot prove isolation. Both sessions must derive different wallets; pass --reinit-both."
log "WALLET_A=$WALLET_A"
log "WALLET_B=$WALLET_B"

# ─── 5. assume agentkeys-data-role as alice ──────────────────────────────────
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
CREDS=$(AWS_PROFILE= aws sts assume-role-with-web-identity \
  --role-arn "$DATA_ROLE_ARN" \
  --role-session-name "isolation-demo-A-$(date +%s)" \
  --web-identity-token "$JWT_A")
ok "assumed $DATA_ROLE_ARN as alice"

# ─── 6. seed both wallets' prefixes (admin profile bypasses bucket policy) ──
log "seeding bots/${WALLET_A}/hello.txt + bots/${WALLET_B}/hello.txt via admin"
EMPTY=$(mktemp); trap "rm -f '$EMPTY'" EXIT
AWS_PROFILE=agentkeys-admin aws s3api put-object --region "$REGION" --bucket "$BUCKET" \
  --key "bots/${WALLET_A}/hello.txt" --body "$EMPTY" >/dev/null
AWS_PROFILE=agentkeys-admin aws s3api put-object --region "$REGION" --bucket "$BUCKET" \
  --key "bots/${WALLET_B}/hello.txt" --body "$EMPTY" >/dev/null
ok "seeded both prefixes"

# ─── 7. re-export assumed-role creds + probe both prefixes ──────────────────
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r .Credentials.SessionToken)
unset AWS_PROFILE   # otherwise the SDK prefers the named profile over env

caller=$(aws sts get-caller-identity --query Arn --output text)
case "$caller" in
  *":assumed-role/agentkeys-data-role/isolation-demo-A-"*) : ;;
  *) die "expected to be assumed-role/agentkeys-data-role, got: $caller" ;;
esac
log "operating as: $caller"

# 4a — alice MUST be able to list + get her own prefix
log "PROBE 4a: list bots/${WALLET_A}/ — expect SUCCESS"
if ! aws s3api list-objects-v2 --bucket "$BUCKET" \
       --prefix "bots/${WALLET_A}/" --query 'Contents[*].Key' >/dev/null 2>&1; then
  die "FALSE NEGATIVE: alice cannot read her own prefix bots/${WALLET_A}/.
   Likely cause: bucket policy was not updated to include bots/ parent
   (see cloud-setup.md §4.4) OR the role inline policy was over-stripped
   (should have ses:SendRawEmail only — see §4.4.1)." 2
fi
ok "alice reads bots/${WALLET_A}/ — allowed (expected)"

# 4b — alice MUST be denied on bob's prefix (the climax)
log "PROBE 4b: get bots/${WALLET_B}/hello.txt — expect AccessDenied"
if aws s3api get-object --region "$REGION" --bucket "$BUCKET" \
     --key "bots/${WALLET_B}/hello.txt" /tmp/isolation-probe-B.txt >/dev/null 2>&1; then
  rm -f /tmp/isolation-probe-B.txt
  die "FALSE POSITIVE — ISOLATION BROKEN: alice read bob's prefix bots/${WALLET_B}/.
   Likely cause: §4.4.1's strip-role-inline-policy step didn't run, so the
   role's broad s3:GetObject grant overrides the bucket-policy PrincipalTag
   check. Run cloud-setup.md §4.4.1 then re-run this script." 3
fi
ok "alice DENIED on bots/${WALLET_B}/ — cloud-enforced isolation works"

# ─── summary ─────────────────────────────────────────────────────────────────
printf '\n\033[1;32m====================================================\033[0m\n'
printf '\033[1;32m✓ §4 isolation proof PASSED\033[0m\n'
printf '  alice wallet : %s\n' "$WALLET_A"
printf '  bob wallet   : %s\n' "$WALLET_B"
printf '  enforcement  : S3 bucket policy via ${aws:PrincipalTag/agentkeys_user_wallet}\n'
printf '\033[1;32m====================================================\033[0m\n'
