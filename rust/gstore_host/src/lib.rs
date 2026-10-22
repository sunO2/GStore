mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
mod models;
pub mod bridge;
mod manager;
mod repo_port;
pub mod download_host;
mod dl_adapter;
mod jni_bridge;
pub mod platform_host;
pub mod installer_host;
pub mod http_port;
pub use http_port::ReqwestHttpPort;
pub use repo_port::{ModuleManagerBridge, ModuleRepoPort, RepoBridge};
// 统一特权 shell 门面：Rust → JNI → Kotlin `ShizukuExecBridge` → Shizuku。
mod shizuku_bridge;
// 免权限电池 JNI 门面：Rust → JNI → Kotlin `BatteryChannel`（applicationContext 由
// Kotlin 在 app 线程交给 Rust 缓存）。
mod battery_bridge;
// 批量设备状态 JNI 门面：Rust → JNI → Kotlin `DeviceStateChannel`（复用
// battery_bridge 缓存的 VM / applicationContext）。
mod device_state_bridge;
// 本应用帧指标 JNI 门面：Rust → JNI → Kotlin `FrameMetricsCollector`（复用
// battery_bridge 缓存的 JavaVM；类引用在 app 线程解析缓存）。
mod frame_metrics_bridge;
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

