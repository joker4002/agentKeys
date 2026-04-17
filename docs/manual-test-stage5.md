# Stage 5a Manual Test Guide

**Prerequisite:** Rust toolchain installed, Node.js 20+, `npm` available, `cargo build --workspace` succeeds.

> **Scope.** This guide covers Stage 5a (provisioner, deterministic + patterns tier).
> Stage 5b (agentic fallback via MCP browser primitives, fallback→PR loop,
> `/agentkeys-record-scraper` skill usage) is not yet shipped and is tested
> separately once 5b lands. Stage 6 (npm packaging) is deferred to v0.1.

Stage 5a has two tests that matter:

1. **The live demo** — a real OpenRouter signup, real Gmail, real API key stored and verified. This is what you run to show Stage 5a actually works end-to-end. Written up top; this is the centerpiece.
2. **Everything else** — Rust + TS unit tests, phantom-key chaos, grep guard, typecheck, clippy, MCP registration, observability metrics. All of it runs in one command: `bash harness/stage-5a-done.sh`. No per-section prose required.

---

## 1. The demo — live OpenRouter provision

> ⛔ **DO NOT RUN YET — blocked on ToS check.** The OpenRouter ToS compliance item in `TODOS.md` must clear first. Running this before the check may violate OpenRouter's terms and create a real account tied to your email.

This is the end-to-end test that actually creates a real OpenRouter account. One command, and by the end you have a verified API key stored in `agentkeys`:

```bash
agentkeys provision openrouter
```

### Prerequisites (once the ToS check clears)

1. **Your existing personal Gmail account** — do *not* create a new Gmail account for this demo. Plus-addressing is a Gmail-native feature: mail sent to `you+anything@gmail.com` is delivered to `you@gmail.com` without any configuration, so a single personal inbox already supports unlimited test aliases (e.g. `you+stage5test-20260418@gmail.com`). A fresh Gmail created for automation risks Google flagging it as a bot account and could itself violate Google's ToS — the whole point of plus-addressing is to avoid that.
2. **Gmail app password** (not your regular password) — generate at https://myaccount.google.com/apppasswords. Scoped to IMAP access only; revoke it after the demo.
3. **Environment:**
   ```bash
   export AGENTKEYS_EMAIL_BACKEND=gmail
   export AGENTKEYS_EMAIL_USER="you@gmail.com"      # your real Gmail; Stage 5a appends +alias at signup
   export AGENTKEYS_EMAIL_PASSWORD="<app password>" # from step 2, NOT your normal Google password
   export AGENTKEYS_EMAIL_HOST="imap.gmail.com"     # default; set explicitly if overriding
   export AGENTKEYS_EMAIL_PORT="993"
   ```
4. **Daemon running and paired** — see the Stage 4 manual test guide.

### Expected behavior

1. Stderr shows single-shot step lines (real-time streaming ships in 5b):
   ```
   Creating account...
   Waiting for email verification...
   Extracting API key...
   Verifying key against openrouter.ai...
   Stored.
   ```
2. Stdout shows the masked key:
   ```
   sk-or-v1-abcd1234****...WXYZ
   ```
3. Exit code 0.
4. A new OpenRouter account exists at `you+stage5test-<timestamp>@gmail.com`.
5. `agentkeys read openrouter` returns the full key.
6. `curl -H "Authorization: Bearer $(agentkeys read openrouter)" https://openrouter.ai/api/v1/models` returns HTTP 200.

### Failure modes to watch for

- **CAPTCHA / Cloudflare challenge** — the Tier 2 script does not solve CAPTCHAs. Expect a Tripwire event with `kind: selector_timeout`. This is the signal that Stage 5b's agentic fallback is needed. Until 5b ships, abort and retry from a different IP.
- **Email didn't arrive within 60 s** — check spam, check plus-addressing forwarding. Tripwire `email_timeout` means the IMAP fetch exhausted its polling window.
- **Key verification fails with `phantom`** — the scraper extracted something key-shaped that isn't a real API key. OpenRouter may have changed its DOM; inspect the page at the success-step selector and file an issue with the HAR dump.
- **Store fails after verify** — the error message includes the obtained (masked) key. Run `agentkeys store openrouter <full-key-you-still-have>` manually to recover, then investigate why the backend rejected.

---

## 2. Everything else — one command

Runs every non-live check in a single script. Use this before merging anything that touches Stage 5a crates or `provisioner-scripts/`.

```bash
cd ~/Projects/agentkeys
bash harness/stage-5a-done.sh
```

**Expected last line:**
```
STAGE 5a PASSED
```

Exit 0 = everything green. Non-zero = the failing step number and a red `✗` line. Do not merge on red.

### What the script runs

| # | Step | Asserts |
|---|---|---|
| 1 | Rust unit tests (`agentkeys-types`, `-provisioner`, `-mcp`, `-cli`) | 67 tests pass |
| 2 | TS install + `npm test` | 15 tests pass across 6 files |
| 3 | Phantom-key chaos test in isolation | silent-corrupt defense holds — Error event fires, no Success |
| 4 | Grep guard over `provisioner-scripts/src/patterns/` | zero service-specific strings leaked into patterns |
| 5 | TS typecheck | no TypeScript errors |
| 6 | `cargo clippy` on Stage 5a crates with `-D warnings` | zero clippy warnings |
| 7 | MCP `tools/list` on the daemon (with the `AGENTKEYS_SESSION` test seam) | `agentkeys.provision` advertised |
| 8 | Observability | orchestrator emits `tier_used`, `duration_seconds`, `verification_result` as JSON metric lines |

### Setup (one-time)

If any step fails with a "command not found" or "workspace member not found" error, you probably haven't installed dependencies yet:

```bash
cd ~/Projects/agentkeys
cargo build --workspace --release
npm install --prefix provisioner-scripts
npx playwright install chromium --with-deps
```

---

## 3. Troubleshooting

### `npm test` hangs

Playwright is waiting for a browser that isn't installed:

```bash
npx playwright install chromium --with-deps
```

### Grep guard fails

A pattern under `provisioner-scripts/src/patterns/` has a service-specific string. Find it:

```bash
grep -rniE "openrouter|brave|jina|groq|anthropic|gemini|twitter|instagram" \
  provisioner-scripts/src/patterns/
```

Extract the offender into a parameter in the calling scraper under `scrapers/`.

### Phantom chaos test passes with a Success event

**Critical.** The verification gate is broken. Check, in order:

1. `provisioner-scripts/src/lib/verify.ts` — does the fetch actually return 401 from the mock?
2. `provisioner-scripts/src/scrapers/openrouter.ts` — is Success only emitted AFTER verify returns `{valid:true}`?
3. The phantom test's `route.fulfill()` — is the mock verify endpoint actually being intercepted?

Fix before merging anything. Silent-corrupt-credential is the primary threat this defends against.

### MCP step reports `Pair code: …`

The `AGENTKEYS_SESSION=test-token` test seam didn't reach the daemon — the env var needs to be on the same shell line as the binary invocation. The script already does this; if you're re-running step 7 by hand, make sure you keep the env vars on the same line.

### Clippy says `useless_vec` / `useless_format`

These are slop markers. Apply the suggested `cargo clippy --fix` or hand-replace `vec![...]` with `[...]` arrays and `format!("literal")` with `.to_string()`. Deslop passes catch these.

---

## 4. What to do when Stage 5b lands

When Stage 5b ships (agentic fallback, `/agentkeys-record-scraper` skill, script-generation loop), this document will grow:

- A new demo path that triggers the agentic fallback via a failing Tier 2 script (expected Tripwire → Tier 3 engagement).
- A step for inspecting the audit JSONL at `~/.agentkeys/logs/provision-<timestamp>.jsonl`.
- A `/agentkeys-record-scraper` walkthrough for adding a new service (Brave, Jina, etc.).
- An assertion that the fallback→PR loop does **not** auto-submit for agent-driven callers (non-TTY).

For now, Stage 5a with OpenRouter as the only deterministic scraper is the full surface.

---

## Summary checklist

- [ ] `bash harness/stage-5a-done.sh` exits 0 (covers tests 1–8 above)
- [ ] (Once ToS cleared) `agentkeys provision openrouter` creates a real account, stores a verified key, `curl` against `/api/v1/models` returns 200
