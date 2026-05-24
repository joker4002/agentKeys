# Volcano Ark MCP-server integration — architecture reference

**Purpose**: permanent reference for how AgentKeys integrates with Volcano Ark (ByteDance's enterprise AI platform) as an above-the-rail MCP-server adapter. Companion to [`tuya-vs-xiaozhi.md`](./tuya-vs-xiaozhi.md) (Phase 3a verdict: VERIFIED FEASIBLE) and [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) (the sibling adapter for the xiaozhi path).

## TL;DR

- **Volcano Ark** = ByteDance's enterprise AI cloud. Hosts Doubao LLM family + Volcengine RTC (real-time audio) + an **MCP-server marketplace** launched 2026. ~49% of China's MaaS market.
- **Integration shape**: AgentKeys runs a hosted MCP server at e.g. `mcp.agentkeys.io`, registers it in Volcano Ark's marketplace. Vendor agents (Doubao-powered hardware like FoloToy's "Eye-Catching Bag") enable the AgentKeys tool. When the agent needs identity / memory / credentials / audit, it calls our MCP tool.
- **What we build**: one MCP server (~1 week of work) exposing 5-7 tools that proxy to existing AgentKeys backend services. No new backend code needed.
- **Why it matters**: Volcano Ark is the AI-platform-side peer to Tuya (which is IoT-device-side). Tuya owns provisioning/OTA/telemetry; Volcano owns LLM inference/agent runtime. AgentKeys above both → any AI hardware running on Doubao gets identity + memory + portability with zero firmware change.
- **Cross-vendor composition**: a user with both a FoloToy (Doubao via Volcano Ark + our MCP server) and a MagicLick (xiaozhi firmware via our Hermes bridge) gets the same memory namespace, same identity, same audit ledger across both devices — the cross-vendor portability moat is automatic.

## What is Volcano Ark + MCP-server

[Volcano Engine](https://www.volcengine.com/) is ByteDance's enterprise cloud, [Volcano Ark](https://ark.volcengine.com/) is its AI platform. Hosts:

- **Doubao LLM family** (text, image Seedream, video Seedance) — ~19 active SKUs in 2026
- **Volcengine RTC** (real-time audio/video for voice agents)
- **MCP Servers Marketplace** (launched 2026 — third parties publish MCP-protocol-compatible tools that any Doubao agent can call)

The MCP marketplace is open to international developer accounts (no PRC entity / ICP needed) per [Doubao International Access Guide 2026](https://tokenmix.ai/blog/doubao-api-international-access-guide-2026). Third-party MCP servers are listed at [mcp.so/server/mcp-server/volcengine](https://mcp.so/server/mcp-server/volcengine).

### MCP primer (60 seconds)

[Model Context Protocol](https://modelcontextprotocol.io) — open standard from Anthropic. An MCP server exposes:
- **Tools** — functions the LLM can call (with JSON-schema arguments + structured return)
- **Resources** — read-only data the LLM can fetch
- **Prompts** — templated prompts the LLM can pick from

An MCP client (the LLM-orchestration layer — Claude Desktop, ChatGPT, Doubao agent runtime, etc.) discovers tools and forwards them to the LLM as available actions. The LLM decides when to call a tool; the client executes the call against the MCP server and returns results to the LLM. Transports: stdio (local), SSE/HTTP (remote), WebSocket.

For Volcano Ark integration: we run a remote MCP server (HTTP/SSE) at `mcp.agentkeys.io`; Doubao agents configured by Volcengine customers connect to it.

## Integration shape — Pattern B (hosted by us)

There are two ways to integrate with an MCP marketplace:

| Pattern | Where the MCP server runs | Pros | Cons | Used by |
|---|---|---|---|---|
| **A** — Upload tool code to marketplace | Marketplace hosts our code | No infra to run | Marketplace controls execution; lose flexibility, lose direct backend access | Less common |
| **B** — Run hosted server, register URL in marketplace | We run the MCP server; marketplace is discovery only | Full control, direct backend access, can authenticate per-tenant | Need to operate infra | Standard for any non-trivial integration |

**We pick Pattern B.** AgentKeys MCP server runs in our infra (existing aiosandbox container or a dedicated Rust/Python service), authenticates incoming requests per-tenant via cap-tokens, and proxies to existing AgentKeys backend services.

## Diagram A — High-level architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Vendor AI hardware device                                  │
│  e.g., FoloToy plushie, AI pendant, AI glasses              │
│  • Audio mic + speaker                                      │
│  • Connects to Volcengine RTC                               │
│  • No knowledge of AgentKeys (zero firmware changes)        │
└──────────────────────────┬──────────────────────────────────┘
                           │ Volcengine RTC (audio transport)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Volcengine cloud (ByteDance)                               │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ Doubao agent runtime                                │    │
│  │  • Doubao LLM (text + multimodal)                   │    │
│  │  • Built-in STT + TTS                               │    │
│  │  • MCP CLIENT (calls registered tools when LLM      │    │
│  │    decides one is needed)                           │    │
│  │  • Vendor configures: which MCP servers to enable   │    │
│  └─────────────────────────┬───────────────────────────┘    │
│                            │                                │
│  ┌─────────────────────────┴───────────────────────────┐    │
│  │ Volcano Ark MCP marketplace (discovery)             │    │
│  │  • Lists registered MCP servers                     │    │
│  │  • AgentKeys appears here for vendor opt-in         │    │
│  │  • Vendor adds AgentKeys to their agent's enabled   │    │
│  │    toolsets in the Doubao agent console             │    │
│  └─────────────────────────────────────────────────────┘    │
└──────────────────────────┬──────────────────────────────────┘
                           │ MCP protocol (HTTPS, SSE streaming)
                           │ POST mcp.agentkeys.io/v1/tools/call
                           │ Authorization: Bearer <vendor-mcp-token>
                           │ X-AgentKeys-Actor: <O_kevin_folotoy_001>
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  AgentKeys MCP server  ★ NEW ★ (~1 week to build)           │
│  Hosted by us at mcp.agentkeys.io                           │
│  Registered in Volcano Ark marketplace                      │
│  ─────────────────────────────────────────────────────────  │
│  MCP-protocol tools exposed:                                │
│   • agentkeys.memory.get(actor, namespace)                  │
│   • agentkeys.memory.put(actor, namespace, content)         │
│   • agentkeys.cred.fetch(actor, service)                    │
│   • agentkeys.cap.mint(actor, operation, params)            │
│   • agentkeys.audit.append(actor, event)                    │
│   • agentkeys.identity.whoami(actor)                        │
│   • agentkeys.permission.check(actor, scope)                │
└──────────────────────────┬──────────────────────────────────┘
                           │ Internal HTTPS / gRPC
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  AgentKeys backend (Stage 7+ stack, UNCHANGED)              │
│  ─────────────────────────────────────────────────────────  │
│  • agentkeys-broker-server (cap-token issuance + verify)    │
│  • signer (K3 / K10 HDKD per arch.md §17)                   │
│  • agentkeys-worker-memory (S3 bots/<actor>/memory/*)       │
│  • agentkeys-worker-creds (S3 vault, per-actor isolation)   │
│  • agentkeys-worker-audit (off-chain + Heima anchoring)     │
│  • agentkeys-daemon (existing memory endpoint per issue #103)│
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
                  ┌──────────────────┐
                  │ AWS S3, Heima    │
                  │ chain, etc.      │
                  └──────────────────┘
```

**Properties**:
- Vendor device firmware unchanged — same as the xiaozhi pattern. The integration sits entirely in the cloud-side agent loop.
- Vendor opts in via the Doubao agent console (add AgentKeys MCP server to enabled toolsets — typically a one-checkbox config in Volcengine's console).
- Per-vendor authentication via `Bearer <vendor-mcp-token>` issued by us at onboarding.
- Per-actor scoping via `X-AgentKeys-Actor` header — vendor agent passes the device's AgentKeys actor omni on every tool call.

## Diagram B — Per-call MCP tool sequence

User says: *"Where am I going this weekend?"*

```
FoloToy   Volcengine RTC   Doubao Agent    AgentKeys MCP   AgentKeys Backend
  │           │                 │                 │                │
  ├ audio ──▶ │                 │                 │                │
  │           ├ STT → text ────▶│                 │                │
  │           │                 │  "where am I going this weekend?"│
  │           │                 │                 │                │
  │           │                 │ LLM step 1: decide tool needed   │
  │           │                 │ (Doubao thinks: "need memory")   │
  │           │                 │                 │                │
  │           │                 ├── MCP /tools/call ────────────▶ │
  │           │                 │   tool: agentkeys.memory.get    │
  │           │                 │   args: {actor: O_kevin_001,    │
  │           │                 │          namespace: "profile"}  │
  │           │                 │   headers: Authorization,       │
  │           │                 │            X-AgentKeys-Actor    │
  │           │                 │                 │                │
  │           │                 │                 │ verify         │
  │           │                 │                 │ vendor-mcp-    │
  │           │                 │                 │ token          │
  │           │                 │                 │                │
  │           │                 │                 │ mint scoped    │
  │           │                 │                 │ cap-token for  │
  │           │                 │                 │ memory.read    │
  │           │                 │                 ├──────────────▶│
  │           │                 │                 │ broker verifies│
  │           │                 │                 │ cap, calls     │
  │           │                 │                 │ memory worker  │
  │           │                 │                 │ → S3 GET       │
  │           │                 │                 │◀── profile.md ─┤
  │           │                 │◀── tool result ─┤                │
  │           │                 │   { content: "Kevin, planning   │
  │           │                 │     Chengdu trip May 25-29..." }│
  │           │                 │                 │                │
  │           │                 │ LLM step 2: synthesize response  │
  │           │                 │   (Doubao with memory context)   │
  │           │                 │                 │                │
  │           │                 │ LLM step 3: decide audit needed  │
  │           │                 ├── MCP /tools/call ────────────▶ │
  │           │                 │   tool: agentkeys.audit.append  │
  │           │                 │   args: {actor: O_kevin_001,    │
  │           │                 │          event: "memory.read",  │
  │           │                 │          namespace: "profile"}  │
  │           │                 │                 ├──────────────▶│
  │           │                 │                 │ audit worker   │
  │           │                 │                 │ appends event  │
  │           │                 │◀── ok ──────────┤                │
  │           │                 │                 │                │
  │           │                 │ Final LLM output (text response) │
  │           │◀── text ────────┤                 │                │
  │           ├ TTS → audio     │                 │                │
  │◀ audio ───┤                 │                 │                │
  ├ play ──▶  │                 │                 │                │
```

**Properties**:
- Tool calls are part of Doubao's normal agent loop — Doubao's LLM decides when to call (no orchestration by us).
- Each tool call is an authenticated HTTPS request from Volcengine cloud to our MCP server.
- Our MCP server mints a fresh scoped cap-token per call against the AgentKeys broker (reuses existing infra, no new auth code).
- Audit happens automatically because our MCP server appends a row on every memory/cred operation, regardless of whether the LLM explicitly asks for it.

### Latency budget per tool call

| Stage | Latency | Notes |
|---|---|---|
| MCP request from Volcengine → us | ~50-150ms | Geographic dependent (HK/SG → us-east-1) |
| Vendor token auth | ~5ms | JWT verify, cached |
| Cap-token mint | ~30ms | broker round-trip |
| Backend op (S3 GET / cred fetch / audit append) | ~50-100ms | S3 latency dominant |
| MCP response back to Volcengine | ~50-150ms | Same geographic dependency |
| **Total per tool call** | **~200-400ms** | |

For a voice turn with 1 memory read + 1 audit append, total MCP overhead = ~400-800ms. Streamed back to user audio adds to the Doubao first-token latency. **Concern**: if Doubao agents do many tool calls per turn, latency stacks fast. **Mitigation**: cache memory in Doubao's session context (Doubao should re-use the memory.get result across turns within a session); batch audit appends.

## Diagram C — Cross-vendor composition (the moat in action)

Kevin owns two devices from two different vendors. Both terminate at AgentKeys.

```
       Kevin's identity root: O_kevin (HDKD-derived, AgentKeys-owned)
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                            │
   O_kevin_folotoy_001                       O_kevin_magiclick_001
   (per-device actor)                        (per-device actor)
        │                                            │
        ▼                                            ▼
┌──────────────────┐                        ┌──────────────────┐
│ FoloToy plushie  │                        │ MagicLick 2.5    │
│ (Doubao + RTC)   │                        │ (xiaozhi-esp32)  │
└────────┬─────────┘                        └────────┬─────────┘
         │                                            │
         │ RTC audio                                  │ WebSocket OPUS
         ▼                                            ▼
┌──────────────────┐                        ┌──────────────────┐
│ Volcengine cloud │                        │ xiaozhi-hermes-  │
│ Doubao agent     │                        │ bridge (our fork)│
└────────┬─────────┘                        └────────┬─────────┘
         │ MCP                                        │ HTTP
         │ (Doubao calls                              │ (Hermes calls
         │  AgentKeys tools)                          │  AgentKeys daemon)
         ▼                                            ▼
   ┌────────────────────────────────────────────────────────┐
   │ AgentKeys MCP server          AgentKeys daemon         │
   │ (Volcano Ark adapter)         (xiaozhi-hermes adapter) │
   └─────────────────────────┬──────────────────────────────┘
                             │
                             ▼
                  ┌──────────────────────┐
                  │ AgentKeys backend    │
                  │ ─────────────────    │
                  │ ONE memory namespace │
                  │   bots/O_kevin/      │
                  │   memory/profile.md  │
                  │                      │
                  │ ONE identity tree    │
                  │   K3 → K10 HDKD      │
                  │                      │
                  │ ONE audit ledger     │
                  │   off-chain + Heima  │
                  └──────────────────────┘
```

**The cross-vendor moat materializes automatically**: Kevin's profile updates from a conversation on his FoloToy are read by his MagicLick on the very next interaction (or vice versa). Neither vendor sees the other's existence. No coordination needed — both vendors just point at AgentKeys' standard endpoints. Identity, memory, audit, permission scoping all flow through the same backend.

This is the architectural property that makes vendors willing to integrate: their users gain a feature (memory portability) they cannot offer alone, and our pricing model (vendor pays per-device, 30% acquirer-revshare on consumer upgrade per office-hours doc §9.3) keeps the per-vendor economics sound.

## AgentKeys MCP tool inventory

Initial v0 tools (~5 tools). Map cleanly to existing AgentKeys backend operations.

| Tool name | Purpose | Backend mapping | Returns |
|---|---|---|---|
| `agentkeys.memory.get` | Fetch user memory in a namespace | broker mint(memory.read) → memory-worker S3 GET | Markdown content + metadata |
| `agentkeys.memory.put` | Store / update user memory | broker mint(memory.write) → memory-worker S3 PUT | Confirmation + version |
| `agentkeys.cred.fetch` | Fetch credential for a third-party service (e.g., Spotify, Gmail) | broker mint(cred.fetch) → cred-worker S3 GET + decrypt | Decrypted credential |
| `agentkeys.cap.mint` | Mint a scoped cap-token for an arbitrary op | broker mint() | Cap-token (signed) |
| `agentkeys.audit.append` | Append audit event | audit-worker append | Confirmation |
| `agentkeys.identity.whoami` | Get identity info for an actor | broker actor lookup | `{omni, display_name, vendor, scopes[]}` |
| `agentkeys.permission.check` | Check if actor has scope for an op (without performing it) | broker scope check | `{allowed: bool, reason?: string}` |

Tools follow the MCP JSON-schema convention. Arguments validated server-side. Errors returned as MCP-protocol error objects with structured codes (`agentkeys.cap.revoked`, `agentkeys.memory.namespace_not_found`, etc.).

## What we build vs what's free

| Layer | Status | Notes |
|---|---|---|
| AgentKeys backend (broker, signer, workers) | ✅ Exists | Stage 7+ shipped per CLAUDE.md |
| `agentkeys-daemon /v1/memory` endpoint | 🛠 In flight | Per issue #103 §C3 |
| MCP server framework (transport, schema, auth) | ✅ Free | Use Anthropic's `mcp` SDK or a Rust equivalent |
| AgentKeys MCP server (tool implementations) | 🆕 NEW | ~1 week — thin layer over backend RPCs |
| Volcano Ark marketplace registration | 🆕 NEW | ~half day — fill out forms, get listed |
| Vendor onboarding (token issuance, billing) | 🆕 NEW (but small) | ~2 days — reuses AgentKeys vendor billing per office-hours §9.3 |
| Hosting infra (TLS, scaling, monitoring) | 🆕 NEW | ~2 days — same pattern as aiosandbox |
| **Total effort to ship Phase 3a** | | **~1-1.5 weeks** |

## Effort estimate

Following the same effort-breakdown style as [`xiaozhi-hermes-risks.md`](./xiaozhi-hermes-risks.md):

| Task | Effort |
|---|---|
| Pick MCP SDK (Python `mcp` vs Rust `mcp-rs` vs Go `mcp-go`) | ~1 hour |
| Scaffold MCP server with 5-7 tool stubs | ~half day |
| Wire each tool to existing AgentKeys backend RPC | ~half day per 2-3 tools = 1-1.5 days |
| Vendor auth (Bearer token) + per-actor scoping (X-AgentKeys-Actor) | ~half day |
| Register in Volcano Ark marketplace (forms + listing copy) | ~half day |
| Deploy to demo host with TLS at mcp.agentkeys.io | ~half day |
| End-to-end test: configure a Doubao agent to use our MCP server, verify tool calls hit our backend | 1 day |
| Demo runbook + integrator docs (how a vendor enables AgentKeys on their Doubao agent) | ~half day |
| **Total** | **~1-1.5 weeks** |

Same shape as the xiaozhi-hermes-bridge effort — one new service, thin layer over existing backend.

## Risks + open questions

1. **MCP tool calls per turn — latency stacking**: if Doubao agents call multiple tools per turn (memory.get + cred.fetch + audit.append), total MCP overhead can hit ~1s. Need to measure and possibly batch via a coarser-grained `agentkeys.context.bootstrap` tool that returns memory + identity + relevant creds in one call. **Open**: design the batched tool after measuring real Doubao call patterns.

2. **Volcano Ark marketplace approval process**: research showed the marketplace is open to international developers, but the actual listing review process / SLA isn't documented publicly. Could be days, could be weeks. **Mitigation**: start the registration process in parallel with the MCP server build so it's done by ship time.

3. **Per-tenant authentication model**: do we issue one bearer token per Volcengine customer, or per Volcengine project, or per registered Doubao agent? Each has different revocation / billing implications. **Open**: pick model after talking to first Volcengine customer (likely FoloToy).

4. **Actor omni resolution**: the Doubao agent needs to know the user's AgentKeys actor omni to pass as `X-AgentKeys-Actor`. How does the device-to-actor mapping happen? Two patterns:
   - **(a)** Vendor enrolls device in AgentKeys at provisioning time, gets back `O_<vendor>_<device_id>`, stores it in their device DB, passes to Doubao agent via prompt context.
   - **(b)** Doubao agent calls `agentkeys.identity.whoami(vendor_device_id)` first to resolve. Adds one tool call per session.
   Pattern (a) is faster but requires vendor-side state. Pattern (b) is stateless but adds latency. **Open**: pick after vendor conversation.

5. **MCP protocol version**: MCP is young (Anthropic released v1 in late 2024). What version does Volcengine's Doubao agent runtime support? **Mitigation**: check during marketplace registration; build to the latest stable spec and downgrade if needed.

6. **Cross-vendor cap-token consent**: when a Doubao agent (FoloToy actor) calls `agentkeys.memory.put` to update Kevin's profile, and his MagicLick later reads it via the xiaozhi-hermes bridge — does that require Kevin's per-vendor consent toggle (per office-hours doc §Cross-Vendor Memory Model)? **Answer**: yes — the cross-vendor consent ceremony in the office-hours doc applies. Both adapters enforce the same consent model.

## How this composes with the xiaozhi-hermes bridge

The two adapters are siblings — same backend, different upstream rails.

| | Volcano Ark adapter (this doc) | xiaozhi-hermes bridge |
|---|---|---|
| Upstream protocol | MCP over HTTPS/SSE | xiaozhi WebSocket + OPUS |
| Upstream runtime | Doubao agent (Volcengine-hosted) | Hermes-agent (us-hosted in aiosandbox) |
| Vendor device types | Any Doubao-powered AI hardware | xiaozhi-firmware ESP32 devices |
| Vendor onboarding | Marketplace listing + console toggle | Bridge URL config in device captive portal |
| Effort to ship | ~1-1.5 weeks | ~1-2 weeks |
| Status | Planned (Phase 3a) | In progress (issue #103) |

Both terminate at the same AgentKeys backend. Both honor the same cross-vendor consent ceremony. Both can be operational on the same user's account simultaneously. This is exactly the "above-the-rail adapter pattern" that the office-hours doc §Cross-Vendor Memory Model called for.

## References

- [Volcano Engine MCP Servers launch (AIBase)](https://www.aibase.com/news/18171) — 2026 marketplace launch
- [Volcano Engine MCP server (mcp.so)](https://mcp.so/server/mcp-server/volcengine) — third-party MCP tool catalog
- [Doubao International Access Guide 2026 (TokenMix)](https://tokenmix.ai/blog/doubao-api-international-access-guide-2026) — international signup verified
- [EMQX + Volcano Engine RTC voice-agent integration](https://docs.emqx.com/en/emqx/latest/emqx-ai/rtc-services/volcengine-rtc/quick-start.html) — working third-party RTC voice-agent recipe
- [Model Context Protocol spec](https://modelcontextprotocol.io) — Anthropic's MCP standard
- [MCP server SDKs](https://modelcontextprotocol.io/quickstart/server) — Python, TypeScript, Rust, Go reference implementations

## Related research

- [`tuya-vs-xiaozhi.md`](./tuya-vs-xiaozhi.md) — Phase 3a verdict (VERIFIED FEASIBLE)
- [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) — sibling adapter architecture (xiaozhi path)
- [`xiaozhi-hermes-risks.md`](./xiaozhi-hermes-risks.md) — risk-verification pattern that informed this doc's risk section
- [`ai-hardware-companion-office-hours.md`](./ai-hardware-companion-office-hours.md) — original Approach D + cross-vendor consent model
- [issue #103 plan](../spec/plans/issue-103-aiosandbox-hermes-esp32-demo.md) — xiaozhi-side implementation
