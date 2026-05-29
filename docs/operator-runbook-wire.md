# Operator runbook — run the `agentkeys wire` demo

**This is the single doc to follow to run the demo.** It drives the harness
`harness/phase1-wire-demo.sh`, which automates the whole flow and stops only at
the essential manual gates. Goal: see the Agent IAM "surprise" — a device that
reads only its permitted memory, is deterministically denied an over-cap action
(no LLM in the decision), and complies on revocation.

> **Architecture (1 paragraph)**: AgentKeys is the **Authority Host**; the Task
> Host (Hermes) does the work. `agentkeys wire hermes` writes IAM-guarantee
> **hooks** into Hermes's config so the LLM cannot bypass `permission.check` /
> `audit.append` / memory injection. Background: [`docs/agent-iam-strategy.md`](agent-iam-strategy.md)
> §3.6–3.7, [`docs/arch.md`](arch.md) §22d, [`docs/wiki/agent-iam-guarantee-glossary.md`](wiki/agent-iam-guarantee-glossary.md).
> Full action table + automation decisions: [`docs/spec/plans/phase1-wire-harness-test-plan.md`](spec/plans/phase1-wire-harness-test-plan.md).

## TL;DR — pick a mode and run one command

```bash
# Lighter path — real Hermes + the full wire flow in the sandbox, in-memory
# backend. No real account/broker/chain. The Chengdu surprise lives here. START HERE.
bash harness/phase1-wire-demo.sh --light

# Real — reuses your heima account (master alice + agent demo-agent), real
# broker + workers + Heima mainnet. Add --webauthn so step 1.5 grants the memory
# scope (real Touch ID) and seeds the Chengdu memory; without it, 1.5 seeds only
# if the scope is already granted.
bash harness/phase1-wire-demo.sh --real --webauthn
```

**A mode is REQUIRED** — `--light` or `--real`. The harness refuses to guess
(running `--real` by accident flips the sandbox MCP to the live broker and loses
the in-memory demo fixture). It prints a loud `MODE:` banner so the active mode
is never ambiguous. Every step prints `ok proceeding` / `skip <reason>` /
`fail <reason>`; the harness is idempotent — re-running is safe.

## The two modes — `--light` vs `--real`

> **`--light` = self-contained demo** (fake-but-pre-seeded data, nothing
> external). **`--real` = the live product** (real broker + chain + your
> account, no demo data). "Light" = *lightweight / no external dependencies*,
> not "fewer features" — it runs the identical wire + hook + memory flow.

| | **`--light`** (start here) | **`--real`** |
|---|---|---|
| **In one line** | Self-contained sandbox demo — nothing external | The live product wired to real infra |
| **MCP backend** | `in-memory` (data lives in the server's RAM) | `http` → real broker + workers |
| **Memory data** | a **pre-seeded fixture** — the "Chengdu trip" is baked into the binary | the real S3-backed memory worker (empty unless you seeded it) |
| **The Chengdu surprise** | ✅ works out of the box | ✅ harness **step 1.5 seeds it** — run **`--real --webauthn`** so 1.5 grants the memory scope (real Touch ID) then `agentkeys memory put`. Without `--webauthn` it seeds only if the scope is already granted, else fails telling you to add `--webauthn`. Needs a live master session + K11 enrolled in webauthn mode |
| **Broker / chain** | none | real broker (`signer.litentry.org`) + Heima **mainnet** |
| **Account** | a fixed demo actor/operator | your real `setup-heima.sh` account (alice + demo-agent) |
| **Cap-mint** | stubbed — always succeeds | real cap-mint (needs a valid master session) |
| **Vendor token** | `demo-tok` | `harness-tok` |
| **Touch ID** | never | at **step 1.5** ONLY when you pass `--webauthn` (it self-grants the memory scope); never otherwise |
| **Needs network to** | sandbox + Docker + (first build) a rust image | + reachable broker / workers / Heima RPC |
| **Proves** | the wire + hook + memory-injection **plumbing** works | the same, against **real IAM infra** (real signing + isolation) |
| **Cost / risk** | free, can't break anything | real gas/cost, mutates real account state |

## Prerequisites

**Always:** Rust toolchain (`rustup default stable`) + `jq` (`brew install jq`).

**`--light` / real (sandbox path):**
- **Docker** + the sandbox running:
  ```bash
  docker run --security-opt seccomp=unconfined -d -p 8080:8080 ghcr.io/agent-infra/sandbox:latest
  ```
  The `--security-opt seccomp=unconfined` flag is required (Docker's default seccomp blocks syscalls the sandbox needs; without it the container exits silently). Re-run after every Docker Desktop upgrade.
- A **reachable rust image** for the aarch64-linux cross-build (the sandbox is aarch64 Linux; the harness cross-builds the agent binary in an `arm64` rust container). The **first** build is slow; after that re-runs are **incremental** — the harness persists cargo's registry + compiled artifacts in docker volumes and bakes the OpenSSL build deps into a cached `agentkeys-sandbox-builder` image, recompiling only when a tracked source file changed (and restarting the sandbox MCP server when the binary changed). If Docker Hub is unreachable, pre-pull or point at a mirror: `RUST_BUILD_IMAGE=<local-or-mirror-rust-image>`.
- **Hermes** in the sandbox — the harness installs it (guarded `curl|bash`) if absent; needs GitHub reachable.

**Real mode only:**
- The `setup-heima.sh` account already created (the harness verifies, never rebuilds). It reads `operator_omni` + `actor_omni` from `~/.agentkeys/agents/demo-agent.json`.
- A non-expired master session at `~/.agentkeys/alice/session.json` (the harness reads its `.token` as the cap-mint bearer). If it's stale, refresh: `agentkeys init --session-id alice …`.
- `export OPENROUTER_API_KEY=...` in `~/.zshenv` — the harness uses it as the LLM-key fallback (no prompt).
- **For the 1.5 memory seed:** the master's primary K11 enrolled in **webauthn** mode — `agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x<operator>`. Without it, 1.5a's `heima-scope-set.sh --webauthn` skips the grant (and 1.5 fails loud with this exact command). Override the granted service list with `SEED_SCOPE_SERVICES` (it **sets** the full list, so include every service the agent needs).

## The manual gates (the "test through" essence)

- **LLM key** — auto from `OPENROUTER_API_KEY` (or `LLM_API_KEY`); only prompts if absent. Phase 4.0 writes it to the sandbox `~/.hermes/.env` and sets `provider: openrouter` + `model.default` (default `deepseek/deepseek-v4-flash`; override `LLM_MODEL`). A non-fatal `4.1 model smoke` confirms the model is live before the surprise.
- **Real Touch ID** — in real mode, **only when you pass `--webauthn`**: step 1.5 then self-grants the agent's memory scope via `heima-scope-set.sh --webauthn`. The banner prints `webauthn=<flag>` so you know upfront whether 1.5 may run a Touch ID ceremony. It's a hardware prompt — `--yes` does NOT bypass it (it only auto-confirms the software "proceed?" gate).
- **Seed the real memory worker** (`--real` only) — step **1.5** is idempotent + scope-aware: it tries `agentkeys memory put` **directly** (succeeds if the scope is already granted — no Touch ID); if rejected for scope, it grants via real Touch ID **only when `--webauthn` was passed**, then retries; without `--webauthn` it fails loud telling you to re-run with it. Skips entirely when the namespace already has content. Override `SEED_MEMORY_CONTENT` / `SEED_SCOPE_SERVICES`; fails loud with the `agentkeys k11 enroll --webauthn …` command if the grant is skipped (K11 not webauthn-enrolled).
- **The Hermes surprise** — open Hermes in the sandbox, send "where am I going this weekend?", and judge the memory-aware reply (`[y/N]`).

Pass `--yes` to auto-confirm the non-secret prompts.

## What you'll see (the three acts)

| Act | Hook | Expected |
|---|---|---|
| **1 — Permissioned Memory** | `pre_llm_call` → `memory-inject` | `{"context":"## Memory: travel\nChengdu trip — Apr 12 to 16, hotpot at Yulin."}` — the device reads only the `travel` namespace it's allowed to. |
| **2 — Deterministic Denial** | `pre_tool_call` → `check` | over-cap (600 > 500) → `{"decision":"block","reason":"daily_spend_cap_exceeded: cap=500, requested=600, period=daily"}`; under-cap (200) → `{}`. No LLM in the decision; **fails CLOSED** if the MCP server is unreachable. |
| **Auto-audit** | `post_tool_call` → `audit` | `{}` — a row lands in the off-chain feed; never blocks the agent loop. |

(Act 3 — Online Revocation — is out of scope for this harness; tested elsewhere.)

## Useful flags

```
--light           sandbox path, in-memory backend
--webauthn        real Touch ID at scope grant (real mode)
--unwire          remove the managed hooks block at teardown
--yes             auto-confirm non-secret prompts
--skip-N          skip phase N (0–5); e.g. --skip-4 to skip the surprise
--help
```

Env overrides: `SANDBOX_URL`, `MCP_PORT`, `SESSION_ID` (default `alice`),
`AGENT_LABEL` (default `demo-agent`), `MEMORY_NS` (default `travel`),
`OPENROUTER_API_KEY` / `LLM_API_KEY`, `LLM_MODEL` (default `deepseek/deepseek-v4-flash`) /
`LLM_BASE_URL`, `RUST_BUILD_IMAGE` (base image) ·
`BUILDER_IMAGE` / `CARGO_REGISTRY_VOL` / `CARGO_GIT_VOL` (build cache),
`SEED_MEMORY_CONTENT` / `SEED_SCOPE_SERVICES` (real-mode 1.5 seed),
`AGENTKEYS_ACTOR_OMNI` / `AGENTKEYS_OPERATOR_OMNI` / `AGENTKEYS_SESSION_BEARER`.

## Drift detection

```bash
agentkeys wire hermes --check-only   # report what WOULD change; write nothing
```
Re-running `agentkeys wire hermes` is always safe — unchanged scripts/config show `skip … matches`. Schedule `--check-only` nightly to catch manual edits to the managed block.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Phase 0 `0.7 session bearer` warns "looks expired" then cap-mint 401s | the `alice` session JWT expired (TTL ≤ 5h) | `agentkeys init --session-id alice …` to refresh |
| Phase 1 `1.3 linux build` → "cannot pull" | Docker Hub unreachable for the base image | `RUST_BUILD_IMAGE=<local/mirror rust image>` or pre-pull `rust:1.83-slim-bookworm` |
| `1.3 linux build` won't pick up a Rust edit | gate compares source mtime vs binary; re-runs rebuild automatically on a real edit | to force a from-scratch rebuild: `rm -rf target/sandbox-linux && docker volume rm agentkeys-sandbox-cargo-registry agentkeys-sandbox-cargo-git`; to rebuild the deps image: `docker rmi agentkeys-sandbox-builder:1.83-bookworm` |
| `wire` step 0 → `fail hermes not installed` | Hermes not on the sandbox PATH | the harness installs it; or run the guarded install (Appendix) — needs GitHub reachable |
| `wire` step 3 → `fail … already has a top-level hooks:` | hand-authored `hooks:` in `~/.hermes/config.yaml` | merge manually or remove it, then re-run |
| `hook check` blocks with `agentkeys_unreachable` | MCP server down | start it (the harness does in Phase 1); check `AGENTKEYS_MCP_URL` |
| `hook memory-inject` returns `{}` | namespace not granted/seeded | use a granted namespace (in-memory seeds `travel`/`family`/`profile`); check stderr for the skipped-namespace warning |
| MCP call → 401 | wrong vendor token | match `AGENTKEYS_MCP_VENDOR_TOKEN` to the server's `--vendor-tokens` (in-memory seeds `demo-tok`) |
| MCP call → 403 | actor header mismatch | `AGENTKEYS_ACTOR_OMNI` must match the server's actor |
| Memory swap not reflected | hooks fetch per-call but Hermes caches the LLM context | start a fresh Hermes session |
| Phase 1 `1.3 … upload failed` | sandbox upload API runs non-root → can't write `/usr/local/bin` (`Errno 13`) | fixed: binaries now upload to the writable `~/.local/bin` (on PATH); just re-run |
| Phase 4 surprise → "No inference provider configured" | key not in `~/.hermes/.env`, or wrong provider | 4.0 writes `OPENROUTER_API_KEY` to `~/.hermes/.env` + sets `provider: openrouter`; confirm `0.6 LLM key` shows `ok` |
| `agentkeys memory put` → `error: unrecognized subcommand 'memory'` (run by hand) | a **stale** `agentkeys` on your PATH predates the `memory` command | rebuild + reinstall: `cargo build --release -p agentkeys-cli && cp target/release/agentkeys ~/.local/bin/agentkeys`. The harness itself uses the freshly cross-built **sandbox** binary, so 1.5 is unaffected |
| `1.5a scope grant` → `grant SKIPPED` | the master's primary K11 isn't enrolled in webauthn mode | `agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x<operator>`, then re-run (the failure prints this exact command) |
| `1.5b seed memory` fails after the grant | master session expired, or the memory worker unreachable | refresh the session (`agentkeys init --session-id alice …`); check `AGENTKEYS_WORKER_MEMORY_URL` reachability |
| Phase 4 `4.1 model smoke` / surprise → HTTP 429 | OpenRouter throttling a `:free` model | retry, or use the paid default `LLM_MODEL=deepseek/deepseek-v4-flash` |
| Surprise reply says "nothing in memory" | wire hooks/MCP missing → `pre_llm_call` never injected | 4.0 now prechecks + fails loud; ensure Phases 1+2 ran (no `--skip-1/--skip-2`): `~/.hermes/agent-hooks/` exists + `:18088/healthz` up; use a fresh Hermes session |
| Phase 1 `1.4 mcp server … did not come up` → `Address already in use` | `MCP_PORT` collides with a sandbox service (8088 = built-in `gem-server`) | default is now `18088` (outside the sandbox's range); override `MCP_PORT` if it still clashes — check `ss -ltnp` in the sandbox |
| Hermes was memory-aware, now replies "nothing in memory" | the MCP server died, **or** a `--real` run flipped the sandbox to the live broker (no Chengdu fixture) | the MCP server now runs under a **respawn loop** (1.4), so a crash self-heals; if it's still down (e.g. a sandbox *container* restart killed the loop), bring it back with `bash harness/phase1-wire-demo.sh --light --skip-2 --skip-3 --skip-4 --skip-5` (Phases 0+1 only). If you ran `--real`, re-run `--light` to restore the in-memory fixture. Then ask again in a fresh Hermes turn. |

## Appendix A — what `agentkeys wire` writes (reference)

`~/.hermes/config.yaml` (managed block, sentinel-delimited — your other keys untouched):

```yaml
# >>> agentkeys wire (managed block — do not edit; re-run `agentkeys wire`) >>>
hooks:
  pre_tool_call:
    - matcher: "(?i)(pay|order|purchase|spend|checkout)"
      command: "~/.hermes/agent-hooks/agentkeys-pretool-permission-gate.sh"
      timeout: 5
  post_tool_call:
    - matcher: ".*"
      command: "~/.hermes/agent-hooks/agentkeys-posttool-audit.sh"
      timeout: 5
  pre_llm_call:
    - command: "~/.hermes/agent-hooks/agentkeys-prellm-memory-inject.sh"
      timeout: 5
hooks_auto_accept: true
# <<< agentkeys wire <<<
```

Each `~/.hermes/agent-hooks/*.sh` bakes the identity env (actor, operator, MCP URL, vendor token, session bearer) then `exec`s the matching `agentkeys hook …` helper with an absolute binary path.

## Appendix B — running by hand (what the harness automates)

The harness does these for you; run them manually only to understand the flow.

```bash
# 1. Sandbox (see Prerequisites).
# 2. MCP server (in-memory demo):
./target/release/agentkeys-mcp-server --backend in-memory --transport http --listen 127.0.0.1:18088
# (real: --backend http --broker-url … --memory-url … --audit-url … --vendor-tokens you:tok)

# 3. Install Hermes in the sandbox (idempotent):
curl -sS -X POST http://localhost:8080/v1/shell/exec -H 'content-type: application/json' \
  -d '{"command":"command -v hermes || curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash"}'

# 4. Wire (do NOT run `hermes setup` first — wire owns the IAM-gate config):
agentkeys wire hermes \
  --actor-omni 0x<64hex> --operator-omni 0x<64hex> \
  --namespaces travel --payment-scope payment.spend \
  --mcp-url http://localhost:18088/mcp --vendor-token "$TOKEN" \
  --session-bearer "$SESSION_JWT"

# 5. Exercise the acts directly (the wired scripts call these):
export AGENTKEYS_MCP_URL=http://127.0.0.1:18088/mcp AGENTKEYS_MCP_VENDOR_TOKEN=demo-tok
export AGENTKEYS_ACTOR_OMNI=0xa0c701…a0c7 AGENTKEYS_OPERATOR_OMNI=0x07e8a1…07e8
echo '{}'                                | agentkeys hook memory-inject --namespaces travel   # Act 1
echo '{"tool_input":{"amount_rmb":600}}' | agentkeys hook check --scope payment.spend          # Act 2 (block)
echo '{"tool_name":"x"}'                  | agentkeys hook audit                                # audit
```

## Cross-references

- [`harness/phase1-wire-demo.sh`](../harness/phase1-wire-demo.sh) — the harness this runbook drives
- [`docs/spec/plans/phase1-wire-harness-test-plan.md`](spec/plans/phase1-wire-harness-test-plan.md) — the action table + automation decisions
- [`docs/agent-iam-strategy.md`](agent-iam-strategy.md) §3.6/§3.7/§4.3 · [`docs/arch.md`](arch.md) §22d · [`docs/wiki/agent-iam-guarantee-glossary.md`](wiki/agent-iam-guarantee-glossary.md)
- [Issue #133](https://github.com/litentry/agentKeys/issues/133) — multi-runtime hook reference configs (Phase 1.b)
