# OpenViking as the AgentKeys memory engine — operator runbook

> **Model B (plan [§6a](plan/agentkeys-memory-design.md)):** OpenViking **ranks**; AgentKeys keeps **storing** (K3-encrypted per-actor S3), **gating** (cap-token + on-chain scope + namespace + audit), and **delivering** (the `pre_llm_call` hook). OpenViking can re-order what gets injected but can **never widen** it — the gate bounds visibility. This runbook stands OpenViking up next to a wired AgentKeys agent and proves the **gated → OpenViking-ranked → injected** flow.

## Why this is NOT `memory.provider: openviking`

| | This runbook (AgentKeys-gated) | Plain Hermes `memory.provider: openviking` |
|---|---|---|
| Where memory lives | AgentKeys' **encrypted S3** (durable, per-actor) + OpenViking holds a ranking index | OpenViking only |
| Gate (cap / scope / namespace / audit) | **yes** — every read is gated | none |
| LLM-facing memory tools (`viking_search`, …) | **no** — the LLM never gets them | **yes** (5 tools) |
| What OpenViking does | **ranks** gate-authorized lines for the current turn | stores + serves + extracts |

The gated path keeps the founding privacy property: the LLM never sees the whole memory and never gets tools to enumerate it. OpenViking is a pluggable *engine*, swappable for Holographic / mem0 / a deterministic built-in.

## Prerequisites

1. **A working wired AgentKeys agent.** Run the wire demo first so memory already flows end-to-end:
   ```bash
   bash harness/phase1-wire-demo.sh --light     # self-contained, or --real for the live worker
   ```
   See [`operator-runbook-wire.md`](operator-runbook-wire.md). The sandbox is at `SANDBOX_URL` (default `http://localhost:8080`).
2. **Python 3.10+ and `pip`** (for `openviking`).
3. **A VLM + an embedding model** — OpenViking *requires* both (it is **not** deterministic). Pick one:
   - **Local Ollama (zero egress — recommended for the privacy thesis):** `ollama pull` a VLM + an embedding model; OpenViking points at `http://localhost:11434`. Heavier (model download) but no memory content leaves the box.
   - **A cloud VLM (fast):** OpenAI / Anthropic / DeepSeek / Gemini / Moonshot for the VLM, and OpenAI / Voyage / Jina for embeddings. ⚠️ Memory content is read by that model — **not** zero-egress. Note: OpenRouter is chat-only and has **no** embeddings endpoint, so it cannot be the embedding provider.

A sandbox shell helper used below:
```bash
SANDBOX_URL="${SANDBOX_URL:-http://localhost:8080}"
sbx() { curl -sS -X POST "$SANDBOX_URL/v1/shell/exec" -H 'content-type: application/json' \
          -d "$(jq -n --arg c "$1" '{command:$c}')" | jq -r '.data.output // ""'; }
```
(Running OpenViking on the host instead of the sandbox? Drop `sbx` and run the commands directly.)

## Step 1 — install OpenViking

```bash
sbx 'pip install --quiet openviking && python -c "import openviking; print(\"openviking installed\")"'
```

## Step 2 — configure OpenViking (VLM + embedding)

Use OpenViking's own setup wizard — it knows the exact provider strings and recommends local Ollama models; do **not** hand-write `~/.openviking/ov.conf` with guessed provider names:

```bash
sbx 'openviking-server init'      # interactive: pick VLM + embedding provider
```

The wizard writes `~/.openviking/ov.conf` with the shape (for reference; values are provider-specific):
```json
{ "vlm":       { "api_base": "...", "api_key": "...", "provider": "...", "model": "...", "max_concurrent": 8 },
  "embedding": { "dense": { "api_base": "...", "api_key": "...", "provider": "...", "dimension": 1024, "model": "..." }, "max_concurrent": 4 } }
```
Override the config path with `OPENVIKING_CONFIG_FILE=~/.openviking/ov.conf` if needed.

## Step 3 — start the server and confirm health

```bash
sbx 'nohup openviking-server >~/openviking.log 2>&1 & sleep 3; curl -fsS http://localhost:1933/health && echo " — openviking up"'
```
`GET /health` returning 200 means the server (and its VLM/embedding config) is live. If it fails, read `~/openviking.log` — almost always a VLM/embedding misconfiguration from step 2.

## Step 4 — mirror your gate-authorized memory into OpenViking's index

OpenViking's `search/find` ranks what is in **its** index, so mirror the lines AgentKeys already holds into it. The durable, encrypted copy stays in AgentKeys' S3 — this is OpenViking's ranking index only, on operator infra.

```bash
# one viking:// entry per memory line, under a per-namespace path
OV=http://localhost:1933
mirror() {  # mirror "<namespace>" "<line text>" "<n>"
  sbx "curl -fsS -X POST $OV/api/v1/content/write -H 'content-type: application/json' \
        -d \"\$(jq -n --arg u 'viking://user/memories/$1/$3' --arg c '$2' '{uri:\$u, content:\$c, mode:\"create\"}')\""
}
mirror travel "Booked Chengdu flight CA4515 on Apr 12."        0
mirror travel "Peanut allergy — note for inflight meals."      1
mirror travel "Hotel in Yulin district near hotpot street."    2
```
> For production, mirror **on write** (when `agentkeys memory put` runs) rather than ad hoc here — see plan §6a "remaining: write-path mirroring."

## Step 5 — wire AgentKeys to use OpenViking as the engine

Re-run `wire` with the OpenViking flags. This bakes `AGENTKEYS_MEMORY_ENGINE=openviking` **and** `OPENVIKING_ENDPOINT` into the generated `pre_llm_call` hook, so the wired hook ranks via OpenViking:

```bash
sbx "agentkeys wire hermes \
  --actor-omni \$AGENTKEYS_ACTOR_OMNI --operator-omni \$AGENTKEYS_OPERATOR_OMNI \
  --namespaces travel \
  --memory-engine openviking \
  --openviking-endpoint http://localhost:1933 \
  --mcp-url http://localhost:18088/mcp --vendor-token demo-tok"
```
Confirm the hook baked the engine + endpoint:
```bash
sbx "grep -E 'OPENVIKING_ENDPOINT|AGENTKEYS_MEMORY_ENGINE' ~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh"
```
Leave `memory.provider` **unset** in `~/.hermes/config.yaml` — the AgentKeys hook stays the sole memory delivery (OpenViking is the engine, not a Hermes provider).

## Step 6 — test: gated → OpenViking-ranked → injected

OpenViking is query-driven, so feed the wired hook a turn (the hook reads the query from the host payload). The injected block is OpenViking-ranked **and** gate-bounded:

```bash
sbx "printf '%s' '{\"query\":\"what about my peanut allergy?\"}' | bash ~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh"
```
Expected — the peanut-allergy line ranked first (OpenViking), and only lines the gate authorized:
```json
{"context":"## Memory: travel\nPeanut allergy — note for inflight meals.\n..."}
```
Then the real chat (Phase 4 of the wire demo): ask the Hermes agent about the trip and watch it answer from the OpenViking-ranked, gate-bounded memory — without ever getting an OpenViking tool.

## Step 7 — verify the safety + privacy properties

| Property | How to check | Expected |
|---|---|---|
| **Gate bounds visibility** | mirror a line into OpenViking under a namespace the cap does NOT authorize, then query | it is **never** injected — `rank_gate_bounded` only returns lines from the gate-authorized set |
| **OpenViking is not load-bearing** | stop the server (`sbx 'pkill -f openviking-server'`), re-run step 6 | still injects — falls back to the deterministic lexical engine (recency/relevance), never errors |
| **LLM gets no memory tools** | `sbx "hermes hooks doctor"` + inspect the model's tool list | only the 3 AgentKeys hooks; **no** `viking_search` / `viking_read` / etc. |
| **Durable copy stays encrypted** | the S3 object `bots/<actor>/memory/memory:travel.enc` | unchanged; OpenViking holds only its `viking://` index |

## Step 8 — teardown

```bash
sbx 'pkill -f openviking-server 2>/dev/null; true'
# revert to the deterministic engine:
sbx "agentkeys wire hermes --namespaces travel --mcp-url http://localhost:18088/mcp --vendor-token demo-tok"   # no --memory-engine ⇒ passthrough
```

## Automated path

`bash harness/phase1-wire-demo.sh --openviking` runs steps 4–7 automatically **when `openviking-server` is already reachable at `OPENVIKING_ENDPOINT`** (it does not install/configure OpenViking — that's steps 1–3 here, because the VLM/embedding choice is operator- and provider-specific). If the server isn't up, the phase skips with a pointer back to this runbook.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `/health` fails | VLM/embedding misconfigured | re-run `openviking-server init`; read `~/openviking.log` |
| step 6 injects the *whole* namespace, unranked | hook fell back (no query, or `OPENVIKING_ENDPOINT` not baked) | confirm step 5 baked the env; ensure the payload has a `query` field |
| step 6 injects nothing new vs. the deterministic engine | OpenViking index empty | re-run step 4 (mirror) — `search/find` ranks only what's indexed |
| `content/write` 4xx | `mode:"create"` on an existing URI | use a fresh `viking://` path or OpenViking's update mode |
| hook hangs on a manual call | reading an open stdin | the hook is `is_terminal()`-guarded; always **pipe** the payload (`printf … | …`) or use `</dev/null` |

## References
- Plan: [`plan/agentkeys-memory-design.md`](plan/agentkeys-memory-design.md) §6a (engine seam, spiked OpenViking API, model-B rationale).
- Adapter: `crates/agentkeys-core/src/openviking.rs` (gate-bounded ranking). Hook: `crates/agentkeys-cli/src/hook.rs` (query-aware `memory-inject`).
- OpenViking: <https://github.com/volcengine/OpenViking>. Hermes plugin (API source): <https://github.com/NousResearch/hermes-agent/tree/main/plugins/memory/openviking>.
