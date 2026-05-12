#!/usr/bin/env bash
# scripts/agentkeys-demo-show.sh — one-line rich-output inspector for an
# agentkeys session JWT, plus the signer-derive smoke-test wallet.
#
# Companion to `agentkeys-init-email-demo.sh` — after init lands a session
# under `~/.agentkeys/<session_id>/session.json`, this script extracts and
# pretty-prints every value §0.4 of stage7-demo-and-verification.md needs
# to drive `agentkeys signer derive` / `signer sign` / S3-isolation calls,
# in ONE invocation:
#
#   - identity_omni (from agentkeys.identity_value, recomputed)
#   - identity_type ("email" / "oauth2_google")
#   - actor_omni    (JWT.agentkeys.omni_account — the durable EVM omni)
#   - master_wallet (JWT.agentkeys.wallet_address — bound to actor_omni
#                    via SIWE at init; this is the wallet AWS PrincipalTag
#                    matches against, i.e. the wallet for §4 S3 prefix)
#   - signer_derive_addr (a SECOND wallet = HKDF(K3, actor_omni); useful
#                    as a signer-wire smoke test but NOT what AWS sees —
#                    see §0.4 for the key-topology explanation)
#   - jwt_expires_at + ttl_remaining (so you know to re-init before §4)
#
# Usage:
#   bash scripts/agentkeys-demo-show.sh                # default: master session
#   bash scripts/agentkeys-demo-show.sh alice          # ~/.agentkeys/alice/session.json
#   AGENTKEYS_SESSION_ID=alice bash scripts/agentkeys-demo-show.sh
#   bash scripts/agentkeys-demo-show.sh --no-derive    # skip the signer wire-test
#   bash scripts/agentkeys-demo-show.sh --json         # one-shot machine-readable
#
# Prereqs (operator workstation): jq, base64; for --derive (default):
# AGENTKEYS_SIGNER_URL set (sourced from operator-workstation.env), and
# the `agentkeys` CLI on $PATH.

set -euo pipefail

SESSION_ID="${AGENTKEYS_SESSION_ID:-master}"
DO_DERIVE=1
JSON_OUTPUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-derive) DO_DERIVE=0; shift ;;
    --json)      JSON_OUTPUT=1; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --*) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    *)   SESSION_ID="$1"; shift ;;
  esac
done

SESSION_FILE="$HOME/.agentkeys/$SESSION_ID/session.json"
if [[ ! -f "$SESSION_FILE" ]]; then
  printf 'no session file at %s\n' "$SESSION_FILE" >&2
  printf '  run: bash scripts/agentkeys-init-email-demo.sh --session-id %s\n' "$SESSION_ID" >&2
  exit 1
fi

# Decode JWT body (URL-safe base64, padded). awk + base64 is portable to
# macOS (/bin/bash 3.2, no GNU coreutils). The signer's strict JWT-omni
# check (issue #74 step 1b) means the canonical omni for any subsequent
# /dev/* call is whatever appears here — DO NOT recompute from email
# address (omni("email", addr) is wrong; the JWT post-SIWE carries the
# EVM-omni, not the identity-omni).
JWT_BODY=$(jq -r .token "$SESSION_FILE" | awk -F. '{
  p=$2; pad = 4 - length(p) % 4;
  if (pad < 4) for (i=0; i<pad; i++) p = p "=";
  gsub("-", "+", p); gsub("_", "/", p);
  print p
}' | base64 -d 2>/dev/null)

if [[ -z "$JWT_BODY" ]]; then
  printf 'failed to decode JWT body from %s — file may be corrupt or empty\n' "$SESSION_FILE" >&2
  exit 1
fi

ACTOR_OMNI=$(printf '%s' "$JWT_BODY" | jq -r '.agentkeys.omni_account')
MASTER_WALLET=$(printf '%s' "$JWT_BODY" | jq -r '.agentkeys.wallet_address')
IDENTITY_TYPE=$(printf '%s' "$JWT_BODY" | jq -r '.agentkeys.identity_type')
IDENTITY_VALUE=$(printf '%s' "$JWT_BODY" | jq -r '.agentkeys.identity_value')
EXP=$(printf '%s' "$JWT_BODY" | jq -r '.exp')
NOW=$(date +%s)
TTL_REMAINING=$(( EXP - NOW ))

# Recompute the identity_omni locally (transient — not in the JWT post-SIWE).
# Matches crates/agentkeys-broker-server/src/identity/omni_account.rs.
IDENTITY_OMNI=$(printf 'agentkeys%s%s' "$IDENTITY_TYPE" "$IDENTITY_VALUE" \
  | shasum -a 256 | awk '{print $1}')

SIGNER_DERIVE_ADDR=""
SIGNER_NOTE=""
if [[ "$DO_DERIVE" -eq 1 ]]; then
  if ! command -v agentkeys >/dev/null 2>&1; then
    SIGNER_NOTE="(agentkeys CLI not on PATH — skipped)"
  elif [[ -z "${AGENTKEYS_SIGNER_URL:-}" && -z "${BACKEND_URL:-}" ]]; then
    SIGNER_NOTE="(AGENTKEYS_SIGNER_URL unset — source operator-workstation.env to enable)"
  else
    derive_json=$(agentkeys --session-id "$SESSION_ID" --json signer derive \
                    --omni-account "$ACTOR_OMNI" 2>&1) || {
      SIGNER_NOTE="(signer derive failed: $derive_json)"
      derive_json=""
    }
    if [[ -n "$derive_json" ]]; then
      SIGNER_DERIVE_ADDR=$(printf '%s' "$derive_json" | jq -r '.address // empty' 2>/dev/null || true)
      [[ -z "$SIGNER_DERIVE_ADDR" ]] && SIGNER_NOTE="(could not parse address from derive response: $derive_json)"
    fi
  fi
fi

if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  jq -n \
    --arg session_id "$SESSION_ID" \
    --arg session_file "$SESSION_FILE" \
    --arg identity_type "$IDENTITY_TYPE" \
    --arg identity_value "$IDENTITY_VALUE" \
    --arg identity_omni "$IDENTITY_OMNI" \
    --arg actor_omni "$ACTOR_OMNI" \
    --arg master_wallet "$MASTER_WALLET" \
    --arg signer_derive_addr "$SIGNER_DERIVE_ADDR" \
    --arg signer_note "$SIGNER_NOTE" \
    --argjson exp "$EXP" \
    --argjson ttl_remaining "$TTL_REMAINING" \
    '{session_id:$session_id, session_file:$session_file,
      identity: {type:$identity_type, value:$identity_value, omni:$identity_omni},
      actor:    {omni:$actor_omni, master_wallet:$master_wallet},
      signer_derive: {address:$signer_derive_addr, note:$signer_note},
      jwt: {exp:$exp, ttl_remaining:$ttl_remaining}}'
  exit 0
fi

bold()  { printf '\033[1m%s\033[0m' "$*"; }
cyan()  { printf '\033[1;36m%s\033[0m' "$*"; }
green() { printf '\033[1;32m%s\033[0m' "$*"; }
yellow(){ printf '\033[1;33m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

ttl_msg=""
if   (( TTL_REMAINING < 0 ));   then ttl_msg=$(yellow "EXPIRED $(( -TTL_REMAINING ))s ago")
elif (( TTL_REMAINING < 300 )); then ttl_msg=$(yellow "${TTL_REMAINING}s — re-init soon")
else                                 ttl_msg=$(green "${TTL_REMAINING}s remaining")
fi

echo
bold "session_id      "; echo ": $SESSION_ID"
bold "session_file    "; echo ": $SESSION_FILE"
echo
cyan  "── identity (transient — what the human authenticated as) ──"; echo
bold "  type          "; echo ": $IDENTITY_TYPE"
bold "  value         "; echo ": $IDENTITY_VALUE"
bold "  identity_omni "; printf ': %s  ' "$IDENTITY_OMNI"; dim '(SHA256("agentkeys"||type||value); not in JWT post-SIWE)'; echo
echo
cyan  "── actor (durable — what AWS / signer / audit see) ──"; echo
bold "  actor_omni    "; printf ': %s  ' "$ACTOR_OMNI"; dim '(JWT.agentkeys.omni_account)'; echo
bold "  master_wallet "; printf ': %s  ' "$MASTER_WALLET"; dim '(JWT.agentkeys.wallet_address — THIS is the S3-prefix wallet)'; echo
echo
cyan  "── signer-wire smoke test (NOT used for AWS) ──"; echo
if [[ -n "$SIGNER_DERIVE_ADDR" ]]; then
  bold "  derive(actor_omni)"; printf ': %s  ' "$SIGNER_DERIVE_ADDR"; dim '(HKDF(K3, actor_omni); proves /dev/derive-address wire works)'; echo
  if [[ "$SIGNER_DERIVE_ADDR" == "$MASTER_WALLET" ]]; then
    yellow "  (matches master_wallet — unexpected for email/oauth2; expected only for identity_type=evm)"; echo
  else
    dim   "  (≠ master_wallet — expected: master_wallet came from HKDF(K3, identity_omni) at init)"; echo
  fi
elif [[ -n "$SIGNER_NOTE" ]]; then
  bold "  derive(actor_omni)"; echo ": $SIGNER_NOTE"
fi
echo
cyan  "── JWT lifetime ──"; echo
bold "  exp           "; printf ': %s  ' "$EXP"
date -r "$EXP" '+(%Y-%m-%d %H:%M:%S %Z)' 2>/dev/null \
  || date -d "@$EXP" '+(%Y-%m-%d %H:%M:%S %Z)' 2>/dev/null || echo
bold "  ttl_remaining "; echo ": $ttl_msg"
echo
