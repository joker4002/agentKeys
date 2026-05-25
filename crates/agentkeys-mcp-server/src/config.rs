//! Runtime configuration.
//!
//! Pulled from CLI flags + env vars; never from the workspace. The config is
//! built once at startup, cloned into every request handler via shared state,
//! and treated as immutable from then on.

use clap::Parser;
use std::collections::HashMap;
use std::net::SocketAddr;

#[derive(Parser, Debug, Clone)]
#[command(
    name = "agentkeys-mcp-server",
    about = "AgentKeys MCP server — Phase 1 (issue #107)"
)]
pub struct Cli {
    /// Transport mode: `http` (default, for vendor deploys) or `stdio`
    /// (for local MCP hosts that spawn this as a subprocess).
    #[arg(long, env = "MCP_TRANSPORT", default_value = "http")]
    pub transport: String,

    /// HTTP bind address.
    #[arg(long, env = "MCP_LISTEN", default_value = "0.0.0.0:8088")]
    pub listen: SocketAddr,

    /// Broker base URL (e.g. `https://broker.litentry.org`).
    #[arg(long, env = "AGENTKEYS_BROKER_URL")]
    pub broker_url: Option<String>,

    /// Memory worker base URL.
    #[arg(long, env = "AGENTKEYS_MEMORY_URL")]
    pub memory_url: Option<String>,

    /// Audit worker base URL.
    #[arg(long, env = "AGENTKEYS_AUDIT_URL")]
    pub audit_url: Option<String>,

    /// Comma-separated `<vendor_id>:<bearer_token>` pairs that the HTTP
    /// transport will accept. Empty = HTTP refuses every request with 401.
    /// Format intentionally simple — vendor onboarding portal in M2 will
    /// replace this with a persisted issuance store.
    #[arg(long, env = "MCP_VENDOR_TOKENS", default_value = "")]
    pub vendor_tokens: String,

    /// Daily spend cap (in RMB units) used by the deterministic policy
    /// engine for `permission.check(scope="payment.spend")`. Per the
    /// three-act demo storyboard in `agent-iam-strategy.md` §4.3.
    #[arg(long, env = "MCP_DEFAULT_DAILY_SPEND_CAP_RMB", default_value_t = 500)]
    pub default_daily_spend_cap_rmb: u64,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub transport: Transport,
    pub listen: SocketAddr,
    pub broker_url: Option<String>,
    pub memory_url: Option<String>,
    pub audit_url: Option<String>,
    /// vendor_id → bearer_token
    pub vendor_tokens: HashMap<String, String>,
    pub default_daily_spend_cap_rmb: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Http,
    Stdio,
}

impl Config {
    pub fn from_cli(cli: Cli) -> anyhow::Result<Self> {
        let transport = match cli.transport.as_str() {
            "http" => Transport::Http,
            "stdio" => Transport::Stdio,
            other => anyhow::bail!("unknown transport `{other}` (expected http|stdio)"),
        };

        let mut vendor_tokens = HashMap::new();
        for pair in cli.vendor_tokens.split(',').filter(|s| !s.trim().is_empty()) {
            let (vendor, token) = pair
                .split_once(':')
                .ok_or_else(|| anyhow::anyhow!("malformed vendor_token entry: {pair}"))?;
            vendor_tokens.insert(vendor.trim().to_string(), token.trim().to_string());
        }

        Ok(Self {
            transport,
            listen: cli.listen,
            broker_url: cli.broker_url,
            memory_url: cli.memory_url,
            audit_url: cli.audit_url,
            vendor_tokens,
            default_daily_spend_cap_rmb: cli.default_daily_spend_cap_rmb,
        })
    }

    /// Convenience builder for tests — no parsing, no env reads.
    pub fn for_tests() -> Self {
        Self {
            transport: Transport::Http,
            listen: "127.0.0.1:0".parse().unwrap(),
            broker_url: None,
            memory_url: None,
            audit_url: None,
            vendor_tokens: HashMap::new(),
            default_daily_spend_cap_rmb: 500,
        }
    }

    pub fn with_vendor_token(mut self, vendor: &str, token: &str) -> Self {
        self.vendor_tokens
            .insert(vendor.to_string(), token.to_string());
        self
    }
}
