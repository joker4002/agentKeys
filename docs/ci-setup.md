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
| S3 buckets | `agentkeys-{mail,vault,memory}-${ACCOUNT_ID}` | `agentkeys-{mail,vault,memory}-test-${ACCOUNT_ID}` |
| Chain | Heima mainnet | **Heima mainnet** (same chain, different deployer → different addresses) |
| Deployer wallet | operator's prod deployer | dedicated test wallet (small HEI float) |
| Contracts | one production deploy | one test deploy with **identical `.sol` source** → new addresses |
| WebAuthn | real Touch ID | never (`WEBAUTHN_MODE=0`) |
| LLM | (separate `claude.yml` review) | never |

**Same code, same chain, isolated storage.** EVM addresses derive from `(deployer, nonce)` and Solidity compiles deterministically — a different deployer key with the same source files produces a parallel contract set that can't see or write to prod contract state.

## CI activation — what comes AFTER `setup-broker-host.sh` succeeds

**Prereq:** the test stack from [`docs/cloud-bootstrap.md` quick start](cloud-bootstrap.md#quick-start--five-steps-to-a-running-stack) **steps 1–5b** is complete — `setup-cloud.sh --test` ran clean, the test EC2 is up at `test-broker.<your-zone>` with SG ports 22 + 80 + 443 all open, `setup-broker-host.sh` finished on the box (broker + signer + 4 workers + nginx running), AND **`certbot` has issued certs for all 6 test hostnames + nginx has been flipped onto `:443`** ([`docs/cloud-bootstrap.md` §5b](cloud-bootstrap.md#5b-issue-tls-certs--flip-nginx-onto-443)).

Running `bash scripts/setup-heima.sh` alone is **not enough** for CI. Five more steps below.

### Shell setup before you start (every command block below runs on your LAPTOP)

Source the test env file so `${ZONE}` / `${ACCOUNT_ID}` / `${BROKER_HOST}` etc. resolve in your shell. Every command block in this doc runs from the operator's **laptop** unless explicitly noted; the broker host doesn't need any of these env vars set in the operator's shell (the broker process gets its config via systemd `Environment=` lines).

```bash
awsp agentkeys-admin
set -a; source scripts/operator-workstation.test.env; set +a
# Confirm the test values are in your shell:
echo "ACCOUNT_ID=$ACCOUNT_ID  ZONE=$ZONE  BROKER_HOST=$BROKER_HOST"
# → ACCOUNT_ID=429071895007  ZONE=litentry.org  BROKER_HOST=test-broker.litentry.org
```

If `${ZONE}` echoes empty, the env file isn't sourced — re-run the `set -a; source …; set +a` line.

### Sanity-check: broker is serving TLS with a real cert

Before §1 (which extracts the cert thumbprint), verify the broker is actually serving HTTPS — otherwise the openssl pipeline gets empty stdin and dies with the cryptic `unable to load certificate / Expecting: TRUSTED CERTIFICATE` error.

**Use DoH for the DNS lookup** — laptop `dig` may be intercepted by Cloudflare WARP / Zscaler / Tailscale that rewrites `litentry.org` to `198.18.x.y` for tunnel routing. DoH bypasses that:

```bash
# Public IP that Let's Encrypt + AWS STS will actually hit:
broker_ip=$(curl -sS "https://dns.google/resolve?name=${BROKER_HOST}&type=A" | jq -r '.Answer[0].data')
echo "${BROKER_HOST} resolves publicly to $broker_ip"
# → e.g. 3.214.219.209 — NOT 198.18.x.y. If you see 198.18.x.y here, your VPN
#   is mis-routing the response (DoH should be immune; retry from a different network).

# TLS handshake against the real EIP, bypassing local DNS:
echo | openssl s_client -servername "${BROKER_HOST}" -connect "${broker_ip}:443" 2>&1 \
  | grep -E '(subject=|verify return code)'
# Expected:
#   depth=0 CN = ${BROKER_HOST}
#   verify return code: 0 (ok)
#   subject=/CN=${BROKER_HOST}
```

If `subject=` echoes empty or `openssl s_client` prints `no peer certificate available`, the broker doesn't have a TLS cert yet — go back to [`docs/cloud-bootstrap.md` §5b](cloud-bootstrap.md#5b-issue-tls-certs--flip-nginx-onto-443) and run certbot + re-run `setup-broker-host.sh` to flip nginx onto `:443`. Then re-run this sanity-check before continuing to §1 below.

### 1. Activate OIDC federation for the test broker

The broker is reachable, but AWS STS doesn't trust its JWTs yet. Follow [`docs/cloud-bootstrap.md` §9](cloud-bootstrap.md#9-oidc-federation-activation-after-broker-is-publicly-reachable) — register the test OIDC provider in IAM (separate ARN from prod's), swap the three `*-role-test` trust policies to the federated variant, apply PrincipalTag-scoped bucket policies.

```bash
# Quick form (full explanation in cloud-bootstrap.md §9). $BROKER_HOST +
# $ACCOUNT_ID come from the env file sourced in the "Shell setup" step above.
# $broker_ip carries over from the sanity-check above (DoH-resolved EIP,
# immune to laptop DNS interception). If your shell lost it: re-run
#   broker_ip=$(curl -sS "https://dns.google/resolve?name=${BROKER_HOST}&type=A" | jq -r '.Answer[0].data')

thumb=$(echo | openssl s_client -servername "$BROKER_HOST" -connect "${broker_ip}:443" 2>/dev/null \
        | openssl x509 -fingerprint -sha1 -noout \
        | awk -F'=' '{print $2}' | tr -d ':' | tr 'A-Z' 'a-z')
[ -n "$thumb" ] || { echo "thumbprint empty — broker has no TLS cert; see cloud-bootstrap.md §5b" >&2; return 1; }
[ ${#thumb} -eq 40 ] || { echo "thumb length ${#thumb} != 40 — openssl emitted non-SHA1 fingerprint; check -sha1 flag is present" >&2; return 1; }
echo "thumb=$thumb"

# IMPORTANT: -sha1 is required. macOS LibreSSL 3.3 (and OpenSSL 3.x on some
# Linux distros) default `openssl x509 -fingerprint` to SHA256 → 64 hex chars,
# but AWS IAM CreateOpenIDConnectProvider rejects anything that isn't exactly
# 40 hex chars (SHA1). Pinning -sha1 makes the recipe portable across the
# operator's openssl version.

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

**Option A (fresh wallet, recommended for clean test isolation):**

```bash
mkdir -p ~/.agentkeys
umask 077
cast wallet new --json \
  | jq -r '.[0].private_key' > ~/.agentkeys/heima-deployer-test.key
chmod 600 ~/.agentkeys/heima-deployer-test.key

# Print the address so you can fund it (works for both Option A and B —
# derives the address from the saved priv key, no /tmp/*.json dependency):
cast wallet address $(cat ~/.agentkeys/heima-deployer-test.key)
# → 0x…  ← send a small float of HEI from your personal wallet
#         (deploy gas only — ~0.5 HEI is plenty for the 6 contracts).
```

**Option B (re-use an existing mnemonic):** if you already have a BIP39 mnemonic (hardware wallet, MetaMask seed, previous deploy you want to redeploy from), derive the deployer key from it:

```bash
# Interactive (mnemonic input is hidden — not in shell history):
bash scripts/heima-deployer-from-mnemonic.sh --test

# Or read from a file (more secure than CLI when scripting):
bash scripts/heima-deployer-from-mnemonic.sh --test --mnemonic-file /path/to/mnemonic.txt

# Print the address for funding:
cast wallet address $(cat ~/.agentkeys/heima-deployer-test.key)
```

The script defaults to derivation path `m/44'/60'/0'/0/0` (standard Ethereum BIP-44); pass `--index N` for a different address index. Idempotent — re-running with the same mnemonic prints `skip already-matches`; re-running with a different mnemonic refuses to overwrite (the existing key may own live deployed contracts).

### 3. Deploy test contracts via `setup-heima.sh`

The orchestrator owns idempotency via TWO inputs that must both point at the TEST stack — otherwise step 6's `cast code` idempotency check fires against prod's addresses and silently skips the test deploy:

| Input | Where to set | What it controls |
|---|---|---|
| **`--test` flag** (or `--env-file scripts/operator-workstation.test.env`) | CLI on `setup-heima.sh` | Which env file the orchestrator + every helper (`heima-bring-up.sh`, `verify-heima-contracts.sh`) reads `*_HEIMA` from for the skip-deploy check AND writes the freshly-deployed addresses back to (via `env_set` in step 6). |
| **`HEIMA_DEPLOYER_KEY_FILE`** | env var | Which deployer wallet signs the deploy tx. Different deployer → different `(deployer, nonce)` → different on-chain addresses than prod. |

```bash
HEIMA_DEPLOYER_KEY_FILE=~/.agentkeys/heima-deployer-test.key \
MAINNET_CONFIRM=1 \
  bash scripts/setup-heima.sh --test --from-step 4 --to-step 8
```

The orchestrator prints a banner at the top so you can confirm the stack before any tx fires:

```
=== AgentKeys Heima setup: chain=heima session=alice ===
  stack:    TEST
  env_file: …/scripts/operator-workstation.test.env
  steps 4..8 (of 15)
```

If `stack: PROD` appears here while you intended a test deploy — STOP. You're about to clobber prod's contract pointers. Re-run with `--test`.

That walks step 4 (reuse the test key) → 5 (fund check; mainnet path just balance-checks, prints manual recipe if the test deployer is low) → 6 (deploy 6 contracts using the test deployer) → 7 (write the NEW `*_HEIMA` addresses back to `operator-workstation.test.env`) → 8 (read-only RPC verify against the just-written addresses). After this completes, the six `*_HEIMA` addresses in `operator-workstation.test.env` are the NEW test contract addresses — different from prod's, isolated by trust scope.

> **Each redeploy yields fresh addresses.** EVM `CREATE` derives the contract address from `keccak256(rlp(deployer, nonce))`, so re-running step 6 advances the deployer's nonce and produces a brand-new set. Always copy the `*_HEIMA` values that land in `operator-workstation.test.env` after the run — never cache addresses from an earlier session.

**Equivalent forms (all three work; pick whichever fits your shell habits):**

```bash
# Form 1: --test ergonomic flag (RECOMMENDED — shortest)
bash scripts/setup-heima.sh --test ...

# Form 2: explicit --env-file
bash scripts/setup-heima.sh --env-file scripts/operator-workstation.test.env ...

# Form 3: ENV_FILE env var (useful when scripting across multiple commands)
ENV_FILE=scripts/operator-workstation.test.env bash scripts/setup-heima.sh ...
```

Precedence when more than one is set: `--env-file` > `$ENV_FILE` > `--test` (auto-derives to `.test.env`) > default (`operator-workstation.env`).

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

# Second inline policy: S3 perms on the test buckets so the harness verify
# steps (head-object after store, ls during cleanup) work from the runner's
# direct creds without re-assuming a worker role.
#
# Codex M3 mitigation (2026-05-23): the policy is split into two statements
# so s3:DeleteObject is scoped to `bots/*` only — the worker write path the
# harness exercises. Previously DeleteObject was granted on the entire
# bucket, which meant a typo or compromised step in the workflow cleanup
# (`aws s3 rm s3://$bucket/...`) could nuke any object in the bucket.
# Now: read-only verify (List/Get/Head) stays bucket-wide because those
# operations need to inspect anywhere the workers might have written; but
# Delete is constrained to the harness's own write path, so the worst a
# bad cleanup invocation can do is wipe its own test data.
AWS_PROFILE=agentkeys-admin aws iam put-role-policy \
  --role-name github-actions-agentkeys-e2e \
  --policy-name agentkeys-e2e-verify-s3 \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[
      {
        Sid:"VerifyReadOnlyTestBuckets",
        Effect:"Allow",
        Action:["s3:ListBucket","s3:GetObject","s3:HeadObject"],
        Resource:[
          "arn:aws:s3:::agentkeys-vault-test-\($acct)",
          "arn:aws:s3:::agentkeys-vault-test-\($acct)/*",
          "arn:aws:s3:::agentkeys-memory-test-\($acct)",
          "arn:aws:s3:::agentkeys-memory-test-\($acct)/*",
          "arn:aws:s3:::agentkeys-mail-test-\($acct)",
          "arn:aws:s3:::agentkeys-mail-test-\($acct)/*"
        ]
      },
      {
        Sid:"CleanupTestBucketsBotsPrefixOnly",
        Effect:"Allow",
        Action:["s3:DeleteObject"],
        Resource:[
          "arn:aws:s3:::agentkeys-vault-test-\($acct)/bots/*",
          "arn:aws:s3:::agentkeys-memory-test-\($acct)/bots/*",
          "arn:aws:s3:::agentkeys-mail-test-\($acct)/bots/*"
        ]
      }
    ]
  }')"
```

If the GitHub OIDC provider doesn't exist in the account yet, `aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1` creates it (one-time).

### 5. Set the GitHub repo secrets

**One-shot recipe (recommended)** — runs `gh secret set` for all 17 values, reading from `operator-workstation.test.env` + the deployer key file:

```bash
# Preview first:
bash scripts/ci-set-github-secrets.sh --dry-run

# Apply (idempotent — replaces existing values silently):
bash scripts/ci-set-github-secrets.sh
```

The script's sanity check refuses to run if any `*_HEIMA` slot is still zeroed (forces you to complete step 3's deploy first), masks the deployer private key in its output, and sets `TEST_OIDC_AWS_ROLE_ARN` last (the gate). Pass `--skip-gate` to populate everything except the activator if you want to wire the role ARN manually later.

**Manual path** — if you'd rather click through, the destination is **Settings → Secrets and variables → Actions → Repository secrets** (NOT "Environments" — `harness-ci.yml` doesn't declare an `environment:` and looks up secrets at the repo level; if you're on the "Add environment" page asking for a name, you're on the wrong page, click "Secrets and variables → Actions" in the left sidebar instead):

| Secret | Value |
|---|---|
| `TEST_OIDC_AWS_ROLE_ARN` | `arn:aws:iam::${ACCOUNT_ID}:role/github-actions-agentkeys-e2e` (the gate) |
| `TEST_ACCOUNT_ID` | numeric AWS account ID (same account as prod is fine) |
| `TEST_AWS_REGION` | e.g. `us-east-1` |
| `TEST_BROKER_HOST` | `test-broker.${ZONE}` |
| `TEST_VAULT_BUCKET` | `agentkeys-vault-test-${ACCOUNT_ID}` |
| `TEST_MEMORY_BUCKET` | `agentkeys-memory-test-${ACCOUNT_ID}` |
| `TEST_VAULT_ROLE_ARN` | `arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-vault-role-test` |
| `TEST_MEMORY_ROLE_ARN` | `arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-memory-role-test` |
| `TEST_DATA_ROLE_ARN` | `arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role-test` |
| `TEST_HEIMA_DEPLOYER_KEY` | the 0x-prefixed test deployer private key from step 4 |
| `TEST_SCOPE_CONTRACT_ADDRESS_HEIMA` | from step 5 |
| `TEST_SIDECAR_REGISTRY_ADDRESS_HEIMA` | from step 5 |
| `TEST_K3_EPOCH_COUNTER_ADDRESS_HEIMA` | from step 5 |
| `TEST_CREDENTIAL_AUDIT_ADDRESS_HEIMA` | from step 5 |
| `TEST_P256_VERIFIER_ADDRESS_HEIMA` | from step 5 |
| `TEST_K11_VERIFIER_ADDRESS_HEIMA` | from step 5 |

`TEST_OIDC_AWS_ROLE_ARN` is the gate. Setting it last activates the workflow; unsetting it disarms.

### 6. Trigger the first run + verify

Setup is done. Confirm the pipeline actually works end-to-end.

**Pre-merge (PR branch — what's true today):** the workflow auto-fires on every push to a branch with an open PR against `main`. The `pull_request:` trigger watches the path filter `crates/**`, `harness/**`, `scripts/**`, `.github/workflows/harness-ci.yml`, `Cargo.toml`, and `Cargo.lock` — push any qualifying change and the run kicks off automatically:

```bash
# List recent runs on your branch:
gh run list --workflow harness-ci.yml --repo litentry/agentKeys \
  --branch <your-branch> --limit 5

# Drill into a specific run's failing step:
gh run view <run-id> --repo litentry/agentKeys --log-failed
```

**Post-merge (after this PR lands on `main`):** `workflow_dispatch` becomes available — GitHub registers workflows from the default branch, so manual dispatch only works once `harness-ci.yml` is on `main`. From then on you can re-run any stage on demand:

```bash
gh workflow run harness-ci.yml --repo litentry/agentKeys --field stage=3
```

`stage` accepts `1`, `2`, `3`, or `all`. Stage 3 is the capstone — it mints session JWT → OIDC JWT → STS creds via the test broker, then exercises the per-actor + per-data-class isolation matrix against real AWS IAM. Stage 3 passing means every layer is wired: TLS + OIDC + IAM federation + S3 PrincipalTag scoping + cap-mint + worker chain-verify.

> **`gh workflow run` returns `Workflow does not have 'workflow_dispatch' trigger`** before the PR merges. That's not a bug in the workflow YAML on your branch — it's GitHub's "workflows are registered from the default branch" rule. Use the `pull_request:` auto-trigger above until merge; after merge, `workflow_dispatch` works.

**Common first-run failure modes:**

| Symptom | Likely cause | Fix |
|---|---|---|
| `cargo fmt --all -- --check` fails with a long diff | accumulated rustfmt drift on `main` from pre-existing code | Run `cargo fmt --all` locally, commit the result as a separate "style: cargo fmt" commit; once it lands, the workspace stays clean. |
| `harness-e2e` job skipped with `::warning::` | `TEST_OIDC_AWS_ROLE_ARN` secret not set | Re-run [§5](#5-set-the-github-repo-secrets) (or `bash scripts/ci-set-github-secrets.sh` without `--skip-gate`). |
| `AssumeRoleWithWebIdentity: AccessDenied` | `github-actions-agentkeys-e2e` role's trust policy `sub` condition doesn't match `repo:litentry/agentKeys:*` | Re-check [§4](#4-register-the-github-actions-oidc-role)'s trust policy JSON; the `StringLike` on `sub` must match the repo path. |
| stage 1 fails on `cast` deploy | runner's contract addresses are zeros | The `TEST_*_ADDRESS_HEIMA` secrets are unset or stale — re-check [§5](#5-set-the-github-repo-secrets). |
| stage 3 fails on `s3:ListBucket → AccessDenied` cross-actor | `apply-vault-bucket-policy.sh` / `apply-memory-bucket-policy.sh` were applied to PROD buckets, not the `-test` variants | Re-run those scripts with `ENV_FILE=scripts/operator-workstation.test.env`. |

When the workflow passes against the test stack, CI is live. Every subsequent push to a PR triggers it; you're done.

### 7. (Optional) Wire auto-deploy of the test broker (issue [#101](https://github.com/litentry/agentKeys/issues/101))

Without this step, the workflow validates against the **already-deployed** test broker. If a PR changes broker code (`crates/agentkeys-broker-server/**`, `crates/agentkeys-worker-*/**`, `crates/agentkeys-signer-protocol/**`, `scripts/setup-broker-host.sh*`, or any workspace-shared crate the broker links against), the test broker binary silently drifts from the PR's source tree — the harness then exercises *old* broker code against *new* harness scripts, producing either spurious passes or confusing failures.

Step 7 wires a second OIDC role (`github-actions-agentkeys-deploy`) plus two new GitHub secrets. When activated, the workflow's `detect-changes` job sees broker-affecting paths in the diff, the `deploy-test-broker` job assumes that role, and `aws ssm send-command` drives `setup-broker-host.sh --test --yes` on the test EC2 — re-deploying the broker so `harness-e2e` validates the PR's actual code. The deploy job is **gated three ways**:

1. `paths-filter` boolean (no broker code changed → skip).
2. Both deploy secrets present (`OIDC_AWS_ROLE_ARN_DEPLOY` + `TEST_BROKER_INSTANCE_ID`).
3. `preflight.outputs.should_run == 'true'` (test infra fully wired).

If any gate fails, the deploy job is **skipped, not failed** — `harness-e2e` still runs against the existing broker binary. So this step is fully opt-in; partial activation is safe.

#### 7.1 Run the provisioning script

```bash
awsp agentkeys-admin
# Look up the test broker EC2 instance ID (one-shot — pin it once):
TEST_BROKER_INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=ip-address,Values=$(curl -sS "https://dns.google/resolve?name=$BROKER_HOST&type=A" | jq -r '.Answer[0].data')" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
echo "$TEST_BROKER_INSTANCE_ID"   # → i-xxxxxxxxxxxxxxxxx

# Idempotent provisioning — safe to re-run. Use --fix-ssm on the FIRST run
# so the script auto-attaches AmazonSSMManagedInstanceCore to the broker EC2's
# instance profile if it's missing (a fresh EC2 commonly lacks this policy).
bash scripts/provision-ci-deploy-role.sh \
  --test-broker-instance-id "$TEST_BROKER_INSTANCE_ID" \
  --env-file scripts/operator-workstation.test.env \
  --fix-ssm
```

The script:

- Creates / refreshes the `github-actions-agentkeys-deploy` IAM role with a federated trust policy on the GitHub Actions OIDC provider, scoped to `repo:litentry/agentKeys:*` (any branch in this repo can trigger; the workflow's path filter + preflight gate further restrict when the role is actually used).
- Attaches an inline policy `agentkeys-ci-deploy-ssm` with:
  - `ssm:SendCommand` on `document/AWS-RunShellScript` + the one instance ARN (so even if the role's session creds leaked, the worst a third party can do is re-run setup-broker-host.sh on the test EC2 — a destructive op there is `terraform apply`-style: idempotent, recoverable, and contained to the test environment).
  - `ssm:GetCommandInvocation` / `ssm:ListCommandInvocations` / `ssm:DescribeInstanceInformation` for status polling + the workflow's pre-deploy sanity check.
  - `ec2:DescribeInstances` scoped to the one instance ID, for the workflow's pre-deploy sanity check.

> Already provisioned the role before `ssm:DescribeInstanceInformation` was added to the policy template? Re-run the provisioning script. `put-role-policy` is idempotent — it overwrites the inline policy with the current source-of-truth shape, picking up any added permissions.
- Verifies the test EC2 is registered with SSM (`PingStatus = Online`). With `--fix-ssm`, auto-remediates the common "instance profile is missing AmazonSSMManagedInstanceCore" case by attaching the policy and polling for up to 3 min for the SSM agent to refresh its creds. Without `--fix-ssm`, just reports the failure with manual fix instructions.

**SSM remediation modes (what `--fix-ssm` covers, what it doesn't):**

| Failure | What `--fix-ssm` does | What it CAN'T fix automatically |
|---|---|---|
| Instance profile missing `AmazonSSMManagedInstanceCore` | Attaches the policy, polls for Online | (handled) |
| Policy already attached, agent process running with stale creds | Polls until agent refreshes (~1-3 min typical) | If poll times out: SSH + `sudo systemctl restart amazon-ssm-agent`, OR `aws ec2 reboot-instances …` |
| Instance has NO instance profile at all | Creates a dedicated `agentkeys-test-broker-ssm` role + instance profile (EC2 trust + `AmazonSSMManagedInstanceCore`) and associates it with the EC2. IMDS surfaces the new creds within ~30s. Safe because the broker's app-layer AWS access uses static creds from `broker.env`, not IMDS — adding IMDS-served creds can only ADD capability for the SSM agent, not displace anything. | (handled) |
| SSM Agent not installed (no `amazon-ssm-agent` unit) | Reports state; can't reach the box to install (operator's laptop has no SSH-into-EC2 capability from the provision script) | Re-run `bash scripts/setup-broker-host.sh --test --yes` on the EC2 — it now installs `amazon-ssm-agent` (snap preferred, .deb fallback) as part of broker bootstrap. One-shot manual recovery if you don't want to re-run the full setup: `ssh test-broker 'sudo snap install amazon-ssm-agent --classic && sudo systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service'` |
| Private VPC subnet without an SSM VPC endpoint | Reports state | Operator wires the VPC endpoint (unlikely for a public-IP broker, but possible) |

Re-running the script after any of the operator-side fixes is safe (idempotent — every step is `get-*` pre-checked before any mutation).

#### 7.2 Set the two new repo secrets

```bash
# Print the deploy role ARN you just provisioned (script also prints this):
role_arn=$(aws iam get-role --role-name github-actions-agentkeys-deploy \
  --query 'Role.Arn' --output text)

gh secret set OIDC_AWS_ROLE_ARN_DEPLOY --repo litentry/agentKeys --body "$role_arn"
gh secret set TEST_BROKER_INSTANCE_ID  --repo litentry/agentKeys --body "$TEST_BROKER_INSTANCE_ID"
```

| Secret | Purpose |
|---|---|
| `OIDC_AWS_ROLE_ARN_DEPLOY` | ARN of `github-actions-agentkeys-deploy` — assumed by the `deploy-test-broker` job via GitHub Actions OIDC. |
| `TEST_BROKER_INSTANCE_ID` | EC2 instance ID (`i-…`) hosting `test-broker.${ZONE}`. The deploy role's inline policy is scoped to *this single instance*. |

#### 7.3 Dry-run validate

Trigger the workflow manually with `force_deploy_broker=true` so the deploy fires regardless of whether the latest commit touched broker paths.

**Pre-merge — `--ref` is required.** `gh workflow run` reads the workflow definition from the *default branch* (`main`) unless you tell it otherwise. Since the `force_deploy_broker` input lives on the PR branch, dispatching without `--ref` fails with `HTTP 422: Unexpected inputs provided: ["force_deploy_broker"]`. Pass `--ref` so GHA reads the workflow YAML (and its inputs) from the PR branch instead:

```bash
gh workflow run harness-ci.yml --repo litentry/agentKeys \
  --ref claude/adoring-bell-1b9ca8 \
  --field stage=1 \
  --field force_deploy_broker=true
```

Replace `claude/adoring-bell-1b9ca8` with your actual PR branch name (`git rev-parse --abbrev-ref HEAD` if you're on it locally).

**Post-merge — `--ref` is optional.** Once this PR is on `main`, dispatching without `--ref` will work because the input is part of the default-branch workflow definition. (The `--ref` form still works and lets you target any branch.)

Then in the run logs:

- `deploy-test-broker` should show `SSM agent online on i-…` (sanity check passed).
- The `SendCommand` step prints the command ID; the next step polls until `Success`.
- On success: the tail of `StandardOutputContent` shows `setup-broker-host.sh` finishing cleanly (`ok systemd unit … active`, `ok nginx running`, etc.).
- On failure: stdout + stderr are dumped to the GHA log. The most common cause is `git checkout` failing on the EC2 because the source tree doesn't have the PR branch fetched — fix by ssh-ing into the box and running `sudo -u ubuntu git fetch --prune origin` once.

#### 7.4 Disable / disarm

Remove either secret to disarm — the workflow's `preflight.outputs.deploy_ready` will flip to `false` and the deploy job silently skips:

```bash
gh secret delete OIDC_AWS_ROLE_ARN_DEPLOY --repo litentry/agentKeys
# or
gh secret delete TEST_BROKER_INSTANCE_ID --repo litentry/agentKeys
```

The IAM role can stay provisioned indefinitely — without the secret it can't be assumed by GHA, and the inline SSM perms are scoped to one instance.

#### Out of scope for issue #101

Per [issue #101](https://github.com/litentry/agentKeys/issues/101) "Out of scope":

- **Prod broker auto-deploy** — never. The prod broker EC2 stays manual via `bash scripts/setup-broker-host.sh --upgrade` from the operator laptop, per CLAUDE.md "Remote broker host (single entry point)".
- **Auto-deploy of test Heima EVM contracts** — deferred to a follow-up PR (issue #101 rollout plan step 7). Contract redeploys mint new addresses and require the `SECRETS_REWRITE_PAT` token to update six `TEST_*_ADDRESS_HEIMA` secrets — more risk than the broker deploy, so it ships separately.
- **Mainnet prod contract redeploy** — never automatic. Manual via `bash scripts/setup-heima.sh` only.

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

No project credentials live in this doc. Every value above is either a placeholder (`${ACCOUNT_ID}`, `${ZONE}`) or an instruction to read from the operator's already-provisioned state ("from step 5"). The actual values live in two places only:

- The operator's local `scripts/operator-workstation.env` (gitignored copies / test variants only).
- The GitHub repo's encrypted secrets store.

Never paste a real account ID, role ARN, bucket name, deployer key, or contract address into a markdown doc, commit message, or PR description.

## Related

- Workflow file: [`.github/workflows/harness-ci.yml`](../.github/workflows/harness-ci.yml)
- Cloud / broker bring-up: [`docs/cloud-bootstrap.md`](cloud-bootstrap.md)
- Chain bring-up: [`docs/chain-setup.md`](chain-setup.md)
- Harness scripts: [`harness/v2-stage{1,2,3}-demo.sh`](../harness/)
- FAQ + troubleshooting: [`wiki/ci-setup-faq.md`](../wiki/ci-setup-faq.md)
