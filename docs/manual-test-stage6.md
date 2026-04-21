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

## 2. Shell env setup — all four terminals need this

You manage two distinct AWS identities:

| Identity | Purpose | Env vars holding the keys |
|---|---|---|
| `agentKeys-admin` | The IAM user that built the AWS infra in `stage6-aws-setup.md`. Stays your default for any `aws ...` command outside the demo. | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` |
| `agentkeys-daemon` | The IAM user the daemon impersonates. Has only `sts:AssumeRole` on `agentkeys-agent`. | `DAEMON_ACCESS_KEY_ID` + `DAEMON_ACCESS_KEY_SECRET` |

> The AWS-standard env-var name for the secret half is `AWS_SECRET_ACCESS_KEY` — **not** `AWS_ACCESS_KEY_SECRET`. If your shell currently exports it as `AWS_ACCESS_KEY_SECRET`, the AWS CLI silently ignores it and falls back to `~/.aws/credentials` if any. Confirm with `env | grep AWS_` and rename if needed.

### 2a. Stage 6 setup vars (always-on)

```bash
export REGION=us-east-1
export DOMAIN=bots.litentry.org
export ACCOUNT_ID=429071895007
export BUCKET=agentkeys-mail-${ACCOUNT_ID}

export AGENTKEYS_EMAIL_BACKEND=ses-s3
export AGENTKEYS_SES_BUCKET="$BUCKET"

# Scraper signup identity — rotate per run so OpenRouter sees a fresh email.
export AGENTKEYS_SIGNUP_EMAIL="bot-$(date +%s)@${DOMAIN}"
export AGENTKEYS_SIGNUP_PASSWORD="Stg6-$(date +%s)-xZq9okFg"

# CDP endpoint (default for the command in step 6)
export CDP_URL="http://localhost:9222"
```

### 2b. Pre-flight: confirm admin creds work

Quick sanity check that `aws` is authenticated as `agentKeys-admin`:

```bash
aws sts get-caller-identity
# Expected:
# {
#   "UserId":  "AIDA...",
#   "Account": "429071895007",
#   "Arn":     "arn:aws:iam::429071895007:user/agentKeys-admin"
# }
```

If this fails or shows a different identity, fix your env (`echo $AWS_ACCESS_KEY_ID` should be the admin's, `echo $AWS_SECRET_ACCESS_KEY` non-empty).

### 2c. Switch to daemon creds + AssumeRole → 1h temp creds

The daemon user's policy is `sts:AssumeRole` ONLY. Without the AssumeRole step the `ses-s3` backend hits AccessDenied on every `ListObjects`. We swap admin creds for daemon creds just long enough to call `sts:AssumeRole`, then overwrite with the assumed-role temp creds the daemon will actually use.

```bash
# Save admin creds to a backup so we can restore later (§Cleanup).
ADMIN_AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
ADMIN_AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"

# Swap in daemon creds for the AssumeRole call
export AWS_ACCESS_KEY_ID="$DAEMON_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$DAEMON_ACCESS_KEY_SECRET"
unset AWS_SESSION_TOKEN  # clear any stale session token

# Confirm we're now the daemon user
aws sts get-caller-identity
# Expected ARN: arn:aws:iam::429071895007:user/agentkeys-daemon

# Assume the agentkeys-agent role
CREDS=$(aws sts assume-role \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-agent" \
  --role-session-name "stage6-demo-$(date +%s)")
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')

# Confirm we're now operating as the assumed role
aws sts get-caller-identity
# Expected ARN: arn:aws:sts::429071895007:assumed-role/agentkeys-agent/stage6-demo-<ts>

# Confirm the assumed role can actually read S3 (this is what the
# ses-s3 backend will do — if it works here, the demo will work):
aws s3 ls "s3://$BUCKET/inbound/" | head -3
# Expected: lists the bucket (may show AMAZON_SES_SETUP_NOTIFICATION
# + any past test mails). NO AccessDenied.
```

The temp creds in `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` are valid for 1 hour. If your demo run takes longer (it shouldn't — typical run is 1–3 minutes), re-run §2c to refresh.

> **Why split between daemon user and agent role.** The USER holds long-lived access keys; its only permission is `sts:AssumeRole`. The ROLE holds real S3+SES permissions and only hands them out as 1h temp creds. Compromise of the daemon's access keys bounds to "attacker can assume the role" — key rotation is one `aws iam create-access-key` + delete the old. See [`wiki/email-system.md` §"Architecture topology"](../wiki/email-system.md) for the full trust chain.

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

The scraper drives the Chrome from step 4, fills the signup form, waits for Turnstile to resolve (you may need to click the checkbox if a visible challenge appears), polls S3 for the verification email, enters the OTP, mints a key, prints it on stdout.

```bash
KEY=$(node --import tsx/esm provisioner-scripts/src/scrapers/openrouter-cdp.ts 2>/tmp/cdp.log | tail -1)
echo "extracted key: ${KEY:0:12}****...${KEY: -4}"
cat /tmp/cdp.log | tail -20   # progress log
```

Expected `/tmp/cdp.log` tail:

```
[cdp] HH:MM:SS connecting to CDP at http://localhost:9222
[cdp] HH:MM:SS navigating to openrouter.ai/auth
[cdp] HH:MM:SS filling email = bot-<ts>@bots.litentry.org
[cdp] HH:MM:SS clicking Continue
[cdp] HH:MM:SS waiting for Turnstile + form to advance ...
[cdp] HH:MM:SS OTP input appeared
[cdp] HH:MM:SS fetching code from Gmail IMAP          ← misnomer; with ses-s3 backend it polls S3
[cdp] HH:MM:SS got OTP: 123456
[cdp] HH:MM:SS navigating to /keys
[cdp] HH:MM:SS extracted key: sk-or-v1-xxxx****...WXYZ
```

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
export AGENTKEYS_SIGNUP_EMAIL="bot-$(date +%s)@${DOMAIN}"
export AGENTKEYS_SIGNUP_PASSWORD="Stg6-$(date +%s)-xZq9okFg"
KEY=$(node --import tsx/esm provisioner-scripts/src/scrapers/openrouter-cdp.ts 2>/tmp/cdp.log | tail -1)
$BIN --backend $BACKEND store openrouter "$KEY" --force
```

## Known limitations in this interim Stage 6 demo

- **`agentkeys provision openrouter` does NOT use the CDP path.** The CLI wraps `openrouter.ts` (headless Playwright, Turnstile-blocked). Stage 6 demo runs `openrouter-cdp.ts` directly and pipes the key into `agentkeys store`. Planned fix: add a `--cdp` flag or swap the wrapped script.
- **AWS creds must be assumed-role manually before each run.** The ses-s3 backend does not do AssumeRole internally. Fix (post-Stage 6): have the daemon do the AssumeRole itself, refresh on expiry.
- **`AMAZON_SES_SETUP_NOTIFICATION`** is polled each cycle; benign, just a wasted HEAD+GET.
- **Per-user isolation is app-side** — Stage 6 interim trusts the daemon to filter by `To:` header. Cloud-enforced isolation via OIDC PrincipalTag is Stage 7 ([`docs/stage7-wip.md`](./stage7-wip.md)).

## Teardown / cleanup

**Restore admin creds** so future `aws ...` commands work as `agentKeys-admin` again (otherwise your shell still has the assumed-role temp creds, which expire in 1h and have only S3+SES permissions):

```bash
export AWS_ACCESS_KEY_ID="$ADMIN_AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$ADMIN_AWS_SECRET_ACCESS_KEY"
unset AWS_SESSION_TOKEN

aws sts get-caller-identity
# Expected ARN back to: arn:aws:iam::429071895007:user/agentKeys-admin
```

**Stop the long-running processes:**

- Terminal A: Ctrl+C the mock server.
- Terminal B: close Chrome.
- `rm -rf /tmp/agentkeys-chrome-profile /tmp/cdp.log`

**AWS infra teardown** (only if you're done with Stage 6 entirely): see `docs/stage6-aws-setup.md` §Cleanup. Don't run this between demo iterations — re-running §2c above gives you fresh temp creds without rebuilding the infra.

## Cross-references

- [`docs/stage6-aws-setup.md`](./stage6-aws-setup.md) — operator runbook that stood up the AWS stack
- [`wiki/email-system.md`](../wiki/email-system.md) — high-level email architecture + scaling model
- [`docs/spec/ses-email-architecture.md`](./spec/ses-email-architecture.md) — engineering spec; §6.5 covers the same topology at depth
- [`docs/stage7-wip.md`](./stage7-wip.md) — future OIDC-federation variant (cloud-enforced isolation)
- [`provisioner-scripts/src/lib/email-backends/ses-s3.ts`](../provisioner-scripts/src/lib/email-backends/ses-s3.ts) — the S3-polling email backend
- [`provisioner-scripts/src/scrapers/openrouter-cdp.ts`](../provisioner-scripts/src/scrapers/openrouter-cdp.ts) — the CDP scraper this demo uses
