#!/usr/bin/env bash
# scripts/setup-mcp-host.sh — idempotent MCP-server + relay deploy on the
# broker EC2 host. Per CLAUDE.md "Idempotent remote-setup rule" — every
# step pre-checks state, emits `ok proceeding` / `skip <reason>` /
# `fail <reason>`, and short-circuits when already done.
#
# Topology this script lands:
#
#   nginx (TLS for mcp.litentry.org)
#     │
#     ├── /mcp_endpoint/mcp/?token=…   ──┐
#     │                                  ▼ wss → ws upgrade
#     ├── /mcp_endpoint/call/?token=…   →  mcp-endpoint-server (127.0.0.1:8004)
#     │                                                              ▲
#     └── /healthz                      →  agentkeys-mcp-server      │ ws tool side
#                                          --transport mcp-endpoint  │
#                                          ──────────────────────────┘
#
# After this runs:
#   wss://mcp.litentry.org/mcp_endpoint/mcp/?token=<TOKEN>   → tool side
#   wss://mcp.litentry.org/mcp_endpoint/call/?token=<TOKEN>  → xiaozhi side
#   https://mcp.litentry.org/mcp_endpoint/health?key=<KEY>   → 智控台 health
#
# Run ON the broker host (same host setup-broker-host.sh runs against).
# Standalone for now; CLAUDE.md follow-up: fold into setup-broker-host.sh
# as `--with-mcp` once this stabilises.
#
# Usage:
#   bash scripts/setup-mcp-host.sh                          # bring up / upgrade
#   bash scripts/setup-mcp-host.sh --domain mcp.litentry.org --certbot-email …
#   bash scripts/setup-mcp-host.sh --without-nginx --without-certbot   # skip the TLS layer
#
set -euo pipefail
export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="mcp.litentry.org"
RELAY_PORT="8004"
INSTALL_DIR="/opt/agentkeys/mcp-endpoint"
RELAY_REPO="https://github.com/xinnan-tech/mcp-endpoint-server.git"
RELAY_PIN_REF="${RELAY_PIN_REF:-main}"      # override to pin commit
RUN_USER="agentkey"
ENV_FILE_DIR="/etc/agentkeys"
ENV_FILE="${ENV_FILE_DIR}/mcp.env"
TOKEN_FILE="${ENV_FILE_DIR}/mcp-tool-token"
HEALTH_KEY_FILE="${ENV_FILE_DIR}/mcp-health-key"
MCP_BIN_DST="/usr/local/bin/agentkeys-mcp-server"
MCP_BIN_SRC="${REPO_ROOT}/target/release/agentkeys-mcp-server"
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
WITH_NGINX="yes"
WITH_CERTBOT="yes"
WITH_BUILD="yes"
CERTBOT_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)          DOMAIN="$2"; shift 2 ;;
    --certbot-email)   CERTBOT_EMAIL="$2"; shift 2 ;;
    --without-nginx)   WITH_NGINX="no"; shift ;;
    --without-certbot) WITH_CERTBOT="no"; shift ;;
    --without-build)   WITH_BUILD="no"; shift ;;
    --relay-port)      RELAY_PORT="$2"; shift 2 ;;
    --relay-ref)       RELAY_PIN_REF="$2"; shift 2 ;;
    --help|-h)         sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -t 2 ]; then
  C_HEAD=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_SKIP=$'\033[0;33m'; C_ERR=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_HEAD=''; C_OK=''; C_SKIP=''; C_ERR=''; C_RESET=''
fi
head() { printf "${C_HEAD}==> %s${C_RESET}\n" "$*" >&2; }
ok()   { printf "    ${C_OK}ok proceeding${C_RESET} — %s\n" "$*" >&2; }
skip() { printf "    ${C_SKIP}skip${C_RESET}          — %s\n" "$*" >&2; }
fail() { printf "    ${C_ERR}fail${C_RESET}          — %s\n" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing prerequisite: $1"; }

need sudo

# ─── 0. Distro-package prerequisites ─────────────────────────────────
# Idempotent: pkg checks first, only `apt install` what's missing. Output
# follows the script's ok/skip/fail convention so a clean re-run shows
# all skips.
head "0/9 distro packages (python3-venv, python3-pip, git, nginx, certbot)"
if command -v apt-get >/dev/null 2>&1; then
  PKGS=(python3-venv python3-pip git)
  [[ "$WITH_NGINX"   == "yes" ]] && PKGS+=(nginx)
  [[ "$WITH_CERTBOT" == "yes" ]] && PKGS+=(certbot python3-certbot-nginx)

  MISSING=()
  for pkg in "${PKGS[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      skip "$pkg already installed"
    else
      MISSING+=("$pkg")
    fi
  done

  if [ ${#MISSING[@]} -gt 0 ]; then
    sudo apt-get update -qq
    sudo apt-get install -y "${MISSING[@]}"
    ok "installed: ${MISSING[*]}"
  fi
elif command -v dnf >/dev/null 2>&1; then
  PKGS=(python3 python3-pip git)
  [[ "$WITH_NGINX"   == "yes" ]] && PKGS+=(nginx)
  [[ "$WITH_CERTBOT" == "yes" ]] && PKGS+=(certbot python3-certbot-nginx)
  sudo dnf install -y -q "${PKGS[@]}" >/dev/null
  ok "ensured: ${PKGS[*]} (dnf is idempotent)"
else
  skip "no apt-get or dnf; assuming prerequisites are present"
  [[ "$WITH_NGINX"   == "yes" ]] && need nginx || true
  [[ "$WITH_CERTBOT" == "yes" ]] && need certbot || true
fi

# Resolve the run-user, falling back to ubuntu on hosts where the
# setup-broker-host.sh hasn't created `agentkey` yet.
if ! id "$RUN_USER" >/dev/null 2>&1; then
  if id ubuntu >/dev/null 2>&1; then
    RUN_USER="ubuntu"
    skip "run-user: agentkey not found; using ubuntu"
  else
    fail "neither agentkey nor ubuntu user exists"
  fi
fi

head "config"
echo "    domain:            ${DOMAIN}" >&2
echo "    relay (local):     127.0.0.1:${RELAY_PORT}" >&2
echo "    relay src:         ${RELAY_REPO}@${RELAY_PIN_REF}" >&2
echo "    install dir:       ${INSTALL_DIR}" >&2
echo "    run user:          ${RUN_USER}" >&2
echo "    env file:          ${ENV_FILE}" >&2
echo "    mcp binary src:    ${MCP_BIN_SRC}" >&2
echo "    mcp binary dst:    ${MCP_BIN_DST}" >&2
echo "    with nginx:        ${WITH_NGINX}" >&2
echo "    with certbot:      ${WITH_CERTBOT}" >&2
echo "    with build:        ${WITH_BUILD}" >&2

# ─── 1. /etc/agentkeys exists with the right perms ───────────────────
head "1/9 /etc/agentkeys layout"
if [ -d "$ENV_FILE_DIR" ]; then
  skip "$ENV_FILE_DIR already exists"
else
  sudo install -d -m 0750 -o "$RUN_USER" -g "$RUN_USER" "$ENV_FILE_DIR"
  ok "created $ENV_FILE_DIR (0750 ${RUN_USER}:${RUN_USER})"
fi

# ─── 2. Token + key — generate on first run only ─────────────────────
head "2/9 tool token + 智控台 health key"
gen_token() { head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32; }
for pair in "TOKEN_FILE:tool token" "HEALTH_KEY_FILE:health key"; do
  var="${pair%%:*}"; desc="${pair##*:}"
  path="${!var}"
  if sudo test -s "$path"; then
    skip "$desc already exists at $path (preserving so URLs stay stable)"
  else
    secret=$(gen_token)
    printf '%s' "$secret" | sudo tee "$path" >/dev/null
    sudo chown "$RUN_USER:$RUN_USER" "$path"
    sudo chmod 0600 "$path"
    ok "generated $desc at $path"
  fi
done
TOKEN=$(sudo cat "$TOKEN_FILE")
HEALTH_KEY=$(sudo cat "$HEALTH_KEY_FILE")

# ─── 3. mcp-endpoint-server clone + venv ─────────────────────────────
head "3/9 mcp-endpoint-server src + venv"
if sudo test -d "$INSTALL_DIR/src/.git"; then
  current_ref=$(sudo -u "$RUN_USER" git -C "$INSTALL_DIR/src" rev-parse HEAD)
  sudo -u "$RUN_USER" git -C "$INSTALL_DIR/src" fetch --quiet origin "$RELAY_PIN_REF"
  target_ref=$(sudo -u "$RUN_USER" git -C "$INSTALL_DIR/src" rev-parse "origin/$RELAY_PIN_REF" 2>/dev/null \
                 || sudo -u "$RUN_USER" git -C "$INSTALL_DIR/src" rev-parse "$RELAY_PIN_REF")
  if [ "$current_ref" = "$target_ref" ]; then
    skip "src at $current_ref already matches $RELAY_PIN_REF"
  else
    sudo -u "$RUN_USER" git -C "$INSTALL_DIR/src" checkout --quiet "$target_ref"
    ok "src moved $current_ref → $target_ref"
    DEPS_DIRTY=1
  fi
else
  sudo install -d -m 0755 -o "$RUN_USER" -g "$RUN_USER" "$INSTALL_DIR"
  sudo -u "$RUN_USER" git clone --quiet --depth 1 -b "$RELAY_PIN_REF" "$RELAY_REPO" "$INSTALL_DIR/src"
  ok "cloned $RELAY_REPO@$RELAY_PIN_REF → $INSTALL_DIR/src"
  DEPS_DIRTY=1
fi

# Healthy venv = .venv/bin/python3 exists AND runs. A failed first attempt
# (e.g. python3-venv missing) can leave a half-built .venv directory; we
# treat that as broken and recreate.
VENV_HEALTHY="no"
if sudo test -x "$INSTALL_DIR/src/.venv/bin/python3"; then
  if sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/python3" -c "pass" 2>/dev/null; then
    VENV_HEALTHY="yes"
  fi
fi

if [ "$VENV_HEALTHY" = "yes" ]; then
  if [ "${DEPS_DIRTY:-0}" = "1" ]; then
    sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/pip" install --quiet -r "$INSTALL_DIR/src/requirements.txt"
    ok "venv: pip install -r requirements.txt (src moved)"
  else
    skip "venv already exists + healthy + src unchanged"
  fi
else
  # Wipe a half-built venv from a prior failed run, if any.
  if sudo test -d "$INSTALL_DIR/src/.venv"; then
    sudo rm -rf "$INSTALL_DIR/src/.venv"
    ok "removed broken half-built venv from a prior failed run"
  fi
  sudo -u "$RUN_USER" python3 -m venv "$INSTALL_DIR/src/.venv"
  sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/pip" install --quiet --upgrade pip
  sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/pip" install --quiet -r "$INSTALL_DIR/src/requirements.txt"
  ok "created venv + installed requirements.txt"
fi

# ─── 4. Build + install agentkeys-mcp-server binary ──────────────────
head "4/9 agentkeys-mcp-server binary"
if [ "$WITH_BUILD" = "yes" ]; then
  if [ -x "$MCP_BIN_SRC" ]; then
    skip "release binary already built at $MCP_BIN_SRC (use --without-build=no to force)"
  else
    ( cd "$REPO_ROOT" && cargo build --release -p agentkeys-mcp-server )
    ok "cargo build --release -p agentkeys-mcp-server"
  fi
fi

if [ ! -x "$MCP_BIN_SRC" ]; then
  fail "$MCP_BIN_SRC not built; re-run without --without-build or build it yourself"
fi

src_sha=$(sha256sum "$MCP_BIN_SRC" | awk '{print $1}')
dst_sha=$(sudo sha256sum "$MCP_BIN_DST" 2>/dev/null | awk '{print $1}' || echo "missing")
if [ "$src_sha" = "$dst_sha" ]; then
  skip "$MCP_BIN_DST already up to date (sha256 $src_sha)"
else
  sudo install -m 0755 "$MCP_BIN_SRC" "$MCP_BIN_DST"
  ok "installed $MCP_BIN_DST (sha256 $src_sha)"
  RESTART_MCP=1
fi

# ─── 5. /etc/agentkeys/mcp.env ───────────────────────────────────────
head "5/9 /etc/agentkeys/mcp.env"
want_env=$(cat <<EOF
# Generated by scripts/setup-mcp-host.sh — DO NOT HAND-EDIT
# Re-run the script to regenerate. Backed by ${TOKEN_FILE} + ${HEALTH_KEY_FILE}.
MCP_TRANSPORT=mcp-endpoint
MCP_BACKEND=http
MCP_ENDPOINT=ws://127.0.0.1:${RELAY_PORT}/mcp_endpoint/mcp/?token=${TOKEN}
# These three are placeholders — paste the live broker / worker URLs in
# after running setup-broker-host.sh on the same host.
AGENTKEYS_BROKER_URL=https://broker.litentry.org
AGENTKEYS_MEMORY_URL=https://memory.litentry.org
AGENTKEYS_AUDIT_URL=https://audit.litentry.org
EOF
)
got_env=$(sudo cat "$ENV_FILE" 2>/dev/null || true)
if [ "$want_env" = "$got_env" ]; then
  skip "$ENV_FILE already matches target"
else
  printf '%s\n' "$want_env" | sudo tee "$ENV_FILE" >/dev/null
  sudo chown "$RUN_USER:$RUN_USER" "$ENV_FILE"
  sudo chmod 0600 "$ENV_FILE"
  ok "wrote $ENV_FILE (0600 ${RUN_USER}:${RUN_USER})"
  RESTART_MCP=1
fi

# ─── 6. systemd units ────────────────────────────────────────────────
head "6/9 systemd units (mcp-endpoint-server + agentkeys-mcp-server)"

want_relay_unit=$(cat <<EOF
[Unit]
Description=MCP endpoint relay (xiaozhi tool registration)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}/src
ExecStart=${INSTALL_DIR}/src/.venv/bin/python main.py
Restart=on-failure
RestartSec=5
Environment=PORT=${RELAY_PORT}

[Install]
WantedBy=multi-user.target
EOF
)
RELAY_UNIT_PATH=/etc/systemd/system/mcp-endpoint-server.service
got=$(sudo cat "$RELAY_UNIT_PATH" 2>/dev/null || true)
if [ "$want_relay_unit" = "$got" ]; then
  skip "${RELAY_UNIT_PATH##*/} already up to date"
else
  printf '%s\n' "$want_relay_unit" | sudo tee "$RELAY_UNIT_PATH" >/dev/null
  ok "wrote ${RELAY_UNIT_PATH##*/}"
  DAEMON_RELOAD=1
  RESTART_RELAY=1
fi

want_mcp_unit=$(cat <<EOF
[Unit]
Description=AgentKeys MCP server (xiaozhi MCP-endpoint tool)
After=network-online.target mcp-endpoint-server.service
Wants=network-online.target mcp-endpoint-server.service

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${REPO_ROOT}
EnvironmentFile=${ENV_FILE}
ExecStart=${MCP_BIN_DST}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
)
MCP_UNIT_PATH=/etc/systemd/system/agentkeys-mcp-server.service
got=$(sudo cat "$MCP_UNIT_PATH" 2>/dev/null || true)
if [ "$want_mcp_unit" = "$got" ]; then
  skip "${MCP_UNIT_PATH##*/} already up to date"
else
  printf '%s\n' "$want_mcp_unit" | sudo tee "$MCP_UNIT_PATH" >/dev/null
  ok "wrote ${MCP_UNIT_PATH##*/}"
  DAEMON_RELOAD=1
  RESTART_MCP=1
fi

[ "${DAEMON_RELOAD:-0}" = "1" ] && sudo systemctl daemon-reload

sudo systemctl enable mcp-endpoint-server.service >/dev/null 2>&1 || true
sudo systemctl enable agentkeys-mcp-server.service >/dev/null 2>&1 || true

if [ "${RESTART_RELAY:-0}" = "1" ]; then
  sudo systemctl restart mcp-endpoint-server.service
  ok "restarted mcp-endpoint-server.service"
else
  sudo systemctl start mcp-endpoint-server.service 2>/dev/null || true
fi
if [ "${RESTART_MCP:-0}" = "1" ]; then
  sudo systemctl restart agentkeys-mcp-server.service
  ok "restarted agentkeys-mcp-server.service"
else
  sudo systemctl start agentkeys-mcp-server.service 2>/dev/null || true
fi

# ─── 7. nginx vhost (TLS-terminating wss → ws) ───────────────────────
if [ "$WITH_NGINX" = "yes" ]; then
  head "7/9 nginx vhost (TLS-terminating wss → ws for ${DOMAIN})"

  # Two-phase nginx config (same pattern as setup-broker-host.sh) to
  # solve the certbot ↔ nginx chicken-and-egg:
  #
  #   Phase A (no cert yet)   :80-only with the ACME challenge location.
  #                           certbot uses webroot to issue.
  #   Phase B (cert exists)   :80 redirects to :443, :443 server block
  #                           proxies wss → ws + 智控台 health.
  #
  # Re-running this script after issuance flips A → B automatically
  # (cert presence is the only trigger).
  #
  # `listen 443 ssl http2;` keeps the old syntax that works on
  # nginx <1.25 — the `http2 on;` directive only lands in 1.25.1+.
  if sudo test -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"; then
    NGINX_PHASE="B"
    want_vhost=$(cat <<EOF
# Generated by scripts/setup-mcp-host.sh (phase B — cert present)
# DO NOT HAND-EDIT. Re-run the script to regenerate.

map \$http_upgrade \$mcp_connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};
  location /.well-known/acme-challenge/ { root /var/www/html; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
  include /etc/letsencrypt/options-ssl-nginx.conf;
  ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

  # WebSocket relay paths — wss → ws upgrade to the local relay.
  location ~ ^/mcp_endpoint/(mcp|call)/ {
    proxy_pass http://127.0.0.1:${RELAY_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$mcp_connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }

  # 智控台 health probe (HTTP, not WS).
  location /mcp_endpoint/health {
    proxy_pass http://127.0.0.1:${RELAY_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
)
  else
    NGINX_PHASE="A"
    want_vhost=$(cat <<EOF
# Generated by scripts/setup-mcp-host.sh (phase A — pre-cert)
# DO NOT HAND-EDIT. After certbot issues, re-run the script to flip to phase B.

server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};

  # ACME http-01 challenge — certbot drops tokens here.
  location /.well-known/acme-challenge/ { root /var/www/html; }

  # Everything else 503s until phase B lands (post-cert).
  location / {
    return 503 "TLS cert not yet issued for ${DOMAIN} — re-run scripts/setup-mcp-host.sh after certbot\n";
    default_type text/plain;
  }
}
EOF
)
  fi
  got=$(sudo cat "$NGINX_SITE" 2>/dev/null || true)
  if [ "$want_vhost" = "$got" ]; then
    skip "${NGINX_SITE##*/} (phase $NGINX_PHASE) already up to date"
  else
    printf '%s\n' "$want_vhost" | sudo tee "$NGINX_SITE" >/dev/null
    ok "wrote ${NGINX_SITE##*/} (phase $NGINX_PHASE)"
    RELOAD_NGINX=1
  fi
  if [ -L "$NGINX_SITE_LINK" ] || [ -e "$NGINX_SITE_LINK" ]; then
    skip "${NGINX_SITE_LINK##*/} already linked"
  else
    sudo ln -sf "$NGINX_SITE" "$NGINX_SITE_LINK"
    ok "enabled site ${NGINX_SITE_LINK##*/}"
    RELOAD_NGINX=1
  fi

  # Reload nginx NOW (mid-step) so certbot's webroot challenge can
  # land against the live phase-A vhost. The post-cert phase-B reload
  # happens in step 9.
  if [ "${RELOAD_NGINX:-0}" = "1" ]; then
    sudo nginx -t
    sudo systemctl reload nginx
    ok "reloaded nginx (phase $NGINX_PHASE)"
    RELOAD_NGINX=0
  fi
else
  head "7/9 nginx vhost"
  skip "--without-nginx; skipping vhost"
fi

# ─── 8. certbot cert (idempotent: reuses existing) ───────────────────
if [ "$WITH_NGINX" = "yes" ] && [ "$WITH_CERTBOT" = "yes" ]; then
  head "8/9 certbot certificate for ${DOMAIN}"
  if sudo test -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"; then
    skip "cert already issued at /etc/letsencrypt/live/${DOMAIN}/ (certbot will auto-renew)"
  else
    # Ensure the webroot dir exists for ACME http-01 challenges.
    sudo install -d -m 0755 /var/www/html

    # ACME account email: used by Let's Encrypt for cert-expiry +
    # renewal-failure notifications and account recovery. Three forms:
    #   --certbot-email <addr>            explicit
    #   prior `certbot register` on host   reuses the existing account
    #   neither                            --register-unsafely-without-email
    if sudo test -d /etc/letsencrypt/accounts && \
       [ "$(sudo find /etc/letsencrypt/accounts -name 'regr.json' | wc -l)" -gt 0 ]; then
      EMAIL_ARG=""
      ok "reusing existing ACME account on host (no --certbot-email needed)"
    elif [ -n "$CERTBOT_EMAIL" ]; then
      EMAIL_ARG="-m $CERTBOT_EMAIL"
    else
      EMAIL_ARG="--register-unsafely-without-email"
      ok "no --certbot-email + no existing ACME account; using --register-unsafely-without-email"
      echo "    (Let's Encrypt will not send expiry notifications. Re-run with" >&2
      echo "     --certbot-email <addr> later to attach a recovery address.)" >&2
    fi

    # DNS pre-flight: certbot fails with NXDOMAIN if the A record isn't
    # live yet. Check before attempting — a clear skip with an action
    # item is much more useful than a cryptic certbot error.
    MY_IP=$(curl -sf --max-time 5 http://checkip.amazonaws.com 2>/dev/null \
              || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
              || echo "")
    DNS_IP=$(dig +short A "$DOMAIN" 2>/dev/null | head -1 \
               || getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 \
               || echo "")

    DNS_OK="yes"
    if [ -z "$DNS_IP" ]; then
      DNS_OK="no"
      echo "    DNS A record for ${DOMAIN} is not yet visible (NXDOMAIN)." >&2
      echo "    Certbot's http-01 challenge will fail until DNS resolves." >&2
      echo >&2
      echo "    ACTION REQUIRED — create an A record in your DNS provider:" >&2
      echo "      Name:  ${DOMAIN}" >&2
      echo "      Type:  A" >&2
      echo "      Value: ${MY_IP:-<PUBLIC_IP_OF_THIS_HOST>}" >&2
      echo "      TTL:   300 (5 min)" >&2
      echo >&2
      echo "    Wait for TTL propagation, then re-run this script." >&2
      echo "    The relay + MCP services are already running on port ${RELAY_PORT}." >&2
      echo "    TLS and the wss:// URLs activate on the next run." >&2
      skip "cert deferred — DNS A record for ${DOMAIN} not yet live"
    elif [ -n "$MY_IP" ] && [ "$DNS_IP" != "$MY_IP" ]; then
      DNS_OK="no"
      echo "    DNS A for ${DOMAIN} resolves to ${DNS_IP}, but this host is ${MY_IP}." >&2
      echo "    Update the A record to point at ${MY_IP} and re-run." >&2
      skip "cert deferred — DNS A for ${DOMAIN} → ${DNS_IP} (expected ${MY_IP})"
    fi

    if [ "$DNS_OK" = "yes" ]; then
    # Webroot mode (NOT --nginx) — issues the cert without mutating
    # the vhost we just wrote. The phase-B flip is our job; certbot
    # only puts files under /etc/letsencrypt/.
    sudo certbot certonly --webroot -w /var/www/html \
      -d "$DOMAIN" --non-interactive --agree-tos $EMAIL_ARG
    ok "issued cert for $DOMAIN via webroot"

    # Now flip phase A → phase B inline (re-run step 7's vhost write
    # so the operator gets TLS in a single script invocation).
    NGINX_PHASE="B"
    phase_b_vhost=$(cat <<EOF
# Generated by scripts/setup-mcp-host.sh (phase B — cert present)
# DO NOT HAND-EDIT. Re-run the script to regenerate.

map \$http_upgrade \$mcp_connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};
  location /.well-known/acme-challenge/ { root /var/www/html; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
  include /etc/letsencrypt/options-ssl-nginx.conf;
  ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

  location ~ ^/mcp_endpoint/(mcp|call)/ {
    proxy_pass http://127.0.0.1:${RELAY_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$mcp_connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }

  location /mcp_endpoint/health {
    proxy_pass http://127.0.0.1:${RELAY_PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
)
    printf '%s\n' "$phase_b_vhost" | sudo tee "$NGINX_SITE" >/dev/null
    ok "rewrote ${NGINX_SITE##*/} to phase B (TLS on)"
    RELOAD_NGINX=1
    fi  # DNS_OK
  fi    # cert not yet present
fi      # WITH_NGINX && WITH_CERTBOT

# ─── 9. nginx reload (only if drift) + post-checks ───────────────────
if [ "$WITH_NGINX" = "yes" ]; then
  head "9/9 nginx reload + post-checks"
  if [ "${RELOAD_NGINX:-0}" = "1" ]; then
    sudo nginx -t
    sudo systemctl reload nginx
    ok "reloaded nginx"
  else
    skip "no nginx drift, no reload"
  fi

  # Probe the local relay's /healthz via 127.0.0.1 so we don't depend on DNS
  # being live yet during the first run.
  if curl -sf "http://127.0.0.1:${RELAY_PORT}/mcp_endpoint/health?key=${HEALTH_KEY}" >/dev/null 2>&1; then
    ok "local relay /mcp_endpoint/health reachable"
  else
    # Health endpoint may not be the relay's actual probe path; check raw upstream:
    if curl -sf "http://127.0.0.1:${RELAY_PORT}/" >/dev/null 2>&1; then
      skip "/mcp_endpoint/health did not match this version of mcp-endpoint-server; raw upstream IS reachable"
    else
      fail "relay not responding on 127.0.0.1:${RELAY_PORT} after restart"
    fi
  fi

  # Don't require external DNS in the post-check — the operator may have
  # only just pointed mcp.litentry.org at this host.
  echo "    nginx vhost wired for ${DOMAIN}. Verify externally once DNS A record is live:" >&2
  echo "      curl -sf https://${DOMAIN}/mcp_endpoint/health?key=${HEALTH_KEY}" >&2
fi

echo
head "ready"
echo "    Tool URL  (this MCP server connects here):"  >&2
echo "      wss://${DOMAIN}/mcp_endpoint/mcp/?token=${TOKEN}" >&2
echo "    Client URL (xiaozhi cloud / xiaozhi-server connects here):" >&2
echo "      wss://${DOMAIN}/mcp_endpoint/call/?token=${TOKEN}" >&2
echo "    Health URL (智控台 health probe):" >&2
echo "      https://${DOMAIN}/mcp_endpoint/health?key=${HEALTH_KEY}" >&2
echo >&2
echo "    Token + key persisted under ${ENV_FILE_DIR}/ (0600). Re-running this" >&2
echo "    script never regenerates them — URLs stay stable across deploys." >&2
echo "    Paste the client URL into 智控台 → 智能体 → MCP接入点." >&2
