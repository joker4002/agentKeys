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

`AGENT` is a positional argument: `0x...` wallet, alias, or email (same resolver as `agentkeys store --agent`/`read --agent`/`run --agent`).

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
cargo build --release -p agentkeys-cli -p agentkeys-mock-server -p agentkeys-daemon
CLI=$(pwd)/target/release/agentkeys
DAEMON=$(pwd)/target/release/agentkeys-daemon
```

## Helper: pair a child

All scope cases operate against a *paired* child agent. Use this helper to pair one:

```bash
pair_child() {
  local token="$1"
  "$CLI" --backend $BACKEND init --mock-token "$token" >&2
  local master
  master=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")
  "$DAEMON" --backend $BACKEND --parent "$master" > /tmp/daemon-$$.log 2>&1 &
  local dpid=$!
  sleep 3
  local code
  code=$(grep -oE "Pair code: [A-Z0-9]+" /tmp/daemon-$$.log | head -1 | awk '{print $3}')
  "$CLI" --backend $BACKEND approve "$code" --yes >&2
  sleep 2
  jq -r .wallet "$(ls $HOME/.agentkeys/daemon-0x*/session.json | head -1)"
  kill $dpid 2>/dev/null || true
}
```

## Case 1 — `--add` appends services

```bash
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

CHILD=$(pair_child scope-add)

# Start with empty scope, add one service:
$CLI --backend $BACKEND scope "$CHILD" --add openrouter
# Expected: "Scope updated for agent 0x... New services: [openrouter]"

$CLI --backend $BACKEND scope "$CHILD" --list
# Expected:
#   Scope for agent 0x...:
#     services: [openrouter]
#     read_only: false

# Add a second:
$CLI --backend $BACKEND scope "$CHILD" --add anthropic
$CLI --backend $BACKEND scope "$CHILD" --list
# Expected: services: [anthropic, openrouter]    (sorted)

kill $MOCK_PID
```

## Case 2 — `--remove` drops services

```bash
rm -rf $HOME_SANDBOX/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

CHILD=$(pair_child scope-remove)
$CLI --backend $BACKEND scope "$CHILD" --set a,b,c   # seed with three services

$CLI --backend $BACKEND scope "$CHILD" --remove a
$CLI --backend $BACKEND scope "$CHILD" --list
# Expected: services: [b, c]

$CLI --backend $BACKEND scope "$CHILD" --remove b --remove c
$CLI --backend $BACKEND scope "$CHILD" --list
# Expected: services: []

kill $MOCK_PID
```

## Case 3 — `--set` replaces

```bash
rm -rf $HOME_SANDBOX/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

CHILD=$(pair_child scope-set)

$CLI --backend $BACKEND scope "$CHILD" --set anthropic,github
$CLI --backend $BACKEND scope "$CHILD" --list
# Expected: services: [anthropic, github]

kill $MOCK_PID
```

## Case 4 — conflict between `--add` / `--set`

```bash
$CLI --backend $BACKEND scope "$CHILD" --add x --set y 2>&1 | head -3
# Expected:
#   Error: --set is mutually exclusive with --add and --remove. Use one or the other.
# Child wallet state unchanged.
```

## Case 5 — ownership enforcement

```bash
rm -rf $HOME_SANDBOX/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!; sleep 1

# User A owns child C
A_CHILD=$(pair_child user-a-scope)

# User B takes over the local session (different mock token → different master wallet)
$CLI --backend $BACKEND init --mock-token user-b-scope

# User B tries to scope A's child — backend enforces ownership
$CLI --backend $BACKEND scope "$A_CHILD" --add openrouter 2>&1 | head -5
# Expected:
#   Error: DENIED
#     session does not own the target wallet

kill $MOCK_PID
```

## Cleanup

```bash
rm -rf "$HOME_SANDBOX"
unset HOME_SANDBOX AGENTKEYS_SESSION_STORE
```

## Cross-references

- `crates/agentkeys-cli/src/lib.rs` — `cmd_scope`
- `crates/agentkeys-cli/src/main.rs` — `Commands::Scope { agent: String, add, remove, set, list }` (positional `agent`)
- `crates/agentkeys-mock-server/src/handlers/auth_request.rs` — `mint_scope_change_session`
- Related: PR #19 (parts 1+2), PR #20 (`resolve_agent` helper).
- `AuthRequestType::ScopeChange` already exists in `agentkeys-types`.
