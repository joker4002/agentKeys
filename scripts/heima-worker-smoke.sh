#!/usr/bin/env bash
# scripts/heima-worker-smoke.sh — exercise the live audit-service + email-service
# workers co-located on the broker host (issue #90, arch.md §15.1 + §15.3).
#
# Used by harness/v2-stage1-demo.sh and harness/v2-stage2-demo.sh as the
# tier-A relay smoke step:
#
#   1. POST 2 events to https://audit.<zone>/v1/audit/append
#   2. POST   /v1/audit/flush/<operator_omni>  → returns merkle_root + entry_count
#   3. cast send CredentialAudit.appendRoot(operator_omni, root, entry_count)
#        on Heima Mainnet — gated by `msg.sender == registry.operatorMasterWallet`,
#        so signs with the master device key (HEIMA_DEPLOYER_MNEMONIC_FILE).
#   4. cast call rootCount + getRoot to verify the root landed.
#   5. GET https://email.<zone>/v1/email/inbox/<actor_omni>  (smoke; usually empty).
#
# Idempotent: if /v1/audit/queue-size returns 0 we append fresh events first.
# If the agent file doesn't exist (--actor) we skip the email step but still
# do audit (operator-level events don't need an actor).
#
# Usage:
#   bash scripts/heima-worker-smoke.sh                              # auto-discover via env
#   bash scripts/heima-worker-smoke.sh --actor demo-agent           # exercise with a specific agent
#   bash scripts/heima-worker-smoke.sh --skip-email                 # audit only (CI w/ no SES wired)
#   bash scripts/heima-worker-smoke.sh --skip-audit                 # email only
#   bash scripts/heima-worker-smoke.sh --audit-url https://… …      # override defaults
#
# Env (sourced from scripts/operator-workstation.env):
#   AGENTKEYS_WORKER_AUDIT_URL  default https://audit.<zone>
#   AGENTKEYS_WORKER_EMAIL_URL  default https://email.<zone>
#   HEIMA_DEPLOYER_MNEMONIC_FILE  default ./test-hei
#   CREDENTIAL_AUDIT_ADDRESS_HEIMA  contract address from chain bring-up

set -euo pipefail

LABEL=""
SKIP_AUDIT=0
SKIP_EMAIL=0
AUDIT_URL=""
EMAIL_URL=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --actor)         LABEL="$2"; shift 2 ;;
    --actor=*)       LABEL="${1#*=}"; shift ;;
    --audit-url)     AUDIT_URL="$2"; shift 2 ;;
    --audit-url=*)   AUDIT_URL="${1#*=}"; shift ;;
    --email-url)     EMAIL_URL="$2"; shift 2 ;;
    --email-url=*)   EMAIL_URL="${1#*=}"; shift ;;
    --skip-audit)    SKIP_AUDIT=1; shift ;;
    --skip-email)    SKIP_EMAIL=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_ERR='\033[1;31m'; C_WARN='\033[1;33m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_ERR=''; C_WARN=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
info() { printf "    ${C_WARN}info${C_RESET} %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

# ─── Load env ────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

[ -z "$AUDIT_URL" ] && AUDIT_URL="${AGENTKEYS_WORKER_AUDIT_URL:-}"
[ -z "$EMAIL_URL" ] && EMAIL_URL="${AGENTKEYS_WORKER_EMAIL_URL:-}"
[ -z "$AUDIT_URL" ] && die "AGENTKEYS_WORKER_AUDIT_URL unset — operator-workstation.env out of date?"
[ -z "$EMAIL_URL" ] && die "AGENTKEYS_WORKER_EMAIL_URL unset — operator-workstation.env out of date?"

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
eval "AUDIT_CONTRACT=\${CREDENTIAL_AUDIT_ADDRESS_${PROFILE_UC}:-}"
[ -z "$AUDIT_CONTRACT" ] && die "CREDENTIAL_AUDIT_ADDRESS_${PROFILE_UC} unset — run heima-bring-up.sh first"
case "$(printf '%s' "$AUDIT_CONTRACT" | tr '[:upper:]' '[:lower:]')" in
  0x000000000000000000000000000000000000000[1-4])
    die "CredentialAudit address $AUDIT_CONTRACT is the env-file sentinel — run heima-bring-up.sh first" ;;
esac

PROFILE_JSON=$(agentkeys chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)
LIVE_CHAIN_ID=$(printf '%d' "$(curl -sS -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "$RPC_HTTP" | jq -r .result)")

# Master key — shared resolve_master_key (HEIMA_DEPLOYER_KEY_FILE for CI,
# falls back to ./test-hei mnemonic). Replaces mnemonic-only inline block.
. "$REPO_ROOT/harness/scripts/_lib.sh"
MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key"
MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
MASTER_ADDR_LC=$(printf '%s' "$MASTER_ADDR" | tr '[:upper:]' '[:lower:]')
OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR_LC" | shasum -a 256 | awk '{print $1}')

# Resolve actor_omni if --actor passed (or default demo-agent if file exists).
ACTOR_OMNI=""
if [ -n "$LABEL" ]; then
  AGENT_FILE="$HOME/.agentkeys/agents/${LABEL}.json"
  [ -f "$AGENT_FILE" ] || die "no agent file for '$LABEL' at $AGENT_FILE"
  ACTOR_OMNI=$(jq -r .actor_omni "$AGENT_FILE")
  [ "$ACTOR_OMNI" = "null" ] && ACTOR_OMNI=""
fi
if [ -z "$ACTOR_OMNI" ]; then
  # Synthesize a deterministic actor_omni from the operator omni so the
  # audit events are still well-formed (no per-actor agent file needed).
  ACTOR_OMNI=$(printf 'demo-actor:0x%s' "$OPERATOR_OMNI" | shasum -a 256 | awk '{print $1}')
  ACTOR_OMNI="0x$ACTOR_OMNI"
  info "no --actor agent file — synthesizing actor_omni=$ACTOR_OMNI"
fi

log "Inputs"
echo "    chain          = $AGENTKEYS_CHAIN (chain_id $LIVE_CHAIN_ID)" >&2
echo "    audit_url      = $AUDIT_URL" >&2
echo "    email_url      = $EMAIL_URL" >&2
echo "    audit contract = $AUDIT_CONTRACT" >&2
echo "    operator_omni  = 0x$OPERATOR_OMNI" >&2
echo "    actor_omni     = $ACTOR_OMNI" >&2

# ─── Worker /healthz precheck ────────────────────────────────────────────────
log "Precheck — worker /healthz"
for pair in "audit:$AUDIT_URL" "email:$EMAIL_URL"; do
  name="${pair%%:*}"; url="${pair#*:}"
  if curl -sf --max-time 5 "$url/healthz" >/dev/null 2>&1; then
    ok "$name worker /healthz reachable at $url"
  else
    die "$name worker /healthz failed at $url — re-run scripts/verify-workers.sh"
  fi
done

# ═══ 1. Audit worker: queue → flush → on-chain appendRoot → verify ═════════
if [ "$SKIP_AUDIT" = "1" ]; then
  info "skipping audit smoke (--skip-audit)"
else
  log "Audit worker — queue 2 events, flush to Merkle root, submit appendRoot on-chain"

  SERVICE_HASH=$(cast keccak "openrouter")
  TS=$(date +%s)
  # Two deterministic-but-fresh events (different op_type + payload_hash so
  # the Merkle tree has two distinct leaves).
  PAYLOAD_1=$(cast keccak "audit-op:store:openrouter:$TS")
  PAYLOAD_2=$(cast keccak "audit-op:read:openrouter:$TS")

  post_event() {
    local op_type="$1" payload="$2"
    curl -sf --max-time 10 -X POST "$AUDIT_URL/v1/audit/append" \
      -H 'content-type: application/json' \
      -d "$(jq -n \
            --arg op  "0x$OPERATOR_OMNI" \
            --arg act "$ACTOR_OMNI" \
            --arg svc "$SERVICE_HASH" \
            --argjson opt "$op_type" \
            --arg ph "$payload" \
            --argjson ts "$TS" '{
              operator_omni: $op,
              actor_omni: $act,
              service_hash: $svc,
              op_type: $opt,
              payload_hash: $ph,
              timestamp: $ts
            }')" \
      | jq -r '.queue_size'
  }

  Q1=$(post_event 0 "$PAYLOAD_1")
  ok "queued event 1 (op=STORE) — queue_size=$Q1"
  Q2=$(post_event 1 "$PAYLOAD_2")
  ok "queued event 2 (op=READ)  — queue_size=$Q2"

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — would flush + appendRoot now"
    echo "{\"ok\":true,\"dry_run\":true,\"audit_queued\":2}"
    exit 0
  fi

  log "Flushing queue → Merkle root"
  FLUSH_OUT=$(curl -sf --max-time 10 -X POST "$AUDIT_URL/v1/audit/flush/0x$OPERATOR_OMNI" 2>&1) \
    || die "flush failed: $FLUSH_OUT"
  ROOT=$(echo "$FLUSH_OUT" | jq -r '.flushed[0].merkle_root_hex // empty')
  ENTRY_COUNT=$(echo "$FLUSH_OUT" | jq -r '.flushed[0].entry_count // 0')
  LEAVES_PATH=$(echo "$FLUSH_OUT" | jq -r '.flushed[0].leaves_path // empty')
  [ -z "$ROOT" ] && die "flush returned empty root — body: $FLUSH_OUT"
  ok "flushed: root=$ROOT  entries=$ENTRY_COUNT  leaves=$LEAVES_PATH"

  # ─── Submit appendRoot on-chain (gated by master wallet) ──────────────────
  log "Calling CredentialAudit.appendRoot from operator master wallet"
  ROOT_COUNT_BEFORE=$(cast call "$AUDIT_CONTRACT" "rootCount(bytes32)(uint256)" \
    "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP" 2>/dev/null | awk '{print $1}')
  ok "rootCount before: $ROOT_COUNT_BEFORE"

  CAST_OUT=$(cast send "$AUDIT_CONTRACT" \
    "appendRoot(bytes32,bytes32,uint64)" \
    "0x$OPERATOR_OMNI" "$ROOT" "$ENTRY_COUNT" \
    --rpc-url "$RPC_HTTP" --chain-id "$LIVE_CHAIN_ID" \
    --private-key "$MASTER_KEY" 2>&1) || { echo "$CAST_OUT" >&2; die "appendRoot tx failed"; }

  TX_HASH=$(printf '%s\n' "$CAST_OUT" | awk '/^transactionHash/ {print $2}' | head -1)
  BLOCK_NUM=$(printf '%s\n' "$CAST_OUT" | awk '/^blockNumber/ {print $2}' | head -1)
  ok "appendRoot tx: $TX_HASH  block: $BLOCK_NUM"

  # Verify rootCount monotonically incremented + stored root matches.
  ROOT_COUNT_AFTER=$(cast call "$AUDIT_CONTRACT" "rootCount(bytes32)(uint256)" \
    "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP" 2>/dev/null | awk '{print $1}')
  EXPECTED=$((ROOT_COUNT_BEFORE + 1))
  [ "$ROOT_COUNT_AFTER" = "$EXPECTED" ] || die "rootCount expected $EXPECTED got $ROOT_COUNT_AFTER"
  ok "rootCount: $ROOT_COUNT_BEFORE → $ROOT_COUNT_AFTER (+1)"

  LAST_IDX=$((ROOT_COUNT_AFTER - 1))
  STORED_ROOT=$(cast call "$AUDIT_CONTRACT" \
    "getRoot(bytes32,uint256)((bytes32,uint64,uint64))" \
    "0x$OPERATOR_OMNI" "$LAST_IDX" --rpc-url "$RPC_HTTP" 2>/dev/null \
    | sed -E 's/^\(([^,]+),.*/\1/')
  STORED_ROOT_LC=$(printf '%s' "$STORED_ROOT" | tr '[:upper:]' '[:lower:]')
  ROOT_LC=$(printf '%s' "$ROOT" | tr '[:upper:]' '[:lower:]')
  [ "$STORED_ROOT_LC" = "$ROOT_LC" ] || die "stored root $STORED_ROOT != flushed root $ROOT"
  ok "on-chain root matches flushed root (idx $LAST_IDX)"
fi

# ═══ 2. Email worker: /inbox smoke (best-effort) ═════════════════════════════
# /inbox calls S3 ListObjects on the broker EC2 host. The instance profile
# may lack s3:ListBucket on the inbox bucket today — wiring per-worker IAM
# is a follow-up (would mirror the broker's AssumeRoleWithWebIdentity path).
# Until then we treat an /inbox 5xx as a soft-warn: the worker is deployed,
# /healthz passes, and the rest of the demo isn't blocked. The same condition
# surfaces as 500 (the worker's own error from the AccessDenied) OR 502/503 (via
# nginx when the worker errors/restarts on ListObjects) — tolerate the whole 5xx
# class so a proxy-variant of the SAME known gap doesn't hard-fail the smoke.
if [ "$SKIP_EMAIL" = "1" ]; then
  info "skipping email smoke (--skip-email)"
else
  log "Email worker — GET /v1/email/inbox/$ACTOR_OMNI"
  INBOX_HTTP_CODE=$(curl -sS -o /tmp/inbox-out.$$ --max-time 10 \
    -w '%{http_code}' "$EMAIL_URL/v1/email/inbox/$ACTOR_OMNI" 2>&1 || echo "000")
  INBOX_BODY=$(cat /tmp/inbox-out.$$ 2>/dev/null || true)
  rm -f /tmp/inbox-out.$$
  case "$INBOX_HTTP_CODE" in
    200)
      INBOX_OK=$(echo "$INBOX_BODY" | jq -r '.ok // false')
      INBOX_BUCKET=$(echo "$INBOX_BODY" | jq -r '.bucket // empty')
      INBOX_PREFIX=$(echo "$INBOX_BODY" | jq -r '.prefix // empty')
      ENTRY_COUNT=$(echo "$INBOX_BODY" | jq -r '.entries | length')
      [ "$INBOX_OK" = "true" ] || die "inbox response not ok: $INBOX_BODY"
      ok "inbox reachable: bucket=$INBOX_BUCKET  prefix=$INBOX_PREFIX  entries=$ENTRY_COUNT"
      ;;
    500|502|503)
      info "inbox /v1/email/inbox returned HTTP $INBOX_HTTP_CODE — likely AWS IAM (s3:ListBucket) not wired on the broker EC2 instance profile (surfaces as 500 from the worker or 502/503 via nginx when it errors on ListObjects). Worker is deployed + /healthz passes; this is a known follow-up."
      info "body: $INBOX_BODY"
      ;;
    *)
      die "inbox GET unexpected HTTP $INBOX_HTTP_CODE  body: $INBOX_BODY"
      ;;
  esac
fi

log "Worker smoke complete"
echo "{\"ok\":true,\"audit_skipped\":$SKIP_AUDIT,\"email_skipped\":$SKIP_EMAIL,\"operator_omni\":\"0x$OPERATOR_OMNI\",\"actor_omni\":\"$ACTOR_OMNI\"}"
