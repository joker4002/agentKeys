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

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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

# Derive primary master via shared key-resolution lib.
. "$REPO_ROOT/harness/scripts/_lib.sh"
if MASTER_KEY=$(resolve_master_key 2>/dev/null); then
  MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
  MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
  OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')
  PRIMARY_DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")
elif [ "$DRY_RUN" = "1" ]; then
  ok "no deployer key + dry-run — using placeholder operator/master"
  MASTER_KEY="0x0000000000000000000000000000000000000000000000000000000000000001"
  MASTER_ADDR_LC="0x0000000000000000000000000000000000000001"
  OPERATOR_OMNI="0000000000000000000000000000000000000000000000000000000000000000"
  PRIMARY_DEVICE_KEY_HASH="0x0000000000000000000000000000000000000000000000000000000000000001"
else
  die "could not resolve deployer key (set HEIMA_DEPLOYER_KEY_FILE or place ~/.agentkeys/heima-deployer.key)"
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

# ─── Typed K11 intent for both masters in the quorum ─────────────────
# Both PRIMARY and COMPANION render the SAME headline + SAME rows
# from the SAME typed payload — only `asserting` differs per master.
# Headline + field formatting live in the shared k11_intent.rs
# renderer, so cross-prompt uniformity is enforced by construction.
# See wiki/k11-intent-conventions.md.

# Collect PRIMARY assertion.
log "Step 1/$THRESHOLD: K11 from PRIMARY master (Touch ID prompt)…"
PRIMARY_INTENT_JSON=$(jq -n \
  --arg op_omni "0x${OPERATOR_OMNI}" \
  --arg asserting_hash "${PRIMARY_DEVICE_KEY_HASH}" \
  --arg target "${TARGET}" \
  --argjson thr "${THRESHOLD}" \
  --argjson chain_id "${LIVE_CHAIN_ID}" \
  --argjson nonce "${NONCE}" \
  '{
    kind: "recovery_device_revoke",
    operator_omni: $op_omni,
    target_device_key_hash: $target,
    recovery_threshold: $thr,
    chain_id: $chain_id,
    operator_nonce: $nonce,
    asserting: { kind: "primary", device_key_hash: $asserting_hash }
  }')
K11_ERR=$(mktemp -t heima-recovery-primary-k11.XXXXXX) || die "mktemp failed"
PRIMARY_JSON=$("$AGENTKEYS_BIN" k11 assert \
  --webauthn --rp-id localhost --emit-chain-payload \
  --operator-omni "0x$OPERATOR_OMNI" --message-hex "$CHALLENGE" \
  --intent-op-json "$PRIMARY_INTENT_JSON" 2>"$K11_ERR") \
  || {
    echo "==> K11 assert stderr ↓ ↓ ↓" >&2
    cat "$K11_ERR" >&2
    echo "==> K11 assert stderr ↑ ↑ ↑" >&2
    rm -f "$K11_ERR"
    die "PRIMARY K11 ceremony failed (see stderr above for root cause)"
  }
rm -f "$K11_ERR"
PRIMARY_TUPLE=$(build_tuple "$PRIMARY_DEVICE_KEY_HASH" "$PRIMARY_JSON")

ASSERTIONS_ARRAY="[$PRIMARY_TUPLE"

# If threshold >= 2: collect COMPANION assertion via HTTP. The companion
# daemon's /v1/companion/approve handler accepts a typed `intent_op`
# payload in its POST body — same K11OpIntent shape, same renderer,
# so PRIMARY + COMPANION prompts are byte-for-byte uniform on the
# operation rows; only `asserting` differs.
if [ "$THRESHOLD" -ge 2 ]; then
  log "Step 2/$THRESHOLD: requesting K11 from COMPANION daemon …"
  COMP_WHOAMI=$(curl -sS "$COMPANION_URL/v1/companion/whoami") \
    || die "GET $COMPANION_URL/v1/companion/whoami failed"
  COMP_DEVICE_KEY_HASH=$(echo "$COMP_WHOAMI" | jq -r .device_key_hash)

  COMP_REQ_JSON=$(jq -n \
    --arg challenge "$CHALLENGE" \
    --arg op_omni "0x${OPERATOR_OMNI}" \
    --arg companion_hash "${COMP_DEVICE_KEY_HASH}" \
    --arg target "${TARGET}" \
    --argjson thr "${THRESHOLD}" \
    --argjson chain_id "${LIVE_CHAIN_ID}" \
    --argjson nonce "${NONCE}" \
    '{
      expected_challenge_hex: $challenge,
      intent_op: {
        kind: "recovery_device_revoke",
        operator_omni: $op_omni,
        target_device_key_hash: $target,
        recovery_threshold: $thr,
        chain_id: $chain_id,
        operator_nonce: $nonce,
        asserting: { kind: "companion", device_key_hash: $companion_hash }
      }
    }')

  COMP_RESPONSE=$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d "$COMP_REQ_JSON" \
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
