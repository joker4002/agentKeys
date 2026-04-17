# Manual Test: Issue #16 — wallet-optional CLI + identity aliases

**Issue:** [litentry/agentKeys#16](https://github.com/litentry/agentKeys/issues/16)

**Branch:** `fix/issue-16`

## What changed

- `agentkeys store`, `read`, `run` — the agent is now specified via an optional `--agent <WALLET|ALIAS|EMAIL>` flag. When omitted, defaults to the current session wallet. (Note: it is a flag rather than a leading positional because clap cannot unambiguously mix an optional leading positional with required trailing positionals — see `agentkeys store --help` for the rationale.)
- Identity aliases and emails resolve to wallet addresses via `/identity/resolve` on the backend. Any `--agent` value that does NOT start with `0x` is treated as an identity and resolved; otherwise it is taken as a wallet address literally.
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
# (on this branch the command succeeds; --agent defaults to the session wallet.)

kill $MOCK_PID
```

## Verify the fix (on `fix/issue-16`)

### Case 1 — default wallet for store / read / run

```bash
rm -rf $HOME/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token default-wallet
WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")

$BIN --backend $BACKEND store openrouter sk-default-test
# Expected: "Stored credential for agent=0x... service=openrouter"

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
rm -rf $HOME/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token alias-test
WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")

$BIN --backend $BACKEND link $WALLET --alias my-bot
# Expected: "Linked agent=0x... alias=my-bot"

$BIN --backend $BACKEND store --agent my-bot openrouter sk-alias-resolve
# Expected: "Stored credential for agent=0x... service=openrouter"

$BIN --backend $BACKEND read --agent my-bot openrouter
# Expected: "sk-alias-resolve"

kill $MOCK_PID
```

### Case 3 — unknown identity error

```bash
rm -rf $HOME/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token unknown-identity
$BIN --backend $BACKEND store --agent not-an-alias openrouter sk-x 2>&1 | head -3
# Expected: "unknown identity 'not-an-alias'. Use `agentkeys link` to create an alias or pass the 0x... wallet directly."

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
