#!/usr/bin/env bash
# AgentKeys Heima chain setup — single idempotent entry point.
#
# Bootstraps the operator's Heima chain state end-to-end:
#   1. Tool sanity-check
#   2. Source operator-workstation.env
#   3. Chain reachability + chain_id sanity-check
#   4. Generate/reuse deployer key
#   5. Fund deployer (sudo on paseo; balance-check on mainnet)
#   6. Deploy stage-1 contracts (P256Verifier + K11Verifier +
#      SidecarRegistry + AgentKeysScope + K3EpochCounter + CredentialAudit)
#   7. Persist contract addresses to operator-workstation.env
#   8. Verify contracts on-chain (read-only RPC checks)
#   9. Register operator master device (first-master bootstrap)
#  10. K11 enrollment (stub or --webauthn)
#  11. Create demo agent device
#  12. Set scope (if --webauthn — else skipped)
#  13. Append a smoke-test audit row (V1 path)
#  14. Tier-A audit relay + worker /healthz smoke
#  15. Summary
#
# Per CLAUDE.md "Heima chain (single entry point)" + "Idempotent
# remote-setup rule": every step pre-checks chain/AWS state and short-
# circuits when the op is already a no-op. The script delegates to the
# existing per-action helpers (heima-bring-up.sh, heima-device-register.sh,
# heima-agent-create.sh, heima-scope-set.sh, heima-credential-audit.sh,
# heima-worker-smoke.sh) — those helpers stay callable directly for
# surgical re-runs; this script is the end-to-end orchestrator.
#
# Usage:
#   AWS_PROFILE=agentkeys-admin bash scripts/setup-heima.sh [flags]
#
# Default chain: heima mainnet (chain_id 212013). Override with --chain.
#
# Flags (each step also accepts a --skip-N for selective re-runs):
#   --chain <name>          heima (default) | heima-paseo | anvil
#   --session-id <id>       operator session label (default: alice)
#   --agent-label <label>   demo agent name (default: demo-agent)
#   --webauthn              use real Touch ID K11 (else stub)
#   --service <name>        smoke-test service (default: openrouter)
#   --from-step N           start at step N (skip 1..N-1)
#   --to-step N             stop after step N
#   --only-step N           run exactly step N
#   --yes                   non-interactive (don't pause before destructive)
#   --help                  this message + exit
#
# Idempotency claims (per CLAUDE.md table):
#   - Step 6 (deploy): `cast code` on every claimed address; skip when present
#   - Step 9 (register master): `getDevice.registeredAt > 0` check
#   - Step 11 (agent create): `getDevice.registeredAt > 0` check
#   - Step 12 (scope set): `getScope` config-equality check
#   - Step 13 (audit append): INTENTIONALLY append-only — re-runs add a
#     fresh row + advance entryCount (called out per the rule).
#   - Step 14 (worker smoke): worker /healthz + tier-A appendRoot (also
#     intentionally append-only per CLAUDE.md).

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ENV_FILE drives BOTH the idempotency read (existing *_HEIMA addresses)
# AND the persist write (step 7's env_set inside heima-bring-up.sh).
# Precedence (resolved after CLI parse below):
#   1. --env-file <path>      (CLI flag, highest priority)
#   2. $ENV_FILE env var      (inherited from caller — e.g. ci-setup.md recipe)
#   3. --test → operator-workstation.test.env  (ergonomic shorthand)
#   4. operator-workstation.env  (prod default)
# Snapshot the caller-supplied env-var value so the CLI parser can detect it.
ENV_FILE_FROM_ENV="${ENV_FILE:-}"
unset ENV_FILE

EXPLICIT_ENV_FILE=""
TEST_MODE=0
AGENTKEYS_CHAIN_ARG=""
SESSION_ID="${SESSION_ID:-alice}"
AGENT_LABEL="demo-agent"
SMOKE_SERVICE="openrouter"
USE_WEBAUTHN=0
YES=0
FROM_STEP=1
TO_STEP=15
STEP_TOTAL=15

# Colors only when stderr is a TTY.
if [ -t 2 ]; then
  COLOR_OK='\033[32m'; COLOR_WARN='\033[33m'; COLOR_FAIL='\033[31m'
  COLOR_HEAD='\033[1m'; COLOR_RESET='\033[0m'
else
  COLOR_OK=''; COLOR_WARN=''; COLOR_FAIL=''; COLOR_HEAD=''; COLOR_RESET=''
fi

# ─── CLI parse ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --chain)        AGENTKEYS_CHAIN_ARG="$2"; shift 2 ;;
    --session-id)   SESSION_ID="$2"; shift 2 ;;
    --agent-label)  AGENT_LABEL="$2"; shift 2 ;;
    --service)      SMOKE_SERVICE="$2"; shift 2 ;;
    --webauthn)     USE_WEBAUTHN=1; shift ;;
    --yes)          YES=1; shift ;;
    --from-step)    FROM_STEP="$2"; shift 2 ;;
    --to-step)      TO_STEP="$2"; shift 2 ;;
    --only-step)    FROM_STEP="$2"; TO_STEP="$2"; shift 2 ;;
    --env-file)     EXPLICIT_ENV_FILE="$2"; shift 2 ;;
    --env-file=*)   EXPLICIT_ENV_FILE="${1#*=}"; shift ;;
    --ci|--test)    TEST_MODE=1; shift ;;   # --ci = canonical CI-env flag; --test retained as alias
    --help|-h)
      sed -n '2,55p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "Unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# Resolve ENV_FILE per documented precedence.
if [ -n "$EXPLICIT_ENV_FILE" ]; then
  ENV_FILE="$EXPLICIT_ENV_FILE"
elif [ -n "$ENV_FILE_FROM_ENV" ]; then
  ENV_FILE="$ENV_FILE_FROM_ENV"
elif [ "$TEST_MODE" = "1" ]; then
  ENV_FILE="$SCRIPT_DIR/operator-workstation.test.env"
else
  ENV_FILE="$SCRIPT_DIR/operator-workstation.env"
fi
# Critical: export so heima-bring-up.sh + verify-heima-contracts.sh inherit
# the SAME env file. Otherwise step 6 reads prod addresses for idempotency
# check (skip-already-deployed fires against prod state) AND step 7 writes
# the freshly-deployed test addresses back to the prod env file (clobbers
# the live broker's contract pointers).
export ENV_FILE

if [ -n "$AGENTKEYS_CHAIN_ARG" ]; then
  export AGENTKEYS_CHAIN="$AGENTKEYS_CHAIN_ARG"
fi
: "${AGENTKEYS_CHAIN:=heima}"
export AGENTKEYS_CHAIN

# ─── Helpers ──────────────────────────────────────────────────────────────────
step() { printf "${COLOR_HEAD}==> [step %d/%d] %s${COLOR_RESET}\n" "$CUR_STEP" "$STEP_TOTAL" "$1" >&2; }
ok()   { printf "    ${COLOR_OK}ok    %s${COLOR_RESET}\n" "$1" >&2; }
warn() { printf "    ${COLOR_WARN}warn  %s${COLOR_RESET}\n" "$1" >&2; }
fail() { printf "    ${COLOR_FAIL}fail  %s${COLOR_RESET}\n" "$1" >&2; }
skip() { printf "    ${COLOR_WARN}skip  %s${COLOR_RESET}\n" "$1" >&2; }
die()  { fail "$1"; exit 1; }

in_scope() {
  [ "$1" -ge "$FROM_STEP" ] && [ "$1" -le "$TO_STEP" ]
}

# Resolve agentkeys binary per CLAUDE.md rule 6 (workspace-local before PATH).
AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
[ ! -x "$AGENTKEYS_BIN" ] && AGENTKEYS_BIN="$REPO_ROOT/target/debug/agentkeys"
[ ! -x "$AGENTKEYS_BIN" ] && AGENTKEYS_BIN="$(command -v agentkeys || true)"

# ─── Run steps ────────────────────────────────────────────────────────────────
# Env-file banner — surfaces test-vs-prod isolation upfront so the operator
# can't miss a prod-env-file run that would clobber prod's *_HEIMA addresses
# (or silently short-circuit a test deploy via prod's idempotency cache).
ENV_BASENAME="$(basename "$ENV_FILE")"
if [ "$TEST_MODE" = "1" ] || [[ "$ENV_BASENAME" == *test* ]]; then
  STACK_LABEL="${COLOR_WARN}TEST${COLOR_RESET}"
else
  STACK_LABEL="${COLOR_OK}PROD${COLOR_RESET}"
fi
printf "${COLOR_HEAD}=== AgentKeys Heima setup: chain=%s session=%s ===${COLOR_RESET}\n" \
  "$AGENTKEYS_CHAIN" "$SESSION_ID" >&2
printf "  stack:    %b\n" "$STACK_LABEL" >&2
printf "  env_file: %s\n" "$ENV_FILE" >&2
printf "  steps %d..%d (of %d)\n\n" "$FROM_STEP" "$TO_STEP" "$STEP_TOTAL" >&2

do_step_1() {
  CUR_STEP=1; step "Tool sanity-check"
  local missing=()
  for tool in jq curl awk sed grep aws cast forge node npx python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [ "${#missing[@]}" -gt 0 ] && die "missing tools: ${missing[*]}"
  [ -x "$AGENTKEYS_BIN" ] || die "agentkeys binary not found — run \`cargo build --release -p agentkeys-cli\`"
  ok "tools present; agentkeys: $AGENTKEYS_BIN"
}

do_step_2() {
  CUR_STEP=2; step "Source operator-workstation.env"
  [ -f "$ENV_FILE" ] || die "missing $ENV_FILE — see docs/cloud-setup.md"
  set -a; . "$ENV_FILE"; set +a
  : "${REGION:?REGION missing from operator-workstation.env}"
  ok "env sourced — REGION=$REGION"
}

do_step_3() {
  CUR_STEP=3; step "Chain reachability + chain_id sanity-check"
  local rpc claimed_chain_id live_chain_id
  rpc=$("$AGENTKEYS_BIN" chain show "$AGENTKEYS_CHAIN" | jq -r .rpc.http)
  claimed_chain_id=$("$AGENTKEYS_BIN" chain show "$AGENTKEYS_CHAIN" | jq -r .chain_id)
  live_chain_id=$(curl -sS -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$rpc" \
    | jq -r '.result' | python3 -c "import sys; print(int(sys.stdin.read().strip(), 16))")
  [ "$claimed_chain_id" = "$live_chain_id" ] || \
    die "chain mismatch: profile says chain_id=$claimed_chain_id but RPC reports $live_chain_id"
  ok "$AGENTKEYS_CHAIN reachable at $rpc (chain_id=$live_chain_id)"
}

do_step_4() {
  CUR_STEP=4; step "Generate/reuse deployer key"
  # Path precedence:
  #   1. HEIMA_DEPLOYER_KEY_FILE env override   (CI / test instance)
  #   2. $HOME/.agentkeys/${AGENTKEYS_CHAIN}-deployer.key  (default)
  #
  # The override lets the test instance use a SEPARATE deployer wallet on
  # the same Heima mainnet — different (deployer, nonce) → different
  # contract addresses on the same chain → isolated test contract set.
  # Without this override, AGENTKEYS_CHAIN=heima always picks up the prod
  # key, the cast-code idempotency check sees prod contracts already
  # exist, and step 6 short-circuits with no new deploy.
  local key_path="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/${AGENTKEYS_CHAIN}-deployer.key}"
  export HEIMA_DEPLOYER_KEY_FILE="$key_path"   # propagate to heima-*.sh helpers
  if [ -f "$key_path" ]; then
    skip "deployer key already exists at $key_path"
  else
    # Delegate to bring-up's key gen (it persists to the same path the
    # env var points at via the same HEIMA_DEPLOYER_KEY_FILE export).
    bash "$SCRIPT_DIR/heima-bring-up.sh" --only-step gen-key 2>/dev/null || true
    [ -f "$key_path" ] || die "deployer key generation failed — see heima-bring-up.sh; or pre-create with: cast wallet new --json | jq -r .[0].private_key > $key_path && chmod 600 $key_path"
    ok "deployer key generated at $key_path"
  fi
}

do_step_5() {
  CUR_STEP=5; step "Fund deployer (sudo on paseo; balance-check on mainnet)"
  # Delegate to heima-bring-up.sh's canonical fund step:
  #   - paseo: Alice sudo auto-tops-up the deployer
  #   - mainnet: balance-check; if low, prints fund-from-personal-wallet
  #     instructions and exits non-zero (NEVER auto-spends real HEI).
  # SKIP_DEPLOY=1 stops bring-up after the fund step so this orchestrator's
  # do_step_6 owns the deploy invocation (avoids double-deploy).
  # Do NOT call heima-fund-account.sh here — that script sends FROM the
  # deployer (used to bootstrap agent wallets), not TO the deployer.
  if [ "$YES" = "1" ]; then
    SKIP_DEPLOY=1 bash "$SCRIPT_DIR/heima-bring-up.sh" --yes
  else
    SKIP_DEPLOY=1 bash "$SCRIPT_DIR/heima-bring-up.sh"
  fi
}

do_step_6() {
  CUR_STEP=6; step "Deploy stage-1 contracts (idempotent — skip if already on-chain)"
  # heima-bring-up.sh checks `cast code` on every claimed address before deploying.
  if [ "$YES" = "1" ]; then
    bash "$SCRIPT_DIR/heima-bring-up.sh" --yes
  else
    bash "$SCRIPT_DIR/heima-bring-up.sh"
  fi
}

do_step_7() {
  CUR_STEP=7; step "Persist contract addresses (handled inside heima-bring-up)"
  ok "operator-workstation.env updated by heima-bring-up if needed"
}

do_step_8() {
  CUR_STEP=8; step "Verify contracts on-chain (read-only RPC)"
  AGENTKEYS_CHAIN="$AGENTKEYS_CHAIN" bash "$SCRIPT_DIR/verify-heima-contracts.sh"
}

do_step_9() {
  CUR_STEP=9; step "Register operator master device (idempotent)"
  bash "$SCRIPT_DIR/heima-device-register.sh" --session-id "$SESSION_ID"
}

do_step_10() {
  CUR_STEP=10; step "K11 enrollment ($([ "$USE_WEBAUTHN" = "1" ] && echo --webauthn || echo stub))"
  local session_file="$HOME/.agentkeys/$SESSION_ID/session.json"
  [ -f "$session_file" ] || die "missing session — run \`agentkeys init --session-id $SESSION_ID --email ...\` first"
  local omni
  omni=$(jq -r .agentkeys.actor_omni "$session_file" 2>/dev/null || jq -r .actor_omni "$session_file")
  local k11_file="$HOME/.agentkeys/k11/${omni#0x}.json"
  if [ -f "$k11_file" ]; then
    skip "K11 already enrolled at $k11_file"
    return
  fi
  if [ "$USE_WEBAUTHN" = "1" ]; then
    "$AGENTKEYS_BIN" k11 enroll --webauthn --operator-omni "0x${omni#0x}"
  else
    [ "$AGENTKEYS_CHAIN" = "heima" ] && [ "${AGENTKEYS_ALLOW_STAGE1_STUBS:-0}" != "1" ] && \
      die "stub K11 on heima requires AGENTKEYS_ALLOW_STAGE1_STUBS=1 (per arch.md §22b.1)"
    "$AGENTKEYS_BIN" k11 enroll --operator-omni "0x${omni#0x}"
  fi
  ok "K11 enrolled"
}

do_step_11() {
  CUR_STEP=11; step "Create demo agent device (idempotent)"
  bash "$SCRIPT_DIR/heima-agent-create.sh" --label "$AGENT_LABEL" --session-id "$SESSION_ID"
}

do_step_12() {
  CUR_STEP=12; step "Set scope for agent (K11-gated — requires --webauthn)"
  if [ "$USE_WEBAUTHN" != "1" ]; then
    skip "scope-set needs --webauthn (real K11 ceremony); re-run with --webauthn"
    return
  fi
  bash "$SCRIPT_DIR/heima-scope-set.sh" --webauthn --agent "$AGENT_LABEL" --services "$SMOKE_SERVICE" --session-id "$SESSION_ID"
}

do_step_13() {
  CUR_STEP=13; step "Append credential audit entry (V1 — intentionally append-only)"
  bash "$SCRIPT_DIR/heima-credential-audit.sh" --actor "$AGENT_LABEL" --service "$SMOKE_SERVICE" --op store --session-id "$SESSION_ID"
}

do_step_14() {
  CUR_STEP=14; step "Tier-A audit relay + worker /healthz smoke (intentionally append-only)"
  local smoke_args=()
  [ -f "$HOME/.agentkeys/agents/${AGENT_LABEL}.json" ] && smoke_args+=(--actor "$AGENT_LABEL")
  bash "$SCRIPT_DIR/heima-worker-smoke.sh" "${smoke_args[@]}"
}

do_step_15() {
  CUR_STEP=15; step "Summary"
  local profile_uc registry_addr session_file
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  registry_addr=$(eval "echo \${SIDECAR_REGISTRY_ADDRESS_${profile_uc}:-}")
  session_file="$HOME/.agentkeys/$SESSION_ID/session.json"

  printf "\n${COLOR_OK}═══ Heima setup complete ═══${COLOR_RESET}\n\n" >&2
  printf "  chain               : %s\n"   "$AGENTKEYS_CHAIN" >&2
  printf "  session-id          : %s\n"   "$SESSION_ID" >&2
  printf "  session JWT         : %s\n"   "$session_file" >&2
  printf "  SidecarRegistry     : %s\n"   "${registry_addr:-(not deployed)}" >&2
  printf "  agent label         : %s\n"   "$AGENT_LABEL" >&2
  printf "\n  Re-run individual phases (idempotent, surgical):\n" >&2
  printf "    bash scripts/setup-heima.sh --only-step 6   # re-check deploy\n" >&2
  printf "    bash scripts/setup-heima.sh --only-step 9   # re-register master\n" >&2
  printf "    bash scripts/setup-heima.sh --only-step 14  # re-smoke workers\n" >&2
  printf "\n  Per-action helpers (still callable directly for surgical re-runs):\n" >&2
  printf "    bash scripts/heima-device-register.sh   --session-id %s\n" "$SESSION_ID" >&2
  printf "    bash scripts/heima-agent-create.sh      --label %s\n" "$AGENT_LABEL" >&2
  printf "    bash scripts/heima-scope-set.sh         --agent %s --services %s\n" "$AGENT_LABEL" "$SMOKE_SERVICE" >&2
  printf "    bash scripts/heima-credential-audit.sh  --actor %s --service %s --op store\n\n" "$AGENT_LABEL" "$SMOKE_SERVICE" >&2
}

main() {
  in_scope 1  && do_step_1
  in_scope 2  && do_step_2
  in_scope 3  && do_step_3
  in_scope 4  && do_step_4
  in_scope 5  && do_step_5
  in_scope 6  && do_step_6
  in_scope 7  && do_step_7
  in_scope 8  && do_step_8
  in_scope 9  && do_step_9
  in_scope 10 && do_step_10
  in_scope 11 && do_step_11
  in_scope 12 && do_step_12
  in_scope 13 && do_step_13
  in_scope 14 && do_step_14
  in_scope 15 && do_step_15
}

main "$@"
