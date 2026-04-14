# Design doc — #5 Pattern 4 audit submission (TEE-as-paymaster)

**Status:** DRAFT — awaiting human + Kai sign-off.

**Scope:** v0.1 on-chain audit submission for AgentKeys on Heima. Target first-read latency ~50 ms without sacrificing the tamper-evident on-chain audit property.

## Problem (recap)

Every credential read on Heima is an extrinsic → on-chain audit event. This is AgentKeys's core differentiator vs 1Password. Cost = ~6 s block time per read = 3 minutes of wait time over a 30-read agent task. Unacceptable.

## Pattern 4 (chosen)

```
CLI reads credential
  ↓
CLI signs read_credential extrinsic with session key
  ↓
TEE verifies session signature + scope (~10 ms)
  ↓
TEE decrypts credential (~5 ms)
  ↓
TEE returns credential to CLI                  ← user sees this (~50 ms total)
  ↓
  ──── decoupled hereafter ────
  ↓
TEE builds audit extrinsic signed_by(user_wallet)  ← user's wallet (TEE-held,
                                                     pallet-bitacross pattern)
  ↓
TEE submits via paymaster (operator-funded)    ← fees NOT paid by user
  ↓
──── ~6 s ──── audit extrinsic confirms on chain
  ↓
Audit event visible on block explorer
```

**Key architectural move:** signer ≠ payer. User wallet signs (so on-chain audit attributes correctly); operator treasury pays (so user has no top-up UX).

## Pattern comparison (locked — don't relitigate)

| Pattern | First-read | Audit onchain | Chain fees | Complexity |
|---|---|---|---|---|
| Cold-first-read (naive) | ~6 s | synchronous | per read | simplest |
| 1: TEE-batched async | ~50 ms | async, ~10 s | batch | medium |
| 2: Merkle-committed log | ~50 ms | async, per-root | 1 hash per batch | medium |
| 3: CLI fire-and-forget | ~50 ms | best-effort | per read | insecure |
| **4: TEE paymaster** | **~50 ms** | **async, ~6 s** | **per read, paymaster** | **medium** |

## Fee funding — Option A (v0.1 default)

| Option | Notes |
|---|---|
| **A. Operator treasury** | Chosen. Works today with no Heima runtime changes. Matches hosted service model. |
| B. Heima protocol ("free calls") | Most elegant. Blocked on Heima runtime change; revisit later. |
| C. User wallet USDC balance | Opt-in mode for self-hosted deployments; mixes identity + gas payment, confusing UX. |

## Hard prerequisite — rate limit (issue #4)

**Do not merge Pattern 4 without issue #4 (per-session read rate limit) in place.** Otherwise an abusive session drains the treasury within seconds.

Default: 100 reads/minute/session, token bucket, configurable per session, enforced at TEE (v0.1) and mock backend (v0).

## Deliverables

### Heima TEE worker (coordinate with Kai)
- [ ] Paymaster-funded audit submission — custom `SignedExtension` or equivalent pattern.
- [ ] Decoupled serve/audit code path — `read_credential` returns plaintext before audit is submitted.
- [ ] Audit submission failure handling — **needs design decision** (see Deferred Decision 3 below). Candidates: retry+backoff, pending queue, circuit-break reads, local-log-and-flush-later.
- [ ] Audit event format: `{ wallet, agent_id, service, timestamp, block_number, session_id, result }`. Indexable by Subsquid.
- [ ] Paymaster treasury account setup + monitoring tooling.

### AgentKeys-core
- [ ] `CredentialBackend` trait unchanged.
- [ ] New `BackendCapabilities` struct: `{ supports_sponsored_audit, audit_on_chain, expected_read_latency_ms }`. CLI uses it for UX hints.

### CLI
- [ ] Happy path unchanged.
- [ ] Optional `--sync-audit` flag for users who want cold-first-read semantics (nice-to-have).
- [ ] Surface rate-limit errors clearly (lives in #4).

### Operational
- [ ] Paymaster treasury dashboards (balance, burn rate, rejected-for-insufficient-funds, per-user audit count).
- [ ] Alerts on balance < N days projected spend.
- [ ] (Optional) Per-user audit-fee budget cap on top of the rate limit.

### Documentation
- [ ] `wiki/key-security.md` — Pattern 4 as the v0.1 default + latency budget table.
- [ ] `docs/spec/plans/development-stages.md` Stage 9 — convert design notes → concrete deliverables as pieces land.

## Acceptance criteria

- First `read_credential` < 100 ms end-to-end (CLI submit → plaintext returned).
- Audit event on block explorer within ~10 s.
- Paymaster treasury covers all submissions — no user-visible fee prompts.
- Rate limit (#4) rejects excess reads with a structured error.
- On paymaster failure: audit events are retried or surfaced to the operator — never silently lost.
- All existing credential-read tests pass under the Pattern 4 code path.

## Deferred decisions (must resolve before implementation)

1. **Cross-pattern mixing.** Ship Pattern 4 as default with an opt-out `--sync-audit` flag? Lean YES.
2. **Paymaster DoS defense beyond rate limiting.** Per-user audit-fee budget cap? Lean YES for hosted, NO for self-hosted.
3. **Audit-submission failure strategy.** Retry + backoff, pending queue, circuit-break, local log + flush later — pick a default + write it up before coding. **Blocker for implementation.**

## Sequencing

1. **This design doc sign-off.**
2. **Issue #4 (rate limit) ships first** — prerequisite for Pattern 4 safety.
3. **Kai reviews paymaster pattern** feasibility on Heima's current TEE worker architecture.
4. **Resolve Deferred Decision 3** (audit failure strategy) — write a mini design addendum.
5. **Implementation** — Heima TEE worker mods, AgentKeys-core capability exposure, CLI UX.

## Open questions for reviewer

1. **@Kai** — is the custom `SignedExtension` / meta-transaction pattern feasible on Heima's substrate runtime without new pallet primitives?
2. **Paymaster treasury account setup** — ops-owned or AgentKeys-repo-owned? Who monitors balance?
3. **Rate-limit + budget cap interaction** — if a user exhausts their monthly audit-fee budget mid-session, do we hard-fail subsequent reads, degrade to cold-first-read, or let them continue and eat the cost?
4. **Pattern 4 + hosted vs self-hosted** — we've designed for the hosted model. Self-hosted operators can run their own paymaster; does the design cleanly parameterise on that, or do we need separate paths?
5. **Audit replay / idempotency** — if the TEE submits a retry and the original eventually lands, we get double audit events. Do we need a nonce-tracked idempotency key in the pallet, or is best-effort single submit enough?

## References

- GitHub issue [#5](https://github.com/litentry/agentKeys/issues/5)
- `wiki/key-security.md` — full pattern comparison + investigation notes
- `docs/spec/plans/development-stages.md` Stage 9 — design decisions holding pen
- `docs/spec/heima-cli-exploration.md` — audit-as-extrinsic model + latency acknowledgement
- `docs/spec/1-step-analysis.md` — pallet-bitacross TEE-held wallet-key pattern (enables signer/payer decoupling)
- Issue #4 — per-session read rate limit (hard prerequisite)
- Issue #3 — Stage 8 hardening (adjacent)
