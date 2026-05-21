# Heima setup — AgentKeys

**Audience:** the operator bringing AgentKeys up on a Heima chain (mainnet, Paseo, or local Anvil).
**Scope:** one command that walks the 15-step chain bring-up end-to-end.
**Companion:** [`docs/cloud-setup.md`](cloud-setup.md) for the AWS/broker side. Run cloud-setup first — Heima setup expects [`scripts/operator-workstation.env`](../scripts/operator-workstation.env) to already exist.
**FAQ + troubleshooting:** [`wiki/heima-setup-faq.md`](../wiki/heima-setup-faq.md).

## TL;DR

```bash
# Mainnet (default; AGENTKEYS_CHAIN=heima implicit)
AWS_PROFILE=agentkeys-admin bash scripts/setup-heima.sh

# Paseo testnet (no real HEI cost; Alice sudo funds the deployer)
AWS_PROFILE=agentkeys-admin bash scripts/setup-heima.sh --chain heima-paseo

# Local Anvil (fully ephemeral, instant finality, free)
AWS_PROFILE=agentkeys-admin bash scripts/setup-heima.sh --chain anvil
```

[`scripts/setup-heima.sh`](../scripts/setup-heima.sh) is **the single idempotent entry point** for Heima bring-up. Re-running is safe: every step pre-checks chain state and short-circuits when the work is already a no-op. Per-step helpers (`scripts/heima-{bring-up,device-register,agent-create,scope-set,credential-audit,worker-smoke}.sh`) stay callable directly for surgical re-runs.

## What runs, in order

| # | Step | Idempotency check | Helper script |
|---|------|-------------------|---------------|
| 1 | Tool sanity-check (jq curl aws cast forge node npx python3 + `agentkeys` binary) | tool presence | — |
| 2 | Source `scripts/operator-workstation.env` | file exists + `REGION` set | — |
| 3 | Chain reachability + `eth_chainId` matches the profile's claim | catches "you said paseo but the RPC is mainnet" footguns | — |
| 4 | Generate/reuse deployer keypair at `~/.agentkeys/${chain}-deployer.key` (0600) | file exists | (inline) |
| 5 | Fund the deployer | balance ≥ floor | [`heima-fund-account.sh`](../scripts/heima-fund-account.sh) |
| 6 | Deploy the 6 stage-1 contracts atomically (P256Verifier → K11Verifier → SidecarRegistry → AgentKeysScope → K3EpochCounter → CredentialAudit) | `cast code` on every claimed address; skip when present | [`heima-bring-up.sh`](../scripts/heima-bring-up.sh) |
| 7 | Persist contract addresses to `operator-workstation.env` namespaced by chain | (sed replace-or-append, no-op when unchanged) | (inside bring-up) |
| 8 | Verify contracts on-chain (read-only RPC: bytecode + ABI + wiring) | always runs, ~3s | [`verify-heima-contracts.sh`](../scripts/verify-heima-contracts.sh) |
| 9 | Register operator master device (first-master bootstrap) | `getDevice.registeredAt > 0` check | [`heima-device-register.sh`](../scripts/heima-device-register.sh) |
| 10 | K11 enrollment (stub bytes by default; `--webauthn` for real Touch ID) | enrollment file exists at `~/.agentkeys/k11/<omni>.json` | (inline) |
| 11 | Create demo agent device | `getDevice.registeredAt > 0` check | [`heima-agent-create.sh`](../scripts/heima-agent-create.sh) |
| 12 | Set scope for agent (K11-gated — needs `--webauthn`) | `getScope` config-equality check; skipped without `--webauthn` | [`heima-scope-set.sh`](../scripts/heima-scope-set.sh) |
| 13 | Append a credential-audit row (V1 path) | **intentionally append-only** — re-runs add a fresh row | [`heima-credential-audit.sh`](../scripts/heima-credential-audit.sh) |
| 14 | Tier-A audit relay + worker `/healthz` smoke | **intentionally append-only** | [`heima-worker-smoke.sh`](../scripts/heima-worker-smoke.sh) |
| 15 | Summary — print contract addresses + suggested next-step re-runs | always | — |

## Per-step re-runs

The orchestrator accepts `--from-step N`, `--to-step N`, and `--only-step N`. Use these to surgically re-run after fixing an issue without re-walking the whole pipeline:

```bash
# Just re-check the deploy (cast-code idempotency means nothing redeploys
# unless an address is empty)
bash scripts/setup-heima.sh --only-step 6

# Re-register the master after rotating the session JWT
bash scripts/setup-heima.sh --only-step 9

# Just smoke the workers
bash scripts/setup-heima.sh --only-step 14
```

## Mainnet vs Paseo vs Anvil

| | `heima` (mainnet) | `heima-paseo` (testnet) | `anvil` (local dev) |
|---|---|---|---|
| Chain ID | 212013 | 2013 | 31337 |
| Cost per deploy | real HEI gas | 0 | 0 |
| Deployer funding | operator's personal wallet (no sudo on mainnet) | Alice sudo via [`heima-fund-account.sh`](../scripts/heima-fund-account.sh) | anvil pre-funds the default key with 10 000 ETH |
| Finality | per chain profile | per chain profile | instant |
| Used by | production | dev / pre-merge sanity | unit tests + ephemeral dev |
| Mainnet deploy guard | requires `MAINNET_CONFIRM=1` env var | — | — |
| Stage-1 K11 stub on this chain | refuses unless `AGENTKEYS_ALLOW_STAGE1_STUBS=1` (per arch.md §22b.1) | allowed | allowed |

## After a successful run

`setup-heima.sh` writes the contract addresses to `scripts/operator-workstation.env` under chain-namespaced keys (e.g. `SCOPE_CONTRACT_ADDRESS_HEIMA=0x…`). Subsequent steps + the broker workers source the same env file, so no manual copy-paste is needed.

Verify any time:

```bash
AGENTKEYS_CHAIN=heima       bash scripts/verify-heima-contracts.sh
AGENTKEYS_CHAIN=heima-paseo bash scripts/verify-heima-contracts.sh
```

Read-only RPC, zero gas, exits 0 on all-pass.

## Chain-profile source of truth

Built-in profiles ship in [`crates/agentkeys-core/chain-profiles/`](../crates/agentkeys-core/chain-profiles/) (`heima.json`, `heima-paseo.json`, `anvil.json`, `base.json`, `base-sepolia.json`, `ethereum.json`, `sepolia.json`). Each carries: RPC URL, chain ID, gas model, default block tag for finality, foundry chain arg.

To override the RPC for one run without forking a profile:

```bash
AGENTKEYS_CHAIN_PROFILE_FILE=./my-custom-profile.json bash scripts/setup-heima.sh
```

The JSON shape is documented in [`docs/spec/architecture.md`](spec/architecture.md) §22a.

## Heima EVM version pin

Heima Frontier runs at London EVM level (pre-Merge). [`crates/agentkeys-chain/foundry.toml`](../crates/agentkeys-chain/foundry.toml) pins `evm_version = "london"` so Foundry's simulator doesn't reject `prevrandao`-less block headers. **Don't change this** without re-verifying against a live Heima block header — see [CLAUDE.md "Heima EVM compatibility level"](../CLAUDE.md) for the verification recipe.

## Related

- Cloud / AWS prereqs: [`docs/cloud-setup.md`](cloud-setup.md)
- CI setup: [`docs/ci-setup.md`](ci-setup.md)
- Live contract addresses: [`docs/spec/deployed-contracts.md`](spec/deployed-contracts.md)
- Architecture: [`docs/spec/architecture.md`](spec/architecture.md) §22 (chain profiles), §22b (per-actor binding ceremonies)
- FAQ + troubleshooting: [`wiki/heima-setup-faq.md`](../wiki/heima-setup-faq.md)
