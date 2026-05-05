//! SQLite-backed storage modules for the pluggable broker.
//!
//! Each submodule owns one table. Schema lives co-located with the
//! reader/writer code. Phase 0 ships the wallets table; auth_nonces
//! lands in US-006, email_tokens in Phase A.1, oauth_pending in Phase
//! A.2, grants + identity_links in Phase B.

pub mod auth_nonces;
#[cfg(feature = "auth-email-link")]
pub mod email_rate_limits;
#[cfg(feature = "auth-email-link")]
pub mod email_tokens;
pub mod wallets;

pub use auth_nonces::{AuthNonceStore, ConsumeOutcome};
#[cfg(feature = "auth-email-link")]
pub use email_rate_limits::{EmailRateLimitStore, RateLimitOutcome};
#[cfg(feature = "auth-email-link")]
pub use email_tokens::{EmailConsumeOutcome, EmailRequestStatus, EmailTokenStore};
pub use wallets::WalletStore;
