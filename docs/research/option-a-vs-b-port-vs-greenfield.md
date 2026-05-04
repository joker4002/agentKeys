# Decision: Port dexs-backend vs. greenfield AgentKeys broker

## Context

User framing (paraphrased): *"Should I port dexs-backend's auth code into agentkeys-broker, or build a broker designed from scratch around AgentKeys' concepts? dexs-backend is sunk cost — don't let it constrain us. Compare both."*

This is a strategic decision, not a tactical one. It shapes what AgentKeys *is* — a battle-tested clone of an existing exchange backend, or a credential-broker designed for the agent-bootstrap problem domain. The decision drives 6+ months of architecture.

Both options share the same upstream dependency: a Heima TEE worker that AgentKeys talks to for crypto/identity primitives. Both assume Litentry adds multi-tenant support to the TEE worker (Phase 0 of the prior plan). The TEE worker is a fixed point; the only variable is how AgentKeys' broker is shaped between the user/CLI and the TEE.

## TL;DR

| | **Option A — Port dexs-backend** | **Option B — Greenfield** |
|---|---|---|
| Source of truth for design | dexs-backend's account / gateway / pumpx_api Go code | AgentKeys' agent-credential-broker problem domain + heima-cli-exploration.md design moves |
| Compat with existing wildmeta deployment | Full | None (separate tenant + separate data model) |
| Path-dependence | High (we inherit dexs-backend's shapes, naming, password+TOTP, HS256 JWT, user_id-INT identity model) | Low (data model designed around master↔daemon, OmniAccount-first, capability grants, TEE-RSA JWTs only) |
| Calendar to v1 | 8–13 weeks (6 phases) | 12–18 weeks (8 phases — adds design + crypto-review weeks) |
| Engineering risk | Lower (battle-tested semantics) | Higher (new auth design surface) |
| Architectural ceiling | Bound by dexs-backend's 2020-era assumptions | Bound only by what we choose to build |
| Future-proofing for agent-attestation (DCAP) | Bolted-on | First-class data model |
| Long-term maintenance burden | Higher (we own a Rust port of evolving Go code) | Lower (we own only what we built) |

**Headline trade-off:** A buys speed-to-shipping at the cost of architectural ceiling. B buys ceiling at the cost of 4–5 extra weeks calendar + meaningfully higher early-stage risk.

## Option A — Port dexs-backend (the saved plan in `regarding-docs-dev-setup-md-http-dev-set-fuzzy-sphinx.md`)

### Architecture

```
agentkeys CLI
    │  (HTTP, POST /v1/session/wallet_login etc.)
    ▼
agentkeys-broker (Rust port of dexs-backend's pattern)
    │
    ├─ wallet_login   ←  port walletloginlogic.go
    ├─ email_login    ←  port emailloginlogic.go (bcrypt + TOTP)
    ├─ google_oauth   ←  port googleoauthcallbacklogic.go
    ├─ passkey        ←  proxy to TEE
    │
    ├─ post_heima_login (callback)
    ├─ add_wallet (callback)
    ├─ get_account_user_id (callback)
    │
    └─ jsonrpsee → dex-api.heima.network
```

Storage shape mirrors dexs-backend's `user_account_info` table: `id INT AUTOINCREMENT PRIMARY KEY`, `user_login_address`, `email`, `password_hash`, `is_2fa_bound`, `omni_account` as a derived field, etc.

JWTs are HS256 signed with a backend secret. TEE-RSA JWTs are *also* fetched from TEE worker for downstream identity but our gateway issues its own.

### What we inherit from dexs-backend (good and bad)

**Good:**
- Battle-tested EIP-191 wallet-sig flow (`crypto.Keccak256Hash` + ecrecover, 45-min timestamp window).
- Email + verification-code flow with TTL.
- Google OAuth code-exchange dance.
- Pumpx callback URL conventions that the TEE worker already speaks.
- Known crypto choices that have run in production for some time.

**Bad (the sunk-cost baggage):**
- `id INT AUTOINCREMENT` user primary key — Web2-shaped, not OmniAccount-first. Every cross-reference is `user_id INT`, not `omni_account TEXT`. Refactoring later is painful.
- Email + password + Google-2FA-TOTP — the password gets bcrypted + TOTP secret stored AES-encrypted at rest. This is a 2014 crypto-onboarding pattern that AgentKeys doesn't need to support if we never expose `email + password` UX to begin with.
- HS256 JWT with backend secret — strictly weaker than the TEE-RSA JWT the TEE worker already mints. Two parallel JWT issuers means two attack surfaces and inconsistent revocation paths.
- URL paths frozen as `/v3/account/post_heima_login`, `/v5/account/get_user_address_info` — dexs-backend's versioning history, not ours. We'd inherit confusing legacy.
- `pumpx_api` naming throughout the TEE worker — internal terminology we adopt.
- Trade-flow assumptions baked in — `is_anti_mev`, `slippage`, `gas_type_eth/sol/trx/bsc`, `is_fast_trade`, `wallet_groups`, `jpush_register_id` (push notifications) — all of these ride along on the user record because dexs-backend is a trading exchange. AgentKeys doesn't need any of them. Either we strip them and break parity, or we keep them and carry weight.
- `invite_code` field, beta-test flag, language preferences — dexs-backend's user-acquisition machinery, irrelevant for AgentKeys.
- `master_wallet ↔ daemon_wallet` capability binding — there is no equivalent in dexs-backend. We bolt it onto `check_hyper_agent_address` (a wildmeta-trading endpoint named for hyperliquid agent wallets), rebadging the semantic. The mismatch will leak into the docs forever.

### Calendar

8–13 weeks per the saved plan (6 phases). Phase 0 (Litentry patch) is small — just adds `CLIENT_ID_AGENTKEYS` to the existing single-tenant constant.

### Risk profile

- **Implementation risk: low.** The Go code we're porting has been running in wildmeta production. Rust port matches it line-for-line.
- **Crypto risk: low.** EIP-191 ecrecover, k256, HS256 JWT — standard primitives.
- **Architectural risk: high.** We inherit decisions made for an exchange, not for a credential broker. Future PRs that reshape the user model into "OmniAccount-first" or "capability-graph-first" will be 6-month refactors instead of a clean greenfield.
- **Migration risk: low.** No existing AgentKeys users to migrate.

---

## Option B — Greenfield AgentKeys broker

### Architecture

```
agentkeys CLI
    │  (HTTP, POST /v1/auth/{wallet,passkey,oauth,email}/{start,complete} etc.)
    ▼
agentkeys-broker (Rust, designed from problem domain)
    │
    ├─ auth/
    │   ├─ wallet_sig          ← EIP-191 + sr25519 + Solana ed25519 (capability-driven)
    │   ├─ passkey             ← WebAuthn, primary path for end users
    │   ├─ oauth               ← Google, Apple, GitHub (capability-driven)
    │   └─ email_link          ← passwordless magic link (NO password, NO TOTP)
    │
    ├─ identity/
    │   ├─ omni_account        ← OmniAccount IS the primary key, no INT
    │   ├─ master_wallet       ← user-owned long-lived identity
    │   └─ daemon_wallet       ← scoped child issued by master
    │
    ├─ capability/             ← first-class concept, not bolted-on
    │   ├─ grant               ← (master, daemon, scope, expires_at, max_uses)
    │   ├─ revoke              ← instant, audit-anchored
    │   └─ verify              ← per-call check
    │
    ├─ tee_callbacks/          ← whatever surface the TEE worker actually needs
    │   ├─ on_user_login       ← record OmniAccount → wallet binding
    │   └─ on_wallet_attach    ← record (omni_account, wallet_index, address)
    │
    └─ jsonrpsee → dex-api.heima.network
```

JWTs are TEE-RSA only. The broker doesn't issue HS256; it relays the TEE's RSA-signed token. There's exactly one source of truth for authentication.

Storage shape designed for the actual problem:

```sql
CREATE TABLE accounts (
  omni_account     TEXT PRIMARY KEY,           -- the identity, no INT
  primary_identity_type  TEXT NOT NULL,
  primary_identity_value TEXT NOT NULL,
  created_at       INTEGER NOT NULL,
  -- no email, no password, no 2fa, no slippage, no gas preferences
  UNIQUE (primary_identity_type, primary_identity_value)
);

CREATE TABLE wallets (
  omni_account     TEXT NOT NULL REFERENCES accounts(omni_account),
  wallet_index     INTEGER NOT NULL,
  address          TEXT NOT NULL,
  role             TEXT NOT NULL,             -- 'master' | 'daemon'
  parent_index     INTEGER,                   -- daemon's master wallet_index
  PRIMARY KEY (omni_account, wallet_index)
);

CREATE TABLE grants (
  id               TEXT PRIMARY KEY,          -- ULID, externally addressable
  master_wallet    TEXT NOT NULL,
  daemon_wallet    TEXT NOT NULL,
  scope            TEXT NOT NULL,             -- JSON, capability list
  granted_at       INTEGER NOT NULL,
  expires_at       INTEGER NOT NULL,
  max_uses         INTEGER,
  used_count       INTEGER NOT NULL DEFAULT 0,
  revoked_at       INTEGER,
  audit_proof      BLOB                       -- TEE-RSA signature over the grant content
);

CREATE TABLE auth_attempts (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at      INTEGER NOT NULL,
  method           TEXT NOT NULL,             -- 'wallet' | 'passkey' | 'oauth' | 'email_link'
  identity_value   TEXT NOT NULL,
  outcome          TEXT NOT NULL,             -- 'ok' | 'invalid_sig' | 'expired' | ...
  rate_limit_bucket TEXT
);
```

No `user_login_address`, no `slippage`, no `is_fast_trade`. The schema models exactly what AgentKeys needs.

### What we design from scratch

- **Identity primitive: OmniAccount.** Not "a user with an integer ID who happens to have an OmniAccount." OmniAccount IS the user. Every foreign key is `omni_account TEXT`. This matches Heima's actual model rather than imposing a Web2 shape over it.

- **Auth methods: passwordless only.** Wallet-sig, passkey, OAuth (Google/Apple/GitHub), and email magic-link. **No password + TOTP path.** Drop bcrypt and the AES-encrypted-at-rest TOTP secret. The crypto-native end-user audience doesn't want passwords; the agent-bootstrap audience doesn't want them either.

- **JWTs: TEE-RSA only.** The broker never issues its own HS256 token. Every authenticated session is a TEE-RSA JWT issued by `omni_userLogin`. One issuer, one verify path, one revocation primitive.

- **Capability grants as first-class data.** Master grants daemon a scope (e.g., "read openrouter credentials, mint AWS creds for S3 prefix bots/0xabc/, expires 2026-08-01, max 1000 uses"). The broker enforces. The grant has a TEE-RSA signature attached so it's tamper-evident even if the SQLite DB is leaked. Revocation is one row update; instant. This is the heima-cli-exploration §2 design move ("ACL as a first-class on-chain object with TTL and rate limits") brought into AgentKeys' broker layer instead of the chain layer (cheaper, faster, still tamper-evident via TEE-RSA signature).

- **URL paths designed around our concepts.** No `/v3/account/post_heima_login` — that's a wildmeta versioning artifact. We have `/v1/auth/{wallet,passkey,oauth,email_link}/{start,complete}`, `/v1/grant/{create,revoke,list}`, `/v1/identity/me`, etc. Clean, versioned to AgentKeys' lifecycle.

- **Hook points for agent-attestation (DCAP) ready from day 1.** When `pallet-teebag` integration lands, the data model already accommodates "this grant was issued to a TEE-attested ephemeral session keypair (MRENCLAVE 0xdef…, ephemeral_pubkey 0xabc…)." Option A would have to refactor the user model to fit; Option B has the slot waiting.

- **Per-call cryptographic provenance.** Each AWS-cred mint or OIDC-JWT mint takes a daemon's session signature over the request payload (timestamp + capability invocation), broker verifies before forwarding to STS. The audit log records the signature, not just metadata. Heima-cli-exploration §4 design move.

### What we DON'T port from dexs-backend

- `email + password + bcrypt + Google-2FA-TOTP` — passwordless instead.
- `user_id INT` primary key model.
- HS256 JWT issuance — TEE-RSA only.
- All trading-specific user fields (slippage, gas types, MEV settings, push registration IDs).
- `invite_code` + beta-test flag.
- Pumpx-named URL conventions.
- `check_hyper_agent_address` semantics — replaced by AgentKeys-native `/v1/grant/verify`.

We do reuse dexs-backend's reference for crypto correctness:
- The exact EIP-191 message format (`"\x19Ethereum Signed Message:\n%d%s"`) and ecrecover code path — small, mechanical, well-tested in their Go.
- The 45-minute timestamp anti-replay window for wallet-sig.
- The OmniAccount derivation function (`SHA256(client_id || identity_type || identity_value)`).

These are crypto primitives, not architecture. Porting them is fine; building around them is greenfield.

### Calendar

8 phases, ~12–18 weeks for one engineer. Extra time vs Option A goes to:

- **Phase −1 — design + crypto review** (2–3 weeks). Sketch the URL surface, the capability-grant data model, the TEE-RSA-only JWT flow. Get a security review of the design before any Rust lands. Prevents "shipped a subtle bug that took 6 months to find."
- **Phase 0 — upstream patch** (Litentry waiting, same as Option A).
- **Phase 1 — identity + storage** (1 week). Schema, migrations, OmniAccount derivation, master/daemon wallet model.
- **Phase 2 — auth methods** (3 weeks). Wallet-sig, passkey (proxy to TEE), OAuth, email-link. Each is smaller than Option A's port because we're not carrying baggage.
- **Phase 3 — capability grants** (2 weeks). Grant create/revoke/verify, TEE-RSA signatures over grants, audit anchoring.
- **Phase 4 — TEE worker integration** (1 week). jsonrpsee client, RSA pubkey caching, callback endpoints (whatever shape the TEE actually requires — likely fewer than Option A's port since we're not implementing the full pumpx_api surface).
- **Phase 5 — CLI rewrite around the new endpoints** (1–2 weeks). `agentkeys init wallet|passkey|oauth|email_link`. Drop the legacy `--mock-token` path entirely.
- **Phase 6 — hardening + monitoring** (2 weeks).
- **Phase 7 — docs + retire mock-server** (1 week).

### Risk profile

- **Implementation risk: medium.** New auth design surface; security review is mandatory.
- **Crypto risk: medium.** Reusing the same primitives as Option A but composing them differently. Email-link in particular needs careful design (we'd be inventing an AgentKeys variant rather than copying dexs-backend's email+code).
- **Architectural risk: low.** Designed around AgentKeys' problem; no inherited assumptions to refactor.
- **Migration risk: zero.** No existing users.
- **Schedule risk: medium.** Greenfield projects slip; budget contingency.

---

## Side-by-side comparison

### Identity model

| | A (port) | B (greenfield) |
|---|---|---|
| Primary key | `user_id INT AUTOINCREMENT` | `omni_account TEXT` (32-byte hex) |
| `email` field on user | First-class column | Not on `accounts`; stored as a row in `identities` if email-link is used |
| Wallet representation | `user_login_address TEXT` on user + `wallets` table | `wallets` table only, with `role IN ('master','daemon')` and `parent_index` for daemon→master link |
| Trading fields (slippage, gas, MEV) | Inherited; have to either keep or strip | Never exist |
| Foreign key from grants/audit | `user_id INT` | `omni_account TEXT` |

### Auth methods

| | A (port) | B (greenfield) |
|---|---|---|
| Wallet-sig | EIP-191 ecrecover (port) | EIP-191 ecrecover (port) |
| Email login | Email + password + optional TOTP | Email magic-link (passwordless) |
| Google OAuth | Code exchange + userinfo fetch (port) | Code exchange + userinfo fetch (designed) |
| Passkey | WebAuthn (TEE-proxied) | WebAuthn (TEE-proxied) — and primary recommended path |
| Apple, GitHub | Not in dexs-backend | Designed in from day 1 |
| TOTP 2FA | Bcrypt password + AES-encrypted TOTP secret in DB | Not present (passkey replaces) |

### JWT model

| | A (port) | B (greenfield) |
|---|---|---|
| Issuance | Broker issues HS256 + TEE issues RSA in parallel | Only TEE-RSA |
| Verification | HS256 secret comparison + RSA pubkey verify | RSA pubkey verify only |
| Revocation | Manual (rotate HS256 secret breaks everyone) + TEE-side revoke | TEE-side revoke is the only path |
| Refresh | Two paths to keep in sync | One path |
| Audit clarity | Two issuers in audit log | One |

### Capability / grant model

| | A (port) | B (greenfield) |
|---|---|---|
| Master grants daemon scope | Bolted onto `check_hyper_agent_address` (named for hyperliquid trading) | First-class `grants` table with TTL, max_uses, scope JSON, TEE-RSA signature |
| Revocation latency | Manual lookup against `is_bound` | One row update, audit-anchored |
| Per-call signing | Not present in dexs-backend | Designed in: each broker call carries a daemon-signed payload that the broker verifies against the active grant |
| Cross-protocol grantee identity | Limited to wildmeta's wallet model | Heima's `Identity` enum (Substrate / EVM / BTC / Solana / Twitter / GitHub / Google / Email) — heima-cli-exploration §5 |

### Endpoint shape

| | A (port) | B (greenfield) |
|---|---|---|
| Login | `POST /v3/account/wallet_login`, `POST /v3/account/email_login`, etc. | `POST /v1/auth/wallet/start` + `/complete`, etc. |
| Versioning | dexs-backend's history (v3, v4, v5) | AgentKeys' lifecycle |
| Naming | "account", "user_id", "main_address", "agent_address" | "account", "omni_account", "master_wallet", "daemon_wallet" |
| Doc surface | We have to explain wildmeta-isms in our docs | Self-consistent |

### TEE-worker patch surface (Phase 0 in both)

| | A (port) | B (greenfield) |
|---|---|---|
| New constant | `CLIENT_ID_AGENTKEYS` | `CLIENT_ID_AGENTKEYS` |
| RpcContext additions | `agentkeys_api: PumpxApiClient` (same shape) + `agentkeys_backend_ecdsa_pubkey` | `agentkeys_api: AgentKeysApiClient` (different shape — broker's endpoints not pumpx's) + `agentkeys_backend_ecdsa_pubkey` |
| user_login.rs branch | Trivial (clone `if WILDMETA` block) | Slightly more work — TEE callback shape differs since AgentKeys doesn't have `pumpx_api.post_heima_login` exactly; needs a small refactor of `oe_client_pumpx::methods` to accommodate a parallel `oe_client_agentkeys::methods` |
| Litentry's review burden | Lower (looks like a wildmeta clone) | Slightly higher (introduces a new client shape) |

The Phase 0 patch is somewhat bigger in B, but still small (~400 LOC vs ~250 LOC). Either way the patch is a few-day exercise, not weeks.

### Total LOC estimate

| | A (port) | B (greenfield) |
|---|---|---|
| Core broker | ~5500 LOC (mirrors dexs-backend's account+gateway surface) | ~3500 LOC (smaller because we drop password/TOTP/trading fields) |
| Capability layer | ~500 LOC (bolt-on) | ~1200 LOC (first-class, with TEE-RSA signing) |
| TEE client | ~600 | ~600 |
| CLI | ~800 | ~700 |
| Tests | ~2000 | ~2000 |
| Docs | ~600 | ~800 (more, because everything is new — needs explanation) |
| **Total** | **~10,000 LOC** | **~8,800 LOC** |

Counter-intuitive but real: B is *less* total code despite being more design work, because we don't inherit the trading-specific bloat from dexs-backend's user model.

---

## Risks specific to each option

### Option A risks

1. **Architectural ceiling.** Every future feature is constrained by dexs-backend's data model. Adding agent-attestation cleanly requires refactoring the user model. Adding cross-protocol identity grants requires the same. We end up paying the design cost later, with the additional cost of a migration.

2. **Doc surface bleed.** Our public docs reference `/v3/account/post_heima_login` and "main_address / agent_address." Every dev who reads our docs has to learn wildmeta's terminology. Confusing for end users; awkward for partner integrations.

3. **Crypto monoculture risk.** HS256 JWT with a backend secret is the most-attacked JWT pattern. We inherit a JWT issuer that's strictly weaker than the TEE-RSA one we're forced to also use. If the HS256 secret leaks, every session ever issued is forgeable forever.

4. **Two-way technical debt.** Future dexs-backend changes (wildmeta evolves) drift from our port. We either re-port (expensive) or diverge (confusing).

5. **Sunk-cost trap accumulates.** "We already ported this; might as well port the next thing too" is how Option A becomes a 100% port over 18 months.

### Option B risks

1. **Greenfield design bug.** Without dexs-backend's battle-testing, we ship an auth design with a flaw. Mitigation: 2–3 weeks of design review (Phase −1) + external crypto-review pass before merge.

2. **Schedule slip.** Greenfield always slips. Mitigation: ship Phase 1+2 (auth + identity, no capability grants yet) as a v0.5; defer capability grants to v1.

3. **Litentry pushback.** A bigger TEE-worker patch (introducing `oe_client_agentkeys` parallel to `oe_client_pumpx`) might trigger more upstream review. Mitigation: write the patch ourselves, propose it cleanly, accept that it might take an extra cycle.

4. **No prior art.** No "we know wildmeta runs this in production" reassurance. Mitigation: code review, security review, staged rollout (internal team → beta → public).

5. **Email-link auth complexity.** Designing magic-link without password fallback requires careful UX (link expiry, rate limit, single-use, device binding). Mitigation: skip email auth in v0.5 (passkey + wallet only); add email-link in v1 once the design is proven.

---

## Recommendation

**Option B (greenfield), with risk mitigation:**

1. **Start with Phase −1 (design + review)**: 2 weeks of architectural design — write the URL surface, data model, JWT-only flow, capability-grant model — and circulate for review *before* any Rust commits. If the design has a flaw, this is when it costs nothing to fix.

2. **Ship a minimal v0.5 first.** Just wallet-sig + passkey auth, OmniAccount-first storage, TEE-RSA JWT only, no capability grants yet. ~6 weeks. Replaces the current mock-server and unblocks "real auth on `/session/create`" — the original goal that started this conversation.

3. **Layer in capability grants for v1.** Master/daemon binding, TTL, scope, TEE-RSA signature on grants, audit anchoring. ~3 weeks. This is the part that makes AgentKeys *not* a wildmeta clone.

4. **Add OAuth + email-link for v1.5.** When end users (not crypto-native developers) start using AgentKeys. ~3 weeks.

5. **Keep Option A as a fallback escape hatch.** If, 4 weeks into Phase −1 + Phase 1 of Option B, the design or the implementation hits a real blocker, fall back to Option A's port. The user-record migration would be small (zero existing users) and the TEE-worker patch is similar.

**Why B over A:**

The user's "沉没成本" framing is correct. dexs-backend's value is its battle-tested *crypto primitives* (which Option B reuses anyway), not its *architecture* (which we'd inherit unwillingly). The architectural cost of Option A compounds over years; the schedule cost of Option B is paid once. AgentKeys is a credential broker for agents, not an exchange; designing around the credential-broker problem yields a smaller, simpler, more correct system than retrofitting an exchange backend.

Concretely: Option B ships ~12% less code, is OmniAccount-first instead of user_id-first, has one JWT issuer instead of two, has capability grants as first-class data, costs 4–5 weeks more calendar, and removes dependency on dexs-backend's evolution. The 4–5 extra weeks is a one-time cost; Option A's architectural debt is a permanent tax.

The recommendation is conditional on:
- Ability to budget 12–18 weeks of one engineer's time (vs 8–13 for Option A).
- Willingness to accept moderate schedule risk for higher architectural quality.
- Engineering or security-review capacity to do a 2-week design pass before any Rust lands.

If any of those are hard constraints, fall back to Option A — it's not the wrong answer, just the more conservative one.

---

## What needs deciding

To proceed, the user needs to commit on:

1. **Option A or Option B**, with the timeline implications stated above.
2. **If B**: whether the v0.5 → v1 → v1.5 phasing above is acceptable, or whether all four auth methods need to ship in v1.
3. **If A**: whether to keep the saved plan in `regarding-docs-dev-setup-md-http-dev-set-fuzzy-sphinx.md` or also rewrite it (the current plan there is the Option A description; it's still valid).

Once decided, the chosen option's plan becomes the active plan; the other is archived as the "rejected alternative" reference.
