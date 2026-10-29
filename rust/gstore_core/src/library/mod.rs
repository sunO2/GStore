//! Unified library write service: channel metadata first, membership second.
//!
//! `added_apps` and `channel_apps` stay physically separate tables (see
//! `.omo/plans/channel-library-unification.md` §2). [`LibraryService`] is the
//! single call site that writes both, so callers get "one library, one action"
//! without a physical table merge:
//!
//! * `channel_apps` = the channel's saved list plus its metadata (owned by the
//!   channel drivers, `js_*` included).
//! * `added_apps` = the user's library membership (owned by
//!   [`AddedAppsService`], which never touches drivers).
//!
//! ## Ordering is the contract
//!
//! [`LibraryService::add`] writes channel metadata **before** membership. A
//! half-finished add then leaves a harmless "saved to the channel, not in the
//! library" row instead of an "in the library without metadata" row. The two
//! writes deliberately run as two independent transactions: `driver.add_app`
//! takes the database writer mutex internally, so nesting it inside an
//! `added_apps` write transaction would re-lock a non-reentrant mutex and
//! deadlock. **Never** call `driver.add_app` while holding a writer guard.
//!
//! local-db channels report [`Error::Unsupported`] from `add_app` (their
//! metadata lives in the `apps` catalog); that is treated as success because
//! the membership write is still valid.

use std::sync::Arc;

use crate::added::apps::{AddedApp, AddedAppsService};
use crate::channel::ChannelDriver;
use crate::dto::AppSummary;
use crate::error::Error;

/// Resolves a channel code to a driver that can write channel metadata.
///
/// Returning `None` means the channel has no writable driver (unknown channel,
/// read-only channel, or script lane not hosted in core). In that case
/// [`LibraryService::add`] skips the metadata phase and still writes membership.
pub trait LibraryDriverResolver: Send + Sync {
    /// Returns the writable driver bound to `channel`, or `None`.
    fn writable_driver(&self, channel: &str) -> Option<Arc<dyn ChannelDriver>>;
}

/// Two-phase library writes over `channel_apps` and `added_apps`.
pub struct LibraryService {
    added: AddedAppsService,
    drivers: Arc<dyn LibraryDriverResolver>,
}

impl LibraryService {
    /// Creates the service around the membership store and the driver resolver.
    pub fn new(added: AddedAppsService, drivers: Arc<dyn LibraryDriverResolver>) -> Self {
        Self { added, drivers }
    }

    /// Adds an app to the library: channel metadata first, membership second.
    ///
    /// * A writable driver's [`ChannelDriver::add_app`] runs first. Its
    ///   [`Error::Unsupported`] (local-db catalog channel) is ignored; any other
    ///   error aborts **before** the membership write.
    /// * The membership id is [`ChannelDriver::canonical_app_id`] when a driver
    ///   exists, otherwise `app.app_id`.
    /// * `sort_order` is forwarded to [`AddedAppsService::add`].
    pub fn add(
        &self,
        channel: &str,
        app: &AppSummary,
        sort_order: Option<i64>,
    ) -> Result<AddedApp, Error> {
        let driver = self.drivers.writable_driver(channel);
        if let Some(driver) = &driver {
            match driver.add_app(app) {
                Ok(()) => {}
                // local_db keeps its metadata in the `apps` catalog; there is no
                // `channel_apps` row to write, and membership is still valid.
                Err(Error::Unsupported(_)) => {}
                Err(error) => return Err(error),
            }
        }
        let canonical = match &driver {
            Some(driver) => driver.canonical_app_id(app)?,
            None => app.app_id.clone(),
        };
        self.added.add(channel, &canonical, sort_order)
    }

    /// Adds only the `added_apps` membership row; **never** writes
    /// `channel_apps`.
    ///
    /// Backup restore uses this path for reference-only backup items: their
    /// exported name/icon are placeholders (`appName == appId`, no icon), so
    /// routing them through [`LibraryService::add`] would overwrite a good
    /// `channel_apps` metadata row with the placeholder. The real metadata is
    /// restored separately from the backup's `channelApps` section. No driver
    /// lookup and no canonicalization happen here: the membership id is exactly
    /// the id the backup recorded.
    pub fn add_membership(
        &self,
        channel: &str,
        app_id: &str,
        sort_order: Option<i64>,
    ) -> Result<AddedApp, Error> {
        self.added.add(channel, app_id, sort_order)
    }

    /// Removes an app from the library.
    ///
    /// Only the `added_apps` membership row is deleted; the channel's saved
    /// `channel_apps` row stays, which is the "still saved to the channel" state.
    /// Returns whether a membership row existed.
    pub fn remove(&self, channel: &str, app_id: &str) -> Result<bool, Error> {
        self.added.remove(channel, app_id)
    }

    /// Toggles library membership for `app`; returns whether it is now added.
    ///
    /// Present membership is removed (`false`); absent membership goes through
    /// [`LibraryService::add`] (`true`), including its metadata phase.
    pub fn toggle(&self, channel: &str, app: &AppSummary) -> Result<bool, Error> {
        let canonical = self.canonical_id(channel, app)?;
        if self.added.is_added(channel, &canonical)? {
            self.added.remove(channel, &canonical)?;
            Ok(false)
        } else {
            self.add(channel, app, None)?;
            Ok(true)
        }
    }

    /// Sets one app's sort weight; missing membership is [`Error::NotFound`].
    pub fn set_order(&self, channel: &str, app_id: &str, sort_order: i64) -> Result<(), Error> {
        self.added.set_order(channel, app_id, sort_order)
    }

    /// Deletes every membership row in one channel; returns the row count.
    pub fn clear_channel(&self, channel: &str) -> Result<usize, Error> {
        self.added.clear_channel(channel)
    }

    /// Deletes every membership row; returns the row count.
    pub fn clear_all(&self) -> Result<usize, Error> {
        self.added.clear_all()
    }

    /// Replaces all tags for one app.
    pub fn set_tags(&self, channel: &str, app_id: &str, tags: &[String]) -> Result<(), Error> {
        self.added.set_tags(channel, app_id, tags)
    }

    /// Adds one tag to an app.
    pub fn add_tag(&self, channel: &str, app_id: &str, tag: &str) -> Result<(), Error> {
        self.added.add_tag(channel, app_id, tag)
    }

    /// Removes one tag from an app.
    pub fn remove_tag(&self, channel: &str, app_id: &str, tag: &str) -> Result<(), Error> {
        self.added.remove_tag(channel, app_id, tag)
    }

    /// Returns one app's tags, earliest first.
    pub fn tags(&self, channel: &str, app_id: &str) -> Result<Vec<String>, Error> {
        self.added.tags(channel, app_id)
    }

    /// Returns all tags keyed by `"{channel}:{app_id}"`.
    pub fn tags_index(&self) -> Result<std::collections::BTreeMap<String, Vec<String>>, Error> {
        self.added.tags_index()
    }

    /// Lists every membership row, newest first (`add_time DESC`).
    pub fn list(&self) -> Result<Vec<AddedApp>, Error> {
        self.added.list()
    }

    /// Lists one channel's membership rows, newest first (`add_time DESC`).
    pub fn list_channel(&self, channel: &str) -> Result<Vec<AddedApp>, Error> {
        self.added.list_channel(channel)
    }

    /// Returns one membership row, if present.
    pub fn get(&self, channel: &str, app_id: &str) -> Result<Option<AddedApp>, Error> {
        self.added.get(channel, app_id)
    }

    /// Returns whether `(channel, app_id)` is a library member.
    pub fn is_added(&self, channel: &str, app_id: &str) -> Result<bool, Error> {
        self.added.is_added(channel, app_id)
    }

    /// Total number of library members.
    pub fn total_count(&self) -> Result<i64, Error> {
        self.added.total_count()
    }

    /// Number of library members in one channel.
    pub fn count_channel(&self, channel: &str) -> Result<i64, Error> {
        self.added.count_channel(channel)
    }

    /// Renames a membership app id inside one channel.
    pub fn rename(&self, channel: &str, old_app_id: &str, new_app_id: &str) -> Result<bool, Error> {
        self.added.rename(channel, old_app_id, new_app_id)
    }

    fn canonical_id(&self, channel: &str, app: &AppSummary) -> Result<String, Error> {
        match self.drivers.writable_driver(channel) {
            Some(driver) => driver.canonical_app_id(app),
            None => Ok(app.app_id.clone()),
        }
    }
}
