#!/usr/bin/env bash
# heima-paseo-bring-up.sh — one-command Heima Paseo bring-up for the v2 stage-1
# demo, using Alice's sudo to skip every manual step that would normally
# require faucet wait / browser clicks / multi-step coordination.
#
# What it does, in order:
#   1. Sanity-check tools (agentkeys CLI, jq, forge, node, npx)
#   2. Resolve the heima-paseo chain profile + reachability-check the RPC
#   3. Generate a throwaway EVM deployer keypair (or reuse $HEIMA_PASEO_DEPLOYER_*)
#   4. Sudo-fund the deployer from Alice with 100 pHEI
#   5. Foundry-deploy the four stage-1 contracts (AgentKeysScope,
#      SidecarRegistry, K3EpochCounter, CredentialAudit)
#   6. Persist contract addresses into operator-workstation.env namespaced by
#      chain profile (so other chains can deploy alongside)
#   7. Print "Demo ready" + addresses + suggested next steps
#
# Refuses to run against Heima mainnet — paseo only.
#
# Usage:
#   bash scripts/heima-paseo-bring-up.sh
#
# Env overrides:
#   AGENTKEYS_CHAIN=heima-paseo  (default; refuses any other value)
#   HEIMA_PASEO_DEPLOYER_KEY=0x... (skip step 3; reuse existing key)
#   FUND_AMOUNT_HEI=100  (default funding)
#   SKIP_FUND=1  (skip step 4 — useful if deployer is already funded)
#   SKIP_DEPLOY=1  (skip step 5 — useful for repeat runs)

set -euo pipefail

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima-paseo}"
if [ "$AGENTKEYS_CHAIN" != "heima-paseo" ]; then
  echo "ERROR: this script is paseo-only. Re-run with AGENTKEYS_CHAIN=heima-paseo." >&2
  exit 1
fi
export AGENTKEYS_CHAIN

FUND_AMOUNT_HEI="${FUND_AMOUNT_HEI:-100}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"

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
echo "[2/7] Reading heima-paseo chain profile …"
PROFILE_JSON=$(agentkeys chain show heima-paseo)
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
  echo "  ERROR: cannot reach $RPC_HTTP. The heima-paseo RPC URL is pending Heima dev-team confirmation —"
  echo "  see docs/spec/heima-open-questions.md Q13. Override via AGENTKEYS_CHAIN_PROFILE_FILE if you have the correct URL." >&2
  exit 1
fi
LIVE_CHAIN_ID=$(printf '%d' "$LIVE_CHAIN_ID_HEX")
echo "  live eth_chainId = $LIVE_CHAIN_ID_HEX (decimal $LIVE_CHAIN_ID)"
if [ "$LIVE_CHAIN_ID" = "212013" ]; then
  echo "  ABORT: connected to Heima MAINNET (chain_id=212013). Paseo only." >&2
  exit 2
fi

# 3. Deployer keypair -----------------------------------------------------
echo "[3/7] Deployer keypair …"
if [ -n "${HEIMA_PASEO_DEPLOYER_KEY:-}" ]; then
  DEPLOYER_KEY="$HEIMA_PASEO_DEPLOYER_KEY"
  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY")
  echo "  reusing existing HEIMA_PASEO_DEPLOYER_KEY → $DEPLOYER_ADDR"
else
  WALLET_JSON=$(cast wallet new --json | jq '.[0]')
  DEPLOYER_KEY=$(echo "$WALLET_JSON" | jq -r .private_key)
  DEPLOYER_ADDR=$(echo "$WALLET_JSON" | jq -r .address)
  echo "  generated throwaway deployer:"
  echo "    address = $DEPLOYER_ADDR"
  echo "    key     = $DEPLOYER_KEY"
  echo "  WARNING: this key is in shell history; do NOT use it on mainnet."
fi
export HEIMA_PASEO_DEPLOYER_KEY="$DEPLOYER_KEY"

# 4. Sudo-fund from Alice -------------------------------------------------
if [ "${SKIP_FUND:-0}" = "1" ]; then
  echo "[4/7] Sudo-fund step SKIPPED via SKIP_FUND=1"
else
  echo "[4/7] Sudo-funding $DEPLOYER_ADDR with $FUND_AMOUNT_HEI pHEI from Alice …"
  # The .mjs script needs @polkadot/api + friends. The earlier
  # `npx --package=X -y -- node script.mjs` shape was wrong: npx
  # --package only puts the package's BIN files on PATH; the script's
  # `import()` resolves via Node's module resolution algorithm, which
  # walks UP from the script's location looking for node_modules — and
  # there's no node_modules in $REPO_ROOT/scripts/ unless we put one
  # there. So we install the deps into scripts/node_modules once
  # (idempotent — npm install is a no-op when deps are already
  # current), then invoke `node` directly. The deps are declared in
  # scripts/package.json.
  if [ ! -d "$REPO_ROOT/scripts/node_modules/@polkadot/api" ]; then
    echo "  installing @polkadot/* into scripts/node_modules (first run only — ~30s) …"
    npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund \
      || { echo "  ERROR: npm install --prefix scripts failed" >&2; exit 1; }
  fi
  node "$REPO_ROOT/scripts/heima-paseo-sudo.mjs" \
      fund --recipient "$DEPLOYER_ADDR" --amount-hei "$FUND_AMOUNT_HEI"

  # Verify the balance landed
  BAL_HEX=$(curl -sS -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$DEPLOYER_ADDR\",\"latest\"],\"id\":1}" \
    "$RPC_HTTP" | jq -r .result)
  BAL_HEI=$(printf 'scale=2; ibase=16; %s / (10^18)\n' "$(echo $BAL_HEX | sed 's/^0x//' | tr 'a-f' 'A-F')" | bc 2>/dev/null || echo "?")
  echo "  funded; new balance ~$BAL_HEI pHEI ($BAL_HEX wei)"
fi

# 5. Foundry deploy --------------------------------------------------------
if [ "${SKIP_DEPLOY:-0}" = "1" ]; then
  echo "[5/7] Contract deploy SKIPPED via SKIP_DEPLOY=1"
else
  echo "[5/7] Foundry-deploying four stage-1 contracts …"
  CHAIN_DIR="$REPO_ROOT/crates/agentkeys-chain"
  if [ ! -d "$CHAIN_DIR" ]; then
    echo "  NOTE: crates/agentkeys-chain not present yet (chain crate is pending in stage-1)."
    echo "  Stub addresses below for downstream env-file persistence; replace post-deploy:"
    SCOPE_ADDR="0x0000000000000000000000000000000000000001"
    REGISTRY_ADDR="0x0000000000000000000000000000000000000002"
    EPOCH_ADDR="0x0000000000000000000000000000000000000003"
    AUDIT_ADDR="0x0000000000000000000000000000000000000004"
  else
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
  echo "  AgentKeysScope    = $SCOPE_ADDR"
  echo "  SidecarRegistry   = $REGISTRY_ADDR"
  echo "  K3EpochCounter    = $EPOCH_ADDR"
  echo "  CredentialAudit   = $AUDIT_ADDR"
fi

# 6. Persist addresses to operator env file -------------------------------
echo "[6/7] Persisting contract addresses to $ENV_FILE …"
PROFILE_NAME_UC=$(echo "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
{
  echo
  echo "# === Stage 1 chain contracts on $PROFILE_NAME_UC (deployed $(date +%Y-%m-%d via heima-paseo-bring-up.sh)) ==="
  echo "SCOPE_CONTRACT_ADDRESS_$PROFILE_NAME_UC=${SCOPE_ADDR:-0x0}"
  echo "SIDECAR_REGISTRY_ADDRESS_$PROFILE_NAME_UC=${REGISTRY_ADDR:-0x0}"
  echo "K3_EPOCH_COUNTER_ADDRESS_$PROFILE_NAME_UC=${EPOCH_ADDR:-0x0}"
  echo "CREDENTIAL_AUDIT_ADDRESS_$PROFILE_NAME_UC=${AUDIT_ADDR:-0x0}"
  echo "HEIMA_PASEO_DEPLOYER_ADDR=$DEPLOYER_ADDR"
} >> "$ENV_FILE"
echo "  appended."

# 7. Summary --------------------------------------------------------------
echo "[7/7] Demo ready."
echo
echo "Chain:       heima-paseo (chain_id=$LIVE_CHAIN_ID)"
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
echo "  agentkeys --chain heima-paseo --session-id alice device register \\"
echo "    --registry-address \$SIDECAR_REGISTRY_ADDRESS_HEIMA_PASEO \\"
echo "    --roles cap-mint,recovery,scope-mgmt"
echo
echo "Re-run with SKIP_FUND=1 or SKIP_DEPLOY=1 to skip individual phases."
