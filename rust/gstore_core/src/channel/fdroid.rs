//! F-Droid channel driver (Wave 1, Todo 11).
//!
//! Repository access goes exclusively through [`RepoPort`]; this crate never
//! opens the repository module's database or re-implements its parser. Saved
//! channel rows live in `channel_apps` under the bound [`ChannelKey`].
//!
//! Dart parity sources (quoted lines are from `FdroidChannel.dart`):
//!
//! * List (`:222-251`): `final channelApps = await
//!   _database!.dao.getAppsByChannel(ChannelType.fdroid.code);` then each row's
//!   icon is rebuilt with its own `sourceIdentity`.
//! * Search (`:278-345`): `final results = await service.searchApps(keyword,
//!   limit: 50);` then `appId: packageName`, `packageName: ...`,
//!   `repositories: packageName`, `extra: {'sourceId': ...}`.
//! * Info (`:430-509`): stored row first, otherwise the repository lookup;
//!   `appId: packageName`, `repositories: packageName`.
//! * Detail (`:604-722`): the record's `sourceIdentity` selects the source
//!   (`getAppByPackageName(appId, sourceId: recordSourceId)`); sections default
//!   to Version (when downloads exist), Downloads, Readme.
//! * Icon normalization (`:32-47`): absolute URLs pass through; otherwise the
//!   path after the last `/repo/` is joined to the source base. An empty icon
//!   becomes `icons/<appId>.png` (`:105-112`).
//! * Add (`:350-390`): category is joined with `,`, the record's own
//!   `sourceId` is stored (never guessed), and the icon is stored as a
//!   repo-relative key.
//!
//! Source enable/disable: `CoreConfig.fdroid_sources` is the authoritative
//! active set. A source that is not listed is disabled: list/search return an
//! EMPTY success (never an error and never stale cached rows) and no
//! `RepoPort` call is made. Detail/update operations that require a source
//! surface a typed [`Error::NotFound`] when none is active.
//!
//! `do_update` refreshes every active source through
//! [`RepoPort::download_repo`] (the Wave 1 contract; Dart's `doUpdate` was a
//! no-op placeholder).

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use rusqlite::{OptionalExtension, Row};
use serde_json::{Map, Value};

use super::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use super::sealed;
use crate::db::DbHandle;
use crate::dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelMeta, DetailSection,
};
use crate::error::Error;
use crate::ports::config::CoreConfig;
use crate::ports::repo::{RepoApp, RepoPort};

const SEARCH_LIMIT: usize = 50;

/// F-Droid channel driver bound to one [`ChannelKey`].
pub struct FdroidDriver {
    key: ChannelKey,
    meta: ChannelMeta,
    db: DbHandle,
    config: CoreConfig,
    repo: Arc<dyn RepoPort>,
    initialized: AtomicBool,
}

impl sealed::Sealed for FdroidDriver {}

#[derive(Debug, Clone)]
struct StoredApp {
    app_id: String,
    name: String,
    user: String,
    repositories: String,
    icon: String,
    description: String,
    category: Option<String>,
    source_id: Option<String>,
    extra_raw: Option<String>,
}

impl StoredApp {
    fn extra(&self) -> Option<Map<String, Value>> {
        self.extra_raw
            .as_deref()
            .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
            .and_then(|value| value.as_object().cloned())
    }

    fn source_identity(&self) -> Option<String> {
        self.source_id
            .as_deref()
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
            .or_else(|| {
                self.extra()
                    .as_ref()
                    .and_then(|map| map.get("sourceId"))
                    .and_then(Value::as_str)
                    .filter(|value| !value.is_empty())
                    .map(ToString::to_string)
            })
    }

    fn category(&self) -> Option<Vec<String>> {
        self.category
            .as_deref()
            .map(|value| value.split(',').map(ToString::to_string).collect())
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
        source_id: row.get(7)?,
        extra_raw: row.get(8)?,
    })
}

impl FdroidDriver {
    /// Creates a driver bound to `key`.
    pub fn new(
        key: ChannelKey,
        meta: ChannelMeta,
        db: DbHandle,
        config: CoreConfig,
        repo: Arc<dyn RepoPort>,
    ) -> Self {
        Self {
            key,
            meta,
            db,
            config,
            repo,
            initialized: AtomicBool::new(false),
        }
    }

    fn reader(&self) -> Result<rusqlite::Connection, Error> {
        self.db
            .reader()
            .map_err(|error| Error::Io(format!("fdroid open reader: {error}")))
    }

    fn load_stored(&self) -> Result<Vec<StoredApp>, Error> {
        let conn = self.reader()?;
        let mut statement = conn
            .prepare(
                "SELECT app_id,name,user,repositories,icon,description,category,source_id,extra \
                 FROM channel_apps WHERE channel_key = ?1 ORDER BY add_time DESC, app_id ASC",
            )
            .map_err(|error| Error::Io(format!("fdroid prepare stored apps: {error}")))?;
        let rows = statement
            .query_map([self.key.as_str()], stored_from_row)
            .map_err(|error| Error::Io(format!("fdroid stored apps: {error}")))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| Error::Io(format!("fdroid stored row: {error}")))
    }

    fn find_stored(&self, app_id: &str) -> Result<Option<StoredApp>, Error> {
        let conn = self.reader()?;
        conn.query_row(
            "SELECT app_id,name,user,repositories,icon,description,category,source_id,extra \
             FROM channel_apps WHERE channel_key = ?1 AND app_id = ?2 LIMIT 1",
            rusqlite::params![self.key.as_str(), app_id],
            stored_from_row,
        )
        .optional()
        .map_err(|error| Error::Io(format!("fdroid lookup stored app: {error}")))
    }

    /// Configured sources, normalized and de-duplicated, in config order.
    fn active_sources(&self) -> Vec<String> {
        let mut seen = HashSet::new();
        self.config
            .fdroid_sources()
            .iter()
            .map(|source| normalize_source(source))
            .filter(|source| !source.is_empty())
            .filter(|source| seen.insert(source.clone()))
            .collect()
    }

    /// Ensures every active source has a local repository index.
    ///
    /// Dart's `FdroidChannel.checkAppUpdate` reads a locally-synced index and
    /// never hits the network; the core mirrors that by downloading a source's
    /// index through [`RepoPort::download_repo`] **only** when
    /// [`RepoPort::get_repo_meta`] reports no local copy.
    fn ensure_active_index(&self) -> Result<(), Error> {
        for source in self.active_sources() {
            if self.repo.get_repo_meta(&source)?.is_none() {
                self.repo.download_repo(&source)?;
            }
        }
        Ok(())
    }

    fn summary_from_repo(&self, app: &RepoApp, source: &str) -> AppSummary {
        let icon = absolute_icon_url(app.icon.as_deref().unwrap_or(""), &app.package_name, source);
        AppSummary {
            app_id: app.package_name.clone(),
            package_name: (!app.package_name.is_empty()).then(|| app.package_name.clone()),
            name: app.name.clone(),
            user: String::new(),
            repositories: app.package_name.clone(),
            icon,
            des: app.summary.clone(),
            readme: None,
            category: Some(app.categories.clone()),
            extra: Some(source_extra(source)),
        }
    }

    fn summary_from_stored(&self, stored: &StoredApp, source: Option<&str>) -> AppSummary {
        let icon = absolute_icon_url(&stored.icon, &stored.app_id, source.unwrap_or(""));
        let mut extra = stored.extra().unwrap_or_default();
        if let Some(source) = source.filter(|value| !value.is_empty()) {
            extra.insert("sourceId".to_string(), Value::String(source.to_string()));
        }
        AppSummary {
            app_id: stored.app_id.clone(),
            package_name: None,
            name: stored.name.clone(),
            user: stored.user.clone(),
            repositories: stored.repositories.clone(),
            icon,
            des: stored.description.clone(),
            readme: None,
            category: stored.category(),
            extra: (!extra.is_empty()).then_some(extra),
        }
    }

    /// Resolves a stored row's source against the active set. Disabled sources
    /// yield `None`, so callers never fall back to stale data.
    fn active_source_for(&self, stored: &StoredApp) -> Option<String> {
        let active = self.active_sources();
        match stored.source_identity() {
            Some(source) => active
                .iter()
                .find(|candidate| **candidate == normalize_source(&source))
                .cloned(),
            None => active.first().cloned(),
        }
    }

    fn lookup(
        &self,
        app_id: &str,
        stored: Option<&StoredApp>,
    ) -> Result<Option<(String, RepoApp)>, Error> {
        let active = self.active_sources();
        if active.is_empty() {
            return Ok(None);
        }
        let candidates = match stored.and_then(|record| self.active_source_for(record)) {
            Some(source) => vec![source],
            None => active,
        };
        for source in candidates {
            if let Some(app) = self.repo.get_one_app(&source, app_id)? {
                return Ok(Some((source, app)));
            }
        }
        Ok(None)
    }

    fn detail_from_repo(&self, app_id: &str, app: &RepoApp, source: &str) -> AppDetail {
        let icon = absolute_icon_url(app.icon.as_deref().unwrap_or(""), app_id, source);
        let mut downloads = Vec::new();
        if let Some(url) = app.apk_url.as_deref().filter(|value| !value.is_empty()) {
            let name = url
                .rsplit('/')
                .next()
                .filter(|value| !value.is_empty())
                .unwrap_or(app_id)
                .to_string();
            let platform = extract_arch(&name);
            downloads.push(AppDownload {
                url: absolute_asset_url(url, source),
                name,
                size: app.size,
                download_count: None,
                version: app.version.clone(),
                version_code: app.version_code,
                published_at: None,
                platform,
                hash: None,
                hash_type: None,
                downloadable: true,
                note: None,
                extra: None,
            });
        }

        let mut sections = Vec::new();
        if !downloads.is_empty() {
            sections.push(DetailSection::Version);
        }
        sections.push(DetailSection::Downloads);
        if !app.summary.is_empty() {
            sections.push(DetailSection::Readme);
        }

        let mut extra = source_extra(source);
        extra.insert(
            "categories".to_string(),
            Value::Array(
                app.categories
                    .iter()
                    .map(|value| Value::String(value.clone()))
                    .collect(),
            ),
        );
        extra.insert("summary".to_string(), Value::String(app.summary.clone()));

        AppDetail {
            app_id: app_id.to_string(),
            name: app.name.clone(),
            icon,
            description: app.summary.clone(),
            version: app.version.clone(),
            developer: None,
            package_name: Some(app.package_name.clone()),
            project_url: None,
            channel: self.meta.kind,
            sections,
            downloads,
            extra,
        }
    }
}

impl ChannelDriver for FdroidDriver {
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
        Ok(!self.active_sources().is_empty())
    }

    fn get_all_apps(&self, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        let active = self.active_sources();
        if active.is_empty() {
            // A disabled source returns EMPTY, never cached/stale rows.
            return Ok(Vec::new());
        }
        let mut apps = Vec::new();
        for stored in self.load_stored()? {
            let Some(source) = self.active_source_for(&stored) else {
                continue;
            };
            apps.push(self.summary_from_stored(&stored, Some(&source)));
        }
        Ok(apps)
    }

    fn get_app_info(&self, app_id: &str, force_refresh: bool) -> Result<AppSummary, Error> {
        let stored = self.find_stored(app_id)?;
        if !force_refresh {
            if let Some(record) = &stored {
                if let Some(source) = self.active_source_for(record) {
                    return Ok(self.summary_from_stored(record, Some(&source)));
                }
            }
        }
        let Some((source, app)) = self.lookup(app_id, stored.as_ref())? else {
            return Err(Error::NotFound(format!(
                "app not found in enabled F-Droid sources: {app_id}"
            )));
        };
        Ok(self.summary_from_repo(&app, &source))
    }

    fn get_app_detail(&self, app_id: &str, _force_refresh: bool) -> Result<AppDetail, Error> {
        if self.active_sources().is_empty() {
            return Err(Error::NotFound(
                "no enabled F-Droid source for detail".to_string(),
            ));
        }
        let stored = self.find_stored(app_id)?;
        let Some((source, app)) = self.lookup(app_id, stored.as_ref())? else {
            return Err(Error::NotFound(format!(
                "app not found in enabled F-Droid sources: {app_id}"
            )));
        };
        Ok(self.detail_from_repo(app_id, &app, &source))
    }

    fn check_app_update(&self, app_id: &str) -> Result<AppUpdate, Error> {
        self.ensure_active_index()?;
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
        let category = app
            .category
            .as_ref()
            .map(|values| values.join(","))
            .filter(|value| !value.is_empty());
        // Dart only trusts the source carried by the record; never guess.
        let source_id = app
            .extra
            .as_ref()
            .and_then(|map| map.get("sourceId"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty());
        let base_host = source_id.and_then(host_of).unwrap_or_default();
        let mut icon = repo_asset_key(&app.icon, &base_host);
        if icon.is_empty() {
            icon = format!("icons/{}.png", app.app_id);
        }
        let add_time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_millis() as i64)
            .unwrap_or(0);
        let extra = app.extra.as_ref().and_then(|map| {
            // `sourceId` lives in its own column; do not duplicate it.
            let mut copy = map.clone();
            copy.remove("sourceId");
            if copy.is_empty() {
                None
            } else {
                serde_json::to_string(&Value::Object(copy)).ok()
            }
        });

        self.db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT OR REPLACE INTO channel_apps(channel_key,app_id,name,user,repositories,\
                     apprepo,icon,description,category,add_time,source_id,extra) \
                     VALUES (?1,?2,?3,?4,?5,NULL,?6,?7,?8,?9,?10,?11)",
                    rusqlite::params![
                        self.key.as_str(),
                        app.app_id,
                        app.name,
                        app.user,
                        app.repositories,
                        icon,
                        app.des,
                        category,
                        add_time,
                        source_id,
                        extra
                    ],
                )
                .map_err(|error| crate::db::DbError(error.to_string()))?;
                Ok(())
            })
            .map_err(|error| Error::Io(format!("fdroid add app: {error}")))
    }

    fn canonical_app_id(&self, app: &AppSummary) -> Result<String, Error> {
        // Dart: `Future<String> canonicalAppId(AppSummary appInfo) async =>
        // appInfo.appId;`
        Ok(app.app_id.clone())
    }

    fn remove_app(&self, app_id: &str) -> Result<(), Error> {
        self.db
            .with_writer(|conn| {
                conn.execute(
                    "DELETE FROM channel_apps WHERE channel_key = ?1 AND app_id = ?2",
                    rusqlite::params![self.key.as_str(), app_id],
                )
                .map_err(|error| crate::db::DbError(error.to_string()))?;
                Ok(())
            })
            .map_err(|error| Error::Io(format!("fdroid remove app: {error}")))
    }

    fn search_apps(&self, keyword: &str, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        let active = self.active_sources();
        if active.is_empty() {
            // Disabled source: EMPTY success, and no RepoPort call.
            return Ok(Vec::new());
        }
        let mut apps = Vec::new();
        let mut seen = HashSet::new();
        for source in active {
            for app in self.repo.search_apps(&source, keyword, SEARCH_LIMIT)? {
                if !seen.insert(app.package_name.clone()) {
                    continue;
                }
                apps.push(self.summary_from_repo(&app, &source));
            }
        }
        Ok(apps)
    }

    fn search_by_category(
        &self,
        _category_id: &str,
        _force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        // Dart: F-Droid does not support category search.
        Ok(Vec::new())
    }

    fn get_all_categories(&self, _force_refresh: bool) -> Result<Vec<ChannelCategory>, Error> {
        // Dart hard-codes these 17 categories (`FdroidChannel.dart:1027-1046`).
        Ok([
            ("1", "Games"),
            ("2", "Communication"),
            ("3", "Development"),
            ("4", "Money"),
            ("5", "Multimedia"),
            ("6", "Navigation"),
            ("7", "Phone & SMS"),
            ("8", "Reading"),
            ("9", "Science & Education"),
            ("10", "Security"),
            ("11", "Sports & Health"),
            ("12", "System"),
            ("13", "Time"),
            ("14", "Writing"),
            ("15", "Internet"),
            ("16", "Connectivity"),
            ("17", "Theming"),
        ]
        .iter()
        .map(|(id, description)| ChannelCategory {
            id: (*id).to_string(),
            description: (*description).to_string(),
            icon: String::new(),
        })
        .collect())
    }

    fn check_update(&self) -> Result<bool, Error> {
        for source in self.active_sources() {
            if self.repo.get_repo_meta(&source)?.is_some() {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn do_update(&self, progress: Option<&mut dyn FnMut(u64, u64)>) -> Result<bool, Error> {
        let sources = self.active_sources();
        if sources.is_empty() {
            return Ok(false);
        }
        let total = sources.len() as u64;
        let mut progress = progress;
        for (index, source) in sources.iter().enumerate() {
            self.repo.download_repo(source)?;
            if let Some(callback) = progress.as_mut() {
                (**callback)(index as u64 + 1, total);
            }
        }
        Ok(true)
    }

    fn get_config(&self, _force_refresh: bool) -> Result<Option<ChannelConfig>, Error> {
        Ok(None)
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

fn source_extra(source: &str) -> Map<String, Value> {
    let mut extra = Map::new();
    if !source.is_empty() {
        extra.insert("sourceId".to_string(), Value::String(source.to_string()));
    }
    extra
}

fn normalize_source(source: &str) -> String {
    source.trim().trim_end_matches('/').to_string()
}

fn host_of(url: &str) -> Option<String> {
    let (_, rest) = url.split_once("://")?;
    let authority = rest.split('/').next().unwrap_or_default();
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    let host = host.split_once(':').map_or(host, |(host, _)| host);
    (!host.is_empty()).then(|| host.to_ascii_lowercase())
}

/// Dart `normalizeRepoAssetPath`: keep absolute URLs, otherwise take the part
/// after the last `/repo/` and trim leading slashes.
fn normalize_repo_asset_path(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    let mut value = path.split('?').next().unwrap_or(path);
    if let Some((_, rest)) = value.split_once("://") {
        value = rest.find('/').map_or("", |index| &rest[index..]);
    }
    if let Some(index) = value.rfind("/repo/") {
        value = &value[index + "/repo/".len()..];
    }
    value.trim_start_matches('/').to_string()
}

/// Dart `joinRepoUrl`: absolute paths pass through; empty path returns the
/// base; otherwise both sides are slash-normalized exactly once.
fn join_repo_url(base: &str, path: &str) -> String {
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    let base = base.trim_end_matches('/');
    let path = path.trim_start_matches('/');
    if path.is_empty() {
        base.to_string()
    } else {
        format!("{base}/{path}")
    }
}

fn absolute_icon_url(icon_key: &str, app_id: &str, source: &str) -> String {
    if icon_key.is_empty() {
        if app_id.is_empty() {
            return source.trim_end_matches('/').to_string();
        }
        return join_repo_url(source, &format!("icons/{app_id}.png"));
    }
    join_repo_url(source, &normalize_repo_asset_path(icon_key))
}

fn absolute_asset_url(path: &str, source: &str) -> String {
    join_repo_url(source, &normalize_repo_asset_path(path))
}

/// Dart `repoAssetKey`: same-host absolute assets become repo-relative keys,
/// external absolute assets stay absolute, relative keys are normalized.
fn repo_asset_key(raw: &str, base_host: &str) -> String {
    let value = raw.trim();
    if value.is_empty() {
        return String::new();
    }
    if let Some((_scheme, rest)) = value.split_once("://") {
        let authority = rest.split('/').next().unwrap_or_default();
        let host = authority
            .rsplit_once('@')
            .map_or(authority, |(_, host)| host)
            .split_once(':')
            .map_or(authority, |(host, _)| host);
        let own = !base_host.is_empty() && host.eq_ignore_ascii_case(base_host);
        return if own {
            let path = rest.find('/').map_or("", |index| &rest[index..]);
            normalize_repo_asset_path(path)
        } else {
            value.to_string()
        };
    }
    normalize_repo_asset_path(value)
}

/// Dart `_extractArch` (leading underscore forms).
fn extract_arch(apk_name: &str) -> Option<String> {
    let lower = apk_name.to_ascii_lowercase();
    for (needle, platform) in [
        ("_arm64-v8a", "arm64-v8a"),
        ("_armeabi-v7a", "armeabi-v7a"),
        ("_x86_64", "x86_64"),
        ("_x86", "x86"),
        ("_universal", "universal"),
    ] {
        if lower.contains(needle) {
            return Some(platform.to_string());
        }
    }
    None
}
