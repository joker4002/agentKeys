# stage3-agent-usage · normal operation · agents do real work · isolation proofs

**Source scripts:** [`harness/v2-stage1-demo.sh`](../../../harness/v2-stage1-demo.sh) steps 12–14 (agent create + scope + audit) and [`harness/v2-stage3-demo.sh`](../../../harness/v2-stage3-demo.sh) (16 steps — the four-layer isolation invariants).
**Canonical reference:** [`docs/arch.md`](../../arch.md) §15 (workers), §17.2 (per-actor + per-data-class isolation invariants), §22c.2 (agent backend variants), `CLAUDE.md` "Per-actor + per-data-class isolation invariants (issue #90)" table.

## What we're mapping

Stage 3 is fundamentally different from stages 1 and 2. Stages 1+2 are onboarding wizards — linear, one-time. Stage 3 is *steady-state operation* plus *on-demand verification*. Two distinct surfaces:

| § | Surface | Operator action | Underlying harness steps |
|--:|---|---|---|
| 1 | **Agent boot + first credential use** | the operator unboxes a new device, lets it pair to their tree, watches it fetch its first credential | stage-1 steps 12–14 (and the agent's own initialization path) |
| 2 | **Live operations dashboard** | the operator watches audit, tweaks scope, revokes when needed | every cap-mint + worker call streams into the audit feed |
| 3 | **Isolation health check** | the operator runs the 4-layer invariant proof on demand against their real cloud | stage-3 steps 1–16 — run as a single in-app demo |

Each surface gets its own section below.

---

## §1 — Agent boot + first credential use

This is the *second* time the operator creates an agent (the first time was the onboarding-screen-E from stage 1, which is necessarily a single demo agent). All subsequent agents go through this flow.

### §1.1 The agent-create screen (steady state)

From the actor-list page, the operator taps "add agent". The screen is similar to stage-1 screen E, but with one important addition: the agent device can be **remote** (a cloud LLM sandbox, a vendor-supplied device) rather than locally-known.

**What the operator sees:**

> *Add an agent*
>
> *An agent is any device or service that should act on your behalf with bounded permissions.*
>
> *How will this agent be set up?*
>
> ```
> [ ● ] this device — I'm holding the device that will run the agent
> [ ○ ] remote sandbox — agent runs in a cloud LLM (OpenAI / Anthropic / etc.)
> [ ○ ] vendor hardware — I have a physical device (FoloToy bear, Pluto robot)
> ```
>
> `[ Label ]   FoloToy bear`
> `[ Vendor (optional) ]   FoloToy Inc.`
>
> `[ Continue → ]`

The "how will this agent be set up" selector determines the next screen — the bootstrap path. Three flavors:

- **this device:** the operator's primary master *is also* the agent's hardware. Rare; mostly for testing. Skip directly to scope grant.
- **remote sandbox:** the operator gets a pairing URL the agent's sandbox controller fetches. Used for ChatGPT (cloud), Claude (cloud).
- **vendor hardware:** the agent device displays a code (or scans a QR from the operator's UI); the device boots its own daemon, registers K10 on chain. Used for FoloToy / Pluto / similar.

The mapping to arch.md §22c.2's four backend kinds:

| Operator's choice | Backend variant from arch.md §22c.2 |
|---|---|
| this device | `DaemonBackend` (co-located) |
| remote sandbox | `HttpBackend` (talks to remote broker) |
| vendor hardware | `DaemonBackend` (per-vendor; daemon ships on the device) |
| (dev only) | `InMemoryBackend` (for fixtures) |

### §1.2 Bootstrap — "remote sandbox" path (most common)

The operator typed "ChatGPT (cloud)" as the label, chose "remote sandbox". UI calls `POST /v1/agents/bootstrap/remote { label, vendor }`. Daemon:

1. Mints a one-time **pair code** (4-word phrase or 8-digit code — operator chooses). The pair code is bound to the operator's session + the agent's about-to-be derivation.
2. Returns the pair code + a target URL (e.g. `https://sandbox.openai.com/agentkeys/pair?code=<code>`).
3. UI displays:

> *Configure your ChatGPT sandbox*
>
> *Paste this code into the AgentKeys plugin / connector inside your ChatGPT sandbox. The sandbox will then talk to your daemon to register itself.*
>
> ```
> ┌─────────────────────────────────────┐
> │  ocean · piano · ladder · echo      │   single-use · expires in 10 min
> └─────────────────────────────────────┘
> ```
>
> `[ Copy to clipboard ]`
>
> *Waiting for your sandbox to pair…*

The agent's sandbox controller (the OpenAI / Anthropic side) is responsible for picking up the code, exchanging it for a session-bound JWT, generating K10 in the sandbox's hardware boundary (or KMS-backed key), and calling `registerAgentDevice` on the chain.

This is exactly what the harness `v2-stage1-demo.sh` step 12 (`heima-agent-create.sh --label demo-agent`) does today, except the harness operator IS the agent — there's no remote sandbox. The web flow generalizes it.

### §1.3 Bootstrap — "vendor hardware" path

Operator unboxed a FoloToy bear. Powering it on the first time, the bear displays a 4-word phrase on its screen (or generates a QR).

UI calls `POST /v1/agents/bootstrap/vendor { label, vendor }`. Daemon returns a "scan or type the code from the bear" prompt:

> *Pair your FoloToy bear*
>
> *Your bear should be displaying a 4-word code. Type or scan it.*
>
> `[ ocean ___ ____ ____ ]`
> `[ camera scan ]`

When the operator enters matching codes on both sides, the bear's on-device daemon completes its registration directly with the operator's broker (using the pair-code as bearer authority). From the operator's UI perspective the experience is the same as the remote-sandbox flow.

### §1.4 Scope grant (same as stage-1 screen E)

After bootstrap completes (agent's K10 on chain, agent's daemon running), the operator grants scope. Identical to stage-1's part-2 screen E. The K11 master-mutation runs on the operator's primary.

### §1.5 First credential use

Once scope is granted, the agent can do work. The operator watches the audit feed:

> ```
> 14:32:08  FoloToy bear      cap.mint          memory:read scope=family ttl=900s     broker
> 14:32:08  FoloToy bear      memory.read       family/bedtime-story #14              memory
> ```

These events are real — they come from the agent's *actual* call to the memory worker, not from a simulated tick. Cap-mint + worker call typically land within ~100 ms of each other.

The agent's first **`cred.fetch`** event is the moment where the operator sees that vault decryption is gated by their on-chain scope:

> ```
> 14:33:22  FoloToy bear      cred.fetch        family/spotify-token (cap=cred:r ttl=300s)   creds
> ```

If the operator hadn't granted `family/read` for the credentials class, this call would have been a `cred.fetch.denied` event with `403` — visible in the same feed but red. The trust chain is observable.

---

## §2 — Live operations dashboard

This is the parent-control UI as the operator uses it day to day. It already exists in the codebase (PR #136 + PR-A/B/C) — this section documents what it must do, not what to build new.

### §2.1 The audit feed (`/audit`)

Live SSE from `/v1/audit/stream` (delivered in PR-C). Newest first. Filterable by worker chip. Click any row → modal with full event detail (`actor`, `cap_token_id`, `K10_signer`, `tier-1 vs tier-2 anchor status`).

**The discipline call-out:** the events come from real worker calls, not simulation. The operator should be able to trust that every row maps to a real action by a real agent. The harness `SIM_EVENTS` tick from the earlier prototype is **gone** — see [`input-discipline.md` §4](input-discipline.md).

### §2.2 Actor detail (`/detail/:actor`)

Per-namespace scope toggles, payment cap inputs, time-window editor, cap-tokens list with per-cap revoke, recent-activity panel filtered to this actor.

Every write here is a master-mutation (K11 assertion + chain commit). The triple toggle (`deny / read / read+write`) maps to `setScopeWithWebauthn(actor, namespace, ops_mask)` per arch.md §10.

The `revoke device` button is destructive — all of the actor's caps go to TTL=0 immediately via the SSE drop; the operator's UI flips the actor's status to `revoked`.

### §2.3 Anchor status (`/anchor`)

Countdown to next tier-2 batch (every 2 minutes per arch.md §11). Recent batches table with Merkle root + tx hash + confirmation count + explorer link.

**Why the operator looks at this:** to verify that yes, the audit feed they're watching IS being anchored on chain. Any tier-1 event they see can be cross-referenced against the Merkle root from its 2-min batch via the chain explorer.

### §2.4 Workers (`/workers`)

Five worker cards (memory, credentials, audit, email, payment) with per-actor usage share. Tap a card → detail with trust profile.

**Why the operator looks at this:** to confirm their agents are using the workers they should be using and nothing else. If "FoloToy bear" is suddenly showing payment-worker calls when it's only supposed to read memory, that's an anomaly worth investigating.

The data comes from `GET /v1/workers` (delivered in PR-C). Per-worker stats are aggregations the daemon computes from the audit log.

### §2.5 Cap-tokens panel (within actor detail)

Per actor's live cap-tokens. Each row: `cap_name`, `scope`, `ttl_remaining`, `minted_at`, `[revoke]`. Revoking a single cap doesn't invalidate the actor's other caps; revoking the device invalidates everything.

This is what stage-1 step 14 (`CredentialAudit.append`) exposes — every cap mint event has a row.

---

## §3 — Isolation health check (on-demand `/isolation-demo`)

This is where stage-3's 16 steps become a single operator action. The operator visits a new screen — `/isolation-demo` — and taps "run". The UI walks the 16 steps in front of them, against their real cloud, with their real STS creds, and reports green/red per step.

This is **not a unit-test runner.** It's an *operator-facing health check*: the operator should be able to prove, at any moment, that their stage-3 isolation guarantees still hold against their *current* deployment. If something regressed in a worker or in their AWS bucket policy, this surfaces it.

### §3.1 What the operator sees

> *Isolation health check*
>
> *We run the 4-layer isolation proof against your real cloud — your buckets, your IAM, your workers, your chain. Takes ~30 seconds. Safe to run any time; nothing is mutated.*
>
> *The 4 layers (see arch.md §17.2):*
> *  1. broker cap-mint rejects cross-actor requests*
> *  2. workers chain-verify the cap before any AWS call*
> *  3. AWS IAM PrincipalTag scopes S3 access to actor_omni*
> *  4. per-data-class bucket separation*
>
> `[ Run isolation check → ]`

On "Run": the screen turns into a live progress strip showing all 16 steps from `harness/v2-stage3-demo.sh`:

> ```
> [✓] step 1  · SIWE wallet auth → session JWT
> [✓] step 2  · mint OIDC JWT (for AWS STS)
> [✓] step 3  · AssumeRoleWithWebIdentity → STS creds (vault + memory)
> [✓] step 4  · POSITIVE — write to own vault prefix
> [✓] step 5  · NEGATIVE — cross-actor vault write blocked
> [✓] step 6  · NEGATIVE — cross-actor vault list blocked
> [✓] step 7  · POSITIVE — write to own memory prefix
> [⟳] step 8  · NEGATIVE — cross-actor memory write blocked (running…)
> [ ] step 9  · NEGATIVE — cross-actor memory list blocked
> [ ] step 10 · cross-bucket isolation (vault creds blocked on memory bucket)
> [ ] step 11 · worker encrypt/decrypt roundtrip — credentials
> [ ] step 12 · worker encrypt/decrypt roundtrip — memory
> [ ] step 13 · broker rejects cross-actor cap-mint
> [ ] step 14 · cred-class cap rejected by memory worker
> [ ] step 15 · memory-class cap rejected by cred worker
> [ ] step 16 · cleanup
> ```

Each row's status updates live (SSE).

### §3.2 What backs each step

| # | Action | Daemon endpoint |
|--:|---|---|
| 1 | mint a fresh session JWT via SIWE (no impact on operator's regular session) | `POST /v1/isolation/siwe` |
| 2 | mint an OIDC JWT bound to the test session | `POST /v1/isolation/oidc-jwt` |
| 3 | STS assume-role for vault + memory under the test JWT | `POST /v1/isolation/sts/mint` |
| 4 | write `bots/<own>/credentials/healthcheck.bin` | `POST /v1/isolation/write { bucket, prefix, content }` |
| 5 | try to write `bots/<other>/credentials/healthcheck.bin` — expect 403 | same endpoint, `expect: 'deny'` |
| 6 | try to list `bots/<other>/credentials/` — expect 403 | `POST /v1/isolation/list { bucket, prefix, expect: 'deny' }` |
| 7 | write `bots/<own>/memory/healthcheck.bin` | `POST /v1/isolation/write` |
| 8 | try to write `bots/<other>/memory/healthcheck.bin` — expect 403 | same |
| 9 | try to list `bots/<other>/memory/` — expect 403 | same |
| 10 | try vault creds on memory bucket (and reverse) — both expect 403 | `POST /v1/isolation/cross-bucket` |
| 11 | cap-mint `cred-store` + write + cap-mint `cred-fetch` + read → assert plaintext matches | `POST /v1/isolation/worker-roundtrip { class: 'credentials' }` |
| 12 | same for memory worker | `POST /v1/isolation/worker-roundtrip { class: 'memory' }` |
| 13 | call cap-mint with cross-actor `operator_omni` — expect HTTP 4xx | `POST /v1/isolation/cap-mint-cross-actor` |
| 14 | submit a cred-class cap to memory worker — expect `cap_data_class_mismatch` | `POST /v1/isolation/cap-cross-class { from: 'credentials', to: 'memory' }` |
| 15 | symmetric — memory-class cap to cred worker | same with reversed direction |
| 16 | delete the test objects | `POST /v1/isolation/cleanup` |

The "cross-actor" target for steps 5/6/8/9 is a *synthetic* `actor_omni` that doesn't exist in the operator's tree — picked deterministically so the test is reproducible. The objects written in steps 4/7/11/12 are tagged with a one-shot health-check prefix that step 16 nukes.

### §3.3 Report

After all 16 steps complete:

> *Isolation check · passed at 14:42:17*
>
> ```
> Layer 1 — broker cap-mint:        ✓  cross-actor rejected (step 13)
> Layer 2 — worker chain-verify:    ✓  cap_data_class_mismatch enforced (steps 14, 15)
> Layer 3 — AWS IAM PrincipalTag:   ✓  cross-actor prefixes blocked (steps 5, 6, 8, 9)
> Layer 4 — per-data-class buckets: ✓  cross-bucket creds blocked (step 10)
>
> All 16 invariants hold against your live deployment.
> ```

If any step fails:

> *Isolation check · FAILED at step 8*
>
> *Step 8 expected an `AccessDenied` when writing to `bots/<other-actor>/memory/healthcheck.bin`, but AWS returned `200 OK`.*
>
> *This means your memory-bucket policy is allowing cross-actor writes — a serious isolation breach. Stop here and investigate before granting any new agent scope.*
>
> *Likely cause: the memory bucket's policy `Statement[2]` is missing the `s3:ResourceTag/agentkeys_actor_omni = ${aws:PrincipalTag/agentkeys_actor_omni}` condition. See [`docs/arch.md`](../../arch.md) §17.2 layer-3 table.*
>
> `[ View detailed error ]`  `[ Re-run check ]`

### §3.4 Why the operator runs this themselves

Three reasons:
1. **Re-deploys are dangerous.** Every time the operator updates a worker / IAM policy / bucket policy, isolation can regress. The CI gate catches it before merge, but the operator's live deployment might be lagging behind CI by hours or days. Running this check after any deploy validates the actual production state.
2. **Trust is observable.** The operator should be able to *prove* their agents can't read each other's data. This isn't a value statement — it's a one-tap demonstration with green checks.
3. **Vendor pilots demand it.** When the operator pitches their AgentKeys deployment to a vendor partner, the vendor will want to see proof that their data is isolated from other actors. This screen is the proof.

### §3.5 What this screen is NOT

- **Not a CI replacement.** The harness's `v2-stage3-demo.sh` still runs in CI on every PR per `.github/workflows/harness-ci.yml`. Removing it would mean a regression could land in main between the operator's checks.
- **Not a chain-deploy validator.** The check runs against the deployed system; it doesn't verify the chain extrinsics or the contract source. That's `forge test` + `cargo test`.
- **Not safe under load.** The synthetic writes touch the operator's real buckets. If the operator's running production traffic, the test prefixes are isolated (`<actor>/.healthcheck/...`) so they don't collide with real data, but the operator should still run this during a maintenance window if they care.

---

## Summary mapping

For the reviewer who wants the harness-step ↔ UI-surface map at a glance:

```
stage-1 step 12  (create demo agent)       → §1 agent-create screen + bootstrap path
stage-1 step 13  (set scope with K11)      → §1.4 + §2.2 actor-detail
stage-1 step 14  (audit append)            → §2.1 audit feed (live event)

stage-3 steps 1-3   (SIWE → OIDC → STS)    → §3 step 1-3 (in isolation check)
stage-3 steps 4-9   (positive / negative S3 isolation) → §3 step 4-9
stage-3 step  10    (cross-bucket)         → §3 step 10
stage-3 steps 11-12 (worker roundtrips)    → §3 step 11-12
stage-3 step  13    (cross-actor cap-mint) → §3 step 13
stage-3 steps 14-15 (cap-class mismatch)   → §3 step 14-15
stage-3 step  16    (cleanup)              → §3 step 16

(everything else)                           → §2 steady-state dashboard
                                             — audit feed, actor detail,
                                               anchor status, workers
```
