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
//   scan_apk_structure(apk_path)   → JSON ApkStructure（只读中央目录，不解压）

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use gstore_contract::abi::{
    ABI_ERR_ABI_MISMATCH, ABI_ERR_DETAIL, ABI_ERR_INTERNAL, ABI_ERR_NULL, ABI_ERR_PANIC, ABI_OK,
    GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
};
use gstore_contract::error::ModuleError;

mod apk;
mod build_versions;
mod components;
mod dex_scan;
mod dex_stats;
mod elf;
mod features;
mod manifest;
mod models;
mod report;
mod rules;
mod signature;
mod structure;

/// 实例表：analyzer 无状态（架构"无状态域用静态调用"），实例仅作句柄占位
static INSTANCES: OnceLock<Mutex<std::collections::HashMap<u64, gstore_contract::context::ModuleContext>>> = OnceLock::new();
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);
/// 宿主注入的日志回调（可空）
static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();

fn instances() -> &'static Mutex<std::collections::HashMap<u64, gstore_contract::context::ModuleContext>> {
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
    // 标准上下文（宿主注入）：约定见 gstore_contract::context。
    // analyzer 当前不落盘，但上下文存入实例，便于诊断并为后续能力（数据目录/缓存）预留。
    let ctx = if config.is_null() || config_len == 0 {
        gstore_contract::context::ModuleContext::default()
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(config, config_len) };
        gstore_contract::context::ModuleContext::parse(bytes)
    };
    let id = NEXT_INSTANCE.fetch_add(1, Ordering::SeqCst);
    instances().lock().unwrap().insert(id, ctx.clone());
    log_message(
        1,
        &format!(
            "analyzer: instance {id} created (data_dir={}, cache_dir={}, abi={})",
            if ctx.data_dir.is_empty() { "-" } else { &ctx.data_dir },
            if ctx.cache_dir.is_empty() { "-" } else { &ctx.cache_dir },
            if ctx.abi.is_empty() { "-" } else { &ctx.abi }
        ),
    );
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

    let dispatch = || -> Result<Vec<u8>, ModuleError> {
        match method.as_str() {
            "parse_apk_info" => {
                let apk_path = read_string_arg(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("missing apk_path"))?;
                crate::apk::parse_apk_info(apk_path)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            "parse_components" => {
                let apk_path = read_string_arg(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("missing apk_path"))?;
                crate::components::parse_components(&apk_path)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            "scan_dex_classes" => {
                // payload: [apk_path NUL] [pattern_count:i32] [patterns... NUL 分隔]
                let (apk_path, patterns) = parse_dex_args(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("bad dex args"))?;
                crate::dex_scan::scan_dex_classes(&apk_path, &patterns)
                    .map(|classes| serde_json::to_vec(&classes).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            "scan_elf_page_sizes" => {
                // payload: apk_path [NUL abi1,abi2,...]（第二段可选，空/缺省 = 不过滤）
                let (apk_path, filter) =
                    parse_apk_and_abis(payload, payload_len).ok_or_else(|| {
                        ModuleError::invalid_arg("missing apk_path")
                    })?;
                crate::elf::scan_elf_page_sizes(&apk_path, filter.as_deref())
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            // APK 结构清单：只读中央目录、不解压（替代宿主侧 3 次全量解压）
            "scan_apk_structure" => {
                let apk_path = read_string_arg(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("missing apk_path"))?;
                crate::structure::scan_apk_structure(&apk_path)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            // DEX 统计：每文件类数量（只读 dex 头）+ CRC32
            "scan_dex_stats" => {
                let apk_path = read_string_arg(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("missing apk_path"))?;
                crate::dex_stats::scan_dex_stats(&apk_path)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            // Manifest 深度提取：权限（含 maxSdkVersion）/ 组件 intent-filter / meta-data /
            // 静态库 / compileSdk / sharedUserId
            "parse_manifest" => {
                let apk_path = read_string_arg(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("missing apk_path"))?;
                crate::manifest::parse_manifest(&apk_path)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            // 签名方案检测 V1–V4（纯字节，不校验）
            "detect_signature_schemes" => {
                let apk_path = read_string_arg(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("missing apk_path"))?;
                crate::signature::detect_signature_schemes(&apk_path)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            // 构建版本：Kotlin / Gradle / Java / Compose / AGP（只解压少量小条目）
            "scan_build_versions" => {
                let apk_path = read_string_arg(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("missing apk_path"))?;
                crate::build_versions::detect_build_versions(&apk_path)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            // 特征识别：Kotlin / Compose / KMP / Xposed / PlaySigning / PWA / AGP
            "scan_features" => {
                let apk_path = read_string_arg(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("missing apk_path"))?;
                crate::features::scan_features(&apk_path)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            // 规则匹配：payload = apk_path NUL rules_json
            "match_libraries" => {
                let (apk_path, rules_json) = parse_apk_and_text(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("bad payload"))?;
                crate::rules::match_libraries(&apk_path, &rules_json)
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            // 聚合报告：payload = apk_path NUL rules_json [NUL abis_csv]
            // 一次打开 APK 产出全部节（快照采集用：避免逐节重复解析与跨时点不一致）
            "scan_apk_report" => {
                let (apk_path, text) = parse_apk_and_text(payload, payload_len)
                    .ok_or_else(|| ModuleError::invalid_arg("bad payload"))?;
                // 可选第三段：abi1,abi2（逗号分隔）；不存在则解析全部 ABI
                let (rules, abis) = match text.split_once('\u{0}') {
                    Some((rules, abi_text)) => {
                        let abis: Vec<String> = abi_text
                            .split(',')
                            .map(|s| s.trim())
                            .filter(|s| !s.is_empty())
                            .map(|s| s.to_string())
                            .collect();
                        (
                            rules.to_string(),
                            if abis.is_empty() { None } else { Some(abis) },
                        )
                    }
                    None => (text.clone(), None),
                };
                crate::report::scan_apk_report(&apk_path, &rules, abis.as_deref())
                    .map(|info| serde_json::to_vec(&info).unwrap_or_default())
                    .map_err(ModuleError::internal)
            }
            "ping" => Ok(b"pong".to_vec()),
            _ => Err(ModuleError::method_not_found(&method)),
        }
    };

    match dispatch() {
        Ok(bytes) => write_out(bytes, out_data, out_len),
        Err(err) => write_error_out(err, out_data, out_len),
    }
}

/// 写出响应字节（模块分配内存，宿主用模块 free 释放）
fn write_out(bytes: Vec<u8>, out_data: *mut *mut u8, out_len: *mut usize) -> Result<(), c_int> {
    let len = bytes.len();
    let ptr = unsafe { libc::malloc(len.max(1)) };
    if ptr.is_null() {
        return Err(ABI_ERR_INTERNAL);
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr as *mut u8, len);
        *out_data = ptr as *mut u8;
        *out_len = len;
    }
    Ok(())
}

/// 写出结构化错误载荷并以 ABI_ERR_DETAIL 返回（宿主据此还原 StatusCode/code/message）
fn write_error_out(
    err: ModuleError,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> Result<(), c_int> {
    log_message(3, &format!("gstore_mod_analyzer: {err}"));
    let _ = write_out(err.to_payload(), out_data, out_len);
    Err(ABI_ERR_DETAIL)
}

/// 读取单个字符串参数（payload 整体作为一个 UTF-8 字符串）
fn read_string_arg(payload: *const u8, payload_len: usize) -> Option<String> {
    if payload.is_null() || payload_len == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload, payload_len) };
    String::from_utf8(bytes.to_vec()).ok()
}

/// 解析 `apk_path [NUL abi1,abi2,...]`：第二段可选，逗号分隔 ABI 过滤列表。
/// 返回 (apk_path, Option<abis>)；过滤段为空/缺省时返回 None（不过滤）。
fn parse_apk_and_abis(
    payload: *const u8,
    payload_len: usize,
) -> Option<(String, Option<Vec<String>>)> {
    if payload.is_null() || payload_len == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload, payload_len) };
    let apk_path = match bytes.iter().position(|&b| b == 0) {
        Some(pos) => {
            let path = String::from_utf8(bytes[..pos].to_vec()).ok()?;
            let rest = &bytes[pos + 1..];
            let filter = String::from_utf8(rest.to_vec()).ok()?;
            let abis: Vec<String> = filter
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
                .collect();
            return Some((path, if abis.is_empty() { None } else { Some(abis) }));
        }
        None => String::from_utf8(bytes.to_vec()).ok()?,
    };
    Some((apk_path, None))
}

/// 解析 `apk_path NUL text`：第二段为原样文本（如规则 JSON），NUL 必须是分隔符
fn parse_apk_and_text(payload: *const u8, payload_len: usize) -> Option<(String, String)> {
    if payload.is_null() || payload_len == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(payload, payload_len) };
    let pos = bytes.iter().position(|&b| b == 0)?;
    let apk_path = String::from_utf8(bytes[..pos].to_vec()).ok()?;
    let text = String::from_utf8(bytes[pos + 1..].to_vec()).ok()?;
    Some((apk_path, text))
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

/// 宿主下发应用事件（下行订阅）。analyzer 无状态、暂不消费，记录日志即可。
fn on_event_impl(
    module_id: u64,
    kind: *const c_char,
    data: *const u8,
    data_len: usize,
) -> Result<(), c_int> {
    if kind.is_null() {
        return Err(ABI_ERR_NULL);
    }
    let kind = unsafe { CStr::from_ptr(kind) }.to_string_lossy().into_owned();
    let len = if data.is_null() { 0 } else { data_len };
    log_message(1, &format!("gstore_mod_analyzer: on_event module_id={module_id} kind={kind} len={len}"));
    Ok(())
}

pub extern "C" fn on_event_export(
    module_id: u64,
    kind: *const c_char,
    data: *const u8,
    data_len: usize,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| on_event_impl(module_id, kind, data, data_len))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
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
            return Err(ABI_ERR_NULL);
        }
        let e = unsafe { &*entry };
        if e.abi_version != GSTORE_MODULE_ABI_VERSION {
            return Err(ABI_ERR_ABI_MISMATCH);
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
        api.on_event = Some(on_event_export);
        Ok(ABI_OK)
    }));
    result.unwrap_or(Err(ABI_ERR_PANIC)).unwrap_or_else(|code| code)
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
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_parses_module_context() {
        // 宿主注入的标准上下文（JSON）应被解析并存入实例
        let ctx = gstore_contract::context::ModuleContext {
            data_dir: "/data/x".into(),
            cache_dir: "/cache/x".into(),
            abi: "arm64-v8a".into(),
            ..Default::default()
        };
        let bytes = ctx.encode();
        let mut instance: u64 = 0;
        let rc = create_export(bytes.as_ptr(), bytes.len(), &mut instance);
        assert_eq!(rc, ABI_OK);
        let stored = instances()
            .lock()
            .unwrap()
            .get(&instance)
            .cloned()
            .unwrap_or_default();
        assert_eq!(stored.data_dir, "/data/x");
        assert_eq!(stored.abi, "arm64-v8a");
        instances().lock().unwrap().remove(&instance);
    }

    #[test]
    fn create_without_config_uses_default_context() {
        let mut instance: u64 = 0;
        let rc = create_export(std::ptr::null(), 0, &mut instance);
        assert_eq!(rc, ABI_OK);
        let stored = instances()
            .lock()
            .unwrap()
            .get(&instance)
            .cloned()
            .unwrap_or_default();
        assert!(stored.data_dir.is_empty());
        instances().lock().unwrap().remove(&instance);
    }
}
