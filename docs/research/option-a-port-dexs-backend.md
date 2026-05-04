# Plan: AgentKeys broker replaces dexs-backend

## Context

After three rounds of progressively deeper research (initial agent-only audit → dexs-backend code read → combined wildmeta+heima audit including local exploration docs), the architecture picture is:

- **Today's stub**: `agentkeys-mock-server` accepts any `auth_token` string and binds it to whatever wallet the caller claims. Public exposure means anyone with the URL can mint a session against any wallet. The original "make `/session/create` real" question was framed as a small docs change.

- **What the research surfaced**: The Heima TEE worker (`https://dex-api.heima.network`, `tee-worker/omni-executor/rpc-server/`) and the dexs-backend (Go-zero monorepo at `dexs-k/dexs-backend`) are mutually-recursive. The TEE worker is hardcoded single-tenant (`client_id == CLIENT_ID_WILDMETA` in `user_login.rs:73-104` is the only accepted client; everything else returns `InvalidParams`). The TEE worker calls back into dexs-backend's pumpx_api during `omni_userLogin` (line 73-91), `omni_addWallet`, `omni_requestJwt`. dexs-backend's gateway runs the front-of-house user-facing endpoints (wallet_login / email_login / google_oauth) and computes OmniAccount locally as a deterministic SHA256.

- **What "use Heima as our auth layer" actually means**: AgentKeys broker has to step into both sides of that mutual recursion. It becomes the front-of-house gateway *and* the back-of-house pumpx_api callback target. The TEE worker holds canonical wallet keys (TEE-derived smart-wallet root signers per `get_smart_wallet_root_signer.rs` and `export_wallet.rs`) and we call it for crypto / identity ops. We replace dexs-backend; we do not coexist with it.

- **Locked-in user decisions** (via AskUserQuestion this session):
  1. **Multi-tenant TEE patch** — Litentry adds (or AgentKeys forks heima with) a new `CLIENT_ID_AGENTKEYS` constant + parallel `agentkeys_api` HTTP-client config + parallel `agentkeys_backend_ecdsa_pubkey`. AgentKeys gets its own OmniAccount namespace, no collisions with wildmeta.
  2. **Auth methods at v1** — all four: wallet-sig (EIP-191 / Web3), email + verification code, Google OAuth, passkey/WebAuthn. Full dexs-backend parity.
  3. **Plan scope** — full rewrite, replacing the prior dev-setup-only framing. Original Changes 1-9 from that plan land as small housekeeping work in Phase 5.

This plan covers a multi-month backend implementation effort, not a single PR. Phases ship incrementally so an early phase can be live in production before later phases land.

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  agentkeys CLI (laptop)        perp-app frontend (browser, future)          │
│       │                              │                                      │
│       │  HTTPS (signed payload)      │  HTTPS (signed payload)              │
│       ▼                              ▼                                      │
│  ┌────────────────────────────────────────────────────────────────────────┐│
│  │  agentkeys-broker (Rust, Axum)                                          ││
│  │                                                                          ││
│  │  Front-of-house  (replaces dexs-backend's gateway/account services):    ││
│  │    POST /v1/session/wallet_login      ← EIP-191 ecrecover               ││
│  │    POST /v1/session/email_login,      ← Email + verification code       ││
│  │         /v1/session/email_register,                                      ││
│  │         /v1/session/email_code                                           ││
│  │    POST /v1/session/google_oauth      ← OAuth code exchange             ││
│  │    POST /v1/session/passkey_login     ← WebAuthn (proxied to TEE)       ││
│  │    POST /v1/mint-aws-creds            ← (existing)                      ││
│  │    POST /v1/mint-oidc-jwt             ← (existing)                      ││
│  │                                                                          ││
│  │  Back-of-house  (the TEE worker's `agentkeys_api` callback surface):    ││
│  │    POST /v3/account/post_heima_login                                    ││
│  │    POST /add_wallet                                                      ││
│  │    GET  /get_account_user_id?email=...                                  ││
│  │    POST /v1/account/check_hyper_agent_address                           ││
│  │    GET  /v5/account/get_user_address_info?mainAddress=...               ││
│  │                                                                          ││
│  │  Embedded:                                                               ││
│  │    • SQLite (or sled) for user/identity/wallet/grant/audit              ││
│  │    • jsonrpsee client → https://dex-api.heima.network                   ││
│  │    • RSA pubkey cache for TEE-RSA JWT verification                      ││
│  │    • EIP-191 / k256 / sr25519 sig verification                          ││
│  │    • bip39 + keystore for CLI-side wallet loading                        ││
│  └────────────────────────────────────────────────────────────────────────┘│
│              │                                                               │
│              │  jsonrpsee (omni_userLogin, omni_addWallet, omni_submitUserOpWithAuth)
│              │  bidirectional callback ↑↓ (TEE → broker)                    │
│              ▼                                                               │
│  ┌────────────────────────────────────────────────────────────────────────┐│
│  │  Heima TEE worker  (https://dex-api.heima.network)                      ││
│  │  • client_id = CLIENT_ID_AGENTKEYS  (NEW, requires upstream patch)      ││
│  │  • agentkeys_api → https://broker.litentry.org  (NEW)                   ││
│  │  • Smart-wallet root signers (TEE-sealed seed derivation)               ││
│  │  • TEE-RSA JWT issuance with sub=OmniAccount                            ││
│  └────────────────────────────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────────────────────────────┘
```

## Phases

Each phase ships a coherent unit. Earlier phases stay live while later ones build out.

### Phase 0 — Upstream prerequisites (block on Litentry, parallel to Phase 1+2)

Not AgentKeys code; but Phase 3 cannot land without these.

- **Open PR against `litentry/heima`** adding multi-tenant support to the TEE worker:
  - New constant `CLIENT_ID_AGENTKEYS` in `oe_core::auth::constants`.
  - `user_login.rs:73-104` — extend the `if params.client_id == CLIENT_ID_WILDMETA` branch to also accept `CLIENT_ID_AGENTKEYS`, dispatching to a parallel `ctx.agentkeys_api` instead of `ctx.pumpx_api`.
  - `submit_user_op_with_auth.rs:619-672` — add a parallel `agentkeys_backend_ecdsa_pubkey` and a `WildmetaBackend`-equivalent variant if AgentKeys needs the backend-signed userOp path; or generalize to `BackendSigned { client_id }` to avoid copy-paste.
  - `RpcContext` config struct gains `agentkeys_api: AgentKeysApiClient` and `agentkeys_backend_ecdsa_pubkey: [u8; 33]` alongside the existing pumpx fields.
- **Litentry deployment** — either deploy the patched TEE worker as a second instance pointed at AgentKeys broker, or deploy the patch into the shared instance with both `pumpx_api` and `agentkeys_api` configured.

Out of AgentKeys' direct scope, but the upstream PR can be drafted by us and offered to Litentry for review.

### Phase 1 — Pumpx-equivalent callback surface in the broker

The TEE worker calls back into our broker during user-login and wallet-creation flows. We need these endpoints live before Phase 3 (TEE-worker integration) can do anything end-to-end.

**New crates / modules:**
- `crates/agentkeys-broker-server/src/handlers/heima_callbacks/` — one file per endpoint:
  - `post_heima_login.rs` — accepts `{user_id, client_id, client_auth, heima_login_success}` from the TEE worker. Validates the inbound TEE-RSA JWT (`Authorization` header) using the cached RSA pubkey. Looks up or creates a user record keyed by `(client_id, identity_type, identity_value)`. Returns `PostHeimaLoginResponse` with our internal `user_id` + the OmniAccount derived locally.
  - `add_wallet.rs` — accepts `{wallet_index?}` from the TEE worker (with TEE-RSA JWT auth). Records `(omni_account, wallet_index, wallet_address)` in our DB. Returns `AddWalletResponse`. Note: the *address* comes from the TEE; we just bookkeep it.
  - `get_account_user_id.rs` — `GET ?email=...` lookup, returns our internal user_id (used by `omni_requestJwt` for email-only flows).
  - `check_hyper_agent_address.rs` — accepts `{main_address, agent_address}`, returns `{isBound: bool}`. AgentKeys' grant/scope DB is the source of truth (this is what makes us not just a wildmeta clone — the binding semantics are AgentKeys' own master/daemon-wallet model).
  - `get_user_address_info.rs` — `GET ?mainAddress=...`, returns wallet metadata for the address.

**Storage:** new SQLite schema (sled is fine if we want pure-Rust; SQLite via sqlx is the pragmatic choice given we already use SQLite for the audit DB).

```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id TEXT NOT NULL,                  -- "agentkeys" (or "wildmeta" if we ever proxy)
    identity_type TEXT NOT NULL,              -- evm | email | google | apple | passkey | substrate
    identity_value TEXT NOT NULL,
    omni_account TEXT NOT NULL,               -- hex(SHA256(client_id || type || value))
    user_login_address TEXT,                  -- nullable; populated for wallet-sig users
    email TEXT,                               -- nullable
    password_hash TEXT,                       -- nullable; only for email+password path
    is_2fa_bound INTEGER NOT NULL DEFAULT 0,
    google_2fa_secret BLOB,                   -- AES-encrypted-at-rest if present
    invite_code TEXT,
    created_at INTEGER NOT NULL,
    UNIQUE (client_id, identity_type, identity_value)
);

CREATE TABLE wallets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id),
    wallet_index INTEGER NOT NULL,
    wallet_address TEXT NOT NULL,
    chain_id INTEGER,                         -- nullable for cross-chain smart wallets
    created_at INTEGER NOT NULL,
    UNIQUE (user_id, wallet_index)
);

CREATE TABLE grants (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    master_wallet TEXT NOT NULL,
    daemon_wallet TEXT NOT NULL,
    scope_json TEXT NOT NULL,                 -- JSON-encoded scope/policy
    granted_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    revoked_at INTEGER,
    UNIQUE (master_wallet, daemon_wallet)
);

CREATE TABLE heima_jwts (
    omni_account TEXT NOT NULL,
    token_type TEXT NOT NULL,                 -- "access" | "id"
    jwt_string TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (omni_account, token_type)
);
```

**Auth on incoming callbacks:** the TEE worker presents an `access_token` it issued for the same OmniAccount. Verify the RSA signature against the TEE's pubkey (Phase 3 builds the RSA-pubkey cache).

**Files to touch:**
- New: `crates/agentkeys-broker-server/src/handlers/heima_callbacks/{mod,post_heima_login,add_wallet,get_account_user_id,check_hyper_agent_address,get_user_address_info}.rs`
- New: `crates/agentkeys-broker-server/src/storage/{mod,users,wallets,grants}.rs`
- New: `crates/agentkeys-broker-server/migrations/0001_users_wallets_grants.sql`
- Modified: `crates/agentkeys-broker-server/src/main.rs` — wire new routes, add `--db-path` flag.
- Modified: `crates/agentkeys-broker-server/Cargo.toml` — add `sqlx` (or pull it in as a workspace dep).

**Tests:** integration tests that drive the callback endpoints with simulated TEE-RSA JWTs (test fixture key); verify rows land in DB.

**Approx size:** ~1500 LOC Rust + ~400 LOC tests. 1-2 weeks of focused work for one engineer.

### Phase 2 — Front-of-house auth surface (replaces dexs-backend gateway)

The endpoints clients actually call. Each is a Rust port of the equivalent dexs-backend Go file.

**Files to create:**
- `crates/agentkeys-broker-server/src/handlers/session/wallet_login.rs` — port `walletloginlogic.go:42-100`. EIP-191 message construction (`"Hi! Welcome to AgentKeys. ... Timestamp is %d."` with our brand string), 45-min timestamp window, k256 ecrecover, user upsert, JWT issuance.
- `crates/agentkeys-broker-server/src/handlers/session/email_login.rs` — port `emailloginlogic.go`. Email lookup + bcrypt password verify + optional 2FA TOTP code check + JWT issuance.
- `crates/agentkeys-broker-server/src/handlers/session/email_register.rs` — port `emailregisterlogic.go`. Email-code verification (SMS-style verification stored in our DB with TTL), bcrypt password hash, user creation, JWT issuance.
- `crates/agentkeys-broker-server/src/handlers/session/email_code.rs` — port `sendemailcodelogic.go` (fetch). Generates a 6-digit code, stores in DB with 10-min TTL, sends via the AgentKeys SES setup (reuse `agentkeys-data-role` for SES SendRawEmail).
- `crates/agentkeys-broker-server/src/handlers/session/google_oauth_login.rs` + `google_oauth_callback.rs` — port `googleoauthloginlogic.go` + `googleoauthcallbacklogic.go`. Uses `oauth2` crate (Rust) + Google's userinfo endpoint.
- `crates/agentkeys-broker-server/src/handlers/session/passkey.rs` — proxy to TEE worker's `request_passkey_challenge` + `attach_passkey` + `omni_loginWithOAuth2`-equivalent. Most of the WebAuthn cryptography happens TEE-side; broker is mostly a router.

**Identity → OmniAccount derivation:** port `dexs-backend/pkg/omni/identity_tool.go:86-92` to Rust. Pure SHA256(`client_id` || `identity_type_byte` || `identity_value_bytes`). Make sure we use `client_id = "agentkeys"` (not "wildmeta") so namespaces don't collide if Litentry does the multi-tenant patch.

**JWT issuance:** initially HS256 with our own secret (matches dexs-backend's pattern). Later, Phase 3 lets us issue TEE-RSA JWTs by calling `omni_userLogin`. Both can coexist: HS256 for "we authenticated you locally"; TEE-RSA for "we got a TEE-attested session for you." The CLI prefers the TEE-RSA path when available.

**SES integration for email codes:** reuse `agentkeys-data-role` (already has `ses:SendRawEmail` permission per `cloud-setup.md §3.2`). The mailer module composes `From: noreply@bots.litentry.org`, `To: <user>`, `Subject: AgentKeys verification code`.

**CLI changes** (`crates/agentkeys-cli/src/lib.rs`):
- `agentkeys init` grows subcommands: `init wallet --mnemonic-file <path>`, `init wallet --keystore <path>`, `init email <addr>`, `init google`, `init passkey`. The default `init` interactively prompts.
- Wallet path: load mnemonic/keystore, sign EIP-191 message against broker's `/v1/session/wallet_login` challenge.
- Email path: prompt for email, broker sends code, prompt for code, prompt for password.
- Google path: open browser to broker's `/v1/session/google_oauth_login` redirect URL, handle the callback locally.
- Resulting JWT lands in OS keychain (existing keyring-rs path, no change).

**Files to touch:**
- New: `crates/agentkeys-broker-server/src/handlers/session/{mod,wallet_login,email_login,email_register,email_code,google_oauth_login,google_oauth_callback,passkey}.rs`
- New: `crates/agentkeys-broker-server/src/identity/omni_account.rs` — SHA256 derivation.
- New: `crates/agentkeys-broker-server/src/jwt/{issue,verify}.rs` — HS256 + RSA verify.
- New: `crates/agentkeys-broker-server/src/mailer.rs` — SES SendRawEmail wrapper.
- Modified: `crates/agentkeys-broker-server/Cargo.toml` — add `k256`, `bip39`, `sha2`, `bcrypt`, `oauth2`, `jsonwebtoken`, `lettre` (or aws-sdk-sesv2).
- Modified: `crates/agentkeys-cli/src/lib.rs` — new init subcommands.
- Modified: `crates/agentkeys-cli/Cargo.toml` — add `bip39`, `k256`, `eth-keystore`.

**Approx size:** ~2500 LOC Rust + ~600 LOC tests. 2-3 weeks.

### Phase 3 — Wire to Heima TEE worker

Now the broker actually talks to `dex-api.heima.network`.

**New module: `crates/agentkeys-broker-server/src/heima_client.rs`** — `jsonrpsee-http-client` against `https://dex-api.heima.network`. Methods we call:
- `omni_userLogin` — after a successful local login (Phase 2), call this with `client_id = "agentkeys"` to get a TEE-RSA JWT. The TEE will call our `/v3/account/post_heima_login` (Phase 1) as part of its handler, completing the round-trip.
- `omni_addWallet` — when a new user requests a smart wallet. TEE generates the address, calls our `/add_wallet` endpoint, returns the address.
- `omni_requestJwt` — email-only path, when the user doesn't have a wallet yet (TEE creates one bound to their email).
- `omni_submitUserOpWithAuth` — if AgentKeys ever needs to submit on-chain userOps (probably not for v1; this is wildmeta's trading-flow path).
- `omni_getSmartWalletRootSigner`, `omni_exportWallet` — for advanced users who want to export their TEE-derived wallet.

**TEE-RSA JWT verification:** at broker startup, fetch the TEE's RSA pubkey. The TEE worker exposes `omni_getShieldingKey` (per `get_shielding_key.rs` in the methods list) which is *related* but not necessarily the JWT signing key — Phase 0's spike against `dex-api.heima.network` confirms the right endpoint to fetch the JWT-verify pubkey, or whether we hardcode-then-rotate.

**Replace `BROKER_BACKEND_URL`** — currently the broker validates session bearers by HTTP-calling `BROKER_BACKEND_URL/session/validate`. Now sessions are TEE-RSA JWTs (or our own HS256 JWTs); validation is local cryptographic verification. Drop the env var or repurpose as `BROKER_TEE_ISSUER=https://dex-api.heima.network`.

**Files to touch:**
- New: `crates/agentkeys-broker-server/src/heima_client.rs` (jsonrpsee client + RSA pubkey cache).
- Modified: `crates/agentkeys-broker-server/src/handlers/mint.rs` — replace `validate_bearer_token` with local JWT verification.
- Modified: `crates/agentkeys-broker-server/src/config.rs` — add `tee_issuer_url`, `tee_rsa_pubkey_path` (or fetch endpoint).
- Modified: `crates/agentkeys-broker-server/Cargo.toml` — add `jsonrpsee-http-client`, `rsa`.

**Approx size:** ~600 LOC Rust + ~200 LOC integration tests. 1 week.

### Phase 4 — Multi-tenancy / production hardening

After Phase 3 ships, AgentKeys is functionally complete but operationally rough.

- **Cert thumbprint pinning** for the TEE-RSA pubkey (avoid silent hijack if Litentry's cert ever rotates and we don't notice).
- **Rate limiting** on the front-of-house endpoints (especially `/email_code` which costs SES money).
- **Audit-log integration** — every login lands a row in the existing `~/.agentkeys/broker/audit.sqlite`, alongside the existing AWS-cred and OIDC mints.
- **Heima JWT refresh flow** — TEE-RSA JWTs expire in 14 days per `AUTH_TOKEN_EXPIRATION_DAYS`; broker handles refresh transparently for the CLI.
- **Master-wallet ↔ daemon-wallet binding** — actually implement what `check_hyper_agent_address.rs` queries. This is the AgentKeys-specific concept (master grants daemon a scoped subset of capabilities), not just a wildmeta clone.

**Approx size:** ~800 LOC Rust + ~300 LOC tests. 2 weeks.

### Phase 5 — Retire mock-server, docs cleanup, smoke-test

**Production cleanup:**
- Remove `agentkeys-mock-server` from `setup-broker-host.sh` (the systemd unit, the nginx proxy block, the post-run summary all go away).
- The mock-server crate stays in-tree for the offline `--skip-startup-check` dev-loop tests and CI.
- Drop `BROKER_BACKEND_URL` from operator-runbook §3 env-var table; replace with `BROKER_TEE_ISSUER=https://dex-api.heima.network`.

**Docs:** the prior plan's Changes 1-9 (dev-setup §3-§4 self-mint framing, §1.1 v0.1 reality callout, stage7-wip smoke-test, setup-broker-host nginx block) all become small housekeeping tasks here. Most paragraphs that said "stub-backend caveat until Path B lands" simply get deleted because Path B has landed by Phase 5.

**New docs:**
- `docs/agentkeys-broker-auth-api.md` — the full HTTP/JsonRPC contract: every front-of-house endpoint, every callback endpoint, request/response shapes.
- `docs/spec/heima-tee-worker-integration.md` — how broker talks to TEE worker, RSA-pubkey caching, refresh flow, error handling.
- `docs/dev-setup.md` §4 — rewritten around `agentkeys init wallet|email|google|passkey` as the canonical entry points.

**End-to-end smoke (acceptance):**
```bash
# Fresh laptop, no AWS env, no SSH key, no pre-existing keychain entry.
agentkeys init wallet --mnemonic-file ~/.agentkeys/wallet.txt
# → broker calls TEE; TEE-RSA JWT lands in keychain; AgentKeys user record created.

agentkeys provision openrouter
# → broker mints AWS creds via existing mint-aws-creds path; daemon spawns scraper.

# Verify in audit DB (broker side):
sqlite3 ~/.agentkeys/broker/audit.sqlite \
  "SELECT outcome, requested_role FROM mint_log ORDER BY id DESC LIMIT 5;"
# → rows for both the session creation and the cred mint.
```

**Approx size:** ~200 LOC Rust cleanup + ~600 LOC docs. 1 week.

## Total scope estimate

| Phase | Scope | Rough LOC | Calendar |
|---|---|---|---|
| 0 | Upstream heima patch (us drafting, them merging) | 200 LOC | 2-4 weeks (their cycle) |
| 1 | Pumpx-equivalent callbacks + storage | 1500 + 400 tests | 1-2 weeks |
| 2 | Front-of-house auth (4 methods) + CLI | 2500 + 600 tests | 2-3 weeks |
| 3 | TEE-worker jsonrpsee client + JWT verify | 600 + 200 tests | 1 week |
| 4 | Hardening, refresh, rate-limit, master-daemon binding | 800 + 300 tests | 2 weeks |
| 5 | Mock-server retirement + docs | 200 + 600 docs | 1 week |
| **Total** | | **~7000 LOC** | **8-13 weeks (1 engineer)** |

Phase 1 + 2 can run partly in parallel with Phase 0 if Litentry takes time on the patch. Phase 3 blocks on Phase 0 landing.

## Critical files (across all phases)

**New crates / dirs in `crates/agentkeys-broker-server/`:**
- `src/handlers/session/` — front-of-house auth endpoints
- `src/handlers/heima_callbacks/` — back-of-house callbacks the TEE calls
- `src/storage/` — users / wallets / grants / heima_jwts
- `src/identity/omni_account.rs` — OmniAccount derivation
- `src/jwt/{issue,verify}.rs` — HS256 + TEE-RSA JWT
- `src/heima_client.rs` — jsonrpsee client to dex-api.heima.network
- `src/mailer.rs` — SES SendRawEmail wrapper
- `migrations/*.sql` — sqlx migrations

**Modified `crates/agentkeys-cli/src/lib.rs`** — `cmd_init` becomes a subcommand router (wallet/email/google/passkey).

**Upstream PR target: `litentry/heima`:**
- `tee-worker/omni-executor/oe-core/src/auth/constants.rs` — add `CLIENT_ID_AGENTKEYS`.
- `tee-worker/omni-executor/rpc-server/src/methods/omni/user_login.rs:73-104` — multi-tenant dispatch.
- `tee-worker/omni-executor/rpc-server/src/methods/omni/submit_user_op_with_auth.rs:619-672` — multi-tenant `BackendSigned` variant.
- `tee-worker/omni-executor/rpc-server/src/server.rs` — `RpcContext` gains `agentkeys_api` + `agentkeys_backend_ecdsa_pubkey`.

**Modified docs:**
- `docs/dev-setup.md` (Phase 5)
- `docs/operator-runbook.md` (Phase 5)
- `docs/stage7-wip.md` (Phase 5)
- `scripts/setup-broker-host.sh` (Phase 5 — undo the `location = /session/create` block from the older plan since the public path goes away)
- New: `docs/agentkeys-broker-auth-api.md`, `docs/spec/heima-tee-worker-integration.md`

## Reference files (read-only sources for the port)

- `dexs-backend/apps/account/internal/logic/walletloginlogic.go` — wallet-sig pattern (Phase 2).
- `dexs-backend/apps/account/internal/logic/emailloginlogic.go` + `emailregisterlogic.go` — email pattern (Phase 2).
- `dexs-backend/apps/account/internal/logic/googleoauthcallbacklogic.go` — Google OAuth pattern (Phase 2).
- `dexs-backend/pkg/omni/identity_tool.go:86-92` — OmniAccount derivation (Phase 2).
- `dexs-backend/apps/gateway/middleware/auth.go` — JWT verification reference (Phase 2).
- `heima/tee-worker/omni-executor/rpc-server/src/methods/omni/user_login.rs` — what the TEE calls back into (Phase 1).
- `heima/tee-worker/omni-executor/rpc-server/src/methods/omni/add_wallet.rs` — same.
- `heima/tee-worker/omni-executor/rpc-server/src/methods/omni/request_jwt.rs` — email-only-flow pattern (Phase 1).
- `heima/tee-worker/omni-executor/rpc-server/src/utils/auth.rs:58-116` — TEE-RSA signature verification reference (Phase 3).
- `heima/tee-worker/omni-executor/oe-core/src/auth/auth_token.rs` — JWT claim shape (Phase 3).
- `heima/tee-worker/omni-executor/primitives/src/auth.rs:212-227` — `ClientAuth` enum (Phase 0 / 3).

## Verification (per phase, all must pass before next phase merges)

**Phase 1:** integration tests that drive each callback endpoint with a fixture TEE-RSA JWT. SQLite rows land correctly. Replay protection works.

**Phase 2:** integration tests for each auth method: wallet-sig (k256 round-trip), email register+login (with mock SES), Google OAuth (with mock provider), passkey (against a TEE-fixture). Existing `--mock-token` keeps working as a feature-gated CI helper.

**Phase 3:** integration test against a local TEE-worker fixture (or staged dex-api) — broker calls `omni_userLogin`, gets JWT back, verifies signature, accepts on subsequent `mint-aws-creds` calls.

**Phase 4:** load test (1000 concurrent logins, no race conditions in user-upsert), refresh-flow soak test (broker keeps users logged in across JWT expirations).

**Phase 5:** `bash harness/stage-7-done.sh` exits 0; manual end-to-end smoke against `https://broker.litentry.org` (real deploy).

## What this plan explicitly does NOT cover

- **Agent-attestation track** (DCAP / `pallet-teebag` / MRENCLAVE-bound ephemeral SR25519 session keypairs from `docs/spec/heima-cli-exploration.md`). Separate work track. Combined research confirmed it's not implemented in any current wildmeta or TEE-worker code.
- **Migration of existing wildmeta users** to AgentKeys. If Litentry deploys the patched TEE worker, wildmeta users keep using `client_id = "wildmeta"` and `pumpx_api`; AgentKeys users are a parallel namespace from day 1. No data migration.
- **Frontend (perp-app equivalent)**. AgentKeys' surface is CLI-first (`agentkeys init wallet`); a future browser frontend can be added later, would call the same `/v1/session/*` endpoints.
- **Replacing the existing `mint-aws-creds` / `mint-oidc-jwt` / audit endpoints**. These stay; they're the reason AgentKeys exists, and they don't depend on the auth-backend choice.

## Phase ordering rationale

Phase 0 + 1 + 2 can interleave: Phase 0 is mostly Litentry waiting; Phase 1's callback endpoints can be built and tested with fixture TEE-RSA JWTs; Phase 2's front-of-house can be built and tested independently with HS256 JWTs. Phase 3 integrates everything once Phase 0 lands. Phase 4 hardens. Phase 5 cleans up.

If Litentry can't take the multi-tenant patch (Phase 0 blocked indefinitely), the fallback per the user's `~/Downloads/agentkeys-heima-worker-plan.md` is to masquerade as wildmeta tenant: AgentKeys broker exposes both the AgentKeys-native endpoints AND a wildmeta-shaped façade, claims `client_id = "wildmeta"` to the TEE, accepts the OmniAccount-namespace collision risk. That fallback is documented in the plan note; this plan assumes the cleaner Phase-0 path.
