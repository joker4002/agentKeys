use crate::sniff::{extract_title, sniff_kind, PlanKind};
use crate::{paths, AppState};
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub kind: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanSummary {
    pub slug: String,
    pub title: Option<String>,
    pub kind: PlanKind,
    pub mtime_unix: i64,
    pub path: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlansPayload {
    pub plans: Vec<PlanSummary>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanDetail {
    pub slug: String,
    pub title: Option<String>,
    pub kind: PlanKind,
    pub raw_markdown: String,
    pub raw_path: String,
}

pub async fn list_handler(
    State(state): State<AppState>,
    Query(query): Query<ListQuery>,
) -> impl IntoResponse {
    let cache = state.plans_cache.clone();
    let repo = state.repo.clone();
    let payload = cache
        .get_or_refresh(|| async move {
            let mut plans = Vec::new();
            // Both the user's global plans dir AND the project-local one are
            // canonical homes for plans. Merge them, newest first.
            let dirs: Vec<std::path::PathBuf> = vec![
                paths::claude_plans_dir(),
                Some(repo.join(".claude").join("plans")),
            ]
            .into_iter()
            .flatten()
            .filter(|d| d.exists())
            .collect();
            if dirs.is_empty() {
                return Ok::<_, anyhow::Error>(PlansPayload {
                    plans: vec![],
                    error: Some(
                        "no .claude/plans/ found (checked global + project)".into(),
                    ),
                });
            }
            for dir in &dirs {
                let read = match std::fs::read_dir(dir) {
                    Ok(r) => r,
                    Err(_) => continue,
                };
                for entry in read {
                    let entry = match entry {
                        Ok(e) => e,
                        Err(_) => continue,
                    };
                    let path = entry.path();
                    if path.extension().and_then(|s| s.to_str()) != Some("md") {
                        continue;
                    }
                    let filename = path
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or("")
                        .to_string();
                    let body = std::fs::read_to_string(&path).unwrap_or_default();
                    let kind = sniff_kind(&filename, &body);
                    let title = extract_title(&body);
                    let mtime_unix = entry
                        .metadata()
                        .ok()
                        .and_then(|m| m.modified().ok())
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    let slug = filename.trim_end_matches(".md").to_string();
                    plans.push(PlanSummary {
                        slug,
                        title,
                        kind,
                        mtime_unix,
                        path: path.to_string_lossy().to_string(),
                    });
                }
            }
            plans.sort_by(|a, b| b.mtime_unix.cmp(&a.mtime_unix));
            Ok(PlansPayload { plans, error: None })
        })
        .await;

    match payload {
        Ok(mut p) => {
            if let Some(want) = query.kind.as_deref() {
                let want = match want.to_lowercase().as_str() {
                    "ceo" => Some(PlanKind::Ceo),
                    "eng" => Some(PlanKind::Eng),
                    "unknown" => Some(PlanKind::Unknown),
                    _ => None,
                };
                if let Some(want) = want {
                    p.plans.retain(|x| x.kind == want);
                }
            }
            Json(p).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("error: {e}")).into_response(),
    }
}

pub async fn detail_handler(
    State(state): State<AppState>,
    Path(slug): Path<String>,
) -> impl IntoResponse {
    let candidates: Vec<std::path::PathBuf> = vec![
        paths::claude_plans_dir().map(|d| d.join(format!("{slug}.md"))),
        Some(state.repo.join(".claude").join("plans").join(format!("{slug}.md"))),
    ]
    .into_iter()
    .flatten()
    .collect();
    for path in candidates {
        if let Ok(body) = std::fs::read_to_string(&path) {
            let filename = format!("{slug}.md");
            let kind = sniff_kind(&filename, &body);
            let title = extract_title(&body);
            return Json(PlanDetail {
                slug,
                title,
                kind,
                raw_markdown: body,
                raw_path: path.to_string_lossy().to_string(),
            })
            .into_response();
        }
    }
    (StatusCode::NOT_FOUND, "plan not found").into_response()
}
