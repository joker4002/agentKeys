#!/usr/bin/env bash
# AgentKeys harness — unified runner for local AND CI.
#
# Wraps the per-stage v2 demo scripts (v2-stage{1,2,3}-demo.sh) into a
# single idempotent entry point so local operators + the GitHub Actions
# runner invoke the same command. Per-stage scripts stay callable
# directly for surgical re-runs.
#
# Usage:
#   bash harness/run.sh                          # run all 3 stages
#   bash harness/run.sh --stage 1                # just stage 1
#   bash harness/run.sh --stage 3                # just stage 3 (PrincipalTag isolation)
#   bash harness/run.sh --env-file scripts/operator-workstation.test.env --stage 3
#
# Environment selection:
#   --env-file <path>   override which operator-workstation env file to source
#                       (default: scripts/operator-workstation.env). When set,
#                       implies AGENTKEYS_TEST=1 if the filename contains
#                       "test".
#   --chain <name>      heima (default) | heima-paseo | anvil
#   --webauthn          use real Touch ID (stage 2 + 3 only; stage 1 stub OK)
#
# Idempotency: each stage script is independently idempotent (per CLAUDE.md
# "Idempotent remote-setup rule"). Re-running stage N is safe and short-
# circuits on no-op work.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/scripts/operator-workstation.env}"
STAGE="all"
CHAIN="${AGENTKEYS_CHAIN:-heima}"
WEBAUTHN=""
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)   ENV_FILE="$2"; shift 2 ;;
    --stage)      STAGE="$2"; shift 2 ;;
    --chain)      CHAIN="$2"; shift 2 ;;
    --webauthn)   WEBAUTHN="--webauthn"; shift ;;
    --)           shift; EXTRA_ARGS=("$@"); break ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

# Colors if stderr is a TTY.
if [ -t 2 ]; then
  C_HEAD='\033[1m'; C_OK='\033[32m'; C_FAIL='\033[31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_FAIL=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==> %s${C_RESET}\n" "$1" >&2; }
ok()   { printf "    ${C_OK}ok    %s${C_RESET}\n" "$1" >&2; }
die()  { printf "    ${C_FAIL}fail  %s${C_RESET}\n" "$1" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"
log "sourcing env: $ENV_FILE"
set -a; . "$ENV_FILE"; set +a
ok "env loaded — BROKER_HOST=$BROKER_HOST ACCOUNT_ID=$ACCOUNT_ID"

case "$ENV_FILE" in
  *test*) export AGENTKEYS_TEST=1; ok "AGENTKEYS_TEST=1 (inferred from env-file path)" ;;
esac

export AGENTKEYS_CHAIN="$CHAIN"

run_stage() {
  local n="$1"; shift
  local script="$REPO_ROOT/harness/v2-stage${n}-demo.sh"
  [ -x "$script" ] || die "missing stage script: $script"
  log "stage $n — $(basename "$script")"
  "$script" "$@" "${EXTRA_ARGS[@]}"
  ok "stage $n complete"
}

case "$STAGE" in
  1)    run_stage 1 ${WEBAUTHN:+$WEBAUTHN} ;;
  2)    run_stage 2 ${WEBAUTHN:+$WEBAUTHN} ;;
  3)    run_stage 3 ${WEBAUTHN:+$WEBAUTHN} ;;
  all)
    # Stage 1 + 2 don't need --webauthn in CI (stub OK); stage 3 needs
    # real WebAuthn only when running interactively.
    run_stage 1
    run_stage 2
    run_stage 3
    ;;
  *) die "unknown stage: $STAGE (use 1, 2, 3, or all)" ;;
esac

printf "\n${C_OK}═══ Harness run complete (stage=%s chain=%s) ═══${C_RESET}\n" \
  "$STAGE" "$CHAIN" >&2
