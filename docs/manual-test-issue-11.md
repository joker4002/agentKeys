# Manual Test: Issue #11 — Biometric gate for high-security master CLI actions

**Issue:** [litentry/agentKeys#11](https://github.com/litentry/agentKeys/issues/11)

**Branch:** `fix/issue-11`

## Scope

Touch ID / device-owner-auth gate on macOS for three high-security master commands:
- `agentkeys approve <pair-code>`
- `agentkeys revoke [<agent>]`
- `agentkeys teardown <agent>`

Linux and Windows gates are deferred to follow-up issues.

## Preconditions

- macOS with Touch ID enabled (MacBook Pro with Touch Bar, MacBook Air M-series, any Apple Silicon Mac with external Touch-ID-capable keyboard).
- Rust toolchain.

## Setup

```bash
cd ~/Projects/agentkeys
export AGENTKEYS_SESSION_STORE=file
export HOME_SANDBOX=$(mktemp -d)
export HOME=$HOME_SANDBOX
BACKEND=http://127.0.0.1:8090
cargo build --release -p agentkeys-cli -p agentkeys-mock-server
CLI=$(pwd)/target/release/agentkeys
```

## Case 1 — Touch ID prompt on `approve`

```bash
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

$CLI --backend $BACKEND init --mock-token bio-approve
# TODO: set up a pair request via daemon+pair flow; then:
# $CLI --backend $BACKEND approve <pair-code>
# Expected: Touch ID dialog pops up with "Approve pair request (creates a new child session)".
# Press Touch ID → command proceeds.
# Cancel → command aborts with a clean error.

kill $MOCK_PID
```

## Case 2 — `revoke` gate

```bash
rm -f $HOME/.agentkeys/master/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

$CLI --backend $BACKEND init --mock-token bio-revoke
WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")
$CLI --backend $BACKEND revoke
# Expected: Touch ID dialog: "Revoke session(s) for (current session)".
# Approve → session revoked + local session wiped.
# Cancel → command aborts, session intact.

kill $MOCK_PID
```

## Case 3 — `teardown` gate

```bash
rm -f $HOME/.agentkeys/master/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

$CLI --backend $BACKEND init --mock-token bio-teardown
WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")
$CLI --backend $BACKEND teardown $WALLET 2>&1
# Expected: Touch ID dialog: "Tear down agent 0x... (deletes all credentials)".
# Approve → all credentials + sessions deleted.
# Cancel → command aborts.

kill $MOCK_PID
```

## Case 4 — `AGENTKEYS_BIOMETRIC=off` escape hatch (CI/tests)

```bash
export AGENTKEYS_BIOMETRIC=off
rm -f $HOME/.agentkeys/master/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

$CLI --backend $BACKEND init --mock-token bio-off
$CLI --backend $BACKEND revoke
# Expected: NO Touch ID prompt. Command proceeds as if biometric not required.
unset AGENTKEYS_BIOMETRIC

kill $MOCK_PID
```

## Case 5 — non-macOS stub (test on Linux / CI)

On non-macOS platforms, the fallback is a stdin y/n prompt. Without a TTY, `AGENTKEYS_ALLOW_NO_BIOMETRIC=1` is required, or the command aborts. This keeps headless CI from silently skipping the gate.

## Cleanup

```bash
rm -rf "$HOME_SANDBOX"
unset HOME_SANDBOX AGENTKEYS_SESSION_STORE AGENTKEYS_BIOMETRIC AGENTKEYS_ALLOW_NO_BIOMETRIC
```

## Cross-references

- `crates/agentkeys-cli/src/biometric.rs` — new module
- `crates/agentkeys-cli/src/lib.rs` — gated commands: cmd_approve, cmd_revoke, cmd_teardown
- `crates/agentkeys-cli/Cargo.toml` — platform-conditional `security-framework` dep
- Deferred follow-up: Linux (fprintd/polkit) and Windows (Hello) gates — separate issues.
