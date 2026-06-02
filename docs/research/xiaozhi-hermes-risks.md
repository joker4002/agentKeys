# xiaozhi × Hermes integration — risk verification + mitigations

**Purpose**: verify the three risks called out in [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) against actual repo code (not assumptions), and document concrete mitigations grounded in the source. Companion to [`xiaozhi-esp32-magiclink.md`](./xiaozhi-esp32-magiclink.md) (hardware research + decision) and [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) (architecture diagrams).

**TL;DR (decision-grade)**

| Risk | Real? | Mitigation effort | Critical path? |
|---|---|---|---|
| **R1**: Hermes HTTP gateway stateless-vs-session | **Real but mitigation is built-in** | 2-4 hours | No |
| **R2**: Latency stack (Hermes adds 200ms+) | **Mostly not real** — learning loop is background, OFF turn path | 1 day (tune + measure) | No |
| **R3**: Concurrent device handling | **Less bad than feared** — Hermes IS multi-tenant in one process | 0 hours (v0); 1-2 weeks (prod scale) | No |
| **R4** (bonus, discovered during research) | **Cold agent construction per request adds 50-300ms** | 1 day (fork hack) or 2-4 days (upstream patch) | **Yes for voice UX** |

**Net effect on v0 timeline**: ~2-3 days of bridge work, not weeks. The 3-week estimate in [office-hours doc §9.7](./ai-hardware-companion-office-hours.md) was conservative; most of the integration points are already designed for the pattern we need. **Risk 4 is the most consequential unknown** — cold-start latency compounds turn-by-turn for a voice toy and warrants either an upstream patch or a fork-local agent pool.

---

## Risk 1 — Hermes HTTP gateway shape (stateless vs always-session)

### Verification (with citations)

**Risk is REAL but the mitigation is built-in.** Hermes-agent ships an OpenAI-compatible HTTP API server explicitly designed for stateless turns AND optional session continuation. Cross-contamination only happens if the integrator actively passes the same `X-Hermes-Session-Id` header from two devices — which we wouldn't do.

Evidence from `gateway/platforms/api_server.py` (3,524 LOC) in the [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) repo:

- `APIServerAdapter` class at line 631; routes registered at lines 3400–3423:
  ```
  GET  /v1/health, /v1/models, /v1/capabilities
  POST /v1/chat/completions           ← OpenAI-compatible
  POST /v1/responses                  ← OpenAI Responses API
  GET  /v1/responses/{response_id}
  POST /v1/runs                       ← Hermes-native run API
  GET  /v1/runs/{run_id}, /v1/runs/{run_id}/events
  ```

- Session handling at lines 1079–1135 has **three modes**:

  1. **Stateless per-call (default)** — when no `X-Hermes-Session-Id` header is sent, `_derive_chat_session_id()` at line 589 hashes `system_prompt + first_user_message` into a deterministic id. Two different `{system, user}` pairs land in two different sessions.
  2. **Explicit continuation** — sending `X-Hermes-Session-Id: <id>` loads history from `state.db` (lines 1118–1120). Requires `API_SERVER_KEY` auth (line 1097, returns 403 otherwise).
  3. **Long-term memory scoping** — `X-Hermes-Session-Key` header (lines 1080–1086) is independent and scopes Honcho per-channel state. Different devices should use different session keys.

- Each request calls `_create_agent()` at line 851, constructing a fresh `AIAgent` instance per call with the resolved `session_id`. There is no global mutable session state shared across devices unless the integrator opts in.

**Confirms**: the gateway is multi-tenant by design. It serves Telegram / Discord / Slack / WhatsApp / Signal simultaneously from one process (per the README); each platform adapter feeds its own session keys.

### Mitigation

For the xiaozhi bridge, integrate by setting per-device headers in the HTTP client:

```python
headers = {
    "Authorization": f"Bearer {HERMES_API_SERVER_KEY}",
    "X-Hermes-Session-Key": f"device-{esp32_mac}",        # scopes long-term memory
    "X-Hermes-Session-Id": f"chat-{esp32_mac}-{chat_id}", # scopes live transcript
}
```

xiaozhi already exposes the device MAC as `device-id` in its WebSocket URL query string (per `websocket_server.py` line 95), so mapping is trivial. No need to spin one Hermes process per device.

### Effort estimate

**2-4 hours.** Two header injections in the xiaozhi bridge's HTTP client + a config knob for `API_SERVER_KEY`.

---

## Risk 2 — Latency stack (Hermes overhead acceptable?)

### Verification

**Mostly NOT real.** The ~200ms Hermes overhead claim is plausible (in fact achievable) when running with a minimal toolset. The "5s+ if learning loop runs every turn" worry is killed by Hermes' design — the learning loop is intentionally moved OFF the turn path.

Evidence from `agent/conversation_loop.py` lines 4152–4162:

```python
# Background memory/skill review — runs AFTER the response is delivered
# so it never competes with the user's task for model attention.
if final_response and not interrupted and (_should_review_memory or _should_review_skills):
    agent._spawn_background_review(...)
```

The learning loop, Honcho user-model updates, and skill creation are explicitly background tasks. `final_response` is delivered first; review fires in a background task.

What stays on the turn path:
- Model API call (foundation LLM)
- Tool calls (if any toolset enabled)
- Prompt assembly + token bookkeeping (~30-80ms in Python)
- Session DB read for history (SQLite, ~5-20ms)
- Streaming SSE forwarding (zero added — pass-through)

So **~50-200ms is realistic for minimal-mode**; **300-800ms+** if `enabled_toolsets` includes anything that loads MCP servers or skill bundles at agent-create time (the `_create_agent` call at line 851 is cold per request — see Risk 4).

### Latency baselines (from xiaozhi-performance-research)

Real measured first-token / first-audio numbers from [xinnan-tech/xiaozhi-performance-research](https://github.com/xinnan-tech/xiaozhi-performance-research):

| Stage | Provider | First-token / first-audio |
|---|---|---|
| Streaming ASR | Xunfei | 0.795s |
| Streaming ASR | Doubao | 0.85s |
| LLM first-token | Qwen-Flash | 0.434s |
| LLM first-token | Kimi-K2 (Moonshot) | 0.774s |
| Streaming TTS | CosyVoice | 0.488s |
| Streaming TTS | Edge-TTS | 0.667s |
| Streaming TTS | local PaddleSpeech | 0.103s |

**Pipelined end-to-end (best case)**: Qwen-Flash + Doubao + CosyVoice = ~1.4s first-audio
**Pipelined end-to-end (Kimi)**: Kimi-K2 + Xunfei + Edge-TTS = ~2.2s first-audio

Adding 50-200ms Hermes overhead lands at **1.5-2.4s**, within the office-hours doc §Constraints "1.5-2.0s realistic floor" target. The 50ms AgentKeys memory fetch on loopback HTTP is realistic for an authenticated cap-token check against SQLite.

### Mitigation

- Set `enabled_toolsets: []` (empty) in `config.yaml` under `platform_toolsets.api_server` to skip MCP / skill loading on agent construction.
- Cap `HERMES_MAX_ITERATIONS=1` via env so the agent does single-shot completion (no tool-call loop on the turn path; default at line 887 is 90).
- Use streaming SSE (`stream: true` in OpenAI request body — already supported per line 1042) so the bridge can start TTS as soon as first token arrives.
- Pin the model to `qwen-flash` or `qwen-plus` via DashScope for lowest first-token latency in China; OpenRouter equivalents for global.

### Effort estimate

**1 day.** Config tuning + one round of stopwatch measurement on the bridge. Hermes' repo has `performance_tester_llm.py` reusable for the measurement loop. Implementation is hours; verification eats the day.

---

## Risk 3 — Concurrent device handling

### Verification

**Asymmetric, but less bad than the architecture doc implied.** Hermes IS multi-tenant inside one process; xiaozhi assumes high concurrent WebSocket connections per box. The handoff between them is fine for v0 demo and works for moderate production load.

**xiaozhi side** (from `xinnan-tech/xiaozhi-esp32-server`):
- `core/websocket_server.py` line 117 — every connection spawns an independent `ConnectionHandler`. No shared mutable state.
- `main/README.md` lines 112 + 134 — design: "asyncio-based concurrent WebSocket handling ... per-connection handler instance ensures multi-device state isolation."
- `core/connection.py` line 121 — caps blocking work at `ThreadPoolExecutor(max_workers=5)` PER CONNECTION (for sync ASR/TTS calls).
- **No documented hard ceiling on concurrent devices per process.** README mentions a 6-concurrent-user public demo but recommends streaming config for ">2 concurrent users."
- The "100+ devices per process in production by Chinese AI toy vendors" figure that circulated in earlier informal discussion is **unverified** by the repo. The xiaozhi-esp32-server README only documents the 6-concurrent demo; Tenclass is mentioned as providing "high-concurrency scenario reference" but without published numbers. Treat the actual concurrent-device ceiling as unknown until measured under realistic load.

**Hermes side**:
- Per-request `_create_agent()` (line 851) builds a fresh `AIAgent`. The gateway IS multi-tenant — README claims "Telegram, Discord, Slack, WhatsApp, Signal, and CLI — all from a single gateway process."
- Each in-flight chat completion holds:
  - A live `AIAgent` instance (model client, prompt builder, tool registry)
  - An asyncio task running `conversation_loop` (4,191 LOC file)
  - A streaming SSE queue
  - A session-db cursor
- **Per-active-request memory cost is plausibly 20-80MB** (skill bundle cache + tool registry + provider clients). 100 concurrent devices ≈ 2-8GB. Workable on one VPS, painful on a $5 one.
- **No documented "shared backend / pool" deployment pattern**; agents are constructed per-request, not pooled.
- **No documented "Hermes-as-library" import path** used by an external service; `from run_agent import AIAgent` works (line 876) but is not contract-stable.

### Mitigation

| Scale | Approach | Effort | Cost |
|---|---|---|---|
| v0 demo (1-3 devices) | Single Hermes process, default config | 0 hours | ~$5-10/mo cloud |
| Moderate (10-50 devices) | Single Hermes process tuned with `enabled_toolsets: []`, session DB on tmpfs, 2GB RAM | ~half day | ~$30-50/mo |
| Production (100+ devices/vendor) | N Hermes processes behind sticky-load-balanced ingress, sharded by `agentkeys_actor_omni` (cap-token in AgentKeys is the natural sharding key) | 1-2 weeks | scales with N |

The "Hermes-as-library" mitigation (import `AIAgent` and call its loop in-process from the Python bridge) is feasible but loses the SSE streaming infra you'd then need to reimplement. Not worth it for v0.

### Effort estimate

- v0 demo: **0 hours** — works out of the box
- Production scale: **1-2 weeks** for sticky-LB + per-process session DB partitioning + memory tuning + load testing

---

## Risk 4 — Cold agent construction per request (discovered during research)

This risk wasn't in the original three but surfaced while reviewing Risk 3. It's potentially the most impactful for voice UX.

### Verification

**Real and consequential for sub-second voice turns.** `_create_agent()` is called inside `_handle_chat_completions` for **every** incoming request (file: `gateway/platforms/api_server.py`, function entry line 1023, agent construction line 851). `AIAgent.__init__` (in `run_agent.py`) loads:

- Provider client + auth
- Toolset registry + MCP discovery (if any toolsets enabled)
- Session DB connection
- Reasoning config
- Fallback model chain

Hermes does not appear to pool agent instances across requests. For a voice toy that fires many sub-second turns, this adds a per-turn cold-start cost of approximately **50-300ms** on top of the network + LLM latencies in Risk 2.

Why this matters more than Risk 2: this is added latency on EVERY turn (not just first), and it compounds with the per-turn LLM + ASR + TTS budget. A 200ms cold-start cost pushes a 2.0s first-audio target into 2.2-2.5s territory consistently, and breaks the streaming illusion when the user is mid-conversation.

### Mitigation

Two paths, picked based on how stable Hermes' API contract is for the fork-local approach:

| Mitigation | Approach | Effort |
|---|---|---|
| **Fork-local hack** | Patch the api_server in our bridge fork to maintain `agent_pool: Dict[session_id, AIAgent]` with TTL. Reuse the agent across turns for the same `X-Hermes-Session-Id`. | **1 day** |
| **Upstream patch** | Open a PR to NousResearch/hermes-agent adding optional agent pooling behind a config flag (`api_server.enable_agent_pooling: true`). | **2-4 days** including review cycle |

The fork-local hack is cheaper but creates a maintenance fork burden. The upstream patch is the durable answer if NousResearch is responsive to PRs.

### Effort estimate

**1 day** (fork-local) or **2-4 days** (upstream).

---

## Net effect on the v0 plan

The original [issue #103 plan](../plan/issue-103-aiosandbox-hermes-esp32-demo.md) estimated 3 weeks for the demo. With these risk findings the integration is substantially smaller:

| Bridge work | Effort |
|---|---|
| Fork `xinnan-tech/xiaozhi-esp32-server` (Python) | ~1 hour |
| Replace LLM-caller module with Hermes HTTP client + AgentKeys memory fetch | ~half day |
| Configure session headers per device (Risk 1) | 2-4 hours |
| Tune `enabled_toolsets: []`, `HERMES_MAX_ITERATIONS=1`, streaming SSE (Risk 2) | 1 day |
| Optional agent pooling hack (Risk 4) | 1 day |
| Deploy to demo host with TLS | ~half day |
| End-to-end test + latency measurement | 1 day |
| **Total bridge work** | **~3-4 days** |

Plus parallel tracks:
- AgentKeys daemon's `/v1/memory/<actor>/profile.md` endpoint (issue #103 §C3) — half day
- S3 bucket provision + mock memory MD blob — 2 hours
- MagicLick device WiFi captive portal config → bridge URL — 30 min
- Demo runbook — half day

**Realistic v0 demo timeline: 1-2 weeks**, not 3.

The biggest remaining unknown is **the actual streaming-SSE flow from Hermes through the bridge to xiaozhi's WebSocket OPUS encoder** — Hermes streams SSE; xiaozhi expects OPUS frames over WebSocket. The bridge has to buffer text tokens, batch into TTS-friendly chunks (typically punctuation or sentence boundaries), call TTS, emit OPUS frames. This is solved in xinnan-tech's reference server; verify the streaming path survives the LLM-caller swap.

## Open questions for the bridge implementer

1. **Bridge → Hermes streaming**: does Hermes' `/v1/chat/completions` with `stream: true` produce real-time token deltas in standard OpenAI SSE format, or does it batch? Stopwatch this on day 1.
2. **AgentKeys memory invalidation**: when does the bridge re-fetch `/v1/memory/<actor>/profile.md`? Per turn (correct but slow if memory rarely changes) or cached with TTL? Recommendation: per-session-start fetch, refresh on a webhook signal from agentkeys-daemon when the memory file changes.
3. **TTS chunk boundary policy**: punctuation-driven (natural pauses, slightly higher latency) or token-count-driven (lower latency, less natural)? Test both on the MagicLick speaker; user perception is what matters.
4. **Hermes `API_SERVER_KEY` management**: this is a long-lived shared secret between the bridge and Hermes. Where does it live? Recommendation: in the AgentKeys daemon's credential vault, fetched on bridge startup; rotates with K3 epoch per the existing AgentKeys rotation plan.
5. **Fallback when Hermes is down**: should the bridge degrade to direct LLM call (xiaozhi baseline behavior) if Hermes returns 5xx? Or refuse to serve? Recommendation: degrade with a "memory unavailable" system prompt; log the degradation as an AgentKeys audit event.

## Sources cited (research agent verified)

- [`gateway/platforms/api_server.py`](https://github.com/NousResearch/hermes-agent/blob/main/gateway/platforms/api_server.py) (3,524 LOC) — lines 589 (`_derive_chat_session_id`), 631 (`APIServerAdapter`), 851 (`_create_agent`), 887 (max iterations), 1023 (`_handle_chat_completions`), 1042 (streaming SSE), 1080-1135 (session header handling), 3400-3423 (route table)
- [`agent/conversation_loop.py`](https://github.com/NousResearch/hermes-agent/blob/main/agent/conversation_loop.py) (4,191 LOC) — line 4152 (background-review-after-response)
- [`run_agent.py`](https://github.com/NousResearch/hermes-agent/blob/main/run_agent.py) — line 876 (`AIAgent` exposed for in-process imports)
- [NousResearch/hermes-agent README](https://github.com/NousResearch/hermes-agent) — multi-platform gateway claim
- [`xinnan-tech/xiaozhi-esp32-server/main/xiaozhi-server/core/websocket_server.py`](https://github.com/xinnan-tech/xiaozhi-esp32-server/blob/main/main/xiaozhi-server/core/websocket_server.py) — line 117 (per-connection `ConnectionHandler`)
- [`xinnan-tech/xiaozhi-esp32-server/main/xiaozhi-server/core/connection.py`](https://github.com/xinnan-tech/xiaozhi-esp32-server/blob/main/main/xiaozhi-server/core/connection.py) — line 121 (`ThreadPoolExecutor(max_workers=5)` per connection)
- [`xinnan-tech/xiaozhi-esp32-server/main/README.md`](https://github.com/xinnan-tech/xiaozhi-esp32-server/blob/main/main/README.md) — lines 112, 134 (asyncio + per-connection-handler design)
- [`xinnan-tech/xiaozhi-esp32-server/docs/readme/README_en.md`](https://github.com/xinnan-tech/xiaozhi-esp32-server/blob/main/docs/readme/README_en.md) — line 190 (6-concurrent demo), 207 (streaming for >2 concurrent), 220 (link to perf research)
- [xinnan-tech/xiaozhi-performance-research](https://github.com/xinnan-tech/xiaozhi-performance-research) — ASR / LLM / TTS first-token benchmarks

## Related

- [`xiaozhi-esp32-magiclink.md`](./xiaozhi-esp32-magiclink.md) — hardware research + Option 1 vs 2 decision
- [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) — architecture diagrams
- [`ai-hardware-companion-office-hours.md`](./ai-hardware-companion-office-hours.md) — wedge strategy
- [issue #103 plan](../plan/issue-103-aiosandbox-hermes-esp32-demo.md) — implementation plan
