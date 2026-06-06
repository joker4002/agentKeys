# Plan — frontend testability + CLI↔web parity

**Status:** amended after Codex adversarial review (2026-06-06). **Landed on this branch + green: B0 (via #213, merged), B1 (`agentkeys-protocol` crate + wasm32 CI gate), B2 (ts-rs `Api*` codegen + drift gate). B3 + B5 assessed as no-code (documented below); B4 blocked on Part A.** Verified: cargo build/test/clippy `-D warnings` (native + wasm32) + `npm run typecheck` (clean except pre-existing `core.ts` wasm-artifact errors). Remaining: Part A (frontend Vitest) — and with it B4 — plus the #207 wire-type codegen follow-up.

## Goal
Two asks, argued to share one root cause: make the parent-control web app testable, and shrink the parity gap between the CLI and the web app. Both are won at the **data-layer boundary** (the `AgentKeysClient` TS interface, the Rust↔TS type seam, the WASM `agentkeys-web-core`), which is framework-agnostic.

## Current state (verified in-repo)
- Frontend: Next.js 14 App Router, React 18, TS, plain CSS. Used as a **client-only SPA** — no SSR/RSC/API-routes/file-routing (routing is a `useState<Page>` machine). No test runner at all.
- Data layer: `AgentKeysClient` interface (~15 methods) with `EmptyBackend` / `DaemonBackend` / `CoreBackend`, selected via `ClientProvider`/`useClient` (DI seam already exists). `Result<T>` discriminated union.
- `daemon.ts` hand-declares ~10 `Api*` TS interfaces mirroring Rust `ui_bridge.rs` structs. **Only 1** (`ApiMemoryEntry`/plant) is gated by `check-web-api-drift.sh`. No Rust→TS codegen.
- **Three** Rust broker/worker clients: `agentkeys-backend-client` (daemon + mcp-server, #203), `agentkeys-web-core::broker::BrokerClient` (browser WASM), the CLI's own `reqwest`. The first two already drift: web-core `CapRequest.ttl_seconds: Option<u64>` vs backend-client `CapMintRequest.ttl_seconds: u64`.
- MCP server: tools take `Arc<dyn Backend>`; `HttpBackend` is a 74-line verbatim pass-through over `BackendClient`; `backend/mod.rs` re-exports backend-client's I/O types. `InMemoryBackend` (305 lines) is the **runtime** `--backend in-memory` mode (referenced only in `main.rs`).

## Parity ladder (project's own framing, harness/CLAUDE.md)
1. Runtime behavioral assertion (run both, compare) — rots silently.
2. Shared fixture/golden contract — CI reddens on shape drift.
3. Shared implementation — one code path; drift is a compile error.
Operating rule: push every parity check *down* the ladder.

## #213 direction (amended after adversarial review)
Remove the runtime `InMemoryBackend` and have MCP tools effectively call `agentkeys-backend-client`. **Keep the `Backend` trait** — it is the test seam, not dead polymorphism.

### Verified (adversarial review, 2026-06-06)
- **The MCP test seam is `MockBackend`** in `crates/agentkeys-mcp-server/tests/common/mod.rs` (a test-only `impl Backend`, from #132), used by `http_auth.rs` / `three_acts.rs` / `schema_only_stubs.rs`. It is **independent of** the runtime `InMemoryBackend` (referenced only in `main.rs`). Deleting `InMemoryBackend` leaves test coverage untouched — **no removal gap** (refutes review finding 1).
- Because `MockBackend impl Backend`, the trait is **not** single-impl once tests count (HttpBackend prod + MockBackend test). Keep it; that mock is its reason to exist.
- The only genuine loss is the `--backend in-memory` manual dev loop — already banned from demo assertions by `harness/CLAUDE.md`, so acceptable.
- **`agentkeys-backend-client` is NOT wasm-safe** (confirms review finding 2): via `agentkeys-provisioner` it pulls `aws-config` + `aws-sdk-sts` + `tokio` + native `reqwest`. `protocol.rs`, however, is **pure serde** (imports only `serde`/`serde_json`) → cleanly splittable.

### Two end states for the MCP backend
- **Option 1 (chosen — minimal, safe):** delete `InMemoryBackend` + the redundant `HttpBackend` wrapper by making `BackendClient` itself `impl Backend` (local trait + foreign type = allowed). Trait + `MockBackend` stay; tools get `Arc<dyn Backend>` = `BackendClient` (prod) / `MockBackend` (test). Zero removal gap.
- **Option 2 (optional, heavier, deferred):** fully collapse the trait to `Arc<BackendClient>` and migrate tool tests to real `BackendClient` + mock HTTP for wire-contract coverage. Only this path requires a mock-HTTP harness to land first.

### Principle
**Fake the transport, not the behavior.** Orchestration/UI → fake the interface (cheap; `MockBackend` / `FakeBackend`). Wire contract → fake only the transport (mock HTTP / MSW), run the real client against the shared golden fixture (Option 2 / the `daemon.ts` mapper tests).

## Part A — testability
1. Add Vitest.
2. Fixture-driven mapper tests: run the **real** `DaemonBackend` (`apiToActor` etc.) with mocked `fetch` against `harness/fixtures/web-api/*.json`. (Highest ROI; doubles as rung-2 parity.)
3. `FakeBackend implements AgentKeysClient` + React Testing Library for component tests via the existing `ClientProvider`.
4. Playwright happy-path E2E on `dev:stack`.

## Part B — parity (push down the ladder)
- **B0 — ✅ DONE (landed via #213, merged):** delete the runtime `InMemoryBackend`; remove the `HttpBackend` wrapper by making `BackendClient` `impl Backend`; **keep the trait** as the `MockBackend` test seam; drop the `--backend in-memory` flag value. (Option 2's full collapse + mock-HTTP is optional, deferred.)
- **B1 — ✅ DONE (this change):** extract `agentkeys-backend-client::protocol` (pure serde) into a standalone `agentkeys-protocol` crate. Both `backend-client` (native: + client + STS via `agentkeys-provisioner`) and `agentkeys-web-core` (wasm: + browser-fetch client) depend on **that**, never the native client. Kills the `ttl_seconds` drift with one shared type. **Do NOT make web-core depend on backend-client** — it drags in `aws-sdk-sts` + `tokio` + native `reqwest` and breaks the wasm build. Add a CI gate: `cargo check --target wasm32-unknown-unknown -p agentkeys-web-core`.
- **B2 — ✅ DONE (this change).** `ts-rs` derives on the 12 `ui_bridge.rs` `Api*` structs generate `apps/parent-control/lib/generated/*.ts`; `daemon.ts` imports them and the 5 hand-declared interfaces are deleted (−49 lines net). `u64`→`number` via `#[ts(type = "number")]`, skip-serialize `Option`s → `#[ts(optional)]`. CI gate: `cargo test --workspace` regenerates + `git diff --exit-code` on the generated dir (rung 2→3: a daemon struct rename is now a frontend compile error). Verified: `cargo test export_bindings` green + `npm run typecheck` clean (only pre-existing `core.ts` wasm-artifact errors, unrelated). Follow-up: the #207 `ApiProposedScope` + classify/credentials wire types are still hand-declared — next codegen batch.
- **B3 — ✅ assessed, no code needed.** The cap-mint *request* is unified (B1). The remaining candidates are non-drifts: (a) `CapToken` is opaque-by-design in backend-client (`type CapToken = Value`, forwarded transparently to workers — every site reads `cap.get("payload")`) vs a typed convenience view in web-core (`{payload, broker_sig}`) over **identical** wire bytes; web-core never re-serializes a cap and backend-client never introspects the typed shape, so forcing one type is ripple (MockBackend + client + daemon + 4 fixtures) for no real benefit. (b) Pairing is single-owned, not duplicated: web-core owns master-side (`claim`/`pending`/`ack`), the daemon owns agent-side (`request`/`poll`) — different endpoint sets. (c) A full client-impl merge (one `BrokerClient`) is unwarranted — native does STS + reqwest, browser does fetch-only. So the achievable, valuable type-sharing IS B1; the rest is documented as deliberately not-done.
- **B4 — ⛔ blocked on Part A.** The backend-protocol + web-api golden fixtures already exist and are gated Rust-side (#203). The net-new B4 work is having the *frontend tests* consume the same fixtures — which needs the Vitest harness (Part A). B2's generated types are the shared *type* contract; fixture-sharing for tests lands with Part A.
- **B5 — ✅ audited, no code needed.** The `agentkeys` CLI does NOT re-type the cap/worker wire protocol. Its `json!` bodies are MCP tool-call args (`call_tool("agentkeys.memory.get", …)`), hook stdin/stdout, and the SIWE/device-session auth surface (separate from the §203 cap/worker chain). Cap/worker bodies are owned by the MCP server via `BackendClient` (B1). Confirmed by grep of `crates/agentkeys-cli/src`.

## Framework verdict
Keep Next.js. Framework choice is orthogonal to both goals (Vitest/RTL/ts-rs/web-core all framework-agnostic; the app uses zero Next server features). The one condition that would flip to Vite + TanStack Router: the "fold the UI into the daemon's `agentkeys web` subcommand as a static bundle, phone-first via the WASM CoreBackend" endgame becoming firm. Optionally adopt TanStack Query *on top of* Next.js for the data layer.

## Sequencing (ROI order)
B0 (delete `InMemoryBackend`, `BackendClient impl Backend`, keep trait) → B1 extract `agentkeys-protocol` crate (+ wasm32 CI gate) → Vitest + `daemon.ts` mapper tests vs fixtures → ts-rs codegen → FakeBackend + RTL → web-core + daemon reuse shared core → Playwright. (Option 2 mock-HTTP tool tests optional, anytime after B0.)

End state: one shared wire-protocol crate behind every consumer (MCP tools, daemon, web-core, CLI), with a native client (`backend-client`, + STS) and a wasm client (`web-core`, fetch-only) that cannot drift on shapes; every test fakes transport or interface, never re-implements behavior.
