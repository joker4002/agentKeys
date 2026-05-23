#!/usr/bin/env bash
# scripts/heima-scope-revoke.sh — revoke an agent's scope on the live
# AgentKeysScope contract. Wraps `AgentKeysScope.revokeScope(...)`
# per arch.md §12.4.
#
# Stage-1: K11 assertion is a non-empty stub (same as scope-set).
# Idempotency: pre-read the existing scope. If services array is empty,
# the scope is already revoked and we skip.
#
# Usage:
#   bash scripts/heima-scope-revoke.sh --agent demo-agent

set -euo pipefail

LABEL=""
DRY_RUN=0
SCOPE_CONTRACT=""
USE_WEBAUTHN=0  # arch.md §22b.1 — pass --webauthn for real Touch ID ceremony.

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)            [ $# -lt 2 ] && { echo "--agent requires a value" >&2; exit 1; }; LABEL="$2"; shift 2 ;;
    --agent=*)          LABEL="${1#*=}"; shift ;;
    --scope-address)    SCOPE_CONTRACT="$2"; shift 2 ;;
    --scope-address=*)  SCOPE_CONTRACT="${1#*=}"; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    --webauthn)         USE_WEBAUTHN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
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

[ -z "$LABEL" ] && die "--agent <label> is required"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# Resolve agentkeys binary (workspace-local first; avoids stale ~/.local/bin).
if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
elif [ -x "$REPO_ROOT/target/debug/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/debug/agentkeys"
elif command -v agentkeys >/dev/null 2>&1; then
  AGENTKEYS_BIN="$(command -v agentkeys)"
else
  die "agentkeys binary not found (try: cargo build -p agentkeys-cli)"
fi

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$SCOPE_CONTRACT" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "SCOPE_CONTRACT=\${SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$SCOPE_CONTRACT" ] && die "--scope-address required"
if [ "$AGENTKEYS_CHAIN" = "heima" ]; then
  case "$(printf '%s' "$SCOPE_CONTRACT" | tr '[:upper:]' '[:lower:]')" in
    0x000000000000000000000000000000000000000[1-4])
      die "AgentKeysScope address $SCOPE_CONTRACT is the operator-workstation.env sentinel — run bash scripts/heima-bring-up.sh first." ;;
  esac
fi

AGENT_FILE="$HOME/.agentkeys/agents/${LABEL}.json"
[ -f "$AGENT_FILE" ] || die "no agent registered for label '$LABEL'"
ACTOR_OMNI=$(jq -r .actor_omni "$AGENT_FILE")
[ "$ACTOR_OMNI" = "null" ] && die "agent file missing actor_omni"

# Master key via shared _lib.sh (raw-hex or mnemonic).
. "$REPO_ROOT/harness/scripts/_lib.sh"
MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')

# Stage-2 K11 assertion: real WebAuthn ceremony required. CI/no-Touch-ID
# environments skip cleanly rather than block — stage-2 contract gates on
# real K11 by design, no way around the Touch ID prompt for chain mutation.
PRIMARY_DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")
PRIMARY_K11_FILE="$HOME/.agentkeys/k11/${OPERATOR_OMNI}.json"
if [ ! -f "$PRIMARY_K11_FILE" ] || [ "$(jq -r .mode "$PRIMARY_K11_FILE" 2>/dev/null)" != "webauthn" ]; then
  skip "primary K11 not enrolled with mode=webauthn — stage-2 revokeScope requires real K11 sig"
  echo "{\"ok\":true,\"skipped\":\"no-webauthn-k11\"}"
  exit 0
fi
# Stub-mode caller (no --webauthn) on a laptop with a stale webauthn K11
# enrollment: skip cleanly instead of triggering Touch ID.
if [ "$USE_WEBAUTHN" = "0" ]; then
  skip "stub mode (no --webauthn) — refusing to trigger a Touch ID ceremony for revokeScope. Re-run with --webauthn to actually revoke, or accept the skip in CI."
  echo "{\"ok\":true,\"skipped\":\"stub-mode-refuses-touchid\"}"
  exit 0
fi
MODE=$(jq -r .mode "$PRIMARY_K11_FILE")

# Compute expected challenge per contract: keccak256(abi.encode(
#   OP_REVOKE_SCOPE, operatorOmni, agentOmni, chainid, scopeNonce))
SCOPE_NONCE=$(cast call "$SCOPE_CONTRACT" \
  "scopeNonce(bytes32,bytes32)(uint256)" "0x$OPERATOR_OMNI" "$ACTOR_OMNI" \
  --rpc-url "$RPC_HTTP")
OP_KIND=$(cast call "$SCOPE_CONTRACT" "OP_REVOKE_SCOPE()(bytes32)" --rpc-url "$RPC_HTTP")
CHALLENGE=$(cast keccak "$(cast abi-encode \
  'revokeScope(bytes32,bytes32,bytes32,uint256,uint256)' \
  "$OP_KIND" "0x$OPERATOR_OMNI" "$ACTOR_OMNI" "$LIVE_CHAIN_ID" "$SCOPE_NONCE")")
log "expected_challenge = $CHALLENGE"

log "Requesting K11 assertion from PRIMARY master (Touch ID prompt)…"
# Typed K11 intent — wiki/k11-intent-conventions.md.
INTENT_JSON=$(jq -n \
  --arg op_omni "0x${OPERATOR_OMNI}" \
  --arg asserting_hash "${PRIMARY_DEVICE_KEY_HASH}" \
  --arg agent_label "${LABEL}" \
  --arg agent_omni "${ACTOR_OMNI}" \
  --argjson chain_id "${LIVE_CHAIN_ID}" \
  --argjson nonce "${SCOPE_NONCE}" \
  '{
    kind: "set_scope_revoke",
    operator_omni: $op_omni,
    agent_label: $agent_label,
    agent_omni: $agent_omni,
    chain_id: $chain_id,
    scope_nonce: $nonce,
    asserting: { kind: "primary", device_key_hash: $asserting_hash }
  }')
K11_ERR=$(mktemp -t heima-scope-revoke-k11.XXXXXX) || die "mktemp failed"
ASSERTION_JSON=$("$AGENTKEYS_BIN" k11 assert \
  --webauthn --rp-id localhost --emit-chain-payload \
  --operator-omni "0x$OPERATOR_OMNI" \
  --message-hex "$CHALLENGE" \
  --intent-op-json "$INTENT_JSON" 2>"$K11_ERR") \
  || {
    echo "==> K11 assert stderr ↓ ↓ ↓" >&2
    cat "$K11_ERR" >&2
    echo "==> K11 assert stderr ↑ ↑ ↑" >&2
    rm -f "$K11_ERR"
    die "primary K11 ceremony failed (see stderr above for root cause)"
  }
rm -f "$K11_ERR"

K11_AUTH_DATA=$(echo "$ASSERTION_JSON" | jq -r .authenticator_data_hex)
K11_CDJ_UTF8=$(echo "$ASSERTION_JSON" | jq -r .client_data_json_utf8)
K11_CDJ_HEX="0x$(printf '%s' "$K11_CDJ_UTF8" | xxd -p -c 65536 | tr -d '\n')"
K11_CHALL_LOC=$(echo "$ASSERTION_JSON" | jq -r .challenge_location)
K11_R_HEX=$(echo "$ASSERTION_JSON" | jq -r .r_hex)
K11_S_HEX=$(echo "$ASSERTION_JSON" | jq -r .s_hex)
K11_TUPLE="($PRIMARY_DEVICE_KEY_HASH,$K11_AUTH_DATA,$K11_CDJ_HEX,$K11_CHALL_LOC,$K11_R_HEX,$K11_S_HEX)"

log "Inputs"
echo "    chain         = $AGENTKEYS_CHAIN" >&2
echo "    scope         = $SCOPE_CONTRACT" >&2
echo "    operator_omni = 0x$OPERATOR_OMNI" >&2
echo "    actor_omni    = $ACTOR_OMNI" >&2

# Idempotency: read current scope. Same struct-of-tuple ABI fix as heima-scope-set.sh
# — cast needs the outer parens to decode the Scope struct correctly. Without them
# cast errors with "ABI decoding failed: buffer overrun" and we silently fall
# through to the cast-send branch.
log "Idempotency check …"
EXISTING_SCOPE=$(cast call "$SCOPE_CONTRACT" \
  "getScope(bytes32,bytes32)((bytes32[],bool,uint128,uint128,uint128,uint32,uint64,bool))" \
  "0x$OPERATOR_OMNI" "$ACTOR_OMNI" \
  --rpc-url "$RPC_HTTP" 2>&1 || echo ERR)
if [ "$EXISTING_SCOPE" != "ERR" ] && [ -n "$EXISTING_SCOPE" ]; then
  # Codex review: fail loud on parser failure instead of silently proceeding.
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 required for getScope idempotency parser — install python3 and re-run"
  fi
  # `set -e` would abort before PARSE_RC inspection (codex pass-2 finding).
  set +e
  PARSED=$(python3 - <<'PYEOF' "$EXISTING_SCOPE"
import sys, re
raw = sys.argv[1].strip()
m = re.match(r"\((.*)\)$", raw, re.DOTALL)
if not m: sys.exit(1)
inner = m.group(1).strip()
arr_match = re.match(r"^\[([^\]]*)\]\s*,\s*(.*)$", inner, re.DOTALL)
if not arr_match: sys.exit(1)
services_inner = arr_match.group(1).strip()
rest = arr_match.group(2)
parts = [p.strip().split()[0] if p.strip() else "" for p in rest.split(",")]
if len(parts) < 7: sys.exit(1)
hashes = [h.strip() for h in services_inner.split(",") if h.strip()]
print("[" + ",".join(hashes) + "]")
print(parts[-1])  # exists
PYEOF
)
  PARSE_RC=$?
  set -e
  if [ "$PARSE_RC" != "0" ]; then
    die "python3 getScope parser failed (exit $PARSE_RC). Raw cast output: $EXISTING_SCOPE"
  fi
  if [ -n "$PARSED" ]; then
    EX_SERVICES=$(printf '%s\n' "$PARSED" | sed -n '1p')
    EX_EXISTS=$(printf '%s\n' "$PARSED" | sed -n '2p')
    if [ "$EX_EXISTS" != "true" ] || [ "$EX_SERVICES" = "[]" ]; then
      skip "scope already revoked or never set"
      rm -f "$HOME/.agentkeys/agents/${LABEL}.scope.json"
      echo "{\"ok\":true,\"skipped\":\"already-revoked\",\"agent\":\"$LABEL\"}"
      exit 0
    fi
  fi
fi
ok "scope is live → revoking"

CAST_ARGS=(
  send "$SCOPE_CONTRACT"
  "revokeScope(bytes32,bytes32,(bytes32,bytes,bytes,uint256,uint256,uint256))"
  "0x$OPERATOR_OMNI" "$ACTOR_OMNI" "$K11_TUPLE"
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
  echo "{\"ok\":true,\"dry_run\":true,\"agent\":\"$LABEL\"}"
  exit 0
fi

log "Submitting revokeScope tx via cast send …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
if [ "$CAST_RC" != "0" ]; then
  echo "$CAST_OUT" >&2
  die "cast send failed (exit $CAST_RC)"
fi

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

rm -f "$HOME/.agentkeys/agents/${LABEL}.scope.json"
ok "scope revoked — txhash $TX_HASH (block $BLOCK_NUM)"
echo "{\"ok\":true,\"agent\":\"$LABEL\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\"}"
