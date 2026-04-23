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

#### 🚀 Demo path: your existing Gmail + plus-addressing + app password

Why plus-addressing as the primary demo path:

- **Unique email per run.** OpenRouter's sign-up/sign-in page is a single URL — if you submit an email that already has an account, you land on a returning-user screen the scraper was not designed to traverse, and the provision fails with a `no terminal event`-style error. `you+or-<timestamp>@gmail.com` is a fresh address to OpenRouter on every run, so every run hits the pristine signup path.
- **Zero account creation.** Uses your existing Gmail — no new Google account, no new phone verification.
- **Single inbox to clean up.** The OpenRouter confirmation mail lands in your real inbox; delete one thread after the demo and you're done.
- **Scales to repeat testing.** Rotate the local-part (`+or-1`, `+or-2`, …) or include a timestamp and you have DWD-equivalent disposable emails without building DWD.

**1. Generate a Gmail app password for IMAP.**

- Requires 2FA enabled on your Google account. If not already enabled: [myaccount.google.com](https://myaccount.google.com) → Security → turn on 2-Step Verification (TOTP or SMS is fine; enrollment is a one-time cost).
- Visit [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords). Create one named `agentkeys-stage5`. Google gives you a 16-character password.
- Copy immediately — it's shown once. Revoke anytime from the same page.

**2. Export the env vars.**

The scraper splits **IMAP login** from **signup email**. Set both:

```bash
export AGENTKEYS_EMAIL_BACKEND=gmail

# IMAP login — must be the canonical Gmail address.
export AGENTKEYS_EMAIL_USER="you@gmail.com"
export AGENTKEYS_EMAIL_PASSWORD="xxxx xxxx xxxx xxxx"   # 16-char app password

# What we type into OpenRouter's signup form.
# Plus-addressed alias so OpenRouter sees a brand-new email per run;
# mail is still delivered to you@gmail.com.
export AGENTKEYS_SIGNUP_EMAIL="you+or-$(date +%s)@gmail.com"

export AGENTKEYS_EMAIL_HOST="imap.gmail.com"
export AGENTKEYS_EMAIL_PORT="993"
```

> **Why two email vars.** `AGENTKEYS_EMAIL_USER` is the IMAP login — Gmail IMAP only accepts your canonical address (plus-addressing aliases are rejected at login). `AGENTKEYS_SIGNUP_EMAIL` is what we fill into the service's sign-up form — plus-addressing works there because SMTP delivery honors the `+alias` suffix. If `AGENTKEYS_SIGNUP_EMAIL` is unset, the scraper falls back to `AGENTKEYS_EMAIL_USER` — which is fine for a dedicated bot account (see alternative below) but guarantees a "account already exists" collision if you reuse a canonical address across runs.

Once the app password is set, the demo sees **zero 2FA prompts**. App passwords bypass 2FA by design — they're Google's non-interactive credential, scoped to IMAP only, revocable anytime.

**3. Build binaries + install provisioner-script deps (one-time).**

```bash
cd ~/Projects/agentkeys
cargo build --workspace --release
npm install --prefix provisioner-scripts
npx playwright install chromium --with-deps
```

<details>
<summary>Alternative: dedicated throwaway Gmail (cleanest but more setup)</summary>

Create a fresh bot Gmail (`wildmeta-stage5-demo@gmail.com`), enable 2FA + TOTP, generate an app password. Set `AGENTKEYS_EMAIL_USER` to the bot address; leave `AGENTKEYS_SIGNUP_EMAIL` unset. One-time ~10 minutes setup; gives you a fully controlled inbox with no personal-mail pollution. Re-runs need `--force` or account-delete between attempts because the bot address itself will collide.

</details>

<details>
<summary>Alternative: Google Workspace DWD (for operators with an existing Workspace subscription)</summary>

See [`docs/stage5-workspace-email-setup.md`](stage5-workspace-email-setup.md). That path mints a throwaway `stage5test-<timestamp>@wildmeta.ai` per run, reads its inbox via the Gmail API (no app password, no interactive OAuth), and deletes the user at the end. One-time ~20-minute admin setup + currently 3-5 days of code work to replace the `imapflow` fetcher with a Gmail-API fetcher that uses DWD impersonation. Right choice for enterprise deployments that already run Workspace; overkill for the demo.

</details>

### Run it

Two terminals. Everything runs from the repo root (`~/Projects/agentkeys`).

**Terminal 1 — mock backend.** Stage 5a stores the provisioned key via the mock server (real Heima + TEE ships in v0.1). Leave this running.

```bash
cd ~/Projects/agentkeys
cargo run --release -p agentkeys-mock-server -- --port 8090
# Expected: "Mock server running on port 8090"
```

**Terminal 2 — provision.** Carry the Gmail env vars from step 2 into this shell (or re-`export` them here). Note: if you are using plus-addressing, **re-evaluate `AGENTKEYS_SIGNUP_EMAIL` for every run** so the timestamp is fresh and OpenRouter sees a new email — otherwise your second run will collide with the first run's account.

```bash
cd ~/Projects/agentkeys
BIN=$(pwd)/target/release/agentkeys
BACKEND=http://127.0.0.1:8090

# 1. Initialize the master session (one-time per shell / mock restart).
$BIN --backend $BACKEND init --mock-token stage5-demo
# Expected: wallet printed; ~/.agentkeys/master/session.json created.

# 2. Sanity-check the email env vars landed in this shell.
env | grep -E 'AGENTKEYS_(EMAIL|SIGNUP)_'
# Expected: AGENTKEYS_EMAIL_{BACKEND,USER,PASSWORD,HOST,PORT} and AGENTKEYS_SIGNUP_EMAIL.
# If AGENTKEYS_SIGNUP_EMAIL is missing, the scraper falls back to AGENTKEYS_EMAIL_USER,
# which will hit "account already exists" on the second run against OpenRouter.

# 3. Re-seed a fresh signup alias for this run (plus-addressing path only).
export AGENTKEYS_SIGNUP_EMAIL="you+or-$(date +%s)@gmail.com"

# 4. Run the live OpenRouter provision.
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
- `~/.agentkeys/logs/provision-openrouter-<unix_ts>.log` — **written automatically when a provision fails with "no terminal event."** Contains the exit code, every event the subprocess emitted, and the full captured stderr. `ls -lt ~/.agentkeys/logs/ | head` to find the most recent.
- Stderr of `provision openrouter` — the single-shot step lines shown under "Expected behavior" below.

**Debugging a failure:**

1. Check the error message on stderr — if it ends with `full log: /path/to/provision-openrouter-<ts>.log`, that file has the full signal.
2. `cat` the log file. The `=== subprocess stderr ===` section usually shows the real cause (Playwright browser-launch error, IMAP connection refused, an unhandled rejection from the pattern, etc.).
3. For interactive debugging, run the TS scraper directly against a visible browser:
   ```bash
   # Temporarily flip headless:false at provisioner-scripts/src/scrapers/openrouter.ts:~116,
   # then:
   cd ~/Projects/agentkeys
   npx tsx provisioner-scripts/src/scrapers/openrouter.ts
   ```
   You'll see the page in real time — instant diagnosis for selector drift, returning-user UI paths, or CAPTCHA challenges.

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

- **"subprocess ended without terminal event"** — the scraper crashed before emitting any event (Playwright browser-launch failed, IMAP connection refused, unhandled rejection, etc.). The error message now ends with `full log: ~/.agentkeys/logs/provision-openrouter-<ts>.log` — open that file; the `=== subprocess stderr ===` section has the real cause. If stderr is empty, re-run the TS scraper directly with `npx tsx provisioner-scripts/src/scrapers/openrouter.ts` and watch the node-side output.
- **"account already exists" (returning-user path)** — OpenRouter's `/auth` is signup+signin on one URL. If `AGENTKEYS_SIGNUP_EMAIL` is an address that already has an OpenRouter account, the site lands on a returning-user UI the scraper can't traverse, and you'll get a `selector_timeout` tripwire or (if the path is weirder) a "no terminal event." Re-evaluate `AGENTKEYS_SIGNUP_EMAIL` with a fresh timestamp (`you+or-$(date +%s)@gmail.com`) and retry.
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

## 4. Stage 5b — CDP-connected real-Chrome scraper (partial: proven working, blocked on email duplicate)

### What's landed

- **[provisioner-scripts/src/scrapers/openrouter-cdp.ts](../provisioner-scripts/src/scrapers/openrouter-cdp.ts)** — connects to a user-launched real Chrome via `chromium.connectOverCDP()`, drives the OpenRouter Clerk-hosted signup form, polls Gmail IMAP for the OTP code, mints a new key on `/keys`, prints the `sk-or-v1-*` value on stdout.
- **Why CDP, not Playwright-launched Chromium:** Playwright's bundled Chromium ships with `--enable-automation` baked in. Cloudflare Turnstile detects this at runtime (error **600010** — "browser execution environment suspicious") and refuses to issue a token even when a human clicks the checkbox. Connecting to a user-launched *real* Chrome bypasses this because the browser process has no automation flags. Verified 2026-04-20: Turnstile passes invisibly in real Chrome, Clerk backend returns normal responses.

### How to run (when you have a fresh-to-OpenRouter email)

1. **Launch real Chrome with CDP enabled** (fresh profile, separate from your daily browsing):
   ```bash
   /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
     --remote-debugging-port=9222 \
     --user-data-dir=/tmp/agentkeys-chrome-profile &
   ```
   A blank Chrome window opens. Don't navigate it manually — the scraper drives it.

2. **Export env** (Gmail IMAP creds + a signup email OpenRouter hasn't seen):
   ```bash
   export AGENTKEYS_EMAIL_BACKEND=gmail
   export AGENTKEYS_EMAIL_USER="you@gmail.com"                   # canonical IMAP login
   export AGENTKEYS_EMAIL_PASSWORD="<gmail app password>"
   export AGENTKEYS_EMAIL_HOST="imap.gmail.com"
   export AGENTKEYS_EMAIL_PORT="993"
   export AGENTKEYS_SIGNUP_EMAIL="<NEW-address-OpenRouter-hasnt-seen>"
   export AGENTKEYS_SIGNUP_PASSWORD="<strong-random>"
   ```

3. **Run the scraper:**
   ```bash
   cd ~/Projects/agentkeys
   node --import tsx/esm provisioner-scripts/src/scrapers/openrouter-cdp.ts
   ```
   Last stdout line is the `sk-or-v1-*` key. Stderr shows `[cdp] <time> <step>` progress lines.

4. **Store via the CLI:**
   ```bash
   $BIN --backend $BACKEND store openrouter <KEY>
   $BIN --backend $BACKEND read openrouter
   curl -H "Authorization: Bearer $(... read openrouter)" https://openrouter.ai/api/v1/models
   ```

### Known blocker — WHY "a fresh-to-OpenRouter email" is non-trivial today

OpenRouter's Clerk integration **normalizes Gmail / Workspace plus-aliases** to the canonical address when checking for duplicates. If `agent@wildmeta.ai` already has an OpenRouter account, every plus-aliased variant (`agent+or-<ts>@wildmeta.ai`, `agent+stage5b@wildmeta.ai`, etc.) gets rejected with:

> This email address is already in use. Creating multiple accounts with the same email address is not allowed.

Only a **different canonical local-part** passes (e.g. `bot-42@wildmeta.ai` is fine if no one has used it; `agent+42@wildmeta.ai` is not because it normalizes to `agent@wildmeta.ai`).

### Pickup plan — blocked on Stage 6

This unblocks when Stage 6 ships its **throwaway inbox provisioning API** (see [`docs/spec/plans/development-stages.md`](./spec/plans/development-stages.md) §Stage 6 deliverables). Stage 6 mints distinct local-parts like `bot-<random>@agentkeys-email.io` per call, Clerk-normalization-proof because each has a unique local-part. The pickup checklist:

- [ ] Stage 6 SES stack deployed (`agentkeys-email.io` verified, MX/DKIM/SPF live, S3 bucket + IAM OIDC provider + bucket policy per §Stage 6)
- [ ] `agentkeys inbox provision` CLI mints a `<id>@agentkeys-email.io` and returns the address
- [ ] `provisioner-scripts/src/lib/email.ts` has an SES-S3 reader variant that reads messages for the provisioned address
- [ ] Set `AGENTKEYS_SIGNUP_EMAIL` to the provisioned address + point the IMAP fetcher at the SES-S3 reader
- [ ] Re-run the CDP scraper per §4 step 3 above
- [ ] Verify all four Stage 5a acceptance criteria pass with the resulting key
- [ ] Promote the scraper from `provisioner-scripts/src/scrapers/openrouter-cdp.ts` to the default OpenRouter provisioner (delete or archive the Turnstile-blocked `openrouter.ts`)

See [`docs/manual-test-stage6.md`](./manual-test-stage6.md) for the Stage 6 manual demo once that stage lands.

### What's also deferred past the CDP scraper (original Stage 5b scope)

Still-future pieces of the original Stage 5b agentic-fallback design:
- A new demo path that triggers the agentic fallback via a failing Tier 2 script (expected Tripwire → Tier 3 engagement).
- A step for inspecting the audit JSONL at `~/.agentkeys/logs/provision-<timestamp>.jsonl`.
- A `/agentkeys-record-scraper` walkthrough for adding a new service (Brave, Jina, etc.).
- An assertion that the fallback→PR loop does **not** auto-submit for agent-driven callers (non-TTY).

---

## Summary checklist

- [ ] `bash harness/stage-5a-done.sh` exits 0 (covers tests 1–8 above)
- [ ] (Once ToS cleared) `agentkeys provision openrouter` creates a real account, stores a verified key, `curl` against `/api/v1/models` returns 200

---

## 5. Backend selector — `AGENTKEYS_EMAIL_BACKEND`

`provisioner-scripts/src/lib/email.ts` dispatches `fetchVerificationCode` to one of three backends based on this env var.

| `AGENTKEYS_EMAIL_BACKEND` | Required env vars | Description |
|---|---|---|
| `gmail` (default) | `AGENTKEYS_EMAIL_USER`, `AGENTKEYS_EMAIL_PASSWORD` | Polls Gmail via IMAP. Optional: `AGENTKEYS_EMAIL_HOST` (default `imap.gmail.com`), `AGENTKEYS_EMAIL_PORT` (default `993`). |
| `mock-inbox` | `AGENTKEYS_SESSION_TOKEN`, `AGENTKEYS_SIGNUP_EMAIL` | Polls `GET /mock/inbox/messages?address=<AGENTKEYS_SIGNUP_EMAIL>` on the running mock server. Optional: `AGENTKEYS_BACKEND_URL` (default `http://127.0.0.1:8090`). |
| `ses-s3` | `AGENTKEYS_SES_BUCKET` | Lists objects under `s3://$AGENTKEYS_SES_BUCKET/inbound/`, downloads new `.eml` files, parses MIME headers. AWS credentials via standard SDK chain (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / instance profile). |

**Quick smoke test for `mock-inbox` dispatch** (server must be running on port 8090; expects a timeout since no message is delivered):

```bash
AGENTKEYS_EMAIL_BACKEND=mock-inbox \
AGENTKEYS_SIGNUP_EMAIL=bot-test@agentkeys-email.io \
AGENTKEYS_SESSION_TOKEN=demo-token \
node --input-type=module <<'EOF'
import { fetchVerificationCode } from './provisioner-scripts/src/lib/email.js';
fetchVerificationCode({ from: /./, subject: /./, codeRegex: /(\d{6})/, timeoutMs: 3000 })
  .catch(e => { console.log('dispatch ok, error:', e.code ?? e.message); });
EOF
# Expected output: "dispatch ok, error: EMAIL_TIMEOUT" (or a fetch error if server is not running)
```
