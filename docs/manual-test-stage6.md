# Stage 6 Live Demo — throwaway inbox on `@bots.litentry.org`

**Prerequisite:** [`docs/stage6-aws-setup.md`](./stage6-aws-setup.md) complete through §7 (hand-back values captured). You have the `agentkeys-daemon` user's access key + secret in 1Password.

End-to-end test: provision a throwaway address on your SES-verified domain, drive OpenRouter signup through the Stage 5b CDP scraper, let the verification email flow through SES → S3, have the scraper read it via the `ses-s3` backend, mint + store the API key, verify with `curl`.

## 1. One-time: install + build (skip if already done)

```bash
cd ~/Projects/agentkeys
cargo build --workspace --release
npm install --prefix provisioner-scripts
npx playwright install chromium --with-deps
```

## 2. Shell env setup

Two sets of IAM creds stashed under project-specific env vars so neither pollutes `AWS_*` persistently. Only the 1h assumed-role temp creds ever live in `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`.

| Identity | Purpose | Env var names |
|---|---|---|
| `agentKeys-admin` | Built the infra; used for any non-demo `aws` call via env-prefix | `ADMIN_AWS_ACCESS_KEY_ID` + `ADMIN_AWS_ACCESS_KEY_SECRET` |
| `agentkeys-daemon` | `sts:AssumeRole` only; impersonated by the daemon | `DAEMON_ACCESS_KEY_ID` + `DAEMON_SECRET_ACCESS_KEY` |

> **Naming drift worth noting:** admin uses `..._ACCESS_KEY_SECRET`, daemon uses AWS-standard `..._SECRET_ACCESS_KEY`. Both work — they're names you chose, not names the AWS SDK reads directly. Pick one pattern eventually to avoid confusion.

**Quick path — just source the helper:**

```bash
cd ~/Projects/agentkeys
source scripts/stage6-demo-env.sh
```

The script populates all Stage 6 env vars, calls `sts:AssumeRole` as the daemon, exports the 1h temp creds into this shell, and prints a sanity-check line. If `DAEMON_ACCESS_KEY_ID` / `DAEMON_SECRET_ACCESS_KEY` aren't in your shell, it fails fast with a clear message.

Re-source it whenever you want fresh creds (temp creds expire in 1h; typical run is 1–3 min).

<details>
<summary>What the script does (for reference / debugging)</summary>

```bash
export REGION=us-east-1
export AWS_REGION="$REGION"   # AWS SDK reads AWS_REGION, not REGION
export DOMAIN=bots.litentry.org
export ACCOUNT_ID=429071895007
export BUCKET="agentkeys-mail-${ACCOUNT_ID}"
export AGENTKEYS_EMAIL_BACKEND=ses-s3
export AGENTKEYS_SES_BUCKET="$BUCKET"
export AGENTKEYS_SIGNUP_EMAIL="bot-$(date +%s)@${DOMAIN}"
export AGENTKEYS_SIGNUP_PASSWORD="Stg6-$(date +%s)-xZq9okFg"
export CDP_URL="http://localhost:9222"

CREDS=$(AWS_ACCESS_KEY_ID="$DAEMON_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$DAEMON_SECRET_ACCESS_KEY" \
  aws sts assume-role \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-agent" \
    --role-session-name "stage6-demo-$(date +%s)")

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')
```

Env-prefix on the AssumeRole call scopes the long-lived daemon keys to that one subprocess — they never touch `AWS_*` in your shell.
</details>

> **Why env-prefix for AssumeRole.** Writing `AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… aws sts ...` on the same line (no `export`) scopes those values to that one subprocess. No save/restore gymnastics, no state to clean up.
>
> **Why split between daemon user and agent role.** Daemon user holds long-lived keys but its only permission is `sts:AssumeRole`. Role holds real S3+SES permissions and only hands them out as 1 h temp creds. Compromise of daemon keys bounds to "attacker can assume the role" — key rotation is one CLI call. Full trust chain: [`wiki/email-system.md` §"Architecture topology"](../wiki/email-system.md).

## 3. Start mock server (Terminal A — leave running)

```bash
cd ~/Projects/agentkeys
cargo run --release -p agentkeys-mock-server -- --port 8090
# → "Mock server running on port 8090"
```

## 4. Launch real Chrome with remote debugging (Terminal B — leave running)

Needed because Playwright-launched Chromium is blocked by Turnstile. The CDP path connects to a real Chrome:

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/agentkeys-chrome-profile
# Leave this window open. Chrome will show a blank page.
```

## 5. Initialize the master session (Terminal C)

Bring the env from step 2 into this terminal (or re-run step 2):

```bash
BIN=$(pwd)/target/release/agentkeys
BACKEND=http://127.0.0.1:8090

$BIN --backend $BACKEND init --mock-token stage6-demo
# → Initialized. Wallet: 0x...
```

## 6. Run the CDP scraper + capture the key (Terminal C)

The scraper drives the Chrome from step 4, fills the signup form, waits for Turnstile to resolve (you may need to click the checkbox if a visible challenge appears), polls S3 for the verification email, **handles whichever verification path Clerk is currently serving** (magic-link URL *or* legacy 6-digit OTP), mints a key, prints it on stdout. Magic-link path: the scraper extracts the verify URL from the email body, navigates the Chrome tab to it, and Clerk completes verification automatically — no manual click needed.

**Quick path — run the helper:**

```bash
cd ~/Projects/agentkeys
./scripts/stage6-demo-run.sh
```

The script refreshes `AGENTKEYS_SIGNUP_EMAIL` with a new timestamp, `cd`s into `provisioner-scripts/` (required — `tsx` lives there, not at repo root), runs the CDP scraper, and prints the extracted key. Log streams to `/tmp/cdp.log`; on failure it tails 25 lines automatically.

Capture the key for step 7:

```bash
KEY=$(./scripts/stage6-demo-run.sh | tail -1)
echo "extracted: ${KEY:0:12}****...${KEY: -4}"
```

Common failures (script + log will make them obvious):
- `env not loaded` → run `source scripts/stage6-demo-env.sh` first
- `ExpiredToken` in /tmp/cdp.log → your STS creds are >1h old; re-source the env script
- Scraper hangs on `waiting for Turnstile` >2 min → click the checkbox in the Chrome window from step 4
- `Cannot find package 'tsx'` → shouldn't happen with the helper, but means you bypassed it and ran from repo root

Expected `/tmp/cdp.log` tail — **magic-link flow** (current Clerk default):

```
[cdp] HH:MM:SS connecting to CDP at http://localhost:9222
[cdp] HH:MM:SS navigating to openrouter.ai/auth
[cdp] HH:MM:SS filling email = bot-<ts>@bots.litentry.org
[cdp] HH:MM:SS clicking Continue
[cdp] HH:MM:SS waiting for Turnstile + form to advance ...
[cdp] HH:MM:SS magic-link verification screen detected
[cdp] HH:MM:SS fetching verification link from email
[cdp] HH:MM:SS got verify URL: https://clerk...
[cdp] HH:MM:SS navigating current tab to verify URL
[cdp] HH:MM:SS waiting for redirect away from /sign-up
[cdp] HH:MM:SS navigating to /keys
[cdp] HH:MM:SS extracted key: sk-or-v1-xxxx****...WXYZ
```

If Clerk falls back to the legacy **6-digit OTP flow**, you'll see `OTP input appeared (legacy 6-digit flow)` → `fetching 6-digit OTP from email` → `got OTP: 123456` instead. The scraper auto-detects which mode Clerk is serving.

> **If it fails at "waiting for Turnstile..." for >2 min:** check the Chrome window — Turnstile may be showing a visible checkbox. Click it. If no checkbox and URL still `/sign-up`, Turnstile rejected the browser fingerprint. Try a fresh `/tmp/agentkeys-chrome-profile` dir in step 4.
>
> **If it fails at "fetching code":** check `aws s3 ls s3://$BUCKET/inbound/ --recursive` — is there a recent object dated within the last 60 seconds? If NO: DNS / MX / SES receipt-rule issue (re-verify via §2 of stage6-aws-setup.md). If YES: the ses-s3 backend may be timing out before the mail arrives (bump `timeoutMs` in openrouter-cdp.ts:121 — default 90s).

## 7. Store + verify the key

```bash
$BIN --backend $BACKEND store openrouter "$KEY"
# → stored

$BIN --backend $BACKEND read openrouter
# → sk-or-v1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx (your key)

curl -sS -H "Authorization: Bearer $($BIN --backend $BACKEND read openrouter)" \
  https://openrouter.ai/api/v1/models | head -c 200
# → {"data":[{"id":"...","name":"...",... — HTTP 200 with JSON body
```

All four acceptance criteria pass when this works:
1. ✅ `node ... openrouter-cdp.ts` exits 0 with a key on stdout
2. ✅ stdout key matches `sk-or-v1-[a-zA-Z0-9]+`
3. ✅ `agentkeys read openrouter` returns that same key
4. ✅ curl against `/api/v1/models` returns HTTP 200

## 8. (Optional) Re-run — fresh address each time

Because plus-aliases are unreliable on Clerk normalization, always re-evaluate `AGENTKEYS_SIGNUP_EMAIL` before each run:

```bash
KEY=$(./scripts/stage6-demo-run.sh | tail -1)
$BIN --backend $BACKEND store openrouter "$KEY" --force
```

The run script refreshes `AGENTKEYS_SIGNUP_EMAIL` every invocation. If STS creds expired (>1h since last `source`), re-source `scripts/stage6-demo-env.sh` first.

## Known limitations in this interim Stage 6 demo

- **`agentkeys provision openrouter` does NOT use the CDP path.** The CLI wraps `openrouter.ts` (headless Playwright, Turnstile-blocked). Stage 6 demo runs `openrouter-cdp.ts` directly and pipes the key into `agentkeys store`. Planned fix: add a `--cdp` flag or swap the wrapped script.
- **AWS creds must be assumed-role manually before each run.** The ses-s3 backend does not do AssumeRole internally. Fix (post-Stage 6): have the daemon do the AssumeRole itself, refresh on expiry.
- **`AMAZON_SES_SETUP_NOTIFICATION`** is polled each cycle; benign, just a wasted HEAD+GET.
- **Per-user isolation is app-side** — Stage 6 interim trusts the daemon to filter by `To:` header. Cloud-enforced isolation via OIDC PrincipalTag is Stage 7 ([`docs/stage7-wip.md`](./stage7-wip.md)).

## Teardown / cleanup

The 1 h temp creds in `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` auto-expire — no restore gymnastics needed. If you want to clear them now:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

To run admin commands (e.g. inspecting IAM policies), env-prefix with your stashed admin creds — same scoped pattern as §2:

```bash
AWS_ACCESS_KEY_ID="$ADMIN_AWS_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$ADMIN_AWS_ACCESS_KEY_SECRET" \
aws sts get-caller-identity
# Expected ARN: arn:aws:iam::429071895007:user/agentKeys-admin
```

Admin creds touch only the one subprocess; your shell never picks them up.

**Stop the long-running processes:**
- Terminal A: Ctrl+C the mock server.
- Terminal B: close Chrome.
- `rm -rf /tmp/agentkeys-chrome-profile /tmp/cdp.log`

**AWS infra teardown** (only if you're done with Stage 6 entirely): see `docs/stage6-aws-setup.md` §Cleanup. Don't run between demo iterations — re-run §2 for fresh temp creds instead.

## Cross-references

- [`docs/stage6-aws-setup.md`](./stage6-aws-setup.md) — operator runbook that stood up the AWS stack
- [`wiki/email-system.md`](../wiki/email-system.md) — high-level email architecture + scaling model
- [`docs/spec/ses-email-architecture.md`](./spec/ses-email-architecture.md) — engineering spec; §6.5 covers the same topology at depth
- [`docs/stage7-wip.md`](./stage7-wip.md) — future OIDC-federation variant (cloud-enforced isolation)
- [`provisioner-scripts/src/lib/email-backends/ses-s3.ts`](../provisioner-scripts/src/lib/email-backends/ses-s3.ts) — the S3-polling email backend
- [`provisioner-scripts/src/scrapers/openrouter-cdp.ts`](../provisioner-scripts/src/scrapers/openrouter-cdp.ts) — the CDP scraper this demo uses
