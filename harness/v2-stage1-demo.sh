#!/usr/bin/env bash
# harness/v2-stage1-demo.sh — one-command v2 stage-1 demo end-to-end.
#
# Composes the existing scripts (install-agentkeys-cli.sh,
# agentkeys-init-email-demo.sh, heima-bring-up.sh) into a single
# idempotent flow with clear step boundaries. Each step checks "is this
# already done?" before doing the work, so re-runs are safe.
#
# Pause points (where the operator must interact):
#   - macOS keychain unlock prompt during step 5 (`agentkeys init`
#     writes the session JWT to the OS keychain). The OS modal handles
#     this naturally — no shell pause needed.
#   - Optional confirmation before chain deploy (step 8) when --confirm
#     is passed.
#
# Configuration (everything is overridable — no hardcoded values):
#
#   SESSION_ID            session label (writes ~/.agentkeys/$SESSION_ID/)
#                         default: alice
#                         override: --session-id <name>
#
#   AGENTKEYS_CHAIN       chain profile name (heima-paseo, heima, anvil, ...)
#                         default: heima-paseo (development convention)
#                         override: --chain <name>
#
#   AGENTKEYS_CHAIN_PROFILE_FILE  custom JSON profile path (overrides built-in)
#                                 default: unset; see arch.md §22a
#
#   SMOKE_TEST_SERVICE    service name used in step 7 envelope write
#                         default: openrouter
#                         override: SMOKE_TEST_SERVICE=brave-search bash ...
#
#   SMOKE_TEST_SECRET     fake credential used in step 7 envelope write
#                         default: sk-or-v1-DEMO-FAKE-DO-NOT-USE-IN-PROD
#                         override: SMOKE_TEST_SECRET=foo bash ...
#
#   FUND_AMOUNT_HEI       sudo-fund amount for the deployer (heima-paseo)
#                         default: 100
#                         override: FUND_AMOUNT_HEI=50 bash ...
#
# Step gating flags:
#
#   --from-step N         start at step N (skip steps 1..N-1)
#   --to-step N           stop after step N
#   --only-step N         run exactly step N
#   --skip-build          assume agentkeys CLI is already current
#   --skip-email          assume ~/.agentkeys/$SESSION_ID/session.json exists
#   --skip-smoke          skip the S3 envelope round-trip
#   --skip-deploy         skip the chain bring-up (contract deploy)
#   --confirm             pause for Enter before chain deploy
#   --debug               enable `set -x` (very chatty)
#   --webauthn            use REAL WebAuthn ceremony for K11 enroll (step 11)
#                         and master-mutation K11 assertions (step 13 scope-set).
#                         Opens the operator's default browser and prompts
#                         Touch ID (macOS) / Windows Hello / platform passkey.
#                         Without this flag, K11 uses deterministic stub bytes
#                         that satisfy the on-chain `length != 0` gate but
#                         are NOT cryptographically bound — CI-friendly,
#                         see arch.md §22b.1 stage-1 simplifications.
#   --help                this message
#
# Resumability:
#   Each step prints "[step N/M] ..." to stderr. If a step fails, re-run
#   with --from-step N to retry just that step (steps 1..N-1 are already
#   done and have idempotent skip-checks anyway).
#
# Usage examples:
#   bash harness/v2-stage1-demo.sh                              # full demo, defaults
#   bash harness/v2-stage1-demo.sh --session-id bob             # second tenant
#   bash harness/v2-stage1-demo.sh --chain anvil                # local-dev backbone
#   bash harness/v2-stage1-demo.sh --from-step 5                # skip preflight, start at email init
#   bash harness/v2-stage1-demo.sh --only-step 7                # re-run the envelope smoke test
#   bash harness/v2-stage1-demo.sh --skip-deploy                # everything but chain deploy
#   AGENTKEYS_CHAIN=heima bash harness/v2-stage1-demo.sh        # mainnet (refused on step 8)

set -euo pipefail

# ─── Color helpers ──────────────────────────────────────────────────────────
if [ -t 2 ]; then
  COLOR_HEAD='\033[1;36m'   # cyan, for step headers
  COLOR_OK='\033[1;32m'     # green
  COLOR_SKIP='\033[1;33m'   # yellow
  COLOR_WARN='\033[1;33m'
  COLOR_ERR='\033[1;31m'    # red
  COLOR_DIM='\033[2m'       # dim
  COLOR_RESET='\033[0m'
else
  COLOR_HEAD='' COLOR_OK='' COLOR_SKIP='' COLOR_WARN='' COLOR_ERR='' COLOR_DIM='' COLOR_RESET=''
fi

# Bash-3.2 (macOS default) does NOT support `local -n`, so step counters
# live as plain globals.
STEP_NUM=0
STEP_TOTAL=15
CURRENT_STEP_NAME=""

step()    { STEP_NUM=$((STEP_NUM+1)); CURRENT_STEP_NAME="$1"
            printf "${COLOR_HEAD}==> [step %d/%d] %s${COLOR_RESET}\n" \
              "$STEP_NUM" "$STEP_TOTAL" "$1" >&2 ; }
ok()      { printf "    ${COLOR_OK}ok${COLOR_RESET}    %s\n" "$1" >&2 ; }
info()    { printf "    ${COLOR_DIM}info${COLOR_RESET}  %s\n" "$1" >&2 ; }
skip()    { printf "    ${COLOR_SKIP}skip${COLOR_RESET}  %s\n" "$1" >&2 ; }
warn()    { printf "    ${COLOR_WARN}warn${COLOR_RESET}  %s\n" "$1" >&2 ; }
die()     { printf "    ${COLOR_ERR}fail${COLOR_RESET}  %s\n" "$1" >&2
            if [ "$STEP_NUM" -gt 0 ]; then
              printf "          (failed during step %d/%d: %s)\n" \
                "$STEP_NUM" "$STEP_TOTAL" "$CURRENT_STEP_NAME" >&2
              printf "          retry just this step: bash harness/v2-stage1-demo.sh --only-step %d\n" \
                "$STEP_NUM" >&2
            fi
            exit 1 ; }

# ─── Default config (overridable via env or flags) ──────────────────────────
SESSION_ID_DEFAULT="alice"
SMOKE_TEST_SERVICE_DEFAULT="openrouter"
SMOKE_TEST_SECRET_DEFAULT="sk-or-v1-DEMO-FAKE-DO-NOT-USE-IN-PROD"

SESSION_ID="${SESSION_ID:-$SESSION_ID_DEFAULT}"
SMOKE_TEST_SERVICE="${SMOKE_TEST_SERVICE:-$SMOKE_TEST_SERVICE_DEFAULT}"
SMOKE_TEST_SECRET="${SMOKE_TEST_SECRET:-$SMOKE_TEST_SECRET_DEFAULT}"

FROM_STEP=1
TO_STEP=$STEP_TOTAL
ONLY_STEP=""
SKIP_BUILD=0
SKIP_EMAIL=0
SKIP_SMOKE=0
SKIP_DEPLOY=0
CONFIRM=0
DEBUG=0
# WEBAUTHN_MODE: 0 = stage-1 stub (CI-friendly, no Touch ID prompt — default).
#                1 = real WebAuthn ceremony (opens browser + Touch ID prompt
#                    on macOS via `agentkeys k11 enroll/assert --webauthn`).
# Per arch.md §22b.1 stage-1 simplifications inventory.
WEBAUTHN_MODE=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/scripts/operator-workstation.env"

# Resolve agentkeys binary — prefer workspace-local builds (operator just
# built / is iterating). Falls back to PATH (installed via
# install-agentkeys-cli.sh). Defends against stale ~/.local/bin/agentkeys
# missing the k11 subcommand. Step 11 (K11 enroll) + step 13 (scope-set
# helper, via --webauthn) invoke this.
if [ -x "$REPO_ROOT/target/release/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/release/agentkeys"
elif [ -x "$REPO_ROOT/target/debug/agentkeys" ]; then
  AGENTKEYS_BIN="$REPO_ROOT/target/debug/agentkeys"
elif command -v agentkeys >/dev/null 2>&1; then
  AGENTKEYS_BIN="$(command -v agentkeys)"
else
  AGENTKEYS_BIN=""  # step 1 (install) will build it; resolver re-checked at step 11/13.
fi
export AGENTKEYS_BIN

# ─── Argument parsing ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id)      [ $# -lt 2 ] && die "--session-id requires a value"
                       SESSION_ID="$2"; shift 2 ;;
    --session-id=*)    SESSION_ID="${1#*=}"; shift ;;
    --chain)           [ $# -lt 2 ] && die "--chain requires a value"
                       export AGENTKEYS_CHAIN="$2"; shift 2 ;;
    --chain=*)         export AGENTKEYS_CHAIN="${1#*=}"; shift ;;
    --from-step)       [ $# -lt 2 ] && die "--from-step requires N"
                       FROM_STEP="$2"; shift 2 ;;
    --to-step)         [ $# -lt 2 ] && die "--to-step requires N"
                       TO_STEP="$2"; shift 2 ;;
    --only-step)       [ $# -lt 2 ] && die "--only-step requires N"
                       ONLY_STEP="$2"; shift 2 ;;
    --skip-build)      SKIP_BUILD=1; shift ;;
    --skip-email)      SKIP_EMAIL=1; shift ;;
    --skip-smoke)      SKIP_SMOKE=1; shift ;;
    --skip-deploy)     SKIP_DEPLOY=1; shift ;;
    --confirm)         CONFIRM=1; shift ;;
    --debug)           DEBUG=1; shift ;;
    --webauthn)        WEBAUTHN_MODE=1; shift ;;
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0 ;;
    *) die "unknown flag: $1 (try --help)" ;;
  esac
done

[ "$DEBUG" = "1" ] && set -x

if [ -n "$ONLY_STEP" ]; then
  FROM_STEP="$ONLY_STEP"
  TO_STEP="$ONLY_STEP"
fi

# Pre-seed STEP_NUM so the first step() call increments to FROM_STEP
# (rather than always landing on 1, which was a UX bug when using
# --from-step N or --only-step N).
STEP_NUM=$((FROM_STEP - 1))

# Determine whether a given step number is in scope.
in_scope() {
  local n="$1"
  [ "$n" -ge "$FROM_STEP" ] && [ "$n" -le "$TO_STEP" ]
}

# ─── Step 1: tool sanity-check ──────────────────────────────────────────────
do_step_1() {
  step "Tool sanity-check"
  local missing=()
  # python3: parsing cast's tuple-of-struct return in heima-scope-{set,revoke}.sh
  # (codex review finding — missing python3 silently bypasses the idempotency
  # check and re-submits txs on every run).
  for tool in jq curl awk sed grep aws cargo node npx python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "missing tools: ${missing[*]} — install them before re-running"
  fi
  ok "all required tools present (jq curl awk sed grep aws cargo node npx python3)"

  # forge + cast are only needed for step 8 (chain deploy). Soft-warn now,
  # hard-fail in step 8 if missing.
  for tool in forge cast; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      warn "$tool missing — step 8 (chain deploy) will fail. Install Foundry: https://book.getfoundry.sh/getting-started/installation"
    fi
  done
}

# ─── Step 2: source operator-workstation.env ────────────────────────────────
do_step_2() {
  step "Load operator-workstation.env"
  if [ ! -f "$ENV_FILE" ]; then
    die "missing $ENV_FILE — copy from scripts/operator-workstation.env.example and fill in your values (see docs/cloud-setup.md §0)"
  fi
  # set -a / set +a auto-exports every VAR=value line.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a

  local required=(ACCOUNT_ID REGION MAIL_DOMAIN MAIL_BUCKET OIDC_ISSUER BACKEND_URL BROKER_HOST BUCKET)
  local missing=()
  for v in "${required[@]}"; do
    eval "val=\${$v:-}"
    [ -z "${val:-}" ] && missing+=("$v")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "operator-workstation.env loaded but missing required vars: ${missing[*]}"
  fi
  ok "env sourced — REGION=$REGION DOMAIN=$MAIL_DOMAIN BUCKET=$BUCKET"

  # Default chain profile if the operator hasn't selected one. We default
  # to heima (mainnet) since Heima Paseo testnet collators have been
  # halted since 2026-01-15 (block 2,905,430 frozen for months). Mainnet
  # has no sudo, so the bring-up step's auto-fund-Alice path isn't
  # available — operators must fund the deployer manually from their
  # personal wallet, AND the demo's mainnet deploy step requires an
  # explicit MAINNET_CONFIRM=1 env var. In stub mode (no
  # crates/agentkeys-chain/ yet), the demo runs with sentinel addresses
  # and no real chain side-effects regardless.
  if [ -z "${AGENTKEYS_CHAIN:-}" ]; then
    export AGENTKEYS_CHAIN="heima"
    info "AGENTKEYS_CHAIN not set — defaulting to heima (mainnet; Paseo is currently halted)"
  fi
}

# ─── Step 3: AWS profile sanity-check ───────────────────────────────────────
do_step_3() {
  step "AWS profile sanity-check"
  local caller_arn
  caller_arn=$(aws sts get-caller-identity --query 'Arn' --output text 2>&1) \
    || die "aws sts get-caller-identity failed: $caller_arn — run: awsp agentkeys-admin"
  # Caller-ARN matching is case-insensitive per CLAUDE.md (remote IAM is
  # agentKeys-admin, local profile is agentkeys-admin).
  local arn_lc
  arn_lc=$(printf '%s' "$caller_arn" | tr '[:upper:]' '[:lower:]')
  case "$arn_lc" in
    *":user/agentkey-broker"*|*":user/agentkey-daemon"*)
      die "caller is $caller_arn — lacks s3:ListBucket. Run: awsp agentkeys-admin" ;;
    *":user/agentkeys-admin"*)
      ok "caller is admin: $caller_arn" ;;
    *)
      warn "caller is $caller_arn — may or may not have required perms; proceeding" ;;
  esac
}

# ─── Step 4: agentkeys CLI build + capability check ─────────────────────────
do_step_4() {
  step "agentkeys CLI build + capability check"
  if [ "$SKIP_BUILD" = "1" ]; then
    skip "--skip-build set; assuming current binary"
    return 0
  fi
  if command -v agentkeys >/dev/null 2>&1 \
     && agentkeys --help 2>&1 | grep -q -- "--session-id" \
     && agentkeys --help 2>&1 | grep -q -- "--chain"; then
    ok "agentkeys $(agentkeys --version 2>/dev/null || echo '?') on PATH at $(command -v agentkeys) (supports --session-id + --chain)"
    return 0
  fi
  info "agentkeys missing or stale — running scripts/install-agentkeys-cli.sh"
  bash "$REPO_ROOT/scripts/install-agentkeys-cli.sh" \
    || die "install-agentkeys-cli.sh failed — see its output above"
  hash -r
  ok "agentkeys rebuilt + reinstalled — $(command -v agentkeys)"
}

# ─── Step 5: chain reachability ─────────────────────────────────────────────
do_step_5() {
  step "Chain reachability check (chain=$AGENTKEYS_CHAIN)"
  local profile rpc_http expected_chain_id hex dec verdict
  profile=$(agentkeys chain show 2>&1) \
    || die "agentkeys chain show failed: $profile"
  rpc_http=$(printf '%s' "$profile" | jq -r .rpc.http)
  expected_chain_id=$(printf '%s' "$profile" | jq -r .chain_id)
  info "RPC=$rpc_http  expected chain_id=$expected_chain_id"
  hex=$(curl -sS --max-time 10 -H 'Content-Type: application/json' \
          -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
          "$rpc_http" 2>/dev/null | jq -r '.result // empty')
  [ -z "$hex" ] && die "cannot reach $rpc_http — check network / override AGENTKEYS_CHAIN_PROFILE_FILE"
  dec=$((hex))   # bash/zsh native hex parse — no 16# prefix, no xargs
  if [ "$dec" = "$expected_chain_id" ]; then
    ok "live eth_chainId=$hex (decimal $dec) matches profile"
  else
    die "live eth_chainId=$hex (decimal $dec) does NOT match profile's $expected_chain_id — chain mismatch?"
  fi
}

# ─── Step 6: email-init Alice session ───────────────────────────────────────
do_step_6() {
  step "Initialize session ($SESSION_ID) via email magic-link"
  local session_file="$HOME/.agentkeys/$SESSION_ID/session.json"
  if [ "$SKIP_EMAIL" = "1" ]; then
    skip "--skip-email set"
    [ -f "$session_file" ] || die "but $session_file missing — drop --skip-email or run init manually"
    return 0
  fi
  if [ -f "$session_file" ]; then
    local age_sec
    age_sec=$(( $(date +%s) - $(stat -f %m "$session_file" 2>/dev/null \
                                 || stat -c %Y "$session_file") ))
    if [ "$age_sec" -lt 3600 ]; then
      skip "$session_file exists and is <1h old (${age_sec}s) — reusing"
      return 0
    fi
    info "$session_file exists but is ${age_sec}s old; re-initing to refresh JWT"
  fi
  info "NOTE: when the macOS keychain dialog appears, click 'Always Allow' (or Touch ID)"
  info "running: bash scripts/agentkeys-init-email-demo.sh --session-id $SESSION_ID"
  AGENTKEYS_SESSION_ID="$SESSION_ID" \
    bash "$REPO_ROOT/scripts/agentkeys-init-email-demo.sh" --session-id "$SESSION_ID" \
    || die "agentkeys-init-email-demo.sh failed — see output above"
  [ -f "$session_file" ] || die "expected $session_file to exist after init"
  ok "session JWT persisted at $session_file"
}

# ─── Step 7: provision vault infrastructure (arch.md §17 per-data-class) ────
do_step_7() {
  step "Provision vault infra (bucket + role + policy)"
  # Per arch.md §17 (per-data-class buckets) + §17.2 (per-bucket IAM
  # role): credentials and email MUST live in separate S3 buckets with
  # separate IAM roles, so a bug widening one role doesn't widen all
  # data classes. This step composes four idempotent sub-scripts:
  #
  #   1. provision-vault-bucket.sh    — create $VAULT_BUCKET if missing,
  #                                      block public access, default SSE-S3.
  #   2. provision-vault-role.sh       — create agentkeys-vault-role with
  #                                      OIDC trust + credentials-only inline.
  #   3. apply-vault-bucket-policy.sh  — apply v2 PrincipalTag policy to
  #                                      the vault bucket.
  #   4. cleanup-mail-bucket-policy.sh — revert $MAIL_BUCKET policy to
  #                                      email-only (drop stray credentials
  #                                      grants from the pre-split migration).
  #
  # Each one checks "is this already done?" before acting; re-running
  # the orchestrator is a no-op once all four are clean.
  info "[7.1/7.4] vault bucket"
  bash "$REPO_ROOT/scripts/provision-vault-bucket.sh" \
    || die "provision-vault-bucket.sh failed — see output above"
  info "[7.2/7.4] vault role"
  bash "$REPO_ROOT/scripts/provision-vault-role.sh" >/dev/null \
    || die "provision-vault-role.sh failed — see output above"
  info "[7.3/7.4] vault bucket policy"
  bash "$REPO_ROOT/scripts/apply-vault-bucket-policy.sh" \
    || die "apply-vault-bucket-policy.sh failed — see output above"
  info "[7.4/7.4] mail bucket policy cleanup"
  bash "$REPO_ROOT/scripts/cleanup-mail-bucket-policy.sh" \
    || die "cleanup-mail-bucket-policy.sh failed — see output above"
  ok "vault infra ready: bucket=$VAULT_BUCKET role=$VAULT_ROLE_ARN"
}

# ─── Step 8: capture wallet + actor_omni, smoke-test S3 envelope ────────────
do_step_8() {
  step "Smoke-test S3 envelope (store + read)"
  if [ "$SKIP_SMOKE" = "1" ]; then
    skip "--skip-smoke set"
    return 0
  fi
  local whoami_json wallet actor_omni
  # NOTE: two CLI quirks bake in here, both worth a comment because the
  # error messages don't make the cause obvious.
  #
  # 1. --json is a TOP-LEVEL flag on the agentkeys CLI (set on `cli.json`
  #    in main.rs; threaded into CommandContext.json_output). It MUST
  #    come before the subcommand. `agentkeys whoami --json` errors
  #    with "unexpected argument '--json' found".
  #
  # 2. whoami's --signer-url arg is `#[arg(long, env = "AGENTKEYS_SIGNER_URL"...)]`.
  #    The operator's operator-workstation.env exports AGENTKEYS_SIGNER_URL,
  #    so clap auto-populates signer_url and whoami tries to call the
  #    signer — which requires --omni-account too. Chicken-and-egg: we
  #    want actor_omni FROM whoami, but whoami wants it as input.
  #    Workaround: `env -u AGENTKEYS_SIGNER_URL` for this one call
  #    (the local-only fields session_wallet + agentkeys_actor_omni are
  #    computed without any signer round-trip).
  whoami_json=$(env -u AGENTKEYS_SIGNER_URL \
                  agentkeys --session-id "$SESSION_ID" --json whoami 2>&1) \
    || die "agentkeys whoami failed: $whoami_json — session expired? re-run --only-step 6"
  wallet=$(printf '%s' "$whoami_json" | jq -r '.session_wallet // empty')
  # arch.md canonical name is agentkeys_actor_omni; tolerate the older
  # whoami field name as an alias (see CLAUDE.md "terminology drift" rule).
  actor_omni=$(printf '%s' "$whoami_json" \
                 | jq -r '.agentkeys_actor_omni // .actor_omni // .agentkeys_user_wallet // empty')
  [ -z "$wallet" ]    && die "whoami did not return session_wallet — got: $whoami_json"
  [ -z "$actor_omni" ] && die "whoami did not return actor_omni — got: $whoami_json"
  info "session_wallet      = $wallet"
  info "agentkeys_actor_omni = $actor_omni"

  # Target the dedicated vault bucket (arch.md §17 per-data-class).
  # The CLI's S3 backend engages OIDC AssumeRoleWithWebIdentity ONLY
  # when both --broker-url AND AGENTKEYS_DATA_ROLE_ARN are set
  # (crates/agentkeys-cli/src/lib.rs:420 mint_s3_credentials). The CLI
  # reads the env var name AGENTKEYS_DATA_ROLE_ARN but we point it at
  # the VAULT role — the var name is the CLI's contract; the actual
  # role is per-data-class. Eventually the CLI will take an explicit
  # `--data-class vault` flag and read the matching role var, but for
  # stage 1 we re-use AGENTKEYS_DATA_ROLE_ARN with vault as the value.
  local vault_bucket="${VAULT_BUCKET:?VAULT_BUCKET required (operator-workstation.env)}"
  local vault_role="${VAULT_ROLE_ARN:?VAULT_ROLE_ARN required (operator-workstation.env)}"
  local broker_url="${OIDC_ISSUER:?OIDC_ISSUER required for --broker-url}"
  export AGENTKEYS_DATA_ROLE_ARN="$vault_role"

  local s3_key="bots/$actor_omni/credentials/$SMOKE_TEST_SERVICE.enc"
  if aws s3 ls "s3://$vault_bucket/$s3_key" --region "$REGION" >/dev/null 2>&1; then
    skip "s3://$vault_bucket/$s3_key already exists — round-tripping read only"
  else
    info "writing $SMOKE_TEST_SERVICE credential to s3://$vault_bucket/$s3_key"
    local store_out
    store_out=$(agentkeys --session-id "$SESSION_ID" \
                  --credential-backend=s3 --envelope-version=v2 \
                  --bucket "$vault_bucket" \
                  --broker-url "$broker_url" \
                  --signer-url "$BACKEND_URL" \
                  --omni-account "$actor_omni" \
                  store "$SMOKE_TEST_SERVICE" "$SMOKE_TEST_SECRET" 2>&1) \
      || die "store failed (output: $store_out)
   The CLI maps every AWS SDK error to 'Error: UNREACHABLE — Backend
   unreachable' (lib.rs L66: BackendError::Transport catch-all), which
   hides the underlying cause. Common real causes, in order of
   likelihood — copy-paste the probe to narrow it down:

     1) Caller lacks data-plane perms on the bucket. The agentkeys CLI
        calls PutObject with the caller's direct IAM creds, but the
        cloud-setup.md §3.5+§4.4 design only grants s3:PutObject to
        the assumed agentkeys-data-role (via OIDC AssumeRoleWithWebIdentity).
        Direct admin-CLI writes get AccessDenied even though the operator
        is admin. Probe:
          echo probe | aws s3 cp - s3://$BUCKET/bots/$actor_omni/credentials/probe.txt --region \$REGION

     2) Bucket policy still keyed on agentkeys_user_wallet (v1) but
        the CLI's v2 envelope tags the session with agentkeys_actor_omni.
        Fix: run v2-stage1-migration-and-demo.md §2.2 to rename the
        PrincipalTag key in the bucket policy. Probe:
          aws s3api get-bucket-policy --bucket \$BUCKET --region \$REGION --query Policy --output text | jq

     3) Bucket region mismatch or signer-url unreachable. Probe:
          curl -sS \"\$BACKEND_URL/healthz\"

   Skip this step for now (continue with chain steps):
     bash harness/v2-stage1-demo.sh --from-step 8 --skip-smoke"
    aws s3 ls "s3://$vault_bucket/$s3_key" --region "$REGION" >/dev/null \
      || die "expected object at s3://$vault_bucket/$s3_key after store, but it's missing"
  fi

  # Cross-contamination assertion: the credential MUST live in the
  # vault bucket only — NOT in the mail bucket. This is the
  # arch.md §17 invariant ("per-data-class buckets") expressed as a
  # runtime test. If the policy / env vars regress and credentials
  # land in the mail bucket again, this catches it.
  if aws s3 ls "s3://$MAIL_BUCKET/$s3_key" --region "$REGION" >/dev/null 2>&1; then
    die "ARCH VIOLATION (arch.md §17): credential blob ALSO landed in s3://$MAIL_BUCKET/$s3_key.
   Per-data-class bucket separation is broken. Likely cause: the CLI
   silently fell back to the mail bucket (env var AGENTKEYS_BUCKET=
   pointing at MAIL_BUCKET instead of VAULT_BUCKET), or the smoke-test
   script regressed and re-used \$BUCKET. Investigate before continuing."
  fi
  ok "cross-contamination check: credential is in vault, NOT in mail (arch.md §17 invariant)"

  info "reading $SMOKE_TEST_SERVICE credential back from vault bucket"
  local round_trip
  round_trip=$(agentkeys --session-id "$SESSION_ID" \
                 --credential-backend=s3 --envelope-version=v2 \
                 --bucket "$vault_bucket" \
                 --broker-url "$broker_url" \
                 --signer-url "$BACKEND_URL" \
                 --omni-account "$actor_omni" \
                 read "$SMOKE_TEST_SERVICE" 2>&1) \
    || die "read failed: $round_trip"
  if [ "$round_trip" = "$SMOKE_TEST_SECRET" ]; then
    ok "envelope round-trip OK — wrote and read back identical bytes"
  else
    die "round-trip mismatch — wrote '$SMOKE_TEST_SECRET' but read '$round_trip'"
  fi
}

# ─── Step 9: chain bring-up (contracts) ─────────────────────────────────────
do_step_9() {
  step "Chain backbone bring-up ($AGENTKEYS_CHAIN)"
  if [ "$SKIP_DEPLOY" = "1" ]; then
    skip "--skip-deploy set"
    return 0
  fi

  local profile_uc
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  local existing_scope
  existing_scope=$(grep -E "^SCOPE_CONTRACT_ADDRESS_${profile_uc}=" "$ENV_FILE" 2>/dev/null \
                     | tail -1 | cut -d= -f2 || true)
  if [ -n "$existing_scope" ] && [ "$existing_scope" != "0x0" ] \
     && [ "$existing_scope" != "0x0000000000000000000000000000000000000001" ]; then
    skip "SCOPE_CONTRACT_ADDRESS_${profile_uc} already in $ENV_FILE: $existing_scope"
    info "(re-deploy with --only-step 8 + manually remove the env-file entries)"
    return 0
  fi

  local bring_up_env=("AGENTKEYS_CHAIN=$AGENTKEYS_CHAIN" "FUND_AMOUNT_HEI=${FUND_AMOUNT_HEI:-100}")
  case "$AGENTKEYS_CHAIN" in
    heima-paseo)
      info "using scripts/heima-bring-up.sh (paseo: sudo-funded via Alice)"
      warn "Heima Paseo collators have been halted since 2026-01-15 (block 2,905,430). Funding step will hang. Recommend AGENTKEYS_CHAIN=heima (mainnet) instead." ;;
    heima)
      info "using scripts/heima-bring-up.sh (mainnet: manual deployer funding)"
      warn "Heima MAINNET — real HEI required. If deployer is unfunded, step 4 prints transfer instructions and exits; you fund manually, then re-run." ;;
    *)
      die "no automated bring-up for AGENTKEYS_CHAIN=$AGENTKEYS_CHAIN yet — only heima + heima-paseo are wired. See docs/v2-stage1-migration-and-demo.md §4 for manual deploy steps on other chains." ;;
  esac

  if [ "$CONFIRM" = "1" ] || [ "$AGENTKEYS_CHAIN" = "heima" ]; then
    printf "\n    %sAbout to run chain bring-up on %s.%s\n" \
      "$COLOR_WARN" "$AGENTKEYS_CHAIN" "$COLOR_RESET" >&2
    if [ "$AGENTKEYS_CHAIN" = "heima" ]; then
      printf "    %sMAINNET — real HEI will be spent if contracts aren't already deployed.%s\n" \
        "$COLOR_WARN" "$COLOR_RESET" >&2
      printf "    %s(Re-runs are idempotent: cast-code check skips redeploy of existing contracts.)%s\n" \
        "$COLOR_WARN" "$COLOR_RESET" >&2
    fi
    printf "    Press Enter to proceed, Ctrl-C to abort > " >&2
    # `set -e` aborts the script if read returns non-zero (EOF from
    # /dev/null in CI / piped invocations); `|| true` tolerates that
    # so the orchestrator continues in non-interactive runs. Interactive
    # operators still get the prompt; Ctrl-C still aborts via SIGINT.
    read -r _ || true
  fi

  # Mainnet safety is now layered: (1) the Press-Enter prompt above is
  # operator consent; (2) the chain-id verification inside heima-bring-up.sh
  # step 2 confirms we're talking to the chain claimed by AGENTKEYS_CHAIN;
  # (3) the on-chain `cast code` check in step 5 makes re-runs idempotent
  # so a second invocation can't double-deploy. The previous
  # MAINNET_CONFIRM=1 env-var gate was redundant — operator dropped it.
  env "${bring_up_env[@]}" bash "$REPO_ROOT/scripts/heima-bring-up.sh" \
    || die "heima-bring-up.sh failed — see output above"

  # Re-source the env file to pick up the freshly-appended contract addresses.
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  ok "contracts deployed; addresses appended to $ENV_FILE"
}

# ─── Step 10: register operator master device on chain ─────────────────────
# Uses scripts/heima-device-register.sh — idempotent, no-op if already
# registered (checks SidecarRegistry.getDevice(deviceKeyHash).registeredAt > 0).
do_step_10() {
  step "Register operator master device on SidecarRegistry"
  local profile_uc registry_addr
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  registry_addr=$(eval "echo \${SIDECAR_REGISTRY_ADDRESS_${profile_uc}:-}")
  if [ -z "$registry_addr" ] || [ "$registry_addr" = "0x0" ]; then
    info "skipping — no SidecarRegistry address yet (run step 9 chain bring-up first)"
    return 0
  fi
  bash "$REPO_ROOT/scripts/heima-device-register.sh" \
    --registry-address "$registry_addr" \
    --roles cap-mint,recovery,scope-mgmt \
    --session-id "$SESSION_ID" \
    || die "heima-device-register.sh failed"
  ok "master device registered (or already on-chain)"
}

# ─── Step 12: create demo agent device ─────────────────────────────────────
do_step_12() {
  step "Create demo agent device (registerAgentDevice)"
  local label="${AGENTKEYS_AGENT_LABEL:-demo-agent}"
  local profile_uc registry_addr
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  registry_addr=$(eval "echo \${SIDECAR_REGISTRY_ADDRESS_${profile_uc}:-}")
  if [ -z "$registry_addr" ] || [ "$registry_addr" = "0x0" ]; then
    info "skipping — no SidecarRegistry address yet"
    return 0
  fi
  bash "$REPO_ROOT/scripts/heima-agent-create.sh" \
    --label "$label" \
    --registry-address "$registry_addr" \
    || die "heima-agent-create.sh failed"
  ok "agent device '$label' registered (or already on-chain)"
}

# ─── Step 13: set agent scope ───────────────────────────────────────────────
do_step_13() {
  step "Grant agent scope (setScopeWithWebauthn)"
  local label="${AGENTKEYS_AGENT_LABEL:-demo-agent}"
  local services="${AGENTKEYS_AGENT_SERVICES:-$SMOKE_TEST_SERVICE}"
  local profile_uc scope_addr
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  scope_addr=$(eval "echo \${SCOPE_CONTRACT_ADDRESS_${profile_uc}:-}")
  if [ -z "$scope_addr" ] || [ "$scope_addr" = "0x0" ]; then
    info "skipping — no AgentKeysScope address yet"
    return 0
  fi
  local scope_set_args=(--agent "$label" --services "$services" --scope-address "$scope_addr")
  if [ "$WEBAUTHN_MODE" = "1" ]; then
    scope_set_args+=(--webauthn)
  fi
  bash "$REPO_ROOT/scripts/heima-scope-set.sh" "${scope_set_args[@]}" \
    || die "heima-scope-set.sh failed"
  ok "scope set for agent '$label' (or already matched)"
}

# ─── Step 14: append a credential-audit entry ──────────────────────────────
do_step_14() {
  step "Append credential audit entry (CredentialAudit.append)"
  local label="${AGENTKEYS_AGENT_LABEL:-demo-agent}"
  local service="${SMOKE_TEST_SERVICE:-openrouter}"
  local profile_uc audit_addr
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  audit_addr=$(eval "echo \${CREDENTIAL_AUDIT_ADDRESS_${profile_uc}:-}")
  if [ -z "$audit_addr" ] || [ "$audit_addr" = "0x0" ]; then
    info "skipping — no CredentialAudit address yet"
    return 0
  fi
  bash "$REPO_ROOT/scripts/heima-credential-audit.sh" \
    --actor "$label" \
    --service "$service" \
    --op store \
    --audit-address "$audit_addr" \
    || die "heima-credential-audit.sh failed"
  ok "audit entry appended"
}

# ─── Step 11: K11 enrollment (must precede master-mutation steps) ───────────────────────────────────────────────
# --webauthn → real ceremony: `agentkeys k11 enroll --webauthn` opens the
#              browser, prompts Touch ID (macOS) / Windows Hello (Windows),
#              persists real attested credential to ~/.agentkeys/k11/<omni>.json
#              with mode="webauthn".
# default    → CI-friendly stub: writes deterministic bytes that satisfy
#              the on-chain `k11Assertion.length != 0` gate. Stub WARN
#              fires on AGENTKEYS_CHAIN=heima per arch.md §22b.1.
do_step_11() {
  local mode_label
  if [ "$WEBAUTHN_MODE" = "1" ]; then
    mode_label="real WebAuthn — Touch ID prompt"
  else
    mode_label="stage-1 stub — CI-friendly; pass --webauthn for real Touch ID"
  fi
  step "K11 enrollment ($mode_label)"
  local profile_uc registry_addr master_addr operator_omni
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  registry_addr=$(eval "echo \${SIDECAR_REGISTRY_ADDRESS_${profile_uc}:-}")
  master_addr=$(eval "echo \${HEIMA_DEPLOYER_ADDR_${profile_uc}:-}")
  if [ -z "$master_addr" ] || [ -z "$registry_addr" ]; then
    info "skipping — master address or registry not yet set (run earlier steps first)"
    return 0
  fi
  local master_lc
  master_lc=$(printf '%s' "$master_addr" | tr '[:upper:]' '[:lower:]')
  operator_omni=$(printf 'agentkeysevm%s' "$master_lc" | shasum -a 256 | awk '{print $1}')
  local enrollment_file="$HOME/.agentkeys/k11/${operator_omni}.json"

  if [ "$WEBAUTHN_MODE" = "1" ]; then
    # Real WebAuthn — re-enroll iff the stored credential isn't already
    # webauthn-mode (so stub→webauthn upgrade is one re-run).
    local current_mode=""
    [ -f "$enrollment_file" ] && current_mode=$(jq -r '.mode // "missing"' "$enrollment_file" 2>/dev/null || echo "missing")
    if [ "$current_mode" = "webauthn" ]; then
      ok "K11 enrollment already real WebAuthn at $enrollment_file"
      return 0
    fi
    info "running real WebAuthn ceremony — browser will open, Touch ID will prompt"
    info "operator_omni = 0x$operator_omni"
    # `agentkeys k11 enroll --webauthn` writes to ~/.agentkeys/k11/<omni>.json
    # itself with mode="webauthn" (k11_webauthn::persist_enrollment).
    "$AGENTKEYS_BIN" k11 enroll --webauthn --operator-omni "0x$operator_omni" \
      || die "real WebAuthn enrollment failed — re-run without --webauthn for stub mode, or check browser pop-up + Touch ID"
    ok "real K11 enrollment written ($enrollment_file, mode=webauthn)"
  else
    if [ -f "$enrollment_file" ]; then
      ok "K11 enrollment already exists at $enrollment_file"
      return 0
    fi
    info "writing stage-1 K11 stub enrollment for operator_omni=0x$operator_omni"
    mkdir -p "$(dirname "$enrollment_file")"
    local cred_id cose ts
    cred_id=$(printf 'agentkeys-k11-stub-cred:0x%s' "$operator_omni" | shasum -a 256 | awk '{print $1}')
    cose=$(printf 'agentkeys-k11-stub-cose:0x%s' "$operator_omni" | shasum -a 256 | awk '{print $1}')
    ts=$(date +%s)
    (umask 077 && jq -n \
      --arg op "0x$operator_omni" \
      --arg cid "$cred_id" \
      --arg cose "$cose" \
      --arg ts "$ts" \
      '{operator_omni:$op, credential_id_hex:$cid, cose_pubkey_hex:$cose, enrolled_at_unix:($ts|tonumber), mode:"stage1-stub"}' \
      > "$enrollment_file")
    chmod 600 "$enrollment_file"
    ok "K11 stub enrollment written ($enrollment_file)"
  fi
}

# ─── Step 15: final summary ────────────────────────────────────────────────
do_step_15() {
  step "Summary + next steps"
  local profile_uc registry_addr session_file
  profile_uc=$(printf '%s' "$AGENTKEYS_CHAIN" | tr 'a-z-' 'A-Z_')
  registry_addr=$(eval "echo \${SIDECAR_REGISTRY_ADDRESS_${profile_uc}:-}")
  session_file="$HOME/.agentkeys/$SESSION_ID/session.json"

  printf "\n${COLOR_OK}═══ v2 stage-1 demo complete ═══${COLOR_RESET}\n\n" >&2
  printf "  session-id          : %s\n"   "$SESSION_ID" >&2
  printf "  session JWT         : %s\n"   "$session_file" >&2
  printf "  chain profile       : %s\n"   "$AGENTKEYS_CHAIN" >&2
  printf "  SidecarRegistry     : %s\n"   "${registry_addr:-(not deployed)}" >&2
  printf "  smoke-test service  : %s @ s3://%s/bots/<actor_omni>/credentials/%s.enc\n" \
    "$SMOKE_TEST_SERVICE" "${VAULT_BUCKET:-$BUCKET}" "$SMOKE_TEST_SERVICE" >&2
  printf "\n  Stage-1 chain actions (bash entries — all shipped):\n" >&2
  if [ -n "$registry_addr" ] && [ "$registry_addr" != "0x0" ]; then
    printf "    bash scripts/heima-device-register.sh --roles cap-mint,recovery,scope-mgmt\n" >&2
    printf "    bash scripts/heima-agent-create.sh    --label demo-agent\n" >&2
    printf "    bash scripts/heima-scope-set.sh       --agent demo-agent --services openrouter\n" >&2
    printf "    bash scripts/heima-credential-audit.sh --actor demo-agent --service openrouter --op store\n" >&2
    printf "    bash scripts/heima-scope-revoke.sh    --agent demo-agent      # teardown\n" >&2
    printf "    bash scripts/heima-device-revoke.sh   --agent demo-agent      # recovery scaffold\n" >&2
    printf "    (pass --webauthn to either for real Touch ID K11 assertion)\n\n" >&2
    printf "  Rust CLI subcommands wrapping the same flows arrive in stage 2 (#90).\n\n" >&2
  fi
  printf "  Re-run individual phases (idempotent):\n" >&2
  printf "    bash harness/v2-stage1-demo.sh --only-step 5     # re-check chain reachability\n" >&2
  printf "    bash harness/v2-stage1-demo.sh --only-step 7     # re-run envelope smoke test\n" >&2
  printf "    bash harness/v2-stage1-demo.sh --from-step 6     # restart from email init\n\n" >&2
}

# ─── Run ────────────────────────────────────────────────────────────────────
main() {
  printf "${COLOR_HEAD}=== v2 stage-1 demo: session-id=%s chain=%s ===${COLOR_RESET}\n" \
    "$SESSION_ID" "${AGENTKEYS_CHAIN:-(unset, will default to heima-paseo)}" >&2
  printf "  steps %d..%d (of %d)\n\n" "$FROM_STEP" "$TO_STEP" "$STEP_TOTAL" >&2

  in_scope 1  && do_step_1
  in_scope 2  && do_step_2
  # Steps 3+ require operator-workstation.env to be sourced — re-source
  # for partial-runs that start at step >= 3.
  if [ "$FROM_STEP" -ge 3 ] && [ -f "$ENV_FILE" ]; then
    set -a; . "$ENV_FILE"; set +a
    : "${AGENTKEYS_CHAIN:=heima-paseo}"; export AGENTKEYS_CHAIN
  fi
  in_scope 3  && do_step_3
  in_scope 4  && do_step_4
  in_scope 5  && do_step_5
  in_scope 6  && do_step_6
  in_scope 7  && do_step_7
  in_scope 8  && do_step_8
  in_scope 9  && do_step_9
  in_scope 10 && do_step_10
  in_scope 11 && do_step_11
  in_scope 12 && do_step_12
  in_scope 13 && do_step_13
  in_scope 14 && do_step_14
  in_scope 15 && do_step_15

  return 0
}

main "$@"
