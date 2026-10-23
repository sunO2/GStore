mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
// Retained for the FRB-generated Dart types; the reduced host does not call it.
#[allow(dead_code)]
mod models;
pub mod bridge;
mod manager;
mod repo_port;
pub mod download_host;
mod dl_adapter;
mod jni_bridge;
// The only VM owner: the allowlisted packet-plane seams (`protect_fd` and
// proxy `uid -> package`) keep the VM here, nothing else.
mod jvm;
pub mod http_port;
pub use http_port::ReqwestHttpPort;
pub use repo_port::{ModuleManagerBridge, ModuleRepoPort, RepoBridge};
// T12 host UID/package resolution. `resolve_uids` is consumed by the proxy
// module's `proxy.uid.query` path.
pub use jni_bridge::{resolve_uids, UidAnswer, UidQueryHost};
mod tun_bridge;
mod trust;
pub mod log_bridge;
mod event_bridge;
mod task_bridge;
mod script_api;
mod script_env;
mod script_host_impl;
mod script_http;
mod script_db;
mod script_pack;
mod script_runtime_entry;
mod ui_api;
#[cfg(test)]
mod script_api_test_support;
#[cfg(test)]
mod script_api_lifecycle_tests;
#[cfg(test)]
mod script_api_roundtrip_tests;
#[cfg(test)]
mod script_api_config_tests;
#[cfg(test)]
mod script_api_park_tests;

/// 单进程测试共享 `jni_bridge::TUN_FD` 等全局态，相关用例须串行执行。
#[cfg(test)]
pub(crate) static TEST_SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());
