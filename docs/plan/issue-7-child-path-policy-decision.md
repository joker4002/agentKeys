**Status:** decision needed — blocks PR #197. **Scope:** where child-path access policy lives and what authority it holds (issue #7).

PR #197 implements issue #7 ("v0.2+: TEE-side access control / security groups for child paths") as a broker-side SQLite `child_path_policies` table: default-deny, activated at pairing-claim, with suspend/resume endpoints, gating **OIDC-JWT minting** ([`handlers/oidc.rs`](../../crates/agentkeys-broker-server/src/handlers/oidc.rs) `check_child_path_policy`). The parent-control UI labels it "TEE child path policy." Three things need a decision before it lands; promote the outcome into `arch.md` §13/§16 in the same change that reworks the PR.

## Three problems vs arch.md

1. **Layer/name mismatch.** Issue #7 says *"TEE-side"*; the PR is **broker-side** (SQLite), gating JWT mint. The broker is not the TEE — arch.md §14 defines the TEE as the signer enclave. Labeling broker state "TEE child path policy" violates the terminology-source-of-truth rule (CLAUDE.md) and misleads operators about where enforcement actually lives.
2. **Authority overlap with the chain.** arch.md §16 makes the **on-chain layer the single source of truth** for capability/scope. Agents already get **no scope until the master approves on-chain** (§10.2 step 13 + §6.3), so default-deny is already the posture. #197 adds a *second*, off-chain default-deny gate at JWT-mint. Is it a **cache** of on-chain state, or an **independent authority**? The PR doesn't say.
3. **Undocumented trust surface.** arch.md §13.1 (broker responsibilities) and §13.2 (what the broker does NOT do) don't mention a broker-held path policy or a JWT-issuance suspend/resume control. Any new broker authority has to be written into arch.md, or it's invisible to the threat model.

## What's genuinely new and worth keeping

**suspend/resume** = pause/resume JWT issuance for a child path **without an on-chain tx**. On-chain revoke costs a tx + a K11 gesture; this is an instant, broker-local kill-switch. That's a real operational gap (fast incident response) worth filling — it's the part of #197 that isn't already covered by the on-chain scope gate.

## Options

**A. Broker-side enforcement cache + operational pause (recommended).** Keep the broker implementation but reframe it as a **bounded** authority:
- "active / default-deny" = a fail-closed mirror of "no on-chain scope yet" (defense-in-depth at mint; can never *grant* beyond on-chain scope).
- "suspended" = a broker-only fast-pause that does **not** replace on-chain revoke (the chain stays the source of truth for permanent state).
- **Rename off "TEE"** everywhere (UI label, `types.ts`, handler/table naming) → "broker child-path policy".
- Document the bounded authority in arch.md §13.

**B. Move enforcement to the signer/TEE (literal #7).** The signer holds the path policy. Heavier; only justified if the policy must survive **broker compromise**. Defer unless the threat model demands it.

**C. Make it purely on-chain** (a `suspended` bit in `ScopeContract`). Most aligned with §16, but slow (tx + K11 per toggle) — defeats the fast-kill-switch value that motivates the feature.

## Recommendation

**Option A.** Keep the broker-side code, but: (1) **rename away from "TEE"** in UI/types/handlers; (2) frame it as a bounded broker authority — fail-closed cache + operational pause, **never a grant**; (3) document it in arch.md §13 + a note in §16 that the chain remains the source of truth for permanent scope and the broker pause is a revocable operational overlay; (4) keep suspend/resume, and emit an **audit row** on every suspend/resume so the off-chain pause is still attributable.

## arch.md updates required (same change as the code)

- **§13.1** responsibilities — add: "holds a per-child-path operational policy: a fail-closed default-deny mirror of on-chain scope, plus a suspend/resume pause for JWT issuance. Cannot grant beyond on-chain scope."
- **§13.2 / §16** — state plainly that the broker pause does **not** mutate on-chain scope; permanent revoke stays on-chain; the chain remains the single source of truth.
- **§5** canonical names — if a name is kept, pin it as **"broker child-path policy"** (retire "TEE child path policy" as a wrong-layer alias).

## Open questions for the human

1. Confirm Option A (broker-side, renamed, bounded) vs. the literal TEE-side framing in #7's title.
2. Should "suspended" eventually get an on-chain counterpart for durable auditability, or is broker-local + an audit row enough?
3. Naming sign-off: "broker child-path policy"?
