use crate::AppState;
use axum::extract::State;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use serde_json::Value;
use std::process::Stdio;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct GhPayload {
    pub items: Value,
    pub error: Option<String>,
}

async fn run_gh(repo: &std::path::Path, args: &[&str]) -> Result<Value, String> {
    let output = Command::new("gh")
        .args(args)
        .current_dir(repo)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("gh not found: {e}; install gh and run `gh auth login`"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("gh failed: {}", stderr.trim()));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    serde_json::from_str(&stdout).map_err(|e| format!("invalid gh json: {e}"))
}

pub async fn prs_handler(State(state): State<AppState>) -> impl IntoResponse {
    let result = run_gh(
        &state.repo,
        &[
            "pr",
            "list",
            "--state",
            "open",
            "--json",
            "number,title,state,author,url,updatedAt,labels,isDraft",
            "--limit",
            "30",
        ],
    )
    .await;
    match result {
        Ok(items) => Json(GhPayload { items, error: None }).into_response(),
        Err(e) => Json(GhPayload {
            items: Value::Array(vec![]),
            error: Some(e),
        })
        .into_response(),
    }
}

pub async fn issues_handler(State(state): State<AppState>) -> impl IntoResponse {
    let result = run_gh(
        &state.repo,
        &[
            "issue",
            "list",
            "--state",
            "open",
            "--json",
            "number,title,state,author,url,updatedAt,labels",
            "--limit",
            "30",
        ],
    )
    .await;
    match result {
        Ok(items) => Json(GhPayload { items, error: None }).into_response(),
        Err(e) => Json(GhPayload {
            items: Value::Array(vec![]),
            error: Some(e),
        })
        .into_response(),
    }
}
