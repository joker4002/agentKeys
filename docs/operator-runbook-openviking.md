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
>
> **Already ran it? Undo (the provider is just a config key — this does NOT touch the AgentKeys `pre_llm_call` hook, which lives in a separate `# >>> agentkeys wire` managed block):**
> ```bash
> # inspect what it set
> hermes config get memory.provider 2>/dev/null            # → openviking
> sed -n '/^memory:/,/^[^[:space:]]/p' ~/.hermes/config.yaml   # the memory: block
> grep -nE 'OPENVIKING' ~/.hermes/.env 2>/dev/null
> # turn it off — try the hermes way first, else edit the files:
> hermes memory setup        # pick "none"/"disable"/"built-in" if offered
> #   else: delete the `memory:`/`provider: openviking` block from ~/.hermes/config.yaml,
> #         and remove OPENVIKING_ENDPOINT / OPENVIKING_API_KEY from ~/.hermes/.env
> hermes config get memory.provider     # verify empty/none
> ```
> Keep `openviking-server` running and keep (or run) `agentkeys wire … --memory-engine openviking` — our gated hook still uses OpenViking; you've only removed the ungated Hermes provider.

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
**Load it** (inside the sandbox). The write URI **must** be
`viking://user/<user>/memories/<subdir>/<name>.md` — the `<user>` segment **and**
the `.md` extension are required, or the server returns **HTTP 400**. First confirm
one write (show the response, don't hide it), then load the corpus idempotently:

```bash
OV=http://localhost:1933; OVUSER=default     # OVUSER = your OPENVIKING_USER (default: "default")

# sanity: ONE write, SHOW the response (no -f/-s hiding the error)
curl -sS -X POST "$OV/api/v1/content/write" -H 'content-type: application/json' \
  -d "$(jq -n --arg u "viking://user/$OVUSER/memories/sample/mem_000.md" \
              --arg c "Severely allergic to peanuts." '{uri:$u,content:$c,mode:"create"}')" | jq .
# expect: {"result":{"written_bytes":...}}   — if you see an error, paste it.

# load the corpus — counts ACTUAL successes; re-runs are idempotent
ok=0; n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  uri="viking://user/$OVUSER/memories/sample/mem_$(printf '%03d' "$n").md"
  resp="$(curl -sS -X POST "$OV/api/v1/content/write" -H 'content-type: application/json' \
    -d "$(jq -n --arg u "$uri" --arg c "$line" '{uri:$u,content:$c,mode:"create"}')")"
  if echo "$resp" | jq -e '.result' >/dev/null 2>&1; then ok=$((ok+1))
  elif echo "$resp" | grep -qi exist; then ok=$((ok+1))     # idempotent: already loaded, no dup
  else echo "  FAIL [$n]: $(echo "$resp" | jq -rc '.error // .' 2>/dev/null | cut -c1-90)"; fi
  n=$((n+1))
done < ~/sample-memory.md
echo "loaded/present $ok of $n facts"
```
> **Idempotency:** the filename is **deterministic** (`mem_000.md`, `mem_001.md`, …), so a re-run targets the *same* URIs — `mode:"create"` then reports "exists", which the loader counts as already-loaded (no duplicates). To force a clean reload, change the subdir (e.g. `sample2`).
**Query it semantically.** Results live under **`result.memories`** (also `result.resources` / `result.skills`); each item has `score` / `uri` / `abstract`:
```bash
# see the raw shape the first time:
curl -sS -X POST "$OV/api/v1/search/find" -H 'content-type: application/json' \
  -d "$(jq -n '{query:"what are my dietary restrictions?", top_k:5}')" | jq .

# the ranked memories:
curl -sS -X POST "$OV/api/v1/search/find" -H 'content-type: application/json' \
  -d "$(jq -n '{query:"what are my dietary restrictions?", top_k:5}')" \
  | jq '.result.memories[]? | {score, uri, abstract}'
```
Expected: the **peanut / lactose / vegetarian** entries rank top — none contain the word "dietary." That's semantic search earning its keep. Try `"where have I travelled?"` (→ Chengdu / Tokyo / Lisbon) and `"important family dates"` (→ birthday / anniversary). This is a **direct** OpenViking eval — it does not go through the AgentKeys gate (next step).

> **`abstract` blank?** If you picked **Skip VLM** at setup, OpenViking still embeds + ranks (scores + URIs are correct) but has no model to generate the L0 `abstract`, so it can be empty. The ranking is unaffected — read the verbatim line by URI:
> ```bash
> top=$(curl -sS -X POST "$OV/api/v1/search/find" -H 'content-type: application/json' \
>   -d "$(jq -n '{query:"dietary restrictions", top_k:1}')" | jq -r '.result.memories[0].uri')
> curl -sS -X POST "$OV/api/v1/content/read" -H 'content-type: application/json' \
>   -d "$(jq -n --arg u "$top" '{uri:$u}')" | jq .
> ```

## Step 5 — the gated path: mirror gate-authorized lines

For the *gated* flow, OpenViking may only rank lines AgentKeys authorized. So the lines in OpenViking must match what `memory.get` returns for the namespace (the gate then bounds the result to exactly that set). Mirror the lines already in the agent's memory namespace:
```bash
OV=http://localhost:1933; OVUSER=default
mirror() {  # mirror <namespace> "<line text>" <n>
  local uri="viking://user/$OVUSER/memories/$1/mem_$3.md"
  curl -sS -X POST "$OV/api/v1/content/write" -H 'content-type: application/json' \
    -d "$(jq -n --arg u "$uri" --arg c "$2" '{uri:$u,content:$c,mode:"create"}')" \
    | jq -rc '.result // .error // .'
}
mirror travel "Booked Chengdu flight CA4515 on Apr 12." 0
mirror travel "Peanut allergy — note for inflight meals." 1
mirror travel "Hotel in Yulin district near hotpot street." 2
```
> The gate matches OpenViking hits back to authorized lines by **text**, not URI — so the subdir/filename here are free; only the `content` must equal the namespace line.
> For production, mirror **on write** (when `agentkeys memory put` runs), not ad hoc — see plan §6a "remaining: write-path mirroring."

## Step 6 — wire AgentKeys to use OpenViking as the engine

This is the replacement for `hermes memory setup` (which we do **not** run — see the warning above). It bakes `AGENTKEYS_MEMORY_ENGINE=openviking` **and** `OPENVIKING_ENDPOINT` into the `pre_llm_call` hook — for the **same agent identity** the [Step-0 prerequisite](#prerequisites) (`harness/phase1-wire-demo.sh`) already wired.

### 6a — inherit the agent's omni identity from the wire demo
`agentkeys wire` reads the actor/operator omni, MCP URL, vendor token, and session bearer from the env (`AGENTKEYS_ACTOR_OMNI`, `AGENTKEYS_OPERATOR_OMNI`, `AGENTKEYS_MCP_URL`, `AGENTKEYS_MCP_VENDOR_TOKEN`, `AGENTKEYS_SESSION_BEARER`) — and the wire demo **baked all five into the hook header**. Recover them so this re-wire keeps the *same* agent (re-typing the 64-hex omnis is error-prone, and passing `--actor-omni ""` from an unset var silently wires an **empty** actor):
```bash
hook=~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh
[ -f "$hook" ] || echo "no wired hook yet — run the Step-0 prerequisite (harness/phase1-wire-demo.sh) first"
eval "$(grep -E '^export AGENTKEYS_(ACTOR_OMNI|OPERATOR_OMNI|MCP_URL|MCP_VENDOR_TOKEN|SESSION_BEARER)=' "$hook" 2>/dev/null)"
: "${AGENTKEYS_ACTOR_OMNI:?unset — set it from the wire demo (see the per-mode note below)}"
echo "actor=$AGENTKEYS_ACTOR_OMNI"
echo "operator=$AGENTKEYS_OPERATOR_OMNI"
echo "mcp=$AGENTKEYS_MCP_URL  vendor=$AGENTKEYS_MCP_VENDOR_TOKEN  bearer=${AGENTKEYS_SESSION_BEARER:+set}"
```
> **Where the omnis come from** (6a recovers them automatically — this is for setting them by hand):
> - **`--light`** (this runbook's default): the fixed in-memory demo identity (`AGENTKEYS_ACTOR_OMNI=0xa0c7…`, `AGENTKEYS_OPERATOR_OMNI=0x07e8…`). Canonical source: [`crates/agentkeys-mcp-server/src/backend/in_memory.rs`](../crates/agentkeys-mcp-server/src/backend/in_memory.rs) lines 33-35; `agentkeys wire` falls back to exactly these when the env is unset, so light mode works even if 6a found nothing — but only if you **omit** the flags (don't pass `--actor-omni ""`).
> - **`--real`**: the per-agent omnis the wire demo resolves in **Phase P** and prints in the `heima-agent-create.sh` `==> Inputs` block, e.g.
>   ```
>   operator_omni    = 0x941cb1c3260518bbf40eac7d02663517fc7cff304d9b03e80d2cc54126c6bef2
>   actor_omni       = 0x18e49c6020dfef1bd1c973bb001b5fb95fa735c41c3a23efae2b22b6447c5ed8
>   ```
>   The operator omni derives from your master key; the actor omni is the HDKD child minted at pairing. The wire step bakes both into the hook, so 6a recovers them — no copy-paste. (The session bearer is a JWT that **expires**; if a real-mode re-wire later fails auth, re-run `harness/phase1-wire-demo.sh --real` to refresh it.)

### 6b — wire (adds OpenViking; keeps the 6a identity)
```bash
agentkeys wire hermes \
  --actor-omni "$AGENTKEYS_ACTOR_OMNI" --operator-omni "$AGENTKEYS_OPERATOR_OMNI" \
  --namespaces travel \
  --memory-engine openviking --openviking-endpoint http://localhost:1933 \
  --mcp-url "$AGENTKEYS_MCP_URL" --vendor-token "$AGENTKEYS_MCP_VENDOR_TOKEN"
grep -E 'OPENVIKING_ENDPOINT|AGENTKEYS_MEMORY_ENGINE|AGENTKEYS_ACTOR_OMNI' ~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh
```
Leave `memory.provider` **unset** in `~/.hermes/config.yaml` — the AgentKeys hook stays the sole memory delivery.

## Step 7 — test: gated → OpenViking-ranked → injected (STRICT, no fallback)
OpenViking is query-driven, so feed the wired hook a turn (it reads the query from the host payload). **A plain non-empty injection does NOT prove OpenViking ranked anything** — the hook falls back to the deterministic lexical engine on any OpenViking error/miss, and with an unbounded budget that fallback returns the whole namespace. To prove the *OpenViking* path specifically, disable the fallback with `AGENTKEYS_MEMORY_ENGINE_STRICT=1` (test-only — production wiring never sets it, so OpenViking stays non-load-bearing there):
```bash
# 1) OpenViking itself ranks the query (direct, gate-free) — expect >= 1 hit:
curl -sS -X POST "${OPENVIKING_ENDPOINT:-http://localhost:1933}/api/v1/search/find" \
  -H 'content-type: application/json' \
  -d '{"query":"what about my peanut allergy?","top_k":5}' \
  | jq '[.result.memories[]?, .result.results[]?, .result.skills[]?] | length'

# 2) STRICT hook run — fallback DISABLED, so a non-empty injection can ONLY
#    have come from OpenViking's gate-matched ranking:
printf '%s' '{"query":"what about my peanut allergy?"}' \
  | AGENTKEYS_MEMORY_ENGINE_STRICT=1 bash ~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh
```
Expected — the peanut line ranked first, only gate-authorized lines; because the fallback is off, this output **is** the proof OpenViking ranked it:
```json
{"context":"## Memory: travel\nPeanut allergy — note for inflight meals.\n..."}
```
An **empty** `{}` in strict mode means OpenViking produced no gate-matched ranking (server down, no hit, or its mirrored content does not text-match the namespace lines) — fix that, rather than reading a *non-strict* green as success. Then the real chat (Phase 4 of the wire demo): ask the agent about the trip and watch it answer from the OpenViking-ranked, gate-bounded memory — without ever getting an OpenViking tool.

## Step 8 — verify the safety + privacy properties

| Property | How to check | Expected |
|---|---|---|
| **Gate bounds visibility** | mirror a line into OpenViking under a namespace the cap does NOT authorize, then query Step 7 | it is **never** injected — `rank_gate_bounded` only returns gate-authorized lines |
| **OpenViking is not load-bearing** | `pkill -f openviking-server`, then re-run the hook **without** strict mode (plain `printf … \| bash …`, no `AGENTKEYS_MEMORY_ENGINE_STRICT`) — *not* Step 7, which is strict and would correctly fail | still injects — falls back to the deterministic lexical engine, never errors |
| **LLM gets no memory tools** | `hermes hooks doctor` + inspect the tool list | only the 3 AgentKeys hooks; **no** `viking_*` |
| **Durable copy stays encrypted** | the S3 object `bots/<actor>/memory/memory:travel.enc` | unchanged; OpenViking holds only its `viking://` index |

## Step 9 — teardown
Revert to the deterministic engine **for the same agent**. The block re-recovers the identity from the hook (same as [6a](#6a--inherit-the-agents-omni-identity-from-the-wire-demo)) so it works in a fresh shell too — without it the omni env would be unset and the re-wire would drop the hook back to the demo actor:
```bash
pkill -f openviking-server 2>/dev/null; true
hook=~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh
eval "$(grep -E '^export AGENTKEYS_(ACTOR_OMNI|OPERATOR_OMNI|MCP_URL|MCP_VENDOR_TOKEN|SESSION_BEARER)=' "$hook" 2>/dev/null)"
agentkeys wire hermes \
  --actor-omni "$AGENTKEYS_ACTOR_OMNI" --operator-omni "$AGENTKEYS_OPERATOR_OMNI" \
  --namespaces travel \
  --mcp-url "$AGENTKEYS_MCP_URL" --vendor-token "$AGENTKEYS_MCP_VENDOR_TOKEN"   # no --memory-engine ⇒ deterministic
```

## Automated path

Two scripts automate different slices — pick by where you run them.

**Sandbox-side, all-in-one (recommended): [`harness/openviking-sandbox-setup.sh`](../harness/openviking-sandbox-setup.sh).** The idempotent, scripted form of **Steps 2–7**, run **inside the sandbox**: server init (`--init`, first time), start + health, corpus load, mirror, identity recovery (6a), re-wire (6b), and the gated injection test (7). Self-contained — the sample corpus is embedded, so nothing else to upload. It **assumes** the operator/Mac side is done (the agent is already wired — it recovers the omni identity from the hook) and OpenViking is pip-installed (Step 1).
```bash
# laptop (repo root) — upload the script into the sandbox:
curl -sS -X POST "${SANDBOX_URL:-http://localhost:8080}/v1/file/upload" \
  -F "file=@harness/openviking-sandbox-setup.sh" -F "path=/home/gem/openviking-sandbox-setup.sh"
# sandbox (docker exec -it <container> bash):
bash ~/openviking-sandbox-setup.sh            # init already done before
bash ~/openviking-sandbox-setup.sh --init     # fresh sandbox: run the init wizard too
#   --reload force a fresh corpus load · --verify prove the fallback · --no-test stop after wiring
```
Re-run it any time — every step pre-checks and short-circuits (`ok` / `skip` / `fail`).

**Phase 7 proves the OpenViking path, not just a non-empty injection.** It (7a) asserts OpenViking's `/search/find` ranks `$TEST_QUERY` directly, then (7b) runs the hook with the lexical fallback **disabled** (`AGENTKEYS_MEMORY_ENGINE_STRICT=1`) so a non-empty injection can *only* come from OpenViking — never the fallback masquerading as it. An empty `$NS`, a down server, or a gate-match miss makes Phase 7 **fail red** (not a vacuous green). Seed the namespace first — the [Prerequisites](#prerequisites) wire demo (`--real --webauthn` grants `memory:travel` **and** seeds it) or a direct `memory.put` — or pass `--no-test` to stand up + wire without the proof. (`--verify`'s Phase 8 is the deliberately *non-strict* complement: with OpenViking killed the lexical fallback must still inject — proving OpenViking is never load-bearing — so empty there is a fallback regression and also fails red.)

**Laptop-driven harness: `bash harness/phase1-wire-demo.sh --openviking`** runs the AgentKeys-side checks (Steps 6–7) **when `openviking-server` is already reachable** at `OPENVIKING_ENDPOINT`. It does **not** install/configure OpenViking (Steps 1–3) or load a corpus (Steps 4–5). If the server isn't up, the phase skips with a pointer back here.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `command not found: sbx` | you are inside the sandbox; `sbx` is a laptop-only helper | drop `sbx`, run the command directly (this runbook already does) |
| `/health` fails | embedding/VLM misconfigured | re-run `openviking-server init`; read `~/openviking.log` |
| `search/find` returns nothing | index empty | run Step 4/5 (load/mirror) — it ranks only what's indexed |
| Step 7 injects the *whole* namespace, unranked | hook fell back (no query, or `OPENVIKING_ENDPOINT` not baked) | confirm Step 6 baked the env; ensure the payload has a `query` field |
| `agentkeys wire --memory-engine openviking` errors *"needs an endpoint"* | wire refuses to bake `AGENTKEYS_MEMORY_ENGINE=openviking` without an endpoint — otherwise the runtime hook silently falls back to lexical (defeating the engine you asked for) | pass `--openviking-endpoint http://<host>:1933` (Step 6b already does) or `export OPENVIKING_ENDPOINT` before wiring |
| Step 6 bakes an empty `AGENTKEYS_ACTOR_OMNI=''` (or the wrong actor) into the hook | you ran the wire command (6b) before exporting the omni env (6a) — `--actor-omni "$UNSET"` passes an empty string, overriding `wire`'s demo fallback | run **Step 6a** first: it recovers actor/operator omni + MCP URL + vendor token from the hook the [Step-0](#prerequisites) wire demo baked. `--light` falls back to the `in_memory.rs` demo omnis only when you **omit** the flags entirely |
| `memory.get(<ns>) failed … cap_mint failed … service_not_in_scope` → empty injection | the agent's on-chain scope grants bare `memory`, but the cap requests `memory:<ns>` (issue #147; `keccak("memory") ≠ keccak("memory:<ns>")`, arch.md §896) | grant the **namespace-qualified** service: re-run `bash harness/phase1-wire-demo.sh --real --webauthn` (now grants `memory:<ns>`), or directly `bash scripts/heima-scope-set.sh --webauthn --agent <label> --services memory:<ns>` (e.g. `memory:travel`) |
| `content/write` HTTP 400 on every write | malformed URI — it **must** be `viking://user/<user>/memories/<subdir>/<name>.md` (the `<user>` segment + `.md` are required) | use the full path (Step 4); drop `-f` so you can see the error body |
| `search/find` → `jq: Cannot iterate over null` | results are under **`.result.memories`** (+ `.resources`/`.skills`), not `.result.results` | `jq '.result.memories[]? \| {score,uri,abstract}'` |
| `search/find` returns score+uri but blank `abstract` | **Skip VLM** mode — no model to write the L0 abstract | ranking is fine; read verbatim with `content/read <uri>` |
| `content/write` says "exists" on a re-run | `mode:"create"` on an already-loaded URI | expected/idempotent — the loader counts it as loaded; no duplicate is created |
| hook hangs on a manual call | reading an open stdin | the hook is `is_terminal()`-guarded; always **pipe** the payload (`printf … \| …`) |
| `pre_llm_call` hook slow when OpenViking is slow/stalled | every OpenViking request (find + per-hit `content/read`) is bounded by a per-request timeout, and Skip-VLM URI reads are capped — a slow/stalled server falls back to the lexical engine instead of hanging the turn | tune `OPENVIKING_TIMEOUT_MS` (default 4000) and `OPENVIKING_MAX_URI_READS` (default 8); a fully-down server fails the first `search/find` and falls back at once |
| LLM has `viking_*` tools / memory double-injects | you ran `hermes memory setup` (provider is on) | undo it — see the ⛔ callout above (remove `memory.provider`); keep the `agentkeys wire` block |

## References
- Plan: [`plan/agentkeys-memory-design.md`](plan/agentkeys-memory-design.md) §6a (engine seam, spiked OpenViking API, model-B rationale).
- Sample corpus: [`../harness/fixtures/sample-memory.md`](../harness/fixtures/sample-memory.md).
- Adapter: `crates/agentkeys-core/src/openviking.rs` (gate-bounded ranking). Hook: `crates/agentkeys-cli/src/hook.rs` (query-aware `memory-inject`).
- OpenViking: <https://github.com/volcengine/OpenViking>. Hermes plugin (API source): <https://github.com/NousResearch/hermes-agent/tree/main/plugins/memory/openviking>.
