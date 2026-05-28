# Operator runbook — `agentkeys wire` fresh-user onboarding

The 7-step fresh-user journey from [`docs/spec/plans/phase-1-fresh-user-wire-onboarding.md`](spec/plans/phase-1-fresh-user-wire-onboarding.md), with copy-pasteable commands. Goal: a fresh user reaches the Agent IAM "surprise" moment (memory-aware first conversation + deterministic denial + revocation) in under 15 minutes, with **zero manual config-file editing**.

> **Architecture**: AgentKeys is the Authority Host; the Task Host (Hermes) does the work. `agentkeys wire hermes` writes the IAM-guarantee hooks into Hermes's config so the LLM cannot bypass `permission.check` / `audit.append` / memory injection. See [`docs/agent-iam-strategy.md`](agent-iam-strategy.md) §3.6–3.7 + [`docs/arch.md`](arch.md) §22d + [`docs/wiki/agent-iam-guarantee-glossary.md`](wiki/agent-iam-guarantee-glossary.md).

## 0. Prerequisites

| Dep | Install | Verify |
|---|---|---|
| Rust toolchain | `rustup default stable` | `cargo --version` |
| `jq` (smoke tests) | `brew install jq` | `jq --version` |
| aiosandbox (for the full device demo) | `docker run --security-opt seccomp=unconfined --rm -it -p 8080:8080 ghcr.io/agent-infra/sandbox:latest` | banner at `http://localhost:8080` |
| Hermes (the Task Host) | inside the sandbox: `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \| bash` (idempotent — see below) | `hermes --version` |

Build the AgentKeys binaries once:

```bash
cargo build --release -p agentkeys-cli -p agentkeys-mcp-server
# binaries: target/release/agentkeys, target/release/agentkeys-mcp-server
```

## 1. Install aiosandbox

```bash
docker run --security-opt seccomp=unconfined --rm -it -p 8080:8080 \
  ghcr.io/agent-infra/sandbox:latest
```

The `--security-opt seccomp=unconfined` flag is required — Docker's default seccomp profile blocks syscalls the sandbox needs, and without it the container exits silently. Re-run after every Docker Desktop upgrade.

## 2. Install + bootstrap the AgentKeys CLI

```bash
# Production: curl -fsSL https://agentkeys.io/install.sh | bash
# Dev: use the freshly built binary
alias agentkeys=./target/release/agentkeys
agentkeys init --email you@example.com --broker-url https://broker.example --signer-url https://signer.example
```

`init` derives the device key and requests pairing (arch.md §10.2 link-code flow). For the local demo you can skip real pairing and use the in-memory MCP backend (step 4) which seeds a demo actor.

## 3. On the master device: provision creds + memory scopes

```bash
agentkeys store openai sk-...           # LLM API key → credential broker
agentkeys scope --agent <actor> --add memory.read,payment.check
# memory namespaces are seeded server-side for the demo (travel/family/profile)
```

## 4. Start the AgentKeys MCP server (the tool surface)

For the local demo, run the in-memory backend — it seeds the demo actor, a `magiclick:demo-tok` vendor token, and the `travel` / `family` / `profile` memory namespaces:

```bash
./target/release/agentkeys-mcp-server \
  --backend in-memory --transport http --listen 127.0.0.1:8088
```

Production points at the real broker + workers:

```bash
./target/release/agentkeys-mcp-server \
  --backend http --transport http --listen 127.0.0.1:8088 \
  --broker-url https://broker.example --memory-url https://memory.example \
  --audit-url https://audit.example --vendor-tokens "yourvendor:$TOKEN"
```

## 5. Install a Task Host (do NOT run its setup wizard)

Inside the sandbox (idempotent — skips if already installed):

```bash
curl -sS -X POST http://localhost:8080/v1/shell/exec \
  -H 'content-type: application/json' \
  -d @- <<'JSON' | jq -r '.data.output'
{"command": "if command -v hermes >/dev/null 2>&1; then echo \"skip hermes already installed\"; else curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash; fi"}
JSON
```

Do **not** run `hermes setup` — `agentkeys wire` handles the IAM-gate config.

## 6. `agentkeys wire hermes` — the one command

```bash
agentkeys wire hermes
```

This idempotently:
1. detects the installed Hermes version,
2. writes 3 hook scripts to `~/.hermes/agent-hooks/` (pre-tool permission gate, post-tool audit, pre-llm memory inject) with the actor/operator/MCP-URL/token baked in,
3. appends a managed `hooks:` block to `~/.hermes/config.yaml` (preserving your other keys; refuses to clobber a hand-authored `hooks:`),
4. sets `hooks_auto_accept: true` (Hermes first-use consent pre-approval),
5. verifies with `hermes hooks doctor`.

Expected output (every step `ok proceeding`; re-runs show `skip … matches`):

```
[agentkeys wire hermes]
  step 0 detect: ok proceeding (Hermes Agent v0.14.0 ...)
  step 1 hooks-dir: ok proceeding (~/.hermes/agent-hooks ready)
  step 2.1 script agentkeys-pretool-permission-gate.sh: ok proceeding (wrote ...)
  step 2.2 script agentkeys-posttool-audit.sh: ok proceeding (wrote ...)
  step 2.3 script agentkeys-prellm-memory-inject.sh: ok proceeding (wrote ...)
  step 3 config-block: ok proceeding (appended managed block to ~/.hermes/config.yaml)
  step 4 consent: ok proceeding (hooks_auto_accept: true set in managed block)
  step 5 verify: ok proceeding (hermes hooks doctor passed)
[agentkeys wire hermes] wired — restart the runtime to load the hooks
```

Override identity / scopes when not using the in-memory demo defaults:

```bash
agentkeys wire hermes \
  --actor-omni 0x<64hex> --operator-omni 0x<64hex> \
  --namespaces travel,family --payment-scope payment.spend \
  --mcp-url http://localhost:8088/mcp --vendor-token "$TOKEN"
```

## 7. The three-act demo (verify the IAM guarantees)

Each hook is independently testable by piping a synthetic host payload to the `agentkeys hook` helper. With the in-memory MCP server from step 4 running:

```bash
export AGENTKEYS_MCP_URL=http://127.0.0.1:8088/mcp
export AGENTKEYS_MCP_VENDOR_TOKEN=demo-tok
export AGENTKEYS_ACTOR_OMNI=0xa0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c701a0c7
export AGENTKEYS_OPERATOR_OMNI=0x07e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8a107e8
```

**Act 1 — Permissioned Memory** (`pre_llm_call` hook injects the `travel` namespace):

```bash
echo '{"hook_event_name":"pre_llm_call"}' | agentkeys hook memory-inject --namespaces travel
# → {"context":"## Memory: travel\nChengdu trip — Apr 12 to 16, hotpot at Yulin."}
```

The device reads ONLY the `travel` namespace it's allowed to read. Try `--namespaces family,profile` to see other scoped reads; an un-granted namespace is skipped with a non-fatal warning (namespace isolation).

**Act 2 — Deterministic Denial** (`pre_tool_call` hook blocks an over-cap spend, no LLM in the decision):

```bash
echo '{"tool_input":{"amount_rmb":600}}' | agentkeys hook check --scope payment.spend
# → {"decision":"block","reason":"daily_spend_cap_exceeded: cap=500, requested=600, period=daily"}

echo '{"tool_input":{"amount_rmb":200}}' | agentkeys hook check --scope payment.spend
# → {}   (under cap — allowed)
```

`check` **fails CLOSED**: if the MCP server is unreachable, the tool call is blocked.

**Act 3 — Online Revocation**: revoke the payment scope from the master device, then repeat the Act 2 under-cap call — it now blocks. (Revocation UI is the parent-control web surface; CLI: `agentkeys revoke` / `agentkeys scope --remove`.)

**Auto-audit** (`post_tool_call` hook, never blocks):

```bash
echo '{"tool_name":"order_hotpot","tool_input":{"amount_rmb":600}}' | agentkeys hook audit
# → {}   (audit row appended to the off-chain feed; never blocks the agent loop)
```

## 8. Drift detection (idempotency + nightly check)

```bash
agentkeys wire hermes --check-only
# reports what WOULD change without writing; exit 0 if in sync
```

Re-running `agentkeys wire hermes` (without `--check-only`) is always safe — unchanged scripts/config show `skip … matches`. Schedule `--check-only` nightly to detect manual edits to the managed block.

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `wire` step 0 → `fail hermes not installed` | Hermes not on PATH | install Hermes (step 5); ensure `hermes --version` works |
| `wire` step 3 → `fail … already has a top-level hooks:` | hand-authored `hooks:` in config.yaml | merge manually or remove it, then re-run |
| `hook check` always blocks with `agentkeys_unreachable` | MCP server down | start the MCP server (step 4); check `AGENTKEYS_MCP_URL` |
| `hook memory-inject` returns `{}` | namespace not seeded / not granted | use a granted namespace (demo seeds `travel`/`family`/`profile`); check stderr for the skipped-namespace warning |
| MCP call → 401 | wrong vendor token | match `AGENTKEYS_MCP_VENDOR_TOKEN` to the server's `--vendor-tokens` (in-memory seeds `demo-tok`) |
| MCP call → 403 | actor header mismatch | `AGENTKEYS_ACTOR_OMNI` must match the server's actor (in-memory: the demo actor `0xa0c701…`) |
| Memory swap not reflected | hooks fetch per-call, but Hermes caches the LLM context | start a fresh Hermes session |

## 10. What the wire command writes (reference)

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

Each `~/.hermes/agent-hooks/*.sh` bakes the identity env (actor, operator, MCP URL, vendor token) then `exec`s the matching `agentkeys hook …` helper with an absolute binary path.

## 11. Cross-references

- [`docs/spec/plans/phase-1-fresh-user-wire-onboarding.md`](spec/plans/phase-1-fresh-user-wire-onboarding.md) — the plan this runbook operationalizes
- [`docs/agent-iam-strategy.md`](agent-iam-strategy.md) §3.6 (IAM tool vs guarantee), §3.7 (wire decision), §4.3 (three-act demo)
- [`docs/arch.md`](arch.md) §22d — IAM-guarantee delivery (hooks-first)
- [`docs/wiki/agent-iam-guarantee-glossary.md`](wiki/agent-iam-guarantee-glossary.md) — hook availability across runtimes
- [Issue #133](https://github.com/litentry/agentKeys/issues/133) — multi-runtime hook reference configs (Phase 1.b: Claude Code, Codex, OpenClaw)
