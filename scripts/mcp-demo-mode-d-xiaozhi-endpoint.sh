#!/usr/bin/env bash
# scripts/mcp-demo-mode-d-xiaozhi-endpoint.sh
#
# Verifies the xiaozhi-MCP-endpoint path end-to-end WITHOUT any
# MagicLick hardware and WITHOUT an LLM provider key. Topology:
#
#   ┌────────────────────────┐                  ┌──────────────────────────┐
#   │  fake xiaozhi client   │ ◀── ws ──▶ relay ◀── ws ──▶  agentkeys-mcp- │
#   │  (this script, websocat│   (mock; pure    │   (--transport=mcp-      │
#   │   or python)           │    JSON-RPC pipe)│   endpoint, our binary)  │
#   └────────────────────────┘                  └──────────────────────────┘
#
# The fake-client side plays the role xiaozhi-server / xiaozhi cloud
# plays in production: it sends `initialize`, `tools/list`, the three-
# act `tools/call`s, and asserts the responses are storyboard-correct.
#
# The mock relay is the simplest possible MCP-endpoint-server: a
# Python websocket pipe that forwards messages between the two
# clients connected to the same `/mcp_endpoint/mcp/?token=X` path.
# It mirrors xinnan-tech/mcp-endpoint-server's role without bringing
# in that whole project — the protocol is plain JSON-RPC over WS.
#
# When this passes, swap the mock for the real `mcp-endpoint-server`
# binary (Python service deployed on the EC2 broker host per the
# runbook §B) and connect it to your xiaozhi智控台 — the MCP server
# behavior is the same.
#
set -euo pipefail

if ! command -v uv >/dev/null 2>&1; then
  echo "skip: uv not installed — see https://docs.astral.sh/uv/" >&2
  exit 77
fi

PORT_RELAY="${MCP_RELAY_PORT:-18104}"
BIN="${MCP_BIN:-target/debug/agentkeys-mcp-server}"
TOKEN='abc123'
TOOL_URL="ws://127.0.0.1:${PORT_RELAY}/mcp_endpoint/mcp/?token=${TOKEN}"
CLIENT_URL="ws://127.0.0.1:${PORT_RELAY}/mcp_endpoint/call/?token=${TOKEN}"

if [ ! -x "$BIN" ]; then
  echo "building $BIN…"
  cargo build -p agentkeys-mcp-server
fi

VENV_DIR="${TMPDIR:-/tmp}/mcp-verify-d-$$"
uv venv --quiet "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
uv pip install --quiet 'websockets>=12'

# ── Minimal MCP-endpoint relay ───────────────────────────────────────
# Mirrors the real xinnan-tech/mcp-endpoint-server routing exactly:
#   /mcp_endpoint/mcp/?token=X  — tool side (the MCP server connects here)
#   /mcp_endpoint/call/?token=X — client side (xiaozhi cloud connects here)
# Same token pairs tool ↔ client. We forward bytes verbatim between
# the two sockets — no ID rewriting (we only ever have one client at
# a time per token, so collisions are impossible).
RELAY_PY="${TMPDIR:-/tmp}/mcp-relay-$$.py"
cat > "$RELAY_PY" <<'PY'
import asyncio, sys, websockets
from urllib.parse import parse_qs, urlparse

PAIRS = {}  # token -> {'tool': ws, 'client': ws}

async def handler(ws):
    raw_path = ws.request.path
    parsed = urlparse(raw_path)
    qs = parse_qs(parsed.query)
    token = (qs.get('token') or [''])[0]
    if not token:
        await ws.close(code=1008, reason='missing token')
        return

    if parsed.path == '/mcp_endpoint/mcp/':
        role = 'tool'
    elif parsed.path == '/mcp_endpoint/call/':
        role = 'client'
    else:
        await ws.close(code=1008, reason='unknown path')
        return

    PAIRS.setdefault(token, {})
    PAIRS[token][role] = ws
    print(f'  relay: {role} connected (token={token[:6]}…)', flush=True)

    try:
        async for msg in ws:
            other_role = 'client' if role == 'tool' else 'tool'
            other = PAIRS[token].get(other_role)
            if other is not None:
                try:
                    await other.send(msg)
                except Exception:
                    pass
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        if PAIRS.get(token, {}).get(role) is ws:
            PAIRS[token][role] = None

async def main():
    port = int(sys.argv[1])
    async with websockets.serve(handler, "127.0.0.1", port):
        print(f'relay listening on ws://127.0.0.1:{port}', flush=True)
        await asyncio.Future()

asyncio.run(main())
PY

# Start the relay in the background; trap teardown.
python3 "$RELAY_PY" "$PORT_RELAY" >/tmp/mcp-relay.log 2>&1 &
RELAY_PID=$!
trap 'kill $RELAY_PID $MCP_PID 2>/dev/null || true; wait 2>/dev/null || true' EXIT INT TERM

# Wait for relay readiness.
for _ in $(seq 1 50); do
  if grep -q "listening on" /tmp/mcp-relay.log 2>/dev/null; then break; fi
  sleep 0.1
done

# Start the MCP server with the new transport, connecting to the tool
# side of the relay.
"$BIN" --transport mcp-endpoint --backend in-memory --mcp-endpoint "$TOOL_URL" \
  > /tmp/mcp-mcpendpoint.log 2>&1 &
MCP_PID=$!

# Give the MCP server a moment to connect as the tool side.
sleep 1
if ! kill -0 "$MCP_PID" 2>/dev/null; then
  echo "FAIL: MCP server exited; log:" >&2
  cat /tmp/mcp-mcpendpoint.log >&2
  exit 1
fi

# ── Drive the relay from the "xiaozhi client" side ───────────────────
export CLIENT_URL TOKEN
python3 - <<'PY'
import asyncio, json, os, sys, websockets

URL = os.environ['CLIENT_URL']

EXPECTED_TOOLS = {
    'agentkeys.identity.whoami', 'agentkeys.memory.get', 'agentkeys.memory.put',
    'agentkeys.permission.check', 'agentkeys.cap.mint', 'agentkeys.cap.revoke',
    'agentkeys.audit.append', 'agentkeys.delegation.grant',
    'agentkeys.delegation.revoke', 'agentkeys.approval.request',
}

async def main():
    # Client role; the relay path /mcp_endpoint/call/ marks us as
    # the xiaozhi side, and pairs us with the tool on the same token.
    async with websockets.connect(URL) as ws:
        async def send(obj):
            await ws.send(json.dumps(obj))
        async def recv_match(want_id):
            for _ in range(20):
                msg = json.loads(await asyncio.wait_for(ws.recv(), 10))
                if msg.get('id') == want_id:
                    return msg
            raise RuntimeError(f'no response for id={want_id}')

        # initialize handshake
        await send({"jsonrpc":"2.0","id":1,"method":"initialize",
                    "params":{"protocolVersion":"2024-11-05","capabilities":{},
                              "clientInfo":{"name":"fake-xiaozhi-client","version":"0.0.1"}}})
        init = await recv_match(1)
        assert init['result']['serverInfo']['name'] == 'agentkeys-mcp-server', init
        print(f"  ✓ initialize: name={init['result']['serverInfo']['name']} "
              f"v{init['result']['serverInfo']['version']}")

        await send({"jsonrpc":"2.0","method":"notifications/initialized"})

        # tools/list
        await send({"jsonrpc":"2.0","id":2,"method":"tools/list"})
        tools = await recv_match(2)
        names = {t['name'] for t in tools['result']['tools']}
        missing = EXPECTED_TOOLS - names
        assert not missing, f'missing tools: {missing}'
        print(f'  ✓ tools/list returned all 10 expected tools through the relay')

        # Act 2: deterministic deny (no LLM)
        await send({"jsonrpc":"2.0","id":3,"method":"tools/call",
                    "params":{"name":"agentkeys.permission.check",
                              "arguments":{"actor":"0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7",
                                           "scope":"payment.spend",
                                           "params":{"amount_rmb":600}}}})
        act2 = await recv_match(3)
        text = act2['result']['content'][0]['text']
        assert 'daily_spend_cap_exceeded' in text, text
        assert 'cap=500, requested=600, period=daily' in text, text
        print('  ✓ Act 2 — deterministic deny, storyboard wording verbatim')

        # Act 1: memory.get
        await send({"jsonrpc":"2.0","id":4,"method":"tools/call",
                    "params":{"name":"agentkeys.memory.get",
                              "arguments":{
                                  "actor":"0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7",
                                  "namespace":"travel",
                                  "operator_omni":"0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8",
                                  "device_key_hash":"0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}}})
        act1 = await recv_match(4)
        assert 'Chengdu' in act1['result']['content'][0]['text']
        print('  ✓ Act 1 — memory.get(travel) returns Chengdu fixture through the relay')

        # Act 3: mint → revoke by nonce → unknown rejected
        await send({"jsonrpc":"2.0","id":5,"method":"tools/call",
                    "params":{"name":"agentkeys.cap.mint",
                              "arguments":{
                                  "actor":"0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7",
                                  "op":"memory_get",
                                  "params":{
                                      "operator_omni":"0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8",
                                      "service":"memory",
                                      "device_key_hash":"0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"},
                                  "ttl":300}}})
        mint = await recv_match(5)
        cap_id = json.loads(mint['result']['content'][0]['text'])['cap']['payload']['nonce']
        print(f'  ✓ Act 3 — cap.mint returned cap_id={cap_id[:8]}…')

        await send({"jsonrpc":"2.0","id":6,"method":"tools/call",
                    "params":{"name":"agentkeys.cap.revoke","arguments":{"cap_id": cap_id}}})
        rev = await recv_match(6)
        assert 'in_memory' in rev['result']['content'][0]['text']
        print('  ✓ Act 3a — cap.revoke(known) recorded')

        await send({"jsonrpc":"2.0","id":7,"method":"tools/call",
                    "params":{"name":"agentkeys.cap.revoke",
                              "arguments":{"cap_id":"this-cap-was-never-minted"}}})
        bad = await recv_match(7)
        assert 'error' in bad, bad
        print('  ✓ Act 3 — cap.revoke(unknown) rejected (not a rubber-stamp)')

asyncio.run(main())
print()
print('ALL MODE-D ASSERTIONS PASSED.')
print('  Drove the server end-to-end through a xiaozhi-style WS relay.')
print('  In production, swap the mock relay for `mcp-endpoint-server`')
print('  on the EC2 broker host and point your xiaozhi agent at it —')
print('  the MCP server behavior is identical.')
PY
