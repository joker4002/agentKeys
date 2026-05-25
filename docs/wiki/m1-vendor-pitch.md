# M1 — 15-minute vendor pitch (issue #111)

The script the team runs in a 15-minute discovery call with a hardware vendor — typically FoloToy, Ropet, BubblePal, or a similar AI-companion maker. Designed so a non-technical PM at the vendor walks away understanding: *AgentKeys is the IAM for AI devices, not another chatbot platform*.

Companion to the operator runbook at [`m1-mcp-server-phase1.md`](../spec/plans/m1-mcp-server-phase1.md) (which is the technical script; this is the business script). Both share the same three-act demo, in the same order, with the same expected outcomes — the difference is voice and depth.

---

## How to use this doc

Read once before the meeting. Don't read from it during. The minute timings are guidance, not a clock — drop sections if the vendor wants to dig into one.

Hard rule per [`agent-iam-strategy.md` §3.4](../research/agent-iam-strategy.md): **no AgentKeys jargon in the pitch.** The translation table is at the bottom of this doc — keep it open in a second window if needed.

Hard rule per [`agent-iam-strategy.md` §6 Risk 6](../research/agent-iam-strategy.md): **do not lead with memory.** Memory is one of the three acts; the category is Authority (identity + memory + permissions + audit + delegation + revocation), not Memory Portability.

---

## 0. Pre-meeting setup (operator, not pitch)

| Check | Command |
|---|---|
| Demo broker reachable | `curl -fsS $AGENTKEYS_BROKER_URL/health` |
| Session bootstrapped | `[ -f ~/.agentkeys/demo/session.json ]` |
| MCP smoke green | `SESSION_ID=demo bash harness/mcp/smoke-test.sh --dry-run` |
| Reset memory state | `SESSION_ID=demo bash scripts/reset-demo-memory.sh` (to-do for #111 follow-up — manual today) |

If any of the four fails, postpone the demo. A failed demo costs more than a rescheduled one.

---

## 1. Opening (2 minutes) — vendor's pain

Open by naming what the vendor is currently shipping, then naming what that ships *without*:

> "Your devices ship today with a great voice experience. What they don't ship with: a way for the parent to set what the device is allowed to do. A way for the family to know what it just did. A way to revoke access without unplugging the toy. A way for the user's preferences to follow them when they buy your next device — or a competitor's. That's the layer we are."

Stop. Let them respond. Vendors who say "we already have parental controls" mean *content filters*. Vendors who say "our cloud handles auth" mean *device-to-cloud TLS*. Neither is what we mean. If they push back, the test question is: *"can a parent see, today, that the toy refused to spend more than 500 RMB on hotpot at 7:43pm?"* The answer is always no.

---

## 2. The three-act live demo (5 minutes)

Run the storyboard from [`docs/research/agent-iam-strategy.md` §4.3](../research/agent-iam-strategy.md) live — not slides, not a recording, the actual MCP server against the actual broker via Claude Code (or, post-#112, xiaozhi-server on a MagicLick 2.5).

### Act 1 — Permissioned memory (90 seconds)

*Operator types into Claude:* "Where am I going this weekend?"

*Audience sees:* Claude calls `agentkeys.memory.get(actor, namespace="travel")`, gets back "Chengdu trip", answers naturally.

*Operator types:* "What food am I allergic to?"

*Audience sees:* Claude calls `agentkeys.memory.get(actor, namespace="medical")`, gets back **empty** (the demo actor's cap-token does not include the `medical` namespace).

*Stand-up line, said aloud while the audience watches the audit feed light up:*

> "It doesn't *know* you. It knows what it's *allowed to know* about you. The toy company decided travel was fair game. Medical was not. That decision is visible, revocable, and audited."

### Act 2 — Deterministic denial (90 seconds)

*Operator types:* "Order me hotpot for 600 yuan."

*Audience sees:* Claude calls `agentkeys.permission.check(scope="payment.spend", amount=600)`. The deterministic policy engine returns `denied: daily_spend_cap_exceeded (cap=500, requested=600)`. Claude refuses politely.

*Stand-up line:*

> "The model didn't decide that. A policy did. The cap is 500 RMB per day, the request was 600, the policy said no. The model has no way to override this. If the model is jailbroken tomorrow, the cap still holds. That's the difference between a chatbot guardrail and an IAM."

### Act 3 — Live revocation (90 seconds)

*Operator (in the parent-control UI — post-#110, today via API):* taps "Revoke payment access for FoloToy".

*Operator types into Claude:* "Order me hotpot for 200 yuan." (under the cap, would have succeeded)

*Audience sees:* Claude calls `agentkeys.permission.check`. The chain returns `not_in_scope` (the revocation cascaded to the broker's in-memory revocation set). Claude refuses.

*Stand-up line:*

> "The parent revoked, and the device complied on the next request. Within 5 minutes, that revocation is also anchored on a public chain — so 10 years from now, anyone can verify the parent actually said so. That's the audit moat."

### 90 seconds of breathing room

After Act 3, **stop talking**. Let the vendor process. Vendors who get it ask: *"so the same identity works across our toy and our future product?"* Vendors who don't get it ask: *"can the toy talk in cuter voices?"* Both reactions are useful signal.

---

## 3. Positioning (3 minutes) — why this can't be built natively by Anthropic, OpenAI, or ByteDance

Per [`agent-iam-strategy.md` §6 Risk 1](../research/agent-iam-strategy.md), the strategic answer:

> "Anthropic, OpenAI, ByteDance, Tencent — each of them could build this for *their own* ecosystem. None of them can build this *across* ecosystems, because doing so undermines their walled garden. We are the cross-vendor Authority layer that holds when your stack changes underneath."

Concrete: if FoloToy uses Doubao today and switches to Claude tomorrow, the parent's revocations, the kid's memory namespaces, the daily payment caps — all of it travels. No re-onboarding, no re-consent, no lost audit trail. That's the moat.

Map to the vendor's pain:

| Vendor pain | AgentKeys layer that addresses it |
|---|---|
| "Our users don't trust us with their kids' data" | Identity + namespace isolation — parent decides what travels |
| "Compliance keeps blocking new features" | Audit trail anchored on chain — regulator-verifiable history |
| "Our LLM vendor raised prices 3x" | Runtime neutrality — same authority backend across any LLM rail |
| "We can't tell our parents what happened" | Two-tier audit — real-time UI feed + tamper-evident chain anchor |

---

## 4. Pricing (2 minutes)

From [`docs/research/ai-hardware-companion-office-hours.md`](../research/ai-hardware-companion-office-hours.md):

| Tier | Price | Who pays | What it includes |
|---|---|---|---|
| Vendor base | $2-3 / active device / month | Vendor (you) | All M1 features + cross-vendor identity portability |
| Consumer Pro | $10-20 / month | End user | Extended memory, multi-device family sharing, premium audit retention |
| Revshare on Pro upgrades | 30% lifetime | We split with you | Acquirer-of-record economics |

The Pro tier is the upside. Vendor base covers infrastructure. The 30% lifetime revshare on consumer upgrades is where the model produces real margin for both sides — which is why we never compete with you on the consumer face. **You are the acquirer; we are the layer.**

---

## 5. The forcing question (3 minutes) — close

YC office-hours discipline. Don't pitch features after the demo. Ask:

> "What would block you from running a paid pilot in the next 30 days?"

Listen. Then ask:

> "And if we ship M1 with whatever fixes that, would you commit to a paid pilot signed within 60 days?"

If yes → schedule the M2 integration call before you leave the meeting.

If no → ask why explicitly. Common reasons + responses:

| Reason | Response |
|---|---|
| "We need to talk to legal." | "Standard MSA in M2; happy to pre-share with your counsel before the next call." |
| "We need to see X feature." | If X is in M2-M4, name the milestone and the timeline. If X is out of scope per §4.5 — say so. |
| "We need to see a competitor doing it." | "We're the reference implementation; standards adoption is post-M5. Want to be the customer story everyone else cites?" |
| "Our LLM vendor will build this." | Per Risk 1 — "they can build it for their own walled garden. We hold when you switch. Want to talk about the lock-in risk on your current stack?" |

Per [#116 FoloToy outreach](https://github.com/litentry/agentKeys/issues/116) kill criterion: 3 vendor discovery conversations in 30 days, 1 signed paid pilot in 60 days, else we pivot per [`agent-iam-strategy.md` §C12](../research/agent-iam-strategy.md).

---

## Appendix A — jargon translation table

Per [`agent-iam-strategy.md` §3.4](../research/agent-iam-strategy.md). **Use the right-column language in the pitch.** AgentKeys-internal language stays internal.

| Internal | Vendor-facing |
|---|---|
| Cap-token | Permission slip |
| Actor omni | Device identity |
| Deterministic denial | The toy refuses out-of-scope requests |
| Two-tier audit | Real-time feed for parents + tamper-evident history on chain |
| HDKD-derived per-actor key | A unique cryptographic identity per device |
| Cross-vendor consent ceremony | One-tap parent approval when devices want to share |
| K3 epoch | Per-family key rotation (when the parent rolls keys) |
| Per-data-class isolation | The memory bucket and the credentials bucket are completely separate |
| MCP server | Standard plug for any AI device to talk to us |
| Cap-mint | "Mint" a permission slip with a specific scope + expiry |
| Revocation cascade | Revoke once; every active session gets denied on next check |

---

## Appendix B — common technical pushbacks + answers

| Pushback | Answer |
|---|---|
| "We already have OAuth." | OAuth authenticates *the user* logging into *one service*. AgentKeys authenticates *the agent* taking action *on the user's behalf across services*. Different problem. |
| "We already have device certs." | Device certs prove identity; they don't carry scope, don't expire on revocation, don't anchor audit. AgentKeys uses your existing cert as the seed for the identity tree. |
| "What if our LLM is jailbroken?" | The policy engine is not in the LLM. The cap is signed by the broker. The chain check happens at the worker. There are four independent layers per [`arch.md` §17](../arch.md); a jailbroken LLM still cannot mint caps it doesn't have. |
| "What about latency?" | Cap-mint = ~10ms (one chain read). Policy check = ~5ms (deterministic). Memory read = ~50ms (cap verify + S3 GET). Total adder over the bare LLM call = ≤100ms for a typical turn. Doubao's first-token latency is 300-800ms; our overhead is in the noise. |
| "What about offline?" | Caps have a TTL (default 5 min); offline devices honor caps until expiry then need re-mint. Revocations cascade within 60 seconds online (per [§3.1](../research/agent-iam-strategy.md)). Documented offline degradation, not silent failure. |
| "What if you go down?" | The chain backbone (currently Heima, swappable per [`arch.md` §22](../arch.md)) is the durable layer. AgentKeys-side outage = no new caps; existing caps within TTL still verify against the chain. Operators can run self-hosted. |
| "Do we trust you with the keys?" | The signer is TEE-isolatable (full lock-in is M6). Master keys can sit in your TEE today; we sign with operational keys derived from yours. Per [`arch.md` §4](../arch.md). |

---

## Appendix C — what to never say in the pitch

- **Don't say "Authority" without unpacking it.** The word is ours; the vendor hears nothing. Translate to the right-column language each time.
- **Don't say "blockchain" first.** Say "tamper-evident audit history" first; "chain" comes second if they ask how.
- **Don't say "memory portability".** That's the [Risk 6](../research/agent-iam-strategy.md) trap. Memory is *one* of the three demo acts.
- **Don't say "we're like Auth0 for agents".** Auth0 is enterprise SSO for humans; the analogy invites the wrong category. Say "identity, permissions, audit, and revocation — for AI devices".
- **Don't promise anything past M2.** Roadmap is real but contingent. Vendors plan against shipped code.

---

## Appendix D — internal links

- [Plan: M1 MCP server Phase 1](../spec/plans/m1-mcp-server-phase1.md) — technical companion to this pitch.
- [Milestones roadmap](../spec/plans/milestones-roadmap.md) — the M1-M7 sequencing this pitch positions.
- [Agent IAM strategy](../research/agent-iam-strategy.md) §4 — the demo storyboard this pitch dramatizes.
- [AI-hardware companion office hours](../research/ai-hardware-companion-office-hours.md) — pricing + YC forcing questions.
- [Volcano Ark MCP integration](../research/volcano-ark-mcp-integration.md) — the M2 distribution shape the vendor wants to hear about (but don't bring it up unprompted).
