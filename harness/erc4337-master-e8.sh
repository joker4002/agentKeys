#!/usr/bin/env bash
# harness/erc4337-master-e8.sh — #164 E8 acceptance: a passkey-only master lands a
# real master mutation via an ERC-4337 UserOp on Heima mainnet, with NO secp256k1
# key on the "device". Proves E1 (factory) + E2 (P256Account, WebAuthn via the live
# K11Verifier) + the userOpHash full-intent binding, end-to-end on mainnet.
#
# Flow: keygen passkey → factory.createAccount → depositTo(account) → build a UserOp
# whose callData is account.addSigner(...) (a master mutation) → getUserOpHash →
# WebAuthn-sign the userOpHash → K11 pre-check (live, free) → EntryPoint.handleOps →
# assert activeSignerCount == 2.
#
# Append-only demo: each run mints a FRESH account (unique salt), so re-runs don't
# collide; it is NOT idempotent in the resource sense (one new account + ~0.22 HEI
# of gas/deposit per run). Direct handleOps (no bundler needed for the proof, per
# the #164 plan). Sourced as phase6 by phase1-wire-demo.sh, or run standalone.
set -uo pipefail

RPC="${HEIMA_RPC:-https://rpc.heima-parachain.heima.network}"
FACTORY="${P256_ACCOUNT_FACTORY_ADDRESS_HEIMA:-0x1ccCe65b22De81aDA4F378FeAf7503d93f5d27a3}"
EP="${ENTRYPOINT_ADDRESS_HEIMA:-0x6672E1b315332167aBA12E0B1d3532a7e9B1ADE9}"
K11="${K11_VERIFIER_ADDRESS_HEIMA:-0x5a441431f08e0f5f5ed10659620cb4e0e814e627}"
DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-deployer.key}"
RPID="${AGENTKEYS_RP_ID:-litentry.org}"
VENV="${ERC4337_VENV:-$HOME/.agentkeys/erc4337-venv}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNER="$HERE/scripts/erc4337-webauthn-sign.py"

ok()   { printf '  ok %s\n' "$1"; }
skip() { printf '  skip %s\n' "$1"; }
fail() { printf '  fail %s\n' "$1"; return 1; }

erc4337_master_e8() {
  echo "== #164 E8: passkey-only master via ERC-4337 UserOp (Heima mainnet) =="
  command -v cast >/dev/null || { skip "cast not on PATH"; return 0; }
  [ -f "$DEPLOYER_KEY_FILE" ] || { skip "no deployer key ($DEPLOYER_KEY_FILE)"; return 0; }
  if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV" >/dev/null 2>&1 && "$VENV/bin/pip" install -q cryptography \
      || { skip "could not provision python+cryptography venv"; return 0; }
  fi
  local PY="$VENV/bin/python"
  local PK; PK="$(tr -d '[:space:]' < "$DEPLOYER_KEY_FILE")"
  local DEPLOYER; DEPLOYER="$(cast wallet address --private-key "$PK")"

  # EntryPoint + factory must be live.
  [ "$(cast code "$EP" --rpc-url "$RPC" 2>/dev/null | wc -c)" -gt 2 ] || { fail "EntryPoint $EP not deployed"; return 1; }
  [ "$(cast code "$FACTORY" --rpc-url "$RPC" 2>/dev/null | wc -c)" -gt 2 ] || { fail "factory $FACTORY not deployed"; return 1; }
  ok "EntryPoint + factory live"

  # 1. Keygen the master passkey (no secp256k1 key on the "device").
  local KEY="${TMPDIR:-/tmp}/e8-passkey.key"
  eval "$($PY "$SIGNER" keygen "$KEY" "$RPID")"   # PUBX PUBY RPIDHASH
  local CRED1; CRED1="$(cast keccak "e8-cred-$$-${RANDOM}")"
  local SALT;  SALT="$(cast keccak "e8-salt-$$-${RANDOM}-$(date +%s 2>/dev/null || echo 0)")"

  # 2. Deploy the account via the factory (CREATE2).
  local ACCT; ACCT="$(cast call "$FACTORY" "getAddress(bytes32,uint256,uint256,bytes32,bytes32)(address)" "$CRED1" "$PUBX" "$PUBY" "$RPIDHASH" "$SALT" --rpc-url "$RPC")"
  cast send "$FACTORY" "createAccount(bytes32,uint256,uint256,bytes32,bytes32)" "$CRED1" "$PUBX" "$PUBY" "$RPIDHASH" "$SALT" --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 1200000 >/dev/null 2>&1
  [ "$(cast code "$ACCT" --rpc-url "$RPC" 2>/dev/null | wc -c)" -gt 2 ] || { fail "account not deployed at $ACCT"; return 1; }
  ok "account deployed (passkey-bound) at $ACCT"

  # 3. Fund the account's EntryPoint deposit (≥ ExistentialDeposit so missingAccountFunds==0).
  cast send "$EP" "depositTo(address)" "$ACCT" --value 0.2ether --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 200000 >/dev/null 2>&1
  local DEP; DEP="$(cast call "$EP" "balanceOf(address)(uint256)" "$ACCT" --rpc-url "$RPC" | awk '{print $1}')"
  [ "$DEP" != "0" ] || { fail "deposit not credited"; return 1; }
  ok "account deposit funded ($DEP wei)"

  # 4. Build the UserOp: callData = a real master mutation (addSigner of a 2nd passkey).
  local CRED2; CRED2="$(cast keccak "e8-cred2-$$-${RANDOM}")"
  local CALLDATA; CALLDATA="$(cast calldata "addSigner(bytes32,uint256,uint256,bytes32)" "$CRED2" "$PUBX" "$PUBY" "$RPIDHASH")"
  local AGL; AGL="$(printf '0x%032x%032x' 1500000 300000)"     # verificationGasLimit | callGasLimit
  local GASFEES; GASFEES="$(printf '0x%032x%032x' 1000000000 40000000000)"  # maxPriority | maxFee
  local NONCE; NONCE="$(cast call "$EP" "getNonce(address,uint192)(uint256)" "$ACCT" 0 --rpc-url "$RPC" | awk '{print $1}')"
  local UNSIGNED="($ACCT,$NONCE,0x,$CALLDATA,$AGL,100000,$GASFEES,0x,0x)"
  local UOH; UOH="$(cast call "$EP" "getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))(bytes32)" "$UNSIGNED" --rpc-url "$RPC")"
  ok "userOpHash = $UOH"

  # 5. WebAuthn-sign the userOpHash (the passkey signs; full-intent commitment).
  eval "$($PY "$SIGNER" sign "$KEY" "$UOH" "$RPID")"  # AUTHDATA CDJ CHALLENGE_LOC R S

  # 6. Pre-check the assertion against the LIVE K11Verifier (free) before spending gas.
  local PRE; PRE="$(cast call "$K11" "verifyAssertion(bytes32,bytes32,bytes,bytes,uint256,uint256,uint256,uint256,uint256)(bool)" "$UOH" "$RPIDHASH" "$AUTHDATA" "$CDJ" "$CHALLENGE_LOC" "$R" "$S" "$PUBX" "$PUBY" --rpc-url "$RPC" 2>&1 | tail -1)"
  [ "$PRE" = "true" ] || { fail "K11 pre-check failed ($PRE)"; return 1; }
  ok "K11 assertion verifies on live verifier"

  # 7. Assemble signature = abi.encode(credIdHash, authData, clientDataJSON, loc, r, s) + handleOps.
  local SIG; SIG="$(cast abi-encode "x(bytes32,bytes,bytes,uint256,uint256,uint256)" "$CRED1" "$AUTHDATA" "$CDJ" "$CHALLENGE_LOC" "$R" "$S")"
  local SIGNED="($ACCT,$NONCE,0x,$CALLDATA,$AGL,100000,$GASFEES,0x,$SIG)"
  cast send "$EP" "handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)" "[$SIGNED]" "$DEPLOYER" --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 3000000 >/dev/null 2>&1

  # 8. Assert the master mutation landed: activeSignerCount 1 -> 2.
  local COUNT; COUNT="$(cast call "$ACCT" "activeSignerCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}')"
  [ "$COUNT" = "2" ] || { fail "UserOp did not execute (activeSignerCount=$COUNT, want 2)"; return 1; }
  ok "UserOp executed: passkey-signed addSigner landed, activeSignerCount=2 — passkey-only master ✓"
  echo "  account=$ACCT  (no secp256k1 key was used to authorize the mutation)"
}

# Run standalone if invoked directly (non-zero exit on failure, for callers/CI).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  erc4337_master_e8 || exit 1
fi
