//! In-memory fakes for tests and callers without a database yet.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use crate::dto::{AppDetail, AppSummary, AppUpdate, ChannelKey, ChannelMeta, DetailSection};
use crate::error::Error;

use super::driver::{ChannelCategory, ChannelConfig, ChannelDriver};
use super::store::{ChannelRecord, ChannelStore};

/// Thread-safe in-memory [`ChannelStore`] fake.
#[derive(Debug, Default)]
pub struct InMemoryChannelStore {
    records: RwLock<BTreeMap<ChannelKey, ChannelRecord>>,
}

impl InMemoryChannelStore {
    /// Creates an empty store.
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of registered channels.
    pub fn len(&self) -> Result<usize, Error> {
        Ok(self.read()?.len())
    }

    /// Whether no channel is registered.
    pub fn is_empty(&self) -> Result<bool, Error> {
        Ok(self.read()?.is_empty())
    }

    /// Removes every channel.
    pub fn clear(&self) -> Result<(), Error> {
        self.write()?.clear();
        Ok(())
    }

    fn read(&self) -> Result<RwLockReadGuard<'_, BTreeMap<ChannelKey, ChannelRecord>>, Error> {
        self.records
            .read()
            .map_err(|_| Error::Internal("channel store lock poisoned".to_string()))
    }

    fn write(&self) -> Result<RwLockWriteGuard<'_, BTreeMap<ChannelKey, ChannelRecord>>, Error> {
        self.records
            .write()
            .map_err(|_| Error::Internal("channel store lock poisoned".to_string()))
    }

    fn set_enabled(&self, key: &ChannelKey, enabled: bool) -> Result<(), Error> {
        let mut records = self.write()?;
        let record = records
            .get_mut(key)
            .ok_or_else(|| Error::NotFound(format!("channel not registered: {key}")))?;
        record.meta.enabled = enabled;
        Ok(())
    }
}

impl ChannelStore for InMemoryChannelStore {
    fn register(&self, record: ChannelRecord) -> Result<(), Error> {
        let mut records = self.write()?;
        match records.get(&record.key) {
            Some(existing) if existing == &record => return Ok(()),
            Some(_) => {
                return Err(Error::Conflict(format!(
                    "channel already registered: {}",
                    record.key
                )));
            }
            None => {}
        }
        records.insert(record.key.clone(), record);
        Ok(())
    }

    fn unregister(&self, key: &ChannelKey) -> Result<(), Error> {
        let mut records = self.write()?;
        records
            .remove(key)
            .map(|_| ())
            .ok_or_else(|| Error::NotFound(format!("channel not registered: {key}")))
    }

    fn get(&self, key: &ChannelKey) -> Result<Option<ChannelRecord>, Error> {
        Ok(self.read()?.get(key).cloned())
    }

    fn list(&self) -> Result<Vec<ChannelRecord>, Error> {
        Ok(self.read()?.values().cloned().collect())
    }

    fn enable(&self, key: &ChannelKey) -> Result<(), Error> {
        self.set_enabled(key, true)
    }

    fn disable(&self, key: &ChannelKey) -> Result<(), Error> {
        self.set_enabled(key, false)
    }

    fn set_priority(&self, key: &ChannelKey, priority: i32) -> Result<(), Error> {
        let mut records = self.write()?;
        let record = records
            .get_mut(key)
            .ok_or_else(|| Error::NotFound(format!("channel not registered: {key}")))?;
        record.meta.priority = priority;
        Ok(())
    }

    fn priority_order(&self) -> Result<Vec<ChannelRecord>, Error> {
        let mut records: Vec<ChannelRecord> = self
            .read()?
            .values()
            .filter(|record| record.meta.enabled)
            .cloned()
            .collect();
        records.sort_by(|left, right| {
            left.meta
                .priority
                .cmp(&right.meta.priority)
                .then_with(|| left.key.cmp(&right.key))
        });
        Ok(records)
    }
}

/// In-memory [`ChannelDriver`] fake bound to one [`ChannelKey`].
///
/// Every method validates the caller's key first, so cross-channel reads and
/// writes fail with [`Error::InvalidArgument`] and never touch this driver's
/// app map.
#[derive(Debug)]
pub struct InMemoryChannelDriver {
    key: ChannelKey,
    meta: ChannelMeta,
    initialized: AtomicBool,
    apps: RwLock<BTreeMap<String, AppSummary>>,
    categories: RwLock<Vec<ChannelCategory>>,
    config: RwLock<Option<ChannelConfig>>,
    cache_size: AtomicU64,
}

impl InMemoryChannelDriver {
    /// Creates a driver owning `key` with the supplied metadata.
    pub fn new(key: ChannelKey, meta: ChannelMeta) -> Self {
        Self {
            key,
            meta,
            initialized: AtomicBool::new(false),
            apps: RwLock::new(BTreeMap::new()),
            categories: RwLock::new(Vec::new()),
            config: RwLock::new(None),
            cache_size: AtomicU64::new(0),
        }
    }

    /// Seeds the driver's app map.
    pub fn with_apps(mut self, apps: Vec<AppSummary>) -> Self {
        self.apps = RwLock::new(
            apps.into_iter()
                .map(|app| (app.app_id.clone(), app))
                .collect(),
        );
        self
    }

    /// Seeds the driver's categories.
    pub fn with_categories(mut self, categories: Vec<ChannelCategory>) -> Self {
        self.categories = RwLock::new(categories);
        self
    }

    /// Seeds the driver's configuration.
    pub fn with_config(mut self, config: Option<ChannelConfig>) -> Self {
        self.config = RwLock::new(config);
        self
    }

    /// Seeds the reported cache size.
    pub fn with_cache_size(mut self, cache_size: u64) -> Self {
        self.cache_size = AtomicU64::new(cache_size);
        self
    }

    fn read_apps(&self) -> Result<RwLockReadGuard<'_, BTreeMap<String, AppSummary>>, Error> {
        self.apps
            .read()
            .map_err(|_| Error::Internal("channel driver app lock poisoned".to_string()))
    }

    fn write_apps(&self) -> Result<RwLockWriteGuard<'_, BTreeMap<String, AppSummary>>, Error> {
        self.apps
            .write()
            .map_err(|_| Error::Internal("channel driver app lock poisoned".to_string()))
    }

    fn read_categories(&self) -> Result<RwLockReadGuard<'_, Vec<ChannelCategory>>, Error> {
        self.categories
            .read()
            .map_err(|_| Error::Internal("channel driver category lock poisoned".to_string()))
    }

    fn read_config(&self) -> Result<RwLockReadGuard<'_, Option<ChannelConfig>>, Error> {
        self.config
            .read()
            .map_err(|_| Error::Internal("channel driver config lock poisoned".to_string()))
    }

    fn require_app(&self, app_id: &str) -> Result<AppSummary, Error> {
        self.read_apps()?
            .get(app_id)
            .cloned()
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))
    }
}

impl ChannelDriver for InMemoryChannelDriver {
    fn key(&self) -> &ChannelKey {
        &self.key
    }

    fn meta(&self) -> &ChannelMeta {
        &self.meta
    }

    fn initialize(&self, key: &ChannelKey) -> Result<(), Error> {
        self.validate_key(key)?;
        self.initialized.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn is_initialized(&self, key: &ChannelKey) -> Result<bool, Error> {
        self.validate_key(key)?;
        Ok(self.initialized.load(Ordering::SeqCst))
    }

    fn check_available(&self, key: &ChannelKey) -> Result<bool, Error> {
        self.validate_key(key)?;
        Ok(self.initialized.load(Ordering::SeqCst))
    }

    fn get_all_apps(
        &self,
        key: &ChannelKey,
        _force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        self.validate_key(key)?;
        Ok(self.read_apps()?.values().cloned().collect())
    }

    fn get_app_info(
        &self,
        key: &ChannelKey,
        app_id: &str,
        _force_refresh: bool,
    ) -> Result<Option<AppSummary>, Error> {
        self.validate_key(key)?;
        Ok(self.read_apps()?.get(app_id).cloned())
    }

    fn get_app_detail(
        &self,
        key: &ChannelKey,
        app_id: &str,
        _force_refresh: bool,
    ) -> Result<AppDetail, Error> {
        self.validate_key(key)?;
        let app = self.require_app(app_id)?;
        let AppSummary {
            app_id,
            package_name,
            name,
            user,
            icon,
            des,
            repositories: _,
            readme: _,
            category: _,
            extra,
        } = app;
        let developer = (!user.is_empty()).then_some(user);
        Ok(AppDetail {
            app_id,
            name,
            icon,
            description: des,
            version: None,
            developer,
            package_name,
            project_url: None,
            channel: self.meta.kind,
            sections: vec![DetailSection::Version, DetailSection::Readme],
            downloads: Vec::new(),
            extra: extra.unwrap_or_default(),
        })
    }

    fn supports_progressive_loading(&self, key: &ChannelKey) -> Result<bool, Error> {
        self.validate_key(key)?;
        Ok(true)
    }

    fn fetch_downloads(
        &self,
        key: &ChannelKey,
        app_id: &str,
    ) -> Result<Vec<crate::dto::AppDownload>, Error> {
        self.validate_key(key)?;
        self.require_app(app_id)?;
        Ok(Vec::new())
    }

    fn fetch_readme(&self, key: &ChannelKey, app_id: &str) -> Result<Option<String>, Error> {
        self.validate_key(key)?;
        Ok(self.require_app(app_id)?.readme)
    }

    fn fetch_statistics(
        &self,
        key: &ChannelKey,
        app_id: &str,
    ) -> Result<Option<serde_json::Map<String, serde_json::Value>>, Error> {
        self.validate_key(key)?;
        Ok(self.require_app(app_id)?.extra)
    }

    fn check_app_update(&self, key: &ChannelKey, app_id: &str) -> Result<AppUpdate, Error> {
        self.validate_key(key)?;
        let detail = self.get_app_detail(key, app_id, false)?;
        let package_name = detail.package_name.clone().unwrap_or_default();
        Ok(AppUpdate {
            app_id: detail.app_id.clone(),
            package_name,
            name: detail.name.clone(),
            icon: Some(detail.icon.clone()),
            latest_version: detail.version.clone(),
            latest_download: None,
            detail,
        })
    }

    fn add_app(&self, key: &ChannelKey, app: &AppSummary) -> Result<(), Error> {
        self.validate_key(key)?;
        self.write_apps()?.insert(app.app_id.clone(), app.clone());
        Ok(())
    }

    fn remove_app(&self, key: &ChannelKey, app_id: &str) -> Result<(), Error> {
        self.validate_key(key)?;
        self.write_apps()?
            .remove(app_id)
            .map(|_| ())
            .ok_or_else(|| Error::NotFound(format!("app not found: {app_id}")))
    }

    fn search_apps(
        &self,
        key: &ChannelKey,
        keyword: &str,
        _force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        self.validate_key(key)?;
        let needle = keyword.to_lowercase();
        Ok(self
            .read_apps()?
            .values()
            .filter(|app| {
                app.name.to_lowercase().contains(&needle)
                    || app.des.to_lowercase().contains(&needle)
            })
            .cloned()
            .collect())
    }

    fn search_by_category(
        &self,
        key: &ChannelKey,
        category_id: &str,
        _force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error> {
        self.validate_key(key)?;
        Ok(self
            .read_apps()?
            .values()
            .filter(|app| {
                app.category.as_ref().is_some_and(|categories| {
                    categories
                        .iter()
                        .any(|category| category.as_str() == category_id)
                })
            })
            .cloned()
            .collect())
    }

    fn get_all_categories(
        &self,
        key: &ChannelKey,
        _force_refresh: bool,
    ) -> Result<Vec<ChannelCategory>, Error> {
        self.validate_key(key)?;
        Ok(self.read_categories()?.clone())
    }

    fn check_update(&self, key: &ChannelKey) -> Result<bool, Error> {
        self.validate_key(key)?;
        Ok(false)
    }

    fn do_update(
        &self,
        key: &ChannelKey,
        progress: Option<&mut dyn FnMut(u64, u64)>,
    ) -> Result<bool, Error> {
        self.validate_key(key)?;
        let total = self.read_apps()?.len() as u64;
        if let Some(callback) = progress {
            callback(0, total);
            callback(total, total);
        }
        Ok(true)
    }

    fn get_config(
        &self,
        key: &ChannelKey,
        _force_refresh: bool,
    ) -> Result<Option<ChannelConfig>, Error> {
        self.validate_key(key)?;
        Ok(self.read_config()?.clone())
    }

    fn clear_cache(&self, key: &ChannelKey) -> Result<(), Error> {
        self.validate_key(key)?;
        self.cache_size.store(0, Ordering::SeqCst);
        Ok(())
    }

    fn get_cache_size(&self, key: &ChannelKey) -> Result<u64, Error> {
        self.validate_key(key)?;
        Ok(self.cache_size.load(Ordering::SeqCst))
    }

    fn dispose(&self, key: &ChannelKey) -> Result<(), Error> {
        self.validate_key(key)?;
        self.initialized.store(false, Ordering::SeqCst);
        Ok(())
    }
}
