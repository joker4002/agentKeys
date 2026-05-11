#!/usr/bin/env bash
# scripts/ses-verify-sender.sh — one-shot SES per-address identity registration
# + verification, fully automated by exploiting the existing SES inbound
# receipt rule from cloud-setup.md §2.1.
#
# Usage:
#   awsp agentkeys-admin   # REQUIRED — broker user lacks s3:ListBucket
#   set -a; source scripts/operator-workstation.env; set +a
#   bash scripts/ses-verify-sender.sh
#
# The script preflights `aws sts get-caller-identity` + a `ListObjectsV2`
# probe. If you forget the profile switch, it dies immediately with
# guidance instead of silently scanning a bucket it can't read (the
# previous behaviour: AccessDenied was masked by `2>/dev/null` and the
# poll loop reported "0 object(s) under inbound/" forever).
#
# Or override the address being verified:
#   BROKER_EMAIL_FROM_ADDRESS=alerts@bots.litentry.org bash scripts/ses-verify-sender.sh
#
# What it does:
#   1. Calls `aws sesv2 create-email-identity --email-identity $BROKER_EMAIL_FROM_ADDRESS`.
#      SES sends a verification email FROM AWS to that address.
#   2. The SES receipt rule (§2.1) routes ALL inbound for *@$MAIL_DOMAIN to
#      s3://$MAIL_BUCKET/inbound/, so the verification mail lands there.
#   3. Polls the bucket every 5s (up to 2 min) for the inbound MIME object.
#   4. Greps the verification URL out of the body (text-quoted-printable).
#   5. Clicks it via curl — SES marks the identity verified.
#   6. Confirms via `aws sesv2 get-email-identity` that
#      VerifiedForSendingStatus=true.
#   7. Prints the env line to add (already in operator-workstation.env if you
#      sourced it before running, but printed for explicit confirmation).
#
# Idempotent: re-running on an already-verified identity just confirms +
# exits cleanly. Re-running on a partially-verified one (e.g. SES mail
# already in inbox but link not clicked) re-runs the click.

set -euo pipefail

REGION="${REGION:-us-east-1}"
MAIL_DOMAIN="${MAIL_DOMAIN:-bots.litentry.org}"
MAIL_BUCKET="${MAIL_BUCKET:-agentkeys-mail-${ACCOUNT_ID:?ACCOUNT_ID env var required}}"
FROM="${BROKER_EMAIL_FROM_ADDRESS:-noreply-test@${MAIL_DOMAIN}}"

POLL_INTERVAL=5
POLL_MAX_ATTEMPTS=24   # 2 minutes
INBOUND_PREFIX="inbound/"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
require aws
require jq
require curl
require grep
require sed

log "FROM         : $FROM"
log "MAIL_DOMAIN  : $MAIL_DOMAIN"
log "MAIL_BUCKET  : $MAIL_BUCKET"
log "REGION       : $REGION"

# ─── Preflight: which AWS identity are we using? ─────────────────────────────
# The S3 inbound bucket is created + owned by `agentkeys-admin` (per
# cloud-setup.md §2.1). The default `agentkey-broker` user only has
# bucket-write/object-write for SES inbound delivery — NOT s3:ListBucket.
# Without explicit caller-identity surfacing, an AccessDenied here
# manifests as "0 objects under inbound/" silently (the script masked the
# error with `2>/dev/null || true` for noisy environments). Surface it
# upfront, AND prove ListBucket works before entering the poll loop.
log "Preflight: AWS caller identity"
caller=$(aws sts get-caller-identity --output json 2>&1) \
  || die "aws sts get-caller-identity failed:\n$caller\nDid you run \`awsp agentkeys-admin\` first?"
caller_arn=$(printf '%s' "$caller" | jq -r '.Arn')
log "  caller ARN : $caller_arn"
case "$caller_arn" in
  *":user/agentkeys-admin"*|*":role/agentkeys-admin"*|*":user/agentkeys-admin/"*)
    : ;;
  *":user/agentkey-broker"*)
    die "wrong AWS profile: $caller_arn lacks s3:ListBucket on $MAIL_BUCKET.
   Run: awsp agentkeys-admin   then re-run this script." ;;
  *)
    warn "caller is not agentkeys-admin — if ListBucket fails below, switch profile" ;;
esac

log "Preflight: ListBucket on s3://$MAIL_BUCKET/$INBOUND_PREFIX"
preflight=$(aws s3api list-objects-v2 \
              --bucket "$MAIL_BUCKET" \
              --prefix "$INBOUND_PREFIX" \
              --max-items 1 \
              --region "$REGION" 2>&1) \
  || die "ListBucket failed (likely wrong profile or bucket missing):\n$preflight"
log "  ListBucket ok"

# ─── Step 0: Already verified? Skip the rest. ────────────────────────────────
existing_status=""
if existing_status=$(aws sesv2 get-email-identity \
                      --region "$REGION" \
                      --email-identity "$FROM" \
                      --query 'VerifiedForSendingStatus' \
                      --output text 2>/dev/null) && \
   [[ "$existing_status" == "True" ]]; then
  log "$FROM is already verified for sending — nothing to do."
  exit 0
fi

# ─── Step 1: Register the identity (SES sends verification mail). ────────────
log "Registering $FROM with SES (this triggers the verification mail)…"
aws sesv2 create-email-identity \
  --region "$REGION" \
  --email-identity "$FROM" >/dev/null 2>&1 \
  || warn "create-email-identity returned non-zero (likely already registered + pending) — continuing"

# ─── Step 2: Poll S3 for the SES verification mail. ──────────────────────────
#
# Extraction strategy: SES verify URLs look like
#   https://email-verification.<region>.amazonaws.com/?Context=...&Token=...
# In multipart/alternative MIME bodies, SES uses quoted-printable: '=' is
# '=3D' and lines may soft-wrap with '=\n'. We undo both, then grep for
# the URL pattern directly. No prerequisite grep on $FROM (it'd be encoded
# as 'noreply-test=40bots.litentry.org' in QP and never match).
extract_verify_url() {
  printf '%s' "$1" \
    | sed 's/=$//' \
    | tr -d '\n' \
    | grep -oE 'https://email-verification\.[a-z0-9.-]+\.amazonaws\.com/[^[:space:]"<>'\''=]+' \
    | head -1 \
    | sed 's/=3D/=/g'
}

log "Polling s3://$MAIL_BUCKET/$INBOUND_PREFIX for the verification mail…"
verify_url=""
verify_key=""
for attempt in $(seq 1 "$POLL_MAX_ATTEMPTS"); do
  # No 2>/dev/null mask: the preflight above proves ListBucket works, so
  # any error here is a real regression worth surfacing immediately.
  keys=$(aws s3api list-objects-v2 \
           --bucket "$MAIL_BUCKET" \
           --prefix "$INBOUND_PREFIX" \
           --region "$REGION" \
           --query 'Contents[*].Key' \
           --output text)
  # Diagnostic: how many objects + sample keys (first 3) per attempt.
  count=$(printf '%s\n' $keys | grep -c . || true)
  log "  attempt $attempt/$POLL_MAX_ATTEMPTS — $count object(s) under $INBOUND_PREFIX"

  for key in $keys; do
    [[ -z "$key" ]] && continue
    body=$(aws s3 cp "s3://$MAIL_BUCKET/$key" - 2>/dev/null || true)
    [[ -z "$body" ]] && continue
    url=$(extract_verify_url "$body")
    if [[ -n "$url" ]]; then
      verify_url="$url"
      verify_key="$key"
      break
    fi
  done

  if [[ -n "$verify_url" ]]; then
    log "Verification URL found in s3://$MAIL_BUCKET/$verify_key"
    aws s3 rm "s3://$MAIL_BUCKET/$verify_key" >/dev/null
    break
  fi

  sleep "$POLL_INTERVAL"
done

if [[ -z "$verify_url" ]]; then
  warn "verification mail did not arrive (or did not contain a verify URL) in $((POLL_INTERVAL * POLL_MAX_ATTEMPTS))s"
  warn "Diagnostic checks:"
  warn "  1. Is the SES receipt rule active?"
  warn "       aws ses describe-active-receipt-rule-set --region $REGION"
  warn "       → expect rule-set-name: agentkeys (per cloud-setup.md §2.1)"
  warn "  2. Did SES send the verification mail at all?"
  warn "       aws sesv2 get-email-identity --region $REGION --email-identity $FROM \\"
  warn "         --query '{status: VerifiedForSendingStatus, type: IdentityType}'"
  warn "       → if status=False with no recent inbound, the verification mail"
  warn "         may have bounced (e.g. SES sandbox + recipient unverified)."
  warn "  3. Is anything landing in the bucket at all?"
  warn "       aws s3 ls s3://$MAIL_BUCKET/$INBOUND_PREFIX --recursive | tail -10"
  die "no verification URL — see diagnostic output above"
fi

# ─── Step 3: Click the verification URL. ─────────────────────────────────────
log "Clicking verification URL…"
curl -sS -L -o /dev/null -w 'HTTP %{http_code}\n' "$verify_url"

# ─── Step 4: Confirm SES recorded verification. ──────────────────────────────
log "Confirming verification status (may take ~10s for SES to update)…"
for attempt in 1 2 3 4 5 6; do
  status=$(aws sesv2 get-email-identity \
             --region "$REGION" \
             --email-identity "$FROM" \
             --query 'VerifiedForSendingStatus' \
             --output text 2>/dev/null || echo "False")
  if [[ "$status" == "True" ]]; then
    log "$FROM is now verified for sending."
    log ""
    log "Add to env (already in scripts/operator-workstation.env after this PR):"
    log "  BROKER_EMAIL_FROM_ADDRESS=$FROM"
    exit 0
  fi
  log "  attempt $attempt/6 — status=$status, sleeping 5s"
  sleep 5
done

die "$FROM did not transition to verified within 30s — check SES console + retry"
