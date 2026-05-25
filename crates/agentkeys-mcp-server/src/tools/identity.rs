//! `agentkeys.identity.whoami` — return what the calling actor is.
//!
//! M1 synthesizes the answer locally from the auth context. The broker
//! does not yet expose `/v1/identity/whoami` — that endpoint lands paired
//! with the vendor onboarding portal in M4. This deliberately matches
//! the M1 scope in `milestones-roadmap.md`: the field shape is real,
//! the source of truth shifts when the broker endpoint lands.

use serde_json::{json, Value};

use crate::auth::CallerContext;
use crate::errors::{McpError, McpResult};

pub fn call(caller: &CallerContext, params: &Value) -> McpResult<Value> {
    let actor = params
        .get("actor")
        .and_then(|v| v.as_str())
        .ok_or_else(|| McpError::InvalidParams("missing `actor`".into()))?;

    if caller.actor_omni != "*" {
        crate::auth::check_actor_param(&caller.actor_omni, actor)?;
    }

    Ok(json!({
        "omni": actor,
        "display_name": format!("actor:{actor}"),
        "vendor": caller.vendor_id,
        "scopes": [
            "memory.read",
            "memory.write",
            "payment.spend"
        ],
        "_note": "M1 synthesizes locally; broker /v1/identity/whoami lands in M4"
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn happy_path() {
        let caller = CallerContext::new("vendor-a", "O_alice");
        let v = call(&caller, &json!({"actor": "O_alice"})).unwrap();
        assert_eq!(v["omni"], "O_alice");
        assert_eq!(v["vendor"], "vendor-a");
        assert!(v["scopes"].is_array());
    }

    #[test]
    fn missing_actor_is_invalid_params() {
        let caller = CallerContext::new("vendor-a", "O_alice");
        let err = call(&caller, &json!({})).unwrap_err();
        assert!(matches!(err, McpError::InvalidParams(_)));
    }

    #[test]
    fn actor_mismatch_is_forbidden() {
        let caller = CallerContext::new("vendor-a", "O_alice");
        let err = call(&caller, &json!({"actor": "O_bob"})).unwrap_err();
        assert!(matches!(err, McpError::Forbidden(_)));
    }
}
