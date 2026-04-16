# Stage 5a Manual Test Guide

**Prerequisite:** Rust toolchain installed, Node.js 20+, `npm` available, `cargo build --workspace` succeeds.

> **Scope.** This guide covers Stage 5a (provisioner, deterministic + patterns tier).
> Stage 5b (agentic fallback via MCP browser primitives, fallback→PR loop,
> `/agentkeys-record-scraper` skill usage) is not yet shipped and is tested
> separately once 5b lands. Stage 6 (npm packaging) is deferred to v0.1.

> **Hermetic vs live.** Stage 5a tests fall into two groups:
> - **Hermetic** — Playwright runs against local HTML fixtures via `page.route()`.
>   No real network, no real Gmail, no real OpenRouter. These are the *unit
>   and chaos tests* and can run on any machine with Node + Playwright.
> - **Live provision** — creates a real OpenRouter account via a real Chromium
>   session, real Gmail IMAP, real HTTP call to openrouter.ai. Requires
>   Gmail plus-addressing creds **and** a ToS compliance check (tracked in
>   `TODOS.md`) before running. The live test is documented here but *do not*
>   run it until the ToS check completes.

All manual tests target the workspace layout:
```
crates/agentkeys-{types,provisioner,mcp,cli}
provisioner-scripts/{src,tests}
harness/
```

---

## 1. Fast gate (30 seconds, no external deps)

The quickest way to verify Stage 5a is intact. Run this first after any change
that touches Stage 5a files.

```bash
cd ~/Projects/agentkeys
bash harness/stage-5a-done.sh
```

**Expected output ends with:**
```
STAGE 5a PASSED
```

This script runs:
1. `cargo test -p agentkeys-types -p agentkeys-provisioner -p agentkeys-mcp -p agentkeys-cli`
2. `npm test --prefix provisioner-scripts`
3. `grep -iE "openrouter|brave|jina|groq|anthropic|gemini|twitter|instagram" provisioner-scripts/src/patterns/` (must be empty)
4. Isolated phantom-key chaos test (hermetic)

Exit 0 = everything green. Exit non-zero = stage broken, do not merge.

---

## 2. Setup (one-time, for the deeper manual tests below)

```bash
cd ~/Projects/agentkeys

# Build all binaries + install TS deps
cargo build --workspace --release
npm install --prefix provisioner-scripts
npx playwright install chromium --with-deps  # downloads the headless browser

# Convenience aliases
alias agentkeys="./target/release/agentkeys-cli"
alias agentkeys-daemon="./target/release/agentkeys-daemon"
alias agentkeys-mock-server="./target/release/agentkeys-mock-server"
```

---

## 3. Hermetic tests — run these any time

### 3a. Rust unit tests (67 tests)

```bash
cargo test -p agentkeys-types       # 8 tests — includes ProvisionEvent serde roundtrips
cargo test -p agentkeys-provisioner # 15 tests — subprocess IPC + mutex + orchestrator
cargo test -p agentkeys-mcp         # 3 tests — agentkeys.provision tool registration
cargo test -p agentkeys-cli         # 41 tests — includes 4 new provision tests
```

All 4 crates should exit 0 with no failures.

### 3b. TypeScript unit tests (15 tests)

```bash
npm test --prefix provisioner-scripts
```

**Expected:**
```
Test Files  6 passed (6)
     Tests  15 passed (15)
```

Breakdown:
- `src/types.test.ts` (3) — ProvisionEvent emit + roundtrip
- `src/lib/email.test.ts` (3) — IMAP happy/timeout/wrong-pattern
- `src/lib/verify.test.ts` (3) — 200/401/503 status mapping
- `tests/scrapers/openrouter.test.ts` (3) — scraper happy/selector-timeout/verification-failure
- `tests/patterns/signup_email_otp.test.ts` (2) — pattern happy/selector-timeout
- `tests/scrapers/openrouter.phantom.test.ts` (1) — phantom-key chaos

### 3c. Phantom-key chaos test in isolation

The key defense against silent-corrupt credentials. Fake-shaped key → verify() returns 401 → Error event, no Success.

```bash
cd provisioner-scripts
npx vitest run tests/scrapers/openrouter.phantom.test.ts
cd -
```

**Expected ending:**
```
{"type":"error","code":"store_failed","details":"key verification failed: phantom"}
 ✓ tests/scrapers/openrouter.phantom.test.ts (1 test)
```

If this test ever passes with a Success event, **stop** — the verification gate is broken and a real phantom key could be stored in production. File an issue immediately.

### 3d. Pattern grep guard

Patterns must never reference service-specific strings. Enforce:

```bash
grep -riE "openrouter|brave|jina|groq|anthropic|gemini|twitter|instagram" \
  provisioner-scripts/src/patterns/
```

**Expected:** empty (no output). Any match means a pattern has leaked service-specific selectors or copy — extract them back into `scrapers/<service>.ts` parameters.

### 3e. Typecheck

```bash
npm run typecheck --prefix provisioner-scripts
```

**Expected:** exit 0, no TypeScript errors.

### 3f. Clippy (Rust lints)

```bash
cargo clippy -p agentkeys-types -p agentkeys-provisioner -p agentkeys-mcp -p agentkeys-cli --all-targets
```

**Expected:** zero warnings in the Stage 5a crates. (Warnings in other crates like `agentkeys-mock-server` or `agentkeys-core` are pre-existing and out of scope.)

---

## 4. Scraper walkthrough — inspect what it does without running live

This is a read-only tour of how a provision actually works, useful when debugging
a failing scraper or onboarding a new service.

### 4a. Inspect the Rust ↔ TS wire format

Every line the TS subprocess emits is a tagged JSON event. Open two terminals.

Terminal 1 — show the schema:
```bash
cat crates/agentkeys-types/src/provision.rs | grep -A 20 "enum ProvisionEvent"
```

Terminal 2 — show the TS mirror:
```bash
cat provisioner-scripts/src/types.ts | grep -A 15 "ProvisionEvent"
```

Fields match. JSON snake_case. `type` is the discriminator. This is the IPC contract.

### 4b. Run the scraper against the hermetic fixture only

The OpenRouter scraper can run with the local HTML fixture served via Playwright `page.route()`. No real network, no real OpenRouter.

```bash
cd provisioner-scripts
npx vitest run tests/scrapers/openrouter.test.ts --reporter=verbose
cd -
```

Three scenarios run:
- `scraper::happy_path` — scraper walks the fixture, emits Progress events, extracts the fixture key, verify() returns valid, Success event fires
- `scraper::selector_timeout` — fixture served without the email input; scraper emits a Tripwire event within 15s
- `scraper::verification_failure` — mock verifier returns `{valid:false, reason:"phantom"}`; scraper emits an Error event

Watch the `console.log` output for the emitted events in each test.

---

## 5. MCP tool registration check

Verify `agentkeys.provision` is discoverable through the daemon's MCP interface.

### 5a. Start the daemon in a scratch environment

Terminal 1:
```bash
cd ~/Projects/agentkeys

# Start the mock backend (needed by daemon for credential backend wiring)
cargo run -p agentkeys-mock-server -- --port 8090 &
MOCK_PID=$!

# Give it a second to bind
sleep 1

# Run the daemon with a test session seam (per Stage 3 test-seam pattern)
AGENTKEYS_BACKEND=http://localhost:8090 \
  cargo run -p agentkeys-daemon -- --stdio
```

The daemon is now listening for MCP JSON-RPC on stdin/stdout.

### 5b. List tools (Terminal 2, via a scratch stdin pipe)

The daemon reads JSON-RPC from stdin. Easiest way to exercise it without an MCP client is a one-shot:

```bash
cd ~/Projects/agentkeys
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  AGENTKEYS_BACKEND=http://localhost:8090 \
  cargo run -p agentkeys-daemon -- --stdio 2>/dev/null
```

**Expected:** the response JSON includes an entry with `"name":"agentkeys.provision"` and the schema `{"service":"string","force":"boolean (optional)"}`.

### 5c. Confirm the in-progress sentinel

(Advanced — requires sending a provision call then immediately a second one. Easier via unit tests: `mcp::provision_in_progress_error` in `crates/agentkeys-mcp/src/lib.rs`.)

```bash
cargo test -p agentkeys-mcp -- provision_in_progress_error --nocapture
```

**Expected:** test passes; the output confirms a second concurrent call returns an MCP error with `code: "PROVISION_IN_PROGRESS"`.

### 5d. Cleanup

```bash
kill $MOCK_PID
```

---

## 6. CLI UX walkthrough

All CLI provision tests can run without any real signup. They use the mock backend and a test-seam provisioner.

### 6a. Masked key output format

```bash
cargo test -p agentkeys-cli -- cli_provision_masked_output --nocapture
```

**Expected:** test passes. Stdout contains exactly one line matching the masked-key format: `sk-or-v1-XXXXXXXX****...XXXX` (first 8 chars + `****...` + last 4). The full raw key is **never** on stdout.

### 6b. `--force` flag re-provisions

```bash
cargo test -p agentkeys-cli -- cli_provision_force_flag --nocapture
```

**Expected:** test passes. With an existing credential present, `--force` triggers a fresh subprocess call (not the verify-and-return shortcut).

### 6c. Duplicate provision verify-and-report

```bash
cargo test -p agentkeys-cli -- cli_provision_duplicate_verified --nocapture
```

**Expected:** test passes. With an existing credential, no `--force`, the CLI prints to stderr `openrouter already provisioned, key valid`, prints the masked existing key on stdout, and does NOT re-run the subprocess.

### 6d. Error message format (problem + cause + fix + docs)

```bash
cargo test -p agentkeys-cli -- cli_provision_error_format --nocapture
```

**Expected:** test passes. Error output to stderr contains (in order):
- `Problem: ...`
- `Cause: ...`
- `Fix: ...`
- `Docs: https://...`

This is the CLAUDE.md-specified error format. Verify manually by triggering any known-bad state (e.g. missing AGENTKEYS_BACKEND) and checking the stderr shape.

---

## 7. Observability check — structured metrics

The orchestrator emits JSON log lines to stderr for each metric. Easiest to see via a subprocess run in a test:

```bash
cargo test -p agentkeys-provisioner -- stores_credential --nocapture 2>&1 | \
  grep "provision_metric"
```

**Expected:** at least three log lines of the form:
```
{"level":"info","event":"provision_metric","name":"tier_used","service":"openrouter","tier":2}
{"level":"info","event":"provision_metric","name":"duration_seconds","service":"openrouter","seconds":0.123}
{"level":"info","event":"provision_metric","name":"verification_result","service":"openrouter","result":"valid"}
```

The metric names are stable (`tier_used`, `duration_seconds`, `trip_wire_fired`, `verification_result`). Prometheus/OTel exporters come in v0.1.

---

## 8. Live provision (DO NOT RUN YET — blocked on ToS check)

This is the end-to-end test that actually creates a real OpenRouter account.
**Do not run until** the TODOS.md OpenRouter ToS compliance check completes.
Running this test before the ToS check may violate OpenRouter's terms and
create a real account tied to your email.

### Prerequisites (when ToS check clears)

1. A Gmail account with plus-addressing enabled (so `you+stage5test@gmail.com` routes to `you@gmail.com`)
2. Gmail app password (not your regular password) — generate at https://myaccount.google.com/apppasswords
3. Environment:
   ```bash
   export AGENTKEYS_EMAIL_BACKEND=gmail
   export AGENTKEYS_EMAIL_USER="you@gmail.com"
   export AGENTKEYS_EMAIL_PASSWORD="<app password>"
   export AGENTKEYS_EMAIL_HOST="imap.gmail.com"  # default, set explicitly if overriding
   export AGENTKEYS_EMAIL_PORT="993"
   ```
4. Daemon running and paired (see Stage 4 manual test guide)

### Run the provision

```bash
agentkeys provision openrouter
```

### Expected behavior

1. Stderr shows step lines (currently single-shot; real-time streaming ships in 5b):
   ```
   Creating account...
   Waiting for email verification...
   Extracting API key...
   Verifying key against openrouter.ai...
   Stored.
   ```
2. Stdout shows the masked key, e.g.:
   ```
   sk-or-v1-abcd1234****...WXYZ
   ```
3. Exit code 0.
4. A new OpenRouter account exists at `you+stage5test-<timestamp>@gmail.com`.
5. `agentkeys read openrouter` returns the full key.
6. Manually calling `curl -H "Authorization: Bearer $(agentkeys read openrouter)" https://openrouter.ai/api/v1/models` returns HTTP 200.

### Failure modes to watch for

- **CAPTCHA / Cloudflare challenge** — the Tier 2 script does not solve CAPTCHAs. Expect a Tripwire event with `kind: selector_timeout`. This is the signal that Stage 5b's agentic fallback is needed (human or LLM drives the browser through the challenge). Until 5b ships, just abort and retry from a different IP.
- **Email didn't arrive within 60s** — check spam folder, check plus-addressing is actually forwarding. Tripwire `email_timeout` indicates the IMAP fetch exhausted its polling window.
- **Key verification fails with `phantom`** — the scraper extracted something key-shaped that isn't a real API key. Inspect the page at the success-step selector; OpenRouter may have changed its DOM. File an issue with the HAR dump.
- **Store fails after verify** — the error message will include the obtained (masked) key. Run `agentkeys store openrouter <full-key-you-still-have>` manually to recover, then investigate why the backend rejected.

---

## 9. Troubleshooting

### `npm test` hangs

Playwright might be waiting for a browser that isn't installed.
```bash
npx playwright install chromium --with-deps
```

### `cargo test` complains about missing `agentkeys-provisioner`

The workspace member might not be listed in the top-level `Cargo.toml`. Check `[workspace]/members` contains `crates/agentkeys-provisioner`.

### Grep guard fails

A pattern in `provisioner-scripts/src/patterns/` has a service-specific string. Find it:
```bash
grep -rniE "openrouter|brave|jina|groq|anthropic|gemini|twitter|instagram" \
  provisioner-scripts/src/patterns/
```
Extract the offender into a parameter in the calling scraper under `scrapers/`.

### Phantom chaos test passes with a Success event

**Critical.** The verification gate is broken. Check:
1. `provisioner-scripts/src/lib/verify.ts` — the fetch function actually returns 401 from the mock?
2. `provisioner-scripts/src/scrapers/openrouter.ts` — the Success event is only emitted AFTER verify returns `{valid:true}`?
3. The phantom test's `route.fulfill()` — the mock verify endpoint is actually being intercepted?

Fix before merging anything. Silent-corrupt-credential is the primary threat this defends against.

### Clippy says "useless_vec" or "useless_format"

These are slop markers. Apply the suggested `cargo clippy --fix` or replace `vec![...]` with `[...]` arrays / `format!("literal")` with `.to_string()`. Deslop passes catch these.

---

## What to do when Stage 5b lands

When Stage 5b ships (agentic fallback, `/agentkeys-record-scraper` skill, script generation loop), this document will grow new sections for:
- Triggering the agentic fallback via a failing Tier 2 script (expected Tripwire → Tier 3 engagement)
- Inspecting the audit JSONL at `~/.agentkeys/logs/provision-<timestamp>.jsonl`
- Running the `/agentkeys-record-scraper` skill to add a new service (Brave, Jina, etc.)
- Verifying the fallback→PR loop does NOT auto-submit for agent-driven callers (non-TTY)

For now, Stage 5a with OpenRouter as the only deterministic scraper is the full surface.

---

## Summary checklist

- [ ] `bash harness/stage-5a-done.sh` exits 0
- [ ] All 67 Rust tests pass across 4 crates
- [ ] All 15 TypeScript tests pass
- [ ] Phantom-key chaos test aborts with Error event (no Success)
- [ ] Pattern grep guard returns empty
- [ ] `npm run typecheck` exits 0
- [ ] `cargo clippy` has zero warnings in Stage 5a crates
- [ ] `agentkeys.provision` appears in MCP `tools/list` response
- [ ] CLI masked-key output never contains the full raw key
- [ ] CLI error output follows problem + cause + fix + docs format
- [ ] Orchestrator emits all four metric names to stderr
- [ ] (Live, after ToS check) `agentkeys provision openrouter` creates a real account and stores a verified key
