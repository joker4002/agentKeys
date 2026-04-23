#!/usr/bin/env bash
# Stage 6 demo — one run of the CDP scraper. Assumes env is loaded (source
# scripts/stage6-demo-env.sh first). Refreshes signup email each call so you
# can loop this against a single env session until STS creds expire.
#
#   ./scripts/stage6-demo-run.sh
#
# Prints the extracted sk-or-v1-* key on success, tails /tmp/cdp.log on failure.

set -euo pipefail

: "${AGENTKEYS_SES_BUCKET:?env not loaded — run 'source scripts/stage6-demo-env.sh' first}"
: "${AWS_ACCESS_KEY_ID:?env not loaded — run 'source scripts/stage6-demo-env.sh' first}"
: "${DOMAIN:?env not loaded — run 'source scripts/stage6-demo-env.sh' first}"

export AGENTKEYS_SIGNUP_EMAIL="bot-$(date +%s)@${DOMAIN}"
export AGENTKEYS_SIGNUP_PASSWORD="Stg6-$(date +%s)-xZq9okFg"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT/provisioner-scripts"

echo "signup email: $AGENTKEYS_SIGNUP_EMAIL"
echo "running scraper (log: /tmp/cdp.log)..."

set +e
KEY=$(npx tsx src/scrapers/openrouter-cdp.ts 2>/tmp/cdp.log | tail -1)
STATUS=$?
set -e

if [[ $STATUS -ne 0 || -z "$KEY" || ! "$KEY" =~ ^sk-or-v1- ]]; then
  echo "--- FAILED (exit $STATUS) ---"
  tail -25 /tmp/cdp.log
  exit 1
fi

echo "--- SUCCESS ---"
echo "extracted key: ${KEY:0:12}****...${KEY: -4}"
echo "$KEY"
