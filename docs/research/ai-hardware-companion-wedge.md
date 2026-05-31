# AI-Hardware Companion Wedge — Business Research

**Status:** Exploratory business brainstorm, not a committed plan. Inputs are the product draft pasted in chat 2026-05-23 plus two parallel competitive + pricing research passes (citations in §8). The intent is to give the team a decision-grade artifact for whether to pursue an AI-hardware-companion GTM as the demo wedge for AgentKeys, and on what terms.

**Decision asks documented in this file:**

1. Pick the wedge: hardware-vendor permission infra (W1), consumer identity layer (W2), or audit ledger (W3) — see §5 C7. Recommendation: **W1 first, W2 as moat, W3 as compliance flavor**.
2. Drop the $10 vendor-billed price; restructure to vendor base fee + consumer upgrade with revshare — see §4.
3. Lead the pitch with cross-device portability + child-safety, not "identity for agents" — see §5 C10.
4. First design-partner outreach: FoloToy, then Ropet, then BubblePal — see §5 C8.
5. Validate Alipay+ AMP as a partnership channel, not a competitor — see §5 C4.
6. Set a kill criterion: 0 paid pilots from 3 priority vendors in 6 months → pivot — see §5 C12.

---

## Contents

**Round 1 (initial research):**

1. Market size + opportunity
2. Competitive landscape (the agent-identity SaaS category is saturated; hardware is open)
3. Direct competitors
4. Business model — three unit-economics holes in the current draft
5. Critical comments (C1–C12)
6. Naming — picks in the `boundry.ai` / `scoped.ai` vein
7. What to do next (sequenced) — *superseded by §9.7*
10. Sources (round 1)

**Round 2 (Q&A + reframe + new pricing + integration paths):**

- 9.1 Q&A on the 13 round-1 questions
- 9.2 Reframed pitch + product flow (security / convenience / portability frames)
- 9.3 Updated payment structure ($1.50/device vendor + $10/$20 consumer revshare)
- 9.4 Alipay+ AMP vs Stripe ACP — sequenced integration (ACP Q3, AMP Q4)
- 9.5 WeChat integration — what's actually feasible
- 9.6 Security-first demo storyboard (updates C1)
- 9.7 Updated next moves (replaces §7)
- 9.8 Round-2 sources

---

## 1. Market size + opportunity

The Chinese AI-toy market alone was **$3.5B+ in 2025 with 1,500+ vendors and 1.8M units shipped in H1 2025**. FoloToy hit 20K units in Q1 2025 and powers ByteDance's internal "Eye-Catching Bag" gift program. Ropet (CES 2025 darling, $299), BubblePal/Haivivi ($99 clip-on), and MOMOTOY (200% revenue growth over three months) all ship today as **stateless model-callers** — no persistent user identity, no cross-device memory, no permission model, no spend cap, no audit log. Cybernews flagged AI toys leaking child voice data in 2025 with no parental scoping — that's a regulatory bomb that maps directly onto the AgentKeys pitch.

US side is more interesting as a *warning* than as a market. Humane Pin imploded (HP bought the IP), Rabbit R1 flopped and re-teased a next-gen for 2026, Limitless was acquired by Meta in Dec 2025 with the hardware sunsetting, Friend.com shipped ~30K $99 necklaces. The English-speaking hardware companion market is a graveyard of standalone devices that couldn't bridge to user identity. **China is where the volume is — and where the identity/permission gap is most acute.**

## 2. Competitive landscape — saturation at the SaaS tier, opening at the hardware tier

Six well-funded direct competitors already ship the SaaS-side pitch the draft described:

| Competitor | What they ship | Overlap with draft | Their gap |
|---|---|---|---|
| **Privy (now Stripe)** | Embedded wallets, programmable policy, spending caps, "Agent Wallets" GA | ~55% | No hardware story, no cross-device memory, no per-device identity |
| **Coinbase AgentKit + x402** | MPC agent wallets, session caps, per-tx limits, gasless on Base | ~50% | Crypto-first, no consumer hardware, no memory |
| **ScaleKit** | Org-scoped agent identity, MCP authz ($49/mo for 200K tool calls) | ~50% | B2B SaaS only, no hardware fleet model |
| **Permit.io** | Fine-grained authz for agents, "zero standing perms" | ~40% | Pure policy engine; no wallet, payments, memory |
| **Stripe Agentic Commerce Suite / ACP** | Open agent-payment standard, co-authored with OpenAI | ~45% | Merchant-side, not device-side identity binding |
| **Alipay+ Agentic Mobile Protocol** | User-defined spend boundaries for agents (China) | ~50% on China spend-cap angle | China-only, Alipay-locked, no cross-device identity |

**The agent-identity/wallet pitch is crowded.** Privy now has Stripe distribution; Coinbase has the crypto rail; ScaleKit owns B2B; Alipay+ AMP owns China spending caps as a *platform-native* primitive (launched 2025, 100M+ Alipay AI Pay users by Feb 2026). If we pitch "identity + wallet for agents" generically, we're startup #7 in a category where #1 just got bought.

**Hardware is the unoccupied slice.** *Nobody* ships "drop this SDK in your AI plush / pendant / AI glasses and the user gets one identity that survives the device, with cross-vendor memory portability." Mem0 pitches portable memory but it's an API for app developers, not a device-identity layer. Personal.ai, Rewind→Limitless (dead), Memex — all assume the *app* is the identity unit, not the *user* with devices as ephemeral leaves.

### The four-way defensible wedge

Pick all four or we're undifferentiated:

1. **Hardware-vendor B2B2C distribution** (not selling to app developers)
2. **Cross-device + cross-vendor memory + identity portability** (the user is the root, the device is a leaf)
3. **China-stack-aware** (sits *above* Alipay+ AMP and Tencent ClawPro, doesn't try to replace them)
4. **Child-safety / parental-scope** angle for the toy segment (regulatory tailwind from the Cybernews exposé and similar incidents)

Without those four, we're Privy with a worse distribution story.

## 3. Direct competitors — extended detail

### Hardware vendors (potential design partners, not competitors)

**China (the volume market):**

- **FoloToy** — Q1 2025 shipped 20K customizable AI plushies; powers ByteDance's "Eye-Catching Bag." Supports Doubao, GPT, Qwen, DeepSeek, Ernie. **No identity/permission layer.** *Highest-fit first design partner.*
- **Ropet** ($299–329) — ChatGPT-backed plush, CES 2025 standout. No identity infra.
- **BubblePal / Haivivi** ($99) — clip-on attachment for existing plushies; child-focused. *Best fit for the child-safety regulatory tailwind.*
- **MOMOTOY** — 200% revenue growth in 3 months (2025).
- **ByteDance Volcengine** — supplies LLM backend ("Eye-Catching Bag" internal gift program). Doubao is the platform model.

**US/Western (mostly struggling or pivoted):**

- **Rabbit R1** ($199) — original flopped; "next-gen" device teased for 2026.
- **Humane AI Pin** — imploded; HP acquired the IP, hardware discontinued.
- **Friend.com** ($99 necklace) — ~30K units shipped; no memory portability, no permissions.
- **Limitless** — Pendant $299; **acquired by Meta Dec 2025**, hardware sunset in ~1 year.
- **Meta Ray-Ban Wayfarer Gen 2** ($379) — best-selling AI glasses; Meta-locked, not addressable.

### Identity / wallet / credentials infrastructure (real competitive set)

- **Privy** (now Stripe-owned) — embedded wallets + Agent Wallets product; free dev tier (50K sigs, $1M volume), Scale $299/mo for 500–2,499 MAU. **Direct competitor on wallet/identity slice.**
- **Coinbase CDP / AgentKit** — open-source agent wallet framework + MPC server wallets GA July 2025. Programmable session caps, per-tx limits, gasless on Base, x402 native. **Direct competitor on wallet+spend-cap slice.**
- **ScaleKit** — org-first identity for B2B AI; users/agents/MCP clients per org. Free 5K agent tool calls, $49/mo for 200K. **Direct competitor on B2B identity slice.**
- **Privy/Dynamic/Crossmint/Turnkey** — agent-wallet players, Web3-leaning. Adjacent.
- **Clerk** — B2C auth, free 10K MAU, $0.02/MAU after; added "AI Authentication." Adjacent.
- **Stytch** (acquired by Twilio 2025) — "Connected Apps" for OAuth 2.1 + MCP authz. Adjacent.
- **AgentMail** — per-inbox billing, gives agents an email identity. Complementary.
- **Letta / MemGPT** — open-source agent memory. Complementary.
- **Mem0** — free 1K memories, $19/mo for 10K, Pro $249/mo with graph memory; 47K GitHub stars. Complementary.
- **Zep** — temporal knowledge graph, free 1K episodes, $25–475/mo. Complementary.
- **Composio** — tool authz integration platform. Complementary.

**Honest read:** identity/wallet for agents is saturated (Privy/Stripe, Coinbase, Crossmint, Turnkey, Dynamic, ScaleKit, Clerk-AI, Stytch). The differentiator must be the hardware-device angle and the cross-device memory portability — not "we sign for agents," because seven well-funded players already do that.

### Permission / sandbox infrastructure

- **E2B** — Apache-2.0; ~150ms cold-start Firecracker sandboxes; **15M sessions/month by March 2025** (up 375x in a year). Compute sandbox, not policy. Complementary.
- **Modal** — stateless GPU/compute sandboxes for agents. Complementary.
- **Fly Machines** — adjacent compute primitive.
- **Permit.io** — fine-grained authz; supports OPA/Cedar/OpenFGA; "zero standing permissions" pitch explicitly courts AI agents. **Direct competitor on the policy slice.**
- **Cedar (AWS-originated)** — policy DSL, often paired with OPAL.
- **OPA / OPAL** — Rego policy engine, real-time sync layer.
- **AuthZed / SpiceDB** — Zanzibar-style relationship authz. Adjacent.
- **Composio** — tool-level authz scoping for agent tool calls. Complementary.

**Honest read:** permission engines (Permit.io, Cedar, OPA, AuthZed) are mature and AI-agent-rebranded but **none target hardware device fleets** — they all assume server-side agents. Real opening.

### Agent payment / spending caps

- **Stripe Agentic Commerce Suite + ACP (Agentic Commerce Protocol)** — open standard for agent-driven checkout; Stripe + OpenAI co-authored. Owns Privy now. **Direct competitor.**
- **Coinbase AgentKit + x402** — programmable session caps, per-tx limits, MPC-secured agent wallets, gasless. **Direct competitor on crypto rail.**
- **Skyfire** — "Agent Passport" reputation scores + spending history; Visa Trusted Agent Protocol pilot partner. Adjacent.
- **Catena Labs** — AI-compliant bank (KYA, custody, clearing). Adjacent infrastructure.
- **Payman** — daily caps + per-tx limits as a product surface.
- **Mercury / Ramp / Brex AI** — corporate card AI features, not consumer-device-agent oriented. Adjacent.

### Chinese stack specifics

**Real path, surprisingly mature:**

- **Alipay AI Pay** (launched 2025, 100M users by Feb 2026) — first AI-native payment globally at that scale. Has **Payment MCP Server**, Payment Integration Skill, AI Tipping, AI subscription payment.
- **Alipay+ Agentic Mobile Protocol** — users explicitly define what agents can spend, where, and how much. **Spending caps as a first-class platform feature.**
- **Tencent ClawPro** — OpenClaw-based agent deployment with token-consumption tracking + security compliance.

**Implication:** in China, Alipay/Tencent are *building the spending-cap layer themselves as platform-native* — a third-party "WeChat spending cap for agents" is not a clean wedge because Alipay+ AMP is the official protocol. A third party could plausibly sit *above* Alipay+ AMP as a multi-tenant/multi-device orchestrator (binding caps to hardware identities), but cannot undercut the rail itself. **Hard no on going under Alipay; possible yes on going over it.**

Default monthly WeChat Pay transaction limits (RMB 50K) and Alipay annual caps ($50K verified) are user-account limits, not delegation primitives — sub-balances / programmatic budget delegation for third parties are not exposed publicly.

### Cross-vendor portability — the cleanest unoccupied slice

- **Personal.ai** — personal AI memory subscription, ~$40/mo tier. Adjacent.
- **Rewind → Limitless → Meta** — portability story dead; absorbed into Meta's stack.
- **Mem0** — "portable memory" pitched explicitly; SDK-level not device-level. Complementary.
- **Memex / Heyday-style** — small, fading.

**No vendor today ships "your AI identity + memory follows you across hardware devices"** as a productized layer for third-party device makers. Closest is Mem0's SDK pitch, but that's an API, not an identity-bearing portable layer.

**This is the cleanest unoccupied slice.** Every memory player assumes the *app/agent* is the unit of identity. None treat the *user* as the persistent root with devices as ephemeral leaves.

## 4. Business model — three unit-economics holes in the current draft

### Hole 1: Free tier breaks the math

The proposed Free tier (2 devices, 1 account, memory storage, light audit) has **negative contribution margin** as drafted. Realistic per-user COGS at retail cloud prices:

- AWS KMS: **$1.00/key/mo** (this alone kills it if we mint one customer-managed key per free user)
- S3 + vault bucket: ~$0.05
- Memory store (S3 + light vector): $0.10–$0.50
- Audit (Datadog-equivalent + on-chain anchor): ~$0.20
- Broker compute amortized: $0.50–$1.00
- KMS ops + STS calls + egress: ~$0.15

Naive total: **$2–$3/free user/mo**. Median B2B SaaS free→paid conversion is ~8%. Math: 100 free users × $2.50 COGS = $250/mo burn; 8 convert to Basic at $10 = $80 revenue. **We lose $170/mo per 100 free users.**

The fix is envelope encryption with a *tenant* KMS master key (not per-user), auto-pause inactive free accounts after 30 days (Supabase plays this card), and cap free at 1 device. Marginal COGS drops to <$0.30 and the funnel turns positive.

### Hole 2: "Vendor pays for cross-vendor user usage" is bad unit economics

The draft says "if a user has 3 devices across 3 vendors, each vendor pays for storage." This implies a fairness formula to split a shared user's cost across competing vendors. **Nobody buys SaaS that asks them to subsidize their competitors.** Plaid and Auth0 don't do this — each vendor pays for *their own attributed usage* on the same user, with no settlement between them.

Fix: bill per *device*, attributed to one vendor. The user is free across vendors; the device (the vendor-scoped touchpoint) is the billable unit. If a user has 3 devices across 3 vendors, each vendor's bill shows 1 device. No cross-vendor accounting.

### Hole 3: $10/mo consumer price ≠ hardware vendor willingness to pay

Hardware vendors pay infra fees at **$0.50–$3/device/mo** because their BOM accounting can't absorb $10/mo per shipped unit (AI companion toy BOM margins are $30–$50). The closest analog is **Tuya** (the Chinese IoT cloud platform serving thousands of OEMs) — flat per-device cloud fee + optional feature unlocks.

We're confusing the consumer subscription price ($10/mo, paid by end-users who upgrade) with the vendor base fee (should be ~$1–$2/device/mo). They're two SKUs in the same model, not the same SKU.

### Recommended pricing structure

A three-layer model that survives the unit economics:

| Layer | Buyer | Price | What it covers |
|---|---|---|---|
| **Vendor base fee** | Hardware OEM | $1–$2/active device/mo flat | Identity issuance, baseline storage, light audit. No cross-vendor settlement. |
| **Consumer upgrade** | End user | $10/mo Basic, $20/mo Pro | LLM key minting, full audit, memory premium retention, key rotation. **Vendor takes 30% revshare on the consumer subscription** — gives them upside without breaking BOM. |
| **Usage overage** | Hardware OEM | Per-event passthrough | Chain audit events beyond N/mo at ~$0.01/event, KMS ops beyond 10K/user at AWS passthrough + 30%. |

This survives because: (a) vendors pay a price they actually pay today (Tuya-shaped), (b) they get upside from high-LTV users without underwriting them, (c) free tier auto-pauses so unit economics stay positive, (d) no cross-vendor settlement formula.

### On the sandbox-vs-identity question

The "$3 profit sandbox vs $8 profit AgentKeys" framing in the draft is directionally right but **overstates the gap**.

Real sandbox COGS (E2B at $0.05/vCPU-hr, Modal at $0.07): a sandbox running 8 hr/day at 0.5 vCPU = ~$6/mo compute alone, $7–$9 with storage/network/isolation. So $7 sandbox COGS is accurate.

Real AgentKeys COGS at Basic tier (conservative with envelope encryption): **$3–$4/mo**, not the implied $2. The 2x gap is real. **Not 3.5x.**

But more importantly: **sandbox isn't a substitute for AgentKeys, it's a complement.** A vendor still needs sandbox compute *somewhere* to execute MCP tools. The real choice isn't "AgentKeys vs sandbox" — it's "do we resell sandbox compute or just sell identity/permission and let the vendor BYO sandbox." The draft instinct (don't resell early) is correct, but for a different reason than profit margin: **reselling sandbox compute drags us into competing with E2B/Modal/Fly at thin margins, while the identity+permission layer is uncontested at the hardware tier**. Stay in the unoccupied slice.

## 5. Critical comments

Numbered for argument tracking. Expect pushback on at least three.

### C1 — The demo is a *capability* demo dressed as a *security* demo

"Hey Kevin, did you handle customs clearance" and "book me spicy Sichuan dinner" are the Siri 2011 demos. They show the toy is *smart*. They don't show why AgentKeys is the only way to ship it safely. **A demo that wins the pitch shows the security model winning:**

- Vendor A's plushie writes to memory; vendor B's pendant **can read but not write** (cap-data-class mismatch returns 403, visible on Heima explorer).
- Toy tries to spend ¥600 on Meituan; daily cap is ¥500; **cap-burn rejection logged on-chain** with the receipt URL printable.
- User revokes toy in the app; toy's next request returns `cap_revoked`, demonstrated live.

The current demo says "this is a smart toy." The demo we want says "this is the only smart toy whose blast radius is bounded by math, not by trust."

### C2 — "Mint LLM API keys from email, no KYC" is the most fragile assumption in the plan

OpenAI and Anthropic enforce KYC on paid accounts. Doubao requires Chinese real-name verification. Kimi has phone-binding. **OpenRouter works** — but only for API access, not subscriptions (and we'd need a wallet bridge to fund it). The "user says 'switch me to Kimi'" auto-subscription flow described in the doc has no clean execution path today, except via the agent's *own* card-on-file that we funded — which means *we* are KYC'd, not the user, and we're the merchant of record absorbing chargeback risk.

Two real paths: (a) OpenRouter-only mode with a custodial USDC/fiat balance we mint per user (clean but limits LLM choice), (b) skip the "auto-subscribe to commercial LLMs" feature entirely and let users paste their own API keys (boring but ships). Pick one. Don't pretend (c) "we'll figure it out" — that path is a year of API-relationship work.

### C3 — The WeChat business chatbot stream is gated behind real-name corp registration

We can build a WeChat Service Account (公众号) that streams chat history between user and hardware toy. We **cannot** without (a) a Chinese ICP-licensed business entity, (b) real-name corp verification, (c) Tencent's per-category content moderation (especially for any AI-related content where the rules tightened post-2024). This is months of compliance work, not an SDK integration. **Tencent ClawPro is what we actually want to integrate against**, not raw WeChat APIs. ClawPro is OpenClaw-based agent deployment with token-consumption tracking already built in — meet them where they are.

### C4 — "Sub-balance on WeChat / Alipay" is a hard no on the user side, but Alipay+ AMP changes everything

Neither WeChat Pay nor Alipay exposes a developer API for end-user sub-balances with third-party spending caps. The user-account caps (WeChat ¥50K/mo, Alipay annual KYC tiers) are platform-side, not delegation primitives. But — and this is the strategic pivot the draft is missing — **Alipay+ Agentic Mobile Protocol shipped 2025 with user-defined spending boundaries for agents as a first-class platform feature** (Alipay AI Pay hit 100M users by Feb 2026).

So the answer to question 3 is: **stop trying to build a sub-balance feature; instead, position AgentKeys as the multi-device, multi-vendor wrapper that orchestrates Alipay+ AMP delegations across the user's device fleet.** Alipay+ AMP gives the agent a budget; we give the *device fleet* a coordinated identity-and-policy layer above that budget. This is a *complementary* play, not a competitive one. The Alipay business development conversation becomes easier because we're a distribution partner, not a competitor.

### C5 — "Audit on Heima blockchain" is a tax unless framed as moat

Blockchain audit costs money (~$0.01/event on Substrate parachains, batched anchoring drops this to fractions of a cent per event). Hardware vendors in China don't intrinsically care about blockchain audit — they care about **MIIT/PIPL-friendly logs for kid safety regulators**. Reframe Heima audit two ways:

1. **Operator-facing**: "regulatory-grade tamper-evident audit, exportable on demand, in a format Cyberspace Administration accepts." Sell the compliance moat. Mention Heima only as plumbing.
2. **Consumer-facing**: "every action your toy takes is on a public ledger you can browse." Sell trust theater. Mention Heima only when it adds credibility.

If we describe "actions on Heima blockchain" as a feature without one of these frames, it reads as "we made it more expensive for the sake of cool architecture." Operators won't buy that.

### C6 — The "agentkeys-submit-memory skill" is a workaround that doesn't scale to the buyer

If memory upload requires the user to install a skill in their *local* LLM, we've taxed the very ecosystem we need to win. Buyers of an AI plushie are 8-year-olds' parents, not techies running a daily skill in Claude Code. The memory upload has to happen **wherever the user already is**:

- Browser extension that scrapes ChatGPT/Claude/Kimi/Doubao chats with consent
- Mobile app SDK the hardware vendor embeds
- MCP server the user's *commercial* LLM (ChatGPT Plus, Claude Pro) talks to directly
- Optionally: WeChat Service Account that ingests chats from a Tencent-blessed channel

The skill is fine for the dogfood phase. It is not a scalable memory-ingestion path. Plan to retire it within 6 months of pivot launch.

### C7 — Pick one wedge. The draft has three.

Reading carefully, the doc describes three different products:

- **W1**: "hardware vendor permission infra" — sell to FoloToy, Ropet, smart-glass startups. B2B2C. Per-device pricing.
- **W2**: "consumer identity layer for AI" — sell to users. Cross-app/cross-device memory portability. End-user subscription.
- **W3**: "agent operations audit ledger" — sell to compliance teams / regulators. Per-event Heima anchor.

All three are good ideas. Picking *one* to dominate first is missing. Read: **W1 is the wedge because the partner conversation is concrete (FoloToy exists, has 20K Q1 units, ships stateless chatbots, has zero identity infra). W2 is the moat that makes W1 sticky once we have 3+ vendor partners (the user's memory is portable across vendors, which no single vendor can offer). W3 is the compliance flavor on top of W1.** Sequence: W1 → W2 once we have 3 vendors → W3 if a regulator forces it.

### C8 — The first-call vendor is FoloToy, not Rabbit / Friend / Limitless

Of all the hardware vendors in the research, **FoloToy is hyperfit** — 20K+ Q1 2025 units, supports Doubao + GPT + Qwen + DeepSeek + Ernie (no LLM lock-in), powers ByteDance's gift program, has zero identity/memory/permission infra. They're already integrating with everyone. They will integrate with one more thing that gives them a per-user feature they can charge for. Get a meeting via Volcengine warm intro if possible.

Second call: **Ropet** ($299 CES darling, ChatGPT-backed, US-coverage angle). Third: **BubblePal/Haivivi** ($99 child-focused — best for the child-safety regulatory tailwind).

### C9 — The 5x markup hand-wave is wrong, but the underlying instinct is right

The draft wrote "sandbox $3 profit, AgentKeys $8 profit" → don't be a sandbox reseller. Numbers are off (real margins are ~$3 vs ~$6, not $3 vs $8) but the conclusion is correct for a *different* reason than profit: **reselling sandbox compute drags us into competing with E2B/Modal/Fly at commodity margins, while the identity+permission layer is uncontested at the hardware tier**. Don't be a sandbox reseller because we'd be undifferentiated, not because the margins are bad.

### C10 — Cross-vendor portability is the most defensible moat — lead with it

The single most important insight from the research: **no vendor today ships "your AI identity + memory follows you across hardware devices" as a productized layer for third-party device makers**. Every memory player (Mem0, Zep, Letta) sells to app developers, not device makers. Every identity player (Privy, Coinbase AgentKit, ScaleKit) sells to app/agent developers.

We're the first one selling identity + memory + permissions as a layer that *binds physical devices to a portable user root*. This is also why vendors will eventually accept us: once 2+ vendors integrate, the user has a real reason to pick a 3rd vendor that integrates (their memory comes with them), and the 3rd vendor has a real reason to integrate (the user already exists in our system). This is the network effect — and **the moment we have it, vendors can't easily defect** because their users would lose memory portability.

**Lead the pitch with this. Not "permissions." Not "wallet." Not "audit." Lead with: *one identity, follows the user, works across every hardware vendor that integrates.* The permissions/wallet/audit are how we deliver it safely.**

### C11 — Heima as the chain is a B2B *liability* unless we sell it as boring

Hardware vendors in China don't want to integrate with "Heima blockchain" — that's a sales-cycle friction point. They want to integrate with "AgentKeys cloud, audit endpoint." Hide Heima behind the API surface. Use it as plumbing. If a compliance team asks "where are the logs," answer "tamper-evident ledger you can export anytime." Only if they push deeper, mention Heima. Same way Stripe doesn't lead with "we use Postgres."

This is consistent with the *ecosystem* (Heima) being umbrella infrastructure and AgentKeys being the productized layer — but the marketing has to do that work, not the architecture deck.

### C12 — The plan needs a kill criterion

What does failure look like? Read: **if 0 of 3 priority hardware vendors (FoloToy, Ropet, BubblePal) signs a paid pilot within 6 months, the wedge is wrong.** Not the execution — the *wedge*. Either the value isn't real, or the buyer isn't who we think it is.

If that triggers, the obvious pivot is: **reposition from "hardware identity layer" to "MCP credential broker for consumer agent apps"** (existing AgentKeys for Claude Code/Cursor/Doubao users) and let the hardware angle be a demo case, not the GTM. AgentKeys infra works fine for this; the hardware play is the riskier bet.

## 6. Naming — picks in the `boundry.ai` / `scoped.ai` vein

The two suggested names already land on the two best brand axes. Top picks with reasoning:

| Name | Vibe | Why it works | Why it might not |
|---|---|---|---|
| **scoped.ai** | Technical, precise | Permission-scoping is the technical core; B2B buyers (vendor CTOs) get it instantly; .ai works | Slightly cold for B2C upgrade tier; "scoped" is jargon to a toy-buying parent |
| **leash.ai** | Vivid, consumer | Memorable, "AI on a leash" maps perfectly to bounded-scope agents; works B2C (parent-friendly), and B2B ("we keep their AI on a leash for them") | Slightly aggressive; "leash" has dog connotations that some find off |
| **bonded.ai** | Warm, ceremonial | Captures the device-binding ceremony + companion vibe; works for both AI-toy and serious infra; "bond" = trust | Could read as crypto-DeFi-bonding (false signal) |
| **envoy.ai** | Diplomatic, B2B | "Your agent as your envoy with delegated authority" — strong agent-acts-on-your-behalf framing | Less memorable than leash; envoy.com etc taken |
| **pact.ai** | Short, agreement | Pact = signed agreement between user, device, agent; fits the cap-token / signed-policy model exactly | Slightly mystical |

**Recommendation:**

- **One name for both B2B and B2C: `scoped.ai`** (user-friendly enough; technically precise; uncomplicated story for vendors)
- **Consumer-grade brand + separate B2B name: `leash.ai`** for consumer + AgentKeys keeps the B2B/infra layer

Check domain + trademark availability — both are clean for usual squatters but no TM search done yet. Also worth checking Chinese-language brand resonance: 范围 (scope) and 缰绳 (leash) both translate cleanly, with 缰绳 having a stronger emotional pull for the toy-parent buyer.

## 7. What to do next (sequenced)

1. **Reframe the pitch to lead with cross-device portability + child-safety, not "identity for agents."** The crowded category is the latter; the unoccupied slice is the former. One sentence: "The user-identity layer that lets your AI device know who its owner is, what their other AIs already know, and what it's allowed to do — with audit."

2. **Drop the $10 vendor-billed price; restructure to per-device base ($1–$2/device/mo to vendor) + consumer upgrade ($10/$20 with 30% vendor revshare).** This is the only structure hardware OEMs will sign.

3. **Build the demo around the *security* properties, not the *capability* properties.** Show: cross-vendor memory portability (vendor A's toy reads vendor B's toy's notes after consent), cap-burn rejection on Heima explorer when toy hits ¥500/day limit, real-time revocation from app. Drop the "buy me Sichuan food" hero scene unless it's *also* showing a cap-token getting decremented live.

4. **Call FoloToy this week.** Highest-fit first design partner — high volume, LLM-agnostic, no existing identity story, regulatory pressure incoming.

5. **Validate the Alipay+ AMP path.** The China spend-cap story changes from "build something WeChat doesn't expose" to "be the multi-device wrapper above AMP." This is potentially a partnership conversation with Ant Group's Alipay+ team, not a competitive build.

6. **Write the one-page child-safety story.** "Three AI plushies on the market leaked child voice data in 2025. AgentKeys (or scoped.ai / leash.ai) is the only product that scopes a device's data access by parental policy with on-chain audit." The kind of one-pager that opens vendor doors *and* gets regulator-friendly press.

7. **Kill criterion: 0 paid pilots from 3 priority vendors in 6 months → pivot to consumer agent-app MCP credential broker.** Set this now while emotion is low.

## 9. Round 2 — Q&A, reframed pitch, updated pricing, integration paths

After the first round, 13 clarifying questions and three structural asks (reframe the pitch, redesign the payment structure, validate Alipay+ AMP vs Stripe ACP). This section delivers all three on top of point-by-point answers.

### 9.1 Q&A on the 13 round-1 questions

**Q1 — Why is AWS KMS $1/key/mo *per user*? Does a tenant master conflict with current arch?**

The $1/mo is per AWS KMS Customer Master Key (CMK), not per user. The hole is only opened if we mint one CMK per user. **The fix is envelope encryption: one tenant master CMK ($1/mo total) + per-user data keys (DEKs) generated via `kms:GenerateDataKey` at $0.03/10K ops.** Per-user DEKs are cheap and don't touch the per-key floor.

This is **consistent with the existing AgentKeys architecture**, not in conflict. Per [`docs/arch.md`](../arch.md), the identity model is an HDKD actor tree — the master device key is the root-of-trust, per-actor keys derive from it. The KMS-rooted CMK only needs to anchor the *broker-side* data-encryption-key derivation (K3 credentials at rest, audit anchoring), not every user's actor key. The HDKD model already does the per-user derivation off-chain; KMS just holds the tenant master. **No arch change needed; just verify the broker's K3-at-rest encryption uses envelope encryption with a single tenant CMK, not per-user CMKs.**

**Q2 — Memory free tier can be capped; broker compute amortizes at scale. How to optimize free-tier COGS?**

Both true. Updated free-tier COGS model at 1K-user scale:

| Cost line | Per free user / mo |
|---|---|
| KMS (envelope, tenant master shared) | ~$0.001 |
| Memory storage (100MB hard cap + 1K vector limit + 30-day inactive auto-archive) | ~$0.05 |
| Broker compute (amortized $50–$100 VM ÷ 1K users at 10 req/day) | ~$0.10 |
| Subsidized LLM (Qwen-class @ $0.001/1K tokens × 5K tokens/day cap) | ~$0.15 |
| Audit anchor (batched to Heima, ~1 anchor/100 events) | ~$0.10 |
| **Total per free user / mo** | **~$0.40** |

At 5% conversion to $10 Basic: 100 free users × $0.40 COGS = $40 burn; 5 convert × $10 = $50 revenue. **Marginal-positive at 5% conv**, comfortably positive at the 8% B2B SaaS median. The four levers that flip the math: envelope encryption (kills KMS floor), hard memory caps (no growth surface), inactive auto-archive (Supabase pattern), subsidized-LLM-only at free tier (no premium model resale on free).

**Q3 — Memory is hard to bill per vendor. Better approach?**

Correct intuition. Memory is user-centric, not vendor-centric — splitting it across vendors creates the same cross-vendor settlement smell as the original draft. **Solution: split the buyer.** Vendor pays only for *device-attributable* events (broker calls per device, cap-mints, audit anchors). Memory storage moves to the **consumer side** — free up to 100MB, included in the $10 Basic upgrade tier, uncapped on Pro. No cross-vendor attribution problem because each vendor's bill shows only their own device events.

**Q4 — "Vendor takes 30% revshare" — multiple vendors per user, who gets the cut?**

**Acquirer-wins-for-life.** The vendor whose checkout the user upgraded through gets 30% for the user's full subscription lifetime. Rationale: (a) simple to compute — single attribution, no settlement; (b) strong incentive for vendors to push their own upgrade flow; (c) app-store precedent (Apple/Google attribute installs to the originating channel); (d) avoids vendor disputes over which device drove conversion.

Edge case: if a user explicitly "migrates billing" through vendor B's app (rare), vendor B becomes the acquirer-of-record going forward. Default = the first conversion sticks. Don't ship time-decaying revshare in v1 — it's a complexity tax with no obvious benefit.

**Q5 — Position against Tuya by being the easy-compatible agent layer that drops in even on Tuya-OS devices.**

This is the right reframe and now goes into the headline positioning (see §9.2). Tuya owns the *device cloud* (OTA, telemetry, BLE provisioning, voice cloud, app SDK). **AgentKeys owns the *agent identity + permission + memory + audit layer above the device cloud.*** They don't overlap — a vendor on Tuya can still drop in AgentKeys for agentic capabilities.

Concrete integration story: AgentKeys ships a Linux sandbox VM (per-actor or per-device, see §17 of arch.md for the actor model) that runs alongside Tuya's voice cloud. The vendor's BLE/OTA/telemetry stays in Tuya; the agent runtime + MCP execution + identity + memory live in AgentKeys. **One sales pitch: "Your Tuya device + AgentKeys = a secure agentic product in one SDK."**

**Q6 — Make a demo proposal updating C1.** → see §9.6.

**Q7 — Use our own subsidized LLM for free users.**

Yes. Use Qwen-Max-Lite or DeepSeek at wholesale (~$0.001/1K tokens, often less for batch pricing) and cap free tier at 5K tokens/day. Cost: ~$0.15/user/mo (line item in Q2 table). Marketing line: "Free tier includes basic LLM allowance — your toy works out of the box, no API key required." Upgrade unlocks 50K tokens/day or bring-your-own-key (OpenAI, Anthropic, Kimi, etc.).

This does technically make AgentKeys an LLM reseller — but only at the free tier, where it's customer-acquisition cost, not a profit center. We are not entering the "$10/mo profit LLM reseller" business the original draft warned against; we are subsidizing onboarding the way Cloudflare Workers AI subsidizes its free tier.

**Q8 — Tencent has `openclaw-weixin-cli`; verify.**

Verified real but operationally suspect. The npm package `@tencent-weixin/openclaw-weixin-cli` exists under Tencent's official GitHub org (MIT, 9 versions Mar–May 2026). **But its mechanism is QR-code personal-WeChat login** — identical to WeChaty/ItChat, which violate WeChat ToS at commercial scale and have a history of account bans in waves. Tencent publishing it under their own org does **not** automatically make personal-account automation ToS-compliant for commercial bots.

Also: the surrounding ecosystem narrative ("346K stars in 60 days, beat React, coordinated ClawPro/ClawBot/QClaw launch") shows fabrication fingerprints in secondary coverage. **Treat the package as ambiguous until verified with a Tencent BD contact**: (a) is QR-code personal-login an officially sanctioned commercial channel, (b) what's the rate/account-ban posture, (c) is there an enterprise-grade SDK path beyond the personal-login CLI. Full feasibility breakdown in §9.5.

**Q9 — Compare Alipay+ AMP vs Stripe ACP.** → see §9.4.

**Q10 — C5 audit framing.** Acknowledged, no change needed.

**Q11 — Make MCP/skill + WeChat memory ingestion feasible.**

Concrete tiered plan (replaces the round-1 "agentkeys-submit-memory skill"):

| Tier | Surface | Audience | Timeline |
|---|---|---|---|
| 1 | **AgentKeys MCP server** — Claude Pro / ChatGPT Plus / Cursor connect once, memory flows automatically | Techie / power user | Immediate, ship-by-Q3-2026 |
| 2 | **Browser extension** for Doubao / Kimi / Tencent Yuanbao web UI — one-time consent, scrapes chat | Mid-market consumer | 3–6 months |
| 3 | **Mobile app SDK** vendor embeds in their companion app — memory ingestion via vendor's app | Mainstream consumer | 6 months |
| 4 | **WeChat Mini Program** via Chinese ISV partnership — chat history + memory sync from WeChat | Chinese mainstream | 6–12 months, partnership-gated |

**Don't ship the explicit skill** at consumer launch — it's fine for power-user dogfood. Tier 1 (MCP server) is the highest-leverage near-term move because Claude/ChatGPT users already have the memory we want and MCP gives us automatic ingestion with no extra install.

**Q12 — Reframe W1 (hardware vendor permission infra) as "agent permission/security + convenience."**

Yes — see new positioning in §9.2. Two value props in one product:

- **Security frame**: "Don't ship a privacy disaster. Bound your AI device's blast radius with cap-tokens and per-actor identity."
- **Convenience frame**: "Become agentic in one SDK. Identity, memory, MCPs, audit — drop in, ship faster."

Vendor self-selects which frame they need (cost-conscious early movers buy convenience; security-conscious post-incident buyers buy security). Both lead to the same SKU.

**Q13 — Lead with cross-vendor portability as the moat.** Reflected in §9.2 headline.

### 9.2 Reframed pitch + product flow

**One-sentence pitch:**

> AgentKeys is the agent permission, security, and identity layer for AI devices — drop in one SDK to make your device agentic, sandboxed, and portable across the user's entire device fleet.

**Three positioning frames (each frame gets its own landing page / pitch deck):**

| Frame | Audience | Hero line |
|---|---|---|
| **Security** | Vendor compliance / CISO / regulator | "Don't let your AI device leak data or get exploited. Bound the blast radius with cap-tokens, per-actor identity, and tamper-evident audit." |
| **Convenience** | Vendor engineering / PM | "Make your device agentic in one SDK. Identity, memory, MCPs, audit. We provide the layer; you build the device." |
| **Portability** (the moat) | End user, ecosystem partner | "Your AI follows you across devices. One root identity, every device knows you. Memory, preferences, credentials — portable across every AgentKeys-enabled vendor." |

**Strategic positioning against incumbents:**

- **vs. Tuya / IoT clouds**: complement, not compete. Tuya owns device cloud (OTA, BLE, telemetry). AgentKeys owns the agent layer above. Pitch: "Your Tuya device + AgentKeys = secure agentic product in one SDK."
- **vs. Privy / Coinbase AgentKit / ScaleKit**: distribution-different. They sell to app devs; we sell to hardware OEMs with cross-device portability.
- **vs. Stripe ACP / Alipay+ AMP**: above the rail, never inside. We orchestrate cap-tokens across devices; the rails settle payments. See §9.4.

**Updated product flow (post-binding onboarding):**

1. **Binding** (unchanged): app + BLE pair, button press for 3 seconds.
2. **Identity issuance** (automatic, HDKD-derived from user master device): zero friction.
3. **Capability toggle screen** (one screen, four toggles):
   - **Payment** — Enable Stripe ACP allowance (global) OR Alipay+ AMP cap (China) with a daily limit
   - **LLM** — Use free subsidized (Qwen-class) / plug user's existing key / auto-subscribe via OpenRouter
   - **Memory preset** — All / Work / Life / Wife / Kids / None
   - **Audit visibility** — Silent / Weekly summary / On-chain anchored
4. **Optional add-ons** (one tap each):
   - Email-as-credential (AgentKeys mints inbox)
   - WeChat sync (via Mini Program, where available)
   - Additional MCPs (calendar, browser, shopping, etc.)
5. **First-conversation greeting** — device pulls memory snapshot, greets user with context-aware first sentence.

The product flow change vs. round-1 draft: capability toggles are now **opt-in security primitives**, not "permission unlocks." Each toggle explicitly bounds what the device can do, with the default being "nothing." A user who toggles nothing has a sandboxed device that talks to them with default memory + subsidized LLM only — safe by default, expansive by choice.

### 9.3 Updated payment structure

Three SKUs, clean attribution, positive unit economics at free tier:

#### SKU 1 — Vendor base (B2B)

- **$1.50/active device/mo flat** (Tuya-equivalent price band, 2× tolerance for the agent layer premium)
- Includes per device: identity issuance, 100MB memory, 30 audit events/day high-level, 300 broker calls/day, 5K subsidized LLM tokens/day
- **No cross-vendor settlement** — each vendor's bill shows only their attributed devices
- Volume tiers:
  - 1–1K devices: flat $1.50/device
  - 1K–10K devices: $1.20/device (20% volume discount)
  - 10K+ devices: direct contract pricing
- Free for vendor to integrate; usage charged after first 100 device-months

#### SKU 2 — Consumer upgrade (B2C, vendor-revshared)

- **$10/mo Basic** — unlimited memory, full audit, premium LLM allowance (50K tokens/day), bring-your-own LLM key, email-as-credential
- **$20/mo Pro** — key rotation, unlimited devices, cross-vendor memory governance UI, regulatory-grade audit export, priority support
- **30% lifetime revshare to acquirer-of-record vendor** (whichever vendor's checkout first converted the user)
- Vendor dashboard shows their attributed upgraders + monthly revshare payout

#### SKU 3 — Usage overage (B2B passthrough)

- Audit anchor events beyond free quota: $0.005/event (~30% margin over actual chain cost)
- KMS ops beyond 100K/device/mo: AWS passthrough + 30%
- Premium LLM resale (vendor-side, for vendors who want to bundle premium models): cost-plus 20%

#### Free tier mechanics (unit-economics positive)

- 1 device max (auto-pause after 30 days inactive — Supabase pattern)
- 100MB memory + 1K vector limit
- Subsidized LLM only (Qwen-class, 5K tokens/day)
- High-level audit (no on-chain anchoring at free tier)
- Marginal COGS: ~$0.40/free user/mo
- Conversion target: 5% to Basic → $50/100 free users revenue vs. $40 COGS → **positive contribution at projected funnel**

#### Tuya-integration tier (special)

For vendors who already integrate with Tuya:
- AgentKeys runs as a Tuya AddOn (their plugin extension model)
- Vendor pays Tuya their normal device-cloud fee + AgentKeys $1.50/device base
- AgentKeys VM sandbox runs alongside Tuya's voice cloud — no architectural conflict
- Co-marketed via Tuya marketplace if partnership signed

#### What changed from round-1 pricing

| Round 1 | Round 2 | Why |
|---|---|---|
| $10/mo "vendor pays per user" | $1.50/device vendor + $10/$20 consumer revshare | Vendor WTP is $0.50–$3/device, not $10/mo. Splits B2B/B2C buyer cleanly. |
| Vendor pays for cross-vendor user storage | Memory moves to consumer side; vendor pays only per-device events | Sidesteps cross-vendor settlement smell |
| Free tier with negative unit econ | Free tier with $0.40 marginal COGS via envelope encryption + caps + subsidized-LLM-only | Math now works at 5% conversion |
| Free email-based LLM auto-subscription | OpenRouter-only at upgrade tier OR bring-your-own-key | "Mint Kimi subscription from email" was fragile (KYC); OpenRouter is the only clean path |

### 9.4 Alipay+ AMP vs Stripe ACP — sequenced integration

**Both, sequenced. Architectural pattern: rail adapter layer that emits AgentKeys cap-tokens into ACP `Allowance`s OR AMP one-time-credentials OR x402 USDC payments.**

#### Technical comparison

| Dimension | Stripe ACP | Alipay+ AMP |
|---|---|---|
| Launch | Sept 2025 (OpenAI + Stripe), Apache 2.0 | April 27, 2026 (Ant International), open-sourced |
| Spec home | [github.com/agentic-commerce-protocol](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol) | [alipayplus.com/agentic-mobile-protocol](https://www.alipayplus.com/agentic-mobile-protocol/) |
| Cap envelope | `Allowance{reason, max_amount, currency, checkout_session_id, merchant_id, expires_at}` (SPT reference impl) | One-time credential from network token + device passkey; KYA cert binds agent identity |
| Cap enforced at | PSP (Stripe) on capture | Wallet (Alipay) on payment authorization |
| Identity model | Delegate-auth subject (OAuth-flavored) | KYA (Know-Your-Agent) — explicit agent identity + Trust Rating |
| Distribution | OpenAI ChatGPT (~800M weekly), Stripe merchants (millions), Etsy live + Shopify rolling | 1.8B Alipay+ accounts, 100M Alipay AI Pay users, 120M txs/week (Feb 2026), 150M merchants in 220+ markets |
| Open SDK | Yes, public sandbox, days to integrate | Press-launched "open" but public SDK lagging; Antom ISV contract required for production access |
| KYC for wrapper | Stripe Connect (47 countries, US LLC or international) | Antom ISV (Singapore-based, no China license needed for cross-border Alipay+) |
| Cross-border | US/global; not in China mainland | Cross-border native; mainland China requires extra registration |
| Crypto rail | Stripe x402 + USDC on Base (Feb 2026) — same SPT envelope wraps stablecoin | No public stablecoin/x402 integration |
| Wrapper-friendly? | Yes — composable spec, obvious wrapper gap | Mixed — Ant wants to *be* the identity layer; wrapper must stay strictly above the wallet |

#### Sequenced recommendation

| Phase | Quarter | Action |
|---|---|---|
| 1 | Q3 2026 | **Stripe ACP integration** — open SDK, no contractual gate, Stripe sandbox in days. Covers global non-China vendors. Add x402 USDC parallel for crypto-native vendors. |
| 2 | Q3 2026 (parallel) | **Begin Antom ISV onboarding** — multi-month process, start now. |
| 3 | Q4 2026 | **Alipay+ AMP integration** — emit AgentKeys-issued KYA-equivalent certs into Alipay AI Pay for China-market customers. |
| 4 | 2027 H1 | **Mature rail adapter** — same internal cap-token routes per-merchant via cheapest/fastest rail (ACP, AMP, x402) without vendor code changes. |

#### Strategic positioning rule

> **AgentKeys is the device-fleet identity-and-cap layer above the rails, never a payment processor.** Both ACP and AMP welcome a layer that issues KYA-equivalent credentials + cap tokens; both push back on a layer that custodies funds. Stay above the rail.

#### Why AgentKeys' model maps better to AMP (but ACP ships first)

AMP's KYA framework = AgentKeys' per-actor HDKD identity (the wallet-level "I am this specific agent" attestation). ACP's delegate-auth is more loosely structured — it leaves agent identity to the OAuth/JWT layer above.

So while AMP is the more *natural* long-term fit for AgentKeys' architecture, **ACP is the right Q3-2026 first integration** because:
1. Open-source spec + public sandbox = days to integrate
2. No contractual gate (vs. Antom ISV multi-month onboarding)
3. Global coverage where AMP doesn't reach (US, EU, non-China APAC)
4. x402 USDC crypto path lands in the same integration

AMP comes in Q4 once the Antom contract clears, and the rail adapter handles routing.

### 9.5 WeChat integration — what's actually feasible

**Honest answer from research:**

`@tencent-weixin/openclaw-weixin-cli` on npm is real (MIT, Tencent org, 9 versions). But its mechanism — QR-code personal-WeChat login — is operationally identical to WeChaty/ItChat, which historically violate WeChat ToS for commercial automation and get accounts banned in waves. Tencent publishing it under their own GitHub org does NOT automatically make this ToS-compliant for commercial bots. Verify with Tencent BD before betting product on it.

**What every surviving Chinese AI companion toy actually does today:**

- **Standalone iOS/Android companion app** = the primary chat surface + history (FoloToy, BubblePal, Ropet all do this)
- WeChat Service Account = marketing/notifications only (not real-time bidirectional chat — 5s sync window + templated messages only)
- WeChat Mini Program with WebSocket = real-time chat possible, but requires ICP-filed entity OR partnership with Chinese ISV (~$10–30K/year licensing)
- WeCom (企业微信) = works overseas-friendly but UX is "add company contact" (B2E flavor), reach limited

**Recommended path for AgentKeys × hardware vendors:**

| Phase | Surface | What it gives | Cost |
|---|---|---|---|
| 1 (immediate) | Vendor companion app with AgentKeys SDK | Primary chat + memory + identity surface | Vendor's existing app dev cost |
| 2 (3–6 mo) | AgentKeys MCP server for Claude Pro / ChatGPT Plus / Cursor | Memory ingestion from existing AI tools, no install required | AgentKeys infra |
| 3 (6–12 mo) | WeChat Mini Program via Chinese ISV partnership | WeChat-native chat for China-mainstream users | $10–30K/yr licensing + ISV ops |
| 4 (contingent) | `openclaw-weixin` validated path | Direct WeChat user-account integration IF Tencent BD confirms commercial ToS-compliance | Unknown until verified |

**Hard rule**: don't bet the product on `openclaw-weixin` for v1. It's a high-upside, high-risk bonus channel — explore in parallel with the safe path.

### 9.6 Security-first demo storyboard (updates C1)

**Target audience**: hardware vendor BD + product / regulatory affairs / press demo. Total demo time: ~4 minutes. Every act shows a security property visible on Heima explorer or AgentKeys app.

**Act 1 — Cross-vendor portability (the moat)**

- User shows FoloToy plushie. Plushie greets: *"Hey Kevin, ready for your trip to Chengdu? Customs forms still on your mind?"* — reflects memory uploaded from desktop ChatGPT/Claude via AgentKeys MCP server.
- User puts plushie down. Picks up a (mock) Ropet companion. Ropet greets: *"Customs clearance going OK?"* — reads the *same* memory namespace with explicit read-only consent shown in app.
- Audience sees: **one identity, two vendors, user-controlled scope**.

**Act 2 — Spend-cap rejection on Heima explorer (the math-bounded blast radius)**

- User: *"Order me dinner from Meituan, something spicy."*
- Toy orders ¥420 Sichuan hotpot. Goes through. Receipt audit row visible on Heima explorer (anchored hash, expandable to event detail).
- User: *"Make it bigger — order the ¥600 lobster combo."*
- Toy: *"Daily cap is ¥500 — rejecting. Order not placed."* Audit row appears on Heima explorer: `cap_burn_rejection: actor=folotoy_kevin_001, requested=600, limit=500, reason=daily_limit_exceeded`.
- Audience sees: **enforced by math, observable on-chain, no after-the-fact recovery needed**.

**Act 3 — Real-time revocation (the kill switch)**

- User opens AgentKeys app, taps *"Revoke FoloToy payment access"*.
- Toy: *"I can no longer access payment — please rebind via the app."* Audit row: `permission_revoked: scope=payment, actor=folotoy_kevin_001`.
- User taps *"Set FoloToy to memory read-only"*.
- User: *"Hey toy, remember I want sushi tomorrow."* Toy: *"I can read your memory but can't write — share it via the app and I'll see it."*
- Audience sees: **instant policy enforcement, no device restart, observable from app**.

**Closing — subsidized LLM with token meter (the on-ramp)**

- User: *"What's the weather?"* Toy answers using AgentKeys free-tier Qwen LLM.
- App shows: 4,127 / 5,000 daily free tokens used. Tap *"Upgrade to Pro"* → 50K tokens/day, plug your own GPT-4 key, unlock cross-vendor memory governance UI.
- Audience sees: **free out of the box, upgrade unlocks the full stack**.

**Drop from the demo**: any pure-capability scene ("buy Sichuan food", "book a flight") *unless* it's also showing a cap-token getting decremented or a policy enforcement moment. The demo's job is to show the security model winning, not to show the toy is smart — every audience already assumes the toy is smart.

### 9.7 Updated next moves (replaces §7)

1. **Update website + pitch deck** with the three-frame positioning (security / convenience / portability) and the new "AgentKeys above the rails (ACP + AMP + x402)" diagram.
2. **Write a 1-page "AgentKeys for Tuya OEMs" integration brief** — explicitly complement, not compete; co-marketing-ready language.
3. **Update payment structure** to per-device base ($1.50) + consumer revshare ($10/$20 with 30% lifetime acquirer revshare) across pricing page and sales docs.
4. **Q3 2026 — implement Stripe ACP integration** as the first rail adapter. Reference SPT flow. Add x402 USDC parallel track.
5. **Q3 2026 (parallel) — begin Antom ISV onboarding** for Alipay+ AMP integration in Q4.
6. **Build AgentKeys MCP server (highest leverage)** — Claude Pro / ChatGPT Plus / Cursor users connect once, memory flows automatically. Ship by Q3.
7. **Outreach to FoloToy, Ropet, BubblePal** with the security + portability + convenience pitch and the new pricing structure.
8. **Validate `openclaw-weixin` with Tencent BD** in parallel; if green-lit, that's bonus distribution; if not, stick with standalone-app + Mini-Program-via-ISV.
9. **Build the security demo end-to-end on Heima testnet** for trade-show readiness — every act must be live-runnable, not slides.
10. **Kill criterion (unchanged)**: 0 paid pilots from 3 priority vendors in 6 months → pivot to consumer agent-app MCP credential broker.

### 9.8 Round-2 sources

WeChat integration:
- [npm @tencent-weixin/openclaw-weixin-cli](https://www.npmjs.com/package/@tencent-weixin/openclaw-weixin-cli)
- [GitHub Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin)
- [Tencent Cloud OpenClaw](https://www.tencentcloud.com/act/pro/intl-openclaw)
- [ICP License for WeChat Mini Programs](https://msadvisory.com/icp-license-wechat-mini-programs/)
- [WeChat Mini Programs for Foreign Brands](https://www.chinaentrypro.com/wechat-mini-programs-for-foreign-brands-in-china)
- [WeChat bans automated content](https://www.yicaiglobal.com/news/wechat-bans-automated-content-publishing-due-to-rise-in-replacement-of-human-creators)

Agent payment protocols:
- [Ant International AMP launch (BusinessWire 2026-04-27)](https://www.businesswire.com/news/home/20260427209524/en/Ant-International-Launches-Open-Sourced-Agentic-Mobile-Protocol-to-Drive-AI-Commerce)
- [Alipay+ AMP product page](https://www.alipayplus.com/agentic-mobile-protocol/)
- [Alipay AI Pay 120M txs/week (BusinessWire 2026-02-13)](https://www.businesswire.com/news/home/20260213770962/en/)
- [ACP GitHub spec](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol)
- [Stripe ACP docs](https://docs.stripe.com/agentic-commerce/acp)
- [OpenAI Delegated Payment Spec](https://developers.openai.com/commerce/specs/payment)
- [Crossmint — Agentic Payment Protocols Compared](https://www.crossmint.com/learn/agentic-payments-protocols-compared)
- [Coinbase x402 docs](https://docs.cdp.coinbase.com/x402/welcome)
- [Antom Global Partner Developer Center](https://docs.antom.com/ac/agpdc/devcenter)

## 10. Sources (round 1)

Competitive landscape:

- [Friend $99 necklace](https://techcrunch.com/2024/07/30/friend-is-an-ai-companion-backed-by-founders-of-solana-perplexity-and-zfellows/)
- [Rabbit R1 next-gen 2026](https://www.tomsguide.com/ai/rabbits-next-gen-ai-hardware-is-coming-next-year-to-take-on-openai-and-the-ceo-just-teased-what-to-expect)
- [AI gadget flops 2025](https://www.everydayaitech.com/en/articles/ai-gadgets-flop-2025)
- [China's $3.5B AI toy market](https://hellochinatech.com/p/china-ai-toys-35-billion-industry)
- [FoloToy / ByteDance Eye-Catching Bag](https://www.sino-carib.com/post/ai-powered-toys-entering-chinese-children-s-playrooms)
- [MOMOTOY / Ropet retention](https://eu.36kr.com/en/p/3769249595835142)
- [AI toy safety risks](https://cybernews.com/ai-news/chinas-ai-toy-boom-puts-generative-ai-in-kids-hands-exposing-new-risks/)
- [BubblePal Amazon](https://www.amazon.com/BubblePal-Interactive-Companion-Learning-Companionship/dp/B0DMPB3B88)
- [Ropet at CES 2025](https://www.engadget.com/home/ropet-is-the-cute-as-hell-emotional-robot-at-ces-2025-that-the-modern-furby-wishes-it-could-be-214046211.html)
- [Privy pricing](https://www.privy.io/pricing)
- [Privy AI Wallets](https://www.privy.io/ai)
- [Agent wallets compared (Crossmint)](https://www.crossmint.com/learn/agent-wallets-compared)
- [Mem0 / Zep / Letta benchmarks](https://mem0.ai/blog/state-of-ai-agent-memory-2026)
- [ScaleKit pricing](https://www.scalekit.com/pricing)
- [AgentMail pricing](https://www.agentmail.to/pricing)
- [Clerk vs Stytch](https://www.malekhammoud.com/software/clerk-vs-stytch)
- [Coinbase AgentKit](https://github.com/coinbase/agentkit)
- [Coinbase Agentic Wallets](https://www.coinbase.com/developer-platform/discover/launches/agentic-wallets)
- [Stripe Agentic Commerce Suite](https://stripe.com/blog/agentic-commerce-suite)
- [Permit.io for AI agents](https://www.permit.io/blog/why-ai-agents-choose-permitio-for-authorization)
- [E2B 15M sessions](https://www.vietanh.dev/blog/2026-02-02-agent-sandboxes)
- [Alipay AI Pay launch](https://www.businesswire.com/news/home/20260421171651/en/Alipay-AI-Pay-Launches-New-Service-Enabling-OpenClaw-type-AI-Agents-to-Make-Payments)
- [Alipay+ Agentic Mobile Protocol](https://www.alipayplus.com/agentic-mobile-protocol/)
- [Tencent ClawPro](https://thenextweb.com/news/tencent-clawpro-openclaw-enterprise-ai-agents)
- [Skyfire + Catena](https://www.chaincatcher.com/en/article/2262929)
- [Limitless acquired by Meta](https://techcrunch.com/2025/12/05/meta-acquires-ai-device-startup-limitless/)
- [Limitless pricing](https://www.limitless.ai/)

Pricing + business model:

- [Auth0 Pricing](https://auth0.com/pricing) / [Auth0 Pricing Guide 2026](https://www.saasworthy.com/blog/auth0-pricing-plans-guide)
- [Clerk vs Auth0 2026](https://leonstaff.com/blogs/clerk-vs-auth0-identity-crisis/)
- [Twilio Messaging Pricing](https://www.twilio.com/en-us/pricing/messaging)
- [Zep vs Mem0 Benchmarks & Pricing](https://atlan.com/know/zep-vs-mem0/)
- [Mem0 Pricing Review 2026](https://theaiagentindex.com/agents/mem0)
- [Pinecone Pricing 2026](https://pecollective.com/tools/pinecone-pricing/)
- [Vector DB Costs 2026](https://leanopstech.com/blog/vector-database-cost-comparison-2026/)
- [Secrets Management Pricing 2026](https://www.cybersectool.com/blog/secrets-management-pricing-breakdown-2026)
- [Top 5 Secrets Management Tools](https://guptadeepak.com/tools/top-5-secrets-management-tools/)
- [AWS KMS Pricing](https://aws.amazon.com/kms/pricing/)
- [Datadog Pricing 2026](https://middleware.io/blog/datadog-pricing/)
- [Drata Pricing](https://soc2auditors.org/insights/drata-pricing/)
- [Moonbeam Transaction Fees](https://docs.moonbeam.network/learn/core-concepts/tx-fees/)
- [AWS IoT Core Pricing](https://aws.amazon.com/iot-core/pricing/)
- [Tuya Developer Platform](https://developer.tuya.com/en/docs/iot/membership-service?id=K9m8k45jwvg9j)
- [Supabase Pricing 2026](https://uibakery.io/blog/supabase-pricing)
- [E2B Pricing](https://e2b.dev/pricing)
- [AI Sandbox Pricing Comparison 2026](https://northflank.com/blog/ai-sandbox-pricing)
- [Vercel Pricing](https://vercel.com/pricing)
