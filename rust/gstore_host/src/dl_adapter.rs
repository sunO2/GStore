// DlModuleAdapter：多 .so 场景下把 C ABI 模块包装为 GStoreModule trait（架构文档 4.3）
//
// 宿主 dlopen 模块 .so → dlsym register 符号 → 握手（传 Entry 收 Api）→
// 本适配器把 Api 函数指针转发为 trait 方法。持有 Library 保持 .so 驻留
// （架构 5.5：mount-once 永不 unload）。

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::Arc;

use gstore_contract::abi::{
    GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
};
use gstore_contract::error::ModuleError;

use crate::manager::GStoreModule;

/// C ABI 函数指针类型（与 gstore_contract::abi 一致：安全 extern "C" fn）
type RegisterFn = extern "C" fn(*const GStoreModuleEntry, *mut GStoreModuleApi) -> c_int;
type CreateFn = extern "C" fn(*const u8, usize, *mut u64) -> c_int;
type CallFn = extern "C" fn(
    u64,
    *const c_char,
    *const u8,
    usize,
    *mut *mut u8,
    *mut usize,
) -> c_int;
type DestroyFn = extern "C" fn(u64) -> c_int;
type ShutdownFn = extern "C" fn() -> c_int;
type AllocFn = extern "C" fn(usize) -> *mut c_void;
type FreeFn = extern "C" fn(*mut c_void);

pub struct DlModuleAdapter {
    _lib: Arc<libloading::Library>, // 保持 .so 加载（永不 unload）
    name: &'static str,             // load 时泄漏一次（模块生命周期内固定）
    version: u32,
    create: CreateFn,
    call: CallFn,
    destroy: DestroyFn,
    shutdown: Option<ShutdownFn>,
    free: FreeFn, // 释放模块分配的内存（谁分配谁释放）
}

/// 从 .so 文件名推导模块名：libgstore_mod_qr.so → qr；libgstore_mod_analyzer.so → analyzer
fn parse_module_name(file_name: &str) -> Result<String, String> {
    let stem = file_name
        .strip_prefix("lib")
        .and_then(|s| s.strip_suffix(".so"))
        .unwrap_or(file_name);
    let name = stem.strip_prefix("gstore_mod_").unwrap_or(stem);
    if name.is_empty() {
        return Err(format!("cannot derive module name from {file_name}"));
    }
    Ok(name.to_string())
}

impl DlModuleAdapter {
    /// dlopen + 握手，构造适配器
    pub fn load(path: &std::path::Path) -> Result<Self, String> {
        // 1. dlopen
        let lib = Arc::new(
            unsafe { libloading::Library::new(path) }
                .map_err(|e| format!("dlopen {}: {e}", path.display()))?,
        );

        // 2. 按模块名约定解析 register 符号：gstore_mod_<name>_register
        //    模块名从 .so 文件名推导（libgstore_mod_qr.so → qr）。
        let file_name = path
            .file_name()
            .and_then(|s| s.to_str())
            .ok_or("invalid .so filename")?;
        let module_name = parse_module_name(file_name)?;
        let register_sym = format!("gstore_mod_{module_name}_register\0");

        // 3. dlsym register 入口（模块按名约定）
        let register: libloading::Symbol<RegisterFn> = unsafe {
            lib.get(register_sym.as_bytes())
        }
        .map_err(|e| format!("no register symbol {} in {}: {e}", register_sym.trim_end_matches('\0'), path.display()))?;

        // 3b. 握手：传 Entry（宿主服务）收 Api（模块能力）
        let mut entry = GStoreModuleEntry {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
            log: Some(crate::log_bridge::host_log),
            alloc: None,
            free: None,
            emit_event: Some(crate::event_bridge::host_emit_event),
            context: std::ptr::null_mut(),
        };
        let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::zeroed();
        let code = unsafe { register(&mut entry, api.as_mut_ptr()) };
        let api = unsafe { api.assume_init() };
        if code != 0 {
            return Err(format!("module rejected handshake: code={code}"));
        }

        // 4. 校验 + 包装
        let name = if api.name.is_null() {
            return Err("module api.name is null".to_string());
        } else {
            unsafe { CStr::from_ptr(api.name) }.to_string_lossy().into_owned()
        };
        // 文件名推导的模块名须与握手回报的 api.name 一致
        if name != module_name {
            return Err(format!(
                "module name mismatch: file says {module_name}, api says {name}"
            ));
        }
        let create = api.create.ok_or("module missing create")?;
        let call = api.call.ok_or("module missing call")?;
        let destroy = api.destroy.ok_or("module missing destroy")?;
        let free = api.free.ok_or("module missing free")?;

        Ok(Self {
            _lib: lib,
            name: Box::leak(name.into_boxed_str()),
            version: api.version,
            create,
            call,
            destroy,
            shutdown: api.shutdown,
            free,
        })
    }

    /// 把模块分配的内存拷贝进 Vec 并用模块 free 释放（谁分配谁释放）
    unsafe fn copy_out(&self, ptr: *mut u8, len: usize) -> Vec<u8> {
        let bytes = if len == 0 || ptr.is_null() {
            Vec::new()
        } else {
            std::slice::from_raw_parts(ptr, len).to_vec()
        };
        (self.free)(ptr as *mut c_void);
        bytes
    }
}

impl GStoreModule for DlModuleAdapter {
    fn name(&self) -> &'static str {
        self.name
    }

    fn create(&self, config: &[u8]) -> Result<u64, ModuleError> {
        let mut instance: u64 = 0;
        let code = unsafe {
            (self.create)(
                config.as_ptr(),
                config.len(),
                &mut instance as *mut u64,
            )
        };
        if code == 0 {
            Ok(instance)
        } else {
            Err(ModuleError::internal(format!("module create failed: code={code}")))
        }
    }

    fn call(&self, instance: Option<u64>, method: &str, payload: &[u8]) -> Result<Vec<u8>, ModuleError> {
        let c_method = CString::new(method)
            .map_err(|_| ModuleError::invalid_arg("method contains NUL"))?;
        let mut out_ptr: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let code = unsafe {
            (self.call)(
                instance.unwrap_or(0),
                c_method.as_ptr(),
                payload.as_ptr(),
                payload.len(),
                &mut out_ptr,
                &mut out_len,
            )
        };
        if code == 0 {
            Ok(unsafe { self.copy_out(out_ptr, out_len) })
        } else {
            Err(ModuleError::internal(format!("module call {method} failed: code={code}")))
        }
    }

    fn destroy(&self, instance: u64) -> Result<(), ModuleError> {
        let code = unsafe { (self.destroy)(instance) };
        if code == 0 {
            Ok(())
        } else {
            Err(ModuleError::internal(format!("module destroy failed: code={code}")))
        }
    }

    fn shutdown(&self) {
        if let Some(f) = self.shutdown {
            unsafe { f() };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 集成测试：dlopen gstore_mod_qr.so → 握手 → create → call → destroy
    /// （需先构建模块：cd rust/gstore_mod_qr && cargo build）
    #[test]
    fn dlopen_qr_module_full_roundtrip() {
        let so_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../gstore_mod_qr/target/debug/libgstore_mod_qr.so");
        if !so_path.exists() {
            eprintln!("SKIP: module .so not built: {}", so_path.display());
            return;
        }

        let adapter = DlModuleAdapter::load(&so_path).expect("dlopen + handshake");
        assert_eq!(adapter.name(), "qr");
        assert!(adapter.version >= 1);

        // create 实例（无状态模块，返回句柄）
        let inst = adapter.create(b"{}").expect("create");
        // call ping（静态语义：实例方法）
        let out = adapter.call(Some(inst), "ping", &[]).expect("call ping");
        assert_eq!(out, b"pong");
        // destroy
        adapter.destroy(inst).expect("destroy");
        // shutdown
        adapter.shutdown();
    }

    /// 通过 ModuleManager 走完整注册表链路
    #[test]
    fn module_manager_load_from_so_and_call() {
        let so_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../gstore_mod_qr/target/debug/libgstore_mod_qr.so");
        if !so_path.exists() {
            eprintln!("SKIP: module .so not built");
            return;
        }

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load from so");
        assert!(mgr.is_loaded(id));

        // 幂等：再次加载 → 同名复用同 id
        let id2 = mgr.load_module_from_so(&so_path).expect("reload");
        assert_eq!(id, id2);

        // 信封级调用（按模块名路由）
        let req = gstore_contract::envelope::EnvelopeRequest::new("qr", None, "ping", vec![]);
        let resp_bytes = mgr.call_envelope(&req.encode().unwrap());
        let resp = gstore_contract::envelope::EnvelopeResponse::decode(&resp_bytes).unwrap();
        assert!(resp.is_ok());
        assert_eq!(resp.payload(), b"pong");

        // 释放：refcount 2 → 1（仍加载）→ 0（卸载）
        mgr.unref(id);
        assert!(mgr.is_loaded(id));
        mgr.unref(id2);
        assert!(!mgr.is_loaded(id));
    }
}

#[cfg(test)]
mod analyzer_tests {
    use super::*;
    use gstore_contract::envelope::{EnvelopeRequest, EnvelopeResponse};

    /// 集成测试：dlopen gstore_mod_analyzer.so → 握手 → create → call ping + 参数化方法
    /// （需先构建模块：cd rust/gstore_mod_analyzer && cargo build）
    #[test]
    fn dlopen_analyzer_module_handshake_and_call() {
        let so_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../gstore_mod_analyzer/target/debug/libgstore_mod_analyzer.so");
        if !so_path.exists() {
            eprintln!("SKIP: analyzer module .so not built: {}", so_path.display());
            return;
        }

        let adapter = DlModuleAdapter::load(&so_path).expect("dlopen + handshake");
        assert_eq!(adapter.name(), "analyzer");
        assert!(adapter.version >= 1);

        // create 实例（无状态占位）
        let inst = adapter.create(b"{}").expect("create");
        // 静态 ping
        let out = adapter.call(Some(inst), "ping", &[]).expect("call ping");
        assert_eq!(out, b"pong");
        // 参数化方法：scan_dex_classes 需要一个存在的 APK，这里仅验证参数解析错误路径
        //（payload 编码：apk_path + NUL + patterns）
        let payload = b"/nonexistent.apk\0androidx.lifecycle.*".to_vec();
        let err = adapter
            .call(Some(inst), "scan_dex_classes", &payload)
            .expect_err("bad apk path should err");
        // 模块 call 失败统一转 ModuleError::internal（内部错误码），验证返回了错误即可
        assert!(!err.to_string().is_empty());

        adapter.destroy(inst).expect("destroy");
    }

    /// 通过 ModuleManager 按路径加载 analyzer 模块 + 信封级错误路由
    #[test]
    fn module_manager_loads_analyzer_from_so() {
        let so_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../gstore_mod_analyzer/target/debug/libgstore_mod_analyzer.so");
        if !so_path.exists() {
            eprintln!("SKIP: analyzer module .so not built");
            return;
        }

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load analyzer");
        assert!(mgr.is_loaded(id));

        // 信封级调用 ping：按模块名 "analyzer" 路由
        let req = EnvelopeRequest::new("analyzer", None, "ping", vec![]);
        let resp_bytes = mgr.call_envelope(&req.encode().unwrap());
        let resp = EnvelopeResponse::decode(&resp_bytes).unwrap();
        assert!(resp.is_ok());
        assert_eq!(resp.payload(), b"pong");

        mgr.unref(id);
    }
}

#[cfg(test)]

#[cfg(test)]
mod repo_tests {
    use super::*;
    use gstore_contract::envelope::{EnvelopeRequest, EnvelopeResponse};
    use std::sync::Mutex as TestMutex;

    /// 测试级互斥锁：repo/gstore_mod_repo.so 的实例状态是进程级共享的，
    /// 多个测试并发操作会互相清空（shutdown/unref clear 共享表）。
    /// 生产用 ModuleManager::global()（单例）无此问题，测试必须串行。
    static SHARED_STATE_LOCK: TestMutex<()> = TestMutex::new(());

    /// 集成测试：dlopen gstore_mod_repo.so → create（SQLite 内存库）
    /// → ping / get_one_app（空库 null）→ destroy。
    /// 验证 repo 域拆分三要素：register 符号按名解析 / 有状态实例 / 生命周期。
    /// 注：download_repo 需外网，不入单测（用 ping + 空库查询验证链路）。
    #[test]
    fn repo_module_handshake_state_and_lifecycle() {
        let _lock = SHARED_STATE_LOCK.lock().unwrap();
        let so_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../gstore_mod_repo/target/debug/libgstore_mod_repo.so");
        if !so_path.exists() {
            eprintln!("SKIP: repo module .so not built: {}", so_path.display());
            return;
        }

        let adapter = DlModuleAdapter::load(&so_path).expect("dlopen + handshake");
        assert_eq!(adapter.name(), "repo");

        // create：SQLite 内存库实例（create 传 db_path config）
        let inst = adapter.create(b":memory:").expect("create instance");
        // ping
        let out = adapter.call(Some(inst), "ping", &[]).expect("call ping");
        assert_eq!(out, b"pong");

        // get_one_app：空库 → JSON null（有状态 SQLite 连接可用）
        let out = adapter.call(Some(inst), "get_one_app", &[]).expect("get_one_app");
        let text = String::from_utf8_lossy(&out);
        assert_eq!(text, "null", "empty db should return null, got: {text}");

        // get_app_count：0
        let out = adapter.call(Some(inst), "get_app_count", &[]).expect("get_app_count");
        assert!(String::from_utf8_lossy(&out).contains("\"count\":0"));

        // destroy
        adapter.destroy(inst).expect("destroy");
        adapter.shutdown();
    }

    /// 通过 ModuleManager 信封级调用 repo 模块（ping 路由）
    #[test]
    fn module_manager_loads_repo_module_from_so() {
        let _lock = SHARED_STATE_LOCK.lock().unwrap();
        let so_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../gstore_mod_repo/target/debug/libgstore_mod_repo.so");
        if !so_path.exists() {
            eprintln!("SKIP: repo module .so not built");
            return;
        }

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load repo");
        assert!(mgr.is_loaded(id));

        // 信封级调用 ping：按模块名 "repo" 路由
        let req = EnvelopeRequest::new("repo", None, "ping", vec![]);
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert!(resp.is_ok());
        assert_eq!(resp.payload(), b"pong");

        // 证书信封调用 get_one_app（需实例）：create → 信封
        let inst = mgr.call_create(id, b":memory:").expect("create");
        let req = EnvelopeRequest::new("repo", Some(&inst.to_string()), "get_one_app", vec![]);
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert!(resp.is_ok(), "resp status={} err={}", resp.status(), resp.error_message());
        assert_eq!(String::from_utf8_lossy(resp.payload()), "null");

        mgr.unref(id);
    }
}
