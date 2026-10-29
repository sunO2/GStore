//! Filesystem catalog repository: versioned, read-only catalog databases.
//!
//! Layout under the repo root:
//! ```text
//! seed/<sha256>.db
//! remote/<version>-<sha256>.db
//! manifest.json  { current, materialized, entries[] }
//! ```
//!
//! Copies and manifest writes are atomic (`*.tmp` + rename); every repo
//! database is opened read-only and validated with the same full validator the
//! refresh path uses. A corrupt manifest never crashes a call: it is rebuilt by
//! rescanning the directory tree.

mod manifest;
mod resolve;
mod store;
mod types;

use std::fs;
use std::path::{Path, PathBuf};

use self::manifest::{
    entry_order, is_newer, upsert_entry, Manifest, ManifestEntry, KIND_REMOTE, KIND_SEED,
};
use self::resolve::{entry_version, resolve_current};
use self::store::{atomic_write, now_millis, sanitize_component, sha256_hex};
pub use self::types::{CatalogMaterializeReport, RepoDownloadReport, RepoEntry, RepoStatus};
use crate::catalog::import::{import_catalog, CatalogImportOptions};
use crate::catalog::refresh::{read_catalog_counts, read_catalog_version, validate_source};
use crate::db::DbHandle;
use crate::error::Error;
use crate::ports::{validate_http_url, HttpOptions, HttpPort};

/// Filesystem-backed catalog repository rooted at `root`.
#[derive(Debug, Clone)]
pub struct CatalogRepo {
    root: PathBuf,
}

impl CatalogRepo {
    /// Creates the repository directories under `root`.
    ///
    /// # Errors
    /// Returns [`Error::Io`] when a directory cannot be created.
    pub fn new(root: impl Into<PathBuf>) -> Result<Self, Error> {
        let root = root.into();
        let repo = Self { root };
        for dir in [repo.seed_dir(), repo.remote_dir(), repo.tmp_dir()] {
            fs::create_dir_all(&dir).map_err(|e| {
                Error::Io(format!(
                    "CORE_E_CATALOG_REPO_DIR: create {}: {e}",
                    dir.display()
                ))
            })?;
        }
        Ok(repo)
    }

    /// Repository root.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Registers `seed_path` (validated, content-addressed) and makes it current
    /// when none is selected. Idempotent: the same bytes never copy twice.
    ///
    /// # Errors
    /// Returns [`Error::InvalidArgument`] when the seed is not a valid catalog
    /// and [`Error::Io`] for filesystem failures.
    pub fn ensure_seed(&self, seed_path: &Path) -> Result<RepoStatus, Error> {
        validate_source(seed_path, false)?;
        let bytes = fs::read(seed_path).map_err(|e| {
            Error::Io(format!(
                "CORE_E_CATALOG_REPO_SEED: read {}: {e}",
                seed_path.display()
            ))
        })?;
        let sha256 = sha256_hex(&bytes);
        let rel = format!("{KIND_SEED}/{sha256}.db");
        let dest = self.root.join(&rel);
        if !dest.exists() {
            atomic_write(&dest, &bytes)?;
        }
        let version = read_catalog_version(&dest)?;
        let apps = read_catalog_counts(&dest).map_or(0, |(apps, _)| apps);

        let mut manifest = self.load_manifest();
        upsert_entry(
            &mut manifest,
            ManifestEntry {
                file: rel.clone(),
                version,
                sha256,
                source: seed_path.display().to_string(),
                kind: KIND_SEED.to_string(),
                added_at: now_millis(),
                apps,
            },
        );
        if manifest.current.is_none() {
            manifest.current = Some(rel);
        }
        self.save_manifest(&manifest)?;
        self.status()
    }

    /// Current repository snapshot (apps/categories read from the current DB).
    ///
    /// # Errors
    /// Returns [`Error::Io`] only when the manifest cannot be written; a corrupt
    /// manifest is rebuilt in memory instead of failing.
    pub fn status(&self) -> Result<RepoStatus, Error> {
        let manifest = self.load_manifest();
        let entries = manifest.entries.iter().cloned().map(Into::into).collect();
        let (current_file, current_version, apps, categories) = match resolve_current(&self.root, &manifest)
        {
            Some((rel, path)) => {
                let version = entry_version(&manifest, &rel, &path);
                let (apps, categories) = read_catalog_counts(&path).unwrap_or((0, 0));
                (Some(rel), Some(version), apps, categories)
            }
            None => (None, None, 0, 0),
        };
        Ok(RepoStatus {
            current_version,
            current_file,
            apps,
            categories,
            entries,
        })
    }

    /// Downloads, validates, and registers a remote catalog. `current` switches
    /// only when the downloaded version is newer; a failed download leaves both
    /// `current` and the manifest untouched.
    ///
    /// # Errors
    /// Returns [`Error::Network`] for a failed request, [`Error::InvalidArgument`]
    /// for an empty body or invalid catalog, and [`Error::Io`] for local failures.
    pub fn download(&self, http: &dyn HttpPort, url: &str) -> Result<RepoDownloadReport, Error> {
        validate_http_url(url)?;
        let response = http.get(url, &HttpOptions::default())?;
        if !response.is_success() {
            return Err(Error::Network(format!(
                "CORE_E_CATALOG_REPO_HTTP: status {} for {url}",
                response.status
            )));
        }
        if response.body.is_empty() {
            return Err(Error::InvalidArgument(format!(
                "CORE_E_CATALOG_REPO_BODY: empty body from {url}"
            )));
        }

        let temp = store::TempFile::create(&self.tmp_dir(), &response.body)?;
        validate_source(temp.path(), false)?;
        let version = read_catalog_version(temp.path())?;
        let sha256 = sha256_hex(&response.body);
        let rel = format!("remote/{}-{sha256}.db", sanitize_component(&version));
        let dest = self.root.join(&rel);
        if !dest.exists() {
            fs::rename(temp.path(), &dest).map_err(|e| {
                Error::Io(format!(
                    "CORE_E_CATALOG_REPO_MOVE: {} -> {}: {e}",
                    temp.path().display(),
                    dest.display()
                ))
            })?;
        }
        let apps = read_catalog_counts(&dest).map_or(0, |(apps, _)| apps);
        let added_at = now_millis();

        let mut manifest = self.load_manifest();
        upsert_entry(
            &mut manifest,
            ManifestEntry {
                file: rel.clone(),
                version: version.clone(),
                sha256,
                source: url.to_string(),
                kind: KIND_REMOTE.to_string(),
                added_at,
                apps,
            },
        );
        let changed = match manifest
            .current
            .as_ref()
            .and_then(|cur| manifest.entries.iter().find(|entry| &entry.file == cur))
        {
            None => true,
            Some(entry) => is_newer(&version, added_at, &entry.version, entry.added_at),
        };
        if changed {
            manifest.current = Some(rel);
        }
        self.save_manifest(&manifest)?;
        Ok(RepoDownloadReport {
            version: Some(version),
            changed,
            entries: manifest.entries.iter().cloned().map(Into::into).collect(),
        })
    }

    /// Selects an entry by version or by relative file name.
    ///
    /// # Errors
    /// Returns [`Error::NotFound`] when no entry matches.
    pub fn select(&self, version_or_file: &str) -> Result<RepoStatus, Error> {
        let mut manifest = self.load_manifest();
        let file = manifest
            .entries
            .iter()
            .filter(|entry| entry.file == version_or_file || entry.version == version_or_file)
            .max_by(|a, b| entry_order(a, b))
            .map(|entry| entry.file.clone())
            .ok_or_else(|| {
                Error::NotFound(format!(
                    "CORE_E_CATALOG_REPO_SELECT: no entry for {version_or_file}"
                ))
            })?;
        manifest.current = Some(file);
        self.save_manifest(&manifest)?;
        self.status()
    }

    /// Resolves the current database: the selected file, else the highest
    /// valid version, else any valid seed file, else `None`.
    pub fn current_db(&self) -> Result<Option<PathBuf>, Error> {
        let manifest = self.load_manifest();
        Ok(resolve_current(&self.root, &manifest).map(|(_, path)| path))
    }

    /// Imports the current repository database into the core catalog when the
    /// core is empty or the materialized version differs from the current file.
    ///
    /// # Errors
    /// Returns [`Error::Io`] for import/manifest failures; a missing repository
    /// returns `materialized = false` instead.
    pub fn materialize_if_needed(
        &self,
        db: &DbHandle,
    ) -> Result<CatalogMaterializeReport, Error> {
        let manifest = self.load_manifest();
        let Some((rel, current)) = resolve_current(&self.root, &manifest) else {
            return Ok(CatalogMaterializeReport {
                materialized: false,
                version: None,
                apps: store::core_count(db, "apps")?,
                categories: store::core_count(db, "categories")?,
            });
        };

        let core_empty = store::core_count(db, "apps")? == 0;
        let stale = manifest.materialized.as_deref() != Some(rel.as_str());
        if !core_empty && !stale {
            return Ok(CatalogMaterializeReport {
                materialized: false,
                version: Some(entry_version(&manifest, &rel, &current)),
                apps: store::core_count(db, "apps")?,
                categories: store::core_count(db, "categories")?,
            });
        }

        let report = import_catalog(
            db,
            Some(&current),
            &current,
            &CatalogImportOptions::default(),
        )?;
        let mut manifest = manifest;
        manifest.materialized = Some(rel.clone());
        self.save_manifest(&manifest)?;
        Ok(CatalogMaterializeReport {
            materialized: true,
            version: Some(entry_version(&manifest, &rel, &current)),
            apps: report.apps,
            categories: report.categories,
        })
    }

    fn seed_dir(&self) -> PathBuf {
        self.root.join(KIND_SEED)
    }

    fn remote_dir(&self) -> PathBuf {
        self.root.join(KIND_REMOTE)
    }

    fn tmp_dir(&self) -> PathBuf {
        self.root.join("tmp")
    }

    fn load_manifest(&self) -> Manifest {
        manifest::load(&self.root)
    }

    fn save_manifest(&self, manifest: &Manifest) -> Result<(), Error> {
        manifest::save(&self.root, manifest)
    }

}
