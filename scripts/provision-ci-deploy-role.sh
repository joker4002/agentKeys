#!/usr/bin/env bash
# scripts/provision-ci-deploy-role.sh — idempotent creation of the
# `github-actions-agentkeys-deploy` IAM role that lets the no-LLM CI
# workflow drive `setup-broker-host.sh --test --yes` on the test broker
# EC2 via AWS Systems Manager (SSM).
#
# Per arch.md trust posture (issue #101): the role is reachable ONLY
# via GitHub Actions OIDC from the `litentry/agentKeys` repo, and its
# inline policy is scoped to:
#   - `ssm:SendCommand` on document/AWS-RunShellScript + the ONE test
#     broker instance ARN — so even if the role were stolen, the worst
#     it can do is queue a shell command on that single EC2.
#   - `ssm:GetCommandInvocation` + `ssm:ListCommandInvocations` for
#     status polling (no resource scope, read-only).
#   - `ec2:DescribeInstances` so the workflow can sanity-check the
#     instance is reachable before sending the command.
#
# Why a separate role from `github-actions-agentkeys-e2e`:
#   - The e2e role's perms (sts:AssumeRole on test data roles + S3
#     verify) are read/write into the test environment AS the workload.
#   - The deploy role's perms (ssm:SendCommand on the broker EC2) are
#     control-plane: it tells the EC2 to re-deploy the broker binary.
#   - Separation of duties: a compromise of CI's e2e creds cannot
#     trigger a broker re-deploy, and vice versa.
#
# Out of scope (stays manual per CLAUDE.md "Remote broker host (single
# entry point)" + "Idempotent remote-setup rule (CLOUD)"):
#   - The PROD broker EC2 (broker.litentry.org) — no auto-deploy ever.
#   - The Heima EVM PROD contract redeploy — never automatic.
#
# Required env (sourced from $ENV_FILE):
#   - ACCOUNT_ID
#   - REGION
# Required CLI flags:
#   - --test-broker-instance-id i-xxxxxxxxx (the EC2 hosting the test broker)
# Optional CLI flags:
#   - --repo litentry/agentKeys (default; pinned in OIDC sub condition)
#   - --role-name github-actions-agentkeys-deploy (default)
#   - --env-file scripts/operator-workstation.test.env (default)
#   - --fix-ssm  Auto-attach AmazonSSMManagedInstanceCore to the broker EC2's
#                instance profile role if the SSM agent is offline, then poll
#                for up to 3 min waiting for the agent to refresh creds.
#                Safe to pass on every run (idempotent: aws iam attach-role-policy
#                no-ops on re-attach, and the auto-attach is gated on PingStatus
#                != Online so a healthy EC2 is untouched).
#   - --dry-run (print planned changes; no AWS calls that mutate state)
#
# Required AWS profile: agentkeys-admin (the script checks caller ARN).
#
# Outcomes per step (matches the idempotent-remote-setup rule shape):
#   - `ok proceeding` → mutation applied
#   - `skip <reason>` → no-op (e.g. role already present + trust matches)
#   - `fail <reason>` → hard error, exit non-zero

set -euo pipefail

# ─── CLI parse ────────────────────────────────────────────────────────────────
DRY_RUN=0
FIX_SSM=0
TEST_BROKER_INSTANCE_ID=""
REPO_SLUG="litentry/agentKeys"
ROLE_NAME="github-actions-agentkeys-deploy"
SSM_POLICY_NAME="agentkeys-ci-deploy-ssm"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.test.env}"

while [ $# -gt 0 ]; do
  case "$1" in
    --test-broker-instance-id) TEST_BROKER_INSTANCE_ID="$2"; shift 2 ;;
    --repo)                    REPO_SLUG="$2"; shift 2 ;;
    --role-name)               ROLE_NAME="$2"; shift 2 ;;
    --env-file)                ENV_FILE="$2"; shift 2 ;;
    --fix-ssm)                 FIX_SSM=1; shift ;;
    --dry-run)                 DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "unknown flag: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# ─── Logging primitives (mirrors provision-vault-role.sh) ─────────────────────
if [ -t 2 ]; then
  C_HEAD='\033[1;36m'; C_OK='\033[1;32m'; C_SKIP='\033[1;33m'
  C_WARN='\033[1;33m'; C_ERR='\033[1;31m'; C_RESET='\033[0m'
else
  C_HEAD=''; C_OK=''; C_SKIP=''; C_WARN=''; C_ERR=''; C_RESET=''
fi
log()  { printf "${C_HEAD}==>${C_RESET} %s\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok${C_RESET}   %s\n" "$*" >&2; }
skip() { printf "    ${C_SKIP}skip${C_RESET} %s\n" "$*" >&2; }
warn() { printf "    ${C_WARN}warn${C_RESET} %s\n" "$*" >&2; }
die()  { printf "    ${C_ERR}fail${C_RESET} %s\n" "$*" >&2; exit 1; }

# ─── Preconditions ────────────────────────────────────────────────────────────
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE (pass --env-file <path> to override)"
set -a; . "$ENV_FILE"; set +a

ACCOUNT_ID="${ACCOUNT_ID:?ACCOUNT_ID required in $ENV_FILE}"
REGION="${REGION:?REGION required in $ENV_FILE}"

[ -n "$TEST_BROKER_INSTANCE_ID" ] \
  || die "missing --test-broker-instance-id (look up via: aws ec2 describe-instances --region $REGION --filters 'Name=tag:Name,Values=agentkeys-test-broker' --query 'Reservations[0].Instances[0].InstanceId')"

[[ "$TEST_BROKER_INSTANCE_ID" =~ ^i-[0-9a-f]{8,17}$ ]] \
  || die "instance ID shape invalid: $TEST_BROKER_INSTANCE_ID (expected i-<8-17 hex chars>)"

[[ "$REPO_SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
  || die "repo slug shape invalid: $REPO_SLUG (expected owner/repo)"

command -v jq >/dev/null  || die "jq not found in PATH (brew install jq)"
command -v aws >/dev/null || die "aws CLI not found in PATH"

# Caller identity must be agentkeys-admin (matches the rest of the provision-*
# scripts; lowercase compare because the live IAM user is `agentKeys-admin`).
caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
  || die "aws sts get-caller-identity failed: $caller_arn"
arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
case "$arn_lc" in
  *":user/agentkeys-admin"*) ok "caller is admin: $caller_arn" ;;
  *) die "caller is $caller_arn — needs agentkeys-admin (try: awsp agentkeys-admin)" ;;
esac

# ─── Step 1: ensure the GitHub Actions OIDC provider exists in the account ───
log "OIDC provider: token.actions.githubusercontent.com"
gha_provider_arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$gha_provider_arn" >/dev/null 2>&1; then
  skip "GHA OIDC provider already registered"
else
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — would create-open-id-connect-provider for token.actions.githubusercontent.com"
  else
    # Thumbprint per GitHub's published cert (matches docs/ci-setup.md §4 note).
    # If the cert chain rolls, this needs a refresh; AWS rejects mismatches.
    aws iam create-open-id-connect-provider \
      --url https://token.actions.githubusercontent.com \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
      >/dev/null \
      || die "create-open-id-connect-provider failed"
    ok "GHA OIDC provider registered"
  fi
fi

# ─── Step 2: trust policy ─────────────────────────────────────────────────────
# Federated on the GHA OIDC provider, scoped to the litentry/agentKeys repo.
# `StringLike` on `sub` lets PR branches AND `refs/heads/*` push events
# trigger; the workflow itself is the second gate (path filter + concurrency).
#
# To tighten further later (e.g. main-branch-only deploys), change the StringLike
# pattern to `repo:litentry/agentKeys:ref:refs/heads/evm` or similar.
trust_policy=$(jq -n \
  --arg provider "$gha_provider_arn" \
  --arg sub_pattern "repo:${REPO_SLUG}:*" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Federated: $provider },
      Action: "sts:AssumeRoleWithWebIdentity",
      Condition: {
        StringEquals: {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        StringLike: {
          "token.actions.githubusercontent.com:sub": $sub_pattern
        }
      }
    }]
  }')

# ─── Step 3: role existence ──────────────────────────────────────────────────
log "Role existence: $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  skip "role already exists"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — would update-assume-role-policy with: $trust_policy"
  else
    log "Refreshing trust policy (idempotent — overwrites with $sub_pattern shape)"
    aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document "$trust_policy" \
      || die "update-assume-role-policy failed"
    ok "trust policy refreshed"
  fi
else
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — would create-role $ROLE_NAME with trust: $trust_policy"
  else
    log "Creating role $ROLE_NAME"
    # IAM CreateRole --description allows only printable ASCII + Latin-1
    # (regex [\t\n\r\x20-\x7e\xa1-\xff]*). Em-dash / en-dash / arrows trip
    # "Value at 'description' failed to satisfy constraint" at AWS-call time.
    # Keep this string ASCII-only.
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "$trust_policy" \
      --description "CI deploy role - drives setup-broker-host.sh on the test EC2 via SSM (issue #101)" \
      >/dev/null \
      || die "create-role failed"
    ok "role created"
  fi
fi

# ─── Step 4: inline SSM policy ───────────────────────────────────────────────
# Narrow on purpose: SendCommand limited to the document + the ONE instance
# ARN. Even a compromised role can only re-run setup-broker-host.sh on the
# test broker; nothing in prod, nothing on other EC2s.
instance_arn="arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${TEST_BROKER_INSTANCE_ID}"
ssm_document_arn="arn:aws:ssm:${REGION}::document/AWS-RunShellScript"

inline_policy=$(jq -n \
  --arg doc_arn "$ssm_document_arn" \
  --arg inst_arn "$instance_arn" \
  --arg inst_id  "$TEST_BROKER_INSTANCE_ID" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "SendShellCommandToTestBrokerOnly",
        Effect: "Allow",
        Action: "ssm:SendCommand",
        Resource: [$doc_arn, $inst_arn]
      },
      {
        Sid: "PollCommandStatus",
        Effect: "Allow",
        Action: [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations"
        ],
        Resource: "*"
      },
      {
        Sid: "DescribeTestBrokerInstanceOnly",
        Effect: "Allow",
        Action: "ec2:DescribeInstances",
        Resource: "*",
        Condition: {
          StringEquals: {
            "ec2:InstanceId": [$inst_id]
          }
        }
      }
    ]
  }')

log "Inline policy: $SSM_POLICY_NAME"
if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would put-role-policy: $inline_policy"
else
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$SSM_POLICY_NAME" \
    --policy-document "$inline_policy" \
    || die "put-role-policy failed"
  ok "inline policy applied ($(echo "$inline_policy" | jq '.Statement | length') statements; SendCommand scoped to $TEST_BROKER_INSTANCE_ID)"
fi

# ─── Step 5: verify the test broker EC2 is SSM-managed ───────────────────────
# If the instance lacks AmazonSSMManagedInstanceCore (via its instance profile)
# OR the SSM Agent isn't running, SendCommand will queue the command and time
# out without delivering it. Fail fast here with a clear remediation path.
#
# With --fix-ssm, the script attempts auto-remediation:
#   - Looks up the EC2's instance profile via DescribeInstances
#   - Extracts the role name behind the profile
#   - Attaches AmazonSSMManagedInstanceCore (idempotent: AWS no-ops on re-attach)
#   - Re-polls PingStatus for up to 3 min waiting for the agent to refresh creds
#   - If still offline after 3 min: tells operator to reboot or restart the agent
#
# The auto-attach is safe because the operator is already running as
# agentkeys-admin (verified above) — they HAVE iam:AttachRolePolicy. Without
# --fix-ssm the script just reports + exits (no IAM mutation, no surprises).
attach_ssm_managed_policy_if_missing() {
  # Returns 0 if policy was attached or already present; non-zero on hard error.
  local instance_id="$1"
  local profile_arn role_name policy_arn already_attached

  policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

  profile_arn=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
    --output text 2>/dev/null || echo "None")

  if [ -z "$profile_arn" ] || [ "$profile_arn" = "None" ] || [ "$profile_arn" = "null" ]; then
    warn "instance $instance_id has NO IAM instance profile attached — auto-remediation is blocked."
    warn "Fix: associate an instance profile via:"
    warn "  aws ec2 associate-iam-instance-profile --instance-id $instance_id \\"
    warn "    --iam-instance-profile Name=<existing-profile-name> --region $REGION"
    warn "Then re-run this script with --fix-ssm."
    return 1
  fi

  # Profile ARN shape: arn:aws:iam::ACCT:instance-profile/<NAME>
  local profile_name="${profile_arn##*/}"
  log "instance profile: $profile_name"

  role_name=$(aws iam get-instance-profile \
    --instance-profile-name "$profile_name" \
    --query 'InstanceProfile.Roles[0].RoleName' \
    --output text 2>/dev/null || echo "None")

  if [ -z "$role_name" ] || [ "$role_name" = "None" ]; then
    warn "instance profile $profile_name has no role attached — auto-remediation is blocked."
    return 1
  fi
  log "role behind profile: $role_name"

  already_attached=$(aws iam list-attached-role-policies \
    --role-name "$role_name" \
    --query "AttachedPolicies[?PolicyArn=='$policy_arn'].PolicyArn" \
    --output text 2>/dev/null || echo "")

  if [ -n "$already_attached" ]; then
    ok "AmazonSSMManagedInstanceCore already attached to $role_name"
    return 0
  fi

  log "Attaching AmazonSSMManagedInstanceCore to $role_name"
  aws iam attach-role-policy \
    --role-name "$role_name" \
    --policy-arn "$policy_arn" \
    || { warn "attach-role-policy failed"; return 1; }
  ok "AmazonSSMManagedInstanceCore attached to $role_name"
  return 0
}

poll_ssm_online() {
  local instance_id="$1" max_iters="$2" state
  for _ in $(seq 1 "$max_iters"); do
    state=$(aws ssm describe-instance-information \
      --region "$REGION" \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo "None")
    case "$state" in
      Online) printf '%s' "$state"; return 0 ;;
    esac
    sleep 10
  done
  printf '%s' "${state:-None}"
  return 1
}

log "Verify SSM agent reachable: $TEST_BROKER_INSTANCE_ID"
if [ "$DRY_RUN" = "1" ]; then
  log "DRY RUN — would query ssm describe-instance-information for $TEST_BROKER_INSTANCE_ID"
else
  ssm_state=$(aws ssm describe-instance-information \
    --region "$REGION" \
    --filters "Key=InstanceIds,Values=$TEST_BROKER_INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "None")

  case "$ssm_state" in
    Online)
      ok "SSM agent online — workflow can SendCommand"
      ;;
    ConnectionLost|Inactive|None|"")
      if [ "$FIX_SSM" = "1" ]; then
        log "Auto-remediating (--fix-ssm): attach AmazonSSMManagedInstanceCore + poll"
        if attach_ssm_managed_policy_if_missing "$TEST_BROKER_INSTANCE_ID"; then
          log "Polling SSM PingStatus for up to 3 min (agent refresh window)"
          final_state=$(poll_ssm_online "$TEST_BROKER_INSTANCE_ID" 18) || true
          if [ "$final_state" = "Online" ]; then
            ok "SSM agent now online"
          else
            warn "SSM agent still $final_state after 3 min — policy attached, but the"
            warn "agent process hasn't picked up the refreshed creds. Pick ONE:"
            warn "  a) SSH and bounce the agent:"
            warn "     ssh test-broker 'sudo systemctl restart amazon-ssm-agent'"
            warn "  b) Reboot the EC2 (heavier):"
            warn "     aws ec2 reboot-instances --instance-ids $TEST_BROKER_INSTANCE_ID --region $REGION"
            warn "Then re-run this script (no flags) to confirm Online."
            exit 1
          fi
        else
          exit 1
        fi
      else
        die "$TEST_BROKER_INSTANCE_ID is not registered with SSM (state=$ssm_state). Re-run with --fix-ssm
to attempt auto-remediation (attaches AmazonSSMManagedInstanceCore to the
EC2's instance profile role, then polls until the SSM agent refreshes).
Or remediate manually:
  1. EC2 instance profile is missing AmazonSSMManagedInstanceCore. Fix:
       aws ec2 describe-instances --region $REGION --instance-ids $TEST_BROKER_INSTANCE_ID \\
         --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'
     Then attach the policy to the role behind that instance profile:
       aws iam attach-role-policy --role-name <role-from-above> \\
         --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
     Reboot the EC2 (or restart amazon-ssm-agent) to pick up new perms.
  2. SSM Agent not installed/running. Fix (Ubuntu 22.04+ ships it):
       ssh test-broker 'sudo systemctl enable --now amazon-ssm-agent'
  3. Instance is in a private VPC subnet without an SSM VPC endpoint.
     (Unlikely for a public-IP broker, but worth a glance at the routing.)"
      fi
      ;;
    *)
      warn "SSM agent state = $ssm_state (unexpected) — proceed with caution"
      ;;
  esac
fi

# ─── Final: print the ARN so the operator can paste it into the GHA secret ──
role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || echo "?")
ok "deploy role ready: $role_arn"
cat <<EOF >&2

Next:
  # 1. Set the two GitHub secrets (idempotent — overwrites existing values):
  gh secret set OIDC_AWS_ROLE_ARN_DEPLOY --repo $REPO_SLUG --body "$role_arn"
  gh secret set TEST_BROKER_INSTANCE_ID  --repo $REPO_SLUG --body "$TEST_BROKER_INSTANCE_ID"

  # 2. Trigger a workflow_dispatch with broker_changed=true to dry-run the
  #    deploy path on the test EC2 (see docs/ci-setup.md §7).

EOF

echo "$role_arn"
