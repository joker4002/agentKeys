//! OpenViking engine adapter — plan `docs/plan/agentkeys-memory-design.md` §6a.
//!
//! OpenViking (`volcengine/OpenViking`) is a self-hosted context database. In
//! AgentKeys' Model-B integration it is the pluggable RANKING engine *behind*
//! our gate: AgentKeys still STORES (K3-encrypted S3) + GATES (cap / scope /
//! namespace / audit) + DELIVERS (the `pre_llm_call` hook). OpenViking only
//! reorders. The HTTP contract below is taken verbatim from the Hermes
//! `plugins/memory/openviking` client — not guessed:
//!
//!   base    http://127.0.0.1:1933  (OPENVIKING_ENDPOINT)
//!   headers X-OpenViking-Agent / -Account / -User, plus X-API-Key +
//!           `Authorization: Bearer <key>` when OPENVIKING_API_KEY is set
//!   GET  /health                       -> 200 when up
//!   POST /api/v1/search/find {query, top_k}
//!        -> {result:{memories|resources|skills|results:
//!              [{score, uri, content|text|abstract}]}}
//!           The live server groups hits by kind (`memories` for our use);
//!           Skip-VLM mode leaves `abstract` blank, so a hit carries only
//!           score + uri and the body must be read back by uri.
//!   POST /api/v1/content/read  {uri}   -> the stored line for a uri; used to
//!        resolve URI-only / blank-abstract hits before gate text-matching.
//!   POST /api/v1/content/write {uri, content, mode:"create"}
//!   error envelope: HTTP >= 400, or {status:"error", error:{code,message}}
//!
//! SAFETY — the gate bounds visibility: [`rank_gate_bounded`] only ever returns
//! lines that were in the gate-authorized input set. OpenViking can change the
//! ORDER but can never WIDEN what is injectable; a compromised/over-broad
//! OpenViking cannot leak content the gate did not authorize. On any error or
//! empty result it returns `None`, so the caller falls back to a deterministic
//! engine (recency) — OpenViking is never load-bearing for availability.

use serde::Deserialize;

use agentkeys_memory_engine::{MemoryLine, SelectionBudget};

pub const DEFAULT_ENDPOINT: &str = "http://127.0.0.1:1933";

/// Per-request timeout (env `OPENVIKING_TIMEOUT_MS`). Secondary bound on a single
/// find/read/write/health call; the caller's overall ranking deadline caps their
/// sum so a stalled server can never hang the hook (OpenViking is never
/// load-bearing — arch.md §22).
const DEFAULT_TIMEOUT_MS: u64 = 2000;
/// Cap on per-turn `content/read` fan-out (env `OPENVIKING_MAX_URI_READS`).
/// A SAFETY bound alongside the overall deadline + early-stop: reads happen in rank
/// order and stop once the output budget is filled, so this only bounds the
/// pathological scan (many out-of-gate URI hits). Kept generous so authorized lines
/// ranked past the first few URI hits are still reached (/codex:adversarial-review).
const DEFAULT_MAX_URI_READS: usize = 64;
/// Max bytes buffered from ANY OpenViking response (env `OPENVIKING_MAX_RESPONSE_BYTES`).
/// A larger body is treated as an error so a buggy/compromised/oversized server
/// can't OOM or stall the hook before the timeout + read cap help — the caller
/// falls back instead (/codex:adversarial-review).
const DEFAULT_MAX_RESPONSE_BYTES: usize = 1_048_576;

fn http_client(timeout_ms: u64) -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_millis(timeout_ms))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(default)
}

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(default)
}

/// OpenViking `search/find` window sizing — DECOUPLED from the output budget.
/// OpenViking's index can hold records OUTSIDE the gate-authorized set (other
/// namespaces, the sample corpus, resources); sizing the fetch from
/// `SelectionBudget` lets those crowd out authorized lines ranked just below the
/// window, silently degrading to lexical. So overfetch a generous (bounded)
/// window, gate-match, THEN budget the matched output (/codex:adversarial-review).
const OVERFETCH_FACTOR: usize = 8;
const MIN_FETCH_TOP_K: usize = 32;
const MAX_FETCH_TOP_K: usize = 256;

fn openviking_fetch_top_k(authorized_lines: usize) -> usize {
    authorized_lines
        .saturating_mul(OVERFETCH_FACTOR)
        .clamp(MIN_FETCH_TOP_K, MAX_FETCH_TOP_K)
}

#[derive(Debug, Clone)]
pub struct OpenVikingClient {
    endpoint: String,
    api_key: String,
    account: String,
    user: String,
    agent: String,
    http: reqwest::Client,
    /// Max bytes buffered from any response — see [`DEFAULT_MAX_RESPONSE_BYTES`].
    max_response_bytes: usize,
}

#[derive(Debug, thiserror::Error)]
pub enum OpenVikingError {
    #[error("openviking transport: {0}")]
    Transport(String),
    #[error("openviking http {status}: {body}")]
    Http { status: u16, body: String },
    #[error("openviking parse: {0}")]
    Parse(String),
}

#[derive(Debug, Deserialize)]
struct FindEnvelope {
    #[serde(default)]
    result: Option<FindResult>,
    #[serde(default)]
    status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FindResult {
    // The real server groups hits by kind (`memories` for our use); the
    // Hermes-doc'd shape uses `results`. Accept ALL documented arrays so a
    // live OpenViking is never silently treated as empty/no-match.
    #[serde(default)]
    results: Vec<FindHit>,
    #[serde(default)]
    memories: Vec<FindHit>,
    #[serde(default)]
    resources: Vec<FindHit>,
    #[serde(default)]
    skills: Vec<FindHit>,
}

impl FindResult {
    /// Every hit across all documented arrays, in a stable kind order.
    fn all_hits(self) -> Vec<FindHit> {
        let mut hits = self.results;
        hits.extend(self.memories);
        hits.extend(self.resources);
        hits.extend(self.skills);
        hits
    }
}

// A single ranked hit. Consumed in the server's array (rank) order, so the
// numeric `score` is intentionally not parsed.
#[derive(Debug, Deserialize)]
struct FindHit {
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    text: Option<String>,
    /// Stable id; often the only body a Skip-VLM hit carries. Resolved to the
    /// verbatim stored line via `content/read` when no inline body is present.
    #[serde(default)]
    uri: Option<String>,
}

impl FindHit {
    /// A non-blank VERBATIM inline body (content/text — what content/write stores).
    /// Excludes any `abstract` summary, which is NOT the stored line: an
    /// abstract-only hit is resolved via content/read instead, and is never matched
    /// directly (it could map onto the wrong authorized line).
    fn verbatim_inline_body(&self) -> Option<&str> {
        [self.content.as_deref(), self.text.as_deref()]
            .into_iter()
            .flatten()
            .map(str::trim)
            .find(|s| !s.is_empty())
    }
}

impl OpenVikingClient {
    /// Build from the OpenViking env vars; `None` when `OPENVIKING_ENDPOINT` is
    /// unset/empty (so the caller cleanly falls back to a built-in engine).
    pub fn from_env() -> Option<Self> {
        let endpoint = std::env::var("OPENVIKING_ENDPOINT")
            .ok()
            .filter(|s| !s.is_empty())?;
        let client = Self::new(
            endpoint,
            std::env::var("OPENVIKING_API_KEY").unwrap_or_default(),
            std::env::var("OPENVIKING_ACCOUNT").unwrap_or_else(|_| "default".to_string()),
            std::env::var("OPENVIKING_USER").unwrap_or_else(|_| "default".to_string()),
            std::env::var("OPENVIKING_AGENT").unwrap_or_else(|_| "hermes".to_string()),
        );
        Some(
            client
                .with_request_timeout_ms(env_u64("OPENVIKING_TIMEOUT_MS", DEFAULT_TIMEOUT_MS))
                .with_max_response_bytes(env_usize(
                    "OPENVIKING_MAX_RESPONSE_BYTES",
                    DEFAULT_MAX_RESPONSE_BYTES,
                )),
        )
    }

    pub fn new(
        endpoint: String,
        api_key: String,
        account: String,
        user: String,
        agent: String,
    ) -> Self {
        Self {
            endpoint: endpoint.trim_end_matches('/').to_string(),
            api_key,
            account,
            user,
            agent,
            http: http_client(DEFAULT_TIMEOUT_MS),
            max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
        }
    }

    /// Override the per-request timeout (rebuilds the HTTP client). Used by
    /// `from_env` for `OPENVIKING_TIMEOUT_MS` and by tests for a short bound.
    pub fn with_request_timeout_ms(mut self, ms: u64) -> Self {
        self.http = http_client(ms);
        self
    }

    /// Override the max response byte cap (env `OPENVIKING_MAX_RESPONSE_BYTES`).
    /// Used by `from_env` and by tests.
    pub fn with_max_response_bytes(mut self, n: usize) -> Self {
        self.max_response_bytes = n;
        self
    }

    /// Read a response body bounded by `self.max_response_bytes`. A body that
    /// exceeds the cap (by Content-Length or while streaming) is an error, so a
    /// buggy/compromised server can't OOM the hook — the caller falls back.
    async fn read_body_capped(&self, mut resp: reqwest::Response) -> Result<String, OpenVikingError> {
        let cap = self.max_response_bytes;
        if resp.content_length().map(|l| l as usize > cap).unwrap_or(false) {
            return Err(OpenVikingError::Transport(format!(
                "openviking response exceeds {cap}-byte cap (Content-Length)"
            )));
        }
        let mut buf: Vec<u8> = Vec::new();
        while let Some(chunk) = resp
            .chunk()
            .await
            .map_err(|e| OpenVikingError::Transport(e.to_string()))?
        {
            if buf.len() + chunk.len() > cap {
                return Err(OpenVikingError::Transport(format!(
                    "openviking response exceeds {cap}-byte cap"
                )));
            }
            buf.extend_from_slice(chunk.as_ref());
        }
        String::from_utf8(buf).map_err(|e| OpenVikingError::Parse(e.to_string()))
    }

    fn with_headers(&self, req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        let mut req = req.header("X-OpenViking-Agent", &self.agent);
        if !self.account.is_empty() {
            req = req.header("X-OpenViking-Account", &self.account);
        }
        if !self.user.is_empty() {
            req = req.header("X-OpenViking-User", &self.user);
        }
        if !self.api_key.is_empty() {
            req = req
                .header("X-API-Key", &self.api_key)
                .header("Authorization", format!("Bearer {}", self.api_key));
        }
        req
    }

    pub async fn health(&self) -> bool {
        let url = format!("{}/health", self.endpoint);
        self.with_headers(self.http.get(&url))
            .send()
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    /// `POST /api/v1/search/find` — fetch RAW ranked hits (HTTP + parse only, no
    /// content/read). Gate-aware resolution + matching happens in
    /// [`OpenVikingClient::match_gate_authorized`].
    async fn fetch_hits(&self, query: &str, top_k: usize) -> Result<Vec<FindHit>, OpenVikingError> {
        let url = format!("{}/api/v1/search/find", self.endpoint);
        let resp = self
            .with_headers(
                self.http
                    .post(&url)
                    .json(&serde_json::json!({ "query": query, "top_k": top_k })),
            )
            .send()
            .await
            .map_err(|e| OpenVikingError::Transport(e.to_string()))?;
        let status = resp.status();
        let body = self.read_body_capped(resp).await?;
        if !status.is_success() {
            return Err(OpenVikingError::Http {
                status: status.as_u16(),
                body,
            });
        }
        let envelope: FindEnvelope =
            serde_json::from_str(&body).map_err(|e| OpenVikingError::Parse(e.to_string()))?;
        if envelope.status.as_deref() == Some("error") {
            return Err(OpenVikingError::Http {
                status: status.as_u16(),
                body,
            });
        }
        Ok(envelope.result.map(FindResult::all_hits).unwrap_or_default())
    }

    /// Fetch ranked hits and resolve + gate-match them IN RANK ORDER, returning the
    /// authorized lines (gate-bounded, deduped, in OpenViking's order). URI-only
    /// hits are resolved via content/read up to a budget, but with EARLY-STOP once
    /// enough authorized lines fill `budget.max_lines` — so a few high-ranked
    /// out-of-gate URI hits can't consume the read budget before authorized lines
    /// ranked below them are even seen (/codex:adversarial-review).
    async fn match_gate_authorized(
        &self,
        query: &str,
        top_k: usize,
        lines: &[MemoryLine],
        budget: &SelectionBudget,
    ) -> Vec<MemoryLine> {
        let hits = match self.fetch_hits(query, top_k).await {
            Ok(h) => h,
            Err(_) => return Vec::new(),
        };
        let read_cap = env_usize("OPENVIKING_MAX_URI_READS", DEFAULT_MAX_URI_READS);
        let mut reads = 0usize;
        let mut out: Vec<MemoryLine> = Vec::new();
        let mut used_bytes = 0usize;
        let mut taken = std::collections::HashSet::new();
        for hit in hits {
            // Early stop: enough authorized lines to fill the output line budget.
            if budget.max_lines.is_some_and(|max| out.len() >= max) {
                break;
            }
            let text = if let Some(body) = hit.verbatim_inline_body() {
                // Verbatim inline body (content/text) — use directly.
                body.to_string()
            } else if let Some(uri) = hit.uri.as_deref() {
                // Resolve the verbatim stored line via content/read — for BOTH
                // Skip-VLM (uri-only) hits AND VLM hits whose only inline body is an
                // L0 `abstract` (a summary that won't gate-match). Capped + each read
                // bounded by the client timeout; spent in rank order with early-stop,
                // not wasted on out-of-gate hits. A failed/timed-out read drops just
                // this hit.
                if reads >= read_cap {
                    continue;
                }
                reads += 1;
                match self.read_content(uri).await {
                    Ok(line) => line,
                    Err(_) => continue,
                }
            } else {
                // No verbatim body (content/text) and no uri to resolve to the
                // verbatim line — drop. An L0 `abstract` is a SUMMARY, not the stored
                // line; matching it risks mapping onto the WRONG authorized line
                // (e.g. a negation), so abstract-only hits are never matched
                // (/codex:adversarial-review).
                continue;
            };
            let text = text.trim();
            if text.is_empty() {
                continue;
            }
            // Gate-bound: only ever return lines that were in the authorized set.
            // EXACT normalized match (case/whitespace-insensitive) — NOT substring
            // containment, which could map a partial hit onto the WRONG authorized
            // line (e.g. "allergic to peanuts" → "Not allergic to peanuts"). The
            // verbatim line comes from content/read, so exact equality is the right,
            // safe join (/codex:adversarial-review).
            let hit_norm = normalize(text);
            if let Some(line) = lines.iter().find(|l| normalize(&l.text) == hit_norm) {
                if !taken.contains(&line.seq) {
                    // Apply the byte budget INLINE (not deferred to a later pass), so
                    // an oversized matched line is SKIPPED — and does NOT count toward
                    // max_lines (the early-stop above) — leaving room to recover
                    // lower-ranked authorized lines that fit (/codex:adversarial-review).
                    if let Some(max_bytes) = budget.max_bytes {
                        let cost = line.text.len() + 1;
                        if used_bytes + cost > max_bytes {
                            continue;
                        }
                        used_bytes += cost;
                    }
                    taken.insert(line.seq);
                    out.push(line.clone());
                }
            }
        }
        out
    }

    /// `POST /api/v1/content/write` — mirror one gate-authorized line into
    /// OpenViking so `search/find` can rank it. The durable copy stays in
    /// AgentKeys' encrypted S3; this is OpenViking's (operator-self-hosted)
    /// ranking index only.
    pub async fn write_content(&self, uri: &str, content: &str) -> Result<(), OpenVikingError> {
        let url = format!("{}/api/v1/content/write", self.endpoint);
        let resp = self
            .with_headers(self.http.post(&url).json(&serde_json::json!({
                "uri": uri,
                "content": content,
                "mode": "create",
            })))
            .send()
            .await
            .map_err(|e| OpenVikingError::Transport(e.to_string()))?;
        let status = resp.status();
        if !status.is_success() {
            let body = self.read_body_capped(resp).await.unwrap_or_default();
            return Err(OpenVikingError::Http {
                status: status.as_u16(),
                body,
            });
        }
        Ok(())
    }

    /// `POST /api/v1/content/read` — fetch the verbatim stored line for a
    /// `uri`. Used to resolve URI-only / blank-abstract `search/find` hits
    /// (Skip-VLM mode) back to text before gate matching. Tolerant of the
    /// response envelope shape (see [`extract_read_content`]).
    pub async fn read_content(&self, uri: &str) -> Result<String, OpenVikingError> {
        let url = format!("{}/api/v1/content/read", self.endpoint);
        let resp = self
            .with_headers(
                self.http
                    .post(&url)
                    .json(&serde_json::json!({ "uri": uri })),
            )
            .send()
            .await
            .map_err(|e| OpenVikingError::Transport(e.to_string()))?;
        let status = resp.status();
        let body = self.read_body_capped(resp).await?;
        if !status.is_success() {
            return Err(OpenVikingError::Http {
                status: status.as_u16(),
                body,
            });
        }
        let value: serde_json::Value =
            serde_json::from_str(&body).map_err(|e| OpenVikingError::Parse(e.to_string()))?;
        extract_read_content(&value)
            .ok_or_else(|| OpenVikingError::Parse(format!("content/read: no text in {body}")))
    }
}

fn normalize(text: &str) -> String {
    text.trim().to_lowercase()
}

/// Pull the stored line text out of a `content/read` response, tolerant of the
/// exact envelope shape: `result.{content|text|body|abstract}`, a grouped
/// `result.<kind>[0].{...}`, or a top-level field. Pure helper, unit-tested.
fn extract_read_content(value: &serde_json::Value) -> Option<String> {
    fn probe(obj: &serde_json::Value) -> Option<String> {
        for key in ["content", "text", "body", "abstract"] {
            if let Some(s) = obj.get(key).and_then(|v| v.as_str()) {
                let s = s.trim();
                if !s.is_empty() {
                    return Some(s.to_string());
                }
            }
        }
        None
    }
    if let Some(result) = value.get("result") {
        if let Some(s) = probe(result) {
            return Some(s);
        }
        for kind in ["memories", "resources", "skills", "results"] {
            if let Some(first) = result
                .get(kind)
                .and_then(|a| a.as_array())
                .and_then(|a| a.first())
            {
                if let Some(s) = probe(first) {
                    return Some(s);
                }
            }
        }
    }
    probe(value)
}

/// Rank gate-authorized `lines` via OpenViking, bounded by the gate and by an
/// overall `deadline`.
///
/// Returns `Some(reordered subset of `lines`)` on success, or `None` on any
/// error / empty / no-match / timeout so the caller falls back to a deterministic
/// engine. A hit maps to a line when their normalized text is equal or one
/// contains the other (OpenViking may return a tiered abstract rather than the
/// verbatim line). Only `lines` entries are ever returned — never a raw hit.
///
/// `deadline` bounds this ENTIRE call (find + every content/read). The CALLER
/// owns it as a hook-WIDE budget shared across namespaces (`memory_inject` passes
/// the *remaining* budget before each namespace), so N namespaces can't each get
/// a fresh deadline and overrun the host `pre_llm_call` timeout. On elapse → None
/// → the caller falls back in time (/codex:adversarial-review).
pub async fn rank_gate_bounded(
    client: &OpenVikingClient,
    query: &str,
    lines: &[MemoryLine],
    budget: &SelectionBudget,
    deadline: std::time::Duration,
) -> Option<Vec<MemoryLine>> {
    if lines.is_empty() {
        return None;
    }
    // Fetch a generous window DECOUPLED from the output budget so unauthorized
    // index records can't crowd out lower-ranked authorized lines.
    let top_k = openviking_fetch_top_k(lines.len());
    // The WHOLE phase — fetch + every content/read + gate matching — is bounded by
    // ONE deadline. match_gate_authorized reads IN RANK ORDER with early-stop, so a
    // few high-ranked out-of-gate URI hits can't consume the read budget before
    // authorized lines are seen (/codex:adversarial-review).
    let out = match tokio::time::timeout(
        deadline,
        client.match_gate_authorized(query, top_k, lines, budget),
    )
    .await
    {
        Ok(out) => out,        // gate-matched authorized lines (possibly empty)
        Err(_) => return None, // overall deadline exceeded → fall back NOW
    };
    // `out` is already line + byte budgeted by match_gate_authorized — the budget is
    // applied INLINE with early-stop, so the line count and byte total are enforced
    // together (an oversized line can't fill a line slot then get dropped) and reads
    // stop once the output budget is met (/codex:adversarial-review).
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::State, routing::post, Json, Router};

    async fn spawn_stub(response: serde_json::Value) -> String {
        let app = Router::new()
            .route(
                "/api/v1/search/find",
                post(|State(body): State<serde_json::Value>| async move { Json(body) }),
            )
            .with_state(response);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        format!("http://{addr}")
    }

    #[derive(Clone)]
    struct FindReadState {
        find: serde_json::Value,
        read: serde_json::Value,
    }

    /// Stub serving BOTH `/search/find` and `/content/read` — for the Skip-VLM
    /// path where find returns URI-only hits the adapter resolves via read.
    async fn spawn_find_read_stub(find: serde_json::Value, read: serde_json::Value) -> String {
        let app = Router::new()
            .route(
                "/api/v1/search/find",
                post(|State(s): State<FindReadState>| async move { Json(s.find) }),
            )
            .route(
                "/api/v1/content/read",
                post(|State(s): State<FindReadState>| async move { Json(s.read) }),
            )
            .with_state(FindReadState { find, read });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        format!("http://{addr}")
    }

    /// Stub whose `/content/read` STALLS (sleeps), to prove a missing per-request
    /// timeout would hang the caller. `/search/find` returns `find` instantly.
    async fn spawn_slow_read_stub(find: serde_json::Value) -> String {
        async fn slow_read() -> Json<serde_json::Value> {
            tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            // Body WOULD match a gate line — so a None result proves the read was
            // dropped by the timeout, not a no-match.
            Json(serde_json::json!({ "result": { "content": "Allergic to peanuts." } }))
        }
        let app = Router::new()
            .route(
                "/api/v1/search/find",
                post(|State(s): State<serde_json::Value>| async move { Json(s) }),
            )
            .route("/api/v1/content/read", post(slow_read))
            .with_state(find);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        format!("http://{addr}")
    }

    /// Stub whose `/search/find` RESPECTS `top_k` — returns only the first `top_k`
    /// of a canned ranked list, so a too-small fetch window is observable.
    async fn spawn_topk_stub(ranked: Vec<serde_json::Value>) -> String {
        let app = Router::new()
            .route(
                "/api/v1/search/find",
                post(
                    |State(ranked): State<Vec<serde_json::Value>>,
                     Json(req): Json<serde_json::Value>| async move {
                        let top_k =
                            req.get("top_k").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                        let hits: Vec<serde_json::Value> =
                            ranked.into_iter().take(top_k).collect();
                        Json(serde_json::json!({ "result": { "results": hits } }))
                    },
                ),
            )
            .with_state(ranked);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        format!("http://{addr}")
    }

    fn client(endpoint: String) -> OpenVikingClient {
        OpenVikingClient::new(
            endpoint,
            String::new(),
            "default".into(),
            "default".into(),
            "hermes".into(),
        )
    }

    fn lines() -> Vec<MemoryLine> {
        vec![
            MemoryLine {
                text: "Chengdu trip — Apr 12 to 16.".into(),
                seq: 0,
            },
            MemoryLine {
                text: "Allergic to peanuts.".into(),
                seq: 1,
            },
        ]
    }

    #[tokio::test]
    async fn memories_array_with_blank_abstract_resolves_via_content_read() {
        // The DOCUMENTED live shape (issue #147 / codex finding): hits arrive
        // under `result.memories` (not `results`), and in Skip-VLM mode the
        // `abstract` is blank — so the only body is the `uri`. The adapter MUST
        // (a) read the `memories` array and (b) content/read the uri to recover
        // the verbatim line for gate-matching. Before this fix the adapter saw
        // an empty `results` array → no hits → None → silent fallback.
        let find = serde_json::json!({
            "result": { "memories": [
                { "score": 0.9, "uri": "viking://user/default/memories/travel/m0.md", "abstract": "" }
            ]}
        });
        let read = serde_json::json!({ "result": { "content": "Allergic to peanuts." } });
        let endpoint = spawn_find_read_stub(find, read).await;
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let out = rank_gate_bounded(
            &client(endpoint),
            "peanut",
            &lines(),
            &budget,
            std::time::Duration::from_secs(5),
        )
        .await
        .expect("memories hit resolved via content/read must rank a gate line");
        assert_eq!(
            out.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["Allergic to peanuts."]
        );
    }

    #[tokio::test]
    async fn slow_content_read_times_out_and_falls_back() {
        // A URI-only hit whose content/read STALLS (3s). With a short per-request
        // timeout the read errors → the hit drops → rank_gate_bounded returns None
        // → the caller falls back to lexical. Without the timeout (codex finding)
        // this would hang past the host hook deadline. The stalled read returns a
        // body that WOULD match a gate line, so a None result proves the timeout
        // fired (not a no-match).
        let find = serde_json::json!({
            "result": { "memories": [
                { "score": 0.9, "uri": "viking://user/default/memories/travel/m0.md", "abstract": "" }
            ]}
        });
        let endpoint = spawn_slow_read_stub(find).await;
        let cl = client(endpoint).with_request_timeout_ms(200);
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let out =
            rank_gate_bounded(&cl, "peanut", &lines(), &budget, std::time::Duration::from_secs(5))
                .await;
        assert!(
            out.is_none(),
            "a stalled content/read must time out and fall back to None, not hang"
        );
    }

    #[tokio::test]
    async fn stalled_read_respects_overall_deadline_and_falls_back() {
        // find returns a URI-only hit FAST; content/read stalls (3s). The OVERALL
        // ranking deadline (300ms here) must make rank_gate_bounded return None
        // well under the host pre_llm_call timeout (5s), so the caller falls back
        // to lexical in time — the bound is the overall deadline, NOT per-request
        // timeout × read cap (/codex:adversarial-review).
        let find = serde_json::json!({
            "result": { "memories": [
                { "score": 0.9, "uri": "viking://user/default/memories/travel/m0.md", "abstract": "" }
            ]}
        });
        let endpoint = spawn_slow_read_stub(find).await;
        let cl = client(endpoint);
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let start = std::time::Instant::now();
        let out = rank_gate_bounded(
            &cl,
            "peanut",
            &lines(),
            &budget,
            std::time::Duration::from_millis(300),
        )
        .await;
        let elapsed = start.elapsed();
        assert!(out.is_none(), "stalled read must hit the overall deadline → None");
        assert!(
            elapsed < std::time::Duration::from_secs(2),
            "overall deadline (300ms) must return well under the 5s host hook timeout; took {elapsed:?}"
        );
    }

    #[tokio::test]
    async fn shared_budget_across_namespaces_stays_under_host_timeout() {
        // Models memory_inject's namespace loop: ONE budget SHARED across two
        // stalled rankings (not a fresh deadline per namespace). The two stalled
        // reads must TOGETHER finish well under the 5s host hook timeout — proving
        // the budget is hook-WIDE. Per-namespace deadlines would be ~2× here and
        // could overrun the host (/codex:adversarial-review).
        let find = serde_json::json!({
            "result": { "memories": [
                { "score": 0.9, "uri": "viking://user/default/memories/travel/m0.md", "abstract": "" }
            ]}
        });
        let endpoint = spawn_slow_read_stub(find).await; // content/read stalls 3s
        let cl = client(endpoint);
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let total = std::time::Duration::from_millis(600); // shared across both namespaces
        let start = std::time::Instant::now();
        for _namespace in 0..2 {
            let remaining = total.saturating_sub(start.elapsed());
            let out = if remaining.is_zero() {
                None // budget exhausted → skip OpenViking, fall back (as the hook does)
            } else {
                rank_gate_bounded(&cl, "peanut", &lines(), &budget, remaining).await
            };
            assert!(out.is_none(), "each stalled ranking falls back to None");
        }
        let elapsed = start.elapsed();
        assert!(
            elapsed < std::time::Duration::from_secs(2),
            "two stalled rankings under a SHARED 600ms budget must finish well under the 5s host \
             timeout (per-namespace deadlines would be ~6s); took {elapsed:?}"
        );
    }

    #[tokio::test]
    async fn oversize_search_find_body_is_rejected_and_falls_back() {
        // A fast but OVERSIZED /search/find body must be rejected (not buffered
        // unboundedly) so the caller falls back, never OOMing the hook
        // (/codex:adversarial-review).
        let big = "x".repeat(5000);
        let endpoint = spawn_stub(serde_json::json!({
            "result": { "results": [ { "score": 0.9, "content": big } ] }
        }))
        .await;
        let cl = client(endpoint).with_max_response_bytes(500);
        let budget = SelectionBudget::default();
        let out =
            rank_gate_bounded(&cl, "q", &lines(), &budget, std::time::Duration::from_secs(5)).await;
        assert!(out.is_none(), "oversized search/find body must be rejected → None");
    }

    #[tokio::test]
    async fn oversize_content_read_body_is_rejected_and_falls_back() {
        // find is small (a URI-only hit) but content/read is OVERSIZED → the read is
        // rejected, the hit drops, and ranking falls back (/codex:adversarial-review).
        let find = serde_json::json!({
            "result": { "memories": [
                { "score": 0.9, "uri": "viking://user/default/memories/travel/m0.md", "abstract": "" }
            ]}
        });
        let big = "y".repeat(5000);
        let read = serde_json::json!({ "result": { "content": big } });
        let endpoint = spawn_find_read_stub(find, read).await;
        let cl = client(endpoint).with_max_response_bytes(500);
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let out = rank_gate_bounded(&cl, "peanut", &lines(), &budget, std::time::Duration::from_secs(5))
            .await;
        assert!(out.is_none(), "oversized content/read body must be rejected → None");
    }

    #[tokio::test]
    async fn ranked_output_respects_max_bytes() {
        // max_bytes set WITHOUT max_lines: the ranked OpenViking output must be
        // byte-budgeted like the built-in engines, not inject every matching line
        // (/codex:adversarial-review).
        let endpoint = spawn_stub(serde_json::json!({
            "result": { "results": [
                { "score": 0.9, "content": "Allergic to peanuts." },
                { "score": 0.7, "content": "Chengdu trip — Apr 12 to 16." }
            ]}
        }))
        .await;
        let cl = client(endpoint);
        // Bytes for exactly the first ranked line (text + newline), no line cap.
        let budget = SelectionBudget {
            max_lines: None,
            max_bytes: Some("Allergic to peanuts.".len() + 1),
        };
        let out = rank_gate_bounded(&cl, "peanut", &lines(), &budget, std::time::Duration::from_secs(5))
            .await
            .unwrap();
        assert_eq!(
            out.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["Allergic to peanuts."],
            "max_bytes must cap the ranked output to the top line that fits"
        );
    }

    #[tokio::test]
    async fn non_verbatim_abstract_is_resolved_via_content_read() {
        // VLM-enabled server: the hit carries a non-blank `abstract` (an L0 summary
        // that does NOT match the gate line) plus a uri. The adapter must content/read
        // the uri for the verbatim line, not gate-match the summary
        // (/codex:adversarial-review).
        let find = serde_json::json!({
            "result": { "memories": [
                { "score": 0.9, "uri": "viking://user/default/memories/travel/m0.md",
                  "abstract": "a short note about the traveler's food allergies" }
            ]}
        });
        let read = serde_json::json!({ "result": { "content": "Allergic to peanuts." } });
        let endpoint = spawn_find_read_stub(find, read).await;
        let cl = client(endpoint);
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let out = rank_gate_bounded(&cl, "peanut", &lines(), &budget, std::time::Duration::from_secs(5))
            .await
            .expect("a non-verbatim abstract + uri must resolve the verbatim line via content/read");
        assert_eq!(
            out.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["Allergic to peanuts."]
        );
    }

    #[tokio::test]
    async fn overfetch_recovers_authorized_hit_below_unauthorized() {
        // OpenViking's index also holds UNAUTHORIZED records that can rank above an
        // authorized line. With max_lines=1, sizing the fetch from the output budget
        // would pull only the unauthorized hit and silently fall back. Overfetch must
        // pull the authorized line too, then budget the OUTPUT (/codex:adversarial-review).
        let ranked = vec![
            serde_json::json!({ "score": 0.9, "content": "SECRET unauthorized record not in the gate" }),
            serde_json::json!({ "score": 0.7, "content": "Allergic to peanuts." }),
        ];
        let endpoint = spawn_topk_stub(ranked).await;
        let cl = client(endpoint);
        let budget = SelectionBudget {
            max_lines: Some(1),
            max_bytes: None,
        };
        let out = rank_gate_bounded(&cl, "peanut", &lines(), &budget, std::time::Duration::from_secs(5))
            .await
            .expect("overfetch must recover the authorized hit ranked below an unauthorized one");
        assert_eq!(
            out.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["Allergic to peanuts."]
        );
    }

    #[test]
    fn fetch_top_k_overfetches_independent_of_output_budget() {
        assert_eq!(openviking_fetch_top_k(1), MIN_FETCH_TOP_K); // tiny gate set still overfetches
        assert_eq!(openviking_fetch_top_k(10), 10 * OVERFETCH_FACTOR); // 80
        assert_eq!(openviking_fetch_top_k(1000), MAX_FETCH_TOP_K); // capped
    }

    #[tokio::test]
    async fn ranked_output_drops_oversized_line_under_byte_cap() {
        // The only matching authorized line is larger than max_bytes → the HARD byte
        // cap drops it; rank returns None so the caller falls back rather than inject
        // over budget (/codex:adversarial-review).
        let endpoint = spawn_stub(serde_json::json!({
            "result": { "results": [ { "score": 0.9, "content": "Allergic to peanuts." } ] }
        }))
        .await;
        let cl = client(endpoint);
        let budget = SelectionBudget {
            max_lines: None,
            max_bytes: Some(5),
        };
        let out = rank_gate_bounded(&cl, "peanut", &lines(), &budget, std::time::Duration::from_secs(5))
            .await;
        assert!(
            out.is_none(),
            "an oversized-only ranked line must be dropped (hard cap) → None"
        );
    }

    #[derive(Clone)]
    struct FindUriReadState {
        find: serde_json::Value,
        reads: std::collections::HashMap<String, String>,
    }

    /// Stub whose `/content/read` returns DIFFERENT content per uri, so a scan over
    /// many uri-only hits (most out-of-gate) can be exercised.
    async fn spawn_find_uri_read_stub(
        find: serde_json::Value,
        reads: std::collections::HashMap<String, String>,
    ) -> String {
        let app = Router::new()
            .route(
                "/api/v1/search/find",
                post(|State(s): State<FindUriReadState>| async move { Json(s.find) }),
            )
            .route(
                "/api/v1/content/read",
                post(
                    |State(s): State<FindUriReadState>, Json(req): Json<serde_json::Value>| async move {
                        let uri =
                            req.get("uri").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let content = s.reads.get(&uri).cloned().unwrap_or_default();
                        Json(serde_json::json!({ "result": { "content": content } }))
                    },
                ),
            )
            .with_state(FindUriReadState { find, reads });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn read_budget_scans_past_unauthorized_uri_hits_to_authorized() {
        // 12 UNAUTHORIZED URI-only hits rank ABOVE the authorized one (all Skip-VLM,
        // uri-only). A fixed read cap of 8 would never read the authorized line at
        // position 13; the gate-aware scan (rank order, early-stop, generous cap +
        // deadline) must recover it (/codex:adversarial-review).
        use std::collections::HashMap;
        let mut hits = Vec::new();
        let mut reads = HashMap::new();
        for i in 0..12 {
            let uri = format!("viking://user/default/memories/other/u{i}.md");
            hits.push(serde_json::json!({
                "score": 0.99 - (i as f64) * 0.01, "uri": uri.clone(), "abstract": ""
            }));
            reads.insert(uri, format!("unauthorized record {i} not in the gate"));
        }
        let auth_uri = "viking://user/default/memories/travel/m0.md".to_string();
        hits.push(serde_json::json!({ "score": 0.5, "uri": auth_uri.clone(), "abstract": "" }));
        reads.insert(auth_uri, "Allergic to peanuts.".to_string());
        let find = serde_json::json!({ "result": { "memories": hits } });
        let endpoint = spawn_find_uri_read_stub(find, reads).await;
        let cl = client(endpoint);
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let out = rank_gate_bounded(&cl, "peanut", &lines(), &budget, std::time::Duration::from_secs(5))
            .await
            .expect("must scan past 12 unauthorized URI hits and recover the authorized one");
        assert_eq!(
            out.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["Allergic to peanuts."]
        );
    }

    #[tokio::test]
    async fn openviking_line_and_byte_caps_recover_next_fitting_line() {
        // max_lines=1 + max_bytes below the TOP-ranked authorized line, but a 2nd
        // authorized line fits: the match must SKIP the oversized top line (not
        // early-stop on it and then drop everything) and recover the fitting one
        // (/codex:adversarial-review).
        let endpoint = spawn_stub(serde_json::json!({
            "result": { "results": [
                { "content": "Chengdu trip — Apr 12 to 16." }, // authorized, oversized, top
                { "content": "Allergic to peanuts." }          // authorized, fits
            ]}
        }))
        .await;
        let cl = client(endpoint);
        let budget = SelectionBudget {
            max_lines: Some(1),
            max_bytes: Some("Allergic to peanuts.".len() + 1),
        };
        let out = rank_gate_bounded(&cl, "peanut", &lines(), &budget, std::time::Duration::from_secs(5))
            .await
            .expect("must skip the oversized top line and recover the fitting authorized line");
        assert_eq!(
            out.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["Allergic to peanuts."]
        );
    }

    #[tokio::test]
    async fn exact_match_does_not_map_hit_onto_negated_line() {
        // A hit must EXACT-match its authorized line, never substring-match a
        // different (e.g. negated) line that merely contains it. "Allergic to
        // peanuts." must map to "Allergic to peanuts." — NOT the earlier "Not
        // allergic to peanuts." (/codex:adversarial-review).
        let endpoint = spawn_stub(serde_json::json!({
            "result": { "results": [ { "content": "Allergic to peanuts." } ] }
        }))
        .await;
        let gate = vec![
            MemoryLine {
                text: "Not allergic to peanuts.".into(),
                seq: 0,
            },
            MemoryLine {
                text: "Allergic to peanuts.".into(),
                seq: 1,
            },
        ];
        let cl = client(endpoint);
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let out = rank_gate_bounded(&cl, "peanut", &gate, &budget, std::time::Duration::from_secs(5))
            .await
            .expect("exact hit must map to the matching authorized line");
        assert_eq!(
            out.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            vec!["Allergic to peanuts."],
            "must NOT map onto the negated line that merely contains the hit"
        );
    }

    #[test]
    fn extract_read_content_handles_envelope_shapes() {
        let r = |v: serde_json::Value| extract_read_content(&v);
        assert_eq!(
            r(serde_json::json!({"result": {"content": "x"}})),
            Some("x".to_string())
        );
        assert_eq!(
            r(serde_json::json!({"result": {"text": " y "}})),
            Some("y".to_string())
        );
        assert_eq!(
            r(serde_json::json!({"result": {"memories": [{"content": "z"}]}})),
            Some("z".to_string())
        );
        assert_eq!(r(serde_json::json!({"content": "top"})), Some("top".to_string()));
        assert_eq!(r(serde_json::json!({"result": {"abstract": ""}})), None);
    }

    #[tokio::test]
    async fn fetch_hits_parses_score_ordered_hits() {
        let endpoint = spawn_stub(serde_json::json!({
            "result": {"results": [
                {"score": 0.9, "content": "Allergic to peanuts."},
                {"score": 0.7, "text": "Chengdu trip — Apr 12 to 16."}
            ]}
        }))
        .await;
        let hits = client(endpoint).fetch_hits("peanut", 5).await.unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].verbatim_inline_body(), Some("Allergic to peanuts."));
        assert_eq!(
            hits[1].verbatim_inline_body(),
            Some("Chengdu trip — Apr 12 to 16.")
        );
    }

    #[tokio::test]
    async fn rank_is_gate_bounded_and_reordered() {
        // OpenViking ranks peanuts top, then chengdu, AND returns an
        // unauthorized line that is NOT in the gate set — it must be dropped.
        let endpoint = spawn_stub(serde_json::json!({
            "result": {"results": [
                {"score": 0.9, "content": "Allergic to peanuts."},
                {"score": 0.8, "content": "SECRET not in the authorized set"},
                {"score": 0.7, "content": "Chengdu trip — Apr 12 to 16."}
            ]}
        }))
        .await;
        let budget = SelectionBudget {
            max_lines: Some(5),
            max_bytes: None,
        };
        let out = rank_gate_bounded(
            &client(endpoint),
            "peanut",
            &lines(),
            &budget,
            std::time::Duration::from_secs(5),
        )
        .await
        .unwrap();
        let texts: Vec<&str> = out.iter().map(|l| l.text.as_str()).collect();
        // gate-bound: only the two authorized lines, in OpenViking's order
        assert_eq!(
            texts,
            vec!["Allergic to peanuts.", "Chengdu trip — Apr 12 to 16."]
        );
    }

    #[tokio::test]
    async fn empty_results_falls_back_to_none() {
        let endpoint = spawn_stub(serde_json::json!({ "result": {"results": []} })).await;
        let budget = SelectionBudget::default();
        assert!(rank_gate_bounded(
            &client(endpoint),
            "q",
            &lines(),
            &budget,
            std::time::Duration::from_secs(5)
        )
        .await
        .is_none());
    }

    #[tokio::test]
    async fn budget_caps_results() {
        let endpoint = spawn_stub(serde_json::json!({
            "result": {"results": [
                {"score": 0.9, "content": "Allergic to peanuts."},
                {"score": 0.7, "content": "Chengdu trip — Apr 12 to 16."}
            ]}
        }))
        .await;
        let budget = SelectionBudget {
            max_lines: Some(1),
            max_bytes: None,
        };
        let out = rank_gate_bounded(
            &client(endpoint),
            "q",
            &lines(),
            &budget,
            std::time::Duration::from_secs(5),
        )
        .await
        .unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].text, "Allergic to peanuts.");
    }
}
