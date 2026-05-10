#!/usr/bin/env bash
# scripts/ses-verify-sender.sh — one-shot SES per-address identity registration
# + verification, fully automated by exploiting the existing SES inbound
# receipt rule from cloud-setup.md §2.1.
#
# Usage:
#   awsp agentkeys-admin
#   set -a; source scripts/operator-workstation.env; set +a
#   bash scripts/ses-verify-sender.sh
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
log "Polling s3://$MAIL_BUCKET/$INBOUND_PREFIX for the verification mail…"
verify_url=""
for attempt in $(seq 1 "$POLL_MAX_ATTEMPTS"); do
  keys=$(aws s3api list-objects-v2 \
           --bucket "$MAIL_BUCKET" \
           --prefix "$INBOUND_PREFIX" \
           --query 'Contents[*].Key' \
           --output text 2>/dev/null || true)
  for key in $keys; do
    [[ -z "$key" ]] && continue
    body=$(aws s3 cp "s3://$MAIL_BUCKET/$key" - 2>/dev/null || true)
    if grep -q "$FROM" <<<"$body" && grep -qE 'ses[._-]?verification|amazonaws\.com.*verify' <<<"$body"; then
      # Verification URLs look like:
      #   https://email-verification.<region>.amazonaws.com/?Context=...&Token=...
      # Body is quoted-printable, so '=' may appear as '=3D' and lines may
      # be soft-wrapped with '=\n'. Undo both before grepping.
      url=$(printf '%s' "$body" \
              | sed 's/=$//' \
              | tr -d '\n' \
              | grep -oE 'https://email-verification\.[a-z0-9.-]+\.amazonaws\.com/[^[:space:]"<>]+' \
              | head -1 \
              | sed 's/=3D/=/g')
      if [[ -n "$url" ]]; then
        verify_url="$url"
        log "Verification URL found in s3://$MAIL_BUCKET/$key"
        # Delete the verification mail so it doesn't pollute the inbox.
        aws s3 rm "s3://$MAIL_BUCKET/$key" >/dev/null
        break
      fi
    fi
  done
  [[ -n "$verify_url" ]] && break
  log "  attempt $attempt/$POLL_MAX_ATTEMPTS — verification mail not yet in bucket, sleeping ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done

[[ -z "$verify_url" ]] && die "verification mail did not arrive in $((POLL_INTERVAL * POLL_MAX_ATTEMPTS))s — \
SES may be in a region without inbound receipt rules, or the receipt rule from \
cloud-setup.md §2.1 is not active. Check: aws ses describe-active-receipt-rule-set --region $REGION"

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
