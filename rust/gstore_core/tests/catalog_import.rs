//! Catalog import contract: live precedence, seed fallback, exact mappings,
//! dry-run counts, optional columns, timestamped backups, and rollback on a
//! malformed source.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::catalog::import::{
    import_catalog, resolve_source, CatalogImportOptions, CatalogImportReport,
};
use gstore_core::db::DbHandle;
use rusqlite::{Connection, OpenFlags};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_catalog_{tag}_{}_{}",
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

const SEED_APPS_SQL: &str = "SELECT \"appId\", \"name\", \"user\", \"repositories\", \
     \"icon\", \"des\", NULL, \"category\", NULL FROM apps ORDER BY \"appId\"";

const CORE_APPS_SQL: &str = "SELECT \"appId\", \"name\", \"user\", \"repositories\", \
     \"icon\", \"des\", \"readme\", \"category\", \"extra\" FROM apps ORDER BY \"appId\"";

fn seed_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/app/db/apps.db")
}

fn open_core(dir: &Path) -> DbHandle {
    DbHandle::open_at(&dir.join("gstore_core.db")).expect("open core database")
}

fn options(dry_run: bool) -> CatalogImportOptions {
    CatalogImportOptions { dry_run }
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

fn read_categories(conn: &Connection, sql: &str) -> Vec<CategoryRow> {
    let mut stmt = conn.prepare(sql).unwrap();
    stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
}

fn read_configs(conn: &Connection, sql: &str) -> Vec<ConfigRow> {
    let mut stmt = conn.prepare(sql).unwrap();
    stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
}

fn catalog_state(conn: &Connection) -> CatalogState {
    let apps = read_apps(conn, CORE_APPS_SQL);
    let categories = read_categories(
        conn,
        "SELECT id, description, icon FROM categories ORDER BY id",
    );
    let configs = read_configs(
        conn,
        "SELECT version, proxy FROM app_config ORDER BY version",
    );
    let fts_rows: i64 = conn
        .query_row("SELECT COUNT(*) FROM apps_fts", [], |row| row.get(0))
        .unwrap();
    (apps, categories, configs, fts_rows)
}

fn backups(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().contains(".bak-import-"))
                .unwrap_or(false)
        })
        .collect()
}

fn prepopulate_known_catalog(core: &DbHandle) {
    let conn = core.writer().unwrap();
    conn.execute(
        "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
         VALUES ('keep.me', 'KeepMe', NULL, NULL, NULL, NULL, 'KEEP')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO categories(id, description, icon) VALUES ('KEEP', 'Keep category', 'keep-icon')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO app_config(version, proxy) VALUES ('7.7.7', NULL)",
        [],
    )
    .unwrap();
}

fn create_source(path: &Path, sql: &str) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(sql).unwrap();
}

fn app_by_id<'a>(apps: &'a [AppRow], app_id: &str) -> &'a AppRow {
    apps.iter()
        .find(|row| row.0 == app_id)
        .unwrap_or_else(|| panic!("missing app {app_id}: {apps:?}"))
}

fn assert_failed_with_catalog_code(report: &Result<CatalogImportReport, gstore_core::Error>) {
    let error = report
        .as_ref()
        .expect_err("malformed source must be rejected");
    assert!(
        error.to_string().contains("CORE_E_CATALOG_"),
        "unexpected error: {error}"
    );
}

#[test]
fn catalog_import_live_and_seed() {
    let dir = TempDir::new("live_and_seed");
    let core = open_core(dir.path());
    let seed = seed_path();
    assert!(
        seed.is_file(),
        "seed database missing at {}",
        seed.display()
    );

    let report = import_catalog(&core, None, &seed, &options(false)).expect("import seed");
    println!("report = {report:?}");
    assert_eq!(report.source, seed.display().to_string());
    assert_eq!(report.source_kind, "seed");
    assert_eq!(report.apps, 17);
    assert_eq!(report.categories, 13);
    assert_eq!(report.configs, 1);
    assert_eq!(report.fts_rows, 17);
    assert!(!report.dry_run);
    assert!(report.backup.is_some(), "import must create a backup");

    let reader = core.reader().unwrap();
    let core_apps = read_apps(&reader, CORE_APPS_SQL);
    let source_apps = {
        let source = Connection::open_with_flags(&seed, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        read_apps(&source, SEED_APPS_SQL)
    };
    assert_eq!(core_apps.len(), 17, "apps row count must match the source");
    assert_eq!(
        core_apps, source_apps,
        "every app value (including NULL vs empty) must round-trip"
    );

    let core_categories = read_categories(
        &reader,
        "SELECT id, description, icon FROM categories ORDER BY id",
    );
    let source_categories = {
        let source = Connection::open_with_flags(&seed, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        read_categories(
            &source,
            "SELECT id, description, icon FROM category ORDER BY id",
        )
    };
    assert_eq!(core_categories, source_categories);

    let core_configs = read_configs(&reader, "SELECT version, proxy FROM app_config");
    assert_eq!(core_configs, vec![("0.0.12".to_string(), None)]);

    let integrity: String = reader
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .unwrap();
    println!("PRAGMA integrity_check = {integrity}");
    assert_eq!(integrity, "ok");

    // `apps_fts` is contentless: match rowids, then read the appId from `apps`.
    let mut stmt = reader
        .prepare(
            "SELECT a.appId FROM apps_fts f JOIN apps a ON a.rowid = f.rowid \
             WHERE apps_fts MATCH '\"magisk\"*'",
        )
        .unwrap();
    let hits: Vec<String> = stmt
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(|row| row.unwrap())
        .collect();
    println!("FTS magisk hits = {hits:?}");
    assert_eq!(hits, vec!["com.topjohnwu.magisk".to_string()]);

    let found_backups = backups(dir.path());
    println!("backups = {found_backups:?}");
    assert_eq!(found_backups.len(), 1, "expected one timestamped backup");
    assert_eq!(
        Some(found_backups[0].clone()),
        report.backup.map(PathBuf::from)
    );

    drop(stmt);
    drop(reader);

    // A second import must be a clean replace, not a duplicate or an error.
    let second = import_catalog(&core, None, &seed, &options(false)).expect("second import");
    assert_eq!(second.apps, 17);
    let reader = core.reader().unwrap();
    let count: i64 = reader
        .query_row("SELECT COUNT(*) FROM apps", [], |row| row.get(0))
        .unwrap();
    let fts: i64 = reader
        .query_row("SELECT COUNT(*) FROM apps_fts", [], |row| row.get(0))
        .unwrap();
    println!("after second import: apps={count}, apps_fts={fts}");
    assert_eq!((count, fts), (17, 17));
}

#[test]
fn catalog_import_live_preferred_over_seed() {
    let dir = TempDir::new("live_preferred");
    let live = dir.path().join("live.db");
    create_source(
        &live,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO apps VALUES ('live.one', 'Live One', 'lu', 'lr', 'li', 'ld', 'TOOLS'); \
         INSERT INTO apps VALUES ('live.two', 'Live Two', NULL, NULL, NULL, NULL, NULL); \
         INSERT INTO category VALUES ('LIVE', 'Live category', 'live-icon'); \
         INSERT INTO config VALUES ('1.2.3');",
    );

    let core = open_core(dir.path());
    let report = import_catalog(&core, Some(&live), &seed_path(), &options(false))
        .expect("import live source");
    println!("report = {report:?}");
    assert_eq!(report.source, live.display().to_string());
    assert_eq!(report.source_kind, "live");
    assert_eq!((report.apps, report.categories, report.configs), (2, 1, 1));

    let reader = core.reader().unwrap();
    let apps = read_apps(&reader, CORE_APPS_SQL);
    assert_eq!(apps.len(), 2);
    assert_eq!(apps[0].0, "live.one");
    assert_eq!(apps[0].1, "Live One");
    assert_eq!(apps[0].8, None, "missing extra column must map to NULL");
    assert_eq!(apps[1].0, "live.two");
    assert!(
        !apps.iter().any(|row| row.0 == "com.topjohnwu.magisk"),
        "seed rows must not leak into a live import"
    );
}

#[test]
fn catalog_import_seed_fallback() {
    let dir = TempDir::new("seed_fallback");
    let core = open_core(dir.path());
    let missing_live = dir.path().join("does-not-exist.db");

    let (resolved, kind) = resolve_source(Some(&missing_live), &seed_path()).unwrap();
    assert_eq!(kind, "seed");
    assert_eq!(resolved, seed_path());

    let report = import_catalog(&core, Some(&missing_live), &seed_path(), &options(false))
        .expect("fallback to seed");
    println!("report = {report:?}");
    assert_eq!(report.source_kind, "seed");
    assert_eq!(report.apps, 17);
}

#[test]
fn catalog_import_dry_run_counts_only() {
    let dir = TempDir::new("dry_run");
    let core = open_core(dir.path());
    {
        let conn = core.writer().unwrap();
        conn.execute(
            "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
             VALUES ('old.app', 'Old App', NULL, NULL, NULL, NULL, 'OLD')",
            [],
        )
        .unwrap();
    }

    let report = import_catalog(&core, None, &seed_path(), &options(true)).expect("dry run");
    println!("report = {report:?}");
    assert_eq!(
        (report.apps, report.categories, report.configs),
        (17, 13, 1)
    );
    assert_eq!(report.fts_rows, 17);
    assert!(report.dry_run);
    assert_eq!(report.backup, None);
    assert!(backups(dir.path()).is_empty(), "dry run must not back up");

    let reader = core.reader().unwrap();
    let apps = read_apps(&reader, CORE_APPS_SQL);
    assert_eq!(apps.len(), 1);
    assert_eq!(apps[0].0, "old.app");
    let fts: i64 = reader
        .query_row("SELECT COUNT(*) FROM apps_fts", [], |row| row.get(0))
        .unwrap();
    assert_eq!(fts, 1);
}

#[test]
fn catalog_import_corrupt_source_rollback() {
    let dir = TempDir::new("rollback");
    let core = open_core(dir.path());
    prepopulate_known_catalog(&core);
    let before = {
        let reader = core.reader().unwrap();
        catalog_state(&reader)
    };
    assert_eq!(before.0.len(), 1);
    assert_eq!(before.3, 1);

    let not_sqlite = dir.path().join("not_sqlite.db");
    std::fs::write(&not_sqlite, b"not a sqlite db").unwrap();

    let missing_config = dir.path().join("missing_config.db");
    create_source(
        &missing_config,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         INSERT INTO apps VALUES ('partial', 'Partial', NULL, NULL, NULL, NULL, 'T'); \
         INSERT INTO category VALUES ('T', 'T', 'i');",
    );

    let null_app_id = dir.path().join("null_app_id.db");
    create_source(
        &null_app_id,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, category TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY); \
         INSERT INTO apps VALUES (NULL, 'No Id', NULL, NULL, NULL, NULL, 'T'); \
         INSERT INTO category VALUES ('T', 'T', 'i'); \
         INSERT INTO config VALUES ('1.0.0');",
    );

    for bad in [&not_sqlite, &missing_config, &null_app_id] {
        let result = import_catalog(&core, None, bad, &options(false));
        assert_failed_with_catalog_code(&result);
        println!("rejected {}: {}", bad.display(), result.unwrap_err());
        let reader = core.reader().unwrap();
        assert_eq!(
            catalog_state(&reader),
            before,
            "failed import of {} must leave the catalog untouched",
            bad.display()
        );
        assert!(
            backups(dir.path()).is_empty(),
            "validation failure must not create a backup"
        );
    }
}

#[test]
fn catalog_import_preserves_optional_columns() {
    let dir = TempDir::new("optional");
    let source = dir.path().join("optional.db");
    create_source(
        &source,
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
         repositories TEXT, icon TEXT, des TEXT, readme TEXT, category TEXT, extra TEXT); \
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
         CREATE TABLE config(version TEXT PRIMARY KEY, proxy TEXT); \
         INSERT INTO apps VALUES ('opt.one', 'Opt One', 'u', 'r', 'i', 'd', 'readme text', 'TOOLS', '{\"k\":\"v\"}'); \
         INSERT INTO apps VALUES ('opt.two', 'Opt Two', NULL, NULL, NULL, NULL, NULL, 'TOOLS', NULL); \
         INSERT INTO apps VALUES ('opt.three', 'Opt Three', NULL, NULL, NULL, NULL, '', 'TOOLS', ''); \
         INSERT INTO category VALUES ('TOOLS', 'Tools', 'tools-icon'); \
         INSERT INTO config VALUES ('2.0.0', 'http://proxy:8080');",
    );

    let core = open_core(dir.path());
    let report = import_catalog(&core, Some(&source), &seed_path(), &options(false))
        .expect("import optional columns");
    assert_eq!((report.apps, report.categories, report.configs), (3, 1, 1));

    let reader = core.reader().unwrap();
    let apps = read_apps(&reader, CORE_APPS_SQL);
    let one = app_by_id(&apps, "opt.one");
    assert_eq!(one.6.as_deref(), Some("readme text"));
    assert_eq!(one.8.as_deref(), Some("{\"k\":\"v\"}"));
    assert_eq!(one.7.as_deref(), Some("TOOLS"));

    let two = app_by_id(&apps, "opt.two");
    assert_eq!(two.6, None, "absent readme value must stay NULL");
    assert_eq!(two.8, None, "absent extra value must stay NULL");

    let three = app_by_id(&apps, "opt.three");
    assert_eq!(three.6.as_deref(), Some(""), "empty readme must stay empty");
    assert_eq!(three.8.as_deref(), Some(""), "empty extra must stay empty");

    let configs = read_configs(&reader, "SELECT version, proxy FROM app_config");
    assert_eq!(
        configs,
        vec![("2.0.0".to_string(), Some("http://proxy:8080".to_string()))]
    );
}

#[test]
fn catalog_import_backup_before_replace() {
    let dir = TempDir::new("backup");
    let core = open_core(dir.path());
    {
        let conn = core.writer().unwrap();
        conn.execute(
            "INSERT INTO apps(appId, name, user, repositories, icon, des, category) \
             VALUES ('old.only', 'Old Only', NULL, NULL, NULL, NULL, 'OLD')",
            [],
        )
        .unwrap();
    }

    let report = import_catalog(&core, None, &seed_path(), &options(false)).expect("import seed");
    let backup = PathBuf::from(report.backup.expect("backup path"));
    assert!(backup.is_file(), "backup missing at {}", backup.display());

    let old_backup =
        Connection::open_with_flags(&backup, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let backup_apps = read_apps(&old_backup, CORE_APPS_SQL);
    println!("backup apps = {backup_apps:?}");
    assert_eq!(backup_apps.len(), 1);
    assert_eq!(backup_apps[0].0, "old.only");
    let backup_fts: i64 = old_backup
        .query_row("SELECT COUNT(*) FROM apps_fts", [], |row| row.get(0))
        .unwrap();
    assert_eq!(backup_fts, 1);

    let reader = core.reader().unwrap();
    let live_apps = read_apps(&reader, CORE_APPS_SQL);
    assert_eq!(live_apps.len(), 17);
    assert!(live_apps.iter().any(|row| row.0 == "com.topjohnwu.magisk"));
    assert!(
        !live_apps.iter().any(|row| row.0 == "old.only"),
        "replaced catalog must not keep the old app"
    );
}
