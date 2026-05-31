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
# §10.2 interim (issue #144): when these are supplied — by the harness Phase P,
# from the in-sandbox `agentkeys agent device-session` — register the
# SANDBOX-generated device instead of generating a key here. This keeps the
# agent's private key OFF the master (the master only sees the pubkey + pop_sig).
FROM_AGENT_ADDR=""
FROM_ACTOR_OMNI=""
FROM_DEVICE_KEY_HASH=""
FROM_POP_SIG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --label)              [ $# -lt 2 ] && { echo "--label requires a value" >&2; exit 1; }; LABEL="$2"; shift 2 ;;
    --label=*)            LABEL="${1#*=}"; shift ;;
    --fund-hei)           [ $# -lt 2 ] && { echo "--fund-hei requires a value" >&2; exit 1; }; FUND_HEI="$2"; shift 2 ;;
    --fund-hei=*)         FUND_HEI="${1#*=}"; shift ;;
    --registry-address)   [ $# -lt 2 ] && { echo "--registry-address requires a value" >&2; exit 1; }; REGISTRY="$2"; shift 2 ;;
    --registry-address=*) REGISTRY="${1#*=}"; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --agent-address)      [ $# -lt 2 ] && { echo "--agent-address requires a value" >&2; exit 1; }; FROM_AGENT_ADDR="$2"; shift 2 ;;
    --agent-address=*)    FROM_AGENT_ADDR="${1#*=}"; shift ;;
    --actor-omni)         [ $# -lt 2 ] && { echo "--actor-omni requires a value" >&2; exit 1; }; FROM_ACTOR_OMNI="$2"; shift 2 ;;
    --actor-omni=*)       FROM_ACTOR_OMNI="${1#*=}"; shift ;;
    --device-key-hash)    [ $# -lt 2 ] && { echo "--device-key-hash requires a value" >&2; exit 1; }; FROM_DEVICE_KEY_HASH="$2"; shift 2 ;;
    --device-key-hash=*)  FROM_DEVICE_KEY_HASH="${1#*=}"; shift ;;
    --pop-sig)            [ $# -lt 2 ] && { echo "--pop-sig requires a value" >&2; exit 1; }; FROM_POP_SIG="$2"; shift 2 ;;
    --pop-sig=*)          FROM_POP_SIG="${1#*=}"; shift ;;
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
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
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
if [ "$AGENTKEYS_CHAIN" = "heima" ]; then
  case "$(printf '%s' "$REGISTRY" | tr '[:upper:]' '[:lower:]')" in
    0x000000000000000000000000000000000000000[1-4])
      die "SidecarRegistry address $REGISTRY is the operator-workstation.env sentinel — run bash scripts/heima-bring-up.sh first." ;;
  esac
fi

# Derive master EVM key — uses shared resolve_master_key from
# harness/scripts/_lib.sh (supports HEIMA_DEPLOYER_KEY_FILE for CI / raw-key
# path + falls back to ./test-hei mnemonic for operator dogfood). Same
# pattern as scripts/heima-scope-set.sh L125. Replaces the prior mnemonic-
# only inline block that broke CI (no test-hei file on the runner).
. "$REPO_ROOT/harness/scripts/_lib.sh"
MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')

OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')

AGENT_KEY=""
if [ -n "$FROM_AGENT_ADDR" ]; then
  # §10.2 interim (issue #144): the agent key was generated IN THE SANDBOX by
  # `agentkeys agent device-session`. The master never sees the private key —
  # so NO keygen, NO agent-file write, NO funding (the agent never sends a tx;
  # the master submits registerAgentDevice below). We only register the pubkey.
  [ -n "$FROM_ACTOR_OMNI" ] && [ -n "$FROM_DEVICE_KEY_HASH" ] && [ -n "$FROM_POP_SIG" ] \
    || die "--agent-address requires --actor-omni, --device-key-hash and --pop-sig"
  AGENT_ADDR="$FROM_AGENT_ADDR"
  AGENT_ADDR_LC=$(printf '%s' "$AGENT_ADDR" | tr '[:upper:]' '[:lower:]')
  ACTOR_OMNI=$(printf '%s' "$FROM_ACTOR_OMNI" | sed 's/^0x//')
  DEVICE_KEY_HASH=$(printf '%s' "$FROM_DEVICE_KEY_HASH" | tr '[:upper:]' '[:lower:]')
  # Key-LESS metadata record so heima-scope-set.sh can resolve the actor by
  # label. The agent's PRIVATE KEY stays in the sandbox and is NEVER written here
  # (that is the whole point of the §10.2 fix). The post-register block below
  # then adds actor_omni / operator_omni / device_key_hash / tx_hash.
  AGENT_DIR="$HOME/.agentkeys/agents"
  AGENT_FILE="$AGENT_DIR/${LABEL}.json"
  mkdir -p "$AGENT_DIR"; chmod 700 "$AGENT_DIR" 2>/dev/null || true
  (umask 077 && jq -n --arg label "$LABEL" --arg addr "$AGENT_ADDR" \
     --arg chain "$AGENTKEYS_CHAIN" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{label:$label, agent_address:$addr, chain:$chain, created_at:$ts, key_custody:"sandbox-only (§10.2 interim #144)"}' \
     > "$AGENT_FILE")
  chmod 600 "$AGENT_FILE"
  ok "from-pubkey: registering SANDBOX-generated device $AGENT_ADDR (key never on master; metadata-only file)"
else
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
fi

log "Inputs"
echo "    AGENTKEYS_CHAIN  = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    registry         = $REGISTRY" >&2
echo "    master addr      = $MASTER_ADDR" >&2
echo "    agent label      = $LABEL" >&2
echo "    agent addr       = $AGENT_ADDR" >&2
echo "    operator_omni    = 0x$OPERATOR_OMNI" >&2
echo "    actor_omni       = 0x$ACTOR_OMNI" >&2
echo "    deviceKeyHash    = $DEVICE_KEY_HASH" >&2

# Idempotency: use the contract's typed isActive view instead of slicing
# the raw getDevice() tuple at hard-coded hex offsets. The DeviceEntry
# struct grew in codex H1 (k11RpIdHash + k11PubX + k11PubY), shifting
# registeredAt's offset from 320 to 512 — silently breaking re-runs of the
# previous offset-based check. isActive(bytes32)(bool) is struct-agnostic.
log "Idempotency check: is this agent device already active?"
IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "false")
if [ "$IS_ACTIVE" = "true" ]; then
  skip "agent device already active on-chain — no-op"
  echo "{\"ok\":true,\"skipped\":\"already-registered\",\"label\":\"$LABEL\",\"agent_address\":\"$AGENT_ADDR\",\"actor_omni\":\"0x$ACTOR_OMNI\",\"device_key_hash\":\"$DEVICE_KEY_HASH\"}"
  exit 0
fi
ok "agent device not yet active → proceeding"

# agentPopSig: agent_wallet signs keccak("agentkeys-agent-pop:" || device_key_hash) —
# proof that the holder of the agent key consents to this device binding.
if [ -n "$FROM_AGENT_ADDR" ]; then
  # from-pubkey: the pop_sig was produced IN THE SANDBOX over the same payload
  # (agentkeys agent device-session). The master never had the key.
  AGENT_POP_SIG="$FROM_POP_SIG"
else
  POP_PAYLOAD_HEX=$(cast keccak "agentkeys-agent-pop:${DEVICE_KEY_HASH}")
  AGENT_POP_SIG=$(cast wallet sign --private-key "$AGENT_KEY" "$POP_PAYLOAD_HEX")
fi
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

# Resolve PENDING nonce for the master wallet — same protection as the
# heima-fund-account.sh fix in PR #102. If the prior run's registerAgentDevice
# tx is still in the mempool, the default `latest` nonce derivation collides.
PENDING_NONCE=$(cast nonce "$MASTER_ADDR" --rpc-url "$RPC_HTTP" --block pending 2>/dev/null || echo "")
if [ -n "$PENDING_NONCE" ]; then
  log "pending nonce for master = $PENDING_NONCE"
  CAST_ARGS+=(--nonce "$PENDING_NONCE")
fi

log "Submitting registerAgentDevice tx via cast send …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
if [ "$CAST_RC" != "0" ]; then
  if printf '%s\n' "$CAST_OUT" | grep -qi "replacement transaction underpriced"; then
    echo "    cast send FAILED: prior tx with same nonce is pending in Heima mempool." >&2
    echo "    Wait ~1 minute and re-run. Output:" >&2
  else
    echo "    cast send FAILED (exit $CAST_RC). Output:" >&2
  fi
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
