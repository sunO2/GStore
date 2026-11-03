// Flutter FFI Bridge - 暴露给 Dart 的接口
use flutter_rust_bridge::frb;

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

/// Configuration DTOs (plain data classes; FRB follows these re-exports).
pub use crate::config_api::{
    ConfigChangeDto, ConfigEntryDto, ConfigExportDto, ConfigExportEntryDto,
    ConfigImportEntryDto, ConfigImportFailureDto, ConfigImportReportDto, ConfigMigrationStateDto,
    ConfigOpResultDto, ConfigSnapshotDto, ConfigVerifyEntryDto, ConfigVerifyReportDto,
    ConfigVerifyResultDto, RecordingConfigSink,
};

/// Module-scoped configuration facade (Todo 8).
///
/// Backed by the process-global `Arc<ConfigStore>` installed by
/// [`CoreApi::finish_init`] from the **same** `SharedConn`/`files_dir` as the
/// rest of the core (C1). It never opens a second `DbHandle`.
///
/// Secret policy (C3): `get(masked = true)`, `list`, `snapshots`, `snapshot`,
/// and every change event are masked. `get(masked = false)` is the explicit
/// trusted-Dart raw read, and [`ConfigApi::export`] is the only raw backup DTO.
#[frb(opaque)]
pub struct ConfigApi;

impl ConfigApi {
    /// Creates the facade; fails with `CORE_E_NOT_INITIALIZED` until
    /// `CoreApi.init()` has installed the process-global store.
    pub fn init() -> Result<ConfigApi, String> {
        crate::config_api::api_init()?;
        Ok(ConfigApi)
    }

    /// Reads one value as JSON. `masked = true` is the default contract;
    /// trusted Dart may pass `masked = false` for the owner's raw value (C3).
    pub fn get(&self, module: String, key: String, masked: bool) -> Result<String, String> {
        crate::config_api::get(module, key, masked)
    }

    /// Validates, commits, and publishes one value.
    pub fn set(
        &self,
        module: String,
        key: String,
        value_json: String,
        source: String,
    ) -> Result<ConfigOpResultDto, String> {
        crate::config_api::set(module, key, value_json, source)
    }

    /// Clears a stored value (reads fall back to the registry default).
    pub fn clear(
        &self,
        module: String,
        key: String,
        source: String,
    ) -> Result<ConfigOpResultDto, String> {
        crate::config_api::clear(module, key, source)
    }

    /// Restores and persists the registry default.
    pub fn reset(
        &self,
        module: String,
        key: String,
        source: String,
    ) -> Result<ConfigOpResultDto, String> {
        crate::config_api::reset(module, key, source)
    }

    /// Registry metadata plus the current (masked) value. `None` = all modules.
    pub fn list(&self, module: Option<String>) -> Result<Vec<ConfigEntryDto>, String> {
        crate::config_api::list(module)
    }

    /// One stored snapshot (masked), or `None` when unset.
    pub fn snapshot(
        &self,
        module: String,
        key: String,
    ) -> Result<Option<ConfigSnapshotDto>, String> {
        crate::config_api::snapshot(module, key)
    }

    /// Stored snapshots, optionally filtered to one module.
    pub fn snapshots(&self, module: Option<String>) -> Result<Vec<ConfigSnapshotDto>, String> {
        crate::config_api::snapshots(module)
    }

    /// Raw export for backups. The only DTO that may contain plaintext secrets.
    pub fn export(&self) -> Result<ConfigExportDto, String> {
        crate::config_api::export()
    }

    /// Idempotent bulk import: validates everything, applies the valid subset
    /// in one transaction, publishes one event per applied key.
    pub fn import(
        &self,
        entries: Vec<ConfigImportEntryDto>,
        source: String,
    ) -> Result<ConfigImportReportDto, String> {
        crate::config_api::import(entries, source)
    }

    /// Re-reads the committed values and compares them with `entries`.
    pub fn verify(
        &self,
        entries: Vec<ConfigVerifyEntryDto>,
    ) -> Result<ConfigVerifyReportDto, String> {
        crate::config_api::verify(entries)
    }

    /// Reads an arbitrary `config_meta` key.
    pub fn meta_get(&self, key: String) -> Result<Option<String>, String> {
        crate::config_api::meta_get(key)
    }

    /// Writes an arbitrary `config_meta` key (`revision` is store-owned).
    pub fn meta_set(&self, key: String, value_json: String) -> Result<(), String> {
        crate::config_api::meta_set(key, value_json)
    }

    /// Hydrates the store cache; reports readiness separately from migration.
    ///
    /// Todo 8 never runs legacy migration, so `migrated` is always `false`.
    pub fn ensure_migrated(&self) -> Result<ConfigMigrationStateDto, String> {
        crate::config_api::ensure_migrated()
    }

    /// Global compatibility stream (all modules). Prefer [`ConfigApi::watch`].
    pub fn config_events_stream(
        &self,
        sink: crate::frb_generated::StreamSink<ConfigChangeDto>,
    ) {
        crate::config_api::events_stream(sink);
    }

    /// Per-subscription filtered stream; `key = None` observes the whole module.
    ///
    /// Two listeners on the same filter both receive (C18); a sink whose send
    /// fails is pruned without affecting the others.
    pub fn watch(
        &self,
        module: String,
        key: Option<String>,
        sink: crate::frb_generated::StreamSink<ConfigChangeDto>,
    ) {
        crate::config_api::watch_stream(module, key, sink);
    }
}

/// Test seam: drops the process-global store/bus/meta handle and all sinks.
#[doc(hidden)]
#[frb(ignore)]
pub fn reset_config_store_for_test() {
    crate::config_api::reset_store_for_test();
}

/// Test seam: registers an in-memory watcher without an FRB runtime.
#[doc(hidden)]
#[frb(ignore)]
pub fn watch_recording_config_for_test(
    module: String,
    key: Option<String>,
    sink: RecordingConfigSink,
) -> Result<(), String> {
    crate::config_api::watch_recording(module, key, sink)
}

/// Test seam: registers an in-memory global stream without an FRB runtime.
#[doc(hidden)]
#[frb(ignore)]
pub fn events_recording_config_for_test(sink: RecordingConfigSink) {
    crate::config_api::events_recording(sink);
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
        crate::config_api::clear_sinks();
        crate::dl_adapter::clear_module_config_sinks();
    }
}

use gstore_core::{db as core_db, migration as core_migration};
use rusqlite::OptionalExtension;

const CORE_E_NOT_INITIALIZED: &str =
    "CORE_E_NOT_INITIALIZED: CoreApi.init() has not been called";

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

/// Device identity crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct DeviceFactsDto {
    pub model: String,
    pub manufacturer: String,
}

/// Storage paths the frontend resolved for the core.
#[derive(Debug, Clone)]
pub struct CorePathsDto {
    pub data: String,
    pub files: String,
    pub cache: String,
}

/// Platform facts pushed by the frontend.
#[derive(Debug, Clone)]
pub struct PlatformFactsDto {
    pub source_id: String,
    pub os: String,
    pub arch: String,
    pub abis: Vec<String>,
    pub sdk: i32,
    pub device: DeviceFactsDto,
    pub paths: CorePathsDto,
    pub crypto_key: Option<Vec<u8>>,
    pub captured_at: i64,
}

impl From<PlatformFactsDto> for gstore_core::facts::PlatformFacts {
    fn from(facts: PlatformFactsDto) -> Self {
        Self {
            source_id: facts.source_id,
            os: facts.os,
            arch: facts.arch,
            abis: facts.abis,
            sdk: facts.sdk,
            device: gstore_core::facts::DeviceFacts {
                model: facts.device.model,
                manufacturer: facts.device.manufacturer,
            },
            paths: gstore_core::facts::CorePaths {
                data: facts.paths.data,
                files: facts.paths.files,
                cache: facts.paths.cache,
            },
            crypto_key: facts.crypto_key,
            captured_at: facts.captured_at,
        }
    }
}

/// One installed application in an inventory snapshot.
#[derive(Debug, Clone)]
pub struct InstalledAppDto {
    pub package_name: String,
    pub app_name: Option<String>,
    pub version_name: String,
    pub version_code: i64,
    pub signature_sha256: Option<String>,
    pub source_dir: Option<String>,
    pub installer: Option<String>,
    pub is_system: bool,
    pub target_sdk: i32,
    pub min_sdk: i32,
    pub abis: Vec<String>,
}

impl From<InstalledAppDto> for gstore_core::facts::InstalledApp {
    fn from(app: InstalledAppDto) -> Self {
        Self {
            package_name: app.package_name,
            app_name: app.app_name,
            version_name: app.version_name,
            version_code: app.version_code,
            signature_sha256: app.signature_sha256,
            source_dir: app.source_dir,
            installer: app.installer,
            is_system: app.is_system,
            target_sdk: app.target_sdk,
            min_sdk: app.min_sdk,
            abis: app.abis,
        }
    }
}

/// Full installed-app set pushed by the frontend.
#[derive(Debug, Clone)]
pub struct InventorySnapshotDto {
    pub source_id: String,
    pub seq: i64,
    pub captured_at: i64,
    pub apps: Vec<InstalledAppDto>,
}

impl From<InventorySnapshotDto> for gstore_core::facts::InventorySnapshot {
    fn from(snapshot: InventorySnapshotDto) -> Self {
        Self {
            source_id: snapshot.source_id,
            seq: snapshot.seq,
            captured_at: snapshot.captured_at,
            apps: snapshot.apps.into_iter().map(Into::into).collect(),
        }
    }
}

/// Result of one inventory push.
#[derive(Debug, Clone)]
pub struct InventoryPushResultDto {
    pub accepted: bool,
    pub reason: Option<String>,
}

/// Current inventory source status.
#[derive(Debug, Clone)]
pub struct InventoryStatusDto {
    pub source_id: String,
    pub seq: Option<i64>,
    pub captured_at: Option<i64>,
    pub count: u32,
    pub stale: bool,
}

/// Frontend install policy (mirrors `gstore_core::facts::InstallRules`).
#[derive(Debug, Clone)]
pub struct InstallRulesDto {
    pub version: i64,
    pub install_enabled: bool,
    pub abi_priority: Vec<String>,
    pub allow_downgrade: bool,
    pub allow_unknown_sources: bool,
    pub signature_policy: String,
    pub silent_install: bool,
    pub timeout_secs: i64,
}

impl From<gstore_core::facts::InstallRules> for InstallRulesDto {
    fn from(rules: gstore_core::facts::InstallRules) -> Self {
        Self {
            version: rules.version,
            install_enabled: rules.install_enabled,
            abi_priority: rules.abi_priority,
            allow_downgrade: rules.allow_downgrade,
            allow_unknown_sources: rules.allow_unknown_sources,
            signature_policy: rules.signature_policy,
            silent_install: rules.silent_install,
            timeout_secs: rules.timeout_secs,
        }
    }
}

impl From<InstallRulesDto> for gstore_core::facts::InstallRules {
    fn from(rules: InstallRulesDto) -> Self {
        Self {
            version: rules.version,
            install_enabled: rules.install_enabled,
            abi_priority: rules.abi_priority,
            allow_downgrade: rules.allow_downgrade,
            allow_unknown_sources: rules.allow_unknown_sources,
            signature_policy: rules.signature_policy,
            silent_install: rules.silent_install,
            timeout_secs: rules.timeout_secs,
        }
    }
}

/// Frontend update policy (mirrors `gstore_core::facts::UpdateRules`).
#[derive(Debug, Clone)]
pub struct UpdateRulesDto {
    pub version: i64,
    pub channel_priority: Vec<String>,
    pub allow_prerelease: bool,
    pub signature_policy: String,
    pub max_inventory_age_secs: i64,
}

impl From<gstore_core::facts::UpdateRules> for UpdateRulesDto {
    fn from(rules: gstore_core::facts::UpdateRules) -> Self {
        Self {
            version: rules.version,
            channel_priority: rules.channel_priority,
            allow_prerelease: rules.allow_prerelease,
            signature_policy: rules.signature_policy,
            max_inventory_age_secs: rules.max_inventory_age_secs,
        }
    }
}

impl From<UpdateRulesDto> for gstore_core::facts::UpdateRules {
    fn from(rules: UpdateRulesDto) -> Self {
        Self {
            version: rules.version,
            channel_priority: rules.channel_priority,
            allow_prerelease: rules.allow_prerelease,
            signature_policy: rules.signature_policy,
            max_inventory_age_secs: rules.max_inventory_age_secs,
        }
    }
}

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
    db: std::sync::Mutex<Option<gstore_core::db::SharedConn>>,
    download: crate::download_host::HostDownloadPort,
    facts: gstore_core::facts::FactStore,
    inventory: gstore_core::inventory::InventoryStore,
    rules: gstore_core::rules::RuleStore,
    config: std::sync::Arc<gstore_core::config::ConfigStore>,
}

pub struct CoreInitResult {
    pub schema_version: i32,
    pub db_path: String,
    pub data_dir: String,
    pub files_dir: String,
    pub cache_dir: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreWritesMarkerDto {
    pub domain: String,
    pub first_write_at: i64,
    pub snapshot_id: Option<String>,
}

impl From<gstore_core::migration::CoreWriteMarker> for CoreWritesMarkerDto {
    fn from(marker: gstore_core::migration::CoreWriteMarker) -> Self {
        Self {
            domain: marker.domain,
            first_write_at: marker.first_write_at,
            snapshot_id: marker.snapshot_id,
        }
    }
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
        let handle = open_core_db(&data_dir).map_err(|error| format!("CORE_E_INIT: {error}"))?;
        let shared = handle.shared_writer();
        let download = crate::download_host::HostDownloadPort::new(
            shared.clone(),
            core_db::core_db_path(std::path::Path::new(&data_dir)),
            PathBuf::from(&data_dir),
            PathBuf::from(&cache_dir),
        );
        Self::finish_init(data_dir, files_dir, cache_dir, handle, shared, download)
    }

    /// Test seam: the production init sequence with an injected download port.
    #[frb(ignore)]
    #[doc(hidden)]
    pub fn init_with_download_port_for_test(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
        download: crate::download_host::HostDownloadPort,
    ) -> Result<CoreApi, String> {
        for dir in [&data_dir, &files_dir, &cache_dir] {
            std::fs::create_dir_all(dir)
                .map_err(|e| format!("CORE_E_INIT: create dir {dir}: {e}"))?;
        }
        let handle = open_core_db(&data_dir).map_err(|error| format!("CORE_E_INIT: {error}"))?;
        let shared = handle.shared_writer();
        Self::finish_init(data_dir, files_dir, cache_dir, handle, shared, download)
    }

    fn finish_init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
        handle: DbHandle,
        shared: gstore_core::db::SharedConn,
        download: crate::download_host::HostDownloadPort,
    ) -> Result<CoreApi, String> {
        let config_secrets: std::sync::Arc<dyn gstore_core::ports::FileSecretPort + Send + Sync> =
            std::sync::Arc::new(gstore_core::ports::FileSecretStore::new(
                std::path::Path::new(&files_dir).join("secrets"),
            ));
        let config = std::sync::Arc::new(gstore_core::config::ConfigStore::new(
            handle.clone(),
            config_secrets,
        ));
        config
            .load_all()
            .map_err(|error| format!("CORE_E_INIT: config load: {error}"))?;
        let config_bus = std::sync::Arc::new(gstore_core::config::ConfigBus::new());
        crate::config_api::install_core_config(
            std::sync::Arc::clone(&config),
            config_bus,
            handle.clone(),
        );

        let api = CoreApi {
            paths: std::sync::Mutex::new(Some(CorePaths {
                data_dir,
                files_dir,
                cache_dir,
            })),
            db: std::sync::Mutex::new(Some(shared)),
            download,
            facts: gstore_core::facts::FactStore::new(handle.clone()),
            inventory: gstore_core::inventory::InventoryStore::new(handle.clone()),
            rules: gstore_core::rules::RuleStore::new(handle.clone()),
            config,
        };
        {
            let _suppression = core_migration::suppress_core_write_markers();
            if let Err(error) = api.download.reconcile() {
                crate::log_bridge::push_host_log(
                    2,
                    format!("download reconcile at init (non-fatal): {error}"),
                );
            }
        }
        let armed = handle
            .with_writer(|conn| core_migration::core_writes_present(conn))
            .map_err(|error| format!("CORE_E_INIT: hydrate core_writes: {error}"))?;
        gstore_core::flags::set_core_writes_armed(armed);
        Ok(api)
    }

    #[allow(dead_code)] // consumed by Todo 2's DownloadApi facade
    pub(crate) fn download_port(&self) -> &crate::download_host::HostDownloadPort {
        &self.download
    }

    #[allow(dead_code)] // observable init reconcile outcome for tests and Todo 2
    pub(crate) fn download_reconcile(&self) -> Option<crate::download_host::ReconcileOutcome> {
        self.download.last_reconcile()
    }

    /// Test seam: whether this handle's store is the one in the process global.
    #[doc(hidden)]
    #[frb(ignore)]
    pub fn shares_config_store_with_global_for_test(&self) -> bool {
        crate::config_api::installed_store_for_test()
            .is_some_and(|store| std::sync::Arc::ptr_eq(&store, &self.config))
    }

    /// Test seam: raw read through this handle's own store.
    #[doc(hidden)]
    #[frb(ignore)]
    pub fn config_value_for_test(&self, module: String, key: String) -> Result<String, String> {
        let key = gstore_core::config::ConfigKey::new(module, key)
            .map_err(|error| error.to_string())?;
        let value = self.config.get(&key).map_err(|error| error.to_string())?;
        serde_json::to_string(&value).map_err(|error| error.to_string())
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
        let db = db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
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

    /// Three-way download resync (dry-run by default).
    ///
    /// Documented deviation from the plan's no-argument `resyncDownloads()`:
    /// the Rust core cannot locate the Dart Floor database
    /// (`getDatabasesPath()/download_task.db`), so the caller passes it as
    /// `floor_db_path`. `None` (or a missing file) yields `floor_rows == 0` and
    /// a two-way module ↔ core parity run.
    ///
    /// A dry-run (`apply == false`) is strictly read-only: the module database
    /// is opened `SQLITE_OPEN_READ_ONLY`, no core row is written, and
    /// `snapshot_path`/`updated` stay empty. `apply == true` first writes
    /// `<files_dir>/migration/backups/pre-resync-<millis>.db` via `VACUUM INTO`,
    /// then mirrors module rows and marks non-terminal core rows
    /// `needs_restart` when the module database is gone. Any identity conflict
    /// returns `CORE_E_DOWNLOAD_RESYNC_CONFLICT` with zero writes, including
    /// conflicts found during an apply.
    ///
    /// Neither path writes a `core_writes` marker or flips a flag.
    pub fn resync_downloads(
        &self,
        apply: bool,
        floor_db_path: Option<String>,
    ) -> Result<ResyncReportDto, String> {
        let files_dir = {
            let paths = self
                .paths
                .lock()
                .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: paths lock poisoned"))?;
            paths
                .as_ref()
                .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?
                .files_dir
                .clone()
        };
        let floor = floor_db_path
            .as_deref()
            .map(str::trim)
            .filter(|path| !path.is_empty())
            .map(std::path::Path::new);
        self.download
            .resync_downloads(apply, floor, std::path::Path::new(&files_dir))
            .map(ResyncReportDto::from)
            .map_err(resync_err)
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

        let db = db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
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
        let (data_dir, files_dir) = {
            let guard = self
                .paths
                .lock()
                .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: paths lock poisoned"))?;
            let paths = guard
                .as_ref()
                .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;
            (paths.data_dir.clone(), paths.files_dir.clone())
        };
        let shared = {
            let guard = self
                .db
                .lock()
                .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
            guard
                .as_ref()
                .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?
                .clone()
        };
        let live = core_db::core_db_path(std::path::Path::new(&data_dir));
        let handle = core_db::DbHandle::from_shared(live, shared).with_files_dir(&files_dir);
        let version = handle
            .replace_from_snapshot(std::path::Path::new(&path))
            .map_err(|e| e.0)?;
        self.config
            .reload_from_db()
            .map_err(|error| format!("CORE_E_SNAPSHOT_RESTORE: config reload: {error}"))?;
        let armed = handle
            .with_writer(|conn| core_migration::core_writes_present(conn))
            .map_err(|e| format!("CORE_E_SNAPSHOT_RESTORE: hydrate core_writes: {}", e.0))?;
        gstore_core::flags::set_core_writes_armed(armed);
        crate::log_bridge::push_host_log(
            1,
            format!(
                "core snapshot restored from {path}: schema v{version}, secrets_excluded=true"
            ),
        );
        Ok(version)
    }

    /// Imports one Dart-exported migration artifact.
    ///
    /// Faces for `channel_db`, `channel_env`, `fdroid_sources`, and `pack` route
    /// through [`gstore_core::channel_migration`]; `update_prefs` keeps the
    /// original JSON-document path. `added_apps_db` and `catalog_db` import the
    /// legacy Floor catalog into the core `added_apps`/`app_config` tables. The
    /// old source files are never moved or deleted by this method (only
    /// successfully imported env/fdroid documents are removed).
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

        // The legacy catalog importers take the shared `DbHandle` (they take the
        // writer mutex internally), so the connection lock must not be held.
        if kind == "added_apps_db" || kind == "catalog_db" {
            let shared = {
                let guard = self
                    .db
                    .lock()
                    .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
                guard
                    .as_ref()
                    .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?
                    .clone()
            };
            let live = core_db::core_db_path(std::path::Path::new(&paths.0));
            let handle = core_db::DbHandle::from_shared(live, shared)
                .with_files_dir(std::path::Path::new(&paths.1));
            if kind == "catalog_db" {
                let report = gstore_core::catalog::import::import_catalog(
                    &handle,
                    Some(path_ref),
                    path_ref,
                    &gstore_core::catalog::import::CatalogImportOptions::default(),
                )
                .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {}", e.message()))?;
                return u32::try_from(report.apps)
                    .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: catalog rows: {e}"));
            }
            let report = gstore_core::added::migration::import_dart_added_db(&handle, path_ref)
                .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {e}"))?;
            return u32::try_from(report.apps + report.tags)
                .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: added rows: {e}"));
        }

        let db = self
            .db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let db = db
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;
        let db = db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;

        match kind.as_str() {
            "channel_db" => {
                let secrets = gstore_core::ports::FileSecretStore::new(
                    std::path::Path::new(&paths.1).join("secrets"),
                );
                let migrator = gstore_core::channel_migration::ChannelMigrator::new(
                    &db,
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
                    &db,
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
                    &db,
                    &secrets,
                    migration_dir.join("backups"),
                );
                migrator
                    .import_fdroid_sources_file(path_ref)
                    .map(|report| report.sources as u32)
                    .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {e}"))
            }
            _ => core_migration::import_migration_file(&db, &kind, path_ref)
                .map(|written| written as u32)
                .map_err(|e| format!("CORE_E_IMPORT_MIGRATION: {}", e.0)),
        }
    }

    pub fn core_writes(&self, domain: String) -> Result<Option<CoreWritesMarkerDto>, String> {
        self.core_write_marker_inner(domain, false)
    }

    /// Records the first core write for `domain` and returns its marker.
    ///
    /// Idempotent: a second call returns the original `first_write_at` and
    /// `snapshot_id`. The call is rejected with `CORE_E_CORE_WRITE_DOMAIN` for
    /// anything outside `CORE_WRITES_DOMAINS`.
    pub fn arm_core_write(&self, domain: String) -> Result<CoreWritesMarkerDto, String> {
        validate_core_write_domain(&domain)?;
        let db = self
            .db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let db = db
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;
        let mut db = db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let tx = db
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
            .map_err(|e| format!("CORE_E_CORE_WRITE: begin {domain}: {e}"))?;
        core_migration::mark_core_write(&tx, &domain, None)
            .map_err(|e| format!("CORE_E_CORE_WRITE: arm {domain}: {}", e.0))?;
        let marker = core_migration::core_write_marker(&tx, &domain)
            .map_err(|e| format!("CORE_E_CORE_WRITE: read {domain}: {}", e.0))?
            .ok_or_else(|| {
                format!("CORE_E_CORE_WRITE: marker missing after arm for {domain}")
            })?;
        tx.commit()
            .map_err(|e| format!("CORE_E_CORE_WRITE: commit {domain}: {e}"))?;
        Ok(marker.into())
    }

    /// Reads the marker for `domain` without writing anything.
    pub fn core_write_marker(
        &self,
        domain: String,
    ) -> Result<Option<CoreWritesMarkerDto>, String> {
        self.core_write_marker_inner(domain, true)
    }

    fn core_write_marker_inner(
        &self,
        domain: String,
        validate_domain: bool,
    ) -> Result<Option<CoreWritesMarkerDto>, String> {
        if validate_domain {
            validate_core_write_domain(&domain)?;
        }
        let db = self
            .db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let db = db
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;
        let db = db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        core_migration::core_write_marker(&db, &domain)
            .map(|marker| marker.map(CoreWritesMarkerDto::from))
            .map_err(|e| format!("CORE_E_WRITES: query {domain}: {}", e.0))
    }

    /// Stores the latest frontend-pushed platform facts.
    pub fn push_platform_facts(&self, facts: PlatformFactsDto) -> Result<(), String> {
        self.facts
            .put(&facts.into())
            .map_err(|error| format!("CORE_E_FACTS: {error}"))
    }

    /// Applies one inventory snapshot under the core stale-seq policy.
    pub fn push_inventory(
        &self,
        snapshot: InventorySnapshotDto,
    ) -> Result<InventoryPushResultDto, String> {
        let result = self
            .inventory
            .push(&snapshot.into())
            .map_err(|error| format!("CORE_E_INVENTORY: {error}"))?;
        Ok(InventoryPushResultDto {
            accepted: result.accepted,
            reason: result.reason,
        })
    }

    /// Reports the stored inventory sequence, capture time, size, and staleness.
    pub fn inventory_status(&self) -> Result<InventoryStatusDto, String> {
        let source_id = self
            .facts
            .get()
            .map_err(|error| format!("CORE_E_FACTS: {error}"))?
            .map(|facts| facts.source_id)
            .unwrap_or_else(|| "android".to_string());
        let rules = self
            .rules
            .effective_update()
            .map_err(|error| format!("CORE_E_RULES: {error}"))?;
        let stale = self
            .inventory
            .is_stale(&source_id, rules.max_inventory_age_secs, now_millis())
            .map_err(|error| format!("CORE_E_INVENTORY: {error}"))?;
        let seq = self
            .inventory
            .source_seq(&source_id)
            .map_err(|error| format!("CORE_E_INVENTORY: {error}"))?;

        let db = self
            .db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let db = db
            .as_ref()
            .ok_or_else(|| CORE_E_NOT_INITIALIZED.to_string())?;
        let conn = db
            .lock()
            .map_err(|_| format!("{CORE_E_NOT_INITIALIZED}: db lock poisoned"))?;
        let captured_at: Option<i64> = conn
            .query_row(
                "SELECT captured_at FROM inventory_source WHERE source_id=?1",
                [&source_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(|error| format!("CORE_E_INVENTORY: {error}"))?;
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM installed_app WHERE source_id=?1",
                [&source_id],
                |row| row.get(0),
            )
            .map_err(|error| format!("CORE_E_INVENTORY: {error}"))?;

        Ok(InventoryStatusDto {
            source_id,
            seq,
            captured_at,
            count: u32::try_from(count).unwrap_or(u32::MAX),
            stale,
        })
    }

    /// Returns the stored install rules or the pinned defaults.
    pub fn get_install_rules(&self) -> Result<InstallRulesDto, String> {
        self.rules
            .get_install()
            .map(Into::into)
            .map_err(|error| format!("CORE_E_RULES: {error}"))
    }

    /// Persists install rules after validation.
    pub fn set_install_rules(&self, rules: InstallRulesDto) -> Result<(), String> {
        self.rules
            .set_install(&rules.into())
            .map_err(|error| format!("CORE_E_RULES: {error}"))
    }

    /// Returns the stored update rules or the pinned defaults.
    pub fn get_update_rules(&self) -> Result<UpdateRulesDto, String> {
        self.rules
            .get_update()
            .map(Into::into)
            .map_err(|error| format!("CORE_E_RULES: {error}"))
    }

    /// Persists update rules after validation.
    pub fn set_update_rules(&self, rules: UpdateRulesDto) -> Result<(), String> {
        self.rules
            .set_update(&rules.into())
            .map_err(|error| format!("CORE_E_RULES: {error}"))
    }

    /// Drains queued core events (`inventory.changed`, ...) as JSON strings.
    pub fn take_events(&self) -> Result<Vec<String>, String> {
        self.inventory
            .take_events()
            .into_iter()
            .map(|event| event.to_json().map_err(core_err))
            .collect()
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

    #[test]
    fn core_api_init_download_reconcile_is_non_fatal() {
        let root = temp_root("download_reconcile");
        let data_dir = root.join("data");
        let files_dir = root.join("files");
        let cache_dir = root.join("cache");
        let module_dir = data_dir.join("gstore_mods").join("download");
        std::fs::create_dir_all(&module_dir).unwrap();
        std::fs::write(module_dir.join("download.db"), b"").unwrap();

        let api = CoreApi::init(
            data_dir.to_string_lossy().into_owned(),
            files_dir.to_string_lossy().into_owned(),
            cache_dir.to_string_lossy().into_owned(),
        )
        .expect("CoreApi::init must tolerate a missing download module");

        let outcome = api
            .download_reconcile()
            .expect("init must record the reconcile outcome");
        println!("init download reconcile outcome: {outcome:?}");
        assert!(
            matches!(outcome, crate::download_host::ReconcileOutcome::Err(_)),
            "module db exists but module is unmounted: expected a typed error"
        );
        assert!(
            api.download_port().snapshot().is_ok(),
            "snapshots are core-authoritative and must not require a mounted module"
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

    fn exec_batch_on_live(api: &CoreApi, sql: &str) {
        let shared = api.db.lock().expect("db lock");
        let conn = shared.as_ref().expect("db present");
        conn.lock()
            .expect("writer lock")
            .execute_batch(sql)
            .expect("exec batch");
    }

    fn count_live(db_path: &str, sql: &str) -> i64 {
        let conn = rusqlite::Connection::open_with_flags(
            db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .expect("open live db read-only");
        conn.query_row(sql, [], |r| r.get(0)).expect("count")
    }

    /// End-to-end: `importSnapshot` validates, backs up, swaps the live database,
    /// and every holder of the shared writer observes the restored connection.
    ///
    /// This test started as the Todo 1 characterization pin (validate-only left
    /// the live database untouched) and asserts the flipped behavior now.
    #[test]
    fn snapshot_restore_end_to_end() {
        let root = temp_root("restore_e2e");
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

        exec_batch_on_live(
            &api,
            "INSERT INTO channels(key, kind, name) VALUES ('in-snapshot', 'custom', 'snapshot');\
             INSERT INTO core_writes(domain, first_write_at, snapshot_id) \
             VALUES ('channel', 11, 'snapshot-marker');",
        );
        let snapshot = root.join("snap.db");
        api.export_snapshot(snapshot.to_string_lossy().into_owned())
            .expect("export_snapshot");
        exec_batch_on_live(
            &api,
            "DELETE FROM core_writes WHERE domain='channel';\
             INSERT INTO channels(key, kind, name) VALUES ('after-export', 'custom', 'live');",
        );

        assert_eq!(
            count_live(
                snapshot.to_str().unwrap(),
                "SELECT COUNT(*) FROM core_writes",
            ),
            1,
            "snapshot must carry the marker seeded before export"
        );
        let version = api
            .import_snapshot(snapshot.to_string_lossy().into_owned())
            .expect("import_snapshot");
        assert_eq!(version, gstore_core::migration::CORE_SCHEMA_VERSION);

        assert_eq!(
            count_live(&init.db_path, "SELECT COUNT(*) FROM core_writes"),
            1,
            "restore must copy the snapshot marker into the live database"
        );
        assert_eq!(
            count_live(
                &init.db_path,
                "SELECT COUNT(*) FROM channels WHERE key='after-export'",
            ),
            0,
            "restore must discard rows written after the snapshot"
        );
        assert_eq!(
            count_live(
                &init.db_path,
                "SELECT COUNT(*) FROM channels WHERE key='in-snapshot'",
            ),
            1,
            "restore must install snapshot rows"
        );
        assert!(
            api.core_writes("channel".to_string())
                .expect("core_writes")
                .is_some(),
            "the shared writer must observe the restored connection"
        );
        let integrity: String = rusqlite::Connection::open_with_flags(
            &init.db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )
        .expect("open live db")
        .query_row("PRAGMA integrity_check", [], |r| r.get(0))
        .expect("integrity_check");
        assert_eq!(integrity, "ok");

        let backups = files_dir.join("migration").join("backups");
        let backup = std::fs::read_dir(&backups)
            .expect("backup dir")
            .filter_map(Result::ok)
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("pre-restore-")
            })
            .expect("pre-restore backup");
        assert_eq!(
            count_live(
                &backup.path().to_string_lossy(),
                "SELECT COUNT(*) FROM channels WHERE key='after-export'",
            ),
            1,
            "pre-restore backup must hold the pre-restore live database"
        );
        assert!(
            !std::path::Path::new(&init.db_path)
                .with_extension("db.restore-old")
                .exists(),
            ".restore-old must not survive a successful restore"
        );

        drop(api);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn snapshot_import_propagates_typed_failure() {
        let root = temp_root("snapshot_failure");
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
        exec_batch_on_live(
            &api,
            "INSERT INTO channels(key, kind, name) VALUES ('keep', 'custom', 'Keep');",
        );

        let snapshot = root.join("newer.db");
        api.export_snapshot(snapshot.to_string_lossy().into_owned())
            .expect("export_snapshot");
        rusqlite::Connection::open(&snapshot)
            .unwrap()
            .pragma_update(
                None,
                "user_version",
                gstore_core::migration::CORE_SCHEMA_VERSION + 1,
            )
            .unwrap();

        let error = api
            .import_snapshot(snapshot.to_string_lossy().into_owned())
            .expect_err("newer snapshot must not report success");
        println!("snapshot_import_propagates_typed_failure: {error}");
        assert!(
            error.starts_with("CORE_E_SNAPSHOT_NEWER"),
            "unexpected error: {error}"
        );
        assert_eq!(
            count_live(
                &init.db_path,
                "SELECT COUNT(*) FROM channels WHERE key='keep'",
            ),
            1,
            "rejected restore must leave the live database intact"
        );

        drop(api);
        std::fs::remove_dir_all(&root).unwrap();
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

        assert_eq!(
            api.import_snapshot(snapshot.to_string_lossy().into_owned())
                .expect("import_snapshot"),
            gstore_core::migration::CORE_SCHEMA_VERSION
        );

        let count = core_writes_count(&init.db_path);
        println!("after snapshot export/import: core_writes count = {count}");
        assert_eq!(
            count, 0,
            "restoring a snapshot without markers must not create any"
        );

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

    #[test]
    fn catalog_and_added_apps_migration_bridge_kinds() {
        let root = temp_root("catalogadded");
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

        let catalog = root.join("gstore").join("apps.db");
        std::fs::create_dir_all(catalog.parent().unwrap()).unwrap();
        {
            let conn = rusqlite::Connection::open(&catalog).unwrap();
            conn.execute_batch(
                "CREATE TABLE apps(
                     appId TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, user TEXT,
                     repositories TEXT, icon TEXT, des TEXT, category TEXT);
                 CREATE TABLE category(
                     id TEXT NOT NULL PRIMARY KEY, description TEXT NOT NULL,
                     icon TEXT NOT NULL);
                 CREATE TABLE config(version TEXT NOT NULL);
                 INSERT INTO apps VALUES
                     ('com.a','A','u','r','i','d','c'),
                     ('com.b','B','u','r','i','d','c');
                 INSERT INTO category VALUES ('c','Cat','i');
                 INSERT INTO config VALUES ('v1');",
            )
            .unwrap();
        }
        let rows = api
            .import_migration_file(
                "catalog_db".to_string(),
                catalog.to_string_lossy().into_owned(),
            )
            .expect("import catalog_db");
        println!("catalog_db rows={rows}");
        assert_eq!(rows, 2);
        assert_eq!(
            api.import_migration_file(
                "catalog_db".to_string(),
                catalog.to_string_lossy().into_owned(),
            )
            .expect("re-import catalog_db"),
            2,
            "a re-import replaces the same catalog"
        );

        let added = root.join("added_apps.db");
        {
            let conn = rusqlite::Connection::open(&added).unwrap();
            conn.execute_batch(
                "CREATE TABLE added_apps(
                     id INTEGER PRIMARY KEY AUTOINCREMENT, channelId TEXT NOT NULL,
                     appId TEXT NOT NULL, addTime INTEGER NOT NULL,
                     sortOrder INTEGER NOT NULL, isEnabled INTEGER NOT NULL,
                     UNIQUE(channelId, appId));
                 CREATE TABLE added_app_tags(
                     channelId TEXT NOT NULL, appId TEXT NOT NULL, tag TEXT NOT NULL,
                     addTime INTEGER NOT NULL,
                     PRIMARY KEY(channelId, appId, tag));
                 INSERT INTO added_apps VALUES
                     (1,'github','com.a',10,0,1),
                     (2,'vivo','com.b',20,1,1);
                 INSERT INTO added_app_tags VALUES
                     ('github','com.a','tag1',10),
                     ('github','com.a','tag2',11);
                 PRAGMA user_version = 5;",
            )
            .unwrap();
        }
        let rows = api
            .import_migration_file(
                "added_apps_db".to_string(),
                added.to_string_lossy().into_owned(),
            )
            .expect("import added_apps_db");
        println!("added_apps_db rows={rows}");
        assert_eq!(rows, 4, "two apps plus two tags");

        let live = rusqlite::Connection::open(&init.db_path).unwrap();
        for (table, expected) in [
            ("apps", 2_i64),
            ("categories", 1),
            ("app_config", 1),
            ("added_apps", 2),
            ("added_app_tags", 2),
        ] {
            let count: i64 = live
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(count, expected, "core table {table}");
        }

        drop(live);
        drop(api);
        std::fs::remove_dir_all(&root).unwrap();
    }

    struct ResyncTestBridge;

    impl gstore_core::download::port::ModuleBridge for ResyncTestBridge {
        fn call(&self, method: &str, _payload: &[u8]) -> Result<Vec<u8>, String> {
            panic!("resync must not call the module bridge ({method})");
        }
    }

    fn create_resync_module_db(path: &std::path::Path, dedup_key: &str) {
        let conn = rusqlite::Connection::open(path).expect("open module db");
        conn.execute_batch(
            "CREATE TABLE download_task (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id TEXT NOT NULL, app_name TEXT NOT NULL, version TEXT NOT NULL,
                file_name TEXT NOT NULL, url TEXT NOT NULL, file_path TEXT NOT NULL,
                total INTEGER NOT NULL DEFAULT 0, received INTEGER NOT NULL DEFAULT 0,
                status INTEGER NOT NULL, dedup_key TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
            );",
        )
        .expect("module DDL");
        conn.execute(
            "INSERT INTO download_task
             (id, app_id, app_name, version, file_name, url, file_path, total, received,
              status, dedup_key, created_at, updated_at)
             VALUES (1, 'com.a', 'A', '1.0', 'a.apk', 'https://example.test/a.bin',
                     '/tmp/a.apk', 100, 10, 0, ?1, 1, 2)",
            [dedup_key],
        )
        .expect("insert module row");
    }

    #[test]
    fn core_api_resync_downloads_reports_and_aborts_on_conflict() {
        let root = temp_root("resync");
        let data_dir = root.join("data");
        let files_dir = root.join("files");
        let cache_dir = root.join("cache");
        let module_path = data_dir
            .join("gstore_mods")
            .join("download")
            .join("download.db");
        std::fs::create_dir_all(module_path.parent().unwrap()).unwrap();
        create_resync_module_db(&module_path, "app:com.a:1.0:a.apk");

        let core_db = gstore_core::db::core_db_path(&data_dir);
        let mut conn = rusqlite::Connection::open(&core_db).expect("open core db");
        gstore_core::migration::apply_core_schema(&mut conn).expect("core schema");
        let shared: gstore_core::db::SharedConn = std::sync::Arc::new(std::sync::Mutex::new(conn));
        let port = crate::download_host::HostDownloadPort::with_bridge_for_test(
            ResyncTestBridge,
            shared.clone(),
            core_db.clone(),
            Some(module_path.clone()),
        );
        let api = CoreApi::init_with_download_port_for_test(
            data_dir.to_string_lossy().into_owned(),
            files_dir.to_string_lossy().into_owned(),
            cache_dir.to_string_lossy().into_owned(),
            port,
        )
        .expect("CoreApi::init_with_download_port_for_test");

        exec_batch_on_live(
            &api,
            "INSERT INTO download_task
             (id, module_task_id, dedup_key, app_id, app_name, version, file_name,
              status, bytes_done, total, created_at, updated_at)
             VALUES (100, '1', 'app:com.a:1.0:a.apk', 'com.a', 'A', '1.0', 'a.apk',
                     'running', 0, 100, 1, 1);",
        );
        let db_path = api.migrate_paths().expect("migrate_paths").db_path;

        let dry = api
            .resync_downloads(false, None)
            .expect("resync dry-run");
        println!("core_api resync dry -> {dry:?}");
        assert_eq!(dry.floor_rows, 0);
        assert_eq!(dry.module_rows, 1);
        assert_eq!(dry.core_rows, 1);
        assert_eq!(dry.matched, 1);
        assert_eq!(dry.missing, 0);
        assert_eq!(dry.updated, 0);
        assert!(dry.snapshot_path.is_none());

        let applied = api.resync_downloads(true, None).expect("resync apply");
        println!("core_api resync apply -> {applied:?}");
        assert_eq!(applied.updated, 1, "the stale core mirror is refreshed");
        let snapshot = applied.snapshot_path.clone().expect("apply snapshot");
        assert!(std::path::Path::new(&snapshot).exists());
        assert_eq!(
            count_live(&db_path, "SELECT bytes_done FROM download_task WHERE id = 100"),
            10
        );
        assert_eq!(
            count_live(&db_path, "SELECT COUNT(*) FROM core_writes"),
            0,
            "resync must not write markers"
        );

        {
            let module = rusqlite::Connection::open(&module_path).expect("reopen module");
            module
                .execute(
                    "UPDATE download_task SET dedup_key = 'app:com.a:1.0:a.apk:rev2' WHERE id = 1",
                    [],
                )
                .expect("introduce dedup conflict");
        }
        let error = api
            .resync_downloads(true, None)
            .expect_err("a conflict must abort the apply");
        println!("core_api resync conflict -> {error}");
        assert!(
            error.starts_with("CORE_E_DOWNLOAD_RESYNC_CONFLICT"),
            "unexpected error: {error}"
        );
        assert_eq!(
            count_live(&db_path, "SELECT COUNT(*) FROM download_task"),
            1,
            "conflict abort must not write rows"
        );
        assert_eq!(
            count_live(&db_path, "SELECT bytes_done FROM download_task WHERE id = 100"),
            10,
            "conflict abort must not rewrite the mirror"
        );

        std::fs::remove_file(&module_path).expect("drop module db");
        let missing_floor = root.join("missing-floor.db");
        let restart = api
            .resync_downloads(true, Some(missing_floor.to_string_lossy().into_owned()))
            .expect("a missing module db is not an error");
        println!("core_api resync missing module db -> {restart:?}");
        assert_eq!(restart.floor_rows, 0);
        assert_eq!(restart.module_rows, 0);
        assert_eq!(restart.conflicts, 0);
        assert_eq!(restart.needs_restart, 1);
        assert!(restart.snapshot_path.is_some());
        assert_eq!(
            count_live(&db_path, "SELECT COUNT(*) FROM download_task WHERE status = 'needs_restart'"),
            1
        );

        drop(api);
        std::fs::remove_dir_all(&root).unwrap();
    }

}



// ===========================================================================
// ChannelApi (Todo 13)
// ===========================================================================

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, RwLock};

use gstore_core::channel::{
    validate_channel_key, BuildHistoryQuery, ChannelCategory, ChannelDriver, ChannelRegistry,
    DetailAction, FdroidDriver, GStoreDriver, GitHubDriver, InstalledPack, LocalDbDriver,
    PackError, PackStore, ScriptChannel, ScriptChannelConfig, ScriptChannelStore, ScriptDetail,
    ScriptDetailConfig, SqliteChannelStore, SwitchVersionQuery, VersionOptionsQuery, VivoDriver,
};
use gstore_core::db::DbHandle;
use gstore_core::dto::{
    AppDetail, AppDownload, AppSummary, ChannelKey, ChannelKind, ChannelMeta, DetailSection, Label,
};
use gstore_core::ports::{
    validate_secret_key, CachedMetadataPort, CoreConfig, FileSecretPort, FileSecretStore,
    HttpOptions, HttpPort, MetadataPort, PackageMetadata, RepoPort,
};
use gstore_core::Error as CoreError;
use gstore_core::channel_migration::is_sensitive_key;
use gstore_core::CoreEvent;
use serde::{Deserialize, Serialize};

use crate::http_port::ScriptHttp;
use crate::script_api::DEFAULT_UI_BUDGET;
use crate::script_host_impl::{ConfigMap, EnvMap, ScriptHostImpl};

fn core_err(error: CoreError) -> String {
    format!("{}: {}", error.code(), error.message())
}

/// Publishes one [`CoreEvent`] on the shared module-event bridge.
///
/// `event.wire_name()` is the **single source** of the wire string (never a
/// hard-coded literal here), and `event.to_json()` is the single source of the
/// body, so a `CoreEvent` variant can never drift from what Dart receives. The
/// bridge is the same one `script.ui_request` uses
/// (`event_bridge::push_event` → `moduleEvents` → `AppEventBus`); no separate
/// channel is introduced.
fn push_core_event(event: &CoreEvent) {
    let wire = event.wire_name();
    match event.to_json() {
        Ok(body) => crate::event_bridge::push_event(0, 0, wire, body.into_bytes()),
        Err(error) => eprintln!("emit {wire} failed: {error}"),
    }
}

/// Publishes a `channel.changed` event for a registered channel.
fn push_channel_changed(key: &ChannelKey, kind: ChannelKind) {
    push_core_event(&CoreEvent::ChannelChanged {
        key: key.clone(),
        kind,
    });
}

/// Publishes a `channel.changed` event for a validated key string.
///
/// A key that fails [`ChannelKey::new`] cannot name a real channel, so it is a
/// programming error rather than a runtime one; nothing is emitted for it.
fn push_channel_changed_str(key: &str, kind: ChannelKind) {
    if let Ok(key) = ChannelKey::new(key) {
        push_channel_changed(&key, kind);
    }
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

/// One dynamic display label crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct ChannelLabel {
    pub key: String,
    pub label: String,
    pub value: String,
    pub icon: Option<String>,
}

impl From<Label> for ChannelLabel {
    fn from(label: Label) -> Self {
        Self {
            key: label.key,
            label: label.label,
            value: label.value,
            icon: label.icon,
        }
    }
}

impl From<ChannelLabel> for Label {
    fn from(label: ChannelLabel) -> Self {
        Self {
            key: label.key,
            label: label.label,
            value: label.value,
            icon: label.icon,
        }
    }
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
    pub labels: Vec<ChannelLabel>,
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
            labels: app.labels.into_iter().map(ChannelLabel::from).collect(),
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
            labels: self.labels.into_iter().map(Label::from).collect(),
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
    pub labels: Vec<ChannelLabel>,
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
            labels: detail.labels.into_iter().map(ChannelLabel::from).collect(),
        }
    }
}

/// One action from a pack's `detail.js` `detailMenu` result.
///
/// Mirrors the core [`DetailAction`] and the JSON Dart `_refreshActions` reads
/// (`action`, `jscall`, `icon`, `clickIsDimiss`). FRB emits these as camelCase
/// Dart fields (`clickIsDimiss`), matching the pack contract.
#[derive(Debug, Clone)]
pub struct ChannelDetailAction {
    pub action: String,
    pub jscall: String,
    pub icon: Option<String>,
    pub click_is_dimiss: Option<bool>,
}

impl From<DetailAction> for ChannelDetailAction {
    fn from(action: DetailAction) -> Self {
        Self {
            action: action.action,
            jscall: action.jscall,
            icon: action.icon,
            click_is_dimiss: action.click_is_dimiss,
        }
    }
}

/// One version row of a pack's `versionOptions` result (`{version, envs, buildCount}`).
#[derive(Debug, Clone)]
pub struct ScriptVersionOption {
    pub version: String,
    pub envs: Vec<String>,
    pub build_count: i64,
}

/// A pack's `versionOptions` result (`{title?, envs, versions, currentEnv?, currentVersion?}`).
///
/// Pack-specific keys are preserved verbatim in [`Self::extra_json`] (a JSON
/// object string), following the `ChannelAppInfo.extra_json` convention.
#[derive(Debug, Clone)]
pub struct ScriptVersionOptions {
    pub title: Option<String>,
    pub envs: Vec<String>,
    pub versions: Vec<ScriptVersionOption>,
    pub current_env: Option<String>,
    pub current_version: Option<String>,
    pub extra_json: String,
}

/// One build row of a pack's `buildHistory` result
/// (`{num, publishedAt, size, changelog, installTimes, ...}`).
///
/// Pack-specific keys (`builtBy`, `ipaName`, `fileUrl`, ...) are preserved in
/// [`Self::extra_json`].
#[derive(Debug, Clone)]
pub struct ScriptBuild {
    pub num: i64,
    pub published_at: Option<String>,
    pub size: Option<i64>,
    pub changelog: Option<String>,
    pub install_times: Option<i64>,
    pub extra_json: String,
}

impl ScriptVersionOption {
    fn from_value(value: &serde_json::Value) -> Self {
        let map = value.as_object();
        Self {
            version: json_text(map, "version").unwrap_or_default(),
            envs: json_string_list(map, "envs"),
            build_count: json_i64(map, "buildCount").unwrap_or(0),
        }
    }
}

impl ScriptVersionOptions {
    /// Parses a `versionOptions` payload; `None` for a non-object (Dart's
    /// `decoded is! Map` degrade).
    fn from_value(value: &serde_json::Value) -> Option<Self> {
        let map = value.as_object()?;
        Some(Self {
            title: json_text(Some(map), "title"),
            envs: json_string_list(Some(map), "envs"),
            versions: map
                .get("versions")
                .and_then(serde_json::Value::as_array)
                .map(|items| items.iter().map(ScriptVersionOption::from_value).collect())
                .unwrap_or_default(),
            current_env: json_text(Some(map), "currentEnv"),
            current_version: json_text(Some(map), "currentVersion"),
            extra_json: json_extra(
                map,
                &["title", "envs", "versions", "currentEnv", "currentVersion"],
            ),
        })
    }
}

impl ScriptBuild {
    fn from_value(value: &serde_json::Value) -> Self {
        let map = value.as_object();
        Self {
            num: json_i64(map, "num").unwrap_or(0),
            published_at: json_text(map, "publishedAt"),
            size: json_i64(map, "size"),
            changelog: json_text(map, "changelog"),
            install_times: json_i64(map, "installTimes"),
            extra_json: map
                .map(|map| {
                    json_extra(
                        map,
                        &["num", "publishedAt", "size", "changelog", "installTimes"],
                    )
                })
                .unwrap_or_else(|| "{}".to_string()),
        }
    }
}

fn json_text(
    map: Option<&serde_json::Map<String, serde_json::Value>>,
    key: &str,
) -> Option<String> {
    match map.and_then(|map| map.get(key))? {
        serde_json::Value::String(text) => Some(text.clone()),
        serde_json::Value::Number(number) => Some(number.to_string()),
        serde_json::Value::Bool(flag) => Some(flag.to_string()),
        _ => None,
    }
}

fn json_string_list(
    map: Option<&serde_json::Map<String, serde_json::Value>>,
    key: &str,
) -> Vec<String> {
    map.and_then(|map| map.get(key))
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|value| match value {
                    serde_json::Value::String(text) => Some(text.clone()),
                    serde_json::Value::Number(number) => Some(number.to_string()),
                    serde_json::Value::Bool(flag) => Some(flag.to_string()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

fn json_i64(map: Option<&serde_json::Map<String, serde_json::Value>>, key: &str) -> Option<i64> {
    match map.and_then(|map| map.get(key))? {
        serde_json::Value::Number(number) => number.as_i64().or_else(|| {
            number
                .as_f64()
                .filter(|float| float.fract() == 0.0)
                .map(|float| float as i64)
        }),
        serde_json::Value::String(text) => text.parse::<i64>().ok(),
        _ => None,
    }
}

fn json_extra(map: &serde_json::Map<String, serde_json::Value>, known: &[&str]) -> String {
    let extra: serde_json::Map<String, serde_json::Value> = map
        .iter()
        .filter(|(key, _)| !known.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    serde_json::Value::Object(extra).to_string()
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
        let version_name = object
            .get("versionName")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string);
        Ok(Some(PackageMetadata {
            package_name,
            app_name,
            icon_url,
            version_name,
        }))
    }
}

/// One F-Droid source as pushed by Dart.
///
/// Dart encodes each source as a JSON string over the unchanged
/// `setFdroidSources(sources: Vec<String>)` FRB boundary; a bare URL string is
/// still accepted and mapped to a spec with no mirrors. `mirrors` is the
/// mirror-first fallback list handed to the repo module's `download_repo`.
#[derive(Clone, Debug, Serialize, Deserialize)]
struct FdroidSourceSpec {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    url: String,
    #[serde(default)]
    mirrors: Vec<String>,
    #[serde(default)]
    mirror_first: bool,
    #[serde(default = "default_true")]
    enabled: bool,
}

fn default_true() -> bool {
    true
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
    fdroid_specs: Arc<RwLock<Vec<FdroidSourceSpec>>>,
}

impl HostRepoPort {
    fn new(
        data_dir: impl AsRef<Path>,
        fdroid_specs: Arc<RwLock<Vec<FdroidSourceSpec>>>,
    ) -> Self {
        let data_dir = data_dir.as_ref().to_path_buf();
        Self {
            db_path: data_dir.join("repo.db"),
            data_dir,
            port: std::sync::Mutex::new(None),
            fdroid_specs,
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

    fn mirrors_for(&self, source: &str) -> (Vec<String>, bool) {
        mirrors_from(&self.fdroid_specs, source)
    }
}

/// The mirrors registered for `source` plus the mirror-first flag — the
/// candidate list a download walks.
///
/// Takes the source lock rather than `&self` so the idempotency test can probe
/// a second handle's view of the set through the exact function
/// [`HostRepoPort::mirrors_for`] uses.
fn mirrors_from(specs: &RwLock<Vec<FdroidSourceSpec>>, source: &str) -> (Vec<String>, bool) {
    specs
        .read()
        .ok()
        .and_then(|specs| {
            specs
                .iter()
                .find(|spec| spec_matches_source(spec, source))
                .map(|spec| (spec.mirrors.clone(), spec.mirror_first))
        })
        .unwrap_or_default()
}

fn normalize_fdroid_source(source: &str) -> String {
    source.trim().trim_end_matches('/').to_string()
}

fn spec_matches_source(spec: &FdroidSourceSpec, source: &str) -> bool {
    let normalized = normalize_fdroid_source(source);
    normalize_fdroid_source(&spec.url) == normalized
        || spec
            .mirrors
            .iter()
            .any(|mirror| normalize_fdroid_source(mirror) == normalized)
}

impl RepoPort for HostRepoPort {
    fn download_repo(
        &self,
        source: &str,
    ) -> Result<gstore_core::ports::RepoMeta, CoreError> {
        let (mirrors, mirror_first) = self.mirrors_for(source);
        self.with_port(|port| port.download_repo_with_mirrors(source, &mirrors, mirror_first))
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

    fn get_app_icons(
        &self,
        source: &str,
        package_names: &[String],
    ) -> Result<Vec<(String, String)>, CoreError> {
        self.with_port(|port| port.get_app_icons(source, package_names))
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
    config: RwLock<CoreConfig>,
    http: Arc<dyn HttpPort>,
    script_http: Arc<dyn ScriptHttp>,
    metadata: Arc<dyn MetadataPort>,
    repo: Arc<dyn RepoPort>,
    /// Active F-Droid sources (with mirrors). Loaded from the persisted
    /// `update_prefs` row at init and refreshed by [`ChannelApi::set_fdroid_sources`].
    /// Shared with [`HostRepoPort`] so downloads can use each source's mirrors.
    fdroid_sources: Arc<RwLock<Vec<FdroidSourceSpec>>>,
    /// Lazily-built script-lane drivers, keyed by pack channel key.
    script_drivers: Mutex<HashMap<ChannelKey, Arc<dyn ChannelDriver>>>,
}

impl ChannelApiInner {
    /// Builds (and caches) the script-lane driver for an installed pack.
    ///
    /// Returns `Ok(None)` when `key` names no installed pack, so the resolver
    /// can fall through without treating an unknown key as an error.
    fn script_driver(&self, key: &ChannelKey) -> Result<Option<Arc<dyn ChannelDriver>>, String> {
        if let Ok(cache) = self.script_drivers.lock() {
            if let Some(driver) = cache.get(key) {
                return Ok(Some(driver.clone()));
            }
        }
        let loaded = match crate::script_pack::load(&self.pack, key) {
            Ok(loaded) => loaded,
            Err(_) => return Ok(None),
        };
        let env = crate::script_env::load(&self.db, &self.secrets, key)
            .map(|snapshot| Arc::new(Mutex::new(snapshot)))
            .unwrap_or_else(|_| Arc::new(Mutex::new(EnvMap::new())));
        let host = Arc::new(ScriptHostImpl::new(
            self.db.clone(),
            Arc::clone(&self.script_http),
            env,
            Arc::new(Mutex::new(None)),
            Arc::new(Mutex::new(ConfigMap::new())),
            DEFAULT_UI_BUDGET,
            Arc::new(std::sync::atomic::AtomicBool::new(false)),
        ));
        let store: Arc<dyn ScriptChannelStore> =
            Arc::new(crate::script_db::SqliteScriptChannelStore::new(self.db.clone()));
        let config = ScriptChannelConfig::new(key.clone(), loaded.entry_js, host)
            .with_store(store)
            .with_pack_key(key.clone());
        let driver: Arc<dyn ChannelDriver> = Arc::new(
            ScriptChannel::new(config).map_err(|error| core_err(CoreError::Internal(error.to_string())))?,
        );
        if let Ok(mut cache) = self.script_drivers.lock() {
            cache.insert(key.clone(), driver.clone());
        }
        Ok(Some(driver))
    }

    /// Resolves a channel code to its driver, registry first then script lane.
    ///
    /// This is the resolver the library facade uses: it covers the built-in
    /// registry drivers (including the read-only `local_db`), any `js_*` script
    /// pack, and returns `None` for an unknown code. Unlike
    /// [`ChannelApi::driver`] it never turns a miss into an error, which is what
    /// [`gstore_core::library::LibraryDriverResolver`] expects.
    fn driver(&self, code: &str) -> Option<Arc<dyn ChannelDriver>> {
        let key = ChannelKey::new(code).ok()?;
        if let Ok(driver) = self.registry.driver(&key) {
            return Some(driver);
        }
        self.script_driver(&key).ok().flatten()
    }

    /// The base config with the current F-Droid source set applied.
    fn fdroid_config(&self) -> Result<CoreConfig, String> {
        let specs = self
            .fdroid_sources
            .read()
            .map_err(|_| invalid_arg("fdroid sources lock poisoned"))?;
        let sources = enabled_source_urls(&specs);
        let base = self
            .config
            .read()
            .map_err(|_| invalid_arg("channel config lock poisoned"))?
            .clone();
        base.with_fdroid_sources(sources)
            .map(|config| config.with_fdroid_asset_bases(fdroid_asset_bases(&specs)))
            .map_err(core_err)
    }

    fn github_config(&self) -> Result<CoreConfig, String> {
        self.config
            .read()
            .map(|config| config.clone())
            .map_err(|_| invalid_arg("channel config lock poisoned"))
    }
}

fn enabled_source_urls(specs: &[FdroidSourceSpec]) -> Vec<String> {
    specs
        .iter()
        .filter(|spec| spec.enabled)
        .map(|spec| spec.url.clone())
        .filter(|url| !url.trim().is_empty())
        .collect()
}

/// Every base a stored F-Droid icon may be prefixed with: each configured
/// source URL plus its mirrors, enabled or not. A stale icon written under a
/// base that is no longer current is re-based by the core driver.
fn fdroid_asset_bases(specs: &[FdroidSourceSpec]) -> Vec<String> {
    specs
        .iter()
        .flat_map(|spec| std::iter::once(&spec.url).chain(spec.mirrors.iter()))
        .map(|url| url.trim().to_string())
        .filter(|url| !url.is_empty())
        .collect()
}

/// Reads the persisted `fdroid_sources` document from the core `update_prefs`
/// table into source specs.
///
/// Accepts the new structured array of specs (`url` + `mirrors`), the legacy
/// array of plain URL strings, and the Dart-migration array of
/// `{id,name,repoUrl}` objects.
fn persisted_fdroid_sources(db: &DbHandle) -> Vec<FdroidSourceSpec> {
    let raw = db
        .reader()
        .ok()
        .and_then(|conn| gstore_core::migration::update_pref(&conn, "fdroid_sources").ok().flatten());
    let Some(raw) = raw else {
        return Vec::new();
    };
    let Ok(serde_json::Value::Array(items)) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return Vec::new();
    };
    items.iter().filter_map(fdroid_spec_from_value).collect()
}

fn fdroid_spec_from_value(value: &serde_json::Value) -> Option<FdroidSourceSpec> {
    match value {
        serde_json::Value::String(url) => {
            gstore_core::ports::repo::validate_repo_source(url).ok()?;
            Some(FdroidSourceSpec {
                id: String::new(),
                name: String::new(),
                url: url.clone(),
                mirrors: Vec::new(),
                mirror_first: false,
                enabled: true,
            })
        }
        serde_json::Value::Object(map) => {
            let url = map
                .get("url")
                .or_else(|| map.get("repoUrl"))
                .and_then(serde_json::Value::as_str)?;
            gstore_core::ports::repo::validate_repo_source(url).ok()?;
            Some(FdroidSourceSpec {
                id: map
                    .get("id")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                name: map
                    .get("name")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                url: url.to_string(),
                mirrors: map
                    .get("mirrors")
                    .and_then(serde_json::Value::as_array)
                    .map(|items| items.iter().filter_map(mirror_url).collect())
                    .unwrap_or_default(),
                mirror_first: map
                    .get("mirror_first")
                    .and_then(serde_json::Value::as_bool)
                    .or_else(|| map.get("useMirrors").and_then(serde_json::Value::as_bool))
                    .unwrap_or(false),
                enabled: map
                    .get("enabled")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(true),
            })
        }
        _ => None,
    }
}

fn mirror_url(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(url) => (!url.trim().is_empty()).then(|| url.clone()),
        serde_json::Value::Object(map) => {
            let enabled = map
                .get("enabled")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(true);
            let url = map.get("url").and_then(serde_json::Value::as_str)?;
            (enabled && !url.trim().is_empty()).then(|| url.to_string())
        }
        _ => None,
    }
}

fn parse_fdroid_source_spec(raw: &str) -> FdroidSourceSpec {
    if let Ok(mut spec) = serde_json::from_str::<FdroidSourceSpec>(raw) {
        spec.mirrors.retain(|mirror| !mirror.trim().is_empty());
        return spec;
    }
    FdroidSourceSpec {
        id: String::new(),
        name: String::new(),
        url: raw.to_string(),
        mirrors: Vec::new(),
        mirror_first: false,
        enabled: true,
    }
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
        "gstore" => Some(meta(
            ChannelKind::GStore,
            "GStore",
            "GStore 本地应用库渠道",
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

/// Process-wide [`ChannelApiInner`] cache keyed by the three init directories.
///
/// `UpdateApi::init` calls [`ChannelApi::init`] again on the same directories;
/// without this cache that opened a second core `DbHandle` and a second
/// [`HostRepoPort`] against the same `repo.db`, i.e. two repo module instances.
/// Sharing one inner means a source/mirror update pushed through any handle
/// reaches the driver and the download path used by all of them.
type InnerCache = Mutex<HashMap<(String, String, String), Arc<ChannelApiInner>>>;

fn inner_cache() -> &'static InnerCache {
    static INNERS: OnceLock<InnerCache> = OnceLock::new();
    INNERS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Test-only: drops every cached inner so tests start from a cold cache.
#[cfg(test)]
pub(crate) fn reset_global_inners() {
    inner_cache()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clear();
}

impl ChannelApi {
    /// Initializes the facade with the same directory shape as `CoreApi`.
    ///
    /// Safe to call more than once against the same directories: the first call
    /// caches the [`ChannelApiInner`] process-wide and later calls return that
    /// same inner, so the core DB handle, repo port and driver set are never
    /// duplicated. No feature flag is armed.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<ChannelApi, String> {
        let http: Arc<dyn HttpPort> = Arc::new(crate::http_port::ReqwestHttpPort::new());
        let script_http: Arc<dyn ScriptHttp> = Arc::new(crate::http_port::ReqwestHttpPort::new());
        let metadata: Arc<dyn MetadataPort> =
            Arc::new(CachedMetadataPort::new(HttpMetadataPort::new(http.clone())));
        let fdroid_specs: Arc<RwLock<Vec<FdroidSourceSpec>>> = Arc::new(RwLock::new(Vec::new()));
        let repo: Arc<dyn RepoPort> =
            Arc::new(HostRepoPort::new(&data_dir, Arc::clone(&fdroid_specs)));
        Self::init_inner(
            data_dir, files_dir, cache_dir, http, script_http, metadata, repo, fdroid_specs,
        )
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
        let script_http: Arc<dyn ScriptHttp> =
            Arc::new(crate::http_port::BufferedScriptHttp::new(http.clone()));
        let fdroid_specs: Arc<RwLock<Vec<FdroidSourceSpec>>> = Arc::new(RwLock::new(Vec::new()));
        Self::build_inner(
            data_dir, files_dir, cache_dir, http, script_http, metadata, repo, fdroid_specs,
        )
    }

    /// Returns the process-wide inner for these directories, building and
    /// caching it on the first call.
    ///
    /// The cache lock is held across the build so two concurrent callers cannot
    /// each open their own `DbHandle`/`HostRepoPort` for the same dirs.
    fn init_inner(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
        http: Arc<dyn HttpPort>,
        script_http: Arc<dyn ScriptHttp>,
        metadata: Arc<dyn MetadataPort>,
        repo: Arc<dyn RepoPort>,
        fdroid_specs: Arc<RwLock<Vec<FdroidSourceSpec>>>,
    ) -> Result<ChannelApi, String> {
        let key = (data_dir.clone(), files_dir.clone(), cache_dir.clone());
        let mut inners = inner_cache()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if let Some(inner) = inners.get(&key) {
            return Ok(ChannelApi {
                inner: Arc::clone(inner),
            });
        }
        let api = Self::build_inner(
            data_dir, files_dir, cache_dir, http, script_http, metadata, repo, fdroid_specs,
        )?;
        inners.insert(key, Arc::clone(&api.inner));
        Ok(api)
    }

    /// Builds a fresh inner from the given ports, bypassing [`inner_cache`].
    fn build_inner(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
        http: Arc<dyn HttpPort>,
        script_http: Arc<dyn ScriptHttp>,
        metadata: Arc<dyn MetadataPort>,
        repo: Arc<dyn RepoPort>,
        fdroid_specs: Arc<RwLock<Vec<FdroidSourceSpec>>>,
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
        let persisted_specs = persisted_fdroid_sources(&db);
        let config = CoreConfig::new(None, token)
            .and_then(|config| config.with_fdroid_sources(enabled_source_urls(&persisted_specs)))
            .map(|config| config.with_fdroid_asset_bases(fdroid_asset_bases(&persisted_specs)))
            .map_err(core_err)?;
        {
            let mut guard = fdroid_specs
                .write()
                .map_err(|_| invalid_arg("fdroid sources lock poisoned"))?;
            *guard = persisted_specs;
        }
        let registry = Arc::new(ChannelRegistry::new(SqliteChannelStore::new(db.clone())));
        let pack = PackStore::new(files_path.join("channel_packs"), db.clone());
        let api = ChannelApi {
            inner: Arc::new(ChannelApiInner {
                db,
                registry,
                pack,
                secrets,
                config: RwLock::new(config),
                http,
                script_http,
                metadata,
                repo,
                fdroid_sources: fdroid_specs,
                script_drivers: Mutex::new(HashMap::new()),
            }),
        };
        {
            let _suppression = core_migration::suppress_core_write_markers();
            api.seed_builtin_records()?;
            api.bind_registry_drivers()?;
        }
        Ok(api)
    }

    fn seed_builtin_records(&self) -> Result<(), String> {
        for key in ["local_db", "gstore", "github", "vivo", "fdroid"] {
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
        let github_config = self.inner.github_config()?;
        let driver: Option<Arc<dyn ChannelDriver>> = match record.kind() {
            ChannelKind::LocalDb => Some(Arc::new(
                LocalDbDriver::new(key, meta.clone(), self.inner.db.clone())
                    .with_metadata(self.inner.metadata.clone())
                    .with_github(github_config.clone(), self.inner.http.clone()),
            )),
            ChannelKind::GStore => Some(Arc::new(
                GStoreDriver::new(key, meta.clone(), self.inner.db.clone())
                    .with_metadata(self.inner.metadata.clone())
                    .with_github(github_config.clone(), self.inner.http.clone()),
            )),
            ChannelKind::Github => Some(Arc::new(GitHubDriver::new(
                key,
                meta,
                self.inner.db.clone(),
                github_config.clone(),
                self.inner.http.clone(),
                self.inner.metadata.clone(),
            ))),
            ChannelKind::Vivo => Some(Arc::new(VivoDriver::new(
                key,
                meta,
                self.inner.db.clone(),
                github_config.clone(),
                self.inner.http.clone(),
            ))),
            ChannelKind::Fdroid => Some(Arc::new(FdroidDriver::new(
                key,
                meta,
                self.inner.db.clone(),
                self.inner.fdroid_config()?,
                self.inner.repo.clone(),
            ))),
            ChannelKind::JsLocal => self.inner.script_driver(&key)?,
            ChannelKind::Http | ChannelKind::Custom => None,
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

    /// Resolves the kind of a channel for a `channel.changed` event.
    ///
    /// A registered channel answers from its record. An unregistered key can only
    /// be a script-lane pack (the same rule `driver()` uses: a `js_*` pack need
    /// not exist in the channels-domain registry), so it reports `JsLocal`;
    /// anything else falls back to `Custom`.
    fn kind_of(&self, key: &ChannelKey) -> ChannelKind {
        if let Ok(Some(record)) = self.inner.registry.get(key) {
            return record.kind();
        }
        if key.as_str().starts_with("js_") {
            return ChannelKind::JsLocal;
        }
        ChannelKind::Custom
    }

    /// Builds the code-to-driver resolver used by the update service.
    ///
    /// The closure keeps the whole `ChannelApiInner` alive, so a facade that
    /// only needs the resolver may drop its own [`ChannelApi`] handle.
    pub(crate) fn resolver(&self) -> gstore_core::update::service::ChannelResolver {
        let inner = Arc::clone(&self.inner);
        Arc::new(move |code: &str| {
            let key = ChannelKey::new(code).ok()?;
            if let Ok(driver) = inner.registry.driver(&key) {
                return Some(driver);
            }
            inner.script_driver(&key).ok().flatten()
        })
    }

    /// Returns the unified library facade, sharing this facade's database
    /// handle and driver resolution.
    pub fn library(&self) -> LibraryApi {
        LibraryApi::build(Arc::clone(&self.inner))
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
        let key = self.channel_key(key)?;
        match self.inner.registry.driver(&key) {
            Ok(driver) => Ok(driver),
            // Unregistered: a `js_*` pack need not exist in the channels-domain
            // registry, so resolve it through the script lane like `resolver()`.
            // `script_driver` returns `Ok(None)` for a non-installed pack, so an
            // unknown key still yields the original typed `not_found`.
            Err(err) => match self.inner.script_driver(&key)? {
                Some(driver) => Ok(driver),
                None => Err(core_err(err)),
            },
        }
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
            | ChannelKind::GStore
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
            // A script-lane channel may be registered before its pack is
            // imported; bind the driver only when the pack already exists and
            // otherwise let the resolver build it on first use.
            ChannelKind::JsLocal => match self.driver_for(&record)? {
                Some(driver) => self
                    .inner
                    .registry
                    .register_driver(driver)
                    .map_err(core_err)?,
                None => self.inner.registry.register(record).map_err(core_err)?,
            },
            ChannelKind::Http | ChannelKind::Custom => {
                self.inner.registry.register(record).map_err(core_err)?;
            }
        }
        let entry = self.record(key.as_str())?;
        push_channel_changed(&key, kind);
        Ok(entry)
    }

    /// Removes a channel registration and its driver binding.
    pub fn unregister(&self, key: String) -> Result<(), String> {
        let key = self.require_channel(&key)?;
        let kind = self.kind_of(&key);
        self.inner.registry.unregister(&key).map_err(core_err)?;
        push_channel_changed(&key, kind);
        Ok(())
    }

    /// Enables a registered channel.
    pub fn enable(&self, key: String) -> Result<ChannelEntry, String> {
        let key = self.require_channel(&key)?;
        let kind = self.kind_of(&key);
        self.inner.registry.enable(&key).map_err(core_err)?;
        let entry = self.record(key.as_str())?;
        push_channel_changed(&key, kind);
        Ok(entry)
    }

    /// Disables a registered channel without removing it.
    pub fn disable(&self, key: String) -> Result<ChannelEntry, String> {
        let key = self.require_channel(&key)?;
        let kind = self.kind_of(&key);
        self.inner.registry.disable(&key).map_err(core_err)?;
        let entry = self.record(key.as_str())?;
        push_channel_changed(&key, kind);
        Ok(entry)
    }

    /// Imports a legacy flat pack from `zip_path`.
    pub fn import_pack(&self, path: String) -> Result<ChannelPackInfo, String> {
        if path.trim().is_empty() {
            return Err(invalid_arg("pack path must not be empty"));
        }
        let info = self
            .inner
            .pack
            .import_pack(&path)
            .map(ChannelPackInfo::from)
            .map_err(pack_err)?;
        push_channel_changed_str(&info.key, ChannelKind::JsLocal);
        Ok(info)
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
        self.inner.pack.remove_pack(&key).map_err(pack_err)?;
        push_channel_changed(&key, ChannelKind::JsLocal);
        Ok(true)
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
        let kind = self.kind_of(&key);
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
        push_channel_changed(&key, kind);
        Ok(())
    }

    /// Removes one env value from both the plaintext row and the secret port.
    pub fn env_remove(&self, key: String, name: String) -> Result<bool, String> {
        let key = self.require_channel(&key)?;
        let kind = self.kind_of(&key);
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
        let removed = plain_removed || secret_removed;
        // A no-op removal is not a mutation, so it emits nothing.
        if removed {
            push_channel_changed(&key, kind);
        }
        Ok(removed)
    }

    /// Runs the channel's update loop (`do_update`).
    pub fn refresh(&self, key: String) -> Result<bool, String> {
        let channel_key = self.channel_key(&key)?;
        let kind = self.kind_of(&channel_key);
        let changed = self.driver(&key)?.do_update(None).map_err(core_err)?;
        push_channel_changed(&channel_key, kind);
        Ok(changed)
    }

    /// Persists (or clears) the GitHub token and rebinds channel drivers.
    ///
    /// Called immediately after login/logout so GitHub channel requests switch
    /// from anonymous to authenticated (and back) without restarting the app.
    pub fn set_github_token(&self, token: Option<String>) -> Result<(), String> {
        let token = token.and_then(|value| {
            let trimmed = value.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        });
        match &token {
            Some(value) => self
                .inner
                .secrets
                .set("core_config.github_token", value)
                .map_err(core_err)?,
            None => {
                self.inner
                    .secrets
                    .remove("core_config.github_token")
                    .map_err(core_err)?;
            }
        }
        {
            let mut config = self
                .inner
                .config
                .write()
                .map_err(|_| invalid_arg("channel config lock poisoned"))?;
            *config = config
                .clone()
                .with_github_token(token)
                .map_err(core_err)?;
        }
        self.bind_registry_drivers()
    }

    /// Replaces the active F-Droid source set and rebinds the F-Droid driver.
    ///
    /// The Dart `FdroidRepoManager` pushes the enabled sources here on every
    /// source change (the core cannot read the Dart config store). Each entry is
    /// either a JSON-encoded spec (id/name/url/mirrors/mirror_first/enabled) or a
    /// bare URL; the full set is persisted into the core DB `update_prefs` table
    /// under key `fdroid_sources` so mirrors survive restarts. URLs are validated
    /// before anything is stored; an invalid URL is a typed error.
    pub fn set_fdroid_sources(&self, sources: Vec<String>) -> Result<(), String> {
        let mut specs = Vec::with_capacity(sources.len());
        for source in sources {
            let spec = parse_fdroid_source_spec(&source);
            gstore_core::ports::repo::validate_repo_source(&spec.url).map_err(core_err)?;
            specs.push(spec);
        }
        let json = serde_json::to_string(&specs).map_err(|error| {
            core_err(CoreError::Serialization(format!(
                "encode fdroid sources: {error}"
            )))
        })?;
        self.inner
            .db
            .with_writer(|conn| gstore_core::migration::set_update_pref(conn, "fdroid_sources", &json))
            .map_err(|error| core_err(CoreError::Io(error.0)))?;
        {
            let mut guard = self
                .inner
                .fdroid_sources
                .write()
                .map_err(|_| invalid_arg("fdroid sources lock poisoned"))?;
            *guard = specs;
        }
        let key = ChannelKey::new("fdroid").map_err(core_err)?;
        if let Some(record) = self.inner.registry.get(&key).map_err(core_err)? {
            if let Some(driver) = self.driver_for(&record)? {
                self.inner
                    .registry
                    .register_driver(driver)
                    .map_err(core_err)?;
            }
        }
        // A source identity imported before this list was known (the cutover
        // imports `channel_db` first) can only be resolved now, and an install
        // that already migrated never re-runs the import. Best-effort: a repair
        // failure must never break source configuration.
        if let Err(error) = self.inner.db.with_writer(|conn| {
            gstore_core::channel_migration::repair_fdroid_source_identities(conn)
                .map_err(|failure| core_db::DbError(failure.to_string()))
        }) {
            crate::log_bridge::push_host_log(
                1,
                format!("fdroid source-identity repair skipped: {error}"),
            );
        }
        Ok(())
    }

    /// Lists every app owned by a registered channel.
    ///
    /// Dart discovery reads this instead of calling its legacy `IChannel`
    /// implementation when `CoreFlags.channels` is armed.
    pub fn list_apps(
        &self,
        key: String,
        force_refresh: bool,
    ) -> Result<Vec<ChannelAppInfo>, String> {
        self.driver(&key)?
            .get_all_apps(force_refresh)
            .map_err(core_err)
            .map(|apps| {
                apps.into_iter()
                    .map(ChannelAppInfo::from_summary)
                    .collect()
            })
    }

    /// Checks whether a registered channel reports an update.
    pub fn check_update(&self, key: String) -> Result<bool, String> {
        self.driver(&key)?.check_update().map_err(core_err)
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

    /// Progressive detail block: README only.
    pub fn fetch_readme(&self, key: String, app_id: String) -> Result<Option<String>, String> {
        self.driver(&key)?
            .fetch_readme(&app_id)
            .map_err(core_err)
    }

    /// Adds/saves an app through the channel driver.
    pub fn add_app(&self, key: String, app: ChannelAppInfo) -> Result<(), String> {
        let channel_key = self.channel_key(&key)?;
        let kind = self.kind_of(&channel_key);
        let app = app.into_summary()?;
        self.driver(&key)?.add_app(&app).map_err(core_err)?;
        push_channel_changed(&channel_key, kind);
        Ok(())
    }

    /// Removes an app from the channel.
    pub fn remove_app(&self, key: String, app_id: String) -> Result<(), String> {
        let channel_key = self.channel_key(&key)?;
        let kind = self.kind_of(&channel_key);
        self.driver(&key)?
            .remove_app(&app_id)
            .map_err(core_err)?;
        push_channel_changed(&channel_key, kind);
        Ok(())
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

    /// Runs a pack's `detail.js` `versionOptions({appId, env?, currentVersion?})`.
    ///
    /// The current version is forwarded as the script's `version` filter (the
    /// pack `main` dispatch reads only `appId`/`env`; the extra key is additive).
    /// Returns `Ok(None)` when the pack answers JSON null (unimplemented /
    /// `{ok:false}` / a JS throw); an unknown/uninstalled pack is a typed
    /// `not_found`.
    pub fn script_version_options(
        &self,
        key: String,
        app_id: String,
        env: Option<String>,
        current_version: Option<String>,
    ) -> Result<Option<ScriptVersionOptions>, String> {
        self.with_script_detail(&key, |detail| {
            let outcome = detail.version_options(VersionOptionsQuery {
                app_id: &app_id,
                env: env.as_deref(),
                version: current_version.as_deref(),
            })?;
            Ok(outcome.and_then(|value| ScriptVersionOptions::from_value(&value)))
        })
    }

    /// Runs a pack's `detail.js` `getAppDetail({appId})` and returns the typed
    /// detail page.
    ///
    /// This is the detail page's INITIAL load path. It runs on a per-call
    /// [`ScriptDetail`] (the same runtime `script_switch_version` uses), so the
    /// first render and every later version/build switch read one implementation
    /// (`detail.js`) instead of the entry channel's separate `getAppDetail`
    /// copy. Returns `Ok(None)` when the pack answers JSON null / `{ok:false}`
    /// (unimplemented or no detail); an unknown/uninstalled pack is a typed
    /// `not_found`.
    pub fn script_get_app_detail(
        &self,
        key: String,
        app_id: String,
    ) -> Result<Option<ChannelAppDetailInfo>, String> {
        self.with_script_detail(&key, |detail| {
            let detail = detail.get_app_detail(&app_id)?;
            Ok(detail.map(ChannelAppDetailInfo::from))
        })
    }

    /// Runs a pack's `detail.js` `switchVersion({appId, env, version, build?})`
    /// and returns the typed detail page.
    ///
    /// `build_json` is an optional JSON object (`{num, ipaName}`) selecting a
    /// historical build; malformed JSON is a typed `invalid_argument`. Returns
    /// `Ok(None)` when the pack answers JSON null; an unknown/uninstalled pack
    /// is a typed `not_found`.
    pub fn script_switch_version(
        &self,
        key: String,
        app_id: String,
        env: String,
        version: String,
        build_json: Option<String>,
    ) -> Result<Option<ChannelAppDetailInfo>, String> {
        let build = match build_json {
            Some(raw) if !raw.trim().is_empty() => {
                let value: serde_json::Value = serde_json::from_str(&raw).map_err(|error| {
                    core_err(CoreError::Serialization(format!("build_json: {error}")))
                })?;
                Some(
                    value
                        .as_object()
                        .cloned()
                        .ok_or_else(|| invalid_arg("build_json must be a JSON object"))?,
                )
            }
            _ => None,
        };
        self.with_script_detail(&key, |detail| {
            let detail = detail.switch_version_detail(SwitchVersionQuery {
                app_id: &app_id,
                env: &env,
                version: &version,
                build: build.as_ref(),
            })?;
            Ok(detail.map(ChannelAppDetailInfo::from))
        })
    }

    /// Runs a pack's `detail.js` `buildHistory({appId, version, env})`.
    ///
    /// A missing result (JSON null / no `builds` array) degrades to an empty list.
    pub fn script_build_history(
        &self,
        key: String,
        app_id: String,
        env: String,
        version: String,
    ) -> Result<Vec<ScriptBuild>, String> {
        self.with_script_detail(&key, |detail| {
            let outcome = detail.build_history(BuildHistoryQuery {
                app_id: &app_id,
                env: &env,
                version: &version,
            })?;
            Ok(outcome
                .as_ref()
                .and_then(serde_json::Value::as_object)
                .and_then(|map| map.get("builds"))
                .and_then(serde_json::Value::as_array)
                .map(|items| items.iter().map(ScriptBuild::from_value).collect())
                .unwrap_or_default())
        })
    }

    /// Runs a pack's `detail.js` `detailMenu(appId)`.
    ///
    /// A missing/non-array result degrades to an empty list.
    pub fn script_detail_menu(
        &self,
        key: String,
        app_id: String,
    ) -> Result<Vec<ChannelDetailAction>, String> {
        self.with_script_detail(&key, |detail| {
            Ok(detail
                .detail_menu(&app_id)?
                .into_iter()
                .map(ChannelDetailAction::from)
                .collect())
        })
    }

    /// Runs one page-scoped pack `jscall` (for example `jsswitchUA`) on a fresh
    /// per-call [`ScriptDetail`].
    ///
    /// Unlike the four typed detail reads, an action may drive the UI through
    /// `host.ui.call` (e.g. `showUAPicker`). It runs on a NEW `ScriptDetail`, never
    /// the shared entry runtime, so a parked round-trip cannot contend on the
    /// entry's `op` guard and cannot deadlock a re-entrant dispatch. The pack drives
    /// the UI itself; the action's own result is not surfaced.
    pub fn script_detail_action(
        &self,
        key: String,
        app_id: String,
        jscall: String,
    ) -> Result<(), String> {
        let mut params = serde_json::Map::new();
        params.insert("appId".to_string(), serde_json::Value::String(app_id));
        self.with_script_detail(&key, |detail| detail.call_main(&jscall, &params).map(|_| ()))
    }

    /// Builds a one-shot [`ScriptDetail`] for `key`'s installed `detail.js` and
    /// runs `run` against it, disposing the runtime before returning.
    ///
    /// Mirrors [`ChannelApiInner::script_driver`]'s env + host wiring but returns
    /// the page-scoped detail dispatcher (not a [`ChannelDriver`]) and never
    /// caches it. An unknown/uninstalled pack, or one whose pack carries no
    /// `detail.js`, is a typed `not_found` — never `pack_not_found`.
    fn with_script_detail<T>(
        &self,
        key: &str,
        run: impl FnOnce(&ScriptDetail) -> Result<T, CoreError>,
    ) -> Result<T, String> {
        let key = self.channel_key(key)?;
        let loaded = crate::script_pack::load(&self.inner.pack, &key).map_err(|_| {
            core_err(CoreError::NotFound(format!(
                "script pack not installed: {key}"
            )))
        })?;
        let Some(detail_js) = loaded.detail_js else {
            return Err(core_err(CoreError::NotFound(format!(
                "script pack `{key}` has no detail.js"
            ))));
        };
        let env = crate::script_env::load(&self.inner.db, &self.inner.secrets, &key)
            .map(|snapshot| Arc::new(Mutex::new(snapshot)))
            .unwrap_or_else(|_| Arc::new(Mutex::new(EnvMap::new())));
        let host = Arc::new(ScriptHostImpl::new(
            self.inner.db.clone(),
            Arc::clone(&self.inner.script_http),
            env,
            Arc::new(Mutex::new(None)),
            Arc::new(Mutex::new(ConfigMap::new())),
            DEFAULT_UI_BUDGET,
            Arc::new(std::sync::atomic::AtomicBool::new(false)),
        ));
        let config =
            ScriptDetailConfig::new(key.clone(), detail_js, host).with_pack_key(key.clone());
        let detail = ScriptDetail::new(config).map_err(core_err)?;
        let result = run(&detail).map_err(core_err);
        if let Err(error) = detail.dispose() {
            if result.is_ok() {
                return Err(core_err(error));
            }
        }
        result
    }
}


// ===========================================================================
// CatalogApi / AddedAppsApi / UpdateApi (Wave 2 Todo 10)
// ===========================================================================

use gstore_core::added::apps::{AddedApp, AddedAppsService};
use gstore_core::aggregate::channel_app_fallback::SqliteChannelAppFallback;
use gstore_core::aggregate::service::{
    AggregatedApp, AggregationService, ChannelAppFallback, MetadataState,
};
use gstore_core::catalog::refresh::{catalog_changed_event, refresh_catalog};
use gstore_core::catalog::repo::{CatalogRepo, RepoEntry, RepoStatus};
use gstore_core::catalog::service::CatalogService;
use gstore_core::library::{LibraryDriverResolver, LibraryService};
use gstore_core::update::service::{CheckLogLevel, UpdateCheckReport, UpdateProgress, UpdateService};

fn validate_core_write_domain(domain: &str) -> Result<(), String> {
    if core_migration::is_core_write_domain(domain) {
        Ok(())
    } else {
        Err(format!("CORE_E_CORE_WRITE_DOMAIN: {domain:?}"))
    }
}

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

/// One catalog repository entry crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct CatalogRepoEntry {
    pub file: String,
    pub version: String,
    pub sha256: String,
    pub source: String,
    pub kind: String,
    pub added_at: i64,
    pub apps: i64,
}

/// Repository snapshot crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct CatalogRepoStatus {
    pub current_version: Option<String>,
    pub current_file: Option<String>,
    pub apps: i64,
    pub categories: i64,
    pub entries: Vec<CatalogRepoEntry>,
}

/// Result of a repository download.
#[derive(Debug, Clone)]
pub struct CatalogRepoDownload {
    pub version: Option<String>,
    pub changed: bool,
    pub status: CatalogRepoStatus,
}

/// Result of materializing the repository into the core catalog.
#[derive(Debug, Clone)]
pub struct CatalogMaterializeResult {
    pub materialized: bool,
    pub version: Option<String>,
    pub apps: i64,
    pub categories: i64,
}

impl From<RepoEntry> for CatalogRepoEntry {
    fn from(entry: RepoEntry) -> Self {
        Self {
            file: entry.file,
            version: entry.version,
            sha256: entry.sha256,
            source: entry.source,
            kind: entry.kind,
            added_at: entry.added_at,
            apps: i64::try_from(entry.apps).unwrap_or(i64::MAX),
        }
    }
}

impl From<RepoStatus> for CatalogRepoStatus {
    fn from(status: RepoStatus) -> Self {
        Self {
            current_version: status.current_version,
            current_file: status.current_file,
            apps: i64::try_from(status.apps).unwrap_or(i64::MAX),
            categories: i64::try_from(status.categories).unwrap_or(i64::MAX),
            entries: status.entries.into_iter().map(Into::into).collect(),
        }
    }
}

/// Read-only facade over the core local catalog.
#[frb(opaque)]
pub struct CatalogApi {
    db: DbHandle,
    service: CatalogService,
    http: Arc<dyn HttpPort>,
    repo: CatalogRepo,
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
        let repo = CatalogRepo::new(std::path::Path::new(&data_dir).join("catalog_repo"))
            .map_err(core_err)?;
        Ok(Self { db, service, http, repo })
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
            push_core_event(&event);
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

    /// Current catalog repository snapshot.
    pub fn repo_status(&self) -> Result<CatalogRepoStatus, String> {
        self.repo.status().map_err(core_err).map(Into::into)
    }

    /// Registers a validated seed database (content-addressed, idempotent).
    pub fn repo_ensure_seed(&self, path: String) -> Result<CatalogRepoStatus, String> {
        self.repo
            .ensure_seed(std::path::Path::new(&path))
            .map_err(core_err)
            .map(Into::into)
    }

    /// Downloads and validates a remote catalog, switching `current` when newer.
    pub fn repo_download(&self, url: String) -> Result<CatalogRepoDownload, String> {
        let report = self
            .repo
            .download(self.http.as_ref(), &url)
            .map_err(core_err)?;
        let status = self.repo.status().map_err(core_err)?;
        Ok(CatalogRepoDownload {
            version: report.version,
            changed: report.changed,
            status: status.into(),
        })
    }

    /// Selects a repository entry by version or file name.
    pub fn repo_select(&self, version: String) -> Result<CatalogRepoStatus, String> {
        self.repo.select(&version).map_err(core_err).map(Into::into)
    }

    /// Materializes the current repository database into the core catalog.
    pub fn repo_materialize(&self) -> Result<CatalogMaterializeResult, String> {
        let report = self.repo.materialize_if_needed(&self.db).map_err(core_err)?;
        Ok(CatalogMaterializeResult {
            materialized: report.materialized,
            version: report.version,
            apps: i64::try_from(report.apps).unwrap_or(i64::MAX),
            categories: i64::try_from(report.categories).unwrap_or(i64::MAX),
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

/// One unified library read row crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct LibraryEntry {
    pub added: AddedAppEntry,
    pub app: ChannelAppInfo,
    pub channel_code: String,
    pub channel_kind: String,
    pub is_from_cache: bool,
    pub error: Option<String>,
    pub metadata_state: String,
}

impl From<AggregatedApp> for LibraryEntry {
    fn from(row: AggregatedApp) -> Self {
        Self {
            added: AddedAppEntry::from(row.added_app),
            app: ChannelAppInfo::from_summary(row.app),
            channel_code: row.channel_code,
            channel_kind: row.channel.as_code().to_string(),
            is_from_cache: row.is_from_cache,
            error: row.error,
            metadata_state: metadata_state_code(row.metadata_state).to_string(),
        }
    }
}

fn metadata_state_code(state: MetadataState) -> &'static str {
    match state {
        MetadataState::Resolved => "resolved",
        MetadataState::FromChannelStore => "from_channel_store",
        MetadataState::Unresolved => "unresolved",
    }
}

fn summary_from_detail(detail: AppDetail) -> AppSummary {
    AppSummary {
        app_id: detail.app_id,
        package_name: detail.package_name,
        name: detail.name,
        user: String::new(),
        repositories: String::new(),
        icon: detail.icon,
        des: detail.description,
        readme: None,
        category: None,
        extra: if detail.extra.is_empty() {
            None
        } else {
            Some(detail.extra)
        },
        labels: detail.labels,
    }
}

/// One page of the unified library read model.
#[derive(Debug, Clone)]
pub struct LibraryPage {
    pub entries: Vec<LibraryEntry>,
    pub total: i64,
}

/// Outcome of [`LibraryApi::repair_missing_metadata`].
#[derive(Debug, Clone)]
pub struct RepairReport {
    pub repaired: u32,
    pub unresolved: u32,
}

/// Writable-driver lookup for [`LibraryService`], over the facade's drivers.
struct HostDriverResolver {
    inner: Arc<ChannelApiInner>,
}

impl LibraryDriverResolver for HostDriverResolver {
    fn writable_driver(&self, channel: &str) -> Option<Arc<dyn ChannelDriver>> {
        self.inner.driver(channel)
    }
}

/// Unified library facade: two-phase membership writes plus the
/// driver -> `channel_apps` -> placeholder read model.
///
/// Shares [`ChannelApi`]'s database handle and driver resolution, so there is
/// exactly one writer connection and no duplicate driver setup.
#[frb(opaque)]
pub struct LibraryApi {
    inner: Arc<ChannelApiInner>,
    fallback: Arc<SqliteChannelAppFallback>,
    library: LibraryService,
    agg: AggregationService,
}

impl LibraryApi {
    fn build(inner: Arc<ChannelApiInner>) -> Self {
        let db = inner.db.clone();
        let library = LibraryService::new(
            AddedAppsService::new(db.clone()),
            Arc::new(HostDriverResolver {
                inner: Arc::clone(&inner),
            }),
        );
        let channels: gstore_core::aggregate::service::ChannelResolver = {
            let inner = Arc::clone(&inner);
            Arc::new(move |code: &str| inner.driver(code))
        };
        let fallback = Arc::new(SqliteChannelAppFallback::new(db.clone()));
        let agg = AggregationService::new(db, channels)
            .expect("aggregation service construction is infallible")
            .with_fallback(fallback.clone())
            .with_trace(Arc::new(|line: &str| {
                crate::log_bridge::push_host_log(1, line.to_string());
            }));
        Self {
            inner,
            fallback,
            library,
            agg,
        }
    }

    /// Adds an app: channel metadata first, membership second.
    pub fn add(
        &self,
        channel: String,
        app: ChannelAppInfo,
        sort_order: Option<i64>,
    ) -> Result<AddedAppEntry, String> {
        let summary = app.into_summary()?;
        self.library
            .add(&channel, &summary, sort_order)
            .map_err(core_err)
            .map(AddedAppEntry::from)
    }

    /// Adds only `added_apps` membership; never writes `channel_apps`.
    ///
    /// Backup restore uses this for reference-only items so a placeholder
    /// name/icon cannot overwrite a good `channel_apps` metadata row.
    pub fn add_membership(
        &self,
        channel: String,
        app_id: String,
        sort_order: Option<i64>,
    ) -> Result<AddedAppEntry, String> {
        self.library
            .add_membership(&channel, &app_id, sort_order)
            .map_err(core_err)
            .map(AddedAppEntry::from)
    }

    /// Toggles membership and returns whether the app is now added.
    pub fn toggle(&self, channel: String, app: ChannelAppInfo) -> Result<bool, String> {
        let summary = app.into_summary()?;
        self.library.toggle(&channel, &summary).map_err(core_err)
    }

    /// Removes membership, keeping the channel's saved metadata row.
    pub fn remove(&self, channel: String, app_id: String) -> Result<bool, String> {
        self.library.remove(&channel, &app_id).map_err(core_err)
    }

    /// Returns one page of the unified read model, newest first.
    pub fn page(&self, offset: i64, limit: i64) -> Result<LibraryPage, String> {
        let offset = u32::try_from(offset.max(0)).unwrap_or(u32::MAX);
        let limit = u32::try_from(limit.max(0)).unwrap_or(u32::MAX);
        let (entries, total) = self.agg.aggregate_page(offset, limit).map_err(core_err)?;
        Ok(LibraryPage {
            entries: entries.into_iter().map(LibraryEntry::from).collect(),
            total: i64::try_from(total).unwrap_or(i64::MAX),
        })
    }

    /// Lists every membership row, newest first.
    pub fn list(&self) -> Result<Vec<AddedAppEntry>, String> {
        self.library
            .list()
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(AddedAppEntry::from).collect())
    }

    /// Lists one channel's membership rows, newest first.
    pub fn list_channel(&self, channel: String) -> Result<Vec<AddedAppEntry>, String> {
        self.library
            .list_channel(&channel)
            .map_err(core_err)
            .map(|apps| apps.into_iter().map(AddedAppEntry::from).collect())
    }

    /// Returns one membership row, if present.
    pub fn get(&self, channel: String, app_id: String) -> Result<Option<AddedAppEntry>, String> {
        self.library
            .get(&channel, &app_id)
            .map_err(core_err)
            .map(|app| app.map(AddedAppEntry::from))
    }

    /// Whether `(channel, app_id)` is a library member.
    pub fn is_added(&self, channel: String, app_id: String) -> Result<bool, String> {
        self.library.is_added(&channel, &app_id).map_err(core_err)
    }

    /// Total number of library members.
    pub fn total_count(&self) -> Result<i64, String> {
        self.library.total_count().map_err(core_err)
    }

    /// Number of library members in one channel.
    pub fn count_channel(&self, channel: String) -> Result<i64, String> {
        self.library.count_channel(&channel).map_err(core_err)
    }

    /// Sets one membership row's sort weight.
    pub fn set_order(
        &self,
        channel: String,
        app_id: String,
        sort_order: i64,
    ) -> Result<(), String> {
        self.library
            .set_order(&channel, &app_id, sort_order)
            .map_err(core_err)
    }

    /// Deletes every membership row in one channel.
    pub fn clear_channel(&self, channel: String) -> Result<i64, String> {
        self.library
            .clear_channel(&channel)
            .map_err(core_err)
            .map(|count| i64::try_from(count).unwrap_or(i64::MAX))
    }

    /// Deletes every membership row.
    pub fn clear_all(&self) -> Result<i64, String> {
        self.library
            .clear_all()
            .map_err(core_err)
            .map(|count| i64::try_from(count).unwrap_or(i64::MAX))
    }

    /// Replaces all tags for one app.
    pub fn set_tags(
        &self,
        channel: String,
        app_id: String,
        tags: Vec<String>,
    ) -> Result<(), String> {
        self.library
            .set_tags(&channel, &app_id, &tags)
            .map_err(core_err)
    }

    /// Adds one tag to an app.
    pub fn add_tag(&self, channel: String, app_id: String, tag: String) -> Result<(), String> {
        self.library
            .add_tag(&channel, &app_id, &tag)
            .map_err(core_err)
    }

    /// Removes one tag from an app.
    pub fn remove_tag(&self, channel: String, app_id: String, tag: String) -> Result<(), String> {
        self.library
            .remove_tag(&channel, &app_id, &tag)
            .map_err(core_err)
    }

    /// Returns one app's tags, earliest first.
    pub fn tags(&self, channel: String, app_id: String) -> Result<Vec<String>, String> {
        self.library.tags(&channel, &app_id).map_err(core_err)
    }

    /// Returns all tag buckets keyed by `"{channel}:{app_id}"`.
    pub fn tags_index(&self) -> Result<Vec<TagGroup>, String> {
        self.library
            .tags_index()
            .map_err(core_err)
            .map(|index| {
                index
                    .into_iter()
                    .map(|(key, tags)| TagGroup { key, tags })
                    .collect()
            })
    }

    /// Re-fetches metadata for membership rows missing a `channel_apps` row.
    ///
    /// Never deletes a membership row. `local_db` is skipped because its
    /// metadata lives in the `apps` catalog, not `channel_apps`.
    pub fn repair_missing_metadata(&self) -> Result<RepairReport, String> {
        let rows = self.library.list().map_err(core_err)?;
        let mut repaired = 0u32;
        let mut unresolved = 0u32;
        for row in rows {
            if row.channel_id == "local_db" {
                continue;
            }
            if self
                .fallback
                .get(&row.channel_id, &row.app_id)
                .map_err(core_err)?
                .is_some()
            {
                continue;
            }
            let Some(driver) = self.inner.driver(&row.channel_id) else {
                unresolved = unresolved.saturating_add(1);
                continue;
            };
            let Ok(detail) = driver.get_app_detail(&row.app_id, false) else {
                unresolved = unresolved.saturating_add(1);
                continue;
            };
            match driver.add_app(&summary_from_detail(detail)) {
                Ok(()) => repaired = repaired.saturating_add(1),
                Err(_) => unresolved = unresolved.saturating_add(1),
            }
        }
        Ok(RepairReport { repaired, unresolved })
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

/// Persisted update cache snapshot used by the Dart startup restore path.
///
/// The Rust core owns the authoritative cache; this DTO mirrors the same
/// `update_prefs` values the legacy Dart `UpdateCache` read from
/// SharedPreferences.
#[derive(Debug, Clone)]
pub struct CachedUpdateStateDto {
    pub last_checked_at: Option<i64>,
    pub updates_json: String,
    pub logs_json: String,
}

/// One progressive event of an update check (FRB stream item).
#[derive(Debug, Clone)]
pub struct UpdateProgressDto {
    pub total: i64,
    pub index: i64,
    pub app_id: String,
    pub app_name: String,
    pub icon_url: Option<String>,
    pub log_level: Option<String>,
    pub log_text: Option<String>,
    pub is_result: bool,
    pub names_json: Option<String>,
    pub finished: bool,
    pub error: Option<String>,
    pub checked_at: i64,
    pub updates_json: String,
    pub skipped_json: String,
    pub events_json: String,
    pub used_cache: bool,
}

fn check_log_level_code(level: CheckLogLevel) -> &'static str {
    match level {
        CheckLogLevel::Info => "info",
        CheckLogLevel::Installed => "installed",
        CheckLogLevel::Update => "update",
        CheckLogLevel::None => "none",
        CheckLogLevel::Skip => "skip",
        CheckLogLevel::Error => "error",
    }
}

fn update_progress_dto(progress: UpdateProgress) -> UpdateProgressDto {
    UpdateProgressDto {
        total: i64::try_from(progress.total).unwrap_or(i64::MAX),
        index: i64::try_from(progress.index).unwrap_or(i64::MAX),
        app_id: progress.app_id,
        app_name: progress.app_name,
        icon_url: progress.icon_url,
        log_level: progress.log_level.map(check_log_level_code).map(str::to_string),
        log_text: progress.log_text,
        is_result: progress.is_result,
        names_json: progress
            .names
            .and_then(|names| serde_json::to_string(&names).ok()),
        finished: false,
        error: None,
        checked_at: 0,
        updates_json: String::new(),
        skipped_json: String::new(),
        events_json: String::new(),
        used_cache: false,
    }
}

impl UpdateProgressDto {
    fn terminal(report: UpdateReport) -> Self {
        Self {
            total: report.total,
            index: report.total,
            app_id: String::new(),
            app_name: String::new(),
            icon_url: None,
            log_level: None,
            log_text: None,
            is_result: false,
            names_json: None,
            finished: true,
            error: None,
            checked_at: report.checked_at,
            updates_json: report.updates_json,
            skipped_json: report.skipped_json,
            events_json: report.events_json,
            used_cache: report.used_cache,
        }
    }

    fn failed(message: String) -> Self {
        Self {
            total: 0,
            index: 0,
            app_id: String::new(),
            app_name: String::new(),
            icon_url: None,
            log_level: None,
            log_text: None,
            is_result: false,
            names_json: None,
            finished: true,
            error: Some(message),
            checked_at: 0,
            updates_json: String::new(),
            skipped_json: String::new(),
            events_json: String::new(),
            used_cache: false,
        }
    }
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
    /// Opens the core database and binds the channel drivers. Update
    /// judgement reads the core-maintained inventory and facts.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<UpdateApi, String> {
        prepare_dirs(&data_dir, &files_dir, &cache_dir)?;
        let db = open_core_db(&data_dir)?;
        let channel_api = ChannelApi::init(data_dir, files_dir, cache_dir)?;
        let resolver = channel_api.resolver();
        Ok(Self {
            service: UpdateService::new(db, resolver),
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

    /// Streams per-app progress while running a full check.
    ///
    /// Emits start/app-start/app-result events, then one terminal event carrying
    /// the same report as [`Self::check`] (or a typed error). The Dart facade
    /// mirrors these events into the shared update page state so logs, the
    /// progress wheel and the current app icon update in real time.
    pub fn check_with_progress(
        &self,
        force: bool,
        sink: crate::frb_generated::StreamSink<UpdateProgressDto>,
    ) {
        let result = self.service.check_all_with_progress(force, |progress| {
            let _ = sink.add(update_progress_dto(progress));
        });
        let terminal = match result {
            Ok(report) => match encode_update_report(report) {
                Ok(report) => UpdateProgressDto::terminal(report),
                Err(error) => UpdateProgressDto::failed(error),
            },
            Err(error) => UpdateProgressDto::failed(core_err(error)),
        };
        let _ = sink.add(terminal);
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

    /// Returns the persisted result/log snapshot for startup cache restore.
    pub fn cached_state(&self) -> Result<CachedUpdateStateDto, String> {
        let updates = self.service.list().map_err(core_err)?;
        let logs = self.service.cached_logs().map_err(core_err)?;
        let last_checked_at = self.service.last_checked_at().map_err(core_err)?;
        Ok(CachedUpdateStateDto {
            last_checked_at,
            updates_json: serde_json::to_string(&updates)
                .map_err(|error| core_err(CoreError::Serialization(error.to_string())))?,
            logs_json: serde_json::to_string(&logs)
                .map_err(|error| core_err(CoreError::Serialization(error.to_string())))?,
        })
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

// ===========================================================================
// DownloadApi (Wave 3 Todo 2)
// ===========================================================================

use crate::download_host::{
    DownloadWatchState, HostDownloadPort, DOWNLOAD_MODULE_UNAVAILABLE_MARKER,
};
use gstore_core::download::port::{DownloadRequest, PortError};
use gstore_core::download::DownloadTaskRow;

const CORE_E_DOWNLOAD_INVALID_ARG: &str = "CORE_E_DOWNLOAD_INVALID_ARG";
const CORE_E_DOWNLOAD_MODULE: &str = "CORE_E_DOWNLOAD_MODULE";
const CORE_E_DOWNLOAD_MODULE_UNAVAILABLE: &str = "CORE_E_DOWNLOAD_MODULE_UNAVAILABLE";
const CORE_E_DOWNLOAD_DB: &str = "CORE_E_DOWNLOAD_DB";
const CORE_E_DOWNLOAD_UNKNOWN_TASK: &str = "CORE_E_DOWNLOAD_UNKNOWN_TASK";
const CORE_E_DOWNLOAD_NEEDS_RESTART: &str = "CORE_E_DOWNLOAD_NEEDS_RESTART";
const CORE_E_DOWNLOAD_IMPORT_DB: &str = "CORE_E_DOWNLOAD_IMPORT_DB";
const CORE_E_DOWNLOAD_IMPORT_INTERNAL: &str = "CORE_E_DOWNLOAD_IMPORT_INTERNAL";
const CORE_E_DOWNLOAD_RESYNC_CONFLICT: &str = "CORE_E_DOWNLOAD_RESYNC_CONFLICT";
const CORE_E_DOWNLOAD_RESYNC_DB: &str = "CORE_E_DOWNLOAD_RESYNC_DB";
const CORE_E_DOWNLOAD_RESYNC_INTERNAL: &str = "CORE_E_DOWNLOAD_RESYNC_INTERNAL";

/// Start request accepted by [`DownloadApi::start`] (FRB data class).
#[derive(Debug, Clone)]
pub struct DownloadStartRequest {
    pub app_id: String,
    pub app_name: String,
    pub version: String,
    pub file_name: String,
    pub url: String,
    pub dest_path: String,
    pub kind: String,
    pub resource_id: String,
    pub resource_version: String,
    pub dedup_key: String,
    pub expected_sha256: Option<String>,
    pub install_after_download: bool,
    /// Extra request headers forwarded to the module (UA/Accept-Language/...).
    pub headers: std::collections::HashMap<String, String>,
}

impl From<DownloadStartRequest> for DownloadRequest {
    fn from(request: DownloadStartRequest) -> Self {
        Self {
            app_id: request.app_id,
            app_name: request.app_name,
            version: request.version,
            file_name: request.file_name,
            url: request.url,
            dest_path: request.dest_path,
            kind: request.kind,
            resource_id: request.resource_id,
            resource_version: request.resource_version,
            dedup_key: request.dedup_key,
            expected_sha256: request.expected_sha256,
            install_after_download: request.install_after_download,
            headers: request.headers,
        }
    }
}

/// One `download_task` row crossing the FRB boundary (FRB data class).
#[derive(Debug, Clone, PartialEq)]
pub struct DownloadTaskDto {
    pub id: i64,
    pub module_task_id: Option<String>,
    pub dedup_key: Option<String>,
    pub app_id: Option<String>,
    pub app_name: Option<String>,
    pub version: Option<String>,
    pub file_name: Option<String>,
    pub kind: Option<String>,
    pub resource_id: Option<String>,
    pub resource_version: Option<String>,
    pub url: Option<String>,
    pub dest_path: Option<String>,
    pub status: String,
    pub bytes_done: i64,
    pub total: i64,
    pub speed_bps: i64,
    pub eta_sec: Option<i64>,
    pub segments_json: Option<String>,
    pub retries: i64,
    pub server_meta: Option<String>,
    pub priority: i64,
    pub headers_json: Option<String>,
    pub expected_sha256: Option<String>,
    pub install_after_download: bool,
    pub error: Option<String>,
    pub last_started_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

impl From<DownloadTaskRow> for DownloadTaskDto {
    fn from(row: DownloadTaskRow) -> Self {
        Self {
            id: row.id,
            module_task_id: row.module_task_id,
            dedup_key: row.dedup_key,
            app_id: row.app_id,
            app_name: row.app_name,
            version: row.version,
            file_name: row.file_name,
            kind: row.kind,
            resource_id: row.resource_id,
            resource_version: row.resource_version,
            url: row.url,
            dest_path: row.dest_path,
            status: row.status,
            bytes_done: row.bytes_done,
            total: row.total,
            speed_bps: row.speed_bps,
            eta_sec: row.eta_sec,
            segments_json: row.segments_json,
            retries: row.retries,
            server_meta: row.server_meta,
            priority: row.priority,
            headers_json: row.headers_json,
            expected_sha256: row.expected_sha256,
            install_after_download: row.install_after_download,
            error: row.error,
            last_started_at: row.last_started_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

/// Counters for one legacy source crossing the FRB boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationCountsDto {
    pub inserted: i64,
    pub updated: i64,
    pub skipped: i64,
}

/// One-shot import outcome for both legacy sources.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadImportReportDto {
    /// `None` when the Floor database was absent (see `skipped_missing`).
    pub floor: Option<MigrationCountsDto>,
    /// `None` when the download-module database was absent.
    pub module: Option<MigrationCountsDto>,
    /// Non-empty paths that did not exist and were skipped, never fatal.
    pub skipped_missing: Vec<String>,
}

impl From<gstore_core::download::legacy::MigrationReport> for MigrationCountsDto {
    fn from(report: gstore_core::download::legacy::MigrationReport) -> Self {
        Self {
            inserted: i64::try_from(report.inserted).unwrap_or(i64::MAX),
            updated: i64::try_from(report.updated).unwrap_or(i64::MAX),
            skipped: i64::try_from(report.skipped).unwrap_or(i64::MAX),
        }
    }
}

impl From<crate::download_host::LegacyImportReport> for DownloadImportReportDto {
    fn from(report: crate::download_host::LegacyImportReport) -> Self {
        Self {
            floor: report.floor.map(MigrationCountsDto::from),
            module: report.module.map(MigrationCountsDto::from),
            skipped_missing: report.skipped_missing,
        }
    }
}

/// Three-way download resync report (FRB data class).
///
/// `snapshot_path` is `None` in dry-run; every other field is meaningful in
/// both modes. See [`CoreApi::resync_downloads`] for the exact semantics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResyncReportDto {
    pub floor_rows: i64,
    pub module_rows: i64,
    pub core_rows: i64,
    pub matched: i64,
    pub updated: i64,
    pub missing: i64,
    pub conflicts: i64,
    pub needs_restart: i64,
    pub snapshot_path: Option<String>,
}

impl From<gstore_core::download::resync::ResyncReport> for ResyncReportDto {
    fn from(report: gstore_core::download::resync::ResyncReport) -> Self {
        let count = |value: usize| i64::try_from(value).unwrap_or(i64::MAX);
        Self {
            floor_rows: count(report.floor_rows),
            module_rows: count(report.module_rows),
            core_rows: count(report.core_rows),
            matched: count(report.matched),
            updated: count(report.updated),
            missing: count(report.missing),
            conflicts: count(report.conflicts),
            needs_restart: count(report.needs_restart),
            snapshot_path: report.snapshot_path,
        }
    }
}

fn resync_err(error: PortError) -> String {
    match error {
        PortError::ResyncConflict(message) => {
            format!("{CORE_E_DOWNLOAD_RESYNC_CONFLICT}: {message}")
        }
        PortError::Db(message) => format!("{CORE_E_DOWNLOAD_RESYNC_DB}: {message}"),
        PortError::Module(message) => {
            format!("{CORE_E_DOWNLOAD_RESYNC_INTERNAL}: module: {message}")
        }
        PortError::UnknownTask(id) => {
            format!("{CORE_E_DOWNLOAD_RESYNC_INTERNAL}: unknown task: {id}")
        }
        PortError::NeedsRestart(id) => {
            format!("{CORE_E_DOWNLOAD_RESYNC_INTERNAL}: needs restart: {id}")
        }
    }
}

fn import_err(error: PortError) -> String {
    match error {
        PortError::Db(message) => format!("{CORE_E_DOWNLOAD_IMPORT_DB}: {message}"),
        other => format!("{CORE_E_DOWNLOAD_IMPORT_INTERNAL}: {other}"),
    }
}

fn download_err(error: PortError) -> String {
    match error {
        PortError::Module(message) => {
            match message.strip_prefix(DOWNLOAD_MODULE_UNAVAILABLE_MARKER) {
                Some(detail) => format!("{CORE_E_DOWNLOAD_MODULE_UNAVAILABLE}: {detail}"),
                None => format!("{CORE_E_DOWNLOAD_MODULE}: {message}"),
            }
        }
        PortError::Db(message) => format!("{CORE_E_DOWNLOAD_DB}: {message}"),
        PortError::UnknownTask(id) => format!("{CORE_E_DOWNLOAD_UNKNOWN_TASK}: {id}"),
        PortError::NeedsRestart(id) => format!("{CORE_E_DOWNLOAD_NEEDS_RESTART}: {id}"),
        PortError::ResyncConflict(message) => {
            format!("{CORE_E_DOWNLOAD_RESYNC_CONFLICT}: {message}")
        }
    }
}

fn validate_task_id(module_task_id: &str) -> Result<(), String> {
    if module_task_id.trim().is_empty() {
        return Err(format!(
            "{CORE_E_DOWNLOAD_INVALID_ARG}: module_task_id must not be empty"
        ));
    }
    Ok(())
}

fn validate_start_request(request: &DownloadStartRequest) -> Result<(), String> {
    for (field, value) in [
        ("app_id", request.app_id.as_str()),
        ("file_name", request.file_name.as_str()),
        ("url", request.url.as_str()),
        ("dest_path", request.dest_path.as_str()),
    ] {
        if value.trim().is_empty() {
            return Err(format!(
                "{CORE_E_DOWNLOAD_INVALID_ARG}: {field} must not be empty"
            ));
        }
    }
    Ok(())
}

/// FRB facade over the Todo-1 [`HostDownloadPort`].
///
/// Mutations require a mounted download module; `list`/`snapshot`/`watchAll`
/// read the authoritative core rows bridge-free. Errors use the stable
/// `CORE_E_DOWNLOAD_*` prefixes.
#[frb(opaque)]
pub struct DownloadApi {
    port: Arc<HostDownloadPort>,
}

impl DownloadApi {
    /// Opens the core database and binds the download port.
    ///
    /// The one reconcile sweep is best-effort: a missing module is logged and
    /// never fails initialization.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<DownloadApi, String> {
        prepare_dirs(&data_dir, &files_dir, &cache_dir)?;
        let db = open_core_db(&data_dir)?;
        let conn = db.shared_writer();
        let core_db_path = gstore_core::db::core_db_path(Path::new(&data_dir));
        let port = HostDownloadPort::new(
            conn,
            core_db_path,
            PathBuf::from(&data_dir),
            PathBuf::from(&cache_dir),
        );
        if let Err(error) = port.reconcile() {
            crate::log_bridge::push_host_log(
                2,
                format!("download reconcile at init (non-fatal): {error}"),
            );
        }
        Ok(Self {
            port: Arc::new(port),
        })
    }

    /// Wraps an already-built port (integration tests only).
    #[frb(ignore)]
    #[doc(hidden)]
    pub fn from_port_for_test(port: HostDownloadPort) -> DownloadApi {
        Self {
            port: Arc::new(port),
        }
    }

    pub fn start(&self, request: DownloadStartRequest) -> Result<i64, String> {
        validate_start_request(&request)?;
        let request = DownloadRequest::from(request);
        self.port.start(&request).map_err(download_err)
    }

    pub fn list(&self) -> Result<Vec<DownloadTaskDto>, String> {
        self.port
            .list()
            .map_err(download_err)
            .map(|rows| rows.into_iter().map(DownloadTaskDto::from).collect())
    }

    pub fn get(&self, module_task_id: String) -> Result<Option<DownloadTaskDto>, String> {
        validate_task_id(&module_task_id)?;
        self.port
            .get(&module_task_id)
            .map_err(download_err)
            .map(|row| Some(DownloadTaskDto::from(row)))
    }

    pub fn pause(&self, module_task_id: String) -> Result<(), String> {
        validate_task_id(&module_task_id)?;
        self.port.pause(&module_task_id).map_err(download_err)
    }

    pub fn resume(&self, module_task_id: String) -> Result<(), String> {
        validate_task_id(&module_task_id)?;
        self.port.resume(&module_task_id).map_err(download_err)
    }

    pub fn cancel(&self, module_task_id: String) -> Result<(), String> {
        validate_task_id(&module_task_id)?;
        self.port.cancel(&module_task_id).map_err(download_err)
    }

    pub fn retry(&self, module_task_id: String) -> Result<(), String> {
        validate_task_id(&module_task_id)?;
        self.port.retry(&module_task_id).map_err(download_err)
    }

    pub fn restart(&self, module_task_id: String) -> Result<(), String> {
        validate_task_id(&module_task_id)?;
        self.port.restart(&module_task_id).map_err(download_err)
    }

    pub fn remove(&self, module_task_id: String) -> Result<(), String> {
        validate_task_id(&module_task_id)?;
        self.port.remove(&module_task_id).map_err(download_err)
    }

    /// One-shot, idempotent import of the legacy Floor and module databases.
    ///
    /// Missing databases are skipped and reported, never fatal. The core row
    /// always wins over a duplicate legacy row (`dedup_key`), so this is safe
    /// to call once per process before the first core-owned download.
    pub fn import_legacy(
        &self,
        floor_db_path: String,
        module_db_path: String,
    ) -> Result<DownloadImportReportDto, String> {
        self.port
            .import_legacy(Path::new(&floor_db_path), Path::new(&module_db_path))
            .map(DownloadImportReportDto::from)
            .map_err(import_err)
    }

    /// 500 ms polling stream over the authoritative core rows.
    ///
    /// Only changed rows are emitted; a terminal row is emitted exactly once
    /// (per-task terminal event) and the stream stays open for later tasks.
    /// The thread exits when Dart cancels the stream (`sink.add` errors) or the
    /// core read fails.
    pub fn watch_all(&self, sink: crate::frb_generated::StreamSink<DownloadTaskDto>) {
        let port = Arc::clone(&self.port);
        let spawned = std::thread::Builder::new()
            .name("gstore-download-watch".to_string())
            .spawn(move || {
                let mut state = DownloadWatchState::new();
                loop {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    let rows = match port.refresh_and_list() {
                        Ok(rows) => rows,
                        Err(error) => {
                            crate::log_bridge::push_host_log(
                                2,
                                format!("download watch stopped: {error}"),
                            );
                            return;
                        }
                    };
                    for dto in state.observe(rows) {
                        if sink.add(dto).is_err() {
                            return;
                        }
                    }
                }
            });
        if let Err(error) = spawned {
            crate::log_bridge::push_host_log(
                2,
                format!("download watch thread failed to start: {error}"),
            );
        }
    }
}

// ===========================================================================
// InstallApi (Wave 3 Todo 6)
// ===========================================================================

use gstore_core::install::service::{InstallRecord, InstallService};

const CORE_E_INSTALL_NOT_FOUND: &str = "CORE_E_INSTALL_NOT_FOUND";
const CORE_E_INSTALL_INVALID_ARG: &str = "CORE_E_INSTALL_INVALID_ARG";
const CORE_E_INSTALL_STATUS: &str = "CORE_E_INSTALL_STATUS";
const CORE_E_INSTALL_SESSION: &str = "CORE_E_INSTALL_SESSION";
const CORE_E_INSTALL_CONFLICT: &str = "CORE_E_INSTALL_CONFLICT";
const CORE_E_INSTALL_UNSUPPORTED: &str = "CORE_E_INSTALL_UNSUPPORTED";
const CORE_E_INSTALL_DB: &str = "CORE_E_INSTALL_DB";
const CORE_E_INSTALL_INTERNAL: &str = "CORE_E_INSTALL_INTERNAL";

fn install_err(error: CoreError) -> String {
    match error {
        CoreError::NotFound(message) => {
            if message.contains(CORE_E_INSTALL_SESSION) {
                format!("{CORE_E_INSTALL_SESSION}: {message}")
            } else {
                format!("{CORE_E_INSTALL_NOT_FOUND}: {message}")
            }
        }
        CoreError::InvalidArgument(message) => {
            format!("{CORE_E_INSTALL_INVALID_ARG}: {message}")
        }
        CoreError::Conflict(message) => format!("{CORE_E_INSTALL_CONFLICT}: {message}"),
        CoreError::Unsupported(message) => {
            format!("{CORE_E_INSTALL_UNSUPPORTED}: {message}")
        }
        CoreError::Io(message) | CoreError::Serialization(message) => {
            format!("{CORE_E_INSTALL_DB}: {message}")
        }
        CoreError::Internal(message) => {
            if message.contains("CORE_E_INSTALL_READ") || message.contains("CORE_E_INSTALL_WRITE") {
                format!("{CORE_E_INSTALL_DB}: {message}")
            } else {
                format!("{CORE_E_INSTALL_INTERNAL}: {message}")
            }
        }
        CoreError::Network(message) => {
            format!("{CORE_E_INSTALL_INTERNAL}: network: {message}")
        }
        CoreError::Unauthorized(message) => {
            format!("{CORE_E_INSTALL_INTERNAL}: unauthorized: {message}")
        }
        CoreError::Forbidden(message) => {
            format!("{CORE_E_INSTALL_INTERNAL}: forbidden: {message}")
        }
        CoreError::RateLimited(message) => {
            format!("{CORE_E_INSTALL_INTERNAL}: rate_limited: {message}")
        }
    }
}

/// One `download_task` install projection crossing the FRB boundary.
#[derive(Debug, Clone)]
pub struct InstallRecordDto {
    pub module_task_id: String,
    pub app_id: String,
    pub status: String,
    pub method: Option<String>,
    pub session_id: Option<String>,
    pub error: Option<String>,
    pub installed_at: Option<i64>,
    pub installed_version: Option<String>,
    pub install_after_download: bool,
}

impl From<InstallRecord> for InstallRecordDto {
    fn from(record: InstallRecord) -> Self {
        Self {
            module_task_id: record.module_task_id,
            app_id: record.app_id,
            status: record.status,
            method: record.method,
            session_id: record.session_id,
            error: record.error,
            installed_at: record.installed_at,
            installed_version: record.installed_version,
            install_after_download: record.install_after_download,
        }
    }
}

/// Download variant selected by the core.
#[derive(Debug, Clone)]
pub struct VariantChoiceDto {
    pub abi: String,
    pub url: String,
    pub fallback_chain: Vec<String>,
}

impl From<gstore_core::facts::VariantChoice> for VariantChoiceDto {
    fn from(variant: gstore_core::facts::VariantChoice) -> Self {
        Self {
            abi: variant.abi,
            url: variant.url,
            fallback_chain: variant.fallback_chain,
        }
    }
}

/// Durable install request the frontend must execute.
#[derive(Debug, Clone)]
pub struct InstallRequestDto {
    pub module_task_id: String,
    pub session_id: String,
    pub package_name: String,
    pub version_name: String,
    pub apk_path: String,
    pub method: String,
    pub variant: VariantChoiceDto,
}

impl From<gstore_core::facts::InstallRequest> for InstallRequestDto {
    fn from(request: gstore_core::facts::InstallRequest) -> Self {
        Self {
            module_task_id: request.module_task_id,
            session_id: request.session_id,
            package_name: request.package_name,
            version_name: request.version_name,
            apk_path: request.apk_path,
            method: request.method,
            variant: request.variant.into(),
        }
    }
}

/// Result of [`InstallApi::install`]: a settled record and/or a request.
#[derive(Debug, Clone)]
pub struct InstallStartDto {
    pub record: InstallRecordDto,
    pub request: Option<InstallRequestDto>,
}

impl From<gstore_core::facts::InstallStart> for InstallStartDto {
    fn from(start: gstore_core::facts::InstallStart) -> Self {
        Self {
            record: start.record.into(),
            request: start.request.map(Into::into),
        }
    }
}

/// Terminal report sent back by the frontend installer.
#[derive(Debug, Clone)]
pub struct InstallReportDto {
    pub session_id: String,
    /// `installed` | `failed` | `denied` | `timeout` (normalized host-side).
    pub status: String,
    pub method: String,
    pub installed_version: Option<String>,
    pub error: Option<String>,
    pub reported_at: i64,
}

/// Acknowledgement of one install report.
#[derive(Debug, Clone)]
pub struct InstallResultAckDto {
    pub session_id: String,
    pub status: String,
    pub changed: bool,
}

impl From<gstore_core::facts::InstallResultAck> for InstallResultAckDto {
    fn from(ack: gstore_core::facts::InstallResultAck) -> Self {
        Self {
            session_id: ack.session_id,
            status: ack.status,
            changed: ack.changed,
        }
    }
}

fn parse_report_status(raw: &str) -> Result<gstore_core::facts::InstallReportStatus, String> {
    use gstore_core::facts::InstallReportStatus;
    match raw.trim().to_ascii_lowercase().as_str() {
        "installed" => Ok(InstallReportStatus::Installed),
        "failed" => Ok(InstallReportStatus::Failed),
        "denied" => Ok(InstallReportStatus::Denied),
        "timeout" => Ok(InstallReportStatus::Timeout),
        other => Err(format!(
            "{CORE_E_INSTALL_STATUS}: unsupported report status '{other}' \
             (expected installed|failed|denied|timeout)"
        )),
    }
}

/// FRB facade over the durable core [`InstallService`].
///
/// The core owns the install state machine on `download_task`. Dart calls
/// [`InstallApi::install`] to obtain an [`InstallRequestDto`] (or a settled
/// record), executes it, then calls [`InstallApi::report_result`]. The timeout
/// sweep is read-driven: it runs inside `install`, `pendingRequests`, and init —
/// never on a background thread.
#[frb(opaque)]
pub struct InstallApi {
    service: Arc<InstallService>,
}

impl InstallApi {
    /// Opens the core database, binds the durable install service, and runs one
    /// read-driven timeout sweep.
    ///
    /// The sweep is never fatal; a failure is logged and initialization still
    /// succeeds.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<InstallApi, String> {
        prepare_dirs(&data_dir, &files_dir, &cache_dir)?;
        let db = open_core_db(&data_dir)?;
        let service = Arc::new(InstallService::new(db.shared_writer()));
        match service.sweep_timeouts(now_millis()) {
            Ok(events) if !events.is_empty() => crate::log_bridge::push_host_log(
                2,
                format!("install sweep at init: {} expired", events.len()),
            ),
            Ok(_) => {}
            Err(error) => crate::log_bridge::push_host_log(
                2,
                format!("install sweep at init (non-fatal): {error}"),
            ),
        }
        Ok(Self { service })
    }

    /// Wraps an already-built service (integration tests only).
    #[frb(ignore)]
    #[doc(hidden)]
    pub fn from_service_for_test(service: InstallService) -> InstallApi {
        Self {
            service: Arc::new(service),
        }
    }

    /// Reads the durable install record for `module_task_id`.
    ///
    /// Returns `None` when no `download_task` row exists for the id.
    pub fn get(&self, module_task_id: String) -> Result<Option<InstallRecordDto>, String> {
        if module_task_id.trim().is_empty() {
            return Err(format!(
                "{CORE_E_INSTALL_INVALID_ARG}: module_task_id must not be empty"
            ));
        }
        match self.service.get(&module_task_id) {
            Ok(record) => Ok(Some(InstallRecordDto::from(record))),
            Err(CoreError::NotFound(_)) => Ok(None),
            Err(error) => Err(install_err(error)),
        }
    }

    /// Starts (or observes) an install for `module_task_id`.
    ///
    /// Exactly one of `record.status == "installed"` or `request.is_some()` is
    /// true.
    pub fn install(&self, module_task_id: String) -> Result<InstallStartDto, String> {
        self.service
            .install(&module_task_id)
            .map(InstallStartDto::from)
            .map_err(install_err)
    }

    /// Lists every still-pending install request after sweeping expired rows.
    ///
    /// Dart re-derives the auto-install path from this list, so a process
    /// restart never loses a request.
    pub fn pending_requests(&self) -> Result<Vec<InstallStartDto>, String> {
        self.service
            .sweep_timeouts(now_millis())
            .map_err(install_err)?;
        self.service
            .pending_requests()
            .map(|starts| starts.into_iter().map(InstallStartDto::from).collect())
            .map_err(install_err)
    }

    /// Applies an installer result and returns the durable acknowledgement.
    ///
    /// A duplicate terminal report is accepted idempotently with
    /// `changed: false`. Bad report statuses fail with `CORE_E_INSTALL_STATUS`;
    /// an unknown session fails with `CORE_E_INSTALL_SESSION`.
    pub fn report_result(
        &self,
        report: InstallReportDto,
    ) -> Result<InstallResultAckDto, String> {
        let status = parse_report_status(&report.status)?;
        let report = gstore_core::facts::InstallReport {
            session_id: report.session_id,
            status,
            method: report.method,
            installed_version: report.installed_version,
            error: report.error,
            reported_at: report.reported_at,
        };
        self.service
            .on_result(report)
            .map(InstallResultAckDto::from)
            .map_err(install_err)
    }

    /// Drains queued install events (`install.requested` / `install.unknown`)
    /// as JSON strings.
    ///
    /// Dart polls this after `install` and `pendingRequests`; when a completed
    /// download has `install_after_download=1`, an `install.requested` entry
    /// carries the request to execute.
    pub fn take_events(&self) -> Result<Vec<String>, String> {
        self.service
            .take_events()
            .into_iter()
            .map(|event| event.to_json().map_err(install_err))
            .collect()
    }
}

// ===========================================================================
// ScriptApi / UiApi (Wave 5 Todo 5)
// ===========================================================================

pub use crate::script_pack::ScriptPackInfo;

/// FRB facade for the Rust-hosted JS channel lane.
///
/// Owns the local pack store and a per-channel runtime cache. The Dart lane is
/// responsible for gating this API behind `CoreFlags.jsChannel`; this facade
/// never flips a flag and never touches Dart channel wiring.
#[frb(opaque)]
pub struct ScriptApi {
    inner: std::sync::Arc<crate::script_api::ScriptApiInner>,
}

impl ScriptApi {
    /// Opens the core database and binds the pack store.
    ///
    /// Safe to call more than once against the same directories.
    pub fn init(
        data_dir: String,
        files_dir: String,
        cache_dir: String,
    ) -> Result<ScriptApi, String> {
        crate::script_api::ScriptApiInner::init(data_dir, files_dir, cache_dir)
            .map(|inner| Self {
                inner: std::sync::Arc::new(inner),
            })
    }

    /// Installs one legacy flat pack from zip bytes.
    ///
    /// New packs are decoded with [`gstore_core::channel::PackPolicy::Strict`].
    /// When strict decoding fails — including on a first import — the pack is
    /// retried with the legacy-permissive policy, and the accepted key plus the
    /// strict failure reason are logged so the fallback is never silent. Unsafe
    /// paths and oversized packs still fail under both policies. `expected_key`
    /// is the channel key (`js_<stem>`); a bare `<stem>` is accepted too. When
    /// omitted, a stable content-hash key is generated.
    pub fn import(
        &self,
        pack_zip_bytes: Vec<u8>,
        expected_key: Option<String>,
    ) -> Result<ScriptPackInfo, String> {
        let info = self.inner.import(pack_zip_bytes, expected_key)?;
        push_channel_changed_str(&info.key, ChannelKind::JsLocal);
        Ok(info)
    }

    /// Removes an installed pack, its cached runtimes, and its channel env.
    pub fn remove(&self, key: String) -> Result<(), String> {
        self.inner.remove(&key)?;
        push_channel_changed_str(&key, ChannelKind::JsLocal);
        Ok(())
    }

    /// Reloads a pack from its installed directory and rebuilds its runtimes.
    pub fn refresh(&self, key: String) -> Result<ScriptPackInfo, String> {
        let info = self.inner.refresh(&key)?;
        push_channel_changed_str(&info.key, ChannelKind::JsLocal);
        Ok(info)
    }

    /// Replaces the channel env snapshot and hot-updates live runtimes.
    pub fn set_env(
        &self,
        key: String,
        env: std::collections::HashMap<String, String>,
    ) -> Result<(), String> {
        self.inner.set_env(&key, env)?;
        push_channel_changed_str(&key, ChannelKind::JsLocal);
        Ok(())
    }

    /// Returns the persisted channel env snapshot for `key` as a JSON object
    /// string (`{"NAME":"value",...}`, `{}` when nothing is stored).
    ///
    /// The read counterpart of [`Self::set_env`]: it reads the same Rust store
    /// the script sees — the plaintext `channel_env` row plus the
    /// `channel.<key>.<NAME>` secrets — so the UI can echo back configured
    /// environment variables without mirroring secrets into the Flutter
    /// `ConfigStore`. It never spawns the pack runtime and an unknown/never-saved
    /// key returns `{}` rather than an error.
    pub fn env(&self, key: String) -> Result<String, String> {
        self.inner.env(&key)
    }

    /// Replaces the channel config snapshot read by `host.config.get`.
    ///
    /// Mirrors [`Self::set_env`]: the snapshot is scoped to `key` (the channel /
    /// pack instance) and hot-updates live runtimes. Each map value is a JSON
    /// document, so a string value is passed quoted (`"\"sit\""`), a number as
    /// `"42"`, and an object as `"{\"a\":1}"`. A key that was never injected (or
    /// was injected as JSON `null`) resolves to `null`, never a fabricated value.
    /// Invalid JSON is rejected as `invalid_argument` without changing the map.
    pub fn set_config(
        &self,
        key: String,
        config: std::collections::HashMap<String, String>,
    ) -> Result<(), String> {
        self.inner.set_config(&key, config)?;
        push_channel_changed_str(&key, ChannelKind::JsLocal);
        Ok(())
    }

    /// Internal pack-data engine — **not** a Dart-facing entry point.
    ///
    /// Runs `main(method, params)` on the pack's entry/detail runtime and
    /// returns the raw JSON result string (the same JSON the old Dart runtime
    /// received). The Dart data path no longer calls this: JS channel data is
    /// read through `ChannelApi` / `RustChannelFacade` (the JS runtime authority
    /// is `ChannelApiInner.script_drivers`, plus the per-call `ScriptDetail`).
    /// The method is therefore kept off the FRB surface (`#[frb(ignore)]`) and
    /// reachable only from the in-crate script-api tests.
    #[frb(ignore)]
    #[doc(hidden)]
    pub fn run(
        &self,
        key: String,
        method: String,
        params_json: String,
    ) -> Result<String, String> {
        self.inner.run(&key, &method, &params_json)
    }

    /// Lists installed packs in deterministic key order (diagnostics).
    pub fn list(&self) -> Result<Vec<ScriptPackInfo>, String> {
        self.inner.list()
    }

    /// Returns the saved `channel_apps` rows for `key` as a JSON array string.
    ///
    /// Store-only: this is Dart `JsChannel.getAllApps` semantics and never calls
    /// the script or the network.
    pub fn stored_apps(&self, key: String) -> Result<String, String> {
        self.inner.stored_apps(&key)
    }

    /// Inserts one app into `key`'s saved `channel_apps` rows.
    ///
    /// This is the script-lane counterpart to `ChannelApi::add_app`: it writes
    /// through the Rust script pack store — the same rows [`Self::stored_apps`]
    /// reads — so a `js_*` pack never has to be registered as a channels-domain
    /// channel. `key` must name an installed pack (`js_<stem>`): an unknown key
    /// is a typed `pack_not_found` error and an empty `app.app_id` is
    /// `invalid_argument`.
    pub fn add_app(&self, key: String, app: ChannelAppInfo) -> Result<(), String> {
        self.inner.add_app(&key, app.into_summary()?)?;
        push_channel_changed_str(&key, ChannelKind::JsLocal);
        Ok(())
    }

    /// Releases the `detail.js` runtime bound to `(key, app_id)`.
    ///
    /// Mirrors Dart `JsChannel.releaseDetailChannel`: idempotent, and the next
    /// detail call for that app gets a fresh, isolated runtime.
    pub fn release_detail(&self, key: String, app_id: String) -> Result<(), String> {
        self.inner.release_detail(&key, &app_id)
    }
}

/// FRB facade for answering `script.ui_request`.
#[frb(opaque)]
pub struct UiApi;

impl UiApi {
    #[frb(init)]
    pub fn new() -> Self {
        Self
    }

    /// Delivers the UI answer for `request_id`.
    ///
    /// `payload_json` is the JSON value the script's `host.ui.call` resolves to
    /// (`null` is valid). Unknown or expired ids return the typed
    /// `CORE_E_SCRIPT_UI_UNKNOWN_REQUEST` error.
    pub fn respond(&self, request_id: String, payload_json: String) -> Result<(), String> {
        crate::ui_api::respond(&request_id, &payload_json)
    }
}

impl Default for UiApi {
    fn default() -> Self {
        Self::new()
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
                version_name: None,
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
            labels: Vec::new(),
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
        assert_eq!(second.list().unwrap().len(), 5);
        assert_eq!(gstore_core::flags::flags(), before_flags);
        assert!(!gstore_core::flags::flags().channels);

        seed_localdb(api);

        // list/get
        let entries = api.list().expect("list");
        assert_eq!(entries.len(), 5, "built-in channels: {entries:?}");
        assert!(entries.iter().any(|entry| entry.key == "local_db"));
        assert!(entries.iter().any(|entry| entry.key == "gstore"));
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
        assert_eq!(api.list().unwrap().len(), 6);

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
        let all_apps = api
            .list_apps("local_db".to_string(), false)
            .expect("list_apps");
        assert_eq!(all_apps.len(), 1);
        assert_eq!(all_apps[0].app_id, "com.example.alpha");
        assert!(!api
            .check_update("local_db".to_string())
            .expect("check_update"));
        let missing_channel_apps = api
            .list_apps("js_contract".to_string(), false)
            .expect_err("registered channel without a driver must be typed");
        println!("channel_api_contract: no-driver list_apps error = {missing_channel_apps}");
        assert!(
            missing_channel_apps.starts_with("not_found:"),
            "{missing_channel_apps}"
        );
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

    const SCRIPT_UPDATE_ENTRY: &str = r#"
async function main(method, params) {
  if (method === 'checkAppUpdate') {
    return { ok: true, data: {
      appId: 'com.example.alpha',
      packageName: 'com.example.alpha',
      name: 'Alpha',
      version: '3.0.0',
      downloads: [{
        url: 'https://js.test/alpha-3.0.0.apk',
        name: 'alpha-3.0.0.apk',
        version: '3.0.0',
      }],
    } };
  }
  return null;
}
"#;

    fn write_script_pack(path: &Path, entry: &str) {
        let file = std::fs::File::create(path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        writer.start_file("entry.js", options).unwrap();
        writer.write_all(entry.as_bytes()).unwrap();
        writer.finish().unwrap();
    }

    #[test]
    fn channel_api_script_lane_binds_the_update_driver() {
        let harness = harness("script_lane");
        let api = &harness.api;
        let pack = harness.root.join("demo.zip");
        write_script_pack(&pack, SCRIPT_UPDATE_ENTRY);
        let info = api
            .import_pack(pack.to_string_lossy().into_owned())
            .expect("import script pack");
        assert_eq!(info.key, "js_demo");

        let resolver = api.resolver();
        let driver = resolver("js_demo")
            .expect("an unregistered script pack is reachable through the resolver fallback");
        let update = driver
            .check_app_update("com.example.alpha")
            .expect("the script returns an update");
        assert_eq!(update.latest_version.as_deref(), Some("3.0.0"));
        assert_eq!(
            update
                .detail
                .downloads
                .first()
                .map(|download| download.name.as_str()),
            Some("alpha-3.0.0.apk")
        );

        let registration = ChannelRegistration {
            key: "js_demo".to_string(),
            kind: "js_local".to_string(),
            name: "Demo".to_string(),
            description: "script channel".to_string(),
            enabled: true,
            priority: 9,
            support_offline: false,
            version: Some("1".to_string()),
        };
        api.register(registration).expect("register js_local");
        assert!(
            api.list_apps("js_demo".to_string(), false).is_ok(),
            "registering a js_local channel binds its script driver"
        );
        drop(harness);
    }

    const SCRIPT_DETAIL_JS: &str = r#"
function main(method, params) {
  if (method === 'versionOptions') {
    return { ok: true, data: {
      title: '选择版本',
      envs: ['sit', 'prod'],
      versions: [
        { version: '2.0.0', envs: ['sit'], buildCount: 3 },
        { version: '1.0.0', envs: ['sit', 'prod'], buildCount: 5 },
      ],
      currentEnv: 'sit',
      currentVersion: '1.0.0',
      packOnly: 'keep-me',
    } };
  }
  if (method === 'getAppDetail') {
    return { ok: true, data: {
      appId: params.appId,
      name: 'Demo',
      icon: 'icon.png',
      description: 'detail.js intro',
      version: '1.0.0',
      packageName: 'com.example.demo',
      sections: ['downloads', 'screenshots'],
      screenshots: ['https://js.test/shot-1.png'],
      downloads: [{
        url: 'https://js.test/demo-1.0.0.apk',
        name: 'demo-1.0.0.apk',
        version: '1.0.0',
        extra: { size: { icon: 'sd_card', text: '10 MB' } },
      }],
      extra: { env: 'sit' },
    } };
  }
  if (method === 'switchVersion') {
    return { ok: true, data: {
      appId: params.appId,
      name: 'Demo',
      icon: 'icon.png',
      description: 'switched detail',
      version: '1.0.0',
      packageName: 'com.example.demo',
      sections: ['downloads'],
      downloads: [{ url: 'https://js.test/demo-1.0.0.apk', name: 'demo-1.0.0.apk', version: '1.0.0' }],
      extra: { env: 'sit', version: '1.0.0' },
    } };
  }
  if (method === 'buildHistory') {
    return { ok: true, data: { builds: [
      { num: 7, publishedAt: '2026-01-02T03:04:05Z', size: 12345, changelog: 'fix', installTimes: 9, builtBy: 'ci', ipaName: 'demo-7.apk' },
      { num: 6, publishedAt: null, size: null, changelog: '', installTimes: null },
    ] } };
  }
  if (method === 'detailMenu') {
    return { ok: true, data: [
      { action: '切换版本', jscall: 'jsswitchVersion', clickIsDimiss: true },
      { action: '', jscall: 'jsBuildHistory', icon: 'history' },
    ] };
  }
  return null;
}
"#;

    fn write_detail_pack(path: &Path, detail: &str) {
        let file = std::fs::File::create(path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        writer.start_file("entry.js", options).unwrap();
        writer
            .write_all(b"module.exports = function () { return {}; };")
            .unwrap();
        writer.start_file("detail.js", options).unwrap();
        writer.write_all(detail.as_bytes()).unwrap();
        writer.finish().unwrap();
    }

    #[test]
    fn channel_api_script_detail_surface() {
        let harness = harness("script_detail_surface");
        let api = &harness.api;
        let pack = harness.root.join("detail_demo.zip");
        write_detail_pack(&pack, SCRIPT_DETAIL_JS);
        let info = api
            .import_pack(pack.to_string_lossy().into_owned())
            .expect("import detail pack");
        assert_eq!(info.key, "js_detail_demo");

        let options = api
            .script_version_options(
                "js_detail_demo".to_string(),
                "com.example.demo".to_string(),
                None,
                Some("1.0.0".to_string()),
            )
            .expect("version options")
            .expect("version options present");
        assert_eq!(options.title.as_deref(), Some("选择版本"));
        assert_eq!(options.envs, vec!["sit".to_string(), "prod".to_string()]);
        assert_eq!(options.versions.len(), 2);
        assert_eq!(options.versions[0].version, "2.0.0");
        assert_eq!(options.versions[0].build_count, 3);
        assert_eq!(options.current_env.as_deref(), Some("sit"));
        assert_eq!(options.current_version.as_deref(), Some("1.0.0"));
        assert!(options.extra_json.contains("packOnly"), "{}", options.extra_json);

        let detail = api
            .script_switch_version(
                "js_detail_demo".to_string(),
                "com.example.demo".to_string(),
                "sit".to_string(),
                "1.0.0".to_string(),
                Some("{\"num\":7,\"ipaName\":\"demo-7.apk\"}".to_string()),
            )
            .expect("switch version")
            .expect("switch version present");
        assert_eq!(detail.app_id, "com.example.demo");
        assert_eq!(detail.version.as_deref(), Some("1.0.0"));
        assert_eq!(detail.package_name.as_deref(), Some("com.example.demo"));
        assert_eq!(detail.channel, "js_local");
        assert_eq!(detail.downloads.len(), 1);
        assert_eq!(detail.downloads[0].name, "demo-1.0.0.apk");

        let builds = api
            .script_build_history(
                "js_detail_demo".to_string(),
                "com.example.demo".to_string(),
                "sit".to_string(),
                "1.0.0".to_string(),
            )
            .expect("build history");
        assert_eq!(builds.len(), 2);
        assert_eq!(builds[0].num, 7);
        assert_eq!(
            builds[0].published_at.as_deref(),
            Some("2026-01-02T03:04:05Z")
        );
        assert_eq!(builds[0].size, Some(12345));
        assert_eq!(builds[0].install_times, Some(9));
        assert_eq!(builds[0].changelog.as_deref(), Some("fix"));
        assert!(builds[0].extra_json.contains("ipaName"), "{}", builds[0].extra_json);
        assert!(builds[0].extra_json.contains("builtBy"), "{}", builds[0].extra_json);
        assert_eq!(builds[1].num, 6);
        assert_eq!(builds[1].published_at, None);
        assert_eq!(builds[1].size, None);

        let menu = api
            .script_detail_menu("js_detail_demo".to_string(), "com.example.demo".to_string())
            .expect("detail menu");
        assert_eq!(menu.len(), 2);
        assert_eq!(menu[0].action, "切换版本");
        assert_eq!(menu[0].jscall, "jsswitchVersion");
        assert_eq!(menu[0].click_is_dimiss, Some(true));
        assert_eq!(menu[0].icon, None);
        assert_eq!(menu[1].action, "");
        assert_eq!(menu[1].jscall, "jsBuildHistory");
        assert_eq!(menu[1].icon.as_deref(), Some("history"));
        assert_eq!(menu[1].click_is_dimiss, None);

        drop(harness);
    }

    /// Given a pack whose `detail.js` answers `getAppDetail`, When the detail
    /// page's initial load runs, Then `script_get_app_detail` reads detail.js
    /// (sections/screenshots/download tags present) instead of entry.js.
    #[test]
    fn channel_api_script_get_app_detail_uses_detail_js() {
        let harness = harness("script_detail_init");
        let api = &harness.api;
        let pack = harness.root.join("detail_init.zip");
        write_detail_pack(&pack, SCRIPT_DETAIL_JS);
        api.import_pack(pack.to_string_lossy().into_owned())
            .expect("import detail pack");

        let detail = api
            .script_get_app_detail(
                "js_detail_init".to_string(),
                "com.example.demo".to_string(),
            )
            .expect("initial detail")
            .expect("initial detail present");
        assert_eq!(detail.description, "detail.js intro");
        assert_eq!(detail.version.as_deref(), Some("1.0.0"));
        assert!(
            detail.sections.contains(&"downloads".to_string()),
            "{:?}",
            detail.sections
        );
        assert!(
            detail.sections.contains(&"screenshots".to_string()),
            "{:?}",
            detail.sections
        );
        assert_eq!(detail.downloads.len(), 1);
        assert!(
            detail.downloads[0]
                .extra_json
                .as_deref()
                .unwrap_or_default()
                .contains("sd_card"),
            "{:?}",
            detail.downloads[0].extra_json
        );

        drop(harness);
    }

    #[test]
    fn channel_api_script_unknown_pack_not_found() {
        let harness = harness("script_unknown_pack");
        let api = &harness.api;

        let version_err = api
            .script_version_options(
                "js_does_not_exist".to_string(),
                "com.example.demo".to_string(),
                None,
                None,
            )
            .expect_err("unknown pack must be typed");
        println!("channel_api_script_unknown_pack_not_found: versionOptions error = {version_err}");
        assert!(version_err.starts_with("not_found:"), "{version_err}");
        assert!(!version_err.starts_with("pack_not_found:"), "{version_err}");

        let switch_err = api
            .script_switch_version(
                "js_does_not_exist".to_string(),
                "com.example.demo".to_string(),
                "sit".to_string(),
                "1.0.0".to_string(),
                None,
            )
            .expect_err("unknown pack must be typed");
        assert!(switch_err.starts_with("not_found:"), "{switch_err}");

        let init_err = api
            .script_get_app_detail(
                "js_does_not_exist".to_string(),
                "com.example.demo".to_string(),
            )
            .expect_err("unknown pack must be typed");
        assert!(init_err.starts_with("not_found:"), "{init_err}");

        let history_err = api
            .script_build_history(
                "js_does_not_exist".to_string(),
                "com.example.demo".to_string(),
                "sit".to_string(),
                "1.0.0".to_string(),
            )
            .expect_err("unknown pack must be typed");
        assert!(history_err.starts_with("not_found:"), "{history_err}");

        let menu_err = api
            .script_detail_menu("js_does_not_exist".to_string(), "com.example.demo".to_string())
            .expect_err("unknown pack must be typed");
        assert!(menu_err.starts_with("not_found:"), "{menu_err}");

        drop(harness);
    }

    const SCRIPT_DETAIL_ACTION_JS: &str = r#"
function main(method, params) {
  if (method === 'jsAction') {
    var res = host.ui.call('showUAPicker', {});
    return { ok: true, data: true };
  }
  return null;
}
"#;

    #[test]
    fn channel_api_script_detail_action_runs_pack_jscall() {
        let _serial = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::script_api_test_support::clear_ui_state();
        let harness = harness("script_detail_action");
        let api = &harness.api;
        let pack = harness.root.join("detail_action.zip");
        write_detail_pack(&pack, SCRIPT_DETAIL_ACTION_JS);
        let info = api
            .import_pack(pack.to_string_lossy().into_owned())
            .expect("import action pack");
        assert_eq!(info.key, "js_detail_action");

        // The responder answers the pack's `host.ui.call('showUAPicker', {})`.
        let responder = crate::script_api_test_support::spawn_responder(
            "showUAPicker",
            "{}".to_string(),
            std::time::Duration::ZERO,
            None,
        );

        api.script_detail_action(
            "js_detail_action".to_string(),
            "com.example".to_string(),
            "jsAction".to_string(),
        )
        .expect("script_detail_action must run the pack jscall and return Ok");

        let answered = responder
            .join()
            .expect("responder thread")
            .expect("the `showUAPicker` request must be emitted and answered");
        println!(
            "channel_api_script_detail_action_runs_pack_jscall: showUAPicker request_id = {}",
            answered.0
        );

        // Failure path: an unknown pack is a typed `not_found`, never `pack_not_found`.
        let err = api
            .script_detail_action(
                "js_does_not_exist".to_string(),
                "com.example".to_string(),
                "jsAction".to_string(),
            )
            .expect_err("unknown pack must be typed");
        println!("channel_api_script_detail_action_runs_pack_jscall: unknown pack error = {err}");
        assert!(err.starts_with("not_found:"), "{err}");
        assert!(!err.starts_with("pack_not_found:"), "{err}");

        drop(harness);
    }

    const SCRIPT_LANE_ENTRY: &str = r#"
function main(method, params) {
  if (method === 'searchApps' || method === 'getAllApps') {
    return { ok: true, data: [{
      appId: 'com.example.demo', name: 'Demo', packageName: 'com.example.demo',
      version: '1.0.0', des: 'demo app',
    }] };
  }
  if (method === 'getAppDetail') {
    return { ok: true, data: { appId: params.appId, name: 'Demo', version: '1.0.0' } };
  }
  return null;
}
"#;

    #[test]
    fn channel_api_driver_resolves_unregistered_script_pack() {
        let harness = harness("driver_unregistered_pack");
        let api = &harness.api;
        let pack = harness.root.join("lane.zip");
        write_script_pack(&pack, SCRIPT_LANE_ENTRY);
        api.import_pack(pack.to_string_lossy().into_owned())
            .expect("import");

        // No register(...) call: the pack is NOT in the channels-domain registry.
        assert!(
            api.get("js_lane".to_string()).is_err(),
            "pack must be unregistered"
        );

        let hits = api
            .search("js_lane".to_string(), "Demo".to_string(), false)
            .expect("search resolves an unregistered js_ pack");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].app_id, "com.example.demo");

        let detail = api
            .get_app_detail(
                "js_lane".to_string(),
                "com.example.demo".to_string(),
                false,
            )
            .expect("get_app_detail resolves an unregistered js_ pack");
        assert_eq!(detail.app_id, "com.example.demo");

        // Failure path: unknown pack -> typed not_found, never pack_not_found.
        let err = api
            .search("js_missing".to_string(), "x".to_string(), false)
            .unwrap_err();
        assert!(err.starts_with("not_found:"), "{err}");
        assert!(!err.starts_with("pack_not_found:"), "{err}");

        drop(harness);
    }

    /// Given a fresh channel registration, When it succeeds, Then exactly one
    /// `channel.changed` event carrying the registered key and kind is on the
    /// event ring (asserted on the wire name and the payload fields, not merely
    /// that "some" event was pushed).
    #[test]
    fn channel_changed_pushed() {
        let _serial = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        crate::event_bridge::clear_buffer_for_tests();
        let harness = harness("emit_channel");
        let api = &harness.api;

        let entry = api
            .register(ChannelRegistration {
                key: "probe_channel".to_string(),
                kind: "custom".to_string(),
                name: "Probe".to_string(),
                description: "emit probe".to_string(),
                enabled: true,
                priority: 7,
                support_offline: false,
                version: None,
            })
            .expect("register");
        assert_eq!(entry.kind, "custom");

        let (event_type, body) = crate::event_bridge::last_event_for_tests()
            .expect("register must emit a channel.changed event");
        assert_eq!(event_type, "channel.changed");
        let value: serde_json::Value = serde_json::from_slice(&body).expect("event body is JSON");
        assert_eq!(value["event"], "channel.changed");
        assert_eq!(value["payload"]["key"], "probe_channel");
        assert_eq!(value["payload"]["kind"], "custom");

        // A no-op mutation (removing an absent env var) must not emit.
        crate::event_bridge::clear_buffer_for_tests();
        assert!(
            !api.env_remove("probe_channel".to_string(), "MISSING".to_string())
                .expect("env_remove"),
            "removing an absent env var is a no-op"
        );
        assert!(
            crate::event_bridge::last_event_for_tests().is_none(),
            "a no-op mutation must not emit channel.changed"
        );
        drop(harness);
    }

    /// Given a source catalog that differs from the core, When
    /// `CatalogApi::refresh` runs, Then it returns the sync result AND pushes a
    /// `catalog.changed` event for the local catalog on the same event ring.
    #[test]
    fn catalog_changed_pushed() {
        let _serial = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let root = temp_root("emit_catalog");
        let data = root.join("data");
        std::fs::create_dir_all(&data).unwrap();
        let db = open_core_db(data.to_str().unwrap()).expect("open core db");
        let service = gstore_core::catalog::service::CatalogService::new(db.clone())
            .expect("catalog service");

        let source = root.join("source.db");
        {
            let conn = rusqlite::Connection::open(&source).unwrap();
            conn.execute_batch(
                "CREATE TABLE apps(appId TEXT PRIMARY KEY, name TEXT NOT NULL, user TEXT, \
                 repositories TEXT, icon TEXT, des TEXT, category TEXT); \
                 CREATE TABLE category(id TEXT PRIMARY KEY, description TEXT NOT NULL, icon TEXT NOT NULL); \
                 CREATE TABLE config(version TEXT PRIMARY KEY); \
                 INSERT INTO apps VALUES ('com.alpha','Alpha','u','r','i','d','TOOLS'); \
                 INSERT INTO category VALUES ('TOOLS','Tools','t'); \
                 INSERT INTO config VALUES ('1.0');",
            )
            .unwrap();
        }
        let body = std::fs::read(&source).unwrap();
        let http = FakeHttpPort::new();
        http.push_response(gstore_core::ports::HttpResponse {
            status: 200,
            headers: Vec::new(),
            body,
        });
        let api = CatalogApi {
            db,
            service,
            http: Arc::new(http),
            repo: CatalogRepo::new(root.join("catalog_repo")).expect("catalog repo"),
        };

        crate::event_bridge::clear_buffer_for_tests();
        let result = api
            .refresh("https://example.invalid/catalog.db".to_string())
            .expect("refresh");
        assert!(result.changed, "the fixture must change the catalog");

        let (event_type, body) = crate::event_bridge::last_event_for_tests()
            .expect("refresh must emit a catalog.changed event");
        assert_eq!(event_type, "catalog.changed");
        let value: serde_json::Value = serde_json::from_slice(&body).expect("event body is JSON");
        assert_eq!(value["event"], "catalog.changed");
        assert_eq!(value["payload"]["key"], "local_db");
        assert!(value["payload"]["app_id"].is_null());
        assert_eq!(value["payload"]["removed"], false);

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Given an installed pack, When a script-domain `add_app` write runs, Then
    /// a `channel.changed` event for that pack key (kind `js_local`) is pushed —
    /// the script-domain store is not a silent bypass of the event seam.
    #[test]
    fn script_domain_write_pushes_channel_changed() {
        let _serial = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let root = temp_root("emit_script");
        let api = ScriptApi::init(
            root.join("data").to_string_lossy().into_owned(),
            root.join("files").to_string_lossy().into_owned(),
            root.join("cache").to_string_lossy().into_owned(),
        )
        .expect("ScriptApi::init");
        api.import(
            crate::script_api_test_support::zip_with("function main(){ return null; }", None, None),
            Some("js_evt".to_string()),
        )
        .expect("import pack");

        crate::event_bridge::clear_buffer_for_tests();
        api.add_app("js_evt".to_string(), app_input())
            .expect("add_app");

        let (event_type, body) = crate::event_bridge::last_event_for_tests()
            .expect("add_app must emit a channel.changed event");
        assert_eq!(event_type, "channel.changed");
        let value: serde_json::Value = serde_json::from_slice(&body).expect("event body is JSON");
        assert_eq!(value["event"], "channel.changed");
        assert_eq!(value["payload"]["key"], "js_evt");
        assert_eq!(value["payload"]["kind"], "js_local");

        let _ = std::fs::remove_dir_all(&root);
    }

    /// Given a live channel facade with no GitHub token, When the token is
    /// applied and later cleared, Then the secret store and in-memory config
    /// both follow and the channel drivers are rebound without error.
    #[test]
    fn set_github_token_updates_secret_and_live_config() {
        let _serial = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let harness = harness("github_token_sync");
        assert!(harness
            .api
            .inner
            .github_config()
            .expect("config")
            .github_token()
            .is_none());

        harness
            .api
            .set_github_token(Some("  token-abc  ".to_string()))
            .expect("set token");
        assert_eq!(
            harness
                .api
                .inner
                .github_config()
                .expect("config")
                .github_token(),
            Some("token-abc")
        );
        assert_eq!(
            harness
                .api
                .inner
                .secrets
                .get("core_config.github_token")
                .expect("secret get")
                .as_deref(),
            Some("token-abc")
        );
        harness.api.get("github".to_string()).expect("driver rebound");

        harness.api.set_github_token(None).expect("clear token");
        assert!(harness
            .api
            .inner
            .github_config()
            .expect("config")
            .github_token()
            .is_none());
        assert!(harness
            .api
            .inner
            .secrets
            .get("core_config.github_token")
            .expect("secret get")
            .is_none());

        harness
            .api
            .set_github_token(Some("   ".to_string()))
            .expect("blank token clears");
        assert!(harness
            .api
            .inner
            .github_config()
            .expect("config")
            .github_token()
            .is_none());

        let _ = std::fs::remove_dir_all(&harness.root);
    }

    /// Given a `channel_apps` F-Droid row migrated before the source list was
    /// known (legacy identity in `source_id`, repo-relative icon), When the
    /// enabled source set is published, Then the row is healed in place so the
    /// home icon resolves without depending on `source_id`.
    #[test]
    fn set_fdroid_sources_repairs_migrated_source_identity() {
        let harness = harness("fdroid_source_repair");
        let app_id = "com.example.migrated";
        harness
            .api
            .inner
            .db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,\
                     description,category,add_time,source_id,extra) \
                     VALUES ('fdroid',?1,'Migrated','',?1,'icons/com.example.migrated.png',\
                     'description','Tools',1000,'official',NULL)",
                    [app_id],
                )
                .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
                Ok(())
            })
            .expect("seed migrated row");

        harness
            .api
            .set_fdroid_sources(vec![
                r#"{"id":"official","name":"Official","url":"https://f-droid.org/repo","mirrors":[],"mirror_first":false,"enabled":true}"#
                    .to_string(),
            ])
            .expect("publish fdroid sources");

        let (icon, source_id): (String, Option<String>) = harness
            .api
            .inner
            .db
            .with_reader(|conn| {
                conn.query_row(
                    "SELECT icon, source_id FROM channel_apps \
                     WHERE channel_key='fdroid' AND app_id=?1",
                    [app_id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .map_err(|error| gstore_core::db::DbError(error.to_string()))
            })
            .expect("read repaired row");

        assert_eq!(
            source_id.as_deref(),
            Some("https://f-droid.org/repo"),
            "the legacy identity key must become the configured source URL"
        );
        assert_eq!(
            icon,
            "https://f-droid.org/repo/icons/com.example.migrated.png",
            "the stored icon must be absolute"
        );

        let _ = std::fs::remove_dir_all(&harness.root);
    }

    /// Given a stored F-Droid row whose icon still carries the prefix of a
    /// mirror that is no longer the current source, When the source set is
    /// published with that mirror listed, Then the home read resolves the icon
    /// against the CURRENT source instead of leaking the stale prefix.
    #[test]
    fn set_fdroid_sources_rebases_a_stale_mirror_icon_on_home() {
        let harness = harness("fdroid_icon_rebase");
        let app_id = "com.example.stale";
        harness
            .api
            .inner
            .db
            .with_writer(|conn| {
                conn.execute(
                    "INSERT INTO channel_apps(channel_key,app_id,name,user,repositories,icon,\
                     description,category,add_time,source_id,extra) \
                     VALUES ('fdroid',?1,'Stale','',?1,\
                     'https://old-mirror.example/repo/icons/com.example.stale.png',\
                     'description','Tools',1000,NULL,NULL)",
                    [app_id],
                )
                .map_err(|error| gstore_core::db::DbError(error.to_string()))?;
                Ok(())
            })
            .expect("seed stale-icon row");

        harness
            .api
            .set_fdroid_sources(vec![
                r#"{"id":"official","name":"Official","url":"https://f-droid.org/repo","mirrors":["https://old-mirror.example/repo"],"mirror_first":false,"enabled":true}"#
                    .to_string(),
            ])
            .expect("publish fdroid sources");

        let apps = harness
            .api
            .list_apps("fdroid".to_string(), false)
            .expect("list fdroid apps");
        assert_eq!(apps.len(), 1, "the stored row must never be dropped");
        assert_eq!(
            apps[0].icon,
            "https://f-droid.org/repo/icons/com.example.stale.png",
            "the icon must be re-based onto the current source"
        );

        let _ = std::fs::remove_dir_all(&harness.root);
    }

    /// Given two `ChannelApi::init` handles on the same directories, When the
    /// first handle publishes an F-Droid source with mirrors, Then the second
    /// handle's download candidates contain those mirrors — both handles share
    /// one inner, one `HostRepoPort` and one `DbHandle` (defect D-B).
    #[test]
    fn two_inits_share_fdroid_sources() {
        let _serial = crate::TEST_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        reset_global_inners();
        let root = temp_root("two_inits_share_sources");
        let data = root.join("data").to_string_lossy().into_owned();
        let files = root.join("files").to_string_lossy().into_owned();
        let cache = root.join("cache").to_string_lossy().into_owned();

        let first =
            ChannelApi::init(data.clone(), files.clone(), cache.clone()).expect("first init");
        let second = ChannelApi::init(data, files, cache).expect("second init");

        assert!(
            Arc::ptr_eq(&first.inner, &second.inner),
            "a repeated init on the same dirs must reuse the cached inner"
        );
        assert!(
            Arc::ptr_eq(&first.inner.repo, &second.inner.repo),
            "both handles must share one RepoPort, so only one HostRepoPort is created"
        );
        assert_eq!(
            first.inner.repo.db_path(),
            second.inner.repo.db_path(),
            "both handles must point at the same repo.db"
        );

        let source = "https://f-droid.org/repo";
        let mirror = "https://mirror.example/repo";
        first
            .set_fdroid_sources(vec![
                r#"{"id":"official","name":"Official","url":"https://f-droid.org/repo","mirrors":["https://mirror.example/repo"],"mirror_first":true,"enabled":true}"#
                    .to_string(),
            ])
            .expect("publish fdroid sources");

        // Probed on the SECOND handle's source set — the same lock instance its
        // HostRepoPort::mirrors_for reads to build the download candidate list.
        let (mirrors, mirror_first) = mirrors_from(&second.inner.fdroid_sources, source);
        assert_eq!(
            mirrors,
            vec![mirror.to_string()],
            "mirrors set through handle A must reach handle B's download candidates"
        );
        assert!(mirror_first, "the shared spec must keep mirror_first");
        assert_eq!(
            mirrors_from(&second.inner.fdroid_sources, mirror),
            (vec![mirror.to_string()], true),
            "a mirror URL must resolve to the same spec on handle B"
        );

        reset_global_inners();
        let _ = std::fs::remove_dir_all(&root);
    }

    /// Given a `HostRepoPort` whose repo.db cannot be opened, When a batched
    /// icon read runs over an empty package list, Then it fails inside
    /// `with_port` rather than returning the trait default's empty `Ok` — the
    /// override delegates to `ModuleRepoPort::get_app_icons` on the same port
    /// seam as `get_one_app`. The one-RPC-per-page proof is
    /// `repo_port::tests::get_app_icons_makes_one_module_call_for_twenty_packages`.
    #[test]
    fn host_repo_port_get_app_icons_delegates_through_with_port() {
        let root = temp_root("host_repo_port_icons");
        let blocked = root.join("not_a_dir");
        std::fs::write(&blocked, b"").unwrap();
        let specs: Arc<RwLock<Vec<FdroidSourceSpec>>> = Arc::new(RwLock::new(Vec::new()));
        let port = HostRepoPort::new(&blocked, Arc::clone(&specs));
        let source = "https://f-droid.org/repo";

        let batch_error = port
            .get_app_icons(source, &[])
            .expect_err("the batched read must build the port, not short-circuit to Ok");
        let single_error = port
            .get_one_app(source, "org.example.app0")
            .expect_err("the per-app read must fail on the same unusable repo.db");
        assert_eq!(
            batch_error, single_error,
            "both reads must fail at the same port-build step"
        );

        let _ = std::fs::remove_dir_all(&root);
    }
}
