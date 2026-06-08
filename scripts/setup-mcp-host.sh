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
# This is the first-time enable for the hosted MCP endpoint. Once the binary is
# installed, setup-broker-host.sh AUTO-CONVERGES it on every run (re-invokes this
# script to keep it current) — NO flag to remember; behaviour follows state
# (issue #152).
#
# Usage (xiaozhi-hosted mode — DEFAULT, simpler):
#   bash scripts/setup-mcp-host.sh --xiaozhi-endpoint 'wss://api.xiaozhi.me/mcp/?token=…'
#   bash scripts/setup-mcp-host.sh                       # re-run (URL persisted on disk)
#
# Usage (self-hosted relay mode — for custom endpoint deployments):
#   bash scripts/setup-mcp-host.sh --self-hosted-relay              # prod → mcp.litentry.org
#   bash scripts/setup-mcp-host.sh --self-hosted-relay --test       # test → test-mcp.litentry.org
#   bash scripts/setup-mcp-host.sh --self-hosted-relay --domain custom.example.com
#
# Two deployment modes:
#
# MODE = "xiaozhi" (default) — xiaozhi.me hosts the MCP-endpoint relay.
#   • No mcp-endpoint-server clone, no nginx, no certbot, no DNS A record needed.
#   • Operator pastes the wss://api.xiaozhi.me/mcp/?token=… URL from
#     智控台 → 智能体 → MCP接入点 → 接入点地址 into --xiaozhi-endpoint once;
#     it's persisted at /etc/agentkeys/mcp-xiaozhi-endpoint for re-runs.
#   • Only agentkeys-mcp-server runs on the broker host (one systemd unit).
#   • The mcp-endpoint-server systemd unit + nginx vhost are stopped if they
#     were left over from a prior self-hosted run.
#
# MODE = "self-hosted" — operator runs their own mcp-endpoint-server.
#   • Full stack: clone + venv, nginx wss→ws upgrade, certbot, DNS.
#   • Domain resolution:
#       1. --domain X                       explicit
#       2. --test                           → test-mcp.litentry.org
#       3. $MCP_HOST from environment       (operator-workstation.env|.test.env)
#       4. fallback                         → mcp.litentry.org
#   • DNS A record is provisioned by scripts/setup-cloud.sh step 6.
#
set -euo pipefail
export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_PORT="8004"
INSTALL_DIR="/opt/agentkeys/mcp-endpoint"
RELAY_REPO="https://github.com/xinnan-tech/mcp-endpoint-server.git"
RELAY_PIN_REF="${RELAY_PIN_REF:-main}"      # override to pin commit
RUN_USER="agentkey"
ENV_FILE_DIR="/etc/agentkeys"
ENV_FILE="${ENV_FILE_DIR}/mcp.env"
TOKEN_FILE="${ENV_FILE_DIR}/mcp-tool-token"
HEALTH_KEY_FILE="${ENV_FILE_DIR}/mcp-health-key"
XIAOZHI_ENDPOINT_FILE="${ENV_FILE_DIR}/mcp-xiaozhi-endpoint"
MCP_BIN_DST="/usr/local/bin/agentkeys-mcp-server"
WITH_NGINX="yes"
WITH_CERTBOT="yes"
CERTBOT_EMAIL=""
TEST_MODE="no"
DOMAIN_OVERRIDE=""
MODE="xiaozhi"                # default; flipped to "self-hosted" by --self-hosted-relay
XIAOZHI_ENDPOINT=""           # set by --xiaozhi-endpoint or loaded from $XIAOZHI_ENDPOINT_FILE

while [[ $# -gt 0 ]]; do
  case "$1" in
    --xiaozhi-endpoint)   XIAOZHI_ENDPOINT="$2"; MODE="xiaozhi"; shift 2 ;;
    --self-hosted-relay)  MODE="self-hosted"; shift ;;
    --test)               TEST_MODE="yes"; shift ;;
    --domain)             DOMAIN_OVERRIDE="$2"; shift 2 ;;
    --certbot-email)      CERTBOT_EMAIL="$2"; shift 2 ;;
    --without-nginx)      WITH_NGINX="no"; shift ;;
    --without-certbot)    WITH_CERTBOT="no"; shift ;;
    --relay-port)         RELAY_PORT="$2"; shift 2 ;;
    --relay-ref)          RELAY_PIN_REF="$2"; shift 2 ;;
    --help|-h)            sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Resolve DOMAIN per the precedence rules in the header comment.
# Self-hosted mode: needed for nginx vhost + cert.
# Xiaozhi mode: not used (xiaozhi.me handles routing), but we still
# resolve it so log messages / diagnostics name the right thing.
if [ -n "$DOMAIN_OVERRIDE" ]; then
  DOMAIN="$DOMAIN_OVERRIDE"
elif [ "$TEST_MODE" = "yes" ]; then
  DOMAIN="test-mcp.litentry.org"
elif [ -n "${MCP_HOST:-}" ]; then
  DOMAIN="$MCP_HOST"
else
  DOMAIN="mcp.litentry.org"
fi
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

# Mode-specific overrides: xiaozhi mode has no nginx/certbot/relay needs.
if [ "$MODE" = "xiaozhi" ]; then
  WITH_NGINX="no"
  WITH_CERTBOT="no"
fi

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
echo "    mode:              ${MODE}" >&2
echo "    domain:            ${DOMAIN}  (test_mode=${TEST_MODE}; only used in self-hosted mode)" >&2
echo "    relay (local):     127.0.0.1:${RELAY_PORT}" >&2
echo "    relay src:         ${RELAY_REPO}@${RELAY_PIN_REF}" >&2
echo "    install dir:       ${INSTALL_DIR}" >&2
echo "    run user:          ${RUN_USER}" >&2
echo "    env file:          ${ENV_FILE}" >&2
echo "    mcp binary dst:    ${MCP_BIN_DST}" >&2
echo "    mcp build:         cargo build --release -p agentkeys-mcp-server  (in ${REPO_ROOT}, cached/incremental)" >&2
echo "    with nginx:        ${WITH_NGINX}" >&2
echo "    with certbot:      ${WITH_CERTBOT}" >&2

# ─── 1. /etc/agentkeys exists with the right perms ───────────────────
head "1/9 /etc/agentkeys layout"
if [ -d "$ENV_FILE_DIR" ]; then
  skip "$ENV_FILE_DIR already exists"
else
  sudo install -d -m 0750 -o "$RUN_USER" -g "$RUN_USER" "$ENV_FILE_DIR"
  ok "created $ENV_FILE_DIR (0750 ${RUN_USER}:${RUN_USER})"
fi

# ─── 2. Endpoint config (mode-dependent) ─────────────────────────────
# Xiaozhi mode    : persist the wss://api.xiaozhi.me/mcp/?token=… URL.
# Self-hosted mode: generate the relay-token + 智控台 health-key.
if [ "$MODE" = "xiaozhi" ]; then
  head "2/9 xiaozhi MCP endpoint URL"
  # Load persisted URL if no --xiaozhi-endpoint flag was passed.
  if [ -z "$XIAOZHI_ENDPOINT" ] && sudo test -s "$XIAOZHI_ENDPOINT_FILE"; then
    XIAOZHI_ENDPOINT=$(sudo cat "$XIAOZHI_ENDPOINT_FILE")
    ok "loaded persisted endpoint from $XIAOZHI_ENDPOINT_FILE"
  fi
  if [ -z "$XIAOZHI_ENDPOINT" ]; then
    echo "    No --xiaozhi-endpoint URL and no persisted endpoint." >&2
    echo "    Get the URL from 智控台 → 智能体 → MCP接入点 → 接入点地址," >&2
    echo "    then re-run with --xiaozhi-endpoint 'wss://api.xiaozhi.me/mcp/?token=…'." >&2
    echo "    Or use --self-hosted-relay to set up your own mcp-endpoint-server." >&2
    fail "xiaozhi mode requires an endpoint URL on first run"
  fi
  # Persist (idempotent diff-then-write).
  EXISTING_URL=$(sudo cat "$XIAOZHI_ENDPOINT_FILE" 2>/dev/null || true)
  if [ "$EXISTING_URL" = "$XIAOZHI_ENDPOINT" ]; then
    skip "$XIAOZHI_ENDPOINT_FILE already matches"
  else
    printf '%s' "$XIAOZHI_ENDPOINT" | sudo tee "$XIAOZHI_ENDPOINT_FILE" >/dev/null
    sudo chown "$RUN_USER:$RUN_USER" "$XIAOZHI_ENDPOINT_FILE"
    sudo chmod 0600 "$XIAOZHI_ENDPOINT_FILE"
    ok "wrote $XIAOZHI_ENDPOINT_FILE (0600 ${RUN_USER}:${RUN_USER})"
    RESTART_MCP=1
  fi
else
  head "2/9 tool token + 智控台 health key"
  gen_token() { command head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-32; }
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
fi

# ─── 3. mcp-endpoint-server clone + venv (self-hosted only) ──────────
if [ "$MODE" = "xiaozhi" ]; then
  head "3/9 mcp-endpoint-server src + venv"
  skip "xiaozhi mode — xiaozhi.me hosts the relay; no local mcp-endpoint-server needed"
else
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

# Venv health check — verify that the relay's key deps are actually
# importable, NOT just that python3 starts. A half-built venv (e.g. from
# a prior pip install that silently failed) has working python3 but no
# uvicorn/fastapi; the relay then crashes on import at systemd start.
VENV_HEALTHY="no"
VENV_REASON=""
if sudo test -x "$INSTALL_DIR/src/.venv/bin/python3" && \
   sudo test -x "$INSTALL_DIR/src/.venv/bin/pip"; then
  if sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/python3" \
       -c "import uvicorn, fastapi, websockets, loguru" 2>/dev/null; then
    VENV_HEALTHY="yes"
  else
    VENV_REASON="key deps (uvicorn/fastapi/websockets/loguru) not importable"
  fi
else
  VENV_REASON=".venv/bin/python3 or .venv/bin/pip missing"
fi

if [ "$VENV_HEALTHY" = "yes" ]; then
  if [ "${DEPS_DIRTY:-0}" = "1" ]; then
    sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/pip" install --quiet \
        -r "$INSTALL_DIR/src/requirements.txt" \
      || fail "pip install -r requirements.txt failed after src moved (see above)"
    ok "venv: pip install -r requirements.txt (src moved)"
  else
    skip "venv healthy + key deps importable + src unchanged"
  fi
else
  ok "venv unhealthy ($VENV_REASON) — rebuilding"
  # Wipe a half-built venv from a prior failed run, if any.
  if sudo test -d "$INSTALL_DIR/src/.venv"; then
    sudo rm -rf "$INSTALL_DIR/src/.venv"
    ok "removed broken half-built venv from a prior failed run"
  fi
  sudo -u "$RUN_USER" python3 -m venv "$INSTALL_DIR/src/.venv" \
    || fail "python3 -m venv failed (apt install python3-venv?)"
  sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/pip" install --quiet --upgrade pip \
    || fail "pip --upgrade failed"
  sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/pip" install --quiet \
      -r "$INSTALL_DIR/src/requirements.txt" \
    || fail "pip install -r requirements.txt failed (see above)"
  # Re-verify after install — catches a silent partial install.
  if ! sudo -u "$RUN_USER" "$INSTALL_DIR/src/.venv/bin/python3" \
       -c "import uvicorn, fastapi, websockets, loguru" 2>/dev/null; then
    fail "venv install completed but key deps still not importable — rerun with verbose pip"
  fi
  ok "created venv + installed requirements.txt + verified deps"
  RESTART_RELAY=1
fi
fi  # MODE == self-hosted (closes step 3 self-hosted branch)

# ─── 4. Install agentkeys-mcp-server via `cargo install --git` ───────
# Canonical install path (per #134 — until M6 ships GH Releases + a
# native installer). Pulls from public GitHub, builds, places binary at
# a user-writable cache, then sudo-installs to /usr/local/bin/.
#
# Override repo/rev for development (e.g. testing a PR branch):
#   AGENTKEYS_REPO_URL=https://github.com/me/agentKeys.git \
#   AGENTKEYS_REV=my-pr-branch bash scripts/setup-mcp-host.sh
head "4/9 build agentkeys-mcp-server (cached workspace build)"

command -v cargo >/dev/null 2>&1 \
  || fail "cargo not found — install Rust first (curl https://sh.rustup.rs | sh -s -- -y)"
# Build IN the on-host repo checkout ($REPO_ROOT, e.g. /opt/agentkeys-src) using
# its PERSISTENT target/ — NOT `cargo install --git`, which re-clones + builds
# the ENTIRE dep tree in a throwaway target every run (a ~10–20 min COLD build
# on the t3.medium broker). setup-broker-host.sh already compiled
# aws-sdk/tokio/k256/etc. into this same target/release, and the target persists
# across re-runs, so `cargo build -p` is INCREMENTAL — only the mcp-server crate
# recompiles (seconds–2 min). Same cached-build approach as setup-broker-host.sh
# and harness/phase1-wire-demo.sh. ($REPO_ROOT was already checked out to the
# desired ref by the caller, so no separate `--git` fetch is needed; we build the
# code that's actually here.)
ok "cargo build --release -p agentkeys-mcp-server (in $REPO_ROOT, reusing the target/release cache)"
( cd "$REPO_ROOT" && cargo build --release --locked -p agentkeys-mcp-server ) \
  || fail "cargo build -p agentkeys-mcp-server failed in $REPO_ROOT"

CACHED_BIN="$REPO_ROOT/target/release/agentkeys-mcp-server"
if [ ! -x "$CACHED_BIN" ]; then
  fail "$CACHED_BIN not built (cargo build did not produce it)"
fi

src_sha=$(sha256sum "$CACHED_BIN" | awk '{print $1}')
dst_sha=$(sudo sha256sum "$MCP_BIN_DST" 2>/dev/null | awk '{print $1}' || echo "missing")
if [ "$src_sha" = "$dst_sha" ]; then
  skip "$MCP_BIN_DST already up to date (sha256 $src_sha)"
else
  sudo install -m 0755 "$CACHED_BIN" "$MCP_BIN_DST"
  ok "installed $MCP_BIN_DST (sha256 $src_sha)"
  RESTART_MCP=1
fi

# ─── 5. /etc/agentkeys/mcp.env ───────────────────────────────────────
head "5/9 /etc/agentkeys/mcp.env"
if [ "$MODE" = "xiaozhi" ]; then
  want_env=$(cat <<EOF
# Generated by scripts/setup-mcp-host.sh (mode=xiaozhi) — DO NOT HAND-EDIT.
# Endpoint URL persisted at ${XIAOZHI_ENDPOINT_FILE}.
MCP_TRANSPORT=mcp-endpoint
MCP_BACKEND=http
MCP_ENDPOINT=${XIAOZHI_ENDPOINT}
AGENTKEYS_BROKER_URL=https://broker.litentry.org
AGENTKEYS_MEMORY_URL=https://memory.litentry.org
AGENTKEYS_AUDIT_URL=https://audit.litentry.org
AGENTKEYS_CRED_URL=https://cred.litentry.org
EOF
)
else
  want_env=$(cat <<EOF
# Generated by scripts/setup-mcp-host.sh (mode=self-hosted) — DO NOT HAND-EDIT.
# Backed by ${TOKEN_FILE} + ${HEALTH_KEY_FILE}.
MCP_TRANSPORT=mcp-endpoint
MCP_BACKEND=http
MCP_ENDPOINT=ws://127.0.0.1:${RELAY_PORT}/mcp_endpoint/mcp/?token=${TOKEN}
# These four are placeholders — paste the live broker / worker URLs in
# after running setup-broker-host.sh on the same host.
AGENTKEYS_BROKER_URL=https://broker.litentry.org
AGENTKEYS_MEMORY_URL=https://memory.litentry.org
AGENTKEYS_AUDIT_URL=https://audit.litentry.org
AGENTKEYS_CRED_URL=https://cred.litentry.org
EOF
)
fi
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
RELAY_UNIT_PATH=/etc/systemd/system/mcp-endpoint-server.service
MCP_UNIT_PATH=/etc/systemd/system/agentkeys-mcp-server.service

if [ "$MODE" = "self-hosted" ]; then
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
  got=$(sudo cat "$RELAY_UNIT_PATH" 2>/dev/null || true)
  if [ "$want_relay_unit" = "$got" ]; then
    skip "${RELAY_UNIT_PATH##*/} already up to date"
  else
    printf '%s\n' "$want_relay_unit" | sudo tee "$RELAY_UNIT_PATH" >/dev/null
    ok "wrote ${RELAY_UNIT_PATH##*/}"
    DAEMON_RELOAD=1
    RESTART_RELAY=1
  fi
  MCP_UNIT_AFTER="network-online.target mcp-endpoint-server.service"
  MCP_UNIT_WANTS="network-online.target mcp-endpoint-server.service"
else
  head "6/9 systemd unit (agentkeys-mcp-server only — xiaozhi mode)"
  # Stop + disable any leftover self-hosted relay unit so we don't waste
  # resources or expose a half-configured port.
  if sudo test -f "$RELAY_UNIT_PATH"; then
    if sudo systemctl is-active --quiet mcp-endpoint-server.service 2>/dev/null; then
      sudo systemctl stop mcp-endpoint-server.service
      ok "stopped leftover mcp-endpoint-server.service (xiaozhi mode)"
    fi
    if sudo systemctl is-enabled --quiet mcp-endpoint-server.service 2>/dev/null; then
      sudo systemctl disable mcp-endpoint-server.service >/dev/null 2>&1 || true
      ok "disabled mcp-endpoint-server.service (xiaozhi mode)"
    fi
  fi
  MCP_UNIT_AFTER="network-online.target"
  MCP_UNIT_WANTS="network-online.target"
fi

want_mcp_unit=$(cat <<EOF
[Unit]
Description=AgentKeys MCP server (xiaozhi MCP-endpoint tool)
After=${MCP_UNIT_AFTER}
Wants=${MCP_UNIT_WANTS}

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${ENV_FILE_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${MCP_BIN_DST}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
)
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

if [ "$MODE" = "self-hosted" ]; then
  sudo systemctl enable mcp-endpoint-server.service >/dev/null 2>&1 || true
fi
sudo systemctl enable agentkeys-mcp-server.service >/dev/null 2>&1 || true

if [ "$MODE" = "self-hosted" ]; then
  if [ "${RESTART_RELAY:-0}" = "1" ]; then
    sudo systemctl restart mcp-endpoint-server.service
    ok "restarted mcp-endpoint-server.service"
  else
    sudo systemctl start mcp-endpoint-server.service 2>/dev/null || true
  fi
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
  if [ "$MODE" = "xiaozhi" ]; then
    skip "xiaozhi mode — xiaozhi.me terminates TLS, no local nginx needed"
  else
    skip "--without-nginx; skipping vhost"
  fi
fi

# ─── 8. certbot cert (idempotent: reuses existing) ───────────────────
# The DNS A record for $DOMAIN is provisioned by scripts/setup-cloud.sh
# step 6 (same Route53 batch as the broker / signer / worker subdomains).
# This step polls the public resolver and skips gracefully if DNS isn't
# yet live, with a clear pointer to run setup-cloud.sh first.
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

    # Single-shot DNS check (no wait). Use `command head` to bypass the
    # head() function we define for ==> step headers — without that the
    # pipeline reads `head -1` as a function call with arg "-1" and
    # prints garbage like `==> -1`.
    DNS_IP=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | command head -n 1)
    [ -z "$DNS_IP" ] && DNS_IP=$(dig +short A "$DOMAIN" 2>/dev/null | command head -n 1)
    [ -z "$DNS_IP" ] && DNS_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk 'NR==1 {print $1}')

    DNS_OK="yes"
    if [ -z "$DNS_IP" ]; then
      DNS_OK="no"
      echo "    DNS A record for ${DOMAIN} not visible right now." >&2
      echo "    ACTION: provision DNS by running on the operator workstation:" >&2
      echo "      set -a && source scripts/operator-workstation.env && set +a" >&2
      echo "      bash scripts/setup-cloud.sh --env-file scripts/operator-workstation.env --only-step 6" >&2
      echo "    For the test env, use scripts/operator-workstation.test.env + --test." >&2
      echo "    Then re-run this script (TTL 300 → ~5 min for resolvers to refresh)." >&2
      skip "cert deferred — DNS A record for ${DOMAIN} not yet live"
    else
      ok "DNS resolved: ${DOMAIN} → ${DNS_IP}"
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
else
  head "8/9 certbot certificate"
  if [ "$MODE" = "xiaozhi" ]; then
    skip "xiaozhi mode — xiaozhi.me's cert covers api.xiaozhi.me; no local cert needed"
  else
    skip "--without-nginx or --without-certbot; no cert"
  fi
fi      # WITH_NGINX && WITH_CERTBOT

# ─── 9. nginx reload (only if drift) + post-checks ───────────────────
if [ "$MODE" = "self-hosted" ]; then
  head "9/9 nginx reload + post-checks"
  if [ "${RELOAD_NGINX:-0}" = "1" ]; then
    sudo nginx -t
    sudo systemctl reload nginx
    ok "reloaded nginx"
  else
    skip "no nginx drift, no reload"
  fi

  # Probe the local relay via 127.0.0.1. Retry a few times — `systemctl
  # restart` returns as soon as the process is forked; uvicorn + fastapi
  # need ~1-3s to bind the port. We poll for up to 15s.
  relay_ok="no"
  relay_probe_path=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf "http://127.0.0.1:${RELAY_PORT}/mcp_endpoint/health?key=${HEALTH_KEY}" >/dev/null 2>&1; then
      relay_ok="yes"; relay_probe_path="/mcp_endpoint/health"; break
    elif curl -sf "http://127.0.0.1:${RELAY_PORT}/" >/dev/null 2>&1; then
      relay_ok="yes"; relay_probe_path="/"; break
    fi
    sleep 1.5
  done

  if [ "$relay_ok" = "yes" ]; then
    ok "local relay reachable on 127.0.0.1:${RELAY_PORT} (probe ${relay_probe_path})"
  else
    echo >&2
    echo "    --- diagnostics: mcp-endpoint-server didn't bind 127.0.0.1:${RELAY_PORT} in 15s ---" >&2
    echo "    systemctl status:" >&2
    sudo systemctl status mcp-endpoint-server.service --no-pager --lines=0 2>&1 | sed 's/^/      /' >&2 || true
    echo "    last 30 journal lines:" >&2
    sudo journalctl -u mcp-endpoint-server.service -n 30 --no-pager 2>&1 | sed 's/^/      /' >&2 || true
    echo "    listening tcp sockets:" >&2
    (sudo ss -tlnp 2>/dev/null || sudo netstat -tlnp 2>/dev/null || true) | sed 's/^/      /' >&2
    echo "    config file (${INSTALL_DIR}/src/mcp-endpoint-server.cfg):" >&2
    sudo cat "$INSTALL_DIR/src/mcp-endpoint-server.cfg" 2>&1 | sed 's/^/      /' >&2 || true
    echo "    --- end diagnostics ---" >&2
    echo >&2
    fail "relay not responding on 127.0.0.1:${RELAY_PORT} after 15s (see diagnostics above)"
  fi

  # Don't require external DNS in the post-check — the operator may have
  # only just pointed mcp.litentry.org at this host.
  echo "    nginx vhost wired for ${DOMAIN}. Verify externally once DNS A record is live:" >&2
  echo "      curl -sf https://${DOMAIN}/mcp_endpoint/health?key=${HEALTH_KEY}" >&2
else
  # Xiaozhi mode — no nginx, no local relay. Check that agentkeys-mcp-server
  # is up and connecting to the cloud endpoint. The journal log will show
  # `mcp-endpoint: connected; awaiting MCP frames` once paired.
  head "9/9 agentkeys-mcp-server post-check (xiaozhi mode)"
  mcp_ok="no"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if sudo systemctl is-active --quiet agentkeys-mcp-server.service; then
      mcp_ok="yes"; break
    fi
    sleep 1.5
  done

  if [ "$mcp_ok" = "yes" ]; then
    ok "agentkeys-mcp-server.service is active"
    # Surface a few recent log lines so the operator sees the outbound
    # connect attempt (or any error) without having to journalctl by hand.
    echo "    recent log lines:" >&2
    sudo journalctl -u agentkeys-mcp-server.service -n 8 --no-pager 2>&1 | sed 's/^/      /' >&2 || true
  else
    echo >&2
    echo "    --- diagnostics: agentkeys-mcp-server.service didn't become active in 15s ---" >&2
    echo "    systemctl status:" >&2
    sudo systemctl status agentkeys-mcp-server.service --no-pager --lines=0 2>&1 | sed 's/^/      /' >&2 || true
    echo "    last 30 journal lines:" >&2
    sudo journalctl -u agentkeys-mcp-server.service -n 30 --no-pager 2>&1 | sed 's/^/      /' >&2 || true
    echo "    env file (${ENV_FILE}):" >&2
    sudo cat "$ENV_FILE" 2>&1 | sed 's/^/      /' >&2 || true
    echo "    --- end diagnostics ---" >&2
    echo >&2
    fail "agentkeys-mcp-server didn't start (see diagnostics above)"
  fi
fi

echo
head "ready"
if [ "$MODE" = "xiaozhi" ]; then
  echo "    MODE: xiaozhi (xiaozhi.me hosts the MCP-endpoint relay)" >&2
  echo "    Endpoint (this MCP server connects out to):" >&2
  echo "      ${XIAOZHI_ENDPOINT}" >&2
  echo >&2
  echo "    Endpoint persisted at ${XIAOZHI_ENDPOINT_FILE} (0600)." >&2
  echo "    Re-runs preserve it; pass --xiaozhi-endpoint <URL> to update." >&2
  echo >&2
  echo "    Refresh 智控台 → 智能体 → MCP接入点 — status should flip from" >&2
  echo "    '未连接' to '已连接' within ~5 seconds." >&2
else
  echo "    MODE: self-hosted (mcp-endpoint-server running locally)" >&2
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
fi
