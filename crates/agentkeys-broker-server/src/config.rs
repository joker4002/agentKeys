use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct BrokerConfig {
    pub daemon_access_key_id: String,
    pub daemon_secret_access_key: String,
    pub agent_role_arn: String,
    pub backend_url: String,
    pub audit_db_path: PathBuf,
    pub aws_region: String,
    pub session_duration_seconds: i32,
}

impl BrokerConfig {
    pub fn from_env() -> anyhow::Result<Self> {
        let daemon_access_key_id = required_env("BROKER_DAEMON_ACCESS_KEY_ID")?;
        let daemon_secret_access_key = required_env("BROKER_DAEMON_SECRET_ACCESS_KEY")?;
        let agent_role_arn = required_env("BROKER_AGENT_ROLE_ARN")?;
        let backend_url = required_env("BROKER_BACKEND_URL")?;
        let audit_db_path = std::env::var("BROKER_AUDIT_DB_PATH")
            .ok()
            .map(PathBuf::from)
            .unwrap_or_else(default_audit_db_path);
        let aws_region = std::env::var("BROKER_AWS_REGION")
            .unwrap_or_else(|_| "us-east-1".to_string());
        let session_duration_seconds = std::env::var("BROKER_SESSION_DURATION_SECONDS")
            .ok()
            .and_then(|s| s.parse::<i32>().ok())
            .unwrap_or(3600);

        if !(900..=43_200).contains(&session_duration_seconds) {
            anyhow::bail!(
                "BROKER_SESSION_DURATION_SECONDS must be between 900 and 43200, got {}",
                session_duration_seconds
            );
        }

        Ok(Self {
            daemon_access_key_id,
            daemon_secret_access_key,
            agent_role_arn,
            backend_url,
            audit_db_path,
            aws_region,
            session_duration_seconds,
        })
    }
}

fn required_env(name: &str) -> anyhow::Result<String> {
    std::env::var(name).map_err(|_| anyhow::anyhow!("missing required env var: {}", name))
}

fn default_audit_db_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".agentkeys").join("broker").join("audit.sqlite")
}
