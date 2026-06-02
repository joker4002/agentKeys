#!/usr/bin/env bash
# harness/storage-test.sh — idempotent, self-contained test of the AgentKeys
# memory STORAGE solution.
#
# What it proves, from a FRESH checkout, with NO external infra (no AWS, no
# chain, no broker, no network):
#   1. env + cache    — resolves the cargo build cache; sanitizes broker env.
#   2. prereqs        — cargo / jq / curl present (fails loud with install hints).
#   3. build          — builds the CLI + MCP server (cargo cache → fast re-runs).
#   4. test suites    — runs the REAL storage code paths: envelope crypto
#                       (encrypt-at-rest), per-actor S3 key derivation,
#                       namespace isolation (#147), and the pluggable engine.
#   5. live roundtrip — starts an in-process MCP server (in-memory backend) and
#                       drives put → get → inject end-to-end, plus an engine
#                       selection check (lexical + budget).
#
# Idempotent: every run is a cargo no-op when nothing changed; the MCP server
# is killed + restarted fresh (ephemeral state) each run. Re-run safely.
#
# NOT a real-S3 proof. The in-memory backend exercises the put/get/engine
# PLUMBING without AWS. For the authoritative real-worker proof (broker cap-mint
# → per-actor STS → memory.litentry.org → S3), run:
#     bash harness/phase1-wire-demo.sh --real
#
# Usage: bash harness/storage-test.sh [--release] [--no-build] [--keep-server]
#   --release       build + test in release profile (default: debug, faster)
#   --no-build      skip the build step (use existing binaries)
#   --keep-server   leave the MCP server running after exit (for manual poking)
#
# Env overrides (no hardcoded values — all have sane defaults):
#   CARGO_TARGET_DIR / CARGO_HOME          build cache locations
#   STORAGE_TEST_PORT (18099)              MCP listen port
#   STORAGE_TEST_ACTOR / _OPERATOR / _DEVICE   demo identities (mirror
#                                          crates/agentkeys-mcp-server/src/backend/in_memory.rs)
#   STORAGE_TEST_VENDOR (magiclick) / _TOKEN (demo-tok)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# ─── output (CLAUDE.md ok/skip/fail convention) ──────────────────────────────
log()  { printf '\n[storage-test] %s\n' "$*"; }
ok()   { printf '  %-28s ok proceeding (%s)\n' "$1" "$2"; }
skip() { printf '  %-28s skip %s\n' "$1" "$2"; }
fail() { printf '  %-28s FAIL %s\n' "$1" "$2" >&2; FAILED=$((FAILED + 1)); }
FAILED=0

# ─── flags ───────────────────────────────────────────────────────────────────
PROFILE="debug"
CARGO_PROFILE_FLAG=""
DO_BUILD=1
KEEP_SERVER=0
for arg in "$@"; do
  case "$arg" in
    --release)     PROFILE="release"; CARGO_PROFILE_FLAG="--release" ;;
    --no-build)    DO_BUILD=0 ;;
    --keep-server) KEEP_SERVER=1 ;;
    -h|--help)     grep '^#' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *)             echo "unknown arg: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ─── step 0 — env + cache ────────────────────────────────────────────────────
log "step 0 — env + cache"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
# Sanitize broker env so the storage tests can NEVER reach a live broker — the
# AGENTKEYS_BROKER_URL leak that otherwise makes provision tests hit prod.
unset AGENTKEYS_BROKER_URL AGENTKEYS_DATA_ROLE_ARN 2>/dev/null || true

ACTOR="${STORAGE_TEST_ACTOR:-0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7}"
OPERATOR="${STORAGE_TEST_OPERATOR:-0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8}"
DEVICE="${STORAGE_TEST_DEVICE:-0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef}"
PORT="${STORAGE_TEST_PORT:-18099}"
VENDOR="${STORAGE_TEST_VENDOR:-magiclick}"
TOKEN="${STORAGE_TEST_TOKEN:-demo-tok}"
MCP_URL="http://127.0.0.1:$PORT/mcp"
ok "cache" "CARGO_TARGET_DIR=$CARGO_TARGET_DIR"
ok "env" "profile=$PROFILE port=$PORT actor=${ACTOR:0:12}…"

# ─── step 1 — prereqs ────────────────────────────────────────────────────────
log "step 1 — prereqs"
have() { command -v "$1" >/dev/null 2>&1; }
if have cargo; then ok "cargo" "$(cargo --version 2>/dev/null | cut -d' ' -f1-2)"; else fail "cargo" "not found — install rust via https://rustup.rs"; fi
if have jq;    then ok "jq" "present"; else fail "jq" "not found — brew install jq / apt-get install jq"; fi
if have curl;  then ok "curl" "present"; else fail "curl" "not found"; fi
if [[ $FAILED -gt 0 ]]; then log "prereqs missing — aborting ($FAILED)"; exit 1; fi

# ─── step 2 — build (cached) ─────────────────────────────────────────────────
BIN_DIR="$CARGO_TARGET_DIR/$PROFILE"
AGENTKEYS_BIN="$BIN_DIR/agentkeys"
MCP_BIN="$BIN_DIR/agentkeys-mcp-server"
if [[ "$DO_BUILD" == 1 ]]; then
  log "step 2 — build (cargo cache → fast re-runs)"
  build_out="$(cargo build $CARGO_PROFILE_FLAG -p agentkeys-cli -p agentkeys-mcp-server 2>&1)"
  build_rc=$?
  if [[ $build_rc -ne 0 ]]; then
    echo "$build_out" | tail -25 >&2
    fail "build" "cargo build failed (rc=$build_rc)"
    log "summary: $FAILED failure(s)"; exit 1
  fi
  if echo "$build_out" | grep -q "Compiling"; then ok "build" "compiled — cache updated"; else ok "build" "up to date — cache hit (no rebuild)"; fi
else
  log "step 2 — build skipped (--no-build)"
fi
[[ -x "$AGENTKEYS_BIN" ]] || { fail "build" "missing binary $AGENTKEYS_BIN (drop --no-build)"; log "summary: $FAILED failure(s)"; exit 1; }
[[ -x "$MCP_BIN" ]]       || { fail "build" "missing binary $MCP_BIN (drop --no-build)"; log "summary: $FAILED failure(s)"; exit 1; }

# ─── step 3 — storage test suites (real code paths) ──────────────────────────
log "step 3 — storage test suites (envelope crypto · per-actor key · namespace isolation · engine)"
run_suite() {
  local crate="$1"; shift
  local out rc passed failed
  out="$(cargo test $CARGO_PROFILE_FLAG -p "$crate" "$@" 2>&1)"; rc=$?
  passed="$(echo "$out" | grep -oE '[0-9]+ passed' | awk '{s+=$1} END{print s+0}')"
  failed="$(echo "$out" | grep -oE '[0-9]+ failed' | awk '{s+=$1} END{print s+0}')"
  if [[ $rc -eq 0 ]]; then ok "test:$crate" "$passed passed"; else echo "$out" | tail -30 >&2; fail "test:$crate" "$failed failed (rc=$rc)"; fi
}
run_suite agentkeys-core              # envelope (AES-256-GCM, AAD), s3_backend, memory_engine
run_suite agentkeys-worker-memory     # s3_key derivation, memory/credentials prefix split, namespace segregation (#147)
run_suite agentkeys-mcp-server        # memory.put / memory.get tools
run_suite agentkeys-cli --lib         # engine wiring: wire-bake + hook (--lib skips env-dependent provision integration tests)

# ─── step 4 — live storage roundtrip (in-memory backend) ─────────────────────
log "step 4 — live roundtrip: put → get → inject → engine-select (in-memory MCP; no AWS/chain/broker)"
# idempotent: clear any prior storage-test server on this port, then start fresh
pkill -f "agentkeys-mcp-server.*--listen 127.0.0.1:$PORT" 2>/dev/null || true
sleep 0.3
SERVER_LOG="$(mktemp -t storage-test-mcp.XXXXXX 2>/dev/null || echo /tmp/storage-test-mcp.$$.log)"
"$MCP_BIN" --backend in-memory --transport http --listen "127.0.0.1:$PORT" \
  --vendor-tokens "$VENDOR:$TOKEN" \
  --default-actor "$ACTOR" --default-operator-omni "$OPERATOR" --default-device-key-hash "$DEVICE" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
cleanup() { if [[ "$KEEP_SERVER" != 1 && -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT

healthy=0
for _ in $(seq 1 50); do
  if curl -fsS -m 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 0.2
done
if [[ "$healthy" != 1 ]]; then
  echo "--- mcp server log ---" >&2; tail -20 "$SERVER_LOG" >&2
  fail "4.0 mcp up" "server not healthy on :$PORT"
  log "summary: $FAILED failure(s)"; exit 1
fi
ok "4.0 mcp up" "in-memory MCP on :$PORT (pid $SERVER_PID)"

export AGENTKEYS_MCP_URL="$MCP_URL"
export AGENTKEYS_MCP_VENDOR_TOKEN="$TOKEN"
export AGENTKEYS_ACTOR_OMNI="$ACTOR"
export AGENTKEYS_OPERATOR_OMNI="$OPERATOR"

# 4.1 READ a pre-seeded namespace (proves read from storage)
seeded="$("$AGENTKEYS_BIN" hook memory-inject --namespaces travel </dev/null 2>/dev/null | jq -r '.context // ""')"
if echo "$seeded" | grep -q "Chengdu"; then ok "4.1 read seeded" "travel → $(echo "$seeded" | tr '\n' ' ' | cut -c1-40)…"; else fail "4.1 read seeded" "expected 'Chengdu', got: $(echo "$seeded" | cut -c1-80)"; fi

# 4.2 WRITE a fresh multi-line namespace (proves write to storage)
NS="storagetest"
MARKER="roundtrip-$$"
CONTENT=$'Booked Chengdu flight CA4515 on Apr 12.\nPeanut allergy noted for inflight meals.\nHotel in Yulin district near hotpot street.\nMarker '"$MARKER"
put_out="$("$AGENTKEYS_BIN" memory put --namespace "$NS" --content "$CONTENT" 2>&1)"
if echo "$put_out" | grep -q "s3_key"; then ok "4.2 put" "wrote 4-line '$NS'"; else fail "4.2 put" "$(echo "$put_out" | tr '\n' ' ' | cut -c1-140)"; fi

# 4.3 READ-BACK via inject, default passthrough engine (proves the round trip)
got="$("$AGENTKEYS_BIN" hook memory-inject --namespaces "$NS" </dev/null 2>/dev/null | jq -r '.context // ""')"
got_body_lines="$(echo "$got" | grep -vc '^## Memory:')"
if echo "$got" | grep -q "$MARKER"; then ok "4.3 get roundtrip" "read back marker; $got_body_lines body lines (passthrough = all)"; else fail "4.3 get roundtrip" "marker '$MARKER' missing: $(echo "$got" | tr '\n' ' ' | cut -c1-100)"; fi

# 4.4 ENGINE selection over storage: lexical + max_lines=1 → exactly 1 body line
sel="$(AGENTKEYS_MEMORY_ENGINE=lexical AGENTKEYS_MEMORY_MAX_LINES=1 "$AGENTKEYS_BIN" hook memory-inject --namespaces "$NS" </dev/null 2>/dev/null | jq -r '.context // ""')"
sel_body="$(echo "$sel" | grep -v '^## Memory:')"
sel_lines="$(echo "$sel_body" | grep -c .)"
if [[ "$sel_lines" == 1 ]]; then ok "4.4 engine select" "lexical/max_lines=1 → 1 of $got_body_lines lines: $(echo "$sel_body" | cut -c1-44)"; else fail "4.4 engine select" "expected 1 body line, got $sel_lines: $(echo "$sel_body" | tr '\n' ' ' | cut -c1-80)"; fi

# ─── summary ─────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 0 ]]; then
  log "ALL GREEN — storage solution verified (build · suites · roundtrip · engine)"
  exit 0
else
  log "$FAILED FAILURE(S) — see above"
  exit 1
fi
