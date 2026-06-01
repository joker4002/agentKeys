# stage1-first-run · operator first run · become a master

**Phase 1 scope:** harness steps 6–11 only (identity, cloud provision, smoke test, chain bring-up, master register, K11 enroll). Steps 12–14 (first agent + scope + audit-ping) are Phase 2 — see [`overview.md` § TODO list](overview.md#todo-list--out-of-phase-1-scope).

**Source script:** [`harness/v2-stage1-demo.sh`](../../../harness/v2-stage1-demo.sh) — 16 numbered steps, idempotent, resumable with `--from-step N`.
**Source runbook:** [`docs/v2-stage1-migration-and-demo.md`](../../v2-stage1-migration-and-demo.md) §0 + §1 + §2 + §4.
**Canonical reference:** [`docs/arch.md`](../../arch.md) §10 (ceremonies), §6.2 (HDKD actor tree), §17.2 (per-data-class isolation).
**Companion docs:** [`input-discipline.md`](input-discipline.md), [`data-model.md`](data-model.md).

## What we're mapping (Phase 1)

Each row says where the harness step surfaces in the UI, what input the operator types (vs. what the system computes), and what daemon endpoint backs it. Harness preflight steps 1–5 are not exposed in the wizard — they're internal checks the daemon runs before responding to the screens below.

| # | Harness step | UI screen | Operator input | Daemon endpoint |
|--:|---|---|---|---|
| 1–5 | preflight (tools, env, AWS profile, CLI, chain reachability) | — (background) | none | folded into `GET /v1/onboarding/state` |
| 6 | init session via email magic-link | **screen A — identity** | operator's real email | `POST /v1/auth/email/start`, `POST /v1/auth/email/verify`, `GET /v1/auth/email/status` |
| 11 | K11 enrollment (real WebAuthn) | **screen B — passkey** | Touch ID / Hello / passkey | `POST /v1/k11/enroll/{begin,finish}` (shipped) |
| 7 | provision vault infrastructure | **screen C — cloud** (part A) | none (uses creds from screen A) | `POST /v1/onboarding/cloud/provision` + SSE `/v1/onboarding/cloud/stream` |
| 7 (new) | list master's vault + memory contents | **screen C — cloud** (part B) | none | `GET /v1/master/credentials`, `GET /v1/master/memory` |
| 8 | smoke-test S3 envelope | **screen C — cloud** (part C) | none | `POST /v1/onboarding/cloud/smoke` |
| 9 | chain bring-up (deploy 4 contracts) | **screen D — chain** (part A) | confirm on mainnet | `POST /v1/onboarding/chain/deploy` |
| 10 | register operator master device on chain | **screen D — chain** (part B) | Touch ID | `POST /v1/k11/assert/{begin,finish}` then `POST /v1/onboarding/chain/register-master` |

The Phase 1 wizard is **4 screens (A–D)**. Order matches the harness; the dependencies (K11 ⇒ register-master) are real. Screens E (first agent) and F (done) from the previous draft are deferred to Phase 2.

Note: harness step 11 (K11 enroll) maps to UI screen B, which the operator sees *before* the cloud + chain screens. This mirrors the harness's actual dependency graph — K11 must exist before the chain step's master-register K11 assertion runs — even though the harness script numbers step 11 later for ordering reasons (steps 12-14 don't depend on K11 in the script). The web flow puts K11 enroll right after identity, where it belongs in the operator's mental model.

---

## Screen A — identity

**Purpose:** establish who the operator is. After this screen they have a session JWT, a deterministic Ethereum wallet, and a `binding_nonce` from the broker. Nothing else changes.

**What the operator sees first:**

> *agentKeys · parent control*
>
> *Type the email you'll use to manage your agents. We send a one-time link there to prove it's yours.*
>
> `[ email input ]`
> `[ Continue → ]`

The email field is **a real email the operator owns and reads**. See [`input-discipline.md` §1](input-discipline.md) for why this is non-negotiable.

**What happens on submit:**

1. UI calls `POST /v1/auth/email/start { email }` (daemon proxies to broker `/v1/auth/email/start`).
2. UI advances to "check your inbox" screen with a polling indicator.
3. Operator opens their mail client, clicks the link.
4. The link's target (`https://parent.litentry.org/verify?token=…`) hits the daemon, which proxies to broker `/v1/auth/email/verify`. Broker returns `{ session_jwt, wallet_address, actor_omni, binding_nonce }`.
5. The original tab — still polling — sees `verified=true` and advances.

**Where the harness path differs and why:**

- Harness step 6 falls back to `wallet_sig` (SIWE with a deployer key file) when `--skip-email` is passed. That is CI-only. The web flow has no CI in the loop — humans always click links, so the wallet_sig path is not exposed. (For ops-power-user dev mode, see [`deferred-and-followups.md` §2](deferred-and-followups.md).)
- Harness step 6 uses `demo-N@bots.litentry.org` SES-verified aliases. That is the **demo's** real email, used because the harness operator doesn't have a real SES-verified domain. A real operator using the deployed web UI types their actual email — which must resolve through the broker's allowed domain list (see [`input-discipline.md` §1.1](input-discipline.md) for the domain policy).

**Validation gates:**

- Empty / malformed email → inline error.
- Domain outside the broker's allow-list → "this email domain isn't supported in your deployment. Contact your operator-cluster admin." with the configured allow-list shown.
- Magic link clicked but the originating tab is closed → daemon stores `verified=true` on the broker side; next time the operator opens the UI, `GET /v1/onboarding/state` returns `identity: 'verified'` and they pick up at screen B.

**Resume:** if `GET /v1/onboarding/state` returns `identity: 'verified'`, this screen is skipped and the UI lands on screen B. If `identity: 'pending'` (broker has a pending verify), they get the "check your inbox" view. If `identity: 'missing'`, the email form.

**State after this screen:**

- Local: session JWT in OS keychain (via the daemon).
- Broker: identity record bound to email + wallet + actor_omni.
- Chain: nothing yet.

---

## Screen B — passkey

**Purpose:** enroll K11. The operator's *biometric proof of intent* for every future master mutation gets created here.

**What the operator sees:**

> *Set up a passkey on this device*
>
> *You'll use Touch ID, Hello, or your phone's passkey to approve every change to your agents — granting them access, revoking devices, raising payment caps. The passkey lives on this device only.*
>
> *Why this matters: even if someone steals your session, they can't do anything serious without your face / fingerprint.*
>
> `[ Enroll passkey → ]`

**What happens on submit:**

This screen is **already implemented** in PR-B. It's the existing `/onboarding` page step 3, simply lifted into its own dedicated screen instead of buried in a list. See [`apps/parent-control/app/_components/onboarding.tsx`](../../../apps/parent-control/app/_components/onboarding.tsx) and [`crates/agentkeys-daemon/src/ui_bridge.rs`](../../../crates/agentkeys-daemon/src/ui_bridge.rs) `enroll_begin` / `enroll_finish`.

The daemon-side challenge construction is what arch.md §10.2 specifies: `sha256(binding_nonce ‖ D_pub)`. `binding_nonce` came from screen A; `D_pub` is computed when K10 is generated (next paragraph).

**What about K10?**

K10 — the per-device secp256k1 key — needs to exist before the K11 challenge can be computed (because the challenge binds D_pub atomically inside it). Two options:

- **Option 1 (separate screen):** explicit "creating device key" mini-screen between A and B. Pro: explicit. Con: the operator doesn't care; one more click.
- **Option 2 (folded into B):** the daemon generates K10 when `POST /v1/k11/enroll/begin` is hit, in the same handler call. The UI shows a single "Enroll passkey" button that does both.

**Recommendation: Option 2.** The operator's mental model is "set up the passkey"; the K10 detail is invisible. Per arch.md §10 the two are part of one ceremony ("master binding ceremony"). The harness step 11 already runs K10 derivation inline with K11 enrollment. The UI follows.

**Validation gates:**

- WebAuthn not available in the browser (e.g. desktop Firefox without a platform authenticator) → screen renders with the enroll button disabled and an explanation: "your browser doesn't expose a platform authenticator. Try Safari, Chrome, or Edge on this device, or use a phone."
- `navigator.credentials.create()` returns null (user cancelled the OS dialog) → "you cancelled. Try again."
- Daemon rejects attestation (`attestation-rejected`) → "your passkey couldn't be verified. Try again, or contact support if this keeps happening." Operator can retry; the begin call issues a fresh challenge.

**Resume:** `k11: 'enrolled'` → skip to screen C.

**State after this screen:**

- Local: K10 in keychain, K11 credential id on disk (`~/.agentkeys/k11/<omni>.json`).
- Broker: K11 cred_id is NOT yet known to the broker — it lands when screen D registers the master device on chain.
- Chain: nothing yet.

---

## Screen C — cloud

**Purpose:** stand up the operator's per-data-class AWS infrastructure (or detect it already exists), prove it's reachable + isolated, and surface what the master currently holds in vault + memory.

This screen has three parts that flow together in one continuous view; the operator doesn't tap between them.

### Part A — provisioning progress

> *Setting up your cloud · this happens once*
>
> ```
> [✓] AWS account · 928... (from your operator-workstation.env)
> [⟳] vault bucket · creating agentkeys-vault-<deployer>...
> [ ] memory bucket
> [ ] audit bucket
> [ ] email bucket
> [ ] vault IAM role · agentkeys-vault-role
> [ ] memory IAM role · agentkeys-memory-role
> [ ] bucket policies · scoped to your actor_omni
> ```
>
> *takes ~90 seconds the first time. Subsequent runs detect existing infra and skip.*

**What happens:**

1. UI calls `POST /v1/onboarding/cloud/provision`.
2. Daemon dispatches to the existing `scripts/provision-vault-bucket.sh`, `scripts/provision-vault-role.sh`, `scripts/apply-vault-bucket-policy.sh`, `scripts/provision-memory-bucket.sh`, `scripts/provision-memory-role.sh`, `scripts/apply-memory-bucket-policy.sh`.
3. Each sub-script's progress streams back via SSE on `GET /v1/onboarding/cloud/stream` as `provision.step` events. The UI updates each row as events land.

### Part B — your credentials + your memories (master scope)

As soon as provisioning succeeds, the UI swaps in a side-by-side listing of what the master holds:

> ```
> ── your credentials (vault)                                       0 entries
>    (none yet — agents will add credentials they store on your behalf;
>     you can also add personal credentials here that only your master
>     session uses, see arch.md §15.1)
>
> ── your memories (memory)                                          0 entries
>    (none yet — agents writing to family/personal namespaces will
>     populate this; the master is the recipient of agent writes per
>     arch.md §15.2)
> ```

For a brand-new operator both panels are empty. For an operator re-running onboarding on a new device, real entries appear immediately — confirming "yes, this is your data; you're not staring at a stranger's cloud."

**Daemon endpoints (new in Phase 1):**

- `GET /v1/master/credentials` — metadata-only listing of the master's vault prefix (`s3://vault/bots/<master_omni_hex>/credentials/*`). Returns `[{ service, last_write_at, size_bytes, encryption_alg }]`. Never plaintext.
- `GET /v1/master/memory` — metadata-only listing of the master's memory prefix (`s3://memory/bots/<master_omni_hex>/memory/*`). Returns `[{ key, last_write_at, size_bytes, writer_actor_omni }]`. Per arch.md §15.2 the `writer_actor_omni` distinguishes things the master wrote themselves vs things an agent wrote on their behalf.

**Why these listings appear here, not on a later "master detail" page only:** the operator's mental model just shifted from "abstract cloud" to "my AWS account has buckets with my data" — surfacing what's there immediately closes the loop. It also tests the listing endpoints with zero entries, which is a useful smoke test on its own.

**Why master is also an actor:** per arch.md §6.2, the master is the root of the HDKD actor tree. Agents are HDKD children of it. Credentials the master stores directly (their own OpenRouter key, used when invoking an agent interactively) live under the master's `actor_omni` prefix — distinct from any agent's prefix. The master-detail page surfaces this from step 5 onward; the operator sees their own slice of the cloud separately from anything an agent does later.

### Part C — smoke test

After Part B renders, the UI fires `POST /v1/onboarding/cloud/smoke`. The daemon writes one envelope to `s3://vault/bots/<master_omni_hex>/credentials/.healthcheck/smoke.test` (using `service="onboarding-smoke"`, `secret=<random 32 bytes>` — see "harness path differs" below), reads it back, and reports `{ passed: true | false, envelope_url, error? }`.

On success the Part B vault listing updates live to include the `.healthcheck/smoke.test` entry — the operator sees their own data appear in their own UI. They can leave it or delete it; the `.healthcheck/` prefix is the marker for the operator-cluster admin's cleanup policy. *(Harness step 8.)*

### Validation gates

- AWS caller identity wrong → "agentkeys-admin profile expected; got `default`. Run `awsp agentkeys-admin` and retry."
- A bucket name already taken → daemon retries with `-2` suffix, surfaces the change.
- IAM trust policy / bucket policy apply fails → "your AWS account is missing these permissions: ..." prompt.
- Smoke test fails → screen pauses, error from AWS is surfaced raw, retry button.

### Where the harness path differs

- Harness has `--skip-provision` for CI. The web flow does NOT expose `--skip-provision` — every real operator provisions their own buckets. (Operator-cluster admin overrides via env var `AGENTKEYS_CLOUD_PROVISIONED=1`; see [`deferred-and-followups.md` §2](deferred-and-followups.md).)
- Harness step 8's smoke uses `SMOKE_TEST_SERVICE=openrouter` + `SMOKE_TEST_SECRET=sk-or-v1-DEMO-FAKE…`. The web UI uses a hard-coded `service="onboarding-smoke"` + random `secret` — no real-looking credential lands in the operator's vault.

### Resume

- `cloud: 'provisioned'` → skip Part A, render Parts B + C only.
- `cloud: 'partial'` → the UI lists what's still missing and offers a "resume provisioning" button.
- Master credentials + memory always re-listed on screen entry (cheap call against the operator's own prefix).

### State after this screen

- AWS: vault + memory + audit + email buckets exist, scoped to the operator's `master_omni_hex`.
- AWS contents: `s3://vault/bots/<master_omni_hex>/credentials/.healthcheck/smoke.test` exists with a random secret.
- Local: STS creds for vault + memory roles cached for the duration of the session.
- Chain: nothing yet — chain step is screen D.

---

## Screen D — chain

**Purpose:** anchor the operator's identity on the chain by registering the master device on `SidecarRegistry`. This is the single moment after which the operator is "a real on-chain identity."

**What the operator sees:**

> *Anchoring you on chain · this is the moment you become a master*
>
> ```
> [✓] chain reachable · heima-paseo / heima
> [ ] SidecarRegistry · deploying (or 'detected at 0xa3f1…')
> [ ] AgentKeysScope · deploying (or 'detected at 0xb1e9…')
> [ ] K3EpochCounter · deploying (or 'detected at 0xc4d8…')
> [ ] CredentialAudit · deploying (or 'detected at 0xd7c0…')
> [ ] registering this device as your master ← needs Touch ID
> ```
>
> *Your master wallet: `0xf3a8…b1d2` · gas estimate: 0.012 HEI*
>
> `[ Approve with Touch ID → ]`

**What happens:**

1. UI calls `POST /v1/onboarding/chain/deploy` for the contract bring-up. Daemon dispatches to existing `harness/scripts/heima-deploy-stage2.sh` + `heima-init-epoch-counter.sh` paths.
2. If the contracts already exist (their addresses are in `scripts/operator-workstation.env`), the daemon detects + reports them as `detected at 0x...`, no re-deploy.
3. After contracts are live, the UI runs the two-step K11 assertion pattern:
   - `POST /v1/k11/assert/begin { intent: { op: "register_master", fields: [["device_pubkey_hash", "0x..."], ["roles", "CAP_MINT|RECOVERY|SCOPE_MGMT"]] } }` → returns `{ challenge, assertion_id }`.
   - Browser calls `navigator.credentials.get({ publicKey: { challenge, allowCredentials: [<K11_cred_id>], userVerification: "required" } })`.
   - `POST /v1/k11/assert/finish { assertion_id, authenticatorData, clientDataJSON, signature }` — daemon verifies the assertion + holds it ready for the chain call.
4. UI calls `POST /v1/onboarding/chain/register-master { k11_assertion_id }`. Daemon submits the extrinsic.
5. Tx hash + block number stream back. UI shows "confirmed at block #1,234,567 in 4.2 s" with a link to the chain explorer.

**Mainnet confirmation step:**

Per the harness's `--confirm` flag and arch.md §8 ("chain bring-up policy"), when the operator's deployment targets `AGENTKEYS_CHAIN=heima` (mainnet), the UI inserts an extra "you're about to deploy contracts on Heima mainnet. Type `deploy` to confirm" pause. heima-paseo / anvil skip this gate.

**Validation gates:**

- Insufficient gas on the deployer wallet → daemon surfaces "wallet `0xf3a8…` needs at least 0.05 HEI; current balance 0.012". On heima-paseo this links to the sudo-fund helper; on heima mainnet it just stops.
- K11 assertion fails (Touch ID cancelled / wrong device) → "we couldn't verify your passkey. Try again."
- Chain rejects the extrinsic (e.g. address already registered) → daemon catches the on-chain `DeviceAlreadyRegistered` event, reports "this device is already on chain — moving you forward."

**Where the harness path differs:**

- Harness step 9 deploys to whatever `AGENTKEYS_CHAIN` is set to. The web UI defaults to the operator's configured chain (single value in `operator-workstation.env`); switching chains mid-flow is not exposed. (Per-chain operator deployments are separate URLs.)
- Harness step 10 is a single `register_master_device` call. The web UI inserts the gas-estimate + confirmation step to surface the on-chain action explicitly.

**Resume:** `chain: 'master-registered'` → onboarding wizard is complete; UI lands on the master-detail page. `chain: 'contracts-deployed'` → operator lands on the "register this device" sub-step. `chain: 'missing'` → full deploy flow.

**State after this screen (Phase 1 terminus):**

- Chain: contracts exist; operator's `D_pub_hash` is registered with `roles = CAP_MINT | RECOVERY | SCOPE_MGMT`, `k11_cred_id_hash` matches what was enrolled on screen B.
- Local: contract addresses cached.
- Audit: a `DeviceRegistered` event is in the chain's event log.

**This is the end of the Phase 1 onboarding wizard.** The operator is now a fully-registered master. Subsequent UI sessions land directly on the master-detail page; the wizard never reappears for this operator on this device.

---

## What comes after Phase 1 (deferred)

The previous draft of this doc contained two more screens:

- **Screen E — first agent.** Agent label + vendor → `POST /v1/agents/create` → chain `registerAgentDevice(...)`. Then per-namespace scope toggles + payment cap inputs → K11 assertion → `setScopeWithWebauthn(...)`. *(Harness steps 12 + 13.)*
- **Screen F — done.** Single demo `CredentialAudit.append` from the operator's session → visible in audit feed within 200 ms. *(Harness step 14.)*

Both are **deferred to Phase 2**. See [`overview.md` § TODO list](overview.md#todo-list--out-of-phase-1-scope) for the full deferred-work index.

Reason for the cut: Phase 1 already delivers a complete, useful slice — the operator can claim their identity, see their own cloud, and exist on chain as a registered master. Agent creation depends on the master being live; nothing in Phase 1 is blocked by deferring it. Shipping Phase 1 alone unlocks both vendor pilot demos ("look, I'm a master on the Heima chain") and the eventual Phase 2 implementation.

---

## Removed screens (formerly drafted, now deferred)

The original sections for screens E and F that lived here have been moved to the deferred work index. They will return in `docs/plan/web-flow/` when Phase 2 begins, with the lessons from Phase 1 implementation folded in (cross-browser passkey quirks, real broker URL handling, etc.).

**Purpose:** the operator creates an agent device and grants it scope. By the end of this screen the operator has done the *complete* AgentKeys flow at least once.

**What the operator sees, part 1 (agent creation):**

> *Add your first agent*
>
> *An agent is any device or sandbox that needs to act on your behalf with bounded permissions. Your home robot, a chatbot you trust, a coding assistant.*
>
> `[ Name your agent ]  e.g. "FoloToy bear" / "ChatGPT" / "Pluto"`
> `[ Vendor (optional) ]  e.g. "FoloToy Inc." / "OpenAI" / "Anthropic"`
> `[ Continue → ]`

**Name** is operator-typed, free-text. **Vendor** is operator-typed, free-text (used as a display string only — the trust chain doesn't depend on the vendor name).

**What happens on submit:**

1. UI calls `POST /v1/onboarding/agent/create { label, vendor }`.
2. Daemon dispatches to existing `harness/scripts/heima-agent-create.sh --label <label>`.
3. Chain registers the agent device under derivation `master_omni // <label>` (HDKD per arch.md §6.2). The agent's own K10 will be generated on the agent's hardware — at this stage we just create the on-chain placeholder.
4. UI advances to part 2 (scope grant).

**What the operator sees, part 2 (scope):**

> *What is "{label}" allowed to do?*
>
> *Each namespace is a separate scope you can grant. Start narrow — you can widen later.*
>
> ```
>          read    read+write    deny
> personal [ ]      [ ]          [x]
> family   [x]      [ ]          [ ]
> work     [ ]      [ ]          [x]
> travel   [ ]      [ ]          [x]
> ```
>
> *Payment cap (optional)*
> ```
> per-transaction limit: [ 5 ] USDC
> daily ceiling:         [ 20 ] USDC
> ```
>
> `[ Save with Touch ID → ]`

The triple toggle is operator-driven. Payment cap is operator-typed. Time-window is omitted from first-run; it's available on the actor-detail screen after onboarding completes.

**What happens on submit:**

1. UI calls `POST /v1/actors/:id/scope` for each changed namespace.
2. Daemon constructs the K11-bound `setScopeWithWebauthn` calldata, returns a challenge.
3. UI runs `navigator.credentials.get(...)`.
4. UI ships the assertion to `POST /v1/actors/:id/scope/finalize`.
5. Daemon submits the extrinsic. Tx confirms within a few seconds.

**Validation gates:**

- Label collision (operator already has an agent named "FoloToy bear") → daemon returns `agent-label-collision`; UI suggests "{label}-2" or asks for a new name.
- Empty namespace selection (everything deny) → UI accepts but warns "this agent will be unable to do anything until you grant a scope".
- Touch ID fails → operator retries.

**Resume:** `first_agent: 'created'` → flow complete, advance to screen F. `first_agent: 'missing'` → screen E.

**State after this screen:**

- Chain: agent device on `SidecarRegistry`, scope on `AgentKeysScope`, both signed by the operator's K11.
- Audit: `DeviceRegistered` + `ScopeGrantedWithWebauthn` events on chain.
- Local: agent shows up in the operator's actor list.

---

## Screen F — done

**Purpose:** confirm everything's live, send a single demo audit event, hand off to steady-state UI.

**What the operator sees:**

> *You're set up*
>
> *Welcome to your control panel.*
>
> ```
> [✓] master device on chain · 0x{D_pub_hash}
> [✓] first agent ready · "FoloToy bear" with scope: family.read
> [✓] live audit feed connected · last event 14:32:08
> ```
>
> *Watch the audit feed update in real time as your agents do work.*
>
> `[ Go to dashboard → ]`

**What happens before this screen renders:**

The daemon fires `POST /v1/onboarding/agent/audit-ping` (harness step 14 equivalent) — a no-op credential audit append that the audit-service worker picks up and broadcasts back via the SSE feed. The operator sees their own first event land in the feed within 200 ms. This is the *only* time the system manufactures an event; from this point on every event is a real action.

**On "Go to dashboard":** UI navigates to `/actors`. The state machine commits — subsequent visits land here, not on onboarding.

---

## Operator-power-user escape hatches

For an SRE doing dev work who explicitly does NOT want the wizard:

- `POST /v1/onboarding/skip { steps: ['cloud-provision', 'chain-deploy'] }` — only available when `AGENTKEYS_OPERATOR_ROLE=admin` in the daemon's env. Marks the steps as "satisfied externally"; the UI accepts the operator's word that they ran the scripts manually.
- All daemon endpoints used by screens C–E are equally callable via `agentkeys` CLI. An ops user can complete onboarding entirely from terminal and the UI will show the resulting state on next visit.

See [`deferred-and-followups.md` §2](deferred-and-followups.md) for the policy on these.
