use crate::AppState;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use cargo_metadata::MetadataCommand;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct CrateInfo {
    pub name: String,
    pub version: String,
    pub manifest_path: String,
    pub deps: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct CratesPayload {
    pub crates: Vec<CrateInfo>,
}

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let repo = state.repo.clone();
    let cache = state.crates_cache.clone();
    let result = cache
        .get_or_refresh(|| async move {
            let metadata = MetadataCommand::new()
                .manifest_path(repo.join("Cargo.toml"))
                .no_deps()
                .exec()
                .map_err(|e| anyhow::anyhow!("cargo metadata failed: {e}"))?;
            let workspace_members: std::collections::HashSet<_> =
                metadata.workspace_members.iter().cloned().collect();
            let workspace_names: std::collections::HashSet<String> = metadata
                .packages
                .iter()
                .filter(|p| workspace_members.contains(&p.id))
                .map(|p| p.name.clone())
                .collect();
            let mut crates: Vec<CrateInfo> = metadata
                .packages
                .iter()
                .filter(|pkg| workspace_members.contains(&pkg.id))
                .map(|pkg| CrateInfo {
                    name: pkg.name.clone(),
                    version: pkg.version.to_string(),
                    manifest_path: pkg.manifest_path.to_string(),
                    deps: pkg
                        .dependencies
                        .iter()
                        .filter(|d| workspace_names.contains(&d.name))
                        .map(|d| d.name.clone())
                        .collect(),
                })
                .collect();
            crates.sort_by(|a, b| a.name.cmp(&b.name));
            Ok::<_, anyhow::Error>(CratesPayload { crates })
        })
        .await;

    match result {
        Ok(payload) => Json(payload).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("error: {e}")).into_response(),
    }
}
