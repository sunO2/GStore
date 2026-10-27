//! Import the Dart `added_apps.db` (v5) into the V2 `added_apps` tables.
//!
//! The Dart database stores camelCase columns; the core stores snake_case. The
//! import preserves the source `id`, `addTime`, `sortOrder`, `isEnabled`, and
//! every tag (including tags whose app row is missing) byte-for-byte.
//!
//! ## Safety model
//!
//! 1. The source is validated before anything else: `integrity_check='ok'`,
//!    `user_version = 5`, the exact v5 table shapes, only 0/1 `isEnabled`, and
//!    no duplicate keys.
//! 2. A consistent snapshot is written with `VACUUM INTO` and everything is
//!    read from that snapshot; the snapshot is deleted afterwards (best
//!    effort).
//! 3. The core database is backed up with `VACUUM INTO` **before** mutating.
//!    A failed backup aborts the import and leaves the core untouched.
//! 4. All core writes happen in one `BEGIN IMMEDIATE` transaction. Validation
//!    or write failures roll back, keeping existing core rows intact.
//! 5. The import is a replace, not an append, so running it again produces the
//!    same rows and the same ids.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags, TransactionBehavior};

use crate::db::DbHandle;
use crate::error::Error;

/// The source does not pass SQLite's integrity check.
pub const CODE_INTEGRITY: &str = "CORE_E_ADDED_INTEGRITY";
/// The source `PRAGMA user_version` is not 5.
pub const CODE_SCHEMA_VERSION: &str = "CORE_E_ADDED_SCHEMA_VERSION";
/// A source table is missing or has the wrong columns/values.
pub const CODE_SCHEMA: &str = "CORE_E_ADDED_SCHEMA";
/// The source contains duplicate app or tag keys.
pub const CODE_DUPLICATE: &str = "CORE_E_ADDED_DUPLICATE";
/// The source could not be read, snapshotted, or backed up.
pub const CODE_IO: &str = "CORE_E_ADDED_IO";
/// The core database could not be written or did not verify.
pub const CODE_WRITE: &str = "CORE_E_ADDED_WRITE";

/// Result of one import.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct AddedAppsMigrationReport {
    /// Source database path as given by the caller.
    pub source: String,
    /// `added_apps` rows imported.
    pub apps: usize,
    /// `added_app_tags` rows imported.
    pub tags: usize,
    /// Core backup written before mutation.
    pub backup: Option<String>,
    /// Whether the temporary source snapshot was removed.
    pub snapshot_deleted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SourceApp {
    id: i64,
    channel_id: String,
    app_id: String,
    add_time: i64,
    sort_order: i64,
    is_enabled: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct SourceTag {
    channel_id: String,
    app_id: String,
    tag: String,
    add_time: i64,
}

const APP_COLUMNS: [&str; 6] = [
    "id",
    "channelId",
    "appId",
    "addTime",
    "sortOrder",
    "isEnabled",
];
const TAG_COLUMNS: [&str; 4] = ["channelId", "appId", "tag", "addTime"];
const DART_SCHEMA_VERSION: i64 = 5;

/// Imports a Dart `added_apps.db` v5 into the core database.
///
/// See the module documentation for the snapshot/backup/transaction model.
pub fn import_dart_added_db(
    db: &DbHandle,
    source: &Path,
) -> Result<AddedAppsMigrationReport, Error> {
    let source_conn = open_source(source)?;
    validate_source(&source_conn, source)?;
    let snapshot = create_snapshot(&source_conn, source)?;
    let outcome = import_from_snapshot(db, &snapshot, source);
    let snapshot_deleted = fs::remove_file(&snapshot).is_ok();
    outcome.map(|mut report| {
        report.snapshot_deleted = snapshot_deleted;
        report
    })
}

fn open_source(source: &Path) -> Result<Connection, Error> {
    if !source.is_file() {
        return Err(io_error(format!(
            "source database not found: {}",
            source.display()
        )));
    }
    Connection::open_with_flags(source, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| io_error(format!("open source {}: {error}", source.display())))
}

fn validate_source(conn: &Connection, source: &Path) -> Result<(), Error> {
    let integrity: String = conn
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|error| {
            Error::InvalidArgument(format!(
                "{CODE_INTEGRITY}: read integrity_check {}: {error}",
                source.display()
            ))
        })?;
    if integrity != "ok" {
        return Err(Error::InvalidArgument(format!(
            "{CODE_INTEGRITY}: {} reported {integrity}",
            source.display()
        )));
    }

    let version: i64 = conn
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|error| {
            Error::InvalidArgument(format!(
                "{CODE_SCHEMA_VERSION}: read user_version {}: {error}",
                source.display()
            ))
        })?;
    if version != DART_SCHEMA_VERSION {
        return Err(Error::InvalidArgument(format!(
            "{CODE_SCHEMA_VERSION}: {} has user_version {version}, expected {DART_SCHEMA_VERSION}",
            source.display()
        )));
    }

    let app_columns = table_columns(conn, "added_apps")?;
    if app_columns != APP_COLUMNS {
        return Err(Error::InvalidArgument(format!(
            "{CODE_SCHEMA}: added_apps columns {app_columns:?}, expected {APP_COLUMNS:?}"
        )));
    }
    let tag_columns = table_columns(conn, "added_app_tags")?;
    if tag_columns != TAG_COLUMNS {
        return Err(Error::InvalidArgument(format!(
            "{CODE_SCHEMA}: added_app_tags columns {tag_columns:?}, expected {TAG_COLUMNS:?}"
        )));
    }

    let bad_enabled: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM added_apps WHERE isEnabled NOT IN (0, 1)",
            [],
            |row| row.get(0),
        )
        .map_err(|error| {
            Error::InvalidArgument(format!("{CODE_SCHEMA}: read isEnabled: {error}"))
        })?;
    if bad_enabled != 0 {
        return Err(Error::InvalidArgument(format!(
            "{CODE_SCHEMA}: {bad_enabled} added_apps rows have isEnabled outside 0/1"
        )));
    }

    let duplicate_apps: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM ( \
                 SELECT channelId, appId FROM added_apps \
                 GROUP BY channelId, appId HAVING COUNT(*) > 1\
             )",
            [],
            |row| row.get(0),
        )
        .map_err(|error| {
            Error::InvalidArgument(format!("{CODE_DUPLICATE}: read added_apps keys: {error}"))
        })?;
    if duplicate_apps != 0 {
        return Err(Error::InvalidArgument(format!(
            "{CODE_DUPLICATE}: {duplicate_apps} duplicate (channelId, appId) keys"
        )));
    }

    let duplicate_tags: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM ( \
                 SELECT channelId, appId, tag FROM added_app_tags \
                 GROUP BY channelId, appId, tag HAVING COUNT(*) > 1\
             )",
            [],
            |row| row.get(0),
        )
        .map_err(|error| {
            Error::InvalidArgument(format!("{CODE_DUPLICATE}: read tag keys: {error}"))
        })?;
    if duplicate_tags != 0 {
        return Err(Error::InvalidArgument(format!(
            "{CODE_DUPLICATE}: {duplicate_tags} duplicate (channelId, appId, tag) keys"
        )));
    }

    Ok(())
}

fn table_columns(conn: &Connection, table: &str) -> Result<Vec<String>, Error> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info(\"{table}\")"))
        .map_err(|error| {
            Error::InvalidArgument(format!("{CODE_SCHEMA}: read {table} columns: {error}"))
        })?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| {
            Error::InvalidArgument(format!("{CODE_SCHEMA}: read {table} columns: {error}"))
        })?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| {
            Error::InvalidArgument(format!("{CODE_SCHEMA}: read {table} columns: {error}"))
        })?;
    Ok(columns)
}

fn create_snapshot(conn: &Connection, source: &Path) -> Result<PathBuf, Error> {
    let temp_dir = std::env::temp_dir();
    let snapshot = unique_path(&temp_dir, "added-apps-snapshot", ".db")?;
    conn.execute("VACUUM INTO ?1", [snapshot.to_string_lossy().into_owned()])
        .map_err(|error| {
            io_error(format!(
                "snapshot {} from {}: {error}",
                snapshot.display(),
                source.display()
            ))
        })?;
    Ok(snapshot)
}

fn import_from_snapshot(
    db: &DbHandle,
    snapshot: &Path,
    source: &Path,
) -> Result<AddedAppsMigrationReport, Error> {
    let snapshot_conn = Connection::open_with_flags(snapshot, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| io_error(format!("open snapshot {}: {error}", snapshot.display())))?;
    let apps = read_apps(&snapshot_conn)?;
    let tags = read_tags(&snapshot_conn)?;
    drop(snapshot_conn);

    let backup = backup_core(db)?;
    write_core(db, &apps, &tags)?;

    Ok(AddedAppsMigrationReport {
        source: source.display().to_string(),
        apps: apps.len(),
        tags: tags.len(),
        backup: Some(backup.to_string_lossy().into_owned()),
        snapshot_deleted: false,
    })
}

fn read_apps(conn: &Connection) -> Result<Vec<SourceApp>, Error> {
    let mut stmt = conn
        .prepare(
            "SELECT id, channelId, appId, addTime, sortOrder, isEnabled \
             FROM added_apps ORDER BY id ASC",
        )
        .map_err(|error| io_error(format!("{CODE_IO}: read added_apps: {error}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok(SourceApp {
                id: row.get(0)?,
                channel_id: row.get(1)?,
                app_id: row.get(2)?,
                add_time: row.get(3)?,
                sort_order: row.get(4)?,
                is_enabled: row.get(5)?,
            })
        })
        .map_err(|error| io_error(format!("{CODE_IO}: read added_apps: {error}")))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| io_error(format!("{CODE_IO}: read added_apps: {error}")))?;
    Ok(rows)
}

fn read_tags(conn: &Connection) -> Result<Vec<SourceTag>, Error> {
    let mut stmt = conn
        .prepare("SELECT channelId, appId, tag, addTime FROM added_app_tags ORDER BY rowid")
        .map_err(|error| io_error(format!("{CODE_IO}: read added_app_tags: {error}")))?;
    let rows = stmt
        .query_map([], |row| {
            Ok(SourceTag {
                channel_id: row.get(0)?,
                app_id: row.get(1)?,
                tag: row.get(2)?,
                add_time: row.get(3)?,
            })
        })
        .map_err(|error| io_error(format!("{CODE_IO}: read added_app_tags: {error}")))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| io_error(format!("{CODE_IO}: read added_app_tags: {error}")))?;
    Ok(rows)
}

fn backup_core(db: &DbHandle) -> Result<PathBuf, Error> {
    let core_path = db.path();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| io_error(format!("{CODE_IO}: clock: {error}")))?
        .as_nanos();
    let base = PathBuf::from(format!("{}.bak-added-{nanos}", core_path.display()));
    let mut backup = base.clone();
    let mut attempt = 0_u32;
    while backup.exists() {
        attempt += 1;
        backup = PathBuf::from(format!("{}-{attempt}", base.display()));
    }
    let conn = db
        .writer()
        .map_err(|error| io_error(format!("{CODE_IO}: lock core db: {error}")))?;
    conn.execute("VACUUM INTO ?1", [backup.to_string_lossy().into_owned()])
        .map_err(|error| {
            io_error(format!(
                "{CODE_IO}: backup core to {}: {error}",
                backup.display()
            ))
        })?;
    Ok(backup)
}

fn write_core(db: &DbHandle, apps: &[SourceApp], tags: &[SourceTag]) -> Result<(), Error> {
    let mut conn = db
        .writer()
        .map_err(|error| write_error(format!("lock core db: {error}")))?;
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|error| write_error(format!("begin import transaction: {error}")))?;

    tx.execute("DELETE FROM added_app_tags", [])
        .map_err(|error| write_error(format!("clear added_app_tags: {error}")))?;
    tx.execute("DELETE FROM added_apps", [])
        .map_err(|error| write_error(format!("clear added_apps: {error}")))?;

    {
        let mut stmt = tx
            .prepare(
                "INSERT INTO added_apps( \
                     id, channel_id, app_id, add_time, sort_order, is_enabled\
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )
            .map_err(|error| write_error(format!("prepare added_apps insert: {error}")))?;
        for app in apps {
            stmt.execute(rusqlite::params![
                app.id,
                app.channel_id,
                app.app_id,
                app.add_time,
                app.sort_order,
                app.is_enabled,
            ])
            .map_err(|error| {
                write_error(format!(
                    "insert added app {}:{}: {error}",
                    app.channel_id, app.app_id
                ))
            })?;
        }
    }

    {
        let mut stmt = tx
            .prepare(
                "INSERT INTO added_app_tags(channel_id, app_id, tag, add_time) \
                 VALUES (?1, ?2, ?3, ?4)",
            )
            .map_err(|error| write_error(format!("prepare tag insert: {error}")))?;
        for tag in tags {
            stmt.execute(rusqlite::params![
                tag.channel_id,
                tag.app_id,
                tag.tag,
                tag.add_time,
            ])
            .map_err(|error| {
                write_error(format!(
                    "insert tag {}:{}:{}: {error}",
                    tag.channel_id, tag.app_id, tag.tag
                ))
            })?;
        }
    }

    let app_count: i64 = tx
        .query_row("SELECT COUNT(*) FROM added_apps", [], |row| row.get(0))
        .map_err(|error| write_error(format!("count added_apps: {error}")))?;
    let tag_count: i64 = tx
        .query_row("SELECT COUNT(*) FROM added_app_tags", [], |row| row.get(0))
        .map_err(|error| write_error(format!("count added_app_tags: {error}")))?;
    if app_count != apps.len() as i64 || tag_count != tags.len() as i64 {
        return Err(write_error(format!(
            "import count mismatch: apps {app_count}/{} tags {tag_count}/{}",
            apps.len(),
            tags.len()
        )));
    }

    tx.commit()
        .map_err(|error| write_error(format!("commit import: {error}")))
}

fn unique_path(dir: &Path, prefix: &str, suffix: &str) -> Result<PathBuf, Error> {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| io_error(format!("{CODE_IO}: clock: {error}")))?
        .as_nanos();
    let base = dir.join(format!("{prefix}-{nanos}{suffix}"));
    let mut candidate = base.clone();
    let mut attempt = 0_u32;
    while candidate.exists() {
        attempt += 1;
        candidate = PathBuf::from(format!("{}-{attempt}", base.display()));
    }
    Ok(candidate)
}

fn io_error(message: impl Into<String>) -> Error {
    Error::Io(message.into())
}

fn write_error(message: impl Into<String>) -> Error {
    Error::Internal(format!("{CODE_WRITE}: {}", message.into()))
}
