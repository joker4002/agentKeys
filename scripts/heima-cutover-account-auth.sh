#!/usr/bin/env bash
# scripts/heima-cutover-account-auth.sh — the #225 / #164 E7 account-auth cutover.
#
# Forces a redeploy of the v2 contract set (SidecarRegistry + AgentKeysScope + …)
# so the **account-auth** sources (E3: master writes gated by `msg.sender ==
# operatorMasterWallet`, `setScopeWithWebauthn`→`setScope`) go LIVE — replacing the
# pre-E3 bytecode that `heima-bring-up.sh`'s `cast code` idempotency check otherwise
# keeps in place. This is what makes the #225 accept batch's `setScope` (P.3) call
# real. Full spec: docs/plan/chain/account-auth-cutover.md.
#
# ⚠️ DESTRUCTIVE: a redeploy mints NEW addresses with EMPTY state — the registered
# master, every agent binding, every scope grant, the K3 epoch counter and the
# audit history are NOT migrated. After it, the master + agents must be
# re-registered (Phase 3/4 below, separate idempotent helpers). Announce + schedule
# this; it is OPT-IN (NOT part of a plain `setup-heima.sh` run).
#
# Idempotent: a re-run with the cutover already done logs `skip already-cut-over`
# and exits 0. The ground-truth probe is the live scope's bytecode carrying the
# account-auth `setScope` selector (d8e9e3c6); the `CUTOVER_DONE_<profile>` env
# marker is the fast path. `--force-cutover` clears the marker to redeploy again.
#
# Phases here: 0 (pre-flight + env backup), 1 (redeploy v2 set), 2 (factory check).
# Phase 3 (onboarding-as-account) = `harness/scripts/erc4337-register-master.sh`;
# Phase 4 (re-bootstrap actors) = `heima-agent-create.sh` / `heima-scope-set.sh`;
# Phase 6 (broker redeploy) = `setup-broker-host.sh --ref main`. All printed at the
# end as the required follow-ups.
#
# Usage:
#   bash scripts/heima-cutover-account-auth.sh [--chain heima] [--yes] [--force-cutover]
#   AGENTKEYS_CHAIN, ENV_FILE, AGENTKEYS_CHAIN_RPC_HTTP honored from the environment.
set -euo pipefail

# ─── args + env ────────────────────────────────────────────────────────────────
CHAIN="${AGENTKEYS_CHAIN:-heima}"
ASSUME_YES=0
FORCE_CUTOVER=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"

while [ $# -gt 0 ]; do
  case "$1" in
    --chain)          CHAIN="$2"; shift 2 ;;
    --chain=*)        CHAIN="${1#*=}"; shift ;;
    --env-file)       ENV_FILE="$2"; shift 2 ;;
    --env-file=*)     ENV_FILE="${1#*=}"; shift ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --force-cutover)  FORCE_CUTOVER=1; shift ;;
    -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ─── logging (mirrors setup-heima.sh) ────────────────────────────────────────────
ok()   { printf '    ok    %s\n' "$1" >&2; }
skip() { printf '    skip  %s\n' "$1" >&2; }
fail() { printf '    fail  %s\n' "$1" >&2; }
step() { printf '==> %s\n' "$1" >&2; }
die()  { fail "$1"; exit 1; }

[ -f "$ENV_FILE" ] || die "env file not found: $ENV_FILE"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

PROFILE_UC="$(printf '%s' "$CHAIN" | tr '[:lower:]-' '[:upper:]_')"
RPC_HTTP="${AGENTKEYS_CHAIN_RPC_HTTP:-$(eval echo "\${RPC_HTTP_${PROFILE_UC}:-}")}"
[ -n "$RPC_HTTP" ] || die "no RPC: set AGENTKEYS_CHAIN_RPC_HTTP or RPC_HTTP_${PROFILE_UC} in $ENV_FILE"

SCOPE_ADDR="$(eval echo "\${SCOPE_CONTRACT_ADDRESS_${PROFILE_UC}:-}")"
MARKER_KEY="CUTOVER_DONE_${PROFILE_UC}"
MARKER_VAL="$(eval echo "\${${MARKER_KEY}:-}")"
SCOPE_SET_SELECTOR="d8e9e3c6" # setScope(bytes32,bytes32,bytes32[],bool,uint128,uint128,uint128,uint32)

for t in cast grep; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done

# Idempotent env writer (update-or-append; bash-only, no zsh modifier hazards).
env_set() {
  local key="$1" val="$2" tmp
  if grep -qE "^${key}=" "$ENV_FILE"; then
    tmp="$(mktemp)"
    sed "s|^${key}=.*|${key}=${val}|" "$ENV_FILE" >"$tmp" && mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
  fi
}

# Ground-truth probe: does the LIVE scope carry the account-auth setScope selector?
scope_is_account_auth() {
  local addr="$1" code
  [ -n "$addr" ] || return 1
  code="$(cast code "$addr" --rpc-url "$RPC_HTTP" 2>/dev/null || echo 0x)"
  printf '%s' "$code" | grep -qi "$SCOPE_SET_SELECTOR"
}

# ─── Phase 0 — pre-flight + env backup ───────────────────────────────────────────
phase0() {
  step "Phase 0 — pre-flight + backup"
  local scope_src="$REPO_ROOT/crates/agentkeys-chain/src/AgentKeysScope.sol"
  [ -f "$scope_src" ] || die "account-auth sources not found ($scope_src) — run from a checkout with crates/agentkeys-chain"
  if grep -qE "function setScope\(" "$scope_src" && ! grep -qE "function setScopeWithWebauthn\(" "$scope_src"; then
    ok "local AgentKeysScope.sol is account-auth (setScope present, setScopeWithWebauthn gone)"
  else
    die "local AgentKeysScope.sol is NOT account-auth — refusing to cut over to non-E3 bytecode"
  fi
  local bak="$ENV_FILE.pre-cutover.bak"
  if [ -f "$bak" ]; then
    skip "env backup already exists ($bak)"
  else
    cp "$ENV_FILE" "$bak" && ok "backed up env → $bak (rollback: restore it + redeploy broker)"
  fi
}

# ─── Phase 1 — force-redeploy the account-auth v2 set ────────────────────────────
phase1() {
  step "Phase 1 — redeploy v2 set (account-auth)"
  if [ "$FORCE_CUTOVER" != "1" ] && [ "$MARKER_VAL" = "1" ] && scope_is_account_auth "$SCOPE_ADDR"; then
    skip "already-cut-over ($MARKER_KEY=1 and live scope carries setScope) — nothing to do"
    return 0
  fi
  if scope_is_account_auth "$SCOPE_ADDR" && [ "$FORCE_CUTOVER" != "1" ]; then
    ok "live scope already account-auth; setting $MARKER_KEY (no redeploy needed)"
    env_set "$MARKER_KEY" 1
    return 0
  fi
  if [ "$ASSUME_YES" != "1" ]; then
    printf '\n  ⚠️  DESTRUCTIVE: this redeploys registry/scope/epoch/audit to NEW addresses and\n' >&2
    printf '     RESETS all on-chain state (master, agents, scopes, audit). Re-run with --yes\n' >&2
    printf '     to proceed after you have announced + scheduled the cutover.\n\n' >&2
    die "refusing to redeploy without --yes"
  fi
  step "  → FORCE_DEPLOY=1 heima-bring-up.sh"
  FORCE_DEPLOY=1 AGENTKEYS_CHAIN="$CHAIN" ENV_FILE="$ENV_FILE" bash "$REPO_ROOT/scripts/heima-bring-up.sh" \
    || die "heima-bring-up.sh (FORCE_DEPLOY) failed"
  # Re-source to pick up the freshly env_set addresses, then verify the new scope.
  set -a; . "$ENV_FILE"; set +a
  SCOPE_ADDR="$(eval echo "\${SCOPE_CONTRACT_ADDRESS_${PROFILE_UC}:-}")"
  if scope_is_account_auth "$SCOPE_ADDR"; then
    env_set "$MARKER_KEY" 1
    ok "redeploy verified — new scope $SCOPE_ADDR carries setScope; $MARKER_KEY=1"
  else
    die "post-redeploy probe failed — new scope $SCOPE_ADDR lacks the setScope selector"
  fi
}

# ─── Phase 2 — factory check (E5 recover() is NOT needed for accept) ─────────────
phase2() {
  step "Phase 2 — P256AccountFactory check"
  local factory; factory="$(eval echo "\${P256_ACCOUNT_FACTORY_ADDRESS_${PROFILE_UC}:-}")"
  if [ -z "$factory" ]; then
    skip "no factory address in env — the 4337 infra (E1) is deployed separately; not required for the accept batch"
    return 0
  fi
  local code; code="$(cast code "$factory" --rpc-url "$RPC_HTTP" 2>/dev/null || echo 0x)"
  if [ "$code" != "0x" ] && [ -n "$code" ]; then
    ok "factory live at $factory (accept needs no factory change; E5 recover() redeploy is a separate, manual guardian-recovery concern)"
  else
    skip "factory $factory has no code — redeploy is a separate E1 step, not part of this cutover"
  fi
}

phase0
phase1
phase2

step "Cutover chain steps done — required follow-ups (separate idempotent helpers):"
cat >&2 <<'NEXT'
    3. Re-register master-as-account:  harness/scripts/erc4337-register-master.sh build|submit
    4. Re-bootstrap agents + scopes:   heima-agent-create.sh ; heima-scope-set.sh
    5. Repo edits (commit):            heima-scope-set.sh setScopeWithWebauthn→setScope ; arch.md §10/§12
    6. Broker redeploy (broker host):  bash scripts/setup-broker-host.sh --ref main
NEXT
ok "account-auth cutover orchestrator complete"
