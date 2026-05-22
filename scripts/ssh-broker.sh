#!/usr/bin/env bash
# AgentKeys broker SSH — single entry point for prod + test, reading
# INSTANCE_ID / EIP from the corresponding env file so this script
# stays in lockstep with whatever setup-cloud.sh persisted there.
#
# Replaces the per-operator shell aliases:
#   alias ssh-agentkeys='AWS_PROFILE=… aws ec2-instance-connect ssh --instance-id …'
#
# Usage:
#   bash scripts/ssh-broker.sh                  # prod via EC2 Instance Connect
#   bash scripts/ssh-broker.sh test             # test via EC2 Instance Connect
#   bash scripts/ssh-broker.sh prod --fallback  # prod via .pem (when EC2-IC is down)
#   bash scripts/ssh-broker.sh test --fallback  # test via .pem
#   bash scripts/ssh-broker.sh --help
#
# Flags:
#   --fallback           use raw SSH + .pem key instead of EC2 Instance Connect
#   --pem <path>         override .pem key path (default: ~/.ssh/Wildmeta-agent-mac.pem)
#   --os-user <name>     override SSH user (default: agentkey for EC2-IC, ubuntu for fallback)
#   --aws-profile <name> override AWS profile (default per stack — see below)
#
# Default AWS profiles (least-privilege, per CLAUDE.md "AWS local-profile ↔
# remote-IAM mapping"):
#   prod → agentkeys-broker
#   test → agentkeys-broker-test
#
# Suggested shell wrappers (drop in ~/.zshrc):
#   alias ssh-prod='bash $AGENTKEYS_REPO/scripts/ssh-broker.sh prod'
#   alias ssh-test='bash $AGENTKEYS_REPO/scripts/ssh-broker.sh test'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="prod"
FALLBACK=0
PEM_PATH="$HOME/.ssh/Wildmeta-agent-mac.pem"
OS_USER=""
AWS_PROFILE_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    prod|test)        STACK="$1"; shift ;;
    --fallback)       FALLBACK=1; shift ;;
    --pem)            PEM_PATH="$2"; shift 2 ;;
    --os-user)        OS_USER="$2"; shift 2 ;;
    --aws-profile)    AWS_PROFILE_OVERRIDE="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,30p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "Unknown arg: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# Resolve env file + default profile + default OS user per stack.
case "$STACK" in
  prod)
    BROKER_ENV_FILE="$SCRIPT_DIR/broker.env"
    : "${AWS_PROFILE_OVERRIDE:=agentkeys-broker}"
    ;;
  test)
    BROKER_ENV_FILE="$SCRIPT_DIR/broker.test.env"
    : "${AWS_PROFILE_OVERRIDE:=agentkeys-broker-test}"
    ;;
  *) echo "Unknown stack: $STACK" >&2; exit 2 ;;
esac

[ -f "$BROKER_ENV_FILE" ] || { echo "missing $BROKER_ENV_FILE" >&2; exit 1; }

INSTANCE_ID=$(grep '^INSTANCE_ID=' "$BROKER_ENV_FILE" | tail -1 | cut -d= -f2)
EIP=$(        grep '^EIP='         "$BROKER_ENV_FILE" | tail -1 | cut -d= -f2)

[ -n "$INSTANCE_ID" ] || {
  echo "INSTANCE_ID unset in $BROKER_ENV_FILE — paste 'INSTANCE_ID=i-…' once EC2 exists" >&2
  exit 1
}

if [ "$FALLBACK" = "1" ]; then
  [ -n "$EIP" ] || { echo "EIP unset in $BROKER_ENV_FILE — required for --fallback" >&2; exit 1; }
  [ -f "$PEM_PATH" ] || { echo "PEM key not found at $PEM_PATH — pass --pem <path>" >&2; exit 1; }
  : "${OS_USER:=ubuntu}"
  echo "ssh -i $PEM_PATH $OS_USER@$EIP   (stack=$STACK, instance=$INSTANCE_ID)" >&2
  exec ssh -i "$PEM_PATH" "$OS_USER@$EIP"
else
  : "${OS_USER:=agentkey}"
  echo "aws ec2-instance-connect ssh --instance-id $INSTANCE_ID --os-user $OS_USER   (stack=$STACK, profile=$AWS_PROFILE_OVERRIDE)" >&2
  exec env AWS_PROFILE="$AWS_PROFILE_OVERRIDE" \
    aws ec2-instance-connect ssh \
      --instance-id "$INSTANCE_ID" \
      --os-user "$OS_USER"
fi
