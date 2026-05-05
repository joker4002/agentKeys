//! Tiered refuse-to-boot per Stage 7 plan §6.
//!
//! Two-tier boot sequence to avoid the outage trap Codex P1 #6 flagged:
//!
//! - **Tier 1 (synchronous, before listener bind):** config-correctness
//!   only. Env vars present + parseable, types in declared bounds, files
//!   readable + parseable, OIDC issuer https in non-dev mode, plugin
//!   compile-time presence verified, SQLite migrations run cleanly,
//!   ES256 keypairs loaded with correct purpose tags. Failure → exit 1
//!   with single-line `BOOT_FAIL: <var_or_path>=<value>: <reason>; see
//!   runbook §<anchor>`.
//!
//! - **Tier 2 (async, after listener bound):** external reachability.
//!   Backend reachable, SES sender verified (when email-link enabled),
//!   EVM RPC reachable + chain_id matches (when audit-evm enabled), EVM
//!   fee-payer balance ≥ floor. These are *not* refuse-to-boot — the
//!   broker binds the port and serves /healthz=200 + /readyz=503 with
//!   structured detail until each check passes.
//!
//! `BROKER_REFUSE_TO_BOOT_STRICT=true` collapses Tier 2 into Tier 1
//! (every reachability check becomes a hard boot fail) for environments
//! that prefer fail-loud over fail-degraded.

use std::sync::Arc;

use crate::config::BrokerConfig;
use crate::env;
use crate::jwt::SessionKeypair;
use crate::oidc::OidcKeypair;
use crate::plugins::audit::{AuditAnchor, AuditPolicy};
use crate::plugins::PluginRegistry;
use crate::storage::{AuthNonceStore, WalletStore};

/// Outcome of the synchronous Tier-1 boot phase.
pub struct BootArtifacts {
    pub registry: Arc<PluginRegistry>,
    pub oidc_keypair: Arc<OidcKeypair>,
    pub session_keypair: Arc<SessionKeypair>,
    pub audit_policy: AuditPolicy,
    pub wallet_store: Arc<WalletStore>,
    pub nonce_store: Arc<AuthNonceStore>,
}

/// Format and emit a `BOOT_FAIL: …` error to stderr-bound logs and return
/// the same anyhow::Error so main can `?` it cleanly.
fn boot_fail(var: &str, value: &str, reason: impl std::fmt::Display, anchor: &str) -> anyhow::Error {
    let msg = format!(
        "BOOT_FAIL: {}={:?}: {}; see runbook §{}",
        var, value, reason, anchor
    );
    tracing::error!("{}", msg);
    anyhow::anyhow!(msg)
}

/// Run Tier 1 — synchronous, must succeed before the broker binds the
/// listener. Returns the constructed `BootArtifacts` (plugin registry,
/// keypairs, store handles) for `main` to wire into `AppState`.
pub fn run_tier1(config: &BrokerConfig) -> anyhow::Result<BootArtifacts> {
    // 1. Validate OIDC issuer URL (https in non-dev mode).
    let dev_mode = std::env::var(env::BROKER_DEV_MODE)
        .map(|v| v == "true")
        .unwrap_or(false);
    if !dev_mode && !config.oidc_issuer.starts_with("https://") {
        return Err(boot_fail(
            env::BROKER_OIDC_ISSUER,
            &config.oidc_issuer,
            "must be https:// in non-dev mode (set BROKER_DEV_MODE=true to relax)",
            "oidc-issuer",
        ));
    }
    if dev_mode {
        tracing::warn!(
            "{}=true — relaxing https-only OIDC issuer rule. NEVER use in production.",
            env::BROKER_DEV_MODE
        );
    }

    // 2. Load OIDC keypair (purpose=oidc, refuses purpose=session).
    if !config.oidc_keypair_path.exists() {
        return Err(boot_fail(
            env::BROKER_OIDC_KEYPAIR_PATH,
            &config.oidc_keypair_path.display().to_string(),
            "OIDC keypair file does not exist (run `agentkeys-broker-server keygen --purpose oidc --out PATH` first; silent generation is disabled per plan §6)",
            "oidc-keypair",
        ));
    }
    let oidc_keypair = Arc::new(OidcKeypair::load(&config.oidc_keypair_path).map_err(|e| {
        boot_fail(
            env::BROKER_OIDC_KEYPAIR_PATH,
            &config.oidc_keypair_path.display().to_string(),
            e,
            "oidc-keypair",
        )
    })?);

    // 3. Load session keypair (purpose=session, strict no-migration).
    let session_keypair_path = match std::env::var(env::BROKER_SESSION_KEYPAIR_PATH) {
        Ok(p) => std::path::PathBuf::from(p),
        Err(_) => SessionKeypair::default_path(),
    };
    if !session_keypair_path.exists() {
        return Err(boot_fail(
            env::BROKER_SESSION_KEYPAIR_PATH,
            &session_keypair_path.display().to_string(),
            "session keypair file does not exist (run `agentkeys-broker-server keygen --purpose session --out PATH` first)",
            "session-keypair",
        ));
    }
    let session_keypair = Arc::new(SessionKeypair::load(&session_keypair_path).map_err(|e| {
        boot_fail(
            env::BROKER_SESSION_KEYPAIR_PATH,
            &session_keypair_path.display().to_string(),
            e,
            "session-keypair",
        )
    })?);
    tracing::info!(
        oidc_kid = %oidc_keypair.kid,
        session_kid = %session_keypair.kid,
        "ES256 keypairs loaded (purpose-tagged)"
    );

    // 4. Open SQLite-backed stores. Each `open()` runs CREATE TABLE IF
    //    NOT EXISTS — those are our migrations for v0. Refuse-to-boot
    //    on any failure.
    let nonce_store = Arc::new(
        AuthNonceStore::open(&auth_nonces_path(config)).map_err(|e| {
            boot_fail(
                env::BROKER_AUDIT_DB_PATH,
                &config.audit_db_path.display().to_string(),
                format!("AuthNonceStore: {}", e),
                "auth-nonces-db",
            )
        })?,
    );
    let wallet_store = Arc::new(
        WalletStore::open(&wallets_path(config)).map_err(|e| {
            boot_fail(
                env::BROKER_AUDIT_DB_PATH,
                &config.audit_db_path.display().to_string(),
                format!("WalletStore: {}", e),
                "wallets-db",
            )
        })?,
    );

    // 5. Validate + parse plugin selection env vars. Every name in each
    //    list must resolve at compile time (i.e. the corresponding
    //    feature must be enabled).
    let auth_methods_raw = std::env::var(env::BROKER_AUTH_METHODS)
        .unwrap_or_else(|_| "wallet_sig".to_string());
    let audit_anchors_raw = std::env::var(env::BROKER_AUDIT_ANCHORS)
        .unwrap_or_else(|_| "sqlite".to_string());
    let wallet_provisioner_name = std::env::var(env::BROKER_WALLET_PROVISIONER)
        .unwrap_or_else(|_| "client_keystore".to_string());

    // 6. Audit policy.
    let audit_policy_raw = std::env::var(env::BROKER_AUDIT_POLICY)
        .unwrap_or_else(|_| "dual_strict".to_string());
    let audit_policy = AuditPolicy::parse(&audit_policy_raw).map_err(|e| {
        boot_fail(
            env::BROKER_AUDIT_POLICY,
            &audit_policy_raw,
            e,
            "audit-policy",
        )
    })?;

    // 7. Build the PluginRegistry. v0 default is wallet_sig + client_keystore + sqlite.
    let registry = build_registry(
        &auth_methods_raw,
        &wallet_provisioner_name,
        &audit_anchors_raw,
        Arc::clone(&nonce_store),
        Arc::clone(&wallet_store),
        config,
    )?;

    Ok(BootArtifacts {
        registry: Arc::new(registry),
        oidc_keypair,
        session_keypair,
        audit_policy,
        wallet_store,
        nonce_store,
    })
}

/// Synchronous probe of which Tier-2 reachability checks are enabled.
/// Used by main to decide what to spawn after the listener binds.
pub struct Tier2Profile {
    pub strict: bool,
    pub email_link_enabled: bool,
    pub audit_evm_enabled: bool,
    pub backend_url: String,
}

impl Tier2Profile {
    pub fn from_config(config: &BrokerConfig) -> Self {
        let strict = std::env::var(env::BROKER_REFUSE_TO_BOOT_STRICT)
            .map(|v| v == "true")
            .unwrap_or(false);
        let methods = std::env::var(env::BROKER_AUTH_METHODS)
            .unwrap_or_else(|_| "wallet_sig".to_string());
        let anchors = std::env::var(env::BROKER_AUDIT_ANCHORS)
            .unwrap_or_else(|_| "sqlite".to_string());
        Self {
            strict,
            email_link_enabled: methods.split(',').any(|m| m.trim() == "email_link"),
            audit_evm_enabled: anchors.split(',').any(|a| a.trim() == "evm_testnet"),
            backend_url: config.backend_url.clone(),
        }
    }
}

fn auth_nonces_path(config: &BrokerConfig) -> std::path::PathBuf {
    config
        .audit_db_path
        .parent()
        .map(|p| p.join("auth_nonces.sqlite"))
        .unwrap_or_else(|| std::path::PathBuf::from("auth_nonces.sqlite"))
}

fn wallets_path(config: &BrokerConfig) -> std::path::PathBuf {
    config
        .audit_db_path
        .parent()
        .map(|p| p.join("wallets.sqlite"))
        .unwrap_or_else(|| std::path::PathBuf::from("wallets.sqlite"))
}

#[cfg(feature = "audit-sqlite")]
fn open_sqlite_anchor(
    config: &BrokerConfig,
) -> Result<Arc<dyn AuditAnchor>, anyhow::Error> {
    use crate::plugins::audit::sqlite::SqliteAnchor;
    let anchor = SqliteAnchor::open(&config.audit_db_path).map_err(|e| {
        boot_fail(
            env::BROKER_AUDIT_DB_PATH,
            &config.audit_db_path.display().to_string(),
            format!("SqliteAnchor: {}", e),
            "audit-sqlite",
        )
    })?;
    Ok(Arc::new(anchor) as Arc<dyn AuditAnchor>)
}

fn build_registry(
    auth_methods_raw: &str,
    wallet_provisioner_name: &str,
    audit_anchors_raw: &str,
    nonce_store: Arc<AuthNonceStore>,
    wallet_store: Arc<WalletStore>,
    config: &BrokerConfig,
) -> anyhow::Result<PluginRegistry> {
    use crate::plugins::auth::UserAuthMethod;
    use crate::plugins::wallet::WalletProvisioner;

    // Auth methods.
    let mut auth_map: std::collections::HashMap<String, Arc<dyn UserAuthMethod>> =
        std::collections::HashMap::new();
    for method in auth_methods_raw.split(',').map(str::trim) {
        match method {
            #[cfg(feature = "auth-wallet-sig")]
            "wallet_sig" => {
                use crate::plugins::auth::wallet_sig::SiweWalletAuth;
                let domain = url_host(&config.oidc_issuer);
                let plugin = SiweWalletAuth::new(
                    Arc::clone(&nonce_store),
                    domain,
                    config.oidc_issuer.clone(),
                );
                auth_map.insert("wallet_sig".to_string(), Arc::new(plugin));
            }
            "" => {
                // Empty entry from `BROKER_AUTH_METHODS=""` or trailing comma.
                continue;
            }
            other => {
                return Err(boot_fail(
                    env::BROKER_AUTH_METHODS,
                    other,
                    "unknown or feature-gated-out auth method (compile with the matching --features flag)",
                    "auth-method-not-compiled",
                ));
            }
        }
    }
    if auth_map.is_empty() {
        return Err(boot_fail(
            env::BROKER_AUTH_METHODS,
            auth_methods_raw,
            "at least one auth method must be enabled (default `wallet_sig`)",
            "auth-method-empty",
        ));
    }

    // Wallet provisioner.
    let wallet: Arc<dyn WalletProvisioner> = match wallet_provisioner_name {
        #[cfg(feature = "wallet-keystore")]
        "client_keystore" => {
            use crate::plugins::wallet::keystore::ClientSideKeystoreProvisioner;
            Arc::new(ClientSideKeystoreProvisioner::new(Arc::clone(&wallet_store)))
        }
        other => {
            return Err(boot_fail(
                env::BROKER_WALLET_PROVISIONER,
                other,
                "unknown or feature-gated-out wallet provisioner",
                "wallet-provisioner-not-compiled",
            ));
        }
    };

    // Audit anchors.
    let mut audit: Vec<Arc<dyn AuditAnchor>> = Vec::new();
    for anchor_name in audit_anchors_raw.split(',').map(str::trim) {
        match anchor_name {
            #[cfg(feature = "audit-sqlite")]
            "sqlite" => {
                audit.push(open_sqlite_anchor(config)?);
            }
            "" => continue,
            other => {
                return Err(boot_fail(
                    env::BROKER_AUDIT_ANCHORS,
                    other,
                    "unknown or feature-gated-out audit anchor",
                    "audit-anchor-not-compiled",
                ));
            }
        }
    }
    if audit.is_empty() {
        return Err(boot_fail(
            env::BROKER_AUDIT_ANCHORS,
            audit_anchors_raw,
            "at least one audit anchor must be enabled (default `sqlite`)",
            "audit-anchor-empty",
        ));
    }

    Ok(PluginRegistry {
        auth: auth_map,
        wallet,
        audit,
    })
}

/// Extract host portion from a URL like `https://broker.example.com/path` →
/// `broker.example.com`. Used for the SIWE `domain` field.
fn url_host(url: &str) -> String {
    let after_scheme = url
        .splitn(2, "://")
        .nth(1)
        .unwrap_or(url);
    after_scheme
        .split('/')
        .next()
        .unwrap_or(after_scheme)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tempfile::TempDir;

    fn config_with(audit_db: PathBuf, oidc_issuer: &str, oidc_kp_path: PathBuf) -> BrokerConfig {
        BrokerConfig {
            daemon_access_key_id: None,
            daemon_secret_access_key: None,
            data_role_arn: "arn:aws:iam::000:role/test".into(),
            backend_url: "http://localhost:8080".into(),
            audit_db_path: audit_db,
            aws_region: "us-east-1".into(),
            session_duration_seconds: 3600,
            backend_request_timeout_seconds: 10,
            shutdown_grace_seconds: 30,
            oidc_issuer: oidc_issuer.to_string(),
            oidc_keypair_path: oidc_kp_path,
            oidc_jwt_ttl_seconds: 300,
        }
    }

    #[test]
    fn refuse_to_boot_when_oidc_issuer_is_http_without_dev_mode() {
        let tmp = TempDir::new().unwrap();
        // Pre-generate a valid OIDC keypair so we get past that check.
        let oidc_kp = tmp.path().join("oidc.json");
        OidcKeypair::generate_and_persist(&oidc_kp).unwrap();
        let config = config_with(
            tmp.path().join("audit.sqlite"),
            "http://oidc.local",
            oidc_kp,
        );
        // Ensure dev mode env var is not set.
        std::env::remove_var(env::BROKER_DEV_MODE);
        let res = run_tier1(&config);
        let err = match res {
            Err(e) => e,
            Ok(_) => panic!("expected boot failure"),
        };
        let msg = err.to_string();
        assert!(
            msg.contains("BOOT_FAIL") && msg.contains("must be https"),
            "expected https boot fail, got: {}",
            msg
        );
    }

    #[test]
    fn refuse_to_boot_on_missing_oidc_keypair() {
        let tmp = TempDir::new().unwrap();
        let config = config_with(
            tmp.path().join("audit.sqlite"),
            "https://broker.example.com",
            tmp.path().join("does-not-exist.json"),
        );
        let res = run_tier1(&config);
        let err = match res {
            Err(e) => e,
            Ok(_) => panic!("expected boot failure"),
        };
        assert!(err.to_string().contains("does not exist"));
    }

    #[test]
    fn url_host_extracts_correctly() {
        assert_eq!(url_host("https://broker.example.com/v1"), "broker.example.com");
        assert_eq!(url_host("http://localhost:8080"), "localhost:8080");
        assert_eq!(url_host("broker.example.com"), "broker.example.com");
    }

    #[test]
    fn tier2_profile_detects_email_link_enabled() {
        let tmp = TempDir::new().unwrap();
        let oidc_kp = tmp.path().join("oidc.json");
        OidcKeypair::generate_and_persist(&oidc_kp).unwrap();
        let config = config_with(
            tmp.path().join("audit.sqlite"),
            "https://broker.example.com",
            oidc_kp,
        );
        std::env::set_var(env::BROKER_AUTH_METHODS, "wallet_sig,email_link");
        let p = Tier2Profile::from_config(&config);
        assert!(p.email_link_enabled);
        assert!(!p.audit_evm_enabled);
        std::env::remove_var(env::BROKER_AUTH_METHODS);
    }
}
