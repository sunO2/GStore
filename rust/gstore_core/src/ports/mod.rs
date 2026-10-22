//! Wave 0/1 ports: platform host, HTTP, secrets, metadata, config, and F-Droid.
//!
//! Traits are synchronous, matching the crate's existing port conventions. All
//! fallible operations return the shared [`crate::error::Error`]; platform
//! operations are capability-gated and fail closed before touching a driver.

pub mod config;
pub mod fake;
pub mod http;
pub mod installer;
pub mod metadata;
pub mod platform;
pub mod repo;
pub mod secret;

pub use config::CoreConfig;
pub use fake::{
    FakeHttpPort, FakeInstallerPort, FakeMetadataPort, FakePlatformHost, FakeRepoPort,
    RecordedHttpCall, RecordedInstallCall,
};
pub use http::{
    validate_http_url, validate_proxy_url, HttpOptions, HttpPort, HttpResponse, DEFAULT_TIMEOUT,
};
pub use installer::{
    InstallMethod, InstallOutcome, InstallTicket, InstallerPort, PlatformInstaller,
};
pub use metadata::{
    CachedMetadataPort, ClockFn, MetadataPort, PackageMetadata, METADATA_CACHE_TTL,
};
pub use platform::{
    Capability, CapabilitySet, Connectivity, DeviceInfo, InstalledApp, Notification, PlatformHost,
    StoragePaths,
};
pub use repo::{validate_repo_source, RepoApp, RepoMeta, RepoPort};
pub use secret::{
    validate_secret_key, FileSecretPort, FileSecretStore, InMemorySecretPort, MAX_SECRET_KEY_LEN,
};

// `DownloadPort` stays exactly as defined by the spike; re-export it here so
// channel drivers have a single port surface without changing its API.
pub use crate::download::port::{
    DownloadPort, DownloadRequest, ModuleBridge, ModuleDownloadPort, PortError, ReconcileReport,
};
