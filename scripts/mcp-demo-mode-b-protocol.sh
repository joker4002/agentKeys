#!/usr/bin/env bash
# scripts/mcp-demo-mode-b-protocol.sh — verifies the MCP boundary using the
# OFFICIAL Anthropic Python `mcp` SDK, which is the same client xiaozhi-server
# imports (confirmed in xiaozhi-esp32-server/main/xiaozhi-server/core/providers/
# tools/server_mcp/mcp_client.py — `from mcp.client.streamable_http import
# streamablehttp_client`).
#
# This catches integration regressions that the mode-A curl runbook can't:
# missing MCP handshake fields, malformed tool schemas, broken error wire
# format, Streamable-HTTP transport drift.
#
# Pre-reqs: `uv` (https://docs.astral.sh/uv/). Skips if not installed.
#
set -euo pipefail

if ! command -v uv >/dev/null 2>&1; then
  echo "skip: uv not installed — see https://docs.astral.sh/uv/" >&2
  exit 77
fi

PORT="${MCP_PORT:-18101}"
BIN="${MCP_BIN:-target/debug/agentkeys-mcp-server}"
URL="http://127.0.0.1:${PORT}/mcp"

if [ ! -x "$BIN" ]; then
  echo "building $BIN…"
  cargo build -p agentkeys-mcp-server
fi

"$BIN" --backend in-memory --listen "127.0.0.1:${PORT}" >/tmp/mcp-b-server.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait 2>/dev/null || true' EXIT INT TERM

for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && break
  sleep 0.2
done

# uv-managed venv so we don't pollute the operator's environment.
VENV_DIR="${TMPDIR:-/tmp}/mcp-verify-$$"
uv venv --quiet "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
uv pip install --quiet 'mcp>=1.0'

python3 - "$URL" <<'PY'
import asyncio
import sys
from mcp.client.streamable_http import streamablehttp_client
from mcp import ClientSession

URL = sys.argv[1]

EXPECTED_TOOLS = {
    'agentkeys.identity.whoami', 'agentkeys.memory.get', 'agentkeys.memory.put',
    'agentkeys.permission.check', 'agentkeys.cap.mint', 'agentkeys.cap.revoke',
    'agentkeys.audit.append', 'agentkeys.delegation.grant',
    'agentkeys.delegation.revoke', 'agentkeys.approval.request',
}

async def main():
    headers = {'Authorization': 'Bearer demo-tok', 'X-AgentKeys-Actor': 'O_kevin_001'}
    async with streamablehttp_client(URL, headers=headers) as (r, w, _sid):
        async with ClientSession(r, w) as session:
            init = await session.initialize()
            assert init.serverInfo.name == 'agentkeys-mcp-server', init.serverInfo.name
            print(f'  ✓ initialize handshake → {init.serverInfo.name} v{init.serverInfo.version}')

            tools = await session.list_tools()
            names = {t.name for t in tools.tools}
            missing = EXPECTED_TOOLS - names
            extra = names - EXPECTED_TOOLS
            assert not missing, f'missing: {missing}'
            assert not extra, f'extra: {extra}'
            print(f'  ✓ tools/list → all 10 expected tools')

            act2 = await session.call_tool('agentkeys.permission.check',
                {'actor':'O_kevin_001','scope':'payment.spend','params':{'amount_rmb':600}})
            text = act2.content[0].text
            assert 'daily_spend_cap_exceeded' in text, text
            assert 'cap=500, requested=600, period=daily' in text, text
            print('  ✓ Act 2 — deterministic deny, storyboard wording verbatim')

            act1 = await session.call_tool('agentkeys.memory.get',
                {'actor':'O_kevin_001','namespace':'travel',
                 'operator_omni':'O_kevin_op','device_key_hash':'0xdeadbeef'})
            assert 'Chengdu' in act1.content[0].text, act1.content[0].text
            print('  ✓ Act 1 — memory.get(travel) returns Chengdu fixture')

            revoke = await session.call_tool('agentkeys.cap.revoke', {'cap_id':'cap-abc'})
            assert 'in_memory' in revoke.content[0].text
            print('  ✓ Act 3a — cap.revoke records in-memory (M1 stub)')

            audit = await session.call_tool('agentkeys.audit.append', {
                'actor':'O_kevin_001',
                'event':{'operator_omni':'O_kevin_op','op_kind':3,
                         'op_body':{'cap_id':'cap-abc'},'result':0,
                         'intent_text':'parent revoked payment access'}
            })
            assert '0x' in audit.content[0].text
            print('  ✓ Act 3b — audit.append returns envelope_hash')

            try:
                await session.call_tool('agentkeys.delegation.grant', {})
                raise AssertionError('expected McpError but got success')
            except Exception as e:
                if 'not_implemented_in_v1' in str(e):
                    print('  ✓ schema-only stub → MCP error: not_implemented_in_v1')
                else:
                    raise

asyncio.run(main())
print()
print('ALL PROTOCOL-LEVEL ASSERTIONS PASSED.')
print('  the official Anthropic mcp SDK successfully drove the server end-to-end.')
print('  xiaozhi-server uses the same SDK (verified against xinnan-tech/xiaozhi-esp32-server@7f73dae).')
PY
