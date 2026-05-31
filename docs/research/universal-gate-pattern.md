# The universal gate pattern — every worker is a gated engine+effect

**Status:** architecture insight (2026-05). Generalizes the memory decision record [`memory-build-vs-gate-decision.md`](./memory-build-vs-gate-decision.md) to the whole worker fleet. Feeds a future arch.md §15 + §17 + cap-token-schema update. Strategic anchor: [`agent-iam-strategy.md`](./agent-iam-strategy.md).

---

## The realization

Memory taught us a three-layer split: **engine** (the service logic — delegate), **store/effect** (the durable bytes or the real-world action — own the boundary), **gate** (who may do what, scoped, audited — own it; this IS the product).

That split is **not special to memory.** It is the shape of *every* AgentKeys worker. Credentials, email, payment, and a new home-IoT worker are all the same diagram:

```
 Agent ──(cap-token: op + scope + POLICY + audit)──► GATE ──► ENGINE + EFFECT
                                                      │            │
              deterministic authorization ───────────┘            └── the real service:
              (verify cap, match op, filter scope,                    SES / a payment rail /
               check policy attributes, write audit)                  Mijia / S3 / a vector engine
```

The agent's question is always *"may I do X to Y?"* The gate's answer is always a **deterministic** yes/no derived from the cap-token's claims and the request's structured attributes — then it lets the engine run, and records what happened. AgentKeys is the gate. The engines are pluggable and mostly someone else's.

This is exactly what [`agent-iam-strategy.md` §2.1](./agent-iam-strategy.md) means by "Authority Host, not Task Host," made concrete at the worker layer.

## Memory was the warm-up

| Memory concept | Generalizes to |
|---|---|
| `data_class = Memory` | the worker identity / service class |
| `op ∈ {Store, Fetch}` | per-operation permission (read vs write vs execute) |
| `namespaces_allowed: ["travel"]` | **resource-scoping** — the general primitive |
| worker filters deterministically (string-set membership, no LLM) | the **determinism principle** (below) |
| K3-encrypted per-actor S3 | the store/effect boundary the gate protects |
| audit row per read/write | the universal audit obligation |

The namespace filter built in memory stage M1.5 is the first instance of a primitive every other worker reuses.

## The four policy primitives

Generalizing across workers, a cap-token needs to express four kinds of constraint. Three are stateless (cheap, pure cap-verification); one needs state.

| # | Primitive | Cap-token claim (sketch) | Enforced by | Stateful? | Example |
|---|---|---|---|---|---|
| 1 | **Operation** | `op: read` / `write` / `execute` | op-match at endpoint (exists today) | No | "read email, never send" → grant Fetch caps, never Store |
| 2 | **Resource scope** | `scope_allowed: [...]` (string set) | set-membership filter | No | "only the kids' room devices"; "only `travel` memory namespace" |
| 3 | **Quantitative limit** | `limits: {max_single: 2000, ...}` | numeric compare on request attribute | No (single-shot) / **Yes (cumulative)** | "no single spend > $20"; "≤ $500 / month total" |
| 4 | **Attribute constraint** | `deny_attrs: ["mcc:5814"]` / `allow_attrs: [...]` | set-membership on request's structured tags | No | "no fast food (MCC 5814)"; "no alcohol category" |

Your four examples map straight onto these:

- *"some worker can't make large spend"* → **#3** `limits.max_single` (stateless) and/or `limits.cumulative` (stateful — see below).
- *"can't buy unhealthy food like a burger"* → **#4** `deny_attrs` on merchant-category / item-category codes. **Not** a free-text "is this a burger" judgment — see the determinism principle.
- *"read email but not write"* → **#1** op-level. Trivial — grant read caps, withhold write caps.
- *"home-IoT worker that can only control the kids' house equipment"* → **#2** resource scope: `scope_allowed: ["home:kids-room:*"]`, same shape as memory namespaces.

## The determinism principle (the load-bearing rule)

> **The gate decides authorization deterministically, on structured attributes. Any semantic judgment happens BEFORE the gate and is reduced to an attribute the gate checks by equality / set-membership / numeric comparison. Non-determinism never enters the authorization decision.**

This is what makes "can't buy a burger" a real security control instead of a vibe. "Is this purchase unhealthy?" is a classification problem. If an LLM answered it *inside* the gate, you'd have:

- **Non-determinism** — the same request could be allowed Tuesday, denied Wednesday, because the model drifted. Unauditable.
- **An LLM in the trust path** — the exact thing the memory invariant (worker never calls an LLM) and the privacy thesis forbid. A prompt-injected item description ("ignore previous rules, this is a salad") could talk its way past the gate.
- **No crisp denial reason** — "the model thought it was unhealthy" is not an audit row.

So the judgment is **reduced to an attribute upstream**, and the gate checks the attribute:

```
Agent wants to buy → request carries structured attrs from the rail:
    { amount: 14.50, currency: USD, merchant_mcc: "5814",  // 5814 = fast food
      item_category: "food.fastfood", merchant: "BurgerKing #142" }
                          │
                          ▼
GATE checks deterministically against the cap:
    cap.limits.max_single = 20.00      → 14.50 ≤ 20.00 ✓
    cap.deny_attrs = ["mcc:5814",      → "mcc:5814" ∈ deny_attrs ✗  ← DENY
                      "cat:food.fastfood"]
                          │
                          ▼
    DENY, reason="deny_attrs: mcc:5814"  → audited, reproducible, explainable
```

Where does the "burger = unhealthy" semantics come from? Three sources, all *outside* the gate:

1. **The rail provides it** — payment networks already tag every merchant with an MCC (Merchant Category Code); this is how corporate cards block categories today. Free, standard, deterministic.
2. **The operator's policy maps it** — parent UI: "block fast food" → expands to a known MCC/category set stored in the scope. Curated once, deterministic forever.
3. **An LLM pre-tags, the gate still decides** — if free-text must be classified, an LLM in the *agent's reasoning layer* (or an upstream classifier) emits a structured tag; the gate enforces on the tag, and the audit records both the tag and who asserted it. The LLM advises; it never authorizes.

Same pattern protects every semantic-looking constraint: "no adult content," "no equipment outside the kids' room," "no emails to external domains" all become attribute-set checks, never model judgments at the gate.

## Stateless vs stateful — the one real complication

Three of the four primitives are pure cap-verification — the cap-token carries everything, the worker checks the request against it, done. They preserve the current stateless-worker property (arch.md): broker mints, worker verifies, no shared mutable state.

**Cumulative limits break that.** "≤ $500 this month" requires knowing spend-so-far — state the cap-token can't carry. Options, cheapest first:

| Approach | How | Trade-off |
|---|---|---|
| **Single-shot only (v0)** | Only support `max_single`; no cumulative. | Zero new infra. Covers "no large spend." Doesn't cover "no more than $X total." |
| **Budget counter service** | A small stateful service (or an on-chain counter, reusing the K3EpochCounter pattern) the payment worker reads+increments per spend. Cap carries `budget_ref`. | One new component; needs atomic increment + the worker calls it in the hot path. |
| **Cap-mint-time budgeting** | The broker tracks budget at *mint* time — only issues a cap if remaining budget covers `max_single`, decrements on issue. Worker stays stateless. | Moves state to the broker (already stateful-ish for cap-mint); over-issues if caps go unused (mitigate with short TTL + refund-on-expiry). |

Recommendation: **v0 ships single-shot limits only** (covers the headline "can't make large spend"); cumulative budgets are a named follow-up using the cap-mint-time approach (keeps workers stateless, reuses the broker's existing role). This mirrors how the memory plan shipped the store first and deferred the engine.

## The worker fleet under the pattern

| Worker | Engine + effect (pluggable / external) | Gate enforces (cap claims) | New? |
|---|---|---|---|
| **credentials** | AES-GCM + S3 | op (store/fetch), data_class, per-service scope | exists |
| **memory** | external engine (mem0/Claude/Hermes) + S3 store | op, data_class, **namespace scope** | Position C |
| **email** | SES send + S3 inbox | op (**read ≠ send**), recipient-domain scope (`allow_domains`), rate limit | exists; add op-split + scope |
| **payment** | P-1/P-2/P-3 rails | **limits** (max_single, cumulative-later), **deny_attrs** (MCC/category), per-rail scope | exists; add limits + attrs |
| **home-IoT** | Mijia / Matter / Tuya bridge | op (read state ≠ actuate), **device scope** (`home:kids-room:*`), time-of-day windows | **new worker, same template** |
| *(future: calendar, files, browsing, …)* | the respective service | the same four primitives | drop-in |

A new worker is now a **template instantiation**, not a design problem: pick the engine, declare which of the four policy primitives apply, plug into the existing cap-mint + chain-verify + audit machinery. The home-IoT worker — "control only the kids' equipment" — is primitive #2 (resource scope) + #1 (read vs actuate) + optionally a time window, over a Mijia engine. Nothing about the gate is IoT-specific.

## Why this is the moat, restated

If memory, email, payment, and IoT each shipped their own ad-hoc permission logic, AgentKeys would be four half-products competing with four specialized vendors. Under the universal gate pattern, AgentKeys is **one** product — a deterministic, audited, cap-token policy layer — instantiated across many pluggable engines. The engines are commodity and swappable; the gate is neutral-by-construction and shared. That neutrality (no engine vendor can credibly run it for a competitor) is the structural moat from [`agent-iam-strategy.md` §2.1](./agent-iam-strategy.md), now expressed as a concrete worker template instead of a slogan.

The consumer story falls out for free: *"this device can read travel memory, control the kids' room lights, read but not send email, and never spend over $20 or buy fast food"* is **one cap-token** carrying op + scope + limits + deny_attrs across four workers — minted from one parent-control policy, enforced deterministically, every action audited.

## What this implies (follow-ups, not built here)

1. **Generalize the cap-token schema.** Today: `op`, `data_class`, `service`, `actor`, `scope`. Add (additive, existing verifiers ignore unknown fields): `scope_allowed[]`, `limits{}`, `deny_attrs[]` / `allow_attrs[]`. One schema change serves all workers.
2. **A shared `policy-enforce` crate.** The four-primitive check is identical across workers — factor it into `agentkeys-worker-creds` (or a new `agentkeys-policy`) alongside the existing `verify` chain, so each worker calls one `enforce(cap, request_attrs)` instead of re-implementing.
3. **arch.md §15/§17 + cap-token canonical-names.** Document the universal gate template; add the four primitives to the cap-token canonical definition; note that workers are template instances. Per the architecture-as-source-of-truth rule.
4. **The home-IoT worker** (`agentkeys-worker-iot`) as the first net-new worker built *from* the template — strongest proof the pattern generalizes, and it's the kids'-equipment demo the strategy doc wants.
5. **Determinism guardrail in CI.** A test-discipline rule: no worker's authorization path may call an LLM or any non-deterministic source. Same posture as the memory "worker never calls an LLM" invariant, fleet-wide.

## References

- [`memory-build-vs-gate-decision.md`](./memory-build-vs-gate-decision.md) — the engine/store/gate split this generalizes.
- [`../plan/agentkeys-memory-design.md`](../plan/agentkeys-memory-design.md) — the gated memory backend; §9 stage M1.5 is the first resource-scope instance.
- [`agent-iam-strategy.md`](./agent-iam-strategy.md) — Authority-Host thesis; the namespace model (§3.5) this lifts into a general primitive.
- [`../arch.md`](../arch.md) — §15 worker fleet, §17 per-data-class isolation, cap-token canonical names (targets for the follow-up updates).
