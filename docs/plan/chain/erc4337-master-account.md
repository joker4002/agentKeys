# ERC-4337 P-256 smart-account master (plan to resolve #164)

**Status:** plan (pre-code). Authored 2026-06-02 after a hard-confirmation deploy spike on **Heima mainnet**.
**Decision:** **Solution A — account-only / full-intent** (locked). The master becomes an ERC-4337 smart account whose `validateUserOp` verifies a **P-256 (K11/passkey) signature** over the `userOpHash`; a **bundler** broadcasts UserOps and an optional **paymaster** sponsors gas. `SidecarRegistry.master` becomes the smart-account address.
**Supersedes:** the §11 fork-A-vs-B framing in [`../web-flow/wire-real-paths.md`](../web-flow/wire-real-paths.md) and the EOA `msg.sender`-bound model.
**Unblocks:** the chain-write half (X4) of [#163](https://github.com/litentry/agentKeys/issues/163).
**Source of truth:** [`docs/arch.md`](../../arch.md) §6 (key inventory), §9 (master bootstrap), §10 (per-actor ceremonies). Arch.md is updated as the E-phases land (E3/E7), not before.

---

## 0. Why (carried from #164, with the falsified bits corrected)

ERC-4337 with a P-256 account is the only model that simultaneously:
- **Removes the software-secp256k1 root** — every client signs UserOps with the **SE-sealed K11/P-256 passkey alone**; no exportable secp256k1 key on any device. (Resolves the security-review HIGH #4.)
- **Key-free + relayer in one** — a bundler broadcasts and a paymaster can pay gas → no HEI on device, **no custodial relayer**.
- **Stable master + multi-device + recovery** — the account address is the durable master across device swaps; multiple authorized passkeys + quorum/social recovery live in the account. (Resolves HIGH #5: the single global `operatorMasterWallet`.)
- **Web + mobile symmetric** — each registers its own passkey as an account signer and signs UserOps directly; the browser→host delegate-broadcast hop (and its confused-deputy risk, HIGH #6) **dissolves**.
- **Reuses on-chain P-256** — the account staticcalls the already-deployed `P256Verifier`.

### The reframe that makes Solution A correct (not just convenient)

The passkey signs the **`userOpHash`**, which the EntryPoint computes over `sender + nonce + callData + accountGasLimits + preVerificationGas + gasFees + paymasterAndData`, then bound to `entryPoint + chainId`. Because `callData` **is** the full function intent (target omni, scope bits, device hash, …), **the P-256 signature over `userOpHash` is a provably-complete full-intent commitment** — it cannot omit a field. This:
- **Resolves the HIGH "full-intent binding" finding structurally** (the security review found two omitted-field bugs in the hand-rolled `abi.encode` challenges; Solution A deletes that code class).
- Lets us **retire** the bespoke per-op `keccak256` challenge construction, `operatorNonce`, `scopeNonce`, and `signCount` in `SidecarRegistry`/`AgentKeysScope`, replacing them with **`msg.sender == masterAccount` + the EntryPoint 2D nonce**.

Defense-in-depth note: for **intent binding**, account-only is strictly ≥ keeping the in-contract K11 verify, since the redundant layer would only be as strong as the weakest hand-rolled challenge. The one uncorrelated benefit of an in-contract re-check (catching an account-*logic* bug) is **not** adopted globally; recovery (E5) stays an independent guardian-authorized path for a different reason (a lost primary passkey must not be required to recover).

---

## 1. VERIFIED feasibility (Heima mainnet spike, 2026-06-02)

Deployed + exercised the real flow end-to-end on Heima mainnet (chainId **212013**) from the harness deploy wallet. **Nothing below is theoretical.**

| Result | Evidence |
|---|---|
| Canonical **eth-infinitism EntryPoint v0.7** compiles for Cancun (solc 0.8.23, 11.8KB runtime) and deploys + runs | live `0x6672E1b315332167aBA12E0B1d3532a7e9B1ADE9` |
| A minimal **P256Account** `validateUserOp` staticcalls the **live** P256Verifier and the UserOp executes | UserOp tx `0x17939004d3ba7a8a5451fa69b815d581486e95ee3601c4e6ee557eb5b2a7d88a`, status 1, `Counter.number()==1` |
| Works via **direct `handleOps`** (no bundler) — bundler is just automation over this | the spike used a raw `handleOps` call |
| Live P256Verifier verifies a valid vector / rejects a tampered one | `0xda5b772f9d6c09abe80414eea908612df9b54749` → `0x..01` / `0x..00` |
| Full passkey UserOp gas | **730,242** (~0.018 HEI @ 25 gwei) |

Spike artifacts (mainnet): P256Account `0x8897ee99434F6c9D8711565EE59c61a03DA0Cc98` (minimal, raw-P256 — **not** the production account), Counter `0x2861D0194d9B263D42eBd956f3aD336185b27C4E` (throwaway). The EntryPoint is the exact audited v0.7 bytecode; E1 decides adopt-this vs redeploy-at-a-deterministic-address.

---

## 2. Heima-specific constraints (all verified)

1. **EVM = Cancun, not London** (#168). The account + EntryPoint may use ≤Cancun opcodes at runtime. The `evm_version="london"` pin is only a `forge script` header-validation workaround — **deploy EntryPoint/factory via `forge create`/raw bytecode** (the spike did; it does not trip the `prevrandao` check) so we ship the exact audited bytecode.
2. **EntryPoint v0.7** (not v0.8). v0.8's headline (EIP-7702) requires Prague *and* re-introduces a secp256k1 EOA root — counter to this design. v0.8's EIP-712 `userOpHash` is for EOA/hardware-wallet signers, not WebAuthn. See the two tracked issues at the end.
3. **No canonical EntryPoint / no deterministic CREATE2 deployer on Heima** → self-deploy both. The account factory carries its own CREATE2 (an opcode — no Arachnid proxy needed) for deterministic account addresses.
4. **No `debug` namespace** on Heima's Frontier RPC (`debug_traceCall`/`debug_traceTransaction` → method-not-found). Standard bundlers need this for ERC-7562 validation → run a **private, self-hosted bundler in `--unsafe` mode**, fed only by authenticated clients via the broker (not a public alt-mempool). Acceptable because the broker is already the gatekeeper.
5. **P-256 verify ≈ 707k gas** with our current `P256Verifier` (measured on mainnet — the repo header's "~700k" is right; #163's "~421k" was Daimo's verifier). Options: accept it (trivial at 25 gwei), **swap to the Daimo verifier (~421k, ~40% cut)**, or push for RIP-7212 (~3.4k, runtime upgrade — see issues).
6. **ExistentialDeposit ≈ 0.1 HEI** (verified behaviorally; confirm the exact `Balances::ExistentialDeposit`). EVM value transfers must keep every account ≥ ED:
   - `depositTo` below ED to a zero-balance EntryPoint fails with `OutOfFund`; ≥ ED succeeds.
   - A new account loses ~0.1 HEI one-time on first funding.
   - **Funding rule:** pre-deposit the account's EntryPoint balance generously so `missingAccountFunds == 0` (no per-op value transfer in `validateUserOp` — this is what made the spike UserOp pass); keep EntryPoint + paymaster ≥ ED; budget ~0.1 HEI per new master account.

---

## 3. Implementation order (E0–E8)

Each phase is independently shippable, idempotent where it mutates chain state (per the repo's idempotent-remote-setup rule), and ends green on a check.

| # | Phase | What | Gate |
|---|---|---|---|
| **E0** | Threat-model delta | Write the `userOpHash`-is-full-intent argument; ED-aware funding security; bundler trust model (unsafe-mode private mempool); what Solution A deletes and why it's safe. | review sign-off |
| **E1** | Heima 4337 infra | Deploy **EntryPoint v0.7** (`forge create`/raw bytecode) — adopt the spike's live one or redeploy deterministic; deploy **account factory** (CREATE2, salt = passkey pubkey). Confirm exact ED constant. Record in [`deployed-contracts.md`](../../spec/deployed-contracts.md) + `operator-workstation.env`; extend `verify-heima-contracts.sh`. | verify script green |
| **E2** | Production `P256Account` | `validateUserOp` staticcalls P256Verifier over `userOpHash`; **WebAuthn `clientDataJSON` wrapping** (spike used raw P256); **multi-passkey signer set**; EntryPoint+verifier behind a config interface (forward-compat hedge for a future EntryPoint/verifier swap); ED-aware `_payPrefund`. Decide **immutable vs upgradeable-proxy** (security tradeoff: upgrade authority = new attack surface). | forge tests (valid / tampered / wrong-signer / replay) |
| **E3** | Registry thinning | `SidecarRegistry`/`AgentKeysScope` master writes → `msg.sender == masterAccount`; `operatorMasterWallet[omni] = account`. **Retire** the per-op K11 challenge + `operatorNonce`/`scopeNonce`/`signCount`. **Keep #166's bootstrap self-attestation.** Update arch.md §6/§10. | forge tests; negative replay/substitution |
| **E4** | Agent bind/revoke via account | route `registerAgentDevice`/`revokeAgentDevice` through the account so they inherit passkey gating (closes the HIGH "agent-bind has no biometric" finding) with **no new challenge code**. | negative: non-account sender → revert |
| **E5** | Recovery module | multi-passkey enroll + M-of-N social recovery in the account; **supersede** registry `revokeMasterDevice`/`recoveryThreshold` quorum. Recovery is an **independent guardian-authorized path** (must not require the lost primary passkey). | add/revoke-passkey + quorum tests |
| **E6** | Bundler + paymaster | self-host **unsafe-mode bundler** (rundler or eth-infinitism reference) on the broker host, fed by authenticated clients; optional **ED-aware VerifyingPaymaster** funded from the deploy wallet (key-free + gasless). | a no-secp256k1 device lands a UserOp through the bundler |
| **E7** | Bootstrap migration | first-master onboarding as one `initCode + registerFirstMasterDevice` UserOp; the deterministic account address (CREATE2 from pubkey) is known pre-deploy, so #166's self-attestation binds it; one-time ~0.1 HEI ED funding; document migration of any existing `operatorMasterWallet` EOAs. | front-run negative test under 4337 |
| **E8** | Harness acceptance | extend a demo: a phone with **no secp256k1 key** completes onboarding + a scope grant by passkey-signing UserOps; the bundler lands the txs; `isServiceInScope(...)==true`; a second passkey is added; a lost device is revoked. | green/red per step |

---

## 4. How #164 interacts with the existing invariants

- **#166 survives** (the CRITICAL bootstrap item is already satisfied). The self-attestation binds `msg.sender`, which becomes the account address; under 4337 the front-run property *strengthens* (account is CREATE2-bound to the passkey pubkey, so an attacker can deploy the account but cannot make it call the registry without the operator's passkey). E7 revisits whether the explicit self-attestation is still needed once the account model lands, or is subsumed.
- **Four-layer isolation (issue #90) is unchanged** — #164 changes *how master writes are authorized*, not the cap-mint / worker chain-verify / IAM PrincipalTag / per-data-class bucket layers. No demo step in `harness/v2-stage3-demo.sh` regresses; E8 adds the passkey-UserOp path on top.
- **The cap layer is untouched** — agents still use K10 + broker caps off-chain; the passkey/UserOp path is master-plane only, low-frequency.

---

## 5. UX cost (per the gesture analysis)

The per-operation Touch ID is a property of "passkey = the only key," not of Solution A. Reads and all agent-runtime traffic require **no** biometric. Master writes cost one gesture each; `executeBatch` keeps bind+grant at **one** gesture (arch §10.2's "one operator gesture" preserved) while now biometric-gating bind too. Recovery is M gestures by nature. A future session-key module can batch a burst of admin actions under one gesture.

---

## 6. Risks & open questions

- **Bundler in unsafe mode** loses ERC-7562 trace validation. Mitigation: private mempool, broker-authenticated submission only, single trusted bundler. Revisit if Frontier ships `debug_traceCall`.
- **ED funding discipline** must be encoded in the paymaster + factory + onboarding, or value moves fail with `OutOfFund`. Confirm the exact ED constant in E1.
- **Account upgradeability** (E2) is a genuine security fork — immutable (EntryPoint swap = new address = re-register) vs upgradeable-proxy (flexible, but upgrade authority is an attack surface). Decide with the threat model in E0.
- **Recovery without the account** (E5) — the guardian path must not depend on the account's own `validateUserOp`.
- **P-256 gas** ~707k is fine now; the Daimo swap (~421k) is a cheap, zero-chain-work option if validation volume grows.

---

## 7. Relationships

- **Plan of record amended:** [`../web-flow/wire-real-paths.md`](../web-flow/wire-real-paths.md) §11/§12 — the Cancun + verified-feasibility revisions land via the patch accompanying this plan.
- **Blocks:** [#163](https://github.com/litentry/agentKeys/issues/163) X4.
- **Resolves:** [#164](https://github.com/litentry/agentKeys/issues/164).
- **Builds on:** [#166](https://github.com/litentry/agentKeys/pull/166) (bootstrap self-attestation).
- **Chain-upgrade follow-up:** [#170](https://github.com/litentry/agentKeys/issues/170) — *evaluate* RIP-7212 (P-256 precompile, ~707k→~3.4k gas, Pectra-independent). EntryPoint v0.8 / EIP-7702 is **not** pursued (requires Prague and re-adds a secp256k1 root — rationale in §2; the v0.8-defer tracker #169 was closed as non-actionable).
- **Contracts:** `crates/agentkeys-chain/src/{SidecarRegistry,AgentKeysScope,K11Verifier,P256Verifier}.sol`.
