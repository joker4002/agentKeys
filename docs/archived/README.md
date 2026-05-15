# Archived docs

Documents in this directory were current at a prior snapshot and are preserved for historical reference. **Do not use them as setup / demo guides.**

Superseded by the current top-level docs:

| Archived file(s) | Superseded by |
|---|---|
| `development-stages-v1-2026-04.md` (1623 lines, Stage 0→9 full history) | [`../spec/plans/development-stages.md`](../spec/plans/development-stages.md) — concise Shipped/Active/Planned summary |
| `manual-test-stage4.md`, `manual-test-stage5.md`, `manual-test-stage6.md`, `stage5-workspace-email-setup.md` | [`../dev-setup.md`](../dev-setup.md) — single developer onboarding + demo guide |
| `manual-test-issue-{12..17}.md`, `manual-test-report-issues-12-17.md` | One-shot per-issue manual tests from Stage 4 — results folded into the Stage 4 test suite; kept for audit trail only |
| `operator-runbook-pre-stage7.md` (was `../operator-runbook.md`) | [`../operator-runbook-stage7.md`](../operator-runbook-stage7.md) — Stage-7+ broker (post-issue-#71 OIDC-only mints, post-issue-#74-step-1 dev_key_service signer) |
| `contradictions-stage4-2026-04.md` (was `../contradictions.md`) | Audit snapshot taken 2026-04-14 against Stage-4-implementation-complete + 17 open issues. The decisions it captured have either landed or been re-scoped; no live successor — Stage 7+ design discussions live under [`../spec/plans/issue-64/`](../spec/plans/issue-64/) and [`../spec/plans/issue-74-dev-key-service-plan.md`](../spec/plans/issue-74-dev-key-service-plan.md) |
| `field-name-translation.md` (was `../field-name-translation.md`) | Stage-4-keychain-output design note. Subsumed by the Stage-7 daemon's session/wallet representation; kept for the historical "why we sed-pretty-printed `security(1)`" reasoning |

## Archive policy

- Move a doc here when it has been **fully replaced** by a newer doc (not just updated).
- Leave a `Superseded by:` pointer at the top of the archived copy if the replacement isn't obvious from the filename.
- Never delete — the archive is the project's historical record and feeds future design reviews.
- Fresh developers: skip this directory. Start at [`../dev-setup.md`](../dev-setup.md) and [`../spec/plans/development-stages.md`](../spec/plans/development-stages.md).
