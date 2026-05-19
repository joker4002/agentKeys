# Credential storage — design comparison

**Status**: Living doc. Revised iteratively as the design evolves.
**Audience**: agentkeys architects + reviewers thinking about v1/v2 evolution of credential storage past today's #87.
**Scope**: How agents fetch, decrypt, and consume long-lived upstream credentials (OpenRouter, Anthropic, etc.). Cross-references arch.md §7a (bucket layout), §9 #10 (mock-server deprecation), §3a (canonical names).

---

## Three designs under active comparison

### Design A — Deterministic KEK + client-side trust boundary (shipped in [#87](https://github.com/litentry/agentKeys/pull/87))

- `KEK = SHA256("agentkeys.kek-derive.v1" || signer.sign_eip191(omni, "agentkeys.kek.v1:" || wallet || ":" || service))`
- secp256k1 + RFC 6979 → deterministic signature → deterministic KEK.
- Agent calls signer, gets signature, hashes to KEK, AES-256-GCM-opens blob.
- `S3CredentialBackend::enforce_scope_for_service` checks `Session.scope` *client-side* before the signer call.
- Bucket policy isolates by wallet PrincipalTag.

### Design B — OIDC-attested scope JWTs + signer-gated KEK release

- Broker mints a scope-attested OIDC JWT (5min TTL) per session, signed by K2.
- JWT carries scope claims: `{credential_services: [...], credential_readonly_services: [...]}`.
- JWT has `cnf.jkt` claim binding it to the agent's omni-derived keypair (RFC 7800 / DPoP).
- Agent calls signer; signer verifies JWT (K2 sig + scope claim) + DPoP challenge; releases KEK.
- KEK derivation is **still deterministic** — same formula as Design A, but signer now refuses to release without a scope-attested JWT.

### Design C — Tiered capability tokens with broker-mediated decrypt

Broker holds authoritative `scope_table[wallet] → {credential_services, ...}`. Per-operation cap mint at broker — short-lived (≤60s), single-purpose. Two operational sub-variants:

#### C-high — broker fetches plaintext, agent uses it directly for upstream calls

- Agent calls `broker.fetch_credential(cap, service)` → broker reads ciphertext from S3, calls signer to derive KEK over an mTLS-only `internal_derive_cred_kek` endpoint, AES-GCM-opens, returns plaintext over TLS.
- Agent receives plaintext; uses it for one upstream LLM call (or batch of calls within the agent's task lifetime); drops it.
- Broker traffic: per credential fetch (low — typically ~once per agent task setup, then the agent uses the cached plaintext for many LLM calls in the same task).
- **Broker is NOT in the LLM-call hot path**; only in the credential-fetch path.

#### C-low — broker proxies every upstream call

- Agent calls `broker.invoke_upstream(cap, service, request)` → broker fetches plaintext server-side, injects, forwards to upstream, streams response back.
- Agent never sees plaintext.
- **Broker IS in the LLM-call hot path** — every LLM call is a broker round-trip. Heavy. Not recommended.

The original rev 2 of this doc conflated C-high and C-low into a single "Design C", then rejected the merged design citing C-low's cost. Codex's adversarial review (2026-05-17) flagged this — see review section below. Rev 4 splits them.

The signer's `derive_cred_kek` endpoint is **not exposed to agents** in either variant — only the broker can reach it.

### Design E — Sidecar credential injection with delegated-bearer controls (the production-default 2026 pattern, rev 4 controls)

The daemon process running on the operator's host **becomes the sidecar**: it holds plaintext credentials in memory **for a bounded TTL**, exposes a localhost HTTP proxy at `http://localhost:9090/proxy/<service>/...`, injects `Authorization: Bearer <cred>` on every forwarded request **only when the request passes the controls below**.

The agent calls the daemon's localhost endpoint instead of the upstream directly. **Agent never sees the credential as a string.** But — and this is the rev 4 honesty fix — **the localhost proxy IS a delegated bearer capability**. A compromised agent that cannot read the cred bytes can still drive the cred through the proxy for arbitrary upstream calls while the sidecar is alive. The controls below bound that capability.

Rev 4 design choices:
- **Lazy fetch, short TTL** (not eager-bootstrap-and-hold-forever as in rev 2). Sidecar fetches a credential the first time an agent requests it via the proxy; holds for `cred_cache_ttl` (default 5 min); purges on TTL expiry. Next agent request triggers a fresh fetch from broker. Bounded plaintext lifetime in sidecar memory.
- **Per-call broker round-trip is amortized** — first request after TTL pays the ~100ms broker hit; subsequent requests within the TTL window are localhost-only (~0.1ms).
- **Broker is in the credential-fetch path** (every ~5 min, not every LLM call) — same as C-high. Broker is NOT in the LLM-call hot path.
- For LLM streaming responses (SSE): daemon proxies chunk-by-chunk; per-chunk overhead is one localhost TCP write.

#### E's required controls (rev 4 — addresses Codex finding [high] #1)

The "agent holds nothing" property only holds if **every** control below is enforced:

| Control | Mechanism (E1 — local) | Mechanism (E2 — container) | Mechanism (E3 — TEE) |
|---|---|---|---|
| Caller authentication | Unix socket + `SO_PEERCRED` UID check | Network namespace (pod-scoped) + optional mTLS | SPIFFE SVID + remote-attestation pin |
| Per-caller scope binding | Sidecar config maps `(uid, binary_path) → allowed_services` | Map `pod_identity → allowed_services` | Map attested workload identity → allowed_services |
| Service/method/path allowlist | Per service: explicit `{methods: [POST], paths: [/v1/chat/completions, /v1/messages], forbidden_headers: [...]}` | Same | Same |
| Spend quotas | Per-caller token bucket: req/min, req/hour, daily $ budget | Same | Same |
| Per-call audit | Daemon writes audit row to local log + ships to audit chain (broker `/v1/audit/append`) | Same | Same |
| Fail-closed on stale broker | If `now - last_broker_event > stale_threshold` (60s): refuse new fetches; cached creds expire on schedule and aren't renewed | Same | Same |
| Request integrity | Reject requests with unrecognized methods/paths; sanitize headers; reject when body > max_size | Same | Same |

A compromised agent that bypasses any of these controls escalates to "full bearer use of every cached credential". The controls **must** ship as part of Design E v1; they are not optional hardening.

#### E's revocation semantics (rev 4 — addresses Codex finding [high] #2)

The effective revocation bound is **NOT** "instant with broker push"; it is:

```
effective_revocation = min(cred_cache_TTL, time_since_last_successful_broker_event + grace)
```

With defaults (`cred_cache_TTL` = 5 min, `grace` = 60 s):
- **Best case** (broker push received): cred is purged immediately on the next request; one in-flight request may complete with the about-to-be-revoked cred.
- **Typical case** (TTL expiry, no push): up to 5 minutes after broker scope change until cred purge.
- **Worst case** (broker unreachable for `> stale_threshold`): sidecar enters stale state; existing cached creds continue to be served for up to one full cache TTL (so up to 5 min from last successful broker contact), then are refused; no new fetches succeed.
- **Adversarial worst case** (broker push intercepted/dropped, sidecar still polls successfully for unrelated events): up to one cache TTL.

Fail-closed rules:
1. Broker unreachable > stale_threshold → enter stale state; refuse new fetches; existing cache still serves until per-cred TTL expiry.
2. Per-cred TTL expiry while in stale state → purge cred; refuse all proxy requests for that service.
3. Broker scope-table denies cred on TTL refresh → purge cred; refuse subsequent requests.
4. Sidecar receives explicit "drop" event for cred X → purge X immediately; complete one in-flight request if any.
5. Sidecar process shutdown → all cached creds purged (process memory only; no disk persistence ever).

Tests required for Design E v1:
- `drop_event_purges_within_one_in_flight_request`
- `stale_broker_serves_until_ttl_then_refuses`
- `cold_start_during_broker_outage_refuses_all_proxy_requests`
- `scope_revoked_during_ttl_window_is_caught_at_refresh`
- `corrupted_drop_event_is_rejected_does_not_purge` (defense against fake drops by attacker)

---

## Comparison matrix

### Signer responsibility (dumbness gradient)

| Property | A (today) | B (OIDC-attested) | C-high | C-low | E (sidecar, rev 4) |
|---|---|---|---|---|---|
| Signer-side request validation | None — signs any bytes for a valid bearer JWT | JWT verify (K2 sig + scope claim + DPoP) | mTLS auth (broker-only) + typed payload validation | Same as C-high | Same as C-high (signer only talks to broker over mTLS, never to agent or sidecar directly) |
| KEK release predicate | "is bearer JWT valid?" | "is JWT signed by K2 ∧ DPoP fresh ∧ service ∈ scope?" | "is caller the broker over mTLS?" | Same as C-high | Same as C-high |
| Signer's signing surface | `/dev/sign-message` for any bytes (raw) | `/derive-service-kek` typed only | `/internal/derive-cred-kek` mTLS-only typed | Same as C-high | Same as C-high |
| Crypto primitives in signer | secp256k1 ECDSA + HKDF | Same + JWT verify + DPoP verify | Same + mTLS | Same as C-high | Same as C-high |
| New attack surface in signer | None vs today | JWT/DPoP parsing (mature OAuth code) | mTLS termination | Same as C-high | Same as C-high |

Trend: A < B < C in signer complexity. A is the dumbest signer (max security risk from "signs anything"); C makes the signer almost trivial again because it only trusts one caller (the broker over mTLS).

### Broker responsibility

| Property | A (today) | B (OIDC-attested) | C-high | C-low | E (sidecar, rev 4) |
|---|---|---|---|---|---|
| Broker state | None (uses mock-server) | Scope table only (read-heavy) | Scope table + transient nonce table (one-shot caps) | Same as C-high | Scope table + per-sidecar event-channel state |
| Broker in cred-fetch hot path | No | No (signer + S3 direct after session start) | **Yes** (every cred-fetch is broker round-trip) | Yes | **Yes — per TTL refresh** (~once per 5min per cred, not per LLM call) |
| Broker in LLM-call hot path | No | No | **No** (agent uses cached plaintext for LLM calls) | **Yes — proxy on every LLM call** | **No** (localhost only after sidecar has the cred cached) |
| Endpoint surface | Existing `/v1/mint-{oidc-jwt,aws-creds}` only | Add `/v1/mint-scope-jwt` (≤1 endpoint family) | Add `/v1/cap/cred-fetch` + `/v1/cred/fetch` (~3 endpoints) | Add `/v1/cap/invoke` + per-service proxy paths (~5+ endpoints, grows with upstream count) | Add `/v1/cap/cred-fetch` + `/v1/sidecar/events` SSE (~3 endpoints) — same backbone as C-high |
| Throughput requirement | Same as today | JWT mint every ~5min/agent | Per cred-fetch (typically ~once per task setup; not per LLM call) | Per LLM call (50-500/task) | Per cred TTL refresh (~once per 5 min while cred is in active use); per drop-event |
| Single point of failure for fetches | No | No | Yes (broker outage blocks cred-fetch; in-flight cached plaintext keeps working until task ends) | Yes (broker outage blocks every LLM call) | Yes for new fetches; cached creds survive outage for ≤TTL then expire (fail-closed) |

### Agent material exposure (this is the security crux per Q3)

Rev 4 honesty fix: the "agent holds nothing" property of E is true for *plaintext credentials* but NOT for the *operational capability* the credential represents. A compromised agent that passes Design E's controls (caller auth, scope binding, allowlist) can still drive the cached credential through the sidecar proxy for any allowlisted operation. The table below reflects this.

| Property | A (today) | B (OIDC-attested) | C-high | C-low | **E (sidecar, rev 4)** |
|---|---|---|---|---|---|
| What's in **agent** process memory (plaintext bytes) | KEK + plaintext (cacheable indefinitely) | KEK + plaintext (cacheable indefinitely) | Plaintext, briefly per fetch (~seconds–minutes) | Nothing | **Nothing — agent has only a localhost proxy URL** |
| What's in **sidecar/daemon** process memory | N/A | N/A | N/A | N/A | Cached plaintext credentials, lifetime = `cred_cache_ttl` (default 5 min) per cred |
| **Operational capability available to a compromised agent** | Decrypt any service's blob; mint OIDC; full STS abuse | Same as A within JWT TTL; KEK cached after | Use plaintext for one fetch's worth of upstream calls; broker denies next | Issue allowlisted requests via broker proxy | **Issue allowlisted requests via sidecar proxy until cred TTL expires** (mitigated by allowlist, quotas, audit — not by absence of plaintext) |
| Can compromised agent re-decrypt past blobs after revocation | Yes (KEK cached, deterministic) | Yes (KEK cached, deterministic) | No | No | No (never had KEK); BUT can replay allowlisted requests via sidecar until TTL+stale_threshold |
| Compromise blast radius if controls hold | Catastrophic | Catastrophic | One fetch's plaintext + its in-flight task | Whatever proxy round-trips happen during window | Allowlisted operations × spend quota × `cred_cache_ttl` for each in-scope service |
| Compromise blast radius if controls **fail** in E | N/A | N/A | N/A | N/A | **Same as having the plaintext: arbitrary upstream calls on every cached cred until purge.** Controls are load-bearing. |
| Sidecar-compromise blast radius | N/A | N/A | N/A | N/A | All credentials currently cached on that host. Trust boundary = host. |

This is where Design B's "KEK-caching attack" lives:
- Agent's omni pubkey is in `cnf.jkt`, so DPoP defeats *extraction* of the JWT.
- But once the legitimate agent calls signer for a service's KEK, **the KEK is in agent memory** and the deterministic derivation means it's the same KEK forever for that (wallet, service).
- Compromise the agent process at any time after first use → KEK extracted → all past/future blobs for that service decryptable, with no recourse short of K3 rotation.

Design A has the same problem (worse: any service's KEK is derivable just by asking the signer). Design C closes it categorically — KEK never leaves the broker-signer pair, so process-memory compromise yields at most one plaintext per compromise window.

### Revocation latency (rev 4 — honest bounds)

| Property | A | B | C-high | C-low | E (rev 4 with controls) |
|---|---|---|---|---|---|
| Session-JWT revocation | Instant at broker; STS creds outlive ~1h | Instant at broker; JWT expires in ~5min | Instant at broker; caps expire in ≤60s | Same as C-high | Instant at broker; affects next TTL refresh |
| Per-service scope tightening | STS-TTL window (~1h) AND KEK already cached forever | JWT-TTL window (~5min) AND KEK already cached forever | Instant (next fetch denied) | Instant (next proxy call denied) | **Up to `cred_cache_ttl`** (5 min default) for cached creds; instant for not-yet-fetched ones; broker push reduces typical case to seconds |
| Effective revocation latency (best case, broker reachable) | Effectively never (KEK cache) | Effectively never (KEK cache) | ≤next fetch | Next call | ≤1 RTT (broker push received → purge) |
| Effective revocation latency (typical, no push received) | Effectively never (KEK cache) | Effectively never (KEK cache) | ≤next fetch (typically minutes) | ≤next call | ≤`cred_cache_ttl` (5 min) |
| Effective revocation latency (worst case, broker unreachable) | Effectively never (KEK cache) | Effectively never (KEK cache) | ≤current fetch's plaintext lifetime, then broker outage blocks new fetches | Same as C-high; broker outage blocks all calls | ≤`cred_cache_ttl` (cached creds keep serving until TTL); after TTL, fail-closed |
| Adversarial worst case (push intercepted) | N/A | N/A | N/A | N/A | ≤`cred_cache_ttl` (push doesn't shorten the window if dropped/blocked) |
| Emergency lever | K3 rotation | K3 rotation OR K2 rotation | K2 rotation OR scope-table delete | Same as C-high | Broker `/v1/sidecar/drop` push + scope-table delete; or kill sidecar process |

### Complexity & operational properties

| Property | A | B | C-high | C-low | E (rev 4) |
|---|---|---|---|---|---|
| Code additions (LOC, very rough) | ~600 (shipped #87) | +~400 | +~1000 | +~2000 (proxy modes × per-upstream protocol) | +~1500 (proxy endpoint + lazy-fetch cache + controls + audit + fail-closed logic + tests) |
| New cryptographic primitives | AES-256-GCM | + JWT + DPoP | + mTLS PKI | Same as C-high | Same as C-high; sidecar trust comes from process boundary + SO_PEERCRED, not new crypto |
| New deploy artifacts | None (S3 bucket policy update) | None | Broker fetch endpoint + signer mTLS cert + nonce table (Redis/Dynamo) | Same as C-high + per-upstream proxy registration | Same as C-high + sidecar config (allowlists, quotas) + systemd unit ordering for daemon-before-agent |
| Cargo-test footprint | +9 unit tests (shipped) | +~15 tests | +~25 tests | +~40 tests | +~35 tests (proxy + cache + controls + revocation failure modes per rev 4 test matrix) |
| Migration from today | Done | One issue | One issue (broker fetch + signer mTLS + cap-token) | Multiple issues (per-upstream proxy + protocol support) | One core issue (daemon proxy + lazy-fetch + controls), plus optional per-tier issues for K8s sidecar (E2) / TEE (E3) |

The "effectively never" cells for A and B in the revocation matrix above are the real teeth of the deterministic-KEK trade-off. Once an agent has held a KEK in memory, revoking that agent's access to that service requires KEK rotation, which requires re-encrypting the blob (defeats the determinism that motivated the design in the first place). C-high, C-low, and E all escape this — they either never give the agent the KEK at all, or bound the agent's plaintext access to a short window that the broker controls.

---

## Q3 — Distribution mode vs one-time refreshed cred (the unification)

### Position

**Credentials do not need a distinct "distribution mode" category.** What I called distribution mode is structurally identical to "one-time refreshed cred" — both are short-lived material minted per-call from the broker, dropped after use, never persisted on the agent. The only difference is the form of the returned payload:

| Operation | Returned material form | Lifecycle |
|---|---|---|
| `fetch_credential(openrouter)` | Plaintext `sk-or-v1-...` | Use once, drop |
| `mint_memory_creds(prefix)` | AWS STS temp creds | Use for 15min, drop |
| `mint_email_creds(from)` | AWS STS temp creds bound to SES | Use once, drop |
| `mint_audit_sign_cap(row_hash)` | One-shot signer authorization | Use once, drop |

Same lifecycle, different payload type. They collapse into a single API shape:

```rust
trait BrokerCapability {
    fn mint(&self, request: CapRequest) -> Cap;
    fn redeem(cap: Cap) -> Material;   // Material is an enum over payload types
}

enum Material {
    PlaintextCredential(Vec<u8>),
    StsCredentials(AwsTempCreds),
    SignerAuthorization(NonceProof),
    UpstreamResponse(Bytes),           // for proxy mode
}
```

### Where the meaningful difference lives

The actual axis that matters is **agent material exposure**, not "mode":

| Exposure | What agent holds | Right deployment |
|---|---|---|
| **High** | Plaintext upstream credential | Local agent (operator's own machine) — operator already trusts hardware |
| **Medium** | Short-lived AWS STS temp creds | Any deployment — AWS enforces narrow scope at IAM layer |
| **Low** | Nothing — broker proxies the upstream call | Cloud agent (untrusted hardware), LLM provider sandbox |

Agents that consume credentials via `export OPENROUTER_API_KEY=... && run-task` already drop the credential at task end. That's high-exposure-but-ephemeral. Fine for local. For cloud agents, the cloud provider can introspect process memory, so high-exposure-even-briefly leaks. Low-exposure (proxy mode) is structurally required.

### How the exposure axis maps onto the named designs

Each named design lands on one or two points of the exposure axis:

| Design | Exposure level | Notes |
|---|---|---|
| A (shipped) | High | Agent holds KEK + plaintext; both persist in keychain / memory |
| B | High | Same exposure as A; B's only addition is JWT-DPoP binding, not exposure reduction |
| **C-high** | High (briefly) | Plaintext lives in agent process for one fetch's worth of upstream calls, then dropped |
| **C-low** | Low | Broker proxies every upstream call; agent never holds plaintext |
| **E (rev 4)** | Low for plaintext bytes; High for operational capability | Sidecar holds plaintext in memory for ≤`cred_cache_ttl`; agent has only a localhost proxy URL but controls bound the delegated-bearer capability |

The "low exposure" cell is achieved by two structurally different mechanisms — broker proxies (C-low) vs sidecar proxies (E). For the cloud-agent case both are equivalent on the "what does the agent process hold" axis; the differentiator is where the proxy actually lives (central in broker vs per-host in sidecar) and therefore who pays the LLM-call latency.

---

## Cloud-agent vs local-agent — collapsed into sidecar tiers (E only)

If Design E is picked for v1, the cloud-vs-local axis collapses into **sidecar deployment tiers** rather than per-call exposure switches. The agent code is identical across tiers — it always calls `http://localhost:9090/proxy/<service>/...`. What changes is where the sidecar runs and how strong its isolation is.

(If C-high is picked instead, the cloud-agent question reduces to "is the plaintext lifetime in the cloud-agent process short enough to be acceptable?" — typically yes for a one-fetch lifetime, but cloud-host memory introspection is still a real concern. For untrusted-host deployments, C-high should be combined with TEE-in-the-agent-process; this is heavier than E3's TEE-in-the-sidecar-process and probably not worth it.)

| Tier | Sidecar deployment | Trust boundary | Sidecar attestation |
|---|---|---|---|
| **E1 — Local** | Daemon on operator's laptop, plain process | Operator's machine | None (operator trusts own machine) |
| **E2 — Cloud-container** | Daemon as K8s sidecar container in same pod | Pod/container namespace | Optional SPIFFE SVID for broker auth |
| **E3 — Cloud-TEE** | Daemon inside Nitro Enclave / AMD SEV / NVIDIA CC | Hardware-rooted; host root excluded | Required: remote attestation to broker before bootstrap-cap is issued |

The deployment-tier choice is per-agent, set by master at provisioning:

```
deployment_policy[agent_wallet] = SidecarTier::E1 | E2 | E3
```

For E2/E3 the broker refuses to mint a bootstrap cap unless the sidecar produces the right attestation proof. That's a SPIFFE workload-attestation flow for E2, and a TEE remote-attestation flow for E3. Tier coverage grows incrementally:

- v1 ships E1 only. Same trust profile as today's daemon.
- v1.1 ships E2 (containerized sidecar). Enables cloud agents on K8s.
- v2 ships E3 (TEE-attested sidecar). Strongest available.

The agent code never changes across tiers — only the sidecar's deployment shape and attestation requirement.

---

## Sidecar mapping onto agentkeys (E1, today's structure, rev 4 lazy-fetch)

The daemon already plays the trust role this sidecar pattern wants. Mapping piece-by-piece:

| Sidecar requirement | Current daemon state | What needs to change |
|---|---|---|
| Runs on operator host as a local process | ✅ `agentkeys-daemon` is a local process | None |
| Holds session-JWT + keychain access | ✅ `session_store::SessionStore` + OS keychain | None |
| Has a local HTTP/IPC endpoint agents can call | ✅ MCP server on stdio/socket | Add an HTTP listener on Unix-socket-by-default (`$XDG_RUNTIME_DIR/agentkeys-proxy.sock`) for the proxy endpoints. TCP `localhost:9090` is opt-in via flag for container scenarios (E2). Unix-socket gives us `SO_PEERCRED` for free. |
| Can fetch credentials from broker | ✅ Session JWT can be exchanged for cap | Add `/v1/cap/cred-fetch` mint on broker; daemon calls it **lazily on first proxy request for each service**, NOT eagerly at startup |
| Holds plaintext credentials in memory | ❌ Today the daemon doesn't | Add a `credential_cache: HashMap<ServiceName, CachedCredential>` where `CachedCredential { plaintext, fetched_at, ttl: Duration }` — TTL default 5 min |
| Proxies upstream HTTP/SSE | ❌ Not implemented | New `proxy.rs` module: route `<sock>/proxy/<service>/<rest>` → upstream with injected `Authorization`, **after** passing the controls below |
| Caller authentication | ❌ N/A | Read `SO_PEERCRED` on the Unix socket; reject requests from UIDs not in the per-deployment allowlist |
| Per-caller scope binding | ❌ N/A | Sidecar config maps `(uid, binary_path) → allowed_services`; checked per request before fetch |
| Service/method/path allowlist | ❌ N/A | Per-service config: `{methods: [POST], paths: [/v1/chat/completions, /v1/messages], max_body_size: 1MiB}`; reject everything else |
| Spend quotas | ❌ N/A | In-memory token bucket per `(caller, service)`: req/min, req/hour, daily $ budget |
| Per-call audit | ❌ N/A | Audit row per proxy call: `{ts, caller_uid, service, method, path, status, request_id}` → local log + ship to broker `/v1/audit/append` |
| Rotation / drop signal handling | ❌ N/A | Long-lived SSE stream from broker `/v1/sidecar/events`; `drop` events purge the cache entry atomically; `rotate` events fetch fresh on next request |
| Fail-closed on stale broker | ❌ N/A | Track `last_broker_event_at`; if `now - last_broker_event_at > stale_threshold` (60s default), refuse new fetches; cached creds expire on per-cred TTL and aren't renewed |

The daemon binary stays a single process; the agent points its OpenAI/Anthropic/OpenRouter client at the daemon's Unix-socket URL instead of the public upstream. Existing `agentkeys store/read` CLI commands stay (operator-facing); they can continue to use the legacy fetch path until plaintext-export is fully deprecated.

### Wire shape (v1, rev 4 lazy-fetch)

```
# agent's first proxy request for a service
POST $XDG_RUNTIME_DIR/agentkeys-proxy.sock /proxy/openrouter/v1/chat/completions
  Headers: Content-Type: application/json
  Body:    { model: "...", messages: [...] }

  daemon:
    1. SO_PEERCRED → caller UID; reject if not in allowlist
    2. Look up (UID, "openrouter") in scope binding; reject if not allowed
    3. Validate method (POST) + path (/v1/chat/completions); reject if not allowed
    4. Token-bucket charge for (UID, openrouter); reject if exhausted
    5. credential_cache.get("openrouter") → CACHE MISS
    6. Mint cap-token from broker: POST /v1/cap/cred-fetch { service: openrouter, ttl: 300 }
    7. Redeem cap → POST /v1/cred/fetch { cap } → plaintext over TLS
    8. Cache plaintext with fetched_at=now, ttl=300s
    9. Inject Authorization: Bearer sk-or-v1-…
   10. Forward to https://openrouter.ai/v1/chat/completions
   11. Stream SSE response chunk-by-chunk back to localhost caller
   12. Emit audit row to broker /v1/audit/append (async, non-blocking)

# agent's subsequent proxy requests within the TTL window
POST $XDG_RUNTIME_DIR/agentkeys-proxy.sock /proxy/openrouter/v1/chat/completions
  daemon:
    1-4. (same as above)
    5. credential_cache.get("openrouter") → CACHE HIT (fetched 30s ago, TTL not expired)
    6. (skip broker mint)
    7. (skip broker redeem)
    8-12. (same as above, ~0.1ms total localhost overhead)

# broker drops a cred (master revoked scope)
SSE  /v1/sidecar/events           (broker → daemon)
  event: drop
  data:  { service: "openrouter" }
  daemon: atomically purge credential_cache["openrouter"]; one in-flight request
          completes; subsequent requests fall back to MISS path which will fail at
          step 6 (broker now denies the cap mint)
```

This is what today's daemon would look like with credential proxy added. No additional process. **Broker is in the cred-fetch path** (~once per 5 min per active service) **but not in the LLM-call hot path** (cached cred handles many LLM calls within the TTL window).

---

## UX walkthrough: child-device bootstrap (rev 4 — concrete scenario research)

This section walks **both finalists** through a real user scenario to test the abstract comparison against concrete operator friction.

### Scenario (as stated)

1. Master has stored credentials in agentkeys (Claude API key, Figma API key, possibly others).
2. User wants to bootstrap agentkeys on a child Ubuntu device.
3. User then wants to type **`claude`** (NOT `agentkeys spawn claude --`) to launch Claude Code.
4. Once Claude Code is launched, the user wants to call Figma MCP from inside Claude **without manual API key setting**.
5. agentkeys' own MCP server (`agentkeys-mcp`) is bound to the daemon; it doesn't need credential injection — it's the credential authority.

The third constraint is the load-bearing one: the user explicitly rejects the `op run -- claude` / `agentkeys spawn claude --` pattern that 1Password CLI and similar tools use. Bare `claude` invocation must just work.

### C-high user flow

C-high returns plaintext from the broker to the agent process; that process uses the credential for upstream calls directly.

```bash
# Bootstrap on child device (one-time)
$ agentkeys init --email child@example.org --broker-url https://broker.litentry.org
# → child device gets its session JWT

# To make `claude` work, ANTHROPIC_API_KEY must be in the env. Two options:

# --- Option C-high-A: shell rc hook ---
$ cat >> ~/.bashrc <<'EOF'
export ANTHROPIC_API_KEY=$(agentkeys read claude)
export FIGMA_API_KEY=$(agentkeys read figma)
# ...one line per service the user might use, enumerated in advance
EOF
$ source ~/.bashrc
$ claude   # works; plaintext keys in env

# --- Option C-high-B: PATH-shim wrappers (per command) ---
$ cat /usr/local/bin/claude
#!/bin/bash
export ANTHROPIC_API_KEY=$(agentkeys read claude)
export FIGMA_API_KEY=$(agentkeys read figma)   # for any MCP subprocess
exec /usr/local/lib/agentkeys/claude-real "$@"

$ claude   # works; plaintext keys in env subtree of THIS invocation
```

**Friction points:**

| Friction | Severity | Notes |
|---|---|---|
| Plaintext credentials live in shell env (Option A) or claude's process subtree (Option B) | Medium-high | Every command in the shell sees ANTHROPIC_API_KEY; every subprocess of claude inherits FIGMA_API_KEY. The credential's blast radius is the entire process tree. |
| User must enumerate services upfront | Medium | Shell hook needs to know which services to fetch. Adding Figma later = edit bashrc + re-source. |
| Per-invocation broker round-trips × N services | Low-medium | Option B does `agentkeys read X` per service per shim launch. For Claude with Figma, that's 2 broker round-trips per `claude` invocation (~200ms cold). |
| Rotation propagation is poor | High | Already-running shells / processes hold stale plaintext until restart. Master revokes scope at t=0; child's `claude` keeps working until shell exit. |
| MCP subprocess credential propagation | Medium | Figma MCP launched by Claude inherits `FIGMA_API_KEY` from claude's env → works. But ANY tool spawned anywhere in claude's subtree also sees it. Lateral-movement risk inside the agent process. |

### E user flow (rev 4 sidecar, lazy-fetch)

E exposes a localhost proxy. Claude code points at it via `ANTHROPIC_BASE_URL`; the sidecar substitutes the placeholder auth token with the real one when forwarding.

```bash
# Bootstrap on child device (one-time)
$ agentkeys init --email child@example.org --broker-url https://broker.litentry.org
# → child device gets its session JWT
# → daemon starts, opens Unix-socket proxy at $XDG_RUNTIME_DIR/agentkeys-proxy.sock
# → daemon writes ~/.config/agentkeys/env (auto-generated, regenerated on scope change)

$ cat ~/.config/agentkeys/env
# Auto-generated by agentkeys-daemon. Source from shell rc.
# For services that support base-URL override (pure-proxy mode):
export ANTHROPIC_BASE_URL=http://unix:$XDG_RUNTIME_DIR/agentkeys-proxy.sock/proxy/anthropic
export ANTHROPIC_AUTH_TOKEN=ak-sidecar
export OPENAI_BASE_URL=http://unix:$XDG_RUNTIME_DIR/agentkeys-proxy.sock/proxy/openrouter
export OPENAI_API_KEY=ak-sidecar
# For services that DON'T support base-URL override (plaintext fallback):
export FIGMA_API_KEY=fig-...real-key-here...   # ← see "Upstream tool support survey" below

# One-time shell rc hook
$ echo '[ -f ~/.config/agentkeys/env ] && source ~/.config/agentkeys/env' >> ~/.bashrc
$ source ~/.bashrc
$ claude   # works; Claude calls localhost proxy; sidecar injects real key
```

**Friction points:**

| Friction | Severity | Notes |
|---|---|---|
| Plaintext for **proxy-able** services never enters env or process tree | None | ANTHROPIC_AUTH_TOKEN=`ak-sidecar` is a placeholder; real key lives only in sidecar memory |
| Plaintext for **non-overridable** services (Figma today) DOES enter env | Medium | Falls back to C-high's exposure profile for that service. Documented per-service. |
| User must enumerate services upfront | None | Daemon manages the env file based on master-granted scope; new service = next time user re-sources |
| Per-invocation broker round-trips | None | First request per service per TTL window hits broker; subsequent requests in window are localhost-only |
| Rotation propagation | Good (proxy-able services) / Bad (non-overridable) | For ANTHROPIC: broker drop event → sidecar purges → next claude API call fails. For FIGMA (plaintext fallback): same as C-high, stale plaintext in env until shell restart |
| MCP subprocess credential propagation | Good for proxy-able services | Figma MCP that supports base-URL → inherits BASE_URL + placeholder. No plaintext. For non-overridable Figma MCP → plaintext fallback (same as C-high). |

### Upstream tool support survey (2026-05-17 research)

Whether E delivers its security advantage on each service depends on whether the upstream client supports a base-URL override.

| Service | Override env var | E mode |
|---|---|---|
| Anthropic Claude Code | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` ([Claude Code docs](https://code.claude.com/docs/en/llm-gateway)) | ✅ Pure proxy |
| OpenAI SDK (all langs) | `OPENAI_BASE_URL` | ✅ Pure proxy |
| OpenRouter | OpenAI-compatible, uses `OPENAI_BASE_URL` | ✅ Pure proxy |
| LiteLLM / Anthropic-compatible gateways | `ANTHROPIC_BASE_URL` (LiteLLM in proxy mode) | ✅ Pure proxy |
| Codex CLI | Config-file based; supports base URL via `OPENAI_BASE_URL` (OpenAI-compatible) | ✅ Pure proxy |
| Figma MCP (`figma/mcp-server-guide` official) | None documented — hardcoded api.figma.com | ❌ Plaintext fallback today |
| Figma MCP (open-mcp.org variant) | `OPEN_MCP_BASE_URL` + `FORWARD_VAR_*` ([open-mcp.org docs](https://www.open-mcp.org/servers/figma)) | ✅ Pure proxy |
| GitHub CLI / Copilot CLI | Hardcoded api.github.com | ❌ Plaintext fallback |
| Anthropic Workbench / direct REST | `ANTHROPIC_BASE_URL` | ✅ Pure proxy |

**Implication**: every major LLM client published by 2026 supports base-URL override. The gap is in domain-specific MCPs that wrap upstream APIs (Figma, GitHub, others). For these, E falls back to plaintext-in-env — at which point E reduces to C-high for that specific service.

**Path forward for non-overridable services**:
1. **Plaintext fallback (v1)**: E writes plaintext for non-overridable services to the env file. Documented per-service. Same blast radius as C-high for those services.
2. **Local TLS MITM via daemon-installed CA cert + DNS override (v2)**: daemon registers a local CA, overrides DNS for `api.figma.com` to `localhost`, MITM's the TLS, injects credential. Works without upstream tool support but is heavier and breaks tools that pin certs.
3. **Upstream contribution (v1.x)**: PR `OPEN_MCP_BASE_URL`-equivalent to popular MCP servers we care about (Figma, GitHub). One-time work, durable benefit.

### Comparison on the user's three constraints

| Constraint | C-high | E (rev 4) |
|---|---|---|
| **1. Bootstrap with single command on Ubuntu** | `agentkeys init` + add ~5 lines to bashrc (one per service) | `agentkeys init` + add 1 line to bashrc (`source ~/.config/agentkeys/env`); daemon manages the env file |
| **2. User types bare `claude` and it works** | ✅ via shell rc or PATH shim; plaintext in env tree | ✅ via base-URL override; **no plaintext for proxy-able services**; placeholder auth token only |
| **3. Figma MCP works without manual setting** | ✅ figma-mcp inherits `FIGMA_API_KEY` plaintext from claude's env | ✅ if MCP supports base-URL override (e.g., open-mcp.org variant); ❌→plaintext-fallback for the official Figma MCP server (same exposure as C-high for that service) |

### Implication for the C-high vs E decision (rev 4)

This UX scenario is **strictly favorable to E** on the dimensions the user cares about:

- **For LLM clients (Claude Code, OpenAI SDK, OpenRouter)** — every major one supports base-URL override. E delivers "agent has no plaintext credential, ever" with a single shell rc line. C-high cannot achieve this — it always requires plaintext in env or in subprocess subtree.
- **For MCPs without base-URL override (Figma official)** — E falls back to plaintext-in-env, **matching** C-high's exposure profile. E is never strictly worse than C-high on this axis.
- **For rotation propagation** — E's sidecar can purge cached creds on broker push, immediately denying subsequent localhost calls. C-high's plaintext-in-env requires shell restart (or process restart) to pick up rotations.
- **For operational friction** — E's daemon-managed env file means "master grants scope X → child's next shell sees X" automatically. C-high requires the user to edit bashrc per service.

**E is the right choice for v1 if** the team is confident it can ship Design E's controls (caller auth via SO_PEERCRED, per-caller scope binding, allowlist, quotas, audit, fail-closed) correctly. The UX evidence shifts the recommendation toward E.

The non-overridable-MCP case is the residual ugliness. v1 ships plaintext fallback (with explicit per-service documentation); v1.x ships upstream contributions to the MCPs we care about; v2 considers local TLS MITM as a generic answer.

---

## Integrated architecture: E + storage + KEK + sidecar-compromise defenses (rev 4.2)

How Design E integrates with the rest of the abstracted architecture (storage, broker policy, signer crypto). Answers three load-bearing questions:

### Storage layer — at rest

**Credentials are never stored in plaintext anywhere.** S3 holds AES-256-GCM-sealed envelopes, same wire format as Design A:

```
s3://$BUCKET/bots/<wallet>/credentials/<service>.enc
  =  1B version (0x01) || 12B nonce || ciphertext || 16B GCM tag
  AAD = "agentkeys.cred.aad.v1|" || lower(wallet) || "|" || service
```

**The load-bearing IAM change for E**: the bucket policy gives `s3:GetObject` on `bots/*/credentials/*` ONLY to `agentkeys-broker-role`. Sidecars and agents have **zero** S3 access to the credentials prefix. They can still have wallet-prefix-scoped read on other prefixes (memory, inbox, sent), but `credentials/` is broker-only.

This change is what enables the broker to act as the data-plane gatekeeper. Without it, a compromised sidecar with OIDC-scoped S3 read could fetch ciphertext directly and only need to defeat the KEK layer.

### KEK management

Yes, KEK is still required. Two viable approaches:

#### K-1 — Deterministic KEK via signer (recommended for v1)

```
KEK = SHA256("agentkeys.cred-derive.v1" || signer.sign_eip191(broker_omni, "agentkeys.cred.v1:" || wallet || ":" || service))
```

Same scheme as today's Design A, **but the omni is the broker's own omni, not the agent's**. The signer's `/internal/derive-cred-kek` endpoint is mTLS-only, broker-only. The sidecar and agent never call the signer at all.

**Why broker_omni instead of agent_omni in E**: in this design the credential's authorized reader is the broker (per the IAM change above). The KEK derivation should anchor on the broker's identity. Per-agent isolation comes from the broker's scope check, not from per-agent KEK derivation.

- **Pros**: stateless. KEK survives broker DB loss. Deterministic = recoverable.
- **Cons**: K3 compromise alone leaks all credentials. Mitigated by K3-in-TEE (arch.md §13, issue #74 step 2).

#### K-2 — Random KEK + broker-side wrap-table (Design D variant, v2 hardening)

Each credential gets `cred_kek = random(32)`. Broker holds a wrap-table: `(credential_id) → ECIES_encrypt(broker_pubkey, cred_kek)`. On decrypt: broker unwraps via signer's `/decrypt/ecies-wrap`, then AES-GCM-opens.

- **Pros**: K3 compromise alone is insufficient — attacker also needs wrap-table.
- **Cons**: load-bearing broker state (wrap-table backup/restore/integrity).

**Recommendation**: K-1 for v1. Layer K-2 in v2 only if K3-in-TEE doesn't ship. The marginal security from K-2 is small if K3 is already in a TEE.

### Decryption authority and plaintext-lifetime chain

```
agent ──localhost──▶ sidecar ──TLS──▶ broker ──mTLS──▶ signer
                       │                  │              │
                       │                  │              └─ holds K3
                       │                  │                 derives KEK on demand
                       │                  │                 returns 32-byte KEK to broker only
                       │                  │
                       │                  └─ reads ciphertext from S3 (broker-only access)
                       │                     receives KEK from signer
                       │                     AES-GCM-opens
                       │                     returns plaintext to sidecar over TLS
                       │
                       └─ caches plaintext in memory for cred_cache_ttl (5 min)
                          injects on agent's localhost calls
```

Plaintext lifetimes:

| Where | Duration | Reason |
|---|---|---|
| Broker memory | ~10ms per decrypt | Read S3 → call signer → AES-GCM-open → write TLS response. Zeroed after response. |
| Network broker→sidecar | In transit only | mTLS-encrypted |
| Sidecar memory | Up to `cred_cache_ttl` (5 min default) | Cached for amortized reuse; zeroed on TTL expiry or `drop` event |
| Agent process | **Never** | Agent only sees the localhost proxy URL + placeholder auth token (e.g., `ANTHROPIC_AUTH_TOKEN=ak-sidecar`) |

KEK lifetime: only in broker memory for the ~10ms decrypt window. Never crosses any network boundary other than mTLS broker↔signer.

### Sidecar-compromise threat model — 7-layer defense

The sidecar holds plaintext credentials in memory. If compromised, the attacker gets those plaintexts. The layered defenses bound that blast radius and force the attacker through multiple barriers:

#### Layer 1 — TTL-bounded plaintext (free in v1)
`cred_cache_ttl = 5 min` default. Compromise reveals at most one TTL window's worth of currently-cached creds. After TTL the plaintext is zeroed.

#### Layer 2 — Lazy fetch (free in v1)
Sidecar fetches a credential ONLY when an agent first requests it. The cache at any moment contains only services with active recent traffic. A master sidecar in scope for 20 services that's actively using 2 has 2 plaintexts in memory, not 20.

#### Layer 3 — Sidecar identity attestation at broker (mandatory for E2/E3, recommended for E1)
Broker refuses cred-fetch caps to unattested sidecars:
- **E1**: sidecar identity = `(operator_wallet, hostname, daemon_pubkey)` registered at first init; subsequent bootstrap proves possession via DPoP/cnf binding on the session JWT.
- **E2**: SPIFFE SVID — workload-attestation by SPIRE proves "this is the agentkeys-daemon container in pod X".
- **E3**: TEE remote attestation — broker validates AMD SEV-SNP / Intel TDX / Nitro report before issuing bootstrap cap.

A rogue daemon process can't fetch new creds because it can't produce valid attestation. **Combined with Layer 1: rogue sidecar can't acquire new plaintext; legitimate-but-compromised sidecar only holds the current TTL window.**

#### Layer 4 — Per-sidecar scope binding (v1)
Broker's scope table keyed by `(operator_wallet, sidecar_id)`. Compromise of one sidecar yields only what THAT sidecar was authorized for. Child-sidecar compromise ≠ master-sidecar compromise. Master sidecar is the highest-value target → most hardened (TEE if possible).

#### Layer 5 — Audit trail + anomaly detection (v1)
Every cap mint, cred fetch, and proxied call generates an audit row → broker → on-chain anchor or immutable log. Anomalies (10x normal fetch rate, fetches from new sidecar identity, fetches after revocation) trigger alerts. Post-hoc: doesn't prevent compromise but enables detection and faster revocation.

#### Layer 6 — Fail-closed on broker-unreachable (v1)
Sidecar tracks `last_broker_event_at`. If `now - last_broker_event_at > stale_threshold` (60s default): enters stale state, refuses new fetches, cached creds expire on schedule. An isolated compromised sidecar runs out of credentials within one TTL window.

Compromise + network MITM is strictly harder than compromise alone, and even both yield bounded blast radius.

#### Layer 7 — TEE deployment (E3, v2 hardening)
Sidecar inside enclave (AWS Nitro, AMD SEV-SNP, Intel TDX). Host root cannot inspect enclave memory. Attestation pins the broker's trust to a specific enclave measurement. **The only layer that defends against host-level compromise.**

### What's NOT defended against

| Threat | Status | Mitigation path |
|---|---|---|
| K3 compromise | Catastrophic — all creds decryptable | K3-in-TEE (issue #74 step 2). Independent of E. |
| Broker compromise | Catastrophic — can mint caps + decrypt anything | K1 in HSM + multi-party access + audit-anchored mints + broker replica voting (v2+). Independent of E. |
| Broker→signer link compromise | Attacker calls signer freely | mTLS with mutual cert pinning + IP allowlist. Standard deployment hardening. |
| Full sidecar process memory dump on E1 | All currently-cached plaintexts leaked | Only E3 (TEE) defends. E1 accepts host-trust assumption. |

### Summary: how E + abstracted design answers the three questions

1. **Are credentials stored in plaintext?** No. AES-256-GCM-sealed in S3 with `bots/<wallet>/credentials/<service>.enc` layout. Broker is the only IAM principal that can read this prefix.

2. **Do we need a KEK?** Yes — same deterministic KEK scheme as Design A (`KEK = SHA256(domain || signer.sign_eip191(broker_omni, ...))`). KEK lives only inside the broker-signer pair, never reaches sidecar or agent. K3-in-TEE is the planned hardening to bound K3-compromise risk.

3. **How do we gate credentials if the sidecar is compromised?** 7-layer defense: TTL-bounded plaintext + lazy fetch + sidecar attestation + per-sidecar scope binding + audit + fail-closed on broker stale + TEE deployment (v2). Layers 1-6 free or low-cost in v1; layer 7 is the v2 hardening for adversarial-host scenarios.

The integration preserves every property of the abstracted design (broker as policy decision point, signer as crypto vault, S3 as encrypted-at-rest storage) while adding the sidecar as a **plaintext-cache + agent-facing localhost proxy** — bounded by the 7 defense layers.

---

## Broker as policy-only authority — per-service worker split (rev 4.3)

Two follow-up architectural questions that decide the broker's long-term shape:

### Does on-demand KEK derivation at high RPS effectively keep KEK always in broker memory?

Statistically, at 100 cred-fetches/second × ~10ms KEK lifetime per derive, the aggregate KEK-presence is ~1 KEK-second per real second. The distribution matters more than the aggregate:

| Approach | KEK presence | Memory-snapshot exposure |
|---|---|---|
| **On-demand derive (current proposal)** | ~10ms per KEK at randomly-rotating heap addresses, then zeroed | A snapshot at any random instant catches ~0.1 KEK on average |
| **Cached KEK (5-min TTL to amortize signer calls)** | N services × persistent at fixed heap addresses | A snapshot catches all N KEKs deterministically |

On-demand is **strictly better against memory-disclosure attacks** (Heartbleed-style leaks, side-channel reads, cold-boot, RowHammer, process memory dumps): shorter lifetime + address rotation + small active set make per-KEK extraction probabilistically harder.

Against **full broker compromise** (arbitrary memory read + active signer connection), neither approach matters — a compromised broker derives any KEK at will. KEK caching only matters for *partial* memory-disclosure scenarios.

**v1 recommendation**: keep on-demand derivation. Do NOT cache KEK at broker. The signer round-trip (~5-10ms) is cheap; the security win is real. Scale signers horizontally (K3 read-only replicas in TEE cluster) if signer throughput becomes the bottleneck.

**v2 if memory-disclosure becomes a serious threat**: put **broker in TEE** rather than caching KEKs. Defends against host-level memory access without giving up the on-demand lifetime bound.

### Per-service worker split — broker becomes policy-only

The cleanest v2 architecture: split credential decryption (and other data-plane operations) OUT of the broker into per-data-class workers. Each worker has its own IAM role, its own deploy lifecycle, its own compromise blast radius. Broker becomes a thin authority that mints typed cap-tokens.

```
              ┌────────────────────────────────────────────┐
              │   BROKER (thin authority)                  │
              │   • Auth ceremonies                         │
              │   • Session JWTs                           │
              │   • Scope table                            │
              │   • Cap-token minting (typed per service)  │
              │   • Does NOT touch credential bytes        │
              └─────────┬───────────────────────┬──────────┘
                        │                       │
        mints typed cap-tokens                 │
                        │                       │
      ┌─────────────────┼───────────────────────┼─────────────────┐
      │                 │                       │                 │
      ▼                 ▼                       ▼                 ▼
┌──────────┐      ┌──────────┐           ┌──────────┐       ┌──────────┐
│ creds    │      │ memory   │           │ audit    │       │ email    │
│ service  │      │ service  │           │ service  │       │ service  │
│ (Lambda  │      │ (direct  │           │ (Lambda  │       │ (Lambda  │
│  + S3 +  │      │  S3 +    │           │  + chain │       │  + SES)  │
│  KMS or  │      │  STS     │           │  submit) │       │          │
│  signer) │      │  policy) │           │          │       │          │
└──────────┘      └──────────┘           └──────────┘       └──────────┘
      │                 │                       │                 │
      ▼                 ▼                       ▼                 ▼
   plaintext         AWS creds              tx receipt        send result
   over TLS          (narrow)               over TLS          over TLS
      │                 │                       │                 │
      └─────────────────┴───────────────┬───────┴─────────────────┘
                                        │
                                        ▼
                                    SIDECAR
                                    (consumes all four;
                                     handles each per its rules)
                                        │
                                        ▼
                                      AGENT
                                  (localhost only)
```

#### What the broker becomes (and stops being)

The broker reduces to:
- Auth (existing) — `/v1/auth/*`
- Session JWT (existing) — `/v1/session/*`
- Scope table (existing) — `/v1/scope/*`
- **Cap minting, typed** (new) — `/v1/cap/cred-fetch`, `/v1/cap/audit-sign`, `/v1/cap/memory-rw`, `/v1/cap/email-send`

The broker NO LONGER holds:
- ❌ Credential decryption authority — moved to credentials-service
- ❌ S3 read access on `bots/*/credentials/*` — moved to credentials-service IAM role
- ❌ Direct calls to the signer's `/derive-cred-kek` — moved to credentials-service

This is a real reduction in broker blast radius. Broker compromise lets the attacker mint arbitrary caps, but caps still have to be redeemed at the per-service workers, which enforce their own validation (cap signature check, scope verification at worker, IAM-level resource constraints).

#### Concrete shape: credentials-service as AWS Lambda

```
1. Sidecar holds cap-token signed by broker (K1)
2. Sidecar POSTs to https://creds-service.litentry.org/decrypt  (API Gateway → Lambda)
3. Lambda:
   - Verifies cap signature with broker JWKS (K1 pubkey)
   - Reads cap.service field
   - Reads s3://$BUCKET/bots/<wallet>/credentials/<service>.enc
   - Calls KMS Decrypt (or signer mTLS for KEK)
   - AES-GCM-opens
   - Returns plaintext as TLS response
4. Lambda's IAM role: ONLY s3:GetObject on credentials prefix + kms:Decrypt on cred CMK
5. Per-invocation CloudTrail log → free audit
```

**Pros**:
- Broker is pure policy, never touches plaintext bytes
- Per-service IAM tightly scoped to that service's needs
- Audit free via CloudTrail per Lambda invocation
- Scales independently per service
- KMS holds KEK in HSM-backed CMK (KEK never visible at application layer)
- Vendor-flexible: same shape on Tencent SCF + COS, Cloudflare Workers + R2, self-hosted microservice

**Cons**:
- Cold-start latency (~100ms) on idle. Mitigate with Lambda Provisioned Concurrency or always-on microservice.
- More moving parts (N services × N regions).
- Each service needs cap-verification logic (shared library is the right answer).
- Per-Lambda compromise leaks all of THAT service's creds (compartmentalization, not elimination).

#### Independent microservice variant

Same architecture, self-hosted:

```
1. agentkeys-creds-server binary (Rust, axum, like broker)
2. Runs anywhere — own EC2, K8s pod, Fly machine
3. Same wire contract as Lambda variant
4. Operator owns runtime — no vendor lock-in
5. Easier to attest (binary hash + TEE deployment)
```

For agentkeys' pluggability story (arch.md §6, China-deployment scenarios), microservice is probably the right default. Lambda is the AWS-native variant for managed-infrastructure operators.

#### What this gets on the security side

1. **Broker compromise** → attacker mints caps but per-service workers enforce their own checks
2. **One service compromise** → that service's data leaks; memory/audit/email unaffected
3. **Trust domains can be separate** — operator picks: broker self-hosted, credentials-service on AWS Lambda, audit-service on Ethereum, memory-service on Cloudflare R2. Each component replaceable.
4. **Broker becomes smaller, simpler, more auditable** — less code, less attack surface, eventual formal-verification path

#### Recommended phasing

- **v1**: monolithic broker holds credential-decrypt (along with everything else). Simpler to ship. Single deployable.
- **v2**: split out per-service workers. Start with credentials-service (highest-value isolation). Then audit-service, memory-service, email-service.
- **v3**: per-service workers in TEEs; multi-vendor backends; full trust-domain decomposition.

---

## Trustless-broker hardening: device co-signature + on-chain scope + Lambda decrypt (rev 4.4)

Four follow-up questions that compose into the v2/v3 architecture target where the broker is no longer the single trust root for credential access.

### Q1 — Prevent broker from impersonating a sidecar (device-key co-signature)

Today and through v1, the broker holds K1 alone and can mint any cap by signing it. A compromised broker is catastrophic. The defense is **mutual signing**: caps require both broker AND sidecar signatures.

#### Device-key co-signature

Each sidecar generates a **device keypair** at bootstrap. Stored in:
- E1 (local): TPM / Apple Secure Enclave / Android Strongbox / fTPM / fallback file
- E2 (container): SPIFFE SVID private key sealed to the pod
- E3 (TEE): inside the enclave, sealed by attestation

This device-key is **NOT derived from K3**, **NOT in the signer's domain**, **NOT known to the broker**. Only the sidecar's host holds it. Public key is registered with broker (and ideally on-chain — see Q2) at first bootstrap, proof-of-possession verified.

Cap-mint becomes a two-signature ceremony:

```
sidecar:
  request = { operator_wallet, service, ttl, nonce }
  sidecar_sig = sign(device_priv, hash(request))
  POST broker /v1/cap/cred-fetch { request, sidecar_sig }

broker:
  1. verify sidecar_sig against registered device_pubkey
  2. check scope_table[operator_wallet] ⊇ {service}  (or read on-chain per Q2)
  3. broker_sig = sign(K1, hash(request))
  4. return cap = { request, sidecar_sig, broker_sig }

worker (credentials-service / signer):
  1. verify sidecar_sig against device_pubkey (broker registry or chain)
  2. verify broker_sig against K1
  3. proceed only if BOTH valid
```

#### Threat coverage

| Attacker | Without device co-sig | With device co-sig |
|---|---|---|
| Compromised broker alone | Mints any cap with K1 → all creds exposed | Can't fake sidecar_sig (device-key not in broker memory); workers reject single-sig; **defended** |
| Compromised sidecar alone | Signs whatever; broker still scope-checks | Same — sidecar mints only within its scope; **no change** |
| Compromised broker + sidecar | Total | Total — but requires BOTH compromised |
| Compromised host root + broker | Total — root extracts device-key from disk | If device-key in TPM/SE/TEE: **defended** — root can't extract |

The device-key in TPM/SE/TEE is the strongest tier — even host root can't exfiltrate it; the chip performs sign operations under attestation. Compromised broker + compromised host root + no TPM-bypass = still can't mint caps.

### Q2 — Move scope table on-chain (single source of truth)

Moving scope on-chain eliminates broker-controlled scope mutations as an attack vector.

#### Option SC-A — Full on-chain scope (recommended)

```solidity
contract AgentKeysScope {
    mapping(address => mapping(address => Scope)) scope;  // operator → agent → scope
    struct Scope { string[] services; bool read_only; uint256 updated_at; }

    event ScopeUpdated(address indexed operator, address indexed agent, string[] services, bool read_only);

    function set_scope(address agent, string[] calldata services, bool read_only) external {
        scope[msg.sender][agent] = Scope(services, read_only, block.timestamp);
        emit ScopeUpdated(msg.sender, agent, services, read_only);
    }

    function get_scope(address operator, address agent) external view returns (Scope memory) {
        return scope[operator][agent];
    }
}
```

`msg.sender` is the master_wallet (derived from K3, signs tx). **No broker involvement in scope mutations.** Broker indexes chain events for fast reads; workers can also read on-chain directly (defense in depth).

Pros: master is sole scope authority; broker has zero mutation power; anyone can verify scope; immutable audit history; censorship-resistant (worker can honor caps that match on-chain scope even if broker dies).

Cons: chain confirmation latency (1-12s) per scope change; gas cost; scope updates are slow (acceptable — they're rare).

For agentkeys, the natural chain is **Litentry chain** (project home). Scope storage is the simplest possible contract.

#### Option SC-B — Off-chain scope, on-chain anchors

Master signs scope-update payloads off-chain (EIP-712); hash on-chain. Cheaper but workers must fetch Merkle proofs. Reserved as a v2.x optimization if SC-A's gas cost becomes a problem.

#### Combined with Q1

Broker's role in cap-mint shrinks to:
1. Verify sidecar_sig (device key)
2. Read scope from chain (not broker DB)
3. Co-sign cap

A compromised broker can only mint caps consistent with on-chain scope (workers double-check). Broker compromise can no longer escalate scope; scope is master-controlled and chain-anchored.

### Q3 — Can the broker be totally on-chain?

Theoretically interesting, practically infeasible for v1. Decomposition:

| Broker function | On-chain feasibility | Notes |
|---|---|---|
| Scope table mutations | ✅ Yes (Q2) | Covered above |
| Cap minting (per-call) | ⚠️ Slow + expensive | Each cap = chain tx + gas + 1-12s. ~100 caps/agent/day = prohibitively slow for interactive UX. |
| Cap signature verification | ✅ Yes | Smart-contract verify of chain inclusion. |
| Auth ceremonies (SIWE) | ✅ Yes | SIWE is chain-native. |
| Auth ceremonies (email-link / OAuth2) | ❌ No | Needs off-chain relay for email/OAuth callback. |
| JWT minting | ⚠️ Awkward | Chains don't produce JWTs natively. Need new cap format (EIP-712 typed sig) and consumer updates. |
| Real-time interactivity | ❌ No | Chain latency too high. |

**Honest assessment**: 100% on-chain broker is not feasible for v1. The right shape from Q1 + Q2 is **hybrid**:

- **On-chain**: scope table (master-controlled, chain-authoritative), sidecar device-key registry, cap-mint audit anchors, scope-update history
- **Off-chain (broker)**: real-time cap minting (signed by K1 + sidecar device-key, bounded by on-chain scope), interactive auth flows that touch external systems
- **Off-chain workers**: per-service workers consume caps, verify both signatures, cross-check on-chain scope independently

In this hybrid, the broker is reduced to:
- "Cap-minting accelerator" — faster than chain, but bounded by on-chain scope
- Pass-through for auth flows touching external systems (email, OAuth)
- JWT-format adapter for legacy consumers

#### Future direction (v3+) — ZK-proven cap minting

With ZK proofs, the broker could become a **stateless prover** that mints caps along with succinct proofs of "this cap is consistent with on-chain scope at block N". Workers verify the proof, not the broker's K1 signature. **Broker compromise no longer matters** — the proof can't lie about underlying truth.

Same shape as ZK-rollup sequencers: stateful for performance, but cryptographically constrained by an underlying truth source. Reserved for v3+; speculative but the destination of this architecture.

### Q4 — Lambda for encrypt/decrypt of S3 credentials

Yes. Concrete shape for both directions:

#### Decrypt (per rev 4.3)

```
sidecar → API Gateway → creds-decrypt Lambda
  Lambda:
    1. Verify broker_sig (K1 pubkey via broker JWKS)
    2. Verify sidecar_sig (device pubkey via on-chain registry or broker)
    3. Verify scope on chain (read ScopeContract.get_scope)
    4. Read s3://$BUCKET/bots/<wallet>/credentials/<service>.enc
    5. Fetch KEK via KMS Decrypt OR signer mTLS
    6. AES-GCM-open
    7. Return plaintext as TLS response
  Lambda IAM: ONLY s3:GetObject on credentials prefix + kms:Decrypt on cred CMK
```

#### Encrypt (symmetric)

```
master CLI → API Gateway → creds-encrypt Lambda
  Lambda:
    1. Verify broker_sig (caller is authenticated master)
    2. Verify master_sig on the new credential (master signed plaintext metadata)
    3. Read scope on chain → confirm caller is operator_wallet
    4. Fetch KEK from KMS or signer
    5. AES-GCM-seal plaintext, AAD = (wallet, service, version)
    6. Write s3://$BUCKET/bots/<wallet>/credentials/<service>.enc
    7. Emit on-chain audit event: CredentialUpdated(operator, service, blob_hash, block_number)
    8. Return success
  Lambda IAM: s3:PutObject on credentials prefix + kms:Encrypt on cred CMK
```

#### Two KEK backends

| Backend | Pros | Cons |
|---|---|---|
| **KMS** (AWS-native) | KEK in HSM-backed CMK, never visible at app layer; CloudTrail per-call audit free | $1/month per CMK; AWS-only |
| **Signer** (vendor-neutral) | Same scheme as Design A; works anywhere; no per-cred cost | Signer round-trip per encrypt/decrypt; signer needs scaling |

**Recommendation**: signer backend for v1 (consistent with rest of architecture, vendor-neutral). KMS backend as opt-in for AWS-only deployments.

### What the combined v2 architecture looks like

```
                 ┌──────────────────────────────────────┐
                 │   CHAIN (Litentry / EVM L2)         │
                 │   • ScopeContract (master-controlled) │
                 │   • SidecarRegistry (device pubkeys)  │
                 │   • AuditAnchor (cap-mint hashes)    │
                 └─────┬────────────────┬──────────────┘
                       │                │
              read scope                read sidecar pubkey
                       │                │
                       ▼                ▼
┌──────────────────────────────────────────────────────────┐
│  BROKER (thin authority, K1-only)                        │
│  • Verifies sidecar_sig (device-key co-sig)              │
│  • Reads scope from chain                                │
│  • Co-signs caps with K1                                 │
│  • Does NOT mutate scope, does NOT touch credential bytes│
└──────────────────────────────────────────────────────────┘
                       │
            cap (sidecar_sig + broker_sig)
                       │
        ┌──────────────┼─────────────────┐
        ▼              ▼                 ▼
   creds-Lambda   memory-Lambda     audit-Lambda
   ↓ verify both sigs                 (etc.)
   ↓ read chain scope (independent verify)
   ↓ decrypt/encrypt via KMS or signer
   ↓ return plaintext to sidecar over TLS
        ▲
        │
     SIDECAR (device-key in TPM/SE/TEE)
        │
        ▼
      AGENT (localhost only)
```

Trust roots in this architecture:
1. **Master wallet** (chain identity) — scope authority, sole mutator
2. **Sidecar device-key** (per-host) — capability requestor, sole cap-mint trigger
3. **Broker K1** — capability counter-signer, scope-bounded
4. **Signer K3** (in TEE per issue #74) — KEK derivation
5. **Chain** — scope storage, audit anchor

**Any single compromise is bounded**:
- Master wallet compromised → attacker can change scope on-chain; visible to everyone (audit trail), revocable by master-recovery flow
- Sidecar device-key compromised → attacker can mint caps within that sidecar's scope; per-sidecar blast radius
- Broker K1 compromised → attacker can co-sign caps but bounded by on-chain scope AND requires sidecar_sig; can't escalate beyond what's already authorized
- Signer K3 compromised → catastrophic (all KEKs derivable); mitigated by K3-in-TEE (issue #74)
- Chain compromised (51% attack on Litentry chain) → attacker can rewrite scope history; bounded by chain security properties

**No single trust root is sufficient for full credential access**. This is the architectural endpoint of the user-defined evolution.

### Phasing onto current work

- **v1 (next)**: monolithic broker, scope in broker DB, no device co-sig, broker holds K1 and decrypts. Same as rev 4.3 v1 recommendation. Ship E with controls.
- **v2.1**: Add device co-sig (Q1). Sidecars register device pubkey at bootstrap; broker requires it on cap-mint; workers verify it.
- **v2.2**: Split out creds-service as Lambda or microservice (rev 4.3 + Q4 detail). Broker no longer holds K1's cred-decrypt authority.
- **v2.3**: Move scope on-chain (Q2). Master signs scope-update tx; broker reads chain; workers double-check chain.
- **v3+**: Explore ZK-proven cap minting (Q3 future direction). Broker becomes stateless prover.

---

## Decision criteria for picking a v1 design (rev 4)

B is rejected categorically (doesn't close KEK-caching). C-low is rejected categorically (broker in LLM-call hot path). The real choice is **C-high vs E** — both close KEK-caching, both keep broker out of LLM-call hot path. Inputs that should drive the decision:

1. **Operator threat model for agent processes.** Treat agents as malicious-by-default → favor C-high (plaintext lifetime is one fetch's worth of upstream calls). Treat agents as buggy-but-not-malicious → E with controls is fine (5-min cache TTL).

2. **LLM-call frequency per task.** Low frequency (one task = one LLM call) → C-high's per-fetch overhead is invisible. High frequency (one task = 100+ LLM calls with streaming) → E's localhost-after-first-fetch latency is meaningfully better, especially for SSE.

3. **Cloud-agent priority in v1 timeline.** If E2 (containerized sidecar) or E3 (TEE-attested sidecar) lands in v1, E's structural fit dominates. If cloud-agent support is v2+, C-high's tighter plaintext-lifetime story wins.

4. **Schedule risk on E's controls.** Caller-auth via SO_PEERCRED is well-trodden but per-service allowlists, spend quotas, and the full fail-closed test matrix are new code. Can we ship E's controls correctly in v1, or do we slip and ship E without them (which would be strictly worse than C-high)?

5. **Audit fidelity demands.** Both C-high (broker logs each cred fetch) and E (sidecar logs each proxy call) generate per-operation audit rows. Equal on this axis. Difference: C-high's audit lives at the broker (central, compliance-friendly); E's lives at the sidecar (per-host, needs aggregation).

6. **Broker statefulness tolerance.** Both C-high and E require the broker to hold a scope table and (transient) cap-token nonce table. Equal on this axis. C-low would have required more (per-call routing state); E rev 4 doesn't.

### Recommendation (rev 4 — honest tradeoff between C-high and E)

After the rev 4 honesty pass, **the real finalists are C-high and E**. Both close the KEK-caching attack. Both keep the broker out of the LLM-call hot path. The honest comparison:

| Dimension | C-high | E (rev 4 with controls) |
|---|---|---|
| Plaintext lifetime in any process memory | Seconds–minutes per fetch (in agent) | Up to `cred_cache_ttl` (~5 min) per cred (in sidecar) |
| Compromise blast radius at a moment | One fetch's plaintext + its in-flight task | One sidecar's cached creds × `cred_cache_ttl` window × what the allowlist permits |
| LLM-call latency | ~50ms (signer call once, S3 once, then direct upstream) | ~0.1ms (localhost per call); ~100ms on first call after TTL expiry |
| Broker-outage tolerance | Cached plaintext keeps working until task ends; new fetches blocked | Cached creds keep working until TTL; new fetches blocked; fail-closed after |
| Trust-boundary location | Broker per fetch | Sidecar process + its controls (host trust + control correctness) |
| Operational complexity | Medium (broker fetch endpoint + signer mTLS) | Medium-high (proxy + lazy cache + controls + audit + fail-closed) |
| Path to TEE (E3-equivalent) | Harder — agent itself would need to run in TEE | Natural — the sidecar runs in TEE, agent stays normal |
| Path to cloud-agent (E2-equivalent) | Each cloud-agent fetches plaintext into untrusted memory | Cloud-agent has sidecar in same pod; plaintext never leaves sidecar |
| Aligned with 2026 production patterns | Less common (closer to JIT-vending Vault Agent variant) | Industry standard (Vault Agent default, Infisical, Aembit, Cloudflare local-mode) |

**The choice is genuinely contested.** Two reasonable positions:

#### Position A — Pick C-high. The cleaner security story.

Plaintext lifetime in agent process memory is bounded to one fetch's worth of upstream calls (seconds-to-minutes). No long-lived bearer capability sits around. The broker is in the credential-fetch path which means scope tightening propagates instantly to all future calls. Latency is acceptable (~50ms once per task, then localhost-to-upstream direct).

The cost is operational: agent code has to do the broker-fetch dance and drop the plaintext after use. Idiomatic library helpers can hide this, but it's "the agent handles credential lifecycle" vs E's "the agent ignores credential lifecycle".

#### Position B — Pick E (rev 4 with controls). The 2026 production-aligned story.

The sidecar pattern is what the production AI-agent ecosystem standardized on by 2026. Localhost latency is essentially free. Cloud-agent and TEE deployments slot in naturally as E2 and E3 tiers. Revocation is bounded (≤`cred_cache_ttl`) and explicitly fail-closed.

The cost is that the controls (caller auth, scope binding, allowlist, quotas, audit, fail-closed) **must** ship in v1 — they are not optional hardening. The sidecar IS a delegated bearer capability and the controls are what bound it. If we ship E without controls, a compromised agent has unbounded use of every cached credential. That's a bigger blast radius than C-high's per-fetch model.

#### Open decision (not yet made)

The doc presents both finalists. Picking between them is the next architecture call. Inputs that should drive the decision:

1. **Operator threat model for agent processes**: do we assume the agent process is malicious (→ favor C-high, shorter plaintext lifetime) or buggy-but-not-malicious (→ E with controls is fine)?
2. **LLM-call frequency per task**: low (→ C-high's per-fetch overhead is negligible) or high (→ E's localhost-after-first-fetch is meaningfully faster, especially with streaming)?
3. **Cloud-agent priority**: if E2/E3 lands in v1 timeline, E's structural fit dominates; otherwise C-high's tighter plaintext lifetime wins.
4. **Are we confident we can ship E's controls correctly in v1?** Caller-auth via SO_PEERCRED is well-trodden but per-service allowlists and spend quotas are new code. Schedule risk.

#### Common ground: skip A → B and never ship D

Regardless of C-high vs E:

- **B is out** — doesn't close KEK-caching (its motivating reason), adds complexity for no security gain.
- **D (wrap-and-rewrap) stays out of v1** — heavier broker state for marginal additional defense (K3-compromise resistance) that we'd rather get by putting K3 in a TEE.
- **C-low is out** — broker in LLM-call hot path is the anti-pattern we want to avoid; rev 4 keeps the rejection but for the right reason (only against C-low specifically, not against C-high).

#### Migration ladder

- **v0 (shipped)**: A — today's #87.
- **v1 (next big work)**: A → {C-high or E rev 4 with controls}. Decision pending per above.
- **v1.x**: If E was picked, ship E2 (containerized sidecar) for cloud agents.
- **v2 (hardening)**: TEE-attested signer (and, if E was picked, TEE-attested sidecar = E3). Wrap-and-rewrap (D) only if K3-TEE doesn't ship.

---

## Appendix: wrap-and-rewrap (Design D, for reference)

Briefly: instead of deterministic KEK, generate `cred_kek = random(32)` per credential. Wrap it under each authorized principal's ECIES pubkey; broker holds wrap-table. Decryption requires reading the wrap, unwrapping (signer's typed `/decrypt/ecies` endpoint), then AES-GCM-open.

Pros: defeats K3-alone compromise (attacker also needs wrap-table). Per-credential rotation is free.

Cons:
- Heavy broker state (wrap-table is load-bearing — backups, restore, integrity).
- Adding agent retroactively requires master/signer to be online (N signer calls).
- ~11ms CPU per store (vs ~1ms today).

Reserved as v2 hardening after C lands. Not in scope for v1.

---

## Revision log

- 2026-05-16 — initial doc. Three designs introduced (A, B, C); Q3 unification ("distribution mode = one-time refreshed cred for credentials"); exposure axis introduced; tentative skip-B recommendation. Appendix D (wrap-and-rewrap) added as v2 reference.
- 2026-05-16 (rev 2) — Added **Design E (sidecar credential injection)** after 2026 industry research (HashiCorp Vault Agent, Infisical Agent Vault, Aembit, Cloudflare local-mode, SPIFFE/SPIRE). Updated comparison matrix to four columns. Reframed Cloud-vs-local section as sidecar tiers (E1/E2/E3). Added concrete mapping onto today's `agentkeys-daemon` structure. **Recommendation updated: skip B and C; A → E is the right migration path.** B doesn't close KEK-caching; C puts broker in LLM-call hot path (anti-pattern per 2026 production deployments). Sidecar pattern keeps broker out of hot path while eliminating agent-side credential exposure.
- 2026-05-17 (rev 3 — adversarial review appended below) — Codex `/codex:adversarial-review` run against the doc. Three findings, two high, one medium. Recommendation is **blocked pending rev 4**: E's localhost-proxy threat model is underspecified, revocation claims overreach, and the C-vs-E comparison aggregates C-high and C-low in a way that biases the conclusion. See "Codex adversarial review (2026-05-17)" section below.
- 2026-05-17 (rev 4.4) — Added "Trustless-broker hardening: device co-signature + on-chain scope + Lambda decrypt" section. Answered four hardening questions: (Q1) prevent broker from impersonating sidecar via **device-key co-signature** (TPM/SE/TEE-held, never in broker or signer memory; caps require both broker_sig and sidecar_sig); (Q2) move **scope table on-chain** as single source of truth (master-signed scope-update tx, broker reads chain, workers can independently verify); (Q3) **fully on-chain broker is infeasible** for v1 (chain latency too high for real-time cap minting, external auth flows can't go on-chain) — recommended hybrid where scope/audit anchors are on-chain and broker is reduced to cap-minting accelerator + auth-flow relay; future direction is ZK-proven cap minting that makes broker stateless-prover; (Q4) **Lambda for encrypt/decrypt** works cleanly with both signer-backend KEK (vendor-neutral) and KMS-backend (AWS-native), per rev 4.3's per-service-worker split. Documented combined v2 architecture diagram with 5 trust roots (master wallet, sidecar device-key, broker K1, signer K3, chain), each with bounded compromise blast radius. Added phasing: v1 monolithic → v2.1 device co-sig → v2.2 creds-service split → v2.3 on-chain scope → v3+ ZK-proven minting.
- 2026-05-17 (rev 4.3) — Added "Broker as policy-only authority — per-service worker split" section. Answered two follow-up questions: (1) on-demand KEK derivation at 100 req/s is **strictly better** than caching against memory-disclosure attacks (statistical exposure ~0.1 KEK at any moment vs N KEKs cached at fixed addresses) — recommendation is no KEK caching in broker; for v2 high-throughput, put broker in TEE rather than cache. (2) Per-service worker split (credentials-service as Lambda/microservice + KMS or signer + S3) is the right v2 architecture — broker becomes thin policy-only authority, each data class gets its own worker with its own IAM and blast radius. Documented Lambda variant + independent microservice variant. v1 stays monolithic; v2 splits credentials out first.
- 2026-05-17 (rev 4.2) — Added "Integrated architecture: E + storage + KEK + sidecar-compromise defenses" section. Spelled out: (1) at-rest storage stays encrypted in S3 with broker-only IAM read; (2) KEK scheme is deterministic via signer under `broker_omni` (NOT agent_omni), exposed only via mTLS broker→signer; (3) 7-layer defense model for sidecar compromise — TTL, lazy fetch, attestation, per-sidecar scope, audit, fail-closed, TEE (E3). Documented residual threats (K3 compromise, broker compromise, full sidecar memory dump on E1) and their mitigation paths.
- 2026-05-17 (rev 4.1) — Added "UX walkthrough: child-device bootstrap" section with concrete user-flow comparison for C-high vs E. Researched upstream tool support for base-URL override (Claude Code's ANTHROPIC_BASE_URL, OpenAI's OPENAI_BASE_URL, Figma MCP variants). Survey shows every major LLM client supports base-URL override; gap is in domain-specific MCPs. **Conclusion**: E's UX is strictly better than C-high's for LLM clients (no plaintext in env tree, single bashrc line) and matches C-high for non-overridable MCPs via plaintext fallback. E is never strictly worse on this axis. The UX evidence **shifts the recommendation toward E**.
- 2026-05-17 (rev 4) — Addressed all three Codex findings:
  - **Finding [high] #1 (sidecar bearer capability)**: rewrote Design E to specify required controls (caller authentication via SO_PEERCRED/SPIFFE, per-caller scope binding, service/method/path allowlist, spend quotas, per-call audit, fail-closed on stale broker). Added "rev 4 — addresses Codex finding [high] #1" subsection. Updated agent-material-exposure matrix to honestly distinguish plaintext exposure (none in agent) from operational capability (bounded by controls). New row: "Compromise blast radius if controls fail in E" — explicit acknowledgement that the controls are load-bearing.
  - **Finding [high] #2 (revocation honesty)**: rewrote Design E's revocation semantics with concrete bounds: `effective_revocation = min(cred_cache_ttl, time_since_last_successful_broker_event + grace)`. Specified fail-closed rules for broker-unreachable / stale-event scenarios. Added required test matrix for revocation failure modes. Reframed Design E from "eager-bootstrap-and-hold-forever" to **lazy-fetch with short TTL** (~5 min default) — addresses both the bearer-capability lifetime and the revocation latency concerns.
  - **Finding [medium] #3 (C-vs-E aggregation)**: split Design C into named sub-variants C-high (broker-mediated fetch, agent uses plaintext for upstream) and C-low (broker proxies every upstream call). Updated all comparison matrices to five columns (A, B, C-high, C-low, E). Rejected C-low for the right reason (broker in LLM-call hot path) without dragging C-high down with it. **Recommendation revised**: C-high and E are now both finalists with genuine contested tradeoffs; the doc presents both honestly and lists the inputs that should drive the decision rather than pretending it's already settled.

---

## Codex adversarial review (2026-05-17)

> Verbatim output from `/codex:adversarial-review`, untouched. The findings here have NOT been addressed in the body of this doc — they are open issues against the rev 2 design and recommendation. Rev 4 must rewrite the affected sections before the A→E recommendation can be considered actionable.

### Verdict: needs-attention

No-ship: the document recommends A→E by undercounting E's new bearer-proxy risk and by comparing E against an over-worst-case version of C.

### Findings

#### [high] Sidecar proxy is treated as non-exposure even though it becomes a live bearer capability (docs/spec/credential-storage-design-comparison.md:37-43)

Design E exposes a localhost proxy to the agent, MCP clients, subprocesses, and other local callers, then claims the agent holds 'Nothing' and that compromised-agent blast radius is approximately zero or at most one in-flight request. That only follows if the sidecar authenticates the caller, binds requests to a session/scope, constrains service/path/method, rate-limits spend, and audits each call. None of those controls are specified in the E design or wire shape. From the doc as written, a compromised agent cannot read the raw key, but it can drive the cached credential through the proxy for arbitrary requests while the sidecar is alive, which is the operational capability the credential protects.

**Recommendation**: Rewrite E's security model to treat localhost proxy access as equivalent to a delegated bearer capability. Specify caller authentication, per-agent/session binding, service/path/method allowlists, quotas, request audit, and fail-closed behavior before claiming reduced blast radius.

#### [high] Revocation claims ignore cached plaintext and missed rotation signals (docs/spec/credential-storage-design-comparison.md:94-99)

E fetches credentials only at startup and rotation, caches plaintext for the whole sidecar lifetime, and relies on broker push or polling for refresh. The matrix still frames the broker as the policy authority and says revocation is bounded by refresh interval or instant with push, but the wire shape has no fail-closed rule for missed SSE events, offline sidecars, stale polling, or broker-unreachable operation. Inference from the documented design: a revoked service can remain usable through the local proxy until cache expiry, process kill, or upstream credential rotation, while the broker is intentionally out of the hot path and cannot deny each call.

**Recommendation**: State E's effective revocation bound as cache TTL plus rotation-delivery failure modes. Require short maximum credential TTLs, fail-closed proxy behavior when refresh/event streams are stale, explicit cache purge semantics, and tests for missed rotate/drop events.

#### [medium] The C-vs-E comparison aggregates C variants to make C look worse than the doc's own design allows (docs/spec/credential-storage-design-comparison.md:156-166)

Design C is introduced as broker-mediated credential fetch, while the later Q3 section explicitly splits C into high exposure (`fetch_credential` returns plaintext) and low exposure (`invoke_upstream` proxies). The recommendation then rejects C because it puts the broker in the LLM-call hot path for 50-500 calls per task. That is only true for C-low/proxy mode, not for C-high where the broker is in the credential-fetch path and the doc itself estimates about 10 credential fetches per hour. This aggregation makes the A→E recommendation look stronger by comparing E against the most expensive C mode instead of separating C-high, C-low, and E sidecar tradeoffs.

**Recommendation**: Split the matrix and recommendation into C-high, C-low, and E. Compare broker calls per credential fetch separately from broker calls per upstream request, and do not use LLM-call hot-path cost to reject all of C unless the chosen C variant actually proxies every LLM call.

### Next steps

Block the recommendation until E's localhost proxy threat model, revocation semantics, and C comparison rows are rewritten with separate failure modes and controls.
