# Stage 6 Manual Test Guide

**Prerequisite:** Stage 6 SES stack deployed OR the Stage 6 mock equivalent running locally (see [`docs/spec/plans/development-stages.md`](./spec/plans/development-stages.md) §Stage 6). Rust toolchain installed, Node.js 20+.

> **Scope.** This guide covers Stage 6 — **Federated Own Email on `@agentkeys-email.io`**. It does NOT cover Stage 5b's CDP-scraper retest beyond the handoff section at the end — that's done per [`docs/manual-test-stage5.md`](./manual-test-stage5.md) §3 once the Stage 6 pieces this document covers are in place.

Stage 6 has two tests that matter:

1. **Throwaway inbox provisioning** — `agentkeys inbox provision` mints a fresh `<id>@agentkeys-email.io`, mail sent to it lands in the right S3 prefix, fetchable by the agent with correctly-tagged creds. This is what makes Stage 5b's live-demo re-run unblockable.
2. **Per-user isolation** — agent A cannot read agent B's mail. Enforced by `aws:PrincipalTag/agentkeys_user_wallet` on the shared `agentkeys-mail` bucket.

---

## 1. Preflight

```bash
# Rust + Node + provisioner deps built
cd ~/Projects/agentkeys
cargo build --workspace --release
npm install --prefix provisioner-scripts

# Backend (mock or real TEE endpoint)
BACKEND="${BACKEND:-http://127.0.0.1:8090}"
curl -sf "$BACKEND/health" >/dev/null || {
  echo "backend not up — run: cargo run --release -p agentkeys-mock-server -- --port 8090 &"
  exit 1
}

BIN=$(pwd)/target/release/agentkeys
$BIN --backend $BACKEND init --mock-token stage6-demo
```

**For the real SES path (not mock):** you also need:
- DNS for `agentkeys-email.io` published (MX, Ed25519 DKIM CNAMEs, SPF, DMARC) per `docs/spec/ses-email-architecture.md`
- S3 bucket `agentkeys-mail` with PrincipalTag-conditioned bucket policy
- IAM OIDC provider `oidc.agentkeys.dev` registered
- IAM role `agentkeys-agent` with trust policy on the OIDC provider + MRSIGNER pinning
- TEE reachable + `derive("dkim/agentkeys-email.io/v1")` and `derive("oidc/issuer/v1")` subkeys present

The mock equivalent stubs all of that to SQLite + a local HTTP server; both paths honor the same CLI surface.

---

## 2. The demo — provision a throwaway inbox + verify mail delivery

```bash
# Provision a fresh inbox (returns { address, agent_wallet })
$BIN --backend $BACKEND inbox provision --agent my-agent
# → e.g.: { "address": "bot-ax7kq@agentkeys-email.io", "agent_wallet": "0x..." }
```

Save the address:

```bash
INBOX=$(<output-from-above>)
echo "provisioned: $INBOX"
```

**Send a test message** from any external mail source (use your own Gmail, Mailgun sandbox, or a `curl` to your own SMTP test relay):

```bash
# Example via `mail` on macOS (requires a local SMTP configured)
echo "stage-6 test body" | mail -s "stage-6-$RANDOM" "$INBOX"
```

Or send from a real service's signup form if you want to validate end-to-end (e.g. paste `$INBOX` into the signup form at a simpler service and trigger a verification email).

**Read the mail** — Claude drives the daemon:

```bash
$BIN --backend $BACKEND run my-agent -- \
  claude-mcp-client email.list 2>&1 | jq
# → shows the test message + its body

$BIN --backend $BACKEND run my-agent -- \
  claude-mcp-client email.get --id <msg-id-from-above>
# → full MIME + parsed body
```

### Expected behavior

1. `inbox provision` exits 0 and returns a JSON object with a `.address` matching `^bot-[a-z0-9]{6}@agentkeys-email.io$` (or whatever shape §Stage 6 commits to; acceptance is "distinct local-part per call, no plus-aliases").
2. `email.list` from the agent returns a non-empty array within ≤30s of the test message being sent. The item's `to` field matches `$INBOX`.
3. The raw MIME in `s3://agentkeys-mail/<agent_wallet>/<inbox_address>/*.eml` is present — verify with `aws s3 ls --profile agentkeys` or whatever read mechanism your deployment uses.
4. An on-chain audit extrinsic `CredentialMinted` was emitted for the `s3.read` mint that serviced `email.list`.

### Failure modes to watch for

- **`inbox provision` 400 / "domain not verified"** — SES identity for `agentkeys-email.io` is not verified in this AWS account. Run `aws sesv2 get-email-identity --email-identity agentkeys-email.io`; if the DKIM / Identity records aren't `PENDING` → `SUCCESS`, publish DNS or re-trigger verification.
- **Mail never appears in S3** — DNS MX record not pointing at `inbound-smtp.us-east-1.amazonaws.com`, OR the SES receipt rule isn't active, OR the S3 bucket's bucket policy denies SES write. `aws logs tail /aws/ses/<rule-set>` to debug.
- **`email.list` returns AccessDenied** — the agent's minted JWT didn't carry `agentkeys_user_wallet` as a session tag, OR bucket policy's `${aws:PrincipalTag/agentkeys_user_wallet}` condition didn't match. Inspect the temp-cred claims via `aws sts get-caller-identity --profile <temp>`.
- **DKIM fails at recipient** — the outbound-path test. Send a message from your agent to a real Gmail inbox; if it lands in Spam with "DKIM: fail", either (a) the Ed25519 DKIM key at `derive("dkim/agentkeys-email.io/v1")` doesn't match what's published in DNS, or (b) the DKIM header isn't being added before SES hands the MIME to the outbound MTA.

---

## 3. Per-user isolation test

```bash
# Provision a second agent + inbox
$BIN --backend $BACKEND inbox provision --agent other-agent
OTHER_WALLET=$(... extract the wallet from the previous output)

# First agent attempts to read second agent's inbox prefix — must fail
$BIN --backend $BACKEND run my-agent -- \
  claude-mcp-client email.list --agent "$OTHER_WALLET" 2>&1
# → AccessDenied OR "DENIED session does not own agent"
```

**Expected:** the cross-agent read is refused at either our backend (ownership check) or at AWS's bucket policy (`${aws:PrincipalTag/agentkeys_user_wallet}` mismatch). Either layer is sufficient; both firing is belt-and-suspenders.

---

## 4. Stage 5b live-demo re-run (the payoff)

With Stage 6's throwaway-inbox API in place, Stage 5b's blocker from [`docs/manual-test-stage5.md`](./manual-test-stage5.md) §4 is resolved.

Procedure:

```bash
# 1. Provision a throwaway inbox for this signup
INBOX=$($BIN --backend $BACKEND inbox provision --agent stage5b-retest --json | jq -r .address)
echo "signup email: $INBOX"

# 2. Export it as the signup target for the CDP scraper
export AGENTKEYS_SIGNUP_EMAIL="$INBOX"
export AGENTKEYS_SIGNUP_PASSWORD="Stage5b-$(date +%s)-xZq9!okFg"

# 3. Point the OTP fetcher at Stage 6's SES-S3 reader (not Gmail IMAP)
export AGENTKEYS_EMAIL_BACKEND=ses-s3   # new value, see provisioner-scripts/src/lib/email.ts
# (ses-s3 backend infers wallet + address from AGENTKEYS_SIGNUP_EMAIL and reads S3 directly)

# 4. Launch real Chrome with CDP (same as Stage 5b)
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/agentkeys-chrome-profile &

# 5. Run the CDP scraper
cd provisioner-scripts
node --import tsx/esm src/scrapers/openrouter-cdp.ts

# 6. Store + verify
$BIN --backend $BACKEND store openrouter "<KEY-FROM-STDOUT>"
$BIN --backend $BACKEND read openrouter
curl -sS -H "Authorization: Bearer $($BIN --backend $BACKEND read openrouter)" \
  https://openrouter.ai/api/v1/models | head -c 40
# → expect "{\"data\":["
```

All four Stage 5a live-demo acceptance criteria should pass. If any step fails, check [`docs/manual-test-stage5.md`](./manual-test-stage5.md) §Failure modes first.

---

## 5. What this does NOT cover (post-Stage 6)

- **BYO custom domain** — `bots.theircompany.com` for enterprise users. Deferred per Stage 7+.
- **BYO Workspace DWD** — the advanced `docs/stage5-workspace-email-setup.md` runbook remains valid for Workspace customers but is never the default path.
- **Email drafts as HITL primitive** — daemon-side, per the broker-not-proxy thesis. Not Stage 6 scope.
- **Labels / threads / search** — implemented daemon-side (MCP); not server features. Per [`wiki/email-system.md`](../wiki/email-system.md).

---

## Summary checklist

- [ ] §2 demo passes: throwaway inbox provisioned, inbound mail received, agent reads it
- [ ] §3 isolation test passes: cross-agent read denied
- [ ] §4 Stage 5b re-run passes: `sk-or-v1-*` minted end-to-end with a Stage-6-provisioned inbox
- [ ] DKIM verified by a real recipient (Gmail / Outlook / Fastmail)
- [ ] Audit trail on chain: `agentkeys usage <agent> --filter email` shows the expected mint events

## References

- [`docs/spec/plans/development-stages.md`](./spec/plans/development-stages.md) §Stage 6 — deliverables + tests
- [`docs/spec/ses-email-architecture.md`](./spec/ses-email-architecture.md) — SES architecture spec
- [`wiki/email-system.md`](../wiki/email-system.md) — high-level email system overview
- [`wiki/hosted-first.md`](../wiki/hosted-first.md) — why `@agentkeys-email.io` is the default
- [`wiki/tag-based-access.md`](../wiki/tag-based-access.md) — PrincipalTag mechanism
- [`docs/manual-test-stage5.md`](./manual-test-stage5.md) — Stage 5a + 5b guide (live demo unblocked by this stage)
