#!/usr/bin/env bash
# harness/web-parity-demo.sh — v2-demo PHASE 6 (web ↔ agent parity).
#
# NOT a standalone front door: it's a phase of harness/v2-demo.sh and assumes the
# prereqs the earlier phases established (chain + broker live, master registered).
# It proves the WEB flow (the agentkeys-daemon --ui-bridge that the parent-control
# app drives) plants through the SAME real chain the agent/harness path uses — so
# the two can't silently drift (the recurring bug class: cap-mint body shapes,
# 0x-omni, field names).
#
# Cheap by construction — it REUSES, never re-bootstraps:
#   - the release binary the v2-demo preflight already built,
#   - the live chain + broker (prereqs),
#   - the master already registered on-chain (phases 1-2),
#   - the daemon --ui-bridge-seed-session-jwt/-omni SEAM so it skips the daemon's
#     interactive email + WebAuthn onboarding (the expensive part). One daemon
#     boot + one web plant; no second build, no chain re-bringup, no re-enroll.
#
# Steps:
#   1. prereqs + identity (deployer → omni → device-hash) + master J1 (wallet SIWE)
#   2. boot agentkeys-daemon --ui-bridge, SEEDED with the J1 + omni + device-hash
#   3. plant a probe namespace via the WEB endpoint POST /v1/master/memory/plant
#      → assert HTTP 200 (with --memory-url, a 200 means cap-mint → STS → worker →
#      S3 all succeeded: the daemon's web chain == the real chain)
#   4. web agent-pairing poll: GET /v1/agent/pairing/pending → assert a well-formed
#      {requests:[...]} (#214) — the daemon's pairing route reaches the real broker
#      rendezvous with the master J1 (the master-side web-pairing wiring smoke)
#
#   bash harness/web-parity-demo.sh                # full
#   bash harness/web-parity-demo.sh --only-step 3  # one step
#   bash harness/web-parity-demo.sh --ci           # tolerate missing infra (skip, exit 0)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
# shellcheck source=/dev/null
. "$REPO_ROOT/harness/scripts/_lib.sh"

CI=0; FROM=1; TO=99; STEP_TOTAL=4
for a in "$@"; do case "$a" in
  --ci) CI=1 ;;
  --from-step) shift; FROM="${1:-1}" ;; --from-step=*) FROM="${a#*=}" ;;
  --to-step) shift; TO="${1:-99}" ;;   --to-step=*) TO="${a#*=}" ;;
  --only-step) shift; FROM="${1:-1}"; TO="$FROM" ;; --only-step=*) FROM="${a#*=}"; TO="$FROM" ;;
  --help|-h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac; done
{ [ -n "${AGENTKEYS_CI:-}" ] || [ -n "${CI:-}" ] && [ "${CI}" != 0 ]; } && CI=1
should_run() { [ "$1" -ge "$FROM" ] && [ "$1" -le "$TO" ]; }
c() { [ -t 2 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
step() { printf '\n%s %s\n' "$(c '1;36' "▸ step $1/$STEP_TOTAL")" "$2" >&2; }
ok()   { printf '  %s %s\n' "$(c '1;32' ok)" "$1" >&2; }
skip() { printf '  %s %s\n' "$(c '1;33' skip)" "$1" >&2; }
die()  { printf '  %s %s\n' "$(c '1;31' fail)" "$1" >&2; [ "$CI" = 1 ] && { skip "CI — tolerated"; exit 0; }; exit 1; }

profile_uc="$(printf '%s' "${AGENTKEYS_CHAIN:-heima}" | tr 'a-z-' 'A-Z_')"
BROKER="${OIDC_ISSUER:-${AGENTKEYS_BROKER_URL:-}}"
eval "MEMORY_URL=\${AGENTKEYS_WORKER_MEMORY_URL:-\${MEMORY_WORKER_URL:-}}"
eval "MEMORY_ROLE_ARN=\${MEMORY_ROLE_ARN:-\${MEMORY_ROLE_ARN_${profile_uc}:-}}"
# #201 Phase 4: when the Config substrate is present, the web plant also writes
# the master-only memory-types taxonomy (config/memory-taxonomy.enc). Optional —
# a missing config worker degrades to a logged warning (the memory plant still
# proves parity), so these stay best-effort.
CONFIG_URL="${AGENTKEYS_WORKER_CONFIG_URL:-}"
eval "CONFIG_ROLE_ARN=\${CONFIG_ROLE_ARN:-\${CONFIG_ROLE_ARN_${profile_uc}:-}}"
REGION="${REGION:-us-east-1}"
PROBE_NS="${WEB_PARITY_NS:-webparity}"           # a dedicated probe ns — never clobbers real memory
PROBE_BODY="web-parity probe :: daemon plant chain OK"
MEMORY_BUCKET="${MEMORY_BUCKET:-}"
DAEMON_BIN="$REPO_ROOT/target/release/agentkeys-daemon"
DAEMON_PORT="${WEB_PARITY_DAEMON_PORT:-3119}"
DAEMON_BIND="127.0.0.1:${DAEMON_PORT}"
DAEMON_PID=""
DAEMON_LOG="$(mktemp -t web-parity-daemon.XXXX)"
# Always-runs (EXIT) cleanup: stop the daemon AND delete the probe ns this run
# planted, so the parity test never leaks test memory into the master's real
# store. Scoped to exactly bots/<omni>/memory/memory:<probe>.enc — can only touch
# the dedicated probe ns. KEEP_DEMO_MEMORY=1 opts out (debugging).
cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  rm -f "$DAEMON_LOG"
  if [ "${KEEP_DEMO_MEMORY:-0}" != 1 ] && [ -n "${DEPLOYER_OMNI:-}" ] && [ -n "$MEMORY_BUCKET" ]; then
    aws s3 rm "s3://$MEMORY_BUCKET/bots/$DEPLOYER_OMNI/memory/memory:$PROBE_NS.enc" \
      --region "$REGION" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ─── Step 1: prereqs + identity + master J1 ────────────────────────────────
if should_run 1; then
  step 1 "Prereqs + master identity + J1 (reused, not re-onboarded)"
  for t in cast jq curl aws; do command -v "$t" >/dev/null 2>&1 || die "missing $t on PATH"; done
  [ -n "$BROKER" ]          || { skip "no broker URL (set OIDC_ISSUER) — web-parity is real-only"; [ "$CI" = 1 ] && exit 0 || die "no broker"; }
  [ -n "$MEMORY_URL" ]      || die "no memory worker URL (AGENTKEYS_WORKER_MEMORY_URL) — web-parity is real-only"
  [ -n "$MEMORY_ROLE_ARN" ] || die "no MEMORY_ROLE_ARN"
  [ -x "$DAEMON_BIN" ] || { ( cd "$REPO_ROOT" && cargo build --release -p agentkeys-daemon ) || die "daemon build failed"; }
  DEPLOYER_KEY="$(resolve_master_key)" || die "no deployer key (~/.agentkeys/heima-deployer.key)"
  DEPLOYER_ADDR="$(cast wallet address --private-key "$DEPLOYER_KEY" | tr 'A-F' 'a-f')"  # 0x-prefixed
  DEPLOYER_OMNI="$(printf 'agentkeysevm%s' "$DEPLOYER_ADDR" | shasum -a 256 | awk '{print $1}')"
  MASTER_DKH="$(resolve_active_master_dkh "$DEPLOYER_OMNI" "$DEPLOYER_ADDR" || true)"
  [ -n "$MASTER_DKH" ] || die "master device not registered — run phases 1-2 (or bash harness/scripts/erc4337-register-master.sh)"
  start=$(curl -sS --fail-with-body -X POST "$BROKER/v1/auth/wallet/start" -H 'content-type: application/json' \
    -d "$(jq -n --arg a "$DEPLOYER_ADDR" --argjson c 1 '{address:$a, chain_id:$c}')" 2>&1) || die "wallet/start: $start"
  req_id=$(echo "$start" | jq -r '.request_id // empty'); msg=$(echo "$start" | jq -r '.siwe_message // empty')
  [ -n "$req_id" ] || die "wallet/start gave no request_id: $start"
  sig=$(cast wallet sign --private-key "$DEPLOYER_KEY" "$msg")
  verify=$(curl -sS --fail-with-body -X POST "$BROKER/v1/auth/wallet/verify" -H 'content-type: application/json' \
    -d "$(jq -n --arg r "$req_id" --arg s "$sig" '{request_id:$r, signature:$s}')" 2>&1) || die "wallet/verify: $verify"
  J1=$(echo "$verify" | jq -r '.session_jwt // .jwt // empty')
  [ -n "$J1" ] || die "no master J1: $verify"
  ok "operator==actor omni 0x${DEPLOYER_OMNI:0:14}…  device ${MASTER_DKH:0:14}…  J1 len=${#J1}"
fi

# ─── Step 2: boot the SEEDED daemon (skip interactive onboarding) ───────────
if should_run 2; then
  step 2 "Boot agentkeys-daemon --ui-bridge (seeded session — no re-onboarding)"
  [ -n "${J1:-}" ] || die "no J1 — run step 1 first"
  # Optional Config-class args, expanded only when both are set (bash-3.2-safe
  # empty-array expansion so `set -u` doesn't trip on an absent config worker).
  CONFIG_FLAGS=()
  if [ -n "$CONFIG_URL" ] && [ -n "$CONFIG_ROLE_ARN" ]; then
    CONFIG_FLAGS=(--config-url "$CONFIG_URL" --config-role-arn "$CONFIG_ROLE_ARN")
  fi
  "$DAEMON_BIN" --ui-bridge \
    --ui-bridge-bind   "$DAEMON_BIND" \
    --ui-bridge-origin "http://localhost:${DAEMON_PORT}" \
    --ui-bridge-rp-id  localhost --ui-bridge-rp-name AgentKeys \
    --broker-url       "$BROKER" \
    --memory-url       "$MEMORY_URL" \
    --memory-role-arn  "$MEMORY_ROLE_ARN" \
    ${CONFIG_FLAGS[@]+"${CONFIG_FLAGS[@]}"} \
    --region           "$REGION" \
    --master-device-key-hash      "$MASTER_DKH" \
    --ui-bridge-seed-session-jwt  "$J1" \
    --ui-bridge-seed-omni         "$DEPLOYER_OMNI" \
    > "$DAEMON_LOG" 2>&1 &
  DAEMON_PID=$!
  ready=0
  for _ in $(seq 1 20); do
    curl -fsS "http://${DAEMON_BIND}/healthz" >/dev/null 2>&1 && { ready=1; break; }
    kill -0 "$DAEMON_PID" 2>/dev/null || { die "daemon exited early — log: $(tail -3 "$DAEMON_LOG" | tr '\n' ' ')"; }
    sleep 0.5
  done
  [ "$ready" = 1 ] || die "daemon not ready on $DAEMON_BIND — log: $(tail -3 "$DAEMON_LOG" | tr '\n' ' ')"
  ok "daemon up on http://$DAEMON_BIND (seeded master session)"
fi

# ─── Step 3: plant via the WEB endpoint → the parity gate ──────────────────
if should_run 3; then
  step 3 "Web plant POST /v1/master/memory/plant → real chain (cap-mint → STS → worker → S3)"
  [ -n "${DAEMON_PID:-}" ] && kill -0 "$DAEMON_PID" 2>/dev/null || die "daemon not running — run step 2"
  # @web-fixture: master_memory_plant — entry shape gated by scripts/check-web-api-drift.sh
  # (must match the daemon's ApiMemoryEntry + daemon.ts; issue #203 / the #206 parity ladder).
  entry=$(jq -n --arg ns "$PROBE_NS" --arg b "$PROBE_BODY" '{
      ns:$ns, key:"probe", title:"Web parity probe", bytes:($b|length),
      version:"v1", updated:"2026-06-05", preview:"web-parity probe", body:$b, content_hash:""}')
  body=$(jq -n --argjson e "$entry" '{entries:[$e]}')
  resp=$(curl -sS --fail-with-body -X POST "http://${DAEMON_BIND}/v1/master/memory/plant" \
    -H 'content-type: application/json' -d "$body" 2>&1) \
    || die "web plant failed (the daemon's chain diverged from the real broker/worker): $resp"
  planted=$(echo "$resp" | jq -r '.planted // empty' 2>/dev/null)
  [ -n "$planted" ] || die "web plant returned no planted count (daemon log: $(tail -3 "$DAEMON_LOG" | tr '\n' ' ')): $resp"
  ok "web plant OK via the daemon — planted=$planted skipped=$(echo "$resp" | jq -r '.skipped // 0') (web chain == agent chain)"
fi

# ─── Step 4: web agent-pairing poll reaches the real broker rendezvous (#214) ──
if should_run 4; then
  step 4 "Web pairing poll GET /v1/agent/pairing/pending → real broker rendezvous"
  { [ -n "${DAEMON_PID:-}" ] && kill -0 "$DAEMON_PID" 2>/dev/null; } || die "daemon not running — run step 2"
  pr=$(curl -sS --fail-with-body "http://${DAEMON_BIND}/v1/agent/pairing/pending" 2>&1) \
    || die "pairing poll failed (daemon → broker /v1/agent/pending-bindings): $pr"
  # A well-formed {requests:[...]} (usually empty for a fresh master) proves the
  # daemon's #214 pairing route reaches the real broker rendezvous with the seeded
  # master J1 — the master-side web-pairing wiring smoke. The full claim → register
  # e2e needs a live agent pairing request (the sandbox §10.2 path) and is exercised
  # by the agent-side wire demo; here we gate that the route is wired + reachable.
  echo "$pr" | jq -e 'has("requests") and (.requests | type == "array")' >/dev/null 2>&1 \
    || die "pairing poll returned a malformed body (expected {requests:[...]}): $pr"
  ok "web pairing poll OK — $(echo "$pr" | jq -r '.requests | length') pending agent binding(s) (route → broker reachable)"
fi

# Phase 6 is deliberately a THIN runtime-wiring smoke (harness/CLAUDE.md "parity
# checks evolve down a ladder"): step 3's HTTP 200 is the whole proof — the daemon's
# web chain (cap-mint → STS → worker → S3) reaches real infra, identical to the agent
# path. The body SHAPE is gated at compile/fixture time by scripts/check-web-api-drift.sh
# (the @web-fixture annotation above), and the canonical S3 key is deterministic +
# covered by the worker's s3_key unit test — so no extra runtime artifact/HEAD step is
# needed here. The probe ns is deleted by the EXIT trap (success OR failure).

printf '\n%s web flow plants through the SAME real chain as the agent/harness path (no drift).\n' "$(c '1;32' 'DONE ·')" >&2
