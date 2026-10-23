// allow: SIZE_OK — the five host scenarios share one process-global flag lock and one init helper; splitting would duplicate the isolation harness
//! Plan-Todo 2 (6A-A2) host surface: `armCoreWrite`, read-only
//! `coreWriteMarker`, init/reopen hydration, and snapshot-restore rehydration.
//!
//! These live in their own test binary because the flags snapshot is a
//! process-global static: no other `CoreApi::init` in this process may clobber
//! it while a projection assertion is running.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use gstore_core::channel::ScriptChannelStore;
use gstore_core::db::DbHandle;
use gstore_core::download::port::{DownloadRequest, ModuleBridge};
use gstore_core::dto::{AppSummary, ChannelKey};
use gstore_core::flags::{reset_flags, set_flags, FlagsPatch};
use gstore_host::bridge::CoreApi;
use gstore_host::download_host::HostDownloadPort;
use gstore_host::SqliteScriptChannelStore;

static FLAG_LOCK: Mutex<()> = Mutex::new(());

fn temp_root(tag: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "gstore_host_writes_{tag}_{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn init_api(root: &Path) -> (CoreApi, String) {
    let api = CoreApi::init(
        root.join("data").to_string_lossy().into_owned(),
        root.join("files").to_string_lossy().into_owned(),
        root.join("cache").to_string_lossy().into_owned(),
    )
    .expect("CoreApi::init");
    let db_path = api.migrate_paths().expect("migrate_paths").db_path;
    (api, db_path)
}

fn core_writes_count(db_path: &str) -> i64 {
    let conn = rusqlite::Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("open live db read-only");
    conn.query_row("SELECT COUNT(*) FROM core_writes", [], |row| row.get(0))
        .expect("count core_writes")
}

fn core_writes_domain_count(db_path: &Path, domain: &str) -> i64 {
    let conn = rusqlite::Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .expect("open live db read-only");
    conn.query_row(
        "SELECT COUNT(*) FROM core_writes WHERE domain=?1",
        [domain],
        |row| row.get(0),
    )
    .expect("count domain core_writes")
}

#[test]
fn arm_core_write_projects_flag() {
    let _guard = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    gstore_core::flags::reset_flags();
    let root = temp_root("arm_project");
    let (api, db_path) = init_api(&root);
    assert!(
        !gstore_core::flags::flags().core_writes,
        "fresh init must clear the projection"
    );

    let first = api
        .arm_core_write("channel".to_string())
        .expect("arm channel");
    println!(
        "arm_core_write: domain={} first_write_at={} snapshot={:?}",
        first.domain, first.first_write_at, first.snapshot_id
    );
    assert_eq!(first.domain, "channel");
    assert!(first.snapshot_id.is_none(), "host arm has no snapshot id");
    assert!(
        gstore_core::flags::flags().core_writes,
        "arm must project into the flags read path"
    );

    let again = api
        .arm_core_write("channel".to_string())
        .expect("second arm is idempotent");
    assert_eq!(
        again.first_write_at, first.first_write_at,
        "first write wins"
    );
    assert_eq!(again.snapshot_id, first.snapshot_id);
    assert_eq!(core_writes_count(&db_path), 1, "exactly one marker row");
    println!(
        "idempotent arm: first={} second={} rows={}",
        first.first_write_at,
        again.first_write_at,
        core_writes_count(&db_path)
    );

    let read = api
        .core_write_marker("channel".to_string())
        .expect("read marker")
        .expect("marker present");
    assert_eq!(read.first_write_at, first.first_write_at);
    assert_eq!(
        api.core_writes("channel".to_string())
            .expect("legacy read")
            .expect("legacy marker")
            .first_write_at,
        first.first_write_at,
        "coreWrites and coreWriteMarker must share the DTO"
    );

    gstore_core::flags::reset_flags();
    drop(api);
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn core_writes_rejects_unknown_domain() {
    let _guard = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    gstore_core::flags::reset_flags();
    let root = temp_root("unknown_domain");
    let (api, db_path) = init_api(&root);

    for domain in ["", "../channel", "channel; DROP TABLE core_writes", "CHANNEL"] {
        let arm_err = api
            .arm_core_write(domain.to_string())
            .expect_err("unknown domain must be rejected");
        println!("arm_core_write({domain:?}) -> {arm_err}");
        assert!(
            arm_err.starts_with("CORE_E_CORE_WRITE_DOMAIN"),
            "unexpected arm error for {domain:?}: {arm_err}"
        );
        let read_err = api
            .core_write_marker(domain.to_string())
            .expect_err("unknown domain must be rejected");
        println!("core_write_marker({domain:?}) -> {read_err}");
        assert!(
            read_err.starts_with("CORE_E_CORE_WRITE_DOMAIN"),
            "unexpected read error for {domain:?}: {read_err}"
        );
    }

    assert_eq!(
        core_writes_count(&db_path),
        0,
        "rejected domains must not write rows"
    );
    assert!(
        !gstore_core::flags::flags().core_writes,
        "rejected domains must not arm the projection"
    );
    gstore_core::flags::reset_flags();
    drop(api);
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn core_writes_flag_hydrates_after_reopen() {
    let _guard = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    gstore_core::flags::reset_flags();
    let root = temp_root("hydrate_reopen");
    let (api, _db_path) = init_api(&root);
    api.arm_core_write("catalog".to_string())
        .expect("arm catalog");
    assert!(gstore_core::flags::flags().core_writes);
    drop(api);

    gstore_core::flags::reset_flags();
    assert!(!gstore_core::flags::flags().core_writes);
    let (api, _db_path) = init_api(&root);
    let reopened = gstore_core::flags::flags().core_writes;
    assert!(
        reopened,
        "reopen with an existing marker must hydrate true"
    );
    drop(api);

    let clean = temp_root("hydrate_clean");
    let (api, _db_path) = init_api(&clean);
    let clean_projection = gstore_core::flags::flags().core_writes;
    println!("reopen_projection={reopened} clean_init_projection={clean_projection}");
    assert!(
        !clean_projection,
        "fresh init with zero markers must hydrate false"
    );
    drop(api);
    std::fs::remove_dir_all(&root).unwrap();
    std::fs::remove_dir_all(&clean).unwrap();
}

#[test]
fn core_writes_not_armed_during_migration() {
    let _guard = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    gstore_core::flags::reset_flags();
    let root = temp_root("migration_clean");
    let (api, db_path) = init_api(&root);
    assert!(
        !gstore_core::flags::flags().core_writes,
        "init must hydrate false on an empty database"
    );

    let migration_dir = root.join("files").join("migration");
    let channel_doc = migration_dir.join("channel_env.json");
    std::fs::write(
        &channel_doc,
        br#"{"version":1,"channel_key":"js.clean","env":{"A":"b"}}"#,
    )
    .unwrap();
    api.import_migration_file(
        "channel_env".to_string(),
        channel_doc.to_string_lossy().into_owned(),
    )
    .expect("import channel_env");

    let prefs_doc = migration_dir.join("update_prefs.json");
    std::fs::write(
        &prefs_doc,
        br#"{"version":1,"prefs":{"update_last_checked_at":"1700000000000"}}"#,
    )
    .unwrap();
    api.import_migration_file(
        "update_prefs".to_string(),
        prefs_doc.to_string_lossy().into_owned(),
    )
    .expect("import update_prefs");

    let old_db = root.join("channel_apps.db");
    {
        let conn = rusqlite::Connection::open(&old_db).unwrap();
        conn.execute_batch(
            "CREATE TABLE channel_added_app(
                 appId TEXT NOT NULL, name TEXT NOT NULL, user TEXT NOT NULL,
                 repositories TEXT NOT NULL, apprepo TEXT, icon TEXT NOT NULL,
                 description TEXT NOT NULL, category TEXT, addTime INTEGER NOT NULL,
                 channelCode TEXT NOT NULL, extra TEXT, sourceId TEXT,
                 PRIMARY KEY(channelCode, appId));
             INSERT INTO channel_added_app VALUES
                 ('a','A','u','r',NULL,'i','d',NULL,1,'github',NULL,NULL);
             PRAGMA user_version = 5;",
        )
        .unwrap();
    }
    api.import_migration_file(
        "channel_db".to_string(),
        old_db.to_string_lossy().into_owned(),
    )
    .expect("import channel_db");

    let snapshot = root.join("clean.db");
    api.export_snapshot(snapshot.to_string_lossy().into_owned())
        .expect("export snapshot");
    api.import_snapshot(snapshot.to_string_lossy().into_owned())
        .expect("import snapshot");

    assert_eq!(
        core_writes_count(&db_path),
        0,
        "init/migrate/import/snapshot must not write markers"
    );
    assert!(
        !gstore_core::flags::flags().core_writes,
        "init/migrate/import/snapshot must leave the projection false"
    );
    drop(api);
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn core_writes_projection_follows_snapshot_restore() {
    let _guard = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    gstore_core::flags::reset_flags();

    let armed_root = temp_root("snapshot_armed");
    let (api, _db_path) = init_api(&armed_root);
    api.arm_core_write("download".to_string())
        .expect("arm download");
    let armed_snapshot = armed_root.join("armed.db");
    api.export_snapshot(armed_snapshot.to_string_lossy().into_owned())
        .expect("export armed snapshot");

    let clean_root = temp_root("snapshot_clean");
    let (clean_api, _db_path) = init_api(&clean_root);
    let clean_snapshot = clean_root.join("clean.db");
    clean_api
        .export_snapshot(clean_snapshot.to_string_lossy().into_owned())
        .expect("export clean snapshot");
    drop(clean_api);
    assert!(
        !gstore_core::flags::flags().core_writes,
        "clean init must be false"
    );

    api.import_snapshot(clean_snapshot.to_string_lossy().into_owned())
        .expect("restore clean snapshot");
    let after_clean = gstore_core::flags::flags().core_writes;
    assert!(
        !after_clean,
        "restoring a clean snapshot must clear the projection"
    );

    api.import_snapshot(armed_snapshot.to_string_lossy().into_owned())
        .expect("restore armed snapshot");
    let after_armed = gstore_core::flags::flags().core_writes;
    println!("snapshot_projection_after_clean={after_clean} after_armed={after_armed}");
    assert!(
        after_armed,
        "restoring an armed snapshot must arm the projection"
    );

    gstore_core::flags::reset_flags();
    drop(api);
    std::fs::remove_dir_all(&armed_root).unwrap();
    std::fs::remove_dir_all(&clean_root).unwrap();
}

struct InitReconcileBridge;

fn task_json(id: u64) -> serde_json::Value {
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

impl ModuleBridge for InitReconcileBridge {
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
                serde_json::to_vec(&task_json(id)).map_err(|e| e.to_string())
            }
            other => Err(format!("unexpected method {other}")),
        }
    }
}

fn start_request() -> DownloadRequest {
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
        dedup_key: "dedup:init".to_string(),
        expected_sha256: None,
        install_after_download: false,
    }
}

#[test]
fn core_writes_init_reconcile_does_not_arm() {
    let _guard = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    reset_flags();
    set_flags(FlagsPatch {
        download: Some(true),
        ..FlagsPatch::default()
    })
    .expect("flip download");

    let root = temp_root("init_reconcile");
    let data_dir = root.join("data");
    std::fs::create_dir_all(&data_dir).unwrap();
    let handle = DbHandle::open(&data_dir).expect("open core db");
    handle
        .writer()
        .unwrap()
        .execute(
            "INSERT INTO download_task(module_task_id, app_id, app_name, version, file_name, \
                 url, dest_path, status, created_at, updated_at) \
             VALUES ('42', 'app.demo', 'Demo', '1.0', 'demo.apk', \
                 'https://example.test/demo.apk', '/tmp/demo.apk', 'running', 1, 1)",
            [],
        )
        .unwrap();
    let conn = handle.shared_writer();
    let core_db = data_dir.join("gstore_core.db");

    let download =
        HostDownloadPort::with_bridge_for_test(InitReconcileBridge, conn.clone(), core_db.clone(), None);
    let api = CoreApi::init_with_download_port_for_test(
        data_dir.to_string_lossy().into_owned(),
        root.join("files").to_string_lossy().into_owned(),
        root.join("cache").to_string_lossy().into_owned(),
        download,
    )
    .expect("CoreApi::init");
    let db_path = api.migrate_paths().expect("migrate_paths").db_path;

    let during_init = core_writes_count(&db_path);
    let projection = gstore_core::FlagsApi::new().get().core_writes;
    println!("init reconcile: core_writes={during_init} projection={projection}");
    assert_eq!(during_init, 0, "init reconcile must not write a marker");
    assert!(!projection, "init reconcile must not arm the projection");

    let port = HostDownloadPort::with_bridge_for_test(InitReconcileBridge, conn.clone(), core_db, None);
    port.start(&start_request()).expect("post-init download start");
    let marker = api
        .core_write_marker("download".to_string())
        .expect("read marker")
        .expect("post-init mutation must mark");
    println!(
        "post-init mutation: download_marker={} first_write_at={} rows={} projection={}",
        marker.domain,
        marker.first_write_at,
        core_writes_count(&db_path),
        gstore_core::FlagsApi::new().get().core_writes
    );
    assert_eq!(marker.domain, "download");
    assert_eq!(core_writes_count(&db_path), 1, "exactly one marker row");
    assert!(
        gstore_core::FlagsApi::new().get().core_writes,
        "post-init mutation must still arm the projection"
    );

    reset_flags();
    drop(api);
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn js_channel_store_write_marks_core_writes_once() {
    let _guard = FLAG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    gstore_core::flags::reset_flags();
    let root = temp_root("js_channel_marker");
    let db = DbHandle::open(&root.join("data")).expect("open core db");
    let store = SqliteScriptChannelStore::new(db.clone());
    let key = ChannelKey::new("js_marker").expect("channel key");
    let app = AppSummary {
        app_id: "app.marker".to_string(),
        package_name: None,
        name: "Marker".to_string(),
        user: "team".to_string(),
        repositories: "marker".to_string(),
        icon: String::new(),
        des: "desc".to_string(),
        readme: None,
        category: None,
        extra: None,
    };

    store
        .insert_apps(&key, std::slice::from_ref(&app))
        .expect("first js_channel insert");
    let first = core_writes_domain_count(db.path(), "js_channel");
    assert_eq!(first, 1, "one js_channel marker row after insert");

    store
        .insert_apps(&key, std::slice::from_ref(&app))
        .expect("second js_channel insert");
    let second = core_writes_domain_count(db.path(), "js_channel");
    assert_eq!(second, 1, "second write is idempotent");

    store.remove_app(&key, "app.marker").expect("js_channel remove");
    let after_remove = core_writes_domain_count(db.path(), "js_channel");
    assert_eq!(after_remove, 1, "remove reuses the same marker row");

    println!(
        "PASS | js_channel core_writes | insert={first} second={second} remove={after_remove}"
    );

    gstore_core::flags::reset_flags();
    drop(db);
    std::fs::remove_dir_all(&root).unwrap();
}
