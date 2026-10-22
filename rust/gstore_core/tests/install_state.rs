//! Wave 3 install-state contract.
//!
//! These tests are deliberately end-to-end over SQLite plus a recording
//! `FakeInstallerPort`: they prove the durable install columns, the atomic
//! attempt guard, exactly-once event emission, and process-death recovery.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use gstore_core::db::{DbHandle, SharedConn};
use gstore_core::install::{
    InstallService, INSTALL_STATUS_DENIED, INSTALL_STATUS_INSTALLED, INSTALL_STATUS_NONE,
    INSTALL_STATUS_PENDING, INSTALL_STATUS_TIMEOUT,
};
use gstore_core::ports::fake::{FakeInstallerPort, RecordedInstallCall};
use gstore_core::ports::{InstallOutcome, InstallerPort};
use gstore_core::{CoreEvent, Error};

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

fn seed_task(
    conn: &SharedConn,
    module_task_id: &str,
    status: &str,
    dest_path: &str,
    install_after_download: bool,
) {
    let conn = conn.lock().unwrap();
    conn.execute(
        "INSERT INTO download_task(\
             module_task_id, app_id, app_name, version, status, dest_path, \
             install_after_download, created_at, updated_at\
         ) VALUES (?1, 'app.demo', 'Demo', '1.2.3', ?2, ?3, ?4, 1, 1)",
        rusqlite::params![
            module_task_id,
            status,
            dest_path,
            if install_after_download { 1 } else { 0 }
        ],
    )
    .unwrap();
}

fn table_columns(conn: &SharedConn) -> Vec<String> {
    let conn = conn.lock().unwrap();
    let mut stmt = conn.prepare("PRAGMA table_info(download_task)").unwrap();
    stmt.query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .map(|row| row.unwrap())
        .collect()
}

fn user_version(conn: &SharedConn) -> i32 {
    let conn = conn.lock().unwrap();
    conn.pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap()
}

fn install_events(events: &[CoreEvent]) -> Vec<&CoreEvent> {
    events
        .iter()
        .filter(|event| event.wire_name() == "install.result")
        .collect()
}

fn installed_outcome(version: &str) -> InstallOutcome {
    InstallOutcome::Installed {
        package_name: Some("com.example.demo".to_string()),
        version_name: Some(version.to_string()),
    }
}

#[test]
fn install_state_contract() {
    let dir = TempDir::new("contract");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();

    let columns = table_columns(&conn);
    println!("download_task columns = {columns:?}");
    println!("user_version = {}", user_version(&conn));
    for required in [
        "install_status",
        "install_method",
        "install_session_id",
        "install_error",
        "installed_at",
        "installed_version",
    ] {
        assert!(
            columns.iter().any(|column| column == required),
            "missing install column {required}; columns={columns:?}"
        );
    }
    assert_eq!(user_version(&conn), 3, "V3 must stamp user_version=3");

    let apk = make_apk(dir.path(), "demo.apk");
    seed_task(&conn, "task-ok", "completed", apk.to_str().unwrap(), false);

    let fake = Arc::new(FakeInstallerPort::new(true));
    fake.set_immediate(installed_outcome("1.2.3"));
    let service = InstallService::new(Arc::clone(&conn), fake.clone());

    let attempt = service.install("task-ok").unwrap();
    println!("attempt = {attempt:?}");
    assert_eq!(attempt.record.status, INSTALL_STATUS_INSTALLED);
    assert!(
        attempt.record.installed_at.unwrap_or(0) > 0,
        "installed_at must be a real timestamp"
    );
    assert_eq!(
        attempt.record.installed_version.as_deref(),
        Some("1.2.3"),
        "installed version must be recorded"
    );
    let event = attempt.event.expect("immediate success emits one event");
    match event {
        CoreEvent::InstallResult {
            app_id,
            package_name,
            success,
            ..
        } => {
            assert_eq!(app_id, "app.demo");
            assert_eq!(package_name.as_deref(), Some("com.example.demo"));
            assert!(success, "successful install event must have success=true");
        }
        other => panic!("unexpected event: {other:?}"),
    }

    // can_install=false is typed Unsupported.
    let unsupported_apk = make_apk(dir.path(), "unsupported.apk");
    seed_task(
        &conn,
        "task-unsupported",
        "completed",
        unsupported_apk.to_str().unwrap(),
        false,
    );
    let disabled = Arc::new(FakeInstallerPort::new(false));
    let disabled_service = InstallService::new(Arc::clone(&conn), disabled.clone());
    match disabled_service.install("task-unsupported") {
        Err(Error::Unsupported(message)) => {
            assert!(message.contains("CORE_E_INSTALL_UNSUPPORTED"), "{message}");
        }
        other => panic!("expected Unsupported, got {other:?}"),
    }

    // Non-completed rows cannot be installed.
    let not_done_apk = make_apk(dir.path(), "not-done.apk");
    seed_task(
        &conn,
        "task-not-done",
        "downloading",
        not_done_apk.to_str().unwrap(),
        false,
    );
    match service.install("task-not-done") {
        Err(Error::Conflict(message)) => {
            assert!(
                message.contains("CORE_E_INSTALL_NOT_DOWNLOADED"),
                "{message}"
            );
        }
        other => panic!("expected Conflict, got {other:?}"),
    }

    // Missing APK is InvalidArgument and does not touch the installer.
    seed_task(
        &conn,
        "task-missing",
        "completed",
        "/definitely/not/here.apk",
        false,
    );
    match service.install("task-missing") {
        Err(Error::InvalidArgument(message)) => {
            assert!(message.contains("CORE_E_INSTALL_APK_MISSING"), "{message}");
        }
        other => panic!("expected InvalidArgument, got {other:?}"),
    }
    assert_eq!(
        fake.begin_count(),
        1,
        "only the valid task may reach begin_install"
    );

    // Unknown task id is NotFound.
    assert!(matches!(
        service.install("task-nope"),
        Err(Error::NotFound(_))
    ));
}

#[test]
fn install_idempotent() {
    let dir = TempDir::new("idempotent");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "demo.apk");
    seed_task(
        &conn,
        "task-pending",
        "completed",
        apk.to_str().unwrap(),
        false,
    );

    let fake = Arc::new(FakeInstallerPort::new(true));
    fake.set_pending();
    let service = InstallService::new(Arc::clone(&conn), fake.clone());

    let first = service.install("task-pending").unwrap();
    println!("first = {first:?}");
    println!("begin_count after first = {}", fake.begin_count());
    assert_eq!(first.record.status, INSTALL_STATUS_PENDING);
    assert!(first.event.is_none(), "pending attempt emits no event");
    let session = first.record.session_id.clone().expect("durable session id");
    assert!(!session.is_empty());
    assert_eq!(fake.begin_count(), 1);

    let second = service.install("task-pending").unwrap();
    println!("second = {second:?}");
    println!("begin_count after second = {}", fake.begin_count());
    assert_eq!(second.record.status, INSTALL_STATUS_PENDING);
    assert!(second.event.is_none());
    assert_eq!(
        fake.begin_count(),
        1,
        "second install while pending must not call begin_install"
    );

    let event = service
        .on_result(
            &session,
            INSTALL_STATUS_INSTALLED,
            Some("com.example.demo"),
            Some("1.2.3"),
            None,
        )
        .unwrap()
        .expect("first terminal result emits an event");
    assert!(matches!(
        event,
        CoreEvent::InstallResult { success: true, .. }
    ));
    let installed = service.get("task-pending").unwrap();
    assert_eq!(installed.status, INSTALL_STATUS_INSTALLED);
    let installed_at = installed.installed_at.expect("installed_at set");
    assert_eq!(installed.installed_version.as_deref(), Some("1.2.3"));

    let duplicate = service
        .on_result(
            &session,
            INSTALL_STATUS_INSTALLED,
            Some("com.example.demo"),
            Some("1.2.3"),
            None,
        )
        .unwrap();
    assert!(duplicate.is_none(), "duplicate result must be a no-op");
    let after = service.get("task-pending").unwrap();
    assert_eq!(
        after.installed_at,
        Some(installed_at),
        "duplicate result must not move installed_at"
    );
}

#[test]
fn install_installed_row_is_idempotent_without_apk() {
    let dir = TempDir::new("installed_no_apk");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "idempotent.apk");
    seed_task(
        &conn,
        "task-installed",
        "completed",
        apk.to_str().unwrap(),
        false,
    );

    let fake = Arc::new(FakeInstallerPort::new(true));
    fake.set_immediate(installed_outcome("1.2.3"));
    let service = InstallService::new(Arc::clone(&conn), fake.clone());

    let first = service.install("task-installed").unwrap();
    assert_eq!(first.record.status, INSTALL_STATUS_INSTALLED);
    assert_eq!(fake.begin_count(), 1);

    std::fs::remove_file(&apk).expect("apk deleted after install");

    let second = service
        .install("task-installed")
        .expect("already-installed row must be an idempotent no-op");
    assert_eq!(second.record.status, INSTALL_STATUS_INSTALLED);
    assert!(
        second.event.is_none(),
        "no second event for a no-op install"
    );
    assert_eq!(second.record.installed_version.as_deref(), Some("1.2.3"));
    assert_eq!(
        fake.begin_count(),
        1,
        "deleting the APK must not trigger another begin_install"
    );
}

#[test]
fn install_port_failure_is_durable_result() {
    let dir = TempDir::new("port_failure");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "failure.apk");
    seed_task(
        &conn,
        "task-failure",
        "completed",
        apk.to_str().unwrap(),
        false,
    );

    let fake = Arc::new(FakeInstallerPort::new(true));
    fake.set_begin_error("installer exploded");
    let service = InstallService::new(Arc::clone(&conn), fake.clone());

    let attempt = service
        .install("task-failure")
        .expect("a port-level install failure is a durable Ok result");
    println!("port-failure attempt = {attempt:?}");
    assert_eq!(attempt.record.status, "failed");
    assert_eq!(attempt.record.error.as_deref(), Some("installer exploded"));
    assert!(matches!(
        attempt.event,
        Some(CoreEvent::InstallResult { success: false, .. })
    ));
    assert_eq!(fake.begin_count(), 1);
    assert_eq!(
        service.get("task-failure").unwrap().status,
        "failed",
        "failure must be persisted"
    );
}

#[test]
fn install_reconcile_partial_failure_preserves_events() {
    let dir = TempDir::new("partial_failure");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk_a = make_apk(dir.path(), "a.apk");
    let apk_b = make_apk(dir.path(), "b.apk");
    seed_task(&conn, "task-a", "completed", apk_a.to_str().unwrap(), false);
    seed_task(&conn, "task-b", "completed", apk_b.to_str().unwrap(), false);

    let fake = Arc::new(FakeInstallerPort::new(true));
    fake.set_pending();
    let service = InstallService::new(Arc::clone(&conn), fake.clone());
    let session_a = service
        .install("task-a")
        .unwrap()
        .record
        .session_id
        .expect("session A");
    let session_b = service
        .install("task-b")
        .unwrap()
        .record
        .session_id
        .expect("session B");

    fake.complete(
        &session_a,
        InstallOutcome::Installed {
            package_name: Some("com.example.a".to_string()),
            version_name: Some("1.2.3".to_string()),
        },
    );
    fake.fail_session(&session_b, "transient poll failure");

    let (report, events) = service.reconcile().unwrap();
    println!("partial reconcile = ({report:?}, {events:?})");
    assert_eq!(report.checked, 2);
    assert_eq!(report.resolved, 1);
    assert_eq!(report.still_pending, 1);
    assert_eq!(report.errors.len(), 1, "row B failure is reported per row");
    assert!(report.errors[0].contains("task-b"));
    assert!(report.errors[0].contains("transient poll failure"));
    assert_eq!(events.len(), 1, "row A event must survive row B failure");
    match &events[0] {
        CoreEvent::InstallResult {
            app_id,
            package_name,
            success,
            ..
        } => {
            assert_eq!(app_id, "app.demo");
            assert_eq!(package_name.as_deref(), Some("com.example.a"));
            assert!(success);
        }
        other => panic!("unexpected event: {other:?}"),
    }
    assert_eq!(
        service.get("task-a").unwrap().status,
        INSTALL_STATUS_INSTALLED
    );
    assert_eq!(
        service.get("task-b").unwrap().status,
        INSTALL_STATUS_PENDING
    );

    // A is terminal, so the second sweep only sees B and never re-emits A.
    let (report, events) = service.reconcile().unwrap();
    println!("partial reconcile#2 = ({report:?}, {events:?})");
    assert_eq!(
        report.checked, 1,
        "only the still-pending row is re-scanned"
    );
    assert_eq!(report.resolved, 0);
    assert_eq!(report.still_pending, 1);
    assert_eq!(report.errors.len(), 1);
    assert!(events.is_empty(), "A's event must not be emitted twice");
}

#[test]
fn install_after_download_once() {
    let dir = TempDir::new("after_download");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let apk = make_apk(dir.path(), "auto.apk");
    let manual_apk = make_apk(dir.path(), "manual.apk");
    seed_task(&conn, "task-auto", "completed", apk.to_str().unwrap(), true);
    seed_task(
        &conn,
        "task-manual",
        "completed",
        manual_apk.to_str().unwrap(),
        false,
    );

    let fake = Arc::new(FakeInstallerPort::new(true));
    fake.set_immediate(installed_outcome("1.2.3"));
    let service = InstallService::new(Arc::clone(&conn), fake.clone());

    let first = service
        .maybe_install_after_download("task-auto")
        .unwrap()
        .expect("first after-download install runs");
    assert_eq!(first.record.status, INSTALL_STATUS_INSTALLED);
    assert!(matches!(
        first.event,
        Some(CoreEvent::InstallResult { success: true, .. })
    ));

    let second = service.maybe_install_after_download("task-auto").unwrap();
    assert!(
        second.is_none(),
        "second after-download run must be a no-op"
    );
    assert_eq!(fake.begin_count(), 1, "install exactly once");

    let skipped = service.maybe_install_after_download("task-manual").unwrap();
    assert!(
        skipped.is_none(),
        "install_after_download=0 must be skipped"
    );
    assert_eq!(
        fake.begin_count(),
        1,
        "skipped task must not call begin_install"
    );

    // A task that never downloaded also has no auto-install.
    let pending_apk = make_apk(dir.path(), "queued.apk");
    seed_task(
        &conn,
        "task-queued",
        "queued",
        pending_apk.to_str().unwrap(),
        true,
    );
    assert!(service
        .maybe_install_after_download("task-queued")
        .unwrap()
        .is_none());
    assert_eq!(fake.begin_count(), 1);
}

#[test]
fn install_pending_survives_process_death() {
    let dir = TempDir::new("restart");
    let db_path = dir.path().join("gstore_core.db");
    let apk = make_apk(dir.path(), "durable.apk");

    let session;
    {
        // First "process": begin a pending install and drop the service handle.
        let db = DbHandle::open_at(&db_path).unwrap();
        let conn = db.shared_writer();
        seed_task(
            &conn,
            "task-durable",
            "completed",
            apk.to_str().unwrap(),
            false,
        );
        let fake = Arc::new(FakeInstallerPort::new(true));
        fake.set_pending();
        let service = InstallService::new(Arc::clone(&conn), fake.clone());
        let attempt = service.install("task-durable").unwrap();
        assert_eq!(attempt.record.status, INSTALL_STATUS_PENDING);
        session = attempt.record.session_id.expect("session persisted");
    }

    // Second "process": reopen the same database and a fresh port.
    let db = DbHandle::open_at(&db_path).unwrap();
    let conn = db.shared_writer();
    let fake = Arc::new(FakeInstallerPort::new(true));
    fake.set_pending();
    let service = InstallService::new(Arc::clone(&conn), fake.clone());

    let (report, events) = service.reconcile().unwrap();
    println!("reconcile#1 = {report:?} events={events:?}");
    assert_eq!(report.checked, 1);
    assert_eq!(report.resolved, 0);
    assert_eq!(report.still_pending, 1);
    assert!(events.is_empty(), "unresolved pending emits no event");
    assert_eq!(
        service.get("task-durable").unwrap().status,
        INSTALL_STATUS_PENDING,
        "pending survives process death"
    );

    fake.complete(&session, installed_outcome("1.2.3"));
    let (report, events) = service.reconcile().unwrap();
    println!("reconcile#2 = {report:?} events={events:?}");
    assert_eq!(report.checked, 1);
    assert_eq!(report.resolved, 1);
    assert_eq!(report.still_pending, 0);
    let events = install_events(&events);
    assert_eq!(
        events.len(),
        1,
        "resolution emits exactly one install event"
    );
    assert!(matches!(
        events[0],
        CoreEvent::InstallResult { success: true, .. }
    ));
    assert_eq!(
        service.get("task-durable").unwrap().status,
        INSTALL_STATUS_INSTALLED
    );

    // An empty persisted session id is downgraded to unknown, not retried.
    conn.lock()
        .unwrap()
        .execute(
            "UPDATE download_task SET install_status='pending', install_session_id='' \
             WHERE module_task_id='task-durable'",
            [],
        )
        .unwrap();
    let (report, events) = service.reconcile().unwrap();
    assert_eq!(report.checked, 1);
    assert_eq!(report.resolved, 1);
    assert_eq!(report.still_pending, 0);
    assert!(events.is_empty());
    assert_eq!(
        service.get("task-durable").unwrap().status,
        "unknown",
        "missing session id becomes unknown"
    );
}

#[test]
fn install_denied_and_timeout_are_terminal() {
    let dir = TempDir::new("terminal");
    let db = DbHandle::open_at(&dir.path().join("gstore_core.db")).unwrap();
    let conn = db.shared_writer();
    let denied_apk = make_apk(dir.path(), "denied.apk");
    let timeout_apk = make_apk(dir.path(), "timeout.apk");
    seed_task(
        &conn,
        "task-denied",
        "completed",
        denied_apk.to_str().unwrap(),
        false,
    );
    seed_task(
        &conn,
        "task-timeout",
        "completed",
        timeout_apk.to_str().unwrap(),
        false,
    );

    let fake = Arc::new(FakeInstallerPort::new(true));
    fake.set_immediate(InstallOutcome::Denied {
        message: "user rejected".to_string(),
    });
    let service = InstallService::new(Arc::clone(&conn), fake.clone());

    let denied = service.install("task-denied").unwrap();
    assert_eq!(denied.record.status, INSTALL_STATUS_DENIED);
    let session = denied.record.session_id.clone().expect("session id");
    assert!(matches!(
        denied.event,
        Some(CoreEvent::InstallResult { success: false, .. })
    ));
    let duplicate = service
        .on_result(&session, INSTALL_STATUS_DENIED, None, None, Some("again"))
        .unwrap();
    assert!(
        duplicate.is_none(),
        "denied is terminal: duplicate result must be a no-op"
    );
    assert_eq!(
        fake.begin_count(),
        1,
        "denied rejection must not silently fall back to another install"
    );

    fake.set_immediate(InstallOutcome::Timeout {
        message: Some("timed out".to_string()),
    });
    let timeout = service.install("task-timeout").unwrap();
    assert_eq!(timeout.record.status, INSTALL_STATUS_TIMEOUT);
    let session = timeout.record.session_id.clone().expect("session id");
    assert!(matches!(
        timeout.event,
        Some(CoreEvent::InstallResult { success: false, .. })
    ));
    let duplicate = service
        .on_result(&session, INSTALL_STATUS_TIMEOUT, None, None, Some("again"))
        .unwrap();
    assert!(duplicate.is_none(), "timeout is terminal");

    // Re-attempting a denied task is allowed (the guard only blocks pending/installed).
    fake.set_immediate(installed_outcome("1.2.4"));
    let retried = service.install("task-denied").unwrap();
    assert_eq!(retried.record.status, INSTALL_STATUS_INSTALLED);
    assert_eq!(
        fake.begin_count(),
        3,
        "invalid/denied retry must call begin_install exactly once more"
    );

    // The terminal seeded rows never silently lost their status.
    assert_ne!(
        service.get("task-timeout").unwrap().status,
        INSTALL_STATUS_NONE
    );
}

#[test]
fn install_port_contract_is_wired() {
    // Guards the port surface used by the service (no direct platform calls).
    let fake = FakeInstallerPort::new(true);
    assert!(InstallerPort::can_install(&fake));
    let calls: Vec<RecordedInstallCall> = fake.begin_calls();
    assert!(calls.is_empty());
    assert!(InstallerPort::pending_sessions(&fake).unwrap().is_empty());
}
