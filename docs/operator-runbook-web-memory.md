# Operator runbook — web memory plant (issue #196)

**This is the single doc to follow to make the web memory demo work end-to-end.**
It drives the idempotent harness `harness/web-memory-bootstrap.sh`, which does
every operator-runnable requirement (build, contracts, fund, register, broker
proof) and then prints the one manual browser step. Goal: `login → master device
auto-registers on passkey-finish → the memory plant button writes to S3`, with
**no manual CLI bootstrap**.

> **What #196 changed (1 paragraph):** the daemon ui-bridge K11-finish handler
> now submits `registerFirstMasterDevice` on chain (un-stubbing `chain_tx_hash`)
> by shelling out to `harness/scripts/heima-register-first-master.sh` under the
> **session (managed-wallet) omni** — `cap.rs` requires
> `device.operator_omni == J1.omni_account`, so the master-self memory cap
> resolves exactly this device. The **local deployer key signs** the tx
> (`msg.sender`; issue option α — `operatorMasterWallet` diverges from the
> managed wallet, which is fine for cap-mint). `GET /v1/onboarding/state` then
> reports `chain: master-registered`. Background: [`docs/arch.md`](arch.md) §9
> stage 4 + §12.4, [`docs/plan/web-flow/w3-real-memory.md`](plan/web-flow/w3-real-memory.md) §4.

## TL;DR — one command

```bash
bash harness/web-memory-bootstrap.sh           # all 7 steps, idempotent
bash harness/web-memory-bootstrap.sh --only-step 6   # re-run just the broker proof
bash harness/web-memory-bootstrap.sh --from-step 4   # skip build/contracts, start at funding
```

Steps 1–6 are fully automated and re-runnable; step 7 prints the manual browser
flow (a WebAuthn passkey can't be scripted).

## Do I need to reinstall the broker / update the contract?

| Question | Answer |
|---|---|
| **Reinstall the broker?** | **Not for #196** — it adds no broker/worker code. But it **depends on #195** (the master-self scope skip in `cap.rs` + `verify.rs`). If the broker host hasn't been redeployed since #195 merged, do it once: `bash scripts/setup-broker-host.sh --ref main` (idempotent). Step 6's proof fails with `ServiceNotInScope` if the broker is pre-#195. |
| **Update the contract?** | **No.** #196 calls the existing `SidecarRegistry` with its current ABI. No deploy/migration. |
| **What's needed locally?** | The #196 binary (`cargo build --release -p agentkeys-cli -p agentkeys-daemon`, = step 1); the deployer key resolvable (`HEIMA_DEPLOYER_KEY_FILE` / `~/.agentkeys/heima-deployer.key` / `./test-hei`); `cast` + `jq` on PATH; `scripts/operator-workstation.env` present. For the live plant you also need the memory worker URL + role ARN (already in `operator-workstation.env`) and AWS creds for the STS relay. |

## When do I fund the master? (no chicken-and-egg in option α)

In what #196 ships, the register tx's `msg.sender` is the **deployer key** — which
is already funded (it deployed the contracts). The master's managed/session
wallet **never signs anything**, so it needs **zero** HEI. Therefore:

- `heima-fund-master.sh` (step 4) targets the deployer by default and is a clean
  **idempotent no-op** when the deployer is already funded — run it anytime, order
  doesn't matter.
- There is **no chicken-and-egg**: the gas payer (deployer) is known from the
  start, before any onboarding / EVM-address derivation.

Your instinct — *fund after the EVM address is set up* — is correct **only for the
future β/γ model** (where the master's own wallet signs its txs). In that world
you'd run `bash scripts/heima-fund-master.sh --to 0x<managed-wallet>` **after**
onboarding stage 3 (managed-wallet attestation freezes the omni/address). In
option α it's moot.

## The steps (what `web-memory-bootstrap.sh` runs)

| # | Step | Idempotent behavior |
|---|---|---|
| 1 | Build `agentkeys` + `agentkeys-daemon` | cargo incremental — rebuilds only on source change |
| 2 | Contracts live (`verify-heima-contracts.sh`) | read-only RPC, zero gas |
| 3 | Broker reachable (`/healthz`) + #195 reminder | read-only; warns how to redeploy |
| 4 | Fund master gas-payer (`heima-fund-master.sh`) | skip-if-funded (no-op for the deployer in α) |
| 5 | Register master device on chain (`register_first_master` → **#164 passkey-account ERC-4337**, EOA fallback) | skip-if-already-active; both paths register `device_key_hash = keccak(operator_omni)` |
| 6 | **Proof**: SIWE → master-self cap-mint, NO scope grant → HTTP 200 | re-runnable; proves device + #195 + broker at once |
| 7 | Manual web-demo guidance (daemon launch + ordering) | informational |

Step 5 is the **CLI / operator==deployer** path (it also enables
`harness/v2-stage3-demo.sh` steps 16–17). The **web flow** registers
automatically under the session omni on passkey-finish — you do not run step 5
for the browser demo; it's a pre-flight that proves the chain-write path works.

## The one manual step — the live web demo

Launch the daemon with the #196 register shell-out wired in (step 7 prints the
exact command), then in the web UI **in this order** (the only sequencing rule):

1. **Verify email** — mints J1 + freezes the session omni.
2. **Finish the passkey (Touch ID)** — on finish the daemon auto-submits
   `registerFirstMasterDevice` under the session omni; `chain_tx_hash` is real.
   > If you finish the passkey **before** email-verify, registration is skipped
   > with a clear `chain_error` (the passkey still enrolls) — just re-finish after
   > verifying.
3. **Confirm:** `curl -s $UI_BRIDGE/v1/onboarding/state | jq .chain` → `"master-registered"`.
4. **Click the plant button** → writes `bots/0x<omni>/memory/memory:<ns>.enc`.

## Troubleshooting

| Symptom (step 6 / plant) | Cause | Fix |
|---|---|---|
| `ServiceNotInScope` on the master-self cap | broker is **pre-#195** (no scope skip) | `bash scripts/setup-broker-host.sh --ref main` |
| `DeviceNotActive` / `DeviceBindingMismatch` | master device not registered | re-run `--only-step 5` (CLI) or finish the web onboarding |
| `chain_error: no onboarding session` on passkey-finish | passkey finished before email-verify | verify email, then re-finish the passkey |
| `device_key_hash missing` / register script dies on K11 | no disk K11 for the CLI path | `agentkeys k11 enroll --webauthn --rp-id localhost --operator-omni 0x<deployer_omni>` |
| broker `AGENTKEYS_CHAIN_RPC_HTTP` / contract-address env errors | broker missing chain config | redeploy broker host |

## References

- Harness: [`harness/web-memory-bootstrap.sh`](../harness/web-memory-bootstrap.sh), [`harness/v2-stage3-demo.sh`](../harness/v2-stage3-demo.sh) steps 16–17.
- Scripts: [`scripts/heima-fund-master.sh`](../scripts/heima-fund-master.sh), [`harness/scripts/heima-register-first-master.sh`](../harness/scripts/heima-register-first-master.sh).
- Plan/spec: [`docs/plan/web-flow/w3-real-memory.md`](plan/web-flow/w3-real-memory.md) §4, [`docs/plan/web-flow/wire-real-paths.md`](plan/web-flow/wire-real-paths.md) §6 (W2), [`docs/arch.md`](arch.md) §9 stage 4 + §12.4.
