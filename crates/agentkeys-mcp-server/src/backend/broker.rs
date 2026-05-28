//! Broker-side request shapes — typed wrappers around the JSON
//! [`agentkeys_broker_server::handlers::cap`] expects. We don't pull the
//! broker crate as a dep (it's a binary with a heavy feature surface) —
//! the wire shape is small enough to mirror by hand and gets exercised
//! end-to-end in `tests/three_acts.rs`.

use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct BrokerCapRequest {
    pub operator_omni: String,
    pub actor_omni: String,
    pub service: String,
    pub device_key_hash: String,
    pub ttl_seconds: u64,
    /// Memory namespaces to grant (issue #108). The broker validates each
    /// against the v0 set and signs them into the cap; ignored for cred
    /// caps. Skipped on the wire when empty so cred cap-mint bodies are
    /// byte-identical to pre-#108.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub namespaces_allowed: Vec<String>,
}
