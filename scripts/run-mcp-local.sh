#!/usr/bin/env bash
# scripts/run-mcp-local.sh — run agentkeys-mcp-server locally against the
# xiaozhi.me hosted relay, with the in-memory backend + verbose frame
# logging. Use this for fast iteration / debug — the binary connects out
# to the same wss:// URL that 智控台 shows, and any device on that agent
# routes its tool calls to this laptop instead of the broker EC2.
#
# IMPORTANT: xiaozhi's relay pairs ONE tool-side connection at a time.
# Starting this script kicks the broker EC2's connection off the agent.
# Stop the broker's systemd unit first if you want a clean cutover:
#   ssh broker 'sudo systemctl stop agentkeys-mcp-server'
# When done, restart it:
#   ssh broker 'sudo systemctl start agentkeys-mcp-server'
#
# URL resolution order (highest to lowest):
#   1. positional arg ($1)
#   2. $XIAOZHI_ENDPOINT env var
#   3. ./mcp-xiaozhi-endpoint (local file you scp'd from the broker)
#   4. /etc/agentkeys/mcp-xiaozhi-endpoint (if you ran setup-mcp-host.sh
#      on this machine in xiaozhi mode)
#
# Usage:
#   bash scripts/run-mcp-local.sh                              # auto-detect URL
#   bash scripts/run-mcp-local.sh 'wss://api.xiaozhi.me/mcp/?token=…'
#   XIAOZHI_ENDPOINT='wss://…' bash scripts/run-mcp-local.sh
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

URL="${1:-${XIAOZHI_ENDPOINT:-}}"
if [ -z "$URL" ] && [ -s "$REPO_ROOT/mcp-xiaozhi-endpoint" ]; then
  URL=$(cat "$REPO_ROOT/mcp-xiaozhi-endpoint")
fi
if [ -z "$URL" ] && [ -r /etc/agentkeys/mcp-xiaozhi-endpoint ]; then
  URL=$(sudo cat /etc/agentkeys/mcp-xiaozhi-endpoint 2>/dev/null || \
        cat /etc/agentkeys/mcp-xiaozhi-endpoint 2>/dev/null || echo "")
fi

if [ -z "$URL" ]; then
  cat >&2 <<'NO_URL'
no URL found. Get it from 智控台 → 智能体 → MCP接入点 → 接入点地址 and pass via one of:
  bash scripts/run-mcp-local.sh 'wss://api.xiaozhi.me/mcp/?token=…'
  XIAOZHI_ENDPOINT='wss://…' bash scripts/run-mcp-local.sh
  echo 'wss://…' > ./mcp-xiaozhi-endpoint   # gitignored; convenient for re-runs

The URL contains a bearer JWT — don't commit it.
NO_URL
  exit 1
fi

if ! [[ "$URL" =~ ^wss?:// ]]; then
  echo "URL must start with wss:// or ws://, got: ${URL:0:40}…" >&2
  exit 1
fi

redacted="${URL%%\?*}?token=<JWT>"

echo "==> building release binary" >&2
( cd "$REPO_ROOT" && cargo build --release -p agentkeys-mcp-server )

cat >&2 <<MSG

==> ready
    URL:        ${redacted}
    backend:    in-memory (seeded with three-act fixture)
    actor:      0xa0c7…01a0c7  (DEMO_ACTOR — see backend/in_memory.rs)
    log level:  info + agentkeys_mcp_server=debug (frame-level)

    Ctrl-C to stop. Any voice query to the xiaozhi agent will land here.

MSG

exec env \
  MCP_TRANSPORT=mcp-endpoint \
  MCP_BACKEND=in-memory \
  MCP_ENDPOINT="$URL" \
  RUST_LOG="info,agentkeys_mcp_server=debug" \
  "$REPO_ROOT/target/release/agentkeys-mcp-server"
