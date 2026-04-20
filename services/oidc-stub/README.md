# agentkeys-oidc-stub

> **THIS IS A TEE-INTERIM STUB.**
> Production Stage 6 replaces the signer with a TEE-derived `oidc/issuer/v1` key
> per `wiki/oidc-federation.md` §Architecture (heima-gaps §3).
> **Do NOT deploy this to production without an audit.**

Minimal OIDC discovery + JWKS service for `oidc.agentkeys.dev`. Used in Stage 5b
scraper testing and Stage 6 AWS IAM federation setup — before the real TEE signer
is wired in.

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/.well-known/openid-configuration` | OIDC discovery document (AWS IAM compatible) |
| `GET` | `/.well-known/jwks.json` | JWK Set with the ES256 public key |
| `POST` | `/internal/sign` | Dev-only: sign arbitrary claims, returns JWT |

## Running locally

```bash
cd services/oidc-stub
npm install
npm start
```

Server listens on `http://localhost:34568` by default. Override with env vars:

```bash
OIDC_STUB_PORT=8080 OIDC_STUB_ISSUER=https://oidc.agentkeys.dev npm start
```

Test the endpoints:

```bash
curl http://localhost:34568/.well-known/openid-configuration | jq .
curl http://localhost:34568/.well-known/jwks.json | jq .
curl -X POST http://localhost:34568/internal/sign \
  -H 'content-type: application/json' \
  -d '{"sub":"enclave:test:agent:0xabc","aud":"sts.amazonaws.com"}' | jq .
```

## Key persistence

On first startup a fresh P-256 keypair is generated and cached at
`~/.agentkeys/oidc-stub/keypair.json` (mode 0600). Subsequent restarts reuse this
keypair so the JWKS stays stable for AWS/GCP OIDC provider registrations.

The `keys/` directory in this repo and all `*.keypair.json` / `keypair.json` files
are `.gitignore`-d — never commit a private key.

## TLS / HTTPS

For local dev, plain HTTP on localhost is fine. In staging/production, run this
service behind a reverse proxy (nginx, Caddy, AWS ALB) that terminates TLS with a
public-CA certificate. AWS IAM requires the issuer URL to start with `https://`;
see `wiki/oidc-federation.md` §"Key requirements".

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OIDC_STUB_PORT` | `34568` | Port to listen on |
| `OIDC_STUB_ISSUER` | `https://oidc.agentkeys.dev` | Issuer URL emitted in discovery doc + JWTs |
| `AGENTKEYS_OIDC_KMS_KEY_ID` | unset | If set, stub errors immediately — KMS path not implemented (reserved for Stage 6 production path) |

## Running tests

```bash
npm test
```

## Security caveats

1. **Private key on disk.** The dev keypair lives unencrypted in
   `~/.agentkeys/oidc-stub/keypair.json`. Protect your home directory.
2. **`/internal/sign` is unauthenticated.** Any process that can reach the port
   can mint arbitrary JWTs. Firewall this endpoint; do not expose it on 0.0.0.0 in
   any shared environment.
3. **Not a TEE.** This stub generates the key in userspace. The production
   architecture (Stage 6) derives the key inside the TEE enclave so it never
   leaves hardware. This stub is solely for dev/test workflows.
4. **KMS stub.** If `AGENTKEYS_OIDC_KMS_KEY_ID` is set the server refuses to
   start. The KMS path is documented with a TODO in `src/keys.ts` but not
   implemented — it is superseded by the TEE path before it would ever be needed.

## Stage 6 follow-up

Replace `src/keys.ts` `loadKeypair()` with a call to the TEE `oidc/issuer/v1`
signing oracle. The three HTTP endpoints stay identical; only the signing
backend changes. See `wiki/oidc-federation.md` for the full architecture.
