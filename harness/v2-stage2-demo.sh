#!/usr/bin/env bash
# harness/v2-stage2-demo.sh — single source of truth for v2 stage-2 on
# Heima Mainnet (or any chain via AGENTKEYS_CHAIN).
#
# Idempotent end-to-end: build → forge test → deploy contracts (if not
# already deployed) → bootstrap primary master (if not registered) →
# spin up companion daemon → register companion as 2nd master → set
# recoveryThreshold = 2 → sanity-check recovery script → summary.
#
# Every step pre-checks "is this already done?" and skips when the work
# is a no-op. Re-runs are safe.
#
# Pause points (where the operator must interact, --webauthn mode only):
#   - Touch ID prompt for COMPANION K11 enrollment (step 5)
#   - Touch ID prompt for PRIMARY K11 during device-add (step 6)
#   - Touch ID prompt for PRIMARY K11 during set-threshold (step 7)
#   - Touch ID prompts for BOTH masters during recovery (step 8, only
#     if --revoke-master <hash> is passed)
#
# Default chain: heima (Mainnet). Override via AGENTKEYS_CHAIN env var.
#
# Modes:
#   --stub (default)      use deterministic K11 stub bytes; CI/no-touchid
#                         friendly; on-chain ops in steps 4, 6, 7, 8 are
#                         skipped because they need a real K11 sig.
#   --webauthn            use REAL WebAuthn ceremonies (Touch ID prompts)
#                         and submit real on-chain mutations.
#
# Step gating:
#   --from-step N         start at step N
#   --to-step N           stop after step N
#   --only-step N         run exactly step N
#   --revoke-master HASH  execute the M-of-N revoke at step 8 against HASH
#   --skip-build          assume agentkeys / agentkeys-daemon binaries are current
#   --redeploy            force a fresh contract deploy even if addresses exist
#   --help                this message
#
# Examples:
#   bash harness/v2-stage2-demo.sh                       # full demo, stub mode, Heima
#   bash harness/v2-stage2-demo.sh --webauthn            # with real Touch ID, full E2E
#   AGENTKEYS_CHAIN=anvil bash harness/v2-stage2-demo.sh # local dev backbone

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────
if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_SKIP='\033[1;33m'
  C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_SKIP=''; C_WARN=''; C_ERR=''; C_DIM=''; C_RESET=''
fi

STEP_NUM=0
STEP_TOTAL=11
CURRENT_STEP_NAME=""

step() { STEP_NUM=$((STEP_NUM+1)); CURRENT_STEP_NAME="$1"
         printf "${C_HEAD}==> [step %d/%d] %s${C_RESET}\n" \
           "$STEP_NUM" "$STEP_TOTAL" "$1" >&2 ; }
ok()   { printf "    ${C_OK}ok${C_RESET}    %s\n" "$1" >&2 ; }
info() { printf "    ${C_DIM}info${C_RESET}  %s\n" "$1" >&2 ; }
skip() { printf "    ${C_SKIP}skip${C_RESET}  %s\n" "$1" >&2 ; }
warn() { printf "    ${C_WARN}warn${C_RESET}  %s\n" "$1" >&2 ; }
die()  { printf "    ${C_ERR}fail${C_RESET}  %s\n" "$1" >&2
         [ "$STEP_NUM" -gt 0 ] && printf "          (step %d/%d: %s)\n" \
           "$STEP_NUM" "$STEP_TOTAL" "$CURRENT_STEP_NAME" >&2
         exit 1 ; }

# ─── Args ────────────────────────────────────────────────────────────
FROM_STEP=1
TO_STEP=$STEP_TOTAL
ONLY_STEP=""
SKIP_BUILD=0
USE_WEBAUTHN=0
REDEPLOY=0
REVOKE_TARGET=""
COMPANION_PORT="${AGENTKEYS_COMPANION_PORT:-9091}"

while [ $# -gt 0 ]; do
  case "$1" in
    --from-step)     FROM_STEP="$2"; shift 2 ;;
    --to-step)       TO_STEP="$2"; shift 2 ;;
    --only-step)     ONLY_STEP="$2"; shift 2 ;;
    --skip-build)    SKIP_BUILD=1; shift ;;
    --webauthn)      USE_WEBAUTHN=1; shift ;;
    --stub)          USE_WEBAUTHN=0; shift ;;
    --redeploy)      REDEPLOY=1; shift ;;
    --revoke-master) REVOKE_TARGET="$2"; shift 2 ;;
    --companion-port) COMPANION_PORT="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

if [ -n "$ONLY_STEP" ]; then FROM_STEP="$ONLY_STEP"; TO_STEP="$ONLY_STEP"; fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

AGENTKEYS_CHAIN="${AGENTKEYS_CHAIN:-heima}"
PROFILE_NAME_UC=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')

ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE — run scripts/setup-dev-env.sh first"
set -a; . "$ENV_FILE"; set +a

DEPLOYER_KEY_FILE="${HEIMA_DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-deployer.key}"

should_run_step() { [ "$1" -ge "$FROM_STEP" ] && [ "$1" -le "$TO_STEP" ]; }

# Idempotent env_set: replaces existing KEY=value line or appends.
env_set() {
  local key="$1" val="$2" file="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    # sed -i differs between macOS and GNU. Use portable form.
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "$file" && rm -f "$file.bak"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

# Resolve deployer key (raw hex or mnemonic) → MASTER_KEY.
resolve_master_key() {
  if [ ! -f "$DEPLOYER_KEY_FILE" ]; then return 1; fi
  local raw
  raw=$(cat "$DEPLOYER_KEY_FILE" | tr -d '\n[:space:]')
  if [ "${#raw}" = "66" ] && [ "${raw:0:2}" = "0x" ]; then
    echo "$raw"
  elif [ "${#raw}" = "64" ]; then
    echo "0x$raw"
  else
    # Mnemonic
    if [ ! -d "$REPO_ROOT/scripts/node_modules/ethers" ]; then
      npm install --prefix "$REPO_ROOT/scripts" --silent --no-audit --no-fund >/dev/null 2>&1
    fi
    node "$REPO_ROOT/scripts/derive-evm-from-mnemonic.mjs" "$DEPLOYER_KEY_FILE" | jq -r .privateKey
  fi
}

# ─── Step 1: Build CLI + daemon binaries ─────────────────────────────
if should_run_step 1; then
  step "Build agentkeys CLI + agentkeys-daemon (release)"
  if [ "$SKIP_BUILD" = 1 ] && [ -x "$REPO_ROOT/target/release/agentkeys" ] \
     && [ -x "$REPO_ROOT/target/release/agentkeys-daemon" ]; then
    skip "release binaries present (--skip-build)"
  else
    info "cargo build --release -p agentkeys-cli -p agentkeys-daemon"
    cargo build --release -p agentkeys-cli -p agentkeys-daemon >/dev/null 2>&1 \
      || die "cargo build failed"
    ok "release binaries built"
  fi
fi

AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
DAEMON_BIN="$REPO_ROOT/target/release/agentkeys-daemon"
[ -x "$AGENTKEYS_BIN" ] || die "missing $AGENTKEYS_BIN (run from-step 1)"
[ -x "$DAEMON_BIN" ] || die "missing $DAEMON_BIN (run from-step 1)"

PROFILE_JSON=$("$AGENTKEYS_BIN" chain show "$AGENTKEYS_CHAIN")
RPC_HTTP=$(echo "$PROFILE_JSON" | jq -r .rpc.http)

# ─── Step 2: Run forge tests ─────────────────────────────────────────
if should_run_step 2; then
  step "Run forge test suite (P256 + K11 + AgentKeysV1)"
  pushd "$REPO_ROOT/crates/agentkeys-chain" >/dev/null
  if forge test 2>&1 | tail -5 | grep -q "passed; 0 failed"; then
    ok "all forge tests pass"
  else
    die "forge test failed (run \`forge test\` in crates/agentkeys-chain to inspect)"
  fi
  popd >/dev/null
fi

# ─── Step 3: Deploy stage-2 contracts (if not already deployed) ──────
if should_run_step 3; then
  step "Deploy stage-2 contracts to $AGENTKEYS_CHAIN (idempotent)"

  has_all=1
  for var in P256_VERIFIER K11_VERIFIER SIDECAR_REGISTRY SCOPE_CONTRACT \
             K3_EPOCH_COUNTER CREDENTIAL_AUDIT; do
    eval "addr=\${${var}_ADDRESS_${PROFILE_NAME_UC}:-}"
    if [ -z "$addr" ] || [ "$addr" = "0x0" ]; then has_all=0; fi
  done

  if [ "$REDEPLOY" = 1 ]; then
    info "--redeploy forced; deploying fresh contracts"
    has_all=0
  fi

  if [ "$has_all" = 1 ]; then
    # Verify each address has code on chain. Heima's RPC occasionally hits
    # TLS-handshake-EOF transients — distinguish RPC failure from genuine
    # "no code at address":
    #   - cast code returns "0x" → genuinely no contract → can redeploy
    #   - cast code returns "" + nonzero exit → RPC failure → retry, then
    #     abort (don't redeploy when we're not sure)
    #   - cast code returns "0x6080..." → has contract → skip
    all_present=1
    for var in P256_VERIFIER K11_VERIFIER SIDECAR_REGISTRY SCOPE_CONTRACT \
               K3_EPOCH_COUNTER CREDENTIAL_AUDIT; do
      eval "addr=\${${var}_ADDRESS_${PROFILE_NAME_UC}}"
      code=""
      rpc_failed=1
      for attempt in 1 2 3 4 5 6 7 8; do
        set +e
        code=$(cast code "$addr" --rpc-url "$RPC_HTTP" 2>/dev/null)
        rc=$?
        set -e
        if [ "$rc" = "0" ]; then
          rpc_failed=0
          break
        fi
        info "RPC error reading code at $addr (attempt $attempt/8) — retrying in 3s"
        sleep 3
      done
      if [ "$rpc_failed" = "1" ]; then
        die "could not verify contract code at $addr after 8 RPC attempts (heima RPC may be down)"
      fi
      if [ "${#code}" -le 4 ]; then
        all_present=0
        warn "$var = $addr has no code on chain (will redeploy)"
        break
      fi
    done
    if [ "$all_present" = 1 ]; then
      skip "all 6 contracts already deployed on $AGENTKEYS_CHAIN"
    else
      has_all=0
    fi
  fi

  if [ "$has_all" = 0 ]; then
    MASTER_KEY=$(resolve_master_key) || die "could not resolve deployer key from $DEPLOYER_KEY_FILE"
    MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY")
    info "deployer = $MASTER_ADDR"
    BAL=""
    for attempt in 1 2 3 4 5; do
      BAL=$(cast balance "$MASTER_ADDR" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "")
      # Real balance, not the RPC-error empty case.
      if [ -n "$BAL" ] && [ "$BAL" != "0" ]; then break; fi
      sleep 2
    done
    [ -n "$BAL" ] || die "could not read balance from $RPC_HTTP after 5 attempts"
    info "balance  = $BAL wei (~$(echo "scale=4; $BAL / 1000000000000000000" | bc 2>/dev/null || echo "?") native)"
    # 6-contract deploy uses ~0.05 native; require ≥ 0.05 for headroom.
    if [ "$(echo "$BAL < 50000000000000000" | bc 2>/dev/null || echo 0)" = "1" ]; then
      die "deployer balance too low (< 0.05 native) — fund $MASTER_ADDR first"
    fi

    info "forge script script/DeployAgentKeysV1.s.sol …"
    pushd "$REPO_ROOT/crates/agentkeys-chain" >/dev/null
    DEPLOY_OUT=$(forge script script/DeployAgentKeysV1.s.sol \
      --rpc-url "$RPC_HTTP" \
      --private-key "$MASTER_KEY" \
      --broadcast --slow --evm-version london 2>&1) \
      || { echo "$DEPLOY_OUT" >&2; die "forge script failed"; }
    popd >/dev/null

    BCAST="$REPO_ROOT/crates/agentkeys-chain/broadcast/DeployAgentKeysV1.s.sol/$(cast chain-id --rpc-url "$RPC_HTTP")/run-latest.json"
    [ -f "$BCAST" ] || die "broadcast file not found at $BCAST"

    P256=$(jq -r '.transactions[] | select(.contractName=="P256Verifier") | .contractAddress' "$BCAST")
    K11=$(jq -r '.transactions[] | select(.contractName=="K11Verifier") | .contractAddress' "$BCAST")
    SIDECAR=$(jq -r '.transactions[] | select(.contractName=="SidecarRegistry") | .contractAddress' "$BCAST")
    SCOPE=$(jq -r '.transactions[] | select(.contractName=="AgentKeysScope") | .contractAddress' "$BCAST")
    EPOCH=$(jq -r '.transactions[] | select(.contractName=="K3EpochCounter") | .contractAddress' "$BCAST")
    AUDIT=$(jq -r '.transactions[] | select(.contractName=="CredentialAudit") | .contractAddress' "$BCAST")

    env_set "P256_VERIFIER_ADDRESS_${PROFILE_NAME_UC}" "$P256" "$ENV_FILE"
    env_set "K11_VERIFIER_ADDRESS_${PROFILE_NAME_UC}" "$K11" "$ENV_FILE"
    env_set "SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}" "$SIDECAR" "$ENV_FILE"
    env_set "SCOPE_CONTRACT_ADDRESS_${PROFILE_NAME_UC}" "$SCOPE" "$ENV_FILE"
    env_set "K3_EPOCH_COUNTER_ADDRESS_${PROFILE_NAME_UC}" "$EPOCH" "$ENV_FILE"
    env_set "CREDENTIAL_AUDIT_ADDRESS_${PROFILE_NAME_UC}" "$AUDIT" "$ENV_FILE"

    # Re-source so subsequent steps see fresh addresses.
    set -a; . "$ENV_FILE"; set +a

    ok "deployed:"
    echo "    P256Verifier     = $P256" >&2
    echo "    K11Verifier      = $K11" >&2
    echo "    SidecarRegistry  = $SIDECAR" >&2
    echo "    AgentKeysScope   = $SCOPE" >&2
    echo "    K3EpochCounter   = $EPOCH" >&2
    echo "    CredentialAudit  = $AUDIT" >&2
  fi
fi

# Re-source env so the latest addresses are visible regardless of step gating.
set -a; . "$ENV_FILE"; set +a
eval "REGISTRY=\${SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC}:-}"

# ─── Step 4: Bootstrap primary master on new SidecarRegistry ─────────
if should_run_step 4; then
  step "Bootstrap primary master on new SidecarRegistry (idempotent)"
  if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "0x0" ]; then
    die "no SIDECAR_REGISTRY_ADDRESS_${PROFILE_NAME_UC} — run step 3 first"
  fi

  # Need primary K11 enrolled at rp_id=localhost. If not, prompt the operator.
  MASTER_KEY=$(resolve_master_key) || die "could not resolve master key"
  MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY" | tr '[:upper:]' '[:lower:]')
  OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR" | shasum -a 256 | awk '{print $1}')
  K11_FILE="$HOME/.agentkeys/k11/${OPERATOR_OMNI}.json"

  if [ ! -f "$K11_FILE" ] || [ "$(jq -r .mode "$K11_FILE" 2>/dev/null)" != "webauthn" ]; then
    if [ "$USE_WEBAUTHN" = 1 ]; then
      info "enrolling primary K11 (Touch ID prompt incoming)…"
      "$AGENTKEYS_BIN" k11 enroll --webauthn --rp-id localhost \
        --operator-omni "0x$OPERATOR_OMNI" >/dev/null \
        || die "primary K11 enrollment failed"
      ok "primary K11 enrolled"
    else
      skip "no primary K11 at $K11_FILE — re-run with --webauthn to enroll"
    fi
  else
    ok "primary K11 already enrolled (mode=webauthn)"
  fi

  if [ -f "$K11_FILE" ] && [ "$(jq -r .mode "$K11_FILE" 2>/dev/null)" = "webauthn" ]; then
    info "running scripts/heima-register-first-master.sh …"
    if ! bash "$REPO_ROOT/harness/scripts/heima-register-first-master.sh" 2>&1 | tail -5 >&2; then
      die "register-first-master failed"
    fi
  else
    skip "skipping registerFirstMasterDevice (no usable K11)"
  fi
fi

# ─── Step 5: Enroll companion K11 + start companion daemon ───────────
if should_run_step 5; then
  step "Start companion daemon (rp_id=companion.localhost)"

  MASTER_KEY=$(resolve_master_key) || die "could not resolve master key"
  MASTER_ADDR=$(cast wallet address --private-key "$MASTER_KEY" | tr '[:upper:]' '[:lower:]')
  OPERATOR_OMNI=$(printf 'agentkeysevm%s' "$MASTER_ADDR" | shasum -a 256 | awk '{print $1}')

  # Find an active companion across versions (companion.localhost, then
  # companion-v2/v3/…). If none active, enroll a fresh version. This makes
  # the demo idempotent across runs where the companion was previously
  # revoked (e.g. as part of the M-of-N quorum test).
  COMPANION_RP_TAG="companion"
  COMP_FILE="$HOME/.agentkeys/k11/${OPERATOR_OMNI}--companion.localhost.json"
  if [ "$USE_WEBAUTHN" = "1" ]; then
    FOUND_ACTIVE=0
    for try_tag in companion companion-v2 companion-v3 companion-v4 companion-v5; do
      f="$HOME/.agentkeys/k11/${OPERATOR_OMNI}--${try_tag}.localhost.json"
      [ -f "$f" ] || continue
      cose=$(jq -r .cose_pubkey_hex "$f" 2>/dev/null) || continue
      hash=$(cast keccak "$cose")
      active=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$hash" --rpc-url "$RPC_HTTP" 2>/dev/null || echo false)
      if [ "$active" = "true" ]; then
        COMPANION_RP_TAG="$try_tag"
        COMP_FILE="$f"
        FOUND_ACTIVE=1
        ok "found active companion at rp_id=${try_tag}.localhost"
        break
      else
        info "$try_tag K11 file exists but device $hash is not active on chain"
      fi
    done
    if [ "$FOUND_ACTIVE" = "0" ]; then
      # Pick the lowest version with no K11 file yet.
      for try_tag in companion companion-v2 companion-v3 companion-v4 companion-v5; do
        f="$HOME/.agentkeys/k11/${OPERATOR_OMNI}--${try_tag}.localhost.json"
        if [ ! -f "$f" ]; then
          COMPANION_RP_TAG="$try_tag"
          COMP_FILE="$f"
          break
        fi
      done
      info "enrolling fresh companion K11 (Touch ID prompt at ${COMPANION_RP_TAG}.localhost)…"
      "$AGENTKEYS_BIN" k11 enroll --webauthn --rp-id "${COMPANION_RP_TAG}.localhost" \
        --operator-omni "0x$OPERATOR_OMNI" >/dev/null \
        || die "companion K11 enrollment failed"
      ok "companion K11 enrolled at $COMP_FILE"
    fi
  else
    info "stub mode — skipping companion K11 enrollment"
  fi
  COMPANION_RP_ID="${COMPANION_RP_TAG}.localhost"

  # Stop any pre-existing companion daemon on this port (idempotency).
  PRE_PID=$(lsof -ti tcp:"$COMPANION_PORT" 2>/dev/null || true)
  if [ -n "$PRE_PID" ]; then
    info "stopping pre-existing process on port $COMPANION_PORT (pid $PRE_PID)"
    kill "$PRE_PID" 2>/dev/null || true
    sleep 1
  fi

  # Compute companion's on-chain identifiers from its K11 file so registration
  # + later revoke can find it. Falls back to all-zeros in stub mode (no K11).
  COMP_DEVICE_KEY_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
  COMP_K11_CRED_ID_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
  if [ -f "$COMP_FILE" ]; then
    COSE_HEX=$(jq -r .cose_pubkey_hex "$COMP_FILE")
    COMP_DEVICE_KEY_HASH=$(cast keccak "$COSE_HEX")
    # k11CredId in the contract is bytes32; we hash the b64url credential id
    # because credential ids are variable-length opaque bytes.
    CRED_B64=$(jq -r .credential_id_b64url "$COMP_FILE")
    COMP_K11_CRED_ID_HASH="0x$(printf '%s' "$CRED_B64" | shasum -a 256 | awk '{print $1}')"
    info "companion device_key_hash = $COMP_DEVICE_KEY_HASH"
    info "companion k11_cred_id     = $COMP_K11_CRED_ID_HASH"
  fi

  COMP_LOG="/tmp/agentkeys-companion-$$.log"
  info "starting: $DAEMON_BIN --master-companion --companion-bind 127.0.0.1:$COMPANION_PORT --companion-rp-id $COMPANION_RP_ID"
  "$DAEMON_BIN" --master-companion \
    --companion-bind "127.0.0.1:$COMPANION_PORT" \
    --companion-operator-omni "0x$OPERATOR_OMNI" \
    --companion-device-key-hash "$COMP_DEVICE_KEY_HASH" \
    --companion-k11-cred-id "$COMP_K11_CRED_ID_HASH" \
    --companion-rp-id "$COMPANION_RP_ID" \
    >"$COMP_LOG" 2>&1 &
  COMP_PID=$!
  sleep 1
  if ! kill -0 "$COMP_PID" 2>/dev/null; then
    cat "$COMP_LOG" >&2 || true
    die "companion daemon failed to start (log: $COMP_LOG)"
  fi
  for _ in 1 2 3 4 5; do
    if curl -sSf "http://127.0.0.1:$COMPANION_PORT/v1/companion/whoami" >/dev/null 2>&1; then
      ok "companion daemon listening on 127.0.0.1:$COMPANION_PORT (pid $COMP_PID)"
      break
    fi
    sleep 1
  done
  echo "$COMP_PID" > /tmp/agentkeys-companion.pid
fi

# ─── Step 6: Register companion as 2nd master device ─────────────────
if should_run_step 6; then
  step "Register companion as 2nd master (heima-device-add.sh)"
  if [ "$USE_WEBAUTHN" = "1" ]; then
    # Codex H2: fail-fast. Silent device-add failure breaks the
    # invariant that step 9 has 2 active masters available for quorum.
    bash "$REPO_ROOT/harness/scripts/heima-device-add.sh" \
      --companion-url "http://127.0.0.1:$COMPANION_PORT" 2>&1 | tail -5 >&2 \
      || die "device-add failed — chain doesn't have a 2nd master, refusing to advance"
    # Verify companion is now active on chain.
    COMP_HASH_NOW=$(curl -sS "http://127.0.0.1:$COMPANION_PORT/v1/companion/whoami" 2>/dev/null | jq -r .device_key_hash)
    IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$COMP_HASH_NOW" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "false")
    [ "$IS_ACTIVE" = "true" ] \
      || die "post-step-6 companion isActive($COMP_HASH_NOW) = $IS_ACTIVE (expected true)"
    ok "on-chain companion isActive confirmed = true"
  else
    skip "stub mode — would call heima-device-add.sh (real K11 ceremony required)"
  fi
fi

# ─── Step 7: Set recoveryThreshold = 2 ───────────────────────────────
if should_run_step 7; then
  step "Set recoveryThreshold = 2 on $AGENTKEYS_CHAIN"
  if [ "$USE_WEBAUTHN" = "1" ]; then
    # Codex H2: must fail-fast. A silently-failed threshold-set leaves the
    # chain at threshold=1 while later steps falsely claim 2-of-2 quorum.
    bash "$REPO_ROOT/harness/scripts/heima-set-recovery-threshold.sh" --threshold 2 2>&1 | tail -5 >&2 \
      || die "set-recovery-threshold failed — chain may still be at threshold=1, refusing to advance"
    # Verify on chain. If the operator was already at threshold=2, the
    # script skip'd (rc=0) and this assertion confirms the state matches.
    POST=$(cast call "$REGISTRY" "recoveryThreshold(bytes32)(uint8)" "0x$OPERATOR_OMNI" --rpc-url "$RPC_HTTP" 2>/dev/null || echo 0)
    [ "$POST" = "2" ] \
      || die "post-step-7 recoveryThreshold = $POST (expected 2). Refusing to advance to M-of-N revoke step."
    ok "on-chain recoveryThreshold confirmed = 2"
  else
    skip "stub mode — would call heima-set-recovery-threshold.sh --threshold 2"
  fi
fi

SPARE_STATE_DIR="${SPARE_STATE_DIR:-/tmp/agentkeys-spare-current}"

# ─── Step 8: Register a synthetic 3rd master (the "spare") ────────────
# Why synthetic: the spare exists ONLY to be revoked in step 9. It never
# needs to sign for its own revocation (primary + companion provide the
# 2-of-2 quorum). Using a freshly-generated P-256 keypair (not a real
# WebAuthn passkey) saves a Touch ID without weakening the contract test.
if should_run_step 8; then
  step "Register synthetic 3rd master (the \"spare\" — will be revoked in step 9)"
  if [ "$USE_WEBAUTHN" != "1" ]; then
    skip "stub mode — spare registration needs primary K11 ceremony"
  else
    if ! bash "$REPO_ROOT/harness/scripts/heima-register-spare-master.sh" \
         --state-dir "$SPARE_STATE_DIR" 2>&1 | tail -10 >&2; then
      die "spare master registration failed"
    fi
  fi
fi

# ─── Step 9: Revoke the spare via 2-of-2 M-of-N quorum ────────────────
if should_run_step 9; then
  step "Revoke spare via 2-of-2 M-of-N quorum (primary + companion)"
  if [ "$USE_WEBAUTHN" != "1" ]; then
    skip "stub mode — revoke needs primary + companion K11 ceremonies"
  elif [ ! -f "$SPARE_STATE_DIR/device_key_hash" ]; then
    skip "no spare state at $SPARE_STATE_DIR — re-run step 8 first"
  else
    SPARE_HASH=$(cat "$SPARE_STATE_DIR/device_key_hash")
    info "target spare device_key_hash = $SPARE_HASH"

    # Check if already revoked (idempotency).
    IS_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$SPARE_HASH" --rpc-url "$RPC_HTTP" 2>/dev/null || echo "false")
    if [ "$IS_ACTIVE" = "false" ]; then
      skip "spare already revoked"
    else
      info "running heima-recovery.sh with --target-device-key-hash $SPARE_HASH"
      info "(2 Touch ID prompts incoming: PRIMARY MASTER at localhost, then COMPANION MASTER at companion.localhost)"
      bash "$REPO_ROOT/harness/scripts/heima-recovery.sh" \
        --target-device-key-hash "$SPARE_HASH" \
        --companion-url "http://127.0.0.1:$COMPANION_PORT" 2>&1 | tail -10 >&2 \
        || die "recovery failed"

      POST_ACTIVE=$(cast call "$REGISTRY" "isActive(bytes32)(bool)" "$SPARE_HASH" --rpc-url "$RPC_HTTP")
      [ "$POST_ACTIVE" = "false" ] || die "post-revoke isActive($SPARE_HASH) = $POST_ACTIVE (expected false)"
      ok "spare revoked — M-of-N quorum verified on chain"
    fi
  fi
fi

# ─── Step 10: Tier-A audit relay + email-inbox smoke (issue #90 workers) ──
if should_run_step 10; then
  step "Tier-A audit relay + email-inbox smoke (workers co-located on broker host)"
  if bash "$REPO_ROOT/scripts/heima-worker-smoke.sh" 2>&1 | tail -20 >&2; then
    ok "tier-A Merkle root committed on-chain; email worker /healthz green"
  else
    die "heima-worker-smoke.sh failed — workers deployed? Run scripts/verify-workers.sh from this laptop."
  fi
fi

# ─── Step 11: Cleanup + summary ───────────────────────────────────────
if should_run_step 11; then
  step "Cleanup spare local state + summary"
  if [ -d "$SPARE_STATE_DIR" ]; then
    info "removing local spare state at $SPARE_STATE_DIR"
    info "(on-chain entry stays as revoked=true — that's the audit trail)"
    rm -rf "$SPARE_STATE_DIR"
    ok "local spare state cleared"
  else
    skip "no local spare state to clean up"
  fi
  if [ -f /tmp/agentkeys-companion.pid ]; then
    COMP_PID=$(cat /tmp/agentkeys-companion.pid)
    if kill -0 "$COMP_PID" 2>/dev/null; then
      info "companion daemon still running at pid $COMP_PID — stop with: kill $COMP_PID"
    fi
  fi
  printf "${C_OK}\n=== v2 stage-2 demo complete ===${C_RESET}\n" >&2
  printf "  Chain:           %s\n" "$AGENTKEYS_CHAIN" >&2
  printf "  Mode:            %s\n" "$([ "$USE_WEBAUTHN" = 1 ] && echo "WebAuthn (real Touch ID)" || echo "stub (CI)")" >&2
  printf "  P256Verifier:    %s\n" "${P256_VERIFIER_ADDRESS_HEIMA:-unset}" >&2
  printf "  K11Verifier:     %s\n" "${K11_VERIFIER_ADDRESS_HEIMA:-unset}" >&2
  printf "  SidecarRegistry: %s\n" "${SIDECAR_REGISTRY_ADDRESS_HEIMA:-unset}" >&2
  printf "  AgentKeysScope:  %s\n" "${SCOPE_CONTRACT_ADDRESS_HEIMA:-unset}" >&2
  printf "  K3EpochCounter:  %s\n" "${K3_EPOCH_COUNTER_ADDRESS_HEIMA:-unset}" >&2
  printf "  CredentialAudit: %s\n" "${CREDENTIAL_AUDIT_ADDRESS_HEIMA:-unset}" >&2
  printf "  Companion URL:   http://127.0.0.1:%s\n" "$COMPANION_PORT" >&2
  printf "\n" >&2
fi
