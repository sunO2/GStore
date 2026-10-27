// allow: SIZE_OK — five-domain fixture matrix is one cohesive proof; splitting duplicates the SQL/service fixtures
//! Plan-Todo 2 (6A-A2): `core_writes` is armed per domain at the first
//! post-flip mutation and projected into the process-global flags.
//!
//! Every test here serializes on [`FLAGS_LOCK`] because the flag snapshot is a
//! process-global static.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use gstore_core::catalog::refresh::replace_catalog_from_db;
use gstore_core::channel::{ChannelRecord, ChannelStore, SqliteChannelStore};
use gstore_core::db::DbHandle;
use gstore_core::download::port::{DownloadRequest, ModuleBridge, ModuleDownloadPort};
use gstore_core::flags::{flags, reset_flags, set_flags, FlagsPatch};
use gstore_core::install::InstallService;
use gstore_core::{ChannelKey, ChannelKind, ChannelMeta, DownloadPort};
use gstore_core::migration::{
    apply_core_schema, core_write_marker, mark_core_write, suppress_core_write_markers,
    CORE_WRITES_DOMAINS,
};
use gstore_core::update::service::{ChannelResolver, UpdateService};
use rusqlite::params;

static FLAGS_LOCK: Mutex<()> = Mutex::new(());
static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_writes_{tag}_{}_{}",
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

fn open(tag: &str) -> (TempDir, DbHandle) {
    let dir = TempDir::new(tag);
    let db = DbHandle::open(dir.path()).expect("open core db");
    (dir, db)
}

fn marker_count(db: &DbHandle, domain: &str) -> i64 {
    db.with_reader(|conn| {
        conn.query_row(
            "SELECT COUNT(*) FROM core_writes WHERE domain=?1",
            [domain],
            |row| row.get(0),
        )
        .map_err(|e| gstore_core::db::DbError(e.to_string()))
    })
    .expect("count markers")
}

fn marker(db: &DbHandle, domain: &str) -> Option<i64> {
    db.with_reader(|conn| core_write_marker(conn, domain))
        .expect("read marker")
        .map(|m| m.first_write_at)
}

fn flip(patch: FlagsPatch) {
    set_flags(patch).expect("flip domain flag");
}

fn only_channels() -> FlagsPatch {
    FlagsPatch {
        channels: Some(true),
        ..FlagsPatch::default()
    }
}

fn only_catalog() -> FlagsPatch {
    FlagsPatch {
        catalog: Some(true),
        ..FlagsPatch::default()
    }
}

fn only_update() -> FlagsPatch {
    FlagsPatch {
        update: Some(true),
        ..FlagsPatch::default()
    }
}

fn only_download() -> FlagsPatch {
    FlagsPatch {
        download: Some(true),
        ..FlagsPatch::default()
    }
}

fn only_install() -> FlagsPatch {
    FlagsPatch {
        install: Some(true),
        ..FlagsPatch::default()
    }
}

fn channel_record(key: &str, name: &str) -> ChannelRecord {
    ChannelRecord::new(
        ChannelKey::new(key).unwrap(),
        ChannelMeta {
            kind: ChannelKind::Custom,
            name: name.to_string(),
            description: format!("{name} channel"),
            enabled: true,
            priority: 0,
            support_offline: false,
            last_update_time: None,
            version: Some("1".to_string()),
        },
    )
}

fn catalog_source(path: &Path) {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
             repositories TEXT, icon TEXT, des TEXT, readme TEXT, category TEXT, extra TEXT);\
         CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL);\
         CREATE TABLE config(version TEXT PRIMARY KEY, proxy TEXT);\
         INSERT INTO apps(appId, name) VALUES ('com.example.one', 'One');\
         INSERT INTO category(id, description, icon) VALUES ('TOOLS', 'Tools', 'i');\
         INSERT INTO config(version, proxy) VALUES ('1.0', NULL);",
    )
    .unwrap();
}

fn seed_update_cache(db: &DbHandle) {
    let cached = serde_json::json!([{
        "channelId": "github",
        "appId": "A",
        "appName": "App A",
        "iconUrl": null,
        "packageName": "com.example.a",
        "installedVersion": "1.0.0",
        "latestVersion": "2.0.0",
        "checkedAt": 1000,
        "download": {
            "url": "https://example.test/a.apk",
            "name": "a.apk",
            "size": 1,
            "downloadCount": null,
            "version": null,
            "versionCode": null,
            "publishedAt": null,
            "platform": null,
            "hash": null,
            "hashType": null
        }
    }]);
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO update_prefs(key, value, imported_at) VALUES ('update_results_v1', ?1, 1)",
        [cached.to_string()],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO installed_app(source_id, package_name, version_name, version_code, captured_at) \
         VALUES ('android', 'com.example.a', '2.0.0', 2, 1)",
        [],
    )
    .unwrap();
}

fn seed_install_task(db: &DbHandle, apk: &Path) {
    db.writer()
        .unwrap()
        .execute(
            "INSERT INTO download_task(module_task_id, app_id, resource_id, app_name, version, \
                 url, file_name, status, dest_path, created_at, updated_at) \
             VALUES ('task-1', 'app.demo', 'com.example.demo', 'Demo', '1.0', \
                 'https://example.test/d.apk', 'demo.apk', 'completed', ?1, 1, 1)",
            params![apk.to_string_lossy().to_string()],
        )
        .unwrap();
}

struct FakeDownloadBridge;

fn module_task_json(id: u64) -> serde_json::Value {
    serde_json::json!({
        "id": id,
        "appId": "app.demo",
        "appName": "Demo",
        "version": "1.0",
        "fileName": "demo.apk",
        "url": "https://example.test/demo.apk",
        "filePath": "/tmp/demo.apk",
        "status": 2,
        "received": 10,
        "total": 100,
        "speedBps": 5,
        "etaSec": 18,
        "dedupKey": "dedup:init",
        "kind": "app",
        "resourceId": "com.example.demo",
        "resourceVersion": "1.0",
        "installAfterDownload": false
    })
}

impl ModuleBridge for FakeDownloadBridge {
    fn call(&self, method: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        match method {
            "download.start" => serde_json::to_vec(&serde_json::json!({"id": 7, "status": 2}))
                .map_err(|e| e.to_string()),
            "download.get" => {
                let body: serde_json::Value =
                    serde_json::from_slice(payload).map_err(|e| e.to_string())?;
                let id = body
                    .get("id")
                    .and_then(serde_json::Value::as_u64)
                    .unwrap_or(42);
                serde_json::to_vec(&module_task_json(id)).map_err(|e| e.to_string())
            }
            other => Err(format!("unexpected method {other}")),
        }
    }
}

fn seed_download_row(db: &DbHandle) {
    db.writer()
        .unwrap()
        .execute(
            "INSERT INTO download_task(module_task_id, app_id, app_name, version, file_name, \
                 url, dest_path, status, created_at, updated_at) \
             VALUES ('42', 'app.demo', 'Demo', '1.0', 'demo.apk', \
                 'https://example.test/demo.apk', '/tmp/demo.apk', 'running', 1, 1)",
            [],
        )
        .unwrap();
}

fn download_request(dedup: &str) -> DownloadRequest {
    DownloadRequest {
        app_id: "app.demo".to_string(),
        app_name: "Demo".to_string(),
        version: "1.0".to_string(),
        file_name: "demo.apk".to_string(),
        url: "https://example.test/demo.apk".to_string(),
        dest_path: "/tmp/demo.apk".to_string(),
        kind: "app".to_string(),
        resource_id: "com.example.demo".to_string(),
        resource_version: "1.0".to_string(),
        dedup_key: dedup.to_string(),
        expected_sha256: None,
        install_after_download: false,
        headers: std::collections::HashMap::new(),
    }
}

#[test]
fn core_writes_arm_all_domains() {
    let _guard = FLAGS_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    reset_flags();

    assert_eq!(
        CORE_WRITES_DOMAINS,
        [
            "channel",
            "catalog",
            "update",
            "download",
            "install",
            "js_channel"
        ],
        "six domains must be declared in the plan's order"
    );

    let (_dir, db) = open("all_domains");
    for domain in CORE_WRITES_DOMAINS {
        let conn = db.writer().unwrap();
        mark_core_write(&conn, domain, None).expect("mark domain");
        assert!(
            core_write_marker(&conn, domain).expect("read marker").is_some(),
            "{domain} must have a marker row"
        );
        drop(conn);
        assert!(
            flags().core_writes,
            "marking {domain} must arm the core_writes projection"
        );
    }

    let total: i64 = db
        .with_reader(|conn| {
            conn.query_row("SELECT COUNT(*) FROM core_writes", [], |row| row.get(0))
                .map_err(|e| gstore_core::db::DbError(e.to_string()))
        })
        .expect("count rows");
    assert_eq!(total, 6, "exactly one row per declared domain");
    reset_flags();
}

#[test]
fn core_writes_first_mutation_per_domain() {
    let _guard = FLAGS_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    reset_flags();
    let (dir, db) = open("per_domain");

    // channel store
    flip(only_channels());
    let store = SqliteChannelStore::new(db.clone());
    store
        .register(channel_record("custom.one", "One"))
        .expect("register channel");
    let first = marker(&db, "channel").expect("channel marker");
    store
        .register(channel_record("custom.one", "Renamed"))
        .expect("second channel mutation");
    assert_eq!(marker_count(&db, "channel"), 1, "one channel marker");
    assert_eq!(
        marker(&db, "channel"),
        Some(first),
        "first_write_at must not change"
    );

    // catalog refresh
    reset_flags();
    flip(only_catalog());
    let source = dir.path().join("catalog-source.db");
    catalog_source(&source);
    replace_catalog_from_db(&db, &source, "test").expect("first catalog refresh");
    let first = marker(&db, "catalog").expect("catalog marker");
    replace_catalog_from_db(&db, &source, "test").expect("second catalog refresh");
    assert_eq!(marker_count(&db, "catalog"), 1, "one catalog marker");
    assert_eq!(
        marker(&db, "catalog"),
        Some(first),
        "first_write_at must not change"
    );

    // update persist
    reset_flags();
    flip(only_update());
    seed_update_cache(&db);
    let resolver: ChannelResolver = Arc::new(|_| None);
    let service = UpdateService::new(db.clone(), resolver);
    assert!(service.mark_updated("A").expect("first update persist"));
    let first = marker(&db, "update").expect("update marker");
    assert!(!service.mark_updated("A").expect("second update persist"));
    assert_eq!(marker_count(&db, "update"), 1, "one update marker");
    assert_eq!(
        marker(&db, "update"),
        Some(first),
        "first_write_at must not change"
    );

    // download mirror upsert
    reset_flags();
    flip(only_download());
    let port = ModuleDownloadPort::new(FakeDownloadBridge, db.shared_writer(), db.path().to_path_buf());
    port.start(&download_request("dedup:one"))
        .expect("first download upsert");
    let first = marker(&db, "download").expect("download marker");
    port.start(&download_request("dedup:one"))
        .expect("second download upsert");
    assert_eq!(marker_count(&db, "download"), 1, "one download marker");
    assert_eq!(
        marker(&db, "download"),
        Some(first),
        "first_write_at must not change"
    );

    // install transition
    reset_flags();
    flip(only_install());
    let apk = dir.path().join("demo.apk");
    std::fs::write(&apk, b"PK\x03\x04demo").unwrap();
    seed_install_task(&db, &apk);
    let install = InstallService::new(db.shared_writer());
    let started = install.install("task-1").expect("first install transition");
    assert!(started.request.is_some(), "first install must request");
    let first = marker(&db, "install").expect("install marker");
    install.install("task-1").expect("second install transition");
    assert_eq!(marker_count(&db, "install"), 1, "one install marker");
    assert_eq!(
        marker(&db, "install"),
        Some(first),
        "first_write_at must not change"
    );

    reset_flags();
}

#[test]
fn core_writes_no_marker_before_flag_flip() {
    let _guard = FLAGS_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    reset_flags();
    let (_dir, db) = open("before_flip");

    // Flags are all false: the core is not authoritative yet, so mutating
    // through a store must not create a marker or arm the projection.
    let store = SqliteChannelStore::new(db.clone());
    store
        .register(channel_record("custom.before", "Before"))
        .expect("register channel");
    assert_eq!(marker_count(&db, "channel"), 0, "no pre-flip marker");
    assert!(!flags().core_writes, "pre-flip projection must stay false");

    // A schema/migration pass proves the same invariant.
    let mut conn = rusqlite::Connection::open_in_memory().unwrap();
    apply_core_schema(&mut conn).unwrap();
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM core_writes", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        0,
        "schema application must not mark"
    );
    reset_flags();
}
#[test]
fn core_writes_rollback_keeps_flag_armed() {
    let _guard = FLAGS_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    reset_flags();
    let (_dir, db) = open("rollback");

    {
        let mut conn = db.writer().unwrap();
        let tx = conn
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .unwrap();
        mark_core_write(&tx, "channel", None).expect("mark inside tx");
        drop(tx);
    }

    assert_eq!(
        marker_count(&db, "channel"),
        0,
        "a rolled-back transaction must not leave a marker row"
    );
    println!(
        "rollback observable: row_absent=true flag_armed={}",
        flags().core_writes
    );
    assert!(
        flags().core_writes,
        "known fail-closed risk: the projection is armed before commit"
    );

    let authority = db
        .with_reader(|conn| core_write_marker(conn, "channel"))
        .expect("read marker");
    assert!(
        authority.is_none(),
        "the per-domain DB probe, not the flag, is the authority"
    );
    reset_flags();
}

#[test]
fn core_writes_no_marker_during_init() {
    let _guard = FLAGS_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    reset_flags();
    set_flags(FlagsPatch {
        channels: Some(true),
        catalog: Some(true),
        update: Some(true),
        download: Some(true),
        install: Some(true),
        js_channel: Some(true),
        ..FlagsPatch::default()
    })
    .expect("flip all domain flags");

    let (_dir, db) = open("init_suppressed");
    seed_download_row(&db);
    let port = ModuleDownloadPort::new(
        FakeDownloadBridge,
        db.shared_writer(),
        db.path().to_path_buf(),
    );

    {
        let _suppression = suppress_core_write_markers();
        let store = SqliteChannelStore::new(db.clone());
        store
            .register(channel_record("builtin.channel", "Builtin"))
            .expect("init-time channel seeding");
        port.reconcile().expect("init-time download reconcile");
    }

    let during_init: i64 = db
        .with_reader(|conn| {
            conn.query_row("SELECT COUNT(*) FROM core_writes", [], |row| row.get(0))
                .map_err(|e| gstore_core::db::DbError(e.to_string()))
        })
        .expect("count during init");
    println!(
        "init suppressed: core_writes={during_init} projection={}",
        flags().core_writes
    );
    assert_eq!(during_init, 0, "init work must not write a marker");
    assert!(!flags().core_writes, "init work must not arm the projection");

    let store = SqliteChannelStore::new(db.clone());
    store
        .register(channel_record("builtin.channel", "PostInit"))
        .expect("post-init channel mutation");
    assert_eq!(marker_count(&db, "channel"), 1, "post-init mutation marks");
    assert!(flags().core_writes, "post-init mutation still arms the flag");
    reset_flags();
}
