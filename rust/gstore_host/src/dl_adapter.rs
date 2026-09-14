// DlModuleAdapter：多 .so 场景下把 C ABI 模块包装为 GStoreModule trait（架构文档 4.3）
//
// 宿主 dlopen 模块 .so → dlsym register 符号 → 握手（传 Entry 收 Api）→
// 本适配器把 Api 函数指针转发为 trait 方法。持有 Library 保持 .so 驻留
// （架构 5.5：mount-once 永不 unload）。

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::Arc;

use gstore_contract::abi::{
    ABI_ERR_DETAIL, ABI_OK, GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
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
type CancelFn = extern "C" fn(u64, *const c_char) -> c_int;
type OnEventFn = extern "C" fn(u64, *const c_char, *const u8, usize) -> c_int;
type DestroyFn = extern "C" fn(u64) -> c_int;
type ShutdownFn = extern "C" fn() -> c_int;
type AllocFn = extern "C" fn(usize) -> *mut c_void;
type FreeFn = extern "C" fn(*mut c_void);

pub struct DlModuleAdapter {
    #[cfg(unix)]
    _lib: Arc<libloading::os::unix::Library>, // 保持 .so 加载（永不 unload）
    #[cfg(not(unix))]
    _lib: Arc<libloading::Library>, // 保持 .so 加载（永不 unload）
    name: &'static str,             // load 时泄漏一次（模块生命周期内固定）
    version: u32,
    create: CreateFn,
    call: CallFn,
    cancel: Option<CancelFn>,
    on_event: Option<OnEventFn>,
    destroy: DestroyFn,
    shutdown: Option<ShutdownFn>,
    free: FreeFn, // 释放模块分配的内存（谁分配谁释放）
}

/// 从 .so 文件名推导模块名：libgstore_mod_qr.so → qr；
/// 版本化文件（libgstore_mod_qr_0.2.0.so）同样剥离版本后缀 → qr。
fn parse_module_name(file_name: &str) -> Result<String, String> {
    let stem = file_name
        .strip_prefix("lib")
        .and_then(|s| s.strip_suffix(".so"))
        .unwrap_or(file_name);
    let with_version = stem.strip_prefix("gstore_mod_").unwrap_or(stem);
    // 先剥版本号，再剥 GPU 变体后缀（两者可叠加）
    let name = strip_variant_suffix(strip_version_suffix(with_version));
    if name.is_empty() {
        return Err(format!("cannot derive module name from {file_name}"));
    }
    Ok(name.to_string())
}

/// 剥离尾部 GPU 变体后缀（`_cpu` / `_opencl` / `_vulkan`）。
///
/// 变体 .so（如 `libgstore_mod_llm_opencl.so`）与主模块同名 → `llm`，
/// 这样宿主才能按同一模块名加载不同后端（调用方按优先级尝试，谁先成功用谁）。
fn strip_variant_suffix(s: &str) -> &str {
    for tag in ["_opencl", "_vulkan", "_cpu"] {
        if let Some(stripped) = s.strip_suffix(tag) {
            if !stripped.is_empty() {
                return stripped;
            }
        }
    }
    s
}

/// 剥离尾部形如 `_1.2.3` 的版本后缀（要求全为数字段，至少含一个点）
fn strip_version_suffix(s: &str) -> &str {
    if let Some(idx) = s.rfind('_') {
        let tail = &s[idx + 1..];
        if tail.contains('.')
            && tail
                .split('.')
                .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
        {
            return &s[..idx];
        }
    }
    s
}

impl DlModuleAdapter {
    /// dlopen + 握手，构造适配器
/// 尽力预加载 OpenCL 运行库（RTLD_GLOBAL）。
///
/// OpenCL 版 llm 模块（ggml-opencl）引用一组 `cl*` 未定义符号，而 NEEDED 里没有
/// libOpenCL.so（Android NDK 不提供），因此必须在 dlopen 该模块之前，让设备上的
/// libOpenCL 进入**全局符号组**；否则模块会因符号无法解析而加载失败。
/// 找不到时静默跳过（CPU 构建完全不受影响）。
fn preload_opencl() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        const CANDIDATES: [&str; 5] = [
            "libOpenCL.so",
            "libOpenCL.so.1",
            "/vendor/lib64/libOpenCL.so",
            "/system/lib64/libOpenCL.so",
            "/vendor/lib/libOpenCL.so",
        ];
        for path in CANDIDATES {
            // 句柄故意泄漏：整个进程生命周期保持加载，供后续 dlopen 解析符号
            let loaded = unsafe {
                libloading::os::unix::Library::open(
                    Some(path),
                    libloading::os::unix::RTLD_NOW | libloading::os::unix::RTLD_GLOBAL,
                )
            }
            .map(|lib| {
                std::mem::forget(lib);
                true
            })
            .unwrap_or(false);
            if loaded {
                crate::log_bridge::push_host_log(1, format!("gstore_host: 已预加载 OpenCL - {path}"));
                return;
            }
        }
        crate::log_bridge::push_host_log(
            0,
            "gstore_host: 未找到 libOpenCL（OpenCL 版 llm 模块将加载失败并回退）".to_string(),
        );
    });
}

    pub fn load(path: &std::path::Path) -> Result<Self, String> {
        Self::preload_opencl();
        // 1. dlopen
        // 用 RTLD_NOW 强制立即绑定全部符号：libloading::Library::new 默认 RTLD_LAZY，
        // 在 Android 16 (16KB page) 上对提取到 files/ 目录的 .so 懒绑定解析异常，
        // GOT 表项停留在链接时虚拟地址（未加加载基址），首次 PLT 调用（如 memcpy）
        // 跳到未映射地址 SIGSEGV（真机崩溃根因）。RTLD_NOW 与 .so 内 BIND_NOW 一致。
        #[cfg(unix)]
        let lib = Arc::new(
            unsafe {
                libloading::os::unix::Library::open(
                    Some(path),
                    libloading::os::unix::RTLD_NOW | libloading::os::unix::RTLD_LOCAL,
                )
            }
            .map_err(|e| format!("dlopen {}: {e}", path.display()))?,
        );
        #[cfg(not(unix))]
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
        let register: libloading::os::unix::Symbol<RegisterFn> = unsafe {
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
        // ABI 版本协商：模块声明的最低宿主 ABI 不得高于本宿主 ABI，
        // 否则结构体布局可能不一致（跨边界 UB），必须拒绝加载而非放行。
        if api.min_host_abi > GSTORE_MODULE_ABI_VERSION {
            return Err(format!(
                "module {name} requires host ABI >= {} but host is {}",
                api.min_host_abi, GSTORE_MODULE_ABI_VERSION
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
            cancel: api.cancel,
            on_event: api.on_event,
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

    /// 请求模块取消某次在途调用（ABI `cancel` 槽；模块未实现则无操作）
    fn cancel_call(&self, instance: u64, request_id: &str) -> Result<(), ModuleError> {
        let Some(cancel) = self.cancel else {
            return Ok(());
        };
        let c_req = CString::new(request_id)
            .map_err(|_| ModuleError::invalid_arg("request_id contains NUL"))?;
        let code = unsafe { cancel(instance, c_req.as_ptr()) };
        if code == ABI_OK {
            Ok(())
        } else {
            Err(ModuleError::internal(format!("module cancel failed: code={code}")))
        }
    }
}

impl GStoreModule for DlModuleAdapter {
    fn name(&self) -> &'static str {
        self.name
    }

    fn version(&self) -> u32 {
        self.version
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
        if code == ABI_OK {
            Ok(unsafe { self.copy_out(out_ptr, out_len) })
        } else if code == ABI_ERR_DETAIL {
            // 模块把结构化错误写入 out 缓冲：还原 StatusCode/code/message
            let bytes = unsafe { self.copy_out(out_ptr, out_len) };
            Err(ModuleError::from_payload(&bytes).unwrap_or_else(|| {
                ModuleError::internal(format!("module call {method} failed (undecodable detail)"))
            }))
        } else {
            Err(ModuleError::internal(format!("module call {method} failed: code={code}")))
        }
    }

    fn cancel(&self, instance: Option<u64>, request_id: &str) -> Result<(), ModuleError> {
        self.cancel_call(instance.unwrap_or(0), request_id)
    }

    fn on_event(&self, module_id: u64, kind: &str, data: &[u8]) -> Result<(), ModuleError> {
        let Some(f) = self.on_event else {
            return Ok(()); // 模块未提供 on_event（旧模块）→ 忽略下发
        };
        let c_kind = CString::new(kind)
            .map_err(|_| ModuleError::invalid_arg("kind contains NUL"))?;
        let code = unsafe { f(module_id, c_kind.as_ptr(), data.as_ptr(), data.len()) };
        if code == ABI_OK {
            Ok(())
        } else {
            Err(ModuleError::internal(format!("module on_event failed: code={code}")))
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

/// 定位已构建的模块 .so：缺失即 fail（避免 CI 静默跳过集成测试）。
/// 设 `GSTORE_ALLOW_MISSING_MODULE=1` 可显式跳过（返回 None）。
#[cfg(test)]
fn module_so(rel: &str) -> Option<std::path::PathBuf> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(rel);
    if path.exists() {
        return Some(path);
    }
    if std::env::var("GSTORE_ALLOW_MISSING_MODULE").is_ok() {
        eprintln!(
            "SKIP (GSTORE_ALLOW_MISSING_MODULE=1): module .so not built: {}",
            path.display()
        );
        return None;
    }
    panic!(
        "module .so not built: {} — 先运行 rust/build_all.sh 构建模块，\
         或设 GSTORE_ALLOW_MISSING_MODULE=1 显式跳过",
        path.display()
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 集成测试：dlopen gstore_mod_qr.so → 握手 → create → call → destroy
    /// （需先构建模块：cd rust/gstore_mod_qr && cargo build）
    #[test]
    fn dlopen_qr_module_full_roundtrip() {
        let Some(so_path) = module_so("../gstore_mod_qr/target/debug/libgstore_mod_qr.so") else { return; };

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
        let Some(so_path) = module_so("../gstore_mod_qr/target/debug/libgstore_mod_qr.so") else { return; };

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
        let Some(so_path) = module_so("../gstore_mod_analyzer/target/debug/libgstore_mod_analyzer.so") else { return; };

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
        let Some(so_path) = module_so("../gstore_mod_analyzer/target/debug/libgstore_mod_analyzer.so") else { return; };

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

    /// P0-2 回归：模块域错误经 ABI_ERR_DETAIL 透传，保留 405/METHOD_NOT_FOUND
    /// （改造前会被塌成 500/INTERNAL_ERROR）。
    #[test]
    fn module_domain_error_preserves_status_and_code() {
        let Some(so_path) = module_so("../gstore_mod_analyzer/target/debug/libgstore_mod_analyzer.so") else { return; };

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load analyzer");

        let req = EnvelopeRequest::new("analyzer", None, "no_such_method", vec![])
            .with_request_id("req-err");
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert_eq!(resp.status(), 405, "应保留 MethodNotFound，而非塌成 500");
        assert_eq!(resp.error_code(), gstore_contract::error::ERR_METHOD_NOT_FOUND);

        // 缺参 → 422 INVALID_ARGUMENT（同一条透传链路）
        let req = EnvelopeRequest::new("analyzer", None, "parse_apk_info", vec![])
            .with_request_id("req-arg");
        let resp = EnvelopeResponse::decode(&mgr.call_envelope(&req.encode().unwrap())).unwrap();
        assert_eq!(resp.status(), 422);
        assert_eq!(resp.error_code(), gstore_contract::error::ERR_INVALID_ARGUMENT);

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
        let Some(so_path) = module_so("../gstore_mod_repo/target/debug/libgstore_mod_repo.so") else { return; };

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
        let Some(so_path) = module_so("../gstore_mod_repo/target/debug/libgstore_mod_repo.so") else { return; };

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

    /// 下行事件烟测：向已 dlopen 的 repo 模块广播 config.changed（走 ABI on_event）
    #[test]
    fn broadcast_event_to_repo_module() {
        let _lock = SHARED_STATE_LOCK.lock().unwrap();
        let Some(so_path) = module_so("../gstore_mod_repo/target/debug/libgstore_mod_repo.so") else { return; };

        let mgr = crate::manager::ModuleManager::new();
        let id = mgr.load_module_from_so(&so_path).expect("load repo");

        // 不应 panic；模块侧 on_event 解析并记录 key
        mgr.broadcast_event("config.changed", br#"{"key":"proxyUrl","value":"x"}"#);

        mgr.unref(id);
    }
}

#[cfg(test)]
mod name_tests {
    use super::*;

    #[test]
    fn parse_module_name_handles_plain_and_versioned() {
        assert_eq!(parse_module_name("libgstore_mod_qr.so").unwrap(), "qr");
        assert_eq!(parse_module_name("libgstore_mod_analyzer.so").unwrap(), "analyzer");
        assert_eq!(parse_module_name("libgstore_mod_repo.so").unwrap(), "repo");
        // 版本化文件名：剥离 _x.y.z
        assert_eq!(parse_module_name("libgstore_mod_qr_0.2.0.so").unwrap(), "qr");
        // GPU 变体：带变体后缀、以及变体+版本叠加，都应归一化回同一模块名
        assert_eq!(parse_module_name("libgstore_mod_llm_cpu.so").unwrap(), "llm");
        assert_eq!(parse_module_name("libgstore_mod_llm_opencl.so").unwrap(), "llm");
        assert_eq!(parse_module_name("libgstore_mod_llm_vulkan.so").unwrap(), "llm");
        assert_eq!(parse_module_name("libgstore_mod_llm_opencl_1.2.3.so").unwrap(), "llm");
        assert_eq!(parse_module_name("libgstore_mod_repo_1.0.0.so").unwrap(), "repo");
        // 下划线模块名（无点版本）不应被误剥
        assert_eq!(parse_module_name("libgstore_mod_my_mod.so").unwrap(), "my_mod");
    }
}
