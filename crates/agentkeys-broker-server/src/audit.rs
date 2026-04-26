use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};

use crate::error::{BrokerError, BrokerResult};

pub struct AuditLog {
    conn: Mutex<Connection>,
}

#[derive(Debug, Clone)]
pub struct MintRecord<'a> {
    pub requester_token: &'a str,
    pub requester_wallet: &'a str,
    pub requested_role: &'a str,
    pub session_duration_seconds: i32,
    pub sts_session_name: &'a str,
    pub outcome: MintOutcome,
}

#[derive(Debug, Clone, Copy)]
pub enum MintOutcome {
    Ok,
    AuthFailed,
    StsError,
}

impl MintOutcome {
    fn as_str(self) -> &'static str {
        match self {
            MintOutcome::Ok => "ok",
            MintOutcome::AuthFailed => "auth_failed",
            MintOutcome::StsError => "sts_error",
        }
    }
}

impl AuditLog {
    pub fn open(path: &Path) -> BrokerResult<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| BrokerError::AuditError(format!("create audit dir: {}", e)))?;
        }
        let conn = Connection::open(path)
            .map_err(|e| BrokerError::AuditError(format!("open audit db: {}", e)))?;
        let log = Self { conn: Mutex::new(conn) };
        log.init_schema()?;
        Ok(log)
    }

    pub fn open_in_memory() -> BrokerResult<Self> {
        let conn = Connection::open_in_memory()
            .map_err(|e| BrokerError::AuditError(format!("open in-memory audit db: {}", e)))?;
        let log = Self { conn: Mutex::new(conn) };
        log.init_schema()?;
        Ok(log)
    }

    fn init_schema(&self) -> BrokerResult<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS mint_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                minted_at INTEGER NOT NULL,
                requester_token TEXT NOT NULL,
                requester_wallet TEXT NOT NULL,
                requested_role TEXT NOT NULL,
                session_duration_seconds INTEGER NOT NULL,
                sts_session_name TEXT NOT NULL,
                outcome TEXT NOT NULL,
                outcome_detail TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_mint_log_minted_at ON mint_log(minted_at);
            CREATE INDEX IF NOT EXISTS idx_mint_log_wallet ON mint_log(requester_wallet);",
        )
        .map_err(|e| BrokerError::AuditError(format!("init schema: {}", e)))?;
        Ok(())
    }

    pub fn record_mint(&self, record: MintRecord<'_>, detail: Option<&str>) -> BrokerResult<()> {
        let conn = self.conn.lock().unwrap();
        let token_hash = hash_token(record.requester_token);
        let now = now_secs();
        conn.execute(
            "INSERT INTO mint_log
             (minted_at, requester_token, requester_wallet, requested_role,
              session_duration_seconds, sts_session_name, outcome, outcome_detail)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                now as i64,
                token_hash,
                record.requester_wallet,
                record.requested_role,
                record.session_duration_seconds,
                record.sts_session_name,
                record.outcome.as_str(),
                detail,
            ],
        )
        .map_err(|e| BrokerError::AuditError(format!("insert mint: {}", e)))?;
        Ok(())
    }

    pub fn count(&self) -> BrokerResult<i64> {
        let conn = self.conn.lock().unwrap();
        let n: i64 = conn
            .query_row("SELECT COUNT(*) FROM mint_log", [], |row| row.get(0))
            .map_err(|e| BrokerError::AuditError(format!("count: {}", e)))?;
        Ok(n)
    }
}

fn hash_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}
