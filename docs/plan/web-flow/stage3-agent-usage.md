# stage3-agent-usage · add an agent · wire IAM-guarantee hooks · the three acts

> **Redesigned 2026-05-31 after PR #141 merged.** The old agent-onboarding flow
> in this doc ("paste a pair-code into your ChatGPT sandbox" + per-actor S3
> isolation) is gone. PR [#140](https://github.com/litentry/agentKeys/pull/140)
> (IAM strategy reset — hooks-first wire architecture) + PR
> [#141](https://github.com/litentry/agentKeys/pull/141) (`agentkeys wire` +
> `agentkeys hook`) replaced it with the **Authority-Host / Task-Host** model.
> This doc now maps that model into the parent-control web UI.

**Source script:** [`harness/phase1-wire-demo.sh`](../../../harness/phase1-wire-demo.sh) — Phases 0/1/P/2/3/4/5.
**Source runbook:** [`docs/operator-runbook-wire.md`](../../operator-runbook-wire.md) — the single harness-first operator doc.
**Source CLI:** `agentkeys wire`, `agentkeys hook check|audit|memory-inject`, `agentkeys agent device-session` ([`crates/agentkeys-cli/src/{wire,hook,device_session}.rs`](../../../crates/agentkeys-cli/src/)).
**Canonical reference:** [`docs/arch.md`](../../arch.md) §22d (IAM-guarantee delivery), §22c.2 (MCP backend variants); [`docs/agent-iam-strategy.md`](../../agent-iam-strategy.md) §2.1/§3.6/§3.7; [`docs/wiki/agent-iam-guarantee-glossary.md`](../../wiki/agent-iam-guarantee-glossary.md) (tool-vs-guarantee).

---

## The mental model the UI has to teach

Two hosts, one boundary. The operator must understand which side they're on.

| | **Authority Host** | **Task Host** |
|---|---|---|
| What it is | AgentKeys — the operator's master, daemon, and this web UI | The LLM runtime — Hermes (Phase 1.a), later Claude Code / Codex / OpenClaw |
| Owns | identity, keys (K1–K11), scope, audit, the *policy decision* | the agent loop, the prompt, the tool calls, the *work* |
| In the demo | the operator's MacBook + parent-control UI | the agent's sandbox |

The thing that makes a scope grant *real* is the distinction in
[`agent-iam-guarantee-glossary.md`](../../wiki/agent-iam-guarantee-glossary.md) §1:

- An **IAM tool** is a function in the LLM's tool registry. Whether the policy
  check runs is decided by the LLM — prompt + sampling. A jailbreak skips it.
- An **IAM guarantee** is a non-LLM gate in the execution path. The *runtime*
  fires it deterministically, before the action runs. The LLM's intent is
  irrelevant. It **fails closed**.

`agentkeys wire <runtime>` is how AgentKeys turns its MCP tools into
guarantees: it installs runtime **hooks** the LLM cannot bypass. That is the
single most important thing the agent screens in the web UI exist to convey —
"you didn't just hand the agent a permission tool it might ignore; you wired a
gate it physically cannot get around."

This doc has three surfaces:

| § | Surface | What the operator does |
|--:|---|---|
| **1** | **Add an agent** (pair → wire → the three acts) | install an agent on a runtime, approve its scope with Touch ID, watch the guarantees come alive |
| **2** | **Live operations dashboard** | watch the hooks fire — permission blocks, memory injects, audit rows — and manage scope/revoke |
| **3** | **Isolation health check** (preserved from the prior design) | run the per-actor + per-data-class isolation proof on demand against the real cloud |

---

## §1 — Add an agent

The flow has three phases, mapped 1:1 to the harness's Phase P → Phase 2 → Phase 3/4. The web UI is the **Authority Host's** view of each; the actual agent-side work (keygen, hook scripts) happens in the agent's runtime/sandbox, and the UI observes + drives the master-side gates.

```
  ┌─ §1.1 choose ─┐   ┌─ §1.2 pair (Phase P) ──────┐   ┌─ §1.3 wire (Phase 2) ─┐   ┌─ §1.4 use (Phase 3/4) ─┐
  │ runtime       │ → │ device key born in sandbox │ → │ install 3 IAM hooks   │ → │ permissioned memory    │
  │ + scope       │   │ master binds on-chain      │   │ into runtime config   │   │ deterministic denial   │
  │ (Real inputs) │   │ master approves (Touch ID) │   │ (LLM can't bypass)    │   │ audit + the surprise   │
  └───────────────┘   └────────────────────────────┘   └───────────────────────┘   └────────────────────────┘
```

### §1.1 — Choose runtime + scope

From the actor list, the operator taps **add agent**.

> *Add an agent*
>
> *An agent is an LLM runtime acting on your behalf with permissions you control and can revoke. You'll install AgentKeys' permission gate into it so the model can't act outside what you grant — even if it's jailbroken.*
>
> **Which runtime does this agent run?**
> ```
> [ ● ] Hermes          ✅ supported now (Phase 1.a)
> [ ○ ] Claude Code     ◷ #133 — adapter coming
> [ ○ ] Codex           ◷ #133 — adapter coming
> [ ○ ] OpenClaw        ◷ #133 — adapter coming
> ```
>
> `[ Label ]            e.g. "travel-bot"`
>
> **What can it read? (memory namespaces)**
> ```
> [x] travel     [ ] family     [ ] work     [ ] personal
> ```
>
> **Can it spend? (payment scope)**
> ```
> [x] payment.spend     daily cap [ 500 ] RMB
> ```
>
> `[ Continue → ]`

Every field here is a **Real** operator input ([`input-discipline.md`](input-discipline.md) §1). The runtime list is gated on what `agentkeys wire` actually supports — only Hermes is selectable today (the `RuntimeAdapter` seam in [`wire.rs`](../../../crates/agentkeys-cli/src/wire.rs) is where #133 slots Claude Code / Codex / OpenClaw). The namespaces map to the `--namespaces` wire flag; the payment scope + cap map to `--payment-scope` and the MCP server's `--default-daily-spend-cap-rmb`.

**No mock data.** If `agentkeys wire` doesn't yet support the chosen runtime, the option is disabled with the tracking issue, not faked.

### §1.2 — Pair (Phase P): the agent's key is born in the sandbox

This is the §10.2 fresh-pairing ceremony. The defining property: **the agent's device key is generated inside the agent's runtime and never touches the master.** The master only ever sees the agent's *public* key, binds it on-chain, and approves its scope.

The web UI shows a three-step progress card mirroring harness Phase P:

> *Pairing "travel-bot" · its key is generated on its own device, never on yours*
>
> ```
> [⟳] P.1  agent generates its device key + session   (in the runtime/sandbox)
> [ ] P.2  you bind its device on-chain               (registerAgentDevice)
> [ ] P.3  you approve its [travel] scope             🔐 Touch ID
> ```

**P.1 — `agentkeys agent device-session`** runs in the agent's runtime. It generates a secp256k1 device key (k256/sha3), derives `actor_omni`, and mints a `wallet_sig` session whose EIP-191 signing matches the broker's `ecrecover`. It emits `{ agent_address, actor_omni, device_key_hash, pop_sig, session_bearer }`. The key file is sandbox-local, `0600`, and never leaves. *(harness `P.1`; [`device_session.rs`](../../../crates/agentkeys-cli/src/device_session.rs).)*

**P.2 — master binds the device on-chain.** The UI calls the daemon to run `heima-agent-create --from-pubkey --agent-address <addr> --actor-omni <omni> --device-key-hash <hash> --pop-sig <sig>` → `registerAgentDevice`. The master signs with its own key; it bound a device whose private key it has never seen, attested by the agent's `pop_sig`. *(harness `P.2`.)*

**P.3 — master approves the scope (Touch ID).** The UI runs the K11 ceremony: `heima-scope-set --webauthn --agent travel-bot --services travel` (or whatever §1.1 selected). The operator's real Touch ID prompt fires. This is the on-chain scope grant — the moment the agent *earns* its permission. *(harness `P.3`.)*

> 🔐 *Approve travel-bot's permissions*
> *travel-bot is asking to read your **travel** memory. Approve with Touch ID to grant it on-chain.*
> `[ Approve with Touch ID → ]`

After P.3 the fresh actor exists on-chain with an empty memory and a `travel`-scoped grant. Because the identity is brand-new, the UI offers to **seed** a first memory so the agent has something to recall (harness step `1.5`) — operator-supplied content, or skip.

**Why "born in the sandbox" matters in the UI copy:** the prior design generated the agent key on the laptop and shipped it out — a key-custody smell. The redesign's headline guarantee is that the master holds *no* agent private keys. The pairing card says so explicitly: *"its key is generated on its own device, never on yours."*

### §1.3 — Wire (Phase 2): install the IAM-guarantee hooks

Now the agent has an identity and a scope. Wiring is what makes that scope *unbypassable*. The UI shows what `agentkeys wire <runtime>` installs:

> *Wire travel-bot's runtime · install your permission gate*
>
> *This writes AgentKeys' three hooks into Hermes's config. From now on the model **cannot** read memory it isn't granted, **cannot** exceed your spend cap, and every action is logged — no matter what the model decides.*
>
> ```
> hook                         fires on            guarantee
> ───────────────────────────  ──────────────────  ─────────────────────────────────────
> agentkeys hook check         pre_tool_call       blocks over-cap / out-of-scope actions
>                              (pay|order|spend…)   — fails CLOSED if AgentKeys unreachable
> agentkeys hook audit         post_tool_call       appends an audit row — never blocks
> agentkeys hook memory-inject pre_llm_call         injects only your granted namespaces
> ```
>
> `[ Wire travel-bot → ]`   `[ Preview what gets written ]`

**What the daemon runs:** `agentkeys wire hermes --actor-omni <omni> --operator-omni <omni> --namespaces travel --payment-scope payment.spend --mcp-url <url> --vendor-token <tok> --session-bearer <jwt>`. It writes the three hook scripts to `~/.hermes/agent-hooks/`, merges a **sentinel-managed** `hooks:` block into `~/.hermes/config.yaml` (preserving the operator's other keys, refusing to clobber a foreign `hooks:`), sets `hooks_auto_accept: true`, and verifies via `hermes hooks doctor`. Idempotent: re-runs show `skip … matches`; `--check-only` reports drift without writing. *(harness Phase 2; [`wire.rs`](../../../crates/agentkeys-cli/src/wire.rs); generated block in [`operator-runbook-wire.md`](../../operator-runbook-wire.md) Appendix A.)*

**"Preview what gets written"** expands the exact managed block (the sentinel-delimited `hooks:` YAML) so the operator sees precisely what AgentKeys owns in their runtime config. This honors the [`user-manual.md`](../../user-manual.md) contract: *"wire takes full ownership of the runtime's hooks block."* The UI must state plainly that wiring **replaces** any existing hooks block.

**Ownership warning.** Per the user manual, a YAML config allows one `hooks:` key, so AgentKeys can't coexist with a hand-authored block — it replaces it. The wire screen surfaces this before applying, and offers `--unwire` (a "remove AgentKeys hooks" affordance) for teardown.

**Drift detection.** The agent-detail page shows a "hooks: wired ✓ / drifted ⚠ / not wired ✗" badge backed by `agentkeys wire <runtime> --check-only`. A drifted badge (operator hand-edited the managed block, or a host re-serialized it and dropped the sentinels) offers a one-tap re-wire. Nightly `--check-only` is the recommended cron ([`operator-runbook-wire.md`](../../operator-runbook-wire.md) "Drift detection").

### §1.4 — Use it: the three acts + the surprise

Wiring done, the operator sees the guarantees fire. The agent-detail page has a **"prove it works"** panel mirroring harness Phase 3, plus the optional live "surprise" (Phase 4).

| Act | Hook | What the UI shows | Harness |
|---|---|---|---|
| **1 — Permissioned Memory** | `pre_llm_call` → `memory-inject` | "travel-bot can read: `## Memory: travel — Chengdu trip, Apr 12–16, hotpot at Yulin`. It cannot see family/work/personal." | `3.1` |
| **2 — Deterministic Denial** | `pre_tool_call` → `check` | over-cap (600 > 500) → **BLOCKED** `daily_spend_cap_exceeded: cap=500, requested=600`; under-cap (200) → allowed. *"No LLM in this decision. Fails closed if AgentKeys is unreachable."* | `3.3` / `3.4` |
| **Auto-audit** | `post_tool_call` → `audit` | a row lands in the agent's audit feed; the action is never blocked by logging | `3.5` |

(Act 3 — Online Revocation — is the §2 revoke flow below; it's out of scope for the wire harness but lives in the live dashboard.)

**The deterministic verify, surfaced honestly.** The authoritative pass/fail is *not* a chat reply — an LLM can phrase a memory-aware answer many ways, or even disown the injected context as a hallucination ([`operator-runbook-wire.md`](../../operator-runbook-wire.md) "Verifying it worked"). The harness's real check is `hermes hooks test pre_llm_call`, which fires the hook through the runtime's *own* dispatcher and asserts a `{"context": …}` block reaches the LLM request. The UI's Act-1 result must be backed by that deterministic signal (relayed by the daemon), and labeled as such — never by parsing a chat transcript.

**The surprise (optional live demo).** A "talk to your agent" affordance: the operator opens a fresh agent session and asks *"where am I going this weekend?"* The agent recalls Chengdu — memory it was never told, injected by the `pre_llm_call` hook. The UI frames this as a demo, not the proof: *"the green check above is the guarantee; this is what it feels like."*

---

## §2 — Live operations dashboard (now hook-aware)

Steady state. The operator opens the UI to watch and manage running agents. The audit feed and actor-detail pages already exist (PR #136 + the daemon read endpoints); the redesign makes them **hook-aware** — every row is tagged by which hook produced it.

### §2.1 — The audit feed, tagged by hook

The audit-service worker's tier-1 SSE feed now carries hook-origin events. Each row shows the hook that fired:

```
14:32:08  travel-bot   pre_llm_call · memory-inject   travel ns → context injected      memory
14:33:01  travel-bot   pre_tool_call · check          order_hotpot 600 RMB → BLOCKED    revoke
                                                       (daily_spend_cap_exceeded)
14:33:02  travel-bot   post_tool_call · audit         order_hotpot attempt logged        audit
14:34:10  travel-bot   pre_tool_call · check          order_tea 200 RMB → allowed        broker
```

The discipline call-out from [`input-discipline.md`](input-discipline.md) §4 stands: these are **real** events from the agent's wired runtime, relayed by the MCP server's `audit.append`. There is no `SIM_EVENTS` tick. The feed is empty until the agent actually runs.

A `check` **block** is the most important row in the system — it's the guarantee catching something. The UI tints it like a revoke (danger) and lets the operator click through to the full decision: `{scope, requested, cap, period, verdict, actor_omni}`.

### §2.2 — Guarantee-health panel (new)

Per agent, a panel answering "are my guarantees actually live right now?":

```
── travel-bot · guarantee health
─────────────────────────────────────────────────────
hooks wired       ✓ hermes · 3/3 (check, audit, memory-inject)   [re-check]
last check        14:34:10 · allowed (order_tea 200 RMB)
last block        14:33:01 · daily_spend_cap_exceeded
last memory inject 14:32:08 · travel ns
MCP reachable     ✓ 18088 · fail-closed armed
scope on-chain    travel (granted 14:30 · Touch ID)
```

The "fail-closed armed" line is load-bearing: if the MCP server is unreachable, `agentkeys hook check` blocks every gated action (`agentkeys_unreachable`), so the operator should *want* to see the agent stall rather than act ungated. The panel surfaces MCP reachability so a green "wired" badge is never mistaken for a live guarantee when the policy backend is down.

### §2.3 — Scope + revoke (Act 3 live)

Scope changes and revocation are master mutations (K11 + chain commit), unchanged from the master-detail design:

- **Tighten/loosen scope** — toggle a namespace or change the spend cap → Touch ID → `heima-scope-set` re-grant. The next `memory-inject` / `check` reflects it (caveat: the runtime caches the LLM context per session, so a namespace change may need a fresh agent session — surfaced as a hint, per [`operator-runbook-wire.md`](../../operator-runbook-wire.md) troubleshooting).
- **Revoke the agent** — Touch ID → on-chain revoke → the agent's caps go to TTL 0 and `check` starts denying. The UI also offers **`--unwire`** (remove the managed hooks block from the runtime config) so a revoked agent's runtime is left clean.

Revoking the *device* and un-wiring the *hooks* are distinct and both offered: revoke kills authority on-chain (the agent can't pass `check` anymore even if still wired); unwire removes the gate from the runtime (so the runtime stops calling AgentKeys at all). The UI explains both and recommends doing both at teardown.

---

## §3 — Isolation health check (preserved)

This surface is unchanged by #141 and remains valuable — it proves the per-actor + per-data-class S3 isolation invariants against the operator's *real* cloud, on demand. It complements the wire guarantees (which gate the runtime) by proving the AWS layer (which gates storage) is also intact.

The operator visits `/isolation-demo` and taps "run". The UI walks the [`harness/v2-stage3-demo.sh`](../../../harness/v2-stage3-demo.sh) 16-step proof live, reporting green/red per step against arch.md §17.2's four layers:

1. **broker cap-mint** rejects cross-actor requests
2. **workers chain-verify** the cap before any AWS call (+ `cap_data_class_mismatch` rejects cross-class caps)
3. **AWS IAM PrincipalTag** scopes S3 to `bots/<actor>/…`
4. **per-data-class bucket separation** (vault creds blocked on the memory bucket)

The 16 steps + their daemon endpoints + the green/red report format are as previously specified — see the prior revision's §3 table (steps `1`–`16`, endpoints `/v1/isolation/*`). Nothing in #141 changes this surface; it stays an on-demand operator tool, **not** a CI replacement (`v2-stage3-demo.sh` still runs in CI as the regression gate).

**Relationship to the wire guarantees:** §1–§2 prove *the runtime can't act outside scope*; §3 proves *the storage can't be read across actors*. Both are needed for the full "your agents can't reach each other's data" claim. The isolation-demo page links to it: *"wiring gates what the agent does; this gates where its data lives."*

---

## Summary mapping — harness Phase ↔ UI surface

```
harness Phase P.1 (device-session in sandbox)     → §1.2 pairing card, step P.1
harness Phase P.2 (registerAgentDevice)            → §1.2 pairing card, step P.2
harness Phase P.3 (heima-scope-set --webauthn)     → §1.2 pairing card, step P.3 (Touch ID)
harness step 1.5  (seed fresh actor's memory)      → §1.2 optional seed-a-memory
harness Phase 2   (agentkeys wire hermes)          → §1.3 wire screen
harness Phase 3.1 (Act 1 memory-inject)            → §1.4 Act 1 + §2.1 feed
harness Phase 3.3/3.4 (Act 2 check block/allow)    → §1.4 Act 2 + §2.1 feed + §2.2 health
harness Phase 3.5 (auto-audit)                     → §1.4 audit + §2.1 feed
harness Phase 4   (the surprise + 4.2 verify)      → §1.4 surprise (deterministic-backed)
(steady state)                                      → §2 dashboard + §2.3 scope/revoke/unwire
harness v2-stage3-demo.sh (16-step isolation)      → §3 isolation health check (preserved)
```

## What's deferred

- **Non-Hermes runtimes** (Claude Code / Codex / OpenClaw) — the `RuntimeAdapter` seam exists; adapters are [#133](https://github.com/litentry/agentKeys/issues/133). The UI lists them disabled until each lands.
- **Full HDKD-literal §10.2 pairing** (broker link-code endpoints + daemon keygen, out-of-process bearer custody) — [#144](https://github.com/litentry/agentKeys/issues/144). The current device-session is the interim shape.
- **OpenAI-compatible proxy fallback** (for hooks-less hosts — xiaozhi-server, mobile SDKs) — arch.md §22d.3, Phase 3b. The web UI's "add agent → choose runtime" gains a "no hooks? use the proxy" path then.
- **Daemon endpoints to drive wire/pair from the browser** — see [`data-model.md`](data-model.md). Today wire/device-session are CLI/sandbox; the web UI needs daemon endpoints to trigger + observe them. That wiring is the implementation work this redesign scopes.
