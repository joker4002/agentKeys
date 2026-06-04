# Web wire test runbook — the parent-control mirror of `phase1-wire-demo.sh`

This runbook tests the **parent-control web app** (`apps/parent-control/`) against the **same live backends** the agent-side harness uses — `broker.litentry.org` + the service workers + Heima mainnet. It is the master-control-plane counterpart to [`harness/phase1-wire-demo.sh`](../../../harness/phase1-wire-demo.sh) (spec: [`phase1-wire-harness-test-plan.md`](../phase1-wire-harness-test-plan.md)).

It follows the same `ok / skip / fail` discipline and the same idempotent, fail-loud posture. Where the web UI can't yet exercise a phase1 capability, the step is marked **⛔ not-wired** with the exact cross-check to use instead and the follow-up that unblocks it. Per the repo's "never gloss over a partial implementation in a runbook" rule, the gap is stated up front, not buried.

---

## 0. Roles, and what actually differs from `phase1-wire-demo`

`phase1-wire-demo.sh` drives **two** hosts: the **agent** (a Hermes runtime inside an aiosandbox container — Phases 1–4) and the **master** (your laptop, via the `agentkeys` CLI — the Phase-0 session mint + Phase-P pairing claim/ack). This runbook replaces the **master CLI half** with the **web app**, talks to the identical broker/workers/chain, and (optionally) keeps the **agent half** exactly as-is (the same `phase1-wire-demo.sh --real` run, or the CLI) so the web app has a real agent to pair with and observe.

| Concern | `phase1-wire-demo.sh` (CLI master) | This runbook (web master) |
|---|---|---|
| Master identity / session | `wallet_sig_init_session` SIWE-signs → J1 (0.7) | Web onboarding (email → WebAuthn K11). **managed-wallet attestation / J1 mint is not in the web client yet** — see §6 |
| Backend | `agentkeys` CLI → broker directly | Browser → **daemon** (`--ui-bridge`, :3114) → broker/chain, **or** browser → **WASM core** → broker directly |
| Broker / workers / chain | `broker.litentry.org`, `memory.litentry.org`, Heima mainnet | **identical** |
| Agent counterpart | the sandbox (same process) | a separate `phase1-wire-demo.sh --real` run, or `agentkeys agent` CLI |

### Honest capability map (read this before running)

For each phase1 master-side capability, what the web UI can do **today**:

| phase1 capability | Web **daemon** mode | Web **core** mode | How this runbook tests it |
|---|---|---|---|
| **K11 WebAuthn enroll** (master passkey) | ✅ real (`/v1/k11/enroll/{begin,finish}`) | ⛔ inherits stub | §3 Step B — real Touch ID / virtual authenticator |
| **Operator session (managed-wallet attestation → J1)** | ⛔ narrated only in UI | ⛔ narrated only | §6 — mint out-of-band (CLI) or treat as task-2 gap |
| **Register master device on-chain** | ⛔ narrated only in UI | ⛔ narrated only | §3 Step B note — cross-check on-chain via CLI |
| **Memory list / plant** (master preserved memory) | ✅ real (`/v1/master/memory[/plant]`, content-hash dedup) | ⛔ inherits stub | §3 Step C — plant + list in UI; cross-check real worker/S3 per §5 |
| **Cap-mint → worker → S3** (the `1.5 seed memory` path) | ⛔ not UI-wired | ⚠️ `capMemoryPut/Get` exist on the WASM core but **no screen calls them** | §3 Step C note + §4 console-drive |
| **Agent pairing — claim / pending / ack** (Phase P) | ⛔ not UI-wired | ⚠️ `pairingClaim/pendingBindings/ackBinding` exist on the WASM core but **no screen calls them** | §3 Step D — §4 console-drive, or CLI |
| **Scope grant** (`updateScope`) | ⚠️ daemon endpoint exists; UI edits **local state only**, never POSTs | ⛔ inherits stub | §3 Step E — task-2 gap; CLI cross-check |
| **Device revoke** | ✅ real (`/v1/actors/:id/revoke`) | ⛔ inherits stub | §3 Step F |
| **Actor list / audit feed** (observe the agent) | ✅ real (`/v1/actors`, `/v1/audit/recent`, SSE `/v1/audit/stream`) | ⛔ inherits stub | §3 Step G |

**Bottom line:** in **daemon** mode the web app genuinely exercises onboarding (K11), memory plant/list, device revoke, and the read/audit views. **Pairing, cap-mint, scope-grant POST, managed-wallet attestation, and on-chain master-register are not yet wired into a UI screen** — the daemon/WASM methods exist, but no component invokes them. Those are the [`wire-real-paths.md`](./wire-real-paths.md) task-2 (W-phase) deliverables. This runbook tests what ships today and gives a console/CLI path for the rest so the broker endpoints can still be smoke-tested from the browser.

> **Memory model (#177 — OpenViking engine behind the gate).** Memory is namespace-partitioned and the cap/scope service is the **signed `memory:<ns>`** string (e.g. `memory:travel`, arch.md §896): the worker keys storage per-namespace (`memory:<ns>.enc`), the broker hashes it for `isServiceInScope`, and a bare `memory` fails cap-mint. **Reading is query-aware** — the agent's `pre_llm_call` read is ranked by the configured engine (OpenViking, else a deterministic fallback) over the gate-bounded lines; ranking reorders but can never widen past the granted namespaces. The web client builds the service with `memoryService(ns)` (`lib/constants.ts`).

> **Which mode to run.** Use **daemon** mode for the fullest UI coverage today. Use **core** mode to validate the phone-first browser→broker path (§4) — today that means `status()` reachability plus the console-driven cap/pairing calls.

---

## 1. Prerequisites (mirror of phase1 Phase 0)

Run these from the repo root on your laptop. Each is the web analog of a phase1 `0.x` check.

| id | check | command | pass |
|---|---|---|---|
| W0.1 | Heima contracts live | `AGENTKEYS_CHAIN=heima bash scripts/verify-heima-contracts.sh` | exits 0 (all 5 groups) |
| W0.2 | Broker reachable | `curl -fsS https://broker.litentry.org/healthz` | 200 |
| W0.3 | Account exists (master `alice`, agent `demo-agent`) | `bash scripts/setup-heima.sh` (idempotent; skips if done) | `ok`/`skip` per step |
| W0.4 | Operator session on disk (for the daemon) | `test -f ~/.agentkeys/alice/session.json` | present + unexpired |
| W0.5 | `wasm-pack` installed (core mode only) | `command -v wasm-pack` | path printed |

**W0.4 detail** — the daemon serves the web app but still authenticates to the broker as the operator, exactly like the CLI. If the session is missing/stale, mint it the same way phase1 does (`wallet_sig_init_session`, SIWE-signing with the master key) before launching:

```bash
# Same mechanism as phase1-wire-demo.sh 0.7; mints ~/.agentkeys/alice/session.json
AGENTKEYS_CHAIN=heima agentkeys session login --session-id alice --broker-url https://broker.litentry.org
# (or run `bash harness/phase1-wire-demo.sh --real --skip-1 --skip-2 --skip-3 --skip-4` once —
#  its Phase 0 mints the operator session as a side effect, then exits.)
```

---

## 2. Launch the web stack

```bash
# Daemon mode (fullest UI coverage today):
export NEXT_PUBLIC_AGENTKEYS_BACKEND=daemon
export NEXT_PUBLIC_AGENTKEYS_DAEMON_URL=http://localhost:3114
AGENTKEYS_CHAIN=heima bash dev.sh

# — or — Core mode (phone-first browser→broker; pairing/cap via console only today):
export NEXT_PUBLIC_AGENTKEYS_BACKEND=core
export NEXT_PUBLIC_AGENTKEYS_BROKER_URL=https://broker.litentry.org
bash dev.sh
```

`dev.sh` brings up three processes and (when `wasm-pack` is present) builds the WASM core into `apps/parent-control/public/wasm/`:

| process | port | role |
|---|---|---|
| `[daemon]` `agentkeys-daemon --ui-bridge` | 3114 | the web app's backend in daemon mode (talks broker + Heima) |
| `[mcp]` `agentkeys-mcp-server` | 18088 | agent-side MCP (only relevant if you run the agent half here too) |
| `[ui]` `next dev` | 3113 | the parent-control web app → **http://localhost:3113** |

`ok` W1: `http://localhost:3113` loads; in core mode the dashboard's connection status probes `https://broker.litentry.org/healthz` (see [`core.ts`](../../../apps/parent-control/lib/client/core.ts) `status()` — it honestly reports `disconnected` until the read endpoints wire in task 2, with `detail` distinguishing *broker reachable* from *unreachable*).

---

## 3. The flow (mirror of phase1 Phases P → 1.5 → 2 → 3)

Drive the browser manually, or with the [`/browse`](../../../) skill / a chrome-devtools MCP session. Each step lists the **UI action**, the **expected result**, and the **cross-check** (the authoritative on-chain / S3 / CLI assertion, since UI green alone is not proof).

### Step A — open + connection status
- **Action:** load `http://localhost:3113`.
- **Expect:** dashboard renders; empty states (no fakes) until onboarded.
- **Cross-check:** daemon mode → status `connected via daemon`; core mode → `disconnected` with `detail: broker … reachable` (by design today).

### Step B — onboarding: email → WebAuthn K11  ✅ (daemon)
- **Action:** onboarding screen ([`ceremony.tsx`](../../../apps/parent-control/app/_components/ceremony.tsx)) → enter the master email → run the ceremony. At the **"bind passkey"** stage the browser invokes `navigator.credentials.create()`.
  - **Real Touch ID:** approve on the Mac.
  - **Headless / CI:** attach a CDP **virtual authenticator** first — see §4. (This is the web analog of the harness's software passkey `harness/scripts/erc4337-webauthn-sign.py`.)
- **Expect:** ceremony completes; `enrollK11Begin` → `enrollK11Finish` hit the daemon (`/v1/k11/enroll/{begin,finish}`); `ak_onboarded` set.
- **⛔ not-wired note:** the ceremony's *email→managed-wallet attestation→J1* and *register-master-on-chain* stages are **narrated only** in the UI (see §6). They do not mint a session or submit a tx.
- **Cross-check (the real proof):** the K11 credential is registered on-chain for the master.
  ```bash
  # K11 enrollment is master-only; confirm the registry recorded it (CLI / read RPC):
  agentkeys k11 status --operator-omni 0x<master_omni>     # or the verify-heima read for the master device
  ```

### Step C — memory: plant + list  ✅ list/plant (daemon) · ⛔ cap-mint path
- **Action:** Memory page ([`memory.tsx`](../../../apps/parent-control/app/_components/memory.tsx)) → **Plant** the prepared archive → the list reloads (`listMasterMemory()` / `plantMemory()`, App wiring in [`app/page` App](../../../apps/parent-control/app/_components)).
- **Expect:** the planted namespaces appear; re-planting is **idempotent** (server dedups by content-hash → `skipped` count rises, `planted` stays 0). This mirrors phase1's idempotent `1.5 seed memory`.
- **⛔ not-wired note:** the UI "plant" writes via the daemon's **master preserved-memory** endpoint (`/v1/master/memory/plant`). The **cap-mint → memory worker → S3** path that phase1 `1.5` exercises (`CoreBackend.capMemoryPut`) is **not invoked by any screen**. So a green UI plant does **not** by itself prove the real worker/S3 write.
- **Namespace = signed service (#177, arch.md §896):** the agent's memory cap/scope is **`memory:<ns>`** (e.g. `memory:travel`) — a *signed* cap field; the worker keys storage per-namespace (`bots/<actor>/memory/memory:<ns>.enc`). A bare `memory` fails cap-mint (`service_not_in_scope`). Build it with `memoryService(ns)` (`lib/constants.ts`).
- **Reading is query-aware (#177):** the agent's `pre_llm_call` read is ranked by the configured engine (OpenViking, or the deterministic fallback) over the **gate-bounded** lines — ranking can reorder but never widen past the granted namespaces. The engine is chosen at `wire`-time: `agentkeys wire hermes --memory-engine openviking --openviking-endpoint <url> [--openviking-api-key <k>]` (default = deterministic; arch.md §15.2 + `docs/operator-runbook-openviking.md`).
- **Cross-check (the real worker, per CLAUDE.md "REAL memory only" rule):**
  ```bash
  # Authoritative real-memory assertion — same as the agent-side demo:
  agentkeys hook memory-inject --namespaces travel </dev/null      # returns the gate-bounded, engine-ranked lines
  # or read the live per-namespace object directly:
  #   s3://agentkeys-memory-<acct>/bots/<actor_omni>/memory/memory:travel.enc
  ```
  To smoke-test the **cap-mint** broker route from the browser today, use the §4 console drive (with `service: "memory:travel"`).

### Step D — agent pairing: claim → pending → ack  ⛔ not UI-wired
This is phase1 **Phase P** (the master's half: `P.1 claim`, `P.1c pending`, `P.2 ack`). The web Pairing page ([`pairing.tsx`](../../../apps/parent-control/app/_components/pairing.tsx)) is **UI-only today** (renders from demo data; no screen calls `pairingClaim/pendingBindings/ackBinding`).

- **Agent side (produce a real pairing code):** run the agent half so there's a live code to claim:
  ```bash
  bash harness/phase1-wire-demo.sh --real --skip-2 --skip-3 --skip-4   # runs Phase P; prints the agent's pairing_code
  ```
  …or `agentkeys agent` from a second sandbox.
- **Master side — two ways to exercise it today:**
  1. **Console drive (browser, core mode)** — the WASM core *does* expose the methods; call them from DevTools (§4):
     ```js
     const core = await window.__agentkeysCore;          // see §4 to expose it
     await core.pairingClaim(bearer, { pairing_code: "ABCD-1234", label: "demo-agent", requested_scope: "memory:travel" });
     await core.pendingBindings(bearer);                 // master sees it awaiting approval
     await core.ackBinding(bearer, "<request_id>");      // clears the rendezvous
     ```
  2. **CLI cross-check** (exactly what phase1 P.1/P.1c/P.2 do): `agentkeys agent claim … / agent pending … / pending-bindings/ack`.
- **Unblocks:** a real Pairing screen calling these three CoreBackend methods (a task-2 / W-phase deliverable in [`wire-real-paths.md`](./wire-real-paths.md)).

### Step E — scope grant  ⚠️ partial
- **Action:** Permissions screen ([`permissions.tsx`](../../../apps/parent-control/app/_components/permissions.tsx)) → edit an agent's namespace scope.
- **⛔ not-wired note:** the edit updates **local React state only** — `updateScope()` exists on the daemon backend but the UI never POSTs it. So the on-chain scope is **not** changed by the UI.
- **Cross-check / do-it-for-real:** grant via the CLI (real Touch ID), same as phase1 `P.3`:
  ```bash
  bash scripts/heima-scope-set.sh --webauthn --agent <label> --services memory:travel   # grant the SAME memory:<ns> the cap-mint requests (#177, arch.md §896)
  ```

### Step F — device revoke  ✅ (daemon)
- **Action:** dashboard → revoke an agent device (type the confirm intent).
- **Expect:** `revokeDevice()` POSTs to the daemon (`/v1/actors/:id/revoke`).
- **Cross-check:** `agentkeys` device status / `verify-heima` read shows the device inactive on-chain.

### Step G — observe the agent (audit feed)  ✅ reads (daemon)
This is the web counterpart to watching phase1 Phases 2–4 (the agent's `wire` + memory get/put + the Hermes "surprise"). The web master **observes**, it doesn't drive Hermes.
- **Action:** with the agent half running (Step D's `--real`), watch the dashboard actor list + audit feed (`listActors`, `listRecentAuditEvents`, SSE `streamAudit`).
- **Expect:** the paired agent appears; memory get/put + cap-mint events stream into the audit feed.
- **Cross-check:** `agentkeys audit query` shows the same envelopes.

---

## 4. Driving WebAuthn (and the WASM core) headlessly

The harness drives WebAuthn with a software passkey ([`erc4337-webauthn-sign.py`](../../../harness/scripts/erc4337-webauthn-sign.py)). The browser analog is a **CDP virtual authenticator** — no Touch ID hardware needed, so Step B runs in CI.

Via a chrome-devtools / CDP session, before Step B:
```
WebAuthn.enable
WebAuthn.addVirtualAuthenticator { options: { protocol: "ctap2", transport: "internal",
                                               hasResidentKey: true, hasUserVerification: true,
                                               automaticPresenceSimulation: true, isUserVerified: true } }
```
Then `navigator.credentials.create()` in Step B resolves automatically. Remove with `WebAuthn.removeVirtualAuthenticator` after.

**Expose the WASM core for console drives (Step C/D):** add a one-liner in dev/core mode so DevTools can reach it, e.g. in the client provider:
```ts
if (process.env.NODE_ENV !== 'production') (window as any).__agentkeysCore = loadCore(brokerUrl);
```
(Or call `selectBackend()` and grab the `CoreBackend` instance.) This is a **test affordance**, not a shipped surface — it lets you smoke-test the wired-but-not-screened broker methods until the real screens land.

Cap-mint smoke (Step C) — note the **namespace-qualified** `service` (use `memoryService("travel")`); a bare `memory` 4xxs with `service_not_in_scope`:
```js
const core = await window.__agentkeysCore;
await core.capMemoryPut(bearer, {
  operator_omni, actor_omni, device_key_hash,
  service: "memory:travel",     // === memoryService("travel"); NEVER bare "memory" (#177, arch.md §896)
});
```

---

## 5. Verification matrix (pass criteria)

A step is **green** only when the UI action *and* its cross-check agree.

| step | UI green | authoritative cross-check | testable today |
|---|---|---|---|
| A status | dashboard loads | daemon `connected` / core `detail: reachable` | ✅ |
| B K11 enroll | ceremony completes | on-chain master K11 registered (CLI) | ✅ daemon |
| B managed-wallet attestation / J1 + master-register | (narrated) | session minted + `registerFirstMasterDevice` tx | ⛔ §6 |
| C memory list/plant | namespaces shown; re-plant dedups | **real worker:** `agentkeys hook memory-inject` / S3 object | ✅ list/plant · ⛔ worker path |
| D pairing claim/pending/ack | — (no screen) | console (§4) or `agentkeys agent …` returns child omni / pending / ack | ⛔ UI · ⚠️ console/CLI |
| E scope grant | local toggle only | `heima-scope-set.sh` on-chain scope | ⛔ UI · ⚠️ CLI |
| F device revoke | confirm intent → done | device inactive on-chain | ✅ daemon |
| G audit observe | agent + events appear | `agentkeys audit query` matches | ✅ reads |

---

## 6. What this runbook can NOT test via the web UI yet (and what unblocks it)

Per the plan-completion + partial-implementation honesty rules, the explicit gaps:

1. **Operator session (managed-wallet attestation → J1) in the browser** — onboarding narrates it; no session is minted client-side. *Unblocks:* the web auth slice in [`wire-real-paths.md`](./wire-real-paths.md) (email → broker → managed-wallet attestation → J1), or the broker **CORS** layer for the core path (the codex-flagged task-2 prerequisite for any browser-direct broker call). Until then, mint via CLI (§1 W0.4).
2. **On-chain master-device register** — narrated ceremony step; no tx from the UI. *Unblocks:* the ERC-4337 UserOp builder/signer in the core (E7 in [`erc4337-master-account.md`](../chain/erc4337-master-account.md)).
3. **Pairing claim/pending/ack screen** — methods exist on `CoreBackend`; no component calls them. *Unblocks:* a real Pairing screen (task 2). Console/CLI in the meantime (Steps D, §4).
4. **Cap-mint → worker → S3 from the UI** — `capMemoryPut/Get` exist on the core; no screen calls them; the UI "plant" uses the daemon's master-memory store instead. *Unblocks:* wiring Memory to the cap path (task 2).
5. **Scope-grant POST** — UI edits local state only. *Unblocks:* call `updateScope()` from the Permissions screen (task 2).
6. **Core mode read endpoints** — `CoreBackend` extends `EmptyBackend`, so `listActors`/`listMasterMemory`/audit are stubs there; `status()` stays `disconnected` by design. *Unblocks:* growing the core surface (task 2).

When a task-2 slice lands, move its row from this section into §3/§5 as a ✅ step in the same PR.

---

## 7. Re-runs & teardown

Every UI action above is idempotent (memory plant dedups; revoke/ack self-check on-chain state; onboarding short-circuits on `ak_onboarded`). The account is kept between runs (like phase1 Phase 5). To re-run onboarding cleanly, clear the browser's `ak_onboarded` localStorage flag and (CI) drop the CDP virtual authenticator.
