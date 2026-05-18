#!/usr/bin/env bash
# scripts/heima-scope-revoke.sh — revoke an agent's scope on the live
# AgentKeysScope contract. Wraps `AgentKeysScope.revokeScope(...)`
# per arch.md §12.4.
#
# Stage-1: K11 assertion is a non-empty stub (same as scope-set).
# Idempotency: pre-read the existing scope. If services array is empty,
# the scope is already revoked and we skip.
#
# Usage:
#   bash scripts/heima-scope-revoke.sh --agent demo-agent

set -euo pipefail

LABEL=""
DRY_RUN=0
SCOPE_CONTRACT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)            [ $# -lt 2 ] && { echo "--agent requires a value" >&2; exit 1; }; LABEL="$2"; shift 2 ;;
    --agent=*)          LABEL="${1#*=}"; shift ;;
    --scope-address)    SCOPE_CONTRACT="$2"; shift 2 ;;
    --scope-address=*)  SCOPE_CONTRACT="${1#*=}"; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_SKIP='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_SKIP=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
skip() { printf "    ${C_SKIP}skip${C_RESET} %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

[ -z "$LABEL" ] && die "--agent <label> is required"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$SCOPE_CONTRACT" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "SCOPE_CONTRACT=\${SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$SCOPE_CONTRACT" ] && die "--scope-address required"

AGENT_FILE="$HOME/.agentkeys/agents/${LABEL}.json"
[ -f "$AGENT_FILE" ] || die "no agent registered for label '$LABEL'"
ACTOR_OMNI=$(jq -r .actor_omni "$AGENT_FILE")
[ "$ACTOR_OMNI" = "null" ] && die "agent file missing actor_omni"

MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
[ -f "$MNEMONIC_FILE" ] || die "missing mnemonic"
if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
  npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund || die "npm install failed"
fi
DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$MNEMONIC_FILE")
MASTER_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
MASTER_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')

K11_STUB="0x$(printf 'stage1-k11-stub:%s' "$OPERATOR_OMNI" | xxd -p -c 256 | tr -d '\n')"

log "Inputs"
echo "    chain         = $AGENTKEYS_CHAIN" >&2
echo "    scope         = $SCOPE_CONTRACT" >&2
echo "    operator_omni = 0x$OPERATOR_OMNI" >&2
echo "    actor_omni    = $ACTOR_OMNI" >&2

# Idempotency: read current scope; if exists==false or services empty, already revoked.
log "Idempotency check …"
EXISTING_SCOPE=$(cast call "$SCOPE_CONTRACT" \
  "getScope(bytes32,bytes32)(bytes32[],bool,uint128,uint128,uint128,uint32,uint64,bool)" \
  "0x$OPERATOR_OMNI" "$ACTOR_OMNI" \
  --rpc-url "$RPC_HTTP" 2>&1 || echo ERR)
if [ "$EXISTING_SCOPE" != "ERR" ] && [ -n "$EXISTING_SCOPE" ]; then
  EX_EXISTS=$(printf '%s\n' "$EXISTING_SCOPE" | sed -n '8p' | tr -d '[:space:]')
  EX_SERVICES=$(printf '%s\n' "$EXISTING_SCOPE" | sed -n '1p' | tr -d '[:space:]')
  if [ "$EX_EXISTS" != "true" ] || [ "$EX_SERVICES" = "[]" ]; then
    skip "scope already revoked or never set"
    rm -f "$HOME/.agentkeys/agents/${LABEL}.scope.json"
    echo "{\"ok\":true,\"skipped\":\"already-revoked\",\"agent\":\"$LABEL\"}"
    exit 0
  fi
fi
ok "scope is live → revoking"

CAST_ARGS=(
  send "$SCOPE_CONTRACT"
  "revokeScope(bytes32,bytes32,bytes)"
  "0x$OPERATOR_OMNI" "$ACTOR_OMNI" "$K11_STUB"
  --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" --private-key "$MASTER_KEY"
)

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would invoke (private key redacted):"
  printf '    cast' >&2
  for a in "${CAST_ARGS[@]}"; do
    case "$a" in
      "$MASTER_KEY") printf ' [REDACTED]' >&2 ;;
      *) printf ' %s' "$a" >&2 ;;
    esac
  done
  printf '\n' >&2
  echo "{\"ok\":true,\"dry_run\":true,\"agent\":\"$LABEL\"}"
  exit 0
fi

log "Submitting revokeScope tx via cast send …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
if [ "$CAST_RC" != "0" ]; then
  echo "$CAST_OUT" >&2
  die "cast send failed (exit $CAST_RC)"
fi

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

rm -f "$HOME/.agentkeys/agents/${LABEL}.scope.json"
ok "scope revoked — txhash $TX_HASH (block $BLOCK_NUM)"
echo "{\"ok\":true,\"agent\":\"$LABEL\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\"}"
