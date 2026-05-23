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
    --)               shift; break ;;
    *)                break ;;    # unknown arg → start of remote command passthrough
  esac
done
# Anything left in "$@" is forwarded to the SSH session as the remote
# command — so `ssh-broker.sh test echo hi` runs `echo hi` on the test
# host. Both `aws ec2-instance-connect ssh` and raw `ssh` accept a
# trailing command after their flags.
EXTRA_ARGS=("$@")

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

# Multiplex SSH connections via ControlMaster so subsequent ssh-broker.sh
# invocations within 10 min reuse the already-authenticated socket. The
# first connection still does the full SendSSHPublicKey + key exchange +
# ~5s warmup; every subsequent ssh-agentkeys-test in 10 min completes
# in ~50ms (no AWS API roundtrip, no ssh handshake).
#
# Socket path lives under /tmp (per-operator, per-(user,host,port) via
# the %C hash) so multiple operators on a shared workstation don't collide.
MUX_OPTS=(-o "ControlMaster=auto"
          -o "ControlPath=/tmp/ssh-agentkeys-%C"
          -o "ControlPersist=10m")

if [ "$FALLBACK" = "1" ]; then
  [ -n "$EIP" ] || { echo "EIP unset in $BROKER_ENV_FILE — required for --fallback" >&2; exit 1; }
  [ -f "$PEM_PATH" ] || { echo "PEM key not found at $PEM_PATH — pass --pem <path>" >&2; exit 1; }
  # Default to `ubuntu` — the AMI's default user with the operator's .pem
  # already in authorized_keys. The fallback path is for first-time
  # bootstrap (before setup-broker-host.sh has created the agentkey user)
  # OR for emergency recovery when EC2 Instance Connect is down. Steady-
  # state operator work goes via ssh-agentkeys-test (non-fallback,
  # `agentkey` user) — that's where files land in /home/agentkey/.
  : "${OS_USER:=ubuntu}"
  echo "ssh -i $PEM_PATH $OS_USER@$EIP   (stack=$STACK, instance=$INSTANCE_ID, mux=on)" >&2
  exec ssh -i "$PEM_PATH" "${MUX_OPTS[@]}" "$OS_USER@$EIP" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
else
  : "${OS_USER:=agentkey}"
  # `aws ec2-instance-connect ssh` is a wrapper that doesn't allow
  # passing arbitrary ssh args (no --ssh-options, doesn't honor `--`).
  # That blocks ControlMaster multiplexing. Bypass the wrapper:
  #   1. Generate a stable ephemeral keypair (one-shot per workstation)
  #   2. Push the pubkey via send-ssh-public-key (API call, valid 60s)
  #   3. Raw `ssh -i privkey` with ControlMaster opts to $EIP
  # Once ControlMaster's socket is established, subsequent invocations
  # in 10 min reuse the socket WITHOUT needing a new pubkey push —
  # multiplexed connection, ~50ms latency.
  EIC_KEY="$HOME/.ssh/ec2_instance_connect_id_ed25519"
  if [[ ! -f "$EIC_KEY" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$EIC_KEY" -q -C "ec2-instance-connect ($USER@$HOSTNAME)"
  fi
  [ -n "$EIP" ] || { echo "EIP unset in $BROKER_ENV_FILE — required for direct ssh" >&2; exit 1; }
  echo "send-ssh-public-key + ssh $OS_USER@$EIP   (stack=$STACK, profile=$AWS_PROFILE_OVERRIDE, mux=on)" >&2

  # Skip the API push if ControlMaster socket is already alive — the
  # multiplexed connection doesn't need a fresh ephemeral key. ssh -O
  # check exits 0 if the master is running.
  if ! ssh -O check -o "ControlPath=/tmp/ssh-agentkeys-%C" "$OS_USER@$EIP" 2>/dev/null; then
    AWS_PROFILE="$AWS_PROFILE_OVERRIDE" \
      aws ec2-instance-connect send-ssh-public-key \
        --instance-id "$INSTANCE_ID" \
        --instance-os-user "$OS_USER" \
        --ssh-public-key "file://${EIC_KEY}.pub" \
        >/dev/null \
      || { echo "send-ssh-public-key failed for $INSTANCE_ID os-user=$OS_USER" >&2; exit 1; }
  fi

  exec ssh -i "$EIC_KEY" "${MUX_OPTS[@]}" "$OS_USER@$EIP" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
fi
