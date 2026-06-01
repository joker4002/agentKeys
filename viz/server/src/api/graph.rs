use crate::AppState;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use cargo_metadata::MetadataCommand;
use serde::Serialize;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, Serialize)]
pub struct Node {
    pub id: String,
    pub layer: usize,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Edge {
    pub from: String,
    pub to: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct GraphPayload {
    pub nodes: Vec<Node>,
    pub edges: Vec<Edge>,
}

pub async fn handler(State(state): State<AppState>) -> impl IntoResponse {
    let repo = state.repo.clone();
    let cache = state.graph_cache.clone();
    let result = cache
        .get_or_refresh(|| async move {
            let metadata = MetadataCommand::new()
                .manifest_path(repo.join("Cargo.toml"))
                .no_deps()
                .exec()
                .map_err(|e| anyhow::anyhow!("cargo metadata failed: {e}"))?;
            let workspace_ids: HashSet<_> = metadata.workspace_members.iter().cloned().collect();

            let workspace_packages: Vec<_> = metadata
                .packages
                .iter()
                .filter(|p| workspace_ids.contains(&p.id))
                .collect();
            let workspace_names: HashSet<String> =
                workspace_packages.iter().map(|p| p.name.clone()).collect();

            let mut adjacency: HashMap<String, Vec<String>> = HashMap::new();
            for pkg in &workspace_packages {
                let outgoing: Vec<String> = pkg
                    .dependencies
                    .iter()
                    .filter(|d| workspace_names.contains(&d.name))
                    .map(|d| d.name.clone())
                    .collect();
                adjacency.insert(pkg.name.clone(), outgoing);
            }

            let layers = compute_layers(&adjacency, &workspace_names);

            let mut nodes: Vec<Node> = workspace_packages
                .iter()
                .map(|pkg| Node {
                    id: pkg.name.clone(),
                    layer: *layers.get(&pkg.name).unwrap_or(&0),
                    kind: "workspace".to_string(),
                })
                .collect();
            nodes.sort_by(|a, b| a.layer.cmp(&b.layer).then(a.id.cmp(&b.id)));

            let mut edges: Vec<Edge> = adjacency
                .iter()
                .flat_map(|(from, outs)| {
                    outs.iter().map(move |to| Edge {
                        from: from.clone(),
                        to: to.clone(),
                    })
                })
                .collect();
            edges.sort_by(|a, b| a.from.cmp(&b.from).then(a.to.cmp(&b.to)));

            Ok::<_, anyhow::Error>(GraphPayload { nodes, edges })
        })
        .await;

    match result {
        Ok(payload) => Json(payload).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, format!("error: {e}")).into_response(),
    }
}

fn compute_layers(
    adjacency: &HashMap<String, Vec<String>>,
    nodes: &HashSet<String>,
) -> HashMap<String, usize> {
    let mut memo: HashMap<String, usize> = HashMap::new();
    fn depth(
        name: &str,
        adjacency: &HashMap<String, Vec<String>>,
        memo: &mut HashMap<String, usize>,
        seen: &mut HashSet<String>,
    ) -> usize {
        if let Some(&d) = memo.get(name) {
            return d;
        }
        if !seen.insert(name.to_string()) {
            return 0;
        }
        let outs = adjacency.get(name).cloned().unwrap_or_default();
        let d = if outs.is_empty() {
            0
        } else {
            outs.iter()
                .map(|dep| depth(dep, adjacency, memo, seen) + 1)
                .max()
                .unwrap_or(0)
        };
        seen.remove(name);
        memo.insert(name.to_string(), d);
        d
    }
    let mut seen = HashSet::new();
    for name in nodes {
        depth(name, adjacency, &mut memo, &mut seen);
    }
    memo
}
