# v2 stage 1 — iteration log

Per-iteration error → fix summary for the remaining v2 stage-1 + stage-2 (#91) work. Each iteration is one PR-sized unit; sub-steps under each iteration capture the specific failure mode and the resolution that landed.

The companion PRD is at [.omc/prd.json](../.omc/prd.json) (12 stories ordered P0 → P2).

---

## Iteration A — live runtime debug pass (2026-05-19 follow-up)

After the first set of iterations 1-12 landed the scripts, **a fresh run of `bash harness/v2-stage1-demo.sh --from-step 12` on Heima mainnet surfaced real bugs that the unit tests didn't catch**. This section documents every error encountered + the underlying fix, in the order they came up.

### Error A.1 — `getScope` ABI decode mismatch (heima-scope-set.sh + heima-scope-revoke.sh)

**Symptom**: re-running `bash harness/v2-stage1-demo.sh --only-step 12` submitted a new `setScopeWithWebauthn` tx every time instead of short-circuiting. Idempotency check printed `"scope not yet set (or differs) → proceeding"` even when the scope WAS already set on-chain.

**Diagnosis** (probed directly with `cast call`):
```bash
$ cast call 0x14C2…aa8 \
    "getScope(bytes32,bytes32)(bytes32[],bool,uint128,uint128,uint128,uint32,uint64,bool)" \
    0x941c…bef2 0x82a0…7268 --rpc-url $RPC
Error: could not decode output; did you specify the wrong function return data type?
Context:
- ABI decoding failed: buffer overrun while deserializing
```

The function returns a **single `Scope` struct**, not a flat tuple. Cast's `(bytes32[],bool,uint128,...)` signature expects 8 separate return values; the contract returns 1 (a wrapped struct). Cast aborts; `cast call` returns empty in the `2>&1 || echo ERR` wrapper; the `if [ -n "$EXISTING_SCOPE" ]` branch never entered; idempotency check silently falls through.

**Fix**: wrap the struct in outer parens — `((bytes32[],bool,uint128,uint128,uint128,uint32,uint64,bool))`. Verified:
```bash
$ cast call ... "getScope(...)((bytes32[],bool,...))" ...
([0x9d7e…e901], false, 0, 0, 0, 0, 1779149808 [1.779e9], true)
```

**Where**: `scripts/heima-scope-set.sh:155` + `scripts/heima-scope-revoke.sh:87`.

**Bonus fix**: cast prints the struct on a single line — the previous parse used `sed -n '1p'` / `sed -n '8p'` to extract fields, which only worked if cast printed line-per-field (which it does NOT for `(struct)` returns). Replaced with an inline `python3` parser that strips the outer parens, extracts the services array, and splits the remaining 7 fields on commas. Also strips cast's `[1.779e9]` scientific-notation annotations.

**Verify**:
```bash
$ bash harness/v2-stage1-demo.sh --only-step 12   # first run
==> [step 12/15] Grant agent scope (setScopeWithWebauthn)
…
    ok   scope set — txhash 0x99a4…06c8 (block 9621848)
$ bash harness/v2-stage1-demo.sh --only-step 12   # second run — no new tx
==> [step 12/15] Grant agent scope (setScopeWithWebauthn)
…
==> Idempotency check: scope already set?
    skip scope already matches requested config — no-op
```

### Error A.2 — step counter always shows `[step 1/15]` regardless of which step actually runs

**Symptom**: `bash harness/v2-stage1-demo.sh --only-step 12` printed `==> [step 1/15] Grant agent scope…` — confusing operator-facing output.

**Diagnosis**: `STEP_NUM=0` initialized at module-load time; `step()` does `STEP_NUM=$((STEP_NUM+1))` on each call. With `--only-step N` the dispatcher skips steps 1..N-1 (their `do_step_X` calls never fire), so the counter never reaches N before the surviving step calls `step "..."` and lands on 1.

**Fix**: pre-seed `STEP_NUM=$((FROM_STEP - 1))` after argument parsing so the first `step()` call lands on the correct step number.

**Where**: `harness/v2-stage1-demo.sh:162` (after the `--only-step` collapse to FROM_STEP/TO_STEP, before the `in_scope` helper).

### Error A.3 — stale "today this errors with 'unrecognized subcommand device'" text in step 15 summary

**Symptom**: step 15 printed "Next manual steps (not yet automated — pending stage-1 CLI work): agentkeys ... device register" with a note that the subcommand "today errors with 'unrecognized subcommand device'." Reality: the bash entries (`scripts/heima-*.sh`) DID ship and are wired into steps 10-13.

**Fix**: replaced the summary block with a list of the shipped bash entries (device-register, agent-create, scope-set, credential-audit, scope-revoke, device-revoke) + a pointer to stage 2 (#90) for the Rust CLI subcommand wrappers.

**Where**: `harness/v2-stage1-demo.sh:639-647` (`do_step_15` summary printf block).

### Step 13 idempotency note

Step 13 (`CredentialAudit.append`) is intentionally NOT idempotent — the on-chain contract is append-only. Each demo re-run adds a fresh audit entry; `entryCount` monotonically increments. This is correct contract semantics (the demo is showing "an audit entry was appended", not "exactly one audit entry exists").

If we want demo-step-level idempotency, the fix is to use a sentinel `payload_hash` (e.g. `keccak("demo-marker:" || session-id)`) and pre-scan `getEntries(operator, 0, entryCount)` for that marker. Deferring this; the current design exercises the audit-append path end-to-end which is the whole point of the demo step.

### Verified idempotent re-run

After all 3 fixes (A.1, A.2, A.3):
```bash
$ bash harness/v2-stage1-demo.sh --from-step 12   # first run → all 4 steps green
$ bash harness/v2-stage1-demo.sh --from-step 12   # second run from scratch shell
  step 12 → skip (idempotent)
  step 13 → +1 audit entry (append-only by contract; intentional)
  step 14 → "K11 enrollment already exists" skip
  step 15 → summary print (no on-chain action)
```

All 4 steps print correct `[step N/15]` counter and pass green.

### Error A.4 — `python3` dep unchecked + parser failures silently swallowed (codex review finding)

**Symptom**: codex adversarial review of commit `65aae78` flagged that the new `python3` parser in `heima-scope-{set,revoke}.sh` was invoked with `2>/dev/null || true`, so:
- A workstation missing `python3` silently falls through to "scope not yet set (or differs) → proceeding" and re-submits a tx (recreates the original A.1 bug).
- The orchestrator's tool sanity-check (`do_step_1`) did NOT list `python3` as a required tool.
- A transient RPC error from cast call could also produce malformed output that breaks the parser silently.

**Fix (3 places)**:
- `harness/v2-stage1-demo.sh:177`: added `python3` to the prereq tool list in step 1 sanity-check.
- `scripts/heima-scope-set.sh:160-175`: pre-check `command -v python3` and `die` if missing; removed `2>/dev/null || true`; added explicit `PARSE_RC=$?` check post-invocation that `die`s with the raw cast output included.
- `scripts/heima-scope-revoke.sh:90-105`: same fix pattern.

Now: missing python3 → loud failure at step 1, NOT silent re-submission. Parser failures → loud failure with the raw cast output dumped for diagnostics.

### Verified after codex fix

```bash
$ bash harness/v2-stage1-demo.sh --from-step 12   # second-pass post-codex-fix
  step 12 → skip scope already matches  (idempotent ✓)
  step 13 → +1 audit entry              (append-only by contract ✓)
  step 14 → K11 enrollment already exists
  step 15 → summary print
  All counters correct: [step 12/15], [step 13/15], [step 14/15], [step 15/15].
```

---

## Audit pass — bypass / hardcoded / theatre (2026-05-19, post-codex)

User-requested adversarial audit: "make sure in the demo docs there is no bypass code, or hardcoded code, all the code must run against the real architecture design and the real environment".

### Finding AUDIT.1 — false `arch.md §22a` citations across stage-1 stub sites

**Type**: theatre / arch-mismatch
**Symptom**: 4 source files claimed "stage-1 simplification per arch.md §22a" but §22a is actually titled "Chain profiles — how to switch between EVM backbones" and says nothing about K11 stubs / KEK-from-env / empty attestation bytes. There was NO authorising section in arch.md for those simplifications.
**Where**: `scripts/heima-{scope-set,agent-create,device-register}.sh` + `crates/agentkeys-broker-server/src/handlers/cap.rs`.
**Fix**: added a real `arch.md §22b — Stage-1 simplifications inventory` section listing each authorised deviation (22b.1 K11 stub vs `--webauthn`; 22b.2 KEK from env; 22b.3 attestation empty bytes; 22b.4 no K10-sig requirement on cap-mint requests; 22b.5 direct-tx audit anchoring) with explicit stage-2 issue pointers. Re-pointed every citation in code from `§22a` → `§22b`.

### Finding AUDIT.2 — K11 was a stub-only stage with no path to a real ceremony

**Type**: bypass (admitted but unfixed)
**Symptom**: `agentkeys k11 enroll` produced deterministic bytes that just satisfy `length != 0`. No real WebAuthn, no Touch ID. Operators on macOS had NO way to bind a real platform passkey to K11 without waiting for stage 2 (#90).
**Where**: `crates/agentkeys-cli/src/k11.rs`.
**Fix**: shipped real WebAuthn ceremony behind `--webauthn` flag:
- New `crates/agentkeys-cli/src/k11_webauthn.rs` (~600 LOC, manual ceremony — no `webauthn-rs` heavy dep needed).
- `agentkeys k11 enroll --webauthn` brings up a localhost axum server, opens default browser, prompts Touch ID, persists real attested credential to `~/.agentkeys/k11/<omni>.json` with `mode: "webauthn"`.
- `agentkeys k11 assert --webauthn --message-hex 0x...` runs `navigator.credentials.get()` with `challenge = sha256(message)`, returns the real assertion (authenticatorData || clientDataJSON || signature) hex-encoded. The application message is cryptographically bound to the WebAuthn signature via the challenge field.
- Without `--webauthn`, defaults to the deterministic stub (CI / non-attested envs).
- WARN to stderr when stub mode is used on `AGENTKEYS_CHAIN=heima` (mainnet) pointing at arch.md §22b.1 + issue #90.

### Finding AUDIT.3 — KEK-from-env had no startup WARN + accepted obviously-weak placeholders

**Type**: bypass (no fail-loud guarantee on production)
**Symptom**: `AGENTKEYS_WORKER_KEK_HEX` / `AGENTKEYS_MEMORY_KEK_HEX` accepted any 32-byte hex including all-zeros, all-same-byte. No WARN at boot to tell the operator "this is a stage-1 stub; stage 2 uses mTLS-derived KEK from the signer."
**Where**: `crates/agentkeys-worker-creds/src/state.rs` + `crates/agentkeys-worker-memory/src/state.rs`.
**Fix**:
- Reject all-zeros and all-same-byte KEK at startup with explicit error.
- Print fail-loud WARN at startup citing arch.md §22b.2 + issue #91.

### Finding AUDIT.4 — stale "not yet implemented" in demo doc

**Type**: doc drift
**Where**: `docs/v2-stage1-migration-and-demo.md:1328` — `--credential-backend=sidecar` row said "stub" but the daemon proxy + cap-mint + worker chain is all shipped.
**Fix**: replaced with the actual shipped surface description + invocation recipe.

### Verified after audit fixes

```bash
$ cargo test -p agentkeys-cli                                # all CLI tests pass
$ AGENTKEYS_CHAIN=heima target/debug/agentkeys k11 assert \
    --operator-omni 0xaa…aa --message-hex deadbeef
==> ⚠️  WARN: K11 stub mode active on chain=heima. The bytes you're about to produce
    are NOT a real WebAuthn assertion — they only satisfy the on-chain
    k11Assertion.length != 0 gate. Pass --webauthn for a real Touch ID ceremony...
0x7374616765312d6b31312d737475623a... (the stub bytes)
$ target/debug/agentkeys k11 enroll --webauthn --operator-omni 0xaa…aa
==> waiting for WebAuthn enrollment in browser at http://localhost:<random>
==> macOS Touch ID prompt should appear in your browser…
   (browser opens; user taps Touch ID; result POSTs back; CLI prints JSON
   with mode="webauthn" + real COSE pubkey)
```

## Audit codex review passes

| Pass | Commit | Verdict | Findings |
|---|---|---|---|
| Audit-1 | `ae2ada7` | REJECTED | 5 must-fix: 2 remaining false §22a citations in main.rs; CBOR auth-data not validated (rpIdHash + flags + cred-id); double-hash signature verify; timeout-abort unreachable; KEK check missed alternating-hex-char patterns |
| Audit-2 | `d0ab230` | APPROVED | All 5 must-fix addressed: cite §22b.1; finalize_enroll verifies rpIdHash + UP/UV/AT + cred-id; signed_bytes passed unhashed to verify; AbortOnDrop<T> RAII guard; hex::decode-then-iter().all() byte uniformity check |

---

## Codex review passes

| Pass | Commit | Verdict | Findings |
|---|---|---|---|
| 1 | `65aae78` | REJECTED | python3 dep unchecked + parser failures swallowed with `2>/dev/null || true` |
| 2 | `cd77e68` | REJECTED | `set -euo pipefail` aborted `$(python3 ...)` before `PARSE_RC=$?` ran — diagnostic branch unreachable |
| 3 | `a2ade7c` | APPROVED | `set +e` / `set -e` bracketing makes PARSE_RC inspection reachable; happy path unchanged |

Final test pass:
- `bash harness/v2-stage1-demo.sh --from-step 12` on Heima mainnet → exit 0, step 12 logs skip (idempotent), steps 13/14/15 green
- `AGENTKEYS_CHAIN=heima bash scripts/verify-heima-contracts.sh` → 13/13 checks pass

Deslop pass: no-op. The python3 parser blocks in `heima-scope-{set,revoke}.sh` decode different subsets of the Scope struct (set: all 8 fields for config-equality check; revoke: only services + exists for "is the scope empty" check). Extracting would be over-abstraction and break the operator-readability principle for these scripts (each runnable + readable in isolation).

---

## Iteration 1 — funding helper script (US-001)

**Scope**: Ship `scripts/heima-fund-account.sh` so downstream agent/scope scripts can mint fresh test wallets without baking the deployer key into anything.

**Errors + fixes**:

No runtime errors. Live test from operator master (`0xdE644…3Bc`) → fresh address: funded with 1 HEI, re-run skips with `recipient already has 1 HEI (≥ 1)`.

---

## Iteration 2 — agent-device registration (US-002)

**Scope**: Ship `scripts/heima-agent-create.sh` wrapping `SidecarRegistry.registerAgentDevice(...)` with idempotency + fresh wallet generation + auto-funding.

**Errors + fixes**:

(populated during execution)

---

## Iteration 3 — scope set + revoke (US-003, US-004)

**Scope**: Ship `scripts/heima-scope-set.sh` + `scripts/heima-scope-revoke.sh` wrapping `AgentKeysScope.setScopeWithWebauthn(...)` / `revokeScope(...)`.

**Errors + fixes**:

(populated during execution)

---

## Iteration 4 — credential audit append (US-005)

**Scope**: Ship `scripts/heima-credential-audit.sh` wrapping `CredentialAudit.append(...)`.

**Errors + fixes**:

(populated during execution)

---

## Iteration 5 — wire into v2-stage1-demo orchestrator (US-006)

**Scope**: Compose all four new scripts into `harness/v2-stage1-demo.sh` as steps 10-13; ensure idempotent end-to-end re-run.

**Errors + fixes**:

(populated during execution)

---

## Iteration 6 — broker cap-mint endpoints (US-007)

**Scope**: `crates/agentkeys-broker-server/src/handlers/cap.rs` with `/v1/cap/cred-store` + `/v1/cap/cred-fetch`; on-chain ScopeContract + K3EpochCounter + SidecarRegistry reads.

**Errors + fixes**:

(populated during execution)

---

## Iteration 7 — sidecar daemon localhost proxy (US-008)

**Scope**: `crates/agentkeys-daemon/src/proxy.rs` with axum + unix socket + 5-min TTL cap-token cache + 60s stale-broker fail-closed.

**Errors + fixes**:

(populated during execution)

---

## Iteration 8 — K11 WebAuthn enrollment scaffolding (US-009)

**Scope**: `agentkeys k11 enroll` + `agentkeys k11 assert` subcommands via `webauthn-rs`; stub mode for CI.

**Errors + fixes**:

(populated during execution)

---

## Iteration 9 — credentials-service worker (US-010, issue #91)

**Scope**: `crates/agentkeys-worker-creds/` new crate + axum server + cap verify + AES-256-GCM envelope + S3 PUT/GET against `$VAULT_BUCKET`.

**Errors + fixes**:

(populated during execution)

---

## Iteration 10 — codex adversarial review (US-011)

**Scope**: Run codex critic; fix must-fix findings.

**Codex findings (2026-05-19 review pass, 8 total — 6 must-fix, 2 should-fix)**:

| # | Severity | Where | Fixed in |
|---|---|---|---|
| 1 | must-fix | broker cap-mint endpoints accept unauthenticated JSON — anyone with chain-knowledge can mint caps | commit `<this>`: added `verify_session_jwt` extraction, session-omni binding check |
| 2 | must-fix | broker only calls `isActive` — never verifies device → operator/actor/role binding | commit `<this>`: replaced with full `getDevice` decode + `revoked`/`operator`/`actor`/`roles & CAP_MINT` checks |
| 3 | must-fix | worker's "independent re-verify" skips device binding, K3 epoch | commit `<this>`: worker now calls `getDevice` + `currentEpoch` independently before any S3 touch |
| 4 | must-fix | worker honored caps regardless of `payload.op` — fetch-cap accepted at /store | commit `<this>`: each endpoint passes its `expected_op` into `verify_cap`; `check_op` rejects mismatch with 403 cap_op_mismatch |
| 5 | must-fix | worker's AAD format (`sha256(o\|a\|s\|epoch)`) differed from CLI's (`agentkeys.cred.aad.v2\|<actor>\|<service>`) — round-trip broken | commit `<this>`: worker's `envelope::aad` rewritten to match CLI byte-for-byte; new test `tests/envelope_cross_compat.rs` pins the shape |
| 6 | must-fix | daemon had `proxy` module but no subcommand wiring — dead code | commit `<this>`: added `--proxy` flag + `run_proxy_mode` that binds Unix socket (0600 perms) + optional TCP via `--proxy-tcp` |
| 7 | should-fix | broker/worker hardcoded `_HEIMA` env names, bypassing the chain-profile system | commit `<this>`: both now resolve env keys via `AGENTKEYS_CHAIN` → `{NAME}_{PROFILE_UC}` lookup |
| 8 | should-fix | no CLI `k11 enroll/assert` subcommand surfaces the k11 module | commit `<this>`: added `Commands::K11 { Enroll, Assert }` dispatch through `cmd_k11`; gated on `AGENTKEYS_K11_STUB=1` (default) |

All 8 findings addressed in a single follow-up commit. Cap-payload shape evolved:
```diff
- { operator_omni, actor_omni, service, op, k3_epoch, expires_at, nonce }
+ { operator_omni, actor_omni, service, op, device_key_hash, k3_epoch, issued_at, expires_at, nonce }
```
Both the broker (sign) and worker (verify) emit/consume the new shape; the
shared JSON encoding is the source of truth for the canonical bytes.

**Errors + fixes**:

- Cargo.toml: `sha3` was gated by `auth-wallet-sig` feature — broke cap.rs which always needs Keccak256. Fix: promoted `sha3` to mandatory dep, removed `"dep:sha3"` from feature line.
- Cargo.toml: daemon's `axum`+`tower`+`hyper` were dev-deps only — broke `proxy.rs`. Fix: moved to runtime deps; removed dev-dep duplicates.
- Worker: AAD mismatch with CLI was the silent bug — only caught by cross-crate test vector. Lesson: every cross-crate format MUST have a vector test, not just unit tests inside each crate.
- Daemon proxy subcommand: had to do unix-listener accept loop manually since axum 0.7 doesn't ship a hyper-util adapter for UnixListener out of the box. Used `hyper_util::server::conn::auto::Builder` + `tower::Service::call` pattern.

---

## Iteration 11 — final end-to-end demo (US-012)

**Scope**: Re-run the full orchestrator end-to-end on heima mainnet; verify idempotency + update doc tables.

**End-state**:
- `docs/v2-stage1-migration-and-demo.md` "What's still in flight" table updated; every prior `⏳ not yet` is now `✅ shipped` with file/contract/tx references.
- `harness/v2-stage1-demo.sh` end-to-end now wraps 15 steps: 1-9 install + email + SIWE + OIDC + vault provisioning + envelope smoke + chain deploy; 10-13 device-register + agent-create + scope-set + audit-append; 14 K11 stub enrollment; 15 summary.
- All cargo tests pass workspace-wide.
- Codex pass-1 + pass-2 reviews landed (8 + 7 findings respectively, all addressed in commits `cff03d0` + `89ec55c`).

## Iteration 11b — deslop pass + clippy fixes

**Scope**: Bounded cleanup pass on the changed-file set per Ralph Step 7.5 (no scope expansion).

**What landed**:
- New `crates/agentkeys-worker-creds/src/errors.rs` module exporting
  shared `ErrorBody` + `ApiError` types + `err_400/err_403/err_500/err_502`
  helpers. Both worker-creds and worker-memory (which deps on
  worker-creds as a lib) now use it; ~28 lines of duplicate boilerplate
  removed; cross-worker wire-shape stays consistent.
- Clippy fixes: `.chars().last() == Some('1')` → `.ends_with('1')`
  (3 call sites in broker + worker); removed 3 redundant closures in
  memory handler error mappers; promoted `CapCache` + `CachedCap` to
  `pub` to fix the proxy state visibility warning.

**Errors + fixes**:
- ai-slop-cleaner skill flagged the heima-*.sh script duplication
  (color helpers, log functions, master-key resolution boilerplate
  repeated across 6 scripts) but I left it alone: per the
  operator-readability principle in `docs/cloud-bootstrap.md` style, each
  operator-facing script should be readable in isolation. Bash `source`
  indirection would hurt that. ~360 LOC of cross-script duplication
  is intentional, not slop.

## Iteration 11c — final codex sign-off

**Verdict (third codex pass, post-deslop + stage-2 additions): APPROVED — ready to ship.**

Codex verified:

1. **Deslop wire-compat** — shared `errors.rs` module's `{error, reason}` JSON shape + HTTP status codes match the per-worker inline error types previous commits removed (`f0fa0af^`). Behavior preserved.
2. **Memory worker per-data-class isolation** — `bots/<actor>/memory/...` path (not `credentials/...`), `$MEMORY_BUCKET` (not `$VAULT_BUCKET`), `$AGENTKEYS_MEMORY_KEK_HEX` (not the creds KEK). No cross-references in `crates/agentkeys-worker-memory/`. Per arch.md §17 a compromise of the creds KEK does NOT unlock memory blobs.
3. **Device-revoke K11 gating** — script passes non-empty stub bytes when `--master`, empty bytes (`0x`) when `--agent`, matching the on-chain contract gate at `SidecarRegistry.sol:162-164` (`tier == TIER_MASTER && k11Assertion.length == 0` → revert).
4. **No new must-fix.**

**Final test counts (cargo test --workspace post-deslop, post-clippy)**: 546 tests passed across 42 suites, 0 failures.

**Final on-chain health check** (`AGENTKEYS_CHAIN=heima bash scripts/verify-heima-contracts.sh`): 13/13 checks pass against Heima mainnet contracts at the addresses in `operator-workstation.env`.

## Iteration 12 — stage-2 / issue #90 foundation

**Scope**: Multi-device recovery scaffold + memory-service worker per arch.md §15.2 + §17 per-data-class buckets policy.

**Deliverables shipped in this iteration**:
- `scripts/heima-device-revoke.sh` — wraps `SidecarRegistry.revokeDevice(deviceKeyHash, k11Assertion)`. Supports `--agent <label>` / `--device-key-hash 0x...` / `--master` modes. K11 stub bytes for master revokes (agent revokes pass empty bytes per the contract). Idempotency via `getDevice.revoked` + `registeredAt > 0` checks. Post-tx verifies `isActive == false`.
- `crates/agentkeys-worker-memory` — new crate per arch.md §15.2. Reuses `agentkeys_worker_creds`'s envelope + verify modules; only the S3 path prefix (`bots/<actor>/memory/...`) and bucket name (`$MEMORY_BUCKET`) differ. Tracks issue #90's memory-service-worker task.

**Errors + fixes**:

(populated during stage-2 execution)

---

## K3 rotation test — 2026-05-19 (Heima Mainnet)

Driver: `scripts/heima-k3-rotate.sh` against
`K3EpochCounter = 0xeacc97d4e7854c52d4736e5fba2dc7c2c2b147d9` on Heima Mainnet.
Per the contract design `advanceEpoch()` is forward-only, so the "back and forth"
test is bounded to forward-path correctness + idempotency.

### Round 1 — single advance

**Cmd**: `bash scripts/heima-k3-rotate.sh`

**Pre**: `currentEpoch() = 1`

**Tx**: `0xda25e5f340f66a9d08ff8d35c354a6cd62ce34508a8286c5797c64c16f47ed6b`

**Post**: `currentEpoch() = 2` ✓

### Round 2 — second single advance

**Cmd**: `bash scripts/heima-k3-rotate.sh`

**Pre**: `currentEpoch() = 2`

**Tx**: `0x8e8deab538b921b6ca67ea88eadce40e487e3aaee6cf99c93e3a38ab2881b059`

**Post**: `currentEpoch() = 3` ✓

### Round 3 — idempotency skip

**Cmd**: `bash scripts/heima-k3-rotate.sh --target-epoch 3`

**Pre**: `currentEpoch() = 3`

**Behaviour**: script pre-reads currentEpoch (3) vs target (3), logs
`skip currentEpoch (3) already >= target (3)`, exits 0 with
`{"ok":true,"skipped":"already-at-target","current_epoch":3}`. No tx submitted.

**Post**: `currentEpoch() = 3` ✓

### Round 4 — multi-step advance

**Cmd**: `bash scripts/heima-k3-rotate.sh --target-epoch 6`

**Pre**: `currentEpoch() = 3`

**Behaviour**: script computes 3 steps (3 → 6), sends 3 sequential
`advanceEpoch()` txs:
- step 1: `0x0e42480835d5000143db8101b16c7108e618530f72b87e336fd5551d852a0c3e`
- step 2: `0x7479495b1055884602cd596d076e8acb8b56de2f944ec630060330373ef30c74`
- step 3: `0x66c00a8d46b173ff206257df5ebabe89c2636a2efd466777f21fd7d625cac00d`

**Post**: `currentEpoch() = 6` ✓

### Verdict

5 real txs landed; script idempotent + multi-step both work. The
forward-only invariant of `K3EpochCounter` is enforced — there is no
"rotate back" by contract design (historical epochs are retained inside
the signer enclave for decrypt of pre-rotation blobs, not on chain).

No errors surfaced. `K3EpochCounter` now at epoch 6 on Heima Mainnet.

## Phase 1 — issue #90 Q3 + codex review final verification (2026-05-20 12:30 UTC)

Re-verification pass after the two codex-review fix commits (18e709b + e9926ed) on PR #92. The harness skill ran all three demos sequentially against Heima Mainnet in stub mode. Acceptance: all three exit 0, all steps land green, clippy clean.

| Demo | Steps | Result | Notes |
|---|---|---|---|
| `harness/v2-stage3-demo.sh` | 11 / 11 | ✅ all green | NEW. Steps 5/6/8/9/10 prove cross-actor + cross-data-class IAM isolation via AccessDenied. Steps 4/7 succeed (same-actor writes). Closes codex P2 (memory worker OIDC) + codex P2 (ListBucket whole-bucket). |
| `harness/v2-stage1-demo.sh` | 16 / 16 | ✅ all green | Step 10 skip (already-registered), 12 skip (already-registered), 13 skip (stub-mode-refuses-touchid). Step 15 (NEW): tier-A audit relay → on-chain `CredentialAudit.appendRoot`. |
| `harness/v2-stage2-demo.sh` | 11 / 11 | ✅ all green | Steps 1-9 stage-2 hardening flow. Step 10 (NEW): tier-A worker smoke same as stage-1 step 15. Step 11 cleanup. |

Other phase-1 gates:
- `cargo clippy -p agentkeys-worker-creds -p agentkeys-worker-memory --no-deps` → zero warnings.
- Backward compat verified: workers without `X-Aws-*` headers fall back to instance profile (existing stage-1 step 8 S3 smoke + stage-1 step 15 + stage-2 step 10 worker-smoke all use the fallback path and remain green).

No regressions introduced by commits `18e709b` (downgrade-attack fix + credential redaction) or `e9926ed` (memory bucket+role + ListBucket scoping). PR #92 is phase-1-ready.

## Phase 1+2 — codex round-2 adversarial review fix + verification (2026-05-20 18:00 UTC)

After PR #92's data-class-explicit isolation work, the codex adversarial review of stage-3 returned `needs-attention` with three findings (one high, two medium):

| # | Severity | Finding |
|---|---|---|
| 1 | high | Worker roundtrip checks could be `skip; return 0` and still appear as "byte-for-byte AES-256-GCM coverage" in the summary table |
| 2 | high | Negative cap-class tests accepted ANY non-200 as pass (404 route, 502 broker stale, generic 403 — all silently green) |
| 3 | medium | Cross-actor cap-mint test accepted generic rejection; 502 (broker stale) was a `skip` instead of a fail |

All three closed in commit `c55ea29`:

- STRICT default mode + `--allow-skip` opt-in for dev iteration
- Steps 14+15 (cross-class) require canonical `cap_data_class_mismatch` + HTTP 4xx
- Step 13 (cross-actor) requires canonical `OperatorMismatch` + HTTP 4xx; 502 with config-missing body is now a hard fail
- Final summary built from per-step `STEP_OUTCOMES[]` array — reflects actual execution, no hardcoded coverage claims
- Summary exits non-zero if any step failed OR if any step skipped in strict mode

Live-verified on Heima Mainnet (2026-05-20):

| Demo | Steps recorded | Outcome |
|---|---|---|
| `harness/v2-stage3-demo.sh` | 13/13 ok (steps 4-15) | DEMO COMPLETE — full isolation + roundtrip coverage proven |
| `harness/v2-stage1-demo.sh` | 16/16 green | unchanged (backward compat) |
| `harness/v2-stage2-demo.sh` | 11/11 green | unchanged |

Step 11+12 (worker encrypt/decrypt) recorded canonical `byte-for-byte roundtrip` outcomes for both cred + memory workers using agent-side SIWE + STS creds. Step 13 (cross-actor) returned HTTP 403 + OperatorMismatch. Steps 14+15 (cross-data-class) returned HTTP 403 + cap_data_class_mismatch.

After commit `5b0516b` (summary-block bug fix), the strict-mode summary renders correctly: per-step outcome list + totals + final verdict.
