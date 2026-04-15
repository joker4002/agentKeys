# Manual test: issue #37 — biometric gate via real macOS LAContext

These scenarios require a macOS host with Touch ID (or Face ID). The automated test suite cannot drive biometric hardware, so these must be exercised by hand before shipping.

## Preconditions

- macOS 11.0 (Big Sur) or later with a working Touch ID / Face ID sensor
- Device passcode configured
- A paired session exists (via `agentkeys init` + `agentkeys approve`)

## Test 1 — Touch ID succeeds

```bash
AGENTKEYS_BIOMETRIC=on agentkeys teardown 0xAGENT
```

**Expected:**
1. macOS shows the Touch ID prompt with the message "Tear down agent 0xAGENT (deletes ALL credentials)"
2. User taps their enrolled finger
3. Command completes: `Torn down agent=0xAGENT`

## Test 2 — User cancels

```bash
AGENTKEYS_BIOMETRIC=on agentkeys teardown 0xAGENT
```

**Expected:**
1. Touch ID prompt appears
2. User clicks "Cancel" on the prompt
3. Command fails with: `biometric gate: user cancelled the biometric prompt`
4. No teardown request was sent to the backend (verify via `agentkeys usage 0xAGENT`)

## Test 3 — Biometry lockout → passcode fallback

```bash
AGENTKEYS_BIOMETRIC=on agentkeys revoke 0xCHILD_WALLET
```

**Expected:**
1. Touch ID prompt appears
2. User presses a wrong finger 5 times in a row (enough to trigger lockout)
3. macOS auto-switches to passcode entry
4. User enters the device passcode correctly → command proceeds
5. If user cancels passcode → command fails with `biometric gate: user cancelled...`

## Test 4 — Device without biometry sensor

On a device with no Touch ID (e.g., older Mac mini, external keyboard on desktop Mac without a T2):

```bash
AGENTKEYS_BIOMETRIC=on agentkeys teardown 0xAGENT
```

**Expected:**
- Command fails immediately (no prompt) with: `biometric gate: biometry is not available on this device`
- OR falls back to passcode only (depends on macOS version)

## Test 5 — Escape hatch (CI-friendly bypass)

```bash
AGENTKEYS_BIOMETRIC=off agentkeys teardown 0xAGENT
agentkeys teardown 0xAGENT     # env var unset → bypass
```

**Expected:** both commands run without any biometric prompt. Passes the `AGENTKEYS_BIOMETRIC=on` opt-in contract.

## Test 6 — Token leak regression

This is the critical P2 from PR #27.

```bash
# Grab a live session token (use --verbose on init if needed)
TOKEN=$(agentkeys init --mock-token test --verbose 2>&1 | grep -oE 'Token: [a-f0-9]{64}' | cut -d' ' -f2)

AGENTKEYS_BIOMETRIC=on agentkeys revoke "$TOKEN"
```

**Expected:**
1. Touch ID prompt appears with reason "Revoke target session"
2. **The raw token MUST NOT appear in the prompt text, stderr output, or terminal scrollback**
3. If user presses a wrong finger or cancels, any error message must also not echo the raw token

Verification: run the command while recording stderr:
```bash
AGENTKEYS_BIOMETRIC=on agentkeys revoke "$TOKEN" 2> /tmp/revoke-stderr.log
grep -c "$TOKEN" /tmp/revoke-stderr.log    # MUST be 0
```

## Test 7 — Non-macOS stdin fallback

On Linux or Windows:

```bash
AGENTKEYS_BIOMETRIC=on agentkeys teardown 0xAGENT
```

**Expected:**
1. Prompt on stderr: "Tear down agent 0xAGENT (deletes ALL credentials)"
2. "Confirm [y/N]: " prompt
3. User types `y` + Enter → command proceeds
4. User types anything else (or just Enter) → command fails with `biometric gate: stdin fallback: user declined the prompt`

If stdin is piped (not a TTY):
```bash
echo "" | AGENTKEYS_BIOMETRIC=on agentkeys teardown 0xAGENT
```

**Expected:** fails with `biometric gate: stdin fallback: no TTY available...`. Setting `AGENTKEYS_ALLOW_NO_BIOMETRIC=1` in addition to `AGENTKEYS_BIOMETRIC=on` would be a weird combination (opt in AND opt out of TTY requirement); behavior is "skip the gate entirely" via the early exit.

## Exit criteria

All 7 scenarios pass on the reviewer's macOS host (tests 1–6) and on at least one non-macOS host (test 7) before the PR merges.
