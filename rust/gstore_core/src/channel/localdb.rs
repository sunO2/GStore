//! LocalDb channel driver (Wave 1, Todo 10).
//!
//! Reads the `apps`, `categories`, and `app_config` tables through
//! [`DbHandle`] and reproduces the observable Dart `LocalDbChannel` semantics:
//!
//! * `getAllApps` → `SELECT * FROM apps` mapped by `AppSummary.fromDbAppInfo`
//!   (`lib/db/apps/AppInfoDatabase.g.dart:99-103`).
//! * `searchApps` → FTS5 `"word"*` first, then `LIKE %word%` appended without
//!   duplicates (`lib/db/apps/AppInfoDao.dart` `search`).
//! * `searchByCategory` → `category LIKE %id%` (substring, not equality).
//! * `getAppInfo` → the stored row as a local snapshot, with no metadata call
//!   (the list/info path is offline).
//! * `getAppDetail` → metadata package/app-name/icon override with
//!   `keepExistingPackageName: true`, plus the latest GitHub release.
//!
//! The driver is read-only. Dart `addApp`/`removeApp` explicitly return a
//! failure ("本地数据库渠道不支持…"), and `doUpdate` delegates to the global
//! database updater outside the channel; the Rust driver surfaces all three as
//! typed [`Error::Unsupported`] instead of pretending to mutate a local catalog.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use rusqlite::{params, Connection, OptionalExtension, Row};
use serde_json::{Map, Value};

use super::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use super::github_releases::{apply_repo_extra, GitHubReleases};
use super::sealed;
use crate::db::DbHandle;
use crate::dto::{
    detail_labels, insert_info_tag, summary_labels, AppDetail, AppDownload, AppSummary, AppUpdate,
    ChannelKey, ChannelKind, ChannelMeta, DetailSection,
};
use crate::error::Error;
use crate::ports::config::CoreConfig;
use crate::ports::http::HttpPort;
use crate::ports::metadata::{MetadataPort, PackageMetadata};

/// Read-only LocalDb channel driver bound to one [`ChannelKey`].
pub struct LocalDbDriver {
    key: ChannelKey,
    meta: ChannelMeta,
    db: DbHandle,
    metadata: Option<Arc<dyn MetadataPort>>,
    api: Option<GitHubReleases>,
    initialized: AtomicBool,
}

impl sealed::Sealed for LocalDbDriver {}

impl LocalDbDriver {
    /// Creates a driver bound to `key`. Metadata overrides are opt-in via
    /// [`LocalDbDriver::with_metadata`], matching deployments that run without
    /// a metadata repository.
    pub fn new(key: ChannelKey, meta: ChannelMeta, db: DbHandle) -> Self {
        Self {
            key,
            meta,
            db,
            metadata: None,
            api: None,
            initialized: AtomicBool::new(false),
        }
    }

    /// Attaches the metadata port used for package/app-name/icon overrides.
    #[must_use]
    pub fn with_metadata(mut self, metadata: Arc<dyn MetadataPort>) -> Self {
        self.metadata = Some(metadata);
        self
    }

    /// Attaches a GitHub fetcher so catalog rows pointing at a GitHub
    /// repository resolve their latest release version and downloads, exactly
    /// as Dart `LocalDbChannel.getAppDetail` does. Without it the driver is
    /// offline and every version stays `None`.
    #[must_use]
    pub fn with_github(mut self, config: CoreConfig, http: Arc<dyn HttpPort>) -> Self {
        self.api = Some(GitHubReleases::new(config, http));
        self
    }

    fn reader(&self) -> Result<Connection, Error> {
        self.db
            .reader()
            .map_err(|error| Error::Io(format!("localdb open reader: {error}")))
    }

    fn query_apps(&self, sql: &str, param: Option<&str>) -> Result<Vec<AppSummary>, Error> {
        let conn = self.reader()?;
        let mut statement = conn
            .prepare(sql)
            .map_err(|error| Error::Io(format!("localdb prepare: {error}")))?;
        let rows = match param {
            Some(value) => statement
                .query_map([value], row_to_summary)
                .map_err(|error| Error::Io(format!("localdb query: {error}")))?,
            None => statement
                .query_map([], row_to_summary)
                .map_err(|error| Error::Io(format!("localdb query: {error}")))?,
        };
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| Error::Io(format!("localdb row: {error}")))
    }

    pub(crate) fn list_page(
        &self,
        offset: u32,
        limit: u32,
    ) -> Result<(Vec<AppSummary>, usize), Error> {
        let conn = self.reader()?;
        let total: i64 = conn
            .query_row("SELECT COUNT(*) FROM apps", [], |row| row.get(0))
            .map_err(|error| Error::Io(format!("localdb count: {error}")))?;
        let mut statement = conn
            .prepare(&format!("{APP_COLUMNS} ORDER BY rowid LIMIT ?1 OFFSET ?2"))
            .map_err(|error| Error::Io(format!("localdb prepare: {error}")))?;
        let rows = statement
            .query_map(params![i64::from(limit), i64::from(offset)], row_to_summary)
            .map_err(|error| Error::Io(format!("localdb query: {error}")))?;
        let page = rows
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| Error::Io(format!("localdb row: {error}")))?;
        Ok((page, usize::try_from(total).unwrap_or(usize::MAX)))
    }

    fn load_app(&self, app_id: &str) -> Result<Option<AppSummary>, Error> {
        Ok(self
            .query_apps(&format!("{APP_COLUMNS} WHERE appId = ?1"), Some(app_id))?
            .into_iter()
            .next())
    }

    /// Fetches metadata for a GitHub-backed row, or `None` when the row has no
    /// owner/repo or no metadata port is attached.
    pub(crate) fn metadata_for(&self, app: &AppSummary) -> Result<Option<PackageMetadata>, Error> {
        if app.user.is_empty() || app.repositories.is_empty() {
            return Ok(None);
        }
        let Some(metadata_port) = &self.metadata else {
            return Ok(None);
        };
        metadata_port.fetch(&app.user, &app.repositories)
    }

    /// Queries the latest GitHub release for a GitHub-backed row.
    ///
    /// Dart wraps `GithubRestClient.releases` in a try/catch and treats any
    /// failure as an empty download list, so a channel error here degrades to
    /// `(vec![], None)` instead of failing the whole detail.
    pub(crate) fn github_release(&self, app: &AppSummary) -> (Vec<AppDownload>, Option<String>) {
        if app.user.is_empty() || app.repositories.is_empty() {
            return (Vec::new(), None);
        }
        let Some(api) = &self.api else {
            return (Vec::new(), None);
        };
        api.fetch_releases(&app.user, &app.repositories)
            .unwrap_or_default()
    }

    pub(crate) fn github_repo(&self, app: &AppSummary) -> Option<Map<String, Value>> {
        if app.user.is_empty() || app.repositories.is_empty() {
            return None;
        }
        let api = self.api.as_ref()?;
        let url = GitHubReleases::repo_url(&app.user, &app.repositories);
        api.get_value(&url)
            .ok()
            .and_then(|(_, value)| value.as_object().cloned())
    }

    pub(crate) fn github_readme(&self, app: &AppSummary) -> Option<String> {
        if app.user.is_empty() || app.repositories.is_empty() {
            return None;
        }
        let api = self.api.as_ref()?;
        api.fetch_readme(&app.user, &app.repositories)
            .ok()
            .flatten()
            .filter(|value| !value.trim().is_empty())
    }

    fn fts_search(&self, word: &str) -> Vec<AppSummary> {
        // Dart escapes quotes and uses a quoted prefix query: `"word"*`.
        let escaped = word.replace('"', "\"\"");
        let matcher = format!("\"{escaped}\"*");
        let sql = format!(
            "{APP_COLUMNS} WHERE rowid IN \
             (SELECT rowid FROM apps_fts WHERE apps_fts MATCH ?1) ORDER BY rowid"
        );
        let Ok(conn) = self.reader() else {
            return Vec::new();
        };
        let Ok(mut statement) = conn.prepare(&sql) else {
            return Vec::new();
        };
        let Ok(rows) = statement.query_map([&matcher], row_to_summary) else {
            return Vec::new();
        };
        // Dart swallows an unsupported FTS tokenizer and falls back to LIKE.
        rows.filter_map(Result::ok).collect()
    }

    fn like_search(&self, word: &str) -> Vec<AppSummary> {
        let pattern = format!("%{word}%");
        let sql = format!("{APP_COLUMNS} WHERE name LIKE ?1 OR des LIKE ?1 ORDER BY rowid");
        self.query_apps(&sql, Some(&pattern)).unwrap_or_default()
    }
}

pub(crate) const APP_COLUMNS: &str =
    "SELECT appId,name,user,repositories,icon,des,readme,category,extra FROM apps";

/// Repository-metadata icon path shared by the local catalog fallback and the
/// GStore channel's add/detail refresh (`.../{owner}@{repo}/icon.png`).
pub(crate) const METADATA_ICON_PREFIX: &str =
    "https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/metadata";

/// Maps one catalog `apps` row to a summary.
///
/// Icon fallback rule: when the stored `apps.icon` is empty and both `user`
/// and `repositories` are known, the row is given the repository-metadata icon
/// path (`.../metadata/{owner}@{repo}/icon.png`, the same convention as
/// `HttpMetadataPort::fetch` and Dart `MetadataRepository.iconUrl`). Every
/// non-empty stored icon is returned verbatim — no proxy rewriting, no query
/// stripping — so a `ghp.ci/`-prefixed URL survives untouched.
pub(crate) fn row_to_summary(row: &Row<'_>) -> rusqlite::Result<AppSummary> {
    let app_id: String = row.get(0)?;
    let name: String = row.get(1)?;
    let user: Option<String> = row.get(2)?;
    let repositories: Option<String> = row.get(3)?;
    let icon: Option<String> = row.get(4)?;
    let des: Option<String> = row.get(5)?;
    let readme: Option<String> = row.get(6)?;
    let category: Option<String> = row.get(7)?;
    let extra_raw: Option<String> = row.get(8)?;

    let extra = extra_raw
        .as_deref()
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok())
        .and_then(|value| value.as_object().cloned());
    let package_name = extra
        .as_ref()
        .and_then(|map| map.get("packageName"))
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);

    let user = user.unwrap_or_default();
    let repositories = repositories.unwrap_or_default();
    let icon = icon.filter(|value| !value.is_empty()).unwrap_or_else(|| {
        if user.is_empty() || repositories.is_empty() {
            String::new()
        } else {
            format!("{METADATA_ICON_PREFIX}/{user}@{repositories}/icon.png")
        }
    });
    let labels = summary_labels(&user, package_name.as_deref(), &repositories);

    Ok(AppSummary {
        app_id,
        package_name,
        name,
        user,
        repositories,
        icon,
        des: des.unwrap_or_default(),
        readme: readme.filter(|value| !value.is_empty()),
        // Dart `CategoryConverter.decode`: split(",") or [] for NULL.
        category: Some(
            category
                .as_deref()
                .map(|value| value.split(',').map(ToString::to_string).collect())
                .unwrap_or_default(),
        ),
        extra,
        labels,
    })
}

/// Returns a trimmed package name that looks valid (`a.b`), else `None`.
pub(crate) fn valid_package_name(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() || !value.contains('.') {
        return None;
    }
    Some(value.to_string())
}

/// Applies already-fetched metadata to a summary (`LocalDbChannel._applyMetadataOverride`).
pub(crate) fn apply_metadata_values(
    app: AppSummary,
    metadata: &PackageMetadata,
    keep_existing_package_name: bool,
) -> AppSummary {
    let override_package = valid_package_name(metadata.package_name.as_deref());
    let display_name = metadata
        .app_name
        .as_deref()
        .filter(|value| !value.is_empty())
        .unwrap_or(&app.name)
        .to_string();
    let icon = metadata
        .icon_url
        .as_deref()
        .filter(|value| !value.is_empty())
        .unwrap_or(&app.icon)
        .to_string();
    let package_name = if override_package.is_some() {
        override_package
    } else if keep_existing_package_name {
        app.package_name
    } else {
        None
    };
    let labels = summary_labels(&app.user, package_name.as_deref(), &app.repositories);
    AppSummary {
        package_name,
        name: display_name,
        icon,
        labels,
        ..app
    }
}

/// Everything a catalog-backed summary needs beyond itself to become a detail.
///
/// Shared by [`LocalDbDriver`] and the catalog fallback of the GStore channel so
/// both produce byte-identical detail bodies for the same row.
pub(crate) struct CatalogDetailSource<'a> {
    /// Channel kind stamped onto the detail.
    pub kind: ChannelKind,
    /// Already-fetched metadata override, if any.
    pub metadata: Option<&'a PackageMetadata>,
    /// GitHub release downloads for the row.
    pub downloads: Vec<AppDownload>,
    /// Latest GitHub release version, when it resolved.
    pub release_version: Option<String>,
    /// GitHub repository payload for stats/license/language/topics, when fetched.
    pub repo: Option<&'a Map<String, Value>>,
    /// GitHub README content, when fetched.
    pub readme: Option<String>,
}

pub(crate) fn build_app_detail(app: AppSummary, source: CatalogDetailSource<'_>) -> AppDetail {
    let version_name = source.metadata.and_then(|value| value.version_name.clone());
    let app = match source.metadata {
        Some(metadata) => apply_metadata_values(app, metadata, true),
        None => app,
    };

    // Dart `_fetchReadmeInternal` with no GitHub client falls back to the row
    // README and then to `des`.
    let readme = source
        .readme
        .clone()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| app.readme.clone().filter(|value| !value.trim().is_empty()));
    // Dart `LocalDbChannel.getAppDetail`: `metadataVersionName ?? latestVersion`.
    let version = version_name.or(source.release_version);

    let mut sections = Vec::new();
    if !source.downloads.is_empty() {
        sections.push(DetailSection::Version);
    }
    sections.push(DetailSection::Downloads);
    if readme.as_deref().is_some_and(|value| !value.is_empty()) {
        sections.push(DetailSection::Readme);
    }
    let developer = (!app.user.is_empty()).then(|| app.user.clone());
    let project_url = (!app.user.is_empty() && !app.repositories.is_empty())
        .then(|| format!("https://github.com/{}/{}", app.user, app.repositories));
    let labels = detail_labels(
        version.as_deref(),
        developer.as_deref(),
        app.package_name.as_deref(),
    );
    let mut extra = app.extra.clone().unwrap_or_default();
    if let Some(categories) = app
        .category
        .as_ref()
        .filter(|categories| !categories.is_empty())
    {
        extra.insert("categories".to_string(), serde_json::json!(categories));
        insert_info_tag(&mut extra, "categories", "分类", categories.join(" / "));
    }
    if let Some(repo) = source.repo {
        apply_repo_extra(&mut extra, repo);
    }
    if let Some(readme_text) = readme.as_deref().filter(|value| !value.trim().is_empty()) {
        extra.insert("readme".to_string(), Value::String(readme_text.to_string()));
    }

    AppDetail {
        app_id: app.app_id.clone(),
        name: app.name.clone(),
        icon: app.icon.clone(),
        description: app.des.clone(),
        version,
        developer,
        package_name: app.package_name.clone(),
        project_url,
        channel: source.kind,
        sections,
        downloads: source.downloads,
        extra,
        labels,
    }
}

impl ChannelDriver for LocalDbDriver {
    fn key(&self) -> &ChannelKey {
        &self.key
    }

    fn meta(&self) -> &ChannelMeta {
        &self.meta
    }

    fn initialize(&self) -> Result<(), Error> {
        self.initialized.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn is_initialized(&self) -> Result<bool, Error> {
        Ok(self.initialized.load(Ordering::SeqCst))
    }

    fn check_available(&self) -> Result<bool, Error> {
        // Dart probes `dao.getVersion()` inside try/catch.
        match self.get_config(true) {
            Ok(_) => Ok(true),
            Err(_) => Ok(false),
        }
    }

    fn get_all_apps(&self, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        self.query_apps(&format!("{APP_COLUMNS} ORDER BY rowid"), None)
    }

    /// Returns the stored row as a local snapshot.
    ///
    /// The list/info path is deliberately offline: it never calls
    /// [`LocalDbDriver::metadata_for`] or [`apply_metadata_values`]. Metadata is
    /// refreshed only on the detail page ([`LocalDbDriver::get_app_detail`]), so
    /// a catalog page costs one local query per row and no network.
    fn get_app_info(&self, app_id: &str, _force_refresh: bool) -> Result<AppSummary, Error> {
        self.load_app(app_id)?
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))
    }

    fn get_app_detail(&self, app_id: &str, _force_refresh: bool) -> Result<AppDetail, Error> {
        let mut app = self
            .load_app(app_id)?
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))?;
        // README is fetched progressively after the detail payload.
        app.readme = None;
        let metadata = self.metadata_for(&app)?;
        let (downloads, release_version) = self.github_release(&app);
        let repo = self.github_repo(&app);
        Ok(build_app_detail(
            app,
            CatalogDetailSource {
                kind: self.meta.kind,
                metadata: metadata.as_ref(),
                downloads,
                release_version,
                repo: repo.as_ref(),
                readme: None,
            },
        ))
    }

    fn supports_progressive_loading(&self) -> Result<bool, Error> {
        Ok(true)
    }

    fn fetch_downloads(&self, app_id: &str) -> Result<Vec<AppDownload>, Error> {
        self.load_app(app_id)?
            .map(|_| Vec::new())
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))
    }

    fn fetch_readme(&self, app_id: &str) -> Result<Option<String>, Error> {
        let app = self
            .load_app(app_id)?
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))?;
        let fallback = (!app.des.is_empty()).then_some(app.des.clone());
        Ok(self
            .github_readme(&app)
            .or_else(|| app.readme.filter(|value| !value.is_empty()))
            .or(fallback))
    }

    fn fetch_statistics(
        &self,
        app_id: &str,
    ) -> Result<Option<serde_json::Map<String, serde_json::Value>>, Error> {
        Ok(self
            .load_app(app_id)?
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))?
            .extra)
    }

    fn check_app_update(&self, app_id: &str) -> Result<AppUpdate, Error> {
        let detail = self.get_app_detail(app_id, false)?;
        Ok(AppUpdate {
            app_id: detail.app_id.clone(),
            package_name: detail.package_name.clone().unwrap_or_default(),
            name: detail.name.clone(),
            icon: Some(detail.icon.clone()),
            latest_version: detail.version.clone(),
            latest_download: detail.downloads.first().cloned(),
            detail,
        })
    }

    fn add_app(&self, _app: &AppSummary) -> Result<(), Error> {
        // Dart: `本地数据库渠道不支持手动添加应用`.
        Err(Error::Unsupported(
            "local database channel does not support adding apps".to_string(),
        ))
    }

    fn remove_app(&self, _app_id: &str) -> Result<(), Error> {
        // Dart: `本地数据库渠道不支持移除应用`.
        Err(Error::Unsupported(
            "local database channel does not support removing apps".to_string(),
        ))
    }

    fn search_apps(&self, keyword: &str, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        if keyword.is_empty() {
            // Dart `search` short-circuits to `const []`.
            return Ok(Vec::new());
        }
        let mut results = self.fts_search(keyword);
        let fts_ids: std::collections::HashSet<String> =
            results.iter().map(|app| app.app_id.clone()).collect();
        for app in self.like_search(keyword) {
            if !fts_ids.contains(&app.app_id) {
                results.push(app);
            }
        }
        Ok(results)
    }

    fn search_by_category(
        &self,
        category_id: &str,
        _force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        let pattern = format!("%{category_id}%");
        self.query_apps(
            &format!("{APP_COLUMNS} WHERE category LIKE ?1 ORDER BY rowid"),
            Some(&pattern),
        )
    }

    fn get_all_categories(&self, _force_refresh: bool) -> Result<Vec<ChannelCategory>, Error> {
        let conn = self.reader()?;
        let mut statement = conn
            .prepare("SELECT id,description,icon FROM categories ORDER BY rowid")
            .map_err(|error| Error::Io(format!("localdb categories: {error}")))?;
        let rows = statement
            .query_map([], |row| {
                Ok(ChannelCategory {
                    id: row.get(0)?,
                    description: row.get(1)?,
                    icon: row.get(2)?,
                })
            })
            .map_err(|error| Error::Io(format!("localdb categories: {error}")))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| Error::Io(format!("localdb category row: {error}")))
    }

    fn check_update(&self) -> Result<bool, Error> {
        // Dart compares the global DB updater result; this read-only driver
        // reports "no update" rather than arming a write path it cannot run.
        Ok(false)
    }

    fn do_update(&self, _progress: Option<&mut dyn FnMut(u64, u64)>) -> Result<bool, Error> {
        Err(Error::Unsupported(
            "local database channel does not own the catalog update loop".to_string(),
        ))
    }

    fn get_config(&self, _force_refresh: bool) -> Result<Option<ChannelConfig>, Error> {
        let conn = self.reader()?;
        conn.query_row(
            "SELECT version,proxy FROM app_config ORDER BY rowid DESC LIMIT 1",
            [],
            |row| {
                Ok(ChannelConfig {
                    version: row.get(0)?,
                    proxy: row.get(1)?,
                })
            },
        )
        .optional()
        .map_err(|error| Error::Io(format!("localdb config: {error}")))
    }

    fn clear_cache(&self) -> Result<(), Error> {
        Ok(())
    }

    fn get_cache_size(&self) -> Result<u64, Error> {
        Ok(0)
    }

    fn dispose(&self) -> Result<(), Error> {
        self.initialized.store(false, Ordering::SeqCst);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    use super::*;
    use crate::ports::FakeMetadataPort;

    static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "gstore_core_localdb_{tag}_{}_{}",
                std::process::id(),
                n
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    const APP_ID: &str = "com.example.snapshot";

    fn channel_meta() -> ChannelMeta {
        ChannelMeta {
            kind: ChannelKind::LocalDb,
            name: "LocalDB".to_string(),
            description: "LocalDb channel".to_string(),
            enabled: true,
            priority: 10,
            support_offline: true,
            last_update_time: None,
            version: Some("1".to_string()),
        }
    }

    /// Seeds one catalog row with a non-empty `user`/`repositories`, so the old
    /// info path would have called [`LocalDbDriver::metadata_for`] and fetched.
    fn seeded_driver() -> (TempDir, LocalDbDriver, FakeMetadataPort) {
        let dir = TempDir::new("snapshot");
        let db = DbHandle::open(dir.path()).unwrap();
        db.with_writer(|conn| {
            conn.execute(
                "INSERT INTO apps(appId,name,user,repositories,icon,des,readme,category,extra) \
                 VALUES (?1,'Stored Snapshot','acme','snap','https://icons.test/stored.png',\
                 'stored description','# Stored','TOOLS','{\"packageName\":\"com.example.stored\"}')",
                rusqlite::params![APP_ID],
            )
            .map_err(|error| crate::db::DbError(error.to_string()))?;
            Ok(())
        })
        .unwrap();

        let metadata = FakeMetadataPort::new();
        metadata.set(
            "acme",
            "snap",
            Some(PackageMetadata {
                package_name: Some("com.example.meta".to_string()),
                app_name: Some("Metadata Name".to_string()),
                icon_url: Some("https://icons.test/meta.png".to_string()),
                version_name: Some("9.9.9".to_string()),
            }),
        );
        let driver = LocalDbDriver::new(ChannelKey::new("local_db").unwrap(), channel_meta(), db)
            .with_metadata(Arc::new(metadata.clone()));
        (dir, driver, metadata)
    }

    /// Seeds one catalog row with explicit icon/owner/repo values.
    fn seeded_icon_driver(
        tag: &str,
        icon: &str,
        user: &str,
        repositories: &str,
    ) -> (TempDir, LocalDbDriver) {
        let dir = TempDir::new(tag);
        let db = DbHandle::open(dir.path()).unwrap();
        db.with_writer(|conn| {
            conn.execute(
                "INSERT INTO apps(appId,name,user,repositories,icon,des,readme,category,extra) \
                 VALUES ('com.example.icon','Icon Row',?1,?2,?3,'des',NULL,'TOOLS',NULL)",
                rusqlite::params![user, repositories, icon],
            )
            .map_err(|error| crate::db::DbError(error.to_string()))?;
            Ok(())
        })
        .unwrap();
        let driver = LocalDbDriver::new(ChannelKey::new("local_db").unwrap(), channel_meta(), db);
        (dir, driver)
    }

    #[test]
    fn row_icon_falls_back_to_metadata_path_when_empty() {
        let (_dir, driver) = seeded_icon_driver("icon_empty", "", "acme", "snap");

        let info = driver.get_app_info("com.example.icon", false).unwrap();

        assert_eq!(
            info.icon,
            "https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/metadata/acme@snap/icon.png"
        );
    }

    #[test]
    fn row_icon_is_kept_verbatim_when_present() {
        let stored = "https://ghp.ci/raw.githubusercontent.com/sunO2/GStore-Repositorys/main/metadata/acme@snap/icon.png";
        let (_dir, driver) = seeded_icon_driver("icon_present", stored, "acme", "snap");

        let info = driver.get_app_info("com.example.icon", false).unwrap();

        assert_eq!(info.icon, stored, "a non-empty icon must not be rewritten");
    }

    #[test]
    fn row_icon_stays_empty_without_owner_repo() {
        let (_dir, driver) = seeded_icon_driver("icon_no_owner", "", "", "");

        let info = driver.get_app_info("com.example.icon", false).unwrap();

        assert_eq!(
            info.icon, "",
            "without owner/repo there is no fallback path"
        );
    }

    #[test]
    fn get_app_info_makes_no_metadata_call() {
        let (_dir, driver, metadata) = seeded_driver();

        let info = driver.get_app_info(APP_ID, false).unwrap();

        assert_eq!(
            metadata.fetch_count(),
            0,
            "the info/list path must never fetch metadata"
        );
        assert_eq!(info.app_id, APP_ID);
        assert_eq!(info.name, "Stored Snapshot");
        assert_eq!(info.icon, "https://icons.test/stored.png");
        assert_eq!(info.package_name.as_deref(), Some("com.example.stored"));
        assert_eq!(info.des, "stored description");
    }

    #[test]
    fn get_app_detail_still_fetches_metadata() {
        let (_dir, driver, metadata) = seeded_driver();

        let detail = driver.get_app_detail(APP_ID, false).unwrap();

        assert_eq!(
            metadata.fetch_count(),
            1,
            "the detail page refreshes metadata exactly once"
        );
        assert_eq!(detail.name, "Metadata Name");
        assert_eq!(detail.icon, "https://icons.test/meta.png");
        assert_eq!(detail.version.as_deref(), Some("9.9.9"));
        assert_eq!(detail.package_name.as_deref(), Some("com.example.meta"));
    }
}
