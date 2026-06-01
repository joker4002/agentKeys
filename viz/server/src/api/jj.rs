use crate::AppState;
use axum::extract::State;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use std::process::Stdio;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct JjEntry {
    pub change_id: String,
    pub description: String,
    pub bookmarks: Vec<String>,
    pub is_working_copy: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct JjBookmark {
    pub name: String,
    pub change_id: String,
    pub description: String,
    pub remote: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct JjPayload {
    pub log: Vec<JjEntry>,
    pub bookmarks: Vec<JjBookmark>,
    pub repo: String,
    pub error: Option<String>,
}

const FIELD: &str = "@@@";

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let repo = state.repo.to_string_lossy().to_string();

    // Recent log: change_id @@@ first-line @@@ bookmarks @@@ working-copy?
    let log_template = format!(
        "change_id.shortest(8) ++ \"{f}\" ++ description.first_line() ++ \"{f}\" ++ bookmarks ++ \"{f}\" ++ if(current_working_copy, \"1\", \"0\") ++ \"\\n\"",
        f = FIELD,
    );
    let log_out = run_jj(
        &state.repo,
        &[
            "log",
            "--no-graph",
            "--limit",
            "40",
            "--color=never",
            "-T",
            &log_template,
        ],
    )
    .await;

    let log_entries = match log_out {
        Ok(text) => text
            .lines()
            .filter_map(|line| {
                let parts: Vec<&str> = line.splitn(4, FIELD).collect();
                if parts.len() < 4 {
                    return None;
                }
                Some(JjEntry {
                    change_id: parts[0].trim().to_string(),
                    description: parts[1].trim().to_string(),
                    bookmarks: parts[2]
                        .split_whitespace()
                        .map(|s| s.trim_end_matches('*').to_string())
                        .filter(|s| !s.is_empty())
                        .collect(),
                    is_working_copy: parts[3].trim() == "1",
                })
            })
            .collect::<Vec<_>>(),
        Err(_) => Vec::new(),
    };

    // Bookmarks: name @@@ target-change @@@ first-line
    let bm_template = format!(
        "self.name() ++ \"{f}\" ++ self.normal_target().change_id().shortest(8) ++ \"{f}\" ++ self.normal_target().description().first_line() ++ \"\\n\"",
        f = FIELD,
    );
    let bm_out = run_jj(&state.repo, &["bookmark", "list", "--color=never", "-T", &bm_template]).await;

    let bookmarks = match bm_out {
        Ok(text) => text
            .lines()
            .filter_map(|line| {
                let parts: Vec<&str> = line.splitn(3, FIELD).collect();
                if parts.len() < 3 {
                    return None;
                }
                let raw_name = parts[0].trim();
                let (name, remote) = if let Some((local, rem)) = raw_name.split_once('@') {
                    (local.to_string(), Some(rem.to_string()))
                } else {
                    (raw_name.to_string(), None)
                };
                Some(JjBookmark {
                    name,
                    change_id: parts[1].trim().to_string(),
                    description: parts[2].trim().to_string(),
                    remote,
                })
            })
            .collect::<Vec<_>>(),
        Err(_) => Vec::new(),
    };

    let error = if log_entries.is_empty() && bookmarks.is_empty() {
        Some("jj not available, or this directory is not a jj repo".to_string())
    } else {
        None
    };

    Json(JjPayload {
        log: log_entries,
        bookmarks,
        repo,
        error,
    })
    .into_response()
}

async fn run_jj(cwd: &std::path::Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("jj")
        .args(args)
        .current_dir(cwd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("jj not found: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        return Err(stderr);
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}
