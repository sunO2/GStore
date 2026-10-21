//! Channel driver surface derived from Dart `IChannel`.
//!
//! Every data operation takes the owning [`ChannelKey`]. Implementations must
//! call [`ChannelDriver::validate_key`] before touching channel-scoped state so a
//! driver can never read or write another channel's apps. The trait is
//! synchronous; the crate has no async runtime and no async traits.

use serde::{Deserialize, Serialize};

use crate::dto::{
    AppDetail, AppDownload, AppSummary, AppUpdate, ChannelKey, ChannelKind, ChannelMeta,
};
use crate::error::Error;

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

/// Full driver surface for one channel implementation.
///
/// Drivers are registered under exactly one [`ChannelKey`]. The key is passed to
/// every operation rather than captured per call so routed callers can prove
/// which channel they intended to reach; a mismatch is a typed
/// [`Error::InvalidArgument`] before any read/write happens.
pub trait ChannelDriver: Send + Sync {
    /// Stable key this driver owns.
    fn key(&self) -> &ChannelKey;

    /// Metadata advertised by this driver.
    fn meta(&self) -> &ChannelMeta;

    /// Channel implementation kind (convenience over [`ChannelDriver::meta`]).
    fn kind(&self) -> ChannelKind {
        self.meta().kind
    }

    /// Returns an error when `key` is not this driver's key.
    fn validate_key(&self, key: &ChannelKey) -> Result<(), Error> {
        if key == self.key() {
            Ok(())
        } else {
            Err(Error::InvalidArgument(format!(
                "channel key mismatch: driver '{}' received '{key}'",
                self.key()
            )))
        }
    }

    /// Initializes channel resources.
    fn initialize(&self, key: &ChannelKey) -> Result<(), Error>;

    /// Whether [`ChannelDriver::initialize`] completed.
    fn is_initialized(&self, key: &ChannelKey) -> Result<bool, Error>;

    /// Whether the channel is currently usable.
    fn check_available(&self, key: &ChannelKey) -> Result<bool, Error>;

    /// Lists all channel-owned apps.
    fn get_all_apps(&self, key: &ChannelKey, force_refresh: bool)
        -> Result<Vec<AppSummary>, Error>;

    /// Reads one channel-owned app; `None` when it is not present.
    fn get_app_info(
        &self,
        key: &ChannelKey,
        app_id: &str,
        force_refresh: bool,
    ) -> Result<Option<AppSummary>, Error>;

    /// Reads one app's detail page payload.
    fn get_app_detail(
        &self,
        key: &ChannelKey,
        app_id: &str,
        force_refresh: bool,
    ) -> Result<AppDetail, Error>;

    /// Whether the detail page may load downloads/readme/statistics separately.
    fn supports_progressive_loading(&self, key: &ChannelKey) -> Result<bool, Error> {
        self.validate_key(key)?;
        Ok(false)
    }

    /// Progressive detail block: downloads only.
    fn fetch_downloads(&self, key: &ChannelKey, app_id: &str) -> Result<Vec<AppDownload>, Error> {
        self.validate_key(key)?;
        let _ = app_id;
        Err(Error::Unsupported(
            "channel does not support progressive downloads".to_string(),
        ))
    }

    /// Progressive detail block: README only.
    fn fetch_readme(&self, key: &ChannelKey, app_id: &str) -> Result<Option<String>, Error> {
        self.validate_key(key)?;
        let _ = app_id;
        Err(Error::Unsupported(
            "channel does not support progressive readme".to_string(),
        ))
    }

    /// Progressive detail block: statistics/version/developer only.
    fn fetch_statistics(
        &self,
        key: &ChannelKey,
        app_id: &str,
    ) -> Result<Option<serde_json::Map<String, serde_json::Value>>, Error> {
        self.validate_key(key)?;
        let _ = app_id;
        Err(Error::Unsupported(
            "channel does not support progressive statistics".to_string(),
        ))
    }

    /// Checks one app for an update.
    fn check_app_update(&self, key: &ChannelKey, app_id: &str) -> Result<AppUpdate, Error>;

    /// Adds/saves an app into this channel.
    fn add_app(&self, key: &ChannelKey, app: &AppSummary) -> Result<(), Error>;

    /// Normalizes an app id for this channel (default: unchanged).
    fn canonical_app_id(&self, key: &ChannelKey, app: &AppSummary) -> Result<String, Error> {
        self.validate_key(key)?;
        Ok(app.app_id.clone())
    }

    /// Removes an app from this channel.
    fn remove_app(&self, key: &ChannelKey, app_id: &str) -> Result<(), Error>;

    /// Searches apps by name/description.
    fn search_apps(
        &self,
        key: &ChannelKey,
        keyword: &str,
        force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error>;

    /// Searches apps by category id.
    fn search_by_category(
        &self,
        key: &ChannelKey,
        category_id: &str,
        force_refresh: bool,
    ) -> Result<Vec<AppSummary>, Error>;

    /// Lists all categories exposed by this channel.
    fn get_all_categories(
        &self,
        key: &ChannelKey,
        force_refresh: bool,
    ) -> Result<Vec<ChannelCategory>, Error>;

    /// Whether a data update is available.
    fn check_update(&self, key: &ChannelKey) -> Result<bool, Error>;

    /// Runs a data update, reporting `(current, total)` progress.
    fn do_update(
        &self,
        key: &ChannelKey,
        progress: Option<&mut dyn FnMut(u64, u64)>,
    ) -> Result<bool, Error>;

    /// Reads channel configuration.
    fn get_config(
        &self,
        key: &ChannelKey,
        force_refresh: bool,
    ) -> Result<Option<ChannelConfig>, Error>;

    /// Clears channel caches.
    fn clear_cache(&self, key: &ChannelKey) -> Result<(), Error>;

    /// Current cache size in bytes.
    fn get_cache_size(&self, key: &ChannelKey) -> Result<u64, Error>;

    /// Releases channel resources.
    fn dispose(&self, key: &ChannelKey) -> Result<(), Error>;
}
