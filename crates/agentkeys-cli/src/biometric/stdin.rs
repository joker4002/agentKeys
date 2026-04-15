//! Non-macOS fallback: ask the user on stdin. Linux / Windows get a y/N
//! prompt on stderr. If stdin is not a TTY (scripts, CI) we refuse unless
//! `AGENTKEYS_ALLOW_NO_BIOMETRIC=1` is set — that way a plain headless run
//! without explicit opt-out fails closed.
//!
//! This fallback will go away when Linux fprintd/polkit (issue TBD) and
//! Windows Hello (issue TBD) land. Keeping it here rather than deleting the
//! module so users on those platforms still have a working prompt while
//! the native gates are implemented.

use super::{BiometricBackend, BiometricError};
use std::io::{BufRead, Write};

pub struct StdinBackend;

impl BiometricBackend for StdinBackend {
    fn authenticate(&self, reason: &str) -> Result<(), BiometricError> {
        // isatty check — if stdin is piped / redirected, the user can't
        // respond, so we fail closed unless they opted in.
        let is_tty = std::io::IsTerminal::is_terminal(&std::io::stdin());
        let allow_no_tty = std::env::var("AGENTKEYS_ALLOW_NO_BIOMETRIC")
            .map(|v| v == "1")
            .unwrap_or(false);
        if !is_tty && !allow_no_tty {
            return Err(BiometricError::NoTty);
        }

        let stderr = std::io::stderr();
        let mut stderr = stderr.lock();
        writeln!(stderr, "{reason}").ok();
        write!(stderr, "Confirm [y/N]: ").ok();
        stderr.flush().ok();

        let mut input = String::new();
        std::io::stdin()
            .lock()
            .read_line(&mut input)
            .map_err(|_| BiometricError::Declined)?;
        let answer = input.trim().to_ascii_lowercase();
        if answer == "y" || answer == "yes" {
            Ok(())
        } else {
            Err(BiometricError::Declined)
        }
    }
}
