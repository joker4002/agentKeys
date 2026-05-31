#!/usr/bin/env bash
# Source this (do NOT exec) before a cargo build to route compilation through
# sccache — a content-addressed compile cache.
#
#     source scripts/sccache-env.sh
#     cargo build --release ...      # now wrapped by sccache
#
# Why: on the shared test-broker host many PR branches deploy back-to-back.
# `git checkout` bumps file mtimes, which defeats cargo's mtime-based
# fingerprints — so unchanged crates recompile on every branch switch
# (cross-PR "cache churn"). sccache keys artifacts on *content* hash, so a
# crate built on one PR is served from cache on the next, regardless of
# branch. CARGO_INCREMENTAL=0 because incremental artifacts aren't cacheable
# by sccache (release builds are non-incremental by default anyway).
#
# Idempotent: installs the sccache binary only if absent. Best-effort by
# design — every step is non-fatal, so a download/install hiccup leaves the
# build running WITHOUT the wrapper rather than breaking a deploy. Safe to
# source into a `set -e` shell: all logic runs inside a function invoked with
# `|| true`, which suppresses errexit for the whole body.
#
# Pinned, overridable (no-hardcoded-values policy): SCCACHE_VER / SCCACHE_DIR
# / SCCACHE_CACHE_SIZE.

_sccache_setup() {
  local ver dir cap arch tmp url
  ver="${SCCACHE_VER:-v0.8.2}"
  dir="${SCCACHE_DIR:-/var/cache/sccache}"
  cap="${SCCACHE_CACHE_SIZE:-20G}"

  if ! command -v sccache >/dev/null 2>&1; then
    arch="$(uname -m)"
    url="https://github.com/mozilla/sccache/releases/download/${ver}/sccache-${ver}-${arch}-unknown-linux-musl.tar.gz"
    tmp="$(mktemp -d)" || return 0
    if curl -fsSL "$url" -o "$tmp/s.tgz" \
       && tar -xzf "$tmp/s.tgz" -C "$tmp" --strip-components=1 \
            "sccache-${ver}-${arch}-unknown-linux-musl/sccache"; then
      sudo install -m 0755 "$tmp/sccache" /usr/local/bin/sccache
    else
      echo "sccache: install failed — building without compile cache" >&2
    fi
    rm -rf "$tmp"
  fi

  command -v sccache >/dev/null 2>&1 || return 0

  export RUSTC_WRAPPER=sccache
  export CARGO_INCREMENTAL=0
  export SCCACHE_DIR="$dir" SCCACHE_CACHE_SIZE="$cap"
  sudo mkdir -p "$dir" 2>/dev/null || true
  sudo chmod 1777 "$dir" 2>/dev/null || true
  sccache --start-server >/dev/null 2>&1 || true
  echo "sccache: enabled (dir=$dir cap=$cap)"
}

_sccache_setup || true
