#!/usr/bin/env bash
# scripts/heima-device-register.sh — register the operator's master
# device on the live SidecarRegistry. Implements arch.md §1.4 / §10.1
# stage 4: "on-chain SidecarRegistry binding."
#
# Sovereign-mode shape (stage-1 simplification per arch.md §22b — stage-1
# simplifications inventory; entries §22b.1 K11 stub + §22b.3 attestation):
#   - msg.sender = the operator's master EVM wallet (derived from
#     ./test-hei mnemonic, same wallet that deployed the contracts)
#   - K10 device pubkey hash = keccak256(20-byte master wallet addr)
#     (stage-1: K10 == master_wallet's secp256k1 key. Stage 2+ uses a
#     separate device-bound key.)
#   - operator_omni = SHA256("agentkeys" || "evm" || master_wallet_lc)
#   - actor_omni for master = operator_omni (arch.md §14)
#   - K11 cred id = bytes32(0)   (stub mode; WebAuthn integration deferred)
#   - attestation = empty bytes  (stub)
#   - k11_assertion = empty bytes (first call doesn't need it)
#
# Idempotency: call SidecarRegistry.getDevice(deviceKeyHash) first; if
# entry.registeredAt != 0, skip the send. Re-runs are no-ops.
#
# Usage (direct):
#   bash scripts/heima-device-register.sh \
#     --registry-address 0x76D574a107727bE87fc1422661A030FEFda70786 \
#     --roles cap-mint,recovery,scope-mgmt
#
# Usage (via CLI orchestrator):
#   agentkeys --chain heima --session-id alice device register \
#     --registry-address $SIDECAR_REGISTRY_ADDRESS_HEIMA \
#     --roles cap-mint,recovery,scope-mgmt

set -euo pipefail

REGISTRY=""
ROLES=""
DRY_RUN=0
SESSION_ID="${AGENTKEYS_SESSION_ID:-master}"

while [ $# -gt 0 ]; do
  case "$1" in
    --registry-address) [ $# -lt 2 ] && { echo "--registry-address requires a value" >&2; exit 1; }; REGISTRY="$2"; shift 2 ;;
    --registry-address=*) REGISTRY="${1#*=}"; shift ;;
    --roles)            [ $# -lt 2 ] && { echo "--roles requires a value" >&2; exit 1; }; ROLES="$2"; shift 2 ;;
    --roles=*)          ROLES="${1#*=}"; shift ;;
    --session-id)       [ $# -lt 2 ] && { echo "--session-id requires a value" >&2; exit 1; }; SESSION_ID="$2"; shift 2 ;;
    --session-id=*)     SESSION_ID="${1#*=}"; shift ;;
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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
# Resolve registry address: --registry-address flag wins, else
# $SIDECAR_REGISTRY_ADDRESS_<CHAIN_UC> (populated by heima-bring-up.sh
# step 6 via env_set). Lets the operator skip the flag in the common case.
if [ -z "$REGISTRY" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$REGISTRY" ] && die "--registry-address required (or set \$SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC:-HEIMA} in operator-workstation.env)"
# Codex audit follow-up: refuse the operator-workstation.env sentinel
# placeholders (0x...0001..0x...0004) on production chain — they'd
# silently target the zero-prefix address and emit confusing failures.
if [ "$AGENTKEYS_CHAIN" = "heima" ]; then
  case "$(printf '%s' "$REGISTRY" | tr '[:upper:]' '[:lower:]')" in
    0x000000000000000000000000000000000000000[1-4])
      die "SidecarRegistry address $REGISTRY is the operator-workstation.env sentinel (pre-deploy). Run 'bash scripts/heima-bring-up.sh' first to deploy the real contracts." ;;
  esac
fi
[ -z "$ROLES" ]    && die "--roles required (comma-separated: cap-mint,recovery,scope-mgmt)"


case "$AGENTKEYS_CHAIN" in
  heima|heima-paseo) ;;
  *) die "unsupported chain: $AGENTKEYS_CHAIN (only heima or heima-paseo)" ;;
esac
PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

# Parse roles bitfield. ROLE_CAP_MINT=1, ROLE_RECOVERY=2, ROLE_SCOPE_MGMT=4.
ROLES_BITFIELD=0
IFS=',' read -ra ROLE_PARTS <<<"$ROLES"
for r in "${ROLE_PARTS[@]}"; do
  case "$(printf '%s' "$r" | tr -d ' ' | tr '[:upper:]' '[:lower:]')" in
    cap-mint)    ROLES_BITFIELD=$((ROLES_BITFIELD | 1)) ;;
    recovery)    ROLES_BITFIELD=$((ROLES_BITFIELD | 2)) ;;
    scope-mgmt)  ROLES_BITFIELD=$((ROLES_BITFIELD | 4)) ;;
    *) die "unknown role: $r (valid: cap-mint, recovery, scope-mgmt)" ;;
  esac
done

# Derive master EVM key from mnemonic (same flow as heima-bring-up.sh step 3).
MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
[ -f "$MNEMONIC_FILE" ] || die "missing mnemonic at $MNEMONIC_FILE (set HEIMA_DEPLOYER_MNEMONIC_FILE)"
if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
  log "Installing scripts/node_modules deps (first run only)…"
  npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund \
    || die "npm install failed"
fi
DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$MNEMONIC_FILE")
MASTER_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
MASTER_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')

# Compute omnis. operator_omni = SHA256("agentkeys" || "evm" || master_lc).
# Same digest agentkeys-broker-server/src/identity/omni_account.rs uses
# (derive_omni_account("evm", master_lc)). Master's actor_omni == operator_omni.
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')
ACTOR_OMNI="$OPERATOR_OMNI"

# deviceKeyHash = keccak256(20-byte master wallet address).
# Stage-1 simplification: K10 == master wallet. Stage 2+ uses a separate
# device-bound secp256k1 key whose 64-byte uncompressed pubkey is hashed.
DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC" 2>/dev/null | tr '[:upper:]' '[:lower:]')

log "Inputs"
echo "    AGENTKEYS_CHAIN  = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    RPC              = $RPC_HTTP" >&2
echo "    registry         = $REGISTRY" >&2
echo "    master EVM addr  = $MASTER_ADDR" >&2
echo "    operator_omni    = 0x$OPERATOR_OMNI" >&2
echo "    actor_omni       = 0x$ACTOR_OMNI" >&2
echo "    deviceKeyHash    = $DEVICE_KEY_HASH" >&2
echo "    roles bitfield   = $ROLES_BITFIELD ($ROLES)" >&2

# Idempotency: read the current device entry. If registeredAt != 0, skip.
log "Idempotency check: is this device already registered?"
EXISTING=$(cast call "$REGISTRY" "getDevice(bytes32)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>&1 || echo "")
# The struct decodes as: (operatorOmni, actorOmni, k11CredId, tier, roles, registeredAt, revoked)
# encoded as 7 32-byte words. word 5 (0-indexed) = registeredAt.
# Each 32-byte word is 64 hex chars; concatenated as a single 0x-prefixed string.
if [ -n "$EXISTING" ] && [ "$EXISTING" != "0x" ]; then
  HEX_PAYLOAD=$(printf '%s' "$EXISTING" | tr -d '\n' | sed 's/^0x//')
  if [ "${#HEX_PAYLOAD}" -ge 448 ]; then
    REGISTERED_AT_HEX="${HEX_PAYLOAD:320:64}"
    REGISTERED_AT_DEC=$(printf '%d' "0x$REGISTERED_AT_HEX" 2>/dev/null || echo 0)
    if [ "$REGISTERED_AT_DEC" -gt 0 ]; then
      skip "device already registered at timestamp $REGISTERED_AT_DEC — no-op"
      echo "{\"ok\":true,\"skipped\":\"already-registered\",\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"registered_at\":$REGISTERED_AT_DEC}"
      exit 0
    fi
  fi
fi
ok "device not yet registered → proceeding"

# Build the cast send invocation. Note all bytes32 args are 0x-prefixed.
K11_CRED_ID="0x0000000000000000000000000000000000000000000000000000000000000000"
ATTESTATION_HEX="0x"      # empty bytes
K11_ASSERTION_HEX="0x"    # empty bytes (first call doesn't need K11)

CAST_ARGS=(
  send "$REGISTRY"
  "registerMasterDevice(bytes32,bytes32,bytes32,bytes32,bytes,uint8,bytes)"
  "$DEVICE_KEY_HASH"
  "0x$OPERATOR_OMNI"
  "0x$ACTOR_OMNI"
  "$K11_CRED_ID"
  "$ATTESTATION_HEX"
  "$ROLES_BITFIELD"
  "$K11_ASSERTION_HEX"
  --rpc-url "$RPC_HTTP"
  --chain-id "$LIVE_CHAIN_ID"
  --private-key "$MASTER_KEY"
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

log "Submitting registerMasterDevice tx via cast send …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
if [ "$CAST_RC" != "0" ]; then
  echo "    cast send FAILED (exit $CAST_RC). Output:" >&2
  echo "------ cast stderr+stdout ------" >&2
  echo "$CAST_OUT" >&2
  echo "------ end cast output ------" >&2
  exit 1
fi
# cast send prints a structured receipt summary; extract transactionHash + blockNumber.
TX_HASH=$(echo "$CAST_OUT" | grep -oE 'transactionHash[[:space:]]+0x[a-fA-F0-9]{64}' | awk '{print $NF}' || true)
BLOCK_NUM=$(echo "$CAST_OUT" | grep -oE 'blockNumber[[:space:]]+[0-9]+' | awk '{print $NF}' || true)
ok "registerMasterDevice tx in block $BLOCK_NUM"
echo "    tx hash: $TX_HASH" >&2

# Verify on-chain that the entry now exists
log "Post-tx verification"
VERIFY=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>&1 || echo "")
case "$VERIFY" in
  true) ok "SidecarRegistry.isActive(deviceKeyHash) = true" ;;
  *) die "expected isActive=true but got: $VERIFY" ;;
esac
# Note the `(address)` return-type hint — without it, cast returns the
# raw 32-byte ABI-encoded value (e.g. 0x000...00dE64...) instead of the
# prettier 20-byte 0x-address form. Same for `isActive(...)(bool)` above.
MASTER_WALLET_ONCHAIN=$(cast call "$REGISTRY" "operatorMasterWallet(bytes32)(address)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP" 2>&1 | tr '[:upper:]' '[:lower:]' || echo "")
if [ "$MASTER_WALLET_ONCHAIN" = "$MASTER_ADDR_LC" ]; then
  ok "SidecarRegistry.operatorMasterWallet[operator_omni] = $MASTER_ADDR (bootstrapped)"
else
  die "operatorMasterWallet mismatch: $MASTER_WALLET_ONCHAIN vs $MASTER_ADDR_LC"
fi

echo "{\"ok\":true,\"tx_hash\":\"$TX_HASH\",\"block\":$BLOCK_NUM,\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"master_wallet\":\"$MASTER_ADDR\"}"
