//! Core schema migration helpers.

use std::path::{Path, PathBuf};

use crate::db::DbError;

// Embedded refinery migrations; `V1__core_schema.sql` mirrors
// `docs/core-schema.sql` (without the ledger table, which refinery owns).
refinery::embed_migrations!("migrations");

/// Directory name, under the app files dir, where Dart-side migration payloads land.
pub const MIGRATION_DIR: &str = "migration";

/// Absolute migration directory under `files_dir`.
pub fn migration_dir(files_dir: &Path) -> PathBuf {
    files_dir.join(MIGRATION_DIR)
}

/// Schema version stamped into `PRAGMA user_version` by [`apply_core_schema`].
pub const CORE_SCHEMA_VERSION: i32 = 1;

/// Name of the refinery ledger table.
pub const MIGRATION_LEDGER_TABLE: &str = "schema_migrations";

/// Applies the embedded core migrations idempotently and stamps the schema
/// version.
///
/// Refinery records each applied migration in `schema_migrations`, so opening
/// an already-migrated database is a no-op. The SQL is also written with
/// `IF NOT EXISTS` so a database created by the pre-refinery spike is adopted
/// without being re-created.
pub fn apply_core_schema(conn: &mut rusqlite::Connection) -> Result<(), DbError> {
    migrations::runner()
        .set_migration_table_name(MIGRATION_LEDGER_TABLE)
        .run(conn)
        .map_err(|e| DbError(format!("apply core schema: {e}")))?;
    conn.pragma_update(None, "user_version", CORE_SCHEMA_VERSION)
        .map_err(|e| DbError(format!("stamp user_version: {e}")))?;
    Ok(())
}

/// Domains that, once written by the Rust core, block legacy Dart writes.
pub const CORE_WRITES_DOMAINS: [&str; 3] = ["channel", "update", "download"];

/// Maximum supported version of the Dart→Rust migration document format.
pub const MIGRATION_DOC_VERSION: i64 = 1;

/// Imports one Dart-produced migration document into the core schema.
///
/// Returns the number of rows written. `kind` selects the target table:
/// `"channel_env"` (a single upsert) or `"update_prefs"` (one upsert per key).
pub fn import_migration_document(
    conn: &rusqlite::Connection,
    kind: &str,
    doc: &serde_json::Value,
) -> Result<usize, DbError> {
    let version = doc.get("version").and_then(serde_json::Value::as_i64);
    if version != Some(MIGRATION_DOC_VERSION) {
        return Err(DbError(format!(
            "CORE_E_MIGRATION_VERSION: expected {MIGRATION_DOC_VERSION}, got {}",
            doc.get("version")
                .map_or_else(|| "missing".to_string(), ToString::to_string)
        )));
    }

    match kind {
        "channel_env" => import_channel_env(conn, doc),
        "update_prefs" => import_update_prefs(conn, doc),
        other => Err(DbError(format!(
            "CORE_E_MIGRATION_KIND: unknown migration kind {other}"
        ))),
    }
}

fn import_channel_env(
    conn: &rusqlite::Connection,
    doc: &serde_json::Value,
) -> Result<usize, DbError> {
    let channel_key = doc
        .get("channel_key")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            DbError("CORE_E_MIGRATION_SHAPE: channel_key must be a string".to_string())
        })?;
    let env = doc
        .get("env")
        .filter(|value| value.is_object())
        .ok_or_else(|| DbError("CORE_E_MIGRATION_SHAPE: env must be an object".to_string()))?;
    let env_json = serde_json::to_string(env)
        .map_err(|e| DbError(format!("CORE_E_MIGRATION_SHAPE: encode env: {e}")))?;
    conn.execute(
        "INSERT INTO channel_env(channel_key, env_json, imported_at) \
         VALUES (?1, ?2, strftime('%s','now')) \
         ON CONFLICT(channel_key) DO UPDATE SET \
             env_json = excluded.env_json, imported_at = excluded.imported_at",
        rusqlite::params![channel_key, env_json],
    )
    .map_err(|e| {
        DbError(format!(
            "CORE_E_MIGRATION_WRITE: channel_env {channel_key}: {e}"
        ))
    })?;
    Ok(1)
}

fn import_update_prefs(
    conn: &rusqlite::Connection,
    doc: &serde_json::Value,
) -> Result<usize, DbError> {
    let prefs = doc
        .get("prefs")
        .filter(|value| value.is_object())
        .ok_or_else(|| DbError("CORE_E_MIGRATION_SHAPE: prefs must be an object".to_string()))?;
    let prefs = prefs
        .as_object()
        .ok_or_else(|| DbError("CORE_E_MIGRATION_SHAPE: prefs must be an object".to_string()))?;
    let mut written = 0usize;
    for (key, value) in prefs {
        let text = match value {
            serde_json::Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        conn.execute(
            "INSERT INTO update_prefs(key, value, imported_at) \
             VALUES (?1, ?2, strftime('%s','now')) \
             ON CONFLICT(key) DO UPDATE SET \
                 value = excluded.value, imported_at = excluded.imported_at",
            rusqlite::params![key, text],
        )
        .map_err(|e| DbError(format!("CORE_E_MIGRATION_WRITE: update_prefs {key}: {e}")))?;
        written += 1;
    }
    Ok(written)
}

/// Reads a migration document from `path` and imports it.
pub fn import_migration_file(
    conn: &rusqlite::Connection,
    kind: &str,
    path: &Path,
) -> Result<usize, DbError> {
    let raw = std::fs::read_to_string(path).map_err(|e| {
        DbError(format!(
            "CORE_E_MIGRATION_READ: read {}: {e}",
            path.display()
        ))
    })?;
    let doc: serde_json::Value = serde_json::from_str(&raw).map_err(|e| {
        DbError(format!(
            "CORE_E_MIGRATION_JSON: parse {}: {e}",
            path.display()
        ))
    })?;
    import_migration_document(conn, kind, &doc)
}

/// Returns how many `channel_env` rows exist for `channel_key`.
pub fn channel_env_count(conn: &rusqlite::Connection, channel_key: &str) -> Result<i64, DbError> {
    conn.query_row(
        "SELECT COUNT(*) FROM channel_env WHERE channel_key=?1",
        [channel_key],
        |row| row.get(0),
    )
    .map_err(|e| DbError(format!("read channel_env count {channel_key}: {e}")))
}

/// Returns the stored `update_prefs` value for `key`, if present.
pub fn update_pref(conn: &rusqlite::Connection, key: &str) -> Result<Option<String>, DbError> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT value FROM update_prefs WHERE key=?1",
        [key],
        |row| row.get(0),
    )
    .optional()
    .map_err(|e| DbError(format!("read update_pref {key}: {e}")))
}

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
        let mut conn = rusqlite::Connection::open_in_memory().unwrap();
        apply_core_schema(&mut conn).unwrap();
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
        let mut conn = rusqlite::Connection::open_in_memory().unwrap();
        apply_core_schema(&mut conn).unwrap();
        apply_core_schema(&mut conn).unwrap();
        let version: i32 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(version, CORE_SCHEMA_VERSION);
    }

    #[test]
    fn core_writes_guard() {
        let mut conn = rusqlite::Connection::open_in_memory().unwrap();
        apply_core_schema(&mut conn).unwrap();

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
    fn migration_handoff_roundtrip() {
        let mut conn = rusqlite::Connection::open_in_memory().unwrap();
        apply_core_schema(&mut conn).unwrap();

        let channel = serde_json::json!({
            "version": 1,
            "channel_key": "js.test",
            "env": {"user": "u", "pass": "p"}
        });
        assert_eq!(
            import_migration_document(&conn, "channel_env", &channel).unwrap(),
            1
        );
        assert_eq!(channel_env_count(&conn, "js.test").unwrap(), 1);

        let channel_update = serde_json::json!({
            "version": 1,
            "channel_key": "js.test",
            "env": {"user": "u2"}
        });
        assert_eq!(
            import_migration_document(&conn, "channel_env", &channel_update).unwrap(),
            1
        );
        assert_eq!(
            channel_env_count(&conn, "js.test").unwrap(),
            1,
            "re-import must upsert, not duplicate"
        );
        let env_json: String = conn
            .query_row(
                "SELECT env_json FROM channel_env WHERE channel_key='js.test'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(env_json, r#"{"user":"u2"}"#);
        assert!(
            !env_json.contains("\"pass\""),
            "stale env fields must be replaced, got {env_json}"
        );

        let prefs = serde_json::json!({
            "version": 1,
            "prefs": {
                "update_last_checked_at": "123",
                "update_preferred_apk": "{\"a\":\"b\"}"
            }
        });
        assert_eq!(
            import_migration_document(&conn, "update_prefs", &prefs).unwrap(),
            2
        );
        assert_eq!(
            update_pref(&conn, "update_last_checked_at").unwrap(),
            Some("123".to_string())
        );
        assert_eq!(
            update_pref(&conn, "update_preferred_apk").unwrap(),
            Some(r#"{"a":"b"}"#.to_string())
        );
        assert_eq!(
            import_migration_document(&conn, "update_prefs", &prefs).unwrap(),
            2
        );
        let pref_rows: i64 = conn
            .query_row("SELECT COUNT(*) FROM update_prefs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(pref_rows, 2, "re-import must upsert prefs");

        let bad_version = serde_json::json!({"version": 2, "channel_key": "x", "env": {}});
        let err = import_migration_document(&conn, "channel_env", &bad_version)
            .expect_err("version 2 must be rejected");
        assert!(
            err.0.contains("CORE_E_MIGRATION_VERSION"),
            "unexpected error: {}",
            err.0
        );

        let unknown_kind = serde_json::json!({"version": 1});
        let err = import_migration_document(&conn, "nope", &unknown_kind)
            .expect_err("unknown kind must be rejected");
        assert!(
            err.0.contains("CORE_E_MIGRATION_KIND"),
            "unexpected error: {}",
            err.0
        );
    }

    #[test]
    fn migration_dir_is_under_files_dir() {
        let files_dir = Path::new("/tmp/files");
        let dir = migration_dir(files_dir);
        assert!(dir.starts_with(files_dir));
        assert_eq!(
            dir.file_name().and_then(|n| n.to_str()),
            Some(MIGRATION_DIR)
        );
    }
}
