# harness/mcp — Claude Code MCP harness for M1

Phase-1 (M1) test harness that registers the AgentKeys MCP server with Claude
Code as the LLM-driven host, then drives the three-act demo storyboard from
[`docs/research/agent-iam-strategy.md`](../../docs/research/agent-iam-strategy.md)
§4.3 as the dev-loop smoke test for issues #107 / #108 / #109 / #111.

This harness is **layer 3** of the M1 test pyramid:

| Layer | What it tests | Files |
|---|---|---|
| 1. Unit + mock-backend | Adapter logic | `crates/agentkeys-mcp/src/lib.rs` `#[cfg(test)]` |
| 2. MCP Inspector / pure-protocol client | MCP wire format | (TBD by planner) |
| 3. **Claude Code MCP host** — this folder | LLM understands tool descriptions | `harness/mcp/` |
| 4. Three-act demo against live broker | #107 Status=Done gate | `harness/mcp/smoke-test.sh` against live broker |

## Files

| File | Purpose |
|---|---|
| `claude-config.json` | `claude mcp add` config — registers `agentkeys-mcp` against the local daemon binary |
| `smoke-test.sh` | Drives Claude Code through the three-act storyboard; exits 0 on green |
| `three-act-storyboard.md` | Operator-readable script the smoke test executes — also the source for the #111 vendor pitch |

## Prerequisites

1. Built daemon binary: `cargo build -p agentkeys-daemon`
2. A live session at `~/.agentkeys/<SESSION_ID>/session.json` (run
   `harness/v2-stage1-demo.sh` first if you don't have one)
3. Broker reachable at `$AGENTKEYS_BROKER_URL` (default
   `https://broker.heima.network` per `scripts/operator-workstation.env`)
4. Claude Code CLI installed and authenticated

## Quick start

```bash
SESSION_ID=alice bash harness/mcp/smoke-test.sh
```

Override any of:

- `SESSION_ID` — session label under `~/.agentkeys/` (default `alice`)
- `AGENTKEYS_BROKER_URL` — broker endpoint
- `AGENTKEYS_MCP_VENDOR_TOKEN` — M1 static vendor token (default `m1-harness-stopgap`;
  rotation policy is M2 #114 per
  [`volcano-ark-mcp-integration.md`](../../docs/research/volcano-ark-mcp-integration.md) §Risks #3)
- `CLAUDE_CODE_BIN` — path to Claude Code CLI (default `claude`)

## Why Claude Code (not xiaozhi-server) for the M1 dev loop

xiaozhi-server is the canonical #107 acceptance gate, but spinning it up per
test iteration is heavy. Claude Code is:

- An MCP host out of the box — `claude mcp add` registers a server in seconds
- LLM-driven — surfaces the failure mode unit tests miss ("LLM consistently
  picks the wrong tool because the description is ambiguous")
- Locally reproducible — every contributor with Claude Code can replay
- Non-deterministic — so layer 3 is a **smoke + tool-doc validator**, NOT
  a regression gate. The deterministic gates are layers 1 + 2.

xiaozhi-server final integration is deferred to the follow-up PR paired with
#112 (Volcano Ark marketplace).
