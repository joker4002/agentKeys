//! BiometricError — a typed representation of the NSError codes that
//! `LAContext.evaluatePolicy` can surface, plus the timeout / unknown cases
//! that only the Rust side knows about. Mapped from raw `i64` codes by
//! [`parse_la_error`](super::logic::parse_la_error).

use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum BiometricError {
    #[error("user cancelled the biometric prompt")]
    UserCancel,
    #[error("system cancelled the biometric prompt (app backgrounded, lockscreen, etc.)")]
    SystemCancel,
    #[error("biometry is not available on this device")]
    BiometryNotAvailable,
    #[error("biometry is locked out after too many failed attempts; device passcode required")]
    BiometryLockout,
    #[error("device has no passcode set, so biometry cannot be enrolled")]
    PasscodeNotSet,
    #[error("application cancelled the authentication session")]
    AppCancel,
    #[error("LAContext is invalid (already used or disposed)")]
    InvalidContext,
    #[error("biometric prompt timed out (no user response within the configured window)")]
    Timeout,
    #[error("biometric backend reported an unknown condition")]
    Unknown,
    #[error("biometric backend reported a specific unknown error code {code}")]
    UnknownCode { code: i64 },
    #[error("stdin fallback: user declined the prompt")]
    Declined,
    #[error("stdin fallback: no TTY available and AGENTKEYS_ALLOW_NO_BIOMETRIC is not set")]
    NoTty,
}
