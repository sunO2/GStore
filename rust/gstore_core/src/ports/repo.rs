//! F-Droid repository port.
//!
//! These are exactly the commands the F-Droid driver needs; the real module
//! bridge (`ModuleRepoPort`) lands with Todo 11. `DownloadPort` is re-exported
//! unchanged from [`crate::download::port`].

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::Error;
use crate::ports::http::validate_http_url;

/// Repository summary returned by `download_repo` / `get_repo_meta`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepoMeta {
    /// Canonical source URL.
    pub source: String,
    /// Display name.
    pub name: String,
    /// Optional description.
    pub description: Option<String>,
    /// Repository index version.
    pub version: Option<String>,
    /// Index timestamp (epoch seconds).
    pub timestamp: Option<i64>,
    /// Number of indexed applications.
    pub app_count: u64,
}

/// One indexed F-Droid application.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RepoApp {
    /// Android package name.
    pub package_name: String,
    /// Display name.
    pub name: String,
    /// Short summary.
    pub summary: String,
    /// Version label.
    pub version: Option<String>,
    /// Numeric version code.
    pub version_code: Option<i64>,
    /// Icon reference.
    pub icon: Option<String>,
    /// APK URL.
    pub apk_url: Option<String>,
    /// APK size in bytes.
    pub size: Option<i64>,
    /// Category ids.
    pub categories: Vec<String>,
    /// Raw F-Droid v2 `metadata` JSON (localized name/summary/description,
    /// screenshots, author, source code, website, license, ...). `None` when the
    /// repository module has no raw row for the app.
    pub metadata: Option<String>,
}

/// Commands the F-Droid driver needs from the repository module.
pub trait RepoPort: Send + Sync {
    /// Downloads/refreshes the repository index and returns its metadata.
    fn download_repo(&self, source: &str) -> Result<RepoMeta, Error>;

    /// Number of indexed applications for `source`.
    fn get_app_count(&self, source: &str) -> Result<u64, Error>;

    /// Keyword search restricted to `source`.
    fn search_apps(&self, source: &str, query: &str, limit: usize) -> Result<Vec<RepoApp>, Error>;

    /// Metadata for an already-downloaded repository (`None` when absent).
    fn get_repo_meta(&self, source: &str) -> Result<Option<RepoMeta>, Error>;

    /// Clears indexed applications for `source` (the repo metadata remains).
    fn clear_apps(&self, source: &str) -> Result<(), Error>;

    /// Reads one application by package name.
    fn get_one_app(&self, source: &str, package_name: &str) -> Result<Option<RepoApp>, Error>;

    /// Batch icon lookup restricted to `source`.
    ///
    /// Returns `(package_name, icon)` for every requested package that exists in
    /// the index with a non-empty icon, in the order of `package_names`; misses
    /// and empty icons are skipped. The default implementation loops
    /// [`RepoPort::get_one_app`], so existing implementations keep compiling;
    /// adapters that can answer in one round-trip override it.
    ///
    /// # Errors
    /// Propagates the [`Error`] returned by [`RepoPort::get_one_app`] for the
    /// first failing lookup.
    fn get_app_icons(
        &self,
        source: &str,
        package_names: &[String],
    ) -> Result<Vec<(String, String)>, Error> {
        let mut icons = Vec::with_capacity(package_names.len());
        for package_name in package_names {
            if let Some(app) = self.get_one_app(source, package_name)? {
                if let Some(icon) = app.icon.filter(|icon| !icon.is_empty()) {
                    icons.push((package_name.clone(), icon));
                }
            }
        }
        Ok(icons)
    }

    /// Path of the repository module database.
    fn db_path(&self) -> &Path;
}

/// Validates a repository source URL.
///
/// # Errors
/// Returns [`Error::InvalidArgument`] for an empty or malformed URL.
pub fn validate_repo_source(source: &str) -> Result<(), Error> {
    if source.trim().is_empty() {
        return Err(Error::InvalidArgument(
            "repo source must not be empty".to_string(),
        ));
    }
    validate_http_url(source)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::fake::FakeRepoPort;

    fn app(package_name: &str, icon: Option<&str>) -> RepoApp {
        RepoApp {
            package_name: package_name.to_string(),
            name: package_name.to_string(),
            summary: String::new(),
            version: None,
            version_code: None,
            icon: icon.map(ToString::to_string),
            apk_url: None,
            size: None,
            categories: Vec::new(),
            metadata: None,
        }
    }

    #[test]
    fn default_get_app_icons_returns_hits_and_skips_misses() {
        let source = "https://f-droid.org/repo";
        let fake = FakeRepoPort::new("/data/repo.db");
        fake.add_app(source, app("org.hit", Some("icons/org.hit.png")));
        fake.add_app(source, app("org.noicon", None));

        let requested = vec![
            "org.hit".to_string(),
            "org.missing".to_string(),
            "org.noicon".to_string(),
        ];
        let icons = fake.get_app_icons(source, &requested).unwrap();

        assert_eq!(
            icons,
            vec![("org.hit".to_string(), "icons/org.hit.png".to_string())]
        );
    }
}
