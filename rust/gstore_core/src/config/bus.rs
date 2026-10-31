//! Filtered, in-process configuration change bus (Todo 6 / C7 / C18).
//!
//! The store commits a change first, then calls [`ConfigBus::publish`] with the
//! committed [`ConfigChange`]. The bus validates that change against the
//! built-in registry, builds the single masked wire payload, and invokes every
//! subscription whose filter matches **and** whose caller is authorized for
//! *that change's* registry entry.
//!
//! # Overlapping AMQP-style subscriptions
//!
//! `(module, key=None)` and `(module, key=Some(k))` overlap by design: a whole
//! module subscription receives every change in that module, and an exact-key
//! subscription receives only that key. There is no deduplication — the same
//! change is delivered to both if both are authorized.
//!
//! # Visibility is per change, never per registration
//!
//! A foreign module subscription is accepted at registration time and is
//! filtered on **every delivery**: only a [`ConfigVisibility::PublicRead`]
//! entry crosses a module boundary. `key = None` merely widens the key match
//! inside that authorized set, so it can never become a blanket grant for a
//! later `Owner`/`Secret` key added to the same module (C7).
//!
//! # Reentrancy
//!
//! Callbacks run with no bus lock held: [`ConfigBus::publish`] snapshots the
//! matching `(id, callback)` pairs under the lock, releases it, then invokes
//! each callback. A callback may therefore call [`ConfigBus::publish`] or
//! [`ConfigBus::unsubscribe`] again without deadlocking. A panicking callback
//! is dropped from the registry and does not stop delivery to the others.

use std::error::Error;
use std::fmt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::error::ConfigError;
use super::model::{ConfigChange, ConfigEntry, ConfigKey, ConfigVisibility, MASKED_VALUE};
use super::schema;
use super::secrets::{is_secret_entry, masked_change_payload};

pub use super::secrets::ConfigCaller;

/// Default visibility of a subscription filter.
///
/// `module` is matched exactly against the change's owning module; `key = None`
/// means "any key in that module", not "any key in any module".
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ConfigFilter {
    /// Exact owning module to observe.
    pub module: String,
    /// `Some(key)` restricts delivery to that key; `None` is whole-module.
    pub key: Option<String>,
}

impl ConfigFilter {
    /// Builds a filter; `None` observes the whole module.
    pub fn new(module: impl Into<String>, key: Option<String>) -> Self {
        Self {
            module: module.into(),
            key,
        }
    }

    /// Whole-module filter (`key = None`).
    pub fn whole_module(module: impl Into<String>) -> Self {
        Self {
            module: module.into(),
            key: None,
        }
    }

    /// Exact-key filter.
    pub fn exact_key(module: impl Into<String>, key: impl Into<String>) -> Self {
        Self {
            module: module.into(),
            key: Some(key.into()),
        }
    }
}

/// Wire payload delivered to a subscription callback.
///
/// Field names match the documented wire shape exactly: `value` is the new
/// value (`new_json`) and `oldValue` is the previous value (`old_json`).
/// Secrets are always `"***"` (or `null` when unset); plaintext secrets never
/// reach a callback.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConfigChangePayload {
    /// Owning module.
    pub module: String,
    /// Key within the module.
    pub key: String,
    /// New value after the change; `None` when the entry was cleared.
    pub value: Option<Value>,
    /// Previous value; `None` when the entry was unset.
    #[serde(rename = "oldValue")]
    pub old_value: Option<Value>,
    /// Revision after the change.
    pub revision: u64,
    /// Origin of the change.
    pub source: super::model::ConfigSource,
}

/// Callback invoked for one authorized delivery.
pub type ConfigCallback = Arc<dyn Fn(&ConfigChangePayload) + Send + Sync + 'static>;

/// Opaque, unique subscription handle.
///
/// Fields are private: callers can only obtain one from
/// [`ConfigBus::subscribe`], so a token cannot be forged. Each token records
/// the owning caller and the bus that issued it; [`ConfigBus::unsubscribe_for`]
/// checks both, which is what rejects "another caller's token".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigToken {
    bus_id: u64,
    id: u64,
    caller: ConfigCaller,
}

impl ConfigToken {
    /// The caller that registered this subscription.
    pub fn caller(&self) -> &ConfigCaller {
        &self.caller
    }
}

/// Typed bus failures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigBusError {
    /// The token was not issued by this bus, or the subscription is gone.
    UnknownToken,
    /// The token exists but belongs to a different caller.
    NotOwner,
    /// The change could not be validated against the registry, so nothing was
    /// emitted.
    InvalidChange(ConfigError),
}

impl ConfigBusError {
    /// Stable machine-readable code.
    pub const fn code(&self) -> &'static str {
        match self {
            Self::UnknownToken => "config_bus_unknown_token",
            Self::NotOwner => "config_bus_not_owner",
            Self::InvalidChange(error) => error.code(),
        }
    }
}

impl fmt::Display for ConfigBusError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownToken => f.write_str("[config_bus_unknown_token] unknown subscription token"),
            Self::NotOwner => f.write_str("[config_bus_not_owner] token belongs to another caller"),
            Self::InvalidChange(error) => write!(f, "{error}"),
        }
    }
}

impl Error for ConfigBusError {}

impl From<ConfigError> for ConfigBusError {
    fn from(error: ConfigError) -> Self {
        Self::InvalidChange(error)
    }
}

struct Subscription {
    token: ConfigToken,
    filter: ConfigFilter,
    callback: ConfigCallback,
}

/// In-process, filtered configuration change bus.
///
/// Cheap to construct and safe to share behind an `Arc`. One instance per
/// process/core is expected; tests use independent instances.
pub struct ConfigBus {
    id: u64,
    subscriptions: Mutex<Vec<Subscription>>,
}

impl ConfigBus {
    /// Creates an empty bus with a process-unique identity.
    pub fn new() -> Self {
        static NEXT_BUS_ID: AtomicU64 = AtomicU64::new(1);
        Self {
            id: NEXT_BUS_ID.fetch_add(1, Ordering::Relaxed),
            subscriptions: Mutex::new(Vec::new()),
        }
    }

    /// Registers `callback` for `filter`.
    ///
    /// Registration never performs visibility authorization: a foreign-module
    /// filter is accepted and each delivered change is checked individually
    /// (C7). The returned token is opaque and unique.
    pub fn subscribe<F>(&self, caller: ConfigCaller, filter: ConfigFilter, callback: F) -> ConfigToken
    where
        F: Fn(&ConfigChangePayload) + Send + Sync + 'static,
    {
        static NEXT_TOKEN_ID: AtomicU64 = AtomicU64::new(1);
        let token = ConfigToken {
            bus_id: self.id,
            id: NEXT_TOKEN_ID.fetch_add(1, Ordering::Relaxed),
            caller: caller.clone(),
        };
        self.lock().push(Subscription {
            token: token.clone(),
            filter,
            callback: Arc::new(callback),
        });
        token
    }

    /// Removes the subscription identified by `token`.
    ///
    /// The token carries its owning caller, so this is the capability-style
    /// entry point. Use [`ConfigBus::unsubscribe_for`] when the caller identity
    /// is available separately (for example from an ABI vtable context).
    ///
    /// # Errors
    /// [`ConfigBusError::UnknownToken`] when the token was not issued by this
    /// bus or was already unsubscribed.
    pub fn unsubscribe(&self, token: &ConfigToken) -> Result<(), ConfigBusError> {
        self.unsubscribe_for(&token.caller, token)
    }

    /// Removes the subscription only when `caller` owns `token`.
    ///
    /// # Errors
    /// [`ConfigBusError::UnknownToken`] for an unknown/foreign token and
    /// [`ConfigBusError::NotOwner`] when the token belongs to another caller.
    pub fn unsubscribe_for(
        &self,
        caller: &ConfigCaller,
        token: &ConfigToken,
    ) -> Result<(), ConfigBusError> {
        if token.bus_id != self.id {
            return Err(ConfigBusError::UnknownToken);
        }
        let mut subscriptions = self.lock();
        let index = subscriptions
            .iter()
            .position(|subscription| subscription.token.id == token.id)
            .ok_or(ConfigBusError::UnknownToken)?;
        if &subscriptions[index].token.caller != caller || &token.caller != caller {
            return Err(ConfigBusError::NotOwner);
        }
        subscriptions.remove(index);
        Ok(())
    }

    /// Removes every subscription registered *by* `module`, returning how many
    /// were removed.
    ///
    /// Used on module unload. Foreign subscriptions that merely observe
    /// `module` (a different caller's filter) are kept, because they belong to
    /// that other caller.
    pub fn clear_module(&self, module: &str) -> usize {
        let mut subscriptions = self.lock();
        let before = subscriptions.len();
        subscriptions.retain(|subscription| {
            !matches!(
                &subscription.token.caller,
                ConfigCaller::Module(owner) if owner == module
            )
        });
        before - subscriptions.len()
    }

    /// Number of live subscriptions.
    pub fn subscription_count(&self) -> usize {
        self.lock().len()
    }

    /// Publishes one committed change.
    ///
    /// The change is validated against the registry first; on any validation
    /// failure nothing is delivered (the change must have been rejected before
    /// commit, and the bus is a second line of defence). The returned count is
    /// the number of callbacks that completed without panicking.
    ///
    /// # Errors
    /// [`ConfigBusError::InvalidChange`] for an unknown key, a malformed
    /// module/key, or a value rejected by the entry's type/range/enum rules.
    pub fn publish(&self, change: &ConfigChange) -> Result<usize, ConfigBusError> {
        let key = ConfigKey::new(change.module.clone(), change.key.clone())?;
        let entry = schema::entry(&key).ok_or_else(|| {
            ConfigBusError::InvalidChange(ConfigError::UnknownKey {
                module: change.module.clone(),
                key: change.key.clone(),
            })
        })?;
        validate_committed_change(entry, change)?;

        let payload = payload_for(entry, change);
        let deliveries: Vec<(u64, ConfigCallback)> = {
            let subscriptions = self.lock();
            subscriptions
                .iter()
                .filter(|subscription| {
                    delivers(entry, change, &subscription.token.caller, &subscription.filter)
                })
                .map(|subscription| (subscription.token.id, subscription.callback.clone()))
                .collect()
        };

        let mut delivered = 0usize;
        let mut failed: Vec<u64> = Vec::new();
        for (id, callback) in &deliveries {
            // No bus lock is held here, so a callback may publish/unsubscribe.
            if catch_unwind(AssertUnwindSafe(|| callback(&payload))).is_ok() {
                delivered += 1;
            } else {
                failed.push(*id);
            }
        }
        if !failed.is_empty() {
            self.lock()
                .retain(|subscription| !failed.contains(&subscription.token.id));
        }
        Ok(delivered)
    }

    fn lock(&self) -> MutexGuard<'_, Vec<Subscription>> {
        self.subscriptions
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }
}

impl Default for ConfigBus {
    fn default() -> Self {
        Self::new()
    }
}

fn delivers(
    entry: &ConfigEntry,
    change: &ConfigChange,
    caller: &ConfigCaller,
    filter: &ConfigFilter,
) -> bool {
    change.module == filter.module
        && filter
            .key
            .as_deref()
            .is_none_or(|key| key == change.key)
        && match caller {
            ConfigCaller::Host | ConfigCaller::Dart => true,
            ConfigCaller::Module(module) => {
                module.as_str() == change.module
                    || entry.visibility == ConfigVisibility::PublicRead
            }
        }
}

fn validate_committed_change(
    entry: &ConfigEntry,
    change: &ConfigChange,
) -> Result<(), ConfigBusError> {
    let Some(value) = change.new_json.as_ref() else {
        return Ok(());
    };
    // `ConfigStore::set` already masks secrets before returning the change, so
    // a `"***"` value is the only thing the bus can validate. Re-masking an
    // already-masked secret is idempotent; validating the placeholder as the
    // entry's real JSON type would wrongly reject it.
    let already_masked_secret = is_secret_entry(entry)
        && matches!(value, Value::String(text) if text.as_str() == MASKED_VALUE);
    if already_masked_secret {
        return Ok(());
    }
    entry.validate_value(value).map_err(ConfigBusError::InvalidChange)
}

fn payload_for(entry: &ConfigEntry, change: &ConfigChange) -> ConfigChangePayload {
    // Single source of truth for secret masking (C3): reuse the committed
    // policy helper instead of a second redaction implementation.
    let masked = masked_change_payload(entry, change);
    ConfigChangePayload {
        module: masked.module,
        key: masked.key,
        value: masked.new_json,
        old_value: masked.old_json,
        revision: masked.revision,
        source: masked.source,
    }
}

#[cfg(test)]
mod tests;
