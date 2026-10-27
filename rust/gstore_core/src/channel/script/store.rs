//! Local channel-app store injected into a [`ScriptChannel`](super::ScriptChannel).
//!
//! Mirrors Dart `JsChannel`'s `ChannelAddedAppDao`: every row is read/written
//! with the bound channel key, which is supplied by the driver (never by a
//! script payload). The trait lives in core so the host can back it with the
//! existing `channel_apps` table without core depending on SQLite.

use std::sync::Arc;

use crate::dto::{AppSummary, ChannelKey};
use crate::error::Error;

/// Per-channel persistence used for Dart's "script returned nothing" fallbacks.
pub trait ScriptChannelStore: Send + Sync {
    /// Lists every saved app for `channel`.
    fn list_apps(&self, channel: &ChannelKey) -> Result<Vec<AppSummary>, Error>;

    /// Reads one saved app, or `None` when the channel has no such row.
    fn get_app(&self, channel: &ChannelKey, app_id: &str) -> Result<Option<AppSummary>, Error>;

    /// Upserts rows for `channel`. Existing rows are updated, never purged.
    fn insert_apps(&self, channel: &ChannelKey, apps: &[AppSummary]) -> Result<(), Error>;

    /// Removes one row from `channel`; a missing row is a no-op.
    fn remove_app(&self, channel: &ChannelKey, app_id: &str) -> Result<(), Error>;
}

pub(crate) type StoreSlot<'a> = Option<&'a Arc<dyn ScriptChannelStore>>;

pub(crate) fn list(slot: StoreSlot<'_>, channel: &ChannelKey) -> Result<Vec<AppSummary>, Error> {
    match slot {
        Some(store) => store.list_apps(channel),
        None => Ok(Vec::new()),
    }
}

pub(crate) fn get(
    slot: StoreSlot<'_>,
    channel: &ChannelKey,
    app_id: &str,
) -> Result<Option<AppSummary>, Error> {
    match slot {
        Some(store) => store.get_app(channel, app_id),
        None => Ok(None),
    }
}

pub(crate) fn insert(
    slot: StoreSlot<'_>,
    channel: &ChannelKey,
    apps: &[AppSummary],
) -> Result<(), Error> {
    match slot {
        Some(store) => store.insert_apps(channel, apps),
        None => Err(Error::Unsupported(
            "script channel has no bound app store".to_string(),
        )),
    }
}

pub(crate) fn remove(slot: StoreSlot<'_>, channel: &ChannelKey, app_id: &str) -> Result<(), Error> {
    match slot {
        Some(store) => store.remove_app(channel, app_id),
        None => Err(Error::Unsupported(
            "script channel has no bound app store".to_string(),
        )),
    }
}
