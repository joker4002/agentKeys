#!/usr/bin/env bash
# AgentKeys broker-host bootstrap.
#
# Provisions a fresh Linux host into a running broker. Automates the manual
# steps in docs/stage7-wip.md "Remote deployment" §1-7. Idempotent — safe
# to re-run after partial failures.
#
# Run with no flags on a TTY for an interactive walk-through that explains
# each decision before it's made. Pass flags / --non-interactive for CI.
#
# Usage:
#   bash scripts/setup-broker-host.sh                        # interactive
#   bash scripts/setup-broker-host.sh --non-interactive \    # CI
#     --issuer-url https://broker.example.dev \
#     --account-id 429071895007 \
#     [--region us-east-1] \
#     [--cred-mode instance-profile|profile|static] \
#     [--profile-name agentkeys-daemon] \
#     [--with-nginx | --without-nginx] \
#     [--with-certbot | --without-certbot] \
#     [--yes]
#
# Order of operations:
#   1. Pre-flight checks (Linux, sudo, repo checkout)
#   2. Interactive prompts (skipped in --non-interactive mode)
#   3. Final summary + confirmation (skipped with --yes)
#   4. Build agentkeys-mock-server + agentkeys-broker-server (release)
#   5. Install binaries to /usr/local/bin
#   6. Create agentkeys system user + /var/lib/agentkeys (mode 0700)
#   7. Drop systemd units for backend + broker
#   8. (Optional) install nginx with site config templating $ISSUER_URL host
#   9. (Optional) install certbot
#  10. Enable + start units
#  11. Print remaining manual steps (DNS A record, certbot run, IAM role
#      attach for instance-profile mode, populate ~/.aws/credentials for
#      profile mode, populate /etc/agentkeys/broker.env for static mode)
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

# ─── Pre-flight ───────────────────────────────────────────────────────────────
log "Pre-flight"
[[ "$(uname -s)" == "Linux" ]] || die "broker host setup is Linux-only (got $(uname -s)). Run scripts/setup-dev-env.sh on a developer machine instead."
have sudo                      || die "sudo not found — run as a user with sudo access"
[[ -d "$REPO_ROOT/crates/agentkeys-broker-server" ]] || \
  die "expected agentkeys checkout at $REPO_ROOT — run from inside a clone"

# ─── Interactive walk-through ─────────────────────────────────────────────────
if $INTERACTIVE; then
  cat <<'EOF'

================================================================================
  AgentKeys broker host bootstrap — interactive
================================================================================
This script walks through the steps in docs/stage7-wip.md "Remote deployment"
on this host. It will install packages, create a system user, drop systemd
units, and (optionally) configure nginx + certbot. Re-runs are safe; existing
files won't be overwritten without your input.

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
      "Example: https://broker.example.dev"
    prompt_required ISSUER_URL "Issuer URL"
  fi

  if [[ -z "$ACCOUNT_ID" ]]; then
    explain "AWS account ID" \
      "12-digit account ID for the AWS account that holds your" \
      "agentkeys-daemon IAM user (or role) and the agentkeys-agent role." \
      "Used to derive BROKER_AGENT_ROLE_ARN if not overridden."
    prompt_required ACCOUNT_ID "Account ID"
  fi

  explain "AWS region" \
    "Region the broker calls STS in. Use the region your agentkeys-agent" \
    "role and the operator's S3 bucket already live in."
  prompt_default REGION "Region" "$REGION"

  if [[ -z "$CRED_MODE" ]]; then
    explain "How does the broker get its AWS credentials?" \
      "Three credential paths, ordered by preference:" \
      "" \
      "  1) instance-profile  (default, recommended for EC2)" \
      "       Broker runs on EC2; SDK pulls creds from the instance profile" \
      "       via IMDS. ZERO secrets on disk. You attach the role to the" \
      "       instance manually after this script finishes." \
      "" \
      "  2) profile           (recommended for non-EC2 hosts)" \
      "       Creates ~/.aws/credentials under the agentkeys system user." \
      "       You fill in the access key + secret by hand. AWS_PROFILE is" \
      "       set in the systemd unit so the SDK picks it up." \
      "" \
      "  3) static            (legacy, only if neither of the above work)" \
      "       Drops DAEMON_ACCESS_KEY_ID + DAEMON_SECRET_ACCESS_KEY into" \
      "       /etc/agentkeys/broker.env. systemd EnvironmentFile= reads it."
    prompt_choice CRED_MODE "Credential mode" 1 \
      "instance-profile" \
      "profile" \
      "static"
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

# ─── Validate non-interactive inputs ─────────────────────────────────────────
[[ -n "$ISSUER_URL" ]] || die "--issuer-url is required (e.g. https://broker.example.dev). Drop --non-interactive for an interactive walk-through."
[[ -n "$ACCOUNT_ID" ]] || die "--account-id is required. Drop --non-interactive for an interactive walk-through."
[[ -n "$CRED_MODE" ]]  || CRED_MODE="instance-profile"
case "$CRED_MODE" in
  instance-profile|profile|static) ;;
  *) die "--cred-mode must be one of: instance-profile, profile, static (got $CRED_MODE)";;
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

# ─── 3. Install binaries ──────────────────────────────────────────────────────
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
aws_access_key_id = REPLACE_WITH_DAEMON_AKID
aws_secret_access_key = REPLACE_WITH_DAEMON_SECRET
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

if [[ "$CRED_MODE" == "static" ]]; then
  sudo install -d -m 0700 /etc/agentkeys
  if [[ ! -f /etc/agentkeys/broker.env ]]; then
    log "Creating placeholder /etc/agentkeys/broker.env"
    sudo tee /etc/agentkeys/broker.env >/dev/null <<'EOF'
# Static IAM-user keys — legacy path, only if instance-profile and
# named-profile aren't options. Both must be set together.
DAEMON_ACCESS_KEY_ID=REPLACE_WITH_DAEMON_AKID
DAEMON_SECRET_ACCESS_KEY=REPLACE_WITH_DAEMON_SECRET
EOF
    sudo chmod 600 /etc/agentkeys/broker.env
  fi
fi

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
  instance-profile)
    CRED_LINE="# Credentials come from the EC2 instance profile via IMDS — no env."
    ;;
  profile)
    CRED_LINE="Environment=AWS_PROFILE=$PROFILE_NAME"
    ;;
  static)
    CRED_LINE="EnvironmentFile=/etc/agentkeys/broker.env"
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
Restart=on-failure
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
if [[ "$WITH_NGINX" == "yes" ]]; then
  if ! have nginx; then
    log "Installing nginx"
    "${PM_INSTALL[@]}" nginx
  fi
  log "Writing nginx site for $ISSUER_HOST"
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

    # certbot will fill these in when you run \`sudo certbot --nginx\` (Step 9).
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
  if [[ -d /etc/nginx/sites-enabled ]]; then
    sudo ln -sf /etc/nginx/sites-available/agentkeys-broker /etc/nginx/sites-enabled/
  fi
  sudo install -d -m 0755 /var/www/certbot
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

# ─── 8. Enable + start ────────────────────────────────────────────────────────
log "Enabling + starting agentkeys-backend, agentkeys-broker"
sudo systemctl daemon-reload
sudo systemctl enable --now agentkeys-backend agentkeys-broker

sleep 2
sudo systemctl --no-pager --full status agentkeys-backend agentkeys-broker || true

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
  AWS credentials (instance-profile mode):
    1. Create an IAM role with trust policy {ec2.amazonaws.com → sts:AssumeRole}.
    2. Attach an inline policy granting sts:AssumeRole on the agentkeys-agent role.
    3. Wrap the role in an instance profile and associate it to this EC2 instance.
    4. Restart the broker:  sudo systemctl restart agentkeys-broker
    5. Tail logs and look for "AWS credentials: SDK default chain (AWS_PROFILE / ~/.aws / IMDS)".

EOF
    ;;
  profile)
    cat <<EOF
  AWS credentials (named-profile mode):
    1. Edit /var/lib/agentkeys/.aws/credentials and replace REPLACE_WITH_*
       with the real \`agentkeys-daemon\` IAM user's access key + secret.
       (The systemd unit sets AWS_PROFILE=$PROFILE_NAME so the SDK picks it up.)
    2. Restart the broker:  sudo systemctl restart agentkeys-broker
    3. Tail logs and look for "AWS credentials: SDK default chain (AWS_PROFILE / ~/.aws / IMDS)".

EOF
    ;;
  static)
    cat <<EOF
  AWS credentials (legacy static-keys mode):
    1. Edit /etc/agentkeys/broker.env and replace REPLACE_WITH_* with the real
       \`agentkeys-daemon\` IAM user's access key + secret.
    2. Restart the broker:  sudo systemctl restart agentkeys-broker
    3. Tail logs and look for "AWS credentials: static IAM-user keys (DAEMON_ACCESS_KEY_ID env)".

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
  cat <<EOF
  TLS:
    sudo certbot --nginx -d $ISSUER_HOST --agree-tos -m <ops@your.org>
    sudo nginx -t && sudo systemctl reload nginx

EOF
fi

cat <<EOF
  Smoke test (from a client machine — NOT this host):
    curl -sf $ISSUER_URL/healthz
    curl -sf $ISSUER_URL/.well-known/openid-configuration | jq '.issuer == "$ISSUER_URL"'
    curl -sf $ISSUER_URL/.well-known/jwks.json | jq '.keys[0].kid'

  Then continue with docs/stage7-wip.md "Cloud federation deployment" §"AWS recipe"
  to register the OIDC provider with AWS IAM.

================================================================================
EOF
