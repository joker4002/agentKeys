#!/usr/bin/env bash
# harness/scripts/heima-register-spare-master.sh — register a synthetic 3rd
# master device for end-to-end M-of-N revoke testing.
#
# The "spare" is a P-256 keypair generated from /dev/urandom (NOT a real
# WebAuthn credential). It exists ONLY to be revoked in the next step of
# the demo, exercising the contract's quorum-verify path. The spare itself
# never signs anything — primary + companion provide the 2-of-2 quorum.
#
# Idempotent: pre-reads getDevice + isActive. If the spare is already
# registered and active, skips. If it's registered but revoked, regenerates
# a fresh spare with a new keypair.
#
# Usage:
#   bash harness/scripts/heima-register-spare-master.sh \
#        [--state-dir /tmp/agentkeys-spare-current] [--registry-address 0x...]
#
# Reads/writes the spare's identity to $STATE_DIR for step 9 (revoke) to
# pick up. Files:
#   $STATE_DIR/pub_x, pub_y         — P-256 coords (0x-prefixed hex)
#   $STATE_DIR/device_key_hash      — keccak256(0x04 || X || Y)
#   $STATE_DIR/k11_cred_id          — synthetic 32-byte hash
#   $STATE_DIR/pem                  — full keypair PEM (for audit)

set -euo pipefail

STATE_DIR="${SPARE_STATE_DIR:-/tmp/agentkeys-spare-current}"
REGISTRY=""
ROLES=3   # CAP_MINT | RECOVERY (no SCOPE_MGMT)

while [ $# -gt 0 ]; do
  case "$1" in
    --state-dir)           STATE_DIR="$2"; shift 2 ;;
    --state-dir=*)         STATE_DIR="${1#*=}"; shift ;;
    --registry-address)    REGISTRY="$2"; shift 2 ;;
    --registry-address=*)  REGISTRY="${1#*=}"; shift ;;
    --roles)               ROLES="$2"; shift 2 ;;
    --roles=*)             ROLES="${1#*=}"; shift ;;
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

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$REGISTRY" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$REGISTRY" ] && die "--registry-address required"

# Resolve primary master.
MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')
PRIMARY_DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")

# Primary's K11 enrollment (signs the register tx).
PRIMARY_K11_FILE="$HOME/.agentkeys/k11/${OPERATOR_OMNI}.json"
[ -f "$PRIMARY_K11_FILE" ] || die "primary K11 not enrolled at $PRIMARY_K11_FILE"
PRIMARY_MODE=$(jq -r .mode "$PRIMARY_K11_FILE")
[ "$PRIMARY_MODE" = "webauthn" ] || die "primary K11 mode=$PRIMARY_MODE (need 'webauthn')"

mkdir -p "$STATE_DIR"

# Idempotency: if state exists and the spare is still active on chain, skip.
if [ -f "$STATE_DIR/device_key_hash" ]; then
  EXISTING_HASH=$(cat "$STATE_DIR/device_key_hash")
  IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$EXISTING_HASH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "false")
  if [ "$IS_ACTIVE" = "true" ]; then
    skip "spare $EXISTING_HASH already registered and active"
    echo "{\"ok\":true,\"skipped\":\"already-registered\",\"device_key_hash\":\"$EXISTING_HASH\"}"
    exit 0
  fi
  log "previous spare state at $STATE_DIR is revoked or missing on chain — regenerating"
  rm -f "$STATE_DIR"/*
fi

# Generate a fresh synthetic P-256 keypair.
log "Generating synthetic P-256 keypair for spare master …"
SPARE_PEM="$STATE_DIR/pem"
openssl ecparam -name prime256v1 -genkey -noout -out "$SPARE_PEM" 2>/dev/null \
  || die "openssl ecparam failed"
SPARE_UNCOMPRESSED=$(openssl ec -in "$SPARE_PEM" -pubout -outform DER 2>/dev/null \
  | tail -c 65 | xxd -p | tr -d '\n')
[ "${#SPARE_UNCOMPRESSED}" = "130" ] || die "spare pubkey malformed (got ${#SPARE_UNCOMPRESSED} hex chars; expected 130)"
[ "${SPARE_UNCOMPRESSED:0:2}" = "04" ] || die "spare pubkey not SEC1 uncompressed (prefix ${SPARE_UNCOMPRESSED:0:2})"

SPARE_PUB_X="0x${SPARE_UNCOMPRESSED:2:64}"
SPARE_PUB_Y="0x${SPARE_UNCOMPRESSED:66:64}"
SPARE_DEVICE_KEY_HASH=$(cast keccak "0x$SPARE_UNCOMPRESSED")
SPARE_CRED_ID=$(cast keccak "$SPARE_DEVICE_KEY_HASH")  # synthetic — never used to look up off-chain

echo "$SPARE_PUB_X" > "$STATE_DIR/pub_x"
echo "$SPARE_PUB_Y" > "$STATE_DIR/pub_y"
echo "$SPARE_DEVICE_KEY_HASH" > "$STATE_DIR/device_key_hash"
echo "$SPARE_CRED_ID" > "$STATE_DIR/k11_cred_id"
chmod 600 "$SPARE_PEM"

ok "spare device_key_hash = $SPARE_DEVICE_KEY_HASH"
ok "spare pub_x           = $SPARE_PUB_X"
ok "spare pub_y           = $SPARE_PUB_Y"

# Build the OP_REGISTER_2ND_MASTER challenge for primary's K11 to sign.
log "Reading operatorNonce + OP_REGISTER_2ND_MASTER constant …"
NONCE=$(cast call "$REGISTRY" "operatorNonce(bytes32)(uint256)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP")
OP_KIND=$(cast call "$REGISTRY" "OP_REGISTER_2ND_MASTER()(bytes32)" --rpc-url "$RPC_HTTP")
CHALLENGE=$(cast keccak "$(cast abi-encode \
  'register2nd(bytes32,bytes32,bytes32,uint8,uint256,uint256)' \
  "$OP_KIND" "0x$OPERATOR_OMNI" "$SPARE_DEVICE_KEY_HASH" "$ROLES" "$LIVE_CHAIN_ID" "$NONCE")")
ok "expected_challenge = $CHALLENGE"

log "Requesting K11 assertion from PRIMARY master (Touch ID prompt at localhost)…"
# Uniform K11-intent shape — see wiki/k11-intent-conventions.md.
# Headline = one-line operation summary; rows ALWAYS include Operator
# omni, Asserting role + device hash, Chain ID, Operator nonce, plus
# operation-specific detail (here: the new spare device's hash + role
# bitfield).
K11_ERR=$(mktemp -t heima-spare-master-k11.XXXXXX) || die "mktemp failed"
ASSERTION_JSON=$("$AGENTKEYS_BIN" k11 assert \
  --webauthn --rp-id localhost --emit-chain-payload \
  --operator-omni "0x$OPERATOR_OMNI" --message-hex "$CHALLENGE" \
  --intent-text "Register synthetic 3rd master (spare) device" \
  --intent-field "Operator omni=0x${OPERATOR_OMNI}" \
  --intent-field "Asserting role=PRIMARY (key hash ${PRIMARY_DEVICE_KEY_HASH})" \
  --intent-field "New spare device key hash=${SPARE_DEVICE_KEY_HASH}" \
  --intent-field "Role bitfield=${ROLES} (bit0=CAP_MINT, bit1=RECOVERY, bit2=SCOPE_MGMT)" \
  --intent-field "Effect=adds a 3rd master to the operator's quorum (used by harness step 9 to demo M-of-N revoke)" \
  --intent-field "Chain ID=${LIVE_CHAIN_ID}" \
  --intent-field "Operator nonce=${NONCE}" 2>"$K11_ERR") \
  || {
    echo "==> K11 assert stderr ↓ ↓ ↓" >&2
    cat "$K11_ERR" >&2
    echo "==> K11 assert stderr ↑ ↑ ↑" >&2
    rm -f "$K11_ERR"
    die "primary K11 ceremony failed (see stderr above for root cause)"
  }
rm -f "$K11_ERR"

AUTH_DATA=$(echo "$ASSERTION_JSON" | jq -r .authenticator_data_hex)
CDJ_UTF8=$(echo "$ASSERTION_JSON" | jq -r .client_data_json_utf8)
CDJ_HEX="0x$(printf '%s' "$CDJ_UTF8" | xxd -p -c 65536 | tr -d '\n')"
CHALL_LOC=$(echo "$ASSERTION_JSON" | jq -r .challenge_location)
R_HEX=$(echo "$ASSERTION_JSON" | jq -r .r_hex)
S_HEX=$(echo "$ASSERTION_JSON" | jq -r .s_hex)
TUPLE="($PRIMARY_DEVICE_KEY_HASH,$AUTH_DATA,$CDJ_HEX,$CHALL_LOC,$R_HEX,$S_HEX)"

# Codex H1: rpIdHash for the synthetic spare. The spare never signs (it
# only gets registered, then revoked), so the stored value is never
# checked. Use a sentinel hash bound to the synthetic identity for
# audit trail clarity.
SPARE_RP_ID_HASH=$(cast keccak "$SPARE_DEVICE_KEY_HASH")

log "Submitting registerAdditionalMasterDevice tx (target: spare) …"
CAST_OUT=$(cast send "$REGISTRY" \
  'registerAdditionalMasterDevice(bytes32,bytes32,bytes32,bytes32,bytes32,uint256,uint256,bytes,uint8,(bytes32,bytes,bytes,uint256,uint256,uint256))' \
  "$SPARE_DEVICE_KEY_HASH" "0x$OPERATOR_OMNI" "0x$OPERATOR_OMNI" "$SPARE_CRED_ID" "$SPARE_RP_ID_HASH" \
  "$SPARE_PUB_X" "$SPARE_PUB_Y" "0x00" "$ROLES" \
  "$TUPLE" \
  --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" --private-key "$MASTER_KEY" 2>&1) \
  || { echo "$CAST_OUT" >&2; die "cast send failed"; }

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

# Verify on-chain.
IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$SPARE_DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP")
[ "$IS_ACTIVE" = "true" ] || die "post-tx isActive($SPARE_DEVICE_KEY_HASH) = $IS_ACTIVE"

ok "spare registered as 3rd master — tx=$TX_HASH block=$BLOCK"
echo "{\"ok\":true,\"device_key_hash\":\"$SPARE_DEVICE_KEY_HASH\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK\"}"
