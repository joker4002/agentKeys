# CI setup — AgentKeys

**Audience:** the operator activating the no-LLM CI workflow against a test instance of the production environment.
**Scope:** one workflow file ([`.github/workflows/harness-ci.yml`](../.github/workflows/harness-ci.yml)), a list of GitHub secrets, and the test-side counterparts of the production resources from [`docs/cloud-bootstrap.md`](cloud-bootstrap.md) + [`docs/chain-setup.md`](chain-setup.md).
**FAQ + troubleshooting:** [`wiki/ci-setup-faq.md`](../wiki/ci-setup-faq.md).

## Where things run

The GitHub Actions runner is **only the operator** — it builds the `agentkeys` CLI, writes a per-run `scripts/operator-workstation.env`, then drives HTTP calls to the persistent test broker. The runner does NOT host any AgentKeys services.

| Component | Lives on | Lifetime |
|---|---|---|
| Operator (drives harness scripts) | GitHub Actions `ubuntu-latest` runner | per-run (ephemeral) |
| Test broker + signer + 4 workers + nginx + certbot | dedicated EC2 at `test-broker.${ZONE}` | long-lived |
| Test contracts on Heima mainnet | Heima mainnet (same chain as prod, isolated addresses) | one-shot deploy per test-env refresh |
| AWS IAM + S3 test resources (`*-test` suffix) | same AWS account as prod | long-lived (one-shot provisioned) |

The runner reaches the broker via public DNS exactly the way your laptop does today — no SSH tunnel, no port-forward. AWS STS reaches the broker the same way to fetch its JWKS for `AssumeRoleWithWebIdentity`.

This mirrors the prod operator's mental model exactly: prod-operator + prod-broker EC2 ↔ CI-operator + test-broker EC2. The harness scripts don't change between the two paths; only `scripts/operator-workstation.env` does.

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

## CI activation — what comes AFTER `setup-broker-host.sh` succeeds

**Prereq:** the test stack from [`docs/cloud-bootstrap.md` quick start](cloud-bootstrap.md#quick-start--five-steps-to-a-running-stack) steps 1–5 is complete — `setup-cloud.sh --test` ran clean, the test EC2 is up at `test-broker.${ZONE}`, and `setup-broker-host.sh` finished on the box (broker + signer + 4 workers + nginx + certbot all running).

Running `bash scripts/setup-heima.sh` alone is **not enough** for CI. Five more steps:

### 1. Activate OIDC federation for the test broker

The broker is reachable, but AWS STS doesn't trust its JWTs yet. Follow [`docs/cloud-bootstrap.md` §9](cloud-bootstrap.md#9-oidc-federation-activation-after-broker-is-publicly-reachable) — register the test OIDC provider in IAM (separate ARN from prod's), swap the three `*-role-test` trust policies to the federated variant, apply PrincipalTag-scoped bucket policies.

```bash
# Quick form (full explanation in cloud-bootstrap.md §9):
export BROKER_HOST=test-broker.${ZONE}
export ACCOUNT_ID=429071895007

thumb=$(echo | openssl s_client -servername "$BROKER_HOST" -connect "$BROKER_HOST:443" 2>/dev/null \
        | openssl x509 -fingerprint -noout | awk -F'=' '{print $2}' | tr -d ':' | tr 'A-Z' 'a-z')

AWS_PROFILE=agentkeys-admin aws iam create-open-id-connect-provider \
  --url "https://$BROKER_HOST" \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list "$thumb"

# Then swap each role's trust policy to the OIDC-federated variant
# (see cloud-bootstrap.md §9.3 for the jq policy body — applies to
# agentkeys-data-role-test, agentkeys-vault-role-test, agentkeys-memory-role-test).
```

Verify with `harness/v2-stage3-demo.sh` — it mints session JWT → OIDC JWT → STS creds and runs the cross-actor isolation matrix.

### 2. Generate + fund the test deployer wallet

Single fresh EVM wallet — its `(deployer, nonce)` is what makes test contracts land at different addresses on the same Heima mainnet.

```bash
mkdir -p ~/.agentkeys
umask 077
cast wallet new --json | tee /tmp/test-deployer.json \
  | jq -r '.[0].private_key' > ~/.agentkeys/heima-deployer-test.key
chmod 600 ~/.agentkeys/heima-deployer-test.key

# Print the address so you can fund it:
jq -r '.[0].address' /tmp/test-deployer.json
# → 0x…  ← send a small float of HEI from your personal wallet
#         (deploy gas only — ~0.5 HEI is plenty for the 6 contracts).
```

### 3. Deploy test contracts via `setup-heima.sh`

With the key in place + funded, the orchestrator handles the deploy + persists addresses back to the operator env file. **`HEIMA_DEPLOYER_KEY_FILE` is the override** — without it, the script falls back to `~/.agentkeys/heima-deployer.key` (your prod key) and step 6's `cast code` idempotency check sees prod contracts already exist, so nothing new deploys.

```bash
HEIMA_DEPLOYER_KEY_FILE=~/.agentkeys/heima-deployer-test.key \
MAINNET_CONFIRM=1 \
  bash scripts/setup-heima.sh --from-step 4 --to-step 8
```

That walks 4 (reuse the test key) → 5 (fund check) → 6 (deploy 6 contracts) → 7 (write `*_HEIMA` addresses back to `operator-workstation.env`) → 8 (read-only RPC verify). For the test instance, source `operator-workstation.test.env` first so the addresses land in the test env file:

```bash
ENV_FILE=scripts/operator-workstation.test.env \
HEIMA_DEPLOYER_KEY_FILE=~/.agentkeys/heima-deployer-test.key \
MAINNET_CONFIRM=1 \
  bash scripts/setup-heima.sh --from-step 4 --to-step 8
```

After this completes, the six `*_HEIMA` addresses in `operator-workstation.test.env` are the NEW test contract addresses (different from prod).

### 4. Register the GitHub Actions OIDC role

One additional IAM role, `github-actions-agentkeys-e2e`. Trust policy: federated on `token.actions.githubusercontent.com` with a `sub` condition pinning to the `litentry/agentKeys` repo. Inline policy: `sts:AssumeRole` on the three test data roles + read-only S3 on the three test buckets.

```bash
AWS_PROFILE=agentkeys-admin aws iam create-role \
  --role-name github-actions-agentkeys-e2e \
  --assume-role-policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Federated:"arn:aws:iam::\($acct):oidc-provider/token.actions.githubusercontent.com"},
      Action:"sts:AssumeRoleWithWebIdentity",
      Condition:{
        StringEquals:{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"},
        StringLike:{"token.actions.githubusercontent.com:sub":"repo:litentry/agentKeys:*"}
      }
    }]
  }')"

# Then inline policy granting AssumeRole on the test data roles:
AWS_PROFILE=agentkeys-admin aws iam put-role-policy \
  --role-name github-actions-agentkeys-e2e \
  --policy-name agentkeys-e2e-assume-test-roles \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Action:"sts:AssumeRole",
      Resource:[
        "arn:aws:iam::\($acct):role/agentkeys-data-role-test",
        "arn:aws:iam::\($acct):role/agentkeys-vault-role-test",
        "arn:aws:iam::\($acct):role/agentkeys-memory-role-test"
      ]
    }]
  }')"
```

If the GitHub OIDC provider doesn't exist in the account yet, `aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1` creates it (one-time).

### 5. Set the GitHub repo secrets

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
- Cloud / broker bring-up: [`docs/cloud-bootstrap.md`](cloud-bootstrap.md)
- Chain bring-up: [`docs/chain-setup.md`](chain-setup.md)
- Harness scripts: [`harness/v2-stage{1,2,3}-demo.sh`](../harness/)
- FAQ + troubleshooting: [`wiki/ci-setup-faq.md`](../wiki/ci-setup-faq.md)
