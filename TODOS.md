# TODOs

## Open architectural follow-ups

### SES Lambda for per-recipient inbound routing (issue #83 follow-up)

Today every SES-delivered email lands in `s3://$BUCKET/inbound/<msg>`, and
**only the broker instance profile + `agentkeys-admin` can read it.** The
OIDC-assumed `agentkeys-data-role` is intentionally denied read on
`inbound/` (see cloud-setup.md §4.5 — federation-isolation rule). That
means the daemon-side auto-provision flow (CDP scraper spawned by
`agentkeys provision <service>`) cannot fetch its own service-signup
verification email from `inbound/` using the OIDC workflow that §5.1
demonstrates.

The architectural fix the team agreed on (2026-05-15): an SES post-receive
Lambda that copies `inbound/<msg>` → `bots/<wallet>/inbound/<msg>` based
on the recipient's local-part for service-provisioning emails (matching
the `^or-0x[a-fA-F0-9]{40}-\d+` pattern; AGENTKEYS-auth magic-links stay
in `inbound/` for the existing broker handlers). Then the existing
PrincipalTag-scoped bucket policy lets the operator's data-role read
**only their own** routed emails — the §5.1 OIDC workflow becomes
sufficient with zero changes to the federation-isolation model.

Implementation outline:
- `infra/ses-routing-lambda/handler.py` — boto3 + Python email-parser;
  triggered by S3 EventBridge on `s3:ObjectCreated:*` over `inbound/`;
  uses `GetObject` with `Range: bytes=0-2047` to parse headers,
  `CopyObject` (server-side, body never transits Lambda memory) to
  destination, optional `DeleteObject` on source.
- `infra/ses-routing-lambda/deploy.sh` — idempotent: creates the IAM
  role + Lambda function + S3 EventBridge notification.
- Update `provisioner-scripts/src/lib/email-backends/ses-s3.ts` to poll
  `bots/${WALLET}/inbound/` (per-wallet prefix) instead of `inbound/`.
- Update `provisioner-scripts/src/scrapers/openrouter-cdp.ts` to pass
  the assumed-role's wallet (derived from JWT claim
  `agentkeys.wallet_address`) so the email backend knows which prefix
  to poll.
- Update `scripts/agentkeys-provision-demo.sh` to format the signup
  email as `or-${wallet}-${ts}@bots.litentry.org`.
- Update `docs/cloud-setup.md` with a new §2.4 documenting the Lambda
  deployment.
- Update `docs/stage7-demo-and-verification.md` §5.3 to reflect the new
  flow.

Until this lands, `agentkeys provision openrouter` against live
`broker.litentry.org` can't complete end-to-end via the OIDC path. The
existing `openrouter.ts` (non-CDP) scraper is also blocked by the same
gap (it relies on `lib/email.ts` which routes to `ses-s3.ts`).
Operators can run `openrouter-cdp.ts` manually using
`AGENTKEYS_EMAIL_BACKEND=gmail` + a Gmail account that doesn't collide
with Clerk's plus-alias-reuse rejection — but that's not the
production-aligned path.

### Deprecate `agentkeys-mock-server` `/credential/*` — replace with S3 + OIDC + client-side AES-GCM

Draft issue body lives at [`docs/spec/plans/issue-credential-storage-s3-oidc.md`](docs/spec/plans/issue-credential-storage-s3-oidc.md). File on the GitHub repo with:

```bash
gh issue create --repo litentry/agentKeys \
  --title "Replace mock-server /credential/* with S3-backed encrypted storage (OIDC-scoped, PrincipalTag-isolated)" \
  --label "stage-7+,architecture,credential-storage" \
  --body-file docs/spec/plans/issue-credential-storage-s3-oidc.md
```

Architecture rationale, wire contract sketch, IAM-delta scope, and 6-step migration plan all in the draft. Reuses the SES Lambda's PrincipalTag-isolated bucket + the §5.1 OIDC workflow — zero new deployable artifacts. Forced by the post-issue-#83 storage failure: provision now succeeds through key mint but the legacy backend at `:8090` (loopback-only per [arch.md §11](docs/spec/architecture.md#L670)) is unreachable from the operator workstation.

### Disable broker's broad S3-full-access (future, after the SES Lambda lands)

The broker's EC2 instance profile currently has broad S3 read on the
mail bucket (intentional today — broker reads `inbound/` for the
AGENTKEYS magic-link auth flow). Once the SES routing Lambda above is
deployed, the broker no longer needs to read every operator's
service-provisioning email. Plan to tighten the broker's instance
profile to:
- `s3:ListBucket` + `s3:GetObject` on `inbound/*` (still required for
  the agentkeys magic-link `/v1/auth/email/{request,verify}` flow that
  consumes operator-signup emails)
- **Remove** any broader S3 read grants if present.
- Add a deny statement on `bots/*/inbound/*` so the broker explicitly
  cannot read service-provisioning emails — the operator's OIDC-assumed
  role is the only principal that should read those.

This is purely defense-in-depth: today the broker COULD read service
emails but doesn't (the new use of the SES Lambda routes them away
from broker-readable paths). The deny statement converts "won't read"
to "can't read."

## Deferred to v0.2 / v0.1+

### Twitter (X) scripted signup

Scripted account creation on X violates their developer terms and practically
requires phone verification + CAPTCHA solving. Not viable in the provisioner's
current form. Re-evaluate in v0.2 if any of the following land:
- An official developer API for account creation
- A different product angle where users bring existing X accounts and
  AgentKeys only stores API credentials (not signup)
- A residential-proxy-browser setup (Browserbase etc.) with explicit legal
  sign-off

Until then, `/agentkeys-record-scraper` will stop on CAPTCHA and flag this
service as unsupported.

### Instagram (Meta) scripted signup

Same story as Twitter, worse. Meta actively pursues bot accounts with device
fingerprinting + phone verification. Dropped entirely from the Phase C target
list per 2026-04-16 decision. No v0.2 plan to revisit unless the product
pivots in a way that makes Instagram credentials load-bearing.

### OpenRouter ToS compliance check

Per 2026-04-16 CEO review, confirm scripted account creation does not violate
OpenRouter's ToS before the first live Stage 5a provision. Repeat this check
for every new service added to Tier 2. Flag noted in Stage 5a "open item to
resolve before first live provision" section.

## Phase C — new scrapers to add after Stage 5a ships

Once Stage 5a ships (infrastructure + OpenRouter reference scraper), add the
following services via `/agentkeys-record-scraper` in sequence:

1. **Brave Search** — dev API, reasonable signup, verifiable key
2. **Jina Search** — dev API, minimal friction
3. **Anthropic** — replaces Twitter in the target list; dev-focused, standard OAuth + email
4. **Groq** — dev-focused API, fast signup
5. **Gemini (Google AI Studio)** — replaces Instagram in the target list; Google OAuth

Each session produces: a `scrapers/<slug>.ts` composing patterns, a HAR fixture,
a unit test, and possibly a new pattern extraction if the signup shape is not
yet in the library. See `~/.claude/skills/agentkeys-record-scraper/SKILL.md` for
the full workflow.

**Expected pattern extractions during Phase C:**
- `oauth_google.ts` — likely from Gemini (Google AI Studio uses Google OAuth)
- Additional archetypes if Anthropic or Groq surface non-email-OTP flows

## v0.1 milestone deliverables (named, to prevent drift)

Per 2026-04-16 CEO review, the following must ship as part of a named v0.1
milestone. Filing as TODOs to prevent "post-MVP" from becoming "never":

- Stage 5b: agentic fallback + audit trail + fallback→PR + `/agentkeys-record-scraper` skill usage
- Stage 6: npm package + install.sh + README polish + DX docs
- Stage 8: production hardening (daemon memory hygiene + CLI defensive features)
- Pattern 4 (Heima) audit submission infrastructure — see docs/spec/plans/development-stages.md Stage 9
