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
/// find/read/write/health call; the overall deadline above caps their sum so a
/// stalled server can never hang the hook (OpenViking is never load-bearing —
/// arch.md §22).
const DEFAULT_TIMEOUT_MS: u64 = 2000;
/// Cap on per-turn `content/read` fan-out (env `OPENVIKING_MAX_URI_READS`).
/// Defense-in-depth alongside the overall deadline; URI-only (Skip-VLM) hits are
/// resolved in OpenViking rank order so the most relevant lines are fetched first.
const DEFAULT_MAX_URI_READS: usize = 8;

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

#[derive(Debug, Clone)]
pub struct OpenVikingClient {
    endpoint: String,
    api_key: String,
    account: String,
    user: String,
    agent: String,
    http: reqwest::Client,
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

#[derive(Debug, Deserialize)]
struct FindHit {
    #[serde(default)]
    score: f64,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    text: Option<String>,
    /// L0 summary — BLANK in Skip-VLM mode (no model to generate it).
    #[serde(default, rename = "abstract")]
    abstract_: Option<String>,
    /// Stable id; often the only body a Skip-VLM hit carries. Resolved to the
    /// verbatim stored line via `content/read` when no inline body is present.
    #[serde(default)]
    uri: Option<String>,
}

impl FindHit {
    /// A non-blank inline body carried by the hit itself (no network call).
    fn inline_body(&self) -> Option<&str> {
        [
            self.content.as_deref(),
            self.text.as_deref(),
            self.abstract_.as_deref(),
        ]
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
        Some(client.with_request_timeout_ms(env_u64("OPENVIKING_TIMEOUT_MS", DEFAULT_TIMEOUT_MS)))
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
        }
    }

    /// Override the per-request timeout (rebuilds the HTTP client). Used by
    /// `from_env` for `OPENVIKING_TIMEOUT_MS` and by tests for a short bound.
    pub fn with_request_timeout_ms(mut self, ms: u64) -> Self {
        self.http = http_client(ms);
        self
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

    /// `POST /api/v1/search/find` — semantic ranking. Returns `(score, text)`
    /// hits in OpenViking's ranked order.
    pub async fn search_find(
        &self,
        query: &str,
        top_k: usize,
    ) -> Result<Vec<(f64, String)>, OpenVikingError> {
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
        let body = resp
            .text()
            .await
            .map_err(|e| OpenVikingError::Transport(e.to_string()))?;
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
        let hits = envelope.result.map(FindResult::all_hits).unwrap_or_default();
        let max_uri_reads = env_usize("OPENVIKING_MAX_URI_READS", DEFAULT_MAX_URI_READS);
        let mut uri_reads = 0usize;
        let mut ranked: Vec<(f64, String)> = Vec::with_capacity(hits.len());
        for hit in hits {
            if let Some(body) = hit.inline_body() {
                ranked.push((hit.score, body.to_string()));
            } else if let Some(uri) = hit.uri.as_deref() {
                // Skip-VLM / URI-only hit: fetch the verbatim stored line so the
                // gate text-match has something to compare. Best-effort — a failed
                // OR timed-out read drops just that hit, never aborts the ranking.
                // Capped at `max_uri_reads` and each bounded by the client timeout,
                // so a stalled OpenViking can't hang the hook: the read errors, the
                // hit drops, and an empty result falls back to the lexical engine.
                if uri_reads >= max_uri_reads {
                    continue;
                }
                uri_reads += 1;
                if let Ok(line) = self.read_content(uri).await {
                    let line = line.trim();
                    if !line.is_empty() {
                        ranked.push((hit.score, line.to_string()));
                    }
                }
            }
        }
        Ok(ranked)
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
            let body = resp.text().await.unwrap_or_default();
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
        let body = resp
            .text()
            .await
            .map_err(|e| OpenVikingError::Transport(e.to_string()))?;
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
    let top_k = budget.max_lines.unwrap_or(lines.len()).max(1);
    let hits = match tokio::time::timeout(deadline, client.search_find(query, top_k)).await {
        Ok(Ok(hits)) => hits,
        Ok(Err(_)) => return None, // OpenViking error → fall back
        Err(_) => return None,     // overall deadline exceeded → fall back NOW
    };
    if hits.is_empty() {
        return None;
    }
    let mut out: Vec<MemoryLine> = Vec::new();
    let mut taken = std::collections::HashSet::new();
    for (_score, hit_text) in hits {
        let hit_norm = normalize(&hit_text);
        if let Some(line) = lines.iter().find(|l| {
            let line_norm = normalize(&l.text);
            line_norm == hit_norm || hit_norm.contains(&line_norm) || line_norm.contains(&hit_norm)
        }) {
            if taken.insert(line.seq) {
                out.push(line.clone());
            }
        }
    }
    if out.is_empty() {
        return None;
    }
    if let Some(max) = budget.max_lines {
        out.truncate(max);
    }
    Some(out)
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
    async fn search_find_parses_score_ordered_hits() {
        let endpoint = spawn_stub(serde_json::json!({
            "result": {"results": [
                {"score": 0.9, "content": "Allergic to peanuts."},
                {"score": 0.7, "text": "Chengdu trip — Apr 12 to 16."}
            ]}
        }))
        .await;
        let hits = client(endpoint).search_find("peanut", 5).await.unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].1, "Allergic to peanuts.");
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
