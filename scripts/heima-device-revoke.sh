#!/usr/bin/env bash
# scripts/heima-device-revoke.sh — revoke a registered device on the
# live SidecarRegistry. Stage-2 recovery-flow scaffold per arch.md §10.3
# (multi-master M-of-N revocation). Stage 1 supports the simpler case:
# operator's current master revokes a single device.
#
# Master-tier revocations require K11 assertion (stub bytes in stage 1).
# Agent-tier revocations don't (agents never hold K11).
#
# Idempotency: pre-read getDevice. If `revoked == true`, skip.
#
# Usage:
#   bash scripts/heima-device-revoke.sh --agent demo-agent
#   bash scripts/heima-device-revoke.sh --device-key-hash 0xabc...
#   bash scripts/heima-device-revoke.sh --master --dry-run

set -euo pipefail

LABEL=""
DEVICE_KEY_HASH=""
REVOKE_MASTER=0
DRY_RUN=0
REGISTRY=""
USE_WEBAUTHN=0  # arch.md §22b.1 — pass --webauthn for real Touch ID K11.

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)              [ $# -lt 2 ] && { echo "--agent requires a value" >&2; exit 1; }; LABEL="$2"; shift 2 ;;
    --agent=*)            LABEL="${1#*=}"; shift ;;
    --device-key-hash)    DEVICE_KEY_HASH="$2"; shift 2 ;;
    --device-key-hash=*)  DEVICE_KEY_HASH="${1#*=}"; shift ;;
    --master)             REVOKE_MASTER=1; shift ;;
    --registry-address)   REGISTRY="$2"; shift 2 ;;
    --registry-address=*) REGISTRY="${1#*=}"; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --webauthn)           USE_WEBAUTHN=1; shift ;;
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

if [ "$REVOKE_MASTER" = "1" ] && [ -n "$LABEL" ]; then
  die "--master and --agent are mutually exclusive"
fi
if [ "$REVOKE_MASTER" = "0" ] && [ -z "$LABEL" ] && [ -z "$DEVICE_KEY_HASH" ]; then
  die "one of --agent <label>, --device-key-hash <hex>, or --master is required"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# Resolve agentkeys binary (workspace-local first; avoids stale ~/.local/bin).
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
PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$REGISTRY" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$REGISTRY" ] && die "--registry-address required"
if [ "$AGENTKEYS_CHAIN" = "heima" ]; then
  case "$(printf '%s' "$REGISTRY" | tr '[:upper:]' '[:lower:]')" in
    0x000000000000000000000000000000000000000[1-4])
      die "SidecarRegistry address $REGISTRY is the operator-workstation.env sentinel — run bash scripts/heima-bring-up.sh first." ;;
  esac
fi

# Master key
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

# Resolve device_key_hash from inputs.
if [ "$REVOKE_MASTER" = "1" ]; then
  DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC" | tr '[:upper:]' '[:lower:]')
  log "revoking MASTER device (this disables the operator's master entirely)"
elif [ -n "$LABEL" ]; then
  AGENT_FILE="$HOME/.agentkeys/agents/${LABEL}.json"
  [ -f "$AGENT_FILE" ] || die "no agent file for '$LABEL'"
  AGENT_ADDR=$(jq -r .agent_address "$AGENT_FILE")
  AGENT_ADDR_LC=$(printf '%s' "$AGENT_ADDR" | tr '[:upper:]' '[:lower:]')
  DEVICE_KEY_HASH=$(cast keccak "$AGENT_ADDR_LC" | tr '[:upper:]' '[:lower:]')
  log "revoking agent '$LABEL' ($AGENT_ADDR)"
fi
case "$DEVICE_KEY_HASH" in 0x*) ;; *) DEVICE_KEY_HASH="0x$DEVICE_KEY_HASH" ;; esac

# K11 assertion per arch.md §22b.1 — only required for master revoke.
if [ "$REVOKE_MASTER" = "1" ]; then
  if [ "$USE_WEBAUTHN" = "1" ]; then
    msg_hex=$(printf 'agentkeys:device-revoke:%s:%s:%s' \
      "$OPERATOR_OMNI" "$DEVICE_KEY_HASH" "$AGENTKEYS_CHAIN" \
      | xxd -p -c 65536 | tr -d '\n')
    log "Requesting real WebAuthn assertion (Touch ID prompt incoming)…"
    K11_ARG=$("$AGENTKEYS_BIN" k11 assert --webauthn \
      --operator-omni "0x$OPERATOR_OMNI" \
      --message-hex "$msg_hex" 2>/dev/null) \
      || die "agentkeys k11 assert --webauthn failed"
  else
    K11_ARG="0x$(printf 'stage1-k11-stub:%s' "$OPERATOR_OMNI" | xxd -p -c 256 | tr -d '\n')"
  fi
else
  # Agent revoke — empty bytes accepted (agents never hold K11).
  K11_ARG="0x"
fi

log "Inputs"
echo "    chain         = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    registry      = $REGISTRY" >&2
echo "    master        = $MASTER_ADDR" >&2
echo "    deviceKeyHash = $DEVICE_KEY_HASH" >&2
echo "    revoke_kind   = $( [ "$REVOKE_MASTER" = 1 ] && echo MASTER || echo AGENT )" >&2

# Idempotency: isActive(bytes32)(bool) returns true iff registeredAt != 0
# AND !revoked. So if !isActive, the device is either unregistered (skip)
# or already revoked (skip). Cleaner than slicing the raw getDevice() tuple
# at hex offsets — the DeviceEntry struct grew in codex H1, breaking the
# previous offset-based check.
log "Idempotency check: is this device still active on-chain?"
IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "false")
if [ "$IS_ACTIVE" = "false" ]; then
  skip "device not active (already-revoked or never-registered) — no-op"
  echo "{\"ok\":true,\"skipped\":\"not-active\",\"device_key_hash\":\"$DEVICE_KEY_HASH\"}"
  exit 0
fi
ok "device active → revoking"

# Stage-2 split: revokeAgentDevice (no K11) vs revokeMasterDevice (M-of-N).
# Master revoke must go through the M-of-N quorum flow — delegate to
# harness/scripts/heima-recovery.sh which collects threshold K11 sigs.
if [ "$REVOKE_MASTER" = "1" ]; then
  log "Master revoke requires the M-of-N quorum flow — delegating to heima-recovery.sh"
  exec bash "$REPO_ROOT/harness/scripts/heima-recovery.sh" \
    --target-device-key-hash "$DEVICE_KEY_HASH" \
    --companion-url "${AGENTKEYS_COMPANION_URL:-http://127.0.0.1:9091}"
fi

# Agent revoke: no K11 sig needed (agents never hold K11). New ABI is
# revokeAgentDevice(bytes32).
CAST_ARGS=(
  send "$REGISTRY"
  "revokeAgentDevice(bytes32)"
  "$DEVICE_KEY_HASH"
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

log "Submitting revokeDevice tx …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
[ "$CAST_RC" = "0" ] || { echo "$CAST_OUT" >&2; die "cast send failed"; }

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

# Post-tx verify: isActive == false now.
log "Post-tx verification …"
IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>&1 || echo ERR)
[ "$IS_ACTIVE" = "false" ] && ok "isActive($DEVICE_KEY_HASH) = false" \
  || die "post-tx isActive check failed: '$IS_ACTIVE'"

# Cleanup: remove agent metadata if revoking an agent.
if [ -n "$LABEL" ]; then
  rm -f "$HOME/.agentkeys/agents/${LABEL}.scope.json"
  # Keep ~/.agentkeys/agents/<label>.json for audit; only nuke scope file.
fi

ok "device revoked — txhash $TX_HASH (block $BLOCK_NUM)"
echo "{\"ok\":true,\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\"}"
