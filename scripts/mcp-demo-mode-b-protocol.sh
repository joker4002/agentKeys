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

# Active tools advertised via tools/list. The 3 M4 stubs
# (delegation.grant, delegation.revoke, approval.request) remain
# dispatchable via tools/call (test farther down) but were dropped from
# tools/list to shrink the LLM tool budget — see tools/mod.rs.
EXPECTED_TOOLS = {
    'agentkeys.identity.whoami', 'agentkeys.memory.get', 'agentkeys.memory.put',
    'agentkeys.permission.check', 'agentkeys.cap.mint', 'agentkeys.cap.revoke',
    'agentkeys.audit.append',
}
M4_STUB_TOOLS = {
    'agentkeys.delegation.grant', 'agentkeys.delegation.revoke', 'agentkeys.approval.request',
}

async def main():
    headers = {'Authorization': 'Bearer demo-tok', 'X-AgentKeys-Actor': '0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7'}
    async with streamablehttp_client(URL, headers=headers) as (r, w, _sid):
        async with ClientSession(r, w) as session:
            init = await session.initialize()
            assert init.serverInfo.name == 'agentkeys-mcp-server', init.serverInfo.name
            print(f'  ✓ initialize handshake → {init.serverInfo.name} v{init.serverInfo.version}')

            tools = await session.list_tools()
            names = {t.name for t in tools.tools}
            missing = EXPECTED_TOOLS - names
            extra = names - EXPECTED_TOOLS
            assert not missing, f'missing active tools: {missing}'
            assert not extra, f'unexpected tools: {extra}'
            # M4 stubs MUST NOT be in tools/list (still callable via tools/call below).
            stubs_in_list = M4_STUB_TOOLS & names
            assert not stubs_in_list, f'M4 stubs should not appear in tools/list: {stubs_in_list}'
            print(f'  ✓ tools/list → {len(EXPECTED_TOOLS)} active tools, 0 M4 stubs')

            act2 = await session.call_tool('agentkeys.permission.check',
                {'actor':'0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7','scope':'payment.spend','params':{'amount_rmb':600}})
            text = act2.content[0].text
            assert 'daily_spend_cap_exceeded' in text, text
            assert 'cap=500, requested=600, period=daily' in text, text
            print('  ✓ Act 2 — deterministic deny, storyboard wording verbatim')

            act1 = await session.call_tool('agentkeys.memory.get',
                {'actor':'0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7','namespace':'travel',
                 'operator_omni':'0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8','device_key_hash':'0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'})
            assert 'Chengdu' in act1.content[0].text, act1.content[0].text
            print('  ✓ Act 1 — memory.get(travel) returns Chengdu fixture')

            # Act 3: mint a real cap, revoke it by nonce, prove unknown revokes fail.
            mint = await session.call_tool('agentkeys.cap.mint', {
                'actor':'0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7',
                'op':'memory_get',
                'params':{'operator_omni':'0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8',
                          'service':'memory',
                          'device_key_hash':'0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'},
                'ttl':300})
            import json as _j
            cap_id = _j.loads(mint.content[0].text)['cap']['payload']['nonce']
            assert cap_id, 'cap.mint did not return a nonce'
            print(f'  ✓ Act 3 — cap.mint returned cap_id={cap_id[:8]}…')

            revoke = await session.call_tool('agentkeys.cap.revoke', {'cap_id': cap_id})
            assert 'in_memory' in revoke.content[0].text
            print('  ✓ Act 3a — cap.revoke(known) records in-memory (M1 stub)')

            try:
                await session.call_tool('agentkeys.cap.revoke', {'cap_id':'this-cap-was-never-minted'})
                raise AssertionError('cap.revoke(unknown) should have errored')
            except Exception as e:
                assert 'unknown cap_id' in str(e), str(e)
                print('  ✓ Act 3 — cap.revoke(unknown) rejected (not a rubber-stamp)')

            audit = await session.call_tool('agentkeys.audit.append', {
                'actor':'0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7',
                'event':{'operator_omni':'0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8','op_kind':3,
                         'op_body':{'cap_id': cap_id},'result':0,
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
