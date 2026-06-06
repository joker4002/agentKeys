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
#   [mcp]     green    — agentkeys-mcp-server           (port 18088)
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
#   MCP_PORT          default 18088  (8088 collides with the sandbox gem-server, per #141)
#   DAEMON_ORIGIN     default http://localhost:${UI_PORT}
#   DAEMON_RP_ID      default localhost
#   DAEMON_RP_NAME    default AgentKeys
#   (the MCP server always uses the real HTTP backend — broker + workers; the
#    in-memory fixture backend was removed. dev.sh points it at the same real
#    broker / memory / audit URLs it resolves for the daemon.)
#
# Requirements: cargo, npx (node), lsof, curl. Bash 3.2+ (works with
# macOS default /bin/bash).

set -euo pipefail
# Disable job-control monitor mode so bash doesn't print "Terminated: 15"
# notifications for the background children we SIGTERM during cleanup.
set +m

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
MCP_PORT="${MCP_PORT:-18088}"   # 18088 per #141 — 8088 collides with the sandbox's built-in gem-server
DAEMON_BIND="127.0.0.1:${DAEMON_PORT}"
MCP_BIND="127.0.0.1:${MCP_PORT}"
DAEMON_ORIGIN="${DAEMON_ORIGIN:-http://localhost:${UI_PORT}}"
DAEMON_RP_ID="${DAEMON_RP_ID:-localhost}"
DAEMON_RP_NAME="${DAEMON_RP_NAME:-AgentKeys}"

DAEMON_BIN="$REPO_ROOT/target/debug/agentkeys-daemon"
MCP_BIN="$REPO_ROOT/target/debug/agentkeys-mcp-server"

# ─── Real on-chain + S3 wiring (the onboarding ceremony must NOT be deferred, and
# the memory plant must hit the real worker) ──────────────────────────────────────
# Source the operator env so BOTH the daemon and the register script it shells out
# to inherit the chain RPC + contract addresses + bucket/role ARNs + deployer key
# path. Absent file ⇒ the chain steps surface a clear chain_error, never a silent skip.
AGENTKEYS_ENV_FILE="${AGENTKEYS_ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
if [ -f "$AGENTKEYS_ENV_FILE" ]; then
  set -a; . "$AGENTKEYS_ENV_FILE"; set +a
fi
# Onboarding register: ALWAYS wired (the daemon skips on-chain register ONLY when this
# is unset → "chain: none"). The script is in-repo; a missing deployer key / chain
# config surfaces chain_error (fund + retry), not a silent defer.
DAEMON_REGISTER_SCRIPT="${AGENTKEYS_REGISTER_MASTER_SCRIPT:-$REPO_ROOT/harness/scripts/heima-register-first-master.sh}"
# Real memory plant (button → cap-mint → STS → worker → S3). The daemon reads the worker
# URL from AGENTKEYS_MEMORY_URL; operator-workstation.env spells it AGENTKEYS_WORKER_MEMORY_URL
# (name drift — bridge here, pass via the flag). MEMORY_ROLE_ARN + REGION names already match.
DAEMON_MEMORY_URL="${AGENTKEYS_MEMORY_URL:-${AGENTKEYS_WORKER_MEMORY_URL:-${MEMORY_WORKER_URL:-}}}"
DAEMON_MEMORY_ROLE="${MEMORY_ROLE_ARN:-}"
DAEMON_REGION="${REGION:-us-east-1}"

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
# actually free before returning.
#
# `lsof -ti` can return MULTIPLE pids on separate lines for a single
# port — e.g. when a process listens on both IPv4 and IPv6, or when a
# parent has a child sharing the socket. The body iterates over each
# pid individually; a single bare `kill "$pid"` with a multiline
# variable would fail silently and leave the port occupied (exactly
# the bug the operator hit).
#
# Idempotent: re-running dev.sh after a hard kill / lost terminal
# cleans up the previous run's stragglers and starts fresh.
free_port() {
  local port="$1"
  local pass
  for pass in 1 2; do
    local pids
    pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
    if [ -z "$pids" ]; then return 0; fi

    local pid
    for pid in $pids; do
      warn "port :$port held by pid $pid — sending SIGTERM (pass $pass)"
      kill "$pid" 2>/dev/null || true
    done

    # Wait up to 3 s for all of them to exit.
    local waited=0
    while [ "$waited" -lt 6 ]; do
      sleep 0.5
      waited=$((waited + 1))
      local still=0
      for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then still=1; break; fi
      done
      [ "$still" = "0" ] && break
    done

    # SIGKILL anything still alive.
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        warn "pid $pid still alive after 3 s — sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
      fi
    done
    sleep 0.5

    # Loop will re-check on next pass. Stops once lsof returns nothing
    # at the top of the loop.
  done

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
    # NB: $C_DIM contains escape sequences in single-quoted form, so it
    # MUST go through %b (not %s) to be interpreted. The literal label
    # string after it goes through %s.
    printf "%b[dev]%b %b%s binary is current — skipping build%b\n" \
      "$C_INFO" "$C_RESET" "$C_DIM" "$label" "$C_RESET"
  fi
}

DAEMON_PID=""
MCP_PID=""
UI_PID=""

# Per-run temp dir for the FIFOs that carry each process's stdout into
# its prefix reader. Using FIFOs (not bash process substitution) so
# that the script itself never holds an fd to the writer end — killing
# the binary cleanly closes the FIFO, the prefix reader sees EOF, and
# `wait` returns. Process substitution leaves the fd open in the
# parent shell, which made Ctrl-C hang indefinitely.
RUN_TMPDIR="${TMPDIR:-/tmp}/agentkeys-dev-stack-$$"
mkdir -p "$RUN_TMPDIR"
FIFO_DAEMON="$RUN_TMPDIR/daemon.fifo"
FIFO_MCP="$RUN_TMPDIR/mcp.fifo"
FIFO_UI="$RUN_TMPDIR/ui.fifo"
mkfifo "$FIFO_DAEMON" "$FIFO_MCP" "$FIFO_UI"

PREFIX_DAEMON_PID=""
PREFIX_MCP_PID=""
PREFIX_UI_PID=""

cleanup() {
  trap - INT TERM EXIT
  printf "\n"
  say "shutting down…"
  # SIGTERM the actual binaries first — their FIFO writes will close
  # and the prefix readers see EOF naturally.
  local p
  for p in "$UI_PID" "$MCP_PID" "$DAEMON_PID"; do
    [ -z "$p" ] && continue
    if kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
    fi
  done
  # Poll for all of them (including prefix readers) to actually exit.
  # We use polling instead of `wait` so bash doesn't print "Terminated:
  # 15" job-control notifications during shutdown — combined with the
  # disowns after each spawn, the shutdown is now silent except for
  # our own [dev] lines.
  local waited=0
  while [ "$waited" -lt 16 ]; do
    sleep 0.25
    waited=$((waited + 1))
    local still=0
    for p in "$UI_PID" "$MCP_PID" "$DAEMON_PID" "$PREFIX_UI_PID" "$PREFIX_MCP_PID" "$PREFIX_DAEMON_PID"; do
      [ -z "$p" ] && continue
      kill -0 "$p" 2>/dev/null && { still=1; break; }
    done
    [ "$still" = "0" ] && break
  done
  # SIGKILL anything still alive.
  for p in "$UI_PID" "$MCP_PID" "$DAEMON_PID" "$PREFIX_UI_PID" "$PREFIX_MCP_PID" "$PREFIX_DAEMON_PID"; do
    [ -z "$p" ] && continue
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
  done
  rm -rf "$RUN_TMPDIR"
  say "stopped."
  # Exit immediately so we don't fall through to the polling loop's
  # post-loop "one of the children exited" warning, which would be
  # misleading after a clean operator-initiated shutdown.
  exit 0
}
trap cleanup INT TERM EXIT

# Build the WASM master-plane core (agentkeys-web-core → apps/parent-control via
# wasm-pack) iff the Rust source / Cargo.toml / wasm-pack version changed since
# the last build. Cached via a src-hash stamp in the (gitignored) out dir; the
# generated pkg + served .wasm are never committed. Graceful no-op if wasm-pack
# isn't installed (the UI then runs with the daemon/empty backend; only the
# `core` backend needs the WASM module).
build_wasm() {
  local crate_dir="$REPO_ROOT/crates/agentkeys-web-core"
  local out_dir="$REPO_ROOT/apps/parent-control/lib/wasm/agentkeys-web-core"
  local pub_dir="$REPO_ROOT/apps/parent-control/public/wasm"
  local stamp="$out_dir/.src-hash"

  if ! command -v wasm-pack >/dev/null 2>&1; then
    warn "wasm-pack not installed — skipping WASM core (cargo install wasm-pack && rustup target add wasm32-unknown-unknown). 'core' backend unavailable; UI uses daemon/empty."
    return 0
  fi

  # Version key: every .rs under src/ (sorted, so the filesystem walk order can't
  # change the hash) + this crate's Cargo.toml + the workspace Cargo.toml &
  # Cargo.lock (so a transitive-dep bump busts the cache) + the rustc & wasm-pack
  # versions. Any change ⇒ rebuild; otherwise reuse the cached pkg.
  local cur
  cur="$( { find "$crate_dir/src" -type f -name '*.rs' -exec shasum -a 256 {} + | sort;
            shasum -a 256 "$crate_dir/Cargo.toml" "$REPO_ROOT/Cargo.toml" "$REPO_ROOT/Cargo.lock";
            rustc -Vv; wasm-pack --version; } | shasum -a 256 | awk '{print $1}' )"

  if [ -f "$out_dir/agentkeys_web_core_bg.wasm" ] && [ -f "$pub_dir/agentkeys_web_core_bg.wasm" ] \
     && [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$cur" ]; then
    printf "%b[dev]%b WASM core up-to-date (%s…) — skip build\n" "$C_DIM" "$C_RESET" "${cur:0:12}"
    return 0
  fi

  rustup target list --installed 2>/dev/null | grep -q wasm32-unknown-unknown \
    || rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
  say "building WASM core (agentkeys-web-core → lib/wasm)…"
  ( cd "$REPO_ROOT" && wasm-pack build crates/agentkeys-web-core --dev --target web \
      --out-dir "$out_dir" -- --features wasm ) \
    || { err "wasm-pack build failed"; exit 1; }
  mkdir -p "$pub_dir"
  cp "$out_dir/agentkeys_web_core_bg.wasm" "$pub_dir/agentkeys_web_core_bg.wasm"
  printf '%s' "$cur" > "$stamp"
  say "WASM core built + cached (${cur:0:12}…)."
}

# ─── Preflight ─────────────────────────────────────────────────────
free_port "$UI_PORT"
free_port "$DAEMON_PORT"
free_port "$MCP_PORT"
build_if_needed "$DAEMON_BIN" "agentkeys-daemon" "agentkeys-daemon" \
  "$REPO_ROOT/crates/agentkeys-daemon"
build_if_needed "$MCP_BIN" "agentkeys-mcp-server" "agentkeys-mcp-server" \
  "$REPO_ROOT/crates/agentkeys-mcp" "$REPO_ROOT/crates/agentkeys-mcp-server"
build_wasm

# ─── Start daemon ──────────────────────────────────────────────────
#
# Pattern for all three processes: spawn the prefix reader FIRST on
# the FIFO (so it's blocking on read when the writer opens), then
# spawn the binary with stdout/stderr redirected to the FIFO. $! is
# now the real binary's pid — clean Ctrl-C kill semantics.
say "starting daemon on http://${DAEMON_BIND} (rp_id=${DAEMON_RP_ID})"
prefix "$C_DAEMON" "daemon" < "$FIFO_DAEMON" &
PREFIX_DAEMON_PID=$!
disown "$PREFIX_DAEMON_PID" 2>/dev/null || true
# Broker for the W1 onboarding email→verify flow (the real magic-link). Override
# with AGENTKEYS_BROKER_URL=…; defaults to prod so onboarding works out of the box.
DAEMON_BROKER_URL="${AGENTKEYS_BROKER_URL:-https://broker.litentry.org}"
say "  daemon onboarding broker: ${DAEMON_BROKER_URL}"
# --register-master-script is ALWAYS passed so the on-chain ceremony is never silently
# deferred; the memory flags only when the operator env supplies them (else the daemon's
# in-memory fallback, logged below).
DAEMON_ARGS=(
  --ui-bridge
  --ui-bridge-bind    "$DAEMON_BIND"
  --ui-bridge-origin  "$DAEMON_ORIGIN"
  --ui-bridge-rp-id   "$DAEMON_RP_ID"
  --ui-bridge-rp-name "$DAEMON_RP_NAME"
  --broker-url        "$DAEMON_BROKER_URL"
  --signer-url        "${AGENTKEYS_SIGNER_URL:-https://signer.litentry.org}"
  --register-master-script "$DAEMON_REGISTER_SCRIPT"
  --region            "$DAEMON_REGION"
)
if [ -n "$DAEMON_MEMORY_URL" ];  then DAEMON_ARGS+=( --memory-url "$DAEMON_MEMORY_URL" ); fi
if [ -n "$DAEMON_MEMORY_ROLE" ]; then DAEMON_ARGS+=( --memory-role-arn "$DAEMON_MEMORY_ROLE" ); fi
say "  daemon onboarding register: on-chain (not deferred) → $DAEMON_REGISTER_SCRIPT"
if [ -n "$DAEMON_MEMORY_URL" ] && [ -n "$DAEMON_MEMORY_ROLE" ]; then
  say "  daemon memory plant: REAL → $DAEMON_MEMORY_URL"
else
  say "  daemon memory plant: in-memory fallback (set AGENTKEYS_WORKER_MEMORY_URL + MEMORY_ROLE_ARN in $AGENTKEYS_ENV_FILE for real S3)"
fi
"$DAEMON_BIN" "${DAEMON_ARGS[@]}" > "$FIFO_DAEMON" 2>&1 &
DAEMON_PID=$!
disown "$DAEMON_PID" 2>/dev/null || true

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
# The MCP server always uses the real HTTP backend (broker cap-mint → per-actor
# STS → worker → S3); the in-memory fixture backend was removed (real-data-only).
# Point it at the same real broker / memory / audit URLs the daemon uses. Agent
# tool calls need a paired agent session (--agent-session-bearer), absent in this
# web dev loop — so manual pokes get honest auth errors, never fake fixture data.
MCP_AUDIT_URL="${AGENTKEYS_WORKER_AUDIT_URL:-${AGENTKEYS_AUDIT_URL:-}}"
say "starting mcp-server on http://${MCP_BIND} (backend=http → ${DAEMON_BROKER_URL})"
prefix "$C_MCP" "mcp" < "$FIFO_MCP" &
PREFIX_MCP_PID=$!
disown "$PREFIX_MCP_PID" 2>/dev/null || true
MCP_ARGS=( --backend http --listen "$MCP_BIND" --broker-url "$DAEMON_BROKER_URL" --region "$DAEMON_REGION" )
[ -n "$DAEMON_MEMORY_URL" ] && MCP_ARGS+=( --memory-url "$DAEMON_MEMORY_URL" )
[ -n "$MCP_AUDIT_URL" ]     && MCP_ARGS+=( --audit-url "$MCP_AUDIT_URL" )
"$MCP_BIN" "${MCP_ARGS[@]}" \
  > "$FIFO_MCP" 2>&1 &
MCP_PID=$!
disown "$MCP_PID" 2>/dev/null || true

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

# ─── Ensure frontend deps (fresh clone / git worktree has no node_modules) ─────
# node_modules is gitignored, so a fresh clone OR a git worktree (e.g.
# .claude/worktrees/*) starts with none. Without it `npx next dev` can't resolve
# `next` and Next.js 16/Turbopack fails with a confusing "inferred your workspace
# root … couldn't find next/package.json" error. Install once here — idempotent:
# skips when `next` is already present (mirrors how this script ensures the Rust
# binaries + WASM core, so `dev.sh` is genuinely one-command on a fresh checkout).
if [ ! -d "$APP_DIR/node_modules/next" ]; then
  say "installing frontend deps in apps/parent-control (no node_modules — fresh clone / worktree)…"
  if [ -f "$APP_DIR/package-lock.json" ] && ( cd "$APP_DIR" && npm ci ); then
    :
  elif ( cd "$APP_DIR" && npm install ); then
    :
  else
    err "npm install in $APP_DIR failed — run it manually: (cd apps/parent-control && npm install)"
    exit 1
  fi
  say "frontend deps installed."
else
  say "frontend deps present — skipping npm install."
fi

# ─── Start Next.js dev server ──────────────────────────────────────
#
# The subshell `exec`s into npx so $! points at the npx process itself
# (not the subshell). Output flows through the FIFO into the prefix
# reader spawned just above.
say "starting Next.js dev server on http://localhost:${UI_PORT}"
say "  NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon"
say "  NEXT_PUBLIC_AGENTKEYS_DAEMON_URL=http://${DAEMON_BIND}"
say "  NEXT_PUBLIC_AGENTKEYS_MCP_URL=http://${MCP_BIND}"
prefix "$C_UI" "ui" < "$FIFO_UI" &
PREFIX_UI_PID=$!
disown "$PREFIX_UI_PID" 2>/dev/null || true
(
  cd "$APP_DIR" && \
  NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon \
  NEXT_PUBLIC_AGENTKEYS_DAEMON_URL="http://${DAEMON_BIND}" \
  NEXT_PUBLIC_AGENTKEYS_MCP_URL="http://${MCP_BIND}" \
    exec npx next dev -p "$UI_PORT"
) > "$FIFO_UI" 2>&1 &
UI_PID=$!
disown "$UI_PID" 2>/dev/null || true

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
