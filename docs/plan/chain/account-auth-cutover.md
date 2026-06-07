# Account-auth cutover + onboarding-as-account (the #225 / #164 E7 unblock)

**Status:** scope/spec for the idempotent cutover script(s). Implements the cutover outlined in [`erc4337-master-account.md`](erc4337-master-account.md) §3.1 ("Cutover — coordinated redeploy, not yet done"). This doc is the precise procedure; the scripts (Phase wiring below) implement exactly this. **Nothing here has run on live mainnet yet** — it changes the contracts the current demo/harness depend on, so it is operator-gated and runs as a deliberate, announced action.

## Why (the gap)

`SidecarRegistry`/`AgentKeysScope` sources are **already account-auth** in code (E3: master writes gated by `msg.sender == operatorMasterWallet`, `setScopeWithWebauthn`→`setScope`, in-contract K11 + `scopeNonce` retired). But the **live deployed** registry/scope are the **pre-E3** bytecode — `heima-bring-up.sh`'s idempotency check (`cast code` on the stored addresses) sees code there and **skips** the redeploy, so the account-auth contracts never go live. The cutover forces the redeploy and re-points everything at the new addresses. Until it runs, `/v1/accept/build` (PR #227) would read an **EOA** from `operatorMasterWallet` and the sponsored UserOp's `sender` would be a non-account → `EntryPoint` rejects it.

## ⚠️ Consequence — this is a redeploy to NEW addresses, i.e. a full re-bootstrap

`DeployAgentKeysV1.s.sol` deploys the whole v2 set atomically (P256Verifier → K11Verifier → SidecarRegistry → AgentKeysScope → K3EpochCounter → CredentialAudit). Redeploying gives **new addresses with empty state** — the registered master device, every agent binding, every scope grant, the K3 epoch counter, and the audit history are **NOT migrated**. After cutover, the master + all agents must be **re-registered** and scopes **re-granted** (now via the account path). The current working demo breaks until re-bootstrapped. CI already skips first-master, so CI is unaffected. **Announce + schedule this; do not run it mid-demo.**

## Procedure (idempotent; each phase pre-checks + short-circuits)

Run via the new orchestrator `scripts/heima-cutover-account-auth.sh` (wired into `setup-heima.sh` as a NEW, explicitly-opt-in step — it is NOT part of a plain `setup-heima.sh` run because it is destructive; gate it behind `--cutover-account-auth`). All addresses are env-namespaced (`*_HEIMA` / `*_HEIMA_PASEO`) via `env_set`; nothing hardcoded.

| Phase | Action | Idempotency check (skip when…) |
|---|---|---|
| **0. Pre-flight** | Confirm the local `SidecarRegistry.sol` exposes the account-auth shape (e.g. `setScope(bytes32,bytes32,bytes32[],bool,uint128,uint128,uint128,uint32)` selector present in the ABI, NOT `setScopeWithWebauthn`). Back up the current `*_ADDRESS_*` env values to `operator-workstation.env.pre-cutover.bak`. | backup file already exists |
| **1. Redeploy v2 set** | `FORCE_DEPLOY=1 bash scripts/heima-bring-up.sh` → new registry/scope/epoch/audit/verifiers; its `env_set` writes the new addresses. | a `CUTOVER_DONE_${PROFILE}=1` marker is set in env AND the live scope answers `setScope` (account-auth selector) — see Idempotency below |
| **2. Redeploy P256AccountFactory** | Deploy the E5-complete `P256AccountFactory` (embeds the recover()-capable `P256Account`); `env_set P256_ACCOUNT_FACTORY_ADDRESS_${PROFILE}`. | `cast code` on the stored factory AND its embedded account has `recover()` (selector probe) |
| **3. Onboarding-as-account** | `scripts/heima-deploy-master-account.sh`: from the master's enrolled K11 pubkey, `factory.getAddress(...)` → `cast code` → `createAccount(...)` if absent; fund the EntryPoint deposit (≥ ED); then `registerFirstMasterDevice(operatorOmni, account, …)` so `operatorMasterWallet[omni] == account`. | account already deployed + `operatorMasterWallet == account` |
| **4. Re-bootstrap actors** | Re-register each agent (`heima-agent-create.sh`) + re-grant scopes (`heima-scope-set.sh`, now `setScope` path) on the new contracts. | `isActive(deviceKeyHash)` / `getScope` already matches |
| **5. Code + doc updates** | `heima-scope-set.sh` `setScopeWithWebauthn`→`setScope`; `verify-heima-contracts.sh` (account-auth assertions); **arch.md §10/§12** (master = account; scope grant = `setScope`); the broker reads scope via env so no code change, just the new `SCOPE_CONTRACT_ADDRESS_*`. | files already at account-auth form (grep guard) |
| **6. Broker redeploy** | `bash scripts/setup-broker-host.sh --ref main` on the broker host → picks up new registry/scope addresses + the `sponsored_accept` module + (when landed) the `/v1/accept/*` routes. | broker already on the target ref + env |

## Idempotency strategy (a redeploy is NOT a first-deploy)

`heima-bring-up.sh`'s native check (`cast code` on the stored address) is **insufficient** here — the *old* contracts also have code, so it would skip. The cutover therefore gates on **two** signals, both written only after a successful Phase-1 redeploy:

1. A `CUTOVER_DONE_${PROFILE_UC}=1` marker in `operator-workstation.env` (via `env_set`).
2. A **capability probe** on the live scope address: `cast call $SCOPE "setScope(bytes32,bytes32,bytes32[],bool,uint128,uint128,uint128,uint32)" …` succeeds (account-auth ABI) where the pre-cutover `setScopeWithWebauthn` ABI would not. The probe is the ground truth; the marker is the fast path.

A re-run with both present logs `skip already-cut-over` and exits 0. `--force-cutover` clears the marker to redeploy intentionally.

## Scripts to implement (the deliverable this spec defines)

- `scripts/heima-cutover-account-auth.sh` — the Phase 0/1/2/5 orchestrator (idempotent, `ok`/`skip`/`fail` logging, `--force-cutover`, env-namespaced, no hardcoded values). Wired into `setup-heima.sh` behind `--cutover-account-auth` (destructive ⇒ opt-in, NOT in the plain flow — the one allowed exception to "plain = prod" because a redeploy resets state).
- `scripts/heima-deploy-master-account.sh` — Phase 3 (onboarding-as-account), idempotent, mirrors `harness/erc4337-master-e8.sh`'s `factory.createAccount` + EntryPoint-deposit steps.
- Phase 4 reuses the existing `heima-agent-create.sh` / `heima-scope-set.sh` (idempotent already).

## Env discipline (HARD — any new key)

`CUTOVER_DONE_*` and any new address key go into **BOTH** `scripts/operator-workstation.env` AND `scripts/operator-workstation.test.env` (with the `-test`/`_PASEO` variant), AND the CI env-materializer in `.github/workflows/harness-ci.yml`, AND each consuming harness script must `: "${NEW_KEY:=}"`-default it after sourcing. (Per the #201 env-discipline rule — a key in only one place breaks `--ci`.)

## Rollback

Restore `operator-workstation.env.pre-cutover.bak` over `operator-workstation.env` and redeploy the broker (`setup-broker-host.sh --ref main`). The old (pre-E3) contracts are still live at their original addresses with their original state intact, so reverting the env pointers fully restores the prior demo. (The new contracts are simply orphaned.)

## arch.md sync (source-of-truth rule)

When Phase 5 lands, update [`docs/arch.md`](../../arch.md) §10 (per-actor ceremonies — agent bind + scope grant now ride the account UserOp) and §12 (scope model — `setScope`, no in-contract K11), and move the §3.1 cutover note in `erc4337-master-account.md` from ⏭️ to ✅ with the new addresses recorded in [`deployed-contracts.md`](../../spec/deployed-contracts.md).
