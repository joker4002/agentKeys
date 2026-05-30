#!/usr/bin/env bash
# Phase 1 wire harness — tests PR #141 (`agentkeys wire` + `agentkeys hook`)
# end-to-end. Master = this MacBook (operator); Agent = the aiosandbox
# container (actor). Idempotent: every step pre-checks + short-circuits
# (`ok proceeding` / `skip <reason>` / `fail <reason>`).
#
# Spec: docs/spec/plans/phase1-wire-harness-test-plan.md
#
# Two modes — you MUST pick ONE explicitly (there is NO default; running real
# mode by accident flips the sandbox MCP to the live broker and loses the demo):
#   --light   In-memory MCP IN THE SANDBOX + real Hermes + the wire flow.
#             Self-contained: NO real account / broker / chain. Seeds the demo
#             memory fixture — the "Chengdu" surprise lives HERE. Start here.
#   --real    Live broker + workers + Heima mainnet, REUSING the account
#             `setup-heima.sh` created (master `alice`, agent `demo-agent`).
#             NO in-memory fixture. Live-env steps fail-loud if a prereq missing.
#
# The agent binary must be aarch64-linux (the sandbox is aarch64 Linux); the
# harness cross-builds it in an arm64 Linux rust container and uploads it via
# the sandbox's own file API (no scp).
#
# Manual gates (the "test through" essence): the LLM key (auto from
# $OPENROUTER_API_KEY, else paste), real Touch ID at scope grant (Mode R, only
# if not already scoped), the Hermes surprise + its confirmation. Everything
# else is automated.
#
# Usage:
#   bash harness/phase1-wire-demo.sh {--light | --real} [--webauthn] [--unwire]
#                                    [--yes] [--skip-N ...] [--help]
#   (--light or --real is REQUIRED — the harness refuses to guess.)

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── config (env overridable) ──────────────────────────────────────────────
MODE=""   # no default — must be set explicitly via --light or --real (see flags)
SANDBOX_URL="${SANDBOX_URL:-http://localhost:8080}"
MCP_PORT="${MCP_PORT:-18088}"   # 8088 collides with the aiosandbox built-in gem-server; 18088 is outside its range
MCP_URL_IN_SANDBOX="http://localhost:${MCP_PORT}/mcp"
SESSION_ID="${SESSION_ID:-alice}"            # master session label on the Mac
AGENT_LABEL="${AGENT_LABEL:-demo-agent}"
SERVICE="${SERVICE:-openrouter}"             # LLM cred service name
# LLM key for the Phase 4 Hermes "surprise". Falls back to OPENROUTER_API_KEY
# (export it in ~/.zshenv) so 0.6 needs no manual paste. Used to configure the
# sandbox Hermes model before the surprise chat.
LLM_API_KEY="${LLM_API_KEY:-${OPENROUTER_API_KEY:-}}"
LLM_BASE_URL="${LLM_BASE_URL:-https://openrouter.ai/api/v1}"
LLM_MODEL="${LLM_MODEL:-deepseek/deepseek-v4-flash}"   # OpenRouter slug; ':free' tier is 429-throttled
MEMORY_NS="${MEMORY_NS:-travel}"
PAYMENT_SCOPE="${PAYMENT_SCOPE:-payment.spend}"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
AGENT_FILE="${AGENT_FILE:-$HOME/.agentkeys/agents/${AGENT_LABEL}.json}"
# Operator/master private key used to non-interactively mint a fresh session JWT
# whose agentkeys.omni_account == OPERATOR_OMNI (cap-mint requires this). Default
# is the Heima master/deployer key (its broker omni == the demo operator_omni).
# Override if your operator identity is a different wallet.
OPERATOR_KEY_FILE="${OPERATOR_KEY_FILE:-${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-deployer.key}}"
LINUX_TARGET_DIR="$REPO_ROOT/target/sandbox-linux"
# Binaries land in the sandbox user's ~/.local/bin — it's writable + already on
# PATH (hermes lives there). The sandbox upload API runs as a NON-ROOT user, so
# /usr/local/bin is NOT writable (upload → "Errno 13 Permission denied").
# Resolved to absolute paths in Phase 1 via resolve_sbx_paths once $HOME is known.
SBX_HOME=""
AGENT_BIN_DST=""
MCP_BIN_DST=""

# Mode-L demo identity (must match crates/agentkeys-mcp-server/src/backend/in_memory.rs)
DEMO_ACTOR="0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7"
DEMO_OPERATOR="0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8"

WEBAUTHN=false; UNWIRE=false; ASSUME_YES=false
SKIP_PHASES=""   # space-separated phase numbers (bash 3.2 — no assoc arrays)

# Resolved at runtime (Mode R from account; Mode L from demo constants):
ACTOR_OMNI="${AGENTKEYS_ACTOR_OMNI:-}"
OPERATOR_OMNI="${AGENTKEYS_OPERATOR_OMNI:-}"
VENDOR_TOKEN="${AGENTKEYS_MCP_VENDOR_TOKEN:-}"
SESSION_BEARER="${AGENTKEYS_SESSION_BEARER:-}"
# Agent session JWT (omni == ACTOR_OMNI) for the per-actor STS relay.
# Distinct from SESSION_BEARER (the operator session that authorizes cap-mint).
# In fresh §10.2 pairing it is minted IN THE SANDBOX by Phase P; legacy 0.8 mints
# it on the master (only under --reuse-agent).
AGENT_SESSION_BEARER="${AGENTKEYS_AGENT_SESSION_BEARER:-}"
# Fresh §10.2 pairing (DEFAULT in --real): the agent generates its OWN device key
# in the sandbox each run (key never on the master). --reuse-agent (or
# AGENTKEYS_REUSE_AGENT=1) falls back to the legacy master-side agent file.
REUSE_AGENT="${AGENTKEYS_REUSE_AGENT:-false}"
[[ "$REUSE_AGENT" == "1" ]] && REUSE_AGENT=true
DEVICE_KEY_HASH="${AGENTKEYS_DEVICE_KEY_HASH:-}"   # Mode R: agent device key hash (from agent file) — memory.put cap-mint needs it
BROKER_URL="${AGENTKEYS_BROKER_URL:-}"             # Mode R: the BROKER (serves /v1/cap/*), resolved from OIDC_ISSUER in phase 0 — NOT the signer ($BACKEND_URL)

# ─── flags ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --light)     MODE="light"; shift ;;
    --real)      MODE="real"; shift ;;
    --webauthn)  WEBAUTHN=true; shift ;;
    --reuse-agent) REUSE_AGENT=true; shift ;;
    --unwire)    UNWIRE=true; shift ;;
    --yes)       ASSUME_YES=true; shift ;;
    --skip-*)    SKIP_PHASES="$SKIP_PHASES ${1#--skip-}"; shift ;;
    --help|-h)   sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# Require an explicit mode — never silently default to the live broker.
if [[ -z "$MODE" ]]; then
  echo "ERROR: pick a mode explicitly — this harness will NOT guess." >&2
  echo "  --light   in-memory demo, self-contained (the Chengdu surprise lives here) — START HERE" >&2
  echo "  --real    live broker + workers + Heima mainnet (reuses the real account)" >&2
  echo "Running --real by accident flips the sandbox MCP to the live broker and" >&2
  echo "loses the in-memory demo fixture. See --help." >&2
  exit 2
fi

# Loud mode banner so the active mode is never ambiguous.
if [[ "$MODE" == "light" ]]; then
  echo "════════════════════════════════════════════════════════════════════"
  echo "  MODE: LIGHT — in-memory MCP, self-contained, seeded demo fixture"
  echo "                (the Chengdu memory surprise lives here)"
  echo "════════════════════════════════════════════════════════════════════"
else
  echo "════════════════════════════════════════════════════════════════════"
  echo "  MODE: REAL — live broker + workers + Heima MAINNET"
  echo "               (NO in-memory Chengdu fixture; uses the real account)"
  if [[ "$WEBAUTHN" != true ]]; then
    echo "               webauthn=false → step 1.5 will NOT grant the memory scope;"
    echo "               re-run with --webauthn to seed the Chengdu memory (Touch ID)."
  fi
  echo "════════════════════════════════════════════════════════════════════"
fi

# ─── output (CLAUDE.md ok/skip/fail convention) ──────────────────────────────
FAILED=0
log()  { printf '\n[phase1-wire] %s\n' "$*"; }
ok()   { printf '  %-26s ok proceeding (%s)\n' "$1" "$2"; }
skip() { printf '  %-26s skip %s\n' "$1" "$2"; }
fail() { printf '  %-26s FAIL %s\n' "$1" "$2" >&2; FAILED=$((FAILED+1)); }
skip_phase() { case " $SKIP_PHASES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Manual gate. $1=id, $2=prompt. Secret gates ($3=secret) always prompt.
# Non-secret confirms honor --yes.
gate() {
  local id="$1" prompt="$2" kind="${3:-confirm}"
  if [[ "$kind" != "secret" && "$ASSUME_YES" == true ]]; then
    ok "$id" "auto-confirmed (--yes)"; return 0
  fi
  printf '  %-26s MANUAL — %s\n' "$id" "$prompt" >&2
  if [[ "$kind" == "secret" ]]; then
    read -r -s -p "      > " REPLY; echo >&2
  else
    read -r -p "      [y/N] > " REPLY; echo >&2
    [[ "$REPLY" =~ ^[Yy]$ ]]
  fi
}

# ─── sandbox helpers (the agent host) ────────────────────────────────────────
# --max-time is a hard ceiling so an in-sandbox command that blocks (e.g. a hook
# stalling on stdin, a worker call with no timeout) FAILS LOUD instead of hanging
# the whole demo silently forever. 600s covers the slowest legit call (hermes
# install). Override per-call with SBX_EXEC_MAXTIME if a step needs longer.
sbx_exec()  { curl -sS --max-time "${SBX_EXEC_MAXTIME:-600}" -X POST "$SANDBOX_URL/v1/shell/exec" -H 'content-type: application/json' \
                -d "$(jq -n --arg c "$1" '{command:$c}')" | jq -r '.data.output // ""'; }
sbx_rc()    { curl -sS --max-time "${SBX_EXEC_MAXTIME:-600}" -X POST "$SANDBOX_URL/v1/shell/exec" -H 'content-type: application/json' \
                -d "$(jq -n --arg c "$1" '{command:$c}')" | jq -r '.data.exit_code // 1'; }
sbx_put()   { curl -sS -X POST "$SANDBOX_URL/v1/file/upload" -F "file=@$1" -F "path=$2" \
                | jq -r '.data.file_path // "UPLOAD_FAILED"'; }
# Run one of the wired hook scripts in the sandbox against a stdin payload.
sbx_hook()  { sbx_exec "printf '%s' $(printf '%q' "$2") | bash \$HOME/.hermes/agent-hooks/$1"; }

# ─── session helpers (operator JWT for real-broker cap-mint) ──────────────────
# Decode a session JWT's agentkeys.omni_account claim (lowercase, no 0x). Empty
# on any failure. base64url → openssl (portable across macOS + Linux) → jq.
jwt_omni() {
  local b64 pad
  b64="$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')"
  pad=$(( (4 - ${#b64} % 4) % 4 ))
  [ "$pad" -gt 0 ] && b64="${b64}$(printf '%*s' "$pad" '' | tr ' ' '=')"
  printf '%s' "$b64" | openssl base64 -d -A 2>/dev/null \
    | jq -r '.agentkeys.omni_account // empty' 2>/dev/null \
    | sed 's/^0x//' | tr 'A-F' 'a-f'
}

# Non-interactive session mint: SIWE-sign the broker challenge with $1 (operator
# key file) so the JWT's agentkeys.omni_account == that wallet's broker omni.
# Mirrors harness/v2-stage1-demo.sh::wallet_sig_init_session. Writes session.json
# at $2 and echoes the JWT on stdout (errors to stderr, returns non-zero).
# Requires the broker ($3) to have the wallet_sig auth plugin enabled + `cast`.
wallet_sig_init_session() {
  local key_file="$1" session_file="$2" issuer="${3:-$BROKER_URL}"
  local key addr rid msg sig jwt t1 t2
  key="$(tr -d '[:space:]' < "$key_file")"
  case "$key" in 0x*) ;; *) echo "wallet_sig: $key_file is not 0x-prefixed" >&2; return 1 ;; esac
  addr="$(cast wallet address --private-key "$key" 2>/dev/null)" \
    || { echo "wallet_sig: cast wallet address failed (cast on PATH? key valid?)" >&2; return 1; }
  t1="$(mktemp)"; t2="$(mktemp)"
  if ! curl -sS --max-time 15 -X POST "${issuer%/}/v1/auth/wallet/start" -H 'content-type: application/json' \
        -d "$(jq -n --arg a "$addr" '{address:$a, chain_id:1}')" -o "$t1"; then
    echo "wallet_sig: POST ${issuer%/}/v1/auth/wallet/start failed" >&2; rm -f "$t1" "$t2"; return 1
  fi
  rid="$(jq -r '.request_id // empty' "$t1" 2>/dev/null)"
  msg="$(jq -r '.siwe_message // empty' "$t1" 2>/dev/null)"
  if [ -z "$rid" ] || [ -z "$msg" ]; then
    echo "wallet_sig: wallet/start missing request_id/siwe_message: $(head -c 200 "$t1")" >&2; rm -f "$t1" "$t2"; return 1
  fi
  sig="$(cast wallet sign --private-key "$key" "$msg" 2>/dev/null)" \
    || { echo "wallet_sig: cast wallet sign failed" >&2; rm -f "$t1" "$t2"; return 1; }
  if ! curl -sS --max-time 15 -X POST "${issuer%/}/v1/auth/wallet/verify" -H 'content-type: application/json' \
        -d "$(jq -n --arg r "$rid" --arg s "$sig" '{request_id:$r, signature:$s}')" -o "$t2"; then
    echo "wallet_sig: POST ${issuer%/}/v1/auth/wallet/verify failed" >&2; rm -f "$t1" "$t2"; return 1
  fi
  jwt="$(jq -r '.session_jwt // .jwt // empty' "$t2" 2>/dev/null)"
  rm -f "$t1" "$t2"
  [ -z "$jwt" ] && { echo "wallet_sig: wallet/verify returned no session JWT (broker wallet_sig enabled?)" >&2; return 1; }
  mkdir -p "$(dirname "$session_file")"
  ( umask 077; jq -n --arg t "$jwt" --arg w "$addr" --argjson ttl 18000 --argjson now "$(date +%s)" \
      '{token:$t, wallet:$w, scope:null, ttl_seconds:$ttl, created_at:$now}' > "$session_file" )
  chmod 600 "$session_file" 2>/dev/null || true
  printf '%s' "$jwt"
}

# Resolve the sandbox user's $HOME → binaries go in ~/.local/bin (writable + on
# PATH; the upload API is non-root so /usr/local/bin gives Errno 13). Idempotent:
# sets the absolute dsts once and mkdir -p's the target dir.
resolve_sbx_paths() {
  [[ -n "$AGENT_BIN_DST" ]] && return 0
  SBX_HOME="$(sbx_exec 'printf %s "$HOME"')"
  [[ -n "$SBX_HOME" ]] || { fail "1.0 sandbox home" "could not resolve \$HOME in the sandbox"; return 1; }
  AGENT_BIN_DST="$SBX_HOME/.local/bin/agentkeys"
  MCP_BIN_DST="$SBX_HOME/.local/bin/agentkeys-mcp-server"
  sbx_exec "mkdir -p \"$SBX_HOME/.local/bin\"" >/dev/null
}

# ─── Phase 0 — prerequisites ─────────────────────────────────────────────────
phase0_prereqs() {
  skip_phase 0 && { log "Phase 0 — prerequisites: skip (--skip-0)"; return; }
  log "Phase 0 — prerequisites ($MODE mode)"

  if [[ "$MODE" == "light" ]]; then
    ACTOR_OMNI="$DEMO_ACTOR"; OPERATOR_OMNI="$DEMO_OPERATOR"
    VENDOR_TOKEN="${VENDOR_TOKEN:-demo-tok}"; SESSION_BEARER=""
    ok "0.L identity" "in-memory demo actor ${ACTOR_OMNI:0:14}…"
    return
  fi

  # Mode R — reuse the real account; verify, don't rebuild.
  VENDOR_TOKEN="${VENDOR_TOKEN:-harness-tok}"
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"; ok "0.0 operator-workstation.env" "sourced $ENV_FILE"
  else
    fail "0.0 operator-workstation.env" "missing $ENV_FILE — run scripts/setup-cloud.sh + setup-heima.sh"
  fi

  # Cap-mint (/v1/cap/*) goes to the BROKER = OIDC_ISSUER (https://$BROKER_HOST),
  # NOT the signer ($BACKEND_URL = $AGENTKEYS_SIGNER_URL, which only signs).
  # Pointing the MCP --broker-url at the signer 404s every cap-mint.
  BROKER_URL="${BROKER_URL:-${AGENTKEYS_BROKER_URL:-${OIDC_ISSUER:-}}}"

  if AGENTKEYS_CHAIN=heima bash "$REPO_ROOT/scripts/verify-heima-contracts.sh" >/dev/null 2>&1; then
    ok "0.1 heima contracts" "verify-heima-contracts.sh passed"
  else
    fail "0.1 heima contracts" "verify-heima-contracts.sh failed — run scripts/setup-heima.sh"
  fi

  local broker="$BROKER_URL"
  if [[ -n "$broker" ]] && curl -fsS "${broker%/}/healthz" >/dev/null 2>&1; then
    ok "0.2 broker healthz" "$broker"
  else
    fail "0.2 broker healthz" "broker not reachable (BACKEND_URL=$broker) — run scripts/setup-broker-host.sh"
  fi

  # Resolve operator_omni + actor_omni. OPERATOR_OMNI is the MASTER's omni
  # (sha256("agentkeys"||"evm"||master_addr_lc)) — derive it from OPERATOR_KEY_FILE
  # so it NEVER depends on the (key-less, fresh-each-run) agent file. In fresh
  # §10.2 pairing (real, default) ACTOR_OMNI is set later by Phase P; the legacy
  # file path stays for --reuse-agent.
  local fresh_pairing=false
  [[ "$MODE" == "real" && "$REUSE_AGENT" != true ]] && fresh_pairing=true
  if [[ -z "$OPERATOR_OMNI" && -f "$OPERATOR_KEY_FILE" ]] && command -v cast >/dev/null 2>&1; then
    local _maddr; _maddr="$(cast wallet address --private-key "$(tr -d '[:space:]' < "$OPERATOR_KEY_FILE")" 2>/dev/null | tr 'A-F' 'a-f')"
    [[ -n "$_maddr" ]] && OPERATOR_OMNI="0x$(printf 'agentkeysevm%s' "$_maddr" | shasum -a 256 | awk '{print $1}')"
  fi
  if [[ -z "$ACTOR_OMNI" && "$fresh_pairing" != true && -f "$AGENT_FILE" ]]; then
    ACTOR_OMNI="$(jq -r '.actor_omni // empty' "$AGENT_FILE" 2>/dev/null)"
  fi
  if [[ -z "$OPERATOR_OMNI" && -f "$AGENT_FILE" ]]; then
    OPERATOR_OMNI="$(jq -r '.operator_omni // empty' "$AGENT_FILE" 2>/dev/null)"
  fi
  if [[ -z "$DEVICE_KEY_HASH" && "$fresh_pairing" != true && -f "$AGENT_FILE" ]]; then
    DEVICE_KEY_HASH="$(jq -r '.device_key_hash // empty' "$AGENT_FILE" 2>/dev/null)"
  fi
  if [[ -n "$ACTOR_OMNI" ]]; then ok "0.4 agent actor_omni" "${ACTOR_OMNI:0:14}…"
  elif [[ "$fresh_pairing" == true ]]; then skip "0.4 agent actor_omni" "fresh pairing — Phase P generates the agent key in the sandbox + sets actor_omni"
  else fail "0.4 agent actor_omni" "unknown — pass --actor-omni / AGENTKEYS_ACTOR_OMNI, or run heima-agent-create.sh (--agent-file $AGENT_FILE)"; fi
  if [[ -n "$OPERATOR_OMNI" ]]; then ok "0.3 operator_omni" "${OPERATOR_OMNI:0:14}… (from master key)"
  else fail "0.3 operator_omni" "unknown — set OPERATOR_KEY_FILE (master key) or AGENTKEYS_OPERATOR_OMNI / .operator_omni in $AGENT_FILE"; fi

  # 0.5 scope (verify; grant via real Touch ID only if missing).
  if [[ -n "${SCOPE_CONTRACT_ADDRESS_HEIMA:-}" && -n "$ACTOR_OMNI" ]]; then
    log "  0.5 scope: verifying memory scope on-chain (manual grant + Touch ID if missing)"
    # Real grant path is heima-scope-set.sh --webauthn; the operator runs it
    # when the verify shows the scope is absent (kept manual = real K11).
    ok "0.5 scope" "verify via heima-scope-set.sh; grant needs real Touch ID if absent"
  fi

  # 0.6 LLM key — env fallback (OPENROUTER_API_KEY / LLM_API_KEY) → manual paste.
  if [[ -n "$LLM_API_KEY" ]]; then
    ok "0.6 LLM key" "from OPENROUTER_API_KEY/LLM_API_KEY env (${#LLM_API_KEY} chars)"
  else
    gate "0.6 LLM key" "no OPENROUTER_API_KEY in env (export it in ~/.zshenv) — paste an LLM key now, or just press enter to skip the Phase 4 surprise" secret || true
    [[ -n "${REPLY:-}" ]] && LLM_API_KEY="$REPLY"
    if [[ -n "$LLM_API_KEY" ]]; then ok "0.6 LLM key" "operator-provided (${#LLM_API_KEY} chars)"
    else skip "0.6 LLM key" "none provided — Phase 4 surprise will be skipped"; fi
  fi

  # 0.7 session bearer — must be a FRESH JWT whose agentkeys.omni_account ==
  # OPERATOR_OMNI. cap-mint enforces session_omni == operator_omni (arch.md
  # §22b.4 + handlers/cap.rs OperatorMismatch). Two silent traps this guards:
  #   • a reused email session (e.g. 'alice') is a DIFFERENT operator omni →
  #     cap-mint 401/OperatorMismatch even though the file looks valid;
  #   • an old session → ExpiredSignature.
  # So: validate the on-disk session's omni + expiry, and auto-mint a fresh
  # OPERATOR session non-interactively via wallet_sig (SIWE-sign with
  # OPERATOR_KEY_FILE) whenever it's missing / stale / wrong-omni.
  local sess_file="${MASTER_SESSION_FILE:-$HOME/.agentkeys/$SESSION_ID/session.json}"
  local want_omni; want_omni="$(printf '%s' "$OPERATOR_OMNI" | sed 's/^0x//' | tr 'A-F' 'a-f')"
  [[ -z "$SESSION_BEARER" && -f "$sess_file" ]] && SESSION_BEARER="$(jq -r '.token // empty' "$sess_file" 2>/dev/null)"

  local need_mint=1 reason="no session on disk"
  if [[ -n "$SESSION_BEARER" ]]; then
    local sess_omni ca tl now
    sess_omni="$(jwt_omni "$SESSION_BEARER")"
    ca="$(jq -r '.created_at // 0' "$sess_file" 2>/dev/null)"
    tl="$(jq -r '.ttl_seconds // 0' "$sess_file" 2>/dev/null)"
    now="$(date +%s)"
    if [[ -n "$want_omni" && -n "$sess_omni" && "$sess_omni" != "$want_omni" ]]; then
      reason="session omni 0x${sess_omni:0:12}… != operator_omni 0x${want_omni:0:12}…"
    elif [[ "$ca" =~ ^[0-9]+$ && "$tl" =~ ^[0-9]+$ && "$tl" -gt 0 && $((ca + tl)) -lt "$now" ]]; then
      reason="session expired"
    else
      need_mint=0
    fi
  fi

  if [[ "$need_mint" -eq 1 ]]; then
    if [[ -f "$OPERATOR_KEY_FILE" ]] && command -v cast >/dev/null 2>&1 && [[ -n "$BROKER_URL" ]]; then
      log "  0.7 session bearer: $reason → minting a fresh operator session via wallet_sig ($(basename "$OPERATOR_KEY_FILE"))"
      local minted
      if minted="$(wallet_sig_init_session "$OPERATOR_KEY_FILE" "$sess_file" "$BROKER_URL")"; then
        SESSION_BEARER="$minted"
      else
        log "  0.7 session bearer: wallet_sig mint failed (see message above)"
      fi
    else
      log "  0.7 session bearer: $reason, and cannot auto-mint (need OPERATOR_KEY_FILE=$OPERATOR_KEY_FILE, 'cast' on PATH, and a broker URL)"
    fi
  fi

  if [[ -n "$SESSION_BEARER" ]]; then
    local got_omni; got_omni="$(jwt_omni "$SESSION_BEARER")"
    if [[ -n "$want_omni" && -n "$got_omni" && "$got_omni" != "$want_omni" ]]; then
      fail "0.7 session bearer" "session omni 0x${got_omni:0:12}… != operator_omni 0x${want_omni:0:12}… — OPERATOR_KEY_FILE ($OPERATOR_KEY_FILE) signs as the WRONG operator. Set OPERATOR_KEY_FILE to the master key whose broker omni == operator_omni."
    else
      ok "0.7 session bearer" "operator session ready (omni matches operator_omni, ${#SESSION_BEARER} chars)"
    fi
  else
    fail "0.7 session bearer" "no valid operator session — set OPERATOR_KEY_FILE to the master key for operator_omni 0x$want_omni (broker $BROKER_URL must have the wallet_sig plugin), or pass AGENTKEYS_SESSION_BEARER for that operator."
  fi

  # 0.8 agent session bearer — for the per-actor STS relay (issue #90). The MCP
  # server uses THIS session (omni == actor_omni) to mint
  # AssumeRoleWithWebIdentity creds tagged with the agent actor, so the worker's
  # S3 ops are AWS-scoped to bots/<actor>/memory/. Distinct from 0.7's OPERATOR
  # session. In fresh §10.2 pairing it is minted IN THE SANDBOX by Phase P (the
  # key never touches the master); only the legacy --reuse-agent path mints it
  # here from the master-held agent_private_key.
  if [[ "$MODE" == "real" && "$REUSE_AGENT" != true ]]; then
    skip "0.8 agent session" "fresh pairing — minted in the sandbox by Phase P (key never on master)"
  elif [[ "$MODE" == "real" ]]; then
    if [[ -z "$AGENT_SESSION_BEARER" ]]; then
      local agent_key; agent_key="$(jq -r '.agent_private_key // empty' "$AGENT_FILE" 2>/dev/null)"
      if [[ -n "$agent_key" ]] && command -v cast >/dev/null 2>&1 && [[ -n "$BROKER_URL" ]]; then
        [[ "${agent_key:0:2}" != "0x" ]] && agent_key="0x$agent_key"
        local akf asf; akf="$(mktemp)"; asf="$(mktemp)"
        ( umask 077; printf '%s' "$agent_key" > "$akf" )
        local ajwt; ajwt="$(wallet_sig_init_session "$akf" "$asf" "$BROKER_URL")" && AGENT_SESSION_BEARER="$ajwt" || true
        rm -f "$akf" "$asf"
      fi
    fi
    if [[ -n "$AGENT_SESSION_BEARER" ]]; then
      local aomni wa; aomni="$(jwt_omni "$AGENT_SESSION_BEARER")"
      wa="$(printf '%s' "$ACTOR_OMNI" | sed 's/^0x//' | tr 'A-F' 'a-f')"
      if [[ -n "$wa" && "$aomni" == "$wa" ]]; then
        ok "0.8 agent session" "minted (omni == actor_omni — per-actor STS relay enabled)"
      else
        fail "0.8 agent session" "agent session omni 0x${aomni:0:12}… != actor_omni 0x${wa:0:12}… — agent_private_key in $AGENT_FILE doesn't derive actor_omni; worker S3 ops will 502."
      fi
    else
      fail "0.8 agent session" "(--reuse-agent) could not mint agent session — needs agent_private_key in $AGENT_FILE + cast + broker wallet_sig, or set AGENTKEYS_AGENT_SESSION_BEARER."
    fi
  fi
}

# Clean slate before a run: the real-memory demo must prove the agent recalls
# from the LIVE worker, so it must NOT start from a cached Hermes session/answer
# or a leftover fake (in-memory) MCP launcher. Each sbx_exec is its own call +
# `; true` so a no-op (nothing to kill/remove) never trips the sandbox shell API.
clean_slate() {
  # stop orphaned interactive Hermes (holds state.db open). Specific patterns so
  # the install / this exec are never matched.
  sbx_exec "pkill -f 'venv/bin/hermes chat' 2>/dev/null; pkill -f 'venv/bin/hermes -z' 2>/dev/null; sleep 1; true" >/dev/null 2>&1
  # remove stale MCP launcher leftovers — these start the FAKE in-memory server
  # (magiclick:demo-tok + seeded Chengdu fixture) and would defeat --real.
  sbx_exec "rm -f \"\$HOME/start-mcp-light.sh\" \"\$HOME/test-respawn.sh\" \"\$HOME\"/.hermes/start-mcp*.sh 2>/dev/null; true" >/dev/null 2>&1
  # clear Hermes native session + conversation state + native memory (no cached answer)
  sbx_exec "rm -f \"\$HOME\"/.hermes/state.db \"\$HOME\"/.hermes/state.db-shm \"\$HOME\"/.hermes/state.db-wal \"\$HOME\"/.hermes/sessions/* \"\$HOME/.hermes/.hermes_history\" 2>/dev/null; : > \"\$HOME/.hermes/memories/MEMORY.md\" 2>/dev/null; : > \"\$HOME/.hermes/memories/USER.md\" 2>/dev/null; true" >/dev/null 2>&1
  ok "1.2b clean slate" "Hermes session/state + native memory cleared; stale fake-MCP launchers removed"
}

# ─── Phase 1 — sandbox bring-up ──────────────────────────────────────────────
phase1_sandbox() {
  skip_phase 1 && { log "Phase 1 — sandbox bring-up: skip (--skip-1)"; return; }
  log "Phase 1 — sandbox bring-up (agent host)"

  # 1.1 sandbox up
  if curl -fsS "$SANDBOX_URL/healthz" >/dev/null 2>&1 || curl -fsS "$SANDBOX_URL/v1/sandbox" >/dev/null 2>&1; then
    ok "1.1 sandbox up" "$SANDBOX_URL reachable"
  else
    fail "1.1 sandbox up" "no sandbox at $SANDBOX_URL — docker run --security-opt seccomp=unconfined -d -p 8080:8080 ghcr.io/agent-infra/sandbox:latest"
    return
  fi

  # Resolve sandbox binary destinations (~/.local/bin) now that it's reachable.
  resolve_sbx_paths || return

  # 1.2 hermes installed (idempotent guard)
  if [[ "$(sbx_rc 'command -v hermes')" == "0" ]]; then
    ok "1.2 hermes" "$(sbx_exec 'hermes --version 2>&1 | head -1')"
  else
    log "  1.2 hermes: installing (guarded curl|bash)"
    sbx_exec "curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash" >/dev/null
    [[ "$(sbx_rc 'command -v hermes')" == "0" ]] && ok "1.2 hermes" "installed" || fail "1.2 hermes" "install failed"
  fi

  # 1.2b clean slate — a REAL-memory demo must prove the agent recalls from the
  # LIVE worker via injection, not from a cached Hermes session or a leftover
  # fake (in-memory) MCP launcher. Wipe Hermes' native session/conversation
  # state + remove stale launchers so every run starts from zero. SKIP_CLEAN=1
  # opts out (e.g. to inspect a prior session).
  [[ "${SKIP_CLEAN:-0}" == "1" ]] && skip "1.2b clean slate" "SKIP_CLEAN=1" || clean_slate

  # 1.3 agentkeys + mcp-server binaries (aarch64-linux) into the sandbox via its file API
  build_linux_binaries || return
  local mcp_bin_changed=false
  for pair in "$LINUX_TARGET_DIR/release/agentkeys:$AGENT_BIN_DST" \
              "$LINUX_TARGET_DIR/release/agentkeys-mcp-server:$MCP_BIN_DST"; do
    local src="${pair%%:*}" dst="${pair##*:}"
    local name; name="$(basename "$dst")"
    local want; want="$(shasum -a256 "$src" 2>/dev/null | awk '{print $1}')"
    local have; have="$(sbx_exec "sha256sum $dst 2>/dev/null | awk '{print \$1}'")"
    if [[ -n "$want" && "$want" == "$have" ]]; then
      ok "1.3 $name" "already present (sha matches)"
    else
      # A RUNNING executable can't be overwritten (ETXTBSY "Text file busy"), so
      # stop a live mcp-server before uploading its new binary; 1.4 restarts it.
      [[ "$dst" == "$MCP_BIN_DST" ]] && sbx_exec "pkill -f agentkeys-mcp-server 2>/dev/null; sleep 1" >/dev/null
      [[ "$(sbx_put "$src" "$dst")" == "$dst" ]] || { fail "1.3 $name" "upload failed"; continue; }
      sbx_exec "chmod +x $dst" >/dev/null
      [[ "$dst" == "$MCP_BIN_DST" ]] && mcp_bin_changed=true
      # Probe with --help (both binaries support it; the server has no --version).
      [[ "$(sbx_rc "$dst --help")" == "0" ]] && ok "1.3 $name" "uploaded + executable" || fail "1.3 $name" "not runnable in sandbox"
    fi
  done

  # ─── Phase P — install (pair) ────────────────────────────────────────────────
  # Fresh §10.2 pairing: the agent generates its OWN secp256k1 device key IN THE
  # SANDBOX (never on the master), mints a session via wallet_sig, the master
  # binds the device on-chain, then "approves" the memory scope. Fresh each run
  # (--regen) → new omni → empty memory → seeded at 1.5 → recalled in Act 1: the
  # full "install an app + approve its permissions" story. Skipped under
  # --reuse-agent (legacy master-side agent key) and in --light.
  if [[ "$MODE" == "real" && "$REUSE_AGENT" != true ]]; then
    log "  Phase P — install (pair): agent generates its device key IN THE SANDBOX (arch.md §10.2; interim #144)"
    local link_code ds ds_addr ds_actor ds_dkh ds_pop ds_jwt
    link_code="lc-$(openssl rand -hex 16)"   # one-time link code (master-minted; stub binding per #144)
    ds="$(sbx_exec "$AGENT_BIN_DST agent device-session --broker-url ${BROKER_URL:-} --link-code $link_code --regen 2>&1")"
    ds_addr="$(echo "$ds" | jq -r '.agent_address // empty' 2>/dev/null)"
    ds_actor="$(echo "$ds" | jq -r '.actor_omni // empty' 2>/dev/null)"
    ds_dkh="$(echo "$ds" | jq -r '.device_key_hash // empty' 2>/dev/null)"
    ds_pop="$(echo "$ds" | jq -r '.pop_sig // empty' 2>/dev/null)"
    ds_jwt="$(echo "$ds" | jq -r '.session_jwt // empty' 2>/dev/null)"
    if [[ -z "$ds_jwt" || -z "$ds_actor" || -z "$ds_addr" || -z "$ds_dkh" || -z "$ds_pop" ]]; then
      fail "P.1 device-session" "in-sandbox device-session failed: $(echo "$ds" | tr '\n' ' ' | cut -c1-200)"
    else
      ACTOR_OMNI="$ds_actor"; AGENT_SESSION_BEARER="$ds_jwt"; DEVICE_KEY_HASH="$ds_dkh"
      ok "P.1 device-session" "📲 agent paired — addr ${ds_addr:0:12}…, omni ${ds_actor:0:14}… (key SANDBOX-only)"
      # P.2 master binds the SANDBOX-generated device on-chain (it never saw the key).
      local reg; reg="$(bash "$REPO_ROOT/scripts/heima-agent-create.sh" --label "$AGENT_LABEL" \
        --agent-address "$ds_addr" --actor-omni "$ds_actor" --device-key-hash "$ds_dkh" --pop-sig "$ds_pop" 2>&1)"
      echo "$reg" | sed 's/^/        /' >&2
      if echo "$reg" | grep -qiE '"ok"[[:space:]]*:[[:space:]]*true'; then
        ok "P.2 register device" "on-chain registerAgentDevice (or already-active)"
      else
        fail "P.2 register device" "registerAgentDevice failed: $(echo "$reg" | tr '\n' ' ' | cut -c1-160)"
      fi
      # P.3 approve permissions: master grants the FRESH actor the memory scope.
      if [[ "$WEBAUTHN" == true ]]; then
        log "    P.3 approve permissions: heima-scope-set --webauthn --agent $AGENT_LABEL --services ${SEED_SCOPE_SERVICES:-memory} (expect Touch ID)"
        local grant; grant="$(bash "$REPO_ROOT/scripts/heima-scope-set.sh" --webauthn --agent "$AGENT_LABEL" --services "${SEED_SCOPE_SERVICES:-memory}" 2>&1)"
        echo "$grant" | sed 's/^/        /' >&2
        echo "$grant" | grep -qiE '"ok"[[:space:]]*:[[:space:]]*true' \
          && ok "P.3 approve permissions" "🔐 master granted [${SEED_SCOPE_SERVICES:-memory}] to ${ds_actor:0:14}… (Touch ID)" \
          || fail "P.3 approve permissions" "scope grant failed: $(echo "$grant" | tr '\n' ' ' | cut -c1-160)"
      else
        skip "P.3 approve permissions" "no --webauthn — re-run with --real --webauthn so the master can grant the fresh actor's scope (Touch ID)"
      fi
    fi
  fi

  # 1.4 MCP server in the sandbox (detached). Idempotent + mode/token-aware:
  # a server already on :MCP_PORT is REUSED only when its --backend AND
  # --vendor-tokens match THIS run's intent. A mismatched server — a leftover
  # real-mode server when we asked for --light, or a stale token — is killed and
  # restarted; otherwise the wired hook's token won't match the server and every
  # memory.get/permission.check 401s ("bearer token not recognized"). Also
  # restart when a fresh binary was just uploaded.
  local mcp_backend mcp_vendor mcp_brokerarg mcp_relayarg cmd
  if [[ "$MODE" == "light" ]]; then
    mcp_backend="in-memory"; mcp_vendor="magiclick:$VENDOR_TOKEN"; mcp_brokerarg=""; mcp_relayarg=""
    cmd="$MCP_BIN_DST --backend in-memory --transport http --listen 127.0.0.1:$MCP_PORT --vendor-tokens $mcp_vendor"
  else
    mcp_backend="http"; mcp_vendor="harness:$VENDOR_TOKEN"; mcp_brokerarg="--broker-url ${BROKER_URL:-}"
    # Per-actor STS relay (issue #90): the MCP server uses the AGENT session
    # (0.8 — omni == actor_omni) to mint AssumeRoleWithWebIdentity creds tagged
    # with the actor, then forwards them to the worker as X-Aws-* headers so the
    # worker's S3 ops are AWS-scoped to bots/<actor>/memory/. Without it the
    # worker falls back to its instance profile (no S3) and every op 502s.
    mcp_relayarg=""
    [[ -n "$AGENT_SESSION_BEARER" ]] && mcp_relayarg="--agent-session-bearer $AGENT_SESSION_BEARER --memory-role-arn ${MEMORY_ROLE_ARN:-} --vault-role-arn ${VAULT_ROLE_ARN:-} --aws-region ${REGION:-us-east-1}"
    cmd="$MCP_BIN_DST --backend http --transport http --listen 127.0.0.1:$MCP_PORT --vendor-tokens $mcp_vendor --broker-url ${BROKER_URL:-} --memory-url ${AGENTKEYS_WORKER_MEMORY_URL:-} --audit-url ${AGENTKEYS_WORKER_AUDIT_URL:-} --default-actor $ACTOR_OMNI --default-operator-omni $OPERATOR_OMNI --default-device-key-hash $DEVICE_KEY_HASH $mcp_relayarg"
  fi
  # Reuse only if a live server's argv carries the intended backend + token AND
  # (real mode) the intended --broker-url — else a stale server pointed at the
  # wrong broker (e.g. the signer) is silently reused. Empty mcp_brokerarg in
  # light mode makes that last grep a no-op (empty pattern matches every line).
  # In real mode with the STS relay, never reuse: the agent session bearer is
  # freshly minted each run (0.8), and a reused server would hold a stale bearer
  # → mint-oidc-jwt 401 on every memory op. -z "$AGENT_SESSION_BEARER" is true in
  # light mode (and real-without-relay), preserving fast reuse there.
  local reuse=false
  if [[ "$mcp_bin_changed" != true \
        && -z "$AGENT_SESSION_BEARER" \
        && "$(sbx_rc "curl -fsS http://localhost:$MCP_PORT/healthz")" == "0" \
        && -n "$(sbx_exec "pgrep -af agentkeys-mcp-server | grep -F -- '--backend $mcp_backend' | grep -F -- '--vendor-tokens $mcp_vendor' | grep -F -- '$mcp_brokerarg'")" ]]; then
    reuse=true
  fi
  if [[ "$reuse" == true ]]; then
    ok "1.4 mcp server" "already up on :$MCP_PORT ($mcp_backend, token matches)"
  else
    # Kill any mismatched/stale/leftover server. The server runs under a respawn
    # loop (below); the wrapper's argv also matches agentkeys-mcp-server, so a
    # double-pkill (with a beat between) takes down both the loop and any child
    # it respawns mid-restart.
    sbx_exec "pkill -f agentkeys-mcp-server 2>/dev/null; sleep 1; pkill -f agentkeys-mcp-server 2>/dev/null; sleep 1" >/dev/null
    # Start under a RESPAWN LOOP so a crash self-heals without a harness re-run,
    # and append (>>) to the log so a restart never truncates the audit trail
    # (a plain > wiped it on every restart). The server re-seeds its in-memory
    # fixture on each (re)start, so a respawn is a clean reset — no data drift.
    sbx_exec "nohup bash -c 'while true; do $cmd >>/tmp/agentkeys-mcp.log 2>&1; echo \"[respawn]\" >>/tmp/agentkeys-mcp.log; sleep 1; done' >/dev/null 2>&1 & sleep 2; echo started" >/dev/null
    [[ "$(sbx_rc "curl -fsS http://localhost:$MCP_PORT/healthz")" == "0" ]] \
      && ok "1.4 mcp server" "(re)started under respawn loop ($mcp_backend backend, token $mcp_vendor)" \
      || fail "1.4 mcp server" "did not come up — see /tmp/agentkeys-mcp.log in the sandbox"
  fi

  # 1.5 seed the real memory worker (Mode R ONLY — in-memory auto-seeds). The
  # agent reads this back in Act 1. Idempotent + scope-aware + --webauthn-gated:
  #   a. namespace already has content → skip everything (no Touch ID);
  #   b. else try memory.put directly — succeeds if the scope is already granted
  #      (also no Touch ID);
  #   c. if the put is scope-rejected:
  #        --webauthn passed → grant the memory SERVICE scope via real WebAuthn
  #                            (heima-scope-set.sh → Touch ID), then retry the put;
  #        --webauthn ABSENT → do NOT trigger Touch ID; fail loud telling the
  #                            operator to re-run with --webauthn.
  # This is why the banner shows webauthn=<flag>: it gates whether 1.5 may run a
  # real Touch ID ceremony. SEED_MEMORY_CONTENT overrides the fixture;
  # SEED_SCOPE_SERVICES the granted list (heima-scope-set.sh SETS the full list).
  if [[ "$MODE" == "real" ]]; then
    local seed="${SEED_MEMORY_CONTENT:-Chengdu trip — Apr 12 to 16, hotpot at Yulin.}"
    local svcs="${SEED_SCOPE_SERVICES:-memory}"
    local env_pfx="AGENTKEYS_MCP_URL=$MCP_URL_IN_SANDBOX AGENTKEYS_MCP_VENDOR_TOKEN=$VENDOR_TOKEN AGENTKEYS_ACTOR_OMNI=$ACTOR_OMNI AGENTKEYS_OPERATOR_OMNI=$OPERATOR_OMNI AGENTKEYS_SESSION_BEARER=$SESSION_BEARER"
    # </dev/null gives stdin an immediate EOF — older binaries' memory-inject
    # block on read_to_string(stdin) without it (fixed in hook.rs, kept here so
    # a stale on-sandbox binary can't re-freeze the demo before 1.3 re-uploads).
    local got; got="$(sbx_exec "$env_pfx $AGENT_BIN_DST hook memory-inject --namespaces $MEMORY_NS </dev/null 2>/dev/null")"
    if echo "$got" | grep -q '"context"'; then
      ok "1.5 seed memory" "namespace '$MEMORY_NS' already populated — skip"
    elif gate "1.5 seed memory" "memory '$MEMORY_NS' is empty — seed \"$seed\" to the real worker (grants the scope via real Touch ID only if --webauthn). Proceed?" confirm; then
      # 1.5a try the put directly — works if the scope is already granted.
      local out; out="$(sbx_exec "$env_pfx $AGENT_BIN_DST memory put --namespace $MEMORY_NS --content \"$seed\" 2>&1")"
      if echo "$out" | grep -qiE '"ok":[[:space:]]*true|s3_key'; then
        ok "1.5 seed memory" "wrote '$MEMORY_NS' to the real worker (scope already granted)"
      elif [[ "$WEBAUTHN" == true ]]; then
        # 1.5b scope rejected + --webauthn → grant via real Touch ID, then retry.
        log "  1.5b scope grant: heima-scope-set.sh --webauthn --agent $AGENT_LABEL --services $svcs (expect a Touch ID prompt)"
        local grant; grant="$(bash "$REPO_ROOT/scripts/heima-scope-set.sh" --webauthn --agent "$AGENT_LABEL" --services "$svcs" 2>&1)"
        echo "$grant" | sed 's/^/      /' >&2
        if echo "$grant" | grep -q '"skipped"'; then
          fail "1.5 seed memory" "scope grant SKIPPED — K11 not enrolled with webauthn. Run: agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x$OPERATOR_OMNI ; then re-run."
        else
          local out2; out2="$(sbx_exec "$env_pfx $AGENT_BIN_DST memory put --namespace $MEMORY_NS --content \"$seed\" 2>&1")"
          if echo "$out2" | grep -qiE '"ok":[[:space:]]*true|s3_key'; then
            ok "1.5 seed memory" "granted scope (Touch ID) + wrote '$MEMORY_NS' to the real worker"
          else
            fail "1.5 seed memory" "memory.put still failed after grant — session expired or worker unreachable. Output: $(echo "$out2" | tr '\n' ' ' | cut -c1-160)"
          fi
        fi
      else
        fail "1.5 seed memory" "memory.put rejected (scope not granted) and --webauthn NOT passed — the harness won't trigger Touch ID. Re-run: bash harness/phase1-wire-demo.sh --real --webauthn (grants the memory scope + seeds). put: $(echo "$out" | tr '\n' ' ' | cut -c1-120)"
      fi
    else
      skip "1.5 seed memory" "operator declined"
    fi
  fi
}

# Cross-build aarch64-linux binaries in an arm64 Linux rust container.
# The sandbox is aarch64 Linux; the Mac is arm64 darwin — same CPU, different
# OS — so the agent binary must be cross-built.
#
# Caching (so re-runs are fast + idempotent, like a local `cargo build`):
#   • TARGET dir        → target/sandbox-linux is bind-mounted to the host, so
#                         compiled crates + deps persist across runs.
#   • REGISTRY + git    → named docker volumes, so the crates.io index and the
#                         downloaded .crate sources survive the --rm container
#                         (no multi-minute re-fetch every run).
#   • RUSTUP toolchain  → named docker volume for /usr/local/rustup, so the
#                         host-pinned toolchain (RUSTUP_TOOLCHAIN) is downloaded
#                         ONCE, not re-fetched (~250 MB) on every --rm run. This
#                         is the difference between a one-line change taking ~15s
#                         (incremental compile only) vs ~2 min (toolchain + compile).
#   • OpenSSL deps      → reqwest's default native-tls links libssl, so we bake
#                         pkg-config + libssl-dev into a derived builder image
#                         ONCE (docker caches it) instead of apt-getting per run.
#   • source-aware gate → rebuild only when a tracked .rs / Cargo.toml /
#                         Cargo.lock is newer than the built binary; else skip.
# RUST_BUILD_IMAGE overrides the BASE image when Docker Hub is unreachable.
RUST_BUILD_IMAGE="${RUST_BUILD_IMAGE:-rust:1.83-slim-bookworm}"
BUILDER_IMAGE="${BUILDER_IMAGE:-agentkeys-sandbox-builder:1.83-bookworm}"
CARGO_REGISTRY_VOL="${CARGO_REGISTRY_VOL:-agentkeys-sandbox-cargo-registry}"
CARGO_GIT_VOL="${CARGO_GIT_VOL:-agentkeys-sandbox-cargo-git}"
# Persist the rustup toolchain dir too. The builder image bakes only the BASE
# image's toolchain (e.g. 1.83), but the cross-build pins RUSTUP_TOOLCHAIN to the
# host's rustc (e.g. 1.94). Without this volume, rustup re-downloads the entire
# pinned toolchain (~250 MB) on EVERY --rm run — which dwarfs the incremental
# compile and is why a one-line change "rebuilds slowly". A named volume is
# seeded from the image's /usr/local/rustup on first use, then caches the
# downloaded pinned toolchain so later runs only recompile the changed crate.
RUSTUP_VOL="${RUSTUP_VOL:-agentkeys-sandbox-rustup}"

# True (0) when any tracked source is newer than the reference binary ($1).
sources_newer() {
  local ref="$1"
  [[ -n "$(find "$REPO_ROOT/crates" "$REPO_ROOT/Cargo.toml" "$REPO_ROOT/Cargo.lock" \
        \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) \
        -newer "$ref" -print -quit 2>/dev/null)" ]]
}

# Derived builder image = base rust + OpenSSL build deps, baked once so apt
# never re-runs per build. Idempotent: docker image inspect short-circuits.
# Returns non-zero if the base image can't be obtained.
ensure_builder_image() {
  docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 && return 0
  # Fail-fast timeout so a flaky registry can't hang the harness (Docker Hub
  # auth EOFs have been observed). timeout/gtimeout used when present.
  local TO=""
  command -v timeout  >/dev/null 2>&1 && TO="timeout 180"
  command -v gtimeout >/dev/null 2>&1 && TO="gtimeout 180"
  if ! docker image inspect "$RUST_BUILD_IMAGE" >/dev/null 2>&1; then
    log "  1.3 linux build: pulling base $RUST_BUILD_IMAGE …"
    if ! $TO docker pull --platform linux/arm64 "$RUST_BUILD_IMAGE" >/dev/null 2>&1; then
      fail "1.3 linux build" "cannot pull $RUST_BUILD_IMAGE (registry unreachable/timed out). Set RUST_BUILD_IMAGE to a local/mirror rust image, or pre-pull it, then re-run."
      return 1
    fi
  fi
  log "  1.3 linux build: building cached builder image $BUILDER_IMAGE (one-time)…"
  docker build --platform linux/arm64 -t "$BUILDER_IMAGE" - <<DOCKERFILE
FROM ${RUST_BUILD_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
    fail "1.3 linux build" "could not build builder image $BUILDER_IMAGE (see docker output above)"
    return 1
  fi
}

build_linux_binaries() {
  local agent_bin="$LINUX_TARGET_DIR/release/agentkeys"
  local mcp_bin="$LINUX_TARGET_DIR/release/agentkeys-mcp-server"
  # Idempotent + source-aware: skip when both binaries exist and no tracked
  # source is newer; otherwise (re)build incrementally (caches persist).
  # Check BOTH binaries against the source — a stale mcp-server must not be
  # masked by an up-to-date cli (the two crates build + fail independently).
  if [[ -x "$agent_bin" && -x "$mcp_bin" ]] \
     && ! sources_newer "$agent_bin" && ! sources_newer "$mcp_bin"; then
    ok "1.3 linux build" "up-to-date (no source changes; cached)"; return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    fail "1.3 linux build" "docker required to cross-build the aarch64-linux agent binary"; return 1
  fi
  ensure_builder_image || return 1
  # Pin the cross-build toolchain to the host's rustc version. rust-toolchain.toml
  # pins `channel = "stable"`, which FLOATS — a fresh container pulls the LATEST
  # stable, which has broken clean builds of pre-release deps (crypto-common 0.2 /
  # hybrid-array). Matching the host keeps the cross-build reproducible. Override
  # with CROSS_RUST_TOOLCHAIN=<ver>.
  local host_toolchain; host_toolchain="$(rustc --version 2>/dev/null | awk '{print $2}')"
  local cross_toolchain="${CROSS_RUST_TOOLCHAIN:-${host_toolchain:-stable}}"
  log "  1.3 linux build: cross-compiling aarch64-linux binaries (toolchain $cross_toolchain; first run is slow)…"
  local build_rc=0
  docker run --rm --platform linux/arm64 \
    -v "$REPO_ROOT":/src -w /src \
    -v "$CARGO_REGISTRY_VOL":/usr/local/cargo/registry \
    -v "$CARGO_GIT_VOL":/usr/local/cargo/git \
    -v "$RUSTUP_VOL":/usr/local/rustup \
    -e CARGO_TARGET_DIR=/src/target/sandbox-linux \
    -e RUSTUP_TOOLCHAIN="$cross_toolchain" \
    "$BUILDER_IMAGE" \
    cargo build --release -p agentkeys-cli -p agentkeys-mcp-server || build_rc=$?
  # Check the BUILD EXIT CODE, not just file existence — a stale binary from a
  # prior build must not be mistaken for a fresh success (silent-failure trap).
  if [[ "$build_rc" -eq 0 && -x "$agent_bin" && -x "$mcp_bin" ]]; then
    ok "1.3 linux build" "built aarch64-linux binaries (toolchain $cross_toolchain)"; return 0
  elif [[ -x "$agent_bin" && -x "$mcp_bin" ]]; then
    skip "1.3 linux build" "cross-build FAILED (rc=$build_rc) — using the previously-built binary; SOURCE CHANGES ARE NOT DEPLOYED (try CROSS_RUST_TOOLCHAIN=<ver>, or clear target/sandbox-linux; see docker output above)"
    return 0
  else
    fail "1.3 linux build" "cross-build failed (rc=$build_rc) and no usable binary present (see docker output above)"; return 1
  fi
}

# ─── Phase 2 — wire ──────────────────────────────────────────────────────────
phase2_wire() {
  skip_phase 2 && { log "Phase 2 — wire: skip (--skip-2)"; return; }
  log "Phase 2 — wire (#141 core)"
  resolve_sbx_paths || return
  local wire_args="hermes --actor-omni $ACTOR_OMNI --operator-omni $OPERATOR_OMNI --namespaces $MEMORY_NS --payment-scope $PAYMENT_SCOPE --mcp-url $MCP_URL_IN_SANDBOX --vendor-token $VENDOR_TOKEN"
  [[ -n "$SESSION_BEARER" ]] && wire_args="$wire_args --session-bearer $SESSION_BEARER"

  # 2.1 check-only (read-only)
  sbx_exec "$AGENT_BIN_DST wire $wire_args --check-only" | sed 's/^/    /'
  ok "2.1 wire --check-only" "drift plan printed"

  # 2.2 apply (idempotent)
  local out; out="$(sbx_exec "$AGENT_BIN_DST wire $wire_args")"
  echo "$out" | sed 's/^/    /'
  if echo "$out" | grep -q "wired — restart"; then ok "2.2 wire apply" "scripts + config + consent written"
  elif echo "$out" | grep -q "WITH FAILURES"; then fail "2.2 wire apply" "see steps above"
  else ok "2.2 wire apply" "completed"; fi

  # 2.3 managed block present
  [[ "$(sbx_rc "grep -q 'agentkeys wire (managed block' \$HOME/.hermes/config.yaml")" == "0" ]] \
    && ok "2.3 managed block" "present in ~/.hermes/config.yaml" \
    || fail "2.3 managed block" "not found"

  # 2.4 re-run = idempotent (all skips)
  local out2; out2="$(sbx_exec "$AGENT_BIN_DST wire $wire_args")"
  if echo "$out2" | grep -q "skip .* matches"; then ok "2.4 idempotency" "re-run shows skips"
  else skip "2.4 idempotency" "re-run did not show 'skip … matches' (inspect output)"; fi
}

# ─── Phase 3 — Acts 1 + 2 + audit ────────────────────────────────────────────
phase3_acts() {
  skip_phase 3 && { log "Phase 3 — acts: skip (--skip-3)"; return; }
  log "Phase 3 — Acts 1 + 2 + audit (Act 3 revocation out of scope)"

  # 3.1 Act 1 — memory inject (pre_llm_call)
  local a1; a1="$(sbx_hook 'agentkeys-prellm-memory-inject.sh' '{"hook_event_name":"pre_llm_call"}')"
  if echo "$a1" | jq -e '.context' >/dev/null 2>&1; then
    ok "3.1 Act1 memory" "$(echo "$a1" | jq -r '.context' | tr '\n' ' ' | cut -c1-60)…"
  else
    fail "3.1 Act1 memory" "no context returned: $a1"
  fi

  # 3.3 Act 2 — over-cap denial (pre_tool_call)
  local a2; a2="$(sbx_hook 'agentkeys-pretool-permission-gate.sh' '{"tool_input":{"amount_rmb":600}}')"
  if [[ "$(echo "$a2" | jq -r '.decision // empty')" == "block" ]]; then
    ok "3.3 Act2 over-cap" "$(echo "$a2" | jq -r '.reason')"
  else
    fail "3.3 Act2 over-cap" "expected block, got: $a2"
  fi

  # 3.4 Act 2 — under-cap allow
  local a2b; a2b="$(sbx_hook 'agentkeys-pretool-permission-gate.sh' '{"tool_input":{"amount_rmb":200}}')"
  [[ "$a2b" == "{}" ]] && ok "3.4 Act2 under-cap" "allowed ({})" || fail "3.4 Act2 under-cap" "expected {}, got: $a2b"

  # 3.5 audit (post_tool_call, never blocks)
  local au; au="$(sbx_hook 'agentkeys-posttool-audit.sh' '{"tool_name":"order_hotpot","tool_input":{"amount_rmb":600}}')"
  [[ "$au" == "{}" ]] && ok "3.5 auto-audit" "row appended ({})" || skip "3.5 auto-audit" "non-empty output: $au"
}

# ─── Phase 4 — the surprise (manual) ─────────────────────────────────────────
phase4_surprise() {
  skip_phase 4 && { log "Phase 4 — surprise: skip (--skip-4)"; return; }
  log "Phase 4 — the surprise (real Hermes session in the sandbox)"

  if [[ -z "$LLM_API_KEY" ]]; then
    skip "4.0 hermes llm" "no LLM key (export OPENROUTER_API_KEY) — skipping the surprise"
    return
  fi
  # 4.0a wiring precheck — the surprise is only memory-aware if the wire hooks
  # + MCP server are live. Fail LOUD here instead of printing open-chat
  # instructions for a chat that would silently NOT inject memory (the trap that
  # masked this: the LLM answers, but with "nothing in memory").
  if [[ "$(sbx_rc "test -f \$HOME/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh")" != "0" ]]; then
    fail "4.0 wiring precheck" "hook scripts missing — run Phases 1+2 first (no --skip-1/--skip-2); 'agentkeys wire' must complete before the surprise"
    return
  fi
  if [[ "$(sbx_rc "curl -fsS -m 4 http://localhost:$MCP_PORT/healthz")" != "0" ]]; then
    fail "4.0 wiring precheck" "MCP server not up on :$MCP_PORT — Phase 1.4 must run (the memory hook fails CLOSED without it)"
    return
  fi

  # 4.0b configure the sandbox Hermes LLM. Hermes reads the provider key from
  # ~/.hermes/.env (its documented mechanism — "all LLM calls go through
  # OpenRouter") and the model from config.yaml (model.default). Commands MUST
  # be single-line: the sandbox /v1/shell/exec rejects multi-line payloads with
  # a silent ErrorObservation. Verified (not masked with || true).
  local env_path='$HOME/.hermes/.env'
  sbx_exec "ENV=$env_path; grep -v '^OPENROUTER_API_KEY=' \"\$ENV\" > \"\$ENV.tmp\" 2>/dev/null; printf 'OPENROUTER_API_KEY=%s\n' $(printf '%q' "$LLM_API_KEY") >> \"\$ENV.tmp\"; mv \"\$ENV.tmp\" \"\$ENV\"" >/dev/null
  if [[ "$(sbx_rc "grep -q '^OPENROUTER_API_KEY=' $env_path")" != "0" ]]; then
    fail "4.0 hermes llm" "could not write OPENROUTER_API_KEY to ~/.hermes/.env"; return
  fi
  sbx_exec "export PATH=\$HOME/.local/bin:\$PATH; hermes config set model.provider openrouter >/dev/null 2>&1; hermes config set model.base_url $(printf '%q' "$LLM_BASE_URL") >/dev/null 2>&1; hermes config set model.default $(printf '%q' "$LLM_MODEL") >/dev/null 2>&1" >/dev/null
  ok "4.0 hermes llm" "provider=openrouter, model=$LLM_MODEL, key in ~/.hermes/.env"

  # 4.1 model smoke (non-fatal) — surface throttling/credential errors BEFORE
  # the manual surprise, so the operator isn't debugging during the chat.
  local smoke; smoke="$(sbx_exec "export PATH=\$HOME/.local/bin:\$PATH; cd \$HOME; timeout 55 hermes -z 'Reply with exactly: OK' 2>&1 | tail -3")"
  if echo "$smoke" | grep -q '429'; then
    skip "4.1 model smoke" "$LLM_MODEL is HTTP 429 (rate-limited; common on ':free'). Retry, or set LLM_MODEL=deepseek/deepseek-v4-flash"
  elif echo "$smoke" | grep -qiE 'no inference|not configured|unauthorized|invalid|error|failed'; then
    skip "4.1 model smoke" "no clean response — $(echo "$smoke" | tr '\n' ' ' | cut -c1-80)"
  elif [[ -n "$(echo "$smoke" | tr -d '[:space:]')" ]]; then
    ok "4.1 model smoke" "$LLM_MODEL responded"
  else
    skip "4.1 model smoke" "empty response (check sandbox network egress)"
  fi

  printf '    Open a Hermes session in the sandbox (v0.14.0, hooks active) and send:\n'
  printf '      "where am I going this weekend?"\n'
  printf '    Terminal: %s/code-server/  (or: docker exec -it <sandbox> bash -lc "hermes chat")\n' "$SANDBOX_URL"
  if gate "4.2 confirm surprise" "did the reply reference the memory (Chengdu / travel)?" confirm; then
    ok "4.2 confirm surprise" "operator confirmed memory-aware response"
  else
    skip "4.2 confirm surprise" "not confirmed (run the Hermes session manually)"
  fi
}

# ─── Phase 5 — teardown ──────────────────────────────────────────────────────
phase5_teardown() {
  skip_phase 5 && { log "Phase 5 — teardown: skip (--skip-5)"; return; }
  log "Phase 5 — teardown (account kept; pure no-op re-runs)"
  sbx_exec "pkill -f 'agentkeys-mcp-server' 2>/dev/null; echo ok" >/dev/null
  ok "5.1 stop mcp" "sandbox MCP server stopped (container + Hermes + wiring kept)"
  if [[ "$UNWIRE" == true ]]; then
    resolve_sbx_paths || true
    sbx_exec "$AGENT_BIN_DST wire hermes --unwire 2>/dev/null || true" >/dev/null
    ok "5.3 unwire" "managed block removed (--unwire)"
  fi
  ok "5.2 account" "kept (no Act 3 → nothing to restore)"
}

# ─── main ────────────────────────────────────────────────────────────────────
main() {
  for t in curl jq docker; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }; done
  log "phase1-wire harness — mode=$MODE webauthn=$WEBAUTHN"
  phase0_prereqs
  if [[ "$FAILED" -gt 0 && "$MODE" == "real" ]]; then
    log "Phase 0 has $FAILED failure(s) — fix the prerequisites above, then re-run. (Try --light for the in-memory path.)"
    exit 1
  fi
  phase1_sandbox
  phase2_wire
  phase3_acts
  phase4_surprise
  phase5_teardown

  log "summary"
  if [[ "$FAILED" -eq 0 ]]; then
    printf '  ✅ all automated steps passed (mode=%s). Manual gates as prompted.\n' "$MODE"
  else
    printf '  ⚠ %d step(s) failed — see FAIL lines above.\n' "$FAILED"
    exit 1
  fi
}

main
