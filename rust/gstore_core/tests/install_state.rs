//! Install request/response contract.
//!
//! These tests are end-to-end over SQLite: the service persists the V4 request
//! columns, queues `install.requested`, sweeps stale `pending` rows to
//! `unknown`, and accepts a late report against an `unknown` row. No installer
//! port is involved — the frontend owns execution.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::db::{DbHandle, SharedConn};
use gstore_core::facts::{InstallReport, InstallReportStatus, InstallStart};
use gstore_core::install::{
    InstallService, INSTALL_STATUS_FAILED, INSTALL_STATUS_INSTALLED, INSTALL_STATUS_PENDING,
    INSTALL_STATUS_UNKNOWN,
};
use gstore_core::{CoreEvent, Error};
use rusqlite::params;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_core_install_{tag}_{}_{}",
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

fn make_apk(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, b"PK\x03\x04fake-apk").unwrap();
    path
}

fn clock_at(value: i64) -> (Arc<AtomicI64>, Arc<dyn Fn() -> i64 + Send + Sync>) {
    let cell = Arc::new(AtomicI64::new(value));
    let reader = Arc::clone(&cell);
    (cell, Arc::new(move || reader.load(Ordering::SeqCst)))
}

fn new_service(conn: &SharedConn, clock: Arc<dyn Fn() -> i64 + Send + Sync>) -> InstallService {
    InstallService::with_clock(Arc::clone(conn), clock)
}

/// Seeds a download row and leaves the five V4 request columns NULL so the
/// test proves `install()` populates them.
fn seed_task(conn: &SharedConn, task_id: &str, status: &str, apk: &Path, install_after: bool) {
    let file_name = apk
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let url = format!("https://example.test/{file_name}");
    conn.lock()
        .unwrap()
        .execute(
            "INSERT INTO download_task(\
                 module_task_id, app_id, resource_id, app_name, version, url, file_name, \
                 status, dest_path, install_after_download, created_at, updated_at\
             ) VALUES (?1, 'app.demo', 'com.example.demo', 'Demo', '1.2.3', ?2, ?3, ?4, ?5, ?6, 1, 1)",
            params![
                task_id,
                url,
                file_name,
                status,
                apk.to_string_lossy().to_string(),
                i64::from(install_after)
            ],
        )
        .unwrap();
}

#[derive(Debug)]
struct StoredRow {
    install_status: String,
    install_session_id: Option<String>,
    install_method: Option<String>,
    package_name: Option<String>,
    abi: Option<String>,
    variant_url: Option<String>,
    fallback_json: Option<String>,
    install_requested_at: Option<i64>,
    installed_at: Option<i64>,
    installed_version: Option<String>,
}

fn stored(conn: &SharedConn, task_id: &str) -> StoredRow {
    conn.lock()
        .unwrap()
        .query_row(
            "SELECT install_status, install_session_id, install_method, package_name, abi, \
                    variant_url, fallback_json, install_requested_at, installed_at, installed_version \
             FROM download_task WHERE module_task_id = ?1",
            [task_id],
            |row| {
                Ok(StoredRow {
                    install_status: row.get(0)?,
                    install_session_id: row.get(1)?,
                    install_method: row.get(2)?,
                    package_name: row.get(3)?,
                    abi: row.get(4)?,
                    variant_url: row.get(5)?,
                    fallback_json: row.get(6)?,
                    install_requested_at: row.get(7)?,
                    installed_at: row.get(8)?,
                    installed_version: row.get(9)?,
                })
            },
        )
        .unwrap()
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

fn requested_events(events: &[CoreEvent]) -> Vec<&CoreEvent> {
    events
        .iter()
        .filter(|event| event.wire_name() == "install.requested")
        .collect()
}

fn pending_of(start: &InstallStart) -> &gstore_core::facts::InstallRequest {
    start
        .request
        .as_ref()
        .unwrap_or_else(|| panic!("expected a pending install request, got {start:?}"))
}

#[test]
fn install_emits_request_and_reports_result() {
    let dir = TempDir::new("request_result");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "demo-arm64-v8a.apk");
    seed_task(&conn, "task-ok", "completed", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let start = service.install("task-ok").unwrap();
    println!("start = {start:?}");
    let request = pending_of(&start);
    assert_eq!(request.module_task_id, "task-ok");
    assert!(
        !request.session_id.is_empty(),
        "session id must be persisted"
    );
    assert_eq!(request.package_name, "com.example.demo");
    assert_eq!(request.version_name, "1.2.3");
    assert_eq!(request.apk_path, apk.to_string_lossy());
    assert_eq!(request.method, "platform");
    assert_eq!(request.variant.abi, "arm64-v8a");
    assert_eq!(
        request.variant.url,
        "https://example.test/demo-arm64-v8a.apk"
    );
    assert_eq!(
        request.variant.fallback_chain,
        vec!["https://example.test/demo-arm64-v8a.apk".to_string()]
    );

    let row = stored(&conn, "task-ok");
    println!("stored after install = {row:?}");
    assert_eq!(row.install_status, INSTALL_STATUS_PENDING);
    assert_eq!(
        row.install_session_id.as_deref(),
        Some(request.session_id.as_str())
    );
    assert_eq!(row.install_requested_at, Some(1_000));
    assert_eq!(row.package_name.as_deref(), Some("com.example.demo"));
    assert_eq!(row.abi.as_deref(), Some("arm64-v8a"));
    assert_eq!(
        row.variant_url.as_deref(),
        Some("https://example.test/demo-arm64-v8a.apk")
    );
    assert!(row
        .fallback_json
        .as_deref()
        .is_some_and(|json| json.contains("demo-arm64-v8a.apk")));
    assert_eq!(row.install_method.as_deref(), Some("platform"));

    let events = service.take_events();
    assert_eq!(requested_events(&events).len(), 1, "one requested event");
    assert!(service.take_events().is_empty(), "drain is consuming");

    let ack = service
        .on_result(report(
            &request.session_id,
            InstallReportStatus::Installed,
            Some("1.2.3"),
        ))
        .unwrap();
    println!("ack = {ack:?}");
    assert!(ack.changed);
    assert_eq!(ack.status, INSTALL_STATUS_INSTALLED);

    let row = stored(&conn, "task-ok");
    assert_eq!(row.install_status, INSTALL_STATUS_INSTALLED);
    assert_eq!(row.installed_version.as_deref(), Some("1.2.3"));
    assert_eq!(row.installed_at, Some(1_000));
}

#[test]
fn install_start_invariant() {
    let dir = TempDir::new("invariant");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-inv", "completed", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let start = service.install("task-inv").unwrap();
    let settled = start.record.status == INSTALL_STATUS_INSTALLED;
    assert!(
        settled ^ start.request.is_some(),
        "exactly one of installed record / request must hold: {start:?}"
    );

    let session = pending_of(&start).session_id.clone();
    service
        .on_result(report(
            &session,
            InstallReportStatus::Installed,
            Some("1.2.3"),
        ))
        .unwrap();

    let settled = service.install("task-inv").unwrap();
    assert_eq!(settled.record.status, INSTALL_STATUS_INSTALLED);
    assert!(
        settled.record.status == INSTALL_STATUS_INSTALLED && settled.request.is_none(),
        "a settled row returns no request"
    );
    let holds = settled.record.status == INSTALL_STATUS_INSTALLED;
    assert!(holds ^ settled.request.is_some());
}

#[test]
fn install_pending_row_rebuilds_request() {
    let dir = TempDir::new("rebuild");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app-arm64-v8a.apk");
    seed_task(&conn, "task-rebuild", "completed", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let first = service.install("task-rebuild").unwrap();
    let session = pending_of(&first).session_id.clone();
    let _ = service.take_events();

    let second = service.install("task-rebuild").unwrap();
    println!("second = {second:?}");
    assert_eq!(second.record.status, INSTALL_STATUS_PENDING);
    let rebuilt = pending_of(&second);
    assert_eq!(rebuilt.session_id, session, "pending reuses the session");
    assert_eq!(rebuilt.package_name, "com.example.demo");
    assert_eq!(rebuilt.variant.abi, "arm64-v8a");
    assert!(
        requested_events(&service.take_events()).is_empty(),
        "a pending rebuild must not queue a second request"
    );
}

#[test]
fn install_settled_row_returns_no_request() {
    let dir = TempDir::new("settled");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-settled", "completed", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let start = service.install("task-settled").unwrap();
    let session = pending_of(&start).session_id.clone();
    service
        .on_result(report(
            &session,
            InstallReportStatus::Installed,
            Some("1.2.3"),
        ))
        .unwrap();
    std::fs::remove_file(&apk).unwrap();

    let settled = service.install("task-settled").unwrap();
    assert_eq!(settled.record.status, INSTALL_STATUS_INSTALLED);
    assert!(
        settled.request.is_none(),
        "settled rows need no APK preflight"
    );
    assert_eq!(settled.record.installed_version.as_deref(), Some("1.2.3"));
}

#[test]
fn install_retryable_creates_new_session() {
    let dir = TempDir::new("retry");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-retry", "completed", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let first = service.install("task-retry").unwrap();
    let first_session = pending_of(&first).session_id.clone();
    let _ = service.take_events();
    service
        .on_result(report(&first_session, InstallReportStatus::Failed, None))
        .unwrap();
    assert_eq!(
        stored(&conn, "task-retry").install_status,
        INSTALL_STATUS_FAILED
    );

    let retried = service.install("task-retry").unwrap();
    let retried_session = pending_of(&retried).session_id.clone();
    assert_ne!(retried_session, first_session, "retry starts a new session");
    assert_eq!(retried.record.status, INSTALL_STATUS_PENDING);
    assert_eq!(
        stored(&conn, "task-retry").install_status,
        INSTALL_STATUS_PENDING
    );
    assert_eq!(requested_events(&service.take_events()).len(), 1);
}

#[test]
fn install_late_report_after_timeout() {
    let dir = TempDir::new("late_report");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-late", "completed", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let start = service.install("task-late").unwrap();
    let session = pending_of(&start).session_id.clone();
    let _ = service.take_events();

    // Default InstallRules::timeout_secs = 180.
    let swept = service.sweep_timeouts(1_000 + 180_000 + 1).unwrap();
    println!("sweep events = {swept:?}");
    assert_eq!(swept.len(), 1);
    match &swept[0] {
        CoreEvent::InstallUnknown {
            session_id,
            module_task_id,
        } => {
            assert_eq!(session_id, &session);
            assert_eq!(module_task_id.as_deref(), Some("task-late"));
        }
        other => panic!("unexpected sweep event: {other:?}"),
    }
    assert_eq!(
        stored(&conn, "task-late").install_status,
        INSTALL_STATUS_UNKNOWN
    );

    // A late report is accepted against the `unknown` row.
    let ack = service
        .on_result(report(
            &session,
            InstallReportStatus::Installed,
            Some("1.2.4"),
        ))
        .unwrap();
    assert!(ack.changed, "a late report still settles the row");
    assert_eq!(ack.status, INSTALL_STATUS_INSTALLED);
    let row = stored(&conn, "task-late");
    assert_eq!(row.install_status, INSTALL_STATUS_INSTALLED);
    assert_eq!(row.installed_version.as_deref(), Some("1.2.4"));
}

#[test]
fn install_double_report_changed_false() {
    let dir = TempDir::new("double_report");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-double", "completed", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let start = service.install("task-double").unwrap();
    let session = pending_of(&start).session_id.clone();

    let first = service
        .on_result(report(
            &session,
            InstallReportStatus::Installed,
            Some("1.2.3"),
        ))
        .unwrap();
    assert!(first.changed);
    let installed_at = stored(&conn, "task-double").installed_at;

    let second = service
        .on_result(report(
            &session,
            InstallReportStatus::Installed,
            Some("9.9.9"),
        ))
        .unwrap();
    println!("duplicate ack = {second:?}");
    assert!(!second.changed, "a terminal row accepts no second change");
    assert_eq!(second.status, INSTALL_STATUS_INSTALLED);
    let row = stored(&conn, "task-double");
    assert_eq!(row.installed_version.as_deref(), Some("1.2.3"));
    assert_eq!(row.installed_at, installed_at, "installed_at must not move");

    // Late/duplicate reports on any other terminal status are equally inert.
    let dir = TempDir::new("double_denied");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-denied", "completed", &apk, false);
    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);
    let session = pending_of(&service.install("task-denied").unwrap())
        .session_id
        .clone();
    assert!(
        service
            .on_result(report(&session, InstallReportStatus::Denied, None))
            .unwrap()
            .changed
    );
    assert!(
        !service
            .on_result(report(&session, InstallReportStatus::Installed, None))
            .unwrap()
            .changed
    );
}

#[test]
fn install_empty_session_becomes_unknown() {
    let dir = TempDir::new("empty_session");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-empty", "completed", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);
    service.install("task-empty").unwrap();
    conn.lock()
        .unwrap()
        .execute(
            "UPDATE download_task SET install_session_id = '' WHERE module_task_id = 'task-empty'",
            [],
        )
        .unwrap();

    let swept = service.sweep_timeouts(1_000).unwrap();
    println!("empty-session sweep = {swept:?}");
    assert_eq!(swept.len(), 1);
    assert_eq!(
        stored(&conn, "task-empty").install_status,
        INSTALL_STATUS_UNKNOWN
    );
    assert!(
        service.pending_requests().unwrap().is_empty(),
        "an unknown row is not a pending request"
    );
}

#[test]
fn install_pending_requests_after_restart() {
    let dir = TempDir::new("restart");
    let db_path = dir.path().join("gstore_core.db");
    let apk = make_apk(dir.path(), "app.apk");

    let session;
    {
        let db = DbHandle::open_at(&db_path).unwrap();
        let conn = db.shared_writer();
        seed_task(&conn, "task-restart", "completed", &apk, false);
        let (_, clock) = clock_at(1_000);
        let service = new_service(&conn, clock);
        session = pending_of(&service.install("task-restart").unwrap())
            .session_id
            .clone();
    }

    let db = DbHandle::open_at(&db_path).unwrap();
    let conn = db.shared_writer();
    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let pending = service.pending_requests().unwrap();
    println!("pending after restart = {pending:?}");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].record.status, INSTALL_STATUS_PENDING);
    assert_eq!(pending_of(&pending[0]).session_id, session);

    let ack = service
        .on_result(report(
            &session,
            InstallReportStatus::Installed,
            Some("1.2.3"),
        ))
        .unwrap();
    assert!(ack.changed);
    assert_eq!(
        service.get("task-restart").unwrap().status,
        INSTALL_STATUS_INSTALLED
    );
}

#[test]
fn install_after_download_emits_request() {
    let dir = TempDir::new("after_download");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let auto = make_apk(dir.path(), "auto.apk");
    let manual = make_apk(dir.path(), "manual.apk");
    let queued = make_apk(dir.path(), "queued.apk");
    seed_task(&conn, "task-auto", "completed", &auto, true);
    seed_task(&conn, "task-manual", "completed", &manual, false);
    seed_task(&conn, "task-queued", "queued", &queued, true);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    let first = service
        .maybe_install_after_download("task-auto")
        .unwrap()
        .expect("auto install runs once");
    assert_eq!(pending_of(&first).module_task_id, "task-auto");
    assert_eq!(requested_events(&service.take_events()).len(), 1);

    assert!(service
        .maybe_install_after_download("task-auto")
        .unwrap()
        .is_none());
    assert!(service
        .maybe_install_after_download("task-manual")
        .unwrap()
        .is_none());
    assert!(service
        .maybe_install_after_download("task-queued")
        .unwrap()
        .is_none());
    assert!(service.take_events().is_empty(), "skips queue no request");
}

#[test]
fn install_malformed_inputs_typed() {
    let dir = TempDir::new("malformed");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "app.apk");
    seed_task(&conn, "task-ok", "completed", &apk, false);
    seed_task(
        &conn,
        "task-missing",
        "completed",
        Path::new("/definitely/not/here.apk"),
        false,
    );
    seed_task(&conn, "task-downloading", "downloading", &apk, false);

    let (_, clock) = clock_at(1_000);
    let service = new_service(&conn, clock);

    match service.install("task-missing") {
        Err(Error::InvalidArgument(message)) => {
            assert!(message.contains("CORE_E_INSTALL_APK_MISSING"), "{message}");
        }
        other => panic!("expected InvalidArgument, got {other:?}"),
    }
    match service.install("task-downloading") {
        Err(Error::Conflict(message)) => {
            assert!(
                message.contains("CORE_E_INSTALL_NOT_DOWNLOADED"),
                "{message}"
            );
        }
        other => panic!("expected Conflict, got {other:?}"),
    }
    match service.install("task-nope") {
        Err(Error::NotFound(message)) => assert!(message.contains("task-nope"), "{message}"),
        other => panic!("expected NotFound, got {other:?}"),
    }

    let start = service.install("task-ok").unwrap();
    let session = pending_of(&start).session_id.clone();

    match service.on_result(report(
        "not-a-session",
        InstallReportStatus::Installed,
        None,
    )) {
        Err(Error::NotFound(message)) => {
            assert!(message.contains("CORE_E_INSTALL_SESSION"), "{message}");
        }
        other => panic!("expected NotFound, got {other:?}"),
    }
    match service.on_result(report("", InstallReportStatus::Failed, None)) {
        Err(Error::InvalidArgument(message)) => {
            assert!(message.contains("CORE_E_INSTALL_SESSION"), "{message}");
        }
        other => panic!("expected InvalidArgument, got {other:?}"),
    }

    // The valid session is still pending and can settle normally.
    assert!(
        service
            .on_result(report(&session, InstallReportStatus::Timeout, None))
            .unwrap()
            .changed
    );
    assert_eq!(
        service.get("task-ok").unwrap().status,
        gstore_core::install::INSTALL_STATUS_TIMEOUT
    );
}
