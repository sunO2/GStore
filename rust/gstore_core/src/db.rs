//! SQLite storage for gstore_core.

use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
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

#[cfg(test)]
thread_local! {
    static FAIL_RESTORE_AFTER_COPY: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Test-only free-space override consulted by [`free_bytes`] so the
    /// `CORE_E_SNAPSHOT_DISK` preflight can be forced without a full disk.
    /// Compiled out of every non-test build, so production is byte-identical.
    static FORCED_FREE_BYTES: std::cell::Cell<Option<u64>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
fn take_forced_restore_failure() -> bool {
    FAIL_RESTORE_AFTER_COPY.with(|cell| cell.replace(false))
}

#[cfg(test)]
fn set_forced_free_bytes(value: Option<u64>) {
    FORCED_FREE_BYTES.with(|cell| cell.set(value));
}

/// Typed error prefix: the snapshot schema is newer than this core.
pub const SNAPSHOT_NEWER: &str = "CORE_E_SNAPSHOT_NEWER";
/// Typed error prefix: the snapshot schema is older than this core.
pub const SNAPSHOT_OLDER: &str = "CORE_E_SNAPSHOT_OLDER";
/// Typed error prefix: the snapshot is not a usable core database.
pub const SNAPSHOT_SHAPE: &str = "CORE_E_SNAPSHOT_SHAPE";
/// Typed error prefix: the snapshot (or the restored copy) failed integrity.
pub const SNAPSHOT_INTEGRITY: &str = "CORE_E_SNAPSHOT_INTEGRITY";
/// Typed error prefix: not enough free space to stage the restore.
pub const SNAPSHOT_DISK: &str = "CORE_E_SNAPSHOT_DISK";
/// Typed error prefix: the pre-restore live backup failed.
pub const SNAPSHOT_BACKUP: &str = "CORE_E_SNAPSHOT_BACKUP";
/// Typed error prefix: the live database swap failed or was rolled back.
pub const SNAPSHOT_RESTORE: &str = "CORE_E_SNAPSHOT_RESTORE";

/// Tables every restorable core snapshot must contain.
pub const SNAPSHOT_REQUIRED_TABLES: [&str; 12] = [
    "core_writes",
    "download_task",
    "installed_app",
    "inventory_source",
    "platform_facts",
    "frontend_rules",
    "channels",
    "channel_apps",
    "apps",
    "config_entry",
    "config_change_log",
    "config_meta",
];

/// Monotonic suffix shared by every staging file in this process.
static STAGING_COUNTER: AtomicU64 = AtomicU64::new(0);

fn snapshot_error(code: &str, detail: impl fmt::Display) -> DbError {
    DbError(format!("{code}: {detail}"))
}

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
    files_dir: Option<PathBuf>,
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
            files_dir: None,
        })
    }

    /// Wraps an already-shared writer so a caller that holds the same
    /// [`SharedConn`] (for example the FRB `CoreApi`) can use the handle-level
    /// restore path and have every holder observe the replacement.
    pub fn from_shared(path: PathBuf, writer: SharedConn) -> Self {
        Self {
            path,
            writer,
            files_dir: None,
        }
    }

    /// Overrides the files root used for pre-restore backups.
    pub fn with_files_dir(mut self, files_dir: impl Into<PathBuf>) -> Self {
        self.files_dir = Some(files_dir.into());
        self
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

    /// Replaces the live database with `snapshot`, upgrading older snapshots.
    ///
    /// A snapshot with `user_version < CORE_SCHEMA_VERSION` is first copied to
    /// a private staging file and migrated there, so the caller's snapshot file
    /// is never mutated. The staged copy (or the snapshot itself when it is
    /// already current) is validated for required tables and `integrity_check`,
    /// the disk preflight covers staging + backup + migration + the final copy,
    /// and only then is the live database backed up with `VACUUM INTO` and
    /// swapped under the writer mutex. A failure after the swap begins restores
    /// the previous file and reopens it.
    ///
    /// Returns the post-migration schema version.
    pub fn replace_from_snapshot(&self, snapshot: &Path) -> Result<i32, DbError> {
        let live = self.path.as_path();
        if snapshot == live {
            return Err(snapshot_error(
                SNAPSHOT_SHAPE,
                format!("snapshot path is the live db: {}", live.display()),
            ));
        }

        let snapshot_conn = open_connection(snapshot, true).map_err(|e| {
            snapshot_error(
                SNAPSHOT_SHAPE,
                format!("open snapshot {}: {e}", snapshot.display()),
            )
        })?;
        let version: i64 = snapshot_conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(|e| {
                snapshot_error(
                    SNAPSHOT_SHAPE,
                    format!("read snapshot user_version {}: {e}", snapshot.display()),
                )
            })?;
        let version = i32::try_from(version).map_err(|_| {
            snapshot_error(SNAPSHOT_SHAPE, format!("user_version {version} out of range"))
        })?;
        if version > migration::CORE_SCHEMA_VERSION {
            return Err(snapshot_error(
                SNAPSHOT_NEWER,
                format!("snapshot v{version} > core v{}", migration::CORE_SCHEMA_VERSION),
            ));
        }
        if version < 1 {
            return Err(snapshot_error(
                SNAPSHOT_SHAPE,
                format!(
                    "snapshot user_version {version} is not a versioned core database (core v{})",
                    migration::CORE_SCHEMA_VERSION
                ),
            ));
        }

        let snapshot_size = std::fs::metadata(snapshot)
            .map_err(|e| {
                snapshot_error(
                    SNAPSHOT_SHAPE,
                    format!("stat snapshot {}: {e}", snapshot.display()),
                )
            })?
            .len();
        let live_size = std::fs::metadata(live).map_or(0, |meta| meta.len());
        let live_parent = live.parent().unwrap_or_else(|| Path::new("."));
        let free = free_bytes(live_parent).map_err(|e| {
            snapshot_error(
                SNAPSHOT_DISK,
                format!("stat free space at {}: {e}", live_parent.display()),
            )
        })?;
        let required = live_size
            .saturating_mul(2)
            .saturating_add(snapshot_size.saturating_mul(2));
        if free < required {
            return Err(snapshot_error(
                SNAPSHOT_DISK,
                format!(
                    "free {free} < required {required} (2 x live {live_size} + 2 x snapshot {snapshot_size}) at {}",
                    live_parent.display()
                ),
            ));
        }

        let mut staged = None;
        let source = if version < migration::CORE_SCHEMA_VERSION {
            let stage = StagedSnapshot::create(live, snapshot)?;
            migrate_staged_snapshot(stage.path())?;
            let path = stage.path().to_path_buf();
            staged = Some(stage);
            path
        } else {
            snapshot.to_path_buf()
        };

        let source_conn = if version < migration::CORE_SCHEMA_VERSION {
            open_connection(&source, true).map_err(|e| {
                snapshot_error(
                    SNAPSHOT_INTEGRITY,
                    format!("open staged snapshot {}: {e}", source.display()),
                )
            })?
        } else {
            snapshot_conn
        };
        validate_snapshot_shape(&source_conn)?;
        drop(source_conn);

        let mut writer = self.writer()?;
        let files_dir = self
            .files_dir
            .clone()
            .or_else(|| live.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| PathBuf::from("."));
        let backup = backup_before_restore(&writer, &files_dir)?;
        log::debug!("pre-restore backup: {}", backup.display());

        swap_live_db(&mut writer, live, &source)?;
        drop(staged);
        Ok(migration::CORE_SCHEMA_VERSION)
    }
}

/// A private copy of an older snapshot that is migrated in place.
///
/// The `Drop` impl removes the file and its WAL sidecars on every exit path —
/// success, validation error, migration error, or a panic — so a failed
/// restore never leaves a partially-migrated database behind.
struct StagedSnapshot {
    path: PathBuf,
}

impl StagedSnapshot {
    fn create(live: &Path, snapshot: &Path) -> Result<Self, DbError> {
        let dir = live.parent().unwrap_or_else(|| Path::new("."));
        let file_name = live
            .file_name()
            .map_or_else(|| CORE_DB_FILE.to_string(), |name| name.to_string_lossy().into_owned());
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_millis());
        let counter = STAGING_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = dir.join(format!(
            ".{file_name}.restore-stage-{}-{millis}-{counter}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        std::fs::copy(snapshot, &path).map_err(|e| {
            let _ = std::fs::remove_file(&path);
            snapshot_error(
                SNAPSHOT_RESTORE,
                format!(
                    "stage snapshot {} -> {}: {e}",
                    snapshot.display(),
                    path.display()
                ),
            )
        })?;
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for StagedSnapshot {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        let _ = std::fs::remove_file(sidecar_path(&self.path, "wal"));
        let _ = std::fs::remove_file(sidecar_path(&self.path, "shm"));
    }
}

fn migrate_staged_snapshot(path: &Path) -> Result<(), DbError> {
    let mut conn = open_connection(path, false).map_err(|e| {
        snapshot_error(
            SNAPSHOT_RESTORE,
            format!("open staged snapshot {}: {e}", path.display()),
        )
    })?;
    migration::apply_core_schema(&mut conn).map_err(|e| {
        snapshot_error(
            SNAPSHOT_RESTORE,
            format!("migrate staged snapshot {}: {e}", path.display()),
        )
    })?;
    let version: i64 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|e| {
            snapshot_error(
                SNAPSHOT_RESTORE,
                format!("read staged user_version {}: {e}", path.display()),
            )
        })?;
    if version != i64::from(migration::CORE_SCHEMA_VERSION) {
        return Err(snapshot_error(
            SNAPSHOT_RESTORE,
            format!(
                "staged snapshot {} is v{version}, expected v{}",
                path.display(),
                migration::CORE_SCHEMA_VERSION
            ),
        ));
    }
    // The staging connection runs in WAL mode (`open_connection`); flush the
    // migration writes into the main file before it is copied to the live path.
    let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    Ok(())
}

fn validate_snapshot_shape(conn: &Connection) -> Result<(), DbError> {
    for table in SNAPSHOT_REQUIRED_TABLES {
        let found: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                [table],
                |row| row.get(0),
            )
            .map_err(|e| snapshot_error(SNAPSHOT_SHAPE, format!("inspect snapshot tables: {e}")))?;
        if found == 0 {
            return Err(snapshot_error(
                SNAPSHOT_SHAPE,
                format!("snapshot is missing table {table}"),
            ));
        }
    }

    let integrity: String = conn
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|e| {
            snapshot_error(SNAPSHOT_INTEGRITY, format!("snapshot integrity_check: {e}"))
        })?;
    if integrity != "ok" {
        return Err(snapshot_error(
            SNAPSHOT_INTEGRITY,
            format!("snapshot integrity_check: {integrity}"),
        ));
    }
    Ok(())
}

fn backup_before_restore(conn: &Connection, files_dir: &Path) -> Result<PathBuf, DbError> {
    let backups = files_dir
        .join(crate::migration::MIGRATION_DIR)
        .join("backups");
    std::fs::create_dir_all(&backups).map_err(|e| {
        snapshot_error(
            SNAPSHOT_BACKUP,
            format!("create backup dir {}: {e}", backups.display()),
        )
    })?;
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| snapshot_error(SNAPSHOT_BACKUP, format!("backup clock: {e}")))?
        .as_millis();
    let dest = unique_pre_restore_path(&backups, millis);
    conn.execute(
        "VACUUM INTO ?1",
        rusqlite::params![dest.to_string_lossy().into_owned()],
    )
    .map_err(|e| {
        snapshot_error(
            SNAPSHOT_BACKUP,
            format!("vacuum live db into {}: {e}", dest.display()),
        )
    })?;
    Ok(dest)
}

fn unique_pre_restore_path(backups: &Path, millis: u128) -> PathBuf {
    let mut candidate = backups.join(format!("pre-restore-{millis}.db"));
    let mut attempt = 0_u32;
    while candidate.exists() {
        attempt += 1;
        candidate = backups.join(format!("pre-restore-{millis}-{attempt}.db"));
    }
    candidate
}

fn swap_live_db(writer: &mut Connection, live: &Path, snapshot: &Path) -> Result<(), DbError> {
    let file_name = live
        .file_name()
        .ok_or_else(|| {
            snapshot_error(
                SNAPSHOT_RESTORE,
                format!("live db has no file name: {}", live.display()),
            )
        })?
        .to_string_lossy()
        .into_owned();
    let old_path = live.with_file_name(format!("{file_name}.restore-old"));

    let _ = writer.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    let placeholder = Connection::open_in_memory().map_err(|e| {
        snapshot_error(SNAPSHOT_RESTORE, format!("prepare writer swap: {e}"))
    })?;
    let mut fallback = Some(std::mem::replace(writer, placeholder));
    let _ = std::fs::remove_file(&old_path);

    if let Err(e) = std::fs::rename(live, &old_path) {
        *writer = fallback
            .take()
            .expect("fallback connection is present until the swap succeeds");
        return Err(snapshot_error(
            SNAPSHOT_RESTORE,
            format!("rename live db {}: {e}", live.display()),
        ));
    }
    let _ = std::fs::remove_file(sidecar_path(live, "wal"));
    let _ = std::fs::remove_file(sidecar_path(live, "shm"));

    match install_snapshot_copy(live, snapshot) {
        Ok(restored) => {
            *writer = restored;
            drop(fallback.take());
            let _ = std::fs::remove_file(&old_path);
            Ok(())
        }
        Err(error) => {
            let _ = std::fs::remove_file(live);
            let _ = std::fs::remove_file(sidecar_path(live, "wal"));
            let _ = std::fs::remove_file(sidecar_path(live, "shm"));
            if std::fs::rename(&old_path, live).is_err() {
                *writer = fallback
                    .take()
                    .expect("fallback connection is present until the swap succeeds");
                return Err(snapshot_error(
                    SNAPSHOT_RESTORE,
                    format!("{error}; rollback rename live db failed"),
                ));
            }
            match open_connection(live, false) {
                Ok(reopened) => *writer = reopened,
                Err(reopen) => {
                    *writer = fallback.take().ok_or_else(|| {
                        snapshot_error(
                            SNAPSHOT_RESTORE,
                            format!("{error}; rollback reopen live: {reopen}"),
                        )
                    })?;
                    return Err(snapshot_error(
                        SNAPSHOT_RESTORE,
                        format!("{error}; rollback reopen live: {reopen}"),
                    ));
                }
            }
            Err(error)
        }
    }
}

fn install_snapshot_copy(live: &Path, snapshot: &Path) -> Result<Connection, DbError> {
    std::fs::copy(snapshot, live).map_err(|e| {
        snapshot_error(
            SNAPSHOT_RESTORE,
            format!("copy {} -> {}: {e}", snapshot.display(), live.display()),
        )
    })?;
    #[cfg(test)]
    if take_forced_restore_failure() {
        let _ = std::fs::write(live, b"corrupted after copy");
    }
    let conn = open_connection(live, false).map_err(|e| {
        snapshot_error(SNAPSHOT_INTEGRITY, format!("open restored live db: {e}"))
    })?;
    let integrity: String = conn
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|e| {
            snapshot_error(SNAPSHOT_INTEGRITY, format!("restored integrity_check: {e}"))
        })?;
    if integrity != "ok" {
        return Err(snapshot_error(
            SNAPSHOT_INTEGRITY,
            format!("restored integrity_check: {integrity}"),
        ));
    }
    Ok(conn)
}

fn sidecar_path(live: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}-{suffix}", live.display()))
}

#[cfg(unix)]
fn free_bytes(path: &Path) -> std::io::Result<u64> {
    #[cfg(test)]
    if let Some(bytes) = FORCED_FREE_BYTES.with(|cell| cell.get()) {
        return Ok(bytes);
    }
    use std::os::unix::ffi::OsStrExt;

    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: `statvfs` initializes the whole struct on success and we only read
    // it after the call reports success; `c_path` is a valid NUL-terminated path.
    let rc = unsafe { libc::statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: the call above succeeded, so the struct is initialized.
    let stat = unsafe { stat.assume_init() };
    #[cfg(target_pointer_width = "64")]
    let bytes = stat.f_bavail.saturating_mul(stat.f_frsize);
    #[cfg(not(target_pointer_width = "64"))]
    let bytes = u64::from(stat.f_bavail).saturating_mul(u64::from(stat.f_frsize));
    Ok(bytes)
}

#[cfg(not(unix))]
fn free_bytes(_path: &Path) -> std::io::Result<u64> {
    #[cfg(test)]
    if let Some(bytes) = FORCED_FREE_BYTES.with(|cell| cell.get()) {
        return Ok(bytes);
    }
    Ok(u64::MAX)
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
    use std::sync::Arc;

    use serde_json::json;

    use super::*;
    use crate::config::{ConfigKey, ConfigSource, ConfigStore};
    use crate::ports::secret::FileSecretStore;

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

        let config_tables: Vec<String> = {
            let mut stmt = conn
                .prepare(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'config_%' \
                     ORDER BY name",
                )
                .unwrap();
            stmt.query_map([], |r| r.get(0))
                .unwrap()
                .map(|r| r.unwrap())
                .collect()
        };
        assert_eq!(
            config_tables,
            vec![
                "config_change_log".to_string(),
                "config_entry".to_string(),
                "config_meta".to_string(),
            ],
            "v6 must create exactly the three config tables (no config_module)"
        );

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

    fn make_snapshot(tag: &str, seed_sql: &str) -> PathBuf {
        let dir = temp_dir(tag);
        let snapshot = dir.join("snapshot.db");
        let handle = DbHandle::open(&dir).unwrap();
        handle
            .with_writer(|conn| {
                conn.execute_batch(seed_sql)
                    .map_err(|e| DbError(e.to_string()))?;
                conn.execute(
                    "VACUUM INTO ?1",
                    rusqlite::params![snapshot.to_string_lossy().into_owned()],
                )
                .map_err(|e| DbError(e.to_string()))?;
                Ok(())
            })
            .unwrap();
        drop(handle);
        snapshot
    }

    fn copy_snapshot(src: &Path, tag: &str) -> PathBuf {
        let dir = temp_dir(tag);
        let dest = dir.join("snapshot.db");
        std::fs::copy(src, &dest).unwrap();
        dest
    }

    fn set_snapshot_version(path: &Path, version: i32) {
        let conn = Connection::open(path).unwrap();
        conn.pragma_update(None, "user_version", version).unwrap();
    }

    fn live_handle(tag: &str, seed_sql: &str) -> (DbHandle, PathBuf) {
        let dir = temp_dir(tag);
        let live = DbHandle::open(&dir).unwrap();
        live.with_writer(|conn| {
            conn.execute_batch(seed_sql)
                .map_err(|e| DbError(e.to_string()))?;
            Ok(())
        })
        .unwrap();
        let files = temp_dir(&format!("{tag}_files"));
        (live, files)
    }

    fn restore_handle(live: &DbHandle, files: &Path) -> DbHandle {
        DbHandle::from_shared(live.path().to_path_buf(), live.shared_writer())
            .with_files_dir(files)
    }

    fn count(conn: &Connection, sql: &str) -> i64 {
        conn.query_row(sql, [], |r| r.get(0)).unwrap()
    }

    fn assert_integrity_ok(conn: &Connection) {
        let result: String = conn
            .query_row("PRAGMA integrity_check", [], |r| r.get(0))
            .unwrap();
        assert_eq!(result, "ok", "integrity_check failed: {result}");
    }

    fn restore_backup_count(files: &Path) -> usize {
        let dir = files.join("migration").join("backups");
        if !dir.is_dir() {
            return 0;
        }
        std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("pre-restore-")
            })
            .count()
    }

    fn staging_files(live: &Path) -> Vec<PathBuf> {
        let dir = live.parent().unwrap_or_else(|| Path::new("."));
        std::fs::read_dir(dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .contains(".restore-stage-")
            })
            .map(|entry| entry.path())
            .collect()
    }

    fn user_version_at(path: &Path) -> i32 {
        Connection::open(path)
            .unwrap()
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap()
    }

    fn table_columns(path: &Path, table: &str) -> Vec<String> {
        let conn = Connection::open(path).unwrap();
        let mut stmt = conn
            .prepare(&format!("PRAGMA table_info({table})"))
            .unwrap();
        stmt.query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .map(|row| row.unwrap())
            .collect()
    }

    /// Builds a genuine v5 fixture: a current v6 database with the v6 config
    /// tables and ledger row removed, then vacuumed into the snapshot path.
    fn make_v5_snapshot(tag: &str, seed_sql: &str) -> PathBuf {
        let dir = temp_dir(tag);
        let snapshot = dir.join("snapshot.db");
        let handle = DbHandle::open(&dir).unwrap();
        handle
            .with_writer(|conn| {
                conn.execute_batch(seed_sql)
                    .map_err(|e| DbError(e.to_string()))?;
                conn.execute_batch(
                    "DROP TABLE IF EXISTS config_change_log;\
                     DROP TABLE IF EXISTS config_entry;\
                     DROP TABLE IF EXISTS config_meta;\
                     DELETE FROM schema_migrations WHERE version = 6;\
                     PRAGMA user_version = 5;",
                )
                .map_err(|e| DbError(e.to_string()))?;
                conn.execute(
                    "VACUUM INTO ?1",
                    rusqlite::params![snapshot.to_string_lossy().into_owned()],
                )
                .map_err(|e| DbError(e.to_string()))?;
                Ok(())
            })
            .unwrap();
        drop(handle);
        snapshot
    }

    fn config_store(live: &DbHandle, files: &Path) -> ConfigStore {
        let store = ConfigStore::new(
            live.clone(),
            Arc::new(FileSecretStore::new(files.join("secrets"))),
        );
        store.load_all().unwrap();
        store
    }

    #[test]
    fn snapshot_restore_replaces_live_db() {
        let snapshot = make_snapshot(
            "restore_src",
            "INSERT INTO channels(key, kind, name) VALUES ('from-snapshot', 'custom', 'Snapshot');\
             INSERT INTO core_writes(domain, first_write_at, snapshot_id) \
             VALUES ('channel', 7, 'snapshot-id');",
        );
        let (live, files) = live_handle(
            "restore_live",
            "INSERT INTO channels(key, kind, name) VALUES ('live-only', 'custom', 'Live');",
        );
        let handle = restore_handle(&live, &files);

        let version = handle.replace_from_snapshot(&snapshot).unwrap();
        assert_eq!(version, migration::CORE_SCHEMA_VERSION);

        live.with_writer(|conn| {
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='from-snapshot'"),
                1,
                "restored snapshot rows must be present"
            );
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='live-only'"),
                0,
                "pre-restore live rows must be gone"
            );
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM core_writes"),
                1,
                "restore must copy the snapshot verbatim"
            );
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();

        assert_eq!(restore_backup_count(&files), 1, "pre-restore backup missing");
        let restore_old = handle
            .path()
            .with_file_name(format!("{CORE_DB_FILE}.restore-old"));
        assert!(!restore_old.exists(), ".restore-old must not survive success");
        assert!(snapshot.is_file(), "snapshot itself must not be moved");
    }

    #[test]
    fn snapshot_backup_failure_is_typed() {
        let snapshot = make_snapshot(
            "backup_fail_src",
            "INSERT INTO channels(key, kind, name) VALUES ('snapshot-row', 'custom', 'Snap');",
        );
        let (live, files) = live_handle(
            "backup_fail_live",
            "INSERT INTO channels(key, kind, name) VALUES ('old-row', 'custom', 'Old');",
        );
        // `<files>/migration/backups` as a regular file makes create_dir_all fail.
        let migration_dir = files.join(migration::MIGRATION_DIR);
        std::fs::create_dir_all(&migration_dir).unwrap();
        std::fs::write(migration_dir.join("backups"), b"not a directory").unwrap();
        let handle = restore_handle(&live, &files);

        let error = handle.replace_from_snapshot(&snapshot).unwrap_err();
        assert!(
            error.0.starts_with(SNAPSHOT_BACKUP),
            "backup failure must be typed: {}",
            error.0
        );
        assert_eq!(
            restore_backup_count(&files),
            0,
            "a failed backup must not create a pre-restore artifact"
        );

        // The failure happens before the writer swap: the live DB is untouched.
        live.with_writer(|conn| {
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='old-row'"),
                1,
                "live rows must survive a backup failure"
            );
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='snapshot-row'"),
                0,
                "no snapshot rows may land after a backup failure"
            );
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
        let restore_old = handle
            .path()
            .with_file_name(format!("{CORE_DB_FILE}.restore-old"));
        assert!(
            !restore_old.exists(),
            ".restore-old must not appear before the swap"
        );
    }

    #[test]
    fn snapshot_rejects_low_disk() {
        let snapshot = make_snapshot(
            "low_disk_src",
            "INSERT INTO channels(key, kind, name) VALUES ('snapshot-row', 'custom', 'Snap');",
        );
        let (live, files) = live_handle(
            "low_disk_live",
            "INSERT INTO channels(key, kind, name) VALUES ('old-row', 'custom', 'Old');",
        );
        let handle = restore_handle(&live, &files);

        set_forced_free_bytes(Some(0));
        let error = handle.replace_from_snapshot(&snapshot).unwrap_err();
        set_forced_free_bytes(None);
        assert!(
            error.0.starts_with(SNAPSHOT_DISK),
            "low free space must be typed: {}",
            error.0
        );
        assert_eq!(
            restore_backup_count(&files),
            0,
            "the disk preflight must run before any backup"
        );
        live.with_writer(|conn| {
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='old-row'"),
                1,
                "live rows must survive a rejected restore"
            );
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='snapshot-row'"),
                0
            );
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();

        // Clearing the forced value proves the seam is the only reason the
        // restore was rejected, and a successful restore cleans `.restore-old`.
        let version = handle.replace_from_snapshot(&snapshot).unwrap();
        assert_eq!(version, migration::CORE_SCHEMA_VERSION);
        assert_eq!(restore_backup_count(&files), 1);
        let restore_old = handle
            .path()
            .with_file_name(format!("{CORE_DB_FILE}.restore-old"));
        assert!(
            !restore_old.exists(),
            "a successful restore must not leave .restore-old behind"
        );
        live.with_writer(|conn| {
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='snapshot-row'"),
                1
            );
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
    }

    #[test]
    fn snapshot_rejects_newer_schema() {
        let snapshot = make_snapshot("newer_src", "");
        let newer = copy_snapshot(&snapshot, "newer_copy");
        assert_eq!(migration::CORE_SCHEMA_VERSION + 1, 7);
        set_snapshot_version(&newer, 7);
        let (live, files) = live_handle(
            "newer_live",
            "INSERT INTO channels(key, kind, name) VALUES ('keep', 'custom', 'Keep');",
        );
        let handle = restore_handle(&live, &files);

        let error = handle.replace_from_snapshot(&newer).unwrap_err();
        assert!(
            error.0.starts_with("CORE_E_SNAPSHOT_NEWER"),
            "unexpected error: {}",
            error.0
        );
        live.with_writer(|conn| {
            assert_eq!(count(conn, "SELECT COUNT(*) FROM channels WHERE key='keep'"), 1);
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
        assert_eq!(restore_backup_count(&files), 0, "rejected snapshot must not back up");
    }

    #[test]
    fn snapshot_restore_upgrades_older() {
        let older = make_v5_snapshot(
            "older_src",
            "INSERT INTO channels(key, kind, name) VALUES ('from-v5', 'custom', 'V5');",
        );
        assert_eq!(user_version_at(&older), 5, "fixture must be a v5 snapshot");
        assert!(
            !table_columns(&older, "config_entry").contains(&"module".to_string()),
            "a v5 fixture has no config tables"
        );

        let (live, files) = live_handle(
            "older_live",
            "INSERT INTO channels(key, kind, name) VALUES ('live-only', 'custom', 'Live');",
        );
        let handle = restore_handle(&live, &files);

        let version = handle.replace_from_snapshot(&older).unwrap();
        assert_eq!(
            version,
            migration::CORE_SCHEMA_VERSION,
            "restore must report the post-migration schema version"
        );

        live.with_writer(|conn| {
            let live_version: i32 = conn
                .pragma_query_value(None, "user_version", |row| row.get(0))
                .unwrap();
            assert_eq!(live_version, migration::CORE_SCHEMA_VERSION);
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='from-v5'"),
                1,
                "v5 rows must survive the upgrade"
            );
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='live-only'"),
                0,
                "the snapshot must replace the live database"
            );
            for table in ["config_entry", "config_change_log", "config_meta"] {
                assert_eq!(
                    count(
                        conn,
                        &format!(
                            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='{table}'"
                        )
                    ),
                    1,
                    "migration must create {table}"
                );
            }
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();

        assert_eq!(
            user_version_at(&older),
            5,
            "the original snapshot must not be mutated by the upgrade"
        );
        assert!(
            !table_columns(&older, "config_entry").contains(&"module".to_string()),
            "the original snapshot must stay a v5 database"
        );
        assert_eq!(restore_backup_count(&files), 1);
        assert!(
            staging_files(handle.path()).is_empty(),
            "staging file must be deleted after a successful upgrade"
        );
    }

    #[test]
    fn snapshot_restore_reloads_config_cache_and_revision() {
        let source_dir = temp_dir("cache_src");
        let source = DbHandle::open(&source_dir).unwrap();
        let snapshot = source_dir.join("snapshot.db");
        source
            .with_writer(|conn| {
                conn.execute_batch(
                    "INSERT INTO config_entry(\
                         module, key, value_json, value_type, revision, updated_at, updated_by) \
                     VALUES ('download', 'max_concurrent', '5', 'number', 42, 123, 'snapshot');\
                     INSERT INTO config_meta(k, v) VALUES ('revision', '42');",
                )
                .map_err(|e| DbError(e.to_string()))?;
                conn.execute(
                    "VACUUM INTO ?1",
                    rusqlite::params![snapshot.to_string_lossy().into_owned()],
                )
                .map_err(|e| DbError(e.to_string()))?;
                Ok(())
            })
            .unwrap();
        drop(source);

        let (live, files) = live_handle("cache_live", "");
        let key = ConfigKey::new("download", "max_concurrent").unwrap();
        let store = config_store(&live, &files);
        let change = store
            .set(&key, json!(2), ConfigSource::User, Some("live".into()))
            .unwrap();
        assert_eq!(change.revision, 1);
        assert_eq!(store.revision(), 1);

        let handle = restore_handle(&live, &files);
        assert_eq!(
            handle.replace_from_snapshot(&snapshot).unwrap(),
            migration::CORE_SCHEMA_VERSION
        );
        assert_eq!(
            store.revision(),
            1,
            "the cache is expected to be stale until the restore hook reloads it"
        );

        store.reload_from_db().unwrap();
        assert_eq!(
            store.revision(),
            42,
            "reload must reset the revision counter from the restored config_meta"
        );
        assert_eq!(store.get(&key).unwrap(), json!(5));
        assert_eq!(
            store.snapshot(&key).unwrap().unwrap().revision,
            42,
            "the restored row must be visible in the cache"
        );
    }

    #[test]
    fn snapshot_restore_secret_hash_policy() {
        let source_dir = temp_dir("secret_src");
        let source = DbHandle::open(&source_dir).unwrap();
        let source_secrets = Arc::new(FileSecretStore::new(source_dir.join("secrets")));
        let source_store = ConfigStore::new(source.clone(), source_secrets);
        source_store.load_all().unwrap();
        let password = ConfigKey::new("webdav", "password").unwrap();
        source_store
            .set(
                &password,
                json!("hunter2"),
                ConfigSource::User,
                Some("source".into()),
            )
            .unwrap();

        let (reference, secret_hash) = source
            .with_writer(|conn| {
                conn.query_row(
                    "SELECT secret_ref, secret_hash FROM config_entry \
                     WHERE module='webdav' AND key='password'",
                    [],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
                )
                .map_err(|e| DbError(e.to_string()))
            })
            .unwrap();
        let snapshot = source_dir.join("snapshot.db");
        source
            .with_writer(|conn| {
                conn.execute(
                    "VACUUM INTO ?1",
                    rusqlite::params![snapshot.to_string_lossy().into_owned()],
                )
                .map_err(|e| DbError(e.to_string()))?;
                Ok(())
            })
            .unwrap();
        drop(source_store);
        drop(source);

        let (live, files) = live_handle("secret_live", "");
        let secret_path = files.join("secrets").join(&reference);
        std::fs::create_dir_all(secret_path.parent().unwrap()).unwrap();
        std::fs::copy(source_dir.join("secrets").join(&reference), &secret_path).unwrap();
        let store = config_store(&live, &files);
        let handle = restore_handle(&live, &files);

        handle.replace_from_snapshot(&snapshot).unwrap();
        store.reload_from_db().unwrap();
        assert_eq!(
            store.get(&password).unwrap(),
            json!("hunter2"),
            "a matching secret file must survive the restore"
        );
        let (restored_ref, restored_hash) = live
            .with_writer(|conn| {
                conn.query_row(
                    "SELECT secret_ref, secret_hash FROM config_entry \
                     WHERE module='webdav' AND key='password'",
                    [],
                    |row| Ok((row.get::<_, Option<String>>(0)?, row.get::<_, Option<String>>(1)?)),
                )
                .map_err(|e| DbError(e.to_string()))
            })
            .unwrap();
        assert_eq!(restored_ref.as_deref(), Some(reference.as_str()));
        assert_eq!(restored_hash.as_deref(), Some(secret_hash.as_str()));

        std::fs::write(&secret_path, "newer-secret").unwrap();
        store.reload_from_db().unwrap();
        assert!(
            store.snapshot(&password).unwrap().is_none(),
            "a hash mismatch must persist-clear the row"
        );
        assert_eq!(
            store.get(&password).unwrap(),
            json!(""),
            "a cleared secret reads as the registry default"
        );
        let cleared_ref: Option<String> = live
            .with_writer(|conn| {
                conn.query_row(
                    "SELECT secret_ref FROM config_entry WHERE module='webdav' AND key='password'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|e| DbError(e.to_string()))
            })
            .unwrap();
        assert_eq!(cleared_ref, None, "the stale row must be persist-cleared");

        handle.replace_from_snapshot(&snapshot).unwrap();
        let _ = std::fs::remove_file(&secret_path);
        store.reload_from_db().unwrap();
        assert!(
            store.snapshot(&password).unwrap().is_none(),
            "a missing secret file must persist-clear the row"
        );
        assert_eq!(store.get(&password).unwrap(), json!(""));
    }

    #[test]
    fn snapshot_restore_rolls_back_on_migration_failure() {
        let older = make_v5_snapshot(
            "migration_fail_src",
            "INSERT INTO channels(key, kind, name) VALUES ('snapshot-row', 'custom', 'Snap');",
        );
        Connection::open(&older)
            .unwrap()
            .execute_batch("CREATE TABLE config_entry(bad INTEGER);")
            .unwrap();
        assert_eq!(user_version_at(&older), 5);

        let (live, files) = live_handle(
            "migration_fail_live",
            "INSERT INTO channels(key, kind, name) VALUES ('old-row', 'custom', 'Old');",
        );
        let handle = restore_handle(&live, &files);

        let error = handle.replace_from_snapshot(&older).unwrap_err();
        assert!(
            error.0.starts_with(SNAPSHOT_RESTORE),
            "migration failure must be typed: {}",
            error.0
        );
        assert_eq!(
            restore_backup_count(&files),
            0,
            "migration happens before the pre-restore backup"
        );
        live.with_writer(|conn| {
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='old-row'"),
                1,
                "live rows must survive a migration failure"
            );
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='snapshot-row'"),
                0,
                "no staged rows may land after a migration failure"
            );
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
        assert!(
            staging_files(handle.path()).is_empty(),
            "staging must be deleted after a migration failure"
        );
        assert_eq!(
            user_version_at(&older),
            5,
            "the original snapshot must stay untouched on failure"
        );
        assert!(
            table_columns(&older, "config_entry") == vec!["bad".to_string()],
            "the original snapshot shape must not be migrated in place"
        );
    }

    #[test]
    fn snapshot_disk_preflight_covers_live_and_staging() {
        let older = make_v5_snapshot("disk_formula_src", "");
        let (live, files) = live_handle(
            "disk_formula_live",
            "INSERT INTO channels(key, kind, name) VALUES ('old-row', 'custom', 'Old');",
        );
        let handle = restore_handle(&live, &files);
        let live_size = std::fs::metadata(handle.path()).unwrap().len();
        let snapshot_size = std::fs::metadata(&older).unwrap().len();
        let required = live_size
            .saturating_mul(2)
            .saturating_add(snapshot_size.saturating_mul(2));

        set_forced_free_bytes(Some(required - 1));
        let error = handle.replace_from_snapshot(&older).unwrap_err();
        set_forced_free_bytes(None);
        assert!(
            error.0.starts_with(SNAPSHOT_DISK),
            "a shortage below 2 x live + 2 x snapshot must be rejected: {}",
            error.0
        );
        assert!(error.0.contains(&required.to_string()), "{}", error.0);
        assert!(staging_files(handle.path()).is_empty());

        set_forced_free_bytes(Some(required));
        let version = handle.replace_from_snapshot(&older).unwrap();
        set_forced_free_bytes(None);
        assert_eq!(version, migration::CORE_SCHEMA_VERSION);
        assert!(staging_files(handle.path()).is_empty());
        assert_eq!(restore_backup_count(&files), 1);
    }

    #[test]
    fn snapshot_restore_cleans_staging_on_every_path() {
        let older = make_v5_snapshot("cleanup_src", "");
        let (live, files) = live_handle("cleanup_live", "");
        let handle = restore_handle(&live, &files);
        assert!(staging_files(handle.path()).is_empty());

        let newer = copy_snapshot(&older, "cleanup_newer");
        set_snapshot_version(&newer, migration::CORE_SCHEMA_VERSION + 1);
        let _ = handle.replace_from_snapshot(&newer).unwrap_err();
        assert!(
            staging_files(handle.path()).is_empty(),
            "a rejected newer snapshot must not stage anything"
        );

        handle.replace_from_snapshot(&older).unwrap();
        assert!(
            staging_files(handle.path()).is_empty(),
            "a successful upgrade must delete staging"
        );

        let broken = make_v5_snapshot("cleanup_broken", "");
        Connection::open(&broken)
            .unwrap()
            .execute_batch("CREATE TABLE config_entry(bad INTEGER);")
            .unwrap();
        let _ = handle.replace_from_snapshot(&broken).unwrap_err();
        assert!(
            staging_files(handle.path()).is_empty(),
            "a failed migration must delete staging"
        );
    }

    #[test]
    fn snapshot_rejects_missing_table() {
        let snapshot = make_snapshot("shape_src", "");
        let broken = copy_snapshot(&snapshot, "shape_copy");
        Connection::open(&broken)
            .unwrap()
            .execute_batch("DROP TABLE platform_facts;")
            .unwrap();
        let (live, files) = live_handle("shape_live", "");
        let handle = restore_handle(&live, &files);

        let error = handle.replace_from_snapshot(&broken).unwrap_err();
        assert!(
            error.0.starts_with("CORE_E_SNAPSHOT_SHAPE"),
            "unexpected error: {}",
            error.0
        );
        live.with_writer(|conn| {
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
    }

    #[test]
    fn snapshot_restore_rolls_back_on_integrity_failure() {
        let snapshot = make_snapshot(
            "rollback_src",
            "INSERT INTO channels(key, kind, name) VALUES ('snapshot-row', 'custom', 'Snap');",
        );
        let (live, files) = live_handle(
            "rollback_live",
            "INSERT INTO channels(key, kind, name) VALUES ('old-row', 'custom', 'Old');",
        );
        let handle = restore_handle(&live, &files);

        FAIL_RESTORE_AFTER_COPY.with(|cell| cell.set(true));
        let error = handle.replace_from_snapshot(&snapshot).unwrap_err();
        assert!(
            error.0.starts_with("CORE_E_SNAPSHOT_INTEGRITY"),
            "forced post-copy failure must be typed as integrity: {}",
            error.0
        );

        live.with_writer(|conn| {
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='old-row'"),
                1,
                "old database must be restored after a mid-restore failure"
            );
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='snapshot-row'"),
                0,
                "failed restore must not leave snapshot rows behind"
            );
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
        let restore_old = handle
            .path()
            .with_file_name(format!("{CORE_DB_FILE}.restore-old"));
        assert!(!restore_old.exists(), ".restore-old must be cleaned up");

        // The same handle must still be usable: a later valid restore succeeds.
        let version = handle.replace_from_snapshot(&snapshot).unwrap();
        assert_eq!(version, migration::CORE_SCHEMA_VERSION);
        live.with_writer(|conn| {
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='snapshot-row'"),
                1
            );
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
    }
    #[test]
    fn snapshot_restore_rejects_malformed_files() {
        let (live, files) = live_handle(
            "malformed_live",
            "INSERT INTO channels(key, kind, name) VALUES ('keep', 'custom', 'Keep');",
        );
        let handle = restore_handle(&live, &files);
        let valid = make_snapshot("malformed_src", "");

        let non_sqlite = temp_dir("malformed_garbage").join("snapshot.db");
        std::fs::write(&non_sqlite, b"not a sqlite database at all").unwrap();

        let truncated = temp_dir("malformed_truncated").join("snapshot.db");
        let bytes = std::fs::read(&valid).unwrap();
        std::fs::write(&truncated, &bytes[..bytes.len().min(512)]).unwrap();

        let empty = temp_dir("malformed_empty").join("snapshot.db");
        std::fs::write(&empty, b"").unwrap();

        let directory = temp_dir("malformed_dir");
        std::fs::write(directory.join("unrelated"), b"x").unwrap();

        let cases: [(&str, &Path, &str); 4] = [
            ("non-sqlite bytes", &non_sqlite, SNAPSHOT_SHAPE),
            ("truncated file", &truncated, SNAPSHOT_SHAPE),
            ("empty file", &empty, SNAPSHOT_SHAPE),
            ("directory path", &directory, SNAPSHOT_SHAPE),
        ];
        for (label, path, code) in cases {
            let error = handle.replace_from_snapshot(path).unwrap_err();
            println!("{label}: {}", error.0);
            assert!(
                error.0.starts_with(code),
                "{label}: expected {code}, got {}",
                error.0
            );
            live.with_writer(|conn| {
                assert_eq!(count(conn, "SELECT COUNT(*) FROM channels WHERE key='keep'"), 1);
                assert_integrity_ok(conn);
                Ok(())
            })
            .unwrap();
            assert_eq!(restore_backup_count(&files), 0, "{label}: no backup expected");
        }
    }

    #[test]
    fn snapshot_restore_twice_keeps_distinct_backups() {
        let snapshot = make_snapshot(
            "twice_src",
            "INSERT INTO channels(key, kind, name) VALUES ('snapshot-row', 'custom', 'Snap');",
        );
        let (live, files) = live_handle(
            "twice_live",
            "INSERT INTO channels(key, kind, name) VALUES ('old-row', 'custom', 'Old');",
        );
        let handle = restore_handle(&live, &files);

        handle.replace_from_snapshot(&snapshot).unwrap();
        handle.replace_from_snapshot(&snapshot).unwrap();

        let backup_dir = files.join("migration").join("backups");
        let names: Vec<String> = std::fs::read_dir(&backup_dir)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with("pre-restore-"))
            .collect();
        println!("pre-restore backups: {names:?}");
        assert_eq!(names.len(), 2, "both restores must leave a backup");
        let unique: std::collections::HashSet<_> = names.iter().collect();
        assert_eq!(unique.len(), 2, "second backup must not overwrite the first");
        let restore_old = handle
            .path()
            .with_file_name(format!("{CORE_DB_FILE}.restore-old"));
        assert!(!restore_old.exists(), ".restore-old must not survive");
        live.with_writer(|conn| {
            assert_eq!(
                count(conn, "SELECT COUNT(*) FROM channels WHERE key='snapshot-row'"),
                1
            );
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
    }

    #[test]
    fn snapshot_restore_survives_repeated_interruptions() {
        let snapshot = make_snapshot(
            "interrupt_src",
            "INSERT INTO channels(key, kind, name) VALUES ('snapshot-row', 'custom', 'Snap');",
        );
        let (live, files) = live_handle(
            "interrupt_live",
            "INSERT INTO channels(key, kind, name) VALUES ('old-row', 'custom', 'Old');",
        );
        let handle = restore_handle(&live, &files);

        for attempt in 1..=2 {
            FAIL_RESTORE_AFTER_COPY.with(|cell| cell.set(true));
            let error = handle.replace_from_snapshot(&snapshot).unwrap_err();
            println!("interruption {attempt}: {}", error.0);
            assert!(error.0.starts_with(SNAPSHOT_INTEGRITY));
            live.with_writer(|conn| {
                assert_eq!(
                    count(conn, "SELECT COUNT(*) FROM channels WHERE key='old-row'"),
                    1,
                    "attempt {attempt}: old db must stay open and readable"
                );
                assert_integrity_ok(conn);
                Ok(())
            })
            .unwrap();
            let restore_old = handle
                .path()
                .with_file_name(format!("{CORE_DB_FILE}.restore-old"));
            assert!(!restore_old.exists(), "attempt {attempt}: .restore-old left");
        }
    }

    #[test]
    fn snapshot_restore_handles_multi_megabyte_snapshot() {
        let payload = "x".repeat(2 * 1024 * 1024);
        let snapshot = make_snapshot(
            "large_src",
            &format!(
                "INSERT INTO channels(key, kind, name) VALUES ('large', 'custom', '{payload}');"
            ),
        );
        let snapshot_size = std::fs::metadata(&snapshot).unwrap().len();
        println!("multi-megabyte snapshot size: {snapshot_size} bytes");
        assert!(snapshot_size > 1024 * 1024, "fixture must exceed 1 MiB");

        let (live, files) = live_handle("large_live", "");
        let handle = restore_handle(&live, &files);
        let started = std::time::Instant::now();
        handle.replace_from_snapshot(&snapshot).unwrap();
        println!("restore of {snapshot_size} bytes took {:?}", started.elapsed());
        live.with_writer(|conn| {
            assert_eq!(count(conn, "SELECT COUNT(*) FROM channels WHERE key='large'"), 1);
            assert_integrity_ok(conn);
            Ok(())
        })
        .unwrap();
    }

}
