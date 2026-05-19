#!/usr/bin/env bash
# scripts/heima-scope-set.sh — grant or replace an agent's scope on the
# live AgentKeysScope contract. Wraps
# `AgentKeysScope.setScopeWithWebauthn(...)` per arch.md §12.4.
#
# Stage-1 simplification (per arch.md §22a):
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

# Load agent metadata.
AGENT_FILE="$HOME/.agentkeys/agents/${LABEL}.json"
[ -f "$AGENT_FILE" ] || die "no agent registered for label '$LABEL' at $AGENT_FILE (run heima-agent-create.sh first)"
AGENT_ADDR=$(jq -r .agent_address "$AGENT_FILE")
ACTOR_OMNI=$(jq -r .actor_omni "$AGENT_FILE")
[ "$ACTOR_OMNI" = "null" ] || [ -z "$ACTOR_OMNI" ] \
  && die "agent file missing actor_omni — re-run heima-agent-create.sh to register on chain first"

# Master key (same flow as the other scripts).
MNEMONIC_FILE="${HEIMA_DEPLOYER_MNEMONIC_FILE:-$REPO_ROOT/test-hei}"
[ -f "$MNEMONIC_FILE" ] || die "missing mnemonic at $MNEMONIC_FILE"
if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
  log "Installing scripts/node_modules deps (first run only)…"
  npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund || die "npm install failed"
fi
DERIV_JSON=$(node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$MNEMONIC_FILE")
MASTER_KEY=$(echo "$DERIV_JSON" | jq -r .privateKey)
MASTER_ADDR=$(echo "$DERIV_JSON" | jq -r .address)
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

# Stage-1 K11 assertion stub. Non-empty (contract requires
# k11Assertion.length != 0) but not P-256-verified on-chain yet.
# Format: ASCII "stage1-k11-stub:" || OPERATOR_OMNI as hex.
K11_STUB="0x$(printf 'stage1-k11-stub:%s' "$OPERATOR_OMNI" | xxd -p -c 256 | tr -d '\n')"

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
  "setScopeWithWebauthn(bytes32,bytes32,bytes32[],bool,uint128,uint128,uint128,uint32,bytes)"
  "0x$OPERATOR_OMNI"
  "$ACTOR_OMNI"
  "$SERVICES_ARG"
  "$READ_ONLY"
  "$MAX_PER_CALL"
  "$MAX_PER_PERIOD"
  "$MAX_TOTAL"
  "$PERIOD_SECONDS"
  "$K11_STUB"
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
