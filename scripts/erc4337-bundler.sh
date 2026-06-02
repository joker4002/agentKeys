#!/usr/bin/env bash
# scripts/erc4337-bundler.sh — self-hosted ERC-4337 v0.7 bundler for Heima (#164 E6).
#
# WHY UNSAFE MODE: Heima's Frontier RPC exposes no `debug` namespace
# (debug_traceCall / debug_traceTransaction → -32601 method-not-found, verified
# 2026-06-02). Standard bundlers need debug_traceCall for ERC-7562 validation, so
# we run a PRIVATE bundler in --unsafe mode, fed only by authenticated clients via
# the broker — NOT a public alt-mempool. Acceptable because the broker is already
# the gatekeeper and we control the single bundler. See
# docs/plan/chain/erc4337-master-account.md §2 + threat-model §4.
#
# This script is the operator-facing runner; it does not stand up infra by itself.
# Idempotent: re-running just (re)launches the bundler against the recorded EntryPoint.
set -euo pipefail

RPC="${HEIMA_RPC:-https://rpc.heima-parachain.heima.network}"
ENTRYPOINT="${ENTRYPOINT_ADDRESS_HEIMA:-0x6672E1b315332167aBA12E0B1d3532a7e9B1ADE9}"
CHAIN_ID="${HEIMA_CHAIN_ID:-212013}"
# The bundler's own EOA pays handleOps gas (reimbursed from the account deposit /
# paymaster). It must hold HEI ≥ ExistentialDeposit (~0.1) + a gas float.
BUNDLER_KEY_FILE="${BUNDLER_KEY_FILE:-$HOME/.agentkeys/heima-bundler.key}"

echo "ERC-4337 bundler (Heima, UNSAFE mode)"
echo "  rpc        = $RPC"
echo "  entryPoint = $ENTRYPOINT"
echo "  chainId    = $CHAIN_ID"

# Sanity: EntryPoint must be deployed.
code=$(cast code "$ENTRYPOINT" --rpc-url "$RPC" 2>/dev/null || echo 0x)
[ "${#code}" -gt 2 ] || { echo "fail: EntryPoint not deployed at $ENTRYPOINT"; exit 1; }
echo "ok proceeding: EntryPoint bytecode present"

# Option A — eth-infinitism reference bundler (TypeScript), simplest for the demo:
#   git clone https://github.com/eth-infinitism/bundler && cd bundler && yarn && yarn preprocess
#   yarn bundler --network "$RPC" --entryPoint "$ENTRYPOINT" --unsafe \
#     --beneficiary "$(cast wallet address --private-key "$(cat "$BUNDLER_KEY_FILE")")" \
#     --privateKey "$(cat "$BUNDLER_KEY_FILE")" --port 3000
#
# Option B — rundler (Rust, Alchemy), prod-grade, also supports unsafe:
#   rundler node --network dev --node_http "$RPC" \
#     --entry_points "$ENTRYPOINT" --unsafe \
#     --builder.private_key "$(cat "$BUNDLER_KEY_FILE")" --rpc.port 3000
#
# Both expose the standard JSON-RPC: eth_sendUserOperation, eth_estimateUserOperationGas,
# eth_getUserOperationByHash, eth_getUserOperationReceipt, eth_supportedEntryPoints.
# The broker submits broker-co-signed UserOps here; the paymaster (VerifyingPaymaster)
# sponsors them. NO BUNDLER IS REQUIRED FOR CORRECTNESS — anyone (incl. our broker)
# can call EntryPoint.handleOps directly (the #164 spike + harness E8 do exactly that);
# the bundler is the always-on automation layer.
echo
echo "Pick Option A (reference bundler) or B (rundler) above and run it; the broker"
echo "then points NEXT_PUBLIC_BUNDLER_URL / the cap-mint relay at http://localhost:3000."
echo "skip: live bundler standup is an operator step (this script documents + sanity-checks)."
