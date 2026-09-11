// gstore_mod_analyzer：APK 分析模块（独立 cdylib，架构文档第 3/5 章）
//
// 纯 Rust + C ABI，无 flutter_rust_bridge。宿主经 dlopen 握手后调用。
// 导出符号前缀 gstore_mod_analyzer_*（防符号内插）。
// 每个 extern "C" 入口包 catch_unwind（模块 panic 绝不越过边界）。
//
// 实例方法（call 分发）：
//   parse_apk_info(apk_path)       → JSON ApkInfo
//   parse_components(apk_path)     → JSON ApkComponents
//   scan_dex_classes(apk_path, patterns) → JSON String[]
//   scan_elf_page_sizes(apk_path)  → JSON ApkElfScanResult

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use gstore_contract::abi::{GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION};

mod apk;
mod components;
mod dex_scan;
mod elf;
mod models;

const ABI_OK: c_int = 0;
const ABI_ERR: c_int = -1;
const ABI_ERR_PANIC: c_int = -6;
const ABI_ERR_NO_INSTANCE: c_int = -4;
const ABI_ERR_NO_METHOD: c_int = -5;

/// 实例表：analyzer 无状态（架构"无状态域用静态调用"），实例仅作句柄占位
static INSTANCES: OnceLock<Mutex<std::collections::HashMap<u64, ()>>> = OnceLock::new();
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);
/// 宿主注入的日志回调（可空）
static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();

fn instances() -> &'static Mutex<std::collections::HashMap<u64, ()>> {
    INSTANCES.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

fn log_message(level: c_int, msg: &str) {
    if let Some(f) = HOST_LOG.get() {
        if let Ok(cmsg) = CString::new(msg) {
            f(level, cmsg.as_ptr());
        }
    }
}

// ==================== 实例方法实现（内部） ====================

fn create_impl(config: *const u8, config_len: usize) -> Result<u64, c_int> {
    let _ = (config, config_len);
    let id = NEXT_INSTANCE.fetch_add(1, Ordering::SeqCst);
    instances().lock().unwrap().insert(id, ());
    Ok(id)
}

fn call_impl(
    instance: u64,
    method: *const c_char,
    payload: *const u8,
    payload_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    let method = unsafe { CStr::from_ptr(method) }.to_string_lossy().into_owned();

    // 无状态模块：方法为纯静态调用（架构"无状态域用静态调用"），
    // 不强制要求实例存在（instance=0 也允许；create/destroy 仍维护完整生命周期）。
    let _ = instance;

    let result: Result<Vec<u8>, String> = match method.as_str() {
        "parse_apk_info" => {
            let apk_path = read_string_arg(payload, payload_len)
                .ok_or_else(|| "missing apk_path".to_string()).map_err(|_| ABI_ERR)?;
            crate::apk::parse_apk_info(apk_path)
                .map(|info| serde_json::to_vec(&info).unwrap_or_default())
        }
        "parse_components" => {
            let apk_path = read_string_arg(payload, payload_len)
                .ok_or_else(|| "missing apk_path".to_string()).map_err(|_| ABI_ERR)?;
            crate::components::parse_components(&apk_path)
                .map(|info| serde_json::to_vec(&info).unwrap_or_default())
        }
        "scan_dex_classes" => {
            // payload: [apk_path NUL] [pattern_count:i32] [patterns... NUL 分隔]
            let (apk_path, patterns) = parse_dex_args(payload, payload_len)
                .ok_or_else(|| "bad dex args".to_string()).map_err(|_| ABI_ERR)?;
            crate::dex_scan::scan_dex_classes(&apk_path, &patterns)
                .map(|classes| serde_json::to_vec(&classes).unwrap_or_default())
        }
        "scan_elf_page_sizes" => {
            let apk_path = read_string_arg(payload, payload_len)
                .ok_or_else(|| "missing apk_path".to_string()).map_err(|_| ABI_ERR)?;
            crate::elf::scan_elf_page_sizes(&apk_path)
                .map(|info| serde_json::to_vec(&info).unwrap_or_default())
        }
        "ping" => Ok(b"pong".to_vec()),
        _ => return Err(ABI_ERR_NO_METHOD),
    };

    match result {
        Ok(bytes) => {
            let len = bytes.len();
            let ptr = unsafe { libc::malloc(len.max(1)) };
            if ptr.is_null() {
                return Err(ABI_ERR);
            }
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, len);
                *out_data = ptr as *mut u8;
                *out_len = len;
            }
            Ok(())
        }
        Err(e) => {
            log_message(3, &format!("gstore_mod_analyzer: {e}"));
            Err(ABI_ERR)
        }
    }
}

/// 读取单个字符串参数（payload 整体作为一个 UTF-8 字符串）
fn read_string_arg(payload: *const u8, payload_len: usize) -> Option<String> {
    if payload.is_null() || payload_len == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload, payload_len) };
    String::from_utf8(bytes.to_vec()).ok()
}

/// 解析 DEX 扫描参数：apk_path（NUL 结尾）+ pattern 列表
fn parse_dex_args(payload: *const u8, payload_len: usize) -> Option<(String, Vec<String>)> {
    if payload.is_null() || payload_len == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload, payload_len) };
    // 第一个 NUL 分隔 apk_path 与 patterns 段
    let nul_pos = bytes.iter().position(|&b| b == 0)?;
    let apk_path = String::from_utf8(bytes[..nul_pos].to_vec()).ok()?;
    let rest = &bytes[nul_pos + 1..];
    // 剩余段：由 NUL 分隔的多个 pattern 字符串
    let patterns = rest
        .split(|&b| b == 0)
        .filter(|s| !s.is_empty())
        .filter_map(|s| String::from_utf8(s.to_vec()).ok())
        .collect();
    Some((apk_path, patterns))
}

fn destroy_impl(instance: u64) -> Result<(), c_int> {
    instances().lock().unwrap().remove(&instance);
    Ok(())
}

// ==================== C ABI 导出 ====================

/// 注册入口：宿主 dlsym 此符号并调用（握手）
#[no_mangle]
pub extern "C" fn gstore_mod_analyzer_register(
    entry: *const GStoreModuleEntry,
    out: *mut GStoreModuleApi,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        if entry.is_null() || out.is_null() {
            return Err(ABI_ERR);
        }
        let e = unsafe { &*entry };
        if e.abi_version != GSTORE_MODULE_ABI_VERSION {
            return Err(ABI_ERR);
        }
        if let Some(log_fn) = e.log {
            let _ = HOST_LOG.set(log_fn);
        }
        let api = unsafe { &mut *out };
        api.name = c"analyzer".as_ptr();
        api.version = 1;
        api.min_host_abi = GSTORE_MODULE_ABI_VERSION;
        api.init = None;
        api.create = Some(create_export);
        api.call = Some(call_export);
        api.cancel = None;
        api.destroy = Some(destroy_export);
        api.shutdown = Some(shutdown_export);
        api.alloc = Some(alloc_export);
        api.free = Some(free_export);
        Ok(ABI_OK)
    }));
    result.unwrap_or(Err(ABI_ERR_PANIC)).unwrap_or(ABI_ERR)
}

pub extern "C" fn create_export(config: *const u8, config_len: usize, out_instance: *mut u64) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| create_impl(config, config_len))) {
        Ok(Ok(id)) => {
            unsafe { *out_instance = id };
            ABI_OK
        }
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn call_export(
    instance: u64,
    method: *const c_char,
    payload: *const u8,
    payload_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| {
        call_impl(instance, method, payload, payload_len, out_data, out_len)
    })) {
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

/// 宿主在拷贝完响应后调用（模块 free）。
/// 跨 .so 边界无法传递 Rust Layout，故统一用 libc malloc/free 配对
/// （进程内共享符号，跨边界安全；Rust System 分配器底层即 malloc）。
pub extern "C" fn free_export(ptr: *mut c_void) {
    if !ptr.is_null() {
        unsafe { libc::free(ptr) };
    }
}