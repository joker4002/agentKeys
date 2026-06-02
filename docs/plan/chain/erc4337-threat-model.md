# ERC-4337 P-256 master — threat-model delta (#164 E0)

**Status:** security analysis (pre-code-review). Companion to [`erc4337-master-account.md`](erc4337-master-account.md). Covers what changes in the trust model when the master moves from an EOA `msg.sender` to a **Solution A** ERC-4337 P-256 account, what the migration **deletes** and why that is safe, and the review checklist that gates the E1 mainnet deploy + E3 registry rewrite.

---

## 1. The load-bearing argument: `userOpHash` is the full-intent commitment

Under ERC-4337 v0.7 the EntryPoint computes `userOpHash = keccak256(abi.encode(hash(packedUserOpWithoutSig), entryPoint, chainId))`, where the inner hash commits `sender, nonce, initCode, callData, accountGasLimits, preVerificationGas, gasFees, paymasterAndData`. The passkey signs a WebAuthn assertion whose **challenge is the `userOpHash`** (verified on-chain by `K11Verifier` inside `P256Account.validateUserOp`).

Therefore one passkey signature authorizes **exactly** this call (`callData` = target + selector + args), on **this** account (`sender`), at **this** nonce, **this** chain, **this** EntryPoint. It is impossible to omit a state-changing field — the signature covers the whole operation by construction.

**Consequence:** this is strictly ≥ the legacy hand-rolled `keccak256(abi.encode(op, operator, ...))` challenges in `SidecarRegistry`/`AgentKeysScope`, whose security floor was the weakest hand-written challenge (the codex review found two omitted-field bugs). Solution A removes that whole bug class.

---

## 2. What the migration deletes — and why each deletion is safe

| Deleted (legacy) | Replaced by | Why safe |
|---|---|---|
| Per-op `keccak256` K11 challenge construction (add-master, scope, revoke) | passkey sig over `userOpHash` | `userOpHash` commits the full calldata — can't omit a field |
| `operatorNonce` / `scopeNonce` | EntryPoint **2D nonce** (`getNonce(sender,key)`) | battle-tested across the 4337 ecosystem; consumed atomically in `handleOps` |
| WebAuthn `signCount` anti-clone | EntryPoint nonce | signCount was inconsistent (registry updated it, scope didn't — codex MEDIUM); nonce is authoritative. (Synced passkeys make signCount best-effort anyway.) |
| `msg.sender == operatorMasterWallet(EOA)` | `msg.sender == masterAccount` (the smart account) | the account only acts after a passkey sig in `validateUserOp` |

**Not deleted:** #166's bootstrap self-attestation (it is the bootstrap proof; see §6).

---

## 3. P256Account-specific threats

| Threat | Mitigation (status) |
|---|---|
| **Cross-account / cross-chain replay** of a passkey sig | `userOpHash` commits `sender + chainId + entryPoint` → a sig for account A / chain X never validates elsewhere. ✓ inherent |
| **Same-op replay** | EntryPoint nonce consumed on first inclusion. ✓ inherent |
| **Signature malleability** (P-256 `(r,s)` vs `(r,n-s)`) | Not exploitable for replay (nonce consumed regardless of which form lands). Off-chain signer normalizes low-s. **Review:** confirm `P256Verifier` accepts both forms but the nonce closes replay. |
| **Caller spoofing `validateUserOp`** | `require(msg.sender == entryPoint)`. ✓ implemented |
| **Unauthorized `execute` / signer mgmt** | `_requireEntryPointOrSelf()` on `execute`/`executeBatch`/`addSigner`/`removeSigner`. ✓ implemented + tested |
| **Signer-set lockout** (remove last key) | `removeSigner` reverts `LastSigner` when `activeSignerCount <= 1`. ✓ implemented + tested |
| **credId collision / unknown signer** | lookup by `credIdHash`; inactive → `SIG_VALIDATION_FAILED`. ✓ tested |
| **ERC-7562 validation-rule violations** (banned opcodes / disallowed storage in `validateUserOp`) | `validateUserOp` only reads own storage (`signers`), staticcalls the verifier (pure math), and pays prefund. No `TIMESTAMP`/`NUMBER`/external-storage reads. **Review:** re-check against ERC-7562 even though we run unsafe-mode (portability + future safe-mode). |
| **Prefund griefing** | `missingAccountFunds` forwarded best-effort; EntryPoint reverts the op if unpaid. We pre-deposit so it is 0 (§5). ✓ |

---

## 4. Trust model changes

- **Bundler (new trusted component).** Heima's Frontier RPC has no `debug_traceCall`, so the bundler runs **`--unsafe`** (no ERC-7562 trace validation). We mitigate by running a **single, private, broker-authenticated** bundler — not a public alt-mempool. A malicious/buggy bundler can censor or reorder our UserOps but **cannot forge one** (no passkey) and cannot alter effects (`userOpHash` binds calldata). Anyone can also submit `handleOps` directly (the spike did), so bundler downtime is not hard censorship.
- **EntryPoint (new trusted singleton).** Standard audited v0.7 bytecode; the account guards `msg.sender == entryPoint`. A compromised/incorrect EntryPoint is catastrophic — hence pin the exact audited bytecode and record its address (E1).
- **Paymaster (optional).** If used, it sponsors gas; must be ED-aware (§5) and rate-limited to its own deposit. Out of scope until E6.
- **Concentration of trust in `validateUserOp`.** Solution A's one critical path. Mitigated by: small surface, reuse of the already-audited `K11Verifier`/`P256Verifier`, full unit coverage, and an **independent guardian recovery path** (E5) that does not depend on `validateUserOp`.

---

## 5. ExistentialDeposit, funding model, and Sybil resistance

Heima rejects EVM value transfers that would leave an account below the ExistentialDeposit (~0.1 HEI — verified: a 0.05 HEI `depositTo` to a zero-balance EntryPoint failed `OutOfFund`; ≥ ED succeeded; topping an existing account showed the ~0.1 is a one-time creation cost, not a per-tx tax).

### Do we fund every new account? No.

- **A master account never needs its own ED-balance.** ERC-4337 gas is paid from the account's *EntryPoint deposit* — an entry in the EntryPoint's `deposits[account]` mapping (funded via `depositTo(account)`). That HEI lands in the **EntryPoint's** balance, not the account's. The master account exists as a **code-only contract with 0 balance** (verified in the spike). ED only bites an account that *holds native value*; the master never needs to. A new master costs **deploy-gas, not ED**.
- **ED is a one-time infra cost, not per-master.** Only the *first* `depositTo` to a fresh EntryPoint must be ≥ ED. After that, per-account deposits are any size and don't re-trigger ED. Same for the paymaster account (funded once).

→ **Funding model:** fund the EntryPoint + paymaster once (≥ ED); a **paymaster** then sponsors every master's gas → **zero per-account funding, key-free + gasless.** (Without a paymaster: a small per-master gas deposit — still no ED.)

### Sybil resistance

The attack is spamming sponsored UserOps / account creations to drain the paymaster. Defense in depth:

1. **Sponsorship is gated by the broker's existing operator auth.** The VerifyingPaymaster only sponsors a UserOp the **broker co-signs**, and the broker co-signs only for an **authenticated operator** (valid J1 from email + SIWE + OIDC onboarding). A Sybil with no operator session gets no sponsorship → must self-fund → no drain. Reuses the auth gate we already have; sponsorship is not open to the world.
2. **Becoming a *recognized* master requires authenticated bootstrap (#166/E7).** Anyone can permissionlessly deploy a junk `P256Account` at *their own* gas cost, but it is **inert** — not a registered master, no omni, no scope, no sponsorship. Sybil accounts are harmless noise, not authority.
3. **Per-operator paymaster budgets + rate limits** (broker-enforced) bound abuse by any single (even compromised) operator.

**Net: Sybil resistance is the broker's operator-auth gate on sponsorship — ED is a one-time liveness cost, not the defense.**

- **Funding discipline (E1/E6):** pre-deposit generously so `missingAccountFunds == 0` (no per-op transfer in validation — what made the spike UserOp pass); keep EntryPoint + paymaster ≥ ED. Read the exact `Balances::ExistentialDeposit` and encode it as the funding floor.

---

## 6. Bootstrap (E7) + #166 survival

The master account address is **CREATE2-deterministic** in the initial passkey pubkey + salt. So:
- The operator knows the address pre-deploy and #166's self-attestation (which commits `msg.sender`) binds it.
- An attacker can permissionlessly deploy the account via the factory, but **cannot make it call `registerFirstMasterDevice`** (no passkey → `validateUserOp` fails). The front-run is defeated more robustly than under the EOA model.
- E7 decides whether the explicit #166 self-attestation is still needed once the account+CREATE2 binding exists, or is subsumed.

---

## 7. Recovery (E5) must not depend on the primary passkey

A lost primary device means no `validateUserOp` from that key. Recovery (M-of-N guardian passkeys) must therefore be authorizable **independently of the account's own primary signer** — a guardian-quorum path, not a self-UserOp. This is the one place an in-contract re-check is retained (the targeted defense-in-depth from the plan's auth-model decision).

---

## 8. Unchanged invariants

- **Four-layer per-actor/per-data-class isolation (#90)** — #164 changes only *how master writes are authorized*, not cap-mint / worker chain-verify / IAM PrincipalTag / per-data-class bucket separation. No `harness/v2-stage3-demo.sh` step regresses.
- **Agents** keep K10 + broker caps off-chain; the passkey/UserOp path is master-plane only.

---

## 9. Review checklist (gates E1 mainnet deploy + E3 registry rewrite)

- [ ] Codex + human review of `P256Account` / `P256AccountFactory` (this is security-critical; the spike's mainnet account was a throwaway, these are production).
- [ ] Confirm `P256Verifier` malleability behavior + that the nonce closes replay regardless.
- [ ] ERC-7562 opcode/storage audit of `validateUserOp` (even under unsafe-mode).
- [ ] Exact Heima ED constant + funding-floor encoding.
- [ ] E3: prove the registry rewrite keeps the #90 negative tests green + adds account-only positive/negative tests.
- [ ] E7: front-run negative test under the account model.
- [ ] Only deploy production EntryPoint + factory to mainnet **after** the above.

## 10. Adversarial review findings (codex, 2026-06-02) + dispositions

Adversarial pass over `P256Account` / `P256AccountFactory` / `VerifyingPaymaster` / the thinned `AgentKeysScope`. No ERC-7562 opcode bypass found.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | HIGH | `VerifyingPaymaster.getHash` omitted the paymaster gas limits (`paymasterAndData[20:52]`) → a valid broker sig could be reused with inflated limits (drain/grief). | **Fixed** — `getHash` now binds `[20:52]`; test `test_RejectsTamperedGasLimits`. |
| 2 | HIGH | Thinned `AgentKeysScope` (`msg.sender == operatorMasterWallet`, in-contract K11 retired) + an **un-migrated EOA master** ⇒ scope writes with no biometric. | **Deployment-ordering invariant** — the contract can't tell an EOA from a 4337 account, so there is no clean in-contract guard. The thinned scope MUST be deployed **only together with the registry cutover** that stores account-masters (so `msg.sender == account`, which is passkey-gated). Warned in `AgentKeysScope.sol` @dev + the E3/cutover notes. **Never deploy E3 pre-cutover.** |
| 3 | MED | Guardian quorum bypass — one physical key registered under two credIds satisfies an M≥2 quorum. | **Fixed** — `recover()` dedups by `(pubX,pubY)`, not just credIdHash; test `test_Recover_RejectsDuplicateGuardianPubkey`. |
| 4 | MED | P-256 malleability — `P256Verifier` accepts high-s, so `(r, n-s)` also verifies. | **Mitigated, not replay-exploitable**: the EntryPoint 2D nonce (`validateUserOp`) and `recoveryNonce` (`recover`) consume the op regardless of sig form. Follow-up: enforce low-s in `P256Verifier` — deferred because it is the **live, shared** verifier (also used by `SidecarRegistry`), so it needs its own change + redeploy. |
| 5 | LOW | `recover()` can install an unusable signer (caller supplies a bad new pubkey). | **Accepted** — operator/relayer error, not an attacker path; guardians can recover again. An on-chain check cannot distinguish a valid-looking-but-wrong P-256 point. |
