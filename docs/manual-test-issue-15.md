# Manual Test: Issue #15 (Parts 1+2) — `agentkeys run` for master sessions + `--env` override

**Issue:** [litentry/agentKeys#15](https://github.com/litentry/agentKeys/issues/15) — CLI `run` command broken for master sessions + missing scope edit and `--env` flag.

**Branch:** `fix/issue-15`

**PR scope:** Parts 1 (master session support) and 2 (`--env` flag). Part 3 (scope-edit CLI command) is tracked as story `fix-15b` in `.omc/prd.json` and will ship in a follow-up PR.

## What changed

On `main`, master sessions (`scope: None`) silently injected nothing into child processes via `agentkeys run` because `cmd_run` relied exclusively on `session.scope.services`. This blocked Test 9 of the stage-4 manual test.

This PR:
- Adds `CredentialBackend::list_credentials(session, agent_id)` trait method + HTTP endpoint `GET /credential/list?agent_id=<w>` (ownership-enforced).
- `cmd_run` now falls back to `list_credentials` when `session.scope.is_none()` and injects all stored credentials.
- Adds `--env KEY=service` flag (repeatable) that maps explicit env-var names to services — an escape hatch for services whose canonical env var doesn't follow the `SERVICE_API_KEY` convention (e.g. GitHub → `GITHUB_TOKEN`).

## Preconditions

- Rust toolchain (`cargo --version` ≥ 1.80).
- `jq` installed.
- No mock server running on `127.0.0.1:8090`.
- Working dir: `~/Projects/agentkeys`.

## Setup

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

$BIN --backend $BACKEND init --mock-token run-repro
WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")
$BIN --backend $BACKEND store --agent $WALLET openrouter sk-or-v1-repro

$BIN --backend $BACKEND run --agent $WALLET -- printenv OPENROUTER_API_KEY
# Expected (on main, BROKEN): empty — master session, scope=None, nothing injected

kill $MOCK_PID
```

## Verify the fix (on `fix/issue-15`)

### Case 1 — master session injects all stored credentials

```bash
rm -rf $HOME/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token master-inject
WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")

$BIN --backend $BACKEND store --agent $WALLET openrouter sk-openrouter-value
$BIN --backend $BACKEND store --agent $WALLET anthropic  sk-anthropic-value

$BIN --backend $BACKEND run --agent $WALLET -- printenv OPENROUTER_API_KEY
# Expected: "sk-openrouter-value"

$BIN --backend $BACKEND run --agent $WALLET -- printenv ANTHROPIC_API_KEY
# Expected: "sk-anthropic-value"

# Both stored keys are injected in a single invocation:
$BIN --backend $BACKEND run --agent $WALLET -- sh -c 'echo "OR=$OPENROUTER_API_KEY AN=$ANTHROPIC_API_KEY"'
# Expected: "OR=sk-openrouter-value AN=sk-anthropic-value"

kill $MOCK_PID
```

### Case 2 — `--env` flag overrides default naming

```bash
rm -rf $HOME/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token env-override
WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")

$BIN --backend $BACKEND store --agent $WALLET github ghp_testtoken

$BIN --backend $BACKEND run --agent $WALLET --env GITHUB_TOKEN=github -- printenv GITHUB_TOKEN
# Expected: "ghp_testtoken"

# `--env` is supplement-not-replace: the default-named env var (GITHUB_API_KEY) is
# still set alongside the explicitly mapped GITHUB_TOKEN.
$BIN --backend $BACKEND run --agent $WALLET --env GITHUB_TOKEN=github -- sh -c 'echo "GT=$GITHUB_TOKEN GA=${GITHUB_API_KEY:-unset}"'
# Expected: "GT=ghp_testtoken GA=ghp_testtoken"

# Multiple --env flags stack:
$BIN --backend $BACKEND store --agent $WALLET openrouter sk-or-override
$BIN --backend $BACKEND run --agent $WALLET --env GITHUB_TOKEN=github --env OPENROUTER_KEY=openrouter -- sh -c 'echo "GT=$GITHUB_TOKEN OR=$OPENROUTER_KEY"'
# Expected: "GT=ghp_testtoken OR=sk-or-override"

kill $MOCK_PID
```

### Case 3 — `--env` with invalid format fails cleanly

```bash
rm -rf $HOME/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

$BIN --backend $BACKEND init --mock-token env-invalid
WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")

$BIN --backend $BACKEND run --agent $WALLET --env NO_EQUALS -- true 2>&1 | head -3
# Expected: "Invalid --env format 'NO_EQUALS': expected KEY=SERVICE (no '=' found)"
# The child process must NOT be spawned.

kill $MOCK_PID
```

### Case 4 — `list_credentials` ownership enforced

```bash
rm -rf $HOME/.agentkeys
cargo run --release -p agentkeys-mock-server &
MOCK_PID=$!
sleep 1

# User A stores credentials
$BIN --backend $BACKEND init --mock-token user-a-store
A_WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")
$BIN --backend $BACKEND store --agent $A_WALLET openrouter sk-secret

# User B initializes (different mock token — different wallet; overwrites local session)
$BIN --backend $BACKEND init --mock-token user-b-probe
B_WALLET=$(jq -r .wallet "$HOME/.agentkeys/master/session.json")

# User B tries to list user A's credentials via run (uses list_credentials under the hood)
$BIN --backend $BACKEND run --agent $A_WALLET -- printenv OPENROUTER_API_KEY 2>&1 | head -3
# Expected: "Error: DENIED\n  session does not own agent 0x..."

kill $MOCK_PID
```

## Cleanup

```bash
rm -rf "$HOME_SANDBOX"
unset HOME_SANDBOX AGENTKEYS_SESSION_STORE
```

## Cross-references

- `crates/agentkeys-cli/src/lib.rs` — `cmd_run` (list_credentials fallback + `--env` parsing)
- `crates/agentkeys-cli/src/main.rs` — `Commands::Run.env: Vec<String>`
- `crates/agentkeys-core/src/backend.rs` — new `list_credentials` trait method
- `crates/agentkeys-mock-server/src/handlers/credential.rs` — `list_credentials` HTTP handler
- `wiki/credential-usage.md` — service-name → env var convention + `--env` escape hatch (updated by this PR)
- `docs/manual-test-stage4.md` Test 9 — will be updated in PR body to remove `run` SKIPPED marker once merged
- `docs/contradictions.md` §4.2 — moves to RESOLVED once merged
- Related follow-up: story `fix-15b` in `.omc/prd.json` (scope-edit CLI command)
