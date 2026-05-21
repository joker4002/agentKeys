# CI setup — AgentKeys

**Audience:** the operator activating the no-LLM CI workflow against a test instance of the production environment.
**Scope:** one workflow file ([`.github/workflows/harness-ci.yml`](../.github/workflows/harness-ci.yml)), a list of GitHub secrets, and the test-side counterparts of the production resources from [`docs/cloud-setup.md`](cloud-setup.md) + [`docs/heima-setup.md`](heima-setup.md).
**FAQ + troubleshooting:** [`wiki/ci-setup-faq.md`](../wiki/ci-setup-faq.md).

## TL;DR

The workflow runs unmodified on every push / PR. It has two jobs:

1. **`rust-checks`** — always runs. `cargo fmt --check` + `cargo clippy -D warnings` + `cargo test --workspace`. Covers 600+ tests including the in-process broker integration tests (which already mock STS + SES + WebAuthn).
2. **`harness-e2e`** — gated on the `TEST_OIDC_AWS_ROLE_ARN` secret being set. Runs the production harness scripts ([`harness/v2-stage{1,2,3}-demo.sh`](../harness/)) against an isolated TEST instance of the cloud + chain.

Until the operator activates the test instance, `harness-e2e` surfaces a `::warning::` skip and the PR is unblocked.

## What "mirror production" means

Every resource in the test instance is parallel to prod:

| | Production | Test |
|---|---|---|
| Broker host | `broker.litentry.org` | `test-broker.litentry.org` (long-lived; AWS validates OIDC issuer URLs byte-for-byte) |
| OIDC issuer | `https://broker.litentry.org` | `https://test-broker.litentry.org` |
| IAM roles | `agentkeys-{data,vault,memory}-role` | `agentkeys-{data,vault,memory}-role-test` |
| S3 buckets | `agentkeys-{mail,vault,memory}-${ACCT}` | `agentkeys-{mail,vault,memory}-test-${ACCT}` |
| Chain | Heima mainnet | **Heima mainnet** (same chain, different deployer → different addresses) |
| Deployer wallet | operator's prod deployer | dedicated test wallet (small HEI float) |
| Contracts | one production deploy | one test deploy with **identical `.sol` source** → new addresses |
| WebAuthn | real Touch ID | never (`WEBAUTHN_MODE=0`) |
| LLM | (separate `claude.yml` review) | never |

**Same code, same chain, isolated storage.** EVM addresses derive from `(deployer, nonce)` and Solidity compiles deterministically — a different deployer key with the same source files produces a parallel contract set that can't see or write to prod contract state.

## One-shot operator bring-up

### 1. Provision the test broker

Same flow as `docs/cloud-setup.md`, with the `-test` suffix on every identifier:

```bash
# On a fresh EC2 with EIP + DNS A record for test-broker.${ZONE}
sudo bash scripts/setup-broker-host.sh \
  --issuer-url https://test-broker.${ZONE} \
  --account-id "${ACCOUNT_ID}" \
  --signer-host signer-test.${ZONE} \
  --audit-host audit-test.${ZONE} \
  --email-host email-test.${ZONE} \
  --cred-host cred-test.${ZONE} \
  --memory-host memory-test.${ZONE} \
  --vault-bucket "agentkeys-vault-test-${ACCOUNT_ID}" \
  --memory-bucket "agentkeys-memory-test-${ACCOUNT_ID}" \
  --email-from "noreply-test@bots-test.${ZONE}" \
  --yes
```

Idempotent: re-run after edits without manual rollback.

### 2. Provision the parallel AWS resources

The prod provisioning helpers (`scripts/provision-vault-{bucket,role}.sh`, `scripts/provision-memory-{bucket,role}.sh`, `scripts/apply-{vault,memory}-bucket-policy.sh`, `scripts/cleanup-mail-bucket-policy.sh`) all read bucket / role names from `scripts/operator-workstation.env`. For the test instance, point them at a test env file:

```bash
# Side-load the test env so the prod scripts pick up -test names
TEST_VAULT_BUCKET="agentkeys-vault-test-${ACCOUNT_ID}" \
TEST_MEMORY_BUCKET="agentkeys-memory-test-${ACCOUNT_ID}" \
TEST_VAULT_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-vault-role-test" \
TEST_MEMORY_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-memory-role-test" \
  bash scripts/provision-vault-bucket.sh && \
  bash scripts/provision-vault-role.sh && \
  bash scripts/apply-vault-bucket-policy.sh && \
  bash scripts/provision-memory-bucket.sh && \
  bash scripts/provision-memory-role.sh && \
  bash scripts/apply-memory-bucket-policy.sh
```

(If the prod scripts don't yet read these overrides, file a follow-up issue and copy the prod scripts as `-test` variants by hand until they do.)

### 3. Register the test OIDC provider in IAM

```bash
thumb=$(echo | openssl s_client -servername "test-broker.${ZONE}" \
                                 -connect "test-broker.${ZONE}:443" 2>/dev/null \
          | openssl x509 -fingerprint -noout \
          | awk -F'=' '{print $2}' | tr -d ':' | tr 'A-Z' 'a-z')

aws iam create-open-id-connect-provider \
  --url "https://test-broker.${ZONE}" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "$thumb"
```

### 4. Generate the test deployer wallet + fund it

```bash
mkdir -p ~/.agentkeys
cast wallet new --json \
  | tee /tmp/test-deployer.json \
  | jq -r .[0].private_key > ~/.agentkeys/heima-deployer-test.key
chmod 600 ~/.agentkeys/heima-deployer-test.key
# Then fund the address ($(jq -r .[0].address /tmp/test-deployer.json))
# from your personal Heima wallet — small float is enough for one-shot deploy.
```

### 5. Deploy the test contracts on Heima mainnet

Identical Solidity, identical `DeployAgentKeysV1.s.sol`, different deployer → new addresses on the production chain:

```bash
AGENTKEYS_CHAIN=heima \
HEIMA_DEPLOYER_KEY_FILE=~/.agentkeys/heima-deployer-test.key \
MAINNET_CONFIRM=1 \
  bash scripts/setup-heima.sh --from-step 4 --to-step 8
```

That walks steps 4–8: reuse the test key, fund-check, deploy, persist addresses, verify on-chain. Read off the six `*_HEIMA` addresses from the resulting `scripts/operator-workstation.env` for the next step.

### 6. Register the GitHub Actions OIDC role

Create one additional IAM role, `github-actions-agentkeys-e2e`, trust-policied on `token.actions.githubusercontent.com` with a condition limiting it to the agentkeys repo. Grant it `sts:AssumeRole` on the three test data roles and read-only S3 on the three test buckets.

### 7. Set the GitHub repo secrets

In **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `TEST_OIDC_AWS_ROLE_ARN` | `arn:aws:iam::${ACCT}:role/github-actions-agentkeys-e2e` (the gate) |
| `TEST_ACCOUNT_ID` | numeric AWS account ID (same account as prod is fine) |
| `TEST_AWS_REGION` | e.g. `us-east-1` |
| `TEST_BROKER_HOST` | `test-broker.${ZONE}` |
| `TEST_VAULT_BUCKET` | `agentkeys-vault-test-${ACCT}` |
| `TEST_MEMORY_BUCKET` | `agentkeys-memory-test-${ACCT}` |
| `TEST_VAULT_ROLE_ARN` | `arn:aws:iam::${ACCT}:role/agentkeys-vault-role-test` |
| `TEST_MEMORY_ROLE_ARN` | `arn:aws:iam::${ACCT}:role/agentkeys-memory-role-test` |
| `TEST_DATA_ROLE_ARN` | `arn:aws:iam::${ACCT}:role/agentkeys-data-role-test` |
| `TEST_HEIMA_DEPLOYER_KEY` | the 0x-prefixed test deployer private key from step 4 |
| `TEST_SCOPE_CONTRACT_ADDRESS_HEIMA` | from step 5 |
| `TEST_SIDECAR_REGISTRY_ADDRESS_HEIMA` | from step 5 |
| `TEST_K3_EPOCH_COUNTER_ADDRESS_HEIMA` | from step 5 |
| `TEST_CREDENTIAL_AUDIT_ADDRESS_HEIMA` | from step 5 |
| `TEST_P256_VERIFIER_ADDRESS_HEIMA` | from step 5 |
| `TEST_K11_VERIFIER_ADDRESS_HEIMA` | from step 5 |

`TEST_OIDC_AWS_ROLE_ARN` is the gate. Setting it last activates the workflow; unsetting it disarms.

## What the workflow does on every run

1. Restores submodules + Rust toolchain + Foundry + cargo cache.
2. **`rust-checks`** job: `cargo fmt --check` → `cargo clippy -- -D warnings` → `cargo test --workspace -- --test-threads=1` (the `--test-threads=1` matches the existing `@claude` review workflow because broker tests mutate `$HOME` / `AWS_*` env).
3. **`preflight`** job: gates on `TEST_OIDC_AWS_ROLE_ARN`.
4. **`harness-e2e`** job: assumes the test role via GitHub Actions OIDC (no long-lived secrets), writes the test deployer key, overwrites `scripts/operator-workstation.env` with TEST_* values, then runs:
   - `harness/v2-stage1-demo.sh --skip-deploy --skip-email` (contracts pre-deployed; identity via wallet_sig)
   - `harness/v2-stage2-demo.sh --stub --skip-build`
   - `harness/v2-stage3-demo.sh` (per-actor + per-data-class PrincipalTag isolation — the capstone that needs real AWS STS)
5. Per-run S3 prefix cleanup (`ci/run-${RUN_ID}/`) in an `if: always()` block.

## Per-run S3 prefix isolation

Concurrent runs (nightly + a manual dispatch) get a unique prefix via `CI_S3_PREFIX=ci/run-${GITHUB_RUN_ID}`. Per-job cleanup is best-effort; pair it with a nightly operator-side cron that sweeps `ci/` prefix keys older than 7 days from the test buckets.

## Manual dispatch

```bash
gh workflow run harness-ci.yml --field stage=3
```

`stage` accepts `1`, `2`, `3`, or `all`. Useful for re-running just stage-3 after a contract revision.

## Secret hygiene

No project credentials live in this doc. Every value above is either a placeholder (`${ACCT}`, `${ZONE}`) or an instruction to read from the operator's already-provisioned state ("from step 5"). The actual values live in two places only:

- The operator's local `scripts/operator-workstation.env` (gitignored copies / test variants only).
- The GitHub repo's encrypted secrets store.

Never paste a real account ID, role ARN, bucket name, deployer key, or contract address into a markdown doc, commit message, or PR description.

## Related

- Workflow file: [`.github/workflows/harness-ci.yml`](../.github/workflows/harness-ci.yml)
- Cloud / broker bring-up: [`docs/cloud-setup.md`](cloud-setup.md)
- Chain bring-up: [`docs/heima-setup.md`](heima-setup.md)
- Harness scripts: [`harness/v2-stage{1,2,3}-demo.sh`](../harness/)
- FAQ + troubleshooting: [`wiki/ci-setup-faq.md`](../wiki/ci-setup-faq.md)
