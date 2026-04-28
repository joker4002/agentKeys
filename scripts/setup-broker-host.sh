#!/usr/bin/env bash
# AgentKeys broker-host bootstrap.
#
# Provisions a fresh Linux host into a running broker. Automates the manual
# steps in docs/stage7-wip.md "Remote deployment" §1-7. Idempotent — safe
# to re-run after partial failures.
#
# Usage:
#   bash scripts/setup-broker-host.sh \
#     --issuer-url https://broker.example.dev \
#     --account-id 429071895007 \
#     [--region us-east-1] \
#     [--cred-mode instance-profile|profile|static] \
#     [--profile-name agentkeys-daemon] \
#     [--with-nginx] \
#     [--with-certbot]
#
# Order of operations:
#   1. Pre-flight checks (Linux, root via sudo, Rust toolchain, repo checkout)
#   2. Build agentkeys-mock-server + agentkeys-broker-server (release)
#   3. Install binaries to /usr/local/bin
#   4. Create agentkeys system user + /var/lib/agentkeys (mode 0700)
#   5. Drop systemd units for backend + broker
#   6. (Optional) install nginx with site config templating $ISSUER_URL host
#   7. (Optional) install certbot
#   8. Enable + start units
#   9. Print remaining manual steps (DNS A record, certbot run, IAM role
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
CRED_MODE="instance-profile"
PROFILE_NAME="agentkeys-daemon"
WITH_NGINX=false
WITH_CERTBOT=false

# ─── CLI parse ────────────────────────────────────────────────────────────────
while (( $# > 0 )); do
  case "$1" in
    --issuer-url)    ISSUER_URL="$2"; shift 2 ;;
    --account-id)    ACCOUNT_ID="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --cred-mode)     CRED_MODE="$2"; shift 2 ;;
    --profile-name)  PROFILE_NAME="$2"; shift 2 ;;
    --with-nginx)    WITH_NGINX=true; shift ;;
    --with-certbot)  WITH_CERTBOT=true; shift ;;
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
log "Pre-flight"
[[ "$(uname -s)" == "Linux" ]] || die "broker host setup is Linux-only (got $(uname -s)). Run scripts/setup-dev-env.sh on a developer machine instead."
[[ -n "$ISSUER_URL" ]]         || die "--issuer-url is required (e.g. https://broker.example.dev)"
[[ -n "$ACCOUNT_ID" ]]         || die "--account-id is required"
case "$CRED_MODE" in
  instance-profile|profile|static) ;;
  *) die "--cred-mode must be one of: instance-profile, profile, static (got $CRED_MODE)";;
esac
have sudo                      || die "sudo not found — run as a user with sudo access"
[[ -d "$REPO_ROOT/crates/agentkeys-broker-server" ]] || \
  die "expected agentkeys checkout at $REPO_ROOT — run from inside a clone"

ISSUER_HOST="${ISSUER_URL#https://}"
ISSUER_HOST="${ISSUER_HOST#http://}"
ISSUER_HOST="${ISSUER_HOST%%/*}"
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
if [[ "$WITH_NGINX" == "true" ]]; then
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
if [[ "$WITH_CERTBOT" == "true" ]]; then
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

if [[ "$WITH_NGINX" == "true" ]]; then
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
