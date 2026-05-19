#!/usr/bin/env bash
# Stage 7 (phase 1 + phase 2) completion gate.
#
# Phase 1 (PR #60): broker server vertical slice — bearer-gated
# POST /v1/mint-aws-creds, SQLite audit, /healthz + /readyz, daemon
# --broker-url flag.
#
# Phase 2 (PR #61): OIDC issuer absorption (discovery + JWKS +
# POST /v1/mint-oidc-jwt) into the Rust broker; provisioner-scripts
# AWS-cred wiring through CLI cmd_provision and MCP provision_tool.
#
# What this covers (offline, hermetic):
#   1. Broker crate compiles + lib + integration tests pass
#   2. Provisioner aws_creds module unit tests pass
#   3. MCP broker-env injection tests pass
#   4. Daemon + CLI rebuild cleanly with the broker_url plumbing
#   5. Clippy on every Stage 7-touched crate, warnings as errors
#   6. The TS oidc-stub directory is gone (issuer surface owned by Rust)
#   7. No raw `services/oidc-stub` references survive in checked-in docs
#
# What this does NOT cover (by design):
#   - Live STS / SES / S3 — the broker's StubStsClient covers the audit
#     + dispatch logic without an AWS round-trip.
#   - Public TLS deployment + `aws iam create-open-id-connect-provider`.
#     That's the operational runbook in docs/stage7-wip.md, not a
#     Stage-7 architectural prerequisite.
#
# Exit 0 = Stage 7 phases 1 + 2 are intact. Non-zero = stage broken.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'
banner() { printf "\n${BOLD}=== %s ===${NC}\n" "$1"; }
ok()     { printf "${GREEN}✓${NC} %s\n" "$1"; }
fail()   { printf "${RED}✗${NC} %s\n" "$1" >&2; exit 1; }

banner "1/7  Broker — lib + integration tests"
cargo test -p agentkeys-broker-server
ok "broker tests passed"

banner "2/7  Provisioner — aws_creds module tests"
cargo test -p agentkeys-provisioner aws_creds
ok "provisioner aws_creds tests passed"

banner "3/7  MCP — broker-env injection + tools/list"
cargo test -p agentkeys-mcp
ok "mcp tests passed"

banner "4/7  Daemon + CLI rebuild with broker_url plumbing"
cargo build -p agentkeys-daemon -p agentkeys-cli
ok "daemon + cli build clean"

banner "5/7  Clippy (Stage 7 crates, --no-deps -D warnings)"
cargo clippy --no-deps \
  -p agentkeys-broker-server \
  -p agentkeys-provisioner \
  -p agentkeys-mcp \
  -p agentkeys-cli \
  -p agentkeys-daemon \
  --all-targets -- -D warnings
ok "clippy clean"

banner "6/7  TS oidc-stub directory retired"
if [ -e services/oidc-stub ]; then
  fail "services/oidc-stub still on disk — Phase 2 expects it deleted (issuer absorbed into Rust broker)"
fi
ok "services/oidc-stub gone"

banner "7/7  No broken markdown links to the retired services/oidc-stub"
# Narrative mentions ("services/oidc-stub retired") are fine — they describe
# what was deleted. What we're guarding against here is broken markdown
# links: `](../services/oidc-stub/...)` would 404 in the rendered docs.
# docs/archived/* is the historical scratchpad and is allowed to keep
# anything for context.
LEAKS=$(grep -rln "](.*/services/oidc-stub" docs wiki 2>/dev/null \
  | grep -v "^docs/archived/" || true)
if [ -n "$LEAKS" ]; then
  printf "%s\n" "$LEAKS" >&2
  fail "broken markdown links to the deleted services/oidc-stub directory in non-archived docs (above)"
fi
ok "no broken links"

printf "\n${GREEN}${BOLD}STAGE 7 (phase 1 + phase 2) PASSED${NC}\n"
