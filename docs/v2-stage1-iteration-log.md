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

**Errors + fixes**:

(populated during execution)

---

## Iteration 11 — final end-to-end demo (US-012)

**Scope**: Re-run the full orchestrator end-to-end on heima mainnet; verify idempotency + update doc tables.

**Errors + fixes**:

(populated during execution)
