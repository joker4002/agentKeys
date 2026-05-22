#!/usr/bin/env bash
# AgentKeys broker-host setup — single idempotent entry point.
#
# Bootstraps a fresh broker host AND re-deploys changes onto an existing
# one. Auto-detects which case it is by reading the existing systemd unit's
# Environment= lines, so `bash scripts/setup-broker-host.sh --yes` is a
# valid full re-deploy after a `git pull`.
#
# Per CLAUDE.md, ALL remote-host changes (binary upgrades, systemd edits,
# env tweaks, nginx/certbot wiring, mock-server redeploys) go through this
# script — no ad-hoc systemctl edits, no hand-built scp.
#
# Usage: bash scripts/setup-broker-host.sh [--help]
#   Interactive when stdin is a TTY; pass --yes to skip the confirm.
#   Pass --ref <branch-or-tag> to opt into an in-script git fetch+pull;
#   otherwise builds whatever is currently checked out.
#
# Out of scope (operator does these by hand): DNS A records, AWS IAM
# role/policy creation, first-time cert issuance (see §7 manual steps),
# firewall rules.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
ISSUER_URL=""
ACCOUNT_ID=""
REGION="us-east-1"
CRED_MODE=""                 # set by interactive prompt or --cred-mode
PROFILE_NAME="agentkeys-daemon"
WITH_NGINX="yes"             # default: install + configure nginx (opt out via --without-nginx)
WITH_CERTBOT="yes"           # default: install certbot (opt out via --without-certbot)
ASSUME_YES=false
TEST_MODE=false              # --test: suffix every derived hostname + bucket with "-test"
                             # so a single flag replaces the 8 explicit
                             # --signer-host / --vault-bucket / --email-from / etc.
                             # overrides for the test broker.
PULL_REF=""                  # --ref <branch-or-tag>: opt-in git fetch+checkout+pull
SIGNER_HOST=""               # --signer-host: hostname for the dedicated signer listener
AUDIT_HOST=""                # --audit-host: hostname for tier-A audit-relay worker (default audit.<zone>)
EMAIL_HOST=""                # --email-host: hostname for email-service worker (default email.<zone>)
CRED_HOST=""                 # --cred-host:  hostname for credentials-service worker (default cred.<zone>)
MEMORY_HOST=""               # --memory-host: hostname for memory-service worker (default memory.<zone>)
# Chain + bucket overrides for the credentials + memory workers. Defaults
# target Heima Mainnet (production chain) with addresses pulled from
# scripts/operator-workstation.env. Pass --chain-rpc / --vault-bucket /
# --memory-bucket / --scope-addr / --registry-addr / --k3-counter-addr
# to override per-host (e.g. when running against a fork or testnet).
CHAIN_RPC=""
VAULT_BUCKET=""
MEMORY_BUCKET=""
SCOPE_ADDR=""
REGISTRY_ADDR=""
K3_COUNTER_ADDR=""
WITH_WORKERS="yes"           # --without-workers: skip build+install of the 4 service workers (audit/email/cred/memory)
CLEAN_BROKER="auto"          # --clean: force `cargo clean -p` first; auto = self-heal only on assertion miss
# Verified SES sender for email-link auth. Operator must register this
# identity via scripts/ses-verify-sender.sh BEFORE booting the broker;
# the broker's verify_sender_ready precheck calls SES GetEmailIdentity
# on this address at startup and refuses to boot if not verified.
# Default targets the demo's bots.litentry.org subdomain. Override via:
#   - --email-from <addr> CLI flag
#   - BROKER_EMAIL_FROM_ADDRESS env var (also persisted in
#     scripts/operator-workstation.env so a sourced env passes through)
BROKER_EMAIL_FROM_ADDRESS="${BROKER_EMAIL_FROM_ADDRESS:-noreply-test@bots.litentry.org}"

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
    --without-nginx)      WITH_NGINX="no"; shift ;;
    --without-certbot)    WITH_CERTBOT="no"; shift ;;
    --non-interactive)    INTERACTIVE=false; shift ;;
    --interactive)        INTERACTIVE=true; shift ;;
    --yes|-y)             ASSUME_YES=true; shift ;;
    --upgrade|--skip-pull) shift ;;        # back-compat no-ops (script is idempotent; --ref drives any pull)
    --ref)                PULL_REF="$2"; shift 2 ;;
    --test)               TEST_MODE=true; shift ;;
    --signer-host)        SIGNER_HOST="$2"; shift 2 ;;
    --audit-host)         AUDIT_HOST="$2"; shift 2 ;;
    --email-host)         EMAIL_HOST="$2"; shift 2 ;;
    --cred-host)          CRED_HOST="$2"; shift 2 ;;
    --memory-host)        MEMORY_HOST="$2"; shift 2 ;;
    --chain-rpc)          CHAIN_RPC="$2"; shift 2 ;;
    --vault-bucket)       VAULT_BUCKET="$2"; shift 2 ;;
    --memory-bucket)      MEMORY_BUCKET="$2"; shift 2 ;;
    --scope-addr)         SCOPE_ADDR="$2"; shift 2 ;;
    --registry-addr)      REGISTRY_ADDR="$2"; shift 2 ;;
    --k3-counter-addr)    K3_COUNTER_ADDR="$2"; shift 2 ;;
    --without-workers)    WITH_WORKERS="no"; shift ;;
    --email-from)         BROKER_EMAIL_FROM_ADDRESS="$2"; shift 2 ;;
    --clean)              CLEAN_BROKER="yes"; shift ;;
    --no-clean)           CLEAN_BROKER="no"; shift ;;
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
#
# Every conditional below uses `if`/`fi` (not `[[ ]] && cmd`) because under
# `set -e` a top-level `[[ false ]] && cmd` exits the whole script — a
# well-known bash gotcha that bit a previous iteration of this block.
EXISTING_UNIT=/etc/systemd/system/agentkeys-broker.service
if [[ -f "$EXISTING_UNIT" ]]; then
  log "Detected existing broker unit at $EXISTING_UNIT — reading config"
  # `|| true` on every grep so a missing key returns empty under set -e+pipefail
  # instead of killing the script.
  read_unit_env() {
    local key="$1"
    { sudo grep -E "^Environment=${key}=" "$EXISTING_UNIT" 2>/dev/null \
        | head -1 \
        | sed -E "s/^Environment=${key}=//"; } || true
  }
  if [[ -z "$ISSUER_URL" ]]; then
    ISSUER_URL="$(read_unit_env BROKER_OIDC_ISSUER)"
  fi
  if [[ -z "$ACCOUNT_ID" ]]; then
    ACCOUNT_ID="$(read_unit_env ACCOUNT_ID)"
  fi
  EXISTING_REGION="$(read_unit_env REGION)"
  if [[ -n "$EXISTING_REGION" ]]; then
    REGION="$EXISTING_REGION"
  fi

  # Cred mode inference. After issue #71 the recommended default is "none"
  # (broker mints via AssumeRoleWithWebIdentity which is JWT-authenticated;
  # no AWS principal needed at runtime). The only signal we can read from
  # the unit is whether AWS_PROFILE is set. So:
  #   - profile mode: Environment=AWS_PROFILE=<name> present
  #   - everything else: default to "none"
  EXISTING_PROFILE="$(read_unit_env AWS_PROFILE)"
  if [[ -z "$CRED_MODE" ]]; then
    if [[ -n "$EXISTING_PROFILE" ]]; then
      CRED_MODE="profile"
      PROFILE_NAME="$EXISTING_PROFILE"
    else
      CRED_MODE="none"
    fi
  fi
  log "  detected: ISSUER_URL=${ISSUER_URL:-(unset)}  ACCOUNT_ID=${ACCOUNT_ID:-(unset)}  REGION=$REGION  CRED_MODE=$CRED_MODE"
fi

# Detect previously-configured worker overrides. Keeps re-runs idempotent:
# operator who passed `--chain-rpc https://devnet.example` on a first run
# can re-run with no flags and the worker env files keep their first-run
# values instead of resetting to the hardcoded defaults.
read_envfile_var() {
  local env_file="$1" key="$2"
  sudo test -f "$env_file" || return 0
  sudo grep -E "^${key}=" "$env_file" 2>/dev/null | head -1 | sed -E "s/^${key}=//" || true
}
if [[ -z "$CHAIN_RPC" ]]; then
  CHAIN_RPC="$(read_envfile_var /etc/agentkeys/worker-creds.env AGENTKEYS_CHAIN_RPC_HTTP)"
fi
if [[ -z "$VAULT_BUCKET" ]]; then
  VAULT_BUCKET="$(read_envfile_var /etc/agentkeys/worker-creds.env VAULT_BUCKET)"
fi
if [[ -z "$MEMORY_BUCKET" ]]; then
  MEMORY_BUCKET="$(read_envfile_var /etc/agentkeys/worker-memory.env MEMORY_BUCKET)"
fi
if [[ -z "$SCOPE_ADDR" ]]; then
  SCOPE_ADDR="$(read_envfile_var /etc/agentkeys/worker-creds.env SCOPE_CONTRACT_ADDRESS_HEIMA)"
fi
if [[ -z "$REGISTRY_ADDR" ]]; then
  REGISTRY_ADDR="$(read_envfile_var /etc/agentkeys/worker-memory.env SIDECAR_REGISTRY_ADDRESS_HEIMA)"
fi
if [[ -z "$K3_COUNTER_ADDR" ]]; then
  K3_COUNTER_ADDR="$(read_envfile_var /etc/agentkeys/worker-memory.env K3_EPOCH_COUNTER_ADDRESS_HEIMA)"
fi

# ─── Optional git pull (--ref, opt-in) ────────────────────────────────────────
# Default behavior: build whatever is currently checked out. The operator is
# expected to git-pull themselves before invoking the script if they want a
# fresh tree. Pass --ref <branch-or-tag> to opt into an in-script pull —
# useful for unattended CI redeploys. --skip-pull / --upgrade are back-compat no-ops.
if [[ -n "$PULL_REF" ]]; then
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

  # Region / cred-mode / nginx / certbot are NOT prompted on a remote-host
  # re-deploy. They have sensible silent defaults:
  #   region      = us-east-1 (or whatever was in the unit / --region flag)
  #   cred-mode   = none      (post-issue-#71 broker is creds-free; --cred-mode
  #                            instance-profile|profile to opt out)
  #   nginx       = yes       (default — runbook always wants the broker +
  #                            signer vhosts; --without-nginx to opt out
  #                            when fronting via ALB / Cloudflare / pre-existing nginx)
  #   certbot     = yes       (default — needed for Let's Encrypt issuance;
  #                            --without-certbot to opt out)
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
[[ -n "$CRED_MODE" ]]  || CRED_MODE="none"
case "$CRED_MODE" in
  none|instance-profile|profile) ;;
  *) die "--cred-mode must be one of: none, instance-profile, profile (got $CRED_MODE)";;
esac
# nginx + certbot default to yes; --without-nginx / --without-certbot opts out.
# (Runbook docs/cloud-setup.md §5 + §6 always want both on a fresh broker host.)

ISSUER_HOST="${ISSUER_URL#https://}"
ISSUER_HOST="${ISSUER_HOST#http://}"
ISSUER_HOST="${ISSUER_HOST%%/*}"

# Derive companion hostnames from ISSUER_HOST when not supplied explicitly.
# Convention: if ISSUER_HOST is "broker.foo.com", signer host is "signer.foo.com",
# audit/email/cred/memory hosts are "audit.foo.com" / "email.foo.com" / etc.
# If ISSUER_HOST has no dots (unlikely), fall back to "<label>.${ISSUER_HOST}".
ISSUER_ZONE="${ISSUER_HOST#*.}"   # everything after the first label

# --test mode appends "-test" to every derived hostname/bucket/email so
# a single flag swaps prod ↔ test without 8 explicit overrides. The
# operator can still override any individual flag (e.g. --vault-bucket)
# and that wins.
if [[ "$TEST_MODE" == "true" ]]; then
  SUFFIX="-test"
else
  SUFFIX=""
fi

if [[ "$ISSUER_ZONE" == "$ISSUER_HOST" ]]; then
  # No dot — single-label hostname (dev/localhost). Prefix with "<label>.".
  derive_companion() { echo "${1}${SUFFIX}.${ISSUER_HOST}"; }
else
  derive_companion() { echo "${1}${SUFFIX}.${ISSUER_ZONE}"; }
fi
if [[ -z "$SIGNER_HOST" ]]; then
  SIGNER_HOST="$(derive_companion signer)"
  warn "Derived signer hostname: $SIGNER_HOST  (pass --signer-host to override)"
fi
if [[ -z "$AUDIT_HOST"  ]]; then AUDIT_HOST="$(derive_companion audit)";  fi
if [[ -z "$EMAIL_HOST"  ]]; then EMAIL_HOST="$(derive_companion email)";  fi
if [[ -z "$CRED_HOST"   ]]; then CRED_HOST="$(derive_companion cred)";    fi
if [[ -z "$MEMORY_HOST" ]]; then MEMORY_HOST="$(derive_companion memory)";fi

# Service-worker defaults (dev-only co-location on the broker host).
# Production will split each service to its own machine + IAM principal;
# see CLAUDE.md "for production, we will isolate all the services".
[[ -z "$CHAIN_RPC" ]]       && CHAIN_RPC="https://rpc.heima-parachain.heima.network"
[[ -z "$VAULT_BUCKET" ]]    && VAULT_BUCKET="agentkeys-vault${SUFFIX}-${ACCOUNT_ID}"
[[ -z "$MEMORY_BUCKET" ]]   && MEMORY_BUCKET="agentkeys-memory${SUFFIX}-${ACCOUNT_ID}"
# Test mode flips the email-from default to the -test subdomain too
# (operator can still override via --email-from).
if [[ "$TEST_MODE" == "true" ]] && [[ "$BROKER_EMAIL_FROM_ADDRESS" == "noreply-test@bots.litentry.org" ]]; then
  BROKER_EMAIL_FROM_ADDRESS="noreply-test@bots-test.${ISSUER_ZONE}"
fi
# Contract addresses pulled from operator-workstation.env on Heima Mainnet.
# Source the repo-committed env file so a fresh broker host inherits the
# same canonical addresses as the operator laptop (no manual sync needed).
if [[ -f "$REPO_ROOT/scripts/operator-workstation.env" ]]; then
  # shellcheck disable=SC1091
  set -a; . "$REPO_ROOT/scripts/operator-workstation.env"; set +a
fi
[[ -z "$SCOPE_ADDR" ]]      && SCOPE_ADDR="${SCOPE_CONTRACT_ADDRESS_HEIMA:-}"
[[ -z "$REGISTRY_ADDR" ]]   && REGISTRY_ADDR="${SIDECAR_REGISTRY_ADDRESS_HEIMA:-}"
[[ -z "$K3_COUNTER_ADDR" ]] && K3_COUNTER_ADDR="${K3_EPOCH_COUNTER_ADDRESS_HEIMA:-}"

# ─── Summary + confirmation ──────────────────────────────────────────────────
cat <<EOF

── Summary ──
  Issuer URL  : $ISSUER_URL  (host: $ISSUER_HOST)
  Signer host : $SIGNER_HOST  (dedicated signer listener — fronts :8092)
  Audit host  : $AUDIT_HOST   (audit-relay worker — fronts :9092)
  Email host  : $EMAIL_HOST   (email-service worker — fronts :9093)
  Cred host   : $CRED_HOST    (credentials worker — fronts :9094)
  Memory host : $MEMORY_HOST  (memory worker — fronts :9095)
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
  • build agentkeys-worker-{audit,email,creds,memory} in release mode (skip with --without-workers)
  • install all binaries to /usr/local/bin
  • create the 'agentkeys' system user + /var/lib/agentkeys (mode 0700)
  • drop systemd units for backend + broker + signer + 4 service workers
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
# agentkeys-broker-server is built with `--features auth-email-link` so the
# /v1/auth/email/* routes are registered. Without the feature the broker
# returns 404 on /v1/auth/email/request and `agentkeys init --email` cannot
# work — see issue #80 and Pass 2 of Option B.
#
# CARGO FOOTGUN: the broker MUST be built in a SEPARATE cargo invocation
# from agentkeys-mock-server. With combined `-p A -p B --features pkg/feat`
# (or even `--features A/feat`) cargo silently DROPS the feature flag —
# the resulting binary is compiled with the broker's defaults only
# (auth-wallet-sig + audit-sqlite + wallet-keystore — NO auth-email-link),
# manifesting as `BOOT_FAIL: BROKER_AUTH_METHODS="email_link": unknown or
# feature-gated-out auth method` at startup. Verified empirically:
# `cargo build --message-format json` shows features=[…] with auth-email-link
# missing in the combined form, present in the separate form.
log "Building agentkeys-mock-server (release)"
( cd "$REPO_ROOT" && cargo build --release -p agentkeys-mock-server )

# Build agentkeys-broker-server with auth-email-link, asserting via
# cargo's --message-format=json output that the feature is actually
# enabled. Three modes for incremental-cache hygiene:
#
#   --clean       force `cargo clean -p agentkeys-broker-server --release`
#                 before the build (3-5min full rebuild).
#   --no-clean    never clean; trust incremental cache. Use when you
#                 KNOW the cache is good and want the fastest re-deploy.
#   (default)     auto: skip clean, run incremental build, ASSERT the
#                 feature is in cargo's reported feature set; if NOT,
#                 self-heal by running `cargo clean -p` and rebuilding
#                 ONCE. Failing again is a real environment bug (host
#                 .cargo/config.toml override, env-var pin, etc.) and
#                 the script dies with 5 specific things to check.
#
# Critical: stdout (NDJSON) and stderr (compiler progress / errors) MUST
# be redirected separately. Merging them with `2>&1` corrupts the NDJSON
# stream and jq dies on `Invalid numeric literal at line N column M`.
BUILD_JSON=$(mktemp); BUILD_ERR=$(mktemp)
trap 'rm -f "$BUILD_JSON" "$BUILD_ERR"' EXIT

build_broker_with_features() {
  log "Building agentkeys-broker-server (release, +auth-email-link)"
  ( cd "$REPO_ROOT" && cargo build --release \
      -p agentkeys-broker-server --features auth-email-link \
      --message-format=json ) > "$BUILD_JSON" 2> "$BUILD_ERR" \
    || { warn "cargo build failed — last 30 lines of stderr:"; tail -30 "$BUILD_ERR" >&2; die "build failed"; }
}

# Returns 0 if cargo reported auth-email-link in the bin artifact's
# features list, 1 otherwise. Sets ENABLED_FEATURES for diagnostics.
assert_feature_enabled() {
  ENABLED_FEATURES=$(jq -r '
    select(.reason=="compiler-artifact"
           and .target.name=="agentkeys-broker-server"
           and (.target.kind | index("bin")))
    | .features | join(",")
  ' "$BUILD_JSON" 2>/dev/null | tail -1)
  # Empty features list usually means cargo skipped the artifact line
  # (incremental: nothing to rebuild → no compiler-artifact emitted).
  # That's NOT a failure — the existing binary is fine. Treat as pass,
  # but only after verifying the binary actually exists on disk (a
  # manual `rm target/release/agentkeys-broker-server` would otherwise
  # let us proceed to `install` and fail there with a worse message).
  if [[ -z "$ENABLED_FEATURES" ]]; then
    if [[ -x "$REPO_ROOT/target/release/agentkeys-broker-server" ]]; then
      log "  cargo emitted no fresh artifact (incremental cache hit) — trusting existing binary"
      return 0
    fi
    warn "cargo emitted no fresh artifact but binary doesn't exist at target/release/agentkeys-broker-server"
    return 1
  fi
  log "  cargo reports features: $ENABLED_FEATURES"
  case ",$ENABLED_FEATURES," in
    *,auth-email-link,*) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ "$CLEAN_BROKER" == "yes" ]]; then
  log "cargo clean -p agentkeys-broker-server --release  (--clean requested)"
  ( cd "$REPO_ROOT" && cargo clean -p agentkeys-broker-server --release ) \
    || warn "cargo clean -p returned non-zero — continuing (may be a fresh tree)"
fi

build_broker_with_features

log "Verifying broker binary has auth-email-link compiled in"
if ! assert_feature_enabled && [[ "$CLEAN_BROKER" != "no" ]]; then
  warn "auth-email-link missing from cargo's reported features [$ENABLED_FEATURES]"
  warn "Self-healing: cargo clean -p + rebuild (one retry; ~3-5min)"
  warn "Pass --no-clean to disable self-heal, or --clean to skip this and clean upfront."
  ( cd "$REPO_ROOT" && cargo clean -p agentkeys-broker-server --release ) \
    || warn "cargo clean -p returned non-zero — continuing"
  build_broker_with_features
  if ! assert_feature_enabled; then
    die "cargo STILL did not enable auth-email-link after a clean rebuild.
   Reported features: [$ENABLED_FEATURES]
   The host environment is overriding feature resolution. Check:
     1. cat \$HOME/.cargo/config.toml  (any [build] / [profile.release.package] sections?)
     2. cat $REPO_ROOT/.cargo/config.toml  (workspace-level overrides?)
     3. env | grep -i cargo  (CARGO_BUILD_*, CARGO_FEATURE_*, CARGO_PROFILE_* vars?)
     4. which cargo + cargo --version  (multiple toolchains?)
     5. cat $REPO_ROOT/Cargo.lock | head -5  (committed lockfile drift?)
   Then file a repro for the issue tracker."
  fi
elif ! assert_feature_enabled; then
  # --no-clean explicitly requested: don't self-heal, just die.
  die "auth-email-link missing from cargo's reported features [$ENABLED_FEATURES] and --no-clean is set.
   Re-run without --no-clean (or with --clean) to let the script self-heal."
fi

# Belt-and-suspenders: nm symbol-table check (more reliable than strings,
# which on rustc 1.95 + Ubuntu binutils gives false negatives). WARN-only:
# cargo's JSON assertion above is the canonical gate; probe_or_die
# post-restart catches any actual runtime mismatch.
if command -v nm >/dev/null 2>&1; then
  email_symbols=$(nm "$REPO_ROOT/target/release/agentkeys-broker-server" 2>/dev/null \
    | grep -cE "register_email_link_routes|email_request|email_verify" \
    || true)
  if (( email_symbols > 0 )); then
    log "  nm sees $email_symbols email-link symbol(s) — feature is linked in"
  else
    warn "nm sees 0 email-link symbols, but cargo claims the feature is on."
    warn "Continuing — the post-restart /healthz probe will catch any real boot failure."
  fi
else
  log "  (nm not installed — skipping symbol-table sanity check)"
fi

# ─── 3. Install binaries (stop → backup → install → restart later) ──────────
# Stop both services before swap so the kernel isn't holding old inodes
# while we install new ones. Both stops are idempotent (no-op on fresh
# hosts where nothing's running yet).
log "Stopping agentkeys services (idempotent)"
# Workers first (they depend on broker), then signer, then broker, then backend.
for svc in agentkeys-worker-memory agentkeys-worker-creds agentkeys-worker-email agentkeys-worker-audit \
           agentkeys-signer agentkeys-broker agentkeys-backend; do
  sudo systemctl stop "$svc" 2>/dev/null || true
done

# Backup existing binaries → .bak so a failed install can be rolled back.
# Skip on fresh hosts where /usr/local/bin/agentkeys-* don't exist yet.
BACKUP_BINS=(agentkeys-mock-server agentkeys-broker-server)
if [[ "$WITH_WORKERS" == "yes" ]]; then
  BACKUP_BINS+=(agentkeys-worker-audit agentkeys-worker-email \
                agentkeys-worker-creds agentkeys-worker-memory)
fi
for bin in "${BACKUP_BINS[@]}"; do
  if [[ -x "/usr/local/bin/$bin" ]]; then
    log "Backing up /usr/local/bin/$bin → /usr/local/bin/$bin.bak"
    sudo cp -p "/usr/local/bin/$bin" "/usr/local/bin/$bin.bak"
  fi
done

# ─── 2b. Build service workers (audit + email + creds + memory) ─────────────
# Co-located on the broker host for dev (CLAUDE.md "for production, we will
# isolate all the services"). One cargo invocation builds all 4 in parallel.
if [[ "$WITH_WORKERS" == "yes" ]]; then
  log "Building service workers (audit + email + creds + memory, release)"
  ( cd "$REPO_ROOT" && cargo build --release \
      -p agentkeys-worker-audit \
      -p agentkeys-worker-email \
      -p agentkeys-worker-creds \
      -p agentkeys-worker-memory )
fi

log "Installing binaries to /usr/local/bin"
sudo install -m 0755 \
  "$REPO_ROOT/target/release/agentkeys-mock-server" \
  "$REPO_ROOT/target/release/agentkeys-broker-server" \
  /usr/local/bin/
if [[ "$WITH_WORKERS" == "yes" ]]; then
  sudo install -m 0755 \
    "$REPO_ROOT/target/release/agentkeys-worker-audit" \
    "$REPO_ROOT/target/release/agentkeys-worker-email" \
    "$REPO_ROOT/target/release/agentkeys-worker-creds" \
    "$REPO_ROOT/target/release/agentkeys-worker-memory" \
    /usr/local/bin/
fi

# ─── 4. System user + state dir ───────────────────────────────────────────────
if ! id -u agentkeys >/dev/null 2>&1; then
  log "Creating agentkeys system user"
  sudo useradd --system --home /var/lib/agentkeys --shell /usr/sbin/nologin agentkeys
fi
sudo install -d -m 0700 -o agentkeys -g agentkeys /var/lib/agentkeys

# Operator SSH login user (separate from the `agentkeys` daemon system
# user). Used by EC2 Instance Connect — the IAM ec2-instance-connect
# policy condition `ec2:osuser=agentkey` requires this exact username.
# Idempotent — re-running on a host where the user already exists is a no-op.
if ! id -u agentkey >/dev/null 2>&1; then
  log "Creating agentkey SSH login user (for EC2 Instance Connect)"
  sudo useradd --create-home --shell /bin/bash agentkey
  echo "agentkey ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/agentkey >/dev/null
  sudo chmod 0440 /etc/sudoers.d/agentkey
fi

# Ensure ec2-instance-connect is installed so sshd's AuthorizedKeysCommand
# can resolve the ephemeral keys pushed via aws ec2-instance-connect
# send-ssh-public-key. Recent Ubuntu AMIs include it; the install is a
# no-op when already present.
if ! [[ -x /usr/share/ec2-instance-connect/eic_run_authorized_keys ]]; then
  log "Installing ec2-instance-connect (required by ssh-broker.sh non-fallback path)"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y ec2-instance-connect >/dev/null \
      || warn "ec2-instance-connect install failed — SSH via Instance Connect will need manual fix"
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y ec2-instance-connect >/dev/null \
      || warn "ec2-instance-connect install failed — SSH via Instance Connect will need manual fix"
  else
    warn "unknown package manager — install ec2-instance-connect manually if SSH via Instance Connect fails"
  fi
fi

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

# ─── 4b. dev_key_service master secret (issue #74 step 1) ────────────────────
# The backend's /dev/derive-address and /dev/sign-message endpoints are
# gated by DEV_KEY_SERVICE_MASTER_SECRET (32 raw bytes hex-encoded). We
# persist it in /etc/agentkeys/dev-key-service.env so re-runs are
# idempotent — generating a fresh secret would invalidate every
# previously-derived wallet for every operator who ever auth'd.
#
# Path: /etc/agentkeys/dev-key-service.env, mode 0600, owner agentkeys.
# Format: a single `DEV_KEY_SERVICE_MASTER_SECRET=<64 hex>` line so it
# can be wired straight into the backend systemd unit via
# EnvironmentFile=. Issue #74 step 2 (TEE worker) will deprecate this
# path entirely — sealed-data inside the enclave replaces the file.
DEV_KEY_SERVICE_ENV_DIR=/etc/agentkeys
DEV_KEY_SERVICE_ENV_FILE=$DEV_KEY_SERVICE_ENV_DIR/dev-key-service.env

if ! sudo test -d "$DEV_KEY_SERVICE_ENV_DIR"; then
  sudo install -d -m 0755 "$DEV_KEY_SERVICE_ENV_DIR"
fi

if ! sudo test -s "$DEV_KEY_SERVICE_ENV_FILE"; then
  log "Generating DEV_KEY_SERVICE_MASTER_SECRET (first-time only — re-runs preserve it)"
  # Generate 32 raw bytes → hex. openssl is on every Ubuntu broker host
  # this script targets; if it ever isn't, we'd want to fail loud rather
  # than silently fall back to anything weaker, so we don't.
  TMP_SECRET=$(openssl rand -hex 32)
  if [[ ${#TMP_SECRET} -ne 64 ]]; then
    log "FATAL: openssl rand produced ${#TMP_SECRET}-char output, expected 64"
    exit 1
  fi
  sudo tee "$DEV_KEY_SERVICE_ENV_FILE" >/dev/null <<EOF
# Generated by setup-broker-host.sh — do NOT regenerate or every
# previously-derived wallet for every linked identity is invalidated.
# Issue #74 step 2 (TEE worker) replaces this with sealed-enclave data.
DEV_KEY_SERVICE_MASTER_SECRET=$TMP_SECRET
EOF
  sudo chown agentkeys:agentkeys "$DEV_KEY_SERVICE_ENV_FILE"
  sudo chmod 0600 "$DEV_KEY_SERVICE_ENV_FILE"
  unset TMP_SECRET
  log "  → wrote $DEV_KEY_SERVICE_ENV_FILE (mode 0600, owner agentkeys)"
else
  log "DEV_KEY_SERVICE_MASTER_SECRET already present at $DEV_KEY_SERVICE_ENV_FILE — preserving (re-runs are idempotent)"
fi

# ─── 4c. Service-worker env files (audit + email + creds + memory) ───────────
# Co-located with the broker for dev (CLAUDE.md "for production, we will
# isolate all the services"). Each worker gets its own EnvironmentFile under
# /etc/agentkeys/, mode 0600 for the two that carry secret KEK material.
#
# Idempotency: KEK secrets are auto-generated on FIRST RUN and preserved on
# every subsequent re-run — regenerating either would invalidate every
# previously-encrypted credential blob (worker-creds) or memory blob
# (worker-memory) in S3.
WORKER_AUDIT_ENV_FILE=$DEV_KEY_SERVICE_ENV_DIR/worker-audit.env
WORKER_EMAIL_ENV_FILE=$DEV_KEY_SERVICE_ENV_DIR/worker-email.env
WORKER_CREDS_ENV_FILE=$DEV_KEY_SERVICE_ENV_DIR/worker-creds.env
WORKER_MEMORY_ENV_FILE=$DEV_KEY_SERVICE_ENV_DIR/worker-memory.env

if [[ "$WITH_WORKERS" == "yes" ]]; then
  # audit + email: no secrets. Mode 0644 is fine; the values are public
  # config (bucket name, leaves dir). Rewrite on every run so bucket /
  # region overrides via --vault-bucket / --region take effect.
  log "Writing $WORKER_AUDIT_ENV_FILE"
  sudo tee "$WORKER_AUDIT_ENV_FILE" >/dev/null <<EOF
AGENTKEYS_WORKER_AUDIT_BIND=127.0.0.1:9092
AGENTKEYS_WORKER_AUDIT_LEAVES_DIR=/var/lib/agentkeys/audit-leaves
AGENTKEYS_WORKER_AUDIT_FLUSH_INTERVAL_SECS=300
EOF
  sudo chmod 0644 "$WORKER_AUDIT_ENV_FILE"
  sudo install -d -m 0750 -o agentkeys -g agentkeys /var/lib/agentkeys/audit-leaves

  log "Writing $WORKER_EMAIL_ENV_FILE"
  sudo tee "$WORKER_EMAIL_ENV_FILE" >/dev/null <<EOF
AGENTKEYS_WORKER_EMAIL_BIND=127.0.0.1:9093
AGENTKEYS_VAULT_BUCKET=$VAULT_BUCKET
AWS_REGION=$REGION
EOF
  sudo chmod 0644 "$WORKER_EMAIL_ENV_FILE"

  # creds + memory carry KEK secrets — mode 0600, owner agentkeys.
  # Pattern lifted from the dev_key_service.env block above.
  ensure_kek_env() {
    local env_file="$1" kek_var="$2"
    if ! sudo test -s "$env_file"; then return 1; fi
    # Re-extract the existing KEK so subsequent overwrites preserve it.
    sudo grep -E "^${kek_var}=" "$env_file" | head -1 | sed -E "s/^${kek_var}=//"
  }

  EXISTING_CREDS_KEK="$(ensure_kek_env "$WORKER_CREDS_ENV_FILE" AGENTKEYS_WORKER_KEK_HEX || true)"
  if [[ -z "$EXISTING_CREDS_KEK" ]]; then
    log "Generating AGENTKEYS_WORKER_KEK_HEX (first-time — re-runs preserve it)"
    EXISTING_CREDS_KEK=$(openssl rand -hex 32)
    [[ ${#EXISTING_CREDS_KEK} -eq 64 ]] || die "openssl rand produced unexpected length"
  else
    log "Preserving existing AGENTKEYS_WORKER_KEK_HEX (regen would invalidate every cred blob)"
  fi
  sudo tee "$WORKER_CREDS_ENV_FILE" >/dev/null <<EOF
# Auto-generated by setup-broker-host.sh.
# AGENTKEYS_WORKER_KEK_HEX is preserved across re-runs — regenerating would
# invalidate every credential blob already in S3. Stage 2 replaces this
# with an mTLS-derived KEK from the signer.
WORKER_BIND=127.0.0.1:9094
VAULT_BUCKET=$VAULT_BUCKET
AWS_REGION=$REGION
AGENTKEYS_CHAIN=heima
AGENTKEYS_CHAIN_RPC_HTTP=$CHAIN_RPC
SIDECAR_REGISTRY_ADDRESS_HEIMA=$REGISTRY_ADDR
SCOPE_CONTRACT_ADDRESS_HEIMA=$SCOPE_ADDR
K3_EPOCH_COUNTER_ADDRESS_HEIMA=$K3_COUNTER_ADDR
AGENTKEYS_WORKER_KEK_HEX=$EXISTING_CREDS_KEK
EOF
  sudo chown agentkeys:agentkeys "$WORKER_CREDS_ENV_FILE"
  sudo chmod 0600 "$WORKER_CREDS_ENV_FILE"

  EXISTING_MEMORY_KEK="$(ensure_kek_env "$WORKER_MEMORY_ENV_FILE" AGENTKEYS_MEMORY_KEK_HEX || true)"
  if [[ -z "$EXISTING_MEMORY_KEK" ]]; then
    log "Generating AGENTKEYS_MEMORY_KEK_HEX (first-time — re-runs preserve it)"
    EXISTING_MEMORY_KEK=$(openssl rand -hex 32)
    [[ ${#EXISTING_MEMORY_KEK} -eq 64 ]] || die "openssl rand produced unexpected length"
  else
    log "Preserving existing AGENTKEYS_MEMORY_KEK_HEX (regen would invalidate every memory blob)"
  fi
  sudo tee "$WORKER_MEMORY_ENV_FILE" >/dev/null <<EOF
# Auto-generated by setup-broker-host.sh.
# AGENTKEYS_MEMORY_KEK_HEX is preserved across re-runs — regenerating would
# invalidate every memory blob already in S3.
WORKER_BIND=127.0.0.1:9095
MEMORY_BUCKET=$MEMORY_BUCKET
AWS_REGION=$REGION
AGENTKEYS_CHAIN=heima
AGENTKEYS_CHAIN_RPC_HTTP=$CHAIN_RPC
SIDECAR_REGISTRY_ADDRESS_HEIMA=$REGISTRY_ADDR
SCOPE_CONTRACT_ADDRESS_HEIMA=$SCOPE_ADDR
K3_EPOCH_COUNTER_ADDRESS_HEIMA=$K3_COUNTER_ADDR
AGENTKEYS_MEMORY_KEK_HEX=$EXISTING_MEMORY_KEK
EOF
  sudo chown agentkeys:agentkeys "$WORKER_MEMORY_ENV_FILE"
  sudo chmod 0600 "$WORKER_MEMORY_ENV_FILE"
fi

# ─── 5. systemd units ─────────────────────────────────────────────────────────
log "Writing systemd units"

sudo tee /etc/systemd/system/agentkeys-backend.service >/dev/null <<EOF
[Unit]
Description=AgentKeys mock backend (session management + dev_key_service signer)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Issue #74 step 1: backend now serves /dev/derive-address +
# /dev/sign-message gated by DEV_KEY_SERVICE_MASTER_SECRET, which is
# loaded from this EnvironmentFile (managed by step 4b above).
EnvironmentFile=$DEV_KEY_SERVICE_ENV_FILE
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
Environment=BROKER_AWS_REGION=$REGION
Environment=BROKER_OIDC_ISSUER=$ISSUER_URL
# Email-link auth (Pass 2 of Option B — see crates/agentkeys-broker-server
# /src/plugins/auth/email_link.rs). Comma-separated method list now includes
# email_link; sender backend is the real aws-sdk-sesv2 SES sender. The
# verified FROM address is generated by scripts/ses-verify-sender.sh and
# pinned in scripts/operator-workstation.env (mirrored here).
Environment=BROKER_AUTH_METHODS=wallet_sig,email_link
Environment=BROKER_EMAIL_SENDER=ses
Environment=BROKER_EMAIL_FROM_ADDRESS=$BROKER_EMAIL_FROM_ADDRESS
# Chain RPC for cap-mint chain-verification (handlers/cap.rs reads
# AGENTKEYS_CHAIN_RPC_HTTP at request time to check device + scope +
# k3_epoch on chain before signing a cap-token). Without these, every
# /v1/cap/cred-{store,fetch} returns 502 "RPC URL not set" — surfaced
# in the stage-3 worker encrypt/decrypt roundtrip test (#90 followup).
Environment=AGENTKEYS_CHAIN=heima
Environment=AGENTKEYS_CHAIN_RPC_HTTP=https://rpc.heima-parachain.heima.network
# Contract addresses for cap-mint chain checks. handlers/cap.rs reads
# {SIDECAR_REGISTRY,SCOPE_CONTRACT,K3_EPOCH_COUNTER}_ADDRESS_HEIMA at
# request time to check device + scope + k3_epoch on chain before
# signing a cap-token. Values flow from scripts/operator-workstation.env
# (sourced earlier in this script) — keeps the laptop's contract
# registry as the single source of truth.
Environment=SIDECAR_REGISTRY_ADDRESS_HEIMA=$REGISTRY_ADDR
Environment=SCOPE_CONTRACT_ADDRESS_HEIMA=$SCOPE_ADDR
Environment=K3_EPOCH_COUNTER_ADDRESS_HEIMA=$K3_COUNTER_ADDR
$CRED_LINE
ExecStart=/usr/local/bin/agentkeys-broker-server --port 8091 --bind 127.0.0.1 \
  --export-session-pubkey-to /var/lib/agentkeys/.agentkeys/broker/session-keypair.pub.pem
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

# ── agentkeys-signer (issue #74 step 1b) ─────────────────────────────────────
# Dedicated signer listener (:8092, loopback only) — serves ONLY /dev/* and
# /healthz. Fronted publicly by signer.$SIGNER_HOST via nginx (:443).
# JWT bearer auth: verifies the broker's session JWT on every /dev/* request
# using the pubkey written by the broker at boot.
log "Writing agentkeys-signer.service"
sudo tee /etc/systemd/system/agentkeys-signer.service >/dev/null <<EOF
[Unit]
Description=AgentKeys signer (dev_key_service — issue #74 step 1b)
After=network-online.target agentkeys-broker.service
Wants=network-online.target
Requires=agentkeys-broker.service

[Service]
Type=simple
# Same master secret as the backend — loaded from the same EnvironmentFile.
# Issue #74 step 2 (TEE worker) will replace this.
EnvironmentFile=$DEV_KEY_SERVICE_ENV_FILE
ExecStart=/usr/local/bin/agentkeys-mock-server --signer-only --port 8092 \
  --broker-session-pubkey-path /var/lib/agentkeys/.agentkeys/broker/session-keypair.pub.pem
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

# ── agentkeys-worker-{audit,email,creds,memory} (dev co-location, issue #90) ─
# All 4 workers are co-located with the broker for development. Each binds
# to a loopback port and is fronted by nginx at its own subdomain:
#
#   audit.<zone>  → :9092  → /v1/audit/*  (tier-A Merkle relay)
#   email.<zone>  → :9093  → /v1/email/*  (SES send + inbox list)
#   cred.<zone>   → :9094  → /v1/cred/*   (credential blob CRUD)
#   memory.<zone> → :9095  → /v1/memory/* (long-term memory CRUD)
#
# Production will split each to its own EC2/IAM principal (CLAUDE.md
# "for production, we will isolate all the services for the security issue").
# The subdomain layout is the migration seam: when a service moves to its
# own host, only the A record changes — clients keep talking to the same
# URL.

if [[ "$WITH_WORKERS" == "yes" ]]; then
  log "Writing agentkeys-worker-audit.service"
  sudo tee /etc/systemd/system/agentkeys-worker-audit.service >/dev/null <<EOF
[Unit]
Description=AgentKeys audit-service worker (tier-A Merkle relay, arch.md §15.3)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$WORKER_AUDIT_ENV_FILE
ExecStart=/usr/local/bin/agentkeys-worker-audit
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

  log "Writing agentkeys-worker-email.service"
  sudo tee /etc/systemd/system/agentkeys-worker-email.service >/dev/null <<EOF
[Unit]
Description=AgentKeys email-service worker (arch.md §15.1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$WORKER_EMAIL_ENV_FILE
ExecStart=/usr/local/bin/agentkeys-worker-email --inbox-bucket \${AGENTKEYS_VAULT_BUCKET}
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

  # creds + memory need BROKER_CAP_PUBKEY_PEM (a multi-line PEM string),
  # which systemd EnvironmentFile= can't carry. Inject it via /bin/sh -c
  # that reads the broker's session-keypair.pub.pem (written at broker
  # boot) into the env var before exec'ing the binary.
  BROKER_CAP_PEM_PATH=/var/lib/agentkeys/.agentkeys/broker/session-keypair.pub.pem

  log "Writing agentkeys-worker-creds.service"
  sudo tee /etc/systemd/system/agentkeys-worker-creds.service >/dev/null <<EOF
[Unit]
Description=AgentKeys credentials-service worker (arch.md §15.4)
After=network-online.target agentkeys-broker.service
Wants=network-online.target
Requires=agentkeys-broker.service

[Service]
Type=simple
EnvironmentFile=$WORKER_CREDS_ENV_FILE
# BROKER_CAP_PUBKEY_PEM is a multi-line PEM — load it from the broker's
# session-pubkey export at start. Falls back to dying loud if the file
# isn't there (broker hasn't written it yet → upstream boot ordering bug).
ExecStart=/bin/sh -c 'export BROKER_CAP_PUBKEY_PEM="\$(cat $BROKER_CAP_PEM_PATH)" && [ -n "\$BROKER_CAP_PUBKEY_PEM" ] && exec /usr/local/bin/agentkeys-worker-creds'
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

  log "Writing agentkeys-worker-memory.service"
  sudo tee /etc/systemd/system/agentkeys-worker-memory.service >/dev/null <<EOF
[Unit]
Description=AgentKeys memory-service worker (arch.md §15.2)
After=network-online.target agentkeys-broker.service
Wants=network-online.target
Requires=agentkeys-broker.service

[Service]
Type=simple
EnvironmentFile=$WORKER_MEMORY_ENV_FILE
ExecStart=/bin/sh -c 'export BROKER_CAP_PUBKEY_PEM="\$(cat $BROKER_CAP_PEM_PATH)" && [ -n "\$BROKER_CAP_PUBKEY_PEM" ] && exec /usr/local/bin/agentkeys-worker-memory'
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
fi

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
  local signer_cert_path="/etc/letsencrypt/live/$SIGNER_HOST/fullchain.pem"
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

  # ── Signer nginx site (issue #74 step 1b) ────────────────────────────────
  # Separate virtual host for signer.$SIGNER_HOST → :8092 (loopback).
  # Only /dev/* and /healthz are proxied; everything else → 404 (defense-in-depth).
  if sudo test -f "$signer_cert_path"; then
    log "Writing nginx site for $SIGNER_HOST (HTTPS — LE cert detected)"
    sudo tee /etc/nginx/sites-available/agentkeys-signer >/dev/null <<EOF
server {
    listen 80;
    server_name $SIGNER_HOST;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $SIGNER_HOST;

    ssl_certificate     /etc/letsencrypt/live/$SIGNER_HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SIGNER_HOST/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Pass Authorization header so the signer can verify the bearer JWT.
    location /dev/ {
        proxy_pass http://127.0.0.1:8092;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header Authorization     \$http_authorization;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_read_timeout 30s;
    }
    location /healthz {
        proxy_pass http://127.0.0.1:8092;
    }
    # Reject everything else — signer serves only /dev/* and /healthz.
    location / {
        return 404;
    }
}
EOF
  else
    log "Writing nginx site for $SIGNER_HOST (HTTP-only — no LE cert yet)"
    log "After issuing the cert (see manual steps below), re-run this script."
    sudo tee /etc/nginx/sites-available/agentkeys-signer >/dev/null <<EOF
# HTTP-only initial config for the signer. To issue the cert:
#   sudo certbot --nginx -d $SIGNER_HOST
# then re-run scripts/setup-broker-host.sh to flip on the :443 block.
server {
    listen 80;
    server_name $SIGNER_HOST;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / {
        return 503 "TLS cert not yet issued for signer — see setup-broker-host.sh\n";
        default_type text/plain;
    }
}
EOF
  fi
}

# write_worker_nginx_site <slug> <host> <port>
#   Writes /etc/nginx/sites-available/agentkeys-worker-<slug>.
#   Flips A → B (HTTP-only → HTTPS) when /etc/letsencrypt/live/<host>/fullchain.pem
#   appears. All worker subdomains share the same proxy shape; the only
#   difference is the loopback port.
write_worker_nginx_site() {
  local slug="$1" host="$2" port="$3"
  local cert_path="/etc/letsencrypt/live/$host/fullchain.pem"
  local sitefile="/etc/nginx/sites-available/agentkeys-worker-$slug"
  if sudo test -f "$cert_path"; then
    log "Writing nginx site for $host (HTTPS — LE cert detected) → :$port"
    sudo tee "$sitefile" >/dev/null <<EOF
server {
    listen 80;
    server_name $host;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $host;

    ssl_certificate     /etc/letsencrypt/live/$host/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$host/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header Authorization     \$http_authorization;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_read_timeout 30s;
    }
}
EOF
  else
    log "Writing nginx site for $host (HTTP-only — no LE cert yet) → :$port"
    sudo tee "$sitefile" >/dev/null <<EOF
# HTTP-only initial config for $slug worker. To issue the cert:
#   sudo certbot certonly --webroot -w /var/www/certbot -d $host \\
#     --agree-tos -m <ops@your.org> --non-interactive
# then re-run scripts/setup-broker-host.sh to flip on the :443 block.
server {
    listen 80;
    server_name $host;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / {
        return 503 "TLS cert not yet issued for $slug — see setup-broker-host.sh\n";
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
  if [[ "$WITH_WORKERS" == "yes" ]]; then
    write_worker_nginx_site audit  "$AUDIT_HOST"  9092
    write_worker_nginx_site email  "$EMAIL_HOST"  9093
    write_worker_nginx_site cred   "$CRED_HOST"   9094
    write_worker_nginx_site memory "$MEMORY_HOST" 9095
  fi
  # Single point of enabling — one ln -sf per vhost (idempotent), default
  # vhost out of the way. Done here (not inside write_nginx_site) so the
  # symlinks aren't sprinkled across HTTPS / HTTP-only branches.
  if [[ -d /etc/nginx/sites-enabled ]]; then
    sudo ln -sf /etc/nginx/sites-available/agentkeys-broker /etc/nginx/sites-enabled/
    sudo ln -sf /etc/nginx/sites-available/agentkeys-signer /etc/nginx/sites-enabled/
    if [[ "$WITH_WORKERS" == "yes" ]]; then
      for slug in audit email cred memory; do
        sudo ln -sf "/etc/nginx/sites-available/agentkeys-worker-$slug" /etc/nginx/sites-enabled/
      done
    fi
    sudo rm -f /etc/nginx/sites-enabled/default
  fi
  if sudo nginx -t; then
    sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx
  else
    warn "nginx -t failed — leaving service in current state. Inspect /etc/nginx/sites-available/agentkeys-*."
  fi
fi

# ─── 7. certbot (optional) ────────────────────────────────────────────────────
if [[ "$WITH_CERTBOT" == "yes" ]] && ! have certbot; then
  log "Installing certbot"
  "${PM_INSTALL[@]}" certbot python3-certbot-nginx
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
CORE_UNITS=(agentkeys-backend agentkeys-broker agentkeys-signer)
WORKER_UNITS=()
if [[ "$WITH_WORKERS" == "yes" ]]; then
  WORKER_UNITS=(agentkeys-worker-audit agentkeys-worker-email \
                agentkeys-worker-creds agentkeys-worker-memory)
fi

log "daemon-reload + enable + restart core + worker services"
sudo systemctl daemon-reload
sudo systemctl enable "${CORE_UNITS[@]}" "${WORKER_UNITS[@]}"
# Start broker first so it writes the session pubkey PEM before the signer
# (and the creds/memory workers, which Requires=agentkeys-broker.service)
# start. Order: backend + broker → signer → workers.
sudo systemctl restart agentkeys-backend agentkeys-broker
# Brief pause to let broker write the pubkey file before signer + workers read it.
sleep 2
sudo systemctl restart agentkeys-signer
if (( ${#WORKER_UNITS[@]} > 0 )); then
  sudo systemctl restart "${WORKER_UNITS[@]}"
fi

sleep 2
sudo systemctl --no-pager --full status "${CORE_UNITS[@]}" "${WORKER_UNITS[@]}" || true

log "Recent broker logs (look for 'broker listening on 127.0.0.1:8091'):"
sudo journalctl -u agentkeys-broker -n 20 --no-pager || true
log "Loopback /healthz probes (polling up to 20s per service — services may be in restart-loop on bad config):"

# Poll-then-die-with-journal: a single 5s curl + warn was the silent-fail
# vector that hid Pass-2 boot crashes (e.g. binary built without
# --features auth-email-link → broker exits with BOOT_FAIL but the
# probe just shrugged and the operator declared the host healthy).
# Now: poll for 20s; on persistent failure, dump status + last 40 journal
# lines for that unit and `die` so the operator cannot move on.
probe_or_die() {
  local name="$1" port="$2" unit="$3"
  for attempt in $(seq 1 10); do
    if curl -sf --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
      log "  $name :$port /healthz ok (attempt $attempt)"
      return 0
    fi
    sleep 2
  done
  warn "$name :$port /healthz did not return 200 after 20s — dumping diagnostics"
  echo "── systemctl status $unit ─────────────────────────────────────────────────"
  sudo systemctl status "$unit" --no-pager -l | head -25 || true
  echo "── journalctl -u $unit -n 40 ─────────────────────────────────────────────"
  sudo journalctl -u "$unit" -n 40 --no-pager || true
  die "$name boot failed — see diagnostics above. Common causes:
   • BOOT_FAIL: BROKER_AUTH_METHODS=email_link with binary missing --features auth-email-link
       fix: rm -rf $REPO_ROOT/target/release/agentkeys-broker-server && re-run this script
   • BOOT_FAIL: BROKER_EMAIL_FROM_ADDRESS unset
       fix: export BROKER_EMAIL_FROM_ADDRESS or pass --email-from to this script
   • aws credentials not resolvable for SES sender
       fix: verify EC2 instance role has ses:SendEmail OR set BROKER_EMAIL_SENDER=stub"
}
probe_or_die broker  8091 agentkeys-broker
probe_or_die backend 8090 agentkeys-backend
probe_or_die signer  8092 agentkeys-signer
if [[ "$WITH_WORKERS" == "yes" ]]; then
  probe_or_die worker-audit  9092 agentkeys-worker-audit
  probe_or_die worker-email  9093 agentkeys-worker-email
  probe_or_die worker-creds  9094 agentkeys-worker-creds
  probe_or_die worker-memory 9095 agentkeys-worker-memory
fi

# ─── 9. Print remaining manual steps ──────────────────────────────────────────
cat <<EOF

================================================================================
  AgentKeys broker host bootstrap complete.
================================================================================
Status:
  • backend       systemd:     agentkeys-backend.service        (:8090, loopback)
  • broker        systemd:     agentkeys-broker.service         (:8091, loopback)
  • signer        systemd:     agentkeys-signer.service         (:8092, loopback)
  • worker-audit  systemd:     agentkeys-worker-audit.service   (:9092, loopback → $AUDIT_HOST)
  • worker-email  systemd:     agentkeys-worker-email.service   (:9093, loopback → $EMAIL_HOST)
  • worker-creds  systemd:     agentkeys-worker-creds.service   (:9094, loopback → $CRED_HOST)
  • worker-memory systemd:     agentkeys-worker-memory.service  (:9095, loopback → $MEMORY_HOST)
  • binaries:                  /usr/local/bin/agentkeys-{mock-server,broker-server,worker-{audit,email,creds,memory}}
  • state dir:                 /var/lib/agentkeys      (mode 0700, agentkeys:agentkeys)
  • audit DB will land at:     /var/lib/agentkeys/.agentkeys/broker/audit.sqlite
  • audit leaves dir:          /var/lib/agentkeys/audit-leaves (per-batch Merkle JSONL)
  • OIDC keypair will land at: /var/lib/agentkeys/.agentkeys/broker/oidc-keypair.json
  • session pubkey (signer):   /var/lib/agentkeys/.agentkeys/broker/session-keypair.pub.pem
                               (written by broker at boot; read by signer + workers for JWT auth)
  • worker env files:          /etc/agentkeys/worker-{audit,email,creds,memory}.env
                               (creds + memory carry KEK secrets — mode 0600)

What you still need to do by hand:

EOF

case "$CRED_MODE" in
  none)
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
    1. Add DNS A records (all point to this host's public IP):
         $ISSUER_HOST  → <public IP>
         $SIGNER_HOST  → <public IP>  (signer vhost)
         $AUDIT_HOST   → <public IP>  (audit-relay worker vhost)
         $EMAIL_HOST   → <public IP>  (email-service worker vhost)
         $CRED_HOST    → <public IP>  (credentials-service worker vhost)
         $MEMORY_HOST  → <public IP>  (memory-service worker vhost)
    2. Open port 443 on the host firewall (and 80 only for ACME challenges).
       Drop all ingress to :8090, :8091, :8092, :9092, :9093, :9094, :9095 except 127.0.0.1.
    3. Issue Let's Encrypt certs for every co-located vhost:
         for h in $SIGNER_HOST $AUDIT_HOST $EMAIL_HOST $CRED_HOST $MEMORY_HOST; do
           sudo certbot certonly --webroot -w /var/www/certbot -d "\$h" \\
             --agree-tos -m <ops@your.org> --non-interactive
         done
       Then re-run this script to flip nginx onto the :443 ssl block for each.
    4. Verify each worker is reachable end-to-end:
         curl -sS https://$SIGNER_HOST/healthz   # → "ok"
         curl -sS https://$AUDIT_HOST/healthz    # → "ok"
         curl -sS https://$EMAIL_HOST/healthz    # → "ok"
         curl -sS https://$CRED_HOST/healthz     # → JSON {"ok":true,...}
         curl -sS https://$MEMORY_HOST/healthz   # → JSON {"ok":true,...}

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
    curl -sS -o /dev/null -w 'HTTP %{http_code}\n' $ISSUER_URL/healthz        # expect: HTTP 200
    curl -sf $ISSUER_URL/.well-known/openid-configuration | jq '.issuer == "$ISSUER_URL"'
    curl -sf $ISSUER_URL/.well-known/jwks.json | jq '.keys[0].kid'
    curl -sS -o /dev/null -w 'HTTP %{http_code}\n' https://$SIGNER_HOST/healthz  # expect: HTTP 200 (after certbot)

  Then continue with docs/cloud-setup.md §4 "OIDC federation" to register
  the OIDC provider with AWS IAM and verify cloud-enforced isolation.

================================================================================
EOF
