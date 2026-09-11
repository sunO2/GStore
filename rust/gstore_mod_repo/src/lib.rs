// gstore_mod_repo：F-Droid 仓库管理模块（独立 cdylib）
//
// 从宿主体内拆分（原 repo.rs），遵循 PoC 验证的架构约束：
// 1. rusqlite Connection 非 Send → 实例整体 Arc<Mutex<RepoManager>>，call 时锁实例串行
// 2. 全局注册表锁取实例后立即释放（不跨越 async 任务），否则多实例 call 串行
// 3. download_repo async 经 runtime.block_on 同步返回（C ABI 同步契约）

mod models;
mod repo;

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use tokio::runtime::Runtime;

use gstore_contract::abi::{GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION};

const ABI_OK: c_int = 0;
const ABI_ERR: c_int = -1;
const ABI_ERR_PANIC: c_int = -6;

/// 实例：RepoManager（SQLite）+ 专用 tokio Runtime（download async block_on）
pub struct RepoInstance {
    manager: repo::RepoManager,
    runtime: Runtime,
}

static INSTANCES: OnceLock<Mutex<std::collections::HashMap<u64, Arc<Mutex<RepoInstance>>>>> = OnceLock::new();
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);
static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();

fn instances() -> &'static Mutex<std::collections::HashMap<u64, Arc<Mutex<RepoInstance>>>> {
    INSTANCES.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

fn log_message(level: c_int, msg: &str) {
    if let Some(f) = HOST_LOG.get() {
        if let Ok(cmsg) = CString::new(msg) {
            f(level, cmsg.as_ptr());
        }
    }
}

// ==================== 内部实现 ====================

fn create_impl(config: *const u8, config_len: usize) -> Result<u64, c_int> {
    let db_path = if config.is_null() || config_len == 0 {
        ":memory:".to_string()
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(config, config_len) };
        String::from_utf8_lossy(bytes).into_owned()
    };

    let manager = repo::RepoManager::new(&db_path)
        .map_err(|e| { log_message(3, &format!("open db failed: {e}")); ABI_ERR })?;
    let runtime = Runtime::new().map_err(|e| {
        log_message(3, &format!("tokio runtime failed: {e}"));
        ABI_ERR
    })?;

    let id = NEXT_INSTANCE.fetch_add(1, Ordering::SeqCst);
    instances().lock().unwrap()
        .insert(id, Arc::new(Mutex::new(RepoInstance { manager, runtime })));
    log_message(1, &format!("repo: instance {id} created (db={db_path})"));
    Ok(id)
}

fn call_impl(
    instance_id: u64,
    method: *const c_char,
    payload: *const u8,
    payload_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    let method = unsafe { CStr::from_ptr(method) }.to_string_lossy().into_owned();

    // 静态方法：ping 无需实例（instance 可为 0，DlModuleAdapter 静态调用传 0）
    if method == "ping" {
        let resp = b"pong".to_vec();
        return write_out(resp, out_data, out_len);
    }

    // 约束 2：全局锁只取实例 Arc 引用，立即释放（不跨越 async 任务）
    let inst_arc = {
        let guard = instances().lock().unwrap();
        guard.get(&instance_id).cloned().ok_or(ABI_ERR)?
    };
    // 约束 1：锁实例串行访问（rusqlite 单写者）
    let inst = inst_arc.lock().unwrap();

    let result: Result<Vec<u8>, String> = match method.as_str() {
        "download_repo" => {
            // async 方法：runtime.block_on（下载可能耗时数秒）
            let repo_url = if payload.is_null() || payload_len == 0 {
                return Err(ABI_ERR);
            } else {
                let bytes = unsafe { std::slice::from_raw_parts(payload, payload_len) };
                String::from_utf8_lossy(bytes).into_owned()
            };
            let manager = &inst.manager;
            match inst.runtime.block_on(manager.download_repo(&repo_url)) {
                Ok(dl) => serde_json::to_vec(&dl).map_err(|e| e.to_string()),
                Err(e) => Err(e),
            }
        }
        "get_app_count" => {
            let n = inst.manager.get_app_count();
            match n {
                Ok(count) => Ok(format!("{{\"count\":{count}}}").into_bytes()),
                Err(e) => Err(e),
            }
        }
        "search_apps" => {
            // payload: keyword NUL limit(i32 LE)
            let parsed = parse_search_args(payload, payload_len);
            match parsed {
                Ok((keyword, limit)) => {
                    let apps = inst.manager.search_apps(&keyword, limit);
                    match apps {
                        Ok(list) => serde_json::to_vec(&list).map_err(|e| e.to_string()),
                        Err(e) => Err(e),
                    }
                }
                Err(e) => Err(e),
            }
        }
        "clear_apps" => {
            let n = inst.manager.clear_apps();
            match n {
                Ok(count) => Ok(format!("{{\"count\":{count}}}").into_bytes()),
                Err(e) => Err(e),
            }
        }
        "get_one_app" => {
            let app = inst.manager.get_one_app();
            match app {
                Ok(Some(a)) => serde_json::to_vec(&a).map_err(|e| e.to_string()),
                Ok(None) => Ok(b"null".to_vec()),
                Err(e) => Err(e),
            }
        }
        _ => Err(format!("no method {method}")),
    };

    match result {
        Ok(bytes) => write_out(bytes, out_data, out_len),
        Err(e) => {
            log_message(3, &format!("repo: {method} failed: {e}"));
            Err(ABI_ERR)
        }
    }
}

/// 写出响应字节（模块分配内存，宿主用模块 free 释放）
fn write_out(
    bytes: Vec<u8>,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    let len = bytes.len();
    let ptr = unsafe { libc::malloc(len.max(1)) };
    if ptr.is_null() { return Err(ABI_ERR); }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, len);
        *out_data = ptr as *mut u8;
        *out_len = len;
    }
    Ok(())
}

/// 解析 search_apps 参数：keyword（UTF-8）NUL 分隔 + limit（i32 LE）
fn parse_search_args(payload: *const u8, payload_len: usize) -> Result<(String, i32), String> {
    if payload.is_null() || payload_len < 5 {
        return Err("bad search args".to_string());
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload, payload_len) };
    let nul = bytes.iter().position(|&b| b == 0)
        .ok_or_else(|| "search args no NUL".to_string())?;
    let keyword = String::from_utf8_lossy(&bytes[..nul]).into_owned();
    let limit = i32::from_le_bytes(bytes[nul + 1..nul + 5].try_into().unwrap());
    Ok((keyword, limit))
}

fn destroy_impl(instance_id: u64) -> Result<(), c_int> {
    instances().lock().unwrap().remove(&instance_id);
    log_message(1, &format!("repo: instance {instance_id} destroyed"));
    Ok(())
}

// ==================== C ABI 导出 ====================

#[no_mangle]
pub extern "C" fn gstore_mod_repo_register(
    entry: *const GStoreModuleEntry,
    out: *mut GStoreModuleApi,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        if entry.is_null() || out.is_null() { return Err(ABI_ERR); }
        let e = unsafe { &*entry };
        if e.abi_version != GSTORE_MODULE_ABI_VERSION { return Err(ABI_ERR); }
        if let Some(f) = e.log { let _ = HOST_LOG.set(f); }
        let api = unsafe { &mut *out };
        api.name = c"repo".as_ptr();
        api.version = 1;
        api.min_host_abi = GSTORE_MODULE_ABI_VERSION;
        api.create = Some(create_export);
        api.call = Some(call_export);
        api.destroy = Some(destroy_export);
        api.shutdown = Some(shutdown_export);
        api.alloc = Some(alloc_export);
        api.free = Some(free_export);
        Ok(ABI_OK)
    }));
    result.unwrap_or(Err(ABI_ERR_PANIC)).unwrap_or(ABI_ERR)
}

pub extern "C" fn create_export(config: *const u8, config_len: usize, out: *mut u64) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| create_impl(config, config_len))) {
        Ok(Ok(id)) => { unsafe { *out = id }; ABI_OK }
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn call_export(
    instance: u64, method: *const c_char, payload: *const u8, payload_len: usize,
    out_data: *mut *mut u8, out_len: *mut usize,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| call_impl(instance, method, payload, payload_len, out_data, out_len))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn destroy_export(instance: u64) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| destroy_impl(instance))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn shutdown_export() -> c_int {
    instances().lock().unwrap().clear();
    ABI_OK
}

pub extern "C" fn alloc_export(size: usize) -> *mut c_void {
    unsafe { libc::malloc(size.max(1)) }
}

pub extern "C" fn free_export(ptr: *mut c_void) {
    if !ptr.is_null() { unsafe { libc::free(ptr) } }
}
