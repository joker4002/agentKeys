# deferred-and-followups · what stays shell · open questions · sequencing

## §1 — Stays shell-only (intentionally not in the web UI)

Some harness flows are operator-cluster admin or SRE concerns, not parent-facing. They will never get a screen.

| Flow | Source | Why not in UI |
|---|---|---|
| `scripts/heima-bring-up.sh` (chain genesis) | one-off per operator deployment | run by SRE who controls the deployer wallet + sudo authority; the parent operator inherits the running chain |
| `scripts/setup-broker-host.sh --upgrade` (EC2 / nginx / certbot) | per-deployment infra mgmt | infrastructure layer; lives behind the broker URL the parent operator uses |
| `forge test` (28 stage-2 contract tests) | CI gate | engineering quality gate; runs in `.github/workflows/harness-ci.yml` |
| `cargo test --workspace` | CI gate | engineering quality gate |
| `harness/v2-stage3-demo.sh` in CI | required check on every PR | retained as the *gate* that proves isolation can't regress unnoticed; the web UI's isolation health check is a complement (operator-visible verification), NOT a replacement |
| K3 epoch rotation (`docs/runbook-k3-rotation.md`) | rare operator ceremony | today shell-only; web promotion is M5+ ("rotate keys" button → 2-of-2 quorum) |
| `awsp` profile switching | OS-level shell helper | not a parent concern |

These flows are referenced from the web UI when relevant (e.g. the cloud-provision screen says "if this fails, run `scripts/setup-broker-host.sh --upgrade` on the broker host"), but the UI never invokes them.

## §2 — Operator-power-user escape hatches

For the engineer / SRE who wants to bypass the wizard:

| Escape hatch | Where | When to use |
|---|---|---|
| `POST /v1/onboarding/skip { steps: [...] }` | daemon endpoint, only enabled when `AGENTKEYS_OPERATOR_ROLE=admin` in daemon env | when the operator ran the shell scripts manually and wants the UI to acknowledge that state |
| `AGENTKEYS_CLOUD_PROVISIONED=1` | daemon startup env | operator-cluster admin pre-provisioned the buckets/roles; the UI skips screen C |
| `AGENTKEYS_CHAIN_BOOTSTRAPPED=1` | daemon startup env | contracts already deployed (`scripts/operator-workstation.env` has the addresses); the UI skips the contract-deploy half of screen D |
| `agentkeys` CLI | every flow | every endpoint the UI uses is also reachable via the existing CLI; an SRE can complete onboarding from terminal and the UI picks it up on next visit |

**Discipline:** these flags are *opt-in privileges*, not defaults. A new-to-AgentKeys operator running the deployed web UI sees the full wizard and provisions their own resources. The flags exist so a power user isn't forced to click through screens for state they already established.

## §3 — Open questions for review

These are the decisions that need an answer before implementation begins.

### Q1 — Onboarding screen merging

Stage-1 has 6 screens (A through F). Some could be merged for fewer clicks:

- A (identity) + B (passkey): the operator types email + immediately enrolls passkey on the same screen, since the daemon needs `binding_nonce` from A to drive B anyway.
- C (cloud) + D (chain): both are "the system stands up infrastructure for you". Operator might see one combined "provisioning" screen.

**Tradeoff:** fewer screens = less context-switch, but each screen has distinct failure modes that benefit from being separated (cloud failure ≠ chain failure ≠ identity failure). The plan currently keeps them separate; review may collapse.

### Q2 — Pair flow JWT lifetime

`docs/plan/web-flow/data-model.md` §"Second-master pairing" sets 10 minutes. The harness uses 10 minutes (per `v2-stage2-demo.sh`). UX-testing might find that's too long (operator wanders off) or too short (operator gets blocked by an OS update on the companion device). Defer until first usability test.

### Q3 — Cross-browser passkey behavior

WebAuthn credentials are RP-bound and origin-bound. A passkey enrolled in Safari is not visible to Chrome on the same Mac (unless both surface iCloud Keychain). The wizard must:

- Detect when the operator is in a browser without their existing passkey and prompt them to switch.
- Fall back gracefully: option to "use a security key" or "use your phone via cross-device hybrid transport".

This is a substantial sub-design that isn't in the current plan. Tracked here for the implementation phase.

### Q4 — What happens if the operator changes their email later

The plan treats the operator's login email as *Real, account-lifetime*. Changing it is a master-mutation that ripples through:

- broker DB rebinding (email → actor_omni)
- chain `SidecarRegistry.master_devices[O_master]` does NOT change (actor_omni is derived from email but the chain stores the hash, not the email)

A "change my email" flow exists in arch.md §10's identity-rebinding ceremony but is out of scope for v0. Defer.

### Q5 — Multi-operator handoff

One operator's UI session showing another operator's data is forbidden (per arch.md §17 isolation). But what about a shared-team workflow where two operators collaborate on a single AgentKeys deployment (e.g. parent + co-parent each manage the same FoloToy bear)?

Not addressed in the harness. Tracked here for a M5+ feature: multi-operator-per-deployment.

### Q6 — Anchor verification flow

stage-3 §2.3 mentions the operator can verify any tier-1 event against its tier-2 Merkle root. The UI currently links out to an explorer. A future "verify on-chain" button in the audit-row modal would:

1. Take the event's `cap_token_id`.
2. Look up the 2-min batch that contains it.
3. Recompute the Merkle path locally in the browser.
4. Show the operator: "this event's path is `[h1, h2, h3]`, root is `0x7e3f…`, chain root at block X is `0x7e3f…`, match ✓".

This is a real product value (the operator can prove integrity without trusting the daemon). Tracked for post-v0.

## §4 — Implementation sequencing if approved

The plan above is broken into tasks the implementation work can pick up in order. The sequencing isn't a guarantee — open questions may force re-ordering — but it's the proposal.

### Phase D — onboarding state machine + cloud provision (1.5 days)

- new daemon endpoint `GET /v1/onboarding/state`
- new daemon endpoint `POST /v1/onboarding/cloud/provision` + SSE stream — orchestrates the four existing `scripts/provision-*.sh`
- new daemon endpoint `POST /v1/onboarding/cloud/smoke`
- UI: screen C (cloud) lands as a real wizard step replacing the PR-B stub
- Rust unit tests for the new endpoints (per the discipline established in PR-B/C)

### Phase E — identity + chain bring-up (2 days)

- new daemon endpoints `POST /v1/auth/email/{start,verify,status}` proxying the broker
- new daemon endpoints `POST /v1/onboarding/chain/{deploy,register-master}`
- new daemon endpoints `POST /v1/k11/assert/{begin,finish}` (decoupled K11 assertion path)
- UI: screens A (identity), B (passkey, refactored from PR-B's existing flow), D (chain) become live
- Rust unit tests + integration tests against a local anvil chain

### Phase F — agent lifecycle (1 day)

- new daemon endpoints `POST /v1/agents/bootstrap/{this-device,remote,vendor}` + `GET /v1/agents/pair/status` + `POST /v1/agents/create`
- shipped endpoints (PR-C `/v1/actors/:id/scope`, etc.) get extended to take `k11_assertion_id`
- UI: screens E (first agent) becomes live; "add agent" in steady state works

### Phase G — second-master pairing + recovery drill (2 days)

- new daemon endpoints for `/v1/onboarding/pair/*` and `/v1/onboarding/drill/*`
- two-assertion-bundle support in the daemon
- UI: stage-2 screens G, H, I, J, K, L (Act 2)

### Phase H — isolation health check (1 day)

- new daemon endpoints `/v1/isolation/*`
- background runner that drives the 16 stage-3 steps against the operator's real cloud
- UI: stage-3 §3 `/isolation-demo` screen
- Rust unit tests verifying the runner's expectations match the harness's

### Phase I — email worker integration + actor-detail polish (0.5 day)

- new daemon endpoints `/v1/agents/:id/email{,/:msg_id}`
- UI: agent inbox visibility on actor-detail page

### Phase J — coverage gate strict + docs sync (0.5 day)

- bump `--fail-under-lines` from 60% to whatever the new daemon code's coverage is
- update arch.md §22c.1 with the new ui-bridge endpoints
- archive obsolete sections of the prototype + initial implementation comments

**Total: ~9 days of focused work.** This assumes Q3 (cross-browser passkey) gets a separate carve-out spike if it surfaces issues.

## §5 — Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Broker `/v1/auth/email/*` API drifts during implementation | medium | freeze the broker interface in Phase E before UI work; daemon proxies are tied to it |
| Cross-device WebAuthn (Q3) reveals iOS-Safari quirks | medium | spike Phase G early; if blocked, ship Act 2 without the recovery drill (Screen K) first |
| Operator's `operator-workstation.env` shape changes between this plan and implementation | low | the daemon reads this file today; treat it as a stable contract until M5 |
| Stage-3 isolation check fails for legitimate operators when their AWS region differs | low | the existing harness handles per-region setup; surface region in `/v1/onboarding/state.cloud_detail` |
| Onboarding state machine's chain queries are too slow | medium | the 5-second poll proposal in `data-model.md` §"Open contract questions" Q1 mitigates; benchmark before shipping |

## §6 — What this plan does not commit to

- **Specific UI copy.** All operator-facing text in this plan is illustrative. Real copy gets a design pass.
- **Visual treatment.** The prototype's iii.dev aesthetic is assumed but not prescribed by this plan. Screens A-L could be redesigned wholesale; the flow + endpoint contracts are what's locked in.
- **Mobile-native iOS / Android.** Per issue #110, that's M5 after vendor pilot.
- **Workflow automation.** No "if X then Y" rules, no scheduled scope changes, no auto-revoke-after-N-failures. v0 is manual every time.

## §7 — Review checkpoint

Before any implementation work begins under this plan, the reviewer should confirm:

1. **Stage docs accurately reflect the harness.** Spot-check a step in `harness/v2-stage1-demo.sh` against `stage1-first-run.md`'s mapping table. Same for stages 2 and 3.
2. **The email distinction in `input-discipline.md` §1 is correct.** Operator-login-email vs agent-inbox-sub-address — confirm the email worker (arch.md §15.4) routes the way the doc claims.
3. **The daemon contract in `data-model.md` is implementable without rewriting PR-C's existing endpoints.** Most additions are net-new endpoints; the shipped POST mutations get a small extension (taking `k11_assertion_id`) but no breaking change.
4. **The sequencing in §4 above is achievable.** ~9 days is the estimate; multiply by 1.5x if reviewer expects scope creep.
5. **Q1–Q6 open questions are tracked.** None of them block the plan from being approved; they block specific phases from starting.

If all five check out, implementation can begin at Phase D.
