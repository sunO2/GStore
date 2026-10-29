//! Real update parity against a committed golden.
//!
//! The golden (`tests/fixtures/update_parity_golden.json`) is **real Rust
//! output**: `UpdateService::check_all(true)` over the committed SQLite input
//! fixture (`tests/fixtures/update_parity_input.db`), driven by the
//! handcrafted channel payloads in `tests/fixtures/update_parity_input.json`
//! (labelled INPUT ONLY — never a core expectation).
//!
//! Regenerate the fixture DB + golden after changing the input:
//!
//! ```text
//! GSTORE_WRITE_UPDATE_GOLDEN=1 \
//!   cargo test --manifest-path rust/gstore_core/Cargo.toml \
//!     --test update_parity_golden
//! ```
//!
//! This test then:
//! 1. verifies the committed input DB + input JSON still hash to the values
//!    recorded in the golden (a stale-fixture guard);
//! 2. copies the committed DB to a scratch dir (so the fixture stays
//!    byte-identical) and runs the real production `UpdateService`;
//! 3. compares candidates, installed/latest versions, the four prefs keys, and
//!    the check logs against the golden.
//!
//! `GSTORE_UPDATE_PARITY_GOLDEN` points at an alternate golden (used to prove a
//! mutated /tmp copy really fails; the committed golden is never modified in
//! that mode).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::channel::{ChannelDriver, InMemoryChannelDriver};
use gstore_core::db::DbHandle;
use gstore_core::dto::{
    AppDetail, AppDownload, AppUpdate, ChannelKey, ChannelKind, ChannelMeta, DetailSection,
};
use gstore_core::facts::{CorePaths, DeviceFacts, InstalledApp, PlatformFacts};
use gstore_core::migration::update_pref;
use gstore_core::update::service::{ChannelResolver, UpdateCheckReport, UpdateService};
use rusqlite::params;
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_update_golden_{tag}_{}_{}",
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

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn golden_path() -> PathBuf {
    std::env::var_os("GSTORE_UPDATE_PARITY_GOLDEN")
        .map(PathBuf::from)
        .unwrap_or_else(|| fixtures_dir().join("update_parity_golden.json"))
}

fn sha256_hex(path: &Path) -> String {
    let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

// ---- INPUT shapes (the handcrafted literals; never an expectation) --------

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input {
    checked_at: i64,
    source_id: String,
    abis: Vec<String>,
    added: Vec<InputAdded>,
    installed: Vec<InputInstalled>,
    preferred_apk: BTreeMap<String, String>,
    channels: Vec<InputChannel>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputAdded {
    channel_id: String,
    app_id: String,
    add_time: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputInstalled {
    package_name: String,
    version_name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputChannel {
    code: String,
    updates: Vec<InputUpdate>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputUpdate {
    app_id: String,
    app_name: String,
    package_name: String,
    icon_url: Option<String>,
    latest_version: String,
    download: InputDownload,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputDownload {
    url: String,
    name: String,
    size: Option<i64>,
    download_count: Option<i64>,
    version: Option<String>,
    version_code: Option<i64>,
    published_at: Option<i64>,
    platform: Option<String>,
    hash: Option<String>,
    hash_type: Option<String>,
}

fn app_download(download: &InputDownload) -> AppDownload {
    AppDownload {
        url: download.url.clone(),
        name: download.name.clone(),
        size: download.size,
        download_count: download.download_count,
        version: download.version.clone(),
        version_code: download.version_code,
        published_at: download.published_at,
        platform: download.platform.clone(),
        hash: download.hash.clone(),
        hash_type: download.hash_type.clone(),
        downloadable: true,
        note: None,
        extra: None,
    }
}

fn app_update(update: &InputUpdate) -> AppUpdate {
    let download = app_download(&update.download);
    AppUpdate {
        app_id: update.app_id.clone(),
        package_name: update.package_name.clone(),
        name: update.app_name.clone(),
        icon: update.icon_url.clone(),
        latest_version: Some(update.latest_version.clone()),
        latest_download: Some(download.clone()),
        detail: AppDetail {
            app_id: update.app_id.clone(),
            name: update.app_name.clone(),
            icon: update.icon_url.clone().unwrap_or_default(),
            description: String::new(),
            version: Some(update.latest_version.clone()),
            developer: None,
            package_name: Some(update.package_name.clone()),
            project_url: None,
            channel: ChannelKind::Custom,
            sections: vec![DetailSection::Version, DetailSection::Downloads],
            downloads: vec![download],
            extra: Map::new(),
            labels: Vec::new(),
        },
    }
}

// ---- Seeding the committed SQLite input fixture ---------------------------

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
    let map: BTreeMap<String, Arc<dyn ChannelDriver>> = drivers
        .into_iter()
        .map(|driver| (driver.key().as_str().to_string(), driver))
        .collect();
    Arc::new(move |code: &str| map.get(code).cloned())
}

fn platform_facts(input: &Input) -> PlatformFacts {
    PlatformFacts {
        source_id: input.source_id.clone(),
        os: "android".to_string(),
        arch: "aarch64".to_string(),
        abis: input.abis.clone(),
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
        captured_at: input.checked_at,
    }
}

fn seed_facts(db: &DbHandle, input: &Input) {
    let encoded = serde_json::to_string(&platform_facts(input)).unwrap();
    db.writer()
        .unwrap()
        .execute(
            "INSERT INTO platform_facts(id, json, source_id, captured_at) VALUES (1, ?1, ?2, ?3) \
             ON CONFLICT(id) DO UPDATE SET json=excluded.json, source_id=excluded.source_id, \
                 captured_at=excluded.captured_at",
            params![encoded, input.source_id, input.checked_at],
        )
        .unwrap();
}

fn installed_apps(input: &Input) -> Vec<InstalledApp> {
    input
        .installed
        .iter()
        .map(|app| InstalledApp {
            package_name: app.package_name.clone(),
            app_name: Some(app.package_name.clone()),
            version_name: app.version_name.clone(),
            version_code: 1,
            signature_sha256: None,
            source_dir: None,
            installer: None,
            is_system: false,
            target_sdk: 35,
            min_sdk: 21,
            abis: input.abis.clone(),
        })
        .collect()
}

fn seed_inventory(db: &DbHandle, input: &Input) {
    let conn = db.writer().unwrap();
    conn.execute(
        "INSERT INTO inventory_source(source_id, seq, captured_at) VALUES (?1, 1, ?2) \
         ON CONFLICT(source_id) DO UPDATE SET seq=excluded.seq, captured_at=excluded.captured_at",
        params![input.source_id, input.checked_at],
    )
    .unwrap();
    for app in installed_apps(input) {
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
                input.source_id,
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
                input.checked_at,
            ],
        )
        .unwrap();
    }
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

/// Seeds a scratch DB through the production migrations, then writes a clean
/// single-file copy to `path` (`VACUUM INTO`, no `-wal`/`-shm` siblings).
fn build_input_db(path: &Path, input: &Input) {
    let dir = TempDir::new("seed");
    let db = DbHandle::open(dir.path()).unwrap();
    for added in &input.added {
        add_added(&db, &added.channel_id, &added.app_id, added.add_time);
    }
    seed_facts(&db, input);
    seed_inventory(&db, input);
    insert_pref(
        &db,
        "update_preferred_apk",
        &serde_json::to_string(&input.preferred_apk).unwrap(),
    );

    let _ = std::fs::remove_file(path);
    db.with_writer(|conn| {
        conn.execute("VACUUM INTO ?1", [path.to_string_lossy().into_owned()])
            .map(|_| ())
            .map_err(|error| gstore_core::db::DbError(error.to_string()))
    })
    .unwrap();
}

fn run_service(db_path: &Path, input: &Input) -> (DbHandle, UpdateCheckReport) {
    let db = DbHandle::open_at(db_path).unwrap();
    let drivers: Vec<Arc<dyn ChannelDriver>> = input
        .channels
        .iter()
        .map(|channel| {
            driver(
                &channel.code,
                channel.updates.iter().map(app_update).collect::<Vec<_>>(),
            )
        })
        .collect();
    let at = input.checked_at;
    let clock: Arc<dyn Fn() -> i64 + Send + Sync> = Arc::new(move || at);
    let service = UpdateService::with_clock(db.clone(), resolver(drivers), clock);
    let report = service.check_all(true).expect("real update check");
    (db, report)
}

fn pref(db: &DbHandle, key: &str) -> Option<String> {
    let conn = db.reader().unwrap();
    update_pref(&conn, key).unwrap()
}

fn required_pref(db: &DbHandle, key: &str) -> Value {
    let raw = pref(db, key).unwrap_or_else(|| panic!("missing pref {key}"));
    serde_json::from_str(&raw).unwrap_or_else(|error| panic!("pref {key} is not JSON: {error}"))
}

/// The canonical snapshot both the Dart legacy lane and the golden compare.
fn canonical(db: &DbHandle) -> Value {
    let results = required_pref(db, "update_results_v1");
    let logs = required_pref(db, "update_check_logs_v1");
    let last_checked: i64 = pref(db, "update_last_checked_at")
        .expect("missing update_last_checked_at")
        .parse()
        .expect("update_last_checked_at is not an integer");
    let preferred = pref(db, "update_preferred_apk")
        .map(|raw| serde_json::from_str(&raw).expect("preferred APK pref is not JSON"))
        .unwrap_or(Value::Null);

    let mut installed = Map::new();
    let mut latest = Map::new();
    for item in results.as_array().expect("results array") {
        let app_id = item["appId"].as_str().expect("appId").to_string();
        installed.insert(app_id.clone(), item["installedVersion"].clone());
        latest.insert(app_id, item["latestVersion"].clone());
    }

    json!({
        "candidates": results,
        "installedVersions": installed,
        "latestVersions": latest,
        "update_last_checked_at": last_checked,
        "update_results_v1": results,
        "update_check_logs_v1": logs,
        "update_preferred_apk": preferred,
    })
}

fn report_json(report: &UpdateCheckReport) -> Value {
    json!({
        "checkedAt": report.checked_at,
        "total": report.total,
        "usedCache": report.used_cache,
        "updates": report.updates,
        "skipped": report.skipped,
    })
}

#[test]
fn update_parity_matches_real_core_golden() {
    let input_path = fixtures_dir().join("update_parity_input.json");
    let input: Input = serde_json::from_str(
        &std::fs::read_to_string(&input_path).expect("read update_parity_input.json"),
    )
    .expect("parse update_parity_input.json");
    let input_sha = sha256_hex(&input_path);

    let db_path = fixtures_dir().join("update_parity_input.db");
    let write_mode = std::env::var("GSTORE_WRITE_UPDATE_GOLDEN").ok().as_deref() == Some("1");
    if write_mode {
        build_input_db(&db_path, &input);
    }
    let db_sha = sha256_hex(&db_path);

    // Work on a copy so the committed fixture stays byte-identical.
    let dir = TempDir::new("run");
    let copy = dir.join("update_parity_input.db");
    std::fs::copy(&db_path, &copy).unwrap();
    let (db, report) = run_service(&copy, &input);

    let actual = canonical(&db);
    let actual_report = report_json(&report);

    if write_mode {
        let golden = json!({
            "provenance": "REAL gstore_core::update::service::UpdateService::check_all(true) output over tests/fixtures/update_parity_input.db; generated by cargo test --test update_parity_golden with GSTORE_WRITE_UPDATE_GOLDEN=1",
            "input": {
                "db": {
                    "sha256": db_sha,
                    "bytes": std::fs::metadata(&db_path).unwrap().len(),
                },
                "channel_input": {
                    "sha256": input_sha,
                    "bytes": std::fs::metadata(&input_path).unwrap().len(),
                },
            },
            "canonical": actual,
            "report": actual_report,
        });
        let encoded = serde_json::to_string_pretty(&golden).unwrap();
        std::fs::write(golden_path(), format!("{encoded}\n")).unwrap();
        return;
    }

    let golden: Value = serde_json::from_str(
        &std::fs::read_to_string(golden_path()).expect("read update_parity_golden.json"),
    )
    .expect("parse update_parity_golden.json");

    // ---- 1. Same input bytes the golden was produced from ---------------
    assert_eq!(
        db_sha,
        golden["input"]["db"]["sha256"]
            .as_str()
            .expect("input db sha256"),
        "stale-state: committed update_parity_input.db changed without regenerating the golden"
    );
    assert_eq!(
        input_sha,
        golden["input"]["channel_input"]["sha256"]
            .as_str()
            .expect("input channel sha256"),
        "stale-state: update_parity_input.json changed without regenerating the golden"
    );

    // ---- 2. Non-empty guards: an empty-vs-empty compare must not pass ----
    let candidates = actual["candidates"].as_array().expect("candidates array");
    assert_eq!(candidates.len(), 2, "fixture must produce two candidates");
    assert_eq!(
        actual["installedVersions"]
            .as_object()
            .expect("installed versions")
            .len(),
        2
    );
    assert_eq!(
        actual["latestVersions"]
            .as_object()
            .expect("latest versions")
            .len(),
        2
    );
    let logs = actual["update_check_logs_v1"]
        .as_array()
        .expect("check logs array");
    assert!(logs.len() >= 4, "check logs must be non-empty and real");
    for key in [
        "update_last_checked_at",
        "update_results_v1",
        "update_check_logs_v1",
        "update_preferred_apk",
    ] {
        assert!(
            !actual[key].is_null(),
            "four-prefs contract: {key} must be written"
        );
    }

    // ---- 3. Row-for-row comparison against real Rust output -------------
    assert_eq!(
        actual, golden["canonical"],
        "real core update output diverged from the committed golden"
    );
    assert_eq!(
        actual_report, golden["report"],
        "real core update report diverged from the committed golden"
    );
}
