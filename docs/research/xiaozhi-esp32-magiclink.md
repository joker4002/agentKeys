# xiaozhi-esp32 + MagicLick 2.5 — integration research

**Status**: Research notes informing the issue #103 demo direction. NOT a spec.
**Audience**: Engineers picking up the AgentKeys × Hermes × ESP32 demo work.

## TL;DR

The hardware demo device on hand is a **MagicLick 2.5** running **xiaozhi-esp32 firmware v1.9.4** (board folder `boards/magiclick-2p5`, firmware tag `v1.9.4` released 2025-11-04). The xiaozhi-esp32 firmware ([github.com/78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32), MIT-licensed, 26K stars, 5.9K forks) is the dominant open-source AI voice firmware in the Chinese ESP32 ecosystem. It supports 70+ boards including ours, ships a full streaming voice pipeline (offline wake-word → ASR → LLM → TTS → OPUS streaming), and talks to its cloud via either WebSocket or MQTT+UDP.

**Chosen direction: Option 1 — keep the existing xiaozhi-esp32 firmware on the device, build a cloud-side adapter that speaks the xiaozhi protocol while routing the agent loop to [Hermes-agent](https://github.com/NousResearch/hermes-agent).** This is dramatically cheaper than rewriting the firmware (Option 2), keeps the device production-equivalent to what vendors ship, and reduces the v0 effort from ~3 months to ~3 weeks.

The earlier `firmware/esp32s3-agentkeys/` scaffolding stays in the tree as **reference for future custom hardware** (new product lines that need first-party firmware), not as the path for the MagicLick demo.

## What is xiaozhi-esp32

- **Repo**: [github.com/78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) — MIT, ESP-IDF-based, C++ codebase
- **Tagline**: "An MCP-based chatbot"
- **Supported chips**: ESP32-C3, ESP32-S3, ESP32-P4
- **Voice pipeline**: offline wake-up via [ESP-SR](https://github.com/espressif/esp-sr) → streaming ASR → LLM → streaming TTS, OPUS codec for audio transport
- **Cloud protocols**: WebSocket (preferred) OR MQTT+UDP
- **Display**: OLED / LCD with emoji rendering
- **MCP integration**:
  - Device-side MCP (speaker, LED, servo, GPIO control as MCP tools)
  - Cloud-side MCP (smart home, PC desktop, knowledge search, email)
- **Multi-language**: Chinese, English, Japanese
- **Audio quality**: speaker recognition via [3D-Speaker](https://github.com/modelscope/3D-Speaker), customizable wake words

### Version notes

- **v1** is the stable line. Latest tag: `v1.9.4` (2025-11-04). The v1 branch is maintained until **February 2026**.
- **v2** is the current development line. Incompatible with v1 partition table — no OTA upgrade path. Latest tag: `v2.2.6` (2026-04-19).
- The MagicLick 2.5 device ships with v1.9.4 (matches the `magiclink 2p5/1.9.4` display text).
- Practical implication: target v1.9.4 for the demo. v2 migration can be a follow-up issue when v1 EOLs.

## What is MagicLick 2.5 (hardware specs)

Reconstructed from [`boards/magiclick-2p5/config.h`](https://github.com/78/xiaozhi-esp32/blob/v1.9.4/main/boards/magiclick-2p5/config.h) and [`magiclick_2p5_board.cc`](https://github.com/78/xiaozhi-esp32/blob/v1.9.4/main/boards/magiclick-2p5/magiclick_2p5_board.cc).

| Component | Detail |
|---|---|
| **MCU** | ESP32-S3 (`target: esp32s3` in `config.json`) |
| **Audio codec** | ES8311 (full-duplex I2S audio codec, I2C-controlled at `ES8311_CODEC_DEFAULT_ADDR`) |
| **Mic + speaker** | Single mic + single speaker, full-duplex via I2S |
| **Audio sample rate** | 24kHz input + 24kHz output |
| **Audio I2S pins** | MCLK=8, WS=11, BCLK=9, DIN=10 (mic), DOUT=12 (speaker) |
| **Speaker amp enable** | GPIO 4 (codec PA pin) |
| **Codec I2C** | SDA=5, SCL=6 |
| **Display** | GC9107 SPI LCD, 128×128 pixels |
| **Display pins** | SDA=16, SCL=15, CS=14, DC=18, RST=17, backlight=13 (inverted) |
| **Buttons (3)** | Main=GPIO 21, Left=GPIO 0 (also BOOT), Right=GPIO 47 |
| **LEDs (2)** | WS2812-style circular strip on GPIO 38, power gate on GPIO 39 |
| **Battery / power** | Power manager on GPIO 48 (charging detect), sleep timer, tickless idle |
| **Network** | DualNetworkBoard — WiFi (primary) + ML307 Cat.1 4G modem (optional) |
| **ML307 4G pins** | RX=42, TX=44, Power=40 |
| **Power management** | `CONFIG_PM_ENABLE=y`, `CONFIG_FREERTOS_USE_TICKLESS_IDLE=y` — designed for battery operation |

**Implication for the demo**: MagicLick 2.5 has full audio listen + speak capability via the ES8311 codec. The xiaozhi firmware already drives the audio pipeline end-to-end. No firmware changes needed for v0 audio.

**Implication for vendor partnerships**: this is the *real shape* of mainstream AI-companion devices. The 3-button layout, ES8311 codec, 128×128 round-ish display, and dual-network (WiFi + 4G fallback) is the dominant pattern. Demoing on MagicLick 2.5 is demoing on the modal device.

## The integration model — how Option 1 actually wires together

```
┌──────────────────────────────────────────────────────────────┐
│ MagicLick 2.5 device                                         │
│  - xiaozhi-esp32 v1.9.4 firmware (unchanged)                 │
│  - ES8311 mic → OPUS encode → WebSocket frames               │
│  - WebSocket frames → OPUS decode → ES8311 speaker           │
│  - 128×128 LCD shows state (idle / listening / thinking)     │
│  - Wake word triggers session via on-device ESP-SR           │
└──────────────────────────┬───────────────────────────────────┘
                           │ WebSocket (xiaozhi protocol)
                           │ OR MQTT+UDP
                           v
┌──────────────────────────────────────────────────────────────┐
│ xiaozhi-hermes-bridge (NEW — our cloud-side adapter)         │
│                                                              │
│  - Accepts xiaozhi WebSocket connections                     │
│  - Receives OPUS audio frames from device                    │
│  - Decodes OPUS → PCM → calls ASR (FunASR / DashScope ASR)   │
│  - Sends transcript to Hermes-agent via its HTTP gateway     │
│  - Hermes processes the turn with AgentKeys-injected memory  │
│  - Streams text response back; calls TTS (CosyVoice/Edge-TTS)│
│  - Encodes PCM → OPUS, streams frames back to device         │
│  - AgentKeys logs the interaction off-chain (v0 demo)        │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ├─→ AgentKeys daemon (memory + identity)
                           │   - GET /v1/memory/<actor>/profile.md
                           │   - mock S3 MD blob (per issue #103 §C3)
                           │
                           └─→ Hermes-agent (NousResearch)
                               - Runs inside aiosandbox container
                               - LLM call routed via Hermes' model abstraction
                                 (Qwen-Plus / DeepSeek / OpenRouter / etc.)
                               - Hermes' own memory layer holds short-term
                                 conversation; AgentKeys provides long-term
                                 profile.md as system-prompt context
```

### Why not skip xiaozhi-hermes-bridge and just have xiaozhi talk to Hermes directly?

Hermes-agent doesn't natively speak the xiaozhi WebSocket protocol. Hermes is designed around terminal / Telegram / Discord / Slack interfaces. The bridge is the translation layer between OPUS-streamed-audio-frames-with-xiaozhi-control-messages and Hermes' text-in / text-out gateway.

Building the bridge from scratch is unnecessary — there are **at least four open-source reference implementations** of the xiaozhi server protocol we can adopt or extend:

| Implementation | Language | Notable features | Repo |
|---|---|---|---|
| **[`xinnan-tech/xiaozhi-esp32-server`](https://github.com/xinnan-tech/xiaozhi-esp32-server)** | Python | Official-feeling reference; broad community use | xinnan-tech main |
| **[`hackers365/xiaozhi-esp32-server-golang`](https://github.com/hackers365/xiaozhi-esp32-server-golang)** | Go | WebSocket + MQTT+UDP, voice-print, voice-clone, knowledge base, **MCP remote call**, active audio downstream, **openclaw** | hackers365 |
| **[`joey-zhou/xiaozhi-esp32-server-java`](https://github.com/joey-zhou/xiaozhi-esp32-server-java)** | Java | Enterprise platform with device monitoring + voice customization + role switching + dialog records | joey-zhou |
| **[`AnimeAIChat/xiaozhi-server-go`](https://github.com/AnimeAIChat/xiaozhi-server-go)** | Go | Lightweight Go variant | AnimeAIChat |

**Recommended starting point**: fork `xinnan-tech/xiaozhi-esp32-server` (Python — matches Hermes' Python ecosystem) and replace its built-in LLM caller with a Hermes-agent client. ASR/TTS/audio handling stays as-is. This gets us a working bridge in 1-2 weeks.

The Go server (`hackers365`) is interesting because it already mentions **openclaw** integration in its README — could be a faster path if the Hermes-agent ↔ openclaw shape ends up adjacent to what we want.

### xiaozhi communication protocols

xiaozhi-esp32 supports two transport protocols. The device picks one at provisioning time.

| Protocol | Use case | Server URL format | Latency | Reliability |
|---|---|---|---|---|
| **WebSocket** | Direct connection, simpler stack, easier to debug | `ws[s]://server.example/ws` | Low (~50ms over WiFi) | TCP-backed, server holds state per device |
| **MQTT+UDP** | High-concurrency / load-balanced fleets; audio over UDP for low latency, control over MQTT | MQTT broker + UDP audio endpoint | Lowest for audio (~10ms over WiFi) | UDP audio is lossy by design; MQTT control survives reconnects |

**For v0 demo**: WebSocket. Easier setup, lower operational complexity, sufficient latency for a single demo device. MQTT+UDP makes sense when the fleet grows past ~100 concurrent devices or when reducing audio latency below 100ms matters.

Protocol details:
- [`docs/websocket.md`](https://github.com/78/xiaozhi-esp32/blob/v1.9.4/docs/websocket.md) in the xiaozhi repo
- [`xiaozhi-mqtt-gateway`](https://github.com/xinnan-tech/xiaozhi-mqtt-gateway) — reference MQTT+UDP server with load balancing

## Hardware verification procedures

`system_profiler SPUSBDataType` showed no enumeration when you plugged in the device. That's expected for a battery-charged consumer-finished product — USB is often charge-only in normal mode, and you have to actively put the chip into the ESP32-S3 ROM bootloader to expose USB CDC + JTAG. Multiple verification paths below; not all require USB serial.

### Path A — Visual confirmation (already done)

You've already confirmed via the device display showing `magiclink 2p5/1.9.4`. That single string identifies:

- **Hardware**: MagicLick 2.5 → `boards/magiclick-2p5` in xiaozhi-esp32
- **Firmware**: xiaozhi-esp32 v1.9.4 → tag `v1.9.4` on the v1 branch (released 2025-11-04)
- **Implied chip**: ESP32-S3 (per `config.json: "target": "esp32s3"`)

This is sufficient identification for the demo plan. Steps below are only needed if you want to flash custom firmware or deep-debug audio pipeline issues.

### Path B — Force ESP32-S3 ROM bootloader (USB serial access)

The S3's ROM bootloader exposes a USB CDC interface even when normal firmware doesn't. To enter it:

1. Disconnect USB cable
2. **Hold the LEFT button** (GPIO 0, which is the BOOT pin) — keep it held
3. Reconnect USB cable while still holding the button
4. After ~2 seconds, release the LEFT button
5. Re-run `system_profiler SPUSBDataType | grep -B 2 -A 10 -iE "esp|cdc|jtag"` — should now show "USB JTAG/serial debug unit" (Espressif VID 0x303A, PID 0x1001)
6. Run `ls /dev/cu.usbmodem*` to find the serial port
7. Probe the chip:
   ```bash
   PORT=$(ls /dev/cu.usbmodem* | head -1)
   esptool.py --port "$PORT" chip_id
   esptool.py --port "$PORT" flash_id
   esptool.py --port "$PORT" read_mac
   ```

Expected output identifies the exact ESP32-S3 variant (e.g., ESP32-S3R8 = with 8MB PSRAM, ESP32-S3 = no PSRAM), flash size, MAC address.

To return to normal firmware: power-cycle without holding the button.

### Path C — Device's own WiFi config portal

During WiFi provisioning (factory reset → device broadcasts a SoftAP), connect your phone/laptop to the device's WiFi network (typically named `xiaozhi-XXXX` or `MagicLick-XXXX`). Open a browser to the captive portal IP (usually `192.168.4.1`). The portal exposes:

- Firmware version + git hash
- Hardware revision string
- WiFi config form
- Server URL config (default: xiaozhi's public server at `api.xiaozhi.me` or similar)

This is the path you'll use to point the device at OUR cloud server later (overrides the default xiaozhi-cloud endpoint with `wss://demo.agentkeys.io/ws`).

### Path D — Vendor's normal app flow

If MagicLick ships with a companion app (likely WeChat Mini Program or Android app via 应用宝), open it and look for "Device info" or "About this device." Will list hardware version, firmware version, MAC, serial number, and the configured server endpoint. Less invasive than Path B.

### Path E — Disassemble (last resort)

Open the case and read the silkscreen labels on:
- The ESP32-S3 module (top-side label, e.g., "ESP32-S3-WROOM-1-N8R8")
- The audio codec chip (look for "ES8311" rectangular ~3mm package)
- The display IC (typically on the LCD ribbon)

Don't do this unless you genuinely cannot identify via Path A-D — voids any vendor warranty and risks bricking.

## Risks and tradeoffs vs Option 2 (rewrite firmware)

| Dimension | Option 1 (use xiaozhi, build bridge) | Option 2 (rewrite firmware) |
|---|---|---|
| **Time to working demo** | ~2-3 weeks | ~2-3 months |
| **Firmware risk** | Zero — using production-tested code with 26K stars | High — voice pipeline (wake-word, ASR, OPUS, TTS) is hard to get right |
| **Hardware compat** | 70+ boards out of the box | Each board needs separate firmware port |
| **MCP capabilities** | Inherits xiaozhi's device-side + cloud-side MCP | Reimplement from scratch |
| **Battery / power mgmt** | Tickless idle, sleep modes, charging detect — already done | Reimplement |
| **Display / emoji / LED** | Already polished | Reimplement |
| **Multi-language** | Chinese / English / Japanese already shipping | Reimplement i18n |
| **Vendor optics** | "We integrate cleanly with the dominant Chinese AI voice firmware" — strong positioning with FoloToy / Ropet / vendors who use xiaozhi today | "We have our own firmware" — sounds like NIH to a vendor whose firmware ALREADY works |
| **Long-term ownership** | Track xiaozhi-esp32 main branch; cherry-pick if needed | Own everything forever |
| **Differentiation surface** | The AgentKeys-Hermes cloud is the moat; firmware is plumbing | Differentiation is firmware-deep — but no vendor has asked for that |
| **AgentKeys integration depth** | Plug into the bridge server (Python) — clean Python ↔ Python integration with Hermes | Same eventual integration depth, just more work to get there |

**Strong recommendation: Option 1.** The MagicLick device on hand IS the vendor reality — they ship xiaozhi-esp32. Replicating that pipeline ourselves would be a 3-month detour that produces a worse copy of what xiaozhi already does. The differentiation is the **cloud side** (Hermes-agent's learning loop + AgentKeys' identity / memory / cross-vendor portability), not the firmware. Build where the differentiation is, integrate everything else.

The only scenario where Option 2 makes sense: a vendor partnership where the vendor demands a fork (e.g., for IP / supply-chain control) AND has the budget to fund 3 months of firmware engineering. Not the demo case.

## Specific next steps (replaces issue #103 §C5–C6 firmware-from-scratch path)

1. **Stand up `xiaozhi-hermes-bridge`** by forking `xinnan-tech/xiaozhi-esp32-server` (Python). Replace its LLM caller module with a Hermes-agent client. Keep ASR/TTS/WebSocket handling as-is. Deploy as a single FastAPI/uvicorn process behind nginx with WSS.
2. **Install Hermes-agent inside aiosandbox** via the official installer (`curl -fsSL .../install.sh | bash`). Configure model to use OpenRouter / DashScope / our subsidized LLM key. Hermes runs as a long-lived process; the bridge talks to it via Hermes' HTTP gateway.
3. **Add AgentKeys integration** in the bridge: on session start, GET `/v1/memory/<actor>/profile.md` from agentkeys-daemon and inject as system-prompt context for that turn's Hermes call. Re-fetch on every N turns or on a webhook signal.
4. **Configure MagicLick 2.5** via Path C (its WiFi captive portal) to point at `wss://demo.agentkeys.io/ws` (our bridge URL) instead of xiaozhi's public cloud.
5. **End-to-end test**: wake the device → ask "Where am I going this weekend?" → bridge receives audio → ASR → Hermes (with profile.md saying "planning Chengdu trip 2026-05-25") → text response references Chengdu → TTS → audio plays from device speaker.
6. **Defer to follow-up**: voice-print recognition (xiaozhi already does it), cross-vendor portability (need 2+ vendor boards), payment integration, audit anchoring.

This sequence collapses issue #103's 3-week effort into a different shape — no firmware work for v0, all engineering on the bridge + Hermes integration + AgentKeys glue.

## Open questions

1. **Hermes-agent's HTTP API surface**: which Hermes endpoints accept a turn input and return text output? Worth a 1-day spike — read [hermes-agent.nousresearch.com/docs](https://hermes-agent.nousresearch.com/docs) end-to-end before architecting the bridge.
2. **xiaozhi's session protocol**: what control messages does the device send (connect / wake / session-end / cancel)? How does the server signal "speaking" vs "listening" vs "thinking" so the device can update its display? Read [`docs/websocket.md`](https://github.com/78/xiaozhi-esp32/blob/v1.9.4/docs/websocket.md).
3. **ASR / TTS choice**: xiaozhi's reference servers default to FunASR (ASR) + Edge-TTS or CosyVoice (TTS). Which combo gives us the best Chinese + English quality at acceptable cost for v0 demos? Likely DashScope ASR + CosyVoice if we're on Aliyun, or Edge-TTS if we want zero infra.
4. **OPUS streaming**: does our bridge need to maintain its own OPUS encoder/decoder, or do the reference servers handle that already? (Spoiler: they handle it; we just route the PCM up to ASR and back down to TTS.)
5. **Magic Wand v2.5 — battery life**: the firmware enables aggressive power management. Will users tolerate a couple-of-days battery life on a chatty device? Vendor product question, not engineering.
6. **WeChat / Telegram dual-channel**: xiaozhi natively supports WeChat MiniProgram clients alongside the ESP32 firmware. Hermes natively supports Telegram. Combining the two is non-trivial but extremely valuable — same agent identity, three surfaces (toy / WeChat / Telegram). Separate exploration.
7. **v1 → v2 firmware migration**: xiaozhi v1 EOLs February 2026. Plan a v2 migration spike before then.

## References

- xiaozhi-esp32 firmware: [github.com/78/xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) — MIT license, 26K stars
- MagicLick 2.5 board source: [`boards/magiclick-2p5`](https://github.com/78/xiaozhi-esp32/tree/v1.9.4/main/boards/magiclick-2p5)
- xiaozhi WebSocket protocol: [`docs/websocket.md`](https://github.com/78/xiaozhi-esp32/blob/v1.9.4/docs/websocket.md)
- Official Feishu wiki (auth-required): [XiaoZhi AI Chatbot Encyclopedia](https://ccnphfhqs21z.feishu.cn/wiki/F5krwD16viZoF0kKkvDcrZNYnhb)
- Hermes-agent: [github.com/NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — MIT license, "The agent that grows with you"
- Hermes-agent docs: [hermes-agent.nousresearch.com/docs](https://hermes-agent.nousresearch.com/docs)
- Hermes-agent installer: `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash`
- Reference server (Python): [xinnan-tech/xiaozhi-esp32-server](https://github.com/xinnan-tech/xiaozhi-esp32-server)
- Reference server (Go, has openclaw): [hackers365/xiaozhi-esp32-server-golang](https://github.com/hackers365/xiaozhi-esp32-server-golang)
- Reference server (Java enterprise): [joey-zhou/xiaozhi-esp32-server-java](https://github.com/joey-zhou/xiaozhi-esp32-server-java)
- ESP-SR (offline wake-word): [github.com/espressif/esp-sr](https://github.com/espressif/esp-sr)
- 3D-Speaker (speaker recognition): [github.com/modelscope/3D-Speaker](https://github.com/modelscope/3D-Speaker)
- ES8311 audio codec datasheet: [Everest-Semi product page](https://www.everest-semi.com/pdf/ES8311%20PB.pdf)
