//! Core schema migration helpers.

use std::path::{Path, PathBuf};

use crate::db::DbError;

/// Directory name, under the app files dir, where Dart-side migration payloads land.
pub const MIGRATION_DIR: &str = "migration";

/// Absolute migration directory under `files_dir`.
pub fn migration_dir(files_dir: &Path) -> PathBuf {
    files_dir.join(MIGRATION_DIR)
}

/// Schema version stamped into `PRAGMA user_version` by [`apply_core_schema`].
pub const CORE_SCHEMA_VERSION: i32 = 1;

/// Applies the core schema idempotently and stamps the schema version.
pub fn apply_core_schema(conn: &rusqlite::Connection) -> Result<(), DbError> {
    conn.execute_batch(&format!(
        "CREATE TABLE IF NOT EXISTS core_writes(
            domain TEXT PRIMARY KEY,
            first_write_at INTEGER NOT NULL,
            snapshot_id TEXT
        );
        CREATE TABLE IF NOT EXISTS download_task(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            module_task_id TEXT UNIQUE,
            dedup_key TEXT UNIQUE,
            app_id TEXT,
            app_name TEXT,
            version TEXT,
            file_name TEXT,
            kind TEXT,
            resource_id TEXT,
            resource_version TEXT,
            url TEXT,
            dest_path TEXT,
            status TEXT NOT NULL DEFAULT '',
            bytes_done INTEGER NOT NULL DEFAULT 0,
            total INTEGER NOT NULL DEFAULT 0,
            speed_bps INTEGER NOT NULL DEFAULT 0,
            eta_sec INTEGER,
            segments_json TEXT,
            retries INTEGER NOT NULL DEFAULT 0,
            server_meta TEXT,
            priority INTEGER NOT NULL DEFAULT 0,
            headers_json TEXT,
            expected_sha256 TEXT,
            install_after_download INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            last_started_at INTEGER,
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        PRAGMA user_version = {CORE_SCHEMA_VERSION};"
    ))
    .map_err(|e| DbError(format!("apply core schema: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn download_task_ddl_has_reconcile_columns() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        apply_core_schema(&conn).unwrap();
        let mut stmt = conn.prepare("PRAGMA table_info(download_task)").unwrap();
        let columns: Vec<String> = stmt
            .query_map([], |r| r.get(1))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        for name in ["module_task_id", "dedup_key", "status", "last_started_at"] {
            assert!(columns.iter().any(|c| c == name), "missing column {name}");
        }
    }

    #[test]
    fn apply_core_schema_is_idempotent() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        apply_core_schema(&conn).unwrap();
        apply_core_schema(&conn).unwrap();
        let version: i32 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(version, CORE_SCHEMA_VERSION);
    }

    #[test]
    fn migration_dir_is_under_files_dir() {
        let files_dir = Path::new("/tmp/files");
        let dir = migration_dir(files_dir);
        assert!(dir.starts_with(files_dir));
        assert_eq!(dir.file_name().and_then(|n| n.to_str()), Some(MIGRATION_DIR));
    }
}