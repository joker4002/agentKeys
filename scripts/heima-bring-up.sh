#!/usr/bin/env bash
# heima-bring-up.sh — one-command Heima bring-up for the v2 stage-1 demo.
# Supports BOTH Heima mainnet (chain_id 212013) and Heima Paseo testnet
# (chain_id 2013). The paseo path uses Alice's sudo to auto-fund the
# deployer (no faucet wait); the mainnet path requires the operator to
# fund the deployer manually from their personal wallet (sudo is not
# available on mainnet by design).
#
# What it does, in order:
#   1. Sanity-check tools (agentkeys CLI, jq, forge, cast, node, npx)
#   2. Resolve the chain profile + reachability-check the RPC + verify
#      live eth_chainId matches the AGENTKEYS_CHAIN claim (catches
#      "you said paseo but the RPC is actually mainnet" footguns).
#   3. Generate or reuse a deployer keypair persisted at
#      ~/.agentkeys/<chain-name>-deployer.key (mode 0600).
#   4. Fund the deployer:
#      - paseo:   sudo via Alice (auto-tops-up Alice if low)
#      - mainnet: balance check; if low, print clear instructions to
#                 fund manually from operator's personal wallet + exit.
#                 NEVER auto-spends real HEI.
#   5. Foundry-deploy the four stage-1 contracts (AgentKeysScope,
#      SidecarRegistry, K3EpochCounter, CredentialAudit).
#      - Mainnet real deploy REQUIRES `MAINNET_CONFIRM=1` env var
#        (paranoid guard — accidental mainnet deploys cost real HEI).
#      - Stub mode (no crates/agentkeys-chain/ present) is a no-op
#        regardless of chain.
#   6. Persist contract addresses to operator-workstation.env, namespaced
#      by chain (SCOPE_CONTRACT_ADDRESS_HEIMA vs _HEIMA_PASEO).
#   7. Print "Demo ready" + addresses + suggested next steps.
#
# Usage:
#   AGENTKEYS_CHAIN=heima       bash scripts/heima-bring-up.sh    # mainnet
#   AGENTKEYS_CHAIN=heima-paseo bash scripts/heima-bring-up.sh    # testnet
#   bash scripts/heima-bring-up.sh                                # default (heima mainnet)
#
# Env overrides:
#   AGENTKEYS_CHAIN=heima|heima-paseo  (default: heima)
#   HEIMA_DEPLOYER_KEY=0x...      (skip step 3; reuse existing key)
#   FUND_AMOUNT_HEI=100           (paseo default; mainnet ignores)
#   MAINNET_CONFIRM=1             (REQUIRED to run real deploy on mainnet)
#   SKIP_FUND=1                   (skip step 4 entirely)
#   SKIP_DEPLOY=1                 (skip step 5 entirely)

set -euo pipefail

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
case "$AGENTKEYS_CHAIN" in
  heima|heima-paseo) ;;
  *) echo "ERROR: this script supports heima or heima-paseo only. Got: $AGENTKEYS_CHAIN" >&2; exit 1 ;;
esac
export AGENTKEYS_CHAIN

FUND_AMOUNT_HEI="${FUND_AMOUNT_HEI:-100}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
# Per-chain deployer key file: ~/.agentkeys/heima-deployer.key for mainnet,
# ~/.agentkeys/heima-paseo-deployer.key for testnet. Keeps the keys for
# the two chains separate so an operator who's used both doesn't
# accidentally reuse the testnet key on mainnet.
DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/${AGENTKEYS_CHAIN}-deployer.key}"

# Replace-or-append helper: keeps operator-workstation.env free of
# duplicate KEY= lines across re-runs. macOS sed needs `-i ''`;
# Linux sed needs `-i` (no arg). Probe `uname` once.
env_set() {
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    if [ "$(uname)" = "Darwin" ]; then
      sed -i '' -E "s|^${key}=.*|${key}=${val}|" "$file"
    else
      sed -i -E "s|^${key}=.*|${key}=${val}|" "$file"
    fi
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# Returns 0 if there's contract code at $1 on-chain, else 1. Empty
# `cast code` output, "0x" alone, or any error means "no code".
contract_exists_on_chain() {
  local addr="$1"
  [ -z "$addr" ] && return 1
  case "$addr" in
    0x0|0x00*|0x0000000000000000000000000000000000000000) return 1 ;;
  esac
  local code
  code=$(cast code "$addr" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "")
  [ -n "$code" ] && [ "$code" != "0x" ]
}

# 1. Tool sanity check ----------------------------------------------------
echo "[1/7] Checking required tools …"
for tool in agentkeys jq forge cast node npx; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "  MISSING: $tool — install it before re-running." >&2
    exit 1
  }
done
echo "  ok"

# 2. Profile + reachability -----------------------------------------------
echo "[2/7] Reading $AGENTKEYS_CHAIN chain profile …"
PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
SUBSTRATE_WSS=$(echo "$PROFILE_JSON" | jq -r .rpc.substrate_wss)
EXPECTED_CHAIN_ID=$(echo "$PROFILE_JSON" | jq -r .chain_id)
echo "  RPC_HTTP=$RPC_HTTP"
echo "  SUBSTRATE_WSS=$SUBSTRATE_WSS"
echo "  expected chain_id=$EXPECTED_CHAIN_ID (0 = auto-detect)"
echo

LIVE_CHAIN_ID_HEX=$(curl -sS -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "$RPC_HTTP" 2>/dev/null | jq -r '.result // empty')
if [ -z "$LIVE_CHAIN_ID_HEX" ]; then
  echo "  ERROR: cannot reach $RPC_HTTP. If this is heima mainnet, check network connectivity; if heima-paseo, the testnet may be halted —"
  echo "  see docs/spec/heima-open-questions.md Q13. Override via AGENTKEYS_CHAIN_PROFILE_FILE if you have the correct URL." >&2
  exit 1
fi
LIVE_CHAIN_ID=$(printf '%d' "$LIVE_CHAIN_ID_HEX")
echo "  live eth_chainId = $LIVE_CHAIN_ID_HEX (decimal $LIVE_CHAIN_ID)"
# Verify the live chain matches the AGENTKEYS_CHAIN claim. Mismatch is
# almost always an env-mistake (e.g. operator set AGENTKEYS_CHAIN=heima
# but the RPC URL in the profile points at paseo, OR vice versa). Fail
# loud so the operator doesn't accidentally deploy to the wrong chain.
case "$AGENTKEYS_CHAIN" in
  heima)
    if [ "$LIVE_CHAIN_ID" != "212013" ]; then
      echo "  ABORT: AGENTKEYS_CHAIN=heima (mainnet) but live chain_id=$LIVE_CHAIN_ID (expected 212013)" >&2
      exit 2
    fi
    echo "  MAINNET CONFIRMED (chain_id=212013). Real-money chain — operator confirmation required for any tx." >&2
    ;;
  heima-paseo)
    if [ "$LIVE_CHAIN_ID" = "212013" ]; then
      echo "  ABORT: AGENTKEYS_CHAIN=heima-paseo but live chain_id=212013 (that's mainnet). RPC misconfigured?" >&2
      exit 2
    fi
    if [ "$LIVE_CHAIN_ID" != "2013" ]; then
      echo "  WARN: AGENTKEYS_CHAIN=heima-paseo but live chain_id=$LIVE_CHAIN_ID (expected 2013). RPC drift?" >&2
    fi
    ;;
esac

# 3. Deployer keypair -----------------------------------------------------
# Idempotency: persist the generated key to
# ~/.agentkeys/<chain>-deployer.key (mode 0600, OUTSIDE the repo so it's
# never accidentally committed) on first run; reuse it on every
# subsequent run. Override at any time by exporting HEIMA_DEPLOYER_KEY
# in your shell. Per-chain key files keep mainnet + paseo keys distinct.
echo "[3/7] Deployer keypair …"
if [ -n "${HEIMA_DEPLOYER_KEY:-}" ]; then
  DEPLOYER_KEY="$HEIMA_DEPLOYER_KEY"
  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY")
  echo "  reusing HEIMA_DEPLOYER_KEY env var → $DEPLOYER_ADDR"
elif [ -f "$DEPLOYER_KEY_FILE" ]; then
  DEPLOYER_KEY=$(cat "$DEPLOYER_KEY_FILE")
  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY" 2>/dev/null) \
    || { echo "  ERROR: $DEPLOYER_KEY_FILE is corrupt — delete and re-run" >&2; exit 1; }
  echo "  reusing persisted key from $DEPLOYER_KEY_FILE → $DEPLOYER_ADDR"
else
  WALLET_JSON=$(cast wallet new --json | jq '.[0]')
  DEPLOYER_KEY=$(echo "$WALLET_JSON" | jq -r .private_key)
  DEPLOYER_ADDR=$(echo "$WALLET_JSON" | jq -r .address)
  mkdir -p "$(dirname "$DEPLOYER_KEY_FILE")"
  (umask 077 && printf '%s\n' "$DEPLOYER_KEY" > "$DEPLOYER_KEY_FILE")
  chmod 600 "$DEPLOYER_KEY_FILE"
  echo "  generated NEW deployer + persisted to $DEPLOYER_KEY_FILE (mode 0600)"
  echo "    address = $DEPLOYER_ADDR"
  if [ "$AGENTKEYS_CHAIN" = "heima" ]; then
    echo "  This is a fresh address with 0 HEI on Heima mainnet. Fund it from"
    echo "  your personal wallet before re-running (step 4 will instruct)."
  else
    echo "  WARNING: paseo-testnet key only — never reuse on mainnet."
  fi
fi
export HEIMA_DEPLOYER_KEY="$DEPLOYER_KEY"
# Legacy env-var alias kept for any operator scripts that still set
# HEIMA_PASEO_DEPLOYER_KEY directly. Removable once those are migrated.
export HEIMA_PASEO_DEPLOYER_KEY="$DEPLOYER_KEY"

# 4. Sudo-fund from Alice -------------------------------------------------
# Idempotency: skip funding if the deployer already has >= 1 HEI, or if
# we're in stub mode (no contracts to deploy → no gas needed). Re-fund
# only when balance is below the threshold (chain reset, drained, etc.).
#
# Stub-mode auto-skip: if crates/agentkeys-chain/ doesn't exist, step 5
# emits sentinel 0x1-0x4 addresses without ever submitting a tx — so
# funding the deployer is wasted (and on a low-Alice testnet like Paseo
# today, where Alice is drained to <1 HEI, requesting 100 HEI would
# submit a tx that no validator can include because Alice can't cover
# the value).
if [ "${SKIP_FUND:-0}" = "1" ]; then
  echo "[4/7] Fund step SKIPPED via SKIP_FUND=1"
elif [ ! -d "$REPO_ROOT/crates/agentkeys-chain" ]; then
  echo "[4/7] Fund step SKIPPED — stub mode (no crates/agentkeys-chain). Deployer needs no gas for sentinel addresses."
  echo "       Set SKIP_FUND=0 explicitly + provide crates/agentkeys-chain/ to enable real funding."
else
  # Shared balance check (both chains): is the deployer already funded
  # enough for the deploy? Threshold: 1 HEI is plenty for stage-1's four
  # contracts on either chain.
  CURRENT_BAL_HEX=$(curl -sS -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$DEPLOYER_ADDR\",\"latest\"],\"id\":1}" \
    "$RPC_HTTP" 2>/dev/null | jq -r .result || echo "0x0")
  HAS_ENOUGH=$(node -e "process.stdout.write(BigInt('$CURRENT_BAL_HEX') >= 10n**18n ? 'true' : 'false')" 2>/dev/null || echo "false")
  CURRENT_BAL_HEI=$(node -e "console.log((Number(BigInt('$CURRENT_BAL_HEX') / 10n**14n) / 10000).toFixed(4))" 2>/dev/null || echo "?")
  if [ "$HAS_ENOUGH" = "true" ]; then
    echo "[4/7] Deployer already has ~$CURRENT_BAL_HEI HEI (≥ 1) — skip funding"
  elif [ "$AGENTKEYS_CHAIN" = "heima-paseo" ]; then
    # Paseo path: sudo-fund via Alice. The .mjs's cmdFund auto-tops-up
    # Alice via forceSetBalance if she's drained — Alice IS the sudoer
    # and can mint to herself on Paseo. Deps via scripts/package.json
    # (npm install --prefix scripts on first run).
    echo "[4/7] Sudo-funding $DEPLOYER_ADDR with $FUND_AMOUNT_HEI HEI from Alice (paseo) …"
    if [ ! -d "$REPO_ROOT/scripts/node_modules/@polkadot/api" ]; then
      echo "  installing @polkadot/* into scripts/node_modules (first run only — ~30s) …"
      npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund \
        || { echo "  ERROR: npm install --prefix scripts failed" >&2; exit 1; }
    fi
    node "$REPO_ROOT/scripts/heima-paseo-sudo.mjs" \
        fund --recipient "$DEPLOYER_ADDR" --amount-hei "$FUND_AMOUNT_HEI"
    BAL_HEX=$(curl -sS -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$DEPLOYER_ADDR\",\"latest\"],\"id\":1}" \
      "$RPC_HTTP" | jq -r .result)
    BAL_HEI=$(node -e "console.log((Number(BigInt('$BAL_HEX') / 10n**14n) / 10000).toFixed(4))" 2>/dev/null || echo "?")
    echo "  funded; new balance ~$BAL_HEI HEI ($BAL_HEX wei)"
  else
    # Mainnet path: no sudo, no Alice, no auto-fund. The operator must
    # transfer real HEI from their personal wallet to the deployer.
    # Print everything they need to do it + exit. Re-running after the
    # transfer detects the new balance and proceeds to step 5.
    cat >&2 <<EOM
[4/7] Deployer NOT yet funded (~$CURRENT_BAL_HEI HEI < 1 HEI threshold).

  Heima MAINNET has no sudo — Alice cannot mint HEI to your deployer.
  You must transfer real HEI from your personal wallet to the deployer.

  Deployer address:   $DEPLOYER_ADDR
  Minimum amount:     1 HEI  (covers stage-1's four-contract deploy + buffer)
  Mainnet RPC:        $RPC_HTTP
  Mainnet explorer:   https://heima.statescan.io/

  Suggested funding methods, in order of friction:
    1. Your existing Heima wallet (MetaMask, Polkadot.js Apps with
       prefix 31, or any EVM wallet pointed at Heima mainnet) — send
       1 HEI to $DEPLOYER_ADDR. Confirm via explorer.
    2. Heima dev-team faucet (if available) — ask in the Heima/Litentry
       community channels with the deployer address.

  Once funding lands (verify via:
    curl -sS -H 'Content-Type: application/json' \\
      -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["$DEPLOYER_ADDR","latest"],"id":1}' \\
      "$RPC_HTTP" | jq -r .result
  ), re-run this script. Step 4 will auto-detect the balance and skip.
EOM
    exit 1
  fi
fi

# 5. Foundry deploy --------------------------------------------------------
# Idempotency: read the 4 contract addresses stored in operator-workstation.env
# from a prior run, then `cast code` each against the live chain. If all 4
# have on-chain code (i.e. the contracts still exist at those addresses),
# skip the deploy entirely. If any address is missing, has the 0x0 sentinel,
# OR returns "0x" (no code) from the chain, redeploy all 4. This handles the
# chain-reset case automatically.
if [ "${SKIP_DEPLOY:-0}" = "1" ]; then
  echo "[5/7] Contract deploy SKIPPED via SKIP_DEPLOY=1"
else
  echo "[5/7] Foundry-deploying four stage-1 contracts …"

  # Re-source env file so we see addresses from prior runs (this run may have
  # appended new vars to ENV_FILE; we want the latest values).
  set -a; . "$ENV_FILE"; set +a
  PROFILE_NAME_UC=$(echo "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')

  ALL_DEPLOYED=1
  for slot in \
      "SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC}:AgentKeysScope" \
      "SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:SidecarRegistry" \
      "K3_EPOCH_COUNTER_ADDRESS_${PROFILE_NAME_UC}:K3EpochCounter" \
      "CREDENTIAL_AUDIT_ADDRESS_${PROFILE_NAME_UC}:CredentialAudit"; do
    var="${slot%%:*}"
    name="${slot##*:}"
    eval "stored_addr=\${$var:-}"
    if [ -z "$stored_addr" ] || [ "$stored_addr" = "0x0" ]; then
      echo "  $name ($var) not in env yet → deploy needed"
      ALL_DEPLOYED=0
      break
    fi
    if contract_exists_on_chain "$stored_addr"; then
      echo "  $name = $stored_addr ✓ has code on-chain"
    else
      echo "  $name = $stored_addr ✗ NO code on-chain (chain reset?) → redeploy"
      ALL_DEPLOYED=0
      break
    fi
  done

  if [ "$ALL_DEPLOYED" = "1" ]; then
    echo "  ALL 4 contracts already deployed + verified on-chain → skip deploy"
    SCOPE_ADDR="$(eval echo \$SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC})"
    REGISTRY_ADDR="$(eval echo \$SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC})"
    EPOCH_ADDR="$(eval echo \$K3_EPOCH_COUNTER_ADDRESS_${PROFILE_NAME_UC})"
    AUDIT_ADDR="$(eval echo \$CREDENTIAL_AUDIT_ADDRESS_${PROFILE_NAME_UC})"
  else
    CHAIN_DIR="$REPO_ROOT/crates/agentkeys-chain"
    if [ ! -d "$CHAIN_DIR" ]; then
      echo "  NOTE: crates/agentkeys-chain not present yet (chain crate is pending in stage-1)."
      echo "  Stub addresses below for downstream env-file persistence; replace post-deploy:"
      SCOPE_ADDR="0x0000000000000000000000000000000000000001"
      REGISTRY_ADDR="0x0000000000000000000000000000000000000002"
      EPOCH_ADDR="0x0000000000000000000000000000000000000003"
      AUDIT_ADDR="0x0000000000000000000000000000000000000004"
      echo "  (stub addresses never have on-chain code; subsequent runs will detect this and 'redeploy' the same stubs — no real chain side-effect.)"
    else
      # Mainnet safety: real `forge script ... --broadcast` on Heima
      # mainnet spends real HEI. Require MAINNET_CONFIRM=1 as a
      # paranoid second gate so an operator can't accidentally deploy
      # contracts to production while testing the orchestrator.
      if [ "$AGENTKEYS_CHAIN" = "heima" ] && [ "${MAINNET_CONFIRM:-0}" != "1" ]; then
        cat >&2 <<EOM
[5/7] REFUSING — about to broadcast a real deploy to Heima MAINNET.

  This will:
    - Spend real HEI from deployer $DEPLOYER_ADDR
    - Permanently deploy 4 contracts at addresses you'll need to trust
    - Be irreversible

  If that's truly what you want, re-run with:
    MAINNET_CONFIRM=1 $0
  OR for partial control:
    MAINNET_CONFIRM=1 SKIP_DEPLOY=0 bash scripts/v2-stage1-demo.sh --only-step 9

  For testing the orchestrator without spending HEI, omit
  crates/agentkeys-chain/ (the script falls back to stub-mode
  sentinel addresses, no on-chain side effects).
EOM
        exit 1
      fi
      cd "$CHAIN_DIR"
      DEPLOY_OUT=$(forge script script/DeployAgentKeysV1.s.sol \
        --rpc-url "$RPC_HTTP" \
        --chain-id "$LIVE_CHAIN_ID" \
        --private-key "$DEPLOYER_KEY" \
        --broadcast 2>&1)
      SCOPE_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'AgentKeysScope:\s+0x[a-fA-F0-9]{40}' | awk '{print $NF}')
      REGISTRY_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'SidecarRegistry:\s+0x[a-fA-F0-9]{40}' | awk '{print $NF}')
      EPOCH_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'K3EpochCounter:\s+0x[a-fA-F0-9]{40}' | awk '{print $NF}')
      AUDIT_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'CredentialAudit:\s+0x[a-fA-F0-9]{40}' | awk '{print $NF}')
      cd "$REPO_ROOT"
    fi
  fi
  echo "  AgentKeysScope    = $SCOPE_ADDR"
  echo "  SidecarRegistry   = $REGISTRY_ADDR"
  echo "  K3EpochCounter    = $EPOCH_ADDR"
  echo "  CredentialAudit   = $AUDIT_ADDR"
fi

# 6. Persist addresses to operator env file -------------------------------
# Idempotent: env_set replaces existing KEY= lines or appends if absent.
# Re-running the script never duplicates lines, no matter how many runs.
echo "[6/7] Persisting contract addresses to $ENV_FILE …"
PROFILE_NAME_UC=$(echo "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
env_set "SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC}"   "${SCOPE_ADDR:-0x0}"    "$ENV_FILE"
env_set "SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}" "${REGISTRY_ADDR:-0x0}" "$ENV_FILE"
env_set "K3_EPOCH_COUNTER_ADDRESS_${PROFILE_NAME_UC}" "${EPOCH_ADDR:-0x0}"    "$ENV_FILE"
env_set "CREDENTIAL_AUDIT_ADDRESS_${PROFILE_NAME_UC}" "${AUDIT_ADDR:-0x0}"    "$ENV_FILE"
env_set "HEIMA_DEPLOYER_ADDR_${PROFILE_NAME_UC}"       "$DEPLOYER_ADDR"        "$ENV_FILE"
echo "  persisted (replaced existing or appended new — no duplicates)."

# 7. Summary --------------------------------------------------------------
echo "[7/7] Demo ready."
echo
echo "Chain:       $AGENTKEYS_CHAIN (chain_id=$LIVE_CHAIN_ID)"
echo "RPC:         $RPC_HTTP"
echo "Deployer:    $DEPLOYER_ADDR"
echo "Contracts:"
echo "  AgentKeysScope    = ${SCOPE_ADDR:-pending}"
echo "  SidecarRegistry   = ${REGISTRY_ADDR:-pending}"
echo "  K3EpochCounter    = ${EPOCH_ADDR:-pending}"
echo "  CredentialAudit   = ${AUDIT_ADDR:-pending}"
echo
echo "Next steps (see docs/v2-stage1-migration-and-demo.md):"
echo "  source $ENV_FILE"
echo "  agentkeys --chain $AGENTKEYS_CHAIN --session-id alice device register \\"
echo "    --registry-address \$SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC} \\"
echo "    --roles cap-mint,recovery,scope-mgmt"
echo
echo "Re-run with SKIP_FUND=1 or SKIP_DEPLOY=1 to skip individual phases."
