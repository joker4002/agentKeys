# AgentKeys — Wiki

> **This wiki is auto-generated from the `wiki/` folder in the main repo.**
> Edit the source files there, not through the web UI — direct edits will be
> overwritten on the next push to `main`. The canonical source is
> [`wiki/` in `litentry/agentKeys`](https://github.com/litentry/agentKeys/tree/main/wiki).

AgentKeys is a credential custody service: a TEE-backed vault that issues long-lived bearer tokens for per-agent credential access, with on-chain audit.

## Pages

- [Home](Home) — you are here.
- [Blockchain TEE Architecture](blockchain-tee-architecture) — how AgentKeys rides Heima TEE for signing + credential custody.
- [Credential Usage](credential-usage) — lifecycle of a credential from store → run/read → revoke.
- [Data Classification](data-classification) — what each data class is, where it lives, how long it stays.
- [Key Security](key-security) — TEE keys, master session key (MSK), storage tiers, threat model.
- [Serve and Audit](serve-and-audit) — Pattern-4 per-read audit flow.
- [Session Token](session-token) — 30-day bearer credential — what it is, how it's protected.

## Related documents in the main repo

- [`README.md`](https://github.com/litentry/agentKeys/blob/main/README.md)
- [`docs/spec/plans/development-stages.md`](https://github.com/litentry/agentKeys/blob/main/docs/spec/plans/development-stages.md) — 8-stage build plan.
- [`docs/spec/architecture.md`](https://github.com/litentry/agentKeys/blob/main/docs/spec/architecture.md)
- [`docs/manual-test-stage4.md`](https://github.com/litentry/agentKeys/blob/main/docs/manual-test-stage4.md) — human-reviewable end-to-end walkthrough.
- [`docs/contradictions.md`](https://github.com/litentry/agentKeys/blob/main/docs/contradictions.md) — living tracker of cross-doc contradictions and their resolutions.
- [`docs/field-name-translation.md`](https://github.com/litentry/agentKeys/blob/main/docs/field-name-translation.md) — "translate at the layer closest to the human" design note.

## How to edit this wiki

1. Open `wiki/<Page>.md` in the main repo.
2. Make changes in a PR.
3. Merge to `main`.
4. The `Publish wiki` GitHub Action mirrors `wiki/**` to the wiki repo.

A maintainer can also trigger the mirror manually from the repo's Actions tab — the workflow exposes `workflow_dispatch` for re-runs against an unchanged `wiki/` tree.

See `.github/workflows/publish-wiki.yml` for the implementation.
