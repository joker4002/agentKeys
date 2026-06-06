#!/usr/bin/env bash
# harness/cred-fetch-demo.sh — #216 agent-side vaulted-key fetch, real e2e.
#
# Proves the #216 guarantee against the LIVE broker + cred worker: a master
# VAULTS a credential (the web/daemon path — cap-mint cred-store → per-actor STS
# → cred worker → S3), and the AGENT FETCHES it back with `agentkeys cred fetch`
# (the agent/CLI path — cap-mint cred-fetch → STS → cred worker → decrypt),
# returning the EXACT secret. This is the cred half of "the agent uses the key
# the master authorized it to use" (the full Hermes wire is phase1-wire #216
# Phase 4.0). The cred-fetch routes through the shared agentkeys-backend-client
# (no re-typed wire shapes, #204).
#
# Idempotent: a FIXED probe service (`cred-e2e-probe`) is overwritten each run
# (store = S3 PUT), so re-runs never accumulate vault objects; the daemon is
# killed on exit (EXIT trap). Real-only — needs a live broker + cred worker +
# a registered master; `--ci` tolerates missing infra (skip, exit 0).
#
#   bash harness/cred-fetch-demo.sh                # full
#   bash harness/cred-fetch-demo.sh --only-step 4  # one step
#   bash harness/cred-fetch-demo.sh --ci           # tolerate missing infra
set -uo pipefail
set +m   # quiet the "Terminated" job-control notice when the EXIT trap kills the daemon

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
{ [ -n "${AGENTKEYS_CI:-}" ] || { [ -n "${CI:-}" ] && [ "${CI}" != 0 ]; }; } && CI=1
should_run() { [ "$1" -ge "$FROM" ] && [ "$1" -le "$TO" ]; }
c() { [ -t 2 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
step() { printf '\n%s %s\n' "$(c '1;36' "▸ step $1/$STEP_TOTAL")" "$2" >&2; }
ok()   { printf '  %s %s\n' "$(c '1;32' ok)" "$1" >&2; }
skip() { printf '  %s %s\n' "$(c '1;33' skip)" "$1" >&2; }
die()  { printf '  %s %s\n' "$(c '1;31' fail)" "$1" >&2; [ "$CI" = 1 ] && { skip "CI — tolerated"; exit 0; }; exit 1; }

BROKER="${OIDC_ISSUER:-${AGENTKEYS_BROKER_URL:-}}"
CRED="${AGENTKEYS_WORKER_CRED_URL:-}"
REGION="${REGION:-us-east-1}"
VAULT_ROLE="${VAULT_ROLE_ARN:-}"
CLI_BIN="$REPO_ROOT/target/release/agentkeys"
DAEMON_BIN="$REPO_ROOT/target/release/agentkeys-daemon"
DPORT="${CRED_E2E_DAEMON_PORT:-3129}"
PROBE_SERVICE="cred-e2e-probe"   # FIXED → re-runs overwrite, never accumulate
PROBE_SECRET="sk-cred-e2e-$$-$(date +%s)"   # unique per run so the assert is fresh
DPID=""; DLOG="$(mktemp -t cred-e2e-daemon.XXXX)"
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; rm -f "$DLOG"; }
trap cleanup EXIT

# ─── Step 1: prereqs + master identity + J1 ────────────────────────────────
if should_run 1; then
  step 1 "Prereqs + master identity + J1 (wallet SIWE)"
  for t in cast jq curl; do command -v "$t" >/dev/null 2>&1 || die "missing $t"; done
  [ -n "$BROKER" ] || { skip "no broker URL (OIDC_ISSUER) — cred-fetch is real-only"; [ "$CI" = 1 ] && exit 0 || die "no broker"; }
  [ -n "$CRED" ]   || die "no cred worker URL (AGENTKEYS_WORKER_CRED_URL)"
  [ -n "$VAULT_ROLE" ] || die "no VAULT_ROLE_ARN"
  for b in "$CLI_BIN" "$DAEMON_BIN"; do [ -x "$b" ] || { ( cd "$REPO_ROOT" && cargo build --release -p agentkeys-cli -p agentkeys-daemon ) || die "build failed"; break; }; done
  KEY=$(resolve_master_key) || die "no master deployer key"
  ADDR=$(cast wallet address --private-key "$KEY" | tr 'A-F' 'a-f')
  OMNI=$(printf 'agentkeysevm%s' "$ADDR" | shasum -a 256 | awk '{print $1}')
  DKH=$(resolve_active_master_dkh "$OMNI" "$ADDR" || true)
  [ -n "$DKH" ] || die "master device not registered — run phases 1-2"
  start=$(curl -sS --fail-with-body -X POST "$BROKER/v1/auth/wallet/start" -H 'content-type: application/json' -d "$(jq -n --arg a "$ADDR" '{address:$a, chain_id:1}')" 2>&1) || die "wallet/start: $start"
  req=$(echo "$start" | jq -r '.request_id // empty'); msg=$(echo "$start" | jq -r '.siwe_message // empty')
  [ -n "$req" ] || die "wallet/start gave no request_id: $start"
  sig=$(cast wallet sign --private-key "$KEY" "$msg")
  verify=$(curl -sS --fail-with-body -X POST "$BROKER/v1/auth/wallet/verify" -H 'content-type: application/json' -d "$(jq -n --arg r "$req" --arg s "$sig" '{request_id:$r, signature:$s}')" 2>&1) || die "wallet/verify: $verify"
  J1=$(echo "$verify" | jq -r '.session_jwt // .jwt // empty')
  [ -n "$J1" ] || die "no master J1: $verify"
  ok "omni 0x${OMNI:0:12}…  device ${DKH:0:12}…  J1 len=${#J1}"
fi

# ─── Step 2: boot the SEEDED daemon (the master web path) ──────────────────
if should_run 2; then
  step 2 "Boot agentkeys-daemon --ui-bridge (seeded master, reads cred env)"
  [ -n "${J1:-}" ] || die "no J1 — run step 1 first"
  "$DAEMON_BIN" --ui-bridge \
    --ui-bridge-bind "127.0.0.1:$DPORT" --ui-bridge-origin "http://localhost:$DPORT" \
    --ui-bridge-rp-id localhost --ui-bridge-rp-name AgentKeys \
    --broker-url "$BROKER" --master-device-key-hash "$DKH" \
    --ui-bridge-seed-session-jwt "$J1" --ui-bridge-seed-omni "$OMNI" \
    > "$DLOG" 2>&1 &
  DPID=$!
  ready=0; for _ in $(seq 1 20); do curl -fsS "http://127.0.0.1:$DPORT/healthz" >/dev/null 2>&1 && { ready=1; break; }; kill -0 "$DPID" 2>/dev/null || break; sleep 0.5; done
  [ "$ready" = 1 ] || die "daemon not ready: $(tail -3 "$DLOG" | tr '\n' ' ')"
  ok "daemon up on http://127.0.0.1:$DPORT (seeded master session)"
fi

# ─── Step 3: master VAULTS the probe cred (web path → real chain) ──────────
if should_run 3; then
  step 3 "Master vaults '$PROBE_SERVICE' via the daemon (cap-mint cred-store → STS → cred worker → S3)"
  { [ -n "${DPID:-}" ] && kill -0 "$DPID" 2>/dev/null; } || die "daemon not running — run step 2"
  store=$(curl -sS --fail-with-body -X POST "http://127.0.0.1:$DPORT/v1/master/credentials/store" \
    -H 'content-type: application/json' -d "$(jq -n --arg s "$PROBE_SERVICE" --arg k "$PROBE_SECRET" '{service:$s, secret:$k}')" 2>&1) \
    || die "daemon vault failed (cred chain): $store"
  echo "$store" | jq -e '.ok == true' >/dev/null 2>&1 || die "vault returned not-ok: $store"
  ok "vaulted via the daemon — $(echo "$store" | jq -c '{ok,service,category}')"
fi

# ─── Step 4: agent FETCHES it back via the CLI → assert round-trip ─────────
if should_run 4; then
  step 4 "Agent: agentkeys cred fetch '$PROBE_SERVICE' → assert == the vaulted secret"
  fetched=$("$CLI_BIN" cred fetch "$PROBE_SERVICE" \
    --operator-omni "0x$OMNI" --actor-omni "0x$OMNI" --device-key-hash "$DKH" \
    --session-bearer "$J1" --broker-url "$BROKER" --cred-url "$CRED" \
    --vault-role-arn "$VAULT_ROLE" --region "$REGION" 2>&1) \
    || die "cred fetch errored: $fetched"
  [ "$fetched" = "$PROBE_SECRET" ] || die "round-trip mismatch — fetched '${fetched:0:24}…' want '${PROBE_SECRET:0:24}…'"
  ok "agent cred-fetch returned the EXACT vaulted secret (len=${#fetched}) — #216 cred half verified"
fi

printf '\n%s the agent fetched the credential the master vaulted — through the real cap-mint → STS → cred worker → decrypt chain.\n' "$(c '1;32' 'DONE ·')" >&2
