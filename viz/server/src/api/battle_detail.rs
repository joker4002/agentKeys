use axum::extract::Path;
use axum::response::{IntoResponse, Json};
use serde::Serialize;
use std::process::Stdio;
use tokio::process::Command;

#[derive(Debug, Serialize)]
pub struct BattleDetail {
    pub pid: u32,
    pub ppid: Option<u32>,
    pub user: Option<String>,
    pub started: Option<String>,
    pub command: Option<String>,
    pub cwd: Option<String>,
    pub exists: bool,
    pub error: Option<String>,
}

pub async fn handler(Path(pid): Path<u32>) -> impl IntoResponse {
    // ps -p <pid> -o pid=,ppid=,user=,lstart=,command=
    let ps_out = Command::new("ps")
        .args([
            "-p",
            &pid.to_string(),
            "-o",
            "pid=,ppid=,user=,lstart=,command=",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await;

    let (mut ppid, mut user, mut started, mut command) = (None, None, None, None);
    let mut exists = false;

    if let Ok(output) = ps_out {
        if output.status.success() {
            let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !raw.is_empty() {
                exists = true;
                // ps lstart includes spaces ("Mon May  6 12:34:56 2026") so we need
                // a manual columnar parse: pid ppid user lstart(5 tokens) command...
                let mut it = raw.splitn(2, char::is_whitespace);
                let _ = it.next(); // pid (already known)
                let rest = it.next().unwrap_or("").trim_start();
                let mut parts = rest.split_whitespace();
                ppid = parts.next().and_then(|s| s.parse::<u32>().ok());
                user = parts.next().map(String::from);
                let lstart_tokens: Vec<&str> = parts.by_ref().take(5).collect();
                if lstart_tokens.len() == 5 {
                    started = Some(lstart_tokens.join(" "));
                }
                let cmd_rest: Vec<&str> = parts.collect();
                if !cmd_rest.is_empty() {
                    command = Some(cmd_rest.join(" "));
                }
            }
        }
    }

    // cwd via lsof: lsof -p <pid> -d cwd -Fn
    let cwd = match Command::new("lsof")
        .args(["-p", &pid.to_string(), "-d", "cwd", "-Fn"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .await
    {
        Ok(o) if o.status.success() => {
            let text = String::from_utf8_lossy(&o.stdout);
            text.lines()
                .find(|l| l.starts_with('n'))
                .map(|l| l.trim_start_matches('n').to_string())
        }
        _ => None,
    };

    let error = if exists {
        None
    } else {
        Some(format!("process {pid} not found"))
    };

    Json(BattleDetail {
        pid,
        ppid,
        user,
        started,
        command,
        cwd,
        exists,
        error,
    })
    .into_response()
}
