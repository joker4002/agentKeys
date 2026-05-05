# Stage 7 — Issue #64 — Decisions Log

## Process decisions (locked)
- **D1 — Plan home:** `docs/spec/plans/issue-64/PLAN.md` (mirror of `~/.claude/plans/now-i-just-merged-idempotent-plum.md`). Updates in this file overlay the master plan.
- **D2 — Branch independence:** Work on `claude/dazzling-mirzakhani-2a06bc` only. No `jj rebase` / no `git merge` from sibling branch `claude/quizzical-ellis-d6f1e9`. Verbatim artifact harvesting allowed only after rewrite per user rules in plan §1.
- **D3 — Reviewer:** codex (per `--critic=codex`). Each phase ends with at least one codex round; stop rule = 2 consecutive rounds of same-severity P2 → ship.
- **D4 — Per-story commit:** `git commit` inside the worktree, one commit per US-* story. Format: `agentkeys: stage 7 issue#64 phase <N> -- US-NNN <deliverable>`.
- **D5 — VCS tool exception:** This worktree is a git worktree at `.claude/worktrees/dazzling-mirzakhani-2a06bc/`, not a jj workspace. Global CLAUDE.md says "use jj for all version control," but jj's working copy is the main repo at `/Users/agent-jojo/Projects/agentKeys/` — it cannot see edits inside this worktree. Pragmatic exception: use `git` for commits inside the worktree. After PR merges to `main`, jj on the main repo will see them via `jj git fetch`.

## Architectural decisions (locked from plan defaults)
- **A1 — Wallet-sig wire format:** SIWE (EIP-4361) wrapping EIP-191. Closes codex P0 #2.
- **A2 — Per-call daemon signature on mint:** Required. Closes codex P0 #5.
- **A3 — EmailLink first form:** magic-link with fragment-token + POST verify + CLI polling.
- **A4 — Backwards compat:** `POST /v1/auth/exchange` shim (legacy bearer → session JWT once at startup). No dual-accept on `/v1/mint-aws-creds`.
- **A5 — OAuth2 v0 provider:** Google only.
- **A6 — OAuth2 multi-tenant:** Single-tenant for v0 (broker holds Google client credentials).
- **B1 — Recovery threat model:** Master-gated via new capability grant. Email-only rebinding rejected (codex P0 #4).
- **B2 — Capability grants:** First-class endpoints + audit_proof signature.
- **C1 — Audit policy:** `dual_strict` default.
- **C2 — Gas-drain mitigations:** All four (per-identity rate, daily budget, min-balance, pre-tx check).
- **C3 — Speculative STS:** Allow, gate response on audit-write success.
- **C4 — Testnet target:** Base Sepolia.
- **D1 — Refuse-to-boot tiering:** Tier-1 config-only sync + Tier-2 boot-to-Unready async.
- **D2 — SES cache:** persisted 24h TTL.
- **D3 — /readyz JSON:** per-check status + reason + docs URL.
- **E1 — Phase ordering:** 0 → A.1 → A.2 → C.0 → B → C → D-rest → E.
- **E2 — Codex stop rule:** 2 consecutive same-severity P2 rounds, with independent prompts and explicit user sign-off on residual P2s.
- **E3 — Production-ready definition:** single-operator EC2 + runbook + 30-min restore drill from SQLite snapshot.

## Open meta-questions (carried into next iteration)
- **M1 — Primary v0 testnet consumer:** Both agents and human devs (current default).
- **M2 — Recovery hard gate:** Yes (Phase B.2 ships in v0).
- **M3 — End-to-end measure:** Operator deploy success (current default).

Per-phase decisions appended below as work proceeds.
