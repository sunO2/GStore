// Flutter FFI Bridge - 暴露给 Dart 的接口
use flutter_rust_bridge::frb;
use super::models::*;

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

/// 模块事件数据类（架构文档 6.8；普通数据类，跨模块 re-export 可被 FRB 跟随）
pub use crate::event_bridge::ModuleEvent;

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
    pub module_id: u64,
    pub instance_id: u64,
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
}

