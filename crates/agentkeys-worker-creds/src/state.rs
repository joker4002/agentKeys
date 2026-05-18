//! Worker process state — environment-driven config + shared S3 client.

use std::sync::Arc;

use anyhow::{anyhow, Context};
use aws_sdk_s3::Client as S3Client;

#[derive(Debug, Clone)]
pub struct WorkerConfig {
    pub vault_bucket: String,
    pub region: String,
    pub broker_pubkey_pem: String,
    pub chain_rpc_http: String,
    pub scope_contract: String,
    pub kek_hex_stage1: String,
}

impl WorkerConfig {
    pub fn from_env() -> anyhow::Result<Self> {
        let vault_bucket = std::env::var("VAULT_BUCKET")
            .context("VAULT_BUCKET must be set")?;
        let region = std::env::var("AWS_REGION")
            .or_else(|_| std::env::var("AWS_DEFAULT_REGION"))
            .unwrap_or_else(|_| "us-east-1".into());
        let broker_pubkey_pem = std::env::var("BROKER_CAP_PUBKEY_PEM")
            .context("BROKER_CAP_PUBKEY_PEM must be set (P-256 SubjectPublicKeyInfo PEM)")?;
        let chain_rpc_http = std::env::var("AGENTKEYS_CHAIN_RPC_HTTP")
            .or_else(|_| std::env::var("HEIMA_RPC_HTTP"))
            .context("AGENTKEYS_CHAIN_RPC_HTTP must be set")?;
        let scope_contract = std::env::var("SCOPE_CONTRACT_ADDRESS_HEIMA")
            .context("SCOPE_CONTRACT_ADDRESS_HEIMA must be set")?;
        let kek_hex_stage1 = std::env::var("AGENTKEYS_WORKER_KEK_HEX")
            .context("AGENTKEYS_WORKER_KEK_HEX must be set (32-byte hex). Stage 2 replaces this with mTLS-derived KEK")?;
        if kek_hex_stage1.len() != 64 {
            return Err(anyhow!(
                "AGENTKEYS_WORKER_KEK_HEX must be 64 hex chars (32 bytes), got {}",
                kek_hex_stage1.len()
            ));
        }
        Ok(WorkerConfig {
            vault_bucket,
            region,
            broker_pubkey_pem,
            chain_rpc_http,
            scope_contract,
            kek_hex_stage1,
        })
    }
}

pub struct WorkerState {
    pub config: WorkerConfig,
    pub s3: S3Client,
    pub http: reqwest::Client,
}

pub type SharedWorkerState = Arc<WorkerState>;

impl WorkerState {
    pub async fn build(config: WorkerConfig) -> anyhow::Result<Self> {
        let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(aws_config::Region::new(config.region.clone()))
            .load()
            .await;
        let s3 = S3Client::new(&sdk_config);
        Ok(WorkerState {
            config,
            s3,
            http: reqwest::Client::new(),
        })
    }
}
