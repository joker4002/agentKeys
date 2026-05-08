#!/usr/bin/env bash
# Stage 7 issue#64 Phase C — smoke test (US-035).
#
# Per plan rule 10. Phase C covers EVM testnet audit anchor (Base
# Sepolia), three-state audit lifecycle, circuit breaker, gas-drain
# mitigations.
#
# This script asserts STRUCTURAL PHASE C invariants:
#   1. cargo build --features audit-evm passes (alloy hardening
#      deferred to V0.1-FOLLOWUPS Phase E; v0 ships EvmStubAnchor).
#   2. cargo test --features audit-evm green (includes circuit
#      breaker + EVM stub + lifecycle methods + mint rate limiter).
#   3. AgentKeysAudit.sol Solidity contract source present
#      (Foundry build + Base Sepolia deploy is a Phase E operator
#      task — see runbook §evm-deploy).
#   4. SqliteAnchor lifecycle methods present + tested
#      (anchor_pending / promote_to_confirmed / promote_to_quarantined).
#   5. CircuitBreaker module present + tested (state machine drop-token
#      counts as failure, half-open probe serialized).
#   6. EvmStubAnchor present (no live network in CI).
#   7. MintRateLimiter present (per-OmniAccount mints/hour +
#      per-OmniAccount EVM tx/day).
#   8. Phase C env vars declared in env.rs.
#
# Live Base Sepolia smoke (deploy contract, mint, observe on-chain
# event) is a Phase E operator-runbook task tracked in V0.1-FOLLOWUPS.
#
# Exits 0 on success.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_DIR="${REPO_ROOT}/crates/agentkeys-broker-server"

log()  { printf '\n[stage-7-phaseC-smoke] %s\n' "$*"; }
fail() { printf '\n[stage-7-phaseC-smoke] FAIL: %s\n' "$*" >&2; exit 1; }

log "1. cargo build --features audit-evm,auth-oauth2-google,auth-email-link"
cargo build -p agentkeys-broker-server \
    --features audit-evm,auth-oauth2-google,auth-email-link --quiet \
    || fail "cargo build with audit-evm failed"

log "2. cargo test --features audit-evm,auth-oauth2-google,auth-email-link"
cargo test -p agentkeys-broker-server \
    --features audit-evm,auth-oauth2-google,auth-email-link --quiet \
    || fail "cargo test with audit-evm failed"

log "3. cargo clippy --features audit-evm -D warnings"
cargo clippy -p agentkeys-broker-server \
    --features audit-evm,auth-oauth2-google,auth-email-link -- -D warnings \
    || fail "clippy reported warnings"

log "4. AgentKeysAudit.sol contract source present"
SOL="${BROKER_DIR}/solidity/src/AgentKeysAudit.sol"
[[ -f "$SOL" ]] || fail "missing Solidity contract: $SOL"
grep -q 'event RecordAnchored' "$SOL" \
    || fail "AgentKeysAudit.sol must declare RecordAnchored event"
grep -q 'bytes32 indexed recordHash' "$SOL" \
    || fail "RecordAnchored must index recordHash"
grep -q 'bytes32 indexed omniAccount' "$SOL" \
    || fail "RecordAnchored must index omniAccount"
grep -q 'address indexed wallet' "$SOL" \
    || fail "RecordAnchored must index wallet"

FOUNDRY="${BROKER_DIR}/solidity/foundry.toml"
[[ -f "$FOUNDRY" ]] || fail "missing foundry.toml: $FOUNDRY"

log "5. SqliteAnchor three-state lifecycle methods"
SQLITE="${BROKER_DIR}/src/plugins/audit/sqlite.rs"
for fn in 'fn anchor_pending' 'fn promote_to_confirmed' 'fn promote_to_quarantined' 'fn list_pending_older_than' 'fn list_quarantined'; do
    grep -q "$fn" "$SQLITE" \
        || fail "sqlite.rs missing lifecycle method: $fn"
done
# Atomic transitions are conditional UPDATE WHERE status='pending'.
grep -q "WHERE id = ?1 AND status = 'pending'" "$SQLITE" \
    || fail "promote_to_confirmed must be atomic via WHERE status='pending'"

log "6. CircuitBreaker module present + tested"
BREAKER="${BROKER_DIR}/src/plugins/audit/breaker.rs"
[[ -f "$BREAKER" ]] || fail "missing breaker module: $BREAKER"
for marker in 'BreakerState::Closed' 'BreakerState::Open' 'BreakerState::HalfOpen' 'fn try_acquire' 'fn complete_success' 'fn complete_failure'; do
    grep -q "$marker" "$BREAKER" \
        || fail "breaker.rs missing: $marker"
done
# Drop-without-resolve counts as failure.
grep -q 'impl<.a> Drop for BreakerToken' "$BREAKER" \
    || fail "BreakerToken must impl Drop (defensive failure on drop)"

log "7. EvmStubAnchor present (audit-evm feature)"
EVM="${BROKER_DIR}/src/plugins/audit/evm.rs"
[[ -f "$EVM" ]] || fail "missing evm anchor module: $EVM"
grep -q 'pub struct EvmStubAnchor' "$EVM" \
    || fail "evm.rs must declare EvmStubAnchor for tests"
grep -q 'set_simulate_failure' "$EVM" \
    || fail "EvmStubAnchor must expose set_simulate_failure for chaos tests"
grep -q 'pub fn validate' "$EVM" \
    || fail "EvmAuditConfig must implement validate() for Tier-1 boot"

log "8. MintRateLimiter present (gas-drain US-034)"
RL="${BROKER_DIR}/src/storage/rate_limit_mints.rs"
[[ -f "$RL" ]] || fail "missing rate_limit_mints module: $RL"
grep -q 'fn check_mint' "$RL" \
    || fail "MintRateLimiter must expose check_mint"
grep -q 'fn check_evm_tx' "$RL" \
    || fail "MintRateLimiter must expose check_evm_tx"

log "9. Phase C env vars declared in env.rs"
ENV_RS="${BROKER_DIR}/src/env.rs"
for var in BROKER_EVM_RPC_URL BROKER_EVM_CHAIN_ID BROKER_EVM_CONTRACT_ADDRESS \
           BROKER_EVM_FEE_PAYER_KEYSTORE BROKER_EVM_FEE_PAYER_PASSWORD_FILE \
           BROKER_EVM_FEE_PAYER_MIN_BALANCE BROKER_EVM_PER_IDENTITY_DAILY_TX_BUDGET \
           BROKER_RATE_LIMIT_MINTS_PER_HOUR_PER_OMNI \
           BROKER_RATE_LIMIT_CHALLENGES_PER_HOUR_PER_IP; do
    grep -q "$var" "$ENV_RS" \
        || fail "env.rs missing constant: $var"
done

log "10. evm_testnet branch in boot.rs registry"
BOOT="${BROKER_DIR}/src/boot.rs"
grep -q '"evm_testnet"' "$BOOT" \
    || fail "boot.rs missing evm_testnet branch in build_registry"

log "OK — Phase C structural smoke green (US-031/032/033/034 + Solidity stub)"
log "Note: Live Base Sepolia smoke (deploy + mint + on-chain event) is"
log "      a Phase E operator-runbook task — see V0.1-FOLLOWUPS PA2-R3-F2"
