#!/usr/bin/env bash
# Upsert Route 53 A records for the 6 co-located service workers
# (audit / email / cred / memory / config / classify) — issue #90 + #201 + #207.
#
# All these workers live on the same EC2 box as the broker today (dev-only
# co-location per CLAUDE.md "for production, we will isolate all the
# services"). DNS layout matches the signer pattern (cloud-setup.md §6.1):
# one A record per hostname, all pointing to the broker's EIP.
#
# Idempotent: UPSERT replaces if exists, creates if not. Safe to re-run.
#
# Usage:
#   bash scripts/dns-upsert-workers.sh                 # PROD: EIP from tag Name=agentkeys-broker-eip
#   bash scripts/dns-upsert-workers.sh --test          # CI/test: tag Name=agentkeys-broker-eip-test
#   bash scripts/dns-upsert-workers.sh --eip 1.2.3.4   # use a known EIP (skips the tag lookup)
#   bash scripts/dns-upsert-workers.sh --dry-run       # print the change-batch only
#   bash scripts/dns-upsert-workers.sh --no-verify     # UPSERT + exit (no INSYNC/DoH
#                                                      # wait) — setup-cloud.sh uses this
#
# Prereqs (validated up front):
#   • awsp agentkeys-admin   # account-owner profile (Route 53 + EC2 read)
#   • scripts/operator-workstation.env sourced
#   • $PARENT_ZONE_ID env var OR --zone-id flag (default: litentry.org zone)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
EIP=""
DRY_RUN=false
NO_VERIFY=false   # --no-verify: UPSERT then exit (skip INSYNC/DoH wait + printout);
                  # used when setup-cloud.sh delegates here (parity with its other DNS).
ZONE_ID="${PARENT_ZONE_ID:-Z09723983CFJOHAE3VC65}"   # litentry.org zone
TTL=300
TEST_MODE=0       # --test (or a *test* ENV_FILE) → target the CI/test broker's EIP

# ─── CLI parse ────────────────────────────────────────────────────────────────
while (( $# > 0 )); do
  case "$1" in
    --eip)       EIP="$2"; shift 2 ;;
    --zone-id)   ZONE_ID="$2"; shift 2 ;;
    --ttl)       TTL="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --no-verify) NO_VERIFY=true; shift ;;
    --ci|--test) TEST_MODE=1; shift ;;   # --ci = canonical CI-env flag; --test retained as alias
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ─── Pre-flight ───────────────────────────────────────────────────────────────
have aws  || die "aws CLI not found"
have jq   || die "jq not found"
have curl || die "curl not found"

# Source operator-workstation.env (or .test.env under --test) to populate $REGION
# + $WORKER_*_HOST + $BROKER_HOST. Prod and the CI/test broker are SEPARATE
# machines with SEPARATE EIPs — the env file + the EIP tag carry the prod/test split.
ENV_FILE="${ENV_FILE:-$REPO_ROOT/scripts/operator-workstation.env}"
if [[ "$TEST_MODE" == "1" && "$ENV_FILE" == "$REPO_ROOT/scripts/operator-workstation.env" ]]; then
  ENV_FILE="$REPO_ROOT/scripts/operator-workstation.test.env"
fi
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found — run from a clone of agentKeys"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
# Auto-detect test mode from the env-file name (so ENV_FILE=…test.env works without
# --test), mirroring setup-cloud.sh. Then pick the broker's EIP tag for this env.
case "$ENV_FILE" in *test*) TEST_MODE=1 ;; esac
EIP_TAG="agentkeys-broker-eip"; ENV_LABEL=prod
[[ "$TEST_MODE" == "1" ]] && { EIP_TAG="agentkeys-broker-eip-test"; ENV_LABEL=test; }

# Caller must be on the admin profile (Route 53 lives in the account-owner profile).
# Match case-insensitively per CLAUDE.md (agentKeys-admin vs agentkeys-admin).
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
CALLER_LC="$(printf '%s' "$CALLER_ARN" | tr '[:upper:]' '[:lower:]')"
case "$CALLER_LC" in
  *user/agentkeys-admin*) ;;
  *) die "current AWS caller is $CALLER_ARN — switch to agentkeys-admin first:\n   awsp agentkeys-admin" ;;
esac

# Defense: refuse a wildcard or sentinel-zero EIP.
validate_eip() {
  local ip="$1"
  [[ -n "$ip" ]] || die "EIP is empty"
  # Reject RFC1918 / TEST-NET-2 / CGNAT — these all silently break Let's Encrypt.
  case "$ip" in
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) die "EIP $ip is RFC1918 (private) — refusing" ;;
    198.18.*|198.19.*)                                    die "EIP $ip is TEST-NET-2 (VPN-rewritten) — likely your local resolver lying through Cloudflare WARP / Zscaler. Re-derive from AWS, not dig." ;;
    100.64.*|100.6[5-9].*|100.[7-9]?.*|100.1[01]?.*|100.12[0-7].*) die "EIP $ip is CGNAT — refusing" ;;
    0.0.0.0|255.255.255.255)                              die "EIP $ip is a sentinel — refusing" ;;
  esac
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "EIP $ip doesn't look like an IPv4"
}

# Derive the workers' EIP from the broker's EIP TAG when --eip isn't passed — the
# SAME mechanism + tag values as setup-cloud.sh step 4 (one source of truth). Prod
# and the CI/test broker are SEPARATE machines with SEPARATE EIPs:
#   prod → Name=agentkeys-broker-eip        (ENV_LABEL=prod)
#   test → Name=agentkeys-broker-eip-test   (ENV_LABEL=test; --test / *test* ENV_FILE)
# The old `describe-addresses | first` could NOT tell them apart and silently
# grabbed the TEST EIP, pointing all 5 worker records at the test broker while
# broker/signer stayed on prod — a multi-round cert-issuance failure. NEVER derive
# from `dig` (the local resolver lies behind a VPN — signer §6.1).
: "${BROKER_HOST:?BROKER_HOST not set — source operator-workstation.env (or pass --eip)}"
if [[ -z "$EIP" ]]; then
  log "Deriving $ENV_LABEL EIP from tag Name=$EIP_TAG (region $REGION)"
  EIP="$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Name,Values=$EIP_TAG" \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null)"
  [[ -n "$EIP" && "$EIP" != "None" ]] \
    || die "no EIP tagged Name=$EIP_TAG in $REGION — allocate it (setup-cloud.sh step 4, add --test for the CI broker) or pass --eip explicitly"
  log "  $EIP_TAG → $EIP  (the 5 workers mirror the $ENV_LABEL broker)"
fi
validate_eip "$EIP"

# Co-location cross-check — catches a prod/test mixup. The workers MUST sit on the
# same EIP as the broker today; if the tag-derived (or --eip) value disagrees with
# BROKER_HOST's current A record, warn loudly (not fatal — a future split-host
# topology may legitimately differ, but today co-location holds).
BROKER_A="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${BROKER_HOST}.' && Type=='A'].ResourceRecords[0].Value | [0]" \
  --output text 2>/dev/null || true)"
[[ "$BROKER_A" == "None" ]] && BROKER_A=""
if [[ -n "$BROKER_A" && "$BROKER_A" != "$EIP" ]]; then
  warn "EIP $EIP (tag $EIP_TAG, $ENV_LABEL) != ${BROKER_HOST} A record ($BROKER_A) — workers co-locate with the broker; double-check you're targeting the right environment (prod vs test)."
fi

# Zone sanity-check.
log "Verifying hosted zone $ZONE_ID is reachable"
ZONE_NAME="$(aws route53 get-hosted-zone --id "$ZONE_ID" --query 'HostedZone.Name' --output text 2>/dev/null || true)"
[[ -n "$ZONE_NAME" ]] || die "hosted zone $ZONE_ID not found — pass --zone-id or export PARENT_ZONE_ID"
log "  zone: $ZONE_NAME"

# Hostname sanity — each must end in the zone (defensive against env file drift).
for h in "$WORKER_AUDIT_HOST" "$WORKER_EMAIL_HOST" "$WORKER_CRED_HOST" "$WORKER_MEMORY_HOST" "$WORKER_CONFIG_HOST" "$WORKER_CLASSIFY_HOST"; do
  [[ -n "$h" ]] || die "operator-workstation.env did not export all six WORKER_*_HOST variables (incl. WORKER_CONFIG_HOST #201, WORKER_CLASSIFY_HOST #207)"
  case "$h." in
    *".$ZONE_NAME") ;;
    *) die "host $h is not under zone $ZONE_NAME — refusing to UPSERT a record outside the target zone" ;;
  esac
done

# ─── Build + dispatch the change-batch ───────────────────────────────────────
CHANGE_BATCH="$(jq -n \
  --arg audit  "${WORKER_AUDIT_HOST}."  \
  --arg email  "${WORKER_EMAIL_HOST}."  \
  --arg cred   "${WORKER_CRED_HOST}."   \
  --arg memory "${WORKER_MEMORY_HOST}." \
  --arg config "${WORKER_CONFIG_HOST}." \
  --arg classify "${WORKER_CLASSIFY_HOST}." \
  --arg ip "$EIP" \
  --argjson ttl "$TTL" '{
    Comment: "audit/email/cred/memory/config/classify workers co-located with broker (issue #90 + #201 + #207)",
    Changes: [
      {Action:"UPSERT", ResourceRecordSet:{Name:$audit,  Type:"A", TTL:$ttl, ResourceRecords:[{Value:$ip}]}},
      {Action:"UPSERT", ResourceRecordSet:{Name:$email,  Type:"A", TTL:$ttl, ResourceRecords:[{Value:$ip}]}},
      {Action:"UPSERT", ResourceRecordSet:{Name:$cred,   Type:"A", TTL:$ttl, ResourceRecords:[{Value:$ip}]}},
      {Action:"UPSERT", ResourceRecordSet:{Name:$memory, Type:"A", TTL:$ttl, ResourceRecords:[{Value:$ip}]}},
      {Action:"UPSERT", ResourceRecordSet:{Name:$config, Type:"A", TTL:$ttl, ResourceRecords:[{Value:$ip}]}},
      {Action:"UPSERT", ResourceRecordSet:{Name:$classify, Type:"A", TTL:$ttl, ResourceRecords:[{Value:$ip}]}}
    ]
  }')"

cat <<EOF

── Plan ──
  Zone        : $ZONE_NAME ($ZONE_ID)
  EIP         : $EIP
  TTL         : $TTL
  Records (6) :
    $WORKER_AUDIT_HOST  A  $EIP
    $WORKER_EMAIL_HOST  A  $EIP
    $WORKER_CRED_HOST   A  $EIP
    $WORKER_MEMORY_HOST A  $EIP
    $WORKER_CONFIG_HOST A  $EIP
    $WORKER_CLASSIFY_HOST A  $EIP

EOF

if $DRY_RUN; then
  log "Dry-run — change-batch payload:"
  echo "$CHANGE_BATCH" | jq .
  exit 0
fi

log "Submitting Route 53 change-batch (UPSERT × 6)"
CHANGE_ID="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch "$CHANGE_BATCH" \
  --query 'ChangeInfo.Id' --output text)"
log "  Route 53 ChangeId: $CHANGE_ID  (status will flip INSYNC within ~60s)"

# --no-verify (orchestrator mode): the records are UPSERTed; skip the slow
# INSYNC + DoH propagation wait and the operator next-steps printout. The caller
# (setup-cloud.sh) submits the broker/signer/mcp records the same way without a
# wait; verify-workers.sh proves reachability later.
if $NO_VERIFY; then
  log "  --no-verify: worker A records submitted; skipping INSYNC/DoH wait + next-steps"
  exit 0
fi

# Wait for INSYNC + DoH verification — gives a hard signal that LE will succeed.
log "Waiting for Route 53 INSYNC"
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
log "  INSYNC"

log "Verifying propagation via Cloudflare DoH (local resolver may still be lying behind VPN)"
for h in "$WORKER_AUDIT_HOST" "$WORKER_EMAIL_HOST" "$WORKER_CRED_HOST" "$WORKER_MEMORY_HOST" "$WORKER_CONFIG_HOST" "$WORKER_CLASSIFY_HOST"; do
  attempts=0
  until [ "$(curl -s --max-time 5 "https://cloudflare-dns.com/dns-query?name=${h}&type=A" \
              -H 'accept: application/dns-json' | jq -r '.Answer[0].data // empty')" = "$EIP" ]; do
    attempts=$((attempts + 1))
    if (( attempts > 60 )); then
      warn "$h still not resolving to $EIP after 5min via Cloudflare DoH — propagation slow, continuing anyway"
      break
    fi
    sleep 5
  done
  log "  $h → $EIP  (resolved via Cloudflare DoH)"
done

cat <<EOF

================================================================================
  Route 53 records ready.
================================================================================
  Next steps on the broker host:

    sudo bash scripts/setup-broker-host.sh --yes                              # writes HTTP-only nginx vhosts
    for h in $WORKER_AUDIT_HOST $WORKER_EMAIL_HOST $WORKER_CRED_HOST $WORKER_MEMORY_HOST $WORKER_CONFIG_HOST $WORKER_CLASSIFY_HOST; do
      sudo certbot certonly --webroot -w /var/www/certbot -d "\$h" \\
        --agree-tos -m ops@litentry.org --non-interactive
    done
    sudo bash scripts/setup-broker-host.sh --yes                              # second pass flips on :443 ssl

  Then verify from your laptop:

    bash scripts/verify-workers.sh

================================================================================
EOF
