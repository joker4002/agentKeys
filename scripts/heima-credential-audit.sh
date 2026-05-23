#!/usr/bin/env bash
# scripts/heima-credential-audit.sh — append an audit entry to the live
# CredentialAudit contract. Wraps `CredentialAudit.append(...)` per
# arch.md §15.3 tier C.
#
# Anyone can append (gas is the spam-resistance); this script signs
# from the master wallet for convenience.
#
# Usage:
#   bash scripts/heima-credential-audit.sh --actor demo-agent --service openrouter --op store
#   bash scripts/heima-credential-audit.sh --actor demo-agent --service openrouter --op read \
#     --payload-hash 0xabcdef...

set -euo pipefail

LABEL=""
SERVICE=""
OP="store"            # store | read | teardown
PAYLOAD_HASH=""       # 0x-prefixed bytes32, or empty (=zero)
DRY_RUN=0
AUDIT_CONTRACT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --actor)          [ $# -lt 2 ] && { echo "--actor requires a value" >&2; exit 1; }; LABEL="$2"; shift 2 ;;
    --actor=*)        LABEL="${1#*=}"; shift ;;
    --service)        SERVICE="$2"; shift 2 ;;
    --service=*)      SERVICE="${1#*=}"; shift ;;
    --op)             OP="$2"; shift 2 ;;
    --op=*)           OP="${1#*=}"; shift ;;
    --payload-hash)   PAYLOAD_HASH="$2"; shift 2 ;;
    --payload-hash=*) PAYLOAD_HASH="${1#*=}"; shift ;;
    --audit-address)  AUDIT_CONTRACT="$2"; shift 2 ;;
    --audit-address=*) AUDIT_CONTRACT="${1#*=}"; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_ERR=''; C_RESET=''
fi
log() { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()  { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
die() { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

[ -z "$LABEL" ]   && die "--actor <agent-label> required"
[ -z "$SERVICE" ] && die "--service required"

case "$OP" in
  store)    OP_CODE=0 ;;
  read)     OP_CODE=1 ;;
  teardown) OP_CODE=2 ;;
  *) die "--op must be store|read|teardown (got $OP)" ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$AUDIT_CONTRACT" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "AUDIT_CONTRACT=\${CREDENTIAL_AUDIT_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$AUDIT_CONTRACT" ] && die "--audit-address required"
if [ "$AGENTKEYS_CHAIN" = "heima" ]; then
  case "$(printf '%s' "$AUDIT_CONTRACT" | tr '[:upper:]' '[:lower:]')" in
    0x000000000000000000000000000000000000000[1-4])
      die "CredentialAudit address $AUDIT_CONTRACT is the operator-workstation.env sentinel — run bash scripts/heima-bring-up.sh first." ;;
  esac
fi

AGENT_FILE="$HOME/.agentkeys/agents/${LABEL}.json"
[ -f "$AGENT_FILE" ] || die "no agent file for '$LABEL'"
ACTOR_OMNI=$(jq -r .actor_omni "$AGENT_FILE")
[ "$ACTOR_OMNI" = "null" ] && die "agent file missing actor_omni"

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

SERVICE_HASH=$(cast keccak "$(printf '%s' "$SERVICE" | tr '[:upper:]' '[:lower:]')")

# If payload-hash absent, default to keccak("audit-op:<op>:<service>:<ts>").
if [ -z "$PAYLOAD_HASH" ]; then
  PAYLOAD_HASH=$(cast keccak "audit-op:${OP}:${SERVICE}:$(date +%s)")
fi

log "Inputs"
echo "    chain         = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    audit         = $AUDIT_CONTRACT" >&2
echo "    operator_omni = 0x$OPERATOR_OMNI" >&2
echo "    actor_omni    = $ACTOR_OMNI" >&2
echo "    service       = $SERVICE ($SERVICE_HASH)" >&2
echo "    op            = $OP (code $OP_CODE)" >&2
echo "    payload_hash  = $PAYLOAD_HASH" >&2

# Pre-tx: record entryCount.
COUNT_BEFORE=$(cast call "$AUDIT_CONTRACT" "entryCount(bytes32)(uint256)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP" 2>/dev/null | awk '{print $1}')
ok "entry count before: $COUNT_BEFORE"

CAST_ARGS=(
  send "$AUDIT_CONTRACT"
  "append(bytes32,bytes32,bytes32,uint8,bytes32)"
  "0x$OPERATOR_OMNI" "$ACTOR_OMNI" "$SERVICE_HASH" "$OP_CODE" "$PAYLOAD_HASH"
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
  echo "{\"ok\":true,\"dry_run\":true,\"actor\":\"$LABEL\",\"service\":\"$SERVICE\",\"op\":\"$OP\"}"
  exit 0
fi

log "Submitting append tx via cast send …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
[ "$CAST_RC" = "0" ] || { echo "$CAST_OUT" >&2; die "cast send failed"; }

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

COUNT_AFTER=$(cast call "$AUDIT_CONTRACT" "entryCount(bytes32)(uint256)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP" 2>/dev/null | awk '{print $1}')

# Verify monotonic increment.
EXPECTED=$((COUNT_BEFORE + 1))
[ "$COUNT_AFTER" = "$EXPECTED" ] && ok "entryCount: $COUNT_BEFORE → $COUNT_AFTER (+1)" \
  || die "expected entryCount=$EXPECTED, got $COUNT_AFTER"

ok "audit appended — txhash $TX_HASH (block $BLOCK_NUM)"
echo "{\"ok\":true,\"actor\":\"$LABEL\",\"service\":\"$SERVICE\",\"op\":\"$OP\",\"entry_index\":$COUNT_BEFORE,\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\"}"
