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
#   FORCE_DEPLOY=1                (deploy fresh even when an env address is
#                                 0x0/empty — only for a brand-NEW chain; the
#                                 default REFUSES, to avoid duplicate deploys)

set -euo pipefail

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
case "$AGENTKEYS_CHAIN" in
  heima|heima-paseo) ;;
  *) echo "ERROR: this script supports heima or heima-paseo only. Got: $AGENTKEYS_CHAIN" >&2; exit 1 ;;
esac
export AGENTKEYS_CHAIN

FUND_AMOUNT_HEI="${FUND_AMOUNT_HEI:-100}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# ENV_FILE: caller-supplied (e.g. setup-heima.sh --test exports
# operator-workstation.test.env) takes precedence; falls back to prod.
# CRITICAL for idempotency: this is BOTH the source of `*_HEIMA` addresses
# for the cast-code skip-deploy check (line ~295) AND the destination of
# newly-deployed addresses written by env_set in step 6 (line ~413). A
# test invocation pointed at the prod env file silently short-circuits
# (prod addrs already on-chain → skip deploy → no test contracts created),
# OR clobbers prod's contract pointers when it does write. Honor the
# caller's choice.
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
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
  local addr="$1" code
  [ -z "$addr" ] && return 1
  case "$addr" in
    0x0|0x00*|0x0000000000000000000000000000000000000000) return 1 ;;
  esac
  # Distinguish "RPC said no code" from "RPC errored". On an RPC error we must
  # NOT report "no code" — that would make the caller redeploy (a DUPLICATE)
  # just because the RPC blipped. Fail safe: assume the contract still exists.
  if code=$(cast code "$addr" --rpc-url "$RPC_HTTP" 2>/dev/null); then
    [ -n "$code" ] && [ "$code" != "0x" ]
  else
    echo "  WARN: cast code $addr failed (RPC error) — assuming deployed (won't redeploy)" >&2
    return 0
  fi
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
# Resolution order for the deployer key:
#   1. $HEIMA_DEPLOYER_KEY env var (raw 0x-prefixed private key)
#   2. $HEIMA_DEPLOYER_MNEMONIC_FILE pointing at a BIP-39 mnemonic file
#      (default: ./test-hei in the repo root if it exists)
#   3. Existing persisted key file at ~/.agentkeys/<chain>-deployer.key
#   4. Generate a fresh throwaway key, persist it for future re-runs
#
# Path 2 (mnemonic file) is the recommended approach for mainnet so
# the operator can bring their OWN wallet and never have to copy a raw
# private key around. The .mjs derivation uses ethers' BIP-44 path
# m/44'/60'/0'/0/0 (same as MetaMask / Foundry / ethers default).
HEIMA_DEPLOYER_MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"

echo "[3/7] Deployer keypair …"
if [ -n "${HEIMA_DEPLOYER_KEY:-}" ]; then
  DEPLOYER_KEY="$HEIMA_DEPLOYER_KEY"
  DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_KEY")
  echo "  reusing HEIMA_DEPLOYER_KEY env var → $DEPLOYER_ADDR"
elif [ -f "$HEIMA_DEPLOYER_MNEMONIC_FILE" ]; then
  echo "  deriving deployer from mnemonic at $HEIMA_DEPLOYER_MNEMONIC_FILE …"
  # Ensure ethers is installed in scripts/node_modules (idempotent).
  if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
    echo "  installing ethers into scripts/node_modules (first run only — ~10s) …"
    npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund \
      || { echo "  ERROR: npm install --prefix scripts failed" >&2; exit 1; }
  fi
  DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$HEIMA_DEPLOYER_MNEMONIC_FILE") \
    || { echo "  ERROR: mnemonic derivation failed — see stderr above" >&2; exit 1; }
  DEPLOYER_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
  DEPLOYER_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
  # Stash the derived EVM key in the per-chain file so subsequent runs
  # (or other tools like Foundry) pick it up without re-deriving. mode
  # 0600 — never world-readable.
  mkdir -p "$(dirname "$DEPLOYER_KEY_FILE")"
  (umask 077 && printf '%s\n' "$DEPLOYER_KEY" > "$DEPLOYER_KEY_FILE")
  chmod 600 "$DEPLOYER_KEY_FILE"
  echo "  derived EVM address $DEPLOYER_ADDR; cached private key at $DEPLOYER_KEY_FILE (0600)"
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
    echo "  TIP: drop a BIP-39 mnemonic at ./test-hei to use your own wallet"
    echo "       (auto-detected next run; never committed — see .gitignore)."
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
  DEPLOY_REASON=""   # "unknown-address" (env 0x0/empty) vs "no-onchain-code" (chain reset)
  for slot in \
      "SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC}:AgentKeysScope" \
      "SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:SidecarRegistry" \
      "K3_EPOCH_COUNTER_ADDRESS_${PROFILE_NAME_UC}:K3EpochCounter" \
      "CREDENTIAL_AUDIT_ADDRESS_${PROFILE_NAME_UC}:CredentialAudit"; do
    var="${slot%%:*}"
    name="${slot##*:}"
    eval "stored_addr=\${$var:-}"
    if [ -z "$stored_addr" ] || [ "$stored_addr" = "0x0" ]; then
      echo "  $name ($var) has no address in env (0x0/empty) — address UNKNOWN"
      ALL_DEPLOYED=0; DEPLOY_REASON="unknown-address"
      break
    fi
    if contract_exists_on_chain "$stored_addr"; then
      echo "  $name = $stored_addr ✓ has code on-chain"
    else
      echo "  $name = $stored_addr ✗ NO code on-chain (chain reset?) → redeploy"
      ALL_DEPLOYED=0; DEPLOY_REASON="no-onchain-code"
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
    # SAFETY — never create DUPLICATE contracts. If we're here because an env
    # address is 0x0/empty (address UNKNOWN), the contracts are very likely
    # already deployed and this would mint a costly duplicate set (it orphaned
    # a mainnet deploy once, via the SKIP_DEPLOY persist-clobber now fixed in
    # step 6). Refuse unless the operator explicitly wants a genuinely-fresh
    # deploy on a NEW chain.
    if [ "$DEPLOY_REASON" = "unknown-address" ] && [ "${FORCE_DEPLOY:-0}" != "1" ]; then
      echo "  REFUSING to deploy — a contract address is 0x0/empty in $ENV_FILE (address unknown)." >&2
      echo "  The contracts are most likely ALREADY deployed; deploying now would DUPLICATE them." >&2
      echo "  • Env accidentally zeroed? Restore it:  git checkout -- $ENV_FILE" >&2
      echo "    (canonical addresses are in docs/spec/deployed-contracts.md)." >&2
      echo "  • Genuinely-fresh deploy on a NEW chain? Re-run with FORCE_DEPLOY=1." >&2
      exit 1
    fi
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
      # Auto-init forge-std submodule if missing. `git pull` doesn't
      # populate submodules; without forge-std, `forge build` fails with
      # an obscure import error. We initialize on-demand here so the
      # operator doesn't need to know about submodule conventions.
      if [ ! -f "$CHAIN_DIR/lib/forge-std/src/Test.sol" ]; then
        echo "  initializing forge-std submodule (first run only) …"
        ( cd "$REPO_ROOT" && git submodule update --init --recursive --quiet ) \
          || { echo "  ERROR: git submodule update failed — install git + retry" >&2; exit 1; }
      fi
      cd "$CHAIN_DIR"
      echo "  invoking: forge script DeployAgentKeysV1.s.sol → $RPC_HTTP (chain $LIVE_CHAIN_ID)"
      # Run forge in two stages so we can:
      #   (a) print its output verbatim regardless of success/failure
      #       (DEPLOY_OUT captured via 2>&1; on success we parse, on
      #       failure we display the error)
      #   (b) check its exit code explicitly (bash $() doesn't trigger
      #       set -e on inner-command non-zero, and the later `grep -oE`
      #       returning empty would trip pipefail and kill the script
      #       BEFORE we ever see forge's actual error message)
      set +e
      DEPLOY_OUT=$(forge script script/DeployAgentKeysV1.s.sol \
        --rpc-url "$RPC_HTTP" \
        --chain-id "$LIVE_CHAIN_ID" \
        --private-key "$DEPLOYER_KEY" \
        --broadcast 2>&1)
      FORGE_RC=$?
      set -e
      if [ "$FORGE_RC" != "0" ]; then
        echo "  forge script FAILED (exit $FORGE_RC). Output:" >&2
        echo "------ forge stderr+stdout ------" >&2
        echo "$DEPLOY_OUT" >&2
        echo "------ end forge output ------" >&2
        exit 1
      fi
      # Forge succeeded — extract addresses from the deploy-script's
      # console.log output. `|| true` tolerates a single missing match
      # without tripping pipefail (then the validation below catches
      # any genuinely-missing address with a clear error).
      SCOPE_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'AgentKeysScope:[[:space:]]+0x[a-fA-F0-9]{40}' | awk '{print $NF}' || true)
      REGISTRY_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'SidecarRegistry:[[:space:]]+0x[a-fA-F0-9]{40}' | awk '{print $NF}' || true)
      EPOCH_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'K3EpochCounter:[[:space:]]+0x[a-fA-F0-9]{40}' | awk '{print $NF}' || true)
      AUDIT_ADDR=$(echo "$DEPLOY_OUT" | grep -oE 'CredentialAudit:[[:space:]]+0x[a-fA-F0-9]{40}' | awk '{print $NF}' || true)
      for pair in "AgentKeysScope:$SCOPE_ADDR" "SidecarRegistry:$REGISTRY_ADDR" "K3EpochCounter:$EPOCH_ADDR" "CredentialAudit:$AUDIT_ADDR"; do
        n="${pair%%:*}"; a="${pair##*:}"
        if [ -z "$a" ]; then
          echo "  ERROR: failed to extract $n address from forge output. Dump:" >&2
          echo "$DEPLOY_OUT" >&2
          exit 1
        fi
      done
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
# NEVER clobber a populated address with 0x0/empty. When the deploy step was
# skipped (SKIP_DEPLOY=1, e.g. the fund-only phase) the *_ADDR vars are unset;
# writing 0x0 here previously ZEROED the env, which then made the next run
# deploy DUPLICATE contracts. Skip-and-preserve instead — only persist a real
# resolved address.
persist_addr() {  # persist_addr <VAR> <addr>
  case "${2:-}" in
    ""|0x0|0x0000000000000000000000000000000000000000)
      echo "  skip $1 (address unresolved — preserving existing value)" ;;
    *) env_set "$1" "$2" "$ENV_FILE" ;;
  esac
}
persist_addr "SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC}"   "${SCOPE_ADDR:-}"
persist_addr "SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}" "${REGISTRY_ADDR:-}"
persist_addr "K3_EPOCH_COUNTER_ADDRESS_${PROFILE_NAME_UC}" "${EPOCH_ADDR:-}"
persist_addr "CREDENTIAL_AUDIT_ADDRESS_${PROFILE_NAME_UC}" "${AUDIT_ADDR:-}"
env_set "HEIMA_DEPLOYER_ADDR_${PROFILE_NAME_UC}"       "$DEPLOYER_ADDR"        "$ENV_FILE"
echo "  persisted (skipped unresolved — never clobbers a populated address)."

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
