//! Memory-worker request shapes.
//!
//! Mirrors `agentkeys_worker_memory::handlers::{PutRequest, GetRequest}`.
//! The wire envelope carries the requested `namespace`; the cap's
//! `namespaces_allowed` claim (signed by the broker) is what the worker
//! filters against (issue #108). A request for a namespace outside the
//! claim comes back with `namespace_violation: true` and no data.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Serialize)]
pub struct MemoryPutBody {
    pub cap: Value,
    pub plaintext_b64: String,
    pub namespace: String,
}

#[derive(Debug, Serialize)]
pub struct MemoryGetBody {
    pub cap: Value,
    pub namespace: String,
}

#[derive(Debug, Deserialize)]
pub struct MemoryPutResp {
    pub ok: bool,
    pub s3_key: String,
    pub envelope_size: usize,
    #[serde(default)]
    pub namespace_violation: bool,
}

#[derive(Debug, Deserialize)]
pub struct MemoryGetResp {
    pub ok: bool,
    pub plaintext_b64: String,
    #[serde(default)]
    pub namespace_violation: bool,
}
