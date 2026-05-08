# AgentKeys — Contradictions Tracker

**Purpose.** A consolidated list of contradictions, inconsistencies, and stale claims across `./wiki/`, `./docs/spec/plans/`, `./docs/`, and the 17 open GitHub issues at `litentry/agentKeys`. Use this as the punch list before Stage 8 begins — each item either needs a canonical decision, a doc edit, or both.

**Audit date:** 2026-04-14
**Repo state at audit:** Stage 4 implementation complete (per commit `f1eb96c`), `harness/progress.json` still shows Stage 4 `in_progress`, user plans to jump to Stage 8 (skipping 5-7). 17 open issues.

**Scope boundaries.**
- "MAJOR" = architectural disagreement or a claim a reader would act on and get burned.
- "MINOR" = terminology, framing, or local inconsistency that won't cause wrong implementation but will confuse readers.
- Contradictions already tracked in an open issue are cross-linked; the goal of this doc is to make them visible *together*, not to replace the issue threads.

---

## How to use this doc

1. **Before Stage 8:** resolve every MAJOR item marked "blocking Stage 8" below. Stage 8 hardening priorities (Priority A vs B vs C) depend on TTL, storage, and audit-pattern decisions that are currently inconsistent across docs.
2. **Each item** ends with a **Resolution** line — the single action that closes it (pick one value, edit N files, or file a new issue).
3. **Sections 1–4** are the MAJOR items grouped by topic. **Section 5** is MINOR. **Section 6** is stage-state / workflow inconsistencies specific to the Stage 4→8 jump. **Section 7** is a condensed punch list.

---

## 1. Session token — TTL, naming, and storage

### 1.1 Session-token TTL: 24 h vs 30 d  (RESOLVED 2026-04-14)

Three docs disagree on the default session-token TTL, and Stage 8 Priority A/B classification is justified in terms of the 30-day number.

| Source | Claim |
|---|---|
| `wiki/session-token.md:35, 58, 99, 121, 146, 211` | "**30-day** bearer credentials"; `exp: now + 30 days`; "up to 30 days" |
| `wiki/key-security.md:48` | "configurable via `AuthOptions.expires_at` (default **~24h**)" |
| `wiki/key-security.md:70-75, 152` | Then flips: "30-day TTL… restored to Priority A" (self-contradicts L48) |
| `wiki/key-security.md:220` | "stolen sessions expire in **24h** (mock backend default)" (contradicts L70 again) |
| `wiki/blockchain-tee-architecture.md:327, 369` | "`exp: now + 24h` (configurable via `AuthOptions.expires_at`)"; "default ~24h per the client SDK" — marked "verified against Heima source 2026-04-12" |
| `wiki/data-classification.md:106` | "JWT expiry (~~24h)" |
| `docs/spec/1-step-analysis.md:124` | Master auth token "15 min – 24 h, configurable" |
| `docs/spec/1-step-analysis.md:130, 437` | Agent session "4 h default, up to 24 h" — and "hard TTL of 4 hours regardless" |
| `wiki/session-token.md:242` | v0 mock table: "TTL field in SQLite (**86400s** default)" (24h) |

**Impact on Stage 8.** `development-stages.md:782, 786-790` cites "restored to Priority A" for `zeroize`/`memfd_secret` because the token is long-lived. If the *actual* Heima default is 24h (not 30d), the urgency drops. Stage 8 Priority A ranking cannot be finalized until one value wins.

**Resolution.** Pick one of:
- **Option T-A**: Canonical TTL = 24h (Heima default). Rewrite `wiki/session-token.md` to use 24h, delete the "30 days" claim, keep Priority A justification by citing "long-lived-enough" argument. 7 files to touch.
- **Option T-B**: Canonical TTL = 30 days (AgentKeys-override policy). Then update `wiki/blockchain-tee-architecture.md:327, 369`, `wiki/data-classification.md:106`, and the v0 SQLite default (86400s). 5 files to touch.
- **Option T-C**: Document both — "Heima default 24h; AgentKeys targets 30d policy override via `AuthOptions.expires_at`." Cleanest if the answer is "both are true." Add a ≤10-line "canonical TTL" note to `wiki/session-token.md` §1.

**Decision (2026-04-14):** **Option T-B** — canonical AgentKeys TTL is **30 days**, set explicitly via `AuthOptions.expires_at`. Heima SDK default of ~24h is acknowledged as the upstream default but overridden by AgentKeys policy. Stage 8 Priority A ranking stands.

**Applied to:**
- `wiki/blockchain-tee-architecture.md:327` — `exp: now + 24h` → `exp: now + 30 days (AgentKeys policy via AuthOptions.expires_at; Heima SDK default is ~24h)`
- `wiki/blockchain-tee-architecture.md:369` — updated to AgentKeys policy + Heima default note
- `wiki/data-classification.md:106` — updated to 30-day policy note
- `wiki/key-security.md:48` — updated; clarified high-value justification
- `wiki/key-security.md:220` — clarified v0 mock 24h vs v0.1 AgentKeys 30d
- `wiki/session-token.md` §1 — already 30d; added AgentKeys policy note explicitly
- v0 mock SQLite default (86400s) unchanged — v0 is the mock layer, document update only.



### 1.2 "JWT" vs "session token" terminology  (RESOLVED 2026-04-14, sweep tracked in #10)

Issue #10 tracks renaming JWT → session token. `wiki/session-token.md:3, 33-37` declares the rename. But:

- `wiki/key-security.md` §1, §2, §3 still uses "JWT" freely (lines 19, 35, 51, 70-75, 89, 108-109).
- `wiki/data-classification.md:24, 106` still labels "JWT auth token" in the master table.
- `wiki/blockchain-tee-architecture.md` §4 is titled "Auth token lifecycle (JWT model…)" and uses "JWT" throughout.
- Issue titles still use "JWT" (issues #10 title itself, #3 body).

**Resolution.** Close with issue #10 — either a single sweeping rename PR or an explicit doc-level decision "we use both, JWT for format and session token for value." Not blocking Stage 8.

**Decision (2026-04-14):** Canonical AgentKeys term is **"bearer token"**. Heima-internal terminology ("JWT" / `AuthTokenClaims`) is out of scope — we do not plan to change Heima. Issue #10 tracks the AgentKeys-side sweep.

**Applied to (anchor edits, not the full sweep):**
- `wiki/session-token.md` title + opening block — bearer token is canonical; session token is synonym; JWT is Heima-side only.
- `wiki/session-token.md` §1 — "bearer token (a.k.a. session token)" with AgentKeys 30-day policy note.
- `wiki/data-classification.md:106` — "Bearer token (formerly JWT auth token; rename tracked in #10)".
- `wiki/blockchain-tee-architecture.md` §4 heading — "Bearer token lifecycle (JWT model, verified against Heima source)" + status banner.
- Full sweep of remaining "JWT" occurrences across `key-security.md`, `serve-and-audit.md`, and issue bodies stays in #10.

### 1.3 Daemon session storage: memfd_secret vs file vs keychain  (RESOLVED 2026-04-14 via #12)

Four different statements about where the daemon stores its session:

| Source | Claim |
|---|---|
| `docs/spec/architecture.md:50, 139, 216, 254, 257` | Daemon "holds session key in `memfd_secret`" |
| `docs/spec/plans/development-stages.md:359` (Stage 3) | "Session file at `$HOME/.agentkeys/session` (mode 0600)" — plain file only |
| `wiki/key-security.md:57` (Section 2 table row) | "Plain file (`~/.agentkeys/token`, mode 0600)… No keychain available" |
| `wiki/blockchain-tee-architecture.md:273` | "memfd_secret under Stage 3 hardening, file at ~/.agentkeys/session mode 0600" |
| Issue #12 | "Daemon should use OS keychain when available (Mac mini, MacBook, Raspberry Pi)" + wallet-based session isolation |
| Current code (`crates/agentkeys-daemon/src/session.rs`) | File only, shared path `~/.agentkeys/session` → daemons collide (per #12) |

Three separate mismatches:
1. **`memfd_secret` status**: `architecture.md` and `blockchain-tee-architecture.md` describe it as if implemented; Stage 3 deliverables list it (as one bullet under "kernel hardening"); but it's a runtime-memory protection, not a storage mechanism. The wiki conflates "memfd_secret for runtime key copy" (memory hygiene) with "session at rest" (file/keychain).
2. **File vs keychain**: Stage 3 ships file-only. Issue #12 says keychain where available. `key-security.md:57` still frames daemon as file-only.
3. **Multi-daemon collision**: all daemons use `~/.agentkeys/session` → multi-agent demo (Demo 1) breaks. Per-wallet namespacing proposed in #12.

**Impact on Stage 8.** Stage 8 Priority A includes "`zeroize`/`SecretString` wrappers on `Session.token`" and "daemon-mediated `cmd_run`" — both interact with where the session actually lives. Can't finalize Priority A without deciding file/keychain/per-wallet first.

**Resolution.** Land issue #12 before Stage 8 starts *or* explicitly scope it to a sub-item of Stage 8. Then update `key-security.md:57` and `architecture.md:50, 139` to reflect the chosen model. 4 files touched.

**Decision (2026-04-14):** Follow issue #12 — daemon uses OS keychain when available (desktop / Mac mini / Raspberry Pi with gnome-keyring/KDE Wallet), wallet-namespaced accounts (`service=agentkeys, account=daemon-<wallet>`), plain-file fallback (`~/.agentkeys/daemon-<wallet>/session.json`, mode 0600) in Docker/sandbox. `memfd_secret` is a **runtime-memory** mechanism for the in-process key copy — not at-rest storage. #12 implementation lands before Stage 8 Priority A begins.

**Applied to:**
- `docs/spec/architecture.md` row 2 (component inventory) — rewrote to reflect keychain-first-with-file-fallback + wallet-namespacing per #12; clarified `memfd_secret` is runtime key copy.
- `wiki/key-security.md` §2 storage table — split "Daemon in sandbox" into two rows: desktop/Mac mini/Raspberry Pi (keychain) vs Docker/cloud sandbox (file fallback).
- `wiki/blockchain-tee-architecture.md` §3 step 17 — updated storage note to keychain-first per #12 with file fallback and memfd_secret as runtime-copy layer.
- Code changes (moving `session_store` to `agentkeys-core`, wallet-based session IDs) are the scope of #12 itself.

### 1.4 `Session.token` type in code  (MINOR)

`development-stages.md` Stage 8 lists test `types::session_token_is_secret_string` — asserts `Session.token` is `SecretString`. Current `agentkeys-types::Session` uses plain `String`. Not a contradiction between docs, but a tracked gap between spec and code. Closed by Stage 8 P-A item "zeroize/SecretString wrappers."

---

## 2. Pair transport — v0 rendezvous relay vs v0.1 on-chain

### 2.1 Two models described as "current" in different docs  (RESOLVED 2026-04-14 via banners)

The pair/approve flow is in an in-between state.

| Source | Claim |
|---|---|
| `docs/spec/plans/development-stages.md:149-169, 195-205` (Stage 1) | v0 mock backend: `rendezvous_registrations` + `auth_requests` tables, 6 REST endpoints (`register_rendezvous`, `poll_rendezvous`, `deliver_rendezvous`, `open_auth_request`, `fetch_auth_request`, `approve_auth_request`, `await_auth_decision`) |
| `docs/spec/plans/development-stages.md:895-928` (Stage 9) | Design decision: "Hybrid on-chain pair transport" replaces the relay — explicitly a v0.1 change |
| Issue #6 | Same — tracks migration, estimates ~665 LOC removed from backend |
| `wiki/blockchain-tee-architecture.md:189-302` (Section 3) | Describes "pairing (on-chain transport)" with no caveat that this is future state — reads as if already implemented |
| `wiki/serve-and-audit.md` intro (~line 8) | Frames v0.1 Pattern 4 decoupling as general principle, applies to pair + audit |

A reader of only `blockchain-tee-architecture.md §3` believes on-chain pair is built. A reader of only Stage 1 knows it's a centralized SQLite relay. Both are "correct" for different horizons.

**Impact on Stage 8.** If Stage 8 adds `SecretString` wrapping + idle eviction + daemon-mediated `cmd_run`, it will *touch* the pair/approve plumbing. Does Stage 8 work against v0 relay (rendezvous + auth_requests tables) or stub in the on-chain interface? Implicit decision today: Stage 8 ships on v0. But no doc makes this explicit.

**Resolution.** Add a one-line status banner at the top of `wiki/blockchain-tee-architecture.md §3` and `§4`: "**Status:** v0.1 design — v0 implements this via the rendezvous relay described in `development-stages.md` Stage 1." Same banner at `wiki/serve-and-audit.md §1`. Cost: 3 sentences.

**Decision (2026-04-14):** Add status banners. Stage 8 ships on v0 (rendezvous relay); v0.1 on-chain transport is future work (#6). No code change in this resolution.

**Applied to:**
- `wiki/blockchain-tee-architecture.md` §2 header — added "Status: v0.1 Pattern 4" banner with link to #5 and pointer to Stage 1 for v0 flow.
- `wiki/blockchain-tee-architecture.md` §3 header — added "Status: v0.1 on-chain pair transport" banner with link to #6 and pointer to Stage 1 v0 rendezvous.
- `wiki/blockchain-tee-architecture.md` §4 header — added "Status: v0.1 Heima JWT" banner; v0 uses opaque random bearer string per `wiki/session-token.md` §8.
- `wiki/serve-and-audit.md` §1 — added "Status: v0 synchronous SQLite; Pattern 4 is v0.1" banner; clarified ~6s = audit-lag, not serve-latency.

### 2.2 OTP (Stage 1/4) vs VVC (Stage 9/issue #6)  (RESOLVED 2026-04-14)

Two separate user-verification codes exist in the docs, for the *same* pair flow:

| Source | Code name | Derivation | Server-validated? | Use |
|---|---|---|---|---|
| `development-stages.md:98, 105, 119-122, 201, 210-215, 448` (Stages 0, 1, 4) | **OTP** | HMAC(nonce, canonical CBOR of request details) | Yes (backend stores, single-use) | Interactive approve — "OTP is 123456. Does this match?" |
| `wiki/blockchain-tee-architecture.md:212, 236` + issue #6 | **VVC** | `decimal(SHA256(pair_request_signature))[..6]` | No (purely client-derived) | User picks correct daemon from list of decoy pair requests |

The two codes are not the same thing — OTP proves backend-mediated integrity of request details (so a tampered request produces a different OTP), VVC proves extrinsic-level signature match (so a decoy daemon on-chain shows a different VVC). Both v0 and v0.1 may want *both* primitives. But the docs use them interchangeably in some places:

- Stage 4 E2E (`development-stages.md:472`) shows "OTP: 123456" — v0.
- Issue #6 describes VVC as replacing "the OTP" in v0.1.

If v0.1 actually replaces OTP with VVC, the threat model changes (server-side tamper detection is different from signature comparison). If v0.1 keeps both, no doc says so.

**Resolution.** Add a short section to `wiki/blockchain-tee-architecture.md` (or a new note) that distinguishes OTP and VVC explicitly, states which is v0 vs v0.1, and whether they coexist. Update issue #6 to reflect the decision.

**Decision (2026-04-14):** v0 keeps OTP (HMAC of canonical request). v0.1 replaces OTP with VVC (SHA256-signature fingerprint) as part of issue #6's on-chain migration. No coexistence — v0.1 does not need OTP because on-chain pair transport has no `auth_requests` table for nonces. The two primitives are fully disambiguated in wiki docs.

**Applied to:**
- `wiki/blockchain-tee-architecture.md` §3 — added "OTP (v0) vs VVC (v0.1) — two different verification codes" subsection with side-by-side comparison table and migration notes.

### 2.3 Daemon `--parent` flag missing  (MUST LAND BEFORE STAGE 8 — issue #14)

- `docs/manual-test-stage4.md:600-604` (Test 8 "Wrong User Approval") uses raw `curl` because the daemon exposes no `--parent` flag.
- `development-stages.md` Stage 4 deliverables list `pair::wrong_user_approve` as a unit test but do not describe daemon `--parent` surfacing.
- Issue #14 tracks adding `--parent <alias-or-wallet>` on daemon + `agentkeys-daemon --recover <id> --parent <master>`.
- `wiki/credential-usage.md` does not reference `--parent`.

**Resolution.** Land #14 before Stage 8 (small — adds one CLI flag and threads it through `open_auth_request`). Or explicitly defer to v0.1 and update Test 8 to label the curl path as "v0 test seam." 3 files touched.

**Decision (2026-04-14):** Land #14 before Stage 8. Implementation-only change (add `--parent` flag on daemon + `--recover --parent` + backend plumbing). Docs update happens as part of #14 landing — no pre-emptive wiki edit here.

**Tracking:** issue #14. Blocks Stage 8 kickoff.

---

## 3. Audit pattern and TEE wallet-key model

### 3.1 Pattern 4 as design vs implementation  (MAJOR — same shape as 2.1)

| Source | Framing |
|---|---|
| `docs/spec/plans/development-stages.md:895-928` (Stage 9) + issue #5 | Pattern 4 is a v0.1 design decision, not shipped in v0 |
| `wiki/serve-and-audit.md` §1 (intro) | "v0.1 target is Pattern 4" — clear |
| `wiki/serve-and-audit.md` §3 opens with the ~6s "first-read" diagram; Section 11's latency budget table shows Pattern 4 at ~50ms. A reader skimming §3 without reading §11 comes away thinking Pattern 4 is slow. |
| `wiki/blockchain-tee-architecture.md:131-166` (Section 2, credential-retrieval worked example) | Step 6 says "TEE builds audit extrinsic (DECOUPLED from the response)… submitted via paymaster" — reads as current Pattern 4 behavior with no v0 caveat |
| `crates/agentkeys-mock-server/src/handlers/audit*.rs` (v0) | Synchronous audit insert in SQLite — no paymaster, no async submission |

**Resolution.** Same banner treatment as 2.1 at the top of `wiki/blockchain-tee-architecture.md §2` and `wiki/serve-and-audit.md §3`. Cost: 2 sentences.

### 3.2 "Latency is ~6s" — first-read or audit-lag?  (MINOR)

`wiki/serve-and-audit.md:99-107` opens §3 with a diagram showing "~6 seconds" as the first-read cost. That is true only for Pattern 0 (cold-first-read, rejected). `blockchain-tee-architecture.md:163` correctly attributes ~6s to "audit extrinsic confirmed on-chain." §3's opening reads as if Pattern 4 also costs ~6s, which it doesn't.

**Resolution.** One sentence edit at the top of `serve-and-audit.md §3`: "Under cold-first-read (rejected), first read takes ~6s. Under Pattern 4 (chosen for v0.1), serve is ~50ms; the ~6s below refers to audit-lag, not serve-latency."

### 3.3 TEE wallet-key model: independent keys vs MSK-derived  (MAJOR — issue #9 intent vs current wiki)

- `wiki/blockchain-tee-architecture.md:57-63` (marked "Correction, verified against Heima source 2026-04-12"): TEE holds **multiple independent keys** (RSA JWT key, shielding key, per-user wallet keys). **NOT HD-derived from a master seed.**
- Issue #9 + `wiki/blockchain-tee-architecture.md` §6 (later in the file) + `wiki/key-security.md` §MSK notes: Target v0.1 is **MSK-derived stateless** model — one sealed MSK, derive user keys on demand.
- `wiki/data-classification.md:21-23` (master table) shows BOTH rows side by side: "User wallet private keys (current model: per-user)" and "MSK (target model: single master key)". This is clean and correct — the two models are presented as current-vs-target.
- `docs/spec/tech-brief.md:49` (§2 architecture box): uses "Master key custody + signing" — ambiguous phrasing that could read as HD-derived.

**Resolution.** Update `tech-brief.md:49` to explicitly say "per-user independent wallet keys held in TEE sealed storage (current); MSK-derived model targeted for v0.1 per issue #9." Issue #9 stays open.

### 3.4 Revocation latency: "instant" vs "~6s"  (MINOR)

- `wiki/key-security.md:221`: "`agentkeys revoke` kills a session **instantly**."
- `docs/spec/plans/ceo-plan.md:320`: "One revoke kills all" (similar framing).
- `wiki/session-token.md:194` + `wiki/blockchain-tee-architecture.md:399`: "Revocation latency = 1 block (~6s)." (v0.1 Heima)
- `docs/spec/heima-open-questions.md` Q9: "~6s is the target; if slower, degrade demo claim to 'within one block'."
- v0 mock backend: SQLite flag flip is genuinely instant.

Both are true at different horizons. But "instantly" in `key-security.md:221` reads absolute.

**Resolution.** One-line edit in `key-security.md:221`: "`agentkeys revoke` kills a session instantly in v0 (SQLite flag); ~6s in v0.1 (one Heima block)."

---

## 4. CLI UX — manual test doc vs current code vs issues

### 4.1 `agentkeys revoke` broken  (RESOLVED 2026-04-14 — fix/issue-17)

- `crates/agentkeys-cli/src/lib.rs` (`cmd_revoke`): passes wallet address as session token → backend's `WHERE token = ?1` finds nothing → always "target session not found."
- `docs/manual-test-stage4.md:707-710, 724`: Test 9 marks revoke SKIPPED/BROKEN, but pass criteria line 724 still lists "Revoke succeeds."
- `wiki/credential-usage.md:127`: shows `agentkeys revoke 0xAGENT` as the canonical syntax, no caveat it's broken.
- Issue #17 proposes: self-revoke (no args) + revoke by wallet/alias + distinguish revoke (invalidate session, creds survive) vs teardown (delete creds + revoke sessions).

**Resolution.** Landed in `fix/issue-17` (PR pending merge). `cmd_revoke` takes `Option<&str>` — no-args self-revokes + wipes local session; wallet form calls new `CredentialBackend::revoke_by_wallet` trait method; backend `/session/revoke` handler now accepts either `target_session` (token) or `target_wallet` (wallet). `wiki/credential-usage.md` now carries the revoke-vs-teardown table. `docs/manual-test-stage4.md` Test 9 passes on the fix branch. See `docs/manual-test-issue-17.md` for the full reproduction + verification walkthrough.

### 4.2 `agentkeys run` broken for master sessions  (PARTIALLY RESOLVED 2026-04-14 — fix/issue-15 parts 1+2)

- `crates/agentkeys-cli/src/lib.rs:156-160`: when `session.scope = None`, `services_to_try = vec![]` → nothing injected.
- `docs/manual-test-stage4.md:697-701`: Test 9 marks run SKIPPED due to #15.
- `wiki/credential-usage.md:45`: correctly documents the limitation.
- `development-stages.md:294` (Stage 2): test `cli::run_injects_env` expects `agentkeys run my-agent -- env` output to contain `OPENROUTER_API_KEY=sk-xxx` — this test cannot pass for master sessions today.
- Issue #15 also requests: (a) fix scope-None path to query all stored credentials, (b) `agentkeys scope <agent> --add service` CLI command, (c) `--env` override flag.

**Resolution.** Parts (a) and (c) landed in `fix/issue-15` (PR pending merge). `CredentialBackend::list_credentials(session, agent_id)` trait method + mock-server endpoint `GET /credential/list?agent_id=<w>` enable master sessions to enumerate stored services. `cmd_run` takes `--env KEY=service` (repeatable) as an escape hatch for services whose canonical env var doesn't match the auto-convention. Part (b) — scope-edit CLI command — remains open, tracked as story `fix-15b` in `.omc/prd.json`; this entry becomes fully RESOLVED when that follow-up PR lands.

### 4.3 Wallet-optional CLI + identity aliases  (RESOLVED 2026-04-14 — fix/issue-16)

- Current: every command requires explicit wallet (`agentkeys store 0xAGENT openrouter sk-xxx`).
- Issue #16: wallet should default to session wallet, and aliases should resolve via `/identity/resolve`.
- `wiki/credential-usage.md` and `docs/manual-test-stage4.md` consistently show the wallet-required form. Both will need rewriting when #16 lands.
- `development-stages.md:276, 314` (Stage 2) hard-codes wallet-required syntax in deliverables + E2E checklist.

**Resolution.** Landed in `fix/issue-16` (PR #20). New `CredentialBackend::resolve_identity(session, identifier)` trait method + helper `resolve_agent(ctx, session, agent: Option<&str>)` in `agentkeys-cli/src/lib.rs` unify all agent-targeting commands. `store`/`read`/`run` take `--agent <wallet|alias>` as a flag (clap derive can't disambiguate an optional leading positional from required args without panicking; subcommand split or manual parser are the only alternatives, and human design call accepted the `--agent` flag tradeoff per PR #20 thread). `--agent` accepts: 0x-prefixed wallet (passthrough), linked alias/email (resolved via `/identity/resolve`), or omitted (defaults to session wallet). Unknown identities return a clean error. **Breaking change**: existing scripts using `agentkeys store 0xABC openrouter sk-xxx` must migrate to `agentkeys store --agent 0xABC openrouter sk-xxx`. Migration sed: `sed -i '' -E 's/agentkeys (store\|read\|run) (0x[0-9a-fA-F]+\|[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+\|[a-zA-Z][a-zA-Z0-9_-]*) /agentkeys \1 --agent \2 /g'`. Wiki + main.rs long_about updated in this PR.

**Human Decision**:
#16 should landed in v0.0 before Stage 8

### 4.4 Backend: typed params, shared resolve_identity, modular handlers  (MAJOR — issue #13)

`CLAUDE.md` declares three Mock Server Design Principles:
- Typed parameters, not opaque JSON
- Shared `resolve_identity()` utility in `handlers/identity.rs`
- Modular handlers (e.g., `mint_pair_session`, `mint_recover_session`)

Current code in `handlers/auth_request.rs` (Recover branch) violates all three per issue #13 body. `docs/spec/credential-backend-interface.md` does not currently document typed identity parameters for `open_auth_request(Recover)`.

**Resolution.** Land #13 before Stage 8 — it's a pure refactor with no product surface change but simplifies downstream work. Update `credential-backend-interface.md` to reflect typed `identity_type`/`identity_value` on Recover. 5 files per #13.

---

## 5. Minor / terminology-level inconsistencies

| # | Item | Files |
|---|---|---|
| 5.1 | CredentialBackend: 15 methods (correct, all plans agree) + `PaymentRail` adds 5 more (not counted separately in plan summaries). `tech-brief.md` mentioning "16 async methods" is not an outright contradiction but could be the `PaymentRail::display_name` sync-method fooling a counter. | `tech-brief.md:~§5`, `credential-backend-interface.md:305-322` |
| 5.2 | Provisioner scope: all docs agree "v0 = OpenRouter only." No contradiction, but language in `architecture.md:234` ("v0: single service") implies extensibility while `ceo-plan.md:43` is "OpenRouter only." Reader can interpret either way. | `ceo-plan.md`, `architecture.md` |
| 5.3 | Test count arithmetic: 8+37+14+13+11+9+7+6 = 105 matches. Stage 7 is "6 E2E flows" which the summary table aggregates into the 105 — label them "E2E flows" not "tests" for clarity. | `development-stages.md:961` |
| 5.4 | Session TTL values scattered: pair-code 5 min; auth-request 60s interactive / 5min async; master token 15m–24h; agent session 4h default/24h hard; JWT target 30d. Each value is correct for its scope, but there's no single "TTL glossary." | 5 docs |
| 5.5 | Issue #11 biometric gate for master CLI — referenced in `wiki/session-token.md:154-168` as planned, but `development-stages.md` does not list it as a Stage 8 deliverable. | Cross-ref only. |
| 5.6 | `wiki/credential-usage.md` does not mention `--parent` daemon flag (#14), `--env` run flag (#15), wallet-optional form (#16), or self-revoke (#17). It accurately describes *current* behavior, so it's not strictly contradictory — but it should carry a "limitations" section linking the four issues. |
| 5.7 | `docs/spec/plans/design-spec.md` is explicitly labeled "Historical stub" and points to `ceo-plan.md`. No contradiction, just flagged because future agents opening the plans dir might read it first. |

---

## 6. Stage-state and workflow inconsistencies (specific to the 4→8 jump)

### 6.1 `harness/progress.json` vs reality  (MAJOR — blocking harness use)

```
harness/progress.json currently says:
  "4": {"status": "in_progress", "tests_passed": 0, "tests_total": 11}
```

But:
- Latest commit `f1eb96c` says "stages 0-4 complete + codex review fixes (all 7/7 PASS)".
- User intent: "finished stage 4."
- `harness/features.json` contains only Stage 0 features; no Stage 1-4 features were ever appended despite the per-stage protocol in `CLAUDE.md`.

**Impact.** The harness is out of sync. A fresh agent running `bash harness/init.sh 4` per `CLAUDE.md` expects to resume Stage 4 in-progress. `advance-stage.sh 4 5` would see Stage 4 incomplete and refuse.

**Resolution before Stage 8.**
1. Update `harness/progress.json`: mark Stage 4 `complete` with the real test count (11/11 if passing, partial otherwise).
2. Backfill `harness/features.json` with Stages 1-4 features (or explicitly decide to stop maintaining that file).
3. Decide: skip stage 5/6/7 by marking them `skipped` with a reason string, or leave them `pending` and jump the `current_stage` pointer directly to 8 (harness needs a documented "skip" semantics — currently undefined).

**Human Decision**:
Follow 1 and 2 in Resolution, and we will work stage by stage to Stage 8

### 6.2 Stage 8 dependencies  (MAJOR)

- `development-stages.md:966`: "Critical path: Stage 0 → 1 → 4 → 7. **Stage 8 is post-MVP and can ship after the v0 demo.**"
- `development-stages.md:883`: Stage 8 Contract: "Inputs: Stages 0-7 complete."
- User plan: skip 5, 6, 7 → Stage 8.

Is Stage 8 actually blocked by 5-7, or is the "Inputs 0-7" boilerplate? Concrete checks:

- Stage 5 (Provisioner): Stage 8 doesn't touch `agentkeys-provisioner`. **No real dependency.**
- Stage 6 (npm + DX): Stage 8 doesn't need the npm package, but ships CLI changes (`whoami`, idempotent `init`, `HighValueRelease`) that should land in the published package. Order: Stage 8 first, Stage 6 later is fine.
- Stage 7 (full E2E): Stage 8 ships new E2E hardening checks. Running Stage 7's 6 flows against Stage 8 code validates both. **Hard dependency only if you want the v0 E2E baseline before hardening.**

**Resolution.** Add an explicit note at `development-stages.md:883`: "Inputs: Stages 0-4 required. Stages 5-7 preferred but not blocking for hardening-only items. If skipping 5-7, mark those stages as `deferred` in `harness/progress.json` and plan a combined 5+6+7+E2E validation pass after Stage 8."

**Human Decision**: In stage 8 we test all the 5+6+7+e2e, a important use case is that it can operate via MCP to create a new API token in openroute by control user browser.

### 6.3 Stage 8 Priority A scope depends on unresolved items above

Priority A deliverables in `development-stages.md:784-790`:
- `zeroize` / `SecretString` on `Session.token` — depends on **1.1 (TTL)** and **1.3 (storage)** decisions.
- Daemon-mediated `cmd_run` — depends on **4.2 (issue #15 scope fix)** and **1.3 (session location)**.
- `memfd_secret`-via-SCM_RIGHTS — a runtime-memory mechanism, independent of 1.1/1.3.
- Idle credential eviction — independent.
- Daemon-internal audit trail — independent.

**Resolution.** Decide items 1.1, 1.3, 4.1, 4.2, 4.3 before coding Priority A; items 3.1, 3.3 can lag to v0.1. Priority B and C items have no upstream blockers from this doc.

**Human Decision**: Following Human Decision, if no human decision, follow resolution


### 6.4 "Backend Design Principles" doc name  (MINOR — issue #13)

Issue #13 asks to rename "Mock Server Design Principles" → "Backend Design Principles" in `CLAUDE.md`. Currently still "Mock Server." Small but cited in every session-start read.

**Human Decision**: Change it now
---

## 7. Punch list (condensed)

Grouped by status and what the user probably wants to hit before Stage 8.

### ✅ Resolved 2026-04-14 (decisions applied to wiki/spec docs)

- [x] **1.1** Canonical TTL = **30 days** (AgentKeys policy via `AuthOptions.expires_at`; Heima SDK default ~24h noted). Applied to `blockchain-tee-architecture.md:327,369`, `data-classification.md:106`, `key-security.md:48,220`, `session-token.md` §1.
- [x] **1.2** Canonical term = **"bearer token"** (AgentKeys side; Heima keeps JWT). Anchor edits applied to `session-token.md`, `data-classification.md`, `blockchain-tee-architecture.md §4`. Full sweep remains scoped to #10.
- [x] **1.3** Daemon storage = **OS keychain when available + file fallback + wallet-namespacing per #12**. Doc updates applied to `architecture.md:50`, `key-security.md §2 table`, `blockchain-tee-architecture.md §3 step 17`. Code changes are the scope of #12.
- [x] **2.1** v0/v0.1 status banners added to `blockchain-tee-architecture.md §2, §3, §4` and `serve-and-audit.md §1`.
- [x] **2.2** OTP (v0) vs VVC (v0.1) disambiguated in a new subsection of `blockchain-tee-architecture.md §3`. v0 keeps OTP, v0.1 replaces with VVC (no coexistence) per #6.

### 🚧 Must land before Stage 8 kickoff (issues, not doc edits)

- [ ] **2.3 / #14** Daemon `--parent` flag. Small implementation change; update `docs/manual-test-stage4.md` Test 8 when landed.
- [ ] **4.1 / #17** Fix `cmd_revoke` + self-revoke + revoke-vs-teardown semantics. Update `credential-usage.md:127` and `manual-test-stage4.md` Test 9 when landed.
- [ ] **4.2 / #15** Fix `cmd_run` scope-None handling (minimum: query all stored credentials when `scope = None`). `--env` override can slip to v0.1.
- [ ] **4.4 / #13** Backend refactor — typed identity params + shared `resolve_identity()` + modular `mint_pair_session` / `mint_recover_session`. Also rename "Mock Server Design Principles" → "Backend Design Principles" in `CLAUDE.md`.
- [ ] **6.1** Sync `harness/progress.json` — mark Stage 4 complete, backfill `features.json` for Stages 1-4 or explicitly stop maintaining it.
- [ ] **6.2** Amend `development-stages.md:883` Stage 8 Contract to say "Inputs: Stages 0-4 required; 5-7 deferred" and document `skipped` semantics for the harness.

### 🔜 Nice-to-have cleanup (not blocking)

- [ ] **3.2** One-sentence fix at `serve-and-audit.md §3` header clarifying ~6s = audit-lag not serve-latency. (Partially addressed by §1 banner edit; revisit if §3 still reads misleading.)
- [ ] **3.4** One-sentence fix at `key-security.md:221` — **already applied** (v0 instant vs v0.1 ~6s clarified).
- [ ] **3.3** `tech-brief.md:49` MSK phrasing — add "per-user independent wallet keys held in TEE sealed storage (current); MSK-derived model targeted for v0.1 per #9."
- [ ] **5.6** Add "limitations" section to `wiki/credential-usage.md` linking #14, #15, #16, #17.

### 📦 Deferred to v0.1 or later

- [ ] **1.2 sweep** Full JWT → bearer-token rename (#10). Anchor edits done; remainder in #10.
- [ ] **3.1** Pattern 4 implementation (#5). Banner in place; implementation itself is v0.1.
- [ ] **3.3 full** MSK-derived TEE key model (#9).
- [ ] **4.3** Wallet-optional CLI + aliases (#16). If landed before Stage 8, update Stage 2 docs + `credential-usage.md` + `manual-test-stage4.md`.
- [ ] **5.5** Biometric gate (#11). Post-MVP hardening.

### 📝 New issues worth filing

- [ ] **6.1** "Harness: define `skipped` stage semantics for 5-7 deferral." (harness tooling)
- [ ] **6.3** "Stage 8 scope — confirm Priority A deliverables against the resolved TTL/storage decisions" (audit pass after #12, #13, #15, #17 land).

---

## 7.1 Where sensitive ciphertext lives — on chain vs off chain  (RESOLVED 2026-04-26)

This was Part 4 / Part 7 of the 2026-04-19 inventory's "key contradictions" list — the docs were silent or inconsistent on whether credential ciphertext lives in `pallet-secrets-vault` on chain (per `wiki/blockchain-tee-architecture.md` §1, `wiki/key-security.md` §1, `docs/spec/credential-backend-interface.md` "Mapping to Heima Primitives") or off-chain in S3. The closest-analogous existing pattern is the Stage 6 email pipeline, which puts raw MIME in S3 and only metadata on chain.

| Source | Pre-2026-04-26 claim |
|---|---|
| `wiki/blockchain-tee-architecture.md` §1 row "Credential blobs" | "encrypted ciphertext, on chain in `pallet-secrets-vault`" |
| `wiki/data-classification.md` §1 row "Credential blobs" | "On chain: encrypted ciphertext" |
| `wiki/key-security.md` §1 v0.1 column | "Encrypted blob in Heima TEE (`pallet-secrets-vault`)" |
| `docs/spec/credential-backend-interface.md` Mapping table | `store_credential` → `pallet-secrets-vault::write_secret` |
| `docs/spec/ses-email-architecture.md` §4 + §6 | Email blobs already in S3 (precedent for off-chain) — not extended to credentials |

**Threat-model finding (2026-04-26):** on-chain encrypted-blob storage creates an unbounded harvest-now-decrypt-later window — public + immutable + permanent ciphertext means any future TEE-key compromise leaks all historical data. Splitting the TEE into two enclaves does not fix the consequence axis. The fix has to be (a) move ciphertext off-chain so it isn't publicly observable forever, and (b) rotate per-epoch DEKs with deletion of old ciphertext. Both moves are required; they multiply rather than add. Full argument: [`docs/spec/threat-model-key-custody.md`](./spec/threat-model-key-custody.md).

**Decision (2026-04-26):** Sensitive ciphertext lives **off-chain** in S3 under per-epoch DEKs. Chain holds `(blob_pointer, ciphertext_hash, epoch)` via new `pallet-vault-pointers`. The deprecated `pallet-secrets-vault` design is no longer a target. Forward-secret epoch rotation is the property the previous design did not have.

**Applied to:**
- `docs/spec/threat-model-key-custody.md` — new doc; canonical position.
- `docs/stage8-wip.md` — new Stage 8 operational design (off-chain vault + rotation runbook).
- `docs/spec/plans/development-stages.md` — inserted new Stage 8; renumbered old Stage 8 (memory hygiene) → Stage 9 and old Stage 9 (Heima holding pen) → Stage 10. Parallelization table + change log updated.
- `docs/stage7-wip.md` — added scope-boundary note: Stage 7 ships the isolation primitive only; vault question deferred to Stage 8.
- `docs/spec/credential-backend-interface.md` — superseded banner on the Mapping table; rows for `store_credential` / `read_credential` / `teardown_agent` updated to point at `pallet-vault-pointers` + S3.
- `wiki/blockchain-tee-architecture.md` §1 — superseded banner; on-chain row rewritten to "vault pointers, not blobs"; new `EpochDek` row; new Stage 8 audit extrinsics added.
- `wiki/data-classification.md` §1 — credential-blob row updated to off-chain + per-epoch DEK; doc-level banner.
- `wiki/key-security.md` §1 — v0.1 storage column updated; doc-level banner.
- `wiki/Home.md` — reading-order link to the new threat-model doc; "four rules" wording softened on rules 1 + 2 to align with the new position.
- `docs/spec/ses-email-architecture.md` §16 — cross-reference added; framing the email pipeline as the precedent that Stage 8 generalizes.

**Tracking:** [issue #57](https://github.com/litentry/agentKeys/issues/57) — security finding + remediation roadmap.

**Why this resolution closes Part 7's gap (architectural commitments NOT yet made).**
1. ✅ "Is `pallet-secrets-vault` the final design, or is S3 off-chain fallback planned?" — **No**, the final design is off-chain S3 with chain pointers. Decided.
2. ✅ "Per-request ephemeral key material rotation (forward secrecy at read level)" — addressed via per-epoch DEK rotation; lazy-rotation variant chosen as default.
3. ❓ "TEE-side credential TTL / eviction policy" — partially addressed (DEK destroyed on epoch boundary; blobs lifecycle-deleted). Remaining tunables (epoch cadence, lifecycle TTL) tracked in [`docs/stage8-wip.md`](./stage8-wip.md) §5 open questions.
4. ❓ "MRSIGNER succession pallet spec" — orthogonal; out of scope here.
5. ❓ "TEE-hosted OIDC endpoint (fully sealed)" — orthogonal Stage 7b/future item.

---

## 8. What this doc does NOT cover

- Code-level bugs not cited in an issue or a wiki/plan doc. (Let code review handle those.)
- Open questions in `docs/spec/heima-open-questions.md` — those are gap-check items for Kai, not internal contradictions.
- Copy-editing / wording nits that don't change technical meaning.
- Contradictions inside the `.omc/` state dir (out of scope for product docs).

Maintain this doc alongside `docs/spec/plans/development-stages.md` — when a contradiction is resolved, delete its row and add a commit note explaining which source of truth won.
