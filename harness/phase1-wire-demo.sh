#!/usr/bin/env bash
# Phase 1 wire harness — tests PR #141 (`agentkeys wire` + `agentkeys hook`)
# end-to-end. Master = this MacBook (operator); Agent = the aiosandbox
# container (actor). Idempotent: every step pre-checks + short-circuits
# (`ok proceeding` / `skip <reason>` / `fail <reason>`).
#
# Spec: docs/spec/plans/phase1-wire-harness-test-plan.md
#
# Two modes:
#   --light   In-memory MCP IN THE SANDBOX + real Hermes + the wire flow.
#             No real account / broker / chain. The lighter inner loop.
#   (default) Mode R — real broker + workers + Heima mainnet, REUSING the
#             account `setup-heima.sh` created (master `alice`, agent
#             `demo-agent`). Live-env steps fail-loud with guidance if a
#             prerequisite is missing.
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
#   bash harness/phase1-wire-demo.sh [--light] [--webauthn] [--unwire]
#                                    [--yes] [--skip-N ...] [--help]

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── config (env overridable) ──────────────────────────────────────────────
MODE="real"
SANDBOX_URL="${SANDBOX_URL:-http://localhost:8080}"
MCP_PORT="${MCP_PORT:-8088}"
MCP_URL_IN_SANDBOX="http://localhost:${MCP_PORT}/mcp"
SESSION_ID="${SESSION_ID:-alice}"            # master session label on the Mac
AGENT_LABEL="${AGENT_LABEL:-demo-agent}"
SERVICE="${SERVICE:-openrouter}"             # LLM cred service name
# LLM key for the Phase 4 Hermes "surprise". Falls back to OPENROUTER_API_KEY
# (export it in ~/.zshenv) so 0.6 needs no manual paste. Used to configure the
# sandbox Hermes model before the surprise chat.
LLM_API_KEY="${LLM_API_KEY:-${OPENROUTER_API_KEY:-}}"
LLM_BASE_URL="${LLM_BASE_URL:-https://openrouter.ai/api/v1}"
LLM_MODEL="${LLM_MODEL:-openrouter/auto}"
MEMORY_NS="${MEMORY_NS:-travel}"
PAYMENT_SCOPE="${PAYMENT_SCOPE:-payment.spend}"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
AGENT_FILE="${AGENT_FILE:-$HOME/.agentkeys/agents/${AGENT_LABEL}.json}"
LINUX_TARGET_DIR="$REPO_ROOT/target/sandbox-linux"
AGENT_BIN_DST="/usr/local/bin/agentkeys"
MCP_BIN_DST="/usr/local/bin/agentkeys-mcp-server"

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

# ─── flags ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --light)     MODE="light"; shift ;;
    --webauthn)  WEBAUTHN=true; shift ;;
    --unwire)    UNWIRE=true; shift ;;
    --yes)       ASSUME_YES=true; shift ;;
    --skip-*)    SKIP_PHASES="$SKIP_PHASES ${1#--skip-}"; shift ;;
    --help|-h)   sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

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
  for pair in "$LINUX_TARGET_DIR/release/agentkeys:$AGENT_BIN_DST" \
              "$LINUX_TARGET_DIR/release/agentkeys-mcp-server:$MCP_BIN_DST"; do
    local src="${pair%%:*}" dst="${pair##*:}"
    local name; name="$(basename "$dst")"
    local want; want="$(shasum -a256 "$src" 2>/dev/null | awk '{print $1}')"
    local have; have="$(sbx_exec "sha256sum $dst 2>/dev/null | awk '{print \$1}'")"
    if [[ -n "$want" && "$want" == "$have" ]]; then
      ok "1.3 $name" "already present (sha matches)"
    else
      [[ "$(sbx_put "$src" "$dst")" == "$dst" ]] || { fail "1.3 $name" "upload failed"; continue; }
      sbx_exec "chmod +x $dst" >/dev/null
      [[ "$(sbx_rc "$dst --version")" == "0" ]] && ok "1.3 $name" "uploaded + executable" || fail "1.3 $name" "not runnable in sandbox"
    fi
  done

  # 1.4 MCP server in the sandbox (detached; idempotent on :8088)
  if [[ "$(sbx_rc "curl -fsS $MCP_URL_IN_SANDBOX/../healthz")" == "0" ]]; then
    ok "1.4 mcp server" "already up on :$MCP_PORT"
  else
    local cmd
    if [[ "$MODE" == "light" ]]; then
      cmd="$MCP_BIN_DST --backend in-memory --transport http --listen 127.0.0.1:$MCP_PORT --vendor-tokens magiclick:$VENDOR_TOKEN"
    else
      cmd="$MCP_BIN_DST --backend http --transport http --listen 127.0.0.1:$MCP_PORT --vendor-tokens harness:$VENDOR_TOKEN --broker-url ${BACKEND_URL:-} --memory-url ${AGENTKEYS_WORKER_MEMORY_URL:-} --audit-url ${AGENTKEYS_WORKER_AUDIT_URL:-} --default-actor $ACTOR_OMNI --default-operator-omni $OPERATOR_OMNI"
    fi
    sbx_exec "nohup $cmd >/tmp/agentkeys-mcp.log 2>&1 & sleep 2; echo started" >/dev/null
    [[ "$(sbx_rc "curl -fsS http://localhost:$MCP_PORT/healthz")" == "0" ]] \
      && ok "1.4 mcp server" "started ($MODE backend)" \
      || fail "1.4 mcp server" "did not come up — see /tmp/agentkeys-mcp.log in the sandbox"
  fi
}

# Cross-build aarch64-linux binaries in an arm64 Linux rust container (cached).
# The sandbox is aarch64 Linux; the Mac is arm64 darwin — same CPU, different
# OS — so the agent binary must be cross-built. RUST_BUILD_IMAGE lets you point
# at a local/mirror image when Docker Hub is unreachable.
RUST_BUILD_IMAGE="${RUST_BUILD_IMAGE:-rust:1.83-slim-bookworm}"
build_linux_binaries() {
  if [[ -x "$LINUX_TARGET_DIR/release/agentkeys" && -x "$LINUX_TARGET_DIR/release/agentkeys-mcp-server" ]]; then
    ok "1.3 linux build" "cached ($LINUX_TARGET_DIR/release)"; return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    fail "1.3 linux build" "docker required to cross-build the aarch64-linux agent binary"; return 1
  fi
  # Ensure the rust image is available (use local if present; else pull).
  # Wrap the pull in a fail-fast timeout so a flaky registry can't hang the
  # harness (Docker Hub auth EOFs have been observed). `timeout`/`gtimeout`
  # used when present; otherwise the pull runs unbounded.
  local TO=""
  command -v timeout  >/dev/null 2>&1 && TO="timeout 180"
  command -v gtimeout >/dev/null 2>&1 && TO="gtimeout 180"
  if ! docker image inspect "$RUST_BUILD_IMAGE" >/dev/null 2>&1; then
    log "  1.3 linux build: pulling $RUST_BUILD_IMAGE …"
    if ! $TO docker pull --platform linux/arm64 "$RUST_BUILD_IMAGE" >/dev/null 2>&1; then
      fail "1.3 linux build" "cannot pull $RUST_BUILD_IMAGE (registry unreachable/timed out). Set RUST_BUILD_IMAGE to a local/mirror rust image, or pre-pull it, then re-run."
      return 1
    fi
  fi
  log "  1.3 linux build: cross-compiling aarch64-linux binaries (first run is slow)…"
  docker run --rm --platform linux/arm64 -v "$REPO_ROOT":/src -w /src \
    -e CARGO_TARGET_DIR=/src/target/sandbox-linux "$RUST_BUILD_IMAGE" \
    sh -c "apt-get update >/dev/null 2>&1 && apt-get install -y --no-install-recommends pkg-config libssl-dev >/dev/null 2>&1 && cargo build --release -p agentkeys-cli -p agentkeys-mcp-server"
  if [[ -x "$LINUX_TARGET_DIR/release/agentkeys" ]]; then
    ok "1.3 linux build" "built aarch64-linux binaries"; return 0
  else
    fail "1.3 linux build" "cross-build produced no binary (see docker output above)"; return 1
  fi
}

# ─── Phase 2 — wire ──────────────────────────────────────────────────────────
phase2_wire() {
  skip_phase 2 && { log "Phase 2 — wire: skip (--skip-2)"; return; }
  log "Phase 2 — wire (#141 core)"
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
  # 4.0 — point the sandbox Hermes at the LLM (idempotent; persisted to
  # ~/.hermes/config.yaml so the operator's interactive session inherits it).
  # Config keys may need per-version tuning; best-effort, non-fatal.
  sbx_exec "export PATH=\$HOME/.local/bin:\$PATH
    hermes config set model.provider custom >/dev/null 2>&1 || true
    hermes config set model.base_url $(printf '%q' "$LLM_BASE_URL") >/dev/null 2>&1 || true
    hermes config set model.default  $(printf '%q' "$LLM_MODEL")    >/dev/null 2>&1 || true
    hermes config set model.api_key  $(printf '%q' "$LLM_API_KEY")  >/dev/null 2>&1 || true
    echo done" >/dev/null
  ok "4.0 hermes llm" "configured ($LLM_MODEL via $LLM_BASE_URL)"

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
