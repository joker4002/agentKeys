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

For the demo-only purpose of Stage 5, the goal is the **shortest path to a running provisioner** with an inbox the agent fully controls. Use a dedicated personal Gmail below — reuses our existing IMAP code path, ~10 minutes total setup, no Workspace subscription required.

> **This is a temporary demo solution.** For production (v0.1), the agent mailbox moves to SES-hosted `*@agentkeys-email.io` under the three-layer `TokenAuthority` abstraction. See the [email-system wiki page](../wiki/email-system.md) for the full architecture and why we're running demo-and-production on different backends deliberately.

#### 🚀 Demo path: dedicated personal Gmail + TOTP + app password

Why dedicated (not your personal inbox with plus-addressing): the agent gets a clean inbox it fully controls, no personal mail pollution, cleanup is a single account-delete.

**1. Create a fresh Gmail account for the bot.**

Sign up at [accounts.google.com](https://accounts.google.com) with a name like `wildmeta-stage5-demo@gmail.com`. Google will ask for a recovery phone — use your personal phone; you only need it once for step 2.

**2. Enable 2-Step Verification and enroll TOTP as the second factor.**

Gmail IMAP access chain: `app password` requires `2FA enabled` requires `second factor enrolled`. Using an authenticator app as that second factor makes the account non-interactive after this one-time enrollment.

- Open [myaccount.google.com](https://myaccount.google.com) → **Security**
- **Turn on 2-Step Verification.** Google sends an SMS to your recovery phone to start enrollment.
- Under 2-Step Verification settings, add **Authenticator app** as a second step. Google shows a QR code and a secret.
- Scan into Google Authenticator / Authy / 1Password / Bitwarden / whatever TOTP client you already use. You now own the second factor.
- (Optional) once TOTP is active, you can drop SMS as a 2FA method — Google keeps the phone for account recovery but stops using it as a live second factor.

**3. Generate an app password for IMAP.**

- Visit [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).
- Create one named "agentkeys-stage5". Google gives you a 16-character password.
- Copy it immediately — it's shown once. Revoke anytime from the same page.

**4. Export the four env vars.**

```bash
export AGENTKEYS_EMAIL_BACKEND=gmail
export AGENTKEYS_EMAIL_USER="wildmeta-stage5-demo@gmail.com"   # the bot account from step 1
export AGENTKEYS_EMAIL_PASSWORD="xxxx xxxx xxxx xxxx"          # 16-char app password from step 3
export AGENTKEYS_EMAIL_HOST="imap.gmail.com"
export AGENTKEYS_EMAIL_PORT="993"
```

Once the app password is set, the demo sees **zero 2FA prompts**. App passwords bypass 2FA by design — they're Google's non-interactive credential, scoped to IMAP only, revocable anytime.

**5. Build binaries + install provisioner-script deps (one-time).**

```bash
cd ~/Projects/agentkeys
cargo build --workspace --release
npm install --prefix provisioner-scripts
npx playwright install chromium --with-deps
```

<details>
<summary>Alternative: Google Workspace DWD (for operators with an existing Workspace subscription)</summary>

See [`docs/stage5-workspace-email-setup.md`](stage5-workspace-email-setup.md). That path mints a throwaway `stage5test-<timestamp>@wildmeta.ai` per run, reads its inbox via the Gmail API (no app password, no interactive OAuth), and deletes the user at the end. One-time ~20-minute admin setup + currently 3-5 days of code work to replace the `imapflow` fetcher with a Gmail-API fetcher that uses DWD impersonation. Longer upfront cost than the dedicated-Gmail demo path, but the right choice for enterprise deployments that already run Workspace.

</details>

<details>
<summary>Alternative: plus-addressed personal Gmail (shared-inbox quick demo)</summary>

If you don't want to create a dedicated account and are OK with one-off OpenRouter mail landing in your real inbox, plus-addressing on your existing Gmail works for a single demo run.

1. **Your existing personal Gmail account** — plus-addressing is a Gmail-native feature: mail sent to `you+anything@gmail.com` is delivered to `you@gmail.com` without any configuration. A single inbox supports unlimited test aliases (`you+stage5test-20260418@gmail.com`).
2. **Gmail app password** (not your regular password) — generate at https://myaccount.google.com/apppasswords. Scoped to IMAP access only; revoke after the demo.
3. **Environment:**
   ```bash
   export AGENTKEYS_EMAIL_BACKEND=gmail
   export AGENTKEYS_EMAIL_USER="you@gmail.com"      # your real Gmail; Stage 5a appends +alias at signup
   export AGENTKEYS_EMAIL_PASSWORD="<app password>" # NOT your normal Google password
   export AGENTKEYS_EMAIL_HOST="imap.gmail.com"
   export AGENTKEYS_EMAIL_PORT="993"
   ```

Downside: the agent doesn't fully control the inbox (shared with the human), and the OpenRouter confirmation email lingers in your personal mail until you delete it.

</details>

### Run it

Two terminals. Everything runs from the repo root (`~/Projects/agentkeys`).

**Terminal 1 — mock backend.** Stage 5a stores the provisioned key via the mock server (real Heima + TEE ships in v0.1). Leave this running.

```bash
cd ~/Projects/agentkeys
cargo run --release -p agentkeys-mock-server -- --port 8090
# Expected: "Mock server running on port 8090"
```

**Terminal 2 — provision.** Carry the four Gmail env vars from step 4 into this shell (or re-`export` them here). Then:

```bash
cd ~/Projects/agentkeys
BIN=$(pwd)/target/release/agentkeys
BACKEND=http://127.0.0.1:8090

# 1. Initialize the master session (one-time per shell / mock restart).
$BIN --backend $BACKEND init --mock-token stage5-demo
# Expected: wallet printed; ~/.agentkeys/master/session.json created.

# 2. Sanity-check the Gmail env vars landed in this shell.
env | grep AGENTKEYS_EMAIL_
# Expected: four AGENTKEYS_EMAIL_* lines matching step 4.

# 3. Run the live OpenRouter provision.
$BIN --backend $BACKEND provision openrouter
# Expect ~30-90 s: browser opens headless, account created,
# email verified, API key extracted + verified, stored in the mock backend.
```

**What this does under the hood:**

- `init` authenticates the master CLI to the mock backend and caches the session token (OS keychain on macOS/Linux with keychain, file fallback otherwise).
- `provision openrouter` runs `npx tsx provisioner-scripts/src/scrapers/openrouter.ts` against a real Chromium session, uses the Gmail IMAP creds from your exported env to read the confirmation email, extracts + verifies the key against `https://openrouter.ai/api/v1/models`, and stores it into the mock backend under the master session's wallet.
- No daemon, no pairing — Stage 5a provision runs entirely as the master CLI. Daemon + pairing are Stage 4's flow for agent-side credential access, not needed for the live provision demo.

**After it succeeds:**

```bash
# Read the full stored key back.
$BIN --backend $BACKEND read openrouter
# Expected: sk-or-v1-...

# Verify it works against OpenRouter.
curl -s -H "Authorization: Bearer $($BIN --backend $BACKEND read openrouter)" \
  https://openrouter.ai/api/v1/models | head -c 200
# Expected: HTTP 200 + a JSON body starting with {"data":[...
```

**Artifacts you can inspect:**

- `~/.agentkeys/master/session.json` — the master session (wallet + bearer token).
- `~/.agentkeys/logs/provision-<timestamp>.jsonl` — per-step audit trail (when present; full audit logging lands with 5b).
- Stderr of `provision openrouter` — the single-shot step lines shown under "Expected behavior" below.

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
4. A new OpenRouter account exists at the email address you configured in `$AGENTKEYS_EMAIL_USER` (e.g. `wildmeta-stage5-demo@gmail.com` for the dedicated-Gmail path, or `you+stage5test-<timestamp>@gmail.com` for the plus-addressing fallback).
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
