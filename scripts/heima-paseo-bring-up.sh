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
DEPLOYER_KEY_FILE="${HEIMA_PASEO_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-paseo-deployer.key}"

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
# Idempotency: persist the generated key to ~/.agentkeys/heima-paseo-deployer.key
# (mode 0600, OUTSIDE the repo so it's never accidentally committed) on
# first run; reuse it on every subsequent run. Override at any time by
# exporting HEIMA_PASEO_DEPLOYER_KEY in your shell.
echo "[3/7] Deployer keypair …"
if [ -n "${HEIMA_PASEO_DEPLOYER_KEY:-}" ]; then
  DEPLOYER_KEY="$HEIMA_PASEO_DEPLOYER_KEY"
  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY")
  echo "  reusing HEIMA_PASEO_DEPLOYER_KEY env var → $DEPLOYER_ADDR"
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
  echo "  WARNING: paseo-testnet key only — never reuse on mainnet."
fi
export HEIMA_PASEO_DEPLOYER_KEY="$DEPLOYER_KEY"

# 4. Sudo-fund from Alice -------------------------------------------------
# Idempotency: skip funding if the deployer already has >= 1 HEI. Re-fund
# only when balance is below the threshold (chain reset, drained, etc.).
if [ "${SKIP_FUND:-0}" = "1" ]; then
  echo "[4/7] Sudo-fund step SKIPPED via SKIP_FUND=1"
else
  CURRENT_BAL_HEX=$(curl -sS -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$DEPLOYER_ADDR\",\"latest\"],\"id\":1}" \
    "$RPC_HTTP" 2>/dev/null | jq -r .result || echo "0x0")
  # Use node (already a required dep) for BigInt-safe hex→decimal compare.
  # 10^18 wei = 1 HEI; if balance >= 1 HEI, skip funding.
  HAS_ENOUGH=$(node -e "process.stdout.write(BigInt('$CURRENT_BAL_HEX') >= 10n**18n ? 'true' : 'false')" 2>/dev/null || echo "false")
  if [ "$HAS_ENOUGH" = "true" ]; then
    CURRENT_BAL_HEI=$(node -e "console.log((Number(BigInt('$CURRENT_BAL_HEX') / 10n**14n) / 10000).toFixed(2))" 2>/dev/null || echo "?")
    echo "[4/7] Deployer already funded (~${CURRENT_BAL_HEI} pHEI ≥ 1) — skip Alice sudo transfer"
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
  BAL_HEI=$(node -e "console.log((Number(BigInt('$BAL_HEX') / 10n**14n) / 10000).toFixed(2))" 2>/dev/null || echo "?")
  echo "  funded; new balance ~$BAL_HEI pHEI ($BAL_HEX wei)"
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
env_set "HEIMA_PASEO_DEPLOYER_ADDR"                   "$DEPLOYER_ADDR"        "$ENV_FILE"
echo "  persisted (replaced existing or appended new — no duplicates)."

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
