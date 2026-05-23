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
