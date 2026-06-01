# stage2-second-master · pair a companion master · raise recovery quorum

**Source script:** [`harness/v2-stage2-demo.sh`](../../../harness/v2-stage2-demo.sh) — 11 steps.
**Source runbook:** [`docs/v2-stage2-heima-deploy-and-test.md`](../../v2-stage2-heima-deploy-and-test.md) §0–§6.
**Canonical reference:** [`docs/arch.md`](../../arch.md) §10.5 (multi-master deployments), §10.3.1 (companion daemon).

## What we're mapping

| # | Harness step | UI surface | Operator input | Notes |
|--:|---|---|---|---|
| 1 | build CLI + daemon (release) | — (operator-cluster admin only) | none | engineering / deploy concern |
| 2 | run forge tests (28 contract tests) | — | none | CI concern |
| 3 | deploy stage-2 contracts (P256Verifier, K11Verifier, fresh SidecarRegistry + AgentKeysScope) | — (operator-cluster admin only) | none | one-shot per operator deployment |
| 4 | bootstrap primary master on new SidecarRegistry | implicit (already done in stage 1) | — | only relevant for the chain migration scenario |
| 5 | enroll companion K11 + start companion daemon | **screen G — pair device** + **screen H — companion enroll** | open URL on second device + Touch ID on each | the meat of stage 2 |
| 6 | register companion as 2nd master device | **screen I — confirm** | Touch ID on primary | |
| 7 | set recoveryThreshold = 2 | **screen J — quorum** | confirmation + Touch ID on primary | |
| 8 | register synthetic 3rd master ("spare") | **screen K — recovery drill** (optional) | Touch ID on primary | demo only — the spare exists only to be revoked next step |
| 9 | revoke the spare via 2-of-2 M-of-N quorum | **screen K — recovery drill** continued | Touch ID on primary + Touch ID on companion | proves the quorum gate is real |
| 10 | Tier-A audit relay + email-inbox smoke (workers) | — (steady-state audit feed) | none | the workers are running anyway |
| 11 | cleanup + summary | **screen L — done** | none | |

The steps merge into **6 UI screens** (G through L). Steps 1–4 are operator-cluster admin concerns (the SRE running the deployment), not the parent operator — they don't appear in the parent-control UI.

---

## Screen G — pair device

**Purpose:** the operator initiates pairing on their primary device. The primary generates a pairing nonce that's encoded into a QR code; the second device scans + opens the URL.

**Precondition:** the operator has completed stage 1. They're logged in on the primary as a master. They tap "add device → second master".

**What the operator sees on the primary:**

> *Pair a second master device*
>
> *Add a phone or tablet as a co-equal master. From then on, sensitive actions (revoking a device, rotating keys) need approval on both devices.*
>
> *Why two devices: if one is lost, stolen, or destroyed, the other can recover the account without a seed phrase. arch.md §10.5.*
>
> ```
>   ┌─────────────────────────┐
>   │ █ ██ █ █ ██  █ █ █ █ █ │
>   │ ██  █ ██████ ██ ██ █ █ │   open this QR on your iPad
>   │ █ █ █ █  █ █ ██ ███ █  │   or paste the URL into the
>   │ ██████ ██ █  █ ██ █ █  │   second device's browser
>   │ █ █  ██ ██ █ █ ██ █ ██ │
>   └─────────────────────────┘
>   https://parent.litentry.org/pair#tok=AKp-1729384a1f9c…
> ```
>
> `[ I've opened it on the other device → ]`

**Pairing URL contents:**

The fragment-portion (`#tok=…`) carries an ephemeral pairing token issued by the primary's daemon. The token is single-use, expires in 10 minutes, and is bound to the primary's session. The companion device exchanges this token at `POST /v1/onboarding/pair/exchange { token }` for a short-lived JWT that lets it run the companion onboarding without going through email-link verification again — pairing inherits the primary's identity.

**What happens on the primary:**

1. UI calls `POST /v1/onboarding/pair/start`.
2. Daemon mints a pairing token (signs it with the primary's K10; broker verifies on exchange).
3. UI shows the QR + URL.
4. Primary polls `GET /v1/onboarding/pair/status?token=…` every 1s.
5. When the companion's `POST /v1/onboarding/pair/exchange` lands, status flips to `companion-active`; primary's UI advances.

**What the operator sees on the companion (after scanning):**

The companion lands on the URL → daemon calls `/v1/onboarding/pair/exchange` automatically using the token from the URL fragment → the companion's UI continues to screen H.

**Validation gates:**

- Token expired (>10 min) → companion sees "this pairing link expired. Go back to your primary device and start a new pairing."
- Token already exchanged → companion sees "this link was already used. Start a new pairing on your primary."
- Companion lands on the URL while a different operator's session JWT is in its browser → "your existing session conflicts with this pairing. Sign out, then re-open the link."

---

## Screen H — companion enroll

**Purpose:** the companion device generates its own K10 + K11, distinct from the primary's. After this screen the companion *exists* as a key pair on the second device, but is not yet recognized by the chain.

**What the operator sees on the companion:**

> *This is your companion device*
>
> *Setting up "{device-label-derived-from-user-agent}" as your second master. We'll enroll a separate passkey on this device — Touch ID here is independent of Touch ID on your primary.*
>
> *RP ID: `companion.localhost` (or `companion-v2.localhost` if a previous companion was revoked)*
>
> `[ Enroll passkey on this device → ]`

**Device label** comes from the user-agent. Operator can edit it ("iPad Pro - home"). This is operator-typed in the same way the agent label was on stage-1 screen E.

**What happens:**

This is the same `POST /v1/k11/enroll/begin` + `POST /v1/k11/enroll/finish` flow already shipped (PR-B). The only difference: the daemon uses `rp_id=companion.localhost` (or `companion-v2.localhost`, etc. when there's a version collision per harness step 5's rp_tag escalation). The companion's K10 is generated locally on this device's secure enclave — it does NOT carry the primary's K10.

The pairing token from screen G authorizes this enrollment without re-verifying email — the broker accepts the companion's POSTs because they carry the pair-derived JWT.

**Why a separate RP ID:**

Per arch.md §10.5 + the harness's rp_tag escalation (`companion`, `companion-v2`, etc.): each WebAuthn credential is bound to its RP ID. If a previous companion was revoked, that credential id is invalidated on chain, but the platform authenticator on the device may still hold the stale credential. Bumping the RP ID forces a fresh enrollment instead of reusing the old credential.

The harness step 5 (lines 350-385 of `v2-stage2-demo.sh`) does this exact scan ("companion, companion-v2, …") and picks the first un-used tag. The web flow mirrors that — the daemon's enroll/begin handler returns the chosen `rp_id` so the browser uses it.

**Validation gates:**

- Companion device doesn't have a platform authenticator → "your second-master device needs Touch ID, Hello, or a passkey to act as a master. Try a different device."
- Pairing JWT expired (>30 min on companion side) → "this pairing session timed out. Start over on your primary device."

**State after this screen:**

- Companion device: K10 in keychain, K11 credential on disk, K11 cred_id reported back to primary via `POST /v1/onboarding/pair/companion-ready { device_key_hash, k11_cred_id_hash }`.
- Primary device: notified that the companion is ready; advances to screen I.
- Chain: still unaware of the companion.

---

## Screen I — confirm companion

**Purpose:** the primary device's operator authorizes the companion's addition to the chain. This is the master mutation that grants the companion `CAP_MINT | RECOVERY` roles on `SidecarRegistry`.

**Why this happens on the primary, not the companion:**

The companion has no on-chain authority yet — it can't sign master mutations. The primary, which IS a master, has to sign the addition. This is the only way to add a second master without a third party.

**What the operator sees on the primary:**

> *Add this device as your second master?*
>
> *Device: "{companion-device-label}"*
> *D_pub_hash: 0x{first-12-hex-chars}…*
> *K11 cred_id_hash: 0x{first-12-hex-chars}…*
> *Roles on chain: `CAP_MINT | RECOVERY` (not SCOPE_MGMT — only the primary controls scope today)*
>
> *Confirming with Touch ID will send `addMasterDevice` to the chain. Gas estimate: 0.008 HEI.*
>
> `[ Approve with Touch ID → ]`

**Why the companion gets `CAP_MINT | RECOVERY` but not `SCOPE_MGMT`:**

Per arch.md §10.5: the companion can co-sign recovery (revoke + rotate when a master is lost) and mint caps on its own. Granting scope to agents requires a single authoritative source — the primary's choice. This matches harness step 6's `--roles cap-mint,recovery` (no `scope-mgmt`).

If the operator wants the companion to have `SCOPE_MGMT`, they edit the companion's roles after pairing completes (steady-state actor-detail screen). That's a follow-on master mutation; not part of the pair flow.

**What happens on submit:**

1. UI calls `POST /v1/onboarding/pair/finalize` with the companion's `device_key_hash` + `k11_cred_id_hash` (which the primary already learned from screen H's "companion-ready" event).
2. Daemon constructs the `addMasterDevice` message + challenge.
3. UI runs `navigator.credentials.get(...)` on the primary's K11.
4. UI ships the assertion + companion details to `POST /v1/onboarding/pair/finalize/submit`.
5. Daemon submits the extrinsic.
6. After confirmation, both the primary's UI and the companion's UI receive an SSE `companion.added` event and advance together.

**Validation gates:**

- Primary's K11 assertion fails → operator retries.
- Chain rejects (e.g. the companion's `device_key_hash` is already on chain from a previous failed pairing attempt) → daemon catches the on-chain error and either short-circuits ("already registered — moving on") or fails with a clear message.
- Companion goes offline mid-flow → primary's UI shows "your companion is unreachable. Bring it back online or restart pairing." The pairing token stays valid for the remainder of its 10-min window.

---

## Screen J — set recovery quorum

**Purpose:** flip `recoveryThreshold` from 1 to 2. After this, neither device can revoke a master or rotate K3 alone — both Touch IDs needed.

**What the operator sees on the primary:**

> *Raise your recovery quorum to 2*
>
> *Right now, either of your two devices can revoke the other unilaterally. We strongly recommend raising the bar so both devices must agree.*
>
> *What this changes:*
> *  · revoking a master device → both devices must Touch ID*
> *  · rotating K3 (key epoch) → both devices must Touch ID*
> *  · creating an agent, granting scope, revoking an agent → only the primary's Touch ID is needed*
>
> *You can lower this back to 1 later, but a 1-of-2 setup loses the recovery safety net.*
>
> `[ Confirm with Touch ID → ]`

**What happens on submit:**

1. UI calls `POST /v1/onboarding/recovery/threshold { threshold: 2 }`.
2. Daemon constructs the `setRecoveryThreshold` message + challenge.
3. UI runs `navigator.credentials.get(...)` on the primary.
4. Daemon submits the extrinsic.
5. Post-confirm, daemon re-queries `recoveryThreshold(operator_omni)` on chain and confirms it's `2` (per harness step 7's post-condition check).

**Validation gates:**

- Already at threshold=2 → daemon detects + skips the extrinsic; UI advances.
- Chain extrinsic fails → "couldn't raise the quorum. Retry?"

---

## Screen K — recovery drill (optional, recommended)

**Purpose:** the operator deliberately revokes a synthetic "spare" master device, requiring both their primary AND companion Touch IDs in the same extrinsic. This is the only way to prove the quorum gate works *before* they need it for real.

**This is an opt-in screen. Skippable with "I'll trust it later".**

The harness runs steps 8–9 as part of CI to gate the deployment. The web UI exposes them as an *operator-facing drill* so the operator gains confidence in the recovery mechanism — they should know what the ceremony feels like before their phone is at the bottom of a lake.

**Part 1 — Register a spare:**

> *Recovery drill (optional but recommended)*
>
> *We'll register a fake third master ("the spare"), then revoke it using both your devices. This proves recovery works without putting your real devices at risk.*
>
> *The spare is a freshly-generated keypair that we'll throw away after the drill. It never holds real authority.*
>
> `[ Run the drill → ]`  `[ Skip — I trust the math ]`

On "Run the drill":

1. UI calls `POST /v1/onboarding/drill/register-spare`.
2. Daemon generates a fresh P-256 keypair (the "spare"), signs the registration with the primary's K11 (Touch ID on the primary).
3. Spare appears on chain with `CAP_MINT | RECOVERY` roles.

**Part 2 — Revoke the spare via 2-of-2 quorum:**

> *Now both your devices must approve the revoke*
>
> ```
>   [ ] primary device — your iPhone Pro
>   [ ] companion — "iPad Pro - home"
> ```
>
> *We'll prompt Touch ID on each device sequentially. Both assertions are bundled into a single chain transaction.*
>
> `[ Approve on primary → ]`

The primary signs first. The UI then shows:

> *Primary approved. Now approve on the companion.*

The companion's UI (still on screen K from earlier — it stayed live throughout) prompts Touch ID. Both assertions ship to the daemon, which bundles them and calls `revokeMasterDevice(spare_hash, assertions=[primary_k11, companion_k11])`.

If the operator's deployment runs the harness's `heima-set-recovery-threshold.sh --threshold 2` precondition (which by this point it has), the contract enforces that both assertions are present + valid. A single assertion will be rejected on-chain.

**What happens after:**

- Chain: spare's `revoked_at` is set; `isActive(spare_hash) == false`.
- Audit feed: a `device.revoked` event for the spare appears.
- UI: "your recovery drill succeeded. Both devices agreed; the spare is revoked."

**Validation gates:**

- Operator skips the drill → no problem, but the UI tags their account as "recovery untested" on the master-detail screen. (A nudge, not a block.)
- Companion goes offline mid-drill → "we need both devices online. Bring the companion back and retry from the spare-revoke step."

---

## Screen L — done

> *You're paired*
>
> ```
> [✓] companion master active · iPad Pro - home
> [✓] recovery quorum: 2 of 2
> [✓] recovery drill: passed (spare revoked at 14:38:12)  — or — recovery drill: skipped
> ```
>
> *From now on, sensitive actions (revoking devices, key rotation) need both Touch IDs. Scope changes only need your primary.*
>
> `[ Back to dashboard → ]`

After Act 2 the operator is in steady state with a 2-of-2 setup. The UI re-routes to `/actors`.

---

## What the operator's steady-state UI looks like after this

The actor-detail page for the operator's master shows a new sub-section:

```
── master devices · multi-device quorum
─────────────────────────────────────────
[●] iPhone 17 Pro · this device       CAP_MINT | RECOVERY | SCOPE_MGMT  · 14:32 just now
[●] iPad Pro · home                   CAP_MINT | RECOVERY               · yesterday 21:08
```

Each row offers:
- **Edit roles** — bump the companion to `SCOPE_MGMT` if the operator wants that. Triggers a master-mutation.
- **Revoke** — disabled when revoking would leave the operator with 0 active masters. Otherwise requires the 2-of-2 ceremony to complete.

`recoveryThreshold` is displayed alongside ("Quorum: 2 of 2"). Lowering it is a master-mutation that requires both Touch IDs.
