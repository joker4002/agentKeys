# Stage 6 demo — source this (don't execute) to set env + mint 1h STS creds.
#
#   source scripts/stage6-demo-env.sh
#
# Prereqs: DAEMON_ACCESS_KEY_ID + DAEMON_SECRET_ACCESS_KEY already in your
# shell (long-lived daemon user keys, stashed in 1Password). Everything else
# is populated here.

: "${DAEMON_ACCESS_KEY_ID:?DAEMON_ACCESS_KEY_ID is empty. Load daemon creds into this shell before sourcing.}"
: "${DAEMON_SECRET_ACCESS_KEY:?DAEMON_SECRET_ACCESS_KEY is empty. Load daemon creds into this shell before sourcing.}"

export REGION=us-east-1
export AWS_REGION="$REGION"
export DOMAIN=bots.litentry.org
export ACCOUNT_ID=429071895007
export BUCKET="agentkeys-mail-${ACCOUNT_ID}"
export AGENTKEYS_EMAIL_BACKEND=ses-s3
export AGENTKEYS_SES_BUCKET="$BUCKET"
export AGENTKEYS_SIGNUP_EMAIL="bot-$(date +%s)@${DOMAIN}"
export AGENTKEYS_SIGNUP_PASSWORD="Stg6-$(date +%s)-xZq9okFg"
export CDP_URL="http://localhost:9222"

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

CREDS=$(AWS_ACCESS_KEY_ID="$DAEMON_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$DAEMON_SECRET_ACCESS_KEY" \
  aws sts assume-role \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-agent" \
    --role-session-name "stage6-demo-$(date +%s)" 2>&1)

if ! echo "$CREDS" | jq -e .Credentials >/dev/null 2>&1; then
  echo "AssumeRole failed:"
  echo "$CREDS"
  return 1 2>/dev/null || exit 1
fi

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')

echo "--- stage 6 demo env loaded ---"
echo "signup email:  $AGENTKEYS_SIGNUP_EMAIL"
echo "bucket:        s3://$BUCKET/"
aws sts get-caller-identity --output text --query 'Arn'
aws s3 ls "s3://$BUCKET/inbound/" >/dev/null && echo "s3 access:     OK" || echo "s3 access:     FAILED"
