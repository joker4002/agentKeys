# Stage 4 Manual Test Guide

The full historical Stage 4 manual test guide lives at
[`docs/archived/manual-test-stage4.md`](archived/manual-test-stage4.md).

## Credential Read Rate Limit

Verify that the v0 mock backend enforces the default 100 reads/minute/session
cap, keeps buckets per session, honors creation-time overrides, and writes a
distinguishable `rate_limit_exceeded` usage row:

```bash
cargo test -p agentkeys-mock-server credential_rate_limit -- --nocapture
```

Expected result: all `credential_rate_limit_*` tests pass.
