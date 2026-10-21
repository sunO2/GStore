//! Registry facade over [`ChannelStore`] and key-bound drivers.
//!
//! The registry applies the two observable `ChannelManager` rules that callers
//! rely on: enabled filtering and priority ordering. Persistence is delegated to
//! the store. Driver routing is keyed: [`ChannelRegistry::driver`] returns the
//! handle bound to the requested key, or a typed [`Error::NotFound`] for an
//! unregistered key.

use std::collections::BTreeMap;
use std::sync::{Arc, RwLock, RwLockReadGuard, RwLockWriteGuard};

use crate::dto::ChannelKey;
use crate::error::Error;

use super::driver::ChannelDriver;
use super::store::{ChannelRecord, ChannelStore};

type DriverMap = BTreeMap<ChannelKey, Arc<dyn ChannelDriver>>;

/// Channel registry backed by a [`ChannelStore`] plus registered drivers.
pub struct ChannelRegistry<S> {
    store: S,
    drivers: RwLock<DriverMap>,
}

impl<S: ChannelStore> ChannelRegistry<S> {
    /// Wraps a store with an empty driver map.
    pub fn new(store: S) -> Self {
        Self {
            store,
            drivers: RwLock::new(BTreeMap::new()),
        }
    }

    /// Borrows the underlying store.
    pub fn store(&self) -> &S {
        &self.store
    }

    /// Consumes the registry and returns its store.
    pub fn into_store(self) -> S {
        self.store
    }

    /// Registers registry state without a driver (useful before drivers load).
    pub fn register(&self, record: ChannelRecord) -> Result<(), Error> {
        self.store.register(record)
    }

    /// Registers a key-bound driver and its record in one call.
    ///
    /// The driver's own key and metadata define the record; callers cannot pass
    /// a separate / foreign key.
    pub fn register_driver(&self, driver: Arc<dyn ChannelDriver>) -> Result<(), Error> {
        let record = ChannelRecord::new(driver.key().clone(), driver.meta().clone());
        self.store.register(record)?;
        self.write_drivers()?.insert(driver.key().clone(), driver);
        Ok(())
    }

    /// Returns the driver handle bound to `key`.
    ///
    /// Unregistered keys return [`Error::NotFound`]; the returned handle exposes
    /// no method that accepts another key.
    pub fn driver(&self, key: &ChannelKey) -> Result<Arc<dyn ChannelDriver>, Error> {
        if self.store.get(key)?.is_none() {
            return Err(Error::NotFound(format!("channel not registered: {key}")));
        }
        self.read_drivers()?
            .get(key)
            .cloned()
            .ok_or_else(|| Error::NotFound(format!("channel driver not registered: {key}")))
    }

    /// Unregisters a channel and drops its driver handle.
    pub fn unregister(&self, key: &ChannelKey) -> Result<(), Error> {
        self.store.unregister(key)?;
        self.write_drivers()?.remove(key);
        Ok(())
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

    fn read_drivers(&self) -> Result<RwLockReadGuard<'_, DriverMap>, Error> {
        self.drivers
            .read()
            .map_err(|_| Error::Internal("channel registry driver lock poisoned".to_string()))
    }

    fn write_drivers(&self) -> Result<RwLockWriteGuard<'_, DriverMap>, Error> {
        self.drivers
            .write()
            .map_err(|_| Error::Internal("channel registry driver lock poisoned".to_string()))
    }
}
