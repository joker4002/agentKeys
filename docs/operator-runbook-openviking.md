# OpenViking as the AgentKeys memory engine — operator runbook

> **Model B (plan [§6a](plan/agentkeys-memory-design.md)):** OpenViking **ranks**; AgentKeys keeps **storing** (K3-encrypted per-actor S3), **gating** (cap-token + on-chain scope + namespace + audit), and **delivering** (the `pre_llm_call` hook). OpenViking can re-order what gets injected but can **never widen** it — the gate bounds visibility. This runbook stands OpenViking up next to a wired AgentKeys agent and proves the **gated → OpenViking-ranked → injected** flow.

## Why this is NOT `memory.provider: openviking`

| | This runbook (AgentKeys-gated) | Plain Hermes `memory.provider: openviking` |
|---|---|---|
| Where memory lives | AgentKeys' **encrypted S3** (durable, per-actor) + OpenViking holds a ranking index | OpenViking only |
| Gate (cap / scope / namespace / audit) | **yes** — every read is gated | none |
| LLM-facing memory tools (`viking_search`, …) | **no** — the LLM never gets them | **yes** (5 tools) |
| What OpenViking does | **ranks** gate-authorized lines for the current turn | stores + serves + extracts |

> ⛔ **Do NOT run `hermes memory setup`.** The OpenViking docs tell you to — but that sets `memory.provider: openviking`, which wires OpenViking as a **Hermes provider**: it hands the LLM the 5 `viking_*` tools and makes OpenViking the store, **bypassing our gate** (the ungated "Model A" we rejected). In our gated model the Hermes-side wiring is **`agentkeys wire hermes --memory-engine openviking …`** (Step 6) — that's the replacement for `hermes memory setup`.

OpenViking is a pluggable *engine*, swappable for Holographic / mem0 / a deterministic built-in. If you don't need semantic search, `MEMORY_ENGINE=lexical` gives gated, query-aware ranking with **zero models to deploy** — skip this whole runbook.

## Prerequisites

1. **A working wired AgentKeys agent.** Run the wire demo first so memory already flows end-to-end:
   ```bash
   bash harness/phase1-wire-demo.sh --light     # self-contained, or --real for the live worker
   ```
   See [`operator-runbook-wire.md`](operator-runbook-wire.md).
2. **Python 3.10+ and `pip`** (already present in the aiosandbox).
3. **An embedding model** (small, local) — OpenViking does *semantic* search, which needs embeddings. The `init` wizard (Step 2) downloads a ~24 MB BGE model on CPU. **A VLM is optional** for our use (see Step 2).

### Run everything below INSIDE the sandbox
`openviking-server init` is an **interactive wizard** and the server is long-running, so shell into the sandbox and run the commands directly (do **not** use the one-shot `/v1/shell/exec` API / the `sbx` helper from the wire runbook):
```bash
docker exec -it <sandbox-container> bash      # you are now gem@… inside the sandbox
```

## Step 1 — install OpenViking
```bash
pip install --quiet openviking && python -c "import openviking; print('openviking installed')"
```

## Step 2 — configure OpenViking (`openviking-server init`)
```bash
openviking-server init
```
Wizard answers for **our** use:
- **Setup mode** → `2` (local embedding via llama.cpp, CPU, no GPU) — or `1` Cloud API only if you have an OpenAI/VolcEngine key. Avoid Ollama in the sandbox (multi-GB pulls).
- **Embedding model** → the offered BGE small model (~24 MB). *(It may be a `-zh` build; fine for a test. If an English `-en` variant is offered and your memory is English, prefer it.)*
- **VLM** → `3` **Skip VLM (embedding only)**. We only use OpenViking's **semantic search** (`search/find`), which is pure embeddings — the VLM is OpenViking's *extraction/tiering* engine, which we don't need (AgentKeys supplies the gate-authorized lines). If a later write insists on a VLM, re-run `init` → `2` Cloud API and point it at your DeepSeek/OpenRouter (`provider openai`, `base_url https://openrouter.ai/api/v1`).

## Step 3 — start the server and confirm health
```bash
nohup openviking-server >~/openviking.log 2>&1 &
sleep 3; curl -fsS http://localhost:1933/health && echo " — openviking up"
```
If `/health` fails, read `~/openviking.log` (usually an embedding/VLM config issue from Step 2).

## Step 4 — load a REAL corpus and SEE semantic search work (direct eval)

A 3-line database can't show semantic retrieval. Load the diverse sample corpus ([`../harness/fixtures/sample-memory.md`](../harness/fixtures/sample-memory.md), ~36 facts across health / travel / family / work / finance) and query it directly.

**Get the corpus into the sandbox** — from your **laptop** (repo root):
```bash
curl -sS -X POST "${SANDBOX_URL:-http://localhost:8080}/v1/file/upload" \
  -F "file=@harness/fixtures/sample-memory.md" -F "path=/home/gem/sample-memory.md"
```
**Load it** (inside the sandbox) — one `viking://` entry per fact, skipping `#` headers:
```bash
OV=http://localhost:1933; n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  curl -fsS -X POST "$OV/api/v1/content/write" -H 'content-type: application/json' \
    -d "$(jq -n --arg u "viking://user/memories/sample/$n" --arg c "$line" \
            '{uri:$u, content:$c, mode:"create"}')" >/dev/null
  n=$((n+1))
done < ~/sample-memory.md
echo "loaded $n facts"
```
**Query it semantically** — note the query words don't appear in the matches:
```bash
curl -fsS -X POST "$OV/api/v1/search/find" -H 'content-type: application/json' \
  -d "$(jq -n '{query:"what are my dietary restrictions?", top_k:5}')" \
  | jq '.result.results[] | {score, content}'
```
Expected: the **peanut / lactose / vegetarian** lines rank top — none contain the word "dietary." That's semantic search earning its keep. Try also `"where have I travelled?"` (→ Chengdu / Tokyo / Lisbon) and `"important family dates"` (→ birthday / anniversary). This is a **direct** OpenViking eval — it does not go through the AgentKeys gate (next step).

## Step 5 — the gated path: mirror gate-authorized lines

For the *gated* flow, OpenViking may only rank lines AgentKeys authorized. So the lines in OpenViking must match what `memory.get` returns for the namespace (the gate then bounds the result to exactly that set). Mirror the lines already in the agent's memory namespace:
```bash
OV=http://localhost:1933
mirror() {  # mirror <namespace> "<line text>" <n>
  curl -fsS -X POST "$OV/api/v1/content/write" -H 'content-type: application/json' \
    -d "$(jq -n --arg u "viking://user/memories/$1/$3" --arg c "$2" \
            '{uri:$u, content:$c, mode:"create"}')"
}
mirror travel "Booked Chengdu flight CA4515 on Apr 12." 0
mirror travel "Peanut allergy — note for inflight meals." 1
mirror travel "Hotel in Yulin district near hotpot street." 2
```
> For production, mirror **on write** (when `agentkeys memory put` runs), not ad hoc — see plan §6a "remaining: write-path mirroring."

## Step 6 — wire AgentKeys to use OpenViking as the engine

This is the replacement for `hermes memory setup` (which we do **not** run — see the warning above). It bakes `AGENTKEYS_MEMORY_ENGINE=openviking` **and** `OPENVIKING_ENDPOINT` into the `pre_llm_call` hook:
```bash
agentkeys wire hermes \
  --actor-omni "$AGENTKEYS_ACTOR_OMNI" --operator-omni "$AGENTKEYS_OPERATOR_OMNI" \
  --namespaces travel \
  --memory-engine openviking --openviking-endpoint http://localhost:1933 \
  --mcp-url http://localhost:18088/mcp --vendor-token demo-tok
grep -E 'OPENVIKING_ENDPOINT|AGENTKEYS_MEMORY_ENGINE' ~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh
```
Leave `memory.provider` **unset** in `~/.hermes/config.yaml` — the AgentKeys hook stays the sole memory delivery.

## Step 7 — test: gated → OpenViking-ranked → injected
OpenViking is query-driven, so feed the wired hook a turn (it reads the query from the host payload). The injected block is OpenViking-ranked **and** gate-bounded:
```bash
printf '%s' '{"query":"what about my peanut allergy?"}' \
  | bash ~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh
```
Expected — the peanut line ranked first, only gate-authorized lines:
```json
{"context":"## Memory: travel\nPeanut allergy — note for inflight meals.\n..."}
```
Then the real chat (Phase 4 of the wire demo): ask the agent about the trip and watch it answer from the OpenViking-ranked, gate-bounded memory — without ever getting an OpenViking tool.

## Step 8 — verify the safety + privacy properties

| Property | How to check | Expected |
|---|---|---|
| **Gate bounds visibility** | mirror a line into OpenViking under a namespace the cap does NOT authorize, then query Step 7 | it is **never** injected — `rank_gate_bounded` only returns gate-authorized lines |
| **OpenViking is not load-bearing** | `pkill -f openviking-server`, re-run Step 7 | still injects — falls back to the deterministic lexical engine, never errors |
| **LLM gets no memory tools** | `hermes hooks doctor` + inspect the tool list | only the 3 AgentKeys hooks; **no** `viking_*` |
| **Durable copy stays encrypted** | the S3 object `bots/<actor>/memory/memory:travel.enc` | unchanged; OpenViking holds only its `viking://` index |

## Step 9 — teardown
```bash
pkill -f openviking-server 2>/dev/null; true
agentkeys wire hermes --namespaces travel \
  --mcp-url http://localhost:18088/mcp --vendor-token demo-tok   # no --memory-engine ⇒ deterministic
```

## Automated path
`bash harness/phase1-wire-demo.sh --openviking` runs the AgentKeys-side checks (Steps 6–7) automatically **when `openviking-server` is already reachable** at `OPENVIKING_ENDPOINT`. It does **not** install/configure OpenViking (Steps 1–3) or load a corpus (Steps 4–5) — those are operator- and provider-specific. If the server isn't up, the phase skips with a pointer back here.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `command not found: sbx` | you are inside the sandbox; `sbx` is a laptop-only helper | drop `sbx`, run the command directly (this runbook already does) |
| `/health` fails | embedding/VLM misconfigured | re-run `openviking-server init`; read `~/openviking.log` |
| `search/find` returns nothing | index empty | run Step 4/5 (load/mirror) — it ranks only what's indexed |
| Step 7 injects the *whole* namespace, unranked | hook fell back (no query, or `OPENVIKING_ENDPOINT` not baked) | confirm Step 6 baked the env; ensure the payload has a `query` field |
| `content/write` 4xx | `mode:"create"` on an existing URI | use a fresh `viking://` path or OpenViking's update mode |
| hook hangs on a manual call | reading an open stdin | the hook is `is_terminal()`-guarded; always **pipe** the payload (`printf … \| …`) |

## References
- Plan: [`plan/agentkeys-memory-design.md`](plan/agentkeys-memory-design.md) §6a (engine seam, spiked OpenViking API, model-B rationale).
- Sample corpus: [`../harness/fixtures/sample-memory.md`](../harness/fixtures/sample-memory.md).
- Adapter: `crates/agentkeys-core/src/openviking.rs` (gate-bounded ranking). Hook: `crates/agentkeys-cli/src/hook.rs` (query-aware `memory-inject`).
- OpenViking: <https://github.com/volcengine/OpenViking>. Hermes plugin (API source): <https://github.com/NousResearch/hermes-agent/tree/main/plugins/memory/openviking>.
