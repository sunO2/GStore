//! SQLite storage for gstore_core.

use std::path::{Path, PathBuf};
use std::time::Duration;

use rusqlite::Connection;

use crate::migration;

/// Shared, mutex-guarded SQLite connection used by the core ports.
pub type SharedConn = std::sync::Arc<std::sync::Mutex<rusqlite::Connection>>;

/// Error type for core database operations.
#[derive(Debug)]
pub struct DbError(pub String);

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DbError {}

/// Default file name of the core database file.
pub const CORE_DB_FILE: &str = "gstore_core.db";

/// Full path of the core database file inside `data_dir`.
pub fn core_db_path(data_dir: &Path) -> PathBuf {
    data_dir.join(CORE_DB_FILE)
}

/// Opens (or creates) the core database and applies the schema.
pub fn open(data_dir: &Path) -> Result<Connection, DbError> {
    std::fs::create_dir_all(data_dir)
        .map_err(|e| DbError(format!("create data dir {}: {e}", data_dir.display())))?;
    let path = core_db_path(data_dir);
    let conn = Connection::open(&path).map_err(|e| DbError(format!("open {}: {e}", path.display())))?;
    conn.pragma_update(None, "journal_mode", "WAL")
        .map_err(|e| DbError(format!("set journal_mode=WAL: {e}")))?;
    conn.pragma_update(None, "synchronous", "NORMAL")
        .map_err(|e| DbError(format!("set synchronous=NORMAL: {e}")))?;
    conn.busy_timeout(Duration::from_millis(5000))
        .map_err(|e| DbError(format!("set busy_timeout: {e}")))?;
    conn.pragma_update(None, "foreign_keys", "ON")
        .map_err(|e| DbError(format!("set foreign_keys=ON: {e}")))?;
    migration::apply_core_schema(&conn)?;
    Ok(conn)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cargo_db_open_sets_wal_and_schema() {
        let dir = std::env::temp_dir().join(format!("gstore_core_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let conn = open(&dir).unwrap();

        let journal_mode: String =
            conn.pragma_query_value(None, "journal_mode", |r| r.get(0)).unwrap();
        assert_eq!(journal_mode.to_lowercase(), "wal");

        let version: i32 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(version, 1);

        let tables: Vec<String> = {
            let mut stmt = conn
                .prepare(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('core_writes', 'download_task')",
                )
                .unwrap();
            stmt.query_map([], |r| r.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        assert_eq!(tables.len(), 2, "expected core_writes and download_task, got {tables:?}");
        assert!(tables.contains(&"core_writes".to_string()));
        assert!(tables.contains(&"download_task".to_string()));

        drop(conn);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}