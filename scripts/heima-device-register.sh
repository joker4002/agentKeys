#!/usr/bin/env bash
# scripts/heima-device-register.sh — stage-1 wrapper, now thin.
#
# The pre-stage-2 contract had a single registerMasterDevice() that handled
# both first-master bootstrap AND adding additional masters. Stage 2 split
# this into:
#   - registerFirstMasterDevice (first master per operator; no K11 needed)
#   - registerAdditionalMasterDevice (2nd+; needs existing master K11 sig)
#
# To keep stage-1 callers (e.g. harness/v2-stage1-demo.sh step 10) working
# against the stage-2 contract, this script forwards to the appropriate
# new script based on whether the operator's first master is already
# registered.

set -euo pipefail

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

. "$REPO_ROOT/harness/scripts/_lib.sh"

if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
else
  AGENTKEYS_BIN="$(command -v agentkeys || true)"
fi
[ -n "$AGENTKEYS_BIN" ] || die "agentkeys binary not found"

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_JSON=$("$AGENTKEYS_BIN" chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"
[ -z "$REGISTRY" ] && die "no SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC} — run heima-bring-up.sh first"

# Resolve deployer to determine operator_omni.
MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR" | shasum -a 256 | awk '{print $1}')

# Strip flags the legacy callers may still pass that the new
# heima-register-first-master.sh doesn't accept (--roles is the main one;
# new script defaults to roles=7 which is what stage-1 demo wants anyway).
FORWARDED_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --roles|--roles=*) shift; [ "${1#-}" = "$1" ] && shift ;; # eat value if separate
    *) FORWARDED_ARGS+=("$1"); shift ;;
  esac
done

# Is the operator's first master already registered?
EXISTING_MASTER=$(cast call "$REGISTRY" \
  "operatorMasterWallet(bytes32)(address)" "0x$OPERATOR_OMNI" \
  --rpc-url "$RPC_HTTP" 2>/dev/null | tr '[:upper:]' '[:lower:]')

if [ -z "$EXISTING_MASTER" ] || [ "$EXISTING_MASTER" = "0x0000000000000000000000000000000000000000" ]; then
  log "no first master registered → forwarding to heima-register-first-master.sh"
  exec bash "$REPO_ROOT/harness/scripts/heima-register-first-master.sh" "${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}"
fi

log "operator already has a registered master ($EXISTING_MASTER)."
log "To add a 2nd master, run harness/scripts/heima-device-add.sh (companion daemon flow)."
log "Skipping — first-master registration is a one-time bootstrap."
echo "{\"ok\":true,\"skipped\":\"already-registered\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"master_wallet\":\"$EXISTING_MASTER\"}"
