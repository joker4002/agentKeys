use crate::AppState;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use walkdir::WalkDir;

#[derive(Debug, Clone, Serialize)]
pub struct Contract {
    pub name: String,
    pub file: String,
    pub line_count: usize,
    pub function_count: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct ContractsPayload {
    pub solidity_dir: String,
    pub foundry_toml: Option<String>,
    pub contracts: Vec<Contract>,
    pub audit_plugin: Option<String>,
    pub audit_active: bool,
    pub error: Option<String>,
}

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let repo = state.repo.clone();
    let cache = state.contracts_cache.clone();
    let result = cache
        .get_or_refresh(|| async move {
            let solidity_dir = repo.join("crates/agentkeys-broker-server/solidity");
            if !solidity_dir.exists() {
                return Ok::<_, anyhow::Error>(ContractsPayload {
                    solidity_dir: solidity_dir.to_string_lossy().to_string(),
                    foundry_toml: None,
                    contracts: vec![],
                    audit_plugin: None,
                    audit_active: false,
                    error: Some("solidity/ directory not found on this branch".into()),
                });
            }
            let foundry_toml = {
                let p = solidity_dir.join("foundry.toml");
                p.exists().then(|| p.to_string_lossy().to_string())
            };
            let mut contracts = Vec::new();
            for entry in WalkDir::new(solidity_dir.join("src"))
                .max_depth(4)
                .into_iter()
                .filter_map(|e| e.ok())
            {
                let path = entry.path();
                if path.extension().and_then(|s| s.to_str()) != Some("sol") {
                    continue;
                }
                let body = match std::fs::read_to_string(path) {
                    Ok(b) => b,
                    Err(_) => continue,
                };
                let line_count = body.lines().count();
                let function_count = body
                    .lines()
                    .filter(|l| {
                        let t = l.trim_start();
                        t.starts_with("function ") || t.starts_with("function(")
                    })
                    .count();
                let name = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("?")
                    .to_string();
                contracts.push(Contract {
                    name,
                    file: path.to_string_lossy().to_string(),
                    line_count,
                    function_count,
                });
            }
            contracts.sort_by(|a, b| a.name.cmp(&b.name));

            let audit_plugin_path = repo
                .join("crates/agentkeys-broker-server/src/plugins/audit/evm.rs");
            let audit_plugin = audit_plugin_path
                .exists()
                .then(|| audit_plugin_path.to_string_lossy().to_string());
            let audit_active = {
                let manifest = repo.join("crates/agentkeys-broker-server/Cargo.toml");
                std::fs::read_to_string(&manifest)
                    .ok()
                    .and_then(|raw| toml::from_str::<toml::Value>(&raw).ok())
                    .and_then(|v| {
                        v.get("features")
                            .and_then(|f| f.get("default"))
                            .and_then(|d| d.as_array())
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|x| x.as_str())
                                    .any(|s| s == "audit-evm")
                            })
                    })
                    .unwrap_or(false)
            };

            Ok(ContractsPayload {
                solidity_dir: solidity_dir.to_string_lossy().to_string(),
                foundry_toml,
                contracts,
                audit_plugin,
                audit_active,
                error: None,
            })
        })
        .await;

    match result {
        Ok(p) => Json(p).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("error: {e}")).into_response(),
    }
}
