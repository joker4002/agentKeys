# Test environment — AgentKeys (issue #66)

**Audience:** the operator setting up CI for AgentKeys, plus contributors who need to debug a CI failure.
**Scope:** the parallel test infrastructure (broker, IAM roles, S3 buckets, deployer wallet, smart contracts) that exists alongside prod so CI can exercise the full code path without touching real user data.

This is the operator-facing companion to:
- [`.github/workflows/harness-ci.yml`](../.github/workflows/harness-ci.yml) — the tier-1 ephemeral CI workflow (no external infra)
- [`.github/workflows/harness-e2e.yml`](../.github/workflows/harness-e2e.yml) — the tier-2 nightly E2E workflow against the long-lived test broker
- [`harness/ci-ephemeral-stack.sh`](../harness/ci-ephemeral-stack.sh) — the ephemeral stack driver tier-1 invokes
- [`scripts/provision-test-environment.sh`](../scripts/provision-test-environment.sh) — operator-run, one-shot provisioner for the tier-2 long-lived infra
- [`scripts/test-environment.env.example`](../scripts/test-environment.env.example) — env file template

## Two-tier model

Issue #66 calls for a CI that runs the harness scripts against a parallel test environment, never spends LLM tokens, and never invokes WebAuthn. There are two natural points to do that, and we ship both:

| | Tier 1 — ephemeral | Tier 2 — long-lived |
|---|---|---|
| **Workflow** | `harness-ci.yml` | `harness-e2e.yml` |
| **Trigger** | every push + PR | nightly + manual dispatch |
| **Where** | inside a GitHub Actions runner | runs against `test-broker.litentry.org` |
| **Chain** | `anvil` (fresh per run, instant finality) | Heima-Paseo testnet (long-lived contracts) |
| **Deployer** | anvil's prefunded default test key (zero risk) | a separate Paseo wallet, funded by operator, persisted at `~/.agentkeys/heima-paseo-deployer-test.key` |
| **Contracts** | fresh deploy per run via Foundry | deployed once by `provision-test-environment.sh`, addresses pinned in `scripts/test-environment.env` |
| **Broker** | in-process spawn, OIDC issuer = `http://127.0.0.1:8091`, `StubSts` | real broker process on test EC2, OIDC issuer = `https://test-broker.litentry.org`, real AWS STS |
| **AWS** | none — broker boots with `--skip-startup-check`, no STS/S3 calls | real test bucket + real test role; AWS STS `AssumeRoleWithWebIdentity` works because the test broker exposes a public TLS-fronted JWKS endpoint |
| **WebAuthn** | never — harness defaults to `WEBAUTHN_MODE=0` stub mode | never — same default |
| **LLM** | never | never |
| **Wall time** | ~10–15 min | ~25–40 min |

Tier 1 catches almost all regressions because the Rust integration tests (`cargo test --workspace`) already spawn an in-process broker with `StubSts` + `StubEmailSender` — those tests cover SIWE auth, OIDC mint, cap-token verification, multi-master, recovery, and per-data-class isolation logic. What tier 1 *can't* cover is the real-AWS path: stage 3's `AssumeRoleWithWebIdentity` requires AWS to fetch the issuer's JWKS over public TLS, which an ephemeral CI runner can't expose. That's the tier-2 capstone.

## Tier 1 — ephemeral CI (no operator setup needed)

Already wired. Every push to `main` or `evm`, plus every PR touching `crates/**` / `harness/**` / `scripts/**`, runs:

1. `cargo fmt --check`
2. `cargo clippy --workspace --all-targets -- -D warnings`
3. `cargo test --workspace -- --test-threads=1`
4. `bash harness/ci-ephemeral-stack.sh`, which:
   - Starts a fresh `anvil` on port 8545 (new chain, instant finality)
   - Runs `forge build && forge test` in `crates/agentkeys-chain/`
   - Runs `forge script DeployAgentKeysV1.s.sol` to deploy all 6 contracts to the ephemeral anvil
   - Parses the deployed addresses and writes a synthetic `operator-workstation.env`
   - Runs `scripts/verify-heima-contracts.sh` against the new addresses (read-only ABI + wiring checks)
   - Starts `mock-server` + `agentkeys-broker-server` (with `--skip-startup-check`, OIDC issuer = `http://127.0.0.1:8091`)
   - Probes `/healthz`, `/.well-known/openid-configuration`, `/.well-known/jwks.json`

On failure, the script's EXIT trap preserves all logs (`anvil.log`, `forge-deploy.log`, `broker.log`, etc.) and the workflow uploads them as a `ephemeral-stack-logs` artifact.

## Tier 2 — long-lived test broker

### Operator bring-up (~2 hours, one-shot)

```bash
awsp agentkeys-admin            # AWS admin profile for the account hosting test infra
bash scripts/provision-test-environment.sh
```

This walks through 7 steps:

1. **Provision the EC2 broker host** at `test-broker.litentry.org`. Manual step (the runbook fragment in the script tells you exactly what to do on the target EC2).
2. **Register the AWS IAM OIDC provider** for `test-broker.litentry.org` (separate ARN from prod's `oidc-provider/broker.litentry.org`).
3. **Provision IAM roles** `agentkeys-data-role-test`, `agentkeys-vault-role-test`, `agentkeys-memory-role-test`, each trust-policied on the test OIDC provider with the same `PrincipalTag/agentkeys_actor_omni` scoping prod uses.
4. **Provision S3 buckets** `agentkeys-mail-test-${ACCT}`, `agentkeys-vault-test-${ACCT}`, `agentkeys-memory-test-${ACCT}` with block-public-access + default SSE-S3 + the v3 split-statement PrincipalTag bucket policy.
5. **Generate a new deployer wallet** (distinct from the prod deployer) at `~/.agentkeys/heima-paseo-deployer-test.key`. You fund it from your personal Paseo wallet (Paseo has sudo so Alice can also fund — see `scripts/heima-bring-up.sh`).
6. **Deploy fresh v2 stage-1 contracts** to Heima-Paseo via `DeployAgentKeysV1.s.sol`. Records the addresses under `*_HEIMA_PASEO` keys in `scripts/test-environment.env`.
7. **Provision a GitHub Actions OIDC role** (`github-actions-agentkeys-e2e`) trust-policied on `token.actions.githubusercontent.com` with a condition limiting it to the agentkeys repo. Grant it `sts:AssumeRole` on the three test roles + read-only S3 on the three test buckets.

Some steps are still operator-manual (parameterizing `provision-vault-role.sh` to accept a `SUFFIX=` env var is a TODO; until then, copy the prod scripts as `-test` variants by hand). The script logs these as `skip` with a follow-up TODO instead of silently passing.

### Repo secrets to set (after provisioning)

After the provisioner finishes, set these in **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `TEST_OIDC_AWS_ROLE_ARN` | `arn:aws:iam::${ACCT}:role/github-actions-agentkeys-e2e` |
| `TEST_AWS_REGION` | `us-east-1` (or wherever the test broker lives) |
| `TEST_ACCOUNT_ID` | `${ACCT}` |
| `TEST_BROKER_HOST` | `test-broker.litentry.org` |
| `TEST_VAULT_BUCKET` | `agentkeys-vault-test-${ACCT}` |
| `TEST_MEMORY_BUCKET` | `agentkeys-memory-test-${ACCT}` |
| `TEST_VAULT_ROLE_ARN` | `arn:aws:iam::${ACCT}:role/agentkeys-vault-role-test` |
| `TEST_MEMORY_ROLE_ARN` | `arn:aws:iam::${ACCT}:role/agentkeys-memory-role-test` |
| `TEST_DATA_ROLE_ARN` | `arn:aws:iam::${ACCT}:role/agentkeys-data-role-test` |

`TEST_OIDC_AWS_ROLE_ARN` is the **gate**: until it's set, the `harness-e2e.yml` preflight job sets `should_run=false` and the workflow surfaces as a `::warning::` skip rather than a failure. This keeps the workflow safe to merge before the parallel infra is up.

### Per-run S3 prefix namespacing

The e2e workflow exports `CI_S3_PREFIX=ci/run-${GITHUB_RUN_ID}` and the harness scripts honor that prefix when writing test envelopes to S3. This means concurrent runs (nightly + a manual dispatch) won't step on each other's writes.

Cleanup is two-layered:
- **Per-job cleanup**: the e2e workflow's `if: always()` step runs `aws s3 rm s3://$bucket/$PREFIX --recursive` at the end of each run.
- **Nightly sweep**: a separate `nightly-prefix-cleanup` job lists `ci/` prefix keys older than 7 days and rm's them. Cheap insurance against forgotten prefixes from cancelled runs.

### Cert renewal monitoring

`test-broker.litentry.org` uses Let's Encrypt (auto-renewed every 90d by certbot). If renewal silently fails, AWS STS stops trusting the OIDC issuer and the e2e workflow turns red overnight.

The nightly workflow's preflight already exercises a `curl` against `https://${TEST_BROKER_HOST}/.well-known/openid-configuration`. A renewal failure surfaces as an immediate workflow failure with a clear TLS error.

### Rotating the test broker secrets

If the test mock-server's `DEV_KEY_SERVICE_MASTER_SECRET` ever leaks, rotate via:

```bash
# 1. New secret on the broker host
ssh ec2-user@test-broker.litentry.org \
  'sudo systemctl set-environment DEV_KEY_SERVICE_MASTER_SECRET=$(openssl rand -hex 32) \
   && sudo systemctl restart agentkeys-backend'

# 2. There's nothing on the operator side to rotate — the secret never
#    leaves the broker host (it derives per-omni signer keys in-process).
```

Test wallets minted via the rotated signer will have different addresses from pre-rotation wallets, which is the desired blast-radius cut.

## Cleanup / teardown

Tear down the entire test environment (cheap insurance if costs spike):

```bash
# Drain the buckets first
for bucket in agentkeys-mail-test-${ACCT} agentkeys-vault-test-${ACCT} agentkeys-memory-test-${ACCT}; do
  aws s3 rm "s3://$bucket" --recursive
  aws s3api delete-bucket --bucket "$bucket"
done

# Delete the roles (detach policies first)
for role in agentkeys-data-role-test agentkeys-vault-role-test agentkeys-memory-role-test github-actions-agentkeys-e2e; do
  for policy in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$policy"
  done
  aws iam delete-role --role-name "$role"
done

# Delete the OIDC provider
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::${ACCT}:oidc-provider/test-broker.litentry.org

# Stop + terminate the EC2 + release the EIP (manual, console or aws ec2 CLI)
```

The contracts on Heima-Paseo stay on chain (they're free), but they're inert without the broker pointing at them.

## Why two tiers (vs. just one)

A single-tier model — running everything against the long-lived broker on every PR — was the obvious shape, but loses on:

- **Latency**: every PR pays the ~30 min e2e wall time (vs. ~10 min for tier 1).
- **Cost**: every PR hits real AWS API calls + chain RPC + potentially gas.
- **Contention**: concurrent PRs serialize on the single test broker, or step on each other's S3 writes without per-run prefix isolation.
- **Brittleness**: a flaky external dep (Paseo collator hiccup, AWS API throttle) blocks merges.

A single-tier model the other way — only ephemeral CI, no long-lived test broker — was also tempting, but loses stage-3 coverage entirely (`AssumeRoleWithWebIdentity` needs publicly-fetchable JWKS). That's the most security-critical layer in the codebase (per-actor + per-data-class IAM isolation per CLAUDE.md "Per-actor + per-data-class isolation invariants"), so leaving it untested in CI was unacceptable.

The two-tier split puts the fast, cheap, deterministic checks on every PR and the expensive E2E on nightly. PRs that need to verify a stage-3 fix can trigger `harness-e2e.yml` via `workflow_dispatch` directly from the PR page.

## Related

- Original issue: [#66 — Stage 7: shared test broker for CI + dev](https://github.com/wildmeta-agent/agentKeys/issues/66)
- Prod cloud setup: [`docs/cloud-setup.md`](cloud-setup.md)
- Stage 7 demo + verification: [`docs/stage7-demo-and-verification.md`](stage7-demo-and-verification.md)
- Architecture: [`docs/spec/architecture.md`](spec/architecture.md) §17 (per-data-class buckets), §4 (HDKD actor tree), CLAUDE.md "Per-actor + per-data-class isolation invariants" table
