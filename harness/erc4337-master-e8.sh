#!/usr/bin/env bash
# harness/erc4337-master-e8.sh — #164 E8 acceptance: a passkey-only master lands a
# real master mutation via an ERC-4337 UserOp on Heima mainnet, with NO secp256k1
# key on the "device". Proves E1 (factory) + E2 (P256Account, WebAuthn via the live
# K11Verifier) + the userOpHash full-intent binding, end-to-end on mainnet.
#
# Flow: passkey → factory.createAccount → fund deposit → build a UserOp whose
# callData is account.addSigner(...) (a master mutation) → getUserOpHash →
# WebAuthn-sign → K11 pre-check (live, free) → EntryPoint.handleOps → assert the
# account's active-signer count went up by exactly 1.
#
# MODES:
#   fresh (default — local): a NEW account + ephemeral passkey + fresh deposit each
#     run. Append-only; ~0.22 HEI/run. HEI cost doesn't matter for local testing.
#   reuse (auto when $CI is set; or ERC4337_E8_MODE=reuse): ONE persistent account
#     (fixed passkey at $ERC4337_E8_KEY_FILE + fixed salt → deterministic address),
#     created once and funded only when its deposit runs low — so CI doesn't mint a
#     new account / spend a full deposit every run. CI must persist the key file
#     (cache/secret) for the account to actually be reused across runs.
# Direct handleOps (no bundler needed for the proof, per the #164 plan).
set -uo pipefail

RPC="${HEIMA_RPC:-https://rpc.heima-parachain.heima.network}"
FACTORY="${P256_ACCOUNT_FACTORY_ADDRESS_HEIMA:-0x1ccCe65b22De81aDA4F378FeAf7503d93f5d27a3}"
EP="${ENTRYPOINT_ADDRESS_HEIMA:-0x6672E1b315332167aBA12E0B1d3532a7e9B1ADE9}"
K11="${K11_VERIFIER_ADDRESS_HEIMA:-0x5a441431f08e0f5f5ed10659620cb4e0e814e627}"
DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-deployer.key}"
RPID="${AGENTKEYS_RP_ID:-litentry.org}"
VENV="${ERC4337_VENV:-$HOME/.agentkeys/erc4337-venv}"
# fresh (local default) vs reuse (default in CI). Override with ERC4337_E8_MODE.
MODE_E8="${ERC4337_E8_MODE:-$([ -n "${CI:-}" ] && echo reuse || echo fresh)}"
REUSE_KEY_FILE="${ERC4337_E8_KEY_FILE:-$HOME/.agentkeys/erc4337-e8-reuse.key}"
DEPOSIT_WEI="${ERC4337_E8_DEPOSIT_WEI:-200000000000000000}"   # 0.2 HEI
MIN_DEPOSIT_WEI="${ERC4337_E8_MIN_DEPOSIT_WEI:-50000000000000000}" # top up reuse below 0.05 HEI
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNER="$HERE/scripts/erc4337-webauthn-sign.py"

ok()   { printf '  ok %s\n' "$1"; }
skip() { printf '  skip %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; return 1; }
# True iff $1 has contract code. `cast code` returns exactly "0x" for an empty
# account (wc -c would count that as 3 — hence a length check is wrong).
_has_code() { local c; c="$(cast code "$1" --rpc-url "$RPC" 2>/dev/null)"; [ -n "$c" ] && [ "$c" != "0x" ]; }

erc4337_master_e8() {
  echo "== #164 E8: passkey-only master via ERC-4337 UserOp (Heima mainnet, mode=$MODE_E8) =="
  command -v cast >/dev/null || { skip "cast not on PATH"; return 0; }
  [ -f "$DEPLOYER_KEY_FILE" ] || { skip "no deployer key ($DEPLOYER_KEY_FILE)"; return 0; }
  if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV" >/dev/null 2>&1 && "$VENV/bin/pip" install -q cryptography \
      || { skip "could not provision python+cryptography venv"; return 0; }
  fi
  local PY="$VENV/bin/python"
  local PK; PK="$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE")"
  local DEPLOYER; DEPLOYER="$(cast wallet address --private-key "$PK")"

  _has_code "$EP" || { fail "EntryPoint $EP not deployed"; return 1; }
  _has_code "$FACTORY" || { fail "factory $FACTORY not deployed"; return 1; }
  ok "EntryPoint + factory live"

  # 1. The master passkey + the account identity (fresh = new each run; reuse = fixed).
  local KEY CRED1 SALT
  if [ "$MODE_E8" = reuse ]; then
    KEY="$REUSE_KEY_FILE"
    CRED1="$(cast keccak "agentkeys-e8-reuse-cred1-v1")"
    SALT="${ERC4337_E8_SALT:-$(cast keccak "agentkeys-e8-reuse-salt-v1")}"
  else
    KEY="${TMPDIR:-/tmp}/e8-passkey-$$-${RANDOM}.key"   # unique → genuinely fresh key
    CRED1="$(cast keccak "e8-cred-$$-${RANDOM}-$(date +%s 2>/dev/null || echo 0)")"
    SALT="$(cast keccak "e8-salt-$$-${RANDOM}-$(date +%s 2>/dev/null || echo 0)")"
  fi
  eval "$($PY "$SIGNER" keygen "$KEY" "$RPID")"   # PUBX PUBY RPIDHASH (idempotent: loads if KEY exists)

  # 2. Deploy (or reuse) the account via the factory (CREATE2, idempotent).
  local ACCT; ACCT="$(cast call "$FACTORY" "getAddress(bytes32,uint256,uint256,bytes32,bytes32)(address)" "$CRED1" "$PUBX" "$PUBY" "$RPIDHASH" "$SALT" --rpc-url "$RPC")"
  if _has_code "$ACCT"; then
    ok "account reused at $ACCT"
  else
    cast send "$FACTORY" "createAccount(bytes32,uint256,uint256,bytes32,bytes32)" "$CRED1" "$PUBX" "$PUBY" "$RPIDHASH" "$SALT" --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 1200000 >/dev/null 2>&1
    _has_code "$ACCT" || { fail "account not deployed at $ACCT"; return 1; }
    ok "account deployed (passkey-bound) at $ACCT"
  fi

  # 3. Fund the EntryPoint deposit (≥ ED so missingAccountFunds==0). fresh: always;
  #    reuse: only when low, so CI doesn't re-deposit a full 0.2 HEI every run.
  local DEP; DEP="$(cast call "$EP" "balanceOf(address)(uint256)" "$ACCT" --rpc-url "$RPC" | awk '{print $1}')"
  if [ "$MODE_E8" != reuse ] || [ "$DEP" -lt "$MIN_DEPOSIT_WEI" ]; then
    cast send "$EP" "depositTo(address)" "$ACCT" --value "${DEPOSIT_WEI}wei" --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 200000 >/dev/null 2>&1
    DEP="$(cast call "$EP" "balanceOf(address)(uint256)" "$ACCT" --rpc-url "$RPC" | awk '{print $1}')"
    ok "account deposit funded ($DEP wei)"
  else
    ok "account deposit sufficient ($DEP wei) — reuse, no top-up"
  fi

  # 4. Active-signer count BEFORE (fresh: 1; reuse: grows each run — we assert the delta).
  local BEFORE; BEFORE="$(cast call "$ACCT" "activeSignerCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}')"

  # 5. Build the UserOp: callData = a real master mutation (addSigner of a UNIQUE-per-run passkey).
  local CRED2; CRED2="$(cast keccak "e8-cred2-$$-${RANDOM}-$(date +%s 2>/dev/null || echo 0)")"
  local CALLDATA; CALLDATA="$(cast calldata "addSigner(bytes32,uint256,uint256,bytes32)" "$CRED2" "$PUBX" "$PUBY" "$RPIDHASH")"
  local AGL; AGL="$(printf '0x%032x%032x' 1500000 300000)"     # verificationGasLimit | callGasLimit
  local GASFEES; GASFEES="$(printf '0x%032x%032x' 1000000000 40000000000)"  # maxPriority | maxFee
  local NONCE; NONCE="$(cast call "$EP" "getNonce(address,uint192)(uint256)" "$ACCT" 0 --rpc-url "$RPC" | awk '{print $1}')"
  local UNSIGNED="($ACCT,$NONCE,0x,$CALLDATA,$AGL,100000,$GASFEES,0x,0x)"
  local UOH; UOH="$(cast call "$EP" "getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))(bytes32)" "$UNSIGNED" --rpc-url "$RPC")"
  ok "userOpHash = $UOH"

  # 6. WebAuthn-sign the userOpHash (the passkey signs; full-intent commitment).
  eval "$($PY "$SIGNER" sign "$KEY" "$UOH" "$RPID")"  # AUTHDATA CDJ CHALLENGE_LOC R S

  # 7. Pre-check the assertion against the LIVE K11Verifier (free) before spending gas.
  local PRE; PRE="$(cast call "$K11" "verifyAssertion(bytes32,bytes32,bytes,bytes,uint256,uint256,uint256,uint256,uint256)(bool)" "$UOH" "$RPIDHASH" "$AUTHDATA" "$CDJ" "$CHALLENGE_LOC" "$R" "$S" "$PUBX" "$PUBY" --rpc-url "$RPC" 2>&1 | tail -1)"
  [ "$PRE" = "true" ] || { fail "K11 pre-check failed ($PRE)"; return 1; }
  ok "K11 assertion verifies on live verifier"

  # 8. Assemble signature = abi.encode(credIdHash, authData, clientDataJSON, loc, r, s) + handleOps.
  local SIG; SIG="$(cast abi-encode "x(bytes32,bytes,bytes,uint256,uint256,uint256)" "$CRED1" "$AUTHDATA" "$CDJ" "$CHALLENGE_LOC" "$R" "$S")"
  local SIGNED="($ACCT,$NONCE,0x,$CALLDATA,$AGL,100000,$GASFEES,0x,$SIG)"
  cast send "$EP" "handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)" "[$SIGNED]" "$DEPLOYER" --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 3000000 >/dev/null 2>&1

  # 9. Assert the master mutation landed: active-signer count went up by exactly 1
  #    (works for both fresh [1→2] and reuse [N→N+1]).
  local AFTER; AFTER="$(cast call "$ACCT" "activeSignerCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}')"
  [ "$AFTER" = "$((BEFORE + 1))" ] || { fail "UserOp did not execute (activeSignerCount ${BEFORE}->${AFTER}, want $((BEFORE + 1)))"; return 1; }
  ok "UserOp executed: passkey-signed addSigner landed, activeSignerCount ${BEFORE}->${AFTER} - passkey-only master (no secp256k1 key)"
  echo "  account=$ACCT  mode=$MODE_E8  (no secp256k1 key authorized the mutation)"
}

# Run standalone if invoked directly (non-zero exit on failure, for callers/CI).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  erc4337_master_e8 || exit 1
fi
