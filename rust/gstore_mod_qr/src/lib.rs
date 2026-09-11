// gstore_mod_qr：二维码解码模块（独立 cdylib，架构文档第 3/5 章）
//
// 纯 Rust + C ABI，无 flutter_rust_bridge。宿主经 dlopen 握手后调用。
// 导出符号前缀 gstore_mod_qr_*（防符号内插）。
// 每个 extern "C" 入口包 catch_unwind（模块 panic 绝不越过边界）。

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use gstore_contract::abi::{GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION};

const ABI_OK: c_int = 0;
const ABI_ERR: c_int = -1;
const ABI_ERR_PANIC: c_int = -6;
const ABI_ERR_NO_INSTANCE: c_int = -4;
const ABI_ERR_NO_METHOD: c_int = -5;

/// 实例表：QR 解码无状态（架构"无状态域用静态调用"），实例仅作句柄占位。
/// create 分配 id，call 按 id 校验存在，destroy 移除——生命周期语义完整。
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
    // config 暂未使用（QR 解码器无状态）；预留
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

    let result: Result<Vec<u8>, String> = match method.as_str() {
        // 实例方法：需实例存在（decode_luma 无状态，实例仅句柄占位）
        "decode_luma" => {
            if !instances().lock().unwrap().contains_key(&instance) {
                return Err(ABI_ERR_NO_INSTANCE);
            }
            let luma = unsafe { std::slice::from_raw_parts(payload, payload_len) };
            // payload 布局: [width:i32][height:i32][luma...]
            if payload_len < 8 {
                return Err("payload too short".to_string()).map_err(|e| { let _ = e; ABI_ERR });
            }
            let width = i32::from_le_bytes(luma[0..4].try_into().unwrap());
            let height = i32::from_le_bytes(luma[4..8].try_into().unwrap());
            let luma_data = &luma[8..];
            decode_qr_luma(luma_data, width, height)
        }
        // 静态方法：无需实例（instance 可为 0）
        "ping" => Ok(b"pong".to_vec()),
        _ => return Err(ABI_ERR_NO_METHOD),
    };

    match result {
        Ok(bytes) => {
            // 模块分配响应内存（宿主会用模块的 free 释放）
            let len = bytes.len();
            let ptr = unsafe { std::alloc::alloc(std::alloc::Layout::array::<u8>(len).unwrap()) };
            unsafe {
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, len);
                *out_data = ptr;
                *out_len = len;
            }
            Ok(())
        }
        Err(e) => {
            log_message(3, &format!("gstore_mod_qr: {e}"));
            Err(ABI_ERR)
        }
    }
}

fn destroy_impl(instance: u64) -> Result<(), c_int> {
    instances().lock().unwrap().remove(&instance);
    Ok(())
}

/// 解码一帧灰度图（返回 JSON 编码结果或 "null"）
fn decode_qr_luma(luma: &[u8], width: i32, height: i32) -> Result<Vec<u8>, String> {
    if luma.is_empty() || width <= 0 || height <= 0 {
        return Ok(b"null".to_vec());
    }
    let expect = (width as usize).checked_mul(height as usize).ok_or("尺寸溢出")?;
    if luma.len() < expect {
        return Err(format!("luma 长度不足: {} < {}", luma.len(), expect));
    }
    let image = zxingcpp::ImageView::from_slice(&luma[..expect], width, height, zxingcpp::ImageFormat::Lum)
        .map_err(|e| format!("ImageView 构造失败: {e}"))?;

    let reader = zxingcpp::read()
        .try_harder(true)
        .try_rotate(false)
        .try_invert(true)
        .return_errors(true)
        .max_number_of_symbols(1)
        .formats(&[zxingcpp::BarcodeFormat::QRCode]);

    let results = reader.from(&image).map_err(|e| format!("解码失败: {e}"))?;

    for b in results {
        if b.is_valid() {
            return Ok(serde_json::json!({
                "text": b.text(),
                "format": b.format().to_string(),
                "points": points_to_vec(&b),
                "raw_bytes": b.bytes(),
                "is_mirrored": b.is_mirrored(),
                "is_inverted": b.is_inverted(),
            })
            .to_string()
            .into_bytes());
        }
    }
    Ok(b"null".to_vec())
}

fn points_to_vec(b: &zxingcpp::Barcode) -> Vec<f64> {
    let p = b.position();
    vec![
        p.top_left.x as f64, p.top_left.y as f64,
        p.top_right.x as f64, p.top_right.y as f64,
        p.bottom_right.x as f64, p.bottom_right.y as f64,
        p.bottom_left.x as f64, p.bottom_left.y as f64,
    ]
}

// ==================== C ABI 导出 ====================

/// 注册入口：宿主 dlsym 此符号并调用（握手）
#[no_mangle]
pub extern "C" fn gstore_mod_qr_register(
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
        // 填充能力表
        let api = unsafe { &mut *out };
        api.name = c"qr".as_ptr();
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
    unsafe { libc::malloc(size) }
}

/// 宿主在拷贝完响应后调用（模块 free）。
/// 跨 .so 边界无法传递 Rust Layout，故统一用 libc malloc/free 配对
/// （进程内共享符号，跨边界安全；Rust System 分配器底层即 malloc）。
pub extern "C" fn free_export(ptr: *mut c_void) {
    if !ptr.is_null() {
        unsafe { libc::free(ptr) };
    }
}
