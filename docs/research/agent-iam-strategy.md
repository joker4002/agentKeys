# AgentKeys strategic direction — Agent IAM for the AI device era

**Status**: Strategic anchor (revised 2026-05-24). Captures the strategic framing that emerged from a multi-round discussion: original Agent IAM proposal → independent analysis → ChatGPT critique with four architecture corrections → this synthesis.

**Purpose**: be the source of truth for "what AgentKeys is, what it isn't, and what we ship next." Future planning, positioning, and scope decisions reference this doc.

**Companion docs**:
- [`ai-hardware-companion-office-hours.md`](./ai-hardware-companion-office-hours.md) — original wedge brainstorm (positioning is updated by this doc)
- [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md), [`volcano-ark-mcp-integration.md`](./volcano-ark-mcp-integration.md), [`tuya-vs-xiaozhi.md`](./tuya-vs-xiaozhi.md) — tactical adapter architectures (unchanged by this doc)
- [issue #103 plan](../spec/plans/issue-103-aiosandbox-hermes-esp32-demo.md) — Phase 1 execution (scope is updated by this doc)

---

## 1. TL;DR

> AgentKeys is the **Agent IAM and memory control plane** for a future where users have many AI devices, many agents, and many LLMs, but still need one trusted way to manage what those systems can know, access, and do.

We stay infrastructure. We do not become a task-execution agent. We integrate with Hermes, OpenClaw, Claude Code, Doubao agents, vendor-specific runtimes — we provide them with identity, memory, permissions, capabilities, and audit. They do the work; we control the authority to do the work.

Three-layer positioning, told to three audiences:

| Layer | Audience | Pitch |
|---|---|---|
| **AI Device Account** | Consumer / vendor BD | "Your AI memory follows you safely across devices. Parents control what devices can know and do." |
| **Agent IAM** | Investor / CTO / CISO / partner | "Identity, permissions, capabilities, audit for AI agents — the IAM layer for the AI device era." |
| **Trust Substrate** | Compliance / regulator / Web3 partner | "Tamper-evident permission history + cryptographic device/agent identity attestation + on-chain anchoring." |

Cap-token machinery, signer, memory/cred/audit workers, per-actor isolation, and HDKD identity are already shipped via Stage 7+. What's net-new is the MCP server wrapper, the parent-control web UI, vendor onboarding, and the three-act demo storyboard.

---

## 2. What we accept from the Agent IAM proposal

These ideas survived independent analysis and ChatGPT critique. They are committed strategic direction.

### 2.1 Task Host vs Authority Host distinction

Hermes, OpenClaw, Claude Code, Codex, Doubao agents, vendor-specific runtimes = **Task Execution Hosts**. They reason, plan, retry, execute, and complete tasks.

AgentKeys = **Authority Host**. We manage identity, device registry, agent registry, memory namespaces, credential broker, capability token issuance, policy engine, delegation chains, approval workflows, audit logs, revocation, budget controls.

The distinction has the same shape as "OS vs application" or "AWS IAM vs the EC2 instance running your workload." Both are valuable, both are needed, they don't compete because they sit at different layers. **Authority must be neutral by construction** — no specialized runtime can credibly play this role without giving up their own walled garden. That neutrality is our structural moat.

### 2.2 Agent IAM as the technical category

"Key management for agents" is too narrow (1Password + Vault eat it). "Memory MCP server" is too narrow (Mem0 / Zep / Letta eat it). "Agent IAM" is the right size:

- *Who is this agent?*
- *Which device is it running on?*
- *Acting for which user?*
- *Can it access which memory?*
- *Can it use which credential?*
- *Can it delegate?*
- *Can it spend?*
- *Can it be revoked?*
- *Can it be audited?*

This is a $20B+ comparable market with deep mental models (Okta, Auth0, AWS IAM, Ping). Extending into the AI agent substrate is a category-creation move with the same buyer logic.

### 2.3 MCP is an integration surface, not the product identity

MCP is the protocol vendor LLMs use to call our tools. Important. But also: SDKs, OAuth-style flows, device APIs, runtime adapters, policy APIs are all eventually-needed surfaces. **We sequence**: MCP first (open standard, broad reach), Python + TypeScript SDKs second, OAuth-style flows third, the rest later.

The product identity is "Agent IAM" — not "an MCP server."

### 2.4 Zero orchestration in v1 — hard line

The proposal said *"AgentKeys can optionally provide lightweight orchestration."* That's a slippery slope. Once we ship even lightweight orchestration, vendors will ask for more. Each ask is reasonable; the sum is mission creep that turns us into "another agent runtime" — exactly the position the Task Host vs Authority Host distinction exists to prevent.

**Policy**: zero orchestration in v1, documented explicitly. If a vendor needs orchestration, they pick a runtime (Hermes, OpenClaw, their own). We provide the authority layer around it.

### 2.5 Deploy → grow → standardize sequencing

Standards work (MCP extensions for IAM-grade auth headers, OAuth-for-Agents, W3C/IETF engagement) is the right long-term direction. But standards adoption requires deployed reference implementations, vendor partners, and credibility we don't yet have.

Sequence: ship working code → grow vendor adoption → THEN propose specs. Not the reverse.

### 2.6 Three-act demo direction over memory-only demo

Single-act memory injection reads as "smart toy." Three acts read as "Agent IAM." See §4 for the revised Phase 1 demo.

---

## 3. Four corrections that reshape architecture commitments

These are the ChatGPT-surfaced corrections to the original proposal. They sharpen what we promise vs what we deliver.

### 3.1 Revocation: immediate online, bounded offline

**Wrong commitment**: *"real-time revocation, no propagation delay."*

That's accurate only when every action passes through an online AgentKeys permission check. Real AI device scenarios include local caches, short-lived capability tokens, offline mode, weak network, device sleep/wake, edge gateways.

**Correct commitment**:

> **Online revocation is immediate. Cached/offline capabilities are bounded by short TTL and revocation-list refresh on next online interaction.**

The honest security model:

| Action class | Enforcement | Latency to revoke |
|---|---|---|
| High-risk (payment, credential write, send-email) | Always online permission check + fresh cap-token mint per call | Immediate on revocation |
| Low-risk (memory read of a non-sensitive namespace) | Short-lived cached cap (1-5 min TTL) | At most cap-TTL |
| Offline mode | Deny sensitive actions by default; allow safe reads from cached memory | Sensitive actions blocked entirely |

This is also better engineering: forcing every memory read through online check kills voice UX latency. Layered enforcement = right answer.

For the demo: show the high-risk path with immediate revocation (the dramatic moment), explain the layered model in the runbook.

### 3.2 Audit: real-time off-chain feed + batched on-chain anchor

**Wrong commitment**: *"audit row appears on Heima explorer in real-time"* (would contradict batched anchoring + cost a fortune in gas).

**Correct commitment**:

> **Off-chain audit feed is real-time, shown in the parent-control web UI. On-chain audit anchor is batched (10-minute Merkle root) on Heima, shown on Heima explorer as tamper-evidence proof.**

Two-tier audit:

| Tier | What | Where shown | Latency | Purpose |
|---|---|---|---|---|
| Off-chain feed | Every authority event (cap mint, permission check, memory read, credential fetch, revocation) | Parent-control web UI + AgentKeys API | Real-time (~100ms) | UX, monitoring, dispute resolution |
| On-chain anchor | Merkle root of off-chain events for a 10-min window | Heima explorer | 10 min | Tamper-evidence, cryptographic proof, regulatory export |

Demo language: *"The parent sees the audit event instantly in the app. The cryptographic audit batch is later anchored on Heima for tamper-evidence — visible on the Heima explorer 10 minutes after."*

Heima explorer is **trust proof, not real-time UX**. Parent-control web UI is the experience surface.

### 3.3 Delegation: schema/preview in v1, not active

Delegation is genuinely complex: parent agent, child agent, scope narrowing, TTL, revocation inheritance, audit chain, approval gates, liability.

**Correct scope for v1**:

| Status | Tools |
|---|---|
| **Implemented + active in v1** | `agentkeys.identity.whoami`, `agentkeys.memory.get`, `agentkeys.memory.put`, `agentkeys.permission.check`, `agentkeys.cap.mint`, `agentkeys.cap.revoke`, `agentkeys.audit.append` |
| **Documented but NOT active in v1** | `agentkeys.delegation.grant`, `agentkeys.delegation.revoke`, `agentkeys.approval.request` (schema only, returns `not_implemented_in_v1`) |

The reason to document-but-not-ship: delegation is a future capability the architecture must accommodate, but shipping a half-baked version risks vendors building on assumptions we'll have to break. Schema-only signals "this is coming" without locking in details we'll change.

### 3.4 Dual narrative — separate consumer pitch from B2B pitch

**Wrong commitment**: leading with "Agent IAM" in consumer contexts.

Agent IAM is correct for B2B / investor / partner / CTO audiences. It's sharp, well-categorized, defensible. But "Agent IAM" to a parent buying an AI toy on Tmall reads as enterprise jargon. They don't care about IAM; they care about whether the toy is safe for their kid.

**Two faces, one product**:

- **Consumer-facing brand and copy**: *"Control what your AI devices can remember, access, and do."* or *"Your AI memory follows you safely across devices."* — practical, benefit-led, parent-friendly. Brand candidates from earlier discussion: `scoped.ai`, `leash.ai`, `bonded.ai`. Don't say "IAM" in any consumer surface.
- **B2B / investor / technical**: *"AgentKeys is the Agent IAM and memory control plane for the AI device economy."* — category-defining, moat-articulating, comparable-anchoring.
- **Regulator / compliance**: *"Tamper-evident audit + cryptographic device identity + scoped capability tokens for AI device interactions."* — Trust Substrate framing.

Three audiences, three pitches, one product. Don't conflate.

---

## 4. Revised Phase 1 (ship in ~2 weeks)

### 4.1 Phase 1 goal

Prove in <5 minutes to a vendor that AgentKeys is Agent IAM, not chatbot infrastructure. Three behavioral properties visible end-to-end:

1. A device can read **permissioned** memory (not just memory)
2. Unauthorized actions are **deterministically denied** by policy, no LLM in the decision
3. A parent can **revoke** capabilities and the device complies immediately on the next online check

### 4.2 Phase 1 MCP server scope

Already-shipped backend (per CLAUDE.md Stage 7+) provides the heavy lifting:

| Capability | Status in backend |
|---|---|
| Broker (cap-token issuance + verification) | ✅ exists (`agentkeys-broker-server`) |
| Signer (K3 / K10 HDKD per arch.md §17) | ✅ exists |
| Memory worker (per-actor S3 isolation) | ✅ exists (`agentkeys-worker-memory`, issue #92) |
| Credential worker (per-actor + per-data-class isolation) | ✅ exists (`agentkeys-worker-creds`, issue #90) |
| Audit worker (off-chain + Heima anchoring) | ✅ exists (`agentkeys-worker-audit`) |
| OIDC issuer (federation) | ✅ exists |
| Per-actor + per-data-class isolation invariants | ✅ exists (issue #90) |

What we wrap with MCP for Phase 1 (~1 week of new code, thin layer over backend RPCs):

| MCP tool | Status in v1 |
|---|---|
| `agentkeys.identity.whoami(actor)` | **Active** |
| `agentkeys.memory.get(actor, namespace)` | **Active** |
| `agentkeys.memory.put(actor, namespace, content)` | **Active** |
| `agentkeys.permission.check(actor, scope)` | **Active** — deterministic policy engine, no LLM |
| `agentkeys.cap.mint(actor, op, params, ttl)` | **Active** — bounded TTL per §3.1 |
| `agentkeys.cap.revoke(cap_id)` | **Active** — immediate online; bounded offline |
| `agentkeys.audit.append(actor, event)` | **Active** — real-time off-chain feed; batched on-chain anchor per §3.2 |
| `agentkeys.delegation.grant(...)` | Documented schema only; returns `not_implemented_in_v1` per §3.3 |
| `agentkeys.delegation.revoke(...)` | Documented schema only |
| `agentkeys.approval.request(...)` | Documented schema only |

### 4.3 Phase 1 three-act demo storyboard

The demo runs on MagicLick 2.5 (xiaozhi-esp32 v1.9.4, unchanged) + stock xinnan-tech/xiaozhi-esp32-server with our MCP server registered in `mcp_server_settings.json` (per [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) MCP-direct pivot).

**Act 1 — Permissioned Memory** (not "smart memory")

- User says: *"Where am I going this weekend?"*
- Doubao/Qwen LLM in xiaozhi-server decides it needs memory context
- LLM calls `agentkeys.memory.get(actor=O_kevin_001, namespace="travel")`
- AgentKeys MCP server verifies cap-token, scopes the read to the `travel` namespace only (NOT `profile`, NOT `family`, NOT `work`)
- Returns Chengdu trip context
- LLM synthesizes response via TTS
- **Headline**: the device reads ONLY the memory namespace it's allowed to read — not "it knows you"; "it knows what it's allowed to know about you"

**Act 2 — Deterministic Denial** (no LLM in the policy decision)

- User says: *"Order me hotpot for ¥600"*
- LLM decides this requires payment authority; calls `agentkeys.permission.check(actor=O_kevin_001, scope="payment.spend", amount_rmb=600)`
- AgentKeys deterministic policy engine returns `denied: daily_spend_cap_exceeded (cap=500, requested=600, period=daily)`
- LLM (because we trained the prompt this way) refuses politely and explains
- Audit row appears in parent-control web UI **instantly**; Heima explorer anchor visible in next 10-min batch
- **Headline**: policy decides, not the LLM. Cap-bounded blast radius. Cryptographically auditable later.

**Act 3 — Online Revocation** (parent UI → device denies, bounded)

- Parent opens AgentKeys web UI (mobile-responsive, not native app)
- Taps "Revoke FoloToy payment access"
- AgentKeys revokes all cap-tokens scoped to `actor=O_kevin_folotoy_001, scope=payment.*`
- Demo: user attempts another spend → online permission check fails immediately → device refuses
- Audit row appears in real-time
- **Headline**: parent revokes; device complies on next online check. For high-risk actions = immediate. The runbook explains the layered TTL/cache model for offline scenarios (Act 3 doesn't need to demo this; just acknowledge it exists).

### 4.4 Phase 1 deliverables (non-implementation view)

| Deliverable | What it is | Why it matters |
|---|---|---|
| AgentKeys MCP server | 7 active tools wrapping existing backend RPCs | The integration surface vendors plug into |
| xiaozhi-server deploy with MCP config | Stock xinnan-tech build, our MCP server registered in `mcp_server_settings.json` | Demo runtime; vendor sees no fork required |
| Parent-control web UI (mobile-responsive) | One page: actor list, scope toggles, revoke buttons, audit feed | The face of "Agent IAM" — without this, Act 3 isn't a demo |
| Two-tier audit | Real-time off-chain feed + 10-min batched Heima anchor | §3.2 corrected architecture |
| Bounded revocation model | Immediate online; documented TTL/cache for offline | §3.1 corrected architecture |
| Three mock memory namespaces | `profile`, `travel`, `family` (only `travel` readable by demo actor) | Shows scoped access in Act 1 |
| Demo runbook + 15-min vendor pitch script | Operator can re-run; vendor sees value in 5 min | Distribution-ready |

### 4.5 What Phase 1 does NOT include

Explicitly out of scope. Each is the right move later, premature now.

- **Orchestration of any kind** (§2.4 hard line)
- **Active delegation** (§3.3 — schema only)
- **Approval workflows** (deferred to Phase 2 — needs more design)
- **Native mobile app** (§5.3 — web UI sufficient for v0, native after pilot)
- **Real-time on-chain audit** (§3.2 corrected — batched only)
- **Volcano Ark MCP server registration** (Phase 2)
- **Tuya Cloud connector** (Phase 2)
- **Hermes / OpenClaw as MCP tools** (Phase 3)
- **OAuth-for-Agents** or any standards body engagement (Phase 4-5)
- **Vendor-specific MCP tools or vendor onboarding portal** (Phase 2)

---

## 5. Revised 12-month roadmap

Sequenced to test the Agent IAM thesis with minimum viable surface, then deepen the moat with each phase.

### Phase 0 — Done (Stage 7+)

Broker, signer, memory/cred/audit workers, OIDC issuer, per-actor + per-data-class isolation (issue #90), Heima EVM integration, HDKD identity tree. All cap-token machinery shipped.

### Phase 1 — Agent IAM v0 demo (0-2 weeks)

Per §4. Goal: vendor understands AgentKeys ≠ chatbot in <5 minutes. MagicLick 2.5 + xiaozhi-server stock + AgentKeys MCP + parent web UI + three-act demo. Two-tier audit. Bounded revocation. Zero orchestration. Delegation as schema preview.

### Phase 2 — First vendor wedge + multi-rail reach (1-2 months)

Not "build many protocol surfaces." Land a real vendor pilot.

- Vendor configuration tools (vendor onboarding portal: tenant tokens, per-vendor billing, attributed devices)
- Device identity provisioning (vendor brings devices into AgentKeys, gets actor omnis back)
- Memory namespace template (for the "AI companion" product class: profile, work, family, child, travel, temp)
- Permission policy template (default-deny for sensitive scopes, sensible defaults for memory reads)
- Audit dashboard for parents (better UI than v0 web page; family-friendly)
- **Volcano Ark MCP marketplace registration** (open international signup per `tuya-vs-xiaozhi.md` Phase 3a)
- **Tuya Cloud Development connector** (Phase 2 from `tuya-vs-xiaozhi.md` original roadmap)

Goal: 1 paid vendor pilot signed at the $2-3/active-device/mo Basic tier from the office-hours pricing doc.

### Phase 3 — Runtime neutrality (3-4 months)

Prove "the same authority layer works across different agent runtimes."

- Hermes-MCP (`hermes.execute_task` as a callable tool — per yesterday's "agent-as-MCP-tool" decision)
- OpenClaw-MCP (same shape)
- Doubao agent compatibility (already covered by Volcano Ark Phase 2)
- Claude Code / Codex CLI compatibility (these are coding agents — different use case, but proves cross-runtime IAM works for developer-tier agents too)
- Python SDK + TypeScript SDK (for non-MCP integration paths)

Goal: 3+ runtimes integrated, demonstrably interoperable through the same AgentKeys backend.

### Phase 4 — Capability + revocation depth (6 months)

Take the half-spec'd v1 schemas and ship the deep versions.

- **Delegation chains in production** (parent agent → child agent with scope narrowing, TTL inheritance, revocation cascade, audit chain)
- **Approval workflows** (high-risk actions push to parent app for one-tap approval before execution)
- **Policy versioning** (vendors deploy new policies; existing devices upgrade with audit trail)
- **Audit replay** (regulator-grade reconstruction of any agent's authority history)
- **Memory namespace ACL maturity** (cross-vendor consent ceremony in production, not demo)
- **Family / work / kids memory separation** (the consumer narrative made operational)

Goal: first enterprise customer (could be a regulated B2B brand-owner — toy maker selling to schools, health-data-adjacent device maker, etc.).

### Phase 5 — Standards + ecosystem (post-12-months)

Only if Phases 1-4 land with deployed reference implementations and 10+ vendor partners.

- Propose MCP extensions for IAM-grade auth headers (session keys, cap-token forwarding, audit-chain headers)
- OAuth-for-Agents specification engagement (likely IETF or W3C working group)
- Reference implementations for non-MCP runtimes (raw HTTP / gRPC clients for vendors that don't use MCP)
- Brand-owner partnerships: Tuya, Xiaomi (per `tuya-vs-xiaozhi.md` Phase 3c "deferred"), Alibaba Smart Home

Goal: become the reference implementation that every new agent runtime + IoT cloud integrates with by default.

---

## 6. Strategic risks worth tracking explicitly

### Risk 1 — Hyperscaler absorption

Anthropic, OpenAI, Tencent, ByteDance could each build their own "Agent IAM" natively. Likely path: limited to their own walled garden (Claude permissions in Claude's ecosystem only, etc.).

**Mitigation**: be the cross-platform layer they CANNOT credibly build (since each would only do their own walled garden). Race to neutral adoption across vendors before any one hyperscaler ships a closed equivalent that everyone defaults to.

### Risk 2 — Over-extension into orchestration

Vendor asks: "can you also handle X workflow?" → mission creep → we become "another agent runtime" → we lose Authority Host neutrality.

**Mitigation**: §2.4 hard line, documented in this doc, referenced in every product conversation. If a vendor needs orchestration, they pick a runtime; we provide the authority around it.

### Risk 3 — Weak consumer face

If AgentKeys is invisible to end-users (no app, no consumer brand), vendors can't justify the upgrade tier. The B2B sale alone doesn't sustain the model — vendor base fee ($2-3/device/mo) is thin; the $10/$20 consumer upgrade is where margin is. Without a consumer face, no consumer upgrades.

**Mitigation**: parent-control web UI is Phase 1. Mobile-responsive. Native mobile app is Phase 2 (only after the v0 web UI proves we know what the UX should be). Brand naming + consumer-facing landing page is Phase 1.5.

### Risk 4 — Pure neutrality = no adoption

Switzerland-grade neutrality without product-market traction = LDAP-grade obscurity. Standards bodies listen to deployed code, not pitches.

**Mitigation**: be the reference implementation everyone defaults to, not just a spec. Open-source the SDK + MCP server (already MIT-aligned with the broader ecosystem). Charge for hosting + premium features (consumer upgrade tier, vendor enterprise tier). Standards engagement only after 10+ vendor deployments.

### Risk 5 — Premature standards work

Engaging IETF / W3C / OpenAPI / MCP spec working groups before we have deployed reference implementations = looking like a vendor lobbying for spec changes that benefit our positioning. Bad optics, weak influence.

**Mitigation**: deploy → grow → propose. Standards work is post-12-months.

### Risk 6 — Memory eclipses authority in the narrative

If we lead every pitch with "memory portability," we get categorized as "Mem0 / Zep / Letta competitor" — and lose the IAM moat. Memory is one of many authority surfaces, not the headline.

**Mitigation**: every Phase 1 demo, deck, and one-pager leads with the three behaviors together (permissioned memory + deterministic denial + revocation). Memory alone is the smallest of the three. Authority is the category.

### Risk 7 — Privacy positioning trap

Privacy is a benefit, not a category. "Privacy product" is crowded (Brave, DuckDuckGo, Signal, etc.) and easy to commoditize. Authority is the category that produces privacy as one of its outputs.

**Mitigation**: never lead with "privacy." Lead with "control" (consumer narrative) or "authority" (B2B narrative). Privacy follows naturally and is a strong supporting benefit.

---

## 7. What this strategic anchor changes about existing docs

| Doc | Update needed |
|---|---|
| [`ai-hardware-companion-office-hours.md`](./ai-hardware-companion-office-hours.md) | Update positioning note at top to point at this strategy doc + add Agent IAM framing + three-narrative reality. Substance below the banner stays. |
| [`ai-hardware-companion-wedge.md`](./ai-hardware-companion-wedge.md) | Update positioning sections — sharper "Agent IAM" framing; keep market sizing + competitive analysis as-is. |
| [issue #103 plan](../spec/plans/issue-103-aiosandbox-hermes-esp32-demo.md) | Pivot demo storyboard to the three-act IAM demo per §4.3. Add parent-control web UI deliverable. Note the four corrections (bounded revocation, two-tier audit, delegation-as-preview, zero orchestration). Implementation detail unchanged (cap-token machinery already exists). |
| [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) | No change — MCP-direct pivot still correct. |
| [`volcano-ark-mcp-integration.md`](./volcano-ark-mcp-integration.md) | Minor: clarify Phase 2 timing per §5 above; tool inventory unchanged. |
| [`tuya-vs-xiaozhi.md`](./tuya-vs-xiaozhi.md) | No change — complement-not-compete framing still correct. |
| [`xiaozhi-hermes-risks.md`](./xiaozhi-hermes-risks.md) | No change — risk analysis still applies; many risks evaporate under MCP-direct. |

---

## 8. The one-sentence summary

> AgentKeys is the **user-owned authority layer for the AI device era** — Agent IAM to technical buyers, "your AI memory follows you safely" to consumers, tamper-evident trust substrate to regulators. We stay infrastructure; we never become an agent runtime; we work with Hermes / OpenClaw / Claude Code / Doubao / xiaozhi / any agent that needs identity, memory, permissions, capabilities, and audit. They do the work; we control the authority to do the work.

---

## 9. Sources + lineage

- **Original proposal**: pasted in chat 2026-05-24 — "AgentKeys Strategic Direction: Agent IAM for the AI Device Era." Captured §1-14 of the strategic framing.
- **Independent analysis (this AI)**: pushed back on consumer/B2B positioning tension, sequencing of multiple integration surfaces, standards timing, demo storyboard.
- **ChatGPT critique**: four architectural corrections (bounded revocation, two-tier audit, delegation-as-preview, dual-narrative) + the three-layer positioning framework (AI Device Account / Agent IAM / Trust Substrate).
- **This doc**: synthesis of all three. Source of truth for Agent IAM positioning + Phase 1 scope + roadmap. Future planning references this anchor.

Companion architectural research:
- [`ai-hardware-companion-wedge.md`](./ai-hardware-companion-wedge.md) — market + competitive landscape
- [`ai-hardware-companion-office-hours.md`](./ai-hardware-companion-office-hours.md) — wedge brainstorm + Approach D selection
- [`xiaozhi-esp32-magiclink.md`](./xiaozhi-esp32-magiclink.md) — hardware identification + Option 1 decision
- [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) — MCP-direct architecture
- [`xiaozhi-hermes-risks.md`](./xiaozhi-hermes-risks.md) — risk verification
- [`volcano-ark-mcp-integration.md`](./volcano-ark-mcp-integration.md) — Volcano Ark MCP-server adapter
- [`tuya-vs-xiaozhi.md`](./tuya-vs-xiaozhi.md) — Tuya vs xiaozhi role comparison + Phase 3 feasibility
