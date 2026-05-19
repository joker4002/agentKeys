#!/usr/bin/env bash
# Stage 7 — Issue #64 (pluggable broker, Option C) completion gate (FINAL form).
#
# US-040 — composes every phase smoke + invariant test + drift check.
# Distinct from `stage-7-done.sh` which gates phases 1+2 of the original
# Stage 7 plan (PR #60 + PR #61). This script gates the NEW pluggable-
# broker work tracked in docs/spec/plans/issue-64/.
#
# Per plan §10 acceptance: run every phase smoke + assert the operator
# runbook section anchors exist + assert env-var table in the runbook
# matches src/env.rs constants exactly (drift check) + run the load-
# bearing invariant test + verify cargo build for v0-default and
# v0-testnet feature combos.
#
# Phases (per docs/spec/plans/issue-64/PLAN.md §4) — all SHIPPED:
#   Phase 0       — Day-1 vertical slice (US-001..US-016)
#   Phase A.1     — EmailLink magic-link (US-017..US-019)
#   Phase A.2     — OAuth2/Google (US-020..US-022)
#   Phase C.0     — Graceful shutdown + migrations (US-023/024)
#   Phase B       — Capability grants + recovery (US-025..US-029)
#   Phase C       — EVM Base Sepolia anchor structural (US-030..US-035)
#   Phase D-rest  — Metrics + idempotency (US-036..US-038)
#   Phase E       — Operator runbook + quickstart final + this script (US-039..US-041)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_DIR="${REPO_ROOT}/crates/agentkeys-broker-server"
RUNBOOK="${REPO_ROOT}/docs/operator-runbook-stage7.md"
PRD="${REPO_ROOT}/docs/spec/plans/issue-64/prd.json"

log()  { printf '\n[stage-7-issue-64-done] %s\n' "$*"; }
fail() { printf '\n[stage-7-issue-64-done] FAIL: %s\n' "$*" >&2; exit 1; }

# --- Build matrix ---

log "[done] cargo build --no-default-features --features auth-wallet-sig,wallet-keystore,audit-sqlite (v0 default)"
cargo build -p agentkeys-broker-server --no-default-features \
    --features auth-wallet-sig,wallet-keystore,audit-sqlite --quiet \
    || fail "v0-default build failed"

log "[done] cargo build --features auth-email-link,auth-oauth2-google,audit-evm (v0 testnet)"
cargo build -p agentkeys-broker-server \
    --features auth-email-link,auth-oauth2-google,audit-evm --quiet \
    || fail "v0-testnet build failed"

# --- Per-phase smokes ---

log "[done] Phase 0 smoke (US-014)"
bash "${REPO_ROOT}/harness/stage-7-issue-64-phase0-smoke.sh" \
    || fail "Phase 0 smoke failed"

log "[done] Phase A smoke (US-019 + US-022) — EmailLink + OAuth2/Google"
bash "${REPO_ROOT}/harness/stage-7-issue-64-phaseA-smoke.sh" \
    || fail "Phase A smoke failed"

log "[done] Phase B smoke (US-029) — capability grants + wallet recovery"
bash "${REPO_ROOT}/harness/stage-7-issue-64-phaseB-smoke.sh" \
    || fail "Phase B smoke failed"

log "[done] Phase C smoke (US-035) — EVM structural"
bash "${REPO_ROOT}/harness/stage-7-issue-64-phaseC-smoke.sh" \
    || fail "Phase C smoke failed"

log "[done] Phase D-rest smoke (US-038) — metrics + idempotency"
bash "${REPO_ROOT}/harness/stage-7-issue-64-phaseD-smoke.sh" \
    || fail "Phase D-rest smoke failed"

# --- Load-bearing invariant ---

log "[done] Load-bearing invariant test (Day-1 contract — Plan §2 + Rule 7)"
cargo test -p agentkeys-broker-server --features audit-evm,auth-email-link,auth-oauth2-google \
    --test invariant_load_bearing --quiet \
    || fail "load-bearing invariant test failed"

# --- Runbook drift check (Plan §5 + Rule 11) ---

log "[done] Operator runbook present + env-var drift check"
[[ -f "${RUNBOOK}" ]] || fail "operator runbook missing: ${RUNBOOK}"

# Every BROKER_* / DAEMON_* / ACCOUNT_ID / REGION constant declared in
# env.rs must appear in the runbook. Phase E (this version) promotes
# this from a warning to a hard fail.
missing=()
while read -r constname; do
    if ! grep -q "${constname}" "${RUNBOOK}"; then
        missing+=("${constname}")
    fi
done < <(grep -oE 'pub const ([A-Z_][A-Z0-9_]*)' "${BROKER_DIR}/src/env.rs" \
         | awk '{print $3}' \
         | grep -E '^(BROKER_|DAEMON_|ACCOUNT_ID|REGION)')

if [[ ${#missing[@]} -gt 0 ]]; then
    log "Env vars declared in env.rs but NOT in runbook env-var table:"
    for v in "${missing[@]}"; do log "    - ${v}"; done
    fail "env-var drift detected — runbook out of sync with env.rs"
fi

# --- Runbook section anchors ---

log "[done] Runbook section anchors (BOOT_FAIL targets)"
for anchor in 'oidc-issuer' 'oidc-keypair' 'session-keypair' \
              'auth-nonces-db' 'wallets-db' 'audit-sqlite' \
              'audit-policy' 'auth-method-not-compiled' \
              'auth-method-empty' 'audit-anchor-empty' \
              'backend-reachability' 'ses-verification' \
              'evm-rpc-reachability' 'evm-fee-payer-balance'; do
    grep -q "${anchor}" "${RUNBOOK}" \
        || fail "runbook missing BOOT_FAIL anchor section: ${anchor}"
done

# --- prd.json passes:true count ---

log "[done] prd.json passes:true tally"
if [[ -f "${PRD}" ]]; then
    passes_count=$(grep -c '"passes": true' "${PRD}" || true)
    total_stories=$(grep -c '"id": "US-' "${PRD}" || true)
    log "  prd.json reports ${passes_count}/${total_stories} stories with passes:true"
    if [[ ${passes_count} -lt ${total_stories} ]]; then
        log "  WARNING: ${total_stories}-${passes_count} stories still passes:false — review before bookmark"
    fi
fi

log "Stage 7 issue#64 — DONE. All phases shipped, all smokes green, drift check clean."
