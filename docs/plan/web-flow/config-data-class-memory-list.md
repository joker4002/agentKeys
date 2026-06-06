# Config data class + lazy, config-driven memory list

**Status:** Phases 0–5 LANDED (2026-06; #200 + #201 PR1 = Phases 0–3, #201 PR2 = Phases 4–5). Builds on #191 (W3 master-self memory chain), #196 (auto-register on K11-finish), #178 ([`classifier-service.md`](../classifier-service.md) — memory types come from a user config), and the per-data-class isolation invariants ([`../../arch.md`](../../arch.md) §17). Ready to promote to `spec/`.

> **Phase status (2026-06):**
> - ✅ **Phase 0 — cap layer** (#200): `DataClass::Config` + broker `/v1/cap/config-{store,fetch}` + `check_data_class`.
> - ✅ **Phase 1 — infra** (#201 PR1): `provision-config-{bucket,role}.sh` + `apply-config-bucket-policy.sh` (idempotent mirrors) + `CONFIG_BUCKET`/`CONFIG_ROLE_ARN` in `operator-workstation.env` + wired into `setup-cloud.sh` step 13. **Operator runs on AWS.**
> - ✅ **Phase 2 — config worker** (#201 PR1): `agentkeys-worker-config` crate (mirror of `agentkeys-worker-memory`, `config/` prefix, port 9096, `DataClass::Config`) + full `setup-broker-host.sh` wiring (build/install/env/systemd/nginx/firewall/certbot/summary). **Operator redeploys the broker host.**
> - ✅ **Phase 3 — isolation tests** (#201 PR1): `harness/v2-stage3-demo.sh` steps 19–21 — config layer-3/4 (own-prefix write OK + cross-bucket AccessDenied) + cap data-class-mismatch (config↔memory, config↔cred), all master-self. Run green once Phases 1–2 are deployed.
> - ✅ **Phase 4 — daemon** (#201 PR2): `ui_bridge.rs` reads/writes the taxonomy via config-fetch/store (`--config-url` + `--config-role-arn`, env `AGENTKEYS_WORKER_CONFIG_URL`/`CONFIG_ROLE_ARN`); `GET /v1/master/memory` → **categories** from the taxonomy (no decrypt, cache fallback); new lazy detail `GET /v1/master/memory/entry?ns=&key=`; **plant → per-ns JSON arrays** (`memory:<ns>.enc` = `[{key,title,body,updated,bytes}]`, taxonomy written last). Agent-read parity: CLI `hook memory-inject` (`render_memory_blob`) + `harness/memory-plant-demo.sh` now write/read the array shape; single-body blobs still inject (wire 4.2 unchanged). The agent WRITE path (MCP `http_backend`) is intentionally untouched — W4 defers agent-inheritance.
> - ✅ **Phase 5 — frontend** (#201 PR2): `apps/parent-control` memory page lists **categories** (`listMemoryCategories`); opening a category decrypts its namespace entries on demand (`getMemoryEntries(ns)`); plant re-fetches categories. Client interface + `daemon`/`empty` backends updated.
> - ✅ **Phase 4/5 codex hardening** (#201 PR2): an adversarial review flagged two real-chain defects, both fixed. (1) **No data loss on plant** — the per-namespace write is now a **read-modify-write merge** (`memory_get_ns_real` → `merge_stored_entries` → put) under a `plant_lock`, so a restart-stale cache or a concurrent plant can never drop already-durable entries (last-writer-wins is gone). (2) **No silent Config failure** — the memory + config workers return **404** (not 502) on `NoSuchKey`, so the daemon distinguishes "never written" (cache fallback OK) from a real failure; `GET /v1/master/memory` now **502s** on a configured-but-broken Config instead of masking it as empty, and `plant` returns an explicit `taxonomy_status` (`ok`/`unconfigured`/`failed`/`skipped`) the UI surfaces. **Requires a broker redeploy** (the workers' 404 behavior) — `setup-broker-host.sh` rebuilds them.

> **In one line:** the web `/memory` list should resolve **categories from the user's memory-types config** (not by decrypting every blob or enumerating S3), reflect the **durable S3 store** (survive daemon restarts), and decrypt an entry's **detail only on click** — which requires standing up the `DataClass::Config` substrate (the taxonomy's encrypted, master-only home, #178 §7 P1) and fixing per-namespace storage to hold multiple classified memory lines.

## 0. Why the current behavior is wrong

- `GET /v1/master/memory` reads the daemon's **in-memory cache** (`state.master_memory`), not S3 → empty after any daemon restart, even though the data is durable in S3 (`bots/<O_master>/memory/memory:<ns>.enc`).
- The plant is **lossy**: the worker keys S3 off the SIGNED `service = memory:<ns>` and `memory_put` is a plain overwrite, so two entries in the same namespace (e.g. `travel/chengdu-trip` + `travel/chengdu-customs`) collide — the 2nd overwrites the 1st.
- Resolving categories by decrypting every namespace is wasteful (and impossible to enumerate — there is no worker LIST endpoint).

## 1. The model (decouple categories from data)

Per #178 the **category set is the user's configured memory types** (the classifier taxonomy authored at COMPILE), NOT an enumeration of storage and NOT inferred at read. So:

- **List = read the taxonomy config** (small, master-only) → the categories. **Zero memory decryption.**
- **Detail = lazy** — decrypt a namespace blob only when the user opens that category.
- **Storage = per-namespace JSON array** of classified memory lines (so a category with several memories round-trips; fixes the lossy overwrite). The agent reads the same blobs.

This keeps the read path deterministic + cheap (#178 §2): no model, no decrypt-all.

## 2. `DataClass::Config` — the taxonomy's home (#178 §7)

The memory-types taxonomy (and, later, the full policy/grant config) is **more sensitive than individual memory lines** — it maps the whole household/business. It lives as a new gated data class, mirroring cred/memory exactly:

- S3: `bots/<operator_omni_hex>/config/<service>.enc`, K3-KEK encrypted. **Own bucket + own IAM role** (per §17.2 — sharing a role across data classes collapses blast radius).
- **Master-only:** the agent a policy governs has **no** config cap (access-control on the access-control). AgentKeys can't read it (encrypted at rest).
- Cap layer: `DataClass::Config` + `/v1/cap/config-store` + `/v1/cap/config-fetch` (data class statically derived from the route, never user input — the data-class-explicit rule).
- master-self (`operator == actor`) ⇒ #195 scope skip, so no on-chain scope grant needed for the master's own config.

The first config object: `config/memory-taxonomy.enc` = the memory types `[{ns, label, role?, ...}]`. (Today's stand-in is `apps/parent-control/lib/constants.ts::NAMESPACES`.)

## 3. Phased plan (each phase independently shippable)

| Phase | What | Files / actor | Verify |
|---|---|---|---|
| **0 — cap layer** | `DataClass::Config` variant (broker `cap.rs:69` + worker `verify.rs:46`); broker routes `/v1/cap/config-store` + `/v1/cap/config-fetch` + handlers `cap_config_store`/`cap_config_fetch` (statically derive `{op, data_class: Config}`); `check_data_class(Config)` | `handlers/cap.rs`, `worker-creds/verify.rs`, broker `lib.rs` (me) | unit: `DataClass::Config` serializes `"config"`; cross-class cap rejected |
| **1 — infra** | config **bucket + IAM role** (own role); split-statement bucket policy (`s3:prefix=bots/${PrincipalTag}/config/*`); `operator-workstation.env` += `CONFIG_BUCKET` / `CONFIG_ROLE_ARN`; provision OIDC PrincipalTag mapping | `scripts/provision-config-role.sh` + `scripts/apply-config-bucket-policy.sh` (idempotent, mirror vault/memory) — **operator runs (AWS)** | `verify-*` green; `head-bucket` ok |
| **2 — config worker** | store/fetch encrypted `bots/<operator>/config/<svc>.enc`, **master-only**; deploy on the broker host | new `agentkeys-worker-config` (mirror `agentkeys-worker-memory`); `setup-broker-host.sh` wires the unit + nginx vhost — **operator redeploys** | worker smoke (put → get round-trip) |
| **3 — isolation tests** | stage-3: Config **4-layer** cross-isolation (own-prefix write ok; cross-actor + cross-bucket AccessDenied) + cap **data-class-mismatch** (config cap → memory worker → `cap_data_class_mismatch`, and reverse) — the test-discipline rule | `harness/v2-stage3-demo.sh` (me) | demo green |
| **4 — daemon** | read/write the memory-taxonomy via config-fetch/store; `GET /v1/master/memory` → categories from the taxonomy (**no decrypt**); new lazy detail endpoint `GET /v1/master/memory/entry?ns=&key=` → `memory-get(memory:<ns>)` → decrypt → that entry; **plant → per-ns JSON arrays** (fix lossy); agent-read parity + **wire re-verify** | `daemon/src/ui_bridge.rs` (me) | cargo + the wire demo (Chengdu still injects) |
| **5 — frontend** | list shows categories (from daemon/Config); clicking a category/entry fetches detail on demand | `apps/parent-control` (me) | `tsc` + manual |

**Dependency chain:** Phase 4 (the visible behavior) depends on 0→1→2 — the Config data class must exist, be provisioned (AWS), and be deployed before the daemon can read the taxonomy from it. Phases 1–2 need the operator on AWS + a broker redeploy.

## 4. Storage detail (Phase 4)

- **Plant** (read-modify-write, under `plant_lock`): group `req.entries` by `ns`; for each `ns`, **read the durable blob first** (`memory-get`; HTTP 404 = new ns → empty, a real error → ABORT, never overwrite), `merge_stored_entries` (durable ∪ request, deduped by content hash — durable entries are always preserved), then write `memory:<ns>.enc` = `[{key,title,body,updated,bytes}]` (one put per ns). The taxonomy (`config/memory-taxonomy.enc`) is written/updated via config-store **last** (no drift); a configured store failure is surfaced via `taxonomy_status`, not silently swallowed. The serialization + merge close the codex finding-1 data-loss window (restart-stale cache / concurrent plant).
- **List**: config-fetch the taxonomy → return the categories (ns + label, no decrypt). Fallback to the in-memory cache ONLY when Config is unconfigured or the taxonomy is confirmed missing (404); a configured-but-failing Config **502s** instead of masking as empty (codex finding 2). (The earlier "has content via S3 HEAD" idea was dropped — taxonomy categories exist only because a namespace was planted, so they always have content; the daemon has no direct bucket/HEAD access.)
- **Detail**: `memory-get(memory:<ns>)` → decrypt → parse the JSON array → the requested entry's body. 404 (no blob) → empty; a real error → 502.
- **Agent parity**: `agentkeys hook memory-inject` reads the same `memory:<ns>` blobs (now JSON). Update the inject to render the entries; re-verify the wire's `4.2 inject` ("Chengdu") and `4.3` surprise.

## 5. Testing & discipline

- **Phase 0 unit:** `DataClass::Config` (de)serializes `"config"`; `check_data_class` rejects a non-Config cap at a config worker and a Config cap at cred/memory workers (both directions).
- **Phase 3 (mandatory, CLAUDE.md test-discipline):** the four isolation layers for Config + the cap data-class-mismatch — a new data class ships with negative cross-isolation tests for ALL four layers, not POSITIVE-only.
- **Phase 4 e2e:** plant from the web → assert `bots/<O_master>/config/memory-taxonomy.enc` + `bots/<O_master>/memory/memory:<ns>.enc` exist; list shows categories with no memory decrypt; open a category → detail decrypts only that ns; restart the daemon → list still populated (reads S3, not the cache).

## 6. Deferred / out of scope

- **Classifier COMPILE/TAG (#178 P2/P3).** This plan stands up the `Config` *storage* + a static taxonomy; the NL→policy compiler, `CapOp::Classify`, the catalog, and salted scope (P3) are later.
- **Lifting `namespace` into a SIGNED CapPayload field → M4** (today a request-body field).
- **Agent-inheritance of master memory → W4** (a write under the agent's own cap; unchanged by this plan).

## 7. Source-of-truth updates landed with the code

- `arch.md`: add **`config`** to the data-class inventory (§15/§17), the canonical-names section, and the four-layer isolation table; note the config bucket/role.
- `docs/spec/deployed-contracts.md` / the bucket+role registry: add the config bucket + role ARN.
- `CLAUDE.md` per-data-class table: add the Config row + its stage-3 isolation tests (extend the "when a third data class lands" note).
