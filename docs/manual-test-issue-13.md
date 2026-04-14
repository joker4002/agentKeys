# Manual Test: Issue #13 — Backend refactor (typed params, shared resolve_identity, modular handlers)

**Issue:** [litentry/agentKeys#13](https://github.com/litentry/agentKeys/issues/13)

**Branch:** `fix/issue-13`

## Nature of the change

Pure refactor. **No user-visible behavior change.** The mock server's API surface is preserved; the internal organization is brought into line with CLAUDE.md's "Mock Server Design Principles":

1. `resolve_identity(db, identity_type, identity_value)` — single shared utility in `handlers/identity.rs`. Replaces the two inline copies in `handlers/session.rs` and `handlers/auth_request.rs`.
2. `auth_requests` table carries explicit `identity_type` + `identity_value` columns for Recover requests — no more JSON-blob parsing at approve time.
3. `approve_auth_request` dispatches to `mint_pair_session`, `mint_recover_session`, `mint_scope_change_session` instead of inlining per-request-type logic.

## How to verify

Because this PR has no user-facing behavior change, the verification is: **every existing flow still works.**

### Run the full test suite

```bash
cd ~/Projects/agentkeys
cargo test -p agentkeys-core -p agentkeys-cli -p agentkeys-mock-server
```
All pre-existing tests must pass. The PR body lists the before/after pass counts.

### Run Stage-4 manual test end-to-end

```bash
# Follow docs/manual-test-stage4.md top-to-bottom.
# Test 1–10 should pass exactly as on main.
# The refactor should not affect any user-observable response.
```

### Targeted Recover flow check (the refactor's hot path)

```bash
export AGENTKEYS_SESSION_STORE=file
export HOME_SANDBOX=$(mktemp -d)
export HOME=$HOME_SANDBOX
BACKEND=http://127.0.0.1:8090
cargo build --release -p agentkeys-cli -p agentkeys-mock-server
BIN=$(pwd)/target/release/agentkeys

cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

# Establish a wallet + link an alias
$BIN --backend $BACKEND init --mock-token recover-refactor
WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")
$BIN --backend $BACKEND link $WALLET --alias my-bot

# Revoke the session (simulate lost device)
$BIN --backend $BACKEND revoke
# Expected: local session wiped.

# Recover by alias — exercises the refactored mint_recover_session + typed fields
$BIN --backend $BACKEND recover my-bot --method passkey
# Expected: session restored for the same wallet (0x...).

test -f $HOME/.agentkeys/session.json && echo "recovered"
# Expected: "recovered"

RECOVERED_WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")
[ "$WALLET" = "$RECOVERED_WALLET" ] && echo "same wallet"
# Expected: "same wallet"

kill $MOCK_PID
```

## Cleanup

```bash
rm -rf "$HOME_SANDBOX"
```

## Cross-references

- `crates/agentkeys-mock-server/src/handlers/identity.rs` — new `resolve_identity` public function
- `crates/agentkeys-mock-server/src/handlers/auth_request.rs` — three new `mint_*_session` functions; handler now dispatches
- `crates/agentkeys-mock-server/src/handlers/session.rs` — `recover_session` now calls shared `resolve_identity`
- `crates/agentkeys-mock-server/src/db.rs` — `auth_requests` table migration adds `identity_type` + `identity_value` columns
- CLAUDE.md > "Mock Server Design Principles" — the rules this PR brings the code into line with
