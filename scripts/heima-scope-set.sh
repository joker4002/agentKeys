#!/usr/bin/env bash
# scripts/heima-scope-set.sh — grant or replace an agent's scope on the
# live AgentKeysScope contract. Wraps
# `AgentKeysScope.setScopeWithWebauthn(...)` per arch.md §12.4.
#
# Stage-1 simplification (per arch.md §22b stage-1 simplifications inventory):
#   - K11 assertion is a non-empty stub byte string (the contract checks
#     `k11Assertion.length != 0` but doesn't P-256-verify on-chain yet).
#     Stage 2 replaces the stub with a real WebAuthn assertion.
#   - msg.sender = the operator's master EVM wallet (the contract checks
#     `msg.sender == registry.operatorMasterWallet[operator]`).
#
# Idempotency: pre-read AgentKeysScope.getScope(operator, agent). If the
# stored services array + caps + readOnly match what we'd write, skip.
#
# Usage:
#   bash scripts/heima-scope-set.sh --agent demo-agent --services openrouter,coinmarketcap
#   bash scripts/heima-scope-set.sh --agent demo-agent --services openrouter \
#     --max-per-call 1000000000 --max-per-period 50000000000 \
#     --period-seconds 86400 --read-only

set -euo pipefail

LABEL=""
SERVICES_RAW=""
READ_ONLY="false"
MAX_PER_CALL="0"
MAX_PER_PERIOD="0"
MAX_TOTAL="0"
PERIOD_SECONDS="0"
DRY_RUN=0
SCOPE_CONTRACT=""
USE_WEBAUTHN=0  # 0 = stub bytes (CI-friendly); 1 = real Touch ID ceremony
                # via `agentkeys k11 assert --webauthn` (arch.md §22b.1).

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)            [ $# -lt 2 ] && { echo "--agent requires a value" >&2; exit 1; }; LABEL="$2"; shift 2 ;;
    --agent=*)          LABEL="${1#*=}"; shift ;;
    --services)         [ $# -lt 2 ] && { echo "--services requires a value" >&2; exit 1; }; SERVICES_RAW="$2"; shift 2 ;;
    --services=*)       SERVICES_RAW="${1#*=}"; shift ;;
    --read-only)        READ_ONLY="true"; shift ;;
    --max-per-call)     MAX_PER_CALL="$2"; shift 2 ;;
    --max-per-call=*)   MAX_PER_CALL="${1#*=}"; shift ;;
    --max-per-period)   MAX_PER_PERIOD="$2"; shift 2 ;;
    --max-per-period=*) MAX_PER_PERIOD="${1#*=}"; shift ;;
    --max-total)        MAX_TOTAL="$2"; shift 2 ;;
    --max-total=*)      MAX_TOTAL="${1#*=}"; shift ;;
    --period-seconds)   PERIOD_SECONDS="$2"; shift 2 ;;
    --period-seconds=*) PERIOD_SECONDS="${1#*=}"; shift ;;
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

[ -z "$LABEL" ]        && die "--agent <label> is required"
[ -z "$SERVICES_RAW" ] && die "--services <comma-sep names> is required"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
set -a; . "$ENV_FILE"; set +a

# Resolve the agentkeys binary: prefer workspace-local builds (operator
# just built / is iterating), fall back to PATH (installed via
# install-agentkeys-cli.sh). Avoids confusion when ~/.local/bin holds
# a stale binary missing the k11 subcommand.
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
case "$AGENTKEYS_CHAIN" in
  heima|heima-paseo) ;;
  *) die "unsupported chain: $AGENTKEYS_CHAIN" ;;
esac
PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$RPC_HTTP" | jq -r .result)")

if [ -z "$SCOPE_CONTRACT" ]; then
  PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  eval "SCOPE_CONTRACT=\${SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC}:-}"
fi
[ -z "$SCOPE_CONTRACT" ] && die "--scope-address required (or set \$SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC:-HEIMA})"
if [ "$AGENTKEYS_CHAIN" = "heima" ]; then
  case "$(printf '%s' "$SCOPE_CONTRACT" | tr '[:upper:]' '[:lower:]')" in
    0x000000000000000000000000000000000000000[1-4])
      die "AgentKeysScope address $SCOPE_CONTRACT is the operator-workstation.env sentinel — run bash scripts/heima-bring-up.sh first." ;;
  esac
fi

# Load agent metadata.
AGENT_FILE="$HOME/.agentkeys/agents/${LABEL}.json"
[ -f "$AGENT_FILE" ] || die "no agent registered for label '$LABEL' at $AGENT_FILE (run heima-agent-create.sh first)"
AGENT_ADDR=$(jq -r .agent_address "$AGENT_FILE")
ACTOR_OMNI=$(jq -r .actor_omni "$AGENT_FILE")
[ "$ACTOR_OMNI" = "null" ] || [ -z "$ACTOR_OMNI" ] \
  && die "agent file missing actor_omni — re-run heima-agent-create.sh to register on chain first"

# Master key — uses shared resolve_master_key (supports raw-hex deployer
# key at ~/.agentkeys/heima-deployer.key OR mnemonic at ./test-hei).
. "$REPO_ROOT/harness/scripts/_lib.sh"
MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')

# Compute keccak256(service_name_lc) for each requested service.
SERVICE_HASHES=()
SERVICE_NAMES=()
IFS=',' read -ra SVC_PARTS <<<"$SERVICES_RAW"
for s in "${SVC_PARTS[@]}"; do
  name=$(printf '%s' "$s" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
  [ -z "$name" ] && continue
  SERVICE_NAMES+=("$name")
  hash=$(cast keccak "$name")
  SERVICE_HASHES+=("$hash")
done
[ "${#SERVICE_HASHES[@]}" -eq 0 ] && die "no services parsed from --services '$SERVICES_RAW'"

# Build the bracketed services array argument: [hash1,hash2,...]
SERVICES_ARG="["
for i in "${!SERVICE_HASHES[@]}"; do
  [ "$i" -gt 0 ] && SERVICES_ARG+=","
  SERVICES_ARG+="${SERVICE_HASHES[$i]}"
done
SERVICES_ARG+="]"

# Stage-2 K11 assertion: real WebAuthn ceremony required.
# The contract's setScopeWithWebauthn now takes a K11Assertion struct
# (attestingDeviceKeyHash, authenticatorData, clientDataJSON,
#  challengeLocation, r, s) and verifies the P-256 sig on chain via
# K11Verifier. Stub bytes no longer work — the contract rejects them.
#
# In CI / non-Touch-ID environments: if the operator hasn't enrolled a
# real K11 yet, skip with a clear log rather than blocking on Touch ID.
# Operators driving the stage-1 demo without --webauthn cannot mutate
# scope on stage-2 contracts — that's a contract-level invariant, not a
# script limitation.
PRIMARY_DEVICE_KEY_HASH=$(cast keccak "$MASTER_ADDR_LC")
PRIMARY_K11_FILE="$HOME/.agentkeys/k11/${OPERATOR_OMNI}.json"
if [ ! -f "$PRIMARY_K11_FILE" ] || [ "$(jq -r .mode "$PRIMARY_K11_FILE" 2>/dev/null)" != "webauthn" ]; then
  skip "primary K11 not enrolled with mode=webauthn — stage-2 setScopeWithWebauthn requires a real WebAuthn assertion. Re-run with \`agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x$OPERATOR_OMNI\` first, or skip this step in CI."
  echo "{\"ok\":true,\"skipped\":\"no-webauthn-k11\",\"reason\":\"stage-2 contract requires real K11 sig\"}"
  exit 0
fi
# Stub-mode caller (no --webauthn) on a laptop that has a stale webauthn K11
# enrollment from a prior real ceremony: still skip — caller didn't ask for
# Touch ID, so we don't trigger one. CI-friendly path.
if [ "$USE_WEBAUTHN" = "0" ]; then
  skip "stub mode (no --webauthn) — refusing to trigger a Touch ID ceremony. Re-run with --webauthn for the real setScopeWithWebauthn, or accept skip in CI."
  echo "{\"ok\":true,\"skipped\":\"stub-mode-refuses-touchid\",\"reason\":\"caller did not pass --webauthn but K11 file is in webauthn mode\"}"
  exit 0
fi
MODE=$(jq -r .mode "$PRIMARY_K11_FILE")

# Compute expected_challenge per contract:
#   keccak256(abi.encode(OP_SET_SCOPE, operatorOmni, agentOmni, servicesDigest,
#     readOnly, maxPerCall, maxPerPeriod, maxTotal, periodSeconds, chainid, nonce))
# servicesDigest = keccak256(abi.encode(services)) — the contract hashes the
# bytes32[] array; cast abi-encode emits the same canonical layout.
SCOPE_NONCE=$(cast call "$SCOPE_CONTRACT" \
  "scopeNonce(bytes32,bytes32)(uint256)" "0x$OPERATOR_OMNI" "$ACTOR_OMNI" \
  --rpc-url "$RPC_HTTP")
OP_KIND=$(cast call "$SCOPE_CONTRACT" "OP_SET_SCOPE()(bytes32)" --rpc-url "$RPC_HTTP")
SERVICES_DIGEST=$(cast keccak "$(cast abi-encode 'wrap(bytes32[])' "$SERVICES_ARG")")
CHALLENGE=$(cast keccak "$(cast abi-encode \
  'setScope(bytes32,bytes32,bytes32,bytes32,bool,uint128,uint128,uint128,uint32,uint256,uint256)' \
  "$OP_KIND" "0x$OPERATOR_OMNI" "$ACTOR_OMNI" "$SERVICES_DIGEST" \
  "$READ_ONLY" "$MAX_PER_CALL" "$MAX_PER_PERIOD" "$MAX_TOTAL" \
  "$PERIOD_SECONDS" "$LIVE_CHAIN_ID" "$SCOPE_NONCE")")
log "expected_challenge = $CHALLENGE"

log "Requesting K11 assertion from PRIMARY master (Touch ID prompt at localhost)…"
# Typed K11 intent — wiki/k11-intent-conventions.md. The shared
# k11_intent.rs renderer collapses the three "Max *" rows to a
# single "Spending limits: unlimited" when all are 0, decodes
# read_only to "read-only" / "read + write", and renders the period
# duration as "1h" instead of "3600s".
# Convert comma-separated services list to a JSON array.
SERVICES_JSON=$(printf '%s' "$SERVICES_RAW" | jq -R 'split(",") | map(. | gsub("^\\s+|\\s+$";""))')
READ_ONLY_BOOL=$([ "$READ_ONLY" = "true" ] && echo true || echo false)
INTENT_JSON=$(jq -n \
  --arg op_omni "0x${OPERATOR_OMNI}" \
  --arg asserting_hash "${PRIMARY_DEVICE_KEY_HASH}" \
  --arg agent_label "${LABEL}" \
  --arg agent_omni "${ACTOR_OMNI}" \
  --argjson services "${SERVICES_JSON}" \
  --argjson read_only "${READ_ONLY_BOOL}" \
  --arg max_per_call "${MAX_PER_CALL}" \
  --arg max_per_period "${MAX_PER_PERIOD}" \
  --argjson period_seconds "${PERIOD_SECONDS}" \
  --arg max_total "${MAX_TOTAL}" \
  --argjson chain_id "${LIVE_CHAIN_ID}" \
  --argjson nonce "${SCOPE_NONCE}" \
  '{
    kind: "set_scope_grant",
    operator_omni: $op_omni,
    agent_label: $agent_label,
    agent_omni: $agent_omni,
    services: $services,
    read_only: $read_only,
    max_per_call: $max_per_call,
    max_per_period: $max_per_period,
    period_seconds: $period_seconds,
    max_total: $max_total,
    chain_id: $chain_id,
    scope_nonce: $nonce,
    asserting: { kind: "primary", device_key_hash: $asserting_hash }
  }')
K11_ERR=$(mktemp -t heima-scope-set-k11.XXXXXX) || die "mktemp failed"
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
echo "    AGENTKEYS_CHAIN  = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    scope contract   = $SCOPE_CONTRACT" >&2
echo "    master           = $MASTER_ADDR" >&2
echo "    operator_omni    = 0x$OPERATOR_OMNI" >&2
echo "    agent label      = $LABEL ($AGENT_ADDR)" >&2
echo "    actor_omni       = $ACTOR_OMNI" >&2
echo "    services         = ${SERVICE_NAMES[*]} (${#SERVICE_HASHES[@]} entries)" >&2
echo "    read_only        = $READ_ONLY" >&2
echo "    max_per_call     = $MAX_PER_CALL" >&2
echo "    max_per_period   = $MAX_PER_PERIOD" >&2
echo "    max_total        = $MAX_TOTAL" >&2
echo "    period_seconds   = $PERIOD_SECONDS" >&2

# Idempotency: read existing scope via getScope. Note: AgentKeysScope.getScope
# returns a single Scope struct, not a flat tuple — declare it as
# `((bytes32[],bool,uint128,uint128,uint128,uint32,uint64,bool))` (struct
# wrapped in outer parens) so cast decodes correctly. Otherwise cast errors
# with "ABI decoding failed: buffer overrun" and the idempotency block
# silently never matches.
log "Idempotency check: scope already set?"
EXISTING_SCOPE=$(cast call "$SCOPE_CONTRACT" \
  "getScope(bytes32,bytes32)((bytes32[],bool,uint128,uint128,uint128,uint32,uint64,bool))" \
  "0x$OPERATOR_OMNI" "$ACTOR_OMNI" \
  --rpc-url "$RPC_HTTP" 2>&1 || echo ERR)

if [ "$EXISTING_SCOPE" != "ERR" ] && [ -n "$EXISTING_SCOPE" ]; then
  # cast prints the struct on a single line:
  #   "([0xhash1, 0xhash2], false, 0, 0, 0, 0, 1779149808 [1.779e9], true)"
  # The trailing `[1.779e9]` is cast's scientific-notation annotation on
  # large uints — strip it. Parse via python3 because the services-array
  # can contain commas which confuse naive shell `IFS=,` splits.
  # Codex review: do NOT swallow parser failure with `|| true` — if
  # python3 fails (missing dep, malformed cast output, etc.) the idempotency
  # check would silently fall through to "proceeding" and re-submit a tx.
  # Fail loud instead so the operator notices.
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 required for getScope idempotency parser — install python3 and re-run"
  fi
  # `set -e` would abort the script if python3 exits non-zero inside the
  # $() command-substitution, BEFORE we get to inspect PARSE_RC. Wrap with
  # set +e / set -e so we can surface a useful diagnostic instead of a
  # generic shell abort. Codex review (pass 2) flagged this exact gap.
  set +e
  PARSED=$(python3 - <<'PYEOF' "$EXISTING_SCOPE"
import sys, re
raw = sys.argv[1].strip()
m = re.match(r"\((.*)\)$", raw, re.DOTALL)
if not m:
    sys.exit(1)
inner = m.group(1).strip()
arr_match = re.match(r"^\[([^\]]*)\]\s*,\s*(.*)$", inner, re.DOTALL)
if not arr_match:
    sys.exit(1)
services_inner = arr_match.group(1).strip()
rest = arr_match.group(2)
parts = [p.strip() for p in rest.split(",")]
clean = [p.split()[0] if p else "" for p in parts]
if len(clean) < 7:
    sys.exit(1)
# Normalize services array to canonical "[a,b,c]" with no spaces
hashes = [h.strip().lower() for h in services_inner.split(",") if h.strip()]
print("[" + ",".join(hashes) + "]")
print(clean[0])  # readOnly
print(clean[1])  # maxPerCall
print(clean[2])  # maxPerPeriod
print(clean[3])  # maxTotal
print(clean[4])  # periodSeconds
print(clean[5])  # updatedAt (unused)
print(clean[6])  # exists
PYEOF
)
  PARSE_RC=$?
  set -e
  if [ "$PARSE_RC" != "0" ]; then
    die "python3 getScope parser failed (exit $PARSE_RC). Raw cast output: $EXISTING_SCOPE"
  fi
  if [ -n "$PARSED" ]; then
    EX_SERVICES=$(printf '%s\n' "$PARSED" | sed -n '1p')
    EX_READ_ONLY=$(printf '%s\n' "$PARSED" | sed -n '2p')
    EX_MAX_CALL=$(printf '%s\n' "$PARSED" | sed -n '3p')
    EX_MAX_PERIOD=$(printf '%s\n' "$PARSED" | sed -n '4p')
    EX_MAX_TOTAL=$(printf '%s\n' "$PARSED" | sed -n '5p')
    EX_PERIOD_S=$(printf '%s\n' "$PARSED" | sed -n '6p')
    EX_EXISTS=$(printf '%s\n' "$PARSED" | sed -n '8p')

    if [ "$EX_EXISTS" = "true" ]; then
      NORM_NEW=$(printf '%s' "$SERVICES_ARG" | tr '[:upper:]' '[:lower:]')
      if [ "$EX_SERVICES" = "$NORM_NEW" ] && \
         [ "$EX_READ_ONLY" = "$READ_ONLY" ] && \
         [ "$EX_MAX_CALL" = "$MAX_PER_CALL" ] && \
         [ "$EX_MAX_PERIOD" = "$MAX_PER_PERIOD" ] && \
         [ "$EX_MAX_TOTAL" = "$MAX_TOTAL" ] && \
         [ "$EX_PERIOD_S" = "$PERIOD_SECONDS" ]; then
        skip "scope already matches requested config — no-op"
        echo "{\"ok\":true,\"skipped\":\"already-set\",\"agent\":\"$LABEL\",\"actor_omni\":\"$ACTOR_OMNI\"}"
        exit 0
      fi
      ok "scope exists but differs → will overwrite (existing services=$EX_SERVICES vs new=$NORM_NEW)"
    fi
  fi
fi
ok "scope not yet set (or differs) → proceeding"

CAST_ARGS=(
  send "$SCOPE_CONTRACT"
  "setScopeWithWebauthn(bytes32,bytes32,bytes32[],bool,uint128,uint128,uint128,uint32,(bytes32,bytes,bytes,uint256,uint256,uint256))"
  "0x$OPERATOR_OMNI"
  "$ACTOR_OMNI"
  "$SERVICES_ARG"
  "$READ_ONLY"
  "$MAX_PER_CALL"
  "$MAX_PER_PERIOD"
  "$MAX_TOTAL"
  "$PERIOD_SECONDS"
  "$K11_TUPLE"
  --rpc-url "$RPC_HTTP"
  --chain-id "$LIVE_CHAIN_ID"
  --private-key "$MASTER_KEY"
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
  echo "{\"ok\":true,\"dry_run\":true,\"agent\":\"$LABEL\",\"actor_omni\":\"$ACTOR_OMNI\",\"services\":${#SERVICE_HASHES[@]}}"
  exit 0
fi

log "Submitting setScopeWithWebauthn tx via cast send …"
set +e
CAST_OUT=$(cast "${CAST_ARGS[@]}" 2>&1)
CAST_RC=$?
set -e
if [ "$CAST_RC" != "0" ]; then
  echo "    cast send FAILED (exit $CAST_RC). Output:" >&2
  echo "$CAST_OUT" >&2
  exit 1
fi

TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)

# Post-tx verification: first service should be in scope.
log "Post-tx verification …"
FIRST_HASH="${SERVICE_HASHES[0]}"
IN_SCOPE=$(cast call "$SCOPE_CONTRACT" \
  "isServiceInScope(bytes32,bytes32,bytes32)(bool)" \
  "0x$OPERATOR_OMNI" "$ACTOR_OMNI" "$FIRST_HASH" \
  --rpc-url "$RPC_HTTP" 2>&1 || echo ERR)
[ "$IN_SCOPE" = "true" ] && ok "isServiceInScope(...) = true for ${SERVICE_NAMES[0]}" \
  || die "post-tx isServiceInScope check failed: '$IN_SCOPE'"

# Persist scope grant info.
SCOPE_FILE="$HOME/.agentkeys/agents/${LABEL}.scope.json"
(umask 077 && jq -n \
  --arg label "$LABEL" \
  --arg actor "$ACTOR_OMNI" \
  --arg operator "0x$OPERATOR_OMNI" \
  --argjson services "$(printf '%s\n' "${SERVICE_NAMES[@]}" | jq -R . | jq -s .)" \
  --argjson service_hashes "$(printf '%s\n' "${SERVICE_HASHES[@]}" | jq -R . | jq -s .)" \
  --arg read_only "$READ_ONLY" \
  --arg max_per_call "$MAX_PER_CALL" \
  --arg max_per_period "$MAX_PER_PERIOD" \
  --arg max_total "$MAX_TOTAL" \
  --arg period_seconds "$PERIOD_SECONDS" \
  --arg tx_hash "$TX_HASH" \
  --arg block_number "$BLOCK_NUM" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{label:$label, actor_omni:$actor, operator_omni:$operator, services:$services, service_hashes:$service_hashes, read_only:($read_only=="true"), max_per_call:$max_per_call, max_per_period:$max_per_period, max_total:$max_total, period_seconds:$period_seconds, tx_hash:$tx_hash, block_number:$block_number, set_at:$ts}' \
  > "$SCOPE_FILE")
chmod 600 "$SCOPE_FILE"

ok "scope set — txhash $TX_HASH (block $BLOCK_NUM)"
echo "{\"ok\":true,\"agent\":\"$LABEL\",\"actor_omni\":\"$ACTOR_OMNI\",\"tx_hash\":\"$TX_HASH\",\"block_number\":\"$BLOCK_NUM\",\"services\":${#SERVICE_HASHES[@]}}"
