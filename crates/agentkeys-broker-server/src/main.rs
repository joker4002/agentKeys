use std::sync::Arc;

use agentkeys_broker_server::{
    audit::AuditLog,
    config::BrokerConfig,
    create_router,
    state::AppState,
    sts::AwsStsClient,
};
use clap::Parser;

#[derive(Parser)]
#[command(name = "agentkeys-broker-server", about = "AgentKeys credential broker")]
struct Args {
    #[arg(long, default_value = "8091")]
    port: u16,

    #[arg(long, default_value = "0.0.0.0")]
    bind: String,
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

    let audit = AuditLog::open(&config.audit_db_path)?;
    let sts = AwsStsClient::from_keys(
        &config.daemon_access_key_id,
        &config.daemon_secret_access_key,
        &config.aws_region,
    )
    .await;

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
    axum::serve(listener, app).await?;
    Ok(())
}
