#!/usr/bin/env bash
# ARCHIVED 2026-05-28. DO NOT RUN.
# Superseded by `agentkeys wire hermes` per
# ../spec/plans/phase-1-fresh-user-wire-onboarding.md
# This script provisioned the obsolete Rust-runtime sandbox image
# (agentkeys-hermes-runtime crate + daemon --demo-memory flag); both
# are slated for removal pending operator confirmation.
#
# Issue #103 — idempotent setup for the aiosandbox + hermes demo (HISTORICAL).
#
# Provisions every artifact needed for the cloud side of the demo:
#   1. Builds the agentkeys-daemon + agentkeys-hermes-runtime binaries.
#   2. Builds the extended sandbox docker image (agentkeys/aiosandbox-demo).
#   3. Creates the S3 memory bucket and uploads the demo profile fixture
#      (skipped when --no-s3 is passed for an air-gapped local demo).
#   4. Prints the env block an operator copies into the docker run / VM.
#
# The ESP32 firmware side is OUT OF SCOPE for this script — issue #103
# explicitly tracks "do not ship the work on esp32 side now". When the
# firmware lands, step 5 of this script will print the matching device
# config block (sandbox URL + actor token).
#
# Idempotency contract per CLAUDE.md:
#   - Every step pre-checks state and short-circuits ("skip <reason>")
#     when already done.
#   - Re-running with the same inputs MUST exit 0 without re-applying.
#   - Output convention per step: "ok proceeding" / "skip <reason>" /
#     "fail <reason>".
#
# Usage:
#   bash scripts/setup-demo-aiosandbox.sh [--bucket NAME] [--region REGION]
#     [--actor OMNI] [--no-s3] [--no-docker] [--skip-build]
#     [--profile aws-profile-name] [--yes]
#
# Env overrides:
#   AGENTKEYS_DEMO_MEMORY_BUCKET    default: agentkeys-demo-memory
#   AGENTKEYS_DEMO_MEMORY_REGION    default: us-east-1
#   AGENTKEYS_DEMO_ACTOR_OMNI       default: O_demo_001

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

BUCKET="${AGENTKEYS_DEMO_MEMORY_BUCKET:-agentkeys-demo-memory}"
REGION="${AGENTKEYS_DEMO_MEMORY_REGION:-us-east-1}"
ACTOR="${AGENTKEYS_DEMO_ACTOR_OMNI:-O_demo_001}"
AWS_PROFILE_NAME="${AWS_PROFILE:-agentkeys-admin}"
DO_S3=true
DO_DOCKER=true
DO_BUILD=true
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)    BUCKET="$2"; shift 2 ;;
    --region)    REGION="$2"; shift 2 ;;
    --actor)     ACTOR="$2"; shift 2 ;;
    --profile)   AWS_PROFILE_NAME="$2"; shift 2 ;;
    --no-s3)     DO_S3=false; shift ;;
    --no-docker) DO_DOCKER=false; shift ;;
    --skip-build) DO_BUILD=false; shift ;;
    --yes)       ASSUME_YES=true; shift ;;
    --help|-h)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "fail unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

FIXTURE_PATH="${REPO_ROOT}/tests/fixtures/demo-profile.md"
S3_KEY="bots/${ACTOR}/memory/profile.md"
DAEMON_BIN="${REPO_ROOT}/target/release/agentkeys-daemon"
HERMES_BIN="${REPO_ROOT}/target/release/agentkeys-hermes-runtime"
DOCKER_IMAGE="agentkeys/aiosandbox-demo:latest"
DOCKERFILE="${REPO_ROOT}/docker/aiosandbox-demo/Dockerfile"

log() { printf '[setup-demo-aiosandbox] %s\n' "$*"; }
fail() { printf '[setup-demo-aiosandbox] fail: %s\n' "$*" >&2; exit 1; }

confirm_inputs() {
  cat <<EOF
[setup-demo-aiosandbox] inputs:
  bucket   : ${BUCKET}
  region   : ${REGION}
  actor    : ${ACTOR}
  profile  : ${AWS_PROFILE_NAME}
  s3       : ${DO_S3}
  docker   : ${DO_DOCKER}
  build    : ${DO_BUILD}
EOF
  if [[ "${ASSUME_YES}" != true ]]; then
    read -r -p "[setup-demo-aiosandbox] proceed? [y/N] " ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] || fail "aborted by operator"
  fi
}

step_build_binaries() {
  if [[ "${DO_BUILD}" != true ]]; then
    log "step 1 — build agentkeys binaries: skip --skip-build"
    return
  fi
  if [[ -x "${DAEMON_BIN}" && -x "${HERMES_BIN}" ]]; then
    log "step 1 — build agentkeys binaries: skip already built (rm target/release/* to force)"
    return
  fi
  log "step 1 — build agentkeys binaries: ok proceeding (cargo build --release)"
  (cd "${REPO_ROOT}" && cargo build --release \
      -p agentkeys-daemon \
      -p agentkeys-hermes-runtime)
}

step_build_docker_image() {
  if [[ "${DO_DOCKER}" != true ]]; then
    log "step 2 — build docker image: skip --no-docker"
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    log "step 2 — build docker image: skip docker not installed"
    return
  fi
  if docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
    log "step 2 — build docker image: skip ${DOCKER_IMAGE} already exists (docker image rm to force)"
    return
  fi
  log "step 2 — build docker image: ok proceeding"
  docker build -f "${DOCKERFILE}" -t "${DOCKER_IMAGE}" "${REPO_ROOT}"
}

step_provision_bucket() {
  if [[ "${DO_S3}" != true ]]; then
    log "step 3 — provision S3 bucket: skip --no-s3"
    return
  fi
  if ! command -v aws >/dev/null 2>&1; then
    fail "step 3 — provision S3 bucket: aws CLI not installed"
  fi
  if aws --profile "${AWS_PROFILE_NAME}" --region "${REGION}" \
       s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
    log "step 3 — provision S3 bucket: skip ${BUCKET} already exists"
  else
    log "step 3 — provision S3 bucket: ok proceeding"
    if [[ "${REGION}" == "us-east-1" ]]; then
      aws --profile "${AWS_PROFILE_NAME}" --region "${REGION}" \
        s3api create-bucket --bucket "${BUCKET}" >/dev/null
    else
      aws --profile "${AWS_PROFILE_NAME}" --region "${REGION}" \
        s3api create-bucket --bucket "${BUCKET}" \
        --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
  fi
  current_versioning=$(aws --profile "${AWS_PROFILE_NAME}" --region "${REGION}" \
    s3api get-bucket-versioning --bucket "${BUCKET}" \
    --query 'Status' --output text 2>/dev/null || echo "None")
  if [[ "${current_versioning}" != "Enabled" ]]; then
    log "step 3a — enable bucket versioning: ok proceeding"
    aws --profile "${AWS_PROFILE_NAME}" --region "${REGION}" \
      s3api put-bucket-versioning --bucket "${BUCKET}" \
      --versioning-configuration Status=Enabled
  else
    log "step 3a — enable bucket versioning: skip already Enabled"
  fi
}

step_upload_fixture() {
  if [[ "${DO_S3}" != true ]]; then
    log "step 4 — upload memory fixture: skip --no-s3"
    return
  fi
  [[ -f "${FIXTURE_PATH}" ]] || fail "step 4 — upload memory fixture: fixture missing at ${FIXTURE_PATH}"
  local local_md5
  local_md5=$(md5 -q "${FIXTURE_PATH}" 2>/dev/null || md5sum "${FIXTURE_PATH}" | awk '{print $1}')
  local remote_etag
  remote_etag=$(aws --profile "${AWS_PROFILE_NAME}" --region "${REGION}" \
    s3api head-object --bucket "${BUCKET}" --key "${S3_KEY}" \
    --query 'ETag' --output text 2>/dev/null || echo "MISSING")
  remote_etag=${remote_etag//\"/}
  if [[ "${remote_etag}" == "${local_md5}" ]]; then
    log "step 4 — upload memory fixture: skip ETag matches local md5 (${local_md5})"
    return
  fi
  log "step 4 — upload memory fixture: ok proceeding (local=${local_md5} remote=${remote_etag})"
  aws --profile "${AWS_PROFILE_NAME}" --region "${REGION}" \
    s3api put-object --bucket "${BUCKET}" --key "${S3_KEY}" \
    --body "${FIXTURE_PATH}" \
    --content-type "text/markdown; charset=utf-8" >/dev/null
}

step_print_runtime_env() {
  cat <<EOF

[setup-demo-aiosandbox] step 5 — runtime config to copy into deploy
─────────────────────────────────────────────────────────────────────
The container (or systemd unit) reads these env vars at boot:

  AGENTKEYS_DEMO_ACTOR_OMNI=${ACTOR}
  AGENTKEYS_DEMO_ACTOR_TOKEN=demo_token_${ACTOR}_changeme
  AGENTKEYS_DEMO_MEMORY_BUCKET=${BUCKET}
  AGENTKEYS_DEMO_MEMORY_REGION=${REGION}
  AGENTKEYS_DEMO_MEMORY_FIXTURE=        # leave empty when using S3
  AGENTKEYS_LLM_PROVIDER=dashscope      # or openrouter / openai / claude / stub
  AGENTKEYS_LLM_MODEL=qwen-plus         # provider default if unset
  AGENTKEYS_LLM_API_KEY=sk-...          # required for non-stub providers
  AGENTKEYS_LLM_BASE_URL=               # leave empty for provider default

Local quickstart (bundled fixture, no S3, stub LLM):
  # NOTE --security-opt seccomp=unconfined is required: the agent-infra/sandbox
  # base image uses kernel syscalls blocked by Docker Desktop's default seccomp
  # profile, so without it the container exits silently on first boot.
  docker run --security-opt seccomp=unconfined \\
    --rm -p 8080:8080 -p 8090:8090 -p 8089:8089 \\
    -e AGENTKEYS_DEMO_ACTOR_OMNI=${ACTOR} \\
    -e AGENTKEYS_DEMO_ACTOR_TOKEN=demo_token_${ACTOR}_changeme \\
    -e AGENTKEYS_LLM_PROVIDER=stub \\
    -e AGENTKEYS_LLM_MODEL=stub \\
    -e AGENTKEYS_LLM_API_KEY= \\
    -e AGENTKEYS_LLM_BASE_URL= \\
    -e AGENTKEYS_DEMO_MEMORY_BUCKET= \\
    -e AGENTKEYS_DEMO_MEMORY_REGION= \\
    -e AGENTKEYS_DEMO_MEMORY_FIXTURE= \\
    ${DOCKER_IMAGE}

Smoke-test (replace HOST with the demo host):
  curl -sS https://HOST/v1/chat \\
    -H 'authorization: Bearer demo_token_${ACTOR}_changeme' \\
    -H 'content-type: application/json' \\
    -d '{"query":"what should I eat for lunch?"}' | jq .

ESP32 device config (firmware side is deferred — wire when issue #103
firmware track ships):
  SANDBOX_URL  = https://HOST/v1/chat
  ACTOR_TOKEN  = demo_token_${ACTOR}_changeme
─────────────────────────────────────────────────────────────────────
EOF
}

main() {
  confirm_inputs
  step_build_binaries
  step_build_docker_image
  step_provision_bucket
  step_upload_fixture
  step_print_runtime_env
  log "all steps complete"
}

main "$@"
