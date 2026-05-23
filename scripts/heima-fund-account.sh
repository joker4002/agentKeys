#!/usr/bin/env bash
# scripts/heima-fund-account.sh — send HEI from the operator's master
# wallet (the same EVM wallet derived from ./test-hei mnemonic in
# heima-bring-up.sh step 3) to a fresh test account. Used to bootstrap
# agent wallets so they have gas before they submit their first tx.
#
# Idempotent: pre-checks the recipient's on-chain balance; if already
# >= --amount-hei, skips the transfer and exits 0 with `skipped` field.
#
# Usage:
#   bash scripts/heima-fund-account.sh --to 0xabc... [--amount-hei 1.0]
#   bash scripts/heima-fund-account.sh --to 0xabc... --amount-hei 0.05
#
# Env override flow (matches heima-bring-up.sh / heima-device-register.sh):
#   1. HEIMA_DEPLOYER_KEY=0x...          (raw 0x-prefixed private key)
#   2. HEIMA_DEPLOYER_MNEMONIC_FILE=<path>  (default: ./test-hei in repo root)
#   3. ~/.agentkeys/<chain>-deployer.key  (persisted cache)
#   4. error out — no fresh-key generation, this script never burns funds
#      to a brand-new wallet
#
# Chain selection: $AGENTKEYS_CHAIN (default heima). Reads
# operator-workstation.env for RPC URL.

set -euo pipefail

TO_ADDR=""
AMOUNT_HEI="1.0"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --to)            [ $# -lt 2 ] && { echo "--to requires a value" >&2; exit 1; }; TO_ADDR="$2"; shift 2 ;;
    --to=*)          TO_ADDR="${1#*=}"; shift ;;
    --amount-hei)    [ $# -lt 2 ] && { echo "--amount-hei requires a value" >&2; exit 1; }; AMOUNT_HEI="$2"; shift 2 ;;
    --amount-hei=*)  AMOUNT_HEI="${1#*=}"; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
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

[ -z "$TO_ADDR" ] && die "--to is required"
case "$TO_ADDR" in 0x*) ;; *) die "--to must start with 0x (got: $TO_ADDR)" ;; esac
[ "${#TO_ADDR}" = "42" ] || die "--to must be 42 chars (0x + 40 hex), got ${#TO_ADDR}"

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

# Deployer key resolution — same 3-way order as heima-bring-up.sh step 3.
# (No fresh-key fallback here; refusing to mint funds from a brand-new wallet.)
DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/${AGENTKEYS_CHAIN}-deployer.key}"
HEIMA_DEPLOYER_MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"

if [ -n "${HEIMA_DEPLOYER_KEY:-}" ]; then
  DEPLOYER_KEY="$HEIMA_DEPLOYER_KEY"
  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY")
elif [ -f "$HEIMA_DEPLOYER_MNEMONIC_FILE" ]; then
  if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
    log "Installing scripts/node_modules deps (first run only)…"
    npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund || die "npm install failed"
  fi
  DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$HEIMA_DEPLOYER_MNEMONIC_FILE") \
    || die "deriving deployer key from $HEIMA_DEPLOYER_MNEMONIC_FILE failed"
  DEPLOYER_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
  DEPLOYER_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
elif [ -f "$DEPLOYER_KEY_FILE" ]; then
  DEPLOYER_KEY=$(cat "$DEPLOYER_KEY_FILE")
  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY" 2>/dev/null) \
    || die "$DEPLOYER_KEY_FILE is corrupt"
else
  die "no deployer key found (HEIMA_DEPLOYER_KEY env, $HEIMA_DEPLOYER_MNEMONIC_FILE, or $DEPLOYER_KEY_FILE)"
fi

# cast --to-wei expects e.g. "1.0ether"; we always denominate in HEI (= 1e18 wei).
AMOUNT_WEI=$(cast to-wei "$AMOUNT_HEI" ether) || die "invalid --amount-hei: $AMOUNT_HEI"

log "Inputs"
echo "    chain         = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    rpc           = $RPC_HTTP" >&2
echo "    from          = $DEPLOYER_ADDR" >&2
echo "    to            = $TO_ADDR" >&2
echo "    amount        = $AMOUNT_HEI HEI ($AMOUNT_WEI wei)" >&2

# Idempotency: read recipient's current balance. If already >= amount, skip.
log "Idempotency check: recipient balance ≥ amount?"
CUR_WEI=$(cast balance "$TO_ADDR" --rpc-url "$RPC_HTTP" 2>/dev/null || echo 0)
if [ -z "$CUR_WEI" ] || ! [ "$CUR_WEI" -ge 0 ] 2>/dev/null; then CUR_WEI=0; fi

# bash arithmetic chokes on 18-digit numbers; use python for the compare.
if python3 -c "import sys; sys.exit(0 if int('$CUR_WEI') >= int('$AMOUNT_WEI') else 1)" 2>/dev/null; then
  CUR_HEI=$(cast from-wei "$CUR_WEI" ether 2>/dev/null || echo "?")
  skip "recipient already has $CUR_HEI HEI (≥ $AMOUNT_HEI) — no transfer needed"
  echo "{\"ok\":true,\"skipped\":\"already-funded\",\"to\":\"$TO_ADDR\",\"balance_wei\":\"$CUR_WEI\"}"
  exit 0
fi
ok "recipient has $CUR_WEI wei (< $AMOUNT_WEI) → proceeding"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would invoke:"
  printf '    cast send %s --value %s --rpc-url %s --chain-id %s --private-key [REDACTED]\n' \
    "$TO_ADDR" "$AMOUNT_WEI" "$RPC_HTTP" "$LIVE_CHAIN_ID" >&2
  echo "{\"ok\":true,\"dry_run\":true,\"to\":\"$TO_ADDR\",\"amount_wei\":\"$AMOUNT_WEI\"}"
  exit 0
fi

# Resolve PENDING nonce (defends against the race where a prior run's funding
# tx is still in the mempool — cast's default `latest` nonce derivation would
# collide with the stuck pending tx, surfacing as
# `replacement transaction underpriced`. PR #102 / codex adversarial review.)
log "Resolving pending nonce for $DEPLOYER_ADDR"
PENDING_NONCE=$(cast nonce "$DEPLOYER_ADDR" --rpc-url "$RPC_HTTP" --block pending 2>/dev/null || echo "")
if [ -z "$PENDING_NONCE" ]; then
  warn "could not resolve pending nonce — proceeding without explicit --nonce (cast will use latest)"
  NONCE_ARGS=()
else
  ok "pending nonce = $PENDING_NONCE"
  NONCE_ARGS=(--nonce "$PENDING_NONCE")
fi

log "Submitting transfer via cast send …"
set +e
SEND_OUT=$(cast send "$TO_ADDR" --value "$AMOUNT_WEI" \
  --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" \
  "${NONCE_ARGS[@]}" \
  --private-key "$DEPLOYER_KEY" 2>&1)
SEND_RC=$?
set -e
if [ "$SEND_RC" != "0" ]; then
  # Surface the underpriced-replacement case with a specific remediation —
  # the broader workflow-level concurrency lock SHOULD prevent this from
  # firing for parallel runs, but a stuck mempool tx still trips it.
  if printf '%s\n' "$SEND_OUT" | grep -qi "replacement transaction underpriced"; then
    echo "    cast send FAILED: prior tx with same nonce is pending in Heima mempool." >&2
    echo "    Wait ~1 minute for it to confirm or drop, then re-run. Output:" >&2
  else
    echo "    cast send FAILED (exit $SEND_RC). Output:" >&2
  fi
  echo "$SEND_OUT" >&2
  exit 1
fi

TX_HASH=$(printf '%s\n' "$SEND_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$SEND_OUT" | awk '/^blockNumber/ {print $2}' | head -1)
ok "funded — txhash $TX_HASH (block $BLOCK_NUM)"
echo "{\"ok\":true,\"to\":\"$TO_ADDR\",\"amount_wei\":\"$AMOUNT_WEI\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\"}"
