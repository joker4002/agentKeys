#!/usr/bin/env bash
# scripts/heima-set-recovery-threshold.sh — update SidecarRegistry.recoveryThreshold
# for an operator (arch.md §11). Master-only, K11-gated.
#
# Usage:
#   bash scripts/heima-set-recovery-threshold.sh --threshold 2
#
# Requires the operator's primary master device + a valid K11 enrollment at
# rp_id=localhost.

set -euo pipefail

THRESHOLD=""
REGISTRY=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)          THRESHOLD="$2"; shift 2 ;;
    --threshold=*)        THRESHOLD="${1#*=}"; shift ;;
    --registry-address)   REGISTRY="$2"; shift 2 ;;
    --registry-address=*) REGISTRY="${1#*=}"; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --help|-h) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[ -n "$THRESHOLD" ] || { echo "--threshold required (1..255)" >&2; exit 1; }

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
elif [ -x "$REPO_ROOT/target/debug/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/debug/agentkeys"
else
  AGENTKEYS_BIN="$(command -v agentkeys)"
fi

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_JSON=$($AGENTKEYS_BIN chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$REGISTRY" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$REGISTRY" ] && die "--registry-address required"

MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$MNEMONIC_FILE")
MASTER_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
MASTER_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')
PRIMARY_DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")

# Idempotency: skip if already set.
CURRENT=$(cast call "$REGISTRY" "recoveryThreshold(bytes32)(uint8)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP")
if [ "$CURRENT" = "$THRESHOLD" ]; then
  ok "recoveryThreshold already $THRESHOLD — skipping"
  echo "{\"ok\":true,\"skipped\":\"already-set\",\"threshold\":$THRESHOLD}"
  exit 0
fi

# Compute expected challenge.
NONCE=$(cast call "$REGISTRY" "operatorNonce(bytes32)(uint256)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP")
OP_KIND=$(cast call "$REGISTRY" "OP_SET_THRESHOLD()(bytes32)" --rpc-url "$RPC_HTTP")
CHALLENGE=$(cast keccak "$(cast abi-encode \
  'setThreshold(bytes32,bytes32,uint256,uint256,uint256)' \
  "$OP_KIND" "0x$OPERATOR_OMNI" "$THRESHOLD" "$LIVE_CHAIN_ID" "$NONCE")")
ok "challenge = $CHALLENGE"

log "Requesting K11 assertion from PRIMARY master (Touch ID)…"
ASSERTION_JSON=$("$AGENTKEYS_BIN" k11 assert \
  --webauthn --rp-id localhost --emit-chain-payload \
  --operator-omni "0x$OPERATOR_OMNI" --message-hex "$CHALLENGE" 2>/dev/null) \
  || die "k11 assert failed"

AUTH_DATA=$(echo "$ASSERTION_JSON" | jq -r .authenticator_data_hex)
CDJ_UTF8=$(echo "$ASSERTION_JSON" | jq -r .client_data_json_utf8)
CDJ_HEX="0x$(printf '%s' "$CDJ_UTF8" | xxd -p -c 65536 | tr -d '\n')"
CHALL_LOC=$(echo "$ASSERTION_JSON" | jq -r .challenge_location)
R_HEX=$(echo "$ASSERTION_JSON" | jq -r .r_hex)
S_HEX=$(echo "$ASSERTION_JSON" | jq -r .s_hex)
TUPLE="($PRIMARY_DEVICE_KEY_HASH,$AUTH_DATA,$CDJ_HEX,$CHALL_LOC,$R_HEX,$S_HEX)"

CAST_ARGS=(
  send "$REGISTRY"
  'setRecoveryThreshold(bytes32,uint8,(bytes32,bytes,bytes,uint256,uint256,uint256))'
  "0x$OPERATOR_OMNI" "$THRESHOLD" "$TUPLE"
  --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" --private-key "$MASTER_KEY"
)

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would invoke cast send"
  echo "{\"ok\":true,\"dry_run\":true,\"threshold\":$THRESHOLD}"
  exit 0
fi

CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1) || die "cast send failed: $CAST_OUT"
TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
ok "recoveryThreshold set to $THRESHOLD — tx=$TX_HASH"
echo "{\"ok\":true,\"threshold\":$THRESHOLD,\"tx_hash\":\"$TX_HASH\"}"
