//! gstore_mod_perf：设备性能监控模块（独立 cdylib，只读 `/proc` + `/sys` + `getprop`）。
//!
//! 纯 Rust + C ABI，无 flutter_rust_bridge。宿主经 `dlopen` 握手后调用。
//! 导出符号前缀 `gstore_mod_perf_*`（防符号内插）。每个 `extern "C"` 入口包
//! `catch_unwind`（模块 panic 绝不越过边界）。
//!
//! 设计要点：采集逻辑在 [`collectors`]（纯函数、可单测），编排在 [`snapshot`]，
//! 方法分发在 [`methods`]，采样线程在 [`sampler`]。

mod abi_io;
mod collectors;
mod methods;
mod sampler;
mod snapshot;
mod state;

use std::ffi::{c_char, c_int, c_void, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};

use gstore_contract::abi::{
    ABI_ERR_ABI_MISMATCH, ABI_ERR_NO_INSTANCE, ABI_ERR_NULL, ABI_ERR_PANIC, ABI_OK,
    GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
};
use gstore_contract::context::ModuleContext;

use abi_io::{payload_bytes, write_error_out, write_out};
use state::{log_message, HOST_ABI, HOST_EMIT, HOST_LOG};

/// 模块名：宿主按 `api.name == "perf"` 校验（`gstore_host/src/dl_adapter.rs`）。
pub const MODULE_NAME: &str = "perf";
/// 模块功能版本（宿主 `module_version` 用于热更新提示）。
pub const MODULE_VERSION: u32 = 1;

/// 静默 panic hook（与 download/repo/proxy 同策略：避免 Android 上 backtrace
/// 符号化器把 panic 放大成 SIGSEGV）。测试不安装，便于定位失败。
#[cfg(not(test))]
fn install_panic_hook() {
    std::env::set_var("RUST_BACKTRACE", "0");
    std::panic::set_hook(Box::new(|info| {
        let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic".to_string()
        };
        let loc = info
            .location()
            .map(|l| format!("{}:{}", l.file(), l.line()))
            .unwrap_or_else(|| "?".to_string());
        log_message(3, &format!("perf module panic at {loc}: {msg}"));
    }));
}

#[cfg(test)]
fn install_panic_hook() {}

// ==================== 内部实现 ====================

fn create_impl(config: *const u8, config_len: usize) -> Result<u64, c_int> {
    let ctx = ModuleContext::parse(payload_bytes(config, config_len));
    let id = state::next_instance_id();
    let inst = std::sync::Arc::new(state::PerfInstance::new(id, &ctx));
    state::instances()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, inst);
    log_message(
        1,
        &format!(
            "perf: instance {id} created (data_dir={}, cache_dir={}, abi={})",
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
    if method.is_null() {
        return Err(ABI_ERR_NULL);
    }
    let method = unsafe { CStr::from_ptr(method) }.to_string_lossy().into_owned();
    let payload = payload_bytes(payload, payload_len);
    match methods::dispatch(instance, &method, payload) {
        Ok(bytes) => write_out(bytes, out_data, out_len),
        Err(err) => write_error_out(err, out_data, out_len),
    }
}

fn cancel_impl(instance: u64, _request_id: *const c_char) -> Result<(), c_int> {
    if state::instance_of(instance).is_none() {
        return Err(ABI_ERR_NO_INSTANCE);
    }
    Ok(())
}

fn destroy_impl(instance: u64) -> Result<(), c_int> {
    if sampler::status().map(|(id, _)| id == instance).unwrap_or(false) {
        sampler::stop();
    }
    state::instances()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&instance);
    log_message(1, &format!("perf: instance {instance} destroyed"));
    Ok(())
}

fn shutdown_impl() -> Result<(), c_int> {
    sampler::stop();
    state::instances()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    log_message(1, "perf: shutdown");
    Ok(())
}

/// 宿主下发应用事件（下行订阅）。Phase 1 无订阅语义，记录日志。
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
    let len = payload_bytes(data, data_len).len();
    log_message(1, &format!("perf: on_event module_id={module_id} kind={kind} len={len}"));
    Ok(())
}

// ==================== C ABI 导出 ====================

/// 注册入口：宿主 `dlsym` 此符号并调用（握手）。
#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn gstore_mod_perf_register(
    entry: *const GStoreModuleEntry,
    out: *mut GStoreModuleApi,
) -> c_int {
    install_panic_hook();
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<c_int, c_int> {
        if entry.is_null() || out.is_null() {
            return Err(ABI_ERR_NULL);
        }
        let e = unsafe { &*entry };
        // 只拒绝更旧的宿主；末尾追加字段对更新宿主前向兼容（不做精确匹配）。
        if e.abi_version < GSTORE_MODULE_ABI_VERSION {
            return Err(ABI_ERR_ABI_MISMATCH);
        }
        let _ = HOST_ABI.set(e.abi_version);
        if let Some(f) = e.log {
            let _ = HOST_LOG.set(f);
        }
        if let Some(f) = e.emit_event {
            let _ = HOST_EMIT.set(f);
        }
        log_message(
            1,
            &format!(
                "perf module register: abi={} size={} built={}",
                e.abi_version,
                e.entry_size,
                env!("CARGO_PKG_VERSION")
            ),
        );
        let api = unsafe { &mut *out };
        api.name = c"perf".as_ptr();
        api.version = MODULE_VERSION;
        api.min_host_abi = GSTORE_MODULE_ABI_VERSION;
        api.init = Some(init_export);
        api.create = Some(create_export);
        api.call = Some(call_export);
        api.cancel = Some(cancel_export);
        api.destroy = Some(destroy_export);
        api.shutdown = Some(shutdown_export);
        api.alloc = Some(alloc_export);
        api.free = Some(free_export);
        api.on_event = Some(on_event_export);
        Ok(ABI_OK)
    }));
    result.unwrap_or(Err(ABI_ERR_PANIC)).unwrap_or_else(|code| code)
}

#[no_mangle]
pub extern "C" fn init_export() -> c_int {
    install_panic_hook();
    ABI_OK
}

#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn create_export(config: *const u8, config_len: usize, out_instance: *mut u64) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| create_impl(config, config_len))) {
        Ok(Ok(id)) => {
            unsafe { *out_instance = id };
            ABI_OK
        }
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn call_export(
    instance: u64,
    method: *const c_char,
    payload: *const u8,
    payload_len: usize,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| {
        call_impl(instance, method, payload, payload_len, out_data, out_len)
    })) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn cancel_export(instance: u64, request_id: *const c_char) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| cancel_impl(instance, request_id))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn destroy_export(instance: u64) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| destroy_impl(instance))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn shutdown_export() -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(shutdown_impl)) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn alloc_export(size: usize) -> *mut c_void {
    unsafe { libc::malloc(size.max(1)) }
}

#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn free_export(ptr: *mut c_void) {
    if !ptr.is_null() {
        unsafe { libc::free(ptr) };
    }
}

#[no_mangle]
pub extern "C" fn on_event_export(
    module_id: u64,
    kind: *const c_char,
    data: *const u8,
    data_len: usize,
) -> c_int {
    install_panic_hook();
    match catch_unwind(AssertUnwindSafe(|| on_event_impl(module_id, kind, data, data_len))) {
        Ok(Ok(())) => ABI_OK,
        Ok(Err(code)) => code,
        Err(_) => ABI_ERR_PANIC,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gstore_contract::error::{ModuleError, ERR_METHOD_NOT_FOUND};

    fn entry() -> GStoreModuleEntry {
        GStoreModuleEntry {
            abi_version: GSTORE_MODULE_ABI_VERSION,
            entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
            log: None,
            alloc: None,
            free: None,
            emit_event: None,
            context: std::ptr::null_mut(),
            protect_fd: None,
        }
    }

    #[test]
    fn create_parses_module_context() {
        let ctx = ModuleContext {
            data_dir: "/data/x".into(),
            abi: "arm64-v8a".into(),
            ..Default::default()
        };
        let bytes = ctx.encode();
        let mut instance: u64 = 0;
        assert_eq!(create_export(bytes.as_ptr(), bytes.len(), &mut instance), ABI_OK);
        let stored = state::instance_of(instance).unwrap();
        assert_eq!(stored.data_dir, "/data/x");
        assert_eq!(stored.abi, "arm64-v8a");
        assert_eq!(destroy_export(instance), ABI_OK);
        assert!(state::instance_of(instance).is_none());
    }

    #[test]
    fn create_without_config_uses_default_context() {
        let mut instance: u64 = 0;
        assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);
        assert!(state::instance_of(instance).unwrap().data_dir.is_empty());
        assert_eq!(destroy_export(instance), ABI_OK);
    }

    #[test]
    fn register_reports_perf_name_and_min_host_abi() {
        let e = entry();
        let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::uninit();
        let rc = gstore_mod_perf_register(&e, api.as_mut_ptr());
        assert_eq!(rc, ABI_OK);
        let api = unsafe { api.assume_init() };
        let name = unsafe { CStr::from_ptr(api.name) }.to_str().unwrap();
        assert_eq!(name, "perf");
        assert_eq!(api.min_host_abi, GSTORE_MODULE_ABI_VERSION);
        assert_eq!(api.version, MODULE_VERSION);
        assert!(api.call.is_some() && api.create.is_some() && api.destroy.is_some());
    }

    #[test]
    fn register_rejects_older_host_abi() {
        let mut e = entry();
        e.abi_version = GSTORE_MODULE_ABI_VERSION - 1;
        let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::uninit();
        assert_eq!(gstore_mod_perf_register(&e, api.as_mut_ptr()), ABI_ERR_ABI_MISMATCH);
    }

    #[test]
    fn create_call_ping_destroy_roundtrip() {
        let mut instance: u64 = 0;
        assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);

        let method = std::ffi::CString::new("ping").unwrap();
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = call_export(instance, method.as_ptr(), std::ptr::null(), 0, &mut out, &mut out_len);
        assert_eq!(rc, ABI_OK);
        let bytes = unsafe { std::slice::from_raw_parts(out, out_len) };
        let v: serde_json::Value = serde_json::from_slice(bytes).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["data"]["pong"], true);
        free_export(out as *mut c_void);

        assert_eq!(destroy_export(instance), ABI_OK);
    }

    #[test]
    fn unknown_method_returns_structured_detail_error() {
        let mut instance: u64 = 0;
        assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);

        let method = std::ffi::CString::new("perf.nope").unwrap();
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = call_export(instance, method.as_ptr(), std::ptr::null(), 0, &mut out, &mut out_len);
        assert_eq!(rc, gstore_contract::abi::ABI_ERR_DETAIL);
        let bytes = unsafe { std::slice::from_raw_parts(out, out_len) };
        let err = ModuleError::from_payload(bytes).unwrap();
        assert_eq!(err.code.as_ref(), ERR_METHOD_NOT_FOUND);
        free_export(out as *mut c_void);

        assert_eq!(destroy_export(instance), ABI_OK);
    }

    #[test]
    fn snapshot_method_returns_partial_data_without_panicking() {
        let mut instance: u64 = 0;
        assert_eq!(create_export(std::ptr::null(), 0, &mut instance), ABI_OK);
        let method = std::ffi::CString::new("perf.snapshot").unwrap();
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let rc = call_export(instance, method.as_ptr(), std::ptr::null(), 0, &mut out, &mut out_len);
        assert_eq!(rc, ABI_OK);
        let bytes = unsafe { std::slice::from_raw_parts(out, out_len) };
        let v: serde_json::Value = serde_json::from_slice(bytes).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["data"]["memory"]["total_kb"].is_u64());
        assert!(v["data"]["cpu"].is_object());
        free_export(out as *mut c_void);
        assert_eq!(destroy_export(instance), ABI_OK);
    }
}
