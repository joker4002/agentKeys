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

# Raw Apple output — escape hatch for troubleshooting the FourCharCode attribute
# names (e.g. svce/acct/cdat/mdat). Same as `security find-generic-password -s
# agentkeys -a session`.
ak-keychain-meta-raw() {
  security find-generic-password -s agentkeys -a session 2>/dev/null \
    || echo "(no keychain entry)"
}

# Show metadata (service, account, timestamps) without the secret, with the
# Apple FourCharCode attribute names translated to human-readable English.
# See docs/field-name-translation.md for the full mapping and the general
# "translate at the client, not the backend" principle.
ak-keychain-meta() {
  local raw
  raw=$(security find-generic-password -s agentkeys -a session 2>/dev/null) || {
    echo "(no keychain entry)"
    return
  }
  printf '%s\n' "$raw" | sed -E \
    -e 's/"svce"<blob>/service<blob>/' \
    -e 's/"acct"<blob>/account<blob>/' \
    -e 's/"cdat"<timedate>/created<timedate>/' \
    -e 's/"mdat"<timedate>/modified<timedate>/' \
    -e 's/"crtr"<uint32>/creator<uint32>/' \
    -e 's/"desc"<blob>/description<blob>/' \
    -e 's/"icmt"<blob>/comment<blob>/' \
    -e 's/"gena"<blob>/generic_data<blob>/' \
    -e 's/"invi"<sint32>/invisible<sint32>/' \
    -e 's/"nega"<sint32>/negative_flag<sint32>/' \
    -e 's/"prot"<blob>/protocol<blob>/' \
    -e 's/"scrp"<sint32>/script_code<sint32>/' \
    -e 's/"cusi"<sint32>/custom_icon<sint32>/' \
    -e 's/"type"<uint32>/type<uint32>/' \
    -e 's/0x00000007 <blob>/label           <blob>/' \
    -e 's/0x00000008 <blob>/alias           <blob>/' \
    -e 's#0x[0-9a-fA-F]+ *"([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})Z[^"]*"#\1-\2-\3 \4:\5:\6 UTC#'
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

# Remove any leftover session file so the daemon enters pair flow
rm -f ~/.agentkeys/session

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
# After approval, Terminal 3 should print and then exit automatically:
#   Paired. Session received. Daemon ready.
#   daemon ready, session wallet=0x...
#   no --stdio flag; daemon exiting (Unix socket mode not yet implemented)
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
rm -f ~/.agentkeys/session

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
rm -f ~/.agentkeys/session

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

**What you're testing:** a child agentKey (daemon) that was previously paired
can be recovered on a new machine by requesting approval from the master Mac.
This requires an initial pair to create the child wallet, then a recovery after
the daemon is killed.

#### Terminal 2 — Init master

```bash
unset AGENTKEYS_SESSION_STORE

cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token recover-child-master
MASTER_WALLET=$(ak-keychain-show | jq -r .wallet)
echo "master wallet: $MASTER_WALLET"
```

#### Terminal 3 — Pair a child daemon (creates child wallet)

```bash
unset AGENTKEYS_SESSION_STORE

# Remove any leftover session file from prior tests so the daemon enters pair flow
rm -f ~/.agentkeys/session

cargo run -p agentkeys-daemon -- --backend http://localhost:8090
# Expected:
#   Pair code: XXXXXXXX. Approve on your Master device. OTP: 123456
# Note the PAIR CODE.
```

#### Terminal 2 — Approve the initial pair

```bash
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: "Approved. Agent paired successfully."
```

#### Terminal 3 — Note the child wallet

```
# After approval, daemon should print and then exit automatically:
#   Paired. Session received. Daemon ready.
#   daemon ready, session wallet=0xCHILD_WALLET
#   no --stdio flag; daemon exiting (Unix socket mode not yet implemented)
#
# Note the CHILD_WALLET address from the "session wallet=" line.
# The daemon exits on its own (no Ctrl+C needed) because Unix socket
# mode is not yet implemented. With --stdio it would stay running.
```

#### Terminal 2 — Store credential + link alias on the child wallet

```bash
# Use the child wallet from Terminal 3 output
CHILD_WALLET=0xCHILD_WALLET

cargo run -p agentkeys-cli -- --backend http://localhost:8090 store $CHILD_WALLET openrouter sk-or-child-key
# Expected: "Credential stored"

cargo run -p agentkeys-cli -- --backend http://localhost:8090 link $CHILD_WALLET --alias my-child-agent
# Expected: "Linked agent=... alias=..."
```

#### Terminal 3 — Start a NEW daemon in recovery mode

```bash
cargo run -p agentkeys-daemon -- --backend http://localhost:8090 --recover my-child-agent
# Expected:
#   Recovery code: YYYYYYYY. Approve on your Master device. OTP: 654321
# Note the new RECOVERY CODE.
```

#### Terminal 2 — Approve recovery from master Mac

```bash
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve YYYYYYYY --yes
# Expected: "Approved"
```

#### Terminal 3 — Verify child recovery

```
# After approval, daemon should print and then exit automatically:
#   Recovered. Session received. Daemon ready.
#   daemon ready, session wallet=0xCHILD_WALLET
#   no --stdio flag; daemon exiting (Unix socket mode not yet implemented)
```

**Pass criteria:**

- Initial pair creates a child wallet
- Alias is linked to the **child** wallet (not the master)
- Daemon recovers the same child wallet via the alias
- Master CLI approve succeeds with matching OTP
- Recovered daemon prints "Recovered" and the same child wallet address

---

### Test 6c: Recover Child AgentKey via 2FA Recovery

**What you're testing:** a child agentKey that was previously paired can be
recovered using a second-factor recovery method (passKey) when the master
device is unavailable. No master approval needed.

#### Terminal 2 — Init master

```bash
unset AGENTKEYS_SESSION_STORE

cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token recover-child-2fa-master
MASTER_WALLET=$(ak-keychain-show | jq -r .wallet)
echo "master wallet: $MASTER_WALLET"
```

#### Terminal 3 — Pair a child daemon (creates child wallet)

```bash
unset AGENTKEYS_SESSION_STORE

# Remove any leftover session file from prior tests so the daemon enters pair flow
rm -f ~/.agentkeys/session

cargo run -p agentkeys-daemon -- --backend http://localhost:8090
# Expected:
#   Pair code: XXXXXXXX. Approve on your Master device. OTP: 123456
# Note the PAIR CODE.
```

#### Terminal 2 — Approve the initial pair

```bash
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve XXXXXXXX --yes
# Expected: "Approved. Agent paired successfully."
```

#### Terminal 3 — Note the child wallet

```
# After approval, daemon should print and then exit automatically:
#   Paired. Session received. Daemon ready.
#   daemon ready, session wallet=0xCHILD_WALLET
#   no --stdio flag; daemon exiting (Unix socket mode not yet implemented)
#
# Note the CHILD_WALLET address from the "session wallet=" line.
```

#### Terminal 2 — Store credential + link alias on the child wallet

```bash
CHILD_WALLET=0xCHILD_WALLET

cargo run -p agentkeys-cli -- --backend http://localhost:8090 store $CHILD_WALLET openrouter sk-or-child-2fa-key
# Expected: "Credential stored"

cargo run -p agentkeys-cli -- --backend http://localhost:8090 link $CHILD_WALLET --alias my-child-2fa
# Expected: "Linked agent=... alias=..."
```

#### Terminal 3 — Simulate session loss, then recover via 2FA

```bash
# Simulate the daemon losing its session (machine died, container restarted, etc.)
rm -f ~/.agentkeys/session

# Recover using 2FA -- the --recover flag bypasses session file check,
# but we delete the file to simulate a realistic scenario.
cargo run -p agentkeys-daemon -- --backend http://localhost:8090 --recover my-child-2fa --method passkey
# Expected (daemon prints and exits):
#   Recovered. Session received. Daemon ready.
#   daemon ready, session wallet=0xCHILD_WALLET
#   no --stdio flag; daemon exiting (Unix socket mode not yet implemented)
#
# The wallet should match the CHILD_WALLET from the original pair.
```

**Pass criteria:**

- Initial pair creates a child wallet
- Alias is linked to the **child** wallet (not the master)
- Child daemon recovers via `--method passkey` without master approval
- Recovery completes via mock auto-verify (production uses real WebAuthn)
- Recovered daemon prints the same child wallet address as the original pair

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

**What you're testing:** a different user cannot approve someone else's pair
request when the request has a pre-assigned parent wallet.

> **Note:** This test requires raw HTTP calls because the daemon's pair request
> has no pre-assigned parent (any master can claim it). The automated test
> `pair_wrong_user_approve` in `crates/agentkeys-daemon/tests/pair_tests.rs`
> covers this via the `InProcessBackend`. The manual version below uses `curl`
> to simulate the same scenario.

### Terminal 2 — Create two users

```bash
unset AGENTKEYS_SESSION_STORE

# Create user A
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token user-a
USER_A_TOKEN=$(ak-keychain-show | jq -r .token)
USER_A_WALLET=$(ak-keychain-show | jq -r .wallet)
echo "user A: wallet=$USER_A_WALLET token=$USER_A_TOKEN"

# Stash user A, create user B
ak-keychain-show > /tmp/ak-user-a.json
ak-keychain-wipe
cargo run -p agentkeys-cli -- --backend http://localhost:8090 init --mock-token user-b
USER_B_TOKEN=$(ak-keychain-show | jq -r .token)
echo "user B: token=$USER_B_TOKEN"
```

### Terminal 2 — Open a pair request with parent_wallet pre-assigned to user A

```bash
# Open a pair request via raw HTTP, explicitly binding it to user A
RESPONSE=$(curl -s -X POST http://localhost:8090/auth-request/open \
  -H "Content-Type: application/json" \
  -d "{
    \"child_pubkey\": \"$(echo -n 'dummy-pubkey-32-bytes-padding!!' | base64)\",
    \"request_type\": \"Pair\",
    \"request_details\": \"$(echo -n '{}' | base64)\",
    \"parent_wallet\": \"$USER_A_WALLET\"
  }")
echo "$RESPONSE" | jq .
REQUEST_ID=$(echo "$RESPONSE" | jq -r .id)
echo "request_id: $REQUEST_ID"
```

### Terminal 2 — User B tries to approve user A's request

```bash
# User B (currently in keychain) tries to approve
cargo run -p agentkeys-cli -- --backend http://localhost:8090 approve \
  $(echo "$RESPONSE" | jq -r .pair_code) --yes
# Expected: UNAUTHORIZED or "owned by a different session" error
```

### Cleanup

```bash
ak-keychain-wipe
security add-generic-password -s agentkeys -a session -w "$(cat /tmp/ak-user-a.json)"
rm -f /tmp/ak-user-a.json
```

**Pass criteria:**

- User B's approval fails with authorization error ("owned by a different session")
- Error message is clear (not a generic 500)
- The automated test `pair_wrong_user_approve` passes (already verified by `cargo test`)

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

# Run with env injection (fixed in #15)
# Master sessions now query list_credentials and inject all stored keys.
cargo run -p agentkeys-cli -- --backend http://localhost:8090 run $WALLET -- printenv OPENROUTER_API_KEY
# Expected: "sk-lifecycle-key"

# (Optional) --env override: override the auto-derived env-var name
# cargo run -p agentkeys-cli -- --backend http://localhost:8090 run $WALLET --env MY_KEY=openrouter -- printenv MY_KEY
# Expected: "sk-lifecycle-key"

# Check audit trail
cargo run -p agentkeys-cli -- --backend http://localhost:8090 usage $WALLET
# Expected: table showing store + read events

# Revoke the wallet's active sessions (fixed in #17)
cargo run -p agentkeys-cli -- --backend http://localhost:8090 revoke $WALLET
# Expected: "Revoked agent=0x..."

# Read after revoke — session row is revoked=1, backend denies
cargo run -p agentkeys-cli -- --backend http://localhost:8090 read $WALLET openrouter
# Expected: error — session revoked / DENIED (exact text depends on backend error surface)

# (Optional) Self-revoke form — no args; wipes local session and requires `init` to re-pair.
# cargo run -p agentkeys-cli -- --backend http://localhost:8090 revoke
# Expected: "Revoked current session for wallet=0x.... Local session wiped. Run `agentkeys init` to re-pair."
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

