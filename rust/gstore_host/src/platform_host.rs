//! Real Android [`PlatformHost`] over the Kotlin `PlatformHostBridge`.
//!
//! Kotlin performs every `PackageManager` lookup and returns JSON; this module
//! only invokes the static bridge methods, parses the payloads into the core
//! DTOs, and keeps a package cache. All failure paths are typed and exception
//! free at the JNI boundary.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{OnceLock, RwLock};

use gstore_core::ports::platform::{
    AppComponents, AppSignature, Capability, CapabilitySet, Connectivity, DeviceInfo, InstalledApp,
    Notification, PlatformHost, StoragePaths,
};
use gstore_core::Error;
use jni::objects::{GlobalRef, JObject, JString, JValue};
use jni::JNIEnv;

use crate::installer_host::{InstallerJni, JniInstallerBridge};
use crate::jni_bridge::{platform_context, platform_jvm};
use crate::notification_host::host_notification_sink;

const PLATFORM_CLASS_NAME: &str = "com/suno2/gstore/PlatformHostBridge";
const NOT_INITIALIZED: &str = "CORE_E_PLATFORM_NOT_INITIALIZED";
const INVENTORY_DENIED: &str = "CORE_E_PACKAGE_INVENTORY_DENIED";

static PLATFORM_CLASS: OnceLock<GlobalRef> = OnceLock::new();

/// In-memory package cache used by [`AndroidPlatformHost`].
#[derive(Debug, Default)]
pub struct InventoryCache {
    entries: BTreeMap<String, InstalledApp>,
}

impl InventoryCache {
    /// Creates an empty cache.
    pub fn new() -> Self {
        Self::default()
    }

    /// Inserts or replaces one package.
    pub fn insert(&mut self, app: InstalledApp) {
        self.entries.insert(app.package_name.clone(), app);
    }

    /// Looks up one package.
    pub fn get(&self, package_name: &str) -> Option<&InstalledApp> {
        self.entries.get(package_name)
    }

    /// Number of cached packages.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the cache is empty.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Drops every cached package.
    pub fn invalidate(&mut self) {
        self.entries.clear();
    }
}

fn cache() -> &'static RwLock<InventoryCache> {
    static CACHE: OnceLock<RwLock<InventoryCache>> = OnceLock::new();
    CACHE.get_or_init(|| RwLock::new(InventoryCache::new()))
}

/// Clears the global package cache. Called from the Kotlin package broadcast
/// receiver through `nativeInvalidateInventory`.
pub fn invalidate_cache() {
    cache()
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .invalidate();
}

/// Number of packages currently cached (observable for contract tests).
#[doc(hidden)]
pub fn cached_package_count() -> usize {
    cache()
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .len()
}

/// Parses the installed-application list payload.
///
/// # Errors
/// Returns [`Error::Serialization`] when `json` is malformed.
pub fn parse_installed_apps(json: &str) -> Result<Vec<InstalledApp>, Error> {
    serde_json::from_str(json).map_err(Error::from)
}

/// Parses a single installed-application payload.
///
/// # Errors
/// Returns [`Error::Serialization`] when `json` is malformed.
pub fn parse_installed_app(json: &str) -> Result<InstalledApp, Error> {
    serde_json::from_str(json).map_err(Error::from)
}

/// Decodes an optional single-application payload; `None` means the package
/// was removed between the list and the get (Kotlin returns `null`).
///
/// # Errors
/// Returns [`Error::Serialization`] when a present `json` is malformed.
pub fn decode_optional_installed_app(json: Option<&str>) -> Result<Option<InstalledApp>, Error> {
    match json {
        Some(json) => parse_installed_app(json).map(Some),
        None => Ok(None),
    }
}

/// Parses a signing-certificate array payload.
///
/// # Errors
/// Returns [`Error::Serialization`] when `json` is malformed.
pub fn parse_signatures(json: &str) -> Result<Vec<AppSignature>, Error> {
    serde_json::from_str(json).map_err(Error::from)
}

/// Parses a requested-permission array payload.
///
/// # Errors
/// Returns [`Error::Serialization`] when `json` is malformed.
pub fn parse_permissions(json: &str) -> Result<Vec<String>, Error> {
    serde_json::from_str(json).map_err(Error::from)
}

/// Parses a components/permission-state payload.
///
/// # Errors
/// Returns [`Error::Serialization`] when `json` is malformed.
pub fn parse_components(json: &str) -> Result<AppComponents, Error> {
    serde_json::from_str(json).map_err(Error::from)
}

/// Parses a device-information payload.
///
/// # Errors
/// Returns [`Error::Serialization`] when `json` is malformed.
pub fn parse_device_info(json: &str) -> Result<DeviceInfo, Error> {
    serde_json::from_str(json).map_err(Error::from)
}

/// Whether a JNI failure message reports an inventory visibility denial.
pub fn is_inventory_denied(message: &str) -> bool {
    let probe = message.to_ascii_lowercase();
    message.contains(INVENTORY_DENIED)
        || probe.contains("securityexception")
        || probe.contains("permission denial")
        || probe.contains("not allowed to")
        || probe.contains("visibility")
}

fn name_not_found(message: &str) -> bool {
    message.contains("NameNotFoundException")
}

/// Maps a JNI failure message to the stable host error contract.
pub fn map_inventory_jni_error(message: &str) -> Error {
    if is_inventory_denied(message) {
        Error::Forbidden(format!("{INVENTORY_DENIED}: {message}"))
    } else if name_not_found(message) {
        Error::NotFound(format!("package not found: {message}"))
    } else {
        Error::Internal(format!("platform inventory JNI failure: {message}"))
    }
}

/// Resolves and caches the Kotlin bridge class on the app thread.
pub(crate) fn init_class(env: &mut JNIEnv) {
    if PLATFORM_CLASS.get().is_some() {
        return;
    }
    match env.find_class(PLATFORM_CLASS_NAME) {
        Ok(class) => match env.new_global_ref(&class) {
            Ok(global) => {
                let _ = PLATFORM_CLASS.set(global);
                crate::log_bridge::push_host_log(
                    1,
                    "PlatformHostBridge: 已缓存类引用（JNI 包清单就绪）".to_string(),
                );
            }
            Err(error) => {
                crate::log_bridge::push_host_log(
                    3,
                    format!("PlatformHostBridge: 类 GlobalRef 失败: {error}"),
                );
            }
        },
        Err(error) => {
            let _ = env.exception_clear();
            crate::log_bridge::push_host_log(
                3,
                format!("PlatformHostBridge: find_class 失败: {error}"),
            );
        }
    }
}

fn not_initialized() -> Error {
    Error::Unsupported(NOT_INITIALIZED.to_string())
}

fn describe_exception(env: &mut JNIEnv) -> String {
    let Ok(throwable) = env.exception_occurred() else {
        return String::new();
    };
    env.exception_clear().ok();
    let throwable = JObject::from(throwable);
    let Ok(value) = env.call_method(&throwable, "toString", "()Ljava/lang/String;", &[]) else {
        let _ = env.exception_clear();
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

fn call_bridge(method: &str, package_name: Option<&str>) -> Result<Option<String>, Error> {
    let jvm = platform_jvm().ok_or_else(not_initialized)?;
    let class = PLATFORM_CLASS.get().ok_or_else(not_initialized)?;
    if platform_context().is_none() {
        return Err(not_initialized());
    }
    let mut env = jvm
        .attach_current_thread()
        .map_err(|error| Error::Internal(format!("platform inventory JNI attach: {error}")))?;

    let value = match package_name {
        Some(package_name) => {
            let jpackage = env
                .new_string(package_name)
                .map_err(|error| Error::Internal(format!("platform inventory package: {error}")))?;
            let package_object = JObject::from(jpackage);
            env.call_static_method(
                class,
                method,
                "(Ljava/lang/String;)Ljava/lang/String;",
                &[JValue::Object(&package_object)],
            )
        }
        None => env.call_static_method(class, method, "()Ljava/lang/String;", &[]),
    };

    let value = match value {
        Ok(value) => value,
        Err(error) => {
            let message = describe_exception(&mut env);
            let detail = if message.is_empty() {
                error.to_string()
            } else {
                message
            };
            if name_not_found(&detail) {
                return Ok(None);
            }
            return Err(map_inventory_jni_error(&detail));
        }
    };

    if env.exception_check().unwrap_or(false) {
        let message = describe_exception(&mut env);
        if name_not_found(&message) {
            return Ok(None);
        }
        return Err(map_inventory_jni_error(&message));
    }

    let object = value
        .l()
        .map_err(|error| Error::Internal(format!("platform inventory value: {error}")))?;
    if object.is_null() {
        return Ok(None);
    }
    let text: JString = object.into();
    let parsed = env
        .get_string(&text)
        .map_err(|error| Error::Internal(format!("platform inventory string: {error}")))?;
    Ok(Some(parsed.into()))
}

fn unsupported(operation: &str) -> Error {
    Error::Unsupported(format!("platform capability unavailable: {operation}"))
}

/// Compatibility adapter for the legacy [`Capability::Install`] surface.
///
/// `InstallService` + `InstallerPort` remains the sole orchestration path (the
/// database owns the durable session). This adapter only preserves the old
/// capability promise for callers that still invoke `PlatformHost::install`.
fn install_via_bridge(apk_path: &Path) -> Result<(), Error> {
    let session = format!("platform:{}", crate::notification_host::now_ms());
    let path = apk_path.to_string_lossy();
    let raw = JniInstallerBridge
        .install(&path, &session)
        .map_err(|error| Error::Internal(format!("CORE_E_INSTALL_BRIDGE: install: {error}")))?;
    let parsed: serde_json::Value = serde_json::from_str(&raw)
        .map_err(|error| Error::Internal(format!("CORE_E_INSTALL_BRIDGE: malformed: {error}")))?;
    let status = parsed
        .get("status")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            Error::Internal("CORE_E_INSTALL_BRIDGE: missing install status".to_string())
        })?;
    let detail = parsed
        .get("error")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("CORE_E_INSTALL_FAILED");
    match status {
        "installed" => Ok(()),
        "denied" => Err(Error::Forbidden(detail.to_string())),
        "pending" => Err(Error::Unsupported(
            "CORE_E_PLATFORM_INSTALL_PENDING: use InstallerPort".to_string(),
        )),
        "failed" => Err(Error::Internal(detail.to_string())),
        other => Err(Error::Internal(format!(
            "CORE_E_INSTALL_BRIDGE: unknown install status: {other}"
        ))),
    }
}

/// Android host backed by `com.suno2.gstore.PlatformHostBridge`.
#[derive(Debug, Clone, Copy, Default)]
#[flutter_rust_bridge::frb(opaque)]
pub struct AndroidPlatformHost;

impl AndroidPlatformHost {
    /// Creates the host.
    pub const fn new() -> Self {
        Self
    }
}

impl PlatformHost for AndroidPlatformHost {
    fn capabilities(&self) -> CapabilitySet {
        CapabilitySet::from_caps([
            Capability::Inventory,
            Capability::DeviceInfo,
            Capability::Install,
            Capability::Uninstall,
            Capability::Launch,
            Capability::Notify,
            Capability::ForegroundService,
        ])
    }

    fn list_installed_unchecked(&self) -> Result<Vec<InstalledApp>, Error> {
        let Some(json) = call_bridge("listInstalledJson", None)? else {
            return Ok(Vec::new());
        };
        let apps = parse_installed_apps(&json)?;
        let mut guard = cache()
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.invalidate();
        for app in &apps {
            guard.insert(app.clone());
        }
        Ok(apps)
    }

    fn get_installed_unchecked(&self, package_name: &str) -> Result<Option<InstalledApp>, Error> {
        if let Some(app) = cache()
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(package_name)
            .cloned()
        {
            return Ok(Some(app));
        }
        let Some(json) = call_bridge("getInstalledJson", Some(package_name))? else {
            return Ok(None);
        };
        let Some(app) = decode_optional_installed_app(Some(&json))? else {
            return Ok(None);
        };
        cache()
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(app.clone());
        Ok(Some(app))
    }

    fn is_installed_unchecked(&self, package_name: &str) -> Result<bool, Error> {
        Ok(self.get_installed_unchecked(package_name)?.is_some())
    }

    fn get_source_dir_unchecked(&self, package_name: &str) -> Result<Option<String>, Error> {
        call_bridge("getSourceDir", Some(package_name))
    }

    fn get_signatures_unchecked(&self, package_name: &str) -> Result<Vec<AppSignature>, Error> {
        let Some(json) = call_bridge("getSignaturesJson", Some(package_name))? else {
            return Ok(Vec::new());
        };
        parse_signatures(&json)
    }

    fn get_permissions_unchecked(&self, package_name: &str) -> Result<Vec<String>, Error> {
        let Some(json) = call_bridge("getPermissionsJson", Some(package_name))? else {
            return Ok(Vec::new());
        };
        parse_permissions(&json)
    }

    fn get_components_unchecked(&self, package_name: &str) -> Result<AppComponents, Error> {
        let Some(json) = call_bridge("getComponentsJson", Some(package_name))? else {
            return Ok(AppComponents {
                components: Vec::new(),
                permission_states: Vec::new(),
            });
        };
        parse_components(&json)
    }

    fn device_info_unchecked(&self) -> Result<DeviceInfo, Error> {
        let Some(json) = call_bridge("deviceInfoJson", None)? else {
            return Err(Error::Internal(
                "platform inventory: empty device info payload".to_string(),
            ));
        };
        parse_device_info(&json)
    }

    fn install_unchecked(&self, apk_path: &Path) -> Result<(), Error> {
        install_via_bridge(apk_path)
    }

    fn uninstall_unchecked(&self, package_name: &str) -> Result<(), Error> {
        match JniInstallerBridge.uninstall(package_name) {
            Ok(true) => Ok(()),
            Ok(false) => Err(Error::Forbidden(format!(
                "CORE_E_INSTALL_UNINSTALL: {package_name}"
            ))),
            Err(error) => Err(Error::Internal(format!(
                "CORE_E_INSTALL_BRIDGE: uninstall: {error}"
            ))),
        }
    }

    fn launch_unchecked(&self, package_name: &str) -> Result<(), Error> {
        match JniInstallerBridge.launch(package_name) {
            Ok(true) => Ok(()),
            Ok(false) => Err(Error::NotFound(format!(
                "CORE_E_INSTALL_LAUNCH: {package_name}"
            ))),
            Err(error) => Err(Error::Internal(format!(
                "CORE_E_INSTALL_BRIDGE: launch: {error}"
            ))),
        }
    }

    fn notify_unchecked(&self, notification: &Notification) -> Result<(), Error> {
        host_notification_sink().notify(notification)
    }

    fn start_foreground_unchecked(&self, notification: &Notification) -> Result<(), Error> {
        host_notification_sink().start_foreground(notification)
    }

    fn stop_foreground_unchecked(&self) -> Result<(), Error> {
        host_notification_sink().stop_foreground()
    }

    fn storage_paths_unchecked(&self) -> Result<StoragePaths, Error> {
        Err(unsupported("storage_paths"))
    }

    fn connectivity_unchecked(&self) -> Result<Connectivity, Error> {
        Err(unsupported("connectivity"))
    }

    fn is_online_unchecked(&self) -> Result<bool, Error> {
        Err(unsupported("connectivity"))
    }

    fn secret_get_unchecked(&self, _key: &str) -> Result<Option<String>, Error> {
        Err(unsupported("secrets"))
    }

    fn secret_set_unchecked(&self, _key: &str, _value: &str) -> Result<(), Error> {
        Err(unsupported("secrets"))
    }

    fn secret_remove_unchecked(&self, _key: &str) -> Result<bool, Error> {
        Err(unsupported("secrets"))
    }

    fn secret_list_unchecked(&self) -> Result<Vec<String>, Error> {
        Err(unsupported("secrets"))
    }
}
