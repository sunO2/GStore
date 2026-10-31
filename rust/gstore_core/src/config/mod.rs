//! Module-scoped configuration.
//!
//! One canonical model shared by the registry, store, bus, and bridges:
//! [`ConfigKey`] identity, [`ConfigEntry`] metadata, [`ConfigVisibility`]
//! access policy, [`ConfigValueType`] JSON typing, [`ConfigChange`] events,
//! [`ConfigSource`] provenance, and typed [`ConfigError`]s.
//!
//! Later waves add `store`, `schema`, `secrets`, `bus`, and `import` modules
//! next to these files; they are re-exported here so downstream `use` paths
//! stay stable.

pub mod error;
pub mod model;
pub mod schema;

pub use error::{
    ConfigAccess, ConfigError, CODE_INVALID_KEY, CODE_INVALID_MODULE, CODE_INVALID_SOURCE,
    CODE_INVALID_WIRE_NAME, CODE_NOT_PERMITTED, CODE_TYPE_MISMATCH, CODE_UNKNOWN_KEY,
    CODE_VALIDATION,
};
pub use model::{
    ConfigChange, ConfigEntry, ConfigKey, ConfigSource, ConfigValueType, ConfigVisibility,
    MASKED_VALUE, MAX_KEY_LEN, MAX_MODULE_LEN,
};
pub use schema::{entries, entry, has, module_entries, MODULE_NAMES};
