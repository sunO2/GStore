//! Catalog refresh contract: atomic replace of only the catalog tables,
//! download failure handling, validation failure preservation, mid-write
//! rollback, empty-source policy, optional columns, and no-op detection.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::catalog::refresh::{
    catalog_changed_event, refresh_catalog, replace_catalog_from_db,
    replace_catalog_from_db_with_options, CatalogRefreshOptions,
};
use gstore_core::db::DbHandle;
use gstore_core::error::Error;
use gstore_core::event::CoreEvent;
use gstore_core::ports::{FakeHttpPort, HttpOptions, HttpPort, HttpResponse};
use rusqlite::{Connection, OpenFlags};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_refresh_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

type AppRow = (
    String,
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
);
type CategoryRow = (String, String, String);
type ConfigRow = (String, Option<String>);
type CatalogState = (Vec<AppRow>, Vec<CategoryRow>, Vec<ConfigRow>, i64);

const FULL_APPS_SQL: &str = "SELECT \"appId\", \"name\", \"user\", \"repositories\", \
     \"icon\", \"des\", \"readme\", \"category\", \"extra\" FROM apps ORDER BY \"appId\"";

const CATEGORY_SQL: &str = "SELECT id, description, icon FROM categories ORDER BY id";
const SOURCE_CATEGORY_SQL: &str = "SELECT id, description, icon FROM category ORDER BY id";
const CONFIG_SQL: &str = "SELECT version, proxy FROM app_config ORDER BY version";
const SOURCE_CONFIG_SQL: &str = "SELECT version, proxy FROM config ORDER BY version";

const FULL_SOURCE_SQL: &str = "
CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
 repositories TEXT, icon TEXT, des TEXT, readme TEXT, category TEXT, extra TEXT);
CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL);
CREATE TABLE config(version TEXT PRIMARY KEY, proxy TEXT);
INSERT INTO apps VALUES ('com.b', 'BetaRenamed', 'ub', 'rb', 'ib', 'new beta desc', \
 'beta readme', 'TOOLS', '{\"v\":2}');
INSERT INTO apps VALUES ('com.c', 'GammaNew', NULL, NULL, NULL, 'gamma desc', NULL, \
 'NEWS', NULL);
INSERT INTO category VALUES ('TOOLS', 'Tools v2', 'tools2');
INSERT INTO category VALUES ('NEWS', 'News', 'news');
INSERT INTO config VALUES ('9.9.9', NULL);
";

fn open_core(dir: &Path) -> DbHandle {
    DbHandle::open_at(&dir.join("gstore_core.db")).expect("open core database")
}

fn create_source(path: &Path, sql: &str) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(sql).unwrap();
}

fn prepopulate_old_catalog(core: &DbHandle) {
    let conn = core.writer().unwrap();
    conn.execute_batch(
        "INSERT INTO apps(appId, name, user, repositories, icon, des, readme, category, extra) \
         VALUES ('com.a', 'OldAlpha', 'ua', 'ra', 'ia', 'old alpha desc', NULL, 'OLD', NULL); \
         INSERT INTO apps(appId, name, user, repositories, icon, des, readme, category, extra) \
         VALUES ('com.b', 'OldBetaUnique', 'ub', 'rb', 'ib', 'old beta desc', NULL, 'OLD', NULL); \
         INSERT INTO categories(id, description, icon) VALUES ('OLD', 'Old category', 'old-icon'); \
         INSERT INTO app_config(version, proxy) VALUES ('1.1.1', NULL);",
    )
    .unwrap();
}

fn prepopulate_non_catalog(core: &DbHandle) {
    let conn = core.writer().unwrap();
    conn.execute_batch(
        "INSERT INTO channels(key, kind, name, description, enabled, priority, support_offline, \
         last_update_time, version) \
         VALUES ('local_db', 'local_db', 'Local', 'local catalog', 1, 1, 1, 123, 'v1'); \
         INSERT INTO channel_env(channel_key, env_json, imported_at) \
         VALUES ('local_db', '{\"k\":\"v\"}', 123); \
         INSERT INTO channel_state(key, ready, app_count, updated_at) \
         VALUES ('local_db', 1, 1, 123); \
         INSERT INTO channel_apps(channel_key, app_id, name, user, repositories, icon, \
         description, category, add_time) \
         VALUES ('local_db', 'keep.app', 'Keep App', 'u', 'r', 'i', 'd', 'TOOLS', 123); \
         INSERT INTO channel_packs(key, pack_hash, meta_json, installed_at) \
         VALUES ('pack.one', 'hash', '{\"m\":1}', 123); \
         INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
         VALUES ('local_db', 'added.app', 123, 1, 1); \
         INSERT INTO added_app_tags(channel_id, app_id, tag, add_time) \
         VALUES ('local_db', 'added.app', 'tag', 123); \
         INSERT INTO update_state(app_id, channel_key, latest_version, status, checked_at) \
         VALUES ('up.app', 'local_db', '2.0', 'idle', 123); \
         INSERT INTO update_log(app_id, channel_key, from_version, to_version, status, checked_at) \
         VALUES ('up.app', 'local_db', '1.0', '2.0', 'ok', 123); \
         INSERT INTO outbox(kind, payload_json, status, attempts, created_at, updated_at) \
         VALUES ('catalog.changed', '{}', 'pending', 0, 123, 123); \
         INSERT INTO update_prefs(key, value, imported_at) VALUES ('theme', 'dark', 123); \
         INSERT INTO core_writes(domain, first_write_at, snapshot_id) \
         VALUES ('catalog', 123, 'snap'); \
         INSERT INTO download_task(app_id, status, created_at, updated_at) \
         VALUES ('dl.app', 'queued', 123, 123);",
    )
    .unwrap();
}

fn read_apps(conn: &Connection, sql: &str) -> Vec<AppRow> {
    let mut stmt = conn.prepare(sql).unwrap();
    stmt.query_map([], |row| {
        Ok((
            row.get(0)?,
            row.get(1)?,
            row.get(2)?,
            row.get(3)?,
            row.get(4)?,
            row.get(5)?,
            row.get(6)?,
            row.get(7)?,
            row.get(8)?,
        ))
    })
    .unwrap()
    .map(|row| row.unwrap())
    .collect()
}

fn read_categories(conn: &Connection) -> Vec<CategoryRow> {
    read_categories_sql(conn, CATEGORY_SQL)
}

fn read_categories_sql(conn: &Connection, sql: &str) -> Vec<CategoryRow> {
    let mut stmt = conn.prepare(sql).unwrap();
    stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
}

fn read_configs(conn: &Connection) -> Vec<ConfigRow> {
    read_configs_sql(conn, CONFIG_SQL)
}

fn read_configs_sql(conn: &Connection, sql: &str) -> Vec<ConfigRow> {
    let mut stmt = conn.prepare(sql).unwrap();
    stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
}

fn catalog_state(conn: &Connection) -> CatalogState {
    let apps = read_apps(conn, FULL_APPS_SQL);
    let categories = read_categories(conn);
    let configs = read_configs(conn);
    let fts_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM apps_fts", [], |row| row.get(0))
        .unwrap();
    (apps, categories, configs, fts_rows)
}

fn fts_hits(conn: &Connection, term: &str) -> i64 {
    conn.query_row(
        "SELECT COUNT(*) FROM apps_fts WHERE apps_fts MATCH ?1",
        [term],
        |row| row.get(0),
    )
    .unwrap()
}

/// Dumps every non-catalog table (including the migration ledger) so a test
/// failure names the table that changed instead of only reporting "differ".
fn non_catalog_dump(conn: &Connection) -> String {
    let mut stmt = conn
        .prepare(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' \
             AND name NOT IN ('apps', 'categories', 'app_config') AND name NOT LIKE 'apps_fts%' ORDER BY name",
        )
        .unwrap();
    let tables: Vec<String> = stmt
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(|row| row.unwrap())
        .collect();
    drop(stmt);

    let mut out = String::new();
    for table in tables {
        out.push_str(&format!("== {table} ==\n"));
        let quoted = table.replace('"', "\"\"");
        let mut stmt = conn
            .prepare(&format!("SELECT * FROM \"{quoted}\" ORDER BY rowid"))
            .unwrap();
        let columns = stmt.column_count();
        let mut rows = stmt.query([]).unwrap();
        while let Some(row) = rows.next().unwrap() {
            for index in 0..columns {
                let value: rusqlite::types::Value = row.get(index).unwrap();
                out.push_str(&format!("{value:?}|"));
            }
            out.push('\n');
        }
    }
    out
}

fn backups(dir: &Path) -> Vec<PathBuf> {
    files_matching(dir, ".bak-refresh-")
}

fn refresh_temp_files(dir: &Path) -> Vec<PathBuf> {
    files_matching(dir, ".refresh-")
}

fn files_matching(dir: &Path, needle: &str) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().contains(needle))
                .unwrap_or(false)
        })
        .collect()
}

fn assert_error_code(result: Result<impl std::fmt::Debug, Error>, needle: &str) -> String {
    let error = result.expect_err("operation must fail");
    let message = error.to_string();
    assert!(
        message.contains(needle),
        "expected {needle}, got {message}"
    );
    message
}

#[test]
fn catalog_refresh_preserves_core_tables() {
    let dir = TempDir::new("preserves");
    let core = open_core(dir.path());
    prepopulate_old_catalog(&core);
    prepopulate_non_catalog(&core);

    let source = dir.path().join("source.db");
    create_source(&source, FULL_SOURCE_SQL);

    let (before_non_catalog, before_catalog) = {
        let reader = core.reader().unwrap();
        (non_catalog_dump(&reader), catalog_state(&reader))
    };
    assert_eq!(before_catalog.0.len(), 2);

    let report = replace_catalog_from_db(&core, &source, "local://source")
        .expect("refresh from a valid source");
    println!("report = {report:?}");

    assert_eq!(
        (report.apps, report.categories, report.configs, report.fts_rows),
        (2, 2, 1, 2)
    );
    assert_eq!(report.source_url, "local://source");
    assert!(report.changed, "changed catalog must report changed=true");
    assert!(report.backup.is_some(), "refresh must create a backup");

    let reader = core.reader().unwrap();
    let after_catalog = catalog_state(&reader);
    let source_conn =
        Connection::open_with_flags(&source, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();

    assert_eq!(
        after_catalog.0,
        read_apps(&source_conn, FULL_APPS_SQL),
        "apps must match the source row-for-row"
    );
    assert_eq!(
        after_catalog.1,
        read_categories_sql(&source_conn, SOURCE_CATEGORY_SQL),
        "categories must match the source"
    );
    assert_eq!(
        after_catalog.2,
        read_configs_sql(&source_conn, SOURCE_CONFIG_SQL),
        "config must match the source"
    );

    assert!(
        !after_catalog.0.iter().any(|row| row.0 == "com.a"),
        "absent app A must be removed"
    );
    let renamed = after_catalog
        .0
        .iter()
        .find(|row| row.0 == "com.b")
        .expect("app B present");
    assert_eq!(renamed.1, "BetaRenamed");
    assert_eq!(renamed.6.as_deref(), Some("beta readme"));
    assert!(
        after_catalog.0.iter().any(|row| row.0 == "com.c"),
        "new app C must be inserted"
    );

    assert_eq!(
        non_catalog_dump(&reader),
        before_non_catalog,
        "every non-catalog table must be byte-identical"
    );

    assert_eq!(after_catalog.3, 2, "fts row count must match the source apps");
    assert_eq!(fts_hits(&reader, "OldAlpha"), 0, "old FTS term must be gone");
    assert_eq!(
        fts_hits(&reader, "OldBetaUnique"),
        0,
        "old FTS term must be gone"
    );
    assert_eq!(fts_hits(&reader, "BetaRenamed"), 1, "new FTS term present");
    assert_eq!(fts_hits(&reader, "GammaNew"), 1, "new FTS term present");

    let integrity: String = reader
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .unwrap();
    assert_eq!(integrity, "ok");
    let user_version: i64 = reader
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap();
    assert_eq!(user_version, 5);

    let found_backups = backups(dir.path());
    assert_eq!(found_backups.len(), 1, "expected one timestamped backup");
    assert_eq!(
        Some(found_backups[0].clone()),
        report.backup.clone().map(PathBuf::from)
    );

    let backup_conn =
        Connection::open_with_flags(&found_backups[0], OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let backup_apps = read_apps(&backup_conn, FULL_APPS_SQL);
    assert_eq!(backup_apps.len(), 2, "backup must hold the old catalog");
    assert!(backup_apps.iter().any(|row| row.0 == "com.a"));
    assert!(backup_apps
        .iter()
        .any(|row| row.0 == "com.b" && row.1 == "OldBetaUnique"));
    assert!(
        !backup_apps.iter().any(|row| row.0 == "com.c"),
        "backup must not contain the new catalog"
    );
    let backup_configs = read_configs(&backup_conn);
    assert_eq!(backup_configs, vec![("1.1.1".to_string(), None)]);

    assert!(
        refresh_temp_files(dir.path()).is_empty(),
        "local refresh must not leave temp files"
    );
}

#[test]
fn catalog_refresh_failure_keeps_old_catalog() {
    let dir = TempDir::new("failures");
    let core = open_core(dir.path());
    prepopulate_old_catalog(&core);
    prepopulate_non_catalog(&core);

    let (before_non_catalog, before_catalog) = {
        let reader = core.reader().unwrap();
        (non_catalog_dump(&reader), catalog_state(&reader))
    };

    let not_sqlite = dir.path().join("not_sqlite.db");
    std::fs::write(&not_sqlite, b"not a sqlite database").unwrap();

    let truncated = dir.path().join("truncated.db");
    std::fs::write(&truncated, b"SQLite format 3").unwrap();

    let missing_config = dir.path().join("missing_config.db");
    create_source(
        &missing_config,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         INSERT INTO apps VALUES ('partial.app', 'Partial', NULL, NULL, NULL, NULL, 'T'); \
         INSERT INTO category VALUES ('T', 'T', 'i');",
    );

    let duplicate_app = dir.path().join("duplicate_app.db");
    create_source(
        &duplicate_app,
        "CREATE TABLE apps(appId TEXT, name TEXT NOT NULL, user TEXT, repositories TEXT, \
         icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO apps VALUES ('dup.app', 'First', NULL, NULL, NULL, NULL, 'T'); \
         INSERT INTO apps VALUES ('dup.app', 'Second', NULL, NULL, NULL, NULL, 'T'); \
         INSERT INTO category VALUES ('T', 'T', 'i'); \
         INSERT INTO config VALUES ('1.0.0');",
    );

    let empty_apps = dir.path().join("empty_apps.db");
    create_source(
        &empty_apps,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO category VALUES ('T', 'T', 'i'); \
         INSERT INTO config VALUES ('1.0.0');",
    );

    let duplicate_category = dir.path().join("duplicate_category.db");
    create_source(
        &duplicate_category,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO apps VALUES ('valid.app', 'Valid', NULL, NULL, NULL, NULL, 'T'); \
         INSERT INTO category VALUES ('T', 'First', 'i'); \
         INSERT INTO category VALUES ('T', 'Second', 'i'); \
         INSERT INTO config VALUES ('1.0.0');",
    );

    for bad in [
        &not_sqlite,
        &truncated,
        &missing_config,
        &duplicate_app,
        &empty_apps,
        &duplicate_category,
    ] {
        let result = replace_catalog_from_db(&core, bad, "bad://source");
        let message = assert_error_code(result, "CORE_E_CATALOG_REFRESH_");
        println!("rejected {}: {message}", bad.display());

        let reader = core.reader().unwrap();
        assert_eq!(
            catalog_state(&reader),
            before_catalog,
            "failed refresh of {} must leave the catalog untouched",
            bad.display()
        );
        assert_eq!(
            non_catalog_dump(&reader),
            before_non_catalog,
            "failed refresh of {} must leave non-catalog tables untouched",
            bad.display()
        );
        assert!(
            backups(dir.path()).is_empty(),
            "validation failure must not create a backup"
        );
        assert!(
            refresh_temp_files(dir.path()).is_empty(),
            "validation failure must not leave temp files"
        );
    }
}

#[test]
fn catalog_refresh_mid_write_rollback() {
    let dir = TempDir::new("mid_write");
    let core = open_core(dir.path());
    prepopulate_old_catalog(&core);
    prepopulate_non_catalog(&core);

    let source = dir.path().join("source.db");
    create_source(
        &source,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO apps VALUES ('com.d', 'DeltaNew', NULL, NULL, NULL, 'delta', 'BOOM'); \
         INSERT INTO category VALUES ('BOOM', 'Boom', 'boom'); \
         INSERT INTO config VALUES ('2.0.0');",
    );

    {
        let conn = core.writer().unwrap();
        conn.execute_batch(
            "CREATE TRIGGER abort_catalog_refresh BEFORE INSERT ON categories \
             WHEN NEW.id = 'BOOM' BEGIN SELECT RAISE(ABORT, 'injected mid-write failure'); END;",
        )
        .unwrap();
    }

    let (before_non_catalog, before_catalog) = {
        let reader = core.reader().unwrap();
        (non_catalog_dump(&reader), catalog_state(&reader))
    };

    let result = replace_catalog_from_db(&core, &source, "boom://source");
    let message = assert_error_code(result, "CORE_E_CATALOG_REFRESH_");
    println!("mid-write failure: {message}");

    let reader = core.reader().unwrap();
    assert_eq!(
        catalog_state(&reader),
        before_catalog,
        "mid-write failure must roll back the catalog (including FTS)"
    );
    assert_eq!(
        non_catalog_dump(&reader),
        before_non_catalog,
        "mid-write failure must leave non-catalog tables untouched"
    );
    assert_eq!(fts_hits(&reader, "OldAlpha"), 1, "old FTS row restored");
    assert_eq!(fts_hits(&reader, "DeltaNew"), 0, "new FTS row rolled back");
    assert_eq!(
        backups(dir.path()).len(),
        1,
        "a backup is taken before the transaction even on failure"
    );
}

#[test]
fn catalog_refresh_allow_empty() {
    let dir = TempDir::new("allow_empty");
    let core = open_core(dir.path());
    prepopulate_old_catalog(&core);
    let source = dir.path().join("empty.db");
    create_source(
        &source,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO category VALUES ('EMPTY', 'Empty', 'i'); \
         INSERT INTO config VALUES ('3.0.0');",
    );

    let (before_non_catalog, before_catalog) = {
        let reader = core.reader().unwrap();
        (non_catalog_dump(&reader), catalog_state(&reader))
    };

    let rejected = replace_catalog_from_db(&core, &source, "empty://source");
    assert_error_code(rejected, "CORE_E_CATALOG_REFRESH_EMPTY");
    let reader = core.reader().unwrap();
    assert_eq!(catalog_state(&reader), before_catalog);
    assert_eq!(non_catalog_dump(&reader), before_non_catalog);
    assert!(backups(dir.path()).is_empty());
    drop(reader);

    let report = replace_catalog_from_db_with_options(
        &core,
        &source,
        "empty://source",
        &CatalogRefreshOptions { allow_empty: true },
    )
    .expect("allow_empty accepts an empty catalog");
    println!("allow_empty report = {report:?}");
    assert_eq!((report.apps, report.fts_rows), (0, 0));
    assert_eq!((report.categories, report.configs), (1, 1));
    assert!(report.changed);

    let reader = core.reader().unwrap();
    let after = catalog_state(&reader);
    assert!(after.0.is_empty(), "catalog apps must be cleared");
    assert_eq!(after.3, 0, "FTS must be cleared");
    assert_eq!(after.1, vec![("EMPTY".to_string(), "Empty".into(), "i".into())]);
    assert_eq!(backups(dir.path()).len(), 1);
}

struct FailHttp;

impl HttpPort for FailHttp {
    fn get(&self, _url: &str, _options: &HttpOptions) -> Result<HttpResponse, Error> {
        Err(Error::Network(
            "CORE_E_CATALOG_REFRESH_NET: injected transport failure".to_string(),
        ))
    }

    fn post(
        &self,
        _url: &str,
        _body: &[u8],
        _options: &HttpOptions,
    ) -> Result<HttpResponse, Error> {
        self.get(_url, _options)
    }
}

#[test]
fn catalog_refresh_download_success() {
    let dir = TempDir::new("download_ok");
    let core = open_core(dir.path());
    prepopulate_old_catalog(&core);

    let source = dir.path().join("source.db");
    create_source(&source, FULL_SOURCE_SQL);
    let body = std::fs::read(&source).unwrap();

    let http = FakeHttpPort::new();
    http.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body,
    });

    let url = "https://example.invalid/catalog.db";
    let report = refresh_catalog(&core, &http, url).expect("download refresh");
    println!("download report = {report:?}");
    assert_eq!(report.source_url, url);
    assert_eq!((report.apps, report.categories, report.configs), (2, 2, 1));
    assert!(report.changed);

    let calls = http.calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].method, "GET");
    assert_eq!(calls[0].url, url);

    let reader = core.reader().unwrap();
    assert_eq!(catalog_state(&reader).0.len(), 2);
    assert_eq!(fts_hits(&reader, "GammaNew"), 1);
    assert!(
        refresh_temp_files(dir.path()).is_empty(),
        "successful download must remove its temp file"
    );
}

#[test]
fn catalog_refresh_download_failure() {
    let dir = TempDir::new("download_fail");
    let core = open_core(dir.path());
    prepopulate_old_catalog(&core);

    let source = dir.path().join("source.db");
    create_source(&source, FULL_SOURCE_SQL);
    let body = std::fs::read(&source).unwrap();

    let before = {
        let reader = core.reader().unwrap();
        catalog_state(&reader)
    };

    let status_fail = FakeHttpPort::new();
    status_fail.push_response(HttpResponse {
        status: 500,
        headers: Vec::new(),
        body: body.clone(),
    });
    let result = refresh_catalog(&core, &status_fail, "https://example.invalid/catalog.db");
    assert_error_code(result, "CORE_E_CATALOG_REFRESH_HTTP");

    let empty_fail = FakeHttpPort::new();
    empty_fail.push_response(HttpResponse {
        status: 200,
        headers: Vec::new(),
        body: Vec::new(),
    });
    let result = refresh_catalog(&core, &empty_fail, "https://example.invalid/catalog.db");
    assert_error_code(result, "CORE_E_CATALOG_REFRESH_BODY");

    let transport_fail = FailHttp;
    let result = refresh_catalog(&core, &transport_fail, "https://example.invalid/catalog.db");
    let error = result.expect_err("transport failure must propagate");
    println!("transport failure: {error}");
    assert_eq!(error.code(), gstore_core::error::CODE_NETWORK);
    assert!(error.to_string().contains("CORE_E_CATALOG_REFRESH_NET"));

    let reader = core.reader().unwrap();
    assert_eq!(
        catalog_state(&reader),
        before,
        "download failures must leave the old catalog intact"
    );
    assert!(backups(dir.path()).is_empty());
    assert!(
        refresh_temp_files(dir.path()).is_empty(),
        "download failures must not leave temp files"
    );
}

#[test]
fn catalog_refresh_missing_optional_columns() {
    let dir = TempDir::new("optional");
    let core = open_core(dir.path());
    let source = dir.path().join("optional.db");
    create_source(
        &source,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO apps VALUES ('opt.one', 'Optional One', 'u', 'r', 'i', 'd', 'TOOLS'); \
         INSERT INTO category VALUES ('TOOLS', 'Tools', 'tools'); \
         INSERT INTO config VALUES ('4.0.0');",
    );

    let report = replace_catalog_from_db(&core, &source, "optional://source")
        .expect("seven-column source must refresh");
    println!("optional report = {report:?}");
    assert_eq!((report.apps, report.categories, report.configs), (1, 1, 1));

    let reader = core.reader().unwrap();
    let apps = read_apps(&reader, FULL_APPS_SQL);
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].0, "opt.one");
    assert_eq!(apps[0].6, None, "absent readme must map to NULL");
    assert_eq!(apps[0].8, None, "absent extra must map to NULL");
    assert_eq!(read_configs(&reader), vec![("4.0.0".to_string(), None)]);
}

#[test]
fn catalog_changed_event_wire_name() {
    let event = catalog_changed_event().expect("catalog event");
    let value = serde_json::to_value(&event).unwrap();
    println!("catalog.changed = {value}");

    assert_eq!(value["event"], "catalog.changed");
    // `CatalogChanged` carries the local catalog's `ChannelKey`; the key is the
    // `local_db` identity consumed by the FRB/Android layer.
    assert_eq!(value["payload"]["key"], "local_db");
    assert_eq!(value["payload"]["app_id"], serde_json::Value::Null);
    assert_eq!(value["payload"]["removed"], false);

    match event {
        CoreEvent::CatalogChanged {
            key,
            app_id,
            removed,
        } => {
            assert_eq!(key.as_str(), "local_db");
            assert_eq!(app_id, None);
            assert!(!removed);
        }
        other => panic!("unexpected event: {other:?}"),
    }
}

#[test]
fn catalog_refresh_noop_reports_unchanged() {
    let dir = TempDir::new("noop");
    let core = open_core(dir.path());
    let source = dir.path().join("source.db");
    create_source(&source, FULL_SOURCE_SQL);

    let first = replace_catalog_from_db(&core, &source, "local://source").expect("first refresh");
    assert!(first.changed, "first refresh changes the empty catalog");
    let after_first = {
        let reader = core.reader().unwrap();
        catalog_state(&reader)
    };

    let second = replace_catalog_from_db(&core, &source, "local://source").expect("second refresh");
    println!("noop report = {second:?}");
    assert!(
        !second.changed,
        "refreshing an identical source must report changed=false"
    );
    assert!(second.backup.is_some(), "no-op refresh still backs up");
    assert_eq!(
        (
            second.apps,
            second.categories,
            second.configs,
            second.fts_rows
        ),
        (2, 2, 1, 2)
    );

    let reader = core.reader().unwrap();
    assert_eq!(
        catalog_state(&reader),
        after_first,
        "no-op refresh must not mutate the catalog"
    );
    assert_eq!(backups(dir.path()).len(), 2, "each refresh backs up");
}
