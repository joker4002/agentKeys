# Architecture research notes

This directory holds **exploratory plans** that informed AgentKeys' Stage 7+ architecture decisions. They're versioned with the repo so the *why* of any future code lands has a paper trail.

These are research artifacts, not authoritative specs. The authoritative specs live in [`../spec/`](../spec/). When a research plan locks in, the corresponding spec doc is what changes.

## Contents

| File | Topic | Status |
|---|---|---|
| [`option-a-port-dexs-backend.md`](./option-a-port-dexs-backend.md) | Port [dexs-backend](https://github.com/dexs-k/dexs-backend)'s wallet-sig + email + OAuth flows into `agentkeys-broker-server`; minimal patch to Heima TEE worker for `CLIENT_ID_AGENTKEYS`. | Researched, not chosen yet |
| [`option-a-vs-b-port-vs-greenfield.md`](./option-a-vs-b-port-vs-greenfield.md) | Side-by-side comparison: port dexs-backend (A) vs greenfield broker designed around AgentKeys' problem domain (B). | Comparison artifact |
| [`option-c-pluggable-attestation-audit.md`](./option-c-pluggable-attestation-audit.md) | **Pluggable** auth / wallet-provisioning / audit-anchoring. Heima becomes one plug-in among several (Solana, Ethereum L2, AWS Nitro, S3 Object Lock, etc.). Zero Heima dependency in v0. | Researched, recommended for net-new branch |
| [`ai-hardware-companion-wedge.md`](./ai-hardware-companion-wedge.md) | Business research on AI-hardware-companion GTM as the AgentKeys demo wedge. Market sizing (China AI-toy $3.5B+), direct competitors (Privy/Stripe, Coinbase AgentKit, ScaleKit, Alipay+ AMP), unit-economics critique of draft pricing, 12 critical comments (C1–C12), naming options, sequenced next moves. | Business brainstorm, not committed |
| [`ai-hardware-companion-office-hours.md`](./ai-hardware-companion-office-hours.md) | YC-style office-hours diagnostic on the same wedge — six forcing questions (demand reality, status quo, specificity, narrowest wedge, observation, future-fit), premise revision (P2 narrowed mid-session to memory portability + isolation + privacy), four alternatives (A/B/C/D), chosen approach (D: AgentKeys-native sandbox / aiosandbox), elastic AWS-style pricing, cross-vendor memory consent model, the assignment (find named buyer at FoloToy in 30 min). Survived 2 rounds of adversarial review at 8/10 final quality. | Approved design doc |
| [`xiaozhi-esp32-magiclink.md`](./xiaozhi-esp32-magiclink.md) | Integration research for the issue #103 demo: identifies the hardware on hand as MagicLick 2.5 (ESP32-S3 + ES8311 audio codec + 128×128 GC9107 display + dual-network WiFi+ML307 4G) running xiaozhi-esp32 v1.9.4 firmware. Recommends Option 1 (keep firmware, build cloud-side `xiaozhi-hermes-bridge`) over Option 2 (rewrite firmware) on a 3-weeks-vs-3-months effort delta. Includes hardware verification procedures, xiaozhi protocol overview (WebSocket + MQTT+UDP), and four reference server implementations to fork. | Approved direction |
| [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) | Architecture reference for the Option 1 integration. Three diagrams: original xiaozhi flow (baseline), our pivoted flow with changed layers highlighted, and per-turn sequence with latency budget (~2.0-2.5s first-audio). Includes precise diff table of what changes vs. baseline — concentrates the actual code change in one module of the bridge fork. | Reference |
| [`xiaozhi-hermes-risks.md`](./xiaozhi-hermes-risks.md) | Risk verification + mitigations grounded in actual repo code. R1 (Hermes gateway shape): real, mitigation built-in via `X-Hermes-Session-Key` header (2-4 hours). R2 (latency): mostly NOT real — learning loop is background, off the turn path (1 day tuning). R3 (concurrency): less bad than feared, multi-tenant by design (0 hours v0, 1-2 weeks production). **R4 (newly discovered)**: cold agent construction per request adds 50-300ms — needs fork-local pool or upstream patch (1 day or 2-4 days). Revises v0 timeline from ~3 weeks to ~1-2 weeks. | Reference |

## Background

The three plans grew out of a single question — *"what does `agentkeys init` actually do?"* — that surfaced a chain of architecture decisions:

1. AgentKeys' broker doesn't have a real auth backend yet (mock-server stub).
2. The natural reference is wildmeta's `dexs-backend` (Go-zero microservices stack) because it solves a similar shape.
3. But `dexs-backend` and Heima TEE worker are tightly coupled — porting one drags in assumptions from the other.
4. Heima TEE worker is single-tenant today (`client_id == CLIENT_ID_WILDMETA` hardcoded in [`tee-worker/omni-executor/rpc-server/src/methods/omni/user_login.rs`](https://github.com/litentry/heima/blob/main/tee-worker/omni-executor/rpc-server/src/methods/omni/user_login.rs)). Multi-tenant support requires an upstream patch.
5. The patch cost is asymmetric across Options A / B / C.
6. [`docs/arch.md` §11](../arch.md#11-audit-destination-is-pluggable) already established that **audit anchoring is pluggable**. Option C extends the same principle to two more layers.

## Tracking issues

Each plan has a corresponding issue tracking next steps:

- [#62](https://github.com/litentry/agentKeys/issues/62) — **OIDC federation deployment (deferred)**. Federation infrastructure ships in PR #61; the cloud-enforced PrincipalTag isolation acceptance test is deferred until auth lands.
- [#63](https://github.com/litentry/agentKeys/issues/63) — **Auth implementation (Option A path)**. Port `walletloginlogic.go` + `emailloginlogic.go` + `googleoauthcallbacklogic.go` to Rust in `agentkeys-broker-server`; coordinate the Heima `CLIENT_ID_AGENTKEYS` patch with Litentry.
- [#64](https://github.com/litentry/agentKeys/issues/64) — **Option C zero-Heima broker (separate branch)**. Pluggable architecture, no Heima dependency in v0; recommended branch `claude/agentkeys-pluggable-broker`.
