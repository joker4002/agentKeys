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
#
# Idempotent: every run is a cargo no-op when nothing changed. Re-run safely.
#
# Unit-level only — these are the REAL storage code paths exercised in-process,
# NOT an end-to-end S3 proof. (The in-memory MCP live-roundtrip step was removed
# with the in-memory backend — real-data-only.) For the authoritative real-worker
# proof (broker cap-mint → per-actor STS → memory.litentry.org → S3), run:
#     bash harness/phase1-wire-demo.sh --real
#
# Usage: bash harness/storage-test.sh [--release] [--no-build]
#   --release       build + test in release profile (default: debug, faster)
#   --no-build      skip the build step (use existing binaries)
#
# Env overrides (no hardcoded values — all have sane defaults):
#   CARGO_TARGET_DIR / CARGO_HOME          build cache locations

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
for arg in "$@"; do
  case "$arg" in
    --release)     PROFILE="release"; CARGO_PROFILE_FLAG="--release" ;;
    --no-build)    DO_BUILD=0 ;;
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

ok "cache" "CARGO_TARGET_DIR=$CARGO_TARGET_DIR"
ok "env" "profile=$PROFILE"

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

# ─── summary ─────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 0 ]]; then
  log "ALL GREEN — storage code paths verified (build · suites)"
  exit 0
else
  log "$FAILED FAILURE(S) — see above"
  exit 1
fi
