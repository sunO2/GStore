//! Manual-QA scratch test for the real FRB host surface.
//!
//! It exercises `InstallApi::init` / `CoreApi::init` exactly as Dart would
//! (directory arguments, real on-disk core database, wall clock) instead of the
//! injected-clock in-memory harness in `install_request_flow.rs`. The evidence
//! run pairs it with `sqlite3` inspection of the temp database.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use gstore_core::db::DbHandle;
use gstore_host::bridge::{
    CoreApi, CorePathsDto, DeviceFactsDto, InstallApi, InstallReportDto, InstalledAppDto,
    InventorySnapshotDto, PlatformFactsDto,
};
use serde_json::Value;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_host_surface_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp dir");
        Self(path)
    }

    fn data(&self) -> String {
        self.0.join("data").to_string_lossy().into_owned()
    }

    fn files(&self) -> String {
        self.0.join("files").to_string_lossy().into_owned()
    }

    fn cache(&self) -> String {
        self.0.join("cache").to_string_lossy().into_owned()
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

fn event_kind(json: &str) -> String {
    let value: Value = serde_json::from_str(json).expect("event JSON");
    value
        .get("event")
        .and_then(Value::as_str)
        .expect("event field")
        .to_string()
}

#[test]
fn host_surface_end_to_end() {
    let root = TempDir::new("install");
    let data = root.data();
    let apk = root.path().join("app-arm64-v8a.apk");
    std::fs::write(&apk, b"PK\x03\x04fake apk").expect("write apk");

    {
        let db = DbHandle::open(Path::new(&data)).expect("open core db");
        db.with_writer(|conn| {
            conn.execute(
                "INSERT INTO download_task(\
                     module_task_id, app_id, version, url, file_name, dest_path, status, \
                     install_after_download, created_at, updated_at\
                 ) VALUES ('task-e2e', 'com.example.e2e', '3.1.4', \
                           'https://example.test/app-arm64-v8a.apk', 'app-arm64-v8a.apk', \
                           ?1, 'completed', 1, 1, 1)",
                [apk.to_string_lossy()],
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
            Ok(())
        })
        .expect("seed download_task");
    }

    let api = InstallApi::init(data.clone(), root.files(), root.cache()).expect("InstallApi::init");
    let start = api.install("task-e2e".to_string()).expect("install");
    println!("host surface install start: {start:?}");
    assert_eq!(start.record.status, "pending");
    let request = start.request.expect("request for a completed download");
    assert_eq!(request.variant.abi, "arm64-v8a");

    let db_path = Path::new(&data).join("gstore_core.db");
    let conn = rusqlite::Connection::open(&db_path).expect("inspect core db");
    let columns: (Option<String>, Option<String>, Option<String>, Option<String>, Option<i64>) =
        conn.query_row(
            "SELECT package_name, abi, variant_url, fallback_json, install_requested_at \
             FROM download_task WHERE module_task_id = 'task-e2e'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .expect("install columns");
    println!("host surface five V4 columns: {columns:?}");
    assert!(columns.0.is_some() && columns.1.is_some() && columns.2.is_some());
    assert!(columns.3.is_some() && columns.4.is_some());
    drop(conn);

    let ack = api
        .report_result(InstallReportDto {
            session_id: request.session_id.clone(),
            status: "installed".to_string(),
            method: "shizuku".to_string(),
            installed_version: Some("3.1.4".to_string()),
            error: None,
            reported_at: 1,
        })
        .expect("report installed");
    println!("host surface first ack: {ack:?}");
    assert!(ack.changed);

    let duplicate = api
        .report_result(InstallReportDto {
            session_id: request.session_id.clone(),
            status: "installed".to_string(),
            method: "shizuku".to_string(),
            installed_version: Some("3.1.4".to_string()),
            error: None,
            reported_at: 2,
        })
        .expect("duplicate report");
    println!("host surface duplicate ack: {duplicate:?}");
    assert!(!duplicate.changed);

    assert!(api.pending_requests().expect("pending").is_empty());
    let events = api.take_events().expect("take events");
    println!("host surface install events: {events:?}");
    assert_eq!(events.len(), 1);
    assert_eq!(event_kind(&events[0]), "install.requested");

    if std::env::var_os("GSTORE_QA_KEEP").is_some() {
        println!("QA_DB_PATH={}", db_path.display());
        std::mem::forget(root);
    }
}

#[test]
fn host_surface_core_api_facts_inventory_rules() {
    let root = TempDir::new("core");
    let api = CoreApi::init(root.data(), root.files(), root.cache()).expect("CoreApi::init");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0);

    api.push_platform_facts(PlatformFactsDto {
        source_id: "android".to_string(),
        os: "android".to_string(),
        arch: "aarch64".to_string(),
        abis: vec!["arm64-v8a".to_string()],
        sdk: 35,
        device: DeviceFactsDto {
            model: "Pixel".to_string(),
            manufacturer: "Google".to_string(),
        },
        paths: CorePathsDto {
            data: root.data(),
            files: root.files(),
            cache: root.cache(),
        },
        crypto_key: None,
        captured_at: now,
    })
    .expect("push facts");

    let snapshot = InventorySnapshotDto {
        source_id: "android".to_string(),
        seq: 7,
        captured_at: now,
        apps: vec![InstalledAppDto {
            package_name: "com.example.e2e".to_string(),
            app_name: Some("E2E".to_string()),
            version_name: "1.0.0".to_string(),
            version_code: 1,
            signature_sha256: None,
            source_dir: None,
            installer: None,
            is_system: false,
            target_sdk: 35,
            min_sdk: 24,
            abis: vec!["arm64-v8a".to_string()],
        }],
    };
    let pushed = api.push_inventory(snapshot).expect("push inventory");
    println!("host surface push result: {pushed:?}");
    assert!(pushed.accepted);

    let duplicate = api
        .push_inventory(InventorySnapshotDto {
            source_id: "android".to_string(),
            seq: 7,
            captured_at: now,
            apps: Vec::new(),
        })
        .expect("duplicate push");
    assert!(!duplicate.accepted);
    assert_eq!(duplicate.reason.as_deref(), Some("unchanged"));

    let status = api.inventory_status().expect("inventory status");
    println!("host surface inventory status: {status:?}");
    assert_eq!(status.source_id, "android");
    assert_eq!(status.seq, Some(7));
    assert_eq!(status.count, 1);
    assert!(!status.stale);

    let events = api.take_events().expect("inventory events");
    println!("host surface inventory events: {events:?}");
    assert!(events.iter().any(|json| event_kind(json) == "inventory.changed"));

    let install_rules = api.get_install_rules().expect("get install rules");
    assert_eq!(install_rules.version, 1);
    assert!(install_rules.install_enabled);
    let mut changed = install_rules;
    changed.timeout_secs = 60;
    api.set_install_rules(changed).expect("set install rules");
    assert_eq!(
        api.get_install_rules()
            .expect("get install rules again")
            .timeout_secs,
        60
    );

    let mut update_rules = api.get_update_rules().expect("get update rules");
    update_rules.max_inventory_age_secs = 60;
    api.set_update_rules(update_rules).expect("set update rules");
    assert_eq!(
        api.get_update_rules()
            .expect("get update rules again")
            .max_inventory_age_secs,
        60
    );
}

#[test]
fn init_sweeps_pending_rows_to_unknown() {
    let root = TempDir::new("init_sweep");
    let data = root.data();
    {
        let db = DbHandle::open(Path::new(&data)).expect("open core db");
        db.with_writer(|conn| {
            conn.execute(
                "INSERT INTO download_task(\
                     module_task_id, app_id, dest_path, status, install_status, \
                     install_session_id, install_requested_at, created_at, updated_at\
                 ) VALUES ('task-old', 'com.example.old', '/tmp/old.apk', 'completed', \
                           'pending', 'old-session', 1, 1, 1)",
                [],
            )
            .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
            Ok(())
        })
        .expect("seed pending row");
    }

    let api = InstallApi::init(data, root.files(), root.cache()).expect("InstallApi::init");
    let events = api.take_events().expect("take events");
    println!("init sweep events: {events:?}");
    assert!(events.iter().any(|json| event_kind(json) == "install.unknown"));
    assert!(api.pending_requests().expect("pending").is_empty());
}
