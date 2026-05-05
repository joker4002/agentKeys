//! `UserAuthMethod` trait — the auth layer of the pluggable broker.
//!
//! Each enabled auth method implements this trait and registers in
//! `PluginRegistry::auth`. The HTTP layer dispatches to the right
//! implementation by URL prefix (`/v1/auth/wallet/*`,
//! `/v1/auth/email/*`, `/v1/auth/oauth2/*`).
//!
//! Per plan §3.5: each method ultimately produces a `VerifiedIdentity`,
//! which the broker hashes into an `OmniAccount` (SHA256 over `client_id ||
//! identity_type || identity_value`) and uses to look up wallet bindings
//! and grants.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::Readiness;

/// Stable, machine-readable label for the kind of identity an auth method
/// proves control of. Used as one of the SHA256 inputs for OmniAccount
/// derivation, so renaming is a breaking change for stored OmniAccounts.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum IdentityType {
    /// EVM wallet, value is the lowercased 0x-prefixed checksum address.
    Evm,
    /// Verified email, value is the lowercased local-part + domain.
    Email,
    /// OAuth2 Google sub claim, value is the Google `sub` (stable).
    OAuth2Google,
    /// OAuth2 GitHub user id, value is the GitHub user id (stable, numeric string).
    /// Reserved for v1.
    OAuth2Github,
    /// OAuth2 Apple sub claim. Reserved for v1.
    OAuth2Apple,
}

impl IdentityType {
    /// The exact byte sequence used as the `identity_type` input to
    /// `SHA256(client_id || identity_type || identity_value)`. Stable —
    /// changing this is a breaking change for stored OmniAccounts.
    pub fn canonical(&self) -> &'static str {
        match self {
            IdentityType::Evm => "evm",
            IdentityType::Email => "email",
            IdentityType::OAuth2Google => "oauth2_google",
            IdentityType::OAuth2Github => "oauth2_github",
            IdentityType::OAuth2Apple => "oauth2_apple",
        }
    }
}

/// Verified identity returned by `UserAuthMethod::verify` after a successful
/// challenge/response round-trip.
///
/// `omni_account` is computed by the auth router after the auth method
/// returns; the auth method itself only fills in `identity_type` and
/// `identity_value`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct VerifiedIdentity {
    pub identity_type: IdentityType,
    pub identity_value: String,
}

/// Inputs to the `challenge()` step. Method-specific extras travel in
/// `extras` as opaque JSON the method itself parses.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChallengeParams {
    /// Optional source IP for rate-limit bookkeeping.
    pub source_ip: Option<String>,
    /// Method-specific JSON payload (e.g., `{"address": "0x…", "chain_id": 84532}`
    /// for wallet-sig; `{"email": "u@x.com"}` for email-link).
    pub extras: serde_json::Value,
}

/// Output of the `challenge()` step. The broker stores this server-side
/// keyed by `request_id` and returns the relevant subset to the client.
///
/// For wallet-sig: `extras` carries the SIWE message text the user must sign.
/// For email-link: `extras` carries the request_id only (token is mailed).
/// For oauth2: `extras` carries the authorization_url.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuthChallenge {
    pub request_id: String,
    pub expires_in_seconds: u64,
    pub extras: serde_json::Value,
}

/// Inputs to the `verify()` step.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuthResponse {
    pub request_id: String,
    /// Method-specific JSON payload (e.g., `{"signature": "0x…"}` for wallet-sig;
    /// `{"token": "…"}` for email-link; `{"code": "…", "state": "…"}` for oauth2).
    pub extras: serde_json::Value,
}

/// Errors a `UserAuthMethod` may return. The HTTP layer maps these to status codes.
#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("expired: {0}")]
    Expired(String),
    #[error("rate limited: {0}")]
    RateLimited(String),
    #[error("upstream error: {0}")]
    Upstream(String),
    #[error("internal: {0}")]
    Internal(String),
}

#[async_trait]
pub trait UserAuthMethod: Send + Sync {
    /// Stable kebab-case name used for plug-in registration and `/readyz` labels.
    /// E.g., `"wallet_sig"`, `"email_link"`, `"oauth2_google"`.
    fn name(&self) -> &'static str;

    /// Operational state of the plug-in's dependencies.
    /// **MUST NOT default to `Ready`** — implementations check their own
    /// dependencies (DB writable, SES verified, JWKS reachable, etc.).
    fn ready(&self) -> Readiness;

    /// Initiate the auth flow. Returns a server-side request handle the
    /// client uses to complete the flow via `verify()`.
    async fn challenge(&self, params: ChallengeParams) -> Result<AuthChallenge, AuthError>;

    /// Complete the auth flow. Returns the verified identity on success.
    async fn verify(&self, response: AuthResponse) -> Result<VerifiedIdentity, AuthError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_type_canonical_strings_are_stable() {
        // These values feed into OmniAccount derivation; renaming any of
        // them is a backwards-incompatible change.
        assert_eq!(IdentityType::Evm.canonical(), "evm");
        assert_eq!(IdentityType::Email.canonical(), "email");
        assert_eq!(IdentityType::OAuth2Google.canonical(), "oauth2_google");
        assert_eq!(IdentityType::OAuth2Github.canonical(), "oauth2_github");
        assert_eq!(IdentityType::OAuth2Apple.canonical(), "oauth2_apple");
    }
}
