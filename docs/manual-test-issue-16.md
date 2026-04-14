# Manual Test: Issue #16 — wallet-optional CLI + identity aliases

**Issue:** [litentry/agentKeys#16](https://github.com/litentry/agentKeys/issues/16)

**Branch:** `fix/issue-16`

## What changed

- `agentkeys store`, `read`, `run` — `agent` positional is now optional. When omitted, defaults to the current session wallet from the keychain.
- Identity aliases and emails now resolve to wallet addresses via `/identity/resolve` on the backend. Any first arg that does NOT start with `0x` is treated as an identity and resolved; otherwise it's taken as a wallet address literally.
- Unknown alias → clean error `"unknown identity '<arg>'. Use \`agentkeys link\` to create an alias or pass the 0x... wallet directly."`

## Preconditions

```bash
cd ~/Projects/agentkeys
export AGENTKEYS_SESSION_STORE=file
export HOME_SANDBOX=$(mktemp -d)
export HOME=$HOME_SANDBOX
BACKEND=http://127.0.0.1:8090
cargo build --release -p agentkeys-cli -p agentkeys-mock-server
BIN=$(pwd)/target/release/agentkeys
```

## Reproduce the bug (on `main`)

```bash
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token default-wallet-repro
$BIN --backend $BACKEND store openrouter sk-or-1 2>&1 | head -3
# Expected (on main): error — missing required argument <AGENT>
# (on this branch the command succeeds; the agent defaults to the session wallet.)

kill $MOCK_PID
```

## Verify the fix (on `fix/issue-16`)

### Case 1 — default wallet for store / read / run

```bash
rm -f $HOME/.agentkeys/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token default-wallet
WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")

$BIN --backend $BACKEND store openrouter sk-default-test
# Expected: "Credential stored"

$BIN --backend $BACKEND read openrouter
# Expected: "sk-default-test"

$BIN --backend $BACKEND run -- printenv OPENROUTER_API_KEY
# Expected: "sk-default-test"

# The explicit wallet form still works (via --agent flag) and targets the same wallet:
$BIN --backend $BACKEND read --agent $WALLET openrouter
# Expected: "sk-default-test"

kill $MOCK_PID
```

### Case 2 — alias resolution

```bash
rm -f $HOME/.agentkeys/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token alias-test
WALLET=$(jq -r .wallet "$HOME/.agentkeys/session.json")

$BIN --backend $BACKEND link $WALLET --alias my-bot
# Expected: "Linked alias my-bot → 0x..."

$BIN --backend $BACKEND store --agent my-bot openrouter sk-alias-resolve
# Expected: "Credential stored"

$BIN --backend $BACKEND read --agent my-bot openrouter
# Expected: "sk-alias-resolve"

kill $MOCK_PID
```

### Case 3 — unknown identity error

```bash
rm -f $HOME/.agentkeys/session.json
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token unknown-identity
$BIN --backend $BACKEND store --agent not-an-alias openrouter sk-x 2>&1 | head -3
# Expected: error containing "unknown identity 'not-an-alias'"

kill $MOCK_PID
```

## Cleanup

```bash
rm -rf "$HOME_SANDBOX"
unset HOME_SANDBOX AGENTKEYS_SESSION_STORE
```

## Cross-references

- `crates/agentkeys-cli/src/main.rs` — `agent: Option<String>` on Store / Read / Run
- `crates/agentkeys-cli/src/lib.rs` — `resolve_agent` helper
- `crates/agentkeys-core/src/backend.rs` — `CredentialBackend::resolve_identity` trait method
- `docs/contradictions.md` §4.3 — will move to RESOLVED when this lands
- Related: #17 (revoke already supports optional + wallet form), #15 (run now supports optional)
