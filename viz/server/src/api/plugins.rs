use crate::AppState;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use std::path::Path;

#[derive(Debug, Clone, Serialize)]
pub struct PluginImpl {
    pub layer: String,
    pub name: String,
    pub file: String,
    pub feature_flag: Option<String>,
    pub active: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct PluginsPayload {
    pub broker_manifest: String,
    pub default_features: Vec<String>,
    pub all_features: Vec<String>,
    pub plugins: Vec<PluginImpl>,
    pub trait_files: Vec<String>,
    pub storage_modules: Vec<String>,
    pub error: Option<String>,
}

const PLUGIN_FEATURE_MAP: &[(&str, &str, &str)] = &[
    ("auth/email_link.rs", "auth", "auth-email-link"),
    ("auth/wallet_sig.rs", "auth", "auth-wallet-sig"),
    ("auth/oauth2/google.rs", "auth", "auth-oauth2-google"),
    ("auth/oauth2/mod.rs", "auth", "auth-oauth2"),
    ("audit/sqlite.rs", "audit", "audit-sqlite"),
    ("audit/evm.rs", "audit", "audit-evm"),
    ("audit/breaker.rs", "audit", ""),
    ("wallet/keystore.rs", "wallet", "wallet-keystore"),
];

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let repo = state.repo.clone();
    let cache = state.plugins_cache.clone();
    let result = cache
        .get_or_refresh(|| async move {
            let manifest = repo.join("crates/agentkeys-broker-server/Cargo.toml");
            if !manifest.exists() {
                return Ok::<_, anyhow::Error>(PluginsPayload {
                    broker_manifest: manifest.to_string_lossy().to_string(),
                    default_features: vec![],
                    all_features: vec![],
                    plugins: vec![],
                    trait_files: vec![],
                    storage_modules: vec![],
                    error: Some("agentkeys-broker-server not found on this branch".into()),
                });
            }
            let raw = std::fs::read_to_string(&manifest)?;
            let parsed: toml::Value = toml::from_str(&raw)?;
            let features = parsed.get("features").and_then(|v| v.as_table());
            let default_features: Vec<String> = features
                .and_then(|t| t.get("default"))
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|x| x.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            let mut all_features: Vec<String> = features
                .map(|t| t.keys().cloned().collect())
                .unwrap_or_default();
            all_features.sort();

            let plugins_dir = repo.join("crates/agentkeys-broker-server/src/plugins");
            let mut plugins = Vec::new();
            for (rel_path, layer, flag) in PLUGIN_FEATURE_MAP {
                let path = plugins_dir.join(rel_path);
                if !path.exists() {
                    continue;
                }
                let feature_flag = if flag.is_empty() { None } else { Some((*flag).to_string()) };
                let active = match &feature_flag {
                    Some(f) => default_features.contains(f),
                    None => true,
                };
                let name = Path::new(rel_path)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or(rel_path)
                    .to_string();
                plugins.push(PluginImpl {
                    layer: layer.to_string(),
                    name,
                    file: path.to_string_lossy().to_string(),
                    feature_flag,
                    active,
                });
            }

            let trait_files: Vec<String> = ["audit/mod.rs", "auth/mod.rs", "wallet/mod.rs", "mod.rs"]
                .iter()
                .filter_map(|rel| {
                    let p = plugins_dir.join(rel);
                    p.exists().then(|| p.to_string_lossy().to_string())
                })
                .collect();

            let storage_dir = repo.join("crates/agentkeys-broker-server/src/storage");
            let mut storage_modules = Vec::new();
            if storage_dir.exists() {
                for entry in std::fs::read_dir(&storage_dir)? {
                    let entry = match entry {
                        Ok(e) => e,
                        Err(_) => continue,
                    };
                    let path = entry.path();
                    if path.extension().and_then(|s| s.to_str()) != Some("rs") {
                        continue;
                    }
                    if path.file_name().and_then(|s| s.to_str()) == Some("mod.rs") {
                        continue;
                    }
                    storage_modules.push(path.to_string_lossy().to_string());
                }
                storage_modules.sort();
            }

            Ok(PluginsPayload {
                broker_manifest: manifest.to_string_lossy().to_string(),
                default_features,
                all_features,
                plugins,
                trait_files,
                storage_modules,
                error: None,
            })
        })
        .await;

    match result {
        Ok(p) => Json(p).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("error: {e}")).into_response(),
    }
}
