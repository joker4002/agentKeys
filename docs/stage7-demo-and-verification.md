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
   per [`architecture.md` §4](arch.md)).
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
> [`docs/arch.md`](arch.md) §4 (HDKD
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
| **Operator workstation (master role)** | `awsp agentkeys-admin` profile, `$ACCOUNT_ID` / `$BROKER_HOST` / `$BUCKET` shell vars from `cloud-setup.md §0`, `agentkeys` CLI, `aws` CLI, `jq` | AWS-side checks, `aws sts assume-role-with-web-identity`, S3 isolation proof, calling the broker + signer over HTTPS. The operator running these commands IS the master per [`architecture.md` §4a](arch.md). |
| **Broker host (EC2)** | `agentkeys-broker-server` and `agentkeys-mock-server` binaries at `/usr/local/bin/`, both ES256 keypairs at `/var/lib/agentkeys/.agentkeys/broker/`, systemd services `agentkeys-broker.service` + `agentkeys-backend.service` + `agentkeys-signer.service`, nginx fronting broker on `:8091` at `https://$BROKER_HOST` and signer on `:8092` at `https://signer.<zone>` | Broker process, audit DB, JWT minting, **dev_key_service signer** |

Hop between them with `ssh agentkey@$BROKER_HOST`.

> **Roles + key inventory primer.** This demo exercises the **master**
> role only (workstation = master per [`architecture.md` §4a](arch.md)).
> The **agent** role (sandbox VM / CI runner / `agent-infra/sandbox`
> container, bootstrapped via link-code from a master) is documented
> in [`architecture.md` §5a.2](arch.md) and the
> [agent wiki page](wiki/agent-role-and-usage-hdkd-per-agent-omni.md)
> but is **not exercised here** — the v0.2 `agentkeys agent create`
> endpoint isn't shipped yet (tracked in
> [#76](https://github.com/litentry/agentKeys/issues/76)). For the
> K-numbered key inventory referenced throughout (K1 = broker session
> keypair, K3 = dev-signer master secret, K4 = per-actor derived
> wallet, K6 = session JWT, K7 = OIDC JWT, K10 = device key, K11 =
> WebAuthn credential), see [`architecture.md` §3](arch.md).

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

# 6. Capability check — the binary MUST be new enough to expose
#    --session-id (added 2026-05-12). Without it, AGENTKEYS_SESSION_ID
#    is silently ignored by `init-email-demo.sh --session-id alice` and
#    the session lands at ~/.agentkeys/master/session.json regardless,
#    breaking the §4 two-session isolation proof and `demo-show.sh`.
agentkeys --help | grep -q -- "--session-id" \
  && echo "session-id flag present (multi-tenant supported)" \
  || { echo "STALE BINARY — re-run steps 3-4. Probable cause: skipped 'cargo build' after pulling latest evm."; exit 1; }
```

> **If `command -v agentkeys` still prints `agentkeys: aliased to …`,**
> the alias is set in a config file step 1 didn't catch (e.g.
> `~/.zprofile`, `~/.aliases`, or shell-specific include). Run
> `grep -rn 'alias agentkeys' ~/.zshenv ~/.zshrc ~/.zprofile ~/.aliases 2>/dev/null`
> to find it, delete it, then `exec zsh -l` to reload.

After the build is on `$PATH`, run `agentkeys --session-id <id> init`
once per tenant to save a session JWT under
`~/.agentkeys/<id>/session.json` (or in the OS keychain — see the
`AGENTKEYS_SESSION_STORE=file` note in §0.4). The CLI auto-attaches
the saved JWT as `Authorization: Bearer …` on every `/dev/*` call.

This demo runs two side-by-side tenants — `alice` and `bob` — to
exercise the multi-tenant story end-to-end (§0.4 inits both via
`init-email-demo.sh`, §2 SIWEs them in turn, §4 proves cloud-enforced
isolation between them). Every `agentkeys` call below either passes
`--session-id <id>` explicitly OR relies on `export
AGENTKEYS_SESSION_ID=<id>` having been set earlier in the section.
Skipping that wiring sends the call to the default `master` session,
which is usually a stale older session and fails with
`SIGNER_UNAUTHORIZED  invalid session JWT: ExpiredSignature` — see
[§14.8](#148-agentkeys-signer-sign-returns-error-signer_unauthorized--invalid-session-jwt-expiredsignature).

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

### 0.3 Identity → `omni_account` math (reference)

The broker derives `omni_account = SHA256("agentkeys" || identity_type
|| identity_value)`. This helper recomputes it locally so you can
verify the math — but the demo's **actual** `OMNI_A` / `OMNI_B` come
from the live session JWTs minted by `agentkeys-init-email-demo.sh`
in §0.4 below, not from this helper. The signer enforces
`JWT.omni_account == request.omni_account` (per issue #74 step 1b),
so we MUST use the omni that's in the session JWT — feeding the signer
an arbitrary `omni("email", "alice@demo.example")` will fail with
`SIGNER_UNAUTHORIZED: JWT omni_account claim does not match request body`.

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

# Math sanity-check only — these don't drive the rest of the demo:
omni email "demo-1@bots.litentry.org"   # what the broker computes for this address
omni evm   "0x5a0c3df691d55008d88a17e06710b6b28718ec4d"  # post-SIWE EVM identity
```

> **What `identity_type` does each demo identity get?** The
> magic-link flow stamps `("email", lower(address))` for the **first,
> transient** JWT (the one the broker hands the CLI right after the
> magic-link click). The CLI then derives a wallet at the signer, links
> it, SIWE-signs it, and the broker mints the **FINAL** session JWT
> with `identity_type="evm"` + `identity_value=lower(wallet)` —
> per [`crates/agentkeys-broker-server/src/handlers/auth/wallet_verify.rs:51`](../crates/agentkeys-broker-server/src/handlers/auth/wallet_verify.rs#L51).
> The email omni is NOT in this final JWT — only the EVM (actor) omni
> is. Anything the signer / AWS / audit sees is keyed on the EVM omni.
> The transient email omni only exists during the ~1-second window
> between magic-link click and SIWE verify, and is never persisted.

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
>    stateful per [`architecture.md`](arch.md) §5a.1.M:
>    CSPRNG token → SHA256 in EmailTokenStore → single-use within TTL.)
>
>    **Broker IAM role: `agentkeys-broker-host`** (canonical, per
>    `cloud-setup.md` §3.4 — the legacy `S3-full-access` name was
>    fully retired 2026-05-12). The role's `BrokerSendEmail` inline
>    policy must grant **both** `ses:SendEmail` (per-request) **and**
>    `ses:GetEmailIdentity` (Tier-2 verify probe — without it /readyz
>    stays 503-degraded on `auth/email_link`). Verify with:
>    ```bash
>    awsp agentkeys-admin
>    set -a; source scripts/operator-workstation.env; set +a
>    aws iam get-role-policy --role-name agentkeys-broker-host \
>      --policy-name BrokerSendEmail \
>      --query 'PolicyDocument.Statement[*].Action'
>    # Expected: [["ses:SendEmail","ses:GetEmailIdentity"]]
>    ```
>
>    **If `agentkeys init --email` returns `502 backend_unreachable`
>    with body `... ses SendEmail: unhandled error
>    (AccessDeniedException)`**: the broker's runtime role lost a perm
>    or got swapped under it. Confirm it's still `agentkeys-broker-host`
>    via the discovery snippet below (defensive — guards against future
>    instance-profile drift), then re-apply the grant if needed:
>    ```bash
>    # CRITICAL: pass --region "$REGION" explicitly. The agentkeys-admin
>    # profile defaults to us-west-2, but the broker EC2 lives in
>    # us-east-1. Without --region, describe-instances searches us-west-2,
>    # finds nothing, returns empty (no error). See CLAUDE.md → AWS
>    # local-profile ↔ remote-IAM mapping.
>    INSTANCE_PROFILE_ARN=$(aws ec2 describe-instances \
>      --region "$REGION" \
>      --filters "Name=ip-address,Values=$EIP" \
>      --query 'Reservations[].Instances[].IamInstanceProfile.Arn' \
>      --output text)
>    if [[ -z "$INSTANCE_PROFILE_ARN" || "$INSTANCE_PROFILE_ARN" == "None" ]]; then
>      echo "ABORT: no EC2 instance with EIP=$EIP found in region $REGION." >&2
>      echo "Caller: $(aws sts get-caller-identity --query Arn --output text)" >&2
>      unset ROLE
>    else
>      # iam is global — no --region needed.
>      ROLE=$(aws iam get-instance-profile \
>        --instance-profile-name "${INSTANCE_PROFILE_ARN##*/}" \
>        --query 'InstanceProfile.Roles[0].RoleName' --output text)
>      echo "broker runtime role: $ROLE   (expected: agentkeys-broker-host)"
>    fi
>
>    # Re-apply the BrokerSendEmail policy with BOTH actions
>    # (idempotent — put-role-policy replaces the prior inline policy):
>    aws iam put-role-policy --role-name "$ROLE" \
>      --policy-name BrokerSendEmail \
>      --policy-document "$(jq -n \
>        --arg region "$REGION" --arg acct "$ACCOUNT_ID" --arg domain "$MAIL_DOMAIN" \
>        '{Version:"2012-10-17",Statement:[{Effect:"Allow",
>          Action:["ses:SendEmail","ses:GetEmailIdentity"],
>          Resource:[
>            "arn:aws:ses:\($region):\($acct):identity/\($domain)",
>            "arn:aws:ses:\($region):\($acct):identity/*@\($domain)"
>          ]}]}')"
>    ```
>    No broker restart needed for SendEmail — sesv2 picks up creds
>    per-call. **A restart IS needed** for `ses:GetEmailIdentity` to
>    take effect on /readyz, because the Tier-2 verify probe runs once
>    at boot (then every 12h) — see commit `722a990` for the probe wiring.
>    See [`cloud-setup.md` §3.4a](cloud-setup.md#34a-sessendemail-grant-on-the-brokers-runtime-role-pass-2-prereq)
>    for the full discovery + grant flow.
>
>    **If the setup script dies with `cargo did NOT enable
>    auth-email-link despite --features auth-email-link`**: cargo's
>    own `--message-format=json` reports the feature is missing — this
>    is a host-environment override, NOT a script bug. The die message
>    lists 5 specific things to check (`~/.cargo/config.toml`,
>    workspace `.cargo/config.toml`, `env | grep CARGO`, `which cargo`,
>    `Cargo.lock`). The script catches this at build-time so a bad
>    binary never reaches systemd.
>
>    **If `agentkeys init --email` returns `502 Bad Gateway` from
>    nginx**: the broker process crashed at boot (nginx up, `:8091`
>    dead). The post-restart probe should die loud with the journal
>    output during re-deploy, but if the broker was started some other
>    way, diagnose with:
>    ```bash
>    ssh agentkey@$BROKER_HOST '
>      sudo journalctl -u agentkeys-broker -n 60 --no-pager | grep -E "BOOT_FAIL|ERROR" | tail -10
>    '
>    ```
>    Historical Pass-2 trap (now caught at build-time per above):
>    `BROKER_AUTH_METHODS="email_link": unknown or feature-gated-out
>    auth method` meant the binary was built without
>    `--features auth-email-link`. The current script defends against
>    this two ways: (1) `cargo clean -p agentkeys-broker-server
>    --release` before the broker rebuild defeats stale incremental
>    cache; (2) the `--message-format=json` assertion fails the script
>    at build-time if cargo did not enable the feature. If you still
>    see this BOOT_FAIL on a fresh re-deploy, run the script with
>    `bash -x scripts/setup-broker-host.sh 2>&1 | grep -E "cargo|features"`
>    and file an issue with the output.

#### Key topology in the saved session JWT (cross-link to `architecture.md` §3 + §3a + §4)

Before you run any derive call, it pays to know what `agentkeys init`
actually wrote to disk and which of the THREE wallets the rest of the
demo refers to. The shell-var spellings (`OMNI_A`, `ADDR_A`,
`MASTER_WALLET_A`) are local to this demo; the **arch.md canonical
names** in the table below are the source-of-truth spellings used in
[`architecture.md` §3a Canonical names](arch.md#3a-canonical-names-one-concept-one-canonical-spelling)
and in the broker / CLI source. Any future doc / runbook / commit
should use the arch.md spellings; this demo keeps the `_A` / `_B`
shell vars because they're embedded across §0.4–§4 + scripts.

```
session.json → JWT claims (arch.md K6 = session JWT, §3 row K4 = per-actor wallet):
  agentkeys.identity_type   = "evm"                ← always "evm" in the FINAL JWT (even for --email init)
  agentkeys.identity_value  = 0x<master_wallet>    ← the SIWE-verified wallet (== wallet_address below)
  agentkeys.omni_account    = SHA256("agentkeys"||"evm"||lower(master_wallet))   ← arch.md actor_omni
  agentkeys.wallet_address  = 0x<master_wallet>    ← arch.md master_wallet (K4 = HKDF(K3, identity_omni_email))
```

| Demo shell var (this guide) | arch.md §3a canonical name      | Derivation                                              | First minted at                                                 | Used for                                                                                                            |
|-----------------------------|---------------------------------|---------------------------------------------------------|-----------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| `MASTER_WALLET` / `MASTER_WALLET_A` | `master_wallet`           | K4 = HKDF(K3, `identity_omni`) where `identity_omni = SHA256("agentkeys" \|\| identity_type \|\| identity_value)` at init time | `agentkeys init` step 3 (`/dev/derive-address` w/ id-omni JWT)  | The wallet the broker linked + SIWE-verified at init. Stored in the post-init JWT as `wallet_address`. `agentkeys whoami` prints this under the label `session_wallet:`. If you skip §2 and mint OIDC from the init JWT directly, this is the wallet AWS sees in `agentkeys_user_wallet`. |
| `ADDR` / `ADDR_A`           | `derived_address(actor_omni)`   | K4' = HKDF(K3, `actor_omni`) where `actor_omni = SHA256("agentkeys" \|\| "evm" \|\| master_wallet)`                            | §0.4 below, via `agentkeys signer derive --omni-account $OMNI`   | A *second* K4 instance, recomputed on demand. §2's SIWE round-trip uses it; §2.3 mints a FRESH session JWT with `wallet_address=ADDR_A`, and §3/§4 mints OIDC from THAT JWT — so for the §2 manual path, this is what AWS sees in `agentkeys_user_wallet`. Never persisted on disk. |
| `OMNI` / `OMNI_A`           | `actor_omni`                    | `SHA256("agentkeys" \|\| "evm" \|\| master_wallet)`     | `agentkeys init` SIWE-verify response (`/v1/auth/wallet/verify`) | Every `/dev/*` call's `--omni-account`. The signer's strict JWT-omni check (issue #74 step 1b) rejects any call where this doesn't equal `JWT.agentkeys.omni_account`.  |
| `IDENTITY_OMNI`             | `identity_omni`                 | `SHA256("agentkeys" \|\| identity_type \|\| identity_value)`                                                                    | broker `/v1/auth/email/verify` (transient)                       | Used internally by init between email-link → SIWE; gone from the JWT post-SIWE (when identity rebinds to `"evm"` + `master_wallet`). Recomputable locally for cross-check. |

**Two K4 wallets, one per omni — why both exist.** The signer's
`/dev/derive-address` is a pure function of `(K3, omni)` — same omni
in, same wallet out. At init the CLI calls derive with
`identity_omni`, producing `master_wallet`. Post-init the saved JWT
carries `actor_omni` (≠ `identity_omni`), so any subsequent
`signer derive` call against that JWT returns a *different* wallet —
`derived_address(actor_omni)`. Both are real, signable, deterministic.
§2 has to use `derived_address(actor_omni)` because that's the only
wallet the post-init JWT can authorize signing for (strict JWT-omni
check rejects sign requests where `request.omni ≠ JWT.omni_account`).

**Which wallet ends up in AWS PrincipalTag?** Whatever wallet was the
`wallet_address` claim of the session JWT used to mint the OIDC token.
The broker (at
[`handlers/oidc.rs:106`](../crates/agentkeys-broker-server/src/handlers/oidc.rs#L106))
reads `session_claims.agentkeys.wallet_address` and stamps it into
`aws.amazon.com/tags.principal_tags.agentkeys_user_wallet`. Two paths:

- **§2 manual SIWE path** (this demo's canonical route): §2.3 mints a
  FRESH session JWT with `wallet_address = derived_address(actor_omni)`
  (= `$ADDR_A`). §3 mints OIDC from that JWT, so
  `agentkeys_user_wallet = $ADDR_A`, and §4's S3 prefix is
  `bots/$ADDR_A/`.
- **§0.4-only path** (skip §2): the OIDC mint reads the on-disk init
  JWT whose `wallet_address = master_wallet` (= `$MASTER_WALLET_A`).
  `agentkeys_user_wallet = $MASTER_WALLET_A` and S3 prefix would be
  `bots/$MASTER_WALLET_A/`.

The CLI's `agentkeys whoami` always reads the on-disk JWT, so its
`session_wallet:` field is `$MASTER_WALLET_A` regardless of which path
you used for §3. If you walked §2 manually, `whoami session_wallet`
and the OIDC `agentkeys_user_wallet` decode to **different** values —
both arch.md `master_wallet`, but of two different JWTs (on-disk init
JWT vs §2.3 fresh JWT). See `architecture.md` §3a for the full alias
table.

#### Run two distinct sessions with `--session-id` (no overwrite)

`init-email-demo.sh` is a fully-automated end-to-end demo: it sends a
magic link via real SES, polls `s3://$MAIL_BUCKET/inbound/` for the
arrival, extracts the broker landing URL, parses the `#t=<token>` URL
fragment, and POSTs to `/v1/auth/email/verify` — replicating the
browser-side JS in `/auth/email/landing`. Then it waits for the
foreground `agentkeys init` to complete.

The script honors a top-level `--session-id <name>` flag (and the
`AGENTKEYS_SESSION_ID` env var). The agentkeys CLI threads this
through to `session_store`, so the resulting JWT lands at
`~/.agentkeys/<name>/session.json` instead of overwriting the default
`~/.agentkeys/master/session.json`. Two back-to-back runs with distinct
session-ids leave both sessions live — exactly what §4's two-actor
isolation proof needs.

When `--session-id <name>` is set AND no positional recipient or
`$RECIPIENT` env override is in play, the script picks
`<name>@$MAIL_DOMAIN` as the recipient. So `--session-id alice` sends
the magic link to `alice@bots.litentry.org` and `--session-id bob` to
`bob@bots.litentry.org`. The two recipients hash to two different
`identity_omni`s, which `signer.derive(K3, omni)` deterministically
maps to two different wallets — the §4 isolation proof can then
exercise true cross-actor denial. Recipient precedence is
`$RECIPIENT` env > positional arg > derived from `--session-id` >
legacy `demo-1`/`demo-2` epoch-parity rotation (only when no
session-id is set).

Do not prefix `sudo` — the script is user-space (AWS APIs + the
`agentkeys` CLI write to YOUR keychain/file, not root's), and `sudo`
strips the env vars you sourced from `operator-workstation.env`.

```bash
# === ON OPERATOR WORKSTATION ===
bash scripts/agentkeys-init-email-demo.sh --session-id alice
bash scripts/agentkeys-init-email-demo.sh --session-id bob
```

The first ~5 log lines surface the recipient and the SHA256 inputs:

```
==> Session id   : alice                  (writes ~/.agentkeys/alice/session.json)
==> Recipient    : alice@bots.litentry.org
==>   identity_omni (email) = dbcb6acda12532fa3838923534288dd89e32bbf9ad7d14e8ff191cf497bf8010
==>   = SHA256("agentkeys" || "email" || "alice@bots.litentry.org")
```

so a recipient collision is diagnosable BEFORE SES SendEmail fires.

For a real inbox you control instead of an `@bots.litentry.org` alias,
override the recipient explicitly:

```bash
agentkeys --session-id alice init \
  --email <you>@<your-real-domain> \
  --broker-url $OIDC_ISSUER \
  --signer-url $BACKEND_URL
```

`agentkeys init` prints the three init-time omnis on success
(`identity omni`, `derived wallet`, `evm omni`). The `evm omni` is the
durable `actor_omni` that lands in `JWT.agentkeys.omni_account`; the
`identity omni` is transient and never persisted.

#### Inspect what landed: `agentkeys-demo-show.sh` modes

The helper reads `~/.agentkeys/<id>/session.json`, base64-decodes the
JWT body, computes the locally-derivable fields (e.g. `identity_omni`),
and emits one of three formats.

| Mode                    | What it prints                                                                                                                                                                                              | Use when                                                                              |
|-------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------|
| (default — human)       | Color-coded report grouped under `identity` / `actor` / `signer-wire smoke test` / `JWT lifetime` headings. The `SHA256("agentkeys"\|\|type\|\|value)` formula prints under `identity_omni`.                | Eyeball check — "is the session healthy? what's the wallet? when does it expire?"     |
| `--json`                | Same fields nested under `identity` / `actor` / `signer_derive` / `jwt`.                                                                                                                                    | Piping into `jq` or another script.                                                   |
| `--export <PREFIX>`     | Eval-able `printf %q`-escaped assignments: `SESSION_ID_<P>=…`, `OMNI_<P>=…`, `ADDR_<P>=…`, `MASTER_WALLET_<P>=…`, `IDENTITY_TYPE_<P>=…`, `IDENTITY_VALUE_<P>=…`, `IDENTITY_OMNI_<P>=…`. Forces `--derive`.  | Capturing the seven fields into shell vars for §2/§4 (`eval "$(...)"`).               |

Two flags adjust behavior across modes:

- `--no-derive` skips the `signer derive` round-trip; the `ADDR` field
  ends up empty. Useful when the signer is offline or you only need
  JWT-side fields.
- A positional `<session-id>` (default `master`) selects which
  `~/.agentkeys/<id>/session.json` to read. `AGENTKEYS_SESSION_ID`
  has the same effect.

```bash
# === ON OPERATOR WORKSTATION ===
bash scripts/agentkeys-demo-show.sh alice
bash scripts/agentkeys-demo-show.sh --json bob | jq .actor.omni
bash scripts/agentkeys-demo-show.sh --no-derive alice
```

#### Capture (`OMNI`, `ADDR`) pairs for §2 + §4 via `--export`

`--export <PREFIX>` is the canonical way to feed §2's SIWE round-trip
and §4's S3 isolation proof. Two `eval` calls populate the seven
per-session vars for both A and B labels; the rest of the demo just
references `$OMNI_A` / `$ADDR_A` / `$ADDR_B` etc. without re-decoding
the JWT. Idempotent — the script reads the file + calls `signer derive`
deterministically, so re-running overwrites the same shell vars with
the same values.

```bash
# === ON OPERATOR WORKSTATION ===
eval "$(bash scripts/agentkeys-demo-show.sh --export A alice)"
eval "$(bash scripts/agentkeys-demo-show.sh --export B bob)"

# Stick the alice session as the default for the rest of §2. Without
# this, every `agentkeys signer sign`/`derive` call below falls back to
# --session-id master, which is likely an older expired session (see
# §14.8). Retarget to "$SESSION_ID_B" right before §2.4's bob block.
export AGENTKEYS_SESSION_ID="$SESSION_ID_A"
```

`--export` emits shell vars only — it does NOT route follow-up
`agentkeys` calls. The CLI's `--session-id` flag defaults to `master`,
so an unset `AGENTKEYS_SESSION_ID` silently reads
`~/.agentkeys/master/session.json` even after `eval … --export A alice`.
The explicit `export` line above pins routing for the rest of the
section; §2.4 retargets to bob the same way.

Per-session vars (label `A` shown; `B` is symmetric):

| Var                | Source                                                                                  | Used by                                                                                              |
|--------------------|-----------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `SESSION_ID_A`     | The session-id the script was called with (`alice`).                                    | Routing follow-up `agentkeys --session-id` calls.                                                    |
| `OMNI_A`           | `JWT.agentkeys.omni_account` — durable EVM actor omni.                                  | Every `/dev/*` call (signer's strict JWT check requires the request omni to match the JWT claim).    |
| `ADDR_A`           | `signer.derive(OMNI_A) = HKDF(K3, OMNI_A)`.                                             | §2's SIWE round-trip; §4's S3 isolation proof tags traffic with this via §2.3's freshly-minted JWT.  |
| `MASTER_WALLET_A`  | `JWT.agentkeys.wallet_address` from init — the wallet the broker linked + SIWE-verified at init. | Audit only post-init; not used by §2 or §4.                                                          |
| `IDENTITY_TYPE_A`  | `JWT.agentkeys.identity_type` — `"evm"` post-SIWE for the email-link flow.              | The `omni()` helper in §0.3 + the SHA256 cross-check.                                                |
| `IDENTITY_VALUE_A` | `JWT.agentkeys.identity_value` — same as `MASTER_WALLET_A` post-SIWE.                   | Same.                                                                                                |
| `IDENTITY_OMNI_A`  | Locally recomputed `SHA256("agentkeys" \|\| IDENTITY_TYPE_A \|\| IDENTITY_VALUE_A)`.    | Cross-check — the JWT does NOT carry this post-SIWE.                                                 |

Sanity-check both sessions are distinct (any of these failing means
the recipient defaults collided — see the callout below):

```bash
[[ "$OMNI_A"          != "$OMNI_B"          ]] && echo "actor-omni split ok"
[[ "$ADDR_A"          != "$ADDR_B"          ]] && echo "ADDR split ok"
[[ "$MASTER_WALLET_A" != "$MASTER_WALLET_B" ]] && echo "wallet split ok"
```

> **Symptom: `MASTER_WALLET_A == MASTER_WALLET_B` after two distinct
> `--session-id` inits.** Both inits hit the same recipient email,
> producing the same `identity_omni_email`, and HKDF(K3, …)
> deterministically returned the same wallet. Since the 2026-05-13
> fix, calling `init-email-demo.sh --session-id <name>` defaults the
> recipient to `<name>@$MAIL_DOMAIN`, which is guaranteed-unique per
> session-id. If you see a collision today: (a) you passed the same
> positional recipient to both runs (`--session-id alice demo-2`
> twice), or (b) you set `$RECIPIENT` in your shell and it's
> overriding both. The script's recipient + `identity_omni (email)`
> log lines make the collision visible BEFORE SES SendEmail fires.

> **Why `--session-id` matters.** The signer's strict JWT-omni check
> means each session JWT only authorizes `/dev/*` calls for ITS own
> actor_omni. Without `--session-id`, a second `agentkeys init` run
> overwrites `~/.agentkeys/master/session.json` and the first
> `(omni, wallet)` pair is lost. With `--session-id alice` +
> `--session-id bob` the two sessions live side by side and §4 can
> drive each in turn (`agentkeys --session-id alice ...` vs
> `--session-id bob ...`).

> **Why `ADDR_A` is `signer derive(OMNI_A)` and NOT `JWT.wallet_address`.**
> §2.2 below calls `agentkeys signer sign --omni-account $OMNI_A` and
> ecrecover on the resulting signature recovers to `HKDF(K3, OMNI_A)` —
> i.e. to `ADDR_A`. For §2.1's SIWE message (which puts `ADDR_A` in the
> body) to survive `/v1/auth/wallet/verify`, the message-address MUST
> equal the signature-recovered address, so `ADDR_A` has to be
> `HKDF(K3, OMNI_A)`. §2.3 then mints a FRESH session JWT with
> `wallet_address=ADDR_A`, and §4 mints OIDC from that JWT — so AWS
> sees `ADDR_A` (= `HKDF(K3, OMNI_A)`) in the PrincipalTag, not
> `MASTER_WALLET_A`. `MASTER_WALLET_A` (= `HKDF(K3, identity_omni_email)`)
> only matters if you skip §2 entirely and mint OIDC directly from the
> init JWT — see the "Which one does AWS see?" paragraph above for the
> mechanical explanation.

> **macOS Keychain prompts during `agentkeys` calls?** The CLI defaults
> to `KeyringMode::Auto` — Keychain first, file fallback. On a fresh
> machine that's fine, but if you've run earlier dev cycles the
> Keychain can hold a stale entry that returns
> `SIGNER_UNAUTHORIZED: invalid session JWT: InvalidToken` from
> `agentkeys signer derive` even while the file at
> `~/.agentkeys/<id>/session.json` is fresh and valid. Force file mode
> for the entire demo:
> ```bash
> export AGENTKEYS_SESSION_STORE=file
> ```
> `operator-workstation.env` sets this for you when you `set -a;
> source` it. Verify with a raw curl using the file's JWT — if that
> succeeds while the CLI fails, your Keychain definitely has a stale
> entry:
> ```bash
> JWT=$(jq -r .token ~/.agentkeys/alice/session.json)
> curl -sS -H "Authorization: Bearer $JWT" -H 'content-type: application/json' \
>   -d "$(jq -n --arg o "$OMNI_A" '{omni_account: $o}')" \
>   "$AGENTKEYS_SIGNER_URL/dev/derive-address" | jq .
> ```
> A `{"address":"0x...","key_version":1}` response means the JWT and
> signer wire are good and only the CLI's Keychain read is broken.

`ADDR_A` and `ADDR_B` are 0x-prefixed 40-char lowercase hex EVM
addresses. They're stable across daemon reinstalls as long as the K3
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

**Two ways to drive this section** — pick one, then jump to §3:

| Path                       | When to use                                                                  | What it runs                                                                                                                       |
|----------------------------|------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| `init-email-demo.sh` (§0.4) | Default for demos, CI, doc verification — no human-in-the-loop click needed. | The script auto-clicks the magic link by polling `s3://$MAIL_BUCKET/inbound/`. §0.4 already ran this for alice + bob.               |
| Manual `agentkeys init --email` (§2.0) | You want the magic link in an inbox you control (real demo to a stakeholder, or smoke-testing real SES delivery). | Same `/v1/auth/email/request` + `/v1/auth/email/verify` chain, but you click the link in your mail client. Requires `--email <deliverable-addr>`. |
| Manual SIWE walkthrough (§2.1–§2.5) | Debugging a step the one-command path hides, or explaining the trust model to a reviewer. | Exactly the chain `init --email` runs internally, exposed call-by-call. Functionally redundant after §0.4 or §2.0 — read it for understanding, don't expect it to produce a new session. |

### 2.0 Recommended path: `agentkeys init --email`

Issue #74 step 1 + Pass 2 of Option B (closed [issue #80](https://github.com/litentry/agentKeys/issues/80))
ship a single-command bootstrap that drives the entire chain end-to-end
against real SES delivery. Use this for any real demo or production deployment.

> **Already done by §0.4 if you ran `init-email-demo.sh --session-id
> alice` (and bob).** That script runs `agentkeys init --email` against
> a deliverable `<id>@$MAIL_DOMAIN` recipient, polls
> `s3://$MAIL_BUCKET/inbound/` for the SES inbound, parses the
> `#t=<token>` fragment, and POSTs `/v1/auth/email/verify` —
> programmatically replicating the browser-side click. By the time it
> exits, alice's `~/.agentkeys/alice/session.json` holds a fully
> SIWE'd JWT and §2.1–§2.5 below would re-do the same chain manually.
> **For automation, skip to [§3](#3-mint-oidc-jwt-for-sts).** Read
> §2.1–§2.5 only when you want to inspect each wire frame or are
> debugging a step the script normally hides.

> **Prereq if you haven't done §0.4 yet:** the two-step setup from
> §0.4 — `bash scripts/ses-verify-sender.sh` (one-time SES sender
> registration) + `sudo bash scripts/setup-broker-host.sh --yes` on the
> broker host (Pass 2 build with `auth-email-link` + `email_link` in
> `BROKER_AUTH_METHODS`).

If you're driving the init manually (because you want a real
operator-controlled inbox rather than the `@bots.litentry.org` alias),
the equivalent one-command form is:

```bash
# === ON OPERATOR WORKSTATION ===
agentkeys --session-id alice init \
  --email <your-deliverable-address> \
  --broker-url $OIDC_ISSUER \
  --signer-url $BACKEND_URL
# Magic link sent via real SES (FROM noreply-test@bots.litentry.org).
# Click the link in your inbox; the CLI is polling…
# (operator clicks the magic link)
# Initialized via email-link.
#   identity omni: <64 hex>
#   derived wallet: 0x…
#   evm omni:      <64 hex>
```

The automated equivalent — same result, no click required — is what
§0.4 already runs:

```bash
bash scripts/agentkeys-init-email-demo.sh --session-id alice
# (auto-prints a "Next: capture eval-able shell vars" hint at the end —
#  copy-paste the eval line below to populate $ADDR_A / $OMNI_A / …)
eval "$(bash scripts/agentkeys-demo-show.sh --export A alice)"
export AGENTKEYS_SESSION_ID=alice
```

Pick whichever fits the run: the script for unattended demos / CI /
docs verification, the manual `--email <addr>` form when you want the
magic link delivered to an inbox you control.

> **Why the second line matters.** `init-email-demo.sh` runs in a
> subprocess, so it can't `export` variables into your parent shell.
> The human-mode session detail it prints at the end is text, not
> assignments. Without the `eval … --export A alice` line, your shell
> either has no `$ADDR_A` / `$OMNI_A` (and §2.1's
> `/v1/auth/wallet/start` fails JSON-validation on an empty address)
> or — worse — carries stale `$ADDR_A` from a previous run against a
> different session/identity. Stale `$ADDR_A` produces the
> `ADDRESS DRIFT — master secret rotated mid-session?` failure at the
> end of §2.2 (the sanity check `[[ "$SIG_ADDR" == "$ADDR_A" ]]`
> compares the just-now signer-returned address against your shell's
> `$ADDR_A`; they only match when both come from the *current* alice
> session). The §0.4 callout earlier already pins this — the eval line
> above is the same line, repeated here for the operator who jumped
> straight into §2 without running §0.4 top-to-bottom.

> **Don't substitute a placeholder email** like `alice@demo.example`
> when you've already run `init-email-demo.sh --session-id alice`. The
> placeholder produces a *different* `identity_omni_email` → different
> `MASTER_WALLET` → different `actor_omni`, and the second init
> overwrites `~/.agentkeys/alice/session.json`. Your shell still holds
> the §0.4 `$OMNI_A` / `$ADDR_A` from the bots-alias identity, so the
> §2.2 strict JWT-omni check fails with a mismatch
> (`request.omni ≠ JWT.omni_account`). Either skip §2.0 entirely (use
> §0.4's script), or pass `--email <addr-you-control>` with a domain
> SES can actually deliver to and re-run §0.4's `--export A alice`
> afterwards to refresh the shell vars.

The `--session-id alice` writes to `~/.agentkeys/alice/session.json`
instead of the default `master`. Subsequent `agentkeys signer …` calls
in §2.1–§2.5 need either the same `--session-id alice` flag or
`export AGENTKEYS_SESSION_ID=alice` once at the top of the shell —
otherwise the CLI silently reads `master`, which is usually a stale
older session (see [§14.8](#148-agentkeys-signer-sign-returns-error-signer_unauthorized--invalid-session-jwt-expiredsignature)).

For OAuth2/Google instead of email-link:

```bash
agentkeys --session-id alice init \
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

**Run this FIRST** — refresh the shell vars for bob's *current*
session and pin the CLI to read bob's session file. Without it, the
`START_B` call below sends a stale `$ADDR_B` from a previous run and
§2.4 ends with `HTTP 401 — signature does not recover to claimed
address` (the SIWE message claims an address derived from
`$ADDR_B_stale`, but `$OMNI_B_stale` doesn't agree — see [§14.4](#144-siwe-verify-returns-signature-does-not-recover-to-claimed-address--or-address-drift--master-secret-rotated-mid-session-at-end-of-22)):

```bash
eval "$(bash scripts/agentkeys-demo-show.sh --export B bob)"
export AGENTKEYS_SESSION_ID="$SESSION_ID_B"
```

The `eval` line is **idempotent** — re-running it after every fresh
`init-email-demo.sh --session-id bob` is the canonical fix when bob's
session got re-minted (e.g. expired JWT, K3 rotation, switched
broker hosts). The script's own end-of-run hint prints the exact same
line; this is just here for the operator who jumped straight from
§2.3 into §2.4 without scrolling back.

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

`whoami` is a read-only `/dev/derive-address` call — it surfaces the
omni → address mapping under whichever session is currently pinned.
Inherits `$AGENTKEYS_SESSION_ID` from §0.4 (still `alice` here) or
override per-call with `--session-id <id>`.

```bash
agentkeys whoami \
  --signer-url $BACKEND_URL \
  --omni-account $OMNI_A
# session_wallet:   0x<master_wallet>     ← JWT.agentkeys.wallet_address from ~/.agentkeys/alice/session.json
# signer_url:       https://signer…
# omni_account:     <actor_omni>           ← OMNI_A
# derived_address:  0x<derived_address>    ← HKDF(K3, OMNI_A) = ADDR_A
# key_version:      1

# For bob, retarget the session-id once and rerun:
agentkeys --session-id "$SESSION_ID_B" whoami \
  --signer-url $BACKEND_URL \
  --omni-account $OMNI_B
```

Field-by-field, in arch.md §3a canonical names:

| CLI label          | arch.md canonical name        | What the CLI computes                                                                                                |
|--------------------|--------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `session_wallet`   | `master_wallet`               | Loaded from `~/.agentkeys/$SESSION_ID/session.json` → `JWT.agentkeys.wallet_address`. The init-flow's wallet.        |
| `omni_account`     | `actor_omni`                  | Echoed from the `--omni-account` flag.                                                                               |
| `derived_address`  | `derived_address(actor_omni)` | Server-side `HKDF(K3, actor_omni)` — what `/dev/derive-address` returns for this omni. Equals `$ADDR_A` post-export. |

`session_wallet` and `derived_address` are **two different K4
wallets** — both signable, both deterministic, derived from two
different omnis (`identity_omni` at init vs `actor_omni` post-SIWE).
After §2.3, the §3 OIDC mint stamps `derived_address(actor_omni)`
(NOT `session_wallet`) into `agentkeys_user_wallet`, because §3 reads
`$SESSION_JWT_A` from §2.3's fresh verify response, not the on-disk
session.json. See the "Which wallet ends up in AWS PrincipalTag?"
callout in §0.4 for the full mechanical reason.

---

## 3. Mint OIDC JWT for STS

The session JWT is broker-internal. AWS STS speaks a different JWT
(signed by K2, the OIDC keypair) carrying the PrincipalTag claim.
Exchange the session JWT for an OIDC JWT — once for alice, once for
bob — and decode each to capture the wallet that ended up in
`agentkeys_user_wallet`. **That decoded wallet IS the value §4's S3
prefix uses** — no path-specific naming, no mental substitution.

```bash
# === ON OPERATOR WORKSTATION ===
# Prereq: $SESSION_JWT_A from §2.3's VERIFY, $SESSION_JWT_B from
# §2.4's VERIFY_B. If you skipped §2 entirely, read both from disk
# (footnote at section end).

JWT_A=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq -r .jwt)
JWT_B=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_B" | jq -r .jwt)

# Decode each JWT's body once, extract the wallet AWS will tag the
# assumed-role session with. These are the canonical names §4 uses.
decode_aws_wallet() {
  echo "$1" | cut -d. -f2 | tr '_-' '/+' \
    | python3 -c "import base64,sys; s=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(s+'='*(-len(s)%4)).decode())" \
    | jq -r .agentkeys_user_wallet
}
WALLET_A=$(decode_aws_wallet "$JWT_A")
WALLET_B=$(decode_aws_wallet "$JWT_B")
echo "WALLET_A=$WALLET_A  WALLET_B=$WALLET_B"
# WALLET_A=0x…  WALLET_B=0x…   (the two wallets your bucket policy will gate on)
```

Confirm the `aws.amazon.com/tags` claim is present on `JWT_A` — STS
needs it to stamp the PrincipalTag:

```bash
echo "$JWT_A" | cut -d. -f2 | tr '_-' '/+' \
  | python3 -c "import base64,sys; s=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(s+'='*(-len(s)%4)).decode())" \
  | jq '{aud, sub, agentkeys_user_wallet, tags: ."https://aws.amazon.com/tags"}'
# {
#   "aud": "sts.amazonaws.com",
#   "sub": "agentkeys:agent:0x…<WALLET_A>",
#   "agentkeys_user_wallet": "0x…<WALLET_A>",
#   "tags": {
#     "principal_tags": {"agentkeys_user_wallet": ["0x…<WALLET_A>"]},
#     "transitive_tag_keys": ["agentkeys_user_wallet"]
#   }
# }
```

JWT TTL is **5 min**. If §4 errors with `InvalidIdentityToken`, the
JWT expired — rerun the two `mint-oidc-jwt` curls (the session JWTs
last 5h, so you usually don't need to re-do §2).

> **Where `$WALLET_A` actually points to.** §3 doesn't pick the
> wallet — it just *reports* whichever wallet the broker stamped into
> your session JWT at init/SIWE time. Concretely:
> - If `$SESSION_JWT_A` came from §2.3's manual SIWE (`$VERIFY` →
>   `.session_jwt`), `$WALLET_A` = `$ADDR_A` = arch.md
>   `derived_address(actor_omni)`.
> - If `$SESSION_JWT_A` came from the on-disk init JWT
>   (`~/.agentkeys/<id>/session.json`), `$WALLET_A` = `$MASTER_WALLET_A`
>   = arch.md `master_wallet`.
>
> Either is valid — §4 just uses `$WALLET_A` directly, no
> conditional. The wallet you committed to at §2/§0.4 is the wallet
> S3 will gate on.

> **Skipped §2 entirely?** Read the session JWTs from disk:
> ```bash
> SESSION_JWT_A=$(jq -r .token ~/.agentkeys/alice/session.json)
> SESSION_JWT_B=$(jq -r .token ~/.agentkeys/bob/session.json)
> ```
> (Or `security find-generic-password -s agentkeys -a alice -w | jq -r .token` on macOS
> Keychain mode — check by listing `~/.agentkeys/alice/.keyring_managed`:
> present-and-non-empty ⇒ Keychain, otherwise file.) Then resume with
> the two `mint-oidc-jwt` curls above.

---

## 4. Cloud-enforced isolation proof

Assume `agentkeys-data-role` with `JWT_A`, then attempt to read both
alice's prefix (`bots/$WALLET_A/`) and bob's prefix (`bots/$WALLET_B/`).
The first succeeds, the second is denied **by AWS, not by app code**.

The S3 prefix shape (`bots/<wallet>/…`) matches arch.md §6's
sequence diagram — `bots/` is the per-actor data namespace, sibling to
SES's `inbound/`, future `audit/`, etc. Keeping user data under a
single parent prefix lets lifecycle rules, encryption defaults, and
replication scope cleanly to "user data" without touching the
bucket's system prefixes. The bucket policy from
[`cloud-setup.md` §4.4](cloud-setup.md#44-upgrade-bucket-policy-to-principaltag-scoped)
grants access conditioned on
`bots/${aws:PrincipalTag/agentkeys_user_wallet}/*`.

### 4.0 One-shot run: `agentkeys-isolation-demo.sh`

This script is the executable form of §3 + §4.1–§4.3. It reads alice
+ bob's saved sessions (running `init-email-demo.sh` first if either
isn't on disk), mints both OIDC JWTs, decodes `$WALLET_A` /
`$WALLET_B` from the `agentkeys_user_wallet` claim, assumes the data
role as alice, seeds `bots/$WALLET_A/` + `bots/$WALLET_B/` via admin,
then asserts:

- 4a: `list bots/$WALLET_A/` → success (alice's own prefix)
- 4b: `get bots/$WALLET_B/hello.txt` → AccessDenied (bob's prefix)

```bash
# === ON OPERATOR WORKSTATION ===
# Prereqs: operator-workstation.env sourced; awsp agentkeys-admin (for the
# seed step); bucket policy applied per cloud-setup.md §4.4; role inline
# policy stripped per cloud-setup.md §4.4.1.
bash scripts/agentkeys-isolation-demo.sh
# ==> WALLET_A=0x…
# ==> WALLET_B=0x…
# ✓ alice reads bots/<WALLET_A>/ — allowed (expected)
# ✓ alice DENIED on bots/<WALLET_B>/ — cloud-enforced isolation works
# ✓ §4 isolation proof PASSED
```

Flags:

- `--reinit-alice` / `--reinit-bob` / `--reinit-both` — force a fresh
  init (replaces the on-disk session JWT) before the proof. Default
  reuses existing sessions.

Exit codes:

- `0` proof passed
- `1` precondition missing (env vars, tools, sessions)
- `2` alice's own-prefix read failed (false-negative — check
  cloud-setup.md §4.4 bucket policy + §4.4.1 role inline strip)
- `3` bob's peer-prefix read succeeded (false-positive — **isolation
  broken**, §4.4.1 wasn't applied so the role's broad `s3:GetObject`
  overrides the bucket-policy PrincipalTag check)

§4.1–§4.3 below are the same chain, broken into copy-paste steps for
when you want to inspect each wire frame manually.

### 4.1 Assume the role with JWT_A

```bash
# === ON OPERATOR WORKSTATION ===
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role \
  --role-session-name "demo-A-$(date +%s)" \
  --web-identity-token "$JWT_A")

printf '%s' "$CREDS" | jq '.Credentials | {AKID:.AccessKeyId, Exp:.Expiration}'
```

### 4.2 Seed test objects (admin profile, no PrincipalTag check)

Two objects, one per tenant prefix. Admin bypasses the bucket policy
via account ownership, so this works regardless of the per-actor
isolation.

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
awsp agentkeys-admin

# AWS CLI's --body needs a seekable regular file (rejects /dev/null
# on macOS — character device, not a regular file). Use a tmp file:
EMPTY=$(mktemp) && trap 'rm -f "$EMPTY"' EXIT

aws s3api put-object --region "$REGION" --bucket "$BUCKET" \
  --key "bots/${WALLET_A}/hello.txt" --body "$EMPTY"
aws s3api put-object --region "$REGION" --bucket "$BUCKET" \
  --key "bots/${WALLET_B}/hello.txt" --body "$EMPTY"
```

### 4.3 Re-export the assumed-role creds and probe both prefixes

```bash
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r .Credentials.SessionToken)

# Confirm: you are NOT your admin profile any more.
aws sts get-caller-identity
# {
#   "Arn": "arn:aws:sts::<acct>:assumed-role/agentkeys-data-role/demo-A-…"
# }

# 4a — alice's prefix: SUCCESS
aws s3api list-objects-v2 --bucket "$BUCKET" \
  --prefix "bots/${WALLET_A}/" --query 'Contents[*].Key'
# [ "bots/<WALLET_A>/hello.txt" ]

aws s3api get-object --region "$REGION" --bucket "$BUCKET" \
  --key "bots/${WALLET_A}/hello.txt" /tmp/got-A.txt
# { "ContentLength": 0, ... }

# 4b — bob's prefix: AccessDenied (CLOUD-ENFORCED, no app code involved)
aws s3api get-object --region "$REGION" --bucket "$BUCKET" \
  --key "bots/${WALLET_B}/hello.txt" /tmp/got-B.txt
# An error occurred (AccessDenied) when calling the GetObject operation:
# Access Denied
```

**Step 4b is the property the static-IAM path cannot prove.** S3's
policy engine evaluated `${aws:PrincipalTag/agentkeys_user_wallet}`
(= `$WALLET_A`, stamped by STS from `$JWT_A`'s tags claim) against the
resource ARN's `bots/${WALLET_B}/` and refused. Swap to `JWT_B` in
§4.1 and you'd see the mirror — bob can read `bots/${WALLET_B}/` and
gets denied on `bots/${WALLET_A}/`.

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

## 5. Mint AWS creds — single client-side path, post-issue-#71 / #72

After issue #71 Option A landed (caller-side migration) and PR #96 / issue
#72 deleted the legacy `/v1/mint-aws-creds` server-side aggregator, the
auto-provision pipeline mints AWS creds **client-side** by combining
`/v1/mint-oidc-jwt` (broker call) + `AssumeRoleWithWebIdentity`
(daemon-side STS call). The broker no longer needs an IAM principal at
runtime, and no longer holds the mint pipeline at all — it's a pure JWT
signer.

The old `POST /v1/mint-aws-creds` route now returns 404. Daemons that
still try to call it will see a hard failure; re-deploy with a binary
that uses `fetch_via_broker_default_ttl()` (the OIDC-first helper).

### 5.1 The daemon-side flow (auto-provision uses this)

```bash
# === ON OPERATOR WORKSTATION === (or anywhere with the JWT)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# 0. Load $SESSION_JWT_A from the saved session for `--session-id alice`.
#    `agentkeys-demo-show.sh --export A alice` populates OMNI_A / ADDR_A
#    / MASTER_WALLET_A but NOT the JWT — load it here. Tries Keychain
#    first (macOS default), falls back to ~/.agentkeys/<id>/session.json.
load_session_jwt() {
  local sid="$1"
  local marker="${HOME}/.agentkeys/${sid}/.keyring_managed"
  if [[ -s "$marker" ]]; then
    security find-generic-password -s agentkeys -a "$sid" -w 2>/dev/null | jq -r .token 2>/dev/null
  else
    jq -r .token "${HOME}/.agentkeys/${sid}/session.json" 2>/dev/null
  fi
}
SESSION_JWT_A=$(load_session_jwt alice)
[[ -n "$SESSION_JWT_A" && "$SESSION_JWT_A" != "null" ]] || {
  echo "ERROR: no alice session JWT on disk or in Keychain. Run:"
  echo "  bash scripts/agentkeys-init-email-demo.sh --session-id alice"
  echo "first, then retry."; return 1 2>/dev/null || exit 1; }
[[ "$SESSION_JWT_A" =~ ^eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || {
  echo "ERROR: \$SESSION_JWT_A is not a well-formed JWT — alice session corrupt"
  return 1 2>/dev/null || exit 1; }

# 1. Ask the broker for an OIDC JWT (lightweight call — broker just signs).
#    HTTP 401 here ⇒ session JWT expired (5h TTL). Re-run init.
JWT=$(curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq -r .jwt)

# 1a. Decode the wallet the JWT actually carries — this IS the prefix
# AWS will let you read. Don't assume $ADDR_A or $MASTER_WALLET_A;
# decode and use the authoritative value (same pattern as §3/§4).
decode_aws_wallet() {
  echo "$1" | cut -d. -f2 | tr '_-' '/+' \
    | python3 -c "import base64,sys; s=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(s+'='*(-len(s)%4)).decode())" \
    | jq -r .agentkeys_user_wallet
}
WALLET_A=$(decode_aws_wallet "$JWT")
[[ "$WALLET_A" =~ ^0x[0-9a-f]{40}$ ]] || { echo "ERROR: decoded WALLET_A=$WALLET_A not a 0x-address — JWT malformed or expired"; return 1 2>/dev/null || exit 1; }

# 2. Exchange it for AWS creds CLIENT-SIDE. No broker creds participate.
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role \
  --role-session-name "demo-A-$(date +%s)" \
  --web-identity-token "$JWT")
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r .Credentials.SessionToken)

# 3. Use the temp creds. PrincipalTag-scoped per cloud-setup.md §4.4.
#    `$WALLET_A` is the canonical prefix — never `$ADDR_A` (which is
#    only correct on §2's manual SIWE path; the auto-init path puts
#    `master_wallet` in the JWT, and AWS gates on the JWT, not the
#    operator's mental model).
aws s3 ls "s3://$BUCKET/bots/${WALLET_A}/"
```

Inside `agentkeys-provisioner`, the `fetch_via_broker_default_ttl()`
helper does the same two-step internally and returns an `AwsTempCreds`
struct ready for env-var injection into the scraper subprocess.

### 5.2 Auto-provision pipeline against live broker.litentry.org

The end-to-end auto-provision trigger is the CLI's `provision`
subcommand. `agentkeys provision <service>` loads the saved session
JWT, calls `/v1/mint-oidc-jwt`, exchanges it for AWS temp creds via
`AssumeRoleWithWebIdentity`, and injects the creds into the scraper
subprocess as env vars — all in one shot.

**Prereqs — one-time per workstation + per AWS account:**

```bash
# 1. Scraper deps (Playwright Chromium). The provisioner subprocess
#    imports `playwright`; without this it dies with
#    `Cannot find package 'playwright'`.
(cd provisioner-scripts && npm install && npx playwright install chromium)

# 2. SES inbound-routing Lambda (issue #83). Required for the CDP
#    scraper to read its own verification email via the OIDC workflow
#    (cloud-setup.md §2.4 + §4.5 federation-isolation rule). Without
#    it, the assumed `agentkeys-data-role` lacks read on `inbound/`
#    and the scraper times out at fetch-verification-email.
awsp agentkeys-admin
set -a; source scripts/operator-workstation.env; set +a
bash infra/ses-routing-lambda/deploy.sh
```

**One-shot run** (last verified 2026-05-15). Two lines from a clean
shell — init the session, then provision. The CLI routes
`provision openrouter` to the CDP-backed scraper
([`provisioner-scripts/src/scrapers/openrouter-cdp.ts`](../provisioner-scripts/src/scrapers/openrouter-cdp.ts))
which connects to a real Chrome over CDP. The wrapper script below
auto-launches the throwaway-profile Chrome on `:9222` if one isn't
already listening — no manual `reset-chrome-for-recording.sh` step
needed:

```bash
# === ON OPERATOR WORKSTATION ===
bash scripts/agentkeys-init-email-demo.sh --session-id alice
bash scripts/agentkeys-provision-demo.sh  --session-id alice openrouter
```

[`scripts/agentkeys-provision-demo.sh`](../scripts/agentkeys-provision-demo.sh)
wraps what used to be an eight-step copy-paste block: it sources
`scripts/operator-workstation.env`, ensures Chrome is on `CDP_URL`
(launches via [`reset-chrome-for-recording.sh`](../scripts/reset-chrome-for-recording.sh)
if not), exports the broker URL / `agentkeys-data-role` ARN / signer
URL / `AGENTKEYS_SESSION_ID`, drops any stale AWS creds in the shell
(the CLI re-mints internally), then `exec`s
`agentkeys --session-id alice provision openrouter`. Override defaults
via env if needed (`AGENTKEYS_BROKER_URL`, `AGENTKEYS_DATA_ROLE_ARN`,
`AWS_REGION`, `CDP_URL`).

> **Credential storage backend (issue #85).** By default `provision`
> writes the freshly-minted API key to the legacy mock-server at
> `http://localhost:8090/credential/store` — fine only if you're running
> the mock-server on the same workstation (today's transition default).
> To land the key in the OIDC-scoped S3 vault instead — same path the
> SES routing Lambda already writes inbound mail through, no extra
> infra to provision — set:
>
> ```bash
> export AGENTKEYS_CREDENTIAL_BACKEND=s3
> export AGENTKEYS_BUCKET="$BUCKET"            # same value as cloud-setup.md
> export AGENTKEYS_SIGNER_URL=https://signer.litentry.org
> export AGENTKEYS_OMNI_ACCOUNT=<64hex>        # from /v1/auth/.../status
> ```
>
> The blob lands at
> `s3://$BUCKET/bots/<wallet>/credentials/openrouter.enc`, AES-256-GCM
> sealed under a per-(wallet, service) KEK derived via the signer's
> `/dev/sign-message`. The mock-server stays in the picture for the
> non-credential endpoints (`/session/*`, `/audit/*`, `/identity/*`)
> until those get their own swap-in target.

> **What "success" looks like vs scraper-DOM drift.** §5.3 demonstrates
> the auto-provision **pipeline** — session JWT → OIDC JWT → STS →
> env-var-injection. If openrouter's signup page DOM has drifted since
> the scraper was last updated, you'll see a `trip_wire_fired` log line
> with `"kind":"SelectorTimeout"` and the CLI exits with
> `A script step timed out at 'signup_flow'`. **That message is proof
> the pipeline worked** — the scraper subprocess only ran because the
> AWS creds were minted and injected. Scraper-maintenance (updating
> selectors when target sites change) is tracked separately in the
> per-service scraper file under
> [`provisioner-scripts/src/scrapers/`](../provisioner-scripts/src/scrapers/)
> — the openrouter scraper specifically is tracked in
> [issue #83](https://github.com/litentry/agentKeys/issues/83) (label:
> `provision-fix`). Out of scope for the §5.3 demo.

> **Why NOT `agentkeys-daemon --session $JWT`?** The daemon binary is
> an MCP host; without `--stdio` it starts, logs `daemon ready, session
> wallet=local` (the `wallet="local"` placeholder is from
> [`session.rs:6`](../crates/agentkeys-daemon/src/session.rs#L6) — the
> daemon doesn't decode the JWT body), and exits immediately. It never
> calls the provisioner on its own — that's MCP-tool-driven. Use the
> CLI subcommand above for an end-to-end run.

Inside the CLI, the call site is
[`crates/agentkeys-mcp/src/lib.rs`](../crates/agentkeys-mcp/src/lib.rs)::`broker_env_for_provision`
→ `fetch_via_broker_default_ttl` → `/v1/mint-oidc-jwt` →
`AssumeRoleWithWebIdentity` → env-var-injection into the scraper.

---

## 6. Capability grants (Phase B)

A grant is an explicit, `master_wallet`-issued authorization that the
daemon at `derived_address(actor_omni)` (arch.md §3a) can mint S3 creds
for `(service, scope_path)` until `expires_at`, up to `max_uses` times.
It's the cloud's fail-closed-by-default story.

### 6.1 Master creates a grant

```bash
# `daemon_address` is arch.md §3a `derived_address(actor_omni)`
# (= `$ADDR_A` in this demo's shell vars).
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
identity unlocks the same `derived_address(actor_omni)`" (arch.md §3a).
The daemon links its `identity_omni` (e.g. the email-derived omni used
at init time) to the post-SIWE `actor_omni` so re-authenticating as that
email recovers the same EVM address.

### 7.1 Master links the `identity_omni` to the `actor_omni`

```bash
curl -sS --fail-with-body -X POST $OIDC_ISSUER/v1/wallet/link \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H 'content-type: application/json' \
  -d "$(jq -n '{identity_type:"email", identity_value:"alice@demo.example"}')"
```

After this call the broker's `IdentityLinkStore` knows that
`("email", "alice@demo.example")` (= `identity_omni`) ↔ `$OMNI_EVM_A`
(= `actor_omni` from §2.3) ↔ `$ADDR_A` (= `derived_address(actor_omni)`).

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

Email-link is the canonical way to bootstrap `identity_omni` (arch.md
§3a) in a real deployment instead of computing it offline like §0.3
does. After verification, the broker mints a session JWT carrying
`identity_omni` (where `identity_type="email"`); the daemon then derives
`master_wallet = HKDF(K3, identity_omni)` via `/dev/derive-address`.
§2's SIWE rebinds the JWT to `actor_omni` from there.

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

# 4. The session JWT now carries `identity_omni` (arch.md §3a;
#    identity_type="email"). Derive `master_wallet`:
EMAIL_SESSION_JWT=...                # from step 3
agentkeys --session-id alice signer derive \
  --signer-url $BACKEND_URL \
  --omni-account $(omni email "alice@demo.example")
# 5. Then run §2.1 onwards — SIWE rebinds the JWT to `actor_omni` and
#    a second derive yields `derived_address(actor_omni)`.
```

§8 is a manual alternative to §2.0's one-command `agentkeys init
--email`. If you're driving it raw like this, persist the
`session_jwt` from step 3 into `~/.agentkeys/alice/session.json`
(matching `--session-id alice`) before running step 4 — or skip
step 4 entirely and inline the JWT as `Authorization: Bearer
$EMAIL_SESSION_JWT` against `$BACKEND_URL/dev/derive-address`.

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
agentkeys --session-id alice signer derive \
  --signer-url $BACKEND_URL \
  --omni-account $(omni oauth2_google "<google-sub>")
```

Same caveat as §8: §9 is a manual alternative to §2.0's
`agentkeys --session-id alice init --oauth2-google`. The shorthand
mints + persists the session JWT for you; the raw flow above needs
the step-3 JWT inlined as `Authorization: Bearer` or persisted into
`~/.agentkeys/alice/session.json` before step 4 reads it.

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
- `omni_account` — arch.md §3a `actor_omni` (= `$OMNI_EVM_A` post-SIWE).
  Post issue #74 the wallet (`master_wallet` or `derived_address`) is
  the public side; the bootstrap `identity_omni` stays on the daemon
  and never lands here.
- `wallet` — arch.md §3a `master_wallet` or `derived_address(actor_omni)`
  depending on which the OIDC JWT carried (see §0.4 "Which wallet
  ends up in AWS PrincipalTag").
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

### 12.2 Idempotency-Key (retired with `/v1/mint-aws-creds` in PR #96)

Server-side idempotency dedup lived in the now-deleted
`/v1/mint-aws-creds` handler. With the route gone (issue #72), no
broker route honors the `Idempotency-Key` header. The only cost-bounding
knob is `BROKER_OIDC_JWT_TTL_SECONDS` (default 300s) — every call to
`/v1/mint-oidc-jwt` re-signs and writes a fresh `mint_log` row, and
every call to `sts:AssumeRoleWithWebIdentity` is a fresh AWS API call
(no caching in the provisioner — see
[`crates/agentkeys-provisioner/src/aws_creds.rs::fetch_via_broker`](../crates/agentkeys-provisioner/src/aws_creds.rs#L128)
which fetches a fresh JWT and assumes a fresh role every invocation).
Callers that need batching, dedup, or rate-limiting must implement it
client-side.

`BROKER_REQUEST_BODY_LIMIT_BYTES` (default 1 MiB) still caps body size
at the router level for every endpoint.

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

### 14.4 SIWE verify returns `signature does not recover to claimed address` — OR `ADDRESS DRIFT — master secret rotated mid-session?` at end of §2.2

Both symptoms have the same family of causes — `$ADDR_A` (or `$OMNI_A`)
in your shell doesn't match the just-now-live alice/bob session. In
practice 9 out of 10 hits are **stale shell vars from a previous run**,
not actual K3 rotation.

Most common diagnosis path — run this triplet and compare:

```bash
echo "OMNI_A (shell)   = $OMNI_A"
echo "ADDR_A (shell)   = $ADDR_A"
DERIVE_NOW=$(agentkeys --json signer derive \
               --signer-url $BACKEND_URL --omni-account $OMNI_A | jq -r .address)
echo "derive(OMNI_A)   = $DERIVE_NOW   ← what signer returns RIGHT NOW"
JWT_OMNI=$(jq -r .token ~/.agentkeys/$AGENTKEYS_SESSION_ID/session.json \
            | cut -d. -f2 | tr '_-' '/+' \
            | { read p; printf '%s%s' "$p" "$(printf '====' | head -c $(( (4 - ${#p} % 4) % 4 )))" \
                | base64 -d 2>/dev/null; } | jq -r '.agentkeys.omni_account')
echo "JWT.omni_account = $JWT_OMNI    ← what's persisted on disk"
```

Then match against the failure mode:

| Symptom                                                    | Cause                                                                                                                       | Fix                                                                                                                                                                                                                                  |
|------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `OMNI_A` (shell) `!=` `JWT.omni_account` (on disk)         | Shell `$OMNI_A` is stale — set by a previous `--export` against a different session. Re-init happened after `--export`.     | Re-run `eval "$(bash scripts/agentkeys-demo-show.sh --export A $AGENTKEYS_SESSION_ID)"`. Then re-do §2.1 (SIWE start) — your old `$SIWE_MSG` is also stale because it embeds the old `$ADDR_A`.                                       |
| `DERIVE_NOW != ADDR_A` (shell)                             | Shell `$ADDR_A` is stale — same root cause as above.                                                                        | Same fix.                                                                                                                                                                                                                            |
| `ADDR_A == MASTER_WALLET_A` (= JWT.wallet_address)         | You substituted `$MASTER_WALLET_A` for `$ADDR_A` somewhere — easy mistake reading demo-show's human-mode output.            | Re-run the eval line; `--export A` is the only mode that reliably sets `$ADDR_A = HKDF(K3, OMNI_A)`.                                                                                                                                  |
| `DERIVE_NOW != SIG_ADDR` (where `SIG_ADDR` = §2.2's check) | Real K3 rotation — `setup-broker-host.sh` regenerated `/etc/agentkeys/dev-key-service.env`, or `agentkeys-backend` restarted with a new `DEV_KEY_SERVICE_MASTER_SECRET`. | All previously-derived wallets are invalidated. Re-init via `init-email-demo.sh --session-id alice`, re-export, restart from §2.1. To keep K3 stable across runs, the setup script preserves the env file — only `--force` rotates it. |
| SIWE message bytes mutated mid-flow                        | `$SIWE_MSG` was re-quoted or re-printed (zsh `echo` corrupts `\n` escapes — see §0 the printf note).                       | Always pass `$SIWE_MSG` straight from `printf '%s' "$START" \| jq -r .siwe_message`. Never `echo "$SIWE_MSG"` into the sign call.                                                                                                    |

The two stale-shell-vars rows are by far the most common when an
operator runs `init-email-demo.sh --session-id alice` twice in a row,
or runs it after a previous `--export A bob`. **Run the eval line every
time a fresh init lands** — it's idempotent and cheap.

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

### 14.8 `agentkeys signer sign` returns `Error: SIGNER_UNAUTHORIZED  invalid session JWT: ExpiredSignature`

The CLI's `--session-id` flag defaults to `master`. If you ran
`bash scripts/agentkeys-init-email-demo.sh --session-id alice` (which
writes `~/.agentkeys/alice/session.json`) but then called
`agentkeys signer sign …` without threading the session-id, the CLI
read `~/.agentkeys/master/session.json` instead — almost certainly an
older session whose JWT has since expired.

Diagnose:

```bash
# Confirm which file the CLI would read by default (master) vs. the one
# init-email-demo.sh just wrote (alice).
ls -la ~/.agentkeys/master/session.json ~/.agentkeys/alice/session.json
# Decode the JWT exp claim from each; the older one is what the bare
# `agentkeys signer sign` was using.
for f in ~/.agentkeys/{master,alice}/session.json; do
  echo "=== $f ==="
  payload="$(jq -r '.token' "$f" | awk -F. '{print $2}')"
  pad=$(( (4 - ${#payload} % 4) % 4 ))
  printf '%s' "$payload$(printf '=%.0s' $(seq 1 $pad))" | tr '_-' '/+' \
    | base64 -d 2>/dev/null | jq '{exp_iso: (.exp | todate)}'
done
```

Fix — pin the right session for the rest of this shell:

```bash
export AGENTKEYS_SESSION_ID=alice    # or whatever --session-id you initted
```

This matches the same pattern §0.4 and §2.4 use. The bare per-call
alternative is `agentkeys --session-id alice signer sign …` but the
env-var sticks across §2 + §4, which is what the demo assumes.

If `alice`'s JWT is also expired (init was >5h ago), re-run
`bash scripts/agentkeys-init-email-demo.sh --session-id alice` to mint
a fresh one. `ttl_seconds` is 18000 (5h) by default.

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
- **Retire `/v1/mint-aws-creds` entirely.** ✅ Done in PR #96 (issue
  #72). The provisioner / MCP / daemon use `/v1/mint-oidc-jwt` +
  client-side `AssumeRoleWithWebIdentity` (issue #71 Option A); the
  legacy server-side aggregator route was deleted along with its
  handler (`handlers/mint.rs`) and tests (`tests/mint_v2_flow.rs`).
  The route now returns 404. Server-side gates dropped with the
  route: Phase B `try_consume` grants, Idempotency-Key dedup, and
  multi-anchor audit coordination. Isolation now rides on
  `/v1/mint-oidc-jwt`'s audit row + AWS CloudTrail + PrincipalTag/bucket
  policy per `arch.md §17.2`.
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

# Make sure follow-up `agentkeys signer sign` calls read the session
# this section initted (not the default `master`, which is usually
# stale — see §14.8).
export AGENTKEYS_SESSION_ID=alice
```

Compute omnis + derive wallets + run SIWE round-trip — exactly §0.3
through §2.4 above, just with `$OIDC_ISSUER=https://broker.litentry.org`
and `$BACKEND_URL=https://signer.litentry.org`. No tunnel; the signer
listener is fronted by nginx with TLS (issued via certbot per §0.2).

```bash
# `omni()` computes arch.md §3a `actor_omni` for the EVM identity-type
# (after SIWE), and `identity_omni` for the email identity-type (before
# SIWE). Here we use it for `actor_omni` directly — short-circuiting
# §0.3's bootstrap. `$ADDR_A` / `$ADDR_B` = `derived_address(actor_omni)`.
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

# Decode the wallet the JWT actually carries — same pattern as §3.
# This is the prefix AWS will let the assumed role read. Don't assume
# `$ADDR_A` (only correct under §16.4's manual SIWE path).
decode_aws_wallet() {
  echo "$1" | cut -d. -f2 | tr '_-' '/+' \
    | python3 -c "import base64,sys; s=sys.stdin.read().strip(); print(base64.urlsafe_b64decode(s+'='*(-len(s)%4)).decode())" \
    | jq -r .agentkeys_user_wallet
}
WALLET_A=$(decode_aws_wallet "$JWT")
[[ "$WALLET_A" =~ ^0x[0-9a-f]{40}$ ]] || { echo "ERROR: decoded WALLET_A=$WALLET_A not a 0x-address"; return 1 2>/dev/null || exit 1; }
echo "WALLET_A=$WALLET_A   (the prefix bot/<WALLET_A>/ is what alice can read)"

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

# Alice's prefix — SUCCESS. (`$WALLET_A` decoded from JWT in §16.5;
#  arch.md §3a canonical: whichever of `master_wallet` or
#  `derived_address(actor_omni)` ended up in `agentkeys_user_wallet`.)
aws s3api list-objects-v2 --bucket "$BUCKET" \
  --prefix "bots/${WALLET_A}/" --query 'Contents[*].Key'

# A peer wallet — AccessDenied (cloud-enforced). `$ADDR_B` is bob's
# `derived_address(actor_omni)` from §16.4; any wallet ≠ `$WALLET_A`
# triggers the same deny.
aws s3api get-object --region "$REGION" --bucket "$BUCKET" \
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

# Bootstrap the alice session via the new flow. The CLI prompts you
# to click the magic link; once verified, it derives + links + SIWEs
# and saves the EVM session JWT under ~/.agentkeys/alice/session.json
# (or the OS keychain). --session-id alice keeps this isolated from
# any prior `master` session.
agentkeys --session-id alice init \
  --email alice@demo.example \
  --broker-url $AGENTKEYS_BROKER_URL \
  --signer-url $AGENTKEYS_SIGNER_URL

# Pin the alice session for the provisioner subprocess too — without
# this, the provisioner falls back to --session-id master and reads
# whatever stale JWT lives there (see §14.8).
export AGENTKEYS_SESSION_ID=alice

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
  --session-id alice \
  --backend $BACKEND_URL \
  --broker-url $AGENTKEYS_BROKER_URL \
  --signer-url $AGENTKEYS_SIGNER_URL \
  --init-email alice@demo.example \
  --stdio
# agentkeys-daemon: bootstrapping via email-link for alice@demo.example; click the magic link in your inbox
# (operator clicks the magic link in their inbox)
# (daemon then enters MCP-stdio loop)
```

The daemon's `--session-id` mirrors the CLI's: it pins which
`~/.agentkeys/<id>/session.json` the long-running process reads + writes.
Omitting it falls back to a `daemon-<ulid>` auto-discovered fallback
(see `agentkeys-daemon --help`) — fine for the very-first run on a
clean machine, but explicit `--session-id alice` keeps the daemon
session aligned with the CLI tenant for the operator-tracing case.

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

After the OIDC-only migration (issue #71) + `/v1/mint-aws-creds`
retirement (issue #72 / PR #96), the daemon-side STS call is invisible
to the broker's audit log — the broker only sees `/v1/mint-oidc-jwt`
calls. The full audit chain is:

- `/v1/mint-oidc-jwt` writes the JWT-mint row to
  `~/.agentkeys/broker/audit.sqlite` (`mint_log` table) via
  `state.audit.record_mint(...)`.
- AWS CloudTrail's `AssumeRoleWithWebIdentity` events capture the
  actual STS exchange, with the role + session name as named in §5.1.

There is no longer a "server-side audit row of the actual mint" — the
mint IS the daemon's STS call, and that's audited by AWS, not the
broker.

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
