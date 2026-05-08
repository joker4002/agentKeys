use agentkeys_mock_server::{create_router, db, dev_key_service::DevKeyService, state::AppState};
use clap::Parser;
use std::sync::Arc;

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = "8090")]
    port: u16,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();
    let args = Args::parse();

    let conn = rusqlite::Connection::open_in_memory().unwrap();
    db::init_schema(&conn).unwrap();

    // Load the dev signer from `DEV_KEY_SERVICE_MASTER_SECRET`. Unset →
    // `/dev/*` returns 503; malformed → fail boot loud (operator error).
    let dev_signer = match DevKeyService::from_env() {
        Ok(opt) => {
            if opt.is_some() {
                eprintln!(
                    "[mock-server] dev_key_service ENABLED (DEV ONLY — replace with TEE worker per issue #74 step 2)"
                );
            } else {
                eprintln!(
                    "[mock-server] dev_key_service disabled (set DEV_KEY_SERVICE_MASTER_SECRET to enable)"
                );
            }
            opt
        }
        Err(e) => {
            eprintln!("[mock-server] FATAL: invalid DEV_KEY_SERVICE_MASTER_SECRET: {e}");
            std::process::exit(2);
        }
    };

    let state = Arc::new(AppState::new(conn).with_dev_signer(dev_signer));

    let app = create_router(state);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", args.port))
        .await
        .unwrap();
    println!("Mock server running on port {}", args.port);
    axum::serve(listener, app).await.unwrap();
}
