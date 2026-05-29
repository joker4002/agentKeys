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
DEVICE_KEY_HASH="${AGENTKEYS_DEVICE_KEY_HASH:-}"   # Mode R: agent device key hash (from agent file) — memory.put cap-mint needs it

# ─── flags ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --light)     MODE="light"; shift ;;
    --real)      MODE="real"; shift ;;
    --webauthn)  WEBAUTHN=true; shift ;;
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
sbx_exec()  { curl -sS -X POST "$SANDBOX_URL/v1/shell/exec" -H 'content-type: application/json' \
                -d "$(jq -n --arg c "$1" '{command:$c}')" | jq -r '.data.output // ""'; }
sbx_rc()    { curl -sS -X POST "$SANDBOX_URL/v1/shell/exec" -H 'content-type: application/json' \
                -d "$(jq -n --arg c "$1" '{command:$c}')" | jq -r '.data.exit_code // 1'; }
sbx_put()   { curl -sS -X POST "$SANDBOX_URL/v1/file/upload" -F "file=@$1" -F "path=$2" \
                | jq -r '.data.file_path // "UPLOAD_FAILED"'; }
# Run one of the wired hook scripts in the sandbox against a stdin payload.
sbx_hook()  { sbx_exec "printf '%s' $(printf '%q' "$2") | bash \$HOME/.hermes/agent-hooks/$1"; }

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

  if AGENTKEYS_CHAIN=heima bash "$REPO_ROOT/scripts/verify-heima-contracts.sh" >/dev/null 2>&1; then
    ok "0.1 heima contracts" "verify-heima-contracts.sh passed"
  else
    fail "0.1 heima contracts" "verify-heima-contracts.sh failed — run scripts/setup-heima.sh"
  fi

  local broker="${BACKEND_URL:-${AGENTKEYS_BROKER_URL:-}}"
  if [[ -n "$broker" ]] && curl -fsS "${broker%/}/healthz" >/dev/null 2>&1; then
    ok "0.2 broker healthz" "$broker"
  else
    fail "0.2 broker healthz" "broker not reachable (BACKEND_URL=$broker) — run scripts/setup-broker-host.sh"
  fi

  # Resolve actor_omni + operator_omni (flag/env → agent file → guidance).
  # heima-agent-create.sh writes BOTH into the agent file.
  if [[ -z "$ACTOR_OMNI" && -f "$AGENT_FILE" ]]; then
    ACTOR_OMNI="$(jq -r '.actor_omni // empty' "$AGENT_FILE" 2>/dev/null)"
  fi
  if [[ -z "$OPERATOR_OMNI" && -f "$AGENT_FILE" ]]; then
    OPERATOR_OMNI="$(jq -r '.operator_omni // empty' "$AGENT_FILE" 2>/dev/null)"
  fi
  if [[ -z "$DEVICE_KEY_HASH" && -f "$AGENT_FILE" ]]; then
    DEVICE_KEY_HASH="$(jq -r '.device_key_hash // empty' "$AGENT_FILE" 2>/dev/null)"
  fi
  if [[ -n "$ACTOR_OMNI" ]]; then ok "0.4 agent actor_omni" "${ACTOR_OMNI:0:14}…"
  else fail "0.4 agent actor_omni" "unknown — pass --actor-omni / AGENTKEYS_ACTOR_OMNI, or run heima-agent-create.sh (--agent-file $AGENT_FILE)"; fi
  if [[ -n "$OPERATOR_OMNI" ]]; then ok "0.3 operator_omni" "${OPERATOR_OMNI:0:14}… (from agent file)"
  else fail "0.3 operator_omni" "unknown — set .operator_omni in $AGENT_FILE, or pass --operator-omni / AGENTKEYS_OPERATOR_OMNI"; fi

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

  # 0.7 session bearer — flag/env → master session file (.token) → guidance.
  # arch.md §22b.4: cap-mint to the broker authenticates with the session JWT.
  local sess_file="${MASTER_SESSION_FILE:-$HOME/.agentkeys/$SESSION_ID/session.json}"
  if [[ -z "$SESSION_BEARER" && -f "$sess_file" ]]; then
    SESSION_BEARER="$(jq -r '.token // empty' "$sess_file" 2>/dev/null)"
    local ca tl now
    ca="$(jq -r '.created_at // 0' "$sess_file" 2>/dev/null)"
    tl="$(jq -r '.ttl_seconds // 0' "$sess_file" 2>/dev/null)"
    now="$(date +%s)"
    if [[ "$ca" =~ ^[0-9]+$ && "$tl" =~ ^[0-9]+$ && "$tl" -gt 0 && $((ca + tl)) -lt "$now" ]]; then
      log "  0.7 session bearer: WARNING — the '$SESSION_ID' session looks expired (created+ttl < now). If cap-mint 401s, refresh with 'agentkeys init --session-id $SESSION_ID …'."
    fi
  fi
  if [[ -n "$SESSION_BEARER" ]]; then
    ok "0.7 session bearer" "from '$SESSION_ID' session (${#SESSION_BEARER} chars)"
  else
    fail "0.7 session bearer" "no session JWT — run 'agentkeys init --session-id $SESSION_ID …' (master), or pass AGENTKEYS_SESSION_BEARER. Required for real-broker cap-mint."
  fi
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

  # 1.4 MCP server in the sandbox (detached). Idempotent + mode/token-aware:
  # a server already on :MCP_PORT is REUSED only when its --backend AND
  # --vendor-tokens match THIS run's intent. A mismatched server — a leftover
  # real-mode server when we asked for --light, or a stale token — is killed and
  # restarted; otherwise the wired hook's token won't match the server and every
  # memory.get/permission.check 401s ("bearer token not recognized"). Also
  # restart when a fresh binary was just uploaded.
  local mcp_backend mcp_vendor cmd
  if [[ "$MODE" == "light" ]]; then
    mcp_backend="in-memory"; mcp_vendor="magiclick:$VENDOR_TOKEN"
    cmd="$MCP_BIN_DST --backend in-memory --transport http --listen 127.0.0.1:$MCP_PORT --vendor-tokens $mcp_vendor"
  else
    mcp_backend="http"; mcp_vendor="harness:$VENDOR_TOKEN"
    cmd="$MCP_BIN_DST --backend http --transport http --listen 127.0.0.1:$MCP_PORT --vendor-tokens $mcp_vendor --broker-url ${BACKEND_URL:-} --memory-url ${AGENTKEYS_WORKER_MEMORY_URL:-} --audit-url ${AGENTKEYS_WORKER_AUDIT_URL:-} --default-actor $ACTOR_OMNI --default-operator-omni $OPERATOR_OMNI --default-device-key-hash $DEVICE_KEY_HASH"
  fi
  # Reuse only if a live server's argv carries BOTH the intended backend + token.
  local reuse=false
  if [[ "$mcp_bin_changed" != true \
        && "$(sbx_rc "curl -fsS http://localhost:$MCP_PORT/healthz")" == "0" \
        && -n "$(sbx_exec "pgrep -af agentkeys-mcp-server | grep -F -- '--backend $mcp_backend' | grep -F -- '--vendor-tokens $mcp_vendor'")" ]]; then
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
    local got; got="$(sbx_exec "$env_pfx $AGENT_BIN_DST hook memory-inject --namespaces $MEMORY_NS 2>/dev/null")"
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
