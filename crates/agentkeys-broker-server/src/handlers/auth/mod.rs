//! Stage 7 auth endpoints (plan §3.5).
//!
//! - `POST /v1/auth/wallet/start` — SIWE challenge.
//! - `POST /v1/auth/wallet/verify` — SIWE verify → session JWT.
//! - `POST /v1/auth/exchange` — backward-compat shim that exchanges a
//!   legacy backend-validated bearer for a new session JWT.

pub mod exchange;
pub mod wallet_start;
pub mod wallet_verify;

pub(super) use wallet_start::map_auth_err as wallet_start_map_auth_err;
