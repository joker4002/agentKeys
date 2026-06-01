use crate::{paths, AppState};
use axum::extract::State;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize)]
pub struct EnvFile {
    pub path: String,
    pub exists: bool,
    pub size_bytes: u64,
    pub line_count: usize,
    pub excerpt: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct EnvVar {
    pub key: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct EnvSettingsPayload {
    pub files: Vec<EnvFile>,
    pub env_vars: Vec<EnvVar>,
    pub error: Option<String>,
}

const MAX_EXCERPT_LINES: usize = 60;

const SAFE_VAR_PREFIXES: &[&str] = &[
    "AGENTKEYS_",
    "BROKER_",
    "CARGO_",
    "RUST_",
    "PATH",
    "HOME",
    "USER",
    "SHELL",
    "TERM",
    "EDITOR",
    "LANG",
    "LC_",
    "OMC_",
    "CLAUDE_",
    "ANTHROPIC_",
];

const SECRET_HINTS: &[&str] = &[
    "TOKEN", "SECRET", "PASSWORD", "KEY", "API",
];

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let mut files = Vec::new();
    let mut candidates: Vec<PathBuf> = vec![
        paths::home_dir().map(|h| h.join(".zshenv")),
        paths::home_dir().map(|h| h.join(".zshrc")),
        paths::home_dir().map(|h| h.join(".bashrc")),
        paths::home_dir().map(|h| h.join(".profile")),
        paths::home_dir().map(|h| h.join(".ssh").join("config")),
        paths::home_dir().map(|h| h.join(".aws").join("config")),
        paths::home_dir().map(|h| h.join(".aws").join("credentials")),
        paths::home_dir().map(|h| h.join(".claude").join("CLAUDE.md")),
        paths::home_dir().map(|h| h.join(".claude").join("settings.json")),
        Some(state.repo.join("CLAUDE.md")),
        Some(state.repo.join("AGENTS.md")),
        Some(state.repo.join(".claude").join("settings.json")),
        Some(state.repo.join(".claude").join("settings.local.json")),
    ]
    .into_iter()
    .flatten()
    .collect();

    // Discover *.env* files in the repo root and home dir so secrets-style
    // files (agentkeys-secrets.env, .env, .env.local, .env.example, ...) show
    // up in the env page automatically. Sensitive values in any line that
    // looks like `KEY=secret` are redacted before the excerpt is sent.
    candidates.extend(discover_env_files(state.repo.as_path()));
    if let Some(home) = paths::home_dir() {
        candidates.extend(discover_env_files(&home));
    }

    for path in candidates {
        let exists = path.exists();
        let is_env_file = is_env_filename(&path);
        let (size_bytes, line_count, excerpt) = if exists {
            let body = std::fs::read_to_string(&path).unwrap_or_default();
            let lc = body.lines().count();
            let excerpt: String = body
                .lines()
                .take(MAX_EXCERPT_LINES)
                .map(|line| {
                    if is_env_file {
                        redact_env_line(line)
                    } else {
                        line.to_string()
                    }
                })
                .collect::<Vec<_>>()
                .join("\n");
            (body.len() as u64, lc, excerpt)
        } else {
            (0, 0, String::new())
        };
        files.push(EnvFile {
            path: path.to_string_lossy().to_string(),
            exists,
            size_bytes,
            line_count,
            excerpt,
        });
    }

    // Pull only safe-prefixed env vars (avoid leaking secrets even though
    // the user is on localhost).
    let mut env_vars: Vec<EnvVar> = std::env::vars()
        .filter(|(k, _)| {
            let upper = k.to_uppercase();
            SAFE_VAR_PREFIXES.iter().any(|p| upper.starts_with(p))
        })
        .map(|(k, v)| {
            let upper = k.to_uppercase();
            let value = if SECRET_HINTS.iter().any(|h| upper.contains(h)) {
                redact(&v)
            } else {
                v
            };
            EnvVar { key: k, value }
        })
        .collect();
    env_vars.sort_by(|a, b| a.key.cmp(&b.key));

    Json(EnvSettingsPayload {
        files,
        env_vars,
        error: None,
    })
    .into_response()
}

fn redact(value: &str) -> String {
    if value.len() <= 8 {
        "***".to_string()
    } else {
        format!("{}…{} ({} chars)", &value[..3], &value[value.len() - 3..], value.len())
    }
}

/// True when the filename looks like an env-style file (.env, .env.local,
/// agentkeys-secrets.env, foo.env.example, ...). Used to decide whether to
/// run per-line redaction on the excerpt.
fn is_env_filename(path: &std::path::Path) -> bool {
    let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
        return false;
    };
    let lower = name.to_lowercase();
    if lower == ".env" || lower.starts_with(".env.") {
        return true;
    }
    // matches `foo.env`, `foo.env.example`, `foo.env.local`, etc.
    lower.contains(".env")
        && (lower.ends_with(".env")
            || lower.contains(".env.")
            || lower.ends_with(".env.example")
            || lower.ends_with(".env.local")
            || lower.ends_with(".env.sample")
            || lower.ends_with(".env.template"))
}

/// Scan a directory (non-recursive) for files that look like env files. We
/// intentionally don't walk subdirectories — .env files are conventionally at
/// the root of a project or home dir.
fn discover_env_files(dir: &std::path::Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let Ok(read) = std::fs::read_dir(dir) else {
        return found;
    };
    for entry in read.flatten() {
        let path = entry.path();
        if path.is_file() && is_env_filename(&path) {
            found.push(path);
        }
    }
    found.sort();
    found
}

/// Redact the value half of a `KEY=value` line when the key looks
/// secret-bearing. Leave comments, blank lines, and `KEY=` (no value) alone.
fn redact_env_line(line: &str) -> String {
    let trimmed = line.trim_start();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return line.to_string();
    }
    let Some(eq) = line.find('=') else {
        return line.to_string();
    };
    let (key_part, value_part) = line.split_at(eq);
    let value = &value_part[1..]; // skip the `=`
    if value.is_empty() {
        return line.to_string();
    }
    let upper_key = key_part.trim().to_uppercase();
    let looks_secret = SECRET_HINTS.iter().any(|h| upper_key.contains(h));
    if !looks_secret {
        return line.to_string();
    }
    // Preserve quote characters around the value, if any, so the structure is
    // readable but the secret itself isn't shown.
    let (lead, trail, body) = if let (Some(b'"'), Some(b'"')) =
        (value.as_bytes().first(), value.as_bytes().last())
    {
        ("\"", "\"", &value[1..value.len() - 1])
    } else if let (Some(b'\''), Some(b'\'')) =
        (value.as_bytes().first(), value.as_bytes().last())
    {
        ("'", "'", &value[1..value.len() - 1])
    } else {
        ("", "", value)
    };
    format!("{}={}{}{}", key_part, lead, redact(body), trail)
}
