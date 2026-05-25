//! HTTP + stdio transports.
//!
//! HTTP transport:
//!   - POST /mcp        — JSON-RPC request, returns JSON-RPC response
//!   - GET  /healthz    — liveness
//!   - Auth: Bearer (vendor) + X-AgentKeys-Actor (actor binding)
//!
//! Stdio transport:
//!   - Reads newline-framed JSON-RPC requests from stdin.
//!   - Writes newline-framed responses to stdout.
//!   - No auth; parent process is implicitly trusted.

use axum::{
    extract::{Json, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use crate::auth::{check_actor_header, check_bearer, CallerContext};
use crate::mcp::Request;
use crate::server::Server;

pub fn http_router(server: Arc<Server>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/mcp", post(handle_mcp))
        .with_state(server)
}

async fn healthz() -> impl IntoResponse {
    axum::Json(serde_json::json!({"ok": true, "name": crate::mcp::MCP_SERVER_NAME}))
}

async fn handle_mcp(
    State(server): State<Arc<Server>>,
    headers: HeaderMap,
    Json(req): Json<Request>,
) -> impl IntoResponse {
    let req_id = req.id.clone();

    let auth_header = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok());
    let vendor_id = match check_bearer(&server.config, auth_header) {
        Ok(v) => v,
        Err(e) => {
            return (
                StatusCode::UNAUTHORIZED,
                axum::Json(e.into_response(req_id)),
            )
                .into_response();
        }
    };

    let actor_header = headers
        .get("x-agentkeys-actor")
        .and_then(|v| v.to_str().ok());
    let actor_omni = match check_actor_header(actor_header) {
        Ok(a) => a,
        Err(e) => {
            return (
                StatusCode::FORBIDDEN,
                axum::Json(e.into_response(req_id)),
            )
                .into_response();
        }
    };

    let caller = CallerContext::new(vendor_id, actor_omni);

    let session_bearer = headers
        .get("x-agentkeys-session-bearer")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    let resp = server.dispatch(&caller, session_bearer, req).await;
    (StatusCode::OK, axum::Json(resp)).into_response()
}

/// Read newline-framed JSON-RPC requests from `stdin`, dispatch them, and
/// write newline-framed responses to `stdout`.
pub async fn run_stdio(server: Arc<Server>) -> anyhow::Result<()> {
    let stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();
    let mut reader = BufReader::new(stdin).lines();

    let caller = CallerContext::local_stdio();

    while let Some(line) = reader.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }

        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let resp = crate::mcp::Response::error(
                    None,
                    crate::mcp::codes::PARSE_ERROR,
                    format!("parse error: {e}"),
                );
                stdout.write_all(serde_json::to_string(&resp)?.as_bytes()).await?;
                stdout.write_all(b"\n").await?;
                stdout.flush().await?;
                continue;
            }
        };

        let resp = server.dispatch(&caller, "", req).await;
        stdout.write_all(serde_json::to_string(&resp)?.as_bytes()).await?;
        stdout.write_all(b"\n").await?;
        stdout.flush().await?;
    }
    Ok(())
}
