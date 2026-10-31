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

pub mod bus;
pub mod error;
pub mod import;
pub mod model;
pub mod schema;
pub mod secrets;
pub mod store;

pub use bus::{
    ConfigBus, ConfigBusError, ConfigCallback, ConfigChangePayload, ConfigFilter, ConfigToken,
};
pub use error::{
    ConfigAccess, ConfigError, CODE_INVALID_KEY, CODE_INVALID_MODULE, CODE_INVALID_SOURCE,
    CODE_INVALID_WIRE_NAME, CODE_NOT_PERMITTED, CODE_TYPE_MISMATCH, CODE_UNKNOWN_KEY,
    CODE_VALIDATION,
};
pub use import::{
    import_batch, import_batch_with_events, import_quiet, verify, ImportReport, VerifyReport,
    VerifyResult, VerifyStatus, CODE_IMPORT_DUPLICATE,
};
pub use model::{
    ConfigChange, ConfigEntry, ConfigKey, ConfigSource, ConfigValueType, ConfigVisibility,
    MASKED_VALUE, MAX_KEY_LEN, MAX_MODULE_LEN,
};
pub use schema::{entries, entry, has, module_entries, MODULE_NAMES};
pub use secrets::{
    dart_mirror_value, is_secret_entry, mask_if_secret, masked_agent_tool_output,
    masked_change_payload, masked_report, masked_snapshot_value, redact_change_log_value,
    secret_ref_for, trusted_read_allowed, ConfigCaller, ConfigRedactor, DART_MIRROR_GUIDANCE,
    MASKED,
};
pub use store::{
    ConfigExportEntry, ConfigImportReport, ConfigSnapshot, ConfigStore, ConfigStoreError,
    CONFIG_SECRET_PREFIX,
};
