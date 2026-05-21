# Architecture research notes

This directory holds **exploratory plans** that informed AgentKeys' Stage 7+ architecture decisions. They're versioned with the repo so the *why* of any future code lands has a paper trail.

These are research artifacts, not authoritative specs. The authoritative specs live in [`../spec/`](../spec/). When a research plan locks in, the corresponding spec doc is what changes.

## Contents

| File | Topic | Status |
|---|---|---|
| [`option-a-port-dexs-backend.md`](./option-a-port-dexs-backend.md) | Port [dexs-backend](https://github.com/dexs-k/dexs-backend)'s wallet-sig + email + OAuth flows into `agentkeys-broker-server`; minimal patch to Heima TEE worker for `CLIENT_ID_AGENTKEYS`. | Researched, not chosen yet |
| [`option-a-vs-b-port-vs-greenfield.md`](./option-a-vs-b-port-vs-greenfield.md) | Side-by-side comparison: port dexs-backend (A) vs greenfield broker designed around AgentKeys' problem domain (B). | Comparison artifact |
| [`option-c-pluggable-attestation-audit.md`](./option-c-pluggable-attestation-audit.md) | **Pluggable** auth / wallet-provisioning / audit-anchoring. Heima becomes one plug-in among several (Solana, Ethereum L2, AWS Nitro, S3 Object Lock, etc.). Zero Heima dependency in v0. | Researched, recommended for net-new branch |

## Background

The three plans grew out of a single question — *"what does `agentkeys init` actually do?"* — that surfaced a chain of architecture decisions:

1. AgentKeys' broker doesn't have a real auth backend yet (mock-server stub).
2. The natural reference is wildmeta's `dexs-backend` (Go-zero microservices stack) because it solves a similar shape.
3. But `dexs-backend` and Heima TEE worker are tightly coupled — porting one drags in assumptions from the other.
4. Heima TEE worker is single-tenant today (`client_id == CLIENT_ID_WILDMETA` hardcoded in [`tee-worker/omni-executor/rpc-server/src/methods/omni/user_login.rs`](https://github.com/litentry/heima/blob/main/tee-worker/omni-executor/rpc-server/src/methods/omni/user_login.rs)). Multi-tenant support requires an upstream patch.
5. The patch cost is asymmetric across Options A / B / C.
6. [`docs/arch.md` §11](../arch.md#11-audit-destination-is-pluggable) already established that **audit anchoring is pluggable**. Option C extends the same principle to two more layers.

## Tracking issues

Each plan has a corresponding issue tracking next steps:

- [#62](https://github.com/litentry/agentKeys/issues/62) — **OIDC federation deployment (deferred)**. Federation infrastructure ships in PR #61; the cloud-enforced PrincipalTag isolation acceptance test is deferred until auth lands.
- [#63](https://github.com/litentry/agentKeys/issues/63) — **Auth implementation (Option A path)**. Port `walletloginlogic.go` + `emailloginlogic.go` + `googleoauthcallbacklogic.go` to Rust in `agentkeys-broker-server`; coordinate the Heima `CLIENT_ID_AGENTKEYS` patch with Litentry.
- [#64](https://github.com/litentry/agentKeys/issues/64) — **Option C zero-Heima broker (separate branch)**. Pluggable architecture, no Heima dependency in v0; recommended branch `claude/agentkeys-pluggable-broker`.
