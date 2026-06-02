# Plan

Agent-authored implementation plans (Claude, codex, ralph) drafted **before** the code lands. Each file describes the intended change, the stages, and the verification.

## Promotion / archival

- When the plan's code ships and you want to keep the contract durable (interfaces, protocol shapes, terminology), **promote** the file to `../spec/` and update [`../arch.md`](../arch.md) to link to it.
- Otherwise, **archive** to `../archived/`. Plans for shipped work do not accumulate here.

## Style

Plain markdown. No YAML frontmatter. Link to repo files with `../../<path>` and to other docs with `../<file>.md` or `../spec/<file>.md`.

See the `agentkeys-docs` skill for the full layout policy.

## Canonical roadmap + runbook

These two are the live source-of-truth pointers referenced from [`../arch.md`](../arch.md) and `CLAUDE.md`. Keep them current; don't archive.

- [`milestones-roadmap.md`](milestones-roadmap.md) — the M1–M7 milestone roadmap (replaces the archived v1/v2 staged plan).
- [`execution-plan.md`](execution-plan.md) — orchestration runbook (ralph, team, ultraqa workflows).

## Active plans

- [`agentkeys-memory-design.md`](agentkeys-memory-design.md) — memory worker design (single file).
- [`ceo-plan.md`](ceo-plan.md) — v0 product approach (Minimal Viable Tool). Foundational vision; largely superseded by `milestones-roadmap.md` for sequencing — keep for the DX/mock-backend contract framing.
- [`issue-103-aiosandbox-hermes-esp32-demo.md`](issue-103-aiosandbox-hermes-esp32-demo.md) — M1 ESP32 demo tracking doc. **Partially superseded:** sections C4/C5/C6 are stale (architecture moved to Hermes + MCP + hooks); the forward path is `phase-1-fresh-user-wire-onboarding.md`.
- [`issue-107-mcp-demo-runbook.md`](issue-107-mcp-demo-runbook.md) — two-mode MCP demo runbook (light in-memory / real broker).
- [`issue-74-step-1c-device-key-auth.md`](issue-74-step-1c-device-key-auth.md) — v1c device-key auth (HDKD per-agent omni + WebAuthn-uniform binding).
- [`issue-82-erc7730-v2-aligned.md`](issue-82-erc7730-v2-aligned.md) — ERC-7730 signing-display + intent-aware audit (M3/M4).
- [`issue-credential-storage-s3-oidc.md`](issue-credential-storage-s3-oidc.md) — S3-backed AES-256-GCM credential store replacing the mock-server `/credential/*` endpoints.
- [`phase-1-fresh-user-wire-onboarding.md`](phase-1-fresh-user-wire-onboarding.md) — fresh-user `agentkeys wire <runtime>` onboarding journey to the Agent IAM "surprise".
- [`phase1-wire-harness-test-plan.md`](phase1-wire-harness-test-plan.md) — two-mode test plan for the wire harness.

## Multi-file plan directories

- [`chain/`](chain/) — ERC-4337 P-256 smart-account master ([`chain/erc4337-master-account.md`](chain/erc4337-master-account.md) + [`chain/erc4337-threat-model.md`](chain/erc4337-threat-model.md)).
- [`web-flow/`](web-flow/) — parent-control web UI operator user flow. Binds harness v2-stage {1,2,3} flows to UI screens with real inputs (no mock data). Start at [`web-flow/README.md`](web-flow/README.md).
- [`v2-issues/`](v2-issues/) — v2 architecture roadmap issues (sovereign sidecar + on-chain scope/registry, multi-master recovery, deferred payment service). Future GitHub issues, not yet filed.
