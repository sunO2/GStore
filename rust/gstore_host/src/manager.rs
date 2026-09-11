// 宿主模块管理：注册表 + GStoreModule trait（架构文档第 4 章）
//
// 单 .so 过渡期：ModuleEntry.module 直接是 Arc<dyn GStoreModule>（假模块/未来域模块
// 都是 trait 实现）；拆分为独立 .so 时补 DlModuleAdapter 包装 C ABI 表，Dart API 不变。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

use gstore_contract::envelope::{EnvelopeRequest, EnvelopeResponse};
use gstore_contract::error::{ModuleError, StatusCode, ERR_MODULE_NOT_FOUND};

/// 模块统一接口（单 .so 内所有域模块实现此 trait；多 .so 由 DlModuleAdapter 转发）
pub trait GStoreModule: Send + Sync {
    fn name(&self) -> &'static str;

    /// 创建实例，返回模块内部管理的句柄（u64 id，不跨边界传裸指针）
    fn create(&self, config: &[u8]) -> Result<u64, ModuleError>;

    /// 静态调用（instance == None）或多实例调用（instance == Some(id)）
    fn call(
        &self,
        instance: Option<u64>,
        method: &str,
        payload: &[u8],
    ) -> Result<Vec<u8>, ModuleError>;

    /// 销毁实例（幂等：不存在的实例返回 Ok）
    fn destroy(&self, instance: u64) -> Result<(), ModuleError>;

    /// 模块级清理（refcount 归零时调用）
    fn shutdown(&self) {}
}

/// 注册表条目
pub struct ModuleEntry {
    pub name: String,
    pub module: Arc<dyn GStoreModule>,
    pub refcount: AtomicU64, // 当前 Dart 侧持有的 ModuleHandle 数
    pub persistent: bool,    // 常驻模块（preload）：refcount 归零也不卸载
}

/// 全局模块注册表（宿主唯一实例）
pub struct ModuleManager {
    modules: RwLock<HashMap<u64, ModuleEntry>>,
    by_name: RwLock<HashMap<String, u64>>,
    next_module_id: AtomicU64,
}

static MANAGER: std::sync::OnceLock<ModuleManager> = std::sync::OnceLock::new();

impl ModuleManager {
    /// 独立实例（测试用；生产代码统一用 global()）
    pub fn new() -> Self {
        Self {
            modules: RwLock::new(HashMap::new()),
            by_name: RwLock::new(HashMap::new()),
            next_module_id: AtomicU64::new(1),
        }
    }

    pub fn global() -> &'static Self {
        MANAGER.get_or_init(ModuleManager::new)
    }

    /// 注册模块（返回 module_id）。同名模块重复注册：refcount+1 复用（幂等）
    pub fn register(&self, module: Arc<dyn GStoreModule>) -> u64 {
        self.register_inner(module, false)
    }

    /// 预注册常驻模块（preload）：refcount 归零也不卸载。
    /// 用于高依赖状态的核心域（repo：SQLite 句柄必须常驻，避免意外 shutdown 丢连接）。
    pub fn register_preload(&self, module: Arc<dyn GStoreModule>) -> u64 {
        self.register_inner(module, true)
    }

    fn register_inner(&self, module: Arc<dyn GStoreModule>, persistent: bool) -> u64 {
        let name = module.name().to_string();
        if let Some(id) = self.by_name.read().unwrap().get(&name) {
            let id = *id;
            let exists = self.modules.read().unwrap().contains_key(&id);
            if exists {
                // 写锁：升级 persistent（若原非常驻）+ refcount+1
                if let Some(entry) = self.modules.write().unwrap().get_mut(&id) {
                    if persistent {
                        entry.persistent = true;
                    }
                    entry.refcount.fetch_add(1, Ordering::SeqCst);
                }
                return id;
            }
        }
        let id = self.next_module_id.fetch_add(1, Ordering::SeqCst);
        self.modules.write().unwrap().insert(
            id,
            ModuleEntry {
                name: name.clone(),
                module,
                refcount: AtomicU64::new(1),
                persistent,
            },
        );
        self.by_name.write().unwrap().insert(name, id);
        id
    }

    /// 引用计数减一；归零时移除并调用 shutdown（.so 保持驻留，仅回收状态）。
    /// 常驻模块（persistent）refcount 归零也不卸载（只复位 refcount）。
    pub fn unref(&self, module_id: u64) {
        let should_shutdown = {
            let read = self.modules.read().unwrap();
            match read.get(&module_id) {
                Some(entry) if !entry.persistent => {
                    let remaining = entry.refcount.fetch_sub(1, Ordering::SeqCst);
                    remaining <= 1
                }
                Some(entry) if entry.persistent => {
                    // 常驻：refcount 归零后复位为 1（始终保持"已挂载"状态）
                    entry.refcount.fetch_update(
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                        |rc| if rc <= 1 { Some(1) } else { Some(rc - 1) },
                    );
                    false
                }
                _ => false,
            }
        };
        if should_shutdown {
            if let Some(entry) = self.modules.write().unwrap().remove(&module_id) {
                self.by_name.write().unwrap().remove(&entry.name);
                entry.module.shutdown();
            }
        }
    }

    pub fn is_loaded(&self, module_id: u64) -> bool {
        self.modules.read().unwrap().contains_key(&module_id)
    }

    /// 按模块名获取 module_id（用于桥面按名路由）
    pub fn module_id_by_name(&self, name: &str) -> Option<u64> {
        self.by_name.read().unwrap().get(name).copied()
    }

    /// 按名加载模块（桥面入口）。单 .so 过渡期：模块编译期静态注册，
    /// 此处仅查找 + refcount+1；未注册报 MODULE_NOT_FOUND（未来多 .so 在此扩展 dlopen 逻辑）。
    pub fn register_by_name(&self, name: &str) -> Result<u64, ModuleError> {
        let id = self
            .module_id_by_name(name)
            .ok_or_else(|| ModuleError::module_not_found(name))?;
        if let Some(entry) = self.modules.read().unwrap().get(&id) {
            entry.refcount.fetch_add(1, Ordering::SeqCst);
        }
        Ok(id)
    }

    /// 从 .so 动态加载模块（P2 多 .so 场景）：dlopen + 握手 + 注册。
    /// 幂等：同名模块已注册则 refcount+1 复用。
    pub fn load_module_from_so(&self, so_path: &std::path::Path) -> Result<u64, ModuleError> {
        let adapter = crate::dl_adapter::DlModuleAdapter::load(so_path)
            .map_err(|e| ModuleError::internal(format!("dlopen adapter failed: {e}")))?;
        let name = adapter.name().to_string();

        // 幂等：同名已注册 → 复用
        if let Some(id) = self.module_id_by_name(&name) {
            if let Some(entry) = self.modules.read().unwrap().get(&id) {
                entry.refcount.fetch_add(1, Ordering::SeqCst);
                return Ok(id);
            }
        }

        let id = self.next_module_id.fetch_add(1, Ordering::SeqCst);
        self.modules.write().unwrap().insert(
            id,
            ModuleEntry {
                name: name.clone(),
                module: Arc::new(adapter),
                refcount: AtomicU64::new(1),
                persistent: false,
            },
        );
        self.by_name.write().unwrap().insert(name, id);
        Ok(id)
    }

    /// 创建实例：module_id → 模块 create() → 返回模块内部实例句柄
    pub fn call_create(&self, module_id: u64, config: &[u8]) -> Result<u64, ModuleError> {
        let module = self
            .modules
            .read()
            .unwrap()
            .get(&module_id)
            .map(|e| e.module.clone())
            .ok_or_else(|| ModuleError::new(StatusCode::ModuleNotFound, ERR_MODULE_NOT_FOUND, "module not found"))?;
        module.create(config)
    }

    /// 统一调用入口：路由到模块（信封处理由调用方负责，本函数只转发原始字节）
    pub fn call(
        &self,
        module_id: u64,
        instance: Option<u64>,
        method: &str,
        payload: &[u8],
    ) -> Result<Vec<u8>, ModuleError> {
        let module = self
            .modules
            .read()
            .unwrap()
            .get(&module_id)
            .map(|e| e.module.clone())
            .ok_or_else(|| ModuleError::new(StatusCode::ModuleNotFound, ERR_MODULE_NOT_FOUND, "module not found"))?;
        module.call(instance, method, payload)
    }

    pub fn call_destroy(&self, module_id: u64, instance: u64) -> Result<(), ModuleError> {
        let module = self
            .modules
            .read()
            .unwrap()
            .get(&module_id)
            .map(|e| e.module.clone())
            .ok_or_else(|| ModuleError::new(StatusCode::ModuleNotFound, ERR_MODULE_NOT_FOUND, "module not found"))?;
        module.destroy(instance)
    }

    /// 信封级调用：解包 EnvelopeRequest → 转发 → 封包 EnvelopeResponse（统一错误收敛）
    pub fn call_envelope(&self, request_bytes: &[u8]) -> Vec<u8> {
        let request = match EnvelopeRequest::decode(request_bytes) {
            Ok(r) => r,
            Err(e) => return EnvelopeResponse::err("", &e).encode().unwrap_or_default(),
        };
        let module_id = self
            .by_name
            .read()
            .unwrap()
            .get(request.module())
            .copied();
        let result = match module_id {
            Some(id) => {
                let instance = if request.instance().is_empty() {
                    None
                } else {
                    request.instance().parse::<u64>().ok()
                };
                self.call(id, instance, request.method(), request.payload())
            }
            None => Err(ModuleError::module_not_found(request.module())),
        };
        match result {
            Ok(payload) => EnvelopeResponse::ok(request.request_id(), payload),
            Err(e) => EnvelopeResponse::err(request.request_id(), &e),
        }
        .encode()
        .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试用假模块：实例 = 计数器
    struct CounterModule;

    impl GStoreModule for CounterModule {
        fn name(&self) -> &'static str {
            "test_counter"
        }
        fn create(&self, _config: &[u8]) -> Result<u64, ModuleError> {
            Ok(1)
        }
        fn call(&self, instance: Option<u64>, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
            match method {
                "echo" => Ok(payload.to_vec()),
                "whoami" => Ok(format!("inst={:?}", instance).into_bytes()),
                _ => Err(ModuleError::method_not_found(method)),
            }
        }
        fn destroy(&self, _instance: u64) -> Result<(), ModuleError> {
            Ok(())
        }
    }

    #[test]
    fn register_and_call_via_trait() {
        let mgr = ModuleManager::new();
        let id = mgr.register(Arc::new(CounterModule));
        assert!(mgr.is_loaded(id));
        let out = mgr.call(id, Some(7), "echo", b"hello").unwrap();
        assert_eq!(out, b"hello");
        let out = mgr.call(id, Some(7), "whoami", &[]).unwrap();
        assert_eq!(out, b"inst=Some(7)");
        mgr.unref(id);
        assert!(!mgr.is_loaded(id));
    }

    #[test]
    fn register_is_idempotent_by_name() {
        let mgr = ModuleManager::new();
        let id1 = mgr.register(Arc::new(CounterModule));
        let id2 = mgr.register(Arc::new(CounterModule));
        assert_eq!(id1, id2); // 同名复用
        // 清理（首次 unref 后 refcount 从 2 到 1，未卸载）
        mgr.unref(id1);
        assert!(mgr.is_loaded(id1));
        mgr.unref(id2);
        assert!(!mgr.is_loaded(id2));
    }

    #[test]
    fn call_envelope_routes_by_name_and_unifies_errors() {
        let mgr = ModuleManager::new();
        mgr.register(Arc::new(CounterModule));
        let req = EnvelopeRequest::new("test_counter", Some("7"), "echo", b"ping".to_vec());
        let resp_bytes = mgr.call_envelope(&req.encode().unwrap());
        let resp = EnvelopeResponse::decode(&resp_bytes).unwrap();
        assert!(resp.is_ok());
        assert_eq!(resp.payload(), b"ping");

        // 未知模块 → 404 信封
        let req = EnvelopeRequest::new("nope", None, "x", vec![]);
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert_eq!(resp.status(), 404);
        assert_eq!(resp.error_code(), ERR_MODULE_NOT_FOUND);
    }

    /// 全链路假模块：带真实实例状态（config 缓存）+ 方法分发 + 计数器
    struct DemoModule;

    impl GStoreModule for DemoModule {
        fn name(&self) -> &'static str {
            "demo"
        }
        fn create(&self, config: &[u8]) -> Result<u64, ModuleError> {
            // 实例 ID 由模块内部分配（架构 5.4：instance_id 归模块管理）
            Ok(config.first().copied().unwrap_or(0) as u64)
        }
        fn call(&self, instance: Option<u64>, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
            match method {
                "ping" => Ok(b"pong".to_vec()),
                "echo" => Ok(payload.to_vec()),
                "instance" => match instance {
                    Some(id) => Ok(format!("instance={id}").into_bytes()),
                    None => Ok(b"no-instance".to_vec()),
                },
                _ => Err(ModuleError::method_not_found(method)),
            }
        }
        fn destroy(&self, _instance: u64) -> Result<(), ModuleError> {
            Ok(())
        }
    }

    /// 全链路验证（对应架构 5.5 生命周期状态机）：
    /// register → load（按名，幂等 refcount）→ create → call → destroy → refcount 归零卸载
    #[test]
    fn full_lifecycle_register_load_create_call_destroy() {
        let mgr = ModuleManager::new();

        // 1. 编译期注册（静态注册；多 .so 场景这里换成 dlopen 握手）
        let mod_id = mgr.register(Arc::new(DemoModule));
        assert!(mgr.is_loaded(mod_id));

        // 2. 按名加载（桥面入口）：refcount 1 → 2
        let loaded_id = mgr.register_by_name("demo").unwrap();
        assert_eq!(loaded_id, mod_id);
        assert!(mgr.is_loaded(loaded_id));

        // 3. 创建实例（config=42 → instance_id=42，模块内部分配）
        let inst = mgr.call_create(loaded_id, &[42]).unwrap();
        assert_eq!(inst, 42);

        // 4. 实例调用（携带 instance_id）
        let out = mgr.call(loaded_id, Some(inst), "instance", &[]).unwrap();
        assert_eq!(out, b"instance=42");

        // 5. 静态调用（无实例）
        let out = mgr.call(loaded_id, None, "ping", &[]).unwrap();
        assert_eq!(out, b"pong");

        // 6. 信封级调用（按模块名路由）
        let req = EnvelopeRequest::new("demo", Some("42"), "echo", b"hello".to_vec());
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert!(resp.is_ok());
        assert_eq!(resp.payload(), b"hello");

        // 7. 销毁实例（幂等）
        mgr.call_destroy(loaded_id, inst).unwrap();

        // 8. 释放模块引用：refcount 2 → 1（仍加载）→ 0（卸载）
        mgr.unref(mod_id);
        assert!(mgr.is_loaded(mod_id));
        mgr.unref(loaded_id);
        assert!(!mgr.is_loaded(mod_id));

        // 9. 卸载后按名加载 → MODULE_NOT_FOUND
        let err = mgr.register_by_name("demo").unwrap_err();
        assert_eq!(err.status as i32, 404);
    }

    /// preload 常驻模块：refcount 归零也不卸载（repo 场景）
    #[test]
    fn preload_module_survives_unref() {
        let mgr = ModuleManager::new();
        let id = mgr.register_preload(Arc::new(DemoModule));
        assert!(mgr.is_loaded(id));

        // 持有多引用后逐级释放
        let id2 = mgr.register_by_name("demo").unwrap();
        mgr.unref(id2);
        assert!(mgr.is_loaded(id)); // 还有引用
        mgr.unref(id);
        // 常驻：refcount 归零后仍保持挂载，且可再次按名加载
        assert!(mgr.is_loaded(id));
        let id3 = mgr.register_by_name("demo").unwrap();
        assert_eq!(id3, id);
        mgr.unref(id3);
        assert!(mgr.is_loaded(id));
    }
}
