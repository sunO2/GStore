//! SQLite storage for gstore_core.

use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags};

use crate::migration;

/// Shared, mutex-guarded SQLite writer used by the core ports.
pub type SharedConn = Arc<Mutex<Connection>>;

/// Error type for core database operations.
#[derive(Debug)]
pub struct DbError(pub String);

impl fmt::Display for DbError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DbError {}

/// Default file name of the core database file.
pub const CORE_DB_FILE: &str = "gstore_core.db";

/// Busy timeout applied to every core connection.
pub const BUSY_TIMEOUT: Duration = Duration::from_millis(5000);

/// Full path of the core database file inside `data_dir`.
pub fn core_db_path(data_dir: &Path) -> PathBuf {
    data_dir.join(CORE_DB_FILE)
}

/// Handle to the core database.
///
/// Write policy: exactly one write connection lives behind a mutex; all writes
/// go through [`DbHandle::with_writer`] (or [`DbHandle::writer`]) so they are
/// serialized. Readers are opened on demand as separate read-only connections,
/// which is safe in WAL mode. Opening the same database through a second
/// `DbHandle` is also safe: refinery's ledger makes migrations a no-op.
#[derive(Clone)]
pub struct DbHandle {
    path: PathBuf,
    writer: SharedConn,
}

impl DbHandle {
    /// Opens (or creates) the core database under `data_dir` and applies the
    /// embedded migrations.
    pub fn open(data_dir: &Path) -> Result<Self, DbError> {
        std::fs::create_dir_all(data_dir)
            .map_err(|e| DbError(format!("create data dir {}: {e}", data_dir.display())))?;
        Self::open_at(&core_db_path(data_dir))
    }

    /// Opens (or creates) the core database at an explicit path.
    pub fn open_at(path: &Path) -> Result<Self, DbError> {
        let conn = open_at(path)?;
        Ok(Self {
            path: path.to_path_buf(),
            writer: Arc::new(Mutex::new(conn)),
        })
    }

    /// Path of the backing database file.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Shared writer handle for ports that already take a [`SharedConn`].
    pub fn shared_writer(&self) -> SharedConn {
        Arc::clone(&self.writer)
    }

    /// Locks the single write connection.
    pub fn writer(&self) -> Result<MutexGuard<'_, Connection>, DbError> {
        self.writer
            .lock()
            .map_err(|_| DbError("core db writer mutex poisoned".to_string()))
    }

    /// Runs `f` against the single write connection.
    pub fn with_writer<T>(
        &self,
        f: impl FnOnce(&mut Connection) -> Result<T, DbError>,
    ) -> Result<T, DbError> {
        let mut guard = self.writer()?;
        f(&mut guard)
    }

    /// Opens a fresh read-only connection.
    pub fn reader(&self) -> Result<Connection, DbError> {
        open_connection(&self.path, true)
    }

    /// Runs `f` against a fresh read-only connection.
    pub fn with_reader<T>(
        &self,
        f: impl FnOnce(&Connection) -> Result<T, DbError>,
    ) -> Result<T, DbError> {
        let conn = self.reader()?;
        f(&conn)
    }
}

/// Opens (or creates) the core database at `path` and applies the schema.
///
/// Prefer [`DbHandle::open_at`] for new code; this function is kept for
/// callers that need a bare [`Connection`].
pub fn open_at(path: &Path) -> Result<Connection, DbError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| DbError(format!("create data dir {}: {e}", parent.display())))?;
    }
    let existed = path.exists();
    let mut conn = open_connection(path, false)?;
    let version: i64 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|e| DbError(format!("read user_version {}: {e}", path.display())))?;
    if existed && version > 0 && version < i64::from(migration::CORE_SCHEMA_VERSION) {
        backup_before_migration(&conn, path, version)?;
    }
    migration::apply_core_schema(&mut conn)?;
    Ok(conn)
}

fn backup_before_migration(
    conn: &Connection,
    path: &Path,
    from_version: i64,
) -> Result<(), DbError> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| DbError(format!("backup clock: {e}")))?
        .as_nanos();
    let dest = unique_backup_path(path, from_version, nanos);
    conn.execute(
        "VACUUM INTO ?1",
        rusqlite::params![dest.to_string_lossy().into_owned()],
    )
    .map_err(|e| {
        DbError(format!(
            "backup {} before v{from_version} migration: {e}",
            dest.display()
        ))
    })?;
    Ok(())
}

fn unique_backup_path(path: &Path, from_version: i64, nanos: u128) -> PathBuf {
    let base = format!("{}.bak-v{from_version}-{nanos}", path.display());
    let mut candidate = PathBuf::from(&base);
    let mut attempt = 0_u32;
    while candidate.exists() {
        attempt += 1;
        candidate = PathBuf::from(format!("{base}-{attempt}"));
    }
    candidate
}

/// Opens (or creates) the core database under `data_dir` and applies the schema.
pub fn open(data_dir: &Path) -> Result<Connection, DbError> {
    open_at(&core_db_path(data_dir))
}

fn open_connection(path: &Path, read_only: bool) -> Result<Connection, DbError> {
    let conn = if read_only {
        Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
    } else {
        Connection::open(path)
    }
    .map_err(|e| DbError(format!("open {}: {e}", path.display())))?;

    conn.busy_timeout(BUSY_TIMEOUT)
        .map_err(|e| DbError(format!("set busy_timeout: {e}")))?;
    if !read_only {
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| DbError(format!("set journal_mode=WAL: {e}")))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|e| DbError(format!("set synchronous=NORMAL: {e}")))?;
    }
    conn.pragma_update(None, "foreign_keys", "ON")
        .map_err(|e| DbError(format!("set foreign_keys=ON: {e}")))?;
    Ok(conn)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("gstore_core_db_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn cargo_db_open_sets_wal_and_schema() {
        let dir = temp_dir("open");
        let conn = open(&dir).unwrap();

        let journal_mode: String = conn
            .pragma_query_value(None, "journal_mode", |r| r.get(0))
            .unwrap();
        assert_eq!(journal_mode.to_lowercase(), "wal");

        let version: i32 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(version, migration::CORE_SCHEMA_VERSION);

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
        assert_eq!(
            tables.len(),
            2,
            "expected core_writes and download_task, got {tables:?}"
        );
        assert!(tables.contains(&"core_writes".to_string()));
        assert!(tables.contains(&"download_task".to_string()));

        drop(conn);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn db_handle_serializes_writes_and_allows_readers() {
        let dir = temp_dir("handle");
        let handle = DbHandle::open(&dir).unwrap();
        handle
            .with_writer(|conn| {
                conn.execute(
                    "INSERT INTO channels(key, kind, name) VALUES ('c1', 'custom', 'one')",
                    [],
                )
                .map_err(|e| DbError(e.to_string()))?;
                Ok(())
            })
            .unwrap();

        let name: String = handle
            .with_reader(|conn| {
                conn.query_row("SELECT name FROM channels WHERE key='c1'", [], |row| {
                    row.get(0)
                })
                .map_err(|e| DbError(e.to_string()))
            })
            .unwrap();
        assert_eq!(name, "one");

        let busy: i64 = handle
            .with_writer(|conn| {
                conn.pragma_query_value(None, "busy_timeout", |row| row.get(0))
                    .map_err(|e| DbError(e.to_string()))
            })
            .unwrap();
        assert_eq!(busy, BUSY_TIMEOUT.as_millis() as i64);

        drop(handle);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
