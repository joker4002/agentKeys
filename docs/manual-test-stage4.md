# Stage 4 Manual Test Guide

**Prerequisite:** Rust toolchain installed, `cargo build --workspace` succeeds, macOS with Keychain Access available.

> **Manual vs automated.** The automated suite (`cargo test`) runs with
> `AGENTKEYS_SESSION_STORE=file` to keep CI deterministic and headless.
> This manual guide is the *opposite*: its job is to verify the parts the
> automated tests deliberately skip — namely, that sessions actually round-trip
> through the **real macOS Keychain**. Do **not** set
> `AGENTKEYS_SESSION_STORE=file` for these tests; if you have it exported in
> your shell, `unset` it before starting.

All tests use 3 terminal windows. Copy-paste each command block in order.

---

## Setup (one-time)

```bash
cd ~/Projects/agentkeys

# Build all binaries
cargo build --workspace --release

# Alias the binaries for convenience (or use cargo run)
alias agentkeys="./target/release/agentkeys-cli"
alias agentkeys-daemon="./target/release/agentkeys-daemon"
alias agentkeys-mock-server="./target/release/agentkeys-mock-server"

# Make sure we are NOT in file-store mode — we want the real keychain
unset AGENTKEYS_SESSION_STORE

# Wipe any prior state so we start cold
rm -rf ~/.agentkeys/
security delete-generic-password -s agentkeys -a session 2>/dev/null || true
```

### Keychain helpers (used throughout)

Paste these into Terminal 2 (and any other terminal where you want to inspect
the keychain). They are thin wrappers around macOS `security(1)`.

```bash
# Show the session JSON currently stored in the keychain
ak-keychain-show() {
  security find-generic-password -s agentkeys -a session -w 2>/dev/null \
    || echo "(no keychain entry)"
}

# Show metadata (service, account, timestamps) without the secret
ak-keychain-meta() {
  security find-generic-password -s agentkeys -a session 2>/dev/null \
    || echo "(no keychain entry)"
}

# Delete the keychain entry
ak-keychain-wipe() {
  security delete-generic-password -s agentkeys -a session 2>/dev/null \
    && echo "deleted" || echo "(nothing to delete)"
}
```

> **First run will prompt.** The first time the CLI writes to the keychain in
> this login session, macOS pops an "agentkeys-cli wants to access your
> keychain" dialog. Click **Always Allow** so subsequent runs are silent.
> This prompt is part of what we are testing — do not dismiss it without
> approving.

---

## Test 0: Keychain Round-Trip (baseline — run this first)

**What you're testing:** a session written by one CLI invocation can be read
by a second, completely separate invocation, and lives in the macOS Keychain
(not the file fallback).

### Terminal 1 — Mock Backend

```bash
cd ~/Projects/agentkeys
cargo run -p agentkeys-mock-server -- --port 8090
# Expected: "Mock server running on port 8090"
# Leave running for every subsequent test.
```

### Terminal 2 — Write then read via separate processes

```bash
cd ~/Projects/agentkeys
unset AGENTKEYS_SESSION_STORE

# Make sure both stores are empty
ak-keychain-wipe
rm -f ~/.agentkeys/session.json

# First process: create a session — this should land in the keychain
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token keychain-roundtrip
# Expected: "Session created" + a wallet address (note it down)
# Approve the macOS keychain dialog with "Always Allow"

# The fallback file should NOT exist — keychain was used
ls -la ~/.agentkeys/session.json 2>&1
# Expected: "No such file or directory"

# The keychain entry SHOULD exist
ak-keychain-meta
# Expected: a record with service="agentkeys", account="session"

# The stored blob should be a valid session JSON
ak-keychain-show | jq '.wallet, .token' 2>/dev/null
# Expected: the wallet address printed above + a bearer token string

# Second process: load the session via any read command — must succeed
WALLET=$(ak-keychain-show | jq -r .wallet)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 usage $WALLET
# Expected: usage table (or empty table) — NOT "session not found"
```

**Pass criteria:**

- `init` triggers exactly one keychain prompt (first run only)
- `~/.agentkeys/session.json` does **not** exist after init
- `ak-keychain-meta` shows the `agentkeys / session` entry
- `ak-keychain-show` returns valid JSON containing `wallet` + `token`
- A second CLI process can read the session without re-running `init`

---

## Test 1: Full Pair Flow (the core demo)

**What you're testing:** a daemon starts cold, displays a pair code, you
approve from the CLI, and the daemon receives a session. Master CLI session
lives in the keychain throughout.

### Terminal 2 — Master CLI (init + store a credential first)

```bash
cd ~/Projects/agentkeys
unset AGENTKEYS_SESSION_STORE

# Create a master session (or reuse Test 0's if still in the keychain)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token master-user-1
# Expected: prints "Session created" and a wallet address like 0x...
# Note the wallet address — this is your master wallet.

# Confirm it landed in the keychain, NOT the file fallback
ak-keychain-meta
ls ~/.agentkeys/session.json 2>&1   # expected: No such file

# Store a credential for later verification
cargo run -p agentkeys-cli -- --backend http://localhost:8090 store 0xAGENT_WALLET openrouter sk-or-test-key-12345
# Replace 0xAGENT_WALLET with the wallet from init
# Expected: "Credential stored"
```

### Terminal 3 — Daemon (pair mode)

```bash
cd ~/Projects/agentkeys
unset AGENTKEYS_SESSION_STORE
export AGENTKEYS_BACKEND=http://localhost:8090

# Start the daemon with NO session — triggers pair flow
cargo run -p agentkeys-daemon -- --backend http://localhost:8090
# Expected output:
#   Pair code: XXXXXXXX. Approve on your Master device. OTP: 123456
#
# Note the PAIR CODE and the OTP. The daemon is now waiting for approval.
```

### Back to Terminal 2 — Approve the pair

```bash
# Use the pair code from Terminal 3
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Replace XXXXXXXX with the actual pair code
#
# Expected:
#   Request type: Pair
#   OTP: 123456
#   Approved. Agent paired successfully.
#
# CHECK: the OTP displayed here matches what Terminal 3 showed
```

### Back to Terminal 3 — Verify daemon received session

```
# After approval, Terminal 3 should print:
#   Paired. Session received. Daemon ready.
#
# The daemon is now running with a valid session.
# Press Ctrl+C to stop it.
```

**Pass criteria:**

- Master CLI session is in the keychain (verified via `ak-keychain-meta`)
- Daemon prints pair code + OTP
- CLI `approve` shows matching OTP
- Daemon prints "Paired. Session received."
- No errors or panics

---

## Test 2: OTP Match Verification

**What you're testing:** the OTP shown by the daemon and the OTP shown by the CLI are identical.

Repeat Test 1 but **carefully compare** the OTP values:

- Terminal 3 (daemon) shows: `OTP: XXXXXX`
- Terminal 2 (approve) shows: `OTP: XXXXXX`

**Pass criteria:**

- Both OTP values are identical (6-digit number)

---

## Test 3: Wrong Pair Code

**What you're testing:** approving a non-existent pair code fails cleanly.

### Terminal 2

```bash
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve FAKE-CODE-999 --yes
# Expected: error message like "not found" or "no pending request"
# Should NOT hang, should NOT panic
```

**Pass criteria:**

- CLI prints a clear error (not a stack trace)
- CLI exits with non-zero exit code
- Response is fast (< 2 seconds)

---

## Test 4: Pair Code Expiry

**What you're testing:** if you wait too long to approve, the pair code expires.

### Terminal 3 — Start daemon

```bash
cargo run -p agentkeys-daemon -- --backend http://localhost:8090
# Note the pair code
```

### Terminal 2 — Wait, then try to approve

```bash
# Wait ~65 seconds (auth request TTL is 60s for Pair type)
sleep 65

cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: error about expired request
```

**Pass criteria:**

- CLI shows "expired" error
- Daemon eventually prints a timeout error (after its poll timeout)

---

## Test 5: Double Approve (Replay Resistance)

**What you're testing:** approving the same pair code twice fails.

### Terminal 3 — Start daemon

```bash
cargo run -p agentkeys-daemon -- --backend http://localhost:8090
# Note the pair code
```

### Terminal 2 — Approve twice

```bash
# First approve (should succeed)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: "Approved"

# Second approve (should fail)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: error about "already consumed" or "not found"
```

**Pass criteria:**

- First approve succeeds
- Second approve fails with a clear error (not a 500)

---

## Test 6: Recovery Flows

Three distinct recovery scenarios covering master and child agentKey recovery.

### Test 6a: Recover Master AgentKey via 2FA Recovery

**What you're testing:** a master agentKey can be recovered on a new computer
using a second-factor recovery method (e.g., passKey stored in Mac keychain
or email verification), without requiring approval from another device.

#### Terminal 2 — Setup (init master + store credential + link identity)

```bash
unset AGENTKEYS_SESSION_STORE

# Init master (uses the keychain)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token recover-master-user
# Note the wallet address

WALLET=$(ak-keychain-show | jq -r .wallet)
echo "wallet: $WALLET"

cargo run -p agentkeys-cli -- --backend http://localhost:8090 store $WALLET openrouter sk-or-recover-master-key
# Expected: "Credential stored"

# Link an alias for easier recovery
cargo run -p agentkeys-cli -- --backend http://localhost:8090 link $WALLET --alias my-master
# Expected: "Linked agent=... alias=..."

# Verify the credential is readable
cargo run -p agentkeys-cli -- --backend http://localhost:8090 read $WALLET openrouter
# Expected: prints "sk-or-recover-master-key"
```

#### Terminal 2 — Simulate loss of master session (wipe keychain)

```bash
ak-keychain-wipe
# Confirm: ak-keychain-meta should print "(no keychain entry)"
```

#### Terminal 2 — Recover master via 2FA (passKey / email)

```bash
# Recover the master session using 2FA recovery (e.g., passKey from Mac keychain or email)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 recover my-master --method passkey
# Expected:
#   Recovered. Session restored for wallet 0x...

# Verify session is back in the keychain
ak-keychain-meta
# Expected: a record with service="agentkeys", account="session"

# Verify credential is still accessible
cargo run -p agentkeys-cli -- --backend http://localhost:8090 read $WALLET openrouter
# Expected: prints "sk-or-recover-master-key"
```

**Pass criteria:**

- Master session can be wiped and recovered without another device
- Recovery completes via `--method passkey` (mock auto-verifies; production uses real WebAuthn)
- Recovered session lands in the keychain
- Previously stored credentials remain accessible after recovery

---

### Test 6b: Recover Child AgentKey via Master Approval

**What you're testing:** a child agentKey (daemon) can be recovered by
requesting approval from an existing master Mac.

#### Terminal 2 — Setup master + child

```bash
unset AGENTKEYS_SESSION_STORE

# Init master
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token recover-child-master
WALLET=$(ak-keychain-show | jq -r .wallet)
echo "master wallet: $WALLET"

cargo run -p agentkeys-cli -- --backend http://localhost:8090 store $WALLET openrouter sk-or-child-key
# Expected: "Credential stored"

cargo run -p agentkeys-cli -- --backend http://localhost:8090 link $WALLET --alias my-child-agent
# Expected: "Linked agent=... alias=..."
```

#### Terminal 3 — Start daemon in recovery mode (child requests recovery)

```bash
cargo run -p agentkeys-daemon -- --backend http://localhost:8090 --recover my-child-agent
# Expected:
#   Recovery code: XXXXXXXX. Approve on your Master device. OTP: 123456
```

#### Terminal 2 — Approve recovery from master Mac

```bash
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: "Approved"
```

#### Terminal 3 — Verify child recovery

```
# Daemon should print:
#   Recovered. Session received. Daemon ready.
```

**Pass criteria:**

- Child daemon starts in recovery mode, shows recovery code + OTP
- Master CLI approve succeeds with matching OTP
- Child daemon receives session and prints "Recovered"

---

### Test 6c: Recover Child AgentKey via 2FA Recovery

**What you're testing:** a child agentKey can be recovered using a
second-factor recovery method (e.g., passKey from Mac keychain) when the
master device is unavailable.

#### Terminal 2 — Setup master + child alias

```bash
unset AGENTKEYS_SESSION_STORE

cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token recover-child-2fa-master
WALLET=$(ak-keychain-show | jq -r .wallet)
echo "master wallet: $WALLET"

cargo run -p agentkeys-cli -- --backend http://localhost:8090 store $WALLET openrouter sk-or-child-2fa-key
# Expected: "Credential stored"

cargo run -p agentkeys-cli -- --backend http://localhost:8090 link $WALLET --alias my-child-2fa
# Expected: "Linked agent=... alias=..."
```

#### Terminal 3 — Recover child via 2FA (no master approval needed)

```bash
# Recover the child session using 2FA recovery (passKey from Mac keychain)
cargo run -p agentkeys-daemon -- --backend http://localhost:8090 --recover my-child-2fa --method passkey
# Expected:
#   Recovered. Session received. Daemon ready.
```

**Pass criteria:**

- Child daemon recovers without needing master approval
- Recovery completes via `--method passkey` (mock auto-verifies; production uses real WebAuthn)
- Daemon receives session and prints "Recovered"

---

## Test 7: Keychain Persistence Across Processes

**What you're testing:** the keychain-backed session survives process death,
not just in-memory state. This is the property that makes the keychain
worthwhile in the first place.

### Terminal 2

```bash
unset AGENTKEYS_SESSION_STORE

# Cold start
ak-keychain-wipe
rm -f ~/.agentkeys/session.json

# Init in one process
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token persist-test
# Note the wallet
WALLET=$(ak-keychain-show | jq -r .wallet)

# Now CLOSE this terminal entirely. Open a brand new one, then:
cd ~/Projects/agentkeys
unset AGENTKEYS_SESSION_STORE
ak-keychain-meta          # should still show the entry from the prior terminal
WALLET=$(ak-keychain-show | jq -r .wallet)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 store $WALLET openrouter sk-persist-key
# Expected: "Credential stored" — proves the second process loaded the
# session from the keychain without re-running `init`.
```

**Pass criteria:**

- `ak-keychain-meta` returns the same entry in the fresh terminal
- `store` succeeds without re-running `init`
- No keychain prompt appears on the second run if "Always Allow" was selected earlier

---

## Test 8: Wrong User Approval

**What you're testing:** a different user cannot approve someone else's pair request.

Because the session lives in a single keychain slot
(`service=agentkeys, account=session`), we swap users by stashing the keychain
blob, wiping the slot, and re-initing as someone else.

### Terminal 2 — Stash user1

```bash
unset AGENTKEYS_SESSION_STORE

# Make sure user1 is currently in the keychain (re-init if needed)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token user1-token

# Stash user1's session JSON to a temp file
ak-keychain-show > /tmp/ak-user1.json
cat /tmp/ak-user1.json | jq .wallet  # sanity check
```

### Terminal 3 — Start daemon paired against user1 (current keychain identity)

```bash
cargo run -p agentkeys-daemon -- --backend http://localhost:8090
# Note the pair code
```

### Terminal 2 — Swap to user2 in the keychain, then try to approve

```bash
# Replace the keychain blob with a fresh user2 session
ak-keychain-wipe
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token different-user-2

# Try to approve user1's pair request as user2
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: UNAUTHORIZED or "permission denied" error — user2 cannot approve user1's request
```

### Cleanup

```bash
# Restore user1 to the keychain (optional, if you want to keep using it)
ak-keychain-wipe
security add-generic-password -s agentkeys -a session -w "$(cat /tmp/ak-user1.json)"
rm -f /tmp/ak-user1.json
```

**Pass criteria:**

- Approval fails with authorization error
- Error message is clear (not a generic 500)

---

## Test 9: Store + Read + Revoke + Read (Full Lifecycle)

**What you're testing:** the complete credential lifecycle end-to-end — with
the session living in the real keychain the whole time.

### Terminal 2 (mock server still running in Terminal 1)

```bash
unset AGENTKEYS_SESSION_STORE
ak-keychain-wipe
rm -f ~/.agentkeys/session.json

# Init
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token lifecycle-test

# Confirm session is in the keychain
ak-keychain-meta

# Pull the wallet from the keychain blob (no need to re-init)
WALLET=$(ak-keychain-show | jq -r .wallet)
echo "wallet: $WALLET"

# Store
cargo run -p agentkeys-cli -- --backend http://localhost:8090 store $WALLET openrouter sk-lifecycle-key
# Expected: "Credential stored"

# Read
cargo run -p agentkeys-cli -- --backend http://localhost:8090 read $WALLET openrouter
# Expected: "sk-lifecycle-key"

# Run with env injection
cargo run -p agentkeys-cli -- --backend http://localhost:8090 run $WALLET -- printenv OPENROUTER_API_KEY
# Expected: "sk-lifecycle-key"

# Check audit trail
cargo run -p agentkeys-cli -- --backend http://localhost:8090 usage $WALLET
# Expected: table showing store + read events

# Revoke
cargo run -p agentkeys-cli -- --backend http://localhost:8090 revoke $WALLET
# Expected: "Session revoked"

# Try to read after revoke
cargo run -p agentkeys-cli -- --backend http://localhost:8090 read $WALLET openrouter
# Expected: error — session revoked / DENIED
```

**Pass criteria:**

- Session is in the keychain (verified)
- Store succeeds
- Read returns the stored key
- `run` injects the env var correctly
- Usage shows audit events
- Revoke succeeds
- Read after revoke fails with clear error

---

## Test 10: File Fallback (opt-out path)

**What you're testing:** the documented opt-out (`AGENTKEYS_SESSION_STORE=file`)
still works for CI/headless environments where no keychain is available.

### Terminal 2

```bash
# Clean both stores
ak-keychain-wipe
rm -f ~/.agentkeys/session.json

# Force file mode
export AGENTKEYS_SESSION_STORE=file
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token file-fallback

# Keychain should be untouched
ak-keychain-meta         # expected: (no keychain entry)

# File should exist
cat ~/.agentkeys/session.json | jq '.wallet'

# IMPORTANT: unset before continuing with other tests
unset AGENTKEYS_SESSION_STORE
```

**Pass criteria:**

- With `AGENTKEYS_SESSION_STORE=file`, nothing is written to the keychain
- `~/.agentkeys/session.json` is created and contains valid JSON

---

## Automated Test (sanity check — does NOT exercise keychain)

```bash
cd ~/Projects/agentkeys
AGENTKEYS_SESSION_STORE=file cargo test --workspace
# Expected: 83 tests passed, 0 failed
#
# NOTE: automated tests force file mode on purpose. Keychain behavior is
# verified only by the manual tests above.
```

---

## Troubleshooting


| Symptom                                            | Fix                                                                                                                                                                                                                                                       |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keychain popup on every CLI invocation             | Click **Always Allow** on the first prompt. If you accidentally clicked plain "Allow", open Keychain Access.app → search for "agentkeys" → right-click the entry → Access Control → add your terminal/cargo binary or switch to "Allow all applications". |
| `security: ... could not be found in the keychain` | There is no entry yet — run `init` first.                                                                                                                                                                                                                 |
| "Connection refused"                               | Make sure the mock server is running in Terminal 1 on port 8090                                                                                                                                                                                           |
| "Session not found"                                | Run `agentkeys init --mock-token <token>` first                                                                                                                                                                                                           |
| Pair code expired                                  | Pair codes expire after 60s. Approve quickly or restart the daemon.                                                                                                                                                                                       |
| Build error about `edition2024`                    | Run `rustup update stable` (need Rust 1.85+)                                                                                                                                                                                                              |
| Want to test without any keychain interaction      | `export AGENTKEYS_SESSION_STORE=file` (this is what CI does — see Test 10)                                                                                                                                                                                |


---

## Cleanup

```bash
# Stop mock server (Ctrl+C in Terminal 1)

# Remove file-based session fallback
rm -rf ~/.agentkeys/

# Remove keychain entry
security delete-generic-password -s agentkeys -a session 2>/dev/null || true

# Confirm both stores are empty
ak-keychain-meta
ls ~/.agentkeys/ 2>&1
```

