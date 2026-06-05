#!/usr/bin/env bash
# scripts/heima-register-first-master.sh — bootstrap the operator's first
# master device against the v2 stage-2 SidecarRegistry (arch.md §10.1).
#
# ⚠️ DEPRECATED (old-model EOA register). This signs registerFirstMasterDevice
# DIRECTLY with the deployer EOA, so operatorMasterWallet = a raw EOA — it does
# NOT follow the #164 passkey-account pattern. The harness register helper
# (register_first_master in _lib.sh) NO LONGER uses this automatically; the only
# supported register is the #164 passkey-account path (erc4337-register-master.sh).
# This script survives as a loud, explicit emergency escape (AGENTKEYS_REGISTER_MODE=eoa)
# and for any not-yet-migrated callers (setup-heima.sh / heima-device-register.sh).
# Do not add new callers — use erc4337-register-master.sh.
#
# Idempotent: pre-reads `getDevice(deviceKeyHash).registeredAt` and exits 0
# with skip when the device is already registered.
#
# Usage:
#   # CLI / harness path (operator == deployer; reads the disk K11 file):
#   bash scripts/heima-register-first-master.sh \
#        [--registry-address 0x...] [--dry-run]
#
#   # Web-onboarding path (issue #196 — daemon ui-bridge shells out here):
#   bash scripts/heima-register-first-master.sh \
#        --operator-omni 0x<session_omni> [--actor-omni 0x<session_omni>] \
#        --k11-cose-hex <130-hex SEC1 pubkey> --k11-cred-id <b64url> [--rp-id localhost]
#
# Reads primary master K11 pubkey + cred-id from
# `~/.agentkeys/k11/<omni>.json` (must be `mode: "webauthn"`) UNLESS the web
# overrides (--operator-omni + --k11-cose-hex) are passed, in which case the
# omni is the managed-wallet *session* omni and the K11 pubkey comes from the
# browser passkey (no disk file; the deployer key still signs = msg.sender).
# device_key_hash defaults to keccak(operator_omni) on the web path so one
# deployer key signing for many session omnis never collides.
#
# ⚠️ ANTI-FRONT-RUN (issue #165) — REDEPLOY-COORDINATED CHANGE PENDING.
# The hardened SidecarRegistry now requires a K11 *self-attestation* at
# bootstrap, bound to msg.sender (defeats the mempool front-run). The new ABI is:
#   registerFirstMasterDevice(bytes32,bytes32,bytes32,bytes32,bytes32,uint256,
#     uint256,uint8,(bytes32,bytes,bytes,uint256,uint256,uint256))
# where the trailing tuple is the K11Assertion (attestingDeviceKeyHash,
# authenticatorData, clientDataJSON, challengeLocation, r, s) signed over
#   keccak256(abi.encode(OP_REGISTER_1ST_MASTER, operatorOmni, actorOmni,
#     deviceKeyHash, k11PubX, k11PubY, roles, msg.sender, block.chainid, registry))
# Generate the assertion exactly like scripts/heima-scope-set.sh --webauthn
# (cast abi-encode → cast keccak → `agentkeys k11 assert`).
# The `cast send` below still targets the OLD (pre-#165) deployed registry ABI.
# Flip it to the new ABI + self-attestation IN THE SAME CHANGE that REDEPLOYS
# SidecarRegistry (then update docs/spec/deployed-contracts.md +
# scripts/operator-workstation.env + re-run verify-heima-contracts.sh). Until
# that coordinated redeploy, this script bootstraps against the old contract.

set -euo pipefail

REGISTRY=""
DRY_RUN=0
DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-deployer.key}"
ROLES=7   # CAP_MINT | RECOVERY | SCOPE_MGMT = full powers for first master

# Web-onboarding overrides (issue #196). When the daemon ui-bridge shells out
# here after a browser K11 enrollment, the master's operator/actor omni is the
# managed-wallet *session* omni (cap.rs forces device.operator_omni ==
# J1.omni_account == req.operator_omni), NOT the deployer-derived omni. The
# deployer key still SIGNS the tx (msg.sender = gas payer = operatorMasterWallet
# value) — issue #196 option (α): the stored wallet diverges from the managed
# wallet, which is fine for cap-mint (it checks the device, not msg.sender).
# All overrides default to the legacy deployer-derived values so existing CLI /
# harness callers (no flags) behave identically.
OPERATOR_OMNI_OVERRIDE=""   # bare or 0x-prefixed 32-byte hex
ACTOR_OMNI_OVERRIDE=""      # defaults to operator omni (master-self)
DEVICE_KEY_HASH_OVERRIDE="" # defaults to keccak(operator_omni) when omni overridden, else keccak(deployer_addr)
K11_COSE_HEX_OVERRIDE=""    # 130-hex SEC1 uncompressed P-256 pubkey from the web passkey (no disk K11 file)
K11_CRED_ID_OVERRIDE=""     # WebAuthn credential id (b64url); sha256-hashed for on-chain storage
RP_ID_OVERRIDE=""           # WebAuthn rp_id the passkey was enrolled under (sha256'd to k11RpIdHash)
RP_ID_HASH_OVERRIDE=""      # k11RpIdHash directly (authData[0:32]); preferred over --rp-id on the web path

while [ $# -gt 0 ]; do
  case "$1" in
    --registry-address)   REGISTRY="$2"; shift 2 ;;
    --registry-address=*) REGISTRY="${1#*=}"; shift ;;
    --roles)              ROLES="$2"; shift 2 ;;
    --roles=*)            ROLES="${1#*=}"; shift ;;
    --operator-omni)      OPERATOR_OMNI_OVERRIDE="$2"; shift 2 ;;
    --operator-omni=*)    OPERATOR_OMNI_OVERRIDE="${1#*=}"; shift ;;
    --actor-omni)         ACTOR_OMNI_OVERRIDE="$2"; shift 2 ;;
    --actor-omni=*)       ACTOR_OMNI_OVERRIDE="${1#*=}"; shift ;;
    --device-key-hash)    DEVICE_KEY_HASH_OVERRIDE="$2"; shift 2 ;;
    --device-key-hash=*)  DEVICE_KEY_HASH_OVERRIDE="${1#*=}"; shift ;;
    --k11-cose-hex)       K11_COSE_HEX_OVERRIDE="$2"; shift 2 ;;
    --k11-cose-hex=*)     K11_COSE_HEX_OVERRIDE="${1#*=}"; shift ;;
    --k11-cred-id)        K11_CRED_ID_OVERRIDE="$2"; shift 2 ;;
    --k11-cred-id=*)      K11_CRED_ID_OVERRIDE="${1#*=}"; shift ;;
    --rp-id)              RP_ID_OVERRIDE="$2"; shift 2 ;;
    --rp-id=*)            RP_ID_OVERRIDE="${1#*=}"; shift ;;
    --rp-id-hash)         RP_ID_HASH_OVERRIDE="$2"; shift 2 ;;
    --rp-id-hash=*)       RP_ID_HASH_OVERRIDE="${1#*=}"; shift ;;
    --dry-run)            DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_SKIP='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_SKIP=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
skip() { printf "    ${C_SKIP}skip${C_RESET} %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# Resolve agentkeys binary (workspace-local first).
if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
elif [ -x "$REPO_ROOT/target/debug/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/debug/agentkeys"
else
  AGENTKEYS_BIN="$(command -v agentkeys || true)"
  [ -n "$AGENTKEYS_BIN" ] || die "agentkeys binary not found"
fi

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_JSON=$("$AGENTKEYS_BIN" chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$REGISTRY" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$REGISTRY" ] && die "--registry-address required (or set SIDECAR_REGISTRY_ADDRESS_*)"
case "$(printf '%s' "$REGISTRY" | tr '[:upper:]' '[:lower:]')" in
  0x000000000000000000000000000000000000000[1-4])
    die "registry $REGISTRY is the sentinel — deploy contracts first" ;;
esac

# Resolve deployer key (raw hex or mnemonic file).
if [ -f "$DEPLOYER_KEY_FILE" ]; then
  RAW=$(cat "$DEPLOYER_KEY_FILE" | tr -d '\n[:space:]')
  if [ "${#RAW}" = "66" ] && [ "${RAW:0:2}" = "0x" ]; then
    MASTER_KEY="$RAW"
  elif [ "${#RAW}" = "64" ]; then
    MASTER_KEY="0x$RAW"
  else
    # Treat as mnemonic
    if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
      npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund >/dev/null
    fi
    DERIV=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$DEPLOYER_KEY_FILE")
    MASTER_KEY=$(echo "$DERIV" | jq -r .privateKey)
  fi
else
  die "deployer key file not found at $DEPLOYER_KEY_FILE (set HEIMA_DEPLOYER_KEY_FILE)"
fi
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')

# normalize_omni: strip 0x, lowercase, require exactly 64 hex chars (32 bytes).
normalize_omni() {
  local v
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  v="${v#0x}"
  case "$v" in *[!0-9a-f]*) die "omni '$1' is not hex" ;; esac
  [ "${#v}" = "64" ] || die "omni '$1' must be 32 bytes (64 hex), got ${#v}"
  printf '%s' "$v"
}

# operator_omni: --operator-omni override (web path: the managed-wallet session
# omni) else legacy deployer-derived. actor_omni defaults to operator (master-self).
if [ -n "$OPERATOR_OMNI_OVERRIDE" ]; then
  OPERATOR_OMNI=$(normalize_omni "$OPERATOR_OMNI_OVERRIDE")
else
  OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')
fi
if [ -n "$ACTOR_OMNI_OVERRIDE" ]; then
  ACTOR_OMNI=$(normalize_omni "$ACTOR_OMNI_OVERRIDE")
else
  ACTOR_OMNI="$OPERATOR_OMNI"
fi

# device_key_hash: explicit override > keccak(operator_omni) when the omni is
# overridden (web path — distinct per session omni so one deployer key signing
# for many masters can't collide on a single keccak(deployer_addr)) > legacy
# keccak(deployer_addr) (CLI/harness, operator == deployer).
if [ -n "$DEVICE_KEY_HASH_OVERRIDE" ]; then
  DEVICE_KEY_HASH=$(printf '%s' "$DEVICE_KEY_HASH_OVERRIDE" | tr '[:upper:]' '[:lower:]')
  case "$DEVICE_KEY_HASH" in 0x*) ;; *) DEVICE_KEY_HASH="0x$DEVICE_KEY_HASH" ;; esac
elif [ -n "$OPERATOR_OMNI_OVERRIDE" ]; then
  DEVICE_KEY_HASH=$(cast keccak "0x$OPERATOR_OMNI")
else
  DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")
fi

# K11 pubkey + cred id + rp-id come from one of two sources:
#   (a) --k11-cose-hex (web path, issue #196): the daemon ui-bridge passes the
#       browser passkey's SEC1 pubkey directly — there is no
#       ~/.agentkeys/k11/<omni>.json on disk (web K11 enrollment is in-memory).
#       This IS a real WebAuthn key (the H2 disk-stub gate guards the disk path,
#       which a synthetic key could poison; an explicit caller-supplied web key
#       does not go through disk so that attack surface doesn't apply here).
#   (b) disk file (CLI/harness path) — unchanged, still mode-gated (H2).
USE_DISK_K11=1
if [ -n "$K11_COSE_HEX_OVERRIDE" ]; then
  USE_DISK_K11=0
  COSE_NOPREFIX="${K11_COSE_HEX_OVERRIDE#0x}"
  [ "${#COSE_NOPREFIX}" = "130" ] \
    || die "--k11-cose-hex unexpected length ${#COSE_NOPREFIX} (expected 130 hex = SEC1 uncompressed P-256)"
  K11_PUB_X="0x${COSE_NOPREFIX:2:64}"
  K11_PUB_Y="0x${COSE_NOPREFIX:66:64}"
  [ -n "$K11_CRED_ID_OVERRIDE" ] || die "--k11-cose-hex requires --k11-cred-id"
  K11_CRED_ID=$(printf '%s' "$K11_CRED_ID_OVERRIDE" | shasum -a 256 | awk '{print "0x"$1}')
  if [ -n "$RP_ID_HASH_OVERRIDE" ]; then
    # k11RpIdHash straight from the credential's authData[0:32] — exact match to
    # the authenticator-bound rpIdHash (forward-compatible with the hardened
    # contract that checks authData[0:32] == k11RpIdHash).
    K11_RP_ID_HASH=$(printf '%s' "$RP_ID_HASH_OVERRIDE" | tr '[:upper:]' '[:lower:]')
    case "$K11_RP_ID_HASH" in 0x*) ;; *) K11_RP_ID_HASH="0x$K11_RP_ID_HASH" ;; esac
  else
    RP_ID="${RP_ID_OVERRIDE:-localhost}"
    K11_RP_ID_HASH=$(printf '%s' "$RP_ID" | shasum -a 256 | awk '{print "0x"$1}')
  fi
fi

if [ "$USE_DISK_K11" = "1" ]; then
# Load primary K11 pubkey + cred id from disk.
K11_FILE="$HOME/.agentkeys/k11/${OPERATOR_OMNI}.json"
[ -f "$K11_FILE" ] || die "K11 enrollment not found at $K11_FILE — run \`agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x$OPERATOR_OMNI\` first"
MODE=$(jq -r .mode "$K11_FILE")
# Mode gate. WebAuthn is the only acceptable mode for production-chain
# registration; the stage-1 CI stub is opt-in via AGENTKEYS_STAGE1_STUB_OK=1
# (set ONLY by harness/v2-stage1-demo.sh; setup-heima.sh + every other
# operator script never sets it). The on-chain contract only enforces
# length != 0 on the pubkey today (arch.md §22b.1 stage-1 simplification),
# so without this env gate a local harness run could write a stub K11 file
# into $HOME/.agentkeys/k11/, and a later prod `setup-heima.sh` run from
# the same $HOME would silently register a synthetic non-WebAuthn-backed
# master device on Heima mainnet. Codex adversarial review 2026-05-23 [H2].
case "$MODE" in
  webauthn) ;;
  stage1-stub)
    if [ "${AGENTKEYS_STAGE1_STUB_OK:-0}" != "1" ]; then
      die "K11 file at $K11_FILE has mode=stage1-stub but AGENTKEYS_STAGE1_STUB_OK is unset.
This file was written by the harness CI stub path and MUST NOT be registered
on Heima mainnet via setup-heima.sh / heima-register-first-master.sh from a
prod operator's machine. Re-enroll with --webauthn for real ceremony, or
re-run via harness/v2-stage1-demo.sh which sets the env gate explicitly.
(Codex H2: stage1-stub bypass on prod chain blocked.)"
    fi
    info "stage1-stub mode accepted under AGENTKEYS_STAGE1_STUB_OK=1 (CI/harness path)"
    ;;
  *)
    die "K11 file at $K11_FILE has mode=$MODE (expected 'webauthn' or 'stage1-stub' under AGENTKEYS_STAGE1_STUB_OK=1) — re-enroll with --webauthn"
    ;;
esac
COSE_HEX=$(jq -r .cose_pubkey_hex "$K11_FILE")
COSE_NOPREFIX="${COSE_HEX#0x}"
[ "${#COSE_NOPREFIX}" = "130" ] || die "K11 cose_pubkey_hex unexpected length ${#COSE_NOPREFIX} (expected 130)"
K11_PUB_X="0x${COSE_NOPREFIX:2:64}"
K11_PUB_Y="0x${COSE_NOPREFIX:66:64}"
# k11CredId — the WebAuthn credential id, b64url. Hash it for bytes32 storage.
CRED_B64URL=$(jq -r .credential_id_b64url "$K11_FILE")
K11_CRED_ID=$(printf '%s' "$CRED_B64URL" | shasum -a 256 | awk '{print "0x"$1}')

# Codex H1: contract enforces authData[0:32] == sha256(rp_id). Bind the
# stored value to the rp_id this credential was actually enrolled under
# so cross-RP replays are impossible.
RP_ID=$(jq -r .rp_id "$K11_FILE")
[ -n "$RP_ID" ] && [ "$RP_ID" != "null" ] || RP_ID="localhost"
K11_RP_ID_HASH=$(printf '%s' "$RP_ID" | shasum -a 256 | awk '{print "0x"$1}')
fi

log "Inputs"
echo "    chain         = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    registry      = $REGISTRY" >&2
echo "    signer (gas)  = $MASTER_ADDR (msg.sender = operatorMasterWallet)" >&2
echo "    operator_omni = 0x$OPERATOR_OMNI" >&2
echo "    actor_omni    = 0x$ACTOR_OMNI" >&2
echo "    deviceKeyHash = $DEVICE_KEY_HASH" >&2
echo "    roles         = $ROLES (CAP_MINT|RECOVERY|SCOPE_MGMT = 7)" >&2

# Idempotency: pre-read getDevice. If already registered, skip.
log "Idempotency check …"
EXISTING=$(cast call "$REGISTRY" "getDevice(bytes32)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>&1 || echo "")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "0x" ]; then
  HEX=$(printf '%s' "$EXISTING" | tr -d '\n' | sed 's/^0x//')
  # New DeviceEntry layout is larger; registeredAt sits at offset depending on
  # struct ordering. Just check operatorMasterWallet — if non-zero, the operator
  # is bootstrapped and this device is the one.
  EXISTING_MASTER=$(cast call "$REGISTRY" "operatorMasterWallet(bytes32)(address)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP" 2>/dev/null || true)
  if [ -n "$EXISTING_MASTER" ] && [ "$(echo "$EXISTING_MASTER" | tr '[:upper:]' '[:lower:]')" != "0x0000000000000000000000000000000000000000" ]; then
    ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "false")
    if [ "$ACTIVE" = "true" ]; then
      skip "first master already registered + active"
      echo "{\"ok\":true,\"skipped\":\"already-registered\",\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"actor_omni\":\"0x$ACTOR_OMNI\"}"
      exit 0
    fi
  fi
fi
ok "first master not yet registered → proceeding"

CAST_ARGS=(
  send "$REGISTRY"
  "registerFirstMasterDevice(bytes32,bytes32,bytes32,bytes32,bytes32,uint256,uint256,bytes,uint8)"
  "$DEVICE_KEY_HASH" "0x$OPERATOR_OMNI" "0x$ACTOR_OMNI" "$K11_CRED_ID" "$K11_RP_ID_HASH" \
  "$K11_PUB_X" "$K11_PUB_Y" "0x00" "$ROLES"
  --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" --private-key "$MASTER_KEY"
)

if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would invoke (private key redacted):"
  printf '    cast' >&2
  for a in "${CAST_ARGS[@]}"; do
    case "$a" in
      "$MASTER_KEY") printf ' [REDACTED]' >&2 ;;
      *) printf ' %s' "$a" >&2 ;;
    esac
  done
  printf '\n' >&2
  echo "{\"ok\":true,\"dry_run\":true,\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"actor_omni\":\"0x$ACTOR_OMNI\"}"
  exit 0
fi

log "Submitting registerFirstMasterDevice tx …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
[ "$CAST_RC" = "0" ] || { echo "$CAST_OUT" >&2; die "cast send failed"; }

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

# Post-tx verify.
ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$DEVICE_KEY_HASH" --rpc-url "$RPC_HTTP")
[ "$ACTIVE" = "true" ] || die "post-tx isActive($DEVICE_KEY_HASH) = $ACTIVE"

ok "first master registered — tx=$TX_HASH block=$BLOCK_NUM"
echo "{\"ok\":true,\"device_key_hash\":\"$DEVICE_KEY_HASH\",\"operator_omni\":\"0x$OPERATOR_OMNI\",\"actor_omni\":\"0x$ACTOR_OMNI\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\"}"
