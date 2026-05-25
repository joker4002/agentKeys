#!/usr/bin/env bash
# scripts/run-mcp-local.sh — run agentkeys-mcp-server locally against the
# xiaozhi.me hosted relay, with the in-memory backend + verbose frame
# logging. Use this for fast iteration / debug — the binary connects out
# to the same wss:// URL that 智控台 shows, and any device on that agent
# routes its tool calls to this laptop instead of the broker EC2.
#
# IMPORTANT: xiaozhi's relay pairs ONE tool-side connection at a time.
# Starting this script kicks the broker EC2's connection off the agent.
# Stop the systemd unit on the broker first if you want a clean cutover:
#   ssh broker 'sudo systemctl stop agentkeys-mcp-server'
# When you're done debugging, restart it:
#   ssh broker 'sudo systemctl start agentkeys-mcp-server'
#
# Usage:
#   bash scripts/run-mcp-local.sh                      # reads URL from broker /etc/agentkeys
#   bash scripts/run-mcp-local.sh 'wss://api.xiaozhi.me/mcp/?token=…'
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${1:-}"

if [ -z "$URL" ]; then
  echo "no URL passed — paste the wss:// URL from 智控台 → 智能体 → MCP接入点" >&2
  echo "  bash scripts/run-mcp-local.sh 'wss://api.xiaozhi.me/mcp/?token=…'" >&2
  exit 1
fi

if ! [[ "$URL" =~ ^wss?:// ]]; then
  echo "URL must start with wss:// or ws://, got: ${URL:0:40}…" >&2
  exit 1
fi

echo "==> building release binary" >&2
( cd "$REPO_ROOT" && cargo build --release -p agentkeys-mcp-server )

cat >&2 <<MSG

==> ready
    URL:        ${URL:0:50}…?token=<JWT>
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
