use crate::api::worktrees::worktree_roots;
use crate::{paths, AppState};
use axum::extract::{Query, State};
use axum::response::{IntoResponse, Json};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
pub struct MarkdownQuery {
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct MarkdownPayload {
    pub path: String,
    pub raw_markdown: String,
    pub error: Option<String>,
}

pub async fn handler(
    State(state): State<AppState>,
    Query(q): Query<MarkdownQuery>,
) -> impl IntoResponse {
    let path = expand(&q.path);
    let roots = worktree_roots(&state).await;

    if !is_safe(&path, &state, &roots) {
        return Json(MarkdownPayload {
            path: path.to_string_lossy().to_string(),
            raw_markdown: String::new(),
            error: Some("path outside allowed roots".into()),
        })
        .into_response();
    }

    if !path.exists() {
        return Json(MarkdownPayload {
            path: path.to_string_lossy().to_string(),
            raw_markdown: String::new(),
            error: Some(format!("not found: {}", path.display())),
        })
        .into_response();
    }

    match std::fs::read_to_string(&path) {
        Ok(body) => Json(MarkdownPayload {
            path: path.to_string_lossy().to_string(),
            raw_markdown: body,
            error: None,
        })
        .into_response(),
        Err(e) => Json(MarkdownPayload {
            path: path.to_string_lossy().to_string(),
            raw_markdown: String::new(),
            error: Some(format!("read failed: {e}")),
        })
        .into_response(),
    }
}

fn expand(s: &str) -> PathBuf {
    if let Some(stripped) = s.strip_prefix("~/") {
        if let Some(home) = paths::home_dir() {
            return home.join(stripped);
        }
    }
    PathBuf::from(s)
}

fn is_safe(path: &std::path::Path, state: &AppState, worktree_roots: &[PathBuf]) -> bool {
    // Allow:
    //   1. Anything under the configured repo root.
    //   2. Anything under any worktree linked to that repo (so the
    //      WorktreeSwitcher can browse files from sibling worktrees).
    //   3. Anything under ~/.claude/.
    //   4. Specific dotfiles in ~ (zshenv, zshrc, bashrc, profile, AGENTS.md, CLAUDE.md).
    let canonical = path.canonicalize().ok();
    let path_to_check = canonical.as_deref().unwrap_or(path);
    if path_to_check.starts_with(state.repo.as_path()) {
        return true;
    }
    for root in worktree_roots {
        if path_to_check.starts_with(root) {
            return true;
        }
    }
    if let Some(home) = paths::home_dir() {
        let claude = home.join(".claude");
        if path_to_check.starts_with(&claude) {
            return true;
        }
        let allowed_dotfiles = [".zshenv", ".zshrc", ".bashrc", ".profile", "AGENTS.md", "CLAUDE.md"];
        if let Some(parent) = path.parent() {
            if parent == home {
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    if allowed_dotfiles.contains(&name) {
                        return true;
                    }
                }
            }
        }
    }
    false
}
