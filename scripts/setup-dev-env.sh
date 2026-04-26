#!/usr/bin/env bash
# AgentKeys dev environment bootstrap for fresh macOS or Linux machines.
#
# Installs: rustup + stable toolchain, Node 20+, jj, jq, AWS CLI v2, then
# builds the Cargo workspace and the provisioner-scripts npm project.
#
#   bash scripts/setup-dev-env.sh
#
# Idempotent: re-run safely. Skips anything already installed at a usable
# version. Does NOT install Google Chrome (needed by the CDP demo) — install
# that manually from https://www.google.com/chrome/.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM=mac ;;
  Linux)  PLATFORM=linux ;;
  *) die "Unsupported OS: $OS (this script handles macOS + Linux only)" ;;
esac
log "Platform detected: $PLATFORM"

###############################################################################
# Package manager
###############################################################################
install_brew() {
  if ! have brew; then
    log "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
}

linux_pm() {
  if have apt-get; then echo apt
  elif have dnf; then echo dnf
  elif have pacman; then echo pacman
  else die "No supported Linux package manager (apt/dnf/pacman)"
  fi
}

if [[ "$PLATFORM" == mac ]]; then
  install_brew
  PM=brew
else
  PM="$(linux_pm)"
fi
log "Package manager: $PM"

pm_install() {
  case "$PM" in
    brew)   brew install "$@" ;;
    apt)    sudo apt-get update -y && sudo apt-get install -y "$@" ;;
    dnf)    sudo dnf install -y "$@" ;;
    pacman) sudo pacman -S --needed --noconfirm "$@" ;;
  esac
}

###############################################################################
# Core tools: curl, build essentials, jq
###############################################################################
log "Ensuring base build tools"
case "$PM" in
  apt)    pm_install curl build-essential pkg-config libssl-dev ca-certificates ;;
  dnf)    pm_install curl gcc gcc-c++ make pkgconf-pkg-config openssl-devel ca-certificates ;;
  pacman) pm_install curl base-devel openssl ca-certificates ;;
  brew)   : ;;
esac

if ! have jq; then
  log "Installing jq"
  pm_install jq
fi

###############################################################################
# Rust (rustup + stable)
###############################################################################
if ! have rustup; then
  log "Installing rustup + stable toolchain"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
else
  log "rustup already installed -- ensuring stable toolchain"
  rustup toolchain install stable >/dev/null
  rustup default stable >/dev/null
fi
have cargo || { source "$HOME/.cargo/env"; }
log "Rust: $(rustc --version)"

###############################################################################
# Node 20+
###############################################################################
node_major() { node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'; }

needs_node=true
if have node; then
  v="$(node_major)"
  if [[ -n "$v" && "$v" -ge 20 ]]; then
    needs_node=false
  fi
fi

if $needs_node; then
  log "Installing Node 20+"
  case "$PM" in
    brew)
      brew install node@20
      brew link --overwrite --force node@20 || true
      ;;
    apt)
      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
      sudo apt-get install -y nodejs
      ;;
    dnf)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash -
      sudo dnf install -y nodejs
      ;;
    pacman)
      pm_install nodejs npm
      ;;
  esac
fi
log "Node: $(node -v)  npm: $(npm -v)"

###############################################################################
# jj (Jujutsu)
###############################################################################
if ! have jj; then
  log "Installing jj (Jujutsu)"
  case "$PM" in
    brew)   brew install jj ;;
    pacman) pm_install jujutsu ;;
    apt|dnf)
      # No first-party packages on apt/dnf yet -- install via cargo.
      cargo install --locked jj-cli
      ;;
  esac
fi
log "jj: $(jj --version)"

# Identity required by CLAUDE.md global rules.
if ! jj config get user.name >/dev/null 2>&1; then
  log "Setting jj identity (Hanwen Cheng <heawen.cheng@gmail.com>)"
  jj config set --user user.name "Hanwen Cheng"
  jj config set --user user.email "heawen.cheng@gmail.com"
fi

###############################################################################
# AWS CLI v2
###############################################################################
if ! have aws; then
  log "Installing AWS CLI v2"
  case "$PLATFORM" in
    mac)
      brew install awscli
      ;;
    linux)
      tmp="$(mktemp -d)"
      arch="$(uname -m)"
      case "$arch" in
        x86_64)  awsurl="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
        aarch64|arm64) awsurl="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
        *) die "Unsupported Linux arch for AWS CLI: $arch" ;;
      esac
      have unzip || pm_install unzip
      curl -sSL "$awsurl" -o "$tmp/aws.zip"
      unzip -q "$tmp/aws.zip" -d "$tmp"
      sudo "$tmp/aws/install" --update
      rm -rf "$tmp"
      ;;
  esac
fi
log "AWS CLI: $(aws --version 2>&1)"

###############################################################################
# Build Rust workspace + provisioner-scripts
###############################################################################
log "Building Cargo workspace (release)"
cargo build --workspace --release

log "Installing provisioner-scripts npm deps"
npm install --prefix provisioner-scripts

log "Installing Playwright Chromium (browser only -- system deps may need sudo)"
if [[ "$PLATFORM" == linux ]]; then
  npx --prefix provisioner-scripts playwright install chromium --with-deps
else
  npx --prefix provisioner-scripts playwright install chromium
fi

###############################################################################
# Smoke tests
###############################################################################
log "Smoke-testing: cargo test --workspace"
cargo test --workspace --quiet

log "Smoke-testing: npm test --prefix provisioner-scripts"
npm test --prefix provisioner-scripts --silent

cat <<'EOF'

================================================================================
  AgentKeys dev environment ready.
================================================================================
Next steps:
  1. Install Google Chrome if missing (CDP demo needs a real Chrome):
       https://www.google.com/chrome/
  2. One-time AWS infra:  docs/stage6-aws-setup.md
  3. Run the demo:        docs/dev-setup.md  (sections 4 + 5)

If you opened a fresh shell, source your cargo env:
  source "$HOME/.cargo/env"
EOF
