#!/usr/bin/env bash
# harness/scripts/heima-register-master-k10.sh — register the master's secp256k1
# K10 device as a CAP_MINT device (issue #76 — the per-request cap-mint
# proof-of-possession key).
#
# WHY: the master's FIRST device is the #164 passkey account
# (device_key_hash = keccak(operator_omni), a P-256 WebAuthn credential). That
# device authorizes MUTATIONS (scope grants, device adds) via a biometric K11
# ceremony — it is deliberately NOT used per-request (arch.md K10/K11 split).
# Per-request cap-mint needs a LOW-friction, NON-interactive signing key: the
# secp256k1 K10. So we register the master's K10 (the same key the daemon loads
# at ~/.agentkeys/agent-device.key) as an ADDITIONAL master device with
# device_key_hash = keccak(K10 EVM address) and roles = CAP_MINT. Master-self
# cap-mint then uses that K10 + the issue-#76 cap-PoP (BackendClient signs;
# broker `verify_cap_pop` + worker `check_client_pop` re-verify) — closing the
# broker-SPOF for the master's OWN data, symmetric with the agent path.
#
# This is the per-request K10 for the master; the K11 passkey stays the mutation
# gate. roles = ROLE_CAP_MINT (1) ONLY — this device can mint caps but cannot
# authorize mutations (no RECOVERY / SCOPE_MGMT, no K11 fields).
#
# MACHINERY (reused from #200/#164): registerAdditionalMasterDevice, authorized
# by the PRIMARY master's K11 assertion over the OP_REGISTER_2ND_MASTER
# challenge — exactly heima-register-spare-master.sh's flow, but the new device
# is the master's real secp256k1 K10 (K11 fields zero), not a synthetic P-256
# spare. Touch ID locally; software passkey under --ci (`agentkeys k11 assert`
# picks the mode from the enrolled K11).
#
# ⚠️  NEEDS-LIVE-VERIFICATION: authored against the contract ABI + the proven
# spare-master pattern but not run on a live chain in this change. Two things to
# confirm on first run:
#   1. msg.sender — registerAdditionalMasterDevice requires
#      `msg.sender == operatorMasterWallet[operatorOmni]`. For a LEGACY EOA
#      master that's the deployer key (`--private-key`, as here). For a #164
#      passkey master (`operatorMasterWallet` = the P256Account) the add must go
#      through a P256Account UserOp — use erc4337-register-master.sh's
#      build/submit hooks for the send in that case (the K11-assertion + challenge
#      computed here are unchanged).
#   2. the asserting primary device_key_hash — resolved via
#      resolve_active_master_dkh (the #164 keccak(omni) or legacy keccak(addr)).
#
# Idempotent: pre-reads isActive(keccak(K10 addr)); skips if already registered.
#
# Usage:
#   bash harness/scripts/heima-register-master-k10.sh [--registry-address 0x...] \
#        [--device-key-file ~/.agentkeys/agent-device.key]

set -euo pipefail

REGISTRY=""
DEVICE_KEY_FILE="${AGENTKEYS_DEVICE_KEY_FILE:-$HOME/.agentkeys/agent-device.key}"
ROLES=1   # ROLE_CAP_MINT only — per-request signing, NOT mutations.

while [ $# -gt 0 ]; do
  case "$1" in
    --registry-address)    REGISTRY="$2"; shift 2 ;;
    --registry-address=*)  REGISTRY="${1#*=}"; shift ;;
    --device-key-file)     DEVICE_KEY_FILE="$2"; shift 2 ;;
    --device-key-file=*)   DEVICE_KEY_FILE="${1#*=}"; shift ;;
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
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
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
[ -z "$REGISTRY" ] && die "--registry-address required (or SIDECAR_REGISTRY_ADDRESS_* in env)"

# Resolve the operator + primary master (the asserting device).
MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')

# The master's secp256k1 K10 — the SAME key the daemon loads + signs cap-PoP
# with. device_key_hash = keccak(K10 address bytes), matching
# agentkeys_core::device_crypto::device_key_hash (and BackendClient::cap_mint,
# which derives the same hash from the injected K10).
[ -f "$DEVICE_KEY_FILE" ] || die "K10 device key not found at $DEVICE_KEY_FILE (run the daemon once, or pass --device-key-file)"
K10_PRIV=$(tr -d '[:space:]' < "$DEVICE_KEY_FILE")
K10_ADDR=$(cast wallet address --private-key "$K10_PRIV")
K10_ADDR_LC=$(printf '%s' "$K10_ADDR" | tr '[:upper:]' '[:lower:]')
K10_DEVICE_KEY_HASH=$(cast keccak "$K10_ADDR_LC")   # keccak(20 addr bytes) — 0x-prefixed input is hashed as bytes
ok "master K10 address       = $K10_ADDR_LC"
ok "master K10 device_key_hash = $K10_DEVICE_KEY_HASH (roles=$ROLES CAP_MINT)"

# Idempotency: already an active CAP_MINT device?
IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$K10_DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "false")
if [ "$IS_ACTIVE" = "true" ]; then
  skip "master K10 $K10_DEVICE_KEY_HASH already registered + active"
  echo "{\"ok\":true,\"skipped\":\"already-registered\",\"device_key_hash\":\"$K10_DEVICE_KEY_HASH\"}"
  exit 0
fi

# The PRIMARY master device that AUTHORIZES the add (its K11 signs the challenge).
# resolve_active_master_dkh returns the #164 keccak(omni) or legacy keccak(addr).
PRIMARY_DEVICE_KEY_HASH=$(resolve_active_master_dkh "$OPERATOR_OMNI" "$MASTER_ADDR_LC" 2>/dev/null || cast keccak "0x$OPERATOR_OMNI")
PRIMARY_K11_FILE="$HOME/.agentkeys/k11/${OPERATOR_OMNI}.json"
[ -f "$PRIMARY_K11_FILE" ] || die "primary K11 not enrolled at $PRIMARY_K11_FILE (run the master onboarding / K11 enroll first)"

# OP_REGISTER_2ND_MASTER challenge (same encoding as heima-register-spare-master.sh).
NONCE=$(cast call "$REGISTRY" "operatorNonce(bytes32)(uint256)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP")
OP_KIND=$(cast call "$REGISTRY" "OP_REGISTER_2ND_MASTER()(bytes32)" --rpc-url "$RPC_HTTP")
CHALLENGE=$(cast keccak "$(cast abi-encode \
  'register2nd(bytes32,bytes32,bytes32,uint8,uint256,uint256)' \
  "$OP_KIND" "0x$OPERATOR_OMNI" "$K10_DEVICE_KEY_HASH" "$ROLES" "$LIVE_CHAIN_ID" "$NONCE")")
ok "expected_challenge = $CHALLENGE"

log "Requesting K11 assertion from PRIMARY master (Touch ID locally / software under --ci)…"
INTENT_JSON=$(jq -n \
  --arg op_omni "0x${OPERATOR_OMNI}" \
  --arg asserting_hash "${PRIMARY_DEVICE_KEY_HASH}" \
  --arg k10_hash "${K10_DEVICE_KEY_HASH}" \
  --argjson roles "${ROLES}" \
  --argjson chain_id "${LIVE_CHAIN_ID}" \
  --argjson nonce "${NONCE}" \
  '{
    kind: "register_master_k10",
    operator_omni: $op_omni,
    new_device_key_hash: $k10_hash,
    roles: $roles,
    chain_id: $chain_id,
    operator_nonce: $nonce,
    asserting: { kind: "primary", device_key_hash: $asserting_hash }
  }')
ASSERTION_JSON=$("$AGENTKEYS_BIN" k11 assert \
  --webauthn --rp-id localhost --emit-chain-payload \
  --operator-omni "0x$OPERATOR_OMNI" --message-hex "$CHALLENGE" \
  --intent-op-json "$INTENT_JSON") || die "primary K11 ceremony failed"

AUTH_DATA=$(echo "$ASSERTION_JSON" | jq -r .authenticator_data_hex)
CDJ_UTF8=$(echo "$ASSERTION_JSON" | jq -r .client_data_json_utf8)
CDJ_HEX="0x$(printf '%s' "$CDJ_UTF8" | xxd -p -c 65536 | tr -d '\n')"
CHALL_LOC=$(echo "$ASSERTION_JSON" | jq -r .challenge_location)
R_HEX=$(echo "$ASSERTION_JSON" | jq -r .r_hex)
S_HEX=$(echo "$ASSERTION_JSON" | jq -r .s_hex)
TUPLE="($PRIMARY_DEVICE_KEY_HASH,$AUTH_DATA,$CDJ_HEX,$CHALL_LOC,$R_HEX,$S_HEX)"

# Register the K10 as a CAP_MINT device. K11 fields are ZERO — it is a secp256k1
# per-request signing key, not a passkey (it never authorizes mutations).
# NOTE (live-verification): --private-key is the EOA path; for a #164 passkey
# master, submit this call via a P256Account UserOp instead (the TUPLE + args
# are identical).
log "Submitting registerAdditionalMasterDevice (target: master K10, roles=CAP_MINT) …"
ZERO32="0x0000000000000000000000000000000000000000000000000000000000000000"
CAST_OUT=$(cast send "$REGISTRY" \
  'registerAdditionalMasterDevice(bytes32,bytes32,bytes32,bytes32,bytes32,uint256,uint256,bytes,uint8,(bytes32,bytes,bytes,uint256,uint256,uint256))' \
  "$K10_DEVICE_KEY_HASH" "0x$OPERATOR_OMNI" "0x$OPERATOR_OMNI" "$ZERO32" "$ZERO32" \
  "0" "0" "0x00" "$ROLES" \
  "$TUPLE" \
  --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" --private-key "$MASTER_KEY" 2>&1) \
  || { echo "$CAST_OUT" >&2; die "cast send failed"; }

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$K10_DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP")
[ "$IS_ACTIVE" = "true" ] || die "post-tx isActive($K10_DEVICE_KEY_HASH) = $IS_ACTIVE"

ok "master K10 registered as CAP_MINT device — tx=$TX_HASH block=$BLOCK"
echo "{\"ok\":true,\"device_key_hash\":\"$K10_DEVICE_KEY_HASH\",\"k10_address\":\"$K10_ADDR_LC\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK\"}"
