//! Deterministic in-memory fakes for every Wave 0/1 port.
//!
//! The fakes are intentionally observable: call counters prove that a gated
//! operation did NOT run, and the HTTP fake records the proxy, CA, and timeout
//! values that were actually applied.

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use crate::error::Error;
use crate::ports::http::{validate_http_url, HttpOptions, HttpPort, HttpResponse};
use crate::ports::installer::{InstallOutcome, InstallTicket, InstallerPort};
use crate::ports::metadata::{MetadataPort, PackageMetadata};
use crate::ports::platform::{
    AppComponents, AppSignature, CapabilitySet, Connectivity, DeviceInfo, InstalledApp,
    Notification, PlatformHost, StoragePaths,
};
use crate::ports::repo::{validate_repo_source, RepoApp, RepoMeta, RepoPort};
use crate::ports::secret::validate_secret_key;

fn internal(context: &str) -> Error {
    Error::Internal(format!("{context} lock poisoned"))
}

// ---------------------------------------------------------------------------
// PlatformHost
// ---------------------------------------------------------------------------

/// Fake platform host with per-operation call witnesses.
#[derive(Debug)]
pub struct FakePlatformHost {
    capabilities: RwLock<CapabilitySet>,
    installed: RwLock<BTreeMap<String, InstalledApp>>,
    source_dirs: RwLock<BTreeMap<String, String>>,
    signatures: RwLock<BTreeMap<String, Vec<AppSignature>>>,
    permissions: RwLock<BTreeMap<String, Vec<String>>>,
    components: RwLock<BTreeMap<String, AppComponents>>,
    online: AtomicBool,
    connectivity: Connectivity,
    storage: StoragePaths,
    device: DeviceInfo,
    secrets: RwLock<BTreeMap<String, String>>,
    notifications: RwLock<Vec<Notification>>,
    foreground: AtomicBool,
    calls: RwLock<BTreeMap<&'static str, u64>>,
}

impl Default for FakePlatformHost {
    fn default() -> Self {
        Self::new(CapabilitySet::empty())
    }
}

impl FakePlatformHost {
    /// Creates a host advertising `capabilities`.
    pub fn new(capabilities: CapabilitySet) -> Self {
        Self {
            capabilities: RwLock::new(capabilities),
            installed: RwLock::new(BTreeMap::new()),
            source_dirs: RwLock::new(BTreeMap::new()),
            signatures: RwLock::new(BTreeMap::new()),
            permissions: RwLock::new(BTreeMap::new()),
            components: RwLock::new(BTreeMap::new()),
            online: AtomicBool::new(true),
            connectivity: Connectivity::Wifi,
            storage: StoragePaths {
                data_dir: PathBuf::from("/data/user/0/com.example.gstore"),
                cache_dir: PathBuf::from("/data/user/0/com.example.gstore/cache"),
                files_dir: PathBuf::from("/data/user/0/com.example.gstore/files"),
                external_files_dir: None,
            },
            device: DeviceInfo {
                manufacturer: "Example".to_string(),
                model: "Fake Phone".to_string(),
                device: "fake".to_string(),
                android_version: "15".to_string(),
                sdk_int: 35,
                abis: vec!["arm64-v8a".to_string()],
            },
            secrets: RwLock::new(BTreeMap::new()),
            notifications: RwLock::new(Vec::new()),
            foreground: AtomicBool::new(false),
            calls: RwLock::new(BTreeMap::new()),
        }
    }

    /// Seeds installed applications.
    #[must_use]
    pub fn with_installed(self, apps: Vec<InstalledApp>) -> Self {
        {
            let mut installed = self.installed.write().unwrap_or_else(|e| e.into_inner());
            for app in apps {
                installed.insert(app.package_name.clone(), app);
            }
        }
        self
    }

    /// Seeds signing certificates for one package.
    #[must_use]
    pub fn with_signatures(self, package_name: &str, values: Vec<AppSignature>) -> Self {
        self.signatures
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(package_name.to_string(), values);
        self
    }

    /// Seeds requested permissions for one package.
    #[must_use]
    pub fn with_permissions(self, package_name: &str, values: Vec<String>) -> Self {
        self.permissions
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(package_name.to_string(), values);
        self
    }

    /// Seeds components and permission states for one package.
    #[must_use]
    pub fn with_components(self, package_name: &str, values: AppComponents) -> Self {
        self.components
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(package_name.to_string(), values);
        self
    }

    /// Seeds the base APK source path for one package.
    #[must_use]
    pub fn with_source_dir(self, package_name: &str, source_dir: &str) -> Self {
        self.source_dirs
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(package_name.to_string(), source_dir.to_string());
        self
    }

    /// Sets the connectivity state reported by the fake.
    #[must_use]
    pub const fn with_online(mut self, online: bool) -> Self {
        self.online = AtomicBool::new(online);
        self
    }

    /// Overrides the device information.
    #[must_use]
    pub fn with_device(mut self, device: DeviceInfo) -> Self {
        self.device = device;
        self
    }

    /// Overrides storage paths.
    #[must_use]
    pub fn with_storage(mut self, storage: StoragePaths) -> Self {
        self.storage = storage;
        self
    }

    /// Replaces the advertised capabilities.
    ///
    /// # Errors
    /// Returns [`Error::Internal`] if the capability lock was poisoned.
    pub fn set_capabilities(&self, capabilities: CapabilitySet) -> Result<(), Error> {
        *self
            .capabilities
            .write()
            .map_err(|_| internal("platform capabilities"))? = capabilities;
        Ok(())
    }

    /// Number of times an implementation hook ran.
    pub fn calls(&self, operation: &str) -> u64 {
        self.calls
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .get(operation)
            .copied()
            .unwrap_or(0)
    }

    /// Notifications accepted so far.
    pub fn notifications(&self) -> Vec<Notification> {
        self.notifications
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Whether the fake foreground service is running.
    pub fn foreground_running(&self) -> bool {
        self.foreground.load(Ordering::SeqCst)
    }

    fn record(&self, operation: &'static str) -> Result<(), Error> {
        let mut calls = self.calls.write().map_err(|_| internal("platform calls"))?;
        *calls.entry(operation).or_insert(0) += 1;
        Ok(())
    }
}

impl PlatformHost for FakePlatformHost {
    fn capabilities(&self) -> CapabilitySet {
        *self
            .capabilities
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn list_installed_unchecked(&self) -> Result<Vec<InstalledApp>, Error> {
        self.record("list_installed")?;
        Ok(self
            .installed
            .read()
            .map_err(|_| internal("platform installed"))?
            .values()
            .cloned()
            .collect())
    }

    fn get_installed_unchecked(&self, package_name: &str) -> Result<Option<InstalledApp>, Error> {
        self.record("get_installed")?;
        Ok(self
            .installed
            .read()
            .map_err(|_| internal("platform installed"))?
            .get(package_name)
            .cloned())
    }

    fn is_installed_unchecked(&self, package_name: &str) -> Result<bool, Error> {
        self.record("is_installed")?;
        Ok(self
            .installed
            .read()
            .map_err(|_| internal("platform installed"))?
            .contains_key(package_name))
    }

    fn get_source_dir_unchecked(&self, package_name: &str) -> Result<Option<String>, Error> {
        self.record("get_source_dir")?;
        let installed = self
            .installed
            .read()
            .map_err(|_| internal("platform installed"))?;
        if !installed.contains_key(package_name) {
            return Ok(None);
        }
        let source_dirs = self
            .source_dirs
            .read()
            .map_err(|_| internal("platform source dirs"))?;
        Ok(Some(source_dirs.get(package_name).cloned().unwrap_or_else(
            || format!("/data/app/{package_name}/base.apk"),
        )))
    }

    fn get_signatures_unchecked(&self, package_name: &str) -> Result<Vec<AppSignature>, Error> {
        self.record("get_signatures")?;
        Ok(self
            .signatures
            .read()
            .map_err(|_| internal("platform signatures"))?
            .get(package_name)
            .cloned()
            .unwrap_or_default())
    }

    fn get_permissions_unchecked(&self, package_name: &str) -> Result<Vec<String>, Error> {
        self.record("get_permissions")?;
        Ok(self
            .permissions
            .read()
            .map_err(|_| internal("platform permissions"))?
            .get(package_name)
            .cloned()
            .unwrap_or_default())
    }

    fn get_components_unchecked(&self, package_name: &str) -> Result<AppComponents, Error> {
        self.record("get_components")?;
        Ok(self
            .components
            .read()
            .map_err(|_| internal("platform components"))?
            .get(package_name)
            .cloned()
            .unwrap_or(AppComponents {
                components: Vec::new(),
                permission_states: Vec::new(),
            }))
    }

    fn install_unchecked(&self, apk_path: &Path) -> Result<(), Error> {
        self.record("install")?;
        if apk_path.as_os_str().is_empty() {
            return Err(Error::InvalidArgument(
                "apk path must not be empty".to_string(),
            ));
        }
        Ok(())
    }

    fn uninstall_unchecked(&self, package_name: &str) -> Result<(), Error> {
        self.record("uninstall")?;
        self.installed
            .write()
            .map_err(|_| internal("platform installed"))?
            .remove(package_name)
            .map(|_| ())
            .ok_or_else(|| Error::NotFound(format!("package not installed: {package_name}")))
    }

    fn launch_unchecked(&self, package_name: &str) -> Result<(), Error> {
        self.record("launch")?;
        if self
            .installed
            .read()
            .map_err(|_| internal("platform installed"))?
            .contains_key(package_name)
        {
            Ok(())
        } else {
            Err(Error::NotFound(format!(
                "package not installed: {package_name}"
            )))
        }
    }

    fn notify_unchecked(&self, notification: &Notification) -> Result<(), Error> {
        self.record("notify")?;
        self.notifications
            .write()
            .map_err(|_| internal("platform notifications"))?
            .push(notification.clone());
        Ok(())
    }

    fn start_foreground_unchecked(&self, notification: &Notification) -> Result<(), Error> {
        self.record("start_foreground")?;
        if notification.channel_id.is_empty() {
            return Err(Error::InvalidArgument(
                "foreground notification channel must not be empty".to_string(),
            ));
        }
        self.foreground.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn stop_foreground_unchecked(&self) -> Result<(), Error> {
        self.record("stop_foreground")?;
        self.foreground.store(false, Ordering::SeqCst);
        Ok(())
    }

    fn storage_paths_unchecked(&self) -> Result<StoragePaths, Error> {
        self.record("storage_paths")?;
        Ok(self.storage.clone())
    }

    fn connectivity_unchecked(&self) -> Result<Connectivity, Error> {
        self.record("connectivity")?;
        Ok(self.connectivity)
    }

    fn is_online_unchecked(&self) -> Result<bool, Error> {
        self.record("is_online")?;
        Ok(self.online.load(Ordering::SeqCst))
    }

    fn device_info_unchecked(&self) -> Result<DeviceInfo, Error> {
        self.record("device_info")?;
        Ok(self.device.clone())
    }

    fn secret_get_unchecked(&self, key: &str) -> Result<Option<String>, Error> {
        validate_secret_key(key)?;
        self.record("secret_get")?;
        Ok(self
            .secrets
            .read()
            .map_err(|_| internal("platform secrets"))?
            .get(key)
            .cloned())
    }

    fn secret_set_unchecked(&self, key: &str, value: &str) -> Result<(), Error> {
        validate_secret_key(key)?;
        self.record("secret_set")?;
        self.secrets
            .write()
            .map_err(|_| internal("platform secrets"))?
            .insert(key.to_string(), value.to_string());
        Ok(())
    }

    fn secret_remove_unchecked(&self, key: &str) -> Result<bool, Error> {
        validate_secret_key(key)?;
        self.record("secret_remove")?;
        Ok(self
            .secrets
            .write()
            .map_err(|_| internal("platform secrets"))?
            .remove(key)
            .is_some())
    }

    fn secret_list_unchecked(&self) -> Result<Vec<String>, Error> {
        self.record("secret_list")?;
        Ok(self
            .secrets
            .read()
            .map_err(|_| internal("platform secrets"))?
            .keys()
            .cloned()
            .collect())
    }
}

// ---------------------------------------------------------------------------
// InstallerPort
// ---------------------------------------------------------------------------

/// One recorded `begin_install` call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedInstallCall {
    /// Session id supplied by the caller.
    pub session_id: String,
    /// APK path supplied by the caller.
    pub apk_path: PathBuf,
}

/// Behaviour of [`FakeInstallerPort::begin_install`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FakeInstallMode {
    /// Return a synchronous outcome.
    Immediate(InstallOutcome),
    /// Create an asynchronous session that only resolves via `complete`.
    Pending,
    /// Return an error from `begin_install`.
    Error(String),
}

#[derive(Debug)]
struct FakeInstallerState {
    can_install: AtomicBool,
    mode: Mutex<FakeInstallMode>,
    pending_sessions: Mutex<Vec<String>>,
    completed: Mutex<BTreeMap<String, InstallOutcome>>,
    begin_calls: Mutex<Vec<RecordedInstallCall>>,
    uninstall_calls: Mutex<Vec<String>>,
    launch_calls: Mutex<Vec<String>>,
    install_result_calls: AtomicU64,
}

/// Recording installer fake.
///
/// Every call is observable so tests can prove the service called the port
/// exactly once and did not reach any other platform/plugin path.
#[derive(Debug, Clone)]
pub struct FakeInstallerPort {
    state: Arc<FakeInstallerState>,
}

impl FakeInstallerPort {
    /// Creates a fake that can (or cannot) install and completes immediately
    /// with an anonymous `Installed` outcome.
    pub fn new(can_install: bool) -> Self {
        Self {
            state: Arc::new(FakeInstallerState {
                can_install: AtomicBool::new(can_install),
                mode: Mutex::new(FakeInstallMode::Immediate(InstallOutcome::Installed {
                    package_name: None,
                    version_name: None,
                })),
                pending_sessions: Mutex::new(Vec::new()),
                completed: Mutex::new(BTreeMap::new()),
                begin_calls: Mutex::new(Vec::new()),
                uninstall_calls: Mutex::new(Vec::new()),
                launch_calls: Mutex::new(Vec::new()),
                install_result_calls: AtomicU64::new(0),
            }),
        }
    }

    /// Changes the advertised [`InstallerPort::can_install`] answer.
    pub fn set_can_install(&self, can_install: bool) {
        self.state.can_install.store(can_install, Ordering::SeqCst);
    }

    /// Makes `begin_install` return `outcome` synchronously.
    pub fn set_immediate(&self, outcome: InstallOutcome) {
        *self.state.mode.lock().unwrap_or_else(|e| e.into_inner()) =
            FakeInstallMode::Immediate(outcome);
    }

    /// Makes `begin_install` create an asynchronous pending session.
    pub fn set_pending(&self) {
        *self.state.mode.lock().unwrap_or_else(|e| e.into_inner()) = FakeInstallMode::Pending;
    }

    /// Makes `begin_install` fail with this message.
    pub fn set_begin_error(&self, message: &str) {
        *self.state.mode.lock().unwrap_or_else(|e| e.into_inner()) =
            FakeInstallMode::Error(message.to_string());
    }

    /// Resolves a pending session with `outcome`.
    pub fn complete(&self, session_id: &str, outcome: InstallOutcome) {
        self.state
            .completed
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(session_id.to_string(), outcome);
        self.state
            .pending_sessions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|session| session != session_id);
    }

    /// Recorded `begin_install` calls, in order.
    pub fn begin_calls(&self) -> Vec<RecordedInstallCall> {
        self.state
            .begin_calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Number of `begin_install` calls.
    pub fn begin_count(&self) -> usize {
        self.state
            .begin_calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .len()
    }

    /// Recorded `uninstall` package names.
    pub fn uninstall_calls(&self) -> Vec<String> {
        self.state
            .uninstall_calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Recorded `launch` package names.
    pub fn launch_calls(&self) -> Vec<String> {
        self.state
            .launch_calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Number of `install_result` polls.
    pub fn install_result_count(&self) -> u64 {
        self.state.install_result_calls.load(Ordering::SeqCst)
    }
}

impl InstallerPort for FakeInstallerPort {
    fn can_install(&self) -> bool {
        self.state.can_install.load(Ordering::SeqCst)
    }

    fn begin_install(&self, apk_path: &Path, session_id: &str) -> Result<InstallTicket, Error> {
        self.state
            .begin_calls
            .lock()
            .map_err(|_| internal("installer begin calls"))?
            .push(RecordedInstallCall {
                session_id: session_id.to_string(),
                apk_path: apk_path.to_path_buf(),
            });
        let mode = self
            .state
            .mode
            .lock()
            .map_err(|_| internal("installer mode"))?
            .clone();
        match mode {
            FakeInstallMode::Immediate(outcome) => Ok(InstallTicket {
                method: crate::ports::installer::InstallMethod::Platform,
                outcome: Some(outcome),
            }),
            FakeInstallMode::Pending => {
                self.state
                    .pending_sessions
                    .lock()
                    .map_err(|_| internal("installer pending sessions"))?
                    .push(session_id.to_string());
                Ok(InstallTicket {
                    method: crate::ports::installer::InstallMethod::Platform,
                    outcome: None,
                })
            }
            FakeInstallMode::Error(message) => Err(Error::Internal(message)),
        }
    }

    fn install_result(&self, session_id: &str) -> Result<Option<InstallOutcome>, Error> {
        self.state
            .install_result_calls
            .fetch_add(1, Ordering::SeqCst);
        Ok(self
            .state
            .completed
            .lock()
            .map_err(|_| internal("installer completed"))?
            .remove(session_id))
    }

    fn uninstall(&self, package_name: &str) -> Result<(), Error> {
        self.state
            .uninstall_calls
            .lock()
            .map_err(|_| internal("installer uninstall calls"))?
            .push(package_name.to_string());
        Ok(())
    }

    fn launch(&self, package_name: &str) -> Result<(), Error> {
        self.state
            .launch_calls
            .lock()
            .map_err(|_| internal("installer launch calls"))?
            .push(package_name.to_string());
        Ok(())
    }

    fn pending_sessions(&self) -> Result<Vec<String>, Error> {
        Ok(self
            .state
            .pending_sessions
            .lock()
            .map_err(|_| internal("installer pending sessions"))?
            .clone())
    }
}

// ---------------------------------------------------------------------------
// HttpPort
// ---------------------------------------------------------------------------

/// One recorded HTTP call, including the options actually applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedHttpCall {
    /// Method (`GET` / `POST`).
    pub method: String,
    /// Request URL.
    pub url: String,
    /// Request headers.
    pub headers: Vec<(String, String)>,
    /// Request body (POST only).
    pub body: Option<Vec<u8>>,
    /// Applied proxy URL.
    pub proxy: Option<String>,
    /// Applied CA override.
    pub ca_pem: Option<Vec<u8>>,
    /// Applied timeout.
    pub timeout: std::time::Duration,
}

#[derive(Debug, Default)]
struct FakeHttpState {
    calls: Mutex<Vec<RecordedHttpCall>>,
    responses: Mutex<VecDeque<HttpResponse>>,
}

/// Recording HTTP fake. Never touches the network.
#[derive(Debug, Clone, Default)]
pub struct FakeHttpPort {
    state: Arc<FakeHttpState>,
}

impl FakeHttpPort {
    /// Creates an empty fake (default response: 200 with an empty body).
    pub fn new() -> Self {
        Self::default()
    }

    /// Queues a response for the next call.
    pub fn push_response(&self, response: HttpResponse) {
        self.state
            .responses
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push_back(response);
    }

    /// Snapshot of recorded calls.
    pub fn calls(&self) -> Vec<RecordedHttpCall> {
        self.state
            .calls
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    fn record(
        &self,
        method: &str,
        url: &str,
        body: Option<Vec<u8>>,
        options: &HttpOptions,
    ) -> Result<HttpResponse, Error> {
        validate_http_url(url)?;
        options.validate()?;
        self.state
            .calls
            .lock()
            .map_err(|_| internal("http calls"))?
            .push(RecordedHttpCall {
                method: method.to_string(),
                url: url.to_string(),
                headers: options.headers.clone(),
                body,
                proxy: options.proxy.clone(),
                ca_pem: options.ca_pem.clone(),
                timeout: options.timeout,
            });
        Ok(self
            .state
            .responses
            .lock()
            .map_err(|_| internal("http responses"))?
            .pop_front()
            .unwrap_or_else(|| HttpResponse {
                status: 200,
                headers: Vec::new(),
                body: Vec::new(),
            }))
    }
}

impl HttpPort for FakeHttpPort {
    fn get(&self, url: &str, options: &HttpOptions) -> Result<HttpResponse, Error> {
        self.record("GET", url, None, options)
    }

    fn post(&self, url: &str, body: &[u8], options: &HttpOptions) -> Result<HttpResponse, Error> {
        self.record("POST", url, Some(body.to_vec()), options)
    }
}

// ---------------------------------------------------------------------------
// MetadataPort
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
struct FakeMetadataState {
    entries: RwLock<BTreeMap<String, Option<PackageMetadata>>>,
    fetch_count: AtomicU64,
}

/// Metadata fake with an observable fetch count.
#[derive(Debug, Clone, Default)]
pub struct FakeMetadataPort {
    state: Arc<FakeMetadataState>,
}

impl FakeMetadataPort {
    /// Creates an empty fake (every lookup returns `None`).
    pub fn new() -> Self {
        Self::default()
    }

    /// Seeds (or replaces) one `owner/repo` lookup.
    pub fn set(&self, owner: &str, repo: &str, value: Option<PackageMetadata>) {
        let mut entries = self
            .state
            .entries
            .write()
            .unwrap_or_else(|e| e.into_inner());
        entries.insert(format!("{owner}@{repo}"), value);
    }

    /// Number of `fetch` calls that reached this fake.
    pub fn fetch_count(&self) -> u64 {
        self.state.fetch_count.load(Ordering::SeqCst)
    }
}

impl MetadataPort for FakeMetadataPort {
    fn fetch(&self, owner: &str, repo: &str) -> Result<Option<PackageMetadata>, Error> {
        self.state.fetch_count.fetch_add(1, Ordering::SeqCst);
        if owner.is_empty() || repo.is_empty() {
            return Err(Error::InvalidArgument(
                "owner and repo must not be empty".to_string(),
            ));
        }
        Ok(self
            .state
            .entries
            .read()
            .map_err(|_| internal("metadata entries"))?
            .get(&format!("{owner}@{repo}"))
            .cloned()
            .flatten())
    }
}

// ---------------------------------------------------------------------------
// RepoPort
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct FakeRepoState {
    db_path: PathBuf,
    repos: RwLock<BTreeMap<String, RepoMeta>>,
    apps: RwLock<BTreeMap<(String, String), RepoApp>>,
    download_count: AtomicU64,
}

/// Deterministic repository fake.
#[derive(Debug, Clone)]
pub struct FakeRepoPort {
    state: Arc<FakeRepoState>,
}

impl FakeRepoPort {
    /// Creates a fake with the supplied database path.
    pub fn new(db_path: impl Into<PathBuf>) -> Self {
        Self {
            state: Arc::new(FakeRepoState {
                db_path: db_path.into(),
                repos: RwLock::new(BTreeMap::new()),
                apps: RwLock::new(BTreeMap::new()),
                download_count: AtomicU64::new(0),
            }),
        }
    }

    /// Seeds repository metadata.
    pub fn add_repo(&self, meta: RepoMeta) {
        self.state
            .repos
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(meta.source.clone(), meta);
    }

    /// Seeds one application.
    pub fn add_app(&self, source: &str, app: RepoApp) {
        self.state
            .apps
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert((source.to_string(), app.package_name.clone()), app);
    }

    /// Number of `download_repo` calls.
    pub fn download_count(&self) -> u64 {
        self.state.download_count.load(Ordering::SeqCst)
    }

    fn app_count(&self, source: &str) -> Result<u64, Error> {
        let apps = self.state.apps.read().map_err(|_| internal("repo apps"))?;
        Ok(apps
            .keys()
            .filter(|(repo, _)| repo == source)
            .count()
            .try_into()
            .unwrap_or(u64::MAX))
    }
}

impl RepoPort for FakeRepoPort {
    fn download_repo(&self, source: &str) -> Result<RepoMeta, Error> {
        validate_repo_source(source)?;
        self.state.download_count.fetch_add(1, Ordering::SeqCst);
        let count = self.app_count(source)?;
        let mut repos = self
            .state
            .repos
            .write()
            .map_err(|_| internal("repo metadata"))?;
        let meta = repos
            .get_mut(source)
            .ok_or_else(|| Error::NotFound(format!("repo not seeded: {source}")))?;
        meta.app_count = count;
        Ok(meta.clone())
    }

    fn get_app_count(&self, source: &str) -> Result<u64, Error> {
        validate_repo_source(source)?;
        self.app_count(source)
    }

    fn search_apps(&self, source: &str, query: &str, limit: usize) -> Result<Vec<RepoApp>, Error> {
        validate_repo_source(source)?;
        if query.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "repo search query must not be empty".to_string(),
            ));
        }
        if limit == 0 {
            return Err(Error::InvalidArgument(
                "repo search limit must be greater than zero".to_string(),
            ));
        }
        let needle = query.to_lowercase();
        let apps = self.state.apps.read().map_err(|_| internal("repo apps"))?;
        let mut hits: Vec<RepoApp> = apps
            .iter()
            .filter(|((repo, _), _)| repo == source)
            .map(|(_, app)| app)
            .filter(|app| {
                app.package_name.to_lowercase().contains(&needle)
                    || app.name.to_lowercase().contains(&needle)
                    || app.summary.to_lowercase().contains(&needle)
            })
            .cloned()
            .collect();
        hits.sort_by(|left, right| left.package_name.cmp(&right.package_name));
        hits.truncate(limit);
        Ok(hits)
    }

    fn get_repo_meta(&self, source: &str) -> Result<Option<RepoMeta>, Error> {
        validate_repo_source(source)?;
        Ok(self
            .state
            .repos
            .read()
            .map_err(|_| internal("repo metadata"))?
            .get(source)
            .cloned())
    }

    fn clear_apps(&self, source: &str) -> Result<(), Error> {
        validate_repo_source(source)?;
        self.state
            .apps
            .write()
            .map_err(|_| internal("repo apps"))?
            .retain(|(repo, _), _| repo != source);
        Ok(())
    }

    fn get_one_app(&self, source: &str, package_name: &str) -> Result<Option<RepoApp>, Error> {
        validate_repo_source(source)?;
        if package_name.trim().is_empty() {
            return Err(Error::InvalidArgument(
                "package name must not be empty".to_string(),
            ));
        }
        Ok(self
            .state
            .apps
            .read()
            .map_err(|_| internal("repo apps"))?
            .get(&(source.to_string(), package_name.to_string()))
            .cloned())
    }

    fn db_path(&self) -> &Path {
        &self.state.db_path
    }
}

// Re-export the secret fake so callers can import every fake from one module.
pub use crate::ports::secret::InMemorySecretPort;
