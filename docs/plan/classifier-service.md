# Classifier-service — natural-language → deterministic authorization for the agent's fleet

**Status:** plan (2026-06). Pre-implementation design, consolidated from the memory-classification design dialogue and generalized to a fleet-wide policy compiler. Foundation: [`../research/universal-gate-pattern.md`](../research/universal-gate-pattern.md) (the four primitives + the determinism principle). It is the **write-side dual** of the memory engine seam in [`agentkeys-memory-design.md`](agentkeys-memory-design.md) §6a. Promote to `spec/` once the first stage ships.

> **In one line:** the classifier-service turns human intent (natural language) into the **structured policy attributes** a deterministic gate enforces, and tags novel requests into those attributes — making AgentKeys *natural-language-programmable, deterministically-enforced* authorization across the whole fleet (memory, credentials, IoT, payment), **without a model ever running on the gate's hot path**.

## 0. The gap this closes

- Deterministic gates need **structured policy** (scope sets, tiers, numeric caps).
- Humans think in **natural language** — *"kids can use their room's devices, no spending."*
- Manual per-resource config **doesn't scale** — "lots of devices, no time to distribute permissions."
- **Semantic gating is unsafe** — an LLM deciding access *at request time* is prompt-injectable and unauditable (the kid's innocent "what's in the rainbow lollipop?" semantically matching the business recipe).

The classifier-service is the **compiler** between the two: NL intent → structured policy the gate enforces deterministically. It is the usability layer that makes the deterministic gate *programmable in English*.

## 1. Three-phase plan

| Phase | Scope | Where the model runs | New mechanism |
|---|---|---|---|
| **P1 — inline, memory only** | classify a memory at write into a namespace | **inline in the agent's own LLM call** (it already sees the turn) + a deterministic rules floor | none — the namespace is an agent-asserted attribute the *existing* gate already enforces. No worker, no GPU, no AgentKeys-reads-plaintext. |
| **P2 — central classifier-service + COMPILE** | a shared, cap-gated, audited worker; **COMPILE** NL → scope grants for credentials ("only trading") and IoT device tiering (the auto-distribution win); **TAG** novel requests | one central shared base model on the GPU fleet; per-tenant via the tenant's taxonomy in the prompt | `classifier-service` (§15.6), `CapOp::Classify` + `/v1/cap/classify`, the tag / decision / chain caches, the parent-confirm flywheel |
| **P3 — fleet-wide + learned** | scope contract generalized to **attribute / category sets** (hierarchical grants); per-tenant **LoRA** trained on confirmations; *optional* TEE for plaintext privacy | LoRA adapters via multi-LoRA serving; (optional) confidential-computing enclave | scope-contract attribute-set check (chain change); LoRA pipeline |

Each phase ships independently. **The glossary (§5) and the determinism guardrail are stable across all three** — only the engine and the policy surface grow. The "no overkill" rule that defers TEE also defers LoRA: don't build P3 machinery until P1/P2 accuracy demands it.

## 2. Efficiency — the gate never infers on the hot path

The fear ("inference on every get") doesn't hold: **the gate is deterministic; the classifier runs only at the edges.**

- **COMPILE** — author time, once, written to scope. Not per request.
- **TAG** — first encounter of a *novel entity*, then cached.
- **Gate check** — `attribute ∈ policy` set-membership. No model.

Three caches make the steady state near-free:

| Cache | Key | Value | Invalidation | Effect |
|---|---|---|---|---|
| **Cap-token** (already exists) | minted `(actor, resource, scope-version)` | signed authorization, TTL ≤ 5h | TTL / explicit revoke | a get within the TTL = verify signature only; resolution + any tag was paid **once at mint**, amortized over every get in the window |
| **Tag cache** | `(entity, policy-version)` | structured attribute (`notion → productivity`) | policy / taxonomy version bump | entities are finite + stable → ~100% hit; inference is once per *novel* entity |
| **Chain-check cache** | `(cap, K3-epoch)` | device / scope / k3 verdict | epoch change | skips the per-get on-chain RPCs (the *real* current per-get cost) within an epoch |

**Steady-state per-get cost = signature verify + set-membership + cache hits → zero inference.** Inference happens once at author (COMPILE), once per novel entity (TAG), once per ambiguous case (ask) — all cached. The **PUT-side classification can be async / queued** (not latency-sensitive). And memory *get* needs zero inference regardless — the namespace was assigned at PUT.

## 3. The Claude Code analog

Claude Code's "auto mode" is fast because **permission is deterministic rule-matching, never a per-call LLM** — and a novel pattern is asked **once**, then persisted as a rule.

**What we copy:** deterministic match on the hot path (rules ≈ our compiled scope) · ask-once → persist → never ask again · tiered (safe → auto, risky → confirm, unknown → ask).

**What we FIX** (the "always-allow but it still keeps asking" pain): Claude Code cached the **surface form** — "allow `npm test`" didn't cover `npm run test:unit` → re-prompt. We cache the **category** (the classifier's output), so one decision covers all variants *and unseen future ones*:

| Claude-Code-style (surface cache) | classifier-service (category cache) |
|---|---|
| allow `npm test` → `npm run test:unit` **asks again** | both → `run-tests` → one grant; even a new `pytest -k foo` → covered |
| allow "McDonald's" → "Burger King" **asks again** | both → `food{fast-food}` → one "deny fast-food" → all variants, forever |

Plus three levers Claude Code lacks, which drive the ask-rate toward zero in (far more varied) daily life:

1. **COMPILE breadth** — one NL paragraph pre-populates *dozens* of category grants on day one (dense from the start, not learned ask-by-ask).
2. **Hierarchical grants** — a high node ("deny all `financial`") covers novel leaves ("buy crypto", a brand-new payment app) → **no ask**.
3. **Async review, not interrupt** — novel-sensitive → safe **deny-by-default** + surface in the daily summary; real-time asks are reserved for *blocking + ambiguous + must-proceed-now* (rare).

**Net: asks ∝ number of novel *categories*, not requests — and most of those are batched into the daily review, not interrupts.**

## 4. Example requests & flow

Three tiers (daily-life):

**Tier 1 — known entity → never asks.** "turn on my bedroom light" → device `kids-room/light` → allow (precomputed). "get the Spotify key" → `spotify → entertainment` (tag cached).

**Tier 2 — variant of a known category → asks once per category, covers all variants.** "play Bluey" / "play Peppa" / any new kids show → `media{rating:kids}` → one grant. "buy robux" / any new in-game purchase → `payment` → deny. No re-asks.

**Tier 3 — can't precompute (a novel *category*).**

Setup (COMPILE) — *"my kid can use his room's devices and watch kids' shows; no spending, no messaging strangers"* compiles to:
- allow `device-control{room:kids-room}`, `media{rating:kids}`
- deny `payment{*}`, `messaging{recipient:non-contact}`

Request — **"ask the home assistant to unlock the front door for my friend."**
1. TAG → `access-control{door:exterior}`.
2. Gate: **no grant covers** `access-control{exterior}` — a category the policy never addressed (this is *why* you can't precompute it: you didn't know it would come up).
3. Sensitive + uncovered → **deny-by-default** + surface in the daily summary ("denied a front-door unlock — set a rule?").
4. Parent decides **once**: `deny access-control{exterior}`.
5. Forever after: front / back / garage door → all `access-control{exterior}` → deny, **never asked again**.

```
WRITE: agent turn ─► [classify / compile → attribute] ─► cap-mint(data_class) ─► gated worker ─► encrypted S3 / effect
                       (edge: cached, async-ok)            (signs the attribute)   (deterministic)
READ:  agent turn ─► cap (TTL cache) ─► gate: attribute ∈ policy?  (deterministic, no model)
                                             ├─ yes → engine ranks → inject
                                             └─ uncovered + sensitive → deny-by-default ─► daily-review (async) ─► one category grant
```

## 5. Abstraction & fit into the arch

**Glossary (canonical — matches `<x>-service`, `CapOp`, `DataClass`):**

| Term | Meaning |
|---|---|
| **`classifier-service`** | a cap-gated, audited, per-tenant **compute-gate** worker (§15.6). No data-class bucket (optional gated training store). |
| **COMPILE** | mode: NL intent → structured policy (scope grants). Author/setup time; master-authorized (`SCOPE_MGMT` role). |
| **TAG** | mode: content/request → structured attribute. Write/request time; `CapOp::Classify`. |
| **policy attribute** | the structured output the gate enforces — memory→namespace, creds→service-category, IoT→device-tier, payment→spend-category. |
| **classifier engine** | the pluggable model (rules → embedding → central-LLM → inline-agent → LoRA → TEE). §22 axis; the **write-side dual of the memory engine**. |

**The determinism guardrail (load-bearing):** the classifier returns **tags + policy, never "allow/deny."** The gate computes the verdict by set-membership on structured attributes. Policy is frozen at COMPILE (human-confirmed); a request can't expand it; a prompt-injected request would have to forge the *category tag*, and low confidence → deny. **No model judgment ever runs inside a gate** — exactly `universal-gate-pattern.md`'s "an LLM pre-tags, the gate still decides; the LLM advises, it never authorizes."

**Where it plugs in:**
- **Worker inventory — `§15.6 classifier-service`**, a *compute*-gate (vs the *storage*-gates §15.1–15.5). Gate = cap + chain-verify + audit (isolation layers 1–2); effect = inference, **no S3 bucket** (layers 3–4 N/A unless it keeps a gated training store).
- **Cap layer** — `CapOp::Classify` (a backward-compatible 2-crate enum add in broker `cap.rs` + worker `verify.rs`) + `/v1/cap/classify` minting `{op:Classify, data_class}` — data-class-bound (a Memory-classify cap can't classify email).
- **Scope contract** — `isServiceInScope` generalizes to **attribute / category-set membership** (the P3 chain change); COMPILE writes the sets; the gate reads them.
- **Reuses, doesn't reinvent** — request-TAG feeds the existing `permission.check` / `agentkeys hook check` gate; ambiguity → the existing **`ask_parent`** verdict; every COMPILE/TAG is an **audit** op_kind (§15.3a envelope, §15.3b ritual) recording the attribute + model + confidence; the **`apps/parent-control`** app is the confirm-UI + the flywheel source.
- **The four primitives** — the classifier compiles NL into `operation / resource-scope / quantitative-limit / attribute-constraint` values; the gate enforces them. Cross-cutting by construction.
- **Write/read symmetry** — `classify-then-gate` (write) is the dual of `gate-then-rank` (read, the §6a engine). Both: a gate over a pluggable model, per-actor, audited, with the inline / central / TEE privacy spectrum.

## 6. Important things not to miss

1. **Revocation vs. cache staleness.** A granted cap carries authority until its TTL (≤5h) or an **explicit revoke**. Tightening a scope does **not** retroactively kill live caps — for "cut access NOW," revoke the cap, don't just edit scope. Surface this in the parent UX ("changes apply within ~N min, or revoke for immediate").
2. **Tag the ENTITY, not the agent's narrative.** Classify on structured facts the agent can't freely author (the real service ID, device ID, MCC) over the agent's free-text *description* of what it wants — the narrative is attacker-controlled ("this is definitely a kids show"). Where only free-text exists, low-confidence → deny.
3. **Sensitivity-weighted confidence.** High-stakes categories (payment, security, credentials) get a **higher confidence bar + bias to deny**; benign ones (which show) a lower bar + bias to allow. One global threshold is wrong.
4. **Stable / deterministic tags.** The same entity must always get the same category (cache correctness, audit, the user's mental model). Use deterministic backends (rules / embedding), or **cache-and-freeze** the LLM's first answer — never re-roll a non-deterministic classification per request.
5. **Taxonomy governance + versioning.** Ship a sensible **default category tree** (role-aware: kid / teen / adult / business); per-tenant extensions; **version it** (cache keys + grants reference the taxonomy version). Unversioned taxonomy drift silently invalidates grants.
6. **Classifier-outage degradation.** If the classifier is down: existing tags (cache) + existing grants still gate fine; only *new* categorizations stall → **deny-by-default new/uncovered, queue for later**. The classifier is **never load-bearing for availability** (same rule as the read engine).
7. **Explainability.** Every deny/allow must be explainable to the parent: "denied — `access-control{exterior}` not in scope; classifier tagged 0.92." Trust + debugging + the appeal path.
8. **Two-way feedback (not just confirm).** Capture *both* wrong-deny (kid frustrated → re-classify/grant) and wrong-allow (a leak → audit anomaly → tighten). One-directional confirmation drifts.
9. **Onboarding = the NL capture.** Day-1 friction is set by how well the first NL-policy capture covers the user's life. Invest in the onboarding conversation that produces the initial COMPILE; safe defaults backstop the rest.
10. **Per-tenant quotas on the shared GPU.** Meter COMPILE/TAG per tenant so one can't starve the fleet; batch puts.
11. **Privacy posture (record it).** Central (P2/P3) classification reads plaintext → AgentKeys is in the trust boundary for the classify path; **inline (P1)** and **TEE (P3)** close it; the durable store stays encrypted throughout. Write the chosen posture into the threat model.

## References
- [`../research/universal-gate-pattern.md`](../research/universal-gate-pattern.md) — the four primitives + the determinism principle (this doc's foundation; "the upstream classifier" it names *is* this worker).
- [`agentkeys-memory-design.md`](agentkeys-memory-design.md) §6a — the read-side engine seam this is the write-side dual of.
- [`../arch.md`](../arch.md) §15 (workers), §17.5 (per-data-class + four-layer isolation), §22 (pluggable surfaces).
