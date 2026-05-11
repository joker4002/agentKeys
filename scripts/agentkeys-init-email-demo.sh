#!/usr/bin/env bash
# scripts/agentkeys-init-email-demo.sh — fully automated end-to-end demo
# of `agentkeys init --email` against a verified bots.litentry.org alias.
#
# Why: stage 7 demo uses `alice@demo.example` (RFC 2606 example domain,
# undeliverable) so the magic link is sent into the void and the CLI
# polls forever. This script uses an actual SES-routable address at
# bots.litentry.org, polls S3 inbound for the magic-link arrival,
# extracts the broker landing URL, parses the #t=<token> URL fragment,
# and POSTs to /v1/auth/email/verify — replicating exactly what the
# browser-side JS in /auth/email/landing does. Then it waits for the
# foreground `agentkeys init` to confirm and exit.
#
# Prereqs (set on operator workstation):
#   awsp agentkeys-admin                   # admin profile (S3 ListBucket)
#   set -a; source scripts/operator-workstation.env; set +a
#                                          # ACCOUNT_ID, REGION, MAIL_DOMAIN,
#                                          # MAIL_BUCKET, OIDC_ISSUER, BACKEND_URL
#
# Usage:
#   bash scripts/agentkeys-init-email-demo.sh                 # auto-pick demo-N alias
#   bash scripts/agentkeys-init-email-demo.sh demo-1          # use specific local-part
#   RECIPIENT=alice@bots.litentry.org bash scripts/agentkeys-init-email-demo.sh
#
# The default rotates between `demo-1@bots.litentry.org` and
# `demo-2@bots.litentry.org` so consecutive runs don't collide on the
# email_request_status row keyed by the request_id (single-use TTL).
# Override with $RECIPIENT or a positional arg.
#
# Idempotent: if the script crashes mid-run, re-running cleans the
# previous attempt's S3 inbound object on the way through.

set -euo pipefail

# This script does NOT need root. It only makes AWS API calls (operator
# admin profile creds, in your shell env) and runs the user-space
# `agentkeys` binary (writes session JWT to YOUR OS keychain, not
# root's). Running with sudo strips the env vars you sourced from
# operator-workstation.env and the script dies on the first
# ${VAR:?...} guard with a misleading "env var required" error.
if [[ -n "${SUDO_USER:-}" ]]; then
  printf '\033[1;31mxx\033[0m  do NOT run this with sudo — sudo strips your env vars,\n' >&2
  printf '    and the script needs to inherit your operator-workstation.env values.\n' >&2
  printf '    Re-run as your normal user:\n' >&2
  printf '      bash scripts/agentkeys-init-email-demo.sh %s\n' "$*" >&2
  exit 1
fi

REGION="${REGION:?REGION env var required (source operator-workstation.env)}"
MAIL_DOMAIN="${MAIL_DOMAIN:?MAIL_DOMAIN env var required}"
MAIL_BUCKET="${MAIL_BUCKET:?MAIL_BUCKET env var required}"
OIDC_ISSUER="${OIDC_ISSUER:?OIDC_ISSUER env var required (broker URL)}"
BACKEND_URL="${BACKEND_URL:?BACKEND_URL env var required (signer URL)}"

POLL_INTERVAL=5
POLL_MAX_ATTEMPTS=24    # 2 min — magic-link delivery is usually <30s
INBOUND_PREFIX="inbound/"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
require aws
require jq
require curl
require agentkeys

# ─── Recipient selection ─────────────────────────────────────────────────────
if [[ -n "${RECIPIENT:-}" ]]; then
  recipient="$RECIPIENT"
elif [[ $# -ge 1 ]]; then
  case "$1" in
    *@*) recipient="$1" ;;
    *)   recipient="$1@$MAIL_DOMAIN" ;;
  esac
else
  # Rotate demo-1 / demo-2 by parity of unix-epoch seconds. Keeps the
  # set bounded (2 addresses, easy to monitor in S3) without collisions
  # on back-to-back runs.
  if (( $(date +%s) % 2 == 0 )); then
    recipient="demo-1@$MAIL_DOMAIN"
  else
    recipient="demo-2@$MAIL_DOMAIN"
  fi
fi

log "Recipient   : $recipient"
log "Broker URL  : $OIDC_ISSUER"
log "Mail bucket : $MAIL_BUCKET"

# ─── Preflight: AWS caller identity (admin profile required for ListBucket) ─
caller_arn=$(aws sts get-caller-identity --query 'Arn' --output text 2>&1) \
  || die "aws sts get-caller-identity failed: $caller_arn
   Run: awsp agentkeys-admin   then re-run this script."
case "$caller_arn" in
  *":user/agentkey-broker"*)
    die "wrong AWS profile: $caller_arn lacks s3:ListBucket on $MAIL_BUCKET.
   Run: awsp agentkeys-admin   then re-run this script." ;;
esac
log "Caller ARN  : $caller_arn"

# ─── Preflight: the broker session JWT will be re-minted by `agentkeys init`,
# so any stale session in the keychain is fine — the CLI overwrites it. ──
# (No precheck needed; documented for clarity.)

# ─── Snapshot inbound BEFORE sending so we can identify the new object ──────
# The bucket has 400+ historical objects (test runs, prior demos). We
# only care about objects that arrive AFTER our SendEmail. snapshot the
# pre-existing key set; later we filter the post-list against this.
log "Snapshotting existing inbound/ keys (filter for NEW arrivals)"
pre_keys=$(aws s3api list-objects-v2 \
             --bucket "$MAIL_BUCKET" --prefix "$INBOUND_PREFIX" \
             --region "$REGION" \
             --query 'Contents[*].Key' --output text 2>/dev/null || true)
pre_count=$(printf '%s\n' $pre_keys | grep -c . || true)
log "  $pre_count existing object(s) — only newer arrivals will be inspected"

# ─── Fire `agentkeys init --email` in the background ────────────────────────
# It will print "Magic link sent..." then poll the broker's
# /v1/auth/email/status endpoint. When we click the link, the broker
# flips status → verified and the CLI completes.
log "Starting agentkeys init in background"
init_log=$(mktemp)
trap 'rm -f "$init_log"' EXIT
agentkeys init --email "$recipient" \
  --broker-url "$OIDC_ISSUER" \
  --signer-url "$BACKEND_URL" \
  > "$init_log" 2>&1 &
init_pid=$!
log "  init PID : $init_pid  (log: $init_log)"

# Give SES SendEmail a few seconds to actually fire before we start polling.
sleep 3

# ─── Poll S3 inbound for the new magic-link email ──────────────────────────
# Match strategy: any key NOT in pre_keys is a candidate; download body,
# look for the recipient address (may be QP-encoded) AND the broker
# landing URL prefix (also may be QP-encoded). The first matching key
# wins. SES inbound objects have UUID-like keys with no useful metadata.
log "Polling s3://$MAIL_BUCKET/$INBOUND_PREFIX for the magic-link email"
landing_url=""
matched_key=""

# Quoted-printable: '=' is encoded as '=3D'; soft-wraps as '=\n'. Reverse
# both before grepping for the URL pattern.
extract_landing_url() {
  local body="$1"
  printf '%s' "$body" \
    | sed 's/=$//' \
    | tr -d '\n' \
    | grep -oE "${OIDC_ISSUER}/auth/email/landing#t=3D[A-Za-z0-9_-]+" \
    | head -1 \
    | sed 's/=3D/=/g'
}

for attempt in $(seq 1 "$POLL_MAX_ATTEMPTS"); do
  # Fast-fail: if agentkeys init died before the email arrives (e.g.
  # broker rejected the request, signer unauthorized, ses misconfig),
  # dump the init log and die immediately instead of waiting the full
  # 2-min poll budget for an email that will never come.
  if ! kill -0 "$init_pid" 2>/dev/null; then
    warn "agentkeys init exited before magic link arrived in S3 — dumping log:"
    cat "$init_log" >&2 || true
    die "init died early (likely broker rejection); see log above"
  fi

  current_keys=$(aws s3api list-objects-v2 \
                   --bucket "$MAIL_BUCKET" --prefix "$INBOUND_PREFIX" \
                   --region "$REGION" \
                   --query 'Contents[*].Key' --output text 2>/dev/null || true)
  # Build set difference: current_keys - pre_keys
  new_keys=""
  for k in $current_keys; do
    case " $pre_keys " in
      *" $k "*) ;;
      *) new_keys="$new_keys $k" ;;
    esac
  done
  new_count=$(printf '%s\n' $new_keys | grep -c . || true)
  log "  attempt $attempt/$POLL_MAX_ATTEMPTS — $new_count new object(s)"

  for key in $new_keys; do
    [[ -z "$key" ]] && continue
    body=$(aws s3 cp "s3://$MAIL_BUCKET/$key" - --region "$REGION" 2>/dev/null || true)
    [[ -z "$body" ]] && continue
    url=$(extract_landing_url "$body")
    if [[ -n "$url" ]]; then
      landing_url="$url"
      matched_key="$key"
      log "  matched: s3://$MAIL_BUCKET/$key"
      break
    fi
  done

  [[ -n "$landing_url" ]] && break
  sleep "$POLL_INTERVAL"
done

if [[ -z "$landing_url" ]]; then
  warn "magic-link email did not arrive in $((POLL_INTERVAL * POLL_MAX_ATTEMPTS))s"
  warn "Killing background agentkeys init (PID $init_pid)"
  kill "$init_pid" 2>/dev/null || true
  warn "init log:"
  cat "$init_log" >&2 || true
  die "no magic-link URL — check broker logs + SES inbound rule"
fi

# ─── Extract the token from the URL fragment + POST to /v1/auth/email/verify ─
# This is what the browser-side JS in /auth/email/landing does. The
# fragment-based delivery means a plain `curl <landing-url>` would just
# fetch the static HTML without the token (fragments don't ride in HTTP
# requests). We have to lift the token out of the URL and POST it.
token="${landing_url##*#t=}"
if [[ -z "$token" || "$token" == "$landing_url" ]]; then
  die "could not parse #t=<token> fragment from landing URL: $landing_url"
fi

log "Clicking the magic link (POST /v1/auth/email/verify with token)"
verify_response=$(curl -sS -X POST \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg t "$token" '{token: $t}')" \
  "$OIDC_ISSUER/v1/auth/email/verify" 2>&1)
log "  verify response: $verify_response"

# Clean up the consumed S3 object so the bucket doesn't keep accreting.
aws s3 rm "s3://$MAIL_BUCKET/$matched_key" --region "$REGION" >/dev/null \
  || warn "failed to remove $matched_key from S3 (orphan)"

# ─── Wait for the foreground init to complete ──────────────────────────────
# It polls /v1/auth/email/status; once the broker flips to verified,
# init proceeds to derive the wallet via the signer and saves the
# session JWT in the OS keychain. Should complete within ~5s.
log "Waiting for agentkeys init to confirm (max 30s)"
for i in $(seq 1 30); do
  if ! kill -0 "$init_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done

if kill -0 "$init_pid" 2>/dev/null; then
  warn "agentkeys init still running after 30s — sending SIGTERM"
  kill "$init_pid" 2>/dev/null || true
  sleep 2
  warn "init log:"
  cat "$init_log" >&2 || true
  die "agentkeys init did not complete after the magic-link click"
fi

if wait "$init_pid"; then
  log "agentkeys init completed successfully:"
  cat "$init_log"
else
  warn "agentkeys init exited non-zero:"
  cat "$init_log" >&2
  die "init failed — see log above"
fi

log "DONE — end-to-end magic-link demo passed for $recipient"
