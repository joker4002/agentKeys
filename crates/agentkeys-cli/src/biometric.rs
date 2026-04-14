//! Biometric gate for high-security CLI actions.
//!
//! macOS: currently logs the reason and proceeds (Touch ID via LAContext requires
//! the `block2` crate for synchronous evaluation — tracked as a follow-up).
//! Non-macOS: prompts via stdin, or accepts AGENTKEYS_ALLOW_NO_BIOMETRIC=1 when
//! stdin is not a TTY.
//!
//! Set `AGENTKEYS_BIOMETRIC=off` to skip the gate entirely (CI / tests).

use anyhow::Result;
#[cfg(not(target_os = "macos"))]
use anyhow::anyhow;

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

/// macOS gate: logs the prompt to stderr and proceeds.
///
/// A real Touch ID evaluation via `LAContext.evaluatePolicy` requires constructing
/// an Objective-C block synchronously, which needs the `block2` crate. That is
/// deferred to a follow-up. For now this provides the escape-hatch scaffolding
/// (`AGENTKEYS_BIOMETRIC=off`) that tests and CI rely on.
#[cfg(target_os = "macos")]
fn macos_gate(reason: &str) -> Result<()> {
    eprintln!("[agentkeys] biometric prompt: {}", reason);
    eprintln!("[agentkeys] Touch ID evaluation deferred (set AGENTKEYS_BIOMETRIC=off to skip)");
    Ok(())
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
