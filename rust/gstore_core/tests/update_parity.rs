//! Update service parity: state/log persistence, exact version compare, ABI
//! selection, the one-hour cache, preferred APKs, and `update.found`.
//!
//! Installed apps and device ABIs come from the stored `installed_app` /
//! `platform_facts` tables (SQL fixtures below), never from a platform port.

use std::cmp::Ordering as CmpOrdering;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::channel::{ChannelDriver, InMemoryChannelDriver};
use gstore_core::db::DbHandle;
use gstore_core::dto::{
    AppDetail, AppDownload, AppUpdate, ChannelKey, ChannelKind, ChannelMeta, DetailSection,
};
use gstore_core::error::Error;
use gstore_core::facts::{CorePaths, DeviceFacts, InstalledApp, PlatformFacts};
use gstore_core::migration::update_pref;
use gstore_core::update::service::{
    asset_matches_abi, compare_versions, normalize_abi, pick_closest_apk, select_best_download,
    select_download_with_preference, AppUpdateInfo, ChannelResolver, CheckLogLevel, UpdateService,
    UPDATE_CACHE_TTL_MS,
};
use rusqlite::params;
use serde_json::{json, Value};

const SOURCE: &str = "android";

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_update_{tag}_{}_{}",
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

#[allow(clippy::too_many_arguments)]
fn update(
    app_id: &str,
    package: &str,
    name: &str,
    latest: Option<&str>,
    icon: Option<&str>,
    downloads: Vec<AppDownload>,
    latest_download: Option<AppDownload>,
) -> AppUpdate {
    AppUpdate {
        app_id: app_id.to_string(),
        package_name: package.to_string(),
        name: name.to_string(),
        icon: icon.map(str::to_string),
        latest_version: latest.map(str::to_string),
        latest_download,
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

fn facts(source: &str, captured_at: i64, abis: &[&str]) -> PlatformFacts {
    PlatformFacts {
        source_id: source.to_string(),
        os: "android".to_string(),
        arch: "aarch64".to_string(),
        abis: abis.iter().map(|abi| (*abi).to_string()).collect(),
        sdk: 35,
        device: DeviceFacts {
            model: "Fixture Phone".to_string(),
            manufacturer: "Fixture".to_string(),
        },
        paths: CorePaths {
            data: "/data/user/0/com.example.gstore".to_string(),
            files: "/data/user/0/com.example.gstore/files".to_string(),
            cache: "/data/user/0/com.example.gstore/cache".to_string(),
        },
        crypto_key: None,
        captured_at,
    }
}

fn seed_facts(db: &DbHandle, source: &str, captured_at: i64, abis: &[&str]) {
    let remaining = facts(source, captured_at, abis);
    let encoded = serde_json::to_string(&remaining).unwrap();
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO platform_facts(id, json, source_id, captured_at) VALUES (1, ?1, ?2, ?3) \
         ON CONFLICT(id) DO UPDATE SET json=excluded.json, source_id=excluded.source_id, \
             captured_at=excluded.captured_at",
        params![encoded, source, captured_at],
    )
    .unwrap();
}

fn seed_inventory(db: &DbHandle, source: &str, captured_at: i64, apps: &[InstalledApp]) {
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO inventory_source(source_id, seq, captured_at) VALUES (?1, 1, ?2) \
         ON CONFLICT(source_id) DO UPDATE SET seq=excluded.seq, captured_at=excluded.captured_at",
        params![source, captured_at],
    )
    .unwrap();
    for app in apps {
        conn.execute(
            "INSERT INTO installed_app(\
                 source_id, package_name, app_name, version_name, version_code, signature_sha256, \
                 source_dir, installer, is_system, target_sdk, min_sdk, abis_json, captured_at\
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) \
             ON CONFLICT(source_id, package_name) DO UPDATE SET \
                 app_name=excluded.app_name, version_name=excluded.version_name, \
                 version_code=excluded.version_code, abis_json=excluded.abis_json, \
                 captured_at=excluded.captured_at",
            params![
                source,
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
}

fn set_inventory_version(db: &DbHandle, package: &str, version: &str) {
    db.writer()
        .unwrap()
        .execute(
            "UPDATE installed_app SET version_name=?1 WHERE package_name=?2",
            params![version, package],
        )
        .unwrap();
}

fn remove_inventory_package(db: &DbHandle, package: &str) {
    db.writer()
        .unwrap()
        .execute("DELETE FROM installed_app WHERE package_name=?1", [package])
        .unwrap();
}

fn add_added(db: &DbHandle, channel: &str, app_id: &str, add_time: i64) {
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO added_apps(channel_id, app_id, add_time, sort_order, is_enabled) \
         VALUES (?1, ?2, ?3, 0, 1)",
        params![channel, app_id, add_time],
    )
    .unwrap();
}

fn insert_pref(db: &DbHandle, key: &str, value: &str) {
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO update_prefs(key, value, imported_at) VALUES (?1, ?2, 1) \
         ON CONFLICT(key) DO UPDATE SET value=excluded.value, imported_at=excluded.imported_at",
        params![key, value],
    )
    .unwrap();
}

fn clock_at(value: i64) -> (Arc<AtomicI64>, Arc<dyn Fn() -> i64 + Send + Sync>) {
    let cell = Arc::new(AtomicI64::new(value));
    let reader = Arc::clone(&cell);
    (cell, Arc::new(move || reader.load(Ordering::SeqCst)))
}

fn make_service(
    db: &DbHandle,
    drivers: Vec<Arc<dyn ChannelDriver>>,
    clock: Arc<dyn Fn() -> i64 + Send + Sync>,
) -> UpdateService {
    UpdateService::with_clock(db.clone(), resolver(drivers), clock)
}

fn find<'a>(updates: &'a [AppUpdateInfo], app_id: &str) -> &'a AppUpdateInfo {
    updates
        .iter()
        .find(|info| info.app_id == app_id)
        .unwrap_or_else(|| panic!("missing update for {app_id}"))
}

fn skip_reason<'a>(
    skipped: &'a [gstore_core::update::service::UpdateSkip],
    app_id: &str,
) -> &'a str {
    &skipped
        .iter()
        .find(|skip| skip.app_id == app_id)
        .unwrap_or_else(|| panic!("missing skip for {app_id}"))
        .reason
}

fn db_count(db: &DbHandle, table: &str) -> i64 {
    let conn = db.reader().unwrap();
    conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
        row.get(0)
    })
    .unwrap()
}

fn db_status(db: &DbHandle, app_id: &str) -> String {
    let conn = db.reader().unwrap();
    conn.query_row(
        "SELECT status FROM update_state WHERE app_id=?1",
        [app_id],
        |row| row.get(0),
    )
    .unwrap()
}

fn pref(db: &DbHandle, key: &str) -> Option<String> {
    let conn = db.reader().unwrap();
    update_pref(&conn, key).unwrap()
}

fn state_rows(db: &DbHandle) -> Vec<Value> {
    let conn = db.reader().unwrap();
    let mut stmt = conn
        .prepare(
            "SELECT app_id, channel_key, latest_version, status, checked_at, payload_json \
             FROM update_state ORDER BY app_id, channel_key",
        )
        .unwrap();
    stmt.query_map([], |row| {
        Ok(json!({
            "appId": row.get::<_, String>(0)?,
            "channelKey": row.get::<_, String>(1)?,
            "latestVersion": row.get::<_, Option<String>>(2)?,
            "status": row.get::<_, String>(3)?,
            "checkedAt": row.get::<_, Option<i64>>(4)?,
            "payload": row.get::<_, Option<String>>(5)?,
        }))
    })
    .unwrap()
    .map(Result::unwrap)
    .collect()
}

fn log_rows(db: &DbHandle) -> Vec<Value> {
    let conn = db.reader().unwrap();
    let mut stmt = conn
        .prepare(
            "SELECT id, app_id, channel_key, from_version, to_version, status, checked_at, payload_json \
             FROM update_log ORDER BY id",
        )
        .unwrap();
    stmt.query_map([], |row| {
        Ok(json!({
            "id": row.get::<_, i64>(0)?,
            "appId": row.get::<_, String>(1)?,
            "channelKey": row.get::<_, String>(2)?,
            "fromVersion": row.get::<_, Option<String>>(3)?,
            "toVersion": row.get::<_, Option<String>>(4)?,
            "status": row.get::<_, String>(5)?,
            "checkedAt": row.get::<_, i64>(6)?,
            "payload": row.get::<_, Option<String>>(7)?,
        }))
    })
    .unwrap()
    .map(Result::unwrap)
    .collect()
}

fn pref_rows(db: &DbHandle) -> Vec<Value> {
    let conn = db.reader().unwrap();
    let mut stmt = conn
        .prepare("SELECT key, value FROM update_prefs ORDER BY key")
        .unwrap();
    stmt.query_map([], |row| {
        Ok(json!({
            "key": row.get::<_, String>(0)?,
            "value": row.get::<_, String>(1)?,
        }))
    })
    .unwrap()
    .map(Result::unwrap)
    .collect()
}

fn write_evidence(value: &Value) {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-evidence/66-update.json");
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, serde_json::to_vec_pretty(value).unwrap()).unwrap();
}

fn write_db_snapshot(db: &DbHandle) {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-evidence/66-update.db");
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    let _ = std::fs::remove_file(&path);
    db.with_writer(|conn| {
        conn.execute("VACUUM INTO ?1", [path.to_string_lossy().into_owned()])
            .map(|_| ())
            .map_err(|error| gstore_core::db::DbError(error.to_string()))
    })
    .unwrap();
}

fn parity_fixture() -> (TempDir, DbHandle, Vec<Arc<dyn ChannelDriver>>) {
    let dir = TempDir::new("parity");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "A", 3000);
    add_added(&db, "fdroid", "B", 2000);
    add_added(&db, "local_db", "C", 1000);

    let drivers = vec![
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
                None,
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
                None,
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
                None,
            )],
        ),
    ];
    (dir, db, drivers)
}

#[test]
fn update_parity() {
    let (_dir, db, drivers) = parity_fixture();
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a"]);
    seed_inventory(
        &db,
        SOURCE,
        1_000_000,
        &[installed("com.a", "1.0.0"), installed("com.b", "1.0.0")],
    );
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers, clock);

    let report = service.check_all(false).expect("check_all");
    assert_eq!(report.total, 3);
    assert_eq!(report.updates.len(), 2);
    assert!(!report.used_cache);
    assert_eq!(report.checked_at, 1_000_000);

    let a = find(&report.updates, "A");
    assert_eq!(a.channel_id, "github");
    assert_eq!(a.app_name, "App A");
    assert_eq!(a.package_name, "com.a");
    assert_eq!(a.installed_version, "1.0.0");
    assert_eq!(a.latest_version, "2.0.0");
    assert_eq!(a.icon_url.as_deref(), Some("https://example.test/a.png"));
    assert_eq!(a.download.name, "app-arm64-v8a.apk");
    assert_eq!(a.download.size, Some(100));
    assert_eq!(a.download.download_count, Some(7));
    assert!(a.detail.is_some());
    assert_eq!(find(&report.updates, "B").download.name, "b-universal.apk");
    assert_eq!(skip_reason(&report.skipped, "C"), "inventory_missing");

    assert_eq!(report.events.len(), 2);
    let event = serde_json::to_value(&report.events[0]).unwrap();
    assert_eq!(event["event"], "update.found");
    assert_eq!(event["payload"]["key"], "github");
    assert_eq!(event["payload"]["app_id"], "A");
    assert_eq!(event["payload"]["update"]["app_id"], "A");
    assert!(report
        .events
        .iter()
        .all(|event| serde_json::to_value(event).unwrap()["event"] == "update.found"));

    assert_eq!(db_count(&db, "update_state"), 3);
    assert_eq!(db_count(&db, "update_log"), 3);
    assert_eq!(db_status(&db, "A"), "update_available");
    assert_eq!(db_status(&db, "B"), "update_available");
    assert_eq!(db_status(&db, "C"), "inventory_missing");

    let results_raw = pref(&db, "update_results_v1").expect("results pref");
    let results: Value = serde_json::from_str(&results_raw).unwrap();
    let first = results[0].as_object().unwrap();
    for key in [
        "channelId",
        "appId",
        "appName",
        "iconUrl",
        "packageName",
        "installedVersion",
        "latestVersion",
        "checkedAt",
        "download",
    ] {
        assert!(first.contains_key(key), "missing cache key {key}");
    }
    assert!(!first.contains_key("detail"), "detail must not be cached");
    let cached_download = first["download"].as_object().unwrap();
    for key in [
        "url",
        "name",
        "size",
        "downloadCount",
        "version",
        "versionCode",
        "publishedAt",
        "platform",
        "hash",
        "hashType",
    ] {
        assert!(
            cached_download.contains_key(key),
            "missing download key {key}"
        );
    }
    assert_eq!(first["download"]["downloadCount"], 7);
    assert_eq!(
        pref(&db, "update_last_checked_at").as_deref(),
        Some("1000000")
    );
    let logs_raw = pref(&db, "update_check_logs_v1").expect("logs pref");
    let logs: Value = serde_json::from_str(&logs_raw).unwrap();
    let levels: Vec<&str> = logs
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["level"].as_str().unwrap())
        .collect();
    for level in &levels {
        assert!(
            ["info", "installed", "update", "none", "skip", "error"].contains(level),
            "unexpected log level {level}"
        );
    }
    assert!(levels.contains(&"update"));

    write_evidence(&json!({
        "report": {
            "checkedAt": report.checked_at,
            "total": report.total,
            "usedCache": report.used_cache,
            "updates": report.updates,
            "skipped": report.skipped,
            "events": report.events,
        },
        "cacheResults": results,
        "cacheLogs": logs,
        "updateState": state_rows(&db),
        "updateLog": log_rows(&db),
        "updatePrefs": pref_rows(&db),
    }));
    write_db_snapshot(&db);

    let cached = service.check_all(false).expect("cached check");
    assert!(cached.used_cache);
    assert_eq!(cached.checked_at, 1_000_000);
    assert_eq!(cached.updates.len(), 2);
    assert!(cached.events.is_empty());
    assert_eq!(db_count(&db, "update_log"), 3, "cache hit persists nothing");

    let forced = service.check_all(true).expect("forced check");
    assert!(!forced.used_cache);
    assert_eq!(forced.checked_at, 1_000_000);
    assert_eq!(db_count(&db, "update_log"), 6);
}

#[test]
fn update_version_compare() {
    let cases = [
        ("1.0", "1.0.1", CmpOrdering::Less),
        ("1.0.1", "1.0", CmpOrdering::Greater),
        ("v2", "1.9", CmpOrdering::Greater),
        ("1.9", "v2", CmpOrdering::Less),
        ("0-beta04", "0-beta5", CmpOrdering::Less),
        ("1.0.0-alpha", "1.0.0", CmpOrdering::Equal),
        ("1.0", "1.0.0.0", CmpOrdering::Equal),
        ("1.2.3", "1.2.3", CmpOrdering::Equal),
        (
            "999999999999999999999",
            "999999999999999999998",
            CmpOrdering::Greater,
        ),
        (
            "999999999999999999999",
            "999999999999999999999",
            CmpOrdering::Equal,
        ),
        ("no-digits", "another", CmpOrdering::Equal),
        ("", "", CmpOrdering::Equal),
        ("abc", "0", CmpOrdering::Equal),
        ("0001.002", "1.2", CmpOrdering::Equal),
        ("版本2", "版本1", CmpOrdering::Greater),
    ];
    for (left, right, expected) in cases {
        assert_eq!(
            compare_versions(left, right),
            expected,
            "compare {left} vs {right}"
        );
    }
}

#[test]
fn update_abi_selection() {
    assert_eq!(normalize_abi("arm64-v8a"), "arm64-v8a");
    assert_eq!(normalize_abi("ARM64-V8A"), "arm64-v8a");
    assert_eq!(normalize_abi("armeabi-v7a"), "armeabi-v7a");
    assert_eq!(normalize_abi("x86_64"), "x86_64");
    assert_eq!(normalize_abi("x86"), "x86");
    assert_eq!(normalize_abi("riscv64"), "riscv64");

    assert!(asset_matches_abi("app-arm64-v8a.apk", "arm64-v8a"));
    assert!(!asset_matches_abi("app-armeabi-v7a.apk", "arm64-v8a"));
    assert!(asset_matches_abi("app-armeabi-v7a.apk", "armeabi-v7a"));
    assert!(asset_matches_abi("app-arm32.apk", "armeabi-v7a"));
    assert!(asset_matches_abi("app-x86_64.apk", "x86_64"));
    assert!(asset_matches_abi("app-x86.apk", "x86"));
    assert!(!asset_matches_abi("app-x86_64.apk", "x86"));
    assert!(asset_matches_abi("app-universal.apk", "arm64-v8a"));
    assert!(asset_matches_abi("app-unknown.bin", ""));
    assert!(asset_matches_abi("app-unknown.bin", "riscv64"));

    let candidates = vec![
        download("app-arm64-v8a.apk", Some("arm64-v8a")),
        download("app-universal.apk", Some("universal")),
    ];
    assert_eq!(
        select_best_download(&candidates, &["arm64-v8a".to_string()])
            .unwrap()
            .name,
        "app-arm64-v8a.apk"
    );
    assert_eq!(
        select_best_download(&candidates, &["x86_64".to_string()])
            .unwrap()
            .name,
        "app-universal.apk"
    );

    let universal_first = vec![
        download("app-universal.apk", Some("universal")),
        download("app-arm64-v8a.apk", Some("arm64-v8a")),
    ];
    assert_eq!(
        select_best_download(&universal_first, &["arm64-v8a".to_string()])
            .unwrap()
            .name,
        "app-universal.apk"
    );

    let apk_preference = vec![
        download("release-notes.txt", None),
        download("app.apk", None),
    ];
    assert_eq!(
        select_best_download(&apk_preference, &["unknown".to_string()])
            .unwrap()
            .name,
        "app.apk"
    );

    let arbitrary = vec![download("one.zip", None), download("two.zip", None)];
    assert_eq!(
        select_best_download(&arbitrary, &[]).unwrap().name,
        "one.zip"
    );
    let non_apk = vec![download("tool-x86_64.bin", None)];
    assert_eq!(
        select_best_download(&non_apk, &["arm64-v8a".to_string()])
            .unwrap()
            .name,
        "tool-x86_64.bin"
    );
    assert!(select_best_download(&[], &["arm64-v8a".to_string()]).is_none());

    let fallback = download("fallback.apk", None);
    assert_eq!(
        select_download_with_preference(&fallback, &candidates, None).name,
        "fallback.apk"
    );
    assert_eq!(
        select_download_with_preference(&fallback, &candidates, Some("app-arm64-v8a.apk")).name,
        "app-arm64-v8a.apk"
    );
}

#[test]
fn update_cache_ttl() {
    let (_dir, db, drivers) = parity_fixture();
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a"]);
    seed_inventory(&db, SOURCE, 1_000_000, &[installed("com.a", "1.0.0")]);
    let (clock, clock_fn) = clock_at(1_000_000);
    let service = make_service(&db, drivers, clock_fn);

    let first = service.check_all(false).unwrap();
    assert!(!first.used_cache);
    assert_eq!(first.checked_at, 1_000_000);

    clock.store(1_000_000 + UPDATE_CACHE_TTL_MS - 1, Ordering::SeqCst);
    let cached = service.check_all(false).unwrap();
    assert!(cached.used_cache);
    assert_eq!(cached.checked_at, 1_000_000);
    assert!(service.is_cache_valid().unwrap());

    clock.store(1_000_000 + UPDATE_CACHE_TTL_MS, Ordering::SeqCst);
    assert!(!service.is_cache_valid().unwrap());
    let refreshed = service.check_all(false).unwrap();
    assert!(!refreshed.used_cache);
    assert_eq!(refreshed.checked_at, 1_000_000 + UPDATE_CACHE_TTL_MS);

    let forced = service.check_all(true).unwrap();
    assert!(!forced.used_cache);
    assert_eq!(forced.checked_at, 1_000_000 + UPDATE_CACHE_TTL_MS);
}

#[test]
fn update_cache_timestamp_overflow_is_safe() {
    let (_dir, db, drivers) = parity_fixture();
    seed_facts(&db, SOURCE, i64::MAX, &["arm64-v8a"]);
    seed_inventory(&db, SOURCE, i64::MAX, &[installed("com.a", "1.0.0")]);
    let (clock, clock_fn) = clock_at(1_000_000);
    let service = make_service(&db, drivers, clock_fn);
    assert!(!service.check_all(true).unwrap().updates.is_empty());

    insert_pref(&db, "update_last_checked_at", &i64::MIN.to_string());
    clock.store(i64::MAX, Ordering::SeqCst);
    assert!(!service.is_cache_valid().unwrap());
    let report = service.check_all(false).unwrap();
    assert!(!report.used_cache);
    assert_eq!(report.checked_at, i64::MAX);

    clock.store(i64::MIN, Ordering::SeqCst);
    let backwards = service.check_all(false).unwrap();
    assert!(backwards.used_cache);
    assert_eq!(backwards.checked_at, i64::MAX);
    assert!(service.is_cache_valid().unwrap());

    let future = 1_000_000_500_i64;
    insert_pref(&db, "update_last_checked_at", &future.to_string());
    clock.store(1_000_000_000, Ordering::SeqCst);
    let shelf = service.check_all(false).unwrap();
    assert!(shelf.used_cache);
    assert_eq!(shelf.checked_at, future);
}

#[test]
fn update_prefs_roundtrip() {
    let (_dir, db, drivers) = parity_fixture();
    insert_pref(
        &db,
        "update_preferred_apk",
        r#"{"github:A":"app-arm64-v8a.apk"}"#,
    );
    seed_facts(&db, SOURCE, 1_234, &["arm64-v8a"]);
    seed_inventory(&db, SOURCE, 1_234, &[installed("com.a", "1.0.0")]);
    let (_, clock) = clock_at(1234);
    let service = make_service(&db, drivers, clock);

    let report = service.check_all(true).unwrap();
    assert_eq!(
        find(&report.updates, "A").download.name,
        "app-arm64-v8a.apk"
    );

    assert_eq!(pref(&db, "update_last_checked_at").as_deref(), Some("1234"));
    let results: Value = serde_json::from_str(&pref(&db, "update_results_v1").unwrap()).unwrap();
    assert_eq!(results.as_array().unwrap().len(), 1);
    let entry = results[0].as_object().unwrap();
    assert_eq!(entry["channelId"], "github");
    assert_eq!(entry["appId"], "A");
    assert_eq!(entry["appName"], "App A");
    assert_eq!(entry["packageName"], "com.a");
    assert_eq!(entry["installedVersion"], "1.0.0");
    assert_eq!(entry["latestVersion"], "2.0.0");
    assert_eq!(entry["checkedAt"], 1234);
    assert!(entry["iconUrl"].is_string());
    assert!(entry.get("detail").is_none());
    let cached_download = entry["download"].as_object().unwrap();
    assert_eq!(cached_download["downloadCount"], 7);
    assert_eq!(cached_download["versionCode"], 2);
    assert_eq!(cached_download["publishedAt"], 1_600_000_000_000_i64);
    assert_eq!(cached_download["hashType"], "sha256");

    let logs: Value = serde_json::from_str(&pref(&db, "update_check_logs_v1").unwrap()).unwrap();
    let entries = logs.as_array().unwrap();
    assert!(!entries.is_empty());
    for entry in entries {
        assert!(entry["text"].as_str().is_some_and(|text| !text.is_empty()));
        assert_eq!(entry["time"], 1234);
    }
    assert_eq!(
        pref(&db, "update_preferred_apk").as_deref(),
        Some(r#"{"github:A":"app-arm64-v8a.apk"}"#)
    );
}

#[test]
fn update_preferred_apk() {
    let candidates = vec![
        download("app-arm64-v8a.apk", Some("arm64-v8a")),
        download("app-universal.apk", Some("universal")),
    ];
    assert_eq!(
        pick_closest_apk(&candidates, "APP-ARM64-V8A.APK")
            .unwrap()
            .name,
        "app-arm64-v8a.apk"
    );
    let tie = vec![download("aaa.apk", None), download("bbb.apk", None)];
    assert_eq!(pick_closest_apk(&tie, "zzz.apk").unwrap().name, "aaa.apk");
    assert!(pick_closest_apk(&candidates, "  ").is_none());
    assert!(pick_closest_apk(&[], "app.apk").is_none());

    let fallback = download("app-universal.apk", Some("universal"));
    let candidates = vec![
        download("app-arm64-v8a.apk", Some("arm64-v8a")),
        download("chosen.apk", None),
    ];
    assert_eq!(
        select_download_with_preference(&fallback, &candidates, Some("chosen.apk")).name,
        "chosen.apk"
    );
    assert_eq!(
        select_download_with_preference(&fallback, &candidates, Some("chosen.apk")).name,
        "chosen.apk"
    );
    assert_eq!(
        select_download_with_preference(&fallback, &[], Some("missing.apk")).name,
        "app-universal.apk"
    );
    assert_eq!(
        select_download_with_preference(&fallback, &candidates, Some("")).name,
        "app-universal.apk"
    );

    let dir = TempDir::new("preferred");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "A", 1000);
    let drivers = vec![driver(
        "github",
        vec![update(
            "A",
            "com.a",
            "App A",
            Some("2.0.0"),
            None,
            vec![
                download("app-arm64-v8a.apk", Some("arm64-v8a")),
                download("chosen.apk", None),
            ],
            None,
        )],
    )];
    insert_pref(&db, "update_preferred_apk", r#"{"github:A":"chosen.apk"}"#);
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a"]);
    seed_inventory(&db, SOURCE, 1_000_000, &[installed("com.a", "1.0.0")]);
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers, clock);
    let report = service.check_all(true).unwrap();
    assert_eq!(find(&report.updates, "A").download.name, "chosen.apk");
}

fn updatable_fixture(
    tag: &str,
    installed_version: &str,
) -> (TempDir, DbHandle, Vec<Arc<dyn ChannelDriver>>) {
    let dir = TempDir::new(tag);
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "A", 1000);
    let drivers = vec![driver(
        "github",
        vec![update(
            "A",
            "com.a",
            "App A",
            Some("2.0.0"),
            None,
            vec![download("app.apk", None)],
            None,
        )],
    )];
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a"]);
    seed_inventory(
        &db,
        SOURCE,
        1_000_000,
        &[installed("com.a", installed_version)],
    );
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers.clone(), clock);
    service.check_all(true).unwrap();
    (dir, db, drivers)
}

#[test]
fn update_mark_updated() {
    let (_dir, db, drivers) = updatable_fixture("mark_removed", "1.0.0");
    set_inventory_version(&db, "com.a", "2.0.0");
    let (_, clock) = clock_at(1_100_000);
    let service = make_service(&db, drivers, clock);
    assert!(service.mark_updated("A").unwrap());
    assert!(service.list().unwrap().is_empty());
    assert!(!service.has_update("A").unwrap());
    assert_eq!(db_status(&db, "A"), "updated");

    let (_dir, db, drivers) = updatable_fixture("mark_kept", "1.0.0");
    set_inventory_version(&db, "com.a", "1.5.0");
    let (_, clock) = clock_at(1_100_000);
    let service = make_service(&db, drivers, clock);
    assert!(!service.mark_updated("A").unwrap());
    assert_eq!(service.count().unwrap(), 1);

    let (_dir, db, drivers) = updatable_fixture("mark_missing", "1.0.0");
    let (_, clock) = clock_at(1_100_000);
    let service = make_service(&db, drivers, clock);
    assert!(!service.mark_updated("missing").unwrap());
    assert_eq!(service.count().unwrap(), 1);

    // An app absent from inventory keeps its cache entry: mark_updated never
    // deletes on missing data (the update is simply still unverified).
    let (_dir, db, drivers) = updatable_fixture("mark_absent", "1.0.0");
    remove_inventory_package(&db, "com.a");
    let (_, clock) = clock_at(1_100_000);
    let service = make_service(&db, drivers, clock);
    assert!(!service.mark_updated("A").unwrap());
    assert_eq!(service.count().unwrap(), 1);
    assert_eq!(db_status(&db, "A"), "update_available");
}

#[test]
fn update_invalid_version() {
    for (left, right) in [
        ("", ""),
        ("", "abc"),
        ("abc", ""),
        ("1.0", "1.0.0.0"),
        ("0001.002", "1.2"),
        ("999999999999999999999999", "1000000000000000000000000"),
    ] {
        let first = compare_versions(left, right);
        let second = compare_versions(left, right);
        assert_eq!(first, second, "comparison must be deterministic");
    }
    assert_eq!(
        compare_versions("999999999999999999999", "1"),
        CmpOrdering::Greater
    );
    assert_eq!(
        compare_versions("1", "999999999999999999999"),
        CmpOrdering::Less
    );
    assert_eq!(compare_versions("", "0"), CmpOrdering::Equal);
    assert_eq!(compare_versions("0", ""), CmpOrdering::Equal);
    assert_eq!(compare_versions("1..2", "1.2"), CmpOrdering::Equal);
}

#[test]
fn update_check_app_cache() {
    let (_dir, db, drivers) = parity_fixture();
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a"]);
    seed_inventory(
        &db,
        SOURCE,
        1_000_000,
        &[
            installed("com.a", "1.0.0"),
            installed("com.b", "1.0.0"),
            installed("com.d", "1.0.0"),
        ],
    );
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers.clone(), clock);
    let report = service.check_all(true).unwrap();
    assert_eq!(report.updates.len(), 2);

    let log_rows_before = db_count(&db, "update_log");
    let cached = service.check_app("A", None).unwrap().unwrap();
    assert_eq!(cached.latest_version, "2.0.0");
    assert_eq!(db_count(&db, "update_log"), log_rows_before);
    assert!(service.check_app("missing", None).unwrap().is_none());
    assert!(service
        .check_app("missing", Some("unknown"))
        .unwrap()
        .is_none());

    let more_drivers = {
        let mut all = drivers;
        all.push(driver(
            "github",
            vec![update(
                "D",
                "com.d",
                "App D",
                Some("3.0.0"),
                None,
                vec![download("d.apk", None)],
                None,
            )],
        ));
        all
    };
    let before_checked = pref(&db, "update_last_checked_at");
    let before_states = db_count(&db, "update_state");
    let service = make_service(&db, more_drivers, Arc::new(|| 1_000_000_i64));
    let single = service.check_app("D", Some("github")).unwrap().unwrap();
    assert_eq!(single.latest_version, "3.0.0");
    assert_eq!(service.count().unwrap(), 2);
    assert_eq!(pref(&db, "update_last_checked_at"), before_checked);
    assert_eq!(db_count(&db, "update_state"), before_states);
}

#[test]
fn update_skip_reasons() {
    let dir = TempDir::new("skips");
    let db = DbHandle::open(dir.path()).unwrap();
    add_added(&db, "github", "A", 7000);
    add_added(&db, "fdroid", "B", 6000);
    add_added(&db, "local_db", "C", 5000);
    add_added(&db, "vivo", "D", 4000);
    add_added(&db, "github", "E", 3000);
    add_added(&db, "fdroid", "F", 2000);
    add_added(&db, "ghost", "G", 1000);

    let drivers = vec![
        // No update payload for A: the driver reports NotFound.
        driver(
            "github",
            vec![update(
                "E",
                "com.e",
                "App E",
                Some("2.0.0"),
                None,
                Vec::new(),
                None,
            )],
        ),
        driver(
            "fdroid",
            vec![
                update(
                    "B",
                    "com.b",
                    "App B",
                    Some("2.0.0"),
                    None,
                    vec![download("b.apk", None)],
                    None,
                ),
                update(
                    "F",
                    "com.f",
                    "App F",
                    Some("1.0.0"),
                    None,
                    vec![download("f.apk", None)],
                    None,
                ),
            ],
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
                None,
            )],
        ),
        driver(
            "vivo",
            vec![update(
                "D",
                "com.d",
                "App D",
                None,
                None,
                vec![download("d.apk", None)],
                None,
            )],
        ),
    ];
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a"]);
    seed_inventory(
        &db,
        SOURCE,
        1_000_000,
        &[
            installed("com.c", ""),
            installed("com.d", "1.0.0"),
            installed("com.e", "1.0.0"),
            installed("com.f", "1.0.0"),
        ],
    );
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers.clone(), clock);
    let report = service.check_all(true).unwrap();

    assert_eq!(report.total, 7);
    assert!(report.updates.is_empty());
    assert_eq!(skip_reason(&report.skipped, "A"), "channel_error");
    assert_eq!(skip_reason(&report.skipped, "B"), "inventory_missing");
    assert_eq!(skip_reason(&report.skipped, "C"), "no_installed_version");
    assert_eq!(skip_reason(&report.skipped, "D"), "no_channel_version");
    assert_eq!(skip_reason(&report.skipped, "E"), "no_download");
    assert_eq!(skip_reason(&report.skipped, "F"), "up_to_date");
    assert_eq!(skip_reason(&report.skipped, "G"), "unknown_channel");
    assert_eq!(db_count(&db, "update_state"), 6);
    assert_eq!(db_count(&db, "update_log"), 6);
    assert!(report.events.is_empty());

    // A stale source with `force = true` does not abort the batch; every app
    // that needs inventory is skipped instead.
    db.writer()
        .unwrap()
        .execute(
            "UPDATE inventory_source SET captured_at = ?1 WHERE source_id = ?2",
            params![1_000_000 - 86_400_000 - 1, SOURCE],
        )
        .unwrap();
    let service = make_service(&db, drivers, Arc::new(|| 1_000_000_i64));
    let stale = service.check_all(true).unwrap();
    assert!(stale.updates.is_empty());
    assert_eq!(skip_reason(&stale.skipped, "E"), "inventory_stale");
    assert_eq!(skip_reason(&stale.skipped, "F"), "inventory_stale");
}

#[test]
fn update_variant_uses_fact_abis() {
    let (_dir, db, drivers) = parity_fixture();
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a", "armeabi-v7a"]);
    seed_inventory(&db, SOURCE, 1_000_000, &[installed("com.a", "1.0.0")]);
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers, clock);
    let report = service.check_all(true).unwrap();
    assert_eq!(
        find(&report.updates, "A").download.name,
        "app-arm64-v8a.apk"
    );
}

#[test]
fn update_check_log_levels_serialize() {
    let levels = [
        (CheckLogLevel::Info, "info"),
        (CheckLogLevel::Installed, "installed"),
        (CheckLogLevel::Update, "update"),
        (CheckLogLevel::None, "none"),
        (CheckLogLevel::Skip, "skip"),
        (CheckLogLevel::Error, "error"),
    ];
    for (level, wire) in levels {
        assert_eq!(serde_json::to_value(level).unwrap(), wire);
    }
}

#[test]
fn update_uses_inventory_store() {
    let (_dir, db, drivers) = parity_fixture();
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a", "armeabi-v7a"]);
    seed_inventory(&db, SOURCE, 1_000_000, &[installed("com.a", "1.0.0")]);
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers, clock);

    let report = service.check_all(true).unwrap();
    let update = find(&report.updates, "A");
    assert_eq!(
        update.installed_version, "1.0.0",
        "installed version must come from installed_app"
    );
    assert_eq!(
        update.download.name, "app-arm64-v8a.apk",
        "variant must come from platform_facts.abis"
    );

    set_inventory_version(&db, "com.a", "2.0.0");
    let refreshed = service.check_all(true).unwrap();
    assert!(
        refreshed.updates.iter().all(|info| info.app_id != "A"),
        "a changed inventory row must change the decision"
    );
    assert_eq!(skip_reason(&refreshed.skipped, "A"), "up_to_date");
}

#[test]
fn update_missing_facts_typed() {
    let (_dir, db, drivers) = parity_fixture();
    seed_inventory(&db, SOURCE, 1_000_000, &[installed("com.a", "1.0.0")]);
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers, clock);

    match service.check_all(true) {
        Err(Error::Unsupported(message)) => {
            assert!(message.contains("CORE_E_FACTS_MISSING"), "{message}");
        }
        other => panic!("expected Unsupported, got {other:?}"),
    }
    match service.run() {
        Err(Error::Unsupported(message)) => {
            assert!(message.contains("CORE_E_FACTS_MISSING"), "{message}");
        }
        other => panic!("expected Unsupported, got {other:?}"),
    }
}

#[test]
fn update_stale_inventory_aborts_per_batch() {
    let (_dir, db, drivers) = parity_fixture();
    seed_facts(&db, SOURCE, 1_000_000, &["arm64-v8a"]);
    seed_inventory(
        &db,
        SOURCE,
        1_000_000 - 86_400_000 - 1,
        &[installed("com.a", "1.0.0")],
    );
    let (_, clock) = clock_at(1_000_000);
    let service = make_service(&db, drivers, clock);

    match service.check_all(false) {
        Err(Error::Unsupported(message)) => {
            assert!(message.contains("CORE_E_INVENTORY_STALE"), "{message}");
        }
        other => panic!("expected Unsupported, got {other:?}"),
    }

    let forced = service.check_all(true).unwrap();
    assert!(
        forced.updates.is_empty(),
        "stale inventory yields no update"
    );
    assert_eq!(skip_reason(&forced.skipped, "A"), "inventory_stale");
}
