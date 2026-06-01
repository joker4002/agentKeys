use anyhow::Result;
use clap::Parser;
use std::net::SocketAddr;
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "agentkeys-viz", about = "Three Kingdoms pixel-art code dashboard")]
struct Cli {
    #[arg(long, env = "AGENTKEYS_VIZ_PORT", default_value_t = 8092)]
    port: u16,

    #[arg(long, env = "AGENTKEYS_VIZ_HOST", default_value = "127.0.0.1")]
    host: String,

    #[arg(long, env = "AGENTKEYS_VIZ_DEV", default_value_t = false)]
    dev: bool,

    /// Path to the agentKeys repo (where Cargo.toml lives).
    #[arg(long, env = "AGENTKEYS_VIZ_REPO", default_value = "../..")]
    repo: PathBuf,

    /// Path to the built frontend (web/dist).
    #[arg(long, env = "AGENTKEYS_VIZ_STATIC", default_value = "../web/dist")]
    static_dir: PathBuf,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,agentkeys_viz=debug")),
        )
        .init();

    let cli = Cli::parse();
    let repo = cli.repo.canonicalize().unwrap_or(cli.repo.clone());
    let static_dir = cli.static_dir.canonicalize().unwrap_or(cli.static_dir.clone());

    let state = agentkeys_viz::AppState::new(repo.clone());
    let app = agentkeys_viz::router(state, &static_dir, cli.dev);

    let addr: SocketAddr = format!("{}:{}", cli.host, cli.port).parse()?;
    tracing::info!(%addr, repo = %repo.display(), static_dir = %static_dir.display(), dev = cli.dev, "viz listening");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
