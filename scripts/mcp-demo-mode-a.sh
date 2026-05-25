#!/usr/bin/env bash
# scripts/mcp-demo-mode-a.sh — automated dev-mode demo for issue #107.
#
# Boots `agentkeys-mcp-server --backend in-memory`, walks Acts 1/2/3,
# asserts the storyboard's exact wording, then cleans up. Use this as
# the regression check for `docs/spec/plans/issue-107-mcp-demo-runbook.md`
# §A — if any assertion fails, the runbook drifted from reality.
#
# Usage:
#   bash scripts/mcp-demo-mode-a.sh
#
# Override the port if 18100 is in use:
#   MCP_PORT=18200 bash scripts/mcp-demo-mode-a.sh
#
set -euo pipefail

PORT="${MCP_PORT:-18100}"
URL="http://127.0.0.1:${PORT}/mcp"
BIN="${MCP_BIN:-target/debug/agentkeys-mcp-server}"

if [ ! -x "$BIN" ]; then
  echo "building $BIN…"
  cargo build -p agentkeys-mcp-server
fi

# Boot the server in the background; trap teardown.
"$BIN" --backend in-memory --listen "127.0.0.1:${PORT}" >/tmp/mcp-demo.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait 2>/dev/null || true' EXIT INT TERM

# Wait for /healthz to respond.
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if ! curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
  echo "FAIL: server did not respond on $URL" >&2
  cat /tmp/mcp-demo.log >&2
  exit 1
fi

call() {
  local body="$1"
  curl -sS -X POST "$URL" \
    -H "authorization: Bearer demo-tok" \
    -H "x-agentkeys-actor: O_kevin_001" \
    -H "content-type: application/json" \
    -d "$body"
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

echo
echo "=== ACT 1: memory.get travel namespace ==="
ACT1=$(call '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"agentkeys.memory.get","arguments":{"actor":"O_kevin_001","namespace":"travel","operator_omni":"O_kevin_op","device_key_hash":"0xdeadbeef"}},"id":1}')
assert_contains 'Chengdu' "$ACT1" "travel namespace returns Chengdu trip"
assert_contains '"namespace":"travel"' "$ACT1" "namespace field echoes back"

echo
echo "=== ACT 2: permission.check 600 RMB over 500 cap ==="
ACT2=$(call '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"agentkeys.permission.check","arguments":{"actor":"O_kevin_001","scope":"payment.spend","params":{"amount_rmb":600}}},"id":1}')
assert_contains '"verdict":"deny"' "$ACT2" "verdict is deny"
assert_contains 'daily_spend_cap_exceeded' "$ACT2" "reason is daily_spend_cap_exceeded"
assert_contains 'cap=500, requested=600, period=daily' "$ACT2" "explanation matches storyboard verbatim"

echo
echo "=== ACT 3a: cap.revoke ==="
ACT3A=$(call '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"agentkeys.cap.revoke","arguments":{"cap_id":"cap-abc-123"}},"id":1}')
assert_contains '"ok":true' "$ACT3A" "revoke succeeded"
assert_contains '"revocation":"in_memory"' "$ACT3A" "revoke recorded in-memory (M1 stub)"

echo
echo "=== ACT 3b: audit.append ==="
ACT3B=$(call '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"agentkeys.audit.append","arguments":{"actor":"O_kevin_001","event":{"operator_omni":"O_kevin_op","op_kind":3,"op_body":{"cap_id":"cap-abc-123","reason":"parent_revoke"},"result":0,"intent_text":"parent revoked payment access"}}},"id":1}')
assert_contains '"ok":true' "$ACT3B" "audit append succeeded"
assert_contains '"envelope_hash":"0x' "$ACT3B" "envelope hash returned"

echo
echo "=== AUTH NEGATIVE PATHS ==="
WRONG_BEARER=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$URL" \
  -H "authorization: Bearer nope" -H "x-agentkeys-actor: O_kevin_001" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}')
[ "$WRONG_BEARER" = "401" ] && echo "  ✓ wrong bearer → 401" || { echo "  ✗ wrong bearer expected 401 got $WRONG_BEARER" >&2; exit 1; }

NO_ACTOR=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$URL" \
  -H "authorization: Bearer demo-tok" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}')
[ "$NO_ACTOR" = "403" ] && echo "  ✓ missing actor header → 403" || { echo "  ✗ missing actor expected 403 got $NO_ACTOR" >&2; exit 1; }

CROSS_ACTOR=$(curl -sS -X POST "$URL" \
  -H "authorization: Bearer demo-tok" -H "x-agentkeys-actor: O_alice" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"agentkeys.identity.whoami","arguments":{"actor":"O_bob"}},"id":1}')
assert_contains '"code":-32003' "$CROSS_ACTOR" "cross-actor param → -32003 (FORBIDDEN)"

echo
echo "=== SCHEMA-ONLY STUBS ==="
STUB=$(call '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"agentkeys.delegation.grant","arguments":{}},"id":1}')
assert_contains 'not_implemented_in_v1' "$STUB" "delegation.grant returns not_implemented_in_v1"
assert_contains '"scheduled_for":"M4"' "$STUB" "scheduled_for: M4 surfaces"

echo
echo "ALL ASSERTIONS PASSED."
echo "  see docs/spec/plans/issue-107-mcp-demo-runbook.md for the full walkthrough."
