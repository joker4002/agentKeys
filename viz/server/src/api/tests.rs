use crate::AppState;
use axum::extract::State;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use walkdir::WalkDir;

#[derive(Debug, Clone, Serialize)]
pub struct CrateTests {
    pub crate_name: String,
    pub test_files: Vec<TestFile>,
    pub last_run_status: Option<String>,
    pub last_run_passed: Option<u32>,
    pub last_run_failed: Option<u32>,
    pub coverage_pct: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TestFile {
    pub name: String,
    pub path: String,
    pub line_count: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct TestsPayload {
    pub crates: Vec<CrateTests>,
    pub cache_dir: String,
    pub error: Option<String>,
}

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let cache_dir = state.repo.join("target/viz-cache/test-output");
    let crates_dir = state.repo.join("crates");
    let mut crates_out = Vec::new();
    if !crates_dir.exists() {
        return Json(TestsPayload {
            crates: vec![],
            cache_dir: cache_dir.to_string_lossy().to_string(),
            error: Some("crates/ not found".into()),
        })
        .into_response();
    }
    for entry in std::fs::read_dir(&crates_dir).unwrap() {
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        if !entry.path().is_dir() {
            continue;
        }
        let crate_name = match entry.file_name().to_str() {
            Some(s) => s.to_string(),
            None => continue,
        };
        let tests_dir = entry.path().join("tests");
        let mut test_files = Vec::new();
        if tests_dir.exists() {
            for f in WalkDir::new(&tests_dir).max_depth(2).into_iter().filter_map(|e| e.ok()) {
                let path = f.path();
                if path.extension().and_then(|s| s.to_str()) != Some("rs") {
                    continue;
                }
                let body = std::fs::read_to_string(path).unwrap_or_default();
                let name = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("?")
                    .to_string();
                test_files.push(TestFile {
                    name,
                    path: path.to_string_lossy().to_string(),
                    line_count: body.lines().count(),
                });
            }
            test_files.sort_by(|a, b| a.name.cmp(&b.name));
        }
        let last_run_path = cache_dir.join(format!("{crate_name}.json"));
        let last_run = std::fs::read_to_string(&last_run_path)
            .ok()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());
        let (last_run_status, last_run_passed, last_run_failed, coverage_pct) = match last_run {
            Some(v) => (
                v.get("status").and_then(|x| x.as_str()).map(String::from),
                v.get("passed").and_then(|x| x.as_u64()).map(|x| x as u32),
                v.get("failed").and_then(|x| x.as_u64()).map(|x| x as u32),
                v.get("coverage_pct").and_then(|x| x.as_f64()),
            ),
            None => (None, None, None, None),
        };
        crates_out.push(CrateTests {
            crate_name,
            test_files,
            last_run_status,
            last_run_passed,
            last_run_failed,
            coverage_pct,
        });
    }
    crates_out.sort_by(|a, b| a.crate_name.cmp(&b.crate_name));
    Json(TestsPayload {
        crates: crates_out,
        cache_dir: cache_dir.to_string_lossy().to_string(),
        error: None,
    })
    .into_response()
}
