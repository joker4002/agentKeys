# Manual Test: Issue #17 — revoke command

**Issue:** [litentry/agentKeys#17](https://github.com/litentry/agentKeys/issues/17) — Fix revoke command: broken lookup + clarify revoke vs teardown semantics.

**Branch:** `fix/issue-17`

## What changed

On `main` (`f59c3803`), `agentkeys revoke <wallet>` always returned `"target session not found"` — `cmd_revoke` passed the wallet address as the session token, so the backend's `WHERE token = ?1` lookup never matched.

This PR introduces two forms:

| Form | Purpose |
|---|---|
| `agentkeys revoke` (no args) | Self-revoke: invalidate the current session on the backend **and** wipe the local keychain/file entry. Run `agentkeys init` again to re-pair. |
| `agentkeys revoke <wallet>` | Revoke all active sessions for the given wallet (after backend-enforced ownership check). Credentials survive — use `agentkeys teardown` to delete them too. |

Backend path: `POST /session/revoke` now accepts **either** `target_session` (token, existing) **or** `target_wallet` (new) — exactly one. A new trait method `CredentialBackend::revoke_by_wallet(session, target_wallet)` drives the wallet form.

## Preconditions

- Rust toolchain (`cargo --version` ≥ 1.80).
- `jq` installed.
- No mock server already running on `127.0.0.1:8090`.
- Clean shell: `unset AGENTKEYS_SESSION` (if set from other tests).
- Working directory: `~/Projects/agentkeys`.

## Setup

```bash
cd ~/Projects/agentkeys
export AGENTKEYS_SESSION_STORE=file         # skip the OS keychain for deterministic testing
export HOME_SANDBOX=$(mktemp -d)
export HOME=$HOME_SANDBOX                   # sandboxes ~/.agentkeys/session.json
BACKEND=http://127.0.0.1:8090

cargo build --release -p agentkeys-cli -p agentkeys-mock-server
BIN=$(pwd)/target/release/agentkeys
```

## Reproduce the bug (on `main`)

```bash
jj new main -m "repro issue #17"            # or git switch main, if using git
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token repro-17
WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")
$BIN --backend $BACKEND revoke "$WALLET"
# Expected (BROKEN): error containing "target session not found"

kill $MOCK_PID
jj abandon @                                # back to fix/issue-17 branch
```

## Verify the fix (on `fix/issue-17`)

### Case 1 — self-revoke

```bash
rm -f $HOME/.agentkeys/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token self-revoke-test
# Expected: "Session initialized for wallet=0x..." (absolute path visible)

test -f $HOME/.agentkeys/session.json && echo "session file exists"
# Expected: "session file exists"

$BIN --backend $BACKEND revoke
# Expected output (single line): "Revoked current session for wallet=0x.... Local session wiped. Run `agentkeys init` to re-pair."

test -f $HOME/.agentkeys/session.json || echo "session file wiped"
# Expected: "session file wiped"

# Follow-up: any subsequent command must fail with the "no session" error
$BIN --backend $BACKEND read 0xdeadbeef openrouter 2>&1 | head -3
# Expected: error containing "load session (run `agentkeys init` first)"

kill $MOCK_PID
```

### Case 2 — revoke by wallet (child agent / multi-session)

```bash
rm -f $HOME/.agentkeys/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token by-wallet-test
WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")

$BIN --backend $BACKEND revoke "$WALLET"
# Expected: "Revoked agent=0x..."

# Post-revoke: reading against the old session must fail (session row flipped revoked=1)
$BIN --backend $BACKEND read "$WALLET" openrouter 2>&1 | head -3
# Expected: error — session revoked / DENIED (exact text depends on backend error surface)

kill $MOCK_PID
```

### Case 3 — error path (no session)

```bash
rm -f $HOME/.agentkeys/session.json

$BIN --backend $BACKEND revoke 2>&1 | head -3
# Expected: error containing "load session (run `agentkeys init` first)"
```

### Case 4 — ownership check

```bash
rm -f $HOME/.agentkeys/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

# User A inits
$BIN --backend $BACKEND init --mock-token user-a
A_WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")

# User B inits (different mock token → different wallet; overwrites local session)
$BIN --backend $BACKEND init --mock-token user-b
B_WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")

# User B tries to revoke user A's wallet — backend rejects
$BIN --backend $BACKEND revoke "$A_WALLET" 2>&1 | head -3
# Expected: permission-denied / 403 error (not "target session not found")

kill $MOCK_PID
```

## Cleanup

```bash
rm -rf "$HOME_SANDBOX"
unset HOME_SANDBOX AGENTKEYS_SESSION_STORE
```

## Cross-references

- Bug source: `crates/agentkeys-cli/src/lib.rs` — `cmd_revoke` (before PR: line 203; after PR: same file, new Option<&str> signature)
- Backend extension: `crates/agentkeys-mock-server/src/handlers/session.rs` — `revoke_session` (now dual-input)
- Trait addition: `crates/agentkeys-core/src/backend.rs` — `revoke_by_wallet`
- Stage 4 manual test updated: `docs/manual-test-stage4.md` Test 9 (BROKEN/SKIPPED caveats removed)
- Canonical usage doc updated: `wiki/credential-usage.md` — revoke vs teardown table added
- Contradictions tracker updated: `docs/contradictions.md` §4.1 marked RESOLVED once PR merges
- Related (not in this PR): [#16](https://github.com/litentry/agentKeys/issues/16) (identity aliases for revoke target)
