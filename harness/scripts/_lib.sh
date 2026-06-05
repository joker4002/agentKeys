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
  repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/../.." 2>/dev/null && pwd)}"
  if [ ! -d "$repo_root/scripts/node_modules/ethers" ]; then
    npm install --prefix "$repo_root/scripts" --silent --no-audit --no-fund >/dev/null 2>&1
  fi
  node "$repo_root/scripts/derive-evm-from-mnemonic.mjs" "$file" | jq -r .privateKey
}

# register_first_master [operator_omni]
# Register the operator's first master device via the #164 passkey-account
# ERC-4337 path — the ONLY supported register. The old-model EOA register is
# DEPRECATED (see below).
#
# The "passkey" has two implementations of the SAME #164 flow (P256Account +
# registerFirstMasterDevice via a P-256 WebAuthn UserOp), both in the Rust agentkeys
# CLI the harness already builds (no separate language runtime):
#   - HARDWARE (`k11 webauthn-keygen`/`webauthn-userop-sign`): the operator's Touch ID /
#     Secure-Enclave K11 signs — used LOCALLY (no flag). The secure, real path.
#   - SOFTWARE (`k11 software-keygen`/`software-sign`): a file P-256 key signs, no
#     biometric — used in CI (--ci). Weaker custody, CI/test-only (the CLI prints a WARN).
# The EOA path (operatorMasterWallet = a raw EOA, signed directly) does NOT follow this
# pattern and is NEVER used automatically; it survives only as a loud, explicit
# emergency escape via AGENTKEYS_REGISTER_MODE=eoa.
#
# Run mode (no flag = local → HARDWARE; --ci = CI → SOFTWARE):
#   - LOCAL (no flag): the HARDWARE Touch ID register MUST run — fail loud (return 1)
#     if its prereqs (cast/agentkeys-cli/EntryPoint/factory) are missing or it fails. Never EOA.
#   - CI (--ci → AGENTKEYS_CI=1, or the runner's own $CI): SOFTWARE signer + TOLERATES a
#     skip (return 0) when those prereqs are unavailable — still never EOA.
#
# device_key_hash = keccak(operator_omni). Idempotent (the register skips when the
# operator already has a master). operator_omni defaults to the deployer omni
# (operator == deployer — the harness identity). Logs to stderr.
register_first_master() {
  local omni="${1:-}"
  local repo_root profile_uc ep factory ci
  # Prefer the caller's absolute $REPO_ROOT (every harness caller sets it before
  # sourcing _lib.sh). Robust under bash AND zsh — ${BASH_SOURCE} is empty under
  # zsh, which would otherwise resolve repo_root one level too high.
  repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/../.." 2>/dev/null && pwd)}"
  if [ -z "$omni" ]; then
    local k addr
    k="$(resolve_master_key)" || { echo "register_first_master: no deployer key" >&2; return 1; }
    addr="$(cast wallet address --private-key "$k" | tr 'A-F' 'a-f')"
    omni="$(printf 'agentkeysevm%s' "$addr" | shasum -a 256 | awk '{print $1}')"
  fi
  omni="0x${omni#0x}"
  profile_uc="$(printf '%s' "${AGENTKEYS_CHAIN:-heima}" | tr 'a-z-' 'A-Z_')"
  eval "ep=\${ENTRYPOINT_ADDRESS_${profile_uc}:-}"
  eval "factory=\${P256_ACCOUNT_FACTORY_ADDRESS_${profile_uc}:-}"
  # The #164 passkey-account ERC-4337 register is the ONLY supported path. The
  # old-model EOA register (operatorMasterWallet = a raw EOA, signed directly) is
  # DEPRECATED — it does NOT follow the #164 pattern (account-as-msg.sender, a
  # P-256 WebAuthn UserOp) and is NEVER used automatically. AGENTKEYS_REGISTER_MODE=eoa
  # remains a loud, explicit emergency escape only.
  if [ "${AGENTKEYS_REGISTER_MODE:-}" = "eoa" ]; then
    echo "register_first_master: WARNING — EOA register is DEPRECATED (old-model, not #164). Proceeding only because AGENTKEYS_REGISTER_MODE=eoa is set explicitly." >&2
    bash "$repo_root/harness/scripts/heima-register-first-master.sh" --operator-omni "$omni"
    return $?
  fi

  # Run mode picks BOTH the skip-tolerance AND the passkey implementation of the SAME
  # #164 flow (P256Account + registerFirstMasterDevice via a P-256 WebAuthn UserOp):
  #   LOCAL (no flag): signer=HARDWARE — the operator's Touch ID / Secure-Enclave K11
  #     signs the register UserOp (a real biometric ceremony; no on-disk key). The
  #     register MUST run — fail loud if prereqs are missing or it fails. NEVER EOA.
  #   CI (--ci → AGENTKEYS_CI=1, or the runner's own $CI): signer=SOFTWARE — a file
  #     P-256 key signs (no biometric; the headless stand-in) AND a skip is tolerated
  #     when the #164 prereqs aren't available. NEVER EOA.
  # The software signer is CI/test-only (weaker key custody — the CLI prints a WARN);
  # the attestation check that would REFUSE it for a real master is stage-2 (#90).
  ci=0
  { [ -n "${AGENTKEYS_CI:-}" ] || [ -n "${CI:-}" ]; } && ci=1

  # Both passkey signers (hardware + software) live in the agentkeys CLI the harness
  # already builds (no python / no separate language runtime) — so the prereq is that
  # binary. (Hardware additionally needs a browser + Touch ID at runtime; if absent,
  # the ceremony fails loud locally — use --ci for the software signer on headless boxes.)
  local bin
  if [ -x "$repo_root/target/release/agentkeys" ]; then bin="$repo_root/target/release/agentkeys";
  elif [ -x "$repo_root/target/debug/agentkeys" ]; then bin="$repo_root/target/debug/agentkeys";
  else bin="$(command -v agentkeys || true)"; fi

  if ! command -v cast >/dev/null 2>&1 || [ -z "$bin" ] || [ -z "$ep" ] || [ -z "$factory" ]; then
    if [ "$ci" = 1 ]; then
      echo "register_first_master: CI — #164 passkey prereqs unavailable (cast/agentkeys-cli/EntryPoint/factory) → SKIP register (EOA is deprecated; no fallback)" >&2
      return 0
    fi
    echo "register_first_master: #164 passkey-account prereqs missing — a LOCAL run requires cast + the agentkeys binary (cargo build --release -p agentkeys-cli) + ENTRYPOINT_ADDRESS_${profile_uc} + P256_ACCOUNT_FACTORY_ADDRESS_${profile_uc}. EOA is deprecated — install the prereqs, or pass --ci to skip in CI." >&2
    return 1
  fi

  local signer_mode
  if [ "$ci" = 1 ]; then signer_mode=software; else signer_mode=hardware; fi
  if [ "$signer_mode" = hardware ]; then
    echo "register_first_master: #164 passkey-account ERC-4337 register (signer=HARDWARE — Touch ID ceremony; approve the prompt) operator_omni=$omni" >&2
  else
    echo "register_first_master: #164 passkey-account ERC-4337 register (signer=SOFTWARE — CI/test, file key, no biometric) operator_omni=$omni" >&2
  fi
  if bash "$repo_root/harness/scripts/erc4337-register-master.sh" --operator-omni "$omni" --signer "$signer_mode"; then
    return 0
  fi
  if [ "$ci" = 1 ]; then
    echo "register_first_master: CI — #164 register failed → SKIP (EOA is deprecated; no fallback)" >&2
    return 0
  fi
  echo "register_first_master: #164 passkey-account register FAILED — LOCAL run, EOA is deprecated (no fallback). Pass --ci to skip in CI." >&2
  return 1
}

# resolve_active_master_dkh <operator_omni> [deployer_addr_lc]
# Echo the operator's ACTIVE on-chain master device_key_hash, or nothing (rc 1).
# The two register paths use different device-hash conventions, and an operator
# bootstrapped before the erc4337 change carries the legacy one — so don't ASSUME
# a convention, detect which device is actually active:
#   1. keccak(operator_omni)   — the #164 / --operator-omni convention
#   2. keccak(deployer_addr)   — the legacy EOA `heima-register-first-master.sh` default
# Master cap-mint must send whichever this returns. Needs cast + a sourced
# operator-workstation.env (registry address) + a resolvable chain.
resolve_active_master_dkh() {
  local omni="0x${1#0x}" deployer_lc="${2:-}"
  local profile_uc reg bin rpc dkh
  command -v cast >/dev/null 2>&1 || return 1
  profile_uc="$(printf '%s' "${AGENTKEYS_CHAIN:-heima}" | tr 'a-z-' 'A-Z_')"
  eval "reg=\${SIDECAR_REGISTRY_ADDRESS_${profile_uc}:-}"
  [ -n "$reg" ] || return 1
  local repo_root; repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/../.." 2>/dev/null && pwd)}"
  if [ -x "$repo_root/target/release/agentkeys" ]; then bin="$repo_root/target/release/agentkeys";
  elif [ -x "$repo_root/target/debug/agentkeys" ]; then bin="$repo_root/target/debug/agentkeys";
  else bin="$(command -v agentkeys || true)"; fi
  [ -n "$bin" ] || return 1
  rpc="$("$bin" chain show "${AGENTKEYS_CHAIN:-heima}" | jq -r .rpc.http)"
  [ -n "$rpc" ] && [ "$rpc" != "null" ] || return 1
  dkh="$(cast keccak "$omni")"
  [ "$(cast call "$reg" 'isActive(bytes32)(bool)' "$dkh" --rpc-url "$rpc" 2>/dev/null || echo false)" = true ] && { printf '%s' "$dkh"; return 0; }
  if [ -n "$deployer_lc" ]; then
    # MUST be 0x-prefixed so `cast keccak` hashes the 20 ADDRESS BYTES (matching
    # heima-register-first-master.sh's keccak(MASTER_ADDR_LC)), NOT the ASCII hex.
    deployer_lc="0x${deployer_lc#0x}"
    dkh="$(cast keccak "$deployer_lc")"
    [ "$(cast call "$reg" 'isActive(bytes32)(bool)' "$dkh" --rpc-url "$rpc" 2>/dev/null || echo false)" = true ] && { printf '%s' "$dkh"; return 0; }
  fi
  return 1
}
