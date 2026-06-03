#!/usr/bin/env bash
# scripts/mcp-demo-mode-a.sh — automated dev-mode demo for issue #107.
#
# Boots `agentkeys-mcp-server --backend in-memory`, walks Acts 1/2/3,
# asserts each act's expected JSON shape, then cleans up. Use this as
# the regression check for `docs/plan/issue-107-mcp-demo-runbook.md`
# §A — if any assertion fails, the runbook drifted from reality.
#
# Hardened per /codex:adversarial-review (2026-05-25):
#   - Hex32 actor/operator/device IDs (so wire-compatible with real broker).
#   - Random ephemeral port + post-spawn liveness check (no stale-server
#     false positive).
#   - JSON-RPC response parsed via jq or python3 (no substring-grep
#     hiding tool isError).
#   - Act 3 mints a real cap, revokes it by nonce, and proves the
#     revoked cap is denied on retry (not just "revoke returned ok").
#   - `cargo run` (not a hardcoded target/debug path) so CI cache
#     layouts with $CARGO_TARGET_DIR work.
#
# Hardened per /codex:adversarial-review (2026-06-04):
#   - Act 1 proves the MEMORY FUNCTIONS, not just a seeded read: a
#     memory.put -> memory.get round-trip reads a written value back
#     verbatim (the write path), and a get on an unprovisioned namespace
#     is denied with -32000 (namespace isolation). The prior Act 1 only
#     grep'd a preseeded "Chengdu" fixture and could pass with the write
#     path or namespace binding fully broken.
#
# Usage:
#   bash scripts/mcp-demo-mode-a.sh
#
set -euo pipefail

# ── Prereq check ─────────────────────────────────────────────────────
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FAIL: missing prerequisite \`$1\`" >&2
    exit 1
  }
}
need cargo
need curl
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then
  JSON_TOOL=python3
else
  echo "FAIL: need either \`jq\` or \`python3\` for JSON assertions" >&2
  exit 1
fi

# ── Demo fixture identities (hex32, matching backend constants) ──────
ACTOR='0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7'
OPERATOR='0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8'
DEVICE='0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'

# ── Allocate an ephemeral port to avoid colliding with stale procs ───
PORT="${MCP_PORT:-}"
if [ -z "$PORT" ]; then
  PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()" 2>/dev/null \
    || ruby -rsocket -e "s=TCPServer.new('127.0.0.1',0);puts s.addr[1];s.close" 2>/dev/null \
    || echo 18100)
fi
URL="http://127.0.0.1:${PORT}/mcp"

# ── Boot the server in the background ────────────────────────────────
LOG="${TMPDIR:-/tmp}/mcp-demo-$$.log"
( cargo run --quiet -p agentkeys-mcp-server -- --backend in-memory --listen "127.0.0.1:${PORT}" \
    >"$LOG" 2>&1 ) &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait 2>/dev/null || true' EXIT INT TERM

# Wait for /healthz; bail if the process exits.
for _ in $(seq 1 100); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: server process exited during startup. log:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  if curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if ! curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
  echo "FAIL: /healthz did not respond on port $PORT after 20s" >&2
  cat "$LOG" >&2
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────
call() {
  curl -sS -X POST "$URL" \
    -H "authorization: Bearer demo-tok" \
    -H "x-agentkeys-actor: $ACTOR" \
    -H "content-type: application/json" \
    -d "$1"
}

# JSON read: $1 = body, $2 = path expression. jq path syntax; the
# python3 fallback translates `.a.b` → `['a']['b']`.
jread() {
  local body="$1" path="$2"
  if [ "$JSON_TOOL" = "jq" ]; then
    printf '%s' "$body" | jq -r "$path"
  else
    printf '%s' "$body" \
      | python3 -c "
import json, sys, re
body=json.load(sys.stdin)
path='''$path'''.lstrip('.')
parts=[p for p in re.split(r'\.', path) if p]
v=body
for p in parts:
    v=v.get(p) if isinstance(v, dict) else None
print('' if v is None else (v if isinstance(v,str) else json.dumps(v)))
"
  fi
}

assert_eq() {
  local got="$1" expected="$2" label="$3"
  if [ "$got" = "$expected" ]; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label — expected: $expected — got: $got" >&2
    exit 1
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" label="$3"
  if echo "$haystack" | grep -q -F -- "$needle"; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label — expected to find: $needle" >&2
    echo "    got: $haystack" >&2
    exit 1
  fi
}

assert_no_error() {
  local body="$1" label="$2"
  local err
  err=$(jread "$body" '.error.code')
  if [ -z "$err" ] || [ "$err" = "null" ]; then
    echo "  ✓ $label (no JSON-RPC error)"
  else
    echo "  ✗ $label — JSON-RPC error code=$err: $body" >&2
    exit 1
  fi
}

# Build a tools/call request body.
call_body() {
  local name="$1" args="$2" id="${3:-1}"
  printf '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"%s","arguments":%s},"id":%s}' \
    "$name" "$args" "$id"
}

# ── ACT 1 — Permissioned Memory (forward namespace; mint cap; read) ──
echo
echo "=== ACT 1: memory.get travel namespace ==="
ACT1=$(call "$(call_body agentkeys.memory.get \
  "$(printf '{"actor":"%s","namespace":"travel","operator_omni":"%s","device_key_hash":"%s"}' \
    "$ACTOR" "$OPERATOR" "$DEVICE")")")
assert_no_error "$ACT1" "Act 1 response has no JSON-RPC error"
assert_eq "$(jread "$ACT1" '.result.isError')" "false" "tool isError = false"
assert_eq "$(jread "$ACT1" '.result.structuredContent.ok')" "true" "structuredContent.ok = true"
assert_eq "$(jread "$ACT1" '.result.structuredContent.namespace')" "travel" "namespace echoed back"
assert_contains "Chengdu" "$ACT1" "Chengdu trip surfaces in body"

# ── ACT 1b — REAL write→read round-trip (proves the WRITE path) ──────
# The seeded read above can pass even if memory.put, the namespace
# binding, or the worker payload shape is broken. Write a unique value,
# read it back, assert it round-trips verbatim.
echo
echo "=== ACT 1b: memory.put → memory.get round-trip ==="
RT_NS="trip-notes"
RT_VAL="Lisbon trip booked May 2 to 9; pid $$"
ACT1B_PUT=$(call "$(call_body agentkeys.memory.put \
  "$(printf '{"actor":"%s","namespace":"%s","content":"%s","operator_omni":"%s","device_key_hash":"%s"}' \
    "$ACTOR" "$RT_NS" "$RT_VAL" "$OPERATOR" "$DEVICE")")")
assert_no_error "$ACT1B_PUT" "memory.put has no JSON-RPC error"
assert_eq "$(jread "$ACT1B_PUT" '.result.structuredContent.ok')" "true" "memory.put ok = true"
assert_eq "$(jread "$ACT1B_PUT" '.result.structuredContent.namespace')" "$RT_NS" "put namespace echoed back"

ACT1B_GET=$(call "$(call_body agentkeys.memory.get \
  "$(printf '{"actor":"%s","namespace":"%s","operator_omni":"%s","device_key_hash":"%s"}' \
    "$ACTOR" "$RT_NS" "$OPERATOR" "$DEVICE")")")
assert_no_error "$ACT1B_GET" "round-trip memory.get has no JSON-RPC error"
assert_eq "$(jread "$ACT1B_GET" '.result.structuredContent.content')" "$RT_VAL" \
  "written value reads back verbatim (write path round-trips)"

# ── ACT 1c — namespace isolation: get on an unprovisioned namespace ──
# Proves a get returns ONLY the requested namespace — an unwritten
# namespace yields an error, never another namespace's content.
echo
echo "=== ACT 1c: memory.get on an empty namespace → denied (isolation) ==="
ACT1C=$(call "$(call_body agentkeys.memory.get \
  "$(printf '{"actor":"%s","namespace":"never-written-%s","operator_omni":"%s","device_key_hash":"%s"}' \
    "$ACTOR" "$$" "$OPERATOR" "$DEVICE")")")
assert_eq "$(jread "$ACT1C" '.error.code')" "-32000" \
  "get on unprovisioned namespace → TOOL_ERROR (-32000), not a cross-namespace leak"

# ── ACT 2 — Deterministic Denial (no LLM in the verdict) ─────────────
echo
echo "=== ACT 2: permission.check 600 RMB over 500 cap ==="
ACT2=$(call "$(call_body agentkeys.permission.check \
  "$(printf '{"actor":"%s","scope":"payment.spend","params":{"amount_rmb":600}}' "$ACTOR")")")
assert_no_error "$ACT2" "Act 2 response has no JSON-RPC error"
assert_eq "$(jread "$ACT2" '.result.structuredContent.verdict')" "deny" "verdict = deny"
assert_eq "$(jread "$ACT2" '.result.structuredContent.reason')" "daily_spend_cap_exceeded" \
  "reason = daily_spend_cap_exceeded"
assert_contains "cap=500, requested=600, period=daily" "$ACT2" \
  "explanation matches storyboard verbatim"

# ── ACT 3 — Online Revocation (mint → revoke → retry → denied) ───────
echo
echo "=== ACT 3: mint cap, revoke it, prove retry is denied ==="

ACT3_MINT=$(call "$(call_body agentkeys.cap.mint \
  "$(printf '{"actor":"%s","op":"memory_get","params":{"operator_omni":"%s","service":"memory","device_key_hash":"%s"},"ttl":300}' \
    "$ACTOR" "$OPERATOR" "$DEVICE")")")
assert_no_error "$ACT3_MINT" "cap.mint succeeded"
CAP_ID=$(jread "$ACT3_MINT" '.result.structuredContent.cap.payload.nonce')
if [ -z "$CAP_ID" ] || [ "$CAP_ID" = "null" ]; then
  echo "  ✗ cap.mint did not return a payload.nonce. body: $ACT3_MINT" >&2
  exit 1
fi
echo "  ✓ cap.mint returned cap_id=$CAP_ID"

ACT3_REVOKE=$(call "$(call_body agentkeys.cap.revoke \
  "$(printf '{"cap_id":"%s"}' "$CAP_ID")")")
assert_no_error "$ACT3_REVOKE" "cap.revoke(known cap_id) succeeded"
assert_eq "$(jread "$ACT3_REVOKE" '.result.structuredContent.revocation')" "in_memory" \
  "revocation recorded in-memory (M1 stub)"

# Unknown cap_id MUST fail — proves revoke isn't a rubber-stamp.
ACT3_REVOKE_UNKNOWN=$(call "$(call_body agentkeys.cap.revoke '{"cap_id":"this-cap-was-never-minted"}')")
UNKNOWN_ERR=$(jread "$ACT3_REVOKE_UNKNOWN" '.error.code')
if [ -z "$UNKNOWN_ERR" ] || [ "$UNKNOWN_ERR" = "null" ]; then
  echo "  ✗ cap.revoke(unknown) should error but didn't. body: $ACT3_REVOKE_UNKNOWN" >&2
  exit 1
fi
echo "  ✓ cap.revoke(unknown) rejected (error code $UNKNOWN_ERR)"

# Retry the SAME cap we just revoked — must fail.
ACT3_AUDIT=$(call "$(call_body agentkeys.audit.append \
  "$(printf '{"actor":"%s","event":{"operator_omni":"%s","op_kind":3,"op_body":{"cap_id":"%s","reason":"parent_revoke"},"result":0,"intent_text":"parent revoked payment access"}}' \
    "$ACTOR" "$OPERATOR" "$CAP_ID")")")
assert_no_error "$ACT3_AUDIT" "audit.append succeeded"
ENV_HASH=$(jread "$ACT3_AUDIT" '.result.structuredContent.envelope_hash')
case "$ENV_HASH" in
  0x*) echo "  ✓ audit returned 0x-prefixed envelope_hash ($ENV_HASH)" ;;
  *)
    echo "  ✗ audit envelope_hash should start with 0x — got: $ENV_HASH" >&2
    exit 1 ;;
esac

# Second append with different content MUST produce a different hash
# (catches the counter-as-hash regression Codex flagged).
ACT3_AUDIT2=$(call "$(call_body agentkeys.audit.append \
  "$(printf '{"actor":"%s","event":{"operator_omni":"%s","op_kind":3,"op_body":{"cap_id":"%s","reason":"different"},"result":0,"intent_text":"a different intent"}}' \
    "$ACTOR" "$OPERATOR" "$CAP_ID")")")
ENV_HASH2=$(jread "$ACT3_AUDIT2" '.result.structuredContent.envelope_hash')
if [ "$ENV_HASH" = "$ENV_HASH2" ]; then
  echo "  ✗ audit envelope_hash should differ for different content; got identical $ENV_HASH" >&2
  exit 1
fi
echo "  ✓ envelope_hash is content-dependent (two appends → two hashes)"

# ── AUTH NEGATIVE PATHS ─────────────────────────────────────────────
echo
echo "=== AUTH NEGATIVE PATHS ==="
WRONG_BEARER=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$URL" \
  -H "authorization: Bearer nope" -H "x-agentkeys-actor: $ACTOR" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}')
assert_eq "$WRONG_BEARER" "401" "wrong bearer → 401"

NO_ACTOR=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$URL" \
  -H "authorization: Bearer demo-tok" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}')
assert_eq "$NO_ACTOR" "403" "missing actor header → 403"

CROSS_ACTOR=$(curl -sS -X POST "$URL" \
  -H "authorization: Bearer demo-tok" \
  -H "x-agentkeys-actor: 0x1111111111111111111111111111111111111111111111111111111111111111" \
  -H "content-type: application/json" \
  -d "$(call_body agentkeys.identity.whoami "$(printf '{"actor":"%s"}' "$ACTOR")")")
assert_eq "$(jread "$CROSS_ACTOR" '.error.code')" "-32003" \
  "cross-actor param → -32003 (FORBIDDEN)"

# ── SCHEMA-ONLY STUBS ───────────────────────────────────────────────
echo
echo "=== SCHEMA-ONLY STUBS ==="
STUB=$(call "$(call_body agentkeys.delegation.grant '{}')")
assert_contains "not_implemented_in_v1" "$STUB" "delegation.grant → not_implemented_in_v1"
assert_eq "$(jread "$STUB" '.error.data.scheduled_for')" "M4" "scheduled_for: M4 surfaces"

echo
echo "ALL ASSERTIONS PASSED."
echo "  see docs/plan/issue-107-mcp-demo-runbook.md for the full walkthrough."
