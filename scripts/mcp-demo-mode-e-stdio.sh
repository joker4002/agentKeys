#!/usr/bin/env bash
# scripts/mcp-demo-mode-e-stdio.sh — three-act storyboard over **stdio**.
#
# Why this tier exists (the gap modes A-D leave):
#   • mode-a: HTTP via curl
#   • mode-b: HTTP via Anthropic Python `mcp` SDK
#   • mode-c: HTTP via xiaozhi's ServerMCPClient
#   • mode-d: WebSocket via mcp-endpoint relay
#   • mode-e: STDIO via Anthropic Python `mcp` SDK's stdio_client  ← THIS
#
# stdio is what Claude Code, Codex CLI, Claude Desktop, Cursor, Cline,
# Roo, Windsurf, Gemini CLI all use. Every other transport could pass
# while stdio is broken (and we saw exactly that in #107 — the binary
# polluted stdout with tracing logs + sent error responses to
# notifications, which would have silently broken every desktop client).
#
# This script invokes the SAME stdio_client code path Claude Code uses
# internally, drives the full three-act storyboard against the installed
# binary, and asserts content (not just JSON shape).
#
# Usage:
#   bash scripts/mcp-demo-mode-e-stdio.sh                       # auto-detect bin
#   bash scripts/mcp-demo-mode-e-stdio.sh /path/to/binary       # explicit
#   AGENTKEYS_MCP_BIN=/path/to/binary bash scripts/mcp-demo-mode-e-stdio.sh
set -euo pipefail

# 1. Resolve the binary to test.
BIN="${1:-${AGENTKEYS_MCP_BIN:-}}"
if [ -z "$BIN" ]; then
  for candidate in \
    "$HOME/.cargo/bin/agentkeys-mcp-server" \
    "$HOME/.local/bin/agentkeys-mcp-server" \
    "./target/release/agentkeys-mcp-server" \
    "/usr/local/bin/agentkeys-mcp-server"; do
    if [ -x "$candidate" ]; then BIN="$candidate"; break; fi
  done
fi
[ -x "$BIN" ] || { echo "ERROR: no agentkeys-mcp-server binary found. Pass path as \$1 or set AGENTKEYS_MCP_BIN." >&2; exit 1; }
echo "==> testing binary: $BIN" >&2

# 2. Ensure uv + a venv with the Anthropic mcp SDK.
if ! command -v uv >/dev/null 2>&1; then
  echo "==> installing uv (one-shot)" >&2
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi

VENV="${TMPDIR:-/tmp}/mcp-mode-e-venv"
if [ ! -x "$VENV/bin/python" ]; then
  uv venv --quiet "$VENV"
  uv pip install --quiet --python "$VENV/bin/python" mcp
fi

# 3. Drive the storyboard.
export BIN
"$VENV/bin/python" <<'PY'
import asyncio, json, os, sys
from mcp.client.stdio import stdio_client, StdioServerParameters
from mcp import ClientSession

# In-memory backend auto-seeds DEMO_ACTOR / DEMO_OPERATOR / DEMO_DEVICE_KEY_HASH
# so the LLM-side can pass minimal arguments (namespace only, etc.). For
# tools whose schema still requires actor+operator (audit.append), we
# pass the demo values verbatim.
DEMO_ACTOR    = "0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7"
DEMO_OPERATOR = "0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8"

async def main():
    params = StdioServerParameters(
        command=os.environ["BIN"],
        args=[],
        env={
            "MCP_TRANSPORT": "stdio",
            "MCP_BACKEND": "in-memory",
            "PATH": os.environ.get("PATH", ""),
            "HOME": os.environ.get("HOME", ""),
        },
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            # — Handshake —
            init = await session.initialize()
            assert init.serverInfo.name == "agentkeys-mcp-server", init.serverInfo
            print(f"  ✓ initialize via stdio → {init.serverInfo.name} v{init.serverInfo.version}")

            tools = await session.list_tools()
            names = sorted(t.name for t in tools.tools)
            assert len(names) == 7, f"want 7 tools, got {len(names)}: {names}"
            for required in [
                "agentkeys.identity.whoami",
                "agentkeys.memory.get",
                "agentkeys.memory.put",
                "agentkeys.permission.check",
                "agentkeys.cap.mint",
                "agentkeys.cap.revoke",
                "agentkeys.audit.append",
            ]:
                assert required in names, f"missing tool: {required}"
            print(f"  ✓ tools/list → 7 active tools, all expected")

            # — Act 1: Permissioned Memory (namespace-scoped read) —
            res = await session.call_tool("agentkeys.memory.get", {"namespace": "travel"})
            text = res.content[0].text
            assert "Chengdu" in text, text
            print("  ✓ Act 1 — memory.get(travel) returns Chengdu fixture")

            res = await session.call_tool("agentkeys.memory.get", {"namespace": "family"})
            assert "Wife" in res.content[0].text or "bday" in res.content[0].text
            print("  ✓ Act 1b — memory.get(family) returns family fixture")

            # — Memory round-trip with unicode (regression test for the
            #   '有痛风' test the user ran live during issue #107) —
            #   Uses the `personal` namespace (a v0 namespace per issue
            #   #108; `profile` is a memory TYPE, not a namespace).
            await session.call_tool("agentkeys.memory.put", {
                "namespace": "personal", "content": "有痛风 — gout, no shellfish"
            })
            res = await session.call_tool("agentkeys.memory.get", {"namespace": "personal"})
            assert "有痛风" in res.content[0].text, res.content[0].text
            assert "gout" in res.content[0].text
            print("  ✓ Memory round-trip — Chinese + English unicode preserved through put→get")

            # — Act 2: Deterministic Denial (no LLM in the loop) —
            res = await session.call_tool("agentkeys.permission.check", {
                "scope": "payment.spend", "params": {"amount_rmb": 600}
            })
            text = res.content[0].text
            assert "daily_spend_cap_exceeded" in text, text
            assert "cap=500" in text, text
            print("  ✓ Act 2 — permission.check denies 600 RMB (storyboard wording: cap=500)")

            res = await session.call_tool("agentkeys.permission.check", {
                "scope": "payment.spend", "params": {"amount_rmb": 100}
            })
            assert "accept" in res.content[0].text, res.content[0].text
            print("  ✓ Act 2b — permission.check accepts 100 RMB under cap")

            # — Act 3: Online Revocation —
            mint = await session.call_tool("agentkeys.cap.mint", {"op": "memory_get"})
            cap_id = json.loads(mint.content[0].text)["cap"]["payload"]["nonce"]
            assert cap_id, "cap.mint returned no nonce"
            print(f"  ✓ Act 3 — cap.mint returned cap_id={cap_id[:10]}…")

            revoke = await session.call_tool("agentkeys.cap.revoke", {"cap_id": cap_id})
            assert "in_memory" in revoke.content[0].text
            print("  ✓ Act 3a — cap.revoke(known) records the revocation")

            try:
                await session.call_tool("agentkeys.cap.revoke",
                                         {"cap_id": "this-cap-was-never-minted"})
                raise AssertionError("cap.revoke(unknown) should have errored")
            except Exception as e:
                assert "unknown cap_id" in str(e), str(e)
                print("  ✓ Act 3b — cap.revoke(unknown) is rejected (not a rubber-stamp)")

            # — Audit envelope —
            audit = await session.call_tool("agentkeys.audit.append", {
                "actor": DEMO_ACTOR,
                "event": {
                    "operator_omni": DEMO_OPERATOR,
                    "op_kind": 3,
                    "op_body": {"cap_id": cap_id, "reason": "parent_revoke"},
                    "result": 0,
                    "intent_text": "stdio e2e test — Act 3 audit row",
                }
            })
            ah_text = audit.content[0].text
            assert "0x" in ah_text, ah_text
            print("  ✓ Act 3c — audit.append returned envelope_hash (0x prefix)")

            # — Identity (ambient actor resolution from MCP_DEFAULT_*) —
            who = await session.call_tool("agentkeys.identity.whoami", {})
            assert DEMO_ACTOR in who.content[0].text, who.content[0].text
            print("  ✓ identity.whoami resolves ambient default actor")

    print()
    print("ALL ASSERTIONS PASSED.")
    print("  stdio transport: three-act storyboard verified end-to-end.")
    print("  This is the path Claude Code / Codex / Claude Desktop drive.")

asyncio.run(main())
PY
