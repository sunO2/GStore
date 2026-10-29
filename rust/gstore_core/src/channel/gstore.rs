//! Writable GStore channel driver.
//!
//! GStore is the user-facing channel backed by the local catalog: it stores its
//! own membership rows in `channel_apps('gstore')` (真元数据), and falls back to
//! the catalog `apps` table when asked about an app the user has not saved yet.
//! That is the same split as F-Droid (channel + repo), except the source is the
//! local catalog read through [`DbHandle`] instead of a downloaded index.
//!
//! Writes mirror `FdroidDriver`: `add_app` upserts one `channel_apps` row with
//! `channel_key = 'gstore'` and `remove_app` deletes exactly that row. Reads
//! prefer the saved row and only then consult the catalog through
//! [`LocalDbDriver`], so browsing an unsaved app still renders real metadata.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use rusqlite::{OptionalExtension, Row};
use serde_json::Value;

use super::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use super::localdb::{build_app_detail, CatalogDetailSource, LocalDbDriver};
use super::sealed;
use crate::db::DbHandle;
use crate::dto::{
    summary_labels, AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelMeta,
};
use crate::error::Error;
use crate::ports::config::CoreConfig;
use crate::ports::http::HttpPort;
use crate::ports::metadata::MetadataPort;

const STORED_COLUMNS: &str =
    "SELECT app_id,name,user,repositories,icon,description,category,source_id,extra \
     FROM channel_apps";

/// Writable GStore channel driver bound to one [`ChannelKey`].
pub struct GStoreDriver {
    key: ChannelKey,
    meta: ChannelMeta,
    db: DbHandle,
    catalog: LocalDbDriver,
    initialized: AtomicBool,
}

impl sealed::Sealed for GStoreDriver {}

impl GStoreDriver {
    /// Creates a driver bound to `key`.
    pub fn new(key: ChannelKey, meta: ChannelMeta, db: DbHandle) -> Self {
        let catalog = LocalDbDriver::new(catalog_key(), catalog_meta(), db.clone());
        Self {
            key,
            meta,
            db,
            catalog,
            initialized: AtomicBool::new(false),
        }
    }

    /// Attaches the metadata port used when a saved row is resolved to detail.
    #[must_use]
    pub fn with_metadata(mut self, metadata: Arc<dyn MetadataPort>) -> Self {
        self.catalog = self.catalog.with_metadata(metadata);
        self
    }

    /// Attaches a GitHub fetcher for catalog rows that point at a repository.
    #[must_use]
    pub fn with_github(mut self, config: CoreConfig, http: Arc<dyn HttpPort>) -> Self {
        self.catalog = self.catalog.with_github(config, http);
        self
    }

    fn reader(&self) -> Result<rusqlite::Connection, Error> {
        self.db
            .reader()
            .map_err(|error| Error::Io(format!("gstore open reader: {error}")))
    }

    fn get_all_stored(&self) -> Result<Vec<AppSummary>, Error> {
        let conn = self.reader()?;
        let mut statement = conn
            .prepare(&format!(
                "{STORED_COLUMNS} WHERE channel_key = ?1 ORDER BY add_time DESC, app_id ASC"
            ))
            .map_err(|error| Error::Io(format!("gstore prepare stored apps: {error}")))?;
        let rows = statement
            .query_map([self.key.as_str()], stored_summary)
            .map_err(|error| Error::Io(format!("gstore stored apps: {error}")))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| Error::Io(format!("gstore stored row: {error}")))
    }

    fn find_stored(&self, app_id: &str) -> Result<Option<AppSummary>, Error> {
        let conn = self.reader()?;
        conn.query_row(
            &format!("{STORED_COLUMNS} WHERE channel_key = ?1 AND app_id = ?2 LIMIT 1"),
            rusqlite::params![self.key.as_str(), app_id],
            stored_summary,
        )
        .optional()
        .map_err(|error| Error::Io(format!("gstore lookup stored app: {error}")))
    }

    fn catalog_detail(&self, app_id: &str, force_refresh: bool) -> Result<AppDetail, Error> {
        let mut detail = self.catalog.get_app_detail(app_id, force_refresh)?;
        detail.channel = self.meta.kind;
        Ok(detail)
    }
}

fn catalog_key() -> ChannelKey {
    ChannelKey::new("local_db").expect("static catalog key is valid")
}

fn catalog_meta() -> ChannelMeta {
    ChannelMeta {
        kind: crate::dto::ChannelKind::LocalDb,
        name: "LocalDB".to_string(),
        description: String::new(),
        enabled: true,
        priority: 1,
        support_offline: true,
        last_update_time: None,
        version: None,
    }
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn stored_summary(row: &Row<'_>) -> rusqlite::Result<AppSummary> {
    let app_id: String = row.get(0)?;
    let name: String = row.get(1)?;
    let user: String = row.get(2)?;
    let repositories: String = row.get(3)?;
    let icon: String = row.get(4)?;
    let description: String = row.get(5)?;
    let category: Option<String> = row.get(6)?;
    let source_id: Option<String> = row.get(7)?;
    let extra_raw: Option<String> = row.get(8)?;

    let mut extra = extra_raw
        .as_deref()
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    if let Some(source) = source_id.filter(|value| !value.is_empty()) {
        extra.insert("sourceId".to_string(), Value::String(source));
    }
    let package_name = extra
        .get("packageName")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string);
    let labels = summary_labels(&user, package_name.as_deref(), &repositories);
    Ok(AppSummary {
        app_id,
        package_name,
        name,
        user,
        repositories,
        icon,
        des: description,
        readme: None,
        category: Some(
            category
                .as_deref()
                .map(|value| value.split(',').map(ToString::to_string).collect())
                .unwrap_or_default(),
        ),
        extra: (!extra.is_empty()).then_some(extra),
        labels,
    })
}

impl ChannelDriver for GStoreDriver {
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
        self.catalog.check_available()
    }

    fn get_all_apps(&self, _force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        self.get_all_stored()
    }

    fn get_app_info(&self, app_id: &str, force_refresh: bool) -> Result<AppSummary, Error> {
        if let Some(stored) = self.find_stored(app_id)? {
            return Ok(stored);
        }
        self.catalog.get_app_info(app_id, force_refresh)
    }

    fn get_app_detail(&self, app_id: &str, force_refresh: bool) -> Result<AppDetail, Error> {
        let Some(app) = self.find_stored(app_id)? else {
            return self.catalog_detail(app_id, force_refresh);
        };
        let metadata = self.catalog.metadata_for(&app)?;
        let (downloads, release_version) = self.catalog.github_release(&app);
        Ok(build_app_detail(
            app,
            CatalogDetailSource {
                kind: self.meta.kind,
                metadata: metadata.as_ref(),
                downloads,
                release_version,
            },
        ))
    }

    fn supports_progressive_loading(&self) -> Result<bool, Error> {
        Ok(true)
    }

    fn fetch_downloads(&self, app_id: &str) -> Result<Vec<AppDownload>, Error> {
        if self.find_stored(app_id)?.is_some() {
            return Ok(Vec::new());
        }
        self.catalog.fetch_downloads(app_id)
    }

    fn fetch_readme(&self, app_id: &str) -> Result<Option<String>, Error> {
        if let Some(app) = self.find_stored(app_id)? {
            return Ok(app
                .readme
                .filter(|value| !value.is_empty())
                .or_else(|| (!app.des.is_empty()).then_some(app.des)));
        }
        self.catalog.fetch_readme(app_id)
    }

    fn fetch_statistics(
        &self,
        app_id: &str,
    ) -> Result<Option<serde_json::Map<String, Value>>, Error> {
        if let Some(app) = self.find_stored(app_id)? {
            return Ok(app.extra);
        }
        self.catalog.fetch_statistics(app_id)
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
        let category = app
            .category
            .as_ref()
            .map(|values| values.join(","))
            .filter(|value| !value.is_empty());
        let source_id = app
            .extra
            .as_ref()
            .and_then(|map| map.get("sourceId"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty());
        let extra = app.extra.as_ref().and_then(|map| {
            let mut copy = map.clone();
            copy.remove("sourceId");
            if copy.is_empty() {
                None
            } else {
                serde_json::to_string(&Value::Object(copy)).ok()
            }
        });
        let add_time = now_millis();

        self.db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT OR REPLACE INTO channel_apps(channel_key,app_id,name,user,\
                     repositories,apprepo,icon,description,category,add_time,source_id,extra) \
                     VALUES (?1,?2,?3,?4,?5,NULL,?6,?7,?8,?9,?10,?11)",
                    rusqlite::params![
                        self.key.as_str(),
                        app.app_id,
                        app.name,
                        app.user,
                        app.repositories,
                        app.icon,
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
            .map_err(|error| Error::Io(format!("gstore add app: {error}")))
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
            .map_err(|error| Error::Io(format!("gstore remove app: {error}")))
    }

    fn search_apps(&self, keyword: &str, force_refresh: bool) -> Result<Vec<AppSummary>, Error> {
        self.catalog.search_apps(keyword, force_refresh)
    }

    fn search_by_category(
        &self,
        category_id: &str,
        force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        self.catalog.search_by_category(category_id, force_refresh)
    }

    fn get_all_categories(&self, force_refresh: bool) -> Result<Vec<ChannelCategory>, Error> {
        self.catalog.get_all_categories(force_refresh)
    }

    fn check_update(&self) -> Result<bool, Error> {
        self.catalog.check_update()
    }

    fn do_update(&self, _progress: Option<&mut dyn FnMut(u64, u64)>) -> Result<bool, Error> {
        Err(Error::Unsupported(
            "gstore channel does not own the catalog update loop".to_string(),
        ))
    }

    fn get_config(&self, force_refresh: bool) -> Result<Option<ChannelConfig>, Error> {
        self.catalog.get_config(force_refresh)
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
