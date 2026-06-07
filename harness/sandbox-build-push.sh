#!/usr/bin/env bash
# harness/sandbox-build-push.sh — cross-build the agentkeys binaries for the
# sandbox (aarch64 Linux) and upload them to its ~/.local/bin. Run after a LOCAL
# code change so the in-sandbox agent runs your current source.
#
# Self-contained: it ONLY builds + pushes — it does NOT pair or wire (that's the
# master's job, done in the parent-control web UI). It shares phase1-wire-demo.sh's
# cached builder image + cargo volumes, so a warm tree re-pushes in seconds; the
# first run builds the deps image + a full cross-compile.
#
#   bash harness/sandbox-build-push.sh                 # localhost sandbox
#   SANDBOX_URL=http://host:8080 bash harness/sandbox-build-push.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX_URL="${SANDBOX_URL:-http://localhost:8080}"
RUST_BUILD_IMAGE="${RUST_BUILD_IMAGE:-rust:1.83-slim-bookworm}"
BUILDER_IMAGE="${BUILDER_IMAGE:-agentkeys-sandbox-builder:1.83-bookworm}"
CARGO_REGISTRY_VOL="${CARGO_REGISTRY_VOL:-agentkeys-sandbox-cargo-registry}"
CARGO_GIT_VOL="${CARGO_GIT_VOL:-agentkeys-sandbox-cargo-git}"
RUSTUP_VOL="${RUSTUP_VOL:-agentkeys-sandbox-rustup}"
CARGO_TARGET_VOL="${CARGO_TARGET_VOL:-agentkeys-sandbox-target}"
LINUX_TARGET_DIR="$REPO_ROOT/target/sandbox-linux"
BINS=(agentkeys agentkeys-mcp-server agentkeys-daemon)

c()   { [ -t 1 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
die() { printf '%s %s\n' "$(c '1;31' '✗')" "$1" >&2; exit 1; }
ok()  { printf '%s %s\n' "$(c '1;32' '✓')" "$1"; }
command -v docker >/dev/null 2>&1 || die "docker required (cross-build for aarch64-linux)"
command -v jq >/dev/null 2>&1     || die "jq required"

sbx() { curl -sS -m"${2:-20}" -X POST "$SANDBOX_URL/v1/shell/exec" -H 'content-type: application/json' \
          -d "$(jq -n --arg cmd "$1" '{command:$cmd}')"; }
sbx 'true' 6 | jq -e '.success==true' >/dev/null 2>&1 \
  || die "sandbox not reachable at $SANDBOX_URL — start it: docker run --security-opt seccomp=unconfined -d -p 8080:8080 ghcr.io/agent-infra/sandbox:latest"
HOME_SBX="$(sbx 'printf %s "$HOME"' 6 | jq -r '.data.output')"
[ -n "$HOME_SBX" ] && [ "$HOME_SBX" != "null" ] || die "could not resolve the sandbox \$HOME"

# Builder image (rust + openssl deps baked) — build once if absent.
if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
  printf '▸ building cached builder image %s (one-time)…\n' "$BUILDER_IMAGE"
  docker build --platform linux/arm64 -t "$BUILDER_IMAGE" - <<DOCKERFILE
FROM ${RUST_BUILD_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
DOCKERFILE
  docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 || die "could not build $BUILDER_IMAGE"
fi

# Cross-build (named volumes → incremental; CARGO_TARGET_DIR is a named volume,
# never your host darwin target/; only the 3 binaries are copied out). Pin the
# toolchain to the host rustc — rust-toolchain.toml's `stable` floats, and a
# fresh-stable container breaks clean builds of some pre-release deps.
host_tc="$(rustc --version 2>/dev/null | awk '{print $2}')"
cross_tc="${CROSS_RUST_TOOLCHAIN:-${host_tc:-stable}}"
printf '▸ cross-building agentkeys (aarch64-linux, toolchain %s; first run slow, then incremental)…\n' "$cross_tc"
docker run --rm --platform linux/arm64 \
  -v "$REPO_ROOT":/src -w /src \
  -v "$CARGO_REGISTRY_VOL":/usr/local/cargo/registry \
  -v "$CARGO_GIT_VOL":/usr/local/cargo/git \
  -v "$RUSTUP_VOL":/usr/local/rustup \
  -v "$CARGO_TARGET_VOL":/cargo-target \
  -e CARGO_TARGET_DIR=/cargo-target \
  -e RUSTUP_TOOLCHAIN="$cross_tc" \
  "$BUILDER_IMAGE" \
  bash -c 'set -e
    cargo build --release -p agentkeys-cli -p agentkeys-mcp-server -p agentkeys-daemon
    mkdir -p /src/target/sandbox-linux/release
    cp -f /cargo-target/release/agentkeys \
          /cargo-target/release/agentkeys-mcp-server \
          /cargo-target/release/agentkeys-daemon \
          /src/target/sandbox-linux/release/'
for b in "${BINS[@]}"; do [ -x "$LINUX_TARGET_DIR/release/$b" ] || die "build produced no $b"; done
ok "cross-built ${BINS[*]}"

# Upload to ~/.local/bin (writable + on the sandbox PATH; the upload API is non-root).
sbx "mkdir -p '$HOME_SBX/.local/bin'" 6 >/dev/null
for b in "${BINS[@]}"; do
  dst="$HOME_SBX/.local/bin/$b"
  got="$(curl -sS -X POST "$SANDBOX_URL/v1/file/upload" -F "file=@$LINUX_TARGET_DIR/release/$b" -F "path=$dst" | jq -r '.data.file_path // "FAIL"')"
  [ "$got" = "$dst" ] || die "$b upload failed (got: $got)"
  sbx "chmod +x '$dst'" 6 >/dev/null
  ok "$b → $dst"
done
printf '\n%s the sandbox runs your current agentkeys (%s/.local/bin). Open the agent pairing request there, then claim it in the web UI.\n' "$(c '1;32' 'DONE ·')" "$HOME_SBX"
