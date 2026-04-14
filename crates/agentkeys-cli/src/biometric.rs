//! Biometric gate for high-security CLI actions.
//!
//! macOS: currently logs the reason and proceeds (Touch ID via LAContext requires
//! the `block2` crate for synchronous evaluation — tracked as a follow-up).
//! Non-macOS: prompts via stdin, or accepts AGENTKEYS_ALLOW_NO_BIOMETRIC=1 when
//! stdin is not a TTY.
//!
//! Set `AGENTKEYS_BIOMETRIC=off` to skip the gate entirely (CI / tests).

use anyhow::{anyhow, Result};

/// Require biometric (or fallback) confirmation before a high-security action.
///
/// `AGENTKEYS_BIOMETRIC=off` skips the gate entirely.
pub fn require_biometric(reason: &str) -> Result<()> {
    if std::env::var("AGENTKEYS_BIOMETRIC").as_deref() == Ok("off") {
        return Ok(());
    }

    #[cfg(target_os = "macos")]
    {
        macos_gate(reason)
    }

    #[cfg(not(target_os = "macos"))]
    {
        stdin_confirm(reason)
    }
}

/// macOS gate: fails closed until a real LAContext integration lands.
///
/// A real Touch ID evaluation via `LAContext.evaluatePolicy` requires
/// constructing an Objective-C block synchronously, which needs the `block2`
/// crate. That's tracked as a follow-up. Until that lands, this gate returns
/// an error rather than silently proceeding — consistent with the PR body's
/// promise that the command "requires Touch ID" on macOS.
///
/// Users who need to run a gated command before Touch ID is wired up can set
/// `AGENTKEYS_BIOMETRIC=off` (handled in `require_biometric` above) to skip
/// the gate entirely. The `AGENTKEYS_BIOMETRIC_STUB_OK=1` escape hatch also
/// exists for tests that specifically want to exercise the post-gate path
/// without a real Touch ID evaluator available.
#[cfg(target_os = "macos")]
fn macos_gate(reason: &str) -> Result<()> {
    if std::env::var("AGENTKEYS_BIOMETRIC_STUB_OK").as_deref() == Ok("1") {
        eprintln!("[agentkeys] biometric prompt: {}", reason);
        eprintln!("[agentkeys] STUB mode (AGENTKEYS_BIOMETRIC_STUB_OK=1) — proceeding");
        return Ok(());
    }
    eprintln!("[agentkeys] biometric prompt: {}", reason);
    Err(anyhow!(
        "Touch ID evaluation is not yet wired (macOS LAContext integration deferred). \
         To proceed without biometric confirmation, set AGENTKEYS_BIOMETRIC=off. \
         To acknowledge the stub and proceed, set AGENTKEYS_BIOMETRIC_STUB_OK=1 (not for production)."
    ))
}

/// Non-macOS gate: prompt on TTY or require AGENTKEYS_ALLOW_NO_BIOMETRIC=1.
#[cfg(not(target_os = "macos"))]
fn stdin_confirm(reason: &str) -> Result<()> {
    use std::io::{BufRead, IsTerminal, Write};

    if !std::io::stdin().is_terminal() {
        if std::env::var("AGENTKEYS_ALLOW_NO_BIOMETRIC").as_deref() == Ok("1") {
            return Ok(());
        }
        return Err(anyhow!(
            "stdin is not a TTY and AGENTKEYS_ALLOW_NO_BIOMETRIC=1 is not set; \
             cannot confirm: {reason}"
        ));
    }

    eprint!("Confirm: {} [y/N] ", reason);
    std::io::stderr().flush().ok();

    let mut input = String::new();
    std::io::stdin()
        .lock()
        .read_line(&mut input)
        .map_err(|e| anyhow!("failed to read confirmation: {e}"))?;

    if input.trim().to_lowercase() == "y" {
        Ok(())
    } else {
        Err(anyhow!("Action cancelled by user"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn biometric_skipped_when_env_disables() {
        unsafe { std::env::set_var("AGENTKEYS_BIOMETRIC", "off") };
        let result = require_biometric("test reason");
        assert!(result.is_ok(), "expected Ok when AGENTKEYS_BIOMETRIC=off, got: {:?}", result.err());
    }
}
