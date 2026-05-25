# Issue #107 — Phase 1 MCP server demo runbook

Two demo modes:

| Mode | Audience | Hardware | LLM key | External services | Time to first byte |
|---|---|---|---|---|---|
| **A. Dev / fresh-laptop** | engineers, vendor prospects | none | none | none | ~2 min |
| **B. Full xiaozhi-server + MagicLick** | end-to-end vendor demo | MagicLick 2.5 toy | Doubao or Qwen | live broker + workers + xiaozhi-server | ~45 min |

Run mode A first to validate the MCP server + the three-act storyboard. Run mode B when you have hardware + LLM key + a live broker deployed.

---

## A. Dev / fresh-laptop demo

### Prerequisites

- Rust toolchain (`stable`, matches `rust-toolchain.toml`).
- macOS or Linux. `curl` + a JSON pretty-printer (`jq`, `python3`, or `mcp-inspector`).
- Nothing else. No broker, no workers, no Docker, no LLM key.

### 1. Build + run the server

```bash
cd ~/Projects/agentKeys      # or wherever you cloned

cargo run -p agentkeys-mcp-server -- \
  --backend in-memory \
  --listen 127.0.0.1:8088
```

Expected log lines:

```text
INFO agentkeys_mcp_server: backend=in-memory (dev demo); seeded with O_kevin_001 fixtures
INFO agentkeys_mcp_server: agentkeys-mcp-server listening (HTTP) addr=127.0.0.1:8088
```

What got seeded into the in-memory backend:

| Actor | Namespace | Content |
|---|---|---|
| `O_kevin_001` | `travel` | "Chengdu trip — Apr 12 to 16, hotpot at Yulin." |
| `O_kevin_001` | `family` | "Wife's bday Aug 3 (gift idea: hiking boots)." |
| `O_kevin_001` | `profile` | "Allergic to shellfish. Prefers windowed flights." |

A default vendor token `magiclick:demo-tok` is auto-seeded in dev mode so the runbook stays one-command. Override with `--vendor-tokens` if you need a different pair.

### 2. Sanity check — healthz + tools/list

In a second terminal:

```bash
curl -sS http://127.0.0.1:8088/healthz
# → {"name":"agentkeys-mcp-server","ok":true}

curl -sS -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer demo-tok" \
  -H "x-agentkeys-actor: O_kevin_001" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)['result']['tools']),'tools')"
# → 10 tools
```

### 3. Act 1 — Permissioned Memory

The MCP host (xiaozhi-server / Claude / etc.) decides it needs memory context and calls `memory.get` scoped to the `travel` namespace:

```bash
curl -sS -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer demo-tok" \
  -H "x-agentkeys-actor: O_kevin_001" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"tools/call",
    "params":{
      "name":"agentkeys.memory.get",
      "arguments":{
        "actor":"O_kevin_001",
        "namespace":"travel",
        "operator_omni":"O_kevin_op",
        "device_key_hash":"0xdeadbeef"
      }
    },
    "id":1
  }' | python3 -m json.tool
```

Expected `structuredContent`:

```json
{
  "content": "Chengdu trip — Apr 12 to 16, hotpot at Yulin.",
  "namespace": "travel",
  "ok": true
}
```

**Why this matters:** the device's cap-token is bound to the `travel` namespace. The MCP server forwards the namespace; the (mocked) worker enforces it. In production, the cap binds cryptographically (M4 follow-up to #108); for the dev demo, the in-memory backend honors the namespace key.

### 4. Act 2 — Deterministic Denial

The MCP host calls `permission.check` to authorize a 600 RMB hotpot order. The policy engine sees the daily cap is 500 RMB and returns a deny verdict with the storyboard's exact reason string:

```bash
curl -sS -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer demo-tok" \
  -H "x-agentkeys-actor: O_kevin_001" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"tools/call",
    "params":{
      "name":"agentkeys.permission.check",
      "arguments":{
        "actor":"O_kevin_001",
        "scope":"payment.spend",
        "params":{"amount_rmb":600}
      }
    },
    "id":1
  }' | python3 -m json.tool
```

Expected `structuredContent`:

```json
{
  "verdict": "deny",
  "reason": "daily_spend_cap_exceeded",
  "scope": "payment.spend",
  "explanation": "cap=500, requested=600, period=daily"
}
```

**Why this matters:** the verdict came from `crate::policy::PolicyEngine`, a pure function. **No LLM, no inference, no network call.** Change the amount to `200` and re-run — verdict flips to `accept`. Change the scope to anything not in the policy table (e.g. `nuke.launch`) — verdict is `deny` with reason `scope_not_in_policy_table` (closed-world default-deny).

### 5. Act 3 — Online Revocation

Two steps: revoke the cap, then append the audit event.

```bash
# 5a. revoke
curl -sS -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer demo-tok" \
  -H "x-agentkeys-actor: O_kevin_001" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"tools/call",
    "params":{
      "name":"agentkeys.cap.revoke",
      "arguments":{"cap_id":"cap-abc-123"}
    },
    "id":1
  }' | python3 -m json.tool

# 5b. audit row appears
curl -sS -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer demo-tok" \
  -H "x-agentkeys-actor: O_kevin_001" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "method":"tools/call",
    "params":{
      "name":"agentkeys.audit.append",
      "arguments":{
        "actor":"O_kevin_001",
        "event":{
          "operator_omni":"O_kevin_op",
          "op_kind":3,
          "op_body":{"cap_id":"cap-abc-123","reason":"parent_revoke"},
          "result":0,
          "intent_text":"parent revoked payment access"
        }
      }
    },
    "id":1
  }' | python3 -m json.tool
```

Expected `structuredContent` for the audit append:

```json
{"ok": true, "envelope_hash": "0x0100000000000000000000000000000000000000000000000000000000000000"}
```

**Why this matters:** revoke + audit are decoupled by design. In production, revoke hits the broker's revocation list (M4); audit lands in the worker queue and gets anchored on-chain in the next 2-min batch per #109. In dev mode, both are in-memory but the wire shape is identical.

### 6. Acceptance-criterion #3 — auth negative paths

Demonstrate the bearer + actor scoping rules from the issue:

```bash
# Wrong token → 401
curl -sS -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer nope" \
  -H "x-agentkeys-actor: O_kevin_001" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
# → 401

# Missing X-AgentKeys-Actor header → 403
curl -sS -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer demo-tok" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
# → 403

# Tool param actor != header actor → JSON-RPC error code -32003
curl -sS -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer demo-tok" \
  -H "x-agentkeys-actor: O_alice" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"agentkeys.identity.whoami","arguments":{"actor":"O_bob"}},"id":1}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('error code:',d['error']['code'])"
# → error code: -32003
```

### 7. Schema-only stubs

The 3 deferred tools return the exact wire shape from the issue:

```bash
curl -sS -X POST http://127.0.0.1:8088/mcp \
  -H "authorization: Bearer demo-tok" \
  -H "x-agentkeys-actor: O_kevin_001" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"agentkeys.delegation.grant","arguments":{}},"id":1}' \
  | python3 -m json.tool
```

Expected error body:

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32000,
    "message": "not_implemented_in_v1",
    "data": {
      "error": "not_implemented_in_v1",
      "scheduled_for": "M4",
      "spec_url": "https://github.com/litentry/agentKeys/blob/main/docs/spec/plans/milestones-roadmap.md#m4"
    }
  },
  "id": 1
}
```

### 8. Tear down

Ctrl-C the server. No state to clean up — the in-memory backend dies with the process.

### What dev-mode does NOT prove

- The broker actually mints valid cap-tokens with the on-chain device-binding ceremony.
- The memory worker actually re-verifies cap signatures and decrypts S3 envelopes.
- The audit worker actually anchors the Merkle root on-chain inside the 2-min SLA.
- xiaozhi-server's Doubao / Qwen LLM actually decides to call the right tools at the right moments.

For those, see mode **B** below.

---

## B. Full xiaozhi-server + MagicLick demo (operator-driven)

> This is a **draft runbook**. The dev-mode demo (mode A) is fully validated by automated tests + hands-on smoke. Mode B requires a live broker deploy + MagicLick hardware + an LLM provider key — none of which can be reproduced inside the repo's test environment. **Verify each step on real hardware before merging refinements back here.**

### B.1 Topology

```
┌────────────────────┐    audio + WebSocket    ┌────────────────────────┐
│   MagicLick 2.5    │ ─────────────────────── │   xiaozhi-server       │
│   (xiaozhi-esp32   │                         │   (stock xinnan-tech)  │
│    firmware 1.9.4) │                         │                        │
└────────────────────┘                         │   MCP client →         │
                                               └───────────┬────────────┘
                                                           │ JSON-RPC over HTTP
                                                           ▼
                                              ┌────────────────────────┐
                                              │   agentkeys-mcp-server │
                                              │   --backend http       │
                                              └─────┬────────┬─────────┘
                                                    │        │
                                                    ▼        ▼
                                          ┌──────────────┐ ┌──────────────┐
                                          │ broker       │ │ memory       │
                                          │ + audit      │ │ + cred       │
                                          │   worker     │ │   worker     │
                                          └──────────────┘ └──────────────┘
                                                    │
                                                    ▼
                                          ┌──────────────────┐
                                          │ Heima parachain  │
                                          │ (chain anchor)   │
                                          └──────────────────┘
```

### B.2 Prerequisites (fresh laptop → demo, no shortcuts)

1. **AWS access** — `agentkeys-admin` profile, per [`docs/cloud-setup.md`](../../cloud-setup.md). Verify with `aws sts get-caller-identity --profile agentkeys-admin`.
2. **Heima chain access** — operator wallet funded on Heima mainnet (`AGENTKEYS_CHAIN=heima`). Required for broker boot + audit anchor.
3. **Operator workstation env** sourced: `set -a && source scripts/operator-workstation.env && set +a`.
4. **Foundry installed** for chain-side bring-up (`forge`, `cast`, `anvil`). Pin via `foundryup`.
5. **Docker** for the broker + worker images.
6. **ESP-IDF + esptool** for flashing MagicLick (xiaozhi-esp32 firmware build).
7. **LLM provider key**:
   - Doubao (Volcano Engine) — get from [console.volcengine.com](https://console.volcengine.com/) — recommended for the demo (matches Volcano Ark vendor pitch in #112).
   - Qwen — alternative; get from Alibaba Cloud Model Studio.
8. **A MagicLick 2.5 toy** (xiaozhi-esp32 v1.9.4 hardware). Without one, mode B falls back to the xiaozhi-server CLI client + a USB microphone.

### B.3 Stand up the chain + broker + workers

```bash
# One-command idempotent bring-up of contracts, master device, agent,
# scopes, K11, audit row. See CLAUDE.md "Heima chain (single entry point)".
AGENTKEYS_CHAIN=heima bash scripts/setup-heima.sh

# One-command broker host setup (binary install, systemd unit, nginx + TLS,
# audit-worker + memory-worker + cred-worker side by side). See CLAUDE.md
# "Remote broker host (single entry point)".
bash scripts/setup-broker-host.sh --upgrade

# Verify deployed contracts via read-only RPC (zero gas).
AGENTKEYS_CHAIN=heima bash scripts/verify-heima-contracts.sh
```

Outputs to capture for the next step:

- `BROKER_URL=https://broker.litentry.org`
- `MEMORY_WORKER_URL=https://memory.litentry.org`
- `AUDIT_WORKER_URL=https://audit.litentry.org`
- One actor omni (`O_kevin_001` or the actor produced by `heima-agent-register.sh`)
- Device key hash (`0x…` from `heima-device-register.sh` output)
- A signed vendor bearer token (mint via the M2 portal in production; for the demo, use a static value the broker recognizes)

### B.4 Deploy `agentkeys-mcp-server` next to the broker

The MCP server is one static binary. Deploy options:

- **Docker** (recommended for a clean prod-like demo):
  ```bash
  docker build -t agentkeys-mcp-server \
    -f crates/agentkeys-mcp-server/Dockerfile .

  docker run -d --name mcp \
    -p 8088:8088 \
    -e AGENTKEYS_BROKER_URL=https://broker.litentry.org \
    -e AGENTKEYS_MEMORY_URL=https://memory.litentry.org \
    -e AGENTKEYS_AUDIT_URL=https://audit.litentry.org \
    -e MCP_VENDOR_TOKENS="magiclick:$VENDOR_BEARER" \
    agentkeys-mcp-server
  ```
- **Systemd unit** on the broker host alongside the existing broker (smaller blast radius, same TLS termination via nginx). Reuse the pattern from `scripts/setup-broker-host.sh` — add a `mcp.service` clone, listen on `127.0.0.1:8088`, proxy via a new nginx server block `mcp.litentry.org`. **(Not yet automated — the script wires the broker + workers; this is a follow-up to land as a `--mcp` flag.)**

Smoke the deploy from outside the host:

```bash
curl -sS https://mcp.litentry.org/healthz
# → {"name":"agentkeys-mcp-server","ok":true}

curl -sS -X POST https://mcp.litentry.org/mcp \
  -H "authorization: Bearer $VENDOR_BEARER" \
  -H "x-agentkeys-actor: $ACTOR_OMNI" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}' \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)['result']['tools']),'tools')"
# → 10 tools
```

### B.5 Seed memory namespaces

The mock fixture from mode A was hardcoded. In production, namespaces are filled by user-driven memory writes through xiaozhi-server. To pre-seed for the demo, use `memory.put` directly:

```bash
for NS in travel family profile; do
  case $NS in
    travel)  CONTENT="Chengdu trip — Apr 12 to 16, hotpot at Yulin." ;;
    family)  CONTENT="Wife's bday Aug 3 (gift idea: hiking boots)." ;;
    profile) CONTENT="Allergic to shellfish. Prefers windowed flights." ;;
  esac

  curl -sS -X POST https://mcp.litentry.org/mcp \
    -H "authorization: Bearer $VENDOR_BEARER" \
    -H "x-agentkeys-actor: $ACTOR_OMNI" \
    -H "x-agentkeys-session-bearer: $SESSION_JWT" \
    -H "content-type: application/json" \
    -d "$(jq -n \
      --arg actor "$ACTOR_OMNI" \
      --arg ns "$NS" \
      --arg content "$CONTENT" \
      --arg op "$OPERATOR_OMNI" \
      --arg dkh "$DEVICE_KEY_HASH" \
      '{
        jsonrpc:"2.0",
        method:"tools/call",
        params:{
          name:"agentkeys.memory.put",
          arguments:{
            actor:$actor, namespace:$ns, content:$content,
            operator_omni:$op, device_key_hash:$dkh
          }
        },
        id:1
      }')"
done
```

Verify each landed by reading back:

```bash
for NS in travel family profile; do
  echo "--- $NS ---"
  curl -sS -X POST https://mcp.litentry.org/mcp \
    -H "authorization: Bearer $VENDOR_BEARER" \
    -H "x-agentkeys-actor: $ACTOR_OMNI" \
    -H "x-agentkeys-session-bearer: $SESSION_JWT" \
    -H "content-type: application/json" \
    -d "$(jq -n \
      --arg actor "$ACTOR_OMNI" \
      --arg ns "$NS" \
      --arg op "$OPERATOR_OMNI" \
      --arg dkh "$DEVICE_KEY_HASH" \
      '{
        jsonrpc:"2.0",
        method:"tools/call",
        params:{
          name:"agentkeys.memory.get",
          arguments:{
            actor:$actor, namespace:$ns,
            operator_omni:$op, device_key_hash:$dkh
          }
        },
        id:1
      }')" \
    | jq '.result.structuredContent.content'
done
```

### B.6 Clone + configure xiaozhi-server

xiaozhi-server is at https://github.com/xinnan-tech/xiaozhi-esp32-server. The version pinned by [`docs/research/xiaozhi-hermes-architecture.md`](../../research/xiaozhi-hermes-architecture.md) is the one with first-class MCP support — no fork needed.

```bash
git clone https://github.com/xinnan-tech/xiaozhi-esp32-server.git ~/code/xiaozhi-server
cd ~/code/xiaozhi-server
# Last verified against commit 7f73dae (2026-05); this is the commit
# whose mcp_client.py we inspected when writing this runbook. Pin via
# `git checkout 7f73dae` if you need byte-for-byte reproduction.
```

**Critical config rules** (verified against the upstream `mcp_client.py` at
commit `7f73dae` — `main/xiaozhi-server/core/providers/tools/server_mcp/mcp_client.py`):

1. **File path**: the runtime file is `main/xiaozhi-server/data/.mcp_server_settings.json`
   (note the leading `.` AND the `data/` prefix). The `mcp_server_settings.json`
   at the repo root is a template only and is NOT read at runtime.
2. **Transport**: include `"transport": "streamable-http"` explicitly. Default is `sse`;
   our server only implements POST `/mcp` (Streamable HTTP), not SSE.
3. **Headers**: every key under `headers` is forwarded by the client unchanged
   (`mcp.client.streamable_http.streamablehttp_client`), so `X-AgentKeys-Actor`
   and `X-AgentKeys-Session-Bearer` round-trip correctly.

Write `main/xiaozhi-server/data/.mcp_server_settings.json`:

```json
{
  "mcpServers": {
    "agentkeys": {
      "url": "https://mcp.litentry.org/mcp",
      "transport": "streamable-http",
      "headers": {
        "Authorization": "Bearer ${AGENTKEYS_VENDOR_BEARER}",
        "X-AgentKeys-Actor": "${AGENTKEYS_ACTOR_OMNI}",
        "X-AgentKeys-Session-Bearer": "${AGENTKEYS_SESSION_JWT}"
      }
    }
  }
}
```

**Protocol-level pre-flight (no LLM, no hardware needed):** before
booting the full xiaozhi-server, smoke the MCP wire with the same SDK
xiaozhi-server uses. `scripts/mcp-demo-mode-b-protocol.sh` runs the
official Anthropic `mcp` Python SDK (`streamablehttp_client`) against
our server and asserts:

- `initialize` handshake succeeds (server name + version)
- `tools/list` returns all 10 expected tools
- Acts 1/2/3 each return the storyboard-expected payload
- Schema-only stubs surface as proper `McpError` exceptions

```bash
bash scripts/mcp-demo-mode-b-protocol.sh
```

When this passes, xiaozhi-server's MCP client will work too — they share
the same SDK. The remaining failure modes are LLM tool-choice and
hardware audio, neither of which can be diagnosed at the MCP boundary.

The xiaozhi-server LLM provider config (Doubao or Qwen) goes in the server's main config — see xiaozhi-server's README for the exact path. For Doubao:

```yaml
llm:
  provider: doubao
  api_key: ${DOUBAO_API_KEY}
  model: doubao-pro-32k    # or whatever the current production model is
```

System prompt addition — tell the LLM about the AgentKeys tools so Act 2 lands cleanly:

```
You have access to AgentKeys MCP tools (agentkeys.*). For any payment or
spending action, you MUST call agentkeys.permission.check first. If the
result is verdict=deny, refuse the user politely and explain the daily
cap exceeded. For memory reads, scope by namespace; never assume the
device can read every namespace.
```

Start xiaozhi-server per its own README.

### B.7 Flash MagicLick 2.5

Get the xiaozhi-esp32 firmware that pairs with the server version you cloned (v1.9.4 per the strategy doc). Build + flash:

```bash
# from the xiaozhi-esp32 repo
idf.py set-target esp32s3
idf.py build
esptool.py --chip esp32s3 --port /dev/cu.usbserial-* write_flash ...
```

Configure the device's WiFi + the xiaozhi-server URL (via the on-device captive portal or pre-flashed nvs partition).

### B.8 Walk the three acts on hardware

Power on MagicLick. Press the talk button. Run each act:

1. **Act 1**: *"我这周末去哪里玩？"* (Where am I going this weekend?)
   - Expected: Doubao/Qwen calls `memory.get(namespace="travel")`, the MCP server fetches the Chengdu fixture, the LLM synthesizes a TTS reply naming Chengdu.
   - **Verify**: `tail -f /var/log/agentkeys-mcp-server.log` shows a single `memory.get` call with `namespace=travel`.
2. **Act 2**: *"帮我点 600 块的火锅"* (Order me 600 RMB of hotpot.)
   - Expected: LLM calls `permission.check(scope="payment.spend", amount_rmb=600)`, gets `verdict=deny`, refuses politely.
   - **Verify**: `tail -f /var/log/agentkeys-mcp-server.log` shows `permission.check` returning `daily_spend_cap_exceeded`. Parent-control UI (M4) shows the audit row in <1s.
3. **Act 3**: On the parent-control UI (when it lands per #111), revoke FoloToy payment access. User says *"再试一次"* (Try again). Same scope; this time `permission.check` returns deny with a revocation-flavored reason. (M1 has no revocation list yet; this act is the *demo of intent* — see plan §6.)

### B.9 What to capture for the vendor pitch

- A 15-second video of Act 1 (LLM names the city correctly).
- A 15-second video of Act 2 (LLM refuses politely; parent UI shows the audit row).
- A screenshot of the chain explorer with the audit anchor batch in the next 2-min window.
- Time-from-talk-button-press to LLM response — should be < 3 s for memory reads, < 1 s for permission checks.

### B.10 Tear down

```bash
docker stop mcp && docker rm mcp
# Broker + workers stay up — they're shared infra, don't pull them down
# unless you're decommissioning the whole environment.
```

### B.11 What's verified vs what still needs hardware

**Verified — automatable, no hardware:**

- ✅ MCP wire protocol compliance (`initialize` / `tools/list` / `tools/call` / error envelope) — `scripts/mcp-demo-mode-b-protocol.sh` drives the server with the same Anthropic Python SDK xiaozhi-server uses, asserting every act.
- ✅ xiaozhi-server's config file path + transport requirement — read from upstream source at commit `7f73dae`.
- ✅ Header pass-through (`X-AgentKeys-Actor`, `X-AgentKeys-Session-Bearer`) — code-traced through `mcp_client.py`.

**Operator-driven — needs hardware / external account / live deploy:**

- 🔌 LLM tool-choice (Doubao or Qwen actually deciding to call `permission.check` for "order me hotpot"). Tune the system prompt per §B.6.
- 🎤 MagicLick audio I/O (wake-word + STT + TTS round-trip). Test independently with xiaozhi-server's own diagnostic mode before adding AgentKeys.
- ☁️ Live broker + workers deployed via `scripts/setup-broker-host.sh` + `scripts/setup-heima.sh`.
- 💳 LLM provider account funded (Doubao/Qwen API key).

**Known gaps to fold back when you run it:**

- **Parent-control UI** (#111) is needed for Act 3's "parent revokes" gesture. Until #111 lands, simulate by calling `cap.revoke` via curl between the two prompts.
- **Live broker `/v1/revoke/cap/:id`** lands in M4. Until then, `cap.revoke` is a local stub on the MCP server — Act 3 demonstrates the *flow*, not the *cryptographic immediacy*.
- **Vendor token mint** is hand-edited into `MCP_VENDOR_TOKENS`. The vendor portal (#114, M2) replaces this with an issued + persisted token.
- **A `--mcp` flag on `scripts/setup-broker-host.sh`** to fold the MCP server deploy into the existing idempotent host setup. Tracked as follow-up.

---

## Where to file demo-specific bugs

- MCP server bug (this crate's code path) → issue on `litentry/agentKeys` labeled `area/mcp`.
- xiaozhi-server bug → upstream at `xinnan-tech/xiaozhi-esp32-server`.
- MagicLick firmware bug → upstream at `xiaozhi-esp32` repo.
- Broker / worker bug → `litentry/agentKeys` labeled `area/broker` / `area/worker`.

## See also

- [`docs/spec/plans/issue-107-mcp-server-phase1.md`](issue-107-mcp-server-phase1.md) — the canonical plan + landed-vs-deferred table for #107.
- [`docs/research/agent-iam-strategy.md`](../../research/agent-iam-strategy.md) §4.3 — the three-act demo storyboard.
- [`docs/research/xiaozhi-hermes-architecture.md`](../../research/xiaozhi-hermes-architecture.md) — why xiaozhi-server's stock MCP support means no fork needed.
- [`crates/agentkeys-mcp-server/README.md`](../../../crates/agentkeys-mcp-server/README.md) — server-side ops reference.
