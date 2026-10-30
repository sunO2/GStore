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
use serde_json::{Map, Value};

use super::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use super::localdb::{
    build_app_detail, valid_package_name, CatalogDetailSource, LocalDbDriver,
};
use super::sealed;
use crate::db::DbHandle;
use crate::dto::{
    summary_labels, AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelMeta,
};
use crate::error::Error;
use crate::ports::config::CoreConfig;
use crate::ports::http::HttpPort;
use crate::ports::metadata::{MetadataPort, PackageMetadata};

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

/// Resolves `(owner, repo)` for a saved row, preferring explicit `user` /
/// `repositories` and falling back to an `owner/repo` shaped app id.
fn resolved_owner_repo(app: &AppSummary) -> (String, String) {
    let (id_owner, id_repo) = match app.app_id.split_once('/') {
        Some((owner, repo)) => (owner, Some(repo)),
        None => (app.app_id.as_str(), None),
    };
    let owner = if app.user.is_empty() {
        id_owner.to_string()
    } else {
        app.user.clone()
    };
    let repo = if app.repositories.is_empty() {
        id_repo.unwrap_or_default().to_string()
    } else {
        app.repositories.clone()
    };
    (owner, repo)
}

/// Merges already-fetched metadata into `(name, icon, package_name, extra)`.
///
/// Each field takes the metadata value when it is non-empty and otherwise
/// keeps the stored value, so a metadata miss or a partial payload never
/// blanks a good row. `extra` starts from the stored map (all keys kept) and
/// only `packageName` is replaced, and only by a valid metadata package name.
fn merge_refreshed(
    app: &AppSummary,
    metadata: Option<&PackageMetadata>,
) -> (String, String, Option<String>, Map<String, Value>) {
    let mut name = app.name.clone();
    let mut icon = app.icon.clone();
    let mut package_name = app.package_name.clone();
    let mut extra = app.extra.clone().unwrap_or_default();
    if let Some(metadata) = metadata {
        if let Some(value) = metadata.app_name.as_deref().filter(|value| !value.is_empty()) {
            name = value.to_string();
        }
        if let Some(value) = metadata.icon_url.as_deref().filter(|value| !value.is_empty()) {
            icon = value.to_string();
        }
        if let Some(value) = valid_package_name(metadata.package_name.as_deref()) {
            extra.insert("packageName".to_string(), Value::String(value.clone()));
            package_name = Some(value);
        }
    }
    (name, icon, package_name, extra)
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
        let mut detail = build_app_detail(
            app.clone(),
            CatalogDetailSource {
                kind: self.meta.kind,
                metadata: metadata.as_ref(),
                downloads,
                release_version,
            },
        );
        if metadata.is_some() {
            let (name, icon, package_name, extra) = merge_refreshed(&app, metadata.as_ref());
            detail.name = name;
            detail.icon = icon;
            detail.package_name = package_name;
            detail.extra = extra.clone();
            let mut persisted = extra;
            persisted.remove("sourceId");
            let extra = (!persisted.is_empty()).then(|| Value::Object(persisted).to_string());
            let name = detail.name.clone();
            let icon = detail.icon.clone();
            self.db
                .with_writer(|conn| {
                    conn.execute(
                        "UPDATE channel_apps SET name = ?3, icon = ?4, extra = ?5 \
                         WHERE channel_key = ?1 AND app_id = ?2",
                        rusqlite::params![self.key.as_str(), app.app_id, name, icon, extra],
                    )
                    .map_err(|error| crate::db::DbError(error.to_string()))?;
                    Ok(())
                })
                .map_err(|error| Error::Io(format!("gstore detail refresh: {error}")))?;
        }
        Ok(detail)
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

        let (owner, repo) = resolved_owner_repo(app);
        let metadata = if owner.is_empty() || repo.is_empty() {
            None
        } else {
            let probe = AppSummary {
                user: owner.clone(),
                repositories: repo.clone(),
                ..app.clone()
            };
            self.catalog.metadata_for(&probe)?
        };
        let (name, icon, _package_name, mut extra_map) = merge_refreshed(app, metadata.as_ref());
        extra_map.remove("sourceId");
        let extra = (!extra_map.is_empty()).then(|| Value::Object(extra_map).to_string());
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
                        name,
                        owner,
                        repo,
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

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    use super::*;
    use crate::dto::ChannelKind;
    use crate::ports::FakeMetadataPort;

    static NEXT_TMP: AtomicU64 = AtomicU64::new(0);

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let n = NEXT_TMP.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "gstore_core_gstore_channel_{tag}_{}_{}",
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
            kind: ChannelKind::GStore,
            name: "GStore".to_string(),
            description: "GStore channel".to_string(),
            enabled: true,
            priority: 1,
            support_offline: true,
            last_update_time: None,
            version: None,
        }
    }

    fn driver(db: &DbHandle, metadata: &Arc<FakeMetadataPort>) -> GStoreDriver {
        GStoreDriver::new(ChannelKey::new("gstore").unwrap(), channel_meta(), db.clone())
            .with_metadata(metadata.clone())
    }

    fn metadata_new() -> PackageMetadata {
        PackageMetadata {
            package_name: Some("com.example.new".to_string()),
            app_name: Some("Meta Name".to_string()),
            icon_url: Some("https://new.test/icon.png".to_string()),
            version_name: None,
        }
    }

    fn app_summary(app_id: &str, name: &str, user: &str, repositories: &str) -> AppSummary {
        AppSummary {
            app_id: app_id.to_string(),
            package_name: Some("com.example.old".to_string()),
            name: name.to_string(),
            user: user.to_string(),
            repositories: repositories.to_string(),
            icon: "https://old.test/icon.png".to_string(),
            des: "old description".to_string(),
            readme: None,
            category: None,
            extra: Some(
                serde_json::json!({
                    "packageName": "com.example.old",
                    "keep": "x",
                    "sourceId": "local"
                })
                .as_object()
                .cloned()
                .unwrap(),
            ),
            labels: Vec::new(),
        }
    }

    /// Reads `(name, icon, extra, user, repositories)` for one gstore row.
    fn stored_row(db: &DbHandle, app_id: &str) -> (String, String, Option<String>, String, String) {
        let conn = db.reader().unwrap();
        conn.query_row(
            "SELECT name,icon,extra,user,repositories FROM channel_apps \
             WHERE channel_key = 'gstore' AND app_id = ?1",
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

    /// Seeds one gstore row directly so detail-refresh tests start from a
    /// known snapshot instead of going through `add_app`.
    fn seed_stored(db: &DbHandle, app_id: &str, name: &str, icon: &str, add_time: i64,
                   extra: Option<&str>) {
        db.with_writer(|conn| {
            conn.execute(
                "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,apprepo,\
                 icon,description,category,add_time,source_id,extra) \
                 VALUES ('gstore',?1,?2,'acme','repo',NULL,?3,'keep description',NULL,?4,'local',?5)",
                rusqlite::params![app_id, name, icon, add_time, extra],
            )
            .map_err(|error| crate::db::DbError(error.to_string()))?;
            Ok(())
        })
        .unwrap();
    }

    /// Reads `(add_time, description, extra, name, icon)` for one gstore row.
    fn stored_snapshot(
        db: &DbHandle,
        app_id: &str,
    ) -> (i64, String, Option<String>, String, String) {
        let conn = db.reader().unwrap();
        conn.query_row(
            "SELECT add_time,description,extra,name,icon FROM channel_apps \
             WHERE channel_key = 'gstore' AND app_id = ?1",
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

    #[test]
    fn add_app_fetches_metadata_once_and_persists_it() {
        let dir = TempDir::new("add_meta");
        let db = DbHandle::open(&dir.0).unwrap();
        let metadata = Arc::new(FakeMetadataPort::new());
        metadata.set("acme", "repo", Some(metadata_new()));
        let driver = driver(&db, &metadata);

        driver
            .add_app(&app_summary("acme/repo", "Old Name", "acme", "repo"))
            .unwrap();

        assert_eq!(metadata.fetch_count(), 1, "add_app must fetch metadata once");
        let (name, icon, extra, user, repositories) = stored_row(&db, "acme/repo");
        assert_eq!(name, "Meta Name");
        assert_eq!(icon, "https://new.test/icon.png");
        assert_eq!(user, "acme");
        assert_eq!(repositories, "repo");
        let extra: Value = serde_json::from_str(extra.as_deref().unwrap()).unwrap();
        assert_eq!(
            extra.get("packageName").and_then(Value::as_str),
            Some("com.example.new")
        );
        assert_eq!(extra.get("keep").and_then(Value::as_str), Some("x"));
        assert!(
            extra.get("sourceId").is_none(),
            "sourceId stays in its own column"
        );
    }

    #[test]
    fn add_app_keeps_db_values_when_metadata_missing() {
        let dir = TempDir::new("add_no_meta");
        let db = DbHandle::open(&dir.0).unwrap();
        let metadata = Arc::new(FakeMetadataPort::new());
        metadata.set("acme", "repo", None);
        let driver = driver(&db, &metadata);

        driver
            .add_app(&app_summary("acme/repo", "Old Name", "acme", "repo"))
            .unwrap();

        assert_eq!(metadata.fetch_count(), 1, "one fetch, even for a miss");
        let (name, icon, extra, _, _) = stored_row(&db, "acme/repo");
        assert_eq!(name, "Old Name");
        assert_eq!(icon, "https://old.test/icon.png");
        let extra: Value = serde_json::from_str(extra.as_deref().unwrap()).unwrap();
        assert_eq!(
            extra.get("packageName").and_then(Value::as_str),
            Some("com.example.old"),
            "a miss must keep the existing package name"
        );
    }

    #[test]
    fn add_app_does_not_fetch_without_owner_repo() {
        let dir = TempDir::new("add_no_owner");
        let db = DbHandle::open(&dir.0).unwrap();
        let metadata = Arc::new(FakeMetadataPort::new());
        let driver = driver(&db, &metadata);

        driver
            .add_app(&app_summary("com.example.only", "Old Name", "", ""))
            .unwrap();

        assert_eq!(
            metadata.fetch_count(),
            0,
            "without owner/repo there is nothing to fetch"
        );
        let (name, icon, _, _, _) = stored_row(&db, "com.example.only");
        assert_eq!(name, "Old Name");
        assert_eq!(icon, "https://old.test/icon.png");
    }

    #[test]
    fn get_app_detail_refreshes_and_writes_back() {
        let dir = TempDir::new("detail_refresh");
        let db = DbHandle::open(&dir.0).unwrap();
        seed_stored(
            &db,
            "acme/repo",
            "Stored Name",
            "https://stored.test/icon.png",
            42,
            Some(r#"{"packageName":"com.example.old","keep":"x"}"#),
        );
        let metadata = Arc::new(FakeMetadataPort::new());
        metadata.set("acme", "repo", Some(metadata_new()));
        let driver = driver(&db, &metadata);

        let detail = driver.get_app_detail("acme/repo", false).unwrap();

        assert_eq!(metadata.fetch_count(), 1, "the detail read refreshes once");
        assert_eq!(detail.name, "Meta Name");
        assert_eq!(detail.icon, "https://new.test/icon.png");
        assert_eq!(detail.package_name.as_deref(), Some("com.example.new"));
        assert_eq!(detail.description, "keep description");

        let local = driver.get_app_info("acme/repo", false).unwrap();
        assert_eq!(metadata.fetch_count(), 1, "the local read must not fetch");
        assert_eq!(local.name, "Meta Name");
        assert_eq!(local.icon, "https://new.test/icon.png");

        let (add_time, description, extra, name, icon) = stored_snapshot(&db, "acme/repo");
        assert_eq!(add_time, 42, "add_time must not change");
        assert_eq!(description, "keep description", "description must not change");
        assert_eq!(name, "Meta Name");
        assert_eq!(icon, "https://new.test/icon.png");
        let extra: Value = serde_json::from_str(extra.as_deref().unwrap()).unwrap();
        assert_eq!(
            extra.get("packageName").and_then(Value::as_str),
            Some("com.example.new")
        );
        assert_eq!(
            extra.get("keep").and_then(Value::as_str),
            Some("x"),
            "extra must be merged, not replaced"
        );
    }

    #[test]
    fn get_app_detail_keeps_stored_values_when_metadata_missing() {
        let dir = TempDir::new("detail_no_meta");
        let db = DbHandle::open(&dir.0).unwrap();
        seed_stored(
            &db,
            "acme/repo",
            "Stored Name",
            "https://stored.test/icon.png",
            7,
            Some(r#"{"packageName":"com.example.stored"}"#),
        );
        let metadata = Arc::new(FakeMetadataPort::new());
        metadata.set("acme", "repo", None);
        let driver = driver(&db, &metadata);

        let detail = driver.get_app_detail("acme/repo", false).unwrap();

        assert_eq!(metadata.fetch_count(), 1, "one fetch, even for a miss");
        assert_eq!(detail.name, "Stored Name");
        assert_eq!(detail.icon, "https://stored.test/icon.png");
        let (_, _, extra, name, icon) = stored_snapshot(&db, "acme/repo");
        assert_eq!(name, "Stored Name", "a miss must not clobber the row");
        assert_eq!(icon, "https://stored.test/icon.png");
        let extra: Value = serde_json::from_str(extra.as_deref().unwrap()).unwrap();
        assert_eq!(
            extra.get("packageName").and_then(Value::as_str),
            Some("com.example.stored")
        );
    }
}
