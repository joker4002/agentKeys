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

# Real — the live product on your heima account + real broker/workers + Heima
# mainnet. Runs a FRESH §10.2 pairing EACH run: the agent generates its own key
# IN THE SANDBOX (never on the master), the master binds it on-chain, and
# --webauthn "approves" the memory scope via Touch ID. Then it seeds + recalls
# the Chengdu memory. Expect ONE Touch ID + one on-chain tx per run.
bash harness/phase1-wire-demo.sh --real --webauthn
```

**A mode is REQUIRED** — `--light` or `--real`. The harness refuses to guess
(running `--real` by accident flips the sandbox MCP to the live broker and loses
the in-memory demo fixture). It prints a loud `MODE:` banner so the active mode
is never ambiguous. Every step prints `ok proceeding` / `skip <reason>` /
`fail <reason>`; the harness is idempotent — re-running is safe.

## How to run — the `--real --webauthn` walkthrough

One command runs the whole "install an app → approve its permissions → use it"
story. Each run does a **fresh pairing** (a brand-new agent identity), so expect
**one Touch ID + one on-chain tx per run**.

1. **Start the sandbox** (once — the harness checks but will not start it):
   ```bash
   docker run --security-opt seccomp=unconfined -d -p 8080:8080 ghcr.io/agent-infra/sandbox:latest
   ```
2. **Run it** from a shell where `OPENROUTER_API_KEY` is exported (see Prerequisites — a shell opened *before* you added the line to `~/.zshenv` won't have it; `source ~/.zshenv` or open a new shell):
   ```bash
   bash harness/phase1-wire-demo.sh --real --webauthn
   ```
3. **What happens, in order:**
   - **Phase 0** — prereqs + operator session (auto-minted from the master key).
   - **Phase 1** — sandbox up → Hermes installed → clean slate (1.2b) → binaries (re)built + uploaded (first build ~1 min).
   - **Phase P — install (pair)** 📲
     - `P.1` the agent generates its **own device key in the sandbox** + mints a session (the key never touches the master).
     - `P.2` the master binds that device **on-chain** (`registerAgentDevice`).
     - `P.3` **🔐 Touch ID** — the master *approves* the agent's `[memory]` permission (on-chain scope grant).
   - **1.4–1.5** — MCP server (per-actor STS relay) starts; the fresh actor's memory is seeded (new identity ⇒ empty ⇒ seeds "Chengdu trip").
   - **Phase 2** — `agentkeys wire hermes` installs the IAM-gate hooks.
   - **Phase 4 — the surprise** — talk to Hermes and ask **"where am I going this weekend?"** → it recalls Chengdu (memory it *just earned permission to read*).
4. **Talk to Hermes** for the surprise: open the printed `code-server` URL, or
   ```bash
   docker exec -it <sandbox-container> bash -lc "hermes chat"
   ```
   Ask a **natural** question ("where am I going this weekend?"). (An *active* "query my agentkeys memory" may make Hermes improvise — see Troubleshooting.)

**Fast-iterate fallback:** `--reuse-agent` (or `AGENTKEYS_REUSE_AGENT=1`) skips the
fresh pairing and reuses a single master-side agent — no per-run Touch ID / tx.
Note it puts the agent key back on the master; use only for quick loops.

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
| **The Chengdu surprise** | ✅ works out of the box | ✅ **Phase P pairs + approves the scope (Touch ID), then 1.5 seeds** the fresh actor's memory — run **`--real --webauthn`**. The new agent identity starts with empty memory, so 1.5 always seeds it. Needs a live master session + K11 enrolled in webauthn mode |
| **Broker / chain** | none | real broker (`signer.litentry.org`) + Heima **mainnet** |
| **Account** | a fixed demo actor/operator | your master (operator) + a **fresh agent identity generated in the sandbox each run** (`--reuse-agent` reuses one master-side agent) |
| **Cap-mint** | stubbed — always succeeds | real cap-mint (needs a valid master session) |
| **Vendor token** | `demo-tok` | `harness-tok` |
| **Touch ID** | never | at **Phase P (P.3)** EACH run when you pass `--webauthn` — the master *approves* the fresh agent's `[memory]` scope; never otherwise |
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
- The `setup-heima.sh` account already created (master device registered + contracts deployed; the harness verifies, never rebuilds). `OPERATOR_OMNI` is derived from your master key (`OPERATOR_KEY_FILE`); the **agent** identity is generated fresh in the sandbox by Phase P (no pre-existing agent file needed in the default fresh-pairing mode).
- An **operator session JWT** for cap-mint. The harness now mints this **automatically and non-interactively**: step `0.7` decodes the on-disk session, and if it's missing, expired, **or for the wrong operator** (its `agentkeys.omni_account` ≠ the agent's `operator_omni`), it SIWE-signs a fresh one with `OPERATOR_KEY_FILE` (default `~/.agentkeys/heima-deployer.key` — the master key whose broker omni == `operator_omni`) via the broker's `wallet_sig` plugin. Requires `cast` (Foundry) on PATH. **Note:** the old `alice` email session is a *different* omni and is no longer used for cap-mint — set `OPERATOR_KEY_FILE` to the master key for your operator if the default isn't it. (Pass `AGENTKEYS_SESSION_BEARER` to override entirely.)
- **For real memory (S3) to work:** **Phase P** generates the agent's device key **in the sandbox** and mints its **agent session** there (`agentkeys agent device-session`); the MCP server uses that session for the per-actor STS relay (`mint-oidc-jwt` → `AssumeRoleWithWebIdentity` → `X-Aws-*` headers to the worker), so the agent key never touches the master. Needs the per-data-class role ARNs (`MEMORY_ROLE_ARN`/`VAULT_ROLE_ARN`, from `operator-workstation.env`). Without the relay the worker falls back to its instance profile (no S3) and memory ops 502. (`--reuse-agent` instead mints the session on the master from `agent_private_key` in the agent file — legacy.)
- `export OPENROUTER_API_KEY=...` in `~/.zshenv` — the harness uses it as the LLM-key fallback (no prompt).
- **For the Phase P scope grant (P.3):** the master's primary K11 enrolled in **webauthn** mode — `agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x<operator>`. Without it, `heima-scope-set.sh --webauthn` can't run and the freshly-paired agent never gets the memory scope (memory ops will be scope-rejected). Override the granted service list with `SEED_SCOPE_SERVICES` (it **sets** the full list, so include every service the agent needs).

## The manual gates (the "test through" essence)

- **LLM key** — auto from `OPENROUTER_API_KEY` (or `LLM_API_KEY`); only prompts if absent. Phase 4.0 writes it to the sandbox `~/.hermes/.env` and sets `provider: openrouter` + `model.default` (default `deepseek/deepseek-v4-flash`; override `LLM_MODEL`). A non-fatal `4.1 model smoke` confirms the model is live before the surprise.
- **Install (pair)** — `--real` only: **Phase P** generates the agent's device key **in the sandbox** (`P.1`), the master binds it on-chain (`P.2`), and — with `--webauthn` — the master **approves** the agent's memory scope via Touch ID (`P.3`). Because every run pairs a **fresh** identity, this happens once per run. `--reuse-agent` skips it.
- **Real Touch ID** — in real mode with `--webauthn`: **Phase P (P.3)** grants the freshly-paired agent's memory scope via `heima-scope-set.sh --webauthn`. The banner prints `webauthn=<flag>` so you know upfront whether a Touch ID ceremony will run. It's a hardware prompt — `--yes` does NOT bypass it (it only auto-confirms the software "proceed?" gates). Without `--webauthn`, `P.3` is skipped (the agent won't be able to read memory) — re-run with `--real --webauthn`.
- **Seed the real memory worker** (`--real` only) — after pairing, step **1.5** writes the Chengdu fixture into the fresh actor's namespace (a brand-new identity always starts empty). Override `SEED_MEMORY_CONTENT` / `SEED_SCOPE_SERVICES` (the latter is the service set Phase P grants — it **sets** the full list).
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
--real            live broker + workers + Heima mainnet + fresh §10.2 pairing
--webauthn        real Touch ID at the Phase P scope grant (real mode)
--reuse-agent     skip fresh pairing; reuse one master-side agent (fast iterate)
--unwire          remove the managed hooks block at teardown
--yes             auto-confirm non-secret prompts
--skip-N          skip phase N (0–5); e.g. --skip-4 to skip the surprise
--help
```

Env overrides: `SANDBOX_URL`, `MCP_PORT`, `SESSION_ID` (default `alice`),
`AGENT_LABEL` (default `demo-agent`), `MEMORY_NS` (default `travel`),
`OPENROUTER_API_KEY` / `LLM_API_KEY`, `LLM_MODEL` (default `deepseek/deepseek-v4-flash`) /
`LLM_BASE_URL`, `RUST_BUILD_IMAGE` (base image) ·
`BUILDER_IMAGE` / `CARGO_REGISTRY_VOL` / `CARGO_GIT_VOL` / `RUSTUP_VOL` (build cache),
`SBX_EXEC_MAXTIME` (per-sandbox-call ceiling, default 600s),
`SEED_MEMORY_CONTENT` / `SEED_SCOPE_SERVICES` (real-mode 1.5 seed),
`OPERATOR_KEY_FILE` (master key for the 0.7 operator-session mint),
`AGENTKEYS_REUSE_AGENT=1` (skip Phase P fresh pairing; reuse a master-side agent) ·
`AGENTKEYS_AGENT_SESSION_BEARER` (override the agent session) ·
`MEMORY_ROLE_ARN` / `VAULT_ROLE_ARN` / `REGION` (per-actor STS relay; sourced from `operator-workstation.env`),
`AGENTKEYS_ACTOR_OMNI` / `AGENTKEYS_OPERATOR_OMNI` / `AGENTKEYS_SESSION_BEARER`.

## Drift detection

```bash
agentkeys wire hermes --check-only   # report what WOULD change; write nothing
```
Re-running `agentkeys wire hermes` is always safe — unchanged scripts/config show `skip … matches`. Schedule `--check-only` nightly to catch manual edits to the managed block.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| cap-mint → 401 `ExpiredSignature` | the operator session JWT expired | the harness now auto-mints a fresh one at `0.7` via `wallet_sig` (`OPERATOR_KEY_FILE`). If it didn't: ensure `cast` is on PATH and `OPERATOR_KEY_FILE` exists |
| cap-mint → 401/`OperatorMismatch` (`session_omni != operator_omni`) | the session is for a *different* operator (e.g. the legacy `alice` email session, omni `4231cd8f…` ≠ agent operator `941cb1c3…`) | `0.7` now detects the omni mismatch and re-mints from `OPERATOR_KEY_FILE`. If `0.7` fails with "wrong operator", point `OPERATOR_KEY_FILE` at the master key whose broker omni == `operator_omni` |
| memory put/get → HTTP **502** `{"reason":"s3_put"}` / `{"reason":"s3_get"}` | the MCP `http` backend didn't forward per-actor STS creds, so the worker fell back to its EC2 instance profile (SES-only, **no S3**) → AccessDenied on every op. cap-mint + chain-verify themselves SUCCEED (the agent IS authorized); the gap was the credential **relay**. | **Fixed (issue #90):** the backend now mints agent-tagged STS creds (`0.8` agent session → broker `/v1/mint-oidc-jwt` → `AssumeRoleWithWebIdentity(memory-role)`, tagged `agentkeys_actor_omni`) and forwards them as `X-Aws-*` headers, so AWS scopes S3 to `bots/<actor>/memory/`. If it still 502s: confirm `P.1 device-session` shows "agent paired" (or `0.8 agent session` under `--reuse-agent`) and `P.3 approve permissions` granted the scope; the relay needs the in-sandbox agent session + `MEMORY_ROLE_ARN`/`VAULT_ROLE_ARN`/`REGION` from `operator-workstation.env`. Optional strict enforcement: set `AGENTKEYS_WORKER_REQUIRE_STS=1` in the worker env (rejects credless requests with 401 instead of falling back). |
| **Phase P** `P.1`/`P.2`/`P.3` fails | `P.1` device-session: stale sandbox `agentkeys` (no `agent device-session` subcommand) or broker `/v1/auth/wallet/*` down. `P.2` register: on-chain `registerAgentDevice` failed (master gas / RPC). `P.3` approve: `heima-scope-set --webauthn` needs K11 webauthn enrollment + Touch ID. | `P.1` 1.3 rebuilds+uploads the binary — just re-run. `P.2` check the master wallet balance / RPC. `P.3` enroll K11 webauthn + pass `--webauthn`. For a quick loop without pairing use `--reuse-agent`. |
| `1.3 linux build` is slow even for a one-line change | rustup re-downloaded the host-pinned toolchain (~250 MB, ~4 min) because `/usr/local/rustup` wasn't cached | fixed: the toolchain now persists in the `RUSTUP_VOL` docker volume — the **first** build seeds it (~4 min), later builds skip the download (incremental compile only, ~15 s) |
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
| `1.5b seed memory` fails after the grant (`memory.put` failed) | (a) the operator session was stale/wrong-omni — now auto-minted at `0.7`; (b) the worker 502'd because the per-actor STS relay wasn't wired — now fixed (the MCP backend forwards `X-Aws-*` creds; see the 502 row) | confirm `0.7` shows "operator session ready" AND `0.8 agent session` shows "minted (omni == actor_omni)"; the `{:#}` CLI error now prints the full chain if it still fails |
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
