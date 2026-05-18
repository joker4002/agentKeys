#!/usr/bin/env bash
# scripts/v2-stage1-demo.sh — one-command v2 stage-1 demo end-to-end.
#
# Composes the existing scripts (install-agentkeys-cli.sh,
# agentkeys-init-email-demo.sh, heima-paseo-bring-up.sh) into a single
# idempotent flow with clear step boundaries. Each step checks "is this
# already done?" before doing the work, so re-runs are safe.
#
# Pause points (where the operator must interact):
#   - macOS keychain unlock prompt during step 5 (`agentkeys init`
#     writes the session JWT to the OS keychain). The OS modal handles
#     this naturally — no shell pause needed.
#   - Optional confirmation before chain deploy (step 8) when --confirm
#     is passed.
#
# Configuration (everything is overridable — no hardcoded values):
#
#   SESSION_ID            session label (writes ~/.agentkeys/$SESSION_ID/)
#                         default: alice
#                         override: --session-id <name>
#
#   AGENTKEYS_CHAIN       chain profile name (heima-paseo, heima, anvil, ...)
#                         default: heima-paseo (development convention)
#                         override: --chain <name>
#
#   AGENTKEYS_CHAIN_PROFILE_FILE  custom JSON profile path (overrides built-in)
#                                 default: unset; see arch.md §22a
#
#   SMOKE_TEST_SERVICE    service name used in step 7 envelope write
#                         default: openrouter
#                         override: SMOKE_TEST_SERVICE=brave-search bash ...
#
#   SMOKE_TEST_SECRET     fake credential used in step 7 envelope write
#                         default: sk-or-v1-DEMO-FAKE-DO-NOT-USE-IN-PROD
#                         override: SMOKE_TEST_SECRET=foo bash ...
#
#   FUND_AMOUNT_HEI       sudo-fund amount for the deployer (heima-paseo)
#                         default: 100
#                         override: FUND_AMOUNT_HEI=50 bash ...
#
# Step gating flags:
#
#   --from-step N         start at step N (skip steps 1..N-1)
#   --to-step N           stop after step N
#   --only-step N         run exactly step N
#   --skip-build          assume agentkeys CLI is already current
#   --skip-email          assume ~/.agentkeys/$SESSION_ID/session.json exists
#   --skip-smoke          skip the S3 envelope round-trip
#   --skip-deploy         skip the chain bring-up (contract deploy)
#   --confirm             pause for Enter before chain deploy
#   --debug               enable `set -x` (very chatty)
#   --help                this message
#
# Resumability:
#   Each step prints "[step N/M] ..." to stderr. If a step fails, re-run
#   with --from-step N to retry just that step (steps 1..N-1 are already
#   done and have idempotent skip-checks anyway).
#
# Usage examples:
#   bash scripts/v2-stage1-demo.sh                              # full demo, defaults
#   bash scripts/v2-stage1-demo.sh --session-id bob             # second tenant
#   bash scripts/v2-stage1-demo.sh --chain anvil                # local-dev backbone
#   bash scripts/v2-stage1-demo.sh --from-step 5                # skip preflight, start at email init
#   bash scripts/v2-stage1-demo.sh --only-step 7                # re-run the envelope smoke test
#   bash scripts/v2-stage1-demo.sh --skip-deploy                # everything but chain deploy
#   AGENTKEYS_CHAIN=heima bash scripts/v2-stage1-demo.sh        # mainnet (refused on step 8)

set -euo pipefail

# ─── Color helpers ──────────────────────────────────────────────────────────
if [ -t 2 ]; then
  COLOR_HEAD='\033[1;36m'   # cyan, for step headers
  COLOR_OK='\033[1;32m'     # green
  COLOR_SKIP='\033[1;33m'   # yellow
  COLOR_WARN='\033[1;33m'
  COLOR_ERR='\033[1;31m'    # red
  COLOR_DIM='\033[2m'       # dim
  COLOR_RESET='\033[0m'
else
  COLOR_HEAD='' COLOR_OK='' COLOR_SKIP='' COLOR_WARN='' COLOR_ERR='' COLOR_DIM='' COLOR_RESET=''
fi

# Bash-3.2 (macOS default) does NOT support `local -n`, so step counters
# live as plain globals.
STEP_NUM=0
STEP_TOTAL=9
CURRENT_STEP_NAME=""

step()    { STEP_NUM=$((STEP_NUM+1)); CURRENT_STEP_NAME="$1"
            printf "${COLOR_HEAD}==> [step %d/%d] %s${COLOR_RESET}\n" \
              "$STEP_NUM" "$STEP_TOTAL" "$1" >&2 ; }
ok()      { printf "    ${COLOR_OK}ok${COLOR_RESET}    %s\n" "$1" >&2 ; }
info()    { printf "    ${COLOR_DIM}info${COLOR_RESET}  %s\n" "$1" >&2 ; }
skip()    { printf "    ${COLOR_SKIP}skip${COLOR_RESET}  %s\n" "$1" >&2 ; }
warn()    { printf "    ${COLOR_WARN}warn${COLOR_RESET}  %s\n" "$1" >&2 ; }
die()     { printf "    ${COLOR_ERR}fail${COLOR_RESET}  %s\n" "$1" >&2
            if [ "$STEP_NUM" -gt 0 ]; then
              printf "          (failed during step %d/%d: %s)\n" \
                "$STEP_NUM" "$STEP_TOTAL" "$CURRENT_STEP_NAME" >&2
              printf "          retry just this step: bash scripts/v2-stage1-demo.sh --only-step %d\n" \
                "$STEP_NUM" >&2
            fi
            exit 1 ; }

# ─── Default config (overridable via env or flags) ──────────────────────────
SESSION_ID_DEFAULT="alice"
SMOKE_TEST_SERVICE_DEFAULT="openrouter"
SMOKE_TEST_SECRET_DEFAULT="sk-or-v1-DEMO-FAKE-DO-NOT-USE-IN-PROD"

SESSION_ID="${SESSION_ID:-$SESSION_ID_DEFAULT}"
SMOKE_TEST_SERVICE="${SMOKE_TEST_SERVICE:-$SMOKE_TEST_SERVICE_DEFAULT}"
SMOKE_TEST_SECRET="${SMOKE_TEST_SECRET:-$SMOKE_TEST_SECRET_DEFAULT}"

FROM_STEP=1
TO_STEP=$STEP_TOTAL
ONLY_STEP=""
SKIP_BUILD=0
SKIP_EMAIL=0
SKIP_SMOKE=0
SKIP_DEPLOY=0
CONFIRM=0
DEBUG=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"

# ─── Argument parsing ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id)      [ $# -lt 2 ] && die "--session-id requires a value"
                       SESSION_ID="$2"; shift 2 ;;
    --session-id=*)    SESSION_ID="${1#*=}"; shift ;;
    --chain)           [ $# -lt 2 ] && die "--chain requires a value"
                       export AGENTKEYS_CHAIN="$2"; shift 2 ;;
    --chain=*)         export AGENTKEYS_CHAIN="${1#*=}"; shift ;;
    --from-step)       [ $# -lt 2 ] && die "--from-step requires N"
                       FROM_STEP="$2"; shift 2 ;;
    --to-step)         [ $# -lt 2 ] && die "--to-step requires N"
                       TO_STEP="$2"; shift 2 ;;
    --only-step)       [ $# -lt 2 ] && die "--only-step requires N"
                       ONLY_STEP="$2"; shift 2 ;;
    --skip-build)      SKIP_BUILD=1; shift ;;
    --skip-email)      SKIP_EMAIL=1; shift ;;
    --skip-smoke)      SKIP_SMOKE=1; shift ;;
    --skip-deploy)     SKIP_DEPLOY=1; shift ;;
    --confirm)         CONFIRM=1; shift ;;
    --debug)           DEBUG=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

[ "$DEBUG" = "1" ] && set -x

if [ -n "$ONLY_STEP" ]; then
  FROM_STEP="$ONLY_STEP"
  TO_STEP="$ONLY_STEP"
fi

# Determine whether a given step number is in scope.
in_scope() {
  local n="$1"
  [ "$n" -ge "$FROM_STEP" ] && [ "$n" -le "$TO_STEP" ]
}

# ─── Step 1: tool sanity-check ──────────────────────────────────────────────
do_step_1() {
  step "Tool sanity-check"
  local missing=()
  for tool in jq curl awk sed grep aws cargo node npx; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "missing tools: ${missing[*]} — install them before re-running"
  fi
  ok "all required tools present (jq curl awk sed grep aws cargo node npx)"

  # forge + cast are only needed for step 8 (chain deploy). Soft-warn now,
  # hard-fail in step 8 if missing.
  for tool in forge cast; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      warn "$tool missing — step 8 (chain deploy) will fail. Install Foundry: https://book.getfoundry.sh/getting-started/installation"
    fi
  done
}

# ─── Step 2: source operator-workstation.env ────────────────────────────────
do_step_2() {
  step "Load operator-workstation.env"
  if [ ! -f "$ENV_FILE" ]; then
    die "missing $ENV_FILE — copy from scripts/operator-workstation.env.example and fill in your values (see docs/cloud-setup.md §0)"
  fi
  # set -a / set +a auto-exports every VAR=value line.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  local required=(ACCOUNT_ID REGION MAIL_DOMAIN MAIL_BUCKET OIDC_ISSUER BACKEND_URL BROKER_HOST BUCKET)
  local missing=()
  for v in "${required[@]}"; do
    eval "val=\${$v:-}"
    [ -z "${val:-}" ] && missing+=("$v")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "operator-workstation.env loaded but missing required vars: ${missing[*]}"
  fi
  ok "env sourced — REGION=$REGION DOMAIN=$MAIL_DOMAIN BUCKET=$BUCKET"

  # Default chain profile if the operator hasn't selected one. We default
  # to heima-paseo (the development convention per arch.md §22a.1) so
  # the script is usable out-of-the-box on a fresh laptop.
  if [ -z "${AGENTKEYS_CHAIN:-}" ]; then
    export AGENTKEYS_CHAIN="heima-paseo"
    info "AGENTKEYS_CHAIN not set — defaulting to heima-paseo (dev convention)"
  fi
}

# ─── Step 3: AWS profile sanity-check ───────────────────────────────────────
do_step_3() {
  step "AWS profile sanity-check"
  local caller_arn
  caller_arn=$(aws sts get-caller-identity --query 'Arn' --output text 2>&1) \
    || die "aws sts get-caller-identity failed: $caller_arn — run: awsp agentkeys-admin"
  # Caller-ARN matching is case-insensitive per CLAUDE.md (remote IAM is
  # agentKeys-admin, local profile is agentkeys-admin).
  local arn_lc
  arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
  case "$arn_lc" in
    *":user/agentkey-broker"*|*":user/agentkey-daemon"*)
      die "caller is $caller_arn — lacks s3:ListBucket. Run: awsp agentkeys-admin" ;;
    *":user/agentkeys-admin"*)
      ok "caller is admin: $caller_arn" ;;
    *)
      warn "caller is $caller_arn — may or may not have required perms; proceeding" ;;
  esac
}

# ─── Step 4: agentkeys CLI build + capability check ─────────────────────────
do_step_4() {
  step "agentkeys CLI build + capability check"
  if [ "$SKIP_BUILD" = "1" ]; then
    skip "--skip-build set; assuming current binary"
    return 0
  fi
  if command -v agentkeys >/dev/null 2>&1 \
     && agentkeys --help 2>&1 | grep -q -- "--session-id" \
     && agentkeys --help 2>&1 | grep -q -- "--chain"; then
    ok "agentkeys $(agentkeys --version 2>/dev/null || echo '?') on PATH at $(command -v agentkeys) (supports --session-id + --chain)"
    return 0
  fi
  info "agentkeys missing or stale — running scripts/install-agentkeys-cli.sh"
  bash "$REPO_ROOT/scripts/install-agentkeys-cli.sh" \
    || die "install-agentkeys-cli.sh failed — see its output above"
  hash -r
  ok "agentkeys rebuilt + reinstalled — $(command -v agentkeys)"
}

# ─── Step 5: chain reachability ─────────────────────────────────────────────
do_step_5() {
  step "Chain reachability check (chain=$AGENTKEYS_CHAIN)"
  local profile rpc_http expected_chain_id hex dec verdict
  profile=$(agentkeys chain show 2>&1) \
    || die "agentkeys chain show failed: $profile"
  rpc_http=$(printf '%s' "$profile" | jq -r .rpc.http)
  expected_chain_id=$(printf '%s' "$profile" | jq -r .chain_id)
  info "RPC=$rpc_http  expected chain_id=$expected_chain_id"
  hex=$(curl -sS --max-time 10 -H 'Content-Type: application/json' \
          -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
          "$rpc_http" 2>/dev/null | jq -r '.result // empty')
  [ -z "$hex" ] && die "cannot reach $rpc_http — check network / override AGENTKEYS_CHAIN_PROFILE_FILE"
  dec=$((hex))   # bash/zsh native hex parse — no 16# prefix, no xargs
  if [ "$dec" = "$expected_chain_id" ]; then
    ok "live eth_chainId=$hex (decimal $dec) matches profile"
  else
    die "live eth_chainId=$hex (decimal $dec) does NOT match profile's $expected_chain_id — chain mismatch?"
  fi
}

# ─── Step 6: email-init Alice session ───────────────────────────────────────
do_step_6() {
  step "Initialize session ($SESSION_ID) via email magic-link"
  local session_file="$HOME/.agentkeys/$SESSION_ID/session.json"
  if [ "$SKIP_EMAIL" = "1" ]; then
    skip "--skip-email set"
    [ -f "$session_file" ] || die "but $session_file missing — drop --skip-email or run init manually"
    return 0
  fi
  if [ -f "$session_file" ]; then
    local age_sec
    age_sec=$(( $(date +%s) - $(stat -f %m "$session_file" 2>/dev/null \
                                 || stat -c %Y "$session_file") ))
    if [ "$age_sec" -lt 3600 ]; then
      skip "$session_file exists and is <1h old (${age_sec}s) — reusing"
      return 0
    fi
    info "$session_file exists but is ${age_sec}s old; re-initing to refresh JWT"
  fi
  info "NOTE: when the macOS keychain dialog appears, click 'Always Allow' (or Touch ID)"
  info "running: bash scripts/agentkeys-init-email-demo.sh --session-id $SESSION_ID"
  AGENTKEYS_SESSION_ID="$SESSION_ID" \
    bash "$REPO_ROOT/scripts/agentkeys-init-email-demo.sh" --session-id "$SESSION_ID" \
    || die "agentkeys-init-email-demo.sh failed — see output above"
  [ -f "$session_file" ] || die "expected $session_file to exist after init"
  ok "session JWT persisted at $session_file"
}

# ─── Step 7: capture wallet + actor_omni, smoke-test S3 envelope ────────────
do_step_7() {
  step "Smoke-test S3 envelope (store + read)"
  if [ "$SKIP_SMOKE" = "1" ]; then
    skip "--skip-smoke set"
    return 0
  fi
  local whoami_json wallet actor_omni
  whoami_json=$(agentkeys --session-id "$SESSION_ID" whoami --json 2>&1) \
    || die "agentkeys whoami failed: $whoami_json — session expired? re-run --only-step 6"
  wallet=$(printf '%s' "$whoami_json" | jq -r '.session_wallet // empty')
  # arch.md canonical name is agentkeys_actor_omni; tolerate the older
  # whoami field name as an alias (see CLAUDE.md "terminology drift" rule).
  actor_omni=$(printf '%s' "$whoami_json" \
                 | jq -r '.agentkeys_actor_omni // .actor_omni // .agentkeys_user_wallet // empty')
  [ -z "$wallet" ]    && die "whoami did not return session_wallet — got: $whoami_json"
  [ -z "$actor_omni" ] && die "whoami did not return actor_omni — got: $whoami_json"
  info "session_wallet      = $wallet"
  info "agentkeys_actor_omni = $actor_omni"

  local s3_key="bots/$actor_omni/credentials/$SMOKE_TEST_SERVICE.enc"
  if aws s3 ls "s3://$BUCKET/$s3_key" --region "$REGION" >/dev/null 2>&1; then
    skip "s3://$BUCKET/$s3_key already exists — round-tripping read only"
  else
    info "writing $SMOKE_TEST_SERVICE credential to s3://$BUCKET/$s3_key"
    agentkeys --session-id "$SESSION_ID" \
      --credential-backend=s3 --envelope-version=v2 \
      --bucket "$BUCKET" --signer-url "$BACKEND_URL" \
      --omni-account "$actor_omni" \
      store "$SMOKE_TEST_SERVICE" "$SMOKE_TEST_SECRET" \
      || die "store failed — check bucket policy (see docs/cloud-setup.md §4.4)"
    aws s3 ls "s3://$BUCKET/$s3_key" --region "$REGION" >/dev/null \
      || die "expected object at s3://$BUCKET/$s3_key after store, but it's missing"
  fi
  info "reading $SMOKE_TEST_SERVICE credential back"
  local round_trip
  round_trip=$(agentkeys --session-id "$SESSION_ID" \
                 --credential-backend=s3 --envelope-version=v2 \
                 --bucket "$BUCKET" --signer-url "$BACKEND_URL" \
                 --omni-account "$actor_omni" \
                 read "$SMOKE_TEST_SERVICE" 2>&1) \
    || die "read failed: $round_trip"
  if [ "$round_trip" = "$SMOKE_TEST_SECRET" ]; then
    ok "envelope round-trip OK — wrote and read back identical bytes"
  else
    die "round-trip mismatch — wrote '$SMOKE_TEST_SECRET' but read '$round_trip'"
  fi
}

# ─── Step 8: chain bring-up (contracts) ─────────────────────────────────────
do_step_8() {
  step "Chain backbone bring-up ($AGENTKEYS_CHAIN)"
  if [ "$SKIP_DEPLOY" = "1" ]; then
    skip "--skip-deploy set"
    return 0
  fi

  local profile_uc
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  local existing_scope
  existing_scope=$(grep -E "^SCOPE_CONTRACT_ADDRESS_${profile_uc}=" "$ENV_FILE" 2>/dev/null \
                     | tail -1 | cut -d= -f2 || true)
  if [ -n "$existing_scope" ] && [ "$existing_scope" != "0x0" ] \
     && [ "$existing_scope" != "0x0000000000000000000000000000000000000001" ]; then
    skip "SCOPE_CONTRACT_ADDRESS_${profile_uc} already in $ENV_FILE: $existing_scope"
    info "(re-deploy with --only-step 8 + manually remove the env-file entries)"
    return 0
  fi

  case "$AGENTKEYS_CHAIN" in
    heima-paseo)
      info "using scripts/heima-paseo-bring-up.sh (sudo-funded via Alice)" ;;
    heima)
      die "AGENTKEYS_CHAIN=heima (mainnet) — bring-up requires real funding + a dedicated runbook. This script only deploys to test chains (heima-paseo, anvil, base-sepolia, sepolia). For mainnet deploys see docs/v2-stage1-migration-and-demo.md §4." ;;
    *)
      die "no automated bring-up for AGENTKEYS_CHAIN=$AGENTKEYS_CHAIN yet — only heima-paseo is shipped. See docs/v2-stage1-migration-and-demo.md §4 for manual deploy steps on $AGENTKEYS_CHAIN." ;;
  esac

  if [ "$CONFIRM" = "1" ]; then
    printf "\n    %sAbout to deploy stage-1 contracts to $AGENTKEYS_CHAIN.%s\n" \
      "$COLOR_WARN" "$COLOR_RESET" >&2
    printf "    Press Enter to proceed, Ctrl-C to abort > " >&2
    read -r _
  fi

  AGENTKEYS_CHAIN="$AGENTKEYS_CHAIN" FUND_AMOUNT_HEI="${FUND_AMOUNT_HEI:-100}" \
    bash "$REPO_ROOT/scripts/heima-paseo-bring-up.sh" \
    || die "heima-paseo-bring-up.sh failed — see output above"

  # Re-source the env file to pick up the freshly-appended contract addresses.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  ok "contracts deployed; addresses appended to $ENV_FILE"
}

# ─── Step 9: final summary ──────────────────────────────────────────────────
do_step_9() {
  step "Summary + next steps"
  local profile_uc registry_addr session_file
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  registry_addr=$(eval "echo \${SIDECAR_REGISTRY_ADDRESS_${profile_uc}:-}")
  session_file="$HOME/.agentkeys/$SESSION_ID/session.json"

  printf "\n${COLOR_OK}═══ v2 stage-1 demo complete ═══${COLOR_RESET}\n\n" >&2
  printf "  session-id          : %s\n"   "$SESSION_ID" >&2
  printf "  session JWT         : %s\n"   "$session_file" >&2
  printf "  chain profile       : %s\n"   "$AGENTKEYS_CHAIN" >&2
  printf "  SidecarRegistry     : %s\n"   "${registry_addr:-(not deployed)}" >&2
  printf "  smoke-test service  : %s @ s3://%s/bots/<actor_omni>/credentials/%s.enc\n" \
    "$SMOKE_TEST_SERVICE" "$BUCKET" "$SMOKE_TEST_SERVICE" >&2
  printf "\n  Next manual steps (not yet automated — pending stage-1 CLI work):\n" >&2
  if [ -n "$registry_addr" ] && [ "$registry_addr" != "0x0" ]; then
    printf "    agentkeys --session-id %s --chain %s device register \\\\\n" \
      "$SESSION_ID" "$AGENTKEYS_CHAIN" >&2
    printf "      --registry-address %s \\\\\n" "$registry_addr" >&2
    printf "      --roles cap-mint,recovery,scope-mgmt\n" >&2
    printf "    (today this errors with 'unrecognized subcommand device' — see\n" >&2
    printf "     docs/v2-stage1-migration-and-demo.md §1.4 stub-status)\n\n" >&2
  fi
  printf "  Re-run individual phases (idempotent):\n" >&2
  printf "    bash scripts/v2-stage1-demo.sh --only-step 5     # re-check chain reachability\n" >&2
  printf "    bash scripts/v2-stage1-demo.sh --only-step 7     # re-run envelope smoke test\n" >&2
  printf "    bash scripts/v2-stage1-demo.sh --from-step 6     # restart from email init\n\n" >&2
}

# ─── Run ────────────────────────────────────────────────────────────────────
main() {
  printf "${COLOR_HEAD}=== v2 stage-1 demo: session-id=%s chain=%s ===${COLOR_RESET}\n" \
    "$SESSION_ID" "${AGENTKEYS_CHAIN:-(unset, will default to heima-paseo)}" >&2
  printf "  steps %d..%d (of %d)\n\n" "$FROM_STEP" "$TO_STEP" "$STEP_TOTAL" >&2

  in_scope 1 && do_step_1
  in_scope 2 && do_step_2
  # Steps 3+ require operator-workstation.env to be sourced — re-source
  # for partial-runs that start at step >= 3.
  if [ "$FROM_STEP" -ge 3 ] && [ -f "$ENV_FILE" ]; then
    set -a; . "$ENV_FILE"; set +a
    : "${AGENTKEYS_CHAIN:=heima-paseo}"; export AGENTKEYS_CHAIN
  fi
  in_scope 3 && do_step_3
  in_scope 4 && do_step_4
  in_scope 5 && do_step_5
  in_scope 6 && do_step_6
  in_scope 7 && do_step_7
  in_scope 8 && do_step_8
  in_scope 9 && do_step_9

  return 0
}

main "$@"
