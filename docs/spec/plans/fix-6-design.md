# Design doc — #6 Hybrid on-chain pair transport

**Status:** DRAFT — awaiting human + Kai sign-off.

**Scope:** Replace the v0 centralized pair relay (`rendezvous_registrations` + `auth_requests` tables + 6 handlers + long-poll state machine) with on-chain pair transport, using Pattern 4 decoupling (serve immediately, audit async via paymaster) to keep pair latency ~50 ms.

## Motivation

Once credential audit moves on-chain under Pattern 4 (#5), the pair relay becomes the only remaining centralized state. Architecturally inconsistent and operationally duplicative. Replace with on-chain pair transport.

## Architecture

```
Phase 1 — Daemon bootstraps
    daemon → ephemeral keypair
    daemon → submit PairRequest { daemon_pubkey, scope, alias, nonce, valid_until, parent_wallet } to TEE
    TEE → validate + store internally + ACK daemon immediately (~50 ms)
    TEE → asynchronously submit PairRequest extrinsic to chain (paymaster-funded)
    daemon → display: scope, alias, daemon_pubkey_fingerprint, VVC (client-derived from signature), valid_until

Phase 2 — Master approves
    master CLI → query chain/TEE for pending pair requests for its wallet (soft time window)
    master CLI → display list (scope, alias, fingerprint, VVC, age)
    user → visually compare VVC + details with daemon display, pick matching entry
    master CLI → submit ApprovePair { pair_request_id, encrypted_child_session } to TEE
    TEE → mint child session + return to daemon immediately (~50 ms)
    TEE → asynchronously submit ApprovePair extrinsic to chain (paymaster-funded)

Phase 3 — Daemon receives
    daemon → decrypt child session with its own ephemeral private key
    daemon → store session, begin serving MCP
```

## Four design refinements (from issue body, locked)

1. **VVC is client-derived, not on-chain.** Deterministic function of the extrinsic signature (e.g., first 6 digits of `SHA256(signature)` mod 10^6). No on-chain OTP field; any client reproduces the same code.
2. **Full request details displayed.** Approve list shows scope, alias, daemon pubkey fingerprint, VVC, valid_until. User inspects exactly what they approve.
3. **TTL as a first-class on-chain field.** `valid_until` (block number or timestamp) is part of the extrinsic; pallet rejects expired approvals at the protocol level.
4. **Latency decoupled (Pattern 4 consistency).** TEE ACKs synchronously, chain extrinsic lands asynchronously. Pair latency ~50 ms; ~6 s audit lag, consistent with the credential-read flow.

## Decoy attack — why VVC is required

Without a visual tiebreaker, an attacker can submit a decoy pair request to the same master wallet; the master CLI shows both entries; the user can't distinguish the legitimate daemon from the attacker. Signatures prove authenticity and integrity of *each* request — but not *which is mine*. VVC matching between daemon and master is the user's only visual signal.

## What this removes

~665 LOC removed from mock-server, ~200 LOC added for chain-event simulation → net ~465 LOC reduction:
- `rendezvous_registrations` table + 3 handlers (register/poll/deliver)
- `auth_requests` table + 4 handlers (open/fetch/approve/await_decision)
- Registration-token management + SQL TTL enforcement

## Deliverables (from issue #6 body)

### Heima pallet (Kai review required)
- [ ] `PairRequest` + `ApprovePair` extrinsic types
- [ ] `PairRequestOpened` / `PairRequestApproved` / `PairRequestExpired` events
- [ ] TTL enforcement at pallet level (`current_block > valid_until` → reject)
- [ ] Indexable by `parent_wallet` for efficient master CLI queries

### TEE worker
- [ ] Decoupled pair-request + approval processing (ACK immediately, submit extrinsic async via paymaster)
- [ ] Rate limit pair requests per wallet (reuse issue #4 infrastructure)
- [ ] Pending-queue for async submission failure handling

### CLI
- [ ] `agentkeys approve` queries chain/TEE for pending requests
- [ ] Full-detail list display with VVC
- [ ] Soft time-window filter (default last 5 minutes)
- [ ] Single-request auto-select (UX polish)

### Mock backend (v0 migration)
- [ ] Remove `rendezvous_registrations` + 3 endpoints
- [ ] Remove `auth_requests` + 4 endpoints
- [ ] Add mock chain-event simulator matching on-chain API shape
- [ ] Update Stage 4 tests to the new flow

### Docs
- [ ] `wiki/serve-and-audit.md` — pair transport section
- [ ] `docs/manual-test-stage4.md` — pair flow tests
- [ ] `wiki/key-security.md` — cross-references

## Acceptance criteria

- Daemon pairs with master using only chain events — no rendezvous relay, no auth_requests.
- Pair latency < 200 ms.
- Pair audit events appear on chain within ~10 s.
- Expired requests rejected at pallet level.
- Two different pair requests → different VVCs.
- Decoy attack: master CLI shows both, user visually distinguishes via VVC.
- All Stage 4 tests adapted and passing.

## Sequencing

1. **This design doc sign-off** (the current PR).
2. **Pattern 4 infrastructure (#5)** must ship first — this design depends on paymaster + decoupled serve/audit.
3. **Rate limit (#4)** shipped — reused for pair-request spam defense.
4. **Heima pallet** — Kai-owned, upstream work.
5. **TEE worker** — Kai-owned, upstream work.
6. **AgentKeys-side** (CLI + mock migration + docs) — this repo, follows Heima.

## Open questions for reviewer

1. **Pallet feasibility.** Is the `PairRequest`/`ApprovePair` extrinsic shape acceptable to the Heima pallet design? @Kai.
2. **VVC collision probability.** 6 digits → 10^6 possible codes. Under peak pair-request rates (say 100 requests/minute to a popular master), what's the acceptable collision rate? Do we need 8 digits?
3. **Soft time-window default.** 5 minutes. Is that right? Users on slow connections might see a pair request disappear before they can approve.
4. **Encrypted child session blob size.** Child session JSON encrypted to daemon_pubkey — what's the payload size? Does it fit on-chain comfortably, or do we need a hash-and-fetch model?
5. **Pattern 4 failure handling.** If the async extrinsic submission fails after the daemon/master already has the session, what's the recovery? Retries forever? User-visible warning? Document the semantics.

## References

- GitHub issue [#6](https://github.com/litentry/agentKeys/issues/6)
- `docs/spec/plans/development-stages.md` Stage 9 — "Hybrid on-chain pair transport" decision
- Issue #5 — Pattern 4 audit submission (prerequisite)
- Issue #4 — Rate limit (prerequisite)
- `wiki/serve-and-audit.md` — Pattern 4 background
- Current v0 implementation to be removed:
  - `crates/agentkeys-mock-server/src/handlers/auth_request.rs`
  - `crates/agentkeys-mock-server/src/handlers/rendezvous.rs`
  - `crates/agentkeys-cli/src/lib.rs:372-444` (cmd_approve)
