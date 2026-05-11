# Stage 7 — Pluggable Broker: Complete Demo & Verification Guide

This guide is the operator-facing companion to
[`docs/spec/plans/issue-64/PHASE-0-CHECKPOINT.md`](spec/plans/issue-64/PHASE-0-CHECKPOINT.md).
That checkpoint covered Phase 0 in isolation against `localhost`. **This
guide is the end-to-end production demo** for the full Stage 7 pluggable
broker (Phase 0 + A.1 + A.2 + B + C-structural + D-rest + E) **and the
new dev_key_service signer flow from issue #74 step 1** (the
operator-holds-no-keys path), running on a real EC2 broker host with the
AWS account from [`cloud-setup.md`](cloud-setup.md).

When you finish this guide you will have:

1. Confirmed the broker process boots cleanly past Tier-1 + Tier-2.
2. Verified AWS IAM accepts the broker's OIDC discovery + JWKS.
3. Walked the **managed-wallet** SIWE auth flow end-to-end without
   ever holding a private key locally — the dev_key_service signs on
   behalf of the operator's `omni_account` (the master actor omni
   per [`architecture.md` §4](spec/architecture.md)).
4. Minted real AWS STS credentials via the post-issue-#71 daemon-side
   flow (`/v1/mint-oidc-jwt` + client-side `AssumeRoleWithWebIdentity`).
5. **Proven cloud-enforced per-user isolation** — `omni_A`'s derived
   wallet reads its own prefix; `omni_B`'s derived wallet returns
   `AccessDenied` from S3 itself, not from app code.
6. Inspected the audit log + metrics + idempotency cache.
7. Exercised capability grants and wallet recovery.

The guide assumes the build deployed includes:

- The Stage 7 pluggable broker (`/.well-known/openid-configuration`
  advertises `wallet_sig` + `email_link` + `oauth2_*` auth methods).
- Issue #74 step 1's signer protocol (the backend exposes
  `POST /dev/derive-address` + `POST /dev/sign-message` per
  [`docs/spec/signer-protocol.md`](spec/signer-protocol.md)).

If you're on a pre-issue-#74 build, run
`scripts/setup-broker-host.sh --upgrade` first and come back.

---

## Trust model (post-issue-#74 step 1b)

> **Status: v1c-interim demo.** This guide exercises what's
> actually shipped in PR #75: bearer-JWT auth on `/dev/*` (step
> 1b), bespoke per-identity PoP shapes (step 1c v1c-interim). The
> v0.2 target — HDKD per-agent omni + uniform WebAuthn binding
> for masters — is documented in
> [`docs/spec/architecture.md`](spec/architecture.md) §4 (HDKD
> actor tree), §4a (mental model), and §5a (per-actor binding
> ceremonies) but is **not yet implemented**. See
> [step-1c plan](spec/plans/issue-74-step-1c-device-key-auth.md)
> for the wire-shape evolution and gh
> [#76](https://github.com/litentry/agentKeys/issues/76) /
> [#79](https://github.com/litentry/agentKeys/issues/79) for the
> tracking issues. The wire shape (`/dev/derive-address`,
> `/dev/sign-message`), the auth flow at the broker, and the AWS
> isolation proof do NOT change between v1c and v0.2.

```
Operator workstation / daemon                         Broker host (EC2)
┌────────────────────────────┐                        ┌──────────────────────────────┐
│ agentkeys (CLI / daemon)   │                        │ agentkeys-signer             │
│   • holds NO private key   │  HTTPS (TLS, JWT auth) │   signer.litentry.org:443    │
│   • holds session JWT      │  POST /dev/derive ─▶   │   ──▶ :8092 (loopback)       │
│                            │  ◀── {address}    ───  │   /dev/derive-address        │
│                            │  POST /dev/sign   ─▶   │   /dev/sign-message          │
│                            │  ◀── {signature}  ───  │   JWT bearer verified on     │
│                            │                        │   every request              │
└──────┬─────────────────────┘                        │                              │
       │                                              │ agentkeys-backend (:8090)    │
       │ POST /v1/auth/wallet/{start,verify}          │   loopback only (broker's    │
       │ POST /v1/mint-oidc-jwt                       │   Tier-2 backend probe)      │
       │ POST /v1/wallet/link                         │                              │
       ▼                                              │ agentkeys-broker  (:8091)    │
   broker.litentry.org:443                            │   broker.litentry.org:443    │
   (stateless minter — verifies session JWT           └──────────────────────────────┘
    cryptographically)
```

The signer is the trust boundary that owns the EVM keypair. It is now an
**independent backend listener** (`signer.litentry.org` → `:8092`) separate
from the mock-server backend (`:8090`). JWT bearer auth on every `/dev/*`
request means the signer never serves unauthenticated key operations.

**Issue #74 step 2** swaps the HKDF dev_key_service for a TEE worker behind
the same `/dev/*` wire shape — daemon and CLI code do not change.

---

## Two-machine layout

Most steps below run on one of two machines. Each step is tagged with an
inline `# === ON … ===` banner.

| Machine | What it has | Used for |
|---|---|---|
| **Operator workstation (master role)** | `awsp agentkeys-admin` profile, `$ACCOUNT_ID` / `$BROKER_HOST` / `$BUCKET` shell vars from `cloud-setup.md §0`, `agentkeys` CLI, `aws` CLI, `jq` | AWS-side checks, `aws sts assume-role-with-web-identity`, S3 isolation proof, calling the broker + signer over HTTPS. The operator running these commands IS the master per [`architecture.md` §4a](spec/architecture.md). |
| **Broker host (EC2)** | `agentkeys-broker-server` and `agentkeys-mock-server` binaries at `/usr/local/bin/`, both ES256 keypairs at `/var/lib/agentkeys/.agentkeys/broker/`, systemd services `agentkeys-broker.service` + `agentkeys-backend.service` + `agentkeys-signer.service`, nginx fronting broker on `:8091` at `https://$BROKER_HOST` and signer on `:8092` at `https://signer.<zone>` | Broker process, audit DB, JWT minting, **dev_key_service signer** |

Hop between them with `ssh agentkey@$BROKER_HOST`.

> **Roles + key inventory primer.** This demo exercises the **master**
> role only (workstation = master per [`architecture.md` §4a](spec/architecture.md)).
> The **agent** role (sandbox VM / CI runner / `agent-infra/sandbox`
> container, bootstrapped via link-code from a master) is documented
> in [`architecture.md` §5a.2](spec/architecture.md) and the
> [agent wiki page](../.omc/wiki/agent-role-and-usage-hdkd-per-agent-omni.md)
> but is **not exercised here** — the v0.2 `agentkeys agent create`
> endpoint isn't shipped yet (tracked in
> [#76](https://github.com/litentry/agentKeys/issues/76)). For the
> K-numbered key inventory referenced throughout (K1 = broker session
> keypair, K3 = dev-signer master secret, K4 = per-actor derived
> wallet, K6 = session JWT, K7 = OIDC JWT, K10 = device key, K11 =
> WebAuthn credential), see [`architecture.md` §3](spec/architecture.md).

---

## 0. Prerequisites checklist

Run on your **operator workstation**. All workstation-side env vars
that the rest of this guide references (`$ACCOUNT_ID`, `$REGION`,
`$BROKER_HOST`, `$BUCKET`, `$OIDC_ISSUER`, `$OIDC_PROVIDER_ARN`,
`$DATA_ROLE_ARN`) live in [`scripts/operator-workstation.env`](../scripts/operator-workstation.env)
— the workstation companion to [`scripts/broker.env`](../scripts/broker.env)
(broker-host scope).

```bash
# === ON OPERATOR WORKSTATION ===
awsp agentkeys-admin
set -a; source scripts/operator-workstation.env; set +a

# Sanity — every step below depends on these.
test -n "$ACCOUNT_ID" && test -n "$BROKER_HOST" && test -n "$BUCKET" \
  && echo "env ok" || echo "env MISSING — check scripts/operator-workstation.env"
```

Cloud-side state from [`cloud-setup.md`](cloud-setup.md):

- `§0` — env vars, awsp profile.
- `§1` — DNS A record for `$BROKER_HOST`.
- `§3` — `agentkeys-{admin,broker,daemon}` IAM users +
  `agentkeys-data-role` + `agentkeys-mail-*` S3 bucket.
- `§4` — OIDC provider registered for `$OIDC_ISSUER`,
  `agentkeys-data-role` trust policy swapped to OIDC-federated form,
  S3 bucket policy upgraded to PrincipalTag-scoped.

Broker-host state (from
[`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh)):

- `agentkeys-broker.service`, `agentkeys-backend.service`, and
  `agentkeys-signer.service` enabled and active.
- `/usr/local/bin/agentkeys-broker-server` and
  `/usr/local/bin/agentkeys-mock-server` match the binaries built from
  this branch (issue #74 step 1b).
- nginx fronting `:8091` at `https://$BROKER_HOST` with a valid TLS cert.
- nginx fronting `:8092` (signer-only) at `https://signer.<zone>` with a
  valid TLS cert (issued via `sudo certbot --nginx -d signer.<zone>`).
- `/var/lib/agentkeys/.agentkeys/broker/session-keypair.pub.pem` exists
  (written by the broker at boot; read by the signer for JWT auth).

Tooling on the workstation:

- `aws` CLI v2.
- `jq` (JSON parsing).
- `shasum` or `sha256sum` (for omni_account computation — present on
  every macOS / Linux box).
- `agentkeys` CLI **built from this branch and on `$PATH`** — see the
  ordered build steps below.

```bash
# === ON OPERATOR WORKSTATION ===
# 1. Drop any conflicting aliases FIRST. zsh aliases beat $PATH lookups,
#    so a stale `alias agentkeys=./target/release/agentkeys-cli` (note
#    the wrong crate-name binary) shadows the install no matter how
#    correctly you stage the binary in step 2.
sed -i.bak '/^alias agentkeys[-= ]/d; /^alias agentkeys-daemon[-= ]/d; /^alias agentkeys-mock-server[-= ]/d' \
  ~/.zshenv ~/.zshrc 2>/dev/null || true
unalias agentkeys agentkeys-daemon agentkeys-mock-server 2>/dev/null || true

# 2. Ensure ~/.local/bin is on $PATH (idempotent; appends only if missing).
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : already on PATH ;;
  *) echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshenv
     export PATH="$HOME/.local/bin:$PATH" ;;
esac

# 3. Build from this branch (NOT a prior tag — signer protocol moved
#    post-issue-#74). The crate is `agentkeys-cli`; the binary it
#    produces is named `agentkeys` (NOT `agentkeys-cli`).
cd /path/to/agentKeys     # repo root, NOT the parent dir
cargo build --release -p agentkeys-cli -p agentkeys-daemon -p agentkeys-mock-server

# 4. Install to ~/.local/bin (now on $PATH from step 2).
mkdir -p ~/.local/bin
cp target/release/agentkeys             ~/.local/bin/
cp target/release/agentkeys-daemon      ~/.local/bin/
cp target/release/agentkeys-mock-server ~/.local/bin/

# 5. Verify with `command` (bypasses any remaining alias zsh hasn't
#    re-hashed away yet). Output MUST be ~/.local/bin/agentkeys, NOT
#    `agentkeys: aliased to …` and NOT `target/release/agentkeys-cli`.
hash -r                                    # zsh: forget cached lookups
command -v agentkeys                       # → /Users/<you>/.local/bin/agentkeys
agentkeys --version
agentkeys signer --help                    # confirms the signer subcommand exists
```

> **If `command -v agentkeys` still prints `agentkeys: aliased to …`,**
> the alias is set in a config file step 1 didn't catch (e.g.
> `~/.zprofile`, `~/.aliases`, or shell-specific include). Run
> `grep -rn 'alias agentkeys' ~/.zshenv ~/.zshrc ~/.zprofile ~/.aliases 2>/dev/null`
> to find it, delete it, then `exec zsh -l` to reload.

After the build is on `$PATH`, run `agentkeys init` once to save a
session JWT in the OS keychain (the CLI auto-attaches it as
`Authorization: Bearer …` on every `/dev/*` call in §0.4).

> **No `cast`, no Foundry, no local private keys.** The pre-issue-#74
> path required `cast wallet new` to mint operator-held EVM keypairs
> and `cast wallet sign` to produce SIWE signatures. **Both are gone
> in this guide.** The operator picks an `(identity_type,
> identity_value)` like `("email", "alice@demo.example")`; the
> dev_key_service derives the wallet and signs SIWE messages on the
> operator's behalf.

> **Why every JSON pipe below uses `printf '%s' "$VAR" | jq` instead
> of `echo "$VAR" | jq`.** zsh's builtin `echo` interprets `\n` (two
> ASCII chars `\` + `n`) as a literal `0x0A` newline. The broker's
> SIWE response embeds `\n` inside the `siwe_message` JSON string as
> a JSON escape, and `echo` corrupts those escapes into raw newlines,
> breaking jq with `Invalid string: control characters … must be
> escaped`. `printf '%s'` is portable across bash and zsh and never
> re-interprets escapes.

### 0.1 Confirm the dev_key_service is enabled on the broker host

`scripts/setup-broker-host.sh` auto-generates `DEV_KEY_SERVICE_MASTER_SECRET`
on first run, persists it to `/etc/agentkeys/dev-key-service.env` (mode
0600, owner `agentkeys`), and wires both the backend and signer systemd
units to read it via `EnvironmentFile=`. The script is **idempotent** —
re-running it preserves the existing secret, so an upgrade does not
invalidate any previously-derived wallet.

If you've never run the script on this host, do it once. Stay on the
branch you intend to deploy — `evm` for production, the PR branch
(e.g. `claude/practical-noether-670bd8`) when validating a PR
end-to-end. The script builds whatever's currently checked out.

```bash
# === ON BROKER HOST ===
ssh agentkey@$BROKER_HOST
cd ~/agentKeys
BRANCH="${BRANCH:-evm}"   # override on the SSH command line for PR branches
git fetch origin && git checkout "$BRANCH" && git pull --ff-only
sudo bash scripts/setup-broker-host.sh --yes
```

Either way, confirm all three services are active **and** that the
signer's nginx vhost was actually written (the recurring failure mode
is `setup-broker-host.sh` running but skipping the vhost write — every
downstream cert / smoke-test command then dies with a confusing 503 or
"only broker.<zone> in certbot list"):

```bash
# === ON BROKER HOST ===
sudo systemctl is-active agentkeys-backend agentkeys-broker agentkeys-signer
# active
# active
# active

# Signer-only listener is up on loopback.
curl -sS http://127.0.0.1:8092/healthz
# ok

# /session endpoints are absent on :8092 (defense-in-depth).
curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8092/session/create
# 404

# nginx vhosts for BOTH hostnames exist + are enabled.
ls /etc/nginx/sites-enabled/agentkeys-broker /etc/nginx/sites-enabled/agentkeys-signer
# /etc/nginx/sites-enabled/agentkeys-broker
# /etc/nginx/sites-enabled/agentkeys-signer
#
# If either is missing → re-pull + re-run setup-broker-host.sh. If
# `agentkeys-signer` is a "TLS not yet issued" stub, jump to §6.2 of
# cloud-setup.md (issue cert + re-run script to flip onto :443 ssl).
grep -E 'proxy_pass|return 503' /etc/nginx/sites-available/agentkeys-signer
# Expect: 2x proxy_pass http://127.0.0.1:8092 (for /dev/ and /healthz)
# Reject: any `return 503` (means cert issued but script never re-ran)
```

If you see HTTP 503 with `"error":"signer_disabled"` from `:8092`, the
env file didn't load — check `sudo systemctl show agentkeys-signer |
grep EnvironmentFile` and confirm `/etc/agentkeys/dev-key-service.env`
exists with mode 0600.

> **Do NOT regenerate `/etc/agentkeys/dev-key-service.env`** unless you
> have already migrated every operator off the old derivation. The
> file is intentionally pinned across re-runs of `setup-broker-host.sh`.
> Issue #74 step 2 (TEE worker) defines the formal rotation runbook.

### 0.2 Set the signer URL

`$BACKEND_URL` / `$AGENTKEYS_SIGNER_URL` are the public HTTPS URL of the
dedicated signer listener (`signer.<zone>`). No SSH tunnel required — the
signer is fronted by nginx over TLS, co-located with the broker on the same
EC2 host (see [`cloud-setup.md` §1.3](cloud-setup.md#13-signer-subdomain--a-record--tls-cert-issue-74-step-1b)
for the topology + future-split note).

Both vars are pre-set in [`scripts/operator-workstation.env`](../scripts/operator-workstation.env)
(sourced in §0 above) — `SIGNER_HOST=signer.${BROKER_HOST#*.}` and
`AGENTKEYS_SIGNER_URL=https://${SIGNER_HOST}`. Confirm + smoke-test:

```bash
# === ON OPERATOR WORKSTATION ===
echo "SIGNER_HOST=$SIGNER_HOST"
echo "AGENTKEYS_SIGNER_URL=$AGENTKEYS_SIGNER_URL"
# SIGNER_HOST=signer.litentry.org
# AGENTKEYS_SIGNER_URL=https://signer.litentry.org

# Smoke-test — body MUST be exactly "ok". A successful HTTP 200 with a
# different body (e.g. "TLS cert not yet issued for signer …") means
# nginx is serving the pre-cert stub vhost — see the "Common failure
# modes" table below.
BODY=$(curl -sS "$BACKEND_URL/healthz")
if [ "$BODY" = "ok" ]; then
  echo "signer healthz ok"
else
  echo "signer healthz UNEXPECTED body: '$BODY'" >&2
fi
```

| `$BODY` value | Cause | Fix |
|---|---|---|
| `ok` | Healthy. | Continue. |
| `TLS cert not yet issued for signer — see setup-broker-host.sh` | Cert is issued but nginx still serving the HTTP-only stub vhost — `setup-broker-host.sh` step 3 of §6.2 wasn't run. | On broker host: `sudo bash scripts/setup-broker-host.sh --yes` (script detects cert, overwrites vhost with `proxy_pass`). |
| (curl error: TLS) | Cert not issued at all. | Run [`cloud-setup.md` §6](cloud-setup.md#6-signer-host) end-to-end. |
| (curl error: connection / NXDOMAIN) | DNS A record missing OR points at a proxied/private IP (e.g. `198.18.x.x` from WARP / Zscaler / Tailscale). | Re-derive `$EIP` from `aws ec2 describe-addresses` (NOT from `dig`) and re-UPSERT — see [`cloud-setup.md` §6.1](cloud-setup.md#61-dns-a-record). |
| `signer_disabled` (503) | `/etc/agentkeys/dev-key-service.env` didn't load. | `sudo systemctl show agentkeys-signer \| grep EnvironmentFile` — confirm file exists, mode 0600. |

### 0.3 Pick two demo identities and compute their `omni_account`

The broker derives `omni_account = SHA256("agentkeys" || identity_type
|| identity_value)`. The operator computes the same value locally so
they can drive the dev_key_service with it.

```bash
# === ON OPERATOR WORKSTATION ===
omni() {
  # Concatenates the broker's canonical inputs and hashes; matches
  # crates/agentkeys-broker-server/src/identity/omni_account.rs.
  local identity_type="$1" identity_value="$2"
  printf '%s%s%s' "agentkeys" "$identity_type" "$identity_value" \
    | shasum -a 256 \
    | awk '{print $1}'
}

OMNI_A=$(omni email "alice@demo.example")
echo "OMNI_A=$OMNI_A  length=${#OMNI_A}"
OMNI_B=$(omni email "bob@demo.example")
echo "OMNI_B=$OMNI_B  length=${#OMNI_B}"

# These should NEVER collide — different identity_value → different omni.
[[ "$OMNI_A" != "$OMNI_B" ]] && echo "omni split ok" || echo "OMNI COLLISION — bug?"
```

> **Why `email` as the identity_type for a demo with no real email?**
> The choice is just a namespace label that the broker hashes into
> `omni_account`. Using `email` keeps the demo identities distinct
> from raw EVM identities (which the broker stamps post-SIWE-verify
> as `("evm", lower(wallet))`). For a fully cleaned-up demo you can
> use any nonempty `(type, value)` pair; the only invariant is that
> A and B differ.

### 0.4 Derive the managed wallets

The dev_key_service derives a deterministic EVM wallet for each omni.
The CLI attaches the saved session JWT as a bearer token, so
**`agentkeys init` must run first** — otherwise every `signer derive` /
`signer sign` call below returns `Error: SIGNER_UNAUTHORIZED  invalid
session JWT: InvalidToken`. See [§2.0](#20-recommended-path-agentkeys-init---email)
for the full init flow + OAuth2 alternative; the minimum to get §0.4
working is one `--email` round-trip.

> **Two-step prereq if you've never run `--email` against this broker
> before** (per [issue #80](https://github.com/litentry/agentKeys/issues/80) —
> closed by Pass 2 of Option B):
>
> 1. **One-time SES sender registration** (operator workstation, ~30s):
>    ```bash
>    awsp agentkeys-admin     # MUST be admin profile — broker user lacks s3:ListBucket
>    set -a; source scripts/operator-workstation.env; set +a
>    bash scripts/ses-verify-sender.sh
>    ```
>    Registers `noreply-test@bots.litentry.org` as a per-address SES
>    identity, polls `s3://$MAIL_BUCKET/inbound/` for the verification
>    mail, clicks the link, confirms `VerifiedForSendingStatus=true`. Idempotent.
>
>    The script now fails loud with `awsp agentkeys-admin` guidance if
>    you forgot the profile switch (previously it silently reported
>    "0 object(s) under inbound/" while the broker user's `AccessDenied`
>    on `s3:ListBucket` was masked by `2>/dev/null`).
>
> 2. **Broker host re-deploy with `auth-email-link` feature** (broker
>    host, ~1 min):
>    ```bash
>    ssh agentkey@$BROKER_HOST
>    cd ~/agentKeys && git pull
>    # nuke stale release artifact so the rebuild can't reuse a binary
>    # compiled WITHOUT --features auth-email-link (cargo's incremental
>    # cache + a half-finished prior build can leave the wrong artifact
>    # in place; the script now polls /healthz post-restart and dies
>    # loud with the journal if boot crashes, but a clean target/ avoids
>    # the failure mode entirely):
>    rm -f target/release/agentkeys-broker-server
>    sudo bash scripts/setup-broker-host.sh --yes
>    ```
>    Pass 2 of Option B: the script now builds with `--features
>    auth-email-link` and sets `BROKER_AUTH_METHODS=wallet_sig,email_link`
>    + `BROKER_EMAIL_SENDER=ses` in the systemd unit. Without this, the
>    broker returns 404 on `/v1/auth/email/request` and
>    `agentkeys init --email` fails. (No HMAC key — magic-link is
>    stateful per [`architecture.md`](spec/architecture.md) §5a.1.M:
>    CSPRNG token → SHA256 in EmailTokenStore → single-use within TTL.)
>
>    **If `agentkeys init --email` returns `502 Bad Gateway` from
>    nginx**: the broker process crashed at boot — nginx is up but
>    `127.0.0.1:8091` is dead. The setup script's post-restart probe
>    will now `die` with the journal output if this happens during
>    re-deploy, but if you ran the broker some other way, diagnose with:
>    ```bash
>    ssh agentkey@$BROKER_HOST '
>      sudo journalctl -u agentkeys-broker -n 60 --no-pager | grep -E "BOOT_FAIL|ERROR" | tail -10
>    '
>    ```
>    The most common Pass-2 boot crash is `BROKER_AUTH_METHODS="email_link":
>    unknown or feature-gated-out auth method` — the binary was built
>    without `--features auth-email-link`. Fix: `rm -f
>    ~/agentKeys/target/release/agentkeys-broker-server` then re-run
>    `setup-broker-host.sh --yes`.

```bash
# === ON OPERATOR WORKSTATION ===
# Send a magic link via real SES, then click it from your inbox. The CLI
# polls the broker, derives the wallet via the signer, and saves the
# session JWT in the OS keychain.
agentkeys init \
  --email alice@demo.example \
  --broker-url $OIDC_ISSUER \
  --signer-url $BACKEND_URL
# Initialized via email-link.
#   identity omni: <64 hex>     ← matches OMNI_A from §0.3
#   derived wallet: 0x…         ← will match ADDR_A below
#   evm omni:      <64 hex>
```

```bash
# === ON OPERATOR WORKSTATION ===
# The CLI reads the saved session (from agentkeys init above) and
# attaches it as Authorization: Bearer <jwt> so the signer can verify
# the request.
ADDR_A=$(agentkeys --json signer derive \
           --signer-url $BACKEND_URL \
           --omni-account $OMNI_A | jq -r .address)
echo "ADDR_A=$ADDR_A"

ADDR_B=$(agentkeys --json signer derive \
           --signer-url $BACKEND_URL \
           --omni-account $OMNI_B | jq -r .address)
echo "ADDR_B=$ADDR_B"

[[ "$ADDR_A" != "$ADDR_B" ]] && echo "wallet split ok" || echo "WALLET COLLISION — bug?"
```

`ADDR_A` and `ADDR_B` are 0x-prefixed 40-char lowercase hex EVM
addresses. They're stable across daemon reinstalls as long as the
master secret doesn't rotate; that's the property that makes the
"recover-via-any-linked-identity" model work without ever moving a
private key.

The keys never need on-chain funds — Stage 7's SIWE auth is off-chain
signing only.

---

## 1. Verify the broker is up

```bash
# === ON OPERATOR WORKSTATION ===
# Show the HTTP status explicitly so a 404 (e.g. wrong path) doesn't
# print silently like `curl -sf … && echo` would.
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' $OIDC_ISSUER/healthz
# HTTP 200          ← anything else means the broker isn't fully up

curl -s -o /dev/null -w 'HTTP %{http_code}\n' $OIDC_ISSUER/readyz
# HTTP 200          ← every plug-in + Tier-2 check is Ready
# HTTP 503          ← at least one check is Unready (body lists which)

curl -s $OIDC_ISSUER/readyz | jq
# All-green case:
#   {
#     "status":   "ready",
#     "degraded": false,
#     "checks":   [],
#     "ready":    ["tier2/backend", "audit/sqlite", …]
#   }
```

The body is always self-describing — `status` is one of `ready`,
`degraded`, `unready` — so `curl … | jq -r .status` is a single-shot
verdict. If `/readyz` returns `503`, paste the `docs:` URL from the
checks array into the [operator runbook](operator-runbook-stage7.md).

```bash
curl -sS --fail-with-body $OIDC_ISSUER/.well-known/openid-configuration | jq
# {
#   "issuer": "https://broker.litentry.org",
#   "jwks_uri": "https://broker.litentry.org/.well-known/jwks.json",
#   "id_token_signing_alg_values_supported": ["ES256"],
#   ...
# }

curl -sS --fail-with-body $OIDC_ISSUER/.well-known/jwks.json | jq '.keys[0]'
```

**Critical invariant:** `issuer` in the discovery doc MUST equal
`$OIDC_ISSUER` byte-for-byte. AWS IAM compares the JWT `iss` claim
against the registered OIDC provider URL exactly. If they don't match,
every `AssumeRoleWithWebIdentity` will return `InvalidIdentityToken`.

```bash
[[ "$(curl -sS --fail-with-body $OIDC_ISSUER/.well-known/openid-configuration | jq -r .issuer)" \
   == "$OIDC_ISSUER" ]] && echo "issuer match" || echo "ISSUER MISMATCH — see runbook §oidc-issuer"
```

Verify from AWS IAM's perspective:

```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn $OIDC_PROVIDER_ARN \
  --query '{Url:Url, ClientIDList:ClientIDList, Thumbprints:ThumbprintList}'
```

---

## 2. Managed-wallet SIWE auth via the dev_key_service

This is the new flow that replaces the pre-issue-#74 `cast wallet
sign` walkthrough. The operator provides only an identity (email or
OAuth2/Google); the broker mints an identity-omni session JWT, the
backend derives the wallet, signs the SIWE challenge on the operator's
behalf, and the broker mints an EVM-omni session JWT. The broker sees
a normal SIWE round-trip — it cannot tell whether the signer is
HKDF-backed (today) or TEE-backed (issue #74 step 2).

### 2.0 Recommended path: `agentkeys init --email`

Issue #74 step 1 + Pass 2 of Option B (closed [issue #80](https://github.com/litentry/agentKeys/issues/80))
ship a single-command bootstrap that drives the entire chain end-to-end
against real SES delivery. Use this for any real demo or production deployment.

> **Prereq if you haven't done it yet:** the two-step setup from §0.4 —
> `bash scripts/ses-verify-sender.sh` (one-time SES sender registration) +
> `sudo bash scripts/setup-broker-host.sh --yes` on the broker host
> (Pass 2 build with `auth-email-link` + `email_link` in
> `BROKER_AUTH_METHODS`).

```bash
# === ON OPERATOR WORKSTATION ===
agentkeys init \
  --email alice@demo.example \
  --broker-url $OIDC_ISSUER \
  --signer-url $BACKEND_URL
# Magic link sent to alice@demo.example via real SES (FROM noreply-test@bots.litentry.org).
# Click the link in your inbox; the CLI is polling…
# (operator clicks the magic link)
# Initialized via email-link.
#   identity omni: <64 hex>
#   derived wallet: 0x…
#   evm omni:      <64 hex>
```

For OAuth2/Google instead of email-link:

```bash
agentkeys init \
  --oauth2-google \
  --broker-url $OIDC_ISSUER \
  --signer-url $BACKEND_URL
# Open this URL in your browser to authenticate with Google:
#   https://accounts.google.com/o/oauth2/v2/auth?…
# (Polling for callback…)
```

The same flow is available on the daemon side via
`agentkeys-daemon --init-email <addr>` and
`agentkeys-daemon --init-oauth2-google` (see §16.7 for an end-to-end
provision against a real broker).

`§2.1`–`§2.5` below walk through the same chain manually, so you can
inspect each wire frame without trusting the CLI to do the right
thing. Use those sections for debugging or for explaining the trust
model to a reviewer.

### 2.1 Request a SIWE challenge for `ADDR_A`

```bash
# === ON OPERATOR WORKSTATION ===
START=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/auth/wallet/start \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg a "$ADDR_A" '{address:$a, chain_id:84532}')")
echo "START=${START:0:32}…  length=${#START}"

printf '%s' "$START" | jq
# {
#   "request_id": "siwe-<ulid>",
#   "siwe_message": "broker.litentry.org wants you to sign in…",
#   "nonce": "<32 hex>",
#   "expires_in_seconds": 2700,
#   "expires_at_iso": "2026-05-08T15:22:11Z"
# }

REQ_ID=$(printf '%s' "$START" | jq -r .request_id)
echo "REQ_ID=$REQ_ID"
SIWE_MSG=$(printf '%s' "$START" | jq -r .siwe_message)
echo "SIWE_MSG=${SIWE_MSG:0:32}…  length=${#SIWE_MSG}"
```

The SIWE message is constructed per EIP-4361 with the broker's
`$BROKER_HOST` as the domain field. The signature you produce next has
the EIP-191 `\x19Ethereum Signed Message:\n<len>` prefix wrapped around
this exact text — re-deriving any whitespace differently breaks
verification, so always pull `SIWE_MSG` straight from the response.

### 2.2 Sign the SIWE message via the dev_key_service

`agentkeys signer sign` calls `POST /dev/sign-message` with `OMNI_A`
and the SIWE message bytes. The signer wraps them in EIP-191 and
returns the canonical 65-byte signature. The CLI never sees the
private key.

```bash
SIG_A=$(agentkeys --json signer sign \
          --signer-url $BACKEND_URL \
          --omni-account $OMNI_A \
          --message "$SIWE_MSG" | jq -r .signature)
echo "SIG_A=${SIG_A:0:32}…  length=${#SIG_A}"
# SIG_A=0x<130 hex chars>
```

Sanity — the signer's `address` reply MUST match `ADDR_A`:

```bash
SIG_ADDR=$(agentkeys --json signer sign \
             --signer-url $BACKEND_URL \
             --omni-account $OMNI_A \
             --message "$SIWE_MSG" | jq -r .address)
[[ "$SIG_ADDR" == "$ADDR_A" ]] && echo "sign↔derive address match" \
                              || echo "ADDRESS DRIFT — master secret rotated mid-session?"
```

### 2.3 Submit the signature, get back a session JWT

```bash
VERIFY=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/auth/wallet/verify \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg r "$REQ_ID" --arg s "$SIG_A" \
        '{request_id:$r, signature:$s}')")
echo "VERIFY=${VERIFY:0:32}…  length=${#VERIFY}"

printf '%s' "$VERIFY" | jq
# {
#   "session_jwt": "eyJ…",
#   "session_jwt_kid": "ak-session-<unix>",
#   "expires_at": 1762345678,
#   "omni_account": "<64 hex>",
#   "wallet_address": "0x…",
#   "identity_type": "evm",
#   "identity_value": "0x…"
# }

SESSION_JWT_A=$(printf '%s' "$VERIFY" | jq -r .session_jwt)
echo "SESSION_JWT_A=${SESSION_JWT_A:0:32}…  length=${#SESSION_JWT_A}"
OMNI_EVM_A=$(printf '%s' "$VERIFY" | jq -r .omni_account)
echo "OMNI_EVM_A=$OMNI_EVM_A"
echo "OMNI_A    =$OMNI_A   (the omni you used to drive the signer)"
```

> **Two omnis at play — both correct.**
> - `$OMNI_A` is the operator's **identity omni** (the one you used to
>   call the signer). The broker never sees this directly.
> - `$OMNI_EVM_A` is the **wallet omni** the broker derives from the
>   verified EVM address. The session JWT is bound to this one.
>
> They link 1:1 in this demo because the wallet is deterministically
> derived from `OMNI_A`. In production, `agentkeys whoami` would
> show both via the linked-identities table after the daemon calls
> `/v1/wallet/link(OMNI_A → ADDR_A)`. See §7.1 below.

> **Session JWT is broker-internal.** It is signed by the *session*
> keypair (`purpose=session`), not the OIDC keypair. AWS IAM never
> sees it. Plan §3.5.6 keeps the two keypairs separate so a stolen
> session JWT can't impersonate the broker to AWS, and a stolen OIDC
> JWT can't be replayed as a session token.

### 2.4 Repeat for `ADDR_B`

```bash
START_B=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/auth/wallet/start \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg a "$ADDR_B" '{address:$a, chain_id:84532}')")
REQ_ID_B=$(printf '%s' "$START_B" | jq -r .request_id)
SIWE_MSG_B=$(printf '%s' "$START_B" | jq -r .siwe_message)

SIG_B=$(agentkeys --json signer sign \
          --signer-url $BACKEND_URL \
          --omni-account $OMNI_B \
          --message "$SIWE_MSG_B" | jq -r .signature)
echo "SIG_B=${SIG_B:0:32}…  length=${#SIG_B}"

VERIFY_B=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/auth/wallet/verify \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg r "$REQ_ID_B" --arg s "$SIG_B" \
        '{request_id:$r, signature:$s}')")
SESSION_JWT_B=$(printf '%s' "$VERIFY_B" | jq -r .session_jwt)
OMNI_EVM_B=$(printf '%s' "$VERIFY_B" | jq -r .omni_account)
echo "OMNI_EVM_A=$OMNI_EVM_A"
echo "OMNI_EVM_B=$OMNI_EVM_B"
```

`OMNI_EVM_A` ≠ `OMNI_EVM_B` — confirmed by hash function.

### 2.5 `agentkeys whoami` — sanity at-a-glance

```bash
agentkeys whoami \
  --signer-url $BACKEND_URL \
  --omni-account $OMNI_A
# session_wallet: 0x… (legacy session if any)
# signer_url: http://…
# omni_account: <OMNI_A>
# derived_address: <ADDR_A>
# key_version: 1
```

This is the read-only operator-UX command that ships in this PR. It
calls `/dev/derive-address` and surfaces the omni → address mapping
without any side effects.

---

## 3. Mint OIDC JWT for STS

The session JWT is broker-internal. To talk to AWS STS you need a
separate OIDC JWT signed by the OIDC keypair, with claims AWS knows how
to consume.

```bash
JWT_A=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq -r .jwt)
echo "JWT_A=${JWT_A:0:32}…  length=${#JWT_A}"

# Decode and verify the claim shape AWS cares about:
echo "$JWT_A" | cut -d. -f2 \
  | tr '_-' '/+' \
  | { read p; printf '%s%s' "$p" "$(printf '====' | head -c $(( (4 - ${#p} % 4) % 4 )))" | base64 -d 2>/dev/null; } \
  | jq
# {
#   "iss": "https://broker.litentry.org",
#   "sub": "agentkeys:agent:0x…<wallet>",
#   "aud": "sts.amazonaws.com",
#   "exp": <unix>,
#   "iat": <unix>,
#   "agentkeys_user_wallet": "0x…",
#   "https://aws.amazon.com/tags": {
#     "principal_tags": {"agentkeys_user_wallet": ["0x…"]},
#     "transitive_tag_keys": ["agentkeys_user_wallet"]
#   }
# }
```

The `https://aws.amazon.com/tags` claim is what makes
`PrincipalTag`-scoped isolation work — AWS STS reads it during
`AssumeRoleWithWebIdentity` and stamps the assumed session with that
tag. The role's trust policy requires this tag to be present (set up
in `cloud-setup.md §4.3`).

JWT TTL is 5 min. If you wait too long, rerun this step.

---

## 4. Cloud-enforced isolation proof

This is the climax of the demo. We assume `agentkeys-data-role` with
`JWT_A`, then attempt to read both `ADDR_A`'s prefix (allowed) and
`ADDR_B`'s prefix (denied **by AWS, not by app code**).

### 4.1 Assume the role with JWT_A

```bash
# === ON OPERATOR WORKSTATION ===
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role \
  --role-session-name "demo-A-$(date +%s)" \
  --web-identity-token "$JWT_A")

printf '%s' "$CREDS" | jq '.Credentials | {AKID:.AccessKeyId, Exp:.Expiration}'

export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r .Credentials.SessionToken)

# Confirm: you are NOT your admin profile any more.
aws sts get-caller-identity
# {
#   "UserId": "AROA…<role-id>:demo-A-…",
#   "Arn": "arn:aws:sts::ACCOUNT:assumed-role/agentkeys-data-role/demo-A-…"
# }
```

### 4.2 Seed test objects (one-shot, with admin creds)

If `ADDR_A`'s prefix is empty, the read in step 4.3 succeeds vacuously
and proves nothing. Pop two objects in (one per derived wallet) using
your admin profile — clear out the assumed-role env first.

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
awsp agentkeys-admin

# Derived addresses are already lowercase from the dev_key_service.
aws s3api put-object --bucket "$BUCKET" \
  --key "bots/${ADDR_A}/hello.txt" --body /dev/null
aws s3api put-object --bucket "$BUCKET" \
  --key "bots/${ADDR_B}/hello.txt" --body /dev/null
```

### 4.3 Re-export the assumed-role creds and probe both prefixes

```bash
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r .Credentials.SessionToken)

# 4a — your own prefix: SUCCESS
aws s3api list-objects-v2 --bucket "$BUCKET" \
  --prefix "bots/${ADDR_A}/" --query 'Contents[*].Key'
# [ "bots/0x…<A>/hello.txt" ]

aws s3api get-object --bucket "$BUCKET" \
  --key "bots/${ADDR_A}/hello.txt" /tmp/got-A.txt
# { "ContentLength": 0, ... }

# 4b — the OTHER derived wallet's prefix: AccessDenied (CLOUD-ENFORCED)
aws s3api get-object --bucket "$BUCKET" \
  --key "bots/${ADDR_B}/hello.txt" /tmp/got-B.txt
# An error occurred (AccessDenied) when calling the GetObject operation:
# Access Denied
```

**Step 4b is the property the static-IAM path cannot prove.** No app
code participated in the deny — S3's policy engine evaluated
`${aws:PrincipalTag/agentkeys_user_wallet}` (which is `ADDR_A`)
against the resource ARN's `bots/${ADDR_B}/` and refused.

### 4.4 Diagnosing intermediate states

If step 4a denies (your *own* prefix), the JWT isn't carrying the
`https://aws.amazon.com/tags` claim. Decode and confirm:

```bash
echo "$JWT_A" | cut -d. -f2 | tr '_-' '/+' \
  | { read p; printf '%s%s' "$p" "$(printf '====' | head -c $(( (4 - ${#p} % 4) % 4 )))" | base64 -d 2>/dev/null; } \
  | jq '."https://aws.amazon.com/tags"'
# Should be a non-null object. If null, the broker minted a JWT
# without the tag claim — see runbook §oidc-issuer.
```

If step 4b succeeds (silent pass — the worst-case bug), `cloud-setup.md
§4.4.1` wasn't applied and the role's inline `s3:*` grant overrides the
bucket policy. Re-apply §4.4.1 and confirm the role's inline policy
contains only `ses:SendRawEmail`.

> The federation-isolation silent-pass bug fixed in PR #69 (commit
> [`c7b7f01`](https://github.com/litentry/agentKeys/commit/c7b7f01))
> is exactly this failure mode at the broker layer. The combined
> doc + code fix prevents it from regressing.

---

## 5. Mint AWS creds — two paths, post-issue-#71

After issue #71 Option A landed, the auto-provision pipeline mints AWS
creds **client-side** by combining `/v1/mint-oidc-jwt` (broker call) +
`AssumeRoleWithWebIdentity` (daemon-side STS call). The broker no longer
needs an IAM principal at runtime.

`/v1/mint-aws-creds` (server-side aggregator) **still works** for callers
who want server-side enforcement of audit + grants + idempotency — but
the production auto-provision path no longer hits it.

### 5.1 The new daemon-side flow (auto-provision uses this)

```bash
# === ON OPERATOR WORKSTATION === (or anywhere with the JWT)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# 1. Ask the broker for an OIDC JWT (lightweight call — broker just signs).
JWT=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq -r .jwt)

# 2. Exchange it for AWS creds CLIENT-SIDE. No broker creds participate.
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role \
  --role-session-name "demo-A-$(date +%s)" \
  --web-identity-token "$JWT")
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r .Credentials.SessionToken)

# 3. Use the temp creds. PrincipalTag-scoped per cloud-setup.md §4.4.
aws s3 ls "s3://$BUCKET/bots/${ADDR_A}/"
```

Inside `agentkeys-provisioner`, the `fetch_via_broker_default_ttl()`
helper does the same two-step internally and returns an `AwsTempCreds`
struct ready for env-var injection into the scraper subprocess.

### 5.2 The server-side aggregator (still available)

If you want the broker to be the policy point — mandatory audit log,
Phase B grant check, Idempotency-Key dedup, multi-anchor coordination —
hit `/v1/mint-aws-creds` instead. It does steps 1+2 above internally
plus the audit-anchor write, and returns the temp creds in the same
shape.

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/mint-aws-creds \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg w "$ADDR_A" '{
        request_id: "demo-1",
        issued_at: (now | floor | todate),
        intent:    {agent_id: $w, service: "s3", scope_path: "bots/"}
      }')" | jq
# {
#   "access_key_id": "ASIA…",  "secret_access_key": "…",  "session_token": "…",
#   "expiration": <unix+session_duration>,
#   "wallet": "0x…",
#   "audit_record_id": "aud_<ulid>",
#   "anchored": ["sqlite"]
# }
```

The two paths return functionally equivalent creds — both
`AssumeRoleWithWebIdentity`, both PrincipalTag-scoped. Pick based on
whether you want the broker or the caller to be the policy point.

### 5.3 Auto-provision pipeline against live broker.litentry.org

`agentkeys-daemon` / `agentkeys-mcp` invoke
`agentkeys-provisioner::fetch_via_broker_default_ttl` under the hood
when `AGENTKEYS_BROKER_URL` is set. End-to-end:

```bash
# === ON OPERATOR WORKSTATION ===
export AGENTKEYS_BROKER_URL=https://broker.litentry.org
export AGENTKEYS_DATA_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role
export AWS_REGION=us-east-1

# Daemon picks up the env vars; provisioner subprocess receives the AWS
# temp creds the daemon mints by hitting /v1/mint-oidc-jwt + STS.
agentkeys-daemon \
  --backend $BACKEND_URL \
  --broker-url $AGENTKEYS_BROKER_URL \
  --session $SESSION_JWT_A
```

Inside the daemon, the call site is
[`crates/agentkeys-mcp/src/lib.rs`](../crates/agentkeys-mcp/src/lib.rs)::`broker_env_for_provision`
→ `fetch_via_broker_default_ttl` → `/v1/mint-oidc-jwt` →
`AssumeRoleWithWebIdentity` → env-var-injection into the scraper.

---

## 6. Capability grants (Phase B)

A grant is an explicit, master-OmniAccount-issued authorization that
daemon address X can mint S3 creds for `(service, scope_path)` until
`expires_at`, up to `max_uses` times. It's the cloud's
fail-closed-by-default story.

### 6.1 Master creates a grant

```bash
GRANT=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/grant/create \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg d "$ADDR_A" '{
        daemon_address: $d,
        service:        "s3",
        scope_path:     "bots/",
        expires_at:     (now + 3600 | floor),
        max_uses:       100
      }')")

printf '%s' "$GRANT" | jq
# {
#   "grant_id": "grn-<ulid>",
#   "audit_proof": "eyJ…",          ← broker-signed JWT over canonical content
#   "expires_at": <unix+3600>,
#   ...
# }
```

The `audit_proof` is a JWT signed with the **session keypair** over the
canonical grant content (master, daemon, service, scope_path,
expires_at, max_uses, grant_id). DB exfiltration cannot produce a
verified-but-tampered grant — the proof's signature won't validate.

### 6.2 Master lists grants

```bash
curl -sS --fail-with-body $OIDC_ISSUER/v1/grant/list \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq '.grants[0]'
```

### 6.3 Master revokes a grant

```bash
GRANT_ID=$(printf '%s' "$GRANT" | jq -r .grant_id)
curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/grant/revoke \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg id "$GRANT_ID" '{grant_id:$id}')"
# {"revoked": true, "grant_id": "grn-…", "revoked_at": <unix>}
```

Re-revoke is a no-op (idempotent). Revoked grants instantly stop
authorizing mints.

### 6.4 Migration-window note

The mint endpoint currently allows mints WITHOUT an explicit grant for
backward-compat with Phase 0 daemons (legacy `NoGrant` path). The
audit log records these with an empty `grant_id`. Phase E US-039 flips
the default to fail-closed — set `BROKER_REQUIRE_EXPLICIT_GRANT=true`
on the broker host once every daemon has a grant.

---

## 7. Wallet linking + recovery (Phase B)

After issue #74 step 1 the canonical recovery model is "any linked
identity unlocks the same derived wallet." The daemon links its
identity-omni (e.g. `OMNI_A` from email) to the derived wallet so
re-authenticating as that email recovers the same EVM address.

### 7.1 Master links the identity-omni to the derived wallet

```bash
curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/wallet/link \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H 'content-type: application/json' \
  -d "$(jq -n '{identity_type:"email", identity_value:"alice@demo.example"}')"
```

After this call the broker's `IdentityLinkStore` knows that
`("email", "alice@demo.example")` ↔ `OMNI_EVM_A` ↔ `ADDR_A`.

### 7.2 List linked identities

```bash
curl -sS --fail-with-body $OIDC_ISSUER/v1/wallet/links \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq
```

### 7.3 Recover lookup (intentionally unauthenticated)

```bash
curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/wallet/recover/lookup \
  -H 'content-type: application/json' \
  -d '{"identity_type":"email","identity_value":"alice@demo.example"}' | jq
# {"omni_account": "<64 hex>"}
```

The lookup is unauthenticated *by design* — `omni_account` is a
SHA256 hash, discovery does not enable impersonation. Recovery still
requires the daemon to (a) re-authenticate as the linked identity,
(b) get the same `omni_account` back, and (c) ask the dev_key_service
to derive the wallet (the master secret has not rotated, so the
derivation is stable). See [operator-runbook-stage7.md → Recovery
flow](operator-runbook-stage7.md#recovery-flow).

---

## 8. Email-link auth (Phase A.1) — alternative entry point

Email-link is the canonical way to bootstrap `OMNI_A` in a real
deployment instead of computing it offline like §0.3 does. After
verification, the broker mints a session JWT bound to `omni_email`,
and the daemon then derives the wallet via `/dev/derive-address`.
Same dev_key_service flow from there on out.

Requires `BROKER_AUTH_METHODS=…,email_link` and `BROKER_EMAIL_*` env
vars set (see runbook). SES sender identity must be verified.

```bash
# 1. Request a magic link.
curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/auth/email/request \
  -H 'content-type: application/json' \
  -d '{"email":"alice@demo.example"}'
# {"request_id":"em_…","status":"sent"}

# 2. Click the link in the email. The broker's /auth/email/landing
#    page completes the verify; the CLI poll surfaces the session JWT.

# 3. Poll for the result.
curl -sS --fail-with-body $OIDC_ISSUER/v1/auth/email/status/em_… | jq
# {
#   "status": "verified",
#   "session_jwt": "eyJ…",
#   "omni_account": "<64 hex of OMNI_A>",
#   "identity_type": "email",
#   "identity_value": "alice@demo.example"
# }

# 4. The session JWT is now an `omni_email` session. Derive the wallet:
EMAIL_SESSION_JWT=...                # from step 3
agentkeys signer derive \
  --signer-url $BACKEND_URL \
  --omni-account $(omni email "alice@demo.example")
# 5. Then run §2.1 onwards using that derived address.
```

### 8.1 Debugging — inspecting the inbound email at S3

If the magic-link click never completes verification, the email
probably arrived but the link the broker rendered doesn't match the
URL pattern the auth handler regex-matches. Use
[`scripts/inspect-inbound-email.sh`](../scripts/inspect-inbound-email.sh)
to dump the most-recent inbound email from `s3://$BUCKET/inbound/`.

```bash
# === ON OPERATOR WORKSTATION ===
awsp agentkeys-admin
./scripts/inspect-inbound-email.sh                # latest
./scripts/inspect-inbound-email.sh --all          # list all keys + headers
./scripts/inspect-inbound-email.sh inbound/<key>  # specific key
```

The session JWT NEVER appears in the browser-facing landing-page
response — only on the CLI poll, per Plan §3.5.4 security posture.

---

## 9. OAuth2/Google auth (Phase A.2) — alternative entry point

Same shape as §8 but the bootstrap is a Google OAuth2 round-trip
instead of email. Once the omni_oauth2 session JWT lands, the daemon
derives the same EVM wallet via the dev_key_service.

Requires `BROKER_OAUTH2_*` env vars, a Google Cloud Console OAuth web
client, and the broker's redirect URI registered exactly. See
[operator-runbook-stage7.md → OAuth2 Setup](operator-runbook-stage7.md#oauth2-setup).

```bash
# 1. Initiate.
curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/auth/oauth2/start \
  -H 'content-type: application/json' \
  -d '{"provider":"google"}' | jq

# 2. Open authorization_url in a browser, sign in. Google redirects
#    to /auth/oauth2/callback on the broker.

# 3. Poll.
curl -sS --fail-with-body $OIDC_ISSUER/v1/auth/oauth2/status/oa2-… | jq
# {"status":"verified", "session_jwt":"eyJ…", "omni_account":"…",
#  "identity_type":"oauth2_google", "identity_value":"<google-sub>"}

# 4. Derive the wallet:
agentkeys signer derive \
  --signer-url $BACKEND_URL \
  --omni-account $(omni oauth2_google "<google-sub>")
```

`prompt=select_account` is hardcoded into the auth URL so Google
always forces the account chooser — defends against the
silent-wrong-account scenario (multi-account browsers).

---

## 10. Audit log inspection

```bash
# === ON BROKER HOST ===
ssh agentkey@$BROKER_HOST
sudo sqlite3 /var/lib/agentkeys/.agentkeys/broker/audit.sqlite \
  'SELECT id, omni_account, wallet, agent_id, service, status, outcome,
          grant_id, anchor_status, minted_at
     FROM plugin_mint_log ORDER BY minted_at DESC LIMIT 5;' \
  -header -column
```

Columns of interest:
- `omni_account` — `OMNI_EVM_A` for derived-wallet mints (post issue
  #74 the wallet is the public side; the identity omni stays on the
  daemon).
- `status` — `confirmed` after `sqlite_primary` or `sqlite`-only
  policy completes; `pending` → `confirmed | quarantined` for
  `dual_strict` policy (Phase C).
- `outcome` — `success` for granted mints; `denied` for grant
  failures (still audited).
- `grant_id` — non-empty when the mint was authorized by an explicit
  grant; empty during the Phase-0→B migration window.

The dev_key_service itself has **no audit log** in v0 — it is
single-process, every `/dev/sign-message` call is the daemon's own.
Issue #74 step 2 (TEE worker) adds enclave-side per-omni signing
counters.

---

## 11. EVM audit anchor (Phase C — structural only in v0)

The current build registers `EvmStubAnchor` for `evm_testnet`. The stub
round-trips without network — the three-state lifecycle (`pending` →
`confirmed | quarantined`), circuit breaker, gas-drain mitigations are
all wired structurally. **The live alloy-driven anchor (real
transaction submission, receipt polling) lands as a Phase E hardening
pass.**

To exercise the structural layer:

```bash
# === ON BROKER HOST ===
sudo systemctl edit agentkeys-broker
# [Service]
# Environment=BROKER_AUDIT_ANCHORS=sqlite,evm_testnet
# Environment=BROKER_AUDIT_POLICY=dual_strict
# Environment=BROKER_EVM_RPC_URL=https://sepolia.base.org
# Environment=BROKER_EVM_CHAIN_ID=84532
# Environment=BROKER_EVM_CONTRACT_ADDRESS=0x…
# Environment=BROKER_EVM_FEE_PAYER_KEYSTORE=/etc/agentkeys/fee-payer.keystore.json
# Environment=BROKER_EVM_FEE_PAYER_PASSWORD_FILE=/etc/agentkeys/fee-payer.pw

sudo systemctl restart agentkeys-broker
curl -sS --fail-with-body https://broker.litentry.org/readyz | jq
# .checks[] for evm_testnet appears; status=Ready or Unready depending
# on whether the stub's ChainId probe succeeded.
```

The harness invariants in `harness/stage-7-issue-64-phaseC-smoke.sh`
exercise this end-to-end against the stub.

---

## 12. Metrics + idempotency (Phase D-rest)

### 12.1 Prometheus metrics

```bash
# === ON BROKER HOST ===
sudo systemctl edit agentkeys-broker
# Environment=BROKER_METRICS_ENABLED=true
sudo systemctl restart agentkeys-broker

curl -sS --fail-with-body https://broker.litentry.org/metrics | head -30
# # HELP agentkeys_broker_mints_total …
# # TYPE agentkeys_broker_mints_total counter
# agentkeys_broker_mints_total 14
# agentkeys_broker_mints_failed_total 0
# agentkeys_broker_audit_writes_total 14
# agentkeys_broker_auth_attempts_total 23
# agentkeys_broker_idempotency_hits_total 3
# …
```

When `BROKER_METRICS_ENABLED` is unset or `false`, `/metrics` returns
404 — operators not running a Prometheus scraper should leave it
disabled to avoid leaking counter shapes to unauthenticated probers.

### 12.2 Idempotency-Key

```bash
KEY=$(uuidgen | tr '[:upper:]' '[:lower:]')

# First call — mints + caches.
curl -i -X POST $OIDC_ISSUER/v1/mint-aws-creds \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H "Idempotency-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{...}'      # full mint body
# HTTP/2 200
# x-idempotency: miss

# Same key + same body within 5 min — returns cached response.
curl -i -X POST $OIDC_ISSUER/v1/mint-aws-creds \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H "Idempotency-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{...}'
# HTTP/2 200
# x-idempotency: hit          ← no re-mint, no STS quota burn

# Same key + DIFFERENT body — 422.
curl -i -X POST $OIDC_ISSUER/v1/mint-aws-creds \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H "Idempotency-Key: $KEY" \
  -H 'content-type: application/json' \
  -d '{...different...}'
# HTTP/2 422
```

`BROKER_REQUEST_BODY_LIMIT_BYTES` (default 1 MiB) caps body size at
the router level.

---

## 13. Run the harness gate

The same script CI runs to gate the entire Stage-7 deliverable:

```bash
# === IN THE WORKTREE (operator workstation OR broker host with the repo) ===
bash harness/stage-7-issue-64-done.sh
```

This composes every per-phase smoke + the load-bearing invariant test
+ the env-var-table drift check + both build matrices (v0-default and
v0-testnet feature combos). Exits 0 if Stage 7 is shippable.

Issue #74's signer-protocol conformance test runs as part of the
default `cargo test` path:

```bash
cargo test -p agentkeys-mock-server --test dev_key_service_routes
cargo test -p agentkeys-core        --test signer_conformance
```

The conformance test exercises both the HKDF-backed dev_key_service
and an in-memory TEE-stub that implements the same wire shape — the
swap-point invariant is now a tested CI gate.

---

## 14. Failure-mode walk-through

### 14.1 BOOT_FAIL on first start

Tier-1 refuse-to-boot prints a single-line `BOOT_FAIL: <var>=<value>:
<reason>; see runbook §<anchor>` to stderr. Common ones:

| Anchor | Cause | Fix |
|---|---|---|
| `oidc-issuer` | `BROKER_OIDC_ISSUER` is `http://` and `BROKER_DEV_MODE` is unset | Set TLS in front of the broker, point issuer at the public HTTPS URL. |
| `oidc-keypair` / `session-keypair` | Keypair file missing | `agentkeys-broker-server keygen --purpose <oidc\|session> --out PATH`; or rerun `setup-broker-host.sh --upgrade` which auto-mints. |
| `audit-policy` | Bad `BROKER_AUDIT_POLICY` value | Must be `dual_strict` / `sqlite_primary` / `evm_primary`. |
| `auth-method-not-compiled` | Plugin name in env var not registered | Rebuild with the matching `--features` flag. |
| `auth-method-empty` / `audit-anchor-empty` | Empty list | Defaults: `wallet_sig` / `sqlite`. |
| `backend-reachability` | Tier-2 backend `/healthz` not yet probed | Auto-clears once mock-server is up. |

### 14.2 `/dev/derive-address` returns HTTP 503 `signer_disabled`

The backend's `DEV_KEY_SERVICE_MASTER_SECRET` env var is unset or
empty. From the broker host:

```bash
sudo systemctl show agentkeys-backend | grep DEV_KEY_SERVICE
# Should print: Environment=DEV_KEY_SERVICE_MASTER_SECRET=…
# If blank, redo §0.1 of this guide.
```

### 14.3 `agentkeys signer sign` returns `Error: SIGNER_UNREACHABLE`

The CLI cannot reach `--signer-url`. Verify, in order:

1. `curl -sS https://signer.<zone>/healthz` returns `ok` from the
   workstation. If TLS errors, the cert hasn't been issued yet —
   run `sudo certbot --nginx -d signer.<zone>` on the broker host
   (per §0.2).
2. `sudo systemctl status agentkeys-signer` on the broker host
   shows `active (running)`. If `failed`, check
   `journalctl -u agentkeys-signer -n 50` — most likely
   `/var/lib/agentkeys/.agentkeys/broker/session-keypair.pub.pem`
   is missing (the broker writes it on boot via
   `--export-session-pubkey-to`; restart `agentkeys-broker` then
   `agentkeys-signer`).
3. The DNS A record for `signer.<zone>` resolves to the broker host
   IP — `dig +short signer.<zone>` should return the EC2 EIP.

### 14.4 SIWE verify returns `signature does not recover to claimed address`

Possible causes:
- The SIWE message bytes were mutated between `/v1/auth/wallet/start`
  and `/dev/sign-message`. Always pass `$SIWE_MSG` straight from
  `printf '%s' "$START" | jq -r .siwe_message` — never re-render or
  re-quote.
- The `omni_account` you signed with is NOT the one that derived
  `$ADDR_A`. Re-derive: `agentkeys signer derive --omni-account
  $OMNI_A` and confirm the address matches what you sent to
  `/v1/auth/wallet/start`.
- `DEV_KEY_SERVICE_MASTER_SECRET` rotated mid-flow. Re-derive
  everything; previously-issued addresses are invalidated.

### 14.5 `AssumeRoleWithWebIdentity` returns InvalidIdentityToken

- **Issuer mismatch.** Confirm `discovery.issuer == $OIDC_ISSUER`
  byte-for-byte.
- **JWKS unreachable.** Confirm AWS can fetch
  `${OIDC_ISSUER}/.well-known/jwks.json` over the public internet.
- **Audience mismatch.** AWS expects `aud=sts.amazonaws.com`. Decode
  the JWT and confirm.
- **Stale OIDC provider.** If the broker's `kid` rotated and AWS
  cached the old JWKS, re-register the provider per
  `cloud-setup.md §4.2`.

### 14.6 S3 GetObject returns AccessDenied for own prefix

The JWT isn't carrying the `https://aws.amazon.com/tags` claim. Decode
and check (per §4.4 above). If the claim is present, confirm the role's
trust policy has `sts:TagSession` and the `aws:RequestTag/...`
condition (per `cloud-setup.md §4.3`).

### 14.7 Broker exits 0 cleanly after ~24h

Designed behavior — the broker has a 24h max-uptime serve loop. The
systemd unit ships with `Restart=always` (commit
[`c21c255`](https://github.com/litentry/agentKeys/commit/c21c255)) so
systemd restarts it automatically. Verify with
`sudo journalctl -u agentkeys-broker --since "1 day ago" | grep -E "max-uptime|listening"`.

---

## 15. What's intentionally not yet live

These ship behind their own user-stories or hardening passes; the
structural plumbing is in place but the live integration isn't wired:

- **TEE-backed signer (issue #74 step 2).** Today's
  `dev_key_service` keeps the master secret in a plain env var — fine
  for dev / demo / single-operator deployments, **not** for any
  environment where compromise of the host shell would be a security
  incident. Step 2 swaps it for a TEE worker behind the same wire
  shape. Daemon and CLI code do not change. See
  [`docs/spec/signer-protocol.md`](spec/signer-protocol.md) for the
  attestation handshake the TEE backend will add (`GET /dev/attestation`).
- **Live EVM audit anchor.** The `EvmStubAnchor` round-trips without
  network. Real transaction submission + receipt polling lands in
  Phase E hardening (V0.1-FOLLOWUPS).
- **TEE-derived OIDC signer.** The on-disk ES256 keypair is the v0.1
  signer for the broker's OIDC keypair (separate from the
  dev_key_service master secret). Plan §8 (TEE) replaces it without
  changing JWKS/JWT/STS shape.
- **`BROKER_REQUIRE_EXPLICIT_GRANT=true` default-on.** Today the
  Phase-0 NoGrant migration window is open; flip the default once
  every daemon has been issued a grant.
- **Histogram metrics + per-handler counter bumps.** Counter shapes
  ship; latency histograms land in V0.1-FOLLOWUPS.
- **Retire `/v1/mint-aws-creds` entirely.** The provisioner / MCP /
  daemon use `/v1/mint-oidc-jwt` + client-side
  `AssumeRoleWithWebIdentity` (issue #71 Option A). The route stays
  for callers who want server-side gates; once every operator's
  pipeline confirms the new path works in production, the route can
  be dropped.
- **Retire `/v1/auth/exchange` and backend `/session/validate`.**
  Issue #74 step 1's CLI/daemon rewrite (this PR) removed every
  in-tree caller of the legacy `/session/create` → bearer →
  `/v1/auth/exchange` chain — production code now goes through
  email/OAuth2 → omni → derive → SIWE → session-JWT. The shim itself
  still exists for backward-compat with any out-of-tree caller; a
  cleanup PR will delete the route, the validator
  (`broker-server/src/auth.rs::validate_bearer_token`), and the env
  vars (`BROKER_BACKEND_URL`, `BROKER_BACKEND_TIMEOUT_SECONDS`) once
  external callers have migrated.

See [`docs/spec/plans/issue-64/V0.1-FOLLOWUPS.md`](spec/plans/issue-64/V0.1-FOLLOWUPS.md)
for the prioritized backlog and
[`docs/spec/plans/issue-74-dev-key-service-plan.md`](spec/plans/issue-74-dev-key-service-plan.md)
for the post-issue-#74 roadmap.

---

## 16. Live walkthrough on broker.litentry.org

Copy-paste runbook for verifying the migration end-to-end against the
**live** broker at `https://broker.litentry.org`. Each block is
tagged with where it runs.

### 16.1 Pull + redeploy on the broker host

```bash
# === ON BROKER HOST (ip-172-31-29-135 via SSH) ===
ssh agentkey@broker.litentry.org
cd ~/agentKeys
git fetch origin
git checkout evm
git pull --ff-only

# Idempotent re-deploy. Same script handles bootstrap and upgrade —
# no `--upgrade` flag needed. Issue #74 step 1 made the script
# auto-generate /etc/agentkeys/dev-key-service.env on first run and
# preserve it on subsequent runs (rotating it would invalidate every
# previously-derived wallet).
sudo bash scripts/setup-broker-host.sh --yes

# Verify the broker + backend are up.
sudo systemctl --no-pager status agentkeys-broker agentkeys-backend
sudo journalctl -u agentkeys-broker  -n 50 --no-pager
sudo journalctl -u agentkeys-backend -n 10 --no-pager
# Look for: [mock-server] dev_key_service ENABLED (DEV ONLY — replace with TEE worker per issue #74 step 2)
```

### 16.2 Verify broker is creds-free

```bash
# === ON BROKER HOST ===
sudo systemctl show agentkeys-broker | grep -E "^Environment=" | tr ' ' '\n' \
  | grep -E "AWS_|DAEMON_|BROKER_DAEMON_" || echo "OK: no AWS_* / DAEMON_* env vars"
```

The expected output is `OK: no AWS_* / DAEMON_* env vars`.

### 16.3 Public health checks (no creds needed)

```bash
# === ON OPERATOR WORKSTATION ===
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' https://broker.litentry.org/healthz
# HTTP 200

curl -sS https://broker.litentry.org/readyz | jq -r .status
# ready

curl -sS --fail-with-body https://broker.litentry.org/.well-known/openid-configuration | jq -r .issuer
# https://broker.litentry.org

curl -sS --fail-with-body https://broker.litentry.org/.well-known/jwks.json | jq '.keys[0] | {kty, crv, alg, kid}'
# {"kty":"EC","crv":"P-256","alg":"ES256","kid":"v1-…"}
```

### 16.4 Managed-wallet SIWE auth via the dev_key_service

Point the workstation at the public signer hostname (§0.2):

```bash
# === ON OPERATOR WORKSTATION ===
export AGENTKEYS_SIGNER_URL=https://signer.litentry.org
export BACKEND_URL=$AGENTKEYS_SIGNER_URL
curl -sS $BACKEND_URL/healthz   # → ok
```

Compute omnis + derive wallets + run SIWE round-trip — exactly §0.3
through §2.4 above, just with `$OIDC_ISSUER=https://broker.litentry.org`
and `$BACKEND_URL=https://signer.litentry.org`. No tunnel; the signer
listener is fronted by nginx with TLS (issued via certbot per §0.2).

```bash
omni() { printf '%s%s%s' "agentkeys" "$1" "$2" | shasum -a 256 | awk '{print $1}'; }
OMNI_A=$(omni email "alice@demo.example")
OMNI_B=$(omni email "bob@demo.example")

ADDR_A=$(agentkeys --json signer derive --signer-url $BACKEND_URL --omni-account $OMNI_A | jq -r .address)
ADDR_B=$(agentkeys --json signer derive --signer-url $BACKEND_URL --omni-account $OMNI_B | jq -r .address)

# SIWE round-trip for A.
START=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/auth/wallet/start \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg a "$ADDR_A" '{address:$a, chain_id:84532}')")
REQ_ID=$(printf '%s' "$START"  | jq -r .request_id)
SIWE_MSG=$(printf '%s' "$START" | jq -r .siwe_message)
SIG_A=$(agentkeys --json signer sign --signer-url $BACKEND_URL --omni-account $OMNI_A --message "$SIWE_MSG" | jq -r .signature)
VERIFY=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/auth/wallet/verify \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg r "$REQ_ID" --arg s "$SIG_A" '{request_id:$r, signature:$s}')")
SESSION_JWT_A=$(printf '%s' "$VERIFY" | jq -r .session_jwt)
echo "SESSION_JWT_A=${SESSION_JWT_A:0:32}…"
```

Repeat for B. Or, for the demo's purposes, only A is needed for the
mint paths in §16.5, and the seed objects + isolation proof in §16.6
exercise both prefixes.

### 16.5 Mint OIDC JWT + AssumeRoleWithWebIdentity (the new auto-provision path)

```bash
# === ON OPERATOR WORKSTATION ===
awsp agentkeys-admin

JWT=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq -r .jwt)
echo "JWT prefix: ${JWT:0:40}…"

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "$DATA_ROLE_ARN" \
  --role-session-name "live-demo-$(date +%s)" \
  --web-identity-token "$JWT")
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r .Credentials.SessionToken)

aws sts get-caller-identity
# {
#   "UserId": "AROA…<role-id>:live-demo-…",
#   "Arn": "arn:aws:sts::ACCOUNT:assumed-role/agentkeys-data-role/live-demo-…"
# }
```

### 16.6 S3 cloud-enforced isolation proof

```bash
# === ON OPERATOR WORKSTATION (still with assumed-role creds) ===

# Wallet A's prefix — SUCCESS.
aws s3api list-objects-v2 --bucket "$BUCKET" \
  --prefix "bots/${ADDR_A}/" --query 'Contents[*].Key'

# Wallet B's prefix — AccessDenied (cloud-enforced).
aws s3api get-object --bucket "$BUCKET" \
  --key "bots/${ADDR_B}/hello.txt" /tmp/got-B.txt
# An error occurred (AccessDenied) when calling the GetObject operation
```

### 16.7 Auto-provision pipeline against live broker

```bash
# === ON OPERATOR WORKSTATION ===
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

export AGENTKEYS_BROKER_URL=https://broker.litentry.org
export AGENTKEYS_DATA_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role
export AGENTKEYS_SIGNER_URL=$BACKEND_URL          # public signer URL from §0.2
export AWS_REGION=us-east-1

# Bootstrap the master session via the new flow. The CLI prompts you
# to click the magic link; once verified, it derives + links + SIWEs
# and saves the EVM session JWT to the OS keychain.
agentkeys init \
  --email alice@demo.example \
  --broker-url $AGENTKEYS_BROKER_URL \
  --signer-url $AGENTKEYS_SIGNER_URL

# Now run the provisioner. AWS temp creds get minted via
# /v1/mint-oidc-jwt + AssumeRoleWithWebIdentity using the saved
# EVM session JWT.
agentkeys provision openrouter
# … scraper runs, fetches the verification email from S3 using the
# injected temp creds …
```

For a long-lived headless daemon (e.g. on a server), use
`agentkeys-daemon --init-email <addr>` instead — same flow, but the
daemon stays running afterward to serve MCP via stdio:

```bash
agentkeys-daemon \
  --backend $BACKEND_URL \
  --broker-url $AGENTKEYS_BROKER_URL \
  --signer-url $AGENTKEYS_SIGNER_URL \
  --init-email alice@demo.example \
  --stdio
# agentkeys-daemon: bootstrapping via email-link for alice@demo.example; click the magic link in your inbox
# (operator clicks the magic link in their inbox)
# (daemon then enters MCP-stdio loop)
```

### 16.8 Audit log inspection

```bash
# === ON BROKER HOST ===
sudo sqlite3 /var/lib/agentkeys/.agentkeys/broker/audit.sqlite \
  'SELECT id, requested_role, sts_session_name, outcome, COUNT(*)
     FROM mint_log
     WHERE minted_at > unixepoch() - 3600
     GROUP BY requested_role, outcome
     ORDER BY id DESC;' \
  -header -column
```

After the OIDC-only migration, the daemon-side path is invisible to
the broker's audit log (the broker only sees `/v1/mint-oidc-jwt`
calls). Use AWS CloudTrail's `AssumeRoleWithWebIdentity` events for
the STS-side audit trail. If you need server-side audit row coverage
of the actual mint, hit `/v1/mint-aws-creds` instead — it audits before
returning creds.

---

## 17. Cleanup

Reset to your admin profile after the demo:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
awsp agentkeys-admin
aws sts get-caller-identity        # confirm: back to admin
```

(No tunnel to tear down post-step-1b — the signer is reached via
its public hostname, not via SSH.)

The broker keeps running. To tear down the cloud-side state
(provider, role, bucket policy), follow `cloud-setup.md §7`.

> **Do NOT casually rotate `DEV_KEY_SERVICE_MASTER_SECRET`** —
> rotating invalidates every previously-derived wallet for every
> linked identity. The TEE worker (issue #74 step 2) will define a
> formal rotation runbook with key-version bumps; the dev backend
> intentionally has none.

---

## Cross-references

- [`docs/spec/signer-protocol.md`](spec/signer-protocol.md) — v0
  wire contract for the signer edge (`/dev/derive-address`,
  `/dev/sign-message`, error envelope, future attestation handshake).
- [`docs/spec/plans/issue-74-dev-key-service-plan.md`](spec/plans/issue-74-dev-key-service-plan.md)
  — the canonical issue #74 plan.
- [`docs/operator-runbook-stage7.md`](operator-runbook-stage7.md) —
  authoritative env-var inventory, BOOT_FAIL anchors, recovery
  procedures, OAuth2/email setup details.
- [`docs/cloud-setup.md`](cloud-setup.md) — AWS-side IAM, OIDC
  provider, bucket policy, EC2 broker host wiring.
- [`docs/spec/plans/issue-64/PLAN.md`](spec/plans/issue-64/PLAN.md) —
  the canonical Stage 7 plan (§6 Refuse-to-boot tiers; §3.5 plugin
  trait surface; §3.5.4 OAuth2 security posture; §3.5.6 dual-keypair
  rationale).
- [`harness/stage-7-issue-64-done.sh`](../harness/stage-7-issue-64-done.sh)
  — programmatic equivalent of §13 above (the gate CI runs).
