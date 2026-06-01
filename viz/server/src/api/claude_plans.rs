use crate::api::plans::PlanSummary;
use crate::sniff::{extract_title, sniff_kind};
use crate::{paths, AppState};
use axum::extract::State;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize)]
pub struct ClaudePlanSection {
    pub label: String,
    pub dir: String,
    pub exists: bool,
    pub plans: Vec<PlanSummary>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ClaudePlansPayload {
    pub dir: String,             // legacy field — points at ~/.claude/plans
    pub plans: Vec<PlanSummary>, // legacy field — flat list across both dirs
    pub sections: Vec<ClaudePlanSection>,
    pub error: Option<String>,
}

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let global = paths::claude_plans_dir();
    let project: Option<PathBuf> = Some(state.repo.join(".claude").join("plans"));

    let mut sections = Vec::new();
    let mut all_plans = Vec::new();

    for (label, dir) in [
        ("Global · ~/.claude/plans", global.clone()),
        ("Project · .claude/plans", project),
    ] {
        match dir {
            Some(d) => {
                let exists = d.exists();
                let plans = if exists { read_plans(&d) } else { Vec::new() };
                all_plans.extend(plans.iter().cloned());
                sections.push(ClaudePlanSection {
                    label: label.to_string(),
                    dir: d.to_string_lossy().to_string(),
                    exists,
                    plans,
                });
            }
            None => {
                sections.push(ClaudePlanSection {
                    label: label.to_string(),
                    dir: String::new(),
                    exists: false,
                    plans: Vec::new(),
                });
            }
        }
    }

    all_plans.sort_by(|a, b| b.mtime_unix.cmp(&a.mtime_unix));

    let global_dir = global
        .as_ref()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();

    Json(ClaudePlansPayload {
        dir: global_dir,
        plans: all_plans,
        sections,
        error: None,
    })
    .into_response()
}

fn read_plans(dir: &std::path::Path) -> Vec<PlanSummary> {
    let mut plans = Vec::new();
    let read = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return plans,
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
    plans.sort_by(|a, b| b.mtime_unix.cmp(&a.mtime_unix));
    plans
}
