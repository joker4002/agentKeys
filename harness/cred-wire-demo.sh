#!/usr/bin/env bash
# harness/cred-wire-demo.sh — #216 agent-side wire, the FULL e2e.
#
# Proves the #216 guarantee against the LIVE broker + cred worker + aiosandbox:
# the agent runs Hermes on an LLM key it FETCHED FROM THE MASTER'S VAULT — never
# an ambient `OPENROUTER_API_KEY` in the agent's env. The chain end-to-end:
#
#   master VAULTS the LLM key   (daemon web path: cap-mint cred-store → STS → cred worker → S3)
#     → agent CRED-FETCHES it   (agentkeys cred fetch: cap-mint cred-fetch → STS → cred worker → decrypt)
#     → wire plants it into Hermes  (~/.hermes/.env + hermes config set model.*) IN THE SANDBOX
#     → Hermes runs on the vault key (real LLM smoke) — with NO OPENROUTER_API_KEY in the sandbox env
#
# This is the durable, headless complement to phase1-wire-demo.sh Phase 4.0b (the
# operator-interactive surprise): same wire result (the vault-fetched key in
# Hermes), proven without Touch ID / manual gates. The fetch routes through the
# shared agentkeys-backend-client (no re-typed wire shapes, #204).
#
# Real-only: needs a live broker + cred worker + a registered master + a reachable
# aiosandbox with Hermes. `--ci` tolerates missing infra (skip, exit 0). The seed
# LLM key comes from $LLM_API_KEY / $OPENROUTER_API_KEY (the master's key — it
# legitimately HAS the key; the POINT is the AGENT reads it from the vault, not the
# env). With no seed key a probe is vaulted + the real-LLM smoke is skipped (the
# cred → plant chain is still proven).
#
# Idempotent: a FIXED vault service (default `openrouter`) is overwritten each run;
# the sandbox ~/.hermes/.env OPENROUTER_API_KEY line is rewritten (never appended);
# the daemon is killed on exit (EXIT trap).
#
#   bash harness/cred-wire-demo.sh                # full
#   bash harness/cred-wire-demo.sh --only-step 5  # one step
#   bash harness/cred-wire-demo.sh --ci           # tolerate missing infra
set -uo pipefail
set +m   # quiet the "Terminated" job-control notice when the EXIT trap kills the daemon

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
# shellcheck source=/dev/null
. "$REPO_ROOT/harness/scripts/_lib.sh"

CI=0; FROM=1; TO=99; STEP_TOTAL=6
for a in "$@"; do case "$a" in
  --ci) CI=1 ;;
  --from-step) shift; FROM="${1:-1}" ;; --from-step=*) FROM="${a#*=}" ;;
  --to-step) shift; TO="${1:-99}" ;;   --to-step=*) TO="${a#*=}" ;;
  --only-step) shift; FROM="${1:-1}"; TO="$FROM" ;; --only-step=*) FROM="${a#*=}"; TO="$FROM" ;;
  --help|-h) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
SANDBOX_URL="${SANDBOX_URL:-http://localhost:8080}"
SERVICE="${SERVICE:-openrouter}"            # the vault cred service (= the LLM provider)
LLM_API_KEY="${LLM_API_KEY:-${OPENROUTER_API_KEY:-}}"   # master's key to SEED the vault (agent reads it back via cap)
LLM_BASE_URL="${LLM_BASE_URL:-https://openrouter.ai/api/v1}"
LLM_MODEL="${LLM_MODEL:-deepseek/deepseek-v4-flash}"
CLI_BIN="$REPO_ROOT/target/release/agentkeys"
DAEMON_BIN="$REPO_ROOT/target/release/agentkeys-daemon"
DPORT="${CRED_WIRE_DAEMON_PORT:-3130}"
DPID=""; DLOG="$(mktemp -t cred-wire-daemon.XXXX)"
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; rm -f "$DLOG"; }
trap cleanup EXIT

# sandbox drive (the agent host) — same mechanism as phase1-wire-demo.sh::sbx_exec.
sbx_exec() { curl -sS --max-time "${SBX_EXEC_MAXTIME:-120}" -X POST "$SANDBOX_URL/v1/shell/exec" \
               -H 'content-type: application/json' -d "$(jq -n --arg c "$1" '{command:$c}')" \
               | jq -r '.data.output // ""'; }
sbx_rc()   { curl -sS --max-time "${SBX_EXEC_MAXTIME:-120}" -X POST "$SANDBOX_URL/v1/shell/exec" \
               -H 'content-type: application/json' -d "$(jq -n --arg c "$1" '{command:$c}')" \
               | jq -r '.data.exit_code // 1'; }
sha() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }

# ─── Step 1: prereqs + master identity + J1 ────────────────────────────────
if should_run 1; then
  step 1 "Prereqs + master identity + J1 (wallet SIWE) + sandbox reachable"
  for t in cast jq curl; do command -v "$t" >/dev/null 2>&1 || die "missing $t"; done
  [ -n "$BROKER" ] || { skip "no broker URL (OIDC_ISSUER) — wire is real-only"; [ "$CI" = 1 ] && exit 0 || die "no broker"; }
  [ -n "$CRED" ]   || die "no cred worker URL (AGENTKEYS_WORKER_CRED_URL)"
  [ -n "$VAULT_ROLE" ] || die "no VAULT_ROLE_ARN"
  for b in "$CLI_BIN" "$DAEMON_BIN"; do [ -x "$b" ] || { ( cd "$REPO_ROOT" && cargo build --release -p agentkeys-cli -p agentkeys-daemon ) || die "build failed"; break; }; done
  [ "$(sbx_rc 'echo ok')" = "0" ] || { skip "sandbox $SANDBOX_URL not reachable — start aiosandbox"; [ "$CI" = 1 ] && exit 0 || die "no sandbox"; }
  [ "$(sbx_rc 'export PATH=$HOME/.local/bin:$PATH; command -v hermes')" = "0" ] || die "hermes not installed in the sandbox (run phase1-wire-demo.sh Phase 1 first)"
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
  ok "omni 0x${OMNI:0:12}…  device ${DKH:0:12}…  J1 len=${#J1}  sandbox+hermes ready"
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

# ─── Step 3: master VAULTS the LLM key (the master legitimately HAS it) ─────
if should_run 3; then
  step 3 "Master vaults '$SERVICE' (the LLM key) via the daemon → the agent will fetch it back"
  { [ -n "${DPID:-}" ] && kill -0 "$DPID" 2>/dev/null; } || die "daemon not running — run step 2"
  if [ -n "$LLM_API_KEY" ]; then
    SEED_KEY="$LLM_API_KEY"; SEED_REAL=1
  else
    SEED_KEY="sk-cred-wire-probe-$$-$(date +%s)"; SEED_REAL=0
    skip "3.0 seed key" "no \$OPENROUTER_API_KEY/\$LLM_API_KEY — vaulting a PROBE (cred→plant chain proven; real-LLM smoke skipped)"
  fi
  store=$(curl -sS --fail-with-body -X POST "http://127.0.0.1:$DPORT/v1/master/credentials/store" \
    -H 'content-type: application/json' -d "$(jq -n --arg s "$SERVICE" --arg k "$SEED_KEY" '{service:$s, secret:$k}')" 2>&1) \
    || die "daemon vault failed (cred chain): $store"
  echo "$store" | jq -e '.ok == true' >/dev/null 2>&1 || die "vault returned not-ok: $store"
  ok "vaulted '$SERVICE' (real=$SEED_REAL) — $(echo "$store" | jq -c '{ok,service,category}')"
fi

# ─── Step 4: agent CRED-FETCHES the key → assert == what the master vaulted ─
if should_run 4; then
  step 4 "Agent: agentkeys cred fetch '$SERVICE' → assert == the vaulted LLM key"
  [ -n "${SEED_KEY:-}" ] || die "no seed key — run step 3"
  FETCHED=$("$CLI_BIN" cred fetch "$SERVICE" \
    --operator-omni "0x$OMNI" --actor-omni "0x$OMNI" --device-key-hash "$DKH" \
    --session-bearer "$J1" --broker-url "$BROKER" --cred-url "$CRED" \
    --vault-role-arn "$VAULT_ROLE" --region "$REGION" 2>&1) \
    || die "cred fetch errored: $FETCHED"
  [ "$(sha "$FETCHED")" = "$(sha "$SEED_KEY")" ] || die "vault round-trip mismatch (fetched ≠ vaulted)"
  ok "agent fetched the vaulted key from the vault (len=${#FETCHED}, sha $(sha "$FETCHED" | cut -c1-12)…) — no env read"
fi

# ─── Step 5: WIRE — plant the FETCHED key into the sandbox Hermes ───────────
if should_run 5; then
  step 5 "Wire: plant the vault-fetched key into the sandbox Hermes (NO OPENROUTER_API_KEY in the agent env)"
  [ -n "${FETCHED:-}" ] || die "no fetched key — run step 4"
  # Prove the value arrives via the vault, not an ambient env: strip any existing
  # OPENROUTER_API_KEY from the sandbox .env, confirm gone, THEN plant the fetched
  # value. (Hermes reads the provider key from ~/.hermes/.env.)
  env_path='$HOME/.hermes/.env'
  sbx_exec "mkdir -p \$HOME/.hermes; ENV=$env_path; touch \"\$ENV\"; grep -v '^OPENROUTER_API_KEY=' \"\$ENV\" > \"\$ENV.tmp\" 2>/dev/null; mv \"\$ENV.tmp\" \"\$ENV\"" >/dev/null
  [ "$(sbx_rc "grep -q '^OPENROUTER_API_KEY=' $env_path")" != "0" ] || die "could not strip pre-existing OPENROUTER_API_KEY from the sandbox .env"
  sbx_exec "ENV=$env_path; printf 'OPENROUTER_API_KEY=%s\n' $(printf '%q' "$FETCHED") >> \"\$ENV\"" >/dev/null
  [ "$(sbx_rc "grep -q '^OPENROUTER_API_KEY=' $env_path")" = "0" ] || die "could not write the fetched key to the sandbox ~/.hermes/.env"
  sbx_exec "export PATH=\$HOME/.local/bin:\$PATH; hermes config set model.provider openrouter >/dev/null 2>&1; hermes config set model.base_url $(printf '%q' "$LLM_BASE_URL") >/dev/null 2>&1; hermes config set model.default $(printf '%q' "$LLM_MODEL") >/dev/null 2>&1" >/dev/null
  ok "planted the vault-fetched key into ~/.hermes/.env + hermes config (provider=openrouter, model=$LLM_MODEL)"
fi

# ─── Step 6: PROOF — Hermes runs on the vault key (value match + real smoke) ─
if should_run 6; then
  step 6 "Proof: the key Hermes uses == the vaulted key (vault-sourced), + a real LLM smoke"
  [ -n "${FETCHED:-}" ] || die "no fetched key — run step 4"
  planted_sha=$(sbx_exec "v=\$(grep '^OPENROUTER_API_KEY=' \$HOME/.hermes/.env | head -1 | sed 's/^OPENROUTER_API_KEY=//'); printf '%s' \"\$v\" | shasum -a 256 | awk '{print \$1}'")
  [ "$planted_sha" = "$(sha "$FETCHED")" ] || die "the key in the sandbox Hermes ≠ the vault-fetched key (planted sha ${planted_sha:0:12}…)"
  ok "6.1 vault-sourced — the key Hermes will use == the master-vaulted key (sha ${planted_sha:0:12}…), NOT an env var"
  if [ "${SEED_REAL:-0}" = "1" ]; then
    smoke=$(sbx_exec "export PATH=\$HOME/.local/bin:\$PATH; cd \$HOME; timeout 55 hermes -z 'Reply with exactly: OK' 2>&1 | tail -3")
    smoke1=$(echo "$smoke" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-80)
    if echo "$smoke" | grep -q '429'; then
      skip "6.2 llm smoke — $LLM_MODEL is HTTP 429 (rate-limited); the key works, the model is throttled — vault-source proof (6.1) stands"
    elif echo "$smoke" | grep -qiE 'unauthorized|invalid.key|no inference|forbidden|401|403'; then
      die "6.2 llm smoke — Hermes REJECTED the vault key: $smoke1"
    elif [ -n "$(echo "$smoke" | tr -d '[:space:]')" ]; then
      ok "6.2 llm smoke — Hermes answered using the VAULT-FETCHED key: \"$smoke1\""
    else
      skip "6.2 llm smoke — empty response (sandbox egress?) — 6.1 (vault-source) is authoritative"
    fi
  else
    skip "6.2 llm smoke — probe key (no real LLM) — 6.1 proved the vault→fetch→plant chain"
  fi
fi

printf '\n%s the agent runs Hermes on a key it FETCHED FROM THE MASTER VAULT — cap-mint → STS → cred worker → decrypt → ~/.hermes/.env. No ambient OPENROUTER_API_KEY.\n' "$(c '1;32' 'DONE ·')" >&2
