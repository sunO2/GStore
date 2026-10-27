//! Catalog list/search/detail/category queries.
//!
//! [`CatalogService`] is the read side of the imported core catalog. It binds a
//! [`LocalDbDriver`] to the reserved `local_db` key and delegates every query
//! there, so the FTS5-then-LIKE search, rowid ordering, and category substring
//! semantics stay identical to the Dart `LocalDbChannel` instead of being
//! re-implemented in a second place.

use crate::channel::{ChannelCategory, ChannelDriver, LocalDbDriver};
use crate::db::DbHandle;
use crate::dto::{AppDetail, AppSummary, ChannelKey, ChannelKind, ChannelMeta};
use crate::error::Error;

/// Channel key used by the local catalog driver.
const LOCAL_DB_KEY: &str = "local_db";

/// Read-only catalog query facade over the imported core database.
pub struct CatalogService {
    // Kept so the service owns its handle even though the driver holds a clone.
    _db: DbHandle,
    driver: LocalDbDriver,
}

impl CatalogService {
    /// Creates the service around `db`.
    ///
    /// The database must already be migrated; [`DbHandle::open`] /
    /// [`DbHandle::open_at`] guarantee that.
    pub fn new(db: DbHandle) -> Result<Self, Error> {
        let key = ChannelKey::new(LOCAL_DB_KEY)?;
        let meta = ChannelMeta {
            kind: ChannelKind::LocalDb,
            name: "LocalDB".to_string(),
            description: "Imported local catalog".to_string(),
            enabled: true,
            priority: 10,
            support_offline: true,
            last_update_time: None,
            version: Some("1".to_string()),
        };
        let driver = LocalDbDriver::new(key, meta, db.clone());
        Ok(Self { _db: db, driver })
    }

    /// Lists every imported app in `rowid` order.
    pub fn list(&self) -> Result<Vec<AppSummary>, Error> {
        self.driver.get_all_apps(false)
    }

    /// Returns one page of [`CatalogService::list`] plus the unpaged total.
    ///
    /// `offset` past the end and `limit == 0` both yield an empty page. Because
    /// the slice is taken from the same `rowid`-ordered list, concatenating
    /// pages reproduces [`CatalogService::list`] exactly.
    pub fn list_page(&self, offset: u32, limit: u32) -> Result<(Vec<AppSummary>, usize), Error> {
        let all = self.list()?;
        let total = all.len();
        let start = usize::try_from(offset).unwrap_or(usize::MAX).min(total);
        let end = start
            .saturating_add(usize::try_from(limit).unwrap_or(usize::MAX))
            .min(total);
        Ok((all[start..end].to_vec(), total))
    }

    /// Searches by keyword: FTS5 `"word"*` first, then `LIKE %word%` without
    /// duplicates. An empty keyword returns an empty list.
    pub fn search(&self, keyword: &str) -> Result<Vec<AppSummary>, Error> {
        self.driver.search_apps(keyword, false)
    }

    /// Reads one app, mapping [`Error::NotFound`] to `None`.
    pub fn get_app(&self, app_id: &str) -> Result<Option<AppSummary>, Error> {
        match self.driver.get_app_info(app_id, false) {
            Ok(app) => Ok(Some(app)),
            Err(Error::NotFound(_)) => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// Lists the imported categories in `rowid` order.
    pub fn categories(&self) -> Result<Vec<ChannelCategory>, Error> {
        self.driver.get_all_categories(false)
    }

    /// Lists apps whose category contains `category_id` (substring `LIKE`).
    pub fn by_category(&self, category_id: &str) -> Result<Vec<AppSummary>, Error> {
        self.driver.search_by_category(category_id, false)
    }

    /// Reads one app's detail payload, mapping [`Error::NotFound`] to `None`.
    pub fn get_app_detail(&self, app_id: &str) -> Result<Option<AppDetail>, Error> {
        match self.driver.get_app_detail(app_id, false) {
            Ok(detail) => Ok(Some(detail)),
            Err(Error::NotFound(_)) => Ok(None),
            Err(error) => Err(error),
        }
    }
}
