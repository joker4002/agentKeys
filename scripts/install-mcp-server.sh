#!/usr/bin/env bash
# scripts/install-mcp-server.sh — one-liner installer for the AgentKeys MCP server.
#
# Operator UX (mirrors rustup / uv / agentmemory):
#   curl -fsSL https://github.com/litentry/agentKeys/releases/latest/download/install.sh | sh
#
# What it does (idempotent):
#   1. Detect OS + arch (linux/x86_64, linux/aarch64, darwin/arm64, darwin/x86_64)
#   2. Pick a matching release asset from GitHub Releases (latest by default,
#      $AGENTKEYS_VERSION=vX.Y.Z to pin)
#   3. Download the tarball + checksums.txt, verify sha256
#   4. Extract `agentkeys-mcp-server` binary to $PREFIX/bin (default ~/.local/bin)
#   5. Print client wiring snippets (Claude Code / Codex / Claude Desktop)
#
# Env overrides:
#   AGENTKEYS_VERSION   pin a release tag (default: latest)
#   AGENTKEYS_PREFIX    install dir (default: ~/.local; binary lands at $PREFIX/bin)
#   AGENTKEYS_REPO      override repo slug for testing (default: litentry/agentKeys)
set -euo pipefail

REPO="${AGENTKEYS_REPO:-litentry/agentKeys}"
PREFIX="${AGENTKEYS_PREFIX:-$HOME/.local}"
VERSION="${AGENTKEYS_VERSION:-latest}"
BIN_NAME="agentkeys-mcp-server"

err() { printf "\033[1;31merror\033[0m: %s\n" "$*" >&2; exit 1; }
say() { printf "\033[1;36m==>\033[0m %s\n" "$*" >&2; }
ok()  { printf "    \033[1;32mok\033[0m %s\n" "$*" >&2; }

# 1. Detect platform
os_raw=$(uname -s)
arch_raw=$(uname -m)
case "$os_raw" in
  Linux)  os="unknown-linux-gnu" ;;
  Darwin) os="apple-darwin" ;;
  *) err "unsupported OS: $os_raw (only Linux + macOS shipped today)" ;;
esac
case "$arch_raw" in
  x86_64|amd64)  arch="x86_64" ;;
  aarch64|arm64) arch="aarch64" ;;
  *) err "unsupported arch: $arch_raw" ;;
esac
TRIPLE="${arch}-${os}"
say "detected platform: ${TRIPLE}"

# 2. Resolve release URL
if [ "$VERSION" = "latest" ]; then
  REL_URL="https://github.com/${REPO}/releases/latest/download"
else
  REL_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi
ASSET="${BIN_NAME}-${TRIPLE}.tar.gz"
URL="${REL_URL}/${ASSET}"
SHA_URL="${REL_URL}/checksums.txt"

# 3. Download + verify
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
say "downloading ${URL}"
if ! curl -fsSL -o "$TMP/$ASSET" "$URL"; then
  err "download failed — does this release ship a binary for ${TRIPLE}? check ${REL_URL%/download}"
fi
ok "downloaded $(wc -c < "$TMP/$ASSET" | tr -d ' ') bytes"

# Verify checksum if the release ships one (release.yml uploads checksums.txt
# alongside the tarballs). Skip gracefully on older releases that don't.
if curl -fsSL -o "$TMP/checksums.txt" "$SHA_URL" 2>/dev/null; then
  expected=$(grep "  ${ASSET}\$" "$TMP/checksums.txt" | awk '{print $1}' || true)
  if [ -n "$expected" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      actual=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
    else
      actual=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
    fi
    [ "$actual" = "$expected" ] || err "sha256 mismatch: expected $expected, got $actual"
    ok "sha256 verified ($expected)"
  fi
fi

# 4. Extract + install
say "extracting"
tar -xzf "$TMP/$ASSET" -C "$TMP"
[ -x "$TMP/$BIN_NAME" ] || err "tarball did not contain executable $BIN_NAME"

mkdir -p "$PREFIX/bin"
install -m 0755 "$TMP/$BIN_NAME" "$PREFIX/bin/$BIN_NAME"
ok "installed $PREFIX/bin/$BIN_NAME"

# Strip macOS quarantine attr so Gatekeeper doesn't refuse to run an
# un-notarized binary. Safe no-op on Linux.
xattr -d com.apple.quarantine "$PREFIX/bin/$BIN_NAME" 2>/dev/null || true

# 5. Confirm + print wiring snippets
version=$("$PREFIX/bin/$BIN_NAME" --version 2>&1 || echo "(version subcommand pending)")
ok "version: ${version}"

cat >&2 <<MSG

==> Next: wire into your LLM host

Claude Code (user scope, all projects):
    claude mcp add --scope user agentkeys \\
      -e MCP_TRANSPORT=stdio -e MCP_BACKEND=in-memory \\
      -- $PREFIX/bin/$BIN_NAME

Codex CLI — append to ~/.codex/config.toml:
    [mcp_servers.agentkeys]
    command = "$PREFIX/bin/$BIN_NAME"
    args = []
    env = { MCP_TRANSPORT = "stdio", MCP_BACKEND = "in-memory" }

Claude Desktop (macOS) — merge into ~/Library/Application Support/Claude/claude_desktop_config.json:
    {
      "mcpServers": {
        "agentkeys": {
          "command": "$PREFIX/bin/$BIN_NAME",
          "env": { "MCP_TRANSPORT": "stdio", "MCP_BACKEND": "in-memory" }
        }
      }
    }

For production (broker-backed), swap MCP_BACKEND=http and set AGENTKEYS_BROKER_URL.
See docs/spec/plans/issue-107-mcp-demo-runbook.md for the full walkthrough.
MSG

# Path hint if $PREFIX/bin isn't on PATH
case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo >&2; printf "    \033[1;33mhint\033[0m: %s is not on \$PATH — add to your shell rc:\n      export PATH=\"%s/bin:\$PATH\"\n" "$PREFIX/bin" "$PREFIX" >&2 ;;
esac
