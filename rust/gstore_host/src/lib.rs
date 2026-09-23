mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
mod models;
mod bridge;
mod manager;
mod dl_adapter;
mod jni_bridge;
// T12 宿主 UID/包名解析 API。`resolve_uids` 的宿主侧消费者是 T13（内部事件消费），
// 在接线前以库 API 暴露可避免暂存期 dead_code 告警。
pub use jni_bridge::{resolve_uids, UidAnswer, UidQueryHost};
mod tun_bridge;
mod trust;
pub mod log_bridge;
mod event_bridge;
mod task_bridge;

/// 单进程测试共享 `jni_bridge::TUN_FD` 等全局态，相关用例须串行执行。
#[cfg(test)]
pub(crate) static TEST_SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

