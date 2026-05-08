#!/usr/bin/env bash
# Stage 7 issue#64 Phase 0 — smoke test.
#
# Per plan rule 10 (smoke script per phase): exercises the Phase 0
# vertical slice end-to-end without external dependencies. Asserts:
#   1. cargo build with v0 default features succeeds
#   2. cargo test for the broker-server lib + integration suites passes
#   3. clippy is clean
#   4. The grep-style invariants for env.rs centralization (rule 11)
#      and refuse-to-boot anchors (rule 4) hold.
#
# Exits 0 on success, non-zero on any assertion failure. Designed to be
# called from CI and from `harness/stage-7-done.sh`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_DIR="${REPO_ROOT}/crates/agentkeys-broker-server"

log()  { printf '\n[stage-7-phase0-smoke] %s\n' "$*"; }
fail() { printf '\n[stage-7-phase0-smoke] FAIL: %s\n' "$*" >&2; exit 1; }

log "1. cargo build (v0 default features)"
cargo build -p agentkeys-broker-server --quiet || fail "cargo build failed"

log "2. cargo build (v0 testnet feature combo: auth-email-link,auth-oauth2-google,audit-evm)"
cargo build -p agentkeys-broker-server \
    --features "auth-email-link,auth-oauth2-google,audit-evm" \
    --quiet || fail "v0 testnet feature combo build failed"

log "3. cargo test (broker-server lib + integration)"
cargo test -p agentkeys-broker-server --quiet || fail "cargo test failed"

log "4. cargo clippy -D warnings"
cargo clippy -p agentkeys-broker-server -- -D warnings 2>&1 \
    | tee /tmp/stage-7-phase0-clippy.log \
    || fail "clippy reported warnings (treated as errors)"

log "5. env.rs centralization — no raw BROKER_*/DAEMON_* literals in config.rs (Plan §1 rule 11)"
if grep -nE '"(BROKER_|DAEMON_|ACCOUNT_ID|REGION)' "${BROKER_DIR}/src/config.rs"; then
    fail "config.rs contains raw env-var literals — must reference env::* constants"
fi

log "6. boot.rs BOOT_FAIL anchor format check (Plan §6 + rule 4)"
if ! grep -q 'BOOT_FAIL:' "${BROKER_DIR}/src/boot.rs"; then
    fail "boot.rs missing BOOT_FAIL: anchor (refuse-to-boot UX broken)"
fi
if ! grep -q 'see runbook §' "${BROKER_DIR}/src/boot.rs"; then
    fail "boot.rs BOOT_FAIL anchors must reference 'see runbook §<anchor>'"
fi

log "7. plugin trait surface present (Plan §3 + rule 8)"
for f in plugins/mod.rs plugins/auth/mod.rs plugins/wallet/mod.rs plugins/audit/mod.rs; do
    [[ -f "${BROKER_DIR}/src/${f}" ]] || fail "missing plugin file: ${f}"
done

log "8. Stage 7 §3.5 wire-format endpoints registered in router"
for route in '/v1/auth/wallet/start' '/v1/auth/wallet/verify' '/v1/auth/exchange' '/v1/mint-aws-creds' '/healthz' '/readyz'; do
    grep -q "\"${route}\"" "${BROKER_DIR}/src/lib.rs" || fail "router missing route: ${route}"
done

log "9. Both ES256 keypair purposes (oidc + session) compile-checked (Plan §3.5.6)"
grep -q 'purpose: KeypairPurpose' "${BROKER_DIR}/src/jwt/session.rs" \
    || fail "SessionKeypair must persist purpose tag"

log "OK — Phase 0 smoke green"
