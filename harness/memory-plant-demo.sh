#!/usr/bin/env bash
# harness/memory-plant-demo.sh — the CLI/CI equivalent of the web app's
# "⊕ plant prepared memory" button (apps/parent-control). It plants the master's
# prepared memory archive through the REAL master-self chain and reads it back —
# the scriptable proof the plant flow works, since the browser button is manual
# (web-memory-bootstrap.sh step 7 can't script the passkey).
#
# Per-entry chain — byte-for-byte what the daemon's memory_put_real does
# (crates/agentkeys-daemon/src/ui_bridge.rs §W3), so this and the button exercise
# the SAME path:
#   1. wallet SIWE → J1                              (operator == actor == O_master)
#   2. cap-mint  POST {broker}/v1/cap/memory-put     (master-self, NO scope grant — #195/#196)
#   3. STS relay POST {broker}/v1/mint-oidc-jwt → aws sts assume-role-with-web-identity
#                                                    (per-actor creds tagged agentkeys_actor_omni)
#   4. worker    POST {memory_url}/v1/memory/put     {cap, plaintext_b64, namespace} + x-aws-*
#   → S3 bots/0x<O_master>/memory/memory:<ns>.enc
# Read-back (step 5) mints a memory-get cap and GETs one namespace to prove S3.
#
# Idempotent: the worker stores ONE blob per namespace, so re-running overwrites
# with identical content (a no-op in effect) — matching the button's content-hash
# dedup. Mainnet posture + run modes per harness/CLAUDE.md.
#
#   bash harness/memory-plant-demo.sh                # plant + read-back
#   bash harness/memory-plant-demo.sh --only-step 4  # one step
#   bash harness/memory-plant-demo.sh --ci           # tolerate missing infra (skip, exit 0)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
# shellcheck source=/dev/null
. "$REPO_ROOT/harness/scripts/_lib.sh"

CI=0; FROM=1; TO=99; STEP_TOTAL=5
for a in "$@"; do case "$a" in
  --ci) CI=1 ;;
  --from-step) shift; FROM="${1:-1}" ;; --from-step=*) FROM="${a#*=}" ;;
  --to-step) shift; TO="${1:-99}" ;;   --to-step=*) TO="${a#*=}" ;;
  --only-step) shift; FROM="${1:-1}"; TO="$FROM" ;; --only-step=*) FROM="${a#*=}"; TO="$FROM" ;;
  --help|-h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac; done
{ [ -n "${AGENTKEYS_CI:-}" ] || [ -n "${CI:-}" ] && [ "${CI}" != 0 ]; } && CI=1
should_run() { [ "$1" -ge "$FROM" ] && [ "$1" -le "$TO" ]; }
c() { [ -t 2 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
step() { printf '\n%s %s\n' "$(c '1;36' "▸ step $1/$STEP_TOTAL")" "$2" >&2; }
ok()   { printf '  %s %s\n' "$(c '1;32' ok)" "$1" >&2; }
skip() { printf '  %s %s\n' "$(c '1;33' skip)" "$1" >&2; }
die()  { printf '  %s %s\n' "$(c '1;31' fail)" "$1" >&2; [ "$CI" = 1 ] && { skip "CI — tolerated"; exit 0; }; exit 1; }

# The prepared archive (ONE blob per namespace — the worker's per-namespace model).
# Mirrors apps/parent-control/lib/preparedMemory.ts; kept small + self-contained.
NAMESPACES="travel personal family"
plain_for() { case "$1" in
  travel)   printf '{"trip":"Chengdu 2025","dates":"Oct 3-12","hotel":"Niccolo","notes":"pandas at Dujiangyan; hotpot on Jinli"}' ;;
  personal) printf '{"diet":"pescatarian","allergies":["peanuts"],"timezone":"Asia/Shanghai"}' ;;
  family)   printf '{"partner":"Wen","kids":2,"emergency_contact":"+86-138-0000-0000"}' ;;
esac; }

profile_uc="$(printf '%s' "${AGENTKEYS_CHAIN:-heima}" | tr 'a-z-' 'A-Z_')"
BROKER="${OIDC_ISSUER:-${AGENTKEYS_BROKER_URL:-}}"
eval "MEMORY_URL=\${AGENTKEYS_WORKER_MEMORY_URL:-\${MEMORY_WORKER_URL:-}}"
eval "MEMORY_ROLE_ARN=\${MEMORY_ROLE_ARN:-\${MEMORY_ROLE_ARN_${profile_uc}:-}}"
REGION="${REGION:-us-east-1}"

# ─── Step 1: prereqs + identity ────────────────────────────────────────────
if should_run 1; then
  step 1 "Prereqs + master identity"
  for t in cast jq curl aws; do command -v "$t" >/dev/null 2>&1 || die "missing $t on PATH"; done
  [ -n "$BROKER" ]   || die "no broker URL (set OIDC_ISSUER in $ENV_FILE)"
  [ -n "$MEMORY_URL" ] || die "no memory worker URL (set AGENTKEYS_WORKER_MEMORY_URL)"
  [ -n "$MEMORY_ROLE_ARN" ] || die "no MEMORY_ROLE_ARN (the per-actor memory IAM role)"
  DEPLOYER_KEY="$(resolve_master_key)" || die "no deployer key (~/.agentkeys/heima-deployer.key)"
  DEPLOYER_ADDR="$(cast wallet address --private-key "$DEPLOYER_KEY" | tr 'A-F' 'a-f')"
  DEPLOYER_OMNI="$(printf 'agentkeysevm%s' "$DEPLOYER_ADDR" | shasum -a 256 | awk '{print $1}')"
  MASTER_DKH="$(resolve_active_master_dkh "$DEPLOYER_OMNI" "$DEPLOYER_ADDR" || true)"
  [ -n "$MASTER_DKH" ] || die "master device not registered on chain — run: bash harness/scripts/erc4337-register-master.sh"
  ok "operator==actor omni 0x${DEPLOYER_OMNI:0:14}…  device ${MASTER_DKH:0:14}…"
fi

# ─── Step 2: wallet SIWE → J1 ──────────────────────────────────────────────
if should_run 2; then
  step 2 "Wallet SIWE → session J1 (managed-wallet attestation)"
  start=$(curl -sSf -X POST "$BROKER/v1/auth/wallet/start" -H 'content-type: application/json' \
    -d "$(jq -n --arg a "0x$DEPLOYER_ADDR" --argjson c 1 '{address:$a, chain_id:$c}')" 2>&1) || die "wallet/start: $start"
  req_id=$(echo "$start" | jq -r '.request_id // empty'); msg=$(echo "$start" | jq -r '.siwe_message // empty')
  [ -n "$req_id" ] || die "wallet/start gave no request_id: $start"
  sig=$(cast wallet sign --private-key "$DEPLOYER_KEY" "$msg")
  verify=$(curl -sSf -X POST "$BROKER/v1/auth/wallet/verify" -H 'content-type: application/json' \
    -d "$(jq -n --arg r "$req_id" --arg s "$sig" '{request_id:$r, signature:$s}')" 2>&1) || die "wallet/verify: $verify"
  J1=$(echo "$verify" | jq -r '.session_jwt // .jwt // empty')
  [ -n "$J1" ] || die "no session JWT: $verify"
  ok "J1 minted"
fi

# Mint a cap (op=memory-put|memory-get) for the master's own actor (no scope grant).
mint_cap() { local op="$1" ns="$2"
  curl -sS -X POST "$BROKER/v1/cap/$op" -H "authorization: Bearer $J1" -H 'content-type: application/json' \
    -d "$(jq -n --arg o "0x$DEPLOYER_OMNI" --arg s "memory:$ns" --arg d "$MASTER_DKH" \
      '{operator_omni:$o, actor_omni:$o, service:$s, device_key_hash:$d, ttl_seconds:300}')"; }

# STS relay: broker OIDC JWT → AssumeRoleWithWebIdentity → export AWS_* for the worker headers.
sts_relay() {
  local oj; oj=$(curl -sSf -X POST "$BROKER/v1/mint-oidc-jwt" -H "authorization: Bearer $J1" 2>&1) || { echo "mint-oidc-jwt: $oj" >&2; return 1; }
  local jwt; jwt=$(echo "$oj" | jq -r '.jwt // .oidc_jwt // empty'); [ -n "$jwt" ] || { echo "no oidc jwt: $oj" >&2; return 1; }
  local creds; creds=$(aws sts assume-role-with-web-identity --region "$REGION" \
    --role-arn "$MEMORY_ROLE_ARN" --role-session-name "memory-plant-$$" --web-identity-token "$jwt" \
    --duration-seconds 900 --output json 2>&1) || { echo "assume-role: $creds" >&2; return 1; }
  AK=$(echo "$creds" | jq -r '.Credentials.AccessKeyId'); SK=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey'); STK=$(echo "$creds" | jq -r '.Credentials.SessionToken')
  [ -n "$AK" ] && [ "$AK" != null ]; }

# ─── Step 3: cap-mint per namespace ────────────────────────────────────────
if should_run 3; then
  step 3 "Cap-mint memory-put per namespace (master-self, no scope grant)"
  declare -A CAP
  for ns in $NAMESPACES; do
    cap=$(mint_cap memory-put "$ns")
    echo "$cap" | jq -e '.cap // .payload // .signature' >/dev/null 2>&1 || die "cap-mint(memory:$ns) failed: $cap"
    CAP[$ns]="$cap"; ok "cap memory:$ns minted"
  done
fi

# ─── Step 4: worker put (real S3) per namespace ────────────────────────────
if should_run 4; then
  step 4 "Plant → worker /v1/memory/put → S3 (the button's write, scripted)"
  sts_relay || die "STS relay failed"
  for ns in $NAMESPACES; do
    cap="${CAP[$ns]:-$(mint_cap memory-put "$ns")}"
    b64=$(printf '%s' "$(plain_for "$ns")" | base64 | tr -d '\n')
    body=$(jq -n --argjson cap "$cap" --arg p "$b64" --arg n "$ns" '{cap:$cap, plaintext_b64:$p, namespace:$n}')
    resp=$(curl -sS -X POST "$MEMORY_URL/v1/memory/put" \
      -H "x-aws-access-key-id: $AK" -H "x-aws-secret-access-key: $SK" -H "x-aws-session-token: $STK" \
      -H 'content-type: application/json' -d "$body" 2>&1)
    key=$(echo "$resp" | jq -r '.s3_key // empty' 2>/dev/null)
    [ -n "$key" ] || die "worker put(memory:$ns) failed: $resp"
    ok "planted memory:$ns → $key"
  done
fi

# ─── Step 5: read-back proof ───────────────────────────────────────────────
if should_run 5; then
  step 5 "Read-back proof — worker /v1/memory/get one namespace"
  sts_relay || die "STS relay failed"
  ns=travel; cap=$(mint_cap memory-get "$ns")
  resp=$(curl -sS -X POST "$MEMORY_URL/v1/memory/get" \
    -H "x-aws-access-key-id: $AK" -H "x-aws-secret-access-key: $SK" -H "x-aws-session-token: $STK" \
    -H 'content-type: application/json' -d "$(jq -n --argjson cap "$cap" --arg n "$ns" '{cap:$cap, namespace:$n}')" 2>&1)
  got=$(echo "$resp" | jq -r '.plaintext_b64 // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
  echo "$got" | grep -q "Chengdu" || die "read-back of memory:$ns did not return the planted content: $resp"
  ok "read-back of memory:$ns returned the planted content ✓ (real S3 round-trip)"
fi

printf '\n%s master memory planted + verified through the REAL chain (same path as the web plant button).\n' "$(c '1;32' 'DONE ·')" >&2
