//! Pure-logic helpers for the biometric module. No FFI, no OS syscalls —
//! everything here is unit-testable on every platform.

use super::error::BiometricError;

/// Map a raw `LAError` code (as returned by NSError.code in the completion
/// block) to a typed [`BiometricError`]. Numeric constants are mirrored from
/// `LocalAuthentication/LAError.h` in the macOS SDK.
///
/// Keeping this as a free function (rather than an impl on BiometricError)
/// makes it testable without wiring any FFI: just call with the documented
/// integer and assert the enum variant.
pub fn parse_la_error(code: i64) -> BiometricError {
    // LAError values from the public SDK headers.
    // https://developer.apple.com/documentation/localauthentication/laerror
    match code {
        -1 => BiometricError::SystemCancel,       // authenticationFailed (legacy alias)
        -2 => BiometricError::UserCancel,         // userCancel
        -3 => BiometricError::UserCancel,         // userFallback (treat as cancel for CLI)
        -4 => BiometricError::SystemCancel,       // systemCancel
        -5 => BiometricError::PasscodeNotSet,     // passcodeNotSet
        -6 => BiometricError::BiometryNotAvailable, // biometryNotAvailable / touchIDNotAvailable
        -7 => BiometricError::BiometryNotAvailable, // biometryNotEnrolled
        -8 => BiometricError::BiometryLockout,    // biometryLockout
        -9 => BiometricError::AppCancel,          // appCancel
        -10 => BiometricError::InvalidContext,    // invalidContext
        other => BiometricError::UnknownCode { code: other },
    }
}

/// Strip anything that looks like a session token or long opaque
/// credential from a user-facing prompt reason. `cmd_revoke` accepts a
/// wallet address OR a session token as its argument; we must not echo
/// the raw token to stderr / TTY / terminal scrollback.
///
/// Heuristic: any whitespace-separated word longer than 40 characters
/// (the typical lower bound of session tokens in this project) gets
/// replaced with `<redacted>`. Short wallet addresses like `0xABC...`
/// pass through because they're already public.
pub fn redact_prompt_reason(raw: &str) -> String {
    const TOKEN_THRESHOLD: usize = 40;
    raw.split_whitespace()
        .map(|word| {
            // Preserve 0x-prefixed wallet addresses verbatim — they're
            // public identifiers. Only the session-token class of long
            // opaque strings is redacted.
            if word.starts_with("0x") && word.len() <= 44 {
                word.to_string()
            } else if word.len() >= TOKEN_THRESHOLD {
                "<redacted>".to_string()
            } else {
                word.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_user_cancel() {
        assert_eq!(parse_la_error(-2), BiometricError::UserCancel);
    }

    #[test]
    fn parse_user_fallback_maps_to_cancel() {
        // CLI has no passcode entry UI; treating fallback as cancel keeps
        // the flow predictable.
        assert_eq!(parse_la_error(-3), BiometricError::UserCancel);
    }

    #[test]
    fn parse_system_cancel() {
        assert_eq!(parse_la_error(-4), BiometricError::SystemCancel);
    }

    #[test]
    fn parse_passcode_not_set() {
        assert_eq!(parse_la_error(-5), BiometricError::PasscodeNotSet);
    }

    #[test]
    fn parse_biometry_not_available() {
        assert_eq!(parse_la_error(-6), BiometricError::BiometryNotAvailable);
    }

    #[test]
    fn parse_biometry_not_enrolled_maps_to_not_available() {
        // User-facing message is the same: device can't do biometric auth.
        assert_eq!(parse_la_error(-7), BiometricError::BiometryNotAvailable);
    }

    #[test]
    fn parse_biometry_lockout() {
        assert_eq!(parse_la_error(-8), BiometricError::BiometryLockout);
    }

    #[test]
    fn parse_app_cancel() {
        assert_eq!(parse_la_error(-9), BiometricError::AppCancel);
    }

    #[test]
    fn parse_invalid_context() {
        assert_eq!(parse_la_error(-10), BiometricError::InvalidContext);
    }

    #[test]
    fn parse_unknown_code_preserves_value() {
        match parse_la_error(-999) {
            BiometricError::UnknownCode { code } => assert_eq!(code, -999),
            other => panic!("expected UnknownCode, got {other:?}"),
        }
    }

    #[test]
    fn redact_preserves_short_wallet_addresses() {
        let input = "Revoke agent 0x1234567890abcdef1234567890abcdef12345678 right now";
        assert!(redact_prompt_reason(input).contains("0x1234567890abcdef1234567890abcdef12345678"));
    }

    #[test]
    fn redact_strips_long_opaque_token() {
        // 64-char hex string — session-token shaped
        let tok = "a".repeat(64);
        let input = format!("Revoke session {tok} now");
        let out = redact_prompt_reason(&input);
        assert!(!out.contains(&tok), "raw token leaked: {out}");
        assert!(out.contains("<redacted>"), "redaction marker missing: {out}");
    }

    #[test]
    fn redact_passes_short_words_through() {
        let input = "Approve pair request XYZ-ABC";
        assert_eq!(redact_prompt_reason(input), input);
    }

    #[test]
    fn redact_is_idempotent() {
        let input = "Revoke <redacted>";
        assert_eq!(redact_prompt_reason(input), input);
    }
}
