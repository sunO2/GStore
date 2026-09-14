// 宿主模块管理：注册表 + GStoreModule trait（架构文档第 4 章）
//
// 注册表用单一 RwLock<Registry> 收敛 modules + by_name，避免双锁维护与潜在锁序问题；
// 锁访问统一走 read()/write()（毒化自愈，宿主 panic=abort，绝不让一次 unwrap 拖垮进程）。
// 单 .so 过渡期：模块经 register() 编译期静态注册；多 .so 场景经 load_module_from_so()
// 走 DlModuleAdapter 包装 C ABI 表，Dart API 不变。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock, RwLockReadGuard, RwLockWriteGuard};
use std::time::Duration;

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

    /// 模块功能版本（默认 1；DlModuleAdapter 覆盖为握手回报的 api.version）
    fn version(&self) -> u32 {
        1
    }

    /// 请求取消某次在途调用（默认无操作；有长任务的模块可覆盖，如 repo 下载）
    fn cancel(&self, instance: Option<u64>, request_id: &str) -> Result<(), ModuleError> {
        let _ = (instance, request_id);
        Ok(())
    }

    /// 宿主下发应用事件给模块（下行订阅；默认忽略，模块按需覆盖）
    fn on_event(&self, module_id: u64, kind: &str, data: &[u8]) -> Result<(), ModuleError> {
        let _ = (module_id, kind, data);
        Ok(())
    }

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

/// 已加载模块快照（供 UI/诊断只读展示）
#[derive(Clone, Debug)]
pub struct ModuleInfo {
    pub id: u64,
    pub name: String,
    pub version: u32,
    pub persistent: bool,
    pub refcount: u64,
}

/// 在途调用（供 cancel 路由；同步调用期间登记，返回后注销）
struct InflightCall {
    instance: Option<u64>,
}

/// 单一注册表：modules + by_name 同锁维护，任何变更只走一条插入/删除路径
#[derive(Default)]
struct Registry {
    modules: HashMap<u64, ModuleEntry>,
    by_name: HashMap<String, u64>,
}

/// 全局模块注册表（宿主唯一实例）
pub struct ModuleManager {
    registry: RwLock<Registry>,
    /// request_id → 在途调用（cancel 路由用）
    inflight: RwLock<HashMap<String, InflightCall>>,
    next_module_id: AtomicU64,
}

static MANAGER: std::sync::OnceLock<ModuleManager> = std::sync::OnceLock::new();

impl ModuleManager {
    /// 独立实例（测试用；生产代码统一用 global()）
    pub fn new() -> Self {
        Self {
            registry: RwLock::new(Registry::default()),
            inflight: RwLock::new(HashMap::new()),
            next_module_id: AtomicU64::new(1),
        }
    }

    pub fn global() -> &'static Self {
        MANAGER.get_or_init(ModuleManager::new)
    }

    /// 读锁（毒化自愈：持有者 panic 不应让后续所有访问连带失败）
    fn read(&self) -> RwLockReadGuard<'_, Registry> {
        self.registry.read().unwrap_or_else(|e| e.into_inner())
    }

    /// 写锁（毒化自愈）
    fn write(&self) -> RwLockWriteGuard<'_, Registry> {
        self.registry.write().unwrap_or_else(|e| e.into_inner())
    }

    fn inflight_read(&self) -> RwLockReadGuard<'_, HashMap<String, InflightCall>> {
        self.inflight.read().unwrap_or_else(|e| e.into_inner())
    }

    fn inflight_write(&self) -> RwLockWriteGuard<'_, HashMap<String, InflightCall>> {
        self.inflight.write().unwrap_or_else(|e| e.into_inner())
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

    /// 唯一插入路径：同名复用（+refcount，必要时升级 persistent）/ 否则新建
    fn register_inner(&self, module: Arc<dyn GStoreModule>, persistent: bool) -> u64 {
        let name = module.name().to_string();
        let mut reg = self.write();
        if let Some(&id) = reg.by_name.get(&name) {
            if let Some(entry) = reg.modules.get_mut(&id) {
                if persistent {
                    entry.persistent = true;
                }
                entry.refcount.fetch_add(1, Ordering::SeqCst);
                return id;
            }
        }
        let id = self.next_module_id.fetch_add(1, Ordering::SeqCst);
        reg.modules.insert(
            id,
            ModuleEntry {
                name: name.clone(),
                module,
                refcount: AtomicU64::new(1),
                persistent,
            },
        );
        reg.by_name.insert(name, id);
        id
    }

    /// 引用计数减一；归零时移除并调用 shutdown（.so 保持驻留，仅回收状态）。
    /// 常驻模块（persistent）refcount 归零也不卸载（只复位 refcount）。
    pub fn unref(&self, module_id: u64) {
        let mut reg = self.write();
        let should_shutdown = match reg.modules.get(&module_id) {
            Some(entry) if !entry.persistent => entry.refcount.fetch_sub(1, Ordering::SeqCst) <= 1,
            Some(entry) if entry.persistent => {
                // 常驻：refcount 归零后复位为 1（始终保持"已挂载"状态）
                let _ = entry.refcount.fetch_update(
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                    |rc| if rc <= 1 { Some(1) } else { Some(rc - 1) },
                );
                false
            }
            _ => false,
        };
        if should_shutdown {
            if let Some(entry) = reg.modules.remove(&module_id) {
                reg.by_name.remove(&entry.name);
                drop(reg); // 释放注册表锁后再回调模块（避免模块 cleanup 重入死锁）
                entry.module.shutdown();
            }
        }
    }

    pub fn is_loaded(&self, module_id: u64) -> bool {
        self.read().modules.contains_key(&module_id)
    }

    /// 按模块名获取 module_id（用于桥面按名路由）
    pub fn module_id_by_name(&self, name: &str) -> Option<u64> {
        self.read().by_name.get(name).copied()
    }

    /// 按名加载模块（桥面入口）：查找 + refcount+1；未注册报 MODULE_NOT_FOUND
    /// （多 .so 场景由 Dart 侧先 mountFromSo 挂载，再按名取句柄）。
    pub fn register_by_name(&self, name: &str) -> Result<u64, ModuleError> {
        let mut reg = self.write();
        let id = *reg
            .by_name
            .get(name)
            .ok_or_else(|| ModuleError::module_not_found(name))?;
        if let Some(entry) = reg.modules.get(&id) {
            entry.refcount.fetch_add(1, Ordering::SeqCst);
        }
        Ok(id)
    }

    /// 从 .so 动态加载模块（P2 多 .so 场景）：dlopen + 握手 + 注册。
    /// 幂等：同名模块已注册则 refcount+1 复用（走统一插入路径）。
    pub fn load_module_from_so(&self, so_path: &std::path::Path) -> Result<u64, ModuleError> {
        let adapter = crate::dl_adapter::DlModuleAdapter::load(so_path)
            .map_err(|e| ModuleError::internal(format!("dlopen adapter failed: {e}")))?;
        let name = adapter.name().to_string();
        let version = adapter.version();
        // mount-once：.so 永不 dlclose，同名模块的热替换不会在本进程生效。
        // 若已在册且版本不同，明确提示需重启（新文件留待下次启动加载）。
        if let Some(id) = self.module_id_by_name(&name) {
            let loaded = self.module_version(id);
            if loaded != Some(version) {
                crate::log_bridge::push_host_log(
                    2,
                    format!(
                        "module {name} already mounted (v{loaded:?}); new v{version} takes effect after restart"
                    ),
                );
            }
        }
        Ok(self.register(Arc::new(adapter)))
    }

    /// 已注册模块的功能版本（用于热更新提示）
    pub fn module_version(&self, module_id: u64) -> Option<u32> {
        self.read().modules.get(&module_id).map(|e| e.module.version())
    }

    /// 列出当前已加载模块（按名字排序，供 UI/诊断只读展示）
    pub fn list_modules(&self) -> Vec<ModuleInfo> {
        let reg = self.read();
        let mut out: Vec<ModuleInfo> = reg
            .modules
            .iter()
            .map(|(id, e)| ModuleInfo {
                id: *id,
                name: e.name.clone(),
                version: e.module.version(),
                persistent: e.persistent,
                refcount: e.refcount.load(Ordering::SeqCst),
            })
            .collect();
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    /// 创建实例：module_id → 模块 create() → 返回模块内部实例句柄
    pub fn call_create(&self, module_id: u64, config: &[u8]) -> Result<u64, ModuleError> {
        self.module_of(module_id)?.create(config)
    }

    /// 统一调用入口：路由到模块（信封处理由调用方负责，本函数只转发原始字节）
    pub fn call(
        &self,
        module_id: u64,
        instance: Option<u64>,
        method: &str,
        payload: &[u8],
    ) -> Result<Vec<u8>, ModuleError> {
        self.module_of(module_id)?.call(instance, method, payload)
    }

    /// 带 request_id 的调用：登记在途表（供 cancel 路由），返回后注销。
    /// [timeout] 为 Some 时在独立线程执行调用，超时即返回 Timeout（模块仍在跑，尽力 cancel）。
    pub fn call_tracked(
        &self,
        module_id: u64,
        instance: Option<u64>,
        method: &str,
        payload: &[u8],
        request_id: &str,
        timeout: Option<Duration>,
    ) -> Result<Vec<u8>, ModuleError> {
        let module = self.module_of(module_id)?;
        if request_id.is_empty() {
            // 无关联键：无法取消，直接调用
            return match timeout {
                None => module.call(instance, method, payload),
                Some(dur) => self.call_with_timeout(
                    module_id, module, instance, method, payload, request_id, dur,
                ),
            };
        }
        self.inflight_write()
            .insert(request_id.to_string(), InflightCall { instance });
        let result = match timeout {
            None => module.call(instance, method, payload),
            Some(dur) => {
                self.call_with_timeout(module_id, module, instance, method, payload, request_id, dur)
            }
        };
        self.inflight_write().remove(request_id);
        result
    }

    /// 在独立线程跑同步 ABI 调用 + 超时等待。超时后尽力 cancel，返回 Timeout。
    fn call_with_timeout(
        &self,
        module_id: u64,
        module: Arc<dyn GStoreModule>,
        instance: Option<u64>,
        method: &str,
        payload: &[u8],
        request_id: &str,
        dur: Duration,
    ) -> Result<Vec<u8>, ModuleError> {
        let (tx, rx) = std::sync::mpsc::channel();
        let method_owned = method.to_string();
        let payload_owned = payload.to_vec();
        let worker = std::thread::Builder::new()
            .name("gstore-mod-call".to_string())
            .spawn(move || {
                let out = module.call(instance, &method_owned, &payload_owned);
                let _ = tx.send(out);
            })
            .map_err(|e| ModuleError::internal(format!("spawn module call failed: {e}")))?;

        match rx.recv_timeout(dur) {
            Ok(result) => {
                let _ = worker.join();
                result
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                // 尽力取消（模块若不支持则无操作）；工作线程继续跑，结果被丢弃
                let _ = self.cancel(module_id, instance, request_id);
                Err(ModuleError::new(
                    StatusCode::Timeout,
                    "TIMEOUT",
                    format!("module call {method} timed out after {dur:?}"),
                ))
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                Err(ModuleError::internal("module call thread panicked"))
            }
        }
    }

    /// 取消某次在途调用：按 request_id 查在途表 → 路由到模块 `cancel`。
    /// 未登记的 request_id 也按传入参数转发（宽松处理）。
    pub fn cancel(
        &self,
        module_id: u64,
        instance: Option<u64>,
        request_id: &str,
    ) -> Result<(), ModuleError> {
        let instance = self
            .inflight_read()
            .get(request_id)
            .map(|c| c.instance)
            .unwrap_or(instance);
        self.module_of(module_id)?.cancel(instance, request_id)
    }

    /// 宿主向所有已加载模块下发应用事件（下行订阅）。
    /// 先快照 (id, Arc) 再释放注册表锁后逐个回调——避免长锁与模块回调重入死锁。
    pub fn broadcast_event(&self, kind: &str, data: &[u8]) {
        let targets: Vec<(u64, Arc<dyn GStoreModule>)> = {
            let reg = self.read();
            reg.modules
                .iter()
                .map(|(id, e)| (*id, e.module.clone()))
                .collect()
        };
        for (id, module) in targets {
            if let Err(e) = module.on_event(id, kind, data) {
                crate::log_bridge::push_host_log(
                    2,
                    format!("module on_event failed (id={id}, kind={kind}): {e}"),
                );
            }
        }
    }

    pub fn call_destroy(&self, module_id: u64, instance: u64) -> Result<(), ModuleError> {
        self.module_of(module_id)?.destroy(instance)
    }

    /// 取模块 Arc（统一 MODULE_NOT_FOUND 处理）
    fn module_of(&self, module_id: u64) -> Result<Arc<dyn GStoreModule>, ModuleError> {
        self.read()
            .modules
            .get(&module_id)
            .map(|e| e.module.clone())
            .ok_or_else(|| {
                ModuleError::new(
                    StatusCode::ModuleNotFound,
                    ERR_MODULE_NOT_FOUND,
                    "module not found",
                )
            })
    }

    /// 信封级调用：解包 EnvelopeRequest → 转发 → 封包 EnvelopeResponse（统一错误收敛）
    pub fn call_envelope(&self, request_bytes: &[u8]) -> Vec<u8> {
        self.call_envelope_impl(request_bytes, None)
    }

    /// 带超时的信封级调用（Dart 侧长任务可传 timeout 避免宿主被无限阻塞）
    pub fn call_envelope_with_timeout(&self, request_bytes: &[u8], timeout: Duration) -> Vec<u8> {
        self.call_envelope_impl(request_bytes, Some(timeout))
    }

    fn call_envelope_impl(&self, request_bytes: &[u8], timeout: Option<Duration>) -> Vec<u8> {
        let request = match EnvelopeRequest::decode(request_bytes) {
            Ok(r) => r,
            Err(e) => return EnvelopeResponse::err("", &e).encode().unwrap_or_default(),
        };
        let module_id = self.read().by_name.get(request.module()).copied();
        let result = match module_id {
            Some(id) => {
                let instance = if request.instance().is_empty() {
                    None
                } else {
                    request.instance().parse::<u64>().ok()
                };
                self.call_tracked(
                    id,
                    instance,
                    request.method(),
                    request.payload(),
                    request.request_id(),
                    timeout,
                )
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
        let req = EnvelopeRequest::new("test_counter", Some("7"), "echo", b"ping".to_vec())
            .with_request_id("req-1");
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
        let req = EnvelopeRequest::new("demo", Some("42"), "echo", b"hello".to_vec())
            .with_request_id("req-2");
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

    /// 超时：慢模块被 Timeout 截断（工作线程继续，不阻塞调用方）
    struct SlowModule;
    impl GStoreModule for SlowModule {
        fn name(&self) -> &'static str {
            "slow"
        }
        fn create(&self, _config: &[u8]) -> Result<u64, ModuleError> {
            Ok(1)
        }
        fn call(&self, _i: Option<u64>, _m: &str, _p: &[u8]) -> Result<Vec<u8>, ModuleError> {
            std::thread::sleep(Duration::from_millis(500));
            Ok(b"done".to_vec())
        }
        fn destroy(&self, _instance: u64) -> Result<(), ModuleError> {
            Ok(())
        }
    }

    #[test]
    fn timeout_returns_timeout_status() {
        let mgr = ModuleManager::new();
        let id = mgr.register(Arc::new(SlowModule));
        let err = mgr
            .call_tracked(id, None, "slow", &[], "req-slow", Some(Duration::from_millis(20)))
            .unwrap_err();
        assert_eq!(err.status, StatusCode::Timeout);
        // 在途表已清理
        assert!(mgr.inflight_read().is_empty());
    }

    /// 下行事件：broadcast_event 触达所有已注册模块的 on_event
    struct Recorder {
        got: std::sync::Mutex<Vec<(u64, String, Vec<u8>)>>,
    }
    impl GStoreModule for Recorder {
        fn name(&self) -> &'static str {
            "recorder"
        }
        fn create(&self, _config: &[u8]) -> Result<u64, ModuleError> {
            Ok(1)
        }
        fn call(&self, _i: Option<u64>, _m: &str, _p: &[u8]) -> Result<Vec<u8>, ModuleError> {
            Ok(Vec::new())
        }
        fn on_event(&self, module_id: u64, kind: &str, data: &[u8]) -> Result<(), ModuleError> {
            self.got
                .lock()
                .unwrap()
                .push((module_id, kind.to_string(), data.to_vec()));
            Ok(())
        }
        fn destroy(&self, _instance: u64) -> Result<(), ModuleError> {
            Ok(())
        }
    }

    #[test]
    fn broadcast_event_reaches_registered_modules() {
        let mgr = ModuleManager::new();
        let rec = Arc::new(Recorder { got: std::sync::Mutex::new(Vec::new()) });
        let id = mgr.register(rec.clone());

        mgr.broadcast_event("config.changed", br#"{"key":"x"}"#);

        let got = rec.got.lock().unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, id);
        assert_eq!(got[0].1, "config.changed");
        assert_eq!(got[0].2, br#"{"key":"x"}"#);
    }

    #[test]
    fn list_modules_reports_registered_modules() {
        struct P(&'static str);
        impl GStoreModule for P {
            fn name(&self) -> &'static str {
                self.0
            }
            fn create(&self, _config: &[u8]) -> Result<u64, ModuleError> {
                Ok(1)
            }
            fn call(&self, _i: Option<u64>, _m: &str, _p: &[u8]) -> Result<Vec<u8>, ModuleError> {
                Ok(vec![])
            }
            fn destroy(&self, _i: u64) -> Result<(), ModuleError> {
                Ok(())
            }
        }
        let mgr = ModuleManager::new();
        mgr.register(Arc::new(P("beta")));
        mgr.register(Arc::new(P("alpha")));
        let list = mgr.list_modules();
        assert_eq!(
            list.iter().map(|m| m.name.as_str()).collect::<Vec<_>>(),
            vec!["alpha", "beta"],
            "应按名字排序"
        );
        assert!(list.iter().all(|m| m.version == 1 && m.refcount == 1));
    }
}
