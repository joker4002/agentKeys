# AI memory systems — survey

**Status:** research artifact (2026-05). Not authoritative. Informs the AgentKeys memory plan at [`../plan/agentkeys-memory-design.md`](../plan/agentkeys-memory-design.md).

**Goal of this doc:** answer the question *"if we want long-term agent memory persisted in S3 (the AgentKeys memory worker, arch.md §15.2), behind a cap-token gate, with the LLM **pluggable** and never given full visibility of the memory — what does the field actually do, and what should we copy / avoid?"*

The AgentKeys-specific design lives in the companion plan doc. This doc is the input.

---

## 1. The four memory types every modern system converges on

Independent of vendor, the same four-way split keeps appearing. Use this taxonomy throughout the rest of the doc.

| Type | What it stores | Lifetime | Read pattern | Example |
|---|---|---|---|---|
| **Episodic** | Raw events / conversations / tool-call transcripts, time-ordered | Append-only; retention policy | "Find sessions where X happened" — needle in haystack | "On Tuesday the user asked about Q3 numbers." |
| **Semantic** | Distilled facts + entities + relations, deduplicated | Updated in place (or invalidated, never deleted) | Lookup by key or graph traversal | "User prefers metric units. Lives in Berlin. Works at Acme." |
| **Procedural** | How-to-do-X — system prompts, learned heuristics, code patterns | Rewritten as the agent learns | Loaded as instructions, not "retrieved" | "When user asks about prices, always quote in EUR first." |
| **Profile** | Bounded structured state about the user / actor / world | Updated in place; size-bounded | Loaded wholesale (small) | `{name, timezone, preferences, ongoing_projects[]}` |

LangMem makes this taxonomy explicit ([LangMem docs](https://github.com/langchain-ai/langmem/blob/main/docs/docs/concepts/conceptual_guide.md)); Letta uses different names (core / recall / archival) but maps cleanly: core ≈ profile + procedural, recall ≈ episodic, archival ≈ semantic.

**Why this matters for AgentKeys.** A single "memory blob in S3" treats all four the same. The current worker (handlers.rs `memory_put` / `memory_get`) is service-keyed only — `bots/<actor>/memory/<service>.enc` — which collapses to "one big blob per service per actor." Fine as a primitive; insufficient as the only abstraction. The plan doc layers the four types on top of this primitive without changing the worker's cap-gated wire surface.

---

## 2. Pipeline shape — three stages, every system has them

```
   raw conversation / tool calls
              │
              ▼
       ┌─────────────┐
       │  EXTRACT    │   what is worth remembering? distill, summarize, tag
       └─────────────┘
              │
              ▼
       ┌─────────────┐
       │ CONSOLIDATE │   dedupe, merge with existing memory, invalidate stale
       └─────────────┘
              │
              ▼
       ┌─────────────┐
       │  RETRIEVE   │   given a query, return top-K relevant items
       └─────────────┘
              │
              ▼
        injected into LLM prompt
```

Differences across systems are mostly *who runs each stage*, *how much LLM is involved*, and *where the artifacts live*.

| System | Extract | Consolidate | Retrieve |
|---|---|---|---|
| **Mem0** | One LLM call per turn (v1) → one ADD-only LLM pass over the session (v2, Apr 2026) | LLM-driven: ADD / UPDATE / DELETE decisions per fact | Vector search + optional graph traversal |
| **Letta / MemGPT** | Agent decides via tool calls (`core_memory_append`, `archival_memory_insert`) | Agent issues `core_memory_replace` when contradicting facts surface | Agent issues `recall_search` / `archival_search` tool calls |
| **Zep / Graphiti** | LLM extracts entities + relations from each "episode" (turn / event) | Bi-temporal graph: old facts get a `valid_until` timestamp, new fact gets `valid_from` — never deleted | Hybrid vector + graph traversal; queries can be time-scoped |
| **A-MEM** | Each new memory becomes a "note" with tags + keywords + contextual desc | Dynamic linking: new note triggers updates to linked historical notes (Zettelkasten) | Graph traversal over notes |
| **Cognee** | Six stages: classify → permission → chunk → entity-extract → summarize → embed | Background sweep prunes stale nodes, reweights edges by usage | Vector + graph hybrid |
| **MemMachine** | **Stores raw episodes**, only summarizes for high-level abstraction — claims ~80% token reduction vs Mem0/Zep | Sentence-level index over raw episodes; LLM only at summary tier | Contextualized retrieval: nucleus match + neighboring-turn expansion |
| **LangMem** | Two modes: (a) hot-path tools the agent calls during conversation, (b) background memory manager that extracts async | Configurable per memory type; profile is updated, collection is appended | `BaseStore` interface — caller picks vector / SQL / etc. |
| **Claude memory tool** | Claude decides via file ops (`create`, `str_replace`, `view`) in a `/memories` dir | Claude rewrites files as needed | Claude reads files explicitly via tool calls — no separate retrieval |
| **ChatGPT memory** | Saved memories: explicit "remember this" or LLM-inferred. Chat history: every message indexed | Pre-computed user-profile + extracted-knowledge tiers | "Active context" tier — pre-computed summary injected wholesale per chat |
| **OpenMemory MCP** | Mem0 under the hood; MCP server interface | Mem0's LLM-driven consolidation | MCP `search_memory` tool exposes vector search |

**Two axes of variation worth naming:**

- **LLM-heavy vs LLM-light extraction.** Mem0 / Zep / Cognee call the LLM on every turn to decide what to extract — accurate, expensive, slow. MemMachine stores raw and defers LLM calls to summarization tier — fast, cheap, but loses some structured extraction. Letta and Claude memory tool hand the decision to the agent itself via tool calls — the agent extracts when it wants to, which makes the cost user-controlled but bursty.
- **Where consolidation lives.** Graphiti's bi-temporal model never deletes — the graph IS the audit trail. Mem0 v2 stops deleting too (ADD-only). Letta / Claude memory tool delete freely. ChatGPT's "saved memories" are deletable; chat history is append-only with a separate index. For AgentKeys, which already has a chain-anchored audit layer (arch.md §15.3), **append-only with explicit invalidation** is the obvious fit — it composes with the audit invariants we already have.

---

## 3. Storage substrate — vector, graph, JSON, files, or hybrid

| System | Substrate | Why |
|---|---|---|
| **Mem0** | Vector DB (Qdrant default) + optional graph (Neo4j) + key-value store | Started vector-only; added graph for relation queries |
| **Letta** | Postgres (default) — message log table + memory-blocks table + archival table with pgvector | Single DB simplifies ops; pgvector good enough for archival recall |
| **Zep** | Neo4j (Graphiti requires graph DB) + vector index inside Neo4j | Bi-temporal graph is the architecture's center of gravity |
| **A-MEM** | Vector DB + lightweight in-memory graph (notes ↔ links) | Zettelkasten linking IS the model — graph is small |
| **Cognee** | Pluggable: Neo4j / FalkorDB / KuzuDB / NetworkX (graph) + Qdrant / Weaviate / Redis (vector) + SQLite / Postgres (metadata) | Memory control plane — picks per deployment |
| **MemMachine** | Postgres + vector index — raw episodes are the source-of-truth | Optimizes for retrieval fidelity over storage cost |
| **LangMem** | `BaseStore` abstraction — Postgres default, can plug others | Library, not a service — defers substrate to caller |
| **Claude memory tool** | **Flat file directory `/memories/`** on the operator's infrastructure | Each tool call is `view` / `create` / `str_replace` on a file; no DB needed |
| **ChatGPT memory** | OpenAI internal; reverse-engineered as: user-profile table + chat-history index + extracted-knowledge store + per-chat active-context cache | Closed |
| **OpenMemory MCP** | Postgres + Qdrant — same as Mem0 self-hosted | Re-uses Mem0's substrate; adds per-app ACL table |

**Observation that matters for AgentKeys.** *Most* of these systems treat S3 / blob storage as an afterthought — they want a vector DB or graph DB for query speed. **Claude's memory tool is the outlier**: a flat file directory IS the memory, and the LLM (Claude) is the indexer-by-reading. This is the model closest to what AgentKeys can deliver cheaply: **S3 IS the substrate**, and the worker exposes a structured query API on top. Vector + graph indices can be derived artifacts (rebuildable, ephemeral) layered alongside the durable JSONL log.

---

## 4. Retrieval mechanics — how memory gets in front of the LLM

This is the section that maps directly onto the user's privacy constraint: *"Memory is injected on the way, not as a whole context sent to the LLM."*

Five distinct patterns observed:

### 4.1 Full-context injection ("just paste it all")

ChatGPT's "active context" tier does this for the small pre-computed user-profile summary. Letta's core-memory blocks do this for the small core-memory window. Works when the memory is small + bounded.

**Privacy property:** the LLM sees everything that's in core/active. Acceptable for ~hundreds-of-bytes profile data; not acceptable for an episodic log.

### 4.2 Tool-call retrieval ("agent asks for what it needs")

Letta's `archival_memory_search`, Claude memory tool's `view`, MemGPT's `recall_search`. The agent calls a tool, gets results, then continues reasoning.

**Privacy property:** LLM sees the query (what it's looking for) AND the returned results — but ONLY the returned results, not the whole memory. Surface is controlled by what the LLM thinks to search for. **This is the "JIT injection" pattern the user asked for.**

### 4.3 Pre-call RAG ("retrieve top-K, then prompt")

Mem0, Zep, Cognee default. Before the LLM call, an embedding retrieval (+ optional graph traversal) runs against the memory store; top-K results are stuffed into the prompt as system context.

**Privacy property:** LLM sees retrieved snippets but never the whole store. The query is the user's actual message (used for embedding); the LLM doesn't see *other* users' or other actors' memories. **This is also the "JIT injection" pattern**, just with the retrieval initiated by the orchestrator instead of by the LLM.

### 4.4 Background extraction-only, no retrieval injection

Some configurations of LangMem and Cognee run extraction in the background and never inject — the memory exists for the operator to read, not for the LLM. Surface for adversarial/red-team review, not for in-conversation use.

### 4.5 Streaming context compaction (the Anthropic context-editing pattern)

Different shape: the memory tool pairs with `clear_tool_uses_20250919` ([Claude docs](https://platform.claude.com/docs/en/build-with-claude/context-editing)). When context fills up, Claude is *warned* to write important items to `/memories/` before tool-result history gets evicted. The "memory" here is mostly about pushing state OUT of context, not pulling it IN.

**Critical privacy distinction for AgentKeys.** Patterns 4.2 and 4.3 both implement "LLM never sees full memory" — but with different threat models:

- Pattern 4.2 (tool-call) trusts the LLM to choose what to query. If the LLM is compromised, it can issue queries that exfiltrate via the query strings themselves.
- Pattern 4.3 (pre-call RAG) hides the retrieval from the LLM entirely — the LLM only sees results, never the index, never the un-retrieved items. If the LLM is compromised, it sees only what would have been injected anyway.

For AgentKeys's stated goal of "rotate the LLM layer easily" and "LLM does not have full visibility," **pattern 4.3 (pre-call RAG with retrieval done by a non-LLM component)** is the strictly stronger choice. Pattern 4.2 should be allowed as an additive escape hatch but not the default.

---

## 5. Portability — how memory leaves one system and enters another

| Standard | Shape | What's included | Notes |
|---|---|---|---|
| **Agent File `.af`** ([Letta](https://github.com/letta-ai/agent-file)) | Single JSON blob | Model config, message history, system prompts, memory blocks, tool rules, env vars, tool source code + schema | Secrets exported as null. Theoretically loadable into non-Letta runtimes. Includes agent state, not just memory. |
| **JSON Agents PAM** ([jsonagents.org](https://jsonagents.org/)) | JSON manifest | Agent capabilities + tools + runtimes + governance — *not* memory itself | Higher-level than memory; useful as the outer envelope. |
| **JSONL** | One JSON object per line | Free-form — convention is `{role, content, timestamp, ...}` for messages | Stream-friendly. Every major LLM training framework consumes it natively. |
| **Mem0 export** ([mem0 docs](https://github.com/mem0ai/mem0)) | JSON with embedding + metadata per entry | Memory entries with `{id, text, metadata, embedding, owner, namespace}` | Vendor-specific schema; not formally an open standard. |
| **OpenAI export** | JSON | Conversations + saved memories | Format is private, may change. |

**Pattern worth adopting.** Letta's `.af` is the most thought-through portable format, but it bundles agent identity + memory together. For AgentKeys, the memory bundle should be:

- **JSONL inside a zip / tar** (streamable; constant memory to read; trivially diffable)
- **One JSONL file per memory type** (`episodic.jsonl`, `semantic.jsonl`, `procedural.jsonl`, `profile.json`)
- **Plus a `manifest.json`** with schema version, actor_omni, export timestamp, optional encryption marker
- **Plus optional `embeddings.bin`** if the operator wants to bring the index along (otherwise rebuildable from text)

The user's "portable, extractable, efficient" requirement maps directly to this shape. JSONL keeps decoder cost flat (no full-file parse); separating types keeps re-import to one new system simple (just consume the type that system supports).

---

## 6. Privacy patterns — what the field does to limit LLM exposure

The user's privacy ask is the architectural pivot: *"LLM do not have the whole visibility of my memory, so I can also easily rotate the LLM layer, make it the LLM pluggable."*

Three patterns from the literature directly support this.

### 6.1 Decompose: keep LLMs out of the trust path

Privacy-preserving LLM deployments route privacy-critical operations to dedicated, cryptographically secured components and keep the large LLM in non-critical paths ([emergentmind summary](https://www.emergentmind.com/topics/privacy-preserving-llm-deployment)).

**AgentKeys mapping:** the memory worker (Rust, in operator's AWS, behind cap-token gate, behind chain verification) is the privacy-critical component. The LLM is NOT in the memory worker's trust path — it never sees the KEK, never sees the cap, never authenticates to S3 directly. The LLM is on the *consumer* side of the worker.

### 6.2 Minimal context exposure ("send only what's needed")

Standard enterprise guidance: only send the minimum data required to answer the question or complete a task, and omit classified items from external prompts entirely ([Kiteworks](https://www.kiteworks.com/cybersecurity-risk-management/prevent-llm-data-leakage-controls/)). MemMachine quantifies the cost: when LongMemEval gave GPT-4o the full conversation history it scored **60.6%**, vs **87.0%** when given only the relevant sessions. *More context is actively worse, both for cost AND accuracy.*

**AgentKeys mapping:** the JIT pre-call RAG pattern (§4.3) IS minimal-context-exposure. Top-K retrieval, never wholesale.

### 6.3 Proactive privacy amnesia + contextual privacy protection

Recent research lines ([PPA](https://arxiv.org/pdf/2502.17591), [CPPLM](https://arxiv.org/pdf/2310.02469)) train LLMs to actively forget PII or to enforce contextual privacy at inference time. Different threat model — these protect against the LLM having memorized PII during training, which is upstream of what AgentKeys controls.

**AgentKeys mapping:** out of scope at the memory-worker layer; relevant only if AgentKeys ever ships an operator-owned fine-tuned model. Note for completeness, not for v0.

### 6.4 The pluggability property

If the LLM is on the consumer side of the memory worker (not on the trust path), the worker's API is LLM-agnostic by construction. Any LLM that can:

- emit an embedding vector (for retrieval), OR
- accept retrieved snippets as part of its prompt

…can use this memory. The worker doesn't care whether the consumer is GPT-4o, Claude Sonnet 4.5, Llama 3, a local Qwen, or zero LLM (a plain agent doing rule-based lookup). The plan doc encodes this as a hard invariant: **the memory worker MUST NOT call an LLM**.

---

## 7. Benchmarks — what "good" looks like in 2025-2026

Two standard benchmarks:

- **LoCoMo** — 1,540 questions, 10 conversation corpora, 272 sessions. Tests single-hop, multi-hop, open-domain, temporal recall. ([paper](https://arxiv.org/abs/2402.17753))
- **LongMemEval** — 500 questions, each accompanied by ~48 sessions of which only 1–3 are relevant. Knowledge updates + multi-session recall. ([paper](https://arxiv.org/html/2507.05257v3))

Both report accuracy + token consumption + latency.

Recent leaderboard snapshot (2026):

| System | LoCoMo | LongMemEval-S | Tokens/query | Notes |
|---|---|---|---|---|
| **GPT-4o full-context baseline** | — | 60.6% | huge | What happens when you don't have a memory system |
| **GPT-4o oracle (only relevant sessions)** | — | 87.0% | small | Theoretical ceiling for retrieval-based memory |
| **Mem0** | ~80s | ~74% (cite varies) | small | Strong baseline |
| **Zep** | reported >MemGPT | reported strong | medium | Bi-temporal helps temporal questions |
| **ByteRover 2.0** | 92.2% | 92.8% | medium (1.6s latency) | [byterover blog](https://www.byterover.dev/blog/benchmark-ai-agent-memory) |
| **MemMachine** | 91.69% (gpt4.1-mini) | 93.0% | ~80% lower than peers | [arxiv](https://arxiv.org/pdf/2604.04853) |

**For AgentKeys v0:** these benchmarks are not yet directly applicable — we are not optimizing retrieval quality, we are building the substrate. But the lesson is "minimum-context retrieval beats full-context injection across cost AND accuracy" — which is exactly the architecture the user is asking for.

---

## 8. What AgentKeys can borrow, and what it should ignore

| Idea | Source | Borrow? | Why |
|---|---|---|---|
| Four-type taxonomy (episodic / semantic / procedural / profile) | LangMem, MemGPT | ✅ Borrow | Maps cleanly onto S3 prefix layout |
| Memory blocks always-in-context | Letta core memory | ⚠️ Partial — only for tiny profile + procedural; episodic stays out | LLM-pluggability + privacy invariants |
| Bi-temporal "never delete, only invalidate" | Zep / Graphiti | ✅ Borrow | Already matches AgentKeys audit invariants (arch.md §15.3) |
| Zettelkasten dynamic linking | A-MEM | 🟡 Defer | Adds LLM-call cost; revisit after v0 ships |
| Ground-truth-preserving raw-episode store | MemMachine | ✅ Borrow | Cheap on S3; LLM-light by design; fits "extractable" requirement |
| Vector DB (Qdrant / pgvector) as primary substrate | Mem0, Letta, Cognee | ❌ Skip | S3 is the substrate. Vector index is a derived rebuildable artifact. |
| Graph DB (Neo4j) | Zep, Cognee | ❌ Skip for v0 | Adds operational surface; revisit if entity-relation queries dominate workload |
| LLM-driven extract-on-every-turn | Mem0 v1, Cognee | ❌ Skip | Couples memory worker to an LLM choice. **Violates pluggability invariant.** |
| Agent-driven tool-call extraction | Letta, Claude memory tool | ✅ Borrow as additive | Lets the agent (whichever LLM) opt into extraction without coupling worker to it |
| Pre-call RAG with embeddings retrieval | Mem0, Zep, ChatGPT active context | ✅ Borrow as default | The JIT injection pattern; LLM-agnostic by construction |
| Agent File `.af` portable format | Letta | ⚠️ Inspire-not-copy | We need *memory* portable, not full agent — different shape |
| MCP server interface | OpenMemory MCP | 🟡 Consider | Easy way to expose the worker to any MCP client; layer on top, not the worker itself |
| Per-app ACL rules | OpenMemory MCP | ❌ Skip — we have cap-tokens | The cap + scope contract is the AgentKeys equivalent, stricter |

---

## 9. Reference list

Core papers + docs read for this survey (chronological where it matters):

**Systems papers:**

- Packer et al., *MemGPT: Towards LLMs as Operating Systems*, 2023 (revised 2024) — origin of core/recall/archival tiers. [arxiv](https://arxiv.org/abs/2310.08560)
- Rasmussen et al., *Zep: A Temporal Knowledge Graph Architecture for Agent Memory*, Jan 2025. [arxiv](https://arxiv.org/abs/2501.13956)
- Xu et al., *A-Mem: Agentic Memory for LLM Agents*, Feb 2025 (NeurIPS 2025 poster). [arxiv](https://arxiv.org/abs/2502.12110)
- Chhikara et al., *Mem0: Building Production-Ready AI Agents with Scalable Long-Term Memory*, Apr 2025. [arxiv](https://arxiv.org/abs/2504.19413)
- *MemMachine: A Ground-Truth-Preserving Memory System for Personalized AI Agents*, 2026. [arxiv](https://arxiv.org/abs/2604.04853)

**Vendor docs + blogs:**

- Anthropic, [Managing context on the Claude Developer Platform](https://www.anthropic.com/news/context-management), 2025.
- Anthropic, [Memory tool](https://docs.claude.com/en/docs/agents-and-tools/tool-use/memory-tool), 2025.
- Anthropic, [Context editing](https://platform.claude.com/docs/en/build-with-claude/context-editing), 2025.
- OpenAI, [Memory and new controls for ChatGPT](https://openai.com/index/memory-and-new-controls-for-chatgpt/), 2024-2025.
- Letta, [Agent memory blog](https://www.letta.com/blog/agent-memory) + [Memory blocks](https://www.letta.com/blog/memory-blocks) + [Agent File](https://www.letta.com/blog/agent-file).
- LangChain, [LangMem SDK launch](https://www.langchain.com/blog/langmem-sdk-launch) + [conceptual guide](https://github.com/langchain-ai/langmem/blob/main/docs/docs/concepts/conceptual_guide.md).
- Neo4j, [Graphiti: Knowledge Graph Memory for an Agentic World](https://neo4j.com/blog/developer/graphiti-knowledge-graph-memory/).
- Cognee, [How Cognee Builds AI Memory for Agents](https://www.cognee.ai/blog/fundamentals/how-cognee-builds-ai-memory).
- Mem0, [State of AI Agent Memory 2026](https://mem0.ai/blog/state-of-ai-agent-memory-2026) + [OpenMemory MCP](https://mem0.ai/blog/introducing-openmemory-mcp).

**Standards + formats:**

- Letta, [Agent File `.af` spec](https://github.com/letta-ai/agent-file).
- [JSON Agents PAM standard](https://jsonagents.org/).

**Privacy:**

- [PrivacyMind / CPPLM](https://arxiv.org/pdf/2310.02469).
- [Proactive Privacy Amnesia](https://arxiv.org/pdf/2502.17591).
- ["Ghost of the past": Identifying and Resolving Privacy Leakage of LLM's Memory](https://arxiv.org/html/2410.14931v1).
- [Kiteworks: Prevent Sensitive Data Leakage with LLMs](https://www.kiteworks.com/cybersecurity-risk-management/prevent-llm-data-leakage-controls/).

**Benchmarks:**

- LoCoMo, LongMemEval comparisons: [emergentmind](https://www.emergentmind.com/topics/locomo-and-longmemeval-_s-benchmarks), [byterover benchmark blog](https://www.byterover.dev/blog/benchmark-ai-agent-memory).

---

## 10. What the AgentKeys plan must answer

These are the open questions the survey surfaced — answered in the companion plan doc.

1. **Storage layout.** Today's worker is `bots/<actor>/memory/<service>.enc`. How do four memory types nest inside that?
2. **Wire format.** JSONL append-only? Single rewritten JSON? Hybrid?
3. **Extraction pipeline location.** In the worker (couples worker to LLM choice — bad)? In the agent's sandbox (preserves LLM-pluggability — good)? In a dedicated extractor sidecar (more complex)?
4. **Retrieval API.** Tool-call style (4.2)? Pre-call RAG style (4.3)? Both?
5. **Index location.** Inline in S3 (rebuildable, ephemeral)? Separate DB (adds operational surface)?
6. **Portability.** What does `agentkeys memory export` produce? What does `agentkeys memory import` accept?
7. **Privacy invariants.** What's the worker's promise about what the LLM can see?
8. **Integration with cap-tokens + per-data-class IAM.** Does the four-type taxonomy need four cap endpoints, or one?
