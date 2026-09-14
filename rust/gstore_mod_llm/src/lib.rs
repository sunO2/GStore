// gstore_mod_llm：本地大模型推理模块（独立 cdylib，架构文档第 3/5 章）
//
// 纯 Rust + C ABI，无 flutter_rust_bridge。宿主经 dlopen 握手后调用。
// 导出符号前缀 gstore_mod_llm_*（防符号内插）。
// 每个 extern "C" 入口包 catch_unwind（模块 panic 绝不越过边界）。
//
// 职责边界（有意为之）：
// - 本模块**只做推理引擎**（load/unload/generate/chat/status）。
// - **不在模块内起 HTTP/后台线程**——dlopen 的 .so 里 spawn 线程在 Android 上会
//   SIGSEGV（见 repo 模块同款结论）。OpenAI 兼容的本地端点由 Dart 侧承载并代理到本模块。
// - 模型文件下载/管理由 Dart（复用 DownloadManager）。

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use gstore_contract::abi::{
    ABI_ERR_ABI_MISMATCH, ABI_ERR_DETAIL, ABI_ERR_INTERNAL, ABI_ERR_NO_INSTANCE,
    ABI_ERR_NO_METHOD, ABI_ERR_NULL, ABI_ERR_PANIC, ABI_OK, GStoreModuleApi, GStoreModuleEntry,
    GSTORE_MODULE_ABI_VERSION,
};
use gstore_contract::error::ModuleError;

mod engine;

/// 单个推理实例（一个已加载模型 + 其生成参数）
///
/// 注意：这里**不再用外层 Mutex 包住整个引擎**——`EngineState` 内部自带两把锁
/// （engine 独占 / meta 只读），所以 `status` 这类查询不会被长推理阻塞。
pub struct LlmInstance {
    state: Arc<engine::EngineState>,
}

static INSTANCES: OnceLock<Mutex<HashMap<u64, Arc<LlmInstance>>>> = OnceLock::new();
static NEXT_INSTANCE: AtomicU64 = AtomicU64::new(1);
/// 宿主注入的日志回调（可空）
static HOST_LOG: OnceLock<extern "C" fn(c_int, *const c_char)> = OnceLock::new();
/// 宿主注入的事件回调（流式 token 走这里；可空）
static HOST_EMIT: OnceLock<extern "C" fn(u64, u64, *const u8, usize)> = OnceLock::new();

fn instances() -> &'static Mutex<HashMap<u64, Arc<LlmInstance>>> {
    INSTANCES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 通过宿主注入的 emit_event 回调推送事件（流式 token 用）。
/// 负载必须按宿主约定**加长度前缀帧**：`[u32 LE 类型长度][类型字节][数据]`。
pub(crate) fn emit_event(instance_id: u64, event_type: &str, payload: &[u8]) {
    let Some(f) = HOST_EMIT.get() else { return };
    let tb = event_type.as_bytes();
    let mut buf = Vec::with_capacity(4 + tb.len() + payload.len());
    buf.extend_from_slice(&(tb.len() as u32).to_le_bytes());
    buf.extend_from_slice(tb);
    buf.extend_from_slice(payload);
    f(0, instance_id, buf.as_ptr(), buf.len());
}

/// 通过宿主注入的 log 回调输出日志（模块内 `log::` 是独立静态，落不到 Dart，必须走这里）
pub(crate) fn log_message(level: c_int, msg: &str) {
    if let Some(f) = HOST_LOG.get() {
        if let Ok(cmsg) = CString::new(msg) {
            f(level, cmsg.as_ptr());
        }
    }
}

// ==================== 实例方法实现（内部） ====================

fn create_impl(config: *const u8, config_len: usize) -> Result<u64, c_int> {
    // config 暂未使用（模型经 load_model 指定）；预留
    let _ = (config, config_len);
    let id = NEXT_INSTANCE.fetch_add(1, Ordering::SeqCst);
    let state = Arc::new(engine::EngineState::default());
    state.set_instance_id(id);
    let inst = Arc::new(LlmInstance { state });
    instances().lock().unwrap().insert(id, inst);
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

    // 静态方法：无需实例（instance 可为 0）
    if method == "ping" {
        return write_out(b"pong".to_vec(), out_data, out_len);
    }
    if method == "capabilities" {
        let caps = serde_json::json!({
            "llama": cfg!(feature = "llama"),
            "abi_version": GSTORE_MODULE_ABI_VERSION,
        });
        return write_out(caps.to_string().into_bytes(), out_data, out_len);
    }

    // 实例方法：需要实例存在
    let inst = {
        let guard = instances().lock().unwrap();
        match guard.get(&instance) {
            Some(i) => i.clone(),
            None => return Err(ABI_ERR_NO_INSTANCE),
        }
    };

    log_message(
        1,
        &format!("llm: call {method} instance={instance} payload_len={payload_len}"),
    );

    let result: Result<Vec<u8>, ModuleError> = match method.as_str() {
        "load_model" => with_json(payload, payload_len, |v| inst.state.load(&v)),
        "unload_model" => inst
            .state
            .unload()
            .map(|j| j.to_string().into_bytes())
            .map_err(ModuleError::internal),
        "status" => Ok(inst.state.status().to_string().into_bytes()),
        "generate" => with_json(payload, payload_len, |v| inst.state.generate(&v)),
        "chat" => with_json(payload, payload_len, |v| inst.state.chat(&v)),
        _ => return Err(ABI_ERR_NO_METHOD),
    };

    match result {
        Ok(bytes) => write_out(bytes, out_data, out_len),
        Err(err) => write_error_out(err, out_data, out_len),
    }
}

/// 解析 JSON 载荷 → 执行闭包 → 序列化结果（统一错误映射）
fn with_json<F>(payload: *const u8, payload_len: usize, f: F) -> Result<Vec<u8>, ModuleError>
where
    F: FnOnce(serde_json::Value) -> Result<serde_json::Value, String>,
{
    if payload.is_null() || payload_len == 0 {
        return Err(ModuleError::invalid_arg("missing payload"));
    }
    let raw = unsafe { std::slice::from_raw_parts(payload, payload_len) };
    let value: serde_json::Value =
        serde_json::from_slice(raw).map_err(|e| ModuleError::invalid_arg(format!("bad json: {e}")))?;
    let out = f(value).map_err(ModuleError::internal)?;
    Ok(out.to_string().into_bytes())
}

/// 写出响应字节（模块分配内存，宿主用模块 free 释放）。
/// 统一 libc::malloc —— 与 free_export 的 libc::free 配对。
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
    log_message(3, &format!("gstore_mod_llm: {err}"));
    let _ = write_out(err.to_payload(), out_data, out_len);
    Err(ABI_ERR_DETAIL)
}

fn destroy_impl(instance: u64) -> Result<(), c_int> {
    if let Some(inst) = instances().lock().unwrap().remove(&instance) {
        // 显式卸载（释放模型显存/内存）
        let _ = inst.state.unload();
    }
    Ok(())
}

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
    log_message(
        1,
        &format!("gstore_mod_llm: on_event module_id={module_id} kind={kind} len={len}"),
    );
    Ok(())
}

// ==================== C ABI 导出 ====================

/// 模块 panic 静默 hook：避免默认 hook 生成 backtrace（gimli 符号化在 Android
/// dlopen 场景会二次崩溃）；日志经宿主日志回调输出。
fn install_panic_hook() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = info.payload().downcast_ref::<String>() {
                s.clone()
            } else {
                "unknown panic".to_string()
            };
            log_message(3, &format!("gstore_mod_llm panic: {msg}"));
        }));
    });
}

/// 注册入口：宿主 dlsym 此符号并调用（握手）
#[no_mangle]
pub extern "C" fn gstore_mod_llm_register(
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
        if let Some(emit_fn) = e.emit_event {
            let _ = HOST_EMIT.set(emit_fn);
        }
        install_panic_hook();

        let api = unsafe { &mut *out };
        api.name = c"llm".as_ptr();
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

pub extern "C" fn create_export(
    config: *const u8,
    config_len: usize,
    out_instance: *mut u64,
) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| create_impl(config, config_len))) {
        Ok(Ok(id)) => {
            if out_instance.is_null() {
                return ABI_ERR_NULL;
            }
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
    install_panic_hook();
    if method.is_null() {
        return ABI_ERR_NULL;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        call_impl(instance, method, payload, payload_len, out_data, out_len)
    }));
    match result {
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

pub extern "C" fn on_event_export(
    module_id: u64,
    kind: *const c_char,
    data: *const u8,
    data_len: usize,
) -> c_int {
    match catch_unwind(AssertUnwindSafe(|| {
        on_event_impl(module_id, kind, data, data_len)
    })) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

pub extern "C" fn shutdown_export() -> c_int {
    if let Ok(mut guard) = instances().lock() {
        for (_, inst) in guard.drain() {
            let _ = inst.state.unload();
        }
    }
    ABI_OK
}

pub extern "C" fn alloc_export(size: usize) -> *mut c_void {
    unsafe { libc::malloc(size) }
}

pub extern "C" fn free_export(ptr: *mut c_void) {
    if !ptr.is_null() {
        unsafe { libc::free(ptr) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_reports_feature_flag() {
        let value: serde_json::Value =
            serde_json::from_str(&format!("{{\"llama\": {}}}", cfg!(feature = "llama"))).unwrap();
        assert!(value["llama"].is_boolean());
    }

    #[test]
    fn create_and_status_roundtrip() {
        let id = create_impl(std::ptr::null(), 0).expect("create");
        let inst = instances().lock().unwrap().get(&id).cloned().expect("instance");
        let status = inst.state.status();
        assert_eq!(status["loaded"], serde_json::json!(false));
        destroy_impl(id).expect("destroy");
    }

    #[test]
    fn load_model_reports_missing_file() {
        let id = create_impl(std::ptr::null(), 0).expect("create");
        let inst = instances().lock().unwrap().get(&id).cloned().expect("instance");
        let err = inst
            .state
            .load(&serde_json::json!({"path": "/nonexistent/model.gguf"}))
            .unwrap_err();
        assert!(err.contains("not found") || err.contains("不存在"), "got: {err}");
        destroy_impl(id).expect("destroy");
    }
}
