#!/usr/bin/env bash
# scripts/heima-k3-rotate.sh — operator-driven K3 epoch rotation.
#
# Calls K3EpochCounter.advanceEpoch() on the chain (per arch.md §16).
# After rotation:
#   - new writes use K3_v[N+1] for KEK derivation
#   - on-read decryption for old blobs uses K3_v[N] retained inside the
#     signer enclave; workers re-encrypt under K3_v[N+1] lazily (or via
#     the operator-driven eager re-encrypt tool — separate script)
#
# This script only signs from the signerGovernance address. In stage 2
# that's a single EOA (the deployer wallet by default). Stage 3 swaps
# in an M-of-N multisig; this script then becomes a multisig submit-and-
# wait wrapper.
#
# Idempotency: pre-reads currentEpoch. If a target epoch is passed
# (--target-epoch N) and currentEpoch >= N, skips. Otherwise advances by
# exactly one.
#
# Usage:
#   bash scripts/heima-k3-rotate.sh
#   bash scripts/heima-k3-rotate.sh --target-epoch 5
#   bash scripts/heima-k3-rotate.sh --dry-run

set -euo pipefail

TARGET_EPOCH=""
COUNTER_ADDR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --target-epoch)        TARGET_EPOCH="$2"; shift 2 ;;
    --target-epoch=*)      TARGET_EPOCH="${1#*=}"; shift ;;
    --counter-address)     COUNTER_ADDR="$2"; shift 2 ;;
    --counter-address=*)   COUNTER_ADDR="${1#*=}"; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
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

if [ -z "$COUNTER_ADDR" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "COUNTER_ADDR=\${K3_EPOCH_COUNTER_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$COUNTER_ADDR" ] && die "--counter-address required (or set K3_EPOCH_COUNTER_ADDRESS_*)"

MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
SIGNER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")

# Pre-read current state.
CURRENT_EPOCH=$(cast call "$COUNTER_ADDR" "currentEpoch()(uint256)" --rpc-url "$RPC_HTTP")
GOV_ADDR=$(cast call "$COUNTER_ADDR" "signerGovernance()(address)" --rpc-url "$RPC_HTTP")
GOV_ADDR_LC=$(printf '%s' "$GOV_ADDR" | tr '[:upper:]' '[:lower:]')
SIGNER_ADDR_LC=$(printf '%s' "$SIGNER_ADDR" | tr '[:upper:]' '[:lower:]')

log "Pre-flight"
echo "    K3EpochCounter   = $COUNTER_ADDR" >&2
echo "    chain            = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    currentEpoch     = $CURRENT_EPOCH" >&2
echo "    signerGovernance = $GOV_ADDR" >&2
echo "    signing as       = $SIGNER_ADDR" >&2

if [ "$SIGNER_ADDR_LC" != "$GOV_ADDR_LC" ]; then
  die "deployer ($SIGNER_ADDR) is NOT the K3 signerGovernance ($GOV_ADDR). Cannot rotate."
fi

# Compute steps to advance.
if [ -n "$TARGET_EPOCH" ]; then
  if [ "$CURRENT_EPOCH" -ge "$TARGET_EPOCH" ]; then
    skip "currentEpoch ($CURRENT_EPOCH) already >= target ($TARGET_EPOCH)"
    echo "{\"ok\":true,\"skipped\":\"already-at-target\",\"current_epoch\":$CURRENT_EPOCH}"
    exit 0
  fi
  STEPS=$((TARGET_EPOCH - CURRENT_EPOCH))
else
  STEPS=1
  TARGET_EPOCH=$((CURRENT_EPOCH + 1))
fi
log "advancing $STEPS epoch(s) ($CURRENT_EPOCH → $TARGET_EPOCH)"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would invoke advanceEpoch() $STEPS time(s)"
  echo "{\"ok\":true,\"dry_run\":true,\"current_epoch\":$CURRENT_EPOCH,\"target_epoch\":$TARGET_EPOCH,\"steps\":$STEPS}"
  exit 0
fi

# Advance one epoch at a time. Each advanceEpoch() emits a K3Rotated
# event that workers + signer enclave consume to switch to the new
# epoch for new writes.
TX_HASHES=()
for ((i=1; i<=STEPS; i++)); do
  log "Submitting advanceEpoch() tx ($i/$STEPS)…"
  CAST_OUT=$(cast send "$COUNTER_ADDR" "advanceEpoch()" \
    --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" --private-key "$MASTER_KEY" 2>&1) \
    || { echo "$CAST_OUT" >&2; die "cast send failed at step $i"; }
  TX=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
  TX_HASHES+=("$TX")
  ok "step $i tx=$TX"
done

FINAL_EPOCH=$(cast call "$COUNTER_ADDR" "currentEpoch()(uint256)" --rpc-url "$RPC_HTTP")
ok "rotation complete — currentEpoch=$FINAL_EPOCH"

# Compact JSON output for downstream tooling.
HASHES_JSON=$(printf '"%s",' "${TX_HASHES[@]}" | sed 's/,$//')
echo "{\"ok\":true,\"prev_epoch\":$CURRENT_EPOCH,\"new_epoch\":$FINAL_EPOCH,\"tx_hashes\":[$HASHES_JSON]}"
