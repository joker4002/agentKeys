# Review Guidelines — agentkeys

This is the single source of truth for code review patterns in this repo. The
`claude-code-review.yml` workflow points Claude at this file; human reviewers
should also use it as a checklist.

Background: these patterns were distilled from 15+ PR review cycles in
March-April 2026 where codex repeatedly surfaced the same classes of bug. Each
numbered item below has been a real P1 or P2 finding at least once.

## Writing style for PR comments, commit messages, and docs

Use plain, common English. Short sentences. The reader might be a blockchain
engineer, a Rust engineer, or a non-native English speaker — make every line
land on the first read.

**Avoid these words and phrases** (and anything with the same smell):

- "leverage", "leveraging" — use "use"
- "utilize" — use "use"
- "robust", "comprehensive", "holistic" — say what it actually does
- "streamline", "seamless" — describe the mechanism instead
- "architect a solution", "solutioning" — "design" or "write"
- "delve", "deep dive" — just say "read", "check", "inspect"
- "facilitate" — "lets", "helps", "does"
- "in order to" — "to"
- "at the end of the day", "fundamentally" — cut entirely
- "unlock", "empower" (for software) — say the concrete effect
- "paradigm", "synergy", "holistic approach" — never
- "cutting-edge", "state-of-the-art" — never; just name the tech

**Prefer:**

- Short sentences. 20 words max where possible.
- Named concrete things. "The `get_scope` handler" beats "the scope retrieval
  mechanism".
- Active voice. "This PR fixes X" not "X is fixed by this PR".
- Direct verdicts. "Wrong" / "Correct" / "Blocker" / "Ready to merge". Not
  "may be suboptimal".
- Code over prose. If three lines of code explain it, use them.

When in doubt: would a tired reviewer at 11pm understand this on the first
read? If not, rewrite.

## Tagging conventions

When a PR or issue needs input from people outside the Rust team, tag them
explicitly in the PR description or a comment. The Action will not guess.

| Topic | Tag |
|-------|-----|
| Heima blockchain extrinsic semantics, on-chain storage layout, chain-side identity resolution | `@Kailai-Wang @BillyWooo` |
| TEE / shielding-key lifecycle, Worker runtime integration | `@Kailai-Wang @BillyWooo` |
| Any change to the mock server's extrinsic-mirror contract that the real chain will need to implement | `@Kailai-Wang @BillyWooo` |
| Any design decision that asks "does the real chain do it this way?" | `@Kailai-Wang @BillyWooo` |

Tag in the PR body (for reviewers to see the moment they open the PR) AND in
a comment on the relevant thread (so they get a notification). One-liner is
fine: `cc @Kailai-Wang @BillyWooo — need your call on <specific question>`.

Don't tag them for Rust-only, mock-only, or CLI-only questions — those stay
inside the team.

## Test constraints

- **ALWAYS use `cargo test -p <crate> -- --test-threads=1`.** Tests mutate
  shared process env (HOME, keyring accounts, AGENTKEYS_SESSION_STORE) and
  parallel runs race. This is not negotiable.
- Target only affected crates. `cargo test` on the whole workspace takes 5+
  minutes and masks which crate actually regressed.
- `cargo clippy -p <crate> -- -D warnings` should stay clean.
- When adding FFI code (macOS LAContext, keychain), add both L2 FFI-boundary
  tests behind `#[cfg(target_os = "macos")]` AND a `MockBackend` so the
  non-FFI behavior stays testable on Linux CI.

## Canonical bug patterns

### 1. Cross-wallet credential leak on namespace collisions

**Don't:** use raw user input as a filesystem directory or keyring account
name.

**Do:** sanitize via `sanitize_for_keyring(session_id)` in `session_store.rs`
— ASCII alnum + `-_.` preserved, anything else replaced with `_`, rewrites
suffixed with a SHA-256-derived 8-char hash under the reserved `__agk_`
prefix. `DefaultHasher` is NOT stable across Rust versions; use `sha2`
crate.

Reference: PR #24 v6 P1 + v9, issue #37.

### 2. Nondeterministic daemon session selection

**Don't:** rely on `std::fs::read_dir` order when picking among multiple
`daemon-*` sessions.

**Do:** sort alphabetically via `list_fallback_session_ids` before selecting.
If more than one loadable session exists and no `--session-id` is passed,
error with the candidate list rather than picking arbitrarily.

Reference: PR #24 v1 P1.

### 3. URL encoding via reqwest `.query()`, never raw interpolation

**Don't:**
```rust
let url = format!("/identity/resolve?identity_type=alias&identity_value={}", raw);
```

**Do:**
```rust
let resp = client.get(format!("{backend_url}/identity/resolve"))
    .query(&[("identity_type", "alias"), ("identity_value", raw)])
    .send()
    .await?;
```

Aliases with `+`, `&`, `%`, spaces, plus-addressed emails (`bot+prod@…`)
break under raw interpolation.

Reference: PR #20, PR #22 v1 P2, PR #29.

### 4. Session-token redaction in prompt / log strings

**Don't:** echo `cmd_revoke`'s raw argument into error messages, biometric
prompts, or stderr. The argument may be a live bearer token.

**Do:** pipe user-supplied strings through `redact_prompt_reason()` (in
`biometric/logic.rs`) — strips anything over 40 characters opaque while
preserving short `0x…` wallet addresses.

Reference: PR #27 P2 (session-token leak via biometric prompt), PR #38.

### 5. Wallet comparison must be case-insensitive OR normalize before compare

**Don't:** `session.wallet.0 == target_wallet_str` when `target_wallet_str`
came from user input. EIP-55 checksummed addresses collide with the
backend's lowercase storage.

**Do:** either `eq_ignore_ascii_case` (revoke self-detection pattern in
`cmd_revoke`) OR lowercase before sending the value to `/identity/resolve`
(pattern in PR #22 v3 `resolve_parent_if_set`).

Reference: PR #18 P2, PR #22 v2 P2.

### 6. Session TTL is 30 days uniformly

Master, agent, sandbox — all sessions are 30 days per `docs/wiki/session-token.md`.
Don't introduce per-type TTL splits; they were tried and reverted.

Reference: PR #23.

### 7. Keychain operations must be synchronous

**Don't:** spawn a detached thread to delete a keyring entry. Callers use
the return value to decide what to tell the user, and the CLI often exits
before the background thread runs.

**Do:** use the `try_keyring_save`/`try_keyring_load` pattern — spawn a
thread, wait up to 2 seconds via `recv_timeout`, return a bool. Propagate
failures as `anyhow::Error` from `clear_session`.

Reference: PR #24 v8 P1 (fire-and-forget delete regression).

### 8. Path traversal guards on user-supplied session_id / filename

**Don't:** join user input directly into a filesystem path.

**Do:** sanitize with the pattern from `crates/agentkeys-core/src/session_store.rs::sanitize_for_keyring`.
Reject reserved path components (`""`, `"."`, `".."`) and anything starting
with the reserved `__agk_` rewrite prefix — those are forced through the
hash-suffix path so user inputs can't collide with rewrite outputs.

Reference: PR #24 v2 P2, v6 P1.

### 9. Audit log: DENIED rows for every cross-agent probing path

New `/credential/*` endpoints that gate on `is_owner_of` must insert a
`'denied'` audit row BEFORE returning 403. This keeps cross-agent probing
visible.

Check: `read_credential`, `store_credential`, `list_credentials`,
`teardown_agent` all insert DENIED rows. New endpoints must match.

Reference: PR #19 P2.

### 10. Mock server design principles (from CLAUDE.md)

- **Typed parameters**: every endpoint takes explicit typed inputs (e.g.,
  `identity_type` + `identity_value`). No opaque JSON-blob parsing at
  runtime. Blockchain extrinsics require typed inputs; the mock mirrors
  that.
- **Shared `resolve_identity`**: one utility in `handlers/identity.rs` —
  never inline `if let Alias => ... else if Email => ...` chains per
  handler.
- **Modular handlers**: request-type-specific logic goes in separate
  functions (`mint_pair_session`, `mint_recover_session`). `approve_auth_request`
  is pure dispatch.

Reference: CLAUDE.md → "Mock Server Design Principles".

## Architectural facts to apply

- **Master → agent is strictly one hop.** No grandchildren. `is_owner_of`
  checks a single `parent_token` level and that's sufficient for the
  current model. Reviewers should NOT file tickets about transitive
  ownership unless the session model has grown recursive pairing, which
  it has not. See closed issue #35.
- **No users in production yet.** Pre-launch state. "Preserve pre-#N
  legacy data on upgrade" findings get dismissed because there is no
  legacy field state. When we ship, we'll add dedicated migration commits
  with CHANGELOG entries.
- **Commit message style**: `fix(<crate>): #<issue> — <subject>` or
  `docs(<scope>): <subject>`. Version suffixes `v2`, `v3` etc for
  iterative codex-review fixes on the same PR.

## Scope control

- `bug fix` PRs should NOT include refactors beyond the fix. If the diff
  starts growing new abstractions, flag it as scope creep.
- Don't add feature flags or backwards-compatibility shims unless the
  project has users (see above — it does not).
- Don't write tests that only re-verify framework guarantees (e.g.,
  "tokio spawn returns a JoinHandle"). Test user-visible behavior.

## When codex and Claude disagree

If this repo's automated review (claude-code-action) and a manual codex
review flag contradictory issues on the same line, prefer the pattern in
this doc. If the doc is silent, surface the disagreement in the PR thread
rather than picking a side silently — the author makes the call.
