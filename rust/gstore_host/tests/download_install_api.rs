//! Wave 3 Todo 6 contract: the FRB `InstallApi` over the durable install service.
//!
//! All tests use an in-memory core database and a fake `InstallerPort`; no
//! device, JNI VM, or module `.so` is required.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use gstore_core::db::SharedConn;
use gstore_core::download::port::ModuleBridge;
use gstore_core::install::service::InstallService;
use gstore_core::ports::installer::{InstallMethod, InstallOutcome, InstallTicket, InstallerPort};
use gstore_core::Error;
use gstore_host::bridge::{DownloadApi, InstallApi};
use gstore_host::download_host::HostDownloadPort;
use rusqlite::Connection;
use serde_json::Value;

static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "gstore_download_install_api_{tag}_{}_{}",
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

#[derive(Default)]
struct FakeState {
    can: AtomicBool,
    async_install: AtomicBool,
    install_calls: AtomicUsize,
    result_calls: AtomicUsize,
    sync_outcome: Mutex<Option<InstallOutcome>>,
    reconcile_outcome: Mutex<Option<InstallOutcome>>,
}

#[derive(Clone, Default)]
struct FakeInstaller {
    state: Arc<FakeState>,
}

impl FakeInstaller {
    fn enabled(sync: InstallOutcome) -> Self {
        let fake = Self::default();
        fake.state.can.store(true, Ordering::SeqCst);
        *fake
            .state
            .sync_outcome
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(sync);
        fake
    }

    fn async_pending() -> Self {
        let fake = Self::default();
        fake.state.can.store(true, Ordering::SeqCst);
        fake.state.async_install.store(true, Ordering::SeqCst);
        fake
    }

    fn without_capability() -> Self {
        Self::default()
    }

    fn with_reconcile_outcome(self, outcome: InstallOutcome) -> Self {
        *self
            .state
            .reconcile_outcome
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(outcome);
        self
    }
}

impl InstallerPort for FakeInstaller {
    fn can_install(&self) -> bool {
        self.state.can.load(Ordering::SeqCst)
    }

    fn begin_install(&self, apk_path: &Path, _session_id: &str) -> Result<InstallTicket, Error> {
        self.state.install_calls.fetch_add(1, Ordering::SeqCst);
        if !apk_path.is_file() {
            return Err(Error::InvalidArgument(format!(
                "fake apk missing: {}",
                apk_path.display()
            )));
        }
        let outcome = if self.state.async_install.load(Ordering::SeqCst) {
            None
        } else {
            self.state
                .sync_outcome
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone()
        };
        Ok(InstallTicket {
            method: InstallMethod::Shizuku,
            outcome,
        })
    }

    fn install_result(&self, _session_id: &str) -> Result<Option<InstallOutcome>, Error> {
        self.state.result_calls.fetch_add(1, Ordering::SeqCst);
        Ok(self
            .state
            .reconcile_outcome
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone())
    }

    fn uninstall(&self, package_name: &str) -> Result<(), Error> {
        if package_name.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "package name must not be empty".to_string(),
            ));
        }
        Ok(())
    }

    fn launch(&self, package_name: &str) -> Result<(), Error> {
        if package_name.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "package name must not be empty".to_string(),
            ));
        }
        Ok(())
    }

    fn pending_sessions(&self) -> Result<Vec<String>, Error> {
        Ok(Vec::new())
    }
}

fn core_conn() -> SharedConn {
    let mut conn = Connection::open_in_memory().expect("open in-memory core db");
    gstore_core::migration::apply_core_schema(&mut conn).expect("apply core schema");
    Arc::new(Mutex::new(conn))
}

fn insert_task(
    conn: &SharedConn,
    module_task_id: &str,
    dest_path: &str,
    download_status: &str,
    install_status: &str,
    session_id: Option<&str>,
    install_after_download: bool,
) {
    let guard = conn.lock().expect("core db lock");
    guard
        .execute(
            "INSERT INTO download_task(\
                 module_task_id, app_id, dest_path, status, install_status, \
                 install_session_id, install_after_download, created_at, updated_at\
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, 1)",
            rusqlite::params![
                module_task_id,
                "com.example.one",
                dest_path,
                download_status,
                install_status,
                session_id,
                i64::from(install_after_download),
            ],
        )
        .expect("insert download_task");
}

fn seeded_api(fake: FakeInstaller, dest_path: &str) -> InstallApi {
    let conn = core_conn();
    insert_task(&conn, "task-1", dest_path, "completed", "none", None, true);
    let service = InstallService::new(conn, Arc::new(fake));
    InstallApi::from_service_for_test(service)
}

fn installed(package: &str, version: &str) -> InstallOutcome {
    InstallOutcome::Installed {
        package_name: Some(package.to_string()),
        version_name: Some(version.to_string()),
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
fn download_install_api_installs_completed_row() {
    let dir = TempDir::new("install");
    let apk = dir.path().join("app.apk");
    std::fs::write(&apk, b"PK\x03\x04fake apk").expect("write apk");
    let dest = apk.to_string_lossy().into_owned();
    let api = seeded_api(
        FakeInstaller::enabled(installed("com.example.one", "1.2.3")),
        &dest,
    );

    let attempt = api.install("task-1".to_string()).expect("install");
    println!(
        "download_install_api install record: {:?} event: {:?}",
        attempt.record, attempt.event_json
    );
    assert_eq!(attempt.record.status, "installed");
    assert_eq!(attempt.record.method.as_deref(), Some("shizuku"));
    assert_eq!(attempt.record.installed_version.as_deref(), Some("1.2.3"));
    assert!(attempt.record.installed_at.is_some());
    let json = attempt.event_json.expect("install event");
    assert_eq!(event_kind(&json), "install.result");
    assert_eq!(
        serde_json::from_str::<Value>(&json).expect("event JSON")["payload"]["success"],
        Value::Bool(true)
    );
}

#[test]
fn download_install_api_on_result_dedupes() {
    let dir = TempDir::new("dedupe");
    let apk = dir.path().join("app.apk");
    std::fs::write(&apk, b"PK\x03\x04fake apk").expect("write apk");
    let dest = apk.to_string_lossy().into_owned();
    let api = seeded_api(FakeInstaller::async_pending(), &dest);

    let pending = api.install("task-1".to_string()).expect("start install");
    assert_eq!(pending.record.status, "pending");
    assert!(pending.event_json.is_none());
    let session = pending.record.session_id.expect("session id");

    let first = api
        .on_result(
            session.clone(),
            "installed".to_string(),
            Some("com.example.one".to_string()),
            Some("1.2.3".to_string()),
            None,
        )
        .expect("first result");
    println!("download_install_api on_result first: {first:?}");
    assert_eq!(
        first.as_deref().map(event_kind).as_deref(),
        Some("install.result")
    );

    let duplicate = api
        .on_result(
            session,
            "installed".to_string(),
            Some("com.example.one".to_string()),
            Some("1.2.3".to_string()),
            None,
        )
        .expect("duplicate result");
    println!("download_install_api on_result duplicate: {duplicate:?}");
    assert!(
        duplicate.is_none(),
        "duplicate on_result must emit no event"
    );
}

#[test]
fn download_install_api_can_install_false_is_typed() {
    let dir = TempDir::new("unsupported");
    let apk = dir.path().join("app.apk");
    std::fs::write(&apk, b"PK\x03\x04fake apk").expect("write apk");
    let dest = apk.to_string_lossy().into_owned();
    let api = seeded_api(FakeInstaller::without_capability(), &dest);

    assert!(!api.can_install());
    let error = api
        .install("task-1".to_string())
        .expect_err("unsupported install must fail");
    println!("download_install_api unsupported error: {error}");
    assert!(
        error.starts_with("CORE_E_INSTALL_UNSUPPORTED"),
        "typed unsupported prefix: {error}"
    );
}

#[test]
fn download_install_api_list_pending_and_maybe_install_once() {
    let dir = TempDir::new("pending");
    let apk = dir.path().join("app.apk");
    std::fs::write(&apk, b"PK\x03\x04fake apk").expect("write apk");
    let dest = apk.to_string_lossy().into_owned();
    let conn = core_conn();
    insert_task(&conn, "task-1", &dest, "completed", "none", None, true);
    insert_task(
        &conn,
        "task-2",
        "/tmp/other.apk",
        "completed",
        "pending",
        Some("task-2:1:0:1"),
        false,
    );
    let service = InstallService::new(
        conn,
        Arc::new(FakeInstaller::enabled(installed(
            "com.example.one",
            "1.2.3",
        ))),
    );
    let api = InstallApi::from_service_for_test(service);

    let pending = api.list_pending().expect("list pending");
    println!("download_install_api pending rows: {pending:?}");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].module_task_id, "task-2");

    let first = api
        .maybe_install_after_download("task-1".to_string())
        .expect("maybe install");
    assert_eq!(
        first.as_ref().map(|attempt| attempt.record.status.as_str()),
        Some("installed")
    );
    let second = api
        .maybe_install_after_download("task-1".to_string())
        .expect("maybe install twice");
    println!("download_install_api maybe second: {second:?}");
    assert!(second.is_none(), "auto-install must run at most once");
}

#[test]
fn download_install_api_reconcile_reports_and_events() {
    let conn = core_conn();
    insert_task(
        &conn,
        "task-1",
        "/tmp/app.apk",
        "completed",
        "pending",
        Some("task-1:1:0:1"),
        false,
    );
    let fake =
        FakeInstaller::default().with_reconcile_outcome(installed("com.example.one", "1.2.3"));
    let service = InstallService::new(conn, Arc::new(fake));
    let api = InstallApi::from_service_for_test(service);

    let report = api.reconcile().expect("reconcile");
    println!("download_install_api reconcile: {report:?}");
    assert_eq!(report.checked, 1);
    assert_eq!(report.resolved, 1);
    assert_eq!(report.still_pending, 0);
    assert!(report.errors.is_empty());
    assert_eq!(report.events.len(), 1);
    assert_eq!(event_kind(&report.events[0]), "install.result");
}

#[derive(Debug, Clone, Copy)]
struct FailingBridge;

impl ModuleBridge for FailingBridge {
    fn call(&self, method: &str, _payload: &[u8]) -> Result<Vec<u8>, String> {
        Err(format!("bridge must not be called: {method}"))
    }
}

#[test]
fn download_install_api_share_the_authoritative_core_db() {
    let dir = TempDir::new("shared");
    let apk = dir.path().join("app.apk");
    std::fs::write(&apk, b"PK\x03\x04fake apk").expect("write apk");
    let dest = apk.to_string_lossy().into_owned();
    let conn = core_conn();
    insert_task(&conn, "task-1", &dest, "completed", "none", None, true);

    let download = DownloadApi::from_port_for_test(HostDownloadPort::with_bridge_for_test(
        FailingBridge,
        conn.clone(),
        dir.path().join("core.db"),
        None,
    ));
    let rows = download.list().expect("download list is bridge-free");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].module_task_id.as_deref(), Some("task-1"));

    let install = InstallApi::from_service_for_test(InstallService::new(
        conn,
        Arc::new(FakeInstaller::enabled(installed(
            "com.example.one",
            "1.2.3",
        ))),
    ));
    let attempt = install.install("task-1".to_string()).expect("install");
    assert_eq!(attempt.record.status, "installed");
    assert_eq!(download.list().expect("download list again").len(), 1);
}
