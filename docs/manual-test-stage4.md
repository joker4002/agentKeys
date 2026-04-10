# Stage 4 Manual Test Guide

**Prerequisite:** Rust toolchain installed, `cargo build --workspace` succeeds.

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

# Force file-based session storage (avoid keychain popups)
export AGENTKEYS_SESSION_STORE=file
```

---

## Test 1: Full Pair Flow (the core demo)

**What you're testing:** a daemon starts cold, displays a pair code, you approve from the CLI, and the daemon receives a session.

### Terminal 1 — Mock Backend
```bash
cd ~/Projects/agentkeys
cargo run -p agentkeys-mock-server -- --port 8090
# Expected: "Mock server running on port 8090"
# Leave running
```

### Terminal 2 — Master CLI (init + store a credential first)
```bash
cd ~/Projects/agentkeys
export AGENTKEYS_SESSION_STORE=file

# Create a master session
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token master-user-1
# Expected: prints "Session created" and a wallet address like 0x...
# Note the wallet address — this is your master wallet.

# Store a credential for later verification
cargo run -p agentkeys-cli -- --backend http://localhost:8090 store 0xAGENT_WALLET openrouter sk-or-test-key-12345
# Replace 0xAGENT_WALLET with the wallet from init
# Expected: "Credential stored"
```

### Terminal 3 — Daemon (pair mode)
```bash
cd ~/Projects/agentkeys
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
- [ ] Daemon prints pair code + OTP
- [ ] CLI `approve` shows matching OTP
- [ ] Daemon prints "Paired. Session received."
- [ ] No errors or panics

---

## Test 2: OTP Match Verification

**What you're testing:** the OTP shown by the daemon and the OTP shown by the CLI are identical.

Repeat Test 1 but **carefully compare** the OTP values:
- Terminal 3 (daemon) shows: `OTP: XXXXXX`
- Terminal 2 (approve) shows: `OTP: XXXXXX`

**Pass criteria:**
- [ ] Both OTP values are identical (6-digit number)

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
- [ ] CLI prints a clear error (not a stack trace)
- [ ] CLI exits with non-zero exit code
- [ ] Response is fast (< 2 seconds)

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
- [ ] CLI shows "expired" error
- [ ] Daemon eventually prints a timeout error (after its poll timeout)

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
- [ ] First approve succeeds
- [ ] Second approve fails with a clear error (not a 500)

---

## Test 6: Recovery Flow

**What you're testing:** an agent's credentials survive a daemon restart via the recover mechanism.

### Terminal 2 — Setup (init + child session + store credential + link identity)
```bash
export AGENTKEYS_SESSION_STORE=file

# Init master
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token recover-test-user
# Note the wallet address

# Create a child session for the agent
# (For v0, the store command uses the master session — store under the master wallet)
WALLET=$(cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token recover-test-user 2>&1 | grep -oP '0x\w+' | head -1)

cargo run -p agentkeys-cli -- --backend http://localhost:8090 store $WALLET openrouter sk-or-recover-test-key
# Expected: "Credential stored"

# Link an alias for easier recovery
cargo run -p agentkeys-cli -- --backend http://localhost:8090 link $WALLET --alias my-agent
# Expected: "Identity linked"

# Verify the credential is readable
cargo run -p agentkeys-cli -- --backend http://localhost:8090 read $WALLET openrouter
# Expected: prints "sk-or-recover-test-key"
```

### Terminal 3 — Start daemon in recovery mode
```bash
cargo run -p agentkeys-daemon -- --backend http://localhost:8090 --recover my-agent
# Expected:
#   Recovery code: XXXXXXXX. Approve on your Master device. OTP: 123456
```

### Terminal 2 — Approve recovery
```bash
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: "Approved"
```

### Terminal 3 — Verify recovery
```
# Daemon should print:
#   Recovered. Session received. Daemon ready.
```

**Pass criteria:**
- [ ] Daemon starts in recovery mode, shows recovery code
- [ ] CLI approve succeeds
- [ ] Daemon receives session and prints "Recovered"

---

## Test 7: Wrong User Approval

**What you're testing:** a different user cannot approve someone else's pair request.

### Terminal 2 — Create a SECOND user
```bash
# Save current session
cp ~/.agentkeys/session.json ~/.agentkeys/session-user1.json

# Init as a different user
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token different-user-2
# This overwrites the session with user2's session
```

### Terminal 3 — Start daemon (will use user1's pair flow internally)
```bash
cargo run -p agentkeys-daemon -- --backend http://localhost:8090
# Note the pair code
```

### Terminal 2 — Try to approve as user2
```bash
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: UNAUTHORIZED or "permission denied" error — user2 cannot approve user1's request
```

### Cleanup
```bash
# Restore user1's session
cp ~/.agentkeys/session-user1.json ~/.agentkeys/session.json
```

**Pass criteria:**
- [ ] Approval fails with authorization error
- [ ] Error message is clear (not a generic 500)

---

## Test 8: Store + Read + Revoke + Read (Full Lifecycle)

**What you're testing:** the complete credential lifecycle end-to-end.

### Terminal 2 (mock server still running in Terminal 1)
```bash
export AGENTKEYS_SESSION_STORE=file

# Init
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token lifecycle-test

# Get wallet
WALLET=$(cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token lifecycle-test 2>&1 | grep -oP '0x\w+' | head -1)

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
- [ ] Store succeeds
- [ ] Read returns the stored key
- [ ] `run` injects the env var correctly
- [ ] Usage shows audit events
- [ ] Revoke succeeds
- [ ] Read after revoke fails with clear error

---

## Automated Test (verify everything in one command)

```bash
cd ~/Projects/agentkeys
AGENTKEYS_SESSION_STORE=file cargo test --workspace
# Expected: 83 tests passed, 0 failed
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Keychain popup on macOS | Set `export AGENTKEYS_SESSION_STORE=file` before running |
| "Connection refused" | Make sure the mock server is running in Terminal 1 on port 8090 |
| "Session not found" | Run `agentkeys init --mock-token <token>` first |
| Pair code expired | Pair codes expire after 60s. Approve quickly or restart the daemon. |
| Build error about `edition2024` | Run `rustup update stable` (need Rust 1.85+) |

---

## Cleanup

```bash
# Stop mock server (Ctrl+C in Terminal 1)
# Remove test session files
rm -rf ~/.agentkeys/
```
