# arch.md verification report — #5, #6, #9, #37

**Verified against**: [`docs/arch.md`](../docs/arch.md) at commit `c02e83f` (2026-05-24).
**Rule**: do NOT merge any of these issues, even if the verification says they're good to go. Decisions on close/merge are user-led.

---

## #5 — Pattern 4 audit submission (TEE-as-paymaster per-read sponsored audit)

**Status in repo**: CLOSED (2026-05-23).
**Issue summary**: replace naive cold-first-read audit (~6s/credential) with TEE-as-paymaster pattern where TEE acknowledges the read immediately and submits the audit extrinsic async, paying gas on behalf of the user.

**arch.md state**: §15.3 audit-service worker defines **three audit tiers**:

| Tier | Description | Key trade-off |
|---|---|---|
| **A** (hosted shared relay) | Service provider runs relay; batches across operators; Merkle root on chain | No `current_master_wallet` exposure (only shared service-relay-wallet); operator trusts service not to omit events |
| **B** (self-sovereign) | Not detailed in excerpt; operator runs own batch relay | Self-sovereign without `current_master_wallet` exposure |
| **C** (direct-write per event, default) | Every event independently signed + submitted | Default — strongest tamper-evidence but per-event cost + latency |

**Verdict**: PARTIALLY ALIGNED. The "TEE-as-paymaster + batched Merkle root" pattern from #5 lives on as **tier A**, but the v2 default flipped to **tier C** (direct per-event). #5 was closed without explicit mapping to the tier model — worth a follow-up doc note that "Pattern 4 = tier A with TEE-side gas subsidy."

**Recommendation**: NO ACTION (issue is closed). Optional: add a tier-A migration note to `docs/arch.md` §15.3 if Pattern 4 productization is ever resumed.

---

## #6 — Hybrid on-chain pair transport (replaces rendezvous relay + auth_requests table)

**Status in repo**: OPEN.
**Issue summary**: replace v0 centralized pair relay (SQLite `auth_requests` + `rendezvous_registrations` + 6 HTTP endpoints + long-poll) with on-chain pair transport. Applies same Pattern 4 latency decoupling to the pair flow.

**arch.md state**:
- §6.3 "Identity ≠ actor ≠ machine ≠ capability" — pair flow conceptually centered on link-code from master
- "Cannot rebind without a fresh master-issued link code" (§3 blast radius table for agent machine)
- §K11 / §10 master binding ceremony (line 393): "Master binding ceremony (WebAuthn) — Platform authenticator generates K11; commits D_pub atomically inside WebAuthn challenge `SHA256(binding_nonce || D_pub)`. Master ↔ platform authenticator ↔ broker."
- `SidecarRegistry` on chain holds device-key registrations
- No explicit on-chain pair-extrinsic flow in current arch.md

**Verdict**: COMPATIBLE in spirit, CONFLICTING on specific design. The latency-decoupling intent of #6 aligns with the broader pattern (decouple serve from audit, async chain commit), and the on-chain registration of D_pub fits the SidecarRegistry pattern. BUT the specific design in #6 (TEE-acknowledges-daemon-immediately + async paymaster) predates the K11 WebAuthn enforcement model — arch.md now requires WebAuthn at master mutations, which is incompatible with "TEE stores internally and acknowledges daemon immediately" without a human-presence check.

**Recommendation**: KEEP OPEN, attach `needs-arch-review` + `status/investigating` labels. Before any implementation, refresh the #6 design against current K11 + SidecarRegistry model. Specific reconciliation: where does WebAuthn fit in the pair-request flow? Is paymaster gas subsidy still meaningful when chain anchoring is batched per tier A? **DO NOT merge until design refresh lands as a comment on the issue.**

---

## #9 — Stateless MSK-derived TEE key architecture

**Status in repo**: OPEN.
**Issue summary**: replace per-user random wallet key storage (N sealed blobs in TEE) with Master Secret Key (MSK) derivation — single TEE-held MSK + user identity → derive all user keys on demand. Eliminates N copies of sensitive key material, enables seamless MSK rotation.

**arch.md state**: §6.2 HDKD actor tree describes exactly this design:

```
M_WALLET   wallet_master = HKDF(K3_v[epoch], O_master)
A_OMNI     AGENT actor omnis O_master//agent-A, //agent-B, ...
A_WALLET   wallet_agent_A = HKDF(K3_v[epoch], O_master//agent-A)
```

Quoting arch.md §6.2 directly: *"Hard derivation (`//N`) — child secret cannot be computed without the parent's master secret. Substrate / SLIP-0010 standard. Each node's wallet is a different EVM address; AWS PrincipalTag is per-actor `actor_omni` for prefix isolation."*

**K3 IS the MSK** that #9 proposed. Signer holds `K3_v[1..current]` sealed in TEE enclave (§K3); per-actor K4 wallets are derived on demand from `K3_v[epoch] + actor_omni`. This shipped in **v2 stage 1 (issue #89)** as `wallet_master = HKDF(K3_v[epoch], O_master)`. K3 rotation is already implemented per K3EpochCounter on chain.

**Verdict**: ALREADY IMPLEMENTED. The "N sealed blobs per user" problem #9 described no longer exists in the v2 architecture. K3-based HDKD is exactly the proposed MSK design with slightly different terminology.

**Recommendation**: RECOMMEND CLOSE with a comment pointing to arch.md §6.2 + issue #89. **Do not merge** per user instruction; flag for user close decision. If user wants to keep open for any residual TEE-side hardening details not covered by §6.2, retag with `status/investigating` and reduce scope to that residual.

---

## #37 — Biometric LAContext (PR #27 follow-up)

**Status in repo**: OPEN.
**Issue summary**: PR #27 introduced biometric gate for `approve` / `revoke` / `teardown` CLI actions but macOS path is a stub (logs prompt, returns `Ok(())`). Wire real macOS `LAContext.evaluatePolicy` via `objc2` + `objc2-local-authentication` so Touch ID / Face ID actually gates master CLI actions.

**arch.md state**: §K11 WebAuthn defines the master-mutation gate:
- Per-RP credential (EC P-256 on **macOS Secure Enclave** / Windows TPM / Android StrongBox)
- "Hardware-attested user-presence proof at **master mutations**: scope grant/revoke, device add/revoke, K10 rotation"
- "NOT used per-request — K10 covers per-call signing without biometric"
- K11 credential ID is registered on chain via `SidecarRegistry`

K11 WebAuthn IS Touch ID / Face ID on macOS — it uses the Secure Enclave through the WebAuthn platform-authenticator API. arch.md establishes WebAuthn as the canonical master-mutation gate. The Touch ID prompt that pops up during a WebAuthn ceremony is the same UI the user would see from `LAContext`, but WITH hardware attestation + on-chain credential registration, which `LAContext` alone does not provide.

**Verdict**: SUPERSEDED. The WebAuthn-via-K11 path (§K11 + master binding ceremony in §10) is strictly more secure than bare `LAContext.evaluatePolicy`. The K11 credential is hardware-attested AND pinned on chain via `SidecarRegistry` — both properties #37 cannot offer.

There IS a narrow residual case: agent-side daemons (non-master) have NO K11 ("agents have no human-presence credential" per §6.3 role table). If `approve` / `revoke` / `teardown` need a biometric gate even on agent CLI, that's not covered by K11 and would need a bare-LAContext fallback. But that's a different ask than #37's original scope (which was specifically for master CLI actions).

**Recommendation**: RECOMMEND CLOSE with a comment pointing to arch.md §K11 + the K11 WebAuthn enforcement landed in #89. If the narrow residual case (agent-side bare-biometric fallback) is wanted, open a NEW issue with that specific scope under M5. **Do not merge** per user instruction; flag for user close decision.

---

## Summary table

| # | Verdict | Recommendation | Action by | Block close? |
|---|---|---|---|---|
| #5 | PARTIALLY ALIGNED (tier A in §15.3) | No action — already closed | User | Already closed |
| #6 | COMPATIBLE in spirit, CONFLICTING in design (pre-K11 era) | Keep open, `needs-arch-review` label, requires design refresh before implementation | User decides scope refresh | Yes — refresh needed |
| #9 | ALREADY IMPLEMENTED (K3 HDKD per §6.2) | RECOMMEND CLOSE as superseded by #89 | User | No (close-ready) |
| #37 | SUPERSEDED by K11 WebAuthn (§K11) | RECOMMEND CLOSE; open narrow follow-up only if agent-side bare-biometric is wanted | User | No (close-ready) |

**Reminder**: per user instruction, NONE of these are to be merged in this PM pass. All recommendations require user sign-off before action.
