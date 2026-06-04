# input-discipline · real vs derived vs auto-generated inputs

This document fixes terminology that the three stage docs depend on. Every value the web UI handles falls into one of three categories. Mistakes happen when the categories blur — most commonly when a synthetic test value (from the harness or the prototype) gets confused for an operator-typed input.

## The three categories

| Category | Definition | Examples | Source of truth |
|---|---|---|---|
| **Real** | The operator types this value. Reflects their actual identity, intent, or property of the real world. | login email, agent label, payment cap amount, time-window hours, scope toggle (deny/read/write) | the operator |
| **Derived** | Computed by the system from real inputs (and possibly other derived values). Always reproducible from its inputs. | `actor_omni`, `wallet_address`, `D_pub_hash`, agent's `child_omni = HDKD(master_omni, label)`, `binding_nonce`, `cap_token_id`, agent inbox address | a deterministic function |
| **Auto-generated** | Created by the system fresh, with entropy, when needed. Not reproducible. | K10 keypair, K11 credential id, pairing token, isolation-check synthetic `actor_omni`, deployer wallet (during chain bring-up), session JWT signing key (broker-side) | the system's CSPRNG |

The discipline: any field that takes operator input must be Real. Any value displayed to the operator (so they recognise it later) must be either Real or Derived from Real. Auto-generated values are internal — the operator sees them only when they're explicitly secrets (a recovery code, a passkey id) and even then sees them once and then they're on disk / in a keychain.

## §1 — The operator's login email vs. the agent's inbox address

This is the source of the user's review note. It's worth resolving once, clearly.

### §1.1 The operator's login email — **Real**

The operator types their real email when they first open the UI. It's the email *they* read, on a phone or laptop they own.

- Used for: broker `/v1/auth/email/start` → magic link → managed-wallet attestation → session JWT.
- Stored at: broker (associated with the operator's wallet + actor_omni) + locally in OS keychain as part of the session record.
- Lifetime: as long as the operator's account exists. Changing it is a master-mutation (not in scope for v0; would be a deferred follow-up).
- Visibility: the operator sees this in the header strip (`Sara · O_master · iPhone 17 Pro`) and on the master-detail page.

**The harness uses `demo-N@bots.litentry.org` because the demo runs in a domain SES has verified.** A real operator running the deployed web UI types their own email. The broker's allowed-domain check (configured per deployment via env var) gates which domains are accepted. See [`docs/v2-stage1-migration-and-demo.md`](../../v2-stage1-migration-and-demo.md) §0.0 for why `@example.com` placeholders are rejected (RFC 2606 reserved → magic link goes into the void).

### §1.2 The agent's inbox address — **Derived**, NOT operator-typed

When an agent needs to receive emails — to verify a signup, get an OTP, claim a token — the agent does NOT use the operator's email. Doing so would:

- conflate identities (the agent acting on behalf of the operator vs. the operator-as-themselves);
- give the agent access to the operator's other mail;
- violate arch.md §15.4 ("per-actor inbox" is keyed on `actor_omni`).

Instead, the email-service worker per arch.md §15.4 routes a *derived* sub-address to that agent's actor-scoped S3 prefix:

```
agent label                  →  derived sub-address
─────────────────────────────────────────────────────────────────
FoloToy bear                 →  agent-folotoy@bots.litentry.org
ChatGPT (cloud)              →  agent-chatgpt@bots.litentry.org
Pluto (home robot)           →  agent-pluto@bots.litentry.org
```

These sub-addresses are **derived from** the operator's chosen agent label + the operator's deployment's email domain (`bots.litentry.org` in the canonical deployment, configurable per-operator). They are NOT typed by the operator. The operator chose the label; the system derived the sub-address.

The SES routing layer (Lambda extension per arch.md §15.4) maps each sub-address to a per-actor S3 prefix:

```
agent-folotoy@bots.litentry.org  →  s3://email-bucket/bots/<O_master//folotoy>/inbound/*
```

The agent presents a cap-token to read from its own inbox prefix; cross-actor reads are blocked by the same `PrincipalTag/agentkeys_actor_omni` chain as every other worker (arch.md §17.2 layer 3).

### §1.3 The UI's responsibility

The UI must:

1. **Show the operator's email** prominently — in the header, on the master-detail page. It's their identity.
2. **NEVER use the operator's email as an agent inbox.** When an agent needs to receive verification, the UI displays the derived sub-address (`agent-folotoy@bots.litentry.org`) and copies it to the clipboard. The operator does NOT pick the sub-address; they pick the agent label, and the sub-address is shown to them so they can verify what was derived.
3. **Display agent inboxes on the actor-detail page** as a row in the "workers in scope" section when the agent has `email-service` in scope: e.g. *"FoloToy bear · receives mail at agent-folotoy@bots.litentry.org"*.
4. **Surface the inbox list** when the operator wants to debug: a small modal showing the recent inbound messages to the agent's sub-address. Agent reads happen via cap-tokens; operator reads via master authority.

### §1.4 The two emails in the audit feed

Both addresses are visible in the audit feed but tagged distinctly:

| Event | Address shown | Tag |
|---|---|---|
| operator's login (manual / not common after onboarding) | `sara@example.com` | `K6 · session JWT` |
| agent inbox receive | `agent-folotoy@bots.litentry.org` | `email worker` |
| agent inbox read | `agent-folotoy@bots.litentry.org` | `email worker · cap=mail:inbox` |

A reviewer who searches the audit feed for the operator's real email should find only login events (and zero agent-driven traffic). A reviewer searching for an agent's sub-address should find only that agent's mail events. Cross-contamination is the smell.

## §2 — The agent label vs. the agent's on-chain derivation

The operator types **the label** ("FoloToy bear"). The label is Real.

The agent's on-chain identity is **derived**:

```
agent_omni = HDKD(master_omni, label)    // per arch.md §6.2
device_pubkey_hash = keccak256(D_pub_agent)  // K10 from the agent's own hardware
```

The UI shows:
- The label everywhere user-facing.
- The hex `agent_omni` (truncated, `0x7c2d…41a9`) on the actor-detail page for operators who want to verify on chain.
- The full hex `device_pubkey_hash` only inside the "binding" panel (advanced detail).

The agent's *derivation path* (`//folotoy` from `O_master`) is shown explicitly in the actor list — that's a Real-looking detail that's actually Derived from the label.

> **#141 note — fresh-pairing changes where `device_pubkey` comes from.** Under the wire flow ([`stage3-agent-usage.md`](stage3-agent-usage.md) §1.2), the agent's K10 device key is generated **in the agent's own runtime** by `agentkeys agent device-session`, not on the master. So `actor_omni` + `device_key_hash` arrive at the master as **Real outputs of the agent's keygen** — the master receives them, doesn't derive them, and binds them on-chain. They're still Derived *from the agent's side* (deterministic from the agent's key), but from the **master/UI's** vantage they're inbound values to be verified (via `pop_sig`), not computed. The UI must never claim to have generated the agent's key — the whole guarantee is that it didn't.

## §2.5 — The agent's runtime + wire inputs

PR #141 adds new inputs on the agent-onboarding path. Their categories:

| Input | Category | Notes |
|---|---|---|
| **runtime** (Hermes / Claude Code / Codex / OpenClaw) | **Real** | Operator-selected. Gated on what `agentkeys wire` supports — only options with a shipped `RuntimeAdapter` are selectable (Hermes today; the rest are disabled with their #133 tracking link, **never faked**). |
| **memory namespaces** (`travel`, `family`, …) | **Real** | Operator-selected checkboxes → `agentkeys wire --namespaces`. The `pre_llm_call` hook injects *only* these. |
| **payment scope + daily cap** | **Real** | Operator-typed → `--payment-scope` + the MCP server's `--default-daily-spend-cap-rmb`. The `pre_tool_call` `check` hook enforces the cap deterministically. |
| **link-code** (pairing) | **Auto-generated** | Minted by `/v1/agents/pair/init`; single-use; the agent's `device-session --link-code` echoes it back for binding. Shown to the operator only as a transient pairing token. |
| **device key / `pop_sig`** | **Auto-generated, in the agent's runtime** | Born in the sandbox, `0600`, never leaves. The master sees only the public address + proof-of-possession. |
| **the managed `hooks:` block** | **Auto-generated** | Written by `agentkeys wire` into the runtime config, sentinel-delimited. The "preview what gets written" affordance shows it verbatim; the operator does not hand-author it. |

The discipline that matters most here: **the runtime list reflects real adapter support, and the agent key is never operator- or master-supplied.** Both are honesty guarantees — don't show a runtime the wire CLI can't drive, and don't imply the master holds the agent's private key.

## §3 — Payment caps, time-windows, scope toggles

All **Real**. Operator-typed. No defaults pre-filled with non-trivial values (defaults are `deny` everywhere on first scope grant, `0` USDC on payment caps, `00:00–24:00` on time-window).

The UI never invents a payment cap as a "reasonable default" — the operator's chosen number is the only number stored. (A "suggested starting point" copy line in the empty state, e.g. *"most operators start with 5 USDC per transaction for class-C agents"*, is fine; pre-filling the field is not.)

## §4 — The dead `SIM_EVENTS` problem

The prototype the design started from (`apps/parent-control/.../data.ts`, deleted in PR-A) shipped with a `SIM_EVENTS` array — synthetic audit events looped on a 4.2 s tick so the feed visibly moved during the demo. They were Auto-generated values pretending to be Real events.

**The plan's posture:** there is no `SIM_EVENTS` in the implementation. The audit feed shows only real events from the audit-service worker. When the operator first opens the UI after stage-1 completes, the feed is empty until an agent actually does something. The `POST /v1/onboarding/agent/audit-ping` from stage-1 screen F is the single deliberate exception — *one* event with `kind: 'onboarding.complete'` and a comment so an operator inspecting the audit log later sees that yes, this was a system-generated welcome ping.

If a demo path *needs* a populated feed (e.g. operator's first pitch to a vendor partner with no real agent activity yet), the demo path is the **isolation health check** (stage 3 §3) — which produces real events from a real synthetic actor.

## §5 — Chain values: deployer, master, agent

The operator's primary identity on chain is **`master_omni = SHA256("agentkeys" ‖ "email" ‖ email)`** — Derived from the Real login email. (Per arch.md `identity_omni` discussion.) The operator never types this; the UI shows the first/last 12 hex chars on the master-detail page.

The deployer wallet (the wallet that pays gas for chain bring-up) is per-operator-deployment. On `heima-paseo` it's funded by sudo; on `heima` mainnet the operator-cluster admin pre-funds it from their treasury. **The deployer wallet is invisible to the parent operator.** The parent's master wallet (`session_wallet`) is what they see — derived from their email + signer-bound, distinct from the deployer.

Confusing the deployer wallet with the master wallet is a real bug we've hit during stage-1 dev. The UI surfaces `master_wallet` everywhere, never `deployer_wallet`.

## §6 — Quick checklist for new screens

Before any UI screen ships, the reviewer should ask, for every editable field and every displayed value:

- Real, Derived, or Auto-generated?
- If Real: does the underlying daemon endpoint persist it? Is there a validation gate?
- If Derived: is the derivation function in arch.md or another spec doc? Does the UI re-derive on display rather than storing the derived value locally?
- If Auto-generated: where is the entropy from? Where does the value end up at rest? When is it shown to the operator and when is it not?

A field that can't answer those three questions cleanly should not ship.
