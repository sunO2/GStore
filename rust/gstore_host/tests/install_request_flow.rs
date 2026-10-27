//! Wave 4 Todo 3 contract: the FRB `InstallApi` request/response surface.
//!
//! The core owns install state on `download_task`; the frontend drives it
//! through `install` → `InstallStartDto.request` → `reportResult` →
//! `pendingRequests` → `takeEvents`. No installer port, JNI VM, or device is
//! required: the service is over an in-memory core database and the clock is
//! injected.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use gstore_core::db::SharedConn;
use gstore_core::install::service::InstallService;
use gstore_host::bridge::{InstallApi, InstallReportDto};
use rusqlite::Connection;
use serde_json::Value;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_install_request_flow_{tag}_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp dir");
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

fn core_conn() -> SharedConn {
    let mut conn = Connection::open_in_memory().expect("open in-memory core db");
    gstore_core::migration::apply_core_schema(&mut conn).expect("apply core schema");
    Arc::new(Mutex::new(conn))
}

#[allow(clippy::too_many_arguments)]
fn insert_task(
    conn: &SharedConn,
    module_task_id: &str,
    dest_path: &str,
    download_status: &str,
    install_status: &str,
    session_id: Option<&str>,
    install_after_download: bool,
    install_requested_at: Option<i64>,
) {
    let guard = conn.lock().expect("core db lock");
    guard
        .execute(
            "INSERT INTO download_task(\
                 module_task_id, app_id, version, url, file_name, dest_path, status, \
                 install_status, install_session_id, install_method, install_after_download, \
                 install_requested_at, created_at, updated_at\
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 1, 1)",
            rusqlite::params![
                module_task_id,
                "com.example.one",
                "1.2.3",
                "https://example.test/app-arm64-v8a.apk",
                "app-arm64-v8a.apk",
                dest_path,
                download_status,
                install_status,
                session_id,
                "platform",
                i64::from(install_after_download),
                install_requested_at,
            ],
        )
        .expect("insert download_task");
}

fn write_apk(dir: &TempDir, name: &str) -> String {
    let apk = dir.path().join(name);
    std::fs::write(&apk, b"PK\x03\x04fake apk").expect("write apk");
    apk.to_string_lossy().into_owned()
}

fn api_with_clock(conn: SharedConn, now: i64) -> InstallApi {
    let service = InstallService::with_clock(conn, Arc::new(move || now));
    InstallApi::from_service_for_test(service)
}

fn event_kind(json: &str) -> String {
    let value: Value = serde_json::from_str(json).expect("event JSON");
    value
        .get("event")
        .and_then(Value::as_str)
        .expect("event field")
        .to_string()
}

fn report(session_id: &str, status: &str) -> InstallReportDto {
    InstallReportDto {
        session_id: session_id.to_string(),
        status: status.to_string(),
        method: "shizuku".to_string(),
        installed_version: Some("1.2.3".to_string()),
        error: None,
        reported_at: 10_500,
    }
}

#[test]
fn install_request_flow() {
    let dir = TempDir::new("happy");
    let dest = write_apk(&dir, "app-arm64-v8a.apk");
    let conn = core_conn();
    insert_task(&conn, "task-1", &dest, "completed", "none", None, true, None);
    let api = api_with_clock(conn.clone(), 10_000);

    let start = api.install("task-1".to_string()).expect("install");
    println!("install start: {start:?}");
    assert_eq!(start.record.status, "pending");
    assert!(
        start.request.is_some(),
        "a pending install must return a request"
    );
    let request = start.request.as_ref().expect("request");
    assert_eq!(request.module_task_id, "task-1");
    assert_eq!(request.package_name, "com.example.one");
    assert_eq!(request.version_name, "1.2.3");
    assert_eq!(request.apk_path, dest);
    assert_eq!(request.method, "platform");
    assert_eq!(request.variant.abi, "arm64-v8a");
    assert_eq!(
        request.variant.url,
        "https://example.test/app-arm64-v8a.apk"
    );
    assert_eq!(
        request.variant.fallback_chain,
        vec!["https://example.test/app-arm64-v8a.apk".to_string()]
    );

    // The five additive V4 columns are durable before the request is returned.
    {
        let guard = conn.lock().expect("core db lock");
        let (package_name, abi, variant_url, fallback_json, requested_at): (
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
            Option<i64>,
        ) = guard
            .query_row(
                "SELECT package_name, abi, variant_url, fallback_json, install_requested_at \
                 FROM download_task WHERE module_task_id = 'task-1'",
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
        println!(
            "install columns: package={package_name:?} abi={abi:?} url={variant_url:?} \
             fallback={fallback_json:?} requested_at={requested_at:?}"
        );
        assert_eq!(package_name.as_deref(), Some("com.example.one"));
        assert_eq!(abi.as_deref(), Some("arm64-v8a"));
        assert_eq!(
            variant_url.as_deref(),
            Some("https://example.test/app-arm64-v8a.apk")
        );
        assert!(fallback_json.is_some(), "fallback_json must be persisted");
        assert_eq!(requested_at, Some(10_000));
    }

    let events = api.take_events().expect("take events");
    println!("install events: {events:?}");
    assert_eq!(events.len(), 1);
    assert_eq!(event_kind(&events[0]), "install.requested");

    let session = request.session_id.clone();
    let ack = api
        .report_result(report(&session, "installed"))
        .expect("report installed");
    println!("install ack: {ack:?}");
    assert!(ack.changed, "the first terminal report must change the row");
    assert_eq!(ack.status, "installed");

    // A duplicate terminal report is accepted idempotently but changes nothing.
    let duplicate = api
        .report_result(report(&session, "installed"))
        .expect("duplicate report");
    println!("install duplicate ack: {duplicate:?}");
    assert!(
        !duplicate.changed,
        "a duplicate terminal report must return changed: false"
    );

    assert!(
        api.pending_requests().expect("pending").is_empty(),
        "a settled install must not be pending"
    );
    let record = api
        .get("task-1".to_string())
        .expect("get")
        .expect("durable row");
    assert_eq!(record.status, "installed");
    assert_eq!(record.installed_version.as_deref(), Some("1.2.3"));
    assert_eq!(record.method.as_deref(), Some("shizuku"));

    // A settled row returns no request and starts nothing.
    let settled = api.install("task-1".to_string()).expect("settled install");
    assert_eq!(settled.record.status, "installed");
    assert!(settled.request.is_none());
}

#[test]
fn install_report_unknown_session_typed() {
    let dir = TempDir::new("unknown_session");
    let dest = write_apk(&dir, "app.apk");
    let conn = core_conn();
    insert_task(&conn, "task-1", &dest, "completed", "none", None, true, None);
    let api = api_with_clock(conn, 10_000);

    let error = api
        .report_result(report("no-such-session", "installed"))
        .expect_err("unknown session must be typed");
    println!("unknown session error: {error}");
    assert!(
        error.starts_with("CORE_E_INSTALL_SESSION"),
        "typed session error, got: {error}"
    );

    let bad_status = api
        .report_result(report("any", "exploded"))
        .expect_err("bad status must be typed");
    println!("bad status error: {bad_status}");
    assert!(
        bad_status.starts_with("CORE_E_INSTALL_STATUS"),
        "typed status error, got: {bad_status}"
    );

    let missing = api
        .install("missing-task".to_string())
        .expect_err("missing task");
    println!("missing task error: {missing}");
    assert!(
        missing.starts_with("CORE_E_INSTALL_NOT_FOUND"),
        "typed not-found error, got: {missing}"
    );

    let empty = api
        .report_result(report("   ", "installed"))
        .expect_err("blank session");
    println!("blank session error: {empty}");
    assert!(empty.starts_with("CORE_E_INSTALL_INVALID_ARG"));
}

#[test]
fn pending_requests_sweeps_expired_rows() {
    let dir = TempDir::new("sweep");
    let dest = write_apk(&dir, "app.apk");
    let conn = core_conn();
    // A pending row from a previous process: still fresh for the injected core
    // clock (10_000), but far outside the timeout window for the host clock.
    insert_task(
        &conn,
        "task-1",
        &dest,
        "completed",
        "pending",
        Some("old-session"),
        false,
        Some(10_000),
    );
    let api = api_with_clock(conn, 10_000);

    let pending = api.pending_requests().expect("pending requests");
    println!("pending after sweep: {pending:?}");
    assert!(
        pending.is_empty(),
        "pendingRequests must sweep the expired row before listing"
    );

    let events = api.take_events().expect("take events");
    println!("sweep events: {events:?}");
    assert!(
        events.iter().any(|json| event_kind(json) == "install.unknown"),
        "an expired pending row must emit install.unknown"
    );

    let record = api
        .get("task-1".to_string())
        .expect("get")
        .expect("durable row");
    assert_eq!(record.status, "unknown");

    let late = api
        .report_result(report("old-session", "installed"))
        .expect("late report");
    assert!(
        late.changed,
        "a late report on an unknown row must still be accepted"
    );
}

#[test]
fn install_requires_a_completed_download_and_an_apk() {
    let dir = TempDir::new("guards");
    let conn = core_conn();
    let dest = write_apk(&dir, "app.apk");
    insert_task(
        &conn,
        "running",
        &dest,
        "downloading",
        "none",
        None,
        true,
        None,
    );
    insert_task(
        &conn,
        "no-apk",
        &dir.path().join("missing.apk").to_string_lossy(),
        "completed",
        "none",
        None,
        true,
        None,
    );
    let api = api_with_clock(conn, 10_000);

    let not_downloaded = api.install("running".to_string()).expect_err("conflict");
    println!("not downloaded error: {not_downloaded}");
    assert!(not_downloaded.starts_with("CORE_E_INSTALL_CONFLICT"));

    let no_apk = api.install("no-apk".to_string()).expect_err("missing apk");
    println!("missing apk error: {no_apk}");
    assert!(no_apk.starts_with("CORE_E_INSTALL_INVALID_ARG"));
    assert!(no_apk.contains("CORE_E_INSTALL_APK_MISSING"));

    assert!(
        api.get("missing".to_string())
            .expect("get missing")
            .is_none()
    );
}
