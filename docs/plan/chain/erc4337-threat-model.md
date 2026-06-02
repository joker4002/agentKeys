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

## 5. ExistentialDeposit (~0.1 HEI) as a security constraint

Heima rejects EVM value transfers that would leave an account below ED (verified: a 0.05 HEI `depositTo` to a zero-balance EntryPoint failed `OutOfFund`; ≥ ED succeeded). Security implications:

- **Funding discipline:** pre-deposit each account's EntryPoint balance generously so `missingAccountFunds == 0` (no per-op transfer in validation — this is what made the spike UserOp pass). Keep EntryPoint + paymaster ≥ ED at all times.
- **Griefing surface:** an attacker cannot drain via dust, but a poorly-funded account/paymaster self-DoSes (txs fail `OutOfFund`). The factory + onboarding must budget the one-time ~0.1 HEI per new account.
- **Action (E1):** read the exact `Balances::ExistentialDeposit` and encode it as the minimum deposit/funding floor.

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
