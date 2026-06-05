#!/usr/bin/env bash
# harness/v2-demo.sh — THE single entry point for the v2 demo. Does the shared
# sanity-check + cargo build ONCE (a preflight), then runs the per-phase
# orchestrators — which SKIP their now-redundant build + tool-check. Each phase
# stays independently runnable + idempotent; this is the "run it all" front door:
#
#   1  v2-stage1-demo.sh      M1 foundation (install → chain → register → agent → audit)
#   2  v2-stage2-demo.sh      hardening (real WebAuthn K11, companion master)
#   3  v2-stage3-demo.sh      OIDC + per-actor/data-class isolation proof (+ #196 steps 16-17)
#   4  memory-plant-demo.sh   plant the master's prepared memory + read-back (re-testable, reserved account)
#   5  phase1-wire-demo.sh    agent-side `agentkeys wire` demo (REAL memory, in the aiosandbox) — pairs the §10.2 agent
#
# OPERATORS RUN WITH NO FLAGS — no flag = the full, real, local experience:
#   bash harness/v2-demo.sh    # ← stages 1→2→3 (Touch ID) + memory plant + the wire test (real)
#
# Phase 5 (wire) auto-runs when the aiosandbox is set up; if it isn't, it's SKIPPED
# with a note (set the sandbox up first with openviking-sandbox-setup.sh). Phase 5
# pairs the §10.2 agent, so AFTER this the sandbox shell runs sandbox-agent-isolation.sh
# directly (no need to re-run the wire demo).
#
# Jump to any step by its OVERALL address PHASE.STEP (the same "phase 3 step 11/18"
# the output prints) — each (phase, step) is unique, no global renumbering:
#   bash harness/v2-demo.sh --from 3.11          # resume AT phase 3 step 11, continue to the end
#   bash harness/v2-demo.sh --from 4.1           # resume at phase 4 (memory plant) → re-test planting
#   bash harness/v2-demo.sh --only 4.1           # run ONLY phase 4 step 1
#   bash harness/v2-demo.sh --from 5             # just the wire phase (phase 5 has no sub-steps)
#
# Other flags are for CI / scoping only — an operator should not need them:
#   bash harness/v2-demo.sh --ci                 # CI: software register + mock agent + tolerate skips; wire OFF (no sandbox)
#   bash harness/v2-demo.sh --stage 3            # one phase
#   bash harness/v2-demo.sh --wire real|light|none     # force the wire phase on/off (light = the dev loop, never for assertions)
#   bash harness/v2-demo.sh --allow-skip=agent-file-invalid   # passthrough to stage 3
#
# Fail-fast: stops at the first failing phase (a red phase cascades); the wire phase
# runs last. Stage 3's agent-side steps (11-12, 14-15) DEFER to the sandbox on the
# operator (green, never fail) and are mocked only under --ci. --ci tolerates per-phase skips.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"      # the harness/ dir
PROJECT_ROOT="$(cd "$REPO_ROOT/.." && pwd)"     # the repo root (Cargo.toml, scripts/)
STAGES="1,2,3,4,5"      # default phase set: 1-3 stages, 4 memory-plant, 5 wire
WIRE_MODE=""            # '' (auto: real if the sandbox is up, else skip), 'real', 'light', or 'none'
FROM_PHASE=""; FROM_STEP=""   # --from P.S : resume from phase P step S, continue to the end
ONLY_PHASE=""; ONLY_STEP=""   # --only P.S : run only phase P (step S)
CI=0
PASS=()                 # flags passed through to each phase (--ci, --webauthn, --allow-skip, …)

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)        STAGES="$2"; shift 2 ;;
    --stage=*)      STAGES="${1#*=}"; shift ;;
    # Overall step addressing: PHASE.STEP (e.g. 3.11 = phase 3, step 11). --from
    # resumes there to the end; --only runs just that. Bare "3" = step 1 / whole phase.
    --from)         case "$2" in *.*) FROM_PHASE="${2%%.*}"; FROM_STEP="${2##*.}" ;; *) FROM_PHASE="$2"; FROM_STEP=1 ;; esac; shift 2 ;;
    --from=*)       v="${1#*=}"; case "$v" in *.*) FROM_PHASE="${v%%.*}"; FROM_STEP="${v##*.}" ;; *) FROM_PHASE="$v"; FROM_STEP=1 ;; esac; shift ;;
    --only)         case "$2" in *.*) ONLY_PHASE="${2%%.*}"; ONLY_STEP="${2##*.}" ;; *) ONLY_PHASE="$2"; ONLY_STEP="" ;; esac; shift 2 ;;
    --only=*)       v="${1#*=}"; case "$v" in *.*) ONLY_PHASE="${v%%.*}"; ONLY_STEP="${v##*.}" ;; *) ONLY_PHASE="$v"; ONLY_STEP="" ;; esac; shift ;;
    --wire)         WIRE_MODE="${2:-real}"; shift 2 ;;
    --wire=*)       WIRE_MODE="${1#*=}"; shift ;;
    --ci)           CI=1; PASS+=(--ci); shift ;;
    --mock-agent)   shift ;;   # accepted for back-compat — stage 3 mocks only under --ci (operators defer to the sandbox)
    --from-step|--to-step|--only-step)  PASS+=("$1" "$2"); shift 2 ;;
    --from-step=*|--to-step=*|--only-step=*)  PASS+=("$1"); shift ;;
    --allow-skip|--allow-skip=*|--webauthn)  PASS+=("$1"); shift ;;
    --help|-h)      sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "v2-demo: unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# --from P.S → run phase P (from step S) through the end; --only P.S → just phase P.
if [ -n "$FROM_PHASE" ]; then
  s=""; for ph in 1 2 3 4 5; do [ "$ph" -ge "$FROM_PHASE" ] && s="${s:+$s,}$ph"; done; STAGES="$s"
fi
[ -n "$ONLY_PHASE" ] && STAGES="$ONLY_PHASE"

{ [ -n "${AGENTKEYS_CI:-}" ] || [ -n "${CI:-}" ] && [ "$CI" != 0 ]; } && CI=1

# Phase 5 (wire) runs only when it's in STAGES; WIRE_MODE controls HOW. Operator → auto
# (real if the sandbox is up, else skip-with-note); CI (no sandbox) → none. --wire wins.
# "is the aiosandbox (agent container) up?" — probe its HTTP API (the SAME gate
# phase1-wire-demo.sh:1.1 uses), NOT a local openviking install. Respects $SANDBOX_URL.
sandbox_present() {
  local u="${SANDBOX_URL:-http://localhost:8080}"
  curl -fsS --max-time 3 "$u/healthz" >/dev/null 2>&1 || curl -fsS --max-time 3 "$u/v1/sandbox" >/dev/null 2>&1
}
if [ -z "$WIRE_MODE" ]; then
  if [ "$CI" = 1 ]; then WIRE_MODE=none; else WIRE_MODE=auto; fi
fi

c() { [ -t 2 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
phase() { printf '\n%s\n' "$(c '1;35' "══ v2-demo · phase $1 ═════════════════════════════════════════")" >&2; }
say()   { printf '%s %s\n' "$(c '1;36' '▸')" "$1" >&2; }

# ── one-time preflight (THE merge) ─────────────────────────────────────────
# Do the shared setup ONCE — source env, the tool sanity-check, and the UNION
# cargo build — instead of letting each phase repeat it. The phases then skip
# their own copies: stages 1/2 via --skip-build, wire via AGENTKEYS_SKIP_CLI_BUILD,
# the tool-check via AGENTKEYS_HARNESS_PREFLIGHT_DONE (stage 3 builds nothing). This
# turns 3-4 redundant builds + sanity-checks into one.
preflight() {
  local env_file="${ENV_FILE:-$PROJECT_ROOT/scripts/operator-workstation.env}"
  [ -f "$env_file" ] && { set -a; . "$env_file"; set +a; }
  phase "0 — preflight (sanity-check + build, once for all phases)"
  local missing=() t
  for t in jq curl awk sed grep cargo cast; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  [ "${#missing[@]}" -eq 0 ] || { printf '%s %s\n' "$(c '1;31' '✗ preflight — missing required tools:')" "${missing[*]}" >&2; exit 1; }
  for t in aws node npx python3 forge; do command -v "$t" >/dev/null 2>&1 || say "$(c '1;33' note:) '$t' not on PATH — some phases need it"; done
  say "sanity-check ok (jq curl awk sed grep cargo cast)"
  # Just run cargo — its fingerprint IS the rebuild-if-needed check: a ~0.5s no-op
  # when nothing changed, rebuilding only what changed otherwise (and target/ is
  # shared, so each crate compiles once). No custom hash / skip flag to second-guess it.
  say "build: cargo build --release (agentkeys-cli + daemon + mcp-server) — cargo rebuilds only what changed…"
  ( cd "$PROJECT_ROOT" && cargo build --release -p agentkeys-cli -p agentkeys-daemon -p agentkeys-mcp-server ) \
    || { printf '%s\n' "$(c '1;31' '✗ preflight — cargo build failed')" >&2; exit 1; }
  say "build ok → $PROJECT_ROOT/target/release"
  # Signal every phase that the shared work is done → they skip their build + sanity-check.
  export AGENTKEYS_HARNESS_PREFLIGHT_DONE=1 AGENTKEYS_SKIP_CLI_BUILD=1
}

# Phase 5 — the agent-side wire demo. Special (no --from-step; WIRE_MODE-driven).
# Pairs the §10.2 agent so the sandbox shell can then run sandbox-agent-isolation.sh.
# Sets WIRE_RESULT so the final summary can tell a real PASS apart from an auto-skip:
#   wired    — the wire actually ran (proof executed)
#   disabled — intentionally off (--wire none / CI has no sandbox) → clean
#   skipped  — auto mode but NO aiosandbox → the proof did NOT run (NOT a pass)
# Returns 0 on wired/disabled/auto-skip, non-zero only on a real wire failure. The
# auto-skip is surfaced as DEMO INCOMPLETE (non-zero exit) by the summary, so an
# unexecuted proof can never read as green.
run_wire_phase() {
  case "$WIRE_MODE" in
    none)  phase "5 — wire (disabled: --wire none / CI has no sandbox)"; WIRE_RESULT=disabled; return 0 ;;
    auto)
      if sandbox_present; then
        phase "5 — phase1-wire-demo.sh --real"; WIRE_RESULT=wired; bash "$REPO_ROOT/phase1-wire-demo.sh" --real
      else
        phase "5 — wire (SKIPPED: no aiosandbox — proof did NOT run)"
        say "$(c '1;33' 'wire skipped') — no aiosandbox reachable at ${SANDBOX_URL:-http://localhost:8080}. The wire/pairing proof did NOT run."
        WIRE_RESULT=skipped
        return 0
      fi ;;
    real)  phase "5 — phase1-wire-demo.sh --real";  WIRE_RESULT=wired; bash "$REPO_ROOT/phase1-wire-demo.sh" --real ;;
    light) phase "5 — phase1-wire-demo.sh --light"; WIRE_RESULT=wired; bash "$REPO_ROOT/phase1-wire-demo.sh" --light ;;
    *) echo "v2-demo: --wire wants real|light|none (got '$WIRE_MODE')" >&2; return 1 ;;
  esac
}

# Map a phase token → its script + build its args. Per-phase flag filtering keeps
# each orchestrator strict (they reject flags they don't define).
run_phase() {
  local p="$1" script args=()
  case "$p" in
    1) script="v2-stage1-demo.sh" ;;
    2) script="v2-stage2-demo.sh" ;;
    3) script="v2-stage3-demo.sh" ;;
    4) script="memory-plant-demo.sh" ;;
    5) run_wire_phase; return $? ;;   # wire — special handling above
    *) echo "v2-demo: unknown phase '$p' (want 1-5)" >&2; return 2 ;;
  esac
  # `${PASS[@]+...}` keeps an EMPTY array safe under `set -u` on macOS bash 3.2.
  for f in ${PASS[@]+"${PASS[@]}"}; do
    case "$f" in
      --allow-skip|--allow-skip=*) [ "$p" = 3 ] && args+=("$f") ;;          # stage 3 only
      --webauthn)                  { [ "$p" = 1 ] || [ "$p" = 2 ]; } && args+=("$f") ;;  # stages 1/2 only
      *)                           args+=("$f") ;;                          # --ci, --from/--only-step → all script phases
    esac
  done
  # Preflight already built target/release — stages 1/2 skip their build via --skip-build
  # (stage 3 + memory-plant build nothing). Wire skips via AGENTKEYS_SKIP_CLI_BUILD.
  case "$p" in 1|2) args+=(--skip-build) ;; esac
  # Overall step addressing: inject the target step into the MATCHING phase only.
  [ -n "$FROM_PHASE" ] && [ "$p" = "$FROM_PHASE" ] && args+=(--from-step "$FROM_STEP")
  [ -n "$ONLY_PHASE" ] && [ "$p" = "$ONLY_PHASE" ] && [ -n "$ONLY_STEP" ] && args+=(--only-step "$ONLY_STEP")
  # Stage 3 agent-side steps (11-12, 14-15) DEFER to the sandbox on the operator; only
  # CI (no sandbox) mocks them with a master-held dev agent.
  case "$p" in 3) [ "$CI" = 1 ] && args+=(--mock-agent) ;; esac
  phase "$p — $script"
  bash "$REPO_ROOT/$script" ${args[@]+"${args[@]}"}
}

preflight   # the merge: sanity-check + build ONCE; every phase below skips its own

OVERALL=0
IFS=',' read -r -a WANT <<< "$STAGES"
for p in ${WANT[@]+"${WANT[@]}"}; do   # ${..+..} keeps an empty STAGES safe under set -u (bash 3.2)
  p="$(printf '%s' "$p" | tr -d '[:space:]')"; [ -n "$p" ] || continue
  if run_phase "$p"; then
    if [ "$p" = 5 ] && [ "${WIRE_RESULT:-}" = skipped ]; then say "phase $p: $(c '1;33' 'SKIPPED — wire proof did not run')"
    else say "phase $p: $(c '1;32' ok)"; fi
  else
    OVERALL=1; say "phase $p: $(c '1;31' FAILED)"
    [ "$CI" = 1 ] || { echo "$(c '1;31' '✗ stopping — fix phase '"$p"' before continuing (downstream phases depend on it)')" >&2; exit 1; }
  fi
done

if [ "$OVERALL" != 0 ]; then
  printf '\n%s some phases reported failures — see the per-phase output above.\n' "$(c '1;33' 'v2-demo ·')" >&2
  exit "$OVERALL"
fi

# Every explicitly-run phase passed. But an AUTO-SKIPPED wire is NOT a pass: the
# pairing proof never ran, so don't let it read as green (codex finding 3). Make
# the skip distinct + exit non-zero, with an explicit escape (--wire none).
wire_requested=0; case ",$STAGES," in *,5,*) wire_requested=1 ;; esac
if [ "$wire_requested" = 1 ] && [ "${WIRE_RESULT:-}" = skipped ]; then
  printf '\n%s phases %s ran green, but phase 5 (wire) was SKIPPED — no aiosandbox, so the wire/pairing proof did NOT run.\n' \
    "$(c '1;33' 'v2-demo INCOMPLETE ·')" "$STAGES" >&2
  say "Bring up the aiosandbox + re-run the wire: docker run --security-opt seccomp=unconfined -d -p 8080:8080 ghcr.io/agent-infra/sandbox:latest  &&  bash harness/v2-demo.sh --from 5"
  say "Or pass --wire none to intentionally skip the wire (then the run is a clean pass)."
  exit 1
fi

printf '\n%s phases %s — all green.\n' "$(c '1;32' 'v2-demo DONE ·')" "$STAGES" >&2
if [ "$wire_requested" = 1 ]; then
  case "${WIRE_RESULT:-}" in
    wired)    say "agent paired in the sandbox → run the agent-side proof THERE: bash \$HOME/sandbox-agent-isolation.sh" ;;
    disabled) say "wire intentionally disabled (--wire none) — no §10.2 agent was paired this run." ;;
  esac
fi
exit 0
