#!/usr/bin/env bash
# scripts/heima-device-add.sh — register a 2nd master device against the
# live SidecarRegistry (arch.md §10.3.1).
#
# Multi-master pairing flow (alternative to the mobile-app companion):
#
#  1. The companion daemon is already running with its own K11 enrolled at
#     rp_id=companion.localhost (see scripts/v2-stage2-demo.sh step 1-2 or
#     `agentkeys-daemon --master-companion ...`).
#  2. This script asks the companion daemon's HTTP API for the new device's
#     parameters (device_key_hash, k11CredId, k11PubX, k11PubY).
#  3. Constructs the OP_REGISTER_2ND_MASTER challenge that the on-chain
#     SidecarRegistry will reconstruct.
#  4. Runs `agentkeys k11 assert --webauthn --emit-chain-payload` against
#     the PRIMARY master's K11 (Touch ID prompt at rp_id=localhost) over
#     the expected challenge.
#  5. Submits SidecarRegistry.registerAdditionalMasterDevice(...) with the
#     primary master's K11 assertion as authorization.
#
# Usage:
#   bash scripts/heima-device-add.sh --companion-url http://127.0.0.1:9091 \
#        [--roles 3] [--registry-address 0x...] [--dry-run]
#
# Default roles = CAP_MINT | RECOVERY = 3 (matches arch.md §10.3.1 default).
# Add SCOPE_MGMT (bit 2) by passing --roles 7.

set -euo pipefail

COMPANION_URL="${AGENTKEYS_COMPANION_URL:-http://127.0.0.1:9091}"
ROLES=3
REGISTRY=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --companion-url)      COMPANION_URL="$2"; shift 2 ;;
    --companion-url=*)    COMPANION_URL="${1#*=}"; shift ;;
    --roles)              ROLES="$2"; shift 2 ;;
    --roles=*)            ROLES="${1#*=}"; shift ;;
    --registry-address)   REGISTRY="$2"; shift 2 ;;
    --registry-address=*) REGISTRY="${1#*=}"; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --help|-h) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# Resolve agentkeys binary (workspace-local first).
if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
elif [ -x "$REPO_ROOT/target/debug/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/debug/agentkeys"
elif command -v agentkeys >/dev/null 2>&1; then
  AGENTKEYS_BIN="$(command -v agentkeys)"
else
  die "agentkeys binary not found (try: cargo build -p agentkeys-cli)"
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
[ -z "$REGISTRY" ] && die "--registry-address required (or set SIDECAR_REGISTRY_ADDRESS_*)"

# Step 1: pull companion's identity + load its K11 pubkey from the file
# the companion daemon dropped during enrollment.
log "Step 1/4: fetching companion daemon /v1/companion/whoami …"
COMPANION_INFO=$(curl -sS "$COMPANION_URL/v1/companion/whoami") \
  || die "GET $COMPANION_URL/v1/companion/whoami failed; is the companion daemon running?"
COMP_OPERATOR_OMNI=$(echo "$COMPANION_INFO" | jq -r .operator_omni)
COMP_DEVICE_KEY_HASH=$(echo "$COMPANION_INFO" | jq -r .device_key_hash)
COMP_K11_CRED_ID=$(echo "$COMPANION_INFO" | jq -r .k11_cred_id)
COMP_RP_ID=$(echo "$COMPANION_INFO" | jq -r .rp_id)
ok "companion operator_omni = $COMP_OPERATOR_OMNI"
ok "companion device_key_hash = $COMP_DEVICE_KEY_HASH"
ok "companion rp_id          = $COMP_RP_ID"

# Idempotency check per CLAUDE.md "Idempotent remote-setup rule":
# `SidecarRegistry.getDevice(deviceKeyHash).registeredAt > 0` means the
# companion is already registered on chain — skip the K11 ceremony +
# tx submit. Re-runs MUST exit 0 without re-applying the mutation,
# otherwise the contract reverts `DeviceAlreadyRegistered(bytes32)`
# (selector 0xa98bbce0) on the second attempt.
log "Idempotency check: is the companion device already on-chain?"
DEVICE_ENTRY=$(cast call "$REGISTRY" \
  "getDevice(bytes32)(bytes32,bytes32,bytes32,bytes32,uint256,uint256,uint8,uint8,uint64,uint32,bool)" \
  "$COMP_DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>/dev/null) || die "getDevice RPC call failed"
# DeviceEntry layout: (operatorOmni, actorOmni, k11CredId, k11RpIdHash,
# k11PubX, k11PubY, tier, roles, registeredAt, lastSignCount, revoked).
# `cast call` with multi-return signature prints one value per line.
REGISTERED_AT=$(printf '%s\n' "$DEVICE_ENTRY" | awk 'NR==9 {print; exit}')
REVOKED=$(printf '%s\n' "$DEVICE_ENTRY" | awk 'NR==11 {print; exit}')
if [ -n "$REGISTERED_AT" ] && [ "$REGISTERED_AT" != "0" ]; then
  if [ "$REVOKED" = "true" ]; then
    die "device $COMP_DEVICE_KEY_HASH is registered AND revoked on-chain — \
re-registering a revoked device is not supported (would require \
contract-side override). Generate a NEW companion device + re-enroll."
  fi
  ok "skip device $COMP_DEVICE_KEY_HASH already registered at block-ts $REGISTERED_AT — no-op"
  printf '{"ok":true,"skipped":"already-registered","device_key_hash":"%s","registered_at":%s}\n' \
    "$COMP_DEVICE_KEY_HASH" "$REGISTERED_AT"
  exit 0
fi
ok "device not yet on-chain — proceeding"

# Load the companion's K11 pubkey from disk — file path is derived from
# the rp_id the daemon was started with, so this works for any version
# (companion.localhost, companion-v2.localhost, etc.).
COMP_OMNI_NOPREFIX="${COMP_OPERATOR_OMNI#0x}"
COMP_K11_FILE="$HOME/.agentkeys/k11/${COMP_OMNI_NOPREFIX}--${COMP_RP_ID}.json"
if [ -f "$COMP_K11_FILE" ]; then
  COMP_COSE_HEX=$(jq -r .cose_pubkey_hex "$COMP_K11_FILE")
  COMP_COSE_NOPREFIX="${COMP_COSE_HEX#0x}"
  [ "${#COMP_COSE_NOPREFIX}" = "130" ] || die "companion cose_pubkey_hex should be 65 bytes (130 hex chars)"
  COMP_K11_PUB_X="0x${COMP_COSE_NOPREFIX:2:64}"
  COMP_K11_PUB_Y="0x${COMP_COSE_NOPREFIX:66:64}"
elif [ "$DRY_RUN" = "1" ]; then
  ok "companion K11 file not present yet — dry-run uses placeholder pubkey"
  COMP_K11_PUB_X="0x0000000000000000000000000000000000000000000000000000000000000000"
  COMP_K11_PUB_Y="0x0000000000000000000000000000000000000000000000000000000000000000"
else
  die "companion K11 enrollment not found at $COMP_K11_FILE — run \`agentkeys k11 enroll --webauthn --rp-id companion.localhost --operator-omni $COMP_OPERATOR_OMNI\` first"
fi

# Step 2: derive primary master wallet + load primary's K11 (for the
# authorization assertion). Uses _lib.sh's resolve_master_key so this
# accepts raw-hex keys (~/.agentkeys/heima-deployer.key) AND mnemonic
# files (./test-hei).
. "$REPO_ROOT/harness/scripts/_lib.sh"
MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')
[ "0x$OPERATOR_OMNI" = "$COMP_OPERATOR_OMNI" ] \
  || die "primary operator_omni 0x$OPERATOR_OMNI != companion's $COMP_OPERATOR_OMNI"

PRIMARY_DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")

# Step 3: build the expected challenge per the contract:
#   keccak256(abi.encode(OP_REGISTER_2ND_MASTER, operator_omni, newDeviceKeyHash, newRoles, chainid, nonce))
log "Step 3/4: reading current operatorNonce + computing challenge …"
NONCE=$(cast call "$REGISTRY" "operatorNonce(bytes32)(uint256)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP")
OP_KIND=$(cast call "$REGISTRY" "OP_REGISTER_2ND_MASTER()(bytes32)" --rpc-url "$RPC_HTTP")

CHALLENGE=$(cast keccak "$(cast abi-encode \
  'register2nd(bytes32,bytes32,bytes32,uint8,uint256,uint256)' \
  "$OP_KIND" "0x$OPERATOR_OMNI" "$COMP_DEVICE_KEY_HASH" "$ROLES" "$LIVE_CHAIN_ID" "$NONCE")")
ok "expected_challenge = $CHALLENGE"

# Step 4: run WebAuthn ceremony on PRIMARY master (rp_id=localhost) to
# attest the new device.
if [ "$DRY_RUN" = "1" ] && [ ! -f "$HOME/.agentkeys/k11/${OPERATOR_OMNI}.json" ]; then
  ok "primary K11 not enrolled — dry-run uses placeholder assertion"
  AUTH_DATA="0x$(printf '%.0s00' $(seq 1 37))"
  CDJ_HEX="0x$(printf '{"type":"webauthn.get","challenge":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","origin":"http://localhost"}' | xxd -p -c 65536 | tr -d '\n')"
  CHALL_LOC=36
  R_HEX="0x0000000000000000000000000000000000000000000000000000000000000001"
  S_HEX="0x0000000000000000000000000000000000000000000000000000000000000001"
else
  log "Step 4/4: requesting K11 assertion from PRIMARY master (Touch ID prompt)…"
  ASSERTION_JSON=$("$AGENTKEYS_BIN" k11 assert \
    --webauthn \
    --rp-id localhost \
    --emit-chain-payload \
    --operator-omni "0x$OPERATOR_OMNI" \
    --message-hex "$CHALLENGE" \
    --intent-text "Register companion device as 2nd master" \
    --intent-field "Operator omni=0x${OPERATOR_OMNI}" \
    --intent-field "New device key hash=${COMP_DEVICE_KEY_HASH}" \
    --intent-field "Companion RP ID=${COMP_RP_ID}" \
    --intent-field "Role bitfield=${ROLES} (bit0=CAP_MINT, bit1=RECOVERY, bit2=SCOPE_MGMT)" \
    --intent-field "Chain ID=${LIVE_CHAIN_ID}" \
    --intent-field "Operator nonce=${NONCE}" 2>/dev/null) \
    || die "k11 assert ceremony failed"

  AUTH_DATA=$(echo "$ASSERTION_JSON" | jq -r .authenticator_data_hex)
  # cast send needs raw bytes; b64url-decode the JSON.
  CDJ_UTF8=$(echo "$ASSERTION_JSON" | jq -r .client_data_json_utf8)
  CDJ_HEX="0x$(printf '%s' "$CDJ_UTF8" | xxd -p -c 65536 | tr -d '\n')"
  CHALL_LOC=$(echo "$ASSERTION_JSON" | jq -r .challenge_location)
  R_HEX=$(echo "$ASSERTION_JSON" | jq -r .r_hex)
  S_HEX=$(echo "$ASSERTION_JSON" | jq -r .s_hex)
fi

# K11Assertion tuple = (deviceKeyHash, authData, cdj, challengeLocation, r, s)
TUPLE="($PRIMARY_DEVICE_KEY_HASH,$AUTH_DATA,$CDJ_HEX,$CHALL_LOC,$R_HEX,$S_HEX)"

# Sanity-check critical bytes32 args before cast — the cast parser's
# "invalid string length" errors are opaque otherwise.
for pair in "COMP_DEVICE_KEY_HASH=$COMP_DEVICE_KEY_HASH" \
            "OPERATOR_OMNI=0x$OPERATOR_OMNI" \
            "COMP_K11_CRED_ID=$COMP_K11_CRED_ID" \
            "COMP_K11_PUB_X=$COMP_K11_PUB_X" \
            "COMP_K11_PUB_Y=$COMP_K11_PUB_Y"; do
  name="${pair%%=*}"; val="${pair#*=}"
  if [ "${#val}" -ne 66 ]; then
    die "$name has length ${#val} (expected 66 = 0x + 64 hex); val=$val"
  fi
done

# Codex H1: compute sha256(companion rp_id) so the contract enforces
# authData[0:32] match against this stored value on every future K11
# assertion from the companion.
COMP_K11_RP_ID_HASH="0x$(printf '%s' "$COMP_RP_ID" | shasum -a 256 | awk '{print $1}')"

log "Submitting registerAdditionalMasterDevice tx …"
CAST_ARGS=(
  send "$REGISTRY"
  'registerAdditionalMasterDevice(bytes32,bytes32,bytes32,bytes32,bytes32,uint256,uint256,bytes,uint8,(bytes32,bytes,bytes,uint256,uint256,uint256))'
  "$COMP_DEVICE_KEY_HASH" "0x$OPERATOR_OMNI" "0x$OPERATOR_OMNI" \
  "$COMP_K11_CRED_ID" "$COMP_K11_RP_ID_HASH" \
  "$COMP_K11_PUB_X" "$COMP_K11_PUB_Y" \
  "0x00" "$ROLES" \
  "$TUPLE"
  --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" --private-key "$MASTER_KEY"
)

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would invoke:"
  printf '    cast %s\n' "${CAST_ARGS[*]}" >&2
  echo "{\"ok\":true,\"dry_run\":true,\"companion_device_key_hash\":\"$COMP_DEVICE_KEY_HASH\"}"
  exit 0
fi

CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1) || die "cast send failed: $CAST_OUT"
TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
ok "2nd master registered — tx=$TX_HASH"
echo "{\"ok\":true,\"device_key_hash\":\"$COMP_DEVICE_KEY_HASH\",\"tx_hash\":\"$TX_HASH\"}"
