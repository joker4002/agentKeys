#!/usr/bin/env bash
# Sync the TEST_* GitHub Actions repo secrets for harness-ci.yml from the
# operator's local state (operator-workstation.test.env + the test deployer
# key file). One-shot replacement for clicking through 17 New-secret forms.
#
# Usage:
#   bash scripts/ci-set-github-secrets.sh                          # uses defaults
#   bash scripts/ci-set-github-secrets.sh --dry-run                # preview only
#   bash scripts/ci-set-github-secrets.sh --repo litentry/agentKeys
#   bash scripts/ci-set-github-secrets.sh --env-file scripts/operator-workstation.test.env \
#                                          --deployer-key-file ~/.agentkeys/heima-deployer-test.key \
#                                          --oidc-role-arn arn:aws:iam::123:role/github-actions-agentkeys-e2e
#
# Prereqs:
#   - `gh auth status` shows you authenticated for the target repo
#   - operator-workstation.test.env has the TEST_*_HEIMA contract addresses
#     persisted (run setup-heima.sh --test --from-step 4 --to-step 8 first)
#   - ~/.agentkeys/heima-deployer-test.key exists with the 0x-prefixed key
#   - ci-setup.md §4 has been completed (the github-actions-agentkeys-e2e
#     IAM role exists; otherwise the workflow will fail at AssumeRoleWithWebIdentity)
#
# Idempotent: `gh secret set` overwrites existing values without prompting.
# Sets TEST_OIDC_AWS_ROLE_ARN LAST per ci-setup.md (it's the gate that
# activates the workflow).
#
# Disarm later with: gh secret delete TEST_OIDC_AWS_ROLE_ARN --repo <repo>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-litentry/agentKeys}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/operator-workstation.test.env}"
DEPLOYER_KEY_FILE="${DEPLOYER_KEY_FILE:-$HOME/.agentkeys/heima-deployer-test.key}"
OIDC_ROLE_ARN_OVERRIDE="${TEST_OIDC_AWS_ROLE_ARN:-}"
DRY_RUN=0
SKIP_GATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)              REPO="$2"; shift 2 ;;
    --env-file)          ENV_FILE="$2"; shift 2 ;;
    --deployer-key-file) DEPLOYER_KEY_FILE="$2"; shift 2 ;;
    --oidc-role-arn)     OIDC_ROLE_ARN_OVERRIDE="$2"; shift 2 ;;
    --skip-gate)         SKIP_GATE=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || {
  echo "gh CLI not found — install: brew install gh && gh auth login" >&2; exit 1
}
[ -f "$ENV_FILE" ] || { echo "missing env file: $ENV_FILE" >&2; exit 1; }
[ -f "$DEPLOYER_KEY_FILE" ] || { echo "missing deployer key file: $DEPLOYER_KEY_FILE" >&2; exit 1; }

if [ "$DRY_RUN" = "0" ]; then
  gh auth status >/dev/null 2>&1 || {
    echo "gh not authenticated — run: gh auth login" >&2; exit 1
  }
  gh repo view "$REPO" >/dev/null 2>&1 || {
    echo "cannot reach $REPO via gh (wrong account / repo doesn't exist / no perms)" >&2; exit 1
  }
fi

set -a; . "$ENV_FILE"; set +a

: "${ACCOUNT_ID:?ACCOUNT_ID missing from $ENV_FILE}"
: "${REGION:?REGION missing from $ENV_FILE}"
: "${BROKER_HOST:?BROKER_HOST missing from $ENV_FILE}"
: "${VAULT_BUCKET:?VAULT_BUCKET missing from $ENV_FILE}"
: "${MEMORY_BUCKET:?MEMORY_BUCKET missing from $ENV_FILE}"
: "${VAULT_ROLE_ARN:?VAULT_ROLE_ARN missing from $ENV_FILE}"
: "${MEMORY_ROLE_ARN:?MEMORY_ROLE_ARN missing from $ENV_FILE}"
: "${DATA_ROLE_ARN:?DATA_ROLE_ARN missing from $ENV_FILE}"

# Sanity-check: contract addresses must be non-zero (otherwise setup-heima.sh
# step 6 hasn't deployed yet, and the secrets would be useless to the runner).
for var in SCOPE_CONTRACT_ADDRESS_HEIMA SIDECAR_REGISTRY_ADDRESS_HEIMA \
           K3_EPOCH_COUNTER_ADDRESS_HEIMA CREDENTIAL_AUDIT_ADDRESS_HEIMA \
           P256_VERIFIER_ADDRESS_HEIMA K11_VERIFIER_ADDRESS_HEIMA; do
  val="${!var:-}"
  if [ -z "$val" ] || [ "$val" = "0x0000000000000000000000000000000000000000" ]; then
    echo "fail $var is unset/zero in $ENV_FILE — run setup-heima.sh --test --from-step 4 --to-step 8 first" >&2
    exit 1
  fi
done

DEPLOYER_KEY=$(tr -d '\r\n[:space:]' < "$DEPLOYER_KEY_FILE")
[[ "$DEPLOYER_KEY" =~ ^0x[0-9a-fA-F]{64}$ ]] || {
  echo "deployer key file content invalid (expected 0x<64hex>)" >&2; exit 1
}

# Derive default OIDC role ARN if not overridden
OIDC_ROLE_ARN="${OIDC_ROLE_ARN_OVERRIDE:-arn:aws:iam::${ACCOUNT_ID}:role/github-actions-agentkeys-e2e}"

set_secret() {
  local name="$1" value="$2" mask="${3:-no}"
  local preview
  if [ "$mask" = "yes" ]; then
    preview="${value:0:6}…(redacted)"
  else
    preview="$value"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '  DRY  %-46s = %s\n' "$name" "$preview"
    return
  fi
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO" --body - >/dev/null
  printf '  ok   %-46s   %s\n' "$name" "$preview"
}

echo "=== Setting TEST_* repo secrets in $REPO ==="
echo "    env-file:     $ENV_FILE"
echo "    deployer-key: $DEPLOYER_KEY_FILE"
[ "$DRY_RUN" = "1" ] && echo "    DRY-RUN MODE (no gh calls)"
echo

set_secret TEST_ACCOUNT_ID                          "$ACCOUNT_ID"
set_secret TEST_AWS_REGION                          "$REGION"
set_secret TEST_BROKER_HOST                         "$BROKER_HOST"
set_secret TEST_VAULT_BUCKET                        "$VAULT_BUCKET"
set_secret TEST_MEMORY_BUCKET                       "$MEMORY_BUCKET"
set_secret TEST_VAULT_ROLE_ARN                      "$VAULT_ROLE_ARN"
set_secret TEST_MEMORY_ROLE_ARN                     "$MEMORY_ROLE_ARN"
set_secret TEST_DATA_ROLE_ARN                       "$DATA_ROLE_ARN"
set_secret TEST_HEIMA_DEPLOYER_KEY                  "$DEPLOYER_KEY"                       yes
set_secret TEST_SCOPE_CONTRACT_ADDRESS_HEIMA        "$SCOPE_CONTRACT_ADDRESS_HEIMA"
set_secret TEST_SIDECAR_REGISTRY_ADDRESS_HEIMA      "$SIDECAR_REGISTRY_ADDRESS_HEIMA"
set_secret TEST_K3_EPOCH_COUNTER_ADDRESS_HEIMA      "$K3_EPOCH_COUNTER_ADDRESS_HEIMA"
set_secret TEST_CREDENTIAL_AUDIT_ADDRESS_HEIMA      "$CREDENTIAL_AUDIT_ADDRESS_HEIMA"
set_secret TEST_P256_VERIFIER_ADDRESS_HEIMA         "$P256_VERIFIER_ADDRESS_HEIMA"
set_secret TEST_K11_VERIFIER_ADDRESS_HEIMA          "$K11_VERIFIER_ADDRESS_HEIMA"

# Gate is set LAST per ci-setup.md §5 — its presence activates harness-e2e
if [ "$SKIP_GATE" = "1" ]; then
  echo
  echo "skip TEST_OIDC_AWS_ROLE_ARN (--skip-gate). Workflow stays GATED OFF."
  echo "     activate later with:"
  echo "       gh secret set TEST_OIDC_AWS_ROLE_ARN --repo $REPO --body '$OIDC_ROLE_ARN'"
else
  set_secret TEST_OIDC_AWS_ROLE_ARN "$OIDC_ROLE_ARN"
fi

echo
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY-RUN complete — no changes made. Re-run without --dry-run to apply."
else
  echo "Done. Verify: gh secret list --repo $REPO | grep TEST_"
fi
