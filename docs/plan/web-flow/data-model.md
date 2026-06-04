# data-model · daemon HTTP surface the UI needs

This document is the contract between the parent-control UI and `agentkeys-daemon`. Every endpoint is tagged:

- **shipped** — already in `crates/agentkeys-daemon/src/ui_bridge.rs` after PR-B / PR-C. Used by Phase 1 without changes.
- **Phase 1** — new endpoint required for Phase 1 (overview.md Act 1 steps 1–7). Build before Phase 1 ships.
- **deferred** — required for Phase 2 / Phase 3 (everything in overview.md's TODO list). Not in Phase 1's contract.

The daemon is the only thing the UI talks to. Direct calls to the broker, signer, chain RPC, or AWS from the browser are forbidden — the daemon is the trust core (per arch.md §22c.5 "what the daemon does NOT become" + arch.md §6).

> **Phone-first amendment (see [`wire-real-paths.md`](wire-real-paths.md) §0.5 + §11).** This "browser → daemon only" rule is **desktop-first** and assumes a localhost daemon — which a phone-only operator does not have. For the **master control plane**, the orchestration logic is being factored into a portable `agentkeys-core` hosted as WASM (web) / a native lib (mobile) / the daemon binary (desktop), all behind this same endpoint contract. In the WASM/native hosts the client calls the broker **directly** (the prohibition was really about the *agent* plane's fail-closed safety + the desktop assumption — neither applies to a biometric-gated master plane). **Chain writes (ERC-4337, landed #171):** every master write is a **UserOp the browser/WASM core passkey-signs** (the P-256 passkey signs the EntryPoint `userOpHash`); a broker-gated bundler broadcasts it to the operator's `P256Account` — **no secp256k1 key on any client, no delegated-broadcast hop.** See `wire-real-paths.md` §4.3/§11 + `../chain/erc4337-master-account.md`. The endpoint **shapes** below are unchanged across hosts; only *where the core runs* differs.

## Phase 1 endpoint count

**Twelve new endpoints** ([`overview.md` § Phase 1 endpoint inventory](overview.md#phase-1-endpoint-inventory-the-only-new-endpoints-to-build)) plus three shipped ones (`/healthz`, `/v1/k11/enroll/begin`, `/v1/k11/enroll/finish`). Everything else listed below is deferred — explicit so the reviewer can see which lines are not on the Phase 1 critical path.

## Surfaces

The daemon runs three independent HTTP surfaces (already established in [`crates/agentkeys-daemon/src/`](../../../crates/agentkeys-daemon/src/)):

| Mode | Bind | Audience | Auth | New in this plan? |
|---|---|---|---|---|
| `--proxy` | unix socket + optional TCP `127.0.0.1:9090` | local agents (cap-mint) | bearer JWT | no |
| `--master-companion` | TCP `127.0.0.1:9091` | second-master daemon (M-of-N approval) | localhost-only | no |
| **`--ui-bridge`** | TCP `127.0.0.1:3114` | parent-control web UI | bearer JWT + CORS | shipped (PR-B/C); extends in this plan |

The ui-bridge is where every UI endpoint lives. The expansions below extend the existing `ui_bridge.rs` module.

## Endpoint inventory

### Onboarding state machine (**Phase 1**)

The single endpoint that the UI hits on every navigation to decide which screen to render. Stateless aggregate over local + broker + chain state.

```
GET /v1/onboarding/state
```

**Phase 1 response shape:**

```json
{
  "identity": "verified" | "pending" | "missing",
  "k10": "present" | "missing",
  "k11": "enrolled" | "missing",
  "cloud": "provisioned" | "partial" | "missing",
  "cloud_detail": {
    "vault_bucket": "ok" | "missing" | "policy-mismatch",
    "memory_bucket": "ok" | "missing" | "policy-mismatch",
    "audit_bucket": "ok" | "missing",
    "email_bucket": "ok" | "missing",
    "vault_role": "ok" | "missing",
    "memory_role": "ok" | "missing",
    "smoke_test": "passed" | "failed" | "not-run"
  },
  "chain": "master-registered" | "contracts-deployed" | "missing",
  "chain_detail": {
    "sidecar_registry": "0x..." | null,
    "agentkeys_scope":  "0x..." | null,
    "k3_epoch_counter": "0x..." | null,
    "credential_audit": "0x..." | null,
    "master_device_hash": "0x..." | null
  }
}
```

**Deferred fields** (Phase 2+, additive only — clients ignore unknown):

```json
{
  "first_agent": "created" | "missing",
  "second_master": "active" | "pending" | "missing",
  "recovery_threshold": 1 | 2 | null
}
```

The UI computes its routing decision from this object alone. Each field's transitions correspond to a stage doc's screen.

### Identity (**Phase 1**)

Screen A. Wraps the broker's `/v1/auth/email/*` so the UI doesn't deal with broker auth directly.

```
POST /v1/auth/email/start
  body: { "email": "sara@example.com" }
  → 200 { "request_id": "...", "verify_polling_after_seconds": 5 }
  → 400 { "error": "email-domain-not-allowed", "allowed_domains": ["bots.litentry.org", ...] }
  → 502 { "error": "broker-unreachable", "broker_url": "..." }

POST /v1/auth/email/verify
  body: { "request_id": "...", "magic_token": "..." }
  → 200 { "session_jwt": "...", "wallet_address": "0xf3a8...", "actor_omni": "0x...", "binding_nonce": "..." }
  → 401 { "error": "magic-token-invalid-or-expired" }

GET  /v1/auth/email/status?request_id=...
  → 200 { "status": "pending" | "verified" | "expired" }
```

The `binding_nonce` from `/verify` is what powers screen B's challenge construction.

### K11 enrollment (**shipped** — PR-B)

```
POST /v1/k11/enroll/begin     — shipped
POST /v1/k11/enroll/finish    — shipped
```

Already mapped to the harness's K11 enroll flow + arch.md §10.2. **K10 derivation is folded into `enroll/begin`'s handler** so the operator sees one Touch ID prompt, not two.

### K11 assertion for master mutations (**Phase 1**)

Phase 1 uses this pattern exactly once — for screen D's `register_master_device` call. Phase 2+ reuses it for every other master mutation (scope grant, payment cap update, device revoke, threshold change, K3 rotation).

```
POST /v1/k11/assert/begin
  body: { "intent": { "op": "register_master" | "set_scope" | ..., "fields": [["k","v"], ...] } }
  → 200 { "challenge": "...", "binding": "...", "assertion_id": "..." }
```

Browser calls `navigator.credentials.get({ publicKey: { challenge, allowCredentials, userVerification: "required" } })`. Then:

```
POST /v1/k11/assert/finish
  body: { "assertion_id": "...", "authenticatorData": "...", "clientDataJSON": "...", "signature": "..." }
  → 200 { "intent_commitment": "0x..." }
```

For most master mutations the daemon submits the on-chain extrinsic itself (so the browser doesn't handle chain calldata). For Phase 1, screen D calls `/v1/onboarding/chain/register-master` after `/assert/finish` succeeds, passing the `assertion_id`.

### Cloud provisioning (**Phase 1**)

Screen C parts A + C.

```
POST /v1/onboarding/cloud/provision
  body: {}   — uses the operator's existing session
  → 200 { "job_id": "..." }
  + SSE on GET /v1/onboarding/cloud/stream emits per-step progress

POST /v1/onboarding/cloud/smoke
  body: {}
  → 200 { "passed": true, "envelope_url": "s3://vault/bots/<own>/credentials/.healthcheck/smoke.test" }
  → 200 { "passed": false, "error": "AccessDenied: ..." }
```

The provision endpoint orchestrates the existing scripts (`scripts/provision-vault-bucket.sh`, etc.) — the daemon runs them server-side, streams progress as SSE.

### Master vault + memory listings (**Phase 1, new per user feedback**)

Screen C part B. Lets the operator see what their *master* actor holds in vault + memory, immediately after cloud provisioning completes. Empty for new operators; populated for re-onboarding.

```
GET /v1/master/credentials
  → 200 { "entries": [
      { "service": "openrouter", "last_write_at": 1779812900, "size_bytes": 384, "encryption_alg": "aes-256-gcm" },
      ...
    ] }
  → 502 { "error": "vault-bucket-unreachable", "bucket": "agentkeys-vault-..." }

GET /v1/master/memory
  → 200 { "entries": [
      { "key": "family/grocery-list", "last_write_at": 1779812900, "size_bytes": 2048, "writer_actor_omni": "0x..." },
      ...
    ] }
  → 502 { "error": "memory-bucket-unreachable", "bucket": "agentkeys-memory-..." }
```

**Metadata only.** Plaintext is never returned. Plaintext fetch is per-cap-token and Phase 2+ (it's how an agent reads, not how the operator browses).

`writer_actor_omni` on memory entries distinguishes things the master wrote themselves vs things an agent wrote on their behalf (per arch.md §15.2). On screen C part B both lists are typically empty until Phase 2 puts agents in scope.

These endpoints scope by IAM PrincipalTag — the daemon uses the operator's existing STS creds against `s3://<vault-bucket>/bots/<master_omni_hex>/credentials/*` and `s3://<memory-bucket>/bots/<master_omni_hex>/memory/*`. Cross-actor leakage is impossible by construction (arch.md §17.2 layer 3).

### Chain bring-up + master registration (**Phase 1**)

Screen D.

```
POST /v1/onboarding/chain/deploy
  body: { "chain": "heima-paseo" | "heima" | "anvil", "confirm_mainnet": false }
  → 200 { "contracts": { "sidecar_registry": "0x...", ... }, "deployed_or_detected": ["new", "detected", "new", "new"] }
  → 400 { "error": "mainnet-deploy-requires-confirm" }

POST /v1/onboarding/chain/register-master
  body: { "k11_assertion_id": "..." }   — uses an assert/finish'd K11
  → 200 { "tx_hash": "0x...", "block": 1234567, "device_key_hash": "0x..." }
```

The daemon delegates to `harness/scripts/heima-bring-up.sh` and `heima-register-first-master.sh` underneath.

### Agent lifecycle — pair + wire (**deferred** — Phase 2; redesigned for #141)

> **Superseded.** The old `bootstrap/{this-device,remote,vendor}` + `agents/create` paste-a-pair-code shape is gone. The agent lifecycle is now pair (device-session) → wire (install hooks) → observe. These endpoints are the daemon surface the web UI needs to *drive and observe* the CLI flow that [`harness/phase1-wire-demo.sh`](../../../harness/phase1-wire-demo.sh) runs by hand. See [`stage3-agent-usage.md`](stage3-agent-usage.md).

**Pairing (Phase P).** The device-session keygen runs *in the agent's runtime*, not the daemon — the key must never touch the master. So the daemon endpoints here are master-side: they accept the agent's *public* outputs and drive the on-chain bind + scope grant.

```
POST /v1/agents/pair/init
  body: { "label": "travel-bot", "runtime": "hermes", "namespaces": ["travel"], "payment_scope": "payment.spend", "daily_cap_rmb": 500 }
  → 200 { "pair_id": "...", "link_code": "...", "broker_url": "...", "instructions": "run `agentkeys agent device-session` in the runtime with this link-code" }
  # The link_code is what the agent's `device-session --link-code` echoes back for binding.

POST /v1/agents/pair/bind                  — P.2: master binds the sandbox-generated device on-chain
  body: { "pair_id": "...", "agent_address": "0x...", "actor_omni": "0x...", "device_key_hash": "0x...", "pop_sig": "0x..." }
  → 200 { "tx_hash": "0x...", "block": 1234567 }   # heima-agent-create --from-pubkey → registerAgentDevice
  → 4xx { "error": "pop-sig-invalid" }             # the agent's proof-of-possession didn't verify

POST /v1/agents/pair/approve-scope/begin   — P.3: build the K11 challenge for the scope grant
  body: { "pair_id": "...", "services": ["memory:travel"] }   # namespace-qualified memory:<ns> (arch.md §896, #177); bare "travel"/"memory" fails cap-mint
  → 200 { "challenge": "...", "assertion_id": "..." }   # reuses the /v1/k11/assert pattern
POST /v1/agents/pair/approve-scope/submit  — P.3: submit Touch ID assertion → heima-scope-set --webauthn
  body: { "assertion_id": "...", "authenticatorData": "...", "clientDataJSON": "...", "signature": "..." }
  → 200 { "tx_hash": "0x...", "granted": ["memory:travel"] }

POST /v1/agents/:id/seed-memory            — step 1.5: seed a fresh actor's empty namespace
  body: { "namespace": "travel", "content": "..." }    # operator-supplied; optional (bare ns here; the worker signs it as service memory:<ns>)
  → 200 { "ok": true, "s3_key": "bots/<actor>/memory/memory:travel.enc" }   # per-namespace object (arch.md §896)
```

**Wire (Phase 2).** The hook scripts install into the *runtime's* config, which for a remote runtime lives in the sandbox — so the daemon drives `agentkeys wire` over the runtime's exec channel and reports the per-step `ok/skip/fail`.

```
POST /v1/agents/:id/wire
  body: { "runtime": "hermes", "mcp_url": "...", "vendor_token": "...", "session_bearer": "..." }
  → 200 { "steps": [ {"step":"scripts","status":"ok"}, {"step":"config","status":"ok"}, {"step":"doctor","status":"ok"} ],
          "managed_block": "# >>> agentkeys wire …" }   # the exact YAML written, for the "preview" affordance

GET  /v1/agents/:id/wire/status            — drift detection (agentkeys wire --check-only)
  → 200 { "state": "wired" | "drifted" | "not-wired", "hooks": ["check","audit","memory-inject"], "detail": "..." }

POST /v1/agents/:id/unwire                 — remove the managed hooks block from the runtime config
  → 200 { "ok": true }
```

**Verify + observe (Phase 3/4).** The deterministic Act-1 check + the live hook-event feed.

```
POST /v1/agents/:id/verify/memory-inject   — runs `hermes hooks test pre_llm_call` via the runtime's dispatcher
  → 200 { "injected": true, "context": "## Memory: travel\nChengdu trip — …" }   # the authoritative Act-1 signal; gate-bounded lines, engine-ranked per query (#177)
  → 200 { "injected": false, "reason": "mcp-unreachable" | "scope-missing" | "session-bad" }

GET  /v1/agents/:id/guarantee-health       — the §2.2 health panel
  → 200 { "wired": "hermes 3/3", "mcp_reachable": true, "fail_closed_armed": true,
          "last_check": {...}, "last_block": {...}, "last_memory_inject": {...}, "scope_on_chain": ["memory:travel"] }

GET  /v1/audit/stream?hook=check|audit|memory-inject   — the existing SSE feed (PR-C), now hook-tagged
  # each event carries { hook: "pre_tool_call|post_tool_call|pre_llm_call", action: "check|audit|memory-inject",
  #                      decision?: "block|allow", reason?, namespace?, actor_omni, ts }
```

**Reused, unchanged (shipped PR-C; extend to take `k11_assertion_id`):**

```
POST /v1/actors/:id/scope                  — tighten/loosen scope (master mutation, K11)
POST /v1/actors/:id/payment-cap            — change spend cap (master mutation, K11)
POST /v1/actors/:id/revoke                 — revoke the agent device on-chain (Act 3)
POST /v1/actors/:id/caps/revoke            — revoke a single cap
GET  /v1/actors                            — actor list
GET  /v1/actors/:id                        — actor detail (now includes wire state + scope)
GET  /v1/actors/:id/caps                   — live cap-tokens
```

The shipped POSTs from PR-C take an `intent_text`/`intent_fields` pair today; under the new plan they extend to take `k11_assertion_id` so the K11 ceremony is decoupled from the mutation (same pattern the pairing scope-grant uses).

**MCP server config the daemon must thread through** (per #141 — these flow into the wired hook scripts + the MCP server the hooks call): `--vendor-token`, `--session-bearer` / `--agent-session-bearer`, `--memory-role-arn`, `--vault-role-arn`, `--aws-region` (the per-actor STS relay, issue #90), and `--default-daily-spend-cap-rmb` (the deterministic-denial cap). **MCP port is `18088`** by convention (8088 collides with the sandbox's built-in `gem-server`).

### Second-master pairing (**deferred** — Phase 3)

Phase-3 work. Stage-2 screens G–L.

```
POST /v1/onboarding/pair/start
  → 200 { "pair_token": "...", "qr_url": "https://...#tok=...", "expires_in_seconds": 600 }

POST /v1/onboarding/pair/exchange         — called from the COMPANION's daemon
  body: { "token": "..." }
  → 200 { "exchange_jwt": "...", "primary_endpoint": "..." }

POST /v1/onboarding/pair/companion-ready   — called from the COMPANION's UI after K11 enroll
  body: { "exchange_jwt": "...", "device_key_hash": "...", "k11_cred_id_hash": "..." }
  → 200 { "ok": true }

GET  /v1/onboarding/pair/status?token=...  — primary polls
  → 200 { "status": "waiting" | "companion-active", "companion": { "device_key_hash": "...", "k11_cred_id_hash": "..." } }

POST /v1/onboarding/pair/finalize/begin
  body: { "device_key_hash": "...", "k11_cred_id_hash": "...", "roles": "cap-mint|recovery" }
  → 200 { "challenge": "...", "assertion_id": "..." }

POST /v1/onboarding/pair/finalize/submit
  body: { "assertion_id": "...", "authenticatorData": "...", "clientDataJSON": "...", "signature": "..." }
  → 200 { "tx_hash": "...", "block": 1234567 }
```

### Recovery quorum + drill (**deferred** — Phase 3)

```
POST /v1/onboarding/recovery/threshold     — set threshold; requires K11 from primary
POST /v1/onboarding/drill/register-spare   — synthetic 3rd master; primary K11
POST /v1/onboarding/drill/revoke-spare/begin  — returns challenge for primary
POST /v1/onboarding/drill/revoke-spare/companion-assert  — companion provides its K11 assertion
POST /v1/onboarding/drill/revoke-spare/submit  — daemon bundles both assertions, calls revokeMasterDevice
```

The two-assertion bundle is the **only** UI flow that requires assertions from two different devices in a single chain call. The companion's POST is authenticated by the companion's pair-derived JWT; the primary's by its session JWT.

### Read endpoints — actors / audit / anchor / workers (**shipped** — PR-C; live-data wiring deferred to Phase 2+)

The endpoints exist; Phase 1 does not exercise them because there are no agents, no audit events, no workers active until Phase 2. The UI's `DaemonBackend` calls them today and renders empty states.

```
GET  /v1/actors                            — shipped
GET  /v1/actors/:id                        — shipped
GET  /v1/actors/:id/caps                   — shipped
GET  /v1/audit/recent?actor_id=&limit=     — shipped
GET  /v1/audit/stream  (SSE)               — shipped
GET  /v1/anchor/status                     — shipped
GET  /v1/workers                           — shipped
GET  /v1/workers/:id                       — shipped
```

### Isolation health check (**deferred** — Phase 3)

Phase-3 work. Stage-3 §3.

```
POST /v1/isolation/run                     — kicks off the 16-step check
  body: { "include_cleanup": true }
  → 200 { "run_id": "..." }

GET  /v1/isolation/run/:id/stream  (SSE)   — per-step status: { step: 4, status: "ok" | "fail", detail: "...", expected: "deny", got: "AccessDenied" }
GET  /v1/isolation/run/:id                  — final summary report after stream closes
```

The run uses synthetic actor_omni + isolated test prefixes (`.healthcheck/...`). Cleanup happens automatically as step 16.

### Email worker integration (**deferred** — Phase 2)

Phase-2 work. Stage-3 §1 + agent inbox visibility.

```
GET  /v1/agents/:id/email
  → 200 { "inbox_address": "agent-folotoy@bots.litentry.org", "recent_messages": [...] }
GET  /v1/agents/:id/email/:msg_id
  → 200 { "from": "...", "subject": "...", "body": "...", "received_at": ... }
```

These wrap the email-service worker's `list-inbox(cap)` + `read-message(cap, msg_id)` calls per arch.md §15.4. The cap-token mint is the daemon's responsibility — the UI never holds a worker cap directly.

### Dev seed (**shipped** — PR-C; Phase 1 does NOT use it)

```
POST /v1/dev/seed                          — operator-only data injection for demos
POST /v1/dev/event                         — manually push one audit event into the SSE feed
```

Kept for demo purposes only. Phase 1 has no need for it because there's no mock data in Phase 1's flows — every value the UI shows is real. Feature-flag off in production deployments per [`deferred-and-followups.md`](deferred-and-followups.md) §1.

## Persistence boundaries

What lives where (the table that lets a reviewer answer "is this data lost when the UI restarts?"):

| Data | Where it's stored | Lifetime |
|---|---|---|
| session JWT | OS keychain (via daemon) | TTL from broker (~5 h) |
| K10 keypair | OS keychain (per device) | until rotation |
| K11 credential id + COSE pubkey | `~/.agentkeys/k11/<omni>.json` (daemon-managed) | until revoked |
| operator's `actor_omni`, `wallet_address`, `email` | broker DB + local session record | account lifetime |
| chain contract addresses | `scripts/operator-workstation.env` + chain | deployment lifetime |
| actors, scope, payment caps, time-windows | chain (SidecarRegistry + AgentKeysScope) + daemon's in-memory cache (TTL'd) | chain lifetime |
| cap-tokens | chain mint events + worker-side validation (no daemon persistence) | per-cap TTL |
| audit events (tier 1) | audit-service worker's S3 bucket + daemon's 200-event in-memory ring | retention per worker config |
| audit anchors (tier 2) | chain extrinsics every 2 min | chain lifetime |
| worker stats (calls/hour, p50/p95) | aggregated by daemon from audit feed | in-memory, recomputed on restart |
| onboarding state machine | NOT persisted — re-derived from local + broker + chain on `GET /v1/onboarding/state` | per query |

The discipline: **the daemon never stores anything it can re-derive from broker + chain + local files**. The audit-feed ring buffer is the one exception — chain has tier-2 roots but tier-1 events live only at the audit-service worker; the daemon caches enough to populate the UI on restart without re-querying.

## What is local-only vs chain-anchored

| Claim | Where it's verified |
|---|---|
| "this user owns this email" | broker (email magic-link record) |
| "this device holds K10 for this actor" | local OS keychain + chain (`SidecarRegistry.device(D_pub_hash).device_pubkey_hash` matches) |
| "this device holds K11 for this master" | platform authenticator (sealed) + chain (`SidecarRegistry.device(D_pub_hash).k11_cred_id_hash` matches) |
| "this agent has memory:read on family" | chain (`AgentKeysScope[O_master][agent_omni][family]`) |
| "this agent did X at time T" | tier-1 SSE + tier-2 chain anchor (Merkle root) |

The UI must never claim "X is true" without resolving X's claim back to its authority. The audit row "FoloToy bear · memory.read · family/bedtime-story" is claimable because the row carries `cap_token_id` and a `tier-2 status` indicator; clicking through shows the full chain.

## Request/response style

- **Bodies are JSON.** snake_case on the wire (matches existing PR-C handlers); the UI's `daemon.ts` translates to camelCase at the boundary.
- **Errors are `{ error, reason, detail? }`.** `reason` is a stable `kebab-case` token the UI can switch on; `error` is operator-readable copy.
- **Long-running operations stream.** Anything that takes >1s emits SSE on a dedicated stream endpoint (`.../stream`) rather than blocking the request.
- **K11 assertions are decoupled.** Every mutation that needs a K11 goes through the two-step `/v1/k11/assert/{begin,finish}` pattern so the browser can sequence the WebAuthn prompt cleanly.

## Open contract questions for review

1. **Should `/v1/onboarding/state` be cached or always live-query?** Live query against chain on every page load is expensive (~2× block time per master / agent / scope lookup). Proposal: daemon polls chain on a 5 s tick + listens to its own audit feed for invalidations.
2. **Pair-flow JWT lifetime.** 10 min is the harness's window; the web flow could be tighter (3 min?). What's right depends on UX testing — leaving 10 min as the default until we see operator drop-off.
3. **CORS for `--ui-bridge` mode.** Currently allows `http://localhost:3113` only. Production deployment with `https://parent.{operator}.litentry.org` needs the daemon's CORS layer to accept the operator-specific origin per env. Should the daemon take this as a CLI flag (current shape) or pull it from the broker's deployment-config endpoint at startup?

These are tracked in [`deferred-and-followups.md`](deferred-and-followups.md).
