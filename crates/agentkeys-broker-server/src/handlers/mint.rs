use std::time::{SystemTime, UNIX_EPOCH};

use axum::{extract::State, http::HeaderMap, Json};
use serde::Serialize;

use crate::audit::{MintOutcome, MintRecord};
use crate::auth::{extract_bearer_token, validate_bearer_token};
use crate::error::{BrokerError, BrokerResult};
use crate::state::SharedState;

#[derive(Serialize)]
pub struct MintResponse {
    pub access_key_id: String,
    pub secret_access_key: String,
    pub session_token: String,
    pub expiration: i64,
    pub wallet: String,
}

pub async fn mint_aws_creds(
    State(state): State<SharedState>,
    headers: HeaderMap,
) -> BrokerResult<Json<MintResponse>> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(extract_bearer_token)
        .ok_or_else(|| BrokerError::Unauthorized("missing Authorization header".into()))?;

    let session = match validate_bearer_token(&state.http, &state.config.backend_url, token).await {
        Ok(s) => s,
        Err(e @ BrokerError::Unauthorized(_)) => {
            let _ = state.audit.record_mint(
                MintRecord {
                    requester_token: token,
                    requester_wallet: "unknown",
                    requested_role: &state.config.agent_role_arn,
                    session_duration_seconds: state.config.session_duration_seconds,
                    sts_session_name: "(unauthenticated)",
                    outcome: MintOutcome::AuthFailed,
                },
                Some(&e.to_string()),
            );
            return Err(e);
        }
        Err(e) => return Err(e),
    };

    let session_name = build_session_name(&session.wallet);

    let result = state
        .sts
        .assume_role(
            &state.config.agent_role_arn,
            &session_name,
            state.config.session_duration_seconds,
        )
        .await;

    match result {
        Ok(creds) => {
            state.audit.record_mint(
                MintRecord {
                    requester_token: token,
                    requester_wallet: &session.wallet,
                    requested_role: &state.config.agent_role_arn,
                    session_duration_seconds: state.config.session_duration_seconds,
                    sts_session_name: &session_name,
                    outcome: MintOutcome::Ok,
                },
                None,
            )?;
            Ok(Json(MintResponse {
                access_key_id: creds.access_key_id,
                secret_access_key: creds.secret_access_key,
                session_token: creds.session_token,
                expiration: creds.expiration_unix,
                wallet: session.wallet,
            }))
        }
        Err(e) => {
            let _ = state.audit.record_mint(
                MintRecord {
                    requester_token: token,
                    requester_wallet: &session.wallet,
                    requested_role: &state.config.agent_role_arn,
                    session_duration_seconds: state.config.session_duration_seconds,
                    sts_session_name: &session_name,
                    outcome: MintOutcome::StsError,
                },
                Some(&e.to_string()),
            );
            Err(e)
        }
    }
}

fn build_session_name(wallet: &str) -> String {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let safe_wallet: String = wallet
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(*c, '-' | '_'))
        .take(50)
        .collect();
    let mut name = format!("agentkeys-{}-{}", safe_wallet, suffix);
    if name.len() > 64 {
        name.truncate(64);
    }
    name
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_name_under_64_chars() {
        let n = build_session_name("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
        assert!(n.len() <= 64, "session name {} exceeds 64 chars", n);
        assert!(n.starts_with("agentkeys-"));
    }

    #[test]
    fn session_name_strips_unsafe_chars() {
        let n = build_session_name("0xABC/123 weird");
        assert!(!n.contains('/'));
        assert!(!n.contains(' '));
    }

    #[test]
    fn session_name_handles_empty_wallet() {
        let n = build_session_name("");
        assert!(n.starts_with("agentkeys--"));
    }
}
