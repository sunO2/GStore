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

/// `PublicRead` cross-module example (owned by `network`, readable by us).
pub const MODULE_NETWORK: &str = "network";
pub const KEY_PROXY_URL: &str = "proxy_url";
