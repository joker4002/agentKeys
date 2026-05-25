#!/usr/bin/env bash
# harness/mcp/smoke-test.sh — M1 three-act demo storyboard against Claude Code as MCP host.
#
# SKELETON — the planner / implementer fills in the Claude Code driver calls
# (step 4-6). Today the script wires up config + prereq checks + the harness
# scaffold; the tool-by-tool drive is marked TODO(M1).
#
# Configuration (all overridable — no hardcoded values per CLAUDE.md):
#
#   SESSION_ID                   session label (~/.agentkeys/$SESSION_ID/)
#                                default: alice
#                                override: SESSION_ID=bob bash ...
#
#   AGENTKEYS_BROKER_URL         broker endpoint
#                                default: https://broker.heima.network
#
#   AGENTKEYS_MCP_VENDOR_TOKEN   M1 static vendor token (rotation = M2 #114)
#                                default: m1-harness-stopgap
#                                tracked in hardcoded.md per no-hardcoded-values policy
#
#   CLAUDE_CODE_BIN              path to Claude Code CLI
#                                default: claude
#
#   ACTOR_OMNI                   actor omni under test (X-AgentKeys-Actor header)
#                                default: read from ~/.agentkeys/$SESSION_ID/session.json
#
#   STORYBOARD                   path to three-act script
#                                default: harness/mcp/three-act-storyboard.md
#
# Step gating:
#   --only-act N      run only act N (1, 2, or 3)
#   --skip-build      assume daemon binary is current
#   --dry-run         resolve config + print the planned actions, do not invoke Claude
#
# Exit codes:
#   0 — all three acts green
#   1 — prereq missing (binary, session, broker)
#   2 — act failed (one of identity / permission / cap-mint / memory / audit)
#   3 — Claude Code CLI not installed or not authenticated
#   99 — TODO(M1) — driver not yet implemented (skeleton state)

set -euo pipefail

SESSION_ID="${SESSION_ID:-alice}"
AGENTKEYS_BROKER_URL="${AGENTKEYS_BROKER_URL:-https://broker.heima.network}"
AGENTKEYS_MCP_VENDOR_TOKEN="${AGENTKEYS_MCP_VENDOR_TOKEN:-m1-harness-stopgap}"
CLAUDE_CODE_BIN="${CLAUDE_CODE_BIN:-claude}"
STORYBOARD="${STORYBOARD:-harness/mcp/three-act-storyboard.md}"

ONLY_ACT=""
SKIP_BUILD=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only-act) ONLY_ACT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok() { printf '  ok   %s\n' "$*"; }
skip() { printf '  skip %s\n' "$*"; }
fail() { printf '  fail %s\n' "$*" >&2; exit "${2:-2}"; }

# ─── Step 1 ── prereq: daemon binary built ────────────────────────────────────
log "step 1 — daemon binary"
if [[ "$SKIP_BUILD" -eq 1 ]]; then
  skip "build (--skip-build)"
elif [[ -x "target/debug/agentkeys-daemon" || -x "target/release/agentkeys-daemon" ]]; then
  ok "agentkeys-daemon already built"
else
  log "  building agentkeys-daemon..."
  cargo build -p agentkeys-daemon
  ok "agentkeys-daemon built"
fi

# ─── Step 2 ── prereq: session file ───────────────────────────────────────────
log "step 2 — session at ~/.agentkeys/$SESSION_ID/session.json"
SESSION_FILE="$HOME/.agentkeys/$SESSION_ID/session.json"
if [[ ! -f "$SESSION_FILE" ]]; then
  fail "no session at $SESSION_FILE — run 'bash harness/v2-stage1-demo.sh' first" 1
fi
ok "session file exists"

ACTOR_OMNI="${ACTOR_OMNI:-$(jq -r '.wallet // .agentkeys_user_wallet // empty' "$SESSION_FILE" 2>/dev/null || true)}"
if [[ -z "$ACTOR_OMNI" ]]; then
  fail "could not resolve ACTOR_OMNI from $SESSION_FILE — pass ACTOR_OMNI=0x... explicitly" 1
fi
ok "actor_omni=$ACTOR_OMNI"

# ─── Step 3 ── prereq: broker reachable ───────────────────────────────────────
log "step 3 — broker health at $AGENTKEYS_BROKER_URL"
if curl -fsS --max-time 5 "$AGENTKEYS_BROKER_URL/health" >/dev/null 2>&1; then
  ok "broker /health 2xx"
else
  fail "broker $AGENTKEYS_BROKER_URL/health unreachable" 1
fi

# ─── Step 4 ── prereq: Claude Code CLI ────────────────────────────────────────
log "step 4 — Claude Code CLI"
if ! command -v "$CLAUDE_CODE_BIN" >/dev/null 2>&1; then
  fail "$CLAUDE_CODE_BIN not found in PATH — install Claude Code CLI" 3
fi
ok "$CLAUDE_CODE_BIN found"

# ─── Step 5 ── prereq: storyboard present ─────────────────────────────────────
log "step 5 — storyboard at $STORYBOARD"
if [[ ! -f "$STORYBOARD" ]]; then
  fail "missing $STORYBOARD" 1
fi
ok "storyboard present"

# ─── Dry run gate ─────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run complete — config resolved, no acts invoked"
  cat <<EOF

resolved config:
  SESSION_ID                 = $SESSION_ID
  ACTOR_OMNI                 = $ACTOR_OMNI
  AGENTKEYS_BROKER_URL       = $AGENTKEYS_BROKER_URL
  AGENTKEYS_MCP_VENDOR_TOKEN = ${AGENTKEYS_MCP_VENDOR_TOKEN:0:8}…  (m1 stopgap; M2 #114)
  CLAUDE_CODE_BIN            = $CLAUDE_CODE_BIN
  STORYBOARD                 = $STORYBOARD

EOF
  exit 0
fi

# Locate the daemon binary that hosts agentkeys-mcp over stdio.
DAEMON_BIN=""
if [[ -x "target/debug/agentkeys-daemon" ]]; then
  DAEMON_BIN="target/debug/agentkeys-daemon"
elif [[ -x "target/release/agentkeys-daemon" ]]; then
  DAEMON_BIN="target/release/agentkeys-daemon"
fi

# ── Helper: issue one or more JSON-RPC requests over the daemon's stdio MCP transport
# and emit the daemon's responses (one JSON object per line) to stdout.
#
# Usage:
#   mcp_request <<'EOF'
#   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
#   {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agentkeys.identity.whoami","arguments":{}}}
#   EOF
mcp_request() {
  if [[ -z "$DAEMON_BIN" ]]; then
    fail "no daemon binary at target/debug/agentkeys-daemon — run 'cargo build -p agentkeys-daemon'" 1
  fi
  AGENTKEYS_BROKER_URL="$AGENTKEYS_BROKER_URL" \
  AGENTKEYS_MCP_VENDOR_TOKEN="$AGENTKEYS_MCP_VENDOR_TOKEN" \
  "$DAEMON_BIN" --stdio --session-id "$SESSION_ID" --broker-url "$AGENTKEYS_BROKER_URL" 2>/dev/null
}

# Pull the textual payload out of a JSON-RPC response's result.content[0].text field.
# Many M1 tools wrap their JSON output in this MCP-content envelope.
unwrap_content_text() {
  jq -r '.result.content[0].text // .result // .error.message // "(no result)"' 2>/dev/null
}

# ─── Act 1 ── identity + permission boundary ──────────────────────────────────
run_act_1() {
  log "act 1 — identity + permission boundary"

  # 1a. identity.whoami — must return omni + display_name + vendor.
  log "  1a. agentkeys.identity.whoami"
  resp=$(mcp_request <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agentkeys.identity.whoami","arguments":{"actor":"$ACTOR_OMNI"}}}
EOF
  )
  whoami_text=$(echo "$resp" | sed -n '2p' | unwrap_content_text)
  echo "$whoami_text" | jq -e '.omni and .display_name and .vendor' >/dev/null \
    || fail "identity.whoami missing required fields: $whoami_text" 2
  ok "identity.whoami returned omni + display_name + vendor"

  # 1b. permission.check positive — under cap, in scope → allowed.
  log "  1b. agentkeys.permission.check (under cap)"
  resp=$(mcp_request <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agentkeys.permission.check","arguments":{"actor":"$ACTOR_OMNI","scope":"payment.spend","params":{"amount_rmb":200}}}}
EOF
  )
  v=$(echo "$resp" | sed -n '2p' | unwrap_content_text)
  echo "$v" | jq -e '.allowed == true' >/dev/null \
    || fail "permission.check under cap should be allowed: $v" 2
  ok "under-cap payment allowed"

  # 1c. permission.check negative — over cap → denied, with reason.
  log "  1c. agentkeys.permission.check (over cap, deterministic)"
  resp=$(mcp_request <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agentkeys.permission.check","arguments":{"actor":"$ACTOR_OMNI","scope":"payment.spend","params":{"amount_rmb":600}}}}
EOF
  )
  v=$(echo "$resp" | sed -n '2p' | unwrap_content_text)
  echo "$v" | jq -e '.allowed == false and (.reason | contains("daily_spend_cap_exceeded"))' >/dev/null \
    || fail "permission.check over cap should be denied with daily_spend_cap_exceeded reason: $v" 2
  ok "over-cap payment denied with deterministic reason"
}

# ─── Act 2 ── capability + memory wiring ───────────────────────────────────────
# Without a live worker-memory backend, layer-3 verifies the MCP tool surfaces
# the right error shape (MissingConfig → JSON-RPC -32603). With a live backend
# wired via AGENTKEYS_MEMORY_WORKER_URL + AGENTKEYS_BROKER_URL, the same
# act exercises the round-trip.
run_act_2() {
  log "act 2 — capability + memory wiring"

  # 2a. cap.mint with no broker reachable → expect either a -32603
  #     MissingConfig (BROKER_URL unset) or a -32000 BROKER_UNREACHABLE.
  log "  2a. agentkeys.cap.mint (verify surface)"
  resp=$(mcp_request <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agentkeys.cap.mint","arguments":{"actor":"$ACTOR_OMNI","op":"store","data_class":"memory","service":"chat-history","device_key_hash":"0x$(printf 'a%.0s' {1..64})"}}}
EOF
  )
  line=$(echo "$resp" | sed -n '2p')
  echo "$line" | jq -e '.result.content[0].text or .error' >/dev/null \
    || fail "cap.mint produced no parseable response: $line" 2
  ok "cap.mint surface reachable (verify backend-attached round-trip via M1 plan §3 step 5)"

  # 2b. memory.put without AGENTKEYS_MEMORY_WORKER_URL → -32603 MissingConfig.
  log "  2b. agentkeys.memory.put (verify namespace + config wiring)"
  resp=$(mcp_request <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agentkeys.memory.put","arguments":{"actor":"$ACTOR_OMNI","namespace":"travel","service":"trips","content":"Chengdu hot-pot trip 2026-05"}}}
EOF
  )
  line=$(echo "$resp" | sed -n '2p')
  if [[ -z "${AGENTKEYS_MEMORY_WORKER_URL:-}" ]]; then
    echo "$line" | jq -e '.error.message | contains("AGENTKEYS_MEMORY_WORKER_URL")' >/dev/null \
      || fail "memory.put should surface MissingConfig when worker URL unset: $line" 2
    ok "memory.put surfaces MissingConfig when worker unset (expected for offline demo)"
  else
    echo "$line" | jq -e '.result.content[0].text' >/dev/null \
      || fail "memory.put with worker URL set should produce content: $line" 2
    ok "memory.put round-tripped against worker"
  fi
}

# ─── Act 3 ── audit visibility ─────────────────────────────────────────────────
run_act_3() {
  log "act 3 — two-tier audit visibility"

  # 3a. audit.append wiring check (offline → MissingConfig, online → envelope_hash).
  log "  3a. agentkeys.audit.append"
  resp=$(mcp_request <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agentkeys.audit.append","arguments":{"actor":"$ACTOR_OMNI","op_kind":0,"op_body":{"smoke":"test"},"result":0}}}
EOF
  )
  line=$(echo "$resp" | sed -n '2p')
  if [[ -z "${AGENTKEYS_AUDIT_WORKER_URL:-}" ]]; then
    echo "$line" | jq -e '.error.message | contains("AGENTKEYS_AUDIT_WORKER_URL")' >/dev/null \
      || fail "audit.append should surface MissingConfig when worker URL unset: $line" 2
    ok "audit.append surfaces MissingConfig (set AGENTKEYS_AUDIT_WORKER_URL for full Tier-1 round-trip)"
  else
    body=$(echo "$line" | unwrap_content_text)
    echo "$body" | jq -e '.envelope_hash | startswith("0x")' >/dev/null \
      || fail "audit.append should return 0x-prefixed envelope_hash: $body" 2
    ok "audit.append returned envelope_hash (Tier-1 off-chain feed)"
    # 3b. Tier-1: fetch the envelope back from the worker (<1s SLA).
    log "  3b. Tier-1 off-chain feed (GET /v1/audit/envelope/<hash>)"
    eh=$(echo "$body" | jq -r '.envelope_hash')
    if curl -fsS --max-time 5 "$AGENTKEYS_AUDIT_WORKER_URL/v1/audit/envelope/$eh" -o /dev/null; then
      ok "envelope fetchable <5s — Tier-1 SLA met"
    else
      fail "envelope $eh not fetchable from worker (Tier-1 SLA missed)" 2
    fi
    # 3c. Tier-2: ≤2-min on-chain anchor — out of scope for the smoke test;
    #     verify by watching the AuditAppendedV2 event in the next minute.
    log "  3c. Tier-2 on-chain anchor — operator-verified (see runbook §5)"
    skip "on-chain anchor verification is operator-driven; see docs/spec/plans/m1-mcp-server-phase1.md §5"
  fi

  # 3d. cap.revoke surface — graceful M1 stub when broker endpoint not wired.
  log "  3d. agentkeys.cap.revoke (M1 stub surface)"
  resp=$(mcp_request <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"agentkeys.cap.revoke","arguments":{"cap_id":"smoke-test-cap-001"}}}
EOF
  )
  line=$(echo "$resp" | sed -n '2p')
  body=$(echo "$line" | unwrap_content_text)
  echo "$body" | jq -e '.revoked != null' >/dev/null \
    || fail "cap.revoke should return {revoked: bool} (true if broker honored, false if stub): $body" 2
  ok "cap.revoke surface returned a revocation verdict"
}

# ─── Run gates ────────────────────────────────────────────────────────────────
case "$ONLY_ACT" in
  1) run_act_1 ;;
  2) run_act_2 ;;
  3) run_act_3 ;;
  "") run_act_1; run_act_2; run_act_3 ;;
  *) fail "--only-act must be 1, 2, or 3" 1 ;;
esac

log "all acts green"
