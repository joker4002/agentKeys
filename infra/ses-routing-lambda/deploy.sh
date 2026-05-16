#!/usr/bin/env bash
# infra/ses-routing-lambda/deploy.sh — idempotent deployment of the
# SES post-receive routing Lambda (issue #83 follow-up).
#
# What it provisions (all `aws iam` / `aws lambda` / `aws s3api` calls
# pinned to the operator-workstation `agentkeys-admin` profile + the
# region from `scripts/operator-workstation.env`):
#
#   1. IAM role  `agentkeys-ses-router-lambda-role`
#      - trust policy: lambda.amazonaws.com
#      - inline policy: GetObject + CopyObject on the mail bucket,
#        CloudWatch Logs basic
#
#   2. Lambda function `agentkeys-ses-router`
#      - runtime: python3.13, memory: 128 MB, timeout: 10 s
#      - reserved-concurrency: 10
#      - env: empty (handler is stateless)
#      - zip payload built fresh from handler.py
#
#   3. S3 ObjectCreated:* notification on the mail bucket scoped to
#      `inbound/` prefix → invokes the Lambda
#
# Re-running is safe: each create_* call is wrapped in a "does it exist?"
# probe; existing resources are update_*'d. The S3 notification step
# replaces the bucket's NotificationConfiguration **in full** — if you
# add other notifications later, manage them in this script too.
#
# Usage:
#   awsp agentkeys-admin
#   set -a; source scripts/operator-workstation.env; set +a
#   bash infra/ses-routing-lambda/deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${ACCOUNT_ID:?ACCOUNT_ID not set — source scripts/operator-workstation.env first}"
: "${REGION:?REGION not set — source scripts/operator-workstation.env first}"
: "${BUCKET:?BUCKET not set — source scripts/operator-workstation.env first}"

# The deploy needs IAM:CreateRole + Lambda:CreateFunction + S3 bucket
# notification config — only the admin group has all of these. Fail
# fast with a readable message before the first AWS call.
caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)
caller_arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
case "$caller_arn_lc" in
  *user/agentkeys-admin)
    ;;
  *)
    echo "error: deploy.sh requires the admin profile." >&2
    echo "  current caller_arn=$caller_arn" >&2
    echo "  fix: 'awsp agentkeys-admin' (or 'AWS_PROFILE=agentkeys-admin') then re-run." >&2
    exit 1
    ;;
esac

ROLE_NAME="agentkeys-ses-router-lambda-role"
FN_NAME="agentkeys-ses-router"
HANDLER="handler.handler"
RUNTIME="python3.13"
MEMORY_MB=128
TIMEOUT_S=10
RESERVED_CONCURRENCY=10
PAYLOAD_ZIP="/tmp/agentkeys-ses-router-${RANDOM}.zip"

cleanup() { rm -f "$PAYLOAD_ZIP"; }
trap cleanup EXIT

echo "[deploy] account=$ACCOUNT_ID region=$REGION bucket=$BUCKET"

# ── 1. IAM role ─────────────────────────────────────────────────────────────
TRUST_POLICY=$(jq -n '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: {Service: "lambda.amazonaws.com"},
    Action: "sts:AssumeRole"
  }]
}')

if aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "[deploy] role $ROLE_NAME exists — updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY" >/dev/null
else
  echo "[deploy] creating role $ROLE_NAME"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" >/dev/null
fi

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
echo "[deploy] role arn: $ROLE_ARN"

INLINE_POLICY=$(jq -n --arg bucket "$BUCKET" '{
  Version: "2012-10-17",
  Statement: [
    {
      Effect: "Allow",
      Action: ["s3:GetObject"],
      Resource: "arn:aws:s3:::\($bucket)/inbound/*"
    },
    {
      Effect: "Allow",
      Action: ["s3:PutObject"],
      Resource: "arn:aws:s3:::\($bucket)/bots/*/inbound/*"
    },
    {
      Effect: "Allow",
      Action: ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      Resource: "*"
    }
  ]
}')

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${ROLE_NAME}-inline" \
  --policy-document "$INLINE_POLICY" >/dev/null
echo "[deploy] inline policy applied"

# AWS IAM is eventually consistent — give the role 5s to be assumable
# before Lambda tries to attach. Without this the first deploy frequently
# fails with "The role defined for the function cannot be assumed by
# Lambda."
sleep 5

# ── 2. Lambda function ─────────────────────────────────────────────────────
(cd "$SCRIPT_DIR" && zip -j -q "$PAYLOAD_ZIP" handler.py)
echo "[deploy] payload zipped"

if aws lambda get-function --function-name "$FN_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "[deploy] function $FN_NAME exists — updating code + config"
  aws lambda update-function-code \
    --function-name "$FN_NAME" \
    --region "$REGION" \
    --zip-file "fileb://$PAYLOAD_ZIP" >/dev/null
  aws lambda wait function-updated \
    --function-name "$FN_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$FN_NAME" \
    --region "$REGION" \
    --runtime "$RUNTIME" \
    --handler "$HANDLER" \
    --memory-size "$MEMORY_MB" \
    --timeout "$TIMEOUT_S" \
    --role "$ROLE_ARN" >/dev/null
  aws lambda wait function-updated \
    --function-name "$FN_NAME" --region "$REGION"
else
  echo "[deploy] creating function $FN_NAME"
  aws lambda create-function \
    --function-name "$FN_NAME" \
    --region "$REGION" \
    --runtime "$RUNTIME" \
    --role "$ROLE_ARN" \
    --handler "$HANDLER" \
    --memory-size "$MEMORY_MB" \
    --timeout "$TIMEOUT_S" \
    --zip-file "fileb://$PAYLOAD_ZIP" >/dev/null
  aws lambda wait function-active \
    --function-name "$FN_NAME" --region "$REGION"
fi

aws lambda put-function-concurrency \
  --function-name "$FN_NAME" \
  --region "$REGION" \
  --reserved-concurrent-executions "$RESERVED_CONCURRENCY" >/dev/null

FN_ARN=$(aws lambda get-function --function-name "$FN_NAME" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text)
echo "[deploy] function arn: $FN_ARN"

# ── 3. Allow S3 to invoke the function ─────────────────────────────────────
STATEMENT_ID="agentkeys-ses-router-s3-invoke"
aws lambda remove-permission \
  --function-name "$FN_NAME" \
  --region "$REGION" \
  --statement-id "$STATEMENT_ID" >/dev/null 2>&1 || true
aws lambda add-permission \
  --function-name "$FN_NAME" \
  --region "$REGION" \
  --statement-id "$STATEMENT_ID" \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$BUCKET" \
  --source-account "$ACCOUNT_ID" >/dev/null
echo "[deploy] S3 → Lambda invoke permission attached"

# ── 4. S3 bucket notification ──────────────────────────────────────────────
NOTIF=$(jq -n --arg fnArn "$FN_ARN" '{
  LambdaFunctionConfigurations: [{
    Id: "agentkeys-ses-router-inbound",
    LambdaFunctionArn: $fnArn,
    Events: ["s3:ObjectCreated:*"],
    Filter: {Key: {FilterRules: [{Name: "prefix", Value: "inbound/"}]}}
  }]
}')
aws s3api put-bucket-notification-configuration \
  --bucket "$BUCKET" \
  --notification-configuration "$NOTIF"
echo "[deploy] S3 notification on inbound/ → Lambda configured"

echo "[deploy] DONE — function=$FN_NAME role=$ROLE_NAME bucket=$BUCKET"
echo "[deploy] verify: aws s3 cp inbound/test - --bucket $BUCKET; tail Lambda logs"
echo "         aws logs tail /aws/lambda/$FN_NAME --follow --region $REGION"
