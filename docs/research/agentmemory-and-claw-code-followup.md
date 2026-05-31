# agentmemory + claw-code — focused research follow-up

**Status:** research artifact (2026-05). Follow-up to [`ai-memory-systems-survey.md`](./ai-memory-systems-survey.md) — those 10 systems covered the field of AI memory products. This doc digs into two specific projects the team flagged after the survey: [`rohitg00/agentmemory`](https://github.com/rohitg00/agentmemory) (17.5K stars, claimed "#1 persistent memory for AI coding agents") and [`ultraworkers/claw-code`](https://github.com/ultraworkers/claw-code) (192K stars, claimed "fastest repo to surpass 100K stars").

**Decisions surfaced:** see §3 ("What to borrow") and §4 ("What to skip"). The decisions are recommendations only — none folded into [`../plan/agentkeys-memory-design.md`](../plan/agentkeys-memory-design.md) at the time of writing.

---

## 1. agentmemory — what's actually in the repo vs the claim

**Surface claim** (from README badges): 95.2% R@5 on LongMemEval-S, 92% fewer tokens, 0 external DBs, 53 MCP tools, 12 auto hooks, 950+ tests passing.

**What this repo actually contains** (verified by reading the public file tree):

| Folder | Contents | Verdict |
|---|---|---|
| `packages/mcp/` | 4 files — README + `bin.mjs` + `package.json` + LICENSE. A 30-line npm shim that just `npx -y @agentmemory/agentmemory mcp`. | **Wrapper only — no engine code.** |
| `integrations/` | Glue for OpenClaw, Hermes, pi, filesystem-watcher | **Glue, not engine.** |
| `plugin/` | Claude Code + Codex CLI + OpenCode hook scripts | **Hook adapter scripts.** |
| `benchmark/` | LongMemEval reproduction scripts + `COMPARISON.md` | **Real, reproducible, no engine code.** |
| `DESIGN.md` | 200+ lines | **Not the memory design — it's a Lamborghini-themed UI style guide for the website.** |
| `ROADMAP.md`, `GOVERNANCE.md`, `SECURITY.md` | Standard open-source hygiene | **Solid governance posture.** |

**Where the engine actually lives:** every architectural claim (4-tier consolidation, hybrid search, decay, supersession, embeddings) is implemented in either:

1. **The closed-source `@agentmemory/agentmemory` npm package** (downloaded by the shim above, not committed to this repo), OR
2. **The [`iii-hq/iii`](https://github.com/iii-hq/iii) engine** — a separate 16K-star Rust project that's a general-purpose service-composition runtime (`worker / function / trigger` primitives + KV state + queue + pubsub + cron + stream + observability). agentmemory's `iii-config.yaml` enumerates the iii workers it depends on.

The README admits this: *"Built on iii engine."* The "0 external DBs" claim refers to iii's file-based KV state — not "no DB" in the sense of "data sits on flat files I can grep." It's a programmatic KV store with serialization, indexing, and access patterns of its own.

**Engineering posture observations** (worth recording — these are positive lessons regardless of the architecture):
- Roadmap is dated, quarterly-themed, and lists what shipped vs what slipped per quarter.
- SECURITY.md routes vulns through GitHub Security Advisories with 72-hour ACK + 30-day default disclosure window.
- Reproducible benchmarks committed in-repo (`npm run bench:longmemeval`).
- Apples-vs-oranges caveat explicitly called out: their 95.2% is on LongMemEval-S; Mem0/Letta numbers they cite are on LoCoMo, not the same dataset.

### 1.1 agentmemory architecture (from README + COMPARISON + ROADMAP)

| Concern | Implementation |
|---|---|
| **Storage substrate** | iii's file-based KV (`store_method: file_based`) at `./data/state_store.db` |
| **Embeddings** | `all-MiniLM-L6-v2` runs in-process (no API key); optional API embeddings supported |
| **Search** | Hybrid: BM25 + vector cosine + graph traversal, fused via reciprocal-rank fusion |
| **Tiers** | 4 — working → episodic → semantic → procedural; consolidation between tiers |
| **Decay** | Ebbinghaus forgetting curve + per-tier half-lives |
| **Supersession** | Jaccard similarity on text dedupes new-overlapping-old |
| **Auto-capture** | 12 lifecycle hooks (Claude Code), 6 (Codex), 22 (OpenCode); agent-loop-driven `append`, no manual `add()` |
| **Privacy** | Regex/heuristic secrets-scrub pre-store (API keys, JWTs, AWS keys) |
| **Surface** | REST + 53 MCP tools + real-time viewer (port 3113) |
| **Multi-agent** | Lease-and-signal mesh; one server, many clients across Claude/Cursor/Codex/etc. |
| **Versioning** | Jaccard-based supersession plus an audit trail of all mutations |

### 1.2 The "best on the market" claim — honest read

The benchmark numbers are reproducible and the comparison table is methodologically careful (it flags the LongMemEval vs LoCoMo mismatch explicitly). The methodology around capture (12 hooks) is genuinely more thorough than Mem0's manual `add()` or Letta's agent-self-edit model. For the *agent-coding-history* use case, on the LongMemEval benchmark, with the apples-vs-oranges caveat, the claim is **defensible** — though "#1" depends on which benchmark you weight and what use case you optimize for.

It is **not** a general-purpose persistent-data infrastructure. The AgentKeys memory worker solves a different problem (encrypted-at-rest, per-actor-isolated, chain-anchored memory for an actor whose LLM is operator-replaceable). agentmemory assumes a trusting single-tenant developer running a coding agent on their laptop. The architectural overlap is real but limited.

---

## 2. claw-code — what it actually is

**Surface claim** (from README): "The fastest repo in history to surpass 100K stars." 192K stars.

**Reality check** (from `PHILOSOPHY.md`):

> The Python rewrite was a byproduct. The Rust rewrite was also a byproduct. The real thing worth studying is the system that produced them: a clawhip-based coordination loop where humans give direction and autonomous claws execute the work.

> The important interface here is not tmux, Vim, SSH, or a terminal multiplexer. The real human interface is a Discord channel.

claw-code is **a Rust port of the `claw` CLI agent**, autonomously built and maintained by a coordination system (`oh-my-codex` + `clawhip` + `oh-my-openagent`). The repo is the *product of an autonomous coding pipeline*, not itself a memory product. The 192K stars are a marketing artifact of the coordination-system demonstration.

### 2.1 The memory-relevant piece: claw-rag-service

The only memory-adjacent component is **`rust/crates/claw-rag-service`** — a tiny standalone Rust binary (8 source files: chunk.rs, db.rs, embed.rs, ingest.rs, lib.rs, main.rs, qdrant_index.rs, search.rs).

```
claw-analog ──POST /v1/query──► claw-rag-service ──► SQLite + linear cosine
                                       │
                                  ingest --watch (chunks + blake3 hash)
                                       ▼
                                  workspace files
```

| Concern | Implementation |
|---|---|
| **What it stores** | Code chunks from the workspace, NOT agent conversation history |
| **Storage** | SQLite via `rusqlite` (bundled feature); optional Qdrant via `qdrant-index` feature flag |
| **Embeddings** | Any OpenAI-compatible endpoint (env `CLAW_RAG_EMBEDDING_BASE_URL`), default `text-embedding-3-small` |
| **Search** | Linear cosine over all SQLite rows. Their own docs label this *"Phase 1 MVP, plan ANN later via sqlite-vec / Qdrant in Docker"*. |
| **HTTP API** | `GET /` (web UI), `GET /health`, `GET /v1/stats`, `POST /v1/query` |
| **Mock mode** | `CLAW_RAG_MOCK_PROVIDERS=1` returns deterministic vectors without network calls — used for CI |
| **Agent integration** | claw-analog has ONE tool named `retrieve_context` that wraps the HTTP call; `RAG_BASE_URL` / `rag_base_url` config drives it |
| **Chunking** | blake3 file/chunk hash for dedupe across files |

### 2.2 What claw-code is NOT

- It is not "agent memory" in the persistent-conversation-history sense. It is code-RAG.
- It is not architecturally distinct from a hundred other RAG-over-codebase tools (Cody, Cursor's codebase indexing, Sourcegraph). The novelty is the **separate-process posture** + **OpenAI-compat embeddings as the seam** + **the "Phase 1 MVP → Phase 2 ANN" growth story being explicit**.
- It is not relevant to the AgentKeys problem domain *as a system*. But its architectural posture (separate process, HTTP API, SQLite-or-better storage, single agent-facing tool) is convergent with what our plan already specifies — useful confirmation we're on a reasonable path.

---

## 3. What to borrow — six concrete items

Cross-referenced against [`../plan/agentkeys-memory-design.md`](../plan/agentkeys-memory-design.md). Each item is a recommendation, not a decision; integrate during the appropriate M-stage if accepted.

### 3.A — Lifecycle-hook auto-capture (from agentmemory)

**What it is.** agentmemory's biggest differentiator vs Mem0 / Letta is "zero manual `append()` calls." The agent's lifecycle (turn start, turn end, tool call, tool result, error) fires hooks that the memory layer subscribes to. The operator wires the hooks once at setup, then memory accumulates automatically.

**AgentKeys mapping.** Enrich plan §6.1 ("Inline in the agent — default"). Define a `MemoryHooks` trait in `agentkeys-core`:

```rust
pub trait MemoryHooks {
    fn on_turn_started(&self, ctx: &TurnContext);
    fn on_turn_completed(&self, ctx: &TurnContext, summary: &str);
    fn on_tool_called(&self, ctx: &TurnContext, tool: &str, args: &Value);
    fn on_tool_result(&self, ctx: &TurnContext, tool: &str, ok: bool);
    fn on_error(&self, ctx: &TurnContext, err: &dyn std::error::Error);
}
```

The default implementation calls `memory.append(Episodic { ... })` for each event. Agent authors implement once at boot; per-turn append happens automatically. Removes the operational burden of "remembering to call append" that Mem0 and Letta both have.

**Cost.** Small — one trait, one default impl, ~50 lines in the SDK.

### 3.B — Caller-side secrets-scrub before encryption (from agentmemory)

**What it is.** agentmemory runs a regex/heuristic pass on every text payload before storing, stripping anything that looks like `sk-*`, `ghp_*`, AWS access keys, JWTs, etc. Replaces matches with `<REDACTED:api_key>`-style sentinels. Belt-and-suspenders alongside encryption-at-rest.

**AgentKeys mapping.** Add to SDK as a caller-side hook (NOT worker-side). Belongs in plan §6 as a new sub-section §6.3. AgentKeys already enforces encryption + cap-token gates + per-actor IAM, so this is strictly defense-in-depth — but the SDK NEVER having seen the secret is stronger than "the secret is encrypted at rest." Ship a reference regex set in `agentkeys-core::memory::scrub`; operators can extend.

**Cost.** ~100 lines of regex + a per-pattern unit test fixture.

**Why caller-side, not worker-side.** Worker can't reject a secret-containing line because it can't decrypt the payload before envelope-encryption — the worker only sees ciphertext. The scrub must happen client-side before encryption. Same shape as agentmemory's hook.

### 3.C — BM25 alongside cosine in `/v1/memory/search` (from agentmemory)

**What it is.** agentmemory's own published numbers from their COMPARISON.md:

| Configuration | LongMemEval-S R@5 |
|---|---|
| BM25-only (no embedding API available) | 86.2% |
| BM25 + Vector (full stack) | 95.2% |

**A 9-point R@5 lift from adding BM25 to vector search.** BM25 is a token-frequency keyword match; it's the standard text-search algorithm with zero external dependencies (~150 lines of Rust including IDF caching). Combined with cosine via reciprocal-rank fusion (RRF), they compose naturally.

**AgentKeys mapping.** Add to M2 deliverable. Worker computes both BM25 and cosine at search time, fuses via RRF, returns top-K. The plan currently says "cosine only"; **changing this is the single highest-leverage change** from this research.

```
score_final(line) = RRF(BM25_rank(line), Cosine_rank(line))
                  = 1/(k + BM25_rank) + 1/(k + Cosine_rank)    // k=60 typical
```

**Cost.** ~200 lines in the worker; one new test file (`crates/agentkeys-worker-memory/tests/search_bm25_hybrid.rs`); no new deps; small bench impact (BM25 over 100K lines ~10ms with IDF cached — already well within p99 budget).

**Why this is the headline borrow.** Pure-vector retrieval is the default in every system we surveyed, but agentmemory is the only one that publishes side-by-side BM25-only vs hybrid numbers on the same benchmark. The lift is real, measured, and cheap to ship.

### 3.D — `AGENTKEYS_MOCK_EMBEDDINGS=1` env var (from claw-rag-service)

**What it is.** claw-rag-service ships `CLAW_RAG_MOCK_PROVIDERS=1` for tests + CI. Set the env, get deterministic vectors derived from a hash of the line content — no embedding API call needed.

**AgentKeys mapping.** Add to M2 test plan. Without this, every integration test in plan §10 (`search_top_k.rs`, `search_invalidate.rs`, etc.) needs a live embedding API. With it, tests are hermetic + fast + deterministic.

```rust
fn mock_embedding(text: &str, dim: usize) -> Vec<f32> {
    let mut hasher = sha2::Sha256::new();
    hasher.update(text.as_bytes());
    let seed = hasher.finalize();
    let mut rng = ChaCha20Rng::from_seed(seed.into());
    (0..dim).map(|_| rng.gen_range(-1.0..1.0)).collect()
}
```

**Cost.** ~30 lines + an entry in the SDK README.

### 3.E — `agentkeys memory stats` CLI command (concept from both)

**What it is.** agentmemory ships `npx @agentmemory/agentmemory status` that shows token-savings estimate, line counts, etc. claw-rag-service exposes `GET /v1/stats` returning `{chunks, phase}`. Both prioritize operator observability.

**AgentKeys mapping.** Add to M3 deliverable:

```
$ agentkeys memory stats --actor 0xabc...
ACTOR: 0xabc...
─────────────────────────────────────────
Lines:        12,483 episodic / 240 semantic / 12 procedural
Index:        12,495 vectors × 1536 dim, 75 MB, built 2026-05-22 03:00Z
K3 epoch:     7 (3 lines under epoch 6, 0 lines under epoch 5)
Bucket:       acme-agentkeys-memory-prod (us-east-1)
Last append:  2026-05-22 14:23Z
Last search:  2026-05-22 14:25Z
─────────────────────────────────────────
```

**Cost.** ~150 lines in `agentkeys-cli` (LIST + manifest read + format). Cheap. Zero worker change — uses existing endpoints.

### 3.F — Single high-level SDK call: `memory.recall(query) -> Vec<Snippet>` (from claw-rag-service)

**What it is.** claw-rag-service's claw-analog binary exposes ONE tool named `retrieve_context` that wraps everything: query embedding + HTTP request + result parsing. The agent author touches one symbol.

**AgentKeys mapping.** Enrich M2 SDK helper spec. The plan currently describes the low-level wire-format endpoints (good). Add a high-level wrapper at the SDK layer:

```rust
impl MemoryClient {
    /// One-line memory retrieval. Embeds the query with the configured model,
    /// mints a Fetch cap, calls /v1/memory/search, decrypts results, returns
    /// plaintext snippets ready for prompt injection.
    pub async fn recall(&self, query: &str, k: usize) -> Result<Vec<Snippet>, RecallError>;
}
```

Plus a write-side companion:

```rust
impl MemoryClient {
    /// Embed-and-append in one call. Used by the lifecycle hooks (item 3.A).
    pub async fn remember(&self, event: MemoryEvent) -> Result<LineId, RememberError>;
}
```

**Cost.** ~200 lines in `agentkeys-core` SDK. Zero worker change.

---

## 4. What to skip

| Idea | Source | Why skip |
|---|---|---|
| iii engine substrate | agentmemory | Heavyweight runtime (KV + queue + pubsub + cron + stream + observability). Violates the "stateless Rust worker + S3" principle in plan §5.5.2 by an order of magnitude in operational surface. AgentKeys' substrate is S3 + chain; that IS the architectural decision. |
| 4-tier consolidation (working → episodic → semantic → procedural) | agentmemory | Requires LLM summarization to move lines up tiers. Violates our "worker never calls LLM" invariant #1. Could fit in the extractor sidecar (plan §6.2), but adds significant complexity for marginal R@5 gain over our existing 3-type taxonomy. Revisit if benchmark numbers demand it. |
| Ebbinghaus memory decay | agentmemory | Premature optimization. Recency-as-tie-break at search time (plan §10 positive test: "ties broken by recency") covers the common case. Add only if operator workload shows it matters. |
| Jaccard supersession (auto-dedupe-on-write) | agentmemory | SDK-side helper at best, not worker code. Our `op=invalidate, target_id=X` (plan §3.3) already supports explicit invalidation; auto-Jaccard is a UX nicety on top, not a structural change. Could be part of item 3.F's `remember()` wrapper if demanded. |
| 53 MCP tools | agentmemory | We have 7 worker endpoints (plan §4.1). The MCP wrapper is already deferred to v0.2 (plan §12 Q7); when it lands, it can expose granular tool surface as needed. Starting with 7 is the right scope. |
| Real-time viewer on port 3113 | agentmemory | Operator UX nicety; out of v0 scope. Belongs in a separate "observability" milestone if demand emerges. |
| Graph search (entity-relation queries) | agentmemory | Already deferred in plan §13. |
| blake3 chunk hashing | claw-rag-service | Different use case — they hash code-chunks for cross-file dedupe. Our line-per-object model uses ULIDs (already collision-resistant by construction). No need. |
| Agent-as-coordinator philosophy (Discord-as-interface, autonomous claws) | claw-code PHILOSOPHY.md | Different problem domain entirely. Nothing to borrow for the memory worker. |

---

## 5. Convergence — what we already have right

Three architectural decisions in our plan that both projects independently arrived at, confirming the shape:

1. **Separate process from the agent.** Both agentmemory (HTTP server on :3111) and claw-rag-service (HTTP server on :8787) run as standalone processes the agent calls into. Our worker is the same shape (cap-gated HTTPS server). The "memory lives in the agent process" model (LangMem in-process, MemGPT runtime-embedded) is the minority pattern.
2. **Embedding model as a swappable seam.** claw-rag-service uses any OpenAI-compatible endpoint (env-var config). agentmemory supports both `all-MiniLM-L6-v2` in-process AND API embeddings. We made the same call: caller provides the embedding vector via `query_vec_b64` (plan §4.2), worker doesn't care about the model. **All three independently picked this — strong signal it's correct.**
3. **Phase 1 brute-force → Phase 2 ANN as the growth path.** claw-rag-service explicitly labels their current implementation "Phase 1 SQLite linear" and plans Phase 2 via sqlite-vec or Qdrant in Docker. Our plan §5.5.3 has the same shape: brute-force cosine over packed-binary S3 file as v0; vector DB as operator-elected cache when scale demands. **Convergent thinking on the migration ladder.**

---

## 6. Bottom line

- **agentmemory is real but narrower than its marketing suggests.** Its engine is iii; its differentiator is the auto-capture hooks + the hybrid (BM25+vector+graph) search + the privacy-scrub. Three of the four highest-leverage borrows in §3 come from agentmemory specifically.
- **claw-code is not a memory system.** Its memory-adjacent crate (claw-rag-service) is a small reference implementation that's architecturally convergent with our plan. Borrow the env-var test pattern + the single-tool SDK shape; ignore the rest.
- **The biggest single change to consider:** item 3.C (BM25 alongside cosine in `/search`). 9-point R@5 lift, ~200 lines of code, zero new deps. If we ship one change from this research, it should be that one.

---

## 7. Reference list

**agentmemory:**
- Repo: [`rohitg00/agentmemory`](https://github.com/rohitg00/agentmemory) (commit at research time: tip of `main`, ~v0.9.21)
- Benchmark methodology: [`benchmark/COMPARISON.md`](https://github.com/rohitg00/agentmemory/blob/main/benchmark/COMPARISON.md)
- Roadmap: [`ROADMAP.md`](https://github.com/rohitg00/agentmemory/blob/main/ROADMAP.md)
- Engine: [`iii-hq/iii`](https://github.com/iii-hq/iii)
- MCP shim: [`packages/mcp/`](https://github.com/rohitg00/agentmemory/tree/main/packages/mcp)

**claw-code:**
- Repo: [`ultraworkers/claw-code`](https://github.com/ultraworkers/claw-code)
- Philosophy: [`PHILOSOPHY.md`](https://github.com/ultraworkers/claw-code/blob/main/PHILOSOPHY.md)
- RAG service: [`rust/crates/claw-rag-service/`](https://github.com/ultraworkers/claw-code/tree/main/rust/crates/claw-rag-service)
- RAG docs: [`docs/rag-web-ui.md`](https://github.com/ultraworkers/claw-code/blob/main/docs/rag-web-ui.md)

**LongMemEval benchmark** (the basis of agentmemory's "best on the market" claim):
- Paper: [arxiv.org/abs/2410.10813](https://arxiv.org/abs/2410.10813) (ICLR 2025)
