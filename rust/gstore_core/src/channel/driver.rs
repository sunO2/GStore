//! Channel driver surface derived from Dart `IChannel`.
//!
//! A driver is bound to exactly one [`ChannelKey`] at construction. Public data
//! methods never receive a key, so a caller holding a handle for channel A has
//! no parameter with which to address channel B. Routing by key lives in
//! [`crate::channel::ChannelRegistry::driver`].
//!
//! The trait is synchronous and sealed: the crate has no async runtime, and
//! downstream crates cannot implement the trait because its supertrait lives in
//! the private `sealed` module.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::sealed;
use crate::dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelKind, ChannelMeta,
};
use crate::error::Error;

/// Icons resolved in one page-scoped prefetch, keyed by app id.
///
/// A driver fills this map once per page via [`ChannelDriver::prefetch_icons`]
/// and the page then reads each row through
/// [`ChannelDriver::get_app_info_with`]. The map is intentionally a plain value
/// (never stored on the driver): a driver-level cache would never invalidate,
/// so a refreshed repository index would keep serving stale home icons.
pub type IconMap = BTreeMap<String, String>;

/// A channel category (mirrors Dart `db.AppCategory`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelCategory {
    /// Stable category id.
    pub id: String,
    /// Human-readable label.
    pub description: String,
    /// Icon URL or pack-relative icon name.
    pub icon: String,
}

/// Channel configuration (mirrors Dart `db.AppInfoConfig`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelConfig {
    /// Configuration/data version.
    pub version: String,
    /// Optional proxy URL.
    pub proxy: Option<String>,
}

/// Key-bound channel driver surface.
///
/// Every data method operates on the driver's bound key. There is deliberately
/// no method taking a foreign [`ChannelKey`]; callers obtain a handle via
/// `ChannelRegistry::driver(&key)` and can only affect that channel.
///
/// The trait is sealed by `sealed::Sealed`. A downstream crate cannot name the
/// private module, so it cannot implement this trait:
///
/// ```compile_fail
/// // Fails: `gstore_core::channel::sealed` is private to the crate.
/// use gstore_core::channel::sealed::Sealed;
/// struct ForeignDriver;
/// impl Sealed for ForeignDriver {}
/// ```
pub trait ChannelDriver: sealed::Sealed + Send + Sync {
    /// Stable key bound at construction.
    fn key(&self) -> &ChannelKey;

    /// Metadata advertised by this driver.
    fn meta(&self) -> &ChannelMeta;

    /// Channel implementation kind (convenience over [`ChannelDriver::meta`]).
    fn kind(&self) -> ChannelKind {
        self.meta().kind
    }

    /// Initializes channel resources.
    fn initialize(&self) -> Result<(), Error>;

    /// Whether [`ChannelDriver::initialize`] completed.
    fn is_initialized(&self) -> Result<bool, Error>;

    /// Whether the channel is currently usable.
    fn check_available(&self) -> Result<bool, Error>;

    /// Lists all apps owned by this driver's bound channel.
    fn get_all_apps(&self, force_refresh: bool) -> Result<Vec<AppSummary>, Error>;

    /// Reads one app owned by this driver's bound channel; missing is
    /// [`Error::NotFound`].
    fn get_app_info(&self, app_id: &str, force_refresh: bool) -> Result<AppSummary, Error>;

    /// Reads one app with Dart's optional `version` hint.
    ///
    /// Defaults to [`ChannelDriver::get_app_info`] and ignores `version`, so
    /// drivers whose protocol has no version selector are unaffected. A
    /// script-backed driver forwards the hint to the script's `main` params
    /// only when it is present, matching Dart `JsChannel.getAppInfo`.
    fn get_app_info_versioned(
        &self,
        app_id: &str,
        force_refresh: bool,
        version: Option<&str>,
    ) -> Result<AppSummary, Error> {
        let _ = version;
        self.get_app_info(app_id, force_refresh)
    }

    /// Resolves icons for `app_ids` once so a page can render many rows without
    /// one icon probe per row.
    ///
    /// The default returns an empty map, which makes every
    /// [`ChannelDriver::get_app_info_with`] call fall back to
    /// [`ChannelDriver::get_app_info`]; drivers that can batch their index
    /// lookup override this.
    fn prefetch_icons(&self, _app_ids: &[String]) -> IconMap {
        IconMap::new()
    }

    /// Reads one app, reusing an icon already resolved by
    /// [`ChannelDriver::prefetch_icons`].
    ///
    /// A hit in `icons` supplies the icon directly; everything else is produced
    /// by the same code path as [`ChannelDriver::get_app_info`]. A miss falls
    /// back to [`ChannelDriver::get_app_info`] unchanged, so single-row
    /// semantics (including any index refresh) are never altered.
    ///
    /// # Errors
    /// Propagates the [`Error`] returned by [`ChannelDriver::get_app_info`].
    fn get_app_info_with(&self, app_id: &str, _icons: &IconMap) -> Result<AppSummary, Error> {
        self.get_app_info(app_id, false)
    }

    /// Reads one app's detail page payload.
    fn get_app_detail(&self, app_id: &str, force_refresh: bool) -> Result<AppDetail, Error>;

    /// Reads one app's detail with Dart's optional `version` hint.
    ///
    /// Defaults to [`ChannelDriver::get_app_detail`] and ignores `version`; a
    /// script-backed driver forwards it to the script's `main` params only when
    /// it is present, matching Dart `JsChannel.getAppDetail`.
    fn get_app_detail_versioned(
        &self,
        app_id: &str,
        force_refresh: bool,
        version: Option<&str>,
    ) -> Result<AppDetail, Error> {
        let _ = version;
        self.get_app_detail(app_id, force_refresh)
    }

    /// Whether the detail page may load downloads/readme/statistics separately.
    fn supports_progressive_loading(&self) -> Result<bool, Error> {
        Ok(false)
    }

    /// Progressive detail block: downloads only.
    fn fetch_downloads(&self, app_id: &str) -> Result<Vec<AppDownload>, Error> {
        let _ = app_id;
        Err(Error::Unsupported(
            "channel does not support progressive downloads".to_string(),
        ))
    }

    /// Progressive detail block: README only.
    fn fetch_readme(&self, app_id: &str) -> Result<Option<String>, Error> {
        let _ = app_id;
        Err(Error::Unsupported(
            "channel does not support progressive readme".to_string(),
        ))
    }

    /// Progressive detail block: statistics/version/developer only.
    fn fetch_statistics(
        &self,
        app_id: &str,
    ) -> Result<Option<serde_json::Map<String, serde_json::Value>>, Error> {
        let _ = app_id;
        Err(Error::Unsupported(
            "channel does not support progressive statistics".to_string(),
        ))
    }

    /// Checks one app for an update.
    fn check_app_update(&self, app_id: &str) -> Result<AppUpdate, Error>;

    /// Adds/saves an app into this channel.
    fn add_app(&self, app: &AppSummary) -> Result<(), Error>;

    /// Normalizes an app id for this channel (default: unchanged).
    fn canonical_app_id(&self, app: &AppSummary) -> Result<String, Error> {
        Ok(app.app_id.clone())
    }

    /// Removes an app from this channel.
    fn remove_app(&self, app_id: &str) -> Result<(), Error>;

    /// Searches apps by name/description.
    fn search_apps(&self, keyword: &str, force_refresh: bool) -> Result<Vec<AppSummary>, Error>;

    /// Searches apps by category id.
    fn search_by_category(
        &self,
        category_id: &str,
        force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error>;

    /// Lists all categories exposed by this channel.
    fn get_all_categories(&self, force_refresh: bool) -> Result<Vec<ChannelCategory>, Error>;

    /// Whether a data update is available.
    fn check_update(&self) -> Result<bool, Error>;

    /// Runs a data update, reporting `(current, total)` progress.
    fn do_update(&self, progress: Option<&mut dyn FnMut(u64, u64)>) -> Result<bool, Error>;

    /// Reads channel configuration.
    fn get_config(&self, force_refresh: bool) -> Result<Option<ChannelConfig>, Error>;

    /// Clears channel caches.
    fn clear_cache(&self) -> Result<(), Error>;

    /// Current cache size in bytes.
    fn get_cache_size(&self) -> Result<u64, Error>;

    /// Releases channel resources.
    fn dispose(&self) -> Result<(), Error>;
}
