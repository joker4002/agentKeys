# Chain setup — AgentKeys

**Audience:** the operator bringing AgentKeys up on an EVM chain (Heima mainnet, Heima Paseo, local Anvil, or any other EVM chain via a chain profile).
**Scope:** one idempotent command that walks the per-actor binding ceremony end-to-end (contract deploy → master registration → K11 enrollment → agent creation → scope grants → audit smoke).
**Companion:** [`docs/cloud-bootstrap.md`](cloud-bootstrap.md) for the AWS/broker side (run cloud-bootstrap first — chain setup expects `scripts/operator-workstation.env` to already exist), [`docs/ci-setup.md`](ci-setup.md) for the automated path.
**FAQ + troubleshooting:** [`wiki/heima-setup-faq.md`](../wiki/heima-setup-faq.md).

## TL;DR

```bash
# Heima mainnet (default — AGENTKEYS_CHAIN=heima implicit)
AWS_PROFILE=agentkeys-admin bash scripts/setup-heima.sh

# Heima Paseo testnet (zero HEI cost; Alice sudo funds the deployer)
AWS_PROFILE=agentkeys-admin bash scripts/setup-heima.sh --chain heima-paseo

# Local Anvil (fully ephemeral, instant finality, zero cost)
AWS_PROFILE=agentkeys-admin bash scripts/setup-heima.sh --chain anvil

# Test instance on Heima mainnet (different deployer key → different
# contract addresses on the SAME mainnet → fully isolated parallel set):
AWS_PROFILE=agentkeys-admin \
HEIMA_DEPLOYER_KEY_FILE=~/.agentkeys/heima-deployer-test.key \
MAINNET_CONFIRM=1 \
  bash scripts/setup-heima.sh
```

[`scripts/setup-heima.sh`](../scripts/setup-heima.sh) is **the single idempotent entry point** for chain bring-up. Re-running is safe: every step pre-checks chain state (`cast code` for deploys, `getDevice.registeredAt` for registrations, `getScope` config-equality for grants) and short-circuits when the work is already a no-op.

Despite the name, the orchestrator works for any EVM chain that has a profile in [`crates/agentkeys-core/chain-profiles/`](../crates/agentkeys-core/chain-profiles/) — Heima is the production target and gives the script its name, but the same script handles Ethereum, Sepolia, Base, Base Sepolia, and any custom EVM chain via `AGENTKEYS_CHAIN_PROFILE_FILE`.

## What runs, in order

| # | Step | Idempotency check | Helper script |
|---|------|-------------------|---------------|
| 1 | Tool sanity-check (`jq curl aws cast forge node npx python3` + `agentkeys` binary) | tool presence | — |
| 2 | Source `scripts/operator-workstation.env` | file exists + `REGION` set | — |
| 3 | Chain reachability + `eth_chainId` matches the profile's claim | catches "you said Paseo but the RPC is mainnet" footguns | — |
| 4 | Generate/reuse deployer keypair at `~/.agentkeys/${chain}-deployer.key` (0600) | file exists | (inline) |
| 5 | Fund the deployer | balance ≥ floor | [`heima-fund-account.sh`](../scripts/heima-fund-account.sh) |
| 6 | Deploy the 6 stage-1 contracts atomically (P256Verifier → K11Verifier → SidecarRegistry → AgentKeysScope → K3EpochCounter → CredentialAudit) | `cast code` on every claimed address; skip when present | [`heima-bring-up.sh`](../scripts/heima-bring-up.sh) |
| 7 | Persist contract addresses to `operator-workstation.env` (chain-namespaced) | sed replace-or-append; no-op when unchanged | (inside bring-up) |
| 8 | Verify contracts on-chain (read-only RPC: bytecode + ABI + wiring) | always runs, ~3s | [`verify-heima-contracts.sh`](../scripts/verify-heima-contracts.sh) |
| 9 | Register operator master device (first-master bootstrap) | `getDevice.registeredAt > 0` check | [`heima-device-register.sh`](../scripts/heima-device-register.sh) |
| 10 | K11 enrollment (stub bytes by default; `--webauthn` for real Touch ID) | enrollment file exists at `~/.agentkeys/k11/<omni>.json` | (inline) |
| 11 | Create demo agent device | `getDevice.registeredAt > 0` check | [`heima-agent-create.sh`](../scripts/heima-agent-create.sh) |
| 12 | Set scope for agent (K11-gated — needs `--webauthn`) | `getScope` config-equality check; skipped without `--webauthn` | [`heima-scope-set.sh`](../scripts/heima-scope-set.sh) |
| 13 | Append a credential-audit row (V1 path) | **intentionally append-only** | [`heima-credential-audit.sh`](../scripts/heima-credential-audit.sh) |
| 14 | Tier-A audit relay + worker `/healthz` smoke | **intentionally append-only** | [`heima-worker-smoke.sh`](../scripts/heima-worker-smoke.sh) |
| 15 | Summary — print contract addresses + suggested next-step re-runs | always | — |

## Per-step re-runs

The orchestrator accepts `--from-step N`, `--to-step N`, and `--only-step N`. Use these to surgically re-run after fixing an issue without re-walking the whole pipeline:

```bash
bash scripts/setup-heima.sh --only-step 6   # re-check the deploy (no-op on identical bytecode)
bash scripts/setup-heima.sh --only-step 9   # re-register the master after rotating session JWT
bash scripts/setup-heima.sh --only-step 14  # just smoke the workers
```

## Chain matrix

| | `heima` (mainnet) | `heima-paseo` (testnet) | `anvil` (local dev) | Other EVM (Ethereum, Base, …) |
|---|---|---|---|---|
| Chain ID | 212013 | 2013 | 31337 | per profile |
| Cost per deploy | real HEI gas | 0 (sudo funds) | 0 | real ETH/native gas |
| Deployer funding | operator's personal wallet | Alice sudo via [`heima-fund-account.sh`](../scripts/heima-fund-account.sh) | anvil pre-funds default key with 10 000 ETH | operator's personal wallet |
| Finality | per chain profile | per chain profile | instant | per chain profile |
| Mainnet deploy guard | `MAINNET_CONFIRM=1` required | — | — | `MAINNET_CONFIRM=1` for known mainnets |
| Stage-1 K11 stub on this chain | refuses unless `AGENTKEYS_ALLOW_STAGE1_STUBS=1` (per arch.md §22b.1) | allowed | allowed | per chain policy |

## After a successful run

`setup-heima.sh` writes the contract addresses to `scripts/operator-workstation.env` under chain-namespaced keys (e.g. `SCOPE_CONTRACT_ADDRESS_HEIMA=0x…`). Subsequent steps and the broker workers all source the same env file, so no manual copy-paste is needed.

Verify any time (read-only RPC, zero gas):

```bash
AGENTKEYS_CHAIN=heima       bash scripts/verify-heima-contracts.sh
AGENTKEYS_CHAIN=heima-paseo bash scripts/verify-heima-contracts.sh
```

## Chain-profile source of truth

Built-in profiles ship in [`crates/agentkeys-core/chain-profiles/`](../crates/agentkeys-core/chain-profiles/): `heima.json`, `heima-paseo.json`, `anvil.json`, `base.json`, `base-sepolia.json`, `ethereum.json`, `sepolia.json`. Each carries RPC URL, chain ID, gas model, default block tag for finality, and Foundry chain arg.

To override the RPC for one run without forking a profile:

```bash
AGENTKEYS_CHAIN_PROFILE_FILE=./my-custom-profile.json bash scripts/setup-heima.sh
```

The JSON shape is documented in [`docs/arch.md`](arch.md) §22a. Add a new chain by dropping a JSON file into the profiles directory + running with `--chain <new-name>`.

## EVM version pin (Heima-specific)

Heima Frontier runs at London EVM level (pre-Merge). [`crates/agentkeys-chain/foundry.toml`](../crates/agentkeys-chain/foundry.toml) pins `evm_version = "london"` so Foundry's simulator doesn't reject `prevrandao`-less block headers. **Don't change this** without re-verifying against a live Heima block header — see [CLAUDE.md "Heima EVM compatibility level"](../CLAUDE.md) for the verification recipe.

Other EVM targets (Ethereum, Base, etc.) are post-Merge and accept `paris` / `shanghai` / `cancun`. For those, override per-deploy:

```bash
FOUNDRY_EVM_VERSION=cancun bash scripts/setup-heima.sh --chain ethereum
```

## Test instance on a real chain — same `.sol`, new address

EVM contract addresses derive from `(deployer_address, nonce)` and Solidity compiles deterministically. Identical `crates/agentkeys-chain/src/*.sol` + identical `DeployAgentKeysV1.s.sol` + a **different deployer key** = a parallel contract set at new addresses on the same chain. No code branch, no testnet — just a separate deployer wallet.

This is how the CI test instance gets contracts on Heima mainnet without colliding with prod:

```bash
# One-shot test deploy (operator-managed, before CI activation):
AGENTKEYS_CHAIN=heima \
HEIMA_DEPLOYER_KEY_FILE=~/.agentkeys/heima-deployer-test.key \
MAINNET_CONFIRM=1 \
  bash scripts/setup-heima.sh --from-step 4 --to-step 8
# → 6 fresh contract addresses; pin into TEST_*_HEIMA secrets
#   (see docs/ci-setup.md step 5).
```

## Related

- Cloud / AWS prereqs: [`docs/cloud-bootstrap.md`](cloud-bootstrap.md)
- Operator workstation setup: [`docs/dev-setup.md`](dev-setup.md)
- CI activation: [`docs/ci-setup.md`](ci-setup.md)
- Live contract addresses: [`docs/spec/deployed-contracts.md`](spec/deployed-contracts.md)
- Architecture: [`docs/arch.md`](arch.md) §22 (chain profiles), §22b (per-actor binding ceremonies)
- FAQ + troubleshooting: [`wiki/heima-setup-faq.md`](../wiki/heima-setup-faq.md)
