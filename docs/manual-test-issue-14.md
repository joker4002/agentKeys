# Manual Test: Issue #14 — Daemon `--parent` flag

**Issue:** [litentry/agentKeys#14](https://github.com/litentry/agentKeys/issues/14)

**Branch:** `fix/issue-14`

## What changed

Daemon now accepts `--parent <ALIAS|WALLET>` which binds pair requests to a specific master. The backend refuses approvals from any other master. Without `--parent` the existing first-come-first-served behavior is preserved.

## Preconditions

```bash
cd ~/Projects/agentkeys
export AGENTKEYS_SESSION_STORE=file
export HOME_SANDBOX=$(mktemp -d)
export HOME=$HOME_SANDBOX
BACKEND=http://127.0.0.1:8090
cargo build --release -p agentkeys-cli -p agentkeys-mock-server -p agentkeys-daemon
CLI=$(pwd)/target/release/agentkeys
DAEMON=$(pwd)/target/release/agentkeys-daemon
```

## Case 1 — daemon bound to a specific master via wallet

```bash
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

# Set up two masters
$CLI --backend $BACKEND init --mock-token master-a
A_WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")
mv "$HOME/.agentkeys/session.json" "$HOME/.agentkeys/session-a.json"

$CLI --backend $BACKEND init --mock-token master-b
B_WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")
mv "$HOME/.agentkeys/session.json" "$HOME/.agentkeys/session-b.json"

# Start daemon bound to master A
cp "$HOME/.agentkeys/session-a.json" "$HOME/.agentkeys/session.json"
$DAEMON --backend $BACKEND --parent "$A_WALLET" &
DAEMON_PID=$!
sleep 1

# Master B tries to approve the pair request → rejected
# (Expected: approve returns permission-denied / not-bound-to-this-master)

kill $DAEMON_PID $MOCK_PID
```

## Case 2 — daemon bound via alias

```bash
rm -f $HOME/.agentkeys/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$CLI --backend $BACKEND init --mock-token master-aliased
WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")
$CLI --backend $BACKEND link $WALLET --alias office-mac

$DAEMON --backend $BACKEND --parent office-mac &
DAEMON_PID=$!
sleep 1
# Expected: daemon resolves "office-mac" to $WALLET, binds pair request.

kill $DAEMON_PID $MOCK_PID
```

## Case 3 — no `--parent` (backward compatible)

```bash
rm -f $HOME/.agentkeys/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$CLI --backend $BACKEND init --mock-token legacy-flow
$DAEMON --backend $BACKEND &
DAEMON_PID=$!
sleep 1
# Expected: pair request has no parent_wallet; any master can claim (existing behavior).

kill $DAEMON_PID $MOCK_PID
```

## Cleanup

```bash
rm -rf "$HOME_SANDBOX"
```

## Cross-references

- `crates/agentkeys-daemon/src/main.rs` — new `--parent` clap arg
- `crates/agentkeys-daemon/src/pairing.rs` — threads parent_wallet through
- `crates/agentkeys-core/src/backend.rs` — `open_auth_request` signature extended with `parent_wallet: Option<&WalletAddress>`
- `docs/manual-test-stage4.md` Test 8 — can be simplified to use `--parent` instead of raw curl once this lands (follow-up docs pass)
- Related: #13 (backend refactor — trait change stacks on top)
