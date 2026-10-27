//! Deterministic in-memory fakes for the surviving Wave 0/1 ports.
//!
//! The fakes are intentionally observable: the HTTP fake records the proxy, CA,
//! and timeout values that were actually applied.

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use crate::error::Error;
use crate::ports::http::{validate_http_url, HttpOptions, HttpPort, HttpResponse};
use crate::ports::metadata::{MetadataPort, PackageMetadata};
use crate::ports::repo::{validate_repo_source, RepoApp, RepoMeta, RepoPort};

fn internal(context: &str) -> Error {
    Error::Internal(format!("{context} lock poisoned"))
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
