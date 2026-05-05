//! `SqliteAnchor` — local-SQLite implementation of `AuditAnchor`.
//!
//! Phase 0 default. Ports the schema and WAL+FULL pragma from the existing
//! `crate::audit::AuditLog` (which is left in place for backwards compat
//! while US-011 migrates the mint handler to this trait), but speaks the
//! `AuditRecord` / `AnchorReceipt` shape from `plugins/audit.rs`.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use async_trait::async_trait;
use rusqlite::{params, Connection};
use serde_json::json;

use crate::plugins::audit::{AnchorReceipt, AuditAnchor, AuditError, AuditRecord};
use crate::plugins::Readiness;

const ANCHOR_NAME: &str = "sqlite";

/// SQLite-backed audit anchor. Single-file, single-process, single-threaded
/// writes via `Mutex<Connection>`. WAL+FULL means power loss loses at most
/// the in-flight transaction.
pub struct SqliteAnchor {
    conn: Mutex<Connection>,
    /// Stored for diagnostics + the `Readiness` writability probe.
    db_path: PathBuf,
}

impl SqliteAnchor {
    /// Open (or create) the SQLite DB at `path`. Idempotent — re-opening
    /// an existing DB is a no-op on schema (CREATE TABLE IF NOT EXISTS).
    ///
    /// On any I/O or schema error returns `AuditError::Storage` so the
    /// boot path can refuse-to-boot per plan §6 Tier-1.
    pub fn open(path: &Path) -> Result<Self, AuditError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| AuditError::Storage(format!("create audit dir {:?}: {}", parent, e)))?;
        }
        let conn = Connection::open(path)
            .map_err(|e| AuditError::Storage(format!("open audit db {:?}: {}", path, e)))?;
        let anchor = Self {
            conn: Mutex::new(conn),
            db_path: path.to_path_buf(),
        };
        anchor.init_schema()?;
        Ok(anchor)
    }

    /// Open in memory. Used by tests.
    pub fn open_in_memory() -> Result<Self, AuditError> {
        let conn = Connection::open_in_memory()
            .map_err(|e| AuditError::Storage(format!("open in-memory audit db: {}", e)))?;
        let anchor = Self {
            conn: Mutex::new(conn),
            db_path: PathBuf::from(":memory:"),
        };
        anchor.init_schema()?;
        Ok(anchor)
    }

    fn lock(&self) -> Result<MutexGuard<'_, Connection>, AuditError> {
        self.conn
            .lock()
            .map_err(|e| AuditError::Storage(format!("audit mutex poisoned: {}", e)))
    }

    fn init_schema(&self) -> Result<(), AuditError> {
        let conn = self.lock()?;
        // Per plan §3.5.5 + §Phase C: three-state lifecycle is enforced
        // here so Phase C's EVM anchor lands cleanly. Phase 0 only writes
        // `'confirmed'` directly; reconciliation lifecycle (`pending`,
        // `quarantined`) ships in Phase C.
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             CREATE TABLE IF NOT EXISTS plugin_mint_log (
                id TEXT PRIMARY KEY,
                minted_at INTEGER NOT NULL,
                record_hash TEXT NOT NULL,
                omni_account TEXT NOT NULL,
                wallet TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                service TEXT NOT NULL,
                grant_id TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'confirmed',
                outcome TEXT NOT NULL,
                outcome_detail TEXT
             );
             CREATE INDEX IF NOT EXISTS idx_plugin_mint_log_minted_at ON plugin_mint_log(minted_at);
             CREATE INDEX IF NOT EXISTS idx_plugin_mint_log_omni_account ON plugin_mint_log(omni_account);
             CREATE INDEX IF NOT EXISTS idx_plugin_mint_log_record_hash ON plugin_mint_log(record_hash);
             CREATE INDEX IF NOT EXISTS idx_plugin_mint_log_status ON plugin_mint_log(status);",
        )
        .map_err(|e| AuditError::Storage(format!("init plugin_mint_log schema: {}", e)))?;
        Ok(())
    }

    /// Quick writability probe used by `ready()`.
    fn writable(&self) -> bool {
        let Ok(conn) = self.conn.lock() else {
            return false;
        };
        conn.execute(
            "CREATE TABLE IF NOT EXISTS _readyz_probe (id INTEGER PRIMARY KEY)",
            [],
        )
        .is_ok()
    }
}

#[async_trait]
impl AuditAnchor for SqliteAnchor {
    fn name(&self) -> &'static str {
        ANCHOR_NAME
    }

    fn ready(&self) -> Readiness {
        if self.writable() {
            Readiness::ready_with(format!("sqlite: {}", self.db_path.display()))
        } else {
            Readiness::unready(format!(
                "sqlite at {} is not writable",
                self.db_path.display()
            ))
        }
    }

    async fn anchor(&self, record: &AuditRecord) -> Result<AnchorReceipt, AuditError> {
        let conn = self.lock()?;
        // Phase 0: insert directly as 'confirmed'. Phase C will introduce
        // the pending → confirmed | quarantined lifecycle for dual-anchor.
        conn.execute(
            "INSERT INTO plugin_mint_log
             (id, minted_at, record_hash, omni_account, wallet, agent_id,
              service, grant_id, status, outcome, outcome_detail)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'confirmed', ?9, ?10)",
            params![
                &record.id,
                record.minted_at,
                &record.record_hash,
                &record.omni_account,
                &record.wallet,
                &record.agent_id,
                &record.service,
                &record.grant_id,
                &record.outcome,
                record.outcome_detail.as_deref(),
            ],
        )
        .map_err(|e| AuditError::Storage(format!("insert plugin_mint_log: {}", e)))?;

        Ok(AnchorReceipt {
            anchor: ANCHOR_NAME.to_string(),
            receipt: json!({ "row_id": record.id }),
            anchored_at: record.minted_at,
        })
    }

    async fn verify(
        &self,
        record: &AuditRecord,
        receipt: &AnchorReceipt,
    ) -> Result<bool, AuditError> {
        if receipt.anchor != ANCHOR_NAME {
            return Err(AuditError::VerificationMismatch(format!(
                "receipt is for anchor {} not {}",
                receipt.anchor, ANCHOR_NAME
            )));
        }
        let conn = self.lock()?;
        let row_hash: Option<String> = conn
            .query_row(
                "SELECT record_hash FROM plugin_mint_log WHERE id = ?1",
                params![&record.id],
                |row| row.get(0),
            )
            .ok();
        match row_hash {
            None => Err(AuditError::NotFound),
            Some(stored) if stored == record.record_hash => Ok(true),
            Some(_) => Err(AuditError::VerificationMismatch(format!(
                "stored record_hash for {} does not match",
                record.id
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(id: &str, hash: &str) -> AuditRecord {
        AuditRecord {
            id: id.into(),
            minted_at: 1_700_000_000,
            record_hash: hash.into(),
            omni_account: "0x7f".repeat(2),
            wallet: "0xabc".repeat(2),
            agent_id: "0xabc".repeat(2),
            service: "s3".into(),
            grant_id: String::new(),
            outcome: "ok".into(),
            outcome_detail: None,
        }
    }

    #[tokio::test]
    async fn anchor_then_verify_round_trip() {
        let a = SqliteAnchor::open_in_memory().unwrap();
        let r = record("01HZA", "deadbeef");
        let receipt = a.anchor(&r).await.unwrap();
        assert_eq!(receipt.anchor, "sqlite");
        let ok = a.verify(&r, &receipt).await.unwrap();
        assert!(ok);
    }

    #[tokio::test]
    async fn verify_returns_not_found_for_unknown_id() {
        let a = SqliteAnchor::open_in_memory().unwrap();
        let unknown = record("01HZUNKNOWN", "deadbeef");
        let receipt = AnchorReceipt {
            anchor: "sqlite".into(),
            receipt: json!({ "row_id": "01HZUNKNOWN" }),
            anchored_at: 0,
        };
        assert!(matches!(
            a.verify(&unknown, &receipt).await,
            Err(AuditError::NotFound)
        ));
    }

    #[tokio::test]
    async fn verify_detects_record_hash_tampering() {
        let a = SqliteAnchor::open_in_memory().unwrap();
        let r = record("01HZB", "originalhash");
        let receipt = a.anchor(&r).await.unwrap();
        // Caller hands us a tampered AuditRecord with the same id but
        // a different record_hash — must detect.
        let tampered = AuditRecord {
            record_hash: "tamperedhash".into(),
            ..r
        };
        assert!(matches!(
            a.verify(&tampered, &receipt).await,
            Err(AuditError::VerificationMismatch(_))
        ));
    }

    #[tokio::test]
    async fn verify_rejects_receipt_from_wrong_anchor() {
        let a = SqliteAnchor::open_in_memory().unwrap();
        let r = record("01HZC", "deadbeef");
        a.anchor(&r).await.unwrap();
        let evm_receipt = AnchorReceipt {
            anchor: "evm_testnet".into(),
            receipt: json!({ "tx_hash": "0xabc" }),
            anchored_at: 0,
        };
        assert!(matches!(
            a.verify(&r, &evm_receipt).await,
            Err(AuditError::VerificationMismatch(_))
        ));
    }

    #[tokio::test]
    async fn ready_reports_ready_for_open_db() {
        let a = SqliteAnchor::open_in_memory().unwrap();
        assert!(a.ready().is_ready());
    }

    #[tokio::test]
    async fn name_is_stable() {
        let a = SqliteAnchor::open_in_memory().unwrap();
        assert_eq!(a.name(), "sqlite");
    }
}
