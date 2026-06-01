use crate::api::worktrees::resolve_repo;
use crate::AppState;
use axum::extract::{Query, State};
use axum::response::{IntoResponse, Json};
use serde::{Deserialize, Serialize};
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

/// `/api/scripts` — surface the repo's `scripts/` folder so operators can
/// orient on what shell ceremonies exist without `cd`-ing or `ls`-ing.
/// Replaces the old `/api/ralph/runs` endpoint that 张飞 used to point at.

#[derive(Debug, Deserialize)]
pub struct ScriptsQuery {
    pub repo: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScriptInfo {
    pub name: String,
    pub path: String,
    pub category: String,
    pub size_bytes: u64,
    pub line_count: usize,
    pub executable: bool,
    pub shebang: Option<String>,
    /// First contiguous block of `#`-prefixed comment lines after the shebang,
    /// joined with newlines and stripped of the leading `# `. Truncated at
    /// `MAX_DESC_LINES` so the panel stays scannable.
    pub description: Option<String>,
    /// First 80 lines of the script body, for the "Preview" disclosure on
    /// the panel. Keeps the payload small while still being useful.
    pub excerpt: String,
    /// Unix mtime as ISO-8601 seconds. None if the FS doesn't report it.
    pub modified: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScriptCategory {
    pub id: String,
    pub label: String,
    pub count: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScriptsPayload {
    pub root: String,
    pub scripts: Vec<ScriptInfo>,
    pub categories: Vec<ScriptCategory>,
    pub error: Option<String>,
}

const MAX_DESC_LINES: usize = 8;
const MAX_EXCERPT_LINES: usize = 80;

pub async fn handler(
    State(state): State<AppState>,
    Query(q): Query<ScriptsQuery>,
) -> impl IntoResponse {
    let repo = resolve_repo(&state, q.repo.as_deref()).await;
    let scripts_dir = repo.join("scripts");
    if !scripts_dir.exists() {
        return Json(ScriptsPayload {
            root: scripts_dir.to_string_lossy().to_string(),
            scripts: vec![],
            categories: vec![],
            error: Some(format!("scripts/ not found at {}", scripts_dir.display())),
        })
        .into_response();
    }

    let mut scripts = walk_scripts(&scripts_dir);
    scripts.sort_by(|a, b| a.category.cmp(&b.category).then_with(|| a.name.cmp(&b.name)));

    let categories = summarize_categories(&scripts);

    Json(ScriptsPayload {
        root: scripts_dir.to_string_lossy().to_string(),
        scripts,
        categories,
        error: None,
    })
    .into_response()
}

fn walk_scripts(dir: &Path) -> Vec<ScriptInfo> {
    let mut out = Vec::new();
    let Ok(read) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in read.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = match path.file_name().and_then(|s| s.to_str()) {
            Some(s) if !s.starts_with('.') => s.to_string(),
            _ => continue,
        };
        let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
        // Accept conventional script extensions + extensionless files that
        // start with a shebang (e.g. polyglot binaries). Skip everything else
        // so README, .lock, .json, etc. don't pollute the panel.
        let is_known_ext = matches!(ext, "sh" | "bash" | "zsh" | "py" | "ts" | "js");
        let body = std::fs::read_to_string(&path).unwrap_or_default();
        let shebang = first_shebang(&body);
        if !is_known_ext && shebang.is_none() {
            continue;
        }
        let size_bytes = body.len() as u64;
        let line_count = body.lines().count();
        let executable = std::fs::metadata(&path)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
        let description = extract_description(&body);
        let excerpt = body
            .lines()
            .take(MAX_EXCERPT_LINES)
            .collect::<Vec<_>>()
            .join("\n");
        let modified = std::fs::metadata(&path)
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| format_unix(d.as_secs()));

        out.push(ScriptInfo {
            category: categorize(&name),
            name,
            path: path.to_string_lossy().to_string(),
            size_bytes,
            line_count,
            executable,
            shebang,
            description,
            excerpt,
            modified,
        });
    }
    out
}

/// First line if it starts with `#!`. Trimmed.
fn first_shebang(body: &str) -> Option<String> {
    let first = body.lines().next()?;
    if first.starts_with("#!") {
        Some(first.trim().to_string())
    } else {
        None
    }
}

/// Pull the doc-comment block that appears just after the optional shebang —
/// contiguous lines starting with `#`. Strip the `#` and one optional space.
/// Stop at the first blank or non-comment line. Truncate at MAX_DESC_LINES.
fn extract_description(body: &str) -> Option<String> {
    let mut lines = body.lines();
    let first = lines.next()?;
    let mut collecting = if first.starts_with("#!") {
        // skip shebang; description starts on next line
        Vec::new()
    } else if first.starts_with('#') {
        vec![strip_comment_prefix(first)]
    } else {
        return None;
    };
    for line in lines {
        let trimmed = line.trim_start();
        if trimmed.is_empty() {
            if !collecting.is_empty() {
                break;
            }
            continue;
        }
        if let Some(stripped) = trimmed.strip_prefix('#') {
            collecting.push(stripped.trim_start().to_string());
        } else {
            break;
        }
        if collecting.len() >= MAX_DESC_LINES {
            break;
        }
    }
    if collecting.is_empty() {
        None
    } else {
        Some(collecting.join("\n"))
    }
}

fn strip_comment_prefix(line: &str) -> String {
    line.trim_start()
        .trim_start_matches('#')
        .trim_start()
        .to_string()
}

/// Category = leading slug before the first `-` or `.`. Examples:
///   `heima-fund.sh`              → "heima"
///   `setup-broker-host.sh`       → "setup"
///   `stage6-demo-env.sh`         → "stage6"
///   `provision-vault-role.sh`    → "provision"
///   `reset-chrome-for-recording.sh` → "reset"
/// Lets the frontend group by ceremony family.
fn categorize(name: &str) -> String {
    let stem = name.split('.').next().unwrap_or(name);
    if let Some(head) = stem.split('-').next() {
        if !head.is_empty() {
            return head.to_lowercase();
        }
    }
    "misc".to_string()
}

fn summarize_categories(scripts: &[ScriptInfo]) -> Vec<ScriptCategory> {
    use std::collections::BTreeMap;
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for s in scripts {
        *counts.entry(s.category.clone()).or_insert(0) += 1;
    }
    counts
        .into_iter()
        .map(|(id, count)| ScriptCategory {
            label: id.clone(),
            id,
            count,
        })
        .collect()
}

/// Format a UNIX timestamp (seconds) as `YYYY-MM-DD HH:MM:SS UTC` without
/// pulling in a heavy date crate. Used purely for display.
fn format_unix(secs: u64) -> String {
    // Days since 1970-01-01
    let days = (secs / 86_400) as i64;
    let time_of_day = secs % 86_400;
    let hours = time_of_day / 3_600;
    let minutes = (time_of_day % 3_600) / 60;
    let seconds = time_of_day % 60;
    let (year, month, day) = civil_from_days(days);
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02} UTC",
        year, month, day, hours, minutes, seconds
    )
}

/// Howard Hinnant's days→(y, m, d) algorithm. Public-domain.
fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = y + if m <= 2 { 1 } else { 0 };
    (y as i32, m as u32, d as u32)
}
