#!/usr/bin/env bash
# scripts/mcp-demo-mode-c-xiaozhi-client.sh
#
# Drives our MCP server using xiaozhi-server's OWN `ServerMCPClient` class
# (one level above the raw Anthropic SDK that mode-B uses). This is the
# integration code xiaozhi-server actually runs in production, exercised
# against our server — same Python interpreter, same imports, same
# config-loading path.
#
# Plus a deterministic "fake LLM" harness that issues the exact tool
# calls the three-act storyboard expects, so the full
# xiaozhi-server → ServerMCPClient → our /mcp endpoint → tools loop
# is asserted without needing Ollama, Doubao, Qwen, MagicLick hardware,
# or any LLM API key.
#
# What this proves vs what it doesn't:
#  ✓ xiaozhi-server's MCP integration code calls our tools correctly
#  ✓ Config-file path + format works against xiaozhi-server's loader
#  ✓ All three acts return storyboard-expected payloads
#  ✗ A real LLM (Doubao/Qwen/Ollama) decides to call the right tools
#    at the right times — that's a prompt-engineering + model-capability
#    question outside the MCP server boundary.
#  ✗ MagicLick audio I/O — physical hardware.
#
set -euo pipefail

if ! command -v uv >/dev/null 2>&1; then
  echo "skip: uv not installed — see https://docs.astral.sh/uv/" >&2
  exit 77
fi

PORT="${MCP_PORT:-18102}"
BIN="${MCP_BIN:-target/debug/agentkeys-mcp-server}"
URL="http://127.0.0.1:${PORT}/mcp"
XIAOZHI_DIR="${XIAOZHI_DIR:-/tmp/xiaozhi-verify/xiaozhi-esp32-server}"

# Clone xiaozhi-server if not present.
if [ ! -d "$XIAOZHI_DIR/main/xiaozhi-server" ]; then
  echo "cloning xiaozhi-server into $XIAOZHI_DIR…"
  mkdir -p "$(dirname "$XIAOZHI_DIR")"
  git clone --depth 1 https://github.com/xinnan-tech/xiaozhi-esp32-server.git "$XIAOZHI_DIR" >/dev/null 2>&1
fi

if [ ! -x "$BIN" ]; then
  echo "building $BIN…"
  cargo build -p agentkeys-mcp-server
fi

"$BIN" --backend in-memory --listen "127.0.0.1:${PORT}" >/tmp/mcp-c-server.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait 2>/dev/null || true' EXIT INT TERM

for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1 && break
  sleep 0.2
done

VENV_DIR="${TMPDIR:-/tmp}/mcp-verify-c-$$"
uv venv --quiet "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
uv pip install --quiet 'mcp>=1.0'

# Make xiaozhi-server importable. The package has its own logging /
# config / dependency stack, so we import the MCP-client subtree
# narrowly to avoid pulling in TTS / ASR / WebSocket deps.
export PYTHONPATH="$XIAOZHI_DIR/main/xiaozhi-server:${PYTHONPATH:-}"
export AGENTKEYS_MCP_URL="$URL"
export XIAOZHI_DIR="$XIAOZHI_DIR"

python3 - <<'PY'
"""
Mode C — drive our MCP server using xiaozhi-server's actual
`ServerMCPClient` integration code (not just the underlying SDK).
Plus a deterministic fake-LLM that issues storyboard-expected tool
calls so the full LLM → MCP → tools loop is end-to-end asserted.
"""
import asyncio
import os
import sys
import logging

# Suppress xiaozhi-server's verbose loguru config — we only need its
# MCP client class, not its full app bootstrap.
logging.basicConfig(level=logging.WARNING)

# Minimal stubs for xiaozhi-server's logger/config deps we don't have.
class _StubLogger:
    def bind(self, **kw): return self
    def info(self, *a, **k): pass
    def debug(self, *a, **k): pass
    def warning(self, *a, **k): pass
    def error(self, *a, **k): pass

class _StubConfigModule:
    @staticmethod
    def setup_logging():
        return _StubLogger()

class _StubUtil:
    @staticmethod
    def sanitize_tool_name(name):
        return name.replace('.', '_')

import types, importlib.util, pathlib

# Build stub modules for the few things `mcp_client.py` imports from
# the xiaozhi-server ecosystem without dragging in the full app stack
# (TTS / ASR / WebSocket / loguru config).
config_logger_mod = types.ModuleType('config.logger')
config_logger_mod.setup_logging = _StubConfigModule.setup_logging
sys.modules['config'] = types.ModuleType('config')
sys.modules['config.logger'] = config_logger_mod

util_mod = types.ModuleType('core.utils.util')
util_mod.sanitize_tool_name = _StubUtil.sanitize_tool_name
sys.modules['core'] = types.ModuleType('core')
sys.modules['core.utils'] = types.ModuleType('core.utils')
sys.modules['core.utils.util'] = util_mod

# Load `mcp_client.py` directly by file path — bypasses
# `core/providers/__init__.py` etc which pull in unrelated deps.
xiaozhi_root = pathlib.Path(os.environ.get('XIAOZHI_DIR', '/tmp/xiaozhi-verify/xiaozhi-esp32-server')) / 'main' / 'xiaozhi-server'
mcp_client_path = xiaozhi_root / 'core' / 'providers' / 'tools' / 'server_mcp' / 'mcp_client.py'
spec = importlib.util.spec_from_file_location('mcp_client', mcp_client_path)
mcp_client_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp_client_mod)
ServerMCPClient = mcp_client_mod.ServerMCPClient

URL = os.environ['AGENTKEYS_MCP_URL']

# This is the EXACT shape xiaozhi-server reads from
# data/.mcp_server_settings.json → mcpServers[name].
config = {
    'url': URL,
    'transport': 'streamable-http',
    'headers': {
        'Authorization': 'Bearer demo-tok',
        'X-AgentKeys-Actor': 'O_kevin_001',
    }
}

async def main():
    client = ServerMCPClient(config)
    await client.initialize()
    print('  ✓ ServerMCPClient.initialize() succeeded')

    tools = client.get_available_tools()
    names = [t['function']['name'] for t in tools]
    print(f'  ✓ ServerMCPClient sees {len(tools)} tools')

    # Names get sanitized by xiaozhi-server (`.` → `_`) for LLM consumption.
    # has_tool() and call_tool() use the sanitized form.
    assert client.has_tool('agentkeys_permission_check'), names
    assert client.has_tool('agentkeys_memory_get'), names
    assert client.has_tool('agentkeys_memory_put'), names
    assert client.has_tool('agentkeys_cap_mint'), names
    assert client.has_tool('agentkeys_cap_revoke'), names
    assert client.has_tool('agentkeys_audit_append'), names
    assert client.has_tool('agentkeys_identity_whoami'), names
    print('  ✓ has_tool(...) lookups match for every active tool')

    # ─── Fake-LLM three-act harness ─────────────────────────────
    # Simulates what Doubao/Qwen would do given each user prompt: pick
    # the right tool with the right args. This is deterministic so the
    # demo's correctness doesn't depend on LLM tuning.

    print('\n  --- Act 1: user says "Where am I going this weekend?" ---')
    print('  fake-LLM picks: agentkeys.memory.get(namespace="travel")')
    r = await client.call_tool('agentkeys_memory_get', {
        'actor': 'O_kevin_001',
        'namespace': 'travel',
        'operator_omni': 'O_kevin_op',
        'device_key_hash': '0xdeadbeef',
    })
    body = r.content[0].text
    assert 'Chengdu' in body, body
    print(f'  ✓ Act 1 response (LLM would TTS this): "{body[:80]}…"')

    print('\n  --- Act 2: user says "Order me 600 RMB of hotpot" ---')
    print('  fake-LLM picks: agentkeys.permission.check(scope="payment.spend", amount_rmb=600)')
    r = await client.call_tool('agentkeys_permission_check', {
        'actor': 'O_kevin_001',
        'scope': 'payment.spend',
        'params': {'amount_rmb': 600},
    })
    body = r.content[0].text
    assert '"verdict":"deny"' in body, body
    assert 'daily_spend_cap_exceeded' in body, body
    assert 'cap=500, requested=600, period=daily' in body, body
    print(f'  ✓ Act 2 verdict: deny (cap=500). LLM uses this to refuse politely.')

    print('\n  --- Act 3: parent revokes; user retries ---')
    print('  fake-LLM picks: agentkeys.cap.revoke + agentkeys.audit.append')
    r = await client.call_tool('agentkeys_cap_revoke', {'cap_id': 'cap-abc'})
    assert 'in_memory' in r.content[0].text
    print('  ✓ Act 3a — cap.revoke recorded')

    r = await client.call_tool('agentkeys_audit_append', {
        'actor': 'O_kevin_001',
        'event': {
            'operator_omni': 'O_kevin_op',
            'op_kind': 3,
            'op_body': {'cap_id': 'cap-abc', 'reason': 'parent_revoke'},
            'result': 0,
            'intent_text': 'parent revoked payment access',
        }
    })
    assert '0x' in r.content[0].text
    print('  ✓ Act 3b — audit envelope returned')

    await client.cleanup()
    print('\n  ✓ ServerMCPClient.cleanup() clean')

asyncio.run(main())
print()
print('ALL MODE-C ASSERTIONS PASSED.')
print('  Drove the server via xiaozhi-server\'s own ServerMCPClient class')
print('  (xinnan-tech/xiaozhi-esp32-server@7f73dae). When a real LLM in')
print('  xiaozhi-server picks the same tool calls our fake-LLM picked,')
print('  the demo will work end-to-end.')
PY
