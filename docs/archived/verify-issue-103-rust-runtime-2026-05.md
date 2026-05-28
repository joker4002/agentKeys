> **Archived 2026-05-28.** Verified the obsolete Rust-runtime path (`agentkeys-hermes-runtime` crate + daemon `--demo-memory` flag). Replaced by per-step verification in the new wire-flow runbook (TBD; tracked in [`../spec/plans/phase-1-fresh-user-wire-onboarding.md`](../spec/plans/phase-1-fresh-user-wire-onboarding.md)). **Do not run these commands — they reference binaries that are slated for removal.**

# Verify issue [#103](https://github.com/litentry/agentKeys/issues/103) — Hermes + sandbox side

Copy-pasteable verification runbook. No Docker, no AWS, no ESP32 required. Just
`cargo`, `curl`, `jq`, and two terminals.

Each step ends with the expected output snippet so you can confirm the result
without reading prose.

## 0. Prereqs

```bash
cargo --version   # 1.83+ (anything stable should work)
jq --version
curl --version | head -1
cd $(git rev-parse --show-toplevel)  # repo root
```

## 1. Unit + integration tests

```bash
cargo test -p agentkeys-daemon -p agentkeys-hermes-runtime 2>&1 | grep "test result"
```

**Expected** (counts should match — 4 result lines, all `ok`):

```
test result: ok. 12 passed; 0 failed; 0 ignored; ...
test result: ok. 15 passed; 0 failed; 0 ignored; ...
test result: ok. 15 passed; 0 failed; 0 ignored; ...
test result: ok. 13 passed; 0 failed; 0 ignored; ...
```

The 13-passed line is the new hermes-runtime suite; the 12-passed line includes
the 4 new `demo_memory::tests::*` cases.

## 2. Build release binaries

```bash
cargo build --release -p agentkeys-daemon -p agentkeys-hermes-runtime
ls -la target/release/agentkeys-daemon target/release/agentkeys-hermes-runtime
```

**Expected**: both binaries present, executable, ~6MB + ~21MB.

## 3. Daemon CLI surface

```bash
./target/release/agentkeys-daemon --help 2>&1 | grep -A1 "demo-memory"
```

**Expected**: seven `--demo-memory*` flags listed (`--demo-memory`,
`--demo-memory-bind`, `--demo-memory-port`, `--demo-memory-actor`,
`--demo-memory-fixture`, `--demo-memory-bucket`, `--demo-memory-region`).

## 4. End-to-end smoke test (stub LLM, bundled fixture, no network deps)

Pick ports that won't collide with any local service. The example uses
28089/28090.

**Terminal A — daemon (memory endpoint):**

```bash
./target/release/agentkeys-daemon --demo-memory --demo-memory-port 28089
```

You should see:

```
INFO agentkeys_daemon::demo_memory: agentkeys-daemon demo-memory server listening bind=0.0.0.0:28089 actor=O_demo_001 source="bundled"
```

**Terminal B — hermes-runtime (stub LLM, pointed at the daemon):**

```bash
AGENTKEYS_LLM_PROVIDER=stub \
AGENTKEYS_LLM_MODEL=stub \
AGENTKEYS_DAEMON_URL=http://localhost:28089 \
AGENTKEYS_HERMES_PORT=28090 \
./target/release/agentkeys-hermes-runtime
```

You should see:

```
INFO agentkeys_hermes_runtime: loaded memory profile from daemon actor=O_demo_001
INFO agentkeys_hermes_runtime: agentkeys-hermes-runtime listening bind=0.0.0.0:28090 actor=O_demo_001 provider=Stub daemon_url=http://localhost:28089
```

The `loaded memory profile from daemon` line proves step 5 of the plan: hermes
fetched the fixture from the daemon at startup.

**Terminal C — verify:**

```bash
# 4a. daemon healthz
curl -sS localhost:28089/healthz | jq .
```
Expected: `{"status":"ok","actor_omni":"O_demo_001","source":"bundled"}`.

```bash
# 4b. daemon memory endpoint returns the fixture
curl -sS localhost:28089/v1/memory/O_demo_001/profile.md | head -5
```
Expected: YAML frontmatter (`actor_omni: O_demo_001`, `user_display_name: Kevin Cheng`, ...).

```bash
# 4c. daemon rejects unknown actor
curl -sS -o /dev/null -w '%{http_code}\n' localhost:28089/v1/memory/O_other/profile.md
```
Expected: `404`.

```bash
# 4d. hermes healthz — memory_loaded must be true
curl -sS localhost:28090/healthz | jq .
```
Expected: `{"status":"ok","memory_loaded":true,"actor_omni":"O_demo_001"}`.

```bash
# 4e. /v1/chat — the stub LLM echoes the user query and reports the
#     system-prompt size, which proves the fixture got injected.
curl -sS -X POST localhost:28090/v1/chat \
  -H 'content-type: application/json' \
  -d '{"query":"what should I have for lunch?"}' | jq .
```
Expected (system_prompt_chars must be ~1000 — that's the fixture size — and
`memory_loaded` must be `true`):
```json
{
  "response": "[stub-llm] (system_prompt_chars=1013) echo: what should I have for lunch?",
  "memory_loaded": true,
  "tokens_used": 9
}
```

```bash
# 4f. empty query → 400
curl -sS -X POST localhost:28090/v1/chat \
  -H 'content-type: application/json' \
  -d '{"query":""}' | jq .
```
Expected: `{"error":"query field is empty","reason":"empty_query"}` with HTTP 400.

## 5. Bearer-token auth path

Restart the hermes-runtime with a token set, then verify:

```bash
# Terminal B (Ctrl-C the previous hermes, restart with a token):
AGENTKEYS_LLM_PROVIDER=stub \
AGENTKEYS_LLM_MODEL=stub \
AGENTKEYS_DAEMON_URL=http://localhost:28089 \
AGENTKEYS_HERMES_PORT=28090 \
AGENTKEYS_DEMO_ACTOR_TOKEN=secret_token_xyz \
./target/release/agentkeys-hermes-runtime
```

```bash
# 5a. Missing bearer → 401
curl -sS -o /dev/null -w '%{http_code}\n' -X POST localhost:28090/v1/chat \
  -H 'content-type: application/json' -d '{"query":"hi"}'
```
Expected: `401`.

```bash
# 5b. Wrong bearer → 401
curl -sS -o /dev/null -w '%{http_code}\n' -X POST localhost:28090/v1/chat \
  -H 'authorization: Bearer wrong' \
  -H 'content-type: application/json' -d '{"query":"hi"}'
```
Expected: `401`.

```bash
# 5c. Correct bearer → 200 with stub echo
curl -sS -X POST localhost:28090/v1/chat \
  -H 'authorization: Bearer secret_token_xyz' \
  -H 'content-type: application/json' \
  -d '{"query":"hello"}' | jq '.response, .memory_loaded'
```
Expected: stub echo containing `hello` and `true`.

## 6. Local-file source (alternative to bundled fixture)

Daemon supports loading the profile from a path on disk, useful for live
editing during a demo:

```bash
# Terminal A — Ctrl-C the previous daemon, restart with a fixture path:
echo "# Custom profile

User likes Cantonese dim sum.
Allergic to shellfish." > /tmp/profile-test.md

./target/release/agentkeys-daemon --demo-memory \
  --demo-memory-port 28089 \
  --demo-memory-fixture /tmp/profile-test.md
```

```bash
# Verify daemon's healthz reports local_file source
curl -sS localhost:28089/healthz | jq .source
# → "local_file"

# Verify the custom content is served
curl -sS localhost:28089/v1/memory/O_demo_001/profile.md
# → "# Custom profile\n\nUser likes Cantonese dim sum.\nAllergic to shellfish."
```

Restart Terminal B's hermes-runtime, then re-run step 4e — the
`system_prompt_chars` should be a small number reflecting the short custom
content, not 1013.

## 7. Setup script syntax check

```bash
bash -n scripts/setup-demo-aiosandbox.sh && echo "ok"
bash scripts/setup-demo-aiosandbox.sh --help | head -25
```
Expected: `ok`, then the usage banner.

## 8. Real LLM (optional — costs ~$0.0001 per call)

If you have a DashScope or OpenRouter API key, replace step 4's Terminal B
command with:

```bash
AGENTKEYS_LLM_PROVIDER=dashscope \
AGENTKEYS_LLM_MODEL=qwen-plus \
AGENTKEYS_LLM_API_KEY=sk-YOUR-KEY \
AGENTKEYS_DAEMON_URL=http://localhost:28089 \
AGENTKEYS_HERMES_PORT=28090 \
./target/release/agentkeys-hermes-runtime
```

Then re-run step 4e. The response should reference Kevin, Shanghai, the
Chengdu trip, the spicy Sichuan preference — proving the memory blob got
into the LLM context, not just the system prompt buffer.

## 9. Clean up

```bash
# Kill the daemon + hermes (Ctrl-C in their terminals)
# Or:
pkill -f 'agentkeys-daemon --demo-memory' || true
pkill -f 'agentkeys-hermes-runtime' || true
rm -f /tmp/profile-test.md
```

## What this verifies (mapped to plan steps)

| Step | Verified by |
|---|---|
| 1 — Mock memory MD fixture | step 4b (daemon serves the fixture verbatim) |
| 2 — hermes-runtime crate scaffold | step 1 (13-passed test line); step 3 (`--help`) |
| 3 — LLM hookup | step 8 (real DashScope call); step 4e (stub echo) |
| 4 — daemon `/v1/memory/{actor}/profile.md` | step 4b, 4c |
| 5 — hermes fetches at startup | Terminal B `loaded memory profile from daemon` log line; step 4e `memory_loaded: true` |
| 6/7 — S3-backed read (code path) | unit test `demo_memory::tests::*` in step 1 |
| 8 — Dockerfile + supervisord | not exercised here (needs Docker); inspect `docker/aiosandbox-demo/` |
| 9 — setup script | step 7 (syntax-only) |
| 12 — runbook | `docs/demo-aiosandbox-runbook.md` |

ESP32 firmware (plan steps 10–11) is intentionally NOT in this verification —
that work is deferred per the task scope.
