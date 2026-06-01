# 9-step operator flow — plan, verification, and pushback

**Status:** plan + implementation (design port + pushback #2 now wired). Source design: Claude Design handoff `agentkeyweb` (onboarding / memory / pairing / permissions / tx-decode).
**Backend merged into this branch:** #159 (§10.2 **agent-initiated** pairing, method A), #149 (HDKD agent bootstrap — superseded front-half by #159), #146 (memory build-vs-gate Position C), #141 (wire/hook), #137 (AuditEnvelope v1 CBOR vectors), #138 (CI hardening).
**Defers to:** [`overview.md`](overview.md) (Authority/Task-Host model), [`stage3-agent-usage.md`](stage3-agent-usage.md), [`data-model.md`](data-model.md), [`docs/arch.md`](../../arch.md) §10.2 / §22c / §22d.

> **Update (this PR, after #159 merge):**
> - **Pushback #1 (pairing direction) — RESOLVED upstream by #159.** §10.2 is now agent-initiated (method A): the agent *shows* a one-time pairing code; the master *claims* it (`POST /v1/agent/pairing/claim`, J1_master-gated) → reviews the device → one Touch ID submits `registerAgentDevice` + `setScopeWithWebauthn`. This matches the design's "agent broadcasts a code" intuition. The pairing-page copy is aligned to this; full daemon-proxy wiring of claim/pending/bind is the next step (broker reachable required).
> - **Pushback #2 — IMPLEMENTED in this PR (was: narrated).**
>   - *Onboarding WebAuthn is real.* `OnboardingScreen` runs a genuine `navigator.credentials.create()` via the daemon `POST /v1/k11/enroll/{begin,finish}` (PR-B) through the `lib/client` seam when a daemon is configured; it shows a "K11 enrolled · real WebAuthn" chip. Offline (EmptyBackend) it falls back to the narrated scan so the demo still runs.
>   - *Memory plant is real + idempotent.* New daemon ui-bridge endpoints `GET /v1/master/memory` + `POST /v1/master/memory/plant` with **server-side content-hash dedup** (re-planting the same content is a no-op; changed body → new entry) + 3 Rust unit tests. The UI auto-detects existing memory on load (`listMasterMemory` → hides the plant button) and plants via `plantMemory` (server dedups), with a seed fallback offline.
> - **Pushback #3 (audit decode) — still a mock**, tracked in [#153](https://github.com/litentry/agentKeys/issues/153) per the user's scope ("just 2").

## The 9 steps the user specified

1. Login with WebAuthn → onboarding ceremony with a progress bar + live text log.
2. Memory panel: see memories; if none, a **plant preserved memory** button; auto-detect existing memory (hide the button); programmatically prevent duplicate plants.
3. On another machine, the user creates a new **Hermes** agent and tries to connect to the master.
4. Master side: a notification (or refresh-triggered) shows a pairing request.
5. Click the request → agent info + requested permissions (e.g. memory).
6. Accept pairing → Touch ID authorizes.
7. Pairing ceremony with a progress bar + process text.
8. On complete: paired device visible in the dashboard, with a **device view** and a **permission view**.
9. Audit messages + their Heima TXs, decodable.

## Verification — each step against the merged backend

| # | Step | Backend reality after merge | Shippable now? |
|---|---|---|---|
| 1 | WebAuthn onboarding ceremony | Real K11 enroll exists (`/v1/k11/enroll/{begin,finish}`, daemon `ui_bridge.rs`, PR-B). The *rest* of the ceremony (createOmniAccount, registerMasterDevice, vault provision, contract verify) are harness shell steps, **not** web endpoints. | **UI now** (real WebAuthn + narrated backend steps); real wiring = Phase 2 (`data-model.md` onboarding endpoints). |
| 2 | Memory plant + dedup | Real memory worker exists (MCP `memory.put`/`memory.get`, S3). #146 settled the build-vs-gate question. Dedup = content-hash. Needs daemon `GET /v1/master/memory` + a plant endpoint. | **UI now** (seed + idempotent dedup guard); real wiring = Phase 2. |
| 3 | Agent creates + connects | **Real, shipped by #149**: `agentkeys agent create` (master mints a one-time link-code bound to the HDKD child omni) → agent `agentkeys-daemon --init-link-code <code>` generates its own K10 in the sandbox + redeems → broker records a **pending binding**. | **Real backend exists.** UI demo seeds the request. |
| 4 | Master notification of request | **Real, shipped by #149**: `GET /v1/agent/pending-bindings` (master polls). This is the notification source. | **Real backend exists.** UI = bell + poll. |
| 5 | Request detail (agent + perms) | Pending-binding record carries child omni + device pubkey + requested services. | **Real backend exists.** |
| 6 | Accept + Touch ID | Master binds (`heima-agent-create --from-pubkey` → `registerAgentDevice`) + grants (`heima-scope-set --webauthn` → `setScopeWithWebauthn`, one Touch ID). | **Real backend exists** (shell + cast today; CLI `agent create`/`pending` added). |
| 7 | Pairing ceremony progress | The two on-chain txs (bind + grant) + cap-mint. | **UI now** (CeremonyRunner over the real step list). |
| 8 | Device view + permission view | Dashboard from the actor tree / SidecarRegistry + AgentKeysScope. | **UI now** (seed); real read = `/v1/actors` (PR-C). |
| 9 | Audit + decodable Heima TXs | #137 shipped the **AuditEnvelope v1 CBOR** cross-language vector exporter; calldata→function decode needs an ABI decoder. No web decode endpoint yet. | **UI now** ships a mock `decodeCalldata` (kind→selector+signature); real decode = the new GH issue below. |

## Pushback — three things the user should know before we call this "real"

1. **Pairing direction is inverted between the design and #149.** The design narrates *"the agent broadcasts a pair-code; the master discovers it."* #149's real ceremony is the opposite: **the master creates the link-code first** (`agent create`), hands it to the agent, the agent redeems it, and *then* a pending binding appears for the master to approve. The polling + accept + Touch ID half is identical; only the code's origin differs. **Recommendation:** align the UI to #149 — the "pairing request" the master sees is a *pending binding* (agent redeemed a code), and "create agent" mints the code the operator gives the new machine. The implemented demo keeps the design's request-card UX but the plan + data-model treat the request as a pending binding. Confirm you're OK with this reconciliation.

2. **Onboarding + memory-plant backends are not web endpoints yet.** Real WebAuthn enroll is live, but createOmniAccount / registerMasterDevice / vault-provision / memory-plant are harness shell steps. For M1 the UI runs the *real* WebAuthn assertion and **narrates** the remaining steps (honest ceremony, not faked success). Real wiring is the Phase-2 daemon endpoints already specced in [`data-model.md`](data-model.md). This matches the existing Phase-1/Phase-2 split — no new deferral, just naming it.

3. **Audit decode needs a real library, not the mock.** The UI ships a deterministic mock (`decodeCalldata`: event-kind → 4-byte selector + function signature; `txHash`: deterministic hash). Real decoding has two halves — (a) **CBOR `AuditEnvelope`** decode (vectors shipped in #137; needs a TS/Rust decoder surfaced to the UI), (b) **EVM calldata → typed args** against the four contract ABIs. Tracked as a **separate GH issue — [#153](https://github.com/litentry/agentKeys/issues/153)**. The UI's decode panel is wired so swapping the mock for the real endpoint is a one-function change.

## What this PR implements (the design port)

Faithful port of the Claude-design 9-step flow into `apps/parent-control` (Next.js), as the **primary, demoable operator experience** driven by seed data + local ceremony state (exactly the prototype's model). Real-daemon wiring stays behind the existing `lib/client` seam and is Phase 2.

- `globals.css` — new blocks: ceremony/clog, onboard, empty-memory, pair-req, view-toggle, device-grid/card, bell+badge, tx-decode, mem-body, perm-* (mobile-style scoped permission list, **no tables**).
- `lib/demoData.ts` — `ONBOARDING_STEPS`, `PAIRING_STEPS`, `PRESERVED_MEMORY`, `INCOMING_PAIRING`, `CHAIN_PROFILE`, `MASTER_DEVICES`, `txHash`, `decodeCalldata`, seed actors/events + types.
- `_components/ceremony.tsx` — `CeremonyRunner` (progress bar + live step log + per-step tx hashes) + `OnboardingScreen` (WebAuthn login → ceremony).
- `_components/memory.tsx` — `MemoryPage` (empty state + plant button, plant ceremony, dedup guard, per-namespace listing).
- `_components/pairing.tsx` — `PairingPage` (incoming request card → accept → Touch ID → ceremony; device view + permission view toggle).
- `_components/permissions.tsx` — `PermissionList` / `PermissionView` / `PermSeg` / `PermSwitch` (mobile scoped permissions — the "tables won't scale" ask).
- `App.tsx` — onboarding gate (localStorage), header bell with pending-request badge, memory/pairing routes, tx-decode modal in the event detail (step 9).

## Sequencing (after this port lands)

- **P2.1** Daemon endpoints for steps 1–2 + 8 reads (onboarding state, master memory list + plant, actor tree) — `data-model.md`.
- **P2.2** Wire pairing to #149: `agent create` (mint code), `GET /v1/agent/pending-bindings` (bell poll), bind + grant on accept. Reconcile direction per pushback #1.
- **P2.3** Real audit decode ([#153](https://github.com/litentry/agentKeys/issues/153)) — swap the mock `decodeCalldata`.
- **P2.4** Remove seed data behind the client seam once endpoints exist (mirrors the PR-A empty-state discipline).
