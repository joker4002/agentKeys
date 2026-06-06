# Onboarding config bootstrap + classifier-driven auto-distribution

**Status:** plan (2026-06). The **product/onboarding view** of the classifier design — how a real user's `Config` (taxonomy + policy) is *bootstrapped*, and how an agent's scopes + memory are *auto-distributed* at connect time. The classifier internals (COMPILE/TAG, the determinism guardrail, the catalog, the flywheel, the three phases) live in [`../classifier-service.md`](../classifier-service.md) (#178) and are **not** re-specified here. The encrypted, master-only `Config` substrate this writes to is **landed** (#201 Phases 0–5, [`config-data-class-memory-list.md`](config-data-class-memory-list.md)). Promote to `spec/` once the first production COMPILE ships.

> **In one line:** today the user gets a *default* taxonomy via a button and a test-only `plant` endpoint; this plan adds the two real bootstrap entry points (**default** and **NL→COMPILE**), and the **connect-time auto-distribution** that turns the master's policy into an agent's scopes + inherited memory — every grant **proposed by the classifier, confirmed by the master**, never silently applied.

## 0. What this builds on (don't re-litigate)

| Foundation | Gives us | Status |
|---|---|---|
| [`../classifier-service.md`](../classifier-service.md) (#178) | COMPILE (NL→policy), TAG (entity→category), the category **catalog** (§8.1), the **flywheel**, the determinism guardrail, the three phases | plan |
| [`../../research/universal-gate-pattern.md`](../../research/universal-gate-pattern.md) | the four primitives (operation / resource-scope / quantitative-limit / attribute-constraint) every worker enforces deterministically | insight |
| [`config-data-class-memory-list.md`](config-data-class-memory-list.md) (#201) | `DataClass::Config` — the encrypted, master-only home for the taxonomy/policy; the daemon read/write path (`config-store`/`config-fetch`) | **landed** |
| arch.md §19 `AgentKeysScope` | the on-chain enforcement primitive (`setScope` / `isServiceInScope`); master-authorized via `SCOPE_MGMT` + K11 | landed |

Terminology used below (**policy / taxonomy / category / namespace / service / scope / cap**) is defined once in [`../../wiki/policy-scope-namespace.md`](../../wiki/policy-scope-namespace.md) — read it first; this doc does not redefine those words.

## 1. The product flow (the five steps the user described)

```
            ┌─────────────────────────── ONBOARDING (master) ───────────────────────────┐
 (1) config init ──┬─ A. DEFAULT taxonomy  (role/region preset: business, smart-home, kids, health…)
                   └─ B. NL → COMPILE      ("I'm a basketball pro, 2nd-yr uni, I like games" → taxonomy+policy)
                                │
                                ▼  writes config/policy.enc + config/memory-taxonomy.enc  (DataClass::Config, master-only)
            ┌─────────────────────────── AGENT CONNECT ──────────────────────────────────┐
 (3) agent pairs ──► vendor DEFAULT classifier (glasses → {sports,health}; Hermes → inherit-all)
                                │
                                ▼  classifier TAGs the agent's surface (its memory namespaces + cred services)
                                ▼  AUTO-DISTRIBUTE: propose scopes (memory:<ns> + cred:<service>) ── master confirms ──► setScope
            ┌─────────────────────────── STEADY STATE ───────────────────────────────────┐
 (4) new cred minted ──► classifier auto-categorizes (catalog + telemetry prior) ──► master picks the category ──► one grant
```

1. **Config init — two entry points** (both write the same `Config` objects):
   - **A · default** — a curated, **role/region-aware** preset taxonomy (#178 §6.5). This is the *only* path partly built today (the parent-control "init default" button).
   - **B · NL → COMPILE** — the user types a sentence; the classifier **COMPILEs** it (#178 §1 P2, §5) into the taxonomy + readable policy. **This is where COMPILE happens explicitly.**
2. **`POST /v1/master/memory/plant` is a TEST harness, not the product path.** It seeds memory blobs directly for demos/CI ([`config-data-class-memory-list.md`](config-data-class-memory-list.md)); production memory is classified-on-write, and the taxonomy is **authored by COMPILE**, not derived from what was planted.
3. **Agent connect → vendor-default classifier → auto-distribution.** An agent arrives with a **vendor default taxonomy** (an AI-glasses vendor ships `{sports, health}`; a general agent like Hermes on a Mac mini can **inherit all** master memory and let the user curate). At connect, the classifier TAGs the agent's surface (the memory namespaces it will read, the cred services it will use) and **auto-distributes** them as scopes — *proposed*, master-confirmed (§3).
4. **New cred minted → classifier auto-categorizes → user picks.** When a credential is minted, the classifier categorizes it from the **catalog + a telemetry prior** (the most-frequent category other tenants chose for that service); the master selects/confirms the category, which becomes a `cred:<service>` grant (§3, §4).

### 1.1 Cred and memory are the SAME pattern (one template, two axes)

This is an explicit invariant, not a coincidence: **credentials and memory go through the identical classifier + onboarding pipeline** — the [universal-gate-pattern](../../research/universal-gate-pattern.md) makes every data class one gated template. Both follow:

```
classify ──► propose scope ──► master-confirm (sensitivity-gated) ──► setScope ──► deterministic gate (service ∈ scope?)
```

The only per-class differences are the **resource axis** and **which operation the scope authorizes** — everything else (COMPILE at onboarding, connect-time auto-distribution, the propose→confirm gate, the catalog, the audit) is shared:

| | classified by | resource axis (the `service`) | scope authorizes | classify timing |
|---|---|---|---|---|
| **memory** | content → namespace | `memory:<ns>` (namespace = the memory category) | **read** the namespace | on write |
| **credentials** | service id → category (catalog) | `<credential-service>` (e.g. `openrouter`) | **fetch/use** the credential | at mint / connect |

So at onboarding the COMPILE produces *both* memory-namespace grants and cred-service grants; at agent connect the classifier TAGs *both* the namespaces the agent reads and the cred services it uses, and auto-distributes *both* under the same confirm-gate. Any future data class (IoT, payment) drops into the same template (#178 / four primitives) — no per-class onboarding logic.

## 2. Verification against #178 (ask 1) — aligned, with four refinements

The flow is the **productized onboarding + connect view** of #178. Direct mapping:

| User's step | #178 mechanism | New? |
|---|---|---|
| 1A default taxonomy | §6.5 "default category tree (role-aware)" + §8.1 catalog bundled defaults | reuse |
| 1B NL → COMPILE | P2 **COMPILE** (§1, §5); §6.9 "onboarding = the NL capture" | reuse |
| 2 plant = test-only | plant is the dev seed; production is classify-on-write + COMPILE-authored taxonomy | clarification |
| 3 agent connect → batch classify → scopes | §8 "Integration connect (eager) → classify each once (batched, async) — **the auto-distribution**" | reuse |
| 4 new cred → categorize → confirm | §8.1 catalog + flywheel; §6.8 two-way feedback | reuse |

**The four genuinely new refinements** (this doc specs them; fold the durable ones back into #178):

- **R1 · Two explicit config-init entry points** (default *vs* NL-COMPILE) as first-class onboarding UI, not just "safe defaults backstop." Verdict: **good** — it makes #178 §6.9 concrete and gives a low-friction path (default) + a high-coverage path (COMPILE) on day one.
- **R2 · Vendor-default taxonomies.** A per-vendor default classifier/taxonomy an agent brings at connect (glasses → `{sports,health}`). Verdict: **good, as a *prior* not an authority** — it is a vendor-supplied **catalog overlay** (#178 §8.1 distribution shape: bundled → registry → community), consumed exactly like the shared catalog: a *proposal* the master confirms, with the catalog's **sensitivity floor** as the backstop (§3). A vendor mis-labeling a door-lock "safe" cannot self-grant — `access-control` is sensitivity-gated regardless of the vendor's label.
- **R3 · Agent memory inheritance with user-pick.** A full agent (Hermes) inherits the master's memory namespaces and the user **curates** which to grant. Verdict: **good** — it is the W4 "agent-inheritance of master memory" item ([`config-data-class-memory-list.md`](config-data-class-memory-list.md) §6, deferred), gated by **per-namespace master pick** (never auto-inherit) + read under the **agent's own cap**. Sensitive namespaces (health, financial) require explicit pick.
- **R4 · Telemetry-prior cred categorization.** Aggregate "most-frequent category for service X" pre-selects the default the user confirms. Verdict: **good, with a hard privacy boundary** (§3) — the prior is a **catalog** statistic (entity→category), never a **grant** statistic (who-denied-what).

**Net:** nothing in the user's flow contradicts #178; R1–R4 are additive and each has a safe construction. R2/R4 are catalog-shaped (already a #178 distribution pattern); R3 is the deferred inheritance item; R1 is the onboarding UI.

## 3. Security model (ask 2) — viable, but four invariants are load-bearing

The flow is viable **only if** it preserves these. Each maps to an existing #178/gate rule.

1. **Determinism guardrail (non-negotiable, #178 §5 / gate-pattern §"determinism").** The classifier emits **tags + proposed policy, never allow/deny**; the gate decides by set-membership on structured attributes. None of R1–R4 may put a model on the gate's hot path. COMPILE/vendor-taxonomy/telemetry all run at the **edges** (author / connect / mint), cached; the per-request gate stays a hashmap lookup.
2. **Auto-distribution = *propose then confirm*, sensitivity-weighted (#178 §6.3).** "Auto-distributed" must NOT mean "silently granted" — `setScope` is a **master mutation** (`SCOPE_MGMT` + K11, arch.md §19.3 step 5). Construction:
   - **Safe categories** (e.g. `media{rating:kids}`, a benign memory namespace) → **auto-confirm + surface in the daily review** (the master can revoke).
   - **Sensitive categories** (payment, credentials, `access-control{exterior}`, health) → **explicit K11 confirm per grant**, never auto. The sensitivity tier comes from the **catalog**, so a vendor/telemetry prior cannot downgrade it.
   - Batched: one K11 gesture confirms a reviewed *set* (the connect-time distribution), not N prompts.
3. **Tag the entity, not the narrative (#178 §6.2).** R4 categorizes on the **real service id** (`stripe`, `openrouter`) + the catalog, never the agent's or vendor's free-text self-description. R2's vendor taxonomy is keyed on real device/namespace ids. Free-text only → low confidence → deny-by-default.
4. **Telemetry & vendor priors carry CATEGORIES, never GRANTS (#178 §8.1 "catalog ≠ policy").** The shared, learnable layer is *"service X is usually `payments`"* (generic, no PII, k-anonymous aggregate, safe to bundle/open-source). The **grant** *"this household denies `payments` for the kid"* is per-tenant, lives **only** in encrypted `DataClass::Config`, and is **never** an input to telemetry. This is the same split as public MCC codes vs. your card's private limits. **Record the privacy posture in the threat model** (#178 §6.11): the NL-COMPILE (1B) sends the onboarding sentence to the central classifier → AgentKeys is in the trust boundary for the *compile* path (author-time, master-authorized, durable store stays encrypted); inline (P1) or TEE (P3) closes it.

**Residual risks to track:** (a) a wrong vendor/telemetry prior silently widening a *safe* grant — mitigated by daily-review visibility + two-way feedback (#178 §6.8); (b) COMPILE over-granting from an ambiguous sentence — mitigated by the master reviewing the COMPILE output before it writes scope; (c) inheritance leaking a sensitive master namespace into an agent — mitigated by per-namespace explicit pick (R3).

## 4. Technical viability + sequencing

**Landed substrate (reuse as-is):** `DataClass::Config` + the daemon `config-store`/`config-fetch` path (#201); `AgentKeysScope.setScope` + K11 master-mutation gate (§19); the agent pairing + per-actor binding (§10.2); the parent-control confirm UI surface.

**Unbuilt — this is mostly #178 P2 + the onboarding UI:**

| Item | Where | Depends on |
|---|---|---|
| `classifier-service` worker (COMPILE + TAG) | new `agentkeys-worker-classify` (#178 §15.6) | — |
| `CapOp::Classify` + `/v1/cap/classify` | broker `cap.rs` + worker `verify.rs` (2-crate enum add) | — |
| category **catalog** (bundled → registry), incl. **vendor overlays (R2)** | `ClearSigningCatalog`-shape distribution (arch.md §22) | catalog format |
| onboarding **COMPILE UI** (1B) + default-preset picker (1A) | `apps/parent-control` | classifier-service |
| **auto-distribute propose→confirm** flow (sensitivity-tiered) | daemon (extends the cap-mint/scope path) + parent-control | classifier-service, catalog |
| **agent memory inheritance + pick (R3)** | daemon (per-ns agent-cap write) + parent-control | W4 |
| **telemetry aggregation (R4)** | a new aggregate pipeline (catalog-densification only) | privacy review |

**Sequencing:** the taxonomy *storage* is done; what changes is the **source** (today: derived from `plant`; target: authored by COMPILE / default-preset). Ship order: (i) default-preset bootstrap (1A) writing a real authored taxonomy → (ii) classifier-service + `CapOp::Classify` → (iii) NL-COMPILE (1B) → (iv) connect-time auto-distribute (3) → (v) catalog + vendor overlays (R2) + cred categorize (4) → (vi) telemetry priors (R4) + inheritance (R3). Each is independently shippable (#178 §1).

## 5. Relationship to the test-only plant endpoint

`POST /v1/master/memory/plant` (#201 Phase 4) stays as the **deterministic, no-model seed** for harness/CI/demo — it writes memory blobs + reconciles a *derived* taxonomy so the web list has data without a live classifier. In production it is superseded: the taxonomy is **authored** (1A/1B), memory is **classified on write**, and the list reads the authored taxonomy. Keep plant; document it as test-only (done in #201's plan). Do **not** route real onboarding through it.

## 6. Resolved decisions (2026-06)

Tracked for implementation in [**#207**](https://github.com/litentry/agentKeys/issues/207) (telemetry split to [**#208**](https://github.com/litentry/agentKeys/issues/208)).

1. **Default presets — ~10 role/region presets.** The shipped DEFAULT is the rich adult profile: *an adult with kids, runs a business, has IoT home appliances, in a relationship (wife, parents), does investment* — so the out-of-the-box taxonomy spans `{business, smart-home, kids, health, finance/investment, relationship/family, …}`. The other ~9 presets specialize by role/region; extend via the catalog.
2. **COMPILE review UX — confirm-as-is + adjust later.** The master sees the compiled grants and confirms the *set* with one K11 gesture; edits happen afterward in parent-control (not a pre-write editor).
3. **Telemetry — opt-in** (off by default), tracked as enhancement [#208](https://github.com/litentry/agentKeys/issues/208). A convenience, never load-bearing (§3 invariant 4: categories not grants).
4. **Vendor-overlay trust — signed + sensitivity floor.** Vendor catalogs are signed (vendor key in the registry); the catalog's sensitivity tier is the backstop, so a signed-but-wrong overlay still can't downgrade a sensitive category (§3 invariant 2).

## 7. Source-of-truth updates to land with the code

- Fold **R1–R4** into [`../classifier-service.md`](../classifier-service.md) (vendor overlay → §8.1; telemetry prior → §8.1 flywheel; inheritance → a §-ref to W4; the two onboarding entry points → §6.9) when the first stage ships.
- arch.md §5 canonical-names: link the new [`../../wiki/policy-scope-namespace.md`](../../wiki/policy-scope-namespace.md).
- When auto-distribution ships, extend the per-actor isolation tests (CLAUDE.md test-discipline) with a **negative**: an unconfirmed sensitive category must NOT produce a scope grant.

## References
- [`../classifier-service.md`](../classifier-service.md) — the classifier internals (#178); this doc is its onboarding/product view.
- [`config-data-class-memory-list.md`](config-data-class-memory-list.md) — the `DataClass::Config` substrate (#201) this writes to.
- [`../../research/universal-gate-pattern.md`](../../research/universal-gate-pattern.md) — the four primitives.
- [`../../wiki/policy-scope-namespace.md`](../../wiki/policy-scope-namespace.md) — the terminology this doc uses.
