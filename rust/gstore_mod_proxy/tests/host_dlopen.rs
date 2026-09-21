//! 宿主侧 dlopen 集成测试（对齐 `gstore_host` 既有 Linux dlopen 测试）。
//!
//! 以宿主的方式加载 `libgstore_mod_proxy.so`：dlsym `gstore_mod_proxy_register`
//! → 传 `GStoreModuleEntry` 收 `GStoreModuleApi` → `create` → `call("ping")`
//! → 未知方法断言 405 → `destroy`/`shutdown`。
//!
//! 需要 cdylib 已构建：`cargo test -p gstore_mod_proxy` 会把 cdylib 建到
//! `target/<profile>/deps/`；`cargo build` 则建到 `target/<profile>/`。

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::PathBuf;

use gstore_contract::abi::{
    ABI_ERR_DETAIL, ABI_OK, GStoreModuleApi, GStoreModuleEntry, GSTORE_MODULE_ABI_VERSION,
};

type RegisterFn = extern "C" fn(*const GStoreModuleEntry, *mut GStoreModuleApi) -> c_int;
type CallFn =
    extern "C" fn(u64, *const c_char, *const u8, usize, *mut *mut u8, *mut usize) -> c_int;

extern "C" fn dummy_protect(_fd: c_int) -> c_int {
    0
}

fn locate_so() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let candidates = [
        dir.join("target/debug/libgstore_mod_proxy.so"),
        dir.join("target/debug/deps/libgstore_mod_proxy.so"),
        dir.join("target/release/libgstore_mod_proxy.so"),
        dir.join("target/release/deps/libgstore_mod_proxy.so"),
    ];
    for candidate in &candidates {
        if candidate.exists() {
            return candidate.clone();
        }
    }
    panic!(
        "libgstore_mod_proxy.so not built; run `cargo build -p gstore_mod_proxy` first (looked in {:?})",
        candidates
    );
}

fn call_json(call: CallFn, free: extern "C" fn(*mut c_void), inst: u64, method: &str) -> (c_int, Vec<u8>) {
    let m = CString::new(method).unwrap();
    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    let code = call(inst, m.as_ptr(), std::ptr::null(), 0, &mut ptr, &mut len);
    let bytes = if ptr.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len).to_vec() }
    };
    if !ptr.is_null() {
        free(ptr as *mut c_void);
    }
    (code, bytes)
}

#[test]
fn dlopen_proxy_module_ping_returns_ok_and_unknown_method_is_405() {
    let lib = unsafe { libloading::Library::new(locate_so()) }.expect("dlopen libgstore_mod_proxy.so");
    let register: libloading::Symbol<RegisterFn> =
        unsafe { lib.get(b"gstore_mod_proxy_register\0") }.expect("register symbol");

    let entry = GStoreModuleEntry {
        abi_version: GSTORE_MODULE_ABI_VERSION,
        entry_size: std::mem::size_of::<GStoreModuleEntry>() as u32,
        log: None,
        alloc: None,
        free: None,
        emit_event: None,
        context: std::ptr::null_mut(),
        protect_fd: Some(dummy_protect),
    };
    let mut api = std::mem::MaybeUninit::<GStoreModuleApi>::zeroed();
    let code = register(&entry, api.as_mut_ptr());
    assert_eq!(code, ABI_OK, "register handshake");
    let api = unsafe { api.assume_init() };

    let name = unsafe { CStr::from_ptr(api.name) }.to_str().unwrap();
    assert_eq!(name, "proxy");
    assert_eq!(api.min_host_abi, 3);

    let create = api.create.expect("create slot");
    let call = api.call.expect("call slot");
    let destroy = api.destroy.expect("destroy slot");
    let free = api.free.expect("free slot");

    let mut inst: u64 = 0;
    assert_eq!(create(b"{}".as_ptr(), 2, &mut inst), ABI_OK);
    assert!(inst > 0);

    let (code, out) = call_json(call, free, inst, "ping");
    assert_eq!(code, ABI_OK, "ping must succeed");
    let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["data"]["pong"], true);
    assert_eq!(v["data"]["module"], "proxy");

    let (code, out) = call_json(call, free, inst, "core.start");
    assert_eq!(code, ABI_ERR_DETAIL, "unknown method must carry a detail payload");
    let err: serde_json::Value = serde_json::from_slice(&out).unwrap();
    assert_eq!(err["status"], 405);
    assert_eq!(err["code"], "METHOD_NOT_FOUND");

    assert_eq!(destroy(inst), ABI_OK);
    if let Some(shutdown) = api.shutdown {
        shutdown();
    }
}
