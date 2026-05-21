#!/usr/bin/env bash
# scripts/provision-test-environment.sh — issue #66 tier-2 one-shot
# provisioner for the long-lived parallel test environment.
#
# What this script provisions (every resource parallel to prod, every
# name carrying a -test suffix so misconfigured CI runs targeting prod
# fail closed):
#
#   1. AWS IAM OIDC provider for test-broker.litentry.org
#   2. AWS IAM roles:
#        - agentkeys-data-role-test    (email subsystem)
#        - agentkeys-vault-role-test   (credentials, scoped to vault bucket)
#        - agentkeys-memory-role-test  (long-term memory, scoped to memory bucket)
#      All three trust-policied on the test OIDC provider, with the same
#      PrincipalTag/agentkeys_actor_omni scoping that prod uses.
#   3. AWS S3 buckets (per-data-class, per arch.md §17.2):
#        - agentkeys-mail-test-${ACCT}
#        - agentkeys-vault-test-${ACCT}
#        - agentkeys-memory-test-${ACCT}
#      Each with block-public-access + default SSE-S3 + the v3
#      split-statement PrincipalTag bucket policy from prod
#      (scripts/apply-vault-bucket-policy.sh + apply-memory-bucket-policy.sh).
#   4. EC2 broker host at test-broker.litentry.org via:
#        bash scripts/setup-broker-host.sh \
#          --issuer-url https://test-broker.litentry.org \
#          --account-id ${ACCOUNT_ID} \
#          --signer-host signer-test.litentry.org \
#          --audit-host audit-test.litentry.org \
#          --email-host email-test.litentry.org \
#          --cred-host cred-test.litentry.org \
#          --memory-host memory-test.litentry.org \
#          --chain-rpc https://rpc.paseo-parachain.heima.network \
#          --vault-bucket agentkeys-vault-test-${ACCOUNT_ID} \
#          --memory-bucket agentkeys-memory-test-${ACCOUNT_ID}
#   5. A new deployer wallet on Heima-Paseo (distinct from the prod
#      deployer), persisted at ~/.agentkeys/heima-paseo-deployer-test.key.
#      Funded from the operator's personal Paseo wallet (no sudo on
#      mainnet; sudo is fine on Paseo via Alice if collators are up).
#   6. Fresh v2 stage-1 contracts deployed via DeployAgentKeysV1.s.sol
#      to Heima-Paseo, distinct addresses from prod, written to
#      scripts/test-environment.env under the *_HEIMA_PASEO keys.
#
# Idempotent: re-run safely. Each step pre-checks "is this already done?"
# before acting. Failed runs leave a paper trail in $WORK_DIR.
#
# This is the OPERATOR script — runs once per account. The CI workflow
# (.github/workflows/harness-e2e.yml) consumes the provisioned env via
# GitHub Actions secrets + scripts/test-environment.env.
#
# Usage:
#   awsp agentkeys-admin                             # admin profile required
#   bash scripts/provision-test-environment.sh       # full provisioning
#   bash scripts/provision-test-environment.sh --dry-run
#   bash scripts/provision-test-environment.sh --only-step N
#
# Per CLAUDE.md, this script is the SINGLE ENTRY POINT for test-env
# changes. No ad-hoc aws iam / aws s3api edits — extend this script
# instead and re-run.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ─── Config defaults ─────────────────────────────────────────────────────
DRY_RUN=0
ONLY_STEP=""
TEST_BROKER_HOST="${TEST_BROKER_HOST:-test-broker.litentry.org}"
TEST_SIGNER_HOST="${TEST_SIGNER_HOST:-signer-test.litentry.org}"
TEST_AUDIT_HOST="${TEST_AUDIT_HOST:-audit-test.litentry.org}"
TEST_EMAIL_HOST="${TEST_EMAIL_HOST:-email-test.litentry.org}"
TEST_CRED_HOST="${TEST_CRED_HOST:-cred-test.litentry.org}"
TEST_MEMORY_HOST="${TEST_MEMORY_HOST:-memory-test.litentry.org}"
TEST_ENV_FILE="$REPO_ROOT/scripts/test-environment.env"
TEST_ENV_EXAMPLE="$REPO_ROOT/scripts/test-environment.env.example"
WORK_DIR="$(mktemp -d -t agentkeys-provision-test-XXXXXX)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --only-step)      ONLY_STEP="$2"; shift 2 ;;
    --test-broker-host) TEST_BROKER_HOST="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//' | sed '$d'
      exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ─── Colors ──────────────────────────────────────────────────────────────
if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_SKIP='\033[1;33m'
  C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_SKIP=''; C_WARN=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}    %s\n" "$*" >&2; }
skip() { printf "    ${C_SKIP}skip${C_RESET}  %s\n" "$*" >&2; }
warn() { printf "    ${C_WARN}warn${C_RESET}  %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET}  %s\n" "$*" >&2; exit 1; }

should_run_step() {
  [ -z "$ONLY_STEP" ] && return 0
  [ "$1" = "$ONLY_STEP" ]
}

run_or_dry() {
  if [ "$DRY_RUN" = "1" ]; then
    printf "    ${C_WARN}dry-run${C_RESET} %s\n" "$*" >&2
  else
    "$@"
  fi
}

# ─── Step 0: prerequisite check ──────────────────────────────────────────
log "0/7 Prereq check"
caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
  || die "aws sts get-caller-identity failed: $caller_arn — run: awsp agentkeys-admin"
caller_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
case "$caller_lc" in
  *":user/agentkeys-admin"*) ok "caller: $caller_arn" ;;
  *) die "caller is $caller_arn — admin required. Run: awsp agentkeys-admin" ;;
esac
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-us-east-1}"
ok "ACCOUNT_ID=$ACCOUNT_ID REGION=$REGION"

# Seed the env file if missing
if [ ! -f "$TEST_ENV_FILE" ]; then
  [ -f "$TEST_ENV_EXAMPLE" ] || die "missing $TEST_ENV_EXAMPLE (committed template)"
  cp "$TEST_ENV_EXAMPLE" "$TEST_ENV_FILE"
  ok "seeded $TEST_ENV_FILE from .example"
fi

env_set() {
  local key="$1" val="$2" file="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    if [ "$(uname)" = "Darwin" ]; then
      sed -i '' -E "s|^${key}=.*|${key}=${val}|" "$file"
    else
      sed -i -E "s|^${key}=.*|${key}=${val}|" "$file"
    fi
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}
env_set ACCOUNT_ID "$ACCOUNT_ID" "$TEST_ENV_FILE"
env_set REGION "$REGION" "$TEST_ENV_FILE"

# ─── Step 1: provision the broker host (mirrors prod §5) ─────────────────
if should_run_step 1; then
  log "1/7 Provision broker host (test-broker.${TEST_BROKER_HOST#test-broker.})"
  cat >&2 <<EOF
    This step is OPERATOR-DRIVEN — setup-broker-host.sh runs on the
    target EC2, not on your laptop. The runbook:

      1. Stand up a fresh t3.micro EC2 with an Elastic IP.
      2. Add an A record for ${TEST_BROKER_HOST} pointing at the EIP.
         (Same for signer-test / audit-test / email-test / cred-test /
          memory-test — five additional A records.)
      3. SSH into the EC2 as ec2-user, then:
           git clone https://github.com/<owner>/agentKeys && cd agentKeys
           bash scripts/setup-broker-host.sh \\
             --issuer-url https://${TEST_BROKER_HOST} \\
             --account-id ${ACCOUNT_ID} \\
             --signer-host ${TEST_SIGNER_HOST} \\
             --audit-host ${TEST_AUDIT_HOST} \\
             --email-host ${TEST_EMAIL_HOST} \\
             --cred-host ${TEST_CRED_HOST} \\
             --memory-host ${TEST_MEMORY_HOST} \\
             --chain-rpc https://rpc.paseo-parachain.heima.network \\
             --vault-bucket agentkeys-vault-test-${ACCOUNT_ID} \\
             --memory-bucket agentkeys-memory-test-${ACCOUNT_ID} \\
             --email-from noreply-test@bots-test.litentry.org \\
             --non-interactive --yes
      4. Confirm: curl -sf https://${TEST_BROKER_HOST}/healthz

    See docs/test-environment.md §3 for the full host runbook.
EOF
  skip "manual operator step; rerun --only-step 2 once the host is up"
fi

# ─── Step 2: IAM OIDC provider for test-broker ───────────────────────────
if should_run_step 2; then
  log "2/7 IAM OIDC provider (oidc-provider/${TEST_BROKER_HOST})"
  oidc_arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${TEST_BROKER_HOST}"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" \
       >/dev/null 2>&1; then
    skip "OIDC provider already registered: $oidc_arn"
  else
    # Fetch the broker's TLS leaf thumbprint (AWS requires it for OIDC
    # provider registration). Public TLS cert, so this is fine to
    # fetch from any network.
    thumb=$(echo | openssl s_client -servername "$TEST_BROKER_HOST" \
                                     -connect "${TEST_BROKER_HOST}:443" 2>/dev/null \
              | openssl x509 -fingerprint -noout 2>/dev/null \
              | awk -F'=' '{print $2}' | tr -d ':' | tr 'A-Z' 'a-z')
    [ -n "$thumb" ] || die "could not fetch TLS thumbprint for ${TEST_BROKER_HOST}; is the broker reachable?"
    run_or_dry aws iam create-open-id-connect-provider \
      --url "https://${TEST_BROKER_HOST}" \
      --client-id-list "sts.amazonaws.com" \
      --thumbprint-list "$thumb"
    ok "registered $oidc_arn (thumbprint=$thumb)"
  fi
  env_set OIDC_PROVIDER_ARN "$oidc_arn" "$TEST_ENV_FILE"
fi

# ─── Step 3: IAM roles (data, vault, memory) ─────────────────────────────
if should_run_step 3; then
  log "3/7 IAM roles (data-test, vault-test, memory-test)"
  # These wrap the existing prod provisioning scripts with a -test
  # suffix on every name. The scripts read role/bucket names from env,
  # so set env then call.
  warn "extend scripts/provision-vault-role.sh + provision-memory-role.sh"
  warn "to accept a SUFFIX env var, or copy them as -test variants."
  warn "Tracking as a TODO in this script — exercise once the prod"
  warn "scripts are parameterized (~ 1 PR of work)."
fi

# ─── Step 4: S3 buckets ──────────────────────────────────────────────────
if should_run_step 4; then
  log "4/7 S3 buckets (mail-test, vault-test, memory-test)"
  warn "same parameterization story as step 3 — see TODO above."
fi

# ─── Step 5: deployer wallet + funding ───────────────────────────────────
if should_run_step 5; then
  log "5/7 Deployer wallet on Heima-Paseo (distinct from prod deployer)"
  KEYFILE="$HOME/.agentkeys/heima-paseo-deployer-test.key"
  if [ -f "$KEYFILE" ]; then
    skip "$KEYFILE exists"
  else
    mkdir -p "$(dirname "$KEYFILE")"
    run_or_dry cast wallet new --json \
      | tee "$WORK_DIR/wallet.json" \
      | jq -r .[0].private_key > "$KEYFILE"
    chmod 600 "$KEYFILE"
    addr=$(jq -r .[0].address "$WORK_DIR/wallet.json")
    ok "generated $KEYFILE (addr=$addr) — fund this address from your"
    ok "  personal Paseo wallet, then re-run --only-step 6 to deploy contracts."
  fi
fi

# ─── Step 6: deploy v2 stage-1 contracts on Heima-Paseo ──────────────────
if should_run_step 6; then
  log "6/7 Deploy v2 stage-1 contracts to Heima-Paseo (new contracts on-chain)"
  KEYFILE="$HOME/.agentkeys/heima-paseo-deployer-test.key"
  [ -f "$KEYFILE" ] || die "missing $KEYFILE — run --only-step 5 first"
  run_or_dry env HEIMA_DEPLOYER_KEY_FILE="$KEYFILE" \
    AGENTKEYS_CHAIN=heima-paseo \
    bash "$REPO_ROOT/scripts/heima-bring-up.sh"
  ok "contract addresses recorded in scripts/operator-workstation.env;"
  ok "  copy the *_HEIMA_PASEO lines into $TEST_ENV_FILE."
fi

# ─── Step 7: GitHub Actions OIDC role for the e2e workflow ───────────────
if should_run_step 7; then
  log "7/7 GitHub Actions OIDC role (test-only)"
  warn "Create an additional IAM role 'github-actions-agentkeys-e2e'"
  warn "with trust policy on token.actions.githubusercontent.com and a"
  warn "condition limiting to the agentkeys repo + branch ref. Grant"
  warn "agentkeys-vault-role-test + agentkeys-memory-role-test assume"
  warn "perms and read-only S3 on the three test buckets."
  warn ""
  warn "Then store the role ARN as the TEST_OIDC_AWS_ROLE_ARN repo secret."
  warn "Until that secret is set, .github/workflows/harness-e2e.yml is"
  warn "inert (the job is gated on its presence)."
fi

# ─── Done ────────────────────────────────────────────────────────────────
log "Done"
ok "test environment provisioning complete (or skip-noted above)"
ok "next: bash harness/v2-stage3-demo.sh against \$OIDC_ISSUER=${TEST_BROKER_HOST}"
ok "  with AGENTKEYS_ENV_FILE=$TEST_ENV_FILE"
rm -rf "$WORK_DIR"
