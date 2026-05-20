# v2 stage 2 — Heima Mainnet deploy + test runbook

**Audience**: operator standing up the stage-2 hardening (P-256 on-chain verify + M-of-N recovery + companion daemon) against **Heima Mainnet** (`chain_id 212013`).

**Prereq**: a working stage-1 deployment from [v2-stage1-migration-and-demo.md](v2-stage1-migration-and-demo.md). This runbook reuses every env var, helper script, and account from stage 1; it does NOT introduce a parallel chain or environment.

**What this lands**:
- Two new contracts: `P256Verifier` + `K11Verifier`
- Two re-deployed contracts: `SidecarRegistry` + `AgentKeysScope` (new ABI; old PR #87 instances become obsolete)
- One unchanged contract each: `K3EpochCounter` + `CredentialAudit` (re-deploy is optional — keep the PR #87 addresses if you want)
- A companion daemon process listening on `127.0.0.1:9091` with its own K11 credential at `rp_id=companion.localhost`
- New helper scripts: `heima-device-add.sh`, `heima-recovery.sh`, `heima-set-recovery-threshold.sh`

---

## 0. Inherited environment from stage 1

Everything below assumes the stage-1 demo already ran successfully against Heima Mainnet. The two artifacts we need from that run:

| Artifact | From stage 1 step | Lives at |
|---|---|---|
| Deployer mnemonic | §0 prereqs | `./test-hei` |
| Operator session JWT | §1 init | `~/.agentkeys/$SESSION_ID/session.json` |
| `operator-workstation.env` with `SIDECAR_REGISTRY_ADDRESS_HEIMA`, `SCOPE_CONTRACT_ADDRESS_HEIMA`, `K3_EPOCH_COUNTER_ADDRESS_HEIMA`, `CREDENTIAL_AUDIT_ADDRESS_HEIMA`, `HEIMA_DEPLOYER_ADDR_HEIMA`, `HEIMA_DEPLOYER_MNEMONIC_FILE` | §6 chain bring-up | `scripts/operator-workstation.env` |
| Primary K11 credential (`mode: "webauthn"`) | §10 K11 enroll | `~/.agentkeys/k11/<omni>.json` |
| Master device registered on PR #87 SidecarRegistry | §11 device register | on chain |

**If any of these are missing**, run `bash harness/v2-stage1-demo.sh --webauthn` first. The stage-2 deploy will fail with a clear "missing prereq" error otherwise.

```bash
# Sanity-check the inherited state.
export AGENTKEYS_CHAIN=heima
set -a; . scripts/operator-workstation.env; set +a

[ -f ./test-hei ] && echo "✓ deployer mnemonic"
[ -f "$HOME/.agentkeys/alice/session.json" ] && echo "✓ session JWT (alice)"
[ -n "$HEIMA_DEPLOYER_ADDR_HEIMA" ] && echo "✓ deployer addr: $HEIMA_DEPLOYER_ADDR_HEIMA"
[ -f "$HOME/.agentkeys/k11/$(printf 'agentkeysevm%s' "$HEIMA_DEPLOYER_ADDR_HEIMA" | tr 'A-F' 'a-f' | shasum -a 256 | awk '{print $1}').json" ] \
  && echo "✓ primary K11 enrollment"
```

---

## 1. Build the stage-2 binaries

```bash
cd /path/to/agentkeys

# Release builds — agentkeys CLI + companion daemon binary
cargo build --release -p agentkeys-cli -p agentkeys-daemon

# Smoke check
./target/release/agentkeys --version
./target/release/agentkeys-daemon --help 2>&1 | grep master-companion && echo "✓ companion mode wired"
```

Then run the forge test suite once to confirm contracts compile + tests pass under your local toolchain (28 tests, ~10 seconds):

```bash
cd crates/agentkeys-chain
forge test 2>&1 | tail -5
# Expected: 28 passed; 0 failed; 0 skipped (28 total tests)
cd -
```

---

## 2. Deploy the stage-2 contract set to Heima Mainnet

Heima EVM is at London level (no EIP-7212 P-256 precompile — see [CLAUDE.md](../CLAUDE.md)), so we deploy `P256Verifier` ourselves. The deploy script writes all 6 addresses to stdout in the same stable format the stage-1 bring-up parses.

```bash
export AGENTKEYS_CHAIN=heima
HEIMA_RPC="$(./target/release/agentkeys chain show heima | jq -r .rpc.http)"
DEPLOYER_PK="$(node scripts/derive-evm-from-mnemonic.mjs test-hei | jq -r .privateKey)"
DEPLOYER_ADDR="$(node scripts/derive-evm-from-mnemonic.mjs test-hei | jq -r .address)"

# Pre-check balance (the 6-contract deploy needs ~0.05 HEI; bump if forge gas estimator
# rejects the broadcast).
cast balance "$DEPLOYER_ADDR" --rpc-url "$HEIMA_RPC"

cd crates/agentkeys-chain
forge script script/DeployAgentKeysV1.s.sol \
  --rpc-url "$HEIMA_RPC" \
  --private-key "$DEPLOYER_PK" \
  --broadcast \
  --slow                 # one tx at a time — avoids nonce races on Heima
cd -
```

The last 8 lines of forge output have this exact shape (your addresses will differ):

```
Deployer:         0xYourDeployer...
SignerGovernance: 0xYourDeployer...
P256Verifier:     0x1111111111111111111111111111111111111111
K11Verifier:      0x2222222222222222222222222222222222222222
AgentKeysScope:   0x3333333333333333333333333333333333333333
SidecarRegistry:  0x4444444444444444444444444444444444444444
K3EpochCounter:   0x5555555555555555555555555555555555555555
CredentialAudit:  0x6666666666666666666666666666666666666666
```

**Capture all 6 addresses into [`scripts/operator-workstation.env`](../scripts/operator-workstation.env)** — overwrite the stage-1 entries for `SIDECAR_REGISTRY_ADDRESS_HEIMA` and `SCOPE_CONTRACT_ADDRESS_HEIMA` (their ABIs changed; the old instances are unusable). Keep the K3EpochCounter + CredentialAudit entries from stage 1 if you want — those ABIs are unchanged — or update to the freshly deployed ones for a clean slate.

```bash
# Edit scripts/operator-workstation.env and update:
P256_VERIFIER_ADDRESS_HEIMA=0x1111111111111111111111111111111111111111   # NEW
K11_VERIFIER_ADDRESS_HEIMA=0x2222222222222222222222222222222222222222    # NEW
SIDECAR_REGISTRY_ADDRESS_HEIMA=0x4444444444444444444444444444444444444444  # OVERWRITE stage-1
SCOPE_CONTRACT_ADDRESS_HEIMA=0x3333333333333333333333333333333333333333    # OVERWRITE stage-1
# K3_EPOCH_COUNTER_ADDRESS_HEIMA — keep or overwrite, your choice
# CREDENTIAL_AUDIT_ADDRESS_HEIMA — keep or overwrite, your choice
```

Re-source the env and sanity-check addresses are wired correctly:

```bash
set -a; . scripts/operator-workstation.env; set +a

for name in P256_VERIFIER K11_VERIFIER SIDECAR_REGISTRY SCOPE_CONTRACT K3_EPOCH_COUNTER CREDENTIAL_AUDIT; do
  var="${name}_ADDRESS_HEIMA"
  addr="${!var}"
  code=$(cast code "$addr" --rpc-url "$HEIMA_RPC" 2>/dev/null | head -c 30)
  if [ "${#code}" -gt 4 ]; then
    echo "✓ $name = $addr (deployed)"
  else
    echo "✗ $name = $addr (no code at address)"
  fi
done
```

All 6 lines should show `✓ ... (deployed)`.

---

## 3. Re-bootstrap the primary master under the new SidecarRegistry

The new `SidecarRegistry` instance is at a fresh address with empty state. Your operator's master device is registered against the OLD instance (PR #87) — that registration doesn't carry over. Run the stage-1 demo's bootstrap steps against the NEW contracts:

```bash
export AGENTKEYS_CHAIN=heima
AGENTKEYS_CHAIN=heima bash harness/v2-stage1-demo.sh --from-step 10 --to-step 11
```

- Step 10 (`registerMasterDevice` → now `registerFirstMasterDevice`): re-bootstraps the operator on the new registry. No K11 required (first-call bootstrap rule).
- Step 11 (K11 enroll): if `~/.agentkeys/k11/<omni>.json` already exists with `mode: "webauthn"`, skips with `ok` (no Touch ID prompt).

> **Note**: as of this PR, `scripts/heima-device-register.sh` still calls the OLD `registerMasterDevice` signature; it'll fail with `function not found` against the new SidecarRegistry. See "[Known gaps](#known-gaps)" below — this is tracked as a follow-up. For now, run step 10 against the new instance manually:
> ```bash
> bash scripts/heima-device-register-stage2.sh   # NOT YET WRITTEN — see Known gaps
> ```

---

## 4. Run the stage-2 demo against Heima Mainnet

This is the main exercise:

```bash
export AGENTKEYS_CHAIN=heima
bash harness/v2-stage2-demo.sh --webauthn
```

**8 steps, expected interactions**:

| Step | What it does | Touch ID prompt? |
|---|---|---|
| 1 | Build agentkeys + agentkeys-daemon | no |
| 2 | `forge test` on contracts | no |
| 3 | Verify primary master on-chain (new SidecarRegistry) | no |
| 4 | Enroll companion K11 (`rp_id=companion.localhost`), start companion daemon at `127.0.0.1:9091` | **yes — first time only** |
| 5 | `registerAdditionalMasterDevice` tx, with primary K11 signing | **yes** |
| 6 | `setRecoveryThreshold(2)` tx | **yes** |
| 7 | M-of-N recovery dry-run (sanity-check the script) | no |
| 8 | Summary | no |

Re-runs of the demo are idempotent: step 4 skips K11 enrollment if the credential file already exists; step 5 skips if the companion is already registered as 2nd master; step 6 skips if threshold is already 2.

**Verification after the run**:

```bash
# Should print recoveryThreshold == 2
cast call "$SIDECAR_REGISTRY_ADDRESS_HEIMA" \
  "recoveryThreshold(bytes32)(uint8)" \
  "0x$(printf 'agentkeysevm%s' "$HEIMA_DEPLOYER_ADDR_HEIMA" | tr 'A-F' 'a-f' | shasum -a 256 | awk '{print $1}')" \
  --rpc-url "$HEIMA_RPC"

# Companion daemon /v1/companion/whoami should respond
curl -sS http://127.0.0.1:9091/v1/companion/whoami | jq

# operatorNonce should be ≥ 2 (one bump per master mutation: device-add + set-threshold)
cast call "$SIDECAR_REGISTRY_ADDRESS_HEIMA" \
  "operatorNonce(bytes32)(uint256)" \
  "0x$(printf 'agentkeysevm%s' "$HEIMA_DEPLOYER_ADDR_HEIMA" | tr 'A-F' 'a-f' | shasum -a 256 | awk '{print $1}')" \
  --rpc-url "$HEIMA_RPC"
```

---

## 5. Test the M-of-N recovery flow (optional, destructive)

This actually revokes a master device on chain. Only run after you've registered ≥ 3 master devices, because the SidecarRegistry doesn't permit revoking the only-or-last surviving master (would lock the operator out).

```bash
# Register a 3rd master first by re-running step 5 with a different companion.
# Then revoke that 3rd master (let's assume its device_key_hash is $TARGET):

export AGENTKEYS_CHAIN=heima
TARGET=0x<third-master-device-key-hash>

bash harness/v2-stage2-demo.sh --webauthn \
  --only-step 7 \
  --revoke-master "$TARGET"
```

Both primary AND companion daemons must be running. Two Touch ID prompts back-to-back (primary first, then companion).

---

## 6. Cleanup

```bash
# Stop the companion daemon when done
if [ -f /tmp/agentkeys-companion.pid ]; then
  kill "$(cat /tmp/agentkeys-companion.pid)" 2>/dev/null || true
  rm -f /tmp/agentkeys-companion.pid /tmp/agentkeys-companion-*.log
fi
```

The deployed contracts stay on Heima Mainnet — they're the new canonical instances for stage 2. Future stage-2 runs reuse them via the addresses in `operator-workstation.env`.

---

## Known gaps (deferred to follow-up PRs)

This PR lands the **chain + CLI + daemon + new bash scripts** for stage 2. The following items would round out the runbook but are tracked for separate PRs:

1. **`scripts/heima-bring-up.sh`** — currently captures 4 addresses; needs +2 for P256Verifier + K11Verifier (one-line `env_set` addition). Operators today copy-paste the addresses by hand after the forge script run.
2. **`scripts/heima-device-register.sh`, `heima-scope-set.sh`, `heima-scope-revoke.sh`** — these were written against the stage-1 ABI (`bytes calldata k11Assertion`). They need updating to use the new `K11Assertion` struct shape. As a workaround, the new `heima-device-add.sh` handles the multi-master case; the single-master bootstrap is handled by step 10 of `harness/v2-stage1-demo.sh` once the bring-up script captures the new addresses.
3. **audit-service worker** (`agentkeys-worker-audit` crate, tier-A Merkle relay batches).
4. **email-service worker** (`agentkeys-worker-email` crate, per-actor inbox).
5. **K3 rotation operational runbook** (`scripts/heima-k3-rotate.sh` + procedure doc).

All five are tracked under [#90](https://github.com/litentry/agentKeys/issues/90) for stage-2 follow-up.

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `forge test` errors `Stack too deep` | `via_ir` not enabled | Already set in [`foundry.toml`](../crates/agentkeys-chain/foundry.toml) — re-pull, the via_ir = true line should be present |
| Forge broadcast errors `prevrandao not set` | Foundry default `evm_version=paris` rejects Heima's London header | Pass `--evm-version london` to forge script |
| `agentkeys k11 enroll --rp-id companion.localhost` fails with "no credential available" in browser | macOS / Safari may not resolve `*.localhost` automatically | Add `127.0.0.1 companion.localhost` to `/etc/hosts`, then retry |
| Companion daemon starts but `/v1/companion/whoami` returns 500 | `--companion-operator-omni` not passed | Re-run with `--companion-operator-omni 0x<omni>` |
| `cast call recoveryThreshold` returns `Error: ... reverted` | You're calling the OLD SidecarRegistry (PR #87 address) | Make sure `SIDECAR_REGISTRY_ADDRESS_HEIMA` in operator-workstation.env points to the NEW instance from §2 |
| Touch ID prompt doesn't appear | Browser isn't focused / passkey-disabled in Safari settings | Switch to Chrome, or enable "AutoFill Passwords and Passkeys" in Safari ▸ Settings ▸ AutoFill |
