# Stage 7 — Pluggable Broker: Complete Demo & Verification Guide

This guide is the operator-facing companion to
[`docs/spec/plans/issue-64/PHASE-0-CHECKPOINT.md`](spec/plans/issue-64/PHASE-0-CHECKPOINT.md).
That checkpoint covered Phase 0 in isolation against `localhost`. **This
guide is the end-to-end production demo** for the full Stage 7 pluggable
broker (Phase 0 + A.1 + A.2 + B + C-structural + D-rest + E) running on
a real EC2 broker host with the AWS account from
[`cloud-setup.md`](cloud-setup.md).

When you finish this guide you will have:

1. Confirmed the broker process boots cleanly past Tier-1 + Tier-2.
2. Verified AWS IAM accepts the broker's OIDC discovery + JWKS.
3. Walked the SIWE wallet auth flow end-to-end with a real EIP-191 wallet.
4. Minted real AWS STS credentials via `/v1/mint-aws-creds`.
5. **Proven cloud-enforced per-user isolation** — wallet A reads its own
   prefix; wallet B's prefix returns `AccessDenied` from S3 itself, not
   from app code.
6. Inspected the audit log + metrics + idempotency cache.
7. Exercised capability grants and wallet recovery.

The guide assumes Stage 7 is the build deployed (the broker's
`/.well-known/openid-configuration` advertises the new auth endpoints).
If you're on a pre-Stage-7 build, run
`scripts/setup-broker-host.sh --upgrade` first and come back.

---

## Two-machine layout

Most steps below run on one of two machines. Each step is tagged with an
inline `# === ON … ===` banner.

| Machine | What it has | Used for |
|---|---|---|
| **Operator workstation** | `awsp agentkeys-admin` profile, `$ACCOUNT_ID` / `$BROKER_HOST` / `$BUCKET` shell vars from `cloud-setup.md §0`, `cast` (Foundry) / wallet, `aws` CLI | AWS-side checks, `aws sts assume-role-with-web-identity`, S3 isolation proof, signing SIWE messages with a private key |
| **Broker host (EC2)** | `agentkeys-broker-server` binary at `/usr/local/bin/`, both ES256 keypairs at `/var/lib/agentkeys/.agentkeys/broker/`, systemd service `agentkeys-broker.service`, mock backend at loopback `:8090`, nginx fronting `:8091` with TLS at `https://$BROKER_HOST` | Broker process, audit DB, JWT minting |

Hop between them with `ssh agentkey@$BROKER_HOST` (the workstation
expands `$BROKER_HOST` before `ssh` runs; the broker host has no
workstation env vars).

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

The file is committed with public values (account ID, role/bucket
names, hostname). If you fork the repo for a different deployment,
edit it in place — there's no template version.

Cloud-side state from `cloud-setup.md`:

- `cloud-setup.md §0` — env vars, awsp profile.
- `cloud-setup.md §1` — DNS A record for `$BROKER_HOST`.
- `cloud-setup.md §3` — `agentkeys-{admin,broker,daemon}` IAM users +
  `agentkeys-data-role` + `agentkeys-mail-*` S3 bucket.
- `cloud-setup.md §4` — OIDC provider registered for `$OIDC_ISSUER`,
  `agentkeys-data-role` trust policy swapped to OIDC-federated form,
  S3 bucket policy upgraded to PrincipalTag-scoped.

Broker-host state (from
[`scripts/setup-broker-host.sh`](../scripts/setup-broker-host.sh)):

- `agentkeys-broker.service` and `agentkeys-backend.service` enabled
  and active.
- `/usr/local/bin/agentkeys-broker-server` matches the binary built
  from this branch.
- nginx (or ALB) fronting `:8091` at `https://$BROKER_HOST` with a
  valid TLS cert.

Tooling on the workstation:

- `aws` CLI v2.
- `jq` (JSON parsing).
- `cast` from Foundry (signing SIWE messages with a private key).
  `curl https://foundry.paradigm.xyz | bash && foundryup`.
- A test EVM keypair. Generate two for the isolation proof:

  ```bash
  cast wallet new --json | tee /tmp/wallet-A.json
  cast wallet new --json | tee /tmp/wallet-B.json
  PK_A=$(jq -r .private_key /tmp/wallet-A.json)
  PK_B=$(jq -r .private_key /tmp/wallet-B.json)
  ADDR_A=$(jq -r .address    /tmp/wallet-A.json)
  ADDR_B=$(jq -r .address    /tmp/wallet-B.json)
  echo "A=$ADDR_A  B=$ADDR_B"
  ```

> The keys never need on-chain funds — Stage 7's SIWE auth is
> off-chain signing only. They only need to be EIP-191-capable.

---

## 1. Verify the broker is up

```bash
# === ON OPERATOR WORKSTATION ===
curl -sf $OIDC_ISSUER/healthz && echo
# ok

curl -s $OIDC_ISSUER/readyz | jq
# {"status":"ready"}            ← all Tier-2 probes green
# OR
# {"status":"unready","checks":[{"name":"backend","status":"unready",
#  "docs":"docs/operator-runbook-stage7.md#backend-reachability"}]}
```

If `/readyz` returns `unready`, paste the `docs:` URL into the
[operator runbook](operator-runbook-stage7.md) — every check has its
own anchor with the recovery procedure.

```bash
curl -sf $OIDC_ISSUER/.well-known/openid-configuration | jq
# {
#   "issuer": "https://broker.litentry.org",
#   "jwks_uri": "https://broker.litentry.org/.well-known/jwks.json",
#   "id_token_signing_alg_values_supported": ["ES256"],
#   ...
# }

curl -sf $OIDC_ISSUER/.well-known/jwks.json | jq '.keys[0]'
# {
#   "kty": "EC",
#   "crv": "P-256",
#   "x": "<43-char base64url>",
#   "y": "<43-char base64url>",
#   "kid": "v1-<unix-seconds>",
#   "alg": "ES256",
#   "use": "sig"
# }
```

**Critical invariant:** `issuer` in the discovery doc MUST equal
`$OIDC_ISSUER` byte-for-byte. AWS IAM compares the JWT `iss` claim
against the registered OIDC provider URL exactly — trailing slash, host,
scheme, path all matter. If they don't match, every
`AssumeRoleWithWebIdentity` will return `InvalidIdentityToken`.

```bash
[[ "$(curl -sf $OIDC_ISSUER/.well-known/openid-configuration | jq -r .issuer)" \
   == "$OIDC_ISSUER" ]] && echo "issuer match" || echo "ISSUER MISMATCH — see runbook §oidc-issuer"
```

Verify from AWS IAM's perspective:

```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn $OIDC_PROVIDER_ARN \
  --query '{Url:Url, ClientIDList:ClientIDList, Thumbprints:ThumbprintList}'
# {
#   "Url": "broker.litentry.org",            ← AWS strips the https://
#   "ClientIDList": ["sts.amazonaws.com"],
#   "Thumbprints": ["<40 hex>"]
# }
```

---

## 2. SIWE wallet auth round-trip

### 2.1 Request a SIWE challenge

```bash
# === ON OPERATOR WORKSTATION ===
START=$(curl -sf -X POST $OIDC_ISSUER/v1/auth/wallet/start \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg a "$ADDR_A" '{address:$a, chain_id:84532}')")

echo "$START" | jq
# {
#   "request_id": "siwe-<ulid>",
#   "siwe_message": "broker.litentry.org wants you to sign in…",
#   "nonce": "<32 hex>",
#   "expires_in_seconds": 2700,
#   "expires_at_iso": "2026-05-08T15:22:11Z"
# }

REQ_ID=$(echo "$START" | jq -r .request_id)
SIWE_MSG=$(echo "$START" | jq -r .siwe_message)
```

The SIWE message is constructed per EIP-4361 with the broker's
`$BROKER_HOST` as the domain field. The signature you produce next has
the EIP-191 `\x19Ethereum Signed Message:\n<len>` prefix wrapped around
this exact text — re-deriving any whitespace differently breaks
verification.

### 2.2 Sign the SIWE message

`cast wallet sign` does the EIP-191 wrap automatically when called
without `--no-hash`. The `--no-hash` flag means "the bytes ARE the
EIP-191 envelope already, just sign them" — which is **not** what we
want here.

```bash
SIG_A=$(cast wallet sign --private-key $PK_A "$SIWE_MSG")
echo "SIG_A=$SIG_A"
# SIG_A=0x<130-hex-chars>
```

### 2.3 Submit the signature, get back a session JWT

```bash
VERIFY=$(curl -sf -X POST $OIDC_ISSUER/v1/auth/wallet/verify \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg r "$REQ_ID" --arg s "$SIG_A" \
        '{request_id:$r, signature:$s}')")

echo "$VERIFY" | jq
# {
#   "session_jwt": "eyJ…",
#   "session_jwt_kid": "ak-session-<unix>",
#   "expires_at": 1762345678,
#   "omni_account": "<64 hex>",
#   "wallet_address": "0x…",
#   "identity_type": "evm",
#   "identity_value": "0x…"
# }

SESSION_JWT_A=$(echo "$VERIFY" | jq -r .session_jwt)
OMNI_A=$(echo "$VERIFY" | jq -r .omni_account)
```

The `omni_account` is `SHA256("agentkeys" || "evm" || lower(wallet))`
— deterministic from the wallet address, namespace-isolated from any
other identity provider, never reused across wallet rotations. If
you decode `$SESSION_JWT_A` (`echo $SESSION_JWT_A | cut -d. -f2 | base64
-d`) you'll see `omni_account`, `wallet`, `iss`, `iat`, `exp` claims and
a `kid` in the header pointing at the session keypair.

> **Session JWT is broker-internal.** It is signed by the *session*
> keypair (`purpose=session`), not the OIDC keypair. AWS IAM never
> sees it. Plan §3.5.6 keeps the two keypairs separate so a stolen
> session JWT can't impersonate the broker to AWS, and a stolen OIDC
> JWT can't be replayed as a session token.

### 2.4 Repeat for wallet B

```bash
START_B=$(curl -sf -X POST $OIDC_ISSUER/v1/auth/wallet/start \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg a "$ADDR_B" '{address:$a, chain_id:84532}')")

REQ_ID_B=$(echo "$START_B" | jq -r .request_id)
SIWE_MSG_B=$(echo "$START_B" | jq -r .siwe_message)
SIG_B=$(cast wallet sign --private-key $PK_B "$SIWE_MSG_B")

VERIFY_B=$(curl -sf -X POST $OIDC_ISSUER/v1/auth/wallet/verify \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg r "$REQ_ID_B" --arg s "$SIG_B" \
        '{request_id:$r, signature:$s}')")

SESSION_JWT_B=$(echo "$VERIFY_B" | jq -r .session_jwt)
OMNI_B=$(echo "$VERIFY_B" | jq -r .omni_account)
echo "OMNI_A=$OMNI_A"
echo "OMNI_B=$OMNI_B"
```

`OMNI_A` ≠ `OMNI_B` — confirmed by hash function.

---

## 3. Mint OIDC JWT for STS

The session JWT is broker-internal. To talk to AWS STS you need a
separate OIDC JWT signed by the OIDC keypair, with claims AWS knows how
to consume.

```bash
JWT_A=$(curl -sf -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq -r .jwt)

echo "$JWT_A"
# eyJ… (header.payload.signature)

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
JWT_A, then attempt to read both wallet A's prefix (allowed) and wallet
B's prefix (denied **by AWS, not by app code**).

### 4.1 Assume the role with JWT_A

```bash
# === ON OPERATOR WORKSTATION ===
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role \
  --role-session-name "demo-A-$(date +%s)" \
  --web-identity-token "$JWT_A")

echo "$CREDS" | jq '.Credentials | {AKID:.AccessKeyId, Exp:.Expiration}'

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

# Confirm: you are NOT your admin profile any more.
aws sts get-caller-identity
# {
#   "UserId": "AROA…<role-id>:demo-A-…",
#   "Arn": "arn:aws:sts::ACCOUNT:assumed-role/agentkeys-data-role/demo-A-…"
# }
```

### 4.2 Seed test objects (one-shot, with admin creds)

If wallet A's prefix is empty, the read in step 4.3 succeeds vacuously
and proves nothing. Pop two objects in (one per wallet) using your
admin profile — clear out the assumed-role env first.

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
awsp agentkeys-admin

WALLET_A_LC=$(echo "$ADDR_A" | tr '[:upper:]' '[:lower:]')
WALLET_B_LC=$(echo "$ADDR_B" | tr '[:upper:]' '[:lower:]')
aws s3api put-object --bucket "$BUCKET" \
  --key "bots/${WALLET_A_LC}/hello.txt" --body /dev/null
aws s3api put-object --bucket "$BUCKET" \
  --key "bots/${WALLET_B_LC}/hello.txt" --body /dev/null
```

### 4.3 Re-export the assumed-role creds and probe both prefixes

```bash
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

# 4a — your own prefix: SUCCESS
aws s3api list-objects-v2 --bucket "$BUCKET" \
  --prefix "bots/${WALLET_A_LC}/" --query 'Contents[*].Key'
# [ "bots/0x…<A>/hello.txt" ]

aws s3api get-object --bucket "$BUCKET" \
  --key "bots/${WALLET_A_LC}/hello.txt" /tmp/got-A.txt
# { "ContentLength": 0, ... }

# 4b — the OTHER wallet's prefix: AccessDenied (CLOUD-ENFORCED)
aws s3api get-object --bucket "$BUCKET" \
  --key "bots/${WALLET_B_LC}/hello.txt" /tmp/got-B.txt
# An error occurred (AccessDenied) when calling the GetObject operation:
# Access Denied
```

**Step 4b is the property the static-IAM path cannot prove.** No app
code participated in the deny — S3's policy engine evaluated
`${aws:PrincipalTag/agentkeys_user_wallet}` (which is `WALLET_A_LC`)
against the resource ARN's `bots/${WALLET_B_LC}/` and refused.

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
JWT=$(curl -sf -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq -r .jwt)

# 2. Exchange it for AWS creds CLIENT-SIDE. No broker creds participate.
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role \
  --role-session-name "demo-A-$(date +%s)" \
  --web-identity-token "$JWT")
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

# 3. Use the temp creds. PrincipalTag-scoped per cloud-setup.md §4.4.
aws s3 ls "s3://$BUCKET/bots/$(echo $ADDR_A | tr A-Z a-z)/"
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
curl -sf -X POST $OIDC_ISSUER/v1/mint-aws-creds \
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
  --session $YOUR_SESSION_TOKEN
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
GRANT=$(curl -sf -X POST $OIDC_ISSUER/v1/grant/create \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H 'content-type: application/json' \
  -d "$(jq -n --arg d "$ADDR_A" '{
        daemon_address: $d,
        service:        "s3",
        scope_path:     "bots/",
        expires_at:     (now + 3600 | floor),
        max_uses:       100
      }')")

echo "$GRANT" | jq
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
curl -sf $OIDC_ISSUER/v1/grant/list \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq '.grants[0]'
```

### 6.3 Master revokes a grant

```bash
GRANT_ID=$(echo "$GRANT" | jq -r .grant_id)
curl -sf -X POST $OIDC_ISSUER/v1/grant/revoke \
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

### 7.1 Master links a secondary identity (e.g. email)

```bash
curl -sf -X POST $OIDC_ISSUER/v1/wallet/link \
  -H "Authorization: Bearer $SESSION_JWT_A" \
  -H 'content-type: application/json' \
  -d "$(jq -n '{identity_type:"email", identity_value:"hanwen@example.com"}')"
```

### 7.2 List linked identities

```bash
curl -sf $OIDC_ISSUER/v1/wallet/links \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq
```

### 7.3 Recover lookup (intentionally unauthenticated)

```bash
curl -sf -X POST $OIDC_ISSUER/v1/wallet/recover/lookup \
  -H 'content-type: application/json' \
  -d '{"identity_type":"email","identity_value":"hanwen@example.com"}' | jq
# {"omni_account": "<64 hex>"}
```

The lookup is unauthenticated *by design* — `omni_account` is a
SHA256 hash, discovery does not enable impersonation. Actual recovery
still requires the master to sign in fresh and call `/v1/grant/create`
on a new daemon address. See [operator-runbook-stage7.md → Recovery
flow](operator-runbook-stage7.md#recovery-flow).

---

## 8. Email-link auth (Phase A.1)

Requires `BROKER_AUTH_METHODS=…,email_link` and `BROKER_EMAIL_*` env
vars set (see runbook). SES sender identity must be verified.

```bash
# 1. Request a magic link.
curl -sf -X POST $OIDC_ISSUER/v1/auth/email/request \
  -H 'content-type: application/json' \
  -d '{"email":"hanwen@example.com"}'
# {"request_id":"em_…","status":"sent"}

# 2. Click the link in the email. The broker's /auth/email/landing
#    page completes the verify; the CLI poll surfaces the session JWT.

# 3. Poll for the result.
curl -sf $OIDC_ISSUER/v1/auth/email/status/em_… | jq
# {
#   "status": "verified",
#   "session_jwt": "eyJ…",
#   "omni_account": "<64 hex>",
#   "identity_type": "email",
#   "identity_value": "hanwen@example.com"
# }
```

### 8.1 Debugging — inspecting the inbound email at S3

If the magic-link click never completes verification, the email
probably arrived but the link the broker rendered doesn't match the
URL pattern the auth handler regex-matches. Use
[`scripts/inspect-inbound-email.sh`](../scripts/inspect-inbound-email.sh)
to dump the most-recent inbound email from `s3://$BUCKET/inbound/`
with the same quoted-printable normalization the broker applies:

```bash
# === ON OPERATOR WORKSTATION ===
awsp agentkeys-admin
set -a; source scripts/operator-workstation.env; set +a   # if not done in §0

./scripts/inspect-inbound-email.sh                # latest
./scripts/inspect-inbound-email.sh --all          # list all keys + headers
./scripts/inspect-inbound-email.sh inbound/<key>  # specific key
```

The script prints raw + normalized bodies, all `href`s, all
`https://` URLs deduped, and specifically the URLs that match the
auth handler's regex. If the last block returns `(NONE — regex would
miss this email!)`, the broker's URL-extraction regex needs an
update for the new sender format. (This script is the Stage 7
replacement for the archived `stage6-inspect-email.sh`.)

The session JWT NEVER appears in the browser-facing landing-page
response — only on the CLI poll, per Plan §3.5.4 security posture.

---

## 9. OAuth2/Google auth (Phase A.2)

Requires `BROKER_OAUTH2_*` env vars, a Google Cloud Console OAuth web
client, and the broker's redirect URI registered exactly. See
[operator-runbook-stage7.md → OAuth2 Setup](operator-runbook-stage7.md#oauth2-setup).

```bash
# 1. Initiate.
curl -sf -X POST $OIDC_ISSUER/v1/auth/oauth2/start \
  -H 'content-type: application/json' \
  -d '{"provider":"google"}' | jq
# {
#   "request_id":"oa2-…",
#   "authorization_url":"https://accounts.google.com/o/oauth2/v2/auth?…",
#   "poll_url":"/v1/auth/oauth2/status/oa2-…"
# }

# 2. Open authorization_url in a browser, sign in. Google redirects
#    to /auth/oauth2/callback on the broker.

# 3. Poll.
curl -sf $OIDC_ISSUER/v1/auth/oauth2/status/oa2-… | jq
# {"status":"verified", "session_jwt":"eyJ…", "omni_account":"…",
#  "identity_type":"oauth2_google", "identity_value":"<google-sub>"}
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
- `status` — `confirmed` after `sqlite_primary` or `sqlite`-only
  policy completes; `pending` → `confirmed | quarantined` for
  `dual_strict` policy (Phase C).
- `outcome` — `success` for granted mints; `denied` for grant
  failures (still audited).
- `grant_id` — non-empty when the mint was authorized by an explicit
  grant; empty during the Phase-0→B migration window.

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
# Set Phase C env vars (see runbook §EVM Audit Anchor).
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
curl -sf https://broker.litentry.org/readyz | jq
# .checks[] for evm_testnet appears; status=Ready or Unready depending
# on whether the stub's ChainId probe succeeded.
```

The harness invariants in `harness/stage-7-issue-64-phaseC-smoke.sh`
exercise this end-to-end against the stub.

---

## 12. Metrics + idempotency (Phase D-rest)

### 12.1 Prometheus metrics

```bash
# === ON BROKER HOST (or curl from anywhere if exposed) ===
sudo systemctl edit agentkeys-broker
# Environment=BROKER_METRICS_ENABLED=true
sudo systemctl restart agentkeys-broker

curl -sf https://broker.litentry.org/metrics | head -30
# # HELP agentkeys_broker_mints_total …
# # TYPE agentkeys_broker_mints_total counter
# agentkeys_broker_mints_total 14
# agentkeys_broker_mints_failed_total 0
# agentkeys_broker_audit_writes_total 14
# agentkeys_broker_audit_writes_failed_total 0
# agentkeys_broker_auth_attempts_total 23
# agentkeys_broker_auth_failed_unauthorized_total 1
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
v0-testnet feature combos). Exits 0 if Stage 7 is shippable. Any
failure prints the failing phase name and points at the relevant
sub-script.

---

## 14. Failure-mode walk-through

### 14.1 BOOT_FAIL on first start

Tier-1 refuse-to-boot prints a single-line `BOOT_FAIL: <var>=<value>:
<reason>; see runbook §<anchor>` to stderr. The anchor is a Markdown
heading slug in [`docs/operator-runbook-stage7.md`](operator-runbook-stage7.md).
Common ones:

| Anchor | Cause | Fix |
|---|---|---|
| `oidc-issuer` | `BROKER_OIDC_ISSUER` is `http://` and `BROKER_DEV_MODE` is unset | Set TLS in front of the broker, point issuer at the public HTTPS URL. |
| `oidc-keypair` / `session-keypair` | Keypair file missing | `agentkeys-broker-server keygen --purpose <oidc\|session> --out PATH` (commit `d9bf541`); or rerun `setup-broker-host.sh --upgrade` which auto-mints (commit `765ea9b`). |
| `audit-policy` | Bad `BROKER_AUDIT_POLICY` value | Must be `dual_strict` / `sqlite_primary` / `evm_primary`. |
| `auth-method-not-compiled` | Plugin name in env var not registered | Rebuild with the matching `--features` flag (e.g. `auth-email-link`) or remove the name. |
| `auth-method-empty` / `audit-anchor-empty` | Empty list | Defaults: `wallet_sig` / `sqlite`. |
| `backend-reachability` | Tier-2 backend `/healthz` not yet probed | Auto-clears once mock-server is up. With `BROKER_REFUSE_TO_BOOT_STRICT=true`, this is a hard fail instead. |

### 14.2 `AssumeRoleWithWebIdentity` returns InvalidIdentityToken

- **Issuer mismatch.** Confirm `discovery.issuer == $OIDC_ISSUER`
  byte-for-byte.
- **JWKS unreachable.** Confirm AWS can fetch
  `${OIDC_ISSUER}/.well-known/jwks.json` over the public internet.
- **Audience mismatch.** AWS expects `aud=sts.amazonaws.com`. Decode
  the JWT and confirm.
- **Stale OIDC provider.** If the broker's `kid` rotated and AWS
  cached the old JWKS, re-register the provider:
  `aws iam delete-open-id-connect-provider …` then re-create per
  `cloud-setup.md §4.2`.

### 14.3 S3 GetObject returns AccessDenied for own prefix

The JWT isn't carrying the `https://aws.amazon.com/tags` claim. Decode
and check (per §4.4 above). If the claim is present, confirm the role's
trust policy has `sts:TagSession` and the `aws:RequestTag/...`
condition (per `cloud-setup.md §4.3`).

### 14.4 Broker exits 0 cleanly after ~24h

Designed behavior — the broker has a 24h max-uptime serve loop. The
systemd unit ships with `Restart=always` (commit
[`c21c255`](https://github.com/litentry/agentKeys/commit/c21c255)) so
systemd restarts it automatically. Verify with
`sudo journalctl -u agentkeys-broker --since "1 day ago" | grep -E "max-uptime|listening"`.

---

## 15. What's intentionally not yet live

These ship behind their own user-stories or hardening passes; the
structural plumbing is in place but the live integration isn't wired:

- **Live EVM audit anchor.** The `EvmStubAnchor` round-trips without
  network. Real transaction submission + receipt polling lands in
  Phase E hardening (V0.1-FOLLOWUPS).
- **TEE-derived OIDC signer.** The on-disk ES256 keypair is the v0.1
  signer. Plan §8 (TEE) replaces it without changing JWKS/JWT/STS shape.
- **`BROKER_REQUIRE_EXPLICIT_GRANT=true` default-on.** Today the
  Phase-0 NoGrant migration window is open; flip the default once
  every daemon has been issued a grant.
- **Histogram metrics + per-handler counter bumps.** Counter shapes
  ship; latency histograms land in V0.1-FOLLOWUPS.
- **Retire `/v1/mint-aws-creds` entirely (issue #71 Option A
  closing step).** Provisioner / MCP / daemon now use
  `/v1/mint-oidc-jwt` + client-side `AssumeRoleWithWebIdentity`
  (landed in this guide's commit set). The endpoint stays for callers
  who want server-side gates (audit + grants + idempotency); once
  every operator's pipeline confirms the new path works in
  production, the route can be dropped.

See [`docs/spec/plans/issue-64/V0.1-FOLLOWUPS.md`](spec/plans/issue-64/V0.1-FOLLOWUPS.md)
for the prioritized backlog.

---

## 16. Live walkthrough on broker.litentry.org

This section is the copy-paste runbook for verifying the migration
end-to-end against the **live** broker at `https://broker.litentry.org`.
Each block is tagged with where it runs.

### 16.1 Pull + redeploy on the broker host

```bash
# === ON BROKER HOST (ip-172-31-29-135 via SSH) ===
ssh agentkey@broker.litentry.org
cd ~/agentKeys
git fetch origin
git checkout evm
git pull --ff-only

# Redeploy via the systemd-aware upgrade script. After the OIDC-only
# migration the broker no longer needs DAEMON_ACCESS_KEY_ID env vars;
# the systemd unit can run with no AWS creds.
sudo bash scripts/setup-broker-host.sh --upgrade

# Verify the broker is up.
sudo systemctl --no-pager status agentkeys-broker
sudo journalctl -u agentkeys-broker -n 50 --no-pager
```

### 16.2 Verify broker is creds-free

```bash
# === ON BROKER HOST ===
sudo systemctl show agentkeys-broker | grep -E "^Environment=" | tr ' ' '\n' \
  | grep -E "AWS_|DAEMON_|BROKER_DAEMON_" || echo "OK: no AWS_* / DAEMON_* env vars"
```

The expected output is `OK: no AWS_* / DAEMON_* env vars`. If the
unit still has `Environment=AWS_PROFILE=...` from a pre-migration
deployment, drop the line and `sudo systemctl daemon-reload &&
sudo systemctl restart agentkeys-broker`.

### 16.3 Public health checks (no creds needed)

```bash
# === ON OPERATOR WORKSTATION ===
curl -sf https://broker.litentry.org/healthz
# ok

curl -sf https://broker.litentry.org/readyz | jq
# {"status":"ready"}

curl -sf https://broker.litentry.org/.well-known/openid-configuration | jq -r .issuer
# https://broker.litentry.org

curl -sf https://broker.litentry.org/.well-known/jwks.json | jq '.keys[0] | {kty, crv, alg, kid}'
# {"kty":"EC","crv":"P-256","alg":"ES256","kid":"v1-…"}
```

### 16.4 SIWE wallet auth → session JWT

Generate two test wallets, sign in as wallet A, capture session JWT.
Same as §2 above against the live broker. Repeat for wallet B if you
want to demo the isolation property in §16.6.

### 16.5 Mint OIDC JWT + AssumeRoleWithWebIdentity (the new auto-provision path)

```bash
# === ON OPERATOR WORKSTATION ===
# (Assumes operator-workstation.env was sourced in §0 — $OIDC_ISSUER,
# $DATA_ROLE_ARN, $ACCOUNT_ID are already set.)
awsp agentkeys-admin

# Get the OIDC JWT.
JWT=$(curl -sf -X POST $OIDC_ISSUER/v1/mint-oidc-jwt \
  -H "Authorization: Bearer $SESSION_JWT_A" | jq -r .jwt)
echo "JWT prefix: ${JWT:0:40}…"

# Exchange it for AWS creds — UNAUTHENTICATED to AWS (the JWT authenticates).
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
CREDS=$(aws sts assume-role-with-web-identity \
  --role-arn "$DATA_ROLE_ARN" \
  --role-session-name "live-demo-$(date +%s)" \
  --web-identity-token "$JWT")
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)

# Confirm — the assumed role identity, NOT your admin profile.
aws sts get-caller-identity
# {
#   "UserId": "AROA…<role-id>:live-demo-…",
#   "Arn": "arn:aws:sts::ACCOUNT:assumed-role/agentkeys-data-role/live-demo-…"
# }
```

### 16.6 S3 cloud-enforced isolation proof

```bash
# === ON OPERATOR WORKSTATION (still with assumed-role creds) ===
WALLET_A_LC=$(echo "$ADDR_A" | tr '[:upper:]' '[:lower:]')
WALLET_B_LC=$(echo "$ADDR_B" | tr '[:upper:]' '[:lower:]')

# Wallet A's prefix — SUCCESS.
aws s3api list-objects-v2 --bucket "$BUCKET" \
  --prefix "bots/${WALLET_A_LC}/" --query 'Contents[*].Key'

# Wallet B's prefix — AccessDenied (cloud-enforced).
aws s3api get-object --bucket "$BUCKET" \
  --key "bots/${WALLET_B_LC}/hello.txt" /tmp/got-B.txt
# An error occurred (AccessDenied) when calling the GetObject operation
```

### 16.7 Auto-provision pipeline against live broker

```bash
# === ON OPERATOR WORKSTATION ===
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# The daemon reads these env vars and threads them through to the
# provisioner's fetch_via_broker_default_ttl().
export AGENTKEYS_BROKER_URL=https://broker.litentry.org
export AGENTKEYS_DATA_ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/agentkeys-data-role
export AWS_REGION=us-east-1

# Run the provisioner-driven scraper. The subprocess receives
# AWS_ACCESS_KEY_ID/SECRET/SESSION_TOKEN via env injection — those creds
# are minted by the daemon calling /v1/mint-oidc-jwt + AssumeRoleWithWebIdentity.
agentkeys-cli provision --service openrouter
# … scraper runs, fetches the verification email from S3 using the
# injected temp creds …
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
the STS-side audit trail.

If you need server-side audit row coverage of the actual mint, hit
`/v1/mint-aws-creds` instead — it audits before returning creds.

---

## 17. Cleanup

Reset to your admin profile after the demo:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
awsp agentkeys-admin
aws sts get-caller-identity        # confirm: back to admin
```

The broker keeps running. To tear down the cloud-side state
(provider, role, bucket policy), follow `cloud-setup.md §6`.

---

## Cross-references

- [`docs/operator-runbook-stage7.md`](operator-runbook-stage7.md) —
  authoritative env-var inventory, BOOT_FAIL anchors, recovery
  procedures, OAuth2/email setup details.
- [`docs/cloud-setup.md`](cloud-setup.md) — AWS-side IAM, OIDC
  provider, bucket policy, EC2 broker host wiring.
- [`docs/spec/plans/issue-64/PLAN.md`](spec/plans/issue-64/PLAN.md) —
  the canonical Stage 7 plan (§6 Refuse-to-boot tiers; §3.5 plugin
  trait surface; §3.5.4 OAuth2 security posture; §3.5.6 dual-keypair
  rationale).
- [`docs/spec/plans/issue-64/PHASE-0-CHECKPOINT.md`](spec/plans/issue-64/PHASE-0-CHECKPOINT.md)
  — Phase-0-isolated localhost checkpoint that this guide
  generalizes to a real cloud deployment.
- [`harness/stage-7-issue-64-done.sh`](../harness/stage-7-issue-64-done.sh)
  — programmatic equivalent of §13 above (the gate CI runs).
