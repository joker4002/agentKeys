//! AWS-cred fetch helper for the Stage 7 broker (post-issue #71 Option A).
//!
//! When the daemon (or CLI) is run with `--broker-url`, the operator no longer
//! has to source `scripts/stage6-demo-env.sh`. The provisioner asks the broker
//! for an OIDC JWT, then does `AssumeRoleWithWebIdentity` **client-side** to
//! exchange that JWT for short-lived AWS credentials. Those creds are injected
//! into the scraper subprocess as `AWS_*` env vars.
//!
//! Behavior is opt-in: pass `BrokerCreds::None` (the default when no broker URL
//! is configured) and the subprocess inherits whatever `AWS_*` env the operator
//! already exported manually.
//!
//! ## Why client-side STS?
//!
//! Pre-issue-#71, the broker exposed `/v1/mint-aws-creds` which did the OIDC
//! mint + STS exchange + audit anchor write internally and returned ready-to-use
//! creds. After cloud-setup.md §4 swaps the IAM role's trust policy from
//! `Principal: {AWS: agentkeys-daemon}` to `Principal: {Federated: oidc-provider}`,
//! the broker's own IAM principal can no longer call `sts:AssumeRole` on the
//! role — only `AssumeRoleWithWebIdentity` works, and the JWT authenticates the
//! call (no broker creds needed).
//!
//! Doing the STS call **client-side** has a side benefit: the broker holds zero
//! AWS principals at runtime. Compromise blast radius drops to "OIDC signing
//! key only" (which signs scoped JWTs, not arbitrary STS calls).
//!
//! Issue: <https://github.com/litentry/agentKeys/issues/71>

use std::collections::HashMap;
use std::time::Duration;

use aws_config::BehaviorVersion;
use aws_sdk_sts::config::Region;
use serde::Deserialize;

use crate::error::{ProvisionError, ProvisionResult};

/// Broker `POST /v1/mint-oidc-jwt` response shape. Mirrors
/// `crates/agentkeys-broker-server/src/handlers/oidc.rs::MintOidcJwtResponse`.
#[derive(Debug, Clone, Deserialize)]
pub struct OidcJwtResponse {
    pub jwt: String,
    pub wallet: String,
    /// Unix-epoch-seconds expiration of the JWT itself, NOT the assumed-role
    /// session. JWT TTL is short (~5 min default); the assumed-role session
    /// has its own (1h-default) TTL set at AssumeRoleWithWebIdentity time.
    pub expiration: i64,
}

/// Final temp-cred shape passed to the scraper subprocess. The struct fields
/// match the broker's pre-issue-#71 `/v1/mint-aws-creds` response so callers
/// who already consume `AwsTempCreds.to_env(...)` need no changes.
#[derive(Debug, Clone)]
pub struct AwsTempCreds {
    pub access_key_id: String,
    pub secret_access_key: String,
    pub session_token: String,
    /// Unix epoch seconds. `duration_seconds` controls this — defaults to
    /// 3600 (1h). AWS caps the value at the role's MaxSessionDuration.
    pub expiration: i64,
    /// Wallet that authenticates the assumed session (the
    /// `agentkeys_user_wallet` PrincipalTag is set to this value).
    pub wallet: String,
}

impl AwsTempCreds {
    /// Render the creds as a `HashMap<String,String>` suitable for merging
    /// into a `tokio::process::Command` env. Adds the AWS region only when
    /// supplied — leaving it unset lets the subprocess fall back to `AWS_REGION`
    /// already in its environment.
    pub fn to_env(&self, region: Option<&str>) -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("AWS_ACCESS_KEY_ID".into(), self.access_key_id.clone());
        m.insert("AWS_SECRET_ACCESS_KEY".into(), self.secret_access_key.clone());
        m.insert("AWS_SESSION_TOKEN".into(), self.session_token.clone());
        if let Some(r) = region {
            m.insert("AWS_REGION".into(), r.to_string());
            m.insert("AWS_DEFAULT_REGION".into(), r.to_string());
        }
        m
    }
}

/// Fetch an OIDC JWT from the broker. The bearer is the daemon's own session
/// token (validated by the broker's session backend). Pulled out of
/// `fetch_via_broker` so unit tests can exercise the HTTP / bearer / parsing
/// half against an axum stub without needing to mock STS.
pub async fn fetch_oidc_jwt(
    broker_url: &str,
    session_token: &str,
) -> ProvisionResult<OidcJwtResponse> {
    let url = format!(
        "{}/v1/mint-oidc-jwt",
        broker_url.trim_end_matches('/')
    );
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .connect_timeout(Duration::from_secs(5))
        .build()
        .map_err(|e| ProvisionError::Internal(format!("build broker http client: {e}")))?;
    let resp = client
        .post(&url)
        .header("Authorization", format!("Bearer {}", session_token))
        .send()
        .await
        .map_err(|e| ProvisionError::Internal(format!("broker request to {url} failed: {e}")))?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(ProvisionError::Internal(format!(
            "broker {url} returned HTTP {}: {}",
            status,
            body
        )));
    }

    resp.json::<OidcJwtResponse>()
        .await
        .map_err(|e| ProvisionError::Internal(format!("parse broker jwt response: {e}")))
}

/// End-to-end caller: fetch the JWT from the broker, exchange it for AWS temp
/// creds via `AssumeRoleWithWebIdentity`, return the creds.
///
/// `role_arn` is the federated role configured in `cloud-setup.md §4.3` (e.g.
/// `arn:aws:iam::ACCOUNT:role/agentkeys-data-role`). The operator passes this
/// in via daemon env — typically `AGENTKEYS_DATA_ROLE_ARN` — because each
/// AgentKeys deployment has its own role ARN.
///
/// `region` is the AWS region for STS calls. STS is a global service but the
/// SDK still wants a region for endpoint resolution. `us-east-1` is fine
/// unless your role is region-restricted.
///
/// `session_duration_seconds`: caller controls the AWS-creds TTL. AWS clamps
/// to the role's `MaxSessionDuration` (default 3600s).
///
/// The STS client is built with **anonymous credentials** — the JWT
/// authenticates the call, the daemon needs zero AWS principals.
pub async fn fetch_via_broker(
    broker_url: &str,
    session_token: &str,
    role_arn: &str,
    region: &str,
    session_duration_seconds: i32,
) -> ProvisionResult<AwsTempCreds> {
    let jwt_resp = fetch_oidc_jwt(broker_url, session_token).await?;
    assume_role_with_jwt(
        &jwt_resp.jwt,
        &jwt_resp.wallet,
        role_arn,
        region,
        session_duration_seconds,
    )
    .await
}

/// Convenience overload that defaults `session_duration_seconds` to 3600 (1h).
pub async fn fetch_via_broker_default_ttl(
    broker_url: &str,
    session_token: &str,
    role_arn: &str,
    region: &str,
) -> ProvisionResult<AwsTempCreds> {
    fetch_via_broker(broker_url, session_token, role_arn, region, 3600).await
}

/// Run `AssumeRoleWithWebIdentity` against the live AWS STS endpoint with the
/// given JWT and return the temp creds. Anonymous SDK config — no AWS creds
/// required on this side.
async fn assume_role_with_jwt(
    jwt: &str,
    wallet: &str,
    role_arn: &str,
    region: &str,
    session_duration_seconds: i32,
) -> ProvisionResult<AwsTempCreds> {
    // BehaviorVersion::latest() is required by aws-config 1.x; without it the
    // SDK refuses to load defaults at runtime.
    let config = aws_config::defaults(BehaviorVersion::latest())
        .region(Region::new(region.to_string()))
        // No credential provider — AssumeRoleWithWebIdentity is unauthenticated
        // (the JWT authenticates). aws-sdk-sts allows the call to go through
        // without resolved credentials when only the federated operation is
        // invoked. We don't call `.no_credentials()` because that constructor
        // doesn't exist in aws-config 1.x; instead we install an anonymous
        // provider that produces no creds.
        .credentials_provider(AnonymousCredentials)
        .load()
        .await;
    let client = aws_sdk_sts::Client::new(&config);

    let session_name = build_session_name(wallet);
    let resp = client
        .assume_role_with_web_identity()
        .role_arn(role_arn)
        .role_session_name(&session_name)
        .web_identity_token(jwt)
        .duration_seconds(session_duration_seconds)
        .send()
        .await
        .map_err(|e| {
            ProvisionError::Internal(format!(
                "assume_role_with_web_identity({}): {}",
                role_arn, e
            ))
        })?;

    let creds = resp
        .credentials
        .ok_or_else(|| ProvisionError::Internal("STS returned no credentials".into()))?;

    Ok(AwsTempCreds {
        access_key_id: creds.access_key_id,
        secret_access_key: creds.secret_access_key,
        session_token: creds.session_token,
        expiration: creds.expiration.secs(),
        wallet: wallet.to_lowercase(),
    })
}

/// Wallet → STS session name (max 64 chars; alphanumeric + `=,.@-_`).
/// Mirrors `crates/agentkeys-broker-server/src/handlers/mint.rs::build_session_name`
/// so audit rows + CloudTrail events line up across broker mints (legacy /v1/mint-aws-creds)
/// and daemon-side mints (this function).
fn build_session_name(wallet: &str) -> String {
    let lc = wallet.to_lowercase();
    let trimmed = lc.trim_start_matches("0x");
    let suffix: String = trimmed.chars().take(40).collect();
    format!("agentkey-{}", suffix)
}

/// Anonymous credential provider for the STS client used in
/// `assume_role_with_jwt`. `AssumeRoleWithWebIdentity` is unauthenticated
/// (the JWT authenticates), so the SDK doesn't need credentials. aws-config
/// 1.x has no built-in "no credentials" mode, but a provider that returns
/// `Err(NoCredentials)` works because the federated STS operation never
/// actually invokes the resolver.
#[derive(Debug)]
struct AnonymousCredentials;

impl aws_credential_types::provider::ProvideCredentials for AnonymousCredentials {
    fn provide_credentials<'a>(
        &'a self,
    ) -> aws_credential_types::provider::future::ProvideCredentials<'a>
    where
        Self: 'a,
    {
        aws_credential_types::provider::future::ProvideCredentials::ready(Err(
            aws_credential_types::provider::error::CredentialsError::not_loaded(
                "anonymous (AssumeRoleWithWebIdentity uses JWT auth)",
            ),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_env_emits_three_aws_keys() {
        let creds = AwsTempCreds {
            access_key_id: "ASIA-test".into(),
            secret_access_key: "secret".into(),
            session_token: "tok".into(),
            expiration: 0,
            wallet: "0xabc".into(),
        };
        let env = creds.to_env(None);
        assert_eq!(env.get("AWS_ACCESS_KEY_ID").unwrap(), "ASIA-test");
        assert_eq!(env.get("AWS_SECRET_ACCESS_KEY").unwrap(), "secret");
        assert_eq!(env.get("AWS_SESSION_TOKEN").unwrap(), "tok");
        assert!(!env.contains_key("AWS_REGION"));
    }

    #[test]
    fn to_env_includes_region_when_given() {
        let creds = AwsTempCreds {
            access_key_id: "k".into(),
            secret_access_key: "s".into(),
            session_token: "t".into(),
            expiration: 0,
            wallet: "0xabc".into(),
        };
        let env = creds.to_env(Some("us-east-1"));
        assert_eq!(env.get("AWS_REGION").unwrap(), "us-east-1");
        assert_eq!(env.get("AWS_DEFAULT_REGION").unwrap(), "us-east-1");
    }

    #[test]
    fn build_session_name_lowercases_and_truncates() {
        let name = build_session_name("0xAbCdEf0123456789ABCDEF0123456789AbCdEf0123456789");
        assert!(name.starts_with("agentkey-"));
        assert!(name.len() <= 64, "STS rejects session names >64 chars");
        assert!(!name.contains(|c: char| c.is_uppercase()));
    }

    // ---- HTTP-side tests for fetch_oidc_jwt against an axum stub ----

    #[tokio::test]
    async fn fetch_oidc_jwt_happy_path() {
        let server = stub_broker_server(StubResponse::OkJwt).await;
        let resp = fetch_oidc_jwt(&server.url, "session-token").await.unwrap();
        assert!(resp.jwt.starts_with("eyJ"), "expected JWT-shaped string");
        assert_eq!(resp.wallet, "0xtest");
        assert_eq!(resp.expiration, 9_999_999_999);
    }

    #[tokio::test]
    async fn fetch_oidc_jwt_propagates_unauthorized() {
        let server = stub_broker_server(StubResponse::Unauthorized).await;
        let err = fetch_oidc_jwt(&server.url, "bogus")
            .await
            .expect_err("expected error on 401");
        let msg = err.to_string();
        assert!(msg.contains("401") || msg.contains("Unauthorized"), "msg = {msg}");
    }

    #[tokio::test]
    async fn fetch_oidc_jwt_handles_unreachable_broker() {
        // Port 1 is reserved; nothing listens there.
        let err = fetch_oidc_jwt("http://127.0.0.1:1", "tok")
            .await
            .expect_err("expected error on unreachable broker");
        assert!(err.to_string().contains("broker request"));
    }

    enum StubResponse {
        OkJwt,
        Unauthorized,
    }

    struct StubServer {
        url: String,
        _handle: tokio::task::JoinHandle<()>,
    }

    async fn stub_broker_server(response: StubResponse) -> StubServer {
        use axum::{routing::post, Json, Router};
        use serde_json::json;

        let router = match response {
            StubResponse::OkJwt => Router::new().route(
                "/v1/mint-oidc-jwt",
                post(|| async {
                    Json(json!({
                        "jwt": "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJzdHViIn0.fake-sig",
                        "wallet": "0xtest",
                        "expiration": 9_999_999_999_i64,
                    }))
                }),
            ),
            StubResponse::Unauthorized => Router::new().route(
                "/v1/mint-oidc-jwt",
                post(|| async {
                    (
                        axum::http::StatusCode::UNAUTHORIZED,
                        Json(json!({"error":"unauthorized","message":"bad bearer"})),
                    )
                }),
            ),
        };

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        StubServer {
            url: format!("http://{}", addr),
            _handle: handle,
        }
    }
}
