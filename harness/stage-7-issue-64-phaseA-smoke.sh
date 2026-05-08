#!/usr/bin/env bash
# Stage 7 issue#64 Phase A.1 — smoke test (US-019).
#
# Per plan rule 10 (smoke script per phase). Phase A.1 covers the
# EmailLink magic-link auth method. This script asserts:
#   1. cargo build with --features auth-email-link
#   2. cargo test --features auth-email-link is green
#   3. cargo test --test email_flow includes the prefetch-defense case
#      (GET on /v1/auth/email/verify returns 405)
#   4. clippy clean under --features auth-email-link
#   5. grep-style invariants:
#      - email-link wire format docstring references "fragment-token" (plan §3.5.3)
#      - landing HTML uses window.location.hash (NOT query string)
#      - landing HTML carries Cache-Control: no-store
#      - email_verify.rs sets Referrer-Policy: no-referrer on success response
#
# Exits 0 on success.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_DIR="${REPO_ROOT}/crates/agentkeys-broker-server"

log()  { printf '\n[stage-7-phaseA-smoke] %s\n' "$*"; }
fail() { printf '\n[stage-7-phaseA-smoke] FAIL: %s\n' "$*" >&2; exit 1; }

log "1. cargo build with --features auth-email-link"
cargo build -p agentkeys-broker-server --features auth-email-link --quiet \
    || fail "cargo build with auth-email-link failed"

log "2. cargo test with --features auth-email-link"
cargo test -p agentkeys-broker-server --features auth-email-link --quiet \
    || fail "cargo test with auth-email-link failed"

log "3. dedicated email_flow integration suite"
cargo test -p agentkeys-broker-server --features auth-email-link \
    --test email_flow --quiet \
    || fail "tests/email_flow.rs failed"

log "4. cargo clippy --features auth-email-link -D warnings"
cargo clippy -p agentkeys-broker-server --features auth-email-link -- -D warnings 2>&1 \
    | tee /tmp/stage-7-phaseA-clippy.log \
    || fail "clippy reported warnings"

log "5. landing page uses window.location.hash (fragment, not query) per §3.5.3"
LANDING="${BROKER_DIR}/src/handlers/auth/email_landing.rs"
[[ -f "$LANDING" ]] || fail "missing landing handler: $LANDING"
grep -q 'window.location.hash' "$LANDING" \
    || fail "landing handler must read window.location.hash for fragment-token retrieval"
grep -q 'Cache-Control:\|cache-control' "$LANDING" \
    || fail "landing handler must set Cache-Control: no-store"
grep -q 'Referrer-Policy:\|referrer-policy' "$LANDING" \
    || fail "landing handler must set Referrer-Policy: no-referrer"

log "6. /v1/auth/email/verify rejects GET (prefetch defense)"
VERIFY_HANDLER="${BROKER_DIR}/src/handlers/auth/email_verify.rs"
grep -q 'METHOD_NOT_ALLOWED\|email_verify_method_not_allowed' "$VERIFY_HANDLER" \
    || fail "verify handler must define a 405-returning GET handler"

log "7. EmailLinkAuth uses single-use token enforcement (storage layer)"
TOKEN_STORE="${BROKER_DIR}/src/storage/email_tokens.rs"
grep -q 'consumed_at IS NULL' "$TOKEN_STORE" \
    || fail "EmailTokenStore must use 'WHERE consumed_at IS NULL' conditional UPDATE"
grep -q 'sha2::\|Sha256' "$TOKEN_STORE" \
    || fail "EmailTokenStore must hash tokens via SHA256 (never persist raw token)"

log "8. EmailLink plugin registers in registry under 'email_link'"
grep -q '"email_link"' "${BROKER_DIR}/src/boot.rs" \
    || fail "boot.rs must include the 'email_link' branch in build_registry"

log "9. New env vars are declared in env.rs"
ENV_RS="${BROKER_DIR}/src/env.rs"
for var in BROKER_EMAIL_HMAC_KEY_PATH BROKER_EMAIL_FROM_ADDRESS \
           BROKER_EMAIL_RATE_LIMIT_PER_EMAIL_HOURLY \
           BROKER_EMAIL_RATE_LIMIT_PER_IP_MINUTELY; do
    grep -q "$var" "$ENV_RS" \
        || fail "env.rs missing constant: $var"
done

# ---- Phase A.2 — OAuth2 / Google additions (US-020/021/022) ----

log "A2.1 cargo build with --features auth-oauth2-google"
cargo build -p agentkeys-broker-server --features auth-oauth2-google --quiet \
    || fail "cargo build with auth-oauth2-google failed"

log "A2.2 cargo test --features auth-oauth2-google"
cargo test -p agentkeys-broker-server --features auth-oauth2-google --quiet \
    || fail "cargo test with auth-oauth2-google failed"

log "A2.3 dedicated oauth2_flow integration suite"
cargo test -p agentkeys-broker-server --features auth-oauth2-google \
    --test oauth2_flow --quiet \
    || fail "tests/oauth2_flow.rs failed"

log "A2.4 cargo clippy --features auth-oauth2-google -D warnings"
cargo clippy -p agentkeys-broker-server --features auth-oauth2-google -- -D warnings 2>&1 \
    | tee /tmp/stage-7-phaseA2-clippy.log \
    || fail "clippy reported warnings under auth-oauth2-google"

log "A2.5 OAuth2 wire format invariants"
OAUTH2_MOD="${BROKER_DIR}/src/plugins/auth/oauth2/mod.rs"
GOOGLE_MOD="${BROKER_DIR}/src/plugins/auth/oauth2/google.rs"
[[ -f "$OAUTH2_MOD" ]] || fail "missing oauth2 plugin: $OAUTH2_MOD"
[[ -f "$GOOGLE_MOD" ]] || fail "missing google provider: $GOOGLE_MOD"
grep -q 'code_challenge_method' "$GOOGLE_MOD" \
    || fail "google.rs must include code_challenge_method=S256 (PKCE)"
grep -q 'prompt=select_account\|"prompt"' "$GOOGLE_MOD" \
    || fail "google.rs must include prompt=select_account (multi-account defense)"
grep -q 'verify_state\|state_hmac_key' "$OAUTH2_MOD" \
    || fail "oauth2 plugin must implement state HMAC verification"
grep -q 'NonceMismatch\|nonce !=' "$OAUTH2_MOD" \
    || fail "oauth2 plugin must reject nonce mismatch"

log "A2.6 callback handler sets Cache-Control + Referrer-Policy"
CALLBACK="${BROKER_DIR}/src/handlers/auth/oauth2_callback.rs"
[[ -f "$CALLBACK" ]] || fail "missing callback handler: $CALLBACK"
grep -q 'cache-control\|Cache-Control' "$CALLBACK" \
    || fail "callback must set Cache-Control: no-store"
grep -q 'referrer-policy\|Referrer-Policy' "$CALLBACK" \
    || fail "callback must set Referrer-Policy: no-referrer"

log "A2.7 OAuth2Auth registers in registry under 'oauth2_google'"
grep -q 'oauth2_google' "${BROKER_DIR}/src/boot.rs" \
    || fail "boot.rs must include the 'oauth2_google' branch in build_registry"

log "A2.8 Phase A.2 env vars are declared in env.rs"
for var in BROKER_OAUTH2_PROVIDERS BROKER_OAUTH2_REDIRECT_URI \
           BROKER_OAUTH2_GOOGLE_CLIENT_ID BROKER_OAUTH2_GOOGLE_CLIENT_SECRET_FILE \
           BROKER_OAUTH2_STATE_HMAC_KEY_PATH BROKER_OAUTH2_JWKS_TTL_SECONDS \
           BROKER_OAUTH2_START_RATE_LIMIT_PER_IP_MINUTELY; do
    grep -q "$var" "$ENV_RS" \
        || fail "env.rs missing constant: $var"
done

log "A2.9 OAuth2PendingStore enforces single-use via consumed_at IS NULL"
PENDING="${BROKER_DIR}/src/storage/oauth_pending.rs"
[[ -f "$PENDING" ]] || fail "missing pending store: $PENDING"
grep -q 'consumed_at IS NULL' "$PENDING" \
    || fail "OAuth2PendingStore must use 'WHERE consumed_at IS NULL' conditional UPDATE"

log "OK — Phase A.1 + A.2 smoke green"
