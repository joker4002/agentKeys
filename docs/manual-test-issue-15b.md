# Manual Test: Issue #15b — `agentkeys scope` CLI command (part 3 of #15)

**Issue:** [litentry/agentKeys#15](https://github.com/litentry/agentKeys/issues/15) (part 3 of 3)

**Branch:** `fix/issue-15b`

## What this ships

Adds `agentkeys scope` for editing a child agent's scope. Follow-up to PR #19 (parts 1+2 — `run` for master sessions + `--env`).

```
agentkeys scope <AGENT> --add <SERVICE> [--add ...]
agentkeys scope <AGENT> --remove <SERVICE> [--remove ...]
agentkeys scope <AGENT> --set <SERVICE,SERVICE,...>
agentkeys scope <AGENT> --list
```

AGENT = `0x...` wallet, alias, or email (same resolver as `agentkeys store`/`read`/`run`).

Under the hood:
1. Read current scope for the target agent.
2. Compute new scope (add/remove/set).
3. Open an `AuthRequest::ScopeChange` from the master session.
4. Auto-approve with the master session.
5. Print the resulting scope.

## Preconditions

```bash
cd ~/Projects/agentkeys
export AGENTKEYS_SESSION_STORE=file
export HOME_SANDBOX=$(mktemp -d)
export HOME=$HOME_SANDBOX
BACKEND=http://127.0.0.1:8090
cargo build --release -p agentkeys-cli -p agentkeys-mock-server
CLI=$(pwd)/target/release/agentkeys
```

## Case 1 — `--add` appends services

```bash
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

$CLI --backend $BACKEND init --mock-token scope-add
MASTER=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")
# Pair a child (via daemon flow or test harness); record CHILD wallet.
CHILD=<resolved from pair flow>

# Start with empty scope, add one service:
$CLI --backend $BACKEND scope --agent $CHILD --add openrouter
# Expected: "Scope updated for agent 0x... New services: [openrouter]"

$CLI --backend $BACKEND scope --agent $CHILD --list
# Expected output includes: services=[openrouter]

# Add a second:
$CLI --backend $BACKEND scope --agent $CHILD --add anthropic
$CLI --backend $BACKEND scope --agent $CHILD --list
# Expected: services=[anthropic, openrouter] (sorted)

kill $MOCK_PID
```

## Case 2 — `--remove` drops services

```bash
rm -rf $HOME_SANDBOX/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

$CLI --backend $BACKEND init --mock-token scope-remove
# (pair a child with scope=[a, b, c])
CHILD=...

$CLI --backend $BACKEND scope --agent $CHILD --remove a
$CLI --backend $BACKEND scope --agent $CHILD --list
# Expected: services=[b, c]

$CLI --backend $BACKEND scope --agent $CHILD --remove b --remove c
$CLI --backend $BACKEND scope --agent $CHILD --list
# Expected: services=[]

kill $MOCK_PID
```

## Case 3 — `--set` replaces

```bash
rm -rf $HOME_SANDBOX/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

$CLI --backend $BACKEND init --mock-token scope-set
# (pair a child with scope=[openrouter])
CHILD=...

$CLI --backend $BACKEND scope --agent $CHILD --set anthropic,github
$CLI --backend $BACKEND scope --agent $CHILD --list
# Expected: services=[anthropic, github]

kill $MOCK_PID
```

## Case 4 — conflict between `--add` / `--set`

```bash
$CLI --backend $BACKEND scope --agent $CHILD --add x --set y 2>&1 | head -3
# Expected: error — "--set is mutually exclusive with --add/--remove"
# Child wallet state unchanged.
```

## Case 5 — ownership enforcement

```bash
# User A owns child C. User B tries to scope C → 403.
# ...
```

## Cleanup

```bash
rm -rf "$HOME_SANDBOX"
unset HOME_SANDBOX AGENTKEYS_SESSION_STORE
```

## Cross-references

- `crates/agentkeys-cli/src/lib.rs` — `cmd_scope`
- `crates/agentkeys-cli/src/main.rs` — `Commands::Scope`
- `crates/agentkeys-mock-server/src/handlers/auth_request.rs` — `mint_scope_change_session` (fleshed out by this PR)
- Related: PR #19 (parts 1+2), PR #20 (`resolve_agent` helper).
- `AuthRequestType::ScopeChange` already exists in `agentkeys-types`.
