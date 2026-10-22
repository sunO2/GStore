//! Todo 4 contract: Android installer port mapping, durable result store,
//! idempotency, process-death recovery, and typed failures.
//!
//! Everything is scripted through the [`InstallerJni`] seam; no device or JNI VM
//! is required.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use gstore_core::ports::installer::{InstallMethod, InstallOutcome, InstallerPort};
use gstore_core::Error;
use gstore_host::installer_host::{
    accepted_result_count, ignored_result_count, record_install_result, reset_result_store,
    AndroidInstallerPort, InstallerJni,
};

/// The result store is process-global, so these tests serialise themselves.
static TEST_LOCK: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[derive(Default)]
struct FakeState {
    can: AtomicBool,
    uninstall_ok: AtomicBool,
    launch_ok: AtomicBool,
    install_json: Mutex<Option<String>>,
    query_json: Mutex<Option<String>>,
    query_error: Mutex<Option<String>>,
    install_calls: AtomicUsize,
    query_calls: AtomicUsize,
    uninstall_calls: AtomicUsize,
    launch_calls: AtomicUsize,
}

#[derive(Clone)]
struct FakeBridge {
    state: Arc<FakeState>,
}

impl FakeBridge {
    fn new() -> Self {
        Self {
            state: Arc::new(FakeState {
                can: AtomicBool::new(true),
                uninstall_ok: AtomicBool::new(true),
                launch_ok: AtomicBool::new(true),
                ..FakeState::default()
            }),
        }
    }

    fn set_install_json(&self, json: &str) {
        *self
            .state
            .install_json
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(json.to_string());
    }

    fn set_query_json(&self, json: &str) {
        *self
            .state
            .query_json
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(json.to_string());
    }

    fn set_uninstall_ok(&self, value: bool) {
        self.state.uninstall_ok.store(value, Ordering::SeqCst);
    }

    fn set_launch_ok(&self, value: bool) {
        self.state.launch_ok.store(value, Ordering::SeqCst);
    }

    fn query_calls(&self) -> usize {
        self.state.query_calls.load(Ordering::SeqCst)
    }
}

impl InstallerJni for FakeBridge {
    fn can_install(&self) -> Result<bool, String> {
        Ok(self.state.can.load(Ordering::SeqCst))
    }

    fn install(&self, _apk_path: &str, _session_id: &str) -> Result<String, String> {
        self.state.install_calls.fetch_add(1, Ordering::SeqCst);
        self.state
            .install_json
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
            .ok_or_else(|| "no scripted install payload".to_string())
    }

    fn uninstall(&self, _package_name: &str) -> Result<bool, String> {
        self.state.uninstall_calls.fetch_add(1, Ordering::SeqCst);
        Ok(self.state.uninstall_ok.load(Ordering::SeqCst))
    }

    fn launch(&self, _package_name: &str) -> Result<bool, String> {
        self.state.launch_calls.fetch_add(1, Ordering::SeqCst);
        Ok(self.state.launch_ok.load(Ordering::SeqCst))
    }

    fn query_result(&self, _session_id: &str) -> Result<Option<String>, String> {
        self.state.query_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(error) = self
            .state
            .query_error
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
        {
            return Err(error);
        }
        Ok(self
            .state
            .query_json
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone())
    }
}

fn installed_json(method: &str, package: &str, version: &str) -> String {
    format!(
        r#"{{"method":"{method}","status":"installed","packageName":"{package}","versionName":"{version}","error":null}}"#
    )
}

#[test]
fn installer_contract_maps_methods_and_statuses() {
    let _guard = serial();
    reset_result_store();

    let cases = [
        ("shizuku", "installed", InstallMethod::Shizuku),
        (
            "package_installer",
            "installed",
            InstallMethod::PackageInstaller,
        ),
        ("intent", "installed", InstallMethod::Intent),
    ];
    for (method, status, expected) in cases {
        let bridge = FakeBridge::new();
        bridge.set_install_json(&installed_json(method, "com.example.one", "1.2.3"));
        let port = AndroidInstallerPort::new(bridge);
        let ticket = port
            .begin_install(
                Path::new("/data/local/tmp/app.apk"),
                &format!("session-{method}"),
            )
            .expect("ticket");
        assert_eq!(ticket.method, expected);
        assert_eq!(
            ticket.outcome,
            Some(InstallOutcome::Installed {
                package_name: Some("com.example.one".to_string()),
                version_name: Some("1.2.3".to_string()),
            }),
            "status {status} should map to installed"
        );
    }

    let bridge = FakeBridge::new();
    bridge.set_install_json(
        r#"{"method":"package_installer","status":"pending","packageName":"com.example.pending","versionName":null,"error":null}"#,
    );
    let port = AndroidInstallerPort::new(bridge);
    let ticket = port
        .begin_install(Path::new("/data/local/tmp/app.apk"), "session-pending")
        .expect("pending ticket");
    assert_eq!(ticket.method, InstallMethod::PackageInstaller);
    assert_eq!(ticket.outcome, None);
}

#[test]
fn installer_contract_duplicate_result_is_idempotent_first_wins() {
    let _guard = serial();
    reset_result_store();

    let bridge = FakeBridge::new();
    bridge.set_install_json(
        r#"{"method":"package_installer","status":"pending","packageName":"com.example.dup","versionName":null,"error":null}"#,
    );
    let port = AndroidInstallerPort::new(bridge.clone());
    port.begin_install(Path::new("/tmp/app.apk"), "session-dup")
        .expect("pending");

    record_install_result(
        "session-dup",
        "installed",
        Some("com.example.dup"),
        Some("2.0.0"),
        None,
    );
    record_install_result("session-dup", "failed", None, None, Some("second report"));

    assert_eq!(accepted_result_count(), 1);
    assert_eq!(ignored_result_count(), 1);

    let first = port.install_result("session-dup").expect("first result");
    assert_eq!(
        first,
        Some(InstallOutcome::Installed {
            package_name: Some("com.example.dup".to_string()),
            version_name: Some("2.0.0".to_string()),
        })
    );
    // Drained once; the duplicate is still rejected and the bridge is not asked
    // to resurrect the terminal result.
    assert_eq!(
        port.install_result("session-dup").expect("second poll"),
        None
    );
    assert_eq!(bridge.query_calls(), 1);
}

#[test]
fn installer_contract_recovers_after_process_death() {
    let _guard = serial();
    reset_result_store();

    let bridge = FakeBridge::new();
    bridge.set_query_json(&installed_json(
        "package_installer",
        "com.example.recovered",
        "3.1.4",
    ));
    // Fresh port with an empty in-memory store; only the Kotlin bridge knows.
    let port = AndroidInstallerPort::new(bridge.clone());

    assert_eq!(
        port.install_result("session-after-death")
            .expect("recovery result"),
        Some(InstallOutcome::Installed {
            package_name: Some("com.example.recovered".to_string()),
            version_name: Some("3.1.4".to_string()),
        })
    );
    assert_eq!(bridge.query_calls(), 1);
}

#[test]
fn installer_contract_uninstall_and_launch_false_are_typed() {
    let _guard = serial();
    reset_result_store();

    let bridge = FakeBridge::new();
    bridge.set_uninstall_ok(false);
    bridge.set_launch_ok(false);
    let port = AndroidInstallerPort::new(bridge);

    assert!(matches!(
        port.uninstall("com.example.missing"),
        Err(Error::Forbidden(_))
    ));
    assert!(matches!(
        port.launch("com.example.missing"),
        Err(Error::NotFound(_))
    ));
}

#[test]
fn installer_contract_malformed_bridge_json_is_serialization() {
    let _guard = serial();
    reset_result_store();

    let bridge = FakeBridge::new();
    bridge.set_install_json("this is not json");
    let port = AndroidInstallerPort::new(bridge);
    let error = port
        .begin_install(Path::new("/tmp/app.apk"), "session-malformed")
        .expect_err("malformed payload must fail");
    match error {
        Error::Serialization(message) => assert!(message.contains("CORE_E_INSTALL_BRIDGE")),
        other => panic!("expected serialization error, got {other:?}"),
    }
}

#[test]
fn installer_contract_denied_and_timeout_carry_typed_codes() {
    let _guard = serial();
    reset_result_store();

    let bridge = FakeBridge::new();
    let port = AndroidInstallerPort::new(bridge);

    record_install_result(
        "session-unknown-sources",
        "denied",
        None,
        None,
        Some("CORE_E_INSTALL_UNKNOWN_SOURCES"),
    );
    match port
        .install_result("session-unknown-sources")
        .expect("denied result")
    {
        Some(InstallOutcome::Denied { message }) => {
            assert!(message.contains("CORE_E_INSTALL_UNKNOWN_SOURCES"));
        }
        other => panic!("expected denied outcome, got {other:?}"),
    }

    record_install_result(
        "session-user-rejected",
        "denied",
        None,
        None,
        Some("CORE_E_INSTALL_USER_REJECTED"),
    );
    match port
        .install_result("session-user-rejected")
        .expect("rejected result")
    {
        Some(InstallOutcome::Denied { message }) => {
            assert!(message.contains("CORE_E_INSTALL_USER_REJECTED"));
        }
        other => panic!("expected denied outcome, got {other:?}"),
    }

    record_install_result(
        "session-timeout",
        "timeout",
        None,
        None,
        Some("CORE_E_INSTALL_TIMEOUT: 120s"),
    );
    match port
        .install_result("session-timeout")
        .expect("timeout result")
    {
        Some(InstallOutcome::Timeout { message }) => {
            assert_eq!(message.as_deref(), Some("CORE_E_INSTALL_TIMEOUT: 120s"));
        }
        other => panic!("expected timeout outcome, got {other:?}"),
    }
}

#[test]
fn installer_contract_pending_sessions_track_store() {
    let _guard = serial();
    reset_result_store();

    let bridge = FakeBridge::new();
    bridge.set_install_json(
        r#"{"method":"intent","status":"pending","packageName":"com.example.pending","versionName":null,"error":null}"#,
    );
    let port = AndroidInstallerPort::new(bridge);
    port.begin_install(Path::new("/tmp/app.apk"), "session-tracked")
        .expect("pending");
    assert_eq!(
        port.pending_sessions().expect("pending sessions"),
        vec!["session-tracked".to_string()]
    );
}

#[test]
fn installer_contract_drained_result_clears_stale_pending_marker() {
    let _guard = serial();
    reset_result_store();

    let bridge = FakeBridge::new();
    bridge.set_install_json(
        r#"{"method":"package_installer","status":"pending","packageName":"com.example.drain","versionName":null,"error":null}"#,
    );
    let port = AndroidInstallerPort::new(bridge);

    port.begin_install(Path::new("/tmp/app.apk"), "session-drain")
        .expect("first pending");
    record_install_result(
        "session-drain",
        "installed",
        Some("com.example.drain"),
        Some("4.0.0"),
        None,
    );
    // Simulate the callback-before-`begin_install`-returns race: the pending
    // marker is re-added after a terminal result is already stored.
    port.begin_install(Path::new("/tmp/app.apk"), "session-drain")
        .expect("race pending");
    assert_eq!(
        port.pending_sessions().expect("stale pending"),
        vec!["session-drain".to_string()]
    );

    assert_eq!(
        port.install_result("session-drain").expect("drain result"),
        Some(InstallOutcome::Installed {
            package_name: Some("com.example.drain".to_string()),
            version_name: Some("4.0.0".to_string()),
        })
    );
    assert!(
        port.pending_sessions()
            .expect("pending after drain")
            .is_empty(),
        "draining a terminal result must clear the pending marker"
    );
}
