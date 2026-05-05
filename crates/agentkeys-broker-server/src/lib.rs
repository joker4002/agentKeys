pub mod audit;
pub mod auth;
pub mod boot;
pub mod config;
pub mod env;
pub mod error;
pub mod handlers;
pub mod identity;
pub mod jwt;
pub mod oidc;
pub mod plugins;
pub mod state;
pub mod storage;
pub mod sts;

use axum::{routing::{get, post}, Router};

use state::SharedState;

pub fn create_router(state: SharedState) -> Router {
    Router::new()
        .route("/healthz", get(handlers::broker_status::healthz))
        .route("/readyz", get(handlers::broker_status::readyz))
        .route("/v1/mint-aws-creds", post(handlers::mint::mint_aws_creds))
        .route(
            "/.well-known/openid-configuration",
            get(handlers::oidc::discovery),
        )
        .route("/.well-known/jwks.json", get(handlers::oidc::jwks))
        .route("/v1/mint-oidc-jwt", post(handlers::oidc::mint_oidc_jwt))
        // Stage 7 §3.5 — pluggable auth surface.
        .route(
            "/v1/auth/wallet/start",
            post(handlers::auth::wallet_start::wallet_start),
        )
        .route(
            "/v1/auth/wallet/verify",
            post(handlers::auth::wallet_verify::wallet_verify),
        )
        .route("/v1/auth/exchange", post(handlers::auth::exchange::exchange))
        .with_state(state)
}
