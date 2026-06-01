use crate::{paths, AppState};
use axum::extract::State;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use std::path::Path;

#[derive(Debug, Clone, Serialize)]
pub struct CloudSetting {
    pub source: String,
    pub path: String,
    pub exists: bool,
    pub description: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CloudUser {
    pub name: String,
    pub source: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CloudSettingsPayload {
    pub settings: Vec<CloudSetting>,
    pub iam_roles: Vec<String>,
    pub users: Vec<CloudUser>,
    pub error: Option<String>,
}

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let home = paths::home_dir().unwrap_or_default();

    let candidates: Vec<(&str, std::path::PathBuf, &str)> = vec![
        (
            "AWS",
            home.join(".aws").join("credentials"),
            "AWS shared credentials file",
        ),
        ("AWS", home.join(".aws").join("config"), "AWS config (profiles, regions)"),
        ("GCP", home.join(".config").join("gcloud"), "Google Cloud SDK config dir"),
        (
            "kubectl",
            home.join(".kube").join("config"),
            "Kubernetes contexts",
        ),
        (
            "Docker",
            home.join(".docker").join("config.json"),
            "Docker registry auth",
        ),
        (
            "GitHub CLI",
            home.join(".config").join("gh").join("hosts.yml"),
            "gh CLI auth hosts",
        ),
        (
            "Anthropic",
            home.join(".claude").join("settings.json"),
            "Claude global settings",
        ),
        (
            "Repo",
            state.repo.join(".env"),
            "Project .env (if present)",
        ),
        (
            "Repo",
            state.repo.join("agentkeys-secrets.env.example"),
            "Repo secrets template",
        ),
    ];

    let settings: Vec<CloudSetting> = candidates
        .into_iter()
        .map(|(source, path, description)| CloudSetting {
            source: source.to_string(),
            path: path.to_string_lossy().to_string(),
            exists: path.exists(),
            description: description.to_string(),
        })
        .collect();

    // Best-effort IAM role discovery — parse `aws iam list-roles --query`
    // is too heavy; instead read the AWS config file for [profile *] sections.
    let mut iam_roles = Vec::new();
    let aws_config = home.join(".aws").join("config");
    if let Ok(body) = std::fs::read_to_string(&aws_config) {
        for line in body.lines() {
            let line = line.trim();
            if line.starts_with("[profile ") && line.ends_with(']') {
                let name = line.trim_start_matches("[profile ").trim_end_matches(']').to_string();
                iam_roles.push(name);
            } else if line.starts_with("role_arn") {
                if let Some(arn) = line.split('=').nth(1) {
                    iam_roles.push(arn.trim().to_string());
                }
            }
        }
    }

    // Users — best-effort: $USER + git config user.name + AWS profiles.
    let mut users = Vec::new();
    if let Ok(u) = std::env::var("USER") {
        users.push(CloudUser {
            name: u,
            source: "$USER".to_string(),
        });
    }
    if let Some(name) = git_config_user(&state.repo) {
        users.push(CloudUser {
            name,
            source: "git config user.name".to_string(),
        });
    }

    Json(CloudSettingsPayload {
        settings,
        iam_roles,
        users,
        error: None,
    })
    .into_response()
}

fn git_config_user(repo: &Path) -> Option<String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["config", "user.name"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}
