# Cloud bootstrap — AgentKeys

**Audience:** the operator standing up a brand-new cloud account to host AgentKeys for the first time, or porting the deployment to a new cloud provider (AliCloud, GCP, Tencent Cloud).
**Scope:** the per-account, run-once provisioning that has to happen **before** the broker host can come up (§§3–8 of this doc), followed by the per-broker OIDC federation activation (§9), broker host bring-up (§10), and tear-down (§11). Identifiers (DNS names, IAM principals, mail backend, object store, initial bucket policy) + runtime activation in one place.
**FAQ + troubleshooting:** [`wiki/cloud-setup-faq.md`](../wiki/cloud-setup-faq.md).

After this doc is run, the operator returns here ONLY when:
- Switching cloud providers (e.g. AWS → AliCloud)
- Adding a second AWS account (test instance, regional shard)
- Re-bootstrapping after a teardown
- Auditing the identity surface (the security-audit checklist in §7)

The day-to-day broker re-deploys live in §10 below (`setup-broker-host.sh`); they re-run that section without touching §§1–9.

## Quick start — five steps to a running stack

Tight five-step flow. Explanation + per-step reasoning are in §1–§11 below; the same flow works for prod (no `--test`) or test (`--test` swaps in `-test` identifiers everywhere). The orchestrator [`scripts/setup-cloud.sh`](../scripts/setup-cloud.sh) is idempotent — re-running is safe.

### 1. Get the EC2 + EIP (manual, ~5 min per stack)

For each stack (prod and test) you stand up SEPARATELY:

- Launch an EC2 — **t3.small minimum** (Ubuntu 22.04 LTS recommended). `t3.micro` runs the OS but its 1 GB RAM gets OOM-killed compiling `aws-sdk-s3` during `setup-broker-host.sh`. If you already have a t3.micro you can resize: `aws ec2 stop-instances` → `modify-instance-attribute --instance-type t3.small` → `start-instances` (EIP stays attached, INSTANCE_ID unchanged).
- Allocate an EIP (or reuse one) and attach it to the EC2.
- **Open SG ports 22 (SSH), 80 (certbot HTTP-01 challenge), 443 (TLS)** to `0.0.0.0/0`. **All three are required** — port 80 is needed for Let's Encrypt to validate domain ownership during cert issuance (step 5b), even though steady-state traffic only flows over 443. Verify with `aws ec2 describe-security-groups --group-ids <sg-id> --query 'SecurityGroups[].IpPermissions[].[FromPort,IpRanges[].CidrIp]'` — you should see all three ports.
- Generate or import an SSH key pair (the `.pem` you'll keep as the fallback when EC2 Instance Connect is down). Confirm SSH works: `ssh -i your.pem ubuntu@<EIP>`.
- The default `ubuntu` user is enough for now — the `agentkey` SSH login user (used by EC2 Instance Connect later) is created automatically by `setup-broker-host.sh` in step 5, along with the `ec2-instance-connect` package.
- Note **INSTANCE_ID** + **EIP** — both go into the env files in step 2.

### 2. Fill in the 4 env files (one-time per environment)

The 2×2 matrix: `{operator-workstation, broker} × {prod, test}` = 4 files. The two operator-workstation files carry account-wide identifiers; the two broker files carry per-machine identifiers (`INSTANCE_ID` + `EIP`).

**Both operator-workstation files are pre-populated with `litentry.org` / account `429071895007` defaults**, and every derived value uses bash `${VAR}` substitution off of `ACCOUNT_ID` / `BROKER_HOST` / `ZONE`. The script writes 2 values back automatically — operator never hand-edits them:

- **`EIP=…`** persisted to broker env file by step 4 (after allocate-or-adopt)
- **`DATA_ROLE_ARN=…`** persisted to operator env file by step 11 (after data role create)

| File | Operator edits | What to set |
|---|---|---|
| [`scripts/operator-workstation.env`](../scripts/operator-workstation.env) | **None** if your account is `litentry.org` / `429071895007`. **5 keys** if you're forking: `ACCOUNT_ID`, `BROKER_HOST`, `ZONE`, `PARENT_ZONE_ID`, `MAIL_DOMAIN` (the other ~20 keys all derive). | account-wide identifiers |
| [`scripts/operator-workstation.test.env`](../scripts/operator-workstation.test.env) | **None** in the same case. Same 5 keys (or just `ZONE` + `PARENT_ZONE_ID`) for a fork. | `-test` variants pre-derived |
| [`scripts/broker.env`](../scripts/broker.env) | `INSTANCE_ID=i-…` | `EIP` is written by the script |
| [`scripts/broker.test.env`](../scripts/broker.test.env) | `INSTANCE_ID=i-…` | `EIP` is written by the script |

In practice: paste `INSTANCE_ID` into the two broker env files. Done.

### 3. Run `setup-cloud.sh` (~3 min, idempotent)

```bash
awsp agentkeys-admin

# Prod stack:
bash scripts/setup-cloud.sh --yes

# Test stack — --test auto-selects scripts/operator-workstation.test.env
# + scripts/broker.test.env and suffixes IAM identifiers with -test:
bash scripts/setup-cloud.sh --test --yes
```

The orchestrator walks 15 idempotent steps (cloud-side AWS resources + IAM users + per-data-class roles + bucket policies + DNS UPSERTs). Steps 10 (`agentkeys-daemon[-test]`) and 12 (`agentkeys-broker[-test]`) print **access keys** to copy off — they're shown ONCE.

### 4. Configure local credentials + shell aliases (paste, one-time)

Append the two access-key blocks from step 3 to `~/.aws/credentials`:

```ini
[agentkeys-daemon-test]
aws_access_key_id     = AKIA…
aws_secret_access_key = …
region                = us-east-1

[agentkeys-broker-test]
aws_access_key_id     = AKIA…
aws_secret_access_key = …
region                = us-east-1
```

(Drop the `-test` suffix for the prod variants. Account-owner `agentkeys-admin` is shared — no `-test` variant.)

Add to `~/.zshenv` (works in zsh + bash):

```zsh
export AGENTKEYS_REPO="$HOME/Projects/agentKeys"
alias ssh-agentkeys='bash $AGENTKEYS_REPO/scripts/ssh-broker.sh prod'
alias ssh-agentkeys-test='bash $AGENTKEYS_REPO/scripts/ssh-broker.sh test'
alias ssh-agentkeys-fallback='bash $AGENTKEYS_REPO/scripts/ssh-broker.sh prod --fallback'
alias ssh-agentkeys-test-fallback='bash $AGENTKEYS_REPO/scripts/ssh-broker.sh test --fallback'
```

`source ~/.zshenv`. The fallback aliases use the `.pem` key + `ubuntu` user; the non-fallback ones use EC2 Instance Connect + the `agentkey` user (which comes online in step 5).

### 5. SSH in + run `setup-broker-host.sh` on the EC2

First-time SSH: use the **fallback** path (the `agentkey` user doesn't exist yet — `setup-broker-host.sh` creates it):

```bash
ssh-agentkeys-test-fallback   # ssh -i ~/.ssh/your.pem ubuntu@<test EIP>

# On the EC2 (~10-15 min on t3.small):
git clone https://github.com/litentry/agentKeys.git
cd agentKeys

sudo bash scripts/setup-broker-host.sh --test --yes
```

Two flags. `--test` triggers the `-test` suffix on every derived hostname / bucket / email; `--issuer-url` + `--account-id` auto-derive from `ZONE` + `ACCOUNT_ID` in `scripts/operator-workstation.env` (which the repo clone ships with). Override any flag explicitly if you need a non-conventional name. For **prod**, drop `--test`:

```bash
sudo bash scripts/setup-broker-host.sh --yes
```

What `--test` derives automatically:
- `signer-test.${ZONE}`, `audit-test.${ZONE}`, `email-test.${ZONE}`, `cred-test.${ZONE}`, `memory-test.${ZONE}`, `config-test.${ZONE}`
- `agentkeys-vault-test-${ACCOUNT_ID}`, `agentkeys-memory-test-${ACCOUNT_ID}`
- `noreply-test@bots-test.${ZONE}`
- `https://test-broker.${ZONE}` for the OIDC issuer URL

When the script finishes (~10-15 min on `t3.small` cold; ~30-60s on re-runs), it does three things at the end so steady-state operator work is one keystroke from your laptop:

1. **Creates the `agentkey` SSH login user** (separate from the `agentkeys` daemon system user).
2. **Installs `ec2-instance-connect`** + writes the sshd `AuthorizedKeysCommand` config so EC2 Instance Connect can push ephemeral keys to `agentkey`.
3. **Relocates the repo** `/home/ubuntu/agentKeys` → `/home/agentkey/agentKeys` (chowned to `agentkey`) so re-runs + ongoing edits happen as the steady-state user.

Then exit the ubuntu session and reconnect as `agentkey` for everything from here on:

```bash
exit                       # leave the ubuntu fallback session
ssh-agentkeys-test         # Instance Connect, no .pem needed
cd ~/agentKeys             # → /home/agentkey/agentKeys, files visible
```

Subsequent re-runs (`git pull` + `sudo bash scripts/setup-broker-host.sh --test --yes`) happen from `/home/agentkey/agentKeys` — step 10's relocation is idempotent (existence check skips when already in place). The cargo build cache survives the move (it's inside `target/`). The Rust toolchain itself is **deleted from `/root/` at the end of the first run** to save ~1.5 GB — future re-runs reinstall it as part of the toolchain step automatically. This keeps the box clean and ensures only one canonical Rust install on disk at a time.

For **prod**, the same flow applies — drop `--test` everywhere and the relocation moves the repo from whichever home dir you bootstrapped in to `/home/agentkey/`.

**Optional: install rustup for the `agentkey` user (dev-loop cargo).** If you want to run `cargo clippy` / `cargo test` interactively as `agentkey` (e.g., to mirror the CI Linux env locally and catch `cfg(target_os = "linux")` clippy lints that don't fire on macOS), install rustup under your own `$HOME` once after reconnecting as `agentkey`:

```bash
ssh-agentkeys-test
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --default-toolchain stable --profile minimal
source "$HOME/.cargo/env"
echo 'source "$HOME/.cargo/env"' >> ~/.bashrc   # persist for future sessions

cargo --version    # matches CI's stable channel
cd ~/agentKeys
cargo clippy --workspace --all-targets -- -D warnings   # same lint set as CI
```

This is **optional**; the broker itself runs from compiled binaries, not from a live toolchain. Operators who only manage the deployed broker (no compile-in-place dev work) can skip this.

### 5b. Issue TLS certs + flip nginx onto :443

`setup-broker-host.sh` installs `certbot` but does NOT issue Let's Encrypt certs itself — issuance is DNS-dependent (the broker hostname must already resolve to this EIP on the public internet before Let's Encrypt's HTTP-01 challenger can validate it). Until you run the issuance below, nginx serves HTTP-only on `:80` with a `503 "TLS cert not yet issued"` placeholder on every non-ACME path — and **the OIDC federation step in [`docs/ci-setup.md`](ci-setup.md) §1 can't succeed because there's no cert to extract a thumbprint from**.

> **⚠️ Run EVERY command in this section ON THE BROKER HOST** — the machine whose public A record the hostnames point to (the EIP). `certbot --webroot` writes the ACME challenge to the **local** `/var/www/certbot`, but Let's Encrypt validates by fetching `http://<host>/.well-known/acme-challenge/…` from the hostname's **public IP = the broker**. Run certbot on your laptop or any non-broker box — *especially* behind a VPN (Cloudflare WARP / Zscaler / Tailscale) that intercepts or rewrites `${ZONE}` — and the challenge lands on the wrong machine, so the broker answers the CA with **404** and issuance fails. SSH in first (`ssh-agentkeys`); sanity-check you're on the right host with `curl -s ifconfig.me` (must print the broker EIP). A laptop `curl` of `<host>` behind a VPN hits the **VPN's** nginx, not the broker's — an easy tell is a different `nginx/<version>` in the 404 page than the broker's `nginx -v`.

```bash
# Still on the broker host (as agentkey or ubuntu — both have sudo):
# PRE-CHECK (cheap; avoids burning Let's Encrypt's rate-limited attempts on a vhost
# that isn't actually live). Confirm THIS host's nginx serves the ACME path before
# asking the CA. A freshly-added worker (e.g. config, #201) needs nginx reloaded
# first — `nginx -T` showing the vhost does NOT mean the running process loaded it.
sudo nginx -t && sudo systemctl reload nginx
sudo mkdir -p /var/www/certbot/.well-known/acme-challenge
echo probe-ok | sudo tee /var/www/certbot/.well-known/acme-challenge/probe >/dev/null
curl -s http://localhost/.well-known/acme-challenge/probe -H "Host: ${CONFIG_HOST}"   # must print: probe-ok (404 ⇒ vhost not live → reload)
sudo rm -f /var/www/certbot/.well-known/acme-challenge/probe

# CONFIG_HOST (config.${ZONE}) is the #201 master-only taxonomy worker — its
# cert is required too, or stage-3 steps 19-21 fail with SSL_ERROR_SYSCALL.
for h in ${BROKER_HOST} ${SIGNER_HOST} ${AUDIT_HOST} ${EMAIL_HOST} ${CRED_HOST} ${MEMORY_HOST} ${CONFIG_HOST}; do
  sudo certbot certonly --webroot -w /var/www/certbot -d "$h" \
    --agree-tos -m <your-ops-email> --non-interactive
done
# Explicit config form (if you issue certs one at a time):
#   sudo certbot certonly --webroot -w /var/www/certbot -d config.litentry.org \
#     --agree-tos -m ops@litentry.org --non-interactive

# Flip nginx from Phase A (HTTP-only) → Phase B (HTTPS) — the renderer in
# setup-broker-host.sh picks Phase B automatically when /etc/letsencrypt/live/<host>/
# exists. Re-running the script is the trigger:
cd ~/agentKeys
sudo bash scripts/setup-broker-host.sh --test --yes      # or drop --test for prod
```

The hostname env vars come from `/etc/agentkeys/broker.env` (which `setup-broker-host.sh` wrote at step 5). For **test**: `BROKER_HOST=test-broker.${ZONE}`, `SIGNER_HOST=signer-test.${ZONE}`, etc. For **prod**: drop the `-test` suffix.

**Verify the cert is live** (bypass laptop DNS, which may be rewritten by WARP / Zscaler / Tailscale to `198.18.x.y` for `${ZONE}`):

```bash
# DoH lookup — proves Route 53 has the right EIP, not your laptop's local resolver
curl -sS "https://dns.google/resolve?name=${BROKER_HOST}&type=A" | jq -r '.Answer[].data'
# → should be your EIP, not 198.18.x.y

# TLS handshake against the real EIP:
echo | openssl s_client -servername "${BROKER_HOST}" -connect "$(curl -sS "https://dns.google/resolve?name=${BROKER_HOST}&type=A" | jq -r '.Answer[0].data'):443" 2>&1 \
  | grep -E "subject="
# → subject=/CN=<your-BROKER_HOST>
```

If `openssl s_client` returns `no peer certificate available`, certbot didn't finish or nginx isn't on Phase B yet. Check:
- `sudo ls /etc/letsencrypt/live/` — should list all 6 hostnames as subdirs.
- `sudo ss -tlnp | grep ':443'` — nginx should be on `0.0.0.0:443`.
- `sudo tail /var/log/letsencrypt/letsencrypt.log` for the actual certbot failure.

Common failures + fixes:
- **`Connection timeout to … port 80`** — the SG is missing port 80 ingress. Re-check step 1's SG requirements (you need 22, 80, **and** 443).
- **`DNS problem: NXDOMAIN`** — Route 53 doesn't have the A record yet, or DNS hasn't propagated. Wait 1-2 min, then retry. Quick check: `curl -sS "https://dns.google/resolve?name=<host>&type=A"` (do NOT rely on `dig` — local resolver may be lying).
- **`No such file or directory: /var/www/certbot`** — Phase A nginx render didn't complete; re-run `sudo bash scripts/setup-broker-host.sh --test --yes` first.
- **A worker's cert fails but the broker's works (or the CA hits an IP that isn't your broker)** — the worker A records point at a *different* EIP than the broker. Workers co-locate with the broker, so every worker A record MUST equal `broker.${ZONE}`'s. This bit us when the account had **both** a prod and a test broker EIP and the worker records were pointed at the **test** EIP while `broker`/`signer` stayed on prod. Check via DoH (never laptop DNS — a VPN rewrites it): `for h in broker audit email cred memory config; do echo "$h → $(curl -s "https://dns.google/resolve?name=$h.${ZONE}&type=A" | jq -r '.Answer[0].data')"; done`. If any worker differs from `broker`, re-run `bash scripts/dns-upsert-workers.sh` from your laptop (`agentkeys-admin`) — it derives the EIP from `broker.${ZONE}`'s own A record, so all five workers mirror the broker (pass `--eip <broker-EIP>` to be explicit).
- **`unauthorized` / `Invalid response … /.well-known/acme-challenge/… : 404`** — the CA reached the host but couldn't fetch the challenge file. Two causes: (1) **certbot ran on the wrong machine** — `--webroot` wrote the challenge to *that* box's `/var/www/certbot`, but the CA validates against the hostname's public IP (the broker). Run certbot ON THE BROKER (see the ⚠️ above). (2) **a newly-added worker's vhost isn't live** — `nginx -T` shows it on disk but the running process wasn't reloaded; `sudo nginx -t && sudo systemctl reload nginx`, then re-run the PRE-CHECK probe. Confirm locally on the broker (not a VPN'd laptop): `echo ok | sudo tee /var/www/certbot/.well-known/acme-challenge/probe >/dev/null && curl -s http://localhost/.well-known/acme-challenge/probe -H "Host: <host>"` must print `ok`.

---

The rest of this doc explains **why** each step exists and how to recover from failures. Operators following the quick start above can skip to [`docs/chain-setup.md`](chain-setup.md) once step 5b completes.

```
§1  Identities         — four IAM principals; concept first, then provider commands
§2  Domain + DNS       — subdomain ownership; parent-zone confirmation
§3  Email backend      — SES domain identity + receipt rule + S3 inbound bucket
§4  IAM users + roles  — agentkeys-{admin,broker,daemon} + agentkeys-data-role
§5  Bucket policy      — static-IAM variant (pre-OIDC; replaced in §9 below)
§6  Instance profile   — agentkeys-broker-host (optional, EC2-only)
§7  Security audit     — strip legacy over-broad attached policies
§8  Cloud portability  — AWS → AliCloud / GCP / Tencent Cloud mapping
§9  OIDC federation    — per-broker security upgrade after broker is reachable
§10 Broker host        — what setup-broker-host.sh does
§11 Cleanup            — full account teardown
```

Surgical re-run of any single step: `bash scripts/setup-cloud.sh --only-step N` (with `--test` for test).

### Env files reference (4 files + CI runner)

Four env files cover the 2×2 matrix of {operator, broker} × {prod, test}. The GitHub Actions runner doesn't get its own file — it materializes the operator-workstation env inline at job start from `TEST_*` secrets.

| File | Lives on | Scope | Sourced by |
|---|---|---|---|
| [`scripts/operator-workstation.env`](../scripts/operator-workstation.env) | operator laptop | prod | every helper script + `setup-cloud.sh` + `setup-heima.sh` + `harness/run.sh` |
| [`scripts/operator-workstation.test.env`](../scripts/operator-workstation.test.env) | operator laptop | test | same scripts, via `--env-file <path>` |
| [`scripts/broker.env`](../scripts/broker.env) | prod broker host at `/etc/agentkeys/broker.env` | prod | the broker process at boot (also `setup-broker-host.sh` writes equivalent systemd `Environment=` lines) |
| [`scripts/broker.test.env`](../scripts/broker.test.env) | test broker host at `/etc/agentkeys/broker.env` | test | same |
| GitHub Actions runner | ephemeral runner per job | test | `harness-ci.yml` writes `scripts/operator-workstation.env` inline from `TEST_*` secrets (see [`docs/ci-setup.md`](ci-setup.md) §7) |

#### Operator env — prod vs test side-by-side

| Variable | Prod | Test | Purpose |
|---|---|---|---|
| `ACCOUNT_ID` | `429071895007` | `429071895007` (same) | every cloud step |
| `REGION` | `us-east-1` | `us-east-1` | regional API calls |
| `ZONE` | `litentry.org` | `litentry.org` (same) | parent DNS zone |
| `PARENT_ZONE_ID` | Route 53 zone ID | same | DNS UPSERTs |
| `BROKER_HOST` | `broker.${ZONE}` | `test-broker.${ZONE}` | OIDC issuer hostname (byte-for-byte distinct → distinct IAM OIDC provider ARN) |
| `MAIL_DOMAIN` | `bots.${ZONE}` | `bots-test.${ZONE}` | SES inbound subdomain |
| `BUCKET` / `MAIL_BUCKET` | `agentkeys-mail-${ACCT}` | `agentkeys-mail-test-${ACCT}` | inbound mail bucket |
| `VAULT_BUCKET` | `agentkeys-vault-${ACCT}` | `agentkeys-vault-test-${ACCT}` | credentials bucket (arch.md §17) |
| `MEMORY_BUCKET` | `agentkeys-memory-${ACCT}` | `agentkeys-memory-test-${ACCT}` | memory bucket |
| `DATA_ROLE_ARN` | `…:role/agentkeys-data-role` | `…:role/agentkeys-data-role-test` | OIDC-federated data role |
| `VAULT_ROLE_ARN` | `…:role/agentkeys-vault-role` | `…:role/agentkeys-vault-role-test` | per-data-class vault role |
| `MEMORY_ROLE_ARN` | `…:role/agentkeys-memory-role` | `…:role/agentkeys-memory-role-test` | per-data-class memory role |
| `OIDC_PROVIDER_ARN` | `…:oidc-provider/${BROKER_HOST}` | `…:oidc-provider/test-broker.${ZONE}` | derived from BROKER_HOST |
| `SIGNER_HOST` + worker hosts | `signer.${ZONE}` etc. | `signer-test.${ZONE}` etc. | per-service public hostnames |
| `BROKER_EMAIL_FROM_ADDRESS` | `noreply@bots.${ZONE}` | `noreply-test@bots-test.${ZONE}` | SES verified sender |
| Heima contract `*_HEIMA` addresses | one set | a DIFFERENT set (same chain, different deployer key) | per-deploy pinned addresses |

#### Broker env — prod vs test side-by-side

| Variable | Prod | Test |
|---|---|---|
| `ACCOUNT_ID` | same | same |
| `BROKER_DATA_ROLE_ARN` | `…:role/agentkeys-data-role` | `…:role/agentkeys-data-role-test` |
| `BROKER_AWS_REGION` | `us-east-1` | `us-east-1` |
| `BROKER_OIDC_ISSUER` | `https://broker.${ZONE}` | `https://test-broker.${ZONE}` |
| `BROKER_OIDC_KEYPAIR_PATH` | `/home/ubuntu/.agentkeys/broker/oidc-keypair.json` | same |
| `BROKER_SESSION_KEYPAIR_PATH` | `/home/ubuntu/.agentkeys/broker/session-keypair.json` | same |
| `BROKER_AUTH_METHODS` | `wallet_sig,email_link` | same |
| `BROKER_AUDIT_ANCHORS` | `sqlite` | same |
| `BROKER_EMAIL_SENDER` | `ses` | `ses` |
| `BROKER_EMAIL_FROM_ADDRESS` | `noreply@bots.${ZONE}` | `noreply-test@bots-test.${ZONE}` |

The broker process never reads operator-workstation env vars directly — separation prevents a laptop value from silently shadowing the broker's own config (per [`scripts/broker.env`](../scripts/broker.env) header comment).

#### CI runner

The runner doesn't ship with a checked-in env file. `harness-ci.yml` writes one inline at job start, mapping `TEST_*` repo secrets into `scripts/operator-workstation.env`:

| TEST secret | Maps to operator var |
|---|---|
| `TEST_ACCOUNT_ID` | `ACCOUNT_ID` |
| `TEST_AWS_REGION` | `REGION` |
| `TEST_BROKER_HOST` | `BROKER_HOST` |
| `TEST_VAULT_BUCKET` / `TEST_MEMORY_BUCKET` | `VAULT_BUCKET` / `MEMORY_BUCKET` |
| `TEST_DATA_ROLE_ARN` / `TEST_VAULT_ROLE_ARN` / `TEST_MEMORY_ROLE_ARN` | `DATA_ROLE_ARN` / `VAULT_ROLE_ARN` / `MEMORY_ROLE_ARN` |
| `TEST_HEIMA_DEPLOYER_KEY` | written to `~/.agentkeys/heima-deployer.key` |
| `TEST_*_HEIMA` contract addresses | `*_HEIMA` |
| `TEST_OIDC_AWS_ROLE_ARN` | the GH Actions OIDC role (gate; not a runtime var) |

Full list + activation flow: [`docs/ci-setup.md`](ci-setup.md) §7. `setup-cloud.sh` validates required keys at step 2 and dies with a precise pointer if missing.

### §0.1 Manual prereqs (must exist before `setup-cloud.sh` runs)

`setup-cloud.sh` consumes already-existing identifiers — it does NOT register your domain, create a Route 53 hosted zone, or launch the EC2. Those are operator decisions (instance type, region, key pair, DNS provider choice) and don't belong in an automated script. Three manual prereqs before the orchestrator works:

#### 1. Domain + Route 53 hosted zone

You own a domain (e.g. `litentry.org`). If not, register one with any registrar (Namecheap, GoDaddy, Route 53 Domains, etc.) — fully manual, out of scope here.

Create a Route 53 hosted zone for the domain (idempotent at the `caller-reference` level, but safe to skip if the zone already exists):

```bash
aws route53 create-hosted-zone \
  --name "$ZONE" \
  --caller-reference "agentkeys-$(date +%s)"
```

Look up the zone ID (strip the `/hostedzone/` prefix):

```bash
aws route53 list-hosted-zones \
  --query 'HostedZones[?Name==`'"$ZONE"'.`].Id' --output text \
  | awk -F/ '{print $NF}'
# → Z09723983CFJOHAE3VC65
```

Paste it into `operator-workstation.env` as `PARENT_ZONE_ID=Z…`.

**Delegation:** Route 53 outputs 4 NS records when you create the zone (visible via `aws route53 get-hosted-zone --id $PARENT_ZONE_ID --query 'DelegationSet.NameServers'`). Copy them into your registrar's DNS settings as the authoritative nameservers. Verify after propagation (usually <1h):

```bash
dig +short NS "$ZONE"
# Should return 4 ns-XX.awsdns-YY.{com,net,org,co.uk} entries.
```

If `dig` returns the registrar's default nameservers instead, delegation hasn't propagated. All downstream DNS UPSERTs in §6 will silently miss until it does.

**Non-Route 53 DNS providers:** `setup-cloud.sh` step 6 hardcodes Route 53 API calls. To use Cloudflare / DigitalOcean / etc., skip step 6 (`--to-step 5`) and replicate the same 12 records manually — see [§6](#6-dns-records-dkim--spf--dmarc--mx--6-a-records) below for the canonical record set. Test isolation works identically: a `test-broker.${ZONE}` A record under any DNS provider is the same byte-for-byte trust scope as under Route 53.

#### 2. EC2 instance (or any Linux host)

`setup-broker-host.sh` runs on any Linux box with sudo, systemd, public-internet egress, ports 22/80/443 open inbound. The host is your choice:

| Setting | Prod | Test |
|---|---|---|
| Instance type | t3.small minimum | t3.micro is fine |
| AMI | Ubuntu 22.04 LTS or Amazon Linux 2023 | same |
| Security group | 22 (SSH), 80 (certbot HTTP-01), 443 (broker + workers TLS), all from `0.0.0.0/0` | same (AWS validates OIDC JWKS over public TLS from AWS IPs that aren't pinnable) |
| Key pair | SSH key, EC2 Instance Connect, or SSM Session Manager | same |

Launch via AWS console, `aws ec2 run-instances`, or your IaC tool. The script doesn't care which.

**Getting the IP — three workflows:**

Both `INSTANCE_ID` and `EIP` live in the env file (`scripts/operator-workstation.env` or `…test.env`) — set them there once, not on the shell every run. The test stack is selected by `--env-file <path>` + the explicit `--test` flag (or auto-detected when the env-file name contains "test").

**Workflow 0 (you already have EC2 + EIP attached): step 4 adopts the existing EIP**

If the EC2 is already running with an EIP attached (whether allocated via the AWS Console, Terraform, or a previous `setup-cloud.sh` run), there's no need to allocate or re-associate. Step 4's precedence ladder detects it:

```bash
# 1. Find the existing EC2's instance id:
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=ip-address,Values=<YOUR-EXISTING-EIP>" \
  --query 'Reservations[].Instances[].InstanceId' --output text

# 2. Paste it into the env file (one line edit):
echo 'INSTANCE_ID=i-0123…' >> scripts/operator-workstation.env

# 3. Run setup-cloud.sh — step 4 prints:
#      "skip  EIP <ip> already attached to <instance-id> (adopting; no allocation)"
#      "ok    tagged existing EIP as agentkeys-broker-eip (idempotency for re-runs)"
#    No new EIP is allocated. No re-association. The existing EIP gets
#    retroactively tagged so future re-runs find it via tag-lookup too.
AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh --yes
```

The precedence inside step 4 is: **A** adopt EIP attached to `$INSTANCE_ID` → **B** reuse tagged EIP → **C** use `$EIP` from env file → **D** allocate fresh. First match wins; no later branch fires if an earlier one resolves. Fully idempotent re-runs even when the operator pre-provisioned EC2 + EIP outside the script.

**Workflow A (recommended): EC2-first, then attach via env-file edit + re-run**

```bash
# 1. Launch EC2 → note INSTANCE_ID
aws ec2 run-instances --instance-type t3.small --image-id <ami> --key-name <key> ...

# 2. Paste INSTANCE_ID into the env file (one line edit):
echo 'INSTANCE_ID=<from-step-1>' >> scripts/operator-workstation.env
#    (or for test: scripts/operator-workstation.test.env)

# 3. Bootstrap (allocates EIP + attaches to INSTANCE_ID + persists EIP back to env)
AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh --yes
# Test stack:
AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh \
  --env-file scripts/operator-workstation.test.env --test --yes

# 4. SSH (EIP is now in the env file as EIP=…)
ssh ubuntu@$(grep ^EIP= scripts/operator-workstation.env | cut -d= -f2)
```

**Workflow B: EIP-first, attach manually**

```bash
# 1. Allocate EIP (printed at §14 summary; persisted to env file as EIP=…)
AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh --yes

# 2. Launch EC2
aws ec2 run-instances ...

# 3. Attach the EIP
aws ec2 associate-address --region "$REGION" \
  --instance-id <new-instance-id> \
  --public-ip $(grep ^EIP= scripts/operator-workstation.env | cut -d= -f2)
```

A is one fewer command; B is sometimes necessary when an existing EC2 needs to be repointed at the EIP later. For test, swap in `--env-file scripts/operator-workstation.test.env --test` everywhere — the EIP will be tagged `agentkeys-broker-eip-test` (the test env file has the test placeholders pre-populated).

#### 2a. SSH into the broker host

Once the EC2 is launched + the EIP attached, SSH access goes through [`scripts/ssh-broker.sh`](../scripts/ssh-broker.sh) — single entry point that reads `INSTANCE_ID` + `EIP` from `scripts/broker.env` or `scripts/broker.test.env` so it stays in lockstep with whatever `setup-cloud.sh` persisted.

```bash
# Prod broker via EC2 Instance Connect (no .pem needed):
bash scripts/ssh-broker.sh

# Test broker:
bash scripts/ssh-broker.sh test

# Fallback via .pem key (when EC2 Instance Connect is down):
bash scripts/ssh-broker.sh prod --fallback
bash scripts/ssh-broker.sh test --fallback
```

Default AWS profiles per stack (least-privilege, one-shot to provision):

| Stack | Default profile | Trust |
|---|---|---|
| `prod` | `agentkeys-broker` | `ec2-instance-connect:SendSSHPublicKey` on the prod instance ARN only |
| `test` | `agentkeys-broker-test` | same, scoped to the test instance ARN |

If `agentkeys-broker` or `agentkeys-broker-test` doesn't exist yet, `setup-cloud.sh` step 12 creates it idempotently (scoped to whatever `INSTANCE_ID` is set in the corresponding broker env file):

```bash
# Test stack — creates agentkeys-broker-test, scopes ec2-instance-connect
# to INSTANCE_ID from broker.test.env, mints an access key ONCE if none
# active. Re-run is a no-op once the user + policy + key already exist.
AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh \
  --env-file scripts/operator-workstation.test.env --test --only-step 12

# Prod stack (the canonical `agentkeys-broker` user from CLAUDE.md):
AWS_PROFILE=agentkeys-admin bash scripts/setup-cloud.sh --only-step 12
```

The script prints the access key once (paste into `~/.aws/credentials` as `[agentkeys-broker]` / `[agentkeys-broker-test]`) — it never re-mints on subsequent runs because the operator already holds the secret. If `INSTANCE_ID` is unset in the broker env file, step 12 skips with a pointer to paste it first.

Shell wrappers (drop in `~/.zshrc`) make the common case one keystroke:

```bash
AGENTKEYS_REPO="$HOME/Projects/agentKeys"
alias ssh-prod='bash $AGENTKEYS_REPO/scripts/ssh-broker.sh prod'
alias ssh-test='bash $AGENTKEYS_REPO/scripts/ssh-broker.sh test'
```

#### 3. `agentkeys-admin` AWS profile

A long-lived IAM user with `IAMFullAccess` + `AmazonS3FullAccess` + `AmazonSESFullAccess` + `AmazonRoute53FullAccess` permissions. Already provisioned per [CLAUDE.md "AWS local-profile ↔ remote-IAM mapping"](../CLAUDE.md). Switch to it before any bootstrap call:

```bash
awsp agentkeys-admin
aws sts get-caller-identity   # → arn:aws:iam::…:user/agentkeys-admin
```

The bootstrap script intentionally doesn't auto-create the admin user — bootstrapping IAM root credentials onto disk is the kind of thing you only do once, by hand, with the IAM Console open.

### §0.2 IAM isolation matrix (prod ↔ test, same AWS account)

Same AWS account is fine — isolation comes from the `-test` suffix on every identifier, not from the account boundary. Cross-trust is structurally impossible because the trust policy on every test role lists ONLY the test OIDC provider ARN (which is bound byte-for-byte to `test-broker.${ZONE}`, never `broker.${ZONE}`).

| Resource | Prod name | Test name | Created by |
|---|---|---|---|
| IAM user (daemon) | `agentkeys-daemon` | `agentkeys-daemon-test` | `setup-cloud.sh` step 10 (suffixed when `--test` flag is passed, or env-file path matches `*test*` as an ergonomic auto-detect) |
| IAM role (data) | `agentkeys-data-role` | `agentkeys-data-role-test` | `setup-cloud.sh` step 11 (same suffix logic) |
| IAM role (vault) | `agentkeys-vault-role` | `agentkeys-vault-role-test` | `provision-vault-role.sh` reads `VAULT_ROLE_ARN` from the active env file |
| IAM role (memory) | `agentkeys-memory-role` | `agentkeys-memory-role-test` | `provision-memory-role.sh` (same env-driven pattern) |
| IAM OIDC provider | `…oidc-provider/broker.${ZONE}` | `…oidc-provider/test-broker.${ZONE}` | manual `aws iam create-open-id-connect-provider` per §9.2 (one per broker URL — AWS validates byte-for-byte) |
| EC2 instance profile | `agentkeys-broker-host` | `agentkeys-broker-host-test` | §6 (optional) |
| EIP (tag) | `agentkeys-broker-eip` | `agentkeys-broker-eip-test` | `setup-cloud.sh` step 4 |
| Mail bucket | `agentkeys-mail-${ACCT}` | `agentkeys-mail-test-${ACCT}` | `setup-cloud.sh` step 7 (from `BUCKET` env var) |
| Vault bucket | `agentkeys-vault-${ACCT}` | `agentkeys-vault-test-${ACCT}` | `provision-vault-bucket.sh` (from `VAULT_BUCKET` env var) |
| Memory bucket | `agentkeys-memory-${ACCT}` | `agentkeys-memory-test-${ACCT}` | `provision-memory-bucket.sh` (from `MEMORY_BUCKET` env var) |
| SES sender | `noreply@bots.${ZONE}` | `noreply-test@bots-test.${ZONE}` | `ses-verify-sender.sh` (from `BROKER_EMAIL_FROM_ADDRESS`) |
| Heima contracts | one set of 6 addresses | a different set of 6 (same chain, different deployer key) | `setup-heima.sh` per deployer key |

**Cross-trust isolation enforced by:**

1. **OIDC provider URL is the trust scope.** Each role's trust policy names exactly one provider ARN. The provider ARN derives from the broker URL. `broker.${ZONE}` and `test-broker.${ZONE}` produce distinct ARNs, so the test OIDC provider literally cannot mint JWTs that prod roles accept.
2. **PrincipalTag scoping (§9.4) layers on top.** Even if a test JWT somehow reached a prod role, the bucket policy condition `s3:prefix=bots/${aws:PrincipalTag/agentkeys_actor_omni}/*` would still scope reads/writes by actor.
3. **Per-data-class bucket separation.** Vault role's IAM grants reference vault bucket only; memory role references memory bucket only. Even within one stack, vault creds in the memory bucket → AccessDenied (defense-in-depth for the cap-mint layer).

`setup-cloud.sh` validates required env keys at step 2 and dies with a precise pointer if missing.

> **Why `jq -n --arg` and not `cat > file.json <<EOF`:** `jq --arg` passes values outside shell parameter expansion, sidestepping the zsh modifier bug (`$VAR:r` etc.) that silently corrupts ARNs. JSON is validated on construction, command substitution feeds straight into `--policy-document`, no file lands on disk. The orchestrator + every helper script applies this convention.

## §1 Identities — mental model

Cloud-agnostic. The four principals exist in every cloud the broker runs on; the cloud changes only which API creates them.

| Identity | Type | Holds | Purpose |
|---|---|---|---|
| `agentkeys-admin` | privileged user | Long-lived access key | One-shot provisioning. Runs every command in this doc. IAM-admin scope. |
| `agentkeys-broker` | scoped user | Long-lived access key | Operator's SSH-into-EC2 path via EC2 Instance Connect (AWS) / SSH key (other clouds). No data-plane access. |
| `agentkeys-daemon` | runtime user | Long-lived access key | The **broker process** uses this at runtime. Only permission: assume the data role. |
| `agentkeys-data-role` | assumed role | (none — assumed) | Holds the actual storage + email permissions. Trusted by the runtime user (Stage 6) or by the OIDC provider (Stage 7). |
| `agentkeys-broker-host` | instance profile (optional) | (none — bound to a VM) | If the broker runs on a managed VM, attach this so the daemon never sees a static key. Runtime creds come from IMDS / metadata server. |

> Why "data role" and not "agent role": the project word "agent" already means three things (the AI agent, the AgentKeys product, an IAM role). The role holds **data-plane** permissions. The broker still accepts the legacy `BROKER_AGENT_ROLE_ARN` env var for backwards compatibility.

## §2 Domain + DNS

Six subdomains under the operator's parent zone (substitute `${ZONE}` everywhere):

| Host | Purpose | Provisioned in |
|---|---|---|
| `${MAIL_DOMAIN}` (e.g. `bots.${ZONE}`) | SES / email backend inbound | §3 |
| `${BROKER_HOST}` (e.g. `broker.${ZONE}`) | Broker public reverse proxy | §10.1 below |
| `signer.${ZONE}` | Signer service (issue #74 step 1b) | §10.1 below |
| `audit.${ZONE}` / `email.${ZONE}` / `cred.${ZONE}` / `memory.${ZONE}` / `config.${ZONE}` | Service workers (issue #90; config = #201 master-only taxonomy) | §10.1 below (dev co-location on broker EIP today) |

Confirm the parent zone is reachable before any record changes (AWS Route 53 example; the same `get-hosted-zone` shape exists on AliCloud DNS + Cloud DNS):

```bash
aws route53 get-hosted-zone --id "$PARENT_ZONE_ID" \
  --query 'HostedZone.{name:Name, private:Config.PrivateZone}'
# → {"name": "${ZONE}.", "private": false}
```

The bulk service-worker A-record creation is automated by [`scripts/dns-upsert-workers.sh`](../scripts/dns-upsert-workers.sh) (AWS Route 53 today). For other providers, replicate the same shape — the hostnames are the migration seam.

## §3 Email backend

### §3.1 Verify the SES domain identity (AWS)

```bash
aws sesv2 create-email-identity \
  --region "$REGION" --email-identity "$MAIL_DOMAIN" \
  --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT
```

Then publish DKIM + SPF + DMARC + MX records in one DNS change. AWS Route 53:

```bash
read -r T1 T2 T3 <<<"$(aws sesv2 get-email-identity --region "$REGION" \
  --email-identity "$MAIL_DOMAIN" --query 'DkimAttributes.Tokens' --output text)"

aws route53 change-resource-record-sets --hosted-zone-id "$PARENT_ZONE_ID" \
  --change-batch "$(jq -n \
    --arg domain "$MAIL_DOMAIN" --arg region "$REGION" \
    --arg t1 "$T1" --arg t2 "$T2" --arg t3 "$T3" '{
      Comment: "AgentKeys email infra for \($domain)",
      Changes: [
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t1)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t1).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t2)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t2).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"\($t3)._domainkey.\($domain)", Type:"CNAME", TTL:300, ResourceRecords:[{Value:"\($t3).dkim.amazonses.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$domain, Type:"MX",  TTL:300, ResourceRecords:[{Value:"10 inbound-smtp.\($region).amazonaws.com"}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:$domain, Type:"TXT", TTL:300, ResourceRecords:[{Value:"\"v=spf1 include:amazonses.com -all\""}]}},
        {Action:"UPSERT", ResourceRecordSet:{Name:"_dmarc.\($domain)", Type:"TXT", TTL:300, ResourceRecords:[{Value:"\"v=DMARC1; p=quarantine; rua=mailto:dmarc@\($domain)\""}]}}
      ]
    }')"
```

Wait ~5 min for DKIM propagation, then verify:

```bash
aws sesv2 get-email-identity --region "$REGION" --email-identity "$MAIL_DOMAIN" \
  --query '{verified: VerifiedForSendingStatus, dkim: DkimAttributes.Status}'
# → {"verified": true, "dkim": "SUCCESS"}
```

> **DKIM key custody:** in this interim setup, the email service holds the private DKIM key (AWS-internal on SES, AliCloud-internal on DirectMail, etc.). Trust surface = provider could forge mail signed as us → bounded blast radius (reputation, not user-data custody). Migration target is TEE-held BYODKIM — track in [`docs/spec/heima-gaps-vs-desired-architecture.md`](spec/heima-gaps-vs-desired-architecture.md) §4. Do **not** intermediate-step to "BYODKIM with file-stored key" (strictly worse than provider-managed).

### §3.2 Create the S3 bucket for inbound mail

```bash
aws s3api create-bucket \
  --region "$REGION" --bucket "$BUCKET" \
  $([ "$REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$REGION")

aws s3api put-public-access-block --region "$REGION" --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 30-day TTL on inbound objects (throwaway-inbox model)
aws s3api put-bucket-lifecycle-configuration --region "$REGION" --bucket "$BUCKET" \
  --lifecycle-configuration "$(jq -n '{
    Rules: [{ID:"inbound-30d-ttl", Status:"Enabled", Filter:{Prefix:"inbound/"}, Expiration:{Days:30}}]
  }')"
```

### §3.3 Create the SES receipt rule

```bash
aws ses create-receipt-rule-set --rule-set-name agentkeys --region "$REGION" 2>/dev/null || true
aws ses create-receipt-rule --region "$REGION" --rule-set-name agentkeys \
  --rule "$(jq -n --arg domain "$MAIL_DOMAIN" --arg bucket "$BUCKET" '{
    Name: "agentkeys-inbound", Enabled: true, ScanEnabled: true, TlsPolicy: "Optional",
    Recipients: [$domain],
    Actions: [{S3Action: {BucketName: $bucket, ObjectKeyPrefix: "inbound/"}}]
  }')"
aws ses set-active-receipt-rule-set --rule-set-name agentkeys --region "$REGION"
```

Inbound MIME lands at `s3://$BUCKET/inbound/<msg_id>`. First object: `AMAZON_SES_SETUP_NOTIFICATION` (provider's "I successfully wrote to your bucket" marker). Real mail follows.

**Sandbox vs production sending:** inbound is unaffected by SES sandbox; **outbound** to arbitrary addresses needs Console → Support → "SES Sending Limits" → "Request Production Access".

## §4 IAM users + roles

### §4.1 `agentkeys-daemon` — broker runtime user

```bash
aws iam create-user --user-name agentkeys-daemon
aws iam create-access-key --user-name agentkeys-daemon
# → save AccessKeyId + SecretAccessKey to your secret manager. NEVER to git.

aws iam put-user-policy --user-name agentkeys-daemon \
  --policy-name agentkeys-daemon-assume-role \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow", Action:"sts:AssumeRole",
      Resource:"arn:aws:iam::\($acct):role/agentkeys-data-role"
    }]
  }')"
```

The daemon user can do exactly one thing: assume `agentkeys-data-role`. Any storage / email action goes through the role's permissions, never the user's.

### §4.2 `agentkeys-data-role` (static-IAM-user trust variant)

The role's trust policy starts with the static-IAM-user variant. After the broker is publicly reachable, [`docs/cloud-bootstrap.md`](cloud-bootstrap.md) §4 swaps it for the OIDC-federated variant.

```bash
aws iam create-role --role-name agentkeys-data-role \
  --assume-role-policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{AWS:"arn:aws:iam::\($acct):user/agentkeys-daemon"},
      Action:"sts:AssumeRole"
    }]
  }')"

aws iam put-role-policy --role-name agentkeys-data-role \
  --policy-name agentkeys-data-role-inline \
  --policy-document "$(jq -n \
    --arg bucket "$BUCKET" --arg region "$REGION" \
    --arg acct "$ACCOUNT_ID" --arg domain "$MAIL_DOMAIN" '{
      Version:"2012-10-17",
      Statement:[
        {Effect:"Allow", Action:"s3:ListBucket", Resource:"arn:aws:s3:::\($bucket)"},
        {Effect:"Allow", Action:"s3:GetObject",  Resource:"arn:aws:s3:::\($bucket)/*"},
        {Effect:"Allow", Action:["ses:SendEmail","ses:GetEmailIdentity"],
         Resource:["arn:aws:ses:\($region):\($acct):identity/\($domain)",
                   "arn:aws:ses:\($region):\($acct):identity/*@\($domain)"]}
      ]
    }')"

export ROLE_ARN=$(aws iam get-role --role-name agentkeys-data-role --query 'Role.Arn' --output text)
echo "ROLE_ARN=$ROLE_ARN"
```

### §4.3 Per-data-class roles (`agentkeys-vault-role`, `agentkeys-memory-role`)

Per arch.md §17.2: separate roles for credentials + memory data classes. Same trust shape as §4.2, distinct inline policies + PrincipalTag scoping. Provisioned by per-data-class helpers (idempotent):

```bash
bash scripts/provision-vault-bucket.sh        # agentkeys-vault-${ACCOUNT_ID}
bash scripts/provision-vault-role.sh          # agentkeys-vault-role
bash scripts/apply-vault-bucket-policy.sh     # v3 split-statement PrincipalTag policy

bash scripts/provision-memory-bucket.sh
bash scripts/provision-memory-role.sh
bash scripts/apply-memory-bucket-policy.sh

bash scripts/cleanup-mail-bucket-policy.sh    # restore email-only grants on $BUCKET
```

These scripts are the **source of truth** for the policy shape — read them, don't transcribe.

### §4.4 `agentkeys-admin`, `agentkeys-broker` (already provisioned)

If you reached this section, `agentkeys-admin` exists (you're using it). `agentkeys-broker` is whatever IAM user you SSH into the broker host with — its perms are out of scope (`ec2-instance-connect:SendSSHPublicKey` on the host's instance ID is sufficient for AWS Instance Connect).

## §5 S3 bucket policy (initial, static-IAM variant)

```bash
aws s3api put-bucket-policy --region "$REGION" --bucket "$BUCKET" \
  --policy "$(jq -n --arg bucket "$BUCKET" --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[
      {
        Sid:"AllowSESWriteInbound", Effect:"Allow",
        Principal:{Service:"ses.amazonaws.com"},
        Action:"s3:PutObject",
        Resource:"arn:aws:s3:::\($bucket)/*",
        Condition:{StringEquals:{"aws:Referer":$acct}}
      },
      {
        Sid:"AllowDaemonRead", Effect:"Allow",
        Principal:{AWS:"arn:aws:iam::\($acct):role/agentkeys-data-role"},
        Action:["s3:GetObject","s3:ListBucket"],
        Resource:["arn:aws:s3:::\($bucket)","arn:aws:s3:::\($bucket)/*"]
      }
    ]
  }')"
```

The PrincipalTag-scoped federated variant (which replaces this once OIDC federation is up) lives in [`docs/cloud-bootstrap.md`](cloud-bootstrap.md) §4.4.

## §6 `agentkeys-broker-host` instance profile (EC2-only, optional)

If the broker runs on AWS EC2, attach this so the daemon never holds a static key. Runtime creds come from IMDS.

```bash
ROLE=agentkeys-broker-host

aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document "$(jq -n '{
    Version:"2012-10-17",
    Statement:[{Effect:"Allow", Principal:{Service:"ec2.amazonaws.com"}, Action:"sts:AssumeRole"}]
  }')"

aws iam put-role-policy --role-name "$ROLE" --policy-name BrokerAssumeData \
  --policy-document "$(jq -n --arg acct "$ACCOUNT_ID" '{
    Version:"2012-10-17",
    Statement:[{Effect:"Allow", Action:"sts:AssumeRole",
                Resource:"arn:aws:iam::\($acct):role/agentkeys-data-role"}]
  }')"

aws iam create-instance-profile --instance-profile-name "$ROLE"
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
aws ec2 associate-iam-instance-profile --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --iam-instance-profile Name="$ROLE"
```

> **Caller-region trap:** `agentkeys-admin` profile defaults to `us-west-2`; the broker EC2 usually lives in `us-east-1`. Without `--region "$REGION"`, `describe-instances` silently returns empty and downstream `put-role-policy` runs with `--role-name ""`. Pass `--region` explicitly on every regional call. See [CLAUDE.md "AWS local-profile ↔ remote-IAM mapping"](../CLAUDE.md).

### §6.1 `ses:SendEmail` grant on the runtime role

The broker calls SES v2 `SendEmail` with its **own** runtime credentials (instance profile), not via the assumed `agentkeys-data-role`. Without `ses:SendEmail` on the broker's role, the operator hits:

```
broker rejected /v1/auth/email/request: status=502 body=
{"error":"backend_unreachable","message":"… ses SendEmail:
 unhandled error (AccessDeniedException)"}
```

The IAM action is `ses:SendEmail` (sesv2), NOT `ses:SendRawEmail` (v1; different code path the broker doesn't use). The grant lives on the broker's runtime role (`agentkeys-broker-host` on EC2; the user `agentkeys-daemon` otherwise) — see [`docs/cloud-bootstrap.md`](cloud-bootstrap.md) §3.3 for the exact statement.

## §7 Security audit — strip legacy over-broad attached policies

Some early deploys ship with `AmazonS3FullAccess` (or similar wide permissions) attached to the broker's runtime role. The broker at runtime ONLY uses `aws-sdk-sts` (the GetCallerIdentity startup probe) + `aws-sdk-sesv2` (the §6.1 grant) — it never accesses S3 with its own creds. Per-user S3 is via JWT-assumed `agentkeys-{data,vault,memory}-role`, not the broker's runtime role.

A broker compromise with `AmazonS3FullAccess` would expose every inbound email in the SES bucket (verification tokens, magic links). Strip it:

```bash
# Discover the actual role attached to the broker host (canonical name:
# agentkeys-broker-host; some early deploys landed on different names):
INSTANCE_PROFILE_ARN=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=ip-address,Values=$EIP" \
  --query 'Reservations[].Instances[].IamInstanceProfile.Arn' --output text)

ROLE=$(aws iam get-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE_ARN##*/}" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)
echo "broker runtime role: $ROLE"

# Audit attached policies:
aws iam list-attached-role-policies --role-name "$ROLE"

# Detach AmazonS3FullAccess if present:
aws iam detach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# Verify only the narrow inline policy (BrokerSendEmail + AssumeDataRole) remains:
aws iam list-role-policies --role-name "$ROLE"
aws iam list-attached-role-policies --role-name "$ROLE"
```

## §8 Cloud-provider portability

Every layer in §3–§5 has a 1:1 analog on the major providers. The provisioning shape carries; only the API endpoints + JSON dialects differ.

| Layer | AWS (current) | AliCloud (in progress) | GCP | Tencent Cloud |
|---|---|---|---|---|
| Privileged user | IAM user with `IAMFullAccess` | RAM user with `AliyunRAMFullAccess` | IAM service account with `roles/iam.securityAdmin` | CAM user with `AdministratorAccess` |
| Runtime user | IAM user + access key | RAM user + AK/SK | Service account + key file (or Workload Identity) | CAM user + SecretId/SecretKey |
| Data role | IAM role + assume policy | RAM role + assume policy | Service account + IAM bindings | CAM role + assume policy |
| Federation | IAM OIDC provider | RAM IDaaS / OIDC provider | Workload Identity Pool | CAM OIDC provider |
| Object store | S3 + bucket policy | OSS + bucket policy | Cloud Storage + IAM bindings | COS + bucket policy |
| Email backend | SES + S3 receipt rule | DirectMail / SimpleDM + OSS event notification | SendGrid / Mailgun (no GCP-native) | SimpleDM + COS |
| TLS termination | nginx + Let's Encrypt | nginx + Let's Encrypt | nginx + Let's Encrypt | nginx + Let's Encrypt |
| Compute (broker host) | EC2 + EIP | ECS + EIP | Compute Engine + external IP | CVM + EIP |
| DNS | Route 53 | AliCloud DNS | Cloud DNS | DNSPod / Cloud DNS |
| Secrets storage | Secrets Manager / SSM Parameter Store | KMS Secrets Manager | Secret Manager | KMS |

**Migration playbook (cloud → cloud):**

1. Re-bind operator-workstation.env to the new provider's identifiers (account ID, region, role ARNs, bucket name).
2. Re-run this doc top-to-bottom against the new provider.
3. Re-run §9 (OIDC federation activation) — substitute the provider's OIDC API.
4. Re-run `scripts/setup-broker-host.sh` on the new host (the script doesn't care which cloud — it consumes already-provisioned identifiers).
5. Re-run `scripts/setup-heima.sh` — the chain side is cloud-agnostic.
6. Re-run the harness scripts to validate end-to-end.

The boundary is sharp: the broker process itself contains zero cloud-specific code — it talks STS-compatible OIDC + S3-compatible PutObject/GetObject + SMTP-compatible SendEmail. Every cloud above offers all three primitives. The [`provisioner-scripts/email-backends/`](../provisioner-scripts/) directory documents the email-backend trait; a new backend slots in as `tencent-simpledm-cos` (or similar) with the same upstream API as `ses-s3`.

## §9 OIDC federation activation (after broker is publicly reachable)

The broker mints OIDC JWTs that AWS STS validates via the broker's public JWKS endpoint. Three one-shot steps per account, run AFTER `setup-broker-host.sh` finishes and the broker is reachable at `https://${BROKER_HOST}` over public TLS.

### §9.1 Prereqs

- `https://${BROKER_HOST}/.well-known/openid-configuration` returns 200 with the expected `issuer` + `jwks_uri`.
- `https://${BROKER_HOST}/.well-known/jwks.json` returns at least one ES256 key.
- `curl -sf "https://${BROKER_HOST}/healthz"` returns 200.

### §9.2 Register the OIDC provider

```bash
# DoH-resolved EIP (immune to local DNS interception; see §5b verify steps):
broker_ip=$(curl -sS "https://dns.google/resolve?name=${BROKER_HOST}&type=A" | jq -r '.Answer[0].data')

# -sha1 is REQUIRED. macOS LibreSSL 3.3 + OpenSSL 3.x default to SHA256
# (64 hex chars) but AWS IAM CreateOpenIDConnectProvider rejects anything
# that isn't exactly 40 hex chars (SHA1).
thumb=$(echo | openssl s_client -servername "$BROKER_HOST" \
                                 -connect "${broker_ip}:443" 2>/dev/null \
          | openssl x509 -fingerprint -sha1 -noout \
          | awk -F'=' '{print $2}' | tr -d ':' | tr 'A-Z' 'a-z')
[ ${#thumb} -eq 40 ] || { echo "thumb length ${#thumb} != 40 — check -sha1 flag" >&2; return 1; }

aws iam create-open-id-connect-provider \
  --url "https://${BROKER_HOST}" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "$thumb"
```

**AWS validates the issuer URL byte-for-byte** against the JWT `iss` claim. Once registered, the URL is effectively immutable — switching means a new provider ARN + new trust policy + new federated grants.

### §9.3 Trust policy (federated variant)

Apply to each of the three data roles. Use `$ROLE` ∈ `{agentkeys-data-role, agentkeys-vault-role, agentkeys-memory-role}` (or the `-test` variants when bootstrapping the CI test instance).

```bash
aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$(jq -n \
  --arg acct "$ACCOUNT_ID" --arg host "$BROKER_HOST" '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Federated:"arn:aws:iam::\($acct):oidc-provider/\($host)"},
      Action:"sts:AssumeRoleWithWebIdentity",
      Condition:{StringEquals:{"\($host):aud":"sts.amazonaws.com"}}
    }]
  }')"
```

### §9.4 PrincipalTag-scoped bucket policy

Per CLAUDE.md "Per-actor + per-data-class isolation invariants": every S3 read/write is scoped to `bots/${aws:PrincipalTag/agentkeys_actor_omni}/{credentials,memory}/*`. The split-statement v3 bucket policy is applied by [`scripts/apply-{vault,memory}-bucket-policy.sh`](../scripts/) — those scripts are the source of truth for the policy shape.

After §9.3 + §9.4, strip the broad-bucket inline grant from the role's policy (the bucket-side policy enforces; defense in depth means no app-side grant):

```bash
aws iam delete-role-policy --role-name "$ROLE" --policy-name "${ROLE}-inline"
```

### §9.5 End-to-end proof

Run [`harness/v2-stage3-demo.sh`](../harness/v2-stage3-demo.sh) (or `bash harness/run.sh --stage 3`) — it mints session JWT → OIDC JWT → STS creds, then proves both POSITIVE (own prefix) and NEGATIVE (cross-actor prefix → AccessDenied) writes for both data classes plus the cross-role isolation matrix. Walks the full §17.2 isolation table from CLAUDE.md.

## §10 Broker host bring-up: `setup-broker-host.sh`

§§3–8 set up identifiers. This step stands up the actual processes — broker + mock-server + signer + 5 service workers (audit/email/cred/memory/config) — on the EC2 host (or any Linux box with public-internet egress + the broker's hostname).

### §10.1 Prereqs

- Fresh Linux host with sudo, systemd, public-internet egress, ports 80 + 443 open inbound (for certbot + nginx).
- DNS A records for `${BROKER_HOST}` + `signer.${ZONE}` + `audit.${ZONE}` + `email.${ZONE}` + `cred.${ZONE}` + `memory.${ZONE}` + `config.${ZONE}` all pointing at the host's public IP (provisioned by `setup-cloud.sh` step 6 — broker/signer/mcp inline, the 5 service workers via `dns-upsert-workers.sh`).
- AWS credentials in `/etc/agentkeys/broker.env` (the script writes the template; operator pastes the `agentkeys-daemon` access key from §4.1).

### §10.2 Run

```bash
# Bootstrap a fresh host:
sudo bash scripts/setup-broker-host.sh \
  --issuer-url "https://${BROKER_HOST}" \
  --account-id "${ACCOUNT_ID}" \
  --signer-host "signer.${ZONE}" \
  --audit-host  "audit.${ZONE}" \
  --email-host  "email.${ZONE}" \
  --cred-host   "cred.${ZONE}" \
  --memory-host "memory.${ZONE}" \
  --config-host "config.${ZONE}" \
  --yes

# After a `git pull`, the same command re-deploys:
sudo bash scripts/setup-broker-host.sh --yes
```

The script:
- Builds `agentkeys-broker-server` (+ `auth-email-link` feature), `agentkeys-mock-server`, the 5 service workers (audit/email/cred/memory/config), and the signer. Compilations are cached with **sccache** (a content-addressed compiler cache, auto-installed best-effort) so re-deploys + `--ref` branch switches reuse the cache instead of recompiling — even when `git checkout` churns mtimes or `target/` is cold. The build prints `sccache stats` afterward (re-deploys should be mostly cache hits). Opt out with `AGENTKEYS_NO_SCCACHE=1`; pin a version with `SCCACHE_VERSION=vX.Y.Z`.
- Creates the `agentkeys` system user + state dir `/var/lib/agentkeys/`.
- Writes the dev_key_service master secret (one-shot at first boot, never rotated — rotation invalidates every previously-derived wallet).
- Writes per-worker env files at `/etc/agentkeys/worker-{audit,email,creds,memory,config}.env`.
- Writes systemd units for broker + signer + each worker, enables + starts.
- Configures nginx vhosts for `${BROKER_HOST}` + `signer.${ZONE}` + 5 worker hosts (audit/email/cred/memory/config) (skip via `--without-nginx`). Vhost is rendered in two phases: Phase A (HTTP-only on `:80`, with the ACME challenge path under `/.well-known/acme-challenge/` and a 503 placeholder on `/`) when no cert is on disk; Phase B (HTTPS on `:443`, broker proxy on `/`) when `/etc/letsencrypt/live/<host>/fullchain.pem` exists. Re-running the script after certbot issuance flips A → B automatically.
- **Installs certbot but does NOT run it.** Cert issuance is DNS-dependent — see quick-start §5b for the per-vhost `certbot certonly --webroot` recipe operators run manually once DNS is in place.
- Mints broker keypairs (oidc + session) under `/var/lib/agentkeys/keys/`.

Auto-detects bootstrap vs upgrade by reading the existing systemd unit's `Environment=` lines. Pass `--ref <branch>` to opt into an in-script `git fetch + pull`.

### §10.3 Verify

```bash
curl -sf "https://${BROKER_HOST}/healthz"                  # → 200
curl -sf "https://${BROKER_HOST}/.well-known/openid-configuration" | jq .
curl -sf "https://${BROKER_HOST}/.well-known/jwks.json"    | jq '.keys | length'
curl -sf "https://audit.${ZONE}/healthz"                   # → 200 (and friends)
```

For full E2E (broker + workers + chain + AWS), run `bash harness/run.sh` — see [`docs/chain-setup.md`](chain-setup.md) for the chain side and [`docs/ci-setup.md`](ci-setup.md) for the automated path.

## §11 Cleanup (full account teardown)

Tear down the whole AgentKeys footprint in one account. Use only when retiring the deployment.

```bash
# Drain the buckets
for b in "$BUCKET" "agentkeys-vault-${ACCOUNT_ID}" "agentkeys-memory-${ACCOUNT_ID}"; do
  aws s3 rm "s3://$b" --recursive 2>/dev/null || true
  aws s3api delete-bucket --bucket "$b" --region "$REGION" 2>/dev/null || true
done

# Roles
for r in agentkeys-data-role agentkeys-vault-role agentkeys-memory-role agentkeys-broker-host; do
  for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p"
  done
  aws iam delete-role --role-name "$r" 2>/dev/null || true
done

# OIDC provider
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${BROKER_HOST}"

# Daemon user
for k in $(aws iam list-access-keys --user-name agentkeys-daemon --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name agentkeys-daemon --access-key-id "$k"
done
aws iam delete-user-policy --user-name agentkeys-daemon --policy-name agentkeys-daemon-assume-role 2>/dev/null || true
aws iam delete-user --user-name agentkeys-daemon

# SES + DNS
aws ses set-active-receipt-rule-set --rule-set-name "" --region "$REGION" 2>/dev/null || true
aws sesv2 delete-email-identity --email-identity "$MAIL_DOMAIN" --region "$REGION" 2>/dev/null || true
# DNS records: operator-managed (Route 53 / your DNS provider) — delete by hand.

# EC2 + EIP: manual via console or aws ec2 CLI
```

For the test instance, substitute `-test` on every identifier above.

## Related

- Operator workstation setup: [`docs/dev-setup.md`](dev-setup.md)
- Chain bring-up: [`docs/chain-setup.md`](chain-setup.md)
- CI activation: [`docs/ci-setup.md`](ci-setup.md)
- Broker host script (single entry point): [`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh)
- Cloud bootstrap script (single entry point): [`scripts/setup-cloud.sh`](../scripts/setup-cloud.sh)
- Architecture (per-data-class buckets + isolation invariants): [`docs/arch.md`](arch.md) §17, §17.2
- Future Tencent / TEE DKIM: [`docs/spec/heima-gaps-vs-desired-architecture.md`](spec/heima-gaps-vs-desired-architecture.md) §4
- FAQ + troubleshooting: [`wiki/cloud-setup-faq.md`](../wiki/cloud-setup-faq.md)
