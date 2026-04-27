use std::net::IpAddr;
use std::sync::Arc;

use agentkeys_broker_server::{
    audit::AuditLog,
    config::BrokerConfig,
    create_router,
    state::AppState,
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

    let audit = AuditLog::open(&config.audit_db_path)?;
    let sts = AwsStsClient::from_keys(
        &config.daemon_access_key_id,
        &config.daemon_secret_access_key,
        &config.aws_region,
    )
    .await;

    if !args.skip_startup_check {
        match sts.caller_identity_ok().await {
            Ok(()) => tracing::info!("startup STS check passed"),
            Err(e) => {
                tracing::error!(error = %e, "startup STS check failed — refusing to bind");
                anyhow::bail!(
                    "startup STS check failed: {}. Verify BROKER_DAEMON_ACCESS_KEY_ID / BROKER_DAEMON_SECRET_ACCESS_KEY / BROKER_AWS_REGION, or pass --skip-startup-check for offline dev.",
                    e
                );
            }
        }
    }

    let state = Arc::new(AppState {
        config,
        http: reqwest::Client::new(),
        audit,
        sts: Arc::new(sts),
    });

    let app = create_router(state);
    let addr = format!("{}:{}", args.bind, args.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    tracing::info!("broker listening on {}", addr);
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    tracing::info!("broker shut down cleanly");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sig) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sig.recv().await;
        }
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
