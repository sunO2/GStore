//! Wire keys consumed (or deliberately not consumed) by the download module.

/// Owning module name used for the bound vtable (`NULL` = this module).
pub const MODULE: &str = "download";

pub const KEY_MULTI_SEGMENT_ENABLED: &str = "multi_segment.enabled";
pub const KEY_MAX_CONCURRENT: &str = "max_concurrent";
pub const KEY_DEFAULT_CONNECTIONS: &str = "default_connections";
pub const KEY_MAX_RETRIES: &str = "max_retries";
pub const KEY_SPEED_LIMIT_BPS: &str = "speed_limit_bps";
/// Registered, but consumed by Dart (connectivity) rather than this module.
#[allow(dead_code)]
pub const KEY_WIFI_ONLY: &str = "wifi_only";

// Clear/unset fallbacks for the keys this module consumes.
//
// These MUST stay equal to the defaults declared in the Rust registry
// (`gstore_core/src/config/schema.rs`). The module is compiled as an
// independent `.so` against `gstore_contract` only and cannot depend on
// `gstore_core`, so the registry values are restated here; the module tests
// pin them against the registry semantics.
pub const REGISTRY_DEFAULT_MULTI_SEGMENT_ENABLED: bool = true;
pub const REGISTRY_DEFAULT_MAX_CONCURRENT: usize = 3;
pub const REGISTRY_DEFAULT_CONNECTIONS: u32 = 4;
pub const REGISTRY_DEFAULT_MAX_RETRIES: u32 = 3;
/// Registry default is `0` = unlimited; the engine represents it as `None`.
pub const REGISTRY_DEFAULT_SPEED_LIMIT_BPS: u64 = 0;

/// `PublicRead` cross-module example (owned by `network`, readable by us).
pub const MODULE_NETWORK: &str = "network";
pub const KEY_PROXY_URL: &str = "proxy_url";
