> **Archived 2026-05-28.** Superseded by [`../spec/plans/phase-1-fresh-user-wire-onboarding.md`](../spec/plans/phase-1-fresh-user-wire-onboarding.md) (the new Phase 1 plan using real Hermes + `agentkeys wire`). Architecture content from §6 lives in [`../arch.md`](../arch.md) §22d + [`../wiki/agent-iam-guarantee-glossary.md`](../wiki/agent-iam-guarantee-glossary.md). **Do not follow this runbook — the artifacts it provisions (`agentkeys-hermes-runtime` crate, daemon `--demo-memory` flag, extended sandbox image) are obsolete.**

# Demo runbook — aiosandbox + Hermes agent (issue [#103](https://github.com/litentry/agentKeys/issues/103))

Live walk-through for the hardware-vendor wedge demo. Goal: a vendor sees a
device-like client talking to a cloud agent that already "knows" the user, in
under 5 minutes.

> **Scope**: this runbook covers the **sandbox + Hermes runtime + daemon** side
> only. The ESP32 firmware side is deferred — placeholders are marked
> `(firmware: deferred)`. A `curl` from a laptop substitutes for the device.

## 1. Prerequisites

| Dep | How to install | Verify |
|---|---|---|
| Rust toolchain | `rustup default stable` | `cargo --version` |
| Docker (only if you want the container image) | Docker Desktop | `docker --version` |
| `aws` CLI (only if you want S3-backed memory) | `brew install awscli` | `aws --version` |
| `jq` (smoke-test) | `brew install jq` | `jq --version` |
| LLM API key (only if you want non-stub LLM) | DashScope console / OpenRouter / Anthropic | `echo $AGENTKEYS_LLM_API_KEY` |

AWS profile must already be wired per
[CLAUDE.md "AWS local-profile ↔ remote-IAM mapping"](../CLAUDE.md) — typically
`agentkeys-admin` for S3 bucket creation.

## 2. One-command setup (cloud side)

```bash
bash scripts/setup-demo-aiosandbox.sh --yes
```

Default behavior:

| Step | Action |
|---|---|
| 1 | Builds `target/release/agentkeys-daemon` + `agentkeys-hermes-runtime` |
| 2 | Builds the `agentkeys/aiosandbox-demo:latest` docker image |
| 3 | Creates the `agentkeys-demo-memory` S3 bucket in `us-east-1` (idempotent) |
| 3a | Enables versioning on the bucket |
| 4 | Uploads `tests/fixtures/demo-profile.md` to `s3://agentkeys-demo-memory/bots/O_demo_001/memory/profile.md` (skipped if ETag matches local md5) |
| 5 | Prints the env block to copy into your deploy |

Air-gapped local-only run (no AWS, bundled fixture compiled into the binary):

```bash
bash scripts/setup-demo-aiosandbox.sh --no-s3 --yes
```

To re-run a step: delete its idempotency anchor (binary, image, bucket, or
object) and re-invoke — `setup-demo-aiosandbox.sh` short-circuits everything
else.

## 3. Stock sandbox first-boot smoke test (optional, ~1 min)

Before building the extended image, sanity-check that the stock
`agent-infra/sandbox` boots on your Docker setup. **You MUST pass
`--security-opt seccomp=unconfined`** — Docker Desktop's default seccomp
profile blocks syscalls the sandbox needs, and without the flag the
container silently exits.

```bash
docker run --security-opt seccomp=unconfined --rm -it -p 8080:8080 \
  ghcr.io/agent-infra/sandbox:latest
```

You should see the AIO banner:

```
🚀 AIO(All-in-One) Agent Sandbox Environment
📦 Image Version: 1.0.0.152
🌈 Dashboard: http://localhost:8080
📚 Documentation: http://localhost:8080/v1/docs
```

Open `http://localhost:8080` and confirm the dashboard loads, then Ctrl-C.
This is the base layer the demo image extends; if this step fails, no
amount of AgentKeys debugging will help. Re-run it after every Docker
Desktop upgrade — seccomp defaults change between Docker versions.

Once the dashboard is up, the sandbox exposes (see banner output):

| URL | Purpose |
|---|---|
| `http://localhost:8080/v1/docs` | FastAPI Swagger — every shell / code / file / browser / MCP endpoint |
| `http://localhost:8080/vnc/index.html?autoconnect=true` | VNC browser session (for browser-action tools) |
| `http://localhost:8080/code-server/` | Full VSCode-in-browser (interactive shell + editor) |
| `http://localhost:8080/mcp` | Streamable-HTTP MCP transport (requires `Accept: text/event-stream`) |
| `http://localhost:8080/v1/mcp/servers` | List of MCP servers the sandbox itself exposes (default: `browser`, `chrome_devtools`) |

## 4. Install NousResearch hermes-agent inside the sandbox

The plan-doc pivot banner ([docs/spec/plans/issue-103-aiosandbox-hermes-esp32-demo.md](spec/plans/issue-103-aiosandbox-hermes-esp32-demo.md) §C4)
deprecates the custom Rust Hermes runtime in favor of NousResearch's
[`hermes-agent`](https://github.com/NousResearch/hermes-agent) installed
via its official installer. The `agentkeys-hermes-runtime` crate shipped
in this PR is a **thin memory-bridge in front of the LLM** — it remains
useful as the `/v1/chat` entry point that injects AgentKeys memory into
the system prompt; it does NOT replace hermes-agent's planner/orchestrator.

Install inside the running container (or bake into a future image
revision). **The install is idempotent** — wrapped in a `command -v
hermes` check so a re-run is a no-op:

```bash
# From your laptop (host), open a sandbox shell via the sandbox's own
# shell-exec API — see §5 for why we use this path instead of `docker exec`.
curl -sS -X POST http://localhost:8080/v1/shell/exec \
  -H 'content-type: application/json' \
  -d @- <<'JSON' | jq -r '.data.output'
{
  "command": "if command -v hermes >/dev/null 2>&1; then echo \"skip hermes already installed at $(command -v hermes) ($(hermes --version 2>/dev/null || echo unknown))\"; else curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash && echo \"ok hermes installed at $(command -v hermes)\"; fi"
}
JSON
```

Expected output on first run: `ok hermes installed at /home/gem/.local/bin/hermes` (or wherever the installer places it).
Expected output on re-run: `skip hermes already installed at /home/gem/.local/bin/hermes (...)` — exit 0, nothing reinstalled.

Alternatively, run the same guarded one-liner inside `http://localhost:8080/code-server/`'s terminal panel:

```bash
if command -v hermes >/dev/null 2>&1; then
  echo "skip hermes already installed at $(command -v hermes)"
else
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
fi
```

After install, verify:

```bash
curl -sS -X POST http://localhost:8080/v1/shell/exec \
  -H 'content-type: application/json' \
  -d '{"command":"command -v hermes && hermes --version"}' \
  | jq -r '.data.output'
```

**Where this leaves the components in this PR:**

| Component (this PR) | Role after NousResearch hermes lands |
|---|---|
| `agentkeys-daemon --demo-memory` | Unchanged — serves `/v1/memory/{actor}/profile.md`. The single source of truth for "what does the device know about the user." |
| `agentkeys-hermes-runtime` (Rust crate) | Thin memory-injection bridge in front of a hosted LLM. Useful when the deployment doesn't run hermes-agent (zero-orchestration mode) or wants a stable `/v1/chat` API contract for the ESP32. |
| NousResearch hermes-agent (this install) | Full agentic orchestrator inside the sandbox. Calls back into AgentKeys for memory via the daemon's HTTP endpoint (or, eventually, via the MCP path in §6). |

## 5. Harness the sandbox from Claude Code (master machine)

The sandbox exposes a clean FastAPI surface at `http://localhost:8080/v1/*`.
Two patterns work cleanly from Claude Code on the host:

**Pattern A — POST /v1/shell/exec (one-shot, recommended for harness):**

```bash
curl -sS -X POST http://localhost:8080/v1/shell/exec \
  -H 'content-type: application/json' \
  -d '{"command":"<your shell command here>"}' \
  | jq .
# → { "success": true, "data": { "output": "...", "exit_code": 0, ... } }
```

This is what I used to install hermes above. The response includes
`output`, `exit_code`, and a `session_id` for follow-up calls. Stateless,
JSON-in/JSON-out — ideal for Claude Code's Bash tool.

**Pattern B — persistent shell session (multi-turn):**

```bash
# Create a session
SID=$(curl -sS -X POST http://localhost:8080/v1/shell/sessions/create \
  -H 'content-type: application/json' \
  -d '{}' | jq -r '.data.session_id')

# Send a command, get streamed output
curl -sS -X POST http://localhost:8080/v1/shell/exec \
  -H 'content-type: application/json' \
  -d "{\"session_id\":\"$SID\",\"command\":\"cd /home/gem && ls\"}" | jq .

# Continue using $SID across calls — cwd, env vars persist.
curl -sS -X DELETE "http://localhost:8080/v1/shell/sessions?session_id=$SID"
```

Other useful endpoints (see `http://localhost:8080/v1/docs` for the full
Swagger surface):

| Endpoint | Use for |
|---|---|
| `POST /v1/code/execute` | One-shot Python/Node/etc. with stdout+stderr capture |
| `POST /v1/jupyter/execute` | Persistent Jupyter kernel with stateful variables |
| `POST /v1/nodejs/execute` | One-shot Node.js |
| `POST /v1/file/{read,write,list,replace}` | File operations — preferred over `cat`/`sed` via shell |
| `GET /v1/shell/terminal-url` | Get the VNC terminal URL for visual debugging |
| `POST /v1/browser/actions` | Playwright-driven browser actions (paired with `/v1/browser/screenshot`) |

**Why this beats `docker exec`:**

- The sandbox's shell-exec API runs commands as the `gem` user the same way
  supervisord does — no UID/PATH/env drift between harness commands and what
  the deployed agent sees.
- Session-mode preserves cwd and env across calls, which `docker exec` does not.
- The same surface works against a remote sandbox over HTTPS, so the harness
  pattern is identical local-vs-cloud.

## 6. AgentKeys + aiosandbox MCP architecture — recommendation

Anchors used here:
- [`docs/agent-iam-strategy.md`](agent-iam-strategy.md) — AgentKeys is the **Authority Host**, never a Task Host; zero orchestration in v1 (§2.1, §2.4); MCP is the integration surface, not the product identity (§2.3); seven active MCP tools for Phase 1 (§4.2: `identity.whoami`, `memory.get`, `memory.put`, `permission.check`, `cap.mint`, `cap.revoke`, `audit.append`).
- aiosandbox MCP surface (verified live on the running container):
  - `POST http://localhost:8080/mcp` — streamable-HTTP transport, no auth documented.
  - Default MCP servers reported by `GET /v1/mcp/servers`: `browser`, `chrome_devtools`. Docs list four logical groups (browser, file, terminal, markitdown) accessible via the same `/mcp` endpoint.
  - **No public API to register external MCP servers into the sandbox process itself** — aiosandbox is a *sandbox primitive*, not an MCP gateway.
- [Issue #133](https://github.com/litentry/agentKeys/issues/133) — LLM-host hook integration is the **guardrail layer that doesn't depend on LLM discretion**. Pre-payment gate, auto-audit, session summary all live in the Task Host's hook system, not in the LLM's free will.

### 6.1 The four moving parts (canonical model)

```
┌─────────────────────────────────────┐
│ Vendor surface                       │  ← chatbot, mobile app, device
│ (whatever the vendor ships to users) │
└───────────────────┬─────────────────┘
                    │ (chat / WebSocket / vendor protocol)
                    v
┌─────────────────────────────────────────────────────────────┐
│ Task Host  (orchestrator + lifecycle hooks)                  │
│   examples: Hermes-agent, OpenClaw, xiaozhi-server, Claude   │
│             Code, Codex/ChatGPT                              │
│                                                              │
│   PreToolUse  → calls agentkeys.permission.check  (#133)    │
│   PostToolUse → calls agentkeys.audit.append      (#133)    │
│   Stop        → calls agentkeys.memory.put        (#133)    │
└─────────┬───────────────────────────────────┬───────────────┘
          │ MCP                               │ MCP
          v                                   v
┌──────────────────────────┐   ┌──────────────────────────────┐
│ aiosandbox primitives    │   │ AgentKeys (Authority Host)    │
│ POST localhost:8080/mcp  │   │ POST agentkeys-mcp/.../mcp    │
│   browser, file,         │   │   identity.whoami             │
│   terminal, markitdown   │   │   memory.get / memory.put     │
│ Sandbox-substrate tools  │   │   permission.check            │
│ for what the agent DOES  │   │   cap.mint / cap.revoke       │
│ in the world             │   │   audit.append                │
└──────────────────────────┘   └──────────────────────────────┘
```

**Four roles, intentionally distinct:**

1. **Vendor surface** — the user-facing channel. AgentKeys never touches this.
2. **Task Host** — the agent runtime that plans, retries, executes, owns lifecycle hooks. Per strategy doc §2.1/§2.4 we never become one of these.
3. **Sandbox primitives** — aiosandbox supplies the kernel-isolated execution substrate (browser, file, shell, markitdown). It is *not* a Task Host; the Task Host runs *inside* it.
4. **Authority Host** — AgentKeys. Identity, memory, permissions, capabilities, audit. Strategy doc §2.1.

### 6.2 The user's two options, mapped to the strategy doc

**Option A — vendor binds aiosandbox MCP + AgentKeys MCP directly to their own chatbot LLM caller.**

```
Vendor chatbot (built-in LLM caller)
  ├── MCP → aiosandbox http://sandbox-host:8080/mcp
  └── MCP → AgentKeys  https://agentkeys-mcp.litentry.org/mcp
```

- ✅ Simplest wiring. No Task Host to deploy or operate.
- ✅ Vendor keeps full control of the LLM caller and prompt strategy.
- ❌ **No guardrail guarantee** — the LLM is free to skip `permission.check` before a payment, or skip `audit.append` after one. Per issue #133 this is *exactly* the failure mode hooks exist to prevent.
- ❌ Vendor must implement their own retry / planning / multi-step orchestration logic (or stay single-turn).
- 📐 Strategy-doc fit: this is the "low-risk read-only" path from §3.1 (memory reads of non-sensitive namespaces). Fine for "make my chatbot sound personalized." Not fine for payment or credential authority.

**Option B — vendor channels into Hermes (or any Task Host) running inside aiosandbox; the Task Host binds both MCPs.**

```
Vendor surface
  └── (Hermes channel / WebSocket / SSE)
       └── Hermes-agent  (running inside aiosandbox)
            ├── MCP → aiosandbox  (loopback, http://localhost:8080/mcp)
            └── MCP → AgentKeys   (over network, https://agentkeys-mcp/.../mcp)
            └── Hooks (PreToolUse / PostToolUse / Stop) → AgentKeys MCP tools
```

- ✅ **IAM guarantee chain** — hooks in the Task Host call `permission.check` / `audit.append` unconditionally. The LLM can't bypass.
- ✅ Vendor inherits Hermes' orchestration (retry, planning, tool-use loop) for free.
- ✅ AgentKeys stays a pure Authority Host (strategy doc §2.4 zero-orchestration line holds).
- ❌ Higher operational complexity: vendor (or AgentKeys' hosted offering) runs an aiosandbox + Hermes deployment per active tenant.
- 📐 Strategy-doc fit: this is the production path for §3.1 high-risk scopes (payment, credential write, send-email) and the §4.3 three-act demo. Issue #133 hooks land naturally on top.

### 6.3 Decision (recorded 2026-05-28)

> **Option B is the production architecture.** Vendor surface → Task Host → both MCPs (aiosandbox loopback + AgentKeys over network). AgentKeys ships as MCP regardless of which option a vendor picks.
>
> **Within Option B, hooks are the primary IAM-guarantee mechanism. The OpenAI-compatible proxy is a lower-priority fallback** for hosts that have no hook system. See [§6.5 hooks vs proxy](#65-hooks-vs-proxy--how-iam-guarantees-get-delivered) and [§6.6 hook availability](#66-hook-availability-across-runtimes-verified-2026-05-28) for evidence and the [wiki glossary](wiki/agent-iam-guarantee-glossary.md) for the standalone reference.

Rationale (anchored in [`agent-iam-strategy.md`](agent-iam-strategy.md)):

- §2.1 Task Host vs Authority Host — Option B keeps that boundary clean; Option A blurs it.
- §2.3 — MCP is the integration surface; we ship the MCP server regardless.
- §2.4 zero-orchestration hard line — hooks are scoped to lifecycle events, not the request path; proxy is in the request path, so its mission-creep risk is higher and it lands later.
- §4.3 three-act demo — deterministic denial requires hook-enforced policy checks (see §6.4 IAM-tool-vs-guarantee distinction).

Practical rollout sequence:

| Stage | Default vendor wiring | Why |
|---|---|---|
| **Phase 1 demo** (this PR + immediate follow-up) | Option B with Hermes inside aiosandbox; AgentKeys MCP registered in Hermes' `mcp_servers` config | Demonstrates the three-act IAM demo (strategy doc §4.3) with the full guardrail story. Vendor pitch reads as "Agent IAM" not "smart memory toy" (§4.1 goal). |
| **Phase 2 vendor onboarding** | Option B is the default; vendors register AgentKeys MCP + AgentKeys hook bundle in their chosen Task Host (Claude Code, Codex, Hermes, OpenClaw, xiaozhi-server). | Strategy doc §2.5 — deploy → grow → standardize. |
| **Phase 3** ([issue #133](https://github.com/litentry/agentKeys/issues/133)) | Reference hook configs for all Tier-1 hosts (Claude Code, Codex, Hermes, OpenClaw); `agentkeys hook check` CLI helper; cap-mint pre-warming for sub-50ms p99. | The canonical track for hooks. Cross-runtime parity per strategy doc §5 Phase 3. |
| **Phase 3b** (after #133 lands) | OpenAI-compatible proxy endpoint for hooks-less hosts (xiaozhi-server, vendor mobile chatbots, plain `openai.ChatCompletion` scripts). Lower priority. | The fallback path for hosts without a hook surface — see §6.5. Strategy doc §2.4 risk applies; sequence behind hooks. |
| **Phase 4** | Standards work (MCP extensions for IAM-grade auth, OAuth-for-Agents) | Per strategy doc §5 Phase 5. |

### 6.4 IAM tool vs IAM guarantee — the distinction Option B enables

The reason Option B + hooks is the production choice (not just the recommended one) comes down to a difference between *advertising* an IAM tool and *enforcing* an IAM guarantee:

| | Defined as... | Whether the check runs is decided by... | Failure mode |
|---|---|---|---|
| **IAM tool** | A function in the LLM's tool registry (`agentkeys.permission.check(scope=…)`) | The LLM, based on its prompt + context + sampling | LLM forgets / skips / is jailbroken → unauthorized action proceeds |
| **IAM guarantee** | A non-LLM gate sitting in the execution path before the sensitive action runs | The runtime (hook system, proxy, OS capability) — deterministically | Runtime gate fails closed; action cannot proceed without an allow verdict |

**Concrete example — payment scenario:**

- *Tool-only* (≈ Option A): User says "buy hotpot." The LLM has both `permission.check` and `payment.execute` in its tool registry. The system prompt asks it to check first. A prompt-injection in the user's input convinces it to skip. **No guarantee.**
- *Guarantee* (Option B + hooks): User says "buy hotpot." The LLM emits `payment.execute(amount_rmb=600)`. The Task Host's `PreToolUse` hook fires before the call leaves the host, executes `agentkeys.permission.check(scope=payment.spend, amount=600)`, gets `denied: daily_spend_cap_exceeded`, **physically blocks the tool call**. LLM intent is irrelevant. **Guarantee.**

Anchored in strategy doc §3.1 (*"high-risk = always online permission check + fresh cap-token mint per call"*) and [issue #133](https://github.com/litentry/agentKeys/issues/133) (*"hooks move those guarantees out of LLM discretion and into the runtime"*). Standalone reference: [`docs/wiki/agent-iam-guarantee-glossary.md`](wiki/agent-iam-guarantee-glossary.md).

### 6.5 Hooks vs proxy — how IAM guarantees get delivered

Two tracks deliver guarantees, with hooks primary and proxy as the fallback:

| Dimension | Hook (primary) | Proxy (fallback) |
|---|---|---|
| **Where it sits** | Inside the Task Host runtime, between "LLM decided to call tool X" and "tool X runs" | Between the LLM client and the LLM provider (OpenAI / DashScope / Anthropic / etc.) |
| **What it sees** | Tool-call events + lifecycle events (`Stop`, `SessionEnd`) | Every prompt, every completion, every `tool_calls` array, every `tool_result` |
| **Host modification needed** | Edit host settings (`~/.claude/settings.json` / `~/.codex/hooks.json` / `~/.hermes/config.yaml` / etc.) | Change one env var: `OPENAI_BASE_URL=https://agentkeys-proxy.../v1` |
| **Host must support...** | A hook lifecycle vocabulary | OpenAI-compatible Chat Completions API (the de facto standard) |
| **Cross-runtime portability** | Per-host adapter (Hermes is Claude-Code-compatible — see §6.6 — so one script set covers Tier-1 with thin shims) | One impl works for all OpenAI-compatible clients |
| **Latency added per LLM call** | ~1–50ms with cap pre-warming | ~50–300ms (full network hop) |
| **Vendor sends prompts through AgentKeys?** | **No** | **Yes** — privacy / residency / compliance implications |
| **Strategy-doc §2.4 zero-orchestration risk** | Low — scoped to lifecycle events | Higher — in the path of every byte invites scope creep |
| **Works for hooks-less hosts** (legacy chatbots, mobile SDKs, plain `openai.ChatCompletion` scripts) | No | Yes |
| **Comparable products / competitive crowding** | Small space (host hook systems) | Crowded — Vercel AI Gateway, Helicone, LangSmith, Portkey, OpenRouter, Cloudflare AI Gateway |

**Why hooks first, proxy second:**

- Hooks stay cleanly on the §2.1 Authority Host side. Proxy edges toward Task Host territory (§2.4 risk).
- Tier-1 hosts (Claude Code, Codex, Hermes, likely OpenClaw — see §6.6) cover the strategically-important runtimes. One investment, four runtimes.
- Proxy track has §2.4 mission-creep risk *and* competitive crowding. We want this only when our authority position is established.

**Why proxy second, not skipped:** some hosts (xiaozhi-server, vendor mobile SDKs, single-turn `openai.ChatCompletion` scripts) have no hook surface — without the fallback they're unreachable. The proxy is the only path for them.

### 6.6 Hook availability across runtimes (verified 2026-05-28)

Live-probed where possible; flagged where inferred.

| Runtime | Hooks? | Events | Config | Wire protocol | Claude-Code-compat | Confidence |
|---|---|---|---|---|---|---|
| **Claude Code** | ✅ richest | ~24 events: `SessionStart/End`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse[Failure/Batch]`, `PermissionRequest/Denied`, `Stop/Failure`, `SubagentStart/Stop`, `Pre/PostCompact`, `FileChanged`, `CwdChanged`, `ConfigChange`, `InstructionsLoaded`, `Elicitation`, `Notification`, `TaskCreated/Completed`, `WorktreeCreate/Remove`, `Setup` | `~/.claude/settings.json` + `.claude/settings.json` + plugin `hooks.json` | stdin JSON `{session_id, hook_event_name, tool_name, tool_input, …}`; stdout JSON `{decision, reason, hookSpecificOutput, …}` or exit 2 to block; types `command`/`http`/`mcp_tool`/`prompt`/`agent` | (reference shape) | **Verified** |
| **Codex (OpenAI)** | ✅ | 10 events: `SessionStart`, `SubagentStart/Stop`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Pre/PostCompact`, `UserPromptSubmit`, `Stop` | `~/.codex/hooks.json` + `~/.codex/config.toml` (inline `[hooks]`) + repo-local equivalents | stdin JSON `{session_id, hook_event_name, model, …}`; stdout JSON `{continue, stopReason, systemMessage, suppressOutput}` | Field names overlap; not officially declared compatible — needs a `decision ↔ continue` shim | **Verified** |
| **Hermes** (NousResearch) | ✅ | 5+ confirmed: `pre_tool_call`, `post_tool_call`, `pre_llm_call`, `on_session_end`, `subagent_stop`. Tool-call events support `matcher:` to filter by tool. | `~/.hermes/config.yaml` `hooks:` block + first-use consent at `~/.hermes/shell-hooks-allowlist.json` | stdin JSON `{hook_event_name, tool_name, tool_input, session_id, cwd, extra}`; stdout JSON — **accepts BOTH** Claude-Code-style `{"decision": "block", "reason": "…"}` AND Hermes-canonical `{"action": "block", "message": "…"}`. `pre_llm_call` supports `{"context": "…"}` injection. | ✅ **First-class** (*"either shape accepted; normalised internally"* per `agent/shell_hooks.py`) | **Verified live** |
| **OpenClaw** | ⚠️ likely | Probably the same Hermes set — Hermes ships `hermes claw` as "OpenClaw migration tools," strongly implying shared hook architecture. Public docs show webhook ingress only, not lifecycle hooks. | Likely `~/.openclaw/config.yaml` — verify | Likely identical to Hermes — verify | Likely ✅ — verify | **Inferred from lineage** |
| **"Kimiclaw"** (hosted OpenClaw — hypothetical) | 🔧 depends on host | If hosted faithfully, same as OpenClaw; per-tenant settings API replaces local config | Tenant settings panel + API (hypothetical) | Same as OpenClaw (assumed) | Same as OpenClaw (assumed) | **Hypothetical** |
| **xiaozhi-server** (xinnan-tech) | ❌ no formal hooks | Plugin system + MCP tool registration; no lifecycle hook surface in README/docs | `mcp_server_settings.json` registers MCP servers; plugin hot-loading | None for hooks (only MCP tool registration) | N/A | **Inferred** — verify source for production |

**Reading the table** — Tier-1 (Claude Code, Codex, Hermes, OpenClaw) all have hooks with converging shapes; Hermes is explicitly Claude-Code-compatible. One reference script bundle ports across Tier-1 with thin shims. Tier-2 (xiaozhi-server, vendor mobile chatbots, plain SDK scripts) has no lifecycle gate and needs the proxy fallback.

### 6.7 The aiosandbox-specific recommendation

The user's question — "I see aiosandbox as a whole could be used as a mcp server for local LLM" — is technically correct: aiosandbox exposes `POST /mcp` and any MCP client can call its browser/file/terminal tools. **But the right mental model is:**

> aiosandbox is a *sandbox primitive*, not a Task Host. Its MCP surface gives the agent (whichever agent — Hermes, OpenClaw, vendor's own) safe access to a browser, a filesystem, and a shell. It does not plan, retry, or own lifecycle. **Binding aiosandbox MCP directly to a vendor chatbot is fine for "let the LLM browse the web in a sandbox," but it does NOT replace a Task Host.**

So in practice:

1. **Always** register AgentKeys MCP wherever the LLM-calling layer lives. That's the Authority binding.
2. **Always** register aiosandbox MCP next to a Task Host (Hermes or equivalent) so the Task Host can use the sandbox's primitives. The Task Host then exposes a higher-level channel back to the vendor surface.
3. **Avoid** the temptation to skip the Task Host and bind aiosandbox + AgentKeys directly to a bare LLM caller for anything beyond read-only memory enrichment — you lose the issue-#133 guardrail story.

### 6.8 What this PR ships vs. what the recommendation needs

This PR ships the demo with AgentKeys exposed as **plain HTTP** (daemon's `/v1/memory/{actor}/profile.md` + hermes-runtime's `/v1/chat`). That's the right scope for the original plan §C3/C4 and matches the user's "do the Hermes and sandbox side work first" instruction.

To execute the recommendation above we need (follow-up issues, not this PR):

| Follow-up | What | Where it lives |
|---|---|---|
| `agentkeys-mcp-server` exposes the 7 Phase-1 tools | Extend [`crates/agentkeys-mcp-server/src/tools/`](../crates/agentkeys-mcp-server/src/tools/) (already has `memory.rs`, `cap.rs`, `audit.rs`, `permission.rs`, `identity.rs`) — finalize per strategy doc §4.2 | Existing crate, add tool definitions + wire the streamable-HTTP transport |
| Hermes mcp_servers config snippet | `mcp_servers.json` fragment that registers AgentKeys MCP into a Hermes deployment inside aiosandbox | New file `docker/aiosandbox-demo/hermes-mcp-servers.json` + setup script step |
| Vendor-direct MCP config snippet | `mcp_servers.json` fragment vendors drop into their xiaozhi-server / chatbot / Claude Code settings | New `docs/wiki/agentkeys-mcp-vendor-config.md` |
| Issue #133 reference hook configs | PreToolUse / PostToolUse / Stop wired to AgentKeys MCP tools | Tracked in #133 itself |

That sequencing aligns with the strategy doc's Phase 1 → Phase 2 → Phase 3 split and keeps this PR scoped to the original Hermes/sandbox track.

## 7. Local quickstart — sandbox-side only (no device, no AWS)

```bash
# Terminal 1 — start the daemon's demo-memory endpoint (bundled fixture)
./target/release/agentkeys-daemon --demo-memory --demo-memory-port 8089

# Terminal 2 — start the hermes runtime, pointed at the daemon
AGENTKEYS_LLM_PROVIDER=stub \
AGENTKEYS_LLM_MODEL=stub \
AGENTKEYS_DAEMON_URL=http://localhost:8089 \
AGENTKEYS_HERMES_PORT=8090 \
./target/release/agentkeys-hermes-runtime
```

In a third terminal:

```bash
curl -sS localhost:8089/v1/memory/O_demo_001/profile.md | head -20
# → ---
#    actor_omni: O_demo_001
#    user_display_name: Kevin Cheng
#    ...

curl -sS -X POST localhost:8090/v1/chat \
  -H 'content-type: application/json' \
  -d '{"query":"what should I have for lunch?"}' | jq .
# → {
#     "response": "[stub-llm] (system_prompt_chars=NNN) echo: what should I have for lunch?",
#     "memory_loaded": true,
#     "tokens_used": N
#   }
```

`memory_loaded: true` proves the runtime fetched the daemon's memory blob at
startup. The stub LLM echoes the user input and reports the system prompt
size — switch `AGENTKEYS_LLM_PROVIDER` to `dashscope` (or `openrouter` /
`openai` / `claude`) with `AGENTKEYS_LLM_API_KEY=...` to get real responses.

## 8. Live demo (vendor pitch script)

Script for a 4-minute vendor demo:

1. **Set the stage** — "This is a $5 ESP32 hardware client. It knows one URL and
   one token. It's never seen me before." `(firmware: deferred — substitute
   curl from laptop)`
2. **First message** — send `"hi, what should I have for lunch?"` from the
   client. Agent responds referencing Kevin's spicy Sichuan preference, the
   Chengdu trip context. *Pause for vendor reaction.*
3. **Reveal the mechanism** — show
   `s3://agentkeys-demo-memory/bots/O_demo_001/memory/profile.md`. "That's the
   user's portable profile. The agent loaded it at boot."
4. **Swap memory live** — edit the S3 file (or `tests/fixtures/demo-profile.md`
   for the bundled path), change `Loves spicy Sichuan` to `Loves Cantonese
   dim sum`, run:
   ```bash
   aws s3 cp tests/fixtures/demo-profile.md \
     s3://agentkeys-demo-memory/bots/O_demo_001/memory/profile.md \
     --profile agentkeys-admin
   docker exec aiosandbox-demo supervisorctl restart hermes-runtime
   ```
   Repeat the lunch question; agent now suggests dim sum. *Vendor sees the
   portability mechanism in 10 seconds.*
5. **Pitch the close** — "Your vendor onboarding is 1 day: point your device
   at one URL with one token. Memory portability, audit, revocation are
   AgentKeys' problem, not yours."

## 9. Troubleshooting

Layer-by-layer failure signatures:

| Symptom | Most-likely cause | Fix |
|---|---|---|
| `docker run` exits immediately with no log, or banner never appears | Default Docker seccomp profile is blocking sandbox syscalls | Re-run with `--security-opt seccomp=unconfined` (see §3) |
| `curl /v1/chat` → connection refused | hermes-runtime not running | `docker logs aiosandbox-demo \| grep hermes` |
| `curl /v1/chat` → `502 llm_error` | LLM API key wrong / quota out | check `AGENTKEYS_LLM_API_KEY`; switch to `stub` provider to isolate |
| `memory_loaded: false` in response | daemon unreachable at startup OR fixture missing in S3 | `curl localhost:8089/healthz` from inside container; `aws s3 ls s3://agentkeys-demo-memory/bots/O_demo_001/memory/` |
| Agent ignores profile facts | LLM was called but memory wasn't injected — daemon returned empty body | check daemon logs for S3 GetObject error; verify `AGENTKEYS_DEMO_MEMORY_BUCKET` matches actual bucket name |
| Memory swap doesn't take effect | hermes-runtime fetches memory **at startup** only | restart the hermes program: `supervisorctl restart hermes-runtime` (a periodic-refresh path is a follow-up) |
| Device side `(firmware: deferred)` | ESP32 firmware is not part of this PR | substitute `curl` from a laptop |

## 10. Hot-swap the memory blob

The runtime caches the memory blob in process memory and only refreshes on
start. Steps to apply a new profile during a live demo:

```bash
# 1. Edit + upload the new content.
$EDITOR tests/fixtures/demo-profile.md
aws --profile agentkeys-admin s3 cp \
  tests/fixtures/demo-profile.md \
  s3://agentkeys-demo-memory/bots/O_demo_001/memory/profile.md

# 2. Force the runtime to re-fetch.
docker exec aiosandbox-demo supervisorctl restart hermes-runtime

# 3. Send a new chat — response now reflects the swap.
curl -sS -X POST $DEMO_HOST/v1/chat \
  -H "authorization: Bearer $ACTOR_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"query":"what should I have for lunch?"}' | jq .
```

## 11. ESP32 firmware (deferred)

This runbook intentionally has no ESP32 sections — issue #103 explicitly
defers firmware to a follow-up. When the firmware track ships, append:

- Board, USB serial bring-up, flash command
- WiFi captive-portal config for `SANDBOX_URL` + `ACTOR_TOKEN`
- Button → query → response observability via USB CDC
- Voice-mode follow-up
