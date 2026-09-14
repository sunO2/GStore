// gstore_mod_qr：二维码解码模块（独立 cdylib，架构文档第 3/5 章）
//
// 纯 Rust + C ABI，无 flutter_rust_bridge。宿主经 dlopen 握手后调用。
// 导出符号前缀 gstore_mod_qr_*（防符号内插）。
// 每个 extern "C" 入口包 catch_unwind（模块 panic 绝不越过边界）。

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use gstore_contract::abi::{
    ABI_ERR_ABI_MISMATCH, ABI_ERR_DETAIL, ABI_ERR_INTERNAL, ABI_ERR_NO_INSTANCE,
    ABI_ERR_NO_METHOD, ABI_ERR_NULL, ABI_ERR_PANIC, ABI_OK, GStoreModuleApi, GStoreModuleEntry,
    GSTORE_MODULE_ABI_VERSION,
};
use gstore_contract::error::ModuleError;

/// 实例表：QR 解码无状态（架构"无状态域用静态调用"），实例仅作句柄占位。
/// create 分配 id，call 按 id 校验存在，destroy 移除——生命周期语义完整。
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
    // qr 当前不落盘，但上下文存入实例，便于诊断并为后续能力（数据目录/缓存）预留。
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
            "qr: instance {id} created (data_dir={}, cache_dir={}, abi={})",
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

    let result: Result<Vec<u8>, ModuleError> = match method.as_str() {
        // 实例方法：需实例存在（decode_luma 无状态，实例仅句柄占位）
        "decode_luma" => {
            if !instances().lock().unwrap().contains_key(&instance) {
                return Err(ABI_ERR_NO_INSTANCE);
            }
            if payload_len < 8 {
                Err(ModuleError::invalid_arg("payload too short"))
            } else {
                let luma = unsafe { std::slice::from_raw_parts(payload, payload_len) };
                // payload 布局: [width:i32][height:i32][luma...]
                let width = i32::from_le_bytes(luma[0..4].try_into().unwrap());
                let height = i32::from_le_bytes(luma[4..8].try_into().unwrap());
                let luma_data = &luma[8..];
                decode_qr_luma(luma_data, width, height).map_err(ModuleError::internal)
            }
        }
        // 静态方法：无需实例（instance 可为 0）
        "ping" => Ok(b"pong".to_vec()),
        _ => return Err(ABI_ERR_NO_METHOD),
    };

    match result {
        Ok(bytes) => write_out(bytes, out_data, out_len),
        Err(err) => write_error_out(err, out_data, out_len),
    }
}

/// 写出响应字节（模块分配内存，宿主用模块 free 释放）。
/// 统一 libc::malloc —— 与 free_export 的 libc::free 配对（不得用 std::alloc 混搭）。
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
    log_message(3, &format!("gstore_mod_qr: {err}"));
    let _ = write_out(err.to_payload(), out_data, out_len);
    Err(ABI_ERR_DETAIL)
}

fn destroy_impl(instance: u64) -> Result<(), c_int> {
    instances().lock().unwrap().remove(&instance);
    Ok(())
}

/// 宿主下发应用事件（下行订阅）。QR 模块无状态、暂不消费，记录日志即可。
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
    log_message(1, &format!("gstore_mod_qr: on_event module_id={module_id} kind={kind} len={len}"));
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

/// 解码一帧灰度图（多策略：原图/增强图 × 二值化器；返回 JSON 编码结果或 "null"）
///
/// 单一策略在极端光照下不稳：
/// - 屏幕码/反光 → 局部过曝，模块对比度丢失 → 需 CLAHE + 对比度拉伸还原；
/// - 暗光 → 整体低对比 + 噪声 → 需拉伸 + LocalAverage；
/// - 远距离小码 → 边缘退化 → 需 unsharp 锐化后重试。
fn decode_qr_luma(luma: &[u8], width: i32, height: i32) -> Result<Vec<u8>, String> {
    if luma.is_empty() || width <= 0 || height <= 0 {
        return Ok(b"null".to_vec());
    }
    let expect = (width as usize).checked_mul(height as usize).ok_or("尺寸溢出")?;
    if luma.len() < expect {
        return Err(format!("luma 长度不足: {} < {}", luma.len(), expect));
    }
    let base = &luma[..expect];

    // 1) 原图 + LocalAverage（常规光照，成本最低，命中即返回）
    if let Some(json) = try_decode(base, width, height, zxingcpp::Binarizer::LocalAverage) {
        return Ok(json);
    }

    // 2) 增强图（对比度拉伸 + CLAHE + 轻锐化）+ LocalAverage（暗光/过曝/光照不均）
    let (w, h) = (expect / height.max(1) as usize, height as usize);
    let enhanced = enhance_luma(base, w, h);
    if let Some(json) = try_decode(&enhanced, width, height, zxingcpp::Binarizer::LocalAverage) {
        return Ok(json);
    }

    // 3) 增强图 + BoolCast（极端明暗、LocalAverage 失效时）
    if let Some(json) = try_decode(&enhanced, width, height, zxingcpp::Binarizer::BoolCast) {
        return Ok(json);
    }

    Ok(b"null".to_vec())
}

/// 单次解码尝试；命中返回结果 JSON，未命中返回 None（含"检测到但不可读"的候选点）
fn try_decode(bytes: &[u8], width: i32, height: i32, bin: zxingcpp::Binarizer) -> Option<Vec<u8>> {
    let image = zxingcpp::ImageView::from_slice(bytes, width, height, zxingcpp::ImageFormat::Lum).ok()?;
    let reader = zxingcpp::read()
        .try_harder(true)
        .try_rotate(false)
        .try_invert(true)
        .return_errors(true)
        .max_number_of_symbols(1)
        .binarizer(bin)
        .formats(&[zxingcpp::BarcodeFormat::QRCode]);

    let results = reader.from(&image).ok()?;
    let mut candidate: Option<Vec<u8>> = None;
    for b in results {
        if b.is_valid() {
            return Some(barcode_json(&b));
        }
        // 检测到但未解析成功：保留候选（text 为空 + 定位点），供 UI 引导与自动变焦使用
        if candidate.is_none() {
            candidate = Some(barcode_json(&b));
        }
    }
    candidate
}

fn barcode_json(b: &zxingcpp::Barcode) -> Vec<u8> {
    serde_json::json!({
        "text": b.text(),
        "format": b.format().to_string(),
        "points": points_to_vec(b),
        "raw_bytes": b.bytes(),
        "is_mirrored": b.is_mirrored(),
        "is_inverted": b.is_inverted(),
        // 解码证据：宿主据此区分「完全可读」/「定位到但校验失败」/「码制问题」，
        // 作为对焦、变焦、曝光闭环的判据（仅靠 text 是否为空区分不出失败原因）。
        "is_valid": b.is_valid(),
        "error": barcode_error_kind(b),
        "orientation": b.orientation(),
    })
    .to_string()
    .into_bytes()
}

/// 不可读候选的失败类型。
/// - `none`：无错误（成功解码）；
/// - `checksum`：定位/取样成功但校验失败 —— 几何可信、像素质量不足，
///   是「该调焦段/该提对比度」的强信号；
/// - `format` / `unsupported`：码制或格式问题，调焦距无收益。
fn barcode_error_kind(b: &zxingcpp::Barcode) -> &'static str {
    match b.error() {
        zxingcpp::BarcodeError::None() => "none",
        zxingcpp::BarcodeError::Checksum(_) => "checksum",
        zxingcpp::BarcodeError::Format(_) => "format",
        zxingcpp::BarcodeError::Unsupported(_) => "unsupported",
    }
}

/// 解码前增强：对比度拉伸 → CLAHE → 轻锐化（各步均为 O(w·h)，无额外分配放大）
fn enhance_luma(luma: &[u8], w: usize, h: usize) -> Vec<u8> {
    if w == 0 || h == 0 || luma.len() < w * h {
        return luma.to_vec();
    }
    let stretched = stretch_contrast(luma);
    let equalized = clahe_lite(&stretched, w, h, 8, 2.5);
    unsharp(&equalized, w, h)
}

/// 百分位线性对比度拉伸（1%..99%），消除雾感/低对比
fn stretch_contrast(luma: &[u8]) -> Vec<u8> {
    let mut hist = [0u32; 256];
    for &v in luma {
        hist[v as usize] += 1;
    }
    let total = luma.len() as u32;
    if total == 0 {
        return luma.to_vec();
    }
    let low_cut = (total as f32 * 0.01) as u32;
    let high_cut = (total as f32 * 0.99) as u32;

    let mut acc = 0u32;
    let mut lo = 0usize;
    for (i, &c) in hist.iter().enumerate() {
        acc += c;
        if acc >= low_cut {
            lo = i;
            break;
        }
    }
    acc = 0;
    let mut hi = 255usize;
    for i in (0..256).rev() {
        acc += hist[i];
        if acc >= total - high_cut {
            hi = i;
            break;
        }
    }
    if hi <= lo {
        return luma.to_vec();
    }
    let scale = 255.0 / (hi as f32 - lo as f32);
    luma.iter()
        .map(|&v| ((v as f32 - lo as f32) * scale).clamp(0.0, 255.0) as u8)
        .collect()
}

/// CLAHE-lite：分块直方图均衡（带裁剪限幅）+ 双线性插值。
/// 专治屏幕反光/单侧过曝这类**局部**光照不均（整体拉伸解决不了）。
fn clahe_lite(luma: &[u8], w: usize, h: usize, tiles: usize, clip_limit: f32) -> Vec<u8> {
    if w == 0 || h == 0 || luma.len() < w * h || tiles == 0 {
        return luma.to_vec();
    }
    let tw = (w + tiles - 1) / tiles;
    let th = (h + tiles - 1) / tiles;
    if tw == 0 || th == 0 {
        return luma.to_vec();
    }
    let clip = (clip_limit * (tw * th) as f32 / 256.0).max(1.0);

    // 每块映射表
    let mut maps: Vec<[u8; 256]> = Vec::with_capacity(tiles * tiles);
    for ty in 0..tiles {
        for tx in 0..tiles {
            let x0 = tx * tw;
            let y0 = ty * th;
            let x1 = ((tx + 1) * tw).min(w);
            let y1 = ((ty + 1) * th).min(h);
            let mut hist = [0f32; 256];
            let mut n = 0f32;
            for y in y0..y1 {
                let row = y * w;
                for x in x0..x1 {
                    hist[luma[row + x] as usize] += 1.0;
                    n += 1.0;
                }
            }
            let mut map = [0u8; 256];
            if n == 0.0 {
                for (i, m) in map.iter_mut().enumerate() {
                    *m = i as u8;
                }
                maps.push(map);
                continue;
            }
            // 裁剪限幅：超出部分均摊回直方图
            let mut excess = 0.0;
            for c in hist.iter_mut() {
                if *c > clip {
                    excess += *c - clip;
                    *c = clip;
                }
            }
            let inc = excess / 256.0;
            for c in hist.iter_mut() {
                *c += inc;
            }
            // CDF → 映射
            let mut cum = 0.0;
            let scale = 255.0 / n;
            for i in 0..256 {
                cum += hist[i];
                map[i] = (cum * scale).clamp(0.0, 255.0) as u8;
            }
            maps.push(map);
        }
    }

    // 双线性插值：像素落在四个相邻块映射之间加权
    let mut out = vec![0u8; w * h];
    for y in 0..h {
        let fy = (y as f32 / th as f32) - 0.5;
        let ty0 = fy.floor().max(0.0) as usize;
        let ty1 = (ty0 + 1).min(tiles - 1);
        let wy = (fy - ty0 as f32).clamp(0.0, 1.0);
        let row = y * w;
        for x in 0..w {
            let fx = (x as f32 / tw as f32) - 0.5;
            let tx0 = fx.floor().max(0.0) as usize;
            let tx1 = (tx0 + 1).min(tiles - 1);
            let wx = (fx - tx0 as f32).clamp(0.0, 1.0);
            let v = luma[row + x] as usize;
            let v00 = maps[ty0 * tiles + tx0][v] as f32;
            let v01 = maps[ty0 * tiles + tx1][v] as f32;
            let v10 = maps[ty1 * tiles + tx0][v] as f32;
            let v11 = maps[ty1 * tiles + tx1][v] as f32;
            let a = v00 * (1.0 - wx) + v01 * wx;
            let b = v10 * (1.0 - wx) + v11 * wx;
            out[row + x] = (a * (1.0 - wy) + b * wy).clamp(0.0, 255.0) as u8;
        }
    }
    out
}

/// 3×3 轻锐化（unsharp mask）：提升远距离小码退化的边缘，幅度温和避免放大噪声
fn unsharp(luma: &[u8], w: usize, h: usize) -> Vec<u8> {
    if w < 3 || h < 3 || luma.len() < w * h {
        return luma.to_vec();
    }
    let mut out = luma.to_vec();
    for y in 1..h - 1 {
        for x in 1..w - 1 {
            let i = y * w + x;
            let blur = (luma[i - w - 1] as u32
                + luma[i - w] as u32
                + luma[i - w + 1] as u32
                + luma[i - 1] as u32
                + luma[i] as u32
                + luma[i + 1] as u32
                + luma[i + w - 1] as u32
                + luma[i + w] as u32
                + luma[i + w + 1] as u32)
                / 9;
            let v = luma[i] as i32;
            let sharpened = v + (v - blur as i32) * 3 / 4;
            out[i] = sharpened.clamp(0, 255) as u8;
        }
    }
    out
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
            return Err(ABI_ERR_NULL);
        }
        let e = unsafe { &*entry };
        if e.abi_version != GSTORE_MODULE_ABI_VERSION {
            return Err(ABI_ERR_ABI_MISMATCH);
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

#[cfg(test)]
mod tests {

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
        let rc = super::create_export(bytes.as_ptr(), bytes.len(), &mut instance);
        assert_eq!(rc, ABI_OK);
        let stored = super::instances()
            .lock()
            .unwrap()
            .get(&instance)
            .cloned()
            .unwrap_or_default();
        assert_eq!(stored.data_dir, "/data/x");
        assert_eq!(stored.cache_dir, "/cache/x");
        assert_eq!(stored.abi, "arm64-v8a");
        super::instances().lock().unwrap().remove(&instance);
    }

    #[test]
    fn create_without_config_uses_default_context() {
        let mut instance: u64 = 0;
        let rc = super::create_export(std::ptr::null(), 0, &mut instance);
        assert_eq!(rc, ABI_OK);
        let stored = super::instances()
            .lock()
            .unwrap()
            .get(&instance)
            .cloned()
            .unwrap_or_default();
        assert!(stored.data_dir.is_empty());
        super::instances().lock().unwrap().remove(&instance);
    }
    use super::*;

    /// 合成一张中心为二维码样式的低对比度灰度图（模拟暗光/过曝场景）
    fn synthetic_low_contrast(w: usize, h: usize) -> Vec<u8> {
        let mut v = vec![60u8; w * h];
        for y in (h / 4)..(h * 3 / 4) {
            for x in (w / 4)..(w * 3 / 4) {
                v[y * w + x] = 80; // 只有 20 级差
            }
        }
        v
    }

    #[test]
    fn enhance_preserves_dimensions() {
        let (w, h) = (64usize, 48usize);
        let src = synthetic_low_contrast(w, h);
        let out = enhance_luma(&src, w, h);
        assert_eq!(out.len(), w * h, "增强后长度必须与输入一致");
    }

    #[test]
    fn stretch_expands_contrast() {
        let src = synthetic_low_contrast(64, 48);
        let out = stretch_contrast(&src);
        let min = *out.iter().min().unwrap();
        let max = *out.iter().max().unwrap();
        // 原图动态范围仅 20 级，拉伸后应显著扩大
        assert!(max - min > 100, "对比度拉伸应扩大动态范围 (got {min}..{max})");
    }

    #[test]
    fn degrades_gracefully_on_tiny_input() {
        // 小于 3×3 时 unsharp 直接返回原图，不应 panic
        let src = vec![10u8, 20, 30, 40];
        let out = unsharp(&src, 2, 2);
        assert_eq!(out, src);
    }
}
