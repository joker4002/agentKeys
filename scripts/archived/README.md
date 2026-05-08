# Archived scripts (pre-Stage-7)

These scripts shipped with the Stage 6 broker and are kept here for
historical reference. **Do not use them for new Stage 7+ work** — the
auto-provision pipeline they automated has been replaced.

| Archived script | Stage 7 replacement |
|---|---|
| `stage6-demo-env.sh` (workstation env + `aws sts assume-role`) | `scripts/operator-workstation.env` (set vars only — broker mints creds via `/v1/mint-oidc-jwt`, no manual AssumeRole) |
| `stage6-demo-run.sh` (one-off scraper run) | `agentkeys-cli provision --service openrouter` against `AGENTKEYS_BROKER_URL=https://broker.litentry.org` (see `docs/stage7-demo-and-verification.md §16.7`) |
| `stage6-inspect-email.sh` (S3 inbound-email dumper) | `scripts/inspect-inbound-email.sh` (same logic, rebadged + Stage-7-compatible env loading) |

The Stage 6 scripts hard-coded `sts:AssumeRole` against the data role's
trust policy as the broker's daemon IAM user. After cloud-setup.md §4
the trust policy is OIDC-federated, so those scripts return
`AccessDenied` even when their env wiring works. They're left here for
forensic reference; replacement scripts use the federated path.
