//! TEE-side child derivation path policy.
//!
//! Pairing creates an explicit active row for the approved HDKD path. Paths with
//! no row are denied by default; suspend/resume flips the active bit without
//! pretending the underlying child key derivation can be destroyed.

use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::json;

use crate::error::BrokerError;
use crate::state::SharedState;

#[derive(Debug, Deserialize)]
pub struct PathPolicyBody {
    pub derivation_path: String,
}

pub async fn path_policy_list(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, BrokerError> {
    let session = super::require_session_jwt(&headers, &state)?;
    let master = session.agentkeys.omni_account;
    let policies = state
        .grant_store
        .list_child_path_policies(&master)
        .map_err(|e| BrokerError::Internal(format!("list child path policies: {}", e)))?;

    Ok((
        StatusCode::OK,
        Json(json!({
            "owner": master,
            "default": "deny",
            "policies": policies,
        })),
    ))
}

pub async fn path_policy_suspend(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<PathPolicyBody>,
) -> Result<impl IntoResponse, BrokerError> {
    set_active(state, headers, body, false).await
}

pub async fn path_policy_resume(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(body): Json<PathPolicyBody>,
) -> Result<impl IntoResponse, BrokerError> {
    set_active(state, headers, body, true).await
}

async fn set_active(
    state: SharedState,
    headers: HeaderMap,
    body: PathPolicyBody,
    active: bool,
) -> Result<impl IntoResponse, BrokerError> {
    let session = super::require_session_jwt(&headers, &state)?;
    let master = session.agentkeys.omni_account;
    let derivation_path = body.derivation_path.trim();
    if derivation_path.is_empty() {
        return Err(BrokerError::BadRequest("derivation_path required".into()));
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);

    let changed = state
        .grant_store
        .set_child_path_active(&master, derivation_path, active, now)
        .map_err(|e| BrokerError::Internal(format!("set child path policy: {}", e)))?;
    if !changed {
        return Err(BrokerError::BadRequest(format!(
            "derivation_path {:?} has no policy for this master",
            derivation_path
        )));
    }

    Ok((
        StatusCode::OK,
        Json(json!({
            "derivation_path": derivation_path,
            "active": active,
            "updated_at": now,
        })),
    ))
}
