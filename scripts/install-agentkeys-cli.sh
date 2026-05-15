#!/usr/bin/env bash
# scripts/install-agentkeys-cli.sh — build + install the three workstation
# binaries (agentkeys, agentkeys-daemon, agentkeys-mock-server) from THIS
# worktree into $PREFIX (default: ~/.local/bin). Mirrors the manual steps
# in stage7-demo-and-verification.md §0 (#5 of the install checklist).
#
# Idempotent by design:
#   - Cargo's incremental build skips already-compiled crates.
#   - The install step is a plain `install -m 0755` (atomic, replaces in place).
#   - Alias stripping uses `sed -i.bak` once per dotfile — re-running just
#     no-ops because the alias is already gone.
#   - PATH wiring appends to ~/.zshenv only when the directory isn't on $PATH.
#   - Post-install verification runs unconditionally; safe on every run.
#
# What gets installed:
#   agentkeys              ← stage-7 CLI (every /dev/* call goes through this)
#   agentkeys-daemon       ← MCP-stdio daemon for §16 e2e provisioning
#   agentkeys-mock-server  ← local mock backend for offline tests
#
# Usage:
#   bash scripts/install-agentkeys-cli.sh                  # → ~/.local/bin
#   PREFIX=/usr/local/bin bash scripts/install-agentkeys-cli.sh
#   bash scripts/install-agentkeys-cli.sh --check          # verify-only, no build
#   bash scripts/install-agentkeys-cli.sh --no-aliases     # skip dotfile rewrite
#
# Why "the script over the manual steps": §0 lists six checklist items
# (alias strip + PATH wire + cargo build + cp + hash -r + capability
# check). Operators run those at least once per `git pull` on the evm
# branch. One script call replaces "did I remember to do step 4?" with
# "the script says it's up to date, period."
#
# Exit codes:
#   0  install succeeded + binary exposes --session-id
#   1  build failed
#   2  install dir not on $PATH AND --no-aliases passed (caller must fix shell)
#   3  post-install capability check failed (the binary on $PATH isn't ours)

set -euo pipefail

# ─── flags + env ─────────────────────────────────────────────────────────────
PREFIX="${PREFIX:-$HOME/.local/bin}"
CHECK_ONLY=0
STRIP_ALIASES=1
FORCE_REBUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)       CHECK_ONLY=1; shift ;;
    --no-aliases)  STRIP_ALIASES=0; shift ;;
    --force)       FORCE_REBUILD=1; shift ;;
    --prefix)      PREFIX="$2"; shift 2 ;;
    --prefix=*)    PREFIX="${1#*=}"; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) PREFIX="$1"; shift ;;
  esac
done

log()   { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
ok()    { printf '\033[1;32m✓\033[0m  %s\n' "$*"; }
die()   { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit "${2:-1}"; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ─── locate repo root ────────────────────────────────────────────────────────
# Walk up from the script's dir until we find Cargo.toml at the workspace
# root. Resilient to being invoked from any cwd.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT=""
candidate="$SCRIPT_DIR"
while [[ "$candidate" != "/" ]]; do
  if [[ -f "$candidate/Cargo.toml" ]] && grep -q '^\[workspace\]' "$candidate/Cargo.toml" 2>/dev/null; then
    REPO_ROOT="$candidate"; break
  fi
  candidate="$(dirname "$candidate")"
done
[[ -z "$REPO_ROOT" ]] && die "could not locate workspace Cargo.toml above $SCRIPT_DIR — run from a checkout of the agentKeys repo"
log "Repo root  : $REPO_ROOT"
log "Install to : $PREFIX"

# ─── check-only path (skip build, just diagnose) ─────────────────────────────
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  log "Check-only mode — no build, no install"
  if ! command -v agentkeys >/dev/null 2>&1; then
    die "agentkeys CLI not on PATH. Re-run without --check to install." 3
  fi
  installed_at="$(command -v agentkeys)"
  log "On PATH    : $installed_at"
  if agentkeys --help 2>&1 | grep -q -- "--session-id"; then
    ok "exposes --session-id (multi-tenant supported)"
    exit 0
  else
    die "STALE BINARY at $installed_at — missing --session-id flag.
   Re-run this script WITHOUT --check to rebuild + install:
     bash scripts/install-agentkeys-cli.sh" 3
  fi
fi

require cargo

# ─── 1. drop conflicting zsh aliases (matches §0 step 1) ─────────────────────
if [[ "$STRIP_ALIASES" -eq 1 ]]; then
  changed=0
  for rc in ~/.zshenv ~/.zshrc ~/.zprofile ~/.bashrc ~/.bash_profile; do
    [[ -f "$rc" ]] || continue
    if grep -qE '^alias (agentkeys|agentkeys-daemon|agentkeys-mock-server)[-= ]' "$rc"; then
      sed -i.bak '/^alias agentkeys[-= ]/d; /^alias agentkeys-daemon[-= ]/d; /^alias agentkeys-mock-server[-= ]/d' "$rc"
      log "stripped conflicting alias from $rc (backup: $rc.bak)"
      changed=1
    fi
  done
  [[ "$changed" -eq 0 ]] && log "no conflicting aliases in shell rc files"
  # Drop runtime aliases from THIS shell too (no-op if we're not sourced).
  unalias agentkeys agentkeys-daemon agentkeys-mock-server 2>/dev/null || true
fi

# ─── 2. ensure $PREFIX is on $PATH ───────────────────────────────────────────
case ":$PATH:" in
  *":$PREFIX:"*)
    log "$PREFIX already on PATH" ;;
  *)
    if [[ "$STRIP_ALIASES" -eq 1 ]]; then
      # Same dotfile policy as alias-strip — we already wrote to ~/.zshenv
      # for that, so adding the PATH export here keeps both in one file.
      echo "export PATH=\"$PREFIX:\$PATH\"" >> ~/.zshenv
      log "appended PATH export to ~/.zshenv (sourced by login shells)"
      export PATH="$PREFIX:$PATH"
    else
      die "$PREFIX is not on PATH and --no-aliases blocked the dotfile edit.
   Add this to your shell rc manually, then re-run:
     export PATH=\"$PREFIX:\$PATH\"" 2
    fi
    ;;
esac

# ─── 3. build (release, all three crates) ────────────────────────────────────
log "Building release binaries (cargo build --release -p agentkeys-cli -p agentkeys-daemon -p agentkeys-mock-server)"
build_args=(build --release
            -p agentkeys-cli
            -p agentkeys-daemon
            -p agentkeys-mock-server)
# --force triggers a clean-and-rebuild so cargo cannot reuse a stale
# artifact compiled with a different feature set (the
# auth-email-link footgun documented in setup-broker-host.sh).
if [[ "$FORCE_REBUILD" -eq 1 ]]; then
  log "  (forced) cargo clean -p {agentkeys-cli,agentkeys-daemon,agentkeys-mock-server} --release"
  (cd "$REPO_ROOT" && cargo clean -p agentkeys-cli -p agentkeys-daemon -p agentkeys-mock-server --release) || true
fi
(cd "$REPO_ROOT" && cargo "${build_args[@]}")

# ─── 4. install (atomic-ish via `install -m 0755`) ───────────────────────────
mkdir -p "$PREFIX"
for bin in agentkeys agentkeys-daemon agentkeys-mock-server; do
  src="$REPO_ROOT/target/release/$bin"
  [[ -x "$src" ]] || die "build did not produce $src (cargo target dir override?)"
  install -m 0755 "$src" "$PREFIX/$bin"
  ok "installed $PREFIX/$bin ($(stat -f '%z' "$PREFIX/$bin" 2>/dev/null || stat -c '%s' "$PREFIX/$bin") bytes)"
done

# ─── 5. clear shell hash table so the new binary wins lookup ────────────────
hash -r 2>/dev/null || true

# ─── 6. post-install capability + PATH-shadow check ──────────────────────────
resolved="$(command -v agentkeys || true)"
if [[ "$resolved" != "$PREFIX/agentkeys" ]]; then
  warn "command -v agentkeys → $resolved (NOT $PREFIX/agentkeys)"
  warn "another agentkeys on PATH is shadowing the install."
  warn "  Suspect entries earlier in \$PATH than $PREFIX:"
  warn "    $PATH" | tr ':' '\n' | head -20 >&2
  die "fix PATH order or remove the shadowing binary, then re-run." 3
fi

if ! agentkeys --help 2>&1 | grep -q -- "--session-id"; then
  die "BUILT BINARY at $PREFIX/agentkeys still lacks --session-id.
   This shouldn't happen — the source in $REPO_ROOT/crates/agentkeys-cli
   ships the flag as of 2026-05-12. Possible causes:
     1. Cargo target dir override redirected the build elsewhere (check
        \$CARGO_TARGET_DIR and ~/.cargo/config.toml [build] target-dir).
     2. The worktree is on a branch that pre-dates the flag — run
        'git log --oneline crates/agentkeys-cli/src/main.rs | head' and
        confirm a commit titled 'feat(stage7): multi-tenant --session-id'
        is in this branch's history." 3
fi

ok "agentkeys --help exposes --session-id"
log "Version:   $(agentkeys --version 2>&1 | head -1)"
log "DONE — workstation binaries up to date at $PREFIX"
