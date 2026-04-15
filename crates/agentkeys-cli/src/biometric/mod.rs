//! Biometric gate for master-CLI actions (`approve`, `revoke`, `teardown`).
//!
//! Trait-seam design:
//! - [`BiometricBackend`] abstracts "prompt the user and return yes/no".
//! - [`LAContextBackend`] (macOS): real LAContext.evaluatePolicy via objc2 FFI.
//! - [`StdinBackend`] (other platforms): interactive y/N fallback.
//! - [`MockBackend`] (tests): scripted results.
//!
//! The gate is opt-in. Set `AGENTKEYS_BIOMETRIC=on` to activate; anything
//! else (default, or `=off`) bypasses entirely — this keeps CI scripts and
//! headless environments working without special-casing each caller.
//!
//! Call sites redact user-supplied arguments before passing them to the
//! `reason` string (see [`redact_prompt_reason`]) so session tokens can't
//! leak to terminal scrollback or captured logs.

pub mod error;
pub mod logic;

#[cfg(target_os = "macos")]
pub mod lacontext;

pub mod stdin;

pub use error::BiometricError;
pub use logic::redact_prompt_reason;

/// Abstracted biometric prompt — implemented per-platform and mocked in
/// tests so call-site behavior can be verified without real hardware.
pub trait BiometricBackend: Send + Sync {
    /// Prompt the user and block until they respond or the prompt times out.
    ///
    /// `reason` is displayed verbatim to the user; callers are responsible
    /// for redaction (see [`redact_prompt_reason`]).
    fn authenticate(&self, reason: &str) -> Result<(), BiometricError>;
}

/// Returns true if the env configuration disables biometric checks.
/// Default is opt-in (gate bypassed unless explicitly enabled), which
/// preserves existing CLI behavior and keeps tests / scripts working
/// without flag churn.
pub fn biometric_is_enabled() -> bool {
    match std::env::var("AGENTKEYS_BIOMETRIC") {
        Ok(v) => v.eq_ignore_ascii_case("on") || v == "1" || v.eq_ignore_ascii_case("true"),
        Err(_) => false,
    }
}

/// Select the appropriate backend for the current platform. Returns a
/// boxed backend so call sites can accept `&dyn BiometricBackend` without
/// knowing which concrete type is in use.
pub fn default_backend() -> Box<dyn BiometricBackend> {
    #[cfg(target_os = "macos")]
    {
        Box::new(lacontext::LAContextBackend::new())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Box::new(stdin::StdinBackend)
    }
}

/// Convenience: run the gate only if [`biometric_is_enabled`] is true.
/// Call sites should prefer this over constructing a backend directly —
/// it centralizes the env-gate check so `AGENTKEYS_BIOMETRIC=off` behavior
/// stays consistent across `cmd_approve`, `cmd_revoke`, `cmd_teardown`.
pub fn require_biometric(reason: &str) -> Result<(), BiometricError> {
    if !biometric_is_enabled() {
        return Ok(());
    }
    let backend = default_backend();
    backend.authenticate(&redact_prompt_reason(reason))
}

#[cfg(test)]
pub mod mock {
    use super::{BiometricBackend, BiometricError};
    use std::collections::VecDeque;
    use std::sync::Mutex;

    /// Test-only backend that replays a scripted sequence of results.
    /// Records every `reason` passed in so tests can assert on redaction.
    pub struct MockBackend {
        scripted: Mutex<VecDeque<Result<(), BiometricError>>>,
        reasons: Mutex<Vec<String>>,
    }

    impl MockBackend {
        pub fn new(scripted: Vec<Result<(), BiometricError>>) -> Self {
            Self {
                scripted: Mutex::new(scripted.into_iter().collect()),
                reasons: Mutex::new(Vec::new()),
            }
        }

        pub fn reasons(&self) -> Vec<String> {
            self.reasons.lock().expect("mock reasons lock").clone()
        }
    }

    impl BiometricBackend for MockBackend {
        fn authenticate(&self, reason: &str) -> Result<(), BiometricError> {
            self.reasons
                .lock()
                .expect("mock reasons lock")
                .push(reason.to_string());
            self.scripted
                .lock()
                .expect("mock scripted lock")
                .pop_front()
                .unwrap_or(Err(BiometricError::Unknown))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Running each test that touches AGENTKEYS_BIOMETRIC with an env lock
    // so concurrent tests don't race the single process env.
    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        LOCK.lock().expect("env lock poisoned")
    }

    #[test]
    fn default_is_disabled_when_env_unset() {
        let _g = env_lock();
        unsafe { std::env::remove_var("AGENTKEYS_BIOMETRIC") };
        assert!(!biometric_is_enabled());
    }

    #[test]
    fn enabled_when_env_is_on() {
        let _g = env_lock();
        unsafe { std::env::set_var("AGENTKEYS_BIOMETRIC", "on") };
        assert!(biometric_is_enabled());
        unsafe { std::env::remove_var("AGENTKEYS_BIOMETRIC") };
    }

    #[test]
    fn disabled_when_env_is_off() {
        let _g = env_lock();
        unsafe { std::env::set_var("AGENTKEYS_BIOMETRIC", "off") };
        assert!(!biometric_is_enabled());
        unsafe { std::env::remove_var("AGENTKEYS_BIOMETRIC") };
    }

    #[test]
    fn require_biometric_is_no_op_when_disabled() {
        let _g = env_lock();
        unsafe { std::env::set_var("AGENTKEYS_BIOMETRIC", "off") };
        assert!(require_biometric("Approve pair").is_ok());
        unsafe { std::env::remove_var("AGENTKEYS_BIOMETRIC") };
    }

    // L3 behavioral — verify that when a backend IS invoked, long opaque
    // strings are redacted before reaching it. Covers codex PR #27 P2
    // (session-token leak via prompt reason). Uses MockBackend directly
    // to bypass the env-gate/default-backend wiring.
    #[test]
    fn mock_backend_receives_redacted_reason() {
        use super::mock::MockBackend;
        let tok = "a".repeat(64);
        let raw_reason = format!("Revoke session {tok} now");
        let redacted = redact_prompt_reason(&raw_reason);

        let backend = MockBackend::new(vec![Ok(())]);
        backend
            .authenticate(&redacted)
            .expect("mock scripted success");

        let reasons = backend.reasons();
        assert_eq!(reasons.len(), 1);
        assert!(
            !reasons[0].contains(&tok),
            "raw token leaked to backend: {}",
            reasons[0]
        );
        assert!(reasons[0].contains("<redacted>"));
    }

    #[test]
    fn mock_backend_returns_scripted_error() {
        use super::mock::MockBackend;
        let backend = MockBackend::new(vec![Err(BiometricError::UserCancel)]);
        assert_eq!(
            backend.authenticate("Revoke").unwrap_err(),
            BiometricError::UserCancel
        );
    }
}
