//! Optional per-request AWS STS credentials passed via `X-Aws-*` headers.
//!
//! Architectural intent (arch.md §17.2 + issue #90 Q3): the broker is the
//! OIDC issuer; agents authenticate to the broker, the broker mints
//! STS creds via `AssumeRoleWithWebIdentity` tagged with the requesting
//! actor's omni. The agent forwards those creds to the worker for the
//! actual S3 op via three headers:
//!
//!   X-Aws-Access-Key-Id
//!   X-Aws-Secret-Access-Key
//!   X-Aws-Session-Token
//!
//! AWS IAM then enforces per-actor S3 scoping via `${aws:PrincipalTag/agentkeys_actor_omni}`
//! conditions (see `scripts/provision-vault-role.sh`). The worker becomes
//! a passive credential relay — even a compromised worker can't read
//! another actor's data because the STS creds are scoped at the AWS
//! layer.
//!
//! Backwards compatible: when the three headers are absent, the worker
//! falls back to the default credential chain (EC2 instance profile),
//! preserving the existing stage-1 demo behavior.

use aws_credential_types::provider::SharedCredentialsProvider;
use aws_credential_types::Credentials;
use aws_sdk_s3::Client as S3Client;
use axum::{
    async_trait,
    extract::FromRequestParts,
    http::{request::Parts, HeaderMap, StatusCode},
};

/// Three header values that together form a single STS session credential.
#[derive(Debug, Clone)]
pub struct StsCreds {
    pub access_key_id: String,
    pub secret_access_key: String,
    pub session_token: String,
}

impl StsCreds {
    /// Extract from a HeaderMap. Returns None if any of the three headers
    /// are missing (partial passthrough is an error — refuse to mint a
    /// half-authed S3 client).
    pub fn from_headers(headers: &HeaderMap) -> Option<Self> {
        let access_key_id = headers.get("x-aws-access-key-id")?.to_str().ok()?.to_string();
        let secret_access_key =
            headers.get("x-aws-secret-access-key")?.to_str().ok()?.to_string();
        let session_token = headers.get("x-aws-session-token")?.to_str().ok()?.to_string();
        if access_key_id.is_empty() || secret_access_key.is_empty() || session_token.is_empty() {
            return None;
        }
        Some(StsCreds { access_key_id, secret_access_key, session_token })
    }

    /// Build a per-request S3 client using these creds in the given region.
    /// The returned client is single-use; do NOT cache it across requests.
    pub async fn build_s3_client(&self, region: &str) -> S3Client {
        let creds = Credentials::new(
            self.access_key_id.clone(),
            self.secret_access_key.clone(),
            Some(self.session_token.clone()),
            None,
            "x-aws-creds-header",
        );
        let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(aws_config::Region::new(region.to_string()))
            .credentials_provider(SharedCredentialsProvider::new(creds))
            .load()
            .await;
        S3Client::new(&sdk_config)
    }
}

/// Axum extractor: pulls `Option<StsCreds>` from the request headers.
/// Absence is not an error (the worker falls back to instance-profile S3).
#[derive(Debug, Clone)]
pub struct OptionalStsCreds(pub Option<StsCreds>);

#[async_trait]
impl<S: Send + Sync> FromRequestParts<S> for OptionalStsCreds {
    type Rejection = (StatusCode, String);

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Self::Rejection> {
        Ok(OptionalStsCreds(StsCreds::from_headers(&parts.headers)))
    }
}

/// Choose between a per-request STS client and the fallback default client.
/// If `override_creds` is Some, mints a per-request client (per-actor IAM
/// scoping). If None, clones the default client (S3Client clone is cheap —
/// internally Arc-shared SdkConfig).
pub async fn s3_for_request(
    default: &S3Client,
    region: &str,
    override_creds: Option<&StsCreds>,
) -> S3Client {
    match override_creds {
        Some(c) => c.build_s3_client(region).await,
        None => default.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn missing_headers_returns_none() {
        let h = HeaderMap::new();
        assert!(StsCreds::from_headers(&h).is_none());
    }

    #[test]
    fn partial_headers_returns_none() {
        let mut h = HeaderMap::new();
        h.insert("x-aws-access-key-id", HeaderValue::from_static("AKIA..."));
        // missing secret + session token
        assert!(StsCreds::from_headers(&h).is_none());
    }

    #[test]
    fn all_three_headers_parse() {
        let mut h = HeaderMap::new();
        h.insert("x-aws-access-key-id", HeaderValue::from_static("AKIA..."));
        h.insert("x-aws-secret-access-key", HeaderValue::from_static("secret"));
        h.insert("x-aws-session-token", HeaderValue::from_static("token"));
        let c = StsCreds::from_headers(&h).unwrap();
        assert_eq!(c.access_key_id, "AKIA...");
        assert_eq!(c.secret_access_key, "secret");
        assert_eq!(c.session_token, "token");
    }

    #[test]
    fn empty_value_returns_none() {
        let mut h = HeaderMap::new();
        h.insert("x-aws-access-key-id", HeaderValue::from_static(""));
        h.insert("x-aws-secret-access-key", HeaderValue::from_static("s"));
        h.insert("x-aws-session-token", HeaderValue::from_static("t"));
        assert!(StsCreds::from_headers(&h).is_none());
    }
}
