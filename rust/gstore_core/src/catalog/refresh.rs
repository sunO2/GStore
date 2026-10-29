//! Remote catalog refresh with atomic replacement.
//!
//! The downloaded (or local) database is validated in full before the core is
//! touched. The replace itself only rewrites the three catalog tables and uses
//! `ATTACH DATABASE` so SQLite does the row matching; every other table is left
//! alone. A `VACUUM INTO` backup is taken first and the whole rewrite runs in
//! one `BEGIN IMMEDIATE` transaction, so any failure rolls back to the old
//! catalog. When a refresh leaves the catalog unchanged the report says
//! `changed = false`; the backup is still created because it is taken before
//! the comparison.

use std::collections::HashSet;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OpenFlags, TransactionBehavior};

use crate::db::DbHandle;
use crate::dto::ChannelKey;
use crate::error::Error;
use crate::event::CoreEvent;
use crate::ports::{validate_http_url, HttpOptions, HttpPort};

const SQLITE_HEADER: &[u8; 16] = b"SQLite format 3\0";

const APPS_REQUIRED: [&str; 7] = [
    "appId",
    "name",
    "user",
    "repositories",
    "icon",
    "des",
    "category",
];
const CATEGORY_REQUIRED: [&str; 3] = ["id", "description", "icon"];
const CONFIG_REQUIRED: [&str; 1] = ["version"];

/// Options for a catalog refresh.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CatalogRefreshOptions {
    /// Allow a source with zero `apps` rows. Defaults to `false` because an
    /// empty remote catalog is far more likely to be a bad download than an
    /// intentional wipe.
    pub allow_empty: bool,
}

/// Result of a successful catalog refresh.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CatalogRefreshReport {
    /// Source URL (or path label) used for the refresh.
    pub source_url: String,
    /// Catalog `apps` rows after the refresh.
    pub apps: usize,
    /// Catalog `categories` rows after the refresh.
    pub categories: usize,
    /// Catalog `app_config` rows after the refresh.
    pub configs: usize,
    /// Rows in the `apps_fts` index after the refresh.
    pub fts_rows: usize,
    /// Timestamped backup created before the replace.
    pub backup: Option<String>,
    /// Whether the replace changed any row.
    pub changed: bool,
}

/// Downloads `url` via `http`, writes it to a temp DB next to the core DB,
/// validates it, then atomically replaces the catalog rows.
///
/// # Errors
/// Returns [`Error::Network`] for a failed request, [`Error::InvalidArgument`]
/// for an empty body or invalid source database, and [`Error::Io`] for local
/// filesystem/database failures.
pub fn refresh_catalog(
    db: &DbHandle,
    http: &dyn HttpPort,
    url: &str,
) -> Result<CatalogRefreshReport, Error> {
    refresh_catalog_with_options(db, http, url, &CatalogRefreshOptions::default())
}

/// [`refresh_catalog`] with explicit options.
///
/// # Errors
/// See [`refresh_catalog`].
pub fn refresh_catalog_with_options(
    db: &DbHandle,
    http: &dyn HttpPort,
    url: &str,
    options: &CatalogRefreshOptions,
) -> Result<CatalogRefreshReport, Error> {
    validate_http_url(url)?;
    let response = http.get(url, &HttpOptions::default())?;
    if !response.is_success() {
        return Err(Error::Network(format!(
            "CORE_E_CATALOG_REFRESH_HTTP: status {} for {url}",
            response.status
        )));
    }
    if response.body.is_empty() {
        return Err(Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_BODY: empty body from {url}"
        )));
    }

    let temp = TempDownload::create(db.path(), &response.body)?;
    replace_catalog_from_db_with_options(db, temp.path(), url, options)
}

/// Same replace/validate path for an already-downloaded DB file (testable,
/// used by the CLI). `source_url` is only a report label.
///
/// # Errors
/// Returns [`Error::InvalidArgument`] when the source is not a valid catalog and
/// [`Error::Io`] for backup/attach/transaction failures.
pub fn replace_catalog_from_db(
    db: &DbHandle,
    source: &Path,
    source_url: &str,
) -> Result<CatalogRefreshReport, Error> {
    replace_catalog_from_db_with_options(db, source, source_url, &CatalogRefreshOptions::default())
}

/// [`replace_catalog_from_db`] with explicit options.
///
/// # Errors
/// See [`replace_catalog_from_db`].
pub fn replace_catalog_from_db_with_options(
    db: &DbHandle,
    source: &Path,
    source_url: &str,
    options: &CatalogRefreshOptions,
) -> Result<CatalogRefreshReport, Error> {
    let shape = validate_source(source, options.allow_empty)?;

    let mut writer = db
        .writer()
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_REFRESH_DB: {e}")))?;
    let backup = backup_core_db(&writer, db.path())?;

    writer
        .execute(
            "ATTACH DATABASE ?1 AS src",
            params![source.to_string_lossy().into_owned()],
        )
        .map_err(|e| {
            Error::Io(format!(
                "CORE_E_CATALOG_REFRESH_ATTACH: {}: {e}",
                source.display()
            ))
        })?;

    let before = writer.total_changes();
    let replace_result = replace_in_transaction(&mut writer, &shape);
    let after = writer.total_changes();
    if let Err(error) = writer.execute("DETACH DATABASE src", []) {
        log::warn!("CORE_E_CATALOG_REFRESH_DETACH: {error}");
    }
    replace_result?;

    let apps = count_rows(&writer, "apps")?;
    let categories = count_rows(&writer, "categories")?;
    let configs = count_rows(&writer, "app_config")?;
    let fts_rows = count_rows(&writer, "apps_fts")?;

    Ok(CatalogRefreshReport {
        source_url: source_url.to_string(),
        apps,
        categories,
        configs,
        fts_rows,
        backup: Some(backup.display().to_string()),
        changed: after > before,
    })
}

/// Returns the `catalog.changed` event for the global local catalog.
///
/// The FRB/Android layer pushes this after a successful changed refresh.
///
/// # Errors
/// Returns [`Error::InvalidArgument`] if the fixed key cannot be built.
pub fn catalog_changed_event() -> Result<CoreEvent, Error> {
    Ok(CoreEvent::CatalogChanged {
        key: ChannelKey::new("local_db")?,
        app_id: None,
        removed: false,
    })
}

// ---------------------------------------------------------------------------
// Download temp file
// ---------------------------------------------------------------------------

/// Temp download that removes itself on every exit path.
struct TempDownload {
    path: PathBuf,
}

impl TempDownload {
    fn create(core: &Path, bytes: &[u8]) -> Result<Self, Error> {
        let parent = core
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .map_or_else(|| PathBuf::from("."), Path::to_path_buf);
        std::fs::create_dir_all(&parent).map_err(|e| {
            Error::Io(format!(
                "CORE_E_CATALOG_REFRESH_TEMP: create {}: {e}",
                parent.display()
            ))
        })?;

        let base = format!("{}.refresh-{}.db", core.display(), now_nanos()?);
        let mut attempt = 0_u32;
        loop {
            let candidate = if attempt == 0 {
                PathBuf::from(&base)
            } else {
                PathBuf::from(format!("{base}-{attempt}"))
            };
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&candidate)
            {
                Ok(mut file) => {
                    if let Err(error) = file.write_all(bytes) {
                        let _ = std::fs::remove_file(&candidate);
                        return Err(Error::Io(format!(
                            "CORE_E_CATALOG_REFRESH_TEMP: write {}: {error}",
                            candidate.display()
                        )));
                    }
                    return Ok(Self { path: candidate });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    attempt += 1;
                }
                Err(error) => {
                    return Err(Error::Io(format!(
                        "CORE_E_CATALOG_REFRESH_TEMP: create {}: {error}",
                        candidate.display()
                    )));
                }
            }
        }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDownload {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn now_nanos() -> Result<u128, Error> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_REFRESH_CLOCK: {e}")))
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

pub(crate) struct SourceShape {
    has_readme: bool,
    has_extra: bool,
    has_proxy: bool,
}

/// Full structural validation of a catalog source database (SQLite header,
/// integrity, required tables/columns, non-empty apps, unique ids, and config).
///
/// Shared by the refresh/direct-replace path and the filesystem catalog
/// repository so both reject exactly the same malformed sources. The returned
/// shape records which optional columns are present.
pub(crate) fn validate_source(path: &Path, allow_empty: bool) -> Result<SourceShape, Error> {
    validate_header(path)?;
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| {
        Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_OPEN: {}: {e}",
            path.display()
        ))
    })?;

    let integrity: String = conn
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_INTEGRITY: {}: {e}",
                path.display()
            ))
        })?;
    if integrity != "ok" {
        return Err(Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_INTEGRITY: {} returned {integrity}",
            path.display()
        )));
    }

    let apps_columns = table_columns(&conn, "apps", path)?;
    let category_columns = table_columns(&conn, "category", path)?;
    let config_columns = table_columns(&conn, "config", path)?;
    require_columns("apps", &apps_columns, &APPS_REQUIRED)?;
    require_columns("category", &category_columns, &CATEGORY_REQUIRED)?;
    require_columns("config", &config_columns, &CONFIG_REQUIRED)?;

    let has_readme = has_column(&apps_columns, "readme");
    let has_extra = has_column(&apps_columns, "extra");
    let has_proxy = has_column(&config_columns, "proxy");

    let apps = validate_apps(&conn, has_readme, has_extra, path)?;
    if apps == 0 && !allow_empty {
        return Err(Error::InvalidArgument(
            "CORE_E_CATALOG_REFRESH_EMPTY: source catalog has no apps".to_string(),
        ));
    }
    validate_categories(&conn, path)?;
    validate_configs(&conn, path)?;

    Ok(SourceShape {
        has_readme,
        has_extra,
        has_proxy,
    })
}

/// Reads `config.version` from a catalog source database (read-only).
///
/// # Errors
/// Returns [`Error::InvalidArgument`] when the database cannot be opened or has
/// no `version` row.
pub(crate) fn read_catalog_version(path: &Path) -> Result<String, Error> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| {
        Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REPO_VERSION: {}: {e}",
            path.display()
        ))
    })?;
    conn.query_row("SELECT \"version\" FROM config LIMIT 1", [], |row| {
        row.get(0)
    })
    .map_err(|e| {
        Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REPO_VERSION: {}: {e}",
            path.display()
        ))
    })
}

/// Counts `apps` and `category` rows in a catalog source database (read-only).
pub(crate) fn read_catalog_counts(path: &Path) -> Result<(usize, usize), Error> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| {
        Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REPO_READ: {}: {e}",
            path.display()
        ))
    })?;
    Ok((count_rows(&conn, "apps")?, count_rows(&conn, "category")?))
}

fn validate_header(path: &Path) -> Result<(), Error> {
    let mut file = File::open(path).map_err(|e| {
        Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_OPEN: {}: {e}",
            path.display()
        ))
    })?;
    let mut header = [0_u8; 16];
    file.read_exact(&mut header).map_err(|e| {
        Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_HEADER: {} is not a SQLite database: {e}",
            path.display()
        ))
    })?;
    if header != *SQLITE_HEADER {
        return Err(Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_HEADER: {} does not start with the SQLite header",
            path.display()
        )));
    }
    Ok(())
}

fn table_columns(conn: &Connection, table: &str, path: &Path) -> Result<Vec<String>, Error> {
    let sql = format!("PRAGMA table_info(\"{}\")", quote(table));
    let mut stmt = conn.prepare(&sql).map_err(|e| {
        Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_TABLE: {} table_info {table}: {e}",
            path.display()
        ))
    })?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1)).map_err(|e| {
        Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_TABLE: {} table_info {table}: {e}",
            path.display()
        ))
    })?;
    let mut columns = Vec::new();
    for row in rows {
        columns.push(row.map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_TABLE: {} table_info {table}: {e}",
                path.display()
            ))
        })?);
    }
    Ok(columns)
}

fn require_columns(table: &str, columns: &[String], required: &[&str]) -> Result<(), Error> {
    if columns.is_empty() {
        return Err(Error::InvalidArgument(format!(
            "CORE_E_CATALOG_REFRESH_TABLE: missing required table {table}"
        )));
    }
    for column in required {
        if !has_column(columns, column) {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_COLUMN: {table} is missing required column {column}"
            )));
        }
    }
    Ok(())
}

fn has_column(columns: &[String], column: &str) -> bool {
    columns.iter().any(|candidate| candidate == column)
}

fn validate_apps(
    conn: &Connection,
    has_readme: bool,
    has_extra: bool,
    path: &Path,
) -> Result<usize, Error> {
    let readme = if has_readme { "\"readme\"" } else { "NULL" };
    let extra = if has_extra { "\"extra\"" } else { "NULL" };
    let sql = format!("SELECT \"appId\", \"name\", {readme}, {extra} FROM apps");
    let mut stmt = conn.prepare(&sql).map_err(|e| rows_error(path, "apps", e))?;
    let mut rows = stmt.query([]).map_err(|e| rows_error(path, "apps", e))?;

    let mut seen = HashSet::new();
    let mut count = 0_usize;
    let mut index = 0_usize;
    while let Some(row) = rows.next().map_err(|e| rows_error(path, "apps", e))? {
        let app_id: Option<String> = row.get(0).map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_ROW: apps row {index} appId: {e}"
            ))
        })?;
        let name: Option<String> = row.get(1).map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_ROW: apps row {index} name: {e}"
            ))
        })?;
        let _readme: Option<String> = row.get(2).map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_ROW: apps row {index} readme: {e}"
            ))
        })?;
        let _extra: Option<String> = row.get(3).map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_ROW: apps row {index} extra: {e}"
            ))
        })?;

        let app_id = app_id.filter(|id| !id.is_empty()).ok_or_else(|| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_APP_ID: apps row {index} has a NULL or empty appId"
            ))
        })?;
        if !seen.insert(app_id.clone()) {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_APP_ID: duplicate appId {app_id}"
            )));
        }
        if name.as_deref().is_none_or(str::is_empty) {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_NAME: app {app_id} has a NULL or empty name"
            )));
        }

        count += 1;
        index += 1;
    }
    Ok(count)
}

fn validate_categories(conn: &Connection, path: &Path) -> Result<usize, Error> {
    let mut stmt = conn
        .prepare("SELECT \"id\", \"description\", \"icon\" FROM category")
        .map_err(|e| rows_error(path, "category", e))?;
    let mut rows = stmt
        .query([])
        .map_err(|e| rows_error(path, "category", e))?;
    let mut seen = HashSet::new();
    let mut count = 0_usize;
    let mut index = 0_usize;
    while let Some(row) = rows.next().map_err(|e| rows_error(path, "category", e))? {
        let id: Option<String> = row.get(0).map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_ROW: category row {index} id: {e}"
            ))
        })?;
        let _description: Option<String> = row.get(1).map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_ROW: category row {index} description: {e}"
            ))
        })?;
        let _icon: Option<String> = row.get(2).map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_ROW: category row {index} icon: {e}"
            ))
        })?;

        let id = id.filter(|id| !id.is_empty()).ok_or_else(|| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_CATEGORY: category row {index} has a NULL or empty id"
            ))
        })?;
        if !seen.insert(id.clone()) {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_CATEGORY: duplicate category id {id}"
            )));
        }

        count += 1;
        index += 1;
    }
    Ok(count)
}

fn validate_configs(conn: &Connection, path: &Path) -> Result<usize, Error> {
    let mut stmt = conn
        .prepare("SELECT \"version\" FROM config")
        .map_err(|e| rows_error(path, "config", e))?;
    let mut rows = stmt
        .query([])
        .map_err(|e| rows_error(path, "config", e))?;
    let mut seen = HashSet::new();
    let mut count = 0_usize;
    let mut index = 0_usize;
    while let Some(row) = rows.next().map_err(|e| rows_error(path, "config", e))? {
        let version: Option<String> = row.get(0).map_err(|e| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_ROW: config row {index} version: {e}"
            ))
        })?;
        let version = version.filter(|value| !value.is_empty()).ok_or_else(|| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_CONFIG: config row {index} has a NULL or empty version"
            ))
        })?;
        if !seen.insert(version.clone()) {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REFRESH_CONFIG: duplicate config version {version}"
            )));
        }

        count += 1;
        index += 1;
    }
    Ok(count)
}

fn rows_error(path: &Path, table: &str, error: rusqlite::Error) -> Error {
    Error::InvalidArgument(format!(
        "CORE_E_CATALOG_REFRESH_READ: {} {table}: {error}",
        path.display()
    ))
}

// ---------------------------------------------------------------------------
// Backup and replace
// ---------------------------------------------------------------------------

fn backup_core_db(conn: &Connection, core: &Path) -> Result<PathBuf, Error> {
    let base = format!("{}.bak-refresh-{}", core.display(), now_nanos()?);
    let mut destination = PathBuf::from(&base);
    let mut attempt = 0_u32;
    while destination.exists() {
        attempt += 1;
        destination = PathBuf::from(format!("{base}-{attempt}"));
    }
    conn.execute(
        "VACUUM INTO ?1",
        params![destination.to_string_lossy().into_owned()],
    )
    .map_err(|e| {
        Error::Io(format!(
            "CORE_E_CATALOG_REFRESH_BACKUP: {}: {e}",
            destination.display()
        ))
    })?;
    Ok(destination)
}

fn replace_in_transaction(conn: &mut Connection, shape: &SourceShape) -> Result<(), Error> {
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_REFRESH_TX: begin: {e}")))?;
    match write_projection(&tx, shape) {
        Ok(()) => {
            crate::migration::mark_core_write_if_flipped(&tx, "catalog", None)
                .map_err(|e| Error::Io(format!("CORE_E_CATALOG_REFRESH_TX: marker: {}", e.0)))?;
            tx.commit()
                .map_err(|e| Error::Io(format!("CORE_E_CATALOG_REFRESH_TX: commit: {e}")))
        }
        Err(error) => {
            drop(tx);
            Err(error)
        }
    }
}

fn write_projection(conn: &Connection, shape: &SourceShape) -> Result<(), Error> {
    let readme = if shape.has_readme { "\"readme\"" } else { "NULL" };
    let extra = if shape.has_extra { "\"extra\"" } else { "NULL" };
    let proxy = if shape.has_proxy { "\"proxy\"" } else { "NULL" };

    conn.execute(
        "DELETE FROM apps WHERE NOT EXISTS \
         (SELECT 1 FROM src.apps AS source WHERE source.\"appId\" = apps.\"appId\")",
        [],
    )
    .map_err(|e| tx_error("delete apps", e))?;
    let upsert_apps = format!(
        "INSERT INTO apps(appId, name, user, repositories, icon, des, readme, category, extra) \
         SELECT \"appId\", \"name\", \"user\", \"repositories\", \"icon\", \"des\", {readme}, \
         \"category\", {extra} FROM src.apps WHERE 1 \
         ON CONFLICT(\"appId\") DO UPDATE SET \
         name = excluded.name, user = excluded.user, repositories = excluded.repositories, \
         icon = excluded.icon, des = excluded.des, readme = excluded.readme, \
         category = excluded.category, extra = excluded.extra \
         WHERE NOT (apps.name IS excluded.name AND apps.user IS excluded.user \
         AND apps.repositories IS excluded.repositories AND apps.icon IS excluded.icon \
         AND apps.des IS excluded.des AND apps.readme IS excluded.readme \
         AND apps.category IS excluded.category AND apps.extra IS excluded.extra)"
    );
    conn.execute(&upsert_apps, [])
        .map_err(|e| tx_error("upsert apps", e))?;

    conn.execute(
        "DELETE FROM categories WHERE NOT EXISTS \
         (SELECT 1 FROM src.category AS source WHERE source.\"id\" = categories.\"id\")",
        [],
    )
    .map_err(|e| tx_error("delete categories", e))?;
    conn.execute(
        "INSERT INTO categories(id, description, icon) \
         SELECT \"id\", \"description\", \"icon\" FROM src.category WHERE 1 \
         ON CONFLICT(\"id\") DO UPDATE SET \
         description = excluded.description, icon = excluded.icon \
         WHERE NOT (categories.description IS excluded.description \
         AND categories.icon IS excluded.icon)",
        [],
    )
    .map_err(|e| tx_error("upsert categories", e))?;

    conn.execute(
        "DELETE FROM app_config WHERE NOT EXISTS \
         (SELECT 1 FROM src.config AS source WHERE source.\"version\" = app_config.\"version\")",
        [],
    )
    .map_err(|e| tx_error("delete app_config", e))?;
    let upsert_configs = format!(
        "INSERT INTO app_config(version, proxy) \
         SELECT \"version\", {proxy} FROM src.config WHERE 1 \
         ON CONFLICT(\"version\") DO UPDATE SET proxy = excluded.proxy \
         WHERE NOT (app_config.proxy IS excluded.proxy)"
    );
    conn.execute(&upsert_configs, [])
        .map_err(|e| tx_error("upsert app_config", e))?;

    Ok(())
}

fn tx_error(context: &str, error: rusqlite::Error) -> Error {
    Error::Io(format!("CORE_E_CATALOG_REFRESH_TX: {context}: {error}"))
}

fn count_rows(conn: &Connection, table: &str) -> Result<usize, Error> {
    let sql = format!("SELECT COUNT(*) FROM \"{}\"", quote(table));
    let count: i64 = conn
        .query_row(&sql, [], |row| row.get(0))
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_REFRESH_READ: count {table}: {e}")))?;
    usize::try_from(count)
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_REFRESH_READ: count {table}: {e}")))
}

fn quote(name: &str) -> String {
    name.replace('"', "\"\"")
}
