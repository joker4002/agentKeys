#!/usr/bin/env bash
# Stage 5a completion gate — runs every non-live check in one shot.
#
# What this covers:
#   1. Rust unit tests across the four Stage 5a crates
#   2. TS install + unit tests (provisioner-scripts)
#   3. Phantom-key chaos test in isolation (silent-corrupt defense)
#   4. Pattern grep guard (patterns must have zero service strings)
#   5. TS typecheck
#   6. Clippy on Stage 5a crates, warnings treated as errors
#   7. MCP `tools/list` advertises agentkeys.provision
#   8. Observability — orchestrator emits the three core provision_metric names
#
# What this does NOT cover (by design):
#   - The live OpenRouter signup demo. See §1 of docs/manual-test-stage5.md.
#
# Exit 0 = Stage 5a is intact. Non-zero = stage broken, do not merge.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'
banner() { printf "\n${BOLD}=== %s ===${NC}\n" "$1"; }
ok()     { printf "${GREEN}✓${NC} %s\n" "$1"; }
fail()   { printf "${RED}✗${NC} %s\n" "$1" >&2; exit 1; }

banner "1/8  Rust tests (types, provisioner, mcp, cli)"
cargo test -p agentkeys-types -p agentkeys-provisioner -p agentkeys-mcp -p agentkeys-cli
ok "Rust tests passed"

banner "2/8  TS install + unit tests"
npm install --prefix provisioner-scripts --silent
npm test --prefix provisioner-scripts
ok "TS tests passed"

banner "3/8  Phantom-key chaos test (isolated)"
( cd provisioner-scripts && npx vitest run tests/scrapers/openrouter.phantom.test.ts )
ok "phantom chaos held"

banner "4/8  Pattern grep guard — zero service strings"
if grep -riE "openrouter|brave|jina|groq|anthropic|gemini|twitter|instagram" \
     provisioner-scripts/src/patterns/ 2>/dev/null; then
  fail "service-specific string leaked into provisioner-scripts/src/patterns/"
fi
ok "grep guard empty"

banner "5/8  TS typecheck"
npm run typecheck --prefix provisioner-scripts
ok "typecheck clean"

banner "6/8  Clippy (Stage 5a crates, warnings as errors, --no-deps)"
# --no-deps so pre-existing lints in out-of-scope crates (e.g. agentkeys-core)
# don't fail this gate. Only Stage 5a crates are linted under -D warnings.
cargo clippy --no-deps \
  -p agentkeys-types -p agentkeys-provisioner -p agentkeys-mcp -p agentkeys-cli \
  --all-targets -- -D warnings
ok "clippy clean"

banner "7/8  MCP tools/list — agentkeys.provision registered"
cargo build --release -q -p agentkeys-mock-server -p agentkeys-daemon
./target/release/agentkeys-mock-server --port 8090 >/tmp/stage5a-mock.log 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT
sleep 1
MCP_RESPONSE=$(echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | \
  AGENTKEYS_BACKEND=http://localhost:8090 \
  AGENTKEYS_SESSION=test-token \
  ./target/release/agentkeys-daemon --stdio 2>/dev/null | head -1)
if ! echo "$MCP_RESPONSE" | grep -q '"name":"agentkeys.provision"'; then
  fail "agentkeys.provision missing from MCP tools/list"
fi
ok "agentkeys.provision registered"
kill $MOCK_PID 2>/dev/null || true
trap - EXIT

banner "8/8  Observability — three core provision_metric names emitted"
METRICS=$(cargo test -p agentkeys-provisioner -- stores_credential --nocapture 2>&1 | \
  grep "provision_metric" || true)
for name in tier_used duration_seconds verification_result; do
  echo "$METRICS" | grep -q "\"name\":\"$name\"" || \
    fail "missing provision_metric name=$name"
done
ok "tier_used, duration_seconds, verification_result all emitted"

printf "\n${GREEN}${BOLD}STAGE 5a PASSED${NC}\n"
