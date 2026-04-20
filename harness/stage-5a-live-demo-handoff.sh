#!/usr/bin/env bash
# Stage 5a live-demo one-shot handoff.
# Preconditions checked up front; failures are loud; prints SUCCESS when
# all four acceptance criteria pass.
#
# Usage (with AGENTKEYS_EMAIL_{BACKEND,USER,PASSWORD,HOST,PORT} exported;
# AGENTKEYS_SIGNUP_EMAIL is auto-minted below if unset):
#   cd ~/Projects/agentkeys
#   bash harness/stage-5a-live-demo-handoff.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
BIN="$REPO_ROOT/target/release/agentkeys"
BACKEND="${BACKEND:-http://127.0.0.1:8090}"

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\033[1;32mPASS:\033[0m %s\n' "$*"; }

say "Preflight — required env"
: "${AGENTKEYS_EMAIL_BACKEND:?AGENTKEYS_EMAIL_BACKEND must be set (e.g. gmail)}"
: "${AGENTKEYS_EMAIL_USER:?AGENTKEYS_EMAIL_USER must be set to the CANONICAL Gmail address (NOT a plus-alias; IMAP login only accepts canonical)}"
: "${AGENTKEYS_EMAIL_PASSWORD:?AGENTKEYS_EMAIL_PASSWORD must be set (Gmail app password; NOT your normal Google password)}"
: "${AGENTKEYS_EMAIL_HOST:?AGENTKEYS_EMAIL_HOST must be set (imap.gmail.com)}"
: "${AGENTKEYS_EMAIL_PORT:?AGENTKEYS_EMAIL_PORT must be set (993)}"

# Auto-mint a fresh single-plus alias for THIS run so OpenRouter never sees
# a repeat email. Strip any existing +suffix on AGENTKEYS_EMAIL_USER first:
# some email validators (including OpenRouter's) reject double-plus addresses
# like agent+2026042001+or-...@wildmeta.ai and silently drop the signup. The
# inbox delivery path doesn't care, but the signup form does.
if [ -z "${AGENTKEYS_SIGNUP_EMAIL:-}" ]; then
  RAW_LOCAL="${AGENTKEYS_EMAIL_USER%@*}"
  CANONICAL_LOCAL="${RAW_LOCAL%%+*}"   # strip first + and everything after
  DOMAIN="${AGENTKEYS_EMAIL_USER#*@}"
  export AGENTKEYS_SIGNUP_EMAIL="${CANONICAL_LOCAL}+or-$(date +%s)@${DOMAIN}"
  say "Auto-minted AGENTKEYS_SIGNUP_EMAIL=$AGENTKEYS_SIGNUP_EMAIL (stripped existing plus-alias before appending)"
fi

say "Preflight — binary exists"
[ -x "$BIN" ] || fail "$BIN not found. Run: cargo build --release -p agentkeys-cli"

say "Preflight — mock-server at $BACKEND is up"
curl -sf "$BACKEND/health" >/dev/null 2>&1 \
  || curl -sf "$BACKEND" >/dev/null 2>&1 \
  || fail "mock-server not reachable at $BACKEND. Run: cargo run --release -p agentkeys-mock-server -- --port 8090 &"

say "Preflight — node + playwright deps + chromium browser"
command -v node >/dev/null || fail "node not on PATH"
command -v npx  >/dev/null || fail "npx not on PATH"
[ -d provisioner-scripts/node_modules ] \
  || fail "provisioner-scripts deps missing. Run: npm install --prefix provisioner-scripts"
# Playwright caches browsers under \$HOME/Library/Caches/ms-playwright on macOS;
# a run-in-unusual-HOME provision will hit "browserType.launch: Executable
# doesn't exist" unless they are installed under THIS \$HOME.
if ! ls "${HOME}/Library/Caches/ms-playwright/chromium_headless_shell-"* >/dev/null 2>&1 \
  && ! ls "${HOME}/.cache/ms-playwright/chromium_headless_shell-"* >/dev/null 2>&1; then
  fail "Playwright chromium not installed under \$HOME=$HOME. Run: npx playwright install chromium --with-deps"
fi

say "1. Initialize master session"
$BIN --backend $BACKEND init --mock-token stage5-live-demo || fail "init"

say "2. Env snapshot (masking secrets)"
env | grep -E 'AGENTKEYS_(EMAIL|SIGNUP)_' | sed 's/\(PASSWORD=\).*/\1***REDACTED***/'

say "3. agentkeys provision openrouter"
if ! $BIN --backend $BACKEND provision openrouter; then
  EC=$?
  echo "---exit=$EC---"
  LOG=$(ls -t $HOME/.agentkeys/logs/provision-openrouter-*.log 2>/dev/null | head -1)
  if [ -n "$LOG" ]; then
    echo "=== most recent provision log: $LOG ==="
    cat "$LOG"
  else
    echo "(no provision log written — orchestrator path unreachable)"
  fi
  fail "provision failed; inspect log above"
fi

say "4. AC#1-#3 — read full key back (exit 0 + masked-key form already checked above)"
KEY=$($BIN --backend $BACKEND read openrouter) || fail "read openrouter"
case "$KEY" in
  sk-or-v1-*) pass "read returned key of correct prefix" ;;
  *) fail "read returned unexpected prefix: $(echo "$KEY" | head -c 12)..." ;;
esac

say "5. AC#4 — curl OpenRouter /api/v1/models"
HTTP_CODE=$(curl -sS -o /tmp/or-models.json -w '%{http_code}' \
  -H "Authorization: Bearer $KEY" \
  https://openrouter.ai/api/v1/models)
if [ "$HTTP_CODE" != "200" ]; then
  echo "unexpected HTTP $HTTP_CODE"
  head -c 500 /tmp/or-models.json
  fail "OpenRouter /api/v1/models did not return 200"
fi
head -c 40 /tmp/or-models.json
echo ''
pass "OpenRouter /api/v1/models returned 200"

say "ALL FOUR ACCEPTANCE CRITERIA PASS"
echo "SUCCESS"
