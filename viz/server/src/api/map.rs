use crate::AppState;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
pub struct MapPayload {
    pub layout: Value,
    pub overrides: Value,
    pub layout_path: String,
    pub overrides_path: String,
    pub error: Option<String>,
}

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let viz_dir = state.repo.join("viz/web/public");
    let layout_path = viz_dir.join("map-layout.json");
    let overrides_path = viz_dir.join("map-layout.overrides.json");

    let read_json = |p: &std::path::Path| -> Value {
        std::fs::read_to_string(p)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or(Value::Object(serde_json::Map::new()))
    };

    let payload = MapPayload {
        layout: read_json(&layout_path),
        overrides: read_json(&overrides_path),
        layout_path: layout_path.to_string_lossy().to_string(),
        overrides_path: overrides_path.to_string_lossy().to_string(),
        error: if layout_path.exists() {
            None
        } else {
            Some("map-layout.json not found; run /agentkeys-viz-sync".into())
        },
    };

    let status = if payload.error.is_some() && !layout_path.exists() {
        StatusCode::OK
    } else {
        StatusCode::OK
    };
    (status, Json(payload)).into_response()
}
