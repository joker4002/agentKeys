pub mod api;
pub mod cache;
pub mod paths;
pub mod ps;
pub mod sniff;

use axum::routing::get;
use axum::Router;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tower_http::cors::CorsLayer;
use tower_http::services::ServeDir;
use tower_http::trace::TraceLayer;

#[derive(Clone)]
pub struct AppState {
    pub repo: Arc<PathBuf>,
    pub crates_cache: cache::TimedCache<api::crates_meta::CratesPayload>,
    pub graph_cache: cache::TimedCache<api::graph::GraphPayload>,
    pub plans_cache: cache::TimedCache<api::plans::PlansPayload>,
    pub plugins_cache: cache::TimedCache<api::plugins::PluginsPayload>,
    pub contracts_cache: cache::TimedCache<api::contracts::ContractsPayload>,
}

impl AppState {
    pub fn new(repo: PathBuf) -> Self {
        Self {
            repo: Arc::new(repo),
            crates_cache: cache::TimedCache::new(std::time::Duration::from_secs(30)),
            graph_cache: cache::TimedCache::new(std::time::Duration::from_secs(30)),
            plans_cache: cache::TimedCache::new(std::time::Duration::from_secs(5)),
            plugins_cache: cache::TimedCache::new(std::time::Duration::from_secs(30)),
            contracts_cache: cache::TimedCache::new(std::time::Duration::from_secs(30)),
        }
    }
}

pub fn router(state: AppState, static_dir: &Path, dev: bool) -> Router {
    let api = Router::new()
        .route("/crates", get(api::crates_meta::handler))
        .route("/graph", get(api::graph::handler))
        .route("/plans", get(api::plans::list_handler))
        .route("/plans/:slug", get(api::plans::detail_handler))
        .route("/claude-plans", get(api::claude_plans::handler))
        .route("/docs", get(api::docs::handler))
        .route("/scripts", get(api::scripts::handler))
        .route("/plugins", get(api::plugins::handler))
        .route("/contracts", get(api::contracts::handler))
        .route("/battles", get(api::battles::sse_handler))
        .route("/battles/:pid", get(api::battle_detail::handler))
        .route("/map", get(api::map::handler))
        .route("/markdown", get(api::markdown::handler))
        .route("/tests", get(api::tests::handler))
        .route("/env-settings", get(api::env_settings::handler))
        .route("/cloud-settings", get(api::cloud_settings::handler))
        .route("/gh/prs", get(api::gh::prs_handler))
        .route("/gh/issues", get(api::gh::issues_handler))
        .route("/jj", get(api::jj::handler))
        .route("/worktrees", get(api::worktrees::handler))
        .with_state(state);

    let mut app = Router::new()
        .nest("/api", api)
        .layer(TraceLayer::new_for_http());

    if dev {
        app = app.layer(CorsLayer::permissive());
    } else if static_dir.exists() {
        app = app.fallback_service(
            ServeDir::new(static_dir).append_index_html_on_directories(true),
        );
    }

    app
}
