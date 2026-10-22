//! Platform host capability contract (Todo 6).
//!
//! Android provides the real implementation through JNI (`gstore_host`). This
//! module only defines the portable, synchronous contract used by the drivers
//! and tests. Every capability-marked operation is gated here, before the
//! implementation hook runs: a missing capability is a typed
//! [`Error::Unsupported`], never a panic and never a silent success.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::Error;

/// A platform capability advertised by [`PlatformHost::capabilities`].
///
/// The stable string ids are part of the port contract (they are used by
/// diagnostics and future host bridges); do not rename them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    /// Enumerate / read installed applications.
    Inventory,
    /// Install an APK.
    Install,
    /// Uninstall an application.
    Uninstall,
    /// Launch an application.
    Launch,
    /// Post a user-visible notification.
    Notify,
    /// Start/stop the host foreground service.
    ForegroundService,
    /// Resolve application storage directories.
    StoragePaths,
    /// Read the current connectivity state.
    Connectivity,
    /// Read stable device information.
    DeviceInfo,
    /// Read/write secrets through the host secret store.
    Secrets,
}

impl Capability {
    /// Every capability known to this wave, in stable declaration order.
    pub const ALL: [Capability; 10] = [
        Capability::Inventory,
        Capability::Install,
        Capability::Uninstall,
        Capability::Launch,
        Capability::Notify,
        Capability::ForegroundService,
        Capability::StoragePaths,
        Capability::Connectivity,
        Capability::DeviceInfo,
        Capability::Secrets,
    ];

    /// Stable machine-readable id.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Inventory => "inventory",
            Self::Install => "install",
            Self::Uninstall => "uninstall",
            Self::Launch => "launch",
            Self::Notify => "notify",
            Self::ForegroundService => "foreground_service",
            Self::StoragePaths => "storage_paths",
            Self::Connectivity => "connectivity",
            Self::DeviceInfo => "device_info",
            Self::Secrets => "secrets",
        }
    }

    /// Parses a stable capability id.
    ///
    /// # Errors
    /// Returns [`Error::InvalidArgument`] for an unknown id.
    pub fn from_id(id: &str) -> Result<Self, Error> {
        match id {
            "inventory" => Ok(Self::Inventory),
            "install" => Ok(Self::Install),
            "uninstall" => Ok(Self::Uninstall),
            "launch" => Ok(Self::Launch),
            "notify" => Ok(Self::Notify),
            "foreground_service" => Ok(Self::ForegroundService),
            "storage_paths" => Ok(Self::StoragePaths),
            "connectivity" => Ok(Self::Connectivity),
            "device_info" => Ok(Self::DeviceInfo),
            "secrets" => Ok(Self::Secrets),
            other => Err(Error::InvalidArgument(format!(
                "unknown platform capability: {other}"
            ))),
        }
    }

    const fn bit(self) -> u64 {
        match self {
            Self::Inventory => 1 << 0,
            Self::Install => 1 << 1,
            Self::Uninstall => 1 << 2,
            Self::Launch => 1 << 3,
            Self::Notify => 1 << 4,
            Self::ForegroundService => 1 << 5,
            Self::StoragePaths => 1 << 6,
            Self::Connectivity => 1 << 7,
            Self::DeviceInfo => 1 << 8,
            Self::Secrets => 1 << 9,
        }
    }
}

impl std::fmt::Display for Capability {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Bitmap of capabilities advertised by a [`PlatformHost`].
///
/// Unset bits — and every bit whose capability id is unknown — answer `false`
/// from [`CapabilitySet::supports`], so the default is fail-closed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CapabilitySet(u64);

impl CapabilitySet {
    /// No capability advertised.
    pub const fn empty() -> Self {
        Self(0)
    }

    /// Every capability known to this wave.
    pub const fn all() -> Self {
        let mut bits = 0;
        let mut index = 0;
        while index < Capability::ALL.len() {
            bits |= Capability::ALL[index].bit();
            index += 1;
        }
        Self(bits)
    }

    /// Builds a set from typed capabilities.
    pub fn from_caps(caps: impl IntoIterator<Item = Capability>) -> Self {
        let mut set = Self::empty();
        for cap in caps {
            set.insert(cap);
        }
        set
    }

    /// Builds a set from stable capability ids.
    ///
    /// # Errors
    /// Returns [`Error::InvalidArgument`] for the first unknown id.
    pub fn from_ids<I, S>(ids: I) -> Result<Self, Error>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut set = Self::empty();
        for id in ids {
            set.insert(Capability::from_id(id.as_ref())?);
        }
        Ok(set)
    }

    /// Builds a set from raw bits, ignoring bits that are not known capabilities.
    pub const fn from_bits_truncate(bits: u64) -> Self {
        Self(bits & Self::all().0)
    }

    /// Raw bitmap.
    pub const fn bits(self) -> u64 {
        self.0
    }

    /// Whether the capability is present.
    pub const fn supports(&self, cap: Capability) -> bool {
        self.0 & cap.bit() != 0
    }

    /// Whether a capability id is known AND present.
    ///
    /// Unknown ids answer `false` instead of erroring: this is a probe, and a
    /// probe must fail closed.
    pub fn supports_id(&self, id: &str) -> bool {
        Capability::from_id(id).is_ok_and(|cap| self.supports(cap))
    }

    /// Adds a capability.
    pub fn insert(&mut self, cap: Capability) {
        self.0 |= cap.bit();
    }

    /// Removes a capability.
    pub fn remove(&mut self, cap: Capability) {
        self.0 &= !cap.bit();
    }

    /// Builder-style [`CapabilitySet::insert`].
    #[must_use]
    pub const fn with(mut self, cap: Capability) -> Self {
        self.0 |= cap.bit();
        self
    }

    /// Iterates the present capabilities in declaration order.
    pub fn iter(self) -> impl Iterator<Item = Capability> {
        Capability::ALL
            .into_iter()
            .filter(move |cap| self.supports(*cap))
    }

    /// Whether no capability is present.
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }
}

/// One installed application as reported by the host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstalledApp {
    /// Android package name.
    pub package_name: String,
    /// User-visible application name.
    pub app_name: String,
    /// Version name (`versionName`).
    pub version_name: String,
    /// Monotonic version code.
    pub version_code: i64,
    /// Icon URI or resource reference, when known.
    pub icon: Option<String>,
    /// Whether this is a system application.
    pub system: bool,
}

/// One signing certificate attached to an installed application.
///
/// `kind` is `signer` (co-signer), `current`, or `history` (rotation history),
/// mirroring the Android signing-info contract.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppSignature {
    /// Certificate signature algorithm (for example `SHA256withRSA`).
    pub algorithm: String,
    /// Certificate subject distinguished name.
    pub subject: String,
    /// Colon-separated uppercase/lowercase hex SHA-256 digest.
    pub sha256: String,
    /// Colon-separated hex SHA-1 digest.
    pub sha1: String,
    /// `signer` / `current` / `history`.
    pub kind: String,
}

/// One Android manifest component of an installed application.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppComponent {
    /// `ACTIVITY` / `SERVICE` / `RECEIVER` / `PROVIDER`.
    pub kind: String,
    /// Fully-qualified component class name.
    pub name: String,
    /// Whether the component is exported.
    pub exported: bool,
    /// Whether the component is enabled.
    pub enabled: bool,
    /// Declared process name, when the host reports one.
    pub process_name: Option<String>,
}

/// Requested-permission state for an installed application.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppPermissionState {
    /// Android permission name.
    pub name: String,
    /// Whether the permission is currently granted.
    pub granted: bool,
    /// Whether the app declared `neverForLocation`.
    pub never_for_location: bool,
}

/// Component and permission inventory for one installed application.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppComponents {
    /// Manifest components (activities, services, receivers, providers).
    pub components: Vec<AppComponent>,
    /// Requested-permission states.
    pub permission_states: Vec<AppPermissionState>,
}

/// Notification payload accepted by [`PlatformHost::notify`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notification {
    /// Android notification channel id.
    pub channel_id: String,
    /// Notification title.
    pub title: String,
    /// Notification body.
    pub body: String,
}

/// Application storage directories resolved by the host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoragePaths {
    /// Private data directory (`Context.getDataDir`).
    pub data_dir: PathBuf,
    /// Private cache directory.
    pub cache_dir: PathBuf,
    /// Private files directory.
    pub files_dir: PathBuf,
    /// External files directory, when mounted.
    pub external_files_dir: Option<PathBuf>,
}

/// Coarse connectivity state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Connectivity {
    /// No usable network.
    None,
    /// Wi-Fi.
    Wifi,
    /// Cellular.
    Cellular,
    /// Ethernet.
    Ethernet,
    /// Some other transport.
    Other,
    /// The host could not determine the state.
    Unknown,
}

/// Stable device information.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceInfo {
    /// Device manufacturer.
    pub manufacturer: String,
    /// Device model.
    pub model: String,
    /// Device codename.
    pub device: String,
    /// Android release string.
    pub android_version: String,
    /// Android SDK level.
    pub sdk_int: i32,
    /// Supported ABIs, in preference order.
    pub abis: Vec<String>,
}

/// Host platform services used by the Wave 0/1 drivers.
///
/// The trait's public methods gate on [`PlatformHost::capabilities`] BEFORE
/// calling the `*_unchecked` hooks. Implementations must only implement the
/// hooks, so no operation can accidentally run without its capability.
///
/// The hooks are `#[doc(hidden)]` implementation details; callers use the
/// gated methods only.
pub trait PlatformHost: Send + Sync {
    /// Capabilities advertised by this host.
    fn capabilities(&self) -> CapabilitySet;

    /// Whether a capability is present.
    fn supports(&self, cap: Capability) -> bool {
        self.capabilities().supports(cap)
    }

    /// Fail-closed capability gate.
    ///
    /// # Errors
    /// Returns [`Error::Unsupported`] when the capability is absent.
    fn require(&self, cap: Capability) -> Result<(), Error> {
        if self.supports(cap) {
            Ok(())
        } else {
            Err(Error::Unsupported(format!(
                "platform capability unavailable: {}",
                cap.as_str()
            )))
        }
    }

    /// Enumerates installed applications.
    fn list_installed(&self) -> Result<Vec<InstalledApp>, Error> {
        self.require(Capability::Inventory)?;
        self.list_installed_unchecked()
    }

    /// Reads one installed application by package name.
    fn get_installed(&self, package_name: &str) -> Result<Option<InstalledApp>, Error> {
        self.require(Capability::Inventory)?;
        self.get_installed_unchecked(package_name)
    }

    /// Whether `package_name` is installed.
    fn is_installed(&self, package_name: &str) -> Result<bool, Error> {
        self.require(Capability::Inventory)?;
        self.is_installed_unchecked(package_name)
    }

    /// Resolves the base APK source directory for `package_name`.
    fn get_source_dir(&self, package_name: &str) -> Result<Option<String>, Error> {
        self.require(Capability::Inventory)?;
        self.get_source_dir_unchecked(package_name)
    }

    /// Reads signing certificates for `package_name`.
    fn get_signatures(&self, package_name: &str) -> Result<Vec<AppSignature>, Error> {
        self.require(Capability::Inventory)?;
        self.get_signatures_unchecked(package_name)
    }

    /// Reads requested permissions for `package_name`.
    fn get_permissions(&self, package_name: &str) -> Result<Vec<String>, Error> {
        self.require(Capability::Inventory)?;
        self.get_permissions_unchecked(package_name)
    }

    /// Reads components and permission states for `package_name`.
    fn get_components(&self, package_name: &str) -> Result<AppComponents, Error> {
        self.require(Capability::Inventory)?;
        self.get_components_unchecked(package_name)
    }

    /// Installs an APK from `apk_path`.
    fn install(&self, apk_path: &Path) -> Result<(), Error> {
        self.require(Capability::Install)?;
        self.install_unchecked(apk_path)
    }

    /// Uninstalls `package_name`.
    fn uninstall(&self, package_name: &str) -> Result<(), Error> {
        self.require(Capability::Uninstall)?;
        self.uninstall_unchecked(package_name)
    }

    /// Launches `package_name`.
    fn launch(&self, package_name: &str) -> Result<(), Error> {
        self.require(Capability::Launch)?;
        self.launch_unchecked(package_name)
    }

    /// Posts a notification.
    fn notify(&self, notification: &Notification) -> Result<(), Error> {
        self.require(Capability::Notify)?;
        self.notify_unchecked(notification)
    }

    /// Starts the foreground service.
    fn start_foreground(&self, notification: &Notification) -> Result<(), Error> {
        self.require(Capability::ForegroundService)?;
        self.start_foreground_unchecked(notification)
    }

    /// Stops the foreground service.
    fn stop_foreground(&self) -> Result<(), Error> {
        self.require(Capability::ForegroundService)?;
        self.stop_foreground_unchecked()
    }

    /// Resolves application storage directories.
    fn storage_paths(&self) -> Result<StoragePaths, Error> {
        self.require(Capability::StoragePaths)?;
        self.storage_paths_unchecked()
    }

    /// Reads the coarse connectivity state.
    fn connectivity(&self) -> Result<Connectivity, Error> {
        self.require(Capability::Connectivity)?;
        self.connectivity_unchecked()
    }

    /// Whether the host currently has a usable network.
    fn is_online(&self) -> Result<bool, Error> {
        self.require(Capability::Connectivity)?;
        self.is_online_unchecked()
    }

    /// Reads stable device information.
    fn device_info(&self) -> Result<DeviceInfo, Error> {
        self.require(Capability::DeviceInfo)?;
        self.device_info_unchecked()
    }

    /// Reads a secret. `None` means the key is absent.
    fn secret_get(&self, key: &str) -> Result<Option<String>, Error> {
        self.require(Capability::Secrets)?;
        self.secret_get_unchecked(key)
    }

    /// Writes a secret.
    fn secret_set(&self, key: &str, value: &str) -> Result<(), Error> {
        self.require(Capability::Secrets)?;
        self.secret_set_unchecked(key, value)
    }

    /// Removes a secret; `true` means it existed.
    fn secret_remove(&self, key: &str) -> Result<bool, Error> {
        self.require(Capability::Secrets)?;
        self.secret_remove_unchecked(key)
    }

    /// Lists secret keys (never values).
    fn secret_list(&self) -> Result<Vec<String>, Error> {
        self.require(Capability::Secrets)?;
        self.secret_list_unchecked()
    }

    /// Implementation hook for [`PlatformHost::list_installed`].
    #[doc(hidden)]
    fn list_installed_unchecked(&self) -> Result<Vec<InstalledApp>, Error>;

    /// Implementation hook for [`PlatformHost::get_installed`].
    #[doc(hidden)]
    fn get_installed_unchecked(&self, package_name: &str) -> Result<Option<InstalledApp>, Error>;

    /// Implementation hook for [`PlatformHost::is_installed`].
    ///
    /// The default keeps the trait backward compatible for hosts that only
    /// implement the base inventory surface.
    #[doc(hidden)]
    fn is_installed_unchecked(&self, _package_name: &str) -> Result<bool, Error> {
        Err(Error::Unsupported(
            "platform inventory detail: is_installed".to_string(),
        ))
    }

    /// Implementation hook for [`PlatformHost::get_source_dir`].
    #[doc(hidden)]
    fn get_source_dir_unchecked(&self, _package_name: &str) -> Result<Option<String>, Error> {
        Err(Error::Unsupported(
            "platform inventory detail: get_source_dir".to_string(),
        ))
    }

    /// Implementation hook for [`PlatformHost::get_signatures`].
    #[doc(hidden)]
    fn get_signatures_unchecked(&self, _package_name: &str) -> Result<Vec<AppSignature>, Error> {
        Err(Error::Unsupported(
            "platform inventory detail: get_signatures".to_string(),
        ))
    }

    /// Implementation hook for [`PlatformHost::get_permissions`].
    #[doc(hidden)]
    fn get_permissions_unchecked(&self, _package_name: &str) -> Result<Vec<String>, Error> {
        Err(Error::Unsupported(
            "platform inventory detail: get_permissions".to_string(),
        ))
    }

    /// Implementation hook for [`PlatformHost::get_components`].
    #[doc(hidden)]
    fn get_components_unchecked(&self, _package_name: &str) -> Result<AppComponents, Error> {
        Err(Error::Unsupported(
            "platform inventory detail: get_components".to_string(),
        ))
    }

    /// Implementation hook for [`PlatformHost::install`].
    #[doc(hidden)]
    fn install_unchecked(&self, apk_path: &Path) -> Result<(), Error>;

    /// Implementation hook for [`PlatformHost::uninstall`].
    #[doc(hidden)]
    fn uninstall_unchecked(&self, package_name: &str) -> Result<(), Error>;

    /// Implementation hook for [`PlatformHost::launch`].
    #[doc(hidden)]
    fn launch_unchecked(&self, package_name: &str) -> Result<(), Error>;

    /// Implementation hook for [`PlatformHost::notify`].
    #[doc(hidden)]
    fn notify_unchecked(&self, notification: &Notification) -> Result<(), Error>;

    /// Implementation hook for [`PlatformHost::start_foreground`].
    #[doc(hidden)]
    fn start_foreground_unchecked(&self, notification: &Notification) -> Result<(), Error>;

    /// Implementation hook for [`PlatformHost::stop_foreground`].
    #[doc(hidden)]
    fn stop_foreground_unchecked(&self) -> Result<(), Error>;

    /// Implementation hook for [`PlatformHost::storage_paths`].
    #[doc(hidden)]
    fn storage_paths_unchecked(&self) -> Result<StoragePaths, Error>;

    /// Implementation hook for [`PlatformHost::connectivity`].
    #[doc(hidden)]
    fn connectivity_unchecked(&self) -> Result<Connectivity, Error>;

    /// Implementation hook for [`PlatformHost::is_online`].
    #[doc(hidden)]
    fn is_online_unchecked(&self) -> Result<bool, Error>;

    /// Implementation hook for [`PlatformHost::device_info`].
    #[doc(hidden)]
    fn device_info_unchecked(&self) -> Result<DeviceInfo, Error>;

    /// Implementation hook for [`PlatformHost::secret_get`].
    #[doc(hidden)]
    fn secret_get_unchecked(&self, key: &str) -> Result<Option<String>, Error>;

    /// Implementation hook for [`PlatformHost::secret_set`].
    #[doc(hidden)]
    fn secret_set_unchecked(&self, key: &str, value: &str) -> Result<(), Error>;

    /// Implementation hook for [`PlatformHost::secret_remove`].
    #[doc(hidden)]
    fn secret_remove_unchecked(&self, key: &str) -> Result<bool, Error>;

    /// Implementation hook for [`PlatformHost::secret_list`].
    #[doc(hidden)]
    fn secret_list_unchecked(&self) -> Result<Vec<String>, Error>;
}
