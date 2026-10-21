//! Registry facade over [`ChannelStore`].
//!
//! The registry applies the two observable `ChannelManager` rules that callers
//! rely on: enabled filtering and priority ordering. Persistence is entirely
//! delegated to the store, so an in-memory fake and the future SQLite store share
//! the same call sites.

use crate::dto::ChannelKey;
use crate::error::Error;

use super::store::{ChannelRecord, ChannelStore};

/// Channel registry backed by a [`ChannelStore`].
#[derive(Debug, Clone)]
pub struct ChannelRegistry<S> {
    store: S,
}

impl<S: ChannelStore> ChannelRegistry<S> {
    /// Wraps a store.
    pub fn new(store: S) -> Self {
        Self { store }
    }

    /// Borrows the underlying store.
    pub fn store(&self) -> &S {
        &self.store
    }

    /// Consumes the registry and returns its store.
    pub fn into_store(self) -> S {
        self.store
    }

    /// Registers a channel record (idempotent for identical records).
    pub fn register(&self, record: ChannelRecord) -> Result<(), Error> {
        self.store.register(record)
    }

    /// Unregisters a channel by key.
    pub fn unregister(&self, key: &ChannelKey) -> Result<(), Error> {
        self.store.unregister(key)
    }

    /// Returns a channel record by key.
    pub fn get(&self, key: &ChannelKey) -> Result<Option<ChannelRecord>, Error> {
        self.store.get(key)
    }

    /// Returns every registered record in deterministic key order.
    pub fn list(&self) -> Result<Vec<ChannelRecord>, Error> {
        self.store.list()
    }

    /// Enables a channel.
    pub fn enable(&self, key: &ChannelKey) -> Result<(), Error> {
        self.store.enable(key)
    }

    /// Disables a channel without removing it.
    pub fn disable(&self, key: &ChannelKey) -> Result<(), Error> {
        self.store.disable(key)
    }

    /// Sets a channel's priority (smaller is preferred).
    pub fn set_priority(&self, key: &ChannelKey, priority: i32) -> Result<(), Error> {
        self.store.set_priority(key, priority)
    }

    /// Enabled channels sorted by `(priority, key)`.
    pub fn priority_order(&self) -> Result<Vec<ChannelRecord>, Error> {
        self.store.priority_order()
    }

    /// Alias for [`ChannelRegistry::priority_order`] that names the filter.
    pub fn enabled(&self) -> Result<Vec<ChannelRecord>, Error> {
        self.store.priority_order()
    }
}
