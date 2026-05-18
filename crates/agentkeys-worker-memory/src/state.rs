//! Memory worker process state — mirrors credentials worker but with a
//! distinct bucket (`$MEMORY_BUCKET`) per arch.md §17 per-data-class
//! separation.

use std::sync::Arc;

use anyhow::{anyhow, Context};
use aws_sdk_s3::Client as S3Client;

#[derive(Debug, Clone)]
pub struct MemoryWorkerConfig {
    pub memory_bucket: String,
    pub region: String,
    pub broker_pubkey_pem: String,
    pub chain_rpc_http: String,
    pub registry_contract: String,
    pub scope_contract: String,
    pub epoch_contract: String,
    pub chain_profile: String,
    pub kek_hex_stage1: String,
}

impl MemoryWorkerConfig {
    pub fn from_env() -> anyhow::Result<Self> {
        let chain_profile =
            std::env::var("AGENTKEYS_CHAIN").unwrap_or_else(|_| "heima".to_string());
        let profile_uc = chain_profile.to_uppercase().replace('-', "_");

        let memory_bucket = std::env::var("MEMORY_BUCKET")
            .context("MEMORY_BUCKET must be set (per arch.md §17 distinct from VAULT_BUCKET)")?;
        let region = std::env::var("AWS_REGION")
            .or_else(|_| std::env::var("AWS_DEFAULT_REGION"))
            .unwrap_or_else(|_| "us-east-1".into());
        let broker_pubkey_pem = std::env::var("BROKER_CAP_PUBKEY_PEM")
            .context("BROKER_CAP_PUBKEY_PEM must be set")?;
        let chain_rpc_http = std::env::var("AGENTKEYS_CHAIN_RPC_HTTP")
            .or_else(|_| std::env::var(format!("CHAIN_RPC_HTTP_{profile_uc}")))
            .or_else(|_| std::env::var("HEIMA_RPC_HTTP"))
            .context("AGENTKEYS_CHAIN_RPC_HTTP must be set")?;
        let registry_contract = profile_env(&profile_uc, "SIDECAR_REGISTRY_ADDRESS")?;
        let scope_contract = profile_env(&profile_uc, "SCOPE_CONTRACT_ADDRESS")?;
        let epoch_contract = profile_env(&profile_uc, "K3_EPOCH_COUNTER_ADDRESS")?;
        let kek_hex_stage1 = std::env::var("AGENTKEYS_MEMORY_KEK_HEX")
            .context("AGENTKEYS_MEMORY_KEK_HEX must be set (32-byte hex; distinct from creds KEK per arch.md §17)")?;
        if kek_hex_stage1.len() != 64 {
            return Err(anyhow!(
                "AGENTKEYS_MEMORY_KEK_HEX must be 64 hex chars (32 bytes), got {}",
                kek_hex_stage1.len()
            ));
        }
        Ok(MemoryWorkerConfig {
            memory_bucket,
            region,
            broker_pubkey_pem,
            chain_rpc_http,
            registry_contract,
            scope_contract,
            epoch_contract,
            chain_profile,
            kek_hex_stage1,
        })
    }
}

fn profile_env(profile_uc: &str, base: &str) -> anyhow::Result<String> {
    let key = format!("{base}_{profile_uc}");
    std::env::var(&key).with_context(|| format!("{key} must be set"))
}

pub struct MemoryWorkerState {
    pub config: MemoryWorkerConfig,
    pub s3: S3Client,
    pub http: reqwest::Client,
}

pub type SharedMemoryWorkerState = Arc<MemoryWorkerState>;

impl MemoryWorkerState {
    pub async fn build(config: MemoryWorkerConfig) -> anyhow::Result<Self> {
        let sdk_config = aws_config::defaults(aws_config::BehaviorVersion::latest())
            .region(aws_config::Region::new(config.region.clone()))
            .load()
            .await;
        let s3 = S3Client::new(&sdk_config);
        Ok(MemoryWorkerState { config, s3, http: reqwest::Client::new() })
    }
}
