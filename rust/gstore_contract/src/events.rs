// gstore_contract：跨 ABI 事件类型常量
//
// 与 Dart 侧 `lib/core/event/app_event.dart` 的 `AppEventTypes` 保持一致。
// 宿主经 ABI `on_event(module_id, kind, data, len)` 下发事件时，kind 即这些字符串；
// 模块用它们做匹配，避免两侧各写魔法字符串而漂移。

/// 配置变化：payload = {key, value}
pub const EVT_CONFIG_CHANGED: &str = "config.changed";

/// 数据库变化：payload = {type, data}
pub const EVT_DB_CHANGED: &str = "db.changed";

/// 模块上下线：payload = {module, lifecycle}
pub const EVT_MODULE_LIFECYCLE: &str = "module.lifecycle";

/// Rust 模块事件（上行）：payload = {eventType, moduleId, instanceId, data}
pub const EVT_RUST_EVENT: &str = "rust.event";

/// 主题变化（可下行）：payload = {mode, ...}
pub const EVT_THEME_CHANGED: &str = "theme.changed";
