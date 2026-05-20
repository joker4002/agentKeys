#!/usr/bin/env bash
# harness/scripts/_lib.sh — shared helpers for v2 stage-2 scripts.
# `source "$LIB"` where LIB="$(dirname "${BASH_SOURCE[0]}")/_lib.sh".

# Resolve the operator's deployer/master private key from one of:
#   1. $HEIMA_DEPLOYER_KEY_FILE  — raw hex (0x... or 64 hex chars)
#   2. $HEIMA_DEPLOYER_KEY_FILE  — BIP-39 mnemonic (multi-word)
#   3. ~/.agentkeys/heima-deployer.key  (default)
#   4. ./test-hei                       (fallback)
# Echoes the 0x-prefixed 64-hex private key on stdout. Returns nonzero on
# failure. Caller is responsible for cd'ing to $REPO_ROOT before calling.
resolve_master_key() {
  local file="${HEIMA_DEPLOYER_KEY_FILE:-}"
  if [ -z "$file" ]; then
    if [ -f "$HOME/.agentkeys/heima-deployer.key" ]; then
      file="$HOME/.agentkeys/heima-deployer.key"
    elif [ -f "./test-hei" ]; then
      file="./test-hei"
    fi
  fi
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "could not resolve deployer key (set HEIMA_DEPLOYER_KEY_FILE or place ~/.agentkeys/heima-deployer.key)" >&2
    return 1
  fi
  local raw
  raw=$(cat "$file" | tr -d '\n[:space:]')
  if [ "${#raw}" = "66" ] && [ "${raw:0:2}" = "0x" ]; then
    echo "$raw"
    return 0
  fi
  if [ "${#raw}" = "64" ]; then
    echo "0x$raw"
    return 0
  fi
  # Treat as mnemonic — derive via ethers
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  if [ ! -d "$repo_root/scripts/node_modules/ethers" ]; then
    npm install --prefix "$repo_root/scripts" --silent --no-audit --no-fund >/dev/null 2>&1
  fi
  node "$repo_root/scripts/derive-evm-from-mnemonic.mjs" "$file" | jq -r .privateKey
}
