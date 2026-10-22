//! Catalog import from the Dart `apps.db` (live or bundled seed).
//!
//! The live copy (under the application documents directory) is preferred and
//! the bundled seed is the fallback. The source is validated in full and read
//! into memory before the core catalog is touched, so a malformed source can
//! never leave a partial catalog behind.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use rusqlite::{params, Connection, OpenFlags, TransactionBehavior};

use crate::db::DbHandle;
use crate::error::Error;

/// Kind label for a live source database.
pub const SOURCE_LIVE: &str = "live";
/// Kind label for the bundled seed database.
pub const SOURCE_SEED: &str = "seed";

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

/// Options for [`import_catalog`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CatalogImportOptions {
    /// Count and validate the source without touching the core database.
    pub dry_run: bool,
}

/// Result of an [`import_catalog`] run.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CatalogImportReport {
    /// Resolved source path.
    pub source: String,
    /// `"live"` or `"seed"`.
    pub source_kind: String,
    /// Imported `apps` row count.
    pub apps: usize,
    /// Imported `categories` row count.
    pub categories: usize,
    /// Imported `app_config` row count.
    pub configs: usize,
    /// Rows in the core `apps_fts` index.
    pub fts_rows: usize,
    /// Timestamped backup created before replacing the catalog, if any.
    pub backup: Option<String>,
    /// Whether the run only counted the source.
    pub dry_run: bool,
}

/// Resolves the live-first / seed-fallback source.
///
/// Returns the chosen path and its kind. A live path that does not exist (or is
/// not a regular file) falls back to the seed; neither present is
/// [`Error::NotFound`].
pub fn resolve_source(live: Option<&Path>, seed: &Path) -> Result<(PathBuf, &'static str), Error> {
    if let Some(live) = live {
        if live.is_file() {
            return Ok((live.to_path_buf(), SOURCE_LIVE));
        }
    }
    if seed.is_file() {
        return Ok((seed.to_path_buf(), SOURCE_SEED));
    }
    Err(Error::NotFound(format!(
        "CORE_E_CATALOG_SOURCE: no live catalog at {} and no seed at {}",
        live.map_or_else(|| "<none>".to_string(), |path| path.display().to_string()),
        seed.display()
    )))
}

/// Imports the catalog into the core database.
///
/// Live-first with seed fallback. The source is validated and fully read before
/// any mutation. On a non-dry run the core is backed up with
/// `VACUUM INTO '<core>.bak-import-<nanos>'` and then replaced in one
/// `BEGIN IMMEDIATE` transaction; any error rolls the transaction back.
pub fn import_catalog(
    db: &DbHandle,
    live: Option<&Path>,
    seed: &Path,
    options: &CatalogImportOptions,
) -> Result<CatalogImportReport, Error> {
    let (source_path, source_kind) = resolve_source(live, seed)?;
    let snapshot = {
        let source = open_source(&source_path)?;
        read_source(&source, &source_path)?
    };
    let apps = snapshot.apps.len();
    let categories = snapshot.categories.len();
    let configs = snapshot.configs.len();

    if options.dry_run {
        return Ok(CatalogImportReport {
            source: source_path.display().to_string(),
            source_kind: source_kind.to_string(),
            apps,
            categories,
            configs,
            fts_rows: apps,
            backup: None,
            dry_run: true,
        });
    }

    let mut writer = db
        .writer()
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_DB: {e}")))?;
    let backup = backup_core_db(&writer, db.path())?;
    write_catalog(&mut writer, &snapshot)?;

    let apps = count_rows(&writer, "apps")?;
    let categories = count_rows(&writer, "categories")?;
    let configs = count_rows(&writer, "app_config")?;
    let fts_rows: i64 = writer
        .query_row("SELECT COUNT(*) FROM apps_fts", [], |row| row.get(0))
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_READ: count apps_fts: {e}")))?;

    Ok(CatalogImportReport {
        source: source_path.display().to_string(),
        source_kind: source_kind.to_string(),
        apps: as_usize(apps, "apps")?,
        categories: as_usize(categories, "categories")?,
        configs: as_usize(configs, "configs")?,
        fts_rows: as_usize(fts_rows, "fts_rows")?,
        backup: Some(backup.display().to_string()),
        dry_run: false,
    })
}

fn as_usize(value: i64, label: &str) -> Result<usize, Error> {
    usize::try_from(value)
        .map_err(|e| Error::Internal(format!("CORE_E_CATALOG_COUNT: {label}: {e}")))
}

fn count_rows(conn: &Connection, table: &str) -> Result<i64, Error> {
    let sql = format!("SELECT COUNT(*) FROM \"{}\"", table.replace('"', "\"\""));
    conn.query_row(&sql, [], |row| row.get(0))
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_READ: count {table}: {e}")))
}

fn open_source(path: &Path) -> Result<Connection, Error> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_OPEN: {}: {e}", path.display())))
}

fn source_error(context: &str, path: &Path, error: rusqlite::Error) -> Error {
    Error::InvalidArgument(format!(
        "CORE_E_CATALOG_SOURCE: {context} {}: {error}",
        path.display()
    ))
}

fn row_error(table: &str, index: usize, column: &str, error: rusqlite::Error) -> Error {
    Error::InvalidArgument(format!(
        "CORE_E_CATALOG_ROW: {table} row {index} column {column}: {error}"
    ))
}

fn table_columns(conn: &Connection, table: &str, path: &Path) -> Result<Vec<String>, Error> {
    let sql = format!("PRAGMA table_info(\"{}\")", table.replace('"', "\"\""));
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| source_error("table_info", path, e))?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| source_error("table_info", path, e))?;
    let mut columns = Vec::new();
    for row in rows {
        columns.push(row.map_err(|e| source_error("table_info", path, e))?);
    }
    Ok(columns)
}

fn require_columns(table: &str, columns: &[String], required: &[&str]) -> Result<(), Error> {
    if columns.is_empty() {
        return Err(Error::InvalidArgument(format!(
            "CORE_E_CATALOG_TABLE: missing required table {table}"
        )));
    }
    for column in required {
        if !columns.iter().any(|candidate| candidate == column) {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_CATALOG_COLUMN: {table} is missing required column {column}"
            )));
        }
    }
    Ok(())
}

fn has_column(columns: &[String], column: &str) -> bool {
    columns.iter().any(|candidate| candidate == column)
}

fn read_source(conn: &Connection, path: &Path) -> Result<SourceCatalog, Error> {
    let integrity: String = conn
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|e| source_error("integrity_check", path, e))?;
    if integrity != "ok" {
        return Err(Error::InvalidArgument(format!(
            "CORE_E_CATALOG_INTEGRITY: {} returned {integrity}",
            path.display()
        )));
    }

    let apps_columns = table_columns(conn, "apps", path)?;
    let category_columns = table_columns(conn, "category", path)?;
    let config_columns = table_columns(conn, "config", path)?;
    require_columns("apps", &apps_columns, &APPS_REQUIRED)?;
    require_columns("category", &category_columns, &CATEGORY_REQUIRED)?;
    require_columns("config", &config_columns, &CONFIG_REQUIRED)?;

    Ok(SourceCatalog {
        apps: read_apps(conn, &apps_columns, path)?,
        categories: read_categories(conn, path)?,
        configs: read_configs(conn, &config_columns, path)?,
    })
}

fn read_apps(conn: &Connection, columns: &[String], path: &Path) -> Result<Vec<SourceApp>, Error> {
    let readme = if has_column(columns, "readme") {
        "\"readme\""
    } else {
        "NULL"
    };
    let extra = if has_column(columns, "extra") {
        "\"extra\""
    } else {
        "NULL"
    };
    let sql = format!(
        "SELECT \"appId\", \"name\", \"user\", \"repositories\", \"icon\", \"des\", \
         {readme}, \"category\", {extra} FROM apps"
    );
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| source_error("read apps", path, e))?;
    let mut rows = stmt
        .query([])
        .map_err(|e| source_error("read apps", path, e))?;

    let mut apps = Vec::new();
    let mut seen = HashSet::new();
    let mut index = 0usize;
    while let Some(row) = rows
        .next()
        .map_err(|e| source_error("read apps", path, e))?
    {
        let app_id: Option<String> = row
            .get(0)
            .map_err(|e| row_error("apps", index, "appId", e))?;
        let name: String = row
            .get(1)
            .map_err(|e| row_error("apps", index, "name", e))?;
        let user: Option<String> = row
            .get(2)
            .map_err(|e| row_error("apps", index, "user", e))?;
        let repositories: Option<String> = row
            .get(3)
            .map_err(|e| row_error("apps", index, "repositories", e))?;
        let icon: Option<String> = row
            .get(4)
            .map_err(|e| row_error("apps", index, "icon", e))?;
        let des: Option<String> = row.get(5).map_err(|e| row_error("apps", index, "des", e))?;
        let readme: Option<String> = row
            .get(6)
            .map_err(|e| row_error("apps", index, "readme", e))?;
        let category: Option<String> = row
            .get(7)
            .map_err(|e| row_error("apps", index, "category", e))?;
        let extra: Option<String> = row
            .get(8)
            .map_err(|e| row_error("apps", index, "extra", e))?;

        let app_id = app_id.filter(|id| !id.is_empty()).ok_or_else(|| {
            Error::InvalidArgument(format!(
                "CORE_E_CATALOG_APP_ID: apps row {index} has a NULL or empty appId"
            ))
        })?;
        if !seen.insert(app_id.clone()) {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_CATALOG_APP_ID: duplicate appId {app_id}"
            )));
        }
        apps.push(SourceApp {
            app_id,
            name,
            user,
            repositories,
            icon,
            des,
            readme,
            category,
            extra,
        });
        index += 1;
    }
    Ok(apps)
}

fn read_categories(conn: &Connection, path: &Path) -> Result<Vec<SourceCategory>, Error> {
    let mut stmt = conn
        .prepare("SELECT \"id\", \"description\", \"icon\" FROM category")
        .map_err(|e| source_error("read category", path, e))?;
    let mut rows = stmt
        .query([])
        .map_err(|e| source_error("read category", path, e))?;
    let mut categories = Vec::new();
    let mut index = 0usize;
    while let Some(row) = rows
        .next()
        .map_err(|e| source_error("read category", path, e))?
    {
        let id: String = row
            .get(0)
            .map_err(|e| row_error("category", index, "id", e))?;
        let description: String = row
            .get(1)
            .map_err(|e| row_error("category", index, "description", e))?;
        let icon: String = row
            .get(2)
            .map_err(|e| row_error("category", index, "icon", e))?;
        categories.push(SourceCategory {
            id,
            description,
            icon,
        });
        index += 1;
    }
    Ok(categories)
}

fn read_configs(
    conn: &Connection,
    columns: &[String],
    path: &Path,
) -> Result<Vec<SourceConfig>, Error> {
    let proxy = if has_column(columns, "proxy") {
        "\"proxy\""
    } else {
        "NULL"
    };
    let sql = format!("SELECT \"version\", {proxy} FROM config");
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| source_error("read config", path, e))?;
    let mut rows = stmt
        .query([])
        .map_err(|e| source_error("read config", path, e))?;
    let mut configs = Vec::new();
    let mut index = 0usize;
    while let Some(row) = rows
        .next()
        .map_err(|e| source_error("read config", path, e))?
    {
        let version: String = row
            .get(0)
            .map_err(|e| row_error("config", index, "version", e))?;
        let proxy: Option<String> = row
            .get(1)
            .map_err(|e| row_error("config", index, "proxy", e))?;
        configs.push(SourceConfig { version, proxy });
        index += 1;
    }
    Ok(configs)
}

fn backup_core_db(conn: &Connection, core: &Path) -> Result<PathBuf, Error> {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_BACKUP: clock: {e}")))?
        .as_nanos();
    let base = format!("{}.bak-import-{nanos}", core.display());
    let mut destination = PathBuf::from(&base);
    let mut attempt = 0u32;
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
            "CORE_E_CATALOG_BACKUP: {}: {e}",
            destination.display()
        ))
    })?;
    Ok(destination)
}

fn write_catalog(conn: &mut Connection, snapshot: &SourceCatalog) -> Result<(), Error> {
    let tx = conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: begin: {e}")))?;

    tx.execute("DELETE FROM apps", [])
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: delete apps: {e}")))?;
    tx.execute("DELETE FROM categories", [])
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: delete categories: {e}")))?;
    tx.execute("DELETE FROM app_config", [])
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: delete app_config: {e}")))?;

    {
        let mut stmt = tx
            .prepare(
                "INSERT INTO apps(appId, name, user, repositories, icon, des, readme, \
                 category, extra) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )
            .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: prepare apps: {e}")))?;
        for app in &snapshot.apps {
            stmt.execute(params![
                app.app_id,
                app.name,
                app.user,
                app.repositories,
                app.icon,
                app.des,
                app.readme,
                app.category,
                app.extra,
            ])
            .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: insert app {}: {e}", app.app_id)))?;
        }
    }

    {
        let mut stmt = tx
            .prepare("INSERT INTO categories(id, description, icon) VALUES (?1, ?2, ?3)")
            .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: prepare categories: {e}")))?;
        for category in &snapshot.categories {
            stmt.execute(params![category.id, category.description, category.icon])
                .map_err(|e| {
                    Error::Io(format!(
                        "CORE_E_CATALOG_TX: insert category {}: {e}",
                        category.id
                    ))
                })?;
        }
    }

    {
        let mut stmt = tx
            .prepare("INSERT INTO app_config(version, proxy) VALUES (?1, ?2)")
            .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: prepare app_config: {e}")))?;
        for config in &snapshot.configs {
            stmt.execute(params![config.version, config.proxy])
                .map_err(|e| {
                    Error::Io(format!(
                        "CORE_E_CATALOG_TX: insert config {}: {e}",
                        config.version
                    ))
                })?;
        }
    }

    tx.commit()
        .map_err(|e| Error::Io(format!("CORE_E_CATALOG_TX: commit: {e}")))
}

struct SourceCatalog {
    apps: Vec<SourceApp>,
    categories: Vec<SourceCategory>,
    configs: Vec<SourceConfig>,
}

struct SourceApp {
    app_id: String,
    name: String,
    user: Option<String>,
    repositories: Option<String>,
    icon: Option<String>,
    des: Option<String>,
    readme: Option<String>,
    category: Option<String>,
    extra: Option<String>,
}

struct SourceCategory {
    id: String,
    description: String,
    icon: String,
}

struct SourceConfig {
    version: String,
    proxy: Option<String>,
}
