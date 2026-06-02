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
# the Chengdu memory. Each run DEPAIRS the prior device (revoke) + re-pairs a fresh
# K10 (register), so expect ONE Touch ID + ~2 on-chain txs per run.
bash harness/phase1-wire-demo.sh --real --webauthn

# VERIFY — deterministic, no LLM. Run IN THE SANDBOX after setup (the harness
# also runs this at step 4.2). A "context" block = the permissioned memory
# reached the LLM request — the actual guarantee. Don't judge by the chat reply.
docker exec -it <sandbox-container> bash -lc "hermes hooks test pre_llm_call"
#   → stdout: {"context":"## Memory: travel\nChengdu trip — Apr 12 to 16, hotpot at Yulin."}   ✅
#   → stdout: {}   ❌  (MCP down / scope not granted / session bad)
```

**A mode is REQUIRED** — `--light` or `--real`. The harness refuses to guess
(running `--real` by accident flips the sandbox MCP to the live broker and loses
the in-memory demo fixture). It prints a loud `MODE:` banner so the active mode
is never ambiguous. Every step prints `ok proceeding` / `skip <reason>` /
`fail <reason>`; the harness is idempotent — re-running is safe.

## How to run — the `--real --webauthn` walkthrough

One command runs the whole "install an app → approve its permissions → use it"
story. Each run does a **genuine fresh pairing** — it **depairs** the prior device
(on-chain revoke) and mints a **new K10 in the sandbox** for the same agent, so
`registerAgentDevice` actually runs (not the already-registered skip). Expect
**one Touch ID + ~2 on-chain txs (revoke + register) per run**.

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
   - **Phase P — install (pair)** 📲 (full §10.2 HDKD bootstrap, issue #144 — **method A, agent-initiated**: the device shows a code, the owner claims it, the Matter/HomeKit model)
     - `P.depair` — **genuine fresh pairing**: if a prior run left this agent's device paired, the master **revokes** it on-chain (depair; agent-tier, no biometric, idempotent) and the sandbox K10 is **wiped**. Required because the contract won't re-register a revoked hash (`registeredAt` sticks), so a real re-pair needs a brand-new key. Skipped under `--reuse-agent`.
     - `P.0` the **agent daemon** (`agentkeys-daemon --request-pairing`) generates a **fresh K10 device key in the sandbox** (P.depair wiped the old one), proves possession, opens an **unbound** pairing request, and **displays a one-time pairing code** (the key never touches the master).
     - `P.1` the **master claims** that code (`agentkeys agent claim --pairing-code …`), binding the agent under the HDKD child omni `O_agent = SHA256(.. ‖ O_master ‖ "//label")` and declaring its scope (real broker `/v1/agent/pairing/claim`).
     - `P.1b` the **agent daemon** (`agentkeys-daemon --retrieve-pairing`) polls + **retrieves `J1_agent`** in the sandbox once the master claims (re-proving K10 possession).
     - `P.1c` the master pulls the rendezvous (`agentkeys agent pending`) and sees this agent awaiting approval.
     - `P.2` the master **binds** that device **on-chain** — a **real `registerAgentDevice`** for the fresh key (no biometric), *not* the old already-registered skip — and **acks** the broker so it clears from `pending`.
     - `P.3` **🔐 Touch ID** — the master **grants** the agent's `[memory]` permission (`setScopeWithWebauthn`). Conceptually `P.2`+`P.3` are **one approval** (install + permissions, iOS/Android-style); kept as two steps for deterministic test automation.
   - **1.4–1.5** — MCP server (per-actor STS relay) starts; step 1.5 (re)seeds the "Chengdu trip" fixture into the agent's memory namespace (keyed by the **stable** omni — only the device key is fresh — so 1.5 overwrites each run).
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
| **The Chengdu surprise** | ✅ works out of the box | ✅ **Phase P pairs + approves the scope (Touch ID), then 1.5 seeds** the agent's memory — run **`--real --webauthn`**. Step 1.5 (re)seeds the fixture each run — memory is keyed by the agent's **stable** omni (only the device key is fresh), so 1.5 overwrites and it's always present. Needs a live master session + K11 enrolled in webauthn mode |
| **Broker / chain** | none | real broker (`signer.litentry.org`) + Heima **mainnet** |
| **Account** | a fixed demo actor/operator | your master (operator) + the **same agent omni** (stable HDKD of the label) re-paired with a **fresh device key minted in the sandbox each run** (`--reuse-agent` reuses one master-side agent) |
| **Cap-mint** | stubbed — always succeeds | real cap-mint (needs a valid master session) |
| **Vendor token** | `demo-tok` | `harness-tok` |
| **Touch ID** | never | at **Phase P (P.3)** EACH run when you pass `--webauthn` — the master *approves* the fresh agent's `[memory]` scope; never otherwise |
| **Needs network to** | sandbox + Docker + (first build) a rust image | + reachable broker / workers / Heima RPC |
| **Proves** | the wire + hook + memory-injection **plumbing** works | the same, against **real IAM infra** (real signing + isolation) |
| **Cost / risk** | free, can't break anything | real gas/cost, mutates real account state |

## Setup entry points — first-time bring-up + re-runs

`--light` needs **none** of this (self-contained — skip to *How to run*). For **`--real`**, the live infra is owned by three idempotent scripts. **Run each ON the machine shown** — this is the part that bites: `setup-broker-host.sh` runs *on the broker host* (SSH in first), the other two from your laptop.

### Starting from scratch (nothing set up yet) — run ONCE, in order

| # | Run it on… | Command | Brings up |
|---|---|---|---|
| 1 | **laptop** (`agentkeys-admin` AWS profile) | `AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh` | Cloud/IAM: SES, S3, DNS, roles, OIDC, EC2 + EIP |
| 2 | **the broker host** — SSH in first: `bash scripts/ssh-broker.sh` | `sudo bash scripts/setup-broker-host.sh --ref <branch>` | broker + signer + 4 workers (binaries, systemd, nginx/TLS) |
| 3 | **laptop** | `bash scripts/setup-heima.sh` | chain: contracts + per-actor binding ceremonies |
| 4 | **laptop** | `bash harness/phase1-wire-demo.sh --real --webauthn` | the demo itself |

Notes:
- **Step 1 prints these exact next-steps** when it finishes — it's the canonical source for the broker-host command (issuer URL + account ID filled in).
- **Step 2 — which branch:** pass the branch you're deploying. Until [#149](https://github.com/litentry/agentKeys/pull/149) merges, that's **`--ref claude/impl-144-hdkd-bootstrap`**; after it merges, `--ref main`. `--ref` does the `git fetch` + checkout on the broker for you, so it builds the code you *mean* — not whatever happened to be checked out (this is why `git pull` on `main` didn't change anything: the work is on the feature branch). `--issuer-url` / `--account-id` auto-derive from the committed `scripts/operator-workstation.env`, so usually `--ref <branch>` is all you pass.
- **Don't `git pull` by hand on the broker** — `--ref` does the fetch/checkout/pull. A `sudo bash …` run executes the script's git+cargo as root, which would leave repo files **root-owned** (a later manual `git pull` as `agentkey` then dies with `error: unable to unlink old '…': Permission denied`) — but the script now **self-heals**: when invoked via sudo it chowns the checkout back to the invoking user at the end (§8c). For an already-stuck tree, a one-time `sudo chown -R agentkey:agentkey ~/agentKeys` clears it. The broker uses plain **git**, not jj — jj is only for the laptop→origin push.
- The broker MUST run the **#144 code** (the §10.2 `/v1/agent/*` routes) or Phase P fails with HTTP 404 — `--ref` guarantees that. The script self-checks (a no-bearer `POST /v1/agent/pairing/claim` must return 401, not 404).

### Re-runs — only run the one whose domain changed

| Script (where it runs) | Owns | Re-run when |
|---|---|---|
| [`scripts/setup-cloud.sh`](../scripts/setup-cloud.sh) — **laptop** | Cloud / IAM (SES, S3, DNS, roles, OIDC) | a permission / role / DNS change |
| [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh) — **broker host** | broker + signer + 4 workers | broker/worker code changed |
| [`scripts/setup-heima.sh`](../scripts/setup-heima.sh) — **laptop** | contracts + per-actor ceremonies | a chain / contract change |

All three are **idempotent + unattended by default** — re-running converges and exits 0 without re-applying; **no flags to remember** (workers always build but skip when up-to-date; the broker self-heals a bad feature build itself). `--yes` / `--non-interactive` are still *accepted* (CI passes them) but no longer needed.

**The wire demo does NOT need a broker-hosted MCP server** — its MCP server runs **in the sandbox** (cross-built there once, then cached; see Prerequisites). The broker-hosted MCP endpoint is the *Hosted-LLM* path (xiaozhi / vendor-cloud), **deferred to [#152](https://github.com/litentry/agentKeys/issues/152)**; `setup-cloud.sh` step 15 is now a no-op pointing there.

## Prerequisites

**Always:** Rust toolchain (`rustup default stable`) + `jq` (`brew install jq`).

**`--light` / real (sandbox path):**
- **Docker** + the sandbox running:
  ```bash
  docker run --security-opt seccomp=unconfined -d -p 8080:8080 ghcr.io/agent-infra/sandbox:latest
  ```
  The `--security-opt seccomp=unconfined` flag is required (Docker's default seccomp blocks syscalls the sandbox needs; without it the container exits silently). Re-run after every Docker Desktop upgrade.
- A **reachable rust image** for the aarch64-linux cross-build (the sandbox is aarch64 Linux; the harness cross-builds the agent binary in an `arm64` rust container). The **first** build is slow; after that re-runs are **incremental** — the harness persists cargo's registry, git db, the rustup toolchain, **and the `target/` dir** in named docker volumes, and bakes the OpenSSL build deps into a cached `agentkeys-sandbox-builder` image, recompiling only when a tracked source file changed (and restarting the sandbox MCP server when the binary changed). The `target/` dir lives in a **named volume** (`agentkeys-sandbox-target`), *not* a host bind-mount — on macOS a bind-mounted target routes cargo's thousands of small incremental files through the Docker VM's virtiofs layer and dominates re-run time; only the three final binaries are copied out to `target/sandbox-linux/release/`. If Docker Hub is unreachable, pre-pull or point at a mirror: `RUST_BUILD_IMAGE=<local-or-mirror-rust-image>`.
- **Hermes** in the sandbox — the harness installs it (guarded `curl|bash`) if absent; needs GitHub reachable.

**Real mode only:**
- **The master-side `agentkeys` CLI must have the `agent` subcommand** (Phase P §10.2 pairing calls `agentkeys agent claim/pending`). Step **0.2b builds it for you** — `cargo build --release -p agentkeys-cli` → `target/release/agentkeys`, which the harness prefers (release → debug → PATH). If you opt out (`AGENTKEYS_SKIP_CLI_BUILD=1`) or run `agentkeys agent …` by hand, install a current binary first: `cargo build --release -p agentkeys-cli && cp target/release/agentkeys ~/.local/bin/agentkeys`. A **stale** CLI fails `P.1 claim` with `unrecognized subcommand 'agent'` and cascades into the MCP/wire/Acts steps.
- **The broker must be running the issue-#144 (method A) code** — the §10.2 endpoints (`/v1/agent/pairing/request`, `/v1/agent/pairing/claim`, `/v1/agent/pairing/poll`, `/v1/agent/pending-bindings`). If your broker predates this PR, run `bash scripts/setup-broker-host.sh --ref main` (or `--test --yes` for the test host) FIRST, or Phase P `P.0 request` fails with HTTP **404**. The deploy self-checks this — a no-bearer `POST /v1/agent/pairing/claim` must return **401** (route live), not 404 (stale binary).
- The `setup-heima.sh` account already created (master device registered + contracts deployed; the harness verifies, never rebuilds). `OPERATOR_OMNI` is derived from your master key (`OPERATOR_KEY_FILE`); the **agent** identity is generated fresh in the sandbox by Phase P (no pre-existing agent file needed in the default fresh-pairing mode).
- An **operator session JWT** for cap-mint. The harness now mints this **automatically and non-interactively**: step `0.7` decodes the on-disk session, and if it's missing, expired, **or for the wrong operator** (its `agentkeys.omni_account` ≠ the agent's `operator_omni`), it SIWE-signs a fresh one with `OPERATOR_KEY_FILE` (default `~/.agentkeys/heima-deployer.key` — the master key whose broker omni == `operator_omni`) via the broker's `wallet_sig` plugin. Requires `cast` (Foundry) on PATH. **Note:** the old `alice` email session is a *different* omni and is no longer used for cap-mint — set `OPERATOR_KEY_FILE` to the master key for your operator if the default isn't it. (Pass `AGENTKEYS_SESSION_BEARER` to override entirely.)
- **For real memory (S3) to work:** **Phase P** generates the agent's device key **in the sandbox**, shows a pairing code the master claims, then retrieves the session there (`agentkeys-daemon --request-pairing` → master `agent claim` → `agentkeys-daemon --retrieve-pairing` → `J1_agent`); the MCP server uses that session for the per-actor STS relay (`mint-oidc-jwt` → `AssumeRoleWithWebIdentity` → `X-Aws-*` headers to the worker), so the agent key never touches the master. Needs the per-data-class role ARNs (`MEMORY_ROLE_ARN`/`VAULT_ROLE_ARN`, from `operator-workstation.env`). Without the relay the worker falls back to its instance profile (no S3) and memory ops 502. (`--reuse-agent` instead mints the session on the master from `agent_private_key` in the agent file — legacy.)
- `export OPENROUTER_API_KEY=...` in `~/.zshenv` — the harness uses it as the LLM-key fallback (no prompt).
- **For the Phase P scope grant (P.3):** the master's primary K11 enrolled in **webauthn** mode — `agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x<operator>`. Without it, `heima-scope-set.sh --webauthn` can't run and the freshly-paired agent never gets the memory scope (memory ops will be scope-rejected). Override the granted service list with `SEED_SCOPE_SERVICES` (it **sets** the full list, so include every service the agent needs).

## The manual gates (the "test through" essence)

- **LLM key** — auto from `OPENROUTER_API_KEY` (or `LLM_API_KEY`); only prompts if absent. Phase 4.0 writes it to the sandbox `~/.hermes/.env` and sets `provider: openrouter` + `model.default` (default `deepseek/deepseek-v4-flash`; override `LLM_MODEL`). A non-fatal `4.1 model smoke` confirms the model is live before the surprise.
- **Install (pair)** — `--real` only: **Phase P** — `P.depair` revokes any prior device + wipes the sandbox K10 so the re-pair is genuine, the agent daemon (`agentkeys-daemon --request-pairing`) generates a **fresh** device key **in the sandbox** + shows a pairing code (`P.0`), the master **claims** it (`P.1`), the agent daemon (`agentkeys-daemon --retrieve-pairing`) retrieves `J1_agent` (`P.1b`), the master does a real `registerAgentDevice` (`P.2`), and — with `--webauthn` — the master **approves** the agent's memory scope via Touch ID (`P.3`). Every run depairs + re-pairs the same agent with a fresh device key (~2 on-chain txs). `--reuse-agent` skips all of Phase P.
- **Real Touch ID** — in real mode with `--webauthn`: **Phase P (P.3)** grants the freshly-paired agent's memory scope via `heima-scope-set.sh --webauthn`. The banner prints `webauthn=<flag>` so you know upfront whether a Touch ID ceremony will run. It's a hardware prompt — `--yes` does NOT bypass it (it only auto-confirms the software "proceed?" gates). Without `--webauthn`, `P.3` is skipped (the agent won't be able to read memory) — re-run with `--real --webauthn`.
- **Seed the real memory worker** (`--real` only) — after pairing, step **1.5** (re)writes the Chengdu fixture into the agent's memory namespace (keyed by the **stable** omni; 1.5 overwrites each run). Override `SEED_MEMORY_CONTENT` / `SEED_SCOPE_SERVICES` (the latter is the service set Phase P grants — it **sets** the full list).
- **The Hermes surprise** — open Hermes in the sandbox, send "where am I going this weekend?", and judge the memory-aware reply (`[y/N]`).

Pass `--yes` to auto-confirm the non-secret prompts.

## What you'll see (the three acts)

| Act | Hook | Expected |
|---|---|---|
| **1 — Permissioned Memory** | `pre_llm_call` → `memory-inject` | `{"context":"## Memory: travel\nChengdu trip — Apr 12 to 16, hotpot at Yulin."}` — the device reads only the `travel` namespace it's allowed to. |
| **2 — Deterministic Denial** | `pre_tool_call` → `check` | over-cap (600 > 500) → `{"decision":"block","reason":"daily_spend_cap_exceeded: cap=500, requested=600, period=daily"}`; under-cap (200) → `{}`. No LLM in the decision; **fails CLOSED** if the MCP server is unreachable. |
| **Auto-audit** | `post_tool_call` → `audit` | `{}` — a row lands in the off-chain feed; never blocks the agent loop. |

(Act 3 — Online Revocation — is out of scope for this harness; tested elsewhere.)

## ERC-4337 passkey-only master — standalone mechanism smoke (#164 E8)

**Not a wire-demo phase.** The 4337 account is the *master*, so it belongs in the
**master-onboarding ceremony** (arch.md §9 — K11 generated at stage 2, the account
registered at stage 4), tracked as **#164 E7** and landing with the registry
**cutover**. Until that ships, this is a **standalone mechanism smoke**: it proves
the on-chain path works (EntryPoint v0.7 + on-chain P-256 verify + a WebAuthn-signed
UserOp on Heima mainnet) using a **throwaway software passkey** — it is **not** the
real ceremony (the real master K11 lives in the platform authenticator, so a real
UserOp needs a Touch ID assert + the cutover).

```bash
# Run the mechanism smoke directly (pure chain — no sandbox/Hermes). ~0.22 HEI:
bash harness/erc4337-master-e8.sh
```

**Two modes (auto-selected):**
- **fresh** (default locally) — a NEW account + ephemeral passkey + fresh deposit each run (**~0.22 HEI/run**, append-only). HEI cost doesn't matter for local testing.
- **reuse** (default when `$CI` is set; or force with `ERC4337_E8_MODE=reuse`) — **one persistent account** (fixed passkey at `ERC4337_E8_KEY_FILE` + fixed salt → deterministic address), created once and funded only when its deposit drops below ~0.05 HEI, so CI doesn't mint a new account each run. **CI must persist the key file** (Actions cache, or a secret written to `ERC4337_E8_KEY_FILE`); otherwise each run keygens a new key → a new account.

What it does: keygen a P-256 passkey → `P256AccountFactory.createAccount` (CREATE2)
→ fund the account's EntryPoint deposit (≥ the ~0.1 HEI ExistentialDeposit, so
`missingAccountFunds == 0`) → build a UserOp whose callData is a master mutation
(`addSigner`) → **WebAuthn-sign the `userOpHash`** → pre-check against the live
`K11Verifier` (zero gas) → `EntryPoint.handleOps` → assert the account's
active-signer count went up by exactly 1 (fresh `1→2`; reuse `N→N+1`). No secp256k1
key signs anything. `ok …` / `fail …` per step.

**Prereqs:** `cast` (Foundry) on PATH; the deployer key (`~/.agentkeys/heima-deployer.key`
— funds the deposit + gas); Python 3 (the script auto-provisions a `cryptography`
venv at `~/.agentkeys/erc4337-venv`). The live EntryPoint + factory addresses are in
[`docs/contracts.md`](contracts.md). **Append-only:** each run mints a fresh account
(it is NOT idempotent in the resource sense). The bundler is not required — the demo
calls `EntryPoint.handleOps` directly. Full design + cutover status:
[`docs/plan/chain/erc4337-master-account.md`](plan/chain/erc4337-master-account.md).

> Note: the **live factory** currently embeds the E2-era account (deployed before the
> E5 recovery work), so on-chain accounts have `addSigner` (what E8 exercises) but not
> yet `recover()`; the E3/E5-complete account ships at the coordinated cutover redeploy.

## Verifying it worked — deterministically (no LLM inference)

**Do NOT judge success by the chat reply.** An LLM may phrase a memory-aware
answer many ways, treat a past-dated memory as "not this weekend", or even
*disown* the injected context as a hallucination — the prose is not a reliable
signal. The harness's authoritative check is **step 4.2**, which fires the
`pre_llm_call` hook through **Hermes' own config-wired dispatcher** and asserts
the real memory is injected.

**Where to run it — IN THE SANDBOX, not on your laptop.** The harness (run on
your laptop) does the *setup*: sandbox + build + `wire` + MCP + Phase P pairing +
seed. Verifying is a separate, **standalone** command run *inside the sandbox* —
you do **not** need to re-run the harness, as long as the demo is already set up
(MCP up + hooks wired + memory seeded). Two ways to run it:

```bash
# From your laptop, into the running sandbox container:
docker exec -it <sandbox-container> bash -lc "hermes hooks test pre_llm_call"

# …or from a shell already inside the sandbox (e.g. the code-server terminal):
hermes hooks test pre_llm_call
#   → stdout: {"context":"## Memory: travel\nChengdu trip — Apr 12 to 16, hotpot at Yulin."}
#   → parsed (Hermes wire shape): {"context": "..."}   ← injected into the LLM request
hermes hooks doctor              # all 3 wired hooks: exec + valid JSON
```

Step 4.2 of the harness runs exactly this for you (so a full `--real --webauthn`
run reports the result inline); the standalone command is for re-checking anytime
without re-running the harness.

`4.2 inject (deterministic) ok` means the permissioned memory reached the LLM
request — the actual AgentKeys guarantee. `stdout: {}` / `parsed: <none>` means it
did **not** (MCP down, scope not granted, or session bad) — that's the real
failure even if a chat reply *sounds* memory-aware. The 4.3 chat "surprise" is an
optional live demo; run it **while the gate is open** (Phase 5 stops the MCP).

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
`MEMORY_ENGINE` (default `passthrough`; set `lexical` for deterministic recency/relevance selection) / `MEMORY_MAX_LINES` (cap injected lines) — the engine is baked into the wired `pre_llm_call` hook and runs over the **real worker's** lines (plan §6a); a multi-line `SEED_MEMORY_CONTENT` makes the selection visible,
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
| memory put/get → HTTP **502** `{"reason":"s3_put"}` / `{"reason":"s3_get"}` | the MCP `http` backend didn't forward per-actor STS creds, so the worker fell back to its EC2 instance profile (SES-only, **no S3**) → AccessDenied on every op. cap-mint + chain-verify themselves SUCCEED (the agent IS authorized); the gap was the credential **relay**. | **Fixed (issue #90):** the backend now mints agent-tagged STS creds (`0.8` agent session → broker `/v1/mint-oidc-jwt` → `AssumeRoleWithWebIdentity(memory-role)`, tagged `agentkeys_actor_omni`) and forwards them as `X-Aws-*` headers, so AWS scopes S3 to `bots/<actor>/memory/`. If it still 502s: confirm `P.1b retrieve` shows "agent retrieved J1_agent in-sandbox" (or `0.8 agent session` under `--reuse-agent`) and `P.3 grant` granted the scope; the relay needs the in-sandbox agent session + `MEMORY_ROLE_ARN`/`VAULT_ROLE_ARN`/`REGION` from `operator-workstation.env`. Optional strict enforcement: set `AGENTKEYS_WORKER_REQUIRE_STS=1` in the worker env (rejects credless requests with 401 instead of falling back). |
| **Phase P** `P.depair`/`P.0`/`P.1`/`P.1b`/`P.2`/`P.3` fails | `P.depair` revoke: master gas / RPC, or the sandbox unreachable for the K10 wipe. `P.0` request: stale sandbox `agentkeys-daemon` (no `--request-pairing`) or broker `/v1/agent/pairing/request` down (no session needed). `P.1` claim: broker `/v1/agent/pairing/claim` down or the operator session (0.7) invalid. `P.1b` retrieve: broker `/v1/agent/pairing/poll` down, or an expired request (>600s before the master claimed). `P.2` bind: on-chain `registerAgentDevice` failed (master gas / RPC). `P.3` grant: `heima-scope-set --webauthn` needs K11 webauthn enrollment + Touch ID. | `P.1` check 0.7 + the broker + master wallet balance. `P.0`/`P.1b` 1.3 rebuilds+uploads the daemon binary — just re-run (each run mints a **fresh** K10, so a retry re-pairs cleanly). `P.2` check the master wallet balance / RPC. `P.3` enroll K11 webauthn + pass `--webauthn`. For a quick loop without pairing use `--reuse-agent`. |
| `1.3 linux build` is slow even for a one-line change | (a) rustup re-downloaded the host-pinned toolchain (~250 MB, ~4 min) because `/usr/local/rustup` wasn't cached; (b) on macOS, cargo's `target/` sat on a **host bind-mount**, so every incremental file crossed the Docker VM's virtiofs layer | fixed on both: (a) the toolchain persists in `RUSTUP_VOL`; (b) `CARGO_TARGET_DIR` is now a **named volume** (`agentkeys-sandbox-target`) on the VM's native fs, with only the 3 final binaries copied out. First build seeds the caches (~4 min); later builds are incremental compile only (~15 s) |
| Phase 1 `1.3 linux build` → "cannot pull" | Docker Hub unreachable for the base image | `RUST_BUILD_IMAGE=<local/mirror rust image>` or pre-pull `rust:1.83-slim-bookworm` |
| `1.3 linux build` won't pick up a Rust edit | gate compares source mtime vs binary; re-runs rebuild automatically on a real edit | to force a from-scratch rebuild: `rm -rf target/sandbox-linux && docker volume rm agentkeys-sandbox-target agentkeys-sandbox-cargo-registry agentkeys-sandbox-cargo-git` (the `target/` dir now lives in the `agentkeys-sandbox-target` volume — `target/sandbox-linux` on the host holds only the 3 extracted binaries); to rebuild the deps image: `docker rmi agentkeys-sandbox-builder:1.83-bookworm` |
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
| `P.1 claim` → `unrecognized subcommand 'agent'` (then `1.4 mcp` / wire / Acts cascade) | a **stale** master-side `agentkeys` (predates #144) — Phase P §10.2 needs the `agent` subcommand | step **0.2b** now builds + verifies it automatically (`cargo build --release -p agentkeys-cli` → `target/release/agentkeys`, which the harness prefers). If you set `AGENTKEYS_SKIP_CLI_BUILD=1`, build it yourself or `cp` a current binary onto your PATH. The MCP/wire/Acts failures are cascades — they clear once P.1 works |
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
- [Issue #152](https://github.com/litentry/agentKeys/issues/152) — **scope:** this runbook covers the **Local-LLM / Task-agent** path only (stdio MCP server built + run *in the sandbox*). The **Hosted-LLM** path (xiaozhi / vendor-cloud — a broker-hosted `mcp-endpoint` the remote LLM connects *into*, per arch.md §22c.2 / §22d.3) is deferred to #152.
