use crate::api::worktrees::resolve_repo;
use crate::AppState;
use axum::extract::{Query, State};
use axum::response::{IntoResponse, Json};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::path::Path;

#[derive(Debug, Deserialize)]
pub struct DocsQuery {
    pub repo: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DocsNode {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<DocsNode>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line_count: Option<usize>,
    /// True for a pinned single-source-of-truth doc (`docs/arch.md` =
    /// technical, `docs/agent-iam-strategy.md` = product). Frontend pins these
    /// to the top of the panel regardless of alphabetical order, in the
    /// `SOURCES_OF_TRUTH` order below.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    #[serde(default)]
    pub is_index: bool,
    /// Caption shown under a pinned SSOT doc ("technical …" / "product …").
    /// Set only when `is_index` is true.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index_caption: Option<String>,
    /// For top-level docs/ subfolders that have a designated audience per
    /// arch.md's "Docs layout (lean)" section. None for other directories
    /// and for all leaf files.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audience: Option<String>,
    /// Number of direct entries inside a directory that is NOT recursed into
    /// (currently only `archived/`, which is deliberately left collapsed).
    /// Lets the frontend show an accurate tab count without expanding it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry_count: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DocsPayload {
    pub root: String,
    pub tree: Vec<DocsNode>,
    /// Path to `docs/arch.md` if present — the primary (technical) source of
    /// truth. Frontend offers a one-click "open arch.md" from the docs panel.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index_path: Option<String>,
    pub error: Option<String>,
}

const SKIP_DIRS: &[&str] = &["node_modules", "target", ".git"];

/// Top-level docs pinned as single-source-of-truth, in display order.
/// `(filename, caption)`. arch.md is the technical SSOT; agent-iam-strategy.md
/// is the product/strategy SSOT. Both are pinned above everything else.
const SOURCES_OF_TRUTH: &[(&str, &str)] = &[
    (
        "arch.md",
        "technical single source of truth · architecture v2, indexes every detail via outward links",
    ),
    (
        "agent-iam-strategy.md",
        "product single source of truth · strategic anchor for what AgentKeys is, isn't, and ships next",
    ),
];

/// Display rank of a pinned SSOT doc (lower = higher on the page), or None.
fn source_of_truth_rank(name: &str) -> Option<usize> {
    SOURCES_OF_TRUTH.iter().position(|(n, _)| *n == name)
}

fn source_of_truth_caption(name: &str) -> Option<&'static str> {
    SOURCES_OF_TRUTH
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, c)| *c)
}

/// Top-level `docs/` subfolders that are deliberately NOT expanded in the
/// panel. `archived/` is superseded content — we surface it as a single
/// collapsed tab with a count, never a long file list.
const COLLAPSED_DIRS: &[&str] = &["archived"];

/// Top-level `docs/` subfolders → audience caption shown in the panel.
/// Mirrors the "Docs layout (lean)" section in arch.md / project CLAUDE.md.
/// Any folder name not in this table renders without an audience caption.
fn audience_for(name: &str) -> Option<&'static str> {
    match name {
        "spec" => Some("developers + coordinating colleagues"),
        "plan" => Some("agent-authored plans BEFORE code lands"),
        "research" => Some("third-party context (Heima, EIP-191/712, aiosandbox)"),
        "wiki" => Some("end users + hardware integrators (mirrored to GitHub Wiki)"),
        "archived" => Some("superseded — never linked from arch.md, never read in normal dev"),
        _ => None,
    }
}

pub async fn handler(
    State(state): State<AppState>,
    Query(q): Query<DocsQuery>,
) -> impl IntoResponse {
    let repo = resolve_repo(&state, q.repo.as_deref()).await;
    let docs_dir = repo.join("docs");
    if !docs_dir.exists() {
        return Json(DocsPayload {
            root: docs_dir.to_string_lossy().to_string(),
            tree: vec![],
            index_path: None,
            error: Some(format!("docs/ not found at {}", docs_dir.display())),
        })
        .into_response();
    }
    let arch_path = docs_dir.join("arch.md");
    let index_path = if arch_path.is_file() {
        Some(arch_path.to_string_lossy().to_string())
    } else {
        None
    };
    let mut tree = walk(&docs_dir, 4, /* top_level = */ true);
    // Pin SSOT docs to the top (in SOURCES_OF_TRUTH order), then directories
    // (alphabetical), then remaining files (alphabetical).
    tree.sort_by(|a, b| {
        let ar = a.is_index.then(|| source_of_truth_rank(&a.name)).flatten();
        let br = b.is_index.then(|| source_of_truth_rank(&b.name)).flatten();
        match (ar, br) {
            (Some(x), Some(y)) => x.cmp(&y),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            (None, None) => b
                .is_dir
                .cmp(&a.is_dir)
                .then_with(|| a.name.cmp(&b.name)),
        }
    });
    Json(DocsPayload {
        root: docs_dir.to_string_lossy().to_string(),
        tree,
        index_path,
        error: None,
    })
    .into_response()
}

/// Count direct entries inside `dir` that `walk` would surface (visible dirs +
/// `.md`/`.mdx`/`.txt` files). Used for collapsed dirs we do not recurse into.
fn count_direct_entries(dir: &Path) -> usize {
    let read = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return 0,
    };
    read.filter_map(|e| e.ok())
        .filter(|entry| {
            let path = entry.path();
            let name = match path.file_name().and_then(|s| s.to_str()) {
                Some(s) => s.to_string(),
                None => return false,
            };
            if name.starts_with('.') {
                return false;
            }
            if path.is_dir() {
                !SKIP_DIRS.contains(&name.as_str())
            } else {
                let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
                matches!(ext, "md" | "mdx" | "txt")
            }
        })
        .count()
}

fn walk(dir: &Path, depth: usize, top_level: bool) -> Vec<DocsNode> {
    let mut entries: Vec<DocsNode> = Vec::new();
    let read = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return entries,
    };
    let mut items: Vec<_> = read.filter_map(|e| e.ok()).collect();
    items.sort_by_key(|e| e.file_name());
    for entry in items {
        let path = entry.path();
        let name = match path.file_name().and_then(|s| s.to_str()) {
            Some(s) => s.to_string(),
            None => continue,
        };
        if name.starts_with('.') {
            continue;
        }
        let is_dir = path.is_dir();
        if is_dir && SKIP_DIRS.contains(&name.as_str()) {
            continue;
        }
        if !is_dir {
            let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("");
            if !matches!(ext, "md" | "mdx" | "txt") {
                continue;
            }
        }
        let line_count = if !is_dir {
            std::fs::read_to_string(&path).ok().map(|s| s.lines().count())
        } else {
            None
        };
        // Leave collapsed top-level dirs (e.g. archived/) un-expanded: report a
        // count instead of a long child list so the panel stays minimal.
        let collapsed = is_dir && top_level && COLLAPSED_DIRS.contains(&name.as_str());
        let children = if is_dir && depth > 0 && !collapsed {
            Some(walk(&path, depth - 1, /* top_level = */ false))
        } else {
            None
        };
        let entry_count = if collapsed {
            Some(count_direct_entries(&path))
        } else {
            None
        };
        let is_index = top_level && !is_dir && source_of_truth_rank(&name).is_some();
        let index_caption = if is_index {
            source_of_truth_caption(&name).map(|s| s.to_string())
        } else {
            None
        };
        let audience = if top_level && is_dir {
            audience_for(name.as_str()).map(|s| s.to_string())
        } else {
            None
        };
        entries.push(DocsNode {
            name,
            path: path.to_string_lossy().to_string(),
            is_dir,
            children,
            line_count,
            is_index,
            index_caption,
            audience,
            entry_count,
        });
    }
    entries
}
