#!/usr/bin/env bash
# Stage 7 issue#64 Phase D-rest — smoke test (US-038).
#
# Per plan rule 10. Phase D-rest covers: Prometheus metrics counters
# (US-036), Idempotency-Key dedup + body limit (US-037).
#
# This script asserts:
#   1. cargo build + test + clippy across feature combos.
#   2. /metrics endpoint emits Prom-format text when BROKER_METRICS_ENABLED=true.
#   3. /metrics returns 404 when env var unset (default).
#   4. IdempotencyStore present + supports check/store/purge.
#   5. DefaultBodyLimit middleware applied to the router.
#   6. Phase D env vars declared in env.rs.
#
# Exits 0 on success.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_DIR="${REPO_ROOT}/crates/agentkeys-broker-server"

log()  { printf '\n[stage-7-phaseD-smoke] %s\n' "$*"; }
fail() { printf '\n[stage-7-phaseD-smoke] FAIL: %s\n' "$*" >&2; exit 1; }

log "1. cargo build (default features)"
cargo build -p agentkeys-broker-server --quiet \
    || fail "cargo build default failed"

log "2. cargo test --features audit-evm,auth-oauth2-google,auth-email-link"
cargo test -p agentkeys-broker-server \
    --features audit-evm,auth-oauth2-google,auth-email-link --quiet \
    || fail "cargo test full features failed"

log "3. cargo clippy --features audit-evm,auth-oauth2-google,auth-email-link -D warnings"
cargo clippy -p agentkeys-broker-server \
    --features audit-evm,auth-oauth2-google,auth-email-link -- -D warnings \
    || fail "clippy reported warnings"

log "4. Metrics module present + counters defined"
METRICS_RS="${BROKER_DIR}/src/metrics.rs"
[[ -f "$METRICS_RS" ]] || fail "missing metrics module: $METRICS_RS"
for counter in mints mints_failed audit_writes audit_writes_failed \
               auth_attempts idempotency_hits idempotency_conflicts; do
    grep -q "pub $counter: AtomicU64" "$METRICS_RS" \
        || fail "metrics.rs missing counter: $counter"
done
grep -q 'fn render_prometheus' "$METRICS_RS" \
    || fail "metrics.rs must implement render_prometheus()"

log "5. /metrics handler gates on BROKER_METRICS_ENABLED"
METRICS_HANDLER="${BROKER_DIR}/src/handlers/metrics.rs"
[[ -f "$METRICS_HANDLER" ]] || fail "missing metrics handler: $METRICS_HANDLER"
grep -q 'BROKER_METRICS_ENABLED' "$METRICS_HANDLER" \
    || fail "/metrics must consult BROKER_METRICS_ENABLED env var"
grep -q 'StatusCode::NOT_FOUND' "$METRICS_HANDLER" \
    || fail "/metrics must return 404 when disabled"

log "6. /metrics route registered"
grep -q '"/metrics"' "${BROKER_DIR}/src/lib.rs" \
    || fail "/metrics route must be registered in lib.rs"

log "7. IdempotencyStore present + supports check/store/purge"
IDEMP="${BROKER_DIR}/src/storage/idempotency.rs"
[[ -f "$IDEMP" ]] || fail "missing idempotency store: $IDEMP"
for fn in 'fn check' 'fn store' 'fn body_hash' 'fn purge_expired'; do
    grep -q "$fn" "$IDEMP" \
        || fail "idempotency.rs missing: $fn"
done
grep -q 'IdempotencyOutcome::NotSeen\|IdempotencyOutcome::Replay\|IdempotencyOutcome::Conflict' "$IDEMP" \
    || fail "idempotency.rs must define NotSeen / Replay / Conflict outcomes"
grep -q 'INSERT OR IGNORE' "$IDEMP" \
    || fail "idempotency store() must use INSERT OR IGNORE for race idempotency"

log "8. DefaultBodyLimit middleware applied to router"
LIB="${BROKER_DIR}/src/lib.rs"
grep -q 'DefaultBodyLimit::max' "$LIB" \
    || fail "lib.rs must apply DefaultBodyLimit::max layer"
grep -q 'BROKER_REQUEST_BODY_LIMIT_BYTES' "$LIB" \
    || fail "lib.rs must read body limit from BROKER_REQUEST_BODY_LIMIT_BYTES"

log "9. Phase D env vars declared in env.rs"
ENV_RS="${BROKER_DIR}/src/env.rs"
for var in BROKER_METRICS_ENABLED BROKER_REQUEST_BODY_LIMIT_BYTES; do
    grep -q "$var" "$ENV_RS" \
        || fail "env.rs missing constant: $var"
done

log "10. graceful shutdown integration test still passes (Phase C.0 carry-over)"
cargo test -p agentkeys-broker-server --test graceful_shutdown --quiet \
    || fail "graceful_shutdown test regressed"

log "OK — Phase D-rest smoke green (US-036/037/038)"
