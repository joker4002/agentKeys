# Issue #103 — extended agent-infra/sandbox image for the AgentKeys
# hardware-companion demo.
#
# Layers two supervisord programs on top of the stock sandbox:
#   - agentkeys-daemon   (port 8089) — serves the demo memory blob
#   - agentkeys-hermes-runtime (port 8090) — agent runtime
#
# The stock gem-server + nginx programs from the base image remain
# in place; nginx fronts hermes-runtime on port 8080 for the public
# /v1/chat path used by the ESP32 (see ./nginx-hermes.conf, applied
# at the deploy script in scripts/setup-demo-aiosandbox.sh step 5).
#
# Build context: workspace root (so the binaries-builder stage can
# `cargo build` against the full workspace).
#
# Build:
#   docker build -f docker/aiosandbox-demo/Dockerfile -t agentkeys/aiosandbox-demo:latest .
#
# IMPORTANT: pass `--security-opt seccomp=unconfined` to every `docker run`
# invocation. The agent-infra/sandbox base image uses kernel syscalls that
# Docker Desktop's default seccomp profile blocks on macOS/Linux, and the
# container exits silently without it. The flag is safe for local demo use;
# production deployments behind a hardened runtime (firecracker / gVisor /
# k8s seccomp profile) can drop it.
#
# Run (local quickstart with bundled fixture, no S3):
#   docker run --security-opt seccomp=unconfined --rm -p 8080:8080 -p 8090:8090 \
#     -e AGENTKEYS_LLM_PROVIDER=stub \
#     agentkeys/aiosandbox-demo:latest
#
# Run (with DashScope Qwen-Plus + S3-backed memory):
#   docker run --security-opt seccomp=unconfined --rm -p 8080:8080 \
#     -e AGENTKEYS_LLM_PROVIDER=dashscope \
#     -e AGENTKEYS_LLM_API_KEY=sk-... \
#     -e AGENTKEYS_DEMO_MEMORY_BUCKET=agentkeys-demo-memory \
#     -e AGENTKEYS_DEMO_MEMORY_REGION=us-east-1 \
#     -e AGENTKEYS_DEMO_ACTOR_TOKEN=demo_token_O_demo_001_changeme \
#     agentkeys/aiosandbox-demo:latest

# ─── stage 1: build the agentkeys Rust binaries ────────────────────────
FROM rust:1.83-slim-bookworm AS builder

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      pkg-config libssl-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY tests ./tests

RUN cargo build --release \
      -p agentkeys-daemon \
      -p agentkeys-hermes-runtime

# ─── stage 2: layer onto the stock sandbox ─────────────────────────────
FROM ghcr.io/agent-infra/sandbox:latest

COPY --from=builder /src/target/release/agentkeys-daemon \
                    /usr/local/bin/agentkeys-daemon
COPY --from=builder /src/target/release/agentkeys-hermes-runtime \
                    /usr/local/bin/agentkeys-hermes-runtime

COPY docker/aiosandbox-demo/supervisord.d/agentkeys-daemon.conf \
     /opt/gem/supervisord.d/agentkeys-daemon.conf
COPY docker/aiosandbox-demo/supervisord.d/hermes-runtime.conf \
     /opt/gem/supervisord.d/hermes-runtime.conf

# Pre-create writable state dir owned by the stock gem user.
RUN mkdir -p /home/gem/.agentkeys \
 && chown gem:gem /home/gem/.agentkeys

# Stock sandbox ships nginx fronting gem-server on 8080; we extend it
# to forward /v1/chat to the hermes-runtime on 8090. The nginx vhost
# is installed by scripts/setup-demo-aiosandbox.sh (post-deploy edit)
# rather than baked in here so operators can swap the cert paths and
# upstream port without rebuilding the image.

# Ports:
#   8080 — public nginx front-end (used by ESP32)
#   8089 — agentkeys-daemon demo memory (loopback-only in prod, exposed
#          here so docker-compose-style debugging is easy)
#   8090 — agentkeys-hermes-runtime (also loopback in prod, behind nginx)
EXPOSE 8080 8089 8090
