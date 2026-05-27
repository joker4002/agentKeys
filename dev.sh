#!/usr/bin/env bash
# dev.sh — single-terminal dev stack for the parent-control web UI.
#
# Lives at the agentkeys repo root so the entry point is one path away
# from the operator on a fresh clone:
#
#   bash dev.sh                          # from the repo root
#   ./dev.sh                             # same
#   cd apps/parent-control && npm run dev:stack   # equivalent via npm
#
# Starts THREE processes and multiplexes their stdouts into this
# terminal with colored per-process line prefixes:
#
#   [daemon]  magenta  — agentkeys-daemon --ui-bridge   (port 3114)
#   [mcp]     green    — agentkeys-mcp-server           (port 8088)
#   [ui]      cyan     — npx next dev                   (port 3113)
#   [dev]     yellow   — this script's own status lines
#
# Ctrl-C cleans up all children. Stale processes holding any of the
# three ports are SIGTERM'd, given 3 s to exit, SIGKILL'd if still
# alive, then re-checked before binding.
#
# Environment overrides:
#   UI_PORT           default 3113
#   DAEMON_PORT       default 3114
#   MCP_PORT          default 8088
#   DAEMON_ORIGIN     default http://localhost:${UI_PORT}
#   DAEMON_RP_ID      default localhost
#   DAEMON_RP_NAME    default AgentKeys
#   MCP_BACKEND       default in-memory   (zero external deps; auto-seeds demo fixtures)
#
# Requirements: cargo, npx (node), lsof, curl. Bash 3.2+ (works with
# macOS default /bin/bash).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$REPO_ROOT/apps/parent-control"

if [ ! -d "$APP_DIR" ]; then
  echo "[dev] expected $APP_DIR — is dev.sh at the agentkeys repo root?" >&2
  exit 1
fi

# ─── Colors ────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_DAEMON='\033[0;35m'   # magenta
  C_MCP='\033[0;32m'      # green
  C_UI='\033[0;36m'       # cyan
  C_INFO='\033[1;33m'     # bold yellow
  C_ERR='\033[1;31m'      # bold red
  C_DIM='\033[2m'
  C_RESET='\033[0m'
else
  C_DAEMON='' C_MCP='' C_UI='' C_INFO='' C_ERR='' C_DIM='' C_RESET=''
fi

UI_PORT="${UI_PORT:-3113}"
DAEMON_PORT="${DAEMON_PORT:-3114}"
MCP_PORT="${MCP_PORT:-8088}"
DAEMON_BIND="127.0.0.1:${DAEMON_PORT}"
MCP_BIND="127.0.0.1:${MCP_PORT}"
DAEMON_ORIGIN="${DAEMON_ORIGIN:-http://localhost:${UI_PORT}}"
DAEMON_RP_ID="${DAEMON_RP_ID:-localhost}"
DAEMON_RP_NAME="${DAEMON_RP_NAME:-AgentKeys}"
MCP_BACKEND="${MCP_BACKEND:-in-memory}"

DAEMON_BIN="$REPO_ROOT/target/debug/agentkeys-daemon"
MCP_BIN="$REPO_ROOT/target/debug/agentkeys-mcp-server"

say()  { printf "%b[dev]%b %s\n" "$C_INFO"  "$C_RESET" "$*"; }
warn() { printf "%b[dev]%b %s\n" "$C_INFO"  "$C_RESET" "$*" >&2; }
err()  { printf "%b[dev]%b %s\n" "$C_ERR"   "$C_RESET" "$*" >&2; }

# Prefix every line of a stream with a coloured tag, written to stdout.
prefix() {
  local color="$1"
  local tag="$2"
  while IFS= read -r line; do
    printf "%b[%s]%b %s\n" "$color" "$tag" "$C_RESET" "$line"
  done
}

# Kill any leftover process holding a port. Graceful first (SIGTERM,
# 3 s wait), forceful if needed (SIGKILL), then verify the port is
# actually free before returning. Aborts the script if the port can't
# be freed — there's no point trying to bind on top of a zombie.
free_port() {
  local port="$1"
  local pid
  pid=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  if [ -z "$pid" ]; then return 0; fi
  warn "port :$port held by pid $pid — sending SIGTERM"
  kill "$pid" 2>/dev/null || true
  local waited=0
  while [ "$waited" -lt 6 ]; do
    sleep 0.5
    waited=$((waited + 1))
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "pid $pid still alive after 3 s — sending SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  if lsof -ti tcp:"$port" >/dev/null 2>&1; then
    err "port :$port is still occupied after SIGKILL — investigate manually"
    err "  lsof -i tcp:$port"
    return 1
  fi
}

# Build a Rust binary iff missing or older than any .rs source under the
# listed crates. $1 = bin path, remaining args = crate dirs to watch.
build_if_needed() {
  local bin="$1"; shift
  local label="$1"; shift
  local cargo_pkg="$1"; shift
  local need_build=0
  if [ ! -x "$bin" ]; then
    need_build=1
  else
    local d
    for d in "$@"; do
      if [ -n "$(find "$d" -name '*.rs' -newer "$bin" -print -quit 2>/dev/null)" ]; then
        need_build=1
        break
      fi
    done
  fi
  if [ "$need_build" = "1" ]; then
    say "building $label (debug)…"
    ( cd "$REPO_ROOT" && cargo build -p "$cargo_pkg" ) \
      || { err "cargo build -p $cargo_pkg failed"; exit 1; }
  else
    printf "%b[dev]%b %s%s binary is current — skipping build%b\n" \
      "$C_INFO" "$C_RESET" "$C_DIM" "$label" "$C_RESET"
  fi
}

DAEMON_PID=""
MCP_PID=""
UI_PID=""

cleanup() {
  trap - INT TERM EXIT
  printf "\n"
  say "shutting down…"
  for p in "$UI_PID" "$MCP_PID" "$DAEMON_PID"; do
    [ -z "$p" ] && continue
    kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  say "stopped."
}
trap cleanup INT TERM EXIT

# ─── Preflight ─────────────────────────────────────────────────────
free_port "$UI_PORT"
free_port "$DAEMON_PORT"
free_port "$MCP_PORT"
build_if_needed "$DAEMON_BIN" "agentkeys-daemon" "agentkeys-daemon" \
  "$REPO_ROOT/crates/agentkeys-daemon"
build_if_needed "$MCP_BIN" "agentkeys-mcp-server" "agentkeys-mcp-server" \
  "$REPO_ROOT/crates/agentkeys-mcp" "$REPO_ROOT/crates/agentkeys-mcp-server"

# ─── Start daemon ──────────────────────────────────────────────────
say "starting daemon on http://${DAEMON_BIND} (rp_id=${DAEMON_RP_ID})"
"$DAEMON_BIN" --ui-bridge \
  --ui-bridge-bind   "$DAEMON_BIND" \
  --ui-bridge-origin "$DAEMON_ORIGIN" \
  --ui-bridge-rp-id  "$DAEMON_RP_ID" \
  --ui-bridge-rp-name "$DAEMON_RP_NAME" \
  2>&1 | prefix "$C_DAEMON" "daemon" &
DAEMON_PID=$!

say "waiting for daemon /healthz…"
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sSf "http://${DAEMON_BIND}/healthz" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 0.5
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    err "daemon exited before becoming ready — see [daemon] log above"
    exit 1
  fi
done
[ "$ready" = "0" ] && { err "daemon did not respond on /healthz within 5 s"; exit 1; }
say "daemon ready."

# ─── Start MCP server ──────────────────────────────────────────────
say "starting mcp-server on http://${MCP_BIND} (backend=${MCP_BACKEND})"
"$MCP_BIN" --backend "$MCP_BACKEND" --listen "$MCP_BIND" \
  2>&1 | prefix "$C_MCP" "mcp" &
MCP_PID=$!

# Wait for the MCP server's listener (no /healthz today — probe TCP).
say "waiting for mcp-server tcp…"
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sS -o /dev/null -w "%{http_code}" "http://${MCP_BIND}/" 2>/dev/null | grep -qE "^(2..|3..|4..)"; then
    ready=1; break
  fi
  sleep 0.5
  if ! kill -0 "$MCP_PID" 2>/dev/null; then
    err "mcp-server exited before becoming ready — see [mcp] log above"
    exit 1
  fi
done
[ "$ready" = "0" ] && { err "mcp-server did not respond on / within 5 s"; exit 1; }
say "mcp-server ready."

# ─── Start Next.js dev server ──────────────────────────────────────
say "starting Next.js dev server on http://localhost:${UI_PORT}"
say "  NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon"
say "  NEXT_PUBLIC_AGENTKEYS_DAEMON_URL=http://${DAEMON_BIND}"
say "  NEXT_PUBLIC_AGENTKEYS_MCP_URL=http://${MCP_BIND}"
(
  cd "$APP_DIR"
  NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon \
  NEXT_PUBLIC_AGENTKEYS_DAEMON_URL="http://${DAEMON_BIND}" \
  NEXT_PUBLIC_AGENTKEYS_MCP_URL="http://${MCP_BIND}" \
    npx next dev -p "$UI_PORT" 2>&1
) | prefix "$C_UI" "ui" &
UI_PID=$!

say "all three processes running. Ctrl-C to stop."
say "  UI:     http://localhost:${UI_PORT}"
say "  daemon: http://${DAEMON_BIND}"
say "  mcp:    http://${MCP_BIND}"

# Wait until any child exits, then cleanup() trap handles the rest.
# `wait -n` is bash 4.3+; macOS default /bin/bash is 3.2. Poll instead.
while \
  kill -0 "$DAEMON_PID" 2>/dev/null && \
  kill -0 "$MCP_PID"    2>/dev/null && \
  kill -0 "$UI_PID"     2>/dev/null
do
  sleep 1
done
warn "one of the children exited — shutting down the others"
