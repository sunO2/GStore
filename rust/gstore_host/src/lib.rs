mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
mod models;
mod bridge;
mod manager;
mod dl_adapter;
mod jni_bridge;
mod tun_bridge;
mod trust;
pub mod log_bridge;
mod event_bridge;
mod task_bridge;

/// 单进程测试共享 `jni_bridge::TUN_FD` 等全局态，相关用例须串行执行。
#[cfg(test)]
pub(crate) static TEST_SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

