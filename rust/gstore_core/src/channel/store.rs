//! Registry persistence contract.
//!
//! [`ChannelStore`] owns registry state only; app rows and channel databases are
//! driver concerns. The SQLite implementation arrives in Todo 8. This trait is
//! synchronous and uses `&self` so both lock-backed fakes and a shared
//! connection can implement it.

use serde::{Deserialize, Serialize};

use crate::dto::{ChannelKey, ChannelKind, ChannelMeta};
use crate::error::Error;

/// One registered channel: its stable key plus observable metadata.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelRecord {
    /// Stable channel identity (`local_db`, `js_pingan`, ...).
    pub key: ChannelKey,
    /// Display metadata, including `enabled` and `priority`.
    pub meta: ChannelMeta,
}

impl ChannelRecord {
    /// Builds a record from a validated key and its metadata.
    pub fn new(key: ChannelKey, meta: ChannelMeta) -> Self {
        Self { key, meta }
    }

    /// Channel implementation kind.
    pub fn kind(&self) -> ChannelKind {
        self.meta.kind
    }

    /// Whether the channel is enabled in registry state.
    pub fn enabled(&self) -> bool {
        self.meta.enabled
    }

    /// Priority; smaller values are preferred.
    pub fn priority(&self) -> i32 {
        self.meta.priority
    }
}

/// Persistence contract for registry state.
///
/// Semantics mirrored from `ChannelManager`:
/// - `register` is idempotent for an identical record, but a different record
///   under the same key is a [`Error::Conflict`].
/// - `unregister`/`enable`/`disable`/`set_priority` return
///   [`Error::NotFound`] for unknown keys.
/// - `list` is deterministic by key.
/// - `priority_order` returns enabled channels only, sorted by
///   `(priority, key)`.
pub trait ChannelStore: Send + Sync {
    /// Registers or idempotently re-registers a channel record.
    fn register(&self, record: ChannelRecord) -> Result<(), Error>;

    /// Removes a registered channel.
    fn unregister(&self, key: &ChannelKey) -> Result<(), Error>;

    /// Returns the record for `key`, or `None` when it is not registered.
    fn get(&self, key: &ChannelKey) -> Result<Option<ChannelRecord>, Error>;

    /// Returns every registered record in deterministic key order.
    fn list(&self) -> Result<Vec<ChannelRecord>, Error>;

    /// Enables a registered channel.
    fn enable(&self, key: &ChannelKey) -> Result<(), Error>;

    /// Disables a registered channel (without removing it).
    fn disable(&self, key: &ChannelKey) -> Result<(), Error>;

    /// Updates a registered channel's priority.
    fn set_priority(&self, key: &ChannelKey, priority: i32) -> Result<(), Error>;

    /// Enabled channels sorted by `(priority, key)` for fallback selection.
    fn priority_order(&self) -> Result<Vec<ChannelRecord>, Error>;
}
