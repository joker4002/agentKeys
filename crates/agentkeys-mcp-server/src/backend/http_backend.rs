//! HTTP `MemoryBackend` impl — talks to the `agentkeys-worker-memory`
//! gated store over HTTP (issue #161).
//!
//! The worker is the gate+store (cap-verify → namespace filter → K3
//! envelope → S3). This client carries the session cap-token in the
//! `Authorization: Bearer` header; the worker enforces `namespaces_allowed`
//! independently (defense in depth — the MCP tool layer also checks it
//! before this is reached, per `tools::memory`).
//!
//! Wire contract (issue #161):
//! ```text
//!   POST {base}/v1/memory/put   { actor_omni, namespace, text }
//!        → 200 MemoryLine { id, namespace, text, ts }
//!   POST {base}/v1/memory/get   { actor_omni, namespace, query?, limit }
//!        → 200 { lines: [MemoryLine] }
//!   non-2xx → MemoryError::Backend("<status>: <body>")
//! ```
//! The worker side of this contract (namespaced per-line endpoints) is the
//! next #161 increment; this client is the gate-facing half.

use async_trait::async_trait;
use serde::Deserialize;

use crate::backend::{MemoryBackend, MemoryLine};
use crate::tools::memory::MemoryError;

pub struct HttpMemoryBackend {
    pub base_url: String,
    pub cap_token: String,
    http: reqwest::Client,
}

impl HttpMemoryBackend {
    pub fn new(base_url: String, cap_token: String) -> Self {
        Self { base_url, cap_token, http: reqwest::Client::new() }
    }

    fn url(&self, path: &str) -> String {
        format!(
            "{}/{}",
            self.base_url.trim_end_matches('/'),
            path.trim_start_matches('/')
        )
    }
}

/// Worker response shape for `/v1/memory/get`.
#[derive(Deserialize)]
struct GetBody {
    lines: Vec<MemoryLine>,
}

#[async_trait]
impl MemoryBackend for HttpMemoryBackend {
    async fn put(
        &self,
        actor_omni: &str,
        namespace: &str,
        text: &str,
    ) -> Result<MemoryLine, MemoryError> {
        let resp = self
            .http
            .post(self.url("/v1/memory/put"))
            .bearer_auth(&self.cap_token)
            .json(&serde_json::json!({
                "actor_omni": actor_omni,
                "namespace": namespace,
                "text": text,
            }))
            .send()
            .await
            .map_err(|e| MemoryError::Backend(format!("put request: {e}")))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(MemoryError::Backend(format!("put {status}: {body}")));
        }
        resp.json::<MemoryLine>()
            .await
            .map_err(|e| MemoryError::Backend(format!("put decode: {e}")))
    }

    async fn get(
        &self,
        actor_omni: &str,
        namespace: &str,
        query: Option<&str>,
        limit: usize,
    ) -> Result<Vec<MemoryLine>, MemoryError> {
        let resp = self
            .http
            .post(self.url("/v1/memory/get"))
            .bearer_auth(&self.cap_token)
            .json(&serde_json::json!({
                "actor_omni": actor_omni,
                "namespace": namespace,
                "query": query,
                "limit": limit,
            }))
            .send()
            .await
            .map_err(|e| MemoryError::Backend(format!("get request: {e}")))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(MemoryError::Backend(format!("get {status}: {body}")));
        }
        let parsed = resp
            .json::<GetBody>()
            .await
            .map_err(|e| MemoryError::Backend(format!("get decode: {e}")))?;
        Ok(parsed.lines)
    }
}
