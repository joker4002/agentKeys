//! Biometric gate for high-security CLI actions.
//!
//! **Opt-in by default** to preserve pre-#11 behavior for every existing user
//! on every platform. Scripts and CI see no behavior change until they
//! explicitly opt in via `AGENTKEYS_BIOMETRIC=on`.
//!
//! Modes (set via `AGENTKEYS_BIOMETRIC`):
//! - `off` (default when unset) → no gate; `require_biometric` returns `Ok`.
//! - `on`                        → gate is active. Platform-specific path:
//!                                  - macOS: real Touch ID (deferred — see
//!                                    `macos_gate`). Set
//!                                    `AGENTKEYS_BIOMETRIC_STUB_OK=1` to
//!                                    acknowledge the stub and proceed.
//!                                  - non-macOS: stdin y/N confirm; non-TTY
//!                                    environments must also set
//!                                    `AGENTKEYS_ALLOW_NO_BIOMETRIC=1`.

use anyhow::{anyhow, Result};

/// Require biometric (or fallback) confirmation before a high-security action.
///
/// See the module doc for mode selection. Summary: no-op unless
/// `AGENTKEYS_BIOMETRIC=on` is set.
pub fn require_biometric(reason: &str) -> Result<()> {
    let mode = std::env::var("AGENTKEYS_BIOMETRIC").ok();
    match mode.as_deref() {
        // Explicit opt-out and the default (unset) both skip the gate — no
        // regression for existing scripts or CI pipelines.
        Some("off") | None => return Ok(()),
        Some("on") => {}
        Some(other) => {
            return Err(anyhow!(
                "unknown AGENTKEYS_BIOMETRIC value '{}'. Use 'on' to enable the gate or 'off' (default) to disable.",
                other
            ));
        }
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
