//! Wave 0/1 ports: HTTP, secrets, metadata, config, and F-Droid.
//!
//! Traits are synchronous, matching the crate's existing port conventions. All
//! fallible operations return the shared [`crate::error::Error`]. The platform
//! and installer ports were removed with the core boundary: the frontend pushes
//! facts/inventory and executes installs, so no core edge calls platform code.

pub mod config;
pub mod fake;
pub mod http;
pub mod metadata;
pub mod repo;
pub mod secret;

pub use config::CoreConfig;
pub use fake::{FakeHttpPort, FakeMetadataPort, FakeRepoPort, RecordedHttpCall};
pub use http::{
    validate_http_url, validate_proxy_url, HttpOptions, HttpPort, HttpResponse, DEFAULT_TIMEOUT,
};
pub use metadata::{
    CachedMetadataPort, ClockFn, MetadataPort, PackageMetadata, METADATA_CACHE_TTL,
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
