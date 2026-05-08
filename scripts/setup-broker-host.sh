#!/usr/bin/env bash
# AgentKeys broker-host setup — single idempotent entry point.
#
# This script is THE place to bootstrap a fresh broker host AND to redeploy
# changes onto an existing one. It auto-detects which case it is by looking
# at the systemd unit's existing Environment= lines, so the same invocation
# works in both states.
#
# Per CLAUDE.md, all remote-host changes (binary upgrades, systemd unit
# edits, env-var tweaks, nginx/certbot wiring, mock-server redeploys) MUST
# go through this script — no ad-hoc systemctl edits, no hand-built scp.
#
# Usage:
#   bash scripts/setup-broker-host.sh                        # interactive
#   bash scripts/setup-broker-host.sh --non-interactive \    # CI / re-deploy
#     [--issuer-url https://broker.litentry.org] \           # required first time
#     [--account-id 429071895007] \                          # required first time
#     [--region us-east-1] \
#     [--cred-mode none|instance-profile|profile] \
#     [--profile-name agentkeys-daemon] \
#     [--with-nginx | --without-nginx] \
#     [--with-certbot | --without-certbot] \
#     [--ref <branch-or-tag>] \                              # opt-in git fetch+checkout+pull
#     [--skip-pull] \                                        # alias for "no --ref"
#     [--upgrade] \                                          # back-compat no-op
#     [--yes]
#
# On re-runs, missing flags are filled in from the existing
# /etc/systemd/system/agentkeys-broker.service Environment= lines, so
# `bash scripts/setup-broker-host.sh --yes` is a valid full re-deploy.
#
# Pass --ref to opt into a git fetch+checkout+pull before building. Without
# --ref, the script builds whatever is currently checked out — the operator
# is expected to git-pull themselves if they want fresh code.
#
# Order of operations (all idempotent):
#   1. Pre-flight (Linux, sudo, repo checkout, optional git pull on --ref)
#   2. Detect existing config from systemd unit (issuer URL, account ID, etc.)
#   3. Interactive prompts (only for values still missing after detection)
#   4. Summary + confirmation
#   5. Install build deps + Rust toolchain (skip if already present)
#   6. Build agentkeys-mock-server + agentkeys-broker-server (incremental)
#   7. Stop services if running (idempotent — safe on fresh host)
#   8. Backup existing binaries → .bak (skip if no existing)
#   9. Install fresh binaries to /usr/local/bin (mode 0755)
#  10. Create agentkeys system user + /var/lib/agentkeys (mode 0700) if missing
#  11. Write systemd units for backend + broker (always — same content most runs)
#  12. (Optional) install nginx + write site config (always — idempotent)
#  13. (Optional) install certbot package
#  14. Mint missing ES256 keypairs as the agentkeys user (idempotent)
#  15. systemctl daemon-reload + enable + restart agentkeys-backend + agentkeys-broker
#  16. Tail recent logs + print remaining out-of-scope manual steps
#
# Out of scope (operator does these by hand):
#   - DNS A record for $ISSUER_URL host
#   - AWS-side IAM role/policy creation
#   - Cert issuance (certbot --nginx prompts interactively)
#   - Firewall rules

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
ISSUER_URL=""
ACCOUNT_ID=""
REGION="us-east-1"
CRED_MODE=""                 # set by interactive prompt or --cred-mode
PROFILE_NAME="agentkeys-daemon"
WITH_NGINX="auto"            # auto | yes | no
WITH_CERTBOT="auto"          # auto | yes | no
ASSUME_YES=false
PULL_REF=""                  # --ref <branch-or-tag>: opt-in git fetch+checkout+pull
PULL_SKIP=false              # --skip-pull: alias for "no --ref" (kept for back-compat)

# Interactive when stdin is a TTY and the operator hasn't opted out.
if [[ -t 0 ]]; then
  INTERACTIVE=true
else
  INTERACTIVE=false
fi

# ─── CLI parse ────────────────────────────────────────────────────────────────
while (( $# > 0 )); do
  case "$1" in
    --issuer-url)         ISSUER_URL="$2"; shift 2 ;;
    --account-id)         ACCOUNT_ID="$2"; shift 2 ;;
    --region)             REGION="$2"; shift 2 ;;
    --cred-mode)          CRED_MODE="$2"; shift 2 ;;
    --profile-name)       PROFILE_NAME="$2"; shift 2 ;;
    --with-nginx)         WITH_NGINX="yes"; shift ;;
    --without-nginx)      WITH_NGINX="no"; shift ;;
    --with-certbot)       WITH_CERTBOT="yes"; shift ;;
    --without-certbot)    WITH_CERTBOT="no"; shift ;;
    --non-interactive)    INTERACTIVE=false; shift ;;
    --interactive)        INTERACTIVE=true; shift ;;
    --yes|-y)             ASSUME_YES=true; shift ;;
    --upgrade)            shift ;;          # back-compat no-op (script is idempotent now)
    --ref)                PULL_REF="$2"; shift 2 ;;
    --skip-pull)          PULL_SKIP=true; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
log()     { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn()    { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()     { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }
have()    { command -v "$1" >/dev/null 2>&1; }

# Print an explanation block before a prompt. Stays out of the way in
# non-interactive mode so CI logs don't fill up with help text the
# operator can't act on.
explain() {
  $INTERACTIVE || return 0
  printf '\n\033[1;34m── %s ──\033[0m\n' "$1"
  shift
  for line in "$@"; do
    printf '  %s\n' "$line"
  done
  printf '\n'
}

# Read a value with a default; non-empty input wins, empty input keeps the default.
# Args: var-name prompt-label default
prompt_default() {
  local __var="$1" __label="$2" __default="$3" __answer
  read -r -p "$__label [$__default]: " __answer || true
  printf -v "$__var" '%s' "${__answer:-$__default}"
}

# Read a required value. Re-asks until non-empty.
prompt_required() {
  local __var="$1" __label="$2" __answer
  while :; do
    read -r -p "$__label: " __answer || true
    if [[ -n "$__answer" ]]; then
      printf -v "$__var" '%s' "$__answer"
      return
    fi
    warn "value required"
  done
}

# Yes/no prompt with a default. Default-on-empty.
# Args: var-name prompt-label default(yes|no)
prompt_yn() {
  local __var="$1" __label="$2" __default="$3" __hint __answer
  case "$__default" in
    yes) __hint="[Y/n]" ;;
    no)  __hint="[y/N]" ;;
    *)   __hint="[y/n]" ;;
  esac
  while :; do
    read -r -p "$__label $__hint: " __answer || true
    __answer="${__answer:-$__default}"
    case "${__answer,,}" in
      y|yes) printf -v "$__var" '%s' "yes"; return ;;
      n|no)  printf -v "$__var" '%s' "no"; return ;;
    esac
  done
}

# Numbered choice prompt with a default index.
# Args: var-name prompt-label default-index choice1 choice2 ...
prompt_choice() {
  local __var="$1" __label="$2" __default="$3"; shift 3
  local __choices=("$@") __i __pick
  while :; do
    printf '%s (default %s):\n' "$__label" "$__default"
    for __i in "${!__choices[@]}"; do
      printf '  %d) %s\n' "$(( __i + 1 ))" "${__choices[__i]}"
    done
    read -r -p "Choice [$__default]: " __pick || true
    __pick="${__pick:-$__default}"
    if [[ "$__pick" =~ ^[1-9][0-9]*$ ]] && (( __pick >= 1 && __pick <= ${#__choices[@]} )); then
      printf -v "$__var" '%s' "${__choices[$(( __pick - 1 ))]}"
      return
    fi
    warn "pick a number between 1 and ${#__choices[@]}"
  done
}

# Ensure both ES256 keypairs (oidc + session) exist under the broker's
# data dir. Stage 7 added the session keypair (Plan §3.5.6) — pre-Stage-7
# hosts have only the OIDC one and a Stage-7 binary's Tier-1 boot then
# refuse-to-boots with `BOOT_FAIL: BROKER_SESSION_KEYPAIR_PATH=…`. We mint
# anything missing here, idempotently, before the broker is asked to start.
#
# Args: $1 = absolute path to the agentkeys-broker-server binary used for keygen.
# Runs keygen as the `agentkeys` system user so the resulting files end up
# owned by that user with mode 0600 (the binary chmods them itself).
ensure_broker_keypairs() {
  local bin="$1"
  local kp_dir="/var/lib/agentkeys/.agentkeys/broker"
  [[ -x "$bin" ]] || die "ensure_broker_keypairs: binary $bin not found or not executable"
  id -u agentkeys >/dev/null 2>&1 || die "ensure_broker_keypairs: agentkeys system user does not exist yet"
  sudo install -d -m 0700 -o agentkeys -g agentkeys "$kp_dir"
  for purpose in oidc session; do
    local kp_path="$kp_dir/${purpose}-keypair.json"
    if sudo test -f "$kp_path"; then
      log "${purpose} keypair already present at ${kp_path} — leaving in place"
    else
      log "Minting ${purpose} keypair at ${kp_path} (as agentkeys user)"
      sudo -u agentkeys "$bin" keygen --purpose "$purpose" --out "$kp_path"
    fi
  done
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
log "Pre-flight"
[[ "$(uname -s)" == "Linux" ]] || die "broker host setup is Linux-only (got $(uname -s)). Run scripts/setup-dev-env.sh on a developer machine instead."
have sudo                      || die "sudo not found — run as a user with sudo access"
[[ -d "$REPO_ROOT/crates/agentkeys-broker-server" ]] || \
  die "expected agentkeys checkout at $REPO_ROOT — run from inside a clone"

# ─── Detect existing config from systemd unit ────────────────────────────────
# On re-runs, fill in any flags the operator didn't pass by reading the
# Environment= lines from the existing broker unit. This is what makes
# `bash scripts/setup-broker-host.sh --yes` a valid full re-deploy after
# a `git pull` without re-typing every flag.
EXISTING_UNIT=/etc/systemd/system/agentkeys-broker.service
if [[ -f "$EXISTING_UNIT" ]]; then
  log "Detected existing broker unit at $EXISTING_UNIT — reading config"
  read_unit_env() {
    local key="$1"
    sudo grep -E "^Environment=${key}=" "$EXISTING_UNIT" | head -1 \
      | sed -E "s/^Environment=${key}=//"
  }
  [[ -z "$ISSUER_URL"  ]] && ISSUER_URL="$(read_unit_env BROKER_OIDC_ISSUER || true)"
  [[ -z "$ACCOUNT_ID"  ]] && ACCOUNT_ID="$(read_unit_env ACCOUNT_ID         || true)"
  EXISTING_REGION="$(read_unit_env REGION || true)"
  [[ -n "$EXISTING_REGION" ]] && REGION="$EXISTING_REGION"

  # Cred mode inference. After issue #71 we have three options:
  #   - profile: Environment=AWS_PROFILE=<name> present
  #   - none / instance-profile: no AWS_* env (the unit's CRED_LINE is a
  #     comment so we can't tell them apart from the unit alone).
  EXISTING_PROFILE="$(sudo grep -E '^Environment=AWS_PROFILE=' "$EXISTING_UNIT" | head -1 | sed -E 's/^Environment=AWS_PROFILE=//')"
  if [[ -n "$EXISTING_PROFILE" && -z "$CRED_MODE" ]]; then
    CRED_MODE="profile"
    PROFILE_NAME="$EXISTING_PROFILE"
  fi
  log "  detected: ISSUER_URL=${ISSUER_URL:-(unset)}  ACCOUNT_ID=${ACCOUNT_ID:-(unset)}  REGION=$REGION  CRED_MODE=${CRED_MODE:-(default to none)}"
fi

# ─── Optional git pull (--ref, opt-in) ────────────────────────────────────────
# Default behavior: build whatever is currently checked out. The operator is
# expected to git-pull themselves before invoking the script if they want a
# fresh tree. Pass --ref <branch-or-tag> to opt into an in-script pull —
# useful for unattended CI redeploys. --skip-pull is a back-compat no-op.
if [[ -n "$PULL_REF" ]] && ! $PULL_SKIP; then
  have git || die "git not found — install git or drop --ref"
  CURRENT_BRANCH="$( cd "$REPO_ROOT" && git symbolic-ref --short HEAD 2>/dev/null || true )"
  if [[ -n "$CURRENT_BRANCH" && "$CURRENT_BRANCH" != "$PULL_REF" ]]; then
    warn "BRANCH SWITCH: $CURRENT_BRANCH → $PULL_REF (commits unique to $CURRENT_BRANCH will not be deployed)"
  fi
  log "git fetch origin"
  ( cd "$REPO_ROOT" && git fetch origin )
  log "git checkout $PULL_REF"
  ( cd "$REPO_ROOT" && git checkout "$PULL_REF" )
  log "git pull --ff-only"
  ( cd "$REPO_ROOT" && git pull --ff-only )
fi

# ─── Interactive walk-through ─────────────────────────────────────────────────
if $INTERACTIVE; then
  cat <<'EOF'

================================================================================
  AgentKeys broker host bootstrap — interactive
================================================================================
This script walks through the host-side bootstrap from docs/stage7-wip.md
"Remote deployment". It will install packages, create a system user, drop
systemd units, and (optionally) configure nginx + certbot. Re-runs are safe;
existing files won't be overwritten without your input. Cloud-account setup
(IAM, SES, S3, OIDC federation) is separate — see docs/cloud-setup.md.

You'll be asked about each optional step before it happens. Pass --help for
the non-interactive flag set.
EOF

  if [[ -z "$ISSUER_URL" ]]; then
    explain "Public OIDC issuer URL" \
      "The HTTPS URL the outside world (AWS / GCP / clients) will use to" \
      "reach this broker. AWS IAM fetches /.well-known/openid-configuration" \
      "and /.well-known/jwks.json from this URL during" \
      "create-open-id-connect-provider, so it MUST:" \
      "  • be reachable over public TLS (Let's Encrypt is fine)" \
      "  • exactly match BROKER_OIDC_ISSUER (this script writes that env var)" \
      "  • exactly match the --url you pass to AWS later" \
      "" \
      "Example: https://broker.litentry.org"
    prompt_required ISSUER_URL "Issuer URL"
  fi

  if [[ -z "$ACCOUNT_ID" ]]; then
    explain "AWS account ID" \
      "12-digit account ID for the AWS account that holds your" \
      "agentkeys-daemon IAM user (or role) and the agentkeys-data-role role." \
      "Used to derive BROKER_DATA_ROLE_ARN if not overridden."
    prompt_required ACCOUNT_ID "Account ID"
  fi

  explain "AWS region" \
    "Region the broker calls STS in. Use the region your agentkeys-data-role" \
    "role and the operator's S3 bucket already live in."
  prompt_default REGION "Region" "$REGION"

  if [[ -z "$CRED_MODE" ]]; then
    explain "How does the broker get its AWS credentials?" \
      "Post-issue-#71 the broker mint flow is JWT-authenticated and needs" \
      "NO AWS credentials at runtime. The optional GetCallerIdentity" \
      "startup probe still consults whatever the SDK default chain finds:" \
      "" \
      "  1) none              (recommended post-migration)" \
      "       Broker runs creds-free. The startup probe soft-warns once" \
      "       and then falls silent. Smallest blast radius — broker host" \
      "       has zero AWS principals." \
      "" \
      "  2) instance-profile  (recommended if you also run unrelated AWS" \
      "                        tooling on the same EC2 host)" \
      "       SDK pulls creds from the EC2 instance profile via IMDS." \
      "       Broker only uses them for the startup probe." \
      "" \
      "  3) profile           (non-EC2 hosts)" \
      "       Creates ~/.aws/credentials under the agentkeys system user." \
      "       You fill in the access key + secret by hand. AWS_PROFILE is" \
      "       set in the systemd unit so the SDK default chain picks it up." \
      "" \
      "Static IAM-user mode (DAEMON_ACCESS_KEY_ID env vars) was REMOVED in" \
      "the OIDC-only migration — the broker no longer reads those vars."
    prompt_choice CRED_MODE "Credential mode" 1 \
      "none" \
      "instance-profile" \
      "profile"
  fi

  if [[ "$CRED_MODE" == "profile" ]]; then
    explain "Named-profile name" \
      "The profile-name section that goes into ~/.aws/credentials and" \
      "~/.aws/config under the agentkeys user, and into AWS_PROFILE= in" \
      "the broker's systemd unit. Match this to the profile you use" \
      "elsewhere if you want awsp / shared tooling to keep working."
    prompt_default PROFILE_NAME "Profile name" "$PROFILE_NAME"
  fi

  if [[ "$WITH_NGINX" == "auto" ]]; then
    ISSUER_HOST_FOR_PROMPT="${ISSUER_URL#https://}"
    ISSUER_HOST_FOR_PROMPT="${ISSUER_HOST_FOR_PROMPT#http://}"
    ISSUER_HOST_FOR_PROMPT="${ISSUER_HOST_FOR_PROMPT%%/*}"
    explain "Install + configure nginx?" \
      "If yes:" \
      "  • installs nginx via the system package manager" \
      "  • drops a site config at /etc/nginx/sites-available/agentkeys-broker" \
      "  • the site routes $ISSUER_HOST_FOR_PROMPT → 127.0.0.1:8091 and" \
      "    redirects :80 → :443" \
      "  • the cert paths point at /etc/letsencrypt/live/$ISSUER_HOST_FOR_PROMPT/" \
      "    (you run certbot separately to actually issue the cert)" \
      "" \
      "Skip if you're using AWS ALB+ACM, Cloudflare tunnel, Caddy, or an" \
      "existing nginx instance you'll edit yourself. The broker stays bound" \
      "to 127.0.0.1:8091 either way — it's the operator's job to put a" \
      "TLS-terminating proxy in front of it."
    prompt_yn WITH_NGINX "Install nginx now?" "yes"
  fi

  if [[ "$WITH_CERTBOT" == "auto" ]]; then
    explain "Install certbot for Let's Encrypt cert issuance?" \
      "This script INSTALLS the certbot package. It does NOT issue a cert." \
      "Cert issuance requires:" \
      "  • DNS A record for the issuer host already pointing at this host" \
      "  • port 80 reachable from the public internet" \
      "  • you running 'sudo certbot --nginx -d <host>' interactively" \
      "" \
      "Skip if you're using AWS ACM, Cloudflare-managed TLS, or a different" \
      "ACME client."
    if [[ "$WITH_NGINX" == "yes" ]]; then
      prompt_yn WITH_CERTBOT "Install certbot now?" "yes"
    else
      # Without nginx, certbot has nothing to talk to via the --nginx plugin.
      # Default-no but still ask in case the operator plans to run certonly.
      prompt_yn WITH_CERTBOT "Install certbot now?" "no"
    fi
  fi
fi

# ─── Validate inputs ─────────────────────────────────────────────────────────
[[ -n "$ISSUER_URL" ]] || die "--issuer-url is required (e.g. https://broker.litentry.org). Drop --non-interactive for an interactive walk-through."
case "$ISSUER_URL" in
  https://*) ;;
  http://*)  warn "issuer URL uses http:// — AWS IAM requires TLS; create-open-id-connect-provider will reject this. Continuing anyway."; ;;
  *)         die "--issuer-url must start with https:// (got '$ISSUER_URL'). The bare hostname is not a valid OIDC issuer; AWS validates the iss claim byte-for-byte."; ;;
esac
# Strip trailing slash — BROKER_OIDC_ISSUER must match the JWT iss claim
# byte-for-byte, and AWS rejects mismatches at AssumeRoleWithWebIdentity time.
ISSUER_URL="${ISSUER_URL%/}"
[[ -n "$ACCOUNT_ID" ]] || die "--account-id is required. Drop --non-interactive for an interactive walk-through."
[[ -n "$CRED_MODE" ]]  || CRED_MODE="instance-profile"
case "$CRED_MODE" in
  none|instance-profile|profile) ;;
  *) die "--cred-mode must be one of: none, instance-profile, profile (got $CRED_MODE)";;
esac
# Resolve auto → no for the non-interactive path (preserves prior default).
[[ "$WITH_NGINX"   == "auto" ]] && WITH_NGINX="no"
[[ "$WITH_CERTBOT" == "auto" ]] && WITH_CERTBOT="no"

ISSUER_HOST="${ISSUER_URL#https://}"
ISSUER_HOST="${ISSUER_HOST#http://}"
ISSUER_HOST="${ISSUER_HOST%%/*}"

# ─── Summary + confirmation ──────────────────────────────────────────────────
cat <<EOF

── Summary ──
  Issuer URL  : $ISSUER_URL  (host: $ISSUER_HOST)
  Account ID  : $ACCOUNT_ID
  Region      : $REGION
  Cred mode   : $CRED_MODE
EOF
[[ "$CRED_MODE" == "profile" ]] && printf '  Profile     : %s\n' "$PROFILE_NAME"
cat <<EOF
  nginx       : $WITH_NGINX
  certbot     : $WITH_CERTBOT

This will:
  • install build deps + Rust toolchain (if missing)
  • build agentkeys-mock-server + agentkeys-broker-server in release mode
  • install both binaries to /usr/local/bin
  • create the 'agentkeys' system user + /var/lib/agentkeys (mode 0700)
  • drop systemd units for backend + broker
EOF
[[ "$WITH_NGINX"   == "yes" ]] && echo "  • install nginx + write /etc/nginx/sites-available/agentkeys-broker"
[[ "$WITH_CERTBOT" == "yes" ]] && echo "  • install certbot (you run it manually after DNS is in place)"
echo "  • enable + start agentkeys-backend, agentkeys-broker"
echo

if ! $ASSUME_YES; then
  if $INTERACTIVE; then
    prompt_yn __PROCEED "Proceed?" "yes"
    [[ "$__PROCEED" == "yes" ]] || die "aborted by operator"
  fi
  # Non-interactive mode without --yes: assume yes (this was the prior
  # behavior; if you want a guard, pass --yes explicitly to be safe).
fi

log "issuer URL : $ISSUER_URL  (host: $ISSUER_HOST)"
log "account ID : $ACCOUNT_ID"
log "region     : $REGION"
log "cred mode  : $CRED_MODE"
[[ "$CRED_MODE" == "profile" ]] && log "profile    : $PROFILE_NAME"

# ─── Detect package manager ───────────────────────────────────────────────────
if have apt-get; then
  PM=apt
  PM_INSTALL=(sudo apt-get install -y)
  PM_UPDATE=(sudo apt-get update -y)
elif have dnf; then
  PM=dnf
  PM_INSTALL=(sudo dnf install -y)
  PM_UPDATE=(:)
else
  die "no supported package manager (need apt or dnf)"
fi
log "package manager: $PM"

# ─── 1. Build prereqs ─────────────────────────────────────────────────────────
log "Ensuring base build tools"
"${PM_UPDATE[@]}"
case "$PM" in
  apt) "${PM_INSTALL[@]}" curl build-essential pkg-config libssl-dev ca-certificates ;;
  dnf) "${PM_INSTALL[@]}" curl gcc gcc-c++ make pkgconf-pkg-config openssl-devel ca-certificates ;;
esac

if ! have rustup; then
  log "Installing rustup + stable toolchain"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
log "Rust: $(rustc --version)"

# ─── 2. Build binaries ────────────────────────────────────────────────────────
log "Building agentkeys-mock-server + agentkeys-broker-server (release)"
( cd "$REPO_ROOT" && cargo build --release \
    -p agentkeys-mock-server \
    -p agentkeys-broker-server )

# ─── 3. Install binaries (stop → backup → install → restart later) ──────────
# Stop both services before swap so the kernel isn't holding old inodes
# while we install new ones. Both stops are idempotent (no-op on fresh
# hosts where nothing's running yet).
log "Stopping agentkeys-backend + agentkeys-broker (idempotent)"
sudo systemctl stop agentkeys-broker  2>/dev/null || true
sudo systemctl stop agentkeys-backend 2>/dev/null || true

# Backup existing binaries → .bak so a failed install can be rolled back.
# Skip on fresh hosts where /usr/local/bin/agentkeys-* don't exist yet.
for bin in agentkeys-mock-server agentkeys-broker-server; do
  if [[ -x "/usr/local/bin/$bin" ]]; then
    log "Backing up /usr/local/bin/$bin → /usr/local/bin/$bin.bak"
    sudo cp -p "/usr/local/bin/$bin" "/usr/local/bin/$bin.bak"
  fi
done

log "Installing binaries to /usr/local/bin"
sudo install -m 0755 \
  "$REPO_ROOT/target/release/agentkeys-mock-server" \
  "$REPO_ROOT/target/release/agentkeys-broker-server" \
  /usr/local/bin/

# ─── 4. System user + state dir ───────────────────────────────────────────────
if ! id -u agentkeys >/dev/null 2>&1; then
  log "Creating agentkeys system user"
  sudo useradd --system --home /var/lib/agentkeys --shell /usr/sbin/nologin agentkeys
fi
sudo install -d -m 0700 -o agentkeys -g agentkeys /var/lib/agentkeys

if [[ "$CRED_MODE" == "profile" ]]; then
  sudo install -d -m 0700 -o agentkeys -g agentkeys /var/lib/agentkeys/.aws
  if [[ ! -f /var/lib/agentkeys/.aws/credentials ]]; then
    log "Creating placeholder /var/lib/agentkeys/.aws/credentials"
    sudo -u agentkeys tee /var/lib/agentkeys/.aws/credentials >/dev/null <<EOF
[$PROFILE_NAME]
# Fill these in by hand — this script does NOT write live AWS keys.
# Any IAM user with read-only access works (used only by the broker's
# GetCallerIdentity startup probe post-issue-#71).
aws_access_key_id = REPLACE_WITH_ACCESS_KEY_ID
aws_secret_access_key = REPLACE_WITH_SECRET_ACCESS_KEY
EOF
    sudo chmod 600 /var/lib/agentkeys/.aws/credentials
  fi
  if [[ ! -f /var/lib/agentkeys/.aws/config ]]; then
    sudo -u agentkeys tee /var/lib/agentkeys/.aws/config >/dev/null <<EOF
[profile $PROFILE_NAME]
region = $REGION
EOF
    sudo chmod 600 /var/lib/agentkeys/.aws/config
  fi
fi

# Issue #71 OIDC-only migration: the static-IAM-user mode that wrote
# DAEMON_ACCESS_KEY_ID + DAEMON_SECRET_ACCESS_KEY to /etc/agentkeys/broker.env
# was REMOVED. The broker no longer reads those env vars. If the file
# already exists from a pre-migration deploy, it's harmless but dead.

# ─── 5. systemd units ─────────────────────────────────────────────────────────
log "Writing systemd units"

sudo tee /etc/systemd/system/agentkeys-backend.service >/dev/null <<'EOF'
[Unit]
Description=AgentKeys mock backend (session management)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/agentkeys-mock-server --port 8090
Restart=on-failure
RestartSec=5s
User=agentkeys
Group=agentkeys
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Build the broker unit with the right credential-source line.
case "$CRED_MODE" in
  none)
    CRED_LINE="# Creds-free post-issue-#71 — broker mints via AssumeRoleWithWebIdentity (JWT-authenticated)."
    ;;
  instance-profile)
    CRED_LINE="# Credentials come from the EC2 instance profile via IMDS — only used by GetCallerIdentity startup probe."
    ;;
  profile)
    CRED_LINE="Environment=AWS_PROFILE=$PROFILE_NAME"
    ;;
esac

sudo tee /etc/systemd/system/agentkeys-broker.service >/dev/null <<EOF
[Unit]
Description=AgentKeys broker (Stage 7)
After=network-online.target agentkeys-backend.service
Wants=network-online.target
Requires=agentkeys-backend.service

[Service]
Type=simple
Environment=HOME=/var/lib/agentkeys
Environment=ACCOUNT_ID=$ACCOUNT_ID
Environment=REGION=$REGION
Environment=BROKER_BACKEND_URL=http://127.0.0.1:8090
Environment=BROKER_OIDC_ISSUER=$ISSUER_URL
$CRED_LINE
ExecStart=/usr/local/bin/agentkeys-broker-server --port 8091 --bind 127.0.0.1
# Broker self-exits cleanly (status=0) after 24h max-uptime, so on-failure
# would leave it dead. Use always so systemd restarts it on every exit.
Restart=always
RestartSec=5s
User=agentkeys
Group=agentkeys
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/agentkeys
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# ─── 6. nginx (optional) ──────────────────────────────────────────────────────
# Two-phase nginx config to avoid the certbot ↔ nginx chicken-and-egg:
# nginx will not start if its config references LE cert files that don't
# exist yet, but `certbot --nginx` runs `nginx -t` before issuing — so
# the first run must produce a config nginx can load *without* a cert.
#
#   Phase A (no cert yet):   :80-only with the ACME challenge location.
#                            Operator issues the cert via webroot mode.
#   Phase B (cert exists):   adds the :443 server block with proxy_pass.
#
# Re-running this script after issuance flips A → B automatically.
write_nginx_site() {
  local cert_path="/etc/letsencrypt/live/$ISSUER_HOST/fullchain.pem"
  if sudo test -f "$cert_path"; then
    log "Writing nginx site for $ISSUER_HOST (HTTPS — LE cert detected)"
    sudo tee /etc/nginx/sites-available/agentkeys-broker >/dev/null <<EOF
server {
    listen 80;
    server_name $ISSUER_HOST;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $ISSUER_HOST;

    ssl_certificate     /etc/letsencrypt/live/$ISSUER_HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ISSUER_HOST/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:8091;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_read_timeout 30s;
    }
}
EOF
  else
    log "Writing nginx site for $ISSUER_HOST (HTTP-only — no LE cert yet)"
    log "After issuing a cert, re-run this script to flip on TLS."
    sudo tee /etc/nginx/sites-available/agentkeys-broker >/dev/null <<EOF
# HTTP-only initial config. To issue the Let's Encrypt cert:
#     sudo certbot certonly --webroot -w /var/www/certbot -d $ISSUER_HOST \\
#       --agree-tos -m <ops@your.org> --non-interactive
# then re-run scripts/setup-broker-host.sh to flip on the :443 block.
server {
    listen 80;
    server_name $ISSUER_HOST;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / {
        return 503 "TLS cert not yet issued — see setup-broker-host.sh\n";
        default_type text/plain;
    }
}
EOF
  fi
}

if [[ "$WITH_NGINX" == "yes" ]]; then
  if ! have nginx; then
    log "Installing nginx"
    "${PM_INSTALL[@]}" nginx
  fi
  sudo install -d -m 0755 /var/www/certbot
  write_nginx_site
  if [[ -d /etc/nginx/sites-enabled ]]; then
    sudo ln -sf /etc/nginx/sites-available/agentkeys-broker /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
  fi
  if sudo nginx -t; then
    sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx
  else
    warn "nginx -t failed — leaving service in current state. Inspect /etc/nginx/sites-available/agentkeys-broker."
  fi
fi

# ─── 7. certbot (optional) ────────────────────────────────────────────────────
if [[ "$WITH_CERTBOT" == "yes" ]]; then
  if ! have certbot; then
    log "Installing certbot"
    case "$PM" in
      apt) "${PM_INSTALL[@]}" certbot python3-certbot-nginx ;;
      dnf) "${PM_INSTALL[@]}" certbot python3-certbot-nginx ;;
    esac
  fi
fi

# ─── 8. Mint missing broker keypairs ──────────────────────────────────────────
# Tier-1 boot refuses to start without both ES256 keypairs (Plan §6 disables
# silent generation). Doing this BEFORE systemctl start avoids the otherwise-
# guaranteed first-boot crash loop on a fresh host.
ensure_broker_keypairs /usr/local/bin/agentkeys-broker-server

# ─── 9. Enable + (re)start ────────────────────────────────────────────────────
# `enable` is idempotent. `restart` forces a refresh after binary swap +
# unit-file rewrite — on fresh hosts where the units were just enabled,
# this is equivalent to start; on re-runs it picks up the new binary +
# any unit-file changes.
log "daemon-reload + enable + restart agentkeys-backend, agentkeys-broker"
sudo systemctl daemon-reload
sudo systemctl enable agentkeys-backend agentkeys-broker
sudo systemctl restart agentkeys-backend agentkeys-broker

sleep 2
sudo systemctl --no-pager --full status agentkeys-backend agentkeys-broker || true

log "Recent broker logs (look for 'broker listening on 127.0.0.1:8091'):"
sudo journalctl -u agentkeys-broker -n 20 --no-pager || true
log "Loopback /healthz probe:"
curl -sf --max-time 5 http://127.0.0.1:8091/healthz && echo " (broker)" || warn "broker /healthz did not return 200"
curl -sf --max-time 5 http://127.0.0.1:8090/healthz && echo " (backend)" || warn "backend /healthz did not return 200"

# ─── 9. Print remaining manual steps ──────────────────────────────────────────
cat <<EOF

================================================================================
  AgentKeys broker host bootstrap complete.
================================================================================
Status:
  • backend systemd:           agentkeys-backend.service
  • broker  systemd:           agentkeys-broker.service
  • binaries:                  /usr/local/bin/agentkeys-{mock-server,broker-server}
  • state dir:                 /var/lib/agentkeys      (mode 0700, agentkeys:agentkeys)
  • audit DB will land at:     /var/lib/agentkeys/.agentkeys/broker/audit.sqlite
  • OIDC keypair will land at: /var/lib/agentkeys/.agentkeys/broker/oidc-keypair.json

What you still need to do by hand:

EOF

case "$CRED_MODE" in
  instance-profile)
    cat <<EOF
  AWS credentials (none mode — recommended post-issue-#71):
    1. Nothing to configure. Broker mints via AssumeRoleWithWebIdentity (JWT-authenticated).
    2. Restart the broker if not already running: sudo systemctl restart agentkeys-broker
    3. Tail logs. Expected: "STS client: SDK default chain (creds optional after issue #71 …)"
       and (once) a soft-warn that the GetCallerIdentity startup probe didn't find creds —
       this is the post-migration normal posture.

EOF
    ;;
  instance-profile)
    cat <<EOF
  AWS credentials (instance-profile mode):
    1. Create an IAM role with trust policy {ec2.amazonaws.com → sts:AssumeRole}.
    2. Wrap the role in an instance profile and associate it to this EC2 instance.
       The broker no longer needs sts:AssumeRole on the data role (mint flow uses
       AssumeRoleWithWebIdentity which is JWT-authenticated). Any read-only role
       is fine — used only by the GetCallerIdentity startup probe.
    3. Restart the broker:  sudo systemctl restart agentkeys-broker
    4. Tail logs and look for "STS client: SDK default chain" + "startup STS check passed".

EOF
    ;;
  profile)
    cat <<EOF
  AWS credentials (named-profile mode):
    1. Edit /var/lib/agentkeys/.aws/credentials and replace REPLACE_WITH_*
       with the access key + secret of any IAM user (read-only is fine — the
       broker only uses these for the GetCallerIdentity startup probe).
       (The systemd unit sets AWS_PROFILE=$PROFILE_NAME so the SDK picks it up.)
    2. Restart the broker:  sudo systemctl restart agentkeys-broker
    3. Tail logs and look for "STS client: SDK default chain" + "startup STS check passed".

EOF
    ;;
esac

cat <<EOF
  Public reachability:
    1. Add a DNS A record:  $ISSUER_HOST → <this host's public IP>
    2. Open port 443 on the host firewall (and 80 only for ACME challenges).
       Drop all ingress to :8090 and :8091 except 127.0.0.1.

EOF

if [[ "$WITH_NGINX" == "yes" ]]; then
  if sudo test -f "/etc/letsencrypt/live/$ISSUER_HOST/fullchain.pem"; then
    cat <<EOF
  TLS: cert already issued — nginx is serving HTTPS.
    sudo certbot renew --dry-run    # verify auto-renewal is wired

EOF
  else
    cat <<EOF
  TLS: nginx is HTTP-only until the cert is issued.
    1. Confirm DNS resolves to this host's public IP:
         dig +short $ISSUER_HOST @1.1.1.1
    2. Confirm port 80 is reachable from anywhere (security group + host firewall).
    3. Issue the cert via webroot mode (works while nginx serves :80):
         sudo certbot certonly --webroot -w /var/www/certbot -d $ISSUER_HOST \\
           --agree-tos -m <ops@your.org> --non-interactive
    4. Re-run this script to flip on the :443 block:
         bash scripts/setup-broker-host.sh
    5. Verify renewal:
         sudo certbot renew --dry-run

  Note: do NOT use \`certbot --nginx\` for the first issuance — its preflight
  \`nginx -t\` will fail because the :443 ssl block doesn't exist until step 4.

EOF
  fi
fi

cat <<EOF
  Smoke test (from a client machine — NOT this host):
    curl -sf $ISSUER_URL/healthz
    curl -sf $ISSUER_URL/.well-known/openid-configuration | jq '.issuer == "$ISSUER_URL"'
    curl -sf $ISSUER_URL/.well-known/jwks.json | jq '.keys[0].kid'

  Then continue with docs/cloud-setup.md §4 "OIDC federation" to register
  the OIDC provider with AWS IAM and verify cloud-enforced isolation.

================================================================================
EOF
