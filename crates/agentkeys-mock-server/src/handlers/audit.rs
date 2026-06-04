use axum::{
    extract::{Query, State},
    http::HeaderMap,
    Json,
};
use rusqlite::params;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::{
    auth::{extract_bearer_token, is_owner_of, validate_session},
    error::{AppError, AppResult},
    state::SharedState,
};

pub async fn shielding_key(State(state): State<SharedState>) -> AppResult<Json<Value>> {
    let pub_key_bytes = state.shielding_public_key.to_bytes().to_vec();
    let encoded =
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &pub_key_bytes);
    Ok(Json(json!({ "public_key": encoded })))
}

#[derive(Deserialize)]
pub struct AuditEventsQuery {
    pub agent_id: String,
}

pub async fn audit_events(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Query(query): Query<AuditEventsQuery>,
) -> AppResult<Json<Value>> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(extract_bearer_token)
        .ok_or_else(|| AppError::unauthorized("missing Authorization header"))?;

    let session = validate_session(&state, token)?;
    let db = state.db.lock().unwrap();
    if !is_owner_of(&db, &session.wallet_address, &query.agent_id) {
        return Err(AppError::forbidden(
            "session does not own the target wallet",
        ));
    }

    let mut stmt = db
        .prepare(
            "SELECT action, session_id, agent_id, service, timestamp, attempted_rate
             FROM audit_events
             WHERE agent_id = ?1
             ORDER BY id ASC",
        )
        .map_err(|e| AppError::internal(e.to_string()))?;

    let rows = stmt
        .query_map(params![query.agent_id], |row| {
            Ok(json!({
                "action": row.get::<_, String>(0)?,
                "session_id": row.get::<_, String>(1)?,
                "agent_id": row.get::<_, String>(2)?,
                "service": row.get::<_, String>(3)?,
                "timestamp": row.get::<_, u64>(4)?,
                "attempted_rate": row.get::<_, Option<u32>>(5)?,
            }))
        })
        .map_err(|e| AppError::internal(e.to_string()))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| AppError::internal(e.to_string()))?;

    Ok(Json(json!({ "events": rows })))
}
