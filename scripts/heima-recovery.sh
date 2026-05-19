#!/usr/bin/env bash
# scripts/heima-recovery.sh — M-of-N master-device revoke (arch.md §11).
#
# Replaces the simpler scripts/heima-device-revoke.sh for MASTER targets.
# Agent revocation continues to use heima-device-revoke.sh (no quorum).
#
# Flow:
#  1. Read recoveryThreshold[operator] from chain.
#  2. Compute the OP_REVOKE_MASTER challenge committing to the target
#     device + per-operator nonce.
#  3. Collect K11 assertions from `threshold` distinct master devices:
#     - PRIMARY's assertion via local `agentkeys k11 assert --webauthn`
#     - COMPANION's assertion via `POST /v1/companion/approve` HTTP API
#  4. Submit SidecarRegistry.revokeMasterDevice(targetHash, K11Assertion[]).
#
# Usage:
#   bash scripts/heima-recovery.sh --target-device-key-hash 0x... \
#        [--companion-url http://127.0.0.1:9091] [--registry-address 0x...]

set -euo pipefail

TARGET=""
COMPANION_URL="${AGENTKEYS_COMPANION_URL:-http://127.0.0.1:9091}"
REGISTRY=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target-device-key-hash) TARGET="$2"; shift 2 ;;
    --target-device-key-hash=*) TARGET="${1#*=}"; shift ;;
    --companion-url)       COMPANION_URL="$2"; shift 2 ;;
    --companion-url=*)     COMPANION_URL="${1#*=}"; shift ;;
    --registry-address)    REGISTRY="$2"; shift 2 ;;
    --registry-address=*)  REGISTRY="${1#*=}"; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    --help|-h) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

[ -n "$TARGET" ] || { echo "--target-device-key-hash required" >&2; exit 1; }

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

# Derive primary master.
MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
if [ ! -f "$MNEMONIC_FILE" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    ok "no mnemonic + dry-run — using placeholder operator/master"
    MASTER_KEY="0x0000000000000000000000000000000000000000000000000000000000000001"
    MASTER_ADDR_LC="0x0000000000000000000000000000000000000001"
    OPERATOR_OMNI="0000000000000000000000000000000000000000000000000000000000000000"
    PRIMARY_DEVICE_KEY_HASH="0x0000000000000000000000000000000000000000000000000000000000000001"
  else
    die "missing mnemonic at $MNEMONIC_FILE"
  fi
else
  if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      ok "ethers not installed + dry-run — using placeholder operator/master"
      MASTER_KEY="0x0000000000000000000000000000000000000000000000000000000000000001"
      MASTER_ADDR_LC="0x0000000000000000000000000000000000000001"
      OPERATOR_OMNI="0000000000000000000000000000000000000000000000000000000000000000"
      PRIMARY_DEVICE_KEY_HASH="0x0000000000000000000000000000000000000000000000000000000000000001"
    else
      die "missing scripts/node_modules/ethers — run \`npm install --prefix scripts\` first"
    fi
  else
    DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$MNEMONIC_FILE")
    MASTER_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
    MASTER_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
    MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
    OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')
    PRIMARY_DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")
  fi
fi

# Read threshold + nonce + op kind.
THRESHOLD=$(cast call "$REGISTRY" "recoveryThreshold(bytes32)(uint8)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP")
[ "$THRESHOLD" = "0" ] && THRESHOLD=1
NONCE=$(cast call "$REGISTRY" "operatorNonce(bytes32)(uint256)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP")
OP_KIND=$(cast call "$REGISTRY" "OP_REVOKE_MASTER()(bytes32)" --rpc-url "$RPC_HTTP")
ok "recoveryThreshold = $THRESHOLD; collecting $THRESHOLD K11 assertions"

CHALLENGE=$(cast keccak "$(cast abi-encode \
  'revokeMaster(bytes32,bytes32,bytes32,uint256,uint256)' \
  "$OP_KIND" "0x$OPERATOR_OMNI" "$TARGET" "$LIVE_CHAIN_ID" "$NONCE")")
ok "expected_challenge = $CHALLENGE"

build_tuple() {
  local device_hash="$1" assertion_json="$2"
  local auth cdj_utf8 cdj_hex chall_loc r_hex s_hex
  auth=$(echo "$assertion_json" | jq -r .authenticator_data_hex)
  cdj_utf8=$(echo "$assertion_json" | jq -r .client_data_json_utf8)
  cdj_hex="0x$(printf '%s' "$cdj_utf8" | xxd -p -c 65536 | tr -d '\n')"
  chall_loc=$(echo "$assertion_json" | jq -r .challenge_location)
  r_hex=$(echo "$assertion_json" | jq -r .r_hex)
  s_hex=$(echo "$assertion_json" | jq -r .s_hex)
  printf '(%s,%s,%s,%s,%s,%s)' "$device_hash" "$auth" "$cdj_hex" "$chall_loc" "$r_hex" "$s_hex"
}

# Collect PRIMARY assertion.
log "Step 1/$THRESHOLD: K11 from PRIMARY master (Touch ID prompt)…"
PRIMARY_JSON=$("$AGENTKEYS_BIN" k11 assert \
  --webauthn --rp-id localhost --emit-chain-payload \
  --operator-omni "0x$OPERATOR_OMNI" --message-hex "$CHALLENGE" 2>/dev/null) \
  || die "PRIMARY K11 ceremony failed"
PRIMARY_TUPLE=$(build_tuple "$PRIMARY_DEVICE_KEY_HASH" "$PRIMARY_JSON")

ASSERTIONS_ARRAY="[$PRIMARY_TUPLE"

# If threshold >= 2: collect COMPANION assertion via HTTP.
if [ "$THRESHOLD" -ge 2 ]; then
  log "Step 2/$THRESHOLD: requesting K11 from COMPANION daemon …"
  COMP_WHOAMI=$(curl -sS "$COMPANION_URL/v1/companion/whoami") \
    || die "GET $COMPANION_URL/v1/companion/whoami failed"
  COMP_DEVICE_KEY_HASH=$(echo "$COMP_WHOAMI" | jq -r .device_key_hash)

  COMP_RESPONSE=$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d "{\"expected_challenge_hex\":\"$CHALLENGE\"}" \
    "$COMPANION_URL/v1/companion/approve") \
    || die "companion approve failed"

  COMP_JSON=$(echo "$COMP_RESPONSE" | jq -c .assertion)
  COMP_TUPLE=$(build_tuple "$COMP_DEVICE_KEY_HASH" "$COMP_JSON")
  ASSERTIONS_ARRAY="$ASSERTIONS_ARRAY,$COMP_TUPLE"
fi
ASSERTIONS_ARRAY="$ASSERTIONS_ARRAY]"

log "Submitting revokeMasterDevice tx …"
CAST_ARGS=(
  send "$REGISTRY"
  'revokeMasterDevice(bytes32,(bytes32,bytes,bytes,uint256,uint256,uint256)[])'
  "$TARGET" "$ASSERTIONS_ARRAY"
  --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" --private-key "$MASTER_KEY"
)

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would invoke:"
  printf '    cast %s\n' "${CAST_ARGS[*]}" >&2
  echo "{\"ok\":true,\"dry_run\":true,\"target\":\"$TARGET\",\"threshold\":$THRESHOLD}"
  exit 0
fi

CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1) || die "cast send failed: $CAST_OUT"
TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
ok "master device revoked — tx=$TX_HASH"
echo "{\"ok\":true,\"target\":\"$TARGET\",\"threshold\":$THRESHOLD,\"tx_hash\":\"$TX_HASH\"}"
