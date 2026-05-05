use std::sync::Arc;

use crate::audit::AuditLog;
use crate::config::BrokerConfig;
use crate::jwt::SessionKeypair;
use crate::oidc::OidcKeypair;
use crate::plugins::audit::AuditPolicy;
use crate::plugins::PluginRegistry;
use crate::storage::{AuthNonceStore, WalletStore};
use crate::sts::StsClient;

/// Tier-2 reachability state shared with the /readyz handler.
///
/// Each field flips to `true` once its corresponding async probe in
/// `boot::run_tier2` has succeeded. /readyz aggregates these into the
/// returned 200/503 status.
#[derive(Default, Debug)]
pub struct Tier2State {
    pub backend_reachable: std::sync::atomic::AtomicBool,
    pub ses_verified: std::sync::atomic::AtomicBool,
    pub evm_rpc_reachable: std::sync::atomic::AtomicBool,
    pub evm_fee_payer_funded: std::sync::atomic::AtomicBool,
}

pub struct AppState {
    pub config: BrokerConfig,
    pub http: reqwest::Client,
    /// Legacy single-table audit log carried during the transition until
    /// US-011 retires it. New mints write through the AuditAnchor trait
    /// in `registry.audit`.
    pub audit: AuditLog,
    pub sts: Arc<dyn StsClient>,
    pub oidc: Arc<OidcKeypair>,
    /// Stage 7 additions:
    pub session_keypair: Arc<SessionKeypair>,
    pub registry: Arc<PluginRegistry>,
    pub audit_policy: AuditPolicy,
    pub wallet_store: Arc<WalletStore>,
    pub nonce_store: Arc<AuthNonceStore>,
    pub tier2: Arc<Tier2State>,
    /// Concrete handle to the EmailLink plugin (Phase A.1, US-018).
    /// `None` when `auth-email-link` feature is disabled OR when
    /// `BROKER_AUTH_METHODS` doesn't include `email_link`. The trait-
    /// object form is also registered in `registry.auth["email_link"]`
    /// for the trait-driven CLI poll path; this concrete reference
    /// exists so the browser-side `/v1/auth/email/verify` handler can
    /// call `consume_token` + `mark_verified` directly.
    #[cfg(feature = "auth-email-link")]
    pub email_link: Option<Arc<crate::plugins::auth::EmailLinkAuth>>,
}

pub type SharedState = Arc<AppState>;
