# Three-act storyboard — M1 MCP demo

Operator-readable script the [`smoke-test.sh`](./smoke-test.sh) drives Claude
Code through. Also the canonical source for the 15-min vendor pitch shipped
with #111. Storyboard derived from
[`docs/research/agent-iam-strategy.md`](../../docs/research/agent-iam-strategy.md)
§4.3.

The three acts walk the agent-IAM thesis end-to-end:

| Act | Question | Tools exercised | Layer of arch.md §17 isolation it demos |
|---|---|---|---|
| 1 | *Who is this agent, and what is it allowed to do?* | `identity.whoami`, `permission.check` | Layer 1 (broker cap-mint preconditions) |
| 2 | *Can the agent do a real thing with bounded blast radius?* | `cap.mint`, `memory.put`, `memory.get` | Layers 2 + 3 + 4 (worker chain-verify, IAM PrincipalTag scoping, per-data-class bucket separation) |
| 3 | *Can the operator see what the agent did?* | `audit.append`, off-chain envelope fetch, on-chain anchor lookup | The two-tier audit invariant from #109 |

Setup assumed:

- Session at `~/.agentkeys/$SESSION_ID/session.json`
- Actor omni resolved from session (`agentkeys_user_wallet` per arch.md canonical names)
- Broker live at `$AGENTKEYS_BROKER_URL`
- Claude Code CLI authenticated with `agentkeys-mcp` server registered per
  [`claude-config.json`](./claude-config.json)

---

## Act 1 — Agent identity + permission boundary

**Story beat**: "Before this agent moves a finger, it has a verifiable
identity, and the broker can answer in milliseconds whether a given action is
in scope — without any LLM in the loop."

**Storyboard prompt for Claude Code** (drives tool selection):

> Using the agentkeys MCP server, tell me everything you can about this actor:
> their omni, display name, vendor, and scopes. Then check whether they are
> allowed to read memories in the `trips` namespace. Then check whether they
> are allowed to send a $999,999 payment. Report both verdicts and the
> broker's reason strings.

**Expected tool sequence**:

1. `agentkeys.identity.whoami(actor=$ACTOR_OMNI)`
   → `{omni, display_name, vendor, scopes: [...]}`
2. `agentkeys.permission.check(actor=$ACTOR_OMNI, scope='memory.read', namespace='trips')`
   → `{allowed: true, reason: "in_scope"}`  (assuming scope grant exists)
3. `agentkeys.permission.check(actor=$ACTOR_OMNI, scope='payment.send', amount=999999)`
   → `{allowed: false, reason: "scope_not_granted"}` OR `"amount_exceeds_cap"`

**Assertion**:

- `whoami.omni == $ACTOR_OMNI`
- The deny verdict comes from the **policy engine, not an LLM**
  (`permission.check` is deterministic per #107 + `agent-iam-strategy.md` §2.4).
  Run act 1 ten times — same input must produce same output.

**Layer 3 (Claude Code) failure mode caught here**: if `permission.check`'s
tool description is ambiguous, the LLM may instead route through `cap.mint`
and let the broker reject — which works but is slower and emits an audit row
for a no-op. The tool description must steer the LLM to the cheap precheck.

---

## Act 2 — Capability-gated memory operation

**Story beat**: "When the agent does act, it must mint a fresh capability
scoped to one operation, one namespace, one bounded TTL. The capability is
signed by the broker AND co-checked by the worker on every call — no single
compromise opens the blast radius."

**Storyboard prompt for Claude Code**:

> The user wants to save this trip memo to their `trips` namespace:
> "Chengdu, May 2026 — visited Wuhou Shrine; jiaozi at Long Chao Shou Cantine."
> Mint the right capability, store it, then read it back to confirm.
> Then try to read from the `medical` namespace using the same capability —
> we expect that to be rejected.

**Expected tool sequence**:

1. `agentkeys.cap.mint(actor, op='memory.put', namespace='trips', ttl=300)`
   → cap-token JWT with `data_class: Memory`, `namespace: trips`
2. `agentkeys.memory.put(actor, namespace='trips', content=...)`
   → `{ok, version}`
3. `agentkeys.memory.get(actor, namespace='trips')`
   → returns the same content
4. `agentkeys.memory.get(actor, namespace='medical')` using the trips cap
   → **HTTP 403 `cap_namespace_mismatch`** (worker rejects per #108 signed-namespace invariant)

**Assertion**:

- Roundtrip content matches byte-for-byte
- The cross-namespace negative MUST be rejected at the worker (not the
  broker) — that proves the worker's independent re-verification works
  (arch.md §17 layer 2)
- The cap-token's `namespace` field is **signed** in the payload, not just
  a query param — symmetric with `data_class` per arch.md §17.2

**Layer 3 failure mode**: if `cap.mint`'s description doesn't make the
`ttl` + `namespace` parameters obvious, the LLM may omit them and rely on
defaults — which then fails downstream with a confusing error. The tool
descriptions must front-load the required-vs-optional split.

---

## Act 3 — Audit visibility (two-tier)

**Story beat**: "Every action the agent takes is visible to the parent in
two places: a real-time off-chain feed (<1s) and an on-chain anchor (≤2min)
that no one — including us — can rewrite."

**Storyboard prompt for Claude Code**:

> Append an audit envelope for the memory.put action you just did. Use op_kind
> MemoryPut, result Success. Then fetch the off-chain envelope by hash to
> confirm it's queryable, and report the envelope_hash so the operator can
> see it land on chain in the next 2 minutes.

**Expected tool sequence**:

1. `agentkeys.audit.append(actor, op_kind='MemoryPut', op_body=..., result='Success')`
   → `{envelope_hash: 0x...}`
2. `GET $AGENTKEYS_BROKER_URL/v1/audit/envelope/<hash>`
   → `AuditEnvelope v1` (CBOR-decoded JSON: version, ts_unix, actor_omni,
   operator_omni, op_kind, op_body, result)
3. Poll on-chain `CredentialAudit.AuditAppendedV2(operatorOmni, actorOmni, opKind, envelopeHash)`
   for `envelopeHash == <hash>` (block-explorer or `cast logs`)
   → must appear within 2 min per #109 SLA

**Assertion**:

- Off-chain envelope queryable < 1s after append
- On-chain anchor lands ≤ 2 min (tune `agentkeys-worker-audit` batch cadence
  if not — default is "1 min or 256 events" per arch.md §15.3)
- `envelope_hash == keccak256(canonical_cbor(envelope))` — verifiable client-side

**Layer 3 failure mode**: an LLM may try to "read the chain directly" via a
generic web-search tool instead of `audit.append` → `/v1/audit/envelope/`.
The MCP server's audit tools should be the obvious one-stop affordance.

---

## End-of-act summary printed by the smoke test

```
act 1 — identity + permission boundary
  ok   whoami resolved $ACTOR_OMNI
  ok   permission.check memory.read/trips → allowed
  ok   permission.check payment.send → denied (policy-engine, deterministic)
act 2 — capability-gated memory operation
  ok   cap.mint memory.put/trips ttl=300 → cap-token issued
  ok   memory.put → stored at version 1
  ok   memory.get → roundtrip byte-match
  ok   memory.get cross-namespace → 403 cap_namespace_mismatch (worker enforced)
act 3 — two-tier audit visibility
  ok   audit.append → envelope_hash=0xabc...
  ok   GET /v1/audit/envelope/0xabc... → AuditEnvelope v1 (<1s)
  ok   on-chain AuditAppendedV2 visible at block N (≤2min)
all acts green
```

This block is the canonical demo evidence to attach to the PR description per
the [plan-completion policy](../../CLAUDE.md#plan-completion-policy).
