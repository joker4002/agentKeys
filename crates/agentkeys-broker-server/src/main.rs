use std::net::IpAddr;
use std::sync::Arc;

use agentkeys_broker_server::{
    audit::AuditLog,
    boot::{run_tier1, Tier2Profile},
    config::BrokerConfig,
    create_router,
    state::{AppState, Tier2State},
    sts::{AwsStsClient, StsClient},
};
use clap::Parser;

#[derive(Parser)]
#[command(name = "agentkeys-broker-server", about = "AgentKeys credential broker")]
struct Args {
    #[arg(long, default_value = "8091")]
    port: u16,

    #[arg(long, default_value = "0.0.0.0")]
    bind: String,

    /// Skip the startup STS sanity check. Useful for offline development.
    /// In production, leave this off so misconfigured creds fail fast.
    #[arg(long)]
    skip_startup_check: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let args = Args::parse();
    let config = BrokerConfig::from_env()?;

    warn_if_non_loopback_without_tls(&args.bind);

    // Tier 1 — synchronous refuse-to-boot per plan §6. Loads keypairs,
    // validates plugin selection, opens stores, builds registry. Any
    // failure here exits with a single-line BOOT_FAIL message.
    let boot_artifacts = run_tier1(&config)?;
    let tier2_profile = Tier2Profile::from_config(&config);
    tracing::info!(
        strict = tier2_profile.strict,
        email_link = tier2_profile.email_link_enabled,
        audit_evm = tier2_profile.audit_evm_enabled,
        "Tier-1 boot complete; Tier-2 reachability checks deferred until after listener bind"
    );

    // Legacy mint-log preserved through US-011. Open it alongside the
    // new plugin-trait-based audit anchors.
    let audit = AuditLog::open(&config.audit_db_path)?;

    let sts = match (&config.daemon_access_key_id, &config.daemon_secret_access_key) {
        (Some(akid), Some(secret)) => {
            tracing::info!("AWS credentials: static IAM-user keys (DAEMON_ACCESS_KEY_ID env)");
            AwsStsClient::from_keys(akid, secret, &config.aws_region).await
        }
        _ => {
            tracing::info!("AWS credentials: SDK default chain (AWS_PROFILE / ~/.aws / IMDS)");
            AwsStsClient::with_default_chain(&config.aws_region).await
        }
    };

    if !args.skip_startup_check {
        match sts.caller_identity_ok().await {
            Ok(()) => tracing::info!("startup STS check passed"),
            Err(e) => {
                tracing::error!(error = %e, "startup STS check failed — refusing to bind");
                anyhow::bail!(
                    "startup STS check failed: {}. Either set AWS_PROFILE (or attach an EC2 instance profile) so the SDK's default chain can resolve credentials, or set DAEMON_ACCESS_KEY_ID + DAEMON_SECRET_ACCESS_KEY for the legacy static-keys path. Verify BROKER_AWS_REGION too. Pass --skip-startup-check for offline dev.",
                    e
                );
            }
        }
    }

    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(config.backend_request_timeout_seconds))
        .connect_timeout(std::time::Duration::from_secs(5))
        .build()?;

    let grace_seconds = config.shutdown_grace_seconds;
    let tier2 = Arc::new(Tier2State::default());

    let state = Arc::new(AppState {
        config,
        http,
        audit,
        sts: Arc::new(sts),
        oidc: boot_artifacts.oidc_keypair,
        session_keypair: boot_artifacts.session_keypair,
        registry: boot_artifacts.registry,
        audit_policy: boot_artifacts.audit_policy,
        wallet_store: boot_artifacts.wallet_store,
        nonce_store: boot_artifacts.nonce_store,
        tier2: Arc::clone(&tier2),
        #[cfg(feature = "auth-email-link")]
        email_link: boot_artifacts.email_link,
        #[cfg(feature = "auth-oauth2")]
        oauth2: boot_artifacts.oauth2,
    });

    // Spawn Tier-2 reachability probes asynchronously. /readyz returns
    // 503 with structured detail until each check passes; broker is
    // already serving /healthz=200 so liveness probes succeed.
    spawn_tier2_probes(Arc::clone(&state), tier2_profile);

    let app = create_router(state);
    let addr = format!("{}:{}", args.bind, args.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!("broker listening on {}", addr);

    let serve_result = tokio::time::timeout(
        std::time::Duration::from_secs(60 * 60 * 24),
        axum::serve(listener, app).with_graceful_shutdown(async move {
            shutdown_signal().await;
            tokio::time::sleep(std::time::Duration::from_secs(grace_seconds)).await;
            tracing::warn!(
                grace_seconds = grace_seconds,
                "shutdown grace expired; forcing exit even if requests are still in flight"
            );
        }),
    )
    .await;

    match serve_result {
        Ok(Ok(())) => tracing::info!("broker shut down cleanly"),
        Ok(Err(e)) => return Err(e.into()),
        Err(_) => tracing::error!("broker hit max-uptime timeout (24h serve loop)"),
    }
    Ok(())
}

/// Spawn the Tier-2 reachability probes that flip the AtomicBool flags
/// on `Tier2State` as each external dependency becomes reachable.
///
/// Phase 0 ships only the backend probe (the only Tier-2 check whose
/// dependencies exist this early). SES + EVM probes land in Phase A.1
/// and Phase C respectively, behind their feature gates.
fn spawn_tier2_probes(
    state: Arc<AppState>,
    profile: agentkeys_broker_server::boot::Tier2Profile,
) {
    use std::sync::atomic::Ordering;
    let backend_url = profile.backend_url.clone();
    let strict = profile.strict;

    tokio::spawn({
        let state = Arc::clone(&state);
        async move {
            loop {
                let url = format!("{}/healthz", backend_url.trim_end_matches('/'));
                let res = state
                    .http
                    .get(&url)
                    .timeout(std::time::Duration::from_secs(3))
                    .send()
                    .await;
                let ok = matches!(&res, Ok(r) if r.status().is_success());
                state.tier2.backend_reachable.store(ok, Ordering::Relaxed);
                if ok {
                    tracing::info!(url = %url, "Tier-2 backend probe: reachable");
                    break;
                }
                if strict {
                    tracing::error!(url = %url, "BROKER_REFUSE_TO_BOOT_STRICT=true and backend unreachable; exiting");
                    std::process::exit(1);
                }
                tracing::warn!(
                    url = %url,
                    "Tier-2 backend probe: unreachable; /readyz will return 503 until reachable"
                );
                tokio::time::sleep(std::time::Duration::from_secs(15)).await;
            }
        }
    });
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        let mut sig = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to register SIGTERM handler — running in a sandbox that blocks signals?");
        sig.recv().await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutdown signal received; draining in-flight requests");
}

fn warn_if_non_loopback_without_tls(bind: &str) {
    let host = bind.split(':').next().unwrap_or(bind);
    let is_loopback = match host.parse::<IpAddr>() {
        Ok(ip) => ip.is_loopback(),
        Err(_) => host == "localhost",
    };
    if !is_loopback {
        tracing::warn!(
            bind = %bind,
            "broker is binding to a non-loopback address without TLS. \
             Bearer tokens and minted AWS credentials will traverse the network in cleartext. \
             Terminate TLS at a reverse proxy (nginx, ALB, Traefik) before exposing the broker."
        );
    }
}
