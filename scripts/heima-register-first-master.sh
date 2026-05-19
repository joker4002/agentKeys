#!/usr/bin/env bash
# scripts/heima-register-first-master.sh — bootstrap the operator's first
# master device against the v2 stage-2 SidecarRegistry (arch.md §10.1).
#
# Idempotent: pre-reads `getDevice(deviceKeyHash).registeredAt` and exits 0
# with skip when the device is already registered.
#
# Usage:
#   bash scripts/heima-register-first-master.sh \
#        [--registry-address 0x...] [--dry-run]
#
# Reads primary master K11 pubkey + cred-id from
# `~/.agentkeys/k11/<omni>.json` (must be `mode: "webauthn"`).

set -euo pipefail

REGISTRY=""
DRY_RUN=0
DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-deployer.key}"
ROLES=7   # CAP_MINT | RECOVERY | SCOPE_MGMT = full powers for first master

while [ $# -gt 0 ]; do
  case "$1" in
    --registry-address)   REGISTRY="$2"; shift 2 ;;
    --registry-address=*) REGISTRY="${1#*=}"; shift ;;
    --roles)              ROLES="$2"; shift 2 ;;
    --roles=*)            ROLES="${1#*=}"; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# Resolve agentkeys binary (workspace-local first).
if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
elif [ -x "$REPO_ROOT/target/debug/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/debug/agentkeys"
else
  AGENTKEYS_BIN="$(command -v agentkeys || true)"
  [ -n "$AGENTKEYS_BIN" ] || die "agentkeys binary not found"
fi

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_JSON=$("$AGENTKEYS_BIN" chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$REGISTRY" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$REGISTRY" ] && die "--registry-address required (or set SIDECAR_REGISTRY_ADDRESS_*)"
case "$(printf '%s' "$REGISTRY" | tr '[:upper:]' '[:lower:]')" in
  0x000000000000000000000000000000000000000[1-4])
    die "registry $REGISTRY is the sentinel — deploy contracts first" ;;
esac

# Resolve deployer key (raw hex or mnemonic file).
if [ -f "$DEPLOYER_KEY_FILE" ]; then
  RAW=$(cat "$DEPLOYER_KEY_FILE" | tr -d '\n[:space:]')
  if [ "${#RAW}" = "66" ] && [ "${RAW:0:2}" = "0x" ]; then
    MASTER_KEY="$RAW"
  elif [ "${#RAW}" = "64" ]; then
    MASTER_KEY="0x$RAW"
  else
    # Treat as mnemonic
    if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
      npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund >/dev/null
    fi
    DERIV=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$DEPLOYER_KEY_FILE")
    MASTER_KEY=$(echo "$DERIV" | jq -r .privateKey)
  fi
else
  die "deployer key file not found at $DEPLOYER_KEY_FILE (set HEIMA_DEPLOYER_KEY_FILE)"
fi
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')
DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")

# Load primary K11 pubkey + cred id from disk.
K11_FILE="$HOME/.agentkeys/k11/${OPERATOR_OMNI}.json"
[ -f "$K11_FILE" ] || die "K11 enrollment not found at $K11_FILE — run \`agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x$OPERATOR_OMNI\` first"
MODE=$(jq -r .mode "$K11_FILE")
[ "$MODE" = "webauthn" ] || die "K11 file at $K11_FILE has mode=$MODE (expected 'webauthn') — re-enroll with --webauthn"
COSE_HEX=$(jq -r .cose_pubkey_hex "$K11_FILE")
COSE_NOPREFIX="${COSE_HEX#0x}"
[ "${#COSE_NOPREFIX}" = "130" ] || die "K11 cose_pubkey_hex unexpected length ${#COSE_NOPREFIX} (expected 130)"
K11_PUB_X="0x${COSE_NOPREFIX:2:64}"
K11_PUB_Y="0x${COSE_NOPREFIX:66:64}"
# k11CredId — the WebAuthn credential id, b64url. Hash it for bytes32 storage.
CRED_B64URL=$(jq -r .credential_id_b64url "$K11_FILE")
K11_CRED_ID=$(printf '%s' "$CRED_B64URL" | shasum -a 256 | awk '{print "0x"$1}')

log "Inputs"
echo "    chain         = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    registry      = $REGISTRY" >&2
echo "    master        = $MASTER_ADDR" >&2
echo "    operator_omni = 0x$OPERATOR_OMNI" >&2
echo "    deviceKeyHash = $DEVICE_KEY_HASH" >&2
echo "    roles         = $ROLES (CAP_MINT|RECOVERY|SCOPE_MGMT = 7)" >&2

# Idempotency: pre-read getDevice. If already registered, skip.
log "Idempotency check …"
EXISTING=$(cast call "$REGISTRY" "getDevice(bytes32)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>&1 || echo "")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "0x" ]; then
  HEX=$(printf '%s' "$EXISTING" | tr -d '\n' | sed 's/^0x//')
  # New DeviceEntry layout is larger; registeredAt sits at offset depending on
  # struct ordering. Just check operatorMasterWallet — if non-zero, the operator
  # is bootstrapped and this device is the one.
  EXISTING_MASTER=$(cast call "$REGISTRY" "operatorMasterWallet(bytes32)(address)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP" 2>/dev/null || true)
  if [ -n "$EXISTING_MASTER" ] && [ "$(echo "$EXISTING_MASTER" | tr '[:upper:]' '[:lower:]')" != "0x0000000000000000000000000000000000000000" ]; then
    ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "false")
    if [ "$ACTIVE" = "true" ]; then
      skip "first master already registered + active"
      echo "{\"ok\":true,\"skipped\":\"already-registered\",\"device_key_hash\":\"$DEVICE_KEY_HASH\"}"
      exit 0
    fi
  fi
fi
ok "first master not yet registered → proceeding"

CAST_ARGS=(
  send "$REGISTRY"
  "registerFirstMasterDevice(bytes32,bytes32,bytes32,bytes32,uint256,uint256,bytes,uint8)"
  "$DEVICE_KEY_HASH" "0x$OPERATOR_OMNI" "0x$OPERATOR_OMNI" "$K11_CRED_ID" \
  "$K11_PUB_X" "$K11_PUB_Y" "0x" "$ROLES"
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
  echo "{\"ok\":true,\"dry_run\":true,\"device_key_hash\":\"$DEVICE_KEY_HASH\"}"
  exit 0
fi

log "Submitting registerFirstMasterDevice tx …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
[ "$CAST_RC" = "0" ] || { echo "$CAST_OUT" >&2; die "cast send failed"; }

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

# Post-tx verify.
ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP")
[ "$ACTIVE" = "true" ] || die "post-tx isActive($DEVICE_KEY_HASH) = $ACTIVE"

ok "first master registered — tx=$TX_HASH block=$BLOCK_NUM"
echo "{\"ok\":true,\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\"}"
