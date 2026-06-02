# Memory: build vs. gate — decision record

**Status:** DECIDED — **Position C (gated store, pluggable engine)**. 2026-05.
**Question owner:** Hanwen. **Supersedes the framing of** [`../plan/agentkeys-memory-design.md`](../plan/agentkeys-memory-design.md) (which reads as "build a memory system"); reconciles it with [`agent-iam-strategy.md`](./agent-iam-strategy.md) and [`../plan/milestones-roadmap.md`](../plan/milestones-roadmap.md) M1.

---

## The question

> "Every agent will have its own memory system — it's quite similar to a skill or a tool call. Can we abstract memory like a tool call and use AgentKeys to *gate* it, rather than building our own memory system — since memory is not our core value, there are many solutions, and even Claude has one (closed-source)?"

The instinct is correct and is already half-written into the repo. [`agent-iam-strategy.md` §1.2](./agent-iam-strategy.md) line 46:

> *"'Memory MCP server' is too narrow (Mem0 / Zep / Letta eat it). 'Agent IAM' is the right size."*

But "gate it, don't build it" hides a three-way distinction that decides whether the idea works. Collapsing memory into one thing ("a memory system") is what makes the question feel binary. It isn't.

## TL;DR decision

**Memory is three layers, not one. AgentKeys owns two and delegates one.**

| Layer | What it is | Commodity? | AgentKeys' role |
|---|---|---|---|
| **Engine** | extraction, embedding, ranking, consolidation, decay (BM25 / vector / graph) | **Yes** — mem0/Zep/Letta/agentmemory/Claude all do this | **Delegate.** Don't build. Pluggable. |
| **Store** | where the encrypted bytes physically live; who holds the keys; per-actor isolation | **No** — this is the arch.md moat | **Own.** K3-encrypted, per-actor S3, namespaced. |
| **Gate** | who can read/write which memory, when, with what scope, audited | **No** — this IS Agent IAM | **Own.** Cap-token + scope + audit. |

So: **yes, abstract memory as a gated tool call** (`agentkeys.memory.get` / `agentkeys.memory.put` — already in M1). **No, don't delegate the store to mem0-cloud or Claude.** Delegate the *engine*. The tool call AgentKeys exposes is gated AND its bytes are in AgentKeys' encrypted vault — the ranking algorithm behind it is the ecosystem's, not ours.

The reason "pure gate, use their store" (Position B) is wrong is not aesthetic — it **breaks the founding privacy requirement** from the first conversation. See §2.

---

## 1. The three-layer distinction

The user's analogy — "memory is like a skill or a tool call" — is exactly right, and it's the unlock. A tool call has two separable parts:

1. **The implementation** (what the tool does internally) — for memory, that's the *engine*: how it decides what to remember and what to recall.
2. **The authority + the data** (may this caller invoke it, on whose data, recorded where) — for memory, that's the *gate* + the *store*.

AgentKeys is an **authority host**, not a task host ([`agent-iam-strategy.md` §2.1](./agent-iam-strategy.md)). Authority hosts own #2 and stay out of #1. Applied to memory:

```
                 ┌───────────────────────────────────────────────┐
                 │  ENGINE  (pluggable, ecosystem, NOT our build) │
                 │  mem0 / agentmemory / Hermes-native / Claude   │
                 │  → decides what to extract, how to rank/recall │
                 └───────────────────────┬───────────────────────┘
                                         │ reads/writes through
                          ┌──────────────▼───────────────┐
   AgentKeys owns ───────►│  GATE  (cap-token + scope +   │
   this whole box         │         namespace + audit)    │
                          ├───────────────────────────────┤
                          │  STORE (K3-encrypted, per-     │
                          │  actor S3, namespaced bytes)   │
                          └───────────────────────────────┘
```

The engine is **per-agent and disposable**. The store + gate are **per-user and durable**. That asymmetry is the whole argument — see §4.

---

## 2. Three positions, and the test that decides

| | **A — Build the engine** | **B — Pure gate** | **C — Gated store, pluggable engine** |
|---|---|---|---|
| Engine | AgentKeys builds BM25/vector/consolidation | ecosystem's | ecosystem's (pluggable) |
| Store | AgentKeys S3 | **mem0-cloud / Claude / Hermes host** | **AgentKeys S3 (K3-encrypted)** |
| Gate | cap-token | cap-token (advisory only) | cap-token (enforcing) |
| Memory eng cost | High (the objection) | Zero | Low (store only) |
| Competes with mem0/Zep? | **Yes (bad)** | No | No |

**The decisive test is the founding requirement** (this thread's first message):

> *"Store memory in S3 … portable, extractable, store efficiently. Memory is injected on the way, not as whole context to the LLM. LLM does not have the whole visibility of my memory. I can easily rotate the LLM layer, make it pluggable."*

Run each position against the five sub-requirements:

| Founding requirement | A | B | C |
|---|---|---|---|
| Bytes in our S3 | ✅ | ❌ (their store) | ✅ |
| Portable + extractable by us | ✅ | ⚠️ (vendor export format) | ✅ |
| Injected on the way (top-K, JIT) | ✅ | depends on engine | ✅ |
| LLM never sees whole memory | ✅ | ❌ (mem0-cloud sees plaintext; Claude couples memory to the LLM) | ✅ |
| LLM pluggable / rotatable | ✅ | ❌ (Claude memory ⇒ locked to Claude) | ✅ |

**Position B fails three of five.** That's not a close call. "Use Claude's closed memory" specifically inverts the founding goal: Claude's memory engine is operated by the LLM vendor, so memory becomes coupled to the LLM you wanted to keep swappable.

**Position A passes the privacy test but loses on strategy** — it builds the commodity engine, the exact thing the user (and `agent-iam-strategy.md` line 46) says we should let the ecosystem eat.

**Position C passes all five AND avoids competing on the engine.** Decision: **C.**

---

## 3. How the ecosystem actually splits engine vs. store (verified)

The good news: the best memory products **already separate engine from store**, which is why Position C composes cleanly with all of them.

### Claude memory tool — the strongest precedent for C
Anthropic's memory tool is **client-side**: the model emits `view`/`create`/`str_replace` calls against a `/memories` directory, and *you* execute them wherever you want. From the docs: *"you can subclass `BetaAbstractMemoryTool` … to implement your own memory backend (file-based, database, cloud storage, **encrypted files**)"*; *"your application receives tool calls and executes file operations wherever you want — local disk, PostgreSQL, **S3, encrypted storage**."* ([Claude memory tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool))

So the engine (what to remember — Claude's closed logic) is split from the store (yours). **AgentKeys can literally be a Claude memory backend**: subclass `BetaAbstractMemoryTool`, route the file ops to the cap-gated, K3-encrypted memory worker. Anthropic itself validates Position C. The user's "Claude's is closed-source" is true of the *engine* and irrelevant to the *store* — the store is explicitly ours to own.

### mem0 — cloud breaks the requirement, self-host bundles its own store
- **mem0 cloud:** memories on mem0's servers; SOC2/HIPAA, but plaintext crosses to a third party. Breaks "LLM/vendor never has whole visibility." ([mem0 platform vs OSS](https://docs.mem0.ai/platform/platform-vs-oss))
- **mem0 self-hosted:** data stays on your infra, but mem0 brings its **own** vector DB (Qdrant/pgvector/Neo4j) — the exact heavyweight substrate [`memory-design.md` §5.5.2](../plan/agentkeys-memory-design.md) rejected. Usable as a *front-end engine* whose final bytes land in AgentKeys' store, but not a drop-in store.

### Hermes — provider = engine+store bundled (per-agent)
Hermes' `MemoryProvider` plugins (mem0, honcho, supermemory, agentmemory…) each bundle engine + store; one active at a time, Python-only, Hermes-only ([`hermes-v0.15` research](./xiaozhi-hermes-architecture.md) and the memory-provider plugin spec). This confirms the user's premise — **every agent ships its own memory system** — and is precisely why the durable layer (§4) must live *outside* any one agent.

### agentmemory — engine wrapper, no isolation model
Hybrid BM25+vector+graph engine over a local KV store; single-tenant, no per-actor crypto isolation, no cap-tokens ([`agentmemory-and-claw-code-followup.md`](./agentmemory-and-claw-code-followup.md)). A candidate *engine*, never the store/gate.

---

## 4. Why own the store: engine is disposable, memory is durable

The clinching argument for C over B:

- **The engine is per-agent and disposable.** Today Hermes, tomorrow OpenClaw, next year something unnamed. Each ships its own ranking/extraction. If the user switches agents, the engine is thrown away.
- **The user's memory data + access policy is per-user and durable.** "Lives in Shanghai, allergic to peanuts," the travel/family/work namespace split, who's allowed to read `personal` — that must outlive *every* agent the user ever runs, and stay identical whether queried via Hermes, a Doubao agent, or a toy.

If memory lives inside a disposable per-agent engine (Position B), the durable thing is trapped in the disposable thing. Switching agents = losing memory or re-exporting through a vendor's format. **Owning the store is what makes memory portable across the agents the user is guaranteed to churn through.** That is the cross-agent neutrality `agent-iam-strategy.md` calls the structural moat — applied to the data plane.

This is also why "memory is not our core value" is half-true: the memory *engine* isn't our value; the **durable, neutral, gated memory store IS** — it's the same asset as the credential vault, one data-class over (arch.md §17).

---

## 5. Reconciling the three in-repo docs

The repo currently holds three positions that look inconsistent; C reconciles them:

| Doc | What it says today | Under Position C |
|---|---|---|
| [`agent-iam-strategy.md`](./agent-iam-strategy.md) | "Memory MCP server is too narrow; we're the authority/control plane" (gate-leaning) | ✅ Correct — we gate. Add: we also own the *store*, not the engine. |
| [`milestones-roadmap.md`](../plan/milestones-roadmap.md) M1 | `memory.get`/`memory.put` MCP tools + `namespaces_allowed` cap claim (gated store) | ✅ This **is** Position C already — a gated store exposed as tool calls. Keep as-is. |
| [`memory-design.md`](../plan/agentkeys-memory-design.md) | Full worker: vault + vector index + BM25 + rebuild-index ("build a system") | ⚠️ Over-scoped. The **store** half (cap-gated get/put, K3 envelope, per-actor S3, namespaces, audit) is Position C and stays. The **engine** half (vector index, BM25, `/rebuild-index`, embedding rotation) becomes *optional / pluggable* — not core, not the default ship. |

The roadmap (M1) was already at Position C. `memory-design.md` is the outlier that drifted toward A. This record pins the intent; a future edit to `memory-design.md` should reframe it from "memory system" to "gated memory backend" and move §4.2/§5 (search + index engine) into an explicit "pluggable engine — not built by us in v0" section.

---

## 6. What Position C means concretely

**Keep (the store + gate — our moat):**
- Cap-token-gated `memory.get` / `memory.put` (+ the 4 structural types + namespaces). M1 issue #108 unchanged.
- K3-derived AES-256-GCM envelope, per-actor S3 prefix, per-actor PrincipalTag IAM, data-class binding (arch.md §17.5).
- Namespace scoping (`namespaces_allowed` cap claim) — the permission story.
- Audit on every read/write (two-tier, M1 issue #109).

**Cut / defer (the engine — let the ecosystem provide):**
- In-worker vector index, BM25, RRF fusion, `/rebuild-index`, embedding-model rotation (`memory-design.md` §4.2, §5). These were the highest-leverage *engine* borrows from the agentmemory research — now explicitly out of our build. If an operator wants semantic recall, they run a pluggable engine in front of our store.
- The worker stays an **encrypted KV/blob store with namespace-filtered list/get** — deterministic, no LLM, no ranking. (This is *less* than `memory-design.md` builds today, which is the point.)

**Three integration shapes the store now supports (all engine-pluggable):**
1. **Claude memory tool backend** — `BetaAbstractMemoryTool` subclass routes file ops → AgentKeys worker. Claude is the engine; we're the encrypted store. (Cleanest; vendor-blessed.)
2. **mem0 self-hosted, AgentKeys as final store** — mem0 does extraction/ranking; persisted bytes land in our vault via the cap-gated API.
3. **Hermes MemoryProvider (~120-line plugin)** — `prefetch`/`sync_turn` proxy to AgentKeys `memory.get`/`memory.put`; Hermes-native ranking, our gated store. (Maps 1:1 per the hermes-v0.15 research.)

In all three, the agent calls memory **as a gated tool**, the engine is swappable, and the bytes are in AgentKeys' K3-encrypted per-actor vault. Exactly the user's "abstract like a tool call and gate it" — with the store kept ours so the privacy requirement holds.

---

## 7. What we explicitly do NOT delegate

- **The store.** Never mem0-cloud, never a vendor's server holding plaintext. The bytes are K3-encrypted in the operator's S3 or they don't exist.
- **The gate.** Cap-token + scope + namespace + audit is the product. An engine may *call* the gate; it never *replaces* it.
- **The key custody.** K3-derived KEK, per arch.md §4. No engine ever holds the decryption key; engines that need plaintext get it only inside the operator's trust boundary, post-decrypt, like any other cap-gated data-class.

Delegating any of these three = giving up the differentiator and re-importing the privacy problem the architecture exists to solve.

---

## 8. Consequences + follow-ups

- **`memory-design.md` reframe** (separate change, not done here): "memory system" → "gated memory backend"; demote the engine sections to "pluggable, not built in v0." Tracked as a follow-up; this record is the authority for the intent until that edit lands.
- **arch.md §15.2 / §17**: add one paragraph — "the memory worker is the gated *store*; ranking/extraction *engine* is pluggable and out of AgentKeys' build." Per the architecture-as-source-of-truth rule.
- **New research worth doing**: a thin spec for the "AgentKeys as Claude `BetaAbstractMemoryTool` backend" adapter — likely the highest-signal proof of Position C and a strong demo ("Claude's own memory, but encrypted + per-actor-isolated + audited by AgentKeys").
- **Net effect on scope**: Position C is *less* engineering than `memory-design.md` as written, and it stops us competing with mem0/Zep/Letta on the layer they'll win anyway. The build shrinks; the moat sharpens.

---

## References

**Founding requirement:** this thread's opening message (store in S3; portable/extractable; injected on the way; LLM never sees whole memory; LLM pluggable).

**In-repo:**
- [`agent-iam-strategy.md`](./agent-iam-strategy.md) — authority-host thesis; line 46 "memory MCP server too narrow."
- [`../plan/milestones-roadmap.md`](../plan/milestones-roadmap.md) — M1 `memory.get`/`memory.put` + namespaces (already Position C).
- [`../plan/agentkeys-memory-design.md`](../plan/agentkeys-memory-design.md) — the store design (keep) + engine design (now pluggable).
- [`ai-memory-systems-survey.md`](./ai-memory-systems-survey.md), [`agentmemory-and-claw-code-followup.md`](./agentmemory-and-claw-code-followup.md), [`xiaozhi-hermes-architecture.md`](./xiaozhi-hermes-architecture.md) — engine survey + Hermes provider/hook model.

**External (verified 2026-05):**
- [Claude memory tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool) — client-side; operator owns the store; `BetaAbstractMemoryTool` backend (S3 / encrypted files).
- [mem0 platform vs OSS](https://docs.mem0.ai/platform/platform-vs-oss) — cloud (their servers) vs self-host (your infra, mem0's vector DB).
- [Hermes memory-provider plugin spec](https://hermes-agent.nousresearch.com/docs/developer-guide/memory-provider-plugin) — provider = engine+store bundled, per-agent.
