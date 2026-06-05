#!/usr/bin/env bash
# harness/scripts/erc4337-register-master.sh — register the first master device
# on SidecarRegistry via a **passkey-account ERC-4337 UserOp** (#164 / chain-plan
# E7), so `operatorMasterWallet[omni]` is the passkey-controlled P256Account, NOT
# a deployer EOA. The passkey signs; the deployer only pays gas (createAccount +
# EntryPoint deposit + the outer handleOps tx). This is the clean replacement for
# the old-model EOA `heima-register-first-master.sh`.
#
# VERIFIED viable on the LIVE (pre-cutover) contracts: the deployed registry has
# no EOA-only guard, so `account.execute(registry, registerFirstMasterDevice(...))`
# records `operatorMasterWallet[omni] = account`. Inner calldata targets the OLD
# (pre-#165) registry ABI — identical args to heima-register-first-master.sh.
# Mechanism proven green on Heima mainnet by harness/erc4337-master-e8.sh.
#
# > CAVEAT (E7 pre-cutover): registrations land on the CURRENT registry. When the
# > E3/E7 cutover redeploys registry+scope, masters re-register on the new one
# > (same migration cost as the EOA path, but the on-chain owner is already the
# > passkey-account). See docs/plan/chain/erc4337-master-account.md §3.1.
#
# SUB-COMMANDS:
#   build  --operator-omni 0x.. --pubx N --puby N --cred-id-hash 0x.. \
#          --rpid-hash 0x.. --state-file F [--roles 7] [--salt 0x..]
#       → derive the account, createAccount + fund its EntryPoint deposit (deployer
#         pays), assemble the register UserOp, print {userop_hash, account,
#         device_key_hash, intent} and persist the UNSIGNED UserOp to F. NO signing.
#         The WEB caller hands `userop_hash` to the browser passkey.
#         Idempotent: prints {skipped:"already-registered"} if the device exists.
#   submit --state-file F --cred-id-hash 0x.. --authdata 0x.. --clientdata 0x.. \
#          --challenge-loc N --r N --s N
#       → take the WebAuthn assertion over userop_hash, K11 pre-check (free), then
#         EntryPoint.handleOps; assert getDevice registered. Prints {tx_hash,..}.
#   (default — no sub-command)  [--operator-omni 0x..] [--key-file F] [--roles 7]
#       → register, signed by a SOFTWARE passkey (build+sign+submit in one shot,
#         no browser). This is the harness path; `erc4337-master-e8.sh` proves the
#         same mechanism. `register` is an explicit alias. Just run:
#         bash erc4337-register-master.sh [--operator-omni 0x..]
#
# Output: machine-readable JSON on the LAST stdout line; human logs on stderr.

set -euo pipefail

# Default action is the all-in-one register (software passkey). `build`/`submit`
# are the explicit two-phase hooks for the daemon web-flow. No sub-command needed
# for the common case: `erc4337-register-master.sh [--operator-omni 0x..]`.
SUBCMD="register"
case "${1:-}" in
  build|submit|register) SUBCMD="$1"; shift ;;
esac

OPERATOR_OMNI_IN=""; ROLES=7; SALT=""; STATE_FILE=""
PUBX=""; PUBY=""; CRED_ID_HASH=""; RPID_HASH=""; RP_ID=""
KEY_FILE=""; AUTHDATA=""; CLIENTDATA=""; CHALLENGE_LOC=""; SIG_R=""; SIG_S=""
SIGNER="${AGENTKEYS_REGISTER_SIGNER:-hardware}"   # hardware (Touch ID, LOCAL default) | software (CI/headless)
DEPOSIT_WEI="${ERC4337_DEPOSIT_WEI:-200000000000000000}"      # 0.2 HEI
MIN_DEPOSIT_WEI="${ERC4337_MIN_DEPOSIT_WEI:-50000000000000000}" # top up below 0.05 HEI

while [ $# -gt 0 ]; do
  case "$1" in
    --operator-omni)  OPERATOR_OMNI_IN="$2"; shift 2 ;;
    --roles)          ROLES="$2"; shift 2 ;;
    --salt)           SALT="$2"; shift 2 ;;
    --state-file)     STATE_FILE="$2"; shift 2 ;;
    --pubx)           PUBX="$2"; shift 2 ;;
    --puby)           PUBY="$2"; shift 2 ;;
    --cred-id-hash)   CRED_ID_HASH="$2"; shift 2 ;;
    --rpid-hash)      RPID_HASH="$2"; shift 2 ;;
    --rp-id)          RP_ID="$2"; shift 2 ;;
    --key-file)       KEY_FILE="$2"; shift 2 ;;
    --signer)         SIGNER="$2"; shift 2 ;;
    --authdata)       AUTHDATA="$2"; shift 2 ;;
    --clientdata)     CLIENTDATA="$2"; shift 2 ;;
    --challenge-loc)  CHALLENGE_LOC="$2"; shift 2 ;;
    --r)              SIG_R="$2"; shift 2 ;;
    --s)              SIG_S="$2"; shift 2 ;;
    --help|-h)        sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_SKIP='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else C_HEAD=''; C_OK=''; C_SKIP=''; C_ERR=''; C_RESET=''; fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
skip() { printf "    ${C_SKIP}skip${C_RESET} %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }
_has_code() { local c; c="$(cast code "$1" --rpc-url "$RPC" 2>/dev/null)"; [ -n "$c" ] && [ "$c" != "0x" ]; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a
. "$REPO_ROOT/harness/scripts/_lib.sh"

command -v cast >/dev/null || die "cast not on PATH (foundry)"
AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_UC="$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')"
if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then BIN="$REPO_ROOT/target/release/agentkeys";
elif [ -x "$REPO_ROOT/target/debug/agentkeys" ]; then BIN="$REPO_ROOT/target/debug/agentkeys";
else BIN="$(command -v agentkeys || true)"; fi
[ -n "$BIN" ] || die "agentkeys binary not found"
RPC="$("$BIN" chain show "$AGENTKEYS_CHAIN" | jq -r .rpc.http)"
eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_UC}:-}"
eval "EP=\${ENTRYPOINT_ADDRESS_${PROFILE_UC}:-}"
eval "FACTORY=\${P256_ACCOUNT_FACTORY_ADDRESS_${PROFILE_UC}:-}"
eval "K11=\${K11_VERIFIER_ADDRESS_${PROFILE_UC}:-}"
[ -n "$REGISTRY" ] || die "no SIDECAR_REGISTRY_ADDRESS_${PROFILE_UC}"
[ -n "$EP" ] || die "no ENTRYPOINT_ADDRESS_${PROFILE_UC} (#164 infra not in env)"
[ -n "$FACTORY" ] || die "no P256_ACCOUNT_FACTORY_ADDRESS_${PROFILE_UC}"
[ -n "$K11" ] || die "no K11_VERIFIER_ADDRESS_${PROFILE_UC}"

# Gas/relayer key (deployer): pays createAccount + depositTo + the outer handleOps
# tx. The PASSKEY (not this key) authorizes the registration.
PK="$(resolve_master_key)" || die "could not resolve deployer key"
DEPLOYER="$(cast wallet address --private-key "$PK")"

# UserOp gas constants (mirror erc4337-master-e8.sh, proven on mainnet).
AGL="$(printf '0x%032x%032x' 1500000 300000)"        # verificationGasLimit | callGasLimit
GASFEES="$(printf '0x%032x%032x' 1000000000 40000000000)" # maxPriority | maxFee
UOP_TUPLE_T="(address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)"

# normalize a bytes32-omni → bare lowercase 64 hex.
_omni() { local v; v="$(printf '%s' "$1" | tr 'A-F' 'a-f')"; v="${v#0x}"; printf '%s' "$v"; }

# Derive the per-operator account + device hash + the register UserOp callData.
# Sets: OPERATOR_OMNI ACCOUNT DEVICE_KEY_HASH CALLDATA  (uses PUBX PUBY CRED_ID_HASH RPID_HASH SALT ROLES)
derive_common() {
  [ -n "$OPERATOR_OMNI_IN" ] || die "--operator-omni required"
  [ -n "$PUBX" ] && [ -n "$PUBY" ] || die "--pubx/--puby required"
  [ -n "$CRED_ID_HASH" ] || die "--cred-id-hash required"
  [ -n "$RPID_HASH" ] || die "--rpid-hash required"
  OPERATOR_OMNI="$(_omni "$OPERATOR_OMNI_IN")"
  [ "${#OPERATOR_OMNI}" = 64 ] || die "--operator-omni must be 32 bytes (got ${#OPERATOR_OMNI} hex)"
  [ -n "$SALT" ] || SALT="$(cast keccak "agentkeys-master-account:0x$OPERATOR_OMNI")"
  ACCOUNT="$(cast call "$FACTORY" "getAddress(bytes32,uint256,uint256,bytes32,bytes32)(address)" \
    "$CRED_ID_HASH" "$PUBX" "$PUBY" "$RPID_HASH" "$SALT" --rpc-url "$RPC")"
  DEVICE_KEY_HASH="$(cast keccak "0x$OPERATOR_OMNI")"
  local inner
  inner="$(cast calldata "registerFirstMasterDevice(bytes32,bytes32,bytes32,bytes32,bytes32,uint256,uint256,bytes,uint8)" \
    "$DEVICE_KEY_HASH" "0x$OPERATOR_OMNI" "0x$OPERATOR_OMNI" "$CRED_ID_HASH" "$RPID_HASH" "$PUBX" "$PUBY" "0x00" "$ROLES")"
  CALLDATA="$(cast calldata "execute(address,uint256,bytes)" "$REGISTRY" 0 "$inner")"
}

# Robust idempotency check — `isActive(bytes32)(bool)` is a clean bool, avoiding a
# brittle DeviceEntry struct decode (same approach heima-register-first-master.sh uses).
_already_registered() { local a; a="$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC" 2>/dev/null || echo false)"; [ "$a" = "true" ]; }

_operator_master_wallet() { cast call "$REGISTRY" "operatorMasterWallet(bytes32)(address)" "0x$OPERATOR_OMNI" --rpc-url "$RPC" 2>/dev/null | tr 'A-F' 'a-f'; }
# True if the operator ALREADY has a first master on chain. registerFirstMasterDevice
# is first-master-ONLY — a 2nd call reverts DeviceAlreadyRegistered. The existing
# master may be a DIFFERENT device than $DEVICE_KEY_HASH (e.g. the legacy EOA
# keccak(deployer_addr) from a prior setup-heima / heima-register-first-master.sh run).
_operator_bootstrapped() { case "$(_operator_master_wallet)" in 0x0000000000000000000000000000000000000000|0x0|"") return 1 ;; *) return 0 ;; esac; }

# Idempotency gate: if THIS device is active OR the operator already has any first
# master, print the skip JSON (reporting the ACTIVE device hash so the caller's
# cap-mint sends the right one) and exit 0. Otherwise return so the caller proceeds.
skip_if_bootstrapped() {
  _already_registered || _operator_bootstrapped || return 0
  local existing_dkh existing_wallet
  existing_dkh="$(resolve_active_master_dkh "$OPERATOR_OMNI" "$(printf '%s' "$DEPLOYER" | tr 'A-F' 'a-f')" || true)"
  existing_wallet="$(_operator_master_wallet)"
  skip "operator 0x$OPERATOR_OMNI already has a first master (wallet=$existing_wallet, active device=${existing_dkh:-$DEVICE_KEY_HASH}) — registerFirstMasterDevice is first-master-only; reusing the existing device"
  echo "{\"ok\":true,\"skipped\":\"already-registered\",\"device_key_hash\":\"${existing_dkh:-$DEVICE_KEY_HASH}\",\"account\":\"$ACCOUNT\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"master_wallet\":\"$existing_wallet\"}"
  exit 0
}

ensure_account_and_deposit() {
  # NOTE: `cast send` may exit non-zero merely because alloy can't deserialize
  # Heima's mixHash-less receipt block (a Substrate/Frontier header quirk — see
  # CLAUDE.md "Heima EVM compatibility level"); the tx still lands. So we ignore
  # the exit code (`|| true`) and verify success ON CHAIN — the e8-proven posture.
  if _has_code "$ACCOUNT"; then ok "account already deployed at $ACCOUNT";
  else
    log "createAccount (CREATE2, deployer pays gas) …"
    cast send "$FACTORY" "createAccount(bytes32,uint256,uint256,bytes32,bytes32)" \
      "$CRED_ID_HASH" "$PUBX" "$PUBY" "$RPID_HASH" "$SALT" \
      --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 1200000 >/dev/null 2>&1 || true
    _has_code "$ACCOUNT" || die "account not deployed at $ACCOUNT (createAccount tx did not land)"
    ok "account deployed (passkey-bound) at $ACCOUNT"
  fi
  local dep; dep="$(cast call "$EP" "balanceOf(address)(uint256)" "$ACCOUNT" --rpc-url "$RPC" | awk '{print $1}')"
  if [ "$dep" -lt "$MIN_DEPOSIT_WEI" ]; then
    log "fund EntryPoint deposit for the account (deployer pays) …"
    cast send "$EP" "depositTo(address)" "$ACCOUNT" --value "${DEPOSIT_WEI}wei" \
      --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 200000 >/dev/null 2>&1 || true
    dep="$(cast call "$EP" "balanceOf(address)(uint256)" "$ACCOUNT" --rpc-url "$RPC" | awk '{print $1}')"
    [ "$dep" -lt "$MIN_DEPOSIT_WEI" ] && die "EntryPoint deposit still $dep wei (< $MIN_DEPOSIT_WEI) — depositTo did not land"
  fi
  ok "account EntryPoint deposit = $dep wei"
}

# Build the UNSIGNED UserOp + userOpHash; persist context to $STATE_FILE.
build_userop() {
  # NONCE is GLOBAL (not local) so the register path's direct
  # submit_userop call sees it — the `submit` sub-command instead loads it from
  # the state file. (The local-`nonce` bug caused `NONCE: unbound variable`.)
  NONCE="$(cast call "$EP" "getNonce(address,uint192)(uint256)" "$ACCOUNT" 0 --rpc-url "$RPC" | awk '{print $1}')"
  local unsigned="($ACCOUNT,$NONCE,0x,$CALLDATA,$AGL,100000,$GASFEES,0x,0x)"
  USEROP_HASH="$(cast call "$EP" "getUserOpHash($UOP_TUPLE_T)(bytes32)" "$unsigned" --rpc-url "$RPC")"
  if [ -n "$STATE_FILE" ]; then
    {
      echo "ACCOUNT=$ACCOUNT"; echo "NONCE=$NONCE"; echo "CALLDATA=$CALLDATA"
      echo "DEVICE_KEY_HASH=$DEVICE_KEY_HASH"; echo "OPERATOR_OMNI=$OPERATOR_OMNI"
      echo "PUBX=$PUBX"; echo "PUBY=$PUBY"; echo "RPID_HASH=$RPID_HASH"
      echo "USEROP_HASH=$USEROP_HASH"
    } > "$STATE_FILE"
  fi
}

# Assemble the signed UserOp from an assertion + land it via handleOps.
submit_userop() {
  local credIdHash="$1" authData="$2" clientData="$3" loc="$4" r="$5" s="$6"
  log "K11 pre-check on the live verifier (free) …"
  local pre; pre="$(cast call "$K11" "verifyAssertion(bytes32,bytes32,bytes,bytes,uint256,uint256,uint256,uint256,uint256)(bool)" \
    "$USEROP_HASH" "$RPID_HASH" "$authData" "$clientData" "$loc" "$r" "$s" "$PUBX" "$PUBY" --rpc-url "$RPC" 2>&1 | tail -1)"
  [ "$pre" = "true" ] || die "K11 assertion does NOT verify ($pre) — wrong passkey / challenge != userOpHash"
  ok "assertion verifies against the live K11Verifier"
  local sig; sig="$(cast abi-encode "x(bytes32,bytes,bytes,uint256,uint256,uint256)" "$credIdHash" "$authData" "$clientData" "$loc" "$r" "$s")"
  local signed="($ACCOUNT,$NONCE,0x,$CALLDATA,$AGL,100000,$GASFEES,0x,$sig)"
  log "EntryPoint.handleOps (deployer pays the outer tx; account reimburses from deposit) …"
  # Ignore cast's exit code (Heima mixHash-less receipt → alloy logs an error but
  # the tx lands); the real success gate is the on-chain isActive check below.
  local out; out="$(cast send "$EP" "handleOps(${UOP_TUPLE_T}[],address)" "[$signed]" "$DEPLOYER" \
    --private-key "$PK" --rpc-url "$RPC" --legacy --gas-limit 3000000 2>&1 || true)"
  TX_HASH="$(printf '%s\n' "$out" | awk '/^transactionHash/ {print $2}' | head -1)"
  _already_registered || { printf '%s\n' "$out" >&2; die "post-tx isActive($DEVICE_KEY_HASH) is false — the register UserOp reverted inside handleOps (or never landed)"; }
  local owner; owner="$(cast call "$REGISTRY" "operatorMasterWallet(bytes32)(address)" "0x$OPERATOR_OMNI" --rpc-url "$RPC" | tr 'A-F' 'a-f')"
  [ "$owner" = "$(printf '%s' "$ACCOUNT" | tr 'A-F' 'a-f')" ] || die "operatorMasterWallet=$owner != account $ACCOUNT"
  ok "master registered — operatorMasterWallet[0x$OPERATOR_OMNI] = the passkey account $ACCOUNT (tx=$TX_HASH)"
}

case "$SUBCMD" in
  build)
    [ -n "$STATE_FILE" ] || die "build requires --state-file"
    derive_common
    skip_if_bootstrapped
    ensure_account_and_deposit
    build_userop
    log "register UserOp built — hand userOpHash to the passkey to sign"
    echo "    intent = registerFirstMasterDevice(operator=actor=0x$OPERATOR_OMNI, device=$DEVICE_KEY_HASH, roles=$ROLES) via account $ACCOUNT" >&2
    echo "{\"ok\":true,\"userop_hash\":\"$USEROP_HASH\",\"account\":\"$ACCOUNT\",\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"intent\":\"registerFirstMasterDevice\"}"
    ;;

  submit)
    [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || die "submit requires an existing --state-file (from build)"
    [ -n "$CRED_ID_HASH" ] && [ -n "$AUTHDATA" ] && [ -n "$CLIENTDATA" ] && [ -n "$CHALLENGE_LOC" ] && [ -n "$SIG_R" ] && [ -n "$SIG_S" ] \
      || die "submit requires --cred-id-hash --authdata --clientdata --challenge-loc --r --s"
    # shellcheck disable=SC1090
    . "$STATE_FILE"   # ACCOUNT NONCE CALLDATA DEVICE_KEY_HASH OPERATOR_OMNI PUBX PUBY RPID_HASH USEROP_HASH
    submit_userop "$CRED_ID_HASH" "$AUTHDATA" "$CLIENTDATA" "$CHALLENGE_LOC" "$SIG_R" "$SIG_S"
    echo "{\"ok\":true,\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"account\":\"$ACCOUNT\",\"tx_hash\":\"$TX_HASH\"}"
    ;;

  register)
    # All-in-one register. --signer picks the passkey implementation of the SAME #164
    # flow (P256Account + registerFirstMasterDevice via a P-256 WebAuthn UserOp through
    # handleOps; both emit the SAME assertion bytes the on-chain K11Verifier accepts —
    # Rust `agentkeys k11 {webauthn,software}-*`, no python):
    #   hardware (DEFAULT — LOCAL): the operator's Touch ID / Secure-Enclave K11 signs
    #       the userOpHash (a real biometric ceremony). No on-disk key. The secure path.
    #   software (CI / headless via --ci): a P-256 key in a file signs (no biometric).
    #       Weaker custody — CI/test only; the CLI prints a WARN (see arch.md §22b.1).
    # (The browser web-flow uses the build+submit sub-commands instead of this path.)
    RP_ID="${RP_ID:-localhost}"
    [ -n "$OPERATOR_OMNI_IN" ] || OPERATOR_OMNI_IN="$(printf 'agentkeysevm%s' "$(printf '%s' "$DEPLOYER" | tr 'A-F' 'a-f')" | shasum -a 256 | awk '{print $1}')"
    [ -n "$CRED_ID_HASH" ] || CRED_ID_HASH="$(cast keccak "agentkeys-register-cred:0x$(_omni "$OPERATOR_OMNI_IN")")"
    OPERATOR_OMNI="$(_omni "$OPERATOR_OMNI_IN")"
    [ "${#OPERATOR_OMNI}" = 64 ] || die "--operator-omni must be 32 bytes (got ${#OPERATOR_OMNI} hex)"
    DEVICE_KEY_HASH="$(cast keccak "0x$OPERATOR_OMNI")"
    # Idempotency BEFORE any ceremony: if the operator already has a first master, skip
    # NOW — don't prompt Touch ID (hardware) or generate a key (software) for a register
    # that would no-op. registerFirstMasterDevice is first-master-only.
    if _already_registered || _operator_bootstrapped; then
      existing_dkh="$(resolve_active_master_dkh "$OPERATOR_OMNI" "$(printf '%s' "$DEPLOYER" | tr 'A-F' 'a-f')" || true)"
      existing_wallet="$(_operator_master_wallet)"
      skip "operator 0x$OPERATOR_OMNI already has a first master (wallet=$existing_wallet, active device=${existing_dkh:-$DEVICE_KEY_HASH}) — first-master-only; reusing it (no ceremony)"
      echo "{\"ok\":true,\"skipped\":\"already-registered\",\"signer\":\"$SIGNER\",\"device_key_hash\":\"${existing_dkh:-$DEVICE_KEY_HASH}\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"master_wallet\":\"$existing_wallet\"}"
      exit 0
    fi
    case "$SIGNER" in
      hardware|webauthn|touchid)
        log "register: HARDWARE passkey (Touch ID), operator_omni=$OPERATOR_OMNI_IN, rp_id=$RP_ID"
        # Touch ID *create* if not yet enrolled; returns the Secure-Enclave K11 pubkey.
        eval "$("$BIN" k11 webauthn-keygen --operator-omni "0x$OPERATOR_OMNI" --rp-id "$RP_ID")"   # PUBX PUBY RPIDHASH
        ;;
      software|file|ci)
        # Stable per-operator passkey file → reproducible account address across re-runs.
        mkdir -p "$HOME/.agentkeys" 2>/dev/null || true
        [ -n "$KEY_FILE" ] || KEY_FILE="$HOME/.agentkeys/erc4337-register-$(printf '%s' "$OPERATOR_OMNI" | cut -c1-16).key"
        log "register: SOFTWARE passkey ($KEY_FILE) — CI/test only, file key + no biometric; operator_omni=$OPERATOR_OMNI_IN"
        eval "$("$BIN" k11 software-keygen --key-file "$KEY_FILE" --rp-id "$RP_ID")"   # PUBX PUBY RPIDHASH
        ;;
      *) die "unknown --signer '$SIGNER' (want: hardware | software)" ;;
    esac
    RPID_HASH="$RPIDHASH"
    STATE_FILE="${TMPDIR:-/tmp}/erc4337-register-state-$$"
    derive_common
    ensure_account_and_deposit
    build_userop
    case "$SIGNER" in
      hardware|webauthn|touchid)
        # Touch ID *get* over the raw userOpHash (challenge == userOpHash). The intent
        # text renders on the localhost confirmation page above the raw hash.
        eval "$("$BIN" k11 webauthn-userop-sign --operator-omni "0x$OPERATOR_OMNI" --userop-hash "$USEROP_HASH" --rp-id "$RP_ID" --intent-text "Register first master device (operator_omni=0x$OPERATOR_OMNI) on SidecarRegistry")"  # AUTHDATA CDJ CHALLENGE_LOC R S
        ;;
      *)
        eval "$("$BIN" k11 software-sign --key-file "$KEY_FILE" --userop-hash "$USEROP_HASH" --rp-id "$RP_ID")"  # AUTHDATA CDJ CHALLENGE_LOC R S
        ;;
    esac
    submit_userop "$CRED_ID_HASH" "$AUTHDATA" "$CDJ" "$CHALLENGE_LOC" "$R" "$S"
    rm -f "$STATE_FILE"
    echo "{\"ok\":true,\"signer\":\"$SIGNER\",\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"account\":\"$ACCOUNT\",\"tx_hash\":\"$TX_HASH\"}"
    ;;

  *)
    die "usage: erc4337-register-master.sh [register] | build | submit [flags]  — register is the default (no sub-command needed); try --help"
    ;;
esac
