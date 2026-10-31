//! Mount helpers: register the real module and drive its C ABI.

use std::ffi::{c_int, c_void, CString};
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};

use gstore_contract::abi::{
    GStoreConfigApiV1, GStoreModuleApi, GStoreModuleEntry, ABI_OK, GSTORE_MODULE_ABI_VERSION,
};
use serde_json::{json, Value};

use super::mock::MockHost;
use crate::{call_export, create_export, free_export, gstore_mod_download_register};

pub(crate) fn test_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub(crate) fn register_with(config: *const GStoreConfigApiV1) -> GStoreModuleApi {
    let entry = GStoreModuleEntry {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
        log: None,
        alloc: None,
        free: None,
        emit_event: None,
        context: std::ptr::null_mut(),
        protect_fd: None,
        platform: std::ptr::null(),
        config,
    };
    let mut api = MaybeUninit::<GStoreModuleApi>::zeroed();
    assert_eq!(
        gstore_mod_download_register(&entry, api.as_mut_ptr()),
        ABI_OK
    );
    unsafe { api.assume_init() }
}

pub(crate) fn mount() -> (&'static MockHost, GStoreModuleApi) {
    let host: &'static MockHost = Box::leak(Box::new(MockHost::new()));
    let vtable = Box::leak(Box::new(host.vtable()));
    let api = register_with(vtable as *const GStoreConfigApiV1);
    (host, api)
}

pub(crate) fn mount_without_vtable() -> &'static MockHost {
    let host: &'static MockHost = Box::leak(Box::new(MockHost::new()));
    let _ = register_with(std::ptr::null());
    host
}

pub(crate) fn create_instance() -> u64 {
    static NEXT_DIR: AtomicU64 = AtomicU64::new(1);
    let dir = std::env::temp_dir().join(format!(
        "gstore-download-cfg-{}-{}",
        std::process::id(),
        NEXT_DIR.fetch_add(1, Ordering::SeqCst)
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let ctx = json!({ "data_dir": dir.to_string_lossy(), "abi": "5" }).to_string();
    let mut id = 0u64;
    assert_eq!(create_export(ctx.as_ptr(), ctx.len(), &mut id), ABI_OK);
    id
}

pub(crate) fn call(id: u64, method: &str, payload: &str) -> Result<Value, c_int> {
    let c_method = CString::new(method).unwrap();
    let mut out_ptr: *mut u8 = std::ptr::null_mut();
    let mut out_len = 0usize;
    let rc = call_export(
        id,
        c_method.as_ptr(),
        payload.as_ptr(),
        payload.len(),
        &mut out_ptr,
        &mut out_len,
    );
    let bytes = if out_ptr.is_null() {
        Vec::new()
    } else {
        let copied = unsafe { std::slice::from_raw_parts(out_ptr, out_len) }.to_vec();
        free_export(out_ptr as *mut c_void);
        copied
    };
    if rc != ABI_OK {
        return Err(rc);
    }
    Ok(serde_json::from_slice(&bytes).expect("method returned JSON"))
}

pub(crate) fn stats(id: u64) -> Value {
    call(id, "download.stats", "").expect("download.stats succeeds")
}
