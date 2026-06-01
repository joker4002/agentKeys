use crate::AppState;
use axum::extract::State;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use std::path::PathBuf;
use std::process::Stdio;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct Worktree {
    pub path: String,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub is_main: bool,
    pub is_detached: bool,
    pub label: String, // short label for UI: branch name, or basename of path, or "(detached)"
    /// Branches that contain this worktree's HEAD. Useful for detached
    /// worktrees so the user can identify them by branch name (e.g. a
    /// worktree at `dazzling-mirzakhani-2a06bc` is recognisable as the
    /// `evm` branch's working copy).
    pub contained_in: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WorktreesPayload {
    pub worktrees: Vec<Worktree>,
    pub current: String,
    pub error: Option<String>,
}

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let current = state.repo.to_string_lossy().to_string();

    // Try git worktree list --porcelain from the configured repo. If that
    // fails, fall back to a single-entry list with just the current repo.
    let output = Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .current_dir(state.repo.as_path())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await;

    let mut worktrees: Vec<Worktree> = Vec::new();
    let mut error: Option<String> = None;

    match output {
        Ok(out) if out.status.success() => {
            let text = String::from_utf8_lossy(&out.stdout);
            worktrees = parse_porcelain(&text);
        }
        Ok(out) => {
            error = Some(
                String::from_utf8_lossy(&out.stderr)
                    .trim()
                    .to_string()
                    .lines()
                    .next()
                    .unwrap_or("git worktree list failed")
                    .to_string(),
            );
        }
        Err(e) => {
            error = Some(format!("git not found: {e}"));
        }
    }

    // Enrich each worktree with the branches that contain its HEAD. For
    // detached worktrees this is the only way to surface the human-readable
    // branch the user thinks of (e.g. `evm`).
    for wt in worktrees.iter_mut() {
        if let Some(head) = &wt.head {
            wt.contained_in = branches_containing(state.repo.as_path(), head).await;
        }
        // Promote a recognisable branch into the label for detached worktrees.
        if wt.is_detached {
            if let Some(name) = wt
                .contained_in
                .iter()
                .find(|b| !is_uninteresting_label(b))
                .cloned()
            {
                wt.label = name;
            }
        }
    }

    if worktrees.is_empty() {
        worktrees.push(Worktree {
            path: current.clone(),
            branch: None,
            head: None,
            is_main: true,
            is_detached: false,
            label: PathBuf::from(&current)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("repo")
                .to_string(),
            contained_in: Vec::new(),
        });
    }

    Json(WorktreesPayload {
        worktrees,
        current,
        error,
    })
    .into_response()
}

async fn branches_containing(repo: &std::path::Path, head: &str) -> Vec<String> {
    let output = Command::new("git")
        .args([
            "branch",
            "-a",
            "--contains",
            head,
            "--format=%(refname:short)",
        ])
        .current_dir(repo)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await;
    let Ok(out) = output else { return Vec::new() };
    if !out.status.success() {
        return Vec::new();
    }
    let mut names: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| l.trim().trim_start_matches('+').trim().to_string())
        .filter(|s| !s.is_empty() && !s.contains("HEAD"))
        .collect();
    // Local branches first; remotes after; ignore origin's HEAD pointer.
    names.sort_by_key(|n| {
        let local = !n.starts_with("origin/") && !n.starts_with("remotes/");
        let claude = n.starts_with("claude/");
        // tuple ordering: false sorts before true; we want non-remote, non-claude first
        (!local, claude, n.clone())
    });
    names.truncate(6);
    names
}

fn is_uninteresting_label(b: &str) -> bool {
    b.starts_with("origin/")
        || b.starts_with("remotes/")
        || b.starts_with("claude/")
        || b == "HEAD"
}

fn parse_porcelain(text: &str) -> Vec<Worktree> {
    let mut out: Vec<Worktree> = Vec::new();
    let mut path: Option<String> = None;
    let mut head: Option<String> = None;
    let mut branch: Option<String> = None;
    let mut detached = false;
    let mut is_first = true;

    let flush = |path: &mut Option<String>,
                 head: &mut Option<String>,
                 branch: &mut Option<String>,
                 detached: &mut bool,
                 is_first: &mut bool,
                 out: &mut Vec<Worktree>| {
        if let Some(p) = path.take() {
            let b = branch.take();
            let label = b
                .as_deref()
                .map(|s| s.trim_start_matches("refs/heads/").to_string())
                .or_else(|| {
                    PathBuf::from(&p)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .map(|s| s.to_string())
                })
                .unwrap_or_else(|| "(detached)".to_string());
            out.push(Worktree {
                path: p,
                branch: b,
                head: head.take(),
                is_main: *is_first,
                is_detached: *detached,
                label,
                contained_in: Vec::new(),
            });
            *is_first = false;
            *detached = false;
        }
    };

    for raw in text.lines() {
        let line = raw.trim_end();
        if line.is_empty() {
            flush(
                &mut path,
                &mut head,
                &mut branch,
                &mut detached,
                &mut is_first,
                &mut out,
            );
            continue;
        }
        if let Some(p) = line.strip_prefix("worktree ") {
            // new entry — flush any in-progress one first
            flush(
                &mut path,
                &mut head,
                &mut branch,
                &mut detached,
                &mut is_first,
                &mut out,
            );
            path = Some(p.to_string());
        } else if let Some(h) = line.strip_prefix("HEAD ") {
            head = Some(h.to_string());
        } else if let Some(b) = line.strip_prefix("branch ") {
            branch = Some(b.to_string());
        } else if line == "detached" {
            detached = true;
        }
    }
    flush(
        &mut path,
        &mut head,
        &mut branch,
        &mut detached,
        &mut is_first,
        &mut out,
    );
    out
}

/// Return the canonicalized roots of every worktree linked to `state.repo`.
/// Used by the markdown sandbox so files in any worktree can be opened, not
/// just the one the server was launched from.
pub async fn worktree_roots(state: &AppState) -> Vec<PathBuf> {
    let output = Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .current_dir(state.repo.as_path())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await;
    let Ok(out) = output else { return Vec::new() };
    if !out.status.success() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&out.stdout);
    parse_porcelain(&text)
        .into_iter()
        .filter_map(|wt| std::fs::canonicalize(&wt.path).ok())
        .collect()
}

/// Resolve a frontend-supplied `?repo=<path>` to an actual filesystem path,
/// only honouring it if it appears in `git worktree list`. Anything else
/// silently falls back to `state.repo`. This is the security guard for all
/// endpoints that accept a `repo` override.
pub async fn resolve_repo(state: &AppState, override_path: Option<&str>) -> PathBuf {
    let default: PathBuf = (*state.repo).clone();
    let Some(req) = override_path else {
        return default;
    };
    if req.is_empty() {
        return default;
    }
    let canon_req = match std::fs::canonicalize(req) {
        Ok(p) => p,
        Err(_) => return default,
    };

    let output = Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .current_dir(state.repo.as_path())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await;
    let Ok(out) = output else {
        return default;
    };
    if !out.status.success() {
        return default;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    for wt in parse_porcelain(&text) {
        if let Ok(canon_wt) = std::fs::canonicalize(&wt.path) {
            if canon_wt == canon_req {
                return canon_req;
            }
        }
    }
    default
}
