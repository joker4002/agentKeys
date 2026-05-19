# K3 Rotation Runbook

**Audience**: operator who needs to advance the K3 epoch on Heima Mainnet, either as scheduled hygiene (quarterly) or in response to a TEE-compromise indicator.

**What K3 is**: the signer's per-epoch master secret. KEKs that encrypt credential and memory blobs are derived from K3_v[N]; rotation moves new writes to K3_v[N+1] while old blobs stay decryptable under the retained K3_v[N] inside the signer enclave.

**What this runbook delivers**: one chain transaction (`K3EpochCounter.advanceEpoch()`) that bumps the on-chain epoch counter. Workers + signer enclave consume the `K3Rotated` event and switch to the new epoch for new writes. Existing blobs continue to decrypt — lazy on-read re-encryption picks up over time, and an eager-re-encrypt tool can be run on demand (separate; not in this runbook).

## TL;DR

```bash
export AGENTKEYS_CHAIN=heima
bash scripts/heima-k3-rotate.sh
```

That's the whole flow. Idempotent re-runs are safe (`--target-epoch N` skips if already at or above N). All other operations below are pre/post sanity checks.

## Prerequisites

| Item | Why | How to check |
|---|---|---|
| Deployer wallet IS `signerGovernance` on K3EpochCounter | Only that address can call `advanceEpoch()` | `cast call $K3_EPOCH_COUNTER_ADDRESS_HEIMA "signerGovernance()(address)" --rpc-url <heima-rpc>` should match the address derived from `~/.agentkeys/heima-deployer.key` |
| Deployer funded with HEI | `advanceEpoch()` consumes ~30k gas (~0.001 HEI at current price) | `cast balance <addr> --rpc-url <heima-rpc>` >= 0.01 HEI |
| Operator-workstation env sourced | Provides `K3_EPOCH_COUNTER_ADDRESS_HEIMA` | `set -a; . scripts/operator-workstation.env; set +a` |

## Step-by-step

### 1. Read current epoch

```bash
set -a; . scripts/operator-workstation.env; set +a
HEIMA_RPC="$(./target/release/agentkeys chain show heima | jq -r .rpc.http)"
cast call "$K3_EPOCH_COUNTER_ADDRESS_HEIMA" "currentEpoch()(uint256)" --rpc-url "$HEIMA_RPC"
```

Expected: an integer ≥ 1 (epoch 1 is set at contract deploy time).

### 2. Run the rotation script

Default (advance by one epoch):

```bash
bash scripts/heima-k3-rotate.sh
```

Or target a specific epoch (e.g. catch up to epoch 5):

```bash
bash scripts/heima-k3-rotate.sh --target-epoch 5
```

Dry-run to preview without sending tx:

```bash
bash scripts/heima-k3-rotate.sh --dry-run
```

Output ends with a JSON record:

```json
{"ok":true,"prev_epoch":1,"new_epoch":2,"tx_hashes":["0x..."]}
```

### 3. Verify the rotation landed

```bash
cast call "$K3_EPOCH_COUNTER_ADDRESS_HEIMA" "currentEpoch()(uint256)" --rpc-url "$HEIMA_RPC"
# expected: <new_epoch> from step 2
cast call "$K3_EPOCH_COUNTER_ADDRESS_HEIMA" "epochStartedAt(uint256)(uint256)" "<new_epoch>" --rpc-url "$HEIMA_RPC"
# expected: block.timestamp of the rotation tx, non-zero
```

### 4. Observe `K3Rotated` event

```bash
LATEST=$(cast block-number --rpc-url "$HEIMA_RPC")
cast logs --address "$K3_EPOCH_COUNTER_ADDRESS_HEIMA" \
  --from-block $((LATEST-100)) --to-block latest \
  "K3Rotated(uint256,uint256)" \
  --rpc-url "$HEIMA_RPC"
```

Workers + signer enclave subscribe to this event. Within their poll interval (typically 10–30s after block finality) they:

1. Switch new envelopes to use K3_v[new_epoch] for KEK derivation
2. Retain K3_v[prev_epoch] in-enclave for decrypt of pre-rotation blobs
3. Begin lazy on-read re-encryption — blobs decrypted under the old epoch get re-encrypted under the new one on next write

## Post-rotation considerations

**Old blobs**: stay decryptable indefinitely (K3 history retained inside the signer enclave). No data loss.

**Lazy vs eager re-encryption**: by default the rotation only changes the epoch counter. Existing S3 blobs keep their old envelope version and decrypt via the retained K3_v[prev] in the enclave. Two ways to migrate:

- **Lazy** (default): blobs get re-encrypted under the new K3 on next operator write or worker re-write. No action required.
- **Eager** (forthcoming `scripts/heima-k3-reencrypt-eager.sh`): scans all blobs for an operator, re-encrypts each under the new K3. Use after a confirmed TEE compromise where you want the old-K3-encrypted blobs purged ASAP.

**Audit trail**: every rotation emits a `K3Rotated` event on chain. Operators using `subscan-essentials` (per arch.md §22a.6) can query history with:

```
https://heima.subscan.io/event?address=$K3_EPOCH_COUNTER_ADDRESS_HEIMA&event=K3Rotated
```

## When to rotate

| Scenario | Recommended action |
|---|---|
| Scheduled hygiene | Quarterly. Document the calendar reminder. |
| Operator off-boards an internal team member who had K3 access | Within 24 hours. |
| TEE-compromise indicator (signer attestation drift, anomalous read patterns, side-channel disclosure) | **Immediately + eager re-encrypt all blobs** |
| Quorum policy change (e.g. moving K3 management from EOA to multisig) | Bundle with the `setSignerGovernance(newMultisig)` call (separate tx) |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Script dies with "deployer is NOT the K3 signerGovernance" | The contract's `signerGovernance` was already transferred away from your deployer wallet. Either (a) move to that wallet to rotate, or (b) call `setSignerGovernance(currentDeployer)` from the previous governance address first |
| `cast send` reverts with `NotSignerGovernance` | Same as above |
| Workers don't pick up the new epoch | Check worker logs for the `K3Rotated` event. Default poll interval is 30s; if longer, restart the worker. Worker logs at `~/.agentkeys/logs/worker-*.log` |
| Want to undo a rotation | Impossible — the contract only advances. If a rotation was a mistake, advance again to "catch up" and accept that one epoch number is unused |

## Stage 3 migration path

Currently `signerGovernance` is a single EOA (the deployer). Stage 3 swaps in an M-of-N multisig contract for governance. The migration is:

1. Deploy a multisig (Gnosis Safe or similar) on Heima with N operators as signers
2. From the current deployer, call:
   ```
   cast send $K3_EPOCH_COUNTER_ADDRESS_HEIMA "setSignerGovernance(address)" <multisig_address> ...
   ```
3. Future rotations require a multisig tx; this script becomes a wrapper that submits the multisig proposal + waits for the threshold of signers.

The contract's `setSignerGovernance` is already defined — no contract change needed.
