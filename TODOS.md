# TODOs

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
