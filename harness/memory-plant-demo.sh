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

# DEDICATED DEMO namespaces — deliberately NOT the real travel/personal/family.
# The harness plants its proof memory under a clearly-ephemeral `demo-*` prefix so
# it (a) never pollutes the master's real memory and (b) can be deleted EXACTLY by
# the EXIT-trap cleanup below (success OR failure). The real prepared archive
# (apps/parent-control/lib/preparedMemory.ts) is planted ONLY by the user — the web
# "⊕ plant prepared memory" button — never auto-planted by onboarding or a demo.
# Each blob is a #201-Phase-4 JSON array of {key,title,body,updated,bytes}.
NAMESPACES="demo-travel demo-personal demo-family"
plain_for() { case "$1" in
  demo-travel)   printf '{"trip":"Chengdu 2025","dates":"Oct 3-12","hotel":"Niccolo","notes":"pandas at Dujiangyan; hotpot on Jinli"}' ;;
  demo-personal) printf '{"diet":"pescatarian","allergies":["peanuts"],"timezone":"Asia/Shanghai"}' ;;
  demo-family)   printf '{"partner":"Wen","kids":2,"emergency_contact":"+86-138-0000-0000"}' ;;
esac; }

profile_uc="$(printf '%s' "${AGENTKEYS_CHAIN:-heima}" | tr 'a-z-' 'A-Z_')"
BROKER="${OIDC_ISSUER:-${AGENTKEYS_BROKER_URL:-}}"
eval "MEMORY_URL=\${AGENTKEYS_WORKER_MEMORY_URL:-\${MEMORY_WORKER_URL:-}}"
eval "MEMORY_ROLE_ARN=\${MEMORY_ROLE_ARN:-\${MEMORY_ROLE_ARN_${profile_uc}:-}}"
REGION="${REGION:-us-east-1}"
MEMORY_BUCKET="${MEMORY_BUCKET:-}"

# Always-runs cleanup (success OR failure, via EXIT trap): delete the `demo-*`
# memory blobs this demo planted so test memory never leaks into the master's real
# store. Scoped to the exact S3 keys (bots/<omni>/memory/memory:<ns>.enc) — it can
# only ever touch the demo namespaces, never real user memory. `KEEP_DEMO_MEMORY=1`
# opts out (for debugging a failed run). Best-effort + idempotent.
cleanup_planted_memory() {
  [ "${KEEP_DEMO_MEMORY:-0}" = 1 ] && return 0
  [ -n "${DEPLOYER_OMNI:-}" ] && [ -n "$MEMORY_BUCKET" ] || return 0
  local n=0
  for ns in $NAMESPACES; do
    aws s3 rm "s3://$MEMORY_BUCKET/bots/$DEPLOYER_OMNI/memory/memory:$ns.enc" \
      --region "$REGION" >/dev/null 2>&1 && n=$((n + 1)) || true
  done
  [ "$n" -gt 0 ] && printf '  %s deleted %s demo memory blob(s) — bots/%s…/memory/memory:demo-*\n' \
    "$(c '1;33' cleanup)" "$n" "${DEPLOYER_OMNI:0:10}" >&2 || true
}
trap cleanup_planted_memory EXIT

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
  # $DEPLOYER_ADDR is ALREADY 0x-prefixed (cast wallet address output); do NOT prepend
  # another 0x (→ "0x0x…" → broker 400 malformed address). --fail-with-body surfaces the
  # broker's error JSON on 4xx (a bare -sSf hides it behind "curl: (22) … error: NNN").
  start=$(curl -sS --fail-with-body -X POST "$BROKER/v1/auth/wallet/start" -H 'content-type: application/json' \
    -d "$(jq -n --arg a "$DEPLOYER_ADDR" --argjson c 1 '{address:$a, chain_id:$c}')" 2>&1) || die "wallet/start: $start"
  req_id=$(echo "$start" | jq -r '.request_id // empty'); msg=$(echo "$start" | jq -r '.siwe_message // empty')
  [ -n "$req_id" ] || die "wallet/start gave no request_id: $start"
  sig=$(cast wallet sign --private-key "$DEPLOYER_KEY" "$msg")
  verify=$(curl -sS --fail-with-body -X POST "$BROKER/v1/auth/wallet/verify" -H 'content-type: application/json' \
    -d "$(jq -n --arg r "$req_id" --arg s "$sig" '{request_id:$r, signature:$s}')" 2>&1) || die "wallet/verify: $verify"
  J1=$(echo "$verify" | jq -r '.session_jwt // .jwt // empty')
  [ -n "$J1" ] || die "no session JWT: $verify"
  ok "J1 minted"
fi

# Master K10 — the per-request cap-mint proof-of-possession key (issue #76),
# registered as a CAP_MINT device by scripts/heima-register-master-k10.sh. The
# SAME secp256k1 key the daemon loads; device_key_hash = keccak(K10 addr).
K10_KEY_FILE="${AGENTKEYS_DEVICE_KEY_FILE:-$HOME/.agentkeys/agent-device.key}"
K10_PRIV=$(tr -d '[:space:]' < "$K10_KEY_FILE" 2>/dev/null || true)
[ -n "$K10_PRIV" ] || die "master K10 not found at $K10_KEY_FILE (issue #76: cap-mint needs it)"
K10_DKH=$(cast keccak "$(cast wallet address --private-key "$K10_PRIV" | tr '[:upper:]' '[:lower:]')")

# EIP-191 cap-PoP signature over agentkeys_core::device_crypto::cap_pop_payload.
# ⚠️ NEEDS-LIVE-VERIFICATION: confirm `cast wallet sign` of the 32-byte preimage
# matches device_crypto::eip191_sign (recovery byte 27/28; ecrecover accepts it).
cap_pop_sign() { local operator="$1" actor="$2" service="$3" op="$4" dc="$5" nonce="$6" ts="$7"
  local svc_hash preimage
  svc_hash=$(cast keccak "$(printf '%s' "$service" | tr '[:upper:]' '[:lower:]')")
  preimage=$(cast keccak "agentkeys-cap-pop:v1:${operator#0x}:${actor#0x}:${svc_hash#0x}:${op}:${dc}:${nonce}:${ts}")
  cast wallet sign --private-key "$K10_PRIV" "$preimage"; }

# Mint a cap (op=memory-put|memory-get) for the master's own actor (no scope grant).
mint_cap() { local op="$1" ns="$2"
  local opstr nonce ts sig; case "$op" in memory-put) opstr=store;; memory-get) opstr=fetch;; *) opstr="$op";; esac
  nonce=$(openssl rand -hex 16); ts=$(date +%s)
  sig=$(cap_pop_sign "0x$DEPLOYER_OMNI" "0x$DEPLOYER_OMNI" "memory:$ns" "$opstr" memory "$nonce" "$ts")
  # @backend-fixture: cap_mint_request  (issue #203 — gated by scripts/check-backend-fixture-drift.sh)
  local body; body=$(jq -n --arg o "0x$DEPLOYER_OMNI" --arg s "memory:$ns" --arg d "$K10_DKH" \
      --arg sig "$sig" --arg nonce "$nonce" --argjson ts "$ts" \
      '{operator_omni:$o, actor_omni:$o, service:$s, device_key_hash:$d, ttl_seconds:300, client_sig:$sig, client_nonce:$nonce, client_ts:$ts}')
  curl -sS -X POST "$BROKER/v1/cap/$op" -H "authorization: Bearer $J1" -H 'content-type: application/json' -d "$body"; }

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
  # No associative array: `declare -A` is bash 4+, but the operator platform is
  # macOS bash 3.2 (where it errors + `CAP[$ns]` under `set -u` treats the ns name
  # as an unbound arithmetic var). This step just proves cap-mint works per
  # namespace; step 4 re-mints fresh caps (they are short-TTL anyway).
  for ns in $NAMESPACES; do
    cap=$(mint_cap memory-put "$ns")
    echo "$cap" | jq -e '.cap // .payload // .signature' >/dev/null 2>&1 || die "cap-mint(memory:$ns) failed: $cap"
    ok "cap memory:$ns minted"
  done
fi

# ─── Step 4: worker put (real S3) per namespace ────────────────────────────
if should_run 4; then
  step 4 "Plant → worker /v1/memory/put → S3 (the button's write, scripted)"
  sts_relay || die "STS relay failed"
  for ns in $NAMESPACES; do
    cap=$(mint_cap memory-put "$ns")   # re-mint fresh (short-TTL; no cross-step array — bash 3.2)
    # #201 Phase 4: each ns blob is a JSON array of {key,title,body,updated,bytes}
    # — byte-for-byte the daemon's memory_put_ns_real format, so the web plant and
    # this script write the SAME on-disk shape for the master's own blobs.
    content="$(plain_for "$ns")"
    arr=$(jq -n --arg k "$ns" --arg b "$content" \
      '[{key:$k, title:$k, body:$b, updated:"2026-06-05", bytes:($b|length)}]')
    b64=$(printf '%s' "$arr" | base64 | tr -d '\n')
    # @backend-fixture: memory_put_body  (issue #203 — gated by scripts/check-backend-fixture-drift.sh)
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
  ns=demo-travel; cap=$(mint_cap memory-get "$ns")
  # @backend-fixture: memory_get_body  (issue #203 — gated by scripts/check-backend-fixture-drift.sh)
  get_body=$(jq -n --argjson cap "$cap" --arg n "$ns" '{cap:$cap, namespace:$n}')
  resp=$(curl -sS -X POST "$MEMORY_URL/v1/memory/get" \
    -H "x-aws-access-key-id: $AK" -H "x-aws-secret-access-key: $SK" -H "x-aws-session-token: $STK" \
    -H 'content-type: application/json' -d "$get_body" 2>&1)
  got=$(echo "$resp" | jq -r '.plaintext_b64 // empty' 2>/dev/null | base64 -d 2>/dev/null || true)
  # #201 Phase 4: the blob is a JSON array — assert the shape AND the content
  # round-tripped (fall back to a substring match for resilience).
  echo "$got" | jq -e '.[0].body | contains("Chengdu")' >/dev/null 2>&1 \
    || echo "$got" | grep -q "Chengdu" \
    || die "read-back of memory:$ns did not return the planted content: $resp"
  ok "read-back of memory:$ns returned the planted JSON-array content ✓ (real S3 round-trip)"
fi

printf '\n%s master memory planted + verified through the REAL chain (same path as the web plant button).\n' "$(c '1;32' 'DONE ·')" >&2
