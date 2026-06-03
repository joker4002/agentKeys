#!/usr/bin/env bash
# OpenViking backend (agent-side) setup + test — runs INSIDE the aiosandbox.
#
# Scripted, idempotent form of docs/operator-runbook-openviking.md Steps 2–7:
# stands OpenViking up as the AgentKeys memory ENGINE behind the gate (Model B),
# then proves the gated -> OpenViking-ranked -> injected flow. Every step
# pre-checks + short-circuits (ok / skip / fail), like the other harness/ scripts,
# so it is safe to re-run.
#
# ASSUMES (the operator/Mac side + one-time installs are already done):
#   1. The agent is WIRED — ~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh
#      exists with the baked identity (run harness/phase1-wire-demo.sh on the Mac).
#      Step 0 recovers actor/operator omni + MCP URL + vendor token + bearer from it.
#   2. OpenViking is pip-installed (runbook Step 1: pip install openviking).
#   3. openviking-server init was run before (runbook Step 2). For a FRESH sandbox,
#      pass --init to run the interactive wizard as part of this script.
#
# UPLOAD then RUN (the server is long-running + init is interactive, so this runs
# INSIDE the sandbox — not via the one-shot /v1/shell/exec API):
#   # laptop, repo root:
#   curl -sS -X POST "${SANDBOX_URL:-http://localhost:8080}/v1/file/upload" \
#     -F "file=@harness/openviking-sandbox-setup.sh" -F "path=/home/gem/openviking-sandbox-setup.sh"
#   # sandbox (docker exec -it <container> bash):
#   bash ~/openviking-sandbox-setup.sh            # init already done before
#   bash ~/openviking-sandbox-setup.sh --init     # first time — run the init wizard too
#
# Flags:
#   --init      run `openviking-server init` (interactive) before starting (fresh sandbox)
#   --reload    force a fresh corpus load into a timestamped subdir (else idempotent skip)
#   --verify    extra safety check: kill openviking, prove the hook still injects (fallback)
#   --no-test   stop after wiring (skip the injection test)
#   -h|--help

set -uo pipefail

# ── config (env overridable; no hardcoded values per project policy) ──────────
OV="${OPENVIKING_ENDPOINT:-http://localhost:1933}"
OVUSER="${OPENVIKING_USER:-default}"
NS="${MEMORY_NS:-travel}"
CORPUS_SUBDIR="${CORPUS_SUBDIR:-sample}"
CORPUS_FILE="${CORPUS_FILE:-}"          # optional override; else the embedded corpus
HOOK="${AGENTKEYS_HOOK:-$HOME/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh}"
HEALTH_WAIT="${HEALTH_WAIT:-30}"        # seconds to wait for /health after starting
SEMANTIC_QUERY="${SEMANTIC_QUERY:-what are my dietary restrictions?}"
TEST_QUERY="${TEST_QUERY:-what about my peanut allergy?}"

DO_INIT=false; DO_RELOAD=false; DO_VERIFY=false; DO_TEST=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --init)    DO_INIT=true; shift ;;
    --reload)  DO_RELOAD=true; shift ;;
    --verify)  DO_VERIFY=true; shift ;;
    --no-test) DO_TEST=false; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ── output (CLAUDE.md ok/skip/fail convention) ───────────────────────────────
FAILED=0
log()  { printf '\n[ov-sandbox] %s\n' "$*"; }
ok()   { printf '  %-24s ok proceeding (%s)\n' "$1" "$2"; }
skip() { printf '  %-24s skip %s\n' "$1" "$2"; }
fail() { printf '  %-24s FAIL %s\n' "$1" "$2" >&2; FAILED=$((FAILED+1)); }

AK=""   # resolved agentkeys binary (Phase 0)
ov_health() { curl -fsS --max-time 5 "$OV/health" >/dev/null 2>&1; }

# Write one content item. Idempotent: mode:create -> "exists" on re-run. JSON is
# built with jq -n --arg (never a heredoc) per project policy. Echoes ok|exists|FAIL.
ov_write() {  # ov_write <uri> <content>
  local resp
  resp="$(curl -sS --max-time 20 -X POST "$OV/api/v1/content/write" -H 'content-type: application/json' \
    -d "$(jq -n --arg u "$1" --arg c "$2" '{uri:$u,content:$c,mode:"create"}')" 2>/dev/null)"
  if   echo "$resp" | jq -e '.result' >/dev/null 2>&1; then echo ok
  elif echo "$resp" | grep -qi exist;                  then echo exists
  else echo "FAIL:$(echo "$resp" | jq -rc '.error // .' 2>/dev/null | cut -c1-80)"; fi
}

# Embedded sample corpus (faithful copy of harness/fixtures/sample-memory.md so
# the script is self-contained — no second upload). '#' lines + blanks are skipped.
# A function (not a "$(cat <<EOF)" var): a heredoc inside command substitution
# misparses a lone apostrophe (e.g. "Wife's") under bash 3.2.
sample_corpus() {
  cat <<'CORPUS'
# Health & dietary
Severely allergic to peanuts; carry an EpiPen when eating out.
Lactose intolerant — oat milk in coffee, no cheese-heavy dishes.
Vegetarian on weekdays, eat fish on weekends.
Blood type O negative; last donation was in February.
Mild asthma, inhaler kept in the laptop bag.
Prefer morning workouts; run 5k three times a week.
# Travel
Booked a Chengdu trip Apr 12–16, staying in the Yulin hotpot district.
Tokyo conference last March; stayed in Shibuya near the station.
Window seat on flights, aisle on overnight trains.
Global Entry expires next year — renew before the summer.
Hate red-eye flights; prefer to land before 8pm local.
Visited Lisbon and Porto two summers ago; loved the pastel de nata.
# Family & people
Wife's birthday is August 3rd; she has been hinting at hiking boots.
Mom prefers phone calls over text; call her Sunday evenings.
Daughter Mia is 7, into dinosaurs and swimming lessons on Tuesdays.
Best friend Daniel is allergic to cats — no cat cafes when he visits.
Anniversary is October 19th; last year we went to Napa.
# Work & projects
Leading the payments-reliability project; on-call rotation every third week.
Manager 1:1s are Thursday at 2pm; keep a running agenda doc.
Prefer async standups over meetings; mornings are deep-work blocks.
Shipped the fraud-detection model in Q1; revisit thresholds in Q3.
# Finance
Max out the 401k each year; rebalance the index funds every January.
Keep a 6-month emergency fund in a high-yield savings account.
Travel rewards card for flights; cashback card for groceries.
CORPUS
}

# ── Phase 0 — prereqs + recover the wired agent identity ──────────────────────
phase0_prereqs() {
  log "Phase 0 — prereqs + recover wired identity"
  for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || { fail "0 $tool" "missing — install it in the sandbox"; }
  done
  AK="$(command -v agentkeys 2>/dev/null || echo "$HOME/.local/bin/agentkeys")"
  [[ -x "$AK" ]] && ok "0 agentkeys" "$AK" \
    || fail "0 agentkeys" "not found — run harness/phase1-wire-demo.sh on the Mac (uploads it)"

  if [[ ! -f "$HOOK" ]]; then
    fail "0 hook" "no wired hook ($HOOK) — run harness/phase1-wire-demo.sh on the Mac first"
    return 1
  fi
  # Recover actor/operator omni + MCP URL + vendor token + session bearer that
  # `agentkeys wire` baked into the hook header (same as runbook Step 6a). The
  # grep filter means only these 5 exports are eval'd — never the hook body.
  eval "$(grep -E '^export AGENTKEYS_(ACTOR_OMNI|OPERATOR_OMNI|MCP_URL|MCP_VENDOR_TOKEN|SESSION_BEARER)=' "$HOOK" 2>/dev/null)"
  if [[ -z "${AGENTKEYS_ACTOR_OMNI:-}" || -z "${AGENTKEYS_OPERATOR_OMNI:-}" ]]; then
    fail "0 identity" "could not recover actor/operator omni from the hook header"
    return 1
  fi
  export AGENTKEYS_ACTOR_OMNI AGENTKEYS_OPERATOR_OMNI AGENTKEYS_MCP_URL \
         AGENTKEYS_MCP_VENDOR_TOKEN AGENTKEYS_SESSION_BEARER
  ok "0 identity" "actor ${AGENTKEYS_ACTOR_OMNI:0:14}…  mcp ${AGENTKEYS_MCP_URL:-?}  bearer=${AGENTKEYS_SESSION_BEARER:+set}"
}

# ── Phase 1 — openviking installed ────────────────────────────────────────────
phase1_installed() {
  log "Phase 1 — openviking installed?"
  if command -v openviking-server >/dev/null 2>&1 || python3 -c 'import openviking' 2>/dev/null; then
    ok "1 openviking" "present ($(command -v openviking-server 2>/dev/null || echo 'python module'))"
  else
    fail "1 openviking" "not installed — run: pip install openviking (runbook Step 1)"
    return 1
  fi
}

# ── Phase 2 — init (interactive wizard; only with --init or when detectably fresh)
phase2_init() {
  log "Phase 2 — openviking-server init"
  if [[ "$DO_INIT" == true ]]; then
    log "  running interactive wizard — answer per runbook Step 2 (mode 2 local-embed, BGE, Skip VLM)…"
    if openviking-server init; then ok "2 init" "wizard completed"
    else fail "2 init" "wizard exited non-zero"; return 1; fi
  elif ov_health; then
    skip "2 init" "server already healthy → already configured"
  elif [[ -d "$HOME/.openviking" || -d "$HOME/.config/openviking" || -n "${OPENVIKING_HOME:-}" ]]; then
    skip "2 init" "config dir present → assuming configured (re-run with --init to reconfigure)"
  else
    skip "2 init" "no config detected — assuming setup was run before; pass --init if this is a fresh sandbox"
  fi
}

# ── Phase 3 — start server + health (idempotent) ──────────────────────────────
phase3_serve() {
  log "Phase 3 — start server + health ($OV)"
  if ov_health; then ok "3 server" "already up + healthy"; return 0; fi
  if pgrep -f openviking-server >/dev/null 2>&1; then
    skip "3 server" "process up but /health not ready — waiting"
  else
    log "  starting: nohup openviking-server >~/openviking.log 2>&1 &"
    nohup openviking-server >"$HOME/openviking.log" 2>&1 &
  fi
  local i=0
  while [[ $i -lt $HEALTH_WAIT ]]; do ov_health && break; sleep 1; i=$((i+1)); done
  if ov_health; then
    ok "3 server" "up + healthy after ${i}s"
  else
    fail "3 server" "/health not OK after ${HEALTH_WAIT}s — not configured? run with --init (runbook Step 2). last log: $(tail -2 "$HOME/openviking.log" 2>/dev/null | tr '\n' ' ' | cut -c1-110)"
    return 1
  fi
}

# ── Phase 4 — load sample corpus + a direct semantic query (engine-only proof) ─
phase4_corpus() {
  log "Phase 4 — load sample corpus + direct semantic query"
  local subdir="$CORPUS_SUBDIR"
  [[ "$DO_RELOAD" == true ]] && subdir="${CORPUS_SUBDIR}-$(date +%s)"
  local n=0 good=0 uri verdict
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    uri="viking://user/$OVUSER/memories/$subdir/mem_$(printf '%03d' "$n").md"
    verdict="$(ov_write "$uri" "$line")"
    case "$verdict" in ok|exists) good=$((good+1)) ;; *) echo "    write[$n] $verdict" >&2 ;; esac
    n=$((n+1))
  done < <(if [[ -n "$CORPUS_FILE" && -f "$CORPUS_FILE" ]]; then cat "$CORPUS_FILE"; else sample_corpus; fi)
  [[ $good -gt 0 ]] && ok "4 corpus" "loaded/present $good of $n into subdir '$subdir' (idempotent)" \
                    || { fail "4 corpus" "no facts loaded — see writes above"; return 1; }

  local hits
  hits="$(curl -sS --max-time 20 -X POST "$OV/api/v1/search/find" -H 'content-type: application/json' \
    -d "$(jq -n --arg q "$SEMANTIC_QUERY" '{query:$q, top_k:5}')" 2>/dev/null \
    | jq -rc '[.result.memories[]? | {score, uri}] | .[0:3]' 2>/dev/null)"
  if [[ -n "$hits" && "$hits" != "[]" && "$hits" != "null" ]]; then
    ok "4 semantic" "query \"$SEMANTIC_QUERY\" → top: $hits"
  else
    skip "4 semantic" "no ranked hits yet (index warming, or Skip-VLM empty abstract — ranking still by score/uri)"
  fi
}

# ── Phase 5 — mirror the REAL gate-authorized namespace lines into OpenViking ──
# The gate text-matches OpenViking hits back to authorized lines, so OpenViking
# must hold exactly what memory.get returns for the namespace. Force passthrough
# to read the FULL namespace (not an already-openviking-ranked subset).
phase5_mirror() {
  log "Phase 5 — mirror real '$NS' namespace lines into OpenViking"
  local ctx
  ctx="$(AGENTKEYS_MEMORY_ENGINE=passthrough "$AK" hook memory-inject --namespaces "$NS" </dev/null 2>/dev/null \
        | jq -r '.context // empty' 2>/dev/null)"
  if [[ -z "$ctx" ]]; then
    skip "5 mirror" "namespace '$NS' empty (seed via memory.put or wire demo --webauthn) — Phase 7 gated inject will be empty"
    return 0
  fi
  local m=0 good=0 uri verdict
  while IFS= read -r line; do
    case "$line" in ''|'## Memory:'*) continue ;; esac
    uri="viking://user/$OVUSER/memories/$NS/mem_$(printf '%03d' "$m").md"
    verdict="$(ov_write "$uri" "$line")"
    case "$verdict" in ok|exists) good=$((good+1)) ;; *) echo "    mirror[$m] $verdict" >&2 ;; esac
    m=$((m+1))
  done < <(printf '%s\n' "$ctx")
  [[ $good -gt 0 ]] && ok "5 mirror" "mirrored $good '$NS' line(s) into OpenViking (text-matched by the gate)" \
                    || skip "5 mirror" "no mirrorable lines parsed from the namespace block"
}

# ── Phase 6 — re-wire so the hook uses OpenViking as the engine ────────────────
phase6_wire() {
  log "Phase 6 — re-wire hook with --memory-engine openviking"
  if "$AK" wire hermes \
       --actor-omni "$AGENTKEYS_ACTOR_OMNI" --operator-omni "$AGENTKEYS_OPERATOR_OMNI" \
       --namespaces "$NS" \
       --memory-engine openviking --openviking-endpoint "$OV" \
       --mcp-url "$AGENTKEYS_MCP_URL" --vendor-token "$AGENTKEYS_MCP_VENDOR_TOKEN" >/dev/null 2>&1; then
    if grep -qiE 'AGENTKEYS_MEMORY_ENGINE=.*openviking' "$HOOK" && grep -q 'OPENVIKING_ENDPOINT=' "$HOOK"; then
      ok "6 wire" "hook now bakes openviking engine + endpoint $OV"
    else
      fail "6 wire" "wire ran but the hook is missing the openviking env"
    fi
  else
    fail "6 wire" "agentkeys wire failed (MCP/identity?) — re-run after fixing Phase 0"
  fi
}

# ── Phase 7 — gated -> OpenViking-ranked -> injected ──────────────────────────
phase7_test() {
  [[ "$DO_TEST" == true ]] || { skip "7 test" "--no-test"; return 0; }
  log "Phase 7 — gated → OpenViking-ranked → injected"
  local out ctx
  out="$(printf '%s' "$(jq -n --arg q "$TEST_QUERY" '{query:$q}')" | bash "$HOOK" 2>/dev/null)"
  ctx="$(echo "$out" | jq -r '.context // empty' 2>/dev/null)"
  if [[ -n "$ctx" ]]; then
    ok "7 inject" "query \"$TEST_QUERY\" → injected $(printf '%s\n' "$ctx" | grep -c .) line(s)"
    printf '%s\n' "$ctx" | sed 's/^/      | /'
  else
    skip "7 inject" "empty injection — namespace empty (Phase 5) or OpenViking returned nothing"
  fi
}

# ── Phase 8 — (--verify) OpenViking is NOT load-bearing: kill it, still injects ─
phase8_verify() {
  [[ "$DO_VERIFY" == true ]] || return 0
  log "Phase 8 — verify fallback (kill openviking → hook still injects)"
  pkill -f openviking-server 2>/dev/null; sleep 1
  local ctx
  ctx="$(printf '%s' "$(jq -n --arg q "$TEST_QUERY" '{query:$q}')" | bash "$HOOK" 2>/dev/null | jq -r '.context // empty' 2>/dev/null)"
  if [[ -n "$ctx" ]]; then ok "8 fallback" "still injected with openviking down (deterministic fallback)"
  else skip "8 fallback" "empty (namespace may be empty regardless of engine)"; fi
  log "  (restart the server with this script again, or: nohup openviking-server >~/openviking.log 2>&1 &)"
}

# ── run ──────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════════"
echo "  OpenViking sandbox setup — engine=$OV  user=$OVUSER  namespace=$NS"
echo "  init=$DO_INIT reload=$DO_RELOAD verify=$DO_VERIFY test=$DO_TEST"
echo "════════════════════════════════════════════════════════════════════"
phase0_prereqs || { log "Phase 0 failed — fix prereqs above, then re-run."; exit 1; }
phase1_installed || { log "Phase 1 failed — install openviking, then re-run."; exit 1; }
phase2_init
phase3_serve || { log "Phase 3 failed — server not healthy; see above."; exit 1; }
phase4_corpus
phase5_mirror
phase6_wire
phase7_test
phase8_verify

log "summary: $([ "$FAILED" -eq 0 ] && echo 'all green ✅' || echo "$FAILED step(s) FAILED ❌")"
exit "$FAILED"
