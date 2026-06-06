#!/usr/bin/env bash
# harness/web-memory-bootstrap.sh — idempotent bootstrap + pre-flight proof for
# the issue #196 web memory demo ("login → master device auto-registers on
# passkey-finish → the memory plant button writes to S3, no manual CLI").
#
# This script does the OPERATOR-RUNNABLE requirements (build, contracts, fund,
# CLI register, broker proof) and then prints the one MANUAL browser step. It
# is idempotent: every step pre-checks state and short-circuits with `skip`
# when already done, so re-running is safe (same posture as setup-heima.sh /
# setup-broker-host.sh).
#
# Steps:
#   1. Build agentkeys + agentkeys-daemon (cargo, incremental — gets the #196
#      `--register-master-script` flag + the register shell-out).
#   2. Contracts live   — verify-heima-contracts.sh (read-only RPC, zero gas).
#   3. Broker reachable — curl $OIDC_ISSUER; reminds that the broker must be on
#      #195+ (the master-self scope skip lives in cap.rs + verify.rs).
#   4. Fund master gas-payer — heima-fund-master.sh (idempotent skip-if-funded).
#      In #196 option (α) the deployer signs the register tx, so this is a clean
#      no-op when the deployer is already funded.
#   5. Register master device on chain — register_first_master (_lib.sh): the
#      #164 passkey-account ERC-4337 path (operatorMasterWallet[omni] = the
#      P256Account), EOA fallback when the #164 infra/tooling is absent. Both
#      register device_key_hash = keccak(operator_omni). Idempotent. (The WEB
#      flow registers under the SESSION omni on passkey-finish — same mechanism.)
#   6. PROOF — SIWE auth → master-self cap-mint with NO scope grant → HTTP 200.
#      Verifies all three at once: device registered (5) + #195 scope-skip live
#      on the broker + the cap-mint path works. A ServiceNotInScope here means
#      the broker is pre-#195 (redeploy it); DeviceNotActive means step 5 didn't
#      land. This is the same assertion as v2-stage3-demo.sh step 16.
#   7. Web demo guidance — prints the daemon launch command + the one ordering
#      rule (email-verify BEFORE passkey-finish) + "click the plant button".
#      MANUAL (browser); the script can't drive WebAuthn.
#
# Flags (mirror setup-heima.sh / v2-stage3-demo.sh):
#   --from-step N      start at step N
#   --to-step N        stop after step N
#   --only-step N      run exactly step N
#   --test             source operator-workstation.test.env instead of prod
#   --ci               CI run: tolerate skip when the #164 passkey-register prereqs
#                      are unavailable (never falls back to the deprecated EOA path).
#                      Without it (local run) the passkey register must succeed.
#   --help
#
# Runbook: docs/operator-runbook-web-memory.md

set -euo pipefail

STEP_TOTAL=7
FROM_STEP=1
TO_STEP=$STEP_TOTAL
TEST_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from-step)  FROM_STEP="$2"; shift 2 ;;
    --to-step)    TO_STEP="$2"; shift 2 ;;
    --only-step)  FROM_STEP="$2"; TO_STEP="$2"; shift 2 ;;
    --test)       TEST_MODE=1; shift ;;
    --ci)         export AGENTKEYS_CI=1; shift ;;   # CI run: tolerate skip when #164 passkey prereqs absent (never EOA)
    --help|-h)    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_SKIP='\033[1;33m'; C_ERR='\033[1;31m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_SKIP=''; C_ERR=''; C_DIM=''; C_RESET=''
fi
CUR_STEP=0
step() { CUR_STEP="$1"; printf "${C_HEAD}\n==> [step %d/%d] %s${C_RESET}\n" "$1" "$STEP_TOTAL" "$2" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
skip() { printf "    ${C_SKIP}skip${C_RESET} %s\n" "$*" >&2; }
info() { printf "    ${C_DIM}%s${C_RESET}\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }
should_run_step() { [ "$1" -ge "$FROM_STEP" ] && [ "$1" -le "$TO_STEP" ]; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [ "$TEST_MODE" = "1" ]; then
  ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.test.env}"
else
  ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
fi
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE — run from a clone of agentKeys"
set -a; . "$ENV_FILE"; set +a
. "$REPO_ROOT/harness/scripts/_lib.sh"

: "${OIDC_ISSUER:?OIDC_ISSUER unset (operator-workstation.env)}"
AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"

# Resolve the agentkeys binary (workspace-local first).
resolve_bin() {
  if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then echo "$REPO_ROOT/target/release/agentkeys";
  elif [ -x "$REPO_ROOT/target/debug/agentkeys" ]; then echo "$REPO_ROOT/target/debug/agentkeys";
  else command -v agentkeys || true; fi
}

# Deployer identity (the register-tx signer + the SIWE wallet for the proof).
DEPLOYER_KEY="$(resolve_master_key)" || die "could not resolve deployer key (set HEIMA_DEPLOYER_KEY_FILE or ~/.agentkeys/heima-deployer.key)"
DEPLOYER_ADDR="$(cast wallet address --private-key "$DEPLOYER_KEY")"
DEPLOYER_ADDR_LC="$(printf '%s' "$DEPLOYER_ADDR" | tr '[:upper:]' '[:lower:]')"
DEPLOYER_OMNI="$(printf 'agentkeysevm%s' "$DEPLOYER_ADDR_LC" | shasum -a 256 | awk '{print $1}')"
# The operator's ACTIVE master device on chain — the #164 keccak(operator_omni)
# or the legacy EOA keccak(deployer_addr), whichever is registered (an operator
# bootstrapped before the erc4337 change carries the legacy one). Falls back to
# keccak(operator_omni) when none is registered yet (step 5 will register).
MASTER_DKH="$(resolve_active_master_dkh "$DEPLOYER_OMNI" "$DEPLOYER_ADDR_LC" 2>/dev/null || cast keccak "0x$DEPLOYER_OMNI")"

PROFILE_NAME_UC="$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')"
eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"

printf "${C_HEAD}=== issue #196 web-memory bootstrap ===${C_RESET}\n" >&2
printf "  chain=%s  issuer=%s\n  deployer=%s\n  operator_omni=0x%s\n  device_key_hash=%s\n  steps %d..%d of %d\n" \
  "$AGENTKEYS_CHAIN" "$OIDC_ISSUER" "$DEPLOYER_ADDR" "$DEPLOYER_OMNI" "$MASTER_DKH" "$FROM_STEP" "$TO_STEP" "$STEP_TOTAL" >&2

RPC_HTTP=""
resolve_rpc() {
  [ -n "$RPC_HTTP" ] && return 0
  local bin; bin="$(resolve_bin)"
  [ -n "$bin" ] || die "agentkeys binary not found — run step 1 (build) first"
  RPC_HTTP="$("$bin" chain show "$AGENTKEYS_CHAIN" | jq -r .rpc.http)"
  [ -n "$RPC_HTTP" ] && [ "$RPC_HTTP" != "null" ] || die "could not resolve RPC for $AGENTKEYS_CHAIN"
}

# ─── Step 1: Build the #196 binary (incremental → idempotent) ──────────────
if should_run_step 1; then
  step 1 "Build agentkeys + agentkeys-daemon (cargo incremental)"
  if cargo build --release -p agentkeys-cli -p agentkeys-daemon 2>&1 | tail -2 >&2; then
    ok "built target/release/agentkeys + target/release/agentkeys-daemon"
  else
    die "cargo build failed"
  fi
fi

# ─── Step 2: Contracts live (read-only) ────────────────────────────────────
if should_run_step 2; then
  step 2 "Verify Heima contracts live (read-only RPC, zero gas)"
  if AGENTKEYS_CHAIN="$AGENTKEYS_CHAIN" bash "$REPO_ROOT/scripts/verify-heima-contracts.sh" >&2; then
    ok "all contracts live + functional"
  else
    die "verify-heima-contracts.sh failed — deploy/bring-up the chain first (scripts/setup-heima.sh)"
  fi
fi

# ─── Step 3: Broker reachable + #195 reminder ──────────────────────────────
if should_run_step 3; then
  step 3 "Broker reachable (and on #195+ for the master-self scope skip)"
  rc=$(curl -sS -o /dev/null -w '%{http_code}' "$OIDC_ISSUER/healthz" 2>/dev/null || echo 000)
  case "$rc" in
    200|204) ok "broker $OIDC_ISSUER reachable (HTTP $rc)" ;;
    000)     die "broker $OIDC_ISSUER unreachable — start/redeploy it: bash scripts/setup-broker-host.sh --ref main" ;;
    *)       ok "broker $OIDC_ISSUER responded HTTP $rc (reachable)" ;;
  esac
  info "#196 adds NO broker/worker code; it requires #195 (master-self scope skip in cap.rs + verify.rs)."
  info "If step 6 returns ServiceNotInScope, the broker is pre-#195 → redeploy: bash scripts/setup-broker-host.sh --ref main"
fi

# ─── Step 4: Fund the master gas-payer (idempotent) ────────────────────────
if should_run_step 4; then
  step 4 "Fund master gas-payer (deployer signs the register tx in option α)"
  if bash "$REPO_ROOT/scripts/heima-fund-master.sh" >&2; then
    ok "master gas-payer funded (or already ≥ threshold — idempotent skip)"
  else
    die "heima-fund-master.sh failed"
  fi
fi

# ─── Step 5: Register the master device on chain (idempotent) ──────────────
if should_run_step 5; then
  step 5 "Register master device on chain (#164 passkey-account ERC-4337; EOA fallback)"
  resolve_rpc
  [ -n "$REGISTRY" ] || die "no SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC} in $ENV_FILE — run scripts/setup-heima.sh"
  active=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$MASTER_DKH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo false)
  if [ "$active" = "true" ]; then
    skip "master device $MASTER_DKH already active on chain"
  else
    # register_first_master (harness/scripts/_lib.sh) uses the #164 passkey-account
    # UserOp (operatorMasterWallet[omni] = the P256Account, Rust signer, no python):
    # HARDWARE Touch ID locally, the SOFTWARE file-key signer under --ci. The old EOA
    # path is DEPRECATED (escape-only, AGENTKEYS_REGISTER_MODE=eoa — never an auto fallback).
    # Both conventions register device_key_hash = keccak(operator_omni) = $MASTER_DKH,
    # so step 6's proof resolves it either way.
    if register_first_master "$DEPLOYER_OMNI"; then
      ok "master device registered (device_key_hash=$MASTER_DKH)"
    else
      skip "register_first_master could not run — see the log above.
       • WEB demo: no terminal action needed; the daemon auto-registers under the
         SESSION omni on passkey-finish (issue #196). Step 6's proof will skip.
       • Force the EOA path: AGENTKEYS_REGISTER_MODE=eoa bash harness/web-memory-bootstrap.sh --only-step 5
         (then enroll a disk K11: agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x$DEPLOYER_OMNI)"
    fi
  fi
fi

# ─── Step 6: PROOF — master-self cap mints with NO scope grant (=stage-3 #16) ─
if should_run_step 6; then
  step 6 "PROOF: master-self cap mints with NO scope grant (device + #195 + broker)"
  resolve_rpc
  active=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$MASTER_DKH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo false)
  if [ "$active" != "true" ]; then
    skip "deployer-omni device not registered (step 5 skipped) — proof needs a registered device.
       The WEB flow registers under the session omni instead; verify there via the plant button."
  else
    # SIWE wallet auth → session JWT (deployer wallet → session omni == device omni).
    start=$(curl -sSf -X POST "$OIDC_ISSUER/v1/auth/wallet/start" -H 'content-type: application/json' \
      -d "$(jq -n --arg a "$DEPLOYER_ADDR" '{address:$a, chain_id:1}')" 2>&1) || die "wallet/start failed: $start"
    req_id=$(echo "$start" | jq -r .request_id); msg=$(echo "$start" | jq -r .siwe_message)
    [ -n "$req_id" ] && [ "$req_id" != "null" ] || die "wallet/start gave no request_id: $start"
    sig=$(cast wallet sign --private-key "$DEPLOYER_KEY" "$msg")
    verify=$(curl -sSf -X POST "$OIDC_ISSUER/v1/auth/wallet/verify" -H 'content-type: application/json' \
      -d "$(jq -n --arg r "$req_id" --arg s "$sig" '{request_id:$r, signature:$s}')" 2>&1) || die "wallet/verify failed: $verify"
    jwt=$(echo "$verify" | jq -r '.session_jwt // .jwt // empty')
    [ -n "$jwt" ] || die "wallet/verify returned no session JWT: $verify"
    # master-self memory cap, NO scope grant (operator == actor == deployer omni).
    body=$(jq -n --arg o "0x$DEPLOYER_OMNI" --arg s "memory:bootstrap-proof" --arg d "$MASTER_DKH" \
      '{operator_omni:$o, actor_omni:$o, service:$s, device_key_hash:$d, ttl_seconds:300}')
    rc=$(curl -sS -o /tmp/wmcap.$$.json -w '%{http_code}' -X POST "$OIDC_ISSUER/v1/cap/memory-put" \
      -H "authorization: Bearer $jwt" -H 'content-type: application/json' -d "$body" 2>&1 || echo 000)
    rbody=$(cat /tmp/wmcap.$$.json 2>/dev/null || true); rm -f /tmp/wmcap.$$.json
    if [ "$rc" = "200" ]; then
      ok "master-self cap minted with NO scope grant — device + #195 skip + broker all proven ✓"
      info "the same machinery serves the web flow under the managed-wallet session omni."
    elif echo "$rbody" | grep -qiE "not.*scope|NotInScope|service_not_in_scope"; then
      die "ServiceNotInScope — the broker is PRE-#195 (master-self scope skip missing). Redeploy: bash scripts/setup-broker-host.sh --ref main. body: $rbody"
    elif echo "$rbody" | grep -qiE "DeviceNotActive|device.*not.*active|DeviceBindingMismatch|DeviceRoleMissing|role_missing"; then
      die "device check failed (HTTP $rc) — re-run --only-step 5 to register. body: $rbody"
    else
      die "master-self cap-mint returned HTTP $rc — body: $rbody"
    fi
  fi
fi

# ─── Step 7: MANUAL — the live web demo (browser) ──────────────────────────
if should_run_step 7; then
  step 7 "Live web demo (MANUAL — browser passkey can't be scripted)"
  cat >&2 <<EOF
    Launch the daemon with the #196 register shell-out wired in:

      target/release/agentkeys-daemon \\
        --register-master-script $REPO_ROOT/harness/scripts/heima-register-first-master.sh \\
        --broker-url $OIDC_ISSUER \\
        --signer-url <SIGNER_URL> \\
        --memory-url ${AGENTKEYS_WORKER_MEMORY_URL:-<MEMORY_WORKER_URL>} \\
        --memory-role-arn ${MEMORY_ROLE_ARN:-<MEMORY_ROLE_ARN>} \\
        --config-url ${AGENTKEYS_WORKER_CONFIG_URL:-<CONFIG_WORKER_URL>} \\
        --config-role-arn ${CONFIG_ROLE_ARN:-<CONFIG_ROLE_ARN>} \\
        --region ${REGION:-us-east-1}
      # the daemon's env must resolve the deployer key (it signs the register tx)
      # + have cast + agentkeys on PATH + $ENV_FILE present.
      # --config-url/--config-role-arn (#201 Phase 4) let the memory list resolve
      # categories from the durable, master-only taxonomy; omit for the in-memory
      # fallback (the list then derives categories from the cache).

    Then in the web UI, IN THIS ORDER (the one sequencing rule):
      1. Verify email (mints J1 + freezes the session omni).
      2. Finish the passkey (Touch ID) — on finish the daemon auto-submits
         registerFirstMasterDevice under the session omni; chain_tx_hash is real.
         (If you finish the passkey BEFORE email-verify, registration is skipped
          with a clear chain_error; just re-finish after verifying.)
      3. Confirm:  curl -s \$UI_BRIDGE/v1/onboarding/state | jq .chain
                   # → "master-registered"
      4. Click the memory plant button → writes per-ns JSON arrays at
         bots/0x<omni>/memory/memory:<ns>.enc + (if --config-url set) the
         master-only taxonomy at bots/0x<omni>/config/memory-taxonomy.enc.
EOF
  ok "web-demo instructions printed"
fi

printf "${C_OK}\n=== bootstrap complete (steps %d..%d) ===${C_RESET}\n" "$FROM_STEP" "$TO_STEP" >&2
printf "  re-run a single step:  bash harness/web-memory-bootstrap.sh --only-step N\n" >&2
