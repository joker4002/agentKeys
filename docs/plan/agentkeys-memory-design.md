# AgentKeys memory — gated backend design

**Status:** plan (2026-05). Pre-implementation. Reframed per the decision record [`../research/memory-build-vs-gate-decision.md`](../research/memory-build-vs-gate-decision.md) (**Position C — gated store, pluggable engine**). Companion research: [`../research/ai-memory-systems-survey.md`](../research/ai-memory-systems-survey.md). Lands as arch.md updates (§15.2, §17) once accepted.

> **⚠️ Read this first — what this doc is, after the Position-C decision.**
>
> Memory is three layers: **engine** (extract / embed / rank / consolidate), **store** (encrypted bytes, keys, per-actor isolation), **gate** (who reads what, scoped, audited). Per the decision record, **AgentKeys owns the store + gate and delegates the engine** to the ecosystem (mem0-self-hosted / Claude memory tool / Hermes-native / agentmemory).
>
> So this doc is the spec for the **gated memory backend** — the cap-gated, K3-encrypted, per-actor S3 store and its read/write/list API. It is **NOT** a spec for a memory *engine*. The sections describing ranking/retrieval machinery (**§4.2, §4.4, §5 — vector index, BM25, `query_vec` search, `/rebuild-index`, embedding-model rotation**) are retained as a reference for an **optional, pluggable engine** an operator may run *in front of* this store. They are **explicitly not part of the v0 build.** Each carries an `ENGINE — pluggable, not built in v0` banner.
>
> The v0 build is the **store + gate**: cap-gated `append` / `get` / `snapshot` / `list` / `teardown` over the encrypted per-actor S3 prefix, with deterministic namespace filtering and audit. No LLM, no embeddings, no ranking inside the worker.

**Scope:** how the AgentKeys memory worker ([`crates/agentkeys-worker-memory`](../../crates/agentkeys-worker-memory)) evolves from today's blob primitive (`memory_put` / `memory_get` / `memory_teardown`) into the **gated memory backend** — a structured, cap-gated, K3-encrypted, per-actor, namespaced, audited store that is **portable, extractable, efficient, and engine-agnostic**. The ranking/retrieval *engine* is pluggable and out of scope for the AgentKeys build.

**Non-scope:** (1) building a memory *engine* (extraction, embeddings, ranking, consolidation) — delegated, see decision record; (2) changing the broker cap-mint protocol, the IAM / OIDC stack, K3 rotation, or the per-data-class isolation gates — those invariants from arch.md §§12, 15.2, 17 hold unchanged.

---

## 1. Headline design

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ENGINE — pluggable, NOT AgentKeys' build (decision record Position C)   │
│  mem0-self-hosted / Claude memory tool / Hermes-native / agentmemory     │
│  • decides what to remember + how to rank/recall                         │
│  • embeds queries, runs vector/BM25/graph ranking — its own concern      │
│  • the LLM is the engine's concern too (pluggable: GPT/Claude/Llama)     │
└───────────┬──────────────────────────────────────────────────────────────┘
            │ reads/writes plaintext lines via the SDK
            ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  memory SDK (agentkeys-core) — cap-mint + envelope + wire calls           │
│   • memory.append(event)  • memory.get(id)  • memory.list(filter)         │
│   • memory.snapshot()     • memory.export()                              │
└───────────┼──────────────────────────────────────────────────────────────┘
            │ HTTPS + cap-token (data_class=Memory, op ∈ {Store,Fetch}, namespaces_allowed)
            ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  agentkeys-worker-memory = STORE + GATE (Rust, operator's AWS, NO LLM)   │
│                                                                          │
│   GATE   verify cap → op-match → data_class=Memory → namespace filter →   │
│          freshness → chain device/scope/k3 → audit. Deterministic only.   │
│   STORE  POST /v1/memory/append   { cap, type, line_id, line_b64 }        │
│          POST /v1/memory/get      { cap, id }            → one line       │
│          POST /v1/memory/list     { cap, type, filter }  → ids/metadata   │
│          POST /v1/memory/snapshot { cap, type }          → bytes          │
│          POST /v1/memory/export   { cap, type? }         → presigned URL  │
│          POST /v1/memory/teardown { cap }                → delete prefix  │
│          (legacy) /v1/memory/{put,get} kept; deprecated                   │
│   ── ENGINE endpoints (/search, /rebuild-index) are PLUGGABLE, not v0 ──  │
│                                                                          │
└──────────┬───────────────────────────────────────────────────────────────┘
           │ STS creds scoped to bots/<actor_omni_hex>/memory/* (PrincipalTag)
           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  S3 — $MEMORY_BUCKET (per arch.md §17)                                   │
│                                                                          │
│   bots/<actor_omni_hex>/memory/                                          │
│      ├── profile.json.enc            (single file, CAS-mutable, 8 KiB)   │
│      ├── procedural.jsonl.enc        (single file, occasional rewrite)   │
│      ├── semantic/<ulid>.enc         (one S3 object per line)            │
│      ├── episodic/<YYYY-MM-DD>/<ulid>.enc                                │
│      │                               (one S3 object per line, date prefix│
│      │                                for cheap LIST + since_ts queries) │
│      └── index/                                                          │
│            ├── embeddings.bin.enc    (derived; rebuildable)              │
│            └── manifest.json.enc     (schema_version + dim + count)      │
└──────────────────────────────────────────────────────────────────────────┘
```

**Three invariants the diagram encodes — restate explicitly because every PR touching this code must preserve them:**

1. **Worker MUST NOT call an LLM.** Embedding generation lives caller-side. Summarization / consolidation lives caller-side (in the agent sandbox or in an extractor sidecar — see §6). The worker is pure cap-verify + crypto + S3.
2. **LLM never sees the whole memory.** The retrieval API returns top-K snippets only. There is no `/memory/dump-everything` endpoint that returns plaintext over the wire. (`/memory/export` returns a presigned URL to an encrypted blob; the *operator* downloads + decrypts client-side.)
3. **LLM is replaceable without re-keying.** Memory format is LLM-agnostic. Switching from GPT-4o to Claude Sonnet 4.5 to a local Llama requires zero changes to stored memory; only the caller's embedding model changes (and if the embedding model changes, the embedding index is rebuilt from text — see §5.4).

---

## 2. Goals + non-goals

**Goals (v0) — the gated store, not an engine:**

- Persist four memory types — episodic, semantic, procedural, profile (per research §1) — under the existing per-actor + per-data-class isolation model, as encrypted per-line S3 objects.
- Deterministic gate: cap-token verify + op-match + `data_class=Memory` + **namespace filtering** (`namespaces_allowed`) + freshness + chain checks + audit. No LLM, no ranking, no fuzzy matching anywhere in the gate.
- Engine-agnostic read/write API (`append` / `get` / `list` / `snapshot`) any external engine (mem0-self-hosted / Claude memory tool / Hermes-native / agentmemory) can sit on top of.
- Export a portable bundle (`agentkeys memory export`) any runtime — or a future AgentKeys version — can ingest.
- Stay backward-compatible with the current `memory_put` / `memory_get` blob primitive (one operator's "service" might genuinely want raw blob KV).
- Land **zero** changes to: broker cap-mint protocol, the data_class isolation gate (`DataClass::Memory`), the per-data-class IAM bucket separation (arch.md §17.5), K3-derived KEK, AES-256-GCM envelope format.

**Explicitly delegated (NOT an AgentKeys goal, per decision record Position C):** the memory *engine* — embeddings, vector/BM25/graph ranking, extraction, consolidation, decay. These run in a pluggable external engine in front of the store, or in the optional E1/E2 stages (§9) only if an operator demands in-worker ranking. **How an external engine plugs in — the adapter seam, the canonical engine pick (OpenViking), and Hermes-provider compatibility — is specified in §6a.**

**Non-goals (v0):**

- Graph DB integration. Defer until entity-relation queries dominate workload. (Research §3 — most systems we read add graph later, not first.)
- Server-side LLM extraction. Violates invariant #1. Extraction is client-side; the worker stays LLM-free. (Research §8 — explicitly skipped.)
- A-MEM-style dynamic memory linking. Defer. Adds LLM-call cost on every write; revisit after v0 ships.
- ChatGPT-style "remember everything by default" — operator opts memory types in per actor / per service via the existing scope-contract model.
- Multi-tenant memory sharing across actors. Per-actor isolation is the security floor; if two actors need to share, they share via the operator copying explicitly (export + import).

---

## 3. Memory taxonomy + S3 layout

### 3.1 The four types, mapped to AgentKeys

| Type | Where (per actor, under `bots/<actor>/memory/`) | Mutation pattern | Size cap | Cap op |
|---|---|---|---|---|
| **Profile** | `profile.json.enc` (single file) | Read-modify-write (CAS via `If-Match` ETag) | 8 KiB | `Store` (write) + `Fetch` (read) |
| **Procedural** | `procedural.jsonl.enc` (single file) | Append + occasional rewrite (when agent updates a learned heuristic) | 64 KiB | `Store` + `Fetch` |
| **Semantic** | `semantic/<ulid>.enc` (one object per line) | Append-only via fresh `<ulid>.enc` PUT; invalidation = a NEW line with `op=invalidate, target_id=X` | unbounded; flat prefix | `Store` + `Fetch` |
| **Episodic** | `episodic/<YYYY-MM-DD>/<ulid>.enc` (one object per line, date-prefixed) | Append-only via fresh `<ulid>.enc` PUT under the date derived from ULID timestamp | unbounded; retention policy per service | `Store` + `Fetch` |
| **Index** | `index/embeddings.bin.enc` + `index/manifest.json.enc` | Rebuildable; written by SDK / extractor sidecar | per-actor, ~10-50 MiB typical | `Store` (write) — operators may forbid via local policy |

**Why object-per-line for semantic + episodic** (changed from a single JSONL-per-day shard model after the M0-stage eng review): putting one line per S3 object trades a small per-PUT cost for three correctness properties that the shared-shard model can't give cheaply:

1. **Idempotent appends.** Worker does `HEAD bots/<actor>/memory/<type>/<ulid>.enc` before PUT; 200 = no-op, 404 = OK to write. Re-importing a bundle re-PUTs the same ULIDs — every PUT a no-op. No decrypt needed for dedup check.
2. **Concurrent-writer safety.** Two agent processes appending simultaneously write to different `<ulid>.enc` keys. S3 PutObject is atomic per key. No GET-modify-PUT race, no If-Match retry loops, no silent data loss.
3. **K3-rotation cleanness.** Each per-line object captures the K3 epoch in its v3 envelope at write time (see §3.3). Rotation doesn't span objects; no "day spans two epochs" problem.

**Cost analysis.** S3 PUT is ~$0.005 per 1,000. At 50K lines per actor that's $0.25 lifetime in PUT charges. Storage is ~1 KB per line × 50K = 50 MB at $0.023/GB/month = ~$0.001/mo per actor. Negligible vs the v0 brute-force-cosine compute footprint.

**Reserved-name rule for the legacy `<service>.enc` blob primitive.** Keep `memory_put(service, plaintext)` → `bots/<actor>/memory/<service>.enc`. To prevent collision with the well-known structured paths above, the worker MUST reject these reserved service names with HTTP 400 at `/v1/memory/put` AND `/v1/memory/get`:

- `profile.json` (collides with profile blob)
- `procedural.jsonl` (collides with procedural blob)
- `semantic` (legacy `<service>.enc` would be `semantic.enc`, but `semantic/` is a prefix — preempt confusion)
- `episodic` (same shape)
- `index` (same shape)

Error: `400 reserved_service_name`. The check is one match against a hard-coded const slice.

### 3.2 Why this layout

- **One bucket, per arch.md §17.** Memory bucket separation from vault/audit/email/payment-audit holds. Per-data-class blast-radius invariant unchanged.
- **Per-actor prefix `bots/<actor_omni_hex>/`.** Identical to the current scheme; per-actor PrincipalTag IAM scoping (arch.md §17.5) cleanly contains cross-actor reach.
- **Object-per-line for high-volume types.** Atomic per-key PutObject + cheap HEAD-for-dedup + clean K3 rotation. See §3.1 cost analysis.
- **Date-prefix `episodic/<YYYY-MM-DD>/`.** Drives cheap `since_ts` filtering via S3 LIST with a date-anchored prefix (LIST of `episodic/2026-05/` returns only May's keys; no need to enumerate older months). Semantic is lower-volume + invalidation-driven, so a flat `semantic/<ulid>.enc` prefix is fine.
- **Date is redundant with ULID timestamp** — ULID's first 48 bits ARE the millisecond timestamp ([spec](https://github.com/ulid/spec)). The path-prefix exists purely for LIST performance; the line-ID itself is the canonical timestamp source.
- **Separate index/.** Rebuildable from `text` fields in the per-line objects. If the operator rotates embedding models (e.g. switches from `text-embedding-3-small` to a self-hosted model), the index gets rebuilt from source; no data loss.

### 3.2a S3 key derivation from line-ID

Every `/v1/memory/append` request includes a caller-generated ULID `line_id` in the wire payload (unencrypted alongside `line_b64`). The worker derives the S3 key deterministically:

```
type=episodic, line_id=01HXYZ123...   →  bots/<actor>/memory/episodic/2026-05-22/01HXYZ123....enc
type=semantic, line_id=01HXYZ456...   →  bots/<actor>/memory/semantic/01HXYZ456....enc
type=procedural                       →  bots/<actor>/memory/procedural.jsonl.enc   (single file, mutated wholesale via /profile-cas-style CAS)
type=profile                          →  bots/<actor>/memory/profile.json.enc       (CAS only via /v1/memory/profile-cas)
```

For episodic, the worker parses the ULID timestamp prefix → derives `YYYY-MM-DD` (UTC) → builds the date-bucketed path. No clock skew between caller and worker affects the path (the date comes from the line-ID, not from worker `now()`).

Line-ID leaks to the worker — minor and acceptable. The ULID is random; it reveals only "an event happened at time T" which the worker already learns from the request timestamp anyway.

### 3.3 Wire format — every line, every blob

**Per-line JSON (semantic / episodic / procedural-line):**

Each `<ulid>.enc` object holds ONE JSON object as its plaintext, encrypted under the v3 envelope:

```json
{
  "id": "01HXYZ123456789ABCDEFGHJK",
  "ts": "2026-05-22T14:23:45Z",
  "type": "episodic",
  "op": "append",
  "text": "User asked about Q3 forecast for European region.",
  "meta": {
    "service": "claude-sonnet-4-5",
    "session_id": "sess_01HXYZ...",
    "tags": ["forecast", "europe", "q3"]
  },
  "embedding_model": "text-embedding-3-small"
}
```

- `id` = ULID; mirrors the S3 key (`<ulid>.enc`). Embedded in the plaintext too so an exported plaintext bundle is self-describing without the S3 path.
- `op` = `append | invalidate | replace`. `invalidate` makes the bi-temporal "never delete" pattern explicit; the line object still exists in S3, but retrieval skips items whose `id` appears as a later object's `invalidate.target_id`. Invalidation lookup is "for the LIST page covering the target's date prefix, scan for invalidate-ops referencing this ID" — bounded by date prefix, not full-corpus.
- **No `embedding_ref` field.** Index lookup is by `line_id` only — the index's `entries[].line_id` field IS the join key. (Earlier draft had a byte-offset reference; that breaks every time the index gets rebuilt. Dropped in M0 review.)
- `embedding_model` field is informational — records which model embedded this line when the index was last built. Used by the SDK on rebuild to detect drift.

**Profile blob (read-modify-write):**

```json
{
  "schema_version": 1,
  "actor_omni": "0xabc...",
  "updated_at": "2026-05-22T14:23:45Z",
  "fields": {
    "preferred_units": "metric",
    "timezone": "Europe/Berlin",
    "ongoing_projects": ["forecast-q3"],
    "language": "en"
  }
}
```

8 KiB cap is deliberate — profile is the only thing the SDK injects wholesale into the LLM prompt (it's small enough). Anything bigger goes into semantic.

**Encryption envelope — v3 (PREREQUISITE: see §9 M-1).** The envelope v2 in `crates/agentkeys-worker-creds/src/envelope.rs` today binds AAD to `(actor_omni, service)` only (the `operator_omni` and `k3_epoch` parameters are accepted but ignored — verifiable at `envelope.rs:47`). Envelope v3 widens the AAD to `(operator_omni, actor_omni, service, k3_epoch)` AND adds an explicit `k3_epoch: u8` byte to the envelope header:

```
v3 envelope layout (binary):
   version       (1 byte = 0x03)
   k3_epoch      (1 byte; identifies which K3 epoch's KEK encrypted this)
   nonce         (12 bytes)
   ciphertext || auth_tag

v3 AAD: "agentkeys.mem.aad.v3|<operator_omni_hex>|<actor_omni_hex>|<service>|<k3_epoch>"
```

Workers MUST handle both v2 and v3 envelopes during the migration window — version-byte dispatch on the first envelope byte selects which AAD shape and which AEAD parameters to use. The K3 epoch byte in v3 lets a worker pick the historical KEK without consulting the cap (works for `/export` of historical lines after K3 rotation).

**Why this matters for K3 rotation.** With v2 the only signal of which epoch's KEK to use was the cap-token's `k3_epoch` field. That works for live operations but not for asynchronous decrypt of historical objects (e.g., an export bundle reaching across rotations). v3 makes the per-object epoch self-describing, so historical decrypt is "read byte 1, fetch that epoch's KEK from the signer, decrypt." Pairs cleanly with §8.3 K3 rotation handling.

**Profile blob (read-modify-write):**

```json
{
  "schema_version": 1,
  "actor_omni": "0xabc...",
  "updated_at": "2026-05-22T14:23:45Z",
  "fields": {
    "preferred_units": "metric",
    "timezone": "Europe/Berlin",
    "ongoing_projects": ["forecast-q3"],
    "language": "en"
  }
}
```

8 KiB cap is deliberate — profile is the only thing the SDK injects wholesale into the LLM prompt (it's small enough). Anything bigger goes into semantic.

**Encryption envelope (unchanged):** every file uses the existing `envelope::encrypt(kek, plaintext, aad)` from `agentkeys-worker-creds`. AAD binds `(operator_omni, actor_omni, service, k3_epoch)` per `handlers.rs` line 90-95. This survives K3 rotation: each old episodic shard remembers its epoch via the envelope's version byte, decrypts under that historical K3 (signer keeps historical epochs per arch.md K3 row in §4).

---

## 4. Worker API extensions

All new endpoints under `/v1/memory/`. Cap-token gating unchanged — every endpoint goes through the existing `verify_cap()` chain (`handlers.rs:183`): signature → op-match → data_class=Memory → freshness → chain-device → chain-scope → chain-k3-epoch. **Touching this chain is out of scope for this plan.**

### 4.1 New endpoints

> **STORE vs ENGINE split (decision record Position C).** The rows below are the full surface *if* an in-worker engine is ever built. For the **v0 store+gate build**, the endpoints are: `append`, `get`, `list`, `snapshot`, `procedural-cas`, `profile-get`, `profile-cas`, `export`, `teardown` (+ legacy `put`/`get`). **`search` and `rebuild-index` are 🔌 ENGINE endpoints — pluggable, deferred to optional stage E1 (§9), not in v0.** Two store reads not yet itemized in the table but shown in the §1 diagram + built in M1: `POST /v1/memory/get { cap, id }` → one decrypted line (deterministic, no ranking); `POST /v1/memory/list { cap, type, namespace?, since_ts? }` → ids + metadata for the caller's engine to rank. Both are namespace-filtered by the gate (M1.5).

| Endpoint | Cap op | Request | Response | S3 effect |
|---|---|---|---|---|
| `POST /v1/memory/append` | `Store` | `{ cap, type ∈ {episodic, semantic}, line_id, line_b64 }` where `line_b64` is the v3-encrypted per-line JSON; `line_id` is the ULID also embedded in the plaintext | `{ ok, line_id, s3_key }` or `{ ok, line_id, s3_key, duplicate: true }` if HEAD found an existing object | PutObject to `bots/<actor>/memory/<type>/[<date>/]<ulid>.enc`; HEAD-first for idempotency |
| `POST /v1/memory/procedural-cas` | `Store` | `{ cap, content_b64, if_match_etag? }` | `{ ok, new_etag }` or 412 | conditional PUT to `procedural.jsonl.enc` |
| `POST /v1/memory/search` 🔌 *(ENGINE — E1, not v0)* | `Fetch` | `{ cap, query_vec_b64, k, type? ∈ {episodic, semantic, all}, since_ts? }` | `{ ok, hits: [{id, type, text_b64, score, ts}] }` | read index + parallel-GetObject the K matched `<ulid>.enc` lines + decrypt |
| `POST /v1/memory/snapshot` | `Fetch` | `{ cap, type ∈ {procedural, semantic, episodic}, since_ts? }` | `{ ok, lines: [{id, ts, text_b64, ...}] }` (single-line types) OR `{ ok, content_b64, etag }` (procedural single-file) | LIST prefix + GetObject each + decrypt each; for procedural, single GetObject |
| `POST /v1/memory/profile-get` | `Fetch` | `{ cap }` | `{ ok, content_b64, etag }` | single GetObject on `profile.json.enc` |
| `POST /v1/memory/profile-cas` | `Store` | `{ cap, content_b64, if_match_etag }` | `{ ok, new_etag }` or 412 | conditional PUT on `profile.json.enc` |
| `POST /v1/memory/export` | `Fetch` | `{ cap, types?: [...], since_ts? }` | `{ ok, presigned_url, expires_at }` | enumerate keys; stream a multipart tar on the fly via presigned URL |
| `POST /v1/memory/rebuild-index` 🔌 *(ENGINE — E1, not v0)* | `Store` | `{ cap, embedding_model, vectors_b64, if_match_etag? }` where `vectors_b64` is the operator-built embedding bundle | `{ ok, manifest_etag }` or 412 | overwrite `index/*` atomically (PUT to `.tmp` keys, CopyObject to canonical); If-Match guards concurrent rebuilders |
| `POST /v1/memory/teardown` | `Teardown` | unchanged | unchanged | unchanged |
| `POST /v1/memory/put` | `Store` | unchanged (legacy blob KV) | unchanged | unchanged — `bots/<actor>/memory/<service>.enc`. **Rejects reserved service names per §3.1.** |
| `POST /v1/memory/get` | `Fetch` | unchanged | unchanged | unchanged. **Rejects reserved service names per §3.1.** |

**Notes on the new shape:**

- `/snapshot` now serves three types — including the high-volume types (semantic + episodic) via LIST + parallel GetObject. For very large corpora, callers should use `/export` instead (presigned-URL streaming). `since_ts` keeps snapshot bounded.
- `/profile-cas` and `/profile-get` are symmetric (write + read) for the profile blob. Procedural got the same treatment via `/procedural-cas` + reading via `/snapshot`. No more "two ways to read profile" overlap — one read, one write per single-file type.
- `/rebuild-index` now takes `if_match_etag` to guard against concurrent rebuilders (two SDK instances racing on the same actor's index). The atomic-CopyObject promise from §5.4 holds, but If-Match makes the "you got beat" outcome explicit (412) rather than silent overwrite.

### 4.2 Why `search` takes `query_vec_b64` not `query: string`

> **🔌 ENGINE — pluggable, not built in v0** (decision record Position C). `/v1/memory/search` is a *ranking* endpoint = engine territory. The v0 store does NOT ship it. This section is retained as the reference design for an operator who runs an in-worker search engine, OR for whoever later builds the optional engine module. The store-layer read path is `/v1/memory/get` + `/v1/memory/list` (deterministic, no ranking). When/if an engine IS built in-worker, the decisions below are the correct ones.

This is the single most important *engine-side* API decision and it directly serves the pluggability constraint — it's why even the optional engine never couples the store to an embedding choice.

- **If `search` took a query string,** the worker would have to call an embedding model to vectorize it. That couples the worker to an embedding choice. Worse, when the operator wants to swap embedding models, the worker has to redeploy. The whole "LLM-pluggable" promise breaks at the embedding seam.
- **If `search` takes `query_vec_b64`,** the worker is pure linear algebra (cosine similarity over its index). The caller picks the embedding model. Switching from `text-embedding-3-small` to a self-hosted model means the operator rebuilds the index *once* via `/v1/memory/rebuild-index` and updates the embedding model in their agent code. Worker doesn't change. Zero re-deploy.

The cost is that the caller has to know the index's embedding dimension + model. The `index/manifest.json` answers both (`{embedding_model, dim, count, built_at}`), readable by anyone with a valid `Fetch` cap.

### 4.3 Why `append` takes a pre-encrypted line, not plaintext

Two reasons:

1. **AAD discipline.** The v3 envelope AAD binds `(operator_omni, actor_omni, service, k3_epoch)`. The CALLER builds the AAD because the caller knows the active session's k3_epoch and the actor binding before any wire round trip. The worker re-checks it on decrypt (no surface for AAD-mismatch attacks). The legacy `/v1/memory/put` keeps the server-side-encrypt v2 model for backward compatibility.
2. **Plaintext reduction on the write path.** `/append` never holds plaintext in worker RAM (ciphertext in, S3 PUT out). The worker still holds the KEK (env var), so a worker compromise is still a confidentiality compromise — but the *write* path adds nothing to that exposure.

**Where plaintext is unavoidable: `/search`.** The agent NEEDS plaintext snippets to inject into the LLM prompt — that's the whole purpose of the JIT-retrieval pattern. So `/search` necessarily:

- decrypts matching JSONL lines to extract `text` for scoring + response,
- returns plaintext (base64-encoded) over the wire in the `hits[].text_b64` field.

This is the same exposure shape as the legacy `/v1/memory/get`. The "raise the bar" claim above applies only to `/append`. The plaintext-emitting endpoints (`/search`, `/snapshot`, `/profile-get`, `/get`) are explicitly part of the trust surface — TLS-protected in transit, scoped to the requesting actor via cap-token, but plaintext at the seam by necessity. Document this honestly; do not paper over.

### 4.4 Why `/search` is the JIT injection seam

> **🔌 ENGINE — pluggable, not built in v0.** The flow below describes how an *engine* (in-worker or external) uses the store. In Position C the engine — mem0-self-hosted, Hermes-native, a Claude `BetaAbstractMemoryTool` backend, etc. — does steps 2–4 against its own index, then reads the matched lines from the store via `/v1/memory/get`. The privacy property in step 7 (LLM sees top-K snippets, never the whole memory) is preserved by ALL of these engines because they all retrieve-then-inject. The store guarantees the bytes are encrypted + per-actor-isolated + audited regardless of which engine ranks them.

A typical agent turn becomes:

```
1. user: "what was that European Q3 number we were tracking?"
2. agent embeds the query locally → query_vec
3. agent SDK calls /v1/memory/search { query_vec, k=5, type=all, since_ts=30d }
4. worker returns 5 snippets, each ~200 tokens
5. agent builds prompt = system + 5 retrieved snippets + last 4 turns + user message
6. agent calls LLM (whichever one)
7. LLM sees: 5 snippets, NOT the whole memory. NOT the index. NOT other actors' data.
8. agent appends an episodic line summarizing this turn (caller decides what to extract)
```

Step 7 IS the privacy invariant the user asked for, made operational. Step 8 is where the extractor sidecar (§6) optionally kicks in — for operators who don't want the LLM to choose what to extract, the sidecar does it on raw transcripts using a separate model (or rule-based extraction).

---

## 5. Indexing — derived, rebuildable, optional

> **🔌 ENGINE — pluggable, not built in v0 (entire section).** Indexing is the engine's job. Per the decision record (Position C), AgentKeys does not build the vector index, BM25, RRF fusion, `/rebuild-index`, or embedding-model rotation. This whole section is retained as: (a) the reference design if a future milestone adds an optional in-worker engine module, and (b) the spec the `index/` S3 prefix follows IF an engine chooses to persist its index inside the per-actor store (which the store permits — it's just more encrypted objects under the actor prefix). Nothing here is on the v0 critical path. The store stays a deterministic, no-LLM, no-ranking encrypted KV.

### 5.1 What the index is

`index/embeddings.bin.enc` is a packed array of `(line_id, vector)` pairs. Format:

```
encrypted envelope (existing) wrapping:
  magic: "AKMEMIDX"   (8 bytes)
  schema_version: u16 = 1
  dim: u16            (e.g. 1536 for text-embedding-3-small)
  count: u32
  entries[count]:
    line_id: 16 bytes (ULID raw)
    type:    u8       (0=episodic, 1=semantic, 2=procedural)
    vector:  f32[dim]
```

Packed binary because text-JSON for 50K × 1536-dim vectors at f32 is 300+ MiB and wasteful. The packed form is ~75 MiB before envelope encryption.

`index/manifest.json.enc` is a tiny header pointing at the bin file:

```json
{
  "schema_version": 1,
  "embedding_model": "text-embedding-3-small",
  "dim": 1536,
  "count": 12483,
  "built_at": "2026-05-22T03:00:00Z",
  "covers_through": "2026-05-22T02:55:00Z",
  "shards": [
    {"bin": "index/embeddings.bin.enc", "count": 12483}
  ]
}
```

### 5.2 Who builds the index, and when

The agent's SDK has a `memory.build_index()` helper. It:

1. Calls `/v1/memory/export` with `since_ts = manifest.covers_through`.
2. Decrypts the new JSONL lines client-side.
3. Embeds each `text` field via the caller's embedding model.
4. Concatenates the new vectors with the existing `embeddings.bin` (also decrypted).
5. Re-encrypts and uploads via `/v1/memory/rebuild-index`.

Operators schedule this however they want — cron, post-session, on-demand. The default cadence in the reference SDK is "every 256 new lines OR every 10 minutes, whichever first" (mirroring the audit-relay batch policy in arch.md §15.3).

### 5.3 Why the index can lag the JSONL log

The `/search` endpoint serves whatever the index has. New JSONL lines that aren't yet indexed are NOT returned by search — they exist in the durable log and will surface after the next index rebuild. This is acceptable because:

- Episodic events from "the last few minutes" are usually still in the agent's conversation context anyway; search is for older items.
- The alternative — synchronous embedding on every append — would force an LLM/embedding-model call inside the worker. **Breaks invariant #1.**

Operators who need "search reflects the last second" can drive `/rebuild-index` after every append. The architecture allows it; the default doesn't.

### 5.4 Embedding-model rotation

To switch embedding models (e.g. operator moves from OpenAI to self-hosted Qwen-3-Embedding):

1. Operator changes the embedding-model identifier in their agent config.
2. SDK detects mismatch between `manifest.embedding_model` and current config on next call.
3. SDK runs `memory.build_index(rebuild=true)`: streams all JSONL lines via `/export`, re-embeds with the new model, calls `/rebuild-index` with the full vector set.
4. Worker overwrites `index/*` atomically (write to `index/embeddings.bin.enc.tmp`, then `CopyObject` to canonical name).

No data is lost; the text in the JSONL logs is the durable source. The index is regenerable from it forever.

### 5.5 Why not a dedicated vector DB (Qdrant / pgvector / Weaviate)?

The obvious question: every comparable system (Mem0, Letta, Zep, Cognee, OpenMemory MCP) uses a dedicated vector DB. Why does AgentKeys v0 do flat brute-force cosine over a packed-binary file on S3 instead?

**Two parts to the answer:** (a) v0 doesn't need ANN performance yet — brute-force is fast enough at our scale; (b) introducing a vector DB at the worker tier breaks four AgentKeys invariants that S3 + packed-binary preserves for free.

#### 5.5.1 Brute-force is fast enough at v0 scale

Cosine similarity over `f32[count × dim]` with SIMD on modern x86:

| Vector count | Dim | Compute | Decrypt | Round-trip total |
|---|---|---|---|---|
| 10K | 1536 | ~5 ms | ~3 ms | ~30 ms |
| 100K | 1536 | ~50 ms | ~30 ms | ~120 ms |
| 1M | 1536 | ~500 ms | ~300 ms | ~900 ms |

For a single-actor episodic store with ≤100K lines (the v0 design target), p99 search latency sits well under the LLM-call latency that dominates the surrounding turn. We don't have a perf problem to solve yet.

#### 5.5.2 What a vector DB breaks

| Invariant we currently have | What a vector DB does to it |
|---|---|
| **Per-actor IAM isolation via S3 PrincipalTag** (arch.md §17.5) | Vector DBs don't speak `${aws:PrincipalTag/agentkeys_actor_omni}`. We'd reinvent the per-actor ACL system inside the DB (its own auth, its own audit, its own compromise blast radius). A shared vector store is a single point where one bug or one stolen credential reaches across actors. S3 + PrincipalTag makes that physically impossible. |
| **K3-derived envelope encryption** (handlers.rs:90-95) | Vector DBs index plaintext vectors. We'd have to either (a) run the DB unencrypted (violates the at-rest invariant), (b) re-index on every K3 rotation under a per-tenant DEK (new key layer, new bug surface), or (c) ship encrypted vectors so the DB can't do ANN (homomorphic-ANN is research-grade). None of these are clean. |
| **Stateless worker, one process** | Worker today is a stateless Rust binary that reads/writes S3. Adding a vector DB adds another stateful service per operator deployment — cluster sizing, snapshots, version upgrades, network ACLs, monitoring. Doubles or triples the ops surface. |
| **Portability / extractability** | `aws s3 sync` → tarball → `import` works anywhere. Vector DBs have proprietary on-disk formats (Qdrant segments, Weaviate LSM, pgvector HNSW indices). Exporting them faithfully is per-vendor work; cross-vendor migration is a re-index. The user's "portable, extractable" requirement is the harder constraint to honor with a DB. |

The fifth, weaker concern is **cost**: managed Qdrant clusters run $50–500/month per operator. S3 storage for the same vectors is pennies. Most operators won't have million-vector corpora; making them pay the DB cost is regressive.

#### 5.5.3 The migration path — vector DB as cache, not source-of-truth

When an operator hits the scale wall (any of: vector count > 100K, p99 search > 50 ms, hybrid filter queries dominate), the architecture supports adding a vector DB as a **cache** in front of S3 without breaking the invariants above:

```
v0 (default):  S3 packed-binary index   ──► /v1/memory/search (brute force)
                  (source of truth)

v1 (operator-elected):
               S3 packed-binary index ──┬──► /v1/memory/search ──► vector DB cache (HNSW)
                  (source of truth)     │                              │
                                         │                              │ on cache miss
                                         │                              │ or on /rebuild-index,
                                         └──────────────────────────────┘ refill from S3
```

Key properties of the cache layer:

- **S3 stays authoritative.** Cache holds derived vectors; if the cache is lost / corrupted / re-deployed, it rebuilds from S3 in one batch job.
- **Per-actor sharding** in the cache. One Qdrant collection per actor, named `actor_<omni_hex>`. The worker's existing per-actor cap-token chain extends naturally — STS creds + chain-verify still gate every call.
- **No K3-rotation surprise.** Cache only stores plaintext vectors *while it's warm*; rotation invalidates the cache, worker re-fills from S3 on next call.
- **Operator-elected per deployment.** Same pluggability shape as the audit-destination tiers in arch.md §15.3 (tier A / B / C). Default tier ships brute-force; high-scale operators opt in to cache.

This is the same architectural lever we already pulled for audit-anchoring — pluggable backend, durable substrate is the floor, optimized backend is the operator's choice.

#### 5.5.4 When this decision should be revisited

Flip from "S3 brute-force is the default" to "vector DB cache is the default" when any TWO of these become true across the operator base (not just one operator):

- p50 episodic count per actor > 50K
- p99 search latency > 100 ms with brute-force
- Operators routinely ask for hybrid filter queries (date × tag × similarity in one call) that are awkward to express against the packed-binary format
- Multiple operators have already deployed their own cache layers — at that point standardize the pattern in the worker

Until then, the cost of a vector DB (ops + IAM + key rotation + portability) exceeds the benefit (latency we don't yet need).

---

## 6. Extraction — strictly client-side

The user's pluggability constraint forbids the worker from calling an LLM. Extraction therefore lives in one of two places, **operator's choice**:

### 6.1 Inline in the agent (default)

The agent code, between turns, calls:

```rust
memory.append(MemoryEvent::Episodic {
    text: format!("In session {sid}: user asked about Q3 forecast for Europe; \
                   agent quoted 142M EUR; user accepted."),
    tags: vec!["forecast", "europe", "q3"],
    ..
});
```

The agent decides what to extract. The LLM is implicitly involved (because the agent IS the LLM) but ONLY for the current turn's content — never with visibility of the broader memory. This is the Letta / Claude-memory-tool pattern (research §4.2) but constrained: the agent can only WRITE based on its current view, never READ-then-WRITE based on cross-actor memory.

### 6.2 Extractor sidecar (operator-elected, optional)

For operators who want stronger separation:

```
agent process ──▶ raw transcript ──▶ extractor sidecar ──▶ /v1/memory/append
                                          │
                                          └── runs extraction model
                                              (rule-based, small classifier,
                                               or LLM the operator deploys
                                               separately from the agent's LLM)
```

The sidecar:

- Reads raw transcripts the agent persists to a local socket / fifo.
- Runs extraction (rule-based, small LLM, or operator-chosen model).
- Appends structured memory via the worker's cap-token interface.

Two privacy properties this adds beyond §6.1:

1. The agent's LLM is no longer the extraction LLM. If they're different vendors (e.g. agent uses Claude, sidecar uses a local model), the agent's LLM provider never sees what was extracted as memory.
2. The sidecar can run with a *narrower* cap (Store-only, never Fetch) — it produces memory, can't read it. This is a clean privilege-separation that the agent's main loop (which needs both) can't have.

The reference implementation ships §6.1; §6.2 is a documented hook with the schema spec but no built-in process. Operators wire it up.

---

## 6a. Engine integration — Hermes providers + the adapter seam

> **🔌 ENGINE — pluggable, not built in v0.** This section specifies *how* an external engine plugs onto the store+gate, using the [Hermes runtime's memory-provider ecosystem](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers) as the worked example. It adds nothing to the v0 build; it defines the adapter contract the first engine milestone (§9 stage **E0**) implements. This is the answer to "Hermes lists many memory providers — which do we pick, and how do we stay compatible with the rest?"

### 6a.1 The reframe: Hermes "memory providers" are *engines*, not peers

Hermes ships ~9 memory providers — Honcho, Mem0, Hindsight, Holographic, OpenViking, RetainDB, ByteRover, Supermemory, Memori. **Each bundles three things this design deliberately splits**: an *engine* (extract / rank / synthesize), a *store* (where the bytes live), and a *delivery* path (how memory reaches the LLM). AgentKeys owns the **store** (K3-encrypted per-actor S3) and the **gate** (cap + scope + namespace + audit). So a Hermes provider is not a peer of AgentKeys — it slots into AgentKeys' **engine** axis. The integration question is "which engine ranks the lines our store holds and our gate authorizes," never "which provider replaces AgentKeys."

### 6a.2 Delivery stays at the hook layer, NOT the provider interface

The Hermes provider lifecycle's step 6 is *"adds provider-specific tools for memory management"* — it hands the LLM tools to query/enumerate memory. That breaks invariant #2 (LLM never sees the whole memory) and weakens invariant #3 (LLM pluggable). So AgentKeys delivers memory through the **`pre_llm_call` hook** (`agentkeys wire hermes`, issue #141), **not** by registering as a Hermes `memory.provider`. The hook (`crates/agentkeys-cli/src/hook.rs` → `memory-inject`) *injects* a namespaced block into the prompt and deliberately exposes no query tool to the model (it does not even read the host's prompt from stdin). The privacy thesis, in code:

| Integration surface | Who controls retrieval | LLM gets memory tools? | Verdict |
|---|---|---|---|
| Hermes `memory.provider: <name>` | the provider | **yes** (lifecycle step 6) | ✗ violates invariant #2 / #3 |
| AgentKeys `pre_llm_call` hook (#141) | the gate + engine, off-LLM | no — passive injection only | ✓ canonical delivery |

**Coexistence rule:** a wired AgentKeys runtime keeps `memory.provider` unset (or `none`) — the AgentKeys hook is the *sole* memory delivery. A Hermes provider running in addition would double-inject from a second source of truth. `agentkeys wire` already owns the `hooks:` block (see [`../user-manual.md`](../user-manual.md)); it intentionally leaves `memory.provider` untouched.

### 6a.3 How to start: pick a canonical engine by one axis

The axis that protects the two load-bearing properties (own-the-bytes + LLM-pluggable) is **store-locality + determinism + zero third-party egress**:

| Tier | Providers | Why this tier | Action |
|---|---|---|---|
| **1 — canonical** | **OpenViking** (self-hosted, `OPENVIKING_ENDPOINT`, tiered retrieval over a hierarchy); **Holographic** (local SQLite, HRR algebra — no LLM in the loop) | bytes stay on operator infra; ranking is deterministic; config is one endpoint/path we control. OpenViking's "filesystem hierarchy + tiered retrieval" is ~1:1 with our namespaced S3 store. | **Build the adapter against OpenViking first.** Holographic second — it proves the no-LLM-call ranking property. |
| **2 — extraction-local** | ByteRover (local pre-compression extraction); Hindsight (local mode) | local-ish; useful for the `extract` call, not just `rank` | after Tier 1 |
| **3 — gate-the-egress only** | Mem0, Honcho, Supermemory, RetainDB, Memori (cloud-bundled store) | their cloud sees the bytes — fights own-store. We cannot *store*, but the gate still controls the *call*. | support as "operator accepts egress"; the cap authorizes whether the egress happens, audit records it |

**Recommendation: OpenViking is the canonical engine to test.** Self-hosted single endpoint, no cloud account, maps onto the store, privacy thesis intact out of the box. Confirm its exact interface with a ½–1 day spike before writing the adapter (the provider doc is a summary, not a contract).

### 6a.4 The adapter seam — one trait, three calls

Compatibility does **not** mean matching Hermes' provider API. It means normalizing every engine onto **AgentKeys' own narrow seam**, with store + gate + delivery held invariant and only the engine swapping:

```rust
trait MemoryEngine {
    // optional — many engines extract server-side; deterministic engines skip it
    fn extract(&self, turn: &Turn) -> Vec<Fact>;
    // the load-bearing call: order gate-authorized line IDs for this query
    fn rank(&self, query: &Query, candidates: &[LineId], budget: Budget) -> Vec<LineId>;
    // optional — summary/consolidation, when the engine offers it
    fn synthesize(&self, facts: &[Fact]) -> Option<Summary>;
}
```

`rank` is load-bearing: the engine sees only **line IDs + metadata** from `/v1/memory/list` (already namespace-filtered by the gate), orders them, then the caller reads the winners via `/v1/memory/get`. The engine never holds the plaintext store — it ranks references the gate already authorized. `extract` / `synthesize` are optional (cloud engines extract server-side; Holographic skips extraction entirely).

### 6a.5 Compatibility = one conformance test, engine swapped

An engine **"is compatible"** iff it passes a single golden-path conformance test with store / gate / delivery constant and only the engine swapped:

> seed the Chengdu fixture → gated `append` → engine `rank` over `list` output → `pre_llm_call` injects the top-K block → assert the injected text.

Same test, swap the `MemoryEngine` impl. That is the testable definition of "fits the others" — behavioral conformance over a fixed store+gate+delivery, not API-shape matching.

### 6a.6 Two compatibility tiers, one gate

| Engine class | Store posture | Gate posture | What the cap authorizes |
|---|---|---|---|
| **Local** (OpenViking, Holographic, ByteRover-local) | own-the-store (S3) | gate-the-read | which actor / namespace may `get` / `list` |
| **Cloud** (Mem0, Honcho, …) | can't own (egress) | gate-the-egress + audit | *whether* actor / namespace may call out at all |

The same cap-token + scope contract drives both; only the enforcement point moves (read-time vs. call-time). This is the [universal gate pattern](../research/universal-gate-pattern.md) applied to the engine axis — the gate stays deterministic and policy-carrying whether or not we hold the bytes.

### 6a.7 Relationship to existing sections

- **§7.4 (Mem0 / Letta / LangMem export adapter)** is the *data-portability* bridge — move bytes between runtimes at rest. **This section** is the *live-ranking* bridge — let an external engine rank our at-rest store per turn. Same delegation philosophy, different verb (migrate vs. rank).
- **§5 / §6** describe an engine's *internal* concerns (index, extraction) if one is ever built in-worker (stages E1 / E2). This section describes the *boundary* to an engine running outside the worker — the common case under Position C.

---

## 7. Portability — `agentkeys memory export` / `import`

### 7.1 Export bundle format

Output of `agentkeys memory export --actor <omni> --since <ts>` is one tar.gz (or zip — flag-controlled) called `<actor>-<ts>.akmem`:

```
<actor>-2026-05-22T14-00.akmem/
  manifest.json            # schema_version, actor_omni, exported_at, types[], encryption: "envelope-v4"
  profile.json.enc         # if profile requested
  procedural.jsonl.enc     # if procedural requested
  semantic.jsonl.enc       # if semantic requested
  episodic/
    2026-05-20.jsonl.enc
    2026-05-21.jsonl.enc
    2026-05-22.jsonl.enc
  index/                   # optional — flag-controlled
    embeddings.bin.enc
    manifest.json.enc
```

This is the `bots/<actor>/memory/` subtree zipped, with no transformation. Why no transformation:

- **Re-encryption** is a sharp edge. Source KEK is K3-derived; destination is unknown at export time. The export ships the ciphertext as-is + a note that decryption requires the K3 epoch + actor binding. If the operator wants plaintext export, that's a separate command (`agentkeys memory export --decrypt --to-file`) that operates client-side after download, with a loud warning.
- **Format-stable.** Importing into a future AgentKeys version is "untar into `bots/<actor>/memory/` and call `/v1/memory/rebuild-index`."
- **Auditable.** Bundle is reproducible — same actor, same since_ts, same content + same envelope nonces means byte-identical bundle. Operators can checksum.

### 7.2 Plain-text export (for "extractable" interop)

Separate CLI command, no presigned URL:

```bash
agentkeys memory export-plaintext \
  --actor <omni> \
  --since 2026-05-01 \
  --types episodic,semantic \
  --out memory.jsonl
```

Streams decrypted JSONL to stdout / file. Refuses without explicit `--i-understand-this-is-plaintext` flag (the audit row records the decrypt + export). This is the bridge to other systems — Mem0, Letta, LangMem all consume JSONL or near-JSONL.

### 7.3 Import

`agentkeys memory import <bundle.akmem>`:

- Verifies manifest schema_version is supported.
- For each JSONL file in the bundle: streams encrypted lines, calls `/v1/memory/append` for each (with re-derived AAD for the destination's k3_epoch).
- Skips `index/`; calls `/v1/memory/rebuild-index` at end (after the operator's SDK re-embeds with the destination's embedding model).

Idempotent by line-id: appending a line whose ULID already exists in the destination shard is a no-op (worker enforces this with a per-shard `HEAD`-then-conditional-PUT; codex P2 trap if we don't — line-IDs MUST be ULIDs for this to work cheaply).

### 7.4 Cross-runtime compatibility (Mem0 / Letta / LangMem)

`agentkeys memory export-plaintext` produces JSONL. Each line maps to:

| AgentKeys field | Mem0 field | Letta field | LangMem field |
|---|---|---|---|
| `id` | `id` | `id` | (auto) |
| `ts` | `created_at` | `timestamp` | `metadata.timestamp` |
| `type` | `categories[]` | (folder choice) | namespace prefix |
| `text` | `memory` | `content` | `value` |
| `meta.tags` | `metadata.tags` | `metadata` | `metadata.tags` |
| `meta.session_id` | `run_id` / `agent_id` | `session_id` | `metadata.session_id` |

A ~50-line adapter script in each direction is enough for round-trip. We ship the AgentKeys → Mem0 adapter as a reference in `scripts/memory-export-adapters/`; others contributed as needed.

---

## 8. Integration with existing AgentKeys invariants

### 8.1 Cap-token data_class binding (arch.md §17.5)

No change. Every memory endpoint above continues to require `cap.payload.data_class == Memory`. The four new endpoints all dispatch through the same `verify_cap()` chain at `handlers.rs:183`. A credentials-class cap submitted to `/v1/memory/append` returns 403 `cap_data_class_mismatch` — symmetric with the existing test in `harness/v2-stage3-demo.sh` step 14.

**Test discipline.** Per the per-actor + per-data-class isolation invariants in CLAUDE.md ("test-discipline rule"), the stage-3 demo gets four new cases:

- `memory_append cross-actor cap` → 403
- `memory_search cross-actor cap` → 403
- `cred-class cap → /v1/memory/append` → 403 `cap_data_class_mismatch`
- `memory-class cap → /v1/cred/store` → 403 `cap_data_class_mismatch` (already exists; verify still passes)

### 8.2 Per-data-class IAM (arch.md §17.5)

No change. The memory worker still runs with `agentkeys-memory-role` STS creds; the role is still scoped to `${MEMORY_BUCKET}/${aws:PrincipalTag/agentkeys_actor_omni}/*`. The new endpoints write to the same per-actor prefix; PrincipalTag interpolation handles isolation. A misconfigured memory cap that authorized actor-A but somehow reached the worker with actor-B's STS creds would still get AccessDenied at the S3 layer.

### 8.3 K3 epoch rotation (arch.md §16)

Inherited via the v3 AEAD envelope (§3.3) — the per-object epoch byte makes rotation across the corpus simple:

- `profile.json.enc` is rewritten under current epoch on every CAS-PUT. Self-rotating per write.
- `procedural.jsonl.enc` is rewritten under current epoch on whole-file replace via `/v1/memory/procedural-cas`. Self-rotating per write.
- `semantic/<ulid>.enc` — each per-line object captures its write-time epoch in its envelope header. New writes after rotation use the new epoch; old objects stay readable under their captured-epoch KEK (signer keeps historical K3s per arch.md K3 row in §4). No re-encryption needed.
- `episodic/<date>/<ulid>.enc` — same property. The date in the path is independent of the epoch; rotation does not partition the date-prefix space. A day spanning two epochs simply contains a mix of v3 envelopes carrying different epoch bytes; each decrypts cleanly.

**No "boundary day" problem.** Earlier draft had a single daily JSONL shard whose whole-file envelope couldn't cleanly span epochs. The object-per-line + v3-epoch-byte combination removes the constraint entirely — granularity of encryption (per-line) is independent of granularity of S3 keying (date prefix).

**Optional re-encryption sweep.** Operators who want to retire an old K3 epoch entirely can run an offline tool that LISTs all per-line objects under that epoch byte, decrypts under the historical KEK, re-encrypts under the current KEK, and PUTs back. Idempotent + restartable + per-line concurrent. Out of scope for the worker; ships as a CLI helper.

The audit log (arch.md §15.3) gets a new event type: `MemoryAppend { actor_omni, type, line_id, ts, k3_epoch }`. The audit is the cross-check — every line in S3 has a corresponding chain-anchored audit row, so an operator can detect tampering by diffing chain rows against worker-reported lines.

### 8.4 Architecture-as-source-of-truth (CLAUDE.md policy)

After this plan lands and code ships, arch.md §15.2 needs three additions:

- Document the four memory types (link out to this plan).
- Document the new endpoints under §15.2 (one line each, table form).
- Add `MemoryAppend` to the audit-row schema table in §15.3.

I'll land those in the same PR that introduces the worker changes. Per the "architecture-as-source-of-truth" rule: arch.md gets updated when the code does, not in a follow-up.

---

## 9. Implementation stages

Numbered in order. Each stage is independently shippable (binary stays functional after each one). Estimates assume one engineer. **Post-Position-C, the stages split into CORE (store + gate — the AgentKeys build) and ENGINE (optional, pluggable — only if an operator wants in-worker ranking instead of an external engine).**

### Core stages (store + gate — the v0 build)

| Stage | Deliverable | Crate touchpoints | Demo proof |
|---|---|---|---|
| **M-1 (PREREQUISITE)** | Envelope v3 lands in `agentkeys-worker-creds::envelope`. AAD widened to `(operator_omni, actor_omni, service, k3_epoch)`; version byte 0x03; explicit `k3_epoch` byte in header (§3.3). Version-byte dispatch handles v2 + v3 on decrypt. **Separate PR, NOT part of the memory plan.** This plan depends on it. | `agentkeys-worker-creds`, `agentkeys-core::s3_backend` | `tests/envelope_cross_compat.rs`; cred worker stays green. |
| **M0** | Refactor `handlers.rs`; **split into `handlers/{append,get,list,snapshot,profile,procedural,export,teardown,legacy}.rs`** (store endpoints only; `search`/`rebuild_index` land only if the optional engine stage E1 is taken). No behavior change. | `agentkeys-worker-memory` | `cargo test -p agentkeys-worker-memory` green. |
| **M1** | `/v1/memory/append` + `/get` + `/list` + `/snapshot` + `/procedural-cas` + `/profile-get` + `/profile-cas`. Per-line JSON formats. Reserved-service-name rejection on legacy endpoints. **Add `ulid = "1"` to `agentkeys-types`.** No index, no search — deterministic store only. | `agentkeys-worker-memory`, `agentkeys-types` (new `MemoryLine` struct + disk-fixture roundtrip test) | Harness: write 100 lines (concurrent 2 tasks), get/list returns them in ULID order; duplicate-ULID PUT → `duplicate: true`. |
| **M1.5 (GATE)** | **Namespace filtering** — wire-format `namespace` field on every line; cap-token `namespaces_allowed` claim; worker filters `/get`/`/list`/`/snapshot` by deterministic string-set membership (no LLM, no fuzzy match). Per [`agent-iam-strategy.md` §3.5](../research/agent-iam-strategy.md) + roadmap M1 issue #108. **This is the gate's resource-scoping primitive — the same shape every other worker reuses; see [`../research/universal-gate-pattern.md`](../research/universal-gate-pattern.md).** | `agentkeys-worker-memory`, `agentkeys-types`, cap-token claim | Harness: cap with `namespaces_allowed:["travel"]` reads `travel` lines, gets empty/403 on `personal`/`family`. |
| **M2** | `/v1/memory/export` (presigned URL) + CLI `agentkeys memory export` / `import`. | `agentkeys-cli` + `agentkeys-core` | Harness: export bundle, import into fresh actor, snapshot matches. |
| **M3** | Plaintext export + adapter to Mem0 JSONL format (interop bridge). | `agentkeys-cli` + adapter script | One round-trip with a Mem0 instance. Audit row recorded. |
| **M4** | arch.md updates land (§15.2 + §15.3 schemas + §17 layout + namespace field). | docs only | arch-md-vs-code grep finds zero divergence. |

Core path: **M-1 → M0 → M1 → M1.5 → M2** is the v0 gated-backend ship (~3 weeks incl. envelope). **M3 → M4** is v0.1 (~1 week). The core trunk is mostly sequential (store → gate → export); the only intra-core parallel opportunity is M3 (plaintext+adapter) alongside M4 (docs).

### Engine stages (OPTIONAL — pluggable; only build if an operator wants in-worker ranking)

| Stage | Deliverable | Status |
|---|---|---|
| **E0** | **External-engine adapter seam** (§6a): the `MemoryEngine` trait (`extract` / `rank` / `synthesize`) + an **OpenViking** reference adapter + the swap-the-engine conformance test (Chengdu golden path over a fixed store+gate+`pre_llm_call` delivery). Depends on the core gate (M1.5 namespaces) being green so `rank` operates over gate-authorized `list` output. | **First engine milestone — the recommended start.** Proves "external engine ranks, AgentKeys store+gate holds + authorizes, hook injects." No in-worker ranking; delivery stays at the hook layer, never the runtime's `memory.provider` interface. |
| **E1** | `/v1/memory/rebuild-index` + `/v1/memory/search` (caller embeds, worker scores cosine; optionally BM25 + RRF per the agentmemory-followup research). Index format per §5. Microbench at 10K/100K/1M. Adds the `search`/`rebuild_index` handler modules deferred in M0. | **Deferred / pluggable.** Most operators use an external engine (mem0-self-hosted / Claude memory tool / Hermes-native) instead. Build E1 only if "ranking *inside* the AgentKeys worker, no external engine" is an explicit operator requirement — i.e. the in-worker alternative to E0. |
| **E2** | Extractor sidecar reference (§6.2) — client-side extraction, never in the worker. | **Deferred / pluggable.** External engines bring their own extraction. |

The engine stages are the part the decision record says the ecosystem already does well — buildable fallback, not the plan of record. E1/E2 fork independently of the core trunk if ever taken.

---

## 10. Test plan

Per CLAUDE.md "test-discipline rule," any new code lands with positive + negative tests in the harness.

> **Numbering note (post-Position-C reframe).** The `search_*` / `rebuild_*` / `*dim*` / `cosine_bench` entries below are **ENGINE (stage E1) tests — only if an in-worker engine is built**, not v0. The **core v0** tests are: append / get / list / snapshot / profile-cas / reserved-names / k3-rotation-inflight, **plus the M1.5 gate test** — a cap with `namespaces_allowed:["travel"]` reads `travel` lines and is denied `personal`/`family` (add `crates/agentkeys-worker-memory/tests/namespace_filter.rs`). In the inventory below, map old labels: **old "M2" → E1 (engine, optional); old "M3" → M2 (export)**.

### Positive (unit + integration):

- `MemoryLine` JSON round-trip preserves all fields. Pinned to a checked-in fixture at `crates/agentkeys-types/tests/fixtures/memory-line.json` so any silent schema drift breaks loudly.
- Envelope v3 round-trip with AAD = `(operator_omni, actor_omni, service, k3_epoch)`; reject decrypt on any AAD-field tamper.
- Envelope v2 + v3 coexistence: a v2 blob written before M-1 still decrypts after M-1 lands; v3 blob written after M-1 still decrypts after another K3 rotation.
- `/v1/memory/append` writes per-line `<ulid>.enc`; `/v1/memory/snapshot` LISTs + returns them in ULID order.
- `/v1/memory/search` returns top-K sorted by cosine similarity; ties broken by recency.
- `/v1/memory/search` on cold/empty index returns `hits: []` without panic (regression test for f32-slice empty case).
- `/v1/memory/search` excludes lines whose ULID is referenced by a later `invalidate.target_id` line.
- `/v1/memory/search` honors `since_ts` — lines older than the bound are not returned.
- `/v1/memory/profile-cas` 412s on stale ETag; 200s on correct ETag.
- Two concurrent profile-cas writers racing on same If-Match: exactly one 200, one 412 (deterministic outcome).
- `/v1/memory/rebuild-index` is atomic: a `/search` running concurrent with `/rebuild-index` either sees the pre-rebuild index OR the post-rebuild index, never a torn mid-write state.
- `/v1/memory/rebuild-index` rejects dim drift: rebuilding with dim=1024 when current is dim=1536 → 400 `embedding_dim_drift` unless a `wipe_existing: true` flag is set.
- Export bundle round-trips: export → import → snapshot identical (modulo timestamps).
- Export → K3 rotation → import: imported lines still decrypt correctly under historical-epoch KEK.
- ULID deduplication on import: re-importing same bundle returns `duplicate: true` for every line; idempotent.

### Negative (the security-discipline ones):

- Cross-actor cap on `/v1/memory/append` → 403 (extends existing stage-3 demo step 12).
- `data_class=Credentials` cap on `/v1/memory/append` → 403 `cap_data_class_mismatch` (extends step 14).
- Search query_vec dim mismatch (e.g. 1024 vs 1536) → 400 `embedding_dim_mismatch`.
- Append with K3 epoch < current.epoch → 403 `cap_k3_epoch_stale`. **Regression test: the SDK MUST detect this error, re-mint the cap, and retry once before propagating.** (See §12 Q8.)
- Export presigned URL is per-actor scoped — Actor-A's URL doesn't return Actor-B's bytes when fetched (S3 PrincipalTag enforcement).
- Plaintext export refuses without `--i-understand-this-is-plaintext`.
- Legacy `/v1/memory/put` with `service ∈ {profile.json, procedural.jsonl, semantic, episodic, index}` → 400 `reserved_service_name`.
- Concurrent `/v1/memory/append` from two tokio tasks writing the same `<actor, type, ulid>`: exactly one PUT lands; the second sees HEAD-200 and returns `duplicate: true`. No silent data loss.

### Harness:

`harness/v2-stage4-memory-demo.sh` (new). Runs: append (concurrent) → search → snapshot → profile-cas race → rebuild-index → search-during-rebuild → export → import → cross-actor reject → cross-class reject. Exit 0 on all-green per the script-output convention in CLAUDE.md ("ok proceeding" / "skip" / "fail").

### Test file inventory (per M-stage):

```
M-1 prerequisite (lands in agentkeys-worker-creds):
  crates/agentkeys-worker-creds/tests/envelope_v2_v3_coexist.rs

M0 (refactor — keeps existing test suite green):
  no new tests; existing crates/agentkeys-worker-memory/src/handlers/*.rs unit tests carry over

M1:
  crates/agentkeys-types/tests/memory_line_fixture.rs
  crates/agentkeys-worker-memory/tests/append_concurrent.rs
  crates/agentkeys-worker-memory/tests/append_idempotent.rs
  crates/agentkeys-worker-memory/tests/snapshot_listing.rs
  crates/agentkeys-worker-memory/tests/profile_cas_race.rs
  crates/agentkeys-worker-memory/tests/reserved_names_legacy.rs
  crates/agentkeys-worker-memory/tests/k3_rotation_inflight.rs

M2:
  crates/agentkeys-worker-memory/tests/search_top_k.rs
  crates/agentkeys-worker-memory/tests/search_empty_index.rs
  crates/agentkeys-worker-memory/tests/search_invalidate.rs
  crates/agentkeys-worker-memory/tests/search_since_ts.rs
  crates/agentkeys-worker-memory/tests/rebuild_atomic.rs
  crates/agentkeys-worker-memory/tests/rebuild_dim_drift.rs
  crates/agentkeys-worker-memory/benches/cosine_bench.rs

M3:
  crates/agentkeys-cli/tests/export_import_roundtrip.rs
  crates/agentkeys-cli/tests/export_k3_rotation.rs
```

---

## 11. Privacy invariants — restated in one place

Every PR touching this code or these docs MUST preserve:

1. **Worker never calls an LLM.** Anywhere. Not for embedding, not for summarization, not for extraction. Embeddings come from the caller; extraction lives in the agent process or the extractor sidecar.
2. **LLM never sees the whole memory.** The retrieval path returns at most K snippets per query (default K=5, hard cap K=20). There is no plaintext-bulk-fetch endpoint exposed to the agent's LLM. (Operators have `agentkeys memory export-plaintext` — but that's a CLI command, not an LLM-callable tool.)
3. **LLM is replaceable without re-keying or re-indexing the durable log.** Memory format is text + structured fields. Switching LLM vendor changes nothing in S3. Switching embedding model rebuilds the index (derived artifact) but never the JSONL log.
4. **Cap-token scopes every read + every write.** No anonymous endpoints. No "internal" worker-to-worker bypass. The chain-verify gate runs on every memory call.
5. **Per-actor + per-data-class isolation holds.** Already enforced four ways (broker cap-mint, worker chain-verify, IAM PrincipalTag, bucket separation). The new endpoints all go through the existing `verify_cap()` chain — they don't get to short-circuit it.
6. **Encryption envelope binds the actor (v3 envelope).** AAD = `(operator_omni, actor_omni, service, k3_epoch)`. Tampered metadata fails decrypt. Note: envelope v2 (the format in production today at `envelope.rs:47`) binds only `(actor_omni, service)` — the wider binding requires the v3 prerequisite at §9 M-1. Workers handle both formats during the migration window via version-byte dispatch.

If a PR appears to violate any of these, it's not ready to land. Add the negative test that catches it FIRST, then weigh whether the PR's value is worth weakening the invariant.

---

## 12. Open questions — answered in order of when they need an answer

| # | Question | Decision needed by | Default if no decision |
|---|---|---|---|
| 1 | Embedding model the reference SDK ships with? | E1 (engine) | `text-embedding-3-small` (cheap, 1536-dim, widely tested) |
| 2 | Default K for `/search`? | E1 (engine) | 5 |
| 3 | Index sharding threshold? | E1 (engine) | One file until count > 100K, then split by date range |
| 4 | Are episodic lines indexed by default? Or only when explicitly tagged `searchable=true`? | E1 (engine) | Yes, default-indexed; operator can opt out per-event |
| 5 | What's the wire format for query embedding? Raw f32 little-endian as base64? Use protobuf? | E1 (engine) | f32 LE bytes, base64-encoded. Avoids protobuf dep in SDK. |
| 6 | Is the extractor sidecar in v0 or v0.1? | E2 | Engine stage (pluggable, deferred). External engines bring their own extraction; v0 ships nothing here. Build E2 only if an operator wants AgentKeys-side extraction. |
| 7 | Do we ship the MCP-server wrapper (à la OpenMemory MCP) in v0? | M3 | No. Bridge to MCP is a separate crate; defer to v0.2. |
| 8 | What's the cap-token TTL for memory ops? Same as creds (currently 60s per arch.md)? Or longer for search (so a multi-turn chat doesn't have to re-mint every turn)? | M1 | Same as creds (60s). Re-mint per turn is the same property the credentials worker has — don't weaken it for memory. **SDK retry contract:** on a `cap_k3_epoch_stale` 403 response (K3 rotated mid-session), the SDK MUST transparently re-mint the cap and retry the failed call exactly once before propagating the error to the agent. Without this, operator-initiated K3 rotation breaks every in-flight chat session. Tested by `k3_rotation_inflight.rs`. |
| 9 | What's the default retention for episodic objects? | M1 | Indefinite. Operator policy on bucket lifecycle handles deletion. (S3 Lifecycle = cheaper than worker code.) |
| 10 | Does `/v1/memory/teardown` recursively delete index files too? | M1 | Yes — `bots/<actor>/memory/` is the deletion root including `index/`. |
| 11 | Does the worker cache index files in RAM, or load-on-demand per request? | E1 (engine) | Load-on-demand. Every `/search` does one GetObject for the index, one decrypt, one cosine pass. Optional LRU cache controlled by `AGENTKEYS_MEMORY_INDEX_CACHE_MB` env var (default 0 = disabled). Multi-tenant operators serving many actors per worker process should raise the cap; single-actor deployments can leave it off. Without an explicit policy, multi-tenant RAM grows linearly with actor count (~75 MB / actor at 50K vectors) — production landmine. |

---

## 13. What's NOT in v0 — explicit deferral list

Per the plan-completion policy in CLAUDE.md, here's what this plan does NOT ship, with the unblocker for each:

- **Envelope v3 work itself.** Lands in a separate prerequisite PR (§9 M-1) touching `agentkeys-worker-creds`, `agentkeys-core::s3_backend`, and the cred worker — NOT part of this plan's scope. This plan depends on M-1 being green before M1 can start.
- **Graph queries.** Unblocked by: operator workload showing entity-relation queries dominate. Plan: add `/v1/memory/graph-traverse` as a separate endpoint with its own data_class sub-tag.
- **A-MEM dynamic linking.** Unblocked by: extractor sidecar going beyond rule-based. Plan: link generation runs in the sidecar, not the worker.
- **Cross-actor sharing.** Unblocked by: a use case that justifies weakening per-actor isolation. Plan: probably "shared scope" — multiple actors named in one cap, with explicit read-list. Out of scope here.
- **Server-side encryption-at-rest delegation to KMS.** Unblocked by: operator KMS adoption. Today AES-256-GCM under K3-derived KEK IS the at-rest encryption. Adding KMS would be a double-encrypt; revisit if operator policy demands it.
- **Vector DB substrate option.** Full reasoning in §5.5. TL;DR: brute-force cosine over a packed-binary S3 file is fast enough at v0 scale (<100K vectors per actor, p99 ~50ms), and a vector DB at the worker tier breaks per-actor IAM isolation, K3-rotation cleanliness, ops-surface minimalism, and portability. Unblocked by: two-of-four scale triggers in §5.5.4. Migration shape: vector DB as **cache** in front of S3, S3 stays source-of-truth.
- **Differential privacy / federated learning** on the memory corpus. Out of scope; this is a memory-substrate plan, not a training-data plan.

---

## What landed

This is a plan — no code lands here. **Reframed 2026-05 per the decision record [`../research/memory-build-vs-gate-decision.md`](../research/memory-build-vs-gate-decision.md) (Position C — gated store, pluggable engine).** The doc is now the spec for the gated memory **backend** (store + gate); the engine (ranking/extraction) is delegated to the ecosystem and demoted to optional stages E1/E2. Once accepted, the CORE stages (**M-1 → M0 → M1 → M1.5 → M2**) translate to one harness-tracked deliverable each, per the development-workflow pattern in CLAUDE.md ("pick the HIGHEST-PRIORITY incomplete deliverable from harness/features.json").

## What did NOT land

This is a planning document, not an implementation. **No code changes shipped with this doc.** Per Position C, the memory *engine* (embeddings, vector/BM25/graph ranking, extraction, consolidation) is **explicitly out of the AgentKeys v0 build** — see §2 "Explicitly delegated", the §4.2/§4.4/§5 ENGINE banners, and §9 stages E1/E2. The CORE store+gate stages (M-1 → M0 → M1 → M1.5 → M2 → M3 → M4) are the plan of record.

---

## Universal gate pattern — memory is one instance of many

The store+gate / engine split this doc applies to memory **generalizes to every AgentKeys worker.** Email, payment, home-IoT, credentials are all the same shape: a deterministic **gate** (cap-token + scope + policy + audit) over a pluggable **engine + effect** (the actual service). The cap-token is the universal policy carrier; each worker is a policy enforcer. The fine-grained policy model (spend limits, content-category constraints, read-not-write, device scoping) and the determinism principle that makes it a sound security control are specified in **[`../research/universal-gate-pattern.md`](../research/universal-gate-pattern.md)**. The namespace filtering in §9 stage M1.5 is the memory worker's instance of that pattern's resource-scoping primitive.

---

## GSTACK REVIEW REPORT

> **Superseded numbering.** This report predates the 2026-05 Position-C reframe. Where it references stages M0–M6 or lanes with M5/M6, read the current §9 instead: **core = M-1 → M0 → M1 → M1.5 → M2 → M3 → M4; engine = E1/E2 (optional).** The review's *findings* still hold — only the stage labels changed.

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 18 issues, 4 critical gaps — all folded into plan |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — (no UI scope) |

### Eng review summary

**Architecture (9 findings):** 1A AAD-claim mismatch with envelope.rs:47 [P0]. 1B line-ID dedup couldn't work with shared-shard model [P0]. 1C `embedding_ref` byte offsets stale after every rebuild [P0]. 1D K3-epoch + daily-shard boundary contradiction [P0]. 1E `/search` plaintext exposure under-acknowledged [P1]. 1F concurrent `/append` silent data loss [P1]. 1G legacy `<service>.enc` namespace collision [P2]. 1H `/snapshot` vs `/profile-cas` model overlap [P2]. 1I K3 rotation mid-session opaque error [P2].

**Code quality (3):** 2A handlers.rs heading past readable size — split during M0. 2B add `ulid = "1"` dep, reject `bincode`/`protobuf` for index. 2C `MemoryLine` fixture roundtrip test.

**Tests (13 gaps):** 8 new test files spec'd in §10. Critical: concurrent append, K3 rotation in-flight, empty index, torn-read during rebuild, profile-cas race, search-since-ts, search-invalidate, envelope v2/v3 coexistence.

**Performance (3):** 4A multi-tenant RAM cache policy — added as §12 Q11. 4B parallel S3 fetch for /search K-line lookup — added to M2. 4C cosine microbench checked in via M2 deliverable.

**Critical failure modes (4):** concurrent-append data loss; K3 rotation breaks in-flight caps; cold/empty index panic; torn-read during /rebuild-index. All four have test cases + handling specified.

### Decisions made (3 user-approved)

1. **JSONL storage shape → one S3 object per line** (resolves 1B + 1D + 1F). Plan §3.1 now specifies `semantic/<ulid>.enc` and `episodic/<YYYY-MM-DD>/<ulid>.enc`. New §3.2a documents key derivation from ULID timestamp.
2. **Envelope format → bump to v3** (resolves 1A). New prerequisite stage M-1 added to §9; lands in a separate PR in `agentkeys-worker-creds`. v3 binds `(operator_omni, actor_omni, service, k3_epoch)` AND carries an explicit k3_epoch byte in the header.
3. **embedding_ref fix → inline now** (resolves 1C). §3.3 updated to drop the field; index lookup is by line_id only.

### Plan structure changes

- §1 headline diagram updated for object-per-line layout
- §3.1 table reshaped + reserved-service-names rule added (resolves 1G)
- §3.2 / §3.2a added (object-per-line rationale + ULID→S3-key derivation)
- §3.3 wire format rewritten for v3 envelope + per-object encryption
- §4.1 endpoints: `/snapshot` types expanded, `/profile-get` added (resolves 1H), `/procedural-cas` added, `/append` accepts `line_id`
- §4.3 plaintext-exposure claim made honest (resolves 1E)
- §8.3 K3 rotation rewritten — "boundary day" problem eliminated
- §9 stages: M-1 prerequisite added; M0 expanded to include handlers/ split; parallelization lanes documented
- §10 test plan: 8 new test files spec'd; envelope v2/v3 coexistence covered
- §11 invariant #6 updated for v3
- §12 Q8 updated with SDK-retry contract (resolves 1I); Q11 added (RAM cache)
- §13 deferral: envelope v3 work called out as separate PR

### Parallelization

4 lanes — A (sequential M-1→M0→M1→M2), B (M3→M4 after M1), C (M5 after M1), D (M6). No module overlap → no merge conflicts expected. Documented in §9.

**UNRESOLVED:** 0 — all surfaced decisions made; all critical gaps have test coverage in §10.

**VERDICT:** ENG CLEARED — plan is ready to implement after the M-1 envelope-v3 prerequisite PR lands. No code change should start in this repo for memory-worker stages M0–M6 until M-1 is green.
