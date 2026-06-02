# xiaozhi-esp32 × Hermes-agent × AgentKeys — architecture reference

**Purpose**: permanent reference for the Option 1 integration model that links the MagicLick 2.5 / xiaozhi-esp32 firmware to NousResearch Hermes-agent via a cloud-side bridge, with AgentKeys providing memory + identity. Companion to [`xiaozhi-esp32-magiclink.md`](./xiaozhi-esp32-magiclink.md) (hardware research, decision rationale) and [`xiaozhi-hermes-risks.md`](./xiaozhi-hermes-risks.md) (risk verification + mitigations).

**Use this doc when**: you're explaining the architecture to a teammate / a vendor / a partner, or when you need to remember exactly which layer changes vs. which layer stays the same.

## How to read

Three diagrams, top to bottom:
- **A**: original xiaozhi-esp32 flow (the baseline every xiaozhi user has today)
- **B**: our pivoted flow with changed layers called out
- **C**: per-turn sequence + latency budget for one voice interaction

After the diagrams, a precise diff table of what changes vs. baseline. The big takeaway: **the actual code change is concentrated in one module of one server fork**. Everything else is upstream code we use as-is.

---

## Diagram A — Original xiaozhi-esp32 flow (baseline)

```
┌─────────────────────────────────────────────────────────────┐
│  MagicLick 2.5 device                                       │
│  • xiaozhi-esp32 v1.9.4 firmware                            │
│  • ES8311 mic → OPUS encode                                 │
│  • OPUS decode → ES8311 speaker                             │
│  • Wake-word (ESP-SR) starts session                        │
│  • 128×128 LCD shows state                                  │
└──────────────────────────┬──────────────────────────────────┘
                           │ WebSocket
                           │ wss://api.xiaozhi.me/ws  (default xiaozhi cloud)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  xiaozhi cloud server (xinnan-tech reference, or xiaozhi.me)│
│  ─────────────────────────────────────────────────────────  │
│   1. Receive OPUS frames                                    │
│   2. OPUS → PCM → ASR (FunASR/DashScope) → transcript       │
│   3. transcript → LLM API call → text response              │
│   4. text → TTS (CosyVoice/Edge-TTS) → PCM                  │
│   5. PCM → OPUS → stream back to device                     │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTPS
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Foundation LLM API                                         │
│  Kimi / Claude / DashScope-Qwen / DeepSeek / OpenAI / etc.  │
└─────────────────────────────────────────────────────────────┘
```

**Properties of the baseline**:
- Stateless across turns (no persistent memory)
- No identity / no permission scoping / no audit
- No cross-device or cross-vendor anything
- The xiaozhi cloud server is essentially an audio ↔ LLM relay

---

## Diagram B — Our pivoted flow (Option 1)

```
┌─────────────────────────────────────────────────────────────┐
│  MagicLick 2.5 device       ★★ UNCHANGED FIRMWARE ★★        │
│  • xiaozhi-esp32 v1.9.4 (same)                              │
│  • Same OPUS audio, same wake-word, same display            │
└──────────────────────────┬──────────────────────────────────┘
                           │ WebSocket (xiaozhi protocol, UNCHANGED)
                           │ ★ NEW URL: wss://demo.agentkeys.io/ws ★
                           │   (configured via device's WiFi captive portal —
                           │    one-time, no firmware change)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  ┌─── aiosandbox container (supervisord PID 1) ─────────┐   │
│  │                                                      │   │
│  │ ┌──────────────────────────────────────────────────┐ │   │
│  │ │ xiaozhi-hermes-bridge  ★ NEW (Python fork) ★     │ │   │
│  │ │ Forked from xinnan-tech/xiaozhi-esp32-server     │ │   │
│  │ │ ───────────────────────────────────────────────  │ │   │
│  │ │ 1. Receive OPUS                  ← copy-paste    │ │   │
│  │ │ 2. ASR (FunASR/DashScope) → text ← copy-paste    │ │   │
│  │ │ 3. ┌── CHANGED ─────────────────────────────┐    │ │   │
│  │ │    │ (a) GET memory from AgentKeys daemon  │    │ │   │
│  │ │    │ (b) Build prompt: memory + transcript │    │ │   │
│  │ │    │ (c) POST turn to Hermes-agent gateway │    │ │   │
│  │ │    │ (d) Receive text response             │    │ │   │
│  │ │    └───────────────────────────────────────┘    │ │   │
│  │ │ 4. TTS → PCM                     ← copy-paste    │ │   │
│  │ │ 5. PCM → OPUS → stream back      ← copy-paste    │ │   │
│  │ └────┬─────────────────────────┬───────────────────┘ │   │
│  │      │ HTTP (loopback)         │ HTTP (loopback)     │   │
│  │      ▼                         ▼                     │   │
│  │ ┌────────────────────┐  ┌────────────────────────┐   │   │
│  │ │ agentkeys-daemon   │  │ Hermes-agent           │   │   │
│  │ │ (Rust, existing    │  │ (NousResearch, Python, │   │   │
│  │ │  extended w/ one   │  │  installed via official│   │   │
│  │ │  GET endpoint)     │  │  installer script)     │   │   │
│  │ │ ───────────────    │  │ ─────────────────────  │   │   │
│  │ │ GET /v1/memory/    │  │ • Self-improving loop  │   │   │
│  │ │  <actor>/profile.md│  │ • Skill creation       │   │   │
│  │ │ → S3 fetch         │  │ • FTS5 session search  │   │   │
│  │ │ → return MD body   │  │ • LLM-agnostic model   │   │   │
│  │ └────────┬───────────┘  │   selection            │   │   │
│  │          │              └───────────┬────────────┘   │   │
│  └──────────┼──────────────────────────┼────────────────┘   │
│             ▼                          │ HTTPS              │
│  ┌────────────────────────────┐        ▼                    │
│  │ S3: mock memory blob       │  ┌──────────────────────┐   │
│  │ s3://agentkeys-demo-memory │  │ Foundation LLM API   │   │
│  │  /bots/<actor>/memory/     │  │ Kimi / Claude /      │   │
│  │  profile.md                │  │ DashScope-Qwen / ... │   │
│  └────────────────────────────┘  └──────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## What actually changes (precise diff)

| Layer | Original | Ours | Changed? |
|---|---|---|---|
| MagicLick firmware | xiaozhi-esp32 v1.9.4 | xiaozhi-esp32 v1.9.4 | **No** |
| Audio pipeline (mic, speaker, OPUS) | ES8311 → OPUS over WS | same | **No** |
| Wake-word | offline ESP-SR | same | **No** |
| LCD display | emoji rendering | same | **No** |
| Cloud server URL on device | `wss://api.xiaozhi.me/ws` | `wss://demo.agentkeys.io/ws` | **URL only** |
| Cloud server code | xinnan-tech reference (or xiaozhi proprietary) | `xiaozhi-hermes-bridge` (fork) | **Replace LLM-caller module** |
| ASR | FunASR / DashScope ASR | same (reused from fork) | **No** |
| TTS | CosyVoice / Edge-TTS | same (reused from fork) | **No** |
| LLM caller | `call_llm(transcript)` direct API | `call_hermes(memory + transcript)` | **YES** |
| Memory layer | none | AgentKeys daemon → mock S3 blob | **NEW** |
| Identity / actor | basic device ID | AgentKeys HDKD actor (mock for v0) | **NEW** |
| Audit | none | AgentKeys off-chain (v0) | **NEW** |
| Foundation LLM | Kimi / Claude / Qwen / etc. | same (called via Hermes' model layer) | **No** |

**The actual code change is concentrated in one module of the bridge fork**: replace the function that calls the LLM directly with one that goes through Hermes-agent + injects AgentKeys memory. Everything else is upstream from xiaozhi's reference server, used as-is.

---

## Diagram C — Per-turn sequence (one voice interaction)

User says: *"Where am I going this weekend?"*

```
MagicLick    Bridge          AgentKeys       Hermes          LLM (Kimi/Claude)
  │            │                 │              │                  │
  ├ wake───▶   │                 │              │                  │
  ├ OPUS ──▶   │                 │              │                  │
  │            ├ decode OPUS     │              │                  │
  │            ├ ASR (FunASR)    │              │                  │
  │            │  ↓ "where am I going this weekend?"               │
  │            │                 │              │                  │
  │            ├─ GET /v1/memory/<actor>/profile.md ──▶            │
  │            │                 ├─ S3 GET ───▶│                  │
  │            │                 │◀─ profile.md │                  │
  │            │◀── profile.md ──┤              │                  │
  │            │   ("Kevin, planning Chengdu trip May 25-29,       │
  │            │    spicy food, ¥500/day cap, family in Hangzhou") │
  │            │                 │              │                  │
  │            ├── POST /turn ────────────────▶│                  │
  │            │   { system: profile.md,        │                  │
  │            │     user: "where am I..." }    │                  │
  │            │                 │              ├── /chat ────▶    │
  │            │                 │              │  {model: kimi-k2}│
  │            │                 │              │◀── stream ───────┤
  │            │◀── text response ──────────────┤  "You're going   │
  │            │   "You're going to Chengdu     │   to Chengdu..." │
  │            │    this weekend, May 25-29..." │                  │
  │            │                 │              │                  │
  │            ├ TTS (CosyVoice) │              │                  │
  │            ├ PCM → OPUS      │              │                  │
  │◀ OPUS ─────┤                 │              │                  │
  ├ play ──▶   │                 │              │                  │
```

### Latency budget (typical, on WiFi, warm sandbox)

| Stage | Latency | Notes |
|---|---|---|
| Audio capture + wake + EOS detection | ~200ms | on-device |
| OPUS encode | ~50ms | on-device |
| WebSocket up (WiFi RTT) | ~50ms | depends on WiFi quality |
| ASR (streaming first-token) | ~400ms | FunASR / DashScope streaming |
| AgentKeys memory fetch (loopback) | ~50ms | localhost HTTP, S3 cached |
| Hermes turn processing | ~200ms | depends on Hermes session mode |
| LLM first-token (Kimi/Claude/Qwen) | ~600ms | streaming, model-dependent |
| TTS first-chunk | ~300ms | CosyVoice / Edge-TTS streaming |
| WebSocket down + OPUS decode | ~100ms | |
| Speaker start | ~50ms | I2S DMA |
| **Total first-audio** | **~2.0–2.5s** | |
| Baseline (no Hermes/AgentKeys) | ~1.5–2.0s | xiaozhi cloud directly to LLM |
| **Delta from our additions** | **~+250–500ms** | |

This sits inside the "1.5–2.0s realistic floor" called out in [office-hours design doc §Constraints](./ai-hardware-companion-office-hours.md). For voice UX on a companion toy this is the upper end of acceptable; the §Risks doc has measurement plans + optimization paths if it slips.

---

## Bottom line

**Architecture is sound**:
- Each layer has one job
- Protocol boundaries are well-defined: xiaozhi WebSocket (device ↔ bridge) / HTTP localhost (bridge ↔ AgentKeys, bridge ↔ Hermes) / HTTPS (Hermes ↔ foundation LLM)
- No novel protocols, no firmware risk, no new audio code
- The differentiation (AgentKeys memory + Hermes learning loop) sits exactly where the vendor pitch needs it: above the audio pipeline, below the foundation LLM

**The integration is one fork + one module rewrite**:
- Fork `xinnan-tech/xiaozhi-esp32-server` (Python, MIT)
- Replace the `chat()` function that calls LLMs directly with one that:
  1. GETs memory from `agentkeys-daemon` (~10 lines)
  2. POSTs a turn to Hermes-agent with memory in the system prompt (~30 lines)
  3. Returns the text response (~5 lines)
- Everything else — OPUS handling, ASR, TTS, WebSocket session management, MCP cloud tools, voice-print recognition — comes free with the fork.

**The demo "wow moment" stays unchanged**: user says *"where am I going this weekend?"*, toy answers *"You're going to Chengdu, May 25-29, planning to deal with the customs question from yesterday."* The "wow" comes from the memory injection (AgentKeys) and the agent's coherence (Hermes), not from anything firmware-side.

**Three risks worth measuring early** — verified + mitigated in [`xiaozhi-hermes-risks.md`](./xiaozhi-hermes-risks.md):
1. Hermes' HTTP gateway shape (stateless single-turn vs. always-session)
2. Latency stack (does adding 250–500ms break voice UX?)
3. Concurrent device handling (Hermes is typically single-user)

## Related research

- [`xiaozhi-esp32-magiclink.md`](./xiaozhi-esp32-magiclink.md) — hardware specs + Option 1 vs 2 decision
- [`xiaozhi-hermes-risks.md`](./xiaozhi-hermes-risks.md) — risk verification + mitigations
- [`ai-hardware-companion-office-hours.md`](./ai-hardware-companion-office-hours.md) — wedge strategy (Approach D)
- [`ai-hardware-companion-wedge.md`](./ai-hardware-companion-wedge.md) — market + competitive landscape
- [issue #103 plan](../plan/issue-103-aiosandbox-hermes-esp32-demo.md) — implementation plan (sections C4/C5/C6 superseded by this direction)
