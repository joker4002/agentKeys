# overview · operator user flow end-to-end

## The two-host model (read this first — it frames everything)

> **Updated 2026-05-31 after PR [#140](https://github.com/litentry/agentKeys/pull/140) + [#141](https://github.com/litentry/agentKeys/pull/141) merged.**

AgentKeys is the **Authority Host**: the operator's master, the daemon, this web UI. It owns identity, keys, scope, audit — the *policy decision*. The LLM runtime the operator's agents run on (Hermes today; Claude Code / Codex / OpenClaw next) is the **Task Host**: it owns the agent loop and the *work*. AgentKeys never becomes a Task Host (strategy §2.4 zero-orchestration line).

The product's load-bearing claim is the difference between an **IAM tool** and an **IAM guarantee** ([`agent-iam-guarantee-glossary.md`](../../wiki/agent-iam-guarantee-glossary.md)):

- An **IAM tool** is a permission function in the LLM's registry — the LLM decides whether to call it. A jailbreak skips it.
- An **IAM guarantee** is a non-LLM gate the *runtime* fires deterministically before the action runs. It **fails closed**. The LLM's intent is irrelevant.

`agentkeys wire <runtime>` turns AgentKeys' MCP tools into guarantees by installing runtime **hooks the LLM cannot bypass**. Everything the web UI does on the agent side exists to deliver + visualize that: the operator isn't handing the agent a permission tool it might ignore; they're wiring a gate it physically can't get around. See [`stage3-agent-usage.md`](stage3-agent-usage.md) for the full agent flow (pair → wire → the three acts).

## Phase 1 scope (this review)

**Phase 1 covers Act 1, steps 1–7 only.** This is the *become a master* slice: the operator opens the web app, types an email, enrolls Touch ID, gets their cloud provisioned, and lands on the chain as a registered master. After step 7 the operator's master identity exists end-to-end and the parent-control UI can render the master-detail page with the master's vault + memory listings.

Everything after step 7 — first agent creation, scope grant, audit ping, second-master pairing, recovery drill, isolation health check — is on the [TODO list](#todo-list--out-of-phase-1-scope) at the bottom of this document. Those become Phase 2 / Phase 3 reviews.

The narrative below describes the full three-act arc for context, but the *contract that backs Phase 1 implementation* is the first 7 steps + the endpoint inventory at the end.

---

A first-time operator opens the parent-control web UI. They have nothing yet — no keys, no chain identity, no AWS infra. By the end of Phase 1 they have all of those, plus the ability to see (an empty) credentials vault and memory store under their own master actor. Acts 2 and 3 (currently TODO) layer on agents, second masters, and live workloads.

## Act 1 — first run · become a master *(Phase 1: steps 1–7)*

*Source: [`harness/v2-stage1-demo.sh`](../../../harness/v2-stage1-demo.sh) steps 1–11.*

The operator visits the parent-control URL. The app detects there is no local session and routes them straight to onboarding. There is no log-in form on the landing page because there is nothing to log in to yet — the first action is **becoming an operator**, not authenticating an existing one.

### Step 1 — tell me who you are

A single screen asks for the operator's real email address. The UI POSTs to `POST /v1/auth/email/start` and tells the operator to check their inbox. The email is **operator-typed and real** — see [`input-discipline.md` §1](input-discipline.md). *(Harness step 6.)*

### Step 2 — click the magic link

The link opens in any browser tab; the daemon proxies the verification to the broker and posts a `binding_nonce` plus the operator's deterministic Ethereum wallet back to the UI. The original tab (which has been polling `GET /v1/auth/email/status`) advances. The UI displays "your master wallet is `0xf3a8…`" — a wallet the operator never had to manage a seed phrase for. *(Harness step 6 continued.)*

### Step 3 — register a device key

The UI tells the daemon to derive K10 — the local-machine secp256k1 keypair — and store it in the platform keychain. Touch ID / Windows Hello unlocks the keychain; the operator sees a single OS-native dialog. K10 derivation is folded into the next step's request (`POST /v1/k11/enroll/begin` triggers it server-side so the operator doesn't see a separate click). *(Implicit in harness step 6; explicit in arch.md §10.)*

### Step 4 — enroll a passkey for biometric approval

Real `navigator.credentials.create()` runs. The platform authenticator generates K11. The challenge bytes — `sha256(binding_nonce ‖ D_pub)` — come from the daemon. The browser shows the OS Touch ID prompt; the operator authenticates. The credential never leaves the device. *(Harness step 11.)*

### Step 5 — provision the operator's cloud, then show what's in it

This step combines two concerns the user explicitly asked to bind together:

**Part A — bucket + role + policy provisioning.** The UI shows a one-screen progress strip: "creating vault bucket… memory bucket… IAM roles… policies…". The daemon delegates to the existing `scripts/provision-vault-bucket.sh`, `scripts/provision-vault-role.sh`, `scripts/apply-vault-bucket-policy.sh`, `scripts/provision-memory-bucket.sh`, `scripts/provision-memory-role.sh`, `scripts/apply-memory-bucket-policy.sh`. The UI renders the operator-readable status of each as SSE events. *(Harness step 7.)*

**Part B — show the master's current vault + memory contents.** As soon as provisioning completes the UI lists, side-by-side:

> ```
> ── your credentials (vault)                       0 entries
> ── your memories (memory)                         0 entries
> ```

For a brand-new operator both are empty. For an operator who's re-running onboarding (e.g. on a new device) they may have entries already, populated by past agent activity — the listings appear immediately and confirm "yes, this is your data; you're not staring at a stranger's cloud."

These listings come from two new daemon endpoints scoped to the master actor:

- `GET /v1/master/credentials` — returns metadata only (service, last write, size), never plaintext.
- `GET /v1/master/memory` — returns memory entries' keys + metadata.

The master actor's omni is the operator's `actor_omni` (derived from email per arch.md §10). The S3 prefixes the daemon lists from are `s3://<vault-bucket>/bots/<master_omni_hex>/credentials/*` and `s3://<memory-bucket>/bots/<master_omni_hex>/memory/*` — the operator's own prefix, scoped by IAM PrincipalTag per arch.md §17.2 layer 3.

**Why "master credentials" and "master memory" at all.** Per arch.md §6.2 (HDKD actor tree) the master is *also* an actor. Agents are HDKD children of it. Credentials the master stores about themselves (e.g. their personal OpenRouter key, used when they invoke an agent interactively) live under `master_omni`'s prefix — not under any agent's prefix. The UI surfacing this from step 5 onward is the operator's first window into their own cloud.

### Step 6 — smoke-test cloud isolation

With the STS creds the operator's wallet can mint, the UI writes one envelope to `s3://vault/bots/<master_omni_hex>/credentials/.healthcheck/smoke.test` and reads it back. If the round-trip fails, the UI pauses with the actual error from AWS. If it succeeds, the operator sees a single green check — and the listing from step 5's Part B updates to show the smoke-test entry (so they see their own data appear in their own UI). The `.healthcheck/` prefix is the marker; the operator can leave it or delete it once they trust the round-trip. *(Harness step 8.)*

### Step 7 — anchor your identity on chain

The UI deploys (or detects already-deployed) the four contracts — SidecarRegistry, AgentKeysScope, K3EpochCounter, CredentialAudit — and then calls `register_master_device(D_pub_hash, K11_cred_id_hash, roles=CAP_MINT|RECOVERY|SCOPE_MGMT)`. The K11 assertion for the register call runs through the new `POST /v1/k11/assert/{begin,finish}` pattern. This is the moment the operator becomes a real on-chain identity. *(Harness steps 9 + 10.)*

After step 7 the operator's master is fully wired:

- on chain: contracts deployed, master device registered, K11 cred_id committed
- on AWS: vault + memory buckets exist with policies scoped to `master_omni_hex`
- locally: K10 in keychain, K11 cred id on disk, session JWT alive
- in the UI: master-detail page renders, vault + memory listings work, audit feed has 1 entry (the DeviceRegistered event)

**Phase 1 ends here.** The operator is in a steady state where they can re-open the UI on this device and land on the master-detail page; the onboarding wizard never reappears for this operator on this device.

---

## Phase 1 endpoint inventory (the only new endpoints to build)

Every endpoint Phase 1 needs. Anything not on this list is out of scope until Phase 2.

| Step | New endpoint | Method | Purpose |
|---|---|---|---|
| umbrella | `/v1/onboarding/state` | GET | single endpoint the UI reads on every navigation to decide which screen to render |
| 1 | `/v1/auth/email/start` | POST | proxies broker's email magic-link issue; takes `{ email }` |
| 1→2 | `/v1/auth/email/status` | GET (poll) | original tab polls; returns `pending` / `verified` |
| 2 | `/v1/auth/email/verify` | POST | called by the tab that opened the magic link; returns `{ session_jwt, wallet_address, actor_omni, binding_nonce }` |
| 5 (Part A) | `/v1/onboarding/cloud/provision` | POST | dispatches the 6 existing provision-*.sh scripts |
| 5 (Part A) | `/v1/onboarding/cloud/stream` | GET (SSE) | per-script progress events |
| 5 (Part B) | `/v1/master/credentials` | GET | metadata-only listing of master's vault prefix |
| 5 (Part B) | `/v1/master/memory` | GET | metadata-only listing of master's memory prefix |
| 6 | `/v1/onboarding/cloud/smoke` | POST | one-shot envelope round-trip + result |
| 7 | `/v1/onboarding/chain/deploy` | POST | deploys (or detects) the 4 contracts |
| 7 | `/v1/onboarding/chain/register-master` | POST | calls `register_master_device(...)` on chain after a K11 assertion completes |
| 7 | `/v1/k11/assert/begin` | POST | two-step K11 assertion: build challenge, return `assertion_id` |
| 7 | `/v1/k11/assert/finish` | POST | submit the WebAuthn assertion; daemon submits the on-chain extrinsic |

**Shipped already** (PR-B / PR-C) and reused without changes by Phase 1:

| Endpoint | Source |
|---|---|
| `GET /healthz` | PR-B |
| `POST /v1/k11/enroll/begin` | PR-B |
| `POST /v1/k11/enroll/finish` | PR-B |

That's the complete contract Phase 1 implementation works against. Twelve new endpoints. No others.

---

## State machine sketch *(Phase 1 fragment)*

```
                ┌─────────────────────────┐
   visit URL ──▶│  /onboarding/identity   │  no local session
                └────────────┬────────────┘
                             │ email submitted
                             ▼
                ┌─────────────────────────┐
                │  await magic link       │  broker pending
                └────────────┬────────────┘
                             │ link clicked (any tab)
                             ▼
                ┌─────────────────────────┐
                │  /onboarding/keys       │  K10 + K11 + Touch ID
                └────────────┬────────────┘
                             │ K11 enrolled
                             ▼
                ┌─────────────────────────┐
                │  /onboarding/cloud      │  bucket + role + STS + smoke + vault/memory listings
                └────────────┬────────────┘
                             │ provision green
                             ▼
                ┌─────────────────────────┐
                │  /onboarding/chain      │  contracts + register_master_device
                └────────────┬────────────┘
                             │ master device on-chain
                             ▼
                ┌─────────────────────────┐
                │  /master                │  master-detail home screen (Phase 1 terminus)
                └─────────────────────────┘
```

Subsequent sessions land on `/master` directly — `GET /v1/onboarding/state` returns `chain: 'master-registered'` and the UI skips the wizard.

## Resumability invariants *(Phase 1)*

The harness scripts run as a single shell process — if the operator's terminal closes mid-step, they re-run with `--from-step N` to pick up. The web flow needs the same property:

1. **Every onboarding step writes the same on-disk + on-chain artifacts the harness writes.** If the UI crashes between step 4 (K11 enrolled) and step 5 (cloud provisioned), the next time the operator opens the URL, the UI inspects what's already on disk + chain and routes them directly to step 5. They never re-enroll K11 unless K11 is gone.
2. **The daemon owns the resume logic.** `GET /v1/onboarding/state` returns the aggregated state; the UI reads it on every navigation and renders the right screen.
3. **Re-onboarding a device that's already a master is allowed.** When the operator opens the UI on a different browser / new install, `GET /v1/onboarding/state` confirms `chain: 'master-registered'` and the UI lands at `/master`. The vault + memory listings populate from chain + S3, reproducing the same view the operator saw on the first device.

---

## TODO list — out of Phase 1 scope

Everything below is *deferred* until Phase 1 is reviewed + shipped. Each item links to where it's currently planned in the other docs.

### Out-of-Phase-1 Act 1 steps

These were drafted in [`stage1-first-run.md`](stage1-first-run.md) but defer past step 7:

- **Step 8 — create your first agent.** Operator picks label + vendor → `POST /v1/agents/create` → chain `registerAgentDevice(...)`. *(Harness step 12.)*
- **Step 9 — decide what the agent is allowed to do.** Per-namespace scope toggles + payment cap inputs + time-window → K11 assertion → `setScopeWithWebauthn(...)`. *(Harness step 13.)*
- **Step 10 — watch the agent use a credential.** One demo `CredentialAudit.append` from the operator's own session → visible in audit feed within 200 ms. *(Harness step 14.)*

### Act 2 — defense in depth (entire act, currently in [`stage2-second-master.md`](stage2-second-master.md))

- Pair a companion master device (QR pairing, companion K11 enroll, primary signs the addition)
- Raise `recoveryThreshold` to 2 (2-of-2 quorum on chain)
- Recovery drill: register a synthetic spare, revoke it via 2-of-2 quorum (proves the gate works)

### Phase 2 — add an agent · the wire flow (redesigned for #141, now in [`stage3-agent-usage.md`](stage3-agent-usage.md))

This is the agent half of the product, fully reframed around the Authority/Task-Host model. It is the next implementation phase after the master onboarding (Phase 1) ships.

- **Choose runtime + scope** — Hermes now; Claude Code / Codex / OpenClaw gated on #133 adapters. Namespaces + payment scope are Real operator inputs.
- **Pair (Phase P)** — the agent's device key is *born in its own runtime* (`agentkeys agent device-session`) and never touches the master; the master binds it on-chain (`registerAgentDevice`) and approves its scope via Touch ID (`heima-scope-set --webauthn`).
- **Wire (Phase 2)** — `agentkeys wire <runtime>` installs the three IAM-guarantee hooks (`pre_tool_call`→check, `post_tool_call`→audit, `pre_llm_call`→memory-inject) into the runtime config; the LLM cannot bypass them. Idempotent; drift-detectable via `--check-only`.
- **The three acts** — Permissioned Memory, Deterministic Denial (fails closed), Auto-audit; plus the memory-aware "surprise" (deterministically backed by `hermes hooks test pre_llm_call`, not a chat reply).
- **Live dashboard** — audit feed tagged by hook; guarantee-health panel (wired? fail-closed armed? last block?); scope/revoke/**unwire** (Act 3 online revocation, live here).
- **On-demand isolation health check** (preserved) — the 16-step v2-stage3 proof against the operator's real cloud.

> The prior "agent bootstrap: this-device / remote-sandbox / vendor-hardware (paste-a-pair-code)" design is **superseded** by the wire flow above. The proxy fallback for hooks-less hosts (xiaozhi-server, mobile SDKs) is arch.md §22d.3 / Phase 3b.

### Act 2 — second master · still applies (in [`stage2-second-master.md`](stage2-second-master.md))

Unchanged by #141 — the companion-master + recovery-quorum flow is orthogonal to the agent wire flow.

### Open questions still pending review

These were collected in [`deferred-and-followups.md`](deferred-and-followups.md). The ones that block Phase 1 are flagged here:

- Q1 (onboarding screen merging) — defer; Phase 1 keeps 4 screens (identity / keys / cloud / chain).
- Q2 (pair-flow JWT lifetime) — N/A in Phase 1 (no pairing yet).
- Q3 (cross-browser passkey behavior) — **blocks Phase 1** for operators who switch browsers between magic-link click and the rest of the flow. Needs a spike during Phase 1 implementation.
- Q4 (email change) — defer to post-v0.
- Q5 (multi-operator handoff) — defer to M5+.
- Q6 (anchor verification flow) — N/A in Phase 1 (no audit feed displays yet at end of step 7 beyond the single DeviceRegistered event).

---

## Where the harness still has the operator's terminal *(unchanged from previous draft)*

These remain shell-only forever:

| Harness step / runbook | Stays shell? Why |
|---|---|
| `scripts/heima-bring-up.sh` (one-shot chain genesis) | Run once per operator deployment, by the SRE who controls the deployer wallet. Not parent-facing. |
| `scripts/setup-broker-host.sh --upgrade` (EC2 / nginx / certbot tweaks) | Operator-cluster infrastructure, not consumer-facing. |
| K3 epoch rotation (`docs/runbook-k3-rotation.md`) | Today shell-only; web UI promotion deferred to M5+. |
| `harness/v2-stage3-demo.sh` itself in CI | Stays in CI as the gate that proves the production isolation invariants. The UI runs equivalent live checks (Phase 2+) but does NOT replace the CI gate. |
