# Manual Test: Issue #12 — Daemon OS keychain (multi-platform)

**Issue:** [litentry/agentKeys#12](https://github.com/litentry/agentKeys/issues/12)

**Branch:** `fix/issue-12`

## What changed

- `session_store` moved from `agentkeys-cli` into `agentkeys-core` and now takes a `session_id` parameter for namespacing.
- CLI uses `session_id = "master"`.
- Daemon uses `session_id = format!("daemon-{}", wallet)` after pair/recover; falls back to `"daemon-pending"` before the wallet is known.
- Keychain entry: `service="agentkeys", account=<session_id>`.
- File fallback: `~/.agentkeys/<session_id>/session.json`.
- `AGENTKEYS_SESSION_STORE=file` still forces file-only mode.

## Case 1 — master + daemon coexist on macOS Keychain

```bash
export HOME_SANDBOX=$(mktemp -d)
export HOME=$HOME_SANDBOX
# Note: on macOS without AGENTKEYS_SESSION_STORE=file, the keychain is used.
BACKEND=http://127.0.0.1:8090
cd ~/Projects/agentkeys
cargo build --release -p agentkeys-cli -p agentkeys-mock-server -p agentkeys-daemon
CLI=$(pwd)/target/release/agentkeys
DAEMON=$(pwd)/target/release/agentkeys-daemon

cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

# Master session
$CLI --backend $BACKEND init --mock-token master-keychain-test
security find-generic-password -s agentkeys -a master 2>&1 | grep "class:"
# Expected: class: "genp" (the keychain entry exists)

# Start daemon (after pairing, daemon will store as daemon-<wallet>)
$DAEMON --backend $BACKEND &
DAEMON_PID=$!; sleep 2

# Both entries should coexist
security find-generic-password -s agentkeys -a master 2>&1 | head -1
security find-generic-password -s agentkeys -a daemon-pending 2>&1 | head -1   # or daemon-<wallet> after pair

kill $DAEMON_PID $MOCK_PID
```

## Case 2 — two daemons do not collide (file-only for portability)

```bash
export AGENTKEYS_SESSION_STORE=file
rm -rf $HOME/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

# First daemon — pretend wallet A
mkdir -p $HOME/.agentkeys/daemon-0xAAAA
echo '{"token":"tok-a","wallet":"0xAAAA","scope":null,"created_at":0,"ttl_seconds":3600}' > $HOME/.agentkeys/daemon-0xAAAA/session.json

# Second daemon — pretend wallet B
mkdir -p $HOME/.agentkeys/daemon-0xBBBB
echo '{"token":"tok-b","wallet":"0xBBBB","scope":null,"created_at":0,"ttl_seconds":3600}' > $HOME/.agentkeys/daemon-0xBBBB/session.json

# Both files exist; no overwrite
ls -la $HOME/.agentkeys/daemon-0xAAAA/session.json $HOME/.agentkeys/daemon-0xBBBB/session.json
# Expected: both listed, independent 0600 files.

kill $MOCK_PID
```

## Case 3 — AGENTKEYS_SESSION_STORE=file override on macOS

```bash
export AGENTKEYS_SESSION_STORE=file
rm -rf $HOME_SANDBOX/.agentkeys
$CLI --backend $BACKEND init --mock-token file-override

# Keychain should NOT have been touched
security find-generic-password -s agentkeys -a master 2>&1 | head -1
# Expected: "could not be found"

test -f $HOME_SANDBOX/.agentkeys/master/session.json && echo "file created"
# Expected: "file created"
```

## Cleanup

```bash
security delete-generic-password -s agentkeys -a master 2>/dev/null || true
security delete-generic-password -s agentkeys -a daemon-pending 2>/dev/null || true
# Delete any daemon-<wallet> entries you created during testing.
rm -rf "$HOME_SANDBOX"
unset HOME_SANDBOX AGENTKEYS_SESSION_STORE
```

## Cross-references

- `crates/agentkeys-core/src/session_store.rs` — new shared module
- `crates/agentkeys-cli/src/lib.rs` — uses `"master"` session_id
- `crates/agentkeys-daemon/src/main.rs`, `pairing.rs` — uses `daemon-<wallet>` session_id
- `docs/arch.md` — daemon session storage section update (follow-up doc pass)
- `wiki/key-security.md` — storage table update (follow-up)
- Related: #14 (daemon --parent), #3 (Stage 8 memory hygiene)
