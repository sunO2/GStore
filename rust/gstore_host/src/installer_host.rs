//! Android [`InstallerPort`] over the Kotlin `InstallerBridge`.
//!
//! Kotlin owns the platform work (Shizuku, `PackageInstaller`, system intent)
//! and returns a stable JSON object. This module parses that payload, keeps the
//! short-lived result store used by the native install callback, and exposes the
//! seam tests use ([`InstallerJni`]) so no contract test needs a device.
//!
//! The database remains the durable authority: [`InstallService`] persists the
//! session id before an install starts and reconciles it through this port.
//!
//! [`InstallService`]: gstore_core::install::InstallService

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use gstore_core::ports::installer::{InstallMethod, InstallOutcome, InstallTicket, InstallerPort};
use gstore_core::Error;
use jni::objects::{GlobalRef, JClass, JObject, JString, JValue};
use jni::JNIEnv;
use serde::Deserialize;

use crate::jni_bridge::{platform_context, platform_jvm};

const INSTALLER_CLASS_NAME: &str = "com/suno2/gstore/InstallerBridge";
const BRIDGE_ERROR: &str = "CORE_E_INSTALL_BRIDGE";
const NOT_INITIALIZED: &str = "CORE_E_INSTALL_BRIDGE: InstallerBridge not initialized";

const CAN_INSTALL_SIG: &str = "()Z";
const INSTALL_SIG: &str = "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;";
const PACKAGE_SIG: &str = "(Ljava/lang/String;)Z";
const QUERY_SIG: &str = "(Ljava/lang/String;)Ljava/lang/String;";

/// JNI seam used by [`AndroidInstallerPort`]; tests script it without a device.
pub trait InstallerJni: Send + Sync {
    /// Whether the host can install packages.
    fn can_install(&self) -> Result<bool, String>;
    /// Starts an install and returns the Kotlin JSON payload.
    fn install(&self, apk_path: &str, session_id: &str) -> Result<String, String>;
    /// Uninstalls a package.
    fn uninstall(&self, package_name: &str) -> Result<bool, String>;
    /// Launches a package.
    fn launch(&self, package_name: &str) -> Result<bool, String>;
    /// Recovers a session result after process death (`None` = unknown).
    fn query_result(&self, session_id: &str) -> Result<Option<String>, String>;
}

/// Cached `InstallerBridge` class (captured on the app thread during
/// `RegisterNatives` so later Rust threads do not need the app class loader).
static INSTALLER_CLASS: OnceLock<GlobalRef> = OnceLock::new();

/// Caches the Kotlin bridge class exactly once.
pub(crate) fn cache_installer_class(
    env: &mut JNIEnv,
    class: &JClass,
) -> Option<&'static GlobalRef> {
    if let Some(cached) = INSTALLER_CLASS.get() {
        return Some(cached);
    }
    let global = env.new_global_ref(class).ok()?;
    let _ = INSTALLER_CLASS.set(global);
    INSTALLER_CLASS.get()
}

fn clear_exception(env: &mut JNIEnv) {
    if env.exception_check().unwrap_or(false) {
        env.exception_describe().ok();
        env.exception_clear().ok();
    }
}

fn describe_exception(env: &mut JNIEnv) -> String {
    let Ok(throwable) = env.exception_occurred() else {
        return String::new();
    };
    env.exception_clear().ok();
    let throwable = JObject::from(throwable);
    let Ok(value) = env.call_method(&throwable, "toString", "()Ljava/lang/String;", &[]) else {
        clear_exception(env);
        return String::new();
    };
    let Ok(object) = value.l() else {
        return String::new();
    };
    if object.is_null() {
        return String::new();
    }
    let text: JString = object.into();
    env.get_string(&text)
        .map(std::convert::Into::into)
        .unwrap_or_default()
}

fn installer_class(env: &mut JNIEnv) -> Result<&'static GlobalRef, String> {
    if let Some(cached) = INSTALLER_CLASS.get() {
        return Ok(cached);
    }
    let class = match env.find_class(INSTALLER_CLASS_NAME) {
        Ok(class) => class,
        Err(error) => {
            let detail = describe_exception(env);
            clear_exception(env);
            let message = if detail.is_empty() {
                error.to_string()
            } else {
                detail
            };
            return Err(format!(
                "{BRIDGE_ERROR}: find {INSTALLER_CLASS_NAME}: {message}"
            ));
        }
    };
    cache_installer_class(env, &class)
        .ok_or_else(|| format!("{BRIDGE_ERROR}: cache {INSTALLER_CLASS_NAME}"))
}

fn jstring_value(env: &mut JNIEnv, object: JObject) -> Result<Option<String>, String> {
    if object.is_null() {
        return Ok(None);
    }
    let text: JString = object.into();
    env.get_string(&text)
        .map(|value| Some(value.into()))
        .map_err(|error| format!("{BRIDGE_ERROR}: JNI string: {error}"))
}

/// Real bridge: invokes the Kotlin `com.suno2.gstore.InstallerBridge` statics.
///
/// Every failure is returned as a typed `Err(String)`; nothing panics across
/// the JNI boundary.
#[derive(Debug, Clone, Copy, Default)]
pub struct JniInstallerBridge;

impl JniInstallerBridge {
    /// Creates the bridge.
    pub const fn new() -> Self {
        Self
    }

    fn with_env<T>(
        operation: &str,
        body: impl FnOnce(&mut JNIEnv, &GlobalRef) -> Result<T, String>,
    ) -> Result<T, String> {
        if platform_context().is_none() {
            return Err(NOT_INITIALIZED.to_string());
        }
        let jvm = platform_jvm().ok_or_else(|| NOT_INITIALIZED.to_string())?;
        let mut env = jvm
            .attach_current_thread()
            .map_err(|error| format!("{BRIDGE_ERROR}: {operation}: JNI attach: {error}"))?;
        let class = installer_class(&mut env)?;
        let result = body(&mut env, class);
        clear_exception(&mut env);
        result
    }

    fn call_bool(operation: &str, method: &str, package_name: &str) -> Result<bool, String> {
        Self::with_env(operation, |env, class| {
            let argument = env
                .new_string(package_name)
                .map_err(|error| format!("{BRIDGE_ERROR}: {operation}: argument: {error}"))?;
            let argument = JObject::from(argument);
            let value = env
                .call_static_method(class, method, PACKAGE_SIG, &[JValue::Object(&argument)])
                .map_err(|error| format!("{BRIDGE_ERROR}: {operation}: {error}"))?;
            value
                .z()
                .map_err(|error| format!("{BRIDGE_ERROR}: {operation}: return type: {error}"))
        })
    }

    fn call_string(
        operation: &str,
        method: &str,
        signature: &str,
        arguments: &[&str],
    ) -> Result<Option<String>, String> {
        Self::with_env(operation, |env, class| {
            let mut owned = Vec::with_capacity(arguments.len());
            for argument in arguments {
                owned.push(JObject::from(env.new_string(argument).map_err(
                    |error| format!("{BRIDGE_ERROR}: {operation}: argument: {error}"),
                )?));
            }
            let values: Vec<JValue<'_, '_>> = owned.iter().map(JValue::Object).collect();
            let value = env
                .call_static_method(class, method, signature, &values)
                .map_err(|error| format!("{BRIDGE_ERROR}: {operation}: {error}"))?;
            let object = value
                .l()
                .map_err(|error| format!("{BRIDGE_ERROR}: {operation}: JNI value: {error}"))?;
            jstring_value(env, object)
        })
    }
}

impl InstallerJni for JniInstallerBridge {
    fn can_install(&self) -> Result<bool, String> {
        Self::with_env("canInstall", |env, class| {
            let value = env
                .call_static_method(class, "canInstall", CAN_INSTALL_SIG, &[])
                .map_err(|error| format!("{BRIDGE_ERROR}: canInstall: {error}"))?;
            value
                .z()
                .map_err(|error| format!("{BRIDGE_ERROR}: canInstall: return type: {error}"))
        })
    }

    fn install(&self, apk_path: &str, session_id: &str) -> Result<String, String> {
        Self::call_string("install", "install", INSTALL_SIG, &[apk_path, session_id])?
            .ok_or_else(|| format!("{BRIDGE_ERROR}: install returned null"))
    }

    fn uninstall(&self, package_name: &str) -> Result<bool, String> {
        Self::call_bool("uninstall", "uninstall", package_name)
    }

    fn launch(&self, package_name: &str) -> Result<bool, String> {
        Self::call_bool("launch", "launch", package_name)
    }

    fn query_result(&self, session_id: &str) -> Result<Option<String>, String> {
        Self::call_string(
            "queryInstallResult",
            "queryInstallResult",
            QUERY_SIG,
            &[session_id],
        )
    }
}

/// Stable Kotlin payload shape.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BridgeResult {
    method: String,
    status: String,
    #[serde(default)]
    package_name: Option<String>,
    #[serde(default)]
    version_name: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

fn serialization(message: impl Into<String>) -> Error {
    Error::Serialization(format!("{BRIDGE_ERROR}: {}", message.into()))
}

fn parse_method(method: &str) -> Result<InstallMethod, Error> {
    InstallMethod::from_id(method).map_err(|_| serialization(format!("unknown method: {method}")))
}

fn outcome_from(
    status: &str,
    package_name: Option<&str>,
    version_name: Option<&str>,
    error: Option<&str>,
) -> Result<Option<InstallOutcome>, Error> {
    match status {
        "pending" => Ok(None),
        "installed" => Ok(Some(InstallOutcome::Installed {
            package_name: package_name.map(str::to_string),
            version_name: version_name.map(str::to_string),
        })),
        "denied" => Ok(Some(InstallOutcome::Denied {
            message: error.unwrap_or("CORE_E_INSTALL_DENIED").to_string(),
        })),
        "timeout" => Ok(Some(InstallOutcome::Timeout {
            message: Some(error.unwrap_or("CORE_E_INSTALL_TIMEOUT").to_string()),
        })),
        "failed" => Ok(Some(InstallOutcome::Failed {
            message: error.unwrap_or("CORE_E_INSTALL_FAILED").to_string(),
        })),
        other => Err(serialization(format!("unknown status: {other}"))),
    }
}

/// Parses one stable bridge payload into a ticket.
///
/// # Errors
/// [`Error::Serialization`] (message contains `CORE_E_INSTALL_BRIDGE`) when the
/// payload is malformed or carries an unknown method/status.
pub fn parse_install_ticket(json: &str) -> Result<InstallTicket, Error> {
    let parsed: BridgeResult = serde_json::from_str(json)
        .map_err(|error| serialization(format!("malformed payload: {error}")))?;
    let method = parse_method(&parsed.method)?;
    let outcome = outcome_from(
        &parsed.status,
        parsed.package_name.as_deref(),
        parsed.version_name.as_deref(),
        parsed.error.as_deref(),
    )?;
    Ok(InstallTicket { method, outcome })
}

#[derive(Debug, Clone)]
struct StoredResult {
    status: String,
    package_name: Option<String>,
    version_name: Option<String>,
    error: Option<String>,
}

#[derive(Debug, Default)]
struct ResultStore {
    /// Undrained terminal results.
    results: BTreeMap<String, StoredResult>,
    /// Sessions started but not terminal yet.
    pending: BTreeSet<String>,
    /// Sessions that already produced one terminal result (dedupe even after
    /// the result above was drained).
    terminal_seen: BTreeSet<String>,
    accepted: u64,
    ignored: u64,
}

fn store() -> &'static Mutex<ResultStore> {
    static STORE: OnceLock<Mutex<ResultStore>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(ResultStore::default()))
}

fn lock_store() -> std::sync::MutexGuard<'static, ResultStore> {
    store()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn terminal_status(status: &str) -> bool {
    matches!(status, "installed" | "denied" | "timeout" | "failed")
}

/// Records one native install callback.
///
/// Terminal statuses only; the first terminal result for a session wins and
/// later duplicates are ignored. Counters are observable for contract tests.
pub fn record_install_result(
    session_id: &str,
    status: &str,
    package_name: Option<&str>,
    version_name: Option<&str>,
    error: Option<&str>,
) {
    if session_id.trim().is_empty() || !terminal_status(status) {
        let mut guard = lock_store();
        guard.ignored += 1;
        return;
    }
    let mut guard = lock_store();
    if !guard.terminal_seen.insert(session_id.to_string()) {
        guard.ignored += 1;
        return;
    }
    guard.accepted += 1;
    guard.pending.remove(session_id);
    guard.results.insert(
        session_id.to_string(),
        StoredResult {
            status: status.to_string(),
            package_name: package_name.map(str::to_string),
            version_name: version_name.map(str::to_string),
            error: error.map(str::to_string),
        },
    );
}

/// Number of terminal results accepted from the native callback.
#[doc(hidden)]
pub fn accepted_result_count() -> u64 {
    lock_store().accepted
}

/// Number of duplicate/invalid native results ignored.
#[doc(hidden)]
pub fn ignored_result_count() -> u64 {
    lock_store().ignored
}

/// Clears the process-global result store (tests only).
#[doc(hidden)]
pub fn reset_result_store() {
    let mut guard = lock_store();
    guard.results.clear();
    guard.pending.clear();
    guard.terminal_seen.clear();
    guard.accepted = 0;
    guard.ignored = 0;
}

fn stored_outcome(stored: &StoredResult) -> InstallOutcome {
    match outcome_from(
        &stored.status,
        stored.package_name.as_deref(),
        stored.version_name.as_deref(),
        stored.error.as_deref(),
    ) {
        Ok(Some(outcome)) => outcome,
        // Defensive: `record_install_result` only stores terminal statuses.
        _ => InstallOutcome::Failed {
            message: stored
                .error
                .clone()
                .unwrap_or_else(|| "CORE_E_INSTALL_FAILED".to_string()),
        },
    }
}

/// Android installer backed by the Kotlin bridge.
#[derive(Debug, Clone, Copy, Default)]
pub struct AndroidInstallerPort<B: InstallerJni = JniInstallerBridge> {
    bridge: B,
}

impl<B: InstallerJni> AndroidInstallerPort<B> {
    /// Wraps a bridge implementation.
    pub fn new(bridge: B) -> Self {
        Self { bridge }
    }
}

impl<B: InstallerJni> InstallerPort for AndroidInstallerPort<B> {
    fn can_install(&self) -> bool {
        match self.bridge.can_install() {
            Ok(value) => value,
            Err(error) => {
                crate::log_bridge::push_host_log(
                    2,
                    format!("InstallerBridge.can_install 失败（视为不可用）: {error}"),
                );
                false
            }
        }
    }

    fn begin_install(&self, apk_path: &Path, session_id: &str) -> Result<InstallTicket, Error> {
        let path = apk_path.to_string_lossy();
        let json = self
            .bridge
            .install(&path, session_id)
            .map_err(|error| Error::Internal(format!("{BRIDGE_ERROR}: install: {error}")))?;
        let ticket = parse_install_ticket(&json)?;
        if ticket.outcome.is_none() {
            lock_store().pending.insert(session_id.to_string());
        }
        Ok(ticket)
    }

    fn install_result(&self, session_id: &str) -> Result<Option<InstallOutcome>, Error> {
        let stored = { lock_store().results.remove(session_id) };
        if let Some(stored) = stored {
            return Ok(Some(stored_outcome(&stored)));
        }
        let Some(json) = self
            .bridge
            .query_result(session_id)
            .map_err(|error| Error::Internal(format!("{BRIDGE_ERROR}: query: {error}")))?
        else {
            return Ok(None);
        };
        let ticket = parse_install_ticket(&json)?;
        let Some(outcome) = ticket.outcome else {
            return Ok(None);
        };
        let mut guard = lock_store();
        guard.pending.remove(session_id);
        if !guard.terminal_seen.insert(session_id.to_string()) {
            return Ok(None);
        }
        Ok(Some(outcome))
    }

    fn uninstall(&self, package_name: &str) -> Result<(), Error> {
        match self.bridge.uninstall(package_name) {
            Ok(true) => Ok(()),
            Ok(false) => Err(Error::Forbidden(format!(
                "CORE_E_INSTALL_UNINSTALL: {package_name}"
            ))),
            Err(error) => Err(Error::Internal(format!(
                "{BRIDGE_ERROR}: uninstall: {error}"
            ))),
        }
    }

    fn launch(&self, package_name: &str) -> Result<(), Error> {
        match self.bridge.launch(package_name) {
            Ok(true) => Ok(()),
            Ok(false) => Err(Error::NotFound(format!(
                "CORE_E_INSTALL_LAUNCH: {package_name}"
            ))),
            Err(error) => Err(Error::Internal(format!("{BRIDGE_ERROR}: launch: {error}"))),
        }
    }

    fn pending_sessions(&self) -> Result<Vec<String>, Error> {
        let guard = lock_store();
        let mut sessions: BTreeSet<String> = guard.pending.clone();
        sessions.extend(guard.results.keys().cloned());
        Ok(sessions.into_iter().collect())
    }
}
