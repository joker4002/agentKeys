**Status:** decision needed — blocks PR #193. **Scope:** whether/how to reserve a generation suffix on agent omnis (issue #8).

PR #193 implements issue #8 ("v0.1+: generation suffix `/0`, `/1`, `/2` for child key rotation") by changing the child-omni preimage from `child_omni(master, "label")` to `child_omni(master, "label/0")` for **all** agents, generation 0 included. That changes the frozen canonical `agent_omni`, which needs an explicit decision before it can land. This note lays out the options and a recommendation; promote the chosen path into `arch.md` §5/§6.2/§10.2 in the same change that reworks the PR.

## Why this is load-bearing

`actor_omni` is the immutable anchor everything keys off — the S3 prefix `bots/<actor_omni_hex>/`, the AWS `agentkeys_actor_omni` PrincipalTag, the on-chain `ScopeContract` index, and the AEAD AAD. arch.md §5/§6.2 and the [`actor_omni.rs`](../../crates/agentkeys-core/src/actor_omni.rs) module doc both warn this preimage must **never change without bumping every consumer at once**. The §5 canonical row pins:

```
agent_omni = SHA256("agentkeys-hdkd-v1" || O_master || "//<label>")
```

The frozen-anchor property is what makes K3 rotation a **zero-migration** event. Changing the gen-0 preimage to `//<label>/0` changes the anchor for every agent → new prefix, new PrincipalTag, new chain key, re-encrypt. Acceptable only pre-production (no bound agents), and only if done in lockstep across all consumers + docs.

## The real question: do we even want omni-level rotation?

v2 already has two rotation axes that **don't** touch the omni, plus a revoke-and-recreate path:

| Axis | Mechanism | Omni changes? |
|---|---|---|
| K3 epoch rotation | `K4 = HKDF(K3_v[epoch], O_agent)` — rotates every wallet; TEE-compromise response | No |
| Device-key (K10) re-pair | §10.3.2 / §10.4 | No |
| Revoke + fresh-label re-bootstrap | new `//<label2>` → new omni (clean identity) | Yes (new label) |

Omni-level "generation" rotation is a **third** axis: same logical label, new omni. The use case is full agent-identity compromise where you want a clean anchor under the same human-facing name without recycling the base label. It's real but narrow — and it **inherently** breaks zero-migration (new omni = new prefix + new binding + re-encrypt). So it isn't "rotation" in the K3 sense; it's revoke-and-recreate-in-place.

## Options

**A. Ship as-is — always-suffix, gen 0 = `//<label>/0`.**
Changes every canonical derivation; must bump all consumers (S3, PrincipalTag, chain, AAD, §5/§6.2/§10.2) in lockstep. Pro: uniform, suffix always present. Con: changes the anchor for all agents to reserve an unbuilt feature; max blast radius; §5/§6.2 formulas become false until updated.

**B. Gen-0-bare (recommended).**
Generation 0 derives at the plain `//<label>` (today's `agent_omni`, unchanged); only `N ≥ 1` appends `/<N>`. Backward-compatible — existing derivations and the §5/§6.2 formulas stay literally true, no consumer bump for the common case — while still reserving the rotation namespace exactly as #8 asks. Con: derivation has a special case (`generation 0 ⇒ bare label`); rotation code must encode "0 means bare". Concretely: assert `child_omni_generation(m, l, 0) == child_omni(m, l)`.

**C. Don't reserve at the omni layer — handle agent rotation via fresh-label re-bootstrap + on-chain revoke of the old.**
No canonical change, simplest. Con: the human-facing label changes (`agent-a` → `agent-a-v2`), which #8 explicitly wants to avoid.

## Recommendation

**Option B.** It satisfies #8's "rotate without recycling the base label" while preserving the frozen-anchor invariant for every already-derivable omni. Rework #193 to keep `child_omni_generation` but special-case generation 0 → bare label, with the equality assertion above as a test.

## arch.md updates required (same change as the code)

- **§6.2** — document the suffix: `O_master//<label>` for gen 0; `O_master//<label>/<N>` for rotations `N ≥ 1`; note gen 0 is bare for backward-compat.
- **§5** `agent_omni` row — add the generation note; keep the gen-0 formula unchanged.
- **§10.2 / §10.4** — at the agent (re-)bootstrap description, add the rotation-by-generation path and state plainly that it produces a **new** omni (new prefix/binding; **not** zero-migration, unlike K3 rotation).
- Note on-chain `current_generation` storage as a reserved follow-up (deferred per the PR).

## Open questions for the human

1. Is omni-level rotation in scope now, or is K3-epoch + device re-pair + fresh-label re-bootstrap enough? (If enough → close #193, keep #8 as a future reservation.)
2. If in scope: confirm Option B (gen-0-bare) over A (always-suffix).
3. Pre-production check: are there **any** agents bound on-chain / with S3 data today whose omni Option A would invalidate? (If yes, A is off the table regardless.)
