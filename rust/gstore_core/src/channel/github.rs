//! GitHub channel driver (Wave 1, Todo 10).
//!
//! Network access goes exclusively through [`HttpPort`]; this crate never links
//! an HTTP client. `CoreConfig` supplies the proxy and token, and
//! [`MetadataPort`] (usually wrapped in `CachedMetadataPort`) supplies the
//! package/app-name/icon overrides with the 24h cache owned by the port.
//!
//! Dart parity sources:
//! * list: `GitHubChannel.getAllApps` (`GitHubChannel.dart:92-126`) reads the
//!   channel's stored apps, ordered by `addTime DESC`.
//! * info: `GitHubChannel.getAppInfo` (`:129-227`) — stored hit first, then
//!   `GET /repos/{owner}/{repo}`, with metadata overrides.
//! * search: `GitHubChannel.searchApps` (`:230-291`) — ex has/Accept/UA.
//! * canonical id: `GitHubChannel.canonicalAppId` (`:295-313`).
//! * add/remove: `GitHubChannel.addApp`/`removeApp` (`:316-389`).
//!
//! Tokens and proxy credentials are never interpolated into an error message.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::Row;
use serde_json::{Map, Value};

use super::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use super::github_releases::{api_error, optional_string, GitHubReleases};
use super::sealed;
use crate::db::DbHandle;
use crate::dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelMeta, DetailSection,
    detail_labels, summary_labels,
};
use crate::error::Error;
use crate::ports::config::CoreConfig;
use crate::ports::http::HttpPort;
use crate::ports::metadata::{MetadataPort, PackageMetadata};

const GITHUB_API: &str = "https://api.github.com";
const PER_PAGE: u32 = 30;

/// GitHub channel driver bound to one [`ChannelKey`].
pub struct GitHubDriver {
    key: ChannelKey,
    meta: ChannelMeta,
    db: DbHandle,
    api: GitHubReleases,
    metadata: Arc<dyn MetadataPort>,
    initialized: AtomicBool,
}

impl sealed::Sealed for GitHubDriver {}

#[derive(Debug, Clone)]
struct StoredApp {
    app_id: String,
    name: String,
    user: String,
    repositories: String,
    icon: String,
    description: String,
    category: Option<String>,
    extra_raw: Option<String>,
}

impl StoredApp {
    fn normalized(mut self) -> Self {
        // Dart `normalizeStoredRecord`: a historical bug stored the full
        // `owner/repo` in `repositories`; split it back only for exactly one
        // slash (GitHub repository names cannot contain '/', so this is safe).
        if self.repositories.matches('/').count() == 1 {
            if let Some((user, repo)) = self.repositories.split_once('/') {
                self.user = user.to_string();
                self.repositories = repo.to_string();
            }
        }
        self
    }

    fn extra(&self) -> Option<Map<String, Value>> {
        self.extra_raw
            .as_deref()
            .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
            .and_then(|value| value.as_object().cloned())
    }

    fn package_name(&self) -> Option<String> {
        self.extra()
            .as_ref()
            .and_then(|map| map.get("packageName"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    }

    fn to_summary(&self) -> AppSummary {
        let package_name = self.package_name();
        AppSummary {
            app_id: self.app_id.clone(),
            package_name: package_name.clone(),
            name: self.name.clone(),
            user: self.user.clone(),
            repositories: self.repositories.clone(),
            icon: self.icon.clone(),
            des: self.description.clone(),
            readme: None,
            // Dart `ChannelAddedApp.category?.split(',')`.
            category: self
                .category
                .as_deref()
                .map(|value| value.split(',').map(ToString::to_string).collect()),
            extra: self.extra(),
            labels: summary_labels(&self.user, package_name.as_deref(), &self.repositories),
        }
    }
}

fn stored_from_row(row: &Row<'_>) -> rusqlite::Result<StoredApp> {
    Ok(StoredApp {
        app_id: row.get(0)?,
        name: row.get(1)?,
        user: row.get(2)?,
        repositories: row.get(3)?,
        icon: row.get(4)?,
        description: row.get(5)?,
        category: row.get(6)?,
        extra_raw: row.get(7)?,
    })
}

impl GitHubDriver {
    /// Creates a driver bound to `key`.
    pub fn new(
        key: ChannelKey,
        meta: ChannelMeta,
        db: DbHandle,
        config: CoreConfig,
        http: Arc<dyn HttpPort>,
        metadata: Arc<dyn MetadataPort>,
    ) -> Self {
        Self {
            key,
            meta,
            db,
            api: GitHubReleases::new(config, http),
            metadata,
            initialized: AtomicBool::new(false),
        }
    }

    fn reader(&self) -> Result<rusqlite::Connection, Error> {
        self.db
            .reader()
            .map_err(|error| Error::Io(format!("github open reader: {error}")))
    }

    fn load_stored(&self) -> Result<Vec<StoredApp>, Error> {
        let conn = self.reader()?;
        let mut statement = conn
            .prepare(
                "SELECT app_id,name,user,repositories,icon,description,category,extra \
                 FROM channel_apps WHERE channel_key = ?1 ORDER BY add_time DESC, app_id ASC",
            )
            .map_err(|error| Error::Io(format!("github prepare stored apps: {error}")))?;
        let rows = statement
            .query_map([self.key.as_str()], stored_from_row)
            .map_err(|error| Error::Io(format!("github stored apps: {error}")))?;
        let loaded = rows
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| Error::Io(format!("github stored row: {error}")))?;
        Ok(loaded.into_iter().map(StoredApp::normalized).collect())
    }

    fn find_stored(&self, app_id: &str) -> Result<Option<StoredApp>, Error> {
        Ok(self
            .load_stored()?
            .into_iter()
            .find(|stored| stored.app_id == app_id))
    }

    fn find_stored_containing(&self, app_id: &str) -> Result<Option<StoredApp>, Error> {
        // Dart falls back to `record.extra.contains(appId)` for package-name
        // app ids that have no owner/repo shape.
        Ok(self.load_stored()?.into_iter().find(|stored| {
            stored
                .extra_raw
                .as_deref()
                .is_some_and(|raw| raw.contains(app_id))
        }))
    }

    /// Builds the summary for one stored channel row without touching the
    /// network.
    ///
    /// The row is the snapshot written by [`Self::add_app`] at add time (and
    /// refreshed by [`Self::get_app_detail`] when the detail page opens), so
    /// the list and info read paths never re-fetch metadata. The only change
    /// applied here is icon stability; see [`stable_stored_icon`].
    fn build_stored_info(&self, stored: StoredApp) -> Result<AppSummary, Error> {
        let mut summary = stored.to_summary();
        summary.icon = stable_stored_icon(&summary.icon, &summary.user, &summary.repositories);
        Ok(summary)
    }

    /// Merges freshly fetched metadata into the detail summary and persists the
    /// refreshed `name`/`icon`/`extra` on the stored row.
    ///
    /// The merge reuses [`apply_metadata`] with the add-time rules, so the
    /// detail response, the stored snapshot, and a fresh [`Self::add_app`] agree
    /// on name/icon/package/labels. The write is a targeted `UPDATE` (never
    /// `INSERT OR REPLACE`), which leaves `add_time`, `description`, `category`
    /// and every other column untouched; a missing row is a no-op. `extra` is
    /// merged key-by-key: `packageName` is replaced only when the metadata
    /// carries a valid package name, and all remaining keys survive.
    fn apply_detail_refresh(
        &self,
        info: AppSummary,
        metadata: PackageMetadata,
        stored: &StoredApp,
    ) -> Result<AppSummary, Error> {
        let fresh_package = valid_package_name(metadata.package_name.as_deref());
        let refreshed = apply_metadata(info, metadata, true);

        let mut extra = stored.extra().unwrap_or_default();
        if let Some(package_name) = fresh_package.as_deref() {
            extra.insert(
                "packageName".to_string(),
                Value::String(package_name.to_string()),
            );
        }
        let extra = if extra.is_empty() {
            None
        } else {
            Some(Value::Object(extra).to_string())
        };

        // `apply_metadata` only substitutes non-empty metadata values, so these
        // fall back to the stored row and never blank a good value.
        let name = refreshed.name.clone();
        let icon = refreshed.icon.clone();
        let app_id = refreshed.app_id.clone();
        self.db
            .with_writer(|conn| {
                conn.execute(
                    "UPDATE channel_apps SET name = ?3, icon = ?4, extra = ?5 \
                     WHERE channel_key = ?1 AND app_id = ?2",
                    rusqlite::params![self.key.as_str(), app_id, name, icon, extra],
                )
                .map_err(|error| crate::db::DbError(error.to_string()))?;
                Ok(())
            })
            .map_err(|error| Error::Io(format!("github detail refresh: {error}")))?;
        Ok(refreshed)
    }

    fn apply_metadata_for_info(&self, app: AppSummary) -> Result<AppSummary, Error> {
        let Some(metadata) = self.metadata.fetch(&app.user, &app.repositories)? else {
            return Ok(app);
        };
        Ok(apply_metadata(app, metadata, false))
    }
}

impl ChannelDriver for GitHubDriver {
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
        Ok(self.initialized.load(Ordering::SeqCst))
    }

    fn get_all_apps(&self, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        Ok(self
            .load_stored()?
            .iter()
            .map(StoredApp::to_summary)
            .collect())
    }

    fn get_app_info(&self, app_id: &str, _force_refresh: bool) -> Result<AppSummary, Error> {
        if let Some(stored) = self.find_stored(app_id)? {
            return self.build_stored_info(stored);
        }

        let parts: Vec<&str> = app_id.split('/').collect();
        if parts.len() != 2 {
            // Dart reverse-looks-up a package-name app id in channel records.
            if let Some(stored) = self.find_stored_containing(app_id)? {
                return self.build_stored_info(stored);
            }
            return Err(Error::NotFound(format!("app not found: {app_id}")));
        }
        let (user, repo) = (parts[0], parts[1]);
        let url = GitHubReleases::repo_url(user, repo);
        let (status, value) = self.api.get_value(&url)?;
        let object = value
            .as_object()
            .ok_or_else(|| api_error(status, &url, "expected a JSON object".to_string()))?;
        let full_name = optional_string(object, "full_name", status, &url)?;
        let name = full_name
            .as_deref()
            .and_then(|value| value.split('/').next_back())
            .filter(|value| !value.is_empty())
            .unwrap_or(repo)
            .to_string();
        let description = optional_string(object, "description", status, &url)?
            .filter(|value| !value.is_empty())
            .unwrap_or_default();

        let app = AppSummary {
            app_id: app_id.to_string(),
            package_name: None,
            name,
            user: user.to_string(),
            repositories: repo.to_string(),
            icon: String::new(),
            des: description,
            readme: None,
            category: None,
            extra: None,
            labels: summary_labels(user, None, repo),
        };
        self.apply_metadata_for_info(app)
    }

    fn get_app_detail(&self, app_id: &str, force_refresh: bool) -> Result<AppDetail, Error> {
        let mut info = self.get_app_info(app_id, force_refresh)?;
        // A stored row is a snapshot taken when the app was added; opening the
        // detail page refreshes it exactly once and writes the result back so
        // the next local read is current. Non-stored ids already went through
        // `apply_metadata_for_info` in `get_app_info`, so they must not trigger
        // a second metadata lookup.
        if let Some(stored) = self.find_stored(&info.app_id)? {
            if !info.user.is_empty() && !info.repositories.is_empty() {
                if let Some(metadata) = self.metadata.fetch(&info.user, &info.repositories)? {
                    info = self.apply_detail_refresh(info, metadata, &stored)?;
                }
            }
        }
        let url = GitHubReleases::repo_url(&info.user, &info.repositories);
        let (status, repo_value) = self.api.get_value(&url)?;
        let repo = repo_value
            .as_object()
            .ok_or_else(|| api_error(status, &url, "expected a JSON object".to_string()))?;
        let (downloads, version) = self.api.fetch_releases(&info.user, &info.repositories)?;
        let readme = self.api.fetch_readme(&info.user, &info.repositories)?;

        let mut sections = Vec::new();
        if repo.get("stargazers_count").is_some() || repo.get("forks").is_some() {
            sections.push(DetailSection::Statistics);
        }
        if !downloads.is_empty() {
            sections.push(DetailSection::Version);
        }
        sections.push(DetailSection::Downloads);
        if readme.as_deref().is_some_and(|value| !value.is_empty()) {
            sections.push(DetailSection::Readme);
        }

        // `AppDetail` has no readme/statistics fields; the shared Dart detail view
        // reads `extra["readme"]` and `extra["apiData"]`, so emit both here.
        let mut extra = info.extra.clone().unwrap_or_default();
        if let Some(readme_text) = readme.as_deref().filter(|value| !value.is_empty()) {
            extra.insert("readme".to_string(), Value::String(readme_text.to_string()));
        }
        let mut api_data = Map::new();
        for key in ["stargazers_count", "watchers_count", "forks_count"] {
            if let Some(value) = repo.get(key) {
                api_data.insert(key.to_string(), value.clone());
            }
        }
        if !api_data.is_empty() {
            extra.insert("apiData".to_string(), Value::Object(api_data));
        }

        let developer = (!info.user.is_empty()).then(|| info.user.clone());
        let labels = detail_labels(
            version.as_deref(),
            developer.as_deref(),
            info.package_name.as_deref(),
        );
        Ok(AppDetail {
            app_id: info.app_id.clone(),
            name: info.name.clone(),
            icon: info.icon.clone(),
            description: info.des.clone(),
            version,
            developer,
            package_name: info.package_name.clone(),
            project_url: optional_string(repo, "html_url", status, &url)?,
            channel: self.meta.kind,
            sections,
            downloads,
            extra,
            labels,
        })
    }

    fn supports_progressive_loading(&self) -> Result<bool, Error> {
        Ok(true)
    }

    fn fetch_downloads(&self, app_id: &str) -> Result<Vec<AppDownload>, Error> {
        let info = self.get_app_info(app_id, false)?;
        Ok(self.api.fetch_releases(&info.user, &info.repositories)?.0)
    }

    fn fetch_readme(&self, app_id: &str) -> Result<Option<String>, Error> {
        let info = self.get_app_info(app_id, false)?;
        self.api.fetch_readme(&info.user, &info.repositories)
    }

    fn fetch_statistics(&self, app_id: &str) -> Result<Option<Map<String, Value>>, Error> {
        let info = self.get_app_info(app_id, false)?;
        let url = GitHubReleases::repo_url(&info.user, &info.repositories);
        let (status, value) = self.api.get_value(&url)?;
        let repo = value
            .as_object()
            .ok_or_else(|| api_error(status, &url, "expected a JSON object".to_string()))?;
        let mut statistics = Map::new();
        for key in [
            "stargazers_count",
            "forks",
            "default_branch",
            "html_url",
            "full_name",
            "description",
            "created_at",
        ] {
            if let Some(value) = repo.get(key) {
                statistics.insert(key.to_string(), value.clone());
            }
        }
        Ok(Some(statistics))
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

    fn add_app(&self, app: &AppSummary) -> Result<(), Error> {
        let parts: Vec<&str> = app.app_id.split('/').collect();
        let owner = if app.user.is_empty() {
            parts.first().copied().unwrap_or_default()
        } else {
            app.user.as_str()
        };
        let repo = if parts.len() == 2 {
            parts[1]
        } else {
            app.repositories.as_str()
        };

        let mut icon = app.icon.clone();
        let mut package_name = None;
        let mut name = app.name.clone();
        if !owner.is_empty() && !repo.is_empty() {
            if let Some(metadata) = self.metadata.fetch(owner, repo)? {
                icon = metadata
                    .icon_url
                    .as_deref()
                    .filter(|value| !value.is_empty())
                    .unwrap_or(&icon)
                    .to_string();
                package_name = valid_package_name(metadata.package_name.as_deref());
                if let Some(metadata_name) = metadata
                    .app_name
                    .as_deref()
                    .filter(|value| !value.is_empty())
                {
                    name = metadata_name.to_string();
                }
            }
        }

        // Dart: `parts.length == 2 ? appId : (appId.contains('/') ? appId : null)`.
        let apprepo = app.app_id.contains('/').then(|| app.app_id.clone());
        let extra = package_name
            .as_ref()
            .map(|package_name| serde_json::json!({ "packageName": package_name }).to_string());
        let add_time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as i64)
            .unwrap_or(0);

        self.db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT OR REPLACE INTO channel_apps(channel_key,app_id,name,user,repositories,\
                     apprepo,icon,description,category,add_time,extra) \
                     VALUES (?1,?2,?3,?4,?5,?6,?7,?8,NULL,?9,?10)",
                    rusqlite::params![
                        self.key.as_str(),
                        app.app_id,
                        name,
                        owner,
                        repo,
                        apprepo,
                        icon,
                        app.des,
                        add_time,
                        extra
                    ],
                )
                .map_err(|error| crate::db::DbError(error.to_string()))?;
                Ok(())
            })
            .map_err(|error| Error::Io(format!("github add app: {error}")))
    }

    fn canonical_app_id(&self, app: &AppSummary) -> Result<String, Error> {
        let parts: Vec<&str> = app.app_id.split('/').collect();
        let owner_repo = if parts.len() == 2 {
            Some((parts[0], parts[1]))
        } else if !app.user.is_empty() && !app.repositories.is_empty() {
            Some((app.user.as_str(), app.repositories.as_str()))
        } else {
            None
        };
        let Some((owner, repo)) = owner_repo else {
            return Ok(app.app_id.clone());
        };
        // Dart: metadata == null -> appInfo.appId; valid package name -> package.
        let Some(metadata) = self.metadata.fetch(owner, repo)? else {
            return Ok(app.app_id.clone());
        };
        Ok(valid_package_name(metadata.package_name.as_deref())
            .unwrap_or_else(|| app.app_id.clone()))
    }

    fn remove_app(&self, app_id: &str) -> Result<(), Error> {
        // Dart `removeApp` issues a DELETE and reports success even for a
        // missing row; it never turns a missing id into an error.
        self.db
            .with_writer(|conn| {
                conn.execute(
                    "DELETE FROM channel_apps WHERE channel_key = ?1 AND app_id = ?2",
                    rusqlite::params![self.key.as_str(), app_id],
                )
                .map_err(|error| crate::db::DbError(error.to_string()))?;
                Ok(())
            })
            .map_err(|error| Error::Io(format!("github remove app: {error}")))
    }

    fn search_apps(&self, keyword: &str, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        let query = format!("{keyword} in:name,description,readme");
        let url = format!(
            "{GITHUB_API}/search/repositories?q={}&per_page={PER_PAGE}",
            encode_component(&query)
        );
        let (status, value) = self.api.get_value(&url)?;
        let object = value
            .as_object()
            .ok_or_else(|| api_error(status, &url, "expected a JSON object".to_string()))?;
        let items = match object.get("items") {
            None => return Ok(Vec::new()),
            Some(value) => value.as_array().ok_or_else(|| {
                api_error(status, &url, "search items must be an array".to_string())
            })?,
        };
        let mut apps = Vec::with_capacity(items.len());
        for item in items {
            let item = item.as_object().ok_or_else(|| {
                api_error(status, &url, "search item must be an object".to_string())
            })?;
            let full_name = optional_string(item, "full_name", status, &url)?.unwrap_or_default();
            let owner = match item.get("owner") {
                None => None,
                Some(value) => Some(value.as_object().ok_or_else(|| {
                    api_error(status, &url, "search owner must be an object".to_string())
                })?),
            };
            let user = match owner {
                Some(owner) => optional_string(owner, "login", status, &url)?.unwrap_or_default(),
                None => String::new(),
            };
            let avatar = match owner {
                Some(owner) => {
                    optional_string(owner, "avatar_url", status, &url)?.unwrap_or_default()
                }
                None => String::new(),
            };
            let repositories = full_name
                .split('/')
                .next_back()
                .unwrap_or_default()
                .to_string();
            let labels = summary_labels(&user, None, &repositories);
            apps.push(AppSummary {
                app_id: full_name.clone(),
                package_name: None,
                name: optional_string(item, "name", status, &url)?
                    .unwrap_or_else(|| full_name.clone()),
                user,
                repositories,
                icon: avatar,
                des: optional_string(item, "description", status, &url)?.unwrap_or_default(),
                readme: None,
                category: None,
                extra: None,
                labels,
            });
        }
        Ok(apps)
    }

    fn search_by_category(
        &self,
        category_id: &str,
        force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        Ok(self
            .get_all_apps(force_refresh)?
            .into_iter()
            .filter(|app| {
                app.category
                    .as_ref()
                    .is_some_and(|categories| categories.iter().any(|id| id == category_id))
            })
            .collect())
    }

    fn get_all_categories(&self, _force_refresh: bool) -> Result<Vec<ChannelCategory>, Error> {
        Ok(Vec::new())
    }

    fn check_update(&self) -> Result<bool, Error> {
        Ok(false)
    }

    fn do_update(&self, _progress: Option<&mut dyn FnMut(u64, u64)>) -> Result<bool, Error> {
        // Dart GitHubChannel.doUpdate returns success; GitHub data is always live.
        Ok(true)
    }

    fn get_config(&self, _force_refresh: bool) -> Result<Option<ChannelConfig>, Error> {
        Ok(Some(ChannelConfig {
            version: "0.0.0".to_string(),
            proxy: None,
        }))
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

/// Returns a stored icon URL that can be relied on across releases.
///
/// * An empty stored icon falls back to the repository-metadata path when the
///   owner and repo are known, so a row added before metadata had an icon still
///   renders one.
/// * A `sunO2/GStore-Repositorys` metadata URL carrying the `?r=<fingerprint>`
///   cache-buster is reduced to scheme/host/path. The fingerprint changes with
///   every icon update, so a stale fingerprinted URL can 404 once the Actions
///   job rewrites the file, while the bare path stays valid.
/// * Any other URL (an avatar, an absolute CDN URL, ...) is returned verbatim.
fn stable_stored_icon(icon: &str, owner: &str, repo: &str) -> String {
    const METADATA_PREFIX: &str = "https://raw.githubusercontent.com/sunO2/GStore-Repositorys/";
    if icon.is_empty() {
        if owner.is_empty() || repo.is_empty() {
            return String::new();
        }
        return format!("{METADATA_PREFIX}main/metadata/{owner}@{repo}/icon.png");
    }
    if icon.starts_with(METADATA_PREFIX) {
        if let Some((path, _query)) = icon.split_once('?') {
            return path.to_string();
        }
    }
    icon.to_string()
}

fn apply_metadata(
    app: AppSummary,
    metadata: PackageMetadata,
    keep_existing_package_name: bool,
) -> AppSummary {
    let package_name = valid_package_name(metadata.package_name.as_deref());
    let name = metadata
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
    let package_name = if package_name.is_some() {
        package_name
    } else if keep_existing_package_name {
        app.package_name
    } else {
        None
    };
    let labels = summary_labels(&app.user, package_name.as_deref(), &app.repositories);
    AppSummary {
        package_name,
        name,
        icon,
        labels,
        ..app
    }
}

fn valid_package_name(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() || !value.contains('.') {
        return None;
    }
    Some(value.to_string())
}

/// Dart `Uri.encodeComponent` compatible percent-encoding for the search query.
fn encode_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        let unreserved = byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(byte);
        if unreserved {
            encoded.push(char::from(*byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    use crate::dto::{summary_labels, ChannelKind};
    use crate::ports::{CoreConfig, FakeHttpPort, FakeMetadataPort, HttpResponse};

    use super::*;

    const APP_ID: &str = "acme/repo";

    static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "gstore_core_github_{tag}_{}_{}",
                std::process::id(),
                n
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn channel_meta() -> ChannelMeta {
        ChannelMeta {
            kind: ChannelKind::Github,
            name: "GitHubAPI".to_string(),
            description: "GitHub channel".to_string(),
            enabled: true,
            priority: 0,
            support_offline: true,
            last_update_time: None,
            version: Some("1".to_string()),
        }
    }

    fn driver(
        db: &DbHandle,
        http: Arc<FakeHttpPort>,
        metadata: Arc<FakeMetadataPort>,
    ) -> GitHubDriver {
        GitHubDriver::new(
            ChannelKey::new("github").unwrap(),
            channel_meta(),
            db.clone(),
            CoreConfig::default(),
            http,
            metadata,
        )
    }

    /// Seeds one stored GitHub row; `extra` is the raw JSON column.
    fn seed_row(
        db: &DbHandle,
        app_id: &str,
        name: &str,
        icon: &str,
        description: &str,
        add_time: i64,
        extra: Option<&str>,
    ) {
        db.with_writer(|conn| {
            conn.execute(
                "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,apprepo,\
                 icon,description,category,add_time,extra) \
                 VALUES ('github',?1,?2,'acme','repo',?1,?3,?4,NULL,?5,?6)",
                rusqlite::params![app_id, name, icon, description, add_time, extra],
            )
            .map_err(|error| crate::db::DbError(error.to_string()))?;
            Ok(())
        })
        .unwrap();
    }

    /// Reads `(add_time, description, extra, name, icon)` for one stored row.
    fn stored_row(
        db: &DbHandle,
        app_id: &str,
    ) -> (i64, String, Option<String>, String, String) {
        let conn = db.reader().unwrap();
        conn.query_row(
            "SELECT add_time,description,extra,name,icon FROM channel_apps \
             WHERE channel_key = 'github' AND app_id = ?1",
            [app_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .unwrap()
    }

    fn metadata_new() -> PackageMetadata {
        PackageMetadata {
            package_name: Some("com.example.new".to_string()),
            app_name: Some("New Name".to_string()),
            icon_url: Some("https://new.test/icon.png".to_string()),
            version_name: None,
        }
    }

    fn push_json(http: &FakeHttpPort, body: &str) {
        http.push_response(HttpResponse {
            status: 200,
            headers: Vec::new(),
            body: body.as_bytes().to_vec(),
        });
    }

    /// Queues the three responses `get_app_detail` needs after the metadata
    /// refresh: repo JSON, an empty releases array, and an empty README object.
    fn push_detail_responses(http: &FakeHttpPort) {
        push_json(
            http,
            r#"{"full_name":"acme/repo","html_url":"https://github.com/acme/repo"}"#,
        );
        push_json(http, "[]");
        push_json(http, "{}");
    }

    #[test]
    fn build_stored_info_makes_no_metadata_call() {
        let dir = TempDir::new("no_metadata");
        let db = DbHandle::open(&dir.0).unwrap();
        seed_row(
            &db,
            APP_ID,
            "Stored Name",
            "stored.png",
            "stored description",
            42,
            Some(r#"{"packageName":"com.example.pkg"}"#),
        );
        let metadata = Arc::new(FakeMetadataPort::new());
        metadata.set(
            "acme",
            "repo",
            Some(PackageMetadata {
                package_name: Some("com.example.meta".to_string()),
                app_name: Some("Meta Name".to_string()),
                icon_url: Some("https://icons.test/meta.png".to_string()),
                version_name: None,
            }),
        );
        let driver = driver(&db, Arc::new(FakeHttpPort::new()), metadata.clone());

        let info = driver.get_app_info(APP_ID, false).unwrap();

        assert_eq!(
            metadata.fetch_count(),
            0,
            "a stored info read must never fetch metadata"
        );
        assert_eq!(info.name, "Stored Name", "the stored snapshot wins");
        assert_eq!(info.icon, "stored.png");
        assert_eq!(info.package_name.as_deref(), Some("com.example.pkg"));
        assert_eq!(
            info.labels,
            summary_labels("acme", Some("com.example.pkg"), "repo"),
            "stored labels must equal the metadata-applied label set"
        );
    }

    #[test]
    fn stable_stored_icon_falls_back_to_fixed_metadata_url() {
        assert_eq!(
            stable_stored_icon("", "acme", "repo"),
            "https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/metadata/acme@repo/icon.png"
        );
    }

    #[test]
    fn stable_stored_icon_strips_fingerprint_query() {
        assert_eq!(
            stable_stored_icon(
                "https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/metadata/o@r/icon.png?r=abc123",
                "o",
                "r"
            ),
            "https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/metadata/o@r/icon.png"
        );
    }

    #[test]
    fn stable_stored_icon_leaves_other_urls_alone() {
        for url in [
            "https://avatars.githubusercontent.com/u/1?v=4",
            "https://icons.test/acme.png",
            "stored.png",
        ] {
            assert_eq!(stable_stored_icon(url, "acme", "repo"), url);
        }
    }

    #[test]
    fn get_app_detail_refreshes_and_writes_back() {
        let dir = TempDir::new("detail_refresh");
        let db = DbHandle::open(&dir.0).unwrap();
        seed_row(
            &db,
            APP_ID,
            "Old Name",
            "https://old.test/icon.png",
            "keep description",
            1_700_000_000_000,
            Some(r#"{"packageName":"com.example.old","other":"keep"}"#),
        );
        let metadata = Arc::new(FakeMetadataPort::new());
        metadata.set("acme", "repo", Some(metadata_new()));
        let http = FakeHttpPort::new();
        push_detail_responses(&http);
        let driver = driver(&db, Arc::new(http), metadata.clone());

        let detail = driver.get_app_detail(APP_ID, false).unwrap();

        assert_eq!(
            metadata.fetch_count(),
            1,
            "the detail read must fetch metadata exactly once"
        );
        assert_eq!(detail.name, "New Name");
        assert_eq!(detail.icon, "https://new.test/icon.png");
        assert_eq!(detail.package_name.as_deref(), Some("com.example.new"));

        let local = driver.get_app_info(APP_ID, false).unwrap();
        assert_eq!(
            metadata.fetch_count(),
            1,
            "the local read after the refresh must not fetch"
        );
        assert_eq!(local.name, "New Name", "the refresh must be written back");
        assert_eq!(local.icon, "https://new.test/icon.png");
        assert_eq!(local.package_name.as_deref(), Some("com.example.new"));

        let (add_time, description, extra, name, icon) = stored_row(&db, APP_ID);
        assert_eq!(add_time, 1_700_000_000_000, "add_time must not change");
        assert_eq!(description, "keep description", "description must not change");
        assert_eq!(name, "New Name");
        assert_eq!(icon, "https://new.test/icon.png");
        let extra: Value =
            serde_json::from_str(extra.as_deref().expect("extra must persist")).unwrap();
        assert_eq!(
            extra.get("packageName").and_then(Value::as_str),
            Some("com.example.new"),
            "extra.packageName must be refreshed"
        );
        assert_eq!(
            extra.get("other").and_then(Value::as_str),
            Some("keep"),
            "extra must be merged, not replaced"
        );
    }

    #[test]
    fn get_app_detail_keeps_stored_values_when_metadata_missing() {
        let dir = TempDir::new("detail_no_metadata");
        let db = DbHandle::open(&dir.0).unwrap();
        seed_row(
            &db,
            APP_ID,
            "Stored Name",
            "https://stored.test/icon.png",
            "keep description",
            7,
            Some(r#"{"packageName":"com.example.stored"}"#),
        );
        let metadata = Arc::new(FakeMetadataPort::new());
        metadata.set("acme", "repo", None);
        let http = FakeHttpPort::new();
        push_detail_responses(&http);
        let driver = driver(&db, Arc::new(http), metadata.clone());

        let detail = driver.get_app_detail(APP_ID, false).unwrap();

        assert_eq!(metadata.fetch_count(), 1, "one fetch, even for a miss");
        assert_eq!(detail.name, "Stored Name");
        assert_eq!(detail.icon, "https://stored.test/icon.png");
        let (_, _, extra, name, icon) = stored_row(&db, APP_ID);
        assert_eq!(name, "Stored Name", "a miss must not clobber the row");
        assert_eq!(icon, "https://stored.test/icon.png");
        let extra: Value = serde_json::from_str(extra.as_deref().unwrap()).unwrap();
        assert_eq!(
            extra.get("packageName").and_then(Value::as_str),
            Some("com.example.stored"),
            "a miss must leave packageName untouched"
        );
    }
}
