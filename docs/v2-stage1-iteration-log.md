# v2 stage 1 — iteration log

Per-iteration error → fix summary for the remaining v2 stage-1 + stage-2 (#91) work. Each iteration is one PR-sized unit; sub-steps under each iteration capture the specific failure mode and the resolution that landed.

The companion PRD is at [.omc/prd.json](../.omc/prd.json) (12 stories ordered P0 → P2).

---

## Iteration 1 — funding helper script (US-001)

**Scope**: Ship `scripts/heima-fund-account.sh` so downstream agent/scope scripts can mint fresh test wallets without baking the deployer key into anything.

**Errors + fixes**:

(populated during execution)

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

**Scope**: Compose all four new scripts into `scripts/v2-stage1-demo.sh` as steps 10-13; ensure idempotent end-to-end re-run.

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
- `scripts/v2-stage1-demo.sh` end-to-end now wraps 15 steps: 1-9 install + email + SIWE + OIDC + vault provisioning + envelope smoke + chain deploy; 10-13 device-register + agent-create + scope-set + audit-append; 14 K11 stub enrollment; 15 summary.
- All cargo tests pass workspace-wide.
- Codex pass-1 + pass-2 reviews landed (8 + 7 findings respectively, all addressed in commits `cff03d0` + `89ec55c`).

## Iteration 12 — stage-2 / issue #90 foundation

**Scope**: Multi-device recovery scaffold + memory-service worker per arch.md §15.2 + §17 per-data-class buckets policy.

**Deliverables shipped in this iteration**:
- `scripts/heima-device-revoke.sh` — wraps `SidecarRegistry.revokeDevice(deviceKeyHash, k11Assertion)`. Supports `--agent <label>` / `--device-key-hash 0x...` / `--master` modes. K11 stub bytes for master revokes (agent revokes pass empty bytes per the contract). Idempotency via `getDevice.revoked` + `registeredAt > 0` checks. Post-tx verifies `isActive == false`.
- `crates/agentkeys-worker-memory` — new crate per arch.md §15.2. Reuses `agentkeys_worker_creds`'s envelope + verify modules; only the S3 path prefix (`bots/<actor>/memory/...`) and bucket name (`$MEMORY_BUCKET`) differ. Tracks issue #90's memory-service-worker task.

**Errors + fixes**:

(populated during stage-2 execution)
