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

    /// 清空日志/事件桥的订阅 sink。引擎在同进程内被销毁重建时，宿主仍持有指向
    /// 上一个 Dart isolate 的失效端口；新 isolate 应在订阅前调用本函数。
    pub fn reset_bridges(&self) {
        crate::log_bridge::clear_sink();
        crate::event_bridge::clear_sink();
    }
}

