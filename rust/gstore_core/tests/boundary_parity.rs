//! F2 boundary parity: the SQL-fed `UpdateService` must reproduce the
//! pre-change `PlatformHost` fixture, the install request/response flow, and
//! the typed missing-facts failure.
//!
//! The expected update lines below were captured from the pre-change tree
//! (`70f6b3f2`) by running the old `PlatformHost`-backed fixture and printing
//! one normalized line per app. This test seeds the same data through SQL only
//! (`installed_app` + the single `platform_facts` row), then asserts the same
//! lines in code — it never reads the evidence file.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::channel::{ChannelDriver, InMemoryChannelDriver};
use gstore_core::db::{DbHandle, SharedConn};
use gstore_core::dto::{
    AppDetail, AppDownload, AppUpdate, ChannelKey, ChannelKind, ChannelMeta, DetailSection,
};
use gstore_core::error::Error;
use gstore_core::facts::{
    InstallReport, InstallReportStatus, InstallStart, InstalledApp, InventorySnapshot,
};
use gstore_core::install::{
    InstallService, INSTALL_STATUS_INSTALLED, INSTALL_STATUS_PENDING, INSTALL_STATUS_UNKNOWN,
};
use gstore_core::inventory::InventoryStore;
use gstore_core::update::service::{ChannelResolver, UpdateCheckReport, UpdateService};
use gstore_core::CoreEvent;
use rusqlite::params;

const SOURCE: &str = "android";

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_boundary_{tag}_{}_{}",
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

fn meta(code: &str) -> ChannelMeta {
    ChannelMeta {
        kind: ChannelKind::Custom,
        name: code.to_string(),
        description: format!("{code} channel"),
        enabled: true,
        priority: 0,
        support_offline: true,
        last_update_time: None,
        version: Some("1".to_string()),
    }
}

fn driver(code: &str, updates: Vec<AppUpdate>) -> Arc<dyn ChannelDriver> {
    let key = ChannelKey::new(code).unwrap();
    Arc::new(InMemoryChannelDriver::new(key, meta(code)).with_updates(updates))
}

fn resolver(drivers: Vec<Arc<dyn ChannelDriver>>) -> ChannelResolver {
    let map: std::collections::BTreeMap<String, Arc<dyn ChannelDriver>> = drivers
        .into_iter()
        .map(|driver| (driver.key().as_str().to_string(), driver))
        .collect();
    Arc::new(move |code: &str| map.get(code).cloned())
}

fn download(name: &str, platform: Option<&str>) -> AppDownload {
    AppDownload {
        url: format!("https://example.test/{name}"),
        name: name.to_string(),
        size: Some(100),
        download_count: Some(7),
        version: Some("2.0.0".to_string()),
        version_code: Some(2),
        published_at: Some(1_600_000_000_000),
        platform: platform.map(str::to_string),
        hash: Some("abc".to_string()),
        hash_type: Some("sha256".to_string()),
        downloadable: true,
        note: None,
        extra: None,
    }
}

fn update(
    app_id: &str,
    package: &str,
    name: &str,
    latest: Option<&str>,
    icon: Option<&str>,
    downloads: Vec<AppDownload>,
) -> AppUpdate {
    AppUpdate {
        app_id: app_id.to_string(),
        package_name: package.to_string(),
        name: name.to_string(),
        icon: icon.map(str::to_string),
        latest_version: latest.map(str::to_string),
        latest_download: None,
        detail: AppDetail {
            app_id: app_id.to_string(),
            name: name.to_string(),
            icon: icon.unwrap_or_default().to_string(),
            description: String::new(),
            version: latest.map(str::to_string),
            developer: None,
            package_name: Some(package.to_string()),
            project_url: None,
            channel: ChannelKind::Custom,
            sections: vec![DetailSection::Version, DetailSection::Downloads],
            downloads,
            extra: serde_json::Map::new(),
            labels: Vec::new(),
        },
    }
}

fn installed(package: &str, version: &str) -> InstalledApp {
    InstalledApp {
        package_name: package.to_string(),
        app_name: Some(package.to_string()),
        version_name: version.to_string(),
        version_code: 1,
        signature_sha256: None,
        source_dir: None,
        installer: None,
        is_system: false,
        target_sdk: 35,
        min_sdk: 21,
        abis: vec!["arm64-v8a".to_string()],
    }
}

fn clock_at(value: i64) -> (Arc<AtomicI64>, Arc<dyn Fn() -> i64 + Send + Sync>) {
    let cell = Arc::new(AtomicI64::new(value));
    let reader = Arc::clone(&cell);
    (cell, Arc::new(move || reader.load(Ordering::SeqCst)))
}

/// Seeds app rows and the single facts row through SQL, exactly as the
/// frontend push would persist them.
fn seed_sql(db: &DbHandle, apps: &[InstalledApp], captured_at: i64, abis: &[&str]) {
    let mut conn = db.writer().unwrap();
    let tx = conn.transaction().unwrap();
    tx.execute(
        "INSERT INTO inventory_source(source_id, seq, captured_at) VALUES (?1, 1, ?2) \
         ON CONFLICT(source_id) DO UPDATE SET seq=excluded.seq, captured_at=excluded.captured_at",
        params![SOURCE, captured_at],
    )
    .unwrap();
    for app in apps {
        tx.execute(
            "INSERT INTO installed_app(\
                 source_id, package_name, app_name, version_name, version_code, signature_sha256, \
                 source_dir, installer, is_system, target_sdk, min_sdk, abis_json, captured_at\
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                SOURCE,
                app.package_name,
                app.app_name,
                app.version_name,
                app.version_code,
                app.signature_sha256,
                app.source_dir,
                app.installer,
                i64::from(app.is_system),
                app.target_sdk,
                app.min_sdk,
                serde_json::to_string(&app.abis).unwrap(),
                captured_at,
            ],
        )
        .unwrap();
    }
    let facts = serde_json::json!({
        "source_id": SOURCE,
        "os": "android",
        "arch": "aarch64",
        "abis": abis,
        "sdk": 35,
        "device": {"model": "Fixture Phone", "manufacturer": "Fixture"},
        "paths": {
            "data": "/data/user/0/com.example.gstore",
            "files": "/data/user/0/com.example.gstore/files",
            "cache": "/data/user/0/com.example.gstore/cache"
        },
        "crypto_key": null,
        "captured_at": captured_at
    });
    tx.execute(
        "INSERT INTO platform_facts(id, json, source_id, captured_at) VALUES (1, ?1, ?2, ?3) \
         ON CONFLICT(id) DO UPDATE SET json=excluded.json, source_id=excluded.source_id, \
             captured_at=excluded.captured_at",
        params![facts.to_string(), SOURCE, captured_at],
    )
    .unwrap();
    tx.commit().unwrap();
}

fn add_added(db: &DbHandle, channel: &str, app_id: &str, add_time: i64) {
    db.writer()
        .unwrap()
        .execute(
            "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
             VALUES (?1, ?2, ?3, 0, 1)",
            params![channel, app_id, add_time],
        )
        .unwrap();
}

fn insert_pref(db: &DbHandle, key: &str, value: &str) {
    db.writer()
        .unwrap()
        .execute(
            "INSERT INTO update_prefs(key, value, imported_at) VALUES (?1, ?2, 1) \
             ON CONFLICT(key) DO UPDATE SET value=excluded.value, imported_at=excluded.imported_at",
            params![key, value],
        )
        .unwrap();
}

fn parity_drivers() -> Vec<Arc<dyn ChannelDriver>> {
    vec![
        driver(
            "github",
            vec![update(
                "A",
                "com.a",
                "App A",
                Some("2.0.0"),
                Some("https://example.test/a.png"),
                vec![
                    download("app-arm64-v8a.apk", Some("arm64-v8a")),
                    download("app-universal.apk", Some("universal")),
                ],
            )],
        ),
        driver(
            "fdroid",
            vec![update(
                "B",
                "com.b",
                "App B",
                Some("2.0.0"),
                None,
                vec![download("b-universal.apk", Some("universal"))],
            )],
        ),
        driver(
            "local_db",
            vec![update(
                "C",
                "com.c",
                "App C",
                Some("2.0.0"),
                None,
                vec![download("c.apk", None)],
            )],
        ),
    ]
}

fn line_for(
    report: &UpdateCheckReport,
    app_id: &str,
    fallback_installed: &str,
    fallback_latest: &str,
) -> String {
    match report.updates.iter().find(|info| info.app_id == app_id) {
        Some(info) => format_line(
            app_id,
            &info.installed_version,
            &info.latest_version,
            Some(&info.download),
        ),
        None => format!("{app_id} | {fallback_installed} | {fallback_latest} | -"),
    }
}

fn format_line(
    app_id: &str,
    installed_version: &str,
    latest_version: &str,
    chosen: Option<&gstore_core::update::service::CachedDownload>,
) -> String {
    match chosen {
        Some(download) => format!(
            "{app_id} | {installed_version} | {latest_version} | {} ({}) {}",
            download.name,
            download.platform.as_deref().unwrap_or("-"),
            download.url
        ),
        None => format!("{app_id} | {installed_version} | {latest_version} | -"),
    }
}

fn main_fixture_lines() -> Vec<String> {
    let dir = TempDir::new("main");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "A", 3000);
    add_added(&db, "fdroid", "B", 2000);
    add_added(&db, "local_db", "C", 1000);
    seed_sql(
        &db,
        &[installed("com.a", "1.0.0"), installed("com.b", "1.0.0")],
        1_000_000,
        &["arm64-v8a"],
    );
    let (_, clock) = clock_at(1_000_000);
    let service = UpdateService::with_clock(db, resolver(parity_drivers()), clock);
    let report = service.check_all(true).expect("check_all");

    vec![
        line_for(&report, "A", "-", "-"),
        line_for(&report, "B", "-", "-"),
        line_for(&report, "C", "-", "2.0.0"),
    ]
}

fn scenario_line(
    name: &str,
    candidates: Vec<AppDownload>,
    device_abis: &[&str],
    preference: Option<&str>,
) -> String {
    let dir = TempDir::new(name);
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "A", 1000);
    if let Some(preferred) = preference {
        insert_pref(
            &db,
            "update_preferred_apk",
            &format!(r#"{{"github:A":"{preferred}"}}"#),
        );
    }
    seed_sql(&db, &[installed("com.a", "1.0.0")], 1_000_000, device_abis);
    let drivers = vec![driver(
        "github",
        vec![update(
            "A",
            "com.a",
            "App A",
            Some("2.0.0"),
            None,
            candidates,
        )],
    )];
    let (_, clock) = clock_at(1_000_000);
    let service = UpdateService::with_clock(db, resolver(drivers), clock);
    let report = service.check_all(true).expect("check_all");
    line_for(&report, "A", "1.0.0", "2.0.0")
}

fn multi_apk() -> Vec<AppDownload> {
    vec![
        download("app-arm64-v8a.apk", Some("arm64-v8a")),
        download("app-armeabi-v7a.apk", Some("armeabi-v7a")),
        download("app-universal.apk", Some("universal")),
    ]
}

#[test]
fn update_fixture_matches_pre_change_oracle() {
    let observed = main_fixture_lines();
    let expected = [
        "A | 1.0.0 | 2.0.0 | app-arm64-v8a.apk (arm64-v8a) https://example.test/app-arm64-v8a.apk",
        "B | 1.0.0 | 2.0.0 | b-universal.apk (universal) https://example.test/b-universal.apk",
        "C | - | 2.0.0 | -",
    ];
    println!("scenario=main-default");
    for line in &observed {
        println!("{line}");
    }
    assert_eq!(observed, expected);
}

#[test]
fn variant_choice_matches_pre_change_oracle() {
    let cases: [(&str, Vec<AppDownload>, &[&str], Option<&str>, &str); 5] = [
        (
            "abi-arm64-first",
            multi_apk(),
            &["arm64-v8a", "armeabi-v7a"],
            None,
            "A | 1.0.0 | 2.0.0 | app-arm64-v8a.apk (arm64-v8a) https://example.test/app-arm64-v8a.apk",
        ),
        (
            "abi-order-v7a-first",
            multi_apk(),
            &["armeabi-v7a", "arm64-v8a"],
            None,
            "A | 1.0.0 | 2.0.0 | app-armeabi-v7a.apk (armeabi-v7a) https://example.test/app-armeabi-v7a.apk",
        ),
        (
            "abi-universal-fallback",
            multi_apk(),
            &["x86_64"],
            None,
            "A | 1.0.0 | 2.0.0 | app-universal.apk (universal) https://example.test/app-universal.apk",
        ),
        (
            "abi-universal-before-arm64",
            vec![
                download("app-universal.apk", Some("universal")),
                download("app-arm64-v8a.apk", Some("arm64-v8a")),
            ],
            &["arm64-v8a"],
            None,
            "A | 1.0.0 | 2.0.0 | app-universal.apk (universal) https://example.test/app-universal.apk",
        ),
        (
            "pref-override",
            vec![
                download("app-arm64-v8a.apk", Some("arm64-v8a")),
                download("app-universal.apk", Some("universal")),
            ],
            &["arm64-v8a"],
            Some("app-universal.apk"),
            "A | 1.0.0 | 2.0.0 | app-universal.apk (universal) https://example.test/app-universal.apk",
        ),
    ];

    for (name, candidates, device_abis, preference, expected) in cases {
        let observed = scenario_line(name, candidates, device_abis, preference);
        println!("scenario={name}");
        println!("{observed}");
        assert_eq!(observed, expected, "scenario {name}");
    }
}

#[test]
fn missing_platform_facts_is_typed() {
    let dir = TempDir::new("missing_facts");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "A", 1000);
    db.writer()
        .unwrap()
        .execute(
            "INSERT INTO inventory_source(source_id, seq, captured_at) VALUES (?1, 1, 1000000)",
            [SOURCE],
        )
        .unwrap();
    let (_, clock) = clock_at(1_000_000);
    let service = UpdateService::with_clock(db, resolver(parity_drivers()), clock);
    match service.check_all(true) {
        Err(Error::Unsupported(message)) => {
            println!("malformed-flow: check_all -> Err(Unsupported) {message}");
            assert!(message.contains("CORE_E_FACTS_MISSING"), "{message}");
        }
        other => panic!("expected typed CORE_E_FACTS_MISSING, got {other:?}"),
    }
}

fn make_apk(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, b"PK\x03\x04fake-apk").unwrap();
    path
}

fn seed_task(conn: &SharedConn, task_id: &str, apk: &Path) {
    conn.lock()
        .unwrap()
        .execute(
            "INSERT INTO download_task(\
                 module_task_id, app_id, resource_id, app_name, version, url, file_name, \
                 status, dest_path, install_after_download, created_at, updated_at\
             ) VALUES (?1, 'app.demo', 'com.example.demo', 'Demo', '1.2.3', ?2, ?3, \
                 'completed', ?4, 0, 1, 1)",
            params![
                task_id,
                format!(
                    "https://example.test/{}",
                    apk.file_name().unwrap().to_string_lossy()
                ),
                apk.file_name().unwrap().to_string_lossy().to_string(),
                apk.to_string_lossy().to_string()
            ],
        )
        .unwrap();
}

fn report(session_id: &str, status: InstallReportStatus, version: Option<&str>) -> InstallReport {
    InstallReport {
        session_id: session_id.to_string(),
        status,
        method: "shizuku".to_string(),
        installed_version: version.map(str::to_string),
        error: None,
        reported_at: 1,
    }
}

fn pending_of(start: &InstallStart) -> &gstore_core::facts::InstallRequest {
    start
        .request
        .as_ref()
        .unwrap_or_else(|| panic!("expected an install request, got {start:?}"))
}

fn status_of(conn: &SharedConn, task_id: &str) -> String {
    conn.lock()
        .unwrap()
        .query_row(
            "SELECT install_status FROM download_task WHERE module_task_id=?1",
            [task_id],
            |row| row.get(0),
        )
        .unwrap()
}

fn requested_events(events: &[CoreEvent]) -> usize {
    events
        .iter()
        .filter(|event| event.wire_name() == "install.requested")
        .count()
}

#[test]
fn install_end_to_end_matches_contract() {
    let dir = TempDir::new("install_e2e");
    let db = DbHandle::open(dir.path()).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app-arm64-v8a.apk");
    seed_task(&conn, "task-e2e", &apk);
    let (_, clock) = clock_at(1_000);
    let service = InstallService::with_clock(Arc::clone(&conn), clock);

    let start = service.install("task-e2e").unwrap();
    let request = pending_of(&start).clone();
    println!(
        "request -> request=Some session_present={} method={} abi={}",
        !request.session_id.is_empty(),
        request.method,
        request.variant.abi
    );
    assert_eq!(status_of(&conn, "task-e2e"), INSTALL_STATUS_PENDING);

    let events = service.take_events();
    let requested = requested_events(&events);
    println!("install.requested event -> count={requested}");
    assert_eq!(requested, 1);

    let ack = service
        .on_result(report(
            &request.session_id,
            InstallReportStatus::Installed,
            Some("1.2.3"),
        ))
        .unwrap();
    println!(
        "report(installed) -> changed={} status={}",
        ack.changed, ack.status
    );
    assert!(ack.changed);
    assert_eq!(status_of(&conn, "task-e2e"), INSTALL_STATUS_INSTALLED);

    let duplicate = service
        .on_result(report(
            &request.session_id,
            InstallReportStatus::Installed,
            Some("9.9.9"),
        ))
        .unwrap();
    println!(
        "double-report -> changed={} status={}",
        duplicate.changed, duplicate.status
    );
    assert!(!duplicate.changed);

    let dir = TempDir::new("install_timeout");
    let db = DbHandle::open(dir.path()).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-timeout", &apk);
    let (cell, clock) = clock_at(1_000);
    let service = InstallService::with_clock(Arc::clone(&conn), clock);
    let session = pending_of(&service.install("task-timeout").unwrap())
        .session_id
        .clone();
    let _ = service.take_events();

    cell.store(1_000 + 180_000 + 1, Ordering::SeqCst);
    let swept = service
        .sweep_timeouts((cell.load(Ordering::SeqCst)) as i64)
        .unwrap();
    let unknown_wire = swept
        .iter()
        .filter(|event| event.wire_name() == "install.unknown")
        .count();
    println!(
        "timeout-flow -> sweep_events={} install.unknown={} status={}",
        swept.len(),
        unknown_wire,
        status_of(&conn, "task-timeout")
    );
    assert_eq!(unknown_wire, 1);
    assert_eq!(status_of(&conn, "task-timeout"), INSTALL_STATUS_UNKNOWN);
    assert!(service.pending_requests().unwrap().is_empty());
    println!(
        "timeout-flow -> pendingRequests={}",
        service.pending_requests().unwrap().len()
    );

    let late = service
        .on_result(report(
            &session,
            InstallReportStatus::Installed,
            Some("1.2.4"),
        ))
        .unwrap();
    println!("late-report(no retry) -> changed={}", late.changed);
    assert!(late.changed);
    assert_eq!(status_of(&conn, "task-timeout"), INSTALL_STATUS_INSTALLED);

    let dir = TempDir::new("install_retry_late");
    let db = DbHandle::open(dir.path()).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-retry-late", &apk);
    let (cell, clock) = clock_at(1_000);
    let service = InstallService::with_clock(Arc::clone(&conn), clock);
    let old_session = pending_of(&service.install("task-retry-late").unwrap())
        .session_id
        .clone();
    let _ = service.take_events();
    cell.store(1_000 + 180_000 + 1, Ordering::SeqCst);
    service.sweep_timeouts(cell.load(Ordering::SeqCst)).unwrap();
    let retried = service.install("task-retry-late").unwrap();
    let new_session = pending_of(&retried).session_id.clone();
    match service.on_result(report(
        &old_session,
        InstallReportStatus::Installed,
        Some("1.2.3"),
    )) {
        Err(Error::NotFound(message)) => {
            println!("retry-then-late-report -> Err(NotFound) CORE_E_INSTALL_SESSION");
            assert!(message.contains("CORE_E_INSTALL_SESSION"), "{message}");
        }
        other => panic!("a retry must invalidate the old session, got {other:?}"),
    }
    assert_ne!(new_session, old_session);
    assert_eq!(status_of(&conn, "task-retry-late"), INSTALL_STATUS_PENDING);

    let dir = TempDir::new("install_restart");
    let db_path = dir.path().join("gstore_core.db");
    let apk = make_apk(dir.path(), "app.apk");
    let session;
    {
        let db = DbHandle::open(&db_path).unwrap();
        let conn = db.shared_writer();
        seed_task(&conn, "task-restart", &apk);
        let (_, clock) = clock_at(1_000);
        let service = InstallService::with_clock(Arc::clone(&conn), clock);
        session = pending_of(&service.install("task-restart").unwrap())
            .session_id
            .clone();
    }
    let db = DbHandle::open(&db_path).unwrap();
    let conn = db.shared_writer();
    let (_, clock) = clock_at(1_000);
    let service = InstallService::with_clock(Arc::clone(&conn), clock);
    let pending = service.pending_requests().unwrap();
    println!(
        "restart-flow -> pendingRequests={} session_present={}",
        pending.len(),
        pending
            .first()
            .map(|start| pending_of(start).session_id == session)
            .unwrap_or(false)
    );
    assert_eq!(pending.len(), 1);
    assert_eq!(pending_of(&pending[0]).session_id, session);
}

/// Guard against an unseeded inventory being mistaken for a missing update:
/// the store-backed path must persist the same rows the fixture asserts.
#[test]
fn inventory_push_roundtrips_fixture() {
    let dir = TempDir::new("inventory");
    let db = DbHandle::open(dir.path()).unwrap();
    let store = InventoryStore::new(db.clone());
    let snapshot = InventorySnapshot {
        source_id: SOURCE.to_string(),
        seq: 1,
        captured_at: 1_000_000,
        apps: vec![installed("com.a", "1.0.0")],
    };
    assert!(store.push(&snapshot).unwrap().accepted);
    let back = store.get("com.a").unwrap().unwrap();
    assert_eq!(back.version_name, "1.0.0");
    assert_eq!(back.package_name, "com.a");
}
