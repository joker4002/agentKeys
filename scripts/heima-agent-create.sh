#!/usr/bin/env bash
# scripts/heima-agent-create.sh — register an agent device on the live
# SidecarRegistry. Implements arch.md §10.2 "agent device pairing"
# (master mints a link code, agent redeems it).
#
# Stage-1 simplification (per arch.md §22b stage-1 simplifications inventory):
#   - msg.sender = the operator's master EVM wallet (the one that
#     deployed the contracts / ran heima-device-register.sh)
#   - The agent's K10 == a freshly-generated secp256k1 keypair, persisted
#     locally to ~/.agentkeys/agents/<label>.json (mode 0600)
#   - device_key_hash = keccak256(agent_wallet_address_lc)
#   - operator_omni  = SHA256("agentkeys" || "evm" || master_wallet_lc)
#   - actor_omni     = SHA256("agentkeys" || "evm" || agent_wallet_lc)
#   - linkCodeRedemption = 32 random bytes (stub for arch.md §10.2's
#     master-mints-link-code dance; on-chain just stores presence)
#   - agentPopSig = ECDSA over keccak("agentkeys-agent-pop:" || device_key_hash)
#     signed by the agent_wallet itself (proof of possession)
#
# Auto-funds the freshly-generated agent wallet with --fund-hei (default
# 0.05 HEI) so it has gas for its first cap-mint tx. Skips funding if
# the agent wallet already has ≥ --fund-hei.
#
# Idempotency: call SidecarRegistry.getDevice(deviceKeyHash) first; if
# registeredAt != 0, skip the send. Re-runs are no-ops.
#
# Usage:
#   bash scripts/heima-agent-create.sh --label demo-agent
#   bash scripts/heima-agent-create.sh --label demo-agent --fund-hei 0.1
#   bash scripts/heima-agent-create.sh --label demo-agent --dry-run

set -euo pipefail

LABEL=""
FUND_HEI="0.05"
DRY_RUN=0
REGISTRY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --label)              [ $# -lt 2 ] && { echo "--label requires a value" >&2; exit 1; }; LABEL="$2"; shift 2 ;;
    --label=*)            LABEL="${1#*=}"; shift ;;
    --fund-hei)           [ $# -lt 2 ] && { echo "--fund-hei requires a value" >&2; exit 1; }; FUND_HEI="$2"; shift 2 ;;
    --fund-hei=*)         FUND_HEI="${1#*=}"; shift ;;
    --registry-address)   [ $# -lt 2 ] && { echo "--registry-address requires a value" >&2; exit 1; }; REGISTRY="$2"; shift 2 ;;
    --registry-address=*) REGISTRY="${1#*=}"; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
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

[ -z "$LABEL" ] && die "--label is required (e.g. --label demo-agent)"
# Label must be filename-safe.
case "$LABEL" in
  *[!a-zA-Z0-9._-]*) die "--label must match [a-zA-Z0-9._-]+ (got: $LABEL)" ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
case "$AGENTKEYS_CHAIN" in
  heima|heima-paseo) ;;
  *) die "unsupported chain: $AGENTKEYS_CHAIN (only heima or heima-paseo)" ;;
esac
PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

# Resolve registry address: --registry-address > $SIDECAR_REGISTRY_ADDRESS_<CHAIN_UC>.
if [ -z "$REGISTRY" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$REGISTRY" ] && die "--registry-address required (or set \$SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC:-HEIMA})"

# Derive master EVM key from mnemonic (same flow as heima-device-register.sh).
MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
[ -f "$MNEMONIC_FILE" ] || die "missing mnemonic at $MNEMONIC_FILE"
if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
  log "Installing scripts/node_modules deps (first run only)…"
  npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund || die "npm install failed"
fi
DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$MNEMONIC_FILE")
MASTER_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
MASTER_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')

OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')

# Generate or reuse agent wallet. Persisted at ~/.agentkeys/agents/<label>.json
AGENT_DIR="$HOME/.agentkeys/agents"
AGENT_FILE="$AGENT_DIR/${LABEL}.json"
mkdir -p "$AGENT_DIR"
chmod 700 "$AGENT_DIR" 2>/dev/null || true

if [ -f "$AGENT_FILE" ]; then
  AGENT_ADDR=$(jq -r .agent_address "$AGENT_FILE")
  AGENT_KEY=$(jq -r .agent_private_key "$AGENT_FILE")
  ok "reusing existing agent wallet from $AGENT_FILE → $AGENT_ADDR"
else
  log "Generating fresh agent wallet for label '$LABEL' …"
  WALLET_JSON=$(cast wallet new --json | jq -r '.[0]')
  AGENT_ADDR=$(echo "$WALLET_JSON" | jq -r .address)
  AGENT_KEY=$(echo "$WALLET_JSON" | jq -r .private_key)
  (umask 077 && jq -n \
    --arg label "$LABEL" \
    --arg addr  "$AGENT_ADDR" \
    --arg key   "$AGENT_KEY" \
    --arg chain "$AGENTKEYS_CHAIN" \
    --arg ts    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{label:$label, agent_address:$addr, agent_private_key:$key, chain:$chain, created_at:$ts}' \
    > "$AGENT_FILE")
  chmod 600 "$AGENT_FILE"
  ok "created $AGENT_FILE (0600) — address $AGENT_ADDR"
fi
AGENT_ADDR_LC=$(printf '%s' "$AGENT_ADDR" | tr '[:upper:]' '[:lower:]')
ACTOR_OMNI=$(printf 'agentkeysevm%s' "$AGENT_ADDR_LC" | shasum -a 256 | awk '{print $1}')

# Auto-fund the agent wallet (idempotent — skips if already funded).
log "Funding agent wallet from operator master (idempotent) …"
bash "$REPO_ROOT/scripts/heima-fund-account.sh" --to "$AGENT_ADDR" --amount-hei "$FUND_HEI" >/dev/null \
  || die "funding agent wallet failed"
ok "agent wallet funded (or already had ≥ $FUND_HEI HEI)"

DEVICE_KEY_HASH=$(cast keccak "$AGENT_ADDR_LC" 2>/dev/null | tr '[:upper:]' '[:lower:]')

log "Inputs"
echo "    AGENTKEYS_CHAIN  = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    registry         = $REGISTRY" >&2
echo "    master addr      = $MASTER_ADDR" >&2
echo "    agent label      = $LABEL" >&2
echo "    agent addr       = $AGENT_ADDR" >&2
echo "    operator_omni    = 0x$OPERATOR_OMNI" >&2
echo "    actor_omni       = 0x$ACTOR_OMNI" >&2
echo "    deviceKeyHash    = $DEVICE_KEY_HASH" >&2

# Idempotency: read the current device entry. If registeredAt != 0, skip.
log "Idempotency check: is this agent device already registered?"
EXISTING=$(cast call "$REGISTRY" "getDevice(bytes32)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>&1 || echo "")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "0x" ]; then
  HEX_PAYLOAD=$(printf '%s' "$EXISTING" | tr -d '\n' | sed 's/^0x//')
  if [ "${#HEX_PAYLOAD}" -ge 448 ]; then
    REGISTERED_AT_HEX="${HEX_PAYLOAD:320:64}"
    REGISTERED_AT_DEC=$(printf '%d' "0x$REGISTERED_AT_HEX" 2>/dev/null || echo 0)
    if [ "$REGISTERED_AT_DEC" -gt 0 ]; then
      skip "agent device already registered at timestamp $REGISTERED_AT_DEC — no-op"
      # Update agent file with the prior tx info if missing.
      echo "{\"ok\":true,\"skipped\":\"already-registered\",\"label\":\"$LABEL\",\"agent_address\":\"$AGENT_ADDR\",\"actor_omni\":\"0x$ACTOR_OMNI\",\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"registered_at\":$REGISTERED_AT_DEC}"
      exit 0
    fi
  fi
fi
ok "agent device not yet registered → proceeding"

# Build the agentPopSig: agent_wallet signs keccak("agentkeys-agent-pop:" || device_key_hash).
# This is the proof-of-possession: only the holder of agent_private_key can produce this sig.
POP_PAYLOAD_HEX=$(cast keccak "agentkeys-agent-pop:${DEVICE_KEY_HASH}")
AGENT_POP_SIG=$(cast wallet sign --private-key "$AGENT_KEY" "$POP_PAYLOAD_HEX")
# Random 32-byte link-code-redemption blob (stub for §10.2 ceremony).
LINK_CODE_REDEMPTION="0x$(openssl rand -hex 32)"

CAST_ARGS=(
  send "$REGISTRY"
  "registerAgentDevice(bytes32,bytes32,bytes32,bytes,bytes)"
  "$DEVICE_KEY_HASH"
  "0x$OPERATOR_OMNI"
  "0x$ACTOR_OMNI"
  "$LINK_CODE_REDEMPTION"
  "$AGENT_POP_SIG"
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
  echo "{\"ok\":true,\"dry_run\":true,\"label\":\"$LABEL\",\"agent_address\":\"$AGENT_ADDR\",\"actor_omni\":\"0x$ACTOR_OMNI\",\"device_key_hash\":\"$DEVICE_KEY_HASH\"}"
  exit 0
fi

log "Submitting registerAgentDevice tx via cast send …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
if [ "$CAST_RC" != "0" ]; then
  echo "    cast send FAILED (exit $CAST_RC). Output:" >&2
  echo "$CAST_OUT" >&2
  exit 1
fi

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

# Post-tx verification: isActive(deviceKeyHash) == true.
log "Post-tx verification …"
IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>&1 || echo ERR)
[ "$IS_ACTIVE" = "true" ] && ok "isActive($DEVICE_KEY_HASH) = true" \
  || die "post-tx isActive check failed: '$IS_ACTIVE'"

# Update agent file with on-chain info.
TMP_FILE=$(mktemp)
jq --arg th "$TX_HASH" --arg bn "$BLOCK_NUM" --arg actor "0x$ACTOR_OMNI" \
   --arg dkh "$DEVICE_KEY_HASH" --arg op "0x$OPERATOR_OMNI" \
   '. + {tx_hash:$th, block_number:$bn, actor_omni:$actor, operator_omni:$op, device_key_hash:$dkh}' \
   "$AGENT_FILE" > "$TMP_FILE"
mv "$TMP_FILE" "$AGENT_FILE"
chmod 600 "$AGENT_FILE"

ok "registered — txhash $TX_HASH (block $BLOCK_NUM)"
echo "{\"ok\":true,\"label\":\"$LABEL\",\"agent_address\":\"$AGENT_ADDR\",\"actor_omni\":\"0x$ACTOR_OMNI\",\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\"}"
