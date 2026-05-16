#!/usr/bin/env bash
# scripts/agentkeys-provision-demo.sh — collapses §5.3 of
# stage7-demo-and-verification.md into one CLI invocation.
#
# Assumes the target session-id has already been initialized via
# `scripts/agentkeys-init-email-demo.sh --session-id <name>` (or the
# `agentkeys init --email` command). Then:
#   1. Source scripts/operator-workstation.env for ACCOUNT_ID / REGION
#      / BACKEND_URL.
#   2. Export the broker URL / data-role ARN / signer URL / session-id
#      env vars the CLI expects.
#   3. Unset any stale STS creds (the CLI re-mints internally).
#   4. exec `agentkeys --session-id <name> provision <service>`.
#
# Usage:
#   bash scripts/agentkeys-provision-demo.sh [--session-id NAME] <service>
#
# Examples:
#   bash scripts/agentkeys-provision-demo.sh openrouter                  # defaults to --session-id alice
#   bash scripts/agentkeys-provision-demo.sh --session-id bob openrouter
#
# Override env defaults if needed:
#   AGENTKEYS_BROKER_URL=...  AGENTKEYS_DATA_ROLE_ARN=...  AWS_REGION=...
set -euo pipefail

SESSION_ID="${AGENTKEYS_SESSION_ID:-alice}"
SERVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id)
      [[ $# -lt 2 ]] && { echo "error: --session-id requires a value" >&2; exit 2; }
      SESSION_ID="$2"; shift 2 ;;
    --session-id=*)
      SESSION_ID="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,23p' "$0"; exit 0 ;;
    --)
      shift; break ;;
    -*)
      echo "error: unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$SERVICE" ]]; then
        SERVICE="$1"
      else
        echo "error: only one <service> positional accepted (got '$SERVICE' then '$1')" >&2
        exit 2
      fi
      shift ;;
  esac
done

if [[ -z "$SERVICE" ]]; then
  echo "error: <service> is required (e.g. 'openrouter')" >&2
  echo "usage: bash scripts/agentkeys-provision-demo.sh [--session-id NAME] <service>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPERATOR_ENV="$SCRIPT_DIR/operator-workstation.env"
if [[ ! -r "$OPERATOR_ENV" ]]; then
  echo "error: cannot read $OPERATOR_ENV — run from repo root or check perms" >&2
  exit 1
fi

# Issue #83 — the openrouter CDP scraper needs a clean Chrome on
# $CDP_URL (default localhost:9222). Always reset (kill + wipe profile
# + relaunch) rather than reuse: if any prior session attached to that
# Chrome via the chrome-devtools-mcp / Playwright Inspector, the
# browser holds a sticky "context-management not supported" flag and
# `chromium.connectOverCDP` later fails with a Browser.setDownloadBehavior
# protocol error. The reset is ~1-2s. The throwaway profile loses
# nothing operator-visible. Set AGENTKEYS_REUSE_CHROME=1 to skip the
# reset (back-to-back provision runs that the operator KNOWS aren't
# tainted by an MCP attach).
CDP_URL_DEFAULT="${CDP_URL:-http://localhost:9222}"
CDP_HOST_PORT="${CDP_URL_DEFAULT#http://}"
if [[ "${AGENTKEYS_REUSE_CHROME:-0}" == "1" ]] && \
   curl -sS --max-time 2 "$CDP_URL_DEFAULT/json/version" >/dev/null 2>&1; then
  echo "[provision-demo] reusing existing Chrome on $CDP_HOST_PORT (AGENTKEYS_REUSE_CHROME=1)"
else
  if [[ -x "$SCRIPT_DIR/reset-chrome-for-recording.sh" ]]; then
    echo "[provision-demo] resetting Chrome on $CDP_HOST_PORT (kill + wipe profile + relaunch)"
    bash "$SCRIPT_DIR/reset-chrome-for-recording.sh"
  else
    echo "error: reset-chrome-for-recording.sh missing — needed to bootstrap Chrome on $CDP_URL_DEFAULT" >&2
    echo "  manual workaround: /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --remote-debugging-port=9222 --user-data-dir=/tmp/agentkeys-chrome-profile &" >&2
    exit 1
  fi
fi
export CDP_URL="$CDP_URL_DEFAULT"

set -a
# shellcheck disable=SC1090
source "$OPERATOR_ENV"
set +a

if [[ -z "${ACCOUNT_ID:-}" ]]; then
  echo "error: ACCOUNT_ID not set after sourcing $OPERATOR_ENV" >&2
  exit 1
fi

# Session-JWT pre-check: avoid the slow path (Chrome launch + provision
# subprocess + broker round-trip) just to discover the JWT expired. If
# session.json is missing, malformed, or `exp` is in the past, auto
# re-init by invoking agentkeys-init-email-demo.sh with the admin
# profile (the init script polls SES inbound, which requires
# admin-level S3 ListBucket — broker user lacks it).
session_jwt_exp() {
  local sid="$1"
  local path="${HOME}/.agentkeys/${sid}/session.json"
  [[ -s "$path" ]] || return 1
  local jwt
  jwt=$(jq -r '.token' "$path" 2>/dev/null) || return 1
  [[ -n "$jwt" && "$jwt" != "null" ]] || return 1
  local payload
  payload=$(printf '%s' "$jwt" | awk -F. '{print $2}')
  [[ -n "$payload" ]] || return 1
  printf '%s' "$payload" | python3 -c "
import base64, json, sys
s = sys.stdin.read().strip()
b = base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
print(json.loads(b).get('exp', ''))
" 2>/dev/null
}

NOW_EPOCH=$(date +%s)
EXP_EPOCH=$(session_jwt_exp "$SESSION_ID" || true)
needs_init=false
if [[ -z "$EXP_EPOCH" || "$EXP_EPOCH" == "None" ]]; then
  echo "[provision-demo] no valid session JWT for '$SESSION_ID' — auto-initializing"
  needs_init=true
elif (( EXP_EPOCH <= NOW_EPOCH )); then
  human_exp=$(python3 -c "import datetime,sys; print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$EXP_EPOCH" 2>/dev/null || echo "$EXP_EPOCH")
  echo "[provision-demo] session JWT for '$SESSION_ID' expired at $human_exp — auto-re-initializing"
  needs_init=true
fi

if $needs_init; then
  # Init needs admin S3 perms; broker user lacks them. Pin the profile
  # for this single subshell so the wrapper's later `unset AWS_*` stays
  # clean.
  AWS_PROFILE=agentkeys-admin \
    bash "$SCRIPT_DIR/agentkeys-init-email-demo.sh" --session-id "$SESSION_ID"
fi

export AGENTKEYS_BROKER_URL="${AGENTKEYS_BROKER_URL:-https://broker.litentry.org}"
export AGENTKEYS_DATA_ROLE_ARN="${AGENTKEYS_DATA_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role}"
export AWS_REGION="${AWS_REGION:-${REGION:-us-east-1}}"
export AGENTKEYS_SIGNER_URL="${AGENTKEYS_SIGNER_URL:-${BACKEND_URL:?BACKEND_URL not set in operator-workstation.env}}"
export AGENTKEYS_SESSION_ID="$SESSION_ID"

# openrouter-cdp.ts requires a fresh password per run (Clerk rejects
# plus-alias reuse on the email too, but issue #83 has the scraper
# derive the email from $AGENTKEYS_USER_WALLET — injected by the CLI
# after the STS exchange — so the SES routing Lambda can move it into
# `bots/${wallet}/inbound/`). Only export SIGNUP_PASSWORD here; let the
# scraper build SIGNUP_EMAIL from the wallet when it runs.
PROVISION_TS="$(date +%s)"
export AGENTKEYS_SIGNUP_PASSWORD="${AGENTKEYS_SIGNUP_PASSWORD:-Pv-${PROVISION_TS}-xZq9okFg}"
# Re-export operator's MAIL_DOMAIN so the scraper inherits it.
export AGENTKEYS_MAIL_DOMAIN="${AGENTKEYS_MAIL_DOMAIN:-${MAIL_DOMAIN:-bots.litentry.org}}"

# CLI re-mints OIDC JWT internally and calls AssumeRoleWithWebIdentity;
# any stale AWS creds in the operator shell would shadow that. Drop them.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

exec agentkeys --session-id "$SESSION_ID" provision "$SERVICE"
