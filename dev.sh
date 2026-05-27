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
# Starts the agentkeys-daemon in --ui-bridge mode and the Next.js dev
# server, multiplexes their stdouts into this terminal with colored
# per-process line prefixes:
#
#   [daemon]  magenta  — agentkeys-daemon --ui-bridge
#   [ui]      cyan     — npx next dev
#   [dev]     yellow   — this script's own status lines
#
# Ctrl-C cleans up both children. If UI_PORT (3113) or DAEMON_PORT
# (3114) is held by a stale process from a previous crash, this script
# kills the squatter before binding.
#
# Environment overrides:
#   UI_PORT           default 3113
#   DAEMON_PORT       default 3114
#   DAEMON_ORIGIN     default http://localhost:${UI_PORT}
#   DAEMON_RP_ID      default localhost
#   DAEMON_RP_NAME    default AgentKeys
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
  C_UI='\033[0;36m'       # cyan
  C_INFO='\033[1;33m'     # bold yellow
  C_ERR='\033[1;31m'      # bold red
  C_DIM='\033[2m'
  C_RESET='\033[0m'
else
  C_DAEMON='' C_UI='' C_INFO='' C_ERR='' C_DIM='' C_RESET=''
fi

UI_PORT="${UI_PORT:-3113}"
DAEMON_PORT="${DAEMON_PORT:-3114}"
DAEMON_BIND="127.0.0.1:${DAEMON_PORT}"
DAEMON_ORIGIN="${DAEMON_ORIGIN:-http://localhost:${UI_PORT}}"
DAEMON_RP_ID="${DAEMON_RP_ID:-localhost}"
DAEMON_RP_NAME="${DAEMON_RP_NAME:-AgentKeys}"

DAEMON_BIN="$REPO_ROOT/target/debug/agentkeys-daemon"

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

# Kill any leftover process holding a port.
free_port() {
  local port="$1"
  local pid
  pid=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    warn "port :$port held by pid $pid — killing"
    kill "$pid" 2>/dev/null || true
    sleep 0.4
  fi
}

# Build the daemon iff binary is missing or older than its sources.
build_daemon_if_needed() {
  local need_build=0
  if [ ! -x "$DAEMON_BIN" ]; then
    need_build=1
  else
    if [ -n "$(find "$REPO_ROOT/crates/agentkeys-daemon" -name '*.rs' -newer "$DAEMON_BIN" -print -quit 2>/dev/null)" ]; then
      need_build=1
    fi
  fi
  if [ "$need_build" = "1" ]; then
    say "building agentkeys-daemon (debug)…"
    ( cd "$REPO_ROOT" && cargo build -p agentkeys-daemon ) \
      || { err "cargo build -p agentkeys-daemon failed"; exit 1; }
  else
    printf "%b[dev]%b %sdaemon binary is current — skipping build%b\n" "$C_INFO" "$C_RESET" "$C_DIM" "$C_RESET"
  fi
}

DAEMON_PID=""
UI_PID=""

cleanup() {
  trap - INT TERM EXIT
  printf "\n"
  say "shutting down…"
  if [ -n "$UI_PID" ] && kill -0 "$UI_PID" 2>/dev/null; then
    kill "$UI_PID" 2>/dev/null || true
  fi
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
  say "stopped."
}
trap cleanup INT TERM EXIT

# ─── Preflight ─────────────────────────────────────────────────────
free_port "$UI_PORT"
free_port "$DAEMON_PORT"
build_daemon_if_needed

# ─── Start daemon ──────────────────────────────────────────────────
say "starting daemon on http://${DAEMON_BIND} (rp_id=${DAEMON_RP_ID})"
"$DAEMON_BIN" --ui-bridge \
  --ui-bridge-bind   "$DAEMON_BIND" \
  --ui-bridge-origin "$DAEMON_ORIGIN" \
  --ui-bridge-rp-id  "$DAEMON_RP_ID" \
  --ui-bridge-rp-name "$DAEMON_RP_NAME" \
  2>&1 | prefix "$C_DAEMON" "daemon" &
DAEMON_PID=$!

# Wait for /healthz (up to ~5 s).
say "waiting for daemon /healthz…"
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sSf "http://${DAEMON_BIND}/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    err "daemon exited before becoming ready — see [daemon] log above"
    exit 1
  fi
done
if [ "$ready" = "0" ]; then
  err "daemon did not respond on /healthz within 5 s"
  exit 1
fi
say "daemon ready."

# ─── Start Next.js dev server ──────────────────────────────────────
say "starting Next.js dev server on http://localhost:${UI_PORT}"
say "  NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon"
say "  NEXT_PUBLIC_AGENTKEYS_DAEMON_URL=http://${DAEMON_BIND}"
(
  cd "$APP_DIR"
  NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon \
  NEXT_PUBLIC_AGENTKEYS_DAEMON_URL="http://${DAEMON_BIND}" \
    npx next dev -p "$UI_PORT" 2>&1
) | prefix "$C_UI" "ui" &
UI_PID=$!

say "both processes running. Ctrl-C to stop."
say "  UI:     http://localhost:${UI_PORT}"
say "  daemon: http://${DAEMON_BIND}"

# Wait until either child exits, then cleanup() trap handles the rest.
# `wait -n` is bash 4.3+; macOS default /bin/bash is 3.2. Poll instead.
while kill -0 "$DAEMON_PID" 2>/dev/null && kill -0 "$UI_PID" 2>/dev/null; do
  sleep 1
done
warn "one of the children exited — shutting down the other"
