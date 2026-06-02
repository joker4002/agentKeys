# Adversarial security review — wire-real-paths.md §11 gating decision

**Reviewer:** Codex (adversarial, read-only) · **Date:** 2026-06-02 · **Scope:** PR #162 — `wire-real-paths.md` §0.5/§11/§12, `data-model.md` phone-first amendment, `arch.md` §22c.3, verified against `crates/agentkeys-chain/src/{SidecarRegistry,AgentKeysScope,K11Verifier}.sol`.

**Verdict:** Recommendation **(A)** (keep `msg.sender`-bound) is *safer than* (B) because the current contracts are **not** assertion-only-safe — but **(A) is NOT sound as written.** The core `msg.sender`-bound claim holds for *post-bootstrap* writes, but the plan obscures a software secp256k1 root key, leaves first-master bootstrap front-runnable, leaves agent bind/revoke K11-free, and lacks a safe browser→host delegation protocol. (A) cannot ship until the items below are fixed.

> **✅ IMPLEMENTED (update 2026-06-02) — every finding below is now addressed; the action-items list is historical (kept for the audit trail).** The ERC-4337 P-256 smart-account master **landed in #171** (Solution A; EntryPoint v0.7 + `P256Account` + factory + `VerifyingPaymaster` live on Heima mainnet — canonical plan [`../chain/erc4337-master-account.md`](../chain/erc4337-master-account.md)). Resolution map: software-secp256k1 root [HIGH #4] → passkey-only UserOps, no secp key on any client; multi-device/recovery [HIGH #5] → account quorum recovery (E5); browser→host delegation [HIGH #6] → each host signs its own UserOp (no hop; the residual is the intent-display-before-Touch-ID obligation); **full-intent binding** [HIGH] → *structural* (the passkey signs `userOpHash`, which commits the whole UserOp callData — the hand-rolled per-op challenges are retired, E3); **CRITICAL** first-master front-run → fixed in **#166**. Heima is **Cancun** (#168), not London; P-256 verify is pure-Solidity (no RIP-7212, no chain change).

## Required changes before fork (A) ships (action items)

1. **[CRITICAL] Authenticate first-master bootstrap.** Add an on-chain authorization proof to `registerFirstMasterDevice` (bind operatorOmni, actorOmni, deviceKeyHash, K11 cred/rp/pubkey, roles, chainId, contract, nonce, expiry, expected sender). Today it's first-call-wins → front-runnable lockout.
2. **[HIGH] K11-gate agent bind/revoke** (or verify a broker-signed pairing redemption on chain). `registerAgentDevice` / `revokeAgentDevice` are `msg.sender`-only today → a compromised master EVM key binds rogue agents / revokes with no biometric.
3. **[HIGH] Full-intent K11 binding on add-master.** The add-master challenge omits `newActorOmni`, K11 cred/rp/pubkey, attestation → an assertion can be reused with substituted params. Challenges must commit every state-changing field + contract + chainId + nonce + expiry.
4. **[HIGH] Model the phone secp256k1 sender key as a first-class root key** in the threat model (it is software/Keychain, NOT SE-sealed). If (A) stays, require K11 on *every* master mutation; stronger: move to an ERC-4337/P-256 account so passkey hardware — not an exportable secp key — is the root.
5. **[HIGH] Define a precise multi-device sender model + recovery.** There is one global `operatorMasterWallet`; "phone + desktop each have their own K10/K11" doesn't reconcile with that. Either accept a shared EVM sender (documented blast radius) or redesign to per-device senders / smart account / quorum.
6. **[HIGH] Specify the browser→host delegation protocol.** The key-holding host must independently decode calldata, recompute the K11 challenge from the current nonce, render a NATIVE confirmation, then sign. The delegation envelope must bind chainId, contract, calldata hash, operator, nonce, expiry, origin, assertionId. Otherwise it's a confused deputy.
7. **[MEDIUM] Centralize/!consume WebAuthn signCount for scope.** `AgentKeysScope` verifies K11 but never updates `lastSignCount` (registry does) → inconsistent clone detection. Centralize K11 consumption or document signCount as best-effort (synced passkeys).
8. **[MEDIUM] Fork (B) is not safe now.** First-master, agent bind, agent revoke have *no* K11 challenge at all; before (B) can be reconsidered, every master mutation needs a typed full-intent K11 digest + nonce + expiry + contract/chain binding + replay/griefing analysis.

---

## Findings (verbatim, codex)

### CRITICAL — First-master bootstrap is unauthenticated first-call-wins
**Attack:** An attacker watches `registerFirstMasterDevice(...)`, copies `operatorOmni` from calldata, front-runs with their own sender/device. If they land first, `operatorMasterWallet[operatorOmni]` becomes the attacker's address and the real operator is locked out.
**Evidence:** `registerFirstMasterDevice` is external with no K11 / authorization proof (`SidecarRegistry.sol:100-114`); only "not already registered" (`:115-121`) then `operatorMasterWallet[operatorOmni] = msg.sender` (`:123`). `arch.md:1272-1278` expected a first-device `authorization_proof` the contract does not verify.
**Mitigation:** On-chain first-master authorization proof binding the full identity tuple + chainId + contract + nonce + expiry + expected sender. Private tx / commit-reveal is temporary hardening, not the auth model.

### HIGH — `registerAgentDevice` is `msg.sender`-only (no K11, no pairing proof)
**Attack:** A compromised operator EVM sender key (or delegated key host) binds rogue agent devices and revokes agents with no biometric. Cannot grant scope without K11, but can poison the registry and exploit any path treating registry binding as sufficient.
**Evidence:** `registerAgentDevice` checks only `msg.sender == master` (`SidecarRegistry.sol:214-216`), writes an active agent (`:218-235`); `linkCodeRedemption`/`agentPopSig` are no-ops (`:236-237`); `revokeAgentDevice` is `msg.sender`-only (`:240-251`). Contradicts `arch.md:522-540` pairing + the "leaked master K10 cannot mint agent omnis" claim (`arch.md:608-612`).
**Mitigation:** K11-gate agent bind/revoke, or verify a broker-signed pairing redemption on chain (bind pairId, operator, actor, deviceHash, popSig, requested-scope digest, chainId, contract, nonce, expiry).

### HIGH — Add-master K11 challenge does not bind full intent
**Attack:** A malicious browser/relayer/key host reuses an add-master K11 assertion while substituting `newActorOmni`, `newK11CredId`, `newK11RpIdHash`, `newK11PubX/Y`, or attestation → registers a master whose future K11 verifier key is not what the operator approved.
**Evidence:** Challenge includes only op, operator, `newDeviceKeyHash`, `newRoles`, chainId, nonce (`SidecarRegistry.sol:167-176`); omitted fields persisted at `:181-193`. `K11Verifier` only checks challenge-substring + P-256 sig (`K11Verifier.sol:121-136`). The plan's `intent.fields`/`intent_commitment` is not enforced by this contract (`data-model.md:110-128`).
**Mitigation:** K11 challenges must include every state-changing parameter + contract + chainId + nonce + expiry.

### HIGH — Fork A makes a software secp256k1 key the effective root
**Attack:** Phone malware, jailbreak/root, key backup/migration, or biometric-ACL bypass can misuse or extract the phone-held secp256k1 sender key. K11 still gates scope/master-device ops, but the sender key alone controls bootstrap, agent bind/revoke, and tx submission for any K11-gated op once the user is tricked into approving an assertion.
**Evidence:** PR #162 admits Keychain/biometric-ACL custody, not SE-sealed (`wire-real-paths.md:274-283`; `arch.md:1982`). `arch.md:121-128,180-192` still sells K11 as non-exfiltratable hardware. Actual authority is `operatorMasterWallet`, set from `msg.sender` (`SidecarRegistry.sol:66,123`).
**Mitigation:** Add this EVM sender key as a first-class threat-model key. If (A) stays, require K11 for *every* master mutation. Stronger: ERC-4337/P-256 account or quorum so passkey hardware is the root.

### HIGH — Multi-device recovery is broken (single `operatorMasterWallet`)
**Attack:** Plan says phone + desktop have separate K10/K11, but the contract has one global `operatorMasterWallet`. A surviving phone (K10_B/K11_B) cannot revoke a lost desktop unless it can also sign as the original `operatorMasterWallet`. If every master copies that key, compromise of any master exposes the global sender.
**Evidence:** Single `operatorMasterWallet` (`SidecarRegistry.sol:66`), set at first bootstrap (`:123`); add-master writes a device only, not an authorized sender (`:181-194`); writes still require `msg.sender == master` (`:163-165,214-216,247-248,273-275,326-328`). Recovery text assumes phone K10_B/K11_B can submit (`arch.md:623-640`).
**Mitigation:** Choose explicitly: shared EVM sender (accepted blast radius) vs per-device senders / smart account / quorum authorization.

### HIGH — Browser/WASM delegation lacks trusted intent binding
**Attack:** A compromised tab displays benign text, builds a malicious K11 challenge, gets a generic OS biometric prompt, then asks the key host to sign/broadcast. For scope, calldata is bound by the challenge; the weak point is the human-intent display + host delegation. For agent bind, no K11 is required at all.
**Evidence:** Browser produces the assertion, daemon injects it (`wire-real-paths.md:143-151`); WASM delegates chain writes (`:287-303`); WebAuthn cannot display app text, intent is app-rendered (`arch.md:466-468`); `setScopeWithWebauthn` binds fields (`AgentKeysScope.sol:111-127`) but has no `intent_commitment` param (`:96-105`).
**Mitigation:** Key host must independently decode calldata, recompute the challenge from the current nonce, render native confirmation, then sign. Envelope binds chainId, contract, calldata hash, operator, nonce, expiry, origin, assertionId.

### MEDIUM — Fork B not safe without full contract redesign
**Evidence:** Scope set/revoke are mostly full-intent (`AgentKeysScope.sol:111-127,166-176`); add-master omits fields (`SidecarRegistry.sol:167-193`); first-master + agent bind/revoke have no K11 challenge (`:100-123,204-251`). Fork B at `wire-real-paths.md:279-283`.
**Mitigation:** Every master mutation needs typed full-intent K11 digest + nonce + expiry + contract/chain binding + replay tests + griefing analysis before B is reconsidered.

### MEDIUM — `AgentKeysScope` does not update WebAuthn signCount
**Evidence:** Registry reads/rejects/updates signCount (`SidecarRegistry.sol:425-443`); scope verifies K11 but never updates it (`AgentKeysScope.sol:211-237`); scope nonce increments after success (`:127-128,175-176`). Not direct replay (scopeNonce stops old assertions), but clone-detection is inconsistent.
**Mitigation:** Centralize K11 consumption in the registry or expose a consuming verifier for scope; else document signCount as best-effort.

## Direct answers to the six review questions
1. §11 is correct that *post-bootstrap* writes are `msg.sender`-bound, but **incomplete**: first bootstrap is front-runnable, and agent bind/revoke are K11-free.
2. **Yes** — (A) introduces a software secp256k1 root weaker than the K11 hardware promise; model it explicitly.
3. Browser/WASM delegation is confused-deputy-prone; a native host confirmation that re-derives the challenge + renders calldata is required (not specified today).
4. K11 does **not** consistently bind full intent (scope mostly complete; add-master incomplete; first-master + agent bind/revoke have none). Fork B unsafe until all paths are covered.
5. Phone-first weakens the §9/§10 chain unless agent bind, sender-key sharing, and recovery are redesigned/documented; a K11→software-key downgrade exists for bootstrap + agent binding.
6. Also unaddressed: phone session-JWT theft (`arch.md:186-188,497-500`); push notifications must be hints only, never authoritative; **a non-custodial relayer is impossible under fork (A) without meta-tx / ERC-4337 contract changes** because `msg.sender` must equal `operatorMasterWallet` (confirms the relayer analysis: EIP-2771 sponsors gas but still needs the secp key; only ERC-4337/P-256 or assertion-only removes the key).
