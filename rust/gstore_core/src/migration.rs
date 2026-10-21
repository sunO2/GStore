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

/// Domains that, once written by the Rust core, block legacy Dart writes.
pub const CORE_WRITES_DOMAINS: [&str; 3] = ["channel", "update", "download"];

/// Marker recording the first core write for a domain.
#[derive(Debug, Clone, PartialEq)]
pub struct CoreWriteMarker {
    pub domain: String,
    pub first_write_at: i64,
    pub snapshot_id: Option<String>,
}

/// Records the first core write for `domain` and returns its timestamp.
///
/// Idempotent: a later call keeps the original `first_write_at` and
/// `snapshot_id` (first write wins).
pub fn mark_core_write(
    conn: &rusqlite::Connection,
    domain: &str,
    snapshot_id: Option<&str>,
) -> Result<i64, DbError> {
    conn.execute(
        "INSERT OR IGNORE INTO core_writes(domain, first_write_at, snapshot_id) \
         VALUES (?1, strftime('%s','now'), ?2)",
        rusqlite::params![domain, snapshot_id],
    )
    .map_err(|e| DbError(format!("mark core write {domain}: {e}")))?;
    conn.query_row(
        "SELECT first_write_at FROM core_writes WHERE domain=?1",
        [domain],
        |row| row.get(0),
    )
    .map_err(|e| DbError(format!("read first_write_at {domain}: {e}")))
}

/// Returns the write marker for `domain`, if the core has written it.
pub fn core_write_marker(
    conn: &rusqlite::Connection,
    domain: &str,
) -> Result<Option<CoreWriteMarker>, DbError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT domain, first_write_at, snapshot_id FROM core_writes WHERE domain=?1",
        [domain],
        |row| {
            Ok(CoreWriteMarker {
                domain: row.get(0)?,
                first_write_at: row.get(1)?,
                snapshot_id: row.get(2)?,
            })
        },
    )
    .optional()
    .map_err(|e| DbError(format!("read core write marker {domain}: {e}")))
}

/// Fail-closed rule: legacy Dart writes are only allowed before the core marks
/// `domain` as written.
pub fn ensure_legacy_write_allowed(
    conn: &rusqlite::Connection,
    domain: &str,
) -> Result<(), DbError> {
    if core_write_marker(conn, domain)?.is_some() {
        return Err(DbError(format!("CORE_E_WRITE_BLOCKED: {domain}")));
    }
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
    fn core_writes_guard() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        apply_core_schema(&conn).unwrap();

        ensure_legacy_write_allowed(&conn, "channel").expect("unmarked domain is writable");

        let t1 = mark_core_write(&conn, "channel", None).unwrap();
        let t2 = mark_core_write(&conn, "channel", Some("snap-1")).unwrap();
        assert_eq!(t1, t2, "first_write_at must not move");
        assert!(t1 > 0, "first_write_at must be a real timestamp, got {t1}");

        let marker = core_write_marker(&conn, "channel")
            .unwrap()
            .expect("channel marker must exist");
        assert_eq!(marker.domain, "channel");
        assert_eq!(marker.first_write_at, t1);
        assert_eq!(marker.snapshot_id, None, "first write wins for snapshot_id");

        let blocked = ensure_legacy_write_allowed(&conn, "channel")
            .expect_err("marked domain must block legacy writes");
        println!("legacy write blocked: {}", blocked.0);
        assert!(
            blocked.0.contains("CORE_E_WRITE_BLOCKED: channel"),
            "unexpected error: {}",
            blocked.0
        );

        ensure_legacy_write_allowed(&conn, "update").expect("other domains stay writable");
    }

    #[test]
    fn migration_dir_is_under_files_dir() {
        let files_dir = Path::new("/tmp/files");
        let dir = migration_dir(files_dir);
        assert!(dir.starts_with(files_dir));
        assert_eq!(dir.file_name().and_then(|n| n.to_str()), Some(MIGRATION_DIR));
    }
}