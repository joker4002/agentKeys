use std::path::{Path, PathBuf};

pub fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

pub fn claude_plans_dir() -> Option<PathBuf> {
    home_dir().map(|h| h.join(".claude").join("plans"))
}

pub fn omc_dir(repo: &Path) -> Option<PathBuf> {
    let candidate = repo.join(".omc");
    if candidate.exists() {
        return Some(candidate);
    }
    let mut cur = repo;
    while let Some(parent) = cur.parent() {
        let candidate = parent.join(".omc");
        if candidate.exists() {
            return Some(candidate);
        }
        cur = parent;
    }
    None
}

pub fn progress_txt(repo: &Path) -> Option<PathBuf> {
    let candidate = repo.join("progress.txt");
    candidate.exists().then_some(candidate)
}

pub fn plans_kind_index() -> Option<PathBuf> {
    claude_plans_dir().map(|p| p.join(".kind-index.json"))
}

pub fn viz_cache(repo: &Path) -> PathBuf {
    repo.join("target").join("viz-cache")
}
