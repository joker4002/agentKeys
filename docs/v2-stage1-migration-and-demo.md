# v2 stage 1 — migration from stage 7 demo + new-feature demo

**Audience**: operators running today's stage 7 demo (per [stage7-demo-and-verification.md](stage7-demo-and-verification.md) §0–§5) who will migrate to v2 stage 1 (per [docs/spec/plans/v2-issues/issue-v2-stage-1-foundation.md](spec/plans/v2-issues/issue-v2-stage-1-foundation.md) + [arch.md §14](spec/architecture.md)).

**This doc has two parts:**
1. **Part A — migration**: every break/change to the existing stage 7 demo (§0–§5), with the minimum operator steps to adapt
2. **Part B — new-feature demo**: a fresh end-to-end run that exercises everything stage 1 adds (sovereign sidecar + on-chain identity + credentials-service worker), so an operator can verify stage 1 is live before retiring the old flow

Both parts assume arch.md §14 as the canonical reference and PR #87 (today's `S3CredentialBackend`) as the predecessor that stage 1 replaces.

---

## What landed in this commit (incremental stage-1 deliverable)

This commit ships the **first batch of stage-1 CLI/backend changes** that are safe to merge without the chain contracts or sidecar daemon being live yet. Operators can adopt these immediately; the remaining stage-1 work (broker cap-mint endpoints, on-chain contracts, sidecar daemon, K11 WebAuthn) lands in follow-up commits.

| What's live now | Where to see it | What's still TBD |
|---|---|---|
| `agentkeys_actor_omni` computed deterministically from `(master_wallet)` | `agentkeys whoami` prints it as a new line; CLI also surfaces it in `--verbose` mode of `store`/`read`/`teardown` | Population in the OIDC JWT (broker mint step) — today still operator-provided via `--omni-account` |
| `--credential-backend=sidecar` flag accepted by CLI surface | `agentkeys --credential-backend=sidecar <cmd>` parses but returns a clear "not yet implemented" error pointing at `--envelope-version=v2` instead | Daemon-side `agentkeys-proxy.sock` HTTP proxy + cap-token flow |
| `--envelope-version={v1,v2}` flag on the S3 backend | `agentkeys --credential-backend=s3 --envelope-version=v2 store …` writes the v2 envelope shape to the actor_omni-keyed path | Operator opt-in flow + bucket-policy dual-tag rollout |
| v2 envelope shape (`agentkeys.cred.aad.v2|<actor_omni_hex>|<service>`) | `crates/agentkeys-core/src/s3_backend.rs` — `aad_for_v2` + envelope version byte `0x02` | (none — envelope is final per arch.md §14.4) |
| Dual-path read: v2 path first, v1 fallback on NotFound | `S3CredentialBackend::read_credential` | Lazy on-access copy v1→v2 (currently read-only fallback; no rewrite on read) |
| Dual-prefix teardown: wipes both `bots/<wallet>/` AND `bots/<actor_omni_hex>/` | `S3CredentialBackend::teardown_agent` | (none) |
| Dual-prefix listing: union of v1 + v2 prefixes, dedup'd | `S3CredentialBackend::list_credentials` | (none) |

**What this lets you do today**, against the existing PR #87 S3 backend without any chain or sidecar work:

```bash
# Mint creds via existing OIDC + STS path
export AGENTKEYS_BROKER_URL=https://broker.example
agentkeys init --email you@example.org

# See your new actor_omni
agentkeys whoami
# session_wallet: 0xabc...
# agentkeys_actor_omni: a17e...    <-- NEW: stable across K3 rotation

# Write under v2 envelope to the actor_omni-keyed S3 path
agentkeys --credential-backend=s3 --envelope-version=v2 \
  --bucket=$AGENTKEYS_BUCKET \
  --signer-url=$AGENTKEYS_SIGNER_URL \
  --omni-account=$AGENTKEYS_OMNI_ACCOUNT \
  store openrouter sk-or-v1-XXX

# Read still works — backend tries v2 path first, falls back to v1 on miss
agentkeys --credential-backend=s3 --envelope-version=v2 read openrouter

# A pre-migration credential written under --envelope-version=v1 also still reads
# (dual-envelope decrypt + dual-path lookup, see Part A.4 below)
```

**What this does NOT do yet**: the bucket-policy `_v2_omni_keyed` rule still needs to be added per the migration runbook step 4 before v2 writes succeed against a live bucket. Until then, v2 writes will fail with `AccessDenied` because the bucket policy only knows about the v1 `agentkeys_user_wallet` PrincipalTag. The migration runbook step 4 is operator-deployment work, not code.

---

## Part A — Migration: what breaks in stage 7 demo §0–§5

### A.1 §1 init flow — adds K10 generation as a new Stage 0 (before email-link)

**Stage 7 demo today (§1)**:
```
agentkeys init --email alice@example.org
# CLI does email-link auth, derives wallet via signer, links via SIWE, mints J1
```

**Stage 1 (v2)** — adds two new steps per arch.md §5 stages 0–3:
```
# Stage 0 (new) — K10 generation on device, local only
#   Daemon generates (D_priv, D_pub) = K10 in OS keychain at startup
#   (no operator-visible step; happens automatically on first launch)

# Stage 1 — same as today (email-link / OAuth2)
agentkeys init --email alice@example.org

# Stage 2 (new in v2) — WebAuthn binding (master devices only)
#   CLI prompts Touch ID / Face ID / Windows Hello
#   Platform authenticator generates K11; commits D_pub atomically
#   inside WebAuthn challenge per arch.md §5a.1 Q7 fix

# Stage 3 — SIWE → J1 (same as today)

# Stage 4 (new in v2) — On-chain SidecarRegistry binding (meta-tx OR sovereign)
#   CLI submits SidecarRegistry.register_master_device(...) tx
```

**Operator impact**:
- **Existing users**: their current `J1` keeps working for read operations; a one-time **device-registration ceremony** is required before stage 1 features (sidecar proxy, cap-mint, on-chain scope) take effect
- **New users**: stage 1 ships the full §5 stages 0–3 flow; nothing to migrate

**Migration command** (one-time per existing operator):
```bash
agentkeys device register --upgrade-from-v1
# Walks through: K10 derive → WebAuthn enrollment → SidecarRegistry write
```

If WebAuthn is unavailable (Linux box without TPM, CI agent, etc.), CLI falls back to the v1c `pop_sig` shape per arch.md §5 footnote — same wire shape stage 1 ships will continue to accept this for a release of soak time.

### A.2 §2 provisioning (§5.3 auto-provision) — new `--credential-backend=sidecar`

**Stage 7 demo today (§5.3)**:
```
bash scripts/agentkeys-provision-demo.sh --session-id alice openrouter
# Internally: agentkeys provision uses --credential-backend=s3 by default (PR #87)
# Stores key at s3://$BUCKET/bots/<master_wallet>/credentials/openrouter.enc
```

**Stage 1**: add new `--credential-backend=sidecar` flag (parallel to existing `s3`/`http`):
```
agentkeys --credential-backend=sidecar provision openrouter
# Internally:
#   1. Daemon's localhost proxy is the actual storage path (no direct S3 from CLI)
#   2. CLI signs cap-store request with K10
#   3. Sends to broker /v1/cap/cred-store
#   4. Broker co-signs, returns cap
#   5. CLI sends cap + plaintext to creds-service worker
#   6. Worker writes to s3://$BUCKET/bots/<actor_omni_hex>/credentials/openrouter.enc
#      (new path, see A.4)
```

**Migration impact**:
- Default stays `--credential-backend=s3` during stage 1 transition (`#87` path keeps working)
- Operators opt in to `--credential-backend=sidecar` once their daemon is upgraded
- Deprecation warning printed when `=s3` is selected after stage 1 ships
- Default flips to `=sidecar` after one release of soak time (separate follow-up issue)

**Today's incremental state** (per "What landed in this commit" section above): `--credential-backend=sidecar` is wired through the CLI surface, but the daemon-side proxy isn't built yet — selecting it returns a clear "not yet implemented" error pointing operators at `--credential-backend=s3 --envelope-version=v2` as the closest currently-working substitute (same S3 path, same envelope shape, just minus the broker cap-token co-sign + on-chain scope check). This lets operators dry-run their migration steps (path, AAD, bucket policy) before the daemon lands.

### A.3 §0.4 wallet derivation reference — unchanged math, new identifier consumers

**Stage 7 demo today (§0.4)**: derives `ADDR_A = HKDF(K3_v1, O_A)` (master_wallet for Alice).

**Stage 1**: same derivation, but a NEW IDENTIFIER `actor_omni_alice = SHA256("agentkeys"||"evm"||ADDR_A)` becomes the primary on-chain / S3 / PrincipalTag identifier. ADDR_A still exists but is signer-internal except in sovereign chain submissions.

**Operator impact**: a new `agentkeys whoami` field shows `actor_omni` in addition to `session_wallet`. The math reference table in §0.4 should be amended to show:

| What | Where | How it's derived |
|---|---|---|
| `actor_omni` | NEW — primary v2 identity | `SHA256("agentkeys" \|\| "evm" \|\| master_wallet)`, frozen at first SIWE-bind |
| `master_wallet` | Same as today | `HKDF(K3_v[epoch], actor_omni)` — rotates with K3 |

### A.4 S3 prefix migration: `bots/<wallet>/` → `bots/<actor_omni_hex>/`

**Today**: credentials at `s3://$BUCKET/bots/0x<master_wallet>/credentials/<service>.enc`

**Stage 1**: credentials at `s3://$BUCKET/bots/<actor_omni_hex>/credentials/<service>.enc`

**Why**: K3-rotation tolerance. master_wallet rotates with K3 epoch; actor_omni is frozen at first SIWE-bind. Keying S3 paths on actor_omni eliminates path migration on K3 rotation.

**Migration strategy** (per stage 1 issue):
- Workers do **lazy on-access copy**: on cred read, try new path first; on miss, fall back to old path; if found at old path, copy to new path + delete from old path (or queue for later GC); subsequent reads hit new path
- **Eager migration tool** (operator-runnable): `agentkeys-migrate-s3-prefix --operator-omni <actor_omni>` walks all blobs at old path, decrypts under K3_v1, re-encrypts under current K3 epoch, writes to new path, deletes from old path. Useful for operators who want to retire old paths early.

**Operator impact**:
- During the transition: both paths can coexist (lazy migration handles)
- No data loss; no downtime
- Old paths become empty after eager migration or natural decay

### A.5 §3 OIDC + STS — AWS PrincipalTag flips from `agentkeys_user_wallet` to `agentkeys_actor_omni`

**Today**: OIDC JWT carries `agentkeys.wallet_address`; STS issues PrincipalTag `agentkeys_user_wallet = <wallet>`; bucket policy scopes via `${aws:PrincipalTag/agentkeys_user_wallet}`.

**Stage 1**: OIDC JWT also carries `agentkeys.actor_omni`; STS issues BOTH tags during a transition window; bucket policy adds a parallel rule scoping via `${aws:PrincipalTag/agentkeys_actor_omni}`.

**Bucket-policy update** (one-time per AWS account):
```jsonc
// EXISTING (today's #87 path) — keep during transition
{
  "Sid": "AllowDaemonGetOwnObjects_v1_wallet_keyed",
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::ACCOUNT:role/agentkeys-data-role"},
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::$BUCKET/bots/${aws:PrincipalTag/agentkeys_user_wallet}/*"
},
// NEW (stage 1 path) — add alongside
{
  "Sid": "AllowDaemonGetOwnObjects_v2_omni_keyed",
  "Effect": "Allow",
  "Principal": {"AWS": "arn:aws:iam::ACCOUNT:role/agentkeys-data-role"},
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::$BUCKET/bots/${aws:PrincipalTag/agentkeys_actor_omni}/*"
}
```

Same dual-rule pattern for `s3:ListBucket` (per arch.md §4.4 split) and the new `AllowDaemonPutOwnCredentials` (for credentials/* writes).

After one release of soak time, the `_v1_wallet_keyed` rule and the `agentkeys_user_wallet` tag emission can be retired.

**Operator runbook update**: a new section in [cloud-setup.md](cloud-setup.md) §4.4 documents the dual-tag transition window.

### A.6 §5.1 / §5.2 OIDC mint — JWT shape evolves

**Today**: OIDC JWT claims include `wallet_address` (master_wallet) for STS PrincipalTag.

**Stage 1**: claims expand to:
```jsonc
{
  "iss": "https://broker.litentry.org",
  "sub": "<actor_omni_hex>",     // PRIMARY identity
  "agentkeys": {
    "actor_omni":     "<32-byte hex>",
    "operator_omni":  "<32-byte hex>",
    "wallet_address": "0x...",      // KEPT for backwards compat during transition window
    "k3_epoch":       2             // NEW — which K3 generation the JWT was minted under
  }
}
```

After the transition window, `wallet_address` claim is removed; `actor_omni` becomes the sole AWS PrincipalTag source.

**Operator impact**:
- Existing tooling that parses `wallet_address` keeps working during transition
- New tooling should consume `actor_omni` directly
- The `agentkeys-isolation-demo.sh` script (§4.0) needs an update to query the new tag — separate follow-up

### A.7 §4 cloud-enforced isolation proof — bucket policy supports both PrincipalTags

The §4 demo proves "Alice's role with PrincipalTag X cannot read Bob's prefix". In stage 1, this proof works for BOTH tag names during the transition. The demo script (`agentkeys-isolation-demo.sh`) gets a new `--tag-version v1|v2` flag; the default tracks the dual-tag window.

### A.8 §0.3 identity ↔ `omni_account` math — agent omni naming unchanged

Per arch.md §3a + §4: master_omni is unchanged; agent omnis are unchanged (HDKD soft-derive under master_omni with operator-chosen labels). The math in §0.3 reference still applies; nothing to migrate.

### A.9 Summary of files that need updates (during stage 1 work)

| File | Update needed |
|---|---|
| [stage7-demo-and-verification.md](stage7-demo-and-verification.md) | Add cross-ref to this migration doc; mark §5.3's `--credential-backend=s3` as deprecated-after-stage-1 |
| [cloud-setup.md](cloud-setup.md) §4.4 | Add dual-tag transition policy; new bucket-policy snippet |
| [operator-runbook-stage7.md](operator-runbook-stage7.md) | Replace existing init flow with arch.md §5 stages 0–3 (K10 + WebAuthn + SIWE) |
| [arch.md §3a](spec/architecture.md) — canonical names | Already has `credential_kek` / `credential_envelope`; add `actor_omni` external-uses row, `K3_epoch` row, `device_pubkey_hash` row |
| [arch.md §9](spec/architecture.md) — component inventory | Add credentials-service / memory-service / audit-service / email-service workers as new entries |

---

## Part B — Stage 1 new-feature demo (end-to-end manual run)

Once stage 1 ships, an operator can verify all the new features against a staging deployment. Each section is a self-contained step the operator can run.

### B.0 Prerequisites

```bash
# Same as stage 7 §0 prerequisites, plus:
gh auth status                              # need GH access for ScopeContract / SidecarRegistry deploys
litentry --version                          # need Litentry-chain CLI tooling (placeholder for now)
agentkeys --version                         # confirm CLI ≥ stage 1 build

export OPERATOR_OMNI=<your actor_omni from agentkeys whoami>
export BUCKET=$BUCKET                       # same as stage 7
export CHAIN_RPC=https://rpc.litentry.io    # placeholder — actual endpoint per stage 1 issue
```

### B.1 Bootstrap a fresh master device (arch.md §5 stages 0–3 + Stage 4)

```bash
# Stage 0 — implicit, daemon generates K10 on first run
agentkeys daemon start --foreground &
# In another shell:

# Stages 1+2+3 — interactive
agentkeys init --email demo-alice@example.org

# Expected interactive UX:
#   1. Magic link sent to demo-alice@example.org → click
#   2. Touch ID / Face ID prompt → enroll K11 (binds D_pub atomically)
#   3. Signer derives wallet → broker verifies → mints J1

# Stage 4 — automatic post-Stage-3
# CLI submits SidecarRegistry.register_master_device(...) tx
# Confirm on-chain:
agentkeys device list
# Expected output (single device, all roles):
#   device_pubkey_hash | actor_omni | tier | roles | k11_cred_id
#   0x7a3f...          | <yours>    | 1=M  | 0x07  | 0xab12...
```

Verification:
```bash
agentkeys whoami
# Expected:
#   actor_omni:    <your actor_omni>
#   master_wallet: 0x...
#   devices:       1 master device (this one)
```

### B.2 Inspect the on-chain SidecarRegistry entry

```bash
# Direct chain query (litentry-CLI placeholder — actual command per stage 1 deploy):
litentry call SidecarRegistry.device "0x7a3f..."
# Expected: {operator_omni, actor_omni, tier: 1, roles: 0x07, k11_cred_id: 0xab12...}
```

### B.3 Add a 2nd master device (per arch.md §5a.3.1) — verify K11 enforcement

On a second laptop / VM (or phone with mobile app):
```bash
# Daemon starts; generates K10 locally; CLI displays QR pairing payload
agentkeys daemon start --pair-as-master
# First device scans QR; prompts Touch ID for K11 assertion; submits register_master_device tx
# Confirm on-chain:
agentkeys device list
# Expected: 2 devices, threshold=1
```

### B.4 Create a child agent (`agentkeys agent create`) — verify K11 required

```bash
agentkeys agent create --label demo-agent-1
# Expected interactive UX:
#   1. CLI prompts Touch ID (K11 required — Codex finding #2)
#   2. Broker derives O_agent_1 = master_omni // "demo-agent-1"
#   3. Broker mints one-time link_code, signed by K11
#   4. CLI displays link_code

# On the agent device (e.g., Raspberry Pi):
agentkeys init --link-code <link_code_from_master>
# Expected: K10 generated locally; J1_agent minted
# SidecarRegistry registers agent device with roles=CAP_MINT only (no K11)
```

### B.5 Grant scope to the agent (K11 required)

```bash
# On master device:
agentkeys scope --agent <agent_1_actor_omni> --add openrouter
# Expected interactive UX:
#   1. CLI prompts Touch ID
#   2. K10 + K11 sigs over payload
#   3. Relay submits ScopeContract.set_scope_with_webauthn(...)
#   4. Chain confirms (~1-12s)

# Verify:
agentkeys scope --agent <agent_1_actor_omni> --list
# Expected: services=["openrouter"], read_only=false
```

### B.6 Use the sidecar proxy from the agent

```bash
# On the agent device, daemon is running.
# Agent's task points its OpenAI/Anthropic client at the daemon localhost:
source ~/.config/agentkeys/env
# This sets, e.g., OPENAI_API_BASE=http://localhost:9090/proxy/openrouter
#                  OPENAI_API_KEY=ak-sidecar (placeholder)

# Agent runs a normal OpenAI-compatible call:
curl http://localhost:9090/proxy/openrouter/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "openai/gpt-4", "messages": [{"role": "user", "content": "Hello"}]}'

# Expected daemon behavior:
#   1. SO_PEERCRED → verify caller UID
#   2. Cache miss → mint cap-fetch request, signed by K10
#   3. Broker verifies + co-signs
#   4. Daemon forwards cap to creds-service worker
#   5. Worker decrypts plaintext under K3_v[epoch] KEK
#   6. Daemon caches plaintext, injects Authorization header
#   7. Daemon forwards request to openrouter; streams response back to agent

# Daemon logs (audit row):
journalctl -u agentkeys-daemon | grep proxy
# Expected: caller=<uid>, service=openrouter, method=POST, path=/v1/chat/completions, status=200
```

### B.7 Verify per-actor binding (Codex finding #1 containment)

```bash
# On agent_1's device, attempt to mint a cap with a DIFFERENT actor_omni:
curl http://localhost:9090/proxy/openrouter/v1/chat/completions \
  -H "X-Agentkeys-Cap-Actor: <agent_2_actor_omni>" \
  ...

# Expected: broker rejects (D_pub_AGENT_1 is bound to agent_1_actor_omni, NOT agent_2)
#   HTTP 403 from broker: "cap.agent_omni does not match registered actor for device_pubkey"
```

### B.8 Verify K3 epoch enforcement (Codex finding #4)

```bash
# Inspect current K3 epoch on chain:
litentry call K3EpochCounter.current_epoch
# Expected: 1 (initial epoch)

# Verify a cap-fetch with manipulated epoch is rejected:
agentkeys cap mint --service openrouter --k3-epoch 99
# Expected: broker rejects "epoch 99 > chain epoch 1"
```

### B.9 Verify actor_omni-keyed S3 path

```bash
# List S3 prefix to confirm new path layout:
aws s3 ls "s3://$BUCKET/bots/$OPERATOR_OMNI/credentials/" --region us-east-1
# Expected: openrouter.enc (and any other stored creds)

# Old wallet-keyed prefix should be empty for new credentials:
aws s3 ls "s3://$BUCKET/bots/$(agentkeys whoami --field master_wallet)/credentials/"
# Expected: empty (or only legacy creds that haven't been lazily migrated)
```

### B.10 Verify cap-mint audit trail

```bash
# Query audit chain for recent cap-mints under this operator:
litentry call CredentialAudit.events --operator-omni $OPERATOR_OMNI --limit 5
# Expected: list of CapMintedBatch + CredentialUpdated events from B.5–B.9
```

### B.11 Tear down

```bash
agentkeys agent revoke --agent <agent_1_actor_omni>
# Expected: K11 prompt; ScopeContract.set_scope_with_webauthn(...) revoking all services;
#   SidecarRegistry.revoke_device(D_pub_AGENT_1, ...); broker pushes drop event

agentkeys device list
# Expected: agent_1 device entry shows revoked_at timestamp
```

---

## Codex-review-driven addendum (2026-05-17)

Three high-severity findings from `/codex:adversarial-review` on the stage 1 plan + arch.md §14 + this doc were folded back into the plan + this doc before implementation begins:

1. **Cloud-enforced vs host-local enforcement distinction is now explicit.** ScopeContract is the cloud-enforced authority for "what service is in scope". Per-method / per-path / per-spend constraints live in **host-local sidecar config** — bypassable by a compromised sidecar but bounded by cloud-enforced cap-binding (compromised sidecar can drive only the actor's registered services, not siblings). Stage 1 ships both layers; arch.md §14 + the stage 1 plan now mark this split clearly.
2. **K11 WebAuthn enforcement moves into stage 1.** Stage 1 ships the FULL master-mutation authorization model (K10 + K11). The original plan deferred K11 to stage 2 — that would have created an escalation window where K10-only sig could mutate on-chain scope. Stage 1's ScopeContract.set_scope_with_webauthn(...) REQUIRES K11; bootstrap includes WebAuthn enrollment (arch.md §5 Stage 2).
3. **S3 path / PrincipalTag migration is dual-read by spec.** Stage 1 migration sequence is now: (a) OIDC JWT emits BOTH v1 (`agentkeys_user_wallet`) AND v2 (`agentkeys_actor_omni`) tags during transition; (b) bucket policy adds v2 rules ALONGSIDE v1 (no removal); (c) credentials-service worker reads BOTH paths AND envelope formats; (d) lazy on-access copy moves blobs from v1 → v2; (e) flag-flip retirements happen only after full release of soak time. No step before the final retirement can break existing #87 flows.

The §A migration sequence above reflects these amendments.

## What's NOT in this doc

- **K3 rotation flow** (per arch.md §14.7.7). Stage 1 ships the contract and signer hooks; the rotation operational runbook is part of stage 2's deliverable.
- **Multi-device recovery** (per arch.md §14.7.6). Recovery flow requires the M-of-N quorum + role bitfield enforcement that stage 2 adds. Stage 1 ships K11 enrollment for SINGLE master device per Codex amendment #2; multi-device pairing is stage 2.
- **Payment service**. Deferred to a separate issue ([issue-payment-service-deferred.md](spec/plans/v2-issues/issue-payment-service-deferred.md)).

---

## Revision log

- 2026-05-17 (initial) — Drafted alongside v2 stage 1 issue. Covers all known breaks to stage 7 demo §0–§5 + a complete end-to-end demo of stage 1's new features.
- 2026-05-18 (incremental implementation 1) — First batch of stage-1 CLI/backend code shipped: `agentkeys_core::actor_omni` helper, v2 envelope shape (`ENVELOPE_VERSION_V2 = 0x02`, AAD v2 = `agentkeys.cred.aad.v2|<actor_omni_hex>|<service>`), dual-path read with v1 fallback, dual-prefix teardown + list, CLI `--envelope-version={v1,v2}` flag, `--credential-backend=sidecar` flag accepted (errors with "not yet implemented" for now), `agentkeys whoami` prints `agentkeys_actor_omni`. New "What landed in this commit" section at the top of this doc enumerates the deliverables. Remaining stage-1 work (chain contracts, sidecar daemon, broker cap-mint endpoints, K11 WebAuthn, OIDC dual-tag, bucket-policy dual-rule) tracked in [docs/spec/plans/v2-issues/issue-v2-stage-1-foundation.md](spec/plans/v2-issues/issue-v2-stage-1-foundation.md).
