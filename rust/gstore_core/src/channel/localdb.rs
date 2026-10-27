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
//! * `getAppInfo` / `getAppDetail` → metadata package/app-name/icon override,
//!   with `keepExistingPackageName` false for info and true for detail.
//!
//! The driver is read-only. Dart `addApp`/`removeApp` explicitly return a
//! failure ("本地数据库渠道不支持…"), and `doUpdate` delegates to the global
//! database updater outside the channel; the Rust driver surfaces all three as
//! typed [`Error::Unsupported`] instead of pretending to mutate a local catalog.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension, Row};

use super::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use super::sealed;
use crate::db::DbHandle;
use crate::dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelMeta, DetailSection,
};
use crate::error::Error;
use crate::ports::metadata::MetadataPort;

/// Read-only LocalDb channel driver bound to one [`ChannelKey`].
pub struct LocalDbDriver {
    key: ChannelKey,
    meta: ChannelMeta,
    db: DbHandle,
    metadata: Option<Arc<dyn MetadataPort>>,
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
            initialized: AtomicBool::new(false),
        }
    }

    /// Attaches the metadata port used for package/app-name/icon overrides.
    #[must_use]
    pub fn with_metadata(mut self, metadata: Arc<dyn MetadataPort>) -> Self {
        self.metadata = Some(metadata);
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

    fn load_app(&self, app_id: &str) -> Result<Option<AppSummary>, Error> {
        Ok(self
            .query_apps(&format!("{APP_COLUMNS} WHERE appId = ?1"), Some(app_id))?
            .into_iter()
            .next())
    }

    /// Mirrors Dart `_applyMetadataOverride` (`LocalDbChannel.dart:92-126`).
    fn apply_metadata(
        &self,
        app: AppSummary,
        keep_existing_package_name: bool,
    ) -> Result<AppSummary, Error> {
        if app.user.is_empty() || app.repositories.is_empty() {
            return Ok(app);
        }
        let Some(metadata_port) = &self.metadata else {
            return Ok(app);
        };
        let Some(metadata) = metadata_port.fetch(&app.user, &app.repositories)? else {
            return Ok(app);
        };

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

        Ok(AppSummary {
            package_name,
            name: display_name,
            icon,
            ..app
        })
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

const APP_COLUMNS: &str =
    "SELECT appId,name,user,repositories,icon,des,readme,category,extra FROM apps";

fn row_to_summary(row: &Row<'_>) -> rusqlite::Result<AppSummary> {
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

    Ok(AppSummary {
        app_id,
        package_name,
        name,
        user: user.unwrap_or_default(),
        repositories: repositories.unwrap_or_default(),
        icon: icon.unwrap_or_default(),
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
    })
}

fn valid_package_name(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() || !value.contains('.') {
        return None;
    }
    Some(value.to_string())
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

    fn get_app_info(&self, app_id: &str, _force_refresh: bool) -> Result<AppSummary, Error> {
        let app = self
            .load_app(app_id)?
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))?;
        self.apply_metadata(app, false)
    }

    fn get_app_detail(&self, app_id: &str, _force_refresh: bool) -> Result<AppDetail, Error> {
        let app = self
            .load_app(app_id)?
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))?;
        let app = self.apply_metadata(app, true)?;

        // Dart `_fetchReadmeInternal` with no GitHub client falls back to the
        // row README and then to `des`.
        let readme = app
            .readme
            .clone()
            .or_else(|| (!app.des.is_empty()).then(|| app.des.clone()));
        let mut sections = vec![DetailSection::Downloads];
        if readme.as_deref().is_some_and(|value| !value.is_empty()) {
            sections.push(DetailSection::Readme);
        }
        let developer = (!app.user.is_empty()).then(|| app.user.clone());
        let project_url = (!app.user.is_empty() && !app.repositories.is_empty())
            .then(|| format!("https://github.com/{}/{}", app.user, app.repositories));

        Ok(AppDetail {
            app_id: app.app_id.clone(),
            name: app.name.clone(),
            icon: app.icon.clone(),
            description: app.des.clone(),
            version: None,
            developer,
            package_name: app.package_name.clone(),
            project_url,
            channel: self.meta.kind,
            sections,
            downloads: Vec::new(),
            extra: app.extra.unwrap_or_default(),
        })
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
        Ok(app.readme.filter(|value| !value.is_empty()).or(fallback))
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
            latest_version: None,
            latest_download: None,
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
