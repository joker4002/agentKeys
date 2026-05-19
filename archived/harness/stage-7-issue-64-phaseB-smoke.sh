#!/usr/bin/env bash
# Stage 7 issue#64 Phase B — smoke test (US-029).
#
# Per plan rule 10. Phase B covers capability grants (US-025/026/027)
# and master-gated wallet recovery (US-028). This script asserts:
#   1. cargo build (default features) — grants always compiled in.
#   2. cargo test (default + multi-feature) — green.
#   3. Dedicated grant_flow + wallet_flow integration suites green.
#   4. clippy -D warnings clean across feature combos.
#   5. grep-style invariants:
#      - GrantStore::try_consume uses ONE atomic SQL with RETURNING (no
#        Rust-level peek-then-update — Codex Phase A.2 round-2 V5 P1).
#      - audit_proof minted via session_keypair.sign_jwt (mint_grant_audit_proof).
#      - Grant errors map to BrokerError::Forbidden (403, not 401 —
#        Codex Phase A.2 round-3 V4 P2 closure).
#      - revoke endpoint message collapses ownership info (no leak).
#      - identity_links composite PK enforces idempotent link.
#      - recover_lookup is unauthenticated by design.
#      - wallet/link rejects cross-master claim with 401.
#
# Exits 0 on success.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_DIR="${REPO_ROOT}/crates/agentkeys-broker-server"

log()  { printf '\n[stage-7-phaseB-smoke] %s\n' "$*"; }
fail() { printf '\n[stage-7-phaseB-smoke] FAIL: %s\n' "$*" >&2; exit 1; }

log "1. cargo build (default features) — grants always compiled in"
cargo build -p agentkeys-broker-server --quiet \
    || fail "cargo build with default features failed"

log "2. cargo test (default features)"
cargo test -p agentkeys-broker-server --quiet \
    || fail "cargo test default failed"

log "3. cargo test --features auth-oauth2-google,auth-email-link"
cargo test -p agentkeys-broker-server --features auth-oauth2-google,auth-email-link --quiet \
    || fail "cargo test with full features failed"

log "4. Dedicated grant_flow integration suite"
cargo test -p agentkeys-broker-server --features auth-oauth2-google,auth-email-link \
    --test grant_flow --quiet \
    || fail "tests/grant_flow.rs failed"

log "5. Dedicated wallet_flow integration suite"
cargo test -p agentkeys-broker-server --features auth-oauth2-google,auth-email-link \
    --test wallet_flow --quiet \
    || fail "tests/wallet_flow.rs failed"

log "6. cargo clippy --features auth-oauth2-google,auth-email-link -D warnings"
cargo clippy -p agentkeys-broker-server --features auth-oauth2-google,auth-email-link -- -D warnings \
    || fail "clippy reported warnings"

log "7. GrantStore::try_consume is one atomic SQL with RETURNING"
GRANTS="${BROKER_DIR}/src/storage/grants.rs"
[[ -f "$GRANTS" ]] || fail "missing grants storage: $GRANTS"
grep -q 'UPDATE grants' "$GRANTS" \
    || fail "grants.rs must use UPDATE … in try_consume"
grep -q 'RETURNING grant_id, audit_proof' "$GRANTS" \
    || fail "grants.rs must use RETURNING for atomic consume (Phase A.2 round-2 V5 P1)"
# The diagnostic SELECT runs ONLY after the atomic UPDATE returned 0 rows.
grep -q 'classify grant\|classify_why_no_consume\|None => Ok(GrantConsumeOutcome::NoGrant)' "$GRANTS" \
    || fail "grants.rs must run diagnostic SELECT only on no-rows-consumed"

log "8. audit_proof minted via session_keypair (mint_grant_audit_proof)"
ISSUE_RS="${BROKER_DIR}/src/jwt/issue.rs"
grep -q 'fn mint_grant_audit_proof' "$ISSUE_RS" \
    || fail "jwt/issue.rs must export mint_grant_audit_proof"
grep -q 'agentkeys:audit-proof' "$ISSUE_RS" \
    || fail "audit_proof JWT must use aud=agentkeys:audit-proof"

log "9. Grant errors map to BrokerError::Forbidden (403, not 401)"
ERROR_RS="${BROKER_DIR}/src/error.rs"
grep -q 'Forbidden' "$ERROR_RS" \
    || fail "error.rs must declare BrokerError::Forbidden variant"
grep -q 'StatusCode::FORBIDDEN' "$ERROR_RS" \
    || fail "Forbidden must map to StatusCode::FORBIDDEN (403)"
MINT="${BROKER_DIR}/src/handlers/mint.rs"
grep -q 'BrokerError::Forbidden' "$MINT" \
    || fail "mint.rs Revoked/Expired/Exhausted must return BrokerError::Forbidden"

log "10. Revoke endpoint collapses ownership info (no enum leak)"
REVOKE="${BROKER_DIR}/src/handlers/grant/revoke.rs"
grep -q 'not found, not owned by this master, or already revoked' "$REVOKE" \
    || fail "revoke handler must collapse error message to defeat enumeration"

log "11. identity_links uses composite PK"
ID_LINKS="${BROKER_DIR}/src/storage/identity_links.rs"
grep -q 'PRIMARY KEY (omni_account, identity_type, identity_value)' "$ID_LINKS" \
    || fail "identity_links must have composite PK (omni, type, value)"
grep -q 'INSERT OR IGNORE' "$ID_LINKS" \
    || fail "identity_links link() must be idempotent (INSERT OR IGNORE)"

log "12. recover_lookup is unauthenticated by design"
RECOVER="${BROKER_DIR}/src/handlers/wallet/recover_lookup.rs"
[[ -f "$RECOVER" ]] || fail "missing recover_lookup handler: $RECOVER"
# Should NOT call require_master_session (it's the only handler that doesn't)
if grep -q 'require_master_session\|require_session_jwt' "$RECOVER"; then
    fail "recover_lookup MUST be unauthenticated (Phase B US-028 contract)"
fi

log "13. /v1/wallet/link rejects cross-master claim with 401"
LINK="${BROKER_DIR}/src/handlers/wallet/link.rs"
grep -q 'identity already linked to a different master' "$LINK" \
    || fail "wallet/link must reject cross-master claim with explicit message"

log "14. New env vars + endpoints registered"
LIB="${BROKER_DIR}/src/lib.rs"
for route in '/v1/grant/create' '/v1/grant/revoke' '/v1/grant/list' \
             '/v1/wallet/link' '/v1/wallet/links' '/v1/wallet/recover/lookup'; do
    grep -q "\"$route\"" "$LIB" \
        || fail "lib.rs must register route: $route"
done

log "OK — Phase B smoke green (US-025/026/027/028)"
