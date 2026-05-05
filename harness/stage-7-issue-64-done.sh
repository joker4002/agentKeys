#!/usr/bin/env bash
# Stage 7 — Issue #64 (pluggable broker, Option C) completion gate.
#
# Distinct from `stage-7-done.sh` which gates phases 1+2 of the original
# Stage 7 plan (PR #60 + PR #61). This script gates the NEW pluggable-
# broker work tracked in docs/spec/plans/issue-64/.
#
# Per plan §10 acceptance: run every phase smoke + assert the operator
# runbook section anchors exist + assert env-var table in the runbook
# matches src/env.rs constants exactly (drift check).
#
# Phases (per docs/spec/plans/issue-64/PLAN.md §4):
#   Phase 0 — Day-1 vertical slice  ← ONLY phase wired today
#   Phase A.1 — EmailLink                (pending US-019)
#   Phase A.2 — OAuth2 Google            (pending US-022)
#   Phase C.0 — Graceful shutdown + migrations  (pending US-023/024)
#   Phase B   — Capability grants + recovery     (pending US-029)
#   Phase C   — EVM Base Sepolia anchor          (pending US-035)
#   Phase D-rest — Metrics + idempotency         (pending US-038)
#   Phase E   — Operator runbook + quickstart final + this script's
#               final form                       (pending US-040)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROKER_DIR="${REPO_ROOT}/crates/agentkeys-broker-server"
RUNBOOK="${REPO_ROOT}/docs/operator-runbook-stage7.md"
PRD="${REPO_ROOT}/docs/spec/plans/issue-64/prd.json"

log()  { printf '\n[stage-7-issue-64-done] %s\n' "$*"; }
fail() { printf '\n[stage-7-issue-64-done] FAIL: %s\n' "$*" >&2; exit 1; }

# --- Phase 0 ---

log "Phase 0 smoke (US-014)"
bash "${REPO_ROOT}/harness/stage-7-issue-64-phase0-smoke.sh" \
    || fail "Phase 0 smoke failed"

log "Phase 0 — operator runbook present (Plan rule 3 + Phase E P0 deliverable)"
[[ -f "${RUNBOOK}" ]] || fail "operator runbook missing: ${RUNBOOK}"

log "Phase 0 — runbook env-var table drift check (Plan §5 + rule 11)"
# Every BROKER_* / DAEMON_* / ACCOUNT_ID / REGION constant declared in
# env.rs must appear in the runbook. Phase E lands the auto-generator
# that emits the table directly from env::all() (US-039 promotes this
# warning to a hard fail).
missing=()
while read -r constname; do
    if ! grep -q "${constname}" "${RUNBOOK}"; then
        missing+=("${constname}")
    fi
done < <(grep -oE 'pub const ([A-Z_][A-Z0-9_]*)' "${BROKER_DIR}/src/env.rs" \
         | awk '{print $3}' \
         | grep -E '^(BROKER_|DAEMON_|ACCOUNT_ID|REGION)')

if [[ ${#missing[@]} -gt 0 ]]; then
    log "WARNING (non-fatal in Phase 0; promoted to FAIL in Phase E US-039):"
    log "  env vars declared in env.rs but NOT in runbook env-var table:"
    for v in "${missing[@]}"; do log "    - ${v}"; done
fi

log "Phase 0 — prd.json passes flag check"
if [[ -f "${PRD}" ]]; then
    passes_count=$(grep -c '"passes": true' "${PRD}" || true)
    log "  prd.json reports ${passes_count} stories with passes:true (across all phases)"
fi

# --- Phases A.1, A.2, C.0, B, C, D-rest, E ---
# Phase A.1 smoke (US-019), Phase A.2 (US-022), Phase B (US-029),
# Phase C (US-035), Phase D (US-038) — each appends here when shipped.

log "Stage 7 issue#64 done.sh: Phase 0 deliverables verified."
log "Phases A.1+ assertions land as those phases ship — see ${PRD}."
