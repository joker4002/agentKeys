use ed25519_dalek::{SigningKey, VerifyingKey};
use jsonwebtoken::DecodingKey;
use rusqlite::Connection;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::dev_key_service::DevKeyService;

pub const DEFAULT_READ_RATE_LIMIT_PER_MINUTE: u32 = 100;
pub const MAX_READ_RATE_LIMIT_PER_MINUTE: u32 = 10_000;

#[derive(Debug, Clone)]
pub struct TokenBucket {
    capacity: u32,
    tokens: f64,
    last_refill: Instant,
    window_started: Instant,
    attempts_in_window: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RateLimitRejection {
    pub retry_after_secs: u64,
    pub attempted_rate: u32,
}

impl TokenBucket {
    pub fn new(rate_limit_per_minute: u32) -> Self {
        let now = Instant::now();
        Self {
            capacity: rate_limit_per_minute,
            tokens: rate_limit_per_minute as f64,
            last_refill: now,
            window_started: now,
            attempts_in_window: 0,
        }
    }

    pub fn consume(&mut self) -> Result<u32, RateLimitRejection> {
        self.refill();
        let now = Instant::now();
        if now.duration_since(self.window_started).as_secs() >= 60 {
            self.window_started = now;
            self.attempts_in_window = 0;
        }
        self.attempts_in_window = self.attempts_in_window.saturating_add(1);

        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            Ok(self.attempts_in_window)
        } else {
            let per_second = self.capacity as f64 / 60.0;
            let retry_after_secs = if per_second <= 0.0 {
                60
            } else {
                ((1.0 - self.tokens) / per_second).ceil().max(1.0) as u64
            };
            Err(RateLimitRejection {
                retry_after_secs,
                attempted_rate: self.attempts_in_window,
            })
        }
    }

    fn refill(&mut self) {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_refill).as_secs_f64();
        if elapsed <= 0.0 {
            return;
        }
        let refill = elapsed * (self.capacity as f64 / 60.0);
        self.tokens = (self.tokens + refill).min(self.capacity as f64);
        self.last_refill = now;
    }
}

pub struct AppState {
    pub db: Mutex<Connection>,
    pub read_buckets: Mutex<HashMap<String, TokenBucket>>,
    pub shielding_signing_key: SigningKey,
    pub shielding_public_key: VerifyingKey,
    /// Dev signer for `/dev/derive-address` and `/dev/sign-message`.
    /// `None` when `DEV_KEY_SERVICE_MASTER_SECRET` is unset; the handlers
    /// then return 503 `signer_disabled` per `signer-protocol.md`.
    pub dev_signer: Option<DevKeyService>,
    /// Broker session keypair public key for JWT bearer verification on `/dev/*`.
    /// `None` in legacy mock-server mode (no auth on `/dev/*`).
    /// When set (signer-only mode), every `/dev/*` request MUST carry a valid
    /// session JWT signed by the broker.
    pub broker_session_pubkey: Option<DecodingKey>,
}

impl AppState {
    pub fn new(conn: Connection) -> Self {
        let mut rng = rand::thread_rng();
        let signing_key = SigningKey::generate(&mut rng);
        let verifying_key = signing_key.verifying_key();
        Self {
            db: Mutex::new(conn),
            read_buckets: Mutex::new(HashMap::new()),
            shielding_signing_key: signing_key,
            shielding_public_key: verifying_key,
            dev_signer: None,
            broker_session_pubkey: None,
        }
    }

    /// Builder: attach a dev signer (or leave it `None` to keep the `/dev/*`
    /// endpoints disabled).
    pub fn with_dev_signer(mut self, signer: Option<DevKeyService>) -> Self {
        self.dev_signer = signer;
        self
    }

    /// Builder: attach the broker session pubkey for JWT bearer verification.
    /// When set, every `/dev/*` request must carry a valid session JWT.
    /// When `None` (default), JWT verification is skipped (legacy/test mode).
    pub fn with_broker_session_pubkey(mut self, key: Option<DecodingKey>) -> Self {
        self.broker_session_pubkey = key;
        self
    }
}

pub type SharedState = Arc<AppState>;
