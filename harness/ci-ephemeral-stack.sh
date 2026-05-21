#!/usr/bin/env bash
# harness/ci-ephemeral-stack.sh — issue #66 tier-1 ephemeral CI driver.
#
# Stands up a complete, isolated AgentKeys test environment INSIDE a
# single CI runner and exercises the chain-deploy path end-to-end. No
# external infrastructure, no LLM, no WebAuthn, no real AWS.
#
# What this script delivers (the four parallel-infra axes from issue #66):
#
#   ─ new test broker server     → ephemeral agentkeys-broker-server
#                                   spawned on 127.0.0.1, OIDC issuer
#                                   http://127.0.0.1:$BROKER_PORT, stub
#                                   STS client (no real AWS).
#   ─ new smart contract on-chain → forge script deploys a fresh copy of
#                                   the v2 stage-1 contract set
#                                   (P256Verifier + K11Verifier +
#                                   SidecarRegistry + AgentKeysScope +
#                                   K3EpochCounter + CredentialAudit)
#                                   to a brand-new anvil instance.
#   ─ new deployer account       → anvil's canonical first prefunded test
#                                   key (10_000 ETH; zero risk).
#   ─ no WebAuthn                 → the harness scripts default to
#                                   WEBAUTHN_MODE=0 (stage-1 line 131);
#                                   this script never passes --webauthn,
#                                   so K11 enrollment writes deterministic
#                                   stub bytes (CI-friendly).
#
# What's COVERED by this script (matches the harness scripts' coverage
# for things that don't require real AWS):
#
#   * Forge unit + property tests for all six v2 stage-1 contracts.
#   * End-to-end Foundry deploy via DeployAgentKeysV1.s.sol against the
#     ephemeral anvil — same script as heima-bring-up.sh step 5 uses
#     against Heima Mainnet/Paseo.
#   * Read-only ABI/wiring checks via verify-heima-contracts.sh against
#     the freshly deployed addresses (same checks Heima uses).
#   * Broker liveness + OIDC discovery surface (/.well-known/
#     openid-configuration, /.well-known/jwks.json, /healthz).
#
# What's NOT covered here (intentionally — needs the long-lived
# test-broker.litentry.org tier-2 environment with publicly-reachable
# TLS + real AWS resources; see docs/test-environment.md):
#
#   * harness/v2-stage3-demo.sh — per-actor + per-data-class S3
#     PrincipalTag isolation tests. AWS STS AssumeRoleWithWebIdentity
#     requires AWS to fetch the OIDC issuer's JWKS over public TLS,
#     which a CI runner can't expose.
#   * Real SES email-link auth round-trip (uses StubEmailSender in unit
#     tests; long-lived tier-2 exercises real SES).
#
# All the Rust-side broker/worker logic (SIWE auth, OIDC mint, cap-token
# verify, etc.) is covered by `cargo test --workspace` in the parent
# CI workflow — those tests already spawn an in-process broker with
# StubSts + StubEmailSender, so the ephemeral-stack script focuses on
# what cargo test can't reach: the on-chain deploy + ABI surface.
#
# Usage:
#   bash harness/ci-ephemeral-stack.sh                # full ephemeral roundtrip
#   bash harness/ci-ephemeral-stack.sh --skip-broker  # chain-only (forge + anvil)
#   bash harness/ci-ephemeral-stack.sh --keep-running # leave anvil + broker up
#                                                     # (for local debugging)
#
# Exit codes:
#   0  every check passed
#   1  any check failed; logs in $WORK_DIR/*.log preserved on failure
#   2  prereqs missing (anvil/forge/cargo)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ─── CLI ─────────────────────────────────────────────────────────────────
SKIP_BROKER=0
KEEP_RUNNING=0
ANVIL_PORT="${ANVIL_PORT:-8545}"
MOCK_PORT="${MOCK_PORT:-8090}"
BROKER_PORT="${BROKER_PORT:-8091}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-broker)  SKIP_BROKER=1; shift ;;
    --keep-running) KEEP_RUNNING=1; shift ;;
    --anvil-port)   ANVIL_PORT="$2"; shift 2 ;;
    --mock-port)    MOCK_PORT="$2"; shift 2 ;;
    --broker-port)  BROKER_PORT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//' | sed '$d'
      exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ─── Colors ──────────────────────────────────────────────────────────────
if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_WARN='\033[1;33m'
  C_ERR='\033[1;31m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}    %s\n" "$*" >&2; }
info() { printf "    ${C_DIM}info${C_RESET}  %s\n" "$*" >&2; }
warn() { printf "    ${C_WARN}warn${C_RESET}  %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET}  %s\n" "$*" >&2; exit 1; }

# ─── Work dir + cleanup trap ─────────────────────────────────────────────
WORK_DIR="$(mktemp -d -t agentkeys-ci-ephemeral-XXXXXX)"
ANVIL_PID=""
MOCK_PID=""
BROKER_PID=""

cleanup() {
  local rc=$?
  if [ "$KEEP_RUNNING" = "1" ]; then
    info "--keep-running set; leaving processes up"
    info "  anvil:  pid=$ANVIL_PID  port=$ANVIL_PORT"
    [ -n "$MOCK_PID" ]   && info "  mock:   pid=$MOCK_PID    port=$MOCK_PORT"
    [ -n "$BROKER_PID" ] && info "  broker: pid=$BROKER_PID  port=$BROKER_PORT"
    info "  work_dir: $WORK_DIR"
    exit "$rc"
  fi
  log "Cleanup"
  for pid_var in BROKER_PID MOCK_PID ANVIL_PID; do
    eval "pid=\${$pid_var:-}"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      ok "stopped $pid_var pid=$pid"
    fi
  done
  if [ "$rc" -ne 0 ]; then
    warn "exit=$rc — preserving logs at $WORK_DIR"
    for f in "$WORK_DIR"/*.log; do
      [ -e "$f" ] || continue
      printf "\n${C_DIM}── tail $f ──${C_RESET}\n" >&2
      tail -n 50 "$f" >&2 || true
    done
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

# ─── 1. Prereq sanity-check ──────────────────────────────────────────────
log "1/8 Prereq sanity-check"
missing=()
for tool in cargo jq curl awk grep sed anvil forge cast; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  warn "missing tools: ${missing[*]}"
  warn "  install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup"
  warn "  install Rust:    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  die "prereqs missing"
fi
ok "tools present: cargo jq curl awk grep sed anvil forge cast"

# ─── 2. Start anvil (new chain) ──────────────────────────────────────────
log "2/8 Starting anvil on 127.0.0.1:$ANVIL_PORT (new ephemeral chain)"
# Anvil's first default account: pre-funded with 10_000 ETH, deterministic.
# This is our "new deployer account" — fresh per CI run, zero blast radius.
ANVIL_DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
ANVIL_DEPLOYER_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
anvil --port "$ANVIL_PORT" \
      --host 127.0.0.1 \
      --silent \
      > "$WORK_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
# Wait for RPC ready (anvil bootstraps fast — <2s typically, give it 30s)
for _ in $(seq 1 60); do
  if curl -sf --max-time 1 \
       -H 'Content-Type: application/json' \
       -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
       "http://127.0.0.1:$ANVIL_PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
curl -sf --max-time 2 \
     -H 'Content-Type: application/json' \
     -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
     "http://127.0.0.1:$ANVIL_PORT" >/dev/null \
  || die "anvil failed to come up; see $WORK_DIR/anvil.log"
ok "anvil up (pid=$ANVIL_PID chain_id=31337 deployer=$ANVIL_DEPLOYER_ADDR)"

# ─── 3. Forge build + test (contract unit + property tests) ──────────────
log "3/8 Forge build + test (crates/agentkeys-chain/)"
(
  cd crates/agentkeys-chain
  forge build > "$WORK_DIR/forge-build.log" 2>&1 \
    || die "forge build failed; see $WORK_DIR/forge-build.log"
  ok "forge build clean"
  forge test --no-match-test "fork_" > "$WORK_DIR/forge-test.log" 2>&1 \
    || die "forge test failed; see $WORK_DIR/forge-test.log"
  ok "forge test passed ($(grep -c "^\[PASS\]" "$WORK_DIR/forge-test.log" || echo 0) tests)"
)

# ─── 4. Deploy v2 stage-1 contract set (new smart contracts on-chain) ────
log "4/8 Deploy v2 stage-1 contracts via DeployAgentKeysV1.s.sol"
(
  cd crates/agentkeys-chain
  forge script script/DeployAgentKeysV1.s.sol \
    --rpc-url "http://127.0.0.1:$ANVIL_PORT" \
    --private-key "$ANVIL_DEPLOYER_KEY" \
    --broadcast \
    --skip-simulation \
    > "$WORK_DIR/forge-deploy.log" 2>&1 \
    || die "forge script deploy failed; see $WORK_DIR/forge-deploy.log"
)
# Parse "Name: 0xAddress" lines (the contract names from DeployAgentKeysV1.s.sol's
# console.log calls). Format matches heima-bring-up.sh's parser.
parse_addr() {
  local name="$1"
  awk -v want="$name" '
    $0 ~ want":" {
      for (i=1; i<=NF; i++) if ($i ~ /^0x[a-fA-F0-9]{40}$/) { print $i; exit }
    }
  ' "$WORK_DIR/forge-deploy.log"
}
SCOPE_ADDR=$(parse_addr "AgentKeysScope")
REGISTRY_ADDR=$(parse_addr "SidecarRegistry")
EPOCH_ADDR=$(parse_addr "K3EpochCounter")
AUDIT_ADDR=$(parse_addr "CredentialAudit")
P256_ADDR=$(parse_addr "P256Verifier")
K11_ADDR=$(parse_addr "K11Verifier")
for v in SCOPE_ADDR REGISTRY_ADDR EPOCH_ADDR AUDIT_ADDR P256_ADDR K11_ADDR; do
  eval "val=\${$v}"
  [ -n "$val" ] || die "could not parse $v from forge-deploy.log"
done
ok "AgentKeysScope:  $SCOPE_ADDR"
ok "SidecarRegistry: $REGISTRY_ADDR"
ok "K3EpochCounter:  $EPOCH_ADDR"
ok "CredentialAudit: $AUDIT_ADDR"
ok "P256Verifier:    $P256_ADDR"
ok "K11Verifier:     $K11_ADDR"

# ─── 5. Write synthetic operator-workstation.env for verify scripts ──────
log "5/8 Write synthetic operator-workstation.env (--anvil profile)"
SYNTH_ENV="$WORK_DIR/operator-workstation.env"
cat > "$SYNTH_ENV" <<EOF
# Synthetic env file for harness/ci-ephemeral-stack.sh (issue #66).
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) — DO NOT COMMIT.
ACCOUNT_ID=000000000000
REGION=us-east-1
MAIL_DOMAIN=test.invalid
MAIL_BUCKET=agentkeys-mail-ci-ephemeral
BUCKET=agentkeys-mail-ci-ephemeral
VAULT_BUCKET=agentkeys-vault-ci-ephemeral
MEMORY_BUCKET=agentkeys-memory-ci-ephemeral
BROKER_HOST=127.0.0.1:$BROKER_PORT
OIDC_ISSUER=http://127.0.0.1:$BROKER_PORT
BACKEND_URL=http://127.0.0.1:$MOCK_PORT
AGENTKEYS_SIGNER_URL=http://127.0.0.1:$MOCK_PORT
DATA_ROLE_ARN=arn:aws:iam::000000000000:role/agentkeys-data-role-ci
VAULT_ROLE_ARN=arn:aws:iam::000000000000:role/agentkeys-vault-role-ci
MEMORY_ROLE_ARN=arn:aws:iam::000000000000:role/agentkeys-memory-role-ci

# v2 stage-1 contracts (anvil profile)
SCOPE_CONTRACT_ADDRESS_ANVIL=$SCOPE_ADDR
SIDECAR_REGISTRY_ADDRESS_ANVIL=$REGISTRY_ADDR
K3_EPOCH_COUNTER_ADDRESS_ANVIL=$EPOCH_ADDR
CREDENTIAL_AUDIT_ADDRESS_ANVIL=$AUDIT_ADDR
P256_VERIFIER_ADDRESS_ANVIL=$P256_ADDR
K11_VERIFIER_ADDRESS_ANVIL=$K11_ADDR
EOF
ok "wrote $SYNTH_ENV"

# ─── 6. Verify deployed contracts (read-only ABI + wiring checks) ────────
log "6/8 verify-heima-contracts.sh (anvil profile)"
# verify-heima-contracts.sh reads scripts/operator-workstation.env, so
# overlay the synthetic file in place for the duration of this step.
# Restored even on failure via the trap.
REAL_ENV="$REPO_ROOT/scripts/operator-workstation.env"
BACKUP_ENV=""
if [ -f "$REAL_ENV" ]; then
  BACKUP_ENV="$WORK_DIR/operator-workstation.env.original"
  cp "$REAL_ENV" "$BACKUP_ENV"
fi
restore_env() {
  if [ -n "$BACKUP_ENV" ] && [ -f "$BACKUP_ENV" ]; then
    cp "$BACKUP_ENV" "$REAL_ENV"
  elif [ -f "$REAL_ENV" ] && [ -z "$BACKUP_ENV" ]; then
    rm -f "$REAL_ENV"
  fi
}
cp "$SYNTH_ENV" "$REAL_ENV"
verify_rc=0
AGENTKEYS_CHAIN=anvil bash "$REPO_ROOT/scripts/verify-heima-contracts.sh" \
  > "$WORK_DIR/verify-contracts.log" 2>&1 || verify_rc=$?
restore_env
if [ "$verify_rc" -ne 0 ]; then
  warn "verify-heima-contracts.sh exited $verify_rc; full log:"
  cat "$WORK_DIR/verify-contracts.log" >&2
  die "contract verification failed"
fi
ok "all six v2 stage-1 contracts verified (bytecode + ABI + wiring)"

# ─── 7. Optional: stand up the broker server (skipped by default) ────────
if [ "$SKIP_BROKER" = "1" ]; then
  log "7/8 Broker bring-up SKIPPED (--skip-broker)"
else
  log "7/8 Stand up ephemeral broker (new test broker server)"

  # Pre-generate keypairs so the broker boots clean. The keygen
  # subcommand writes 0600 files; matches the production setup-broker-host
  # flow but in $WORK_DIR instead of /var/lib/agentkeys.
  BROKER_DATA_DIR="$WORK_DIR/broker-data"
  mkdir -p "$BROKER_DATA_DIR"
  info "building agentkeys-broker-server (release)"
  cargo build --release -p agentkeys-broker-server \
    > "$WORK_DIR/cargo-build-broker.log" 2>&1 \
    || die "cargo build broker failed; see $WORK_DIR/cargo-build-broker.log"
  BROKER_BIN="$REPO_ROOT/target/release/agentkeys-broker-server"
  [ -x "$BROKER_BIN" ] || die "broker binary missing at $BROKER_BIN"

  "$BROKER_BIN" keygen --purpose oidc \
    --out "$BROKER_DATA_DIR/oidc-keypair.json" >/dev/null
  "$BROKER_BIN" keygen --purpose session \
    --out "$BROKER_DATA_DIR/session-keypair.json" >/dev/null
  ok "broker keypairs generated"

  info "building agentkeys-mock-server (release)"
  cargo build --release -p agentkeys-mock-server \
    > "$WORK_DIR/cargo-build-mock.log" 2>&1 \
    || die "cargo build mock-server failed; see $WORK_DIR/cargo-build-mock.log"
  MOCK_BIN="$REPO_ROOT/target/release/agentkeys-mock-server"
  [ -x "$MOCK_BIN" ] || die "mock-server binary missing at $MOCK_BIN"

  info "starting mock-server on 127.0.0.1:$MOCK_PORT"
  "$MOCK_BIN" --port "$MOCK_PORT" \
    > "$WORK_DIR/mock-server.log" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 60); do
    curl -sf --max-time 1 "http://127.0.0.1:$MOCK_PORT/healthz" >/dev/null 2>&1 && break
    sleep 0.25
  done
  curl -sf --max-time 2 "http://127.0.0.1:$MOCK_PORT/healthz" >/dev/null \
    || die "mock-server failed to come up; see $WORK_DIR/mock-server.log"
  ok "mock-server up (pid=$MOCK_PID)"

  info "starting broker on 127.0.0.1:$BROKER_PORT (--skip-startup-check)"
  # No real AWS creds in CI — broker runs OIDC-only mint path per issue #71,
  # so the only thing AWS would do is the optional GetCallerIdentity probe,
  # which --skip-startup-check disables.
  BROKER_OIDC_ISSUER="http://127.0.0.1:$BROKER_PORT" \
  BROKER_BACKEND_URL="http://127.0.0.1:$MOCK_PORT" \
  BROKER_DATA_ROLE_ARN="arn:aws:iam::000000000000:role/agentkeys-data-role-ci" \
  BROKER_AWS_REGION="us-east-1" \
  BROKER_OIDC_KEYPAIR_PATH="$BROKER_DATA_DIR/oidc-keypair.json" \
  BROKER_SESSION_KEYPAIR_PATH="$BROKER_DATA_DIR/session-keypair.json" \
  BROKER_AUDIT_DB_PATH="$BROKER_DATA_DIR/audit.sqlite" \
  RUST_LOG=info \
    "$BROKER_BIN" --bind 127.0.0.1 --port "$BROKER_PORT" --skip-startup-check \
    > "$WORK_DIR/broker.log" 2>&1 &
  BROKER_PID=$!
  for _ in $(seq 1 60); do
    curl -sf --max-time 1 "http://127.0.0.1:$BROKER_PORT/healthz" >/dev/null 2>&1 && break
    sleep 0.25
  done
  curl -sf --max-time 2 "http://127.0.0.1:$BROKER_PORT/healthz" >/dev/null \
    || die "broker failed to come up; see $WORK_DIR/broker.log"
  ok "broker up (pid=$BROKER_PID)"

  # OIDC discovery surface — same endpoints AWS would hit in tier-2.
  info "probing OIDC discovery surface"
  curl -sf --max-time 2 \
       "http://127.0.0.1:$BROKER_PORT/.well-known/openid-configuration" \
       > "$WORK_DIR/oidc-config.json" \
    || die "openid-configuration unreachable"
  jq -e '.issuer == "http://127.0.0.1:'"$BROKER_PORT"'"' \
       "$WORK_DIR/oidc-config.json" >/dev/null \
    || die "openid-configuration issuer claim mismatch (see $WORK_DIR/oidc-config.json)"
  ok ".well-known/openid-configuration → issuer matches"

  curl -sf --max-time 2 \
       "http://127.0.0.1:$BROKER_PORT/.well-known/jwks.json" \
       > "$WORK_DIR/jwks.json" \
    || die "jwks.json unreachable"
  jq -e '.keys | length >= 1' "$WORK_DIR/jwks.json" >/dev/null \
    || die "jwks.json has no keys (see $WORK_DIR/jwks.json)"
  ok ".well-known/jwks.json → at least one key present"
fi

# ─── 8. Summary ──────────────────────────────────────────────────────────
log "8/8 Summary"
ok "ephemeral environment passed all checks"
info "  chain      : anvil  (chain_id 31337, ephemeral)"
info "  deployer   : $ANVIL_DEPLOYER_ADDR"
info "  contracts  : 6/6 deployed + verified on chain"
if [ "$SKIP_BROKER" != "1" ]; then
  info "  broker     : http://127.0.0.1:$BROKER_PORT"
  info "  oidc issuer: http://127.0.0.1:$BROKER_PORT"
  info "  backend    : http://127.0.0.1:$MOCK_PORT (mock-server)"
fi
info ""
info "Not covered here (needs long-lived test-broker.litentry.org —"
info "see docs/test-environment.md):"
info "  * stage-3 per-actor + per-data-class S3 PrincipalTag isolation"
info "  * real AWS STS AssumeRoleWithWebIdentity"
info "  * real SES email-link auth round-trip"
