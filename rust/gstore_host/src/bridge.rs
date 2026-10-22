// Flutter FFI Bridge - 暴露给 Dart 的接口
use flutter_rust_bridge::frb;
use super::models::*;

/// 宿主侧静默 panic hook：宿主与模块 .so 各自静态链接一份 std，各自持有独立的
/// panic hook 全局状态。宿主 std 副本默认 hook 在 panic 时生成 backtrace，
/// gimli 符号化器在 Android dlopen 场景二次崩溃为 SIGSEGV（真机崩溃放大器）。
/// 模块 register 时已安装自己的静默 hook；此处安装宿主副本的，双保险。
pub fn install_host_panic_hook() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = info.payload().downcast_ref::<String>() {
                s.clone()
            } else {
                "unknown panic".to_string()
            };
            let loc = if let Some(loc) = info.location() {
                format!("{}:{}", loc.file(), loc.line())
            } else {
                "?".to_string()
            };
            let line = format!("gstore_host panic at {loc}: {msg}");
            crate::log_bridge::push_host_log(3, line);
        }));
    });
}

/// 统一特权 shell 执行（Rust facade）：经 JNI 调 Kotlin `ShizukuExecBridge.exec`。
/// 无 Shizuku/未初始化 → `null`；返回值用 `Option<String>` 以避免 FRB 对
/// `Result` 错误类型的约束。
pub fn shizuku_exec(command: String) -> Option<String> {
    crate::shizuku_bridge::exec(&command)
}

/// Shizuku 是否可用（`pingBinder() && checkSelfPermission()==GRANTED`）。
pub fn shizuku_available() -> bool {
    crate::shizuku_bridge::is_available()
}

/// 免权限电池 JSON（Rust → JNI → Kotlin `BatteryChannel.readJson`）。
/// 未初始化（Kotlin 尚未交付 applicationContext）/ 调用失败 → `null`。
pub fn battery_read_json() -> Option<String> {
    crate::battery_bridge::read_json()
}

/// 屏幕是否点亮（Rust → JNI → Kotlin `BatteryChannel.isInteractive`）。
/// 未初始化 / 调用失败 → `null`。
pub fn battery_power_interactive() -> Option<bool> {
    crate::battery_bridge::is_interactive()
}

/// 批量设备状态 JSON（Rust → JNI → Kotlin `DeviceStateChannel.readJson`）。
/// 未初始化（Kotlin 尚未交付 applicationContext）/ 调用失败 → `null`。
pub fn device_state_read_json() -> Option<String> {
    crate::device_state_bridge::read_json()
}

/// 前台无障碍服务缓存 JSON（Rust → JNI →
/// Kotlin `ForegroundAccessibilityService.readJson`）。
/// 未初始化 / 服务未启用 / 调用失败 → `null`；Dart 侧据此决定是否跳过
/// `dumpsys activity activities`。
pub fn foreground_read_json() -> Option<String> {
    crate::battery_bridge::foreground_read_json()
}

/// 本应用帧指标摘要 JSON（Rust → JNI → Kotlin `FrameMetricsCollector.readJson`）。
/// 未初始化（Kotlin 尚未交付 applicationContext）/ 调用失败 → `null`。
pub fn frame_metrics_read_json() -> Option<String> {
    crate::frame_metrics_bridge::read_json()
}

/// 日志消息数据类（架构文档 6.8；普通数据类，跨模块 re-export 可被 FRB 跟随）
pub use crate::log_bridge::LogMessage;

/// 日志桥 opaque（架构文档 6.8）：Rust 日志 → FRB Stream → Flutter LogManager。
/// 必须直接定义在 bridge.rs（FRB 2.11 只跟随本文件内直接定义的 opaque 类型）。
#[frb(opaque)]
pub struct LogBridge;

impl LogBridge {
    #[frb(init)]
    pub fn new() -> Self {
        Self
    }

    /// 订阅日志流。首次订阅时补发环形缓冲中的历史日志。
    pub fn logs_stream(&self, sink: crate::frb_generated::StreamSink<LogMessage>) {
        crate::log_bridge::subscribe(sink);
    }
}

/// 长任务门面（架构文档：Task 模型）
///
/// 用法（Dart）：
/// ```dart
/// final task = TaskBridge();
/// final id = await task.start(module: 'repo', instance: instanceId, method: 'download_repo', payload: bytes);
/// task.watch(id).listen((e) { /* started/progress/done/error */ });
/// await task.cancel(id);
/// ```
#[frb(opaque)]
pub struct TaskBridge;

impl TaskBridge {
    #[frb(init)]
    pub fn new() -> Self {
        TaskBridge
    }

    /// 启动长任务：**立即返回** task_id，工作在宿主自有线程执行（不占 FRB 任务池）
    pub fn start(
        &self,
        module: String,
        instance: Option<u64>,
        method: String,
        payload: Vec<u8>,
    ) -> Result<String, String> {
        crate::task_bridge::start_task(module, instance, method, payload)
    }

    /// 订阅任务事件流（先补发缓冲，再转实时）
    pub fn watch(&self, task_id: String, sink: crate::frb_generated::StreamSink<TaskEvent>) {
        crate::task_bridge::watch_task(task_id, sink);
    }

    /// 取消任务（协作式：模块在检查点退出）
    pub fn cancel(&self, task_id: String) -> Result<(), String> {
        crate::task_bridge::cancel_task(task_id)
    }

    /// 在跑任务数（诊断）
    pub fn running_count(&self) -> u32 {
        crate::task_bridge::running_task_count() as u32
    }
}

impl Default for TaskBridge {
    fn default() -> Self {
        Self::new()
    }
}

/// 模块事件数据类（架构文档 6.8；普通数据类，跨模块 re-export 可被 FRB 跟随）
pub use crate::event_bridge::ModuleEvent;
/// 长任务事件（FRB 生成 Dart 侧类）
pub use crate::task_bridge::TaskEvent;

/// 已加载模块快照数据类（只读诊断；跨模块 re-export 可被 FRB 跟随）
pub use crate::manager::ModuleInfo;

/// 事件桥 opaque（架构文档 6.8）：模块事件 → FRB Stream → Flutter。
/// 必须直接定义在 bridge.rs（FRB 2.11 只跟随本文件内直接定义的 opaque 类型）。
#[frb(opaque)]
pub struct EventBridge;

impl EventBridge {
    #[frb(init)]
    pub fn new() -> Self {
        Self
    }

    /// 订阅模块事件流。首次订阅时补发环形缓冲中的历史事件。
    pub fn events_stream(&self, sink: crate::frb_generated::StreamSink<ModuleEvent>) {
        crate::event_bridge::subscribe(sink);
    }

    /// 应用侧事件下行：广播给所有已加载模块（模块经 ABI `on_event` 订阅）。
    /// [kind] 事件类型（如 "config.changed"），[data] 为 JSON 载荷字节。
    pub fn broadcast(&self, kind: String, data: Vec<u8>) {
        crate::manager::ModuleManager::global().broadcast_event(&kind, &data);
    }
}

/// 模块代理（Dart 侧 = 模块对象）。内部携带 module_id，调用时宿主自动路由。
#[frb(opaque)]
pub struct ModuleHandle {
    pub id: u64,
}

impl ModuleHandle {
    /// 按名加载/获取模块（幂等：已注册则 refcount+1 复用）
    pub fn load(module_name: String) -> Result<ModuleHandle, String> {
        let id = crate::manager::ModuleManager::global().register_by_name(&module_name)?;
        Ok(ModuleHandle { id })
    }

    /// 从 .so 动态挂载模块（P2 多 .so 按需下载场景）。
    /// 幂等：同名模块已注册则复用。
    pub fn mount_from_so(so_path: String) -> Result<ModuleHandle, String> {
        install_host_panic_hook();
        // 安全门：下载模块（携带 .sig 侧车）必须在 dlopen 前通过签名校验；
        // 内置模块（无 .sig）按 APK 信任锚直接放行。
        crate::trust::verify_module_file(std::path::Path::new(&so_path))?;
        let id = crate::manager::ModuleManager::global()
            .load_module_from_so(std::path::Path::new(&so_path))
            .map_err(|e| e.to_string())?;
        Ok(ModuleHandle { id })
    }

    /// 实例化：宿主转发给模块 create()，返回实例代理对象
    pub fn create_instance(&self, config: Vec<u8>) -> Result<InstanceHandle, String> {
        let instance_id = crate::manager::ModuleManager::global().call_create(self.id, &config)?;
        Ok(InstanceHandle {
            module_id: self.id,
            instance_id,
        })
    }

    /// 模块级静态调用（不创建实例）
    pub fn call_static(&self, method: String, payload: Vec<u8>) -> Result<Vec<u8>, String> {
        crate::manager::ModuleManager::global()
            .call(self.id, None, &method, &payload)
            .map_err(|e| e.to_string())
    }

    /// 是否已加载
    pub fn is_loaded(&self) -> bool {
        crate::manager::ModuleManager::global().is_loaded(self.id)
    }

    /// 释放模块引用（refcount-1；归零时回收模块状态）
    pub fn dispose(&self) {
        crate::manager::ModuleManager::global().unref(self.id);
    }
}

impl Drop for ModuleHandle {
    fn drop(&mut self) {
        crate::manager::ModuleManager::global().unref(self.id);
    }
}

/// 实例代理（Dart 侧 = 实例对象）。携带 (module_id, instance_id)，调用时宿主自动透传。
#[frb(opaque)]
pub struct InstanceHandle {
    // 字段保持私有：FRB 会为 pub 字段生成同名 getter/setter，
    // 与下面的 `instance_id()` 方法冲突（instanceId 重复声明）。
    pub(crate) module_id: u64,
    pub(crate) instance_id: u64,
}

impl InstanceHandle {
    /// 实例方法调用 —— 外部不用携带任何 id
    pub fn call(&self, method: String, payload: Vec<u8>) -> Result<Vec<u8>, String> {
        crate::manager::ModuleManager::global()
            .call(self.module_id, Some(self.instance_id), &method, &payload)
            .map_err(|e| e.to_string())
    }

    /// 实例句柄的字符串形式（信封 instance 字段用；Dart 侧拼 EnvelopeRequest 路由）
    pub fn instance_id(&self) -> String {
        self.instance_id.to_string()
    }

    /// 显式释放实例（幂等）
    pub fn dispose(&self) -> Result<(), String> {
        crate::manager::ModuleManager::global()
            .call_destroy(self.module_id, self.instance_id)
            .map_err(|e| e.to_string())
    }
}

impl Drop for InstanceHandle {
    fn drop(&mut self) {
        let _ = crate::manager::ModuleManager::global().call_destroy(self.module_id, self.instance_id);
    }
}

impl ModuleHandle {
    /// 信封级调用：Dart 侧传 EnvelopeRequest 编码字节，宿主解包→路由→封包返回
    pub fn call_envelope(&self, request_bytes: Vec<u8>) -> Vec<u8> {
        crate::manager::ModuleManager::global().call_envelope(&request_bytes)
    }

    /// 带超时的信封级调用（毫秒；0 = 不超时）。超时后尽力 cancel 并返回 504 信封。
    pub fn call_envelope_timed(&self, request_bytes: Vec<u8>, timeout_ms: u64) -> Vec<u8> {
        if timeout_ms == 0 {
            return self.call_envelope(request_bytes);
        }
        crate::manager::ModuleManager::global().call_envelope_with_timeout(
            &request_bytes,
            std::time::Duration::from_millis(timeout_ms),
        )
    }

    /// 取消某次在途调用（按 request_id 路由到模块 cancel；模块未实现则无操作）
    pub fn cancel_call(&self, request_id: String) -> Result<(), String> {
        crate::manager::ModuleManager::global()
            .cancel(self.id, None, &request_id)
            .map_err(|e| e.to_string())
    }
}

/// 宿主诊断（只读）：查看已加载的原生插件状态，供 UI 展示"是否存在/是否加载"。
#[frb(opaque)]
pub struct HostInspector;

impl HostInspector {
    #[frb(init)]
    pub fn new() -> Self {
        Self
    }

    /// 已加载的原生插件快照（名字/版本/常驻/引用计数）
    pub fn loaded_modules(&self) -> Vec<ModuleInfo> {
        crate::manager::ModuleManager::global().list_modules()
    }

    /// 清空日志/事件/任务桥的订阅 sink。引擎在同进程内被销毁重建、或 Flutter
    /// engine/Dart isolate 重启（Activity 重建）时，宿主仍持有指向上一个
    /// isolate 的失效端口；新 isolate 应在订阅前调用本函数。
    ///
    /// 只丢弃订阅端点：Rust 引擎、已加载模块与 TUN 隧道**不受影响**（隧道由
    /// `nativeSetTunFd` 持有，模块事件/日志继续入有界环形缓冲，新 isolate
    /// 重新订阅时补发）。任务（[`crate::task_bridge`]）继续运行，仅其 sink 被丢弃。
    pub fn reset_bridges(&self) {
        crate::log_bridge::clear_sink();
        crate::event_bridge::clear_sink();
        crate::task_bridge::reset_sinks();
    }
}

use gstore_core::{db as core_db, migration as core_migration};
use rusqlite::OptionalExtension;

const CORE_E_NOT_INITIALIZED: &str =
    "CORE_E_NOT_INITIALIZED: CoreApi.init() has not been called";

struct CorePaths {
    data_dir: String,
    files_dir: String,
    cache_dir: String,
}

/// 核心库宿主门面（spike）：初始化、迁移目录、快照导出/导入与写入标记查询。
///
/// `rusqlite::Connection` 只作为私有字段存在；对外签名全部是 FRB 可直接映射的
/// `String` / `i32` / `u64` / 普通数据类。
#[frb(opaque)]
pub struct CoreApi {
    paths: std::sync::Mutex<Option<CorePaths>>,
    db: std::sync::Mutex<Option<rusqlite::Connection>>,
}

pub struct CoreInitResult {
    pub schema_version: i32,
    pub db_path: String,
    pub data_dir: String,
    pub files_dir: String,
    pub cache_dir: String,
}

pub struct CoreWritesMarker {
    pub domain: String,
    pub first_write_at: i64,
    pub snapshot_id: Option<String>,
}

/// Rust-owned feature flag snapshot (FRB data class).
///
/// Field names mirror `gstore_core::flags::Flags`; the values always come from
/// the core's process-global state.
pub struct Flags {
    pub channels: bool,
    pub catalog: bool,
    pub update: bool,
    pub download: bool,
    pub install: bool,
    pub js_channel: bool,
    pub core_writes: bool,
}

impl From<gstore_core::flags::Flags> for Flags {
    fn from(flags: gstore_core::flags::Flags) -> Self {
        Self {
            channels: flags.channels,
            catalog: flags.catalog,
            update: flags.update,
            download: flags.download,
            install: flags.install,
            js_channel: flags.js_channel,
            core_writes: flags.core_writes,
        }
    }
}

/// Partial flag update accepted by [`FlagsApi::set`] (FRB data class).
///
/// `None` leaves a flag unchanged. `Some(true)` for `core_writes` is rejected
/// by the core in Wave 0/1.
pub struct FlagsPatch {
    pub channels: Option<bool>,
    pub catalog: Option<bool>,
    pub update: Option<bool>,
    pub download: Option<bool>,
    pub install: Option<bool>,
    pub js_channel: Option<bool>,
    pub core_writes: Option<bool>,
}

impl From<FlagsPatch> for gstore_core::flags::FlagsPatch {
    fn from(patch: FlagsPatch) -> Self {
        Self {
            channels: patch.channels,
            catalog: patch.catalog,
            update: patch.update,
            download: patch.download,
            install: patch.install,
            js_channel: patch.js_channel,
            core_writes: patch.core_writes,
        }
    }
}

/// Feature-flag facade for Flutter. The Rust core remains authoritative; the
/// Dart `CoreFlags` class is a read-only mirror of [`FlagsApi::get`].
#[frb(opaque)]
pub struct FlagsApi;

impl FlagsApi {
    /// Creates the facade (generated as `FlagsApi.init()` in Dart).
    pub fn init() -> FlagsApi {
        FlagsApi
    }

    /// Returns the current Rust-owned snapshot.
    pub fn get(&self) -> Flags {
        Flags::from(gstore_core::flags::flags())
    }

    /// Applies a partial update and returns the resulting snapshot.
    pub fn set(&self, patch: FlagsPatch) -> Result<Flags, String> {
        gstore_core::flags::set_flags(patch.into())
            .map(Flags::from)
            .map_err(|e| e.to_string())
    }

    /// Resets every flag to `false` and returns the resulting snapshot.
    pub fn reset(&self) -> Flags {
        Flags::from(gstore_core::flags::reset_flags())
    }
}

impl CoreApi {
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<CoreApi, String> {
        for dir in [&data_dir, &files_dir, &cache_dir] {
            std::fs::create_dir_all(dir)
                .map_err(|e| format!("CORE_E_INIT: create dir {dir}: {e}"))?;
        }
        let conn = core_db::open(std::path::Path::new(&data_dir))
            .map_err(|e| format!("CORE_E_INIT: {}", e.0))?;
        Ok(CoreApi {
            paths: std::sync::Mutex::new(Some(CorePaths {
                data_dir,
                files_dir,
                cache_dir,
            })),
            db: std::sync::Mutex::new(Some(conn)),
        })
    }

    pub fn migrate_paths(&self) -> Result<CoreInitResult, String> {
        let paths = self
            .paths
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: paths lock poisoned"))?;
        let paths = paths
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;

        let migration_dir =
            core_migration::migration_dir(std::path::Path::new(&paths.files_dir));
        std::fs::create_dir_all(&migration_dir).map_err(|e| {
            format!(
                "CORE_E_MIGRATE: create {}: {e}",
                migration_dir.display()
            )
        })?;

        let db = self
            .db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let db = db
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;
        let schema_version: i32 = db
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(|e| format!("CORE_E_MIGRATE: read user_version: {e}"))?;

        Ok(CoreInitResult {
            schema_version,
            db_path: core_db::core_db_path(std::path::Path::new(&paths.data_dir))
                .to_string_lossy()
                .into_owned(),
            data_dir: paths.data_dir.clone(),
            files_dir: paths.files_dir.clone(),
            cache_dir: paths.cache_dir.clone(),
        })
    }

    pub fn import_file(&self, path_or_fd: String) -> Result<u64, String> {
        let meta = std::fs::metadata(std::path::Path::new(&path_or_fd))
            .map_err(|_| format!("CORE_E_IMPORT_NOT_FOUND: {path_or_fd}"))?;
        if !meta.is_file() {
            return Err(format!("CORE_E_IMPORT_NOT_FOUND: {path_or_fd}"));
        }
        Ok(meta.len())
    }

    pub fn export_snapshot(&self, path: String) -> Result<u64, String> {
        let db = self
            .db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let db = db
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;

        let target = std::path::Path::new(&path);
        if target.exists() {
            std::fs::remove_file(target)
                .map_err(|e| format!("CORE_E_EXPORT: remove existing {path}: {e}"))?;
        }
        db.execute("VACUUM INTO ?1", rusqlite::params![&path])
            .map_err(|e| format!("CORE_E_EXPORT: vacuum into {path}: {e}"))?;
        let size = std::fs::metadata(target)
            .map_err(|e| format!("CORE_E_EXPORT: stat {path}: {e}"))?
            .len();
        Ok(size)
    }

    pub fn import_snapshot(&self, path: String) -> Result<i32, String> {
        let conn = rusqlite::Connection::open_with_flags(
            &path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .map_err(|e| format!("CORE_E_IMPORT_SNAPSHOT: open {path}: {e}"))?;
        let version: i32 = conn
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(|e| format!("CORE_E_IMPORT_SNAPSHOT: read user_version: {e}"))?;
        for table in ["core_writes", "download_task"] {
            let found: Option<String> = conn
                .query_row(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name=?1",
                    [table],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|e| {
                    format!("CORE_E_IMPORT_SNAPSHOT: inspect sqlite_master: {e}")
                })?;
            if found.is_none() {
                return Err(format!(
                    "CORE_E_IMPORT_SNAPSHOT: missing table {table}"
                ));
            }
        }
        Ok(version)
    }

    /// Imports one Dart-exported migration artifact.
    ///
    /// Faces for `channel_db`, `channel_env`, `fdroid_sources`, and `pack` route
    /// through [`gstore_core::channel_migration`]; `update_prefs` keeps the
    /// original JSON-document path. The old source files are never moved or
    /// deleted by this method (only successfully imported env/fdroid documents
    /// are removed).
    pub fn import_migration_file(&self, kind: String, path: String) -> Result<u32, String> {
        let paths = {
            let guard = self
                .paths
                .lock()
                .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: paths lock poisoned"))?;
            let paths = guard
                .as_ref()
                .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;
            (paths.data_dir.clone(), paths.files_dir.clone())
        };
        let path_ref = std::path::Path::new(&path);
        let migration_dir =
            core_migration::migration_dir(std::path::Path::new(&paths.1));

        if kind == "pack" {
            let db = core_db::DbHandle::open(std::path::Path::new(&paths.0))
                .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: channel db: {}", e.0))?;
            // The pack path is read-only w.r.t. its migrator connection; the
            // PackStore owns the single writer mutex.
            let conn = rusqlite::Connection::open(db.path())
                .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: open db: {e}"))?;
            let secrets = gstore_core::ports::FileSecretStore::new(
                std::path::Path::new(&paths.1).join("secrets"),
            );
            let backup_dir = migration_dir.join("backups");
            let migrator = gstore_core::channel_migration::ChannelMigrator::new(
                &conn,
                &secrets,
                backup_dir,
            );
            let store = gstore_core::channel::PackStore::new(
                std::path::Path::new(&paths.1).join("channel_packs"),
                db,
            );
            return migrator
                .import_pack_archive(&store, path_ref)
                .map(|report| report.packs as u32)
                .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {e}"));
        }

        let db = self
            .db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let db = db
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;

        match kind.as_str() {
            "channel_db" => {
                let secrets = gstore_core::ports::FileSecretStore::new(
                    std::path::Path::new(&paths.1).join("secrets"),
                );
                let migrator = gstore_core::channel_migration::ChannelMigrator::new(
                    db,
                    &secrets,
                    migration_dir.join("backups"),
                );
                migrator
                    .import_channel_db(path_ref)
                    .map(|report| report.rows_imported as u32)
                    .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {e}"))
            }
            "channel_env" => {
                let secrets = gstore_core::ports::FileSecretStore::new(
                    std::path::Path::new(&paths.1).join("secrets"),
                );
                let migrator = gstore_core::channel_migration::ChannelMigrator::new(
                    db,
                    &secrets,
                    migration_dir.join("backups"),
                );
                let report = migrator
                    .import_channel_env_path(path_ref)
                    .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {e}"))?;
                // Only managed export documents are deleted; an arbitrary
                // caller-supplied path is left in place.
                if path_ref.starts_with(&migration_dir) {
                    std::fs::remove_file(path_ref).map_err(|e| {
                        format!(
                            "CORE_E_IMPORT_MIGRATION: delete {}: {e}",
                            path_ref.display()
                        )
                    })?;
                }
                Ok(report.rows as u32)
            }
            "fdroid_sources" => {
                let secrets = gstore_core::ports::FileSecretStore::new(
                    std::path::Path::new(&paths.1).join("secrets"),
                );
                let migrator = gstore_core::channel_migration::ChannelMigrator::new(
                    db,
                    &secrets,
                    migration_dir.join("backups"),
                );
                migrator
                    .import_fdroid_sources_file(path_ref)
                    .map(|report| report.sources as u32)
                    .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {e}"))
            }
            _ => core_migration::import_migration_file(db, &kind, path_ref)
                .map(|written| written as u32)
                .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {}", e.0)),
        }
    }

    pub fn core_writes(&self, domain: String) -> Result<Option<CoreWritesMarker>, String> {
        let db = self
            .db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let db = db
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;
        core_migration::core_write_marker(db, &domain)
            .map(|marker| {
                marker.map(|m| CoreWritesMarker {
                    domain: m.domain,
                    first_write_at: m.first_write_at,
                    snapshot_id: m.snapshot_id,
                })
            })
            .map_err(|e| format!("CORE_E_WRITES: query {domain}: {}", e.0))
    }
}

#[cfg(test)]
mod core_api_tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture_root() -> PathBuf {
        std::env::temp_dir().join(format!("gstore_core_api_test_{}", std::process::id()))
    }

    #[test]
    fn core_api_contract() {
        let root = fixture_root();
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let data_dir = root.join("data");
        let files_dir = root.join("files");
        let cache_dir = root.join("cache");

        let api = CoreApi::init(
            data_dir.to_string_lossy().into_owned(),
            files_dir.to_string_lossy().into_owned(),
            cache_dir.to_string_lossy().into_owned(),
        )
        .expect("CoreApi::init");

        let init = api.migrate_paths().expect("migrate_paths");
        assert_eq!(
            init.schema_version,
            gstore_core::migration::CORE_SCHEMA_VERSION
        );
        assert!(
            std::path::Path::new(&init.db_path).exists(),
            "db file missing: {}",
            init.db_path
        );
        assert_eq!(
            init.db_path,
            data_dir
                .join("gstore_core.db")
                .to_string_lossy()
                .into_owned()
        );

        let migration_dir = files_dir.join("migration");
        assert!(
            migration_dir.is_dir(),
            "migration dir missing: {}",
            migration_dir.display()
        );

        for domain in ["channel", "update", "download"] {
            assert!(
                api.core_writes(domain.to_string())
                    .expect("core_writes")
                    .is_none(),
                "init must not arm {domain}"
            );
        }

        let sample = root.join("a.txt");
        let content = b"hello gstore core";
        std::fs::write(&sample, content).unwrap();
        let len = api
            .import_file(sample.to_string_lossy().into_owned())
            .expect("import_file");
        assert_eq!(len, content.len() as u64);

        let snapshot = root.join("snap.db");
        let size = api
            .export_snapshot(snapshot.to_string_lossy().into_owned())
            .expect("export_snapshot");
        assert!(size > 0, "snapshot size must be positive");
        assert!(snapshot.is_file(), "snapshot file missing");

        let version = api
            .import_snapshot(snapshot.to_string_lossy().into_owned())
            .expect("import_snapshot");
        assert_eq!(version, gstore_core::migration::CORE_SCHEMA_VERSION);

        let migration_doc = root.join("migration_channel.json");
        std::fs::write(
            &migration_doc,
            br#"{"version":1,"channel_key":"js.test","env":{"a":"b"}}"#,
        )
        .unwrap();
        let imported = api
            .import_migration_file(
                "channel_env".to_string(),
                migration_doc.to_string_lossy().into_owned(),
            )
            .expect("import_migration_file");
        assert_eq!(imported, 1);
        let reimported = api
            .import_migration_file(
                "channel_env".to_string(),
                migration_doc.to_string_lossy().into_owned(),
            )
            .expect("import_migration_file again");
        assert_eq!(reimported, 1, "migration import must be idempotent");

        let missing = root.join("does-not-exist.txt");
        let err = api
            .import_file(missing.to_string_lossy().into_owned())
            .unwrap_err();
        assert!(
            err.contains("CORE_E_IMPORT_NOT_FOUND"),
            "unexpected error: {err}"
        );

        drop(api);
        std::fs::remove_dir_all(&root).unwrap();
    }

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "gstore_core_api_{tag}_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    fn core_writes_count(db_path: &str) -> i64 {
        let conn = rusqlite::Connection::open_with_flags(
            db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .expect("open live db read-only");
        conn.query_row("SELECT COUNT(*) FROM core_writes", [], |r| r.get(0))
            .expect("count core_writes")
    }

    #[test]
    fn core_writes_empty_after_init_and_migration() {
        let root = temp_root("writes");
        let data_dir = root.join("data");
        let files_dir = root.join("files");
        let cache_dir = root.join("cache");
        let api = CoreApi::init(
            data_dir.to_string_lossy().into_owned(),
            files_dir.to_string_lossy().into_owned(),
            cache_dir.to_string_lossy().into_owned(),
        )
        .expect("CoreApi::init");

        let init = api.migrate_paths().expect("migrate_paths");
        let count = core_writes_count(&init.db_path);
        println!("after init+migrate_paths: SELECT COUNT(*) FROM core_writes = {count}");
        assert_eq!(count, 0, "init/migrate_paths must not arm core_writes");
        for domain in core_migration::CORE_WRITES_DOMAINS {
            let marker = api
                .core_writes(domain.to_string())
                .expect("core_writes");
            println!(
                "after init+migrate_paths: marker[{domain}] present = {}",
                marker.is_some()
            );
            assert!(marker.is_none(), "{domain} must not be armed");
        }

        let migration_path = files_dir.join("migration");
        let channel_doc = migration_path.join("channel_env.json");
        std::fs::write(
            &channel_doc,
            br#"{"version":1,"channel_key":"js.wave01","env":{"USER":"alice"}}"#,
        )
        .unwrap();
        let channel_rows = api
            .import_migration_file(
                "channel_env".to_string(),
                channel_doc.to_string_lossy().into_owned(),
            )
            .expect("import channel_env");
        assert_eq!(channel_rows, 1);

        let prefs_doc = migration_path.join("update_prefs.json");
        std::fs::write(
            &prefs_doc,
            br#"{"version":1,"prefs":{"update_last_checked_at":"1700000000000"}}"#,
        )
        .unwrap();
        let pref_rows = api
            .import_migration_file(
                "update_prefs".to_string(),
                prefs_doc.to_string_lossy().into_owned(),
            )
            .expect("import update_prefs");
        assert_eq!(pref_rows, 1);

        let count = core_writes_count(&init.db_path);
        println!("after migration imports: core_writes count = {count}");
        assert_eq!(count, 0, "migration imports must not arm core_writes");

        let snapshot = root.join("snapshot.db");
        let size = api
            .export_snapshot(snapshot.to_string_lossy().into_owned())
            .expect("export_snapshot");
        assert!(size > 0);

        let stale = rusqlite::Connection::open(&snapshot).expect("open snapshot");
        stale
            .execute(
                "INSERT INTO core_writes(domain, first_write_at, snapshot_id) \
                 VALUES ('channel', 1, 'stale-snapshot')",
                [],
            )
            .expect("seed snapshot marker");
        drop(stale);
        let stale_count = core_writes_count(&snapshot.to_string_lossy());
        println!("seeded snapshot core_writes count = {stale_count}");
        assert_eq!(stale_count, 1);

        assert_eq!(
            api.import_snapshot(snapshot.to_string_lossy().into_owned())
                .expect("import_snapshot"),
            gstore_core::migration::CORE_SCHEMA_VERSION
        );

        let count = core_writes_count(&init.db_path);
        println!("after snapshot export/import: core_writes count = {count}");
        assert_eq!(count, 0, "snapshot round-trip must not arm core_writes");

        let live = rusqlite::Connection::open_with_flags(
            &init.db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .expect("open live db");
        for domain in core_migration::CORE_WRITES_DOMAINS {
            let marker = api
                .core_writes(domain.to_string())
                .expect("core_writes");
            assert!(marker.is_none(), "{domain} must stay unarmed");
            core_migration::ensure_legacy_write_allowed(&live, domain)
                .unwrap_or_else(|e| panic!("guard must stay disabled for {domain}: {}", e.0));
        }

        drop(live);
        drop(api);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn malformed_migration_leaves_core_writes_empty() {
        let root = temp_root("malformed");
        let data_dir = root.join("data");
        let files_dir = root.join("files");
        let cache_dir = root.join("cache");
        let api = CoreApi::init(
            data_dir.to_string_lossy().into_owned(),
            files_dir.to_string_lossy().into_owned(),
            cache_dir.to_string_lossy().into_owned(),
        )
        .expect("CoreApi::init");
        let init = api.migrate_paths().expect("migrate_paths");

        let cases: [(&str, &str, &str); 3] = [
            (
                "bad-json.json",
                "channel_env",
                r#"{"version":1,"channel_key":"js.bad","env":{"a":"b"}"#,
            ),
            (
                "bad-version.json",
                "channel_env",
                r#"{"version":2,"channel_key":"js.bad","env":{"a":"b"}}"#,
            ),
            (
                "bad-shape.json",
                "update_prefs",
                r#"{"version":1,"prefs":[]}"#,
            ),
        ];

        for (name, kind, body) in cases {
            let path = root.join(name);
            std::fs::write(&path, body).unwrap();
            let err = api
                .import_migration_file(kind.to_string(), path.to_string_lossy().into_owned())
                .expect_err("malformed document must fail");
            println!("{name}: {err}");
            assert!(
                err.starts_with("CORE_E_IMPORT_MIGRATION"),
                "{name}: expected typed error, got {err}"
            );
            println!("{name}: document retained = {}", path.is_file());
            assert!(path.is_file(), "{name}: document must be retained on failure");
            let count = core_writes_count(&init.db_path);
            println!("{name}: core_writes count = {count}");
            assert_eq!(count, 0, "{name}: failure must not arm core_writes");
            for domain in core_migration::CORE_WRITES_DOMAINS {
                let marker = api
                    .core_writes(domain.to_string())
                    .expect("core_writes");
                println!(
                    "{name}: marker[{domain}] present = {}",
                    marker.is_some()
                );
                assert!(
                    marker.is_none(),
                    "{name}: {domain} must not be armed"
                );
            }
        }

        drop(api);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn channel_migration_bridge_kinds() {
        let root = temp_root("channel12");
        let data_dir = root.join("data");
        let files_dir = root.join("files");
        let cache_dir = root.join("cache");
        let api = CoreApi::init(
            data_dir.to_string_lossy().into_owned(),
            files_dir.to_string_lossy().into_owned(),
            cache_dir.to_string_lossy().into_owned(),
        )
        .expect("CoreApi::init");
        let init = api.migrate_paths().expect("migrate_paths");

        // channel_db: mapped twice without duplication, source retained, backup.
        let old_db = root.join("channel_apps.db");
        {
            let conn = rusqlite::Connection::open(&old_db).unwrap();
            conn.execute_batch(
                "CREATE TABLE channel_added_app(
                     appId TEXT NOT NULL, name TEXT NOT NULL, user TEXT NOT NULL,
                     repositories TEXT NOT NULL, apprepo TEXT, icon TEXT NOT NULL,
                     description TEXT NOT NULL, category TEXT, addTime INTEGER NOT NULL,
                     channelCode TEXT NOT NULL, extra TEXT, sourceId TEXT,
                     PRIMARY KEY(channelCode, appId));
                 INSERT INTO channel_added_app VALUES
                     ('a','A','u','r',NULL,'i','d',NULL,1,'github',NULL,NULL),
                     ('b','B','u','r',NULL,'i','d',NULL,2,'fdroid',NULL,'official');
                 PRAGMA user_version = 5;",
            )
            .unwrap();
        }
        let before = std::fs::read(&old_db).unwrap();
        for run in 1..=2 {
            let rows = api
                .import_migration_file(
                    "channel_db".to_string(),
                    old_db.to_string_lossy().into_owned(),
                )
                .expect("import channel_db");
            println!("channel_db run {run}: rows={rows}");
            assert_eq!(rows, 2);
        }
        assert!(old_db.is_file(), "legacy DB must survive");
        assert_eq!(std::fs::read(&old_db).unwrap(), before, "legacy DB mutated");
        let live = rusqlite::Connection::open(&init.db_path).unwrap();
        let rows: i64 = live
            .query_row("SELECT COUNT(*) FROM channel_apps", [], |r| r.get(0))
            .unwrap();
        assert_eq!(rows, 2, "re-import must not duplicate channel rows");
        let backups = std::fs::read_dir(files_dir.join("migration").join("backups"))
            .expect("backup dir")
            .count();
        println!("channel_db backups = {backups}");
        assert!(backups >= 1);

        // channel_env: sensitive value reaches FileSecretPort only; doc deleted.
        let env_path = files_dir.join("migration").join("channel_env.js.bridge.json");
        std::fs::write(
            &env_path,
            br#"{"version":1,"channel_key":"js.bridge","env":{"USER":"alice","PASSWORD":"p@ss"}}"#,
        )
        .unwrap();
        let env_rows = api
            .import_migration_file(
                "channel_env".to_string(),
                env_path.to_string_lossy().into_owned(),
            )
            .expect("import channel_env");
        println!("channel_env rows={env_rows} doc_exists={}", env_path.exists());
        assert_eq!(env_rows, 1);
        assert!(!env_path.exists(), "managed env doc must be deleted");
        let env_json: String = live
            .query_row(
                "SELECT env_json FROM channel_env WHERE channel_key='js.bridge'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        println!("bridge plaintext env = {env_json}");
        assert!(!env_json.contains("p@ss"));
        assert!(!env_json.contains("PASSWORD"));
        let secret = std::fs::read_to_string(
            files_dir.join("secrets").join("channel.js.bridge.PASSWORD"),
        )
        .expect("secret file");
        assert_eq!(secret, "p@ss");

        // fdroid_sources: persisted, doc deleted.
        let fdroid_path = files_dir.join("migration").join("fdroid_sources.json");
        std::fs::write(
            &fdroid_path,
            br#"{"version":1,"sources":[{"id":"official","name":"Official","repoUrl":"https://f-droid.org/repo"}],"last_source_id":"official"}"#,
        )
        .unwrap();
        let sources = api
            .import_migration_file(
                "fdroid_sources".to_string(),
                fdroid_path.to_string_lossy().into_owned(),
            )
            .expect("import fdroid_sources");
        println!("fdroid sources={sources} doc_exists={}", fdroid_path.exists());
        assert_eq!(sources, 1);
        assert!(!fdroid_path.exists());
        let last: String = live
            .query_row(
                "SELECT value FROM update_prefs WHERE key='last_source_id'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(last, "official");

        drop(live);
        drop(api);
        std::fs::remove_dir_all(&root).unwrap();
    }
}



// ===========================================================================
// ChannelApi (Todo 13)
// ===========================================================================

use std::path::{Path, PathBuf};
use std::sync::Arc;

use gstore_core::channel::{
    validate_channel_key, ChannelCategory, ChannelDriver, ChannelRegistry,
    FdroidDriver, GitHubDriver, InstalledPack, LocalDbDriver, PackError, PackStore,
    SqliteChannelStore, VivoDriver,
};
use gstore_core::db::DbHandle;
use gstore_core::dto::{
    AppDetail, AppDownload, AppSummary, ChannelKey, ChannelKind, ChannelMeta, DetailSection,
};
use gstore_core::ports::{
    validate_secret_key, CachedMetadataPort, CoreConfig, FileSecretPort, FileSecretStore,
    HttpOptions, HttpPort, MetadataPort, PackageMetadata, RepoPort,
};
use gstore_core::Error as CoreError;
use gstore_core::channel_migration::is_sensitive_key;

fn core_err(error: CoreError) -> String {
    format!("{}: {}", error.code(), error.message())
}

fn pack_err(error: PackError) -> String {
    format!("{}: {}", error.code(), error.message())
}

fn invalid_arg(message: impl Into<String>) -> String {
    core_err(CoreError::InvalidArgument(message.into()))
}

/// One registered channel exposed to Dart.
#[derive(Debug, Clone)]
pub struct ChannelEntry {
    /// Stable key (`local_db`, `github`, `js_pingan`, ...).
    pub key: String,
    /// Implementation kind code.
    pub kind: String,
    pub name: String,
    pub description: String,
    pub enabled: bool,
    pub priority: i32,
    pub support_offline: bool,
    pub last_update_time: Option<i64>,
    pub version: Option<String>,
}

impl From<gstore_core::channel::ChannelRecord> for ChannelEntry {
    fn from(record: gstore_core::channel::ChannelRecord) -> Self {
        Self {
            key: record.key.as_str().to_string(),
            kind: record.kind().as_code().to_string(),
            name: record.meta.name,
            description: record.meta.description,
            enabled: record.meta.enabled,
            priority: record.meta.priority,
            support_offline: record.meta.support_offline,
            last_update_time: record.meta.last_update_time,
            version: record.meta.version,
        }
    }
}

/// Input accepted by [`ChannelApi::register`].
#[derive(Debug, Clone)]
pub struct ChannelRegistration {
    pub key: String,
    pub kind: String,
    pub name: String,
    pub description: String,
    pub enabled: bool,
    pub priority: i32,
    pub support_offline: bool,
    pub version: Option<String>,
}

/// One app summary crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct ChannelAppInfo {
    pub app_id: String,
    pub package_name: Option<String>,
    pub name: String,
    pub user: String,
    pub repositories: String,
    pub icon: String,
    pub des: String,
    pub readme: Option<String>,
    pub category: Vec<String>,
    pub extra_json: Option<String>,
}

impl ChannelAppInfo {
    fn from_summary(app: AppSummary) -> Self {
        Self {
            app_id: app.app_id,
            package_name: app.package_name,
            name: app.name,
            user: app.user,
            repositories: app.repositories,
            icon: app.icon,
            des: app.des,
            readme: app.readme,
            category: app.category.unwrap_or_default(),
            extra_json: app.extra.map(|extra| serde_json::Value::Object(extra).to_string()),
        }
    }

    fn into_summary(self) -> Result<AppSummary, String> {
        let extra = match self.extra_json {
            Some(raw) if !raw.trim().is_empty() => {
                let value: serde_json::Value = serde_json::from_str(&raw)
                    .map_err(|error| core_err(CoreError::Serialization(error.to_string())))?;
                Some(value.as_object().cloned().ok_or_else(|| {
                    core_err(CoreError::Serialization(
                        "extra_json must be a JSON object".to_string(),
                    ))
                })?)
            }
            _ => None,
        };
        Ok(AppSummary {
            app_id: self.app_id,
            package_name: self.package_name,
            name: self.name,
            user: self.user,
            repositories: self.repositories,
            icon: self.icon,
            des: self.des,
            readme: self.readme,
            category: if self.category.is_empty() {
                None
            } else {
                Some(self.category)
            },
            extra,
        })
    }
}

/// One download candidate in an app detail payload.
#[derive(Debug, Clone)]
pub struct ChannelAppDownloadInfo {
    pub url: String,
    pub name: String,
    pub size: Option<i64>,
    pub download_count: Option<i64>,
    pub version: Option<String>,
    pub version_code: Option<i64>,
    pub published_at: Option<i64>,
    pub platform: Option<String>,
    pub hash: Option<String>,
    pub hash_type: Option<String>,
    pub downloadable: bool,
    pub note: Option<String>,
    pub extra_json: Option<String>,
}

impl From<AppDownload> for ChannelAppDownloadInfo {
    fn from(download: AppDownload) -> Self {
        Self {
            url: download.url,
            name: download.name,
            size: download.size,
            download_count: download.download_count,
            version: download.version,
            version_code: download.version_code,
            published_at: download.published_at,
            platform: download.platform,
            hash: download.hash,
            hash_type: download.hash_type,
            downloadable: download.downloadable,
            note: download.note,
            extra_json: download.extra.map(|extra| serde_json::Value::Object(extra).to_string()),
        }
    }
}

/// Full app detail crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct ChannelAppDetailInfo {
    pub app_id: String,
    pub name: String,
    pub icon: String,
    pub description: String,
    pub version: Option<String>,
    pub developer: Option<String>,
    pub package_name: Option<String>,
    pub project_url: Option<String>,
    pub channel: String,
    pub sections: Vec<String>,
    pub downloads: Vec<ChannelAppDownloadInfo>,
    pub extra_json: String,
}

fn section_code(section: DetailSection) -> &'static str {
    match section {
        DetailSection::Version => "version",
        DetailSection::Statistics => "statistics",
        DetailSection::Screenshots => "screenshots",
        DetailSection::Readme => "readme",
        DetailSection::Downloads => "downloads",
        DetailSection::Rating => "rating",
        DetailSection::Developer => "developer",
        DetailSection::Changelog => "changelog",
        DetailSection::Permissions => "permissions",
    }
}

impl From<AppDetail> for ChannelAppDetailInfo {
    fn from(detail: AppDetail) -> Self {
        Self {
            app_id: detail.app_id,
            name: detail.name,
            icon: detail.icon,
            description: detail.description,
            version: detail.version,
            developer: detail.developer,
            package_name: detail.package_name,
            project_url: detail.project_url,
            channel: detail.channel.as_code().to_string(),
            sections: detail
                .sections
                .into_iter()
                .map(|section| section_code(section).to_string())
                .collect(),
            downloads: detail
                .downloads
                .into_iter()
                .map(ChannelAppDownloadInfo::from)
                .collect(),
            extra_json: serde_json::Value::Object(detail.extra).to_string(),
        }
    }
}

/// One channel category.
#[derive(Debug, Clone)]
pub struct ChannelCategoryInfo {
    pub id: String,
    pub description: String,
    pub icon: String,
}

impl From<ChannelCategory> for ChannelCategoryInfo {
    fn from(category: ChannelCategory) -> Self {
        Self {
            id: category.id,
            description: category.description,
            icon: category.icon,
        }
    }
}

/// Channel `app_config` row.
#[derive(Debug, Clone)]
pub struct ChannelConfigInfo {
    pub version: String,
    pub proxy: Option<String>,
}

/// One imported local pack.
#[derive(Debug, Clone)]
pub struct ChannelPackInfo {
    pub key: String,
    pub pack_hash: String,
    pub installed_at: i64,
    pub dir: String,
}

impl From<InstalledPack> for ChannelPackInfo {
    fn from(pack: InstalledPack) -> Self {
        Self {
            key: pack.key.as_str().to_string(),
            pack_hash: pack.pack_hash,
            installed_at: pack.installed_at,
            dir: pack.dir.to_string_lossy().into_owned(),
        }
    }
}

/// Host `MetadataPort`: reads the GStore metadata repository fallback.
struct HttpMetadataPort {
    http: Arc<dyn HttpPort>,
}

impl HttpMetadataPort {
    fn new(http: Arc<dyn HttpPort>) -> Self {
        Self { http }
    }
}

impl MetadataPort for HttpMetadataPort {
    fn fetch(&self, owner: &str, repo: &str) -> Result<Option<PackageMetadata>, CoreError> {
        if owner.trim().is_empty() || repo.trim().is_empty() {
            return Err(CoreError::InvalidArgument(
                "owner and repo must not be empty".to_string(),
            ));
        }
        let url = format!(
            "https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/metadata/{owner}@{repo}/info.json"
        );
        let options = HttpOptions::new()
            .with_header("User-Agent", "GStore-App/1.0")
            .with_timeout(std::time::Duration::from_secs(8));
        let response = match self.http.get(&url, &options) {
            Ok(response) => response,
            // Dart MetadataRepository treats transport failures as a miss.
            Err(_) => return Ok(None),
        };
        if response.status != 200 || response.body.is_empty() {
            return Ok(None);
        }
        let value: serde_json::Value = match serde_json::from_slice(&response.body) {
            Ok(value) => value,
            Err(_) => return Ok(None),
        };
        let Some(object) = value.as_object() else {
            return Ok(None);
        };
        let package_name = object
            .get("packageName")
            .and_then(serde_json::Value::as_str)
            .map(ToString::to_string);
        let app_name = object
            .get("appName")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        let icon_url = object
            .get("icon")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .map(|icon| {
                format!("https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/{icon}")
            })
            .or_else(|| {
                Some(format!(
                    "https://raw.githubusercontent.com/sunO2/GStore-Repositorys/main/metadata/{owner}@{repo}/icon.png"
                ))
            });
        Ok(Some(PackageMetadata {
            package_name,
            app_name,
            icon_url,
        }))
    }
}

/// Host `RepoPort` adapter over the optional `gstore_mod_repo` module.
///
/// The module is mounted by Dart; until it is, every operation is a typed
/// [`CoreError::Unsupported`] instead of a panic. The instance is created lazily
/// on first use so ChannelApi init never performs module I/O.
struct HostRepoPort {
    db_path: PathBuf,
    data_dir: PathBuf,
    port: std::sync::Mutex<Option<crate::repo_port::ModuleRepoPort<crate::repo_port::ModuleManagerBridge>>>,
}

impl HostRepoPort {
    fn new(data_dir: impl AsRef<Path>) -> Self {
        let data_dir = data_dir.as_ref().to_path_buf();
        Self {
            db_path: data_dir.join("repo.db"),
            data_dir,
            port: std::sync::Mutex::new(None),
        }
    }

    fn with_port<T>(
        &self,
        f: impl FnOnce(&crate::repo_port::ModuleRepoPort<crate::repo_port::ModuleManagerBridge>) -> Result<T, CoreError>,
    ) -> Result<T, CoreError> {
        let mut guard = self
            .port
            .lock()
            .map_err(|_| CoreError::Internal("repo port lock poisoned".to_string()))?;
        if guard.is_none() {
            let manager = crate::manager::ModuleManager::global();
            let module_id = manager.module_id_by_name("repo").ok_or_else(|| {
                CoreError::Unsupported(
                    "repo module is not mounted (F-Droid operations unavailable until it is)".to_string(),
                )
            })?;
            let config = serde_json::json!({
                "db_path": self.db_path.to_string_lossy(),
                "data_dir": self.data_dir.to_string_lossy(),
            });
            let bytes = serde_json::to_vec(&config)
                .map_err(|error| CoreError::Serialization(error.to_string()))?;
            let instance = manager
                .call_create(module_id, &bytes)
                .map_err(|error| CoreError::Internal(format!("repo module create: {error}")))?;
            *guard = Some(crate::repo_port::ModuleRepoPort::new(
                crate::repo_port::ModuleManagerBridge::new(module_id, instance),
                self.db_path.clone(),
            ));
        }
        let port = guard.as_ref().ok_or_else(|| {
            CoreError::Internal("repo port was not initialized".to_string())
        })?;
        f(port)
    }
}

impl RepoPort for HostRepoPort {
    fn download_repo(
        &self,
        source: &str,
    ) -> Result<gstore_core::ports::RepoMeta, CoreError> {
        self.with_port(|port| port.download_repo(source))
    }

    fn get_app_count(&self, source: &str) -> Result<u64, CoreError> {
        self.with_port(|port| port.get_app_count(source))
    }

    fn search_apps(
        &self,
        source: &str,
        query: &str,
        limit: usize,
    ) -> Result<Vec<gstore_core::ports::RepoApp>, CoreError> {
        self.with_port(|port| port.search_apps(source, query, limit))
    }

    fn get_repo_meta(
        &self,
        source: &str,
    ) -> Result<Option<gstore_core::ports::RepoMeta>, CoreError> {
        self.with_port(|port| port.get_repo_meta(source))
    }

    fn clear_apps(&self, source: &str) -> Result<(), CoreError> {
        self.with_port(|port| port.clear_apps(source))
    }

    fn get_one_app(
        &self,
        source: &str,
        package_name: &str,
    ) -> Result<Option<gstore_core::ports::RepoApp>, CoreError> {
        self.with_port(|port| port.get_one_app(source, package_name))
    }

    fn db_path(&self) -> &Path {
        &self.db_path
    }
}

struct ChannelApiInner {
    db: DbHandle,
    registry: Arc<ChannelRegistry<SqliteChannelStore>>,
    pack: PackStore,
    secrets: FileSecretStore,
    config: CoreConfig,
    http: Arc<dyn HttpPort>,
    metadata: Arc<dyn MetadataPort>,
    repo: Arc<dyn RepoPort>,
}

/// FRB-facing channel facade. The old Dart `ChannelManager` remains
/// authoritative while `CoreFlags.channels == false`; this API is opt-in.
#[frb(opaque)]
pub struct ChannelApi {
    inner: Arc<ChannelApiInner>,
}

fn default_meta(key: &str) -> Option<ChannelMeta> {
    let meta = |kind, name: &str, description: &str, priority, support_offline| ChannelMeta {
        kind,
        name: name.to_string(),
        description: description.to_string(),
        enabled: true,
        priority,
        support_offline,
        last_update_time: None,
        version: None,
    };
    match key {
        "local_db" => Some(meta(
            ChannelKind::LocalDb,
            "LocalDB",
            "本地数据库渠道",
            1,
            true,
        )),
        "github" => Some(meta(ChannelKind::Github, "GitHubAPI", "GitHub API 渠道", 2, false)),
        "vivo" => Some(meta(ChannelKind::Vivo, "vivo", "vivo 应用市场", 4, false)),
        "fdroid" => Some(meta(
            ChannelKind::Fdroid,
            "F-Droid",
            "F-Droid 开源应用市场",
            5,
            false,
        )),
        _ => None,
    }
}

impl ChannelApi {
    /// Initializes the facade with the same directory shape as `CoreApi`.
    ///
    /// Safe to call more than once against the same directories: registry rows
    /// and drivers are re-registered idempotently. No feature flag is armed.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<ChannelApi, String> {
        let http: Arc<dyn HttpPort> = Arc::new(crate::http_port::ReqwestHttpPort::new());
        let metadata: Arc<dyn MetadataPort> =
            Arc::new(CachedMetadataPort::new(HttpMetadataPort::new(http.clone())));
        let repo: Arc<dyn RepoPort> = Arc::new(HostRepoPort::new(&data_dir));
        Self::init_inner(data_dir, files_dir, cache_dir, http, metadata, repo)
    }

    #[cfg(test)]
    pub(crate) fn init_with_ports(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
        http: Arc<dyn HttpPort>,
        metadata: Arc<dyn MetadataPort>,
        repo: Arc<dyn RepoPort>,
    ) -> Result<ChannelApi, String> {
        Self::init_inner(data_dir, files_dir, cache_dir, http, metadata, repo)
    }

    fn init_inner(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
        http: Arc<dyn HttpPort>,
        metadata: Arc<dyn MetadataPort>,
        repo: Arc<dyn RepoPort>,
    ) -> Result<ChannelApi, String> {
        for dir in [&data_dir, &files_dir, &cache_dir] {
            std::fs::create_dir_all(dir)
                .map_err(|error| format!("io: create dir {dir}: {error}"))?;
        }
        let data_path = Path::new(&data_dir);
        let files_path = Path::new(&files_dir);
        let db = DbHandle::open(data_path).map_err(|error| core_err(CoreError::Io(error.0)))?;
        let secrets = FileSecretStore::new(files_path.join("secrets"));
        let token = secrets
            .get("core_config.github_token")
            .map_err(core_err)?;
        let config = CoreConfig::new(None, token).map_err(core_err)?;
        let registry = Arc::new(ChannelRegistry::new(SqliteChannelStore::new(db.clone())));
        let pack = PackStore::new(files_path.join("channel_packs"), db.clone());
        let api = ChannelApi {
            inner: Arc::new(ChannelApiInner {
                db,
                registry,
                pack,
                secrets,
                config,
                http,
                metadata,
                repo,
            }),
        };
        api.seed_builtin_records()?;
        api.bind_registry_drivers()?;
        Ok(api)
    }

    fn seed_builtin_records(&self) -> Result<(), String> {
        for key in ["local_db", "github", "vivo", "fdroid"] {
            let channel_key = ChannelKey::new(key).map_err(core_err)?;
            if self
                .inner
                .registry
                .get(&channel_key)
                .map_err(core_err)?
                .is_none()
            {
                let meta = default_meta(key).expect("built-in metadata");
                self.inner
                    .registry
                    .register(gstore_core::channel::ChannelRecord::new(channel_key, meta))
                    .map_err(core_err)?;
            }
        }
        Ok(())
    }

    fn driver_for(
        &self,
        record: &gstore_core::channel::ChannelRecord,
    ) -> Result<Option<Arc<dyn ChannelDriver>>, String> {
        let key = record.key.clone();
        let meta = record.meta.clone();
        let driver: Option<Arc<dyn ChannelDriver>> = match record.kind() {
            ChannelKind::LocalDb => Some(Arc::new(
                LocalDbDriver::new(key, meta.clone(), self.inner.db.clone())
                    .with_metadata(self.inner.metadata.clone()),
            )),
            ChannelKind::Github => Some(Arc::new(GitHubDriver::new(
                key,
                meta,
                self.inner.db.clone(),
                self.inner.config.clone(),
                self.inner.http.clone(),
                self.inner.metadata.clone(),
            ))),
            ChannelKind::Vivo => Some(Arc::new(VivoDriver::new(
                key,
                meta,
                self.inner.db.clone(),
                self.inner.config.clone(),
                self.inner.http.clone(),
            ))),
            ChannelKind::Fdroid => Some(Arc::new(FdroidDriver::new(
                key,
                meta,
                self.inner.db.clone(),
                self.inner.config.clone(),
                self.inner.repo.clone(),
            ))),
            ChannelKind::Http | ChannelKind::Custom | ChannelKind::JsLocal => None,
        };
        Ok(driver)
    }

    fn bind_registry_drivers(&self) -> Result<(), String> {
        for record in self.inner.registry.list().map_err(core_err)? {
            if let Some(driver) = self.driver_for(&record)? {
                self.inner
                    .registry
                    .register_driver(driver)
                    .map_err(core_err)?;
            }
        }
        Ok(())
    }

    fn channel_key(&self, key: &str) -> Result<ChannelKey, String> {
        ChannelKey::new(key).map_err(core_err)
    }

    /// Builds the code-to-driver resolver used by the update service.
    ///
    /// The closure keeps the whole `ChannelApiInner` alive, so a facade that
    /// only needs the resolver may drop its own [`ChannelApi`] handle.
    pub(crate) fn resolver(&self) -> gstore_core::update::service::ChannelResolver {
        let inner = Arc::clone(&self.inner);
        Arc::new(move |code: &str| {
            let key = ChannelKey::new(code).ok()?;
            inner.registry.driver(&key).ok()
        })
    }

    fn require_channel(&self, key: &str) -> Result<ChannelKey, String> {
        let key = self.channel_key(key)?;
        if self
            .inner
            .registry
            .get(&key)
            .map_err(core_err)?
            .is_none()
        {
            return Err(core_err(CoreError::NotFound(format!(
                "channel not registered: {key}"
            ))));
        }
        Ok(key)
    }

    fn record(&self, key: &str) -> Result<ChannelEntry, String> {
        let key = self.require_channel(key)?;
        self.inner
            .registry
            .get(&key)
            .map_err(core_err)?
            .map(ChannelEntry::from)
            .ok_or_else(|| {
                core_err(CoreError::NotFound(format!(
                    "channel not registered: {key}"
                )))
            })
    }

    fn driver(&self, key: &str) -> Result<Arc<dyn ChannelDriver>, String> {
        let key = self.require_channel(key)?;
        self.inner.registry.driver(&key).map_err(core_err)
    }

    /// Lists every registered channel in deterministic key order.
    pub fn list(&self) -> Result<Vec<ChannelEntry>, String> {
        self.inner
            .registry
            .list()
            .map_err(core_err)
            .map(|records| records.into_iter().map(ChannelEntry::from).collect())
    }

    /// Reads one registered channel.
    pub fn get(&self, key: String) -> Result<ChannelEntry, String> {
        self.record(&key)
    }

    /// Registers (or idempotently re-registers) a channel and binds a real
    /// built-in driver when the kind maps to one.
    pub fn register(&self, registration: ChannelRegistration) -> Result<ChannelEntry, String> {
        let key = ChannelKey::new(registration.key.clone()).map_err(core_err)?;
        validate_channel_key(&key).map_err(core_err)?;
        let kind = ChannelKind::from_code(&registration.kind).map_err(core_err)?;
        let meta = ChannelMeta {
            kind,
            name: registration.name,
            description: registration.description,
            enabled: registration.enabled,
            priority: registration.priority,
            support_offline: registration.support_offline,
            last_update_time: None,
            version: registration.version,
        };
        let record = gstore_core::channel::ChannelRecord::new(key.clone(), meta.clone());
        match kind {
            ChannelKind::LocalDb
            | ChannelKind::Github
            | ChannelKind::Vivo
            | ChannelKind::Fdroid => {
                let driver = self
                    .driver_for(&record)?
                    .expect("built-in kind has a driver");
                self.inner
                    .registry
                    .register_driver(driver)
                    .map_err(core_err)?;
            }
            ChannelKind::Http | ChannelKind::Custom | ChannelKind::JsLocal => {
                self.inner.registry.register(record).map_err(core_err)?;
            }
        }
        self.record(key.as_str())
    }

    /// Removes a channel registration and its driver binding.
    pub fn unregister(&self, key: String) -> Result<(), String> {
        let key = self.require_channel(&key)?;
        self.inner.registry.unregister(&key).map_err(core_err)
    }

    /// Enables a registered channel.
    pub fn enable(&self, key: String) -> Result<ChannelEntry, String> {
        let key = self.require_channel(&key)?;
        self.inner.registry.enable(&key).map_err(core_err)?;
        self.record(key.as_str())
    }

    /// Disables a registered channel without removing it.
    pub fn disable(&self, key: String) -> Result<ChannelEntry, String> {
        let key = self.require_channel(&key)?;
        self.inner.registry.disable(&key).map_err(core_err)?;
        self.record(key.as_str())
    }

    /// Imports a legacy flat pack from `zip_path`.
    pub fn import_pack(&self, path: String) -> Result<ChannelPackInfo, String> {
        if path.trim().is_empty() {
            return Err(invalid_arg("pack path must not be empty"));
        }
        self.inner
            .pack
            .import_pack(&path)
            .map(ChannelPackInfo::from)
            .map_err(pack_err)
    }

    /// Exports an installed pack as a flat zip at `path`; returns bytes written.
    pub fn export_pack(&self, key: String, path: String) -> Result<u64, String> {
        if path.trim().is_empty() {
            return Err(invalid_arg("export path must not be empty"));
        }
        let key = self.channel_key(&key)?;
        self.inner.pack.export_pack(&key, &path).map_err(pack_err)
    }

    /// Removes an installed pack (row plus version directories).
    pub fn remove_pack(&self, key: String) -> Result<bool, String> {
        let key = self.channel_key(&key)?;
        self.inner
            .pack
            .remove_pack(&key)
            .map(|()| true)
            .map_err(pack_err)
    }

    fn secret_key(&self, key: &ChannelKey, name: &str) -> String {
        format!("channel.{}.{}", key.as_str(), name)
    }

    fn read_plain_env(&self, key: &ChannelKey) -> Result<serde_json::Map<String, serde_json::Value>, String> {
        let conn = self.inner.db.reader().map_err(|error| core_err(CoreError::Io(error.0)))?;
        let raw: Option<String> = rusqlite::OptionalExtension::optional(
            conn.query_row(
                "SELECT env_json FROM channel_env WHERE channel_key=?1",
                [key.as_str()],
                |row| row.get(0),
            ),
        )
        .map_err(|error| core_err(CoreError::Io(error.to_string())))?;
        match raw {
            None => Ok(serde_json::Map::new()),
            Some(raw) if raw.trim().is_empty() => Ok(serde_json::Map::new()),
            Some(raw) => {
                let value: serde_json::Value = serde_json::from_str(&raw).map_err(|error| {
                    core_err(CoreError::Serialization(format!(
                        "channel env is not valid JSON: {error}"
                    )))
                })?;
                value.as_object().cloned().ok_or_else(|| {
                    core_err(CoreError::Serialization(
                        "channel env must be a JSON object".to_string(),
                    ))
                })
            }
        }
    }

    fn write_plain_env(
        &self,
        key: &ChannelKey,
        env: &serde_json::Map<String, serde_json::Value>,
    ) -> Result<(), String> {
        let json = serde_json::Value::Object(env.clone()).to_string();
        self.inner
            .db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT INTO channel_env(channel_key, env_json, imported_at) \
                     VALUES (?1, ?2, strftime('%s','now')) \
                     ON CONFLICT(channel_key) DO UPDATE SET \
                         env_json = excluded.env_json, imported_at = excluded.imported_at",
                    rusqlite::params![key.as_str(), json],
                )
                .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
                Ok(())
            })
            .map_err(|error| core_err(CoreError::Io(error.0)))
    }

    fn validate_env_name(&self, name: &str) -> Result<(), String> {
        if name.trim().is_empty() {
            return Err(invalid_arg("env name must not be empty"));
        }
        validate_secret_key(name).map_err(core_err)
    }

    /// Reads one env value. Sensitive names come from the secret port; other
    /// names come from the plaintext `channel_env` row.
    pub fn env_get(&self, key: String, name: String) -> Result<Option<String>, String> {
        let key = self.require_channel(&key)?;
        self.validate_env_name(&name)?;
        if is_sensitive_key(&name) {
            let secret = self
                .inner
                .secrets
                .get(&self.secret_key(&key, &name))
                .map_err(core_err)?;
            if secret.is_some() {
                return Ok(secret);
            }
        }
        let env = self.read_plain_env(&key)?;
        Ok(env.get(&name).and_then(|value| match value {
            serde_json::Value::String(text) => Some(text.clone()),
            serde_json::Value::Null => None,
            other => Some(other.to_string()),
        }))
    }

    /// Writes one env value, routing sensitive names to the secret port.
    pub fn env_set(&self, key: String, name: String, value: String) -> Result<(), String> {
        let key = self.require_channel(&key)?;
        self.validate_env_name(&name)?;
        let mut env = self.read_plain_env(&key)?;
        if is_sensitive_key(&name) {
            env.remove(&name);
            self.write_plain_env(&key, &env)?;
            self.inner
                .secrets
                .set(&self.secret_key(&key, &name), &value)
                .map_err(core_err)?;
        } else {
            env.insert(name.clone(), serde_json::Value::String(value));
            self.write_plain_env(&key, &env)?;
            self.inner
                .secrets
                .remove(&self.secret_key(&key, &name))
                .map_err(core_err)?;
        }
        Ok(())
    }

    /// Removes one env value from both the plaintext row and the secret port.
    pub fn env_remove(&self, key: String, name: String) -> Result<bool, String> {
        let key = self.require_channel(&key)?;
        self.validate_env_name(&name)?;
        let mut env = self.read_plain_env(&key)?;
        let plain_removed = env.remove(&name).is_some();
        if plain_removed {
            self.write_plain_env(&key, &env)?;
        }
        let secret_removed = self
            .inner
            .secrets
            .remove(&self.secret_key(&key, &name))
            .map_err(core_err)?;
        Ok(plain_removed || secret_removed)
    }

    /// Runs the channel's update loop (`do_update`).
    pub fn refresh(&self, key: String) -> Result<bool, String> {
        self.driver(&key)?
            .do_update(None)
            .map_err(core_err)
    }

    /// Searches one channel by keyword.
    pub fn search(
        &self,
        key: String,
        keyword: String,
        force_refresh: bool,
    ) -> Result<Vec<ChannelAppInfo>, String> {
        self.driver(&key)?
            .search_apps(&keyword, force_refresh)
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(ChannelAppInfo::from_summary).collect())
    }

    /// Reads one app summary.
    pub fn get_app_info(
        &self,
        key: String,
        app_id: String,
        force_refresh: bool,
    ) -> Result<ChannelAppInfo, String> {
        self.driver(&key)?
            .get_app_info(&app_id, force_refresh)
            .map_err(core_err)
            .map(ChannelAppInfo::from_summary)
    }

    /// Reads one app detail page.
    pub fn get_app_detail(
        &self,
        key: String,
        app_id: String,
        force_refresh: bool,
    ) -> Result<ChannelAppDetailInfo, String> {
        self.driver(&key)?
            .get_app_detail(&app_id, force_refresh)
            .map_err(core_err)
            .map(ChannelAppDetailInfo::from)
    }

    /// Adds/saves an app through the channel driver.
    pub fn add_app(&self, key: String, app: ChannelAppInfo) -> Result<(), String> {
        let app = app.into_summary()?;
        self.driver(&key)?.add_app(&app).map_err(core_err)
    }

    /// Removes an app from the channel.
    pub fn remove_app(&self, key: String, app_id: String) -> Result<(), String> {
        self.driver(&key)?
            .remove_app(&app_id)
            .map_err(core_err)
    }

    /// Searches one channel by category id.
    pub fn search_by_category(
        &self,
        key: String,
        category_id: String,
        force_refresh: bool,
    ) -> Result<Vec<ChannelAppInfo>, String> {
        self.driver(&key)?
            .search_by_category(&category_id, force_refresh)
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(ChannelAppInfo::from_summary).collect())
    }

    /// Lists the channel's categories.
    pub fn get_all_categories(
        &self,
        key: String,
        force_refresh: bool,
    ) -> Result<Vec<ChannelCategoryInfo>, String> {
        self.driver(&key)?
            .get_all_categories(force_refresh)
            .map_err(core_err)
            .map(|categories| categories.into_iter().map(ChannelCategoryInfo::from).collect())
    }

    /// Returns the driver's canonical app id.
    pub fn canonical_app_id(
        &self,
        key: String,
        app: ChannelAppInfo,
    ) -> Result<String, String> {
        let app = app.into_summary()?;
        self.driver(&key)?
            .canonical_app_id(&app)
            .map_err(core_err)
    }

    /// Reads the channel configuration row.
    pub fn get_config(
        &self,
        key: String,
        force_refresh: bool,
    ) -> Result<Option<ChannelConfigInfo>, String> {
        self.driver(&key)?
            .get_config(force_refresh)
            .map_err(core_err)
            .map(|config| {
                config.map(|config| ChannelConfigInfo {
                    version: config.version,
                    proxy: config.proxy,
                })
            })
    }
}


// ===========================================================================
// CatalogApi / AddedAppsApi / UpdateApi (Wave 2 Todo 10)
// ===========================================================================

use gstore_core::added::apps::{AddedApp, AddedAppsService};
use gstore_core::catalog::refresh::{catalog_changed_event, refresh_catalog};
use gstore_core::catalog::service::CatalogService;
use gstore_core::ports::PlatformHost;
use gstore_core::update::service::{UpdateCheckReport, UpdateService};

fn open_core_db(data_dir: &str) -> Result<DbHandle, String> {
    std::fs::create_dir_all(data_dir)
        .map_err(|error| format!("io: create dir {data_dir}: {error}"))?;
    DbHandle::open(Path::new(data_dir)).map_err(|error| core_err(CoreError::Io(error.0)))
}

fn prepare_dirs(data_dir: &str, files_dir: &str, cache_dir: &str) -> Result<(), String> {
    for dir in [data_dir, files_dir, cache_dir] {
        std::fs::create_dir_all(dir).map_err(|error| format!("io: create dir {dir}: {error}"))?;
    }
    Ok(())
}

/// One page of the local catalog plus the unpaged total.
#[derive(Debug, Clone)]
pub struct CatalogPage {
    pub apps: Vec<ChannelAppInfo>,
    pub total: i64,
}

/// Result of a remote catalog refresh.
#[derive(Debug, Clone)]
pub struct CatalogRefreshResult {
    pub apps: i64,
    pub categories: i64,
    pub configs: i64,
    pub fts_rows: i64,
    pub changed: bool,
    pub backup: Option<String>,
    /// Serialized `catalog.changed` event when the catalog changed, else `"null"`.
    pub events_json: String,
}

/// Read-only facade over the core local catalog.
#[frb(opaque)]
pub struct CatalogApi {
    db: DbHandle,
    service: CatalogService,
    http: Arc<dyn HttpPort>,
}

impl CatalogApi {
    /// Opens the core database and binds the local catalog service.
    ///
    /// Safe to call more than once against the same directories.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<CatalogApi, String> {
        prepare_dirs(&data_dir, &files_dir, &cache_dir)?;
        let db = open_core_db(&data_dir)?;
        let service = CatalogService::new(db.clone()).map_err(core_err)?;
        let http: Arc<dyn HttpPort> = Arc::new(crate::http_port::ReqwestHttpPort::new());
        Ok(Self { db, service, http })
    }

    /// Lists every imported app in `rowid` order.
    pub fn list(&self) -> Result<Vec<ChannelAppInfo>, String> {
        self.service
            .list()
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(ChannelAppInfo::from_summary).collect())
    }

    /// Returns one page plus the unpaged total.
    pub fn list_page(&self, offset: u32, limit: u32) -> Result<CatalogPage, String> {
        self.service
            .list_page(offset, limit)
            .map_err(core_err)
            .map(|(apps, total)| CatalogPage {
                apps: apps.into_iter().map(ChannelAppInfo::from_summary).collect(),
                total: i64::try_from(total).unwrap_or(i64::MAX),
            })
    }

    /// Searches by keyword (empty keyword yields an empty list).
    pub fn search(&self, keyword: String) -> Result<Vec<ChannelAppInfo>, String> {
        self.service
            .search(&keyword)
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(ChannelAppInfo::from_summary).collect())
    }

    /// Reads one app, or `None` when it is absent.
    pub fn get_app(&self, app_id: String) -> Result<Option<ChannelAppInfo>, String> {
        self.service
            .get_app(&app_id)
            .map_err(core_err)
            .map(|app| app.map(ChannelAppInfo::from_summary))
    }

    /// Lists imported categories in `rowid` order.
    pub fn categories(&self) -> Result<Vec<ChannelCategoryInfo>, String> {
        self.service
            .categories()
            .map_err(core_err)
            .map(|categories| categories.into_iter().map(ChannelCategoryInfo::from).collect())
    }

    /// Lists apps whose category contains `category_id`.
    pub fn by_category(&self, category_id: String) -> Result<Vec<ChannelAppInfo>, String> {
        self.service
            .by_category(&category_id)
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(ChannelAppInfo::from_summary).collect())
    }

    /// Reads one app detail payload, or `None` when it is absent.
    pub fn get_app_detail(
        &self,
        app_id: String,
    ) -> Result<Option<ChannelAppDetailInfo>, String> {
        self.service
            .get_app_detail(&app_id)
            .map_err(core_err)
            .map(|detail| detail.map(ChannelAppDetailInfo::from))
    }

    /// Downloads and atomically replaces the catalog.
    ///
    /// This is the production `catalog.changed` forwarding point: when the
    /// replace changed rows, `events_json` carries the serialized
    /// `CoreEvent::CatalogChanged`; otherwise it is the JSON literal `null`.
    pub fn refresh(&self, url: String) -> Result<CatalogRefreshResult, String> {
        let report = refresh_catalog(&self.db, self.http.as_ref(), &url).map_err(core_err)?;
        let events_json = if report.changed {
            let event = catalog_changed_event().map_err(core_err)?;
            serde_json::to_string(&event)
                .map_err(|error| core_err(CoreError::Serialization(error.to_string())))?
        } else {
            "null".to_string()
        };
        Ok(CatalogRefreshResult {
            apps: i64::try_from(report.apps).unwrap_or(i64::MAX),
            categories: i64::try_from(report.categories).unwrap_or(i64::MAX),
            configs: i64::try_from(report.configs).unwrap_or(i64::MAX),
            fts_rows: i64::try_from(report.fts_rows).unwrap_or(i64::MAX),
            changed: report.changed,
            backup: report.backup,
            events_json,
        })
    }
}

/// One `added_apps` row crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct AddedAppEntry {
    pub id: i64,
    pub channel_id: String,
    pub app_id: String,
    pub add_time: i64,
    pub sort_order: i64,
    pub is_enabled: bool,
}

impl From<AddedApp> for AddedAppEntry {
    fn from(app: AddedApp) -> Self {
        Self {
            id: app.id,
            channel_id: app.channel_id,
            app_id: app.app_id,
            add_time: app.add_time,
            sort_order: app.sort_order,
            is_enabled: app.is_enabled,
        }
    }
}

/// One `"{channel}:{app_id}"` tag bucket.
#[derive(Debug, Clone)]
pub struct TagGroup {
    pub key: String,
    pub tags: Vec<String>,
}

/// Added-apps and user-tag facade over [`AddedAppsService`].
#[frb(opaque)]
pub struct AddedAppsApi {
    service: AddedAppsService,
}

impl AddedAppsApi {
    /// Opens the core database and binds the added-apps service.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<AddedAppsApi, String> {
        prepare_dirs(&data_dir, &files_dir, &cache_dir)?;
        let db = open_core_db(&data_dir)?;
        Ok(Self {
            service: AddedAppsService::new(db),
        })
    }

    /// Adds or refreshes one `(channel, app_id)` row.
    pub fn add(
        &self,
        channel: String,
        app_id: String,
        sort_order: Option<i64>,
    ) -> Result<AddedAppEntry, String> {
        self.service
            .add(&channel, &app_id, sort_order)
            .map_err(core_err)
            .map(AddedAppEntry::from)
    }

    /// Removes one row and all of its tags.
    pub fn remove(&self, channel: String, app_id: String) -> Result<bool, String> {
        self.service.remove(&channel, &app_id).map_err(core_err)
    }

    /// Renames an app id inside one channel.
    pub fn rename(
        &self,
        channel: String,
        old_app_id: String,
        new_app_id: String,
    ) -> Result<bool, String> {
        self.service
            .rename(&channel, &old_app_id, &new_app_id)
            .map_err(core_err)
    }

    /// Sets one row's sort weight.
    pub fn set_order(
        &self,
        channel: String,
        app_id: String,
        sort_order: i64,
    ) -> Result<(), String> {
        self.service
            .set_order(&channel, &app_id, sort_order)
            .map_err(core_err)
    }

    /// Toggles one row and returns the new added state.
    pub fn toggle(&self, channel: String, app_id: String) -> Result<bool, String> {
        self.service.toggle(&channel, &app_id).map_err(core_err)
    }

    /// Deletes every added row in one channel.
    pub fn clear_channel(&self, channel: String) -> Result<u32, String> {
        self.service
            .clear_channel(&channel)
            .map_err(core_err)
            .map(|count| u32::try_from(count).unwrap_or(u32::MAX))
    }

    /// Deletes every added row across all channels.
    pub fn clear_all(&self) -> Result<u32, String> {
        self.service
            .clear_all()
            .map_err(core_err)
            .map(|count| u32::try_from(count).unwrap_or(u32::MAX))
    }

    /// Lists every added app, newest first.
    pub fn list(&self) -> Result<Vec<AddedAppEntry>, String> {
        self.service
            .list()
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(AddedAppEntry::from).collect())
    }

    /// Lists one channel's added apps, newest first.
    pub fn list_channel(&self, channel: String) -> Result<Vec<AddedAppEntry>, String> {
        self.service
            .list_channel(&channel)
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(AddedAppEntry::from).collect())
    }

    /// Returns one row, if present.
    pub fn get(&self, channel: String, app_id: String) -> Result<Option<AddedAppEntry>, String> {
        self.service
            .get(&channel, &app_id)
            .map_err(core_err)
            .map(|app| app.map(AddedAppEntry::from))
    }

    /// Whether `(channel, app_id)` is in `added_apps`.
    pub fn is_added(&self, channel: String, app_id: String) -> Result<bool, String> {
        self.service.is_added(&channel, &app_id).map_err(core_err)
    }

    /// Total number of added apps.
    pub fn total_count(&self) -> Result<i64, String> {
        self.service.total_count().map_err(core_err)
    }

    /// Number of added apps in one channel.
    pub fn count_channel(&self, channel: String) -> Result<i64, String> {
        self.service.count_channel(&channel).map_err(core_err)
    }

    /// Replaces all tags for one app.
    pub fn set_tags(
        &self,
        channel: String,
        app_id: String,
        tags: Vec<String>,
    ) -> Result<(), String> {
        self.service
            .set_tags(&channel, &app_id, &tags)
            .map_err(core_err)
    }

    /// Adds one tag (idempotent, trimmed; empty is a no-op).
    pub fn add_tag(&self, channel: String, app_id: String, tag: String) -> Result<(), String> {
        self.service
            .add_tag(&channel, &app_id, &tag)
            .map_err(core_err)
    }

    /// Removes one tag; absent tags are a no-op.
    pub fn remove_tag(&self, channel: String, app_id: String, tag: String) -> Result<(), String> {
        self.service
            .remove_tag(&channel, &app_id, &tag)
            .map_err(core_err)
    }

    /// Returns one app's tags, earliest first.
    pub fn tags(&self, channel: String, app_id: String) -> Result<Vec<String>, String> {
        self.service.tags(&channel, &app_id).map_err(core_err)
    }

    /// Returns all tag buckets keyed by `"{channel}:{app_id}"`.
    pub fn tags_index(&self) -> Result<Vec<TagGroup>, String> {
        self.service
            .tags_index()
            .map_err(core_err)
            .map(|index| {
                index
                    .into_iter()
                    .map(|(key, tags)| TagGroup { key, tags })
                    .collect()
            })
    }
}

/// Serialized result of one update check.
#[derive(Debug, Clone)]
pub struct UpdateReport {
    pub checked_at: i64,
    pub total: i64,
    pub used_cache: bool,
    /// JSON array of `AppUpdateInfo` (camelCase, no `detail`).
    pub updates_json: String,
    /// JSON array of `UpdateSkip`.
    pub skipped_json: String,
    /// JSON array of `CoreEvent` (`update.found`, ...).
    pub events_json: String,
}

fn encode_update_report(report: UpdateCheckReport) -> Result<UpdateReport, String> {
    let updates_json = serde_json::to_string(&report.updates)
        .map_err(|error| core_err(CoreError::Serialization(error.to_string())))?;
    let skipped_json = serde_json::to_string(&report.skipped)
        .map_err(|error| core_err(CoreError::Serialization(error.to_string())))?;
    let events_json = serde_json::to_string(&report.events)
        .map_err(|error| core_err(CoreError::Serialization(error.to_string())))?;
    Ok(UpdateReport {
        checked_at: report.checked_at,
        total: i64::try_from(report.total).unwrap_or(i64::MAX),
        used_cache: report.used_cache,
        updates_json,
        skipped_json,
        events_json,
    })
}

/// Update check/cache facade over [`UpdateService`].
#[frb(opaque)]
pub struct UpdateApi {
    service: UpdateService,
}

impl UpdateApi {
    /// Opens the core database, binds channel drivers, and wires the Android
    /// platform host.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<UpdateApi, String> {
        prepare_dirs(&data_dir, &files_dir, &cache_dir)?;
        let db = open_core_db(&data_dir)?;
        let channel_api = ChannelApi::init(data_dir, files_dir, cache_dir)?;
        let resolver = channel_api.resolver();
        let platform: Arc<dyn PlatformHost> = Arc::new(
            crate::platform_host::AndroidPlatformHost::new(),
        );
        Ok(Self {
            service: UpdateService::new(db, resolver, platform),
        })
    }

    /// Wraps an already-built service (integration tests only).
    #[frb(ignore)]
    #[doc(hidden)]
    pub fn from_service_for_test(service: UpdateService) -> UpdateApi {
        Self { service }
    }

    /// Checks every added app, honoring the one-hour cache unless `force`.
    pub fn check(&self, force: bool) -> Result<UpdateReport, String> {
        let report = self.service.check_all(force).map_err(core_err)?;
        encode_update_report(report)
    }

    /// Forces a full update check.
    pub fn run(&self) -> Result<UpdateReport, String> {
        let report = self.service.run().map_err(core_err)?;
        encode_update_report(report)
    }

    /// Checks one app, preferring the cache; returns serialized
    /// `AppUpdateInfo` or `None`.
    pub fn check_app(
        &self,
        app_id: String,
        channel_code: Option<String>,
    ) -> Result<Option<String>, String> {
        let update = self
            .service
            .check_app(&app_id, channel_code.as_deref())
            .map_err(core_err)?;
        update
            .map(|info| {
                serde_json::to_string(&info)
                    .map_err(|error| core_err(CoreError::Serialization(error.to_string())))
            })
            .transpose()
    }

    /// Returns the cached updatable apps as a JSON array.
    pub fn list(&self) -> Result<String, String> {
        let updates = self.service.list().map_err(core_err)?;
        serde_json::to_string(&updates)
            .map_err(|error| core_err(CoreError::Serialization(error.to_string())))
    }

    /// Drops `app_id` from the cache once the installed version caught up.
    pub fn mark_updated(&self, app_id: String) -> Result<bool, String> {
        self.service.mark_updated(&app_id).map_err(core_err)
    }

    /// Whether the cache contains `app_id`.
    pub fn has_update(&self, app_id: String) -> Result<bool, String> {
        self.service.has_update(&app_id).map_err(core_err)
    }

    /// Number of cached updatable apps.
    pub fn count(&self) -> Result<i64, String> {
        self.service
            .count()
            .map_err(core_err)
            .map(|count| i64::try_from(count).unwrap_or(i64::MAX))
    }

    /// Whether the cached results are still inside the one-hour window.
    pub fn cache_valid(&self) -> Result<bool, String> {
        self.service.is_cache_valid().map_err(core_err)
    }
}

#[cfg(test)]
mod channel_api_tests {
    use super::*;
    use gstore_core::ports::fake::{FakeHttpPort, FakeMetadataPort, FakeRepoPort};
    use gstore_core::ports::{HttpPort, MetadataPort, PackageMetadata, RepoPort};
    use std::io::Write as _;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::time::Instant;

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "gstore_channel_api_{tag}_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    struct Harness {
        root: PathBuf,
        api: ChannelApi,
        http: FakeHttpPort,
        metadata: FakeMetadataPort,
        repo: FakeRepoPort,
    }

    fn harness(tag: &str) -> Harness {
        let root = temp_root(tag);
        let http = FakeHttpPort::new();
        let metadata = FakeMetadataPort::new();
        metadata.set(
            "owner",
            "repo",
            Some(PackageMetadata {
                package_name: Some("com.example.owner".to_string()),
                app_name: Some("Owner App".to_string()),
                icon_url: Some("https://example.test/icon.png".to_string()),
            }),
        );
        let repo = FakeRepoPort::new(root.join("repo.db"));
        let api = ChannelApi::init_with_ports(
            root.join("data").to_string_lossy().into_owned(),
            root.join("files").to_string_lossy().into_owned(),
            root.join("cache").to_string_lossy().into_owned(),
            Arc::new(http.clone()) as Arc<dyn HttpPort>,
            Arc::new(metadata.clone()) as Arc<dyn MetadataPort>,
            Arc::new(repo.clone()) as Arc<dyn RepoPort>,
        )
        .expect("ChannelApi::init_with_ports");
        Harness {
            root,
            api,
            http,
            metadata,
            repo,
        }
    }

    fn seed_localdb(api: &ChannelApi) {
        api.inner
            .db
            .with_writer(|conn| {
                conn.execute_batch(
                    "INSERT INTO apps(appId,name,user,repositories,icon,des,readme,category,extra) \
                     VALUES('com.example.alpha','Alpha Browser','','','','Fast alpha','readme','Tools', \
                            '{\"packageName\":\"com.example.alpha\"}'); \
                     INSERT INTO categories(id,description,icon) VALUES('Tools','工具','tool.png'); \
                     INSERT INTO app_config(version,proxy) VALUES('2026.1',NULL);",
                )
                .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
                Ok(())
            })
            .expect("seed localdb");
    }

    fn write_pack(path: &Path) {
        let file = std::fs::File::create(path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        writer.start_file("entry.js", options).unwrap();
        writer.write_all(b"module.exports = function () { return {}; };").unwrap();
        writer.finish().unwrap();
    }

    fn app_input() -> ChannelAppInfo {
        ChannelAppInfo {
            app_id: "owner/repo".to_string(),
            package_name: None,
            name: "Owner Repo".to_string(),
            user: "owner".to_string(),
            repositories: "repo".to_string(),
            icon: String::new(),
            des: "description".to_string(),
            readme: None,
            category: vec!["Tools".to_string()],
            extra_json: None,
        }
    }

    #[test]
    fn channel_api_contract() {
        let started = Instant::now();
        let harness = harness("contract");
        let api = &harness.api;

        // Init is idempotent and does not arm any flag.
        gstore_core::flags::reset_flags();
        let before_flags = gstore_core::flags::flags();
        let second = ChannelApi::init_with_ports(
            harness.root.join("data").to_string_lossy().into_owned(),
            harness.root.join("files").to_string_lossy().into_owned(),
            harness.root.join("cache").to_string_lossy().into_owned(),
            Arc::new(harness.http.clone()) as Arc<dyn HttpPort>,
            Arc::new(harness.metadata.clone()) as Arc<dyn MetadataPort>,
            Arc::new(harness.repo.clone()) as Arc<dyn RepoPort>,
        )
        .expect("second init");
        assert_eq!(second.list().unwrap().len(), 4);
        assert_eq!(gstore_core::flags::flags(), before_flags);
        assert!(!gstore_core::flags::flags().channels);

        seed_localdb(api);

        // list/get
        let entries = api.list().expect("list");
        assert_eq!(entries.len(), 4, "built-in channels: {entries:?}");
        assert!(entries.iter().any(|entry| entry.key == "local_db"));
        assert!(entries.iter().any(|entry| entry.key == "github"));
        assert!(entries.iter().any(|entry| entry.key == "vivo"));
        assert!(entries.iter().any(|entry| entry.key == "fdroid"));
        let local = api.get("local_db".to_string()).expect("get local_db");
        assert_eq!(local.kind, "local_db");
        assert!(local.support_offline);

        // register / re-register idempotence
        let registration = ChannelRegistration {
            key: "js_contract".to_string(),
            kind: "custom".to_string(),
            name: "Contract".to_string(),
            description: "contract channel".to_string(),
            enabled: true,
            priority: 9,
            support_offline: false,
            version: Some("1".to_string()),
        };
        let registered = api.register(registration.clone()).expect("register");
        assert_eq!(registered.key, "js_contract");
        let registered_again = api.register(registration).expect("re-register");
        assert_eq!(registered_again.priority, 9);
        assert_eq!(api.list().unwrap().len(), 5);

        // enable / disable
        let disabled = api.disable("js_contract".to_string()).expect("disable");
        assert!(!disabled.enabled);
        let enabled = api.enable("js_contract".to_string()).expect("enable");
        assert!(enabled.enabled);

        // env: plaintext stays out of the channel_env row, secrets use the port.
        api.env_set(
            "local_db".to_string(),
            "USER".to_string(),
            "alice".to_string(),
        )
        .expect("env_set USER");
        assert_eq!(
            api.env_get("local_db".to_string(), "USER".to_string())
                .expect("env_get USER"),
            Some("alice".to_string())
        );
        api.env_set(
            "local_db".to_string(),
            "PASSWORD".to_string(),
            "p@ss".to_string(),
        )
        .expect("env_set PASSWORD");
        let env_row: String = api
            .inner
            .db
            .with_reader(|conn| {
                conn.query_row(
                    "SELECT env_json FROM channel_env WHERE channel_key='local_db'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
            })
            .expect("read env row");
        println!("channel_api_contract: plaintext env row = {env_row}");
        assert!(!env_row.contains("p@ss"));
        assert!(!env_row.contains("PASSWORD"));
        let secret = std::fs::read_to_string(harness.root.join("files/secrets/channel.local_db.PASSWORD"))
            .expect("secret file");
        assert_eq!(secret, "p@ss");
        assert_eq!(
            api.env_get("local_db".to_string(), "PASSWORD".to_string())
                .expect("env_get PASSWORD"),
            Some("p@ss".to_string())
        );
        assert!(api
            .env_remove("local_db".to_string(), "USER".to_string())
            .expect("env_remove USER"));
        assert!(!api
            .env_remove("local_db".to_string(), "USER".to_string())
            .expect("env_remove USER twice"));
        assert_eq!(
            api.env_get("local_db".to_string(), "USER".to_string())
                .expect("env_get removed"),
            None
        );

        // search / info / detail / categories / config / canonical id
        let hits = api
            .search("local_db".to_string(), "Alpha".to_string(), false)
            .expect("search");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].app_id, "com.example.alpha");
        assert_eq!(hits[0].package_name.as_deref(), Some("com.example.alpha"));
        let info = api
            .get_app_info(
                "local_db".to_string(),
                "com.example.alpha".to_string(),
                false,
            )
            .expect("get_app_info");
        assert_eq!(info.name, "Alpha Browser");
        let detail = api
            .get_app_detail(
                "local_db".to_string(),
                "com.example.alpha".to_string(),
                false,
            )
            .expect("get_app_detail");
        assert_eq!(detail.app_id, "com.example.alpha");
        let missing_app = api
            .get_app_info("local_db".to_string(), "missing.app".to_string(), false)
            .expect_err("missing app must be typed");
        println!("channel_api_contract: missing app error = {missing_app}");
        assert!(missing_app.starts_with("not_found:"), "{missing_app}");
        let missing_detail = api
            .get_app_detail("local_db".to_string(), "missing.app".to_string(), false)
            .expect_err("missing detail app must be typed");
        assert!(missing_detail.starts_with("not_found:"), "{missing_detail}");
        let no_driver_config = api
            .get_config("js_contract".to_string(), false)
            .expect_err("registered channel without a driver must be typed");
        println!("channel_api_contract: no-driver config error = {no_driver_config}");
        assert!(no_driver_config.starts_with("not_found:"), "{no_driver_config}");
        assert_eq!(
            api.search_by_category(
                "local_db".to_string(),
                "Tools".to_string(),
                false
            )
            .expect("search_by_category")
            .len(),
            1
        );
        let categories = api
            .get_all_categories("local_db".to_string(), false)
            .expect("get_all_categories");
        assert_eq!(categories.len(), 1);
        assert_eq!(categories[0].id, "Tools");
        let config = api
            .get_config("local_db".to_string(), false)
            .expect("get_config")
            .expect("localdb config");
        assert_eq!(config.version, "2026.1");
        assert_eq!(
            api.canonical_app_id("local_db".to_string(), app_input())
                .expect("canonical_app_id"),
            "owner/repo"
        );

        // add/remove on the GitHub driver (metadata is injected, no network).
        api.add_app("github".to_string(), app_input())
            .expect("add_app");
        let stored = api
            .get_app_info("github".to_string(), "owner/repo".to_string(), false)
            .expect("stored github app");
        assert_eq!(stored.package_name.as_deref(), Some("com.example.owner"));
        let github_canonical = api
            .canonical_app_id("github".to_string(), app_input())
            .expect("github canonical");
        assert_eq!(github_canonical, "com.example.owner");
        api.remove_app("github".to_string(), "owner/repo".to_string())
            .expect("remove_app");
        let row_count: i64 = api
            .inner
            .db
            .with_reader(|conn| {
                conn.query_row(
                    "SELECT COUNT(*) FROM channel_apps WHERE channel_key='github' AND app_id='owner/repo'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
            })
            .expect("count channel_apps");
        assert_eq!(row_count, 0);
        assert!(harness.http.calls().is_empty(), "contract test must not touch the network");

        // refresh calls the driver update (GitHub is live data).
        assert!(api.refresh("github".to_string()).expect("refresh"));

        // packs: import twice is idempotent, export round-trips, remove is typed.
        let pack = harness.root.join("alpha.zip");
        write_pack(&pack);
        let first = api
            .import_pack(pack.to_string_lossy().into_owned())
            .expect("import_pack");
        assert_eq!(first.key, "js_alpha");
        assert_eq!(first.pack_hash.len(), 64);
        let second_pack = api
            .import_pack(pack.to_string_lossy().into_owned())
            .expect("import_pack twice");
        assert_eq!(second_pack.pack_hash, first.pack_hash);
        let pack_rows: i64 = api
            .inner
            .db
            .with_reader(|conn| {
                conn.query_row(
                    "SELECT COUNT(*) FROM channel_packs WHERE key='js_alpha'",
                    [],
                    |row| row.get(0),
                )
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
            })
            .expect("count packs");
        assert_eq!(pack_rows, 1);
        let exported = harness.root.join("alpha-export.zip");
        let bytes = api
            .export_pack(
                "js_alpha".to_string(),
                exported.to_string_lossy().into_owned(),
            )
            .expect("export_pack");
        assert!(bytes > 0);
        assert!(exported.is_file());
        assert!(api.remove_pack("js_alpha".to_string()).expect("remove_pack"));
        let err = api
            .remove_pack("js_alpha".to_string())
            .expect_err("second remove must fail");
        println!("channel_api_contract: second remove error = {err}");
        assert!(err.starts_with("pack_not_found:"), "{err}");
        let err = api
            .export_pack(
                "js_alpha".to_string(),
                harness.root.join("missing.zip").to_string_lossy().into_owned(),
            )
            .expect_err("export removed pack must fail");
        println!("channel_api_contract: export removed pack error = {err}");
        assert!(err.starts_with("pack_not_found:"), "{err}");

        // Successful unregister removes both row and driver binding.
        api.unregister("js_contract".to_string())
            .expect("unregister js_contract");
        let unregistered = api.get("js_contract".to_string()).unwrap_err();
        assert!(unregistered.starts_with("not_found:"), "{unregistered}");

        // Missing channel -> typed not found (never null / panic).
        for err in [
            api.get("missing".to_string()).unwrap_err(),
            api.search("missing".to_string(), "x".to_string(), false).unwrap_err(),
            api.get_app_info("missing".to_string(), "x".to_string(), false).unwrap_err(),
            api.get_app_detail("missing".to_string(), "x".to_string(), false).unwrap_err(),
            api.refresh("missing".to_string()).unwrap_err(),
            api.env_get("missing".to_string(), "USER".to_string()).unwrap_err(),
            api.get_config("missing".to_string(), false).unwrap_err(),
            api.enable("missing".to_string()).unwrap_err(),
            api.disable("missing".to_string()).unwrap_err(),
            api.unregister("missing".to_string()).unwrap_err(),
        ] {
            println!("channel_api_contract: missing channel error = {err}");
            assert!(err.starts_with("not_found:"), "expected not_found, got {err}");
        }

        // Malformed input is typed, not a panic.
        assert!(api
            .get(String::new())
            .unwrap_err()
            .starts_with("invalid_argument:"));
        let bad_kind = ChannelRegistration {
            key: "js_bad_kind".to_string(),
            kind: "not_a_kind".to_string(),
            name: "Bad".to_string(),
            description: String::new(),
            enabled: true,
            priority: 0,
            support_offline: false,
            version: None,
        };
        assert!(api
            .register(bad_kind)
            .unwrap_err()
            .starts_with("invalid_argument:"));
        assert!(api
            .env_set(
                "local_db".to_string(),
                String::new(),
                "x".to_string()
            )
            .unwrap_err()
            .starts_with("invalid_argument:"));
        let missing_pack = harness.root.join("nope.zip");
        let pack_err = api
            .import_pack(missing_pack.to_string_lossy().into_owned())
            .unwrap_err();
        println!("channel_api_contract: missing pack error = {pack_err}");
        assert!(!pack_err.is_empty());
        let mut bad_app = app_input();
        bad_app.extra_json = Some("not json".to_string());
        let bad_extra = api
            .add_app("github".to_string(), bad_app)
            .unwrap_err();
        println!("channel_api_contract: bad extra error = {bad_extra}");
        assert!(bad_extra.starts_with("serialization:"), "{bad_extra}");

        // The test never touched the network and never armed core_writes.
        assert!(harness.http.calls().is_empty());
        assert!(api
            .inner
            .db
            .with_reader(|conn| {
                conn.query_row("SELECT COUNT(*) FROM core_writes", [], |row| row.get::<_, i64>(0))
                    .map_err(|error| gstore_core::db::DbError(error.to_string()))
            })
            .expect("core_writes count")
            == 0);

        println!(
            "channel_api_contract: PASS duration_ms={}",
            started.elapsed().as_millis()
        );
        drop(harness);
    }
}
