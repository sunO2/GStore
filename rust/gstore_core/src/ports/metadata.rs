//! Repository metadata port with a 24h TTL decorator.
//!
//! The decorator mirrors Dart `MetadataRepository`: a positive or negative
//! lookup is cached for 24 hours, and the clock is injectable so tests never
//! sleep. The port itself is synchronous and implementation-agnostic.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};

use crate::error::Error;

/// Metadata TTL required by the GitHub/LocalDb drivers.
pub const METADATA_CACHE_TTL: Duration = Duration::from_secs(24 * 60 * 60);

/// Override values extracted from repository metadata (`info.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PackageMetadata {
    /// Real Android package name, when metadata provides one.
    pub package_name: Option<String>,
    /// Real application name, when metadata provides one.
    pub app_name: Option<String>,
    /// Icon URL, when metadata provides one.
    pub icon_url: Option<String>,
}

impl PackageMetadata {
    /// Returns the metadata package name, or `fallback` when absent/empty.
    pub fn package_name_or<'a>(&'a self, fallback: &'a str) -> &'a str {
        self.package_name
            .as_deref()
            .filter(|value| !value.is_empty())
            .unwrap_or(fallback)
    }

    /// Returns the metadata app name, or `fallback` when absent/empty.
    pub fn app_name_or<'a>(&'a self, fallback: &'a str) -> &'a str {
        self.app_name
            .as_deref()
            .filter(|value| !value.is_empty())
            .unwrap_or(fallback)
    }

    /// Returns the metadata icon URL, or `fallback` when absent/empty.
    pub fn icon_or<'a>(&'a self, fallback: &'a str) -> &'a str {
        self.icon_url
            .as_deref()
            .filter(|value| !value.is_empty())
            .unwrap_or(fallback)
    }
}

/// Source of repository metadata (`owner/repo` → `info.json`).
pub trait MetadataPort: Send + Sync {
    /// Fetches metadata. `None` means the repository is not (yet) known.
    fn fetch(&self, owner: &str, repo: &str) -> Result<Option<PackageMetadata>, Error>;
}

/// Clock injection point for [`CachedMetadataPort`].
pub type ClockFn = Arc<dyn Fn() -> SystemTime + Send + Sync>;

#[derive(Debug, Clone)]
struct CacheEntry {
    value: Option<PackageMetadata>,
    fetched_at: SystemTime,
}

impl CacheEntry {
    fn is_fresh(&self, now: SystemTime, ttl: Duration) -> bool {
        match now.duration_since(self.fetched_at) {
            Ok(age) => age < ttl,
            // A clock that moved backwards must not make stale data immortal.
            Err(_) => false,
        }
    }
}

/// TTL cache decorator over any [`MetadataPort`].
pub struct CachedMetadataPort<M: MetadataPort> {
    inner: M,
    ttl: Duration,
    now: ClockFn,
    cache: Mutex<BTreeMap<String, CacheEntry>>,
}

impl<M: MetadataPort> CachedMetadataPort<M> {
    /// Wraps `inner` with the required 24h TTL.
    pub fn new(inner: M) -> Self {
        Self {
            inner,
            ttl: METADATA_CACHE_TTL,
            now: Arc::new(SystemTime::now),
            cache: Mutex::new(BTreeMap::new()),
        }
    }

    /// Overrides the TTL (tests / edge deployments).
    #[must_use]
    pub const fn with_ttl(mut self, ttl: Duration) -> Self {
        self.ttl = ttl;
        self
    }

    /// Overrides the clock (tests inject a deterministic one).
    #[must_use]
    pub fn with_clock(mut self, now: ClockFn) -> Self {
        self.now = now;
        self
    }

    /// Number of cached keys (positive and negative entries both count).
    ///
    /// # Errors
    /// Returns [`Error::Internal`] if the cache lock was poisoned.
    pub fn cache_len(&self) -> Result<usize, Error> {
        Ok(self
            .cache
            .lock()
            .map_err(|_| Error::Internal("metadata cache lock poisoned".to_string()))?
            .len())
    }

    /// Clears every cached lookup.
    ///
    /// # Errors
    /// Returns [`Error::Internal`] if the cache lock was poisoned.
    pub fn clear_cache(&self) -> Result<(), Error> {
        self.cache
            .lock()
            .map_err(|_| Error::Internal("metadata cache lock poisoned".to_string()))?
            .clear();
        Ok(())
    }

    /// Resolves metadata for `owner/repo`, serving fresh cache hits.
    ///
    /// # Errors
    /// Returns [`Error::InvalidArgument`] for malformed owner/repo values, or
    /// forwards the underlying port's error.
    pub fn resolve(&self, owner: &str, repo: &str) -> Result<Option<PackageMetadata>, Error> {
        let key = cache_key(owner, repo)?;
        let now = (self.now)();
        {
            let cache = self
                .cache
                .lock()
                .map_err(|_| Error::Internal("metadata cache lock poisoned".to_string()))?;
            if let Some(entry) = cache.get(&key) {
                if entry.is_fresh(now, self.ttl) {
                    return Ok(entry.value.clone());
                }
            }
        }

        let value = self.inner.fetch(owner, repo)?;
        let mut cache = self
            .cache
            .lock()
            .map_err(|_| Error::Internal("metadata cache lock poisoned".to_string()))?;
        cache.insert(
            key,
            CacheEntry {
                value: value.clone(),
                fetched_at: now,
            },
        );
        Ok(value)
    }
}

/// The TTL decorator is itself a [`MetadataPort`]: drivers accept
/// `Arc<dyn MetadataPort>` and get the 24h cache without knowing about it.
impl<M: MetadataPort> MetadataPort for CachedMetadataPort<M> {
    fn fetch(&self, owner: &str, repo: &str) -> Result<Option<PackageMetadata>, Error> {
        self.resolve(owner, repo)
    }
}

fn cache_key(owner: &str, repo: &str) -> Result<String, Error> {
    for (label, value) in [("owner", owner), ("repo", repo)] {
        if value.is_empty()
            || value.trim() != value
            || value.contains('/')
            || value.chars().any(|c| c.is_whitespace() || c.is_control())
        {
            return Err(Error::InvalidArgument(format!(
                "invalid metadata {label}: {value:?}"
            )));
        }
    }
    Ok(format!("{owner}@{repo}"))
}
